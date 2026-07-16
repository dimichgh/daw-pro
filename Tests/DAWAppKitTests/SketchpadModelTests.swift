import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWAppKit

/// Headless tests for the M6 (iii-b) Sketchpad state machine: the generate →
/// poll → import lifecycle, the failed-poll TOLERANCE rule (a transient poll
/// error marks the candidate stale but never kills it), the sidecar banner
/// surface, the duration stepper clamp, and the lyrics section helper. Drives
/// `SketchpadModel` against a scripted fake `SongGenerating` and a fake importer
/// — no window, no engine, no network (the `TakeLaneModel`/`MixerModel`
/// precedent).
@MainActor
@Suite struct SketchpadModelTests {

    // MARK: - Fakes

    /// A scriptable `SongGenerating`: `generateSong` hands back queued jobs (or
    /// throws `submitError`); `generationStatus` returns the next scripted
    /// response for a job, throwing `StubError` to simulate a transient network
    /// blip. An actor so it's `Sendable` and safe across the model's awaits.
    actor FakeGenerator: SongGenerating {
        struct StubError: Error, LocalizedError { var errorDescription: String? }

        var submitError: Error?
        private var counter = 0
        /// jobID → FIFO queue of scripted poll outcomes.
        private var scripts: [String: [Result<SongGenerationStatus, Error>]] = [:]
        /// The last status returned once a job's script is exhausted (so extra
        /// polls keep seeing the terminal state).
        private var sticky: [String: Result<SongGenerationStatus, Error>] = [:]

        func setSubmitError(_ error: Error?) { submitError = error }

        /// Registers the outcomes a job will yield across successive polls.
        func script(_ jobID: String, _ outcomes: [Result<SongGenerationStatus, Error>]) {
            scripts[jobID] = outcomes
        }

        func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
            if let submitError { throw submitError }
            counter += 1
            return SongGenerationSubmission(jobID: "job-\(counter)", state: .queued, queuePosition: 1)
        }

        func generationStatus(jobID: String) async throws -> SongGenerationStatus {
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
            // Unknown job.
            throw StubError(errorDescription: "job \(jobID) not found or expired")
        }

        // Sketchpad doesn't drive stems/Lego (M6 iii-c) — not exercised here,
        // just needed for protocol conformance.
        func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
            throw StubError(errorDescription: "not used by SketchpadModel")
        }

        func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
            throw StubError(errorDescription: "not used by SketchpadModel")
        }
    }

    private func succeededStatus(_ jobID: String, audioPath: String = "/tmp/x.wav",
                                 bpm: Double? = 120) -> SongGenerationStatus {
        SongGenerationStatus(jobID: jobID, state: .succeeded, progress: 1, statusText: "done",
                             audioPath: audioPath, bpm: bpm, durationSeconds: 30)
    }
    private func runningStatus(_ jobID: String, progress: Double) -> SongGenerationStatus {
        SongGenerationStatus(jobID: jobID, state: .running, progress: progress, statusText: "step")
    }

    private func healthyModel(_ gen: FakeGenerator,
                              importer: @escaping @MainActor (String) async throws -> SketchpadImportResult
                                = { _ in SketchpadImportResult(trackID: UUID(), trackName: "AI") })
    -> SketchpadModel {
        let model = SketchpadModel(generator: gen, importer: importer)
        model.updateSidecar(SidecarStatus(state: .healthy, message: "running"))
        return model
    }

    // MARK: - Generate

    @Test func generateAppendsAQueuedCandidate() async {
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "lofi chillhop, mellow keys"
        await model.generate()
        #expect(model.candidates.count == 1)
        #expect(model.candidates[0].state == .queued)
        #expect(model.candidates[0].jobID == "job-1")
        #expect(model.candidates[0].promptSnippet == "lofi chillhop, mellow keys")
    }

    @Test func generateSubmitFailureAppendsAFailedCandidate() async {
        let gen = FakeGenerator()
        await gen.setSubmitError(FakeGenerator.StubError(errorDescription: "sidecar unreachable"))
        let model = healthyModel(gen)
        model.prompt = "anything"
        await model.generate()
        #expect(model.candidates.count == 1)
        if case .failed(let message) = model.candidates[0].state {
            #expect(message == "sidecar unreachable")
        } else {
            Issue.record("expected a failed candidate, got \(model.candidates[0].state)")
        }
    }

    // MARK: - Poll transitions

    @Test func refreshMovesQueuedThroughRunningToSucceeded() async {
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [
            .success(runningStatus(job, progress: 0.4)),
            .success(succeededStatus(job, bpm: 92)),
        ])

        await model.refresh()
        if case .running(let p, _) = model.candidates[0].state {
            #expect(p == 0.4)
        } else { Issue.record("expected running, got \(model.candidates[0].state)") }
        #expect(model.hasActiveCandidates)

        await model.refresh()
        if case .succeeded(let path, let bpm, _) = model.candidates[0].state {
            #expect(path == "/tmp/x.wav")
            #expect(bpm == 92)
        } else { Issue.record("expected succeeded, got \(model.candidates[0].state)") }
        #expect(!model.hasActiveCandidates)
    }

    @Test func succeededWithoutAudioPathStaysRunning() async {
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [.success(succeededStatus(job, audioPath: ""))])
        await model.refresh()
        #expect(model.candidates[0].state.isActive)   // no path yet → still working
    }

    @Test func failedStateFromPollMarksCandidateFailed() async {
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [
            .success(SongGenerationStatus(jobID: job, state: .failed, statusText: "out of memory")),
        ])
        await model.refresh()
        if case .failed(let message) = model.candidates[0].state {
            #expect(message == "out of memory")
        } else { Issue.record("expected failed, got \(model.candidates[0].state)") }
        #expect(!model.hasActiveCandidates)
    }

    // MARK: - Failed-poll tolerance (the key rule)

    @Test func transientPollErrorMarksStaleButKeepsPolling() async {
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [
            .success(runningStatus(job, progress: 0.5)),
            .failure(FakeGenerator.StubError(errorDescription: "connection reset")),
            .success(succeededStatus(job)),
        ])

        await model.refresh()   // running
        #expect(!model.candidates[0].isStale)

        await model.refresh()   // transient blip
        #expect(model.candidates[0].isStale, "a poll throw must mark stale, not kill")
        #expect(model.candidates[0].state.isActive, "the candidate survives the blip")
        if case .running = model.candidates[0].state {} else {
            Issue.record("state must be preserved across a transient error, got \(model.candidates[0].state)")
        }

        await model.refresh()   // recovers → succeeded, stale cleared
        #expect(!model.candidates[0].isStale)
        if case .succeeded = model.candidates[0].state {} else {
            Issue.record("expected recovery to succeeded, got \(model.candidates[0].state)")
        }
    }

    @Test func terminalPollThrowFlipsTheCandidateToFailedWithTheWorkerMessage() async {
        // m17-h honesty fix: the REAL client surfaces an upstream failure by
        // THROWING `ACEStepError.jobFailed` (never returning a `.failed`
        // status), and before this mapping a genuinely failed job sat in
        // "reconnecting" forever — the exact "user does not know if it failed"
        // complaint. The worker's message must land verbatim.
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [
            .failure(ACEStepError.jobFailed(jobID: job, message: "CUDA out of memory on step 6")),
        ])
        await model.refresh()
        if case .failed(let message) = model.candidates[0].state {
            #expect(message == "CUDA out of memory on step 6")
        } else {
            Issue.record("expected failed, got \(model.candidates[0].state)")
        }
        #expect(!model.candidates[0].isStale, "terminal failure is not a transient blip")
        #expect(!model.hasActiveCandidates)
    }

    @Test func jobNotFoundPollThrowIsTerminalToo() async {
        // An expired/lost job (sidecar restarted, ~24h retention) must read as
        // failed, not poll forever.
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [.failure(ACEStepError.jobNotFound(job))])
        await model.refresh()
        if case .failed(let message) = model.candidates[0].state {
            #expect(message.contains(job))
        } else {
            Issue.record("expected failed, got \(model.candidates[0].state)")
        }
    }

    @Test func refreshOnlyPollsActiveCandidates() async {
        // A succeeded (terminal) candidate must not be re-polled back into flux.
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [.success(succeededStatus(job))])
        await model.refresh()
        #expect(!model.candidates[0].state.isActive)
        // Even if the job later starts throwing, a terminal candidate is untouched.
        await gen.script(job, [.failure(FakeGenerator.StubError(errorDescription: "gone"))])
        await model.refresh()
        if case .succeeded = model.candidates[0].state {} else {
            Issue.record("terminal candidate must not be re-polled, got \(model.candidates[0].state)")
        }
        #expect(!model.candidates[0].isStale)
    }

    // MARK: - Import wiring

    @Test func importSucceededCandidateFlipsToImportedWithTrackName() async {
        let gen = FakeGenerator()
        let importedTrackID = UUID()
        var importedJob: String?
        let model = healthyModel(gen, importer: { job in
            importedJob = job
            return SketchpadImportResult(trackID: importedTrackID, trackName: "AI: lofi chillhop")
        })
        model.prompt = "lofi"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [.success(succeededStatus(job))])
        await model.refresh()

        await model.importCandidate(model.candidates[0].id)
        #expect(importedJob == job)
        if case .imported(let tid, let name) = model.candidates[0].state {
            #expect(tid == importedTrackID)
            #expect(name == "AI: lofi chillhop")
        } else { Issue.record("expected imported, got \(model.candidates[0].state)") }
        #expect(!model.hasActiveCandidates)
    }

    @Test func importIsNoOpForNonSucceededCandidate() async {
        let gen = FakeGenerator()
        var called = false
        let model = healthyModel(gen, importer: { _ in
            called = true
            return SketchpadImportResult(trackID: UUID(), trackName: "x")
        })
        model.prompt = "x"
        await model.generate()   // candidate is .queued
        await model.importCandidate(model.candidates[0].id)
        #expect(!called)
        #expect(model.candidates[0].state == .queued)
    }

    @Test func importFailureMarksStaleAndKeepsSucceeded() async {
        struct Boom: Error {}
        let gen = FakeGenerator()
        let model = healthyModel(gen, importer: { _ in throw Boom() })
        model.prompt = "x"
        await model.generate()
        let job = model.candidates[0].jobID
        await gen.script(job, [.success(succeededStatus(job))])
        await model.refresh()
        await model.importCandidate(model.candidates[0].id)
        #expect(model.candidates[0].isStale)
        if case .succeeded = model.candidates[0].state {} else {
            Issue.record("import failure must leave the audio importable, got \(model.candidates[0].state)")
        }
    }

    @Test func dismissRemovesTheRow() async {
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        let id = model.candidates[0].id
        model.dismissCandidate(id)
        #expect(model.candidates.isEmpty)
    }

    // MARK: - Sidecar banner + canGenerate

    @Test func healthySidecarWithPromptCanGenerateAndHasNoBanner() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        #expect(model.banner?.message == "Checking the AI generator…")   // nil status
        #expect(!model.canGenerate)
        model.updateSidecar(SidecarStatus(state: .healthy, message: "running"))
        #expect(model.banner == nil)
        #expect(!model.canGenerate)                                       // no prompt yet
        model.prompt = "   "
        #expect(!model.canGenerate)                                       // blank prompt
        model.prompt = "warm pads"
        #expect(model.canGenerate)
    }

    @Test func notRunningSidecarOffersStartAndArmsAutoStartGenerate() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.prompt = "warm pads"
        model.updateSidecar(SidecarStatus(state: .installedNotRunning,
                                          message: "ACE-Step is installed but not running — call ai.sidecarStart."))
        // m17-h auto-start: an installed-but-stopped sidecar no longer blocks
        // Generate — the observing generator boots it on submit and the
        // progress card narrates the boot. The banner + Start button remain.
        #expect(model.canGenerate == true)
        let banner = model.banner
        #expect(banner?.canStartSidecar == true)
        #expect(banner?.tone == .warning)
        // The banner translates to user-speak; the wire message (agent-facing
        // "call ai.sidecarStart") must never reach this surface.
        #expect(banner?.message == "The AI generator is not running — Generate will start it for you, "
            + "or press Start to launch it now.")
        #expect(banner?.message.contains("ai.sidecarStart") == false)
    }

    @Test func notInstalledAndErrorStatesStillBlockGenerate() {
        // Auto-start can't fix a missing install or a broken sidecar — the
        // m17-h arming stops at exactly those states.
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.prompt = "warm pads"
        model.updateSidecar(SidecarStatus(state: .notInstalled, message: "run install.sh"))
        #expect(model.canGenerate == false)
        model.updateSidecar(SidecarStatus(state: .error, message: "bad /health payload"))
        #expect(model.canGenerate == false)
    }

    @Test func notInstalledAndErrorBannersDoNotOfferStart() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.updateSidecar(SidecarStatus(state: .notInstalled, message: "run install.sh"))
        #expect(model.banner?.canStartSidecar == false)
        #expect(model.banner?.message == "run install.sh")
        model.updateSidecar(SidecarStatus(state: .error, message: "crashed on load"))
        #expect(model.banner?.tone == .error)
        #expect(model.banner?.canStartSidecar == false)
    }

    // MARK: - M10-b: the `.starting` banner (spinner + phase + elapsed)

    @Test func startingWithPhaseComposesPhaseAndElapsedIntoTheMessage() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.updateSidecar(SidecarStatus(
            state: .starting,
            message: "ACE-Step sidecar is starting — loading models… (42s so far). Poll again.",
            phase: "loading models…",
            startingForSeconds: 42))

        let banner = model.banner
        #expect(banner?.tone == .progress)
        #expect(banner?.isInProgress == true)
        #expect(banner?.canStartSidecar == false)   // never re-offered while a boot is in flight
        #expect(banner?.message == "Starting — loading models… (42s)")
    }

    @Test func startingWithoutPhaseStillShowsElapsedProgress() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.updateSidecar(SidecarStatus(
            state: .starting, message: "ACE-Step sidecar is starting (7s so far).",
            phase: nil, startingForSeconds: 7))

        let banner = model.banner
        #expect(banner?.tone == .progress)
        #expect(banner?.isInProgress == true)
        #expect(banner?.canStartSidecar == false)
        #expect(banner?.message == "Starting… (7s)")
    }

    @Test func startingWithoutElapsedFallsBackToTheRawStatusMessage() {
        // e.g. a dry-run `SidecarStatus` that never populated the M10-b
        // elapsed/phase fields — the banner must still read as in-progress,
        // just without a fabricated elapsed counter.
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.updateSidecar(SidecarStatus(
            state: .starting, message: "[dry-run] would spawn: /bin/bash run.sh"))

        let banner = model.banner
        #expect(banner?.tone == .progress)
        #expect(banner?.isInProgress == true)
        #expect(banner?.canStartSidecar == false)
        #expect(banner?.message == "[dry-run] would spawn: /bin/bash run.sh")
    }

    @Test func startingBannerKeepsGenerateArmedForTheAutoStartPath() {
        // m17-h: a boot in flight no longer disarms Generate — the observing
        // generator's submit waits through the boot (awaitsBoot) and the
        // progress card narrates it. Pre-m17-h this pinned canGenerate false.
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.prompt = "warm pads"
        model.updateSidecar(SidecarStatus(
            state: .starting, message: "starting", phase: "loading models…", startingForSeconds: 5))
        #expect(model.canGenerate == true)
    }

    // MARK: - Duration stepper

    @Test func durationClampsToRange() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        #expect(model.durationSeconds == 30)
        model.setDurationSeconds(5)
        #expect(model.durationSeconds == 15)
        model.setDurationSeconds(9999)
        #expect(model.durationSeconds == 240)
        model.setDurationSeconds(60)
        model.nudgeDuration(by: -SketchpadModel.durationStep)
        #expect(model.durationSeconds == 55)
        model.setDurationSeconds(238)
        model.nudgeDuration(by: SketchpadModel.durationStep)
        #expect(model.durationSeconds == 240)      // nudge past the ceiling clamps
    }

    // MARK: - Lyrics section helper

    @Test func insertSectionAtStartInsertsBareTagLine() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.insertSection(.verse)
        #expect(model.lyrics == "[verse]\n")
        #expect(model.lyricsCursor == "[verse]\n".count)
    }

    @Test func insertSectionMidTextStartsOnItsOwnLine() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.lyrics = "hello"
        model.lyricsCursor = 5                       // at the end, not on a fresh line
        model.insertSection(.chorus)
        #expect(model.lyrics == "hello\n[chorus]\n")
    }

    @Test func insertSectionAfterNewlineDoesNotDoubleTheNewline() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.lyrics = "line\n"
        model.lyricsCursor = 5                        // already at line start
        model.insertSection(.bridge)
        #expect(model.lyrics == "line\n[bridge]\n")
    }

    @Test func insertSectionClampsAStaleCursor() {
        let model = SketchpadModel(generator: FakeGenerator(),
                                   importer: { _ in SketchpadImportResult(trackID: UUID(), trackName: "x") })
        model.lyrics = "abc"
        model.lyricsCursor = 999                      // beyond the end
        model.insertSection(.outro)
        #expect(model.lyrics == "abc\n[outro]\n")
        #expect(SketchpadSection.allCases.map(\.tag) == ["[verse]", "[chorus]", "[bridge]", "[outro]"])
    }

    // MARK: - Snippet helper

    @Test func snippetTakesLeadingWords() {
        #expect(SketchpadModel.snippet("one two three four five six seven") == "one two three four five six")
        #expect(SketchpadModel.snippet("   ") == "Untitled")
    }

    // MARK: - Capture seeding

    @Test func setCandidatesForCaptureReplacesTheList() async {
        let gen = FakeGenerator()
        let model = healthyModel(gen)
        model.prompt = "x"
        await model.generate()
        model.setCandidatesForCapture([
            SketchpadCandidate(jobID: "a", promptSnippet: "warm pads",
                               state: .running(progress: 0.4, statusText: "step 3/8")),
            SketchpadCandidate(jobID: "b", promptSnippet: "lofi keys",
                               state: .succeeded(audioPath: "/tmp/a.wav", bpm: 92, durationSeconds: 30)),
        ])
        #expect(model.candidates.count == 2)
        #expect(model.candidates[0].jobID == "a")
    }
}
