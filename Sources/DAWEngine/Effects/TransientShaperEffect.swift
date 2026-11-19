import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in transient shaper (m39-y) — a ZERO-LATENCY, GAIN-ONLY insert driven
/// by a THREE-ENVELOPE DIFFERENTIAL FOLLOWER running in the LINEAR amplitude
/// domain, whose differentials are taken as **dB RATIOS**.
/// `TransientShaperParams` carries the frozen laws and the argument for them;
/// `docs/design/2026-09-20-transient-shaper.md` §3 is the detector and §4 the
/// frozen parameter order.
///
/// ⛔ **THIS IS NOT A COMPRESSOR AND THERE IS NO THRESHOLD IN THIS FILE.** That
/// absence is the design, not an omission. A compressor asks "is the signal
/// above a level?"; this asks "is the signal rising (or falling) faster than its
/// OWN lagged reference?". The first question has a different answer at every
/// fader position. The second has the same answer at all of them, which is why
/// this effect works on a quiet stem and a hot one alike.
///
/// WHAT IT DOES, in the order the render path does it, per sample:
///   1. **Rectify, stereo-LINKED** — `peak = max over prepared channels |x|`.
///      Linked and not per-channel: unlinked detection applies a different gain
///      per channel on every hit, which moves the stereo image with the drummer
///      (the `CompressorEffect` detector's rule, for its reason).
///   2. **Three one-pole followers**, branching attack/release, all LINEAR:
///        · `envFast`    follows `peak`,    τ 0.05 ms up / 5 ms down (FIXED)
///        · `envAttack`  follows `envFast`, τ `attackMs` BOTH ways (symmetric)
///        · `envSustain` follows `envFast`, τ 0.05 ms up / `sustainMs` down
///   3. **Flush** all three if denormally small.
///   4. **Two differentials, as dB ratios** — `dA = max(0, 20log10(f/A))` is
///      non-zero only while the signal is rising faster than its own lag;
///      `dS = max(0, 20log10(S/f))` only while it is falling faster than its
///      own lag. Hard-gated to zero below `detectorFloorDb`.
///   5. **One gain** — `attackDb·shapedFraction(dA) + sustainDb·shapedFraction(dS)`,
///      clamped to ±`maxShapeDb`, plus `outputDb`, through `pow`, folded with
///      the dry/wet blend into a SINGLE per-sample scalar.
///
/// ⭐ **WHY LINEAR FOLLOWERS WITH A dB RATIO, AND NOT dB-DOMAIN FOLLOWERS.** A
/// one-pole filtering a **dB** signal has a step response whose duration depends
/// on where the signal STARTED: from a −180 dB silence floor a 5 ms reference
/// needs far longer to climb to within 12 dB of a 0 dBFS hit than it does from a
/// −40 dB noise floor. The "attack window" would then change with whatever
/// preceded the hit — plausible-looking, subtly wrong, and invisible to any test
/// that does not vary the pre-roll. A **linear** one-pole has a
/// level-proportional step response, so the RATIO `f/A` is invariant under a
/// change of input gain. ⛔ **THE LEVEL-INDEPENDENCE COMES FROM THE RATIO, NOT
/// FROM FILTERING IN dB**, and `TransientShaperTests` L6 plants the classic
/// wrong formulation (a LINEAR DIFFERENCE, `envFast − envAttack`) to prove it.
///
/// ⭐ **WHY EACH REFERENCE LAGS `envFast` RATHER THAN `peak`.** Lagging `envFast`
/// SYMMETRICALLY makes `envAttack` converge to it from either side, so `dA`
/// returns to 0 within a few `attackMs` of any onset. ⚠️ **State that precisely:
/// `dA` is 0 once `envAttack` has crossed ABOVE `envFast`, not "throughout any
/// decay".** After a near-rectangular onset the crossing is quick, so `dA` is 0
/// for essentially the whole tail. After a SLOW onset `envAttack` is still below
/// `envFast` when the decay begins and takes up to ~`attackMs` to cross, during
/// which attack shaping does reach the first part of the decay. That is
/// musically correct — a slow swell has a longer "attack" by any definition —
/// and it is why L5's independence window starts well after the crossing.
///
/// ⛔ **LATENCY IS ZERO AND THAT IS A DELIBERATE REFUSAL, NOT AN OVERSIGHT.**
/// `latencySamples` is 0, so this effect adds NO new latency source to the
/// insert PDC measured sample-exact at m25-n. The honest cost: with
/// `fastAttackMs` 0.05 (≈ 2.4 samples at 48 kHz) the gain reaches ~63 % of
/// target in ~2 samples and ~95 % in ~7, so a CUT leaves the first ~2 samples of
/// a leading edge unattenuated — a sub-0.05 ms tick. The alternative costs a
/// `maxLookaheadSamples × maxChannels` ring at `prepare()`, a new declared
/// latency, and a re-verification of a working guarantee, for two samples.
/// ⛔ **A future implementer who adds lookahead MUST declare it in
/// `latencySamples` and re-measure against m25-n. Do not add it silently.**
/// L9 asserts both this effect's 0 and that inserting it leaves
/// `EffectChainProcessor.latencySamples` unmoved.
///
/// SMOOTHING (rule 6.0.6): effect params arrive as ONE SCALAR PER QUANTUM.
/// `attackDb`, `sustainDb`, `outputDb` and `mix` **multiply the signal
/// directly** and are interpolated **per sample** across the quantum; a
/// per-quantum step in any of them is an audible click at a 10.7 ms cadence.
/// ⚠️ **THE FOUR ENVELOPE COEFFICIENTS ARE DELIBERATELY *NOT* INTERPOLATED, AND
/// THAT IS A NARROW, STATED DEVIATION FROM §6.1.3'S 32-FRAME STRIDE.** The
/// difference is one of kind: `DJFilterEffect` and `PhaserEffect` interpolate
/// FILTER coefficients in the audio path, where a step changes the OUTPUT
/// discontinuously. A one-pole ENVELOPE coefficient changes the TRAJECTORY of a
/// state variable whose current value is unchanged — the envelope is continuous
/// across the step, so there is nothing to zipper. `CompressorEffect` already
/// recomputes its attack/release coefficients exactly this way, per adopt, and
/// ships. Recorded here so nobody has to infer it.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. There is NO prepared buffer of any
/// kind in this file — the direct consequence of refusing lookahead.
final class TransientShaperEffect: EffectRendering, @unchecked Sendable {
    private static let maxChannels = 8

    /// Denormal-flush threshold — `DelayEffect`'s existing constant and the
    /// `CompressorEffect` envelope convention, applied to ALL THREE envelopes.
    /// Each is its own one-pole IIR and each decays toward zero on silence
    /// INDEPENDENTLY, so one flush is not enough.
    private static let denormalFloor = 1e-20

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: TransientShaperParams

        init(generation: UInt64, params: TransientShaperParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // Prepared storage (main-actor set, render-thread read).
    private var sampleRate: Double = 48_000
    private var preparedChannels = 2

    // Render-thread-only DETECTOR state. Three `Double`s — nothing here scales
    // with frame count, channel count or sample rate, which is what makes
    // `prepare()` allocation-free too.
    private var envFast = 0.0
    private var envAttack = 0.0
    private var envSustain = 0.0

    // Render-thread-only COEFFICIENTS, derived on adopt / automation store only.
    private var aFastAtk = 0.0
    private var aFastRel = 0.0
    private var aAttack = 0.0
    private var aSustain = 0.0

    private var lastGeneration = UInt64.max

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for.
    private var previousAttackDb = 0.0
    private var targetAttackDb = 0.0
    private var previousSustainDb = 0.0
    private var targetSustainDb = 0.0
    private var previousOutputDb = 0.0
    private var targetOutputDb = 0.0
    private var previousMix = 1.0
    private var targetMix = 1.0
    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<TransientShaperParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: TransientShaperParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: TransientShaperParams = TransientShaperParams()) {
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

    // MARK: - Test instruments
    //
    // ⭐ These exist because the legs that matter most measure a GAIN
    // TRAJECTORY, and reading it back off the parameter would be reading the
    // knob rather than the render. They are bounded reads of stored properties,
    // render-thread safe in the same sense `reset()` is, and called only from
    // tests. The gain itself is never exposed — a test that wants it divides the
    // rendered output by its own input, which is a measurement of the AUDIO.

    /// The three detector envelopes as they stand right now (linear amplitude).
    var detectorEnvelopes: (fast: Double, attack: Double, sustain: Double) {
        (envFast, envAttack, envSustain)
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: TransientShaperParams) {
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

    /// Allocates NOTHING. It stores the rate, clamps the channel count, zeroes
    /// the three envelopes and the four accumulators, and forces a coefficient
    /// re-derive at the new rate. The absence of any prepared buffer here is the
    /// direct consequence of refusing lookahead.
    func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {
        self.sampleRate = sampleRate
        preparedChannels = min(channelCount, Self.maxChannels)
        clearRuntimeState()
        lastGeneration = .max  // re-derive coefficients at the new rate
    }

    var latencySamples: Int { 0 }

    /// Clears the detector (stop-time cut / un-bypass): post-reset output is
    /// unshaped immediately rather than carrying a stale envelope into the next
    /// passage.
    func reset() {
        clearRuntimeState()
    }

    /// Render-thread safe: a handful of stores over stored properties.
    private func clearRuntimeState() {
        envFast = 0
        envAttack = 0
        envSustain = 0
        needsPrime = true
        // m39-d CR-2: a reset drops the ramp in flight (`needsPrime` re-seats
        // the values); the cell geometry is the renderer's and stays.
        rampFramesLeft = 0
        rampAttackDelta = 0
        rampSustainDelta = 0
        rampOutputDelta = 0
        rampMixDelta = 0
    }

    /// Adopts a newly published main-actor snapshot (borrowed — retire bin
    /// guarantees lifetime). Called at the top of `process()` AND by
    /// `storeAutomatedParam`, so an automation store never loses to a snapshot
    /// adopted later in the same quantum.
    private func adoptPendingParams() {
        guard let raw = daw_atomic_ptr_load(paramsSlot) else { return }
        let snapshot = Unmanaged<ParamSnapshot>.fromOpaque(raw).takeUnretainedValue()
        guard snapshot.generation != lastGeneration else { return }
        lastGeneration = snapshot.generation
        overlay.rebase(snapshot.params)
        deriveRenderParams(snapshot.params)
    }

    /// Captures this quantum's interpolation TARGETS and recomputes the four
    /// envelope coefficients. Generation changes, automation stores and the
    /// automation revert all route through here, so there is exactly one place
    /// where a parameter becomes a render value. Pure libm, no allocation.
    ///
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED. A field-by-field overlay poke
    /// (`storeAutomatedParam`) bypasses `TransientShaperParams.init`, so the
    /// clamping the init does is NOT in force. There is no tap arithmetic to
    /// poison here, but a NaN would reach `pow` and then the interpolation
    /// accumulators, where it would silence the strip PERMANENTLY — the
    /// `StereoWidthEffect.width` precedent, same shape, same reason.
    private func deriveRenderParams(_ p: TransientShaperParams) {
        targetAttackDb = (p.attackDb.isFinite ? p.attackDb : 0)
            .clamped(to: TransientShaperParams.attackDbRange)
        targetSustainDb = (p.sustainDb.isFinite ? p.sustainDb : 0)
            .clamped(to: TransientShaperParams.sustainDbRange)
        targetOutputDb = (p.outputDb.isFinite ? p.outputDb : 0)
            .clamped(to: TransientShaperParams.outputDbRange)
        targetMix = (p.mix.isFinite ? p.mix : 1).clamped(to: TransientShaperParams.mixRange)
        // THROUGH THE LAW, never a second copy of the `e^(−1/(ms·rate))`
        // convention. The two fixed constants are re-derived here rather than
        // cached because `prepare()` can change the rate under them.
        aFastAtk = TransientShaperParams.onePoleCoefficient(
            ms: TransientShaperParams.fastAttackMs, sampleRate: sampleRate)
        aFastRel = TransientShaperParams.onePoleCoefficient(
            ms: TransientShaperParams.fastReleaseMs, sampleRate: sampleRate)
        aAttack = TransientShaperParams.onePoleCoefficient(
            ms: (p.attackMs.isFinite ? p.attackMs : 5)
                .clamped(to: TransientShaperParams.attackMsRange),
            sampleRate: sampleRate)
        aSustain = TransientShaperParams.onePoleCoefficient(
            ms: (p.sustainMs.isFinite ? p.sustainMs : 200)
                .clamped(to: TransientShaperParams.sustainMsRange),
            sampleRate: sampleRate)
        rampPending = true  // m39-d CR-2: the next `process` starts a ramp
    }

    /// RENDER-THREAD automation store (M4 vii-c). ⛔ SLOT ORDER IS
    /// `EffectParamSpec.specs(for: .transientShaper)` AND IT IS FROZEN:
    /// 0 attackDb, 1 sustainDb, 2 attackMs, 3 sustainMs, 4 outputDb, 5 mix.
    /// Pokes a preallocated params copy and re-derives — no allocation, no
    /// locks. The three detector envelopes are UNTOUCHED, so an automated move
    /// bends the trajectory without moving the state (§3.8).
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...5).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.attackDb = value
        case 1: overlay.effective.sustainDb = value
        case 2: overlay.effective.attackMs = value
        case 3: overlay.effective.sustainMs = value
        case 4: overlay.effective.outputDb = value
        default: overlay.effective.mix = value
        }
        deriveRenderParams(overlay.effective)
    }

    // MARK: - m39-d CR-2: the control cell (docs/design/2026-10-07-effect-control-rate.md §5.4)
    //
    // Render-thread only. A ramp starts in the `process` call after a derive
    // (`rampPending`). On the control grid (`cellFramesLeft` covers the whole
    // call) it spans the REST OF THE CELL and carries across calls; off it,
    // it spans the call, exactly as before the grid. A ramp in flight that
    // would end INSIDE a call is re-spanned over that call, so no ramp ever
    // ends mid-call and the per-sample loop is untouched. In a 512 bounce the
    // cell is the call: the same delta expression, run the same number of
    // times (G1 byte gate).
    /// Frames from the next `process` call to the next control-cell line
    /// (0 = off the grid). Set by `beginControlCell`, counted down here.
    private var cellFramesLeft = 0
    /// Frames left in the ramp in flight (0 = values sit at their targets).
    private var rampFramesLeft = 0
    /// A derive landed since the ramp in flight began.
    private var rampPending = false
    /// The ramp in flight's per-frame steps (carried across calls; 0 at rest).
    private var rampAttackDelta = 0.0
    private var rampSustainDelta = 0.0
    private var rampOutputDelta = 0.0
    private var rampMixDelta = 0.0

    /// m39-d CR-1 (design §5.3): the automated values stored at this control
    /// cell's entry still stand. Adopt FIRST, so a knob publish waiting in the
    /// slot is seen now, as a store would see it (then `overlay.hold()`
    /// answers false and the renderer re-stores). Render thread; no allocation.
    func holdAutomatedParams() -> Bool {
        adoptPendingParams()
        return overlay.hold()
    }

    /// m39-d CR-2 (design §5.4): the dB and mix ramps span the rest of the
    /// cell (`frames`), carried across calls, instead of one call. (The envelope
    /// coefficients step at the derive, as before.)
    func beginControlCell(frames: Int) {
        cellFramesLeft = max(0, frames)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard frameCount > 0 else { return }

        if needsPrime {
            previousAttackDb = targetAttackDb
            previousSustainDb = targetSustainDb
            previousOutputDb = targetOutputDb
            previousMix = targetMix
            needsPrime = false
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
        guard channelCount > 0, minFrames > 0 else { return }

        // m39-d CR-2: start (or re-span) the ramp — see the MARK above. The
        // delta expressions are the pre-grid ones, verbatim.
        if rampPending || (rampFramesLeft > 0 && rampFramesLeft < minFrames) {
            rampPending = false
            let rampFrames = cellFramesLeft >= minFrames ? cellFramesLeft : minFrames
            let span = Double(rampFrames)
            rampAttackDelta = (targetAttackDb - previousAttackDb) / span
            rampSustainDelta = (targetSustainDb - previousSustainDb) / span
            rampOutputDelta = (targetOutputDb - previousOutputDb) / span
            rampMixDelta = (targetMix - previousMix) / span
            rampFramesLeft = rampFrames
        }
        let attackDelta = rampAttackDelta
        let sustainDelta = rampSustainDelta
        let outputDelta = rampOutputDelta
        let mixDelta = rampMixDelta

        let floorLin = TransientShaperParams.detectorFloorLinear
        let maxShape = TransientShaperParams.maxShapeDb
        let denormal = Self.denormalFloor
        let fastAtk = aFastAtk
        let fastRel = aFastRel
        let attackCoeff = aAttack
        let sustainCoeff = aSustain

        var attackDb = previousAttackDb
        var sustainDb = previousSustainDb
        var outputDb = previousOutputDb
        var mix = previousMix
        var fast = envFast
        var attackEnv = envAttack
        var sustainEnv = envSustain

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gate (L7) can assert an absolute zero. ⚠️ Note
        // `CompressorEffect`'s inner loop uses the `for` form: it PREDATES the
        // rule. Do not copy that line.
        var frame = 0
        while frame < minFrames {
            // 1. STEREO-LINKED PEAK RECTIFIER. Linked, not per-channel: see the
            //    header — unlinked detection moves the stereo image with the
            //    drummer.
            var peak: Float = 0
            var channel = 0
            while channel < channelCount {
                let sample = abs(channelData[channel]![frame])
                if sample > peak { peak = sample }
                channel += 1
            }
            let target = Double(peak)

            // 2. THREE LINEAR ONE-POLE FOLLOWERS, branching attack/release.
            let fastCoeff = target > fast ? fastAtk : fastRel
            fast = fastCoeff * fast + (1.0 - fastCoeff) * target
            // SYMMETRIC lag of `fast` — the same τ up and down, which is what
            // makes `attackEnv` converge from either side so `dA` returns to 0.
            attackEnv = attackCoeff * attackEnv + (1.0 - attackCoeff) * fast
            // Fast UP, `sustainMs` DOWN: it must not lag a rise (or `dS` would
            // fire at an onset and the two axes would not be independent), and
            // it must lag a fall (which is the whole sustain differential).
            let sustainC = fast > sustainEnv ? fastAtk : sustainCoeff
            sustainEnv = sustainC * sustainEnv + (1.0 - sustainC) * fast

            // 3. DENORMAL FLUSH, ALL THREE. Each is its own one-pole IIR and
            //    each decays toward zero on silence INDEPENDENTLY. Subnormal
            //    arithmetic costs orders of magnitude more, on the render
            //    thread, during silence — exactly when nobody is looking.
            if fast < denormal { fast = 0 }
            if attackEnv < denormal { attackEnv = 0 }
            if sustainEnv < denormal { sustainEnv = 0 }

            // 4. THE TWO DIFFERENTIALS, AS dB RATIOS. ⛔ The HARD GATE below is
            //    not merely a ratio clamp: without it the ratio of two
            //    near-zero envelopes is noise, and the unit would apply up to
            //    ±20 dB of shaping to room tone.
            var shapeDb = 0.0
            if fast >= floorLin {
                let f = fast
                let a = attackEnv > floorLin ? attackEnv : floorLin
                let s = sustainEnv > floorLin ? sustainEnv : floorLin
                // RISING faster than its own lag.
                let dA = 20.0 * log10(f / a)
                // FALLING faster than its own lag.
                let dS = 20.0 * log10(s / f)
                shapeDb = attackDb * TransientShaperParams.shapedFraction(differentialDb: dA)
                    + sustainDb * TransientShaperParams.shapedFraction(differentialDb: dS)
                if shapeDb > maxShape { shapeDb = maxShape }
                if shapeDb < -maxShape { shapeDb = -maxShape }
            }

            // 5. ONE GAIN. The dry/wet blend is folded into the SAME per-sample
            //    scalar — `out = mix·(x·g) + (1−mix)·x = x·(mix·g + 1−mix)` — so
            //    the blend costs one multiply-add, no dry buffer, no branch, and
            //    there is only one application site so no two paths can diverge.
            //    ⭐ AT THE DEFAULTS THIS IS BIT-EXACT DRY BY IEEE: `shapeDb` and
            //    `outputDb` are both exactly 0, `pow(10, 0) == 1.0` exactly,
            //    `1·1.0 + 0.0 == 1.0`, and multiplying a `Float` by `1.0f` is
            //    the identity — including for −0.0, subnormals and infinities.
            //    ⚠️ THE LOOP IS NEVER SKIPPED AT `mix == 0`, for the reason
            //    `CompressorEffect` gives verbatim: this unit is STATEFUL, and
            //    an automated `mix` 0→1 would snap from stale envelopes.
            let gain = Float(mix * pow(10.0, (shapeDb + outputDb) / 20.0) + (1.0 - mix))
            channel = 0
            while channel < channelCount {
                channelData[channel]![frame] *= gain
                channel += 1
            }

            attackDb += attackDelta
            sustainDb += sustainDelta
            outputDb += outputDelta
            mix += mixDelta
            frame += 1
        }

        envFast = fast
        envAttack = attackEnv
        envSustain = sustainEnv

        // m39-d CR-2: a ramp still in flight carries what it reached; at the
        // ramp's end the values are SNAPPED to their targets, exactly as every
        // call end did before the grid (and still does off it).
        rampFramesLeft = rampFramesLeft > minFrames ? rampFramesLeft - minFrames : 0
        cellFramesLeft = cellFramesLeft > minFrames ? cellFramesLeft - minFrames : 0
        if rampFramesLeft > 0 {
            previousAttackDb = attackDb
            previousSustainDb = sustainDb
            previousOutputDb = outputDb
            previousMix = mix
            return
        }
        rampAttackDelta = 0
        rampSustainDelta = 0
        rampOutputDelta = 0
        rampMixDelta = 0

        // SNAPPED to this quantum's targets rather than left at whatever the
        // accumulation landed on (the `StereoWidthEffect` rule): a value that
        // settled at 0.9999999 instead of 1 would drift, every quantum, forever
        // — and for `mix` in particular that would break the bit-exact identity
        // the byte gate depends on.
        previousAttackDb = targetAttackDb
        previousSustainDb = targetSustainDb
        previousOutputDb = targetOutputDb
        previousMix = targetMix
    }
}
