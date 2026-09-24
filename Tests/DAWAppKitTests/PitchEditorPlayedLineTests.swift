import CoreGraphics
import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

/// m23-ap C-0b — **THE EDITOR DRAWS THE LINE THE RENDER WILL PLAY, AND SAYS SO
/// WHEN IT CANNOT.** Design `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md`
/// §4.4 and §4.6 tests 4–7.
///
/// The gate that the line IS the render's curve lives in
/// `Tests/DAWEngineTests/PitchEditorDisplayMatchesRenderTests.swift` (it needs
/// `DAWEngine`'s render side). This file holds what only the editor model can
/// get wrong: the live drag, the transpose in both directions, holes, and the
/// caption. Every test names the defect planted to prove it can fail; each was
/// applied, seen red, and reverted.
///
/// ⚠️ NOT a `@MainActor` suite — `MainActorOccupancySiteTests` bounds those
/// (a review cadence). Each test that touches the model is `@MainActor` on its
/// own — which that census does NOT see (its Leg C 394 paragraph says so).
@Suite("C-0 — the pitch editor's played line")
struct PitchEditorPlayedLineTests {

    // MARK: - The fixture (§4.6, the same shape the engine-side gate uses)

    static let frameRate = 62.5
    static let period = 1 / 62.5
    static let tempo = try! TempoMap(segments: [.init(startBeat: 0, bpm: 120)])

    /// Three voiced runs with a 5.5 Hz, ±40 c vibrato, split by unvoiced
    /// holes, plus an unvoiced tail. Frame indices at 62.5 fps:
    ///   A 0..<50 (220 Hz) · hole 50..<56 · B 56..<116 (246.94 Hz)
    ///   · hole 116..<126 · C 126..<186 (196 Hz) · tail 186..<196.
    static func frames(gridOffset: Double = 0) -> [ClipPitchFrame] {
        var out: [ClipPitchFrame] = []
        func voiced(_ range: Range<Int>, hz: Double) {
            for i in range {
                let t = Double(i) * period + gridOffset
                let cents = 40 * sin(2 * .pi * 5.5 * t)
                out.append(ClipPitchFrame(timeSeconds: t, frequencyHz: hz * pow(2, cents / 1200),
                                          confidence: 0.97, levelDbfs: -16, absence: nil))
            }
        }
        func unvoiced(_ range: Range<Int>, _ absence: PitchDetectionAbsence) {
            for i in range {
                out.append(ClipPitchFrame(timeSeconds: Double(i) * period + gridOffset,
                                          frequencyHz: nil, confidence: 0.2,
                                          levelDbfs: absence == .belowLevel ? -90 : -40,
                                          absence: absence))
            }
        }
        voiced(0..<50, hz: 220)
        unvoiced(50..<56, .belowConfidence)
        voiced(56..<116, hz: 246.94)
        unvoiced(116..<126, .belowLevel)
        voiced(126..<186, hz: 196)
        unvoiced(186..<196, .belowLevel)
        return out
    }

    static func result(_ frames: [ClipPitchFrame]) -> PitchDetectionResult {
        let voiced = frames.filter { $0.frequencyHz != nil }.count
        return PitchDetectionResult(
            frames: frames, frameCount: frames.count, voicedFrameCount: voiced,
            voicedFraction: frames.isEmpty ? 0 : Double(voiced) / Double(frames.count),
            frameRateHz: frameRate, analysisSampleRateHz: 16_000, sourceSampleRateHz: 48_000,
            windowStartSeconds: frames.first?.timeSeconds ?? 0,
            windowDurationSeconds: Double(frames.count) * period,
            confidenceThreshold: PitchDetectionDefaults.defaultConfidenceThreshold,
            silenceFloorDbfs: PitchDetectionDefaults.defaultSilenceFloorDbfs,
            minFrequencyHz: 46, maxFrequencyHz: 2_093)
    }

    /// The render's whole-file contour (what THE seam answers).
    static let wholeFile = result(frames())
    /// The editor's own window detection — a different analysis, its grid 2 ms
    /// off the render's (finding F18), used as the estimate's fallback.
    static let windowDetection = result(frames(gridOffset: 0.002))

    struct Fixture {
        let a: NoteSegment
        let b: NoteSegment
        let c: NoteSegment
        let clip: Clip
        var set: PitchEditSet { clip.pitchEdits ?? .empty }
    }

    /// A untouched (the drag moves it). B `vibratoScale: 0` — it needs the
    /// contour. C a 6 Hz, ±40 c generator. On a clip transposed `shift`
    /// semitones and stretched 1.25×.
    static func fixture(shift: Double = 2) -> Fixture {
        let table = PitchNoteTable.detected(from: wholeFile)
        precondition(table.segments.count == 3, "the fixture must segment into three notes")
        let a = table.segments[0]
        var b = table.segments[1]
        b.vibratoScale = 0
        var c = table.segments[2]
        c.vibratoRateHz = 6
        c.vibratoDepthCents = 40
        let clip = Clip(name: "vox", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/tmp/c0-played-line.wav"),
                        stretchRatio: 1.25, pitchShiftSemitones: shift,
                        pitchEdits: PitchEditSet(segments: [a, b, c]))
        return Fixture(a: a, b: b, c: c, clip: clip)
    }

    /// A reference box so the commit sink survives the closure.
    @MainActor final class Sink {
        var commits: [PitchEditorCommit] = []
    }

    static func seam(_ contour: PitchRenderContour) -> PitchEditorRenderContourProvider {
        { _ in PitchRenderInputs(contour: contour, sourceDurationSeconds: 3.136) }
    }

    /// A model loaded the way the pane loads one: the window detection
    /// applied, the clip's stored table synced, and — when `contour` is given —
    /// THE seam answered.
    @MainActor
    static func loadedModel(_ f: Fixture, contour: PitchRenderContour?) async
    -> (model: PitchEditorModel, sink: Sink) {
        let model = PitchEditorModel(clipID: f.clip.id,
                                     geometry: PitchEditorGeometry(clip: f.clip, tempoMap: tempo))
        model.apply(ClipPitchDetection(pitch: windowDetection, clipWindowDurationSeconds: 3.2,
                                       stretchRatio: f.clip.stretchRatio,
                                       pitchShiftSemitones: f.clip.pitchShiftSemitones))
        model.syncStoredNoteTable(f.clip.pitchEdits)
        if let contour { await model.loadRenderContour(using: seam(contour)) }
        let sink = Sink()
        model.onCommit = { sink.commits.append($0) }
        return (model, sink)
    }

    // MARK: - 4. draftMovesTheLine

    /// Planted and seen red: the draft line built from the STORED table
    /// instead of the draft (`rebuildDraftLine` not applying `offsetCents`) —
    /// A's interior then moves by 0, the "wobble left behind" picture.
    @Test("⭐ a live drag moves the note's stretch of line with it, and still commits only on release")
    @MainActor
    func draftMovesTheLine() async throws {
        let f = Self.fixture()
        let (model, sink) = await Self.loadedModel(f, contour: .detected(Self.wholeFile))
        let before = Array(model.playedLine.runs.joined())
        #expect(model.playedLine.basis == .render)
        let blob = try #require(model.blobs.first { $0.id == f.a.id })

        #expect(model.beginPitchDrag(on: blob))
        // The draft exists from the first moment of the gesture — and until
        // the pointer moves it IS the committed line.
        #expect(model.draftPlayedLine?.runs == model.playedLine.runs)

        // One row up, free (⌥) so it lands on exactly +100 cents, in twenty
        // pointer ticks.
        let row = model.geometry.rowHeight
        for tick in 1...20 {
            model.updatePitchDrag(translationHeight: -row * CGFloat(tick) / 20, free: true)
        }
        // ⛔ THE CADENCE: twenty ticks, zero store writes (`aDragTickNeverCommits`'s rule).
        #expect(sink.commits.isEmpty, "a pointer tick committed to the store")
        let draft = try #require(model.drag)
        #expect(abs(draft.offsetCents - 100) < 1e-9, "one row up is +100 cents, got \(draft.offsetCents)")

        let line = try #require(model.draftPlayedLine)
        let after = Array(line.runs.joined())
        #expect(after.count == before.count && !before.isEmpty)
        // A's gate is exactly 1 inside [start + h, end − h] (centred ramps of
        // half-width h = min(retune/2, duration/2)).
        let h = min(model.noteTable.retuneMs / 1000 / 2, (f.a.endSeconds - f.a.startSeconds) / 2)
        var interior = 0
        var untouched = 0
        for (old, new) in zip(before, after) {
            #expect(new.sourceSeconds == old.sourceSeconds && new.sungMidi == old.sungMidi,
                    "the draft moves the PITCH, never the frames")
            let t = old.sourceSeconds
            if t >= f.a.startSeconds + h && t <= f.a.endSeconds - h {
                interior += 1
                #expect(abs((new.playedMidi - old.playedMidi) - 1.0) < 1e-9,
                        "at \(t) s, inside A, the line moved \(new.playedMidi - old.playedMidi) st, not the draft's 1.0")
            } else if t >= f.b.startSeconds {
                untouched += 1
                #expect(new.playedMidi == old.playedMidi,
                        "at \(t) s (B or C) the line moved — a drag on A must not touch its neighbours")
            }
        }
        #expect(interior > 30 && untouched > 100, "the fixture must reach both checks (\(interior), \(untouched))")
        // The committed line is untouched while the pointer is down: nothing
        // has been written, so nothing the render plays has changed.
        #expect(Array(model.playedLine.runs.joined()) == before)

        // The two layers split the line at the draft span: the surface draws
        // nothing inside it, the overlay draws it.
        let span = try #require(model.draftSpan)
        let left = model.geometry.x(forSourceSecond: span.lowerBound)
        let right = model.geometry.x(forSourceSecond: span.upperBound)
        for point in model.playedLineSegments(excluding: span).joined() {
            #expect(point.x < left || point.x > right,
                    "the surface still draws the dragged stretch at x \(point.x) — it would be drawn twice")
        }
        #expect(!model.draftLineSegments.isEmpty, "the overlay has nothing to draw")

        // Release: exactly one commit, and the draft goes with the gesture.
        let commit = model.endPitchDrag()
        #expect(commit != nil)
        #expect(sink.commits.count == 1)
        #expect(model.draftPlayedLine == nil && model.draftLineSegments.isEmpty)
    }

    // MARK: - 5. transposeIsDrawnAndUndrawn

    /// Planted and seen red: `storedOffsetCents` without its
    /// `− clipPitchShiftSemitones` — the stored offset lands 200 cents high,
    /// and the read-back draws the note two rows above where it was let go.
    @Test("⭐ a transposed clip is DRAWN transposed, and a drag on it stores the untransposed offset")
    @MainActor
    func transposeIsDrawnAndUndrawn() async throws {
        let f = Self.fixture(shift: 2)
        let (model, sink) = await Self.loadedModel(f, contour: .detected(Self.wholeFile))
        let g = model.geometry
        #expect(g.clipPitchShiftSemitones == 2)
        #expect(model.blobs.count == 3)
        for blob in model.blobs {
            let drawn = blob.centreMidi + blob.offsetCents / 100 + 2
            #expect(g.drawnMidi(for: blob) == drawn)
            #expect(abs(g.rect(for: blob).midY - g.y(forMidi: drawn)) < 1e-9,
                    "the blob is not on its drawn row")
            #expect(g.drawnNoteName(for: blob) == Fundamental.noteName(midiNote: Int(drawn.rounded())),
                    "the label must name the note it SOUNDS as")
            // The ghost carries the transpose too: an untouched note on a
            // transposed clip sits exactly on its ghost (no false edit).
            #expect(abs(g.ghostRect(for: blob).midY - g.rect(for: blob).midY) < 1e-9
                    || blob.isMoved)
        }

        // Drag A three rows up on the DRAWN axis, snapped. The drawn target R
        // is an integer row; the stored offset must be (R − 2 − centre) × 100.
        let a = try #require(model.blobs.first { $0.id == f.a.id })
        let origin = g.drawnMidi(for: a)
        let target = origin.rounded() + 3
        #expect(g.midiRange.contains(target - 1) && g.midiRange.contains(target + 1),
                "the target row must sit inside the window for the snap to be exact")
        #expect(model.beginPitchDrag(on: a))
        model.updatePitchDrag(translationHeight: -CGFloat(target - origin) * g.rowHeight, free: false)
        model.endPitchDrag()
        guard case .notePitch(let id, let cents)? = sink.commits.last?.kind else {
            Issue.record("the release did not commit a pitch edit")
            return
        }
        #expect(id == f.a.id)
        let expected = (target - 2 - a.centreMidi) * 100
        #expect(abs(cents - expected) < 1e-9,
                "a drag to drawn row \(target) stored \(cents) c; (R − 2 − centre) × 100 is \(expected)")

        // The READ-BACK: store it the way the store would, and the note is
        // drawn on exactly the row it was let go on.
        var stored = model.noteTable
        let index = try #require(stored.segments.firstIndex { $0.id == id })
        stored.segments[index].pitchOffsetCents = cents
        model.syncStoredNoteTable(stored)
        let landed = try #require(model.blobs.first { $0.id == id })
        #expect(abs(model.geometry.drawnMidi(for: landed) - target) < 1e-9,
                "the saved note is drawn off the row it was dropped on")

        // Changing the transpose with the pane open moves EVERYTHING by the
        // difference — blobs and every point of the line — and nothing else.
        let lineBefore = Array(model.playedLine.runs.joined())
        let rowsBefore = model.blobs.map { model.geometry.drawnMidi(for: $0) }
        model.setClipPitchShiftSemitones(5)
        #expect(model.geometry.clipPitchShiftSemitones == 5)
        let rowsAfter = model.blobs.map { model.geometry.drawnMidi(for: $0) }
        for (old, new) in zip(rowsBefore, rowsAfter) {
            #expect(abs((new - old) - 3) < 1e-9)
        }
        let lineAfter = Array(model.playedLine.runs.joined())
        #expect(lineAfter.count == lineBefore.count && !lineBefore.isEmpty)
        for (old, new) in zip(lineBefore, lineAfter) {
            #expect(abs((new.playedMidi - old.playedMidi) - 3) < 1e-9,
                    "at \(old.sourceSeconds) s the line did not follow the transpose")
        }
    }

    // MARK: - 6. holesStayHoles

    /// Planted and seen red: `playedLineSegments` joining every run into one
    /// polyline — the B|C hole is then bridged by a straight segment the
    /// singer never sang.
    @Test("⭐ a hole in the singing is a GAP in the drawn line — and a split note is not")
    @MainActor
    func holesStayHoles() async throws {
        let f = Self.fixture()
        let (model, _) = await Self.loadedModel(f, contour: .detected(Self.wholeFile))
        let lines = model.playedLineSegments()
        #expect(lines.count == 3, "three voiced runs, three polylines — got \(lines.count)")

        // The B|C hole on screen: B's last frame centre to C's first.
        let g = model.geometry
        let holeLeft = g.x(forSourceSecond: 115 * Self.period + Self.period / 2)
        let holeRight = g.x(forSourceSecond: 126 * Self.period + Self.period / 2)
        // 0.176 s of source × 1.25 stretch at 120 BPM and the default 32 pt/beat
        // is 14.08 pt, against 1.28 pt between neighbouring frames: a hole ten
        // frame-steps wide, so "no segment spans it" is a real claim.
        let step = g.x(forSourceSecond: Self.period) - g.x(forSourceSecond: 0)
        #expect(holeRight - holeLeft > 10 * step, "the hole must be wide on screen for this check to mean anything")
        for line in lines {
            let reachesLeft = line.contains { $0.x <= holeLeft + 0.5 }
            let reachesRight = line.contains { $0.x >= holeRight - 0.5 }
            #expect(!(reachesLeft && reachesRight),
                    "one polyline has points on both sides of the B|C hole — the hole is bridged")
            for (p, q) in zip(line, line.dropFirst()) {
                #expect(q.x - p.x < holeRight - holeLeft,
                        "a segment from x \(p.x) to \(q.x) spans the hole")
            }
        }

        // POSITIVE CONTROL: a SPLIT makes two notes out of one run, and the
        // line is per RUN — so A's stretch stays one unbroken polyline across
        // the cut. (Per-note polylines would break it there: a 0 ms "hole"
        // the singer never left.) Split through the store's own op.
        let store = ProjectStore()
        _ = store.addTrack(kind: .audio)
        store.tracks[0].clips = [f.clip]
        let cut = (f.a.startSeconds + f.a.endSeconds) / 2
        let split = try store.splitClipNoteSegment(clipId: f.clip.id, segmentId: f.a.id,
                                                   atSourceSecond: cut)
        model.syncStoredNoteTable(split.pitchEdits)
        #expect(model.blobs.count == 4, "the split must have made two notes")
        let afterSplit = model.playedLineSegments()
        #expect(afterSplit.count == 3, "a split note is still ONE run and ONE polyline — got \(afterSplit.count)")
        let cutX = g.x(forSourceSecond: cut)
        #expect(afterSplit.contains { line in
            line.contains { $0.x < cutX } && line.contains { $0.x > cutX }
        }, "no polyline crosses the split point")
    }

    // MARK: - 7. estimateIsSaidOutLoud (model half; the site half is below)

    /// Planted and seen red: `PitchPlayedLine.make` hard-coding `.render` as
    /// its basis — the line then claims to be the sound while the render
    /// cannot shape B, and the caption disappears. And separately:
    /// `unresolvedNoteIDList` ignoring the contour phase — the pending state
    /// then draws an amber "cannot apply" outline over a wait.
    @Test("⭐ an estimate is SAID: basis, the sentence, and whether it is a wait or a shortfall")
    @MainActor
    func estimateIsSaidOutLoud() async throws {
        let f = Self.fixture()
        // Before the seam answers: a PROGRESS line, never a warning.
        let (model, _) = await Self.loadedModel(f, contour: nil)
        #expect(model.playedLine.basis == .estimate(reason: PitchPlayedLine.pendingReason))
        #expect(model.lineCaption == PitchEditorLineCaption(kind: .progress,
                                                            text: PitchPlayedLine.pendingReason))
        // ⛔ …and NO amber outline yet. The line has no contour while it waits,
        // so B reads unresolved in the CURVE — but nothing has failed, and an
        // outline would claim it had (seen in the pending render, then fixed).
        #expect(model.playedLine.unresolvedSegmentIDsInWindow == [f.b.id],
                "the control: the pending curve does list B as unresolved")
        #expect(model.unresolvedNoteIDs.isEmpty && model.unresolvedNoteIDList.isEmpty,
                "a wait drew a warning outline on \(model.unresolvedNoteIDList)")

        // `.unavailable` plus a fallback: an estimate, DRAWN, and said.
        let reason = "the pitch model is missing from this build"
        await model.loadRenderContour(using: Self.seam(.unavailable(reason: reason)))
        let unavailable = "The app couldn't analyse this recording (\(reason)), so wobble changes "
            + "can't be applied. Pitch moves still play."
        #expect(model.playedLine.basis == .estimate(reason: unavailable))
        #expect(model.lineCaption == PitchEditorLineCaption(kind: .shortfall, text: unavailable))
        #expect(!model.playedLine.runs.isEmpty, "an estimate is drawn from the fallback, never left blank")
        #expect(model.unresolvedNoteIDs == [f.b.id], "B cannot be flattened without the contour")

        // A set made by an older detector.
        await model.loadRenderContour(using: Self.seam(.analysisVersionMismatch(editSet: 0, detector: 1)))
        let older = "These notes were found by an older version of the app, so wobble changes "
            + "can't be applied to them. Pitch moves still play."
        #expect(model.lineCaption == PitchEditorLineCaption(kind: .shortfall, text: older))

        // The render's own contour, everything resolved: NO caption at all. A
        // caption that is always there stops being read.
        await model.loadRenderContour(using: Self.seam(.detected(Self.wholeFile)))
        #expect(model.playedLine.basis == .render)
        #expect(model.lineCaption == nil)
        #expect(model.unresolvedNoteIDs.isEmpty)

        // The render's contour, but one shaping note with no voiced frame
        // under it (placed in the unvoiced tail): the count sentence, and its
        // amber outline.
        let lonely = NoteSegment(startSeconds: 2.99, endSeconds: 3.10, detectedHz: 196,
                                 detectedConfidence: 0.9, vibratoScale: 0)
        let withLonely = PitchEditSet(analysisVersion: f.set.analysisVersion,
                                      segments: f.set.segments + [lonely],
                                      retuneMs: f.set.retuneMs)
        #expect(withLonely.segments.count == 4, "the canonical set must keep the lonely note")
        model.syncStoredNoteTable(withLonely)
        #expect(model.unresolvedNoteIDs == [lonely.id])
        #expect(model.lineCaption == PitchEditorLineCaption(
            kind: .shortfall,
            text: "1 note has no steady pitch the app could hear, so its wobble setting can't "
                + "change it. Its pitch move still plays."))
    }
}

// MARK: - The site half of test 7

/// `Sources/DAWApp` has no test target, so what the PANE does with the model's
/// caption and line is pinned here over comment-stripped source —
/// `PitchEditorInteractionSiteTests`' reader, verbatim. The offscreen renders
/// in the close record are the look; this is what keeps it from regressing.
@Suite("C-0 — the pitch editor pane draws the played line and SAYS its caption")
struct PitchEditorPlayedLineSiteTests {

    private static func sourcesDir() -> URL {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<12 {
            let candidate = dir.appendingPathComponent("Sources", isDirectory: true)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: candidate.path, isDirectory: &isDir), isDir.boolValue {
                return candidate
            }
            dir = dir.deletingLastPathComponent()
        }
        Issue.record("Could not locate Sources from \(#filePath)")
        return URL(fileURLWithPath: "/nonexistent")
    }

    private static func code(_ relativePath: String) -> String {
        let url = sourcesDir().appendingPathComponent(relativePath)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else {
            Issue.record("Could not read \(relativePath) under \(sourcesDir().path)")
            return ""
        }
        return content.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") {
                return ""
            }
            return line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
        }.joined(separator: "\n")
    }

    /// The text between two markers, or "" (which every positive assertion
    /// below then fails on).
    private static func slice(_ code: String, from start: String, to end: String) -> String {
        guard let a = code.range(of: start),
              let b = code.range(of: end, range: a.upperBound..<code.endIndex) else { return "" }
        return String(code[a.lowerBound..<b.lowerBound])
    }

    private static let viewPath = "DAWApp/PitchEditor/PitchEditorView.swift"
    private static let contentPath = "DAWApp/ContentView.swift"

    /// ⭐ THE POSITIVE CONTROL: the reader reaches real code and really strips
    /// comments — so the `!contains` assertions below cannot pass on an empty
    /// or unstripped read.
    @Test("the source reader reaches real code and strips comments (positive control)")
    func readerWorks() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("struct PitchEditorToolPalette: View"))
        #expect(view.count > 5_000)
        // Words that exist in this file ONLY in comments: present in the raw
        // text (so the absence below is not a typo), gone once stripped.
        let raw = (try? String(contentsOf: Self.sourcesDir().appendingPathComponent(Self.viewPath),
                               encoding: .utf8)) ?? ""
        for phrase in ["THE PLAYED LINE (m23-ap C-0)", "PROGRESS, NOT A WARNING"] {
            #expect(raw.contains(phrase), "the control phrase `\(phrase)` is not in the file at all")
            #expect(!view.contains(phrase), "the stripper left the comment `\(phrase)` in")
        }
        let palette = Self.slice(view, from: "struct PitchEditorToolPalette: View",
                                 to: "enum PitchEditorZoomCommand")
        #expect(palette.contains("var body: some View"), "the palette slice is empty or wrong")
    }

    /// Planted and seen red: the shortfall caption moved into a `.help(...)`
    /// tooltip — invisible to `view.capture`, so a captured gate could not
    /// tell a correct caption from a missing one.
    @Test("⭐ the palette DRAWS the line caption — amber for a shortfall, progress ink for a wait — never a tooltip")
    func theCaptionIsDrawnNotHung() {
        let view = Self.code(Self.viewPath)
        let palette = Self.slice(view, from: "struct PitchEditorToolPalette: View",
                                 to: "enum PitchEditorZoomCommand")
        #expect(palette.contains("var lineCaption: PitchEditorLineCaption?"))
        #expect(palette.contains("case .shortfall:"))
        #expect(palette.contains("PanelRefusalLine(message: lineCaption.text)"),
                "a shortfall must be drawn through `PanelRefusalLine`")
        #expect(palette.contains("case .progress:"))
        #expect(palette.contains("Text(lineCaption.text)"), "a wait must be drawn as text")
        #expect(!palette.contains(".help(lineCaption"), "the caption is hung on a tooltip")
        // The pane hands the palette the SAME value it reports to the spy.
        #expect(view.contains("let lineCaption = model.lineCaption"))
        #expect(view.contains("lineCaption: lineCaption,"))
        #expect(view.contains("let caption = model.lineCaption"))
        #expect(view.contains("chrome?.recordPlayedLine("))
    }

    @Test("⭐ the surface strokes the PLAYED line, the overlay the draft — the measurement is no longer drawn")
    func thePaneDrawsThePlayedLine() {
        let view = Self.code(Self.viewPath)
        #expect(view.contains("Self.drawPlayedLine(&context, lines: ctx.playedLine, estimate: ctx.lineIsEstimate)"))
        #expect(view.contains("PitchEditorSurface.drawPlayedLine(&context, lines: draftLine, estimate: estimate)"))
        #expect(view.contains("playedLine: playedSegments,"))
        #expect(view.contains("lineIsEstimate: model.playedLine.basis != .render,"))
        #expect(view.contains("unresolvedNoteIDs: model.unresolvedNoteIDs,"))
        #expect(view.contains("hiddenBlobID: model.drag?.segmentID,"))
        #expect(view.contains("draftLine: model.draftLineSegments,"))
        // ⛔ The old line — the measurement, left behind by a moved note.
        #expect(!view.contains("model.contourSegments"),
                "the pane draws the DETECTED contour again — the wobble would stay behind in the ghost")
    }

    /// Planted and seen red: ContentView handing the pane a STUB seam that
    /// answers `.unavailable` without asking the store. It compiles, draws,
    /// and quietly turns every line into an estimate — the plausible-looking
    /// wrong answer only this assertion catches. (Omitting the argument
    /// outright is a compile error, which needs no test.)
    @Test("⭐ ContentView binds THE seam, and the pane re-asks it only when the file or detector changes")
    func contentViewBindsTheSeam() {
        let content = Self.code(Self.contentPath)
        #expect(content.contains("renderContour: { id in await store.renderPitchContour(clipId: id) }"),
                "the pane is not given the store's render-contour door")
        let view = Self.code(Self.viewPath)
        #expect(view.contains(".task(id: renderContourKey)"))
        #expect(view.contains("await model.loadRenderContour(using: renderContour)"))
        #expect(view.contains("onChange(of: clip.pitchShiftSemitones)"))
        #expect(view.contains("model.setClipPitchShiftSemitones(semitones)"))
        let key = Self.slice(view, from: "private struct RenderContourKey", to: "init(clip: Clip")
        #expect(key.contains("let url: URL?") && key.contains("let analysisVersion: Int"))
        #expect(!key.contains("pitchEdits:") && !key.contains("segments"),
                "the fetch key must not include the edits — an edit would re-run the analysis")
    }
}
