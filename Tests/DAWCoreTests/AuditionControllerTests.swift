import Foundation
import Testing
@testable import DAWCore

/// m23-d note-audition POLICY, headless: set semantics, the diff, the voice
/// cap, the heartbeat, the one-shot release, the hold ceiling, and the refusals
/// (§13 C10–C12, C14's store half, C17's defeat-switch half). No engine, no
/// renderers, no audio — the render-side mechanism is gated separately by
/// `AuditionRenderTests`.
@MainActor
@Suite("Note audition policy (m23-d)")
struct AuditionControllerTests {
    private func instrumentStore() -> (ProjectStore, FakeEngine, UUID) {
        let store = ProjectStore()
        let engine = FakeEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument)
        engine.clearAuditionCalls()
        return (store, engine, track.id)
    }

    // MARK: - Set semantics and the diff

    @Test("set() is idempotent: an unchanged set still heartbeats, never re-triggers")
    func unchangedSetStillHeartbeats() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60, 64], velocity: 100, engine: engine)
        controller.set(trackID: track, pitches: [64, 60], velocity: 100, engine: engine)

        // Two calls out — the ENGINE diffs the pitches; the controller's job is
        // to keep asserting the set so the render watchdog sees liveness.
        #expect(engine.auditionCalls.count == 2)
        #expect(engine.auditionCalls.allSatisfy { $0.pitches == [60, 64] })
        #expect(controller.heldPitches == [60, 64])
        #expect(controller.isHolding)
    }

    @Test("an empty set stops, and stopping is idempotent")
    func emptySetStops() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let track = UUID()

        controller.set(trackID: track, pitches: [60], velocity: 100, engine: engine)
        controller.set(trackID: track, pitches: [], velocity: 0, engine: engine)
        controller.set(trackID: track, pitches: [], velocity: 0, engine: engine)
        controller.stop(engine: engine)

        #expect(!controller.isHolding)
        #expect(controller.heldPitches.isEmpty)
        // on, then exactly one release (the repeats hold nothing to release)
        #expect(engine.auditionCalls.count == 2)
        #expect(engine.auditionCalls[1].pitches.isEmpty)
    }

    @Test("switching tracks mid-hold silences the previous track FIRST")
    func trackSwitchSilencesThePrevious() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let first = UUID(), second = UUID()

        controller.set(trackID: first, pitches: [60], velocity: 100, engine: engine)
        controller.set(trackID: second, pitches: [67], velocity: 100, engine: engine)

        #expect(engine.auditionCalls.count == 3)
        #expect(engine.auditionCalls[1].trackID == first)
        #expect(engine.auditionCalls[1].pitches.isEmpty)   // released before the new one sounds
        #expect(engine.auditionCalls[2].trackID == second)
        #expect(controller.heldTrackID == second)
    }

    @Test("the voice cap keeps the LOWEST 8 pitches, de-duped and ascending")
    func voiceCapKeepsTheLowestEight() {
        #expect(AuditionController.clampPitches([72, 60, 64, 60]) == [60, 64, 72])
        let wide = Array(40...60)
        #expect(AuditionController.clampPitches(wide) == Array(40...47))
        #expect(AuditionController.clampPitches([-3, 200, 64]) == [64])
        #expect(AuditionController.clampPitches([]) == [])
    }

    @Test("a noRenderer outcome holds nothing (no heartbeat for voices that don't exist)")
    func noRendererDoesNotHold() {
        let controller = AuditionController()
        let engine = FakeEngine()
        engine.auditionOutcomeStub = .noRenderer

        let outcome = controller.set(trackID: UUID(), pitches: [60], velocity: 100, engine: engine)

        #expect(outcome == .noRenderer)
        #expect(!controller.isHolding)
    }

    @Test("an inaudible outcome still HOLDS — muted is not undelivered")
    func mutedStillHolds() {
        let controller = AuditionController()
        let engine = FakeEngine()
        engine.auditionOutcomeStub = .inaudibleMuted

        let outcome = controller.set(trackID: UUID(), pitches: [60], velocity: 100, engine: engine)

        #expect(outcome == .inaudibleMuted)
        #expect(controller.isHolding)   // the events WERE delivered; the strip is silent
    }

    // MARK: - C11: overlapping one-shots

    @Test("C11 two overlapping one-shots leave ZERO open voices")
    func overlappingOneShotsLeaveNothingOpen() async throws {
        let controller = AuditionController()
        let engine = FakeEngine()
        let track = UUID()

        let first = controller.oneShot(trackID: track, pitches: [60], velocity: 100,
                                       durationMs: 10, engine: engine)
        let second = controller.oneShot(trackID: track, pitches: [60], velocity: 100,
                                        durationMs: 60, engine: engine)
        #expect(first.durationMs == 10 && second.durationMs == 60)
        // The first release was cancelled — LAST CALL WINS.
        var waited = 0
        while controller.isHolding, waited < 100 {
            try await Task.sleep(for: .milliseconds(20))
            waited += 1
        }
        #expect(!controller.isHolding)
        #expect(engine.auditionCalls.last?.pitches.isEmpty == true)
        // Exactly ONE release went out, not two.
        #expect(engine.auditionCalls.filter { $0.pitches.isEmpty }.count == 1)
    }

    @Test("C10 the one-shot clamps durationMs into range instead of refusing")
    func oneShotClampsDuration() {
        let controller = AuditionController()
        let engine = FakeEngine()
        let low = controller.oneShot(trackID: UUID(), pitches: [60], velocity: 100,
                                     durationMs: 1, engine: engine)
        controller.stop(engine: engine)
        let high = controller.oneShot(trackID: UUID(), pitches: [60], velocity: 100,
                                      durationMs: 99_999, engine: engine)
        controller.stop(engine: engine)
        #expect(low.durationMs == AuditionController.durationRangeMs.lowerBound)
        #expect(high.durationMs == AuditionController.durationRangeMs.upperBound)
    }

    // MARK: - C12: the stuck-note sweep

    @Test("C12 the 30 s hold ceiling releases a lost mouse-up")
    func holdCeilingReleasesALostGesture() {
        let controller = AuditionController()
        let engine = FakeEngine()
        var now = ContinuousClock.now
        controller.clock = { now }

        controller.set(trackID: UUID(), pitches: [60], velocity: 100, engine: engine)
        #expect(controller.isHolding)
        // Inside the ceiling: the heartbeat re-asserts.
        now = now.advanced(by: .seconds(10))
        #expect(controller.heartbeatOnceForTesting(engine: engine))
        #expect(controller.isHolding)
        // Past it: the same iteration releases instead of re-asserting. Clock is
        // INJECTED — the gate never sleeps for 30 s.
        now = now.advanced(by: .seconds(25))
        #expect(!controller.heartbeatOnceForTesting(engine: engine))
        #expect(!controller.isHolding)
        #expect(engine.auditionCalls.last?.pitches.isEmpty == true)
    }

    @Test("C12 stopAll clears held state and reaches the engine's all-stop")
    func stopAllSweepsEverything() {
        let controller = AuditionController()
        let engine = FakeEngine()
        controller.set(trackID: UUID(), pitches: [60, 64], velocity: 100, engine: engine)
        controller.stopAll(engine: engine)
        #expect(!controller.isHolding)
        #expect(engine.stopAllAuditionCount == 1)
        controller.stopAll(engine: engine)      // idempotent
        #expect(engine.stopAllAuditionCount == 2)
        #expect(!controller.isHolding)
    }

    @Test("C12 a project boundary releases a held audition")
    func projectBoundaryReleasesAudition() throws {
        let (store, engine, track) = instrumentStore()
        try store.auditionPitches(trackID: track, pitches: [60])
        #expect(store.audition.isHolding)

        try store.newProject(discardChanges: true)

        #expect(!store.audition.isHolding)
        #expect(engine.stopAllAuditionCount >= 1)
    }

    // MARK: - Store-level refusals (C10 / C14's store half)

    @Test("C10 the store refuses an unknown track, a non-instrument track, and bad fields")
    func storeRefusalsTeach() throws {
        let (store, engine, track) = instrumentStore()
        let audioTrack = store.addTrack(name: "Vox", kind: .audio)
        engine.clearAuditionCalls()

        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: UUID(), pitches: [60])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: audioTrack.id, pitches: [60])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: Array(40...50))
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [128])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], velocity: 0)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], velocity: 200)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], durationMs: 9)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60], durationMs: 5_001)
        }
        // EVERY rejection landed before anything was pushed.
        #expect(engine.auditionCalls.isEmpty)
    }

    @Test("C14 a take starts SILENT: a held audition is released, and none can start")
    func auditionRefusedWhileRecording() throws {
        let store = ProjectStore()
        let engine = AuditionTakeEngine()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument).id
        try store.auditionPitches(trackID: track, pitches: [60])
        #expect(store.audition.isHolding)
        engine.clearAuditionCalls()
        try store.setTrackArm(id: track, armed: true)
        try store.record()
        #expect(store.transport.isRecording)

        // THE HALF A REFUSAL ALONE CANNOT COVER: the voice held when record
        // began. Refusing NEW auditions does nothing about it — the controller
        // heartbeat re-asserts a held voice every 500 ms straight through the
        // take, and the render watchdog would sustain it ~3 s even with the
        // heartbeat stopped. The capture ring can't see an audition, so it
        // would be heard and not recorded. `record()` releases it — through
        // stopAll, so a voice held on ANY track (not just the armed one) is
        // silenced, and the renderer-side flush rides along.
        #expect(engine.stopAllAuditionCount == 1)
        #expect(engine.auditionCalls.isEmpty)              // nothing NEW sounded
        #expect(!store.audition.isHolding)
        engine.clearAuditionCalls()

        #expect(throws: ProjectError.self) {
            try store.auditionNote(trackID: track, pitches: [60])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionPitches(trackID: track, pitches: [60])
        }
        #expect(engine.auditionCalls.isEmpty)   // nothing sounded during the take

        // Stopping is never refused, so a voice cannot get stuck BEHIND the
        // gate. Held straight through the controller here — the store's own
        // door is shut mid-take, which is the point — then released through the
        // store, proving the release path still reaches the engine.
        store.audition.set(trackID: track, pitches: [60], velocity: 100, engine: engine)
        engine.clearAuditionCalls()
        try store.auditionPitches(trackID: track, pitches: [])
        #expect(engine.auditionCalls.count == 1)
        #expect(engine.auditionCalls[0].pitches.isEmpty)
        #expect(!store.audition.isHolding)
    }

    @Test("the store's one-shot returns immediately and echoes what it sounded")
    func storeOneShotEchoesTheRequest() throws {
        // `store.engine` is WEAK — the engine must stay bound for the call.
        let (store, engine, track) = instrumentStore()
        #expect(engine.auditionCalls.isEmpty)
        let result = try store.auditionNote(trackID: track, pitches: [67, 60, 64],
                                            velocity: 90, durationMs: 250)
        #expect(result.trackID == track)
        #expect(result.pitches == [60, 64, 67])       // ascending, de-duped
        #expect(result.velocity == 90)
        #expect(result.durationMs == 250)
        // A FakeEngine has no renderers, but the protocol default is overridden
        // by the spy, so the store's answer is the spy's.
        #expect(result.outcome == .sounded)
        #expect(result.isAudible)
    }

    @Test("velocity clamps rather than throwing inside the controller")
    func controllerClampsVelocity() {
        let controller = AuditionController()
        let engine = FakeEngine()
        controller.set(trackID: UUID(), pitches: [60], velocity: 999, engine: engine)
        #expect(engine.auditionCalls[0].velocity == 127)
        controller.stop(engine: engine)
        controller.set(trackID: UUID(), pitches: [60], velocity: -5, engine: engine)
        #expect(engine.auditionCalls.last?.velocity == 1)
    }

    @Test("the heartbeat interval sits comfortably inside the render watchdog window")
    func heartbeatIntervalIsSafelyInsideTheWatchdog() {
        // Not a numeric contract between two authorities — the renderer's
        // frame count is THE authority. This pins that the derivation copy the
        // controller reasons from still leaves ≥ 4 heartbeats per window.
        let perWindow = AuditionController.watchdogSeconds
            / (Double(AuditionController.heartbeatMilliseconds) / 1_000)
        #expect(perWindow >= 4)
        #expect(AuditionController.maxHoldSeconds > AuditionController.watchdogSeconds)
    }

    // MARK: - I1: hear the note while editing it (clip-note audition policy)
    //
    // Design `2026-09-24-pitch-editor-interaction-batch.md` §4, decision (c).
    // These live in this EXISTING `@MainActor` suite on purpose: the controller
    // and the store are `@MainActor`, and a new suite would move the
    // MainActorOccupancy Leg C count (393 of 394).

    private func clipSpan(_ clip: UUID = UUID(), start: Double = 1.0,
                          end: Double = 1.5) -> ClipNoteAuditionSpan {
        ClipNoteAuditionSpan(trackID: UUID(), clipID: clip, startSeconds: start, endSeconds: end)
    }

    @Test("I1 press plays the notes as they sound NOW, once, and never waits")
    func clipNotePressPlaysNow() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        let span = clipSpan()

        let status = controller.press(span, enabled: true, transportRunning: false, engine: engine)

        #expect(status == .attempted(.sounded))
        #expect(engine.calls == [ClipSpanSpyEngine.Call(span)])
        #expect(!controller.isWaitingForRender)
        // A render in flight at press time plays nothing and waits for nothing:
        // silence is what playback plays there too.
        engine.answers = [.inaudibleNotReady]
        #expect(controller.press(span, enabled: true, transportRunning: false, engine: engine)
            == .attempted(.inaudibleNotReady))
        #expect(!controller.isWaitingForRender)
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2, "a press must never turn into a delayed play")
    }

    @Test("I1 a sound-changing commit waits, then plays ONCE when THAT clip's render completes")
    func clipNoteCommitPlaysOnceAfterMatchingRender() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        engine.answers = [.inaudibleNotReady, .sounded]
        let span = clipSpan()

        let status = controller.commitDidChange(.pitch, span: span, enabled: true,
                                                transportRunning: false, engine: engine)
        #expect(status == .waitingForRender)
        #expect(controller.isWaitingForRender)
        #expect(engine.calls.count == 1)   // the immediate attempt, answered not-ready

        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2)
        #expect(engine.calls.last == ClipSpanSpyEngine.Call(span))
        #expect(controller.lastRenderCompleteOutcome == .sounded)
        #expect(!controller.isWaitingForRender)

        // ONCE: a second render-complete for the same clip plays nothing.
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2)
    }

    @Test("I1 another clip's render does not trigger the waiting audition")
    func clipNoteOtherClipsRenderDoesNotTrigger() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        engine.answers = [.inaudibleNotReady, .sounded]
        let span = clipSpan()

        controller.commitDidChange(.level, span: span, enabled: true, transportRunning: false,
                                   engine: engine)
        controller.renderDidComplete(clipID: UUID(), transportRunning: false, engine: engine)
        #expect(engine.calls.count == 1, "a different clip's render played this clip's notes")
        #expect(controller.isWaitingForRender)
        #expect(controller.pending == span)

        // Control: the matching render still plays, so the refusal above was
        // about the clip, not a controller that never plays.
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2)
    }

    @Test("I1 a second commit cancels the first: the latest request wins")
    func clipNoteSecondCommitCancelsTheFirst() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        engine.answers = [.inaudibleNotReady, .inaudibleNotReady, .sounded]
        let first = clipSpan()
        let second = clipSpan(start: 2.0, end: 2.4)

        controller.commitDidChange(.pitch, span: first, enabled: true, transportRunning: false,
                                   engine: engine)
        controller.commitDidChange(.pitch, span: second, enabled: true, transportRunning: false,
                                   engine: engine)
        #expect(controller.pending == second)

        controller.renderDidComplete(clipID: first.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2, "the superseded commit still played")
        controller.renderDidComplete(clipID: second.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 3)
        #expect(engine.calls.last == ClipSpanSpyEngine.Call(second))

        // A press also supersedes a waiting commit.
        engine.answers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: first, enabled: true, transportRunning: false,
                                   engine: engine)
        controller.press(second, enabled: true, transportRunning: false, engine: engine)
        #expect(controller.pending == nil)
        let before = engine.calls.count
        controller.renderDidComplete(clipID: first.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == before)
    }

    @Test("I1 nothing plays while the transport runs or records, and a transport start stops the voice and drops the wait")
    func clipNoteTransportRefusesAndStops() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        let span = clipSpan()

        #expect(controller.press(span, enabled: true, transportRunning: true, engine: engine)
            == .refusedTransportRunning)
        #expect(controller.commitDidChange(.pitch, span: span, enabled: true,
                                           transportRunning: true, engine: engine)
            == .refusedTransportRunning)
        #expect(engine.calls.isEmpty)

        // Waiting, then the transport starts: the wait is dropped and the voice
        // is told to stop, so a render landing mid-playback plays nothing.
        engine.answers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: span, enabled: true, transportRunning: false,
                                   engine: engine)
        controller.transportDidStart(engine: engine)
        #expect(engine.stopCount == 1)
        #expect(!controller.isWaitingForRender)
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 1)

        // A render that lands while the transport runs drops the wait too.
        engine.answers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: span, enabled: true, transportRunning: false,
                                   engine: engine)
        controller.renderDidComplete(clipID: span.clipID, transportRunning: true, engine: engine)
        #expect(engine.calls.count == 2)
        #expect(controller.pending == nil)
    }

    @Test("I1 a wait longer than 8 s is dropped: a late render plays nothing")
    func clipNoteRenderWaitExpires() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        var now = ContinuousClock.now
        controller.clock = { now }
        let span = clipSpan()

        // Control first: a render at 7.9 s still plays.
        engine.answers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: span, enabled: true, transportRunning: false,
                                   engine: engine)
        now = now.advanced(by: .seconds(7.9))
        #expect(controller.isWaitingForRender)
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2)

        // Past 8 s: nothing plays, and the wait is gone.
        engine.answers = [.inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: span, enabled: true, transportRunning: false,
                                   engine: engine)
        now = now.advanced(by: .seconds(8.001))
        #expect(!controller.isWaitingForRender)
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 3, "a render landing after the 8 s wait still played")
        #expect(controller.pending == nil)
    }

    @Test("I1 a split triggers nothing and does not cancel an audition already waiting")
    func clipNoteSplitTriggersNothing() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        engine.answers = [.inaudibleNotReady, .sounded]
        let span = clipSpan()

        controller.commitDidChange(.pitch, span: span, enabled: true, transportRunning: false,
                                   engine: engine)
        #expect(controller.commitDidChange(.split, span: clipSpan(start: 3, end: 3.5),
                                           enabled: true, transportRunning: false,
                                           engine: engine) == .unchanged)
        #expect(engine.calls.count == 1, "a split reached the engine")
        #expect(engine.stopCount == 0)
        #expect(controller.pending == span, "a split cancelled the waiting audition")
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(engine.calls.count == 2)
    }

    @Test("I1 the audition switch is an INPUT: off, the editor's doors play nothing; a notReady answer after a render keeps waiting")
    func clipNoteSwitchIsAnInput() {
        let controller = ClipNoteAuditionController()
        let engine = ClipSpanSpyEngine()
        let span = clipSpan()

        #expect(controller.press(span, enabled: false, transportRunning: false, engine: engine)
            == .disabled)
        #expect(controller.commitDidChange(.clear, span: span, enabled: false,
                                           transportRunning: false, engine: engine) == .disabled)
        #expect(engine.calls.isEmpty)

        // A render for the clip that still resolves not-ready (it re-keyed again
        // in between) keeps the wait alive instead of consuming it.
        engine.answers = [.inaudibleNotReady, .inaudibleNotReady, .sounded]
        controller.commitDidChange(.pitch, span: span, enabled: true, transportRunning: false,
                                   engine: engine)
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(controller.isWaitingForRender)
        controller.renderDidComplete(clipID: span.clipID, transportRunning: false, engine: engine)
        #expect(!controller.isWaitingForRender)
        #expect(engine.calls.count == 3)
    }

    // MARK: I1 store doors

    /// An audio clip whose STORED table holds two detected notes, bound to a
    /// spy engine. The file is never opened by the store.
    private func noteClipStore() -> (ProjectStore, ClipSpanSpyEngine, Track, NoteSegment, NoteSegment) {
        let a = NoteSegment(startSeconds: 0.5, endSeconds: 1.0, detectedHz: 220,
                            detectedConfidence: 0.9)
        let b = NoteSegment(startSeconds: 2.0, endSeconds: 2.6, detectedHz: 247,
                            detectedConfidence: 0.9)
        let clip = Clip(name: "Vox", startBeat: 0, lengthBeats: 8,
                        audioFileURL: URL(fileURLWithPath: "/nonexistent/i1-vox.wav"),
                        pitchEdits: PitchEditSet(segments: [a, b]))
        let track = Track(name: "Vox", kind: .audio, clips: [clip])
        let store = ProjectStore(tracks: [track])
        let engine = ClipSpanSpyEngine()
        store.engine = engine
        return (store, engine, track, a, b)
    }

    @Test("I1 store: auditionClipNotes resolves the span from the STORED table and plays it through the engine")
    func clipNoteStorePressResolvesFromTheStoredTable() throws {
        let (store, engine, track, a, b) = noteClipStore()
        let clipID = try #require(track.clips.first?.id)

        let result = try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id])
        #expect(result.outcome == .sounded && result.isAudible && result.reason == nil)
        // Detected-only notes bend nothing: the clip plays its SOURCE.
        #expect(result.source == .source)
        #expect(abs(result.startSeconds - 0.44) < 1e-9)
        #expect(abs(result.endSeconds - 1.06) < 1e-9)
        let call = try #require(engine.calls.first)
        #expect(call.trackID == track.id && call.clipID == clipID)
        #expect(abs(call.start - 0.44) < 1e-9 && abs(call.end - 1.06) < 1e-9)

        // A group spans earliest start to latest end; a custom context is honoured.
        let group = try store.auditionClipNotes(clipId: clipID, segmentIds: [b.id, a.id],
                                                contextSeconds: 0.1)
        #expect(abs(group.startSeconds - 0.4) < 1e-9 && abs(group.endSeconds - 2.7) < 1e-9)

        // A tuned clip reads its RENDER.
        try store.setClipNotePitchOffset(clipId: clipID, segmentId: a.id, offsetCents: 200)
        #expect(try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id]).source == .render)
    }

    @Test("I1 store: the transport refuses with transport-running before the engine; play() stops the voice")
    func clipNoteStoreRefusesWhileTransportRuns() throws {
        let (store, engine, track, a, _) = noteClipStore()
        let clipID = try #require(track.clips.first?.id)

        store.play()
        #expect(engine.stopCount >= 1, "a transport start did not stop the clip-note voice")
        let result = try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id])
        #expect(result.reason == .transportRunning)
        #expect(result.outcome == nil && !result.isAudible)
        #expect(engine.calls.isEmpty)
        store.stop()

        // Control: stopped again, the same request plays.
        #expect(try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id]).isAudible)
        #expect(engine.calls.count == 1)

        // stopAllAudition (shutdown, project boundary) stops it too.
        let stopsBefore = engine.stopCount
        store.stopAllAudition()
        #expect(engine.stopCount > stopsBefore)
    }

    @Test("I1 store: caller mistakes throw and reach nothing — unknown clip, MIDI clip, no table, no ids, unknown id, bad context")
    func clipNoteStoreRefusalsTeach() throws {
        let (store, engine, track, a, _) = noteClipStore()
        let clipID = try #require(track.clips.first?.id)
        let bare = Clip(name: "Bare", startBeat: 8, lengthBeats: 4,
                        audioFileURL: URL(fileURLWithPath: "/nonexistent/bare.wav"))
        let midi = Clip(name: "Keys", startBeat: 0, lengthBeats: 4,
                        notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)])
        store.tracks[0].clips.append(bare)
        store.tracks.append(Track(name: "Keys", kind: .instrument, clips: [midi]))

        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: UUID(), segmentIds: [a.id])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: midi.id, segmentIds: [a.id])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: bare.id, segmentIds: [a.id])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: clipID, segmentIds: [])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: clipID, segmentIds: [UUID()])
        }
        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id], contextSeconds: -0.1)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id], contextSeconds: 2.5)
        }
        #expect(throws: ProjectError.self) {
            try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id], contextSeconds: .nan)
        }
        #expect(engine.calls.isEmpty, "a refused request reached the engine")
    }

    @Test("I1 store: after a commit the audition waits for THAT clip's render signal from the engine, then plays once")
    func clipNoteStoreCommitWaitsForTheEngineSignal() throws {
        let (store, engine, track, a, _) = noteClipStore()
        let clipID = try #require(track.clips.first?.id)
        #expect(engine.renderCompleteHandler != nil,
                "binding the engine did not install the render-complete sink")

        try store.setClipNotePitchOffset(clipId: clipID, segmentId: a.id, offsetCents: 200)
        engine.answers = [.inaudibleNotReady, .sounded]
        let result = try store.auditionClipNotesAfterEdit(.pitch, clipId: clipID,
                                                          segmentIds: [a.id], enabled: true)
        #expect(result.reason == .waitingForRender)
        #expect(result.outcome == .inaudibleNotReady)
        #expect(result.source == .render)
        #expect(engine.calls.count == 1)

        engine.fireRenderComplete(UUID())
        #expect(engine.calls.count == 1, "another clip's render played this clip's notes")
        engine.fireRenderComplete(clipID)
        #expect(engine.calls.count == 2)
        engine.fireRenderComplete(clipID)
        #expect(engine.calls.count == 2, "the edited notes played more than once")
    }

    @Test("I1 store: a clear is heard with 0.3 s of context, a split plays nothing, the switch off plays nothing")
    func clipNoteStoreClearContextSplitAndSwitch() throws {
        let (store, engine, track, a, _) = noteClipStore()
        let clipID = try #require(track.clips.first?.id)

        let cleared = try store.auditionClipNotesAfterEdit(.clear, clipId: clipID,
                                                           segmentIds: [a.id], enabled: true)
        #expect(abs(cleared.startSeconds - 0.2) < 1e-9 && abs(cleared.endSeconds - 1.3) < 1e-9)
        #expect(engine.calls.count == 1)

        let split = try store.auditionClipNotesAfterEdit(.split, clipId: clipID,
                                                         segmentIds: [a.id], enabled: true)
        #expect(split.reason == .unchanged && split.outcome == nil)
        #expect(engine.calls.count == 1)

        let off = try store.auditionClipNotesAfterEdit(.level, clipId: clipID,
                                                       segmentIds: [a.id], enabled: false)
        #expect(off.reason == .auditionOff && off.outcome == nil)
        #expect(engine.calls.count == 1)
        // The wire's press door ignores the switch by design: it has no switch.
        #expect(try store.auditionClipNotes(clipId: clipID, segmentIds: [a.id]).isAudible)
    }
}

/// I1 spy: records every clip-span audition and stop, answers from a script,
/// and exposes the render-complete sink the store installs, so a test can play
/// the engine's side of the handshake.
@MainActor
private final class ClipSpanSpyEngine: AudioEngineControlling {
    struct Call: Equatable {
        let trackID: UUID
        let clipID: UUID
        let start: Double
        let end: Double

        init(trackID: UUID, clipID: UUID, start: Double, end: Double) {
            self.trackID = trackID
            self.clipID = clipID
            self.start = start
            self.end = end
        }

        init(_ span: ClipNoteAuditionSpan) {
            self.init(trackID: span.trackID, clipID: span.clipID,
                      start: span.startSeconds, end: span.endSeconds)
        }
    }

    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    private(set) var calls: [Call] = []
    private(set) var stopCount = 0
    /// Answers in order; the last one repeats.
    var answers: [AuditionOutcome] = [.sounded]
    private(set) var renderCompleteHandler: ((UUID) -> Void)?

    func auditionClipSpan(trackID: UUID, clipID: UUID, startSourceSeconds: Double,
                          endSourceSeconds: Double) -> AuditionOutcome {
        calls.append(Call(trackID: trackID, clipID: clipID, start: startSourceSeconds,
                          end: endSourceSeconds))
        return answers.count > 1 ? answers.removeFirst() : (answers.first ?? .sounded)
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

/// Minimal conformer that ALSO accepts a MIDI take (the `BareEngine` shape) —
/// the shared `FakeEngine` uses the protocol's default `startTake`, which
/// refuses MIDI capture, and the refuse-while-recording gate needs a store that
/// actually reaches `transport.isRecording == true`.
@MainActor
private final class AuditionTakeEngine: AudioEngineControlling {
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    private(set) var auditionCalls: [(trackID: UUID, pitches: [UInt8], velocity: UInt8)] = []
    private(set) var stopAllAuditionCount = 0

    func clearAuditionCalls() {
        auditionCalls.removeAll()
        stopAllAuditionCount = 0
    }

    func setAuditionPitches(trackID: UUID, pitches: [UInt8], velocity: UInt8) -> AuditionOutcome {
        auditionCalls.append((trackID, pitches, velocity))
        return .sounded
    }

    func stopAllAudition() { stopAllAuditionCount += 1 }

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
