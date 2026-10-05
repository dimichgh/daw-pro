import Foundation
import Testing
@testable import DAWCore

// Natural tuning §4 (NT-C C4, design `docs/design/2026-09-25-natural-tuning.md`
// §4.b-§4.g, R10, R14, R15, R27, X7): SOFT JOINS, ON THE CURVE.
//
// A join between two neighbouring curve notes that `PitchEditSet.joinKind`
// calls `.soft` takes ONE width (`PitchEditSet.softJoin`) and ONE edge on both
// sides, so the two gates are complementary there (no F12 dip), and a sung
// slide that follows its neighbours TILTS. Every legacy set keeps today's
// per-note ramps bit for bit (G-TWO in `PitchSpanSearchTests` holds the
// evaluator to a linear-scan mirror on both; the byte goldens that name a
// legacy join are in `NaturalTuningTransitionRenderTests`).
//
// ⭐ HOW Σgate IS READ WITHOUT REACHING `fileprivate` CODE. Every note gets
// `formantOffsetSemitones = 1` and the set `formantCorrection = 1` (the
// formant follows none of the pitch move). The formant evaluator then returns
// `Σ gate · 1`, divided by the sum only when it OVER-sums: at a join it reads
// Σgate exactly whenever Σgate ≤ 1, which is where a dip lives. It shares the
// pitch loop's gates and spans (X7), so it sees the same joins.
//
// Pure and nonisolated (the `@MainActor` suite cap is full). The store half
// (setters, undo, split, stamp) is in `PitchCorrectionWriterTests`.
struct PitchTransitionTests {

    // MARK: - Fixtures

    static func note(_ start: Double, _ end: Double, cents: Double = 0,
                     width: Double = 0, follow: Double = 0, formant: Double = 0,
                     origin: NoteOrigin = .detected) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    formantOffsetSemitones: formant, transitionOutMs: width,
                    glideFollow: follow, origin: origin)
    }

    /// `set` with every note's formant offset 1 and the amount 1, so the
    /// formant evaluator reads Σgate (see the banner).
    static func gateProbe(_ set: PitchEditSet) -> PitchEditSet {
        var probe = set
        probe.formantCorrection = 1
        for index in probe.segments.indices { probe.segments[index].formantOffsetSemitones = 1 }
        return probe
    }

    /// Σgate at `t` for `set`'s joins (exact where it is ≤ 1).
    static func gateSum(_ set: PitchEditSet, at t: Double) -> Double {
        PitchCorrectionCurve.make(editSet: gateProbe(set))
            .formantSemitones(atSourceSecond: t, formantPreserve: false)
    }

    /// `t = low + i · step`, index-built.
    static func grid(_ low: Double, _ high: Double, step: Double = 0.0001) -> [Double] {
        (0...Int(((high - low) / step).rounded())).map { low + Double($0) * step }
    }

    static func log(_ message: String) { print("nt-c4| \(message)") }

    // MARK: - R15: the ONE soft-join predicate

    @Test("R15 joinKind: abutting and holes under the threshold are soft; the threshold and beyond is a gap")
    func joinKindRule() {
        let min = PitchEditSet.consonantMinimumGapSeconds
        #expect(PitchEditSet.joinKind(leftEndSeconds: 1.5, rightStartSeconds: 1.5) == .soft)
        #expect(PitchEditSet.joinKind(leftEndSeconds: 1.5, rightStartSeconds: 1.516) == .soft)
        #expect(PitchEditSet.joinKind(leftEndSeconds: 1.5, rightStartSeconds: 1.532) == .soft)
        #expect(PitchEditSet.joinKind(leftEndSeconds: 0, rightStartSeconds: min.nextDown) == .soft)
        #expect(PitchEditSet.joinKind(leftEndSeconds: 0, rightStartSeconds: min) == .gap)
        #expect(PitchEditSet.joinKind(leftEndSeconds: 1.5, rightStartSeconds: 1.8) == .gap)
    }

    /// The curve-notes rule: an UNTOUCHED sound between two notes builds no
    /// span, so the join is between the notes and the sound's length is the
    /// gap. A note and the sound it abuts are never asked about.
    @Test("R15 joins are between CURVE notes: an untouched sound's length is the gap; a moved sound is a curve note")
    func joinsAreBetweenCurveNotes() {
        let long = PitchEditSet(segments: [Self.note(0.5, 1.5, cents: 300),
                                           Self.note(1.5, 1.6, origin: .unpitched),
                                           Self.note(1.6, 2.5)],
                                transitionSlopeCentsPerSecond: 3000)
        #expect(long.nextCurveNoteIndex(after: 0) == 2)
        #expect(long.joinReading(afterSegmentAt: 0)?.kind == .gap,
                "a 100 ms sound between two notes is a gap, not a slide")
        #expect(long.joinReading(afterSegmentAt: 1) == nil, "an untouched sound has no join")
        let short = PitchEditSet(segments: [Self.note(0.5, 1.5, cents: 300),
                                            Self.note(1.5, 1.52, origin: .unpitched),
                                            Self.note(1.52, 2.5)],
                                 transitionSlopeCentsPerSecond: 3000)
        #expect(short.joinReading(afterSegmentAt: 0)?.kind == .soft,
                "a 20 ms sound is under the threshold: the notes around it meet softly")
        var moved = long
        moved.segments[1].pitchOffsetCents = 200
        #expect(moved.nextCurveNoteIndex(after: 0) == 1, "a MOVED sound enters the curve")
        #expect(moved.joinReading(afterSegmentAt: 0)?.kind == .soft)
        #expect(long.joinReading(afterSegmentAt: 2)?.kind == .last)
    }

    // MARK: - G-AUTO: the width grows with the jump

    @Test("G-AUTO Δ 100/300/500 c at 3000 c/s ⇒ 33.3/100/166.7 ms; Δ 0 ⇒ retune; explicit width overrides; the shorter note caps it")
    func autoWidth() throws {
        func applied(_ a: NoteSegment, _ b: NoteSegment, retune: Double = 30,
                     slope: Double = 3000) -> Double? {
            PitchEditSet(segments: [a, b], retuneMs: retune, transitionSlopeCentsPerSecond: slope)
                .joinReading(afterSegmentAt: 0)?.appliedWidthMs
        }
        for (cents, expected) in [(100.0, 100.0 / 3), (300.0, 100.0), (500.0, 500.0 / 3)] {
            let width = try #require(applied(Self.note(0.5, 1.5, cents: cents), Self.note(1.5, 2.5)))
            Self.log("G-AUTO Δ \(cents) c → \(width) ms")
            #expect(abs(width - expected) < 1e-9, "Δ \(cents) c: \(width) ms, expected \(expected)")
        }
        // Δ = 0: the retune floor, not 0.
        #expect(applied(Self.note(0.5, 1.5, cents: 300), Self.note(1.5, 2.5, cents: 300),
                        retune: 80) == 80)
        // An explicit width on the LEFT note overrides the rule.
        #expect(applied(Self.note(0.5, 1.5, cents: 500, width: 250), Self.note(1.5, 2.5)) == 250)
        // Next to a 60 ms note the join cannot be wider than 60 ms (§4.b.6).
        let capped = try #require(applied(Self.note(0.5, 1.5, cents: 500), Self.note(1.5, 1.56)))
        #expect(abs(capped - 60) < 1e-9, "capped at the shorter note: \(capped)")
        // A soft join on a LEGACY set applies no soft width: legacy ramps.
        #expect(applied(Self.note(0.5, 1.5, cents: 500), Self.note(1.5, 2.5), slope: 0) == nil)
    }

    // MARK: - G-SUM (I2): a soft join never dips

    /// A +300 / B 0 at an abutting join and across 16 and 32 ms holes (R15):
    /// Σgate is 1 to 1e-12 across the whole join, and the curve falls
    /// monotonically from +3 to 0.
    @Test("G-SUM a soft join sums to 1 (abutting, 16 ms and 32 ms holes) and the curve is monotone")
    func softJoinNeverDips() {
        for hole in [0.0, 0.016, 0.032] {
            let set = PitchEditSet(segments: [Self.note(0.5, 1.5, cents: 300),
                                              Self.note(1.5 + hole, 2.5)],
                                   transitionSlopeCentsPerSecond: 3000)
            let curve = PitchCorrectionCurve.make(editSet: set)
            var worstSum = 0.0
            var rises = 0
            var previous = Double.infinity
            for t in Self.grid(1.3, 1.75) {
                worstSum = max(worstSum, abs(Self.gateSum(set, at: t) - 1))
                let value = curve.semitones(atSourceSecond: t)
                if value > previous + 1e-12 { rises += 1 }
                previous = value
            }
            Self.log("G-SUM hole \(hole * 1000) ms: max |Σgate − 1| \(worstSum), rises \(rises)")
            #expect(worstSum < 1e-12, "hole \(hole): Σgate departs from 1 by \(worstSum)")
            #expect(rises == 0, "hole \(hole): the curve rises \(rises) times on a falling join")
            #expect(curve.semitones(atSourceSecond: 1.2) == 3)
            #expect(curve.semitones(atSourceSecond: 1.9) == 0)
        }
    }

    /// − control: the LEGACY F12 shape (retune 200, a 60 ms note after a 2 s
    /// note, both +300 c) still dips, so the instrument above can see a dip
    /// and legacy is untouched.
    @Test("G-SUM − legacy F12 still dips (the probe can see a dip; legacy is untouched)")
    func legacyStillDips() {
        let set = PitchEditSet(segments: [Self.note(0, 2, cents: 300), Self.note(2, 2.06, cents: 300)],
                               retuneMs: 200)
        #expect(!set.usesSoftJoins)
        let lowest = Self.grid(1.85, 2.0).map { Self.gateSum(set, at: $0) }.min() ?? 1
        Self.log("G-SUM − legacy F12: lowest Σgate \(lowest)")
        #expect(lowest < 0.9, "the legacy F12 dip vanished: \(lowest)")
    }

    // MARK: - F12 on NT-G's fixture

    /// NT-G's `f12AsymmetricRampDip` fixture (legacy: 89.06 c at −25.5 ms,
    /// `NaturalTuningBaselineTests`), made SOFT by the new-set slope: the dip
    /// is gone. Both notes are +300 c, so the curve must read a flat 3.0 st.
    @Test("F12 NT-G's fixture with a slope: the 89 c dip at the join is gone (flat 3.0 st)")
    func f12DipIsGoneOnASoftSet() {
        let legacy = PitchEditSet(segments: [Self.note(0, 2, cents: 300), Self.note(2, 2.06, cents: 300)],
                                  retuneMs: 200)
        var soft = legacy
        soft.transitionSlopeCentsPerSecond = PitchEditSet.defaultTransitionSlope
        func worstDip(_ set: PitchEditSet) -> (cents: Double, at: Double) {
            let curve = PitchCorrectionCurve.make(editSet: set)
            var worst = (cents: 0.0, at: Double.nan)
            // Up to where the short note starts its own fall (its end − 30 ms).
            for t in Self.grid(1.85, 2.03) {
                let dip = (3 - curve.semitones(atSourceSecond: t)) * 100
                if dip > worst.cents { worst = (dip, t) }
            }
            return worst
        }
        let before = worstDip(legacy)
        let after = worstDip(soft)
        Self.log(String(format: "F12 legacy dip %.2f c at %.1f ms; soft dip %.3e c",
                        before.cents, (before.at - 2) * 1000, after.cents))
        #expect(before.cents > 80, "the legacy dip is the fixture's own positive control: \(before)")
        #expect(after.cents < 1e-9, "the soft join still dips \(after.cents) c at \(after.at)")
    }

    // MARK: - G-TILT: a following slide tilts from the moved note to the unmoved one

    /// A +300 c (0.5-1.0 s), T a 200 ms sung slide following fully, B 0 c
    /// (1.2-2.0 s), all abutting, slope 3000, retune 30.
    static func tiltSet(a: Double = 300, t: Double = 0, b: Double = 0,
                        follow: Double = 1) -> PitchEditSet {
        PitchEditSet(segments: [note(0.5, 1.0, cents: a),
                                note(1.0, 1.2, cents: t, follow: follow, origin: .transition),
                                note(1.2, 2.0, cents: b)],
                     transitionSlopeCentsPerSecond: 3000)
    }

    @Test("G-TILT a followed slide starts at the moved note's pitch and lands on the unmoved one")
    func followedSlideTilts() throws {
        let curve = PitchCorrectionCurve.make(editSet: Self.tiltSet())
        let start = curve.semitones(atSourceSecond: 1.0)
        let middle = curve.semitones(atSourceSecond: 1.1)
        let end = curve.semitones(atSourceSecond: 1.2)
        Self.log("G-TILT start \(start) mid \(middle) end \(end) st")
        #expect(abs(start - 3) < 1e-9, "the slide starts at \(start), not at A's +3 st")
        #expect(abs(middle - 1.5) < 1e-9, "the smoothstep midpoint is +1.5 st: \(middle)")
        #expect(abs(end) < 1e-9, "the slide lands at \(end), not on B")
        // Δ = 0 at both joins, so both take the retune floor (30 ms).
        let set = Self.tiltSet()
        #expect(set.joinReading(afterSegmentAt: 0)?.appliedWidthMs == 30)
        #expect(set.joinReading(afterSegmentAt: 1)?.appliedWidthMs == 30)
        // Monotone across the whole slide: a tilt, never a snap-back.
        var previous = Double.infinity
        for t in Self.grid(0.9, 1.3) {
            let value = curve.semitones(atSourceSecond: t)
            #expect(value <= previous + 1e-12, "the tilt rises at \(t)")
            previous = value
        }
    }

    /// − controls: with follow 0 the slide snaps back to 0 at its start (the
    /// regime-3 defect, today's legacy behaviour); the mirror image (B moved)
    /// tilts the other way; the slide's own offset still ADDS (a drag of a
    /// followed slide is never inert); alone between gaps it is a constant.
    @Test("G-TILT − follow 0 snaps back; B moved mirrors; the slide's own drag adds; alone it is a constant")
    func tiltControls() {
        let unfollowed = PitchCorrectionCurve.make(editSet: Self.tiltSet(follow: 0))
        #expect(abs(unfollowed.semitones(atSourceSecond: 1.05)) < 1e-9,
                "with follow 0 the slide should sit at its own 0 (today's snap-back)")
        let mirrored = PitchCorrectionCurve.make(editSet: Self.tiltSet(a: 0, b: 300))
        #expect(abs(mirrored.semitones(atSourceSecond: 1.0)) < 1e-9)
        #expect(abs(mirrored.semitones(atSourceSecond: 1.2) - 3) < 1e-9)
        let dragged = PitchCorrectionCurve.make(editSet: Self.tiltSet(t: 100))
        #expect(abs(dragged.semitones(atSourceSecond: 1.1) - 2.5) < 1e-9,
                "a +100 c drag of the followed slide must move it by +1 st (additive, §4.b.3)")
        let alone = PitchEditSet(segments: [Self.note(0.5, 1.0, cents: 300),
                                            Self.note(1.2, 1.4, cents: 100, follow: 1),
                                            Self.note(1.6, 2.0)],
                                 transitionSlopeCentsPerSecond: 3000)
        #expect(PitchCorrectionCurve.make(editSet: alone).semitones(atSourceSecond: 1.3) == 1,
                "between two gaps a following note has nothing to follow: its own +1 st")
    }

    // MARK: - I1 / I3: at most two gates along a chain of soft joins

    /// Fuzz 10 000 CHAINS OF SOFT JOINS (abutting or R15 short holes, notes
    /// ≥ 60 ms, random offsets, widths, follows and slopes) through the ONE
    /// width rule, `PitchEditSet.softJoin`. For every note the incoming
    /// join's window must end before the outgoing join's window begins (so
    /// no point sees the previous note's fall, this note and the next note's
    /// rise at once: I1), and each note's reach (edge + h) must not
    /// decrease along the chain (I3, R15).
    @Test("G-TWO I1/I3 10k soft chains: never three gates, and the reach never decreases")
    func softChainsHoldTwoGates() {
        var rng = PitchSpanSearchTests.Rng(state: 0x0925_2026_C4C4_0011)
        var overlaps = 0
        var reachDrops = 0
        var joins = 0
        var shortHoles = 0
        var example = ""
        for _ in 0..<10_000 {
            let count = 3 + Int(rng.next() % 6)
            var notes: [NoteSegment] = []
            var cursor = 0.1
            for _ in 0..<count {
                let duration = rng.chance(0.4) ? rng.uniform(0.06, 0.12) : rng.uniform(0.06, 1.5)
                notes.append(Self.note(cursor, cursor + duration,
                                       cents: rng.uniform(-1200, 1200),
                                       width: rng.chance(0.5) ? 0 : rng.uniform(30, 1000),
                                       follow: rng.chance(0.7) ? 0 : rng.unit()))
                cursor += duration
                if rng.chance(0.4) {
                    cursor += rng.uniform(0, PitchEditSet.consonantMinimumGapSeconds * 0.99)
                }
            }
            let slope = rng.logUniform(500, 20_000)
            let retune = rng.uniform(30, 500)
            var joinsHere: [PitchEditSet.SoftJoin] = []
            for index in 0..<(count - 1) {
                let left = notes[index], right = notes[index + 1]
                guard PitchEditSet.joinKind(leftEndSeconds: left.endSeconds,
                                            rightStartSeconds: right.startSeconds) == .soft,
                      let join = PitchEditSet.softJoin(left: left, right: right, retuneMs: retune,
                                                       slopeCentsPerSecond: slope) else {
                    Issue.record("a generated join is not soft")
                    return
                }
                if left.endSeconds != right.startSeconds { shortHoles += 1 }
                joinsHere.append(join)
            }
            joins += joinsHere.count
            for index in 1..<(count - 1) {
                let incoming = joinsHere[index - 1], outgoing = joinsHere[index]
                // 1e-12 s: `start + d/2` and `end − d/2` may round a ulp
                // apart when both halves clamp to half the note.
                if incoming.edgeSeconds + incoming.halfWidthSeconds
                    > outgoing.edgeSeconds - outgoing.halfWidthSeconds + 1e-12 {
                    overlaps += 1
                    if example.isEmpty { example = "note \(index) of \(notes.map(\.durationSeconds))" }
                }
                if incoming.edgeSeconds + incoming.halfWidthSeconds
                    > outgoing.edgeSeconds + outgoing.halfWidthSeconds + 1e-12 {
                    reachDrops += 1
                }
            }
        }
        Self.log("I1/I3 soft chains: \(joins) joins (\(shortHoles) across short holes), "
                 + "\(overlaps) three-gate windows, \(reachDrops) reach drops")
        #expect(joins > 30_000 && shortHoles > 1_000, "the fuzz lost its joins: \(joins), \(shortHoles)")
        #expect(overlaps == 0, "\(overlaps) notes see three gates at once; first: \(example)")
        #expect(reachDrops == 0, "\(reachDrops) reach drops along soft chains")
    }

    // MARK: - Legacy stays legacy; one explicit width touches one join

    /// A slope-0 set with ONE explicit width is soft only at that join: every
    /// sample away from it reads the legacy curve bit for bit (§4.b.2 "a set
    /// can be soft only because some OTHER note has an explicit width").
    @Test("one explicit width on a slope-0 set changes that join only (bit-identical elsewhere)")
    func oneWidthTouchesOneJoin() {
        let legacy = PitchEditSet(segments: [Self.note(0.5, 1.5, cents: 400),
                                             Self.note(1.5, 2.5),
                                             Self.note(2.5, 3.5, cents: -300)])
        #expect(!legacy.usesSoftJoins)
        var edited = legacy
        edited.segments[1].transitionOutMs = 200
        #expect(edited.usesSoftJoins && edited.transitionSlopeCentsPerSecond == 0)
        let before = PitchCorrectionCurve.make(editSet: legacy)
        let after = PitchCorrectionCurve.make(editSet: edited)
        var changedNearEditedJoin = 0
        for t in Self.grid(0.3, 3.7, step: 0.0005) {
            let a = before.semitones(atSourceSecond: t).bitPattern
            let b = after.semitones(atSourceSecond: t).bitPattern
            if abs(t - 2.5) <= 0.1 + 1e-9 {
                if a != b { changedNearEditedJoin += 1 }
            } else {
                #expect(a == b, "t = \(t) moved, but only the 2.5 s join was edited")
            }
        }
        #expect(changedNearEditedJoin > 0, "the edited join did not change: the width is not read")
    }

    // MARK: - X7: the formant crossfade follows the join width

    /// At a 500 c soft join (W = 166.7 ms) with the formant following half
    /// the move (c = 0.5), the formant's 50 % point and 10-90 % width match
    /// the pitch's, and the width is the soft one, not the 30 ms retune.
    @Test("X7 the formant crossfade tracks the soft join: same 50 % point, same width, not the retune's")
    func formantFollowsJoinWidth() throws {
        var set = PitchEditSet(segments: [Self.note(0.5, 1.5, cents: 500), Self.note(1.5, 2.5)],
                               transitionSlopeCentsPerSecond: 3000)
        set.formantCorrection = 0.5
        let curve = PitchCorrectionCurve.make(editSet: set)
        func crossings(_ value: (Double) -> Double, top: Double) -> (p10: Double, p50: Double, p90: Double) {
            var p10 = Double.nan, p50 = Double.nan, p90 = Double.nan
            for t in Self.grid(1.3, 1.7) {
                let fraction = value(t) / top
                if p90.isNaN && fraction <= 0.9 { p90 = t }
                if p50.isNaN && fraction <= 0.5 { p50 = t }
                if p10.isNaN && fraction <= 0.1 { p10 = t }
            }
            return (p10, p50, p90)
        }
        let pitch = crossings({ curve.semitones(atSourceSecond: $0) }, top: 5)
        let formant = crossings({ curve.formantSemitones(atSourceSecond: $0, formantPreserve: false) },
                                top: 2.5)
        let pitchWidth = pitch.p10 - pitch.p90
        let formantWidth = formant.p10 - formant.p90
        Self.log(String(format: "X7 pitch 50%% at %.4f s, 10-90 %.1f ms; formant 50%% at %.4f s, 10-90 %.1f ms",
                        pitch.p50, pitchWidth * 1000, formant.p50, formantWidth * 1000))
        #expect(abs(pitch.p50 - formant.p50) <= 0.03, "the formant crosses 50 % more than a hop away")
        #expect(abs(pitchWidth - formantWidth) < 0.0005)
        // 10-90 % of a smoothstep over 2h = 166.7 ms is ≈ 0.61 · 166.7 ≈ 101 ms;
        // at the 30 ms retune it would be ≈ 18 ms.
        #expect(formantWidth > 0.08, "the formant crossfade is the retune's, not the join's: \(formantWidth)")
    }

    // MARK: - The transforms (the one home of the three setters' rules)

    static let clip = UUID(uuidString: "C4000000-0000-4000-8000-0000000000CC")!

    /// A: 0.5-1.5 +300 | B: 1.5-2.5 (abutting A) | gap | S: an untouched
    /// sound 2.6-2.7 | gap | C: 2.8-3.5 (the last note).
    static func table() -> PitchEditSet {
        PitchEditSet(segments: [note(0.5, 1.5, cents: 300), note(1.5, 2.5),
                                note(2.6, 2.7, origin: .unpitched), note(2.8, 3.5)],
                     transitionSlopeCentsPerSecond: 3000)
    }

    static func refusal(_ body: () throws -> PitchEditSet) -> String? {
        do {
            _ = try body()
            return nil
        } catch let error as ProjectError {
            return error.localizedDescription
        } catch {
            return "\(error)"
        }
    }

    @Test("applyingNoteTransition: Auto, clamps, one field only; refuses sound, last note, gap, NaN and negative in words")
    func transitionTransform() throws {
        let set = Self.table()
        let a = set.segments[0].id, b = set.segments[1].id
        let s = set.segments[2].id, c = set.segments[3].id
        let wide = try set.applyingNoteTransition(segmentId: a, widthMs: 5000, clipId: Self.clip)
        #expect(wide.segments[0].transitionOutMs == 1000, "clamped to the field's ceiling")
        #expect(wide.segments.dropFirst() == set.segments.dropFirst(), "only the named note moves")
        #expect(wide.transitionSlopeCentsPerSecond == set.transitionSlopeCentsPerSecond)
        #expect(try set.applyingNoteTransition(segmentId: a, widthMs: 10, clipId: Self.clip)
                    .segments[0].transitionOutMs == 30, "raised to one hop")
        #expect(try wide.applyingNoteTransition(segmentId: a, widthMs: nil, clipId: Self.clip)
                    .segments[0].transitionOutMs == 0, "nil is Auto")
        #expect(try wide.applyingNoteTransition(segmentId: a, widthMs: 0, clipId: Self.clip)
                    .segments[0].transitionOutMs == 0, "0 is Auto")
        // What applies is capped by the notes, and read back through `make`'s rule.
        #expect(wide.joinReading(afterSegmentAt: 0)?.appliedWidthMs == 1000)
        let shortNeighbour = PitchEditSet(segments: [Self.note(0.5, 1.5, cents: 300),
                                                     Self.note(1.5, 1.58)],
                                          transitionSlopeCentsPerSecond: 3000)
        let capped = try shortNeighbour.applyingNoteTransition(
            segmentId: shortNeighbour.segments[0].id, widthMs: 400, clipId: Self.clip)
        #expect(capped.segments[0].transitionOutMs == 400, "the stored width is the request")
        let applied = try #require(capped.joinReading(afterSegmentAt: 0)?.appliedWidthMs)
        #expect(abs(applied - 80) < 1e-9, "the applied width is capped at the 80 ms note: \(applied)")

        let sound = Self.refusal { try set.applyingNoteTransition(segmentId: s, widthMs: 100, clipId: Self.clip) }
        let last = Self.refusal { try set.applyingNoteTransition(segmentId: c, widthMs: 100, clipId: Self.clip) }
        let gap = Self.refusal { try set.applyingNoteTransition(segmentId: b, widthMs: 100, clipId: Self.clip) }
        let nan = Self.refusal { try set.applyingNoteTransition(segmentId: a, widthMs: .nan, clipId: Self.clip) }
        let negative = Self.refusal { try set.applyingNoteTransition(segmentId: a, widthMs: -5, clipId: Self.clip) }
        let unknown = Self.refusal { try set.applyingNoteTransition(segmentId: UUID(), widthMs: 100, clipId: Self.clip) }
        for (name, message) in [("sound", sound), ("last", last), ("gap", gap), ("nan", nan),
                                ("negative", negative), ("unknown", unknown)] {
            Self.log("refusal \(name): \(message ?? "NONE")")
        }
        #expect(sound == PitchTransitionSentences.soundHasNoSlide(s))
        #expect(last == PitchTransitionSentences.lastNoteHasNoSlide(c))
        #expect(gap == PitchTransitionSentences.gapHasNoSlide(b))
        #expect(nan == PitchTransitionSentences.widthNotANumber(.nan))
        #expect(negative == PitchTransitionSentences.widthNotANumber(-5))
        #expect(unknown?.contains("carries 4 note(s)") == true, "\(unknown ?? "none")")
    }

    @Test("applyingNoteGlideFollow: clamps, one field; refuses sound, NaN, and a follow with nothing to follow (0 always allowed)")
    func followTransform() throws {
        let set = Self.table()
        let a = set.segments[0].id, s = set.segments[2].id, c = set.segments[3].id
        let followed = try set.applyingNoteGlideFollow(segmentId: a, amount: 7, clipId: Self.clip)
        #expect(followed.segments[0].glideFollow == 1)
        #expect(followed.segments.dropFirst() == set.segments.dropFirst())
        #expect(try followed.applyingNoteGlideFollow(segmentId: a, amount: -1, clipId: Self.clip)
                    .segments[0].glideFollow == 0)
        // C sits between two gaps: following would take and do nothing.
        #expect(Self.refusal { try set.applyingNoteGlideFollow(segmentId: c, amount: 1, clipId: Self.clip) }
                == PitchTransitionSentences.nothingToFollow(c))
        // `set` predates natural tuning (no formant amount, a tuned note). A
        // follow that CHANGES a note is its first hand edit and updates it
        // (D4-1 (b), the user's ruling); stopping C's follow, which is already
        // off, changes no note, so it leaves the old vocal exactly as it is
        // (the no-op rule).
        #expect(set.predatesNaturalTuning)
        #expect(!followed.predatesNaturalTuning, "a real follow left an old vocal on the old rule")
        #expect(try set.applyingNoteGlideFollow(segmentId: c, amount: 0, clipId: Self.clip) == set,
                "stopping a follow is always allowed, and stopping one that is off changes nothing")
        #expect(Self.refusal { try set.applyingNoteGlideFollow(segmentId: s, amount: 1, clipId: Self.clip) }
                == PitchTransitionSentences.soundCannotFollow(s))
        #expect(Self.refusal { try set.applyingNoteGlideFollow(segmentId: a, amount: .infinity, clipId: Self.clip) }
                == PitchTransitionSentences.followNotANumber(.infinity))
    }

    @Test("applyingTransitionSmoothness: nil is the default, clamps; 0, negative and NaN are refused in words; nothing else moves")
    func smoothnessTransform() throws {
        var legacy = Self.table()
        legacy.transitionSlopeCentsPerSecond = 0
        #expect(!legacy.usesSoftJoins)
        let defaulted = try legacy.applyingTransitionSmoothness(centsPerSecond: nil)
        #expect(defaulted.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        #expect(defaulted.segments == legacy.segments && defaulted.formantCorrection == nil,
                "an explicit smoothness upgrades THIS field alone (§4.j)")
        #expect(try legacy.applyingTransitionSmoothness(centsPerSecond: 100).transitionSlopeCentsPerSecond == 500)
        #expect(try legacy.applyingTransitionSmoothness(centsPerSecond: 1e9).transitionSlopeCentsPerSecond == 20_000)
        #expect(Self.refusal { try legacy.applyingTransitionSmoothness(centsPerSecond: 0) }
                == PitchTransitionSentences.smoothnessZero)
        #expect(Self.refusal { try legacy.applyingTransitionSmoothness(centsPerSecond: -0.0) }
                == PitchTransitionSentences.smoothnessZero)
        #expect(Self.refusal { try legacy.applyingTransitionSmoothness(centsPerSecond: -10) }
                == PitchTransitionSentences.smoothnessNotANumber(-10))
        #expect(Self.refusal { try legacy.applyingTransitionSmoothness(centsPerSecond: .nan) }
                == PitchTransitionSentences.smoothnessNotANumber(.nan))
    }

    // MARK: - D4-1 and the upgrade

    /// D4-1 = (b), the user's ruling of 2026-09-26 ("The first note you drag
    /// on an old vocal updates the whole vocal (also one Undo)"); this test
    /// pinned option (a) until then. A hand edit on a LEGACY set updates it
    /// through the one hook, once, and the update keeps an explicit slope.
    @Test("D4-1 (b): a hand edit on a legacy set updates it once; the upgrade fills the slope only when it is 0")
    func d41UpdatesALegacySetAndUpgradeKeepsAPick() throws {
        #expect(PitchEditSet.handEditUpgradesLegacyVocal,
                "the user ruled Q-U1 = (b) on 2026-09-26")
        var legacy = Self.table()
        legacy.transitionSlopeCentsPerSecond = 0
        #expect(legacy.predatesNaturalTuning, "positive control: this is a legacy tuned vocal")
        let dragged = try legacy.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: legacy.segments[1].id, offsetCents: 200)], clipId: Self.clip)
        #expect(!dragged.predatesNaturalTuning
                && dragged.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope
                && dragged.formantCorrection == PitchEditSet.newSetFormantCorrection
                && dragged.keepsConsonantsUntuned,
                "a pitch drag left a legacy vocal on the old rule (D4-1 (b))")
        var movedOnly = legacy
        movedOnly.segments[1].pitchOffsetCents = 200
        #expect(dragged == movedOnly.upgradedToNaturalTuning(), "the drag is not the move, then the update")
        #expect(movedOnly.afterHandEdit() == dragged)
        #expect(dragged.afterHandEdit() == dragged, "only the first hand edit updates")
        let upgraded = movedOnly.upgradedToNaturalTuning()
        #expect(upgraded.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        #expect(upgraded.formantCorrection == PitchEditSet.newSetFormantCorrection
                && upgraded.keepsConsonantsUntuned)
        var picked = movedOnly
        picked.transitionSlopeCentsPerSecond = 6000
        #expect(picked.predatesNaturalTuning, "a picked slope alone does not make a vocal new")
        #expect(picked.upgradedToNaturalTuning().transitionSlopeCentsPerSecond == 6000,
                "the upgrade threw away an explicit smoothness pick")
        #expect(picked.afterHandEdit().transitionSlopeCentsPerSecond == 6000,
                "a hand edit's update threw away an explicit smoothness pick")
    }

    // MARK: - The drag's reach: where a pitch drag can change the curve

    /// ⭐ A SPY GATE, not a shape gate: for 300 seeded soft sets (the G-TWO
    /// soft generator), move ONE random note by a random amount through the
    /// drag's own transform and compare the whole curve of the set the drag
    /// starts from with the set it stores, on a 1 ms grid. Every sample that
    /// changed must lie inside `pitchDragReach` of the set it starts from.
    ///  * D4-1 (b), the user's ruling (`handEditUpgradesLegacyVocal`): on a
    ///    set that predates natural tuning the drag is the FIRST hand edit and
    ///    updates the whole vocal, so the reach must cover every note. The
    ///    positive control is that finding: such a drag changes samples
    ///    outside the note's own reach (`noteDragReach`).
    ///  * On a set that is already new, and on a SECOND drag (another note of
    ///    the set a first drag stored), the reach is the note's own, and every
    ///    change still lies inside it.
    ///  * NT-U2's finding stays: on soft sets a drag changes samples OUTSIDE
    ///    today's `draftSpan` rule (the note ± retune/2), so the pitch
    ///    editor's draft window must widen.
    @Test("drag reach: every change a one-note drag makes lies inside pitchDragReach; a first drag on an old vocal reaches the whole vocal (D4-1 (b)), a second drag or a new set the note's own reach")
    func dragReachContainsEveryChange() throws {
        var rng = PitchSpanSearchTests.Rng(state: 0x0925_2026_C4C4_0021)
        // The second drags draw from their OWN stream, so the 300 fixtures
        // are the same sets this gate drew before the second drag existed.
        var secondRng = PitchSpanSearchTests.Rng(state: 0x0927_2026_D41D_0002)
        var tally = DragReachTally()
        for _ in 0..<300 {
            let fixture = PitchSpanSearchTests.randomSoftFixture(&rng).set
            guard !fixture.segments.isEmpty else { continue }
            let index = Int(rng.next() % UInt64(fixture.segments.count))
            let moved = try Self.drag(fixture, noteAt: index, &rng)
            try Self.checkReach(from: fixture, noteAt: index, to: moved, isSecondDrag: false, &tally)
            guard fixture.afterHandEdit() != fixture else { continue }
            #expect(moved.afterHandEdit() == moved,
                    "the first drag stored a set the next hand edit would update again")
            let other = Int(secondRng.next() % UInt64(moved.segments.count))
            let movedAgain = try Self.drag(moved, noteAt: other, &secondRng)
            try Self.checkReach(from: moved, noteAt: other, to: movedAgain, isSecondDrag: true, &tally)
        }
        Self.log("drag reach: \(tally.changedPoints) changed samples, \(tally.escapes) outside the reach; "
                 + "\(tally.firstDrags) first drags on an old vocal (\(tally.firstDragsBeyondTheNote) "
                 + "changed the curve outside the note's own reach), \(tally.secondDrags) second drags, "
                 + "\(tally.newSetDrags) drags on a new set, \(tally.neverTunedDrags) first drags on a "
                 + "never-tuned table; \(tally.beyondLegacyRule) samples outside today's note ± retune/2 window")
        #expect(tally.changedPoints > 1000, "the fuzz moved almost nothing")
        #expect(tally.firstDrags > 0 && tally.secondDrags > 0 && tally.newSetDrags > 0,
                "positive control: the fuzz holds old vocals, second drags and new sets")
        #expect(tally.firstDragsBeyondTheNote > 0,
                "positive control: a first drag on an old vocal should change the curve outside the note's own reach (the whole-vocal update, D4-1 (b))")
        #expect(tally.escapes == 0, "a drag changed the curve outside its reach: \(tally.example)")
        #expect(tally.notWholeVocal.isEmpty,
                "a first drag on an old vocal did not reach the whole vocal: \(tally.notWholeVocal.prefix(3))")
        #expect(tally.notNoteOwn.isEmpty,
                "a second drag or a new set did not keep the note's own reach: \(tally.notNoteOwn.prefix(3))")
        #expect(tally.beyondLegacyRule > 0,
                "positive control: on soft sets a drag should reach past note ± retune/2 (the NT-U2 finding)")
    }

    /// What `dragReachContainsEveryChange` counts.
    struct DragReachTally {
        var changedPoints = 0
        var escapes = 0
        var example = ""
        var beyondLegacyRule = 0
        var firstDrags = 0
        var firstDragsBeyondTheNote = 0
        var secondDrags = 0
        var newSetDrags = 0
        var neverTunedDrags = 0
        var notWholeVocal: [String] = []
        var notNoteOwn: [String] = []
    }

    /// One random move of the note at `index`, through the drag's own
    /// transform (so it stores what a real drag stores, D4-1 included).
    static func drag(_ set: PitchEditSet, noteAt index: Int,
                     _ rng: inout PitchSpanSearchTests.Rng) throws -> PitchEditSet {
        let note = set.segments[index]
        return try set.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: note.id,
                             offsetCents: note.pitchOffsetCents + rng.uniform(-900, 900))],
            clipId: clip)
    }

    /// Compares `set`'s curve with `moved`'s on a 1 ms grid and holds every
    /// changed sample to `set.pitchDragReach(ofSegmentAt: index)`; tallies
    /// which reach the drag took.
    static func checkReach(from set: PitchEditSet, noteAt index: Int, to moved: PitchEditSet,
                           isSecondDrag: Bool, _ tally: inout DragReachTally) throws {
        let note = set.segments[index]
        let reach = try #require(set.pitchDragReach(ofSegmentAt: index))
        let own = try #require(set.noteDragReach(ofSegmentAt: index))
        let first = set.afterHandEdit() != set
        if first {
            tally.firstDrags += 1
            let low = set.segments.map(\.startSeconds).min() ?? 0
            let high = set.segments.map(\.endSeconds).max() ?? 0
            if reach != set.wholeVocalDragReach() || reach.lowerBound > low || reach.upperBound < high {
                tally.notWholeVocal.append("\(reach) for notes \(low)...\(high)")
            }
        } else {
            if isSecondDrag {
                tally.secondDrags += 1
            } else if set.formantCorrection != nil {
                tally.newSetDrags += 1
            } else if moved.withSegments(set.segments) != set {
                tally.neverTunedDrags += 1
            }
            if reach != own { tally.notNoteOwn.append("\(reach) vs the note's own \(own)") }
        }
        let half = max(0, set.retuneMs / 1000 / 2)
        let legacyRule = (note.startSeconds - half)...(note.endSeconds + half)
        let before = PitchCorrectionCurve.make(editSet: set)
        let after = PitchCorrectionCurve.make(editSet: moved)
        let end = (set.segments.last?.endSeconds ?? 0) + 1.5
        var beyondTheNote = false
        for t in grid(0, end, step: 0.001) {
            let a = before.semitones(atSourceSecond: t)
            let b = after.semitones(atSourceSecond: t)
            let fa = before.formantSemitones(atSourceSecond: t, formantPreserve: false)
            let fb = after.formantSemitones(atSourceSecond: t, formantPreserve: false)
            guard a.bitPattern != b.bitPattern || fa.bitPattern != fb.bitPattern else { continue }
            tally.changedPoints += 1
            if !reach.contains(t) {
                tally.escapes += 1
                if tally.example.isEmpty {
                    tally.example = "t \(t) outside \(reach) (note \(index) of \(set.segments.count), "
                        + (first ? "a first drag)" : isSecondDrag ? "a second drag)" : "a plain drag)")
                }
            }
            if first && !own.contains(t) { beyondTheNote = true }
            if !first && moved.usesSoftJoins && !legacyRule.contains(t) { tally.beyondLegacyRule += 1 }
        }
        if beyondTheNote { tally.firstDragsBeyondTheNote += 1 }
    }

    /// The no-op rule on the drag's reach (2026-09-27): `pitchDragReach`
    /// answers for a drag that MOVES the note. A drag that ends where it
    /// started changes no note, so the drag's own transform stores the old
    /// vocal as it was and not one curve sample changes: the note's own
    /// (narrow) reach holds it, as would any window. A real move of the same
    /// note is still the old vocal's first hand edit.
    @Test("drag reach and the no-op rule: a zero-offset drag on an old vocal stores it unchanged and changes no sample")
    func zeroOffsetDragChangesNothing() throws {
        let old = Self.table()
        #expect(old.predatesNaturalTuning, "positive control: a vocal tuned before the update")
        let a = old.segments[0]
        let stayed = try old.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: a.id, offsetCents: a.pitchOffsetCents)], clipId: Self.clip)
        #expect(stayed == old, "a drag that moved nothing changed the vocal")
        let before = PitchCorrectionCurve.make(editSet: old)
        let after = PitchCorrectionCurve.make(editSet: stayed)
        var changed = 0
        for t in Self.grid(0, 4, step: 0.001) {
            let x = before.semitones(atSourceSecond: t)
            let y = after.semitones(atSourceSecond: t)
            let fx = before.formantSemitones(atSourceSecond: t, formantPreserve: false)
            let fy = after.formantSemitones(atSourceSecond: t, formantPreserve: false)
            if x.bitPattern != y.bitPattern || fx.bitPattern != fy.bitPattern { changed += 1 }
        }
        #expect(changed == 0, "a zero-offset drag changed \(changed) curve samples")
        let moved = try old.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: a.id, offsetCents: a.pitchOffsetCents + 100)], clipId: Self.clip)
        #expect(!moved.predatesNaturalTuning, "positive control: a real move updates the old vocal")
        #expect(old.pitchDragReach(ofSegmentAt: 0) == old.wholeVocalDragReach(),
                "the reach answers for a drag that MOVES the note, which updates the whole vocal")
    }

    /// A set whose joins are LEGACY but which is already on natural tuning's
    /// voice (a formant amount, as the set-level switch leaves it, and slope
    /// 0): a drag does not update it, so the reach is exactly today's
    /// `draftSpan` rule. Its twin with NO amount predates natural tuning: the
    /// drag updates the whole vocal (D4-1 (b)), so the reach is every note,
    /// each widened by the soft rule. This test pinned today's rule on that
    /// twin until the user's ruling.
    @Test("drag reach: legacy joins with a voice amount keep today's note ± retune/2 exactly; the same notes with no amount (an old vocal) reach the whole vocal")
    func dragReachOnLegacyIsTodaysRule() throws {
        let notes = [Self.note(0.5, 1.5, cents: 300), Self.note(1.5, 2.5)]
        let legacyJoins = PitchEditSet(segments: notes, retuneMs: 80, formantCorrection: 1)
        #expect(!legacyJoins.usesSoftJoins && !legacyJoins.predatesNaturalTuning)
        #expect(legacyJoins.pitchDragReach(ofSegmentAt: 0) == (0.5 - 0.04)...(1.5 + 0.04))
        #expect(legacyJoins.pitchDragReach(ofSegmentAt: 2) == nil)
        let old = PitchEditSet(segments: notes, retuneMs: 80)
        #expect(old.predatesNaturalTuning, "positive control: this is a vocal tuned before the update")
        // Both notes are 1 s long: max(0.04, 0.5 + half the 64 ms short hole).
        let widening = 0.5 + PitchEditSet.consonantMinimumGapSeconds / 2
        for index in [0, 1] {
            #expect(old.pitchDragReach(ofSegmentAt: index) == (0.5 - widening)...(2.5 + widening),
                    "a first drag on an old vocal updates every note, whichever one is dragged")
        }
        #expect(old.pitchDragReach(ofSegmentAt: 2) == nil)
    }

    /// D4-1 (b)'s edge: a table with NO voice amount whose notes bend nothing
    /// (never tuned, or every move undone) does not predate natural tuning,
    /// so its reach is not the whole vocal. But its first drag bends a note,
    /// and `afterHandEdit()` then updates the set the drag stores, default
    /// slope included: the joins next to the dragged note turn soft and
    /// reach past today's note ± retune/2. The reach is read on that stored
    /// set (`noteDragReach`), so it must hold them.
    @Test("drag reach on a never-tuned table with no voice amount: the drag's stored set has soft joins, and the reach holds them")
    func dragReachOnANeverTunedTable() throws {
        let plain = PitchEditSet(segments: [Self.note(0, 1), Self.note(1, 2), Self.note(2, 3)],
                                 retuneMs: 30)
        #expect(!plain.predatesNaturalTuning && plain.afterHandEdit() == plain && !plain.usesSoftJoins,
                "positive control: a never-tuned table with legacy joins")
        let moved = try plain.applyingNotePitchOffsets(
            [NotePitchOffset(segmentId: plain.segments[1].id, offsetCents: 900)], clipId: Self.clip)
        #expect(moved.usesSoftJoins && moved.formantCorrection == PitchEditSet.newSetFormantCorrection,
                "the drag updated the set it stores (D4-1 (b))")
        let reach = try #require(plain.pitchDragReach(ofSegmentAt: 1))
        let before = PitchCorrectionCurve.make(editSet: plain)
        let after = PitchCorrectionCurve.make(editSet: moved)
        let todaysRule = (1 - 0.015)...(2 + 0.015)
        var changed = 0
        var pastTodaysRule = 0
        var escapes: [Double] = []
        for t in Self.grid(0, 3.5, step: 0.001) {
            let a = before.semitones(atSourceSecond: t)
            let b = after.semitones(atSourceSecond: t)
            let fa = before.formantSemitones(atSourceSecond: t, formantPreserve: false)
            let fb = after.formantSemitones(atSourceSecond: t, formantPreserve: false)
            guard a.bitPattern != b.bitPattern || fa.bitPattern != fb.bitPattern else { continue }
            changed += 1
            if !todaysRule.contains(t) { pastTodaysRule += 1 }
            if !reach.contains(t) { escapes.append(t) }
        }
        Self.log("never-tuned drag: \(changed) changed samples, \(pastTodaysRule) past note ± retune/2, "
                 + "reach \(reach), \(escapes.count) outside it")
        #expect(pastTodaysRule > 0,
                "positive control: the stored set's soft joins should reach past note ± retune/2")
        #expect(escapes.isEmpty, "the drag changed the curve outside its reach: \(escapes.prefix(3))")
        #expect(reach == plain.noteDragReach(ofSegmentAt: 1) && reach != plain.wholeVocalDragReach(),
                "only the dragged note bends, so the note's own reach, not the whole vocal")
    }
}
