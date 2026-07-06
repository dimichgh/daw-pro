import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in downward noise gate (M4 iv). Topology:
///   stereo-linked instant-attack peak detector (fixed 5 ms decay — the
///   CompressorEffect detector, bridging rectifier dips) → open/closed
///   decision vs. threshold → LINEAR gain ramps: attack toward EXACTLY 1,
///   release toward EXACTLY 0, with a hold counter that re-arms every
///   above-threshold sample and keeps the gate open across short gaps.
///
/// Exactness contract: the ramps land on 1.0/0.0 by construction
/// (min/max-clamped linear steps), so a fully OPEN gate multiplies by
/// nothing at all (bit-exact passthrough — the GainEffect unity-skip
/// pattern) and a fully CLOSED gate writes literal zeros (true silence
/// after release completes, even on nonzero sub-threshold input).
///
/// The gate starts CLOSED (gain 0): program that begins loud fades in over
/// the attack ramp (0.1–50 ms) — standard gate behavior.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// derived constants recompute only on generation change. Render-path
/// contract: `process()`/`reset()` allocate nothing, take no locks, log
/// nothing, touch no ObjC. The detector level is denormal-flushed on silence.
final class GateEffect: EffectRendering, @unchecked Sendable {
    private static let maxChannels = 8

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: GateParams

        init(generation: UInt64, params: GateParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var lastGeneration = UInt64.max
    private var thresholdLinear: Float = 0.01   // −40 dB
    private var attackStep: Float = 0
    private var releaseStep: Float = 0
    private var holdSamples = 0
    /// Gate gain 0…1; EXACTLY 0 when closed, EXACTLY 1 when open.
    private var gain: Float = 0
    private var holdRemaining = 0
    /// Instant-attack peak-follower state (linear) + its fixed 5 ms decay.
    private var detectorLevel: Float = 0
    private var detectorDecay: Float = 0
    private var preparedChannels = 2
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<GateParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: GateParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: GateParams = GateParams()) {
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
    func apply(params: GateParams) {
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
        preparedChannels = min(channelCount, Self.maxChannels)
        detectorDecay = Float(exp(-1.0 / (0.005 * sampleRate)))  // fixed 5 ms peak decay
        gain = 0
        holdRemaining = 0
        detectorLevel = 0
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// Closes the gate and clears the detector (stop-time cut / un-bypass).
    func reset() {
        gain = 0
        holdRemaining = 0
        detectorLevel = 0
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
    private func deriveRenderParams(_ p: GateParams) {
        thresholdLinear = Float(pow(10.0, p.thresholdDb / 20.0))
        attackStep = Float(1.0 / max(1.0, (p.attackMs * 0.001 * sampleRate).rounded()))
        releaseStep = Float(1.0 / max(1.0, (p.releaseMs * 0.001 * sampleRate).rounded()))
        holdSamples = Int((p.holdMs * 0.001 * sampleRate).rounded())
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .gate)`: 0 thresholdDb, 1 attackMs,
    /// 2 holdMs, 3 releaseMs. Pokes a preallocated params copy and
    /// re-derives — no allocation, no locks. The attack/release ramps
    /// naturally declick the quantum steps.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...3).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.thresholdDb = value
        case 1: overlay.effective.attackMs = value
        case 2: overlay.effective.holdMs = value
        default: overlay.effective.releaseMs = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }

        let strideBytes = MemoryLayout<Float>.stride
        var channelData = InlineChannelPointers()
        var channelCount = 0
        var minFrames = frameCount
        for buffer in buffers where channelCount < preparedChannels {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            channelData[channelCount] = data
            minFrames = min(minFrames, Int(buffer.mDataByteSize) / strideBytes)
            channelCount += 1
        }
        guard channelCount > 0 else { return }

        var g = gain
        var hold = holdRemaining
        var level = detectorLevel
        for frame in 0..<minFrames {
            // Stereo-linked peak detector: instant attack, fixed 5 ms decay.
            var peak: Float = 0
            for channel in 0..<channelCount {
                let sample = abs(channelData[channel]![frame])
                if sample > peak { peak = sample }
            }
            level = max(peak, level * detectorDecay)
            if level < 1e-20 { level = 0 }  // denormal flush on silence

            // Open/closed decision: above threshold re-arms the hold; below,
            // the hold keeps the target open until it runs out.
            let open: Bool
            if level >= thresholdLinear {
                hold = holdSamples
                open = true
            } else if hold > 0 {
                hold -= 1
                open = true
            } else {
                open = false
            }

            // Linear ramps landing EXACTLY on 1 / 0.
            if open {
                if g < 1 { g = min(1, g + attackStep) }
            } else if g > 0 {
                g = max(0, g - releaseStep)
            }

            // Fully open: bit-exact passthrough (no multiply at all).
            if g == 1 { continue }
            for channel in 0..<channelCount {
                channelData[channel]![frame] *= g
            }
        }
        gain = g
        holdRemaining = hold
        detectorLevel = level
    }
}
