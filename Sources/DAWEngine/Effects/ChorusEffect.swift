import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in 2-voice chorus (M4 iv): per channel, two LFO-modulated delay taps
/// read with LINEAR interpolation from one shared line per channel. Delay per
/// voice = 15 ms center + depthMs · sin(phase); sine LFO at `rateHz` with a
/// 90° stereo phase offset (R leads L) and a 180° offset between the two
/// voices. Wet = (voice0 + voice1) / 2; output is dry·(1−mix) + wet·mix.
/// Max modulated delay is 15 + 10 = 25 ms, always > 0 (min 5 ms), so the
/// interpolated read never crosses the write head.
///
/// mix == 0 is BIT-EXACT dry: the buffer is never written (the lines and LFO
/// still advance so a later mix raise is phase-coherent).
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// derived constants recompute only on generation change. Lines are
/// preallocated in `prepare` for the MAX depth range. Render-path contract:
/// `process()`/`reset()` allocate nothing, take no locks, log nothing, touch
/// no ObjC. The chorus path is feedback-free (taps only), so it can neither
/// generate denormals nor blow up on finite input.
final class ChorusEffect: EffectRendering, @unchecked Sendable {
    /// Fixed center delay the LFO modulates around.
    private static let centerDelayMs = 15.0
    private static let voiceCount = 2

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: ChorusParams

        init(generation: UInt64, params: ChorusParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor allocated, render-thread used).
    private var sampleRate: Double = 48_000
    /// Two channel lines in one flat block: [channel][capacityPerChannel].
    private var line: UnsafeMutablePointer<Float>?
    private var capacityPerChannel = 0
    private var writeIndex = 0

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    private var phaseIncrement = 0.0
    private var phase = 0.0                     // voice 0, channel L phase (radians)
    private var centerSamples = 720.0           // 15 ms @ 48 kHz
    private var depthSamples = 144.0            // 3 ms @ 48 kHz
    private var mix: Float = 0.5
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<ChorusParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: ChorusParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: ChorusParams = ChorusParams()) {
        paramsSlot = .allocate(capacity: 1)
        daw_atomic_ptr_init(paramsSlot)
        lastAppliedParams = params
        overlay = AutomationParamOverlay(base: params)
        let snapshot = ParamSnapshot(generation: 0, params: params)
        _ = daw_atomic_ptr_exchange(
            paramsSlot, UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque()))
    }

    deinit {
        if let raw = daw_atomic_ptr_exchange(paramsSlot, nil) {
            Unmanaged<ParamSnapshot>.fromOpaque(raw).release()
        }
        paramsSlot.deallocate()
        line?.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: ChorusParams) {
        guard params != lastAppliedParams else { return }
        lastAppliedParams = params
        publishedGeneration &+= 1
        let snapshot = ParamSnapshot(generation: publishedGeneration, params: params)
        let now = ContinuousClock.now
        let raw = UnsafeMutableRawPointer(Unmanaged.passRetained(snapshot).toOpaque())
        if let old = daw_atomic_ptr_exchange(paramsSlot, raw) {
            retired.append((Unmanaged<ParamSnapshot>.fromOpaque(old).takeRetainedValue(), now))
        }
        retired.removeAll { $0.retiredAt.duration(to: now) > .seconds(1) }
    }

    // MARK: - EffectRendering

    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        centerSamples = Self.centerDelayMs * 0.001 * sampleRate
        // Sized for center + MAX depth (25 ms) + interpolation/rounding
        // margin, so any published depth is math, never an allocation.
        let needed = Int(((Self.centerDelayMs + ChorusParams.depthRange.upperBound)
                          * 0.001 * sampleRate).rounded(.up)) + 4
        if capacityPerChannel != needed || line == nil {
            line?.deallocate()
            line = .allocate(capacity: needed * 2)
            capacityPerChannel = needed
        }
        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the lines and restarts the LFO (stop-time cut / un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: bounded clears of preallocated memory.
    private func clearRuntimeState() {
        line?.update(repeating: 0, count: capacityPerChannel * 2)
        writeIndex = 0
        phase = 0
    }

    /// Linearly interpolated tap `delay` samples behind `write` in the
    /// channel region starting at `base`.
    private func tap(_ line: UnsafeMutablePointer<Float>, base: Int, write: Int,
                     delay: Double) -> Float {
        let whole = Int(delay)               // delay ≥ 5 ms, so never 0
        let fraction = Float(delay - Double(whole))
        var i0 = write - whole
        if i0 < 0 { i0 += capacityPerChannel }
        var i1 = i0 - 1
        if i1 < 0 { i1 += capacityPerChannel }
        let s0 = line[base + i0]
        let s1 = line[base + i1]
        return s0 + (s1 - s0) * fraction
    }

    /// Adopts a newly published main-actor snapshot (borrowed — retire bin
    /// guarantees lifetime). Called at the top of `process()` AND by
    /// `storeAutomatedParam`, so an automation store never loses to a
    /// snapshot adopted later in the same quantum.
    private func adoptPendingParams() {
        guard let raw = daw_atomic_ptr_load(paramsSlot) else { return }
        let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
        guard snapshot.generation != lastGeneration else { return }
        lastGeneration = snapshot.generation
        overlay.rebase(snapshot.params)
        deriveRenderParams(snapshot.params)
    }

    /// Recomputes the derived render constants from `p` — generation change,
    /// automation stores, and the automation revert route through the SAME
    /// math (pure arithmetic, no allocation; render-thread safe — the lines
    /// are sized for the MAX depth, so depth is math, never an allocation).
    private func deriveRenderParams(_ p: ChorusParams) {
        phaseIncrement = 2.0 * .pi * p.rateHz / sampleRate
        depthSamples = p.depthMs * 0.001 * sampleRate
        mix = Float(p.mix)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .chorus)`: 0 rateHz, 1 depthMs, 2 mix.
    /// Pokes a preallocated params copy and re-derives — no allocation, no
    /// locks. The LFO phase is untouched, so rate/depth steps stay coherent.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...2).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.rateHz = value
        case 1: overlay.effective.depthMs = value
        default: overlay.effective.mix = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard let line else { return }

        let strideBytes = MemoryLayout<Float>.stride
        var channelData = InlineChannelPointers()
        var channelCount = 0
        var minFrames = frameCount
        for buffer in buffers where channelCount < 2 {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            channelData[channelCount] = data
            minFrames = min(minFrames, Int(buffer.mDataByteSize) / strideBytes)
            channelCount += 1
        }
        guard channelCount > 0, let left = channelData[0] else { return }
        let right = channelCount > 1 ? channelData[1] : nil

        let wetWrite = mix != 0  // mix 0: advance lines + LFO, never write
        let dryGain = 1 - mix
        let mixGain = mix
        let center = centerSamples
        let depth = depthSamples
        var index = writeIndex
        var lfo = phase

        for frame in 0..<minFrames {
            let dryL = left[frame]
            let dryR = right?[frame] ?? dryL
            line[index] = dryL
            line[capacityPerChannel + index] = dryR

            if wetWrite {
                // Voices 180° apart; right channel leads by 90°.
                let delayL0 = center + depth * sin(lfo)
                let delayL1 = center + depth * sin(lfo + .pi)
                let wetL = (tap(line, base: 0, write: index, delay: delayL0)
                            + tap(line, base: 0, write: index, delay: delayL1)) * 0.5
                left[frame] = dryL * dryGain + wetL * mixGain
                if let right {
                    let delayR0 = center + depth * sin(lfo + .pi / 2)
                    let delayR1 = center + depth * sin(lfo + .pi * 1.5)
                    let wetR = (tap(line, base: capacityPerChannel, write: index, delay: delayR0)
                                + tap(line, base: capacityPerChannel, write: index,
                                      delay: delayR1)) * 0.5
                    right[frame] = dryR * dryGain + wetR * mixGain
                }
            }

            index += 1
            if index == capacityPerChannel { index = 0 }
            lfo += phaseIncrement
            if lfo >= 2.0 * .pi { lfo -= 2.0 * .pi }
        }
        writeIndex = index
        phase = lfo
    }
}
