import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWAppKit

/// Headless tests for the M6 (v-b-2) clip vocal-fix state machine: the submit →
/// poll → import lifecycle, the failed-poll TOLERANCE rule (a transient poll
/// error marks a card stale but never kills it; only a returned `.failed` fails
/// it), the import error mapping (`clipFixStale` → amber stale card,
/// `clipFixJobNotFound` → red failed card, anything else → retryable), the
/// submit busy-guard, and context threading. Drives `ClipFixModel` against
/// scripted fakes — no window, no engine, no network (the `SketchpadModel`
/// precedent).
@MainActor
@Suite struct ClipFixModelTests {

    // MARK: - Fakes

    /// Records the EXACT `ClipFixSubmitRequest` each submit received and hands
    /// back a scripted `ClipFixSubmission` (or throws `error`). MainActor because
    /// the model's submitter closure is.
    @MainActor final class SubmitRecorder {
        var received: [ClipFixSubmitRequest] = []
        var nextJobID = "fix-1"
        var error: Error?

        func submit(_ request: ClipFixSubmitRequest) async throws -> ClipFixSubmission {
            received.append(request)
            if let error { throw error }
            // Echo the region back with a ±4-beat context window (the store's
            // placement echo shape).
            return ClipFixSubmission(
                jobID: nextJobID, state: "queued", queuePosition: 1,
                windowStartBeat: request.startBeat - 4, windowEndBeat: request.endBeat + 4,
                regionStartBeat: request.startBeat, regionEndBeat: request.endBeat,
                repaintStartSeconds: 2, repaintEndSeconds: 6, bouncePath: "/tmp/bounce.wav")
        }
    }

    /// A scriptable generation-status source (the `FakeGenerator` idiom): FIFO
    /// outcomes per jobID, the last one sticky so extra polls keep seeing the
    /// terminal state; a `.failure` simulates a transient network blip. An actor
    /// so the `@Sendable` status closure can call it across the model's awaits.
    actor FakeStatus {
        struct StubError: Error, LocalizedError { var errorDescription: String? }
        private var scripts: [String: [Result<SongGenerationStatus, Error>]] = [:]
        private var sticky: [String: Result<SongGenerationStatus, Error>] = [:]

        func script(_ jobID: String, _ outcomes: [Result<SongGenerationStatus, Error>]) {
            scripts[jobID] = outcomes
        }

        func status(jobID: String) async throws -> SongGenerationStatus {
            if var queue = scripts[jobID], !queue.isEmpty {
                let next = queue.removeFirst()
                scripts[jobID] = queue
                sticky[jobID] = next
                switch next {
                case .success(let s): return s
                case .failure(let e): throw e
                }
            }
            if let last = sticky[jobID] {
                switch last {
                case .success(let s): return s
                case .failure(let e): throw e
                }
            }
            throw StubError(errorDescription: "job \(jobID) not found")
        }
    }

    /// Records import calls, returns a scripted `ClipFixImportResult` or throws.
    @MainActor final class ImportRecorder {
        var received: [String] = []
        var result = ClipFixImportResult(trackID: UUID(), groupID: UUID(),
                                         laneID: UUID(), laneName: "AI Fix 1")
        var error: Error?

        func importFix(_ jobID: String) async throws -> ClipFixImportResult {
            received.append(jobID)
            if let error { throw error }
            return result
        }
    }

    private func makeModel(_ submit: SubmitRecorder, _ status: FakeStatus,
                           _ imp: ImportRecorder) -> ClipFixModel {
        ClipFixModel(
            submitter: { request in try await submit.submit(request) },
            statusProvider: { jobID in try await status.status(jobID: jobID) },
            importer: { jobID in try await imp.importFix(jobID) })
    }

    private func running(_ jobID: String, _ progress: Double) -> SongGenerationStatus {
        SongGenerationStatus(jobID: jobID, state: .running, progress: progress, statusText: "step 3/8")
    }
    private func succeeded(_ jobID: String, audioPath: String = "/tmp/fix.wav") -> SongGenerationStatus {
        SongGenerationStatus(jobID: jobID, state: .succeeded, progress: 1,
                             statusText: "done", audioPath: audioPath)
    }

    // MARK: - Submit

    @Test func submitCallsStoreWithExactArgsAndAppendsPendingCard() async {
        let submit = SubmitRecorder(); let status = FakeStatus(); let imp = ImportRecorder()
        let model = makeModel(submit, status, imp)
        let trackID = UUID(); let clipID = UUID()

        await model.submit(trackId: trackID, clipId: clipID,
                           startBeat: 33, endBeat: 41,
                           prompt: "clean the chorus vocal", lyrics: "[chorus]\nwe rise",
                           mode: .balanced, contextSeconds: 10)

        #expect(submit.received.count == 1)
        let req = submit.received[0]
        #expect(req.trackId == trackID)
        #expect(req.clipId == clipID)
        #expect(req.startBeat == 33)
        #expect(req.endBeat == 41)
        #expect(req.prompt == "clean the chorus vocal")
        #expect(req.lyrics == "[chorus]\nwe rise")
        #expect(req.mode == .balanced)
        #expect(req.contextSeconds == 10)

        #expect(model.cards.count == 1)
        #expect(model.cards[0].jobID == "fix-1")
        #expect(model.cards[0].state == .pending)
        #expect(model.cards[0].regionStartBeat == 33)
        #expect(model.cards[0].regionEndBeat == 41)
        #expect(model.hasActiveJobs)
        #expect(model.submitError == nil)
    }

    @Test func submitFailureSetsSubmitErrorAndAddsNoCard() async {
        struct Boom: Error, LocalizedError { var errorDescription: String? { "sidecar unreachable" } }
        let submit = SubmitRecorder(); submit.error = Boom()
        let model = makeModel(submit, FakeStatus(), ImportRecorder())

        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)

        #expect(model.cards.isEmpty)
        #expect(model.submitError == "sidecar unreachable")
    }

    @Test func blankPromptAndLyricsAreThreadedAsNil() async {
        let submit = SubmitRecorder()
        let model = makeModel(submit, FakeStatus(), ImportRecorder())
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4,
                           prompt: "   ", lyrics: "\n")
        #expect(submit.received[0].prompt == nil)
        #expect(submit.received[0].lyrics == nil)
    }

    // MARK: - Busy-guard

    @Test func submitIsBusyGuardedAgainstDoubleFire() async {
        // A slow submitter that yields, letting a second submit race in while the
        // first is still awaiting — the guard must drop the second.
        actor Gate { func wait() async { await Task.yield(); await Task.yield() } }
        let gate = Gate()
        final class Counter { var n = 0 }
        let counter = Counter()
        let model = ClipFixModel(
            submitter: { req in
                counter.n += 1
                await gate.wait()
                return ClipFixSubmission(
                    jobID: "fix-\(counter.n)", state: "queued", queuePosition: nil,
                    windowStartBeat: req.startBeat, windowEndBeat: req.endBeat,
                    regionStartBeat: req.startBeat, regionEndBeat: req.endBeat,
                    repaintStartSeconds: 0, repaintEndSeconds: 0, bouncePath: "/tmp/b.wav")
            },
            statusProvider: { _ in throw CancellationError() },
            importer: { _ in ClipFixImportResult(trackID: UUID(), groupID: UUID(),
                                                 laneID: UUID(), laneName: "AI Fix 1") })
        let t = UUID(); let c = UUID()
        async let a: Void = model.submit(trackId: t, clipId: c, startBeat: 0, endBeat: 4)
        async let b: Void = model.submit(trackId: t, clipId: c, startBeat: 0, endBeat: 4)
        _ = await (a, b)
        #expect(counter.n == 1, "the busy-guard must drop the overlapping submit")
        #expect(model.cards.count == 1)
    }

    // MARK: - Poll transitions

    @Test func refreshMovesPendingThroughRunningToSucceeded() async {
        let submit = SubmitRecorder(); let status = FakeStatus(); let imp = ImportRecorder()
        let model = makeModel(submit, status, imp)
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [
            .success(running(job, 0.4)),
            .success(succeeded(job)),
        ])

        await model.refresh()
        if case .running(let p, let text) = model.cards[0].state {
            #expect(p == 0.4)
            #expect(text == "step 3/8")
        } else { Issue.record("expected running, got \(model.cards[0].state)") }
        #expect(model.hasActiveJobs)

        await model.refresh()
        #expect(model.cards[0].state == .succeededAwaitingImport)
        #expect(!model.hasActiveJobs)
    }

    @Test func succeededWithoutAudioPathStaysRunning() async {
        let submit = SubmitRecorder(); let status = FakeStatus()
        let model = makeModel(submit, status, ImportRecorder())
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [.success(succeeded(job, audioPath: ""))])
        await model.refresh()
        #expect(model.cards[0].state.isActive)   // no path yet → still working
    }

    @Test func returnedFailedStateFailsTheCard() async {
        let submit = SubmitRecorder(); let status = FakeStatus()
        let model = makeModel(submit, status, ImportRecorder())
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [
            .success(SongGenerationStatus(jobID: job, state: .failed, statusText: "worker crashed")),
        ])
        await model.refresh()
        if case .failed(let message) = model.cards[0].state {
            #expect(message == "worker crashed")
        } else { Issue.record("expected failed, got \(model.cards[0].state)") }
        #expect(!model.hasActiveJobs)
    }

    // MARK: - Failed-poll tolerance (the key rule)

    @Test func transientPollErrorMarksStaleButKeepsPolling() async {
        let submit = SubmitRecorder(); let status = FakeStatus()
        let model = makeModel(submit, status, ImportRecorder())
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [
            .success(running(job, 0.5)),
            .failure(FakeStatus.StubError(errorDescription: "connection reset")),
            .success(succeeded(job)),
        ])

        await model.refresh()   // running
        #expect(!model.cards[0].isStale)

        await model.refresh()   // transient blip
        #expect(model.cards[0].isStale, "a poll throw must mark stale, not kill")
        #expect(model.cards[0].state.isActive, "the card survives the blip")
        if case .running = model.cards[0].state {} else {
            Issue.record("state must be preserved across a transient error, got \(model.cards[0].state)")
        }

        await model.refresh()   // recovers → succeeded, stale cleared
        #expect(!model.cards[0].isStale)
        #expect(model.cards[0].state == .succeededAwaitingImport)
    }

    @Test func refreshOnlyPollsActiveJobs() async {
        // A settled card must not be re-polled back into flux.
        let submit = SubmitRecorder(); let status = FakeStatus()
        let model = makeModel(submit, status, ImportRecorder())
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [.success(succeeded(job))])
        await model.refresh()
        #expect(!model.cards[0].state.isActive)
        // Even if the job later starts throwing, a terminal card is untouched.
        await status.script(job, [.failure(FakeStatus.StubError(errorDescription: "gone"))])
        await model.refresh()
        #expect(model.cards[0].state == .succeededAwaitingImport)
        #expect(!model.cards[0].isStale)
    }

    // MARK: - Import

    @Test func importHappyPathFlipsToImportedWithLaneName() async {
        let submit = SubmitRecorder(); let status = FakeStatus(); let imp = ImportRecorder()
        imp.result = ClipFixImportResult(trackID: UUID(), groupID: UUID(),
                                         laneID: UUID(), laneName: "AI Fix 2")
        let model = makeModel(submit, status, imp)
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [.success(succeeded(job))])
        await model.refresh()

        await model.importFix(jobID: job)
        #expect(imp.received == [job])
        if case .imported(let laneName) = model.cards[0].state {
            #expect(laneName == "AI Fix 2")
        } else { Issue.record("expected imported, got \(model.cards[0].state)") }
        #expect(!model.cards[0].isStale)
        #expect(!model.hasActiveJobs)
    }

    @Test func importIsNoOpForNonSucceededCard() async {
        let submit = SubmitRecorder(); let imp = ImportRecorder()
        let model = makeModel(submit, FakeStatus(), imp)
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)   // .pending
        await model.importFix(jobID: model.cards[0].jobID)
        #expect(imp.received.isEmpty)
        #expect(model.cards[0].state == .pending)
    }

    @Test func importClipFixStaleFlipsToStaleWithMessage() async {
        let submit = SubmitRecorder(); let status = FakeStatus(); let imp = ImportRecorder()
        imp.error = ProjectError.clipFixStale("the original clip's time-stretch changed — submit again")
        let model = makeModel(submit, status, imp)
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [.success(succeeded(job))])
        await model.refresh()

        await model.importFix(jobID: job)
        if case .stale(let message) = model.cards[0].state {
            #expect(message == "the original clip's time-stretch changed — submit again")
        } else { Issue.record("expected stale, got \(model.cards[0].state)") }
        #expect(!model.cards[0].isStale)   // terminal stale STATE, not the transient flag
    }

    @Test func importClipFixJobNotFoundFlipsToFailed() async {
        let submit = SubmitRecorder(); let status = FakeStatus(); let imp = ImportRecorder()
        imp.error = ProjectError.clipFixJobNotFound("fix-1")
        let model = makeModel(submit, status, imp)
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [.success(succeeded(job))])
        await model.refresh()

        await model.importFix(jobID: job)
        if case .failed(let message) = model.cards[0].state {
            #expect(message.contains("no pending clip fix"))
        } else { Issue.record("expected failed, got \(model.cards[0].state)") }
    }

    @Test func genericImportFailureMarksStaleAndKeepsImportable() async {
        struct Boom: Error {}
        let submit = SubmitRecorder(); let status = FakeStatus(); let imp = ImportRecorder()
        imp.error = Boom()
        let model = makeModel(submit, status, imp)
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        await status.script(job, [.success(succeeded(job))])
        await model.refresh()

        await model.importFix(jobID: job)
        #expect(model.cards[0].isStale)
        #expect(model.cards[0].state == .succeededAwaitingImport,
                "a transient import failure must leave the fix importable for a retry")
    }

    // MARK: - Context threading

    @Test func contextSecondsIsThreadedThroughSubmit() async {
        let submit = SubmitRecorder()
        let model = makeModel(submit, FakeStatus(), ImportRecorder())
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 8, endBeat: 16,
                           mode: .aggressive, strength: 0.7, seed: 42, contextSeconds: 25)
        let req = submit.received[0]
        #expect(req.contextSeconds == 25)
        #expect(req.mode == .aggressive)
        #expect(req.strength == 0.7)
        #expect(req.seed == 42)
    }

    // MARK: - Composer

    @Test func prepareSeedsRegionFromClipSpanAndGatesSubmit() async {
        let submit = SubmitRecorder()
        let model = makeModel(submit, FakeStatus(), ImportRecorder())
        #expect(!model.canSubmit)   // no target yet

        let track = UUID(); let clip = UUID()
        model.prepare(trackID: track, clipID: clip, name: "Lead vox", startBeat: 12, endBeat: 28)
        #expect(model.regionStartBeat == 12)
        #expect(model.regionEndBeat == 28)
        #expect(model.targetClipName == "Lead vox")
        #expect(model.canSubmit)

        // A redraw of the SAME selection keeps an in-progress region edit.
        model.regionStartBeat = 14
        model.prepare(trackID: track, clipID: clip, name: "Lead vox", startBeat: 12, endBeat: 28)
        #expect(model.regionStartBeat == 14, "same-clip prepare must not clobber an edit")

        // Switching to a different clip re-seeds.
        let clip2 = UUID()
        model.prepare(trackID: track, clipID: clip2, name: "Harmony", startBeat: 40, endBeat: 44)
        #expect(model.regionStartBeat == 40)
        #expect(model.regionEndBeat == 44)

        // An inverted region disarms the GO button.
        model.regionEndBeat = 40
        #expect(!model.canSubmit)
    }

    @Test func submitCurrentUsesComposerFields() async {
        let submit = SubmitRecorder()
        let model = makeModel(submit, FakeStatus(), ImportRecorder())
        let track = UUID(); let clip = UUID()
        model.prepare(trackID: track, clipID: clip, name: "Vox", startBeat: 5, endBeat: 9)
        model.prompt = "smooth the transition"
        model.mode = .conservative
        await model.submitCurrent()
        #expect(submit.received.count == 1)
        #expect(submit.received[0].startBeat == 5)
        #expect(submit.received[0].endBeat == 9)
        #expect(submit.received[0].prompt == "smooth the transition")
        #expect(submit.received[0].mode == .conservative)
    }

    // MARK: - Dismiss + seeding

    @Test func dismissRemovesTheCard() async {
        let submit = SubmitRecorder()
        let model = makeModel(submit, FakeStatus(), ImportRecorder())
        await model.submit(trackId: UUID(), clipId: UUID(), startBeat: 0, endBeat: 4)
        let job = model.cards[0].jobID
        model.dismiss(jobID: job)
        #expect(model.cards.isEmpty)
    }

    @Test func setCardsForCaptureReplacesTheList() {
        let submit = SubmitRecorder()
        let model = makeModel(submit, FakeStatus(), ImportRecorder())
        model.setCardsForCapture([
            ClipFixCard(jobID: "a", trackID: UUID(), regionStartBeat: 33, regionEndBeat: 41,
                        promptSnippet: "chorus", state: .running(progress: 0.4, statusText: "step 3/8")),
            ClipFixCard(jobID: "b", trackID: UUID(), regionStartBeat: 8, regionEndBeat: 12,
                        state: .succeededAwaitingImport),
        ])
        #expect(model.cards.count == 2)
        #expect(model.cards[0].jobID == "a")
        #expect(model.hasActiveJobs)   // the running one keeps the timer alive
    }
}
