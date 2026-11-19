import Foundation
import Testing
@testable import AIServices
@testable import DAWCore

// p2-sing-e part 1: `SingJobCoordinator` against a scripted engine and synthesizer, a REAL
// `ModelLifecycleCoordinator` (temp storage, never `.shared`) and a REAL `ProjectStore` (its own temp
// Generations folder). The audio is real: the fake synthesizer writes the WAVs a facade would, and the
// fixtures' pitch tracker reads them back, so the gates and the note check measure the take.
//
// ⚠️ No `Task.cancel()` anywhere: every wait polls (`SingFixture.waitUntil`) or parks on a `SingLatch`
// the test opens.

// MARK: - Fakes

/// A scripted singing sidecar. `start()` mirrors the manager's lifecycle bookkeeping (resolve, commit,
/// admitted) so residency rules see a resident SoulX, and clears the stop classification on a real boot.
actor FakeSingEngine: SingJobEngine {
    enum StartOutcome: Sendable {
        case healthy
        case fails(String)
        case staysStarting
        case admissionRefused
    }

    private(set) var state: SingingSidecarState
    private(set) var startCount = 0
    private var stopReason: SingingStopReason?
    private var pid: Int32 = 4_000
    private var script: [StartOutcome] = []
    private var latch: SingLatch?
    let lifecycle: ModelLifecycleCoordinator

    init(state: SingingSidecarState, lifecycle: ModelLifecycleCoordinator) {
        self.state = state
        self.lifecycle = lifecycle
    }

    func setStartScript(_ outcomes: [StartOutcome]) { script = outcomes }
    func holdStart(_ latch: SingLatch) { self.latch = latch }
    /// A classification left over from an EARLIER stop.
    func setStaleStopReason(_ reason: SingingStopReason?) { stopReason = reason }

    func status() -> SingingSidecarStatus {
        let healthy = state == .healthy
        return SingingSidecarStatus(
            state: state,
            message: state == .notInstalled
                ? "The singing engine isn't installed yet. Open Settings ▸ Singing to install it."
                : "fake engine: \(state)",
            pid: healthy ? pid : nil, facadeVersion: healthy ? 1 : nil, commit: healthy ? "fakecommit" : nil,
            weightsRevision: healthy ? "fakeweights" : nil, weightsBytes: healthy ? 1_234 : nil)
    }

    func start() async throws -> SingingSidecarStatus {
        startCount += 1
        if let latch { self.latch = nil; await latch.wait() }
        let outcome = script.isEmpty ? .healthy : script.removeFirst()
        switch outcome {
        case .healthy:
            let plan = await lifecycle.resolveAdmission(.soulxSinger)
            if let ticket = try await lifecycle.commitAdmission(plan, for: .soulxSinger) {
                await lifecycle.admitted(ticket, healthy: true)
            }
            state = .healthy
            pid += 1
            stopReason = nil                       // the manager clears it on a real boot
        case .fails(let message):
            throw FakeError(message)
        case .staysStarting:
            state = .starting
            return SingingSidecarStatus(state: .starting, message: "The singing engine is still loading.")
        case .admissionRefused:
            throw SidecarError.admissionRefused("Another model is loading right now.")
        }
        return status()
    }

    func lastStopClassification() -> SingingStopReason? { stopReason }

    /// The engine goes away. `reason` nil is a crash: nothing is recorded (an older value stays).
    func goAway(_ reason: SingingStopReason?) async {
        state = .installedNotRunning
        if let reason { stopReason = reason }
        if reason == .evictedByCoordinator {
            // The lifecycle coordinator evicted it, so its own record already reads "not resident".
            await lifecycle.noteStoppedExternally(.soulxSinger)
        }
    }
}

struct FakeError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A scripted synthesizer. Each unit is named by its first sung word ("one", "five"); every call for that
/// unit takes the next step of its script, then `.render(.sine)` forever.
actor FakeSingSynth: SingingSynthesizing {
    enum Step: Sendable {
        case render(SingFixture.Voice, extraSeconds: Double)
        case facadeNonFinite
        case loading
        case refusal(SingingFacadeError)
        case engineGoesAway(SingingStopReason?)

        static func sung(_ voice: SingFixture.Voice) -> Step { .render(voice, extraSeconds: 0) }
    }

    struct Call: Sendable, Equatable {
        var unit: String
        var seed: UInt64
        var outputPath: String
    }

    let engine: FakeSingEngine
    private var script: [String: [Step]] = [:]
    private var latches: [String: SingLatch] = [:]
    private(set) var calls: [Call] = []

    init(engine: FakeSingEngine) { self.engine = engine }

    func plan(_ unit: String, _ steps: [Step]) { script[unit] = steps }
    /// The NEXT call for `unit` parks until `latch` opens.
    func hold(_ unit: String, _ latch: SingLatch) { latches[unit] = latch }
    func calls(for unit: String) -> [Call] { calls.filter { $0.unit == unit } }

    func renderPhrase(_ request: SingingPhraseRequest) async throws -> SingingRenderResult {
        let unit = request.words.first?.text ?? ""
        calls.append(Call(unit: unit, seed: request.seed, outputPath: request.outputPath))
        if let latch = latches.removeValue(forKey: unit) { await latch.wait() }
        var steps = script[unit] ?? []
        let step = steps.isEmpty ? Step.sung(.sine) : steps.removeFirst()
        script[unit] = steps
        switch step {
        case .render(let voice, let extra):
            let samples = SingFixture.render(request, voice: voice, extraSeconds: extra)
            try SingWAV.writeFloat32Mono(samples, sampleRate: request.outputSampleRate,
                                         to: URL(fileURLWithPath: request.outputPath))
            return SingFixture.result(for: request, samples: samples)
        case .facadeNonFinite:
            throw SingingFacadeError.nonFinite("The render came out with non-finite samples.")
        case .loading:
            throw SingingFacadeError.loading("The singing model is still loading.")
        case .refusal(let error):
            throw error
        case .engineGoesAway(let reason):
            await engine.goAway(reason)
            throw SingingFacadeError.transport("Could not connect to the server.")
        }
    }
}

actor FakeTranscriber {
    private var heard: String? = "one two three four five six seven eight"
    private var failure: String?
    private var latch: SingLatch?
    private(set) var calls = 0

    func set(heard: String?) { self.heard = heard }
    func fail(_ message: String) { failure = message }
    func hold(_ latch: SingLatch) { self.latch = latch }

    func transcribe(_ url: URL) async throws -> String? {
        calls += 1
        if let latch { self.latch = nil; await latch.wait() }
        if let failure { throw FakeError(failure) }
        return heard
    }
}

// MARK: - The harness

struct SingHarness {
    let root: URL
    let store: ProjectStore
    let clipID: UUID
    let lifecycle: ModelLifecycleCoordinator
    let engine: FakeSingEngine
    let synth: FakeSingSynth
    let transcriber: FakeTranscriber
    let cache: SingPhraseCache
    let coordinator: SingJobCoordinator

    static let take: UInt64 = SingJobRequestBuilder.firstTakeSeed

    static func make(_ label: String, lyrics: String? = SingFixture.twoUnitLyrics,
                     engineState: SingingSidecarState = .installedNotRunning, capacity: Int = 4,
                     outside: Bool = false, freshBootGrace: Double = 30) async throws -> SingHarness {
        let root = try SingFixture.tempDir(label)
        let (store, clipID) = try await MainActor.run { try SingFixture.store(root: root, lyrics: lyrics) }
        let lifecycle = ModelLifecycleCoordinator(
            storageDirectory: root.appendingPathComponent("lifecycle", isDirectory: true), settleSeconds: 0)
        // Nothing here may ever be signalled: no evictors, no idle unloads.
        var soulx = ModelRegistry.soulxSinger(baseURL: URL(string: "http://127.0.0.1:9")!)
        soulx.idleUnloadSeconds = nil
        var ace = ModelRegistry.aceStep(baseURL: URL(string: "http://127.0.0.1:9")!)
        ace.idleUnloadSeconds = nil
        await lifecycle.register(soulx, evictor: nil)
        await lifecycle.register(ace, evictor: nil)
        let engine = FakeSingEngine(state: engineState, lifecycle: lifecycle)
        let synth = FakeSingSynth(engine: engine)
        let transcriber = FakeTranscriber()
        let cache = SingPhraseCache(directory: root.appendingPathComponent("cache", isDirectory: true))
        let configuration = SingJobCoordinator.Configuration(
            queueCapacity: capacity, outputSampleRate: 24_000, modelPollSeconds: 0.002, enginePollSeconds: 0.002,
            freshBootGraceSeconds: freshBootGrace,
            sleepSeconds: { seconds in try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) },
            songGeneratorRunsOutside: { outside })
        let coordinator = SingJobCoordinator(
            store: store, engine: engine, synthesizer: synth, lifecycle: lifecycle, cache: cache,
            detectPitch: { url in try SingFixture.frames(at: url) },
            transcribe: { url in try await transcriber.transcribe(url) },
            configuration: configuration)
        return SingHarness(root: root, store: store, clipID: clipID, lifecycle: lifecycle, engine: engine,
                           synth: synth, transcriber: transcriber, cache: cache, coordinator: coordinator)
    }

    func cleanup() { try? FileManager.default.removeItem(at: root) }

    func submit(_ request: SingJobRequest? = nil) async throws -> SingJobStatus {
        try await coordinator.submit(request ?? SingJobRequest(clipID: clipID))
    }

    func status(_ id: String) async throws -> SingJobStatus { try await coordinator.status(jobID: id) }

    /// Waits until `condition` holds for the job's status, and returns that status.
    @discardableResult
    func wait(_ id: String, _ what: String, _ condition: @escaping @Sendable (SingJobStatus) -> Bool)
        async throws -> SingJobStatus {
        let reached = try await SingFixture.waitUntil { condition(try await status(id)) }
        let current = try await status(id)
        #expect(reached, "waited for \(what); the job reads \(current.phase): \(current.stageText)")
        return current
    }

    func finished(_ id: String) async throws -> SingJobStatus {
        try await wait(id, "a terminal phase") { $0.phase.isTerminal }
    }

    func trackCount() async -> Int { await MainActor.run { store.tracks.count } }

    func landedTrack(_ id: UUID) async -> Track? {
        await MainActor.run { store.tracks.first { $0.id == id } }
    }

    /// Makes the song generator resident through the real admission path, with a job running on it.
    func songGeneratorStartsAJob(_ jobID: String) async throws {
        let plan = await lifecycle.resolveAdmission(.aceStep)
        if let ticket = try await lifecycle.commitAdmission(plan, for: .aceStep) {
            await lifecycle.admitted(ticket, healthy: true)
        }
        await lifecycle.noteJobStarted(.aceStep, jobID: jobID)
    }
}

// MARK: - The suite

@Suite("SingJobCoordinator — phases, cancel, queue, residency, retries, identity (p2-sing-e)")
struct SingJobCoordinatorTests {

    // MARK: Every phase, in order

    @Test("every phase in order: queued → startingEngine → singing 1, 2 → landed → checking → done; ONE undo")
    func everyPhaseAndOneUndo() async throws {
        let h = try await SingHarness.make("phases")
        defer { h.cleanup() }
        let start = SingLatch(), one = SingLatch(), five = SingLatch(), words = SingLatch()
        await h.engine.holdStart(start)
        await h.synth.hold("one", one)
        await h.synth.hold("five", five)
        await h.transcriber.hold(words)
        let tracksBefore = await MainActor.run { h.store.tracks }
        let undoBefore = await MainActor.run { h.store.undoHistory().undo }

        let submitted = try await h.submit()
        let id = submitted.jobID
        #expect(submitted.phase == .queued)
        #expect(submitted.stageText == SingJobCoordinator.Copy.queued)
        #expect(submitted.unitCount == 2)
        #expect(submitted.seed == SingHarness.take)
        #expect(submitted.progress == 0)

        let starting = try await h.wait(id, "startingEngine") { $0.phase == .startingEngine }
        #expect(starting.stageText == "Starting the singing engine… (about 20 seconds)")
        #expect(starting.etaSeconds != nil, "a cold start has an ETA")
        await start.release()

        let line1 = try await h.wait(id, "line 1") { $0.phase == .singing && $0.unitIndex == 1 }
        #expect(line1.stageText == "Singing line 1 of 2…")
        #expect(await h.lifecycle.openJobIDs(.soulxSinger) == ["\(id)#0"], "R5: the unit is a lifecycle job")
        await one.release()

        let line2 = try await h.wait(id, "line 2") { $0.unitIndex == 2 }
        #expect(line2.stageText == "Singing line 2 of 2…")
        #expect(line2.progress > 0.4 && line2.progress < 0.6, "weighted by unit length: two equal units")
        #expect(await h.lifecycle.openJobIDs(.soulxSinger) == ["\(id)#1"])
        await five.release()

        let checking = try await h.wait(id, "checking") { $0.phase == .checking }
        #expect(checking.stageText == "Checking the words…")
        #expect(checking.progress == 1)
        #expect(checking.etaSeconds == nil)
        let result = try #require(checking.result)
        #expect(result.gates.failed.isEmpty)
        #expect(result.noteAccuracy?.inTune == true)
        #expect(result.wordCheck == nil, "not yet")
        #expect(!result.melodyChanged)
        #expect(result.transposedSemitones == 0)
        // It has landed: ONE violet track, ONE undo step, the provenance written in that step.
        let track = try #require(await h.landedTrack(result.trackID))
        #expect(track.name == "Vocals — Built-in singer")
        #expect(track.isAIGenerated)
        #expect(track.clips.map { $0.id } == [result.clipID])
        let record = try #require(track.sungVocalProvenance)
        #expect(record.engineId == "soulx-singer")
        #expect(record.engineCommit == "fakecommit")
        #expect(record.weightsRevision == "fakeweights")
        #expect(record.voiceId == "builtin-1")
        #expect(record.voiceName == "Built-in singer")
        #expect(record.voiceKind == SungVocalProvenance.VoiceKind.builtIn)
        #expect(record.lyricsText == SingFixture.twoUnitLyrics)
        #expect(record.sourceClipId == h.clipID)
        #expect(record.seed == Int(SingHarness.take))
        #expect(record.nSteps == 32)
        #expect(record.cfg == 3.0)
        #expect(record.noteAccuracy?.inTune == true, "the notes are in the landing step")
        #expect(abs((record.loudness?.output.integratedLufs ?? 0) - -18) < 0.2)
        let undoAfter = await MainActor.run { h.store.undoHistory().undo }
        #expect(undoAfter.count == undoBefore.count + 1)
        #expect(undoAfter.first == "Land Sung Vocal")
        #expect(await h.lifecycle.openJobIDs(.soulxSinger).isEmpty)
        await words.release()

        let done = try await h.finished(id)
        #expect(done.phase == .done)
        #expect(done.stageText == "In tune · Words clear")
        #expect(done.result?.wordCheck?.verdict == SingWordCheck.Verdict.clear)
        #expect(done.finishedAt != nil)
        #expect(done.error == nil)
        #expect(done.renderedUnits == 2 && done.cachedUnits == 0)
        let recorded = await h.landedTrack(result.trackID)?.sungVocalProvenance?.wordCheck
        #expect(recorded?.verdict == SingWordCheck.Verdict.clear, "the word check is written into the record")
        #expect(await MainActor.run { h.store.undoHistory().undo.count } == undoBefore.count + 1,
                "the checks are NOT an undo step")
        let busy = await SingFixture.waitUntil { !(await h.coordinator.isBusy()) }
        #expect(busy)
        #expect(!FileManager.default.fileExists(
            atPath: h.cache.directory.appendingPathComponent("takes/\(id).wav").path), "the temp take is gone")

        #expect(try await MainActor.run { try h.store.undo() } == "Land Sung Vocal")
        #expect(await MainActor.run { h.store.tracks } == tracksBefore, "undo removes the take exactly")
    }

    // MARK: Cancel

    @Test("cancel takes effect at the next unit boundary: the line in flight finishes, nothing lands")
    func cancelAtTheBoundary() async throws {
        let h = try await SingHarness.make("cancel")
        defer { h.cleanup() }
        let one = SingLatch()
        await h.synth.hold("one", one)
        let tracks = await h.trackCount()
        let id = try await h.submit().jobID
        try await h.wait(id, "line 1") { $0.unitIndex == 1 }

        let asked = try await h.coordinator.cancel(jobID: id)
        #expect(asked.cancelRequested)
        #expect(asked.phase == .singing, "cancel never invents a terminal state")
        #expect(asked.stageText == "Stopping after this line…")
        #expect(try await h.status(id).phase == .singing)
        await one.release()

        let ended = try await h.finished(id)
        #expect(ended.phase == .cancelled)
        #expect(ended.stageText == "Stopped. Nothing was added to your song.")
        #expect(ended.error == nil)
        #expect(await h.synth.calls(for: "five").isEmpty, "the next line never started")
        #expect(await h.trackCount() == tracks)
        #expect(await h.lifecycle.openJobIDs(.soulxSinger).isEmpty)
        await #expect(throws: SingJobError.jobFinished(id)) { try await h.coordinator.cancel(jobID: id) }

        // The line that finished is in the cache: singing again renders only the other one.
        let again = try await h.finished(try await h.submit().jobID)
        #expect(again.phase == .done)
        #expect(again.cachedUnits == 1)
        #expect(again.renderedUnits == 1)
    }

    @Test("a queued job leaves the queue at once; the queue holds one rendering + `capacity` waiting")
    func queueAndQueuedCancel() async throws {
        let h = try await SingHarness.make("queue", capacity: 1)
        defer { h.cleanup() }
        let one = SingLatch()
        await h.synth.hold("one", one)
        let a = try await h.submit().jobID
        try await h.wait(a, "A singing") { $0.unitIndex == 1 }
        let b = try await h.submit()
        #expect(b.phase == .queued)
        #expect(b.stageText == "Waiting for the take before this one to finish…")
        do {
            _ = try await h.submit()
            Issue.record("a third job was accepted with capacity 1")
        } catch let error as SingJobError {
            #expect(error == .queueFull(capacity: 1))
            #expect(error.code == "singQueueFull")
            #expect(error.errorDescription == "A take is already waiting to be sung. Wait for it to finish, then try again.")
        }

        let cancelled = try await h.coordinator.cancel(jobID: b.jobID)
        #expect(cancelled.phase == .cancelled, "a queued job has started nothing: leaving the queue IS its unwind")
        #expect(cancelled.finishedAt != nil)
        let listed = await h.coordinator.statuses().map { $0.jobID }
        #expect(listed == [b.jobID, a], "newest first")

        await one.release()
        #expect(try await h.finished(a).phase == .done)
        let units = await h.synth.calls.count
        #expect(units == 2, "only A's two lines were ever rendered")
        await #expect(throws: SingJobError.jobNotFound("nope")) { try await h.coordinator.status(jobID: "nope") }
    }

    // MARK: Residency (design §2.7)

    @Test("R2: waits while the song generator works, names it, shows no ETA; a fresh boot counts as busy")
    func waitsForTheSongGenerator() async throws {
        let h = try await SingHarness.make("r2")
        defer { h.cleanup() }
        try await h.songGeneratorStartsAJob("ace-job-1")
        let id = try await h.submit().jobID
        let waiting = try await h.wait(id, "waitingForModel") { $0.phase == .waitingForModel }
        #expect(waiting.stageText == "Waiting for the song generator to finish — it's using most of this Mac's memory.")
        #expect(waiting.waitingFor == "ACE-Step song generation")
        #expect(waiting.etaSeconds == nil)
        #expect(await h.engine.startCount == 0, "nothing booted while it waits")
        await h.lifecycle.noteJobEnded(.aceStep, jobID: "ace-job-1")
        #expect(try await h.finished(id).phase == .done)
        #expect(await h.engine.startCount == 1)
    }

    @Test("R2: a model booted moments ago with no job yet still counts as busy; with no grace it does not")
    func freshBootGrace() async throws {
        let h = try await SingHarness.make("grace")
        defer { h.cleanup() }
        let plan = await h.lifecycle.resolveAdmission(.aceStep)
        let ticket = try #require(try await h.lifecycle.commitAdmission(plan, for: .aceStep))
        await h.lifecycle.admitted(ticket, healthy: true)
        let id = try await h.submit().jobID
        try await h.wait(id, "waitingForModel") { $0.phase == .waitingForModel }
        // Its first job comes and goes: now it is idle, and the boot may evict it.
        await h.lifecycle.noteJobStarted(.aceStep, jobID: "ace-first")
        await h.lifecycle.noteJobEnded(.aceStep, jobID: "ace-first")
        #expect(try await h.finished(id).phase == .done)

        let control = try await SingHarness.make("grace-control", freshBootGrace: 0)
        defer { control.cleanup() }
        let plan2 = await control.lifecycle.resolveAdmission(.aceStep)
        let ticket2 = try #require(try await control.lifecycle.commitAdmission(plan2, for: .aceStep))
        await control.lifecycle.admitted(ticket2, healthy: true)
        let job = try await control.submit().jobID
        let ended = try await control.finished(job)
        #expect(ended.phase == .done)
        #expect(ended.waitingFor == nil)
    }

    @Test("a job waiting for another model can be cancelled; it never boots the engine")
    func cancelWhileWaiting() async throws {
        let h = try await SingHarness.make("r2-cancel")
        defer { h.cleanup() }
        try await h.songGeneratorStartsAJob("ace-job")
        let id = try await h.submit().jobID
        try await h.wait(id, "waitingForModel") { $0.phase == .waitingForModel }
        _ = try await h.coordinator.cancel(jobID: id)
        #expect(try await h.finished(id).phase == .cancelled)
        #expect(await h.engine.startCount == 0)
    }

    @Test("R3: evicted mid-job is a YIELD: it waits, restarts, re-renders ONLY that line at the same seed")
    func yieldAndResume() async throws {
        let h = try await SingHarness.make("yield")
        defer { h.cleanup() }
        let five = SingLatch()
        await h.synth.hold("five", five)
        await h.synth.plan("five", [.engineGoesAway(.evictedByCoordinator)])
        let id = try await h.submit().jobID
        try await h.wait(id, "line 2") { $0.unitIndex == 2 }
        // The song generator boots and starts work while line 2 is being sung; SoulX gives way.
        try await h.songGeneratorStartsAJob("ace-job")
        await five.release()

        let paused = try await h.wait(id, "the yield's wait") { $0.phase == .waitingForModel }
        #expect(paused.stageText == "Paused while the song generator runs; I'll carry on after.")
        #expect(paused.yields == 1)
        #expect(paused.etaSeconds == nil)
        await h.lifecycle.noteJobEnded(.aceStep, jobID: "ace-job")

        let done = try await h.finished(id)
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.yields == 1)
        #expect(done.engineRestarts == 0, "a yield is not a crash")
        #expect(await h.engine.startCount == 2)
        #expect(await h.synth.calls(for: "one").count == 1, "the finished line is kept")
        let seeds = await h.synth.calls(for: "five").map { $0.seed }
        #expect(seeds == [SingHarness.take, SingHarness.take], "the same line, the same seed")
    }

    @Test("R4: a song generator running outside DAW Pro is never signalled; the job says so and goes on")
    func songGeneratorOutside() async throws {
        let h = try await SingHarness.make("r4", outside: true)
        defer { h.cleanup() }
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done)
        #expect(done.notices.contains(
            "The song generator is also running outside DAW Pro, so this Mac may run short of memory."))
    }

    @Test("admission refused (another model mid-boot) waits and tries again")
    func admissionRefusedRetries() async throws {
        let h = try await SingHarness.make("admission")
        defer { h.cleanup() }
        await h.engine.setStartScript([.admissionRefused, .healthy])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done)
        #expect(await h.engine.startCount == 2)
    }

    // MARK: Retries and failures (design §4.4, §4.7)

    @Test("a NaN line gets ONE retry at seed + 1, recorded for that line; the take keeps its seed")
    func oneRetryAtSeedPlusOne() async throws {
        let h = try await SingHarness.make("retry")
        defer { h.cleanup() }
        await h.synth.plan("five", [.sung(.nan)])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.retriedUnits == [2])
        let fiveSeeds = await h.synth.calls(for: "five").map { $0.seed }
        #expect(fiveSeeds == [SingHarness.take, SingHarness.take + 1])
        let oneSeeds = await h.synth.calls(for: "one").map { $0.seed }
        #expect(oneSeeds == [SingHarness.take])
        let record = await h.landedTrack(try #require(done.result?.trackID))?.sungVocalProvenance
        #expect(record?.seed == Int(SingHarness.take), "the take's seed, not the retry's")
    }

    @Test("the facade's own nonFinite refusal takes the same one retry")
    func facadeNonFiniteRetries() async throws {
        let h = try await SingHarness.make("retry-facade")
        defer { h.cleanup() }
        await h.synth.plan("one", [.facadeNonFinite])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done)
        #expect(done.retriedUnits == [1])
    }

    @Test("a line silent twice fails in words, names the line, lands nothing")
    func badLineFailsAfterItsRetry() async throws {
        let h = try await SingHarness.make("retry-fail")
        defer { h.cleanup() }
        await h.synth.plan("one", [.sung(.silent), .sung(.silent)])
        let tracks = await h.trackCount()
        let failed = try await h.finished(try await h.submit().jobID)
        #expect(failed.phase == .failed)
        #expect(failed.error?.code == "singBadUnit")
        #expect(failed.error?.message == "One line didn't come out right (line 1). Try another take.")
        #expect(failed.stageText == failed.error?.message)
        #expect(await h.synth.calls(for: "five").isEmpty)
        #expect(await h.trackCount() == tracks)
    }

    @Test("a still-loading engine is waited for, not counted as a failure")
    func loadingIsWaitedFor() async throws {
        let h = try await SingHarness.make("loading")
        defer { h.cleanup() }
        await h.synth.plan("one", [.loading])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done)
        #expect(done.retriedUnits.isEmpty)
        let seeds = await h.synth.calls(for: "one").map { $0.seed }
        #expect(seeds == [SingHarness.take, SingHarness.take])
    }

    @Test("a crash mid-line (no stop recorded) restarts ONCE and re-sings the line; a second crash fails")
    func crashRestartsOnce() async throws {
        let h = try await SingHarness.make("crash")
        defer { h.cleanup() }
        await h.synth.plan("five", [.engineGoesAway(nil)])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.engineRestarts == 1)
        #expect(done.yields == 0)
        #expect(await h.engine.startCount == 2)
        #expect(await h.synth.calls(for: "one").count == 1)

        let twice = try await SingHarness.make("crash-twice")
        defer { twice.cleanup() }
        await twice.synth.plan("one", [.engineGoesAway(nil), .engineGoesAway(nil)])
        let failed = try await twice.finished(try await twice.submit().jobID)
        #expect(failed.phase == .failed)
        #expect(failed.error?.code == "singEngineCrashed")
        #expect(failed.error?.message == "The singing engine stopped unexpectedly.")
    }

    @Test("a stop recorded BEFORE this line is stale: the crash still reads as a crash")
    func staleClassificationIsNotThisStop() async throws {
        let h = try await SingHarness.make("stale", engineState: .healthy)
        defer { h.cleanup() }
        await h.engine.setStaleStopReason(.explicit)
        await h.synth.plan("one", [.engineGoesAway(nil)])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done, "an old explicit stop must not end this job: \(done.error?.message ?? "")")
        #expect(done.engineRestarts == 1)
    }

    @Test("an explicit stop mid-job (not a cancel) fails it in words")
    func explicitStopFails() async throws {
        let h = try await SingHarness.make("explicit")
        defer { h.cleanup() }
        await h.synth.plan("one", [.engineGoesAway(.explicit)])
        let failed = try await h.finished(try await h.submit().jobID)
        #expect(failed.phase == .failed)
        #expect(failed.error?.code == "singEngineStopped")
    }

    @Test("the watchdog: footprint and memory pressure each fail in their own words")
    func watchdogFails() async throws {
        let footprint = try await SingHarness.make("wd-footprint")
        defer { footprint.cleanup() }
        await footprint.synth.plan("one", [.engineGoesAway(.watchdog(
            trigger: .footprint(bytes: 20 << 30, capBytes: 16 << 30), detail: "21.5 GB over the 17.2 GB cap"))])
        let a = try await footprint.finished(try await footprint.submit().jobID)
        #expect(a.error?.code == "singWatchdogFootprint")
        #expect(a.error?.message == "The singing engine used too much memory, so I stopped it. Try shorter lines.")
        #expect(a.error?.detail == "21.5 GB over the 17.2 GB cap")
        #expect(await footprint.engine.startCount == 1, "no restart after a watchdog kill")

        let pressure = try await SingHarness.make("wd-pressure")
        defer { pressure.cleanup() }
        await pressure.synth.plan("five", [.engineGoesAway(.watchdog(trigger: .pressure, detail: "critical"))])
        let b = try await pressure.finished(try await pressure.submit().jobID)
        #expect(b.error?.code == "singWatchdogPressure")
        #expect(b.error?.message == "Your Mac ran very low on memory, so I stopped the singing engine. "
            + "Close other apps or the song generator and try again.")
    }

    @Test("the engine won't start: the cause in words; a boot that never gets ready says so")
    func engineWontStart() async throws {
        let h = try await SingHarness.make("nostart")
        defer { h.cleanup() }
        await h.engine.setStartScript([.fails("port 8004 is already in use by another program.")])
        let a = try await h.finished(try await h.submit().jobID)
        #expect(a.error?.code == "singStartFailed")
        #expect(a.error?.message == "The singing engine couldn't start: port 8004 is already in use by another program.")

        let slow = try await SingHarness.make("nostart-slow")
        defer { slow.cleanup() }
        await slow.engine.setStartScript([.staysStarting])
        let b = try await slow.finished(try await slow.submit().jobID)
        #expect(b.error?.message == "The singing engine couldn't start: it did not become ready in time.")
    }

    @Test("a facade refusal (not a crash) fails the job with the facade's own sentence")
    func facadeRefusalFails() async throws {
        let h = try await SingHarness.make("refusal")
        defer { h.cleanup() }
        await h.synth.plan("one", [.refusal(.unknownPhone("The word \"xq\" has a sound the singer doesn't know."))])
        let failed = try await h.finished(try await h.submit().jobID)
        #expect(failed.error?.code == "singFacadeRefused")
        #expect(await h.engine.startCount == 1)
    }

    // MARK: Submit-time refusals

    @Test("submit refuses at once: not installed, needs an update, no lyrics, an unknown clip, a bad octave")
    func submitRefusals() async throws {
        let missing = try await SingHarness.make("not-installed", engineState: .notInstalled)
        defer { missing.cleanup() }
        do {
            _ = try await missing.submit()
            Issue.record("submitted with no engine installed")
        } catch let error as SingJobError {
            #expect(error.code == "singEngineNotInstalled")
            #expect(error.errorDescription == "The singing engine isn't installed yet. Open Settings ▸ Singing to install it.")
        }
        #expect(await missing.coordinator.statuses().isEmpty, "nothing was queued")

        let stale = try await SingHarness.make("needs-update", engineState: .needsUpdate)
        defer { stale.cleanup() }
        await #expect(throws: SingJobError.self) { _ = try await stale.submit() }

        let wordless = try await SingHarness.make("no-lyrics", lyrics: nil)
        defer { wordless.cleanup() }
        do {
            _ = try await wordless.submit()
            Issue.record("submitted with no lyrics")
        } catch let error as SingJobError {
            #expect(error == .planRefused(.lyrics(.noWords)))
            #expect(error.code == "singNeedsLyrics")
        }
        let unknown = UUID()
        await #expect(throws: SingJobError.clipNotFound(unknown)) {
            _ = try await wordless.submit(SingJobRequest(clipID: unknown))
        }
        do {
            _ = try await wordless.submit(SingJobRequest(clipID: wordless.clipID, octaveShift: 3))
            Issue.record("an octave shift of 3 was accepted")
        } catch let error as SingJobError {
            #expect(error.code == "singOctaveShiftInvalid")
        }
    }

    // MARK: Landing gates through the job (design §7.1)

    @Test("a gate that fails keeps the take out, says why, and keeps the units in the cache")
    func gateFailureDoesNotLand() async throws {
        let h = try await SingHarness.make("gate")
        defer { h.cleanup() }
        await h.synth.plan("one", [.sung(.noise)])
        await h.synth.plan("five", [.sung(.noise)])
        let tracks = await h.trackCount()
        let failed = try await h.finished(try await h.submit().jobID)
        #expect(failed.phase == .failed)
        #expect(failed.error?.code == "singGateL2")
        #expect(failed.error?.message == "I couldn't hear singing in this take, so I didn't add it. Try another take.")
        #expect(failed.gates?.failed == [.singingPresent])
        #expect(failed.result == nil)
        #expect(await h.trackCount() == tracks)
        // §4.7: "the cache is kept".
        let again = try await h.finished(try await h.submit().jobID)
        #expect(again.cachedUnits == 2)
    }

    @Test("a line longer than planned fails L1; the take does not land")
    func gateL1ThroughTheJob() async throws {
        let h = try await SingHarness.make("gate-l1")
        defer { h.cleanup() }
        await h.synth.plan("five", [.render(.sine, extraSeconds: 0.1)])
        let failed = try await h.finished(try await h.submit().jobID)
        #expect(failed.error?.code == "singGateL1")
        #expect(failed.error?.message == "This take came out damaged, so I didn't add it. Try another take.")
    }

    @Test("a click holds the gain at the ceiling: the take lands, with the quiet-take notice")
    func quietTakeLandsWithNotice() async throws {
        let h = try await SingHarness.make("quiet")
        defer { h.cleanup() }
        await h.synth.plan("one", [.sung(.click)])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.notices.contains(
            "This take came out quieter than usual because of a sharp peak; turn the track up if you need to."))
        #expect(done.result?.loudness?.limitedByCeiling == true)
        #expect((done.result?.gates.truePeakDbtp ?? 0) <= -1.0 + SingLandingGates.truePeakToleranceDb)
    }

    @Test("a detuned take still lands (the note check is advisory) and names the bars that are off")
    func detunedTakeLandsWithBars() async throws {
        let h = try await SingHarness.make("detuned")
        defer { h.cleanup() }
        await h.synth.plan("five", [.sung(.detuned(cents: 100))])
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.phase == .done)
        let notes = try #require(done.result?.noteAccuracy)
        #expect(!notes.inTune)
        #expect(notes.hitRate == 0.5)
        #expect(notes.offBars == [10])
        #expect(done.stageText == "Some notes may be off (bars 10). · Words clear")
    }

    @Test("results line: §5.7's words; notes off with no bar to name never prints empty brackets")
    func resultsLine() {
        typealias Copy = SingJobCoordinator.Copy
        let inTune = SungNoteAccuracy(hitRate: 1, meanAbsErrorCents: 3, voicedCoverage: 0.95, inTune: true)
        let clear = SungWordCheck(state: SungWordCheck.State.checked, wer: 0, heard: "x", verdict: "clear")
        #expect(Copy.results(notes: inTune, words: clear) == "In tune · Words clear")
        let thin = SungNoteAccuracy(hitRate: 1, meanAbsErrorCents: 3, voicedCoverage: 0.6, inTune: false)
        #expect(Copy.results(notes: thin, words: nil) == "Some notes may be off.")
        let off = SungNoteAccuracy(hitRate: 0.5, meanAbsErrorCents: 3, voicedCoverage: 0.9, inTune: false,
                                   offBars: [3, 7])
        #expect(Copy.results(notes: off, words: nil) == "Some notes may be off (bars 3, 7).")
    }

    // MARK: Project identity (design §4.5)

    @Test("a different project opened mid-job: nothing lands; the take is kept and the job says where")
    func projectChangedKeepsTheTake() async throws {
        let h = try await SingHarness.make("identity")
        defer { h.cleanup() }
        let five = SingLatch()
        await h.synth.hold("five", five)
        let id = try await h.submit().jobID
        try await h.wait(id, "line 2") { $0.unitIndex == 2 }
        try await MainActor.run { try h.store.newProject(discardChanges: true) }
        await five.release()
        let failed = try await h.finished(id)
        #expect(failed.phase == .failed)
        #expect(failed.error?.code == "singProjectChanged")
        let kept = try #require(failed.keptTakePath)
        #expect(FileManager.default.fileExists(atPath: kept))
        #expect(kept.hasPrefix(h.root.appendingPathComponent("generations").path))
        #expect(failed.error?.message.hasPrefix("The project was closed before the singing finished.") == true)
        #expect(await MainActor.run { h.store.tracks.allSatisfy { $0.sungVocalProvenance == nil } })
    }

    @Test("the song transposed mid-job (+3): the take lands moved by +3, in the same step, with its notice")
    func transposedMidJob() async throws {
        let h = try await SingHarness.make("transpose")
        defer { h.cleanup() }
        let five = SingLatch()
        await h.synth.hold("five", five)
        let id = try await h.submit().jobID
        try await h.wait(id, "line 2") { $0.unitIndex == 2 }
        try await MainActor.run { _ = try h.store.transposeProject(semitones: 3) }
        await five.release()
        let done = try await h.finished(id)
        #expect(done.phase == .done, "\(done.error?.message ?? "")")
        #expect(done.result?.transposedSemitones == 3)
        #expect(done.result?.melodyChanged == false)
        #expect(done.notices.contains(
            "The song moved up 3 half-steps while I was singing, so I moved this take up 3 half-steps to match."))
        let clip = await h.landedTrack(try #require(done.result?.trackID))?.clips.first
        #expect(clip?.pitchShiftSemitones == 3)
        // Sung in the planned key, and checked against it: the shift is the clip's, not the audio's.
        #expect(done.result?.noteAccuracy?.inTune == true)
    }

    // MARK: The phrase cache through the job (design §4.3)

    @Test("cache: the same take again renders nothing; an edited line renders only that line; a new seed all")
    func phraseCacheThroughTheJob() async throws {
        let h = try await SingHarness.make("cache-job")
        defer { h.cleanup() }
        let first = try await h.finished(try await h.submit().jobID)
        #expect(first.renderedUnits == 2)
        let calls = await h.synth.calls.count

        let again = try await h.finished(try await h.submit().jobID)
        #expect(again.phase == .done)
        #expect(again.cachedUnits == 2 && again.renderedUnits == 0)
        #expect(await h.synth.calls.count == calls, "the engine sang nothing")

        try await MainActor.run {
            try SingFixture.setLyrics(h.store, clipID: h.clipID, text: "one two three four\nfive six seven ate")
        }
        let edited = try await h.finished(try await h.submit().jobID)
        #expect(edited.cachedUnits == 1 && edited.renderedUnits == 1)
        #expect(await h.synth.calls.last?.unit == "five")

        let other = try await h.finished(try await h.submit(SingJobRequest(clipID: h.clipID, seed: 99)).jobID)
        #expect(other.seed == 99)
        #expect(other.cachedUnits == 0 && other.renderedUnits == 2, "another take is another seed")
    }

    // MARK: Voices and the word check (design §4.6)

    @Test("an own voice: the first line reads 'Getting the voice ready…'; a hard-to-judge voice says so")
    func ownVoiceAndHardToJudge() async throws {
        let h = try await SingHarness.make("own")
        defer { h.cleanup() }
        let one = SingLatch()
        await h.synth.hold("one", one)
        let voice = SingJobVoice.own(SingOwnVoice(
            id: "voice-me", name: "My voice", referencePath: "/v/me.wav", referenceSha256: "abc",
            windowStartS: 0, windowEndS: 4, promptNotes: [], wordCheckIsReliable: false))
        let id = try await h.submit(SingJobRequest(clipID: h.clipID, voice: voice)).jobID
        let preparing = try await h.wait(id, "preparingVoice") { $0.phase == .preparingVoice }
        #expect(preparing.stageText == "Getting the voice ready…")
        #expect(preparing.unitIndex == 1)
        await one.release()
        let done = try await h.finished(id)
        #expect(done.result?.wordCheck?.state == SungWordCheck.State.hardToJudge)
        #expect(done.stageText == "In tune · Word check: hard to judge for this voice.")
        let track = await h.landedTrack(try #require(done.result?.trackID))
        #expect(track?.name == "Vocals — My voice")
        #expect(track?.sungVocalProvenance?.voiceKind == SungVocalProvenance.VoiceKind.own)
    }

    @Test("no speech model: the word check is skipped honestly; a failing transcriber is not 'skipped'")
    func wordCheckSkippedOrFailed() async throws {
        let h = try await SingHarness.make("skipped")
        defer { h.cleanup() }
        await h.transcriber.set(heard: nil)
        let done = try await h.finished(try await h.submit().jobID)
        #expect(done.result?.wordCheck?.state == SungWordCheck.State.skipped)
        #expect(done.stageText == "In tune · Word check skipped: no speech model is installed.")

        let broken = try await SingHarness.make("transcriber-fails")
        defer { broken.cleanup() }
        await broken.transcriber.fail("the speech model is damaged")
        let ended = try await broken.finished(try await broken.submit().jobID)
        #expect(ended.phase == .done, "the word check is advisory: it never un-lands")
        #expect(ended.result?.wordCheck == nil)
        #expect(ended.notices.contains("The word check couldn't run: the speech model is damaged"))
        #expect(ended.stageText == "In tune")
    }
}

// MARK: - The two language refusal codes (APPENDED by W8-X6, W8-X3b's finding)

extension SingJobCoordinatorTests {

    /// Pins the wire codes of W8-X3's two language refusals next to `submitRefusals`' `singNeedsLyrics` pin
    /// (`SingJobCoordinator.swift`'s `code` switch): a rename here would silently change what an agent reads.
    @Test("the language refusals' wire codes: lyricsScriptMismatch and lyricsLanguageUnsupported")
    func languageRefusalCodes() {
        #expect(SingJobError.planRefused(.lyrics(.scriptMismatch(word: "我"))).code == "lyricsScriptMismatch")
        #expect(SingJobError.planRefused(.lyrics(.languageUnsupported(language: "es"))).code
                == "lyricsLanguageUnsupported")
    }
}
