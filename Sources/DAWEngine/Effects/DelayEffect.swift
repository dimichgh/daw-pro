import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in stereo delay (M4 iv): per-channel INTEGER delay lines (delay =
/// round(timeMs × rate / 1000), the exact-sample-offset contract pinned by
/// `delayEchoLandsAtExactSampleOffset`), feedback through a one-pole low-pass
/// (`highCutHz`) in the FEEDBACK path only — the first echo is unfiltered.
/// `pingPong` ≥ 0.5 crossfeeds the feedback L↔R (L's echo feeds R's line and
/// vice versa). Output is dry·(1−mix) + delayed·mix.
///
/// mix == 0 is BIT-EXACT dry: the buffer is never written (lines still
/// advance so a later mix raise has coherent repeats).
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// derived constants recompute only on generation change. Lines are
/// preallocated in `prepare` for the MAX 2 s time, so a time change is a
/// read-offset change, never an allocation. Render-path contract:
/// `process()`/`reset()` allocate nothing, take no locks, log nothing, touch
/// no ObjC. Feedback filter state is denormal-flushed per sample.
final class DelayEffect: EffectRendering, @unchecked Sendable {
    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: DelayParams

        init(generation: UInt64, params: DelayParams) {
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
    private var delaySamples = 16_800   // 350 ms @ 48 kHz
    private var feedback: Float = 0.35
    private var mix: Float = 0.3
    private var pingPong = false
    private var lowpassCoeff: Float = 0  // y += a·(x − y)
    private var filterStateL: Float = 0
    private var filterStateR: Float = 0
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<DelayParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: DelayParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: DelayParams = DelayParams()) {
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
    func apply(params: DelayParams) {
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
        // Sized for the MAX of the param range (2 s) + 1, so any published
        // timeMs is a read-offset change, never an allocation.
        let needed = Int((DelayParams.timeRange.upperBound * 0.001 * sampleRate).rounded()) + 1
        if capacityPerChannel != needed || line == nil {
            line?.deallocate()
            line = .allocate(capacity: needed * 2)
            capacityPerChannel = needed
        }
        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the lines + feedback filters (stop-time tail cut / un-bypass).
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: bounded clears of preallocated memory.
    private func clearRuntimeState() {
        line?.update(repeating: 0, count: capacityPerChannel * 2)
        writeIndex = 0
        filterStateL = 0
        filterStateR = 0
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
    /// math (pure libm, no allocation; render-thread safe).
    private func deriveRenderParams(_ p: DelayParams) {
        delaySamples = min(capacityPerChannel - 1,
                           max(1, Int((p.timeMs * 0.001 * sampleRate).rounded())))
        feedback = Float(p.feedback)
        mix = Float(p.mix)
        pingPong = p.pingPong >= 0.5
        // One-pole low-pass y += a·(x − y): a = 1 − e^(−2π·fc/fs).
        lowpassCoeff = Float(1.0 - exp(-2.0 * .pi * p.highCutHz / sampleRate))
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .delay)`: 0 timeMs, 1 feedback, 2 mix,
    /// 3 pingPong, 4 highCutHz. Pokes a preallocated params copy and
    /// re-derives — no allocation, no locks.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...4).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.timeMs = value
        case 1: overlay.effective.feedback = value
        case 2: overlay.effective.mix = value
        case 3: overlay.effective.pingPong = value
        default: overlay.effective.highCutHz = value
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

        let wetWrite = mix != 0  // mix 0: advance the lines, never write (bit-exact dry)
        let dryGain = 1 - mix
        let mixGain = mix
        let a = lowpassCoeff
        var lpL = filterStateL
        var lpR = filterStateR
        var index = writeIndex

        for frame in 0..<minFrames {
            let dryL = left[frame]
            let dryR = right?[frame] ?? dryL

            var readIndex = index - delaySamples
            if readIndex < 0 { readIndex += capacityPerChannel }
            let delayedL = line[readIndex]
            let delayedR = line[capacityPerChannel + readIndex]

            // One-pole high-cut in the feedback path (first echo unfiltered).
            lpL += a * (delayedL - lpL)
            lpR += a * (delayedR - lpR)
            if abs(lpL) < 1e-20 { lpL = 0 }
            if abs(lpR) < 1e-20 { lpR = 0 }

            // Ping-pong crossfeeds the feedback L↔R.
            let fbIntoL = (pingPong ? lpR : lpL) * feedback
            let fbIntoR = (pingPong ? lpL : lpR) * feedback
            line[index] = dryL + fbIntoL
            line[capacityPerChannel + index] = dryR + fbIntoR
            index += 1
            if index == capacityPerChannel { index = 0 }

            guard wetWrite else { continue }
            left[frame] = dryL * dryGain + delayedL * mixGain
            if let right {
                right[frame] = dryR * dryGain + delayedR * mixGain
            }
        }
        filterStateL = lpL
        filterStateR = lpR
        writeIndex = index
    }
}
