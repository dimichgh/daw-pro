import CryptoKit
import Foundation
import Testing

@testable import DAWCore

/// m23-ap C2-1: `PitchTimeWarp` (W), the one predicate `hasTimeEdits`, the
/// curve's stored `timeWarp`, and the generator's edited-time branch.
///
/// Design: `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §3.2,
/// §3.4 step 4, §3.10 modes 4 and 5. The digest's time-warp block, the render
/// byte goldens and the importer-vs-render D pin are in DAWEngineTests
/// (`PitchCurveRenderTests`), because they need the engine.
///
/// Every structural claim is asserted on the finished map, never on the
/// construction's intermediate state. A heal that "ran" but left a crossing
/// behind must fail here.
///
/// Deliberately NOT `@MainActor`: this is pure arithmetic, and the
/// `@MainActor` suite count (`MainActorOccupancySiteTests` Leg C) is at its cap.
@Suite("m23-ap C2-1 — PitchTimeWarp, hasTimeEdits, the edited-time generator")
struct PitchTimeWarpTests {

    // MARK: - Fixtures

    static func note(_ start: Double, _ end: Double,
                     startDelta: Double = 0, endDelta: Double = 0,
                     offsetCents: Double = 0,
                     rateHz: Double = 0, depthCents: Double = 0, onset: Double = 0,
                     id: UUID = UUID()) -> NoteSegment {
        NoteSegment(id: id, startSeconds: start, endSeconds: end,
                    detectedHz: 220, detectedConfidence: 0.9,
                    pitchOffsetCents: offsetCents,
                    vibratoRateHz: rateHz, vibratoDepthCents: depthCents,
                    vibratoOnsetSeconds: onset,
                    timeStartDeltaSeconds: startDelta, timeEndDeltaSeconds: endDelta)
    }

    static func set(_ notes: [NoteSegment], retuneMs: Double = 30) -> PitchEditSet {
        PitchEditSet(segments: notes, retuneMs: retuneMs)
    }

    /// A dense, deliberately irregular sweep over `[−0.5, D + 0.5]`, plus every
    /// knot and its two IEEE neighbours. Monotonicity bugs live at knots.
    static func sweep(_ warp: PitchTimeWarp) -> [Double] {
        let d = warp.sourceDurationSeconds
        var out: [Double] = []
        let steps = 4_000
        for k in 0...steps {
            out.append(-0.5 + (d + 1) * Double(k) / Double(steps))
        }
        for s in warp.sourceKnots {
            out.append(contentsOf: [s.nextDown, s, s.nextUp])
        }
        return out.sorted()
    }

    /// Every structural invariant of W, asserted on the finished map.
    ///
    /// ⚠️ The slope bound carries a relative tolerance of 1e-9, and only that.
    /// The heal's interval is exact in real arithmetic and meets the envelope
    /// with EQUALITY at its edges, so in IEEE arithmetic a healed slope can
    /// land an ulp or two outside `structuralFactorRange`. That is rounding,
    /// not a bound violation. A missing heal misses the bound by whole factors.
    static func expectWellFormed(_ warp: PitchTimeWarp, duration d: Double,
                                 _ label: String,
                                 sourceLocation: SourceLocation = #_sourceLocation) {
        let s = warp.sourceKnots
        let e = warp.editedKnots
        #expect(s.count == e.count && s.count >= 2,
                "\(label): knot arrays \(s.count)/\(e.count)", sourceLocation: sourceLocation)
        guard s.count == e.count, s.count >= 2 else { return }
        // Pinned anchors, EXACTLY.
        #expect(s.first == 0 && e.first == 0 && s.last == d && e.last == d,
                "\(label): anchors \(s.first!),\(e.first!) … \(s.last!),\(e.last!); D = \(d)",
                sourceLocation: sourceLocation)
        #expect(warp.sourceDurationSeconds == d, sourceLocation: sourceLocation)
        for k in 1..<s.count {
            #expect(s[k].isFinite && e[k].isFinite,
                    "\(label): non-finite knot \(k)", sourceLocation: sourceLocation)
            #expect(s[k] > s[k - 1],
                    "\(label): source knots not strictly ascending at \(k): \(s[k - 1]) → \(s[k])",
                    sourceLocation: sourceLocation)
            #expect(e[k] > e[k - 1],
                    """
                    \(label): EDITED knots not strictly ascending at \(k): \
                    \(e[k - 1]) → \(e[k]). A crossing or a zero-length piece — the \
                    one thing the heal promises never to produce.
                    """, sourceLocation: sourceLocation)
            let slope = (e[k] - e[k - 1]) / (s[k] - s[k - 1])
            let range = PitchTimeWarp.structuralFactorRange
            #expect(slope >= range.lowerBound * (1 - 1e-9)
                    && slope <= range.upperBound * (1 + 1e-9),
                    "\(label): piece \(k) slope \(slope) outside \(range)",
                    sourceLocation: sourceLocation)
        }
        // Monotone and total, EVALUATED — not only the stored knots.
        var previous = -Double.infinity
        for x in sweep(warp) {
            let w = warp.editedSecond(forSourceSecond: x)
            #expect(w.isFinite, "\(label): W(\(x)) = \(w)", sourceLocation: sourceLocation)
            #expect(w >= previous,
                    "\(label): W went BACKWARDS at \(x): \(previous) → \(w)",
                    sourceLocation: sourceLocation)
            previous = w
            if x < 0 || x > d {
                #expect(w == x, "\(label): W is not the identity outside [0, D] at \(x)",
                        sourceLocation: sourceLocation)
            }
            // Round trip. W is strictly increasing, so W⁻¹(W(s)) = s up to
            // the rounding of two interpolations.
            let back = warp.sourceSecond(forEditedSecond: w)
            #expect(abs(back - x) <= 1e-9 * max(1, abs(x)),
                    "\(label): W⁻¹(W(\(x))) = \(back)", sourceLocation: sourceLocation)
        }
    }

    // MARK: - (1) the predicate

    @Test("hasTimeEdits is the one predicate: either edge, never −0.0, and it breaks identity")
    func hasTimeEditsIsTheOnePredicate() {
        #expect(!Self.note(1, 2).hasTimeEdits)
        #expect(Self.note(1, 2, startDelta: 0.01).hasTimeEdits)
        #expect(Self.note(1, 2, endDelta: -0.01).hasTimeEdits)
        #expect(Self.note(1, 2, startDelta: 0.01, endDelta: 0.02).hasTimeEdits)
        // −0.0 is no edit, exactly as `isIdentity` reads it.
        let negativeZero = Self.note(1, 2, startDelta: -0.0, endDelta: -0.0)
        #expect(!negativeZero.hasTimeEdits)
        #expect(negativeZero.isIdentity)

        #expect(!Self.set([Self.note(1, 2, offsetCents: 30), Self.note(3, 4)]).hasTimeEdits)
        #expect(Self.set([Self.note(1, 2), Self.note(3, 4, endDelta: 0.1)]).hasTimeEdits)
        #expect(!PitchEditSet.empty.hasTimeEdits)

        // A timing-only set is not identity. That is what sends it down the
        // curve path (design §3.4 step 1) and what keys it at all.
        let timingOnly = Self.set([Self.note(1, 2, endDelta: 0.1)])
        #expect(timingOnly.hasTimeEdits)
        #expect(!timingOnly.isIdentity)
        // Agreement with identity on every segment shape above: a segment
        // with time edits is never identity.
        for segment in [Self.note(1, 2, startDelta: 0.01), Self.note(1, 2, endDelta: 0.3)] {
            #expect(segment.hasTimeEdits && !segment.isIdentity)
        }
    }

    // MARK: - (2) nil exactly when it must be

    @Test("make is nil exactly for untimed sets and for a missing or invalid D")
    func makeIsNilExactlyWhenItMustBe() {
        let untimed = Self.set([Self.note(1, 2, offsetCents: 40)])
        #expect(PitchTimeWarp.make(editSet: untimed, sourceDurationSeconds: 4) == nil)
        #expect(PitchTimeWarp.make(editSet: .empty, sourceDurationSeconds: 4) == nil)
        let negativeZero = Self.set([Self.note(1, 2, startDelta: -0.0, endDelta: -0.0)])
        #expect(PitchTimeWarp.make(editSet: negativeZero, sourceDurationSeconds: 4) == nil)

        let timed = Self.set([Self.note(1, 2, endDelta: 0.1)])
        for d in [0.0, -1.0, .nan, .infinity, -.infinity] {
            #expect(PitchTimeWarp.make(editSet: timed, sourceDurationSeconds: d) == nil,
                    "D = \(d) must not produce a map")
        }
        // Positive control: the same set with a real D does produce one.
        #expect(PitchTimeWarp.make(editSet: timed, sourceDurationSeconds: 4) != nil)
    }

    // MARK: - (3) a set the setter would write passes through EXACTLY

    /// The design's own C2-2 burst fixture (§3.4 step 5): one note [1.0, 1.6]
    /// lengthened by 0.3 s (factor 1.5), the next note [2.4, 3.0] untouched,
    /// so the gap between them is compressed to 0.625.
    @Test("W pins its anchors, and a well-formed set passes through bit for bit")
    func wellFormedSetPassesThroughExactly() throws {
        let d = 4.0
        let set = Self.set([Self.note(1.0, 1.6, endDelta: 0.3), Self.note(2.4, 3.0)])
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: d))
        Self.expectWellFormed(warp, duration: d, "burst fixture")
        #expect(!warp.healed)
        #expect(warp.sourceKnots == [0, 1.0, 1.6, 2.4, 3.0, 4.0])
        #expect(warp.editedKnots == [0, 1.0, 1.6 + 0.3, 2.4, 3.0, 4.0],
                "a well-formed set must pass through the heal BIT FOR BIT")
        // The physics the knots mean.
        #expect(abs(warp.localFactor(atSourceSecond: 1.3) - 1.5) < 1e-12)
        #expect(abs(warp.localFactor(atSourceSecond: 2.0) - 0.625) < 1e-12)
        #expect(warp.localFactor(atSourceSecond: 0.5) == 1)
        #expect(warp.localFactor(atSourceSecond: 3.5) == 1)
        #expect(abs(warp.editedSecond(forSourceSecond: 1.3) - 1.45) < 1e-12)
        #expect(abs(warp.sourceSecond(forEditedSecond: 1.45) - 1.3) < 1e-12)
        // At a knot, W answers the knot exactly.
        #expect(warp.editedSecond(forSourceSecond: 1.6) == 1.6 + 0.3)
        // Nothing past the moved edges moves: the file's length is conserved.
        #expect(warp.editedSecond(forSourceSecond: 3.25) == 3.25)
    }

    /// Design §3.6: a split makes two notes that abut exactly, and the setter
    /// writes the SAME delta to the shared edge. The two knots coincide, and
    /// "first wins" must then be a no-op, not a heal.
    @Test("a connected edge the setter moved on both notes is one knot, and not a heal")
    func connectedEdgeIsOneKnotNotAHeal() throws {
        let set = Self.set([Self.note(1.0, 1.3, endDelta: 0.1),
                            Self.note(1.3, 1.6, startDelta: 0.1)])
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: 4))
        Self.expectWellFormed(warp, duration: 4, "connected pair")
        #expect(!warp.healed)
        #expect(warp.sourceKnots == [0, 1.0, 1.3, 1.6, 4.0])
        #expect(warp.editedSecond(forSourceSecond: 1.3) == 1.3 + 0.1)
    }

    /// ⭐ **FINDING (g1), pinned.** The design's step 2 reads "drop every knot
    /// at source ≤ 0 or ≥ D, and set `healed`". `voicedRuns` emits a note at
    /// source 0 whenever a vocal starts on the file's first frame, and notes
    /// routinely run past D (a run ends one frame period after its last
    /// frame). Under that literal reading, every such clip retimed anywhere
    /// else would read as healed. `healed` means "W does not honour a
    /// requested knot", and `(0, 0)` and an untouched edge past D are honoured.
    @Test("an untouched edge at source 0 or past D is honoured, not healed")
    func untouchedEdgesAtTheFileEdgesAreNotHeals() throws {
        let d = 3.0
        let set = Self.set([Self.note(0, 0.8),                       // starts ON the file's first frame
                            Self.note(1.2, 1.8, endDelta: 0.15),    // a real edit
                            Self.note(2.5, d + 0.012)])             // runs past D
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: d))
        Self.expectWellFormed(warp, duration: d, "edges at 0 and past D")
        #expect(!warp.healed,
                "a set with no out-of-bounds request must not read as healed")
        // Positive control: MOVE the start that sits on source 0, and it IS a
        // heal, because the file's first sample cannot move.
        var moved = set
        moved.segments[0].timeStartDeltaSeconds = 0.05
        let healed = try #require(PitchTimeWarp.make(editSet: moved, sourceDurationSeconds: d))
        Self.expectWellFormed(healed, duration: d, "moved start at 0")
        #expect(healed.healed)
        #expect(healed.editedSecond(forSourceSecond: 0) == 0)
    }

    // MARK: - (4) adversarial JSON: healed, and SAID so

    /// One hand-written payload per failure the heal exists for. Each is
    /// decoded through `Codable`, exactly as a hand-edited or agent-written
    /// project arrives. For every case:
    ///  * the finished map is well-formed (monotone, total, pinned, bounded);
    ///  * `healed` is true, so a caller must say so;
    ///  * the specific knot that was out of bounds is NOT honoured, which
    ///    proves the heal acted rather than the flag being set by accident;
    ///  * the finished knots are THE DESIGN'S heal (§3.2 steps 2 to 4),
    ///    computed BY HAND from its formula and written below, not read back
    ///    from the code;
    ///  * a SANE TWIN of the same geometry reads `healed == false`, so the flag
    ///    discriminates.
    ///
    /// ⚠️ **WHY THE HAND-COMPUTED KNOTS ARE HERE: A PLANT SHOWED THEY WERE
    /// NEEDED.** With the step-4 clamp removed and only `make`'s step-5
    /// backstop left (which DROPS a knot it cannot keep), every structural
    /// assertion above still passed on all seven cases. Dropping also yields
    /// a monotone, pinned, bounded map. Only the seeded fuzz's slope bound
    /// went red. A heal is a specified rule, and the display and the render
    /// must agree on its OUTPUT, so the output is pinned.
    struct Adversary {
        let label: String
        let duration: Double
        let json: String
        let saneTwinJSON: String
        /// The requested knot that cannot be honoured, (source, edited).
        let offending: (Double, Double)
        /// The finished knots, by hand from the design's formula.
        let expectedSources: [Double]
        let expectedEdited: [Double]
    }

    static func segmentsJSON(_ segments: [String]) -> String {
        """
        {"analysisVersion":1,"segments":[\(segments.joined(separator: ","))]}
        """
    }

    static func seg(_ id: Int, _ start: Double, _ end: Double,
                    startDelta: Double? = nil, endDelta: Double? = nil) -> String {
        var fields = [
            "\"id\":\"C2100000-0000-4000-8000-00000000000\(id)\"",
            "\"startSeconds\":\(start)", "\"endSeconds\":\(end)",
            "\"detectedHz\":220", "\"detectedConfidence\":0.9",
        ]
        if let startDelta { fields.append("\"timeStartDeltaSeconds\":\(startDelta)") }
        if let endDelta { fields.append("\"timeEndDeltaSeconds\":\(endDelta)") }
        return "{" + fields.joined(separator: ",") + "}"
    }

    static let adversaries: [Adversary] = [
        // CROSSING INTERVALS. The raw edited knots go BACKWARDS: 1.0, 3.5,
        // 1.2, 3.0. Without the heal W is not a function of time. The pass
        // runs forward, so the EARLIER knot (2.0 → 3.5) stands and the later
        // one (2.1 → 1.2) is the one moved.
        Adversary(
            label: "crossing intervals",
            duration: 5,
            json: segmentsJSON([seg(1, 1.0, 2.0, endDelta: 1.5),
                                seg(2, 2.1, 3.0, startDelta: -0.9)]),
            saneTwinJSON: segmentsJSON([seg(1, 1.0, 2.0, endDelta: 0.03),
                                        seg(2, 2.1, 3.0, startDelta: -0.02)]),
            offending: (2.1, 2.1 - 0.9),
            // k=3 (2.1): [max(lo=0.525, 3.5+0.25·0.1=3.525), min(hi=4.275, 3.5+4·0.1=3.9)] → 3.525.
            // k=4 (3.0): [max(lo=0.75, 3.525+0.25·0.9=3.75), min(hi=4.5, 3.525+3.6)] → 3.75.
            expectedSources: [0, 1, 2, 2.1, 3, 5],
            expectedEdited: [0, 1, 3.5, 3.525, 3.75, 5]),
        // A DELTA PAST THE FILE'S START: an edited start before source 0.
        Adversary(
            label: "edited start before the file",
            duration: 5,
            json: segmentsJSON([seg(1, 0.3, 1.0, startDelta: -2.0)]),
            saneTwinJSON: segmentsJSON([seg(1, 0.3, 1.0, startDelta: -0.05)]),
            offending: (0.3, 0.3 - 2.0),
            // k=1 (0.3): [max(lo=max(0.075, 5−4·4.7), 0+0.25·0.3), min(hi=1.2, 0+4·0.3)] → 0.075.
            expectedSources: [0, 0.3, 1.0, 5],
            expectedEdited: [0, 0.075, 1.0, 5]),
        // A DELTA PAST THE FILE'S END: an edited end after D.
        Adversary(
            label: "edited end after the file",
            duration: 5,
            json: segmentsJSON([seg(1, 4.0, 4.9, endDelta: 3.0)]),
            saneTwinJSON: segmentsJSON([seg(1, 4.0, 4.9, endDelta: 0.02)]),
            offending: (4.9, 4.9 + 3.0),
            // k=2 (4.9): [max(lo=max(1.225, 5−4·0.1=4.6), 4+0.225), min(hi=min(19.6, 5−0.25·0.1=4.975), 4+3.6)] → 4.975.
            expectedSources: [0, 4.0, 4.9, 5],
            expectedEdited: [0, 4.0, 4.975, 5]),
        // A MOVED KNOT ON THE FILE'S FIRST SAMPLE, which cannot move.
        Adversary(
            label: "moved start at source 0",
            duration: 5,
            json: segmentsJSON([seg(1, 0.0, 1.0, startDelta: 0.2)]),
            saneTwinJSON: segmentsJSON([seg(1, 0.0, 1.0, endDelta: 0.1)]),
            offending: (0.0, 0.2),
            // Step 2: the knot at source 0 merges into the (0, 0) anchor.
            expectedSources: [0, 1, 5],
            expectedEdited: [0, 1, 5]),
        // A MOVED KNOT PAST THE FILE'S END, which W cannot reach.
        Adversary(
            label: "moved end past D",
            duration: 5,
            json: segmentsJSON([seg(1, 4.5, 5.5, endDelta: 0.1)]),
            saneTwinJSON: segmentsJSON([seg(1, 4.5, 5.5, startDelta: 0.05)]),
            offending: (5.5, 5.6),
            // Step 2: the knot past D merges into the (D, D) anchor.
            expectedSources: [0, 4.5, 5],
            expectedEdited: [0, 4.5, 5]),
        // ABUTTING KNOTS WITH UNEQUAL DELTAS: one source instant asked to be
        // two edited instants. First wins (the left note's end).
        Adversary(
            label: "abutting knots, unequal deltas",
            duration: 5,
            json: segmentsJSON([seg(1, 1.0, 2.0, endDelta: 0.2),
                                seg(2, 2.0, 3.0, startDelta: -0.1)]),
            saneTwinJSON: segmentsJSON([seg(1, 1.0, 2.0, endDelta: 0.2),
                                        seg(2, 2.0, 3.0, startDelta: 0.2)]),
            offending: (2.0, 1.9),
            // Step 3: first wins, so source 2.0 keeps the left end's 2.2.
            expectedSources: [0, 1, 2, 3, 5],
            expectedEdited: [0, 1, 2.2, 3, 5]),
        // A FINITE BUT ABSURD DELTA: in bounds of Double, not of the file.
        Adversary(
            label: "absurd finite delta",
            duration: 5,
            json: segmentsJSON([seg(1, 1.0, 2.0, endDelta: 1e300)]),
            saneTwinJSON: segmentsJSON([seg(1, 1.0, 2.0, endDelta: 0.5)]),
            offending: (2.0, 2.0 + 1e300),
            // k=2 (2.0): [max(lo=0.5, 1+0.25), min(hi=min(8, 5−0.25·3=4.25), 1+4)] → 4.25.
            expectedSources: [0, 1, 2, 5],
            expectedEdited: [0, 1, 4.25, 5]),
    ]

    @Test("adversarial JSON is healed into a well-formed W, and healed is SAID",
          arguments: Self.adversaries.indices)
    func adversarialJSONIsHealedAndSaid(index: Int) throws {
        let adversary = Self.adversaries[index]
        let label = adversary.label
        let decoded = try JSONDecoder().decode(PitchEditSet.self,
                                               from: Data(adversary.json.utf8))
        #expect(decoded.hasTimeEdits, "\(label): the fixture must carry time edits")
        let warp = try #require(PitchTimeWarp.make(editSet: decoded,
                                                   sourceDurationSeconds: adversary.duration))
        Self.expectWellFormed(warp, duration: adversary.duration, label)
        #expect(warp.healed, "\(label): the heal moved the user's request and did not say so")
        let (s, e) = adversary.offending
        #expect(!(abs(warp.editedSecond(forSourceSecond: s) - e) <= PitchTimeWarp.healToleranceSeconds),
                "\(label): the out-of-bounds knot (\(s) → \(e)) was honoured, so nothing was healed")
        #expect(warp.sourceKnots.count == adversary.expectedSources.count
                && zip(warp.sourceKnots, adversary.expectedSources).allSatisfy { abs($0 - $1) <= 1e-12 }
                && zip(warp.editedKnots, adversary.expectedEdited).allSatisfy { abs($0 - $1) <= 1e-12 },
                """
                \(label): the heal's output is not the design's. Got sources \(warp.sourceKnots), \
                edited \(warp.editedKnots); by hand from §3.2: sources \(adversary.expectedSources), \
                edited \(adversary.expectedEdited).
                """)

        // The flag discriminates: the same geometry, in bounds, is not healed.
        let twin = try JSONDecoder().decode(PitchEditSet.self,
                                            from: Data(adversary.saneTwinJSON.utf8))
        let twinWarp = try #require(PitchTimeWarp.make(editSet: twin,
                                                       sourceDurationSeconds: adversary.duration))
        Self.expectWellFormed(twinWarp, duration: adversary.duration, "\(label) (sane twin)")
        #expect(!twinWarp.healed, "\(label): the sane twin reads as healed")
    }

    /// The abutting case's rule, stated as a value: FIRST wins, which is
    /// `PitchEditSet.canonical`'s own rule for overlaps.
    @Test("abutting knots with unequal deltas: the left note's end wins")
    func abuttingUnequalDeltasFirstWins() throws {
        let set = Self.set([Self.note(1.0, 2.0, endDelta: 0.2),
                            Self.note(2.0, 3.0, startDelta: -0.1)])
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: 5))
        #expect(warp.healed)
        #expect(warp.editedSecond(forSourceSecond: 2.0) == 2.0 + 0.2)
        #expect(warp.sourceKnots == [0, 1.0, 2.0, 3.0, 5.0])
    }

    /// ⭐ **FINDING (g4), pinned: the heal's proof is real arithmetic.** Two
    /// knots one ulp apart give a lower bound `e[k−1] + 0.25·Δs` that rounds
    /// back to `e[k−1]` in IEEE doubles, a zero-length edited piece. This is
    /// the set that would produce one. `minimumKnotSpacingSeconds` merges the
    /// pair, and `make`'s strictness guard (step 5) would drop the second knot
    /// if the merge ever let it through. This asserts the claim, "no
    /// zero-length piece", whichever of the two holds it. The ask below also
    /// CROSSES, so the pair cannot survive by luck.
    @Test("knots one ulp apart cannot make a zero-length piece")
    func oneUlpKnotSpacingCannotCollapseAPiece() throws {
        let start = 1.0
        let end = start.nextUp
        #expect(end > start, "the fixture must be a real, positive-length note")
        let set = Self.set([Self.note(start, end, startDelta: 0.5, endDelta: -0.5)])
        #expect(set.segments.count == 1, "canonical must keep a one-ulp note")
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: 4))
        Self.expectWellFormed(warp, duration: 4, "one-ulp note")
        #expect(warp.healed)
    }

    /// Seeded, so a failure reproduces. Random sets well outside anything a
    /// setter writes: overlapping edges, huge deltas both ways, notes past D.
    /// The map must be well-formed every time, and `healed` must be exactly
    /// "some request is not honoured".
    @Test("seeded fuzz: every random set heals into a well-formed W")
    func seededFuzzAlwaysWellFormed() throws {
        var rng = WarpFuzzRNG(seed: 0xC2_1_5EED)
        var healedCount = 0
        var cleanCount = 0
        for trial in 0..<300 {
            let d = 0.5 + 9.5 * rng.unit()
            var notes: [NoteSegment] = []
            var cursor = rng.unit() < 0.2 ? 0 : rng.unit() * 0.5
            let count = 1 + Int(rng.unit() * 6)
            for _ in 0..<count {
                let length = 0.01 + rng.unit() * 1.5
                let spread = rng.unit() < 0.3 ? 3.0 : 0.05
                notes.append(Self.note(
                    cursor, cursor + length,
                    startDelta: rng.unit() < 0.5 ? (rng.unit() - 0.5) * 2 * spread : 0,
                    endDelta: rng.unit() < 0.5 ? (rng.unit() - 0.5) * 2 * spread : 0))
                // Sometimes abut exactly, sometimes overlap (canonical heals
                // that first-wins), usually leave a gap.
                let roll = rng.unit()
                cursor += roll < 0.2 ? length : (roll < 0.3 ? length * 0.5 : length + rng.unit())
            }
            let set = Self.set(notes)
            guard set.hasTimeEdits else { continue }
            let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: d))
            Self.expectWellFormed(warp, duration: d, "fuzz trial \(trial)")
            // `healed` agrees with its definition, evaluated independently here.
            var honoured = true
            for segment in PitchEditSet.canonical(set.segments) {
                for (s, e) in [(segment.startSeconds, segment.startSeconds + segment.timeStartDeltaSeconds),
                               (segment.endSeconds, segment.endSeconds + segment.timeEndDeltaSeconds)]
                where !(abs(warp.editedSecond(forSourceSecond: s) - e)
                        <= PitchTimeWarp.healToleranceSeconds) {
                    honoured = false
                }
            }
            #expect(warp.healed == !honoured, "fuzz trial \(trial): healed disagrees with its definition")
            if warp.healed { healedCount += 1 } else { cleanCount += 1 }
        }
        // The fuzz must exercise BOTH outcomes, or it tested one branch.
        #expect(healedCount > 20 && cleanCount > 20,
                "fuzz exercised healed \(healedCount) / clean \(cleanCount)")
    }

    // MARK: - (5) the contracts callers rely on

    @Test("inverse, local factor and non-finite inputs follow their documented contracts")
    func evaluationContracts() throws {
        let d = 4.0
        let set = Self.set([Self.note(1.0, 1.6, endDelta: 0.3), Self.note(2.4, 3.0)])
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: d))
        // The last piece owns D (the render's flush reads it there).
        let lastSlope = (warp.editedKnots[warp.editedKnots.count - 1] - warp.editedKnots[warp.editedKnots.count - 2])
            / (warp.sourceKnots[warp.sourceKnots.count - 1] - warp.sourceKnots[warp.sourceKnots.count - 2])
        #expect(warp.localFactor(atSourceSecond: d) == lastSlope)
        // Outside [0, D] and non-finite: the identity's factor.
        for x in [-0.1, d + 0.1, .nan, .infinity, -.infinity] {
            #expect(warp.localFactor(atSourceSecond: x) == 1)
        }
        // A non-finite input returns itself, both ways.
        #expect(warp.editedSecond(forSourceSecond: .infinity) == .infinity)
        #expect(warp.editedSecond(forSourceSecond: -.infinity) == -.infinity)
        #expect(warp.editedSecond(forSourceSecond: .nan).isNaN)
        #expect(warp.sourceSecond(forEditedSecond: .nan).isNaN)
        // The anchors are fixed points of both maps.
        #expect(warp.editedSecond(forSourceSecond: 0) == 0)
        #expect(warp.editedSecond(forSourceSecond: d) == d)
        #expect(warp.sourceSecond(forEditedSecond: 0) == 0)
        #expect(warp.sourceSecond(forEditedSecond: d) == d)
    }

    // MARK: - (6) the generator runs in EDITED time; nothing else moves

    /// A 5.5 Hz generator on a note stretched 1.4×. The design's own numbers
    /// (F10): evaluated in source time it would play at 5.5 / 1.4 ≈ 3.9 Hz.
    /// Here the generator term is asserted against its formula in EDITED time,
    /// and against the untimed curve, which must differ.
    @Test("the synthesised generator runs in edited time, phase and envelope both")
    func generatorRunsInEditedTime() throws {
        let d = 4.0
        let rate = 5.5
        let depthCents = 50.0
        let onset = 0.3
        let offsetCents = 20.0
        let set = Self.set([
            Self.note(1.0, 2.0, endDelta: 0.4, offsetCents: offsetCents,
                      rateHz: rate, depthCents: depthCents, onset: onset),
            Self.note(2.6, 3.0),
        ])
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: d))
        #expect(!warp.healed)
        #expect(abs(warp.localFactor(atSourceSecond: 1.5) - 1.4) < 1e-12)
        let timed = PitchCorrectionCurve.make(editSet: set, timeWarp: warp)
        let untimed = PitchCorrectionCurve.make(editSet: set)
        #expect(timed.timeWarp == warp)
        #expect(untimed.timeWarp == nil)

        func smoothstep(_ x: Double) -> Double {
            let c = min(max(x, 0), 1)
            return c * c * (3 - 2 * c)
        }
        let editedStart = warp.editedSecond(forSourceSecond: 1.0)
        var differs = 0
        // Inside the note, clear of both boundary ramps (15 ms half-ramps).
        for k in 0...400 {
            let s = 1.05 + 0.9 * Double(k) / 400
            let e = warp.editedSecond(forSourceSecond: s)
            let expected = offsetCents / 100
                + depthCents / 100 * smoothstep((e - editedStart) / onset) * sin(2 * .pi * rate * e)
            let got = timed.semitones(atSourceSecond: s)
            #expect(abs(got - expected) < 1e-12,
                    "timed curve at source \(s): \(got), expected \(expected) (edited time \(e))")
            // The one-argument form IS the two-argument form with W(s).
            #expect(got.bitPattern == timed.semitones(atSourceSecond: s, editedSecond: e).bitPattern)
            if abs(got - untimed.semitones(atSourceSecond: s)) > 1e-6 { differs += 1 }
        }
        // Discriminator: the untimed curve is the source-time answer, and it
        // must be far from the edited-time one across the note.
        #expect(differs > 300, "the edited-time generator matched the source-time one at \(401 - differs) of 401 points")

        // THE PHYSICS, as a rate: count the generator's zero crossings across
        // the note in SOURCE seconds. In edited time the rate is 5.5 Hz, so in
        // source time it runs 1.4× faster.
        func crossings(_ curve: PitchCorrectionCurve) -> Int {
            var count = 0
            var last: Double?
            for k in 0...9_000 {
                let s = 1.35 + 0.6 * Double(k) / 9_000   // past the fade, inside the note
                let v = curve.semitones(atSourceSecond: s) - offsetCents / 100
                if let last, (last < 0) != (v < 0) { count += 1 }
                last = v
            }
            return count
        }
        let timedRate = Double(crossings(timed)) / 2 / 0.6
        let untimedRate = Double(crossings(untimed)) / 2 / 0.6
        #expect(abs(timedRate - rate * 1.4) < 1.0,
                "timed generator runs at \(timedRate) Hz in source time; 5.5 × 1.4 = 7.7 expected")
        #expect(abs(untimedRate - rate) < 1.0,
                "untimed generator runs at \(untimedRate) Hz in source time; 5.5 expected")
    }

    /// ⭐ The boring invariance control: in C2-1, W touches ONLY the generator.
    /// A retimed set with no generator, contour-shaped or not, evaluates bit
    /// for bit the same with and without its warp. The gates and the shaping
    /// stay in source time (design §3.4 step 4).
    @Test("W moves only the generator: without one, the curve is bit-identical with or without W")
    func warpTouchesOnlyTheGenerator() throws {
        let d = 4.0
        var shaped = Self.note(1.0, 1.6, endDelta: 0.3, offsetCents: 35)
        shaped.driftScale = 0.4
        shaped.vibratoScale = 0.2
        let set = Self.set([shaped, Self.note(2.4, 3.0, startDelta: -0.05, offsetCents: -15)],
                           retuneMs: 60)
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: d))
        let contour = Self.contourFrames()
        let with = PitchCorrectionCurve.make(editSet: set, contour: contour,
                                             contourValueOffsetSeconds: 0.008,
                                             clipPitchShiftSemitones: 0.5, timeWarp: warp)
        let without = PitchCorrectionCurve.make(editSet: set, contour: contour,
                                                contourValueOffsetSeconds: 0.008,
                                                clipPitchShiftSemitones: 0.5)
        #expect(with.unresolvedShapingSegmentIDs.isEmpty, "the fixture must actually shape")
        #expect(with != without, "Equatable must see the warp")
        for t in Self.probeSeconds {
            #expect(with.semitones(atSourceSecond: t).bitPattern
                    == without.semitones(atSourceSecond: t).bitPattern,
                    "W moved a non-generator term at source \(t)")
        }
    }

    // MARK: - (7) the untimed curve is the pre-C2 curve, bit for bit

    /// Captured on the pre-change tree (2026-09-24 05:58 snapshot, isolated
    /// copy, two identical runs) by building each curve through the pre-C2
    /// `make` and hashing `semitones(atSourceSecond:)`'s bit patterns at
    /// `probeSeconds`. Every curve here is built WITHOUT a warp, which is what
    /// every existing caller does, so none of these may move. The timed sets
    /// are included on purpose: a curve built without W must be today's curve
    /// whatever the set carries.
    static let preC2CurveGoldens: [(set: String, shift: Double, hex: String)] = [
        ("offset", 0, "5cca6029380a095c282dd5bcb955830fa1df9a5c60cdd1c1cbd9d70beafbb841"),
        ("offset", 1.5, "04f2d2cefc52631acde14c1b06636cafca7fdab279e8262a30a209c89647ccf3"),
        ("shaping", 0, "b2b3c9a7cdfb34560636b0717386053a403f096396fc1ceb5d3b1c9468c87459"),
        ("shaping", 1.5, "913b119af95e95846997e7aa32acfd251170cfd07203e859015ee92f6f3207a4"),
        ("generator", 0, "be1a41a7b0cbe42916049ea5c53828ac5ea7a018931b61be8d5d4d5297e87444"),
        ("generator", 1.5, "27b261c8cb39e709479e7da980a6ef5d11d70cfd537d971ce3662228bd122893"),
        ("delta", 0, "298d43f5d83e4850e837576b73f6933501b1cdd179330b189439b0821a0a4da1"),
        ("delta", 1.5, "171c05c3ec84ed7e2fdd3df78ffa526ec17d78483d396ff52eb73c26ace6bb1c"),
        ("timingOnly", 0, "2ed97d4d81eacca2c31491247c1f3b8f66ed148d893fa776fdf6a8c34fe183d7"),
        ("timingOnly", 1.5, "9fb3130b8cf0583898406bbe4570d2cf2b29a8e51dcb5b4f080ee37d85805fe1"),
        ("startDelta", 0, "a05dda6eddcda8d716b8968d2d60d13147840671efe9452395e84ca02635620b"),
        ("startDelta", 1.5, "38ec6e42f8734c954ed5f71c553e03667008adf47834d23f90b9f83931174b8e"),
    ]
    static let preC2ContourCurveGoldens: [(set: String, hex: String)] = [
        ("shaping", "f65fc6a227b7d6d0f567fa7813fe13a4f5f0dece3aa2b7ac60058fcc30b634d4"),
        ("generator", "07857df23eed5e744bcf60cff2cdcc74b5ccdb95105b560d457131b847d82756"),
    ]

    @Test("an untimed curve evaluates bit-identically to the pre-C2 curve")
    func untimedCurveIsBitIdenticalToPreC2() throws {
        for golden in Self.preC2CurveGoldens {
            let set = try #require(C21Fixtures.sets[golden.set])
            let curve = PitchCorrectionCurve.make(editSet: set,
                                                  clipPitchShiftSemitones: golden.shift)
            #expect(Self.curveDigest(curve) == golden.hex,
                    "\(golden.set) @ shift \(golden.shift): the curve moved since pre-C2")
        }
        let contour = Self.contourFrames()
        for golden in Self.preC2ContourCurveGoldens {
            let set = try #require(C21Fixtures.sets[golden.set])
            let curve = PitchCorrectionCurve.make(editSet: set, contour: contour,
                                                  contourValueOffsetSeconds: 0.008,
                                                  clipPitchShiftSemitones: 0.5)
            #expect(curve.unresolvedShapingSegmentIDs.isEmpty)
            #expect(Self.curveDigest(curve) == golden.hex,
                    "\(golden.set) with contour: the curve moved since pre-C2")
        }
        // The matcher CAN fail: the same digest of a curve that differs by a
        // semitone of clip shift must not match its golden.
        let moved = PitchCorrectionCurve.make(editSet: try #require(C21Fixtures.sets["offset"]),
                                              clipPitchShiftSemitones: 1)
        #expect(Self.curveDigest(moved) != Self.preC2CurveGoldens[0].hex)
    }

    /// The contour display and render share: `PitchRenderContour.curve` must
    /// pass the warp through, or a display building W would still draw a
    /// source-time wobble.
    @Test("PitchRenderContour.curve passes the warp through, and nothing else changes")
    func renderContourCurvePassesTheWarp() throws {
        let set = Self.set([Self.note(1.0, 2.0, endDelta: 0.2, rateHz: 5, depthCents: 30)])
        let warp = try #require(PitchTimeWarp.make(editSet: set, sourceDurationSeconds: 4))
        let contour = PitchRenderContour.unavailable(reason: "fixture")
        #expect(contour.curve(editSet: set, clipPitchShiftSemitones: 0.25, timeWarp: warp)
            == PitchCorrectionCurve.make(editSet: set, clipPitchShiftSemitones: 0.25, timeWarp: warp))
        #expect(contour.curve(editSet: set, clipPitchShiftSemitones: 0.25)
            == PitchCorrectionCurve.make(editSet: set, clipPitchShiftSemitones: 0.25))
        #expect(contour.curve(editSet: set, clipPitchShiftSemitones: 0.25, timeWarp: warp)
            != contour.curve(editSet: set, clipPitchShiftSemitones: 0.25))
    }

    // MARK: - Shared instruments (identical to the pre-change capture's)

    static let probeSeconds: [Double] = {
        var out: [Double] = []
        for k in -50..<3000 { out.append(Double(k) / 997) }
        out.append(contentsOf: [-1e300, -0.0, 0.0, 1e300, .infinity, -.infinity, .nan,
                                .leastNonzeroMagnitude, 0.25, 1.25, 1.9, 0.5, 1.0, 1.1, 1.4])
        return out
    }()

    static func curveDigest(_ curve: PitchCorrectionCurve) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(probeSeconds.count * 8)
        for t in probeSeconds {
            withUnsafeBytes(of: curve.semitones(atSourceSecond: t).bitPattern.littleEndian) {
                bytes.append(contentsOf: $0)
            }
        }
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 62.5 fps over 0…2 s: a 220 Hz note with a ±30 cent 5 Hz wobble and a
    /// three-frame hole at 1.2 s.
    static func contourFrames() -> [ClipPitchFrame] {
        var frames: [ClipPitchFrame] = []
        for k in 0..<125 {
            let t = Double(k) / 62.5
            if k >= 75 && k < 78 {
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: 0.1,
                                             levelDbfs: -60, absence: .belowConfidence))
                continue
            }
            let cents = 30 * sin(2 * .pi * 5 * t)
            frames.append(ClipPitchFrame(timeSeconds: t,
                                         frequencyHz: 220 * pow(2, cents / 1200),
                                         confidence: 0.95, levelDbfs: -12, absence: nil))
        }
        return frames
    }
}

/// The C2-1 fixture sets, value for value the ones the pre-change capture
/// hashed. `offset` and `shaping` are `NoteVibratoGeneratorTests`'
/// `legacyOffsetSet` / `legacyShapingSet`, restated here because that suite
/// lives in DAWEngineTests.
enum C21Fixtures {
    static let idA = UUID(uuidString: "A0000000-0000-4000-8000-000000000001")!
    static let idB = UUID(uuidString: "A0000000-0000-4000-8000-000000000002")!

    static let sets: [String: PitchEditSet] = [
        "offset": PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.25, endSeconds: 1.25,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: -37.5),
                NoteSegment(id: idB, startSeconds: 1.25, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81,
                            pitchOffsetCents: 22.0),
            ],
            retuneMs: 45),
        "shaping": PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.25, endSeconds: 1.25,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: -37.5,
                            driftScale: 0, vibratoScale: 0),
            ],
            retuneMs: 30),
        "generator": PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.25, endSeconds: 1.25,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: -37.5,
                            vibratoRateHz: 5.5, vibratoDepthCents: 40,
                            vibratoOnsetSeconds: 0.2),
                NoteSegment(id: idB, startSeconds: 1.25, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81,
                            pitchOffsetCents: 22.0),
            ],
            retuneMs: 45),
        "delta": PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.5, endSeconds: 1.0,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: 25,
                            timeEndDeltaSeconds: 0.1),
                NoteSegment(id: idB, startSeconds: 1.4, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81,
                            pitchOffsetCents: -12),
            ],
            retuneMs: 30),
        "timingOnly": PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.5, endSeconds: 1.0,
                            detectedHz: 220, detectedConfidence: 0.9,
                            timeEndDeltaSeconds: 0.1),
                NoteSegment(id: idB, startSeconds: 1.4, endSeconds: 1.9,
                            detectedHz: 233.08, detectedConfidence: 0.81),
            ],
            retuneMs: 30),
        "startDelta": PitchEditSet(
            analysisVersion: 1,
            segments: [
                NoteSegment(id: idA, startSeconds: 0.5, endSeconds: 1.0,
                            detectedHz: 220, detectedConfidence: 0.9,
                            pitchOffsetCents: 25,
                            timeStartDeltaSeconds: -0.05),
            ],
            retuneMs: 30),
    ]
}

/// A seeded generator, so the fuzz reproduces. SplitMix64 (Steele, Lea and
/// Flood 2014), never `SystemRandomNumberGenerator`.
private struct WarpFuzzRNG {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}
