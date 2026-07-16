import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWAppKit

/// Headless tests for the m17-h unified generation-progress registry: origin
/// tagging, the boot → queued → running → done/failed lifecycle, the verbatim
/// failure law, the sidecar-death detection (failed + notice, never silent),
/// the stale-tolerance rule, the lingers, and the observing decorator that
/// feeds it from every origin. Drives `GenerationPresenceModel` /
/// `GenerationObservingGenerator` against scripted fakes — no window, no
/// engine, no network (the `SketchpadModel` precedent).
@MainActor
@Suite struct GenerationPresenceModelTests {

    // MARK: - Fakes

    /// A mutable box whose access is serialized by an internal lock.
    /// @unchecked Sendable justification: every read/write goes through
    /// `withLock` on the private NSLock — no unsynchronized state escapes.
    final class LockedBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: Value
        init(_ value: Value) { stored = value }
        var value: Value {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// Scripted status responses keyed by jobID (FIFO, last outcome sticky).
    /// @unchecked Sendable justification: all state behind the internal NSLock.
    final class StatusScript: @unchecked Sendable {
        private let lock = NSLock()
        private var queues: [String: [Result<SongGenerationStatus, Error>]] = [:]
        private var sticky: [String: Result<SongGenerationStatus, Error>] = [:]
        private var polledIDs: [String] = []

        func script(_ jobID: String, _ outcomes: [Result<SongGenerationStatus, Error>]) {
            lock.withLock { queues[jobID] = outcomes }
        }

        var polled: [String] { lock.withLock { polledIDs } }

        func next(_ jobID: String) throws -> SongGenerationStatus {
            let outcome: Result<SongGenerationStatus, Error>? = lock.withLock {
                polledIDs.append(jobID)
                if var queue = queues[jobID], !queue.isEmpty {
                    let head = queue.removeFirst()
                    queues[jobID] = queue
                    sticky[jobID] = head
                    return head
                }
                return sticky[jobID]
            }
            guard let outcome else { throw ACEStepError.jobNotFound(jobID) }
            return try outcome.get()
        }
    }

    private static func healthy() -> SidecarStatus {
        SidecarStatus(state: .healthy, message: "running")
    }

    private func makeModel(
        script: StatusScript = StatusScript(),
        sidecar: LockedBox<SidecarStatus> = LockedBox(healthy()),
        clock: LockedBox<Date> = LockedBox(Date(timeIntervalSince1970: 1_000)),
        notify: ((String) -> Void)? = nil
    ) -> GenerationPresenceModel {
        GenerationPresenceModel(
            status: { jobID in try script.next(jobID) },
            sidecarStatus: { sidecar.value },
            notify: notify,
            now: { clock.value })
    }

    private func runningStatus(_ jobID: String, progress: Double?, text: String? = nil) -> SongGenerationStatus {
        SongGenerationStatus(jobID: jobID, state: .running, progress: progress, statusText: text)
    }

    private func succeededStatus(_ jobID: String) -> SongGenerationStatus {
        SongGenerationStatus(jobID: jobID, state: .succeeded, progress: 1,
                             audioPath: "/tmp/\(jobID).wav")
    }

    // MARK: - Registry basics

    @Test func registerSubmissionAppendsAnOriginTaggedQueuedJob() {
        let model = makeModel()
        model.registerSubmission(jobID: "j1", origin: .wire, label: "warm 80s synth-pop")
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].jobID == "j1")
        #expect(model.jobs[0].origin == .wire)
        #expect(model.jobs[0].phase == .queued)
        #expect(model.isVisible)
        #expect(model.needsPolling)
    }

    @Test func submissionConsumesTheBootEntryOfItsOriginKeepingElapsedStart() {
        let clock = LockedBox(Date(timeIntervalSince1970: 1_000))
        let model = makeModel(clock: clock)
        model.beginStartingSidecar(origin: .sketchpad, label: "warm pads")
        let bootStart = model.jobs[0].startedAt
        clock.value = Date(timeIntervalSince1970: 1_090)   // 90 s of boot
        model.registerSubmission(jobID: "j1", origin: .sketchpad, label: "warm pads")
        // ONE row: the boot entry became the job — elapsed spans the boot.
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].jobID == "j1")
        #expect(model.jobs[0].phase == .queued)
        #expect(model.jobs[0].startedAt == bootStart)
        #expect(model.elapsedText(for: model.jobs[0]) == "1:30")
    }

    @Test func submissionOfAnotherOriginDoesNotConsumeTheBootEntry() {
        let model = makeModel()
        model.beginStartingSidecar(origin: .wire, label: "agent job")
        model.registerSubmission(jobID: "j1", origin: .sketchpad, label: "panel job")
        #expect(model.jobs.count == 2)
    }

    @Test func submissionFailureIsAFailedCardWithTheVerbatimReason() {
        let model = makeModel()
        model.registerSubmissionFailure(origin: .wire, label: "x", reason: "HTTP 500: worker exploded")
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].phase == .failed(reason: "HTTP 500: worker exploded"))
        #expect(!model.needsPolling)
        #expect(model.isVisible)    // failed stays visible until dismissed
    }

    @Test func applyUpdatesProgressAndStageAndIgnoresLatePollsAfterTerminal() {
        let model = makeModel()
        model.registerSubmission(jobID: "j1", origin: .sketchpad, label: "x")
        model.apply(runningStatus("j1", progress: 0.4, text: "step 3/8"))
        #expect(model.jobs[0].phase == .running(progress: 0.4, stageText: "step 3/8"))
        model.apply(succeededStatus("j1"))
        #expect(model.jobs[0].phase == .succeeded)
        #expect(model.jobs[0].finishedAt != nil)
        // A late running poll for a terminal row is ignored.
        model.apply(runningStatus("j1", progress: 0.1))
        #expect(model.jobs[0].phase == .succeeded)
    }

    @Test func applyRegistersAnUnknownActiveJobButNotAnUnknownTerminalOne() {
        let model = makeModel()
        // An agent polls a job this session never saw submitted → presence.
        model.apply(runningStatus("ghost", progress: 0.2), origin: .wire)
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].jobID == "ghost")
        #expect(model.jobs[0].origin == .wire)
        // An unknown TERMINAL status must not resurrect a card (e.g. an import
        // re-polling a long-finished job).
        model.apply(succeededStatus("old-done"))
        #expect(model.jobs.count == 1)
    }

    @Test func applyFailureRegistersUnknownJobsToo() {
        let model = makeModel()
        model.applyFailure(jobID: "ghost", reason: "worker ran out of memory")
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].phase == .failed(reason: "worker ran out of memory"))
    }

    @Test func dismissRemovesTerminalRowsOnlyNeverActiveOnes() {
        let model = makeModel()
        model.registerSubmission(jobID: "j1", origin: .wire, label: "active")
        model.registerSubmissionFailure(origin: .wire, label: "dead", reason: "boom")
        let activeID = model.jobs[0].id
        let failedID = model.jobs[1].id
        model.dismiss(activeID)
        #expect(model.jobs.count == 2)   // active rows are not dismissable (no upstream abort)
        model.dismiss(failedID)
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].id == activeID)
    }

    // MARK: - Poll: job advancement + the failure honesty laws

    @Test func pollAdvancesQueuedThroughRunningWithProgress() async {
        let script = StatusScript()
        script.script("j1", [.success(runningStatus("j1", progress: 0.25, text: "step 2/8"))])
        let model = makeModel(script: script)
        model.registerSubmission(jobID: "j1", origin: .wire, label: "x")
        await model.poll()
        #expect(model.jobs[0].phase == .running(progress: 0.25, stageText: "step 2/8"))
        #expect(GenerationPresenceModel.percentText(for: model.jobs[0].phase) == "25%")
    }

    @Test func pollJobFailedFlipsToFailedWithTheWorkerMessageVerbatim() async {
        let script = StatusScript()
        script.script("j1", [.failure(ACEStepError.jobFailed(
            jobID: "j1", message: "CUDA out of memory on step 6"))])
        let model = makeModel(script: script)
        model.registerSubmission(jobID: "j1", origin: .sketchpad, label: "x")
        await model.poll()
        #expect(model.jobs[0].phase == .failed(reason: "CUDA out of memory on step 6"))
        #expect(model.jobs[0].finishedAt != nil)
    }

    @Test func pollJobNotFoundIsTerminalToo() async {
        let script = StatusScript()   // nothing scripted → jobNotFound
        let model = makeModel(script: script)
        model.registerSubmission(jobID: "gone", origin: .wire, label: "x")
        await model.poll()
        guard case .failed(let reason) = model.jobs[0].phase else {
            Issue.record("expected failed, got \(model.jobs[0].phase)")
            return
        }
        #expect(reason.contains("gone"))   // the client's own jobNotFound message
    }

    @Test func pollTransientErrorWithAHealthySidecarOnlyDimsTheRow() async {
        struct Blip: Error {}
        let script = StatusScript()
        script.script("j1", [.failure(Blip()),
                             .success(runningStatus("j1", progress: 0.5))])
        let model = makeModel(script: script)
        model.registerSubmission(jobID: "j1", origin: .wire, label: "x")
        await model.poll()
        #expect(model.jobs[0].isStale)                 // dimmed, kept, still polling
        #expect(model.jobs[0].phase.isActive)
        await model.poll()
        #expect(!model.jobs[0].isStale)                // recovered on the next good poll
        #expect(model.jobs[0].phase == .running(progress: 0.5, stageText: nil))
    }

    @Test func sidecarDeathMidJobFailsTheRowVerbatimAndFiresTheNotice() async {
        let script = StatusScript()
        let unreachable = ACEStepError.sidecarUnreachable("Could not connect to the server.")
        script.script("j1", [.failure(unreachable)])
        let sidecar = LockedBox(SidecarStatus(
            state: .installedNotRunning, message: "not running"))
        var notices: [String] = []
        let model = makeModel(script: script, sidecar: sidecar,
                              notify: { notices.append($0) })
        model.registerSubmission(jobID: "j1", origin: .wire, label: "agent song")
        await model.poll()
        guard case .failed(let reason) = model.jobs[0].phase else {
            Issue.record("expected failed after sidecar death, got \(model.jobs[0].phase)")
            return
        }
        // The card carries the client error VERBATIM…
        #expect(reason == unreachable.errorDescription)
        // …and the notice fired — never silent.
        #expect(notices.count == 1)
        #expect(notices[0].contains("agent song"))
        #expect(!model.jobs[0].isStale)
    }

    @Test func unreachableWhileTheSidecarStillReportsStartingIsNeverDeath() async {
        // A boot-in-progress makes polls fail without meaning death — never a
        // failed card, never a notice. A QUEUED row reads the boot narration
        // (the overlay); a RUNNING row keeps its progress and just dims.
        let script = StatusScript()
        script.script("q", [.failure(ACEStepError.sidecarUnreachable("refused"))])
        script.script("r", [.failure(ACEStepError.sidecarUnreachable("refused"))])
        let sidecar = LockedBox(SidecarStatus(
            state: .starting, message: "starting", phase: "loading models…", startingForSeconds: 30))
        var notices: [String] = []
        let model = makeModel(script: script, sidecar: sidecar, notify: { notices.append($0) })
        model.registerSubmission(jobID: "q", origin: .wire, label: "queued job")
        model.registerSubmission(jobID: "r", origin: .wire, label: "running job")
        model.apply(runningStatus("r", progress: 0.7, text: "step 6/8"))
        await model.poll()
        // Queued → boot narration, undimmed.
        #expect(model.jobs[0].phase == .startingSidecar(detail: "loading models…"))
        #expect(!model.jobs[0].isStale)
        // Running → keeps its last progress, dimmed stale.
        #expect(model.jobs[1].phase == .running(progress: 0.7, stageText: "step 6/8"))
        #expect(model.jobs[1].isStale)
        #expect(model.jobs.allSatisfy { $0.phase.isActive })
        #expect(notices.isEmpty)
    }

    // MARK: - Poll: boot entries (auto-start narration)

    @Test func bootEntryTracksTheSidecarPhaseIncludingLoadingModels() async {
        let sidecar = LockedBox(SidecarStatus(
            state: .starting, message: "starting", phase: "loading models…", startingForSeconds: 12))
        let model = makeModel(sidecar: sidecar)
        model.beginStartingSidecar(origin: .sketchpad, label: "warm pads")
        #expect(model.jobs[0].phase == .startingSidecar(detail: nil))
        await model.poll()
        #expect(model.jobs[0].phase == .startingSidecar(detail: "loading models…"))
        #expect(GenerationPresenceModel.stageLabel(for: model.jobs[0].phase) == "LOADING THE MODEL…")
    }

    @Test func bootEntryGoesReadyOnHealthyAndClearsAfterTheLinger() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 2_000))
        let sidecar = LockedBox(Self.healthy())
        let model = makeModel(sidecar: sidecar, clock: clock)
        model.beginStartingSidecar(origin: .wire, label: "agent song")
        await model.poll()
        #expect(model.jobs[0].phase == .sidecarReady)
        // Still present inside the linger window…
        clock.value = Date(timeIntervalSince1970: 2_000 + 5)
        await model.poll()
        #expect(model.jobs.count == 1)
        // …cleared once it expires (nothing is running upstream).
        clock.value = Date(timeIntervalSince1970:
            2_000 + GenerationPresenceModel.sidecarReadyLingerSeconds + 6)
        await model.poll()
        #expect(model.jobs.isEmpty)
    }

    @Test func bootEntryFailsVerbatimWhenTheSidecarReportsErrorOrNotInstalled() async {
        let sidecar = LockedBox(SidecarStatus(
            state: .error, message: "health responded with an unparseable payload"))
        let model = makeModel(sidecar: sidecar)
        model.beginStartingSidecar(origin: .sketchpad, label: "x")
        await model.poll()
        #expect(model.jobs[0].phase == .failed(
            reason: "health responded with an unparseable payload"))
    }

    @Test func seededActiveRowWithoutAJobIDIsNeverTouchedByThePoll() async {
        // The capture seam stages running rows with NO jobID on purpose (the
        // debug.sketchpadDemo empty-jobID rule) — the poll must not mistake
        // them for boot entries or poll them upstream.
        let script = StatusScript()
        let model = makeModel(script: script)
        model.seedJobForCapture(GenerationPresenceJob(
            origin: .sketchpad, label: "staged",
            phase: .running(progress: 0.4, stageText: "step 3/8"),
            startedAt: Date()))
        await model.poll()
        #expect(model.jobs[0].phase == .running(progress: 0.4, stageText: "step 3/8"))
        #expect(script.polled.isEmpty)
    }

    @Test func queuedJobOverlaysTheBootPhaseWhileTheSidecarIsStillLoading() async {
        // Measured live (m17-h gate): ACE-Step's /health flips healthy seconds
        // into a cold boot, so an auto-started submit lands "queued" while the
        // 8–20 GB model load is the real work. The card must narrate that —
        // "LOADING THE MODEL…" — not sit on a bare QUEUED.
        let script = StatusScript()
        script.script("j1", [.success(SongGenerationStatus(jobID: "j1", state: .queued)),
                             .success(SongGenerationStatus(jobID: "j1", state: .queued))])
        let sidecar = LockedBox(SidecarStatus(
            state: .starting, message: "starting", phase: "loading models…", startingForSeconds: 20))
        let model = makeModel(script: script, sidecar: sidecar)
        model.registerSubmission(jobID: "j1", origin: .sketchpad, label: "x")
        await model.poll()
        #expect(model.jobs[0].phase == .startingSidecar(detail: "loading models…"))
        #expect(GenerationPresenceModel.stageLabel(for: model.jobs[0].phase) == "LOADING THE MODEL…")
        #expect(!model.jobs[0].isStale)
        // Boot over → the overlay flips back to plain QUEUED.
        sidecar.value = Self.healthy()
        await model.poll()
        #expect(model.jobs[0].phase == .queued)
    }

    @Test func failingPollsDuringTheModelLoadReadAsBootNarrationNotReconnecting() async {
        // While the server is busy loading, `query_result` can fail outright;
        // with the sidecar honestly reporting `starting`, the row must show
        // the boot phase (not a dimmed RECONNECTING — that's for real blips).
        struct Busy: Error {}
        let script = StatusScript()
        script.script("j1", [.failure(Busy())])
        let sidecar = LockedBox(SidecarStatus(
            state: .starting, message: "starting", phase: "loading models…", startingForSeconds: 40))
        let model = makeModel(script: script, sidecar: sidecar)
        model.registerSubmission(jobID: "j1", origin: .wire, label: "x")
        await model.poll()
        #expect(model.jobs[0].phase == .startingSidecar(detail: "loading models…"))
        #expect(!model.jobs[0].isStale)
    }

    @Test func succeededRowsClearAfterTheLingerFailedRowsStay() async {
        let clock = LockedBox(Date(timeIntervalSince1970: 3_000))
        let script = StatusScript()
        script.script("ok", [.success(succeededStatus("ok"))])
        script.script("bad", [.failure(ACEStepError.jobFailed(jobID: "bad", message: "boom"))])
        let model = makeModel(script: script, clock: clock)
        model.registerSubmission(jobID: "ok", origin: .wire, label: "good")
        model.registerSubmission(jobID: "bad", origin: .wire, label: "bad")
        await model.poll()
        #expect(model.jobs.count == 2)
        clock.value = Date(timeIntervalSince1970:
            3_000 + GenerationPresenceModel.succeededLingerSeconds + 1)
        await model.poll()
        // DONE cleared honestly; FAILED is sticky until dismissed.
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].jobID == "bad")
    }

    // MARK: - Derivations

    @Test func stageLabelsReadHonestly() {
        #expect(GenerationPresenceModel.stageLabel(for: .startingSidecar(detail: nil))
            == "STARTING THE AI GENERATOR…")
        #expect(GenerationPresenceModel.stageLabel(for: .startingSidecar(detail: "starting server…"))
            == "STARTING SERVER…")
        #expect(GenerationPresenceModel.stageLabel(for: .startingSidecar(detail: "loading models…"))
            == "LOADING THE MODEL…")
        #expect(GenerationPresenceModel.stageLabel(for: .queued) == "QUEUED")
        #expect(GenerationPresenceModel.stageLabel(for: .running(progress: 0.5, stageText: nil))
            == "GENERATING")
        #expect(GenerationPresenceModel.stageLabel(for: .running(progress: nil, stageText: "step 4/8"))
            == "STEP 4/8")
        #expect(GenerationPresenceModel.stageLabel(for: .succeeded) == "DONE")
        #expect(GenerationPresenceModel.stageLabel(for: .failed(reason: "x")) == "FAILED")
    }

    @Test func percentAndElapsedFormat() {
        #expect(GenerationPresenceModel.percentText(for: .running(progress: 0.856, stageText: nil)) == "86%")
        #expect(GenerationPresenceModel.percentText(for: .running(progress: nil, stageText: nil)) == nil)
        #expect(GenerationPresenceModel.percentText(for: .queued) == nil)
        let start = Date(timeIntervalSince1970: 0)
        #expect(GenerationPresenceModel.elapsedText(from: start, to: start.addingTimeInterval(7)) == "0:07")
        #expect(GenerationPresenceModel.elapsedText(from: start, to: start.addingTimeInterval(83)) == "1:23")
        #expect(GenerationPresenceModel.elapsedText(from: start, to: start.addingTimeInterval(725)) == "12:05")
    }

    @Test func preferredStageTextPicksTheCleanPipelineStageOverTheRawLogLine() {
        // Live shape (m17-h): `stage` = clean pipeline text, `statusText` =
        // the worker's raw log line. Clean wins; legacy enum stages defer to
        // the log line; something honest always comes back when either exists.
        #expect(GenerationPresenceModel.preferredStageText(
            stage: "Generating music (batch size: 2)...",
            statusText: "MLX DiT diffusion:  25%|##5 | 2/8") == "Generating music (batch size: 2)...")
        #expect(GenerationPresenceModel.preferredStageText(
            stage: "running", statusText: "step 3/8") == "step 3/8")
        #expect(GenerationPresenceModel.preferredStageText(
            stage: "running", statusText: nil) == "running")
        #expect(GenerationPresenceModel.preferredStageText(stage: nil, statusText: "step 3/8") == "step 3/8")
        #expect(GenerationPresenceModel.preferredStageText(stage: nil, statusText: nil) == nil)
    }

    @Test func terminalFailureClassification() {
        #expect(GenerationPresenceModel.terminalFailureReason(
            ACEStepError.jobFailed(jobID: "j", message: "worker died")) == "worker died")
        #expect(GenerationPresenceModel.terminalFailureReason(
            ACEStepError.jobNotFound("j"))?.contains("j") == true)
        #expect(GenerationPresenceModel.terminalFailureReason(
            ACEStepError.sidecarUnreachable("refused")) == nil)
        #expect(GenerationPresenceModel.terminalFailureReason(
            ACEStepError.requestFailed(status: 503, body: "busy")) == nil)
        #expect(GenerationPresenceModel.isUnreachable(ACEStepError.sidecarUnreachable("x")))
        #expect(!GenerationPresenceModel.isUnreachable(ACEStepError.jobNotFound("x")))
    }

    // MARK: - The observing decorator (origin feeds)

    /// Scriptable `SongGenerating` for decorator tests. An actor so it's
    /// Sendable across the decorator's awaits (the SketchpadModelTests rule).
    actor FakeGenerator: SongGenerating {
        var submitOutcomes: [Result<SongGenerationSubmission, Error>] = []
        var statusOutcome: Result<SongGenerationStatus, Error>?
        private(set) var submitCount = 0

        func scriptSubmits(_ outcomes: [Result<SongGenerationSubmission, Error>]) {
            submitOutcomes = outcomes
        }
        func scriptStatus(_ outcome: Result<SongGenerationStatus, Error>) {
            statusOutcome = outcome
        }

        func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
            submitCount += 1
            guard !submitOutcomes.isEmpty else {
                return SongGenerationSubmission(jobID: "auto-\(submitCount)", state: .queued)
            }
            return try submitOutcomes.removeFirst().get()
        }

        func generationStatus(jobID: String) async throws -> SongGenerationStatus {
            guard let statusOutcome else { throw ACEStepError.jobNotFound(jobID) }
            return try statusOutcome.get()
        }

        func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
            StemGenerationSubmission(jobID: "stems-1", state: .queued, trackNames: request.trackNames)
        }

        func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
            StemGenerationSubmission(jobID: "lego-1", state: .queued,
                                     trackNames: request.tracks.map(\.trackName))
        }
    }

    @Test func decoratorRegistersASubmissionTaggedWithItsOrigin() async throws {
        let fake = FakeGenerator()
        let model = makeModel()
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .sketchpad, presence: model)
        let submission = try await observed.generateSong(
            SongGenerationRequest(prompt: "warm 80s synth-pop, anthemic, driving bass and gated drums"))
        #expect(submission.jobID == "auto-1")
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].origin == .sketchpad)
        #expect(model.jobs[0].jobID == "auto-1")
        #expect(model.jobs[0].label == "warm 80s synth-pop, anthemic, driving bass")   // 6-word snippet
        #expect(model.jobs[0].phase == .queued)
    }

    @Test func decoratorAwaitsBootRetriesAndTheOneCardEntryBecomesTheJob() async throws {
        let fake = FakeGenerator()
        await fake.scriptSubmits([
            .failure(ACEStepError.sidecarUnreachable("refused")),
            .success(SongGenerationSubmission(jobID: "post-boot", state: .queued)),
        ])
        let model = makeModel()
        let bootRan = LockedBox(false)
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .sketchpad, presence: model,
            ensureSidecar: { bootRan.value = true; return true },
            awaitsBoot: true)
        let submission = try await observed.generateSong(SongGenerationRequest(prompt: "warm pads"))
        #expect(submission.jobID == "post-boot")
        #expect(bootRan.value)
        // ONE entry rode the whole path: boot → submitted.
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].jobID == "post-boot")
        #expect(model.jobs[0].phase == .queued)
    }

    @Test func decoratorAwaitsBootFailureIsAFailedCardWithTheVerbatimError() async throws {
        let fake = FakeGenerator()
        let unreachable = ACEStepError.sidecarUnreachable("refused")
        await fake.scriptSubmits([.failure(unreachable)])
        let model = makeModel()
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .sketchpad, presence: model,
            ensureSidecar: { false },   // the boot never reached healthy
            awaitsBoot: true)
        await #expect(throws: ACEStepError.self) {
            _ = try await observed.generateSong(SongGenerationRequest(prompt: "x"))
        }
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].phase == .failed(reason: unreachable.errorDescription ?? ""))
    }

    @Test func decoratorWireModeKicksTheBootKeepsTheBootCardAndRethrows() async throws {
        let fake = FakeGenerator()
        await fake.scriptSubmits([.failure(ACEStepError.sidecarUnreachable("refused"))])
        let model = makeModel()
        let bootRan = LockedBox(false)
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .wire, presence: model,
            ensureSidecar: { bootRan.value = true; return true },
            awaitsBoot: false)
        await #expect(throws: ACEStepError.self) {
            _ = try await observed.generateSong(SongGenerationRequest(prompt: "agent song"))
        }
        // The boot presence stays (the card narrates it); the agent's retry
        // will consume it via registerSubmission.
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].phase == .startingSidecar(detail: nil))
        #expect(model.jobs[0].origin == .wire)
        // The fire-and-forget boot task actually ran.
        for _ in 0..<100 where !bootRan.value {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(bootRan.value)
    }

    @Test func decoratorNonUnreachableSubmitErrorIsAFailedCardVerbatim() async throws {
        let fake = FakeGenerator()
        await fake.scriptSubmits([.failure(ACEStepError.requestFailed(status: 422, body: "bad prompt"))])
        let model = makeModel()
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .wire, presence: model,
            ensureSidecar: { true }, awaitsBoot: false)
        await #expect(throws: ACEStepError.self) {
            _ = try await observed.generateSong(SongGenerationRequest(prompt: "x"))
        }
        guard case .failed(let reason) = model.jobs[0].phase else {
            Issue.record("expected a failed card, got \(model.jobs[0].phase)")
            return
        }
        #expect(reason.contains("422"))
        #expect(reason.contains("bad prompt"))
    }

    @Test func decoratorObservedStatusPollsFlowIntoThePresence() async throws {
        let fake = FakeGenerator()
        await fake.scriptStatus(.success(runningStatus("j1", progress: 0.6, text: "step 5/8")))
        let model = makeModel()
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .wire, presence: model)
        model.registerSubmission(jobID: "j1", origin: .wire, label: "x")
        _ = try await observed.generationStatus(jobID: "j1")
        #expect(model.jobs[0].phase == .running(progress: 0.6, stageText: "step 5/8"))
    }

    @Test func decoratorObservedTerminalPollFailureLandsAsAFailedCard() async {
        let fake = FakeGenerator()
        await fake.scriptStatus(.failure(ACEStepError.jobFailed(jobID: "j1", message: "oom")))
        let model = makeModel()
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .wire, presence: model)
        model.registerSubmission(jobID: "j1", origin: .wire, label: "x")
        await #expect(throws: ACEStepError.self) {
            _ = try await observed.generationStatus(jobID: "j1")
        }
        #expect(model.jobs[0].phase == .failed(reason: "oom"))
    }

    @Test func decoratorRegistersStemJobsWithATrackNameLabel() async throws {
        let fake = FakeGenerator()
        let model = makeModel()
        let observed = GenerationObservingGenerator(
            wrapping: fake, origin: .import, presence: model)
        _ = try await observed.extractStems(StemExtractionRequest(
            sourceAudioPath: "/tmp/mix.wav", trackNames: ["vocals", "drums"]))
        #expect(model.jobs.count == 1)
        #expect(model.jobs[0].jobID == "stems-1")
        #expect(model.jobs[0].origin == .import)
        #expect(model.jobs[0].label == "Stems: vocals, drums")
    }
}
