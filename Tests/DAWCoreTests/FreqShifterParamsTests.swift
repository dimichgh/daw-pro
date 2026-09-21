import Foundation
import Testing
@testable import DAWCore

/// m39-z — `FreqShifterParams`: the clamping laws, the coarse+fine sum, the
/// down-fold law, and **the two legs that make the shipped Hilbert network's
/// quality number falsifiable instead of decorative**.
///
/// ⭐⭐ **LAW 1 IS THE POINT OF THIS FILE.** `worstPhaseErrorDeg` and
/// `sidebandRejectionDb` could each be a plausible-looking literal that nothing
/// checks — this tree's named characteristic failure. Law 1 therefore
/// **re-derives the phase response FROM `hilbertI`/`hilbertQ`**, in the
/// frequency domain, on a dense grid, using arithmetic that shares no code with
/// the render path. If somebody edits a coefficient, or reorders the two
/// branches, or drops the extra `z⁻¹`, the declared figure stops matching the
/// coefficients and this reddens.
///
/// ⚠️ It is a SECOND INSTRUMENT, not the only one: `FreqShifterTests` measures
/// the same quantity end-to-end off rendered audio with a Goertzel probe. Two
/// independent instruments agreeing is the evidence; either alone is not.
@Suite("m39-z — FreqShifterParams laws")
struct FreqShifterParamsTests {

    // MARK: - Law 1: the network's phase error, re-derived from the coefficients

    /// One first-order all-pass in z⁻², evaluated on the unit circle:
    /// `H(z) = (a − z⁻²)/(1 − a·z⁻²)`. Complex arithmetic written out by hand so
    /// this shares nothing with the render path's difference equation.
    private static func sectionPhase(_ a: Double, _ omega: Double) -> (re: Double, im: Double) {
        // z⁻² = cos(2ω) − i·sin(2ω)
        let c = cos(2 * omega), s = -sin(2 * omega)
        let numRe = a - c, numIm = -s
        let denRe = 1 - a * c, denIm = -a * s
        let d = denRe * denRe + denIm * denIm
        return ((numRe * denRe + numIm * denIm) / d, (numIm * denRe - numRe * denIm) / d)
    }

    private static func branch(_ coefficients: [Double], _ omega: Double,
                               extraDelay: Bool) -> (re: Double, im: Double) {
        var re = 1.0, im = 0.0
        for a in coefficients {
            let h = sectionPhase(a, omega)
            let r = re * h.re - im * h.im
            im = re * h.im + im * h.re
            re = r
        }
        if extraDelay {  // multiply by z⁻¹ = cos ω − i sin ω
            let c = cos(omega), s = -sin(omega)
            let r = re * c - im * s
            im = re * s + im * c
            re = r
        }
        return (re, im)
    }

    /// |∠I − ∠Q| − 90°, in degrees, at a given normalised frequency `f/fs`.
    private static func phaseErrorDeg(atFraction x: Double) -> Double {
        let omega = 2 * Double.pi * x
        let i = branch(FreqShifterParams.hilbertI, omega, extraDelay: true)
        let q = branch(FreqShifterParams.hilbertQ, omega, extraDelay: false)
        // arg(I / Q)
        let re = i.re * q.re + i.im * q.im
        let im = i.im * q.re - i.re * q.im
        let deg = atan2(im, re) * 180 / Double.pi
        return abs(abs(deg) - 90)
    }

    @Test("Law 1 — the DECLARED phase error is what the SHIPPED coefficients actually deliver")
    func declaredPhaseErrorMatchesTheCoefficients() {
        let lo = FreqShifterParams.designBandLowFraction
        let hi = FreqShifterParams.designBandHighFraction
        var worst = 0.0
        var worstAt = 0.0
        let steps = 20_000
        for step in 0...steps {
            let x = lo * pow(hi / lo, Double(step) / Double(steps))
            let error = Self.phaseErrorDeg(atFraction: x)
            if error > worst { worst = error; worstAt = x }
        }
        print("[measured] Hilbert pair worst phase error \(worst) deg at f/fs \(worstAt) "
              + "-> rejection \(20 * log10(tan(worst * Double.pi / 180 / 2))) dB")
        // Tight both ways. TOO LOW would mean the constant is pessimistic and
        // the effect is better than advertised — still a disagreement between
        // the record and the source, which is the failure this suite exists for.
        #expect(worst <= FreqShifterParams.worstPhaseErrorDeg + 0.005, """
            the shipped coefficients are WORSE (\(worst) deg) than the declared \
            \(FreqShifterParams.worstPhaseErrorDeg) deg — the quality number has rotted
            """)
        #expect(worst >= FreqShifterParams.worstPhaseErrorDeg - 0.05, """
            the shipped coefficients are BETTER (\(worst) deg) than declared — update the \
            constant rather than leaving the record stale
            """)
    }

    /// ⛔ ANTI-VACUITY. A phase probe that returns ~0 for everything would pass
    /// Law 1 by accident. This proves the probe can SEE a bad network: strip the
    /// extra `z⁻¹` — the single most likely thing for an implementer to leave
    /// out, since it looks like plumbing rather than filter design — and watch
    /// the error explode.
    ///
    /// ⭐ MEASURED, AND THE NUMBER IS EXACTLY PREDICTABLE, WHICH IS WHY THIS
    /// PROBE IS TRUSTWORTHY: one sample of delay is `360·(f/fs)` degrees of
    /// phase, so dropping it costs **18° at f/fs 0.05 and exactly 90° at
    /// f/fs 0.25**. The first draft of this leg asserted `> 45` at f/fs 0.05 and
    /// reddened at the true 18.357° — the assertion was wrong, not the network.
    /// Evaluating where the delay is worth a full quarter cycle makes the
    /// control both maximal and arithmetically checkable.
    @Test("Law 1b — POSITIVE CONTROL: the phase probe reddens on a network it should reject")
    func thePhaseProbeCanSeeABrokenNetwork() {
        let fraction = 0.25  // 12 kHz at 48 kHz; one sample = exactly 90 deg
        let omega = 2 * Double.pi * fraction
        let correct = Self.phaseErrorDeg(atFraction: fraction)
        // Same two branches, but WITHOUT the extra one-sample delay.
        let i = Self.branch(FreqShifterParams.hilbertI, omega, extraDelay: false)
        let q = Self.branch(FreqShifterParams.hilbertQ, omega, extraDelay: false)
        let re = i.re * q.re + i.im * q.im
        let im = i.im * q.re - i.re * q.im
        let broken = abs(abs(atan2(im, re) * 180 / Double.pi) - 90)
        print("[measured] at f/fs \(fraction): with z^-1 \(correct) deg; WITHOUT it \(broken) deg")
        #expect(correct < 1.0)
        // Without the delay the branches are nearly IN PHASE, so the deviation
        // from 90 deg is itself nearly 90 deg.
        #expect(broken > 80, "the probe cannot tell a quadrature pair from a non-quadrature one")
        // And the degradation in the thing that actually matters.
        #expect(20 * log10(tan(broken * Double.pi / 180 / 2)) > -6,
                "dropping z^-1 must destroy the sideband rejection, and this probe must see it")
    }

    // MARK: - Law 2: the rejection figure is DERIVED, not asserted

    @Test("Law 2 — sidebandRejectionDb is tan(eps/2) of the phase error, re-derived independently")
    func rejectionIsDerivedFromThePhaseError() {
        let eps = FreqShifterParams.worstPhaseErrorDeg * Double.pi / 180
        let expected = 20 * log10(tan(eps / 2))
        #expect(abs(FreqShifterParams.sidebandRejectionDb - expected) < 1e-12)
        // The number itself, pinned so a coefficient change that moved it has
        // to be noticed rather than absorbed.
        print("[measured] sidebandRejectionDb = \(FreqShifterParams.sidebandRejectionDb)")
        #expect(FreqShifterParams.sidebandRejectionDb < -45)
        #expect(FreqShifterParams.sidebandRejectionDb > -55)
        // ⚠️ `tan(x/2)` is NOT `sin(x)` and NOT `x/2`, but at 0.38 deg all three
        // agree to ~0.01 dB — which is exactly why a wrong one would look
        // right and why the demo gate measures this off a rendered wav.
        let naive = 20 * log10(eps / 2)
        #expect(abs(naive - expected) < 0.01,
                "if these ever diverge, the note in FreqShifterParams needs rewording")
    }

    @Test("the two branches are the same length and the coefficient set is non-trivial")
    func coefficientSetIsWellFormed() {
        #expect(FreqShifterParams.hilbertI.count == 5)
        #expect(FreqShifterParams.hilbertQ.count == 5)
        // Every pole radius strictly inside the unit circle — a coefficient at
        // or beyond 1 is an UNSTABLE section, and it would ring forever rather
        // than sound wrong.
        for a in FreqShifterParams.hilbertI + FreqShifterParams.hilbertQ {
            #expect(a > 0 && a < 1, "coefficient \(a) is outside (0, 1) — unstable section")
        }
        // Strictly increasing within each branch, and INTERLEAVED across them:
        // that is the polyphase structure, and a sorted-wrong set would still
        // be stable while destroying the quadrature.
        #expect(FreqShifterParams.hilbertI == FreqShifterParams.hilbertI.sorted())
        #expect(FreqShifterParams.hilbertQ == FreqShifterParams.hilbertQ.sorted())
        for index in 0..<5 {
            #expect(FreqShifterParams.hilbertQ[index] < FreqShifterParams.hilbertI[index],
                    "branch coefficients are no longer interleaved at index \(index)")
            if index + 1 < 5 {
                #expect(FreqShifterParams.hilbertI[index]
                        < FreqShifterParams.hilbertQ[index + 1])
            }
        }
    }

    @Test("the design band converts to Hz and moves with the sample rate")
    func designBandScalesWithRate() {
        let at48 = FreqShifterParams.designBandHz(sampleRate: 48_000)
        #expect(abs(at48.low - 9.6) < 1e-9)
        #expect(abs(at48.high - 23_990.4) < 1e-6)
        // ⚠️ The band is NORMALISED, so a 96 kHz session's low corner is twice
        // as high — 19.2 Hz, which only just covers the audio band. That is a
        // real, stated limitation and this pins it rather than hiding it.
        let at96 = FreqShifterParams.designBandHz(sampleRate: 96_000)
        #expect(abs(at96.low - 19.2) < 1e-9)
        #expect(at96.low > at48.low)
        // Non-finite / non-positive rates return a degenerate band rather than
        // propagating a NaN into anything that formats it.
        #expect(FreqShifterParams.designBandHz(sampleRate: 0).low == 0)
        #expect(FreqShifterParams.designBandHz(sampleRate: .nan).high == 0)
    }

    // MARK: - The coarse + fine sum

    @Test("effectiveShiftHz sums the two knobs and clamps the SUM to the coarse range")
    func effectiveShiftSumsAndClamps() {
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: 100, fineHz: 5) == 105)
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: -100, fineHz: -5) == -105)
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: 250, fineHz: -7.5) == 242.5)
        // ⛔ THE CLAMP THAT KEEPS `fx.describe` HONEST. Without it the real
        // range would be +/-2020 Hz while the advertised one is +/-2000.
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: 2_000, fineHz: 20) == 2_000)
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: -2_000, fineHz: -20) == -2_000)
        // Out-of-range inputs are clamped BEFORE the sum, so a wild coarse
        // value cannot drag a legal fine value out with it.
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: 9_999, fineHz: -20) == 1_980)
        // Non-finite is "no answer", not "very large".
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: .nan, fineHz: 5) == 5)
        #expect(FreqShifterParams.effectiveShiftHz(shiftHz: 100, fineHz: .infinity) == 100)
    }

    // MARK: - The fold law

    @Test("shiftedHz IS the effect, and a downward shift past 0 Hz REFLECTS")
    func shiftedHzFolds() {
        // The headline example: a harmonic series stops being one.
        #expect(FreqShifterParams.shiftedHz(inputHz: 100, effectiveShiftHz: 100) == 200)
        #expect(FreqShifterParams.shiftedHz(inputHz: 200, effectiveShiftHz: 100) == 300)
        #expect(FreqShifterParams.shiftedHz(inputHz: 300, effectiveShiftHz: 100) == 400)
        // ⭐ 200/300/400 is NOT a harmonic series: the ratios have changed from
        // 1:2:3 to 1:1.5:2. That is the whole effect, asserted rather than
        // described.
        let shifted = [100.0, 200, 300].map {
            FreqShifterParams.shiftedHz(inputHz: $0, effectiveShiftHz: 100)
        }
        #expect(shifted[1] / shifted[0] != 200.0 / 100.0)
        // …and a PITCH shifter would have preserved them, which is the contrast
        // that makes the kind distinct.
        let pitched = [100.0, 200, 300].map { $0 * 2 }
        #expect(pitched[1] / pitched[0] == 200.0 / 100.0)
        // The fold.
        #expect(FreqShifterParams.shiftedHz(inputHz: 100, effectiveShiftHz: -300) == 200)
        #expect(FreqShifterParams.shiftedHz(inputHz: 250, effectiveShiftHz: -250) == 0)
        #expect(FreqShifterParams.shiftedHz(inputHz: .nan, effectiveShiftHz: 10) == 0)
    }

    // MARK: - Clamping, defaults and decoding

    @Test("init clamps every field to its declared range")
    func initClamps() {
        let high = FreqShifterParams(shiftHz: 9_999, fineHz: 500, stereoSpreadHz: 500,
                                     mix: 4, outputDb: 99)
        #expect(high.shiftHz == 2_000)
        #expect(high.fineHz == 20)
        #expect(high.stereoSpreadHz == 20)
        #expect(high.mix == 1)
        #expect(high.outputDb == 24)
        let low = FreqShifterParams(shiftHz: -9_999, fineHz: -500, stereoSpreadHz: -500,
                                    mix: -4, outputDb: -99)
        #expect(low.shiftHz == -2_000)
        #expect(low.fineHz == -20)
        #expect(low.stereoSpreadHz == -20)
        #expect(low.mix == 0)
        #expect(low.outputDb == -24)
    }

    /// ⛔ A NaN reaching the phase accumulator is UNRECOVERABLE — every later
    /// sample is NaN and the strip is silenced permanently.
    @Test("non-finite fields fall back to the default rather than propagating")
    func nonFiniteFieldsFallBack() {
        let p = FreqShifterParams(shiftHz: .nan, fineHz: .infinity,
                                  stereoSpreadHz: -.infinity, mix: .nan, outputDb: .nan)
        #expect(p.shiftHz == 0)
        #expect(p.fineHz == 0)
        #expect(p.stereoSpreadHz == 0)
        #expect(p.mix == 0.5)
        #expect(p.outputDb == 0)
    }

    @Test("defaults, and a partial JSON object decodes with per-field defaults")
    func defaultsAndPartialDecoding() throws {
        let d = FreqShifterParams()
        #expect(d.shiftHz == 0)
        #expect(d.fineHz == 0)
        #expect(d.stereoSpreadHz == 0)
        #expect(d.mix == 0.5)
        #expect(d.outputDb == 0)

        let partial = Data(#"{"shiftHz": 440}"#.utf8)
        let decoded = try JSONDecoder().decode(FreqShifterParams.self, from: partial)
        #expect(decoded.shiftHz == 440)
        #expect(decoded.mix == 0.5, "a missing field must take its DEFAULT, not zero")
        #expect(decoded.fineHz == 0)

        // Out-of-range values in the FILE route through the clamping init too.
        let wild = Data(#"{"shiftHz": 1e9, "mix": -3}"#.utf8)
        let clamped = try JSONDecoder().decode(FreqShifterParams.self, from: wild)
        #expect(clamped.shiftHz == 2_000)
        #expect(clamped.mix == 0)

        // Round trip.
        let original = FreqShifterParams(shiftHz: -347.5, fineHz: -6.25,
                                         stereoSpreadHz: 3.75, mix: 0.83, outputDb: -5.5)
        let back = try JSONDecoder().decode(
            FreqShifterParams.self, from: try JSONEncoder().encode(original))
        #expect(back == original)
    }

    // MARK: - The spec table

    @Test("the spec table is FROZEN in order and matches the ranges and defaults")
    func specTableIsFrozen() {
        let specs = EffectParamSpec.specs(for: .freqShifter)
        // ⛔ THE INDEX IS THE AUTOMATION SLOT, PERMANENTLY. Asserted as a list,
        // because a count cannot see a swap.
        #expect(specs.map(\.name) == ["shiftHz", "fineHz", "stereoSpreadHz", "mix", "outputDb"])
        #expect(specs.map(\.unit) == ["Hz", "Hz", "Hz", "linear", "dB"])
        #expect(specs.map(\.defaultValue) == [0, 0, 0, 0.5, 0])
        #expect(specs.allSatisfy { $0.curve == .linear },
                "every range here crosses or touches 0, so .logarithmic is structurally invalid")
        #expect(specs[0].range == FreqShifterParams.shiftHzRange)
        #expect(specs[1].range == FreqShifterParams.fineHzRange)
        #expect(specs[2].range == FreqShifterParams.stereoSpreadHzRange)
        #expect(specs[3].range == FreqShifterParams.mixRange)
        #expect(specs[4].range == FreqShifterParams.outputDbRange)
        // Every default is inside its own range and equals the struct default.
        let d = FreqShifterParams()
        #expect(specs[0].defaultValue == d.shiftHz)
        #expect(specs[3].defaultValue == d.mix)
        for spec in specs {
            #expect(spec.range.contains(spec.defaultValue))
            #expect(spec.note?.isEmpty == false, "\(spec.name) ships with no teaching note")
        }
        // ⛔ NO note may claim `fx.describe` carries the derived per-instance
        // fields — it does not, and that exact false claim shipped in three
        // places at once on 2026-09-19.
        for spec in specs {
            #expect(spec.note?.contains("fx.describe") != true, """
                \(spec.name)'s note mentions fx.describe, which does not carry derived fields
                """)
        }
    }

    /// The `paramValue(named:)` read-back arm — every name in the table must be
    /// reachable, or `fx.setParam` writes somewhere `project.snapshot` cannot
    /// read back.
    @Test("every spec name reads back through paramValue(named:)")
    func everySpecNameReadsBack() {
        let params = FreqShifterParams(shiftHz: -347.5, fineHz: -6.25,
                                       stereoSpreadHz: 3.75, mix: 0.83, outputDb: -5.5)
        let effect = EffectDescriptor(kind: .freqShifter, freqShifter: params)
        #expect(effect.paramValue("shiftHz") == -347.5)
        #expect(effect.paramValue("fineHz") == -6.25)
        #expect(effect.paramValue("stereoSpreadHz") == 3.75)
        #expect(effect.paramValue("mix") == 0.83)
        #expect(effect.paramValue("outputDb") == -5.5)
        #expect(effect.paramValue("notAParam") == nil)
        for spec in EffectParamSpec.specs(for: .freqShifter) {
            #expect(effect.paramValue(spec.name) != nil,
                    "\(spec.name) is in the spec table but has no paramValue arm")
        }
    }
}
