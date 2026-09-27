import Foundation
import Testing

@testable import AIServices

// MARK: - Fixtures (p2-sing-0)
//
// ⚠️ `MachineStub`, `SpyEvictor` and `SleepGate` are NOT redeclared here. They live
// in `ModelLifecycleCoordinatorTests.swift` in this same test target, where a second
// declaration would not compile. The coordinator and descriptor builders are that
// suite's own statics, reused so the two suites cannot drift on what a hermetic
// coordinator is. No test here touches `ModelLifecycleCoordinator.shared`, starts a
// sidecar, or signals a process: every evictor is a spy that stops nothing.

/// Lets a test wait until a fake has ENTERED a call, so a cancellation lands mid-call
/// rather than before it. Continuation-based, not polled. Shared with
/// `LifecycleTrackingVoiceConverterTests`.
actor LifecycleTrackingEntrySignal {
    private var arrivals = 0
    private var waiters: [(target: Int, continuation: CheckedContinuation<Void, Never>)] = []

    func arrive() {
        arrivals += 1
        let ready = waiters.filter { $0.target <= arrivals }
        waiters.removeAll { $0.target <= arrivals }
        for waiter in ready { waiter.continuation.resume() }
    }

    func wait(forArrivals target: Int = 1) async {
        if arrivals >= target { return }
        await withCheckedContinuation { continuation in
            waiters.append((target, continuation))
        }
    }
}

/// The raw `ACEStepClient`'s stand-in: a scripted `SongGenerating` that records every
/// call. The call log is how a test proves one call in is exactly one call out: the
/// tracker adds no hidden poll and no self-observation loop.
private actor ScriptedSongGenerator: SongGenerating {
    enum Submission: Sendable, Equatable { case generate, extract, lego, repaint }

    let entered = LifecycleTrackingEntrySignal()
    private(set) var submissions: [Submission] = []
    private(set) var polls: [String] = []
    private var minted = 0
    private var submitFailure: (any Error)?
    private var holdsSubmissions = false
    private var scripted: [String: Result<SongGenerationState, any Error>] = [:]

    func failSubmissions(with error: any Error) { submitFailure = error }
    /// Every later submission waits until its task is cancelled, then throws
    /// `CancellationError` without being accepted.
    func holdSubmissionsUntilCancelled() { holdsSubmissions = true }
    /// What the next polls of `jobID` see. Unscripted jobs read `.running`.
    func script(_ jobID: String, _ outcome: Result<SongGenerationState, any Error>) {
        scripted[jobID] = outcome
    }

    func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
        let jobID = try await accept(.generate, prefix: "ace-")
        return SongGenerationSubmission(jobID: jobID, state: .queued, queuePosition: 1)
    }

    func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
        let jobID = try await accept(.extract, prefix: "stems:")
        return StemGenerationSubmission(jobID: jobID, state: .queued, trackNames: request.trackNames)
    }

    func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
        let jobID = try await accept(.lego, prefix: "stems:")
        return StemGenerationSubmission(
            jobID: jobID, state: .queued, trackNames: request.tracks.map(\.trackName))
    }

    func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission {
        let jobID = try await accept(.repaint, prefix: "ace-")
        return SongGenerationSubmission(jobID: jobID, state: .queued, queuePosition: 1)
    }

    func generationStatus(jobID: String) async throws -> SongGenerationStatus {
        polls.append(jobID)
        switch scripted[jobID] ?? .success(.running) {
        case .success(let state):
            return Self.status(jobID, state)
        case .failure(let error):
            throw error
        }
    }

    /// The status this fake returns for a scripted state, so a test can compare what
    /// the caller received against it.
    static func status(_ jobID: String, _ state: SongGenerationState) -> SongGenerationStatus {
        SongGenerationStatus(
            jobID: jobID, state: state, progress: state == .succeeded ? 1 : 0.5,
            audioPath: state == .succeeded ? "/tmp/\(jobID).wav" : nil)
    }

    private func accept(_ kind: Submission, prefix: String) async throws -> String {
        await entered.arrive()
        if holdsSubmissions {
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
        if let submitFailure { throw submitFailure }
        submissions.append(kind)
        minted += 1
        return "\(prefix)\(minted)"
    }
}

/// A pass-through stand-in for `DAWAppKit`'s `GenerationObservingGenerator`, which this
/// target cannot import. It sits where the real origin observers sit, ABOVE the
/// tracker, and forwards every call exactly once. It carries no presence model. What
/// it stands for here: the Sketchpad and the import seam submit through their OWN
/// wrapper, so `CommandRouter.noteACEJobStarted` never runs for their jobs.
private final class OriginStandIn: SongGenerating, Sendable {
    let origin: String
    private let wrapped: any SongGenerating

    init(_ origin: String, wrapping wrapped: any SongGenerating) {
        self.origin = origin
        self.wrapped = wrapped
    }

    func generateSong(_ request: SongGenerationRequest) async throws -> SongGenerationSubmission {
        try await wrapped.generateSong(request)
    }

    func generationStatus(jobID: String) async throws -> SongGenerationStatus {
        try await wrapped.generationStatus(jobID: jobID)
    }

    func extractStems(_ request: StemExtractionRequest) async throws -> StemGenerationSubmission {
        try await wrapped.extractStems(request)
    }

    func generateLegoTracks(_ request: LegoGenerationRequest) async throws -> StemGenerationSubmission {
        try await wrapped.generateLegoTracks(request)
    }

    func repaintAudio(_ request: RepaintRequest) async throws -> SongGenerationSubmission {
        try await wrapped.repaintAudio(request)
    }
}

// MARK: - The suite

/// p2-sing-0 (design `docs/design/2026-09-27-p2-sing-integration.md` §2.7 R0, F1, and
/// §9's gate row): every ACE job registers with the REAL coordinator, whichever part
/// of the app submitted it.
///
/// Nonisolated on purpose: it drives the coordinator actor and the tracker, and no
/// `@MainActor` type.
@Suite("Lifecycle tracking — every ACE job registers (p2-sing-0)", .timeLimit(.minutes(1)))
struct LifecycleTrackingSongGeneratorTests {

    fileprivate typealias Fixtures = ModelLifecycleCoordinatorTests

    /// A hermetic coordinator with ACE and RVC registered and ACE booked resident:
    /// the state a Sketchpad generation runs in.
    fileprivate struct World {
        let coordinator: ModelLifecycleCoordinator
        let aceSpy: SpyEvictor
        let rvcSpy: SpyEvictor
        let storage: URL
    }

    fileprivate static func world(
        aceIdleSeconds: Double? = nil,
        sleepSeconds: (@Sendable (Double) async -> Void)? = nil
    ) async throws -> World {
        let storage = Fixtures.tempDirectory()
        let machine = MachineStub(availableGiB: 110, at: Fixtures.epoch)
        let coordinator = Fixtures.coordinator(
            machine: machine, storage: storage, sleepSeconds: sleepSeconds)
        let aceSpy = SpyEvictor(modelID: .aceStep)
        let rvcSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(
            Fixtures.model("ace-step", holdGiB: 74, port: 8001, idleSeconds: aceIdleSeconds),
            evictor: aceSpy)
        await coordinator.register(Fixtures.model("rvc", holdGiB: 3, port: 8002), evictor: rvcSpy)
        try await Fixtures.makeResident(coordinator, .aceStep)
        return World(coordinator: coordinator, aceSpy: aceSpy, rvcSpy: rvcSpy, storage: storage)
    }

    /// What an RVC boot saw and did while a Sketchpad song was rendering.
    fileprivate struct BootDuringSong {
        let jobID: String
        let openWhileRendering: [String]
        let plan: ModelAdmission.Plan
        let aceStopsDuringBoot: Int
        let aceResidentAfterBoot: Bool
        let openAfterBoot: [String]
    }

    /// F1 as it happens in the app, with ONE axis varied: whether the tracker sits
    /// below the Sketchpad's origin wrapper. The Sketchpad submits through its own
    /// wrapper (never the wire), polls once mid-render, and then RVC boots through the
    /// real admission path that `VoiceConversionManager.start()` takes:
    /// `resolveAdmission`, then `commitAdmission`, which is where a SIGTERM lands. The
    /// boot is released unhealthy, so RVC does not stay resident and the same boot can
    /// be planned again afterwards.
    fileprivate static func sketchpadSongThenRVCBoot(
        decorated: Bool, in world: World, raw: ScriptedSongGenerator
    ) async throws -> (seen: BootDuringSong, sketchpad: OriginStandIn) {
        let belowTheObservers: any SongGenerating = decorated
            ? LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator)
            : raw
        let sketchpad = OriginStandIn("sketchpad", wrapping: belowTheObservers)

        let submission = try await sketchpad.generateSong(
            SongGenerationRequest(prompt: "a slow synthwave ballad"))
        let midRender = try await sketchpad.generationStatus(jobID: submission.jobID)
        #expect(midRender.state == .running, "fixture: the song is still rendering")
        let openWhileRendering = await world.coordinator.openJobIDs(.aceStep)

        let plan = await world.coordinator.resolveAdmission(.rvc)
        let ticket = try #require(
            try await world.coordinator.commitAdmission(plan, for: .rvc),
            "fixture: the RVC boot must be admitted")
        await world.coordinator.admitted(ticket, healthy: false)

        let aceRow = await world.coordinator.residency().models.first { $0.modelID == .aceStep }
        let seen = BootDuringSong(
            jobID: submission.jobID,
            openWhileRendering: openWhileRendering,
            plan: plan,
            aceStopsDuringBoot: await world.aceSpy.callCount(),
            aceResidentAfterBoot: aceRow?.resident ?? false,
            openAfterBoot: await world.coordinator.openJobIDs(.aceStep))
        return (seen, sketchpad)
    }

    // MARK: - F1, and its negative control

    @Test("F1. A Sketchpad-origin job protects ACE: an RVC boot mid-song leaves ACE alone")
    func sketchpadJobProtectsACEFromAnRVCBoot() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedSongGenerator()
        let (seen, sketchpad) = try await Self.sketchpadSongThenRVCBoot(
            decorated: true, in: world, raw: raw)

        #expect(seen.openWhileRendering == [seen.jobID],
                "the Sketchpad's job must be open, under ACE's own job id")
        #expect(seen.plan.protectedByJobs == [.aceStep])
        #expect(seen.plan.evicting.isEmpty)
        #expect(seen.aceStopsDuringBoot == 0, "the RVC boot must not SIGTERM ACE mid-song")
        #expect(seen.aceResidentAfterBoot)
        #expect(seen.openAfterBoot == [seen.jobID], "a boot beside the job does not close it")

        // ⭐ The twin: the protection is the JOB's, so a terminal poll releases it and
        // the SAME boot now plans ACE into `evicting`.
        await raw.script(seen.jobID, .success(.succeeded))
        _ = try await sketchpad.generationStatus(jobID: seen.jobID)
        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty)
        let after = await world.coordinator.resolveAdmission(.rvc)
        #expect(after.evicting == [.aceStep])
        #expect(after.protectedByJobs.isEmpty)
    }

    @Test("F1 NEGATIVE CONTROL. Without the tracker the same Sketchpad job leaves ACE in evicting, and the boot stops it")
    func withoutTheTrackerTheBootStopsACEMidSong() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let (seen, _) = try await Self.sketchpadSongThenRVCBoot(
            decorated: false, in: world, raw: ScriptedSongGenerator())

        // This is the live defect: nothing registered the Sketchpad's job.
        #expect(seen.openWhileRendering.isEmpty)
        #expect(seen.plan.evicting == [.aceStep])
        #expect(seen.plan.protectedByJobs.isEmpty)
        #expect(seen.aceStopsDuringBoot == 1,
                "the RVC boot SIGTERMs ACE with the song half-rendered")
        #expect(seen.aceResidentAfterBoot == false)
    }

    // MARK: - F8's other half: ACE's own idle unload, and its negative control
    //
    // ACE's 600 s idle unload is armed the moment it becomes resident, and ONLY a job
    // disarms it. So an unregistered Sketchpad job was invisible to the timer too:
    // ten minutes after boot, ACE was SIGTERMed whether or not a song was rendering.

    @Test("F8 idle half. A Sketchpad-origin job disarms ACE's idle unload for the whole render")
    func sketchpadJobDisarmsTheIdleUnload() async throws {
        let gate = SleepGate()   // held closed until the render is under way
        let world = try await Self.world(
            aceIdleSeconds: 600, sleepSeconds: { _ in await gate.wait() })
        defer { try? FileManager.default.removeItem(at: world.storage) }
        #expect(await world.coordinator.pendingIdleUnloads()[.aceStep] != nil,
                "fixture: becoming resident arms the idle unload")
        let raw = ScriptedSongGenerator()
        let sketchpad = OriginStandIn(
            "sketchpad",
            wrapping: LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator))

        let jobID = try await sketchpad.generateSong(SongGenerationRequest(prompt: "x")).jobID
        #expect(await world.coordinator.pendingIdleUnloads().isEmpty,
                "a render in flight must not sit on an armed idle timer")

        // Ten minutes pass mid-render: the wake-up armed before the job wakes, finds
        // its epoch revoked and the model busy, and declines.
        await gate.open()
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(await world.aceSpy.callCount() == 0, "the song survives the ten-minute mark")
        #expect(await world.coordinator.openJobIDs(.aceStep) == [jobID])

        // The twin: the terminal poll re-arms the clock, and it fires AFTER the song.
        await raw.script(jobID, .success(.succeeded))
        _ = try await sketchpad.generationStatus(jobID: jobID)
        #expect(await Fixtures.eventually("the re-armed idle unload evicts ACE after the song") {
            await world.aceSpy.callCount() == 1
        })
    }

    @Test("F8 idle NEGATIVE CONTROL. Without the tracker ACE's idle unload stays armed mid-song and fires into the render")
    func withoutTheTrackerTheIdleUnloadFiresMidSong() async throws {
        let gate = SleepGate()
        let world = try await Self.world(
            aceIdleSeconds: 600, sleepSeconds: { _ in await gate.wait() })
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let sketchpad = OriginStandIn("sketchpad", wrapping: ScriptedSongGenerator())

        _ = try await sketchpad.generateSong(SongGenerationRequest(prompt: "x"))
        #expect(await world.coordinator.pendingIdleUnloads()[.aceStep] != nil,
                "nothing disarmed the timer: the render is invisible to it")

        await gate.open()
        #expect(await Fixtures.eventually("the idle unload fires with the song half-rendered") {
            await world.aceSpy.callCount() == 1
        })
        // Awaited too: the spy counts INSIDE the stop, and the coordinator books the
        // residency change only after the stop returns.
        #expect(await Fixtures.eventually("ACE is booked gone") {
            await world.coordinator.residency().models
                .first { $0.modelID == .aceStep }?.resident == false
        })
    }

    // MARK: - Where the tracker sits: below every origin and every poller

    @Test("The first terminal poll by ANY poller closes the job; every later one is a no-op")
    func anyPollerClosesAndLaterPollsAreNoOps() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedSongGenerator()
        let tracked = LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator)
        let sketchpad = OriginStandIn("sketchpad", wrapping: tracked)
        let importSeam = OriginStandIn("import", wrapping: tracked)
        // The presence poll and the clip-fix status poll read the tracker DIRECTLY:
        // `DAWProApp` builds both over `songGenerator`, the tracked handle.
        let presencePoll: @Sendable (String) async throws -> SongGenerationStatus = {
            try await tracked.generationStatus(jobID: $0)
        }

        let jobID = try await sketchpad.generateSong(SongGenerationRequest(prompt: "lo-fi rain")).jobID
        _ = try await sketchpad.generationStatus(jobID: jobID)
        #expect(await world.coordinator.openJobIDs(.aceStep) == [jobID], "`running` closes nothing")

        // A DIFFERENT poller than the submitter sees the terminal state first.
        await raw.script(jobID, .success(.succeeded))
        _ = try await presencePoll(jobID)
        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty)
        let settled = await world.coordinator.currentGeneration()

        _ = try await sketchpad.generationStatus(jobID: jobID)
        _ = try await importSeam.generationStatus(jobID: jobID)
        _ = try await presencePoll(jobID)
        #expect(await world.coordinator.currentGeneration() == settled,
                "a repeated terminal observation is not a residency transition")
        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty)
    }

    @Test("The tracker is not an observer: one call in is exactly one call out, and nothing calls back")
    func oneCallInIsOneCallOut() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedSongGenerator()
        let tracked = LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator)
        let presencePoll: @Sendable (String) async throws -> SongGenerationStatus = {
            try await tracked.generationStatus(jobID: $0)
        }
        let before = await world.coordinator.currentGeneration()

        let jobID = try await tracked.generateSong(SongGenerationRequest(prompt: "x")).jobID
        for _ in 0..<4 { _ = try await presencePoll(jobID) }
        await raw.script(jobID, .success(.succeeded))
        let last = try await presencePoll(jobID)

        #expect(last == ScriptedSongGenerator.status(jobID, .succeeded),
                "the status reaches the caller unchanged")
        #expect(await raw.submissions == [.generate])
        #expect(await raw.polls == Array(repeating: jobID, count: 5),
                "five polls in, five polls out: no hidden poll, no re-entry")
        #expect(await world.coordinator.currentGeneration() == before + 2,
                "exactly one open and one close; a running poll moves nothing")
    }

    // MARK: - The census: every submitting requirement

    @Test("Every submitting requirement opens a job: generateSong, extractStems, generateLegoTracks, repaintAudio")
    func everySubmittingRequirementOpensAJob() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedSongGenerator()
        let tracked = LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator)
        let mix = "/tmp/p2-sing-0-mix.wav"

        let song = try await tracked.generateSong(SongGenerationRequest(prompt: "x"))
        let stems = try await tracked.extractStems(
            StemExtractionRequest(sourceAudioPath: mix, trackNames: ["vocals", "drums"]))
        let lego = try await tracked.generateLegoTracks(LegoGenerationRequest(
            sourceAudioPath: mix, globalCaption: "warm lo-fi",
            tracks: [StemTrackRequest(trackName: "bass", localPrompt: "round")]))
        // ⚠️ Through the tracker's OWN override: the protocol-extension default throws
        // "unsupported", so a tracker without one would fail this line.
        let repaint = try await tracked.repaintAudio(
            RepaintRequest(srcAudioPath: mix, startSeconds: 4, endSeconds: 8))

        let jobIDs = [song.jobID, stems.jobID, lego.jobID, repaint.jobID]
        #expect(Set(jobIDs).count == 4)
        #expect(await world.coordinator.openJobIDs(.aceStep) == jobIDs.sorted())
        #expect(await raw.submissions == [.generate, .extract, .lego, .repaint],
                "each submission reached the raw client exactly once")
        #expect(await world.coordinator.resolveAdmission(.rvc).protectedByJobs == [.aceStep])

        for jobID in jobIDs {
            await raw.script(jobID, .success(.succeeded))
            _ = try await tracked.generationStatus(jobID: jobID)
        }
        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty)
        #expect(await world.coordinator.resolveAdmission(.rvc).evicting == [.aceStep])
    }

    // MARK: - Every terminal path closes; nothing else does

    /// How a poll can report that a job is over.
    enum TerminalPoll: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case succeeded
        /// A provider that RETURNS `.failed` instead of throwing.
        case failedState
        case jobFailed
        case jobNotFound

        var testDescription: String { rawValue }

        /// The error the caller must receive unchanged, or nil when the poll returns.
        func thrown(_ jobID: String) -> ACEStepError? {
            switch self {
            case .succeeded, .failedState: return nil
            case .jobFailed: return .jobFailed(jobID: jobID, message: "CUDA out of memory")
            case .jobNotFound: return .jobNotFound(jobID)
            }
        }

        func outcome(_ jobID: String) -> Result<SongGenerationState, any Error> {
            switch self {
            case .succeeded: return .success(.succeeded)
            case .failedState: return .success(.failed)
            case .jobFailed, .jobNotFound: return .failure(thrown(jobID)!)
            }
        }
    }

    @Test("Each terminal path closes the job: succeeded, a failed state, jobFailed, jobNotFound",
          arguments: TerminalPoll.allCases)
    func eachTerminalPathClosesTheJob(_ path: TerminalPoll) async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedSongGenerator()
        let tracked = LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator)
        let jobID = try await tracked.generateSong(SongGenerationRequest(prompt: "x")).jobID
        #expect(await world.coordinator.openJobIDs(.aceStep) == [jobID])

        await raw.script(jobID, path.outcome(jobID))
        let expected = path.thrown(jobID)
        do {
            let status = try await tracked.generationStatus(jobID: jobID)
            #expect(expected == nil, "\(path) returned \(status.state) instead of throwing")
        } catch let error as ACEStepError {
            #expect(error == expected, "the error must reach the caller unchanged")
        }
        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty,
                "\(path) must close the job: a leaked job pins ACE for the whole lease")
        #expect(await world.coordinator.resolveAdmission(.rvc).evicting == [.aceStep])
    }

    @Test("F8 regression. Non-terminal polls and 'could not ask' errors leave the job open")
    func transientPollsKeepTheJobOpen() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedSongGenerator()
        let tracked = LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator)
        let jobID = try await tracked.generateSong(SongGenerationRequest(prompt: "x")).jobID

        for state in [SongGenerationState.queued, .running] {
            await raw.script(jobID, .success(state))
            _ = try await tracked.generationStatus(jobID: jobID)
            #expect(await world.coordinator.openJobIDs(.aceStep) == [jobID], "\(state) closes nothing")
        }

        // ⚠️ The mistake the wire already paid for once (`ModelLifecycleCommandTests`'
        // F8 regression): closing on ANY error turns one dropped connection mid-render
        // into a SIGTERM. A cancelled POLL is on this list too: ACE-Step has no abort
        // route, so the render goes on without the poller.
        struct ForeignProviderError: Error {}
        let couldNotAsk: [any Error] = [
            ACEStepError.sidecarUnreachable("connection reset"),
            ACEStepError.requestFailed(status: 504, body: "gateway timeout"),
            ACEStepError.malformedResponse("truncated body"),
            ACEStepError.modelSlotUnavailable(model: "acestep-v15-xl-sft", detail: "no slot 2"),
            CancellationError(),
            URLError(.cancelled),
            ForeignProviderError(),
        ]
        for error in couldNotAsk {
            await raw.script(jobID, .failure(error))
            await #expect(throws: (any Error).self) {
                try await tracked.generationStatus(jobID: jobID)
            }
            #expect(await world.coordinator.openJobIDs(.aceStep) == [jobID],
                    "\(error) must leave the render protected; the lease repairs a leak")
        }

        // ANTI-VACUITY: the loop above passes just as well against a tracker that
        // never closes anything, so prove an error that DOES mean "over" still closes.
        await raw.script(jobID, .failure(ACEStepError.jobFailed(jobID: jobID, message: "boom")))
        await #expect(throws: ACEStepError.self) {
            try await tracked.generationStatus(jobID: jobID)
        }
        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty)
    }

    @Test("A refused or cancelled submission opens nothing")
    func refusedOrCancelledSubmissionOpensNothing() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let before = await world.coordinator.currentGeneration()

        let refusing = ScriptedSongGenerator()
        await refusing.failSubmissions(with: ACEStepError.sidecarUnreachable("connection refused"))
        let tracked = LifecycleTrackingSongGenerator(
            wrapping: refusing, coordinator: world.coordinator)
        await #expect(throws: ACEStepError.self) {
            try await tracked.generateSong(SongGenerationRequest(prompt: "x"))
        }
        await #expect(throws: ACEStepError.self) {
            try await tracked.repaintAudio(RepaintRequest(srcAudioPath: "/tmp/a.wav", startSeconds: 0))
        }

        // Cancelled while the submission is in flight, as a Sketchpad task can be.
        let holding = ScriptedSongGenerator()
        await holding.holdSubmissionsUntilCancelled()
        let slow = LifecycleTrackingSongGenerator(wrapping: holding, coordinator: world.coordinator)
        let task = Task { try await slow.generateSong(SongGenerationRequest(prompt: "x")) }
        await holding.entered.wait()
        task.cancel()
        switch await task.result {
        case .success(let submission):
            Issue.record("a cancelled submission was accepted as \(submission.jobID)")
        case .failure(let error):
            #expect(error is CancellationError, "got \(error)")
        }

        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty,
                "a submission that was never accepted has no job to leak")
        #expect(await world.coordinator.currentGeneration() == before)
    }

    // MARK: - The wire's own hooks stay: double registration is harmless

    @Test("Double registration with the wire's own hooks is harmless: one job, one close, one re-arm")
    func wireHooksAndTrackerTogetherAreHarmless() async throws {
        // Held closed: this test asserts on ARMING the idle clock, never on it firing.
        let gate = SleepGate()
        let world = try await Self.world(
            aceIdleSeconds: 600, sleepSeconds: { _ in await gate.wait() })
        defer { try? FileManager.default.removeItem(at: world.storage) }
        #expect(await world.coordinator.idleWakeUpsEverScheduled() == 1,
                "fixture: becoming resident arms one wake-up")
        let raw = ScriptedSongGenerator()
        let tracked = LifecycleTrackingSongGenerator(wrapping: raw, coordinator: world.coordinator)
        let wire = OriginStandIn("wire", wrapping: tracked)

        // `ai.generateSong` (`Commands.swift` ~7769): the submit goes through the wire's
        // observer, then the wire's own hook opens the SAME id.
        let jobID = try await wire.generateSong(SongGenerationRequest(prompt: "x")).jobID
        let afterTracker = await world.coordinator.currentGeneration()
        await world.coordinator.noteJobStarted(.aceStep, jobID: jobID)
        #expect(await world.coordinator.openJobIDs(.aceStep) == [jobID], "one job, not two")
        #expect(await world.coordinator.currentGeneration() == afterTracker,
                "the duplicate open is not a residency transition")
        #expect(await world.coordinator.pendingIdleUnloads().isEmpty,
                "the idle clock stays disarmed mid-render")

        // `ai.generationStatus` on a terminal state (`Commands.swift` ~7792): the tracker
        // closes on the way up, then the wire's own hook closes the same id again.
        await raw.script(jobID, .success(.succeeded))
        _ = try await wire.generationStatus(jobID: jobID)
        let afterClose = await world.coordinator.currentGeneration()
        let armedAfterClose = await world.coordinator.idleWakeUpsEverScheduled()
        await world.coordinator.noteJobEnded(.aceStep, jobID: jobID)

        #expect(await world.coordinator.openJobIDs(.aceStep).isEmpty)
        #expect(await world.coordinator.currentGeneration() == afterClose,
                "the duplicate close is not a residency transition")
        #expect(armedAfterClose == 2, "one arming on becoming resident, one on the close")
        #expect(await world.coordinator.idleWakeUpsEverScheduled() == armedAfterClose,
                "the duplicate close re-armed nothing")
        #expect(await world.coordinator.pendingIdleUnloads().count == 1)

        // Release the clock: the ONE armed wake-up fires once, and the wake-up the
        // job disarmed declines. Awaited, so no eviction outlives the test.
        await gate.open()
        #expect(await Fixtures.eventually("the one armed wake-up fires") {
            await world.aceSpy.callCount() == 1
        })
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(await world.aceSpy.callCount() == 1, "exactly one eviction, not one per close")
    }

    // MARK: - The rule, and the inert case

    @Test("The terminal rule: jobFailed and jobNotFound close; every other error keeps protecting")
    func terminalRuleIsAsymmetric() {
        typealias Tracker = LifecycleTrackingSongGenerator
        #expect(Tracker.errorProvesJobIsOver(ACEStepError.jobFailed(jobID: "j", message: "boom")))
        #expect(Tracker.errorProvesJobIsOver(ACEStepError.jobNotFound("j")))

        #expect(!Tracker.errorProvesJobIsOver(ACEStepError.sidecarUnreachable("reset")))
        #expect(!Tracker.errorProvesJobIsOver(ACEStepError.requestFailed(status: 504, body: "")))
        #expect(!Tracker.errorProvesJobIsOver(ACEStepError.malformedResponse("")))
        #expect(!Tracker.errorProvesJobIsOver(
            ACEStepError.modelSlotUnavailable(model: "m", detail: "")))
        struct Foreign: Error {}
        #expect(!Tracker.errorProvesJobIsOver(Foreign()))
        #expect(!Tracker.errorProvesJobIsOver(CancellationError()))
        #expect(!Tracker.errorProvesJobIsOver(URLError(.timedOut)))

        #expect(Tracker.stateIsTerminal(.succeeded))
        #expect(Tracker.stateIsTerminal(.failed))
        #expect(!Tracker.stateIsTerminal(.queued))
        #expect(!Tracker.stateIsTerminal(.running))
    }

    @Test("Over a coordinator that knows no models the tracker is inert: it passes through and writes nothing")
    func inertOverAnEmptyCoordinator() async throws {
        let storage = Fixtures.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Fixtures.epoch)
        let coordinator = Fixtures.coordinator(machine: machine, storage: storage)
        let raw = ScriptedSongGenerator()
        let tracked = LifecycleTrackingSongGenerator(wrapping: raw, coordinator: coordinator)

        let jobID = try await tracked.generateSong(SongGenerationRequest(prompt: "x")).jobID
        await raw.script(jobID, .success(.succeeded))
        let status = try await tracked.generationStatus(jobID: jobID)

        #expect(status == ScriptedSongGenerator.status(jobID, .succeeded))
        #expect(await coordinator.openJobIDs(.aceStep).isEmpty)
        #expect(await coordinator.currentGeneration() == 0)
        #expect(!FileManager.default.fileExists(atPath: storage.path),
                "an inert coordinator writes nothing to disk")
    }
}
