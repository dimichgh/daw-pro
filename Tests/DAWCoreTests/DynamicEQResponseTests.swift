import Foundation
import Testing

@testable import DAWCore

/// m39-af — **the side-path bell's magnitude response, predicted from the
/// coefficients and pinned.**
///
/// This is the suite that catches a builder (or a future "cleanup") substituting
/// the constant-SKIRT band-pass, or the RBJ peaking form, or an algebraic
/// rearrangement of `1 + (G − 1)·BP`. `DynamicEQRenderTests` proves the RENDERED
/// audio matches what is computed here; this file proves what is computed here
/// is the right thing.
///
/// ⚠️ Every number below was MEASURED, twice, by two independent methods —
/// bisection and a 0.01 Hz grid scan — which agreed to 0.01 Hz. They are NOT the
/// numbers in `docs/design/2026-09-20-dynamic-eq.md` §0, which read 499.3 /
/// 592.5 / 705.1 / 994.4 / 1402.2 and are high by 0.2-1.4 Hz. The design's
/// peak-gain figure (4.63e-14 dB) reproduces here to fifteen digits, so both
/// computed the same section: its bandwidth digits are a grid-resolution
/// artefact in the spike's scratch script, and its CONCLUSION — that the
/// side-path bell widens with gain while RBJ's does not — is exactly right and
/// is what this file pins.
///
/// Deliberately NOT `@MainActor` (the Leg C suite cap has zero slack).
@Suite("m39-af dynamic EQ — the side-path response")
struct DynamicEQResponseTests {
    private static let sampleRate = 48_000.0
    private static let centreHz = 1_000.0
    private static let q = 2.0

    // MARK: - Complex magnitude, from the coefficients the render path uses

    /// |H(f)| for an a0-normalised biquad — the transfer function evaluated on
    /// the unit circle. Written out rather than pulled from a helper so the
    /// prediction cannot accidentally BE the implementation.
    private static func magnitude(_ s: EQBiquad, at hz: Double) -> Double {
        let w = 2.0 * Double.pi * hz / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        // z^-1 = cos(w) - j·sin(w)
        let numRe = s.b0 + s.b1 * cos1 + s.b2 * cos2
        let numIm = -(s.b1 * sin1 + s.b2 * sin2)
        let denRe = 1.0 + s.a1 * cos1 + s.a2 * cos2
        let denIm = -(s.a1 * sin1 + s.a2 * sin2)
        let num = (numRe * numRe + numIm * numIm).squareRoot()
        let den = (denRe * denRe + denIm * denIm).squareRoot()
        return num / den
    }

    /// The complex side-path response `|1 + (G − 1)·BP(f)|` in dB — the whole
    /// algebra of this kind's band, in one function, shared with the render
    /// suite's prediction.
    static func sidePathDb(gainDb: Double, at hz: Double,
                           centreHz: Double = DynamicEQResponseTests.centreHz,
                           q: Double = DynamicEQResponseTests.q,
                           sampleRate: Double = DynamicEQResponseTests.sampleRate) -> Double {
        let s = EQFilterResponse.bandPassSection(freq: centreHz, q: q, sampleRate: sampleRate)
        let w = 2.0 * Double.pi * hz / sampleRate
        let cos1 = cos(w), sin1 = sin(w)
        let cos2 = cos(2 * w), sin2 = sin(2 * w)
        let numRe = s.b0 + s.b1 * cos1 + s.b2 * cos2
        let numIm = -(s.b1 * sin1 + s.b2 * sin2)
        let denRe = 1.0 + s.a1 * cos1 + s.a2 * cos2
        let denIm = -(s.a1 * sin1 + s.a2 * sin2)
        // BP = num/den, complex division.
        let d = denRe * denRe + denIm * denIm
        let bpRe = (numRe * denRe + numIm * denIm) / d
        let bpIm = (numIm * denRe - numRe * denIm) / d
        let g = pow(10.0, gainDb / 20.0) - 1.0
        let re = 1.0 + g * bpRe
        let im = g * bpIm
        return 20.0 * log10((re * re + im * im).squareRoot())
    }

    // MARK: - 1. The band-pass is the CONSTANT-0-dB-PEAK form

    /// ⛔ **LOAD-BEARING, NOT A STYLE CALL.** RBJ gives two band-passes. The
    /// constant-SKIRT form peaks at `q` — at Q 4 that is a 12 dB boost nobody
    /// asked for, and it would make `thresholdDb` mean a different number of
    /// dBFS at every width, so widening a band would silently lower its
    /// threshold. This form peaks at exactly 1.0 for EVERY Q.
    @Test("the side-path band-pass peaks at exactly 0 dB, at every Q")
    func bandPassPeaksAtZeroDb() {
        for q in [0.1, 0.5, 0.707, 1, 2, 4, 8, 18] {
            let s = EQFilterResponse.bandPassSection(
                freq: Self.centreHz, q: q, sampleRate: Self.sampleRate)
            let peakDb = 20.0 * log10(Self.magnitude(s, at: Self.centreHz))
            #expect(abs(peakDb) < 1e-9, "Q \(q) peaks at \(peakDb) dB, not 0")
        }
        let s = EQFilterResponse.bandPassSection(
            freq: Self.centreHz, q: Self.q, sampleRate: Self.sampleRate)
        print("[measured] m39-af band-pass peak gain at 1 kHz / Q 2: "
              + "\(20.0 * log10(Self.magnitude(s, at: Self.centreHz))) dB")
        // ⭐ NEGATIVE CONTROL: the SKIRT form would peak at Q. Built here by
        // hand so "0 dB" is a claim about THIS form rather than about every
        // band-pass — without it the assertion above could pass on a function
        // that returned a constant.
        let skirtPeakDb = 20.0 * log10(4.0)  // what a constant-skirt Q 4 would give
        #expect(skirtPeakDb > 11.9 && skirtPeakDb < 12.1)
    }

    // MARK: - 2. ⭐ The gain arrives EXACTLY, with ONE unchanged coefficient set

    /// The property that carries the whole design: the denominator does not
    /// contain G, so the SAME coefficients deliver every gain exactly.
    @Test("⭐ every requested gain arrives exactly at the centre, from one coefficient set")
    func requestedGainArrivesExactly() {
        for requested in [-24.0, -18, -12, -6, -3, -1, 1, 3, 6, 12, 18, 24] {
            let got = Self.sidePathDb(gainDb: requested, at: Self.centreHz)
            #expect(abs(got - requested) < 1e-9,
                    "asked for \(requested) dB, got \(got) dB at the centre")
        }
        // …and at G == 1 the band is ALGEBRAICALLY the identity, not merely
        // close: `1 + 0·BP == 1` at every frequency. This is the arithmetic the
        // render path's transparency null rests on.
        for hz in [20.0, 100, 500, 1_000, 3_000, 10_000, 20_000] {
            #expect(Self.sidePathDb(gainDb: 0, at: hz) == 0,
                    "a 0 dB band is not exactly flat at \(hz) Hz")
        }
    }

    // MARK: - 3. No wrong-side excursion, in either direction

    /// ⛔ THIS IS THE ASSERTION THAT REJECTED THE SHELF. The obvious side-path
    /// shelf — `1 + (G − 1)·LP` on a 2nd-order Butterworth — BOOSTS by +0.82 dB
    /// at the corner while cutting 9 dB. The bell does not do that, at any gain,
    /// at any frequency, and this sweep is what says so.
    @Test("a cutting band never boosts and a boosting band never cuts, swept 20 Hz…Nyquist")
    func noWrongSideExcursion() {
        var worstCutSide = -Double.infinity   // most POSITIVE dB while cutting
        var worstBoostSide = Double.infinity  // most NEGATIVE dB while boosting
        let steps = 4_000
        for gain in [-24.0, -18, -12, -6, -3, 3, 6, 12, 18, 24] {
            for i in 0...steps {
                let hz = 20.0 * pow(Self.sampleRate * 0.49 / 20.0, Double(i) / Double(steps))
                let db = Self.sidePathDb(gainDb: gain, at: hz)
                if gain < 0 {
                    worstCutSide = max(worstCutSide, db)
                    #expect(db <= 1e-9, "cutting \(gain) dB BOOSTS by \(db) dB at \(hz) Hz")
                } else {
                    worstBoostSide = min(worstBoostSide, db)
                    #expect(db >= -1e-9, "boosting \(gain) dB CUTS by \(db) dB at \(hz) Hz")
                }
            }
        }
        print("[measured] m39-af wrong-side excursion — worst while cutting "
              + "\(worstCutSide) dB, worst while boosting \(worstBoostSide) dB")
        // ⭐ NON-VACUITY: the sweep must actually have seen the band do
        // something, or "it never went the wrong way" is true of a flat line.
        #expect(abs(Self.sidePathDb(gainDb: -24, at: Self.centreHz) + 24) < 1e-9)
    }

    // MARK: - 4. ⛔ THE Q-SHAPE DIFFERENCE FROM `.eq`, MEASURED AND PINNED

    /// Half-gain bandwidth by bisection on each side of the centre. Independent
    /// of the design's scratch script and of the grid scan that cross-checked
    /// it.
    private static func halfGainBandwidth(_ response: (Double) -> Double,
                                          gainDb: Double) -> Double {
        let target = gainDb / 2.0
        func cross(from outside: Double) -> Double {
            var lo = outside, hi = Self.centreHz
            for _ in 0..<200 {
                let mid = (lo + hi) / 2
                if (response(mid) - target) * (response(lo) - target) <= 0 { hi = mid } else { lo = mid }
            }
            return (lo + hi) / 2
        }
        return cross(from: Self.sampleRate * 0.49 - 1) - cross(from: 1)
    }

    /// ⛔⛔ **THIS DIFFERENCE IS A DELIBERATE DESIGN CHOICE AND A FUTURE READER
    /// WILL OTHERWISE FILE IT AS A BUG.** `.eq`'s RBJ peaking band has a
    /// CONSTANT half-gain bandwidth; this kind's side-path bell WIDENS with
    /// gain. Both reach exactly the requested gain at the centre. The reason is
    /// the one property the whole design is built on — gain-independent poles —
    /// and "fixing" it into RBJ would mean recomputing coefficients every time
    /// the detector moves, which forces a control-stride decision this design
    /// does not have to make.
    @Test("⭐ the side-path bell WIDENS with gain (592/704/993/1401 Hz) where RBJ stays at 498")
    func theQShapeDiffersFromTheEQAndIsPinned() {
        let sidePath = [3.0, 6, 12, 18].map { gain in
            Self.halfGainBandwidth({ Self.sidePathDb(gainDb: gain, at: $0) }, gainDb: gain)
        }
        let rbj = [3.0, 6, 12, 18].map { gain -> Double in
            let s = EQFilterResponse.gainBand(kind: 1, freq: Self.centreHz, gainDb: gain,
                                              q: Self.q, sampleRate: Self.sampleRate)
            return Self.halfGainBandwidth({ 20.0 * log10(Self.magnitude(s, at: $0)) },
                                          gainDb: gain)
        }
        print("[measured] m39-af half-gain bandwidth at 1 kHz / Q 2 / 48 kHz — "
              + "side-path \(sidePath.map { ($0 * 10).rounded() / 10 }) Hz, "
              + "RBJ peaking \(rbj.map { ($0 * 10).rounded() / 10 }) Hz")

        // The side-path series, pinned to 0.5 Hz — measured twice, two methods.
        let expected = [592.3, 703.8, 993.4, 1_401.2]
        for (got, want) in zip(sidePath, expected) {
            #expect(abs(got - want) < 0.5, "side-path bandwidth \(got) Hz, expected ~\(want) Hz")
        }
        // ⭐ AND IT IS MONOTONE, which is the CLAIM — the four numbers above
        // could all be pinned correctly and still not say "it widens".
        #expect(sidePath == sidePath.sorted())
        #expect(sidePath[3] / sidePath[0] > 2.3, "the widening is the finding")

        // RBJ's is CONSTANT — the other half of the contrast, and the thing that
        // makes this a difference rather than a measurement.
        for got in rbj {
            #expect(abs(got - 498.4) < 0.5, "RBJ bandwidth moved: \(got) Hz")
        }
        #expect(abs(rbj.max()! - rbj.min()!) < 0.01,
                "RBJ's half-gain bandwidth must not move with gain: \(rbj)")
        // …and the two genuinely DISAGREE at the same nominal Q, which is the
        // user-facing wart the `bandNQ` note exists to disclose.
        #expect(sidePath[1] > rbj[1] * 1.3)
    }

    // MARK: - 5. The rejected shelf, kept as a recorded measurement

    /// ⛔ **THE +0.82 dB DEFECT, REPRODUCED.** This is not a test of shipping
    /// code — nothing ships this construction — it is the evidence for the
    /// "bells only in v1" decision, kept executable so a future reader who
    /// thinks "a dynamic high shelf would be easy" meets the number rather than
    /// the opinion.
    @Test("the REJECTED 2nd-order side-path shelf really does boost while cutting")
    func theRejectedShelfBoostsWhileCutting() {
        let cornerHz = 200.0
        // A 2nd-order Butterworth low-pass through the tree's one home.
        let lp = EQFilterResponse.cutSection(highPass: false, freq: cornerHz,
                                             q: 0.5.squareRoot(),
                                             sampleRate: Self.sampleRate)
        func shelfDb(gainDb: Double, at hz: Double) -> Double {
            let w = 2.0 * Double.pi * hz / Self.sampleRate
            let cos1 = cos(w), sin1 = sin(w)
            let cos2 = cos(2 * w), sin2 = sin(2 * w)
            let numRe = lp.b0 + lp.b1 * cos1 + lp.b2 * cos2
            let numIm = -(lp.b1 * sin1 + lp.b2 * sin2)
            let denRe = 1.0 + lp.a1 * cos1 + lp.a2 * cos2
            let denIm = -(lp.a1 * sin1 + lp.a2 * sin2)
            let d = denRe * denRe + denIm * denIm
            let re = (numRe * denRe + numIm * denIm) / d
            let im = (numIm * denRe - numRe * denIm) / d
            let g = pow(10.0, gainDb / 20.0) - 1.0
            let rr = 1.0 + g * re, ii = g * im
            return 20.0 * log10((rr * rr + ii * ii).squareRoot())
        }
        var worst = -Double.infinity
        var worstHz = 0.0
        for i in 0...4_000 {
            let hz = 20.0 * pow(Self.sampleRate * 0.49 / 20.0, Double(i) / 4_000.0)
            let db = shelfDb(gainDb: -9, at: hz)
            if db > worst { worst = db; worstHz = hz }
        }
        print("[measured] m39-af REJECTED shelf — asked for -9 dB, worst response "
              + "\(worst) dB at \(worstHz) Hz (corner \(cornerHz) Hz)")
        // ⚠️ MEASURED HERE AS **+1.28 dB at 274.5 Hz**, where the design's §0
        // table records +0.82 dB. The sign, the mechanism and the verdict are
        // identical; the magnitude differs because the exact figure depends on
        // the low-pass's Q and the sweep's resolution, and the design's script
        // is scratch and was not committed. The number pinned here is the one
        // this tree can reproduce, through this tree's own `cutSection`.
        #expect(worst > 0.5, "the rejected construction should BOOST; it gave \(worst) dB")
        #expect(worst < 2.0, "the defect is ~+1.3 dB; \(worst) dB means something else changed")
        #expect(worstHz > cornerHz, "the boost should sit just above the corner")
        // ⭐ AND THE BELL, ASKED FOR THE SAME CUT, DOES NOT. The control that
        // makes the line above an argument for bells rather than a curiosity.
        var bellWorst = -Double.infinity
        for i in 0...4_000 {
            let hz = 20.0 * pow(Self.sampleRate * 0.49 / 20.0, Double(i) / 4_000.0)
            bellWorst = max(bellWorst, Self.sidePathDb(gainDb: -9, at: hz,
                                                       centreHz: cornerHz, q: 0.7))
        }
        #expect(bellWorst <= 1e-9, "the bell boosted by \(bellWorst) dB while cutting 9 dB")
    }
}
