import Foundation
import Testing
@testable import DAWCore

/// m39-ac — **the oversampler's FILTER, re-derived rather than restated.**
///
/// ⭐⭐ `OversamplerDesign` writes down four quality numbers (`passbandRippleDb`,
/// `stopbandAttenuationDb` and the two band edges) and one structural one
/// (`latencySamples`). A comment carrying a number is a number that can rot away
/// from the code it describes — the `FreqShifterParams.worstPhaseErrorDeg`
/// lesson. So this suite EVALUATES the shipped kernel's frequency response on a
/// dense grid and holds the constants to it. Change `tapsPerPhase` or
/// `kaiserBeta` by a digit and these legs redden instead of the effect quietly
/// getting worse.
///
/// ⛔ D4b is the leg that makes the rest evidence: it runs the SAME measurement
/// against a DELIBERATELY BAD kernel (β = 0, i.e. a rectangular window) and
/// proves the stopband assertion FAILS on it. A measurement never seen to fail
/// is not a measurement.
@Suite("m39-ac — the oversampler's kernel is what its constants say it is")
struct OversamplerDesignTests {

    // MARK: - Instruments

    /// |H(f)| in dB at `f`, given as a fraction of the OVERSAMPLED rate.
    /// Evaluated straight from the taps — no FFT, no windowing, no library.
    private static func responseDb(_ taps: [Double], atFractionOfOversampled f: Double) -> Double {
        let w = 2 * Double.pi * f
        var re = 0.0
        var im = 0.0
        for (n, tap) in taps.enumerated() {
            re += tap * cos(-w * Double(n))
            im += tap * sin(-w * Double(n))
        }
        let magnitude = (re * re + im * im).squareRoot()
        return magnitude > 0 ? 20 * log10(magnitude) : -400
    }

    /// Worst deviation from DC gain, in dB, over the passband
    /// `[0, edge·fs]` expressed in BASE-rate fractions.
    private static func passbandRipple(_ taps: [Double], factor: Int,
                                       edge: Double, points: Int = 4_001) -> Double {
        let dc = responseDb(taps, atFractionOfOversampled: 0)
        var worst = 0.0
        for index in 0...points {
            let f = (edge / Double(factor)) * Double(index) / Double(points)
            let deviation = responseDb(taps, atFractionOfOversampled: f) - dc
            if abs(deviation) > abs(worst) { worst = deviation }
        }
        return worst
    }

    /// Worst (highest) stopband level relative to DC gain, in dB, over
    /// `[edge·fs, factor·fs/2]`.
    private static func stopbandPeak(_ taps: [Double], factor: Int,
                                     edge: Double, points: Int = 4_001) -> Double {
        let dc = responseDb(taps, atFractionOfOversampled: 0)
        let low = edge / Double(factor)
        var worst = -400.0
        for index in 0...points {
            let f = low + (0.5 - low) * Double(index) / Double(points)
            worst = max(worst, responseDb(taps, atFractionOfOversampled: f) - dc)
        }
        return worst
    }

    /// The same kernel family at an arbitrary β — D4b's bad-kernel control.
    /// Deliberately a COPY of `OversamplerDesign.kernel`'s body rather than a
    /// parameter on it: the shipped function must have no β knob to get wrong.
    private static func kernel(factor: Int, beta: Double) -> [Double] {
        let count = OversamplerDesign.kernelLength(factor: factor)
        let half = (count - 1) / 2
        let cutoff = 0.5 / Double(factor)
        let normaliser = OversamplerDesign.besselI0(beta)
        var taps = [Double](repeating: 0, count: count)
        var sum = 0.0
        for index in 0..<count {
            let m = Double(index - half)
            let sinc = m == 0 ? 2 * cutoff : sin(2 * Double.pi * cutoff * m) / (Double.pi * m)
            let ratio = m / Double(half)
            let window = OversamplerDesign.besselI0(
                beta * (max(0, 1 - ratio * ratio)).squareRoot()) / normaliser
            taps[index] = sinc * window
            sum += taps[index]
        }
        return taps.map { $0 * Double(factor) / sum }
    }

    // MARK: - D1: shape

    @Test("D1 — every kernel is odd-length, EXACTLY symmetric, and sums to its factor")
    func kernelShapeIsWhatLinearPhaseRequires() {
        for factor in OversamplerDesign.supportedFactors {
            let taps = OversamplerDesign.kernel(factor: factor)
            #expect(taps.count == factor * OversamplerDesign.tapsPerPhase + 1)
            #expect(taps.count % 2 == 1, Comment(rawValue:
                    "an even-length FIR has a HALF-SAMPLE group delay, which would make the "
                    + "round-trip latency non-integral"))
            // Symmetry TO THE BIT, not to a tolerance: `sin(-x)` is exactly
            // `-sin(x)` and `(-a)/(-b)` is exactly `a/b` in IEEE, so a
            // difference here means the evaluation is not mirror-symmetric and
            // the filter is not linear phase.
            var worstAsymmetry = 0.0
            for index in 0..<taps.count {
                worstAsymmetry = max(worstAsymmetry, abs(taps[index] - taps[taps.count - 1 - index]))
            }
            #expect(worstAsymmetry == 0,
                    "factor \(factor): kernel is asymmetric by \(worstAsymmetry) — not linear phase")
            let sum = taps.reduce(0, +)
            #expect(abs(sum - Double(factor)) < 1e-12, Comment(rawValue:
                    "factor \(factor): DC gain \(sum), expected exactly \(factor) — a gain error "
                    + "here listens like 'a higher factor sounds better' and is nothing of the kind"))
        }
    }

    /// ⭐ The claim that makes factor 1 a member of the family rather than an
    /// exception, and therefore the claim the constant latency rests on.
    @Test("D2 — the factor-1 kernel is EXACTLY a unit impulse at its centre: a pure delay")
    func factorOneDegeneratesToAPureDelay() {
        let taps = OversamplerDesign.kernel(factor: 1)
        let centre = (taps.count - 1) / 2
        #expect(centre == OversamplerDesign.tapsPerPhase / 2)
        #expect(taps[centre] == 1.0, "centre tap is \(taps[centre]), not exactly 1")
        var worstOffCentre = 0.0
        for index in 0..<taps.count where index != centre {
            worstOffCentre = max(worstOffCentre, abs(taps[index]))
        }
        // Not "== 0": `sin(k*pi)` is not exactly 0 in double precision. It is
        // below the float epsilon by ten orders of magnitude, which is what the
        // claim actually needs.
        #expect(worstOffCentre < 1e-16,
                "worst off-centre tap is \(worstOffCentre) — factor 1 is not a pure delay")
        print("[measured] factor-1 kernel: centre tap \(taps[centre]), "
              + "worst off-centre |tap| \(worstOffCentre)")
    }

    // MARK: - D3/D4: the quality numbers

    @Test("D3 — passband ripple is within the constant, at every factor")
    func passbandRippleMatchesTheConstant() {
        for factor in [2, 4] {
            let taps = OversamplerDesign.kernel(factor: factor)
            let ripple = Self.passbandRipple(
                taps, factor: factor, edge: OversamplerDesign.passbandEdgeFraction)
            print("[measured] factor \(factor) passband ripple over "
                  + "[0, \(OversamplerDesign.passbandEdgeFraction)·fs]: \(ripple) dB")
            #expect(abs(ripple) <= OversamplerDesign.passbandRippleDb, Comment(rawValue:
                    "factor \(factor) ripple \(ripple) dB exceeds the declared "
                    + "\(OversamplerDesign.passbandRippleDb) dB"))
        }
    }

    @Test("D4 — stopband rejection is at least the constant, at every factor")
    func stopbandMatchesTheConstant() {
        for factor in [2, 4] {
            let taps = OversamplerDesign.kernel(factor: factor)
            let peak = Self.stopbandPeak(
                taps, factor: factor, edge: OversamplerDesign.stopbandEdgeFraction)
            print("[measured] factor \(factor) stopband peak over "
                  + "[\(OversamplerDesign.stopbandEdgeFraction)·fs, \(factor)/2·fs]: \(peak) dB")
            #expect(peak <= OversamplerDesign.stopbandAttenuationDb, Comment(rawValue:
                    "factor \(factor) stopband peak \(peak) dB is above the declared "
                    + "\(OversamplerDesign.stopbandAttenuationDb) dB"))
        }
    }

    /// ⛔⛔ THE LEG THAT MAKES D3/D4 EVIDENCE. A rectangular window (β = 0) is a
    /// perfectly valid lowpass and a TERRIBLE one — Gibbs ringing puts its first
    /// sidelobe about 21 dB down. If the measurement above cannot tell it from
    /// the shipped kernel, the measurement is not measuring.
    @Test("D4b — POSITIVE CONTROL: the same measurement REJECTS a rectangular-window kernel")
    func theStopbandMeasurementCanFail() {
        for factor in [2, 4] {
            let bad = Self.kernel(factor: factor, beta: 0)
            let peak = Self.stopbandPeak(
                bad, factor: factor, edge: OversamplerDesign.stopbandEdgeFraction)
            print("[control] factor \(factor) RECTANGULAR-window stopband peak: \(peak) dB")
            #expect(peak > OversamplerDesign.stopbandAttenuationDb, Comment(rawValue:
                    "a rectangular window measured \(peak) dB, i.e. it PASSED the shipped "
                    + "kernel's stopband claim — the measurement cannot tell good from bad"))
            // …and it must be bad by a LOT, not by a hair. MEASURED: −29.39 dB
            // at 2× and −30.10 dB at 4× — the textbook ~21 dB first sidelobe of
            // a rectangular window, pushed a little lower by the stopband edge
            // sitting past the first lobe. The bound is −35 so the leg cannot
            // flicker on a grid change while still being 45 dB away from the
            // shipped kernel's −80.8.
            #expect(peak > -35, "rectangular-window peak \(peak) dB is implausibly good")
        }
        // The control's own control: the SHIPPED β must still pass the same
        // helper, so the difference above is the kernel and not the helper.
        let good = Self.kernel(factor: 4, beta: OversamplerDesign.kaiserBeta)
        let goodPeak = Self.stopbandPeak(
            good, factor: 4, edge: OversamplerDesign.stopbandEdgeFraction)
        #expect(goodPeak <= OversamplerDesign.stopbandAttenuationDb)
    }

    // MARK: - D5: the delay arithmetic

    /// ⛔ The invariance the whole latency contract rests on (`OversamplerDesign`
    /// §3). Asserted as ARITHMETIC over every factor, not as a single constant,
    /// so a future factor that broke it could not be added silently.
    @Test("D5 — up + down is M base-rate samples at EVERY supported factor")
    func roundTripDelayIsFactorIndependent() {
        let m = OversamplerDesign.tapsPerPhase
        #expect(m % 2 == 0, "an odd M would make the per-stage delay a half sample")
        for factor in OversamplerDesign.supportedFactors {
            let length = OversamplerDesign.kernelLength(factor: factor)
            // Group delay of a type-I linear-phase FIR, in OVERSAMPLED samples.
            let stageOversampled = (length - 1) / 2
            #expect((length - 1) % 2 == 0)
            #expect(stageOversampled % factor == 0, Comment(rawValue:
                    "factor \(factor): \(stageOversampled) oversampled samples is not a whole "
                    + "number of base-rate samples"))
            let stageBase = stageOversampled / factor
            #expect(stageBase * 2 == m,
                    "factor \(factor): round trip is \(stageBase * 2) base samples, not \(m)")
        }
        #expect(OversamplerDesign.latencySamples == m)
        #expect(ClipperParams.latencySamples == m)
        #expect(OversamplerDesign.maxFactor == 4)
    }

    // MARK: - D6: the window's own arithmetic

    @Test("D6 — besselI0 matches its published values")
    func besselMatchesPublishedValues() {
        // Abramowitz & Stegun 9.8.1 territory; these are the standard values.
        #expect(abs(OversamplerDesign.besselI0(0) - 1.0) < 1e-15)
        #expect(abs(OversamplerDesign.besselI0(1) - 1.2660658777520084) < 1e-12)
        #expect(abs(OversamplerDesign.besselI0(2) - 2.2795853023360673) < 1e-12)
        #expect(abs(OversamplerDesign.besselI0(8) - 427.5641157218048) < 1e-9)
        // β itself, the value the shipped window divides by.
        #expect(OversamplerDesign.besselI0(OversamplerDesign.kaiserBeta) > 0)
    }

    // MARK: - D7: the band edges mean what §5 says they mean

    @Test("D7 — the passband and stopband edges mirror about fs/2, which is what protects the band")
    func theEdgesMirror() {
        // `OversamplerDesign` §5: content in [fs/2, (1−fp)·fs] folds ABOVE the
        // passband edge and is already given up; only content above
        // (1−fp)·fs reaches the protected band. That argument is only true if
        // the stopband starts at or below (1 − passbandEdge)·fs.
        #expect(OversamplerDesign.stopbandEdgeFraction
                <= 1 - OversamplerDesign.passbandEdgeFraction + 1e-12)
        #expect(OversamplerDesign.passbandEdgeFraction < 0.5)
        #expect(OversamplerDesign.stopbandEdgeFraction > 0.5)
        // And the protected band in Hz at the two rates this app runs at,
        // printed rather than asserted — a session-rate-dependent claim that
        // nobody has to re-derive from a fraction.
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            print("[measured] at \(rate) Hz: alias-protected band is "
                  + "0 … \((1 - OversamplerDesign.stopbandEdgeFraction) * rate) Hz")
        }
    }
}
