import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in tanh saturator (M4 iv): wet = tanh(g·x) · g^(−1/2) · out, where
/// g = 10^(driveDb/20) and out = 10^(outputDb/20). The FIXED drive
/// compensation is −driveDb/2 dB (× g^(−1/2)): tanh compresses peaks as drive
/// rises, so backing off by half the drive keeps typical program unity-ish
/// loud at mix 1 (measured: a −6 dBFS sine at the default 12 dB drive comes
/// out within ~1.5 dB of its input level). Output is dry·(1−mix) + wet·mix.
///
/// mix == 0 is BIT-EXACT dry: the shaper is stateless, so the whole pass is
/// skipped outright (the GainEffect unity-skip pattern).
///
/// ALIAS HONESTY (v0): there is NO oversampling — tanh's odd harmonics above
/// Nyquist fold back. Acceptable for v0; the test asserts odd-harmonic
/// generation (H3 ≫ floor, H2 ≪ H3), not the alias floor. Oversampling is an
/// additive internal change behind the same seam.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// gains recompute only on generation change. Render-path contract:
/// `process()`/`reset()` allocate nothing, take no locks, log nothing, touch
/// no ObjC. tanh is bounded (|wet| ≤ comp·out), so the shaper can neither
/// generate denormal feedback nor blow up on finite input.
final class SaturatorEffect: EffectRendering, @unchecked Sendable {
    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: SaturatorParams

        init(generation: UInt64, params: SaturatorParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var lastGeneration = UInt64.max
    private var driveLinear: Float = 3.981_071_7   // +12 dB
    private var postGain: Float = 0.501_187_23     // g^(−1/2) · 10^(outputDb/20)
    private var mix: Float = 1
    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<SaturatorParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: SaturatorParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: SaturatorParams = SaturatorParams()) {
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
    func apply(params: SaturatorParams) {
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
        lastGeneration = .max  // adopt exactly at the first quantum
    }

    var latencySamples: Int { 0 }

    /// Stateless waveshaper — nothing to clear.
    func reset() {}

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

    /// Recomputes the derived gains from `p` — generation change, automation
    /// stores, and the automation revert route through the SAME math (pure
    /// libm, no allocation; render-thread safe).
    private func deriveRenderParams(_ p: SaturatorParams) {
        let g = pow(10.0, p.driveDb / 20.0)
        // Fixed −driveDb/2 dB compensation folded with the output trim.
        postGain = Float(pow(g, -0.5) * pow(10.0, p.outputDb / 20.0))
        driveLinear = Float(g)
        mix = Float(p.mix)
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .saturator)`: 0 driveDb, 1 mix,
    /// 2 outputDb. Pokes a preallocated params copy and re-derives — no
    /// allocation, no locks.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...2).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.driveDb = value
        case 1: overlay.effective.mix = value
        default: overlay.effective.outputDb = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        // mix 0: stateless, so skip the whole pass (bit-exact dry).
        guard mix != 0 else { return }

        let strideBytes = MemoryLayout<Float>.stride
        let dryGain = 1 - mix
        let mixGain = mix
        let drive = driveLinear
        let post = postGain
        for buffer in buffers {
            guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
            let frames = min(frameCount, Int(buffer.mDataByteSize) / strideBytes)
            for frame in 0..<frames {
                let dry = data[frame]
                let wet = tanhf(drive * dry) * post
                data[frame] = dry * dryGain + wet * mixGain
            }
        }
    }
}
