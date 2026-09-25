@testable import DAWCore
import Foundation
import Testing

// I1-F1: HEAR THE NOTE WHILE EDITING IT, THROUGH SPAN RENDERS. THE POLICY.
//
// `ClipNoteAuditionController` and `ProjectStore`'s doors against a spy engine
// that implements BOTH audition forms: the playback-file form (I1) and the
// span-render form with its completion (I1-F1). Nothing here renders audio;
// `AuditionEngineTests`' `clipSpanRender…` tests and `ClipSpanRenderTests` do.
//
// Nonisolated suite on purpose: MainActorOccupancy Leg C counts `@MainActor`
// SUITES and sits at its cap, so each test is `@MainActor` on its own (the
// controller and the store are main-actor types).
//
// I1's own tests in `AuditionControllerTests` keep I1's contract: their spy
// implements only the playback-file form, so the span-render requirement
// answers its protocol default, `.unsupported`, and the controller keeps I1's
// behaviour (a press answers not-ready, a release waits for the render). The
// tests below carry the new contract.

@Suite("I1-F1 span-render audition policy: press, release, drag, and the draft the commit would store")
struct ClipNoteSpanAuditionTests {

    private func span(start: Double = 1.0, end: Double = 1.4,
                      clipID: UUID = UUID()) -> ClipNoteAuditionSpan {
        ClipNoteAuditionSpan(trackID: UUID(), clipID: clipID, startSeconds: start, endSeconds: end)
    }

    /// One note's id for every draft of a test, so two drafts of the same
    /// offset compare equal.
    private let draftNoteID = UUID()

    private func draft(_ cents: Double) -> PitchEditSet {
        PitchEditSet(segments: [NoteSegment(id: draftNoteID, startSeconds: 1.0, endSeconds: 1.4,
                                            detectedHz: 220, detectedConfidence: 0.9,
                                            pitchOffsetCents: cents)])
    }

    // MARK: Press and release

    @MainActor
    @Test("I1-F1 press: a render in flight plays a span render of the STORED edits instead of nothing; a ready render still plays the render")
    func clipNoteSpanPressRendersTheStoredSpan() {
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        let pressed = span()

        engine.fileAnswers = [.inaudibleNotReady]
        let status = controller.press(pressed, enabled: true, transportRunning: false, engine: engine)
        #expect(status == .spanRender(.sounded))
        #expect(engine.calls == [.init(pressed, nil), .init(pressed, .storedSpanRender)])
        #expect(!controller.isWaitingForRender, "a press must never turn into a delayed play")
        controller.renderDidComplete(clipID: pressed.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2)
        engine.finish(0, .played(seconds: 0.4))
        #expect(controller.lastSpanDelivery == .played(seconds: 0.4))

        // Control: a render already on disk plays from the file; no span render.
        engine.fileAnswers = [.sounded]
        #expect(controller.press(pressed, enabled: true, transportRunning: false, engine: engine)
            == .attempted(.sounded))
        #expect(engine.calls.count == 3)
        #expect(engine.calls.last == .init(pressed, nil))
    }

    @MainActor
    @Test("I1-F1 release: a sound-changing commit plays the COMMITTED span at once and never waits for the whole-file render; a split still plays nothing")
    func clipNoteSpanReleasePlaysTheCommittedSpanAtOnce() {
        for edit in [ClipNoteEdit.pitch, .level, .clear] {
            let controller = ClipNoteAuditionController()
            let engine = SpanRenderSpyEngine()
            engine.fileAnswers = [.inaudibleNotReady]
            let released = span()

            let status = controller.commitDidChange(edit, span: released, enabled: true,
                                                    transportRunning: false, engine: engine)
            #expect(status == .spanRender(.sounded), "\(edit)")
            #expect(!controller.isWaitingForRender, "\(edit) waited for the whole-file render")
            #expect(engine.calls == [.init(released, nil), .init(released, .storedSpanRender)])
            // ONCE: the whole-file render landing later plays nothing more.
            controller.renderDidComplete(clipID: released.clipID, transportRunning: false,
                                         engine: engine)
            #expect(engine.calls.count == 2, "\(edit) played twice")
        }
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        #expect(controller.commitDidChange(.split, span: span(), enabled: true,
                                           transportRunning: false, engine: engine) == .unchanged)
        #expect(engine.calls.isEmpty)
    }

    @MainActor
    @Test("I1-F1 an engine without span renders keeps I1: the press answers not-ready, the release waits for THAT clip's render and plays it once")
    func clipNoteSpanUnsupportedEngineKeepsI1() {
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        engine.supportsSpanRender = false
        engine.fileAnswers = [.inaudibleNotReady]
        let s = span()

        #expect(controller.press(s, enabled: true, transportRunning: false, engine: engine)
            == .attempted(.inaudibleNotReady))
        #expect(controller.commitDidChange(.pitch, span: s, enabled: true, transportRunning: false,
                                           engine: engine) == .waitingForRender)
        #expect(controller.isWaitingForRender)
        engine.fileAnswers = [.sounded]
        controller.renderDidComplete(clipID: s.clipID, transportRunning: false, engine: engine)
        #expect(!controller.isWaitingForRender)
        #expect(controller.lastRenderCompleteOutcome == .sounded)
        #expect(engine.calls.filter { $0.source != nil }.isEmpty,
                "an engine without span renders was asked for one and answered")
        #expect(engine.spanRequestsRefused == 2, "the controller never tried the span render")
    }

    // MARK: Drag

    @MainActor
    @Test("I1-F1 drag, snapped: every step renders the DRAFT, the latest wins, and a superseded render's report changes nothing")
    func clipNoteSpanSnappedDragLatestWins() {
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        let s = span()

        for (k, cents) in [100.0, 200, 300].enumerated() {
            let status = controller.dragDidStep(s, draft: draft(cents), snapped: true, enabled: true,
                                                transportRunning: false, engine: engine)
            #expect(status == .spanRender(.sounded), "step \(k)")
        }
        #expect(engine.calls == [.init(s, .draftSpanRender(draft(100))),
                                 .init(s, .draftSpanRender(draft(200))),
                                 .init(s, .draftSpanRender(draft(300)))])
        #expect(engine.calls.allSatisfy { $0.source != .storedSpanRender },
                "a drag step rendered the STORED set, not the draft")
        // The engine drops the superseded renders; their reports change nothing.
        engine.finish(0, .dropped)
        engine.finish(1, .played(seconds: 0.4))
        #expect(controller.lastSpanDelivery == nil, "a superseded render's report was taken as the latest")
        engine.finish(2, .played(seconds: 0.4))
        #expect(controller.lastSpanDelivery == .played(seconds: 0.4))
        #expect(engine.calls.count == 3)
    }

    @MainActor
    @Test("I1-F1 drag, free (⌥): one render in flight plus the NEWEST step waiting; an older waiting step never renders; a snapped step jumps the queue")
    func clipNoteSpanFreeDragKeepsOneInFlightPlusNewest() {
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        let s = span()

        #expect(controller.dragDidStep(s, draft: draft(10), snapped: false, enabled: true,
                                       transportRunning: false, engine: engine) == .spanRender(.sounded))
        #expect(controller.dragDidStep(s, draft: draft(20), snapped: false, enabled: true,
                                       transportRunning: false, engine: engine) == .queued)
        #expect(controller.dragDidStep(s, draft: draft(30), snapped: false, enabled: true,
                                       transportRunning: false, engine: engine) == .queued)
        #expect(engine.calls.count == 1, "a free step rendered while one was in flight")
        #expect(controller.hasQueuedDraft)

        // The render in flight ends: the NEWEST waiting step renders, not 20.
        engine.finish(0, .played(seconds: 0.4))
        #expect(engine.calls.count == 2)
        #expect(engine.calls.last == .init(s, .draftSpanRender(draft(30))))
        #expect(!controller.hasQueuedDraft)
        engine.finish(1, .played(seconds: 0.4))
        #expect(engine.calls.count == 2, "a render started with nothing waiting")

        // A snapped step never waits, and supersedes a waiting free one.
        #expect(controller.dragDidStep(s, draft: draft(40), snapped: false, enabled: true,
                                       transportRunning: false, engine: engine) == .spanRender(.sounded))
        #expect(controller.dragDidStep(s, draft: draft(50), snapped: false, enabled: true,
                                       transportRunning: false, engine: engine) == .queued)
        #expect(controller.dragDidStep(s, draft: draft(100), snapped: true, enabled: true,
                                       transportRunning: false, engine: engine) == .spanRender(.sounded))
        #expect(!controller.hasQueuedDraft)
        #expect(engine.calls.last == .init(s, .draftSpanRender(draft(100))))
        engine.finish(2, .dropped)
        #expect(engine.calls.count == 4, "the superseded free step's report released the queue")
    }

    @MainActor
    @Test("I1-F1 drag: a transport start, a stop and the switch drop the waiting step and forget the render in flight; a rolling transport refuses a step")
    func clipNoteSpanDragStopsAndRefusals() {
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        let s = span()

        controller.dragDidStep(s, draft: draft(10), snapped: false, enabled: true,
                               transportRunning: false, engine: engine)
        controller.dragDidStep(s, draft: draft(20), snapped: false, enabled: true,
                               transportRunning: false, engine: engine)
        controller.transportDidStart(engine: engine)
        #expect(engine.stopCount == 1)
        #expect(!controller.hasQueuedDraft)
        engine.finish(0, .dropped)
        #expect(engine.calls.count == 1, "a step waiting before the transport started played after it")

        controller.dragDidStep(s, draft: draft(30), snapped: false, enabled: true,
                               transportRunning: false, engine: engine)
        controller.dragDidStep(s, draft: draft(40), snapped: false, enabled: true,
                               transportRunning: false, engine: engine)
        controller.stop(engine: engine)
        #expect(engine.stopCount == 2)
        engine.finish(1, .played(seconds: 0.4))
        #expect(engine.calls.count == 2, "a step waiting before a stop played after it")

        #expect(controller.dragDidStep(s, draft: draft(50), snapped: true, enabled: true,
                                       transportRunning: true, engine: engine)
            == .refusedTransportRunning)
        #expect(controller.dragDidStep(s, draft: draft(50), snapped: true, enabled: false,
                                       transportRunning: false, engine: engine) == .disabled)
        #expect(controller.dragDidStep(s, draft: draft(50), snapped: true, enabled: true,
                                       transportRunning: false, engine: nil)
            == .attempted(.unsupported))
        #expect(engine.calls.count == 2)
    }

    // MARK: The store's draft door

    /// An audio clip with three stored notes, bound to a span-render spy.
    @MainActor
    private func draftStore() -> (ProjectStore, SpanRenderSpyEngine, Clip, [NoteSegment]) {
        let notes = [
            NoteSegment(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 2.0, endSeconds: 2.6, detectedHz: 247, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 9.0, endSeconds: 9.5, detectedHz: 196, detectedConfidence: 0.9),
        ]
        let clip = Clip(name: "Vox", startBeat: 0, lengthBeats: 32,
                        audioFileURL: URL(fileURLWithPath: "/nonexistent/i1f1-vox.wav"),
                        pitchEdits: PitchEditSet(segments: notes))
        let store = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [clip])])
        let engine = SpanRenderSpyEngine()
        store.engine = engine
        return (store, engine, clip, notes)
    }

    @MainActor
    @Test("I1-F1 store: the draft the engine renders IS the set the commit then stores (99999 c → 2400, NaN → 0, a repeated note folds), and the preview writes nothing")
    func clipNoteSpanStoreDraftAgreesWithTheCommit() throws {
        let cases: [[(Int, Double)]] = [
            [(0, 150)],
            [(0, 99_999)],
            [(0, -.infinity), (1, .nan)],
            [(1, -300), (0, 250), (1, -300)],
        ]
        for named in cases {
            let (store, engine, clip, notes) = draftStore()
            let offsets = named.map { NotePitchOffset(segmentId: notes[$0.0].id, offsetCents: $0.1) }
            let before = store.tracks[0].clips[0].pitchEdits
            let undoBefore = store.canUndo

            let result = try store.previewClipNotePitchDraft(clipId: clip.id, offsets: offsets,
                                                            snapped: true, enabled: true)
            #expect(result.outcome == .sounded && result.source == .spanRender)
            #expect(store.tracks[0].clips[0].pitchEdits == before, "the preview wrote the table")
            #expect(store.canUndo == undoBefore, "the preview journalled an edit")
            guard case .draftSpanRender(let rendered)? = engine.calls.last?.source else {
                Issue.record("no draft render for \(named)")
                continue
            }
            // The extension the preview uses, directly, agrees too.
            let table = try #require(before)
            #expect(try table.applyingNotePitchOffsets(offsets, clipId: clip.id) == rendered)

            _ = try store.setClipNotePitchOffsets(clipId: clip.id, offsets: offsets, undoKey: nil)
            #expect(store.tracks[0].clips[0].pitchEdits == rendered,
                    "the draft heard during the drag is not the set the release stored: \(named)")
        }
        // The pins, read back from what the commit stored.
        let (store, spy, clip, notes) = draftStore()
        _ = try store.previewClipNotePitchDraft(
            clipId: clip.id,
            offsets: [NotePitchOffset(segmentId: notes[0].id, offsetCents: 99_999),
                      NotePitchOffset(segmentId: notes[1].id, offsetCents: .nan)],
            snapped: true, enabled: true)
        guard case .draftSpanRender(let rendered)? = spy.calls.last?.source else {
            Issue.record("no draft render")
            return
        }
        #expect(rendered.segments[0].pitchOffsetCents == 2_400)
        #expect(rendered.segments[1].pitchOffsetCents == 0)
        #expect(rendered.segments[2].pitchOffsetCents == notes[2].pitchOffsetCents)

        // m23-ap I1 UI hooks, item 0 — the ONE-note commit too. A one-note drag
        // (C1) previews through the same draft rule and releases through
        // `setClipNotePitchOffset`, so that commit must store what was heard.
        for cents in [150.0, 99_999, -.infinity, .nan, -2_400.5] {
            let (store, engine, clip, notes) = draftStore()
            let offset = NotePitchOffset(segmentId: notes[1].id, offsetCents: cents)
            _ = try store.previewClipNotePitchDraft(clipId: clip.id, offsets: [offset],
                                                    snapped: true, enabled: true)
            guard case .draftSpanRender(let rendered)? = engine.calls.last?.source else {
                Issue.record("no one-note draft render for \(cents)")
                continue
            }
            _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: notes[1].id,
                                                 offsetCents: cents)
            #expect(store.tracks[0].clips[0].pitchEdits == rendered,
                    "a one-note drag heard \(cents) c as a different pitch than its release stored")
        }
    }

    @MainActor
    @Test("I1-F1 store: a draft preview refuses what the commit refuses, with the commit's words, and commits nothing")
    func clipNoteSpanStoreDraftRefusesLikeTheCommit() throws {
        let (store, engine, clip, notes) = draftStore()
        let a = notes[0].id
        let refusals: [(String, UUID, [NotePitchOffset])] = [
            ("empty", clip.id, []),
            ("unknown note", clip.id, [NotePitchOffset(segmentId: UUID(), offsetCents: 100)]),
            ("two pitches", clip.id, [NotePitchOffset(segmentId: a, offsetCents: 100),
                                      NotePitchOffset(segmentId: a, offsetCents: 200)]),
            ("unknown clip", UUID(), [NotePitchOffset(segmentId: a, offsetCents: 100)]),
        ]
        for (label, clipID, offsets) in refusals {
            var commitWords = ""
            var previewWords = ""
            do {
                _ = try store.setClipNotePitchOffsets(clipId: clipID, offsets: offsets, undoKey: nil)
            } catch { commitWords = String(describing: error) }
            do {
                _ = try store.previewClipNotePitchDraft(clipId: clipID, offsets: offsets,
                                                        snapped: true, enabled: true)
            } catch { previewWords = String(describing: error) }
            #expect(!commitWords.isEmpty, "\(label): the commit did not refuse, so this proves nothing")
            #expect(previewWords == commitWords, "\(label): preview \(previewWords) vs commit \(commitWords)")
        }
        // I1 UI hooks, item 0: the ONE-note commit refuses an unknown note in
        // the preview's words too (it now calls the same rule).
        let stray = NotePitchOffset(segmentId: UUID(), offsetCents: 100)
        var singleWords = ""
        var singlePreviewWords = ""
        do {
            _ = try store.setClipNotePitchOffset(clipId: clip.id, segmentId: stray.segmentId,
                                                 offsetCents: stray.offsetCents)
        } catch { singleWords = String(describing: error) }
        do {
            _ = try store.previewClipNotePitchDraft(clipId: clip.id, offsets: [stray],
                                                    snapped: true, enabled: true)
        } catch { singlePreviewWords = String(describing: error) }
        #expect(!singleWords.isEmpty, "the one-note commit accepted an unknown note")
        #expect(singlePreviewWords == singleWords)
        // A clip with no stored notes and no seed: refused by both; with a
        // seed, the preview renders the seed with the offsets applied.
        let bare = Clip(name: "Bare", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/nonexistent/i1f1-bare.wav"))
        let bareStore = ProjectStore(tracks: [Track(name: "Bare", kind: .audio, clips: [bare])])
        let bareEngine = SpanRenderSpyEngine()
        bareStore.engine = bareEngine
        let offset = [NotePitchOffset(segmentId: a, offsetCents: 100)]
        #expect(throws: (any Error).self) {
            try bareStore.previewClipNotePitchDraft(clipId: bare.id, offsets: offset,
                                                    snapped: true, enabled: true)
        }
        let seed = PitchEditSet(segments: notes)
        _ = try bareStore.previewClipNotePitchDraft(clipId: bare.id, offsets: offset, snapped: true,
                                                    enabled: true, seedIfAbsent: seed)
        #expect(bareStore.tracks[0].clips[0].pitchEdits == nil, "the seeded preview stored the seed")
        guard case .draftSpanRender(let seeded)? = bareEngine.calls.last?.source else {
            Issue.record("the seeded preview rendered nothing")
            return
        }
        #expect(seeded.segments[0].pitchOffsetCents == 100)
        #expect(engine.calls.isEmpty, "a refused preview reached the engine")
    }

    @MainActor
    @Test("I1-F1 store: a group draft spans every moving note ± context, capped at 6 s; a free step behind a render answers preview-queued")
    func clipNoteSpanStoreGroupSpanAndQueue() throws {
        let (store, engine, clip, notes) = draftStore()
        let group = try store.previewClipNotePitchDraft(
            clipId: clip.id,
            offsets: [NotePitchOffset(segmentId: notes[1].id, offsetCents: 100),
                      NotePitchOffset(segmentId: notes[0].id, offsetCents: 100)],
            snapped: true, enabled: true)
        #expect(abs(group.startSeconds - 0.44) < 1e-9)
        #expect(abs(group.endSeconds - 2.66) < 1e-9)
        let wide = try store.previewClipNotePitchDraft(
            clipId: clip.id,
            offsets: [NotePitchOffset(segmentId: notes[0].id, offsetCents: 100),
                      NotePitchOffset(segmentId: notes[2].id, offsetCents: 100)],
            snapped: true, enabled: true)
        #expect(abs(wide.startSeconds - 0.44) < 1e-9)
        #expect(abs(wide.endSeconds - (0.44 + ClipNoteAuditionPolicy.maxSpanSeconds)) < 1e-9)
        #expect(engine.calls.count == 2)

        // A free step while that render is still in flight waits.
        let free = try store.previewClipNotePitchDraft(
            clipId: clip.id, offsets: [NotePitchOffset(segmentId: notes[0].id, offsetCents: 130)],
            snapped: false, enabled: true)
        #expect(free.outcome == nil && free.reason == .previewQueued && free.source == .spanRender)
        #expect(engine.calls.count == 2)
        // Off, it plays nothing and says so.
        let off = try store.previewClipNotePitchDraft(
            clipId: clip.id, offsets: [NotePitchOffset(segmentId: notes[0].id, offsetCents: 140)],
            snapped: true, enabled: false)
        #expect(off.reason == .auditionOff)
        #expect(engine.calls.count == 2)
    }

    // MARK: H2: panic and project boundaries

    @MainActor
    @Test("I1 H2: panic, a new project and opening a project each drop a release still waiting for its render")
    func clipNoteSpanWaitDiesWithPanicAndProjectBoundaries() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("i1f1-h2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let other = ProjectStore()
        _ = other.addTrack(name: "Other", kind: .bus)
        let otherPath = dir.appendingPathComponent("Other").path
        try other.saveProject(to: otherPath)

        for boundary in ["panic", "newProject", "openProject", "control: none"] {
            let (store, engine, clip, notes) = draftStore()
            // An engine WITHOUT span renders, so the release waits (I1's path).
            engine.supportsSpanRender = false
            engine.fileAnswers = [.inaudibleNotReady, .sounded]
            let result = try store.auditionClipNotesAfterEdit(.pitch, clipId: clip.id,
                                                              segmentIds: [notes[0].id],
                                                              enabled: true)
            #expect(result.reason == .waitingForRender, "\(boundary)")
            let callsBefore = engine.calls.count
            switch boundary {
            case "panic": _ = store.panic()
            case "newProject": try store.newProject(discardChanges: true)
            case "openProject": _ = try store.openProject(at: otherPath, discardChanges: true)
            default: break
            }
            engine.fireRenderComplete(clip.id)
            if boundary == "control: none" {
                #expect(engine.calls.count == callsBefore + 1,
                        "the control did not play, so the three rows above prove nothing")
            } else {
                #expect(engine.calls.count == callsBefore,
                        "a release waiting before \(boundary) played after it")
            }
        }
    }

    // MARK: m23-ap I1 UI hooks — NH-D, honest waiting, the press seed, Stop

    @MainActor
    @Test("I1 UI NH-D: an ENGINE-side drop of the render in flight kills the free-drag step waiting behind it — 0 further plays; a played report still releases it")
    func clipNoteSpanEngineSideDropNeverPlaysTheQueue() {
        let s = span()
        // Control first: the step waiting behind a render that PLAYED renders,
        // so the drop below is measured against a queue that can release.
        let control = ClipNoteAuditionController()
        let controlEngine = SpanRenderSpyEngine()
        control.dragDidStep(s, draft: draft(10), snapped: false, enabled: true,
                            transportRunning: false, engine: controlEngine)
        #expect(control.dragDidStep(s, draft: draft(20), snapped: false, enabled: true,
                                    transportRunning: false, engine: controlEngine) == .queued)
        controlEngine.finish(0, .played(seconds: 0.4))
        #expect(controlEngine.calls.count == 2,
                "the control did not release the queue, so the drop below proves nothing")

        // The ENGINE drops the render in flight on its own — a graph rebuild, a
        // recovery after a device change, shutdown. Nothing went through this
        // controller's stop (the spy's stop count stays 0).
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        controller.dragDidStep(s, draft: draft(10), snapped: false, enabled: true,
                               transportRunning: false, engine: engine)
        #expect(controller.dragDidStep(s, draft: draft(20), snapped: false, enabled: true,
                                       transportRunning: false, engine: engine) == .queued)
        #expect(controller.hasQueuedDraft)
        engine.finish(0, .dropped)
        #expect(engine.calls.count == 1,
                "an engine-side drop released the queued free-drag step: it played after a rebuild or a device change")
        #expect(!controller.hasQueuedDraft)
        #expect(controller.lastSpanDelivery == .dropped)
        #expect(engine.stopCount == 0, "this row is the ENGINE's drop; the controller stopped nothing")
        // The drag is not wedged: the next step renders at once.
        #expect(controller.dragDidStep(s, draft: draft(30), snapped: false, enabled: true,
                                       transportRunning: false, engine: engine) == .spanRender(.sounded))
        #expect(engine.calls.count == 2)
    }

    @MainActor
    @Test("I1 UI honest waiting: a release that waits is numbered and ends as played, EXPIRED (counted; a late render plays nothing) or cancelled — never silently")
    func clipNoteSpanWaitEndsHonestly() {
        let controller = ClipNoteAuditionController()
        let engine = SpanRenderSpyEngine()
        engine.supportsSpanRender = false   // an engine without span renders waits (I1)
        var now = ContinuousClock.now
        controller.clock = { now }
        let s = span()

        // 1. PLAYED: the render lands inside the 8 s.
        engine.fileAnswers = [.inaudibleNotReady, .sounded]
        #expect(controller.commitDidChange(.pitch, span: s, enabled: true, transportRunning: false,
                                           engine: engine) == .waitingForRender)
        let first = controller.waitSerial
        #expect(controller.waitState(of: first) == .waiting)
        now = now.advanced(by: .seconds(1.7))
        controller.renderDidComplete(clipID: s.clipID, transportRunning: false, engine: engine)
        #expect(controller.waitState(of: first) == .played)
        #expect(engine.calls.count == 2)

        // 2. EXPIRED with no render at all: noticed on read, counted, dropped.
        engine.fileAnswers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: s, enabled: true, transportRunning: false,
                                   engine: engine)
        let second = controller.waitSerial
        #expect(second == first &+ 1)
        #expect(controller.waitState(of: first) == .cancelled, "an older wait's serial reads cancelled")
        now = now.advanced(by: .seconds(7.9))
        #expect(controller.waitState(of: second) == .waiting, "control: still inside the 8 s")
        now = now.advanced(by: .seconds(0.2))
        #expect(controller.waitState(of: second) == .expired)
        #expect(controller.counts.droppedWaits == 1)
        #expect(controller.pending == nil)
        controller.renderDidComplete(clipID: s.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 3, "a render landing after the expiry played the dropped edit")
        #expect(controller.waitState(of: second) == .expired, "the end is kept for a late reader")

        // 3. EXPIRED, noticed by the late render itself — the 5-minute-take case
        // (the whole-file render lands at about 13 s), which used to be silent.
        engine.fileAnswers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: s, enabled: true, transportRunning: false,
                                   engine: engine)
        let third = controller.waitSerial
        now = now.advanced(by: .seconds(13))
        controller.renderDidComplete(clipID: s.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 4, "the 13 s render played an edit whose wait had expired")
        #expect(controller.waitState(of: third) == .expired)
        #expect(controller.counts.droppedWaits == 2)

        // 4. CANCELLED: a press replaces the wait — replaced, not dropped.
        engine.fileAnswers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: s, enabled: true, transportRunning: false,
                                   engine: engine)
        let fourth = controller.waitSerial
        controller.press(s, enabled: true, transportRunning: false, engine: engine)
        #expect(controller.waitState(of: fourth) == .cancelled)
        #expect(controller.counts.droppedWaits == 2, "a replaced wait was counted as a dropped one")
    }

    @MainActor
    @Test("I1 UI press: an UNTOUCHED clip is heard through the editor's seed (never stored), the stored table wins over a seed, and the switch off reaches nothing")
    func clipNoteSpanPressSeedAndSwitch() throws {
        let notes = [
            NoteSegment(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220, detectedConfidence: 0.9),
            NoteSegment(startSeconds: 2.0, endSeconds: 2.6, detectedHz: 247, detectedConfidence: 0.9),
        ]
        let bare = Clip(name: "Bare", startBeat: 0, lengthBeats: 32,
                        audioFileURL: URL(fileURLWithPath: "/nonexistent/i1ui-bare.wav"))
        let store = ProjectStore(tracks: [Track(name: "Vox", kind: .audio, clips: [bare])])
        let engine = SpanRenderSpyEngine()
        store.engine = engine
        // Control: without the seed the editor's first click on an untouched
        // take is refused ("no notes to hear yet") — the defect the seed closes.
        #expect(throws: (any Error).self) {
            try store.auditionClipNotes(clipId: bare.id, segmentIds: [notes[0].id])
        }
        #expect(engine.calls.isEmpty)
        let seed = PitchEditSet(segments: notes)
        let heard = try store.auditionClipNotes(clipId: bare.id, segmentIds: [notes[0].id],
                                                seedIfAbsent: seed)
        #expect(heard.isAudible)
        #expect(abs(heard.startSeconds - 0.44) < 1e-9 && abs(heard.endSeconds - 1.06) < 1e-9)
        #expect(engine.calls.count == 1)
        #expect(store.tracks[0].clips[0].pitchEdits == nil, "the press stored the seed")
        // The switch off: `audition-off`, and nothing reaches the engine.
        let off = try store.auditionClipNotes(clipId: bare.id, segmentIds: [notes[0].id],
                                              enabled: false, seedIfAbsent: seed)
        #expect(off.reason == .auditionOff && off.outcome == nil)
        #expect(engine.calls.count == 1, "the switch was off and the press still reached the engine")
        // The STORED table wins: with one stored, a seed-only note is unknown…
        let (stored, storedEngine, clip, storedNotes) = draftStore()
        let otherSeed = PitchEditSet(segments: [
            NoteSegment(startSeconds: 5, endSeconds: 5.5, detectedHz: 330, detectedConfidence: 0.9),
        ])
        #expect(throws: (any Error).self) {
            try stored.auditionClipNotes(clipId: clip.id, segmentIds: [otherSeed.segments[0].id],
                                         seedIfAbsent: otherSeed)
        }
        // …and a stored note plays from the stored bounds.
        let fromStore = try stored.auditionClipNotes(clipId: clip.id, segmentIds: [storedNotes[1].id],
                                                     seedIfAbsent: otherSeed)
        #expect(fromStore.isAudible && abs(fromStore.startSeconds - 1.94) < 1e-9)
        #expect(storedEngine.calls.count == 1)
    }

    @MainActor
    @Test("I1 UI H5: the transport's Stop stops a note audition EXACTLY once, even with the transport already stopped — the only time one can sound")
    func clipNoteSpanTransportStopIsAStopDoor() throws {
        let (store, engine, clip, notes) = draftStore()
        #expect(!store.transport.isPlaying && !store.transport.isRecording)
        // A free drag with a step waiting behind the render in flight.
        _ = try store.previewClipNotePitchDraft(
            clipId: clip.id, offsets: [NotePitchOffset(segmentId: notes[0].id, offsetCents: 10)],
            snapped: false, enabled: true)
        _ = try store.previewClipNotePitchDraft(
            clipId: clip.id, offsets: [NotePitchOffset(segmentId: notes[0].id, offsetCents: 20)],
            snapped: false, enabled: true)
        #expect(store.clipNoteAudition.hasQueuedDraft)
        #expect(engine.stopCount == 0, "positive control: nothing has stopped the voice yet")
        store.stop()
        #expect(engine.stopCount == 1,
                "Stop, with the transport stopped, did not stop the note audition exactly once")
        #expect(store.clipNoteAudition.counts.stops == 1)
        #expect(!store.clipNoteAudition.hasQueuedDraft)
        engine.finish(0, .played(seconds: 0.4))
        #expect(engine.calls.count == 1, "a step waiting before Stop played after it")

        // A release waiting for its render, through the store: numbered,
        // readable, and cancelled by Stop.
        engine.supportsSpanRender = false
        engine.fileAnswers = [.inaudibleNotReady]
        let waiting = try store.auditionClipNotesAfterEdit(.pitch, clipId: clip.id,
                                                           segmentIds: [notes[1].id], enabled: true)
        #expect(waiting.reason == .waitingForRender)
        let serial = store.clipNoteAuditionWaitSerial
        #expect(store.clipNoteAuditionWaitState(serial: serial) == .waiting)
        store.stop()
        #expect(engine.stopCount == 2)
        #expect(store.clipNoteAuditionWaitState(serial: serial) == .cancelled)
    }

    @MainActor
    @Test("I1 UI debug knob: with span renders disabled for staging, the controller behaves as on an engine without them — the engine is never asked for one, and a release waits")
    func clipNoteSpanStagingKnobReachesTheWaitPath() {
        let s = span()
        // Control: the knob off, a span-render engine renders the committed span.
        let control = ClipNoteAuditionController()
        let controlEngine = SpanRenderSpyEngine()
        controlEngine.fileAnswers = [.inaudibleNotReady]
        #expect(control.commitDidChange(.pitch, span: s, enabled: true, transportRunning: false,
                                        engine: controlEngine) == .spanRender(.sounded))

        let controller = ClipNoteAuditionController()
        controller.spanRendersDisabledForStaging = true
        let engine = SpanRenderSpyEngine()
        engine.fileAnswers = [.inaudibleNotReady]
        #expect(controller.commitDidChange(.pitch, span: s, enabled: true, transportRunning: false,
                                           engine: engine) == .waitingForRender)
        #expect(engine.calls == [.init(s, nil)], "the knob still asked the engine for a span render")
        #expect(controller.counts.engineRequests == 1)
        #expect(controller.counts.releases == 1)
    }
}

/// A spy engine with BOTH audition forms. The playback-file form answers
/// `fileAnswers` in order (the last repeats); the span-render form answers
/// `spanAnswer` and keeps each completion so a test ends each render when and
/// how it chooses. `supportsSpanRender = false` makes the span form answer the
/// protocol default, `.unsupported`, and record nothing.
@MainActor
private final class SpanRenderSpyEngine: AudioEngineControlling {
    struct Call: Equatable {
        let trackID: UUID
        let clipID: UUID
        let start: Double
        let end: Double
        /// nil: the playback-file (four-argument) form.
        let source: ClipSpanAuditionSource?

        init(_ span: ClipNoteAuditionSpan, _ source: ClipSpanAuditionSource?) {
            trackID = span.trackID
            clipID = span.clipID
            start = span.startSeconds
            end = span.endSeconds
            self.source = source
        }

        init(trackID: UUID, clipID: UUID, start: Double, end: Double,
             source: ClipSpanAuditionSource?) {
            self.trackID = trackID
            self.clipID = clipID
            self.start = start
            self.end = end
            self.source = source
        }
    }

    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    private(set) var calls: [Call] = []
    private(set) var stopCount = 0
    private(set) var spanRequestsRefused = 0
    var fileAnswers: [AuditionOutcome] = [.sounded]
    var spanAnswer: AuditionOutcome = .sounded
    var supportsSpanRender = true
    /// One per ACCEPTED span render, in request order.
    private var completions: [(@MainActor @Sendable (ClipSpanAuditionDelivery) -> Void)?] = []
    private var renderCompleteHandler: ((UUID) -> Void)?

    func auditionClipSpan(trackID: UUID, clipID: UUID, startSourceSeconds: Double,
                          endSourceSeconds: Double) -> AuditionOutcome {
        calls.append(Call(trackID: trackID, clipID: clipID, start: startSourceSeconds,
                          end: endSourceSeconds, source: nil))
        return fileAnswers.count > 1 ? fileAnswers.removeFirst() : (fileAnswers.first ?? .sounded)
    }

    func auditionClipSpan(trackID: UUID, clipID: UUID, startSourceSeconds: Double,
                          endSourceSeconds: Double, source: ClipSpanAuditionSource,
                          completion: (@MainActor @Sendable (ClipSpanAuditionDelivery) -> Void)?)
        -> AuditionOutcome {
        guard supportsSpanRender else {
            spanRequestsRefused += 1
            return .unsupported
        }
        calls.append(Call(trackID: trackID, clipID: clipID, start: startSourceSeconds,
                          end: endSourceSeconds, source: source))
        if spanAnswer == .sounded { completions.append(completion) }
        return spanAnswer
    }

    /// Ends the `index`-th accepted span render (request order) with `delivery`.
    func finish(_ index: Int, _ delivery: ClipSpanAuditionDelivery) {
        guard completions.indices.contains(index) else {
            Issue.record("no accepted span render #\(index)")
            return
        }
        completions[index]?(delivery)
    }

    func stopClipSpanAudition() { stopCount += 1 }

    func setClipRenderCompleteHandler(_ handler: ((UUID) -> Void)?) {
        renderCompleteHandler = handler
    }

    func fireRenderComplete(_ clipID: UUID) { renderCompleteHandler?(clipID) }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
    var recordPermission: RecordPermission { .granted }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        throw ProjectError.engineUnavailable
    }
    func startTake(_ transport: TransportState, audioURL: URL?, captureMIDI: Bool,
                   completion: @escaping @MainActor (Result<TakeResult, Error>) -> Void) throws {}
    func stopRecording() {}
}
