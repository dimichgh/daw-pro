import Foundation
import Testing
@testable import DAWCore

/// m39-o — `PhaserParams`, the ONE HOME for every law the DSP, the wire and the
/// tests read. `docs/design/2026-09-19-creative-effects.md` §2.1 rank 7 is the
/// item; §6.0 is the contract.
///
/// ⭐ **The legs here are the ones that can be checked WITHOUT rendering, and
/// they are deliberately the ones that separate a phaser from a flanger on
/// paper.** `PhaserTests` (DAWEngineTests) then proves the rendered audio
/// actually obeys them, and runs the same notch-finder over BOTH kinds so
/// neither law can quietly be the other's.
///
/// This suite is NOT `@MainActor`: none of it touches main-actor state, and
/// `MainActorOccupancySiteTests` Leg C pins the isolated-suite count at its cap
/// with zero slack.
@Suite("PhaserParams — the non-harmonic notch laws (m39-o)")
struct PhaserParamsTests {

    // MARK: - The even-stage snap

    /// ⚠️ THE FIXTURE TRAP THIS LEG EXISTS TO DODGE: a snap test fed only EVEN
    /// inputs passes with the snap deleted. Every odd value in range is here,
    /// and so are both out-of-range ends and a NaN.
    @Test("stages snaps to the nearer EVEN count and the stored value is what is in force")
    func stagesSnapToEvenAcrossTheWholeSurface() {
        // Odd inputs — the case a clamp-only implementation gets wrong.
        // An odd value is an exact TIE, and the tie goes UP (Double.rounded()'s
        // "half away from zero"), which is a documented choice, not an accident.
        #expect(PhaserParams.snappedStages(3) == 4)
        #expect(PhaserParams.snappedStages(5) == 6)
        #expect(PhaserParams.snappedStages(7) == 8)
        #expect(PhaserParams.snappedStages(9) == 10)
        #expect(PhaserParams.snappedStages(11) == 12)
        // Fractional inputs round to the nearer even.
        #expect(PhaserParams.snappedStages(5.9) == 6)
        #expect(PhaserParams.snappedStages(6.1) == 6)
        #expect(PhaserParams.snappedStages(7.1) == 8)
        // Even inputs are fixed points.
        for even in [2.0, 4, 6, 8, 10, 12] {
            #expect(PhaserParams.snappedStages(even) == Int(even))
        }
        // Out of range clamps INTO range and stays even.
        #expect(PhaserParams.snappedStages(-50) == 2)
        #expect(PhaserParams.snappedStages(0) == 2)
        #expect(PhaserParams.snappedStages(1) == 2)
        #expect(PhaserParams.snappedStages(999) == 12)
        // Non-finite is "no answer", not "very large": both fall back to the
        // default, like every other law in this type.
        #expect(PhaserParams.snappedStages(.nan) == 6)
        #expect(PhaserParams.snappedStages(.infinity) == 6)
        #expect(PhaserParams.snappedStages(-.infinity) == 6)

        // The STORED value is the snapped one, so nothing downstream has to
        // keep its own copy of the rule (the RingModParams.waveform precedent).
        #expect(PhaserParams(stages: 7).stages == 8)
        #expect(PhaserParams(stages: 11).stages == 12)
        #expect(PhaserParams(stages: 0).stages == 2)
    }

    @Test("notchCount is exactly stages/2, over every even count")
    func notchCountIsHalfTheStageCount() {
        for stages in [2.0, 4, 6, 8, 10, 12] {
            #expect(PhaserParams.notchCount(stages: stages) == Int(stages) / 2)
        }
        // An odd request snaps first, so the count follows the snapped value.
        #expect(PhaserParams.notchCount(stages: 7) == 4)
        #expect(PhaserParams.notchCount(stages: 6) == 3)
    }

    // MARK: - ⭐ THE NON-HARMONIC LAW — a phaser is not a flanger

    /// ⭐⭐ THE HEADLINE CLAIM OF THIS KIND, ON PAPER. A flanger's comb notches
    /// are the ODD MULTIPLES of one base frequency: 1, 3, 5, 7. A phaser's are
    /// `tan((2k+1)π/2N)` ratios, which are not that series at ANY stage count —
    /// and the discrepancy GROWS with the index, which is the part a listener
    /// hears as "the notches spread apart as they climb".
    ///
    /// The margins below are the MEASURED discrepancies, asserted as floors
    /// rather than guessed: if the ratio law were ever replaced by a harmonic
    /// one this leg reddens on the first comparison.
    @Test("⭐ notch ratios are NOT the flanger's odd-harmonic comb, at every stage count")
    func notchRatiosAreNonHarmonic() {
        var checked = 0
        for stages in [4.0, 6, 8, 12] {
            let count = PhaserParams.notchCount(stages: stages)
            let first = PhaserParams.notchRatio(stages: stages, index: 0)
            #expect(first > 0)
            // Notch 0 is the reference for both laws, so it agrees trivially.
            for index in 1..<count {
                let phaser = PhaserParams.notchRatio(stages: stages, index: index) / first
                let flanger = Double(2 * index + 1)
                let relative = abs(phaser - flanger) / flanger
                print("[measured] stages \(Int(stages)) notch \(index): "
                      + "phaser ratio \(phaser), flanger comb would be \(flanger), "
                      + "relative difference \(relative)")
                // 4.5 % is the TIGHTEST case in the whole surface (12 stages,
                // notch 1, 3.146 vs 3.000). Everything else is far wider, and
                // the top notch of an 8-stage chain is 25.2 against 7.
                #expect(relative > 0.045,
                        "stages \(Int(stages)) notch \(index) ratio \(phaser) is within 4.5 % of the flanger comb's \(flanger) — if the ratio law has become harmonic, this kind is a flanger")
                checked += 1
            }
        }
        #expect(checked == 1 + 2 + 3 + 5, "the ratio grid went vacuous")

        // And the series SPREADS. ⚠️ MEASURED, and the first form of this
        // assertion was WRONG: successive RATIOS are 3.36, 2.24, 3.36 — not
        // monotone. What does grow monotonically is the ABSOLUTE gap between
        // notches, normalised to the first, and that is the honest statement of
        // "they spread apart as they climb". A harmonic comb's gaps are CONSTANT
        // (exactly 2 in these units), so this still discriminates.
        let eight = (0..<4).map {
            PhaserParams.notchRatio(stages: 8, index: $0)
                / PhaserParams.notchRatio(stages: 8, index: 0)
        }
        let gaps = (1..<4).map { eight[$0] - eight[$0 - 1] }
        print("[measured] 8-stage normalised notch positions \(eight), gaps \(gaps)")
        #expect(gaps[0] < gaps[1])
        #expect(gaps[1] < gaps[2])
        // The flanger comb this is being separated from: gaps of exactly 2, 2, 2.
        #expect(gaps.allSatisfy { abs($0 - 2) > 0.3 })
    }

    @Test("notchRatio is empty outside [0, notchCount) rather than an undefined tangent")
    func notchRatioRefusesAnOutOfRangeIndex() {
        #expect(PhaserParams.notchRatio(stages: 6, index: 3) == 0)
        #expect(PhaserParams.notchRatio(stages: 6, index: 99) == 0)
        #expect(PhaserParams.notchRatio(stages: 6, index: -1) == 0)
        // Non-vacuity: the in-range indices are all non-zero.
        for index in 0..<3 { #expect(PhaserParams.notchRatio(stages: 6, index: index) > 0) }
    }

    // MARK: - The exact digital notch law, and the approximation the wire ships

    /// ⚠️ THE DERIVED-FIELD HONESTY LEG. `firstNotchHzAtSweepFloor` (the number
    /// `fx.add` / `fx.setParam` echo back) is the SAMPLE-RATE-FREE analog ratio,
    /// while `notchHz` is the exact digital answer. The wire ships the former
    /// so the reported number does not change when the user changes project
    /// rate. This leg PROVES the 0.2 % claim the note makes, over the whole
    /// `centerHz` range at both common rates, rather than asserting it.
    @Test("notchRatio and the exact digital notchHz agree to 0.2 % at the sweep floor")
    func notchRatioMatchesTheExactDigitalLawAtTheSweepFloor() {
        var worst = 0.0
        var checked = 0
        for rate in [44_100.0, 48_000, 96_000] {
            for centerHz in [20.0, 100, 300, 700, 1_000] {
                for stages in [2.0, 4, 6, 8, 10, 12] {
                    // ⛔ INDEX 0 ONLY, and that restriction is the finding. The
                    // first version of this leg looped over EVERY index and
                    // measured 8.9 % — because a 12-stage chain's top ratio is
                    // 57.7, so a 1 kHz corner puts that notch at a nominal
                    // 57.7 kHz where prewarping matters enormously. The shipped
                    // derived field uses index 0 at the sweep floor and nothing
                    // else, so that is what may be claimed.
                    let exact = PhaserParams.notchHz(cornerHz: centerHz, stages: stages,
                                                     index: 0, sampleRate: rate)
                    let approx = centerHz * PhaserParams.notchRatio(stages: stages, index: 0)
                    worst = max(worst, abs(exact - approx) / exact)
                    checked += 1
                }
            }
        }
        print("[measured] worst analog-vs-digital notch discrepancy at the sweep "
              + "floor: \(worst * 100) %  over \(checked) points")
        #expect(checked == 3 * 5 * 6)
        #expect(worst < 0.002, "the derived `firstNotchHz` note promises better than 0.2 %")

        // ⭐ POSITIVE CONTROL ON THE RESTRICTION: the same comparison at the TOP
        // index of a 12-stage chain is far worse, so the 0.2 % above is a real
        // bound on a real restriction and not a tolerance wide enough to pass
        // anything. ⚠️ THE FIRST FORM OF THIS CONTROL ASSERTED > 50 % AND
        // FAILED AT 8.9 %, because I had confused `notchRatio` (7.60 at the top
        // of a 12-stage chain) with the ratio to the FIRST notch (57.7). The
        // measured number is 8.9 % — still 54x the index-0 bound, which is what
        // the control is for.
        let topExact = PhaserParams.notchHz(cornerHz: 1_000, stages: 12, index: 5,
                                            sampleRate: 44_100)
        let topApprox = 1_000 * PhaserParams.notchRatio(stages: 12, index: 5)
        let topError = abs(topExact - topApprox) / topExact
        print("[measured] top notch of a 12-stage 1 kHz chain: exact \(topExact) Hz "
              + "vs analog \(topApprox) Hz — \(topError * 100) %")
        #expect(topError > 0.05)
        #expect(topError > worst * 20)

        // The shipped derived field reads the analog law, through its one home.
        #expect(PhaserParams.firstNotchHzAtSweepFloor(centerHz: 300, stages: 6)
                == 300 * PhaserParams.notchRatio(stages: 6, index: 0))
        // …and the number is a real one: 300 Hz / 6 stages puts the lowest
        // notch at about 80 Hz, well below the corner.
        let first = PhaserParams.firstNotchHzAtSweepFloor(centerHz: 300, stages: 6)
        print("[measured] firstNotchHz at the 300 Hz / 6-stage default: \(first)")
        #expect(abs(first - 80.385) < 0.01)
    }

    // MARK: - ⭐ The coefficient, whose SIGN is the easy thing to get wrong

    /// ⭐⭐ THE PLANT THIS LEG EXISTS FOR: `a = (1 − t)/(1 + t)` instead of
    /// `(t − 1)/(t + 1)`. Both are stable all-passes, both give `stages/2`
    /// notches, and every count-based test passes either way. What separates
    /// them is that a first-order all-pass must be exactly **−90° at its own
    /// corner** — the wrong sign gives a fraction of a degree at low corners
    /// and about −13° at 5 kHz.
    ///
    /// The phase is evaluated by EVALUATING THE TRANSFER FUNCTION at `z =
    /// e^{jω}`, not by re-using the closed form the law is derived from, so the
    /// derivation and the check are independent instruments.
    @Test("⭐ the all-pass section is exactly -90 deg at its own corner, and unit gain everywhere")
    func allpassCoefficientPutsMinusNinetyDegreesAtTheCorner() {
        func response(_ a: Double, _ omega: Double) -> (magnitude: Double, phase: Double) {
            let cosine = cos(omega), sine = sin(omega)
            // H = (a + e^-jw) / (1 + a e^-jw)
            let nr = a + cosine, ni = -sine
            let dr = 1 + a * cosine, di = -a * sine
            let denominator = dr * dr + di * di
            let re = (nr * dr + ni * di) / denominator
            let im = (ni * dr - nr * di) / denominator
            return ((re * re + im * im).squareRoot(), atan2(im, re))
        }

        var checked = 0
        for rate in [44_100.0, 48_000, 96_000] {
            for corner in [20.0, 100, 300, 1_000, 4_000, 16_000] {
                let a = PhaserParams.allpassCoefficient(cornerHz: corner, sampleRate: rate)
                #expect(abs(a) < 1, "coefficient \(a) at \(corner) Hz / \(rate) is not stable")
                let omega = 2 * .pi * corner / rate
                let (magnitude, phase) = response(a, omega)
                // ALL-pass: unit magnitude, at the corner and anywhere else.
                #expect(abs(magnitude - 1) < 1e-12)
                #expect(abs(response(a, omega * 0.3).magnitude - 1) < 1e-12)
                #expect(abs(response(a, omega * 2.1).magnitude - 1) < 1e-12)
                // …and exactly a quarter turn of phase AT the corner.
                #expect(abs(phase + .pi / 2) < 1e-9,
                        "corner \(corner) Hz at \(rate): phase \(phase * 180 / .pi) deg, expected -90. The coefficient sign is (t-1)/(t+1), NOT (1-t)/(1+t)")
                checked += 1
            }
        }
        #expect(checked == 18)

        // The wrong-sign form, shown here so the plant is documented rather
        // than folklore: it is a stable all-pass whose corner phase is nowhere
        // near -90 deg.
        let t = tan(.pi * 5_000 / 48_000.0)
        let wrong = (1 - t) / (1 + t)
        let wrongPhase = response(wrong, 2 * .pi * 5_000 / 48_000).phase * 180 / .pi
        print("[measured] the WRONG-SIGN coefficient at 5 kHz gives \(wrongPhase) deg "
              + "at its own corner, not -90")
        #expect(abs(wrongPhase + 90) > 60)

        // The coefficient runs -1 -> 0 -> +1 as the corner climbs, and crosses
        // zero at exactly fs/4 (where the section is a one-sample delay).
        #expect(PhaserParams.allpassCoefficient(cornerHz: 20, sampleRate: 48_000) < -0.99)
        #expect(abs(PhaserParams.allpassCoefficient(cornerHz: 12_000, sampleRate: 48_000)) < 1e-12)
    }

    // MARK: - ⭐ The structural Nyquist claim

    /// ⭐ THE DESIGN CLAIM THAT LETS THIS EFFECT HAVE NO RENDER-THREAD CLAMP:
    /// the sweep's ceiling over the WHOLE surface is below `0.45·fs` at every
    /// rate the app runs at, so the guard inside `allpassCoefficient` never
    /// engages and the sweep top is never flattened. If anyone widens
    /// `centerRange` or `depthRange`, this reddens before the flattening ships.
    @Test("⭐ the sweep ceiling fits under the tan guard at every supported rate")
    func maxCornerFitsEverySupportedRate() {
        #expect(PhaserParams.maxCornerHz == 16_000)
        for rate in [44_100.0, 48_000, 88_200, 96_000] {
            let ceiling = rate * PhaserParams.cornerCeilingFraction
            print("[measured] rate \(rate): guard ceiling \(ceiling) Hz vs "
                  + "maxCornerHz \(PhaserParams.maxCornerHz)")
            #expect(PhaserParams.maxCornerHz < ceiling,
                    "at \(rate) Hz the guard would clamp the sweep top, flattening it")
        }
        // Positive control: at a rate the app does NOT run at, the guard DOES
        // engage — so the assertion above is discriminating, not vacuous.
        #expect(PhaserParams.maxCornerHz > 32_000 * PhaserParams.cornerCeilingFraction)
        let clamped = PhaserParams.allpassCoefficient(cornerHz: 16_000, sampleRate: 32_000)
        let atGuard = PhaserParams.allpassCoefficient(
            cornerHz: 32_000 * PhaserParams.cornerCeilingFraction, sampleRate: 32_000)
        #expect(clamped == atGuard)
        #expect(abs(clamped) < 1, "the guard must keep the section stable even there")
    }

    // MARK: - The sweep law

    /// ⛔ THE UPWARD-ONLY PIN, the §6.3.2 principle in the log-frequency domain.
    /// The corner never leaves `[centerHz, centerHz·2^depth]`, which is what
    /// makes a render-thread bounds check unnecessary.
    @Test("the sweep law is UPWARD ONLY: the corner never leaves [center, center*2^depth]")
    func sweepLawIsUpwardOnlyAcrossTheWholeSurface() {
        var checked = 0
        var lowest = Double.infinity
        var highest = 0.0
        for centerHz in [20.0, 57, 300, 1_000] {
            for depth in [0.0, 0.5, 1, 2.5, 4] {
                let floorHz = centerHz
                let ceilingHz = centerHz * pow(2, depth)
                // A full LFO cycle at fine resolution, plus the exact extremes.
                for step in 0...720 {
                    let phase = Double(step) * .pi / 180
                    let corner = PhaserParams.sweptCornerHz(
                        phaseRadians: phase, centerHz: centerHz, depthOctaves: depth)
                    #expect(corner >= floorHz - 1e-9,
                            "corner \(corner) dived below the floor \(floorHz)")
                    #expect(corner <= ceilingHz + 1e-9,
                            "corner \(corner) passed the ceiling \(ceilingHz)")
                    lowest = min(lowest, corner)
                    highest = max(highest, corner)
                    checked += 1
                }
                // The extremes are REACHED, not merely respected — a law that
                // returned the floor forever would pass the bounds above.
                #expect(abs(PhaserParams.sweptCornerHz(phaseRadians: -(.pi / 2),
                                                       centerHz: centerHz,
                                                       depthOctaves: depth) - floorHz) < 1e-9)
                #expect(abs(PhaserParams.sweptCornerHz(phaseRadians: .pi / 2,
                                                       centerHz: centerHz,
                                                       depthOctaves: depth) - ceilingHz) < 1e-6)
            }
        }
        #expect(checked == 4 * 5 * 721)
        print("[measured] corner over the whole surface: \(lowest) … \(highest) Hz")
        #expect(highest <= PhaserParams.maxCornerHz + 1e-6)
        #expect(lowest >= PhaserParams.centerRange.lowerBound - 1e-9)

        // At phase 0 the sweep sits at the MIDDLE of its travel, not the floor
        // — the upward-only law's signature, and what separates it from a
        // bipolar `center * 2^(depth*sin)` that would sit at the floor there.
        let middle = PhaserParams.sweptCornerHz(phaseRadians: 0, centerHz: 300, depthOctaves: 2)
        #expect(abs(middle - 300 * 2) < 1e-9)
    }

    @Test("depthOctaves 0 freezes the sweep exactly, which is what makes the effect measurable")
    func zeroDepthIsATimeInvariantFilter() {
        for step in 0...360 {
            let phase = Double(step) * .pi / 180
            #expect(PhaserParams.sweptCornerHz(phaseRadians: phase, centerHz: 417,
                                               depthOctaves: 0) == 417)
        }
    }

    // MARK: - The DC gain closed form

    @Test("dcGain is (1-mix) + mix/(1-feedback), and the SIGN of feedback matters")
    func dcGainMatchesTheClosedForm() {
        #expect(abs(PhaserParams.dcGain(feedback: 0.5, mix: 0.5) - 1.5) < 1e-12)
        #expect(abs(PhaserParams.dcGain(feedback: 0, mix: 0.5) - 1.0) < 1e-12)
        // NEGATIVE feedback is BELOW unity — the asymmetry the param note warns
        // about, and the only thing that separates +0.5 from -0.5 at DC.
        #expect(abs(PhaserParams.dcGain(feedback: -0.5, mix: 0.5) - 0.8333333) < 1e-6)
        #expect(abs(PhaserParams.dcGain(feedback: 0.9, mix: 0.5) - 5.5) < 1e-9)
        // mix 0 is unity whatever the feedback — the bypass, arithmetically.
        for feedback in [-0.95, -0.4, 0.0, 0.4, 0.95] {
            #expect(PhaserParams.dcGain(feedback: feedback, mix: 0) == 1)
        }
    }

    // MARK: - Guards and clamping

    @Test("every law guards non-finite input rather than propagating it to the render thread")
    func lawsGuardNonFiniteInput() {
        // A field-by-field automation poke bypasses `init`, so the guards have
        // to live in the laws. Each of these reaches `tan()` or an accumulator.
        #expect(PhaserParams.sweptCornerHz(phaseRadians: .nan, centerHz: 300,
                                           depthOctaves: 3).isFinite)
        #expect(PhaserParams.sweptCornerHz(phaseRadians: 0, centerHz: .nan,
                                           depthOctaves: 3).isFinite)
        #expect(PhaserParams.sweptCornerHz(phaseRadians: 0, centerHz: 300,
                                           depthOctaves: .nan).isFinite)
        #expect(PhaserParams.sweptCornerHz(phaseRadians: 0, centerHz: 1e9,
                                           depthOctaves: 99) <= PhaserParams.maxCornerHz)
        #expect(PhaserParams.allpassCoefficient(cornerHz: .nan, sampleRate: 48_000).isFinite)
        #expect(PhaserParams.allpassCoefficient(cornerHz: 1e9, sampleRate: 48_000).isFinite)
        #expect(abs(PhaserParams.allpassCoefficient(cornerHz: 1e9, sampleRate: 48_000)) < 1)
        #expect(PhaserParams.allpassCoefficient(cornerHz: 300, sampleRate: .nan).isFinite)
        #expect(PhaserParams.notchHz(cornerHz: .nan, stages: 6, index: 0,
                                     sampleRate: 48_000).isFinite)
        #expect(PhaserParams.dcGain(feedback: .nan, mix: .nan).isFinite)
        #expect(PhaserParams.stereoPhaseOffsetRadians(stereoPhaseDeg: .nan) == 0)
        #expect(PhaserParams.firstNotchHzAtSweepFloor(centerHz: .nan, stages: 6).isFinite)
    }

    @Test("the init clamps every field into its declared range")
    func initClampsEveryField() {
        let low = PhaserParams(rateHz: -99, centerHz: -99, depthOctaves: -99,
                               stages: -99, feedback: -99, mix: -99, stereoPhaseDeg: -99)
        #expect(low.rateHz == PhaserParams.rateRange.lowerBound)
        #expect(low.centerHz == PhaserParams.centerRange.lowerBound)
        #expect(low.depthOctaves == PhaserParams.depthRange.lowerBound)
        #expect(low.stages == PhaserParams.stagesRange.lowerBound)
        #expect(low.feedback == PhaserParams.feedbackRange.lowerBound)
        #expect(low.mix == PhaserParams.mixRange.lowerBound)
        #expect(low.stereoPhaseDeg == PhaserParams.stereoPhaseRange.lowerBound)

        let high = PhaserParams(rateHz: 1e6, centerHz: 1e6, depthOctaves: 1e6,
                                stages: 1e6, feedback: 1e6, mix: 1e6, stereoPhaseDeg: 1e6)
        #expect(high.rateHz == PhaserParams.rateRange.upperBound)
        #expect(high.centerHz == PhaserParams.centerRange.upperBound)
        #expect(high.depthOctaves == PhaserParams.depthRange.upperBound)
        #expect(high.stages == PhaserParams.stagesRange.upperBound)
        #expect(high.feedback == PhaserParams.feedbackRange.upperBound)
        #expect(high.mix == PhaserParams.mixRange.upperBound)
        #expect(high.stereoPhaseDeg == PhaserParams.stereoPhaseRange.upperBound)

        let nan = PhaserParams(rateHz: .nan, centerHz: .nan, depthOctaves: .nan,
                               stages: .nan, feedback: .nan, mix: .nan, stereoPhaseDeg: .nan)
        #expect(nan == PhaserParams())
    }

    // MARK: - Codable

    /// ⚠️ A PARTIAL OBJECT MUST DECODE (the `ChorusParams` pattern), and a
    /// round trip must be lossless. The fixture is NON-DEFAULT in every field,
    /// because an all-defaults round trip passes with every key deleted.
    @Test("a partial object decodes to defaults; a full round trip is lossless")
    func codableRoundTripsAndToleratesMissingKeys() throws {
        let partial = try JSONDecoder().decode(
            PhaserParams.self, from: Data(#"{"centerHz": 700}"#.utf8))
        #expect(partial.centerHz == 700)
        #expect(partial == PhaserParams(centerHz: 700))

        let empty = try JSONDecoder().decode(PhaserParams.self, from: Data("{}".utf8))
        #expect(empty == PhaserParams())

        let full = PhaserParams(rateHz: 1.7, centerHz: 640, depthOctaves: 1.25,
                                stages: 12, feedback: -0.4, mix: 0.9, stereoPhaseDeg: 33)
        // Non-vacuity: every field differs from the default.
        let base = PhaserParams()
        #expect(full.rateHz != base.rateHz && full.centerHz != base.centerHz
                && full.depthOctaves != base.depthOctaves && full.stages != base.stages
                && full.feedback != base.feedback && full.mix != base.mix
                && full.stereoPhaseDeg != base.stereoPhaseDeg)
        let restored = try JSONDecoder().decode(
            PhaserParams.self, from: JSONEncoder().encode(full))
        #expect(restored == full)

        // Decoding routes through the CLAMPING init — a hostile file cannot
        // put an out-of-range or odd value into the render path.
        let hostile = try JSONDecoder().decode(
            PhaserParams.self,
            from: Data(#"{"stages": 7, "feedback": 9, "centerHz": -3}"#.utf8))
        #expect(hostile.stages == 8)
        #expect(hostile.feedback == PhaserParams.feedbackRange.upperBound)
        #expect(hostile.centerHz == PhaserParams.centerRange.lowerBound)
    }

    // MARK: - The descriptor surface

    @Test("the descriptor exposes phaser params by wire name and omits nothing")
    func descriptorReadsEveryDeclaredParamByName() {
        let descriptor = EffectDescriptor(
            kind: .phaser,
            phaser: PhaserParams(rateHz: 2, centerHz: 500, depthOctaves: 1,
                                 stages: 10, feedback: -0.3, mix: 0.7,
                                 stereoPhaseDeg: 45))
        // Driven by the SPEC TABLE, so a param declared and not readable fails.
        for spec in EffectParamSpec.specs(for: .phaser) {
            #expect(descriptor.paramValue(spec.name) != nil,
                    "\(spec.name) is declared in specs(for:) but unreadable on the descriptor")
        }
        #expect(EffectParamSpec.specs(for: .phaser).count == 7)
        #expect(descriptor.paramValue("centerHz") == 500)
        #expect(descriptor.paramValue("stages") == 10)
        #expect(descriptor.paramValue("feedback") == -0.3)
        #expect(descriptor.paramValue("notchCount") == nil)  // derived, not a param
        #expect(descriptor.resolvedPhaser.centerHz == 500)
        // A descriptor with no params object resolves to the defaults.
        #expect(EffectDescriptor(kind: .phaser).resolvedPhaser == PhaserParams())
    }
}
