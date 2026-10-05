import Foundation
import Testing
@testable import DAWCore

/// m39-ac — **`ClipperParams`' laws, which the render thread reads and does not
/// re-implement.** The shaping law lives in DAWCore for the
/// `TapeDelayParams.saturated` reason: the DSP and the tests must read ONE home,
/// or they drift and both look right.
///
/// ⭐ The centre of this suite is P2/P3: what separates a CLIPPER from a
/// SATURATOR is that both modes reach the ceiling at a FINITE input. `tanh` does
/// not, ever, and P3 measures that difference rather than asserting it.
@Suite("m39-ac — the clipper's parameter laws")
struct ClipperParamsTests {

    // MARK: - P1: hard mode

    @Test("P1 — hard mode is the identity below the ceiling and EXACTLY the ceiling above it")
    func hardModeIsAnExactCeiling() {
        let ceiling = 0.5
        for x in stride(from: -0.499, through: 0.499, by: 0.01) {
            // Below the ceiling: the identity, to the bit.
            #expect(ClipperParams.shaped(x, ceilingLinear: ceiling, soft: false) == x)
        }
        for x in [0.5, 0.500001, 1.0, 12.5, 1e9] {
            #expect(ClipperParams.shaped(x, ceilingLinear: ceiling, soft: false) == ceiling)
            #expect(ClipperParams.shaped(-x, ceilingLinear: ceiling, soft: false) == -ceiling)
        }
        // The symmetry is exact, which is why a clipped sine has ODD harmonics
        // only — the property every alias measurement in `ClipperTests` relies
        // on to know which bins should be empty.
        for x in stride(from: 0.0, through: 2.0, by: 0.017) {
            let up = ClipperParams.shaped(x, ceilingLinear: ceiling, soft: false)
            let down = ClipperParams.shaped(-x, ceilingLinear: ceiling, soft: false)
            #expect(up == -down)
        }
    }

    // MARK: - P2/P3: soft mode, and what makes it a clipper

    @Test("P2 — soft mode has unity slope at 0, reaches the ceiling at exactly 1.5x it, and is bounded")
    func softModeIsACubicKneeOntoAHardCeiling() {
        let ceiling = 0.4
        // Unity gain for small signals — the property a tanh saturator does NOT
        // have (tanh(gx)/… rescales everything, however quiet).
        for x in [1e-6, 1e-4, 1e-3] {
            let y = ClipperParams.shaped(x, ceilingLinear: ceiling, soft: true)
            #expect(abs(y / x - 1) < 1e-4, "soft slope at \(x) is \(y / x), not ~1")
        }
        // Reaches the ceiling at EXACTLY softKneeRatio x ceiling.
        let knee = ClipperParams.softKneeRatio * ceiling
        let atKnee = ClipperParams.shaped(knee, ceilingLinear: ceiling, soft: true)
        #expect(abs(atKnee - ceiling) < 1e-12, "at the knee the output is \(atKnee), not \(ceiling)")
        // …and STAYS there.
        for x in [knee, knee * 1.000001, knee * 2, 1e9] {
            #expect(ClipperParams.shaped(x, ceilingLinear: ceiling, soft: true) == ceiling)
        }
        // C1: the slope goes to 0 AT the knee, so the curve meets the flat top
        // without a corner. A corner there would generate exactly the harmonics
        // soft mode exists to avoid.
        let h = 1e-6
        let slopeAtKnee = (ClipperParams.shaped(knee, ceilingLinear: ceiling, soft: true)
                           - ClipperParams.shaped(knee - h, ceilingLinear: ceiling, soft: true)) / h
        #expect(abs(slopeAtKnee) < 1e-4, "slope at the knee is \(slopeAtKnee), not ~0")
        // Monotone and bounded over the whole approach.
        var previous = -Double.infinity
        for x in stride(from: 0.0, through: knee, by: knee / 500) {
            let y = ClipperParams.shaped(x, ceilingLinear: ceiling, soft: true)
            #expect(y >= previous - 1e-15, "soft mode is not monotone at \(x)")
            #expect(y <= ceiling + 1e-15)
            previous = y
        }
        // Odd symmetry, same reason as P1.
        for x in stride(from: 0.0, through: 2.0, by: 0.013) {
            #expect(ClipperParams.shaped(x, ceilingLinear: ceiling, soft: true)
                    == -ClipperParams.shaped(-x, ceilingLinear: ceiling, soft: true))
        }
    }

    /// ⛔ THE LEG THAT SEPARATES THIS KIND FROM `.saturator`, MEASURED. The
    /// `Kind.clipper` doc comment claims soft mode "reaches the ceiling at a
    /// finite input and stays there" and that tanh cannot. This measures both
    /// halves of that sentence rather than asserting either.
    @Test("P3 — soft mode REACHES its bound; tanh scaled the same way never does")
    func softModeIsNotTanh() {
        let ceiling = 0.6
        let knee = ClipperParams.softKneeRatio * ceiling
        #expect(ClipperParams.shaped(knee, ceilingLinear: ceiling, soft: true) == ceiling)
        // The saturator's shape, at the gain that gives it the same small-signal
        // slope: tanh(x/c)*c. It approaches `c` and never arrives.
        func tanhShaped(_ x: Double) -> Double { tanh(x / ceiling) * ceiling }
        // ⚠️ THE MULTIPLES STOP AT 4x DELIBERATELY, AND THE REASON IS THE POINT.
        // `tanh` reaches 1.0 in `Double` at an argument of about 19 — i.e. at
        // LARGE inputs a tanh saturator does hit its bound, but only because
        // the arithmetic ran out, not because the function did. That is exactly
        // the kind of "it works in practice" that makes the two shapes look
        // equivalent while the CLIPPER's bound is a property of the formula and
        // holds at every input including the ones near the knee, where music
        // actually lives. MEASURED at `knee * 100`: tanh reads exactly 0.6.
        for x in [knee, knee * 2, knee * 4] {
            let t = tanhShaped(x)
            #expect(t < ceiling, "tanh reached its bound at \(x) — it should not")
            #expect(ClipperParams.shaped(x, ceilingLinear: ceiling, soft: true) == ceiling)
        }
        let gap = ceiling - tanhShaped(knee)
        print("[measured] at the knee input \(knee): soft clipper = \(ceiling) exactly, "
              + "tanh = \(tanhShaped(knee)) (short by \(gap))")
        #expect(gap > 0.05, Comment(rawValue:
                "tanh is only \(gap) below the ceiling at the knee — the two shapes "
                + "are being compared at gains that make the distinction invisible"))
    }

    // MARK: - P4: the discrete snaps

    @Test("P4 — mode and oversampling snap exactly as documented, including the 3 -> 4 tie")
    func discreteParamsSnap() {
        #expect(ClipperParams.mode(at: 0) == .hard)
        #expect(ClipperParams.mode(at: 0.4) == .hard)
        #expect(ClipperParams.mode(at: 0.5) == .soft)   // .rounded() is half-away-from-zero
        #expect(ClipperParams.mode(at: 1) == .soft)
        #expect(ClipperParams.mode(at: 99) == .soft)    // clamped first
        #expect(ClipperParams.mode(at: -99) == .hard)
        #expect(ClipperParams.mode(at: .nan) == .hard)

        #expect(ClipperParams.oversamplingFactor(at: 1) == 1)
        #expect(ClipperParams.oversamplingFactor(at: 1.4) == 1)
        #expect(ClipperParams.oversamplingFactor(at: 1.5) == 2)  // tie -> higher
        #expect(ClipperParams.oversamplingFactor(at: 2) == 2)
        #expect(ClipperParams.oversamplingFactor(at: 2.9) == 2)
        #expect(ClipperParams.oversamplingFactor(at: 3) == 4)    // the documented tie
        #expect(ClipperParams.oversamplingFactor(at: 4) == 4)
        #expect(ClipperParams.oversamplingFactor(at: 400) == 4)  // clamped first
        #expect(ClipperParams.oversamplingFactor(at: -400) == 1)
        #expect(ClipperParams.oversamplingFactor(at: .nan) == 4)
        // Nothing outside the supported set can come back.
        for raw in stride(from: -2.0, through: 6.0, by: 0.05) {
            #expect(OversamplerDesign.supportedFactors
                .contains(ClipperParams.oversamplingFactor(at: raw)))
        }
    }

    /// ⛔⛔ **THE DRIFT PIN.** `oversamplingFactor(at:)` uses HAND-WRITTEN
    /// thresholds rather than a search over `OversamplerDesign.supportedFactors`
    /// — because it runs on the render thread and iterating a Swift `Array`
    /// there allocates (MEASURED: 163 296 malloc events over 2 000 quanta at
    /// `-Onone`). That makes the roster and the function two separate statements
    /// of the same fact, which is exactly the shape this tree keeps getting
    /// bitten by. So this leg re-derives the answer BY BRUTE FORCE from the
    /// roster and fails if the two ever disagree: add a factor to
    /// `supportedFactors` without moving the thresholds and this reddens.
    @Test("P4b — the hand-written thresholds agree with a brute-force search over the roster")
    func theSnapAgreesWithTheRoster() {
        func bruteForce(_ value: Double) -> Int {
            let clamped = value.clamped(to: ClipperParams.oversamplingRange)
            var best = OversamplerDesign.supportedFactors.first ?? 1
            var bestDistance = Double.infinity
            for factor in OversamplerDesign.supportedFactors.sorted() {
                let distance = abs(Double(factor) - clamped)
                // `<=`: ascending candidates, so a tie resolves UPWARD — the
                // documented rule.
                if distance <= bestDistance {
                    bestDistance = distance
                    best = factor
                }
            }
            return best
        }
        var checked = 0
        var ties = 0
        for step in 0...40_000 {
            let raw = -4.0 + Double(step) * 0.0005   // −4 … +16, through every edge
            let shipped = ClipperParams.oversamplingFactor(at: raw)
            let reference = bruteForce(raw)
            let roster = OversamplerDesign.supportedFactors
            #expect(shipped == reference, Comment(rawValue:
                "at \(raw): shipped \(shipped), brute force over \(roster) says \(reference)"))
            checked += 1
            if raw == 1.5 || raw == 3.0 { ties += 1 }
        }
        // Non-vacuity: the sweep must have crossed BOTH exact ties, or it has
        // not tested the only interesting inputs.
        #expect(ties == 2, "the sweep missed a tie point — it checked \(checked) values")
        #expect(OversamplerDesign.supportedFactors == [1, 2, 4], Comment(rawValue:
            "the roster changed to \(OversamplerDesign.supportedFactors); "
            + "`ClipperParams.oversamplingFactor(at:)`'s thresholds must move with it"))
        #expect(OversamplerDesign.maxFactor == OversamplerDesign.supportedFactors.max())
    }

    // MARK: - P5: the init

    @Test("P5 — init clamps, snaps, and refuses every non-finite value")
    func initIsTotal() {
        let defaults = ClipperParams()
        #expect(defaults.driveDb == 0)
        #expect(defaults.ceilingDb == -0.3)
        #expect(defaults.mode == 0)
        // ⛔ 1, NOT THE 4 THIS KIND SHIPPED WITH — the user's 2026-09-20 ruling
        // that a NEW clipper starts with oversampling OFF. A literal as well as
        // the constant, so moving the constant cannot quietly move this pin.
        #expect(defaults.oversampling == 1)
        #expect(defaults.oversampling == ClipperParams.defaultOversampling)
        #expect(defaults.mix == 1)
        #expect(defaults.outputDb == 0)
        // …and the frozen number that absence means, which must NEVER follow it.
        #expect(ClipperParams.legacyOversampling == 4)
        #expect(ClipperParams.legacy.oversampling == 4)
        #expect(ClipperParams.legacy == ClipperParams(oversampling: 4),
                "the legacy params must differ from a new clipper in oversampling ONLY")

        let clamped = ClipperParams(driveDb: 999, ceilingDb: 12, mode: 7,
                                    oversampling: 3, mix: -4, outputDb: -999)
        #expect(clamped.driveDb == ClipperParams.driveDbRange.upperBound)
        #expect(clamped.ceilingDb == 0)            // a ceiling above 0 dBFS is not a ceiling
        #expect(clamped.mode == 1)
        #expect(clamped.oversampling == 4)         // 3 snaps UP
        #expect(clamped.mix == 0)
        #expect(clamped.outputDb == ClipperParams.outputDbRange.lowerBound)

        // ⚠️ A NON-FINITE VALUE FALLS BACK TO THE DEFAULT, IT DOES NOT CLAMP —
        // the guard runs AHEAD of `clamped(to:)` on purpose, because
        // `clamped(to:)` on a NaN returns the NaN (both comparisons inside
        // `min(max(…))` are false against NaN). An infinity would clamp
        // correctly and a NaN would not, so treating both the same way is what
        // makes the rule statable. This is the house shape
        // (`FreqShifterParams.init`), and it is asserted here rather than
        // assumed because the two behaviours differ VISIBLY for infinities.
        let poisoned = ClipperParams(driveDb: .nan, ceilingDb: .infinity, mode: .nan,
                                     oversampling: .nan, mix: -.infinity, outputDb: .nan)
        #expect(poisoned.driveDb == 0)
        #expect(poisoned.ceilingDb == -0.3)        // the DEFAULT, not the range's top
        #expect(poisoned.mode == 0)
        // ⚠️ THE ONE FIELD THAT DOES NOT FALL BACK TO ITS DEFAULT — and it never
        // did; until 2026-09-20 the two numbers merely coincided at 4. A NaN
        // factor snaps through `oversamplingFactor(at:)`, the render thread's
        // own rule, to the TOP factor ("more alias rejection than asked for").
        // One rule for init and render beats matching the new default here, and
        // JSON cannot carry a NaN, so this never decides what a project sounds like.
        #expect(poisoned.oversampling == 4)
        #expect(poisoned.mix == 1)                 // the DEFAULT, not the range's bottom
        #expect(poisoned.outputDb == 0)
        // Nothing non-finite survived anywhere.
        for value in [poisoned.driveDb, poisoned.ceilingDb, poisoned.mode,
                      poisoned.oversampling, poisoned.mix, poisoned.outputDb] {
            #expect(value.isFinite)
        }
    }

    @Test("P6 — shaped() returns 0 for a non-finite input rather than propagating it")
    func shapedRefusesNonFinite() {
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(ClipperParams.shaped(bad, ceilingLinear: 0.5, soft: false) == 0)
            #expect(ClipperParams.shaped(bad, ceilingLinear: 0.5, soft: true) == 0)
        }
        // A poisoned CEILING is refused too — it reaches a division in soft mode.
        for bad in [Double.nan, .infinity, 0, -1] {
            #expect(ClipperParams.shaped(0.25, ceilingLinear: bad, soft: true) == 0)
            #expect(ClipperParams.shaped(0.25, ceilingLinear: bad, soft: false) == 0)
        }
    }

    // MARK: - P7: the derived wire numbers

    @Test("P7 — clipThresholdDbfs and wetCeilingDbfs are the numbers the notes promise")
    func derivedWireNumbersAreCorrect() {
        // The default instance: ceiling −0.3, drive 0 → clipping starts at −0.3.
        #expect(abs(ClipperParams.clipThresholdDbfs(driveDb: 0, ceilingDb: -0.3) + 0.3) < 1e-12)
        // The note's worked example, verbatim: "ceiling -0.3 with drive 6
        // starts clipping anything above -6.3 dBFS".
        #expect(abs(ClipperParams.clipThresholdDbfs(driveDb: 6, ceilingDb: -0.3) + 6.3) < 1e-12)
        #expect(abs(ClipperParams.wetCeilingDbfs(ceilingDb: -0.3, outputDb: 0) + 0.3) < 1e-12)
        #expect(abs(ClipperParams.wetCeilingDbfs(ceilingDb: -6, outputDb: 3) + 3) < 1e-12)
        // Both clamp their inputs, so an unfenced automation value cannot make
        // the wire report a threshold the effect cannot reach.
        #expect(ClipperParams.clipThresholdDbfs(driveDb: 1e9, ceilingDb: 1e9)
                == ClipperParams.ceilingDbRange.upperBound - ClipperParams.driveDbRange.upperBound)
        #expect(ClipperParams.clipThresholdDbfs(driveDb: .nan, ceilingDb: .nan) == 0)
        #expect(ClipperParams.wetCeilingDbfs(ceilingDb: .nan, outputDb: .nan) == 0)
    }

    // MARK: - P8: Codable

    @Test("P8 — a full round trip preserves every field, and a partial object decodes to defaults")
    func codableRoundTrips() throws {
        let original = ClipperParams(driveDb: 9.5, ceilingDb: -4.25, mode: 1,
                                     oversampling: 2, mix: 0.73, outputDb: -3.5)
        let data = try JSONEncoder().encode(original)
        let back = try JSONDecoder().decode(ClipperParams.self, from: data)
        #expect(back == original)
        // Non-vacuity: the fixture is genuinely non-default, so the round trip
        // is not comparing two default instances.
        #expect(original != ClipperParams())

        // A partial object — the `ChorusParams` pattern. Every absent key takes
        // the default, and the two DISCRETE keys still snap.
        let partial = Data(#"{"driveDb": 3, "oversampling": 3}"#.utf8)
        let decoded = try JSONDecoder().decode(ClipperParams.self, from: partial)
        #expect(decoded.driveDb == 3)
        #expect(decoded.ceilingDb == -0.3)
        #expect(decoded.mode == 0)
        #expect(decoded.oversampling == 4)   // 3 snapped on the way in
        #expect(decoded.mix == 1)
        #expect(decoded.outputDb == 0)

        // ⛔ …EXCEPT `oversampling`, whose ABSENCE is not "the default" but
        // "written by something describing a clipper that ran at 4×" — the
        // 2026-09-20 ruling moved the default to 1 and must not move this.
        let noFactor = Data(#"{"driveDb": 3}"#.utf8)
        let legacy = try JSONDecoder().decode(ClipperParams.self, from: noFactor)
        #expect(legacy.oversampling == ClipperParams.legacyOversampling)
        #expect(legacy.oversampling == 4)
        #expect(legacy.driveDb == 3)

        // An out-of-range object on disk re-clamps through the same init.
        let wild = Data(#"{"ceilingDb": 99, "mix": 42}"#.utf8)
        let tamed = try JSONDecoder().decode(ClipperParams.self, from: wild)
        #expect(tamed.ceilingDb == 0)
        #expect(tamed.mix == 1)
    }

    // MARK: - P9: the spec surface agrees with the struct

    /// ⚠️ **"FRESH" MEANS `EffectDescriptor.newlyAdded`, NOT `EffectDescriptor(kind:)`**
    /// (2026-09-20 ruling). A bare no-params clipper descriptor is what a
    /// pre-ruling build SAVED for a clipper nobody touched, so it deliberately
    /// reads the LEGACY 4 — asserted below, next to the new insert's 1.
    @Test("P9 — every spec's default equals a NEW clipper's value, and every range is the struct's")
    func specTableAgreesWithTheStruct() {
        let specs = EffectParamSpec.specs(for: .clipper)
        let defaults = ClipperParams()
        let descriptor = EffectDescriptor.newlyAdded(kind: .clipper)
        #expect(descriptor.clipper != nil,
                "a NEW clipper must carry explicit params — absence means 'saved before the ruling'")
        #expect(specs.count == 6)
        for spec in specs {
            let live = descriptor.paramValue(spec.name)
            #expect(live != nil, "paramValue has no arm for \(spec.name)")
            #expect(live == spec.defaultValue, Comment(rawValue:
                    "\(spec.name): spec default \(spec.defaultValue) but a new clipper "
                    + "reads \(String(describing: live))"))
            #expect(spec.range.contains(spec.defaultValue))
        }
        #expect(descriptor.paramValue("driveDb") == defaults.driveDb)
        #expect(descriptor.paramValue("nonsense") == nil)

        // ⛔ THE OTHER HALF: a no-params descriptor is an OLD clipper and reads
        // 4 for `oversampling` — and ONLY for `oversampling`; every other field's
        // default never moved, so it must still match the spec.
        let saved = EffectDescriptor(kind: .clipper)
        #expect(saved.clipper == nil)
        for spec in specs {
            let expected = spec.name == "oversampling"
                ? ClipperParams.legacyOversampling : spec.defaultValue
            #expect(saved.paramValue(spec.name) == expected, Comment(rawValue:
                    "an untouched pre-ruling clipper reads \(spec.name) = "
                    + "\(String(describing: saved.paramValue(spec.name))), expected \(expected)"))
        }
        // The ranges are the struct's, not a second copy.
        #expect(specs[0].range == ClipperParams.driveDbRange)
        #expect(specs[1].range == ClipperParams.ceilingDbRange)
        #expect(specs[2].range == ClipperParams.modeRange)
        #expect(specs[3].range == ClipperParams.oversamplingRange)
        #expect(specs[4].range == ClipperParams.mixRange)
        #expect(specs[5].range == ClipperParams.outputDbRange)
    }
}
