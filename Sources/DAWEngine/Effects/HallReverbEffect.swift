import AVFAudio
import CAtomics
import DAWCore
import Foundation

/// Built-in 8-line Feedback Delay Network reverb (m39-l) — Householder mixing,
/// per-line two-band absorption and small independently-phased tail modulation.
/// `docs/design/2026-09-19-creative-effects.md` §5 / §6.2 is the frozen
/// contract; §4.1 is the shared delay line's contract.
///
/// ⭐ THIS IS THE THIRD CALLER OF `InterpolatedDelayLine`, and the first to use
/// NINE of them at once (eight tank lines plus the pre-delay). The home needed
/// no change: everything this effect wanted — declared capacity in seconds, a
/// fractional tap that moves smoothly, a prepare-time refusal instead of a
/// render-thread bounds check — was already there for the chorus and the
/// flanger.
///
/// ⛔ THIS DOES NOT REPLACE `.reverb`, AND `.reverb` IS NOT DEPRECATED. Not one
/// byte of `ReverbEffect` changes. Freeverb's small, bright, dense room is a
/// genuinely good sound that this hall does not replicate; what `.reverb`
/// cannot do is have a SIZE, because its comb lengths are compile-time
/// constants and `roomSize` scales comb FEEDBACK (a mislabeled decay control —
/// now documented as such in its own `EffectParamSpec.note`).
///
/// WHAT IT DOES, in the order the render path does it, per sample:
///   1. **Sum to mono** and write it into the pre-delay line; tap that line at
///      `preDelayMs · sr/1000 + 1` samples. ⛔ THE `+1` IS LOAD-BEARING — see
///      `HallReverbParams.preDelayFloorSamples`. `preDelayRange.lowerBound` is
///      0 and `InterpolatedDelayLine.prepare()` REFUSES a declared minimum of
///      0, and a refused line is a SILENT one, so without the floor this whole
///      effect would be a permanent bit-exact passthrough at `preDelayMs: 0`,
///      reporting success the entire time. One sample is ~21 µs.
///   2. **Diffuse** through four series Schroeder allpasses, equal-power
///      crossfaded against the direct path by `diffusion`. This is the EARLY
///      signal. (The crossfade is a MEASURED correction — see `process()`.)
///   3. **Tap all eight lines**, flush each tapped value, and form the two
///      stereo output sums with orthogonal ±1 vectors — that is where the wet
///      stereo image comes from, not from any delay trickery.
///   4. **Mix and absorb.** `y_i = t_i − (2/N)·Σt` (Householder: one dot
///      product plus a scaled subtract, `O(N)`, and ORTHOGONAL so it neither
///      adds nor removes energy), then a low shelf, a high shelf and the
///      mid-band gain `10^(−3·L_i/RT60)`.
///   5. **Inject and write.** The diffused input enters every line with an
///      alternating ±1/√8 sign, and the line advances once per frame.
///   6. **Blend** early against late (equal power), apply M/S `width` to the
///      wet only, then `mix`. At `mix == 0` exactly, THE BUFFER IS NEVER
///      WRITTEN — bit-exact dry by IEEE (rule 6.0.7) — while the tank keeps
///      running, so raising `mix` later brings in a tail that is already going.
///
/// ⛔ **THE DENORMAL FLUSH IS THIS FILE'S JOB, NOT THE LINE'S (§4.1), AND IT
/// MATTERS MORE HERE THAN ANYWHERE.** `InterpolatedDelayLine` deliberately
/// carries no flushing because the chorus is feedback-free and provably cannot
/// generate denormals; a per-sample branch in the home would tax a caller that
/// does not need one. This effect is EIGHT recirculating loops with a decay
/// that is meant to run for up to twenty seconds, idling on silence between
/// phrases — the single most denormal-prone structure in the tree. There are
/// THREE recirculating words per line and all three are flushed with
/// `DelayEffect`'s existing `abs(x) < 1e-20` rather than a second approach:
///   (a) the tapped value — the flanger's site; kills it in the recirculation
///       AND in the output, because both read this one word;
///   (b) the two shelf one-pole states — `DelayEffect`'s own `lpL` site. ⚠️
///       THIS ONE IS INVISIBLE FROM THE OUTPUT: (a) already cleans what the
///       listener hears, so a subnormal grinding inside a shelf costs render
///       time while every output-only test stays green. It is pinned by a
///       `@testable` read of the shelf state itself, not by listening;
///   (c) the allpass diffusers' recirculating word. ⚠️ ALSO INVISIBLE FROM THE
///       OUTPUT, and for a SECOND reason that made it the last site to get a
///       gate: an allpass decays by its coefficient once per loop length, so it
///       crosses the entire subnormal band in ~0.25 s and is exactly zero
///       afterwards. Removing this flush reddened NOTHING — not the output leg,
///       not the shelf leg, and not a state read taken at the end of the
///       silence, because by then the word is 0. It is pinned by SAMPLING the
///       state at every quantum boundary while the decay passes through
///       (MEASURED with the flush removed: 578 786 subnormal words across 562
///       boundaries, smallest 1e-45; zero with it in place).
///
/// SMOOTHING (rule 6.0.6): effect params arrive as ONE SCALAR PER QUANTUM, so
/// `sizeMeters` (as line-length samples), the pre-delay tap, mod depth, the LFO
/// increment, mix, width, the early/late gains, the two shelf coefficients and
/// ALL 24 per-line gains interpolate **per sample** across the quantum. Size
/// especially: it is a read offset on eight recirculating lines, and a
/// per-quantum step in it is an audible tear rather than the smooth Doppler
/// glide the parameter's `note` promises. `pow`/`exp` run only at the quantum
/// boundary. ⚠️ THE EIGHT LFO PHASES ARE NEVER RESET BY A PARAMETER CHANGE;
/// `reset()` clears them (a stop-time cut), `apply`/`storeAutomatedParam` never
/// do, so an automated rate change speeds the drift up without jumping it.
///
/// Parameter updates follow the `GainEffect` atomic-POD-publish convention.
/// Render-path contract: `process()`/`reset()` allocate nothing, take no locks,
/// log nothing, touch no ObjC, hop no actors. Every line is preallocated in
/// `prepare()` for `sizeRange.upperBound`, so a `sizeMeters` change is
/// arithmetic on a read offset and NOTHING EVER RESIZES.
///
/// `latencySamples` is 0. The FDN is not a lookahead structure, and `preDelayMs`
/// is signal delay the user ASKED FOR — reporting it as latency would have PDC
/// compensate away the parameter.
final class HallReverbEffect: EffectRendering, @unchecked Sendable {
    /// `DelayEffect`'s existing constant and its existing shape, deliberately
    /// not a second one. −400 dB: far below anything audible, far above the
    /// subnormal boundary (~1.18e-38 for `Float`).
    private static let denormalFloor: Float = 1e-20

    private static let lineCount = HallReverbParams.lineCount

    /// Input diffuser lengths in samples at 44.1 kHz — Freeverb's allpass
    /// tunings, reused because they are known-good mutually-prime scatter
    /// lengths. FIXED, not scaled by `sizeMeters`: making the scatter times
    /// follow the room too would make `diffusion` and `sizeMeters`
    /// inseparable.
    private static let allpassTunings = [225, 341, 441, 556]
    private static let allpassCount = 4
    /// Fixed Schroeder allpass coefficient — see the crossfade note in
    /// `process()` for why `diffusion` does NOT drive this.
    private static let allpassCoefficient: Float = 0.7

    /// `freeze` crossfade length. A hard switch on either the input mute or
    /// the absorption bypass is a click; ~10 ms is a swell.
    private static let freezeRampSeconds = 0.010

    /// Immutable box crossing main actor → render thread. POD payload.
    private final class ParamSnapshot {
        let generation: UInt64
        let params: HallReverbParams

        init(generation: UInt64, params: HallReverbParams) {
            self.generation = generation
            self.params = params
        }
    }

    private let paramsSlot: UnsafeMutablePointer<daw_atomic_ptr>

    // MARK: - Prepared storage (main-actor allocated, render-thread used)

    private var sampleRate: Double = 48_000

    /// THE SHARED HOME (§4.1) × 9, used unchanged. Capacities are declared in
    /// SECONDS from `HallReverbParams`, the one home for both numbers.
    ///
    /// ⭐⭐ **THE TANK LINES USE `.cubicHermite`, AND THAT IS A MEASURED
    /// DECISION, NOT A PREFERENCE.** §4.1's rule is that an implementer must
    /// not switch an EXISTING caller from `.linear` to "improve" it — that
    /// would redden the chorus's byte-identical gate for a non-bug. A NEW
    /// caller chooses, and §4.1 describes this caller's situation by name:
    /// `.cubicHermite` "exists for the tape delay, where a slow deep wow
    /// sweeps the fractional tap continuously and linear interpolation's
    /// frequency-dependent loss becomes an audibly dull top end."
    ///
    /// An FDN is that case COMPOUNDED. A chorus passes its line once; each of
    /// these lines is re-read roughly fifty times per second, so the
    /// interpolator's loss is raised to the fiftieth power every second.
    /// MEASURED, 48 kHz, `decaySeconds: 4`, absorption neutral:
    ///
    /// | | `.linear` | `.cubicHermite` |
    /// |---|---|---|
    /// | broadband RT60 / requested | 0.90 · 0.85 · **0.775** (at 1/2/4 s — it gets WORSE the longer you ask for) | **0.90 · 0.90 · 0.90** (constant) |
    /// | RT60 at 8 kHz, asking 4 s | **2.23 s** | **4.70 s** |
    /// | `highDecayMultiplier` 1.0 vs 0.1, 8 kHz vs 1 kHz | −37.2 → −66.8 dB | −20.0 → −64.9 dB |
    ///
    /// With `.linear` the effect could not meet §12 gate 9's "RT60 within 10 %
    /// of `decaySeconds`" at all, and `highDecayMultiplier: 1` — documented as
    /// "no damping at all, bright" — was a lie: the interpolator had already
    /// removed the top end before the parameter got a vote.
    ///
    /// ⚠️ **Stability was the reason to check rather than assume**, because
    /// Hermite is not a passive interpolator and this is a feedback loop that
    /// reaches UNITY gain at `freeze`. MEASURED at the worst case (`freeze: 1`,
    /// `sizeMeters: 1` — the shortest lines, hence the most recirculations per
    /// second any setting can produce): **+0.005 dB over 17 seconds**. The
    /// unfrozen worst case (`decaySeconds: 20`, `sizeMeters: 1`,
    /// `lowDecayMultiplier: 4`) decays **−22.4 dB over 27 s** and every sample
    /// stays finite.
    ///
    /// ⛔ **The PRE-DELAY line stays `.linear`, and it has no choice**:
    /// `.cubicHermite`'s stencil reads one sample NEWER than the tap, so its
    /// floor is 2 samples, and this line declares a floor of 1 (§4.1's
    /// addendum). The tank's floor is the shortest line at `sizeMeters: 1` —
    /// 72.9 samples at 44.1 kHz, 79.3 at 48 kHz — so Hermite's 2 is met with
    /// room to spare there.
    private let lines: [InterpolatedDelayLine] = (0..<HallReverbParams.lineCount).map { _ in
        InterpolatedDelayLine(capacitySeconds: HallReverbParams.lineCapacitySeconds,
                              interpolation: .cubicHermite)
    }
    private let preDelayLine = InterpolatedDelayLine(
        capacitySeconds: HallReverbParams.preDelayCapacitySeconds, interpolation: .linear)

    /// Diffuser storage: four fixed-length integer lines in ONE flat block.
    /// These are NOT `InterpolatedDelayLine`s on purpose — nothing modulates
    /// them, so a fractional tap would buy nothing and cost a multiply.
    private var allpassStore: UnsafeMutablePointer<Float>?
    private var allpassLengths = [Int](repeating: 0, count: allpassCount)
    private var allpassOffsets = [Int](repeating: 0, count: allpassCount)
    private var allpassIndices = [Int](repeating: 0, count: allpassCount)
    private var allpassCapacity = 0

    // MARK: - Render-thread-only state

    private var lastGeneration = UInt64.max
    /// One LFO phase PER LINE, in radians — the anti-metallic law (§5.5).
    private var lfoPhase = [Double](repeating: 0, count: lineCount)
    /// Two one-pole shelf states per line (low band, high band).
    private var lowState = [Float](repeating: 0, count: lineCount)
    private var highState = [Float](repeating: 0, count: lineCount)
    /// This frame's tapped line values — read twice (output sum, then mixing),
    /// so they are stashed rather than tapped twice.
    private var tapScratch = [Float](repeating: 0, count: lineCount)

    /// `freeze` blend, 0 = running, 1 = held. Moves by a FIXED per-sample step
    /// (a counter, not the quantum span), so the ramp length is the same
    /// whatever the buffer size.
    private var freezeBlend = 0.0
    private var freezeStep = 1.0 / (0.010 * 48_000)
    private var freezeTarget = 0.0

    // Interpolation endpoints. `previous*` is where the last quantum ENDED,
    // `target*` is what this quantum was asked for. All in RENDER units.
    private var previousSizeSamples = 12.0 / 343.0 * 48_000
    private var targetSizeSamples = 12.0 / 343.0 * 48_000
    private var previousPreDelaySamples = 0.020 * 48_000 + 1
    private var targetPreDelaySamples = 0.020 * 48_000 + 1
    private var previousDepthMs = 0.15
    private var targetDepthMs = 0.15
    private var previousIncrement = 2.0 * .pi * 0.3 / 48_000.0
    private var targetIncrement = 2.0 * .pi * 0.3 / 48_000.0
    private var previousMix = 0.3
    private var targetMix = 0.3
    private var previousWidth = 1.0
    private var targetWidth = 1.0
    private var previousDiffusion = 0.7
    private var targetDiffusion = 0.7
    private var previousEarlyGain = cos(Double.pi / 4)
    private var targetEarlyGain = cos(Double.pi / 4)
    private var previousLateGain = sin(Double.pi / 4)
    private var targetLateGain = sin(Double.pi / 4)
    private var previousLowCoeff = 0.0
    private var targetLowCoeff = 0.0
    private var previousHighCoeff = 0.0
    private var targetHighCoeff = 0.0
    /// Per-line mid-band gain and the two shelf RATIOS relative to it.
    private var previousMidGain = [Double](repeating: 0, count: lineCount)
    private var targetMidGain = [Double](repeating: 0, count: lineCount)
    private var previousLowRatio = [Double](repeating: 1, count: lineCount)
    private var targetLowRatio = [Double](repeating: 1, count: lineCount)
    private var previousHighRatio = [Double](repeating: 1, count: lineCount)
    private var targetHighRatio = [Double](repeating: 1, count: lineCount)
    /// Working copies advanced per sample (kept as stored properties so the
    /// inner loop never allocates a local array).
    private var runningMidGain = [Double](repeating: 0, count: lineCount)
    private var runningLowRatio = [Double](repeating: 1, count: lineCount)
    private var runningHighRatio = [Double](repeating: 1, count: lineCount)
    private var deltaMidGain = [Double](repeating: 0, count: lineCount)
    private var deltaLowRatio = [Double](repeating: 0, count: lineCount)
    private var deltaHighRatio = [Double](repeating: 0, count: lineCount)

    /// Set by `prepare`/`reset`: the next quantum starts AT its target instead
    /// of sweeping into it from a stale value.
    private var needsPrime = true

    /// Automation overlay (M4 vii-c) — render-thread-only knob/lane split.
    private var overlay: AutomationParamOverlay<HallReverbParams>

    // Main-actor-only publish state (retire bin ≥ 1 s).
    private var publishedGeneration: UInt64 = 0
    private var lastAppliedParams: HallReverbParams
    private var retired: [(snapshot: ParamSnapshot, retiredAt: ContinuousClock.Instant)] = []

    init(params: HallReverbParams = HallReverbParams()) {
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
        allpassStore?.deallocate()
    }

    // MARK: - Main-actor surface

    /// Publishes new parameters for pickup at the top of the next quantum.
    /// No-op when nothing changed (safe on every parameter pass).
    @MainActor
    func apply(params: HallReverbParams) {
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
        freezeStep = 1.0 / max(Self.freezeRampSeconds * sampleRate, 1)

        // ⛔ THE TANK'S DECLARED MINIMUM is the SHORTEST line at the SMALLEST
        // size, because the tail modulation is UPWARD-ONLY (the §6.3.2 law
        // applied here — see `HallReverbParams.modulatedDelaySamples`). A
        // bipolar excursion would drive that 1.65 ms line below the 5 ms
        // modulation ceiling and straight into the write head, and `prepare()`
        // would then refuse — silently, because a refused line is a silent one.
        // At 44.1 kHz the floor is 72.9 samples and at 48 kHz 79.3, so a
        // refusal needs a sample rate under ~700 Hz.
        let minLineSamples = HallReverbParams.minimumLineDelaySamples(sampleRate: sampleRate)
        for index in 0..<Self.lineCount {
            do {
                try lines[index].prepare(sampleRate: sampleRate, minDelaySamples: minLineSamples,
                                 channelCount: 1)
            } catch {
                // Not swallowed: the refusal IS `line.isPrepared == false`,
                // which the render path reads every quantum.
            }
        }
        do {
            try preDelayLine.prepare(sampleRate: sampleRate,
                                     minDelaySamples: HallReverbParams.preDelayFloorSamples,
                                     channelCount: 1)
        } catch {
            // Same contract: an unprepared pre-delay line reads 0, and the
            // guard at the top of `process` passes the buffer through dry.
        }

        // Diffuser lines at the prepared rate, one flat block.
        let scale = sampleRate / 44_100.0
        var total = 0
        for index in 0..<Self.allpassCount {
            let length = max(2, Int((Double(Self.allpassTunings[index]) * scale).rounded()))
            allpassLengths[index] = length
            allpassOffsets[index] = total
            total += length
        }
        if allpassCapacity != total || allpassStore == nil {
            allpassStore?.deallocate()
            allpassStore = .allocate(capacity: total)
            allpassCapacity = total
        }

        clearRuntimeState()
        lastGeneration = .max  // re-derive at the new rate
    }

    var latencySamples: Int { 0 }

    /// ⚠️ NOT RENDER-CALLABLE — it allocates. It exists for ONE gate and the
    /// gate cannot be written without it: flush (b), on the shelf one-pole
    /// states, is INVISIBLE FROM THE OUTPUT, because flush (a) has already
    /// cleaned every word the listener hears. An output-only subnormal test
    /// stays green while sixteen subnormal shelf states grind through every
    /// sample of silence, so the only instrument that can see that defect is a
    /// direct read of the state itself. Internal rather than private for
    /// exactly that reason, and named so nobody mistakes it for a control
    /// surface.
    var internalShelfStateMagnitudes: [Float] {
        (0..<Self.lineCount).map { abs(lowState[$0]) }
        + (0..<Self.lineCount).map { abs(highState[$0]) }
    }

    /// ⚠️ NOT RENDER-CALLABLE — it allocates. Flush (c), the four Schroeder
    /// diffusers' recirculating word. Invisible from the output for the same
    /// reason as (b) AND for a second one: the diffuser tail passes into
    /// subnormal territory and then underflows to zero within a few hundred
    /// milliseconds, so even a state read taken once at the end of a silence
    /// sees nothing. The gate has to sample WHILE the decay is passing through.
    var internalDiffuserStateMagnitudes: [Float] {
        guard let allpassStore, allpassCapacity > 0 else { return [] }
        return (0..<allpassCapacity).map { abs(allpassStore[$0]) }
    }

    /// ⚠️ NOT RENDER-CALLABLE. The eight tail-modulation LFO phases, for the
    /// anti-metallic law's structural gate: eight lines sharing one phase
    /// modulate in lockstep, which is a chorus on the whole tank rather than
    /// the independent smear that breaks the modes up, and NO OUTPUT MEASURE
    /// separates the two reliably at the default depth.
    var internalModulationPhases: [Double] { lfoPhase }

    /// Clears every line, every filter state and every LFO (stop-time cut /
    /// un-bypass). Render-thread safe: bounded clears of preallocated memory.
    func reset() {
        clearRuntimeState()
    }

    private func clearRuntimeState() {
        for index in 0..<Self.lineCount { lines[index].reset() }
        preDelayLine.reset()
        if let allpassStore, allpassCapacity > 0 {
            allpassStore.update(repeating: 0, count: allpassCapacity)
        }
        for index in 0..<Self.allpassCount { allpassIndices[index] = 0 }
        for index in 0..<Self.lineCount {
            // ⛔ THE ANTI-METALLIC LAW: each line starts at its OWN phase, read
            // from the one home. Eight lines sharing a phase modulate in
            // lockstep, which is a chorus on the whole tank rather than the
            // independent smear that breaks the modes up.
            lfoPhase[index] = HallReverbParams.modulationPhaseOffsetRadians(line: index)
            lowState[index] = 0
            highState[index] = 0
            tapScratch[index] = 0
        }
        freezeBlend = freezeTarget
        needsPrime = true
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

    /// Captures this quantum's interpolation TARGETS. Generation changes,
    /// automation stores and the automation revert all route through here, so
    /// there is exactly one place where a parameter becomes a render value.
    ///
    /// ⚠️ EVERY FIELD IS RE-GUARDED AND RE-CLAMPED, AND HERE THAT IS A MEMORY-
    /// SAFETY REQUIREMENT, NOT A TIDINESS ONE. A field-by-field overlay poke
    /// (`storeAutomatedParam`) bypasses `HallReverbParams.init`, so the
    /// clamping the init does is NOT in force. `sizeMeters`, `modDepthMs` and
    /// `preDelayMs` all reach `Int(delay)` inside `InterpolatedDelayLine.tap`,
    /// and that line has NO render-thread bounds check by design (§4.1): an
    /// unclamped 600 m would read off the end of a 0.256 s line, and
    /// `Int(Double.nan)` TRAPS outright. `decaySeconds` and the crossovers
    /// reach `pow`/`exp`. (The `FlangerParams` precedent, same shape, three
    /// times the surface.)
    private func deriveRenderParams(_ p: HallReverbParams) {
        let size = (p.sizeMeters.isFinite ? p.sizeMeters : 12)
            .clamped(to: HallReverbParams.sizeRange)
        targetSizeSamples = size / HallReverbParams.speedOfSoundMetersPerSecond * sampleRate
        targetPreDelaySamples = HallReverbParams.preDelaySamples(
            preDelayMs: p.preDelayMs, sampleRate: sampleRate)
        targetDepthMs = (p.modDepthMs.isFinite ? p.modDepthMs : 0.15)
            .clamped(to: HallReverbParams.modDepthRange)
        let rate = (p.modRateHz.isFinite ? p.modRateHz : 0.3)
            .clamped(to: HallReverbParams.modRateRange)
        targetIncrement = 2.0 * .pi * rate / sampleRate
        targetMix = (p.mix.isFinite ? p.mix : 0.3).clamped(to: HallReverbParams.mixRange)
        targetWidth = (p.width.isFinite ? p.width : 1).clamped(to: HallReverbParams.widthRange)
        targetDiffusion = (p.diffusion.isFinite ? p.diffusion : 0.7)
            .clamped(to: HallReverbParams.diffusionRange)
        let gains = HallReverbParams.earlyLateGains(balance: p.earlyLateBalance)
        targetEarlyGain = gains.early
        targetLateGain = gains.late
        targetLowCoeff = HallReverbParams.onePoleCoefficient(
            cornerHz: (p.lowCrossoverHz.isFinite ? p.lowCrossoverHz : 200)
                .clamped(to: HallReverbParams.lowCrossoverRange),
            sampleRate: sampleRate)
        targetHighCoeff = HallReverbParams.onePoleCoefficient(
            cornerHz: (p.highCrossoverHz.isFinite ? p.highCrossoverHz : 6_000)
                .clamped(to: HallReverbParams.highCrossoverRange),
            sampleRate: sampleRate)

        // Per-line gains. `pow` runs HERE, at the quantum boundary — never per
        // sample. The three RT60s are the mid band and the two multiplied bands
        // (§6.2.3's `10^(-3·L/rt60)` law, read from its one home).
        let decay = (p.decaySeconds.isFinite ? p.decaySeconds : 1.8)
            .clamped(to: HallReverbParams.decayRange)
        let lowMultiplier = (p.lowDecayMultiplier.isFinite ? p.lowDecayMultiplier : 1)
            .clamped(to: HallReverbParams.lowDecayMultiplierRange)
        let highMultiplier = (p.highDecayMultiplier.isFinite ? p.highDecayMultiplier : 0.5)
            .clamped(to: HallReverbParams.highDecayMultiplierRange)
        let midRT60 = HallReverbParams.bandRT60Seconds(decaySeconds: decay, multiplier: 1)
        let lowRT60 = HallReverbParams.bandRT60Seconds(decaySeconds: decay,
                                                       multiplier: lowMultiplier)
        let highRT60 = HallReverbParams.bandRT60Seconds(decaySeconds: decay,
                                                        multiplier: highMultiplier)
        // ⚠️ `while`, not `for index in 0..<n`, AND THAT IS MEASURED, not
        // stylistic: this function runs once per quantum on the automation
        // path, and a `Range` iteration raises ~2 malloc/free events PER
        // ITERATION at `-Onone`. The allocation gate counted 96 000 events
        // across 2 000 quanta — exactly 48 per quantum, which is the 24
        // iterations in this function and `process()` doubled.
        var index = 0
        while index < Self.lineCount {
            let length = HallReverbParams.lineLengthSeconds(sizeMeters: size, index: index)
            let mid = HallReverbParams.lineGain(lineLengthSeconds: length, rt60Seconds: midRT60)
            let low = HallReverbParams.lineGain(lineLengthSeconds: length, rt60Seconds: lowRT60)
            let high = HallReverbParams.lineGain(lineLengthSeconds: length, rt60Seconds: highRT60)
            targetMidGain[index] = mid
            // The shelves realise each band's gain RELATIVE to the mid band, so
            // the mid-band multiply is the only broadband one. ⭐ The worst-case
            // loop gain is therefore `mid · max(lowRatio, 1) · max(highRatio, 1)`
            // = `10^(-3L/(4·decay))`, which is < 1 for every reachable setting —
            // and Householder mixing is orthogonal, so the whole network is
            // contractive. That is why `lowDecayMultiplier` can reach 4 without
            // a stability guard.
            targetLowRatio[index] = mid > 0 ? low / mid : 1
            targetHighRatio[index] = mid > 0 ? high / mid : 1
            index += 1
        }

        freezeTarget = HallReverbParams.isFrozen(p.freeze) ? 1 : 0
    }

    /// RENDER-THREAD automation store (M4 vii-c). Slot order =
    /// `EffectParamSpec.specs(for: .hallReverb)`: 0 mix, 1 decaySeconds,
    /// 2 sizeMeters, 3 preDelayMs, 4 width, 5 diffusion, 6 earlyLateBalance,
    /// 7 lowDecayMultiplier, 8 highDecayMultiplier, 9 lowCrossoverHz,
    /// 10 highCrossoverHz, 11 modRateHz, 12 modDepthMs, 13 freeze. Pokes a
    /// preallocated params copy and re-derives — no allocation, no locks. The
    /// LFO phases, the lines and the filter states are untouched, so an
    /// automated move stays continuous.
    func storeAutomatedParam(slot: Int, value: Double) {
        guard value.isFinite, (0...13).contains(slot) else { return }
        adoptPendingParams()
        overlay.beginStore()
        switch slot {
        case 0: overlay.effective.mix = value
        case 1: overlay.effective.decaySeconds = value
        case 2: overlay.effective.sizeMeters = value
        case 3: overlay.effective.preDelayMs = value
        case 4: overlay.effective.width = value
        case 5: overlay.effective.diffusion = value
        case 6: overlay.effective.earlyLateBalance = value
        case 7: overlay.effective.lowDecayMultiplier = value
        case 8: overlay.effective.highDecayMultiplier = value
        case 9: overlay.effective.lowCrossoverHz = value
        case 10: overlay.effective.highCrossoverHz = value
        case 11: overlay.effective.modRateHz = value
        case 12: overlay.effective.modDepthMs = value
        default: overlay.effective.freeze = value
        }
        deriveRenderParams(overlay.effective)
    }

    func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
        adoptPendingParams()
        // Automation lane(s) vanished: knob params restore, no republish.
        if overlay.endQuantum() {
            deriveRenderParams(overlay.base)
        }
        guard preDelayLine.isPrepared, let allpassStore, frameCount > 0 else { return }
        var readiness = 0
        while readiness < Self.lineCount {
            guard lines[readiness].isPrepared else { return }
            readiness += 1
        }

        if needsPrime {
            previousSizeSamples = targetSizeSamples
            previousPreDelaySamples = targetPreDelaySamples
            previousDepthMs = targetDepthMs
            previousIncrement = targetIncrement
            previousMix = targetMix
            previousWidth = targetWidth
            previousDiffusion = targetDiffusion
            previousEarlyGain = targetEarlyGain
            previousLateGain = targetLateGain
            previousLowCoeff = targetLowCoeff
            previousHighCoeff = targetHighCoeff
            var primed = 0
            while primed < Self.lineCount {
                previousMidGain[primed] = targetMidGain[primed]
                previousLowRatio[primed] = targetLowRatio[primed]
                previousHighRatio[primed] = targetHighRatio[primed]
                primed += 1
            }
            needsPrime = false
        }

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
        guard channelCount > 0, minFrames > 0, let left = channelData[0] else { return }
        let right = channelCount > 1 ? channelData[1] : nil

        let span = Double(minFrames)
        let sizeDelta = (targetSizeSamples - previousSizeSamples) / span
        let preDelayDelta = (targetPreDelaySamples - previousPreDelaySamples) / span
        let depthDelta = (targetDepthMs - previousDepthMs) / span
        let incrementDelta = (targetIncrement - previousIncrement) / span
        let mixDelta = (targetMix - previousMix) / span
        let widthDelta = (targetWidth - previousWidth) / span
        let diffusionDelta = (targetDiffusion - previousDiffusion) / span
        let earlyDelta = (targetEarlyGain - previousEarlyGain) / span
        let lateDelta = (targetLateGain - previousLateGain) / span
        let lowCoeffDelta = (targetLowCoeff - previousLowCoeff) / span
        let highCoeffDelta = (targetHighCoeff - previousHighCoeff) / span
        var setup = 0
        while setup < Self.lineCount {
            runningMidGain[setup] = previousMidGain[setup]
            runningLowRatio[setup] = previousLowRatio[setup]
            runningHighRatio[setup] = previousHighRatio[setup]
            deltaMidGain[setup] = (targetMidGain[setup] - previousMidGain[setup]) / span
            deltaLowRatio[setup] = (targetLowRatio[setup] - previousLowRatio[setup]) / span
            deltaHighRatio[setup] = (targetHighRatio[setup] - previousHighRatio[setup]) / span
            setup += 1
        }

        var sizeSamples = previousSizeSamples
        var preDelaySamples = previousPreDelaySamples
        var depthMs = previousDepthMs
        var increment = previousIncrement
        var mix = previousMix
        var width = previousWidth
        var diffusion = previousDiffusion
        var earlyGain = previousEarlyGain
        var lateGain = previousLateGain
        var lowCoeff = previousLowCoeff
        var highCoeff = previousHighCoeff
        let denormalFloor = Self.denormalFloor
        let householder = Float(HallReverbParams.householderScale)
        // ±1/√8 — orthogonal injection and output vectors. Alternating signs on
        // the injection decorrelate the lines from each other; the two output
        // vectors are orthogonal Hadamard rows, which is the WHOLE source of
        // the wet stereo image (no delay trickery, so it folds to mono cleanly).
        let vectorScale: Float = 0.353_553_390_593_274

        // ⚠️ `while`, not `for i in 0..<n` — measured at
        // `EffectChainProcessor.swift:402-412`, a `Range` iteration raises
        // ~2 malloc/free events PER ITERATION at `-Onone`, which is why the
        // allocation gates can assert an absolute zero.
        var frame = 0
        while frame < minFrames {
            let dryL = left[frame]
            let dryR = right?[frame] ?? dryL
            let mono = (dryL + dryR) * 0.5

            // ---- 1. pre-delay, through the shared home ----------------------
            preDelayLine.write(channel: 0, mono)
            var pre = preDelayLine.tap(channel: 0, delaySamples: preDelaySamples)
            preDelayLine.advance()
            if abs(pre) < denormalFloor { pre = 0 }

            // ---- 2. diffusion: four series Schroeder allpasses --------------
            // y = (z^-M - g) / (1 - g·z^-M) — a TRUE allpass (unit magnitude),
            // not Freeverb's approximation, so the scatter smears the input
            // without colouring it. The COEFFICIENT is fixed at 0.7, the value
            // at which a Schroeder diffuser still reads as scatter rather than
            // as a resonance.
            //
            // ⛔ `diffusion` IS AN EQUAL-POWER CROSSFADE, NOT THE COEFFICIENT,
            // AND THAT IS A MEASURED CORRECTION, not a preference. Driving the
            // coefficient looks right and is wrong: a Schroeder allpass at
            // `g == 0` is a PURE DELAY, so `diffusion: 0` — which the param's
            // own note promises means "a drum hit enters the tank as a drum
            // hit" — instead delayed the whole input by the diffusers' serial
            // length. MEASURED: 1 701 samples at 48 kHz, which put the first
            // wet arrival at 56.6 ms when the closed form says 19.8 ms, i.e.
            // the knob nobody turned was adding 35 ms of pre-delay that no
            // parameter accounted for. Crossfading instead makes `diffusion: 0`
            // mean exactly what it says, and equal power (rather than linear)
            // because the direct and scattered paths are decorrelated — a
            // linear blend would dip ~3 dB in the middle of the knob.
            let scatter = Float(sin(diffusion * Double.pi * 0.5))
            let direct = Float(cos(diffusion * Double.pi * 0.5))
            var wet = pre
            var wetRight = pre
            var stage = 0
            while stage < Self.allpassCount {
                let base = allpassOffsets[stage]
                let index = allpassIndices[stage]
                let delayed = allpassStore[base + index]
                var v = wet + delayed * Self.allpassCoefficient
                if abs(v) < denormalFloor { v = 0 }
                allpassStore[base + index] = v
                wet = delayed - v * Self.allpassCoefficient
                var next = index + 1
                if next >= allpassLengths[stage] { next = 0 }
                allpassIndices[stage] = next
                // The third stage's output is the RIGHT early signal — one
                // extra tap, so the early part is stereo instead of a mono
                // spike sitting dead centre. Costs nothing.
                if stage == 2 { wetRight = wet }
                stage += 1
            }
            let diffused = pre * direct + wet * scatter
            let earlyRight = pre * direct + wetRight * scatter

            // ---- 3. tap all eight lines, form the stereo output sums --------
            let inputGain = Float(1 - freezeBlend)
            var sum: Float = 0
            var lateL: Float = 0
            var lateR: Float = 0
            var index = 0
            while index < Self.lineCount {
                let base = sizeSamples * HallReverbParams.lineLengthRatios[index]
                let delay = HallReverbParams.modulatedDelaySamples(
                    baseSamples: base, depthMs: depthMs,
                    phaseRadians: lfoPhase[index], sampleRate: sampleRate)
                var tapped = lines[index].tap(channel: 0, delaySamples: delay)
                // (a) THE FLUSH THE HOME DELIBERATELY DOES NOT DO (§4.1).
                // Cutting the tap kills the denormal in the recirculation AND
                // in the output, because both read this one word.
                if abs(tapped) < denormalFloor { tapped = 0 }
                tapScratch[index] = tapped
                sum += tapped
                // Orthogonal ±1 output vectors: L flips at the halfway point,
                // R alternates. Two Hadamard rows, hence decorrelated.
                lateL += index < 4 ? tapped : -tapped
                lateR += (index & 1) == 0 ? tapped : -tapped
                index += 1
            }
            lateL *= vectorScale
            lateR *= vectorScale

            // ---- 4/5. Householder mix, absorption, injection ----------------
            let mixSum = sum * householder
            let injected = diffused * inputGain * vectorScale
            // `freezeBlend` slides every gain toward UNITY and the input toward
            // silence, so the tank holds what it has. A hard switch on either
            // is a click; this is a fixed ~10 ms ramp in preallocated state.
            let hold = Float(freezeBlend)
            let running = Float(1 - freezeBlend)
            index = 0
            while index < Self.lineCount {
                var v = tapScratch[index] - mixSum

                // Low shelf: gain `lowRatio` below the corner, 1 above.
                let aLow = Float(lowCoeff)
                var low = lowState[index]
                low += aLow * (v - low)
                // (b) THE FLUSH THAT IS INVISIBLE FROM THE OUTPUT. The tap is
                // already clean, so a subnormal living here costs render time
                // while every output-only test stays green.
                if abs(low) < denormalFloor { low = 0 }
                lowState[index] = low
                let lowGain = Float(runningLowRatio[index]) * running + hold
                v = low * lowGain + (v - low)

                // High shelf: gain 1 below the corner, `highRatio` above.
                let aHigh = Float(highCoeff)
                var high = highState[index]
                high += aHigh * (v - high)
                if abs(high) < denormalFloor { high = 0 }
                highState[index] = high
                let highGain = Float(runningHighRatio[index]) * running + hold
                v = high + (v - high) * highGain

                v *= Float(runningMidGain[index]) * running + hold
                // Alternating injection sign — the second orthogonal vector.
                v += (index & 1) == 0 ? injected : -injected
                lines[index].write(channel: 0, v)
                lines[index].advance()

                runningMidGain[index] += deltaMidGain[index]
                runningLowRatio[index] += deltaLowRatio[index]
                runningHighRatio[index] += deltaHighRatio[index]
                lfoPhase[index] += increment
                if lfoPhase[index] >= 2.0 * .pi { lfoPhase[index] -= 2.0 * .pi }
                index += 1
            }

            // ---- 6. early/late blend, width, mix ----------------------------
            let earlyF = Float(earlyGain)
            let lateF = Float(lateGain)
            var wetL = diffused * inputGain * earlyF + lateL * lateF
            var wetR = earlyRight * inputGain * earlyF + lateR * lateF
            // M/S on the WET only — the dry never moves.
            let mid = (wetL + wetR) * 0.5
            let side = (wetL - wetR) * 0.5 * Float(width)
            wetL = mid + side
            wetR = mid - side

            // `mix == 0` is the BIT-EXACT DRY path: the tank above still ran
            // (so a later mix raise is coherent), the buffer is simply never
            // touched. `mix` reaches exactly 0 by arithmetic, not by an
            // epsilon — a knob parked at 0 gives a 0 target and a 0 delta.
            if mix != 0 {
                let dryGain = Float(1 - mix)
                let wetGain = Float(mix)
                left[frame] = dryL * dryGain + wetL * wetGain
                if let right {
                    right[frame] = dryR * dryGain + wetR * wetGain
                }
            }

            if freezeBlend < freezeTarget {
                freezeBlend = min(freezeBlend + freezeStep, freezeTarget)
            } else if freezeBlend > freezeTarget {
                freezeBlend = max(freezeBlend - freezeStep, freezeTarget)
            }
            sizeSamples += sizeDelta
            preDelaySamples += preDelayDelta
            depthMs += depthDelta
            increment += incrementDelta
            mix += mixDelta
            width += widthDelta
            diffusion += diffusionDelta
            earlyGain += earlyDelta
            lateGain += lateDelta
            lowCoeff += lowCoeffDelta
            highCoeff += highCoeffDelta
            frame += 1
        }

        previousSizeSamples = targetSizeSamples
        previousPreDelaySamples = targetPreDelaySamples
        previousDepthMs = targetDepthMs
        previousIncrement = targetIncrement
        previousMix = targetMix
        previousWidth = targetWidth
        previousDiffusion = targetDiffusion
        previousEarlyGain = targetEarlyGain
        previousLateGain = targetLateGain
        previousLowCoeff = targetLowCoeff
        previousHighCoeff = targetHighCoeff
        var settle = 0
        while settle < Self.lineCount {
            previousMidGain[settle] = targetMidGain[settle]
            previousLowRatio[settle] = targetLowRatio[settle]
            previousHighRatio[settle] = targetHighRatio[settle]
            settle += 1
        }
    }
}
