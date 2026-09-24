import CoreGraphics
import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m23-ap Phase 2, item p2-a — the gate for `PitchEditorModel`
/// (design `docs/design/2026-09-22-pitch-editor-ui.md` §12.1).
///
/// Three things in here are load-bearing and are marked ⭐ where they sit:
///
///  1. **A HAND-COMPUTED x, NOT A ROUND TRIP.** A round trip is tautological
///     against a shared error: drop `stretchRatio` from BOTH directions and
///     `sourceSecond(forX: x(forSourceSecond: s)) == s` still passes. The
///     hand-computed value on a clip that is trimmed AND offset AND stretched
///     AND crosses a tempo change is what discriminates — every one of the
///     three likely defects lands on a DIFFERENT wrong number, named inline.
///  2. **"NOTHING RAN" vs "RAN AND FOUND NOTHING".** A tool that never looked
///     and a tool that looked and saw nothing produce the same output; this
///     surface must not. Asserted on the STRINGS by value, with a positive
///     control proving the comparison can report equality.
///  3. **THE HOLE, WITH ITS POSITIVE CONTROL.** The same contour with the hole
///     FILLED must yield one polyline. An absence that confirms the hypothesis
///     is the weakest evidence there is until the control has run.
@MainActor
@Suite("PitchEditorModel")
struct PitchEditorModelTests {

    // MARK: - Fixtures

    /// SwiftF0's rate. Taken as a fixture constant, never as a claim about the
    /// backend: the model reads `PitchDetectionResult.frameRateHz`, and one of
    /// the tests below proves it echoes whatever it was handed.
    private static let frameRate: Double = 62.5
    private static var framePeriod: Double { 1 / frameRate }

    private func voiced(count: Int, from start: Double, hz: Double,
                        confidence: Double = 0.98) -> [ClipPitchFrame] {
        (0..<count).map { i in
            ClipPitchFrame(timeSeconds: start + Double(i) * Self.framePeriod,
                           frequencyHz: hz, confidence: confidence,
                           levelDbfs: -18, absence: nil)
        }
    }

    private func unvoiced(count: Int, from start: Double,
                          absence: PitchDetectionAbsence = .belowConfidence) -> [ClipPitchFrame] {
        (0..<count).map { i in
            ClipPitchFrame(timeSeconds: start + Double(i) * Self.framePeriod,
                           frequencyHz: nil, confidence: 0.2,
                           levelDbfs: -58, absence: absence)
        }
    }

    private func detection(_ frames: [ClipPitchFrame],
                           frameRateHz: Double = PitchEditorModelTests.frameRate,
                           clipWindowSeconds: Double = 10,
                           stretchRatio: Double = 1) -> ClipPitchDetection {
        let voicedCount = frames.filter { $0.frequencyHz != nil }.count
        let result = PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voicedCount,
            voicedFraction: frames.isEmpty ? 0 : Double(voicedCount) / Double(frames.count),
            frameRateHz: frameRateHz, analysisSampleRateHz: 16_000,
            sourceSampleRateHz: 48_000,
            windowStartSeconds: frames.first?.timeSeconds ?? 0,
            windowDurationSeconds: Double(frames.count) * (1 / frameRateHz),
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46, maxFrequencyHz: 2_093)
        return ClipPitchDetection(pitch: result,
                                  clipWindowDurationSeconds: clipWindowSeconds,
                                  stretchRatio: stretchRatio, pitchShiftSemitones: 0)
    }

    /// 120 BPM until beat 10, then 60 BPM. Barline-free arithmetic on purpose:
    /// every hand-computed number below is derivable from these two numbers.
    private func steppedTempo() -> TempoMap {
        try! TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 10, bpm: 60)])
    }

    /// ⛔ **THE NON-PRISTINE CLIP** every geometry assertion runs against:
    /// trimmed into the source (`startOffsetSeconds` 0.25), placed late on the
    /// timeline (`startBeat` 8), time-stretched (`stretchRatio` 2) and spanning
    /// a tempo change (beats 8…14 cross the 120→60 step at beat 10).
    ///
    /// Output span = 2 beats @120 (1.0 s) + 4 beats @60 (4.0 s) = **5.0 s**.
    /// Source window = 5.0 / 2 = **2.5 s**, so the clip reads source seconds
    /// **[0.25, 2.75)**.
    private func awkwardClip() -> Clip {
        Clip(name: "vox", startBeat: 8, lengthBeats: 6,
             audioFileURL: URL(fileURLWithPath: "/tmp/does-not-need-to-exist.wav"),
             startOffsetSeconds: 0.25, stretchRatio: 2)
    }

    private func awkwardGeometry(pixelsPerBeat: CGFloat = 40) -> PitchEditorGeometry {
        PitchEditorGeometry(clip: awkwardClip(), tempoMap: steppedTempo(),
                            pixelsPerBeat: pixelsPerBeat)
    }

    private func close(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    private func close(_ a: CGFloat, _ b: CGFloat, _ tolerance: CGFloat = 1e-9) -> Bool {
        abs(a - b) <= tolerance
    }

    // MARK: - Geometry: the conversion that corrupts data if it is wrong

    /// ⭐ **THE LOAD-BEARING ASSERTION OF THIS ITEM.**
    ///
    /// Hand-computed, from the fixture's own two tempi and nothing else. Each
    /// of the three likely defects lands somewhere different, which is what
    /// makes this a discriminating test rather than a restatement of the code:
    ///
    ///  * source second 1.25 is 1.0 s into the clip's source window;
    ///  * at `stretchRatio` 2 that is 2.0 s of OUTPUT time;
    ///  * 2.0 s from beat 8 is: 1.0 s to reach beat 10 (120 BPM), then 1.0 s =
    ///    1 beat at 60 BPM → **beat 11**;
    ///  * beat 11 is 3 beats into the clip → **x = 120** at 40 px/beat.
    ///
    /// Drop the ratio → 80. Drop `startOffsetSeconds` → 140. Treat the tempo
    /// map as a constant 120 → 160.
    @Test("source-second → x is hand-computable on a trimmed, offset, stretched clip across a tempo change")
    func xIsHandComputedOnATrimmedOffsetStretchedClip() {
        let geometry = awkwardGeometry()

        // A `Comment` takes ONE literal, so each note is built first and
        // interpolated (the `EditorSurfaceOwnershipSiteTests` idiom).
        let windowNote = "the clip reads 2.5 s of source (5.0 s of output at ratio 2), got "
            + "\(geometry.sourceWindowSeconds)"
        #expect(close(geometry.sourceWindowSeconds, 2.5), "\(windowNote)")
        #expect(close(geometry.outputSpanSeconds, 5.0))

        // The window's head sits at the pane's left edge.
        #expect(close(geometry.x(forSourceSecond: 0.25), 0))
        // 0.5 s of source = 1.0 s of output = exactly the tempo change at beat 10.
        let stepNote = "source 0.75 s should land on beat 10 (x = 80); got "
            + "\(geometry.x(forSourceSecond: 0.75)) — 40 means the stretch ratio is "
            + "missing, 100 means the offset is"
        #expect(close(geometry.x(forSourceSecond: 0.75), 80), "\(stepNote)")
        // THE discriminating value.
        let discriminatingNote = "source 1.25 s should land on beat 11 (x = 120); got "
            + "\(geometry.x(forSourceSecond: 1.25)) — 80 means the stretch ratio is "
            + "missing, 140 means startOffsetSeconds is, 160 means the tempo map is being "
            + "read as a constant 120 BPM"
        #expect(close(geometry.x(forSourceSecond: 1.25), 120), "\(discriminatingNote)")
        // The window's tail sits at the pane's right edge.
        #expect(close(geometry.x(forSourceSecond: 2.75), geometry.contentWidth))
        #expect(close(geometry.contentWidth, 240))
    }

    /// The derived ratio is compared against the CLIP'S OWN — the thing it is
    /// derived from must agree with the thing it describes, or the whole
    /// x-axis skews silently.
    @Test("the geometry's derived stretch ratio equals the clip's")
    func derivedRatioMatchesTheClip() {
        let clip = awkwardClip()
        let geometry = PitchEditorGeometry(clip: clip, tempoMap: steppedTempo())
        #expect(close(geometry.stretchRatio, clip.stretchRatio))
        #expect(close(geometry.sourceWindowSeconds,
                      clip.sourceWindowSeconds(tempoMap: steppedTempo())))

        // And the identity case: a pristine clip is ratio 1, whatever the tempo.
        let pristine = Clip(name: "vox", startBeat: 0, lengthBeats: 4,
                            audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        let flat = PitchEditorGeometry(clip: pristine, tempoMap: TempoMap(constantBPM: 120))
        #expect(close(flat.stretchRatio, 1))
        #expect(close(flat.sourceWindowSeconds, 2.0))
    }

    /// A degenerate clip answers a finite, flat axis rather than a NaN — a NaN
    /// poisons every `Path` in the Canvas and the crash is nowhere near here.
    @Test("a zero-length source window never produces a NaN axis")
    func degenerateWindowStaysFinite() {
        let geometry = PitchEditorGeometry(
            sourceWindowStartSeconds: 0, sourceWindowSeconds: 0,
            startBeat: 0, lengthBeats: 0, tempoMap: TempoMap(constantBPM: 120))
        #expect(geometry.stretchRatio == 1)
        #expect(geometry.x(forSourceSecond: 1).isFinite)
        #expect(geometry.sourceSecond(forX: 100).isFinite)
        #expect(geometry.x(forSourceSecond: .nan).isFinite)
        #expect(geometry.y(forMidi: .infinity).isFinite)
    }

    @Test("source-second ↔ x round-trips across the window at every zoom")
    func timeRoundTrips() {
        for ppb in [CGFloat(4), 8, 32, 40, 120, 200] {
            let geometry = awkwardGeometry(pixelsPerBeat: ppb)
            for step in 0...20 {
                let seconds = 0.25 + (2.5 * Double(step) / 20)
                let back = geometry.sourceSecond(forX: geometry.x(forSourceSecond: seconds))
                #expect(close(back, seconds, 1e-9),
                        "round trip at \(ppb) px/beat, \(seconds) s came back \(back)")
            }
        }
    }

    @Test("x grows strictly with source time, including across the tempo change")
    func timeIsMonotonic() {
        let geometry = awkwardGeometry()
        var previous = -CGFloat.infinity
        for step in 0...50 {
            let seconds = 0.25 + (2.5 * Double(step) / 50)
            let x = geometry.x(forSourceSecond: seconds)
            #expect(x > previous, "x went backwards at \(seconds) s")
            previous = x
        }
    }

    // MARK: - Geometry: the pitch axis (§3.3.1 — the divergence from PianoRollModel)

    @Test("midi ↔ y round-trips on NON-INTEGER pitches")
    func pitchRoundTrips() {
        let geometry = PitchEditorGeometry(
            sourceWindowStartSeconds: 0, sourceWindowSeconds: 2, startBeat: 0, lengthBeats: 4,
            tempoMap: TempoMap(constantBPM: 120), midiRange: 55...79, rowHeight: 14)
        for midi in [55.0, 57.5, 61.37, 62.0, 68.999, 79.0] {
            let back = geometry.midi(forY: geometry.y(forMidi: midi))
            #expect(close(back, midi, 1e-9), "\(midi) came back \(back)")
        }
    }

    /// ⭐ The pin for design §3.3.1: an INTEGER pitch axis (`PianoRollModel`'s)
    /// would collapse these two onto one row. A pitch contour is continuous;
    /// quantising it to a semitone before it reaches the screen would draw a
    /// different measurement from the one the detector made.
    @Test("pitches inside one semitone get distinct y — an integer axis would fail this")
    func nonIntegerPitchesAreDistinct() {
        let geometry = PitchEditorGeometry(
            sourceWindowStartSeconds: 0, sourceWindowSeconds: 2, startBeat: 0, lengthBeats: 4,
            tempoMap: TempoMap(constantBPM: 120), midiRange: 55...79, rowHeight: 14)
        let flat = geometry.y(forMidi: 61.0)
        let slightlySharp = geometry.y(forMidi: 61.4)
        #expect(flat != slightlySharp)
        // 0.4 of a semitone is 0.4 of a row.
        #expect(close(flat - slightlySharp, 0.4 * 14, 1e-9))
    }

    @Test("the top and bottom rows are whole rows at the window's edges")
    func rowsFillTheWindow() {
        let geometry = PitchEditorGeometry(
            sourceWindowStartSeconds: 0, sourceWindowSeconds: 2, startBeat: 0, lengthBeats: 4,
            tempoMap: TempoMap(constantBPM: 120), midiRange: 60...72, rowHeight: 14)
        #expect(close(geometry.y(forMidi: 72), 7))                       // centre of the top row
        #expect(close(geometry.rowTopY(forMidi: 72), 0))                 // its top edge
        #expect(close(geometry.contentHeight, 13 * 14))                  // 13 semitone rows
        #expect(close(geometry.y(forMidi: 60), geometry.contentHeight - 7))
        #expect(close(geometry.rowTopY(forMidi: 60) + 14, geometry.contentHeight))
    }

    @Test("the ruler names every key, top down, and marks the accidentals and the Cs")
    func rulerKeys() {
        let geometry = PitchEditorGeometry(
            sourceWindowStartSeconds: 0, sourceWindowSeconds: 2, startBeat: 0, lengthBeats: 4,
            tempoMap: TempoMap(constantBPM: 120), midiRange: 60...72, rowHeight: 14)
        let keys = geometry.rulerKeys
        #expect(keys.count == 13)
        #expect(keys.first?.midi == 72, "the ruler is drawn top down (highest first)")
        #expect(keys.last?.midi == 60)
        // Every key named — §5.6.6, the KeyboardSidebar density decision.
        #expect(keys.allSatisfy({ !$0.name.isEmpty }))
        #expect(keys.last?.name == "C4")
        #expect(keys.first?.name == "C5")
        #expect(keys.first(where: { $0.midi == 61 })?.isBlack == true)
        #expect(keys.first(where: { $0.midi == 62 })?.isBlack == false)
        #expect(keys.filter(\.isOctaveC).map(\.midi) == [72, 60])
    }

    // MARK: - Geometry: blob rects

    @Test("a blob sits on its own row, spans its own seconds, and never collapses to nothing")
    func blobRects() {
        let geometry = PitchEditorGeometry(
            sourceWindowStartSeconds: 0, sourceWindowSeconds: 2, startBeat: 0, lengthBeats: 4,
            tempoMap: TempoMap(constantBPM: 120), midiRange: 55...67, rowHeight: 20)
        // 220 Hz is exactly A3 = midi 57.
        let blob = NoteBlob(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220,
                            medianConfidence: 0.97, frameCount: 32)
        #expect(close(blob.centreMidi, 57, 1e-9))

        let rect = geometry.rect(for: blob)
        #expect(close(rect.minX, geometry.x(forSourceSecond: 0.5)))
        #expect(close(rect.width, geometry.x(forSourceSecond: 1.0) - geometry.x(forSourceSecond: 0.5)))
        #expect(close(rect.height, 20 * PitchEditorGeometry.blobHeightFraction))
        #expect(close(rect.midY, geometry.y(forMidi: 57)))

        // Zoomed all the way out, the note is far under a pixel wide. It is
        // still DRAWN — an invisible detected note is a note the surface
        // silently failed to mention.
        var tiny = geometry
        tiny.pixelsPerBeat = 0.01
        let tinyRect = tiny.rect(for: blob)
        #expect(close(tinyRect.width, PitchEditorGeometry.minimumVisibleBlobWidth))
        // ⛔ And the DATA is untouched: the floor widens a RECT, never a note.
        #expect(blob.startSeconds == 0.5)
        #expect(blob.endSeconds == 1.0)
        #expect(close(blob.durationSeconds, 0.5))
    }

    // MARK: - Blobs from a detection

    @Test("each voiced run becomes exactly one blob, centred on the run's median")
    func blobsMirrorVoicedRuns() {
        let frames = voiced(count: 30, from: 0, hz: 220)
            + unvoiced(count: 10, from: 30 * Self.framePeriod)
            + voiced(count: 30, from: 40 * Self.framePeriod, hz: 440)
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(frames))

        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: Self.frameRate)
        #expect(runs.count == 2)
        #expect(model.blobs.count == runs.count)
        #expect(close(model.blobs[0].detectedHz, 220, 1e-6))
        #expect(close(model.blobs[0].centreMidi, 57, 1e-6))
        #expect(model.blobs[0].noteName == "A3")
        #expect(close(model.blobs[1].detectedHz, 440, 1e-6))
        #expect(model.blobs[1].noteName == "A4")
        // Times are the run's, verbatim — never re-anchored to the clip.
        #expect(close(model.blobs[0].startSeconds, runs[0].startSeconds))
        #expect(close(model.blobs[0].endSeconds, runs[0].endSeconds))
        #expect(model.blobs[0].frameCount == 30)
        #expect(close(model.blobs[0].medianConfidence, 0.98, 1e-9))
        #expect(Set(model.blobs.map(\.id)).count == 2)
        // The detector's OWN rate is echoed, never a hardcoded 62.5.
        #expect(close(model.frameRateHz, Self.frameRate))
        #expect(model.analysedFrameCount == frames.count)
    }

    @Test("the model reads whatever frame rate the backend reported")
    func frameRateComesFromTheBackend() {
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        // A hypothetical 100 fps backend: at 100 fps the SAME 5 frames span
        // 0.05 s, which is under minimumNoteSeconds, so no note comes out.
        let frames = (0..<5).map { i in
            ClipPitchFrame(timeSeconds: Double(i) * 0.01, frequencyHz: 220,
                           confidence: 0.99, levelDbfs: -20, absence: nil)
        }
        model.apply(detection(frames, frameRateHz: 100))
        #expect(close(model.frameRateHz, 100))
        #expect(model.blobs.isEmpty)
    }

    /// A voiced blip under `PitchAutoCorrect.minimumNoteSeconds` is not a note
    /// — and gets no contour either, because the contour is gathered per run.
    /// Recorded as a deliberate consequence of having ONE home for the split
    /// rule, not as an accident.
    @Test("a voiced blip shorter than the minimum note is neither a blob nor a contour stretch")
    func shortBlipsAreNotNotes() {
        let frames = voiced(count: 2, from: 0, hz: 220)
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(frames))
        #expect(2 * Self.framePeriod < PitchAutoCorrect.minimumNoteSeconds)
        #expect(model.blobs.isEmpty)
        #expect(model.contourRuns.isEmpty)
        // ⚠️ And the state is "found nothing" — NOT "nothing ran".
        #expect(model.state == .noNotesFound)
    }

    // MARK: - The contour, and the hole

    /// ⭐ **THE HOLE TEST, WITH ITS POSITIVE CONTROL.**
    ///
    /// §5.5.1: a hole is the signal and must never be bridged. The count alone
    /// would be weak evidence here (the contour is gathered per run, so the
    /// counts agree structurally), so this also asserts the GAP: no contour
    /// point falls inside the unvoiced stretch, and the two polylines are
    /// separated on screen. The control fills the hole and demands ONE
    /// polyline that DOES cross it.
    @Test("a hole splits the contour — and the filled-hole control proves the test can tell")
    func holeSplitsTheContour() {
        let holeStart = 30 * Self.framePeriod              // 0.48 s
        let holeEnd = 40 * Self.framePeriod                // 0.64 s
        let withHole = voiced(count: 30, from: 0, hz: 220)
            + unvoiced(count: 10, from: holeStart)
            + voiced(count: 30, from: holeEnd, hz: 220)

        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(withHole))

        #expect(model.contourRuns.count == 2, "a hole must END a run, never be bridged")
        #expect(model.contourSegments.count == 2)
        #expect(model.blobs.count == 2)
        // The polylines carry their blobs' ids, so a view needs no second table.
        #expect(model.contourRuns.map(\.id) == model.blobs.map(\.id))

        // ⛔ THE PHYSICS: nothing was measured inside the hole, so nothing is drawn there.
        let allPoints = model.contourRuns.flatMap(\.points)
        #expect(allPoints.allSatisfy({ $0.sourceSeconds < holeStart || $0.sourceSeconds >= holeEnd }),
                "a contour point landed inside the unvoiced stretch")
        #expect(allPoints.count == 60)
        // And the gap is visible on screen, not merely in the data.
        let first = model.contourSegments[0]
        let second = model.contourSegments[1]
        #expect(first.last!.x < second.first!.x)
        #expect(second.first!.x - first.last!.x > 0)

        // ⭐ POSITIVE CONTROL — the same contour with the hole FILLED. If this
        // also came back as 2, the assertion above would be measuring nothing.
        let filled = voiced(count: 30, from: 0, hz: 220)
            + voiced(count: 10, from: holeStart, hz: 220)
            + voiced(count: 30, from: holeEnd, hz: 220)
        let control = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        control.apply(detection(filled))
        #expect(control.contourRuns.count == 1, "the control must NOT split — if it does, the hole test proves nothing")
        #expect(control.contourSegments.count == 1)
        #expect(control.blobs.count == 1)
        #expect(control.contourRuns[0].points.count == 70)
        // The control's single polyline DOES cross the region the other left empty.
        #expect(control.contourRuns[0].points.contains(where: { $0.sourceSeconds >= holeStart && $0.sourceSeconds < holeEnd }))
    }

    /// `voicedRuns` ends a run at a frame gap larger than 1.5 frame periods
    /// even with no explicit unvoiced frame — a decimated or windowed payload
    /// measured nothing in between either.
    @Test("a frame gap wider than 1.5 periods ends a run, with no nil frame in sight")
    func gapEndsARun() {
        let first = voiced(count: 20, from: 0, hz: 220)
        let resumeAt = (20 * Self.framePeriod) + (2 * Self.framePeriod)   // a 2-period jump
        let frames = first + voiced(count: 20, from: resumeAt, hz: 220)
        #expect(frames.allSatisfy({ $0.frequencyHz != nil }), "this fixture has no unvoiced frame")

        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(frames))
        #expect(model.blobs.count == 2)
        #expect(model.contourRuns.count == 2)

        // Control: the same 40 frames with NO gap are one run.
        let contiguous = voiced(count: 40, from: 0, hz: 220)
        let control = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        control.apply(detection(contiguous))
        #expect(control.blobs.count == 1)
        #expect(control.contourRuns.count == 1)
    }

    @Test("contour points follow the geometry without re-detecting")
    func contourFollowsGeometry() {
        let frames = voiced(count: 30, from: 0.3, hz: 220)
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry(pixelsPerBeat: 40))
        model.apply(detection(frames))
        let before = model.contourSegments
        let dataBefore = model.contourRuns

        model.geometry.pixelsPerBeat = 80
        let after = model.contourSegments

        #expect(after.count == before.count)
        #expect(model.contourRuns == dataBefore, "a zoom change must not re-derive the DATA")
        // Doubling the scale doubles x (the pane's origin is the clip's start).
        #expect(close(after[0][0].x, before[0][0].x * 2, 1e-9))
        // The x each point lands at is the geometry's own conversion — not a
        // second arithmetic path in the model.
        let point = model.contourRuns[0].points[5]
        #expect(close(after[0][5].x, model.geometry.x(forSourceSecond: point.sourceSeconds)))
        #expect(close(after[0][5].y, model.geometry.y(forMidi: point.midi)))
    }

    // MARK: - §5.5.6 — a rest and a shrug are different facts

    /// §5.5's sixth rule, from `PitchDetection.swift`: a stretch of
    /// `belowLevel` is a REST, a stretch of `belowConfidence` is WE COULD NOT
    /// TELL, and the surface must not merge them into "no note".
    @Test("a silent stretch and an unclear stretch are different facts with different words")
    func restIsNotTheSameAsUncertain() {
        let silent = voiced(count: 20, from: 0, hz: 220)
            + unvoiced(count: 10, from: 20 * Self.framePeriod, absence: .belowLevel)
            + voiced(count: 20, from: 30 * Self.framePeriod, hz: 220)
        let unclear = voiced(count: 20, from: 0, hz: 220)
            + unvoiced(count: 10, from: 20 * Self.framePeriod, absence: .belowConfidence)
            + voiced(count: 20, from: 30 * Self.framePeriod, hz: 220)

        let restModel = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        restModel.apply(detection(silent))
        let shrugModel = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        shrugModel.apply(detection(unclear))

        #expect(restModel.gaps.count == 1)
        #expect(shrugModel.gaps.count == 1)
        #expect(restModel.gaps[0].kind == .rest)
        #expect(shrugModel.gaps[0].kind == .uncertain)
        // ⛔ The words must differ, or the two facts have been merged.
        #expect(restModel.gaps[0].label != shrugModel.gaps[0].label)
        #expect(restModel.gaps[0].label == "No sound here")
        #expect(shrugModel.gaps[0].label == "We could not hear a clear note here")

        // The gap's bounds meet the notes on either side exactly.
        #expect(close(restModel.gaps[0].startSeconds, 20 * Self.framePeriod, 1e-12))
        #expect(close(restModel.gaps[0].endSeconds, 30 * Self.framePeriod, 1e-12))
        #expect(close(restModel.gaps[0].endSeconds, restModel.blobs[1].startSeconds, 1e-12))
        #expect(restModel.gaps[0].frameCount == 10)
    }

    /// ⭐ Claiming silence takes UNANIMOUS evidence: one frame the detector
    /// heard-but-could-not-name means "no sound here" is a claim the
    /// measurement does not support. The control is the same stretch with that
    /// one frame made silent too.
    @Test("one unclear frame stops a stretch being called silence — and the all-silent control proves it")
    func mixedGapIsNeverCalledSilence() {
        func gapModel(mixedAt index: Int?) -> PitchEditorModel {
            var hole = unvoiced(count: 10, from: 20 * Self.framePeriod, absence: .belowLevel)
            if let index {
                hole[index] = ClipPitchFrame(timeSeconds: hole[index].timeSeconds,
                                             frequencyHz: nil, confidence: 0.4,
                                             levelDbfs: -20, absence: .belowConfidence)
            }
            let frames = voiced(count: 20, from: 0, hz: 220) + hole
                + voiced(count: 20, from: 30 * Self.framePeriod, hz: 220)
            let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
            model.apply(detection(frames))
            return model
        }

        let mixed = gapModel(mixedAt: 5)
        #expect(mixed.gaps.count == 1)
        #expect(mixed.gaps[0].kind == .uncertain,
                "9 silent frames and 1 unclear one is not silence")

        // ⭐ POSITIVE CONTROL — the same stretch, all ten frames silent.
        let control = gapModel(mixedAt: nil)
        #expect(control.gaps.count == 1)
        #expect(control.gaps[0].kind == .rest,
                "if the control does not come back a rest, the assertion above proves nothing")
        #expect(control.gaps[0].label != mixed.gaps[0].label)
    }

    @Test("a failed load leaves no stale gaps either")
    func gapsClearWithEverythingElse() async {
        let frames = voiced(count: 20, from: 0, hz: 220)
            + unvoiced(count: 10, from: 20 * Self.framePeriod, absence: .belowLevel)
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        await model.load(using: ScriptedProvider(.success(detection(frames))).detect)
        #expect(model.gaps.count == 1)
        model.reset()
        #expect(model.gaps.isEmpty)
    }

    // MARK: - The vertical window

    @Test("the window opens on the detected notes plus padding")
    func windowFitsTheMaterial() {
        // 220 Hz (A3 = 57) and 261.63 Hz (C4 = 60).
        let frames = voiced(count: 30, from: 0, hz: 220)
            + unvoiced(count: 10, from: 30 * Self.framePeriod)
            + voiced(count: 30, from: 40 * Self.framePeriod, hz: 261.6255653)
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(frames))

        let range = model.geometry.midiRange
        #expect(range.lowerBound <= 57 - PitchEditorRange.paddingSemitones)
        #expect(range.upperBound >= 60 + PitchEditorRange.paddingSemitones)
        #expect(range.upperBound - range.lowerBound <= PitchEditorRange.maximumVisibleSemitones)
        #expect(range.lowerBound == range.lowerBound.rounded(), "row bounds are integral")
        #expect(range.upperBound == range.upperBound.rounded())
    }

    @Test("with nothing detected the window falls back rather than collapsing")
    func windowFallsBack() {
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection([]))
        #expect(model.geometry.midiRange == PitchEditorRange.fallbackMidiRange)
        #expect(model.geometry.contentHeight > 0)
        // §5.6 requires the surface to SAY SO in words.
        #expect(model.state == .noNotesFound)
        #expect(!model.state.message.isEmpty)
    }

    @Test("the window never opens at the full 128 rows, and never narrower than the floor")
    func windowIsBounded() {
        // A drum loop: SwiftF0 is monophonic and reports SOMETHING everywhere.
        let wild = PitchEditorRange.midiRange(forNoteCentres: [24, 40, 57, 60, 61, 108])
        #expect(wild.upperBound - wild.lowerBound == PitchEditorRange.maximumVisibleSemitones)
        #expect(PitchEditorRange.fullMidiRange.contains(wild.lowerBound))
        #expect(PitchEditorRange.fullMidiRange.contains(wild.upperBound))
        // The window re-centres on the MEDIAN centre, so it holds the material
        // the singer actually spent their time on.
        #expect(wild.contains(58.5))

        // One note, sung flat and never moving.
        let single = PitchEditorRange.midiRange(forNoteCentres: [60])
        #expect(single.upperBound - single.lowerBound >= PitchEditorRange.minimumVisibleSemitones)
        #expect(single.contains(60))

        // Material at the very bottom of MIDI slides rather than narrows.
        let low = PitchEditorRange.midiRange(forNoteCentres: [1, 2])
        #expect(low.lowerBound >= 0)
        #expect(low.upperBound - low.lowerBound >= PitchEditorRange.minimumVisibleSemitones)
        #expect(low.contains(2))

        // …and so does material at the very top.
        let high = PitchEditorRange.midiRange(forNoteCentres: [126, 127])
        #expect(high.upperBound <= 127)
        #expect(high.upperBound - high.lowerBound >= PitchEditorRange.minimumVisibleSemitones)
        #expect(high.contains(126))
    }

    // MARK: - ⭐ The four states, and the one distinction this project keeps paying for

    @Test("state is a total function of (phase, note count)")
    func stateIsTotal() {
        let phases: [PitchEditorPhase] = [
            .notStarted, .detecting, .detected,
            .failed(.engineUnavailable), .failed(.refused("nope")),
        ]
        for phase in phases {
            for count in [0, 1, 450] {
                let state = PitchEditorState.resolve(phase: phase, noteCount: count)
                #expect(!state.message.isEmpty, "\(phase) × \(count) drew no prose")
                #expect(!state.statusKey.isEmpty)
            }
        }
        #expect(PitchEditorState.resolve(phase: .notStarted, noteCount: 0) == .idle)
        #expect(PitchEditorState.resolve(phase: .notStarted, noteCount: 7) == .idle,
                "a stale note count must not turn 'nothing ran' into a result")
        #expect(PitchEditorState.resolve(phase: .detecting, noteCount: 0) == .analysing)
        #expect(PitchEditorState.resolve(phase: .detected, noteCount: 0) == .noNotesFound)
        #expect(PitchEditorState.resolve(phase: .detected, noteCount: 3) == .ready(noteCount: 3))
        #expect(PitchEditorState.resolve(phase: .failed(.engineUnavailable), noteCount: 0)
                == .engineUnavailable)
        #expect(PitchEditorState.resolve(phase: .failed(.refused("why")), noteCount: 0)
                == .refused("why"))
    }

    /// ⭐⭐ **THE DISTINCTION.** A tool that never looked and a tool that looked
    /// and found nothing produce the same output — unless something makes them
    /// different. The positive control below proves the comparison would
    /// REPORT equality if the two strings ever became equal.
    @Test("'nothing ran' and 'ran and found nothing' are different screens")
    func idleIsNotNoNotesFound() {
        let idle = PitchEditorState.idle
        let empty = PitchEditorState.noNotesFound

        #expect(idle != empty)
        #expect(idle.statusKey != empty.statusKey)
        #expect(idle.message != empty.message,
                "'\(idle.message)' and '\(empty.message)' must not be the same sentence")
        #expect(!idle.message.isEmpty)
        #expect(!empty.message.isEmpty)
        #expect(!idle.drawsNotes)
        #expect(!empty.drawsNotes)

        // ⭐ POSITIVE CONTROL for the instrument: two references to the SAME
        // state must compare EQUAL on all three axes. If this failed, the
        // inequalities above would be meaningless.
        let sameEmpty = PitchEditorState.resolve(phase: .detected, noteCount: 0)
        #expect(sameEmpty == empty)
        #expect(sameEmpty.statusKey == empty.statusKey)
        #expect(sameEmpty.message == empty.message)
    }

    /// Asserted BY VALUE, never by "non-empty": a placeholder passes a
    /// non-empty check. Three of these are §5.7's own strings, verbatim.
    @Test("every state's prose is the beginner-readable line the design specifies")
    func proseIsExact() {
        #expect(PitchEditorState.analysing.message == "Listening to your vocal…")
        #expect(PitchEditorState.noNotesFound.message
                == "We could not hear any sung notes here. This works best on one voice "
                + "singing on its own — not on drums, chords or a full mix.")
        #expect(PitchEditorState.engineUnavailable.message
                == "The audio engine is not running, so we cannot analyse this clip yet.")
        #expect(PitchEditorState.idle.message == "We have not listened to this clip yet.")
        #expect(PitchEditorState.ready(noteCount: 1).message == "Found 1 note.")
        #expect(PitchEditorState.ready(noteCount: 12).message == "Found 12 notes.")

        // The status keys are the echo's contract (additive only, never renamed).
        #expect(PitchEditorState.idle.statusKey == "idle")
        #expect(PitchEditorState.analysing.statusKey == "analysing")
        #expect(PitchEditorState.ready(noteCount: 1).statusKey == "ready")
        #expect(PitchEditorState.noNotesFound.statusKey == "noNotes")
        #expect(PitchEditorState.engineUnavailable.statusKey == "engineUnavailable")
        #expect(PitchEditorState.refused("x").statusKey == "refused")
        // Every key distinct — an echo that reported two states the same way
        // would hide exactly the conflation above.
        let keys = [PitchEditorState.idle, .analysing, .ready(noteCount: 1), .noNotesFound,
                    .engineUnavailable, .refused("x")].map(\.statusKey)
        #expect(Set(keys).count == keys.count)
    }

    @Test("an unavailable engine says so in words a novice can act on, not in the store's developer text")
    func engineUnavailableProse() {
        let failure = PitchEditorFailure(ProjectError.engineUnavailable)
        #expect(failure == .engineUnavailable)
        let state = PitchEditorState.resolve(phase: .failed(failure), noteCount: 0)
        #expect(state.message == "The audio engine is not running, so we cannot analyse this clip yet.")
        // MEASURED 2026-09-22: the store's own string is "audio engine not available".
        #expect(state.message != ProjectError.engineUnavailable.errorDescription)
    }

    @Test("a refusal carries the store's teaching text verbatim")
    func refusalIsVerbatim() {
        let id = UUID()
        let error = ProjectError.pitchDetectionRequiresAudioClip(id)
        let failure = PitchEditorFailure(error)
        let teaching = error.errorDescription ?? ""
        #expect(failure == .refused(teaching))
        let state = PitchEditorState.resolve(phase: .failed(failure), noteCount: 0)
        // Not merely equal to itself: the text is the store's real sentence.
        #expect(state.message.contains("is a MIDI clip"))
        #expect(state.message.contains(id.uuidString))
        #expect(!state.message.contains("couldn’t be completed"),
                "Foundation's boilerplate must never reach the screen")
    }

    // MARK: - The load lifecycle

    /// Records what it was asked for and answers a script.
    @MainActor final class ScriptedProvider {
        var received: [UUID] = []
        var result: Result<ClipPitchDetection, Error>

        init(_ result: Result<ClipPitchDetection, Error>) { self.result = result }

        func detect(_ id: UUID) async throws -> ClipPitchDetection {
            received.append(id)
            return try result.get()
        }
    }

    @Test("a load that finds notes reaches ready, and asks for THIS clip by id")
    func loadReachesReady() async {
        let clipID = UUID()
        let frames = voiced(count: 30, from: 0, hz: 220)
            + unvoiced(count: 10, from: 30 * Self.framePeriod)
            + voiced(count: 30, from: 40 * Self.framePeriod, hz: 440)
        let provider = ScriptedProvider(.success(detection(frames)))
        let model = PitchEditorModel(clipID: clipID, geometry: awkwardGeometry())

        #expect(model.state == .idle, "before anything is asked, the surface says so")
        await model.load(using: provider.detect)

        #expect(provider.received == [clipID], "the editor addresses clips BY ID")
        #expect(model.state == .ready(noteCount: 2))
        #expect(model.state.message == "Found 2 notes.")
        #expect(model.state.drawsNotes)
        #expect(model.blobs.count == 2)
        #expect(model.contourSegments.count == 2)
    }

    /// ⭐ The load-path twin of `idleIsNotNoNotesFound`: a completed load that
    /// found nothing must NOT come back looking like a load that never ran.
    @Test("a load that finds nothing reaches 'no notes found', never 'idle'")
    func emptyLoadIsNotIdle() async {
        let provider = ScriptedProvider(.success(detection([])))
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        await model.load(using: provider.detect)

        #expect(model.phase == .detected, "detection DID run")
        #expect(model.state == .noNotesFound)
        #expect(model.state != .idle)
        #expect(model.state.message != PitchEditorState.idle.message)
        #expect(model.blobs.isEmpty)
    }

    @Test("a failed load leaves no stale notes behind")
    func failureClearsTheSurface() async {
        let frames = voiced(count: 30, from: 0, hz: 220)
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        await model.load(using: ScriptedProvider(.success(detection(frames))).detect)
        #expect(model.blobs.count == 1)

        await model.load(using: ScriptedProvider(.failure(ProjectError.engineUnavailable)).detect)
        #expect(model.state == .engineUnavailable)
        #expect(model.blobs.isEmpty, "a refusal must not leave the previous take's notes on screen")
        #expect(model.contourRuns.isEmpty)
        #expect(model.analysedFrameCount == 0)
    }

    @Test("a cancelled load concludes nothing and says nothing")
    func cancellationConcludesNothing() async {
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        await model.load(using: ScriptedProvider(.failure(CancellationError())).detect)
        #expect(model.state == .idle,
                "a cancelled load is not a refusal — Foundation boilerplate must not be drawn as one")
        #expect(model.phase == .notStarted)
    }

    /// A provider that PARKS its first call so two loads can overlap.
    @MainActor final class ParkingProvider {
        private var parked: [CheckedContinuation<ClipPitchDetection, Error>] = []
        var immediate: [ClipPitchDetection] = []
        private(set) var callCount = 0

        var parkedCount: Int { parked.count }

        func detect(_ id: UUID) async throws -> ClipPitchDetection {
            callCount += 1
            if !immediate.isEmpty { return immediate.removeFirst() }
            return try await withCheckedThrowingContinuation { parked.append($0) }
        }

        func resumeFirst(with detection: ClipPitchDetection) {
            guard !parked.isEmpty else { return }
            parked.removeFirst().resume(returning: detection)
        }
    }

    /// Waits for `condition`, bounded — a spin that could hang is worse than a
    /// failing test.
    private func settle(until condition: () -> Bool) async -> Bool {
        for _ in 0..<10_000 {
            if condition() { return true }
            await Task.yield()
        }
        return false
    }

    /// ⭐ A detection that finishes AFTER the pane moved on must never paint.
    /// This is the tree's characteristic failure in miniature: the stale result
    /// is a perfectly valid-looking answer to a question nobody is asking any
    /// more.
    @Test("a stale detection never paints")
    func staleDetectionIsDropped() async {
        let slow = detection(voiced(count: 30, from: 0, hz: 220)
                             + unvoiced(count: 10, from: 30 * Self.framePeriod)
                             + voiced(count: 30, from: 40 * Self.framePeriod, hz: 440))
        let fresh = detection(voiced(count: 30, from: 0, hz: 330))

        let provider = ParkingProvider()
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())

        let first = Task { await model.load(using: provider.detect) }
        #expect(await settle(until: { provider.parkedCount == 1 }), "the first load never parked")
        #expect(model.state == .analysing)

        // A second load supersedes it and completes immediately.
        await model.load(using: ScriptedProvider(.success(fresh)).detect)
        #expect(model.blobs.count == 1)

        // Now the first one finally answers — with TWO notes. If the guard were
        // missing, the surface would flip back to the superseded result.
        provider.resumeFirst(with: slow)
        await first.value

        #expect(model.blobs.count == 1, "the superseded detection repainted the surface")
        #expect(model.state == .ready(noteCount: 1))
        #expect(close(model.blobs[0].detectedHz, 330, 1e-6))
    }

    @Test("reset invalidates a load that is still in flight")
    func resetInvalidatesInFlight() async {
        let late = detection(voiced(count: 30, from: 0, hz: 220))
        let provider = ParkingProvider()
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())

        let task = Task { await model.load(using: provider.detect) }
        #expect(await settle(until: { provider.parkedCount == 1 }), "the load never parked")
        model.reset()
        #expect(model.state == .idle)

        provider.resumeFirst(with: late)
        await task.value
        #expect(model.state == .idle, "a reset load painted anyway")
        #expect(model.blobs.isEmpty)
    }

    // MARK: - Honesty floors

    /// §5.5.3: half a bin is 12.90 cents, so nothing finer may be claimed, and
    /// a readout is whole cents at most.
    @Test("a cents readout respects the detector's own resolution floor")
    func centsReadoutFloor() {
        #expect(PitchEditorReadout.centsReadout(0) == nil)
        #expect(PitchEditorReadout.centsReadout(12) == nil,
                "12 cents is inside half a bin — the detector cannot tell")
        #expect(PitchEditorReadout.centsReadout(-12) == nil)
        #expect(PitchEditorReadout.centsReadout(12.90) == "+13 cents")
        #expect(PitchEditorReadout.centsReadout(31.4) == "+31 cents")
        #expect(PitchEditorReadout.centsReadout(-31.4) == "-31 cents")
        #expect(PitchEditorReadout.centsReadout(.nan) == nil)
        // No decimals, ever — the chain cannot support them.
        #expect(PitchEditorReadout.centsReadout(31.4)?.contains(".") == false)

        // 440 Hz is exactly A4, so its readout is absent rather than "0 cents".
        let inTune = NoteBlob(startSeconds: 0, endSeconds: 1, detectedHz: 440,
                              medianConfidence: 0.99, frameCount: 60)
        #expect(inTune.centsReadout == nil)
        #expect(inTune.noteName == "A4")
        // A quarter-tone flat of A4 is 50 cents — well outside the floor.
        let flat = NoteBlob(startSeconds: 0, endSeconds: 1,
                            detectedHz: 440 * pow(2, -0.5 / 12),
                            medianConfidence: 0.99, frameCount: 60)
        #expect(flat.centsReadout == "-50 cents")
        #expect(flat.noteName == "A4")
    }
}
