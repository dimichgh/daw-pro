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

    @Test func singOriginTagsTheCardSing() throws {
        // p2-sing-e: ONE appended case; the existing three keep their labels.
        #expect(GenerationJobOrigin.sing.displayLabel == "SING")
        #expect(GenerationJobOrigin(rawValue: "sing") == .sing)
        #expect(GenerationJobOrigin.allCases.map { $0.displayLabel } == ["SKETCHPAD", "AGENT", "IMPORT", "SING", "AGENT"])
        let encoded = try JSONEncoder().encode(GenerationJobOrigin.sing)
        #expect(String(decoding: encoded, as: UTF8.self) == "\"sing\"")
        #expect(try JSONDecoder().decode(GenerationJobOrigin.self, from: encoded) == .sing)
    }


    // MARK: - p2-sing-f: the Sing screens' MainActor halves
    //
    // Appended here (no new @MainActor suite: the cap). The pure halves and the shared fakes live in
    // `SingScreensTextTests.swift`. Never a real microphone, engine, download or singing engine.

    @Test func singAgentJobShowsAgentChipAndNeverAdoptsAnACEBootRow() {
        let model = makeModel()
        // An agent's ACE generate is still booting: a `.wire` pre-submit row with no job id.
        model.beginStartingSidecar(origin: .wire, label: "ACE song")
        model.registerSubmission(jobID: "sing-a", origin: .forSingJob(fromAgent: true),
                                 label: "Vocals — Built-in singer", state: .running)
        #expect(model.jobs.count == 2)
        #expect(model.jobs.first { $0.jobID == "sing-a" }?.origin.displayLabel == "AGENT")
        #expect(model.jobs.contains { $0.jobID == nil && $0.origin == .wire })
        model.registerSubmission(jobID: "sing-u", origin: .forSingJob(fromAgent: false), label: "x", state: .running)
        #expect(model.jobs.first { $0.jobID == "sing-u" }?.origin.displayLabel == "SING")
    }

    /// The sheet under test, with spies in front of the three functions the wire calls.
    private func makeSheet(pitches: [Int] = [60, 62, 64, 65], engine: SingingSidecarState = .installedNotRunning,
                           jobs: SingFakeJobs = SingFakeJobs()) throws
        -> (SingSheetModel, ProjectStore, UUID, SingLyricsSpy, SingTransposeSpy, SingFakeJobs) {
        let (store, clipID) = try SingSheetFixture.store(pitches: pitches)
        let lyrics = SingLyricsSpy(store: store)
        let transposer = SingTransposeSpy(store: store)
        let status = SingingSidecarStatus(state: engine, message: "fake engine: \(engine.rawValue)")
        let sheet = SingSheetModel(store: store, lyrics: lyrics, transposer: transposer, jobs: jobs,
                                   engineStatus: { status }, library: nil)
        return (sheet, store, clipID, lyrics, transposer, jobs)
    }

    @Test func singSheetSingItReachesTheWiresFunctions() async throws {
        let (sheet, store, clipID, lyrics, _, jobs) = try makeSheet()
        let accepted = LockedBox<[SingJobRequest]>([])
        sheet.onSubmitted = { _, request in accepted.value.append(request) }
        await sheet.open(clipID: clipID)
        sheet.setText("one two three four")
        #expect(sheet.canSing)
        await sheet.singIt()

        // p2-sing-x8 (the W8-X3b ruling): the words go through the LANGUAGE overload, with the picker's value
        // (English is nil).
        #expect(lyrics.calls == [.init(clipId: clipID, text: "one two three four", language: nil,
                                       undoLabel: "Set Lyrics")])
        let submitted = await jobs.submitted
        #expect(submitted.count == 1)
        #expect(submitted.first?.clipID == clipID)
        #expect(submitted.first?.fromAgent == false)
        #expect(submitted.first?.voice == .builtIn)
        #expect(submitted.first.map { SingPlanner.octaveShiftRange.contains($0.octaveShift) } == true)
        #expect(accepted.value.count == 1)
        #expect(!sheet.isOpen)
        #expect(store.tracks.flatMap(\.clips).first { $0.id == clipID }?.lyrics?.text == "one two three four")
    }

    @Test func singSheetUnchangedLyricsAreNotWrittenAgain() async throws {
        let (sheet, _, clipID, lyrics, _, jobs) = try makeSheet()
        await sheet.open(clipID: clipID)
        sheet.setText("one two three four")
        await sheet.singIt()
        await sheet.open(clipID: clipID)   // the words are now stored
        #expect(sheet.text == "one two three four")
        await sheet.singIt()
        #expect(lyrics.calls.count == 1)   // the wire's rule: only a change is written
        #expect(await jobs.submitted.count == 2)
    }

    @Test func singSheetShowsCoordinatorRefusalInItsOwnWords() async throws {
        let jobs = SingFakeJobs()
        await jobs.refuse(.queueFull(capacity: 1))
        let (sheet, _, clipID, _, _, _) = try makeSheet(jobs: jobs)
        await sheet.open(clipID: clipID)
        sheet.setText("one two three four")
        await sheet.singIt()
        #expect(sheet.refusal == SingJobError.queueFull(capacity: 1).errorDescription)
        #expect(sheet.isOpen)
        #expect(!sheet.isSubmitting)
    }

    @Test func singSheetWordsRefusalKeepsSingItDarkAndCallsNothing() async throws {
        let (sheet, _, clipID, lyrics, _, jobs) = try makeSheet()
        await sheet.open(clipID: clipID)
        sheet.setText("one two three four five six")   // 6 words, 4 notes
        #expect(!sheet.canSing)
        #expect(sheet.singItDisabledReason?.contains("has 6 words but the tune has 4 notes") == true)
        await sheet.singIt()
        #expect(lyrics.calls.isEmpty)
        #expect(await jobs.submitted.isEmpty)
    }

    @Test func singSheetWithNoEngineAsksForConsentAndStoresNothing() async throws {
        let (sheet, _, clipID, lyrics, _, jobs) = try makeSheet(engine: .notInstalled)
        let broker = SingConsentBroker(autoConsent: false)
        let consent = SingConsentModel(
            broker: broker,
            install: SingingEngineInstallCoordinator(installFunction: { _ in .succeeded(installedBytes: 1) }))
        broker.onRequest = { consent.present($0) }
        sheet.onNeedsInstall = { await consent.ask(.installEngine) }
        await sheet.open(clipID: clipID)
        sheet.setText("one two three four")
        await sheet.singIt()
        #expect(lyrics.calls.isEmpty)
        #expect(await jobs.submitted.isEmpty)
        #expect(broker.pending.count == 1)
        #expect(broker.pending.first?.fromAgent == false)
        #expect(consent.cardText?.body == SingCopy.installCardBody)
        #expect(consent.cardText?.agentLine == nil)
        #expect(sheet.isOpen)
    }

    @Test func singSheetMovePreviewsWithADryRunThenTransposesThroughTheStore() async throws {
        // MIDI 66…75 against the built-in singer (61.7 / 65.9 / 68.7): no octave fits, t = −5 does.
        let (sheet, store, clipID, _, transposer, jobs) = try makeSheet(pitches: Array(66...75))
        await sheet.open(clipID: clipID)
        let line = try #require(sheet.height)
        #expect(line.moveTitle == "Move the song down 5")
        sheet.chooseMove()
        #expect(transposer.calls == [.init(semitones: -5, dryRun: true)])
        #expect(sheet.transposeReview?.sentence == SingCopy.transposePreview(instrumentTracks: 1, recordedTracks: 0))
        let firstPitch = { store.tracks.flatMap(\.clips).first { $0.id == clipID }?.notes?.first?.pitch }
        #expect(firstPitch() == 66)   // a preview moves nothing
        sheet.confirmMove()
        #expect(transposer.calls.last == .init(semitones: -5, dryRun: false))
        #expect(firstPitch() == 61)
        #expect(sheet.height?.sentence == "Fits your voice.")
        sheet.setText("one two three four five six seven eight nine ten")
        await sheet.singIt()
        #expect(await jobs.submitted.first?.songTransposeSemitones == -5)
    }

    @Test func singSheetRealStoreWritesTheLyricsThroughTheStoresOwnMethod() async throws {
        // No spy: the conformer the app passes IS the store, so the witness is `ProjectStore.setClipLyrics`.
        let (store, clipID) = try SingSheetFixture.store()
        let jobs = SingFakeJobs()
        let sheet = SingSheetModel(store: store, lyrics: store, transposer: store, jobs: jobs,
                                   engineStatus: { SingingSidecarStatus(state: .healthy, message: "ok") },
                                   library: nil)
        await sheet.open(clipID: clipID)
        sheet.setText("la la la la")
        await sheet.singIt()
        #expect(store.tracks.flatMap(\.clips).first { $0.id == clipID }?.lyrics?.text == "la la la la")
        #expect(await jobs.submitted.count == 1)
    }

    // MARK: Consent

    private func makeConsent() -> (SingConsentModel, SingConsentBroker, LockedBox<[SingConsentAction]>,
                                   LockedBox<Int>) {
        let broker = SingConsentBroker(autoConsent: false)
        let performed = LockedBox<[SingConsentAction]>([])
        broker.performer = { action in performed.value.append(action) }
        let directInstalls = LockedBox<Int>(0)
        let install = SingingEngineInstallCoordinator(installFunction: { _ in
            directInstalls.value += 1
            return .succeeded(installedBytes: 1)
        })
        let consent = SingConsentModel(broker: broker, install: install)
        broker.onRequest = { consent.present($0) }
        return (consent, broker, performed, directInstalls)
    }

    @Test func consentInstallGoesThroughTheBroker() async throws {
        let (consent, broker, performed, directInstalls) = makeConsent()
        _ = try await broker.request(.installEngine, fromAgent: true)   // the agent's sing.installEngine
        #expect(consent.cardText?.agentLine == "An AI agent asked for this.")
        #expect(performed.value.isEmpty)   // nothing happens until the click
        await consent.approve()
        #expect(performed.value == [.installEngine])
        #expect(broker.pending.isEmpty)
        for _ in 0..<20 { await Task.yield() }
        #expect(directInstalls.value == 0)   // the card never starts a download itself
    }

    @Test func consentNotNowDeclinesAndNothingIsPerformed() async throws {
        let (consent, broker, performed, _) = makeConsent()
        _ = try await broker.request(.installEngine, fromAgent: false)
        #expect(consent.cardText?.agentLine == nil)
        consent.notNow()
        #expect(broker.pending.isEmpty)
        #expect(performed.value.isEmpty)
        #expect(!consent.isOpen)
    }

    @Test func consentUninstallIsGuardedTheSameWay() async throws {
        let (consent, broker, performed, _) = makeConsent()
        _ = try await broker.request(.uninstallEngine, fromAgent: true)
        #expect(consent.cardText?.primary == "Remove the engine")
        #expect(consent.cardText?.agentLine == "An AI agent asked for this.")
        #expect(performed.value.isEmpty)
        await consent.approve()
        #expect(performed.value == [.uninstallEngine])
        #expect(consent.phase == .finished(message: SingCopy.removed, retry: nil))
        // And a no is a no.
        consent.dismiss()
        _ = try await broker.request(.uninstallEngine, fromAgent: false)
        consent.notNow()
        #expect(performed.value == [.uninstallEngine])
        #expect(broker.pending.isEmpty)
    }

    @Test func consentAYesThatFailsIsShownInItsOwnWords() async throws {
        let broker = SingConsentBroker(autoConsent: false)   // no performer: the broker refuses
        let consent = SingConsentModel(
            broker: broker,
            install: SingingEngineInstallCoordinator(installFunction: { _ in .succeeded(installedBytes: 1) }))
        broker.onRequest = { consent.present($0) }
        _ = try await broker.request(.installEngine, fromAgent: false)
        await consent.approve()
        #expect(consent.errorText == SingConsentError.notConnected.errorDescription)
        #expect(consent.phase == .finished(message: SingConsentError.notConnected.errorDescription ?? "",
                                           retry: .installEngine))
    }

    @Test func consentFailedInstallReadsInstallStoppedWithTryAgain() async throws {
        let broker = SingConsentBroker(autoConsent: false)
        let install = SingingEngineInstallCoordinator(installFunction: { _ in
            .failed(step: "preflight", message: "only 3 GB free")
        })
        broker.performer = { _ in _ = try await install.start() }   // what the wire's performer does
        let consent = SingConsentModel(broker: broker, install: install)
        broker.onRequest = { consent.present($0) }
        _ = try await broker.request(.installEngine, fromAgent: false)
        await consent.approve()
        for _ in 0..<200 {
            await consent.pollInstall()
            if case .finished = consent.phase { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(consent.phase == .finished(message: "Installing stopped at 'preflight': only 3 GB free.",
                                           retry: .installEngine))
    }

    // MARK: The recorder (a FAKE capture; never a real microphone)

    final class RecorderClock {
        var t = 100.0
    }

    private func makeRecorder(permission: RecordPermission = .granted)
        -> (SingVoiceRecorderModel, SingFakeCapture, SingFakeTransport, SingFakePlayer, SingSaverSpy, RecorderClock,
            LockedBox<[String]>) {
        let capture = SingFakeCapture()
        capture.recordPermission = permission
        let transport = SingFakeTransport()
        let order = LockedBox<[String]>([])
        transport.log = { order.value.append($0) }
        capture.sharedLog = { order.value.append($0) }
        let player = SingFakePlayer()
        let saver = SingSaverSpy()
        let clock = RecorderClock()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-recorder-test-\(UUID().uuidString)", isDirectory: true)
        let recorder = SingVoiceRecorderModel(
            capture: capture, transport: transport, player: player, saver: saver, recordingsDirectory: folder,
            guideURL: { URL(fileURLWithPath: "/tmp/guide-\($0.rawValue).wav") }, now: { clock.t },
            startsDriver: false)
        return (recorder, capture, transport, player, saver, clock, order)
    }

    private func recording(_ url: URL, endedBy: InputOnlyCaptureEnd = .stopped) -> InputOnlyCaptureOutcome {
        .recorded(InputOnlyCaptureRecording(
            fileURL: url, info: AudioFileInfo(durationSeconds: 6, sampleRate: 48_000, channelCount: 1),
            frameCount: 288_000, endedBy: endedBy))
    }

    private func waitFor(_ recorder: SingVoiceRecorderModel, _ step: SingVoiceRecorderModel.Step) async {
        for _ in 0..<200 where recorder.step != step {
            await Task.yield()
        }
    }

    @Test func recorderOpeningStopsPlaybackFirst() {
        let (recorder, _, transport, _, _, _, _) = makeRecorder()
        transport.isTransportPlaying = true
        recorder.open(fromAgent: true)
        #expect(transport.stops == 1)
        #expect(!transport.isTransportPlaying)
        #expect(recorder.step == .choose)
        #expect(recorder.openedByAgent)
    }

    @Test func recorderRecordStopsPlaybackAgainBeforeTheCaptureStarts() {
        let (recorder, capture, transport, _, _, _, order) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        #expect(recorder.step == .ready)
        transport.isTransportPlaying = true   // an agent's transport.play since the recorder opened
        order.value = []
        recorder.record()
        #expect(order.value == ["stopTransport", "start"])
        #expect(capture.started.count == 1)
        #expect(recorder.step == .recording)
    }

    @Test func recorderAsksForTheMicrophoneThenProceeds() {
        let (recorder, capture, _, _, _, _, _) = makeRecorder(permission: .undetermined)
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        #expect(capture.log == ["requestPermission"])
        #expect(recorder.step == .ready)
    }

    @Test func recorderPermissionDeniedStopsBeforeAnyCapture() {
        let (asked, askedCapture, _, _, _, _, _) = makeRecorder(permission: .undetermined)
        askedCapture.grantOnRequest = false
        asked.open(fromAgent: false)
        asked.answerHeadphones(true)
        #expect(asked.step == .permissionDenied)
        asked.record()
        #expect(askedCapture.started.isEmpty)

        let (denied, deniedCapture, _, _, _, _, _) = makeRecorder(permission: .denied)
        denied.open(fromAgent: false)
        denied.answerHeadphones(true)
        #expect(denied.step == .permissionDenied)
        #expect(deniedCapture.log.isEmpty)   // never re-prompted: macOS would not show it again
    }

    @Test func recorderWithoutHeadphonesPlaysTheTuneFirst() {
        let (recorder, _, _, player, _, _, _) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.pickAndPlay(.low)
        recorder.answerHeadphones(false)
        #expect(recorder.step == .listening)
        #expect(player.played.last == URL(fileURLWithPath: "/tmp/guide-low.wav"))
    }

    @Test func recorderStopBeforeAudioShowsTheEnginesSentence() {
        let (recorder, capture, _, _, _, clock, _) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        clock.t += 0.4
        recorder.tick()
        recorder.stop()                     // during "Get ready…"
        #expect(recorder.step == .finishing)
        clock.t += 0.2
        recorder.tick()
        #expect(!capture.log.contains("stop"))   // the 0.30 s guard is still running
        clock.t += 0.15
        recorder.tick()
        #expect(capture.log.contains("stop"))
        let sentence = "No sound came in from the microphone, so nothing was recorded."
        capture.finish(.failed(reason: sentence))
        #expect(recorder.step == .failed(sentence))
    }

    @Test func recorderStopsByItselfAfterQuietOnceSingingWasHeard() {
        let (recorder, capture, _, _, _, clock, _) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        func run(_ seconds: Double, _ db: Double) {
            capture.peak = db
            let end = recorder.elapsed + seconds
            while recorder.elapsed < end - 1e-9, recorder.step == .recording {
                clock.t += 1.0 / 30
                recorder.tick()
            }
        }
        run(SingRecorderTiming.singingStartsAt, -70)
        run(3.2, -20)
        run(1.4, -70)
        #expect(recorder.step == .recording)
        run(0.2, -70)
        #expect(recorder.step == .finishing)
        clock.t += 0.31
        recorder.tick()
        #expect(capture.log.contains("stop"))
    }

    @Test func recorderCapsAtTwelveSecondsAndChecksTheTake() async throws {
        let (recorder, capture, _, _, saver, _, _) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        #expect(capture.started.first?.maxSeconds == 12)
        let url = try #require(capture.started.first?.url)
        capture.finish(recording(url, endedBy: .reachedMaxSeconds))
        #expect(recorder.step == .checking)
        await waitFor(recorder, .passed)
        #expect(recorder.step == .passed)
        #expect(await saver.checks == [url])
        #expect(await saver.checkKinds == [.recorder])
    }

    @Test func recorderProjectSwapCancelsTheCapture() {
        let (recorder, capture, transport, _, _, clock, _) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        transport.projectGeneration += 1   // File ▸ Open, New, or a recovery
        clock.t += 0.1
        recorder.tick()
        #expect(capture.log.contains("cancel"))
        #expect(recorder.step == .failed(SingCopy.projectChanged))
        recorder.record()                   // and the recorder works again on the new project
        #expect(capture.started.count == 2)
    }

    @Test func recorderPlaybackStartingDuringTheCaptureCancelsIt() {
        let (recorder, capture, transport, _, _, clock, _) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        transport.isTransportPlaying = true
        clock.t += 0.1
        recorder.tick()
        #expect(capture.log.contains("cancel"))
        #expect(recorder.step == .failed(SingCopy.playbackInterrupted))
    }

    /// p2-sing-f2 RENAMED this from `recorderRefusesTheProjectsRecordWhileOpenAndWaitsForATake`, which overclaimed:
    /// it checks the sentence, its REGISTRATION with the song, and the recorder's own refusal. The store's refusal
    /// itself is driven against a real `ProjectStore` in the `songRecord…` tests below.
    @Test func recorderRegistersTheSongsRecordRefusalWhileOpenAndWaitsForATake() {
        let (recorder, capture, transport, _, _, _, _) = makeRecorder()
        #expect(recorder.projectRecordRefusal == nil)
        #expect(transport.voiceRecorderOpenReason == nil)
        recorder.open(fromAgent: false)
        #expect(recorder.projectRecordRefusal == SingCopy.recorderIsOpen)
        #expect(transport.voiceRecorderOpenReason == SingCopy.recorderIsOpen)
        recorder.answerHeadphones(true)
        transport.isTransportRecording = true
        recorder.record()
        #expect(recorder.notice == SingCopy.takeIsRecording)
        #expect(capture.started.isEmpty)
        recorder.close()
        #expect(recorder.projectRecordRefusal == nil)
        #expect(transport.voiceRecorderOpenReason == nil)
    }

    @Test func recorderSaveReachesPreparationWithTheNameAndRecorderKind() async throws {
        let (recorder, capture, _, _, saver, _, _) = makeRecorder()
        let saved = LockedBox<[String]>([])
        recorder.onSaved = { saved.value.append($0.id) }
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        let url = try #require(capture.started.first?.url)
        capture.finish(recording(url))
        await waitFor(recorder, .passed)
        recorder.name = "Low voice"
        await recorder.save()
        let saves = await saver.saves
        #expect(saves.count == 1)
        #expect(saves.first?.url == url)
        #expect(saves.first?.name == "Low voice")
        #expect(saves.first?.kind == .recorder)
        #expect(recorder.step == .saved(VoiceRangeFit.voiceSavedSentence(saver.range)))
        #expect(saved.value == ["voice-saved"])
    }

    @Test func recorderCheckRefusalIsOneSentenceThenAFreshFileToRecordAgain() async throws {
        let (recorder, capture, _, _, saver, _, _) = makeRecorder()
        let refusal = SingVoiceAddRefusal.check(.tooShort, durationSeconds: 1.2)
        await saver.refuseChecks(refusal)
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        let first = try #require(capture.started.first?.url)
        capture.finish(recording(first))
        await waitFor(recorder, .failed(refusal.sentence))
        #expect(recorder.step == .failed(refusal.sentence))
        recorder.record()
        #expect(capture.started.count == 2)
        #expect(capture.started.last?.url != first)
    }

    @Test func recorderClosingCancelsARunningCapture() {
        let (recorder, capture, _, _, _, _, _) = makeRecorder()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        recorder.close()
        #expect(capture.log.contains("cancel"))
        #expect(recorder.step == .closed)
    }

    // MARK: The song's Record while the recorder is open (p2-sing-f2: refused AT THE STORE, not only by the scrim)

    /// A recorder whose transport is a REAL `ProjectStore` (one armed instrument track, a take spy), so these
    /// assertions meet `ProjectStore.record()` itself: the function `transport.record` and the button call.
    private func makeRecorderOnStore() throws
        -> (SingVoiceRecorderModel, ProjectStore, RecordRefusalSpyEngine, SingFakeCapture, SingSaverSpy,
            RecorderClock) {
        let engine = RecordRefusalSpyEngine()
        let store = ProjectStore(projectName: "p2-sing-f2 recorder")
        store.engine = engine
        try armKeys(store)
        let capture = SingFakeCapture()
        capture.recordPermission = .granted
        let saver = SingSaverSpy()
        let clock = RecorderClock()
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("sing-recorder-f2-test-\(UUID().uuidString)", isDirectory: true)
        let recorder = SingVoiceRecorderModel(
            capture: capture, transport: store, player: SingFakePlayer(), saver: saver, recordingsDirectory: folder,
            guideURL: { URL(fileURLWithPath: "/tmp/guide-\($0.rawValue).wav") }, now: { clock.t },
            startsDriver: false)
        return (recorder, store, engine, capture, saver, clock)
    }

    private func armKeys(_ store: ProjectStore) throws {
        let track = store.addTrack(name: "Keys", kind: .instrument)
        _ = try store.setTrackArm(id: track.id, armed: true)
    }

    /// `store.record()`'s refusal in its own words, or nil when the take started.
    private func songRecordRefusal(_ store: ProjectStore) -> String? {
        do {
            try store.record()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    /// `store.recordLayer()`'s refusal in its own words, or nil when the layer started.
    private func songLayerRefusal(_ store: ProjectStore) -> String? {
        do {
            try store.recordLayer()
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? "\(error)"
        }
    }

    @Test func songRecordIsRefusedAtTheStoreWhileTheRecorderIsOpenAndNothingStarts() throws {
        let (recorder, store, engine, _, _, _) = try makeRecorderOnStore()
        #expect(store.voiceRecorderOpenReason == nil)
        recorder.open(fromAgent: true)   // an agent's sing.openVoiceRecorder: only the person records
        #expect(store.voiceRecorderOpenReason == SingCopy.recorderIsOpen)
        #expect(songRecordRefusal(store) == SingCopy.recorderIsOpen)
        #expect(store.lastRecordingError == SingCopy.recorderIsOpen)
        // A layer over the playing song is refused the same way, and FIRST.
        store.play()
        #expect(songLayerRefusal(store) == SingCopy.recorderIsOpen)
        store.stop()
        #expect(engine.takeStarts == 0)
        #expect(engine.layerStarts == 0)
        #expect(!store.transport.isRecording)
        recorder.close()   // the ✕, Escape (the ✕'s key) and `debug.singScreens {close}` all call this
        #expect(store.voiceRecorderOpenReason == nil)
        #expect(songRecordRefusal(store) == nil)
        #expect(engine.takeStarts == 1)
        #expect(store.transport.isRecording)
        store.stop()
    }

    @Test func songRecordWorksAgainWhenTheRecorderClosesMidCapture() throws {
        let (recorder, store, engine, capture, _, _) = try makeRecorderOnStore()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        #expect(recorder.step == .recording)
        #expect(songRecordRefusal(store) == SingCopy.recorderIsOpen)
        recorder.close()
        #expect(capture.log.contains("cancel"))
        #expect(store.voiceRecorderOpenReason == nil)
        #expect(songRecordRefusal(store) == nil)
        #expect(engine.takeStarts == 1)
        store.stop()
    }

    @Test func songRecordStaysRefusedOnTheSavedCardAndWorksAfterDone() async throws {
        let (recorder, store, engine, capture, _, _) = try makeRecorderOnStore()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        let url = try #require(capture.started.first?.url)
        capture.finish(recording(url))
        await waitFor(recorder, .passed)
        #expect(recorder.step == .passed)
        await recorder.save()
        guard case .saved = recorder.step else {
            Issue.record("expected the saved card, got \(recorder.step)")
            return
        }
        // "Voice saved" and [Done] are still on screen, so the sentence is still true.
        #expect(store.voiceRecorderOpenReason == SingCopy.recorderIsOpen)
        #expect(songRecordRefusal(store) == SingCopy.recorderIsOpen)
        recorder.close()   // [Done]
        #expect(store.voiceRecorderOpenReason == nil)
        #expect(songRecordRefusal(store) == nil)
        #expect(engine.takeStarts == 1)
        store.stop()
    }

    @Test func aProjectSwapLeavesTheRecorderOpenAndTheNewProjectsRecordRefused() throws {
        let (recorder, store, engine, _, _, _) = try makeRecorderOnStore()
        recorder.open(fromAgent: false)
        try store.newProject(discardChanges: true)   // File ▸ New; Open and a recovery bump the same generation
        try armKeys(store)
        // The card is still on screen (the recorder is app-level and outlives the project), so the new project's
        // Record is refused with the same, still-true sentence.
        #expect(recorder.isOpen)
        #expect(store.voiceRecorderOpenReason == SingCopy.recorderIsOpen)
        #expect(songRecordRefusal(store) == SingCopy.recorderIsOpen)
        #expect(engine.takeStarts == 0)
    }

    @Test func closingTheRecorderAfterAProjectSwapLetsTheNewProjectRecord() throws {
        let (recorder, store, engine, _, _, _) = try makeRecorderOnStore()
        recorder.open(fromAgent: false)
        try store.newProject(discardChanges: true)
        recorder.close()
        #expect(store.voiceRecorderOpenReason == nil)
        try armKeys(store)
        #expect(songRecordRefusal(store) == nil)
        #expect(engine.takeStarts == 1)
        store.stop()
    }

    @Test func aSwapDuringACaptureEndsItAndClosingThenLetsTheNewProjectRecord() throws {
        let (recorder, store, engine, capture, _, clock) = try makeRecorderOnStore()
        recorder.open(fromAgent: false)
        recorder.answerHeadphones(true)
        recorder.record()
        try store.newProject(discardChanges: true)
        clock.t += 0.1
        recorder.tick()
        #expect(capture.log.contains("cancel"))
        #expect(recorder.step == .failed(SingCopy.projectChanged))
        #expect(songRecordRefusal(store) == SingCopy.recorderIsOpen)   // still open, on the new project
        recorder.close()
        try armKeys(store)
        #expect(songRecordRefusal(store) == nil)
        #expect(engine.takeStarts == 1)
        store.stop()
    }

    @Test func theDebugStagingRegistersAndClearsTheSongsRecordRefusalToo() throws {
        // Keep the spy bound: `ProjectStore.engine` is WEAK, and a dropped spy reads "audio engine not available".
        let (recorder, store, engine, _, _, _) = try makeRecorderOnStore()
        recorder.stageForCapture(.ready)   // from closed, without open(): `debug.singScreens {screen:"recorder"}`
        #expect(store.voiceRecorderOpenReason == SingCopy.recorderIsOpen)
        recorder.stageForCapture(.closed)
        #expect(store.voiceRecorderOpenReason == nil)
        #expect(songRecordRefusal(store) == nil)
        #expect(engine.takeStarts == 1)
        store.stop()
    }

    // MARK: The results card's job calls

    @Test func takeCancelAndAnotherTakeReachTheCoordinator() async throws {
        let jobs = SingFakeJobs()
        let take = SingTakeModel(jobs: jobs)
        let request = SingJobRequest(clipID: UUID(), octaveShift: -1)
        let first = try await jobs.submit(request)
        take.track(first, request: request)
        await take.cancel()
        #expect(await jobs.cancelled == [first.jobID])
        #expect(take.status?.cancelRequested == true)
        let accepted = LockedBox<Int>(0)
        take.onSubmitted = { _, _ in accepted.value += 1 }
        await take.tryAnotherTake()
        let submitted = await jobs.submitted
        #expect(submitted.count == 2)
        #expect(submitted.last?.octaveShift == -1)
        #expect(submitted.last?.seed != nil)
        #expect(accepted.value == 1)
    }

    // MARK: - p2-sing-x8: the singing expansion's MainActor halves
    //
    // Appended here (no new @MainActor suite: the cap). The pure halves and the expansion's fakes live in
    // `SingScreensExpansionTests.swift`. Every test reaches the store/coordinator function the WIRE calls (through a
    // spy where the call itself is the claim) and counts undo steps with the store's own journal.

    /// A sheet over a real store, with spies in front of the lyrics, style and job seams.
    private func makeX8Sheet(pitches: [Int] = [60, 62, 64, 65], lyrics stored: String? = nil,
                             engine: SingingSidecarState = .healthy, jobs: SingFakeJobs = SingFakeJobs(),
                             writer: (any LyricsGenerating)? = nil) throws
        -> (SingSheetModel, ProjectStore, UUID, SingLyricsSpy, SingStyleSpy, SingFakeJobs) {
        let (store, clipID) = try SingSheetFixture.store(pitches: pitches, lyrics: stored)
        let lyrics = SingLyricsSpy(store: store)
        let styles = SingStyleSpy(store: store)
        let status = SingingSidecarStatus(state: engine, message: "fake engine: \(engine.rawValue)")
        var makeWriter: (@MainActor () throws -> any LyricsGenerating)?
        if let writer { makeWriter = { @MainActor in writer } }
        let sheet = SingSheetModel(store: store, lyrics: lyrics, transposer: store, jobs: jobs,
                                   engineStatus: { status }, library: nil, styles: styles, makeWriter: makeWriter)
        return (sheet, store, clipID, lyrics, styles, jobs)
    }

    private func x8Clip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap(\.clips).first { $0.id == id }
    }

    // MARK: The note field (§3.1)

    @Test func noteFieldReturnCommitsThroughSetNoteWordAsOneUndoStep() async throws {
        let (sheet, store, clipID, lyrics, _, _) = try makeX8Sheet(lyrics: "one two three four")
        let engine = SingCountingEngine()
        store.engine = engine
        await sheet.open(clipID: clipID)
        let notes = sheet.preview.notes
        let before = x8Clip(store, clipID)?.lyrics
        sheet.tapNote(notes[1].id)
        #expect(sheet.noteWord?.draft == "two")
        #expect(sheet.noteWord?.refusal == nil)
        sheet.setNoteWordDraft("deux")
        let pushesBefore = engine.tracksPushes
        sheet.commitNoteWord(advance: false)
        #expect(lyrics.noteWordCalls == [.init(clipId: clipID, noteId: notes[1].id, word: "deux", dryRun: false)])
        #expect(lyrics.calls.isEmpty)   // the stored words were already the box's: no "Set Lyrics" first
        #expect(sheet.text == x8Clip(store, clipID)?.lyrics?.text)
        #expect(sheet.text.contains("deux"))
        #expect(sheet.preview.chips.map(\.text).contains("deux"))
        #expect(sheet.noteWord == nil)
        // ONE undo step, "Type Word", with ONE engine push inside it.
        #expect(store.undoLabel == ProjectStore.typeWordUndoLabel)
        #expect(engine.tracksPushes - pushesBefore == 1)
        try store.undo()
        #expect(x8Clip(store, clipID)?.lyrics == before)
    }

    @Test func noteFieldTabMovesToTheNextNote() async throws {
        let (sheet, _, clipID, lyrics, _, _) = try makeX8Sheet(lyrics: "one two three four")
        await sheet.open(clipID: clipID)
        let notes = sheet.preview.notes
        sheet.tapChip(0)
        #expect(sheet.noteWord?.noteID == notes[0].id)
        sheet.setNoteWordDraft("uno")
        sheet.commitNoteWord(advance: true)
        #expect(lyrics.noteWordCalls.count == 1)
        #expect(sheet.noteWord?.noteID == notes[1].id)
        #expect(sheet.noteWord?.draft == "two")
        // An unchanged Tab writes nothing and moves on.
        sheet.commitNoteWord(advance: true)
        #expect(lyrics.noteWordCalls.count == 1)
        #expect(sheet.noteWord?.noteID == notes[2].id)
    }

    @Test func noteFieldPlusAndEmptyBothHoldTheWordBefore() async throws {
        for typed in ["+", ""] {
            let (sheet, store, clipID, lyrics, _, _) = try makeX8Sheet(lyrics: "one two three four")
            await sheet.open(clipID: clipID)
            let notes = sheet.preview.notes
            // The oracle: the store's own dry run of the same edit (it changes nothing).
            let expected = try store.setNoteWord(clipId: clipID, noteId: notes[1].id, word: typed, dryRun: true)
            sheet.tapNote(notes[1].id)
            sheet.setNoteWordDraft(typed)
            sheet.commitNoteWord(advance: false)
            #expect(lyrics.noteWordCalls.last?.word == typed)
            #expect(sheet.text == expected.text)
            #expect(x8Clip(store, clipID)?.lyrics?.text == expected.text)
            // The word before now holds onto the note: the first chip covers both notes. (Its `held` flag stays
            // false: that flag is rule 5.2's automatic melisma only; notes asked for with `+` are not counted there.)
            #expect(sheet.preview.chips.first?.noteIDs == [notes[0].id, notes[1].id], "typed '\(typed)'")
        }
    }

    @Test func noteFieldWithNoWordsYetSaysSoAndWritesNothing() async throws {
        let (sheet, _, clipID, lyrics, _, _) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        sheet.tapNote(sheet.preview.notes[0].id)
        #expect(sheet.noteWord?.refusal == LyricEditRefusal.noText.sentence)
        #expect(sheet.noteWord?.canCommit == false)
        sheet.setNoteWordDraft("la")
        sheet.commitNoteWord(advance: false)
        #expect(lyrics.noteWordCalls.isEmpty)
        #expect(lyrics.calls.isEmpty)
    }

    @Test func noteFieldRefusalIsShownInItsOwnWordsAndTheFieldStays() async throws {
        let (sheet, store, clipID, _, _, _) = try makeX8Sheet(lyrics: "one two three four")
        await sheet.open(clipID: clipID)
        let note = sheet.preview.notes[2].id
        sheet.tapNote(note)
        sheet.setNoteWordDraft("two words")
        sheet.commitNoteWord(advance: false)
        #expect(sheet.noteWord?.refusal == "Type one word per note. To type several, use the words box.")
        #expect(sheet.noteWord?.noteID == note)
        #expect(x8Clip(store, clipID)?.lyrics?.text == "one two three four")
        #expect(sheet.text == "one two three four")
    }

    @Test func noteFieldStoresAChangedBoxFirstButNeverRefusedWords() async throws {
        let (sheet, store, clipID, lyrics, _, _) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        sheet.setText("one two three four five six")   // W > N: the planner refuses
        sheet.tapNote(sheet.preview.notes[0].id)
        #expect(lyrics.calls.isEmpty)
        #expect(sheet.noteWord?.canCommit == false)
        #expect(sheet.noteWord?.refusal == sheet.preview.refusal)
        sheet.setText("one two three four")
        sheet.tapNote(sheet.preview.notes[2].id)
        #expect(lyrics.calls == [.init(clipId: clipID, text: "one two three four", language: nil,
                                       undoLabel: SingSheetModel.undoLabel)])
        #expect(x8Clip(store, clipID)?.lyrics?.text == "one two three four")
        #expect(sheet.noteWord?.draft == "three")
        #expect(sheet.noteWord?.canCommit == true)
    }

    // MARK: The language picker (§6.1, the W8-X3b ruling)

    @Test func languagePickerWritesThroughTheLanguageOverloadAsOneUndoStep() async throws {
        let (sheet, store, clipID, lyrics, _, _) = try makeX8Sheet(lyrics: "one two three four")
        await sheet.open(clipID: clipID)
        #expect(sheet.languageTitle == "English")
        sheet.setLanguage(LyricLanguage.mandarin)
        #expect(lyrics.calls == [.init(clipId: clipID, text: "one two three four", language: "zh",
                                       undoLabel: SingSheetModel.undoLabel)])
        #expect(x8Clip(store, clipID)?.lyrics?.language == "zh")
        #expect(sheet.languageTitle == "Chinese (Mandarin)")
        #expect(store.undoLabel == SingSheetModel.undoLabel)
        try store.undo()
        #expect(x8Clip(store, clipID)?.lyrics?.language == nil)
        #expect(x8Clip(store, clipID)?.lyrics?.text == "one two three four")
    }

    @Test func clearingAndRetypingKeepsThePickedLanguage() async throws {
        let (sheet, store, clipID, lyrics, _, jobs) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        // Nothing stored yet: the pick writes nothing and waits on the sheet.
        sheet.setLanguage(LyricLanguage.cantonese)
        #expect(lyrics.calls.isEmpty)
        sheet.setText("我爱你们")
        #expect(sheet.preview.refusal == nil)
        await sheet.singIt()
        #expect(lyrics.calls.last?.language == "yue")
        #expect(x8Clip(store, clipID)?.lyrics?.language == "yue")
        // Clear the box (blank text clears the stored lyrics, language and all) and type again.
        await sheet.open(clipID: clipID)
        #expect(sheet.languageTitle == "Chinese (Cantonese)")
        sheet.setText("")
        sheet.setText("你好你好")
        await sheet.singIt()
        #expect(lyrics.calls.last == .init(clipId: clipID, text: "你好你好", language: "yue",
                                           undoLabel: SingSheetModel.undoLabel))
        #expect(x8Clip(store, clipID)?.lyrics?.language == "yue")
        #expect(await jobs.submitted.count == 2)
    }

    @Test func chineseInAnEnglishClipGetsTheSection67Sentence() async throws {
        let (sheet, _, clipID, _, _, _) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        sheet.setText("我爱你们")
        #expect(sheet.preview.refusal == LyricLanguage.Copy.scriptMismatch)
        #expect(!sheet.canSing)
        sheet.setLanguage(LyricLanguage.mandarin)
        #expect(sheet.preview.refusal == nil)
        #expect(sheet.canSing)
    }

    // MARK: The playback glow (§8.2)

    @Test func playbackGlowNeverDerivesPerFrame() async throws {
        let (sheet, store, clipID, _, _, _) = try makeX8Sheet(lyrics: "one two three four")
        await sheet.open(clipID: clipID)
        let derived = sheet.derivationCount
        #expect(derived >= 1)
        #expect(sheet.playingChipID == nil)   // stopped: no glow
        store.play()
        defer { store.stop() }
        var seen: [Int?] = []
        for frame in 0..<40 {
            let beat = Double(frame) * 0.1 + 0.05
            try store.seek(toBeats: beat)
            seen.append(sheet.playingChipID)
            #expect(sheet.playingChipID == Int(beat), "frame \(frame) at beat \(beat)")
        }
        #expect(Set(seen.compactMap { $0 }) == [0, 1, 2, 3])
        #expect(sheet.derivationCount == derived, "the glow derived the words again during playback")
        store.stop()
        #expect(sheet.playingChipID == nil)
        // A text change IS a derivation (the control: the counter can move).
        sheet.setText("one two three")
        #expect(sheet.derivationCount == derived + 1)
    }

    // MARK: Singing without words (§8.1)

    @Test func wordlessWritesTextThroughTheSameStoreCall() async throws {
        let (sheet, store, clipID, lyrics, _, _) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        #expect(sheet.wordlessOffered)
        let clip = try #require(x8Clip(store, clipID))
        sheet.singWordless(.ooh)
        let expected = WordlessLyrics.text(for: clip, sound: .ooh, perNote: false)
        #expect(lyrics.calls == [.init(clipId: clipID, text: expected, language: nil,
                                       undoLabel: SingSheetModel.undoLabel)])
        #expect(sheet.text == expected)
        #expect(x8Clip(store, clipID)?.lyrics?.text == expected)
        #expect(store.undoLabel == SingSheetModel.undoLabel)
        #expect(sheet.wordlessOffered)   // switching sounds stays one click
        sheet.setWordlessPerNote(true)
        sheet.singWordless(.aah)
        #expect(sheet.text == WordlessLyrics.text(for: clip, sound: .aah, perNote: true))
        #expect(sheet.text == "aah aah aah aah")
        try store.undo()
        #expect(x8Clip(store, clipID)?.lyrics?.text == expected)
        sheet.setText("hello there")
        #expect(!sheet.wordlessOffered)
    }

    // MARK: The Expression card (§5.1)

    @Test func expressionVibratoForTheWholeVocalIsOneStyleWrite() async throws {
        let (sheet, store, clipID, _, styles, _) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        let card = sheet.expression
        #expect(!card.isExpanded)
        // W9-PICKS (round V): nothing chosen sings the default vibrato, Normal, and the closed line says so.
        #expect(card.summary == "Style: Vibrato Normal")
        #expect(card.vibrato == .normal)
        card.toggleExpanded()
        card.setVibrato(.wide)
        #expect(styles.edits == [SingStyleEdit(vibrato: .wide)])
        #expect(x8Clip(store, clipID)?.singStyle?.vibrato == .wide)
        #expect(card.vibrato == .wide)
        #expect(card.summary == "Style: Vibrato Wide")
        #expect(store.undoLabel == ProjectStore.setSingStyleUndoLabel)
        try store.undo()
        #expect(x8Clip(store, clipID)?.singStyle == nil)
    }

    @Test func expressionPerNoteCarriesTheOtherChoiceAndShowsADot() async throws {
        let (sheet, store, clipID, _, styles, _) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        let note = sheet.preview.notes[0].id
        try store.setSingStyle(clipId: clipID, edit: SingStyleEdit(notes: [
            NoteSingStyleEdit(noteID: note, style: NoteSingStyle(air: 0.5))]))
        let card = sheet.expression
        card.toggleExpanded()
        sheet.tapNote(note)   // the card is open: a click picks the note (no note field)
        #expect(sheet.noteWord == nil)
        #expect(card.selectionLine == "1 note selected")
        card.setVibrato(.gentle)
        #expect(styles.edits.last == SingStyleEdit(notes: [
            NoteSingStyleEdit(noteID: note, style: NoteSingStyle(vibrato: .gentle, air: 0.5))]))
        // The slider writes once, on release, and keeps the note's vibrato.
        card.dragAir(0.8)
        card.dragAir(0.9)
        #expect(styles.edits.count == 1)
        card.commitAir()
        #expect(styles.edits.count == 2)
        #expect(styles.edits.last == SingStyleEdit(notes: [
            NoteSingStyleEdit(noteID: note, style: NoteSingStyle(vibrato: .gentle, air: 0.9))]))
        #expect(x8Clip(store, clipID)?.singStyle?.notes?[note] == NoteSingStyle(vibrato: .gentle, air: 0.9))
        #expect(card.notesWithOwnSetting == [note])
        // The loudness toggle is the whole vocal's: dark with its reason while notes are picked.
        #expect(card.followDisabledReason == SingCopy.followLoudnessIsClipWide)
        card.setFollowVelocity(true)
        #expect(styles.edits.count == 2)
        card.clearSelection()
        #expect(card.followDisabledReason == nil)
        card.setFollowVelocity(true)
        #expect(styles.edits.last == SingStyleEdit(followVelocity: true))
    }

    @Test func expressionLooperRefusalIsShownInItsOwnWords() async throws {
        let (sheet, store, clipID, _, styles, _) = try makeX8Sheet()
        await sheet.open(clipID: clipID)
        // The store refuses per-note choices on a loop layer still being recorded (`SingStyleRefusal.loopLayerNotes`,
        // ProjectStore+SingStyle.swift's throw); the spy stands in for the loop deck.
        styles.refusal = .loopLayerNotes
        let card = sheet.expression
        card.toggleExpanded()
        card.toggleNote(sheet.preview.notes[1].id)
        card.setVibrato(.wide)
        #expect(card.refusal == SingStyleRefusal.loopLayerNotes.sentence)
        #expect(x8Clip(store, clipID)?.singStyle == nil)
    }

    // MARK: The Harmony card (§4.1) and [Sing it] with parts

    @Test func singItWithPartsIsOneJobCarryingTheParts() async throws {
        let (sheet, _, clipID, _, _, jobs) = try makeX8Sheet(pitches: [60, 62, 64, 65, 67, 65, 64, 62],
                                                              lyrics: "one two three four five six sev en")
        await sheet.open(clipID: clipID)
        #expect(!sheet.harmonyChoices.contains(.chordNotes))   // no chords under this tune
        let key = SongKey(tonicPitchClass: 0, mode: .major)
        sheet.setHarmonyKey(key)
        sheet.addHarmony(.thirdAbove)
        sheet.addHarmony(.sixthBelow)
        #expect(sheet.harmonyRows.map(\.name) == ["third above", "sixth below"])
        #expect(sheet.harmonyRows.allSatisfy { $0.refusal == nil })
        #expect(sheet.harmonyRows.allSatisfy { $0.voiceName == SingJobVoice.builtInName })
        #expect(sheet.harmonyKey == .given(key))
        sheet.addHarmony(.thirdBelow)
        #expect(sheet.addHarmonyDisabledReason == "You can add up to 3 harmony parts.")
        sheet.addHarmony(.thirdAbove)   // a fourth is not added
        #expect(sheet.harmonyParts.count == 3)
        sheet.removeHarmony(sheet.harmonyParts[2].id)
        #expect(sheet.addHarmonyDisabledReason == nil)
        #expect(sheet.canSing)
        await sheet.singIt()
        let submitted = await jobs.submitted
        #expect(submitted.count == 1)   // ONE job: the lead and its parts
        #expect(submitted.first?.parts == [SingJobPart(SingHarmonyChoice.thirdAbove.kind),
                                           SingJobPart(SingHarmonyChoice.sixthBelow.kind)])
        #expect(submitted.first?.key == key)
        #expect(submitted.first?.clipID == clipID)
    }

    @Test func harmonyWithAnUnknownKeyDarkensSingItWithTheSection14Sentence() async throws {
        // Twelve notes, one of each pitch class: no key can be heard in it.
        let (sheet, store, clipID, _, _, jobs) = try makeX8Sheet(pitches: Array(60...71),
                                                                  lyrics: "a b c d e f g h i j k l")
        #expect(throws: HarmonyRefusal.needsKey) {
            _ = try HarmonyPlanner.resolveKey(given: nil, tracks: store.tracks, tempoMap: store.transport.tempoMap)
        }
        await sheet.open(clipID: clipID)
        sheet.addHarmony(.thirdAbove)
        #expect(sheet.harmonyKey == .unknown)
        #expect(sheet.harmonyRows.first?.refusal == HarmonyRefusal.needsKey.sentence)
        #expect(sheet.singItDisabledReason == HarmonyRefusal.needsKey.sentence)
        #expect(!sheet.canSing)
        await sheet.singIt()
        #expect(await jobs.submitted.isEmpty)
        sheet.setHarmonyKey(SongKey(tonicPitchClass: 2, mode: .minor))
        #expect(sheet.harmonyRows.first?.refusal == nil)
        #expect(sheet.canSing)
    }

    @Test func chordNotesAreOfferedWhenTheTuneHasChords() async throws {
        // A C major chord under the first melody note (72 on top of 64 and 67).
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let notes = [72, 74, 76, 77].enumerated().map { i, p in MIDINote(pitch: p, startBeat: Double(i), lengthBeats: 1) }
            + [MIDINote(pitch: 64, startBeat: 0), MIDINote(pitch: 67, startBeat: 0)]
        let clipID = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: 4,
                                           notes: notes).id
        let sheet = SingSheetModel(store: store, lyrics: SingLyricsSpy(store: store), transposer: store,
                                   jobs: SingFakeJobs(),
                                   engineStatus: { SingingSidecarStatus(state: .healthy, message: "ok") },
                                   library: nil)
        await sheet.open(clipID: clipID)
        #expect(sheet.tuneHasChords)
        #expect(sheet.harmonyChoices.last == .chordNotes)
        sheet.addHarmony(.chordNotes)
        #expect(sheet.harmonyRows.first?.name == SingJobCoordinator.Copy.chordNotesPartName)
    }

    // MARK: The unified progress card's sing rows (§5.5 [Cancel] + ETA)

    @Test func progressCardSingRowShowsTheETAAndCancelsThroughTheCoordinator() async throws {
        let jobs = SingFakeJobs()
        let take = SingTakeModel(jobs: jobs)
        // An AGENT's job: not this card's take, and still reachable.
        await jobs.hold(try SingStaging.status(phase: .singing, stageText: SingJobCoordinator.Copy.singing(line: 3, of: 8),
                                               jobID: "sing-agent-1", unitIndex: 3, unitCount: 8, progress: 0.4,
                                               etaSeconds: 65, fromAgent: true))
        await take.refreshLive(jobIDs: ["sing-agent-1", "ace-song-9"])
        #expect(take.liveStatuses.keys.sorted() == ["sing-agent-1"])   // a song row is never read here
        let row = try #require(take.liveRow(jobID: "sing-agent-1"))
        #expect(row.eta == "about 1:05 left")
        #expect(row.cancelTitle == SingCopy.cancel)
        #expect(row.cancelEnabled)
        await take.cancel(jobID: "sing-agent-1")
        #expect(await jobs.cancelled == ["sing-agent-1"])
        let after = try #require(take.liveRow(jobID: "sing-agent-1"))
        #expect(after.cancelTitle == SingJobCoordinator.Copy.stopping)
        #expect(!after.cancelEnabled)
        await take.refreshLive(jobIDs: [])
        #expect(take.liveStatuses.isEmpty)
    }

    @Test func progressCardShowsARefusedCancelInItsOwnWords() async throws {
        let jobs = SingFakeJobs()
        let take = SingTakeModel(jobs: jobs)
        let request = SingJobRequest(clipID: UUID())
        let first = try await jobs.submit(request)
        take.track(first, request: request)
        await jobs.refuseCancel(.jobFinished(first.jobID))
        await take.cancel()
        let words = SingJobError.jobFinished(first.jobID).errorDescription
        #expect(take.cancelRefusals[first.jobID] == words)
        #expect(take.refusal == words)
        #expect(words?.contains("nothing to stop") == true)
    }

    @Test func styledTakeTipShowsOnlyForAStyledMelody() throws {
        let take = SingTakeModel(jobs: SingFakeJobs())
        let clipID = UUID()
        let landed = try SingStaging.status(phase: .done, stageText: SingJobCoordinator.Copy.landed, clipID: clipID,
                                            landedTrackID: UUID(), landedClipID: UUID())
        take.stageForCapture(landed, request: SingJobRequest(clipID: clipID))
        #expect(take.styledTakeTip == nil)   // no probe: no tip
        take.styleProbe = { $0 == clipID }
        #expect(take.styledTakeTip == SingCopy.afterStyledTake)
        take.styleProbe = { _ in false }
        #expect(take.styledTakeTip == nil)
    }

    /// W9-PICKSF: the tip agrees with what the singer sings under the default vibrato (`isNoOp`), both ways.
    @Test func styleTipAsksWhatTheSingerWillSing() {
        #expect(SingTakeModel.styleIsHeard(nil), "no style is sung with the default Medium vibrato")
        #expect(SingTakeModel.styleIsHeard(SingStyle(vibrato: .normal)))
        #expect(SingTakeModel.styleIsHeard(SingStyle(vibrato: .wide)))
        #expect(SingTakeModel.styleIsHeard(SingStyle(vibrato: .straight, air: 0.4)))
        #expect(!SingTakeModel.styleIsHeard(SingStyle(vibrato: .asSung)), "a chosen 'as sung' adds nothing")
        #expect(SingTakeModel.styleIsHeard(SingStyle(vibrato: .asSung, air: 0.4)))
        for style in [nil, SingStyle(vibrato: .asSung), SingStyle(vibrato: .normal), SingStyle(vibrato: .straight, air: 0.4)] {
            #expect(SingTakeModel.styleIsHeard(style) == !SungExpressionPlanner.isNoOp(style: style))
        }
    }

    // MARK: Part B: the install pre-check and "Write words for me"

    @Test func installPreCheckRefusesBeforeTheBrokerHearsAnythingAndOnTryAgain() async throws {
        let broker = SingConsentBroker(autoConsent: false)
        let calls = LockedBox<Int>(0)
        let mac = LockedBox<SingInstallPreflight.Host>(SingInstallPreflight.Host(isAppleSilicon: false,
                                                                                isMacOS14OrLater: true))
        let consent = SingConsentModel(
            broker: broker,
            install: SingingEngineInstallCoordinator(installFunction: { _ in .succeeded(installedBytes: 1) }),
            preflight: {
                calls.value += 1
                return SingInstallPreflight.check(host: mac.value, needBytes: 1, freeBytes: nil)
            })
        broker.onRequest = { consent.present($0) }
        // The sheet's path: no engine → ask for consent.
        let (sheet, _, clipID, lyrics, _, jobs) = try makeX8Sheet(engine: .notInstalled)
        sheet.onNeedsInstall = { await consent.ask(.installEngine) }
        await sheet.open(clipID: clipID)
        sheet.setText("one two three four")
        await sheet.singIt()
        #expect(calls.value == 1)
        #expect(broker.pending.isEmpty)
        #expect(consent.phase == .finished(message: SingInstallPreflight.Copy.unsupportedMac.sentence,
                                           retry: .installEngine))
        #expect(lyrics.calls.isEmpty)
        #expect(await jobs.submitted.isEmpty)
        // [Try again] checks again; still refused.
        await consent.tryAgain()
        #expect(calls.value == 2)
        #expect(broker.pending.isEmpty)
        // The Mac passes now: the request reaches the broker.
        mac.value = SingInstallPreflight.Host(isAppleSilicon: true, isMacOS14OrLater: true)
        await consent.tryAgain()
        #expect(calls.value == 3)
        #expect(broker.pending.count == 1)
        #expect(consent.cardText?.body == SingCopy.installCardBody)
        // An uninstall is never pre-checked.
        consent.notNow()
        await consent.ask(.uninstallEngine)
        #expect(calls.value == 3)
    }

    @Test func writeWordsPutsTheWordsInTheBoxAndStoresNothing() async throws {
        let reply = "la la la la"
        let writer = SingFakeWriter(replies: [reply])
        let (sheet, store, clipID, lyrics, _, _) = try makeX8Sheet(writer: writer)
        let clip = try #require(x8Clip(store, clipID))
        #expect(LyricsFit.check(reply, clip: clip, language: nil, tempoMap: store.transport.tempoMap).allFit)
        await sheet.open(clipID: clipID)
        #expect(sheet.canWriteWords)
        sheet.openWriteWords()
        #expect(sheet.writeWordsDisabledReason == SingCopy.writeWordsThemePlaceholder)
        sheet.setWriteWordsTheme("rain on a window")
        await sheet.writeWordsForMe()
        #expect(sheet.text == reply)
        #expect(sheet.writeWords.notice == nil)
        #expect(!sheet.writeWords.isOpen)
        #expect(x8Clip(store, clipID)?.lyrics == nil)   // §8.3: it does NOT store
        #expect(lyrics.calls.isEmpty)
        let asked = await writer.requests
        #expect(asked.count == 1)
        #expect(asked.first?.prompt == "rain on a window")
        #expect(asked.first?.fit?.phrases.map(\.notes) == [4])
    }

    @Test func writeWordsNamesTheLinesThatStillDoNotFit() async throws {
        let long = "one two three four five six seven"
        let writer = SingFakeWriter(replies: [long, long])
        let (sheet, store, clipID, _, _, _) = try makeX8Sheet(writer: writer)
        await sheet.open(clipID: clipID)
        sheet.openWriteWords()
        sheet.setWriteWordsTheme("a long day")
        await sheet.writeWordsForMe()
        #expect(await writer.requests.count == 2)   // checked, then asked once more
        #expect(sheet.writeWords.notice == LyricsFit.Copy.notFit(lines: [1]))
        #expect(sheet.writeWords.notice == "Some lines didn't fit the tune: 1. Edit them, or try again.")
        #expect(sheet.text == long)
        #expect(x8Clip(store, clipID)?.lyrics == nil)
    }

    // MARK: vf-2: the strip's pick, through the lane layout (W10-PRWD)

    /// The Expression card's note pick still lands on the same notes after the strip adopted the piano roll's Words-lane
    /// layout (vf-2): a click on any word, hyphen PART or dot resolves (`SingWordStripLayout.target`) to its chip, and
    /// the chip picks its word's FIRST note — what a click on the old stretched chip picked; a click on a note's column
    /// picks that note. Through the model's own `tapChip` / `tapNote`, the calls the strip makes.
    @Test func expressionPickThroughSingWordStripLayoutPicksTheSameNotes() async throws {
        let (sheet, _, clipID, _, _, _) = try makeX8Sheet(pitches: [60, 62, 64, 65, 67],
                                                          lyrics: "twin-kle lit-tle star")
        await sheet.open(clipID: clipID)
        let preview = sheet.preview
        let layout = SingWordStripLayout(preview: preview, visibleWidth: 520, textWidths: [:])
        #expect(layout.items.filter { $0.kind == .part }.count == 4, "positive control: the parts are drawn")
        let card = sheet.expression
        card.toggleExpanded()
        for item in layout.items {
            let point = CGPoint(x: item.x + item.width / 2, y: PianoRollWordLane.rowTop(item.row) + 2)
            guard case .word(let chipID)? = layout.target(at: point) else {
                Issue.record("'\(item.text)' did not resolve to its chip")
                continue
            }
            let first = try #require(preview.chips[chipID].noteIDs.first)
            card.clearSelection()
            sheet.tapChip(chipID)
            #expect(card.selectedNoteIDs == [first], "'\(item.text)'")
            #expect(sheet.noteWord == nil, "the card is open: a click picks, it opens no field")
        }
        for note in layout.noteFrames {
            let point = CGPoint(x: note.rect.minX + 1, y: SingWordStripLayout.barTop + 6)
            guard case .note(let noteID)? = layout.target(at: point) else {
                Issue.record("a note's column did not resolve to a note")
                continue
            }
            #expect(noteID == note.id)
            card.clearSelection()
            sheet.tapNote(noteID)
            #expect(card.selectedNoteIDs == [note.id])
        }
    }
}
