import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in psychoacoustic bass harmonic enhancer (m23-p1) — the RBass /
/// MaxxBass class. Per channel, per sample:
///
///   low     = LP(x, fc)                       2nd-order Butterworth
///   m      += k · (|low| − m)                 symmetric one-pole, τ = 50 ms
///   env     = m · π/2                         mean-|sine| → peak amplitude
///   u       = clamp(low / (env + ε), −1, 1)   amplitude-normalized low band
///   shaped  = (w2·T2(u) + w3·T3(u) + w4·T4(u)) · env
///   harm    = HP(shaped, fc)                  2nd-order Butterworth
///   out     = x + mix · harm
///
/// WHY IT WORKS (and why it is not a saturator). The shaper only ever sees
/// the LOW band, and `T_n(cos θ) = cos nθ` exactly — so a normalized sinusoid
/// at f becomes partials at 2f/3f/4f with amplitudes exactly w2/w3/w4, and
/// NOTHING above the 4th. A waveshaper on the full-band signal instead
/// produces an unbounded series over everything you feed it. The generated
/// series is then high-passed at the SAME corner, so only content the small
/// speaker can actually reproduce is added; the ear infers the fundamental it
/// never received (residue pitch / the "missing fundamental").
///
/// LEVEL TRACKING. `u` is the low band divided by its own tracked amplitude,
/// so the harmonic character is identical on a quiet bass line and a loud one
/// — the thing a bare polynomial cannot do (its partials scale as A², A³, A⁴,
/// so the effect would vanish on quiet material and explode on loud). The
/// detector is a SYMMETRIC one-pole on |low| at τ = 50 ms, scaled by π/2 so a
/// steady sine reads its own peak. Symmetric (rather than fast-attack) is
/// deliberate: an asymmetric detector settles near the peak instead of the
/// mean, which breaks the π/2 identity, and its short attack ripples at 2·f
/// (a 10 ms attack ripples ~10% at 100 Hz, smearing the series into
/// intermodulation sidebands). At τ = 50 ms the ripple is ~2% (≈ −34 dB
/// sidebands) and the price is a ~50 ms settle, which the tests exclude by
/// measuring the tail window.
///
/// PURELY ADDITIVE. The dry path is never filtered and nothing is subtracted:
/// `out = x + mix · harm`. There is no complementary-split reconstruction, so
/// there is no reconstruction error, and **`mix == 0` or `amount == 0` skips
/// the whole pass — bit-exact dry, including the detector and both filters**
/// (the `SaturatorEffect` mix-0 precedent: a skipped effect leaves no state to
/// diverge). Both conditions are pinned separately; neither is a special case
/// of the other.
///
/// DC. `T2`/`T4` carry a constant term, so a normalized signal whose peak is
/// below 1 (detector still settling, or non-tonal content) shapes to a small
/// DC offset. The post-shaper high-pass is 2nd-order Butterworth at `fc` ≥
/// 30 Hz, whose DC gain is 0 — this is exactly why every exciter high-passes
/// its generator, not merely a band-limiting convenience.
///
/// SAFETY. `u` is clamped to ±1, so |shaped| ≤ (w2+w3+w4)·env ≤ 0.9·env and
/// the generator can neither run away nor produce a NaN from finite input.
/// `ε` in the divisor (rather than a floored divisor) makes `u → 0` smoothly
/// as the signal dies, so digital silence in is EXACTLY silence added out.
/// Biquad and detector state are denormal-flushed once per channel per pass.
///
/// Parameter updates follow the GainEffect atomic-POD-publish convention;
/// coefficients recompute only on generation change (or an automation store).
/// Render-path contract: `process()`/`reset()` allocate nothing, take no
/// locks, log nothing, touch no ObjC.
final class BassEnhancerEffect: EffectRendering, @unchecked Sendable {
    private static let maxChannels = 8
    /// Per-channel state stride: lp s1, lp s2, hp s1, hp s2, detector.
    private static let stateStride = 5
    /// Detector time constant. See the symmetric-detector argument above.
    private static let detectorTau = 0.050
    /// mean(|A·sin|) = 2A/π, so the peak is the mean × π/2.
    private static let meanToPeak = Double.pi / 2
    /// Divisor epsilon: normalization fades out below ≈ −180 dBFS, far under
    /// float32's usable floor, so silence adds EXACTLY zero.
    private static let normalizeEpsilon = 1e-9

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: BassEnhancerParams

        init(generation: UInt64, params: BassEnhancerParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Render-thread-only state.
    private var sampleRate: Double = 48_000
    private var preparedChannels = 2
    private var lastGeneration = UInt64.max  // .max forces first-quantum adoption
    /// TDF2 state + detector, flat [channel][lp1, lp2, hp1, hp2, m].
    private var state = [Double](repeating: 0, count: maxChannels * stateStride)

    // Derived render params (scalars — no array indirection in the inner loop).
    private var lpB0 = 0.0, lpB1 = 0.0, lpB2 = 0.0, lpA1 = 0.0, lpA2 = 0.0
    private var hpB0 = 0.0, hpB1 = 0.0, hpB2 = 0.0, hpA1 = 0.0, hpA2 = 0.0
    private var w2 = 0.0, w3 = 0.0, w4 = 0.0
    private var mixGain = 0.0
    private var detectorCoefficient = 0.0
    /// False when the effect contributes nothing (`amount == 0 || mix == 0`):
    /// `process` returns before touching the buffer, so the pass is bit-exact
    /// dry AND leaves no filter/detector state behind.
    private var active = false

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<BassEnhancerParams>

    // Main-actor-only publish state (retire bin ≥ 1 s, GainEffect contract).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: BassEnhancerParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: BassEnhancerParams = BassEnhancerParams()) {
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
    func apply(params: BassEnhancerParams) {
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
        for index in state.indices { state[index] = 0 }
        lastGeneration = .max  // adopt (and recompute coefficients) at the first quantum
    }

    /// Minimum-phase filters and a memoryless shaper — no lookahead.
    var latencySamples: Int { 0 }

    func reset() {
        for index in state.indices { state[index] = 0 }
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

    /// Recomputes filter coefficients and series weights from `p` — generation
    /// change, automation stores, and the automation revert route through the
    /// SAME math (pure libm, no allocation; render-thread safe). The RBJ cut
    /// sections come from DAWCore's `EQFilterResponse` — the ONE home for this
    /// project's biquad coefficient math — and the series weights from
    /// `BassEnhancerParams.harmonicWeights`, so the editor's drawing of the
    /// series and the sound it makes cannot fork.
    private func deriveRenderParams(_ p: BassEnhancerParams) {
        let lp = EQFilterResponse.cutSection(highPass: false, freq: p.crossoverHz,
                                             q: EQFilterResponse.butterworth2Q,
                                             sampleRate: sampleRate)
        lpB0 = lp.b0; lpB1 = lp.b1; lpB2 = lp.b2; lpA1 = lp.a1; lpA2 = lp.a2
        let hp = EQFilterResponse.cutSection(highPass: true, freq: p.crossoverHz,
                                             q: EQFilterResponse.butterworth2Q,
                                             sampleRate: sampleRate)
        hpB0 = hp.b0; hpB1 = hp.b1; hpB2 = hp.b2; hpA1 = hp.a1; hpA2 = hp.a2
        let weights = BassEnhancerParams.harmonicWeights(amount: p.amount)
        w2 = weights.h2
        w3 = weights.h3
        w4 = weights.h4
        mixGain = p.mix
        detectorCoefficient = 1 - exp(-1.0 / (Self.detectorTau * sampleRate))
        // BOTH neutral conditions, deliberately NOT folded into one.
        //
        // Note what this flag is and is not. It is NOT what makes a neutral
        // setting bit-exact — `amount == 0` zeroes every series weight and
        // `mix == 0` zeroes the wet gain, so the arithmetic already lands on
        // `x + 0.0`, which is `x` exactly. (Mutation-verified: dropping
        // either condition leaves both bit-exactness legs GREEN.) What the
        // flag buys is that a neutral pass advances NO STATE — the two
        // biquads and the detector are not run at all, so re-enabling the
        // effect behaves exactly like a freshly-prepared insert instead of
        // one carrying a second of warm filter memory. THAT is the pinned
        // property, one leg per condition, in `neutralPassAdvancesNoState*`.
        active = p.mix != 0 && p.amount != 0
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .bassEnhancer)`: 0 crossoverHz, 1 amount,
    /// 2 mix. Pokes a preallocated params copy and re-derives — no allocation,
    /// no locks.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...2).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.crossoverHz = value
        case 1: overlay.effective.amount = value
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
        // Contributes nothing: skip the whole pass (bit-exact dry, no state).
        guard active else { return }

        let strideBytes = MemoryLayout<Float>.stride
        let b0 = lpB0, b1 = lpB1, b2 = lpB2, a1 = lpA1, a2 = lpA2
        let g0 = hpB0, g1 = hpB1, g2 = hpB2, c1 = hpA1, c2 = hpA2
        let k2 = w2, k3 = w3, k4 = w4
        let wet = mixGain
        let detK = detectorCoefficient
        let meanToPeak = Self.meanToPeak
        let epsilon = Self.normalizeEpsilon

        state.withUnsafeMutableBufferPointer { s in
            var channel = 0
            for buffer in buffers {
                guard channel < preparedChannels,
                      let data = buffer.mData?.assumingMemoryBound(to: Float.self) else {
                    channel += 1
                    continue
                }
                let frames = min(frameCount, Int(buffer.mDataByteSize) / strideBytes)
                let base = channel * Self.stateStride
                var lp1 = s[base], lp2 = s[base + 1]
                var hp1 = s[base + 2], hp2 = s[base + 3]
                var mean = s[base + 4]
                // MANUALLY-INCREMENTED `while`, NOT `for frame in 0..<frames`
                // — the m23-r2a chain-walk finding: at `-Onone` (which is how
                // `swift test` builds) `Range` iteration itself raises ~2
                // malloc/free events PER ITERATION, so the per-sample loop of
                // an effect is the single largest allocation source in a
                // debug render. Measured here before the change: exactly
                // 2 048 events per 512-frame stereo quantum (2 × 512 × 2);
                // after it, zero. **NEVER put a `continue` in this body** —
                // `frame` would not advance and the render thread would spin
                // forever (a hang, not a glitch). Use the loop's own exit.
                var frame = 0
                while frame < frames {
                    let x = Double(data[frame])
                    // Low band (TDF2) — the ONLY thing the generator sees.
                    let low = b0 * x + lp1
                    lp1 = b1 * x - a1 * low + lp2
                    lp2 = b2 * x - a2 * low
                    // Amplitude tracking.
                    mean += detK * (abs(low) - mean)
                    let env = mean * meanToPeak
                    var u = low / (env + epsilon)
                    if u > 1 { u = 1 } else if u < -1 { u = -1 }
                    // Chebyshev partials: T_n(cos θ) = cos nθ, so these are
                    // EXACTLY the 2nd/3rd/4th harmonics of a normalized sine.
                    let u2 = u * u
                    let t2 = 2 * u2 - 1
                    let t3 = (4 * u2 - 3) * u
                    let t4 = 8 * u2 * u2 - 8 * u2 + 1
                    let shaped = (k2 * t2 + k3 * t3 + k4 * t4) * env
                    // Inject above the crossover only (and kill the shaper DC).
                    let harm = g0 * shaped + hp1
                    hp1 = g1 * shaped - c1 * harm + hp2
                    hp2 = g2 * shaped - c2 * harm
                    data[frame] = Float(x + wet * harm)
                    frame &+= 1
                }
                // Denormal flush: keep the recursions and the decaying
                // detector out of subnormal territory on silent input.
                if abs(lp1) < 1e-25 { lp1 = 0 }
                if abs(lp2) < 1e-25 { lp2 = 0 }
                if abs(hp1) < 1e-25 { hp1 = 0 }
                if abs(hp2) < 1e-25 { hp2 = 0 }
                if mean < 1e-25 { mean = 0 }
                s[base] = lp1; s[base + 1] = lp2
                s[base + 2] = hp1; s[base + 3] = hp2
                s[base + 4] = mean
                channel += 1
            }
        }
    }
}
