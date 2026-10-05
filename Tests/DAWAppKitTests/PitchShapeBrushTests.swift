import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

/// m23-ap C5b-4a — **THE PITCH BRUSH'S MATH, HEADLESS**, and the one DAWCore
/// reading it stands on, `PitchPlayedLine.playedMidi(atSourceSecond:)`.
/// Design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §5.5
/// (kernel, accumulation, release formula, readout, `.estimate`) and §5.8.
///
/// Tests assert PHYSICS where the design asks for it: a commit is applied
/// through the store's own transform (`PitchEditSet.applyingNoteShapes`) and the
/// played line is REBUILT through `PitchPlayedLine.make`, the render's own curve
/// over the render's own contour, so "the line lands where the pointer was" is
/// measured, not restated. Each named plant was applied to the source, seen
/// red and reverted (logs: `scratchpad/w6/C5b3a4a/plants/`).
///
/// ⚠️ NOT a `@MainActor` suite — `MainActorOccupancySiteTests` caps those, and
/// nothing here touches an actor: the brush is pure values.
@Suite("C5b-4a — the pitch brush and the played pitch at any second, headless")
struct PitchShapeBrushTests {

    // MARK: - The fixture: two sung notes and a hole, through the render's own seam

    static let frameRate = 62.5
    static let period = 1 / 62.5
    /// 12 pt at 240 pt per source second: a 50 ms radius.
    static let zoom = 240.0

    static let idA = UUID(uuidString: "C5B4A000-0000-4000-8000-00000000000A")!
    static let idB = UUID(uuidString: "C5B4A000-0000-4000-8000-00000000000B")!
    static let idS = UUID(uuidString: "C5B4A000-0000-4000-8000-00000000005A")!

    static func midi(_ hz: Double) -> Double { 69 + 12 * log2(hz / 440) }

    /// Frames at 62.5 fps over 0.9…2.5 s: voiced at 220 Hz (MIDI 57) on
    /// [1.0, 1.6), UNVOICED on [1.6, 1.8) — a hole — and voiced at 246.94 Hz
    /// (MIDI 59) on [1.8, 2.4).
    static func frames() -> [ClipPitchFrame] {
        let count = Int(((2.5 - 0.9) / period).rounded(.down))
        return (0..<count).map { i in
            let t = 0.9 + Double(i) * period
            let hz: Double? = (1.0..<1.6).contains(t) ? 220
                : (1.8..<2.4).contains(t) ? 440 * pow(2, (59.0 - 69) / 12) : nil
            return ClipPitchFrame(timeSeconds: t, frequencyHz: hz, confidence: hz == nil ? 0.1 : 0.97,
                                  levelDbfs: hz == nil ? -70 : -16,
                                  absence: hz == nil ? .belowConfidence : nil)
        }
    }

    static let contour: PitchRenderContour = {
        let all = frames()
        return .detected(PitchDetectionResult(
            frames: all, frameCount: all.count,
            voicedFrameCount: all.filter { $0.frequencyHz != nil }.count,
            voicedFraction: 0.75, frameRateHz: frameRate, analysisSampleRateHz: 16_000,
            sourceSampleRateHz: 48_000, windowStartSeconds: 0.9,
            windowDurationSeconds: Double(all.count) * period,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46, maxFrequencyHz: 2_093))
    }()

    /// A (1.0-1.6) and B (1.8-2.4), sung; S (1.62-1.78), a SOUND in the hole.
    /// A NEW (natural-tuning) set, so a commit changes the drawing and nothing
    /// else whichever way D4-1's hand-edit switch stands.
    static func table(shapeA: [Int16] = [], noteA: (Double, Double) = (1.0, 1.6),
                      withB: Bool = true, withSound: Bool = true) -> PitchEditSet {
        var notes = [NoteSegment(id: idA, startSeconds: noteA.0, endSeconds: noteA.1, detectedHz: 220,
                                 detectedConfidence: 0.97,
                                 shapeStartIndex: shapeA.isEmpty ? 0
                                     : NoteShapeSamples.gridIndex(atOrAfter: noteA.0),
                                 shapeTenthsOfCents: shapeA)]
        if withSound {
            notes.append(NoteSegment(id: idS, startSeconds: 1.62, endSeconds: 1.78, detectedHz: 300,
                                     detectedConfidence: 0.3, origin: .unpitched))
        }
        if withB {
            notes.append(NoteSegment(id: idB, startSeconds: 1.8, endSeconds: 2.4,
                                     detectedHz: 440 * pow(2, (59.0 - 69) / 12), detectedConfidence: 0.97))
        }
        return PitchEditSet(segments: notes).upgradedToNaturalTuning()
    }

    /// The line the render plays for `set`.
    static func line(_ set: PitchEditSet, contour: PitchRenderContour? = contour) -> PitchPlayedLine {
        PitchPlayedLine.make(contour: contour, fallback: nil, editSet: set,
                             clipPitchShiftSemitones: 0, sourceWindow: 0..<100)
    }

    /// Start a stroke on note A (or `note`) at `(seconds, midi)`, or fail the test.
    static func begin(_ set: PitchEditSet, on note: UUID = idA, at seconds: Double, midi: Double,
                      zoom: Double = zoom) throws -> PitchShapeStroke {
        let start = PitchShapeStroke.begin(pressedNoteID: note, atSourceSecond: seconds, midi: midi,
                                           table: set, prestrokePlayedLine: line(set),
                                           pointsPerSourceSecond: zoom)
        return try #require(start.stroke, "the brush refused: \(start.refusal ?? "?")")
    }

    /// The set a release stores: the commit through the STORE's transform.
    static func committed(_ stroke: PitchShapeStroke, onto set: PitchEditSet) throws -> PitchEditSet {
        let shapes = stroke.commit()
        guard !shapes.isEmpty else { return set }
        return try set.applyingNoteShapes(shapes, clipId: UUID())
    }

    // MARK: - `PitchPlayedLine.playedMidi(atSourceSecond:)` (DAWCore)

    @Test("playedMidi: at every frame centre it IS the drawn point's playedMidi, bit for bit")
    func playedMidiMatchesEveryDrawnPoint() {
        let line = Self.line(Self.table(shapeA: (0..<60).map { Int16(($0 % 7) * 90) }))
        var checked = 0
        for run in line.runs {
            for point in run {
                #expect(line.playedMidi(atSourceSecond: point.sourceSeconds)?.bitPattern
                            == point.playedMidi.bitPattern, "at \(point.sourceSeconds) s")
                checked += 1
            }
        }
        #expect(checked > 60, "precondition: the line has points to check")
    }

    /// ⭐ THE SUNG HALF IS INTERPOLATED, THE CURVE EVALUATED: between two frame
    /// centres a drawn shape's 10 ms structure is read, not smeared.
    @Test("playedMidi: between frame centres it reads the curve's own 10 ms structure, not a smear of the points")
    func playedMidiReadsTheCurveBetweenCentres() throws {
        // A zig-zag on the 10 ms grid: finer than the 16 ms frames.
        let set = Self.table(shapeA: (0..<60).map { $0 % 2 == 0 ? 0 : 800 })
        let line = Self.line(set)
        let run = try #require(line.runs.first)
        var smeared = 0
        for (a, b) in zip(run, run.dropFirst()) where a.sourceSeconds > 1.1 && b.sourceSeconds < 1.5 {
            let t = (a.sourceSeconds + b.sourceSeconds) / 2
            let played = try #require(line.playedMidi(atSourceSecond: t))
            #expect(abs(played - (57 + line.curve.semitones(atSourceSecond: t))) < 1e-9,
                    "at \(t) s the sung half is not 57 plus the curve")
            let smear = (a.playedMidi + b.playedMidi) / 2
            if abs(played - smear) > 0.05 { smeared += 1 }
        }
        #expect(smeared > 5, "positive control: interpolating playedMidi would have smeared the drawing")
    }

    /// ⛔ NIL ACROSS HOLES: the line exists from a run's first point to its
    /// last, and is never bridged over an unvoiced gap.
    @Test("playedMidi: nil across a hole, before the first run, after the last, and for NaN — never a bridge")
    func playedMidiIsNilAcrossHoles() throws {
        let line = Self.line(Self.table())
        try #require(line.runs.count == 2, "precondition: two voiced runs around the hole")
        let lastOfFirst = try #require(line.runs[0].last).sourceSeconds
        let firstOfSecond = try #require(line.runs[1].first).sourceSeconds
        #expect(line.playedMidi(atSourceSecond: lastOfFirst) != nil)
        #expect(line.playedMidi(atSourceSecond: firstOfSecond) != nil)
        for t in [lastOfFirst + 0.001, 1.65, 1.7, 1.75, firstOfSecond - 0.001] {
            #expect(line.playedMidi(atSourceSecond: t) == nil, "at \(t) s, in the hole, the line was bridged")
        }
        #expect(line.playedMidi(atSourceSecond: 0.5) == nil)
        #expect(line.playedMidi(atSourceSecond: 3.0) == nil)
        #expect(line.playedMidi(atSourceSecond: .nan) == nil)
        #expect(Self.line(Self.table(), contour: nil).playedMidi(atSourceSecond: 1.3) == nil,
                "a line with no points has no pitch anywhere")
    }

    /// U-B's fallback for a SOUND: its borrowed anchor plus the curve. Not on
    /// the brush's path (sounds are gaps under C5b-3a's refuse ruling).
    @Test("playedMidi(on:): a SOUND in a hole falls back to its centre plus the curve; a sung note in a hole does not")
    func playedMidiFallsBackToASoundsCentre() throws {
        let set = Self.table()
        let line = Self.line(set)
        let sound = set.segments[1]
        try #require(sound.origin == .unpitched, "precondition: S is a sound")
        let fallback = try #require(line.playedMidi(atSourceSecond: 1.7, on: sound))
        #expect(abs(fallback - (Self.midi(300) + line.curve.semitones(atSourceSecond: 1.7))) < 1e-12)
        // Outside the sound: nil; a cleared sound: nil (it plays silence).
        #expect(line.playedMidi(atSourceSecond: 1.9, on: sound) == nil)
        var cleared = sound
        cleared.isCleared = true
        #expect(line.playedMidi(atSourceSecond: 1.7, on: cleared) == nil)
        // A SUNG note stretched over the hole: the hole rule holds.
        let long = NoteSegment(id: Self.idA, startSeconds: 1.0, endSeconds: 2.4, detectedHz: 220,
                               detectedConfidence: 0.97)
        #expect(line.playedMidi(atSourceSecond: 1.7, on: long) == nil)
        // And where the line HAS a pitch, the note changes nothing.
        #expect(line.playedMidi(atSourceSecond: 1.3, on: set.segments[0])
                == line.playedMidi(atSourceSecond: 1.3))
    }

    // MARK: - The kernel

    /// The raised cosine (§5.5): 1 at the centre, 0 with ZERO SLOPE at the
    /// edge. PLANT: a linear kernel (`1 − |Δ|/R`) — its edge slope is `1/R`.
    @Test("kernel: 1 at the centre, ½ at half the radius, 0 at and past the edge WITH ZERO SLOPE, symmetric")
    func kernelIsARaisedCosine() {
        let r = 0.05
        func w(_ d: Double) -> Double { PitchShapeBrush.weight(distanceSeconds: d, radiusSeconds: r) }
        #expect(w(0) == 1)
        #expect(abs(w(r / 2) - 0.5) < 1e-12)
        #expect(abs(w(r / 4) - 0.5 * (1 + cos(Double.pi / 4))) < 1e-12)
        #expect(w(r) == 0 && w(r * 1.5) == 0 && w(.infinity) == 0 && w(.nan) == 0)
        #expect(w(-0.013) == w(0.013), "the kernel is not symmetric")
        // ZERO SLOPE at the edge (and at the centre): the brush has no corner.
        let h = r * 1e-4
        let edgeSlope = (w(r - h) - w(r)) / h
        #expect(edgeSlope * r < 1e-2, "the kernel meets zero with slope \(edgeSlope * r)/R: a corner")
        let centreSlope = (w(0) - w(h)) / h
        #expect(centreSlope * r < 1e-2)
        // The radius: 12 pt at the zoom of the press, in SOURCE seconds.
        #expect(PitchShapeBrush.radiusPoints == 12)
        #expect(abs(PitchShapeBrush.radiusSeconds(pointsPerSourceSecond: 240) - 0.05) < 1e-15)
        #expect(PitchShapeBrush.radiusSeconds(pointsPerSourceSecond: 0) == 0.01)
        #expect(PitchShapeBrush.radiusSeconds(pointsPerSourceSecond: .nan) == 0.01)
    }

    // MARK: - The release formula

    /// ⭐ §5.5's formula against HAND-COMPUTED numbers: A carries +20 c drawn
    /// everywhere (so `shape_i` is not 0 and `played_i` is not the sung line),
    /// and one press at (1.30 s, MIDI 57.7) with a 50 ms radius. Then
    /// `shape_i = 200 + w(d) · (57.7 − 57.2) · 1000` tenths, with
    /// w(0) = 1, w(10 ms) = 0.904508, w(20) = 0.654508, w(30) = 0.345492,
    /// w(40) = 0.095492 → 700, 652.25, 527.25, 372.75, 247.75.
    /// PLANT: the LIVE line instead of the pre-stroke one — the delta then
    /// shrinks by the weight it already applied.
    @Test("release: shape_i += w_i · (target − PRE-stroke played), quantised — against a hand-computed fixture")
    func releaseFormulaMatchesHandComputedNumbers() throws {
        let set = Self.table(shapeA: [Int16](repeating: 200, count: 60))
        let stroke = try Self.begin(set, at: 1.30, midi: 57.7)
        let shapes = stroke.commit()
        #expect(Set(shapes.keys) == [Self.idA])
        let a = try #require(shapes[Self.idA])
        #expect(a.startIndex == 100 && a.tenthsOfCents.count == 60, "not the note's whole grid span")
        #expect(Array(a.tenthsOfCents[26...34]) == [248, 373, 527, 652, 700, 652, 527, 373, 248])
        #expect(a.tenthsOfCents[..<26].allSatisfy { $0 == 200 } && a.tenthsOfCents[35...].allSatisfy { $0 == 200 },
                "a sample beyond the radius moved")
        #expect(stroke.maxExcursionCents == 50)
        #expect(stroke.readout == "Drawing · moves the line by up to 50 cents")
    }

    /// ⭐ THE LINE LANDS WHERE THE POINTER WAS: a stroke along A at MIDI 57.5,
    /// committed through the store's transform, re-played through the
    /// render's own `make`, sits at 57.5 wherever the brush's full weight fell.
    @Test("release: the re-played line LANDS on the pointer's pitch under the stroke, and nothing moves outside it")
    func releaseLandsTheLineOnThePointer() throws {
        let set = Self.table(shapeA: [Int16](repeating: 150, count: 60))
        var stroke = try Self.begin(set, at: 1.15, midi: 57.5)
        stroke.move(toSourceSecond: 1.30, midi: 57.5)
        stroke.move(toSourceSecond: 1.45, midi: 57.5)
        #expect(stroke.prestrokePlayedLine == Self.line(set), "the stroke did not hold the pre-stroke line")
        let after = Self.line(try Self.committed(stroke, onto: set))
        let before = Self.line(set)
        var landed = 0
        for index in 115...145 {
            let t = NoteShapeSamples.seconds(atGridIndex: index)
            let played = try #require(after.playedMidi(atSourceSecond: t))
            #expect(abs(played - 57.5) < 0.001, "at \(t) s the line sits at \(played), not the pointer's 57.5")
            landed += 1
        }
        #expect(landed == 31)
        // Outside the stroke and its radius, the line did not move.
        for t in [1.05, 1.08, 1.53, 1.57, 1.9, 2.2] {
            #expect(after.playedMidi(atSourceSecond: t) == before.playedMidi(atSourceSecond: t),
                    "at \(t) s, outside the stroke, the line moved")
        }
    }

    // MARK: - Accumulation

    /// ⭐ MAX WEIGHT, NEVER A SUM: going back and forth over the same place at
    /// the same pitch is exactly one pass; going back at a NEW pitch re-aims
    /// it (the latest wins a tie) and never adds the two.
    /// PLANT: accumulate by SUM — three passes push three times as far.
    @Test("accumulation: overdrawing is idempotent and a second pass RE-AIMS, never double-applies")
    func maxWeightAccumulationAndReAim() throws {
        let set = Self.table()
        var once = try Self.begin(set, at: 1.2, midi: 57.5)
        once.move(toSourceSecond: 1.4, midi: 57.5)
        var thrice = try Self.begin(set, at: 1.2, midi: 57.5)
        thrice.move(toSourceSecond: 1.4, midi: 57.5)
        thrice.move(toSourceSecond: 1.2, midi: 57.5)
        thrice.move(toSourceSecond: 1.4, midi: 57.5)
        #expect(thrice.commit() == once.commit(), "going back over a place applied the stroke again")
        #expect(thrice.samples.values.allSatisfy { $0.weight <= 1 }, "a weight grew past 1")
        // RE-AIM: back over the same place at a new pitch.
        var reaimed = try Self.begin(set, at: 1.2, midi: 57.5)
        reaimed.move(toSourceSecond: 1.4, midi: 57.5)
        reaimed.move(toSourceSecond: 1.2, midi: 57.9)
        let after = Self.line(try Self.committed(reaimed, onto: set))
        for index in 125...135 {
            let t = NoteShapeSamples.seconds(atGridIndex: index)
            let played = try #require(after.playedMidi(atSourceSecond: t))
            // The second pass swept 57.5 → 57.9 from 1.4 back to 1.2.
            let expected = 57.5 + 0.4 * (1.4 - t) / 0.2
            #expect(abs(played - expected) < 0.001, "at \(t) s: \(played), not the re-aimed \(expected)")
        }
    }

    /// Rule 2: the SWEPT path. Zoomed right in, the radius (2 ms) is under
    /// half a grid step, so a brush dabbed every 10 ms from an off-grid start
    /// would comb the line. One fast tick must still write every sample.
    @Test("accumulation: one fast tick at a 2 ms radius leaves NO gap — every grid sample swept gets full weight")
    func aFastDragLeavesNoGaps() throws {
        let set = Self.table()
        var stroke = try Self.begin(set, at: 1.1037, midi: 57.5, zoom: 12 / 0.002)
        #expect(abs(stroke.radiusSeconds - 0.002) < 1e-15)
        stroke.move(toSourceSecond: 1.5037, midi: 57.5)
        for index in 111...150 {
            #expect(stroke.samples[index]?.weight == 1, "grid sample \(index) was skipped by a fast drag")
        }
        let a = try #require(stroke.commit()[Self.idA])
        #expect(a.tenthsOfCents[11...50].allSatisfy { $0 == 500 }, "the fast drag left gaps in the drawing")
    }

    /// "Pull tops or bottoms up or down", in the user's words: a press that
    /// moves straight up is ONE place with a moving target; the release
    /// uses where the pointer ENDED, not where it passed.
    @Test("pull a peak: press and move straight up is one point with a moving target — the LAST pitch wins")
    func pullingAPeakIsOnePointWithAMovingTarget() throws {
        let set = Self.table()
        var stroke = try Self.begin(set, at: 1.3, midi: 57.0)
        stroke.move(toSourceSecond: 1.3, midi: 57.4)
        stroke.move(toSourceSecond: 1.3, midi: 57.8)
        #expect(stroke.samples.keys.allSatisfy { abs(NoteShapeSamples.seconds(atGridIndex: $0) - 1.3) < 0.05 },
                "a vertical pull touched a sample outside the radius")
        let a = try #require(stroke.commit()[Self.idA])
        #expect(a.tenthsOfCents[30] == 800, "the peak did not go to the LAST pitch (+80 c)")
        #expect(a.tenthsOfCents[29] == 724 && a.tenthsOfCents[31] == 724)   // 800 · w(10 ms)
        #expect(stroke.readout == "Drawing · moves the line by up to 80 cents")
    }

    // MARK: - Where it writes

    /// Rule 4: a stroke crosses gaps, holes and sounds and writes only where a
    /// SUNG note has a line. PLANT: `playedMidi` bridging the hole — the brush
    /// then writes inside it.
    @Test("gaps: a stroke across a hole, a sound and a gap writes only where a sung note has a line")
    func aStrokeAcrossAGapWritesNothingInIt() throws {
        // Two notes and a sound in the hole between them.
        let set = Self.table()
        var across = try Self.begin(set, at: 1.4, midi: 58)
        across.move(toSourceSecond: 2.0, midi: 58)
        let shapes = across.commit()
        #expect(Set(shapes.keys) == [Self.idA, Self.idB], "the stroke wrote into a sound or missed a note")
        // The store takes the commit as it is: no sound, nothing outside a note.
        #expect(throws: Never.self) { _ = try set.applyingNoteShapes(shapes, clipId: UUID()) }
        // ONE note stretched across the hole: only the samples where the line
        // has a pitch are written; the hole keeps its zeros.
        let long = Self.table(noteA: (1.0, 2.4), withB: false, withSound: false)
        let line = Self.line(long)
        var stroke = try Self.begin(long, at: 1.4, midi: 58)
        stroke.move(toSourceSecond: 2.0, midi: 58)
        let a = try #require(stroke.commit()[Self.idA])
        var hole = 0, drawn = 0
        for index in 140...200 {
            let value = a.tenthsOfCents[index - a.startIndex]
            if line.playedMidi(atSourceSecond: NoteShapeSamples.seconds(atGridIndex: index)) == nil {
                hole += 1
                #expect(value == 0, "grid sample \(index), in the hole, was written (\(value))")
            } else {
                drawn += 1
                #expect(value != 0, "grid sample \(index), on the line, was not written")
            }
        }
        #expect(hole >= 15 && drawn >= 35, "precondition: the stroke covers the hole and the line (\(hole), \(drawn))")
    }

    @Test("a stroke that draws exactly on the line commits NOTHING — an empty map is 'nothing to commit'")
    func aStrokeOnTheLineCommitsNothing() throws {
        let set = Self.table()
        var stroke = try Self.begin(set, at: 1.2, midi: 57)
        stroke.move(toSourceSecond: 1.4, midi: 57)
        #expect(stroke.commit().isEmpty)
        #expect(stroke.readout == "Drawing · moves the line by up to 0 cents")
    }

    // MARK: - When it may draw, and the words

    @Test("disabled while the line is an ESTIMATE; refused on a sound and off the table — each with its sentence")
    func theBrushRefusesInWords() {
        let set = Self.table()
        let estimate = Self.line(set, contour: nil)
        #expect(estimate.basis.key == "estimate", "precondition: no contour yet is an estimate")
        let start = PitchShapeStroke.begin(pressedNoteID: Self.idA, atSourceSecond: 1.3, midi: 58, table: set,
                                           prestrokePlayedLine: estimate, pointsPerSourceSecond: Self.zoom)
        #expect(start == .refused("Drawing needs the app's analysis of this recording. One moment."))
        #expect(PitchShapeBrush.refusal(basis: estimate.basis) == PitchShapeBrush.estimateCaption)
        #expect(PitchShapeBrush.refusal(basis: .render) == nil)
        let onSound = PitchShapeStroke.begin(pressedNoteID: Self.idS, atSourceSecond: 1.7, midi: 60, table: set,
                                             prestrokePlayedLine: Self.line(set), pointsPerSourceSecond: Self.zoom)
        #expect(onSound.refusal == PitchShapeBrush.soundCaption)
        let nowhere = PitchShapeStroke.begin(pressedNoteID: UUID(), atSourceSecond: 1.3, midi: 58, table: set,
                                             prestrokePlayedLine: Self.line(set), pointsPerSourceSecond: Self.zoom)
        #expect(nowhere.refusal == PitchShapeBrush.startOnANoteCaption)
        // POSITIVE CONTROL: the same press on the render's line draws.
        let drawing = PitchShapeStroke.begin(pressedNoteID: Self.idA, atSourceSecond: 1.3, midi: 58, table: set,
                                             prestrokePlayedLine: Self.line(set), pointsPerSourceSecond: Self.zoom)
        #expect(drawing.stroke != nil)
    }

    @Test("the words, verbatim: the readout rounded to 5 c, the estimate caption, the sound caption and the help")
    func theWordsVerbatim() {
        #expect(PitchShapeBrush.readout(maxExcursionCents: 33) == "Drawing · moves the line by up to 35 cents")
        #expect(PitchShapeBrush.readout(maxExcursionCents: 32.4) == "Drawing · moves the line by up to 30 cents")
        #expect(PitchShapeBrush.readout(maxExcursionCents: -47) == "Drawing · moves the line by up to 45 cents")
        #expect(PitchShapeBrush.readout(maxExcursionCents: .nan) == "Drawing · moves the line by up to 0 cents")
        #expect(PitchShapeBrush.estimateCaption
                == "Drawing needs the app's analysis of this recording. One moment.")
        #expect(PitchShapeBrush.soundCaption
                == "This is a breath or a consonant, not a sung note — it has no pitch line to draw.")
        #expect(PitchShapeBrush.help == "Drag along a note's line to redraw it. Press and drag up or down to "
                + "pull a peak. Let go to hear it.")
    }

    /// The draft C5b-4b draws is "the notes' shapes after `commit`, applied to
    /// copies": per note, `NoteShapeSamples.applied(to:)`, then the set's
    /// `afterHandEdit(from: set)` (D4-1's hook WITH its no-op rule, W7-D41) —
    /// exactly what the store's transform writes, so the live line is the
    /// stored line.
    ///
    /// ⚠️ The oracle was the BARE `afterHandEdit()` until W7-D41 moved the
    /// no-op rule into `afterHandEdit(from:)`: for a write that changes no
    /// note on an OLD vocal the store returns the set unchanged, and the bare
    /// hook upgrades it. The second leg is that case, with the bare oracle
    /// shown to DISAGREE (so this test can tell the two apart).
    @Test("the draft: commit() applied per note to copies, then afterHandEdit(from:), IS the set the store's transform writes — a no-op write on an OLD vocal included")
    func theDraftIsTheStoredSet() throws {
        let set = Self.table(shapeA: [Int16](repeating: 90, count: 60))
        var stroke = try Self.begin(set, at: 1.2, midi: 57.6)
        stroke.move(toSourceSecond: 2.1, midi: 59.3)
        let shapes = stroke.commit()
        var copies = set.segments
        for index in copies.indices {
            if let write = shapes[copies[index].id] { copies[index] = write.applied(to: copies[index]) }
        }
        #expect(set.withSegments(copies).afterHandEdit(from: set)
                == (try set.applyingNoteShapes(shapes, clipId: UUID())))

        // An OLD vocal (no voice amount, A drawn: `predatesNaturalTuning`) and a
        // write that changes NO note — A's own drawing, written again. A stroke
        // cannot produce it (`commit()` leaves out every note it would not
        // change), but the store's transform must still leave the set as it
        // was, and the draft rule must say so too.
        let old = PitchEditSet(segments: set.segments.map {
            $0.id == Self.idA ? NoteShapeSamples(startIndex: NoteShapeSamples.gridIndex(atOrAfter: 1.0),
                                                 tenthsOfCents: [Int16](repeating: 90, count: 60)).applied(to: $0)
                : $0
        })
        #expect(old.predatesNaturalTuning, "the second leg must run on an OLD vocal")
        let same = [Self.idA: NoteShapeSamples(storedIn: old.segments.first { $0.id == Self.idA }!)]
        let stored = try old.applyingNoteShapes(same, clipId: UUID())
        #expect(stored == old, "a write that changed no note upgraded the vocal")
        let unchanged = old.segments.map { note in same[note.id].map { $0.applied(to: note) } ?? note }
        #expect(old.withSegments(unchanged).afterHandEdit(from: old) == stored)
        // The bare hook — the oracle before W7-D41 — disagrees here.
        #expect(old.withSegments(unchanged).afterHandEdit() != stored,
                "the bare oracle agrees on a no-op write, so this leg cannot tell the two rules apart")
        // And C5b-4b's draft case is the store's transform on this write too.
        #expect(PitchEditorDraftEdit.draftSet(old, applying: [(segmentID: Self.idA, edit: .shape(same[Self.idA]!))],
                                              clipID: UUID()) == stored)
    }

    // MARK: - C5b-4b — the draft's case and the write's read-back

    /// `PitchEditorDraftEdit.shape` runs the transform `setClipNoteShapes`
    /// runs — ONE call for every note a stroke drew on — and a write the store
    /// would refuse leaves the table as it was (what the store holds after a
    /// refused commit: all or nothing).
    @Test("C5b-4b — the draft's .shape case IS the store's transform: one call for every note, all or nothing")
    func theDraftCaseRunsTheStoresTransform() throws {
        let set = Self.table()
        var stroke = try Self.begin(set, at: 1.2, midi: 57.6)
        stroke.move(toSourceSecond: 2.1, midi: 59.3)
        let shapes = stroke.commit()
        #expect(Set(shapes.keys) == [Self.idA, Self.idB], "the stroke must draw on both sung notes")
        let clip = UUID()
        let edits = shapes.map { (segmentID: $0.key, edit: PitchEditorDraftEdit.shape($0.value)) }
        let drafted = PitchEditorDraftEdit.draftSet(set, applying: edits, clipID: clip)
        #expect(drafted == (try set.applyingNoteShapes(shapes, clipId: clip)))
        #expect(drafted != set, "the draft changed nothing, so the equality above proves nothing")
        // A drawing on the SOUND in the hole: the store refuses the whole call.
        let onSound = edits + [(segmentID: Self.idS, edit: PitchEditorDraftEdit.shape(
            NoteShapeSamples(startIndex: NoteShapeSamples.gridIndex(atOrAfter: 1.62), tenthsOfCents: [100])))]
        #expect(PitchEditorDraftEdit.draftSet(set, applying: onSound, clipID: clip) == set)
    }

    /// The app funnel's read-back (`PitchEditorShapeWrite.took`) is TRUE only
    /// when every named note stores exactly the normalised write.
    @Test("C5b-4b — the shape write's read-back: true for the stored write, false for a table without it, a different drawing, an empty map or a missing note")
    func theShapeWriteReadsBack() throws {
        let set = Self.table()
        var stroke = try Self.begin(set, at: 1.2, midi: 57.6)
        stroke.move(toSourceSecond: 1.5, midi: 58.0)
        let shapes = stroke.commit()
        #expect(!shapes.isEmpty)
        func clip(_ edits: PitchEditSet) -> Clip {
            Clip(name: "vox", startBeat: 0, lengthBeats: 8,
                 audioFileURL: URL(fileURLWithPath: "/tmp/c5b4b-readback.wav"), pitchEdits: edits)
        }
        let stored = try set.applyingNoteShapes(shapes, clipId: UUID())
        #expect(PitchEditorShapeWrite.took(clip: clip(stored), shapes: shapes))
        // The setter "accepted" and the table does not hold it.
        #expect(!PitchEditorShapeWrite.took(clip: clip(set), shapes: shapes))
        // A clear, read back against a note that still carries its drawing.
        #expect(!PitchEditorShapeWrite.took(clip: clip(stored), shapes: [Self.idA: .clear]))
        // …and against one that does not: a clear that took.
        #expect(PitchEditorShapeWrite.took(clip: clip(set), shapes: [Self.idA: .clear]))
        // An empty map, and a note the clip does not carry.
        #expect(!PitchEditorShapeWrite.took(clip: clip(stored), shapes: [:]))
        #expect(!PitchEditorShapeWrite.took(clip: clip(stored), shapes: [UUID(): shapes.values.first!]))
    }
}
