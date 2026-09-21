import Foundation

// ============================================================================
// MARK: - DESIGN (m39-ac). The oversampler's FILTER, and the numbers that
//         describe it. There is no separate design doc; this file is it.
// ============================================================================
//
// ## 1. Why this lives in DAWCore and not next to the DSP
//
// The engine's `Oversampler` (DAWEngine/Effects/Primitives/Oversampler.swift)
// copies `kernel(factor:)` into unsafe storage once, at init, and never
// evaluates any of this on the render thread. Keeping the DESIGN here means:
//
//  · the quality claims below (`passbandRippleDb`, `stopbandAttenuationDb`) are
//    RE-DERIVED from the kernel by `OversamplerDesignTests` rather than
//    restated — change a digit and a test reddens instead of the effect
//    quietly degrading (the `FreqShifterParams.worstPhaseErrorDeg` pattern);
//  · `ClipperParams` can echo `latencySamples` on the wire without DAWCore
//    importing DAWEngine;
//  · Saturator v2 — the known second caller, which
//    `SaturatorEffect.swift` already advertises as "an additive internal change
//    behind the same seam" — gets the same numbers with no second copy.
//
// ## 2. The kernel family, in one line
//
//     h[n] = sinc((n − (N−1)/2) / L) · kaiser(n, β),   N = L·M + 1
//
// scaled so `Σh = L`. A Kaiser-windowed sinc whose cutoff is FIXED at the BASE
// rate's Nyquist (`0.5/L` of the oversampled rate), length `N = L·M + 1`, type-I
// linear phase. Two free numbers only: `M` (taps per polyphase phase) and `β`.
//
// ⭐ **THE CUTOFF IS NOT A FREE PARAMETER AND THAT IS THE POINT.** Both stages
// of an oversampler — the anti-IMAGING filter on the way up and the anti-ALIAS
// filter on the way down — have to remove exactly the same thing: everything
// above the base rate's Nyquist. One kernel serves both, which is what "shared
// symmetric kernel" means here and why the up and down stages cannot drift
// apart.
//
// ## 3. The delay, and why it is the SAME for every factor
//
// A type-I linear-phase FIR of length N has group delay `(N−1)/2` samples, flat
// across all frequencies. Here that is `L·M/2` at the OVERSAMPLED rate, i.e.
// `M/2` at the base rate — **independent of L**. Up plus down is therefore
// exactly `M` base-rate samples, at every factor and at every sample rate.
//
// ⛔⛔ **THAT INVARIANCE IS LOAD-BEARING, NOT A CURIOSITY.** The oversampling
// factor is a USER-FACING PARAMETER, and parameter edits deliberately never
// republish the effect chain (`EffectRendering`: "Param edits never republish
// the chain"). If latency moved with the factor, `EffectChainProcessor
// .latencySamples` — and the PDC plan built from it, measured sample-exact at
// m25-n — would go stale the moment a user turned the knob, silently, with
// every test still green. A constant makes that impossible rather than merely
// unlikely.
//
// ⚠️ **m39-ad IS THE ONE EXCEPTION, AND IT EARNED IT RATHER THAN ASSUMED IT.**
// `.saturator` reports 0 at factor 1 and 32 at 2/4, because it is a SHIPPED kind
// whose default must render bit-for-bit as it always did, and 32 samples of
// shift on existing projects is exactly the regression this paragraph is about.
// It is safe there only because its factor can move on the MAIN ACTOR ONLY —
// inside `PlaybackGraph.applyParameters`, whose tail recomputes the plan in the
// SAME pass — and because its `oversampling` slot is INERT to automation, so the
// render thread can never move it behind the plan's back. A future caller that
// wants a factor-dependent latency must reproduce BOTH properties; with either
// one missing, the paragraph above stands unchanged. See `SaturatorEffect`
// DESIGN §3.
//
// ⭐ And factor 1 is not a special case in the maths either: at L = 1 the
// cutoff is 0.5 of the (un-)oversampled rate, so `sinc(n − M/2)` is 1 at the
// centre tap and EXACTLY ZERO everywhere else — the kernel degenerates to a
// pure `M/2`-sample delay, twice, for the same `M` total. `Oversampler` still
// takes a copy path there rather than multiplying by 31 zeroes, but the
// contract is the family's, not an exception to it.
//
// ## 4. The numbers — MEASURED on a dense grid, not quoted
//
// `M = 32`, `β = 8.0` was chosen by sweeping M ∈ {24, 32, 48, 64} × β ∈ [7, 11]
// and reading the response off a 200 001-point grid. β = 8 is the optimum for
// this M: it MINIMISES `fpass + fstop` (the transition width at 0.01 dB ripple
// and 80 dB rejection); 7.5 and 8.5 are both worse, in both directions.
//
// | quantity | value |
// |---|---|
// | taps per phase `M` | 32 |
// | Kaiser β | 8.0 |
// | kernel length at 2× / 4× | 65 / 129 |
// | group delay, up + down | **32 base-rate samples, EVERY factor** |
// | …in ms at 48 kHz | 0.667 ms |
// | passband ripple over `[0, 0.42·fs]` | **≤ 0.0011 dB** (2×: 0.000938, 4×: 0.001002) |
// | stopband over `[0.58·fs, L·fs/2]` | **≤ −80.8 dB** (2×: −80.84, 4×: −81.36) |
//
// ⭐ **THE TWO FACTORS AGREE TO 0.5 dB AND THAT IS A CHECK, NOT A COINCIDENCE.**
// The Kaiser order estimate says attenuation follows `(N−1)·Δf`, and here
// `N−1 = L·M` while the normalised transition width is `(1−2·fp)/L` — the `L`
// cancels. One `M` therefore buys the same filter quality at every factor,
// which is why this design has ONE quality number rather than one per factor.
//
// ## 5. What the passband/stopband edges actually protect
//
// Decimating `L·fs → fs` folds content at `f ∈ [fs/2, fs]` down onto `fs − f`.
// Content between `fs/2` and `(1−fp)·fs` therefore lands ABOVE `fp·fs` — inside
// the band the passband edge already gave up — and only content above
// `(1−fp)·fs` reaches the protected band. With `fp = 0.42` and the stopband
// starting at `0.58·fs` those two edges mirror each other exactly, so:
//
//   **aliasing into `[0, 0.42·fs]` is at least 80.8 dB down.**
//
// At 48 kHz that protected band is 0 … 20.16 kHz; at 44.1 kHz, 0 … 18.52 kHz.
// ⚠️ **IT IS A FRACTION OF THE SESSION RATE, SO IT MOVES.** At 44.1 kHz this
// design gives up the 18.5–22.05 kHz octave-and-a-bit; that is inherent to a
// fixed-length normalised FIR and is stated rather than hidden. Sessions at
// 48 kHz and above are unaffected in any audible sense.
public enum OversamplerDesign {
    /// Taps per polyphase phase, `M`. The ONE number that sets both the filter
    /// quality and the latency; see §3 and §4.
    public static let tapsPerPhase = 32

    /// Kaiser window β. The measured optimum for `tapsPerPhase` — see §4.
    public static let kaiserBeta = 8.0

    /// The factors a caller may ask for. ⛔ APPEND-ONLY in spirit: `1` must stay
    /// first (it is the "hear the aliasing" reference) and the list is what
    /// `ClipperParams.oversamplingFactor(at:)` snaps onto.
    ///
    /// ⚠️⚠️ **THIS IS A SWIFT `Array`, SO IT IS FORBIDDEN ON THE RENDER THREAD.**
    /// It is the DOCUMENTED roster, read by tests, by `prepare()` and by
    /// `Oversampler.init` — all main-actor. Every render-reachable consumer
    /// (`oversamplingFactor(at:)`, `maxFactor`, `Oversampler.upsample`/
    /// `downsample`) uses explicit integer arithmetic instead, and
    /// `ClipperParamsTests` P4b pins the two against each other so they cannot
    /// drift. MEASURED during this build: touching an `Array` and a `Dictionary`
    /// in the render path cost **163 296 malloc events over 2 000 quanta** at
    /// `-Onone`, against the absolute zero the allocation gate asserts.
    public static let supportedFactors = [1, 2, 4]

    /// The largest factor any caller may ask for. Buffers are sized for THIS,
    /// once, so a factor change is an index bound and never an allocation.
    ///
    /// ⚠️ A STORED constant, not `supportedFactors.max()`: it is read on the
    /// render thread (`Oversampler.scratch`) and the computed form touched the
    /// `Array`. `OversamplerDesignTests` D5 pins it against the roster.
    public static let maxFactor = 4

    /// ⛔ **THE GROUP DELAY OF A COMPLETE UP → SHAPE → DOWN ROUND TRIP, IN
    /// BASE-RATE SAMPLES. THE SAME AT EVERY FACTOR AND EVERY SAMPLE RATE** —
    /// see §3 for why that invariance is a requirement rather than a bonus.
    public static var latencySamples: Int { tapsPerPhase }

    /// Kernel length for one stage at `factor`: `L·M + 1`, always odd, so the
    /// filter is type-I linear phase with an integer group delay.
    public static func kernelLength(factor: Int) -> Int {
        max(1, factor) * tapsPerPhase + 1
    }

    // MARK: - The quality claims. RE-DERIVED by the tests, never asserted.

    /// Top of the band whose ripple is pinned (fraction of the BASE rate).
    public static let passbandEdgeFraction = 0.42
    /// Bottom of the stopband (fraction of the BASE rate). Mirrors the
    /// passband edge about `fs/2`, which is what makes §5's claim true.
    public static let stopbandEdgeFraction = 0.58
    /// Worst-case passband deviation from DC gain, in dB, over
    /// `[0, passbandEdgeFraction·fs]` at every supported factor.
    /// MEASURED 0.000938 (2×) and 0.001002 (4×); declared with a little margin
    /// so a grid-resolution change cannot flicker `OversamplerDesignTests` D3.
    public static let passbandRippleDb = 0.0011
    /// Worst-case stopband level relative to DC gain, in dB (negative), over
    /// `[stopbandEdgeFraction·fs, factor·fs/2]`.
    ///
    /// ⭐ MEASURED **−80.84 dB (2×)** and **−81.36 dB (4×)** — the two factors
    /// agreeing to half a decibel, which is §4's cancellation argument coming
    /// out in an actual measurement. Declared at −80.5 for the same
    /// margin reason as `passbandRippleDb`: the claim is what the effect
    /// PROMISES, the numbers above are what it does.
    public static let stopbandAttenuationDb = -80.5

    // MARK: - The kernel itself

    /// Modified Bessel function of the first kind, order 0 — the Kaiser
    /// window's normaliser. Series form; it converges in well under 40 terms
    /// for the β values this design uses, and the loop exits on a RELATIVE
    /// tolerance so it cannot spin on a large argument.
    static func besselI0(_ x: Double) -> Double {
        var sum = 1.0
        var term = 1.0
        var k = 1.0
        while k < 64 {
            let half = x / (2 * k)
            term *= half * half
            sum += term
            if term < 1e-18 * sum { break }
            k += 1
        }
        return sum
    }

    /// ⛔ **THE ONE HOME OF THE KERNEL.** `Oversampler` copies the result into
    /// unsafe storage at init and never calls this again; the tests evaluate
    /// its frequency response and re-derive §4's numbers from it.
    ///
    /// Returns `kernelLength(factor:)` taps, symmetric to the last bit (the
    /// window and the sinc are both even about the centre and are evaluated at
    /// `|m|`-symmetric points), normalised so `Σh == factor` EXACTLY — which is
    /// what makes an interpolator preserve level and a decimator preserve it
    /// again after the `1/factor` scaling the engine applies.
    ///
    /// ⚠️ The normalisation is a DIVISION BY THE MEASURED SUM, not an analytic
    /// scale factor. The windowed sinc's sum is only approximately `2·fc·N`, and
    /// a DC gain that is 0.3 % off would show up as a level change the moment a
    /// user switched factors — a difference that listens like "4× sounds
    /// better" and is nothing but a gain error.
    public static func kernel(factor: Int) -> [Double] {
        let factor = max(1, factor)
        let count = kernelLength(factor: factor)
        let half = (count - 1) / 2
        guard half > 0 else { return [Double(factor)] }
        // Cutoff as a fraction of the OVERSAMPLED rate: the base rate's
        // Nyquist. See §2 — this is not a tunable.
        let cutoff = 0.5 / Double(factor)
        let normaliser = besselI0(kaiserBeta)
        var taps = [Double](repeating: 0, count: count)
        var sum = 0.0
        var index = 0
        while index < count {
            let m = Double(index - half)
            let sinc: Double = m == 0
                ? 2 * cutoff
                : sin(2 * Double.pi * cutoff * m) / (Double.pi * m)
            let ratio = m / Double(half)
            let window = besselI0(kaiserBeta * (max(0, 1 - ratio * ratio)).squareRoot())
                / normaliser
            let tap = sinc * window
            taps[index] = tap
            sum += tap
            index += 1
        }
        guard sum != 0, sum.isFinite else { return taps }
        let scale = Double(factor) / sum
        index = 0
        while index < count {
            taps[index] *= scale
            index += 1
        }
        return taps
    }
}
