import Foundation
import Testing
@testable import DAWCore

/// m23-ap C5b-1 (design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md`
/// §5.2-§5.3): THE DRAWN SHAPE's model and curve term.
///
/// A drawn shape is a DELTA in tenths of a cent on a global 10 ms grid
/// anchored at source second 0, one more term in the curve's sum inside the
/// note's gate, read in SOURCE time, interpolated linearly and HELD at both
/// ends. Deliberately NOT `@MainActor`: every type here is a pure value.
@Suite("C5b-1 — the drawn pitch shape: fields, healing, Codable, predicates, curve term")
struct NoteShapeModelTests {

    static let id = UUID(uuidString: "C5B10000-0000-4000-8000-000000000001")!
    static let idB = UUID(uuidString: "C5B10000-0000-4000-8000-000000000002")!

    static func note(start: Double = 1, end: Double = 2, cents: Double = 0,
                     shapeStart: Int = 0, shape: [Int16] = [],
                     origin: NoteOrigin = .detected) -> NoteSegment {
        NoteSegment(id: id, startSeconds: start, endSeconds: end, detectedHz: 220,
                    detectedConfidence: 0.9, pitchOffsetCents: cents,
                    shapeStartIndex: shapeStart, shapeTenthsOfCents: shape, origin: origin)
    }

    // MARK: - Healing (`NoteSegment.init`, and so decode)

    @Test("healing: every sample is clamped to ±12 000 tenths (±1200 c)")
    func healingClampsEverySample() {
        let healed = Self.note(shapeStart: 100,
                               shape: [.min, -12_001, -12_000, 0, 12_000, 12_001, .max])
        #expect(healed.shapeTenthsOfCents == [-12_000, -12_000, -12_000, 0, 12_000, 12_000, 12_000])
        #expect(healed.shapeStartIndex == 100)
        #expect(NoteSegment.shapeCentsRange == -1200...1200)
        #expect(NoteSegment.shapeGridHz == 100)
    }

    @Test("healing: an empty shape stores index 0, and is no shape")
    func emptyShapeStoresIndexZero() {
        let empty = Self.note(shapeStart: 57, shape: [])
        #expect(empty.shapeStartIndex == 0)
        #expect(!empty.hasShape)
    }

    /// ⭐ THE NEGATIVE-INDEX RULE, PICKED AND PINNED: a sample whose grid index
    /// is below 0 is DROPPED, never moved, so every kept sample stays at its
    /// own source second (the global-grid argument, §5.2). The same rule
    /// drops samples past the 24 h structural bound.
    @Test("healing: samples at a NEGATIVE grid index are dropped; the rest keep their own times")
    func negativeStartDropsSamplesBeforeZero() {
        let clipped = Self.note(shapeStart: -3, shape: [10, 20, 30, 40, 50])
        #expect(clipped.shapeStartIndex == 0)
        #expect(clipped.shapeTenthsOfCents == [40, 50],
                "sample k sits at index start + k: indices -3,-2,-1 go, 0 and 1 stay")
        // Every sample before zero: nothing is left, so no shape (index 0).
        let gone = Self.note(shapeStart: -5, shape: [10, 20, 30, 40, 50])
        #expect(!gone.hasShape && gone.shapeStartIndex == 0)
        // The extreme: no arithmetic on `Int.min` may trap.
        let extreme = Self.note(shapeStart: .min, shape: [1, 2, 3])
        #expect(!extreme.hasShape && extreme.shapeStartIndex == 0)
    }

    @Test("healing: samples past the 24 h bound are dropped the same way, and Int.max cannot trap")
    func samplesPastTheBoundAreDropped() {
        let bound = NoteSegment.shapeMaxIndex
        #expect(bound == 8_640_000, "24 h on the 100 Hz grid, the anchor's structural bound")
        let tail = Self.note(shapeStart: bound - 1, shape: [1, 2, 3])
        #expect(tail.shapeStartIndex == bound - 1)
        #expect(tail.shapeTenthsOfCents == [1, 2])
        let far = Self.note(shapeStart: .max, shape: [1, 2, 3])
        #expect(!far.hasShape && far.shapeStartIndex == 0)
    }

    @Test("healing: an all-zero shape is STILL a shape (the setter, not init, empties it)")
    func allZeroIsStillAShape() {
        // Design §5.2: "store an all-zero array as empty" is the SETTER's
        // normalisation. `init` heals only what cannot be represented, so a
        // hand-authored all-zero array is a shape that renders as nothing.
        let zeros = Self.note(shapeStart: 100, shape: [0, 0, 0])
        #expect(zeros.hasShape)
        #expect(!zeros.isPitchIdentity)
    }

    // MARK: - Codable

    @Test("Codable: a shape-free note writes no shape key; absent keys decode empty")
    func shapeFreeNoteWritesNoKey() throws {
        let plain = Self.note(cents: 12)
        let object = try #require(try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(plain)) as? [String: Any])
        #expect(object["shapeStartIndex"] == nil)
        #expect(object["shapeTenthsOfCents"] == nil)
        #expect(Set(object.keys) == ["id", "startSeconds", "endSeconds", "detectedHz",
                                     "detectedConfidence", "pitchOffsetCents"])
        let decoded = try JSONDecoder().decode(NoteSegment.self, from: JSONEncoder().encode(plain))
        #expect(decoded == plain)
        #expect(!decoded.hasShape && decoded.shapeStartIndex == 0)
    }

    @Test("Codable: a shaped note round-trips exactly, both keys written")
    func shapedNoteRoundTrips() throws {
        let shaped = Self.note(shapeStart: 123, shape: [-12_000, -1, 0, 1, 500, 12_000])
        let data = try JSONEncoder().encode(shaped)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["shapeStartIndex"] as? Int == 123)
        #expect((object["shapeTenthsOfCents"] as? [Int]) == [-12_000, -1, 0, 1, 500, 12_000])
        let decoded = try JSONDecoder().decode(NoteSegment.self, from: data)
        #expect(decoded == shaped)
        #expect(decoded.shapeTenthsOfCents == shaped.shapeTenthsOfCents)
        #expect(decoded.shapeStartIndex == 123)
    }

    /// ⛔ THE DECODE MUST NOT THROW on a sample `Int16` cannot hold: a
    /// `[Int16]` decode of 40 000 throws, and one bad note would fail the
    /// whole project. Samples are read as numbers and healed like every other
    /// field (rounded to the nearest tenth, clamped), and a negative start
    /// heals by the drop rule.
    @Test("Codable: out-of-range, fractional and negative-index samples heal instead of throwing")
    func handAuthoredShapeHeals() throws {
        let json = """
        {"id":"\(Self.id.uuidString)","startSeconds":1,"endSeconds":2,"detectedHz":220,
         "detectedConfidence":0.9,"shapeStartIndex":-2,
         "shapeTenthsOfCents":[5,6,40000,-99999.7,12.4,12.6,-0.4]}
        """
        let decoded = try JSONDecoder().decode(NoteSegment.self, from: Data(json.utf8))
        #expect(decoded.shapeStartIndex == 0)
        #expect(decoded.shapeTenthsOfCents == [12_000, -12_000, 12, 13, 0])
    }

    // MARK: - Predicates

    /// ⛔ THE SILENT FAILURE OF THIS WHOLE ITEM (design §5.8 mode 1): a shape
    /// missing from `isPitchIdentity` sends a shape-only set down the
    /// identity bypass, and the clip plays unshaped while every setter echoes
    /// success.
    @Test("predicates: a shape-only note is NOT pitch identity; the set and the clip follow")
    func shapeBreaksPitchIdentity() {
        let shaped = Self.note(shapeStart: 120, shape: [0, 500, 0])
        #expect(shaped.hasShape)
        #expect(!shaped.isPitchIdentity)
        #expect(!shaped.isIdentity)
        #expect(shaped.isEdited)
        #expect(!shaped.wantsContourShaping, "a shape needs no contour (§5.2)")
        let set = PitchEditSet(segments: [shaped])
        #expect(!set.isPitchIdentity && !set.isIdentity)
        #expect(!set.needsDetectedContour)
        let clip = Clip(name: "Vocal", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/c5b-never-opened.wav"),
                        pitchEdits: set)
        #expect(clip.hasPitchEdits)
        #expect(clip.rendersThroughStretchCache)
    }

    /// A shape on a SOUND (`.unpitched`) must enter the curve (R21's rule: a
    /// deliberate value on a sound comes in). Without it the set is not
    /// identity, the stretcher runs, and the sound's span does not exist: the
    /// shape would be silently dropped.
    @Test("predicates: a shaped SOUND enters the pitch curve, and its shape is read")
    func shapedSoundEntersTheCurve() {
        let sound = Self.note(shapeStart: 120, shape: [500, 500, 500], origin: .unpitched)
        #expect(sound.entersPitchCurve)
        let untouched = Self.note(origin: .unpitched)
        #expect(!untouched.entersPitchCurve, "positive control: an untouched sound stays out")
        let curve = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [sound]))
        #expect(abs(curve.semitones(atSourceSecond: 1.5) - 0.5) < 1e-12)
    }

    // MARK: - The curve term (§5.3)

    static func curve(_ notes: [NoteSegment], retuneMs: Double = 30,
                      slope: Double = 0, warpDuration: Double? = nil) -> PitchCorrectionCurve {
        let set = PitchEditSet(segments: notes, retuneMs: retuneMs,
                               transitionSlopeCentsPerSecond: slope)
        let warp = warpDuration.flatMap { PitchTimeWarp.make(editSet: set, sourceDurationSeconds: $0) }
        return PitchCorrectionCurve.make(editSet: set, timeWarp: warp)
    }

    @Test("term: linear between grid samples, tenths ÷ 1000 semitones, on the note's constant")
    func termIsLerpedOnTheGrid() {
        // Samples at 1.20, 1.21, 1.22, 1.23 s: 0, 50, 100, 50 cents.
        let shaped = Self.curve([Self.note(cents: 20, shapeStart: 120, shape: [0, 500, 1000, 500])])
        func st(_ t: Double) -> Double { shaped.semitones(atSourceSecond: t) }
        #expect(abs(st(1.2) - 0.2) < 1e-9)
        #expect(abs(st(1.21) - 0.7) < 1e-9)
        #expect(abs(st(1.215) - 0.95) < 1e-9, "half-way between 0.5 and 1.0 st")
        #expect(abs(st(1.22) - 1.2) < 1e-9)
        #expect(abs(st(1.2275) - 0.825) < 1e-9, "three quarters of the way from 1.0 st to 0.5 st")
        #expect(abs(st(1.25) - 0.7) < 1e-9, "past the last sample, held at +50 c")
    }

    @Test("term: HELD at both ends — before the first sample and after the last, the end values")
    func termIsHeldAtBothEnds() {
        // Samples at 1.50 and 1.51 s: +30 c and +60 c. The note runs 1..2 s.
        let shaped = Self.curve([Self.note(shapeStart: 150, shape: [300, 600])])
        for t in [1.1, 1.3, 1.49, 1.5] {
            #expect(abs(shaped.semitones(atSourceSecond: t) - 0.3) < 1e-12,
                    "at \(t) s, before the first sample, the term is not held at +30 c")
        }
        for t in [1.51, 1.6, 1.9] {
            #expect(abs(shaped.semitones(atSourceSecond: t) - 0.6) < 1e-12,
                    "at \(t) s, after the last sample, the term is not held at +60 c")
        }
    }

    /// ⭐ THE STRUCTURAL BRANCH: the term is added only when a span HAS a
    /// shape, so every shape-free span evaluates bit for bit as before, and
    /// a shape on one note never touches a note it does not reach.
    @Test("term: a shape on note A leaves every second outside A's gate bit-identical")
    func shapeFreeSpansAreBitIdentical() {
        var a = Self.note(start: 0.5, end: 1.0, cents: 15)
        let b = NoteSegment(id: Self.idB, startSeconds: 1.4, endSeconds: 2.0, detectedHz: 233,
                            detectedConfidence: 0.8, pitchOffsetCents: -30,
                            vibratoRateHz: 5.5, vibratoDepthCents: 40)
        let plain = Self.curve([a, b])
        a.shapeStartIndex = 50
        a.shapeTenthsOfCents = [0, 300, 600, 300, 0]
        let shaped = Self.curve([a, b])
        var outside = 0
        for k in 0..<2_500 {
            let t = Double(k) / 1000
            let inA = t > 0.5 - 0.016 && t < 1.0 + 0.016
            let p = plain.semitones(atSourceSecond: t)
            let s = shaped.semitones(atSourceSecond: t)
            if !inA {
                outside += 1
                #expect(p.bitPattern == s.bitPattern, "at \(t) s, outside note A, the curve moved")
            }
        }
        #expect(outside > 1_900)
        #expect(shaped.semitones(atSourceSecond: 0.52) != plain.semitones(atSourceSecond: 0.52),
                "positive control: inside A the shape is read")
    }

    @Test("term: it ADDS to the constant, the drift/vibrato scales and the generator")
    func termAddsToEveryOtherTerm() {
        let base = NoteSegment(id: Self.id, startSeconds: 1, endSeconds: 2, detectedHz: 220,
                               detectedConfidence: 0.9, pitchOffsetCents: -25,
                               driftScale: 0.5, vibratoScale: 0.25,
                               vibratoRateHz: 5.5, vibratoDepthCents: 60,
                               vibratoPhaseAnchorSeconds: 1.1)
        var shapedNote = base
        shapedNote.shapeStartIndex = 110
        shapedNote.shapeTenthsOfCents = (0..<80).map { Int16(($0 * 37) % 900 - 450) }
        // A sung contour for the two scales to shape: a 5 Hz, ±20 c wobble
        // on a 10 c/s drift, one frame per 10 ms across the note.
        let contour = (90...210).map { frame -> ClipPitchFrame in
            let t = Double(frame) / 100
            let cents = 20 * sin(2 * .pi * 5 * t) + 10 * (t - 1)
            return ClipPitchFrame(timeSeconds: t, frequencyHz: 220 * pow(2, cents / 1200),
                                  confidence: 0.9, levelDbfs: -12, absence: nil)
        }
        let plain = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [base]),
                                              contour: contour)
        let shaped = PitchCorrectionCurve.make(editSet: PitchEditSet(segments: [shapedNote]),
                                               contour: contour)
        #expect(plain.unresolvedShapingSegmentIDs.isEmpty,
                "precondition: the scales must resolve, or they are not in the sum")
        let unshaped = Self.curve([base])
        #expect(plain.semitones(atSourceSecond: 1.43) != unshaped.semitones(atSourceSecond: 1.43),
                "precondition: the shaping term is really non-zero")
        let term = Self.curve([Self.note(cents: 0, shapeStart: 110,
                                         shape: shapedNote.shapeTenthsOfCents)])
        for k in 0..<400 {
            let t = 1.05 + Double(k) * 0.0022
            let difference = shaped.semitones(atSourceSecond: t) - plain.semitones(atSourceSecond: t)
            #expect(abs(difference - term.semitones(atSourceSecond: t)) < 1e-12,
                    "at \(t) s the shape did not simply add")
        }
    }

    /// ⭐ SOURCE TIME, NOT EDITED TIME (§5.3): the user drew against the sung
    /// audio, so retiming carries the drawing with it. On a retimed curve the
    /// generator reads W(s); the shape must read s.
    @Test("term: on a RETIMED curve the shape is read at the SOURCE second, not the edited one")
    func termRunsInSourceTime() throws {
        var stretched = NoteSegment(id: Self.id, startSeconds: 0.5, endSeconds: 1.5,
                                    detectedHz: 220, detectedConfidence: 0.9,
                                    timeEndDeltaSeconds: 0.3)
        // A steep ramp, 0 → +100 c over 0.6..1.4 s, so a W(s) ≠ s read lands
        // on a visibly different sample.
        stretched.shapeStartIndex = 60
        stretched.shapeTenthsOfCents = (0...80).map { Int16($0 * 1000 / 80) }
        let retimed = Self.curve([stretched], warpDuration: 3)
        let warp = try #require(retimed.timeWarp)
        let untimedTerm = Self.curve([Self.note(start: 0.5, end: 1.5, shapeStart: 60,
                                                shape: stretched.shapeTenthsOfCents)])
        var moved = 0
        for k in 0..<60 {
            let s = 0.7 + Double(k) * 0.01
            let edited = warp.editedSecond(forSourceSecond: s)
            if abs(edited - s) > 0.02 { moved += 1 }
            #expect(abs(retimed.semitones(atSourceSecond: s)
                        - untimedTerm.semitones(atSourceSecond: s)) < 1e-12,
                    "at source \(s) s (edited \(edited) s) the shape was not read at the source second")
        }
        #expect(moved > 20, "precondition: the warp really moves these seconds")
    }

    /// Natural tuning §4 coexistence: the shape is ONE MORE TERM inside note
    /// A's gate. At a soft join the two gates are complementary, so the shape
    /// reaches the join weighted by A's gate and never more; B's follower
    /// tilt reads A's OWN offset, never A's shape; the join's width does not
    /// move. Nothing double-counts.
    @Test("term: at a soft join the shape is weighted by its own gate and never double-counts")
    func shapeAtASoftJoinNeverDoubleCounts() {
        let a = NoteSegment(id: Self.id, startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220,
                            detectedConfidence: 0.9, pitchOffsetCents: 100)
        let b = NoteSegment(id: Self.idB, startSeconds: 1.0, endSeconds: 1.6, detectedHz: 220,
                            detectedConfidence: 0.9, pitchOffsetCents: -50, glideFollow: 1)
        var shapedA = a
        // +80 c held across the whole of A and past its end: the worst case
        // for a join, the shape's full value sits on A's side of the edge.
        shapedA.shapeStartIndex = 50
        shapedA.shapeTenthsOfCents = [Int16](repeating: 800, count: 51)
        let plain = Self.curve([a, b], retuneMs: 30, slope: 3000)
        let shaped = Self.curve([shapedA, b], retuneMs: 30, slope: 3000)
        var sawBlend = false
        for k in 0..<1_000 {
            let t = 0.6 + Double(k) * 0.001
            let difference = shaped.semitones(atSourceSecond: t) - plain.semitones(atSourceSecond: t)
            #expect(difference >= -1e-12 && difference <= 0.8 + 1e-12,
                    "at \(t) s the shape contributed \(difference) st, outside 0…0.8")
            if difference > 0.01 && difference < 0.79 { sawBlend = true }
            if t < 0.95 { #expect(abs(difference - 0.8) < 1e-12) }
            if t > 1.2 {
                #expect(shaped.semitones(atSourceSecond: t).bitPattern
                            == plain.semitones(atSourceSecond: t).bitPattern,
                        "at \(t) s, deep in B, A's shape reached B (its tilt or its join)")
            }
        }
        #expect(sawBlend, "precondition: the join really crossfades A into B")
    }

    @Test("term: the formant curve never reads the shape (the envelope follows the constant move only)")
    func formantNeverReadsTheShape() {
        let plainNote = NoteSegment(id: Self.id, startSeconds: 1, endSeconds: 2, detectedHz: 220,
                                    detectedConfidence: 0.9, pitchOffsetCents: 300)
        var shapedNote = plainNote
        shapedNote.shapeStartIndex = 110
        shapedNote.shapeTenthsOfCents = [0, 2_000, 4_000, 2_000, 0]
        let plain = PitchCorrectionCurve.make(editSet: PitchEditSet(
            segments: [plainNote], formantCorrection: 0.5))
        let shaped = PitchCorrectionCurve.make(editSet: PitchEditSet(
            segments: [shapedNote], formantCorrection: 0.5))
        for k in 0..<200 {
            let t = 1.0 + Double(k) * 0.005
            #expect(shaped.formantSemitones(atSourceSecond: t, formantPreserve: false).bitPattern
                        == plain.formantSemitones(atSourceSecond: t, formantPreserve: false).bitPattern)
        }
        #expect(shaped.semitones(atSourceSecond: 1.12) != plain.semitones(atSourceSecond: 1.12),
                "positive control: the PITCH curve reads it")
    }

    // MARK: - Provenance

    /// `contentStamp` is a JSON encode of the set, so a shape counts as a hand
    /// edit the moment `encode` writes it; no provenance code changed.
    @Test("provenance: a drawn shape on a preset's output reads as a hand edit")
    func shapeIsAHandEdit() {
        let preset = PitchEditSet(segments: [Self.note(cents: 30)]).stampedAsAutoCorrectOutput()
        #expect(!preset.hasHandEditsSinceAutoCorrect, "positive control: untouched output")
        var drawn = preset
        drawn.segments[0].shapeStartIndex = 120
        drawn.segments[0].shapeTenthsOfCents = [0, 10, 0]
        #expect(drawn.hasHandEditsSinceAutoCorrect)
        #expect(drawn.contentStamp != preset.contentStamp)
        // The drawn samples' VALUES are in the stamp, not only their presence.
        var redrawn = drawn
        redrawn.segments[0].shapeTenthsOfCents = [0, 11, 0]
        #expect(redrawn.contentStamp != drawn.contentStamp)
    }

    /// C5b-3a: moving a drawing by one grid step, or clearing it, is a hand
    /// edit too — the stamp reads the index, not only the values.
    @Test("provenance: a drawing moved one grid step, or cleared, reads as a hand edit")
    func shapeIndexAndClearAreHandEdits() {
        var drawnNote = Self.note(cents: 30)
        drawnNote.shapeStartIndex = 120
        drawnNote.shapeTenthsOfCents = [0, 10, 0]
        let preset = PitchEditSet(segments: [drawnNote]).stampedAsAutoCorrectOutput()
        #expect(!preset.hasHandEditsSinceAutoCorrect, "positive control: untouched output")
        var moved = preset
        moved.segments[0].shapeStartIndex = 121
        #expect(moved.hasHandEditsSinceAutoCorrect)
        let cleared = PitchEditSet(segments: [NoteShapeSamples.clear.applied(to: drawnNote)])
        #expect(cleared.contentStamp != preset.contentStamp)
    }

    // MARK: - C5b-3a: the write rule (`NoteShapeSamples.swift`)

    /// ⭐ ONE GRID RULE, THE MATHEMATICAL ONE. `0.07 × 100` is
    /// `7.000000000000001` in floating point, so a bare `ceil` skips the
    /// sample sitting exactly at 0.07 s and a bare `floor` of `0.29 × 100`
    /// (`28.999999999999996`) lands one step early. Every write and every test
    /// asks these functions, never its own `ceil`.
    @Test("C5b-3a grid: ONE rule, the mathematical ceiling and floor — a second exactly on a step IS that step")
    func gridRuleIsTheMathematicalOne() {
        let past: Double = 0.07 * 100
        let short: Double = 0.29 * 100
        #expect(past > 7.0, "positive control: the floating-point product really is past the step")
        #expect(short < 29.0, "positive control: and this one really is short of it")
        #expect(NoteShapeSamples.gridIndex(atOrAfter: 0.07) == 7)
        #expect(NoteShapeSamples.gridIndex(atOrBefore: 0.07) == 7)
        #expect(NoteShapeSamples.gridIndex(atOrAfter: 0.29) == 29)
        #expect(NoteShapeSamples.gridIndex(atOrBefore: 0.29) == 29)
        #expect(NoteShapeSamples.gridIndex(atOrAfter: 0.071) == 8)
        #expect(NoteShapeSamples.gridIndex(atOrBefore: 0.079) == 7)
        #expect(NoteShapeSamples.gridIndex(atOrAfter: -3) == 0)
        #expect(NoteShapeSamples.gridIndex(atOrAfter: .nan) == 0)
        #expect(NoteShapeSamples.gridIndex(atOrAfter: .infinity) == 0)
        #expect(NoteShapeSamples.gridIndex(atOrAfter: 1e300) == NoteSegment.shapeMaxIndex + 1)
        #expect(NoteShapeSamples.seconds(atGridIndex: 7) == 0.07)
        #expect(NoteShapeSamples.gridSpan(of: Self.note(start: 1, end: 2)) == 100..<200)
        #expect(NoteShapeSamples.gridSpan(of: Self.note(start: 0.07, end: 0.29)) == 7..<29)
        #expect(NoteShapeSamples.gridSpan(of: Self.note(start: 1.001, end: 1.009)).isEmpty,
                "a note that holds no grid point has nothing to draw on")
    }

    /// Design §5.2's normalisation, as the store applies it. ⛔ THE HELD-ENDS
    /// TRAP: a partial write must be ZERO-FILLED across the note, or its first
    /// and last samples play across the whole of it.
    @Test("C5b-3a normalise: trimmed to the note, ZERO-FILLED around a partial write, clamped, all-zero stored as a clear")
    func normalisedIsTheWholeSpan() {
        let note = Self.note(start: 1, end: 1.1)   // grid span 100..<110
        let partial = NoteShapeSamples(startIndex: 104, tenthsOfCents: [300, 400])
        let stored = partial.normalised(for: note)
        #expect(stored.startIndex == 100)
        #expect(stored.tenthsOfCents == [0, 0, 0, 0, 300, 400, 0, 0, 0, 0],
                "a partial write was not zero-filled across the note's grid span")
        // Trimmed: samples before and after the note are dropped, never moved.
        let wide = NoteShapeSamples(startIndex: 98,
                                    tenthsOfCents: [9, 9, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 9, 9])
        #expect(wide.normalised(for: note)
                == NoteShapeSamples(startIndex: 100, tenthsOfCents: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]))
        // Clamped to ±12 000 tenths (±1200 c).
        let loud = NoteShapeSamples(startIndex: 100, tenthsOfCents: [.max, .min, 5])
        #expect(Array(loud.normalised(for: note).tenthsOfCents.prefix(3)) == [12_000, -12_000, 5])
        // All zero, a clear, and a write that misses the note: stored as a CLEAR.
        #expect(NoteShapeSamples(startIndex: 100, tenthsOfCents: [0, 0, 0]).normalised(for: note) == .clear)
        #expect(NoteShapeSamples.clear.normalised(for: note) == .clear)
        let miss = NoteShapeSamples(startIndex: 300, tenthsOfCents: [50])
        #expect(miss.normalised(for: note) == .clear)
        #expect(!miss.reaches(note) && partial.reaches(note))
        // Extreme starts cannot trap.
        #expect(NoteShapeSamples(startIndex: .min, tenthsOfCents: [1]).normalised(for: note) == .clear)
        #expect(NoteShapeSamples(startIndex: .max, tenthsOfCents: [1]).normalised(for: note) == .clear)
        // Deterministic: normalising what was stored stores the same bytes.
        #expect(stored.normalised(for: note) == stored)
    }

    @Test("C5b-3a normalise: a partial write onto an undrawn note plays 0 outside it — the held ends cannot stretch it")
    func partialWriteDoesNotStretchAcrossTheNote() {
        let note = Self.note(start: 1, end: 2)
        let drawn = NoteShapeSamples(startIndex: 140, tenthsOfCents: [500, 500, 500]).applied(to: note)
        let curve = Self.curve([drawn])
        #expect(abs(curve.semitones(atSourceSecond: 1.41) - 0.5) < 1e-12, "positive control: the write plays")
        for t in [1.1, 1.2, 1.3, 1.38, 1.44, 1.6, 1.8] {
            #expect(curve.semitones(atSourceSecond: t) == 0, "at \(t) s the held end stretched the write")
        }
        // THE TRAP ITSELF, measured: the same three samples stored bare DO
        // play across the note, which is what the zero-fill exists to stop.
        let bare = Self.curve([Self.note(shapeStart: 140, shape: [500, 500, 500])])
        #expect(abs(bare.semitones(atSourceSecond: 1.2) - 0.5) < 1e-12)
    }

    // MARK: - C5b-3a: splicing sparse points (the wire's form)

    /// ⭐ THE ZERO-FILL AT THE WIRE'S DOOR: sparse points onto an undrawn note
    /// come back as the note's WHOLE grid span, zero outside the points.
    @Test("C5b-3a splicing: sparse points onto an UNDRAWN note — interpolated between them, ZERO everywhere else")
    func splicingOntoAnEmptyNoteZeroFills() throws {
        let note = Self.note(start: 1, end: 1.2)   // grid span 100..<120
        let spliced = try NoteShapeSamples.splicing(points: [
            NoteShapePoint(seconds: 1.11, cents: -20),   // out of order on purpose: sorted here
            NoteShapePoint(seconds: 1.05, cents: 30),
            NoteShapePoint(seconds: 1.09, cents: 40),
        ], onto: note)
        #expect(spliced.startIndex == 100)
        #expect(spliced.tenthsOfCents.count == 20,
                "the whole grid span, not only the stretch the points cover")
        #expect(spliced.tenthsOfCents == [0, 0, 0, 0, 0, 300, 325, 350, 375, 400,
                                          100, -200, 0, 0, 0, 0, 0, 0, 0, 0])
        // THE HELD-ENDS TRAP, through the curve of the note exactly as stored.
        let curve = Self.curve([Self.note(start: 1, end: 1.2, shapeStart: spliced.startIndex,
                                          shape: spliced.tenthsOfCents)])
        #expect(abs(curve.semitones(atSourceSecond: 1.09) - 0.4) < 1e-12, "positive control")
        #expect(curve.semitones(atSourceSecond: 1.03) == 0, "the first point was held back to the note's start")
        #expect(curve.semitones(atSourceSecond: 1.15) == 0, "the last point was held on to the note's end")
    }

    @Test("C5b-3a splicing: onto a DRAWN note, the rest stays as it PLAYS — its samples and its held ends")
    func splicingKeepsTheRestOfTheNote() throws {
        // Stored 103...105; plays 100 held back to 1.00 s and 300 held on to 1.10 s.
        let note = Self.note(start: 1, end: 1.1, shapeStart: 103, shape: [100, 200, 300])
        let spliced = try NoteShapeSamples.splicing(points: [NoteShapePoint(seconds: 1.07, cents: -50)],
                                                    onto: note)
        #expect(spliced == NoteShapeSamples(startIndex: 100, tenthsOfCents: [100, 100, 100, 100, 200,
                                                                              300, 300, -500, 300, 300]))
        let before = Self.curve([note])
        let after = Self.curve([spliced.applied(to: note)])
        for index in 100..<110 where index != 107 {
            let t = NoteShapeSamples.seconds(atGridIndex: index)
            #expect(abs(before.semitones(atSourceSecond: t) - after.semitones(atSourceSecond: t)) < 1e-12,
                    "at \(t) s, outside the patch, what the note plays changed")
        }
        #expect(after.semitones(atSourceSecond: 1.07) != before.semitones(atSourceSecond: 1.07),
                "positive control: the patched sample moved")
    }

    @Test("C5b-3a splicing: refused in words — no points, NaN, one second twice, off the grid, off the note; a lone point ON a step is fine")
    func splicingRefusals() throws {
        let note = Self.note(start: 1, end: 1.1)
        func refusal(_ points: [NoteShapePoint], onto target: NoteSegment? = nil) -> String? {
            do {
                _ = try NoteShapeSamples.splicing(points: points, onto: target ?? note)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(refusal([]) == NoteShapeSentences.noPoints)
        let nan = NoteShapePoint(seconds: .nan, cents: 1)
        #expect(refusal([NoteShapePoint(seconds: 1.02, cents: 5), nan])
                == NoteShapeSentences.pointNotANumber(position: 2, nan))
        #expect(refusal([NoteShapePoint(seconds: 1.02, cents: 5), NoteShapePoint(seconds: 1.02, cents: 6)])
                == NoteShapeSentences.pointsTwiceAtOneSecond(seconds: 1.02, 5, 6))
        #expect(refusal([NoteShapePoint(seconds: 1.023, cents: 5)]) == NoteShapeSentences.pointsMissTheGrid)
        #expect(refusal([NoteShapePoint(seconds: 3, cents: 5), NoteShapePoint(seconds: 3.5, cents: 5)])
                == NoteShapeSentences.pointsMissTheNote(note, from: 3, to: 3.5))
        // Folded, not refused: the same second twice with the same value.
        #expect(refusal([NoteShapePoint(seconds: 1.02, cents: 5), NoteShapePoint(seconds: 1.02, cents: 5)]) == nil)
        // A point past ±1200 c is clamped, not refused.
        let clamped = try NoteShapeSamples.splicing(points: [NoteShapePoint(seconds: 1.02, cents: 99_999)],
                                                    onto: note)
        try #require(clamped.tenthsOfCents.count == 10, "not the note's whole grid span")
        #expect(clamped.tenthsOfCents[2] == 12_000)
        // THE FLOATING-POINT BOUNDARY: a lone point exactly on a step is one sample.
        let early = Self.note(start: 0, end: 0.2)
        let lone = try NoteShapeSamples.splicing(points: [NoteShapePoint(seconds: 0.07, cents: 12)], onto: early)
        try #require(lone.tenthsOfCents.count == 20, "not the note's whole grid span")
        #expect(lone.tenthsOfCents[7] == 120)
        #expect(lone.tenthsOfCents.filter { $0 != 0 }.count == 1)
    }

    // MARK: - C5b-3a: the split (design §5.3)

    @Test("C5b-3a halves: an INDEX split at ceil(cut·100), each half re-based; an empty or all-zero half is no drawing")
    func halvesAreAnIndexSplit() {
        let note = Self.note(start: 1, end: 1.1, shapeStart: 100,
                             shape: [0, 0, 10, 20, 30, 40, 50, 60, 70, 80])
        let mid = NoteShapeSamples.halves(of: note, atSourceSecond: 1.045)    // k = 105
        #expect(mid.left == NoteShapeSamples(startIndex: 100, tenthsOfCents: [0, 0, 10, 20, 30]))
        #expect(mid.right == NoteShapeSamples(startIndex: 105, tenthsOfCents: [40, 50, 60, 70, 80]))
        // A cut EXACTLY on a step: that step's sample opens the right half.
        let onStep = NoteShapeSamples.halves(of: note, atSourceSecond: 1.07)
        #expect(onStep.left.tenthsOfCents.count == 7 && onStep.right.startIndex == 107)
        // An all-zero half is no drawing (the setter's §5.2 rule), index 0.
        let early = NoteShapeSamples.halves(of: note, atSourceSecond: 1.015)  // k = 102: left [0, 0]
        #expect(early.left == .clear)
        #expect(early.right == NoteShapeSamples(startIndex: 102,
                                                tenthsOfCents: [10, 20, 30, 40, 50, 60, 70, 80]))
        // A cut past the drawing, and one before it.
        let partial = Self.note(start: 1, end: 1.5, shapeStart: 110, shape: [5, 6, 7])
        let late = NoteShapeSamples.halves(of: partial, atSourceSecond: 1.3)
        #expect(late.left == NoteShapeSamples(startIndex: 110, tenthsOfCents: [5, 6, 7]) && late.right == .clear)
        let before = NoteShapeSamples.halves(of: partial, atSourceSecond: 1.05)
        #expect(before.left == .clear && before.right == NoteShapeSamples(startIndex: 110, tenthsOfCents: [5, 6, 7]))
        // No drawing: two clears.
        let plain = NoteShapeSamples.halves(of: Self.note(), atSourceSecond: 1.5)
        #expect(plain.left == .clear && plain.right == .clear)
    }

    /// The shape term exactly as `PitchCorrectionCurve.drawnShape` computes it
    /// (design §5.3), for the split's proof. TIED to the real curve below, so
    /// it cannot drift from what the render plays.
    static func term(_ samples: NoteShapeSamples, at t: Double) -> Double {
        let semitones = samples.tenthsOfCents.map { Double($0) / 1000 }
        guard let first = semitones.first else { return 0 }
        let position = t * NoteSegment.shapeGridHz - Double(samples.startIndex)
        guard position > 0 else { return first }
        let last = semitones.count - 1
        guard position < Double(last) else { return semitones[last] }
        let lower = Int(position)
        let fraction = position - Double(lower)
        return semitones[lower] * (1 - fraction) + semitones[lower + 1] * fraction
    }

    /// ⭐ §5.8 MODE 5, MEASURED: a split inside a drawing moves the drawn line
    /// nowhere except in the ONE grid step that straddles the cut, where each
    /// half holds its end instead of interpolating across; the two sides of
    /// the cut then differ by exactly the step between the samples beside it.
    @Test("C5b-3a split physics: each half plays the parent's line except the one straddling step, and the cut jumps by that step only")
    func splitKeepsTheDrawnLineWithinOneStep() {
        let tenths: [Int16] = (0..<100).map { Int16((3_000 * sin(Double($0) * 0.21)).rounded()) }
        let parent = Self.note(start: 1, end: 2, shapeStart: 100, shape: tenths)
        let whole = NoteShapeSamples(storedIn: parent)
        // TIE: the reference IS the curve's term (the gate is 1 inside the note).
        let curve = Self.curve([parent])
        for k in 0..<300 {
            let t = 1.1 + Double(k) * 0.0027
            #expect(abs(curve.semitones(atSourceSecond: t) - Self.term(whole, at: t)) < 1e-12,
                    "the reference term disagrees with the curve at \(t) s")
        }
        for cut in [1.3, 1.4567, 1.5, 1.73] {
            let halves = NoteShapeSamples.halves(of: parent, atSourceSecond: cut)
            let k = NoteShapeSamples.gridIndex(atOrAfter: cut)
            let straddle = NoteShapeSamples.seconds(atGridIndex: k - 1)..<NoteShapeSamples.seconds(atGridIndex: k)
            let step = abs(Double(tenths[k - 100]) - Double(tenths[k - 101])) / 1000
            #expect(step > 0.01, "precondition: the samples beside the cut at \(cut) s really differ")
            var straddling = 0
            for probe in 0..<1_000 {
                let t = 1 + Double(probe) / 1_000
                let parentTerm = Self.term(whole, at: t)
                let halfTerm = Self.term(t < cut ? halves.left : halves.right, at: t)
                if straddle.contains(t) {
                    straddling += 1
                    #expect(abs(parentTerm - halfTerm) <= step + 1e-12)
                } else {
                    #expect(abs(parentTerm - halfTerm) < 1e-12,
                            "at \(t) s (cut \(cut) s), outside the straddling step, the split moved the line")
                }
            }
            #expect(straddling > 0, "precondition: some probes fall in the straddling step")
            let jump = abs(Self.term(halves.left, at: cut) - Self.term(halves.right, at: cut))
            #expect(abs(jump - step) < 1e-12, "the line jumps by \(jump) st at the cut, not the one step \(step)")
        }
    }

    // MARK: - C5b-3a: the set transform (the store's commit, a brush's draft)

    static let clipId = UUID(uuidString: "C5B30000-0000-4000-8000-00000000C119")!
    static let sound = NoteSegment(id: idB, startSeconds: 1.6, endSeconds: 1.9, detectedHz: 220,
                                   detectedConfidence: 0.4, origin: .unpitched)

    @Test("C5b-3a applyingNoteShapes: writes the two fields on the named note and nothing else; a clear EMPTIES")
    func applyingNoteShapesWritesOnlyTheDrawing() throws {
        let sung = Self.note(start: 1, end: 1.5)
        // A NEW (natural-tuning) set: on a legacy one a hand edit also
        // upgrades the set (D4-1 (b), `afterHandEdit()`), which is not this test.
        let set = PitchEditSet(segments: [sung, Self.sound]).upgradedToNaturalTuning()
        let drawn = try set.applyingNoteShapes(
            [Self.id: NoteShapeSamples(startIndex: 110, tenthsOfCents: [100, 200])], clipId: Self.clipId)
        let note = drawn.segments[0]
        #expect(note.shapeStartIndex == 100)
        try #require(note.shapeTenthsOfCents.count == 50, "not the note's whole grid span")
        #expect(Array(note.shapeTenthsOfCents[10...11]) == [100, 200])
        var rest = note
        rest.shapeStartIndex = 0
        rest.shapeTenthsOfCents = []
        #expect(rest == sung, "a field other than the drawing moved")
        #expect(drawn.segments[1] == Self.sound)
        // ⛔ A CLEAR EMPTIES, NEVER ZEROES: no drawing, index 0, identity again.
        let cleared = try drawn.applyingNoteShapes([Self.id: .clear], clipId: Self.clipId)
        #expect(cleared.segments[0].shapeTenthsOfCents.isEmpty && cleared.segments[0].shapeStartIndex == 0)
        #expect(!cleared.segments[0].hasShape)
        #expect(cleared.segments[0].isPitchIdentity, "a zeroed array would keep the note on the stretcher")
        #expect(cleared == set)
    }

    @Test("C5b-3a applyingNoteShapes: refused in words, all or nothing — no notes, an unknown id, a SOUND, a miss, a sliver")
    func applyingNoteShapesRefusals() throws {
        let sung = Self.note(start: 1, end: 1.5)
        let set = PitchEditSet(segments: [sung, Self.sound])
        let draw = NoteShapeSamples(startIndex: 110, tenthsOfCents: [100, 200])
        func refusal(_ shapes: [UUID: NoteShapeSamples], in table: PitchEditSet? = nil) -> String? {
            do {
                _ = try (table ?? set).applyingNoteShapes(shapes, clipId: Self.clipId)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        #expect(refusal([:]) == NoteShapeSentences.nameAtLeastOneNote)
        let stranger = UUID(uuidString: "C5B30000-0000-4000-8000-0000000000FF")!
        #expect(refusal([stranger: draw]) == "No note with id \(stranger) on clip \(Self.clipId). That clip "
                + "carries 2 note(s); read them back with `clip.getPitchEdits` before editing one.")
        // ⭐ THE SOUND RULING: drawing on a sound is refused, alone or beside a
        // sung note (all or nothing), and so is a clear with nothing to clear.
        let onSound = NoteShapeSamples(startIndex: 165, tenthsOfCents: [100])
        #expect(refusal([Self.idB: onSound]) == NoteShapeSentences.soundHasNoPitchLine(Self.idB))
        #expect(refusal([Self.id: draw, Self.idB: onSound]) == NoteShapeSentences.soundHasNoPitchLine(Self.idB))
        #expect(refusal([Self.idB: .clear]) == NoteShapeSentences.soundHasNoPitchLine(Self.idB))
        // A write that reaches no part of its note would erase it silently.
        #expect(refusal([Self.id: NoteShapeSamples(startIndex: 300, tenthsOfCents: [100])])
                == NoteShapeSentences.drawingMissesTheNote(sung))
        let sliver = Self.note(start: 1.001, end: 1.009)
        let sliverSet = PitchEditSet(segments: [sliver])
        try #require(sliverSet.segments.count == 1, "precondition: the set keeps an 8 ms note")
        #expect(refusal([Self.id: draw], in: sliverSet) == NoteShapeSentences.noteTooShortToDraw(sliver))
        // POSITIVE CONTROLS: the same note takes a real drawing, and a clear
        // of an undrawn SUNG note is a quiet no-op, never a refusal.
        #expect(refusal([Self.id: draw]) == nil)
        #expect(refusal([Self.id: .clear]) == nil)
    }

    /// The one write a sound takes: a CLEAR of a drawing it already carries
    /// (only a hand-written file can put one there). It only removes.
    @Test("C5b-3a applyingNoteShapes: a sound's own hand-written drawing can be cleared, and nothing else moves")
    func aSoundsHandWrittenDrawingCanBeCleared() throws {
        let handWritten = NoteSegment(id: Self.idB, startSeconds: 1.6, endSeconds: 1.9, detectedHz: 220,
                                      detectedConfidence: 0.4, shapeStartIndex: 165,
                                      shapeTenthsOfCents: [100, 100], origin: .unpitched)
        let set = PitchEditSet(segments: [Self.note(start: 1, end: 1.5), handWritten])
            .upgradedToNaturalTuning()
        let cleaned = try set.applyingNoteShapes([Self.idB: .clear], clipId: Self.clipId)
        #expect(!cleaned.segments[1].hasShape)
        #expect(cleaned.segments[1] == Self.sound)
        #expect(cleaned.segments[0] == set.segments[0])
    }
}
