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
/// The line itself is `InterpolatedDelayLine` (m39-j-0) — the shared home in
/// `Effects/Primitives/`, which owns the flat two-channel block, the write
/// head and the frozen linear tap arithmetic. Modulation stays HERE: the home
/// has no depth, no rate and no LFO, which is what lets the flanger, the tape
/// delay and the FDN share it.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// derived constants recompute only on generation change. The line is
/// preallocated in `prepare` for the MAX depth range. Render-path contract:
/// `process()`/`reset()` allocate nothing, take no locks, log nothing, touch
/// no ObjC. The chorus path is feedback-free (taps only), so it can neither
/// generate denormals nor blow up on finite input — which is exactly why the
/// shared home carries no denormal flush and each FEEDBACK caller must add
/// its own (design §4.1).
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
    /// Two channel lines in one flat block, one shared write head, linear
    /// fractional taps — sized in `prepare` for centre + MAX depth (25 ms),
    /// so any published depth is math, never an allocation.
    private let line = InterpolatedDelayLine(
        capacitySeconds: (ChorusEffect.centerDelayMs + ChorusParams.depthRange.upperBound) * 0.001,
        interpolation: .linear)

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
        // The SHALLOWEST delay the LFO can ever reach — 15 ms centre minus the
        // 10 ms maximum depth — is the invariant the home checks once, here,
        // off the render thread. At any rate CoreAudio delivers it is hundreds
        // of samples; a refusal can only mean a nonsense rate, and it leaves
        // the line unprepared so `process` passes the buffer through bit-exact
        // dry rather than reading its own write head.
        let minDelaySamples = (Self.centerDelayMs - ChorusParams.depthRange.upperBound)
            * 0.001 * sampleRate
        // ALWAYS two channels: the render path duplicates a mono input into
        // the right line so a later stereo quantum is phase-coherent.
        do {
            try line.prepare(sampleRate: sampleRate, minDelaySamples: minDelaySamples,
                             channelCount: 2)
        } catch {
            // Unreachable above ~200 Hz (5 ms is then ≥ 1 sample). The refusal
            // is not swallowed: it IS `line.isPrepared == false`, which the
            // render path reads every quantum.
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
        line.reset()
        phase = 0
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

    /// m39-d CR-1 (`docs/design/2026-10-07-effect-control-rate.md` §5.3): the
    /// automated values stored at this control cell's entry still stand. Adopt
    /// FIRST, so a knob publish waiting in the slot is seen now, as a store
    /// would see it (then `overlay.hold()` answers false and the renderer
    /// re-stores). Render thread; no allocation, no lock.
    func holdAutomatedParams() -> Bool {
        adoptPendingParams()
        return overlay.hold()
    }

    /// m39-d CR-2 (design §5.4): deliberately a no-op — class (c): every param steps at the store;
    /// nothing ramps over the call.
    func beginControlCell(frames: Int) {}

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard line.isPrepared else { return }

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
        var lfo = phase

        for frame in 0..<minFrames {
            let dryL = left[frame]
            let dryR = right?[frame] ?? dryL
            line.write(channel: 0, dryL)
            line.write(channel: 1, dryR)

            if wetWrite {
                // Voices 180° apart; right channel leads by 90°.
                let delayL0 = center + depth * sin(lfo)
                let delayL1 = center + depth * sin(lfo + .pi)
                let wetL = (line.tap(channel: 0, delaySamples: delayL0)
                            + line.tap(channel: 0, delaySamples: delayL1)) * 0.5
                left[frame] = dryL * dryGain + wetL * mixGain
                if let right {
                    let delayR0 = center + depth * sin(lfo + .pi / 2)
                    let delayR1 = center + depth * sin(lfo + .pi * 1.5)
                    let wetR = (line.tap(channel: 1, delaySamples: delayR0)
                                + line.tap(channel: 1, delaySamples: delayR1)) * 0.5
                    right[frame] = dryR * dryGain + wetR * mixGain
                }
            }

            line.advance()
            lfo += phaseIncrement
            if lfo >= 2.0 * .pi { lfo -= 2.0 * .pi }
        }
        phase = lfo
    }
}
