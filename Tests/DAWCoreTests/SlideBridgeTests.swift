import Foundation
import Testing
@testable import DAWCore

// vf-18 (W9-SLIDE measured it; W9-SLRV ruled "carry + hold"; W9-SLFX built it,
// design `$S/w9/SLRV/REVIEW.md`): a GROUP pitch move must move a followed
// slide by exactly the move, never twice it.
//
// The bridge ADDS the neighbours' own offsets to a followed slide's own offset
// (natural tuning §4.b.3: a lone drag of the slide still moves it). So the
// LITERAL state "every note +M" plays the slide at about 2M, and it stays
// that way on purpose: it is what the literal writer (`clip.setNotePitches
// {notes}`) asks for. A move of notes TOGETHER goes through the one group
// transform, `PitchEditSet.applyingGroupPitchMove`, which CARRIES a followed
// slide whose anchors move with it (`own + (1 − follow)·Δ`).
//
// Every green row here is built THROUGH the transform. One pin keeps the
// literal state's 2M, so nobody "fixes" it by changing the render.
//
// Pure and nonisolated (the `@MainActor` suite cap is full); the store method
// is reached through `MainActor.run`.
struct SlideBridgeTests {

    static let clip = UUID(uuidString: "F1800000-0000-4000-8000-0000000000CC")!

    static func note(_ start: Double, _ end: Double, cents: Double = 0,
                     follow: Double = 0, origin: NoteOrigin = .detected) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    glideFollow: follow, origin: origin)
    }

    /// A set with the NEW-set values (voice amount 1.0, consonants on, slope
    /// 3000), as the editor seeds one: it does not predate natural tuning, so
    /// D4-1's first-edit update never runs and every row reads only vf-18.
    static func newSet(_ segments: [NoteSegment]) -> PitchEditSet {
        PitchEditSet(segments: segments, formantCorrection: PitchEditSet.newSetFormantCorrection,
                     keepsConsonantsUntuned: true,
                     transitionSlopeCentsPerSecond: PitchEditSet.defaultTransitionSlope)
    }

    /// A (0.5-1.0 s) · T, a 200 ms sung slide following by `follow`
    /// (1.0-1.2 s) · B (1.2-2.0 s), all abutting (two soft joins):
    /// `PitchTransitionTests.tiltSet`'s shape.
    static func twoSided(a: Double = 0, t: Double = 0, b: Double = 0, follow: Double = 1) -> PitchEditSet {
        newSet([note(0.5, 1.0, cents: a),
                note(1.0, 1.2, cents: t, follow: follow, origin: .transition),
                note(1.2, 2.0, cents: b)])
    }

    /// `t = low + i · step`, index-built.
    static func grid(_ low: Double, _ high: Double, step: Double = 0.0005) -> [Double] {
        (0...Int(((high - low) / step).rounded())).map { low + Double($0) * step }
    }

    /// The worst |curve − target| over `range`, and where.
    static func worstError(_ set: PitchEditSet, target: Double,
                           over range: (Double, Double)) -> (error: Double, at: Double, value: Double) {
        let curve = PitchCorrectionCurve.make(editSet: set)
        var worst = (error: 0.0, at: Double.nan, value: Double.nan)
        for t in grid(range.0, range.1) {
            let value = curve.semitones(atSourceSecond: t)
            let error = abs(value - target)
            if error > worst.error || worst.at.isNaN { worst = (error, t, value) }
        }
        return worst
    }

    static func ids(_ set: PitchEditSet) -> [UUID] { set.segments.map(\.id) }

    static func refusal(_ body: () throws -> Any) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as ProjectError {
            return error.localizedDescription
        } catch {
            return "\(error)"
        }
    }

    static func log(_ message: String) { print("vf18| \(message)") }

    // MARK: - The literal state keeps its meaning (the pin)

    @Test("vf-18 PIN: the LITERAL state (every note's own offset +M, the notes form) plays a two-sided followed slide at 2M, on purpose")
    func literalStatePlaysTwiceTheMove() {
        for move in [12.0, -5.0] {
            let set = Self.twoSided(a: move * 100, t: move * 100, b: move * 100)
            let middle = PitchCorrectionCurve.make(editSet: set).semitones(atSourceSecond: 1.1)
            Self.log("literal two-sided \(move): middle \(middle)")
            #expect(abs(middle - 2 * move) < 1e-9,
                    "the literal state's slide reads \(middle), not 2 × \(move): the additive bridge (§4.b.3) changed")
        }
    }

    // MARK: - T1 / T7: a uniform move through the transform is exact

    @Test("vf-18 T1: a uniform +12 / −5 through applyingGroupPitchMove moves a TWO-SIDED followed slide by exactly M; the joins keep the unmoved table's width")
    func uniformMoveTwoSidedIsExact() throws {
        let still = Self.twoSided()
        #expect(still.joinReading(afterSegmentAt: 0)?.appliedWidthMs == 30
                    && still.joinReading(afterSegmentAt: 1)?.appliedWidthMs == 30,
                "the unmoved control's joins are not at the 30 ms floor")
        for move in [12.0, -5.0] {
            let moved = try still.applyingGroupPitchMove(segmentIDs: Self.ids(still), byCents: move * 100,
                                                         clipId: Self.clip)
            #expect(moved.carriedSlideIDs == [still.segments[1].id])
            #expect(moved.set.segments.map(\.pitchOffsetCents) == [move * 100, 0, move * 100],
                    "a fully followed slide carried by both neighbours keeps its own offset")
            let worst = Self.worstError(moved.set, target: move, over: (0.6, 1.9))
            Self.log("T1 two-sided \(move): worst |err| \(worst.error) at \(worst.at) (value \(worst.value))")
            #expect(worst.error < 1e-9, "move \(move): \(worst)")
            #expect(moved.set.joinReading(afterSegmentAt: 0)?.appliedWidthMs == 30
                        && moved.set.joinReading(afterSegmentAt: 1)?.appliedWidthMs == 30,
                    "a uniform move widened the joins beside the slide")
        }
    }

    @Test("vf-18 T7: a half-followed slide (g = 0.5) moves exactly M under a uniform move (k = 0.5)")
    func halfFollowIsExact() throws {
        let still = Self.twoSided(follow: 0.5)
        for move in [12.0, -5.0] {
            let moved = try still.applyingGroupPitchMove(segmentIDs: Self.ids(still), byCents: move * 100,
                                                         clipId: Self.clip)
            #expect(moved.set.segments[1].pitchOffsetCents == move * 100 * 0.5)
            let worst = Self.worstError(moved.set, target: move, over: (0.6, 1.9))
            Self.log("T7 g 0.5 move \(move): worst |err| \(worst.error)")
            #expect(worst.error < 1e-9, "move \(move): \(worst)")
        }
    }

    // MARK: - T5 / T6 / T12: the carry reads the GROUP, so gestures stay distinct

    @Test("vf-18 T5: a lone move of a followed slide (no anchor moves) is NOT carried: +100 c plays +1 st on top of its tilt (§4.b.3)")
    func loneSlideMoveIsAdditive() throws {
        let set = Self.twoSided(a: 300)
        let slide = set.segments[1].id
        #expect(set.groupMoveCarry(ofSegmentAt: 1, movingIDs: [slide]) == 1)
        let moved = try set.applyingGroupPitchMove(segmentIDs: [slide], byCents: 100, clipId: Self.clip)
        #expect(moved.carriedSlideIDs.isEmpty)
        #expect(moved.set.segments[1].pitchOffsetCents == 100)
        let middle = PitchCorrectionCurve.make(editSet: moved.set).semitones(atSourceSecond: 1.1)
        #expect(abs(middle - 2.5) < 1e-9, "the lone +100 c move reads \(middle) at the middle, not 1.5 + 1")
    }

    @Test("vf-18 T6: a partial group {A, slide}, B unmoved: the slide starts at A's new pitch and lands on B; both joins at the floor")
    func partialGroupFollowsTheNeighbour() throws {
        let still = Self.twoSided()
        let moved = try still.applyingGroupPitchMove(segmentIDs: [still.segments[0].id, still.segments[1].id],
                                                     byCents: 400, clipId: Self.clip)
        #expect(moved.carriedSlideIDs == [still.segments[1].id])
        let curve = PitchCorrectionCurve.make(editSet: moved.set)
        let start = curve.semitones(atSourceSecond: 1.0)
        let end = curve.semitones(atSourceSecond: 1.2)
        Self.log("T6 partial group: start \(start) end \(end)")
        #expect(abs(start - 4) < 1e-9 && abs(end) < 1e-9)
        #expect(moved.set.joinReading(afterSegmentAt: 0)?.appliedWidthMs == 30
                    && moved.set.joinReading(afterSegmentAt: 1)?.appliedWidthMs == 30)
    }

    @Test("vf-18 T12: 'neighbours −D, then everything +D' leaves the slide at 0; 'the slide alone +D' plays D; the two store different states")
    func gesturesStoreDifferentStates() throws {
        let start = Self.twoSided()
        let a = start.segments[0].id, t = start.segments[1].id, b = start.segments[2].id
        let down = try start.applyingGroupPitchMove(segmentIDs: [a, b], byCents: -300, clipId: Self.clip).set
        let back = try down.applyingGroupPitchMove(segmentIDs: [a, t, b], byCents: 300, clipId: Self.clip).set
        let alone = try start.applyingGroupPitchMove(segmentIDs: [t], byCents: 300, clipId: Self.clip).set
        #expect(back.segments.map(\.pitchOffsetCents) == [0, 0, 0])
        #expect(alone.segments.map(\.pitchOffsetCents) == [0, 300, 0])
        #expect(back.segments != alone.segments, "two gestures stored one state: no render can tell them apart")
        let backMiddle = PitchCorrectionCurve.make(editSet: back).semitones(atSourceSecond: 1.1)
        let aloneMiddle = PitchCorrectionCurve.make(editSet: alone).semitones(atSourceSecond: 1.1)
        #expect(abs(backMiddle) < 1e-9 && abs(aloneMiddle - 3) < 1e-9, "\(backMiddle), \(aloneMiddle)")
    }

    // MARK: - The carry's membership rule

    /// A long (100 ms) untouched sound S between A and the slide T is a GAP
    /// today, so T has no anchor on that side. Once S moves WITH T, S is a
    /// curve note abutting T: an anchor that moves, so T is carried.
    @Test("vf-18 carry: a sound moving in the group counts as a curve note (an anchor); left out, it is no anchor")
    func movingSoundIsAnAnchor() {
        let set = Self.newSet([Self.note(0.3, 0.8, cents: 0),
                               Self.note(0.8, 0.9, origin: .unpitched),
                               Self.note(0.9, 1.1, follow: 1, origin: .transition),
                               Self.note(1.4, 2.0)])
        let s = set.segments[1].id, t = set.segments[2].id
        #expect(set.groupMoveCarry(ofSegmentAt: 2, movingIDs: [t]) == 1, "nothing T reads moves")
        #expect(set.groupMoveCarry(ofSegmentAt: 2, movingIDs: [s, t]) == 0,
                "the moving sound abuts T, so it is T's anchor and T is carried")
        #expect(set.groupMoveCarry(ofSegmentAt: 1, movingIDs: [s, t]) == 1, "a sound is never carried")
        #expect(set.groupMoveCarry(ofSegmentAt: 2, movingIDs: [s]) == 1, "T is not in the group")
        #expect(set.groupMoveCarry(ofSegmentAt: 9, movingIDs: [t]) == 1, "an index outside the table")
    }

    // MARK: - k == 1 is the literal expression; the result is the literal writer's

    @Test("vf-18 k == 1 notes land on baseline + move bit for bit, and the stored set is exactly the literal writer's set for the same offsets")
    func uncarriedNotesAreTheLiteralArithmetic() throws {
        let set = Self.newSet([Self.note(0.2, 0.5, cents: 33.3),
                               Self.note(0.5, 0.9, cents: -1.9550008653880013),
                               Self.note(1.2, 1.4, cents: 0.1, origin: .unpitched),
                               Self.note(1.4, 2.0, cents: 1234.5678)])
        let move = 701.955
        let moved = try set.applyingGroupPitchMove(segmentIDs: Self.ids(set), byCents: move, clipId: Self.clip)
        #expect(moved.carriedSlideIDs.isEmpty)
        for (before, after) in zip(set.segments, moved.set.segments) {
            #expect(after.pitchOffsetCents.bitPattern == (before.pitchOffsetCents + move).bitPattern,
                    "\(after.pitchOffsetCents) is not \(before.pitchOffsetCents) + \(move) bit for bit")
        }
        #expect(moved.offsets.map(\.segmentId) == Self.ids(set), "offsets come in segment order")
        #expect(try set.applyingNotePitchOffsets(moved.offsets, clipId: Self.clip) == moved.set,
                "the group move stored something the literal writer would not for the same offsets")
        // A repeated id is folded.
        let twice = try set.applyingGroupPitchMove(segmentIDs: Self.ids(set) + [set.segments[0].id],
                                                   byCents: move, clipId: Self.clip)
        #expect(twice.set == moved.set && twice.offsets == moved.offsets)
        // Zero moves nothing and stores the set as it was (the no-op rule).
        #expect(try set.applyingGroupPitchMove(segmentIDs: Self.ids(set), byCents: 0, clipId: Self.clip).set == set)
    }

    // MARK: - T11 and the refusals

    @Test("vf-18 T11: a group move that would push one note past ±2400 c is refused ALL OR NOTHING, naming the range the group can move")
    func outOfRangeIsRefusedWithTheRange() {
        let set = Self.twoSided(a: 2000, b: -100)
        let a = set.segments[0].id
        let message = Self.refusal {
            try set.applyingGroupPitchMove(segmentIDs: Self.ids(set), byCents: 500, clipId: Self.clip)
        }
        Self.log("T11 refusal: \(message ?? "NONE")")
        // A: +400 at most; B (at −100): down to −2300; the fully followed slide
        // is carried (k = 0) and bounds nothing.
        #expect(message == NotePitchMoveSentences.moveOutOfRange(byCents: 500, segmentId: a,
                                                                lowest: -2300, highest: 400))
        #expect(message?.contains("-2300 to +400") == true, "\(message ?? "")")
        #expect(Self.refusal {
            try set.applyingGroupPitchMove(segmentIDs: Self.ids(set), byCents: 400, clipId: Self.clip)
        } == nil, "the edge of the named range is allowed")
    }

    @Test("vf-18 refusals: empty list and unknown id in the literal writer's words; a non-finite move in words")
    func refusalsInWords() {
        let set = Self.twoSided()
        let unknown = UUID()
        let empty = Self.refusal { try set.applyingGroupPitchMove(segmentIDs: [], byCents: 100, clipId: Self.clip) }
        let literalEmpty = Self.refusal { try set.applyingNotePitchOffsets([], clipId: Self.clip) }
        #expect(empty != nil && empty == literalEmpty)
        let missing = Self.refusal {
            try set.applyingGroupPitchMove(segmentIDs: [set.segments[0].id, unknown], byCents: 100,
                                           clipId: Self.clip)
        }
        let literalMissing = Self.refusal {
            try set.applyingNotePitchOffsets([NotePitchOffset(segmentId: unknown, offsetCents: 0)],
                                             clipId: Self.clip)
        }
        #expect(missing != nil && missing == literalMissing, "\(missing ?? "none")")
        for bad in [Double.nan, .infinity, -.infinity] {
            #expect(Self.refusal {
                try set.applyingGroupPitchMove(segmentIDs: Self.ids(set), byCents: bad, clipId: Self.clip)
            } == NotePitchMoveSentences.moveNotANumber(bad))
        }
        #expect(NotePitchMoveSentences.wholeCents(-0.3) == "+0" && NotePitchMoveSentences.wholeCents(1e300)
                    .hasPrefix("+1"), "the sentence's number formatting")
    }

    // MARK: - Step 2: the HOLD rule (one-sided and adjacent slides), adoption, the file

    /// A (0.5-1.0) · T, a tail-off following fully (1.0-1.2) · a 200 ms GAP ·
    /// B (1.4-2.0): T has ONE soft neighbour, the splitter's tail-off shape.
    static func tailOff(a: Double = 0, t: Double = 0, b: Double = 0) -> PitchEditSet {
        newSet([note(0.5, 1.0, cents: a),
                note(1.0, 1.2, cents: t, follow: 1, origin: .transition),
                note(1.4, 2.0, cents: b)])
    }

    /// A (0.3-0.8) · a 200 ms GAP · L, a lead-in following fully
    /// (1.0-1.15) · B (1.15-1.9).
    static func leadIn(a: Double = 0, l: Double = 0, b: Double = 0) -> PitchEditSet {
        newSet([note(0.3, 0.8, cents: a),
                note(1.0, 1.15, cents: l, follow: 1, origin: .transition),
                note(1.15, 1.9, cents: b)])
    }

    /// A · T1 · T2 · B, all abutting; T1 and T2 follow (a split of one slide).
    static func adjacent(a: Double = 0, t1: Double = 0, t2: Double = 0, b: Double = 0,
                         follow2: Double = 1) -> PitchEditSet {
        newSet([note(0.5, 1.0, cents: a),
                note(1.0, 1.1, cents: t1, follow: 1, origin: .transition),
                note(1.1, 1.2, cents: t2, follow: follow2, origin: .transition),
                note(1.2, 2.0, cents: b)])
    }

    static func withRule(_ set: PitchEditSet, _ rule: PitchEditSet.SlideFollowRule) -> PitchEditSet {
        var out = set
        out.slideFollowRule = rule
        return out
    }

    /// The same timing with EVERY note a plain (unfollowed) note at `cents`:
    /// the zero table shifted by `cents`, which is what an exact uniform move
    /// of a zero table must render.
    static func plainShifted(_ set: PitchEditSet, by cents: Double) -> PitchEditSet {
        var out = withRule(set, .sungAtOpenSide)
        for index in out.segments.indices {
            out.segments[index].glideFollow = 0
            out.segments[index].pitchOffsetCents = cents
        }
        return out
    }

    /// The worst |a − b| of two sets' pitch curves over the whole table.
    static func worstDifference(_ a: PitchEditSet, _ b: PitchEditSet, offset: Double = 0,
                                over range: (Double, Double)? = nil) -> (error: Double, at: Double) {
        let ca = PitchCorrectionCurve.make(editSet: a)
        let cb = PitchCorrectionCurve.make(editSet: b)
        let end = (a.segments.last?.endSeconds ?? 0) + 0.3
        var worst = (error: 0.0, at: Double.nan)
        for t in grid(range?.0 ?? 0, range?.1 ?? end) {
            let error = abs(ca.semitones(atSourceSecond: t) - cb.semitones(atSourceSecond: t) - offset)
            if error > worst.error { worst = (error, t) }
        }
        return worst
    }

    /// Pitch AND formant curves (every 0.5 ms) and every join reading, bit for
    /// bit, of `a` against `b`: the count of samples that differ.
    static func bitDifferences(_ a: PitchEditSet, _ b: PitchEditSet) -> Int {
        let ca = PitchCorrectionCurve.make(editSet: a)
        let cb = PitchCorrectionCurve.make(editSet: b)
        let end = (a.segments.last?.endSeconds ?? 0) + 0.3
        var differ = 0
        for t in grid(0, end) {
            if ca.semitones(atSourceSecond: t).bitPattern != cb.semitones(atSourceSecond: t).bitPattern
                || ca.formantSemitones(atSourceSecond: t, formantPreserve: false).bitPattern
                    != cb.formantSemitones(atSourceSecond: t, formantPreserve: false).bitPattern {
                differ += 1
            }
        }
        for index in a.segments.indices
        where a.joinReading(afterSegmentAt: index) != b.joinReading(afterSegmentAt: index) {
            differ += 1
        }
        return differ
    }

    @Test("vf-18 T2: a uniform +12 / −5 on an inert table ADOPTS the hold rule, and a one-sided tail-off AND lead-in then move exactly M")
    func oneSidedSlidesAreExactUnderHold() throws {
        for (name, still) in [("tail-off", Self.tailOff()), ("lead-in", Self.leadIn())] {
            #expect(still.slideFollowRule == .sungAtOpenSide && still.isSlideFollowRuleInert,
                    "\(name): the fixture must start legacy and inert")
            for move in [12.0, -5.0] {
                let moved = try still.applyingGroupPitchMove(segmentIDs: Self.ids(still), byCents: move * 100,
                                                             clipId: Self.clip)
                #expect(moved.set.slideFollowRule == .holdAtOpenSide, "\(name): the move did not adopt")
                #expect(moved.carriedSlideIDs == [still.segments[1].id])
                let worst = Self.worstDifference(moved.set, Self.plainShifted(still, by: move * 100))
                Self.log("T2 \(name) \(move): worst |curve − shifted table| \(worst.error) at \(worst.at)")
                #expect(worst.error < 1e-9, "\(name) \(move): \(worst)")
                // Positive control: the same stored offsets on the LEGACY rule
                // tilt the slide back to the sung pitch at its open side.
                let legacy = Self.worstDifference(Self.withRule(moved.set, .sungAtOpenSide),
                                                  Self.plainShifted(still, by: move * 100))
                #expect(legacy.error > abs(move) * 0.4,
                        "\(name) \(move): the legacy rule is not the residual this fixes (\(legacy))")
            }
        }
    }

    @Test("vf-18 T3: a NON-inert legacy table (A already +300 beside a tail-off) does not adopt; its tail-off keeps the documented tilt to the sung pitch")
    func nonInertTableKeepsTheLegacyResidual() throws {
        let still = Self.tailOff(a: 300)
        #expect(!still.isSlideFollowRuleInert, "positive control: hold would read +3 at the open side, legacy 0")
        #expect(still.ruleAfterHandEdit() == .sungAtOpenSide)
        let moved = try still.applyingGroupPitchMove(segmentIDs: Self.ids(still), byCents: 1200,
                                                     clipId: Self.clip)
        #expect(moved.set.slideFollowRule == .sungAtOpenSide, "a non-inert table adopted the hold rule")
        #expect(moved.set.segments.map(\.pitchOffsetCents) == [1500, 0, 1200])
        let curve = PitchCorrectionCurve.make(editSet: moved.set)
        let middle = curve.semitones(atSourceSecond: 1.1)
        Self.log("T3 residual: tail-off middle \(middle) st (A at +15, open side 0)")
        #expect(abs(middle - 7.5) < 1e-9, "the documented legacy residual moved: \(middle)")
    }

    @Test("vf-18 T4: an inert table renders bit for bit the same under both rules (pitch, formant, joins)")
    func inertTablesRenderTheSameUnderBothRules() {
        let inert = [("tail-off", Self.tailOff()), ("lead-in", Self.leadIn()),
                     ("adjacent", Self.adjacent()),
                     ("two-sided, moved but held", Self.twoSided(a: 300, t: 50, b: -200)),
                     // Each slide's own offset equals the outer note on its
                     // far side, so each reads the same value either way.
                     ("adjacent, non-zero but inert", Self.adjacent(a: 250, t1: -80, t2: 250, b: -80))]
        for (name, set) in inert {
            #expect(set.isSlideFollowRuleInert, "\(name) should be inert")
            let differ = Self.bitDifferences(Self.withRule(set, .sungAtOpenSide),
                                             Self.withRule(set, .holdAtOpenSide))
            #expect(differ == 0, "\(name): \(differ) samples differ between the rules")
        }
        // Positive control: a non-inert table does differ, so the probe sees a rule.
        let moved = Self.tailOff(a: 300)
        #expect(Self.bitDifferences(Self.withRule(moved, .sungAtOpenSide),
                                    Self.withRule(moved, .holdAtOpenSide)) > 100)
    }

    @Test("vf-18 T4 fuzz: on 400 seeded soft sets, inert ⇔ the two rules render the same bits (pitch, formant, joins)")
    func inertnessIsExactlyTheRenderIdentity() {
        var rng = PitchSpanSearchTests.Rng(state: 0x0F18_2026_1012_A4A4)
        var inertWithFollowers = 0, nonInert = 0, inertButDiffers = 0, nonInertButSame = 0
        var example = ""
        for _ in 0..<400 {
            let set = PitchSpanSearchTests.randomSoftFixture(&rng).set
            let followers = set.segments.contains { $0.glideFollow > 0 && $0.entersPitchCurve }
            let differ = Self.bitDifferences(Self.withRule(set, .sungAtOpenSide),
                                             Self.withRule(set, .holdAtOpenSide))
            if set.isSlideFollowRuleInert {
                if followers { inertWithFollowers += 1 }
                if differ > 0 {
                    inertButDiffers += 1
                    if example.isEmpty { example = "\(set.segments.count) notes, \(differ) samples" }
                }
            } else {
                nonInert += 1
                if differ == 0 { nonInertButSame += 1 }
            }
        }
        Self.log("T4 fuzz: \(inertWithFollowers) inert sets with followers, \(nonInert) non-inert, "
                 + "\(inertButDiffers) inert-but-differ, \(nonInertButSame) non-inert-but-same")
        #expect(inertWithFollowers > 10 && nonInert > 50, "the fuzz lost its shapes")
        #expect(inertButDiffers == 0, "an inert set renders differently under the hold rule: \(example)")
        #expect(nonInertButSame == 0,
                "the inertness predicate is over-conservative: a non-inert set renders the same")
    }

    @Test("vf-18 T8: adjacent followed slides (a split slide): exact under hold, each anchoring on its outer held note; the legacy rule's documented dip is pinned")
    func adjacentSlides() throws {
        // (a) A uniform move of an inert zero table adopts hold and is exact.
        let still = Self.adjacent()
        let moved = try still.applyingGroupPitchMove(segmentIDs: Self.ids(still), byCents: 1200,
                                                     clipId: Self.clip)
        #expect(moved.set.slideFollowRule == .holdAtOpenSide)
        #expect(Set(moved.carriedSlideIDs) == [still.segments[1].id, still.segments[2].id])
        let worst = Self.worstDifference(moved.set, Self.plainShifted(still, by: 1200))
        Self.log("T8 adjacent uniform +12: worst \(worst.error) at \(worst.at)")
        #expect(worst.error < 1e-9, "\(worst)")
        #expect(moved.set.joinReading(afterSegmentAt: 1)?.appliedWidthMs == 30)

        // (b) A hold set with its outer notes moved: T1 copies A, T2 copies B,
        // and their join compares EACH slide's own edge value (3 vs −2 st:
        // 500 c at 3000 c/s = 166.7 ms, capped by the 100 ms notes).
        let hold = Self.withRule(Self.adjacent(a: 300, b: -200), .holdAtOpenSide)
        let curve = PitchCorrectionCurve.make(editSet: hold)
        #expect(abs(curve.semitones(atSourceSecond: 1.03) - 3) < 1e-9
                    && abs(curve.semitones(atSourceSecond: 1.17) + 2) < 1e-9,
                "T1 \(curve.semitones(atSourceSecond: 1.03)), T2 \(curve.semitones(atSourceSecond: 1.17))")
        let width = try #require(hold.joinReading(afterSegmentAt: 1)?.appliedWidthMs)
        Self.log("T8 hold slide|slide join: \(width) ms")
        #expect(abs(width - 100) < 1e-9, "the slide|slide join did not read each side's own anchor: \(width)")
        #expect(Self.withRule(hold, .sungAtOpenSide).joinReading(afterSegmentAt: 1)?.appliedWidthMs == 30,
                "control: the legacy rule's own reading (each reads the other's own 0)")
        // The CURVE takes that width too: 10 ms into the 100 ms join (it
        // starts at 1.05 s) the crossfade toward T2 has begun; a 30 ms join
        // (each side's legacy edge value, 0 against 0) would still read +3.
        let early = curve.semitones(atSourceSecond: 1.06)
        Self.log("T8 hold curve at 1.06 s: \(early) st")
        #expect(early < 2.95 && early > 2.5, "the curve's slide|slide join is not the hold width: \(early)")
        // A uniform move of that hold set is exact too, wherever the gates
        // sum to 1 (inside the notes; outside them both curves read 0).
        let movedHold = try hold.applyingGroupPitchMove(segmentIDs: Self.ids(hold), byCents: 700,
                                                        clipId: Self.clip)
        let shift = Self.worstDifference(movedHold.set, hold, offset: 7, over: (0.6, 1.9))
        #expect(movedHold.set.slideFollowRule == .holdAtOpenSide && shift.error < 1e-9, "\(shift)")

        // (c) LEGACY LIMIT, documented: on the legacy rule each slide reads the
        // OTHER slide's own offset, so after a carried +12 the split slide
        // dips to the sung pitch where its halves meet.
        let legacy = Self.withRule(Self.adjacent(a: 1200, b: 1200), .sungAtOpenSide)
        let legacyCurve = PitchCorrectionCurve.make(editSet: legacy)
        #expect(abs(legacyCurve.semitones(atSourceSecond: 1.1)) < 1e-9
                    && abs(legacyCurve.semitones(atSourceSecond: 1.05) - 6) < 1e-9,
                "the pinned legacy dip moved: \(legacyCurve.semitones(atSourceSecond: 1.1))")
    }

    @Test("vf-18 T9: under hold, moving the note a lead-in leads into carries the WHOLE lead-in; a legacy table keeps today's tilt from the sung pitch")
    func holdCarriesALeadInWhole() throws {
        let still = Self.leadIn()
        let b = still.segments[2].id
        let moved = try still.applyingGroupPitchMove(segmentIDs: [b], byCents: 300, clipId: Self.clip)
        #expect(moved.set.slideFollowRule == .holdAtOpenSide && moved.carriedSlideIDs.isEmpty)
        let curve = PitchCorrectionCurve.make(editSet: moved.set)
        var worst = 0.0
        for t in Self.grid(1.02, 1.5) { worst = max(worst, abs(curve.semitones(atSourceSecond: t) - 3)) }
        #expect(worst < 1e-9, "the lead-in did not move with its note: \(worst)")
        let legacy = PitchCorrectionCurve.make(editSet: Self.withRule(moved.set, .sungAtOpenSide))
        let middle = legacy.semitones(atSourceSecond: 1.075)
        #expect(abs(middle - 1.5) < 1e-9, "today's tilt (0 at the gap, +3 at its note): \(middle)")
    }

    @Test("vf-18 T10: a followed note alone between gaps is a constant under both rules, bit for bit")
    func aloneBetweenGapsIsTheSameUnderBothRules() {
        let alone = Self.newSet([Self.note(0.5, 1.0, cents: 300),
                                 Self.note(1.2, 1.4, cents: 100, follow: 1),
                                 Self.note(1.6, 2.0)])
        #expect(alone.isSlideFollowRuleInert)
        #expect(Self.bitDifferences(Self.withRule(alone, .sungAtOpenSide),
                                    Self.withRule(alone, .holdAtOpenSide)) == 0)
        #expect(PitchCorrectionCurve.make(editSet: Self.withRule(alone, .holdAtOpenSide))
                    .semitones(atSourceSecond: 1.3) == 1)
    }

    // MARK: - Adoption (REVIEW §3.4)

    @Test("vf-18 adoption: a hand edit adopts hold only on an inert set with a follower; a no-op, a non-inert set and a follower-free set stay legacy; seeds never write it; the upgrade door does")
    func adoptionRules() throws {
        let inert = Self.tailOff()
        var edited = inert
        edited.segments[0].pitchOffsetCents = 50
        #expect(edited.afterHandEdit(from: inert).slideFollowRule == .holdAtOpenSide)
        #expect(inert.afterHandEdit(from: inert) == inert, "a no-op adopted the rule")
        let nonInert = Self.tailOff(a: 300)
        var editedNonInert = nonInert
        editedNonInert.segments[2].pitchOffsetCents = 50
        #expect(editedNonInert.afterHandEdit(from: nonInert).slideFollowRule == .sungAtOpenSide)
        let plain = Self.newSet([Self.note(0.5, 1.0), Self.note(1.0, 1.5)])
        var editedPlain = plain
        editedPlain.segments[0].pitchOffsetCents = 50
        #expect(editedPlain.afterHandEdit(from: plain).slideFollowRule == .sungAtOpenSide,
                "a set with no followed slide has nothing to adopt for")
        // The bare hook is unchanged (pitchDragReach reads it).
        #expect(edited.afterHandEdit() == edited)
        // A legacy vocal that predates natural tuning takes hold through D4-1's update.
        var old = Self.tailOff(a: 300)
        old.formantCorrection = nil
        #expect(old.predatesNaturalTuning)
        var oldEdited = old
        oldEdited.segments[2].pitchOffsetCents = 40
        #expect(oldEdited.afterHandEdit(from: old) == oldEdited.upgradedToNaturalTuning())
        #expect(oldEdited.afterHandEdit(from: old).slideFollowRule == .holdAtOpenSide)
        // The upgrade door: hold iff there is a follower.
        #expect(nonInert.upgradedToNaturalTuning().slideFollowRule == .holdAtOpenSide)
        #expect(plain.upgradedToNaturalTuning().slideFollowRule == .sungAtOpenSide)
        // Seeds never write it.
        let kinds: [UUID: NotePart.Kind] = [inert.segments[1].id: .transition]
        for policy in [PitchEditSet.SeedPolicy.editor, .preset] {
            let seeded = PitchEditSet.seeded(analysisVersion: 1, segments: inert.segments, retuneMs: 30,
                                             partKinds: kinds, seedPolicy: policy)
            #expect(seeded.slideFollowRule == .sungAtOpenSide, "\(policy) seeded the rule")
        }
        // Once adopted it stays: another edit on a hold set, inert or not.
        var later = edited.afterHandEdit(from: inert)
        let before = later
        later.segments[2].pitchOffsetCents = -700
        #expect(later.afterHandEdit(from: before).slideFollowRule == .holdAtOpenSide)
    }

    @Test("vf-18 ruleAfterHandEdit: on 300 seeded sets it is the rule a real one-note edit (any note, any amount) stores")
    func ruleAfterHandEditAgreesWithTheHome() {
        var rng = PitchSpanSearchTests.Rng(state: 0x0F18_2026_1012_C3C3)
        var hold = 0, legacy = 0, mismatches = 0
        for _ in 0..<300 {
            var set = PitchSpanSearchTests.randomSoftFixture(&rng).set
            if rng.chance(0.3) { set.formantCorrection = nil }
            guard !set.segments.isEmpty else { continue }
            let index = Int(rng.next() % UInt64(set.segments.count))
            var edited = set
            edited.segments[index].pitchOffsetCents = set.segments[index].pitchOffsetCents
                + (rng.chance(0.5) ? 1 : -1) * rng.uniform(5, 900)
            guard edited.segments[index].pitchOffsetCents != 0 else { continue }
            let stored = edited.afterHandEdit(from: set).slideFollowRule
            if stored == .holdAtOpenSide { hold += 1 } else { legacy += 1 }
            if set.ruleAfterHandEdit() != stored { mismatches += 1 }
        }
        Self.log("ruleAfterHandEdit fuzz: \(hold) hold, \(legacy) legacy, \(mismatches) mismatches")
        #expect(hold > 20 && legacy > 20, "the fuzz lost one of the two answers")
        #expect(mismatches == 0)
    }

    @Test("vf-18 the width-rule overload is the legacy softJoin when fed the legacy edge values (10k random pairs)")
    func softJoinOverloadMatchesTheLegacyRule() {
        var rng = PitchSpanSearchTests.Rng(state: 0x0F18_2026_1012_D5D5)
        var compared = 0
        for _ in 0..<10_000 {
            let start = rng.uniform(0, 2)
            let leftEnd = start + rng.uniform(0.005, 1.5)
            let rightStart = leftEnd + (rng.chance(0.5) ? 0 : rng.uniform(0, 0.063))
            let left = NoteSegment(startSeconds: start, endSeconds: leftEnd, detectedHz: 220,
                                   detectedConfidence: 1, pitchOffsetCents: rng.uniform(-2400, 2400),
                                   transitionOutMs: rng.chance(0.3) ? rng.uniform(30, 1000) : 0,
                                   glideFollow: rng.chance(0.5) ? rng.unit() : 0)
            let right = NoteSegment(startSeconds: rightStart, endSeconds: rightStart + rng.uniform(0.005, 1.5),
                                    detectedHz: 220, detectedConfidence: 1,
                                    pitchOffsetCents: rng.uniform(-2400, 2400),
                                    glideFollow: rng.chance(0.5) ? rng.unit() : 0)
            let retune = rng.uniform(30, 500)
            let slope = rng.chance(0.2) ? 0 : rng.uniform(500, 20_000)
            var end = left.pitchOffsetCents
            if left.glideFollow > 0 { end += left.glideFollow * right.pitchOffsetCents }
            var start2 = right.pitchOffsetCents
            if right.glideFollow > 0 { start2 += right.glideFollow * left.pitchOffsetCents }
            let a = PitchEditSet.softJoin(left: left, right: right, retuneMs: retune, slopeCentsPerSecond: slope)
            let b = PitchEditSet.softJoin(left: left, right: right, leftEdgeValueCents: end,
                                          rightEdgeValueCents: start2, retuneMs: retune,
                                          slopeCentsPerSecond: slope)
            #expect(a?.edgeSeconds.bitPattern == b?.edgeSeconds.bitPattern
                        && a?.halfWidthSeconds.bitPattern == b?.halfWidthSeconds.bitPattern)
            compared += 1
        }
        #expect(compared == 10_000)
    }

    // MARK: - B2: the file

    @Test("vf-18 B2 codable: absent decodes legacy; legacy is never written; hold round-trips; an unknown value decodes legacy")
    func slideFollowRuleCodable() throws {
        let legacy = Self.tailOff(a: 300)
        let legacyText = String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self)
        #expect(!legacyText.contains("slideFollowRule"), "the legacy rule wrote its key")
        #expect(legacyText.contains("\"transitionSlope\""), "positive control: the probe finds written keys")
        #expect(try JSONDecoder().decode(PitchEditSet.self, from: Data(legacyText.utf8)) == legacy)
        let hold = Self.withRule(legacy, .holdAtOpenSide)
        let holdText = String(decoding: try JSONEncoder().encode(hold), as: UTF8.self)
        #expect(holdText.contains("\"slideFollowRule\":\"holdAtOpenSide\""), "\(holdText)")
        let back = try JSONDecoder().decode(PitchEditSet.self, from: Data(holdText.utf8))
        #expect(back == hold && back.slideFollowRule == .holdAtOpenSide)
        #expect(hold.contentStamp != legacy.contentStamp, "the stamp hashes the full encoding")
        for value in ["\"somethingNewer\"", "\"sungAtOpenSide\""] {
            let text = holdText.replacingOccurrences(of: "\"holdAtOpenSide\"", with: value)
            let decoded = try JSONDecoder().decode(PitchEditSet.self, from: Data(text.utf8))
            #expect(decoded.slideFollowRule == .sungAtOpenSide, "\(value) did not read as legacy")
            #expect(decoded == legacy)
        }
        #expect(PitchEditSet.SlideFollowRule.allCases.map(\.rawValue) == ["sungAtOpenSide", "holdAtOpenSide"],
                "the raw values are file values: additive only, never rename")
        #expect(PitchEditSet.empty.slideFollowRule == .sungAtOpenSide
                    && PitchEditSet(segments: legacy.segments).slideFollowRule == .sungAtOpenSide)
        #expect(legacy.withSegments(legacy.segments).slideFollowRule == .sungAtOpenSide
                    && hold.withSegments(legacy.segments).slideFollowRule == .holdAtOpenSide,
                "withSegments must carry the rule")
    }

    // MARK: - The store method (one writer, one undo step)

    @Test("vf-18 store: moveClipNotePitches moves every sung note together in ONE undo step through setClipNotePitchOffsets; sounds stay; carried slides come back; out of range changes nothing")
    func storeMovesNotesTogether() async throws {
        let table = Self.newSet([Self.note(0.2, 0.3, origin: .unpitched),
                                 Self.note(0.3, 0.45, follow: 1, origin: .transition),
                                 Self.note(0.45, 1.0),
                                 Self.note(1.0, 1.2, follow: 1, origin: .transition),
                                 Self.note(1.4, 2.0),
                                 Self.note(2.0, 2.05, origin: .unpitched)])
        try await MainActor.run {
            let clip = Clip(name: "Vocal", startBeat: 0, lengthBeats: 8,
                            audioFileURL: URL(fileURLWithPath: "/nonexistent/slfx-vocal.wav"),
                            pitchEdits: table)
            let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
            let sung = table.segments.filter { $0.origin != .unpitched }.map(\.id)
            let expected = try table.applyingGroupPitchMove(segmentIDs: sung, byCents: 1200, clipId: clip.id)
            let result = try store.moveClipNotePitches(clipId: clip.id, segmentIds: nil, byCents: 1200,
                                                       undoKey: PitchCorrectionUndoKey.structuralKey)
            let stored = try #require(store.tracks[0].clips[0].pitchEdits)
            #expect(stored == expected.set, "the store stored something the one transform would not")
            #expect(result.carriedSlideIDs == [table.segments[1].id, table.segments[3].id])
            #expect(stored.segments.map(\.pitchOffsetCents) == [0, 0, 1200, 0, 1200, 0],
                    "sung notes +1200, carried slides 0, sounds unmoved")
            #expect(stored.slideFollowRule == .holdAtOpenSide)
            #expect(try store.undo() == "Tune Notes")
            #expect(store.tracks[0].clips[0].pitchEdits == table, "one undo step did not restore the table")
            // Out of range: all or nothing, the table untouched.
            #expect(throws: ProjectError.self) {
                try store.moveClipNotePitches(clipId: clip.id, segmentIds: nil, byCents: 3000,
                                              undoKey: PitchCorrectionUndoKey.structuralKey)
            }
            #expect(store.tracks[0].clips[0].pitchEdits == table)
            // A named sound moves.
            let sound = table.segments[0].id
            _ = try store.moveClipNotePitches(clipId: clip.id, segmentIds: [sound], byCents: -200,
                                              undoKey: PitchCorrectionUndoKey.structuralKey)
            #expect(store.tracks[0].clips[0].pitchEdits?.segments[0].pitchOffsetCents == -200)
            // A table with only sounds: nothing sung to move, said in words.
            let sounds = Self.newSet([Self.note(0.2, 0.3, origin: .unpitched)])
            let soundClip = Clip(name: "Breaths", startBeat: 0, lengthBeats: 8,
                                 audioFileURL: URL(fileURLWithPath: "/nonexistent/slfx-breaths.wav"),
                                 pitchEdits: sounds)
            let soundStore = ProjectStore(tracks: [Track(name: "Breaths", kind: .audio, clips: [soundClip])])
            do {
                _ = try soundStore.moveClipNotePitches(clipId: soundClip.id, segmentIds: nil, byCents: 100,
                                                       undoKey: PitchCorrectionUndoKey.structuralKey)
                Issue.record("a clip with no sung notes moved")
            } catch let error as ProjectError {
                #expect(error.localizedDescription == NotePitchMoveSentences.noSungNotes)
            }
        }
    }

    // MARK: - W10-SFDC: where a followed slide PLAYS, one home in DAWCore

    static func followRigID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "5FDC0000-0000-4000-8000-%012d", index))!
    }

    /// W10-SFDC's vocal: the pitch editor's vf-18 rig (E1–E3) with uneven
    /// numbers, so a wrong rule or a wrong formula cannot land on the same
    /// bits. Every note sung at 220 Hz:
    ///
    ///     0 A 0.30-0.60 +37.3 · 1 T1 0.60-0.70, a TWO-SIDED slide following 0.7,
    ///     own +15 · 2 B 0.70-1.00 −120.9 · 200 ms gap · 3 C 1.20-1.50 +211.7
    ///     · 4 T2 1.50-1.60, a TAIL-OFF following 1, own −8 · 200 ms gap
    ///     · 5 L 1.80-1.90, a LEAD-IN following 0.45 · 6 E 1.90-2.40 −64.2
    static func followRig(_ rule: PitchEditSet.SlideFollowRule) -> PitchEditSet {
        let spans: [(start: Double, end: Double, cents: Double, follow: Double)] = [
            (0.30, 0.60, 37.3, 0), (0.60, 0.70, 15, 0.7), (0.70, 1.00, -120.9, 0),
            (1.20, 1.50, 211.7, 0), (1.50, 1.60, -8, 1),
            (1.80, 1.90, 0, 0.45), (1.90, 2.40, -64.2, 0)]
        let segments = spans.enumerated().map { index, span in
            NoteSegment(id: followRigID(index), startSeconds: span.start, endSeconds: span.end,
                        detectedHz: 220, detectedConfidence: 0.9,
                        pitchOffsetCents: span.cents, glideFollow: span.follow,
                        origin: span.follow > 0 ? .transition : .detected)
        }
        return withRule(newSet(segments), rule)
    }

    /// What the pitch editor DREW for each followed slide of `followRig`
    /// (`NoteBlob.followCents`, by note index) BEFORE its helper moved here.
    /// CAPTURED 2026-10-12 15:51 by W10-SFDC from the unmoved tree: a
    /// temporary probe test called the editor's own
    /// `PitchEditorModel.slideFollowCents(in:only:)` AND loaded each table
    /// into a real `PitchEditorModel` and read its blobs; both agreed bit for
    /// bit (log `$S/w10/SFDC/logs/capture.log`). A missing index is a note
    /// with no follow entry (it does not follow, or follows 0).
    static let drawnBeforeTheMove: [PitchEditSet.SlideFollowRule: [Int: UInt64]] = [
        // T1 −29.26 · T2 +105.85 (the open side read 0) · L −14.445
        .sungAtOpenSide: [1: 0xc03d428f5c28f5c3, 4: 0x405a766666666666, 5: 0xc02ce3d70a3d70a4],
        // T1 −29.26 · T2 +211.7 (the open side copies C) · L −28.89 (copies E)
        .holdAtOpenSide: [1: 0xc03d428f5c28f5c3, 4: 0x406a766666666666, 5: 0xc03ce3d70a3d70a4]]

    @Test("vf-18 slideFollowCents (W10-SFDC, moved from the pitch editor onto PitchEditSet): a two-sided slide, a tail-off and a lead-in, under BOTH rules, are bit for bit what the editor drew before the move; the one-sided slides split the rules, the two-sided one does not; each value is the middle of the line the slide plays")
    func slideFollowCentsIsWhatTheEditorDrew() {
        let id = Self.followRigID
        for rule in PitchEditSet.SlideFollowRule.allCases {
            let set = Self.followRig(rule)
            #expect(set.slideFollowRule == rule)
            let want = Self.drawnBeforeTheMove[rule] ?? [:]
            #expect(!want.isEmpty, "no capture for \(rule)")
            let follows = set.slideFollowCents()
            let entries = set.segments.indices.filter { follows[set.segments[$0].id] != nil }
            #expect(Set(entries) == Set(want.keys), "\(rule): follow entries at notes \(entries)")
            for (index, bits) in want.sorted(by: { $0.key < $1.key }) {
                let got = follows[id(index)]
                Self.log("SFDC \(rule) note \(index): \(got.map { "\($0)" } ?? "absent"), drawn before \(Double(bitPattern: bits))")
                #expect(got?.bitPattern == bits,
                        "\(rule) note \(index): \(String(describing: got)) is not what the editor drew, \(Double(bitPattern: bits))")
                // THE PHYSICS: at the middle of its span the smoothstep is ½, so
                // the curve plays the slide's own offset plus exactly this.
                let note = set.segments[index]
                let middle = PitchCorrectionCurve.make(editSet: set)
                    .semitones(atSourceSecond: (note.startSeconds + note.endSeconds) / 2)
                let plays = (note.pitchOffsetCents + Double(bitPattern: bits)) / 100
                #expect(abs(middle - plays) < 1e-9,
                        "\(rule) note \(index): the curve's middle plays \(middle) st, the blob says \(plays)")
            }
            // `only:` — the drag's moving notes: the tail-off and a plain note
            // ask for the tail-off alone, same bits; nothing asked, nothing back.
            let only = set.slideFollowCents(only: [id(4), id(0)])
            #expect(only.count == 1 && only[id(4)]?.bitPattern == want[4], "\(rule): only gave \(only)")
            #expect(set.slideFollowCents(only: []).isEmpty)
        }
        // THE RULE SPLIT: a one-sided slide reads the open side as 0 under the
        // legacy rule and copies the present anchor under hold (here twice the
        // value); the two-sided slide's neighbours are both held, so the rules agree.
        let legacy = Self.followRig(.sungAtOpenSide).slideFollowCents()
        let hold = Self.followRig(.holdAtOpenSide).slideFollowCents()
        #expect(legacy[id(1)] != nil && legacy[id(1)]?.bitPattern == hold[id(1)]?.bitPattern)
        for index in [4, 5] {
            #expect(legacy[id(index)].map { 2 * $0 } == hold[id(index)],
                    "note \(index): legacy \(String(describing: legacy[id(index)])), hold \(String(describing: hold[id(index)]))")
        }
    }
}
