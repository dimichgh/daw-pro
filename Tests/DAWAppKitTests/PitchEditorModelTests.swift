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
        // p2-seg §5.2: neither run changes note inside, so the note splitter the
        // blobs now come from returns each run whole, and both note-table
        // builders write the pre-p2-seg table field by field.
        let invariance = PrePitchNoteSplitReference.invarianceFailures(frames: frames,
                                                                       frameRateHz: Self.frameRate)
        #expect(invariance.isEmpty, "\(invariance.prefix(3))")
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
        // ⚠️⚠️ **THE ID EQUALITY THAT USED TO BE ASSERTED HERE IS RETIRED, AND
        // ITS RETIREMENT IS THE FINDING.** Until m23-ap C3 the contour was
        // gathered PER BLOB, so `contourRuns[i].id == blobs[i].id` held by
        // construction. A split makes two NOTES out of one measured RUN, and
        // the contour follows the RUN — because breaking the measured line in
        // two at a cut would draw a 16 ms hole where the singer never stopped,
        // which is the bridged-hole lie (§5.5.1) with its sign reversed. So the
        // two collections are no longer index-for-index, and the honest
        // assertion is that each polyline lies inside exactly one voiced run.
        let runs = PitchAutoCorrect.voicedRuns(in: withHole, frameRateHz: Self.frameRate)
        // p2-seg §5.2: two steady runs, so the note splitter changes nothing here.
        let invariance = PrePitchNoteSplitReference.invarianceFailures(frames: withHole,
                                                                       frameRateHz: Self.frameRate)
        #expect(invariance.isEmpty, "\(invariance.prefix(3))")
        #expect(model.contourRuns.count == runs.count)
        for (index, run) in runs.enumerated() {
            let points = model.contourRuns[index].points
            #expect(points.allSatisfy { $0.sourceSeconds >= run.startSeconds
                                        && $0.sourceSeconds < run.endSeconds })
        }

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

    // MARK: - I6c — the window fills the pane (interaction batch §9)
    //
    // The numbers are the MEASURED staging pane (1400×1000, the synthetic
    // 40-note take, 2026-09-25): a 17-row window 53…69 at 14 pt is 238 pt,
    // docked in a 245.6 pt pitch viewport and maximized in a 503 pt one.

    /// Notes one per voiced run at `midis`, 20 frames each with 10 unvoiced
    /// between (`fourNotes`' shape, any pitches), inside the awkward clip's
    /// source window [0.25, 2.75) for up to five notes.
    private func notes(_ midis: [Double]) -> (model: PitchEditorModel, sink: Box) {
        var frames: [ClipPitchFrame] = []
        var start = 0.30
        for (index, midi) in midis.enumerated() {
            frames += voiced(count: 20, from: start, hz: 440 * pow(2, (midi - 69) / 12))
            start += 20 * Self.framePeriod
            if index < midis.count - 1 {
                frames += unvoiced(count: 10, from: start)
                start += 10 * Self.framePeriod
            }
        }
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(frames))
        let sink = Box()
        model.onCommit = { sink.commits.append($0) }
        return (model, sink)
    }

    /// The laid-out grid fills a pane `height` tall: never taller than it, and
    /// short of it by less than one row.
    private func fills(_ model: PitchEditorModel, _ height: CGFloat) -> Bool {
        let content = model.geometry.contentHeight
        return content <= height + 1e-9 && content + model.geometry.rowHeight > height
    }

    @Test("I6c — the pure fill: whole rows at the row height, split evenly (the odd one above), slid into 0…127; the measured docked pane keeps its window")
    func i6cTheFillRuleByHand() {
        let fitted: ClosedRange<Double> = 53...69                  // 17 rows
        // THE DOCKED DEFAULT, MEASURED: 245.6 pt holds 17.54 rows → 17 → unchanged.
        #expect(PitchEditorRange.filled(fitted, rowHeight: 14, availableHeight: 245.6) == fitted)
        #expect(PitchEditorRange.filled(fitted, rowHeight: 14, availableHeight: 238) == fitted)
        // MAXIMIZED, MEASURED 503 pt: 35 rows, 18 more — 9 below, 9 above.
        #expect(PitchEditorRange.filled(fitted, rowHeight: 14, availableHeight: 503) == 44...78)
        // PITCH + ×2 (the ladder's own 21.875): 22 rows, 5 more — 2 below, 3 above.
        let plus2 = PianoRollZoom.tallerRow(PianoRollZoom.tallerRow(14))
        #expect(plus2 == 21.875)
        #expect(PitchEditorRange.filled(fitted, rowHeight: plus2, availableHeight: 503) == 51...72)
        // PITCH − ×2 (11.2, then the 10 pt floor): 50 rows, 33 more — 16 below, 17 above.
        let minus2 = PianoRollZoom.shorterRow(PianoRollZoom.shorterRow(14))
        #expect(minus2 == 10)
        #expect(PitchEditorRange.filled(fitted, rowHeight: minus2, availableHeight: 503) == 37...86)
        // At either end of MIDI the growth SLIDES, keeping all 50 rows.
        #expect(PitchEditorRange.filled(115...127, rowHeight: 10, availableHeight: 503) == 78...127)
        #expect(PitchEditorRange.filled(0...12, rowHeight: 10, availableHeight: 503) == 0...49)
        // Never more than the 128 rows MIDI has.
        #expect(PitchEditorRange.filled(fitted, rowHeight: 1, availableHeight: 10_000) == 0...127)
        // Total: no pane, a bad pane or a bad row height is the fitted window.
        for height in [0, -5, CGFloat.nan, .infinity] as [CGFloat] {
            #expect(PitchEditorRange.filled(fitted, rowHeight: 14, availableHeight: height) == fitted)
        }
        for row in [0, -1, CGFloat.nan] as [CGFloat] {
            #expect(PitchEditorRange.filled(fitted, rowHeight: row, availableHeight: 503) == fitted)
        }
        // A window already taller than the pane is never cut down.
        #expect(PitchEditorRange.filled(fitted, rowHeight: 56, availableHeight: 503) == fitted)

        // The STRAND rule's own arithmetic: whole rows, one row of room each
        // side of a held note, never a narrowing, clamped to MIDI.
        #expect(PitchEditorRange.heldNoteHeadroomRows == 1)
        #expect(PitchEditorRange.holding(53...66, drawnMidis: [70]) == 53...71)
        #expect(PitchEditorRange.holding(53...66, drawnMidis: [50.4]) == 49...66)
        #expect(PitchEditorRange.holding(53...66, drawnMidis: [60, 61]) == 53...66, "inside: untouched")
        #expect(PitchEditorRange.holding(53...66, drawnMidis: []) == 53...66)
        #expect(PitchEditorRange.holding(53...66, drawnMidis: [.nan, .infinity]) == 53...66)
        #expect(PitchEditorRange.holding(100...120, drawnMidis: [127]) == 100...127)
        #expect(PitchEditorRange.holding(10...20, drawnMidis: [0.5]) == 0...20)
    }

    @Test("I6c — ⭐ a pane taller than the notes' window is filled with whole rows at the CURRENT row height, centred on the notes; PITCH −/+ still change the rows; restore gives today's window back")
    func i6cThePaneIsFilledAtEveryHeight() {
        let (model, _, _) = fourNotes()                             // fitted 53…66, 14 rows
        #expect(model.geometry.midiRange == 53...66, "no pane: today's window")
        // A pane the notes' rows already fill (to within a row) keeps today's window.
        model.setAvailableHeight(196)                               // exactly 14 rows
        #expect(model.geometry.midiRange == 53...66)
        model.setAvailableHeight(209.9)                             // 14.99 rows
        #expect(model.geometry.midiRange == 53...66)

        // MAXIMIZED (the measured 503 pt): 35 rows, 21 more — 10 below, 11 above.
        model.setAvailableHeight(503)
        #expect(model.geometry.midiRange == 43...77)
        #expect(fills(model, 503), "content \(model.geometry.contentHeight) in a 503 pt pane")
        #expect(model.fittedMidiRange == 53...66, "the notes' own window is untouched by the fill")
        let above = model.geometry.midiRange.upperBound - 66
        let below = 53 - model.geometry.midiRange.lowerBound
        #expect(above - below == 1, "centred on the notes, the odd row above")
        // Everything that reads the window follows it: the ruler names all 35
        // rows, and D4 (62) is drawn — and hit — on its row under the new top.
        #expect(model.rulerKeys.count == 35)
        #expect(model.rulerKeys.first?.midi == 77 && model.rulerKeys.last?.midi == 43)
        let d = model.blobs[3]
        #expect(close(model.rect(for: d).midY, (77 - 62 + 0.5) * 14))
        #expect(model.blob(at: CGPoint(x: model.rect(for: d).midX, y: model.rect(for: d).midY))?.id == d.id)

        // PITCH + ×2 keeps its meaning — TALLER rows, so FEWER of them: 22, 4 and 4.
        model.setRowHeight(PianoRollZoom.tallerRow(PianoRollZoom.tallerRow(14)))
        #expect(model.geometry.rowHeight == 21.875)
        #expect(model.geometry.midiRange == 49...70)
        #expect(fills(model, 503))
        // PITCH − ×2 — SHORTER rows, so MORE of them: 50, 18 and 18.
        model.setRowHeight(PianoRollZoom.shorterRow(PianoRollZoom.shorterRow(14)))
        #expect(model.geometry.rowHeight == 10)
        #expect(model.geometry.midiRange == 35...84)
        #expect(fills(model, 503))
        // Back to 14 pt, then RESTORE: exactly the maximized window, then today's.
        model.setRowHeight(14)
        #expect(model.geometry.midiRange == 43...77)
        model.setAvailableHeight(196)
        #expect(model.geometry.midiRange == 53...66)
    }

    @Test("I6c — ⛔ the drag clamps follow the laid-out window: a note reaches a row the fill added, and no further, one note or a group")
    func i6cTheClampFollowsTheFilledWindow() {
        let (model, sink, ids) = fourNotes()
        model.setAvailableHeight(503)                               // 43…77
        let d = model.blobs[3]                                      // D4, 62
        #expect(model.beginPitchDrag(on: d))
        // 400 pt at 14 pt/row is 28.6 rows: far past the top of the NOTES' window
        // (66) — and stopped at the top of the LAID-OUT one.
        model.updatePitchDrag(translationHeight: -400, free: true)
        #expect(close(model.drag!.targetMidi, 77), "⌥ stops at the laid-out top, not at 66")
        model.updatePitchDrag(translationHeight: -400, free: false)
        #expect(close(model.drag!.targetMidi, 76), "snapped: one row inside the laid-out top")
        model.cancelDrag()

        // A group, D and A: D is the tightest, 77 − 62 = 15 semitones of room.
        model.selectOnly(ids[0])
        model.toggle(ids[3])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -400, free: true)
        #expect(close(model.drag!.offsetCents, 1500), "A moved by D's room in the LAID-OUT window")
        #expect(close(model.drag!.members[0].targetMidi(clipPitchShiftSemitones: 0), 77))
        model.cancelDrag()
        #expect(sink.commits.isEmpty)
    }

    @Test("I6c — ⛔ a note dragged into a row the fill added: the commit does not move the grid, restore never strands it, and a redo after a shrink widens the window rather than hiding the note")
    func i6cANoteInAGrownRowIsNeverStranded() {
        let (model, sink, _) = fourNotes()
        model.setAvailableHeight(503)                               // 43…77
        let d = model.blobs[3]                                      // D4, 62
        #expect(model.beginPitchDrag(on: d))
        model.updatePitchDrag(translationHeight: -8 * 14, free: false)
        _ = model.endPitchDrag()
        guard case .notePitch(let id, let cents)? = sink.commits.last?.kind else {
            Issue.record("no one-note commit")
            return
        }
        #expect(id == d.id && close(cents, 800), "D committed on 70, four rows above the notes' own top (66)")
        func table(dCents: Double) -> PitchEditSet {
            var segments = model.seedTable.segments
            let index = segments.firstIndex { $0.id == d.id }!
            segments[index].pitchOffsetCents = dCents
            return PitchEditSet(segments: segments)
        }
        // The store reads the commit back — the grid does NOT move under it.
        model.syncStoredNoteTable(table(dCents: 800))
        #expect(model.geometry.midiRange == 43...77)
        #expect(close(model.rect(for: model.blobs[3]).midY, (77 - 70 + 0.5) * 14))

        // RESTORE: the fill goes, D's row stays — with one row of room above it
        // for its name (drawn in the gutter over the note). The notes' own window
        // (53…66) does not hold 70, so it is the strand rule, not the fit.
        #expect(!model.fittedMidiRange.contains(70))
        model.setAvailableHeight(196)
        #expect(model.geometry.midiRange == 53...71)
        let rect = model.rect(for: model.blobs[3])
        #expect(rect.minY >= 0 && rect.maxY <= model.geometry.contentHeight,
                "D drawn at \(rect) in a \(model.geometry.contentHeight) pt content — stranded off it")
        #expect(rect.minY >= model.geometry.rowHeight, "no row above D for its label: \(rect)")
        // Maximize again: the same window as before, nothing drifted.
        model.setAvailableHeight(503)
        #expect(model.geometry.midiRange == 43...77)

        // UNDO while maximized (D back on 62): the window only ever widens on a
        // read-back, so it stays; then restore gives the notes' own window.
        model.syncStoredNoteTable(table(dCents: 0))
        #expect(model.geometry.midiRange == 43...77)
        model.setAvailableHeight(196)
        #expect(model.geometry.midiRange == 53...66)
        // REDO after the shrink puts D back on 70 — outside 53…66. It widens.
        model.syncStoredNoteTable(table(dCents: 800))
        #expect(model.geometry.midiRange == 53...71, "a redo after a shrink hid the note it moved")
    }

    @Test("I6c — a note the fit left off the window on purpose (the 36-semitone cap) stays off it however much the pane grows")
    func i6cAFitOutlierIsNotPulledIn() {
        // Four notes around C4 and one far detection at 95: padded, 53…99 spans
        // 46, over the cap, so the fit re-centres on the median (60) at 36 wide
        // — 42…78, give or take the median's last bit of floating point.
        let (model, _) = notes([57, 59, 60, 62, 95])
        #expect(model.blobs.count == 5)
        let fitted = model.fittedMidiRange
        #expect(fitted.upperBound - fitted.lowerBound == PitchEditorRange.maximumVisibleSemitones)
        #expect(model.geometry.midiRange == fitted)
        let far = model.blobs.first { $0.centreMidi > 90 }!
        #expect(!fitted.contains(model.geometry.drawnMidi(for: far)))
        #expect(model.fitOutlierIDs == [far.id])
        // Maximized at 10 pt rows: 50 rows, so the fill adds 13 (6 below, 7
        // above) and stops there.
        model.setRowHeight(10)
        model.setAvailableHeight(503)
        #expect(model.geometry.midiRange == (fitted.lowerBound - 6)...(fitted.upperBound + 7))
        #expect(!model.geometry.midiRange.contains(95), "the fill pulled the fit's outlier back in")
        // CONTROL: holding EVERY drawn note would have pulled it in — so the
        // outlier set, not the fixture, is what keeps it out.
        let all = model.blobs.map { model.geometry.drawnMidi(for: $0) }
        #expect(PitchEditorRange.holding(model.geometry.midiRange, drawnMidis: all).contains(95))
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

    // MARK: - m23-ap Increment C — direct manipulation
    //
    // ⭐⭐ THE LOAD-BEARING TEST IN THIS SECTION IS `aDragTickNeverCommits`.
    // Design §8.2 / §11 P7b: a commit per pointer tick re-keys
    // `ClipKey.pitchEditSetHash` at pointer rate and the offline render is
    // never ready. The design recorded the vocal going SILENT for the whole
    // drag; since p2-ren Stage A (2026-09-25) a note edit's pending render
    // plays the clip's PREVIOUS version instead (`StretchResolution.bridge`),
    // so the vocal sounds STALE for the whole drag — silence only after a
    // stretch change or a failed render. Either way that defect is invisible to
    // every other kind of gate — the pitch still ends up right, the undo still
    // coalesces, the screen still looks correct. Only the CADENCE tells you, and
    // only because the model owns the commit seam rather than a `DragGesture`
    // closure.

    /// One long A3 (220 Hz = midi 57 exactly), so every drag number below is
    /// derivable by hand from `rowHeight` and nothing else.
    /// A reference box so the sink survives the closure. (Returning the array
    /// by value would hand back a SNAPSHOT — a sink that can never fill is a
    /// test that can never fail, which is the whole failure class this file's
    /// header is about.)
    @MainActor final class Box {
        var commits: [PitchEditorCommit] = []
    }

    private func oneNote(rowHeight: CGFloat = PitchEditorGeometry.defaultRowHeight)
    -> (model: PitchEditorModel, sink: Box) {
        var geometry = awkwardGeometry()
        geometry.rowHeight = rowHeight
        let model = PitchEditorModel(clipID: UUID(), geometry: geometry)
        model.apply(detection(voiced(count: 60, from: 0.30, hz: 220)))
        let sink = Box()
        model.onCommit = { sink.commits.append($0) }
        return (model, sink)
    }

    @Test("the editor seeds a note table from the detection and draws its blobs from it")
    func seedTableBecomesTheBlobs() {
        let (model, _) = oneNote()
        #expect(model.blobs.count == 1)
        #expect(model.seedTable.segments.count == 1)
        #expect(model.storedTable == nil)
        // The blob IS the segment — that identity is what makes a drag
        // addressable without a second table.
        #expect(model.blobs[0].id == model.seedTable.segments[0].id)
        #expect(close(model.blobs[0].centreMidi, 57, 1e-9))
        #expect(model.blobs[0].offsetCents == 0)
        #expect(close(model.blobs[0].editedCentreMidi, 57, 1e-9))
        #expect(model.blobs[0].frameCount == 60)
        // ⛔ AND THE SEED IS NOT AN EMPTY SET. `PitchAutoCorrect.editSet` at
        // strength 0 returns no segments at all; an editor needs the notes.
        #expect(!model.seedTable.isEmpty)
        #expect(model.seedTable.isIdentity)
    }

    @Test("a STORED table wins over the seed, and its offsets move the blob")
    func storedTableWinsAndMovesTheBlob() {
        let (model, _) = oneNote()
        let seeded = model.seedTable.segments[0]
        var edited = seeded
        edited.pitchOffsetCents = 100
        model.syncStoredNoteTable(PitchEditSet(segments: [edited]))

        #expect(model.blobs.count == 1)
        #expect(model.blobs[0].id == seeded.id)
        #expect(model.blobs[0].offsetCents == 100)
        #expect(model.blobs[0].isEdited)
        // The DETECTED centre never moves — that is the measurement.
        #expect(close(model.blobs[0].centreMidi, 57, 1e-9))
        // The DRAWN centre does.
        #expect(close(model.blobs[0].editedCentreMidi, 58, 1e-9))
        #expect(model.blobs[0].noteName == "A3")
        #expect(model.blobs[0].editedNoteName == "A#3")
        // And the rectangle follows the EDIT, one row higher (y grows down).
        let detectedY = model.geometry.y(forMidi: 57)
        #expect(close(model.rect(for: model.blobs[0]).midY,
                      detectedY - model.geometry.rowHeight, 1e-6))
    }

    @Test("a stored segment outside the clip's source window is not drawn")
    func staleSegmentsOutsideTheWindowAreNotDrawn() {
        let (model, _) = oneNote()
        let inside = model.seedTable.segments[0]
        // The awkward clip reads source seconds [0.25, 2.75). A note at 9 s is
        // one a trim left behind: real data, not this clip's to draw.
        let outside = NoteSegment(startSeconds: 9, endSeconds: 9.5,
                                  detectedHz: 440, detectedConfidence: 0.9)
        model.syncStoredNoteTable(PitchEditSet(segments: [inside, outside]))
        #expect(model.blobs.count == 1)
        #expect(model.blobs[0].id == inside.id)
        // POSITIVE CONTROL: the same segment INSIDE the window is drawn, so the
        // filter is the window talking and not a blanket drop of a second note.
        let alsoInside = NoteSegment(startSeconds: 1.5, endSeconds: 1.8,
                                     detectedHz: 440, detectedConfidence: 0.9)
        model.syncStoredNoteTable(PitchEditSet(segments: [inside, alsoInside]))
        #expect(model.blobs.count == 2)
    }

    // MARK: C1 — the drag

    @Test("⭐ a drag TICK never commits — forty of them produce zero store writes")
    func aDragTickNeverCommits() {
        let (model, sink) = oneNote()
        let blob = model.blobs[0]
        #expect(model.beginPitchDrag(on: blob))

        for tick in 1...40 {
            model.updatePitchDrag(translationHeight: -CGFloat(tick), free: false)
            // The DRAFT moves — the live value is visible the whole way down.
            #expect(model.drag != nil)
        }
        // ⛔ THE ASSERTION THE WHOLE CADENCE RESTS ON.
        #expect(sink.commits.isEmpty,
                "a pointer tick committed to the store — the render would never land and the vocal would play stale for the drag")
        #expect(model.commitCount == 0)

        // …and the release commits exactly once, with the value the last tick
        // resolved to. -40 pt at 14 pt/row = 2.857 semitones; snapped to the
        // chromatic scale from midi 57 that is 60, i.e. +300 cents.
        let commit = model.endPitchDrag()
        #expect(sink.commits.count == 1)
        #expect(model.commitCount == 1)
        #expect(commit != nil)
        guard case .notePitch(let segmentID, let cents)? = sink.commits.first?.kind else {
            Issue.record("the commit was not a pitch edit")
            return
        }
        #expect(segmentID == blob.id)
        #expect(close(cents, 300, 1e-9))
        // The seed rides along, so the first edit on an untuned clip has a
        // table to land in.
        #expect(sink.commits[0].seedIfAbsent.segments.count == 1)
        #expect(sink.commits[0].seedIfAbsent.segments[0].id == blob.id)
        #expect(model.drag == nil)
    }

    @Test("a drag that ends where it began commits NOTHING")
    func aNoOpDragCommitsNothing() {
        let (model, sink) = oneNote()
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -30, free: false)
        model.updatePitchDrag(translationHeight: 0, free: false)   // back to the start
        #expect(model.endPitchDrag() == nil)
        #expect(sink.commits.isEmpty)
        #expect(model.commitCount == 0)
        // POSITIVE CONTROL: the same gesture that does NOT return home commits.
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -30, free: false)
        #expect(model.endPitchDrag() != nil)
        #expect(sink.commits.count == 1)
    }

    @Test("a cancelled drag commits nothing and leaves no phantom baseline")
    func cancelDragCommitsNothing() {
        let (model, sink) = oneNote()
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -30, free: false)
        model.cancelDrag()
        #expect(model.drag == nil)
        #expect(sink.commits.isEmpty)
        // And `endPitchDrag` after a cancel is a no-op rather than a replay.
        #expect(model.endPitchDrag() == nil)
        #expect(sink.commits.isEmpty)
    }

    @Test("⌥ moves freely; without it the drag SNAPS to the scale")
    func snapAndFreeDragDiffer() {
        let (model, _) = oneNote()
        // -18 pt at 14 pt/row = 1.2857 semitones above midi 57 → 58.2857.
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -18, free: false)
        #expect(close(model.drag!.offsetCents, 100, 1e-9))   // snapped to 58 = A#3
        model.updatePitchDrag(translationHeight: -18, free: true)
        #expect(close(model.drag!.offsetCents, 18.0 / 14.0 * 100, 1e-9))
        #expect(model.drag!.isFree)
        model.cancelDrag()
    }

    @Test("the snap follows the SCALE, not just the nearest semitone")
    func snapFollowsTheScale() {
        let (model, _) = oneNote()
        model.snapScale = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)  // C major
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        // 58.2857 is A#3, which C major does not contain; the nearest allowed
        // is B3 = 59, i.e. +200 cents rather than chromatic's +100.
        model.updatePitchDrag(translationHeight: -18, free: false)
        #expect(close(model.drag!.offsetCents, 200, 1e-9))
        model.cancelDrag()
    }

    @Test("a second drag starts from where the first LEFT the note, not from the detected centre")
    func aSecondDragStartsFromTheStoredOffset() {
        let (model, sink) = oneNote()
        var edited = model.seedTable.segments[0]
        edited.pitchOffsetCents = 100          // already a semitone up
        model.syncStoredNoteTable(PitchEditSet(segments: [edited]))

        #expect(model.beginPitchDrag(on: model.blobs[0]))
        #expect(close(model.drag!.baselineCents, 100, 1e-9))
        // One more row up from 58 lands on 59 = +200, not on 58 = +100.
        model.updatePitchDrag(translationHeight: -14, free: false)
        #expect(close(model.drag!.offsetCents, 200, 1e-9))
        _ = model.endPitchDrag()
        guard case .notePitch(_, let cents)? = sink.commits.first?.kind else {
            Issue.record("no commit")
            return
        }
        #expect(close(cents, 200, 1e-9))
    }

    @Test("the drag readout respects the detector's resolution floor and never prints zero")
    func dragReadoutHonoursTheFloor() {
        let (model, _) = oneNote()
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        // A free drag of 1 pt at 14 pt/row is ~7.1 cents — under the 12.90
        // floor, so there is NOTHING honest to print.
        model.updatePitchDrag(translationHeight: -1, free: true)
        #expect(model.drag!.readout == nil)
        // POSITIVE CONTROL: a snapped semitone clears the floor and prints.
        model.updatePitchDrag(translationHeight: -18, free: false)
        #expect(model.drag!.readout == "+100 cents")
        #expect(model.drag!.targetNoteName == "A#3")
        model.cancelDrag()
    }

    @Test("a taller row means a SMALLER pitch change for the same pointer distance")
    func rowHeightChangesDragSensitivity() {
        let (coarse, _) = oneNote(rowHeight: 14)
        let (fine, _) = oneNote(rowHeight: 56)
        for model in [coarse, fine] {
            #expect(model.beginPitchDrag(on: model.blobs[0]))
            model.updatePitchDrag(translationHeight: -28, free: true)
        }
        #expect(close(coarse.drag!.offsetCents, 200, 1e-9))   // 2 semitones
        #expect(close(fine.drag!.offsetCents, 50, 1e-9))      // half a semitone
        coarse.cancelDrag(); fine.cancelDrag()
    }

    @Test("⛔ a drag cannot push a note off the visible window — snapped OR free")
    func aDragCannotLoseANoteOffTheWindow() {
        let (model, sink) = oneNote()
        let window = model.geometry.midiRange
        #expect(model.beginPitchDrag(on: model.blobs[0]))

        // 200 pt at a 14 pt row is over fourteen semitones — far past the top
        // of a window that is the detected span plus four.
        model.updatePitchDrag(translationHeight: -200, free: false)
        var target = model.drag!.targetMidi
        #expect(target <= window.upperBound,
                "a snapped drag committed a note above the top of the content — it would vanish")
        // …and the snap is still EXACT at the boundary: a clamp that put the
        // note on a non-scale pitch would be a quieter version of the same lie.
        #expect(close(target, model.snapScale.nearestAllowedMidi(to: target), 1e-9))

        model.updatePitchDrag(translationHeight: 200, free: false)
        target = model.drag!.targetMidi
        #expect(target >= window.lowerBound)

        model.updatePitchDrag(translationHeight: -200, free: true)
        #expect(close(model.drag!.targetMidi, window.upperBound, 1e-9),
                "a FREE drag must stop at the edge too — ⌥ turns off the snap, not the window")

        // POSITIVE CONTROL: a drag well inside the window is untouched by any
        // of this, so the clamp is the window talking and not a ceiling on
        // every drag.
        model.updatePitchDrag(translationHeight: -14, free: false)
        #expect(close(model.drag!.offsetCents, 100, 1e-9))
        _ = model.endPitchDrag()
        #expect(sink.commits.count == 1)
    }

    @Test("the hit test finds a note where it is DRAWN, not where it was sung")
    func hitTestFollowsTheEdit() {
        let (model, _) = oneNote()
        var edited = model.seedTable.segments[0]
        edited.pitchOffsetCents = 300            // three semitones up
        model.syncStoredNoteTable(PitchEditSet(segments: [edited]))
        let rect = model.rect(for: model.blobs[0])

        #expect(model.blob(at: CGPoint(x: rect.midX, y: rect.midY))?.id == model.blobs[0].id)
        // ⛔ AND NOT at the detected centre it no longer occupies. Three
        // semitones is 42 pt at a 14 pt row — far outside the slop.
        let sungY = model.geometry.y(forMidi: 57)
        #expect(model.blob(at: CGPoint(x: rect.midX, y: sungY)) == nil)
    }

    @Test("the scissors tool does not drag, and the pointer does not cut")
    func toolsDoNotOverlap() {
        let (model, sink) = oneNote()
        model.tool = .scissors
        #expect(model.beginPitchDrag(on: model.blobs[0]) == false)
        #expect(model.drag == nil)

        model.tool = .pointer
        let rect = model.rect(for: model.blobs[0])
        #expect(model.splitNote(at: CGPoint(x: rect.midX, y: rect.midY)) == nil)
        #expect(sink.commits.isEmpty)
        // POSITIVE CONTROL: with the right tool each one works.
        model.tool = .scissors
        #expect(model.splitNote(at: CGPoint(x: rect.midX, y: rect.midY)) != nil)
        #expect(sink.commits.count == 1)
    }

    // MARK: C3 — the split

    @Test("the scissors cuts where the pointer is, in SOURCE seconds")
    func splitCutsAtThePointer() {
        let (model, sink) = oneNote()
        model.tool = .scissors
        let blob = model.blobs[0]
        let rect = model.rect(for: blob)
        let cutX = rect.midX
        _ = model.splitNote(at: CGPoint(x: cutX, y: rect.midY))

        #expect(sink.commits.count == 1)
        guard case .splitNote(let segmentID, let second)? = sink.commits.first?.kind else {
            Issue.record("the commit was not a split")
            return
        }
        #expect(segmentID == blob.id)
        // ⭐ Hand-checked against the ONE coordinate home, not against itself:
        // the cut must be the source second that x maps to.
        #expect(close(second, model.geometry.sourceSecond(forX: cutX), 1e-9))
        #expect(second > blob.startSeconds && second < blob.endSeconds)
        #expect(model.refusal == nil)
    }

    @Test("a cut off a note, and a cut too near an edge, REFUSE in words and commit nothing")
    func splitRefusalsAreSpokenNotSilent() {
        let (model, sink) = oneNote()
        model.tool = .scissors
        let rect = model.rect(for: model.blobs[0])

        // Off the note entirely.
        #expect(model.splitNote(at: CGPoint(x: rect.midX, y: rect.midY + 200)) == nil)
        #expect(sink.commits.isEmpty)
        #expect(model.refusal == "Nothing to cut there. Click on one of the notes.")

        // On the note but a sliver from its start.
        let edgeX = model.geometry.x(forSourceSecond: model.blobs[0].startSeconds + 0.005)
        #expect(model.splitNote(at: CGPoint(x: edgeX, y: rect.midY)) == nil)
        #expect(sink.commits.isEmpty)
        let refusal = model.refusal ?? ""
        #expect(refusal.contains("too close to the edge"))
        #expect(refusal.contains("60 milliseconds"))
        // ⚠️ The two refusals are DIFFERENT SENTENCES. "Nothing there" and "too
        // near the edge" are different facts and a surface that merged them
        // would teach the user to zoom when they should aim.
        #expect(refusal != "Nothing to cut there. Click on one of the notes.")

        // POSITIVE CONTROL: the middle of the same note is accepted, and the
        // refusal clears.
        #expect(model.splitNote(at: CGPoint(x: rect.midX, y: rect.midY)) != nil)
        #expect(model.refusal == nil)
        #expect(sink.commits.count == 1)
    }

    // MARK: m23-ap p2-del — ⌫ with the pane open

    @Test("⌫ refused while the note editor is open lands on the refusal line, commits nothing, and the next drag clears it")
    func deleteKeyRefusalIsSpokenAndCommitsNothing() {
        let (model, sink) = oneNote()
        let blobsBefore = model.blobs
        #expect(model.refusal == nil)

        model.refuseDeleteKey()
        // THE WORDS ARE THE POLICY'S, verbatim — one home for the rule and the
        // sentence that explains it.
        #expect(model.refusal == DeleteMenuPolicy.pitchEditorOpenHint)
        // A REFUSAL, NOT AN EDIT: no commit, no note moved or removed.
        #expect(sink.commits.isEmpty)
        #expect(model.commitCount == 0)
        #expect(model.blobs == blobsBefore)
        // Pressing it again is idempotent — the same one line, not a pile.
        model.refuseDeleteKey()
        #expect(model.refusal == DeleteMenuPolicy.pitchEditorOpenHint)

        // It inherits the refusal slot's lifetime: the user's next gesture in
        // the pane clears it, exactly as it clears "Nothing to cut there.".
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        #expect(model.refusal == nil)
    }

    @Test("the split commit carries the seed table, so the first cut on an untuned clip has somewhere to land")
    func splitCarriesTheSeed() {
        let (model, sink) = oneNote()
        model.tool = .scissors
        let rect = model.rect(for: model.blobs[0])
        _ = model.splitNote(at: CGPoint(x: rect.midX, y: rect.midY))
        #expect(sink.commits.count == 1)
        #expect(sink.commits[0].seedIfAbsent.segments.count == 1)
        #expect(sink.commits[0].seedIfAbsent.segments[0].id == model.blobs[0].id)
    }

    @Test("after a split the editor draws TWO notes and ONE contour run")
    func splitDrawsTwoNotesOverOneMeasuredRun() {
        let (model, _) = oneNote()
        let parent = model.seedTable.segments[0]
        let cut = (parent.startSeconds + parent.endSeconds) / 2
        var left = parent
        left.endSeconds = cut
        let right = NoteSegment(startSeconds: cut, endSeconds: parent.endSeconds,
                                detectedHz: parent.detectedHz,
                                detectedConfidence: parent.detectedConfidence)
        model.syncStoredNoteTable(PitchEditSet(segments: [left, right]))

        #expect(model.blobs.count == 2)
        // ⛔⛔ THE POINT OF THE WHOLE SEPARATION: the MEASUREMENT is still one
        // unbroken run. A contour split at the cut would draw a hole where the
        // singer never stopped — §5.5.1's lie with its sign reversed.
        #expect(model.contourRuns.count == 1)
        #expect(model.contourSegments.count == 1)
        // The frames are divided between the two notes, none lost, none doubled.
        #expect(model.blobs[0].frameCount + model.blobs[1].frameCount == 60)
        #expect(model.blobs[0].frameCount > 0 && model.blobs[1].frameCount > 0)
    }

    @Test("the tool palette offers exactly the tools that work, and each says what it does")
    func paletteOffersOnlyWorkingTools() {
        // ⚠️ FOUR, not the reference app's nine (design §7.2): slots that do
        // nothing when pressed are one fake affordance multiplied. C5a-4b added
        // Wobble and W7-NTU U3 added Voice — working tools — and NO Drift or
        // Shape placeholder beside them.
        #expect(PitchEditorTool.allCases.count == 4)
        #expect(PitchEditorTool.allCases.map(\.rawValue) == ["pointer", "scissors", "wobble", "voice"])
        for tool in PitchEditorTool.allCases {
            #expect(!tool.label.isEmpty)
            #expect(tool.help.count > 20, "a tool's help must be a sentence, not a word")
            #expect(!tool.symbolName.isEmpty)
        }
        #expect(PitchEditorTool.pointer.help.contains("⌥"))
        #expect(PitchEditorTool.voice.help.contains("⌥"))
    }

    // MARK: - I3 — the cut line (interaction batch §6)
    //
    // ⭐⭐ ONE VERDICT, TWO READERS. The view draws `cutLine(at:)`; the knife is
    // `splitNote(at:)`; both read `cutVerdict(at:)`. The agreement test compares
    // the knife with THE VIEW'S OWN ENTRY POINT (`cutLine(at:)?.verdict`), never
    // with `cutVerdict` directly: a second floor planted on the preview path
    // alone is invisible to a test that never calls the preview path.

    /// The click's refusal, WORD FOR WORD as it read before I3. The hover's amber
    /// is a prediction; the click is unchanged (design §6), so this sentence is
    /// pinned exactly rather than by the two fragments the older test checks.
    private static let tooCloseSentence = "That is too close to the edge of the note. Each half "
        + "has to be at least 60 milliseconds long — zoom in and click nearer the middle."

    @Test("the cut verdict truth table — inside a note, each edge ± the 60 ms floor, off the note, and inside the hit slop")
    func cutVerdictTruthTable() {
        let (model, _) = oneNote()
        let floor = PitchAutoCorrect.minimumNoteSeconds
        #expect(floor == 0.06, "this title's 60 ms is that constant; if it moved, retitle the test")
        let blob = model.blobs[0]
        let rect = model.rect(for: blob)
        let slop = PitchEditorModel.hitSlop
        // 1 ms either side of the floor, never ON it: x ↔ second does not
        // round-trip exactly on the awkward clip, so a row placed exactly at the
        // boundary would test the float, not the rule.
        let margin = 0.001
        func x(_ second: Double) -> CGFloat { model.geometry.x(forSourceSecond: second) }
        func knife(_ x: CGFloat) -> Double { model.geometry.sourceSecond(forX: x) }

        // 1. The middle of the note: a cut, with both halves measured exactly.
        // Hand-computed: the note is 60 frames from 0.30 s, i.e. [0.30, 1.26),
        // so its middle is 0.78 s and each half is 480 ms.
        let midX = x((blob.startSeconds + blob.endSeconds) / 2)
        let midSecond = knife(midX)
        let mid = model.cutVerdict(at: CGPoint(x: midX, y: rect.midY))
        #expect(mid == .cut(segmentID: blob.id, atSourceSecond: midSecond,
                            leftMs: (midSecond - blob.startSeconds) * 1000,
                            rightMs: (blob.endSeconds - midSecond) * 1000))
        #expect(mid.label == "Cut · 480 ms | 480 ms")
        #expect(mid.key == "cut")

        // 2–3. The START edge ± the floor.
        let inStartX = x(blob.startSeconds + floor + margin)
        guard case .cut(let inStartID, _, let inStartLeft, _) =
                model.cutVerdict(at: CGPoint(x: inStartX, y: rect.midY)) else {
            Issue.record("61 ms from the start must be a cut")
            return
        }
        #expect(inStartID == blob.id)
        #expect(close(inStartLeft, (floor + margin) * 1000, 1e-6))
        let outStartX = x(blob.startSeconds + floor - margin)
        let outStart = model.cutVerdict(at: CGPoint(x: outStartX, y: rect.midY))
        #expect(outStart == .tooCloseToEdge(segmentID: blob.id, atSourceSecond: knife(outStartX),
                                            minimumMs: floor * 1000))
        #expect(outStart.label == "Too close to the edge")
        #expect(outStart.key == "tooCloseToEdge")

        // 4–5. The END edge ± the floor.
        let inEndX = x(blob.endSeconds - floor - margin)
        guard case .cut(_, _, _, let inEndRight) =
                model.cutVerdict(at: CGPoint(x: inEndX, y: rect.midY)) else {
            Issue.record("61 ms from the end must be a cut")
            return
        }
        #expect(close(inEndRight, (floor + margin) * 1000, 1e-6))
        let outEndX = x(blob.endSeconds - floor + margin)
        #expect(model.cutVerdict(at: CGPoint(x: outEndX, y: rect.midY))
                == .tooCloseToEdge(segmentID: blob.id, atSourceSecond: knife(outEndX),
                                   minimumMs: floor * 1000))

        // 6. Off the note entirely.
        let off = model.cutVerdict(at: CGPoint(x: midX, y: rect.midY + 200))
        #expect(off == .noNote)
        #expect(off.label == nil)
        #expect(off.key == "noNote")
        #expect(off.segmentID == nil && off.atSourceSecond == nil)

        // 7–8. INSIDE the vertical hit slop the note is still hit — the same
        // verdict as the middle; one point past it, nothing is.
        #expect(model.cutVerdict(at: CGPoint(x: midX, y: rect.minY - (slop - 1))) == mid)
        #expect(model.cutVerdict(at: CGPoint(x: midX, y: rect.minY - (slop + 1))) == .noNote)

        // 9–11. INSIDE the horizontal slop, but outside the note's time span, a
        // "half" would be NEGATIVE: that is too close to the edge, never a cut
        // and never "no note". One point past the slop, nothing is hit.
        let beforeStart = model.cutVerdict(at: CGPoint(x: rect.minX - (slop - 1), y: rect.midY))
        #expect(beforeStart.key == "tooCloseToEdge")
        #expect(beforeStart.segmentID == blob.id)
        #expect(model.cutVerdict(at: CGPoint(x: rect.maxX + (slop - 1), y: rect.midY)).key
                == "tooCloseToEdge")
        #expect(model.cutVerdict(at: CGPoint(x: rect.minX - (slop + 1), y: rect.midY)) == .noNote)
    }

    @Test("⭐ the hover line and the knife agree at 200 points — a split exactly where the line says cut, at the same second")
    func cutLineAndKnifeAgree() {
        let (model, sink) = oneNote()
        model.tool = .scissors
        let blob = model.blobs[0]
        let rect = model.rect(for: blob)
        func x(_ second: Double) -> CGFloat { model.geometry.x(forSourceSecond: second) }

        var points: [CGPoint] = []
        // 120 points hugging the two edges in 2 ms steps, from 20 ms outside the
        // note to 98 ms inside it. DENSE ACROSS THE FLOOR ON PURPOSE: a preview
        // with its own 50 ms floor disagrees with the knife at five of these per
        // edge, and a sparse sweep would step straight over that band.
        for k in 0..<60 {
            let offset = -0.020 + Double(k) * 0.002
            points.append(CGPoint(x: x(blob.startSeconds + offset), y: rect.midY))
            points.append(CGPoint(x: x(blob.endSeconds - offset), y: rect.midY))
        }
        // 60 points across the whole note and past both ends, 3 pt above its top
        // edge — inside the hit slop, where "on the note" is decided by the slop.
        for k in 0..<60 {
            let fraction = CGFloat(k) / 59
            points.append(CGPoint(x: rect.minX - 8 + (rect.width + 16) * fraction, y: rect.minY - 3))
        }
        // 20 points well below the note: nothing to cut there.
        for k in 0..<20 {
            points.append(CGPoint(x: rect.minX + rect.width * CGFloat(k) / 19, y: rect.maxY + 40))
        }
        #expect(points.count == 200)

        var tally: [String: Int] = [:]
        for point in points {
            guard let line = model.cutLine(at: point) else {
                Issue.record("Split is live over a ready surface, so a line must be drawn at \(point)")
                continue
            }
            // Drawn where the pointer is, naming the second the knife would use.
            #expect(line.x == point.x)
            #expect(line.sourceSecond == model.geometry.sourceSecond(forX: point.x))
            tally[line.verdict.key, default: 0] += 1

            let before = sink.commits.count
            let commit = model.splitNote(at: point)
            switch line.verdict {
            case .cut(let segmentID, let second, _, _):
                #expect(commit?.kind == .splitNote(segmentID: segmentID, atSourceSecond: second),
                        "the line said cut at \(point) and the knife did not cut there, at that second")
                #expect(sink.commits.count == before + 1)
                #expect(model.refusal == nil)
            case .tooCloseToEdge:
                #expect(commit == nil, "the line said too close at \(point) and the knife cut anyway")
                #expect(sink.commits.count == before)
                #expect(model.refusal == Self.tooCloseSentence)
            case .noNote:
                #expect(commit == nil, "the line said no note at \(point) and the knife cut anyway")
                #expect(sink.commits.count == before)
                #expect(model.refusal == "Nothing to cut there. Click on one of the notes.")
            }
        }
        // ANTI-VACUITY: every verdict really occurred, often enough to mean
        // something, and the knife cut exactly as many times as the line said so.
        #expect((tally["cut"] ?? 0) >= 60, "tally \(tally)")
        #expect((tally["tooCloseToEdge"] ?? 0) >= 40, "tally \(tally)")
        #expect((tally["noNote"] ?? 0) >= 20, "tally \(tally)")
        #expect(sink.commits.count == (tally["cut"] ?? 0))
    }

    @Test("the cut line is drawn only while Split is engaged over notes, and the pointer is the crosshair exactly then")
    func cutLineAppearsOnlyWhileSplitIsLive() {
        let (model, _) = oneNote()
        let rect = model.rect(for: model.blobs[0])
        let onNote = CGPoint(x: rect.midX, y: rect.midY)
        let offNote = CGPoint(x: rect.midX, y: rect.maxY + 40)

        // The Move tool: no line, and no special pointer.
        #expect(model.tool == .pointer)
        #expect(model.cutLine(at: onNote) == nil)
        #expect(model.surfaceCursor == nil)

        // Split: a line anywhere on the surface. Over a note it carries that
        // note's drawn rect (for the glowing segment); off one it is the dim
        // hairline alone — no rect, no words.
        model.tool = .scissors
        #expect(model.surfaceCursor == .crosshair)
        let on = model.cutLine(at: onNote)
        #expect(on?.noteRect == rect)
        #expect(on?.verdict.key == "cut")
        let off = model.cutLine(at: offNote)
        #expect(off != nil)
        #expect(off?.verdict == .noNote)
        #expect(off?.noteRect == nil)
        #expect(off?.verdict.label == nil)
        // No pointer on the surface, no line.
        #expect(model.cutLine(at: nil) == nil)

        // A surface drawing no notes: the knife ignores a click there
        // (`dragEnded` guards `drawsNotes`), so the line must not offer one.
        let empty = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        empty.tool = .scissors
        #expect(!empty.state.drawsNotes)
        #expect(empty.cutLine(at: onNote) == nil)
        #expect(empty.surfaceCursor == nil)
    }

    @Test("the cut label sits above the note, drops below it at the top edge, and never leaves the content")
    func cutLabelNeverClips() {
        let label = CGSize(width: 120, height: 14)
        let content = CGSize(width: 600, height: 300)
        let id = UUID()
        let cut = PitchEditorCutVerdict.cut(segmentID: id, atSourceSecond: 1, leftMs: 240, rightMs: 310)
        func line(x: CGFloat, noteTop: CGFloat) -> PitchEditorCutLine {
            PitchEditorCutLine(x: x, sourceSecond: 1, verdict: cut,
                               noteRect: CGRect(x: 0, y: noteTop, width: 600, height: 11))
        }
        let overhang = PitchEditorCutLine.segmentOverhang
        let gap = PitchEditorCutLine.labelGap

        // Mid-surface: centred on the line, just above the glowing segment.
        let mid = line(x: 300, noteTop: 150).labelFrame(labelSize: label, contentSize: content)
        #expect(mid?.midX == 300)
        #expect(mid?.maxY == 150 - overhang - gap)

        // ⭐ At the TOP EDGE there is no room above, so it drops below the
        // segment instead of clipping (the orchestrator's ruling on §6).
        let top = line(x: 300, noteTop: 2).labelFrame(labelSize: label, contentSize: content)
        #expect(top?.minY == 2 + 11 + overhang + gap)
        // POSITIVE CONTROL for that branch: one row lower, the label fits above.
        let roomy = line(x: 300, noteTop: 30).labelFrame(labelSize: label, contentSize: content)
        #expect(roomy?.maxY == 30 - overhang - gap)

        // Near either end of the clip it is clamped inside, never cut off.
        #expect(line(x: 10, noteTop: 150).labelFrame(labelSize: label, contentSize: content)?.minX == 0)
        #expect(line(x: 595, noteTop: 150).labelFrame(labelSize: label, contentSize: content)?.maxX == 600)

        // `.noNote` has nothing to place.
        let bare = PitchEditorCutLine(x: 300, sourceSecond: 1, verdict: .noNote, noteRect: nil)
        #expect(bare.labelFrame(labelSize: label, contentSize: content) == nil)
        #expect(bare.segmentSpan(contentHeight: 300) == nil)

        // And the words are §6's, verbatim.
        #expect(cut.label == "Cut · 240 ms | 310 ms")
        #expect(PitchEditorCutVerdict.tooCloseToEdge(segmentID: id, atSourceSecond: 1,
                                                     minimumMs: 60).label == "Too close to the edge")
        #expect(PitchEditorCutVerdict.noNote.label == nil)
    }

    // MARK: - I6a — ESCAPE on the pane (the seam I4 filled)

    /// ⚠️ **REWRITTEN AT I4, ON PURPOSE** — it was `escapeAsksTheAppDecisionOnce`
    /// ("Escape on the pane asks the app's one decision exactly once and hands
    /// back its answer (the I4 seam)"), whose last leg pinned that a press
    /// during a live drag went straight to the app and LEFT THE DRAG ALONE, and
    /// said I4 would change it. The seam now hands the app the pane's two facts
    /// and applies the rung that comes back.
    @Test("Escape on the pane hands the app's ladder its two facts once, and applies the rung it gets back (I4 fills the seam)")
    func escapeAppliesTheLaddersRung() {
        let (model, sink, ids) = fourNotes()
        var asked: [(gestureLive: Bool, hasSelection: Bool)] = []
        func answer(_ rung: EditorEscapeRung) -> (Bool, Bool) -> EditorEscapeRung {
            { live, selected in
                asked.append((live, selected))
                return rung
            }
        }
        // Idle, nothing selected: `.pass` is handed back as "not consumed", so
        // the key keeps propagating.
        #expect(!model.handleEscapeKey(appDecision: answer(.pass)))
        // `.exitMaximize` is the APP's rung (it already applied it): consumed,
        // and nothing in the pane moves.
        model.selectOnly(ids[0])
        #expect(model.handleEscapeKey(appDecision: answer(.exitMaximize)))
        #expect(model.selection == [ids[0]])
        // `.clearSelection` is the pane's: the selection goes.
        #expect(model.handleEscapeKey(appDecision: answer(.clearSelection)))
        #expect(model.selection.isEmpty)

        // `.cancelGesture` mid-drag: the draft is dropped UNCOMMITTED, the
        // selection is kept (cancelling a drag is not deselecting), and the rest
        // of THAT gesture does nothing — the press is abandoned, not forgotten.
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        let onA = centre(of: model.blobs[0], in: model)
        let up = CGPoint(x: onA.x, y: onA.y - 28)
        _ = model.trackPress(start: onA, location: onA, modifiers: .none)
        #expect(model.trackPress(start: onA, location: up, modifiers: .none).didPromote)
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -28, free: false)
        #expect(model.drag != nil)
        #expect(model.escapeGestureLive)
        #expect(model.handleEscapeKey(appDecision: answer(.cancelGesture)))
        #expect(model.drag == nil)
        #expect(model.draftPlayedLine == nil)
        #expect(!model.escapeGestureLive)
        #expect(model.selection == [ids[0], ids[1]])
        let later = model.trackPress(start: onA, location: CGPoint(x: onA.x, y: onA.y - 42),
                                     modifiers: .none)
        #expect(!later.isFirst)
        #expect(model.drag == nil, "a tick after the cancel restarted the drag")
        #expect(model.releasePress(start: onA, location: up, modifiers: .none) == .nothing)
        #expect(model.endPitchDrag() == nil)
        #expect(sink.commits.isEmpty)

        // ONE question per press, carrying the pane's OWN two facts.
        #expect(asked.map(\.gestureLive) == [false, false, false, true])
        #expect(asked.map(\.hasSelection) == [false, true, true, true])
    }

    @Test("I4 — three presses walk the REAL ladder: the drag is cancelled, then the selection cleared, then the mode left")
    func escapeWalksTheRealLadder() {
        let (model, sink, _) = fourNotes()
        var maximized = true
        // The app's half, played by the real rule: it applies `.exitMaximize`
        // itself and hands the rung back (`AppModel.handleEditorEscape`).
        let app: (Bool, Bool) -> EditorEscapeRung = { live, selected in
            let rung = EditorEscapeLadder.resolve(gestureLive: live, hasSelection: selected,
                                                  maximized: maximized, blocked: false)
            if rung == .exitMaximize { maximized = false }
            return rung
        }
        model.selectAll()
        #expect(model.beginSelectionPitchDrag(on: model.blobs[1]))
        model.updatePitchDrag(translationHeight: -14, free: false)

        #expect(model.handleEscapeKey(appDecision: app))      // 1 — the drag
        #expect(model.drag == nil)
        #expect(model.selection.count == 4)
        #expect(maximized)
        #expect(model.handleEscapeKey(appDecision: app))      // 2 — the selection
        #expect(model.selection.isEmpty)
        #expect(maximized, "the mode was left while notes were still selected")
        #expect(model.handleEscapeKey(appDecision: app))      // 3 — the mode
        #expect(!maximized)
        #expect(!model.handleEscapeKey(appDecision: app))     // 4 — nothing left: the key propagates
        #expect(sink.commits.isEmpty)
    }

    // MARK: - I0 — the press seam (the router's model half)

    /// The pure router and tracker are `PitchEditorGestureRouterTests`' (a
    /// nonisolated suite). This leg pins only the MODEL's wiring of them: the
    /// tool the press asks with is the model's own, the hit is `blob(at:)`, a
    /// surface drawing no notes is inert, the release is recorded, and a new
    /// press drops a draft a lost `onEnded` stranded.
    @Test("I0 — a press routes on the model's tool and the note under it; a new press drops a stranded draft")
    func pressSeamRoutesOnTheModelsToolAndBlob() {
        // Inert first: a model that has analysed nothing draws no notes.
        let bare = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        let bareTick = bare.trackPress(start: CGPoint(x: 10, y: 10), location: CGPoint(x: 10, y: 10),
                                       modifiers: .none)
        #expect(bareTick.kind == PitchEditorPressKind.none)
        #expect(bare.releasePress(start: CGPoint(x: 10, y: 10), location: CGPoint(x: 10, y: 10),
                                  modifiers: .none) == .nothing)
        #expect(bare.lastRelease == .nothing)

        let (model, sink) = oneNote()
        let blob = model.blobs[0]
        let onNote = CGPoint(x: model.rect(for: blob).midX, y: model.rect(for: blob).midY)
        #expect(model.pressHit(at: onNote) == .note(blob.id))
        // POSITIVE CONTROL for the hit: far above every row is empty surface.
        let offNote = CGPoint(x: onNote.x, y: onNote.y - 20 * model.geometry.rowHeight)
        #expect(model.pressHit(at: offNote) == .empty)

        // Move tool on the note: a note drag; released in place, a plain click.
        #expect(model.trackPress(start: onNote, location: onNote, modifiers: .none).kind == .noteDrag(blob.id))
        #expect(model.releasePress(start: onNote, location: onNote, modifiers: .none)
                == .click(.selectOnly(blob.id)))
        #expect(model.lastRelease == .click(.selectOnly(blob.id)))

        // The model's TOOL is what the press asks with.
        model.tool = .scissors
        #expect(model.trackPress(start: onNote, location: onNote, modifiers: .none).kind == .cut)
        #expect(model.releasePress(start: onNote, location: onNote, modifiers: .none) == .cut(at: onNote))
        model.tool = .pointer

        // A stranded draft: a drag whose release never arrived.
        #expect(model.beginPitchDrag(on: blob))
        model.updatePitchDrag(translationHeight: -14, free: false)
        #expect(model.drag != nil)
        // The NEXT gesture's first tick drops it — on empty surface, where no
        // new drag will begin, so only the drop can clear it.
        let fresh = model.trackPress(start: offNote, location: offNote, modifiers: .none)
        #expect(fresh.isFirst)
        #expect(model.drag == nil, "a stranded draft survived a new press and would take its ticks")
        #expect(model.draftPlayedLine == nil)
        // A LATER tick of that gesture drops nothing (there is nothing), and no
        // commit happened anywhere in this leg.
        #expect(!model.trackPress(start: offNote, location: offNote, modifiers: .none).isFirst)
        #expect(sink.commits.isEmpty)
    }


    // MARK: - I4 — note selection, the band, the group drag (interaction batch §7)

    /// Four notes, one per voiced run, rising A3 · B3 · C4 · D4 (midi 57, 59,
    /// 60, 62): 20 frames (0.32 s) each, 10 unvoiced frames (0.16 s) between —
    /// a hole ends a note (§5.5.1), so the table has exactly four. All inside
    /// the awkward clip's source window [0.25, 2.75). The window auto-fits to
    /// 53…66 (the span padded by four), so every clamp below is derivable by
    /// hand: D has 4 semitones of room above it, A has 4 below.
    private func fourNotes(clipID: UUID = UUID()) -> (model: PitchEditorModel, sink: Box, ids: [UUID]) {
        let midis: [Double] = [57, 59, 60, 62]
        var frames: [ClipPitchFrame] = []
        var start = 0.30
        for (index, midi) in midis.enumerated() {
            frames += voiced(count: 20, from: start, hz: 440 * pow(2, (midi - 69) / 12))
            start += 20 * Self.framePeriod
            if index < midis.count - 1 {
                frames += unvoiced(count: 10, from: start)
                start += 10 * Self.framePeriod
            }
        }
        let model = PitchEditorModel(clipID: clipID, geometry: awkwardGeometry())
        model.apply(detection(frames))
        let sink = Box()
        model.onCommit = { sink.commits.append($0) }
        return (model, sink, model.blobs.map(\.id))
    }

    private func centre(of blob: NoteBlob, in model: PitchEditorModel) -> CGPoint {
        let rect = model.rect(for: blob)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    /// A point on EMPTY surface: A's column, three semitones above the top
    /// note. Asserted empty, so a fixture change cannot quietly aim it at a note.
    private func emptyPoint(_ model: PitchEditorModel) -> CGPoint {
        let point = CGPoint(x: model.rect(for: model.blobs[0]).midX, y: model.geometry.y(forMidi: 65))
        #expect(model.pressHit(at: point) == .empty)
        return point
    }

    /// A press released where it began — the CLICK I0 routes.
    @discardableResult
    private func click(_ model: PitchEditorModel, at point: CGPoint,
                       _ chord: ArrangeClickModifiers = .none) -> PitchEditorReleaseAction {
        _ = model.trackPress(start: point, location: point, modifiers: chord)
        return model.releasePress(start: point, location: point, modifiers: chord)
    }

    /// Counts observable writes of one bridge property — the
    /// `AvailabilityFlipRecorder` idiom (`CrashRecoveryTests`): every write is
    /// synchronous on the main actor, so re-arming from the notification counts
    /// a back-to-back sequence exactly.
    @MainActor final class WriteRecorder {
        private(set) var writes = 0
        private let read: @MainActor () -> Void

        init(_ read: @escaping @MainActor () -> Void) {
            self.read = read
            arm()
        }

        private func arm() {
            withObservationTracking {
                read()
            } onChange: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.writes += 1
                    self.arm()
                }
            }
        }
    }

    @Test("I4 — the four-note fixture draws four notes on a hand-derivable 53…66 window, nothing selected")
    func fourNoteFixtureIsWhatItSays() {
        let (model, _, ids) = fourNotes()
        #expect(model.blobs.count == 4)
        #expect(Set(ids).count == 4)
        for (blob, midi) in zip(model.blobs, [57.0, 59, 60, 62]) {
            #expect(close(blob.centreMidi, midi, 1e-6), "centre \(blob.centreMidi), expected \(midi)")
        }
        #expect(model.geometry.midiRange == 53...66)
        #expect(model.selection.isEmpty)
        #expect(model.selectionSummary == nil)
    }

    @Test("I4 — a click acts on the house click table: plain selects only, ⇧/⌘ toggle, plain on empty deselects, ⇧ on empty changes nothing, ⌘ on empty seeks once (I5) and keeps the selection")
    func clickActsOnTheHouseClickTable() {
        // (chord, target note by index — nil is empty surface, expected
        // selection by index) with B already selected. The literal column is
        // the brief's words; the table (`PianoRollGridPress.release`) is also
        // asserted as the answer, so neither can drift alone.
        // I5 — the last column is how many seeks the click asked for: only ⌘ on
        // empty places the playhead, and it still keeps the selection.
        let rows: [(chord: ArrangeClickModifiers, target: Int?, expected: Set<Int>, seeks: Int)] = [
            (.none, 0, [0], 0),          // plain on A: A alone
            (.none, 1, [1], 0),          // plain on the selected B: B alone
            (.shift, 0, [0, 1], 0),      // ⇧ on A: added
            (.command, 0, [0, 1], 0),    // ⌘ on A: added — ⇧ and ⌘ both mean toggle
            (.shift, 1, [], 0),          // ⇧ on B: taken out
            (.command, 1, [], 0),        // ⌘ on B: taken out
            (.none, nil, [], 0),         // plain on empty: deselect
            (.shift, nil, [1], 0),       // ⇧ on empty: nothing
            (.command, nil, [1], 1),     // ⌘ on empty: seeks (I5), selection kept
        ]
        for row in rows {
            let (model, sink, ids) = fourNotes()
            var seeks: [Double] = []
            model.onSeek = { seeks.append($0) }
            model.selectOnly(ids[1])
            let point = row.target.map { centre(of: model.blobs[$0], in: model) } ?? emptyPoint(model)
            let action = click(model, at: point, row.chord)
            let label = "chord \(row.chord.rawValue) on \(row.target.map { "note \($0)" } ?? "empty")"
            #expect(action == .click(PianoRollGridPress.release(noteID: row.target.map { ids[$0] },
                                                                modifiers: row.chord)), "\(label)")
            #expect(model.selection == Set(row.expected.map { ids[$0] }), "\(label)")
            #expect(model.drag == nil, "\(label): a click began a drag")
            #expect(sink.commits.isEmpty, "\(label): a click committed")
            #expect(seeks.count == row.seeks, "\(label): \(seeks.count) seeks, expected \(row.seeks)")
            if row.seeks == 1 {
                #expect(seeks.first == model.placementBeat(atContentX: point.x, snapBypassed: false),
                        "\(label): the seek must carry the placement at the click's x")
            }
        }
    }

    // MARK: - I5 — the playhead (interaction batch §8)

    /// A clip that starts OFF the 1/16 grid (beat 3.1), 8 beats long, at 40 pt
    /// per beat — a 1/16 (0.25 beat) is 10 pt, and a snap applied in PROJECT
    /// space lands on a different line than one applied in clip-local space.
    /// That is the whole reason for the 3.1: on a grid-aligned start the two
    /// orders agree and the truth table below could not tell them apart.
    /// (3.1 is also off a BAR line — the song's bar 2 starts 0.9 beats in.)
    private func offGridPlacementModel(appSnap: ClipSnap = .beat) -> PitchEditorModel {
        let tempo = try! TempoMap(segments: [.init(startBeat: 0, bpm: 120)])
        let geometry = PitchEditorGeometry(sourceWindowStartSeconds: 0, sourceWindowSeconds: 4,
                                           startBeat: 3.1, lengthBeats: 8, tempoMap: tempo,
                                           pixelsPerBeat: 40)
        let model = PitchEditorModel(clipID: UUID(), geometry: geometry)
        model.appSnap = appSnap
        return model
    }

    /// ⚠️⚠️ **RESTATED, NOT DELETED — I5-F1 (2026-09-25) MOVED THE SNAP TO THE
    /// SONG'S GRID.** I5 pinned a CLIP-LOCAL 1/16 here, to match a ruler
    /// numbered from the clip's first beat; that ruler named a different bar
    /// from the transport for any vocal not starting on a bar line, and the
    /// ruler now numbers the song's bars (`PitchEditorSongRuler`). Every row
    /// that moved says what the clip-local snap gave, so the table still tells
    /// the two apart — the 3.1 start is what makes them differ.
    @Test("I5-F1 — placement truth table: snap on/off, ⌥, clamp to the clip, x 0 is the clip start, snapped on the SONG's 1/16 (never clip-local)")
    func placementTruthTable() {
        // (app snap, content x, ⌥, expected PROJECT beat). Hand-derived: project
        // beat = 3.1 + x / 40; the grid is 0.25 SONG beats from beat 0; the clip
        // spans [3.1, 11.1] and the clamp wins at its edges.
        let rows: [(snap: ClipSnap, x: CGFloat, bypass: Bool, expected: Double, why: String)] = [
            (.beat, 0, false, 3.1, "x 0: 3.1 snaps to 3.0, outside the clip, and clamps back to its start"),
            (.beat, 0, true, 3.1, "x 0 is the clip's start, snap bypassed"),
            (.beat, 57, false, 4.5, "4.525 → 4.5 on the song's 1/16 (the clip-local snap gave 4.6)"),
            (.beat, 44, false, 4.25, "4.2 → 4.25, rounding up (the clip-local snap gave 4.1)"),
            (.beat, 36, false, 4.0, "the song's bar 2 line, 0.9 beats in (the clip-local snap gave 4.1)"),
            (.beat, 57, true, 4.525, "⌥: unsnapped"),
            (.off, 57, false, 4.525, "app snap OFF: unsnapped"),
            (.bar, 57, false, 4.5, "the app's DIVISION never follows: a bar snap still lands on 1/16"),
            (.beat, 319, false, 11.0, "11.075 → 11.0, inside the clip (the clip-local snap gave 11.1)"),
            (.beat, -40, false, 3.1, "left of the clip clamps to its start"),
            (.beat, 1000, false, 11.1, "right of the clip clamps to its end"),
            (.off, 1000, false, 11.1, "the clamp holds with snap off"),
        ]
        for row in rows {
            let model = offGridPlacementModel(appSnap: row.snap)
            let beat = model.placementBeat(atContentX: row.x, snapBypassed: row.bypass)
            #expect(close(beat, row.expected, 1e-9), "\(row.why): got \(beat), expected \(row.expected)")
        }
    }

    @Test("I5 — the placement grid: app snap OFF gives .off, every other app snap gives 1/16 — never the Simple .beat lock")
    func placementSnapFollowsOnlyTheAppSnapsOff() {
        #expect(PitchEditorModel.placementGrid == .sixteenth)
        for app in ClipSnap.allCases {
            let model = offGridPlacementModel(appSnap: app)
            #expect(model.placementSnap == (app == .off ? .off : .sixteenth), "app snap \(app)")
        }
    }

    @Test("I5 — seek spy: one seek per ruler tick carrying its placement; ⌘-click on empty seeks ONCE at the press START; nothing else seeks")
    func seekSpyCountsEveryPlacement() {
        let (model, sink, ids) = fourNotes()
        var seeks: [Double] = []
        model.onSeek = { seeks.append($0) }
        // The ruler's ticks: one seek each, each carrying the placement.
        let xs: [CGFloat] = [0, 37, 123.4]
        for x in xs { model.placePlayhead(atContentX: x, snapBypassed: false) }
        #expect(seeks == xs.map { model.placementBeat(atContentX: $0, snapBypassed: false) })
        // A ⌘-click that SLIPPED inside the slop: still a click, and it seeks once,
        // where the press BEGAN (the knife's rule).
        seeks.removeAll()
        let start = emptyPoint(model)
        let slipped = CGPoint(x: start.x + 3, y: start.y)   // under the 4 pt slop
        _ = model.trackPress(start: start, location: start, modifiers: .command)
        let action = model.releasePress(start: start, location: slipped, modifiers: .command,
                                        snapBypassed: true)
        #expect(action == .click(.positionPlayhead))
        #expect(seeks == [model.placementBeat(atContentX: start.x, snapBypassed: true)])
        #expect(model.placementBeat(atContentX: start.x, snapBypassed: true)
                != model.placementBeat(atContentX: slipped.x, snapBypassed: true),
                "positive control — the slip moves the unsnapped placement, so the line above tells START from END")
        // Nothing else seeks: plain and ⇧ on empty, ⌘ on a note, a travelled ⌘ band.
        seeks.removeAll()
        model.selectOnly(ids[0])
        click(model, at: start)
        #expect(model.selection.isEmpty, "plain on empty still deselects")
        click(model, at: start, .shift)
        click(model, at: centre(of: model.blobs[1], in: model), .command)
        let far = CGPoint(x: start.x + 40, y: start.y)
        _ = model.trackPress(start: start, location: start, modifiers: .command)
        _ = model.trackPress(start: start, location: far, modifiers: .command)
        #expect(model.releasePress(start: start, location: far, modifiers: .command) == .endBand)
        #expect(seeks.isEmpty, "\(seeks.count) seek(s) from presses that must not seek")
        #expect(sink.commits.isEmpty, "placing the playhead is never a note edit")
    }

    @Test("I5 — ⌘-click on a surface drawing NO notes does not seek (its press is inert); the ruler's path seeks in every state")
    func commandClickOnAnInertSurfaceDoesNotSeek() {
        let model = offGridPlacementModel()
        var seeks: [Double] = []
        model.onSeek = { seeks.append($0) }
        #expect(!model.state.drawsNotes, "precondition — a model that never loaded draws no notes")
        let point = CGPoint(x: 57, y: 20)
        #expect(model.pressHit(at: point) == .inert)
        #expect(click(model, at: point, .command) == .nothing)
        #expect(seeks.isEmpty)
        model.placePlayhead(atContentX: 57, snapBypassed: false)
        // I5-F1: the song's 1/16 (4.525 → 4.5); the clip-local snap gave 4.6.
        #expect(seeks.count == 1 && close(seeks[0], 4.5, 1e-9), "the ruler seeks here: \(seeks)")
    }

    @Test("I5-F1 — the ruler and the placement agree: a click on a song-bar tick lands the transport ON that bar (bar.beat \"n.1\"), and every snapped placement across the clip is on the song's 1/16 — never on the clip-local one")
    func placementLandsOnTheRulersBars() {
        let model = offGridPlacementModel()
        let meter = MeterMap(constant: TimeSignature())
        let ticks = PitchEditorSongRuler.ticks(clipStartBeat: model.geometry.startBeat,
                                               lengthBeats: model.geometry.lengthBeats,
                                               pixelsPerBeat: model.geometry.pixelsPerBeat,
                                               meterMap: meter)
        let bars = ticks.filter { $0.isBar && $0.label != nil }
        #expect(bars.map(\.label) == ["2", "3"], "song bars 2 and 3 lie inside 3.1…11.1")
        for tick in bars {
            let placed = model.placementBeat(atContentX: tick.x, snapBypassed: false)
            let transport = TransportState(positionBeats: placed)
            #expect(transport.barsBeatsDisplay == "\(tick.label ?? "?").1",
                    "a click on the \"\(tick.label ?? "?")\" tick placed the transport at \(transport.barsBeatsDisplay)")
        }
        var clipLocalHits = 0
        for step in 1..<300 {
            let x = CGFloat(step) * 1.05
            let beat = model.placementBeat(atContentX: x, snapBypassed: false)
            guard beat > 3.1 + 1e-9, beat < 11.1 - 1e-9 else { continue }   // the clamped edges
            #expect(abs(beat / 0.25 - (beat / 0.25).rounded()) < 1e-9, "x \(x) → \(beat), off the song's 1/16")
            if abs((beat - 3.1) / 0.25 - ((beat - 3.1) / 0.25).rounded()) < 1e-9 { clipLocalHits += 1 }
        }
        #expect(clipLocalHits == 0, "\(clipLocalHits) placement(s) landed on the clip-local grid")
    }

    @Test("I5 — the ⌘ affordance promises exactly what the click does: the bar over EMPTY surface with ⌘, never on a note, with ⇧, with the knife, or on an inert surface")
    func theCommandAffordanceMatchesTheClick() {
        let (model, _, _) = fourNotes()
        let empty = emptyPoint(model)
        let onNote = centre(of: model.blobs[1], in: model)
        // Each promise is checked against what the click then DOES.
        func clickSeeks(_ point: CGPoint, _ chord: ArrangeClickModifiers) -> Bool {
            var seeks = 0
            model.onSeek = { _ in seeks += 1 }
            click(model, at: point, chord)
            return seeks == 1
        }
        let rows: [(point: CGPoint, chord: ArrangeClickModifiers, promises: Bool, why: String)] = [
            (empty, [.command], true, "⌘ on empty"),
            (empty, [], false, "no chord on empty"),
            (empty, [.shift], false, "⇧ on empty"),
            (onNote, [.command], false, "⌘ on a note toggles it"),
        ]
        for row in rows {
            #expect(model.placesPlayhead(at: row.point, modifiers: row.chord) == row.promises, "\(row.why)")
            #expect(model.surfaceCursor(at: row.point, modifiers: row.chord)
                    == (row.promises ? .verticalBar : nil), "\(row.why): cursor")
            #expect(clickSeeks(row.point, row.chord) == row.promises, "\(row.why): the click disagrees")
        }
        // The knife is engaged: no promise, the crosshair stays.
        model.tool = .scissors
        #expect(!model.placesPlayhead(at: empty, modifiers: [.command]))
        #expect(model.surfaceCursor(at: empty, modifiers: [.command]) == .crosshair)
        // An inert surface promises nothing either.
        let inert = offGridPlacementModel()
        #expect(!inert.placesPlayhead(at: CGPoint(x: 57, y: 20), modifiers: [.command]))
        #expect(inert.surfaceCursor(at: CGPoint(x: 57, y: 20), modifiers: [.command]) == nil)
    }

    @Test("I4 — ⭐ a band touches exactly the notes a click at its corner would hit, probed INSIDE the hit slop")
    func bandHitsEqualClickHits() {
        let (model, _, _) = fourNotes()
        let slop = PitchEditorModel.hitSlop
        var hitsSeen = 0
        var missesSeen = 0
        for blob in model.blobs {
            let drawn = model.rect(for: blob)
            // The band's free corner sits `depth` above the note's DRAWN top,
            // and the band lies above-left of it, so it can reach the note only
            // through that corner. Two depths inside the slop, two outside —
            // never ON it, where "contains" and "overlaps" legitimately differ.
            for depth in [slop * 0.5, slop - 0.5, slop + 0.5, slop * 2] {
                let corner = CGPoint(x: drawn.midX, y: drawn.minY - depth)
                let origin = CGPoint(x: drawn.minX - 20, y: drawn.minY - 40)
                #expect(model.pressHit(at: origin) == .empty)
                let clickHits = model.blob(at: corner)?.id == blob.id
                _ = model.trackPress(start: origin, location: origin, modifiers: .none)
                #expect(model.trackPress(start: origin, location: corner, modifiers: .none).kind == .band)
                let bandHits = model.band?.hits.contains(blob.id) == true
                #expect(bandHits == clickHits,
                        "depth \(depth) above note \(blob.id): the click says \(clickHits), the band \(bandHits)")
                #expect(model.releasePress(start: origin, location: corner, modifiers: .none) == .endBand)
                #expect(model.band == nil)
                #expect(model.selection.contains(blob.id) == clickHits)
                if clickHits { hitsSeen += 1 } else { missesSeen += 1 }
            }
        }
        // ANTI-VACUITY: both answers were exercised, and the two hits per note
        // were INSIDE the slop but OUTSIDE the drawn rect — exactly where a band
        // reading the drawn rects (or any inset set) would disagree.
        #expect(hitsSeen == 8)
        #expect(missesSeen == 8)
    }

    @Test("I4 — a band REPLACES the selection, ⇧ UNIONS onto the frozen base, shrinking gives notes back, and Escape puts the base back")
    func bandSelectionRules() {
        let (model, sink, ids) = fourNotes()
        let rects = model.blobs.map { model.rect(for: $0) }
        let slop = PitchEditorModel.hitSlop
        // Top-left of everything, left of A's slop: empty surface.
        let origin = CGPoint(x: rects[0].minX - slop - 4, y: rects[3].minY - 20)
        #expect(model.pressHit(at: origin) == .empty)
        // Corners below every note, in the time gaps after A and after B.
        let bottom = rects[0].maxY + 20
        let afterA = (rects[0].maxX + rects[1].minX) / 2
        let afterB = (rects[1].maxX + rects[2].minX) / 2
        #expect(rects[0].maxX + slop < afterA && afterA < rects[1].minX - slop)
        #expect(rects[1].maxX + slop < afterB && afterB < rects[2].minX - slop)
        let coverA = CGPoint(x: afterA, y: bottom)
        let coverAB = CGPoint(x: afterB, y: bottom)

        // PLAIN, with D selected: the band REPLACES it.
        model.selectOnly(ids[3])
        _ = model.trackPress(start: origin, location: origin, modifiers: .none)
        _ = model.trackPress(start: origin, location: coverAB, modifiers: .none)
        #expect(model.band?.hits == [ids[0], ids[1]])
        #expect(model.band?.additive == false)
        #expect(model.selection == [ids[0], ids[1]])
        // Shrinking the band gives B back.
        _ = model.trackPress(start: origin, location: coverA, modifiers: .none)
        #expect(model.selection == [ids[0]])
        _ = model.trackPress(start: origin, location: coverAB, modifiers: .none)
        #expect(model.releasePress(start: origin, location: coverAB, modifiers: .none) == .endBand)
        #expect(model.band == nil)
        #expect(model.selection == [ids[0], ids[1]])

        // ⇧: UNION onto the base {D}; shrinking never takes D.
        model.selectOnly(ids[3])
        _ = model.trackPress(start: origin, location: origin, modifiers: .shift)
        _ = model.trackPress(start: origin, location: coverAB, modifiers: .shift)
        #expect(model.band?.additive == true)
        #expect(model.selection == [ids[0], ids[1], ids[3]])
        _ = model.trackPress(start: origin, location: coverA, modifiers: .shift)
        #expect(model.selection == [ids[0], ids[3]])
        #expect(model.releasePress(start: origin, location: coverA, modifiers: .shift) == .endBand)
        #expect(model.selection == [ids[0], ids[3]])

        // A plain band that touches NOTHING replaces with nothing — the roll's
        // rule, through the same `PianoRollMarquee.selection`.
        let emptyCorner = CGPoint(x: afterA, y: origin.y + 10)
        _ = model.trackPress(start: origin, location: origin, modifiers: .none)
        _ = model.trackPress(start: origin, location: emptyCorner, modifiers: .none)
        #expect(model.band?.hits.isEmpty == true)
        model.releasePress(start: origin, location: emptyCorner, modifiers: .none)
        #expect(model.selection.isEmpty)

        // ESCAPE MID-BAND: the base comes back, the band goes, and the rest of
        // the gesture does nothing.
        model.selectOnly(ids[3])
        _ = model.trackPress(start: origin, location: origin, modifiers: .none)
        _ = model.trackPress(start: origin, location: coverAB, modifiers: .none)
        #expect(model.selection == [ids[0], ids[1]])
        #expect(model.escapeGestureLive)
        model.cancelGestureForEscape()
        #expect(model.band == nil)
        #expect(model.selection == [ids[3]])
        _ = model.trackPress(start: origin, location: coverA, modifiers: .none)
        #expect(model.band == nil)
        #expect(model.selection == [ids[3]])
        #expect(model.releasePress(start: origin, location: coverA, modifiers: .none) == .nothing)
        #expect(model.selection == [ids[3]])
        #expect(sink.commits.isEmpty, "selecting is not editing")
    }

    @Test("I4 — ⭐ a group drag: forty ticks commit nothing, and the release commits ONE .notePitches carrying every moved note")
    func groupDragCommitsOnceForEveryNote() {
        let (model, sink, ids) = fourNotes()
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        model.toggle(ids[2])
        let token = model.selectionToken
        #expect(model.beginSelectionPitchDrag(on: model.blobs[1]))
        #expect(model.drag?.members.map(\.segmentID) == [ids[0], ids[2]])
        #expect(model.drag?.movingSegmentIDs == [ids[1], ids[0], ids[2]])
        #expect(model.selectionToken == token, "pressing a note already selected must not re-select anything")
        for tick in 1...40 {
            model.updatePitchDrag(translationHeight: -CGFloat(tick), free: false)
        }
        // ⛔ THE CADENCE, for N notes exactly as for one.
        #expect(sink.commits.isEmpty)
        #expect(model.commitCount == 0)
        // -40 pt at 14 pt/row is 2.857 semitones: B (59) snaps to 62, so the
        // landed delta is +3, and EVERY member takes it — intervals kept.
        #expect(close(model.drag!.offsetCents, 300, 1e-9))
        for member in model.drag!.members {
            #expect(close(member.offsetCents, 300, 1e-9))
        }
        let commit = model.endPitchDrag()
        #expect(sink.commits.count == 1)
        #expect(model.commitCount == 1)
        guard case .notePitches(let offsets, let committedToken)? = commit?.kind else {
            Issue.record("a group drag must commit ONE .notePitches, got \(String(describing: commit?.kind))")
            return
        }
        #expect(committedToken == token, "the undo key must name THIS selection (UI design §8.4)")
        #expect(offsets.map(\.segmentId) == [ids[0], ids[1], ids[2]], "table order, pressed note included")
        #expect(offsets.allSatisfy { close($0.offsetCents, 300, 1e-9) })
        #expect(!offsets.contains { $0.segmentId == ids[3] }, "D was never selected and must not be written")
        // The seed rides along, as for a one-note drag.
        #expect(sink.commits[0].seedIfAbsent.segments.map(\.id) == ids)
        #expect(model.drag == nil)
    }

    @Test("I4 — a group drag released where it began commits NOTHING")
    func groupNoOpCommitsNothing() {
        let (model, sink, ids) = fourNotes()
        model.selectOnly(ids[0])
        model.toggle(ids[3])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -30, free: false)
        model.updatePitchDrag(translationHeight: 0, free: false)
        #expect(model.endPitchDrag() == nil)
        #expect(sink.commits.isEmpty)
        // POSITIVE CONTROL: the same group, not returned home, commits once.
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -30, free: false)
        #expect(model.endPitchDrag() != nil)
        #expect(sink.commits.count == 1)
    }

    @Test("I4 — ⛔ the group clamp is the TIGHTEST member's: no moving note leaves the window, snapped or free, and the interval survives")
    func groupClampIsTheTightestMembers() {
        let (model, sink, ids) = fourNotes()
        let window = model.geometry.midiRange                       // 53…66
        model.selectOnly(ids[0])
        model.toggle(ids[3])                                        // A (57) and D (62)
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        func dTarget() -> Double { model.drag!.members[0].targetMidi(clipPitchShiftSemitones: 0) }

        // Twenty rows up. A alone could reach 65; D has only 66 − 62 = 4 of room.
        model.updatePitchDrag(translationHeight: -280, free: false)
        #expect(dTarget() <= window.upperBound, "D was pushed above the window — gone from view, saved to disk")
        #expect(close(model.drag!.offsetCents, 400, 1e-9))
        #expect(close(model.drag!.members[0].offsetCents, 400, 1e-9))
        // ⌥ stops at the same edge: it turns off the snap, not the window.
        model.updatePitchDrag(translationHeight: -280, free: true)
        #expect(close(dTarget(), window.upperBound, 1e-9))
        #expect(close(model.drag!.offsetCents, 400, 1e-9))
        // Down: now A is the tightest (57 − 53 = 4).
        model.updatePitchDrag(translationHeight: 280, free: false)
        #expect(close(model.drag!.targetMidi, window.lowerBound, 1e-9))
        #expect(close(model.drag!.offsetCents, -400, 1e-9))
        #expect(close(model.drag!.members[0].offsetCents, -400, 1e-9))
        // The INTERVAL between the two is what was sung: five semitones.
        #expect(close(dTarget() - model.drag!.targetMidi, 5, 1e-9))
        model.cancelDrag()
        #expect(sink.commits.isEmpty)

        // POSITIVE CONTROL: A ALONE, the same twenty rows up, goes to 65 (the
        // one-semitone inset under the top) — so the +400 above was D's room
        // talking, not a ceiling on every drag.
        model.selectOnly(ids[0])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        #expect(model.drag!.members.isEmpty)
        model.updatePitchDrag(translationHeight: -280, free: false)
        #expect(close(model.drag!.offsetCents, 800, 1e-9))
        model.cancelDrag()
    }

    @Test("I4 — a drag on a LONE note is the one-note drag, byte for byte: .notePitch, never .notePitches")
    func loneNoteDragIsTheOneNoteDrag() {
        // Through the selection path, on an unselected note…
        let (viaSelection, sinkA, ids) = fourNotes()
        #expect(viaSelection.beginSelectionPitchDrag(on: viaSelection.blobs[0]))
        #expect(viaSelection.selection == [ids[0]], "an unselected note is selected when its drag begins")
        #expect(viaSelection.drag!.members.isEmpty)
        #expect(viaSelection.draftSpans == [viaSelection.draftSpan!])
        viaSelection.updatePitchDrag(translationHeight: -18, free: false)
        _ = viaSelection.endPitchDrag()
        // …and through the pre-I4 entry point, on an identical fixture.
        let (direct, sinkB, _) = fourNotes()
        #expect(direct.beginPitchDrag(on: direct.blobs[0]))
        direct.updatePitchDrag(translationHeight: -18, free: false)
        _ = direct.endPitchDrag()
        #expect(sinkA.commits.count == 1)
        #expect(sinkB.commits.count == 1)
        guard case .notePitch(let idA, let centsA)? = sinkA.commits.first?.kind,
              case .notePitch(let idB, let centsB)? = sinkB.commits.first?.kind else {
            Issue.record("a lone-note drag must commit .notePitch")
            return
        }
        #expect(idA == ids[0])
        #expect(idB == direct.blobs[0].id)
        #expect(centsA == centsB)
        #expect(close(centsA, 100, 1e-9))
    }

    @Test("I4 — travel on an UNSELECTED note selects it first: alone with no chord, added with ⇧")
    func travelOnAnUnselectedNoteSelectsItFirst() {
        for chord in [ArrangeClickModifiers.none, .shift] {
            let (model, sink, ids) = fourNotes()
            model.selectOnly(ids[1])
            let onA = centre(of: model.blobs[0], in: model)
            let to = CGPoint(x: onA.x, y: onA.y - 14)
            _ = model.trackPress(start: onA, location: onA, modifiers: chord)
            let tick = model.trackPress(start: onA, location: to, modifiers: chord)
            #expect(tick.didPromote)
            #expect(tick.kind == .noteDrag(ids[0]))
            // What the view's `dragChanged` does on the promoting tick.
            #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
            model.updatePitchDrag(translationHeight: -14, free: false)
            #expect(model.releasePress(start: onA, location: to, modifiers: chord) == .endNoteDrag(ids[0]))
            _ = model.endPitchDrag()
            #expect(sink.commits.count == 1)
            if chord.isEmpty {
                #expect(model.selection == [ids[0]])
                guard case .notePitch(let id, let cents)? = sink.commits.first?.kind else {
                    Issue.record("a plain drag on an unselected note must move it ALONE")
                    continue
                }
                #expect(id == ids[0])
                #expect(close(cents, 100, 1e-9))
            } else {
                #expect(model.selection == [ids[0], ids[1]])
                guard case .notePitches(let offsets, _)? = sink.commits.first?.kind else {
                    Issue.record("a ⇧ drag on an unselected note must ADD it and move both")
                    continue
                }
                #expect(offsets.map(\.segmentId) == [ids[0], ids[1]])
                #expect(offsets.allSatisfy { close($0.offsetCents, 100, 1e-9) })
            }
        }
    }

    @Test("I4 — the draft line moves EVERY member, and the committed line leaves every member's stretch")
    func groupDraftLineCoversEveryMember() {
        let (model, _, ids) = fourNotes()
        model.selectOnly(ids[0])
        model.toggle(ids[2])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -14, free: false)
        // Two notes 0.64 s apart: two spans, neither merged into the other.
        let spans = model.draftSpans
        #expect(spans.count == 2)
        for blob in [model.blobs[0], model.blobs[2]] {
            let mid = (blob.startSeconds + blob.endSeconds) / 2
            #expect(spans.contains { $0.contains(mid) }, "note \(blob.id) has no draft span")
        }
        let untouched = (model.blobs[1].startSeconds + model.blobs[1].endSeconds) / 2
        #expect(!spans.contains { $0.contains(untouched) }, "B is not moving and must keep its line")
        // One draft piece per moving note, at least.
        #expect(model.draftLineSegments.count >= 2)
        // For ONE span the multi-span cut is the single-span cut, verbatim.
        #expect(model.playedLineSegments(excludingAll: [spans[0]])
                == model.playedLineSegments(excluding: spans[0]))
        #expect(model.playedLineSegments(excludingAll: []) == model.playedLineSegments(excluding: nil))
        model.cancelDrag()
        #expect(model.draftSpans.isEmpty)
    }

    @Test("I4 — the selection survives the store: the first commit's seed keeps its ids, a split's right half joins a selected parent, a vanished note is pruned")
    func selectionSurvivesTheStore() {
        // (1) THE FIRST COMMIT on a clip with no stored table: the store hands
        // the seed back VERBATIM (`noteTable(seedIfAbsent:)`), so the read-back
        // names the same ids — and a read-back that changed nothing selected
        // does not re-mint the token.
        let (model, _, ids) = fourNotes()
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        let token = model.selectionToken
        var echoed = model.seedTable
        echoed.segments[0].pitchOffsetCents = 100
        model.syncStoredNoteTable(echoed)
        #expect(model.storedTable != nil)
        #expect(model.selection == [ids[0], ids[1]])
        #expect(model.selectionToken == token)

        // (2) A SPLIT of a SELECTED note: the store keeps the parent's id on
        // the LEFT half and mints the right one — which joins the selection.
        let parent = echoed.segments[0]
        let cut = (parent.startSeconds + parent.endSeconds) / 2
        var split = echoed
        split.segments[0].endSeconds = cut
        let right = NoteSegment(startSeconds: cut, endSeconds: parent.endSeconds,
                                detectedHz: parent.detectedHz,
                                detectedConfidence: parent.detectedConfidence)
        split.segments.insert(right, at: 1)
        model.syncStoredNoteTable(split)
        #expect(model.blobs.count == 5)
        #expect(model.selection == [ids[0], right.id, ids[1]])
        #expect(model.selectionToken != token)

        // (3) A selected note that VANISHED from the table is pruned.
        var shrunk = split
        shrunk.segments.removeAll { $0.id == ids[1] }
        model.syncStoredNoteTable(shrunk)
        #expect(model.selection == [ids[0], right.id])

        // (2′) CONTROL: a split of an UNSELECTED note leaves its right half out.
        let (other, _, otherIDs) = fourNotes()
        other.selectOnly(otherIDs[1])
        var table = other.seedTable
        let head = table.segments[0]
        let otherCut = (head.startSeconds + head.endSeconds) / 2
        table.segments[0].endSeconds = otherCut
        table.segments.insert(NoteSegment(startSeconds: otherCut, endSeconds: head.endSeconds,
                                          detectedHz: head.detectedHz,
                                          detectedConfidence: head.detectedConfidence), at: 1)
        other.syncStoredNoteTable(table)
        #expect(other.blobs.count == 5)
        #expect(other.selection == [otherIDs[1]])
    }

    @Test("I4 — ⭐ OWED FROM I0: a click on a note drawn OFF the grid selects it and never retunes it")
    func clickOnAnOffGridNoteNeverRetunes() {
        // 226 Hz ≈ midi 57.47: between A3 and A#3, so any snap MOVES it.
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(voiced(count: 60, from: 0.30, hz: 226)))
        let sink = Box()
        model.onCommit = { sink.commits.append($0) }
        let blob = model.blobs[0]
        #expect(abs(blob.centreMidi - blob.centreMidi.rounded()) > 0.25,
                "the fixture must sit OFF the chromatic grid, or it cannot catch the old defect")
        let before = blob.offsetCents

        let action = click(model, at: centre(of: blob, in: model))
        #expect(action == .click(.selectOnly(blob.id)))
        #expect(sink.commits.isEmpty, "a CLICK retuned a note")
        #expect(model.commitCount == 0)
        #expect(model.blobs[0].offsetCents == before)
        #expect(model.selection == [blob.id])

        // POSITIVE CONTROL — the pre-I0 defect, replayed on the SAME note: a
        // zero-length drag SNAPS the drawn pitch and so commits a retune. If
        // this ever stops committing, the fixture no longer discriminates.
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: 0, free: false)
        let replay = model.endPitchDrag()
        #expect(sink.commits.count == 1)
        guard case .notePitch(_, let cents)? = replay?.kind else {
            Issue.record("the positive control did not commit — the fixture proves nothing")
            return
        }
        #expect(cents != 0)
    }

    @Test("I4 — ⌘A selects EVERY drawn note, replacing; the token re-mints on a real change only; the status line counts in words")
    func selectAllTokenAndSummary() {
        let (model, sink, ids) = fourNotes()
        let t0 = model.selectionToken
        model.selectOnly(ids[2])
        #expect(model.selectionSummary == "1 note selected")
        let t1 = model.selectionToken
        #expect(t1 != t0)
        model.selectOnly(ids[2])
        #expect(model.selectionToken == t1, "writing the same selection re-minted the token")
        model.selectAll()
        #expect(model.selection == Set(ids))
        #expect(model.selection.count == model.blobs.count)
        #expect(model.selectionSummary == "4 notes selected")
        let t2 = model.selectionToken
        #expect(t2 != t1)
        model.selectAll()
        #expect(model.selectionToken == t2)
        model.toggle(ids[0])
        #expect(model.selectionSummary == "3 notes selected")
        model.clearSelection()
        #expect(model.selectionSummary == nil)
        // A note this surface does not draw is never selected.
        model.selectOnly(UUID())
        model.toggle(UUID())
        #expect(model.selection.isEmpty)
        #expect(sink.commits.isEmpty, "selecting is not editing")
    }

    // MARK: - I7b — clear a note (interaction batch §10)

    /// The model's table with the given notes CLEARED, as the store would hand
    /// it back after `setClipNotesCleared` (the flag and nothing else).
    private func tableClearing(_ indices: [Int], of model: PitchEditorModel) -> PitchEditSet {
        var table = model.noteTable
        for index in indices { table.segments[index].isCleared = true }
        return table
    }

    /// ⚠️ REPLACES "I4 — ⌫ with notes selected is refused on the refusal line in
    /// the policy's words, removes nothing, keeps the selection"
    /// (`deleteWithNotesSelectedIsRefusedInWords`), retired with the refusal it
    /// pinned: I7b gives ⌫ its action (the user's `delete-clears = yes`).
    @Test("I7b — ⌫ with notes selected is ONE Clear commit carrying exactly the selected notes, in table order; nothing else moves")
    func deleteClearsTheSelectedNotesInOneCommit() {
        let (model, sink, ids) = fourNotes()
        // Three of four, selected out of order (D, then A, then C) — the commit
        // must still carry them in TABLE order.
        model.selectOnly(ids[3])
        model.toggle(ids[0])
        model.toggle(ids[2])
        let returned = model.performNoteAction(.clear)
        #expect(sink.commits.count == 1, "one gesture, one commit")
        #expect(model.commitCount == 1)
        guard case .notesCleared(let segmentIDs, let cleared)? = sink.commits.first?.kind else {
            Issue.record("⌫ committed \(String(describing: sink.commits.first?.kind)), not a clear")
            return
        }
        #expect(segmentIDs == [ids[0], ids[2], ids[3]])
        #expect(cleared)
        #expect(returned == sink.commits.first)
        // The FIRST edit on an untouched clip carries the editor's seed, so the
        // ids it names are the ids the store will hold.
        #expect(sink.commits.first?.seedIfAbsent == model.seedForCommit)
        // A clear is not a delete and not a deselect: every note is still drawn,
        // the selection stands, and no refusal is on screen.
        #expect(model.blobs.map(\.id) == ids)
        #expect(model.selection == Set([ids[0], ids[2], ids[3]]))
        #expect(model.refusal == nil)
    }

    @Test("I7b — ⌫ on notes that are ALL already cleared commits nothing and says so; a mix clears only the rest; Restore brings back only the cleared")
    func clearingClearedNotesSaysSoAndRestoreIsTheWayBack() {
        let (model, sink, ids) = fourNotes()
        model.syncStoredNoteTable(tableClearing([0, 1], of: model))
        #expect(model.blobs.map(\.isCleared) == [true, true, false, false])

        // ALL cleared: nothing committed, the line, pointing at Restore.
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        #expect(model.performNoteAction(.clear) == nil)
        #expect(sink.commits.isEmpty)
        #expect(model.refusal == "Those notes are already cleared. Right-click ▸ Restore brings them back.")
        // One note reads in the singular.
        model.selectOnly(ids[0])
        _ = model.performNoteAction(.clear)
        #expect(sink.commits.isEmpty)
        #expect(model.refusal == "That note is already cleared. Right-click ▸ Restore brings it back.")

        // A MIX clears only what would change — the menu's "Clear Note" — and
        // the refusal goes (every action clears it first).
        model.toggle(ids[2])
        _ = model.performNoteAction(.clear)
        #expect(model.refusal == nil)
        guard case .notesCleared(let clearedIDs, true)? = sink.commits.last?.kind else {
            Issue.record("a mixed ⌫ committed \(String(describing: sink.commits.last?.kind))")
            return
        }
        #expect(clearedIDs == [ids[2]])

        // RESTORE carries the cleared notes only (the sink wrote nothing back,
        // so the table still has A and B cleared).
        model.selectAll()
        _ = model.performNoteAction(.restore)
        guard case .notesCleared(let restoredIDs, false)? = sink.commits.last?.kind else {
            Issue.record("Restore committed \(String(describing: sink.commits.last?.kind))")
            return
        }
        #expect(restoredIDs == [ids[0], ids[1]])
        #expect(sink.commits.count == 2)

        // NOTHING SELECTED: never routed here by the app, but a stale report
        // must not swallow ⌫ in silence — p2-del's own line, verbatim. Restore
        // with nothing to restore does nothing at all.
        model.clearSelection()
        #expect(model.performNoteAction(.clear) == nil)
        #expect(model.refusal == DeleteMenuPolicy.pitchEditorOpenHint)
        #expect(model.performNoteAction(.restore) == nil)
        #expect(model.refusal == nil)
        #expect(sink.commits.count == 2)
    }

    @Test("I7b — through the store: ⌫ on three notes is ONE \"Clear Notes\" entry, the clip stays, the pane draws them cleared, and ONE undo brings all three back")
    func clearThroughTheStoreIsOneUndoStep() throws {
        // A real store and the app funnel's own call, so the journal is
        // counted rather than inferred. The file is never read: a note setter
        // does no I/O (`locateEditableNoteClip` asks only "audio, not a comp
        // member").
        let clip = Clip(name: "I7b vocal", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-i7b-never-read.wav"))
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let (model, _, ids) = fourNotes(clipID: clip.id)
        func storedTable() -> PitchEditSet? { store.tracks.first?.clips.first?.pitchEdits }
        // THE FUNNEL: `AppModel.commitPitchNoteEdit`'s `.notesCleared` arm, then
        // the pane's read-back (`.onChange(of: clip.pitchEdits)`).
        model.onCommit = { commit in
            guard case .notesCleared(let segmentIDs, let cleared) = commit.kind else {
                Issue.record("unexpected commit \(commit.kind)")
                return
            }
            _ = try? store.setClipNotesCleared(clipId: clip.id, segmentIds: segmentIDs,
                                               cleared: cleared, seedIfAbsent: commit.seedIfAbsent)
            model.syncStoredNoteTable(storedTable())
        }
        // A STORED "before" (an unrelated edit), so undo lands on a real table
        // whose flags can be read — not on `nil`, which would pass vacuously.
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: ids[2], offsetCents: 30,
                                             seedIfAbsent: model.seedForCommit)
        model.syncStoredNoteTable(storedTable())
        let before = try #require(storedTable())
        let depth = store.undoHistory().undo.count

        model.selectOnly(ids[0])
        model.toggle(ids[1])
        model.toggle(ids[3])
        _ = model.performNoteAction(.clear)

        #expect(store.undoHistory().undo.count == depth + 1, "three notes must be ONE undo step")
        #expect(store.undoHistory().undo.first == "Clear Notes")
        let after = try #require(storedTable())
        #expect(after.segments.filter(\.isCleared).map(\.id) == [ids[0], ids[1], ids[3]])
        // Nothing but the flag moved (the invariance control).
        for (now, was) in zip(after.segments, before.segments) {
            var flag = now
            flag.isCleared = was.isCleared
            #expect(flag == was, "clearing changed more than the flag on \(now.id)")
        }
        #expect(store.tracks.first?.clips.map(\.id) == [clip.id], "the clip must still exist")
        #expect(model.blobs.filter(\.isCleared).map(\.id) == [ids[0], ids[1], ids[3]])

        #expect(try store.undo() == "Clear Notes")
        model.syncStoredNoteTable(storedTable())
        #expect(storedTable() == before, "one undo did not bring all three back")
        #expect(model.blobs.allSatisfy { !$0.isCleared })
    }

    @Test("I7b — a right-click on an UNSELECTED note selects it first and its menu names it alone; inside the selection, or on empty surface, the menu is the selection's")
    func rightClickTargetsTheNoteUnderItOrTheSelection() {
        let (model, sink, ids) = fourNotes()
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        let onA = centre(of: model.blobs[0], in: model)
        let onC = centre(of: model.blobs[2], in: model)
        let empty = emptyPoint(model)
        // The menu is built BEFORE the click lands, so it must already name what
        // the click will act on.
        #expect(model.noteMenu(at: onC).map(\.title) == ["Clear Note"])
        #expect(model.noteMenu(at: onA).map(\.title) == ["Clear 2 Notes"])
        #expect(model.noteMenu(at: empty).map(\.title) == ["Clear 2 Notes"])
        #expect(model.noteMenu(at: nil).map(\.title) == ["Clear 2 Notes"])
        // Inside the selection, or on empty surface: the selection is untouched.
        model.selectForContextMenu(at: onA)
        #expect(model.selection == Set([ids[0], ids[1]]))
        model.selectForContextMenu(at: empty)
        #expect(model.selection == Set([ids[0], ids[1]]))
        // An UNSELECTED note: it becomes the selection, alone…
        model.selectForContextMenu(at: onC)
        #expect(model.selection == [ids[2]])
        // …and the menu at that point still says what it said before the click.
        #expect(model.noteMenu(at: onC).map(\.title) == ["Clear Note"])
        #expect(sink.commits.isEmpty, "a right-click selects; it never edits")
        // NOTHING SELECTED, off every note: the menu is SHOWN, greyed, count-free.
        model.clearSelection()
        #expect(model.noteMenu(at: empty)
                == [PitchEditorNoteMenu.Item(action: .clear, title: "Clear Notes", isEnabled: false)])
        // A cleared note under the pointer offers Restore beside a greyed Clear.
        model.syncStoredNoteTable(tableClearing([3], of: model))
        let onD = centre(of: model.blobs[3], in: model)
        #expect(model.noteMenu(at: onD)
                == [PitchEditorNoteMenu.Item(action: .clear, title: "Clear Notes", isEnabled: false),
                    PitchEditorNoteMenu.Item(action: .restore, title: "Restore Note", isEnabled: true)])
    }

    @Test("I7b — the played line has NO point over a cleared note, and every other stretch is unchanged point for point — between runs and inside one")
    func aClearedNoteLeavesTheLine() {
        // BETWEEN RUNS — four notes, four runs; clear B.
        let (model, _, _) = fourNotes()
        let before = model.playedLineSegments()
        let beforeSummaries = model.playedLineNoteSummaries
        #expect(before.count == 4)
        let bRect = model.rect(for: model.blobs[1])
        func inB(_ point: CGPoint) -> Bool { point.x >= bRect.minX && point.x < bRect.maxX }
        // POSITIVE CONTROL: before the clear, B's stretch IS drawn — the
        // absence below is the clear talking, not a line that was never there.
        #expect(before.joined().contains(where: inB))

        model.syncStoredNoteTable(tableClearing([1], of: model))
        let after = model.playedLineSegments()
        #expect(!after.joined().contains(where: inB), "the line is still drawn over a cleared note")
        // THE INVARIANCE CONTROL: the three other notes' stretches, verbatim.
        #expect(after == [before[0], before[2], before[3]])
        // The echo's per-note summary says the same: B has no points, the others
        // are what they were.
        let afterSummaries = model.playedLineNoteSummaries
        #expect(afterSummaries[1].pointCount == 0)
        #expect(afterSummaries[1].medianMidi == nil)
        #expect([afterSummaries[0], afterSummaries[2], afterSummaries[3]]
                == [beforeSummaries[0], beforeSummaries[2], beforeSummaries[3]])
        // ONE PRODUCER (I7b-2): the MADE line — the wire verb's — IS the drawn
        // one. `PitchPlayedLine.make` leaves the hole itself; nothing downstream
        // filters (I7b's first cut hid it here only, and the wire disagreed).
        #expect(model.playedLine.runs.count == 3)
        #expect(model.visiblePlayedLine == model.playedLine)

        // INSIDE ONE RUN — one long note split at frame 30, the right half
        // cleared: the run is CUT there (a hole, never bridged) and the left
        // half's points are the run's first thirty, verbatim.
        let (one, _) = oneNote()
        let whole = one.playedLineSegments()
        #expect(whole.count == 1)
        let seed = one.noteTable.segments[0]
        let cut = seed.startSeconds + 30 * Self.framePeriod
        let left = NoteSegment(id: seed.id, startSeconds: seed.startSeconds, endSeconds: cut,
                               detectedHz: seed.detectedHz, detectedConfidence: seed.detectedConfidence)
        let right = NoteSegment(startSeconds: cut, endSeconds: seed.endSeconds,
                                detectedHz: seed.detectedHz, detectedConfidence: seed.detectedConfidence,
                                isCleared: true)
        one.syncStoredNoteTable(PitchEditSet(analysisVersion: one.noteTable.analysisVersion,
                                             segments: [left, right]))
        let halved = one.playedLineSegments()
        #expect(halved.count == 1)
        #expect(halved.first == Array(whole[0].prefix(30)))
        #expect(one.playedLineNoteSummaries.last?.pointCount == 0)
        #expect(one.playedLineNoteSummaries.first?.pointCount == 30)
    }

    @Test("I7b — each drawn note carries its clear and its level from the segment; a non-zero level always reads")
    func blobsCarryTheClearAndTheLevel() {
        let (model, _, _) = fourNotes()
        var table = model.noteTable
        table.segments[0].amplitudeDb = -6
        table.segments[1].isCleared = true
        table.segments[1].amplitudeDb = -6
        model.syncStoredNoteTable(table)
        let blobs = model.blobs
        #expect(blobs.map(\.isCleared) == [false, true, false, false])
        #expect(blobs.map(\.amplitudeDb) == [-6, -6, 0, 0])
        // A level is never invisible…
        #expect(blobs[0].levelReadout == "Level -6.0 dB")
        // …a cleared note says "cleared" instead (its level waits for Restore)…
        #expect(blobs[1].levelReadout == nil)
        // …and a note at its sung level says nothing.
        #expect(blobs[2].levelReadout == nil)
        // A cleared note is an EDITED one ("has anyone touched it") — but not a
        // TUNED one: since I1 UI hooks item 7 the tuned accent asks
        // `isPitchEdited`, which a clear or a level never sets
        // (`tunedColourFollowsThePitchHalf`). The surface still asks
        // `isCleared` first, for the hollow look.
        #expect(blobs[1].isEdited)
        #expect(!blobs[1].isPitchEdited)
        #expect(blobs[1].menuTarget == PitchEditorNoteMenu.Target(kind: .note, isCleared: true))
    }

    @Test("I4 — the bridge: each IN request bumps only its own nonce, each OUT report writes only on a change, and a teardown clears only its own")
    func bridgeRequestsAndReports() {
        let bridge = PitchEditorInteractionBridge()
        func nonces() -> [Int] {
            [bridge.selectAllNonce, bridge.clearSelectionNonce, bridge.deleteNonce,
             bridge.escapeNonce, bridge.stageNonce]
        }
        #expect(nonces() == [0, 0, 0, 0, 0])
        bridge.requestSelectAll()
        #expect(nonces() == [1, 0, 0, 0, 0])
        bridge.requestClearSelection()
        #expect(nonces() == [1, 1, 0, 0, 0])
        bridge.requestDelete()
        #expect(nonces() == [1, 1, 1, 0, 0])

        // OUT, change-guarded — MEASURED as observable writes, not inferred
        // from the value (an unguarded write of the same value is invisible to
        // a value check and still invalidates every reader, the ⌫ gate included).
        let selectionWrites = WriteRecorder { _ = bridge.hasNoteSelection }
        let countWrites = WriteRecorder { _ = bridge.drawnNoteCount }
        bridge.report(hasNoteSelection: false)
        bridge.report(drawnNoteCount: 0)
        #expect(selectionWrites.writes == 0)
        #expect(countWrites.writes == 0)
        bridge.report(hasNoteSelection: true)
        bridge.report(hasNoteSelection: true)
        bridge.report(drawnNoteCount: 4)
        bridge.report(drawnNoteCount: 4)
        #expect(selectionWrites.writes == 1)
        #expect(countWrites.writes == 1)
        #expect(bridge.hasNoteSelection)
        #expect(bridge.drawnNoteCount == 4)

        // The surface report carries the model's selection verbatim…
        let pane = UUID()
        let selected = PitchEditorSelectionReport(ids: [UUID()], token: UUID(), summary: "1 note selected")
        bridge.reportSurface(token: pane, PitchEditorSurfaceReport(selection: selected))
        #expect(bridge.surface.selection == selected)
        // …a STRANGER's teardown clears nothing…
        bridge.clearSurface(from: UUID())
        #expect(bridge.hasNoteSelection)
        #expect(bridge.drawnNoteCount == 4)
        #expect(bridge.surface.selection == selected)
        // …and the reporting pane's own teardown clears both facts and the report.
        bridge.clearSurface(from: pane)
        #expect(!bridge.hasNoteSelection)
        #expect(bridge.drawnNoteCount == 0)
        #expect(bridge.surface.selection == PitchEditorSelectionReport())
    }

    // MARK: - m23-ap I1 UI hooks — hearing the note (press · drag step · release · stop)
    //
    // ⭐ THE SPY GATE. `onAudition` is the model's ONE audition seam (the
    // `onCommit` shape), so what it is asked can be COUNTED gesture by gesture:
    // a press is one request, each scale step a drag LANDS on is one, a move
    // inside a step is none, the release is none (the app hears the commit), and
    // every Escape and every teardown is exactly one stop. The switch is not the
    // model's to read — the router legs below count it against a REAL store, by
    // the requests that reach the engine.

    /// Everything the model asked to hear, in order, and a shared event log so
    /// a leg can assert ORDER against another closure (Escape's ladder).
    @MainActor final class AuditionSink {
        var requests: [PitchEditorAuditionRequest] = []
        var events: [String] = []
    }

    private func listen(_ model: PitchEditorModel) -> AuditionSink {
        let sink = AuditionSink()
        model.onAudition = { request in
            sink.requests.append(request)
            sink.events.append(request.key)
        }
        return sink
    }

    private func pressIDs(_ sink: AuditionSink) -> [[UUID]] {
        sink.requests.compactMap { request -> [UUID]? in
            guard case .press(let ids, _) = request else { return nil }
            return ids
        }
    }

    private func dragSteps(_ sink: AuditionSink) -> [(offsets: [NotePitchOffset], snapped: Bool)] {
        sink.requests.compactMap { request -> (offsets: [NotePitchOffset], snapped: Bool)? in
            guard case .dragStep(let offsets, let snapped, _) = request else { return nil }
            return (offsets, snapped)
        }
    }

    private func stopCount(_ sink: AuditionSink) -> Int {
        sink.requests.filter { $0 == .stop }.count
    }

    @Test("I1 UI hooks — ⭐ a press on a note asks to hear it ONCE, at its first tick, with the editor's seed; its later ticks, its release, a press on empty surface, a knife press and an inert surface ask nothing")
    func aPressOnANoteIsHeardOnce() {
        let (model, commits, ids) = fourNotes()
        let sink = listen(model)
        let onA = centre(of: model.blobs[0], in: model)
        _ = model.trackPress(start: onA, location: onA, modifiers: .none)
        #expect(pressIDs(sink) == [[ids[0]]])
        guard case .press(_, let seed)? = sink.requests.first else {
            Issue.record("the first tick of a press on a note asked for nothing")
            return
        }
        // The editor's own table rides along: a take nobody has edited has no
        // stored notes, and the seed is how its note is heard.
        #expect(seed == model.seedForCommit)
        #expect(!seed.isEmpty)
        // A later tick of the SAME press (inside the slop), and its release.
        _ = model.trackPress(start: onA, location: CGPoint(x: onA.x + 1, y: onA.y), modifiers: .none)
        #expect(model.releasePress(start: onA, location: onA, modifiers: .none)
                == .click(.selectOnly(ids[0])))
        #expect(sink.requests.count == 1, "\(sink.requests.map(\.key))")
        // POSITIVE CONTROL for "once": a NEW press, on B, is a new request.
        click(model, at: centre(of: model.blobs[1], in: model))
        #expect(pressIDs(sink) == [[ids[0]], [ids[1]]])
        // Empty surface (a band's press) and the knife ask nothing.
        click(model, at: emptyPoint(model))
        model.tool = .scissors
        click(model, at: onA)
        model.tool = .pointer
        #expect(sink.requests.count == 2, "\(sink.requests.map(\.key))")
        // A surface drawing no notes is inert.
        let bare = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        let bareSink = listen(bare)
        _ = bare.trackPress(start: CGPoint(x: 10, y: 10), location: CGPoint(x: 10, y: 10), modifiers: .none)
        #expect(bareSink.requests.isEmpty)
        // Hearing is not editing.
        #expect(commits.commits.isEmpty)
    }

    @Test("I1 UI hooks — ⭐ a snapped drag asks once per scale step it LANDS on: forty pointer ticks are three requests, a move inside a step asks nothing, a step back is heard, and the release asks nothing")
    func aSnappedDragIsHeardPerStepNotPerTick() {
        let (model, commits) = oneNote()
        let sink = listen(model)
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        for tick in 1...40 {
            model.updatePitchDrag(translationHeight: -CGFloat(tick), free: false)
        }
        // -40 pt at 14 pt/row from midi 57: the snap lands on 58, 59 and 60 —
        // +100, +200, +300 cents (`aDragTickNeverCommits` derives the 300), one
        // request each, never forty.
        let steps = dragSteps(sink)
        #expect(steps.count == 3, "\(steps.count) requests for 40 ticks")
        #expect(steps.allSatisfy { $0.snapped })
        #expect(steps.allSatisfy { $0.offsets.map(\.segmentId) == [model.blobs[0].id] })
        let cents = steps.compactMap { $0.offsets.first?.offsetCents }
        #expect(cents.count == 3 && zip(cents, [100.0, 200, 300]).allSatisfy { close($0, $1, 1e-6) },
                "\(cents)")
        // Inside the step the note sits on (raw 59.71…59.93 all land on 60): nothing.
        for dy in [-39.0, -41, -38, -40] {
            model.updatePitchDrag(translationHeight: CGFloat(dy), free: false)
        }
        #expect(dragSteps(sink).count == 3)
        // A step BACK is a change: heard, and so is the return.
        model.updatePitchDrag(translationHeight: -30, free: false)    // 59.14 → 59
        model.updatePitchDrag(translationHeight: -40, free: false)    // → 60
        #expect(dragSteps(sink).count == 5)
        // The release commits once and asks to hear nothing itself.
        #expect(model.endPitchDrag() != nil)
        #expect(commits.commits.count == 1)
        #expect(sink.requests.count == 5)
        #expect(sink.requests.allSatisfy { $0.key == "dragStep" })
    }

    @Test("I1 UI hooks — an ⌥ free drag asks once per change of the offset with snapped: false; a repeated position asks nothing; letting go of ⌥ onto the grid is a step of its own")
    func aFreeDragIsHeardPerOffsetChange() {
        let (model, _) = oneNote()
        let sink = listen(model)
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -5, free: true)
        model.updatePitchDrag(translationHeight: -5, free: true)    // the same position
        model.updatePitchDrag(translationHeight: -6, free: true)
        var steps = dragSteps(sink)
        guard steps.count == 2 else {
            Issue.record("expected 2 free steps, got \(steps.count)")
            return
        }
        #expect(steps.allSatisfy { !$0.snapped })
        #expect(close(steps[0].offsets[0].offsetCents, 500.0 / 14, 1e-6))
        #expect(close(steps[1].offsets[0].offsetCents, 600.0 / 14, 1e-6))
        // ⌥ released where the pointer is: the snap puts the note back on 57.
        model.updatePitchDrag(translationHeight: -6, free: false)
        steps = dragSteps(sink)
        #expect(steps.count == 3)
        #expect(steps.last?.snapped == true)
        #expect(steps.last.map { close($0.offsets[0].offsetCents, 0, 1e-9) } == true)
    }

    /// One note sung `cents` sharp of A3 (midi 57) — what a real voice holds:
    /// never exactly on the grid, unlike every other fixture in this file.
    private func offGridNote(cents: Double) -> PitchEditorModel {
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        model.apply(detection(voiced(count: 60, from: 0.30, hz: 220 * pow(2, cents / 1200))))
        return model
    }

    @Test("I1 UI hooks — ⭐ a SNAPPED step inside the detector floor of what is sounding asks nothing: a note sung 6 c sharp is NOT restarted when the drag snaps it onto its own row, yet every row it crosses is heard and so is the way back; a note 45 c sharp IS heard snapping into tune; ⌥ steps are never thinned")
    func aSnappedStepNobodyCanHearAsksNothing() {
        // MEASURED in staging (2026-09-25): a 3-row snapped drag of a detected
        // note asked 4 times (−6, +94, +194, +294 c) and a 1-row group drag
        // twice (−1, +99 c) — the first ask of each a snap onto the note's own
        // row that restarted it for nothing. Every fixture above is exactly
        // on the grid, which is why none of them could see it.
        let model = offGridNote(cents: 6)
        #expect(close(model.blobs[0].centreMidi, 57.06, 1e-6))
        let sink = listen(model)
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        // 3 pt up at 14 pt/row: raw 57.27 lands on 57 — the note's OWN row, −6 c.
        model.updatePitchDrag(translationHeight: -3, free: false)
        #expect(model.drag.map { close($0.offsetCents, -6, 1e-6) } == true,
                "the draft must still move (its line, its commit) — only the ASK is withheld")
        #expect(dragSteps(sink).isEmpty, "a 6-cent snap onto the note's own row asked to be heard")
        // On up: rows 58, 59, 60 — +94, +194, +294 — each heard once.
        for tick in 4...40 {
            model.updatePitchDrag(translationHeight: -CGFloat(tick), free: false)
        }
        var cents = dragSteps(sink).compactMap { $0.offsets.first?.offsetCents }
        #expect(cents.count == 3 && zip(cents, [94.0, 194, 294]).allSatisfy { close($0, $1, 1e-6) },
                "\(cents)")
        // Back down to its own row: 300 c from what is sounding — heard.
        model.updatePitchDrag(translationHeight: -3, free: false)
        cents = dragSteps(sink).compactMap { $0.offsets.first?.offsetCents }
        #expect(cents.count == 4 && cents.last.map { close($0, -6, 1e-6) } == true, "\(cents)")

        // The floor's OTHER side: a note 45 c sharp snaps AUDIBLY into tune.
        let far = offGridNote(cents: 45)
        let farSink = listen(far)
        #expect(far.beginPitchDrag(on: far.blobs[0]))
        far.updatePitchDrag(translationHeight: 1, free: false)       // raw 57.38 → 57: −45 c
        let farCents = dragSteps(farSink).compactMap { $0.offsets.first?.offsetCents }
        #expect(farCents.count == 1 && farCents.first.map { close($0, -45, 1e-6) } == true,
                "\(farCents)")

        // ⌥ is never thinned: two sub-cent free moves are two asks.
        let fine = offGridNote(cents: 6)
        let fineSink = listen(fine)
        #expect(fine.beginPitchDrag(on: fine.blobs[0]))
        fine.updatePitchDrag(translationHeight: -0.1, free: true)
        fine.updatePitchDrag(translationHeight: -0.2, free: true)
        #expect(dragSteps(fineSink).count == 2)
        #expect(dragSteps(fineSink).allSatisfy { !$0.snapped })
    }

    @Test("I1 UI hooks — a GROUP drag's step names every moving note with its absolute offset, the pressed note first; the press before it named the pressed note alone")
    func aGroupDragIsHeardAsOneStep() {
        let (model, _, ids) = fourNotes()
        let sink = listen(model)
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        let onB = centre(of: model.blobs[1], in: model)
        let up = CGPoint(x: onB.x, y: onB.y - 28)
        _ = model.trackPress(start: onB, location: onB, modifiers: .none)
        #expect(model.trackPress(start: onB, location: up, modifiers: .none).didPromote)
        #expect(model.beginSelectionPitchDrag(on: model.blobs[1]))
        model.updatePitchDrag(translationHeight: -28, free: false)
        #expect(pressIDs(sink) == [[ids[1]]])
        let steps = dragSteps(sink)
        #expect(steps.count == 1)
        #expect(steps.first?.offsets.map(\.segmentId) == [ids[1], ids[0]])
        #expect(steps.first.map { $0.offsets.allSatisfy { close($0.offsetCents, 200, 1e-6) } } == true)
        #expect(steps.first?.snapped == true)
    }

    @Test("I1 UI hooks — ⭐ Escape asks for ONE stop per press, BEFORE the ladder is asked, and the ladder's rung still happens: the drag is cancelled, the selection cleared, the mode left, and a pass still passes")
    func escapeStopsTheAuditionThenClimbsTheLadder() {
        let (model, commits, _) = fourNotes()
        let sink = listen(model)
        var maximized = true
        let app: (Bool, Bool) -> EditorEscapeRung = { live, selected in
            sink.events.append("ask")
            let rung = EditorEscapeLadder.resolve(gestureLive: live, hasSelection: selected,
                                                  maximized: maximized, blocked: false)
            if rung == .exitMaximize { maximized = false }
            return rung
        }
        model.selectAll()
        #expect(model.beginSelectionPitchDrag(on: model.blobs[1]))
        model.updatePitchDrag(translationHeight: -14, free: false)
        let before = sink.events.count
        #expect(model.handleEscapeKey(appDecision: app))      // 1 — the drag
        #expect(model.drag == nil)
        #expect(model.selection.count == 4)
        #expect(model.handleEscapeKey(appDecision: app))      // 2 — the selection
        #expect(model.selection.isEmpty)
        #expect(maximized)
        #expect(model.handleEscapeKey(appDecision: app))      // 3 — the mode
        #expect(!maximized)
        #expect(!model.handleEscapeKey(appDecision: app))     // 4 — the key passes; the sound still stops
        #expect(Array(sink.events.dropFirst(before))
                == ["stop", "ask", "stop", "ask", "stop", "ask", "stop", "ask"])
        #expect(stopCount(sink) == 4)
        #expect(commits.commits.isEmpty)
    }

    @Test("I1 UI hooks — the pane going away asks for ONE stop and touches nothing else; a cancelled drag and a click's release ask for no stop")
    func teardownStopsTheAuditionOnce() {
        let (model, _, ids) = fourNotes()
        let sink = listen(model)
        model.selectOnly(ids[2])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[2]))
        model.updatePitchDrag(translationHeight: -14, free: false)
        let asked = sink.requests.count
        #expect(asked == 1)
        // What the view's OTHER `.onDisappear` runs: a cancel is not a stop.
        model.cancelDrag()
        #expect(sink.requests.count == asked)
        model.stopAudition()
        #expect(sink.requests.count == asked + 1)
        #expect(sink.requests.last == .stop)
        #expect(model.selection == [ids[2]], "a stop changed the selection")
        #expect(model.drag == nil)
        // A click's release (the view runs `cancelDrag` after it) asks nothing.
        click(model, at: emptyPoint(model))
        #expect(sink.requests.count == asked + 1)
    }

    // MARK: I1 UI hooks — the router, against a REAL store

    /// A take whose notes are STORED (the release door resolves from the
    /// stored table): 0.5–1.0 s and 2.0–2.6 s. The file is never read.
    private func auditionStore() -> (store: ProjectStore, engine: AuditionTestEngine,
                                     clip: Clip, notes: [NoteSegment]) {
        let notes = [
            NoteSegment(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 2.0, endSeconds: 2.6, detectedHz: 247, detectedConfidence: 0.9),
        ]
        let clip = Clip(name: "I1 UI vocal", startBeat: 0, lengthBeats: 32,
                        audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-i1ui-never-read.wav"),
                        pitchEdits: PitchEditSet(segments: notes))
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = AuditionTestEngine()
        store.engine = engine
        return (store, engine, clip, notes)
    }

    @Test("I1 UI hooks — ⭐ the chain, model → router → REAL store: a click on a note of an UNTOUCHED take is ONE engine request with the switch on, ZERO with it off, and ZERO while the transport runs — which draws nothing extra")
    func pressChainThroughTheRealStore() {
        let clip = Clip(name: "I1 UI untouched", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-i1ui-never-read.wav"))
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = AuditionTestEngine()
        store.engine = engine
        let router = PitchEditorAuditionRouter(doors: store, pollInterval: nil)
        let (model, _, _) = fourNotes(clipID: clip.id)
        var switchOn = true
        model.onAudition = { router.route($0, clipID: clip.id, enabled: switchOn) }
        func requests() -> Int { store.clipNoteAudition.counts.engineRequests }
        #expect(store.tracks[0].clips[0].pitchEdits == nil)

        click(model, at: centre(of: model.blobs[0], in: model))
        #expect(requests() == 1)
        #expect(engine.fileCalls.count == 1)
        #expect(router.lastResult?.isAudible == true)
        #expect(router.line == nil)
        #expect(store.tracks[0].clips[0].pitchEdits == nil, "hearing a note stored the seed")

        switchOn = false
        click(model, at: centre(of: model.blobs[1], in: model))
        #expect(requests() == 1, "the switch was off and the engine was asked anyway")
        #expect(router.lastResult?.reason == .auditionOff)

        switchOn = true
        store.play()
        click(model, at: centre(of: model.blobs[2], in: model))
        #expect(requests() == 1, "the transport was running and the engine was asked anyway")
        #expect(router.lastResult?.reason == .transportRunning)
        #expect(router.line == nil, "the transport running must show nothing extra")
        store.stop()
        // POSITIVE CONTROL: stopped again, the same click is heard.
        click(model, at: centre(of: model.blobs[2], in: model))
        #expect(requests() == 2)
        #expect(router.counts.presses == 4)
    }

    @Test("I1 UI hooks — the chain for a DRAG: each step is ONE span render of the DRAFT, the switch off reaches no engine, and an ⌥ step behind a render in flight waits in the store's queue")
    func dragChainThroughTheRealStore() {
        let clip = Clip(name: "I1 UI untouched", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-i1ui-never-read.wav"))
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let engine = AuditionTestEngine()
        store.engine = engine
        let router = PitchEditorAuditionRouter(doors: store, pollInterval: nil)
        let (model, commits, ids) = fourNotes(clipID: clip.id)
        var switchOn = true
        model.onAudition = { router.route($0, clipID: clip.id, enabled: switchOn) }
        model.selectOnly(ids[0])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))

        model.updatePitchDrag(translationHeight: -14, free: false)     // 57 → 58
        #expect(engine.spanCalls.count == 1)
        guard case .draftSpanRender(let draft)? = engine.spanCalls.last else {
            Issue.record("the drag step did not render a DRAFT: \(engine.spanCalls)")
            return
        }
        #expect(draft.segments.first(where: { $0.id == ids[0] }).map { close($0.pitchOffsetCents, 100, 1e-6) } == true)
        #expect(store.tracks[0].clips[0].pitchEdits == nil, "a drag step wrote the table")

        switchOn = false
        model.updatePitchDrag(translationHeight: -28, free: false)     // → 59, switch off
        #expect(engine.spanCalls.count == 1, "the switch was off and a span render was asked for")
        #expect(router.lastResult?.reason == .auditionOff)

        switchOn = true
        model.updatePitchDrag(translationHeight: -35, free: true)      // free: renders at once
        #expect(engine.spanCalls.count == 2)
        model.updatePitchDrag(translationHeight: -36, free: true)      // behind it: waits
        #expect(engine.spanCalls.count == 2)
        #expect(store.clipNoteAudition.hasQueuedDraft)
        #expect(router.lastResult?.reason == .previewQueued)
        #expect(router.line == nil, "a step that WILL play is not a shortfall")
        #expect(router.counts.dragSteps == 4)
        #expect(commits.commits.isEmpty)
    }

    @Test("I1 UI hooks — after a commit LANDS: a retune, a group drag and a clear each play their notes ONCE (a clear with 0.3 s of context), a split plays and asks NOTHING, and the switch off reaches no engine")
    func releaseAfterTheCommitLands() throws {
        let (store, engine, clip, notes) = auditionStore()
        let router = PitchEditorAuditionRouter(doors: store, pollInterval: nil)
        let seed = PitchEditSet()
        func landed(_ kind: PitchEditorCommit.Kind, enabled: Bool = true) {
            router.commitLanded(PitchEditorCommit(kind: kind, seedIfAbsent: seed), clipID: clip.id,
                                enabled: enabled)
        }
        func lastSpan() -> (Double, Double)? { engine.fileCalls.last.map { ($0.start, $0.end) } }
        func near(_ span: (Double, Double)?, _ start: Double, _ end: Double) -> Bool {
            guard let span else { return false }
            return close(span.0, start, 1e-9) && close(span.1, end, 1e-9)
        }

        // C1 — one note retuned: that note ± 60 ms.
        _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: notes[0].id, offsetCents: 100)
        landed(.notePitch(segmentID: notes[0].id, offsetCents: 100))
        #expect(engine.fileCalls.count == 1)
        #expect(near(lastSpan(), 0.44, 1.06), "\(String(describing: lastSpan()))")
        // I4 — a group drag: every moved note, one span.
        landed(.notePitches(offsets: notes.map { NotePitchOffset(segmentId: $0.id, offsetCents: 100) },
                            selectionToken: UUID()))
        #expect(engine.fileCalls.count == 2)
        #expect(near(lastSpan(), 0.44, 2.66), "\(String(describing: lastSpan()))")
        // I7b — a clear (and a restore, the same edit kind): 0.3 s either side.
        _ = try store.setClipNotesCleared(clipId: clip.id, segmentIds: [notes[1].id], cleared: true)
        landed(.notesCleared(segmentIDs: [notes[1].id], cleared: true))
        #expect(engine.fileCalls.count == 3)
        #expect(near(lastSpan(), 1.7, 2.9), "\(String(describing: lastSpan()))")
        landed(.notesCleared(segmentIDs: [notes[1].id], cleared: false))
        #expect(engine.fileCalls.count == 4)
        #expect(near(lastSpan(), 1.7, 2.9))
        // C3 — a split changes nothing audible: no door, no engine.
        let releasesBefore = store.clipNoteAudition.counts.releases
        landed(.splitNote(segmentID: notes[0].id, atSourceSecond: 0.75))
        #expect(engine.fileCalls.count == 4)
        #expect(store.clipNoteAudition.counts.releases == releasesBefore, "a split reached the release door")
        #expect(router.counts.silentCommits == 1)
        // The switch off: the door is entered (latest wins) and the engine is not asked.
        landed(.notePitch(segmentID: notes[0].id, offsetCents: 200), enabled: false)
        #expect(engine.fileCalls.count == 4, "the switch was off and the release played")
        #expect(router.lastResult?.reason == .auditionOff)
        #expect(router.counts.releases == 5)
        // The mapping itself, in its one exhaustive home.
        #expect(PitchEditorAuditionRouter.releaseAudition(for: .splitNote(segmentID: notes[0].id,
                                                                          atSourceSecond: 0.75)) == nil)
        #expect(PitchEditorAuditionRouter.releaseAudition(
            for: .notesCleared(segmentIDs: [notes[1].id], cleared: false))
            == PitchEditorReleaseAudition(edit: .clear, segmentIDs: [notes[1].id]))
    }

    /// A scripted door for the LINE legs: the router's words and its wait
    /// polling, with every store answer chosen by the test.
    private func answer(_ reason: ClipNoteAuditionResult.Reason?) -> ClipNoteAuditionResult {
        ClipNoteAuditionResult(outcome: reason == nil ? .sounded : nil, startSeconds: 0.44,
                               endSeconds: 1.06, source: .render, reason: reason)
    }

    @Test("I1 UI hooks — HONEST WAITING: a release that waits draws \"Preparing your note…\" as PROGRESS; it clears when the note plays or is replaced, and a drop draws the SHORTFALL \"Couldn't play that note in time. Click it to hear it.\" until the next request — never silence")
    func honestWaitingLines() {
        let doors = ScriptedAuditionDoors()
        let router = PitchEditorAuditionRouter(doors: doors, pollInterval: nil)
        let clip = UUID()
        let note = UUID()
        let commit = PitchEditorCommit(kind: .notePitch(segmentID: note, offsetCents: 100),
                                       seedIfAbsent: PitchEditSet())
        let preparing = PitchEditorLineCaption(kind: .progress, text: "Preparing your note…")
        let dropped = PitchEditorLineCaption(kind: .shortfall,
                                             text: "Couldn't play that note in time. Click it to hear it.")

        doors.answer = answer(.waitingForRender)
        doors.serial = 7
        doors.state = .waiting
        router.commitLanded(commit, clipID: clip, enabled: true)
        #expect(router.line == preparing)
        #expect(router.waitingSerial == 7)
        #expect(router.pollWait(), "a wait still inside its 8 s must keep polling")
        #expect(router.line == preparing)
        doors.state = .played
        #expect(!router.pollWait())
        #expect(router.line == nil)
        #expect(router.waitingSerial == nil)

        // The DROP: said, and kept until the next request.
        doors.serial = 8
        doors.state = .waiting
        router.commitLanded(commit, clipID: clip, enabled: true)
        doors.state = .expired
        #expect(!router.pollWait())
        #expect(router.line == dropped)
        #expect(!router.pollWait())
        #expect(router.line == dropped, "the drop vanished with nothing new asked")
        // …and the click it asks for, a press that plays, clears it.
        doors.answer = answer(nil)
        router.route(.press(segmentIDs: [note], seedIfAbsent: PitchEditSet()), clipID: clip, enabled: true)
        #expect(router.line == nil)

        // A wait REPLACED (a transport start, a stop elsewhere) clears without a drop.
        doors.answer = answer(.waitingForRender)
        doors.serial = 9
        doors.state = .waiting
        router.commitLanded(commit, clipID: clip, enabled: true)
        doors.state = .cancelled
        #expect(!router.pollWait())
        #expect(router.line == nil)

        // A stop takes the line down with the sound.
        doors.serial = 10
        doors.state = .waiting
        router.commitLanded(commit, clipID: clip, enabled: true)
        #expect(router.line == preparing)
        router.route(.stop, clipID: clip, enabled: true)
        #expect(router.line == nil)
        #expect(router.waitingSerial == nil)
        #expect(doors.stops == 1)
        #expect(router.counts.stops == 1)
    }

    @Test("I1 UI hooks — the wait is polled BY ITSELF: with no one asking, \"Preparing your note…\" turns into the drop once the store says the wait expired")
    func theWaitPollsItself() async {
        let doors = ScriptedAuditionDoors()
        let router = PitchEditorAuditionRouter(doors: doors, pollInterval: .milliseconds(5))
        doors.answer = answer(.waitingForRender)
        doors.serial = 3
        doors.state = .waiting
        router.commitLanded(PitchEditorCommit(kind: .notePitch(segmentID: UUID(), offsetCents: 50),
                                              seedIfAbsent: PitchEditSet()),
                            clipID: UUID(), enabled: true)
        #expect(router.line?.kind == .progress)
        // ⭐ RESUMED BY THE READ ITSELF, NEVER BY A CLOCK. The router's poll needs
        // TWO main-actor turns (its task starts and naps, then it reads); a
        // clock-bounded loop needs ONE to give up. Both failed with the main
        // actor queued up behind the rest of a run: a fixed 30 ms nap read 0 in
        // a 549-test run, and a 5 s loop read 0 in the full suite (its check
        // landed after the deadline and before the read; the test took 81.0 s,
        // `full-suite-0847.log`, 2026-09-25). Resumed BY the read, the checks
        // below run after it by construction. The guard only keeps a product
        // that never polls from hanging the run (`mainActorHangGuard`).
        await doors.untilAWaitRead(answered: .waiting, hangGuard: mainActorHangGuard)
        #expect(doors.waitReads > 0, "nothing polled the wait")
        #expect(router.line?.kind == .progress, "the line left while the store still said waiting")
        doors.state = .expired
        // The router ends the wait and draws the drop in the SAME main-actor
        // turn as the read that answered "expired"; the resumption queues
        // behind that turn, so the line is already the drop when it runs.
        await doors.untilAWaitRead(answered: .expired, hangGuard: mainActorHangGuard)
        #expect(router.line == PitchEditorAuditionWords.droppedCaption)
        #expect(router.waitingSerial == nil)
    }

    @Test("I1 UI hooks — the audition words, by value: each store reason maps to ONE sentence or to nothing, and a running transport shows nothing extra")
    func auditionWordsByValue() {
        typealias Reason = ClipNoteAuditionResult.Reason
        let expected: [(Reason, PitchEditorLineCaption?)] = [
            (.waitingForRender, PitchEditorLineCaption(kind: .progress, text: "Preparing your note…")),
            (.trackMuted, PitchEditorLineCaption(
                kind: .shortfall, text: "Can't play that note: its track is muted, or another track is soloed.")),
            (.engineStopped, PitchEditorLineCaption(
                kind: .shortfall, text: "Can't play that note: the audio engine isn't running.")),
            (.stillRendering, PitchEditorLineCaption(
                kind: .shortfall, text: "That note isn't ready to play yet. Click it again in a moment.")),
            (.transportRunning, nil),
            (.auditionOff, nil),
            (.previewQueued, nil),
            (.unchanged, nil),
            (.noAudio, nil),
            (.unsupported, nil),
        ]
        for (reason, caption) in expected {
            #expect(PitchEditorAuditionWords.caption(for: reason) == caption, "\(reason)")
        }
        #expect(PitchEditorAuditionWords.caption(for: nil) == nil)
        #expect(Set(expected.map(\.0.rawValue)).count == 10, "a reason is listed twice")
        #expect(PitchEditorAuditionWords.droppedCaption
                == PitchEditorLineCaption(kind: .shortfall,
                                          text: "Couldn't play that note in time. Click it to hear it."))
    }

    @Test("I1 UI hooks — the HEAR switch's faces, by value: a speaker when on, a crossed speaker when off, and the help says it is ONE switch for both note editors")
    func hearSwitchFaces() {
        #expect(PitchEditorAuditionToggle.title == "HEAR")
        #expect(PitchEditorAuditionToggle.symbol(on: true) == "speaker.wave.2.fill")
        #expect(PitchEditorAuditionToggle.symbol(on: false) == "speaker.slash.fill")
        for on in [true, false] {
            #expect(PitchEditorAuditionToggle.help(on: on).hasSuffix(
                "One switch for both note editors (the piano roll and this one) and for musical typing."))
        }
        #expect(PitchEditorAuditionToggle.help(on: true).hasPrefix("Notes play as you click and drag them."))
        #expect(PitchEditorAuditionToggle.help(on: false).hasPrefix("Note sounds are off."))
        #expect(PitchEditorAuditionToggle.accessibilityLabel(on: true) == "Note sounds on")
        #expect(PitchEditorAuditionToggle.accessibilityLabel(on: false) == "Note sounds off")
    }

    // MARK: I1 UI hooks item 7 — the tuned colour asks the PITCH half

    @Test("I1 UI hooks item 7 — ⭐ the tuned colour asks the PITCH half: a level-only, a clear-only and a rate-only note are not tuned; a moved note and an in-tune Hard-Tuned note are — note for note what the header badge aggregates")
    func tunedColourFollowsThePitchHalf() {
        let (model, _, _) = fourNotes()
        let base = model.noteTable
        let cases: [(name: String, edit: (inout NoteSegment) -> Void, tuned: Bool, moved: Bool)] = [
            ("level only", { $0.amplitudeDb = -6 }, false, false),
            ("clear only", { $0.isCleared = true }, false, false),
            ("vibrato rate, no depth", { $0.vibratoRateHz = 5.5 }, false, false),
            ("moved +100 c", { $0.pitchOffsetCents = 100 }, true, true),
            ("Hard Tune, already in tune", { $0.driftScale = 0; $0.vibratoScale = 0 }, true, false),
        ]
        for (name, edit, tuned, moved) in cases {
            var table = base
            edit(&table.segments[0])
            model.syncStoredNoteTable(table)
            let blob = model.blobs[0]
            #expect(blob.isPitchEdited == tuned, "\(name)")
            // Every case IS an edit: the old colour question said "tuned" to all five.
            #expect(blob.isEdited, "\(name)")
            // The ghost's own question is untouched.
            #expect(blob.isMoved == moved, "\(name)")
            // ONE home: the note's answer is the badge's, note for note.
            let clip = Clip(name: "c", audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-i1ui-never-read.wav"),
                            pitchEdits: table)
            #expect(clip.hasTuningEdits == tuned, "\(name): the badge and the note disagree")
            #expect(model.blobs.dropFirst().allSatisfy { !$0.isPitchEdited }, "\(name)")
        }
        // A blob built without a segment knows only its offset.
        #expect(!NoteBlob(startSeconds: 0, endSeconds: 1, detectedHz: 220, medianConfidence: 1,
                          frameCount: 10).isPitchEdited)
        #expect(NoteBlob(startSeconds: 0, endSeconds: 1, detectedHz: 220, medianConfidence: 1,
                         frameCount: 10, offsetCents: 50).isPitchEdited)
    }

    // MARK: - NT-U0 — the draft line's table CARRIES the set (natural tuning X2 rule 2)

    /// The drag's DRAFT line is drawn through a copy of the note table. That copy
    /// must carry every set-level field, or the line drawn during a drag differs
    /// from what plays once NT-C C4's transitions read the slope.
    ///
    /// ⚠️ **THE TWO CONTROLS ARE WHAT MAKE THE RED MEAN SOMETHING.** Under the
    /// planted legacy constructor (`PitchEditSet(analysisVersion:segments:
    /// retuneMs:)`) the three natural-tuning fields go red while `retuneMs`,
    /// `analysisVersion` and the dragged offset stay green, which shows the seam
    /// reads the real rebuild and not the stored table.
    @Test("NT-U0 — ⭐ the draft line's table CARRIES the formant amount, the consonant flag, the transition slope and the stamp, for a one-note drag and a group drag")
    func draftLineCarriesTheSetLevelFields() {
        let (model, _, ids) = fourNotes()
        let seed = model.noteTable
        // Every set-level field non-legacy, over the SEED's own segments so the
        // ids are the drawn blobs'. Stored before the drag: table, then drag.
        var stored = PitchEditSet(analysisVersion: seed.analysisVersion, segments: seed.segments,
                                  retuneMs: 120, formantCorrection: 0.35,
                                  keepsConsonantsUntuned: true, transitionSlopeCentsPerSecond: 2500)
        stored.autoCorrectStamp = "nt-u0-stamp"
        model.syncStoredNoteTable(stored)
        // The fixture is what it says: the table the editor draws carries them.
        #expect(model.noteTable == stored)
        #expect(model.draftEditSet == nil, "no drag, no draft table")

        func expectCarried(_ label: String) {
            guard let draft = model.draftEditSet else {
                Issue.record("\(label): no draft table was built")
                return
            }
            #expect(draft.formantCorrection == 0.35, "\(label): formant amount dropped")
            #expect(draft.keepsConsonantsUntuned, "\(label): consonant flag dropped")
            #expect(draft.transitionSlopeCentsPerSecond == 2500, "\(label): transition slope dropped")
            #expect(draft.autoCorrectStamp == "nt-u0-stamp", "\(label): stamp dropped")
            // Controls: what the legacy constructor DID carry.
            #expect(draft.retuneMs == 120, "\(label)")
            #expect(draft.analysisVersion == seed.analysisVersion, "\(label)")
        }

        // One note: D (62) two rows up. The draft table holds the DRAFT offset.
        #expect(model.beginPitchDrag(on: model.blobs[3]))
        model.updatePitchDrag(translationHeight: -2 * model.geometry.rowHeight, free: false)
        let offset = model.drag?.offsetCents ?? 0
        #expect(offset != 0, "the drag moved nothing, so this reads the stored table")
        #expect(model.draftEditSet?.segments.first { $0.id == ids[3] }?.pitchOffsetCents == offset)
        expectCarried("one note")
        model.cancelDrag()
        #expect(model.draftEditSet == nil, "the draft table goes with the draft")

        // A group: A and B, one row up.
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
        model.updatePitchDrag(translationHeight: -model.geometry.rowHeight, free: false)
        #expect(model.drag?.members.count == 1)
        expectCarried("group")
        model.cancelDrag()
    }

    // MARK: - I6b S2 — the window grows under a drag at its edge (interaction batch §9)

    @Test("I6b — grown(_:towards:by:) widens ONE end by whole rows, never narrows, and stops at 0 and 127")
    func i6bGrownByHand() {
        #expect(PitchEditorRange.grown(53...66, towards: .leading, by: 1) == 53...67, "leading is the TOP")
        #expect(PitchEditorRange.grown(53...66, towards: .trailing, by: 2) == 51...66)
        #expect(PitchEditorRange.grown(53...66, towards: .leading, by: 0) == 53...66)
        #expect(PitchEditorRange.grown(53...66, towards: .trailing, by: -3) == 53...66)
        #expect(PitchEditorRange.grown(120...125, towards: .leading, by: 5) == 120...127)
        #expect(PitchEditorRange.grown(100...127, towards: .leading, by: 5) == 100...127)
        #expect(PitchEditorRange.grown(2...20, towards: .trailing, by: 5) == 0...20)
        #expect(PitchEditorRange.grown(0...20, towards: .trailing, by: 5) == 0...20)
    }

    @Test("I6b — growth is EARNED at 12 st/s × depth × dt with the remainder carried, reset per press, banks nothing at 0/127, and never happens without a drag or commits")
    func i6bGrowthRateAndLimits() {
        let (model, sink, _) = fourNotes()                          // 53…66
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 1) == 0,
                "no drag, no growth")
        #expect(model.geometry.midiRange == 53...66)
        #expect(model.beginPitchDrag(on: model.blobs[3]))
        // 12 × 1 × 0.125 = 1.5 rows: one now, half a row carried; then 2.0.
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 0.125) == 1)
        #expect(model.geometry.midiRange == 53...67)
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 0.125) == 2)
        #expect(model.geometry.midiRange == 53...69)
        // Half depth, half the rate: 0.75 of a row, none yet.
        #expect(model.growPitchWindowForDrag(side: .trailing, depthFraction: 0.5, dt: 0.125) == 0)
        #expect(model.drag?.topGrowthRows == 3 && model.drag?.bottomGrowthRows == 0)
        for (depth, dt) in [(0, 1), (1, .nan), (1, -1), (.nan, 1)] as [(CGFloat, Double)] {
            #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: depth, dt: dt) == 0,
                    "depth \(depth), dt \(dt)")
        }
        // A NEW press banks nothing from the last: the 0.75 carried would make
        // this 0.375 a whole row.
        model.cancelDrag()
        #expect(model.beginPitchDrag(on: model.blobs[3]))
        #expect(model.growPitchWindowForDrag(side: .trailing, depthFraction: 1, dt: 0.03125) == 0)
        // To the top of MIDI: 120 rows asked, 58 left above 69.
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 10) == 58)
        #expect(model.geometry.midiRange == 53...127)
        // A pause AT the limit banks nothing: 0.75 there, then 0.375 at the
        // bottom, would otherwise add up to a row.
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 0.0625) == 0)
        #expect(model.growPitchWindowForDrag(side: .trailing, depthFraction: 1, dt: 0.03125) == 0)
        // The bottom goes to 0 the same way, and stops.
        #expect(model.growPitchWindowForDrag(side: .trailing, depthFraction: 1, dt: 10) == 53)
        #expect(model.geometry.midiRange == 0...127)
        #expect(model.growPitchWindowForDrag(side: .trailing, depthFraction: 1, dt: 10) == 0)
        #expect(model.drag?.grownRows == 111)
        model.cancelDrag()
        #expect(sink.commits.isEmpty, "growth is layout, never a store write")
    }

    @Test("I6b — an edge step grows for the time since the press's last step, capped at three frames; its first step for the repeat's own interval")
    func i6bEdgeStepSeconds() {
        #expect(close(PitchEditorModel.edgeStepSeconds(sinceLastStep: nil), 0.016))
        #expect(close(PitchEditorModel.edgeStepSeconds(sinceLastStep: .milliseconds(8)), 0.008))
        #expect(PitchEditorModel.edgeStepSeconds(sinceLastStep: .seconds(2))
                == PitchEditorModel.maxEdgeStepSeconds)
        #expect(PitchEditorModel.maxEdgeStepSeconds == 0.05)
        #expect(PitchEditorModel.edgeStepSeconds(sinceLastStep: .milliseconds(-5)) == 0)
    }

    /// ⭐ THE TOP-GROWTH HAZARD (survey I6b): rows are laid out down from the
    /// window's top, so a row grown there moves every row while the press point
    /// stays put. The pointer is HELD 5 pt under the viewport's top and every
    /// tick rebuilds its content y from the OBSERVED offset (`EdgeAutoScroll
    /// .tick`), under both answers to the INFERRED SwiftUI question: the offset
    /// stays 0 (the content moves down under it), or the scroller anchors the
    /// content (the offset grows by the rows). Either way the note must be the
    /// pitch under the pointer, clamped and snapped as the drag always is.
    @Test("I6b — ⭐ held at the TOP wall the window climbs and the dragged note stays the pitch UNDER THE POINTER, whether the offset holds at 0 or the scroller anchors; snapped and free")
    func i6bTheNoteStaysUnderThePointerAsTheTopGrows() {
        for free in [false, true] {
            for anchors in [false, true] {
                let label = "free \(free), anchors \(anchors)"
                let (model, _, _) = fourNotes()                     // 53…66, 14 pt rows
                let rh = model.geometry.rowHeight
                let d = model.blobs[3]                              // D4, 62, centre y 63
                let start = centre(of: d, in: model)
                #expect(model.beginPitchDrag(on: d))
                let local: CGFloat = 5
                var offset: CGFloat = 0
                func expected() -> Double {
                    let under = model.geometry.midi(forY: local + offset)
                    let window = model.geometry.midiRange
                    return free
                        ? min(max(under, window.lowerBound), window.upperBound)
                        : min(max(under, window.lowerBound + 1), window.upperBound - 1).rounded()
                }
                model.updatePitchDrag(translationHeight: (local + offset) - start.y, free: free)
                #expect(close(model.drag!.targetMidi, expected(), 1e-9), "\(label): before growth")
                let screenY = model.geometry.y(forMidi: model.drag!.targetMidi) - offset
                var total = 0
                for tick in 1...5 {
                    let rows = model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 0.125)
                    #expect(rows >= 1, "\(label): tick \(tick) grew nothing")
                    total += rows
                    if anchors { offset += CGFloat(rows) * rh }
                    model.updatePitchDrag(translationHeight: (local + offset) - start.y, free: free)
                    #expect(close(model.drag!.targetMidi, expected(), 1e-9),
                            "\(label): tick \(tick), note \(model.drag!.targetMidi) vs under the pointer \(expected())")
                    if !anchors {
                        // The survey's words: the note's SCREEN y stays under the pointer.
                        #expect(close(model.geometry.y(forMidi: model.drag!.targetMidi) - offset, screenY),
                                "\(label): tick \(tick)")
                    }
                }
                #expect(model.geometry.midiRange == 53...Double(66 + total), "\(label)")
                model.cancelDrag()
            }
        }
    }

    /// ⭐ S2's BIT-IDENTITY PROOF. The pre-I6b ⌥ arithmetic, FROZEN here (one
    /// note, and the group's raw→delta step), against the live drag over a
    /// sweep of translations, on `.bitPattern`, for the draft AND the commit.
    /// ⌥ because a snapped drag lands on whole semitones × 100, where many wrong
    /// formulas agree; a free drag carries every bit of the arithmetic.
    @Test("I6b — ⭐ a drag that never grows is BIT-identical to the pre-I6b arithmetic: ⌥ free drags over a sweep, one note and a group, draft and commit, on .bitPattern; its release leaves the window alone")
    func i6bANonGrowingDragIsBitIdentical() {
        func frozenRaw(_ t: CGFloat, origin: Double, rowHeight: CGFloat) -> Double {
            origin + -Double(t) / Double(max(1, rowHeight))
        }
        var sweep: [CGFloat] = [-0.0, 0, 1e-9, -1e-9, 0.3, -0.3, 7.25, -7.25, 13.99, -14, 20.123456789,
                                -55.5, 100.7, -100.7, 333.3333, -333.3333, -1000, 1000]
        sweep += stride(from: -300, through: 300, by: 0.37).map { CGFloat($0) }
        let (model, sink, _) = fourNotes()
        let rh = model.geometry.rowHeight
        let window = model.geometry.midiRange
        let d = model.blobs[3]
        let shift = model.geometry.clipPitchShiftSemitones
        let origin = PitchEditorGeometry.drawnMidi(centreMidi: d.centreMidi, offsetCents: d.offsetCents,
                                                   clipPitchShiftSemitones: shift)
        func frozenOne(_ t: CGFloat) -> Double {
            let raw = frozenRaw(t, origin: origin, rowHeight: rh)
            let landed = min(max(raw, window.lowerBound), window.upperBound)
            return PitchEditorGeometry.storedOffsetCents(drawnMidi: landed, centreMidi: d.centreMidi,
                                                         clipPitchShiftSemitones: shift)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
        }
        #expect(model.beginPitchDrag(on: d))
        var mismatches: [CGFloat] = []
        for t in sweep {
            model.updatePitchDrag(translationHeight: t, free: true)
            if model.drag!.offsetCents.bitPattern != frozenOne(t).bitPattern { mismatches.append(t) }
        }
        #expect(mismatches.isEmpty, "one note, \(mismatches.count) of \(sweep.count) differ: \(mismatches.prefix(5))")
        // The COMMIT carries the same bits, and the release leaves the window alone.
        model.updatePitchDrag(translationHeight: -20.123456789, free: true)
        _ = model.endPitchDrag()
        guard case .notePitch(_, let cents)? = sink.commits.last?.kind else {
            Issue.record("no one-note commit")
            return
        }
        #expect(cents.bitPattern == frozenOne(-20.123456789).bitPattern)
        #expect(model.geometry.midiRange == window, "an ungrown release moved the window")
        i6bGroupBitIdentity(sweep: sweep)
    }

    /// The GROUP half of `i6bANonGrowingDragIsBitIdentical`: A pressed, D riding.
    /// The frozen part is the translation → raw step; the delta bounds are the
    /// model's own `groupDeltaBounds`, which I6b does not touch.
    private func i6bGroupBitIdentity(sweep: [CGFloat]) {
        let (model, sink, ids) = fourNotes()
        let rh = model.geometry.rowHeight
        let window = model.geometry.midiRange
        let shift = model.geometry.clipPitchShiftSemitones
        let a = model.blobs[0]
        let d = model.blobs[3]
        let origins = [a, d].map {
            PitchEditorGeometry.drawnMidi(centreMidi: $0.centreMidi, offsetCents: $0.offsetCents,
                                          clipPitchShiftSemitones: shift)
        }
        let baselines = [a.offsetCents, d.offsetCents]
        let bounds = PitchEditorModel.groupDeltaBounds(origins: origins, baselines: baselines, window: window)
        func frozen(_ t: CGFloat) -> (pressed: Double, member: Double) {
            let raw = origins[0] + -Double(t) / Double(max(1, rh))
            let delta = min(max(raw - origins[0], bounds.lowerBound), bounds.upperBound)
            let pressed = delta == 0 ? baselines[0] : PitchEditorGeometry.storedOffsetCents(
                drawnMidi: origins[0] + delta, centreMidi: a.centreMidi, clipPitchShiftSemitones: shift)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
            return (pressed, (baselines[1] + delta * 100).clamped(to: NoteSegment.pitchOffsetCentsRange))
        }
        model.selectOnly(ids[0])
        model.toggle(ids[3])
        #expect(model.beginSelectionPitchDrag(on: a))
        var mismatches: [CGFloat] = []
        for t in sweep {
            model.updatePitchDrag(translationHeight: t, free: true)
            let want = frozen(t)
            if model.drag!.offsetCents.bitPattern != want.pressed.bitPattern
                || model.drag!.members[0].offsetCents.bitPattern != want.member.bitPattern {
                mismatches.append(t)
            }
        }
        #expect(mismatches.isEmpty, "group, \(mismatches.count) of \(sweep.count) differ: \(mismatches.prefix(5))")
        model.updatePitchDrag(translationHeight: -20.123456789, free: true)
        _ = model.endPitchDrag()
        guard case .notePitches(let offsets, _)? = sink.commits.last?.kind else {
            Issue.record("no group commit")
            return
        }
        let want = frozen(-20.123456789)
        #expect(offsets.first { $0.segmentId == a.id }?.offsetCents.bitPattern == want.pressed.bitPattern)
        #expect(offsets.first { $0.segmentId == d.id }?.offsetCents.bitPattern == want.member.bitPattern)
        #expect(model.geometry.midiRange == window, "an ungrown group release moved the window")
    }

    @Test("I6b — a GROUP in a grown window is still clamped by its TIGHTEST note: D at the grown top, A at the grown bottom")
    func i6bGroupGrowthKeepsTheTightestClamp() {
        let (model, sink, ids) = fourNotes()                        // 53…66; A 57, D 62
        model.selectOnly(ids[0])
        model.toggle(ids[3])
        #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))  // A pressed, D rides
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 0.25) == 3)
        #expect(model.geometry.midiRange == 53...69)
        model.updatePitchDrag(translationHeight: -1000, free: true)
        // D has 69 − 62 = 7 of room above: the group moves 7, D on the grown top.
        #expect(close(model.drag!.offsetCents, 700))
        #expect(close(model.drag!.members[0].targetMidi(clipPitchShiftSemitones: 0), 69))
        // 1.5 then 1.5 more: three rows at the bottom, 50…69.
        #expect(model.growPitchWindowForDrag(side: .trailing, depthFraction: 1, dt: 0.125) == 1)
        #expect(model.growPitchWindowForDrag(side: .trailing, depthFraction: 1, dt: 0.125) == 2)
        #expect(model.geometry.midiRange == 50...69)
        model.updatePitchDrag(translationHeight: 1000, free: true)
        // A has 57 − 50 = 7 of room below: A on the grown bottom, D on 55.
        #expect(close(model.drag!.offsetCents, -700))
        #expect(close(model.drag!.members[0].targetMidi(clipPitchShiftSemitones: 0), 55))
        model.cancelDrag()
        #expect(sink.commits.isEmpty)
    }

    @Test("I6b — a relayout MID-DRAG (a restore) holds the draft's note on the window with its name row; with no drag the same restore gives the notes' own window")
    func i6bARelayoutMidDragKeepsTheDraft() {
        let (model, sink, _) = fourNotes()
        model.setAvailableHeight(503)                               // 43…77
        #expect(model.beginPitchDrag(on: model.blobs[3]))
        model.updatePitchDrag(translationHeight: -400, free: true)
        #expect(close(model.drag!.targetMidi, 77))
        // RESTORE mid-drag: the fill alone is 53…66, which the draft (77) is not on.
        model.setAvailableHeight(196)
        #expect(model.geometry.midiRange == 53...78, "the draft was laid out off the window")
        // CONTROL: the same restore with no drag in flight is the notes' own window.
        model.cancelDrag()
        model.setAvailableHeight(503)
        model.setAvailableHeight(196)
        #expect(model.geometry.midiRange == 53...66)
        #expect(sink.commits.isEmpty)
    }

    @Test("I6b — released on a GROWN top row, the note keeps a row above it for its NAME, and the row survives the read-back and the next layout")
    func i6bTheReleaseKeepsTheNamesRow() {
        let (model, sink, _) = fourNotes()                          // 53…66
        let d = model.blobs[3]
        #expect(model.beginPitchDrag(on: d))
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 0.25) == 3)
        model.updatePitchDrag(translationHeight: -1000, free: true)
        #expect(close(model.drag!.targetMidi, 69), "⌥ reaches the grown top row")
        _ = model.endPitchDrag()
        #expect(model.geometry.midiRange == 53...70, "no row above the note for its name")
        guard case .notePitch(let id, let cents)? = sink.commits.last?.kind else {
            Issue.record("no one-note commit")
            return
        }
        #expect(id == d.id && close(cents, 700))
        // The store reads it back, then the pane lays out again (a splitter nudge).
        var segments = model.seedTable.segments
        segments[segments.firstIndex { $0.id == d.id }!].pitchOffsetCents = 700
        model.syncStoredNoteTable(PitchEditSet(segments: segments))
        #expect(model.geometry.midiRange == 53...70)
        model.setAvailableHeight(200)                               // 14 rows: the notes' own fit
        #expect(model.geometry.midiRange == 53...70, "the next layout dropped the name row")
        let rect = model.rect(for: model.blobs[3])
        #expect(rect.minY >= model.geometry.rowHeight, "no row above D for its label: \(rect)")
    }

    // MARK: - I6b S3 — the one edge decision the view executes

    @Test("I6b S3 — the ONE edge decision: an unpromoted press, a cancelled drag and a cut push nothing; a note drag scrolls y while there is room and GROWS at the wall (the bottom revealed against the NEW content), never x; a band scrolls x and y and never grows")
    func i6bTheEdgeDecision() {
        let (model, _, _) = fourNotes()                             // 53…66: 196 pt tall
        let d = model.blobs[3]
        let start = centre(of: d, in: model)
        // DOCKED: the window fills the viewport on y (no room); x has room.
        let docked = PitchEditorViewport(offset: .zero, viewportSize: CGSize(width: 400, height: 196),
                                         contentSize: CGSize(width: 1000, height: 196))
        let top = CGPoint(x: start.x, y: 2)                         // deep in the top band
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        #expect(model.edgeStep(pointer: top, viewport: docked, dt: 1) == .none,
                "an unpromoted press pushes nothing")
        #expect(model.edgePushAxes.isEmpty, "the clock would arm on an unpromoted press")
        _ = model.trackPress(start: start, location: top, modifiers: .none)
        #expect(model.beginSelectionPitchDrag(on: d))
        #expect(model.edgePushAxes == .vertical)
        let grew = model.edgeStep(pointer: top, viewport: docked, dt: 0.25)
        #expect(grew.grownRows >= 1 && grew.edge == .top)
        #expect(grew.scrollY == nil && grew.scrollX == nil, "the top needs no write")
        #expect(model.geometry.midiRange == 53...Double(66 + grew.grownRows))
        #expect(model.edgeGrownRows == grew.grownRows && model.lastEdge == .top)
        // A note drag is y ONLY: deep in the x band at mid-height, nothing.
        #expect(model.edgeStep(pointer: CGPoint(x: 399, y: 98), viewport: docked, dt: 0.25) == .none)
        // The bottom grows too, and its write is the NEW content's own maximum.
        let bottom = model.edgeStep(pointer: CGPoint(x: start.x, y: 194), viewport: docked, dt: 0.25)
        #expect(bottom.grownRows >= 1 && bottom.edge == .bottom)
        #expect(bottom.scrollY == model.geometry.contentHeight - 196, "the grown row was not revealed")
        #expect(model.edgeGrownRows == grew.grownRows + bottom.grownRows && model.lastEdge == .bottom)
        // With ROOM on y it scrolls, exactly `EdgeAutoScroll`'s answer, and grows nothing.
        let content = model.geometry.contentHeight
        let window = model.geometry.midiRange
        let roomy = PitchEditorViewport(offset: CGPoint(x: 0, y: 50), viewportSize: CGSize(width: 400, height: 100),
                                        contentSize: CGSize(width: 1000, height: content))
        let scrolled = model.edgeStep(pointer: CGPoint(x: start.x, y: 52), viewport: roomy, dt: 1)
        #expect(scrolled.scrollY != nil && scrolled.grownRows == 0 && scrolled.edge == .top)
        #expect(scrolled.scrollY == EdgeAutoScroll.push(pointer: 52, offset: 50, viewport: 100, content: content)?.next)
        #expect(model.geometry.midiRange == window)
        model.cancelDrag()
        #expect(model.edgeStep(pointer: top, viewport: docked, dt: 1) == .none, "a cancelled drag pushes nothing")

        // A BAND scrolls on x AND y, and never grows — not even at a wall.
        let empty = emptyPoint(model)
        _ = model.trackPress(start: empty, location: empty, modifiers: .none)
        _ = model.trackPress(start: empty, location: CGPoint(x: 398, y: 98), modifiers: .none)
        #expect(model.band != nil)
        #expect(model.edgePushAxes == .both)
        let room = PitchEditorViewport(offset: .zero, viewportSize: CGSize(width: 400, height: 100),
                                       contentSize: CGSize(width: 1000, height: content))
        let band = model.edgeStep(pointer: CGPoint(x: 398, y: 98), viewport: room, dt: 1)
        #expect(band.scrollX == EdgeAutoScroll.push(pointer: 398, offset: 0, viewport: 400, content: 1000)?.next)
        #expect(band.scrollY == EdgeAutoScroll.push(pointer: 98, offset: 0, viewport: 100, content: content)?.next)
        #expect(band.scrollX != nil && band.scrollY != nil && band.grownRows == 0)
        #expect(model.edgeStep(pointer: CGPoint(x: 200, y: 2), viewport: docked, dt: 1) == .none,
                "a band at the top wall grew or scrolled")
        #expect(model.geometry.midiRange == window)
        model.cancelDrag()

        // A CUT pushes nothing.
        model.tool = .scissors
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        _ = model.trackPress(start: start, location: top, modifiers: .none)
        #expect(model.edgeStep(pointer: top, viewport: docked, dt: 1) == .none)
        #expect(model.edgePushAxes.isEmpty)
        model.cancelDrag()
        model.tool = .pointer
    }

    // MARK: - S4 follow-up — each guard that keeps a band from growing the window, ALONE

    /// ⚠️ **TWO GUARDS, EACH PINNED ON ITS OWN.** A band never grows the pitch
    /// window, and two things say so: `edgeStep`'s `.band` arm answers
    /// `grows: false`, and `growPitchWindowForDrag` returns 0 with no drag. S4's
    /// plant 3 (the arm flipped to `true`) stayed GREEN because the second guard
    /// still stopped the band — each hid the other's removal. These two tests
    /// each read ONE guard directly, so a plant of either goes red on its own.
    @Test("S4 — guard A ALONE: with no drag in flight (a band live, at a wall), growPitchWindowForDrag grows nothing on either side, at any depth or dt")
    func s4NoDragNeverGrowsTheWindow() {
        let (model, _, _) = fourNotes()                             // 53…66
        let empty = emptyPoint(model)
        _ = model.trackPress(start: empty, location: empty, modifiers: .none)
        _ = model.trackPress(start: empty, location: CGPoint(x: empty.x + 60, y: 2), modifiers: .none)
        #expect(model.band != nil && model.drag == nil, "precondition — a band, and no drag")
        for side in [EdgeAutoScroll.Side.leading, .trailing] {
            for dt in [0.05, 0.25, 1, 10] {
                #expect(model.growPitchWindowForDrag(side: side, depthFraction: 1, dt: dt) == 0,
                        "side \(side), dt \(dt)")
            }
        }
        #expect(model.geometry.midiRange == 53...66, "the window grew with no drag")
        model.cancelDrag()
        // CONTROL — the same call with a drag in flight DOES grow.
        #expect(model.beginPitchDrag(on: model.blobs[3]))
        #expect(model.growPitchWindowForDrag(side: .leading, depthFraction: 1, dt: 0.25) == 3)
        model.cancelDrag()
    }

    @Test("S4 — guard B ALONE: the edge decision's `.band` arm never grows (edgeGrowsAtWall is false for a band, true for a note drag); read straight from the switch, so the drag guard cannot stand in for it")
    func s4TheBandArmNeverGrows() {
        let (model, _, _) = fourNotes()
        #expect(!model.edgeGrowsAtWall, "no press, no growth")
        let empty = emptyPoint(model)
        _ = model.trackPress(start: empty, location: empty, modifiers: .none)
        _ = model.trackPress(start: empty, location: CGPoint(x: empty.x + 60, y: 2), modifiers: .none)
        #expect(model.band != nil)
        #expect(model.edgePushAxes == .both, "precondition — the band's arm answered")
        #expect(!model.edgeGrowsAtWall, "the `.band` arm says a band grows the pitch window")
        model.cancelDrag()
        // CONTROL — the note-drag arm DOES grow, so the read can say true.
        let d = model.blobs[3]
        let start = centre(of: d, in: model)
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        _ = model.trackPress(start: start, location: CGPoint(x: start.x, y: 2), modifiers: .none)
        #expect(model.beginSelectionPitchDrag(on: d))
        #expect(model.edgeGrowsAtWall, "positive control — a note drag grows at a wall")
        model.cancelDrag()
    }

    // MARK: - UE-1 — sounds with no pitch (unpitched-notes design §1.7, U5 + R21)

    /// ⭐ **THE FROZEN COPY.** `updatePitchDrag`'s one-note arithmetic and the
    /// group branch's `snappedGroupLanding` / `allowedMidi`, copied as they
    /// stood BEFORE UE-1 gave sounds a relative snap (2026-09-25, the tree
    /// UE-1 started from). A notes-only drag must land on these bits exactly,
    /// snapped AND free, one note AND a group, on a chromatic AND a major
    /// scale, from zero AND non-zero baselines. The L3a precedent is
    /// `i6bANonGrowingDragIsBitIdentical`, which froze the FREE branch only;
    /// UE-1 edits the SNAPPED ones, so they are frozen here.
    private enum FrozenDrag {
        static func single(raw: Double, window: ClosedRange<Double>, free: Bool,
                           scale: PitchCorrectionScale, centreMidi: Double, shift: Double) -> Double {
            let clamped = min(max(raw, window.lowerBound), window.upperBound)
            let landed = free
                ? clamped
                : scale.nearestAllowedMidi(
                    to: min(max(raw, window.lowerBound + 1), window.upperBound - 1))
            return PitchEditorGeometry.storedOffsetCents(
                drawnMidi: landed, centreMidi: centreMidi, clipPitchShiftSemitones: shift)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
        }

        static func allowedMidi(from midi: Double, step: Double,
                                scale: PitchCorrectionScale) -> Double? {
            let allowed = Set(scale.allowedPitchClasses)
            var candidate = step < 0 ? midi.rounded(.down) : midi.rounded(.up)
            for _ in 0...12 {
                if allowed.contains(((Int(candidate) % 12) + 12) % 12) { return candidate }
                candidate += step
            }
            return nil
        }

        static func groupLanding(origin: Double, rawDelta: Double, bounds: ClosedRange<Double>,
                                 scale: PitchCorrectionScale) -> (Double, Double) {
            let target = origin + min(max(rawDelta, bounds.lowerBound), bounds.upperBound)
            var landed = scale.nearestAllowedMidi(to: target)
            if landed - origin > bounds.upperBound {
                landed = allowedMidi(from: origin + bounds.upperBound, step: -1, scale: scale) ?? origin
            } else if landed - origin < bounds.lowerBound {
                landed = allowedMidi(from: origin + bounds.lowerBound, step: 1, scale: scale) ?? origin
            }
            let delta = landed - origin
            guard delta <= bounds.upperBound + 1e-9, delta >= bounds.lowerBound - 1e-9 else {
                return (0, origin)
            }
            return (min(max(delta, bounds.lowerBound), bounds.upperBound), landed)
        }

        /// (pressed, member) offsets for a two-note group drag.
        static func group(raw: Double, origins: [Double], baselines: [Double],
                          window: ClosedRange<Double>, free: Bool, scale: PitchCorrectionScale,
                          pressedCentreMidi: Double, shift: Double) -> (Double, Double) {
            let bounds = PitchEditorModel.groupDeltaBounds(origins: origins, baselines: baselines,
                                                           window: window)
            let rawDelta = raw - origins[0]
            let delta: Double
            let landed: Double
            if free {
                delta = min(max(rawDelta, bounds.lowerBound), bounds.upperBound)
                landed = origins[0] + delta
            } else {
                (delta, landed) = groupLanding(origin: origins[0], rawDelta: rawDelta,
                                               bounds: bounds, scale: scale)
            }
            let pressed = delta == 0 ? baselines[0] : PitchEditorGeometry.storedOffsetCents(
                drawnMidi: landed, centreMidi: pressedCentreMidi, clipPitchShiftSemitones: shift)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
            return (pressed, (baselines[1] + delta * 100).clamped(to: NoteSegment.pitchOffsetCentsRange))
        }
    }

    /// The translation sweep every UE-1 bit-identity check drives.
    private static var ue1Sweep: [CGFloat] {
        var sweep: [CGFloat] = [-0.0, 0, 1e-9, -1e-9, 0.3, -0.3, 6.99, -6.99, 7, -7, 7.01, -7.01,
                                13.99, -14, 20.123456789, -55.5, 100.7, -100.7, 333.3333, -333.3333,
                                -1000, 1000]
        sweep += stride(from: -300, through: 300, by: 0.37).map { CGFloat($0) }
        return sweep
    }

    @Test("UE-1 — a NOTES-ONLY drag is bit-identical to the frozen pre-UE-1 arithmetic: one note and a group, snapped and free, chromatic and major, zero and non-zero baselines")
    func ue1NotesOnlyDragIsBitIdenticalToTheFrozenArithmetic() {
        let scales = [PitchCorrectionScale.chromatic,
                      PitchCorrectionScale(tonicPitchClass: 2, mode: .major)]
        // Baselines: as sung, then A and D already moved by off-grid amounts.
        let baselineSets: [(a: Double, d: Double)] = [(0, 0), (37, -120)]
        var report: [String] = []
        for scale in scales {
            for baselines in baselineSets {
                for free in [false, true] {
                    // ONE NOTE: D.
                    let (model, _, _) = fourNotes()
                    var table = model.noteTable
                    table.segments[0].pitchOffsetCents = baselines.a
                    table.segments[3].pitchOffsetCents = baselines.d
                    model.syncStoredNoteTable(table)
                    model.snapScale = scale
                    let rh = model.geometry.rowHeight
                    let window = model.geometry.midiRange
                    let shift = model.geometry.clipPitchShiftSemitones
                    let d = model.blobs[3]
                    let origin = PitchEditorGeometry.drawnMidi(
                        centreMidi: d.centreMidi, offsetCents: d.offsetCents,
                        clipPitchShiftSemitones: shift)
                    #expect(model.beginPitchDrag(on: d))
                    var misses = 0
                    for t in Self.ue1Sweep {
                        model.updatePitchDrag(translationHeight: t, free: free)
                        let want = FrozenDrag.single(raw: origin + -Double(t) / Double(max(1, rh)),
                                                     window: window, free: free, scale: scale,
                                                     centreMidi: d.centreMidi, shift: shift)
                        if model.drag!.offsetCents.bitPattern != want.bitPattern { misses += 1 }
                    }
                    model.cancelDrag()
                    if misses > 0 { report.append("one \(scale.mode) \(baselines) free=\(free): \(misses)") }

                    // A GROUP: A pressed, D riding.
                    let (group, _, ids) = fourNotes()
                    var groupTable = group.noteTable
                    groupTable.segments[0].pitchOffsetCents = baselines.a
                    groupTable.segments[3].pitchOffsetCents = baselines.d
                    group.syncStoredNoteTable(groupTable)
                    group.snapScale = scale
                    let a = group.blobs[0]
                    let member = group.blobs[3]
                    let origins = [a, member].map {
                        PitchEditorGeometry.drawnMidi(centreMidi: $0.centreMidi, offsetCents: $0.offsetCents,
                                                      clipPitchShiftSemitones: shift)
                    }
                    group.selectOnly(ids[0])
                    group.toggle(ids[3])
                    #expect(group.beginSelectionPitchDrag(on: a))
                    var groupMisses = 0
                    for t in Self.ue1Sweep {
                        group.updatePitchDrag(translationHeight: t, free: free)
                        let want = FrozenDrag.group(
                            raw: origins[0] + -Double(t) / Double(max(1, rh)), origins: origins,
                            baselines: [a.offsetCents, member.offsetCents],
                            window: group.geometry.midiRange, free: free, scale: scale,
                            pressedCentreMidi: a.centreMidi, shift: shift)
                        if group.drag!.offsetCents.bitPattern != want.0.bitPattern
                            || group.drag!.members[0].offsetCents.bitPattern != want.1.bitPattern {
                            groupMisses += 1
                        }
                    }
                    group.cancelDrag()
                    if groupMisses > 0 {
                        report.append("group \(scale.mode) \(baselines) free=\(free): \(groupMisses)")
                    }
                }
            }
        }
        #expect(report.isEmpty, "\(Self.ue1Sweep.count) ticks per leg; legs that differ: \(report)")
    }

    /// `segment` as a SOUND (`NoteOrigin.unpitched`): same id, span and borrowed
    /// anchor — `origin` is a `let`, so a sound is a new segment, as U-A's
    /// builders make it.
    private func soundCopy(of segment: NoteSegment, offsetCents: Double? = nil) -> NoteSegment {
        NoteSegment(id: segment.id, startSeconds: segment.startSeconds,
                    endSeconds: segment.endSeconds, detectedHz: segment.detectedHz,
                    detectedConfidence: segment.detectedConfidence,
                    pitchOffsetCents: offsetCents ?? segment.pitchOffsetCents, origin: .unpitched)
    }

    /// `fourNotes` (A3 · B3 · C4 · D4, window 53…66) with the notes at `indices`
    /// turned into SOUNDS and every entry of `offsets` applied, STORED — the
    /// table the store hands a pane once U-A made sounds.
    private func withSounds(_ indices: Set<Int>, offsets: [Int: Double] = [:])
        -> (model: PitchEditorModel, sink: Box, ids: [UUID]) {
        let (model, sink, ids) = fourNotes()
        var table = model.noteTable
        for index in table.segments.indices {
            if indices.contains(index) {
                table.segments[index] = soundCopy(of: table.segments[index], offsetCents: offsets[index])
            } else if let offset = offsets[index] {
                table.segments[index].pitchOffsetCents = offset
            }
        }
        model.syncStoredNoteTable(table)
        return (model, sink, ids)
    }

    @Test("UE-1 — a blob KNOWS it is a sound: its origin is the segment's, it prints no cents (not even moved), it carries §1.7's sentence and a `.sound` menu target; the same segment as a NOTE is unchanged")
    func ue1ABlobKnowsASound() {
        // Off the grid by +40 c AND moved +300 c, so a note here HAS both numbers.
        let segment = NoteSegment(startSeconds: 0.3, endSeconds: 0.62,
                                  detectedHz: 440 * pow(2, 40.0 / 1200), detectedConfidence: 0.6,
                                  pitchOffsetCents: 300)
        let note = NoteBlob(segment: segment, frameCount: 0)
        let sound = NoteBlob(segment: soundCopy(of: segment), frameCount: 0)
        // POSITIVE CONTROL: the note prints both numbers, so their absence below is the rule.
        #expect(note.centsReadout == "+40 cents")
        #expect(note.offsetReadout == "+300 cents")
        #expect(note.origin == .detected && !note.isUnpitched && note.soundReadout == nil)
        #expect(note.menuTarget == PitchEditorNoteMenu.Target(kind: .note, isCleared: false))

        #expect(sound.origin == .unpitched && sound.isUnpitched)
        #expect(sound.centsReadout == nil && sound.offsetReadout == nil)
        #expect(sound.soundReadout
                == "No pitch found. Moving it shifts this sound: a breath or an 's' just gets brighter or darker.")
        #expect(sound.menuTarget == PitchEditorNoteMenu.Target(kind: .sound, isCleared: false))
        // It is still drawn where its anchor is, and still carries its edit.
        #expect(sound.centreMidi == note.centreMidi && sound.offsetCents == 300)

        // Through the MODEL: the stored table's sound is the blob's sound.
        let (model, _, ids) = withSounds([1])
        #expect(model.blobs.map(\.isUnpitched) == [false, true, false, false])
        #expect(model.blobs[1].id == ids[1])
        // A blob built with no segment (a contour run) is a note.
        #expect(NoteBlob(startSeconds: 0, endSeconds: 1, detectedHz: 220, medianConfidence: 0.9,
                         frameCount: 4).origin == .detected)
    }

    @Test("UE-1 — dragging a SOUND reads §1.7's sentence from the press on, with no note name and no cents; a note's label keeps its pre-UE-1 text")
    func ue1ADraggingASoundReadsTheSentence() {
        let (model, _, _) = withSounds([1])
        let rh = model.geometry.rowHeight
        #expect(model.beginPitchDrag(on: model.blobs[1]))
        #expect(model.drag!.isUnpitched)
        #expect(model.drag!.readout == PitchEditorReadout.unpitchedSound)
        // UE-2: over the blob, the two-word TAG; the sentence is the palette's.
        #expect(model.drag!.overlayLabel == PitchEditorReadout.unpitchedSoundTag)
        model.updatePitchDrag(translationHeight: -2 * rh, free: false)
        #expect(model.drag!.overlayLabel == PitchEditorReadout.unpitchedSoundTag)
        model.updatePitchDrag(translationHeight: -2.3 * rh, free: true)
        #expect(model.drag!.readout == PitchEditorReadout.unpitchedSound, "⌥ is free, still no number")
        model.cancelDrag()
        // The NOTE beside it: nothing drawn unmoved, then "name  cents", as before.
        #expect(model.beginPitchDrag(on: model.blobs[0]))
        #expect(!model.drag!.isUnpitched)
        #expect(model.drag!.overlayLabel == nil, "an unmoved note draws no label")
        model.updatePitchDrag(translationHeight: -2 * rh, free: false)
        #expect(model.drag!.overlayLabel == "B3  +200 cents")
        #expect(model.drag!.overlayLabel == model.drag!.readout.map { "\(model.drag!.targetNoteName)  \($0)" })
        model.cancelDrag()
    }

    @Test("UE-1 — a SOUND moves in WHOLE SEMITONES FROM WHERE IT SITS: its off-grid offset is kept, the scale is ignored, ⌥ is free, and the release commits the exact offset")
    func ue1ASoundMovesInWholeSemitonesFromWhereItSits() {
        // B3 as a sound, already moved +37 c: drawn at 59.37. On C major a NOTE
        // here would snap one row up to C4 (60), an offset of +100; the sound
        // goes to +137.
        let (model, sink, ids) = withSounds([1], offsets: [1: 37])
        model.snapScale = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)
        let rh = model.geometry.rowHeight
        #expect(model.beginPitchDrag(on: model.blobs[1]))
        model.updatePitchDrag(translationHeight: -0.4 * rh, free: false)
        #expect(model.drag!.offsetCents.bitPattern == (37.0).bitPattern, "under half a row moved it")
        #expect(model.drag!.isNoOp)
        model.updatePitchDrag(translationHeight: -0.6 * rh, free: false)
        #expect(model.drag!.offsetCents.bitPattern == (137.0).bitPattern)
        model.updatePitchDrag(translationHeight: -2.49 * rh, free: false)
        #expect(model.drag!.offsetCents.bitPattern == (237.0).bitPattern)
        model.updatePitchDrag(translationHeight: 1.6 * rh, free: false)
        #expect(model.drag!.offsetCents.bitPattern == (-163.0).bitPattern)
        #expect(!model.drag!.isFree)
        // ⌥ — free, continuous: exactly the arithmetic a note's free drag uses.
        model.updatePitchDrag(translationHeight: -0.3 * rh, free: true)
        #expect(model.drag!.isFree)
        #expect(close(model.drag!.offsetCents, 67, 1e-6))
        // The window clamps in WHOLE semitones: 66 − 59.37 = 6.63 of room, so 6.
        model.updatePitchDrag(translationHeight: -40 * rh, free: false)
        #expect(model.drag!.offsetCents.bitPattern == (637.0).bitPattern)
        model.updatePitchDrag(translationHeight: -3 * rh, free: false)
        _ = model.endPitchDrag()
        guard case .notePitch(let id, let cents)? = sink.commits.last?.kind else {
            Issue.record("a sound's drag committed nothing")
            return
        }
        #expect(id == ids[1])
        #expect(cents.bitPattern == (337.0).bitPattern)
        // Released where it began: no commit.
        #expect(model.beginPitchDrag(on: model.blobs[1]))
        model.updatePitchDrag(translationHeight: -0.49 * rh, free: false)
        #expect(model.endPitchDrag() == nil)
        #expect(sink.commits.count == 1)
    }

    @Test("UE-1 — the GROUP rule: the PRESSED blob decides the snap and every member rides its ONE delta — a sound pressed moves the group in whole semitones (a note riding keeps its sung offset, off the scale); a note pressed snaps to the scale and a sound riding takes that delta")
    func ue1AGroupRuleThePressedBlobDecides() {
        let major = PitchCorrectionScale(tonicPitchClass: 0, mode: .major)
        // (i) SOUND pressed (B3 +37 c), NOTE riding (D4, as sung).
        do {
            let (model, sink, ids) = withSounds([1], offsets: [1: 37])
            model.snapScale = major
            let rh = model.geometry.rowHeight
            model.selectOnly(ids[1])
            model.toggle(ids[3])
            #expect(model.beginSelectionPitchDrag(on: model.blobs[1]))
            #expect(model.drag!.members.map(\.isUnpitched) == [false])
            model.updatePitchDrag(translationHeight: -0.6 * rh, free: false)
            // +1 each: D4 → D♯4, which C major does not allow — the interval is kept.
            #expect(model.drag!.offsetCents.bitPattern == (137.0).bitPattern)
            #expect(model.drag!.members[0].offsetCents.bitPattern == (100.0).bitPattern)
            // The TIGHTEST member clamps, in whole semitones: D4 has 66 − 62 = 4.
            model.updatePitchDrag(translationHeight: -10 * rh, free: false)
            #expect(model.drag!.offsetCents.bitPattern == (437.0).bitPattern)
            #expect(model.drag!.members[0].offsetCents.bitPattern == (400.0).bitPattern)
            _ = model.endPitchDrag()
            guard case .notePitches(let offsets, _)? = sink.commits.last?.kind else {
                Issue.record("a group led by a sound committed nothing")
                return
            }
            #expect(offsets.map(\.segmentId) == [ids[1], ids[3]])
            #expect(offsets.map(\.offsetCents) == [437, 400])
        }
        // (ii) NOTE pressed (A3 +45 c, drawn 57.45), SOUND riding (B3 +37 c).
        do {
            let (model, _, ids) = withSounds([1], offsets: [0: 45, 1: 37])
            model.snapScale = major
            let rh = model.geometry.rowHeight
            model.selectOnly(ids[0])
            model.toggle(ids[1])
            #expect(model.beginSelectionPitchDrag(on: model.blobs[0]))
            #expect(!model.drag!.isUnpitched)
            #expect(model.drag!.members.map(\.isUnpitched) == [true])
            model.updatePitchDrag(translationHeight: -1 * rh, free: false)
            // A snaps to the scale: 58.45 → B3 (59), a delta of 1.55 semitones.
            #expect(close(model.drag!.targetMidi, 59))
            // The sound rides that SAME delta — fractional — so it stays at its note.
            #expect(close(model.drag!.members[0].offsetCents, 37 + 155, 1e-9))
            model.cancelDrag()
        }
        // (iii) SOUNDS only: B3 pressed, C4 riding — both move by whole semitones.
        do {
            let (model, _, ids) = withSounds([1, 2], offsets: [1: 37, 2: -12])
            model.snapScale = major
            let rh = model.geometry.rowHeight
            model.selectOnly(ids[1])
            model.toggle(ids[2])
            #expect(model.beginSelectionPitchDrag(on: model.blobs[1]))
            model.updatePitchDrag(translationHeight: 1.6 * rh, free: false)
            #expect(model.drag!.offsetCents.bitPattern == (-163.0).bitPattern)
            #expect(model.drag!.members[0].offsetCents.bitPattern == (-212.0).bitPattern)
            model.cancelDrag()
        }
    }

    @Test("UE-1 — a sound's drag is HEARD: one drag step per whole semitone, carrying its id and exact offset, snapped — a transposed breath (U5), never a silent no-op")
    func ue1ASoundDragIsHeard() {
        let (model, _, ids) = withSounds([1], offsets: [1: 37])
        let audition = listen(model)
        let rh = model.geometry.rowHeight
        #expect(model.beginPitchDrag(on: model.blobs[1]))
        model.updatePitchDrag(translationHeight: -0.4 * rh, free: false)
        #expect(dragSteps(audition).isEmpty, "nothing moved, nothing to hear")
        model.updatePitchDrag(translationHeight: -0.6 * rh, free: false)
        model.updatePitchDrag(translationHeight: -0.9 * rh, free: false)   // still +1
        model.updatePitchDrag(translationHeight: -1.6 * rh, free: false)
        let steps = dragSteps(audition)
        #expect(steps.count == 2, "\(steps.map(\.offsets))")
        #expect(steps.map { $0.offsets.map(\.segmentId) } == [[ids[1]], [ids[1]]])
        #expect(steps.map { $0.offsets.map(\.offsetCents) } == [[137], [237]])
        #expect(steps.allSatisfy { $0.snapped })
        model.cancelDrag()
    }

    @Test("UE-1 — the menu and the status line NAME a sound: \"Clear Sound\", \"Clear 2 Selected\" for a mix, \"Restore Sound\"; Clear carries the sound's id; \"1 sound selected\", \"1 note and 1 sound selected\"; a notes-only selection reads as before")
    func ue1AMenuAndStatusNameASound() {
        let (model, sink, ids) = withSounds([1])
        model.selectOnly(ids[1])
        #expect(model.selectionSummary == "1 sound selected")
        #expect(model.noteMenu(at: nil).map(\.title) == ["Clear Sound"])
        model.toggle(ids[0])
        #expect(model.selectionSummary == "1 note and 1 sound selected")
        #expect(model.noteMenu(at: nil).map(\.title) == ["Clear 2 Selected"])
        model.selectOnly(ids[1])
        model.performNoteAction(.clear)
        guard case .notesCleared(let cleared, true)? = sink.commits.last?.kind else {
            Issue.record("Clear on a sound committed nothing")
            return
        }
        #expect(cleared == [ids[1]])
        // The store hands it back cleared: the way back names it.
        var table = model.noteTable
        table.segments[1].isCleared = true
        model.syncStoredNoteTable(table)
        #expect(model.noteMenu(at: nil).map(\.title) == ["Clear Sounds", "Restore Sound"])
        #expect(model.blobs[1].isCleared && model.blobs[1].isUnpitched)
        // Notes only: exactly the pre-UE-1 words.
        model.selectOnly(ids[0])
        model.toggle(ids[2])
        #expect(model.selectionSummary == "2 notes selected")
        #expect(model.noteMenu(at: nil).map(\.title) == ["Clear 2 Notes"])
    }

    @Test("UE-1 — Find sounds with no pitch: offered only for a STORED table with no sound; one press runs once (a second is ignored while it works) and is never a commit; a table the store would refuse is refused in words without asking it")
    func ue1AFindSoundsOffersAndRunsOnce() {
        let (model, _, _) = fourNotes()
        #expect(model.storedTable == nil)
        #expect(!model.offersFindSounds, "a seed already has its sounds")
        // A stored table with no sound: the pre-U-A shape.
        model.syncStoredNoteTable(model.noteTable)
        #expect(model.offersFindSounds)
        #expect(model.findSoundsLine == nil)
        #expect(model.beginFindSounds())
        #expect(model.isFindingSounds)
        #expect(model.findSoundsLine == PitchEditorFindSounds.workingLine)
        #expect(!model.beginFindSounds(), "a second press while the first works")
        #expect(model.commitCount == 0, "finding sounds is the store's own undo step, never a commit")
        model.finishFindSounds(.finished(added: 3, skipped: nil))
        #expect(!model.isFindingSounds)
        #expect(model.findSoundsLine == PitchEditorFindSoundsLine(
            kind: .done,
            text: "Added 3 sounds with no pitch, like breaths and \"s\" sounds. Undo takes them away."))
        // Once the table holds a sound, it is no longer offered.
        #expect(!withSounds([2]).model.offersFindSounds)
        // Another detector generation: refused in words, before the store is asked.
        let old = PitchEditSet(analysisVersion: PitchEditSet.currentAnalysisVersion + 1,
                               segments: model.noteTable.segments)
        model.syncStoredNoteTable(old)
        #expect(model.offersFindSounds)
        #expect(!model.beginFindSounds())
        #expect(model.findSoundsLine?.kind == .shortfall)
        #expect(model.findSoundsLine?.text == PitchEditorFindSounds.refusal(storedTable: old))
        #expect(model.findSoundsLine?.text.contains("older version") == true)
    }

    @Test("UE-1 — Find sounds' words: each finder guard says nothing was added and why (three different sentences); finding nothing says so; one sound reads in the singular; a refusal is shown verbatim")
    func ue1AFindSoundsWords() {
        func line(_ outcome: PitchEditorFindSoundsOutcome) -> PitchEditorFindSoundsLine {
            PitchEditorFindSounds.line(for: outcome)
        }
        var guards: Set<String> = []
        for reason in PitchUnpitchedFinder.SkipReason.allCases {
            let said = line(.finished(added: 0, skipped: reason))
            #expect(said.kind == .shortfall)
            #expect(said.text.hasPrefix("Nothing was added: "))
            #expect(said.text == PitchEditorFindSounds.skipLine(reason))
            guards.insert(said.text)
        }
        #expect(guards.count == PitchUnpitchedFinder.SkipReason.allCases.count)
        #expect(PitchEditorFindSounds.skipLine(.notEnoughQuiet).contains("1 second"))
        let none = line(.finished(added: 0, skipped: nil))
        #expect(none.kind == .done)
        #expect(none.text == "Found no breaths or other sounds between the notes, so nothing was added.")
        #expect(line(.finished(added: 1, skipped: nil)).text
                == "Added 1 sound with no pitch, like a breath or an \"s\". Undo takes it away.")
        #expect(line(.refused("That clip is gone.")) == PitchEditorFindSoundsLine(kind: .shortfall,
                                                                                text: "That clip is gone."))
    }

    @Test("UE-1 — Find sounds' pre-check AGREES with the store: the two tables `findUnpitchedSounds` refuses before reading the pitch are the two the editor refuses in words, and a current table passes both")
    func ue1AFindSoundsPreCheckAgreesWithTheStore() async {
        let segments = [NoteSegment(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220,
                                    detectedConfidence: 0.9)]
        let cases: [(name: String, table: PitchEditSet?)] = [
            ("no table", nil),
            ("another detector", PitchEditSet(analysisVersion: PitchEditSet.currentAnalysisVersion + 1,
                                              segments: segments)),
            ("current", PitchEditSet(segments: segments)),
        ]
        for (name, table) in cases {
            // An audio clip with NO file: a store past its table checks fails
            // next at `detectClipPitch` with `pitchDetectionRequiresAudioClip`,
            // which is how this test sees that it got past them.
            let clip = Clip(name: "UE-1 \(name)", startBeat: 0, lengthBeats: 8, audioFileURL: nil,
                            pitchEdits: table)
            let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
            var storeRefusedTheTable = false
            do {
                _ = try await store.findUnpitchedSounds(clipId: clip.id)
                Issue.record("\(name): the store ran with no file")
            } catch ProjectError.invalidClipEdit(_) {
                storeRefusedTheTable = true
            } catch ProjectError.pitchDetectionRequiresAudioClip(_) {
                storeRefusedTheTable = false
            } catch {
                Issue.record("\(name): unexpected \(error)")
            }
            let editorRefuses = PitchEditorFindSounds.refusal(storedTable: table) != nil
            #expect(editorRefuses == storeRefusedTheTable, "\(name): editor \(editorRefuses), store \(storeRefusedTheTable)")
        }
    }

    // MARK: - UE-2 — how a sound LOOKS, and the words around it

    @Test("UE-2 — the LOOK has one home and one precedence: a note draws as a note, a sound as a sound (moved or not), and a CLEARED blob draws cleared whatever it is; through the model, the stored sound is the one drawn striped")
    func ue2TheLookPrecedence() {
        let segment = NoteSegment(startSeconds: 0.3, endSeconds: 0.62, detectedHz: 440,
                                  detectedConfidence: 0.59, pitchOffsetCents: 0)
        var cleared = segment
        cleared.isCleared = true
        var clearedSound = soundCopy(of: segment)
        clearedSound.isCleared = true
        #expect(NoteBlob(segment: segment, frameCount: 0).look == .note)
        #expect(NoteBlob(segment: soundCopy(of: segment), frameCount: 0).look == .sound)
        #expect(NoteBlob(segment: soundCopy(of: segment, offsetCents: 300), frameCount: 0).look == .sound,
                "a MOVED sound is still a sound (its stripes turn `signal`, like a tuned note)")
        #expect(NoteBlob(segment: cleared, frameCount: 0).look == .cleared)
        #expect(NoteBlob(segment: clearedSound, frameCount: 0).look == .cleared,
                "a cleared sound plays silence: hollow, never striped")
        // Its confidence (0.59, §1.2's median) cannot move the look.
        for confidence in [0.0, 0.59, 1.0] {
            let blob = NoteBlob(startSeconds: 0, endSeconds: 1, detectedHz: 220,
                                medianConfidence: confidence, frameCount: 4, origin: .unpitched)
            #expect(blob.look == .sound)
        }
        let (model, _, _) = withSounds([1])
        #expect(model.blobs.map(\.look) == [.note, .sound, .note, .note])
    }

    @Test("UE-2 — the status line never calls a sound a note: \"Found 3 notes and 1 sound with no pitch.\" on a table with a sound, the pre-UE-2 sentence without one, and every state key unchanged")
    func ue2StatusLineCountsSoundsApart() {
        #expect(PitchEditorState.ready(noteCount: 72, soundCount: 32).message
                == "Found 40 notes and 32 sounds with no pitch.")
        #expect(PitchEditorState.ready(noteCount: 2, soundCount: 1).message
                == "Found 1 note and 1 sound with no pitch.")
        #expect(PitchEditorState.ready(noteCount: 3, soundCount: 3).message == "Found 3 sounds with no pitch.")
        // CONTROL: no sound, the sentence every earlier pin knows.
        #expect(PitchEditorState.ready(noteCount: 12).message == "Found 12 notes.")
        #expect(PitchEditorState.ready(noteCount: 12, soundCount: 0).message == "Found 12 notes.")
        #expect(PitchEditorState.ready(noteCount: 72, soundCount: 32).statusKey == "ready")
        // Through the model: the stored sound is counted as a sound.
        let (model, _, _) = withSounds([1])
        #expect(model.state == .ready(noteCount: 4, soundCount: 1))
        #expect(model.state.message == "Found 3 notes and 1 sound with no pitch.")
        #expect(fourNotes().model.state.message == "Found 4 notes.")
    }

    @Test("UE-2 — the header's legend explains the stripes ONLY while a sound is drawn striped, and says nothing with no notes on screen")
    func ue2LegendExplainsTheStripes() {
        #expect(PitchEditorSoundLook.legend(drawsNotes: false, drawsSounds: true) == "")
        #expect(PitchEditorSoundLook.legend(drawsNotes: true, drawsSounds: false)
                == "Fainter notes mean we are less sure you were singing there.")
        let both = PitchEditorSoundLook.legend(drawsNotes: true, drawsSounds: true)
        #expect(both == PitchEditorSoundLook.notesLegend + " " + PitchEditorSoundLook.soundsLegend)
        #expect(both.contains("Striped boxes are sounds with no pitch"))
        // A beginner's words: no note name, no number, no jargon.
        #expect(PitchEditorSoundLook.soundsLegend.rangeOfCharacter(from: .decimalDigits) == nil)
        #expect(!PitchEditorSoundLook.soundsLegend.lowercased().contains("unpitched"))
    }

    @Test("UE-2 — a dragged SOUND carries the two-word TAG above itself and the whole §1.7 sentence in the palette readout; the tag is the sentence's own start, with no note name and no number")
    func ue2OverlayTagAndPaletteSentence() {
        let (model, _, _) = withSounds([1])
        let rh = model.geometry.rowHeight
        #expect(model.beginPitchDrag(on: model.blobs[1]))
        model.updatePitchDrag(translationHeight: -3 * rh, free: false)
        let draft = model.drag!
        #expect(draft.overlayLabel == "No pitch")
        #expect(draft.readout == PitchEditorReadout.unpitchedSound, "the palette keeps the whole sentence")
        #expect(PitchEditorReadout.unpitchedSound.hasPrefix(PitchEditorReadout.unpitchedSoundTag))
        #expect(PitchEditorReadout.unpitchedSoundTag.split(separator: " ").count <= 2)
        #expect(!draft.overlayLabel!.contains(draft.targetNoteName))
        #expect(draft.overlayLabel!.rangeOfCharacter(from: .decimalDigits) == nil)
        model.cancelDrag()
    }

    @Test("UE-2 — an UNDONE merge withdraws its \"Added\" line (the table holds no sound again, the button is back); the line stays while the sounds do, and a \"none found\" answer survives a table change")
    func ue2UndoWithdrawsTheAddedLine() {
        let (model, _, _) = fourNotes()
        let soundFree = model.noteTable
        model.syncStoredNoteTable(soundFree)
        #expect(model.beginFindSounds())
        model.finishFindSounds(.finished(added: 2, skipped: nil))
        let added = model.findSoundsLine
        #expect(added?.kind == .done && added?.text.hasPrefix("Added 2 sounds") == true)
        // The merge lands: the table now HOLDS sounds — the line stays.
        var merged = soundFree
        merged.segments[1] = soundCopy(of: merged.segments[1])
        merged.segments[3] = soundCopy(of: merged.segments[3])
        model.syncStoredNoteTable(merged)
        #expect(!model.offersFindSounds)
        #expect(model.findSoundsLine == added, "the sounds it names are on screen")
        // An unrelated edit that keeps a sound: still true, still shown.
        merged.segments[0].pitchOffsetCents = 100
        model.syncStoredNoteTable(merged)
        #expect(model.findSoundsLine == added)
        // UNDO: the table is sound-free again.
        model.syncStoredNoteTable(soundFree)
        #expect(model.offersFindSounds)
        #expect(model.findSoundsLine == nil, "\"Added 2 sounds\" beside the button that is back names sounds that are gone")
        // CONTROL: "none found" is not withdrawn by a table change.
        #expect(model.beginFindSounds())
        model.finishFindSounds(.finished(added: 0, skipped: nil))
        let none = model.findSoundsLine
        #expect(none?.kind == .done)
        var edited = soundFree
        edited.segments[2].pitchOffsetCents = -100
        model.syncStoredNoteTable(edited)
        #expect(model.findSoundsLine == none)
    }

    /// The merge's shape (`ProjectStore.findUnpitchedSounds`): every note KEPT,
    /// with its id, and one sound ADDED in each of the first two gaps, with a
    /// new id — never a note turned into a sound.
    private func merged(_ table: PitchEditSet) -> PitchEditSet {
        let s = table.segments
        let sounds = (0..<2).map { i in
            NoteSegment(startSeconds: s[i].endSeconds, endSeconds: s[i + 1].startSeconds,
                        detectedHz: s[i].detectedHz, detectedConfidence: 0, origin: .unpitched)
        }
        return table.withSegments(s + sounds)
    }

    /// A PRESET pass over the same audio: the same notes and sounds, every one
    /// with a NEW id — what `PitchAutoCorrect.build` mints on each run (pinned
    /// below, `ue2APresetPassMintsNewIDs`).
    private func rebuilt(_ table: PitchEditSet) -> PitchEditSet {
        table.withSegments(table.segments.map {
            NoteSegment(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                        detectedHz: $0.detectedHz, detectedConfidence: $0.detectedConfidence,
                        pitchOffsetCents: $0.pitchOffsetCents, origin: $0.origin)
        })
    }

    @Test("UE-2 edge — a table REBUILT under an \"Added\" line (a preset pass: new ids, sounds still drawn) withdraws it, whichever of the answer and the merge's write reaches the pane first; a pitch drag, a level change and a note's split keep it")
    func ue2ARebuildWithdrawsTheAddedLine() {
        for answerFirst in [true, false] {
            let (model, _, _) = fourNotes()
            let soundFree = model.noteTable
            model.syncStoredNoteTable(soundFree)
            #expect(model.beginFindSounds())
            let withSounds = merged(soundFree)
            if answerFirst {
                model.finishFindSounds(.finished(added: 2, skipped: nil))
                model.syncStoredNoteTable(withSounds)
            } else {
                model.syncStoredNoteTable(withSounds)
                model.finishFindSounds(.finished(added: 2, skipped: nil))
            }
            let added = model.findSoundsLine
            #expect(added?.kind == .done && added?.text.hasPrefix("Added 2 sounds") == true,
                    "answerFirst \(answerFirst): \(String(describing: added))")
            // Edits that keep every sound: the line stays.
            var edited = withSounds
            edited.segments[0].pitchOffsetCents = 100               // a pitch drag
            edited.segments[1].amplitudeDb = -6                     // a level change
            model.syncStoredNoteTable(edited)
            let note = edited.segments[2]
            let mid = (note.startSeconds + note.endSeconds) / 2
            var split = edited
            split.segments[2] = NoteSegment(startSeconds: note.startSeconds, endSeconds: mid,
                                            detectedHz: note.detectedHz,
                                            detectedConfidence: note.detectedConfidence)
            split.segments.append(NoteSegment(startSeconds: mid, endSeconds: note.endSeconds,
                                              detectedHz: note.detectedHz,
                                              detectedConfidence: note.detectedConfidence))
            model.syncStoredNoteTable(split.withSegments(split.segments))  // a note's split
            #expect(model.findSoundsLine == added, "answerFirst \(answerFirst): an edit that kept the sounds withdrew it")
            // THE REBUILD: sounds are still drawn (so the old rule, "no sound
            // left", does not fire), but none of them is one the line named.
            let preset = rebuilt(split)
            #expect(preset.segments.contains { $0.origin == .unpitched })
            model.syncStoredNoteTable(preset)
            #expect(!model.offersFindSounds, "precondition — the offer is NOT back, so only the new rule can withdraw")
            #expect(model.findSoundsLine == nil,
                    "answerFirst \(answerFirst): \"Undo takes them away\" would now undo the preset")
        }
    }

    @Test("UE-2 edge — the mechanism: a preset pass builds its table afresh, so two passes over the same audio share NO segment id (the store writes `PitchAutoCorrect.build`'s table as built, stamped)")
    func ue2APresetPassMintsNewIDs() {
        // `fourNotes`' audio (A3 · B3 · C4 · D4), built twice.
        let midis: [Double] = [57, 59, 60, 62]
        var frames: [ClipPitchFrame] = []
        var start = 0.30
        for (index, midi) in midis.enumerated() {
            frames += voiced(count: 20, from: start, hz: 440 * pow(2, (midi - 69) / 12))
            start += 20 * Self.framePeriod
            if index < midis.count - 1 {
                frames += unvoiced(count: 10, from: start)
                start += 10 * Self.framePeriod
            }
        }
        let pitch = detection(frames).pitch
        let first = PitchAutoCorrect.build(from: pitch, options: PitchAutoCorrectOptions()).editSet
        let second = PitchAutoCorrect.build(from: pitch, options: PitchAutoCorrectOptions()).editSet
        #expect(!first.segments.isEmpty && first.segments.count == second.segments.count)
        #expect(Set(first.segments.map(\.id)).isDisjoint(with: second.segments.map(\.id)),
                "a preset pass kept an id — the rebuild rule would not see it")
        // The stamp the store adds keeps them.
        #expect(first.stampedAsAutoCorrectOutput().segments.map(\.id) == first.segments.map(\.id))
    }

    @Test("UE-2 — a finder DECLINE is remembered per clip and table: a pane rebuilt on the same table shows the same button WITH the same answer; another table, another clip, no memory, an \"Added\" line or a store refusal restore nothing")
    func ue2FindSoundsDeclineIsRemembered() {
        let memory = PitchEditorFindSoundsMemory()
        let clipID = UUID()
        let (first, _, _) = fourNotes(clipID: clipID)
        first.findSoundsMemory = memory
        let table = first.noteTable
        first.syncStoredNoteTable(table)
        #expect(first.beginFindSounds())
        first.finishFindSounds(.finished(added: 0, skipped: .notEnoughQuiet))
        let declined = first.findSoundsLine
        #expect(declined == PitchEditorFindSoundsLine(kind: .shortfall,
                                                      text: PitchEditorFindSounds.skipLine(.notEnoughQuiet)))

        // THE REBUILD: a new pane model on the same clip and the same table.
        let rebuilt = PitchEditorModel(clipID: clipID, geometry: first.geometry)
        rebuilt.findSoundsMemory = memory
        rebuilt.syncStoredNoteTable(table)
        #expect(rebuilt.offersFindSounds, "the button stays: it is the only door to asking again")
        #expect(rebuilt.findSoundsLine == declined)
        // A pitch drag keeps every id: still the same answer.
        var moved = table
        moved.segments[0].pitchOffsetCents = 200
        let afterDrag = PitchEditorModel(clipID: clipID, geometry: first.geometry)
        afterDrag.findSoundsMemory = memory
        afterDrag.syncStoredNoteTable(moved)
        #expect(afterDrag.findSoundsLine == declined)

        // CONTROLS — each restores NOTHING.
        func line(clip: UUID, table: PitchEditSet, memory: PitchEditorFindSoundsMemory?) -> PitchEditorFindSoundsLine? {
            let model = PitchEditorModel(clipID: clip, geometry: first.geometry)
            model.findSoundsMemory = memory
            model.syncStoredNoteTable(table)
            return model.findSoundsLine
        }
        let resplit = PitchEditSet(analysisVersion: table.analysisVersion,
                                   segments: table.segments.map {
                                       NoteSegment(startSeconds: $0.startSeconds, endSeconds: $0.endSeconds,
                                                   detectedHz: $0.detectedHz,
                                                   detectedConfidence: $0.detectedConfidence)
                                   })
        #expect(line(clip: clipID, table: resplit, memory: memory) == nil, "new note ids: ask again")
        #expect(line(clip: UUID(), table: table, memory: memory) == nil, "another clip")
        #expect(line(clip: clipID, table: table, memory: nil) == nil, "no memory installed")

        let other = UUID()
        let (added, _, _) = fourNotes(clipID: other)
        added.findSoundsMemory = memory
        added.syncStoredNoteTable(added.noteTable)
        #expect(added.beginFindSounds())
        added.finishFindSounds(.finished(added: 3, skipped: nil))
        #expect(line(clip: other, table: added.noteTable, memory: memory) == nil, "an Added line is never remembered")
        #expect(added.beginFindSounds())
        added.finishFindSounds(.refused("That clip is gone."))
        #expect(line(clip: other, table: added.noteTable, memory: memory) == nil, "a store refusal is never remembered")
    }

    @Test("UE-2 — Edit ▸ Delete NAMES the selection with the note menu's nouns, count-free: \"Clear Selected Notes\" (unchanged), \"Clear Selected Sounds\", \"Clear Selected\" for a mix — on both doors, from the model's selection kinds through the bridge")
    func ue2EditMenuClearTitleNamesTheSelection() {
        #expect(PitchEditorNoteMenu.selectionClearTitle(kinds: [.note]) == "Clear Selected Notes")
        #expect(PitchEditorNoteMenu.selectionClearTitle(kinds: [.sound]) == "Clear Selected Sounds")
        #expect(PitchEditorNoteMenu.selectionClearTitle(kinds: [.note, .sound]) == "Clear Selected")
        #expect(PitchEditorNoteMenu.selectionClearTitle(kinds: []) == "Clear Selected Notes")
        #expect(DeleteMenuPolicy.pitchEditorClearTitle == "Clear Selected Notes")

        func menu(_ kinds: Set<PitchEditorNoteMenu.Kind>) -> DeleteMenuItem {
            DeleteMenuPolicy.editMenuItem(
                arrangeWorkspace: true, isModalPresented: false, pianoRollHasNoteSelection: false,
                automationPointCount: 0, pitchEditorOpen: true, pitchEditorHasNoteSelection: true,
                pitchEditorSelectionKinds: kinds, arrangeClipCount: 1)
        }
        func key(_ kinds: Set<PitchEditorNoteMenu.Kind>) -> DeleteMenuItem {
            DeleteMenuPolicy.keyPress(
                arrangeWorkspace: true, isModalPresented: false, isTextEditingFocused: false,
                pianoRollHasNoteSelection: false, automationPointCount: 0, pitchEditorOpen: true,
                pitchEditorHasNoteSelection: true, pitchEditorSelectionKinds: kinds, arrangeClipCount: 1)
        }
        #expect(menu([.sound]).title == "Clear Selected Sounds")
        #expect(menu([.note, .sound]).title == "Clear Selected")
        #expect(key([.sound]).title == "Clear Selected Sounds", "the key door forwards the noun")
        // The noun changes NOTHING else: same surface, same live state.
        #expect(menu([.sound]).surface == menu([.note]).surface)
        #expect(menu([.sound]).isEnabled && menu([.sound]).refusedBy == nil)
        // A kinds report with NO selection claims nothing (the arm needs the Bool).
        let stale = DeleteMenuPolicy.editMenuItem(
            arrangeWorkspace: true, isModalPresented: false, pianoRollHasNoteSelection: false,
            automationPointCount: 0, pitchEditorOpen: true, pitchEditorHasNoteSelection: false,
            pitchEditorSelectionKinds: [.sound], arrangeClipCount: 1)
        #expect(stale.refusedBy == .pitchEditorOpen)

        // The model's kinds, and the bridge's compare-on-change report.
        let (model, _, ids) = withSounds([1])
        #expect(model.selectionKinds == [])
        model.selectOnly(ids[1])
        #expect(model.selectionKinds == [.sound])
        model.selectOnly(ids[0])
        #expect(model.selectionKinds == [.note])
        model.selectAll()
        #expect(model.selectionKinds == [.note, .sound])
        let bridge = PitchEditorInteractionBridge()
        bridge.report(selectionKinds: model.selectionKinds)
        #expect(bridge.selectionKinds == [.note, .sound])
        let token = UUID()
        bridge.reportSurface(token: token, .empty)
        bridge.clearSurface(from: token)
        #expect(bridge.selectionKinds == [], "a pane that went away leaves no noun behind")
    }
}

// MARK: - I1 UI hooks fakes

/// An engine that counts what the store's audition doors ask of it — the
/// `SpanRenderSpyEngine` (DAWCoreTests) shape, copied because test targets
/// cannot share a private type. The file audition answers `fileAnswer`; a span
/// render is accepted and never finishes, so the one in flight stays in flight.
@MainActor
private final class AuditionTestEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var fileAnswer: AuditionOutcome = .sounded
    private(set) var fileCalls: [(start: Double, end: Double)] = []
    private(set) var spanCalls: [ClipSpanAuditionSource] = []
    private(set) var stopCount = 0

    func auditionClipSpan(trackID: UUID, clipID: UUID, startSourceSeconds: Double,
                          endSourceSeconds: Double) -> AuditionOutcome {
        fileCalls.append((startSourceSeconds, endSourceSeconds))
        return fileAnswer
    }

    func auditionClipSpan(trackID: UUID, clipID: UUID, startSourceSeconds: Double,
                          endSourceSeconds: Double, source: ClipSpanAuditionSource,
                          completion: (@MainActor @Sendable (ClipSpanAuditionDelivery) -> Void)?)
        -> AuditionOutcome {
        spanCalls.append(source)
        return .sounded
    }

    func stopClipSpanAudition() { stopCount += 1 }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
}

/// ⚠️ A HANG GUARD, NOT A LATENCY CLAIM: how long a test waits for a
/// main-actor event before giving up on a product that never delivers it.
/// Every `@MainActor` suite shares the one main thread, and in a full run a
/// turn on it can come very late. MEASURED 2026-09-25 (`full-suite-0847.log`,
/// 9637 tests, run alone): `theWaitPollsItself` took 81.0 s and missed two
/// 5 s deadlines, 2942 of 9583 test results took 60 s or more, and the longest
/// took 374 s. Across 24 full runs 2026-09-22…25 the "PitchEditorModel" suite
/// took 59.1–82.4 s. A wait resumed BY its event (`untilAWaitRead`) does not
/// race this guard in the normal case: the poll's read is queued 5 ms after the
/// poll starts, the guard's resumption 120 s after it starts, and the guard
/// starts after the poll does.
private let mainActorHangGuard: Duration = .seconds(120)

/// The router's doors with every answer chosen by the test — for the LINE
/// legs, where the words and the wait polling are the subject, not the store.
@MainActor
private final class ScriptedAuditionDoors: PitchEditorAuditionDoors {
    var answer = ClipNoteAuditionResult(outcome: .sounded, startSeconds: 0, endSeconds: 1,
                                        source: .render, reason: nil)
    var serial: UInt64 = 0
    var state: ClipNoteAuditionWaitState = .waiting
    private(set) var stops = 0
    private(set) var waitReads = 0
    /// What each wait read ANSWERED, in order.
    private(set) var waitReadAnswers: [ClipNoteAuditionWaitState] = []
    /// The test suspended in `untilAWaitRead`, if any, and its hang guard.
    private var readWaiter: (answer: ClipNoteAuditionWaitState, token: Int,
                             continuation: CheckedContinuation<Void, Never>)?
    private var readWaiterGuard: Task<Void, Never>?
    private var readWaiterTokens = 0

    func auditionClipNotes(clipId: UUID, segmentIds: [UUID], contextSeconds: Double,
                           enabled: Bool, seedIfAbsent: PitchEditSet?) throws -> ClipNoteAuditionResult {
        answer
    }

    func previewClipNotePitchDraft(clipId: UUID, offsets: [NotePitchOffset], snapped: Bool,
                                   enabled: Bool, seedIfAbsent: PitchEditSet?,
                                   contextSeconds: Double) throws -> ClipNoteAuditionResult {
        answer
    }

    func auditionClipNotesAfterEdit(_ edit: ClipNoteEdit, clipId: UUID, segmentIds: [UUID],
                                    enabled: Bool, contextSeconds: Double?) throws -> ClipNoteAuditionResult {
        answer
    }

    func stopClipNoteAudition() { stops += 1 }

    var clipNoteAuditionWaitSerial: UInt64 { serial }

    func clipNoteAuditionWaitState(serial: UInt64) -> ClipNoteAuditionWaitState {
        waitReads += 1
        let answered = serial == self.serial ? state : .cancelled
        waitReadAnswers.append(answered)
        if let waiter = readWaiter, waiter.answer == answered { endReadWait(token: waiter.token) }
        return answered
    }

    /// Suspends until a wait read has ANSWERED `answer` (at once if one already
    /// has), resumed BY that read. The resumption is a main-actor job, so it
    /// runs after the rest of the read's turn: whatever the router does with
    /// the answer is done when the test looks. `hangGuard` only ends a wait
    /// for a read that never comes.
    func untilAWaitRead(answered answer: ClipNoteAuditionWaitState, hangGuard: Duration) async {
        guard !waitReadAnswers.contains(answer) else { return }
        readWaiterTokens += 1
        let token = readWaiterTokens
        await withCheckedContinuation { continuation in
            readWaiter = (answer, token, continuation)
            readWaiterGuard = Task { @MainActor [weak self] in
                try? await Task.sleep(for: hangGuard)
                guard !Task.isCancelled else { return }
                self?.endReadWait(token: token)
            }
        }
    }

    /// Resumes the waiting test once: by the read it waited for, or by its
    /// own guard (the token keeps an old guard off a later wait).
    private func endReadWait(token: Int) {
        guard let waiter = readWaiter, waiter.token == token else { return }
        readWaiter = nil
        readWaiterGuard?.cancel()
        readWaiterGuard = nil
        waiter.continuation.resume()
    }
}

// MARK: - m23-ap C5a-4b — the Wobble tool, WIRED (vibrato-handle §4–§6, unpitched §4)
//
// The gesture itself is C5a-4a's, headless, and `PitchWobbleGestureTests`
// covers it. These are what the WIRING can get wrong: which notes show a dot
// and in which tool, what a press on a sound does, the one slop, one commit
// per gesture, the undo fold through the REAL store, and the menu's way back.
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite, never a new `@Suite`:
// `MainActorOccupancySiteTests` bounds the suites (394, 393 used).
@MainActor
extension PitchEditorModelTests {

    /// C-0's fixture (`PitchEditorPlayedLineTests`): A sung with a 5.5 Hz ±40 c
    /// wobble and untouched, B flattened (`vibratoScale: 0`), C a new 6 Hz
    /// ±40 c wobble — on a 1.25× clip, the render's contour ANSWERED, so the
    /// basis gate is open unless `contour` says otherwise.
    private func wobbleModel(contour: PitchRenderContour? = .detected(PitchEditorPlayedLineTests.wholeFile))
    async -> (model: PitchEditorModel, sink: PitchEditorPlayedLineTests.Sink,
              f: PitchEditorPlayedLineTests.Fixture) {
        let f = PitchEditorPlayedLineTests.fixture(shift: 0)
        let (model, sink) = await PitchEditorPlayedLineTests.loadedModel(f, contour: contour)
        return (model, sink, f)
    }

    private func wobbleRect(_ model: PitchEditorModel, _ id: UUID) -> CGRect {
        model.rect(for: model.blobs.first { $0.id == id }!)
    }

    /// The dot's centre on note `id` (the blob's top centre).
    private func dotPoint(_ model: PitchEditorModel, _ id: UUID) -> CGPoint {
        PitchWobbleGesture.dot(in: wobbleRect(model, id))
    }

    /// A point on note `id`'s body OUTSIDE the dot's 12 pt reach: the drag door.
    private func bodyPoint(_ model: PitchEditorModel, _ id: UUID) -> CGPoint {
        let rect = wobbleRect(model, id)
        let point = CGPoint(x: rect.minX + 3, y: rect.midY)
        #expect(PitchWobbleGesture.door(at: point, blobRect: rect) == .drag,
                "the fixture's body point must be the drag door, or the test aims at the dot")
        return point
    }

    /// ONE press, the pane's own calls in the pane's order: `dragChanged`'s
    /// (`trackPress`, then `updateWobbleDrag` while a session exists) for the
    /// first tick and for `end`, then `dragEnded`'s (`releasePress`, then the
    /// release's own model call). ⌥ rides as it does there: fine per tick and
    /// "smaller" at release.
    @discardableResult
    private func wobblePress(_ model: PitchEditorModel, from start: CGPoint, to end: CGPoint,
                             option: Bool = false) -> PitchEditorReleaseAction {
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        if model.wobble != nil { model.updateWobbleDrag(translation: .zero, fine: option) }
        if end != start {
            _ = model.trackPress(start: start, location: end, modifiers: .none)
            if model.wobble != nil {
                model.updateWobbleDrag(translation: CGSize(width: end.x - start.x, height: end.y - start.y),
                                       fine: option)
            }
        }
        let action = model.releasePress(start: start, location: end, modifiers: .none, snapBypassed: option)
        switch action {
        case .endWobble: _ = model.endWobbleDrag()
        case .wobbleStep(let id, let bigger): _ = model.stepWobble(segmentID: id, bigger: bigger)
        default: break
        }
        return action
    }

    /// Planted and seen red, each separately: (a) `wobbleDot` without its
    /// `tool == .wobble` guard (a dot drawn in the Move tool); (b)
    /// `wobbleDotHit` without `wobbleCanGrab` (a sound's dot grabs a press).
    @Test("C5a-4b — THE DOT: none in the Move tool, one on a grabbable note in the Wobble tool (where a press grabs it), none on a SOUND, none while the basis gate refuses")
    func wobbleDotOnlyWhereTheToolCanGrab() async {
        let (model, _, f) = await wobbleModel()
        let a = f.a.id
        let dot = dotPoint(model, a)
        let body = bodyPoint(model, a)
        // The Move tool: no dot anywhere, and the dot's point is not a dot hit.
        #expect(model.tool == .pointer)
        #expect(model.wobbleDot(at: body) == nil, "a dot is drawn in the Move tool")
        #expect(model.wobbleDot(at: dot) == nil, "a dot is drawn in the Move tool")
        #expect(model.pressHit(at: dot) != .dot(a))
        #expect(model.wobbleReadout(dot: nil) == nil)

        // POSITIVE CONTROL — the Wobble tool on the same note draws it, where
        // `pressHit` answers the dot, with a tip in words.
        model.tool = .wobble
        let shown = model.wobbleDot(at: body)
        #expect(shown?.segmentID == a)
        #expect(shown?.centre == dot)
        #expect(shown?.reason == .hover)
        #expect(shown?.tip.text.isEmpty == false)
        #expect(model.pressHit(at: dot) == .dot(a))
        #expect(model.pressHit(at: body) == .note(a))
        #expect(model.wobbleReadout(dot: shown) == shown?.readout)

        // A SOUND: A as a sound, same place. No dot drawn, and its dot's point
        // is the note (whose press is refused, below), never a dot grab.
        var table = model.noteTable
        table.segments[0] = soundCopy(of: table.segments[0])
        model.syncStoredNoteTable(table)
        #expect(model.wobbleDot(at: body) == nil, "a dot is drawn on a sound")
        #expect(model.wobbleDot(at: dot) == nil, "a dot is drawn on a sound")
        #expect(model.pressHit(at: dot) != .dot(a), "a sound's dot grabs a press")
        // …while the sung note beside it keeps its own (the sound removed it,
        // not the tool).
        #expect(model.wobbleDot(at: bodyPoint(model, f.b.id))?.segmentID == f.b.id)

        // THE BASIS GATE: with no usable contour a note with no new wobble has
        // no dot (A here, restored as a note); C — a new wobble at both scales
        // 1, which needs no contour — keeps one.
        let (gated, _, g) = await wobbleModel(contour: .unavailable(reason: "no model in this build"))
        gated.tool = .wobble
        #expect(gated.wobbleDot(at: bodyPoint(gated, g.a.id)) == nil, "a dot is offered while the gate refuses")
        #expect(gated.pressHit(at: dotPoint(gated, g.a.id)) != .dot(g.a.id))
        #expect(gated.wobbleDot(at: bodyPoint(gated, g.c.id))?.segmentID == g.c.id,
                "C needs no contour, so the gate must not take its dot")
    }

    @Test("C5a-4b — a press on a SOUND in the Wobble tool does NOTHING: no session, no draft, no selection, no commit — just §1.7's sentence")
    func wobblePressOnASoundDoesNothing() async {
        let (model, sink, f) = await wobbleModel()
        var table = model.noteTable
        table.segments[0] = soundCopy(of: table.segments[0])
        model.syncStoredNoteTable(table)
        model.tool = .wobble
        let body = bodyPoint(model, f.a.id)
        // A click.
        #expect(wobblePress(model, from: body, to: body) == .nothing)
        #expect(model.refusal == NoteVibratoLimits.noPitchHereSentence)
        #expect(model.wobble == nil)
        #expect(model.selection.isEmpty, "a refused press selected the sound")
        // A drag, well past the slop and the dead zone.
        #expect(wobblePress(model, from: body, to: CGPoint(x: body.x + 40, y: body.y - 30)) == .nothing)
        #expect(model.wobble == nil && model.draftPlayedLine == nil)
        #expect(model.selection.isEmpty)
        #expect(sink.commits.isEmpty, "a press on a sound committed")
        // POSITIVE CONTROL — the same drag on the sung note beside it commits once.
        let b = bodyPoint(model, f.b.id)
        wobblePress(model, from: b, to: CGPoint(x: b.x, y: b.y - 30))
        #expect(sink.commits.count == 1)
    }

    /// ⭐ The ONE slop (vibrato-handle §18.8): a dot press that travels exactly
    /// 4 pt is a DRAG — and a 4 pt drag plays like the stored note, so it
    /// commits nothing (T10) — never a step. Planted and seen red: the
    /// tracker's release reading the dot's travel with its own `> 4`.
    @Test("C5a-4b — 4 pt on the dot is a DRAG (endWobble, no commit); 3.99 pt is ONE step up, ⌥ at release one step down")
    func fourPointsIsADragNotAStep() async {
        let (model, sink, f) = await wobbleModel()
        model.tool = .wobble
        let a = f.a.id
        let dot = dotPoint(model, a)
        #expect(wobblePress(model, from: dot, to: CGPoint(x: dot.x + 4, y: dot.y)) == .endWobble(a))
        #expect(sink.commits.isEmpty, "a 4 pt drag that changed nothing committed")
        #expect(model.wobbleTipNoteID == nil, "a drag left the step's tip showing")
        #expect(model.wobble == nil && model.draftPlayedLine == nil)

        #expect(wobblePress(model, from: dot, to: CGPoint(x: dot.x + 3.99, y: dot.y))
                == .wobbleStep(a, bigger: true))
        #expect(sink.commits.count == 1)
        guard case .noteVibrato(let id, let edit)? = sink.commits.last?.kind else {
            Issue.record("a dot click did not commit a wobble: \(String(describing: sink.commits.last))")
            return
        }
        #expect(id == a)
        // A's own wobble, one keep step (0.10) up. The proportional coupling
        // moves drift only DOWN with keep (`PitchWobbleGesture.driftScale`), so
        // widening leaves it where it was.
        #expect(close(edit.vibratoScale ?? .nan, 1.1, 1e-9))
        #expect(close(edit.driftScale ?? .nan, 1, 1e-9))
        #expect(model.wobbleTipNoteID == a)
        #expect(model.wobbleDot(at: nil)?.reason == .afterClick, "the step's tip is not drawn after the click")

        // ⌥ at release: one step DOWN, from the stored note (the model was not
        // resynced, so the stored keep is still 1).
        #expect(wobblePress(model, from: dot, to: dot, option: true) == .wobbleStep(a, bigger: false))
        guard case .noteVibrato(_, let down)? = sink.commits.last?.kind else {
            Issue.record("an ⌥-click did not commit a wobble")
            return
        }
        #expect(close(down.vibratoScale ?? .nan, 0.9, 1e-9))
        #expect(close(down.driftScale ?? .nan, 0.9, 1e-9), "smoothing leaves the drift where it was")
        // A click on the BODY (not the dot) is the house click: it selects, and
        // commits nothing.
        let body = bodyPoint(model, a)
        #expect(wobblePress(model, from: body, to: body) == .click(.selectOnly(a)))
        #expect(model.selection == [a])
        #expect(sink.commits.count == 2)
        #expect(model.wobble == nil, "a house click left its wobble session speaking")
    }

    /// T-dot-4 through the REAL store and the app's own write
    /// (`PitchEditorWobbleWrite`, the funnel's arm). Planted and seen red:
    /// `PitchEditorWobbleWrite` writing a single note through the batch
    /// setter under `structuralKey` (three clicks, three undo steps).
    @Test("C5a-4b T-dot-4 — three dot clicks on ONE note inside 800 ms are ONE undo step (keep 1 → 1.3), undo restores as sung; another note is its own step; a click after the window is a new one")
    func dotClicksFoldIntoOneUndoStep() async throws {
        let f = PitchEditorPlayedLineTests.fixture(shift: 0)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [f.clip])])
        let (model, _) = await PitchEditorPlayedLineTests.loadedModel(f, contour: .detected(PitchEditorPlayedLineTests.wholeFile))
        var writes: [Bool?] = []
        model.onCommit = { commit in
            writes.append(try? PitchEditorWobbleWrite.commit(commit.kind, clipID: f.clip.id,
                                                             seedIfAbsent: commit.seedIfAbsent, to: store))
            // The pane resyncs from the clip, as `onChange(of: clip.pitchEdits)` does.
            model.syncStoredNoteTable(store.tracks[0].clips[0].pitchEdits)
        }
        model.tool = .wobble
        func stored(_ id: UUID) -> NoteSegment? {
            store.tracks[0].clips[0].pitchEdits?.segments.first { $0.id == id }
        }
        let a = f.a.id
        let before = store.undoHistory().undo.count
        for _ in 0..<3 {
            let dot = dotPoint(model, a)
            wobblePress(model, from: dot, to: dot)
        }
        #expect(writes == [true, true, true], "a click's write did not take")
        #expect(close(stored(a)?.vibratoScale ?? .nan, 1.3, 1e-9), "three steps did not land 1.3")
        #expect(store.undoHistory().undo.count == before + 1,
                "three clicks on one note inside 800 ms are \(store.undoHistory().undo.count - before) undo steps")

        _ = try store.undo()
        #expect(stored(a)?.vibratoScale == 1 && stored(a)?.driftScale == 1, "one undo did not restore as sung")
        #expect(store.undoHistory().undo.count == before)
        model.syncStoredNoteTable(store.tracks[0].clips[0].pitchEdits)

        // POSITIVE CONTROL — the key is the NOTE: a click on A then one on C,
        // inside the window, are two steps.
        let dotA = dotPoint(model, a)
        wobblePress(model, from: dotA, to: dotA)
        let dotC = dotPoint(model, f.c.id)
        wobblePress(model, from: dotC, to: dotC)
        #expect(store.undoHistory().undo.count == before + 2, "clicks on two notes folded into one step")

        // Past the journal's 800 ms window, the same note is a NEW step.
        try await Task.sleep(for: .milliseconds(900))
        let again = dotPoint(model, a)
        wobblePress(model, from: again, to: again)
        #expect(store.undoHistory().undo.count == before + 3, "a click after the window folded into the old step")
        #expect(writes.allSatisfy { $0 == true })
    }

    /// §13 — THE HANDOFF READS THE NOTE WITHOUT ITS DRAWING. A C5b shape is
    /// part of the played line; if the handoff's measurement copy kept it, the
    /// drawing would be read as wobble, copied into the new sine, and then play
    /// twice. Planted and seen red: `wobbleHandoffLine` without
    /// `clearingShapeOf:` (the shaped note seeds a wider wobble than the plain
    /// one).
    @Test("C5a-4b §13 — a handoff on a note with a DRAWN SHAPE seeds exactly what the same note without it seeds (the copy is cleared), keeps the stored drawing, and the readout says the drawing stays on top")
    func handoffSeedExcludesTheDrawnShape() async {
        let f = PitchEditorPlayedLineTests.fixture(shift: 0)
        let contour = PitchRenderContour.detected(PitchEditorPlayedLineTests.wholeFile)
        let (plain, _) = await PitchEditorPlayedLineTests.loadedModel(f, contour: contour)
        let (shaped, _) = await PitchEditorPlayedLineTests.loadedModel(f, contour: contour)
        // A with a drawn 5.5 Hz, ±30 c shape IN PHASE with its sung ±40 c wobble.
        var table = shaped.noteTable
        var a = table.segments[0]
        #expect(a.id == f.a.id)
        let first = NoteShapeSamples.gridIndex(atOrAfter: a.startSeconds)
        let last = NoteShapeSamples.gridIndex(atOrBefore: a.endSeconds)
        a.shapeStartIndex = first
        a.shapeTenthsOfCents = (first...last).map {
            Int16((300 * sin(2 * .pi * 5.5 * Double($0) / NoteSegment.shapeGridHz)).rounded())
        }
        table.segments[0] = a
        shaped.syncStoredNoteTable(table)
        // CONTROL: the drawing is really in the played line, so it COULD leak.
        #expect(shaped.playedLine.curve != plain.playedLine.curve, "the drawn shape is not in the line at all")
        if case .wobble(_, let plainDepth, _, _) = PitchWobbleEstimate.played(f.a, line: plain.playedLine),
           case .wobble(_, let shapedDepth, _, _) = PitchWobbleEstimate.played(a, line: shaped.playedLine) {
            #expect(shapedDepth > plainDepth + 15,
                    "the shaped line reads ±\(shapedDepth) c vs ±\(plainDepth) c: the drawing does not widen it, so this proves nothing")
        } else {
            Issue.record("a line reads no wobble, so the control cannot run")
        }
        // The same sideways drag on both, past the 16 pt crossing.
        for model in [plain, shaped] {
            model.tool = .wobble
            let body = bodyPoint(model, f.a.id)
            _ = model.trackPress(start: body, location: body, modifiers: .none)
            for dx in [10.0, 30.0] {
                _ = model.trackPress(start: body, location: CGPoint(x: body.x + dx, y: body.y), modifiers: .none)
                model.updateWobbleDrag(translation: CGSize(width: dx, height: 0), fine: false)
            }
        }
        #expect(plain.wobble?.session.phase == .handedOff && shaped.wobble?.session.phase == .handedOff,
                "a drag did not hand off, so the seed was never read")
        #expect(plain.wobble?.edit != nil && shaped.wobble?.edit == plain.wobble?.edit,
                "the drawing leaked into the new wobble: \(String(describing: shaped.wobble?.edit)) vs \(String(describing: plain.wobble?.edit))")
        #expect(shaped.wobble?.session.draft.shapeTenthsOfCents == a.shapeTenthsOfCents,
                "the draft lost the note's drawing — only the MEASUREMENT's copy may")
        // The words: the drawing stays on top, said on the shaped note only.
        let suffix = PitchWobbleCopy.drawnChangesStayOnTop
        #expect(shaped.wobble?.readout.text.hasSuffix(suffix) == true, "\(String(describing: shaped.wobble?.readout.text))")
        #expect(plain.wobble?.readout.text.hasSuffix(suffix) == false)
    }

    /// Natural tuning D4-1 — the user's Q-U1 = (b), 2026-09-26: the first hand
    /// edit on a vocal that `predatesNaturalTuning` upgrades the WHOLE set
    /// (`PitchEditSet.afterHandEdit()`). A set-level change like that is
    /// exactly what a per-note draft write cannot reproduce, so the draft runs
    /// the commit's OWN set transform (`PitchEditorDraftEdit.draftSet`), and
    /// this pins the result: the draft set at the last tick IS the set the
    /// release stores, whole-struct equality, for a wobble drag and for a
    /// pitch drag, on a legacy vocal.
    ///
    /// Planted and seen red, with (b) in force: `draftSet` keeping the note
    /// fields its transform wrote but NOT the set-level upgrade
    /// (`set.withSegments(next.set.segments)`, a draft "built any other way")
    /// — the draft draws the old rule while the release stores the new one,
    /// which is the D4-1 hazard. (An earlier plant, the draft upgrading while
    /// the commit did not, went green once D4-1 made the wobble transform
    /// upgrade too: the two then agree, which is the point.)
    @Test("C5a-4b × D4-1 — on a LEGACY vocal, a wobble drag's draft set IS the set its release stores (whole struct), and so is a pitch drag's, and (C5b-4b) a brush stroke's")
    func legacyDraftSetIsTheStoredSet() async throws {
        let f = PitchEditorPlayedLineTests.fixture(shift: 0)
        let contour = PitchRenderContour.detected(PitchEditorPlayedLineTests.wholeFile)
        #expect(f.set.predatesNaturalTuning, "the fixture must be a LEGACY vocal, or this proves nothing about D4-1")

        // A wobble drag on B: 30 pt up, the keep lever.
        do {
            let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [f.clip])])
            let (model, _) = await PitchEditorPlayedLineTests.loadedModel(f, contour: contour)
            model.onCommit = { commit in
                _ = try? PitchEditorWobbleWrite.commit(commit.kind, clipID: f.clip.id,
                                                       seedIfAbsent: commit.seedIfAbsent, to: store)
            }
            model.tool = .wobble
            let start = bodyPoint(model, f.b.id)
            let end = CGPoint(x: start.x, y: start.y - 30)
            _ = model.trackPress(start: start, location: start, modifiers: .none)
            _ = model.trackPress(start: start, location: end, modifiers: .none)
            model.updateWobbleDrag(translation: CGSize(width: 0, height: -30), fine: false)
            let draft = try #require(model.draftEditSet, "the wobble drag built no draft set")
            #expect(model.releasePress(start: start, location: end, modifiers: .none) == .endWobble(f.b.id))
            _ = model.endWobbleDrag()
            let stored = try #require(store.tracks[0].clips[0].pitchEdits)
            #expect(stored != f.set, "the wobble drag stored nothing, so the equality below proves nothing")
            #expect(draft == stored, "the wobble draft set is not the set its release stored")
            // With (b) in force the release upgrades the whole vocal — the
            // set-level change the equality above must have carried.
            if PitchEditSet.handEditUpgradesLegacyVocal {
                #expect(!stored.predatesNaturalTuning, "(b) is on, and the wobble release did not upgrade the vocal")
            }
        }

        // A pitch drag on A: 40 pt up, the Move tool, the pane's calls in order.
        do {
            let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [f.clip])])
            let (model, _) = await PitchEditorPlayedLineTests.loadedModel(f, contour: contour)
            model.onCommit = { commit in
                if case .notePitch(let id, let cents) = commit.kind {
                    _ = try? store.setClipNotePitchOffset(clipId: f.clip.id, segmentId: id,
                                                          offsetCents: cents, seedIfAbsent: commit.seedIfAbsent)
                }
            }
            let start = bodyPoint(model, f.a.id)
            let end = CGPoint(x: start.x, y: start.y - 40)
            _ = model.trackPress(start: start, location: start, modifiers: .none)
            let tick = model.trackPress(start: start, location: end, modifiers: .none)
            if tick.didPromote, let blob = model.blobs.first(where: { $0.id == f.a.id }) {
                _ = model.beginSelectionPitchDrag(on: blob)
            }
            model.updatePitchDrag(translationHeight: -40, free: false)
            let draft = try #require(model.draftEditSet, "the pitch drag built no draft set")
            #expect(model.releasePress(start: start, location: end, modifiers: .none) == .endNoteDrag(f.a.id))
            _ = model.endPitchDrag()
            let stored = try #require(store.tracks[0].clips[0].pitchEdits)
            #expect(stored != f.set, "the pitch drag stored nothing, so the equality below proves nothing")
            #expect(draft == stored, "the pitch draft set is not the set its release stored")
            if PitchEditSet.handEditUpgradesLegacyVocal {
                #expect(!stored.predatesNaturalTuning, "(b) is on, and the pitch release did not upgrade the vocal")
            }
        }

        // C5b-4b × D4-1 #1 — a brush STROKE across A and B, the pane's calls
        // in order, through the app's own write (`PitchEditorShapeWrite`). The
        // draft's `.shape` case runs `applyingNoteShapes`, the transform the
        // store's `setClipNoteShapes` runs, `afterHandEdit(from:)` included (it
        // updates the vocal only when the write changed a note). Planted and
        // seen red (W7-C5b4b p1): that case writing each note with
        // `NoteShapeSamples.applied(to:)` alone (no set transform, so no
        // whole-vocal upgrade in the draft).
        do {
            let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [f.clip])])
            let (model, _) = await PitchEditorPlayedLineTests.loadedModel(f, contour: contour)
            model.onCommit = { commit in
                _ = try? PitchEditorShapeWrite.commit(commit.kind, clipID: f.clip.id,
                                                      seedIfAbsent: commit.seedIfAbsent, to: store)
            }
            let (start, path) = acrossAB(model, f)
            _ = model.trackPress(start: start, location: start, modifiers: .command)
            for point in path { _ = model.trackPress(start: start, location: point, modifiers: .command) }
            let draft = try #require(model.draftEditSet, "the stroke built no draft set")
            #expect(model.releasePress(start: start, location: path.last!, modifiers: .command)
                    == .endBrush(f.a.id))
            _ = model.endBrush()
            let stored = try #require(store.tracks[0].clips[0].pitchEdits)
            #expect(stored != f.set, "the stroke stored nothing, so the equality below proves nothing")
            #expect(draft == stored, "the stroke's draft set is not the set its release stored")
            if PitchEditSet.handEditUpgradesLegacyVocal {
                #expect(!stored.predatesNaturalTuning, "(b) is on, and the stroke's release did not upgrade the vocal")
            }
        }
    }

    @Test("C5a-4b — \"Back to how you sang it\": offered only on a note whose wobble changed, it puts that note back as sung in ONE commit, and then is not offered")
    func backToHowYouSangIt() async throws {
        let f = PitchEditorPlayedLineTests.fixture(shift: 0)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [f.clip])])
        let (model, sink) = await PitchEditorPlayedLineTests.loadedModel(f, contour: .detected(PitchEditorPlayedLineTests.wholeFile))
        model.onCommit = { commit in
            sink.commits.append(commit)
            _ = try? PitchEditorWobbleWrite.commit(commit.kind, clipID: f.clip.id,
                                                   seedIfAbsent: commit.seedIfAbsent, to: store)
            model.syncStoredNoteTable(store.tracks[0].clips[0].pitchEdits)
        }
        let a = f.a.id
        let body = bodyPoint(model, a)
        let title = PitchEditorNoteMenu.resetWobbleTitle
        #expect(title == "Back to how you sang it")
        // A is as sung: no row.
        #expect(!model.noteMenu(at: body).contains { $0.action == .resetWobble })
        // B IS changed (flattened) in the fixture: the row is offered there.
        #expect(model.noteMenu(at: bodyPoint(model, f.b.id)).contains { $0.title == title })
        // Change A's wobble with one dot click, then ask the menu on A.
        model.tool = .wobble
        let dot = dotPoint(model, a)
        wobblePress(model, from: dot, to: dot)
        #expect(model.noteMenu(at: body).contains { $0.action == .resetWobble && $0.isEnabled })
        model.selectForContextMenu(at: body)
        let commits = sink.commits.count
        let reset = model.performNoteAction(.resetWobble)
        #expect(reset?.kind == .noteVibratoReset(segmentIDs: [a]))
        #expect(sink.commits.count == commits + 1)
        let stored = store.tracks[0].clips[0].pitchEdits?.segments.first { $0.id == a }
        #expect(stored.map(NoteVibratoEdit.init(storedIn:)) == .asSung)
        #expect(!model.noteMenu(at: body).contains { $0.action == .resetWobble },
                "the row is offered on a note that is already as sung")
    }
}

// MARK: - m23-ap C5b-4b — the freehand brush, wired (timing-and-freehand §5.5–§5.6)
//
// The stroke's MATH is C5b-4a's, headless, and `PitchShapeBrushTests` covers
// it (max weight, the swept path, the pre-stroke line, the gaps). These are
// what the WIRING can get wrong: which press is a stroke (⌘, a note, past the
// slop), one commit per stroke through the REAL store (one undo step), the
// draft being the stored set on a legacy vocal, the two refusals said in
// words, Escape, the band, the help and the cursor promising exactly what the
// press does, the menu's way back, and the draft window asking DAWCore.
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite, never a new `@Suite`:
// `MainActorOccupancySiteTests` bounds the suites (394, 393 used).
@MainActor
extension PitchEditorModelTests {

    /// C-0's fixture (`PitchEditorPlayedLineTests`: A 0–0.8 s at A3, B
    /// 0.896–1.856 s at B3, C 2.016–2.976 s at G3, holes between; a LEGACY set)
    /// with the render's contour answered unless `contour` says otherwise,
    /// wired to a REAL store through the app's own write
    /// (`PitchEditorShapeWrite`, the funnel's arm) and resynced from the clip
    /// the way the pane's `onChange(of: clip.pitchEdits)` does. `writes` holds
    /// each write's read-back verdict.
    @MainActor private final class BrushRig {
        let f: PitchEditorPlayedLineTests.Fixture
        let store: ProjectStore
        let model: PitchEditorModel
        var commits: [PitchEditorCommit] = []
        var writes: [Bool?] = []
        var refusals: [String] = []

        init(f: PitchEditorPlayedLineTests.Fixture, store: ProjectStore, model: PitchEditorModel) {
            self.f = f
            self.store = store
            self.model = model
        }

        var stored: PitchEditSet? { store.tracks[0].clips[0].pitchEdits }
        func storedNote(_ id: UUID) -> NoteSegment? { stored?.segments.first { $0.id == id } }
    }

    /// `table` edits the fixture's own table (its ids are minted per call, so
    /// a table built from ANOTHER fixture call would name notes this one does
    /// not draw); A, B and C are re-read from the edited table.
    private func brushRig(table: ((PitchEditSet) -> PitchEditSet)? = nil,
                          contour: PitchRenderContour? = .detected(PitchEditorPlayedLineTests.wholeFile))
    async -> BrushRig {
        var f = PitchEditorPlayedLineTests.fixture(shift: 0)
        if let table {
            var clip = f.clip
            let edited = table(f.set)
            clip.pitchEdits = edited
            f = PitchEditorPlayedLineTests.Fixture(a: edited.segments[0], b: edited.segments[1],
                                                   c: edited.segments[2], clip: clip)
        }
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [f.clip])])
        let (model, _) = await PitchEditorPlayedLineTests.loadedModel(f, contour: contour)
        let rig = BrushRig(f: f, store: store, model: model)
        model.onCommit = { [unowned rig] commit in
            rig.commits.append(commit)
            do {
                rig.writes.append(try PitchEditorShapeWrite.commit(commit.kind, clipID: f.clip.id,
                                                                   seedIfAbsent: commit.seedIfAbsent,
                                                                   to: store))
            } catch {
                rig.refusals.append("\(error)")
            }
            model.syncStoredNoteTable(store.tracks[0].clips[0].pitchEdits)
        }
        return rig
    }

    /// Where note `id`'s line is drawn at SOURCE second `seconds`, pulled
    /// `cents` up: content space, through the geometry's one mapping.
    private func linePoint(_ model: PitchEditorModel, _ id: UUID, at seconds: Double,
                           cents: Double = 0) -> CGPoint {
        let blob = model.blobs.first { $0.id == id }!
        return CGPoint(x: model.geometry.x(forSourceSecond: seconds),
                       y: model.geometry.y(forMidi: model.geometry.drawnMidi(for: blob) + cents / 100))
    }

    /// ONE press, the pane's own calls in the pane's order: `dragChanged`'s
    /// `trackPress` for the first tick and each point of `path`, then
    /// `dragEnded`'s `releasePress` and the release's own model call (the
    /// brush's `endBrush`; `cancelDrag` for a click, a band or nothing).
    @discardableResult
    private func brushPress(_ model: PitchEditorModel, from start: CGPoint, through path: [CGPoint],
                            chord: ArrangeClickModifiers = .command) -> PitchEditorReleaseAction {
        _ = model.trackPress(start: start, location: start, modifiers: chord)
        for point in path { _ = model.trackPress(start: start, location: point, modifiers: chord) }
        let action = model.releasePress(start: start, location: path.last ?? start, modifiers: chord)
        switch action {
        case .endBrush: _ = model.endBrush()
        case .click, .endBand, .nothing: model.cancelDrag()
        default: break
        }
        return action
    }

    /// A stroke from A's middle, pulled 60 c up, across the hole into B's
    /// middle: it writes into BOTH notes.
    private func acrossAB(_ model: PitchEditorModel, _ f: PitchEditorPlayedLineTests.Fixture)
    -> (start: CGPoint, path: [CGPoint]) {
        let start = linePoint(model, f.a.id, at: 0.4)
        let aHigh = linePoint(model, f.a.id, at: 0.6, cents: 60)
        let bMid = linePoint(model, f.b.id, at: 1.3, cents: -60)
        return (start, [CGPoint(x: start.x + 1, y: start.y - 1), aHigh, bMid])
    }

    /// ⭐ THE CADENCE AND THE ONE UNDO STEP, through the real store. Planted
    /// and seen red, each (W7-C5b4b p2, p6): `PitchEditorShapeWrite` writing
    /// each note of a stroke in its OWN store call (two undo steps for one
    /// stroke; the model's commit count stays 1, so only the journal can see
    /// it); and `advanceBrush` emitting a commit on every tick that changed
    /// the draft (the design's own C5b-4 plant, "a commit per tick").
    @Test("C5b-4b — ⭐ a ⌘-drag across two notes commits NOTHING per tick, then ONE .noteShapes at release: ONE \"Draw Pitch\" undo step through the real store; the draft IS the stored set; one undo restores the table")
    func aStrokeIsOneCommitAndOneUndoStep() async throws {
        let rig = await brushRig()
        let model = rig.model, f = rig.f
        #expect(f.set.predatesNaturalTuning, "the fixture must be a LEGACY vocal (D4-1's first-edit upgrade)")
        let (start, path) = acrossAB(model, f)
        let before = rig.store.undoHistory().undo.count

        // First tick: routed, nothing begun (inside the slop a press is a click).
        #expect(model.trackPress(start: start, location: start, modifiers: .command).kind == .brush(f.a.id))
        #expect(model.brush == nil && model.draftPlayedLine == nil)
        // A tick still inside the slop: still nothing.
        _ = model.trackPress(start: start, location: path[0], modifiers: .command)
        #expect(model.brush == nil, "a stroke began inside the slop")
        // Past it: the stroke is live, the line drafts, and NOTHING is written.
        for point in path.dropFirst() {
            _ = model.trackPress(start: start, location: point, modifiers: .command)
            #expect(rig.commits.isEmpty, "a stroke tick committed")
        }
        let brush = try #require(model.brush, "the promoted ⌘ press did not start a stroke")
        #expect(brush.pressedNoteID == f.a.id)
        #expect(Set(brush.shapes.keys) == [f.a.id, f.b.id], "the stroke did not write into both notes")
        #expect(brush.readout.hasPrefix("Drawing · moves the line by up to "))
        #expect(model.draftPlayedLine != nil, "the stroke drew no draft line")
        let draft = try #require(model.draftEditSet, "the stroke built no draft set")
        #expect(model.escapeGestureLive)
        #expect(model.selection.isEmpty, "a stroke selected notes")

        // The release: ONE commit, of exactly what the last tick drew.
        let action = model.releasePress(start: start, location: path.last!, modifiers: .command)
        #expect(action == .endBrush(f.a.id))
        let commit = model.endBrush()
        #expect(commit?.kind == .noteShapes(shapes: brush.shapes))
        #expect(rig.commits.count == 1)
        #expect(rig.writes == [true], "the write did not take (\(rig.refusals))")
        #expect(model.brush == nil && model.draftPlayedLine == nil && model.draftEditSet == nil)

        // ONE undo step, the store's own label.
        #expect(rig.store.undoHistory().undo.count == before + 1,
                "one stroke is \(rig.store.undoHistory().undo.count - before) undo steps")
        #expect(rig.store.undoHistory().undo.first == "Draw Pitch")
        // ⭐ The draft set IS the stored set — whole struct, the legacy
        // upgrade included (D4-1 (b): the first hand edit updates the vocal).
        let stored = try #require(rig.stored)
        #expect(stored != f.set, "the stroke stored nothing, so the equality below proves nothing")
        #expect(draft == stored, "the stroke's draft set is not the set its release stored")
        for (id, samples) in brush.shapes {
            #expect(rig.storedNote(id).map(NoteShapeSamples.init(storedIn:)) == samples,
                    "note \(id) stores a different drawing from the one the stroke drew")
        }
        if PitchEditSet.handEditUpgradesLegacyVocal {
            #expect(!stored.predatesNaturalTuning, "(b) is on, and the stroke's release did not upgrade the vocal")
        }
        // One undo puts the whole table back.
        _ = try rig.store.undo()
        #expect(rig.stored == f.set, "one undo did not restore the table the stroke started from")
    }

    @Test("C5b-4b — a ⌘-click that stays inside the slop is the house click: it toggles the note and draws nothing")
    func aCommandClickStillToggles() async {
        let rig = await brushRig()
        let model = rig.model, f = rig.f
        let start = linePoint(model, f.a.id, at: 0.4)
        let action = brushPress(model, from: start, through: [CGPoint(x: start.x + 3, y: start.y)])
        #expect(action == .click(.toggle(f.a.id)))
        #expect(model.selection == [f.a.id])
        #expect(model.brush == nil && model.draftPlayedLine == nil)
        #expect(rig.commits.isEmpty && model.refusal == nil)
        // POSITIVE CONTROL — the same press WITHOUT ⌘, travelled, is a pitch
        // drag's route (the chord, not the travel, is what made it a stroke).
        #expect(model.trackPress(start: start, location: start, modifiers: .none).kind == .noteDrag(f.a.id))
        model.cancelDrag()
    }

    @Test("C5b-4b — Escape mid-stroke drops it: nothing committed, the draft gone, and the rest of the gesture does nothing")
    func escapeCancelsAStroke() async {
        let rig = await brushRig()
        let model = rig.model, f = rig.f
        let (start, path) = acrossAB(model, f)
        _ = model.trackPress(start: start, location: start, modifiers: .command)
        for point in path { _ = model.trackPress(start: start, location: point, modifiers: .command) }
        #expect(model.brush != nil && model.escapeGestureLive)
        #expect(model.handleEscapeKey(appDecision: { live, _ in live ? .cancelGesture : .pass }))
        #expect(model.brush == nil && model.draftPlayedLine == nil && model.draftEditSet == nil)
        #expect(!model.escapeGestureLive)
        // The pointer is still down: its next tick and its release are inert.
        _ = model.trackPress(start: start, location: CGPoint(x: path.last!.x + 20, y: path.last!.y),
                             modifiers: .command)
        #expect(model.brush == nil, "a cancelled stroke restarted on the next tick")
        #expect(model.releasePress(start: start, location: path.last!, modifiers: .command) == .nothing)
        #expect(rig.commits.isEmpty && rig.store.undoHistory().undo.isEmpty)
    }

    /// Planted and seen red: `beginBrush` ignoring a refusal (no sentence, the
    /// press not abandoned) — the release becomes `.endBrush` and the line
    /// below reads nil.
    @Test("C5b-4b — a stroke that starts on a SOUND is refused in words and abandoned: no draft, no selection, no commit; the band says so first")
    func aStrokeOnASoundIsRefused() async {
        let rig = await brushRig(table: { set in
            var table = set
            table.segments[0] = self.soundCopy(of: table.segments[0])
            return table
        })
        let model = rig.model, f = rig.f
        let (start, path) = acrossAB(model, f)
        // Before the press: the band is dim and says why; the cursor is plain.
        let band = model.brushBand(at: start, commandHeld: true)
        #expect(band?.refusal == PitchShapeBrush.soundCaption)
        #expect(model.paletteHelp(commandHeld: true, band: band) == PitchShapeBrush.soundCaption)
        #expect(model.surfaceCursor(at: start, modifiers: [.command]) == nil)
        // The press.
        #expect(brushPress(model, from: start, through: path) == .nothing)
        #expect(model.refusal == PitchShapeBrush.soundCaption)
        #expect(model.brush == nil && model.draftPlayedLine == nil)
        #expect(model.selection.isEmpty, "a refused stroke selected the sound")
        #expect(rig.commits.isEmpty)
        // POSITIVE CONTROL — the same stroke from B (a sung note) draws.
        let fromB = linePoint(model, f.b.id, at: 1.3)
        #expect(brushPress(model, from: fromB,
                           through: [linePoint(model, f.b.id, at: 1.5, cents: 50)]) == .endBrush(f.b.id))
        #expect(rig.writes == [true], "the stroke from a sung note did not draw (\(rig.refusals))")
        #expect(model.refusal == nil, "a stroke that drew kept the old refusal on screen")
    }

    @Test("C5b-4b — while the line is an ESTIMATE the brush is refused with the design's caption; with the render's line it draws")
    func theBrushWaitsForTheRendersLine() async {
        let rig = await brushRig(contour: nil)
        let model = rig.model, f = rig.f
        #expect(model.playedLine.basis != .render, "the fixture must draw an ESTIMATE without the contour")
        let (start, path) = acrossAB(model, f)
        let band = model.brushBand(at: start, commandHeld: true)
        #expect(band?.refusal == PitchShapeBrush.estimateCaption)
        #expect(model.paletteHelp(commandHeld: true, band: band) == PitchShapeBrush.estimateCaption)
        #expect(brushPress(model, from: start, through: path) == .nothing)
        #expect(model.refusal == PitchShapeBrush.estimateCaption)
        #expect(rig.commits.isEmpty)
        // POSITIVE CONTROL — the render's line answers, and the same stroke draws.
        await model.loadRenderContour(using: PitchEditorPlayedLineTests.seam(.detected(PitchEditorPlayedLineTests.wholeFile)))
        #expect(model.playedLine.basis == .render)
        #expect(brushPress(model, from: start, through: path) == .endBrush(f.a.id))
        #expect(rig.writes == [true])
    }

    @Test("C5b-4b — the band, the help and the cursor promise exactly what a ⌘-press does: over a note in Move or Wobble, never over empty surface, never with the knife, never without ⌘")
    func theBandHelpAndCursorMatchThePress() async {
        let rig = await brushRig()
        let model = rig.model, f = rig.f
        let onA = linePoint(model, f.a.id, at: 0.4)
        let empty = CGPoint(x: onA.x, y: model.geometry.y(forMidi: model.geometry.drawnMidi(
            for: model.blobs.first { $0.id == f.a.id }!) + 6))
        #expect(model.pressHit(at: empty) == .empty, "the empty point must be empty")
        // Move tool, ⌘ over A: the band — 2R wide, centred, full height, live.
        let band = model.brushBand(at: onA, commandHeld: true)
        #expect(band?.rect == CGRect(x: onA.x - 12, y: 0, width: 24, height: model.geometry.contentHeight))
        #expect(band?.refusal == nil && band?.isStroking == false)
        #expect(model.paletteHelp(commandHeld: true, band: band) == PitchShapeBrush.help)
        #expect(model.surfaceCursor(at: onA, modifiers: [.command]) == .crosshair)
        // Without ⌘: nothing, and the tool's own help.
        #expect(model.brushBand(at: onA, commandHeld: false) == nil)
        #expect(model.paletteHelp(commandHeld: false, band: nil) == PitchEditorTool.pointer.help)
        #expect(model.surfaceCursor(at: onA, modifiers: []) == nil)
        // Over empty surface ⌘ places the playhead: no band.
        #expect(model.brushBand(at: empty, commandHeld: true) == nil)
        #expect(model.surfaceCursor(at: empty, modifiers: [.command]) == .verticalBar)
        // The knife never draws: no band, the knife's help, the knife's cursor.
        model.tool = .scissors
        #expect(model.brushBand(at: onA, commandHeld: true) == nil)
        #expect(model.paletteHelp(commandHeld: true, band: nil) == PitchEditorTool.scissors.help)
        #expect(model.surfaceCursor(at: onA, modifiers: [.command]) == .crosshair,
                "the knife keeps its own crosshair")
        // The Wobble tool: ⌘ draws there too, and its help says so.
        model.tool = .wobble
        #expect(model.brushBand(at: onA, commandHeld: true)?.refusal == nil)
        #expect(PitchEditorTool.wobble.help.contains("Hold ⌘ to draw instead."))
        #expect(PitchEditorTool.pointer.help.contains("Hold ⌘ to draw its line"))
        // While a stroke is live the band follows IT, with ⌘ up or down.
        model.tool = .pointer
        let (start, path) = acrossAB(model, f)
        _ = model.trackPress(start: start, location: start, modifiers: .command)
        for point in path { _ = model.trackPress(start: start, location: point, modifiers: .command) }
        let following = model.brushBand(at: nil, commandHeld: false)
        #expect(following?.isStroking == true && following?.point == path.last)
        #expect(model.paletteHelp(commandHeld: false, band: following) == PitchShapeBrush.help)
        model.cancelDrag()
    }

    @Test("C5b-4b — in the Wobble tool a ⌘-press on the note or its dot is the brush: no wobble session, no dot while drawing, one shape commit")
    func theWobbleToolDrawsWithCommand() async {
        let rig = await brushRig()
        let model = rig.model, f = rig.f
        model.tool = .wobble
        let dot = dotPoint(model, f.a.id)
        _ = model.trackPress(start: dot, location: dot, modifiers: .command)
        #expect(model.wobble == nil, "a ⌘-press began a wobble session")
        let end = CGPoint(x: dot.x + 8, y: dot.y - 12)
        _ = model.trackPress(start: dot, location: end, modifiers: .command)
        #expect(model.brush != nil)
        #expect(model.wobbleDot(at: dot) == nil, "the dot is drawn during a stroke")
        #expect(model.releasePress(start: dot, location: end, modifiers: .command) == .endBrush(f.a.id))
        _ = model.endBrush()
        #expect(rig.commits.count == 1)
        guard case .noteShapes? = rig.commits.first?.kind else {
            Issue.record("the Wobble tool's ⌘-drag committed \(String(describing: rig.commits.first?.kind))")
            return
        }
        #expect(rig.writes == [true])
    }

    @Test("C5b-4b — \"Reset drawn shape\": offered only on a note that carries a drawing; ONE commit of clears, ONE \"Reset Drawn Shape\" undo step; then not offered")
    func resetDrawnShape() async throws {
        let rig = await brushRig()
        let model = rig.model, f = rig.f
        let onA = linePoint(model, f.a.id, at: 0.4)
        #expect(!model.noteMenu(at: onA).contains { $0.action == .resetShape }, "offered on an undrawn note")
        let (start, path) = acrossAB(model, f)
        brushPress(model, from: start, through: path)
        #expect(rig.writes == [true])
        #expect(rig.storedNote(f.a.id)?.hasShape == true && rig.storedNote(f.b.id)?.hasShape == true)
        let item = model.noteMenu(at: onA).first { $0.action == .resetShape }
        #expect(item?.title == "Reset drawn shape" && item?.isEnabled == true)
        model.selectForContextMenu(at: onA)
        let before = rig.store.undoHistory().undo.count
        let reset = model.performNoteAction(.resetShape)
        #expect(reset?.kind == .noteShapes(shapes: [f.a.id: .clear]), "the reset named more (or less) than A")
        #expect(rig.writes == [true, true])
        #expect(rig.store.undoHistory().undo.count == before + 1)
        #expect(rig.store.undoHistory().undo.first == "Reset Drawn Shape")
        #expect(rig.storedNote(f.a.id)?.hasShape == false, "A still carries its drawing")
        #expect(rig.storedNote(f.b.id)?.hasShape == true, "the reset reached B, which was not selected")
        #expect(!model.noteMenu(at: onA).contains { $0.action == .resetShape })
    }

    /// ⭐ D4-1 #2 (orchestrator's scope addition to C5b-4b): the draft window
    /// ASKS DAWCore (`PitchEditSet.pitchDragReach`) instead of restating the
    /// reach, and its memo cannot outlive the table it was read from. ONE
    /// model throughout, so the memo is really exercised: a first move on the
    /// legacy vocal (whole vocal), a stroke (both notes asked, merged), its
    /// commit through the real store (the vocal upgraded, the table and the
    /// line rebuilt), then a second drag (the note's own reach).
    ///
    /// Planted and seen red, each: (1) `draftSpan` back to the note widened by
    /// half the retune (the first leg's window stops short of C); (2) the memo
    /// never emptied (`draftReachCache` not keyed on `playedLineRevision`): the
    /// second drag reads the FIRST drag's whole-vocal reach from a table that
    /// no longer exists.
    @Test("D4-1 #2 — the draft window is DAWCore's reach: a FIRST move on a legacy vocal owns the WHOLE vocal; after the upgrade lands, a second drag owns only its note's reach (the memo does not outlive its table)")
    func theDraftWindowAsksDAWCore() async throws {
        let rig = await brushRig()
        let model = rig.model, f = rig.f
        #expect(f.set.predatesNaturalTuning)
        let whole = try #require(f.set.pitchDragReach(ofSegmentAt: 0))
        #expect(whole.lowerBound <= f.a.startSeconds && whole.upperBound >= f.c.endSeconds,
                "DAWCore's first-edit reach on a legacy vocal is not the whole vocal (\(whole))")

        // 1. A first MOVE (a pitch drag) on the legacy vocal: the whole vocal.
        let blob = try #require(model.blobs.first { $0.id == f.a.id })
        #expect(model.beginPitchDrag(on: blob))
        model.updatePitchDrag(translationHeight: -30, free: false)
        #expect(model.draftSpan == whole, "a first move's window is not DAWCore's whole-vocal reach")
        #expect(model.draftSpans == [whole])
        model.cancelDrag()

        // 2. A stroke across A and B asks the same rule for BOTH notes, merged.
        let (start, path) = acrossAB(model, f)
        _ = model.trackPress(start: start, location: start, modifiers: .command)
        for point in path { _ = model.trackPress(start: start, location: point, modifiers: .command) }
        #expect(model.draftSpans == [whole], "a stroke's windows are not DAWCore's reach, merged")
        #expect(model.releasePress(start: start, location: path.last!, modifiers: .command) == .endBrush(f.a.id))
        _ = model.endBrush()
        #expect(rig.writes == [true])
        let upgraded = try #require(rig.stored)
        #expect(!upgraded.predatesNaturalTuning, "the stroke's release did not upgrade the vocal")

        // 3. A SECOND drag on the SAME model, after the upgrade was read back:
        // the note's own reach, from the table as it is NOW.
        let own = try #require(upgraded.pitchDragReach(ofSegmentAt: 0))
        #expect(own != whole && own.upperBound < f.c.startSeconds,
                "the fixture must make the note's own reach narrower than the vocal (\(own))")
        let again = try #require(model.blobs.first { $0.id == f.a.id })
        #expect(model.beginPitchDrag(on: again))
        model.updatePitchDrag(translationHeight: -30, free: false)
        #expect(model.draftSpan == own,
                "the second drag's window is \(String(describing: model.draftSpan)), not the note's own reach \(own) — a memo outlived its table")
        model.cancelDrag()
    }
}

// MARK: - W7-NTU U1 — the header group "Sound like the singer" (natural tuning X9)
//
// The gestures (ONE commit per gesture, never per tick; on a vocal tuned before
// the update every press is THE update, never a voice-size write) and each
// write through a REAL store via the app funnel's own arm
// (`PitchEditorSingerWrite`), read back from the store, counted in the undo
// journal, and undone. The faces, words and metrics are pinned headless in
// `PitchEditorSingerGroupTests` (nonisolated).
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite, never a new `@Suite`:
// `MainActorOccupancySiteTests` bounds the suites (394, 393 used).
@MainActor
extension PitchEditorModelTests {

    /// C-0's three-note fixture on a clip that is NOT stretched or transposed
    /// (so the consonant row is not paused), with `table(f.set)` stored — nil
    /// for none, so the editor's seed is the table — wired to a real store
    /// through `PitchEditorSingerWrite` and resynced from the clip, as the
    /// pane's `onChange(of: clip.pitchEdits)` does.
    @MainActor private final class SingerRig {
        let clip: Clip
        let store: ProjectStore
        let model: PitchEditorModel
        var commits: [PitchEditorCommit] = []
        var writes: [Bool?] = []
        var refusals: [String] = []

        init(clip: Clip, store: ProjectStore, model: PitchEditorModel) {
            self.clip = clip
            self.store = store
            self.model = model
        }

        var stored: PitchEditSet? { store.tracks[0].clips[0].pitchEdits }
        var undoDepth: Int { store.undoHistory().undo.count }
        var undoTop: String? { store.undoHistory().undo.first }
        var group: PitchEditorSingerGroup {
            model.singerGroup(stretchRatio: clip.stretchRatio, clipSemitones: clip.pitchShiftSemitones)
        }
    }

    private func singerRig(_ table: ((PitchEditSet) -> PitchEditSet?)?) async -> SingerRig {
        let f = PitchEditorPlayedLineTests.fixture(shift: 0)
        var clip = f.clip
        clip.stretchRatio = 1
        if let table { clip.pitchEdits = table(f.set) }
        let fixture = PitchEditorPlayedLineTests.Fixture(a: f.a, b: f.b, c: f.c, clip: clip)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let (model, _) = await PitchEditorPlayedLineTests.loadedModel(fixture, contour: nil)
        let rig = SingerRig(clip: clip, store: store, model: model)
        model.onCommit = { [unowned rig] commit in
            rig.commits.append(commit)
            do {
                rig.writes.append(try PitchEditorSingerWrite.commit(commit.kind, clipID: clip.id,
                                                                    seedIfAbsent: commit.seedIfAbsent,
                                                                    to: store))
            } catch {
                rig.refusals.append("\(error)")
            }
            model.syncStoredNoteTable(store.tracks[0].clips[0].pitchEdits)
        }
        return rig
    }

    /// The fixture's own set, updated (the notes a new vocal would have).
    private static func updatedTable(_ set: PitchEditSet) -> PitchEditSet? { set.upgradedToNaturalTuning() }
    /// The fixture's own set as stored: a vocal tuned BEFORE the update.
    private static func legacyTable(_ set: PitchEditSet) -> PitchEditSet? { set }

    /// Planted and seen red (W7-NTU P-tick): `trackVoiceSize` emitting a
    /// `.voiceSize` commit per tick.
    @Test("W7-NTU U1 — Keep voice size: a drag is ONE commit, on release, never per tick; the draft draws while it runs")
    func voiceSizeDragCommitsOnce() async throws {
        let rig = await singerRig(Self.updatedTable)
        let model = rig.model
        #expect(model.offersSingerGroup)
        #expect(rig.group.voice.readout == "100%")
        for fraction in [0.9, 0.8, 0.7, 0.6, 0.52] {
            model.trackVoiceSize(atFraction: fraction, fine: false)
        }
        #expect(rig.commits.isEmpty, "a tick committed")
        #expect(model.voiceSizePress == .drag(amount: 0.5), "0.52 lands on the 50% stop")
        #expect(model.voiceSizeDraft == 0.5)
        #expect(rig.group.voice.readout == "50%")
        #expect(rig.group.voice.isDragging)
        let commit = try #require(model.releaseVoiceSize())
        #expect(commit.kind == .voiceSize(amount: 0.5))
        #expect(rig.commits.count == 1)
        #expect(model.voiceSizePress == nil)
        #expect(!rig.group.voice.isDragging)
        // ⌥ (fine) skips the stop.
        model.trackVoiceSize(atFraction: 0.52, fine: true)
        #expect(model.voiceSizeDraft == 0.52)
        model.cancelVoiceSize()
    }

    @Test("W7-NTU U1 — a voice drag released where it started, or cancelled, commits nothing")
    func voiceSizeNoOpAndCancel() async {
        let rig = await singerRig(Self.updatedTable)
        let model = rig.model
        model.trackVoiceSize(atFraction: 0.99, fine: false)          // the 100% stop = stored
        #expect(model.releaseVoiceSize() == nil)
        model.trackVoiceSize(atFraction: 0.3, fine: false)
        model.cancelDrag()                                             // the pane's Escape / disappear path
        #expect(model.voiceSizePress == nil)
        #expect(model.releaseVoiceSize() == nil)
        #expect(rig.commits.isEmpty)
    }

    /// Planted and seen red (W7-NTU P-legacy-write): the legacy press routed
    /// to `.voiceSize` (a drag on the dim slider writing its amount alone,
    /// which `setClipFormantCorrection` stores WITHOUT the update — D4-1 (b)
    /// broken with a green read-back).
    @Test("⭐ W7-NTU U1 — on a vocal tuned before the update, every press on the slider is THE update: no draft, ONE commit on release")
    func legacyPressIsTheUpdate() async throws {
        let rig = await singerRig(Self.legacyTable)
        let model = rig.model
        #expect(rig.group.voice.needsUpdate)
        model.trackVoiceSize(atFraction: 0.3, fine: false)
        #expect(model.voiceSizePress == .update)
        #expect(model.voiceSizeDraft == nil, "a legacy press drew a draft")
        model.trackVoiceSize(atFraction: 0.8, fine: false)
        #expect(model.voiceSizePress == .update)
        #expect(rig.group.voice.amount == nil)
        #expect(rig.commits.isEmpty)
        let commit = try #require(model.releaseVoiceSize())
        #expect(commit.kind == .naturalTuningUpdate)
        #expect(rig.commits.count == 1)
    }

    @Test("W7-NTU U1 — the update line: a tap on an old vocal is ONE update; on an updated one, nothing")
    func updateLineTap() async {
        let old = await singerRig(Self.legacyTable)
        #expect(old.model.updateToNaturalTuning()?.kind == .naturalTuningUpdate)
        #expect(old.commits.count == 1)
        let new = await singerRig(Self.updatedTable)
        #expect(new.model.updateToNaturalTuning() == nil)
        #expect(new.commits.isEmpty)
    }

    /// Planted and seen red (W7-NTU P-consonants): the switch writing the
    /// state it SHOWS (`enabled: keepsConsonantsUntuned`); and (P-snappy0)
    /// Snappy writing 0.
    @Test("W7-NTU U1 — Consonants and Slides: one commit per click; the lit step commits nothing")
    func consonantsAndSlidesCommitOnce() async {
        let rig = await singerRig(Self.updatedTable)
        let model = rig.model
        #expect(model.toggleConsonants()?.kind == .consonants(enabled: false))
        #expect(model.toggleConsonants()?.kind == .consonants(enabled: true))
        #expect(model.pickSlides(.smooth) == nil, "the lit step re-committed")
        #expect(model.pickSlides(.slow)?.kind == .slideSmoothness(centsPerSecond: 1500))
        #expect(model.pickSlides(.snappy)?.kind == .slideSmoothness(centsPerSecond: 20000))
        #expect(rig.commits.count == 4)
    }

    @Test("W7-NTU U1 — no notes, no group: every door is a no-op")
    func noNotesNoGroup() {
        let model = PitchEditorModel(clipID: UUID(), geometry: awkwardGeometry())
        let sink = Box()
        model.onCommit = { sink.commits.append($0) }
        #expect(!model.offersSingerGroup)
        model.trackVoiceSize(atFraction: 0.5, fine: false)
        #expect(model.voiceSizePress == nil)
        #expect(model.releaseVoiceSize() == nil)
        #expect(model.updateToNaturalTuning() == nil)
        #expect(model.toggleConsonants() == nil)
        #expect(model.pickSlides(.slow) == nil)
        #expect(sink.commits.isEmpty)
    }

    // MARK: Through the store

    /// Planted and seen red (W7-NTU P-wrong-amount): the funnel sending the
    /// store 0.75 for any amount — the funnel's read-back says NO, and this
    /// test's own read of the clip finds 0.75. And (P-consonants): the switch
    /// writing the state it SHOWS — the funnel's read-back says YES (ON was
    /// sent and ON is stored), and only this test's read of the clip (`.on`,
    /// not `.offByChoice`) and the undo journal catch it.
    @Test("⭐ W7-NTU U1 — through the store: each gesture is ONE undo step with its own name, reads back from the clip, moves nothing else, and undo restores the vocal exactly")
    func groupThroughTheStore() async throws {
        let rig = await singerRig(Self.updatedTable)
        let model = rig.model
        let before = try #require(rig.stored)
        let depth = rig.undoDepth

        // Keep voice size: a drag through four ticks, one write.
        for fraction in [0.8, 0.7, 0.6, 0.5] { model.trackVoiceSize(atFraction: fraction, fine: false) }
        model.releaseVoiceSize()
        #expect(rig.writes == [true])
        #expect(rig.stored?.formantCorrection == 0.5, "the clip does not hold 50%")
        #expect(rig.undoDepth == depth + 1)
        #expect(rig.undoTop == "Keep Voice Size")
        #expect(rig.group.voice.readout == "50%", "the row does not read the stored value back")

        // Consonants: OFF is a CHOICE (W7-D2), and the row reads OFF.
        model.toggleConsonants()
        #expect(rig.writes == [true, true])
        #expect(rig.stored?.consonantProtection == .offByChoice)
        #expect(rig.undoTop == "Keep Consonants")
        #expect(rig.group.consonants.face == "OFF")

        // Slides: Snappy is the ceiling, never 0.
        model.pickSlides(.snappy)
        #expect(rig.writes == [true, true, true])
        #expect(rig.stored?.transitionSlopeCentsPerSecond == PitchEditSet.transitionSlopeRange.upperBound)
        #expect(rig.undoTop == "Slide Smoothness")
        #expect(rig.group.slides.selected == .snappy)
        #expect(rig.undoDepth == depth + 3, "three gestures are \(rig.undoDepth - depth) undo steps")
        #expect(rig.refusals.isEmpty, "\(rig.refusals)")

        // The invariance control: no note moved.
        #expect(rig.stored?.segments == before.segments)

        for _ in 0..<3 { _ = try rig.store.undo() }
        #expect(rig.stored == before, "three undos did not restore the vocal exactly")
    }

    /// Planted and seen red (W7-NTU P-legacy-write), through the store: the
    /// dim slider's press writing `.voiceSize(0.2)` stores 20% and leaves the
    /// vocal un-updated (consonants off, slides 0) — and the funnel's read-back
    /// says YES (20% was sent, 20% is stored): only this test's own read of the
    /// clip and the journal's step name catch it.
    @Test("⭐ W7-NTU U1 — an old vocal through the store: the tap is ONE \"Update Tuning\" step that sets all three and keeps every note; undo brings the old vocal back exactly; a slider press is the SAME update")
    func legacyUpdateThroughTheStore() async throws {
        let rig = await singerRig(Self.legacyTable)
        let model = rig.model
        let before = try #require(rig.stored)
        #expect(before.predatesNaturalTuning)
        let depth = rig.undoDepth

        model.updateToNaturalTuning()
        #expect(rig.writes == [true])
        let after = try #require(rig.stored)
        #expect(after == before.upgradedToNaturalTuning())
        #expect(after.formantCorrection == PitchEditSet.newSetFormantCorrection)
        #expect(after.keepsConsonantsUntuned)
        #expect(after.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        #expect(after.segments == before.segments, "the update moved a note")
        #expect(rig.undoDepth == depth + 1)
        #expect(rig.undoTop == "Update Tuning")
        #expect(!rig.group.voice.needsUpdate, "the row still asks for the update")
        #expect(rig.group.voice.readout == "100%")

        _ = try rig.store.undo()
        #expect(rig.stored == before, "undo did not bring the old vocal back exactly")
        model.syncStoredNoteTable(rig.stored)
        #expect(rig.group.voice.needsUpdate)

        // The dim slider: a press anywhere is the update, never its amount.
        model.trackVoiceSize(atFraction: 0.2, fine: false)
        model.releaseVoiceSize()
        #expect(rig.writes == [true, true])
        #expect(rig.stored?.formantCorrection == PitchEditSet.newSetFormantCorrection,
                "a press on the dim slider wrote \(String(describing: rig.stored?.formantCorrection))")
        #expect(rig.stored?.keepsConsonantsUntuned == true)
        #expect(rig.undoTop == "Update Tuning")
    }

    @Test("W7-NTU U1 — a clip holding only the editor's seed: the first group click stores the seed WITH the change, as ONE step")
    func seedOnlyClipStoresTheSeed() async throws {
        let rig = await singerRig { _ in nil }
        let model = rig.model
        #expect(rig.stored == nil)
        #expect(model.offersSingerGroup)
        let seed = model.seedForCommit
        #expect(!seed.predatesNaturalTuning, "the editor's seed is never a legacy set")
        let depth = rig.undoDepth
        let commit = try #require(model.pickSlides(.slow))
        #expect(commit.seedIfAbsent == seed)
        #expect(rig.writes == [true])
        let stored = try #require(rig.stored)
        #expect(stored.transitionSlopeCentsPerSecond == 1500)
        #expect(stored.segments == seed.segments)
        #expect(rig.undoDepth == depth + 1)
    }
}


// MARK: - W7-NTU U3 — the Voice tool (natural tuning §1(f) items 2-3)
//
// The pane half: a press on a note in the Voice tool, made with the pane's own
// calls in the pane's order; ONE commit per gesture and none for one that
// changes nothing; a sound refused in words; R11's short note; the double-click
// reset; Escape; the note menu's Voice row; and each write through a REAL store
// via the app funnel's own arm (`PitchEditorVoiceWrite`), read back WHOLE,
// counted in the undo journal and undone. The arithmetic and the words are
// pinned headless in `PitchEditorVoiceToolTests` (nonisolated).
//
// ⚠️ An EXTENSION of the existing `@MainActor` suite, never a new `@Suite`:
// `MainActorOccupancySiteTests` bounds the suites.
@MainActor
extension PitchEditorModelTests {

    /// C-0's three-note fixture (unstretched, untransposed) in the Voice tool,
    /// with `table(f.set)` stored (nil: the editor's seed is the table), wired
    /// to a real store through `PitchEditorVoiceWrite` and resynced from the
    /// clip, as the pane does.
    private func voiceRig(_ table: ((PitchEditSet) -> PitchEditSet?)?) async -> SingerRig {
        let f = PitchEditorPlayedLineTests.fixture(shift: 0)
        var clip = f.clip
        clip.stretchRatio = 1
        if let table { clip.pitchEdits = table(f.set) }
        let fixture = PitchEditorPlayedLineTests.Fixture(a: f.a, b: f.b, c: f.c, clip: clip)
        let store = ProjectStore(tracks: [Track(name: "Vocals", kind: .audio, clips: [clip])])
        let (model, _) = await PitchEditorPlayedLineTests.loadedModel(fixture, contour: nil)
        model.tool = .voice
        let rig = SingerRig(clip: clip, store: store, model: model)
        model.onCommit = { [unowned rig] commit in
            rig.commits.append(commit)
            do {
                rig.writes.append(try PitchEditorVoiceWrite.commit(commit.kind, clipID: clip.id,
                                                                   seedIfAbsent: commit.seedIfAbsent,
                                                                   to: store))
            } catch {
                rig.refusals.append("\(error)")
            }
            model.syncStoredNoteTable(store.tracks[0].clips[0].pitchEdits)
        }
        return rig
    }

    /// ONE Voice press, made with the pane's own calls in the pane's order:
    /// `dragChanged`'s (`trackPress`, then `updateVoiceDrag` while a draft
    /// exists) for the first tick and for each point, then `dragEnded`'s
    /// (`releasePress` with the click count, then the release's own model
    /// call). ⌥ rides as it does there: fine per tick.
    @discardableResult
    private func voicePress(_ model: PitchEditorModel, from start: CGPoint, through points: [CGPoint] = [],
                            fine: Bool = false, clicks: Int = 1) -> PitchEditorReleaseAction {
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        if model.voiceDrag != nil { model.updateVoiceDrag(translationHeight: 0, fine: fine) }
        for point in points {
            _ = model.trackPress(start: start, location: point, modifiers: .none)
            if model.voiceDrag != nil {
                model.updateVoiceDrag(translationHeight: Double(point.y - start.y), fine: fine)
            }
        }
        let action = model.releasePress(start: start, location: points.last ?? start, modifiers: .none,
                                        snapBypassed: fine, clickCount: clicks)
        switch action {
        case .endFormantDrag: _ = model.endVoiceDrag()
        case .formantReset(let id): _ = model.resetVoice(segmentID: id)
        default: break
        }
        return action
    }

    /// Planted and seen red (W7-NTU P-v-tick): `updateVoiceDrag` emitting a
    /// commit per tick.
    @Test("W7-NTU U3 — a Voice drag: up is brighter; the draft, its mark and the readout follow the pointer with NO commit; the release is ONE \"Set Note Voice\" step of the note's final Voice, read back from the store")
    func voiceDragCommitsOnce() async throws {
        let rig = await voiceRig(Self.updatedTable)
        let model = rig.model
        let a = try #require(rig.stored?.segments.first).id
        let start = bodyPoint(model, a)
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        #expect(model.voiceDrag?.segmentID == a)
        #expect(model.voiceDrag?.isDragging == false)
        for step in 1...4 {
            let point = CGPoint(x: start.x, y: start.y - CGFloat(step * 6))
            _ = model.trackPress(start: start, location: point, modifiers: .none)
            model.updateVoiceDrag(translationHeight: Double(point.y - start.y), fine: false)
        }
        // 24 pt up: +2.0, drawn, and nothing written.
        #expect(model.voiceDrag?.semitones == 2)
        #expect(rig.commits.isEmpty, "a Voice tick committed")
        #expect(model.voiceMarks.map(\.chip) == ["Brighter 2.0"])
        #expect(model.voiceMarks.first?.isLive == true)
        #expect(model.voiceReadout(hover: nil) == "Voice: brighter 2.0")
        #expect(model.escapeGestureLive)
        let depth = rig.undoDepth
        let action = model.releasePress(start: start, location: CGPoint(x: start.x, y: start.y - 24),
                                        modifiers: .none)
        #expect(action == .endFormantDrag(a))
        let commit = try #require(model.endVoiceDrag())
        #expect(commit.kind == .noteFormant(segmentIDs: [a], semitones: 2))
        #expect(rig.commits.count == 1)
        #expect(rig.writes == [true])
        #expect(rig.stored?.segments.first { $0.id == a }?.formantOffsetSemitones == 2)
        #expect(rig.undoDepth == depth + 1)
        #expect(rig.undoTop == "Set Note Voice")
        #expect(model.voiceDrag == nil)
        // At rest, the STORED value is what the mark draws.
        #expect(model.voiceMarks.map(\.chip) == ["Brighter 2.0"])
        #expect(model.voiceMarks.first?.isLive == false)
    }

    @Test("W7-NTU U3 — a click selects and writes nothing; a drag that comes back to where it began writes nothing; a sideways drag writes nothing")
    func voiceNoOps() async throws {
        let rig = await voiceRig(Self.updatedTable)
        let model = rig.model
        let a = try #require(rig.stored?.segments.first).id
        let start = bodyPoint(model, a)
        #expect(voicePress(model, from: start) == .click(.selectOnly(a)))
        #expect(model.selection == [a])
        #expect(model.voiceDrag == nil, "a click left its draft behind")
        #expect(voicePress(model, from: start, through: [CGPoint(x: start.x, y: start.y - 24), start])
                == .endFormantDrag(a))
        #expect(voicePress(model, from: start, through: [CGPoint(x: start.x + 30, y: start.y)])
                == .endFormantDrag(a))
        #expect(rig.commits.isEmpty, "a gesture that changed nothing wrote \(rig.commits.map(\.kind))")
        #expect(model.voiceDrag == nil)
    }

    @Test("W7-NTU U3 — ⌥ is fine: the same 24 pt with ⌥ held is a quarter of the change (0.5, not 2.0)")
    func voiceFine() async throws {
        let rig = await voiceRig(Self.updatedTable)
        let model = rig.model
        let a = try #require(rig.stored?.segments.first).id
        let start = bodyPoint(model, a)
        voicePress(model, from: start, through: [CGPoint(x: start.x, y: start.y - 24)], fine: true)
        #expect(rig.commits.map(\.kind) == [.noteFormant(segmentIDs: [a], semitones: 0.5)])
        #expect(rig.writes == [true])
    }

    /// Planted and seen red (W7-NTU P-v-reset): `resetVoice` writing on a
    /// note already as sung.
    @Test("W7-NTU U3 — a double-click puts the note back as sung: the first click selects, the second is ONE \"Set Note Voice\" step of 0; on a note already as sung it writes nothing")
    func voiceDoubleClickResets() async throws {
        let rig = await voiceRig { set in
            var table = set.upgradedToNaturalTuning()
            table.segments[0].formantOffsetSemitones = -3
            return table
        }
        let model = rig.model
        let a = try #require(rig.stored?.segments.first).id
        let start = bodyPoint(model, a)
        #expect(voicePress(model, from: start) == .click(.selectOnly(a)))
        #expect(voicePress(model, from: start, clicks: 2) == .formantReset(a))
        #expect(rig.commits.map(\.kind) == [.noteFormant(segmentIDs: [a], semitones: 0)])
        #expect(rig.writes == [true])
        #expect(rig.stored?.segments.first { $0.id == a }?.formantOffsetSemitones == 0)
        #expect(rig.undoTop == "Set Note Voice")
        // Again, on a note now as sung: nothing.
        voicePress(model, from: start)
        #expect(voicePress(model, from: start, clicks: 2) == .formantReset(a))
        #expect(rig.commits.count == 1, "a reset of a note already as sung wrote an undo step")
    }

    /// Planted and seen red (W7-NTU P-v-sound): `beginVoiceDrag` without its
    /// `.unpitched` guard.
    @Test("W7-NTU U3 — a SOUND is refused at its press, in words, and the press abandoned: no draft, no selection, no commit, and its release does nothing")
    func voiceRefusesASound() {
        let (model, sink, _) = withSounds([1])
        model.tool = .voice
        let sound = model.blobs[1]
        let start = centre(of: sound, in: model)
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        #expect(model.refusal == PitchEditorFormantCopy.voiceSoundRefusal)
        #expect(model.voiceDrag == nil)
        #expect(model.press.current?.kind == PitchEditorPressKind.none)
        let end = CGPoint(x: start.x, y: start.y - 30)
        _ = model.trackPress(start: start, location: end, modifiers: .none)
        model.updateVoiceDrag(translationHeight: -30, fine: false)
        #expect(model.releasePress(start: start, location: end, modifiers: .none) == .nothing)
        #expect(sink.commits.isEmpty)
        #expect(model.selection.isEmpty)
        // Hovered, a sound says nothing; the note beside it says its Voice.
        #expect(model.voiceReadout(hover: start) == nil)
        #expect(model.voiceReadout(hover: centre(of: model.blobs[0], in: model)) == "Voice: as sung")
    }

    @Test("W7-NTU U3 — R11: over a note shorter than 80 ms the readout says it is too short to change alone, at rest and mid-drag; the drag is still taken and its chip prints the number")
    func voiceShortNote() throws {
        let (model, sink, ids) = fourNotes()
        var table = model.noteTable
        table.segments[2].endSeconds = table.segments[2].startSeconds + 0.05
        model.syncStoredNoteTable(table)
        model.tool = .voice
        let short = try #require(model.blobs.first { $0.id == ids[2] })
        let start = centre(of: short, in: model)
        #expect(model.voiceReadout(hover: start) == PitchEditorFormantCopy.voiceTooShort)
        #expect(model.voiceReadout(hover: centre(of: model.blobs[0], in: model)) == "Voice: as sung")
        let end = CGPoint(x: start.x, y: start.y + 36)
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        _ = model.trackPress(start: start, location: end, modifiers: .none)
        model.updateVoiceDrag(translationHeight: 36, fine: false)
        #expect(model.voiceDrag?.isTooShort == true)
        #expect(model.voiceReadout(hover: nil) == PitchEditorFormantCopy.voiceTooShort)
        #expect(model.voiceMarks.map(\.chip) == ["Deeper 3.0"])
        _ = model.releasePress(start: start, location: end, modifiers: .none)
        model.endVoiceDrag()
        #expect(sink.commits.map(\.kind) == [.noteFormant(segmentIDs: [ids[2]], semitones: -3)])
    }

    @Test("W7-NTU U3 — Escape mid-drag drops the Voice draft with NOTHING committed, and the rest of that press does nothing")
    func voiceEscape() {
        let (model, sink, _) = fourNotes()
        model.tool = .voice
        let start = centre(of: model.blobs[0], in: model)
        _ = model.trackPress(start: start, location: start, modifiers: .none)
        #expect(!model.escapeGestureLive, "a press inside the slop is not a live gesture")
        let end = CGPoint(x: start.x, y: start.y - 30)
        _ = model.trackPress(start: start, location: end, modifiers: .none)
        model.updateVoiceDrag(translationHeight: -30, fine: false)
        #expect(model.escapeGestureLive)
        model.cancelGestureForEscape()
        #expect(model.voiceDrag == nil)
        _ = model.trackPress(start: start, location: CGPoint(x: start.x, y: start.y - 40), modifiers: .none)
        model.updateVoiceDrag(translationHeight: -40, fine: false)
        #expect(model.voiceDrag == nil, "a cancelled Voice drag restarted itself")
        #expect(model.releasePress(start: start, location: end, modifiers: .none) == .nothing)
        #expect(model.endVoiceDrag() == nil)
        #expect(sink.commits.isEmpty)
    }

    /// Planted and seen red (W7-NTU P-v-marks): `voiceMarks` without its
    /// `tool == .voice` guard.
    @Test("W7-NTU U3 — the marks: only in the Voice tool, only for NOTES with a Voice, at the STORED value at rest; never for a sound, whatever it carries")
    func voiceMarksOnlyInTheVoiceTool() {
        let (model, _, ids) = withSounds([1])
        var table = model.noteTable
        table.segments[0].formantOffsetSemitones = -3
        table.segments[1].formantOffsetSemitones = 2   // a sound: never drawn
        table.segments[2].formantOffsetSemitones = 1.5
        model.syncStoredNoteTable(table)
        #expect(model.voiceMarks.isEmpty, "a Voice drawn in the Move tool")
        model.tool = .voice
        let marks = model.voiceMarks
        #expect(marks.map(\.segmentID) == [ids[0], ids[2]])
        #expect(marks.map(\.chip) == ["Deeper 3.0", "Brighter 1.5"])
        #expect(marks.map(\.offsetFraction) == [-0.5, 0.25])
        #expect(marks.allSatisfy { !$0.isLive })
        #expect(marks.first?.blobRect == model.rect(for: model.blobs[0]))
    }

    /// Planted and seen red (W7-NTU P-v-menu-model): the Voice row naming the
    /// sound's id (the store would refuse the whole batch).
    @Test("W7-NTU U3 — the note menu's Voice row: Deeper and Brighter in the Voice tool only, As sung in every tool once a note has a Voice; each is ONE commit naming only the NOTES that change, never a sound")
    func voiceMenuRow() {
        let (model, sink, ids) = withSounds([1])
        model.selectOnly(ids[0])
        model.toggle(ids[1])
        model.toggle(ids[2])
        #expect(model.noteMenu(at: nil).map(\.title) == ["Clear 3 Selected"], "the Move tool's menu changed")
        model.tool = .voice
        #expect(model.noteMenu(at: nil).map(\.title)
                == ["Clear 3 Selected", "Voice: Deeper 2.0", "Voice: Brighter 2.0"])
        model.performNoteAction(.voiceDeeper)
        #expect(sink.commits.map(\.kind) == [.noteFormant(segmentIDs: [ids[0], ids[2]], semitones: -2)])
        // The store hands it back.
        var table = model.noteTable
        table.segments[0].formantOffsetSemitones = -2
        table.segments[2].formantOffsetSemitones = -2
        model.syncStoredNoteTable(table)
        let items = model.noteMenu(at: nil)
        #expect(items.map(\.title)
                == ["Clear 3 Selected", "Voice: Deeper 2.0", "Voice: Brighter 2.0", "Voice: As sung"])
        #expect(items.first { $0.action == .voiceDeeper }?.isEnabled == false)
        // Deeper again changes nothing, so nothing is written.
        #expect(model.performNoteAction(.voiceDeeper) == nil)
        #expect(sink.commits.count == 1)
        // The Move tool: the reset stays offered, the two steps do not.
        model.tool = .pointer
        #expect(model.noteMenu(at: nil).map(\.title) == ["Clear 3 Selected", "Voice: As sung"])
        model.performNoteAction(.voiceAsSung)
        #expect(sink.commits.last?.kind == .noteFormant(segmentIDs: [ids[0], ids[2]], semitones: 0))
    }

    /// Planted and seen red (W7-NTU P-v-d41, through the store): `took` without
    /// `afterHandEdit(from:)` reads NO to the store's correct write.
    @Test("⭐ W7-NTU U3 — an old vocal through the store: the first Voice drag is ONE \"Set Note Voice\" step that ALSO updates the vocal (D4-1 (b)), keeps a consonant OFF somebody chose (NT-C2-F1) and moves no pitch; undo brings the old vocal back exactly")
    func voiceOnAnOldVocalThroughTheStore() async throws {
        let rig = await voiceRig { set in
            var legacy = set
            legacy.consonantProtection = .offByChoice
            return legacy
        }
        let model = rig.model
        let before = try #require(rig.stored)
        #expect(before.predatesNaturalTuning)
        #expect(before.consonantProtection == .offByChoice)
        let a = try #require(before.segments.first).id
        let depth = rig.undoDepth
        let start = bodyPoint(model, a)
        voicePress(model, from: start, through: [CGPoint(x: start.x, y: start.y + 24)])
        #expect(rig.commits.map(\.kind) == [.noteFormant(segmentIDs: [a], semitones: -2)])
        #expect(rig.writes == [true], "the funnel's read-back said NO to the store's own write")
        let after = try #require(rig.stored)
        #expect(after.segments.first?.formantOffsetSemitones == -2)
        #expect(after.formantCorrection == PitchEditSet.newSetFormantCorrection)
        #expect(after.transitionSlopeCentsPerSecond == PitchEditSet.defaultTransitionSlope)
        #expect(after.consonantProtection == .offByChoice, "the update switched a chosen OFF back on")
        #expect(after.segments.map(\.pitchOffsetCents) == before.segments.map(\.pitchOffsetCents))
        #expect(rig.undoDepth == depth + 1)
        #expect(rig.undoTop == "Set Note Voice")
        _ = try rig.store.undo()
        #expect(rig.stored == before, "undo did not bring the old vocal back exactly")
    }

    @Test("W7-NTU U3 — a clip holding only the editor's seed: the first Voice drag stores the seed WITH the Voice, as ONE step")
    func voiceOnASeedOnlyClip() async throws {
        let rig = await voiceRig { _ in nil }
        let model = rig.model
        #expect(rig.stored == nil)
        let seed = model.seedForCommit
        let a = try #require(seed.segments.first).id
        let depth = rig.undoDepth
        let start = bodyPoint(model, a)
        voicePress(model, from: start, through: [CGPoint(x: start.x, y: start.y - 12)])
        #expect(rig.commits.first?.seedIfAbsent == seed)
        #expect(rig.writes == [true])
        let stored = try #require(rig.stored)
        #expect(stored.segments.first { $0.id == a }?.formantOffsetSemitones == 1)
        #expect(stored.segments.count == seed.segments.count)
        #expect(rig.undoDepth == depth + 1)
    }
}
