import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in soft-knee downward compressor (M4 iii). Topology (the classic
/// log-domain feed-forward design):
///   stereo-linked peak detector → log-domain gain computer (quadratic soft
///   knee) → one-pole attack/release smoothing ON THE GAIN SIGNAL → makeup.
///
/// The detector is an instant-attack peak follower with a short FIXED 5 ms
/// decay (not the raw rectified sample): it bridges the rectifier's
/// zero-crossing dips so a steady tone reads as its peak level and the static
/// curve matches theory (measured −14.96 dBFS out for a −6 dBFS 1 kHz sine at
/// −18 dB threshold / 4:1 — the textbook −15). 5 ms is well under the minimum
/// release (5 ms floor), so attack/release timing stays governed by the gain
/// smoother.
///
/// With the envelope at rest and no makeup, the computed gain is EXACTLY 1.0
/// (pow(10, 0) == 1), so below-threshold input nulls bit-exact against dry.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// smoothing coefficients recompute only on generation change (they depend on
/// the prepared sample rate). Render-path contract: `process()`/`reset()`
/// allocate nothing, take no locks, log nothing, touch no ObjC — per-sample
/// log10/pow are pure libm. The envelope snaps to 0 near rest (denormal/
/// asymptote guard).
final class CompressorEffect: EffectRendering, @unchecked Sendable {
    private static let maxChannels = 8

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: CompressorParams

        init(generation: UInt64, params: CompressorParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var lastGeneration = UInt64.max
    private var thresholdDb = -18.0
    private var slope = 1.0 / 4.0 - 1.0  // (1/ratio − 1) ≤ 0, dB of reduction per dB over
    private var kneeDb = 6.0
    private var makeupDb = 0.0
    private var attackCoeff = 0.0   // per-sample one-pole feedback coefficient
    private var releaseCoeff = 0.0
    /// Smoothed gain reduction in dB (≤ 0; 0 = no reduction).
    private var envelopeDb = 0.0
    /// Instant-attack peak-follower state (linear) + its fixed 5 ms decay.
    private var detectorLevel = 0.0
    private var detectorDecay = 0.0
    private var preparedChannels = 2
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<CompressorParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: CompressorParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: CompressorParams = CompressorParams()) {
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
    func apply(params: CompressorParams) {
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
        envelopeDb = 0
        detectorLevel = 0
        detectorDecay = exp(-1.0 / (0.005 * sampleRate))  // fixed 5 ms peak decay
        lastGeneration = .max  // re-derive coefficients at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the envelopes — post-reset output is uncompressed immediately.
    func reset() {
        envelopeDb = 0
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
    private func deriveRenderParams(_ p: CompressorParams) {
        thresholdDb = p.thresholdDb
        slope = 1.0 / p.ratio - 1.0
        kneeDb = p.kneeDb
        makeupDb = p.makeupDb
        // One-pole time constants: coeff = e^(−1/(ms·rate)); the
        // envelope covers 63.2% of a step in exactly attack/release ms.
        attackCoeff = exp(-1.0 / (p.attackMs * 0.001 * sampleRate))
        releaseCoeff = exp(-1.0 / (p.releaseMs * 0.001 * sampleRate))
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .compressor)`: 0 thresholdDb, 1 ratio,
    /// 2 attackMs, 3 releaseMs, 4 kneeDb, 5 makeupDb. Pokes a preallocated
    /// params copy and re-derives — no allocation, no locks. The envelope
    /// smoother naturally declicks the quantum steps.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...5).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.thresholdDb = value
        case 1: overlay.effective.ratio = value
        case 2: overlay.effective.attackMs = value
        case 3: overlay.effective.releaseMs = value
        case 4: overlay.effective.kneeDb = value
        default: overlay.effective.makeupDb = value
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
        // Gather channel pointers once (fixed-size stack storage, no heap).
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

        var env = envelopeDb
        var level = detectorLevel
        for frame in 0..<minFrames {
            // Stereo-linked peak detector: instant attack, fixed 5 ms decay.
            var peak: Float = 0
            for channel in 0..<channelCount {
                let sample = abs(channelData[channel]![frame])
                if sample > peak { peak = sample }
            }
            level = max(Double(peak), level * detectorDecay)
            if level < 1e-20 { level = 0 }  // denormal flush on silence
            // Gain computer (log domain, quadratic soft knee).
            let levelDb = 20.0 * log10(max(level, 1e-9))
            let over = levelDb - thresholdDb
            let targetDb: Double
            if 2.0 * over <= -kneeDb {
                targetDb = 0
            } else if 2.0 * over >= kneeDb {
                targetDb = slope * over
            } else {
                let t = over + kneeDb / 2.0
                targetDb = slope * t * t / (2.0 * kneeDb)
            }
            // One-pole smoothing on the gain signal: attack when reduction
            // deepens, release when it recovers.
            let coeff = targetDb < env ? attackCoeff : releaseCoeff
            env = coeff * env + (1.0 - coeff) * targetDb
            if env > -1e-10 { env = 0 }  // snap at rest → exact unity below threshold
            // Makeup applied last.
            let gain = Float(pow(10.0, (env + makeupDb) / 20.0))
            for channel in 0..<channelCount {
                channelData[channel]![frame] *= gain
            }
        }
        envelopeDb = env
        detectorLevel = level
    }
}

/// Fixed-size stack storage for up to 8 channel pointers — avoids any heap
/// allocation for the per-quantum pointer gather on the render thread.
struct InlineChannelPointers {
    var p0, p1, p2, p3, p4, p5, p6, p7: UnsafeMutablePointer<Float>?

    init() {
        p0 = nil; p1 = nil; p2 = nil; p3 = nil
        p4 = nil; p5 = nil; p6 = nil; p7 = nil
    }

    subscript(index: Int) -> UnsafeMutablePointer<Float>? {
        get {
            switch index {
            case 0: return p0
            case 1: return p1
            case 2: return p2
            case 3: return p3
            case 4: return p4
            case 5: return p5
            case 6: return p6
            default: return p7
            }
        }
        set {
            switch index {
            case 0: p0 = newValue
            case 1: p1 = newValue
            case 2: p2 = newValue
            case 3: p3 = newValue
            case 4: p4 = newValue
            case 5: p5 = newValue
            case 6: p6 = newValue
            default: p7 = newValue
            }
        }
    }
}
