import Foundation
import Testing
@testable import DAWCore

/// Breath pad P2 — the circular morph space (`EffortRing`), design §8.2 (the
/// weight law) and §7.3 (the blend law), with the assertions design §13.2 names.
///
/// ⭐ **NOT `@MainActor`, deliberately.** The tree is at its 330-`@MainActor`-
/// suite ceiling and every line here is pure DAWCore arithmetic, so this suite
/// costs no slot. The ring's STORE half folds into the existing
/// `ControllerLaneStoreTests` for the same reason P1's did.
@Suite("Breath pad P2 — the effort ring")
struct EffortRingTests {

    // Sampling density used wherever the design says "at every sample". 1000 is
    // §13.2's own figure for the angle sweep; the same density is used for `u`
    // so a difference that only shows between knots cannot hide.
    private let steps = 1000

    private func sweepAngles(_ n: Int) -> [Double] {
        (0..<n).map { 2 * Double.pi * Double($0) / Double(n) }
    }

    private func sweepU(_ n: Int) -> [Double] {
        (0...n).map { Double($0) / Double(n) }
    }

    private func pattern(_ id: String) throws -> EffortPattern {
        try #require(EffortPattern.named(id))
    }

    // MARK: - §13.2 partition of unity

    @Test("partition of unity: the weights sum to exactly 1 at every angle, for every ring size")
    func weightsSumToOne() throws {
        // N = 1 and N = 2 are the sizes where a nearest-two rule can divide by
        // zero or store both neighbours in one slot, so they are tested rather
        // than assumed away.
        for n in [1, 2, 3, 5, 8, 12] {
            let ring = EffortRing(patterns: Array(EffortPattern.library.prefix(max(1, min(8, n))))
                                    + Array(repeating: EffortPattern.library[0],
                                            count: max(0, n - 8)))
            #expect(ring.count == n, "ring of \(n) built the wrong size")
            var worst = 0.0
            // Include angles outside 0..<2π: DAWCore WRAPS, and a wrap that
            // dropped a weight would show as a sum of 0 here.
            for phi in sweepAngles(steps) + [-1.0, -0.001, 2 * Double.pi, 7 * Double.pi] {
                let w = ring.weights(atAngle: phi)
                #expect(w.count == n)
                worst = max(worst, abs(w.reduce(0, +) - 1))
                #expect(w.filter { $0 > 0 }.count <= 2,
                        "nearest-TWO: at most two patterns may be non-zero")
                #expect(w.allSatisfy { $0 >= 0 })
            }
            #expect(worst < 1e-12, "N=\(n): worst |Σw − 1| was \(worst)")
        }
    }

    // MARK: - §13.2 exact reproduction

    @Test("exact reproduction: parking the dot ON a pattern gives that pattern, at every sample")
    func parkingOnAPatternReproducesIt() throws {
        let ring = EffortRing.standard
        for (i, expected) in ring.patterns.enumerated() {
            let blend = ring.blend(atAngle: ring.angle(ofIndex: i), radius: 1)
            // Exactly one pattern sounding at θ_i is the property that
            // inverse-distance (Shepard) weighting would fail.
            #expect(blend.members.count == 1, "at θ_\(i) exactly one pattern may be sounding")
            #expect(blend.dominant.pattern.id == expected.id)
            #expect(blend.weight(of: expected.scope) == 1)

            // At every sample, not just at the knots.
            var worst = 0.0
            for u in sweepU(steps) {
                worst = max(worst, abs(blend.level(scope: expected.scope, u: u)
                                       - expected.evaluate(u: u)))
            }
            #expect(worst < 1e-15, "\(expected.id): worst level error \(worst)")

            // And through the PROJECTION vehicle too — the store reads the
            // curve, not `level`, so reproducing one but not the other would
            // still ship a wrong gesture.
            let curve = try #require(blend.curve(scope: expected.scope))
            var curveWorst = 0.0
            for u in sweepU(steps) {
                curveWorst = max(curveWorst, abs(curve.evaluate(u: u) - expected.evaluate(u: u)))
            }
            #expect(curveWorst < 1e-15, "\(expected.id): worst curve error \(curveWorst)")
            #expect(curve.peakPosition == expected.peakPosition)
            #expect(curve.travel == expected.travel)
            #expect(curve.normalisedOnsetLevel == expected.normalisedOnsetLevel)
            #expect(curve.normalisedReleaseLevel == expected.normalisedReleaseLevel)
            #expect(curve.earlyDipPosition == expected.earlyDipPosition)

            // The OTHER scope is absent, not flattened — the store reads nil as
            // "leave this axis alone".
            let other: EffortPattern.Scope = expected.scope == .note ? .phrase : .note
            #expect(blend.curve(scope: other) == nil)
            #expect(blend.weight(of: other) == 0)
        }
    }

    // MARK: - §13.2 identity under self-blend — THE EQUAL-POWER CATCHER

    @Test("self-blend identity: a ring of one pattern IS that pattern at every angle and every u")
    func selfBlendIsTheIdentity() throws {
        // Every library entry, so the catch does not depend on which shape was
        // picked. `messaDiVoce` alone would nearly do it, but `flat` has two
        // knots and `sforzandoPiano` four, and a length-sensitive bug would
        // survive a single-pattern test.
        for source in EffortPattern.library {
            let ring = EffortRing.uniform(source, count: 8)
            var worst = 0.0
            var worstAt = (phi: 0.0, u: 0.0)
            // ⚠️ THE SWEEP MUST INCLUDE THE MIDPOINTS. √w + √(1−w) is exactly
            // 1.0 at w == 1, so an equal-power implementation reproduces the
            // pattern PERFECTLY at every θ_i and fails only between them. A
            // sweep aligned to the pattern angles would ship the bug green.
            for phi in sweepAngles(steps) {
                let blend = ring.blend(atAngle: phi, radius: 1)
                for u in sweepU(64) {
                    let error = abs(blend.level(scope: source.scope, u: u)
                                    - source.evaluate(u: u))
                    if error > worst { worst = error; worstAt = (phi, u) }
                }
            }
            #expect(worst < 1e-15,
                    "\(source.id): a self-blend must be the IDENTITY; worst error \(worst) at φ=\(worstAt.phi), u=\(worstAt.u)")
        }
    }

    @Test("the midpoint between two copies is 1.0x, not the 1.414x an equal-power blend gives")
    func theEqualPowerErrorIsNamedAndAbsent() throws {
        let source = try pattern("messaDiVoce")
        let ring = EffortRing.uniform(source, count: 8)
        // Exactly halfway between index 0 and index 1 — where the eased weights
        // are 0.5/0.5 and where equal-power is maximally wrong.
        let midpoint = ring.spacing / 2
        let w = ring.weights(atAngle: midpoint)
        #expect(abs(w[0] - 0.5) < 1e-12)
        #expect(abs(w[1] - 0.5) < 1e-12)

        let blend = ring.blend(atAngle: midpoint, radius: 1)
        let u = 0.5                                   // messaDiVoce's own peak
        let correct = blend.level(scope: .note, u: u)
        let value = source.evaluate(u: u)
        // What an equal-power blend WOULD have produced, written out so the
        // failure names the bug instead of a number.
        let equalPower = (0.5.squareRoot() + 0.5.squareRoot()) * value
        print("[measured] P2 self-blend at the midpoint: \(correct) "
              + "(pattern \(value); equal-power would give \(equalPower))")
        #expect(abs(correct - value) < 1e-15, "equal-gain: the self-blend returns the pattern")
        // Positive control: the equal-power figure must actually DIFFER,
        // otherwise this test discriminates nothing.
        #expect(abs(equalPower - value) > 0.1, "the equal-power figure must differ from the pattern's")
        #expect(abs(correct - equalPower) > 0.1)
    }

    // MARK: - §8.2 continuity

    @Test("continuity across the 0/2pi seam, and C1 at every pattern position")
    func continuityIncludingTheWrap() throws {
        let ring = EffortRing.standard
        let eps = 1e-7

        // C0 at the seam: the weight vector just below 2π must match the one at 0.
        let before = ring.weights(atAngle: 2 * .pi - eps)
        let atZero = ring.weights(atAngle: 0)
        for i in 0..<ring.count {
            #expect(abs(before[i] - atZero[i]) < 1e-6,
                    "seam discontinuity at index \(i): \(before[i]) vs \(atZero[i])")
        }

        // C1 at every θ_i: the cosine ease has zero slope at both ends, so the
        // one-sided derivatives of the dominant weight must both be ≈ 0. A
        // LINEAR ease would give ±1/spacing here — a slope the dot passes
        // through as an audible kink.
        let h = 1e-5
        for i in 0..<ring.count {
            let theta = ring.angle(ofIndex: i)
            let left = (ring.weights(atAngle: theta)[i]
                        - ring.weights(atAngle: theta - h)[i]) / h
            let right = (ring.weights(atAngle: theta + h)[i]
                         - ring.weights(atAngle: theta)[i]) / h
            #expect(abs(left) < 1e-3, "left slope at θ_\(i) was \(left)")
            #expect(abs(right) < 1e-3, "right slope at θ_\(i) was \(right)")
        }
        // POSITIVE CONTROL for the slope probe: at the MIDPOINT the same
        // measurement must be clearly non-zero, or the numbers above prove
        // nothing but a broken derivative.
        let mid = ring.spacing / 2
        let midSlope = (ring.weights(atAngle: mid + h)[0]
                        - ring.weights(atAngle: mid - h)[0]) / (2 * h)
        print("[measured] P2 weight slope: at a pattern ~0, at the midpoint \(midSlope)")
        #expect(abs(midSlope) > 0.5)
    }

    // MARK: - §8.2 commutativity of the ring order

    @Test("rotating the ring rotates the answer and changes nothing else")
    func ringOrderIsCommutative() throws {
        let ring = EffortRing.standard
        let k = 3
        let rotated = EffortRing(patterns: Array(ring.patterns[k...]) + Array(ring.patterns[..<k]))
        for phi in sweepAngles(256) {
            let a = ring.weights(atAngle: phi)
            let b = rotated.weights(atAngle: phi - Double(k) * ring.spacing)
            for i in 0..<ring.count {
                #expect(abs(a[i] - b[(i - k + ring.count) % ring.count]) < 1e-12)
            }
        }
    }

    @Test("value-domain blending is commutative in the two members")
    func blendIsCommutative() throws {
        // flat and messaDiVoce, both note-scoped, as an adjacent pair — then the
        // SAME pair swapped, sampled at the mirrored angle.
        let a = try pattern("flat"), b = try pattern("messaDiVoce")
        let forward = EffortRing(patterns: [a, b])
        let backward = EffortRing(patterns: [b, a])
        for t in sweepU(64) {
            let phi = t * Double.pi                       // 0 → a, π → b on a 2-ring
            let f = forward.blend(atAngle: phi, radius: 1)
            let r = backward.blend(atAngle: Double.pi + phi, radius: 1)
            for u in sweepU(32) {
                #expect(abs(f.level(scope: .note, u: u) - r.level(scope: .note, u: u)) < 1e-14)
            }
        }
    }

    // MARK: - Different knot counts

    @Test("a blend of two patterns with DIFFERENT knot counts is well defined at every u")
    func differentKnotCountsBlendCleanly() throws {
        // messaDiVoce has 3 knots, lateBloom 4, and they are ring neighbours —
        // the case the design says has no natural knot correspondence and is
        // exactly why the law blends VALUES rather than warping time.
        let a = try pattern("messaDiVoce"), b = try pattern("lateBloom")
        #expect(a.knots.count != b.knots.count, "fixture check: the counts must differ")

        let ring = EffortRing(patterns: [a, b])
        for phi in sweepAngles(128) {
            let blend = ring.blend(atAngle: phi, radius: 1)
            let curve = try #require(blend.curve(scope: .note))
            // The union — 0, 0.5, 1 from messaDiVoce and 0, 0.55, 0.85, 1 from
            // lateBloom — must all be PRESENT as knots, whichever way the
            // weights fall. (Mismatched intervals are additionally subdivided,
            // so the count is a floor, not an equality.)
            let positions = Set(curve.knots.map(\.u))
            for u in [0, 0.5, 0.55, 0.85, 1.0] where blend.members.count > 1 {
                #expect(positions.contains(u), "the union position \(u) is missing from the curve")
            }
            for u in sweepU(steps) {
                let level = blend.level(scope: .note, u: u)
                #expect(level.isFinite, "level at u=\(u), φ=\(phi) was not finite")
                #expect(level >= 0 && level <= 1)
                // Value-domain blending is bounded by its parents everywhere —
                // it cannot overshoot, which is the concrete symptom an
                // equal-power blend would show.
                let lo = min(a.evaluate(u: u), b.evaluate(u: u)) - 1e-12
                let hi = max(a.evaluate(u: u), b.evaluate(u: u)) + 1e-12
                #expect(level >= lo && level <= hi,
                        "u=\(u): \(level) escaped the parents' range \(lo)...\(hi)")
            }
        }
    }

    @Test("the curve vehicle tracks the pointwise law, and the gap is PINNED not assumed")
    func curveAndLevelAgreeWithinAMeasuredBound() throws {
        // The file's own caveat, made a number. `curve` cosine-interpolates its
        // union knots; `level` interpolates each parent and sums. They agree at
        // every knot and for any self-blend; between knots of a genuine blend
        // they differ, and if that difference ever became large the projection
        // the store performs would stop describing the gesture.
        var worst = 0.0
        var worstPair = ""
        for scope in EffortPattern.Scope.allCases {
            let group = EffortPattern.library.filter { $0.scope == scope }
            for i in group.indices {
                for j in group.indices where j > i {
                    let ring = EffortRing(patterns: [group[i], group[j]])
                    for phi in sweepAngles(64) {
                        let blend = ring.blend(atAngle: phi, radius: 1)
                        guard let curve = blend.curve(scope: scope) else { continue }
                        for u in sweepU(200) {
                            let d = abs(curve.evaluate(u: u) - blend.level(scope: scope, u: u))
                            if d > worst { worst = d; worstPair = "\(group[i].id)+\(group[j].id)" }
                        }
                    }
                }
            }
        }
        print("[measured] P2 curve-vs-law worst deviation: \(worst) on \(worstPair)")
        // MEASURED 2026-08-19: 0.0189 on flat+sforzandoPiano, over every
        // same-scope library pair at 64 angles × 200 samples. It was 0.132
        // before the mismatched-interval refinement in `curve(scope:)`, so this
        // bound is what stops that refinement being silently removed.
        #expect(worst < 0.025,
                "the projection vehicle drifted \(worst) from the law on \(worstPair)")
        // POSITIVE CONTROL: the deviation must be non-zero somewhere, or the
        // bound above is being met by a loop that never ran.
        #expect(worst > 0, "the sweep found no deviation at all — did it execute?")
    }

    // MARK: - §8.2 step 4 — radius

    @Test("radius scales travel by exactly r and moves NO other geometry")
    func radiusIsAnAffineLevelMapOnly() throws {
        let ring = EffortRing.standard
        let source = try pattern("messaDiVoce")
        let index = try #require(ring.patterns.firstIndex { $0.id == source.id })
        let theta = ring.angle(ofIndex: index)

        let full = try #require(ring.blend(atAngle: theta, radius: 1).curve(scope: .note))
        for r in [1.0, 0.75, 0.5, 0.25, 0.1, 0.01] {
            let curve = try #require(ring.blend(atAngle: theta, radius: r).curve(scope: .note))
            // ⭐ THE P1 BOUNDARY, HELD BY THE ARITHMETIC: an increasing affine
            // map cannot move an argmax or a min/max-normalised position, so
            // the ring selects WHICH shape and never re-derives its geometry.
            #expect(curve.peakPosition == full.peakPosition,
                    "radius \(r) moved peakPosition — the ring must not re-derive geometry")
            #expect(abs(curve.normalisedOnsetLevel - full.normalisedOnsetLevel) < 1e-12)
            #expect(abs(curve.normalisedReleaseLevel - full.normalisedReleaseLevel) < 1e-12)
            #expect(curve.earlyDipPosition == full.earlyDipPosition)
            #expect(abs(curve.travel - r * full.travel) < 1e-12,
                    "radius \(r): travel \(curve.travel) should be \(r * full.travel)")
        }

        // r = 0 collapses to the neutral level exactly — a true no-op, which is
        // only true because `neutral` is 1 here and not the design's estimated
        // 0.5. See the file header.
        let none = try #require(ring.blend(atAngle: theta, radius: 0).curve(scope: .note))
        #expect(none.travel == 0)
        for u in sweepU(64) {
            #expect(abs(none.evaluate(u: u) - EffortRing.defaultNeutral) < 1e-12)
        }
        #expect(EffortRing.defaultNeutral == 1.0)
    }

    @Test("radius and amount are ONE axis: r*s is all that survives")
    func radiusComposesMultiplicativelyWithAmount() throws {
        // The phrase axis under radius is 1 + r(raw − 1); the verb's `amount`
        // gives 1 + s(raw − 1). Same form, so only the product is observable —
        // documented rather than implied, because two knobs that look
        // independent and are not is exactly the ambiguity this design rejects.
        let ring = EffortRing.standard
        let index = try #require(ring.patterns.firstIndex { $0.id == "hairpinCrescendo" })
        let theta = ring.angle(ofIndex: index)

        func effortCurve(radius r: Double, amount s: Double) -> [Double] {
            let blend = ring.blend(atAngle: theta, radius: r)
            return sweepU(64).map { u in
                1 - s * blend.phraseWeight * (1 - blend.level(scope: .phrase, u: u))
            }
        }
        let a = effortCurve(radius: 0.5, amount: 1)
        let b = effortCurve(radius: 1, amount: 0.5)
        for (x, y) in zip(a, b) { #expect(abs(x - y) < 1e-14) }

        // NEGATIVE CONTROL: a different product must give a different curve, or
        // the equality above would hold for a function that ignores both.
        let c = effortCurve(radius: 1, amount: 1)
        #expect(zip(a, c).contains { abs($0 - $1) > 0.05 })
    }

    // MARK: - Scope split

    @Test("noteWeight and phraseWeight sum to 1 everywhere and split the dot")
    func scopeWeightsPartitionTheDot() throws {
        let ring = EffortRing.standard
        for phi in sweepAngles(steps) {
            let blend = ring.blend(atAngle: phi, radius: 1)
            #expect(abs(blend.noteWeight + blend.phraseWeight - 1) < 1e-12)
            #expect(blend.noteWeight >= 0 && blend.phraseWeight >= 0)
        }
        // The standard ring's indices 3, 4, 5 are the three phrase patterns, so
        // there IS an angle where the dot is purely phrase-scoped and one where
        // it is purely note-scoped — without both, the split is untested.
        let purePhrase = ring.blend(atAngle: ring.angle(ofIndex: 4), radius: 1)
        #expect(purePhrase.phraseWeight == 1)
        #expect(purePhrase.curve(scope: .note) == nil)
        let pureNote = ring.blend(atAngle: ring.angle(ofIndex: 1), radius: 1)
        #expect(pureNote.noteWeight == 1)
        #expect(pureNote.curve(scope: .phrase) == nil)
        // And a mixed one: the seam between subToneEntry (7, note) and flat
        // (0, note) is not mixed, but 2↔3 (lateBloom → hairpinCrescendo) is.
        let mixed = ring.blend(atAngle: ring.angle(ofIndex: 2) + ring.spacing / 2, radius: 1)
        #expect(mixed.noteWeight > 0 && mixed.phraseWeight > 0)
        #expect(mixed.curve(scope: .note) != nil && mixed.curve(scope: .phrase) != nil)
    }

    @Test("the crescendo/diminuendo midpoint is CONSTANT at 0.625 — the ring's own null shape")
    func theHairpinMidpointIsAnalyticallyFlat() throws {
        // Adjacent, both phrase-scoped, and exact mirrors: cresc(u) = 0.25 +
        // 0.75k(u) and dim(u) = 1 − 0.75k(u), so a 0.5/0.5 equal-GAIN blend is
        // 0.625 for every u. An equal-power blend is also flat — at 0.884 — so
        // this test asserts the LEVEL, not the flatness. It is the fixture the
        // P2 render gate uses.
        let ring = EffortRing.standard
        let up = try #require(ring.patterns.firstIndex { $0.id == "hairpinCrescendo" })
        let down = try #require(ring.patterns.firstIndex { $0.id == "hairpinDiminuendo" })
        #expect(down == up + 1, "fixture: the two hairpins must be ring neighbours")

        let blend = ring.blend(atAngle: ring.angle(ofIndex: up) + ring.spacing / 2, radius: 1)
        var lo = 1.0, hi = 0.0
        for u in sweepU(steps) {
            let level = blend.level(scope: .phrase, u: u)
            lo = min(lo, level); hi = max(hi, level)
        }
        print("[measured] P2 hairpin midpoint: level \(lo)…\(hi) "
              + "(equal-power would be \(0.5.squareRoot() * 1.25))")
        #expect(abs(lo - 0.625) < 1e-12)
        #expect(abs(hi - 0.625) < 1e-12)
        #expect(abs(hi - 0.5.squareRoot() * 1.25) > 0.25,
                "positive control: equal-power's 0.884 must be far from 0.625")
    }

    // MARK: - Resolution and healing

    @Test("resolve names what is wrong instead of silently falling back")
    func resolveRefusesReadably() throws {
        let ok = try EffortRing.resolve(ids: ["flat", "MESSADIVOCE", "terraced"])
        #expect(ok.patterns.map(\.id) == ["flat", "messaDiVoce", "terraced"])

        #expect(throws: EffortRing.ResolveError.empty) { _ = try EffortRing.resolve(ids: []) }
        #expect(throws: EffortRing.ResolveError.self) {
            _ = try EffortRing.resolve(ids: ["flat", "airRunsOut"])
        }
        #expect(throws: EffortRing.ResolveError.self) {
            _ = try EffortRing.resolve(ids: Array(repeating: "flat", count: 33))
        }
        // Duplicates are LEGAL — a ring of copies is how the identity law is
        // stated, and rejecting them would make §13.2 unwritable.
        let dupes = try EffortRing.resolve(ids: Array(repeating: "lateBloom", count: 4))
        #expect(dupes.count == 4)

        // Every message must name the fix, not merely the fault.
        for error in [EffortRing.ResolveError.empty,
                      .tooMany(count: 99, limit: 32),
                      .unknown(id: "airRunsOut", valid: EffortPattern.libraryIDs)] {
            #expect(error.message.count > 40, "a teaching error, not a code: \(error.message)")
        }
        #expect(EffortRing.ResolveError.unknown(id: "x", valid: EffortPattern.libraryIDs)
            .message.contains("subToneEntry"))
    }

    @Test("an empty ring heals to the library and an over-long one is truncated")
    func initHealsRatherThanLeavingSomethingUnevaluable() {
        #expect(EffortRing(patterns: []).patterns.map(\.id) == EffortPattern.libraryIDs)
        let long = EffortRing(patterns: Array(repeating: EffortPattern.library[0], count: 99))
        #expect(long.count == EffortRing.maxPatterns)
        #expect(EffortRing.standard.count == 8)
    }

    @Test("degrees are the wire's unit and round-trip through radians")
    func degreeConversionIsExact() {
        let ring = EffortRing.standard
        for (i, expected) in [(0, 0.0), (1, 45.0), (4, 180.0), (7, 315.0)] {
            #expect(abs(EffortRing.degrees(fromRadians: ring.angle(ofIndex: i)) - expected) < 1e-9)
            let back = EffortRing.radians(fromDegrees: expected)
            #expect(ring.weights(atAngle: back)[i] == 1,
                    "\(expected)° must land exactly on pattern \(i)")
        }
        // 360 is 0, and a negative angle wraps rather than clamping.
        #expect(EffortRing.radians(fromDegrees: 360) == 0)
        #expect(abs(EffortRing.radians(fromDegrees: -45)
                    - EffortRing.radians(fromDegrees: 315)) < 1e-12)
        #expect(EffortRing.wrap(.nan) == 0)
        #expect(EffortRing.wrap(.infinity) == 0)
    }

    @Test("dominant is deterministic at an exact midpoint")
    func dominantBreaksTiesByRingOrder() {
        let ring = EffortRing.standard
        let blend = ring.blend(atAngle: ring.spacing / 2, radius: 1)
        #expect(abs(blend.members[0].weight - blend.members[1].weight) < 1e-12)
        #expect(blend.dominant.index == 0, "a tie resolves to the LOWER ring index, always")
        #expect(blend.patternIDs == EffortPattern.libraryIDs)
        #expect(abs(blend.weights.reduce(0, +) - 1) < 1e-12)
    }

    @Test("the field law weighs both axes and matches the design's formula")
    func effortAcrossBothAxes() throws {
        let ring = EffortRing.standard
        // lateBloom (note, index 2) ↔ hairpinCrescendo (phrase, index 3).
        let phi = ring.angle(ofIndex: 2) + ring.spacing / 2
        let blend = ring.blend(atAngle: phi, radius: 1)
        let note = try pattern("lateBloom"), phrase = try pattern("hairpinCrescendo")
        for noteU in sweepU(16) {
            for phraseU in sweepU(16) {
                let expected = 0.5 * note.evaluate(u: noteU) + 0.5 * phrase.evaluate(u: phraseU)
                #expect(abs(blend.effort(noteU: noteU, phraseU: phraseU) - expected) < 1e-14)
            }
        }
    }
}
