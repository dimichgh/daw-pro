import Foundation
import Testing

@testable import AIServices

// MARK: - Fixtures (p2-sing-0, the RVC half)
//
// `MachineStub`, `SpyEvictor` and the coordinator builders come from
// `ModelLifecycleCoordinatorTests.swift`, and `LifecycleTrackingEntrySignal` from
// `LifecycleTrackingSongGeneratorTests.swift`, all in this same target. No test here
// starts a sidecar or signals a process.

/// The raw `VoiceConversionClient`'s stand-in. Every `convert`/`train` call first
/// ARRIVES (so a test can wait for it), then runs the test's probe while the call is
/// still in flight, then finishes the way the test scripted.
private actor ScriptedVoiceConverter: VoiceConverting {
    enum Finish: Sendable {
        case succeed
        case fail(VoiceConversionError)
        /// Waits until its task is cancelled, then throws `CancellationError`.
        case holdUntilCancelled
    }

    let entered = LifecycleTrackingEntrySignal()
    private(set) var calls: [String] = []
    private var finish: Finish = .succeed
    private var probe: (@Sendable () async -> Void)?

    func finish(with finish: Finish) { self.finish = finish }
    func probeDuringCall(_ probe: @escaping @Sendable () async -> Void) { self.probe = probe }

    func listVoices() async throws -> [VoiceDescriptor] {
        calls.append("listVoices")
        return [VoiceDescriptor(id: "my-voice", name: "My voice", state: "ready")]
    }

    func voiceStatus(voiceID: String) async throws -> VoiceDescriptor {
        calls.append("voiceStatus")
        return VoiceDescriptor(id: voiceID, name: voiceID, state: "ready")
    }

    func convert(_ request: VoiceConvertRequest) async throws -> VoiceConvertResult {
        calls.append("convert")
        try await run()
        return VoiceConvertResult(
            outputPath: "/tmp/p2-sing-0-converted.wav", voiceId: request.voiceId,
            inputSeconds: 4, engineLoadSeconds: 0.1, inferSeconds: 0.2,
            sampleRate: 48_000, realConversion: true)
    }

    func train(_ request: VoiceTrainRequest) async throws -> Data {
        calls.append("train")
        try await run()
        return Data(#"{"voiceId":"my-voice"}"#.utf8)
    }

    private func run() async throws {
        await entered.arrive()
        if let probe { await probe() }
        switch finish {
        case .succeed:
            return
        case .fail(let error):
            throw error
        case .holdUntilCancelled:
            try await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
}

/// What the coordinator looked like from INSIDE a running call.
private actor DuringCall {
    private(set) var openJobs: [[String]] = []
    private(set) var plans: [ModelAdmission.Plan] = []

    func record(open: [String], plan: ModelAdmission.Plan) {
        openJobs.append(open)
        plans.append(plan)
    }
}

// MARK: - The suite

/// p2-sing-0, the RVC half: `convert` and `train` hold a job open for exactly as long
/// as they run, against the REAL coordinator. The reverse direction of F1.
///
/// Nonisolated on purpose: it drives the coordinator actor and the tracker, and no
/// `@MainActor` type.
@Suite("Lifecycle tracking — every RVC job registers (p2-sing-0)", .timeLimit(.minutes(1)))
struct LifecycleTrackingVoiceConverterTests {

    fileprivate typealias Fixtures = ModelLifecycleCoordinatorTests

    /// The two RVC calls that do work on the model.
    enum VoiceJob: String, CaseIterable, Sendable, CustomTestStringConvertible {
        case convert, train

        var testDescription: String { rawValue }

        var prefix: String {
            switch self {
            case .convert: return LifecycleTrackingVoiceConverter.convertJobPrefix
            case .train: return LifecycleTrackingVoiceConverter.trainJobPrefix
            }
        }

        /// What the facade answers when each call fails today: a convert against a
        /// voice it does not know, and training, which always answers 501.
        var realisticFailure: VoiceConversionError {
            switch self {
            case .convert:
                return .requestFailed(status: 404, code: "unknownVoice", message: "no voice 'x'")
            case .train:
                return .requestFailed(
                    status: 501, code: "trainingNotYetAvailable", message: "training ships later")
            }
        }

        fileprivate func run(on converter: any VoiceConverting) async throws {
            switch self {
            case .convert:
                _ = try await converter.convert(
                    VoiceConvertRequest(inputPath: "/tmp/p2-sing-0-dry.wav", voiceId: "my-voice"))
            case .train:
                try await converter.train(
                    VoiceTrainRequest(name: "My voice", datasetDir: "/tmp/p2-sing-0-dataset"))
            }
        }
    }

    /// A hermetic coordinator with ACE and RVC registered and RVC booked resident: the
    /// state a conversion runs in.
    fileprivate struct World {
        let coordinator: ModelLifecycleCoordinator
        let aceSpy: SpyEvictor
        let rvcSpy: SpyEvictor
        let storage: URL
    }

    fileprivate static func world() async throws -> World {
        let storage = Fixtures.tempDirectory()
        let machine = MachineStub(availableGiB: 110, at: Fixtures.epoch)
        let coordinator = Fixtures.coordinator(machine: machine, storage: storage)
        let aceSpy = SpyEvictor(modelID: .aceStep)
        let rvcSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(
            Fixtures.model("ace-step", holdGiB: 74, port: 8001), evictor: aceSpy)
        await coordinator.register(Fixtures.model("rvc", holdGiB: 3, port: 8002), evictor: rvcSpy)
        try await Fixtures.makeResident(coordinator, .rvc)
        return World(coordinator: coordinator, aceSpy: aceSpy, rvcSpy: rvcSpy, storage: storage)
    }

    /// What an ACE boot saw and did while an RVC call was running.
    fileprivate struct BootDuringCall {
        let openDuringCall: [String]
        let planDuringCall: ModelAdmission.Plan
        let rvcStopsDuringBoot: Int
        let openAfterCall: [String]
        let planAfterCall: ModelAdmission.Plan
    }

    /// The reverse of F1, with ONE axis varied: whether the tracker wraps the raw
    /// client. ACE boots through the real admission path (`resolveAdmission`, then
    /// `commitAdmission`, where a SIGTERM lands) from INSIDE the running call, so the
    /// boot lands mid-call by construction, not by timing. The boot is released
    /// unhealthy, so ACE never becomes resident and can be planned again afterwards.
    fileprivate static func aceBootDuring(
        _ job: VoiceJob, decorated: Bool, in world: World
    ) async throws -> BootDuringCall {
        let raw = ScriptedVoiceConverter()
        let converter: any VoiceConverting = decorated
            ? LifecycleTrackingVoiceConverter(wrapping: raw, coordinator: world.coordinator)
            : raw
        let during = DuringCall()
        let coordinator = world.coordinator
        await raw.probeDuringCall {
            let open = await coordinator.openJobIDs(.rvc)
            let plan = await coordinator.resolveAdmission(.aceStep)
            if let ticket = try? await coordinator.commitAdmission(plan, for: .aceStep) {
                await coordinator.admitted(ticket, healthy: false)
            }
            await during.record(open: open, plan: plan)
        }

        try await job.run(on: converter)

        let plans = await during.plans
        let openJobs = await during.openJobs
        return BootDuringCall(
            openDuringCall: try #require(openJobs.first, "fixture: the probe must have run"),
            planDuringCall: try #require(plans.first),
            rvcStopsDuringBoot: await world.rvcSpy.callCount(),
            openAfterCall: await world.coordinator.openJobIDs(.rvc),
            planAfterCall: await world.coordinator.resolveAdmission(.aceStep))
    }

    // MARK: - The reverse of F1, and its negative control

    @Test("Reverse F1. A running RVC job protects RVC: an ACE boot mid-call leaves RVC alone",
          arguments: VoiceJob.allCases)
    func runningJobProtectsRVCFromAnACEBoot(_ job: VoiceJob) async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let seen = try await Self.aceBootDuring(job, decorated: true, in: world)

        #expect(seen.openDuringCall.count == 1, "one job while \(job) runs")
        #expect(seen.openDuringCall.allSatisfy { $0.hasPrefix(job.prefix) },
                "the job id names the call: \(seen.openDuringCall)")
        #expect(seen.planDuringCall.protectedByJobs == [.rvc])
        #expect(seen.planDuringCall.evicting.isEmpty)
        #expect(seen.rvcStopsDuringBoot == 0, "the ACE boot must not SIGTERM RVC mid-\(job)")

        // The twin: once the call is over, the same boot plans RVC into `evicting`.
        #expect(seen.openAfterCall.isEmpty)
        #expect(seen.planAfterCall.evicting == [.rvc])
    }

    @Test("Reverse F1 NEGATIVE CONTROL. Without the tracker the same call leaves RVC in evicting, and the boot stops it",
          arguments: VoiceJob.allCases)
    func withoutTheTrackerTheBootStopsRVCMidCall(_ job: VoiceJob) async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let seen = try await Self.aceBootDuring(job, decorated: false, in: world)

        // This is the live defect: `convert` and `train` never registered.
        #expect(seen.openDuringCall.isEmpty)
        #expect(seen.planDuringCall.evicting == [.rvc])
        #expect(seen.planDuringCall.protectedByJobs.isEmpty)
        #expect(seen.rvcStopsDuringBoot == 1, "the ACE boot SIGTERMs RVC in the middle of \(job)")
    }

    // MARK: - Every exit closes the job

    enum Exit: String, CaseIterable, Sendable {
        case returns, throwsError, cancelled
    }

    struct ExitCase: Sendable, CustomTestStringConvertible {
        let job: VoiceJob
        let exit: Exit
        var testDescription: String { "\(job.rawValue) \(exit.rawValue)" }
    }

    static let exitCases: [ExitCase] = VoiceJob.allCases.flatMap { job in
        Exit.allCases.map { ExitCase(job: job, exit: $0) }
    }

    @Test("Every exit closes the job: a result, a thrown error, a cancellation (convert and train)",
          arguments: exitCases)
    func everyExitClosesTheJob(_ exitCase: ExitCase) async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedVoiceConverter()
        let tracked = LifecycleTrackingVoiceConverter(wrapping: raw, coordinator: world.coordinator)
        let during = DuringCall()
        let coordinator = world.coordinator
        await raw.probeDuringCall {
            await during.record(
                open: await coordinator.openJobIDs(.rvc),
                plan: await coordinator.resolveAdmission(.aceStep))
        }

        switch exitCase.exit {
        case .returns:
            await raw.finish(with: .succeed)
            try await exitCase.job.run(on: tracked)
        case .throwsError:
            let failure = exitCase.job.realisticFailure
            await raw.finish(with: .fail(failure))
            await #expect(throws: failure) {
                try await exitCase.job.run(on: tracked)
            }
        case .cancelled:
            await raw.finish(with: .holdUntilCancelled)
            let task = Task { try await exitCase.job.run(on: tracked) }
            await raw.entered.wait()
            task.cancel()
            switch await task.result {
            case .success:
                Issue.record("a cancelled \(exitCase.job) completed")
            case .failure(let error):
                #expect(error is CancellationError, "got \(error)")
            }
        }

        let openDuring = try #require(await during.openJobs.first, "fixture: the probe must have run")
        #expect(openDuring.count == 1 && openDuring.allSatisfy { $0.hasPrefix(exitCase.job.prefix) },
                "the job was open while the call ran: \(openDuring)")
        #expect(await world.coordinator.openJobIDs(.rvc).isEmpty,
                "\(exitCase) must close the job: a leaked job pins RVC for the whole lease")
        #expect(await world.coordinator.resolveAdmission(.aceStep).evicting == [.rvc])
    }

    // MARK: - One id per call

    @Test("Two conversions in flight hold two jobs: the first to finish cannot un-protect the second")
    func concurrentCallsHoldSeparateJobs() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedVoiceConverter()
        await raw.finish(with: .holdUntilCancelled)
        let tracked = LifecycleTrackingVoiceConverter(wrapping: raw, coordinator: world.coordinator)

        let first = Task { try await VoiceJob.convert.run(on: tracked) }
        await raw.entered.wait(forArrivals: 1)
        let second = Task { try await VoiceJob.convert.run(on: tracked) }
        await raw.entered.wait(forArrivals: 2)

        let open = await world.coordinator.openJobIDs(.rvc)
        #expect(open.count == 2, "two calls, two jobs: \(open)")

        first.cancel()
        _ = await first.result
        #expect(await world.coordinator.openJobIDs(.rvc).count == 1,
                "the first call's exit closed only its own job")
        #expect(await world.coordinator.resolveAdmission(.aceStep).protectedByJobs == [.rvc],
                "the conversion still running stays protected")

        second.cancel()
        _ = await second.result
        #expect(await world.coordinator.openJobIDs(.rvc).isEmpty)
        #expect(await world.coordinator.resolveAdmission(.aceStep).evicting == [.rvc])
    }

    // MARK: - Reads are not jobs

    @Test("Reads open no job: listVoices, voiceStatus and availableVoiceTargets pass straight through")
    func readsOpenNoJob() async throws {
        let world = try await Self.world()
        defer { try? FileManager.default.removeItem(at: world.storage) }
        let raw = ScriptedVoiceConverter()
        let tracked = LifecycleTrackingVoiceConverter(wrapping: raw, coordinator: world.coordinator)
        let before = await world.coordinator.currentGeneration()

        let voices = try await tracked.listVoices()
        let base = try await tracked.voiceStatus(voiceID: "base")
        let targets = try await tracked.availableVoiceTargets()

        #expect(voices.map(\.id) == ["my-voice"])
        #expect(base.id == "base")
        #expect(targets.map(\.id) == ["base", "my-voice"])
        #expect(await raw.calls == ["listVoices", "voiceStatus", "voiceStatus", "listVoices"],
                "each read reached the raw client exactly once")
        #expect(await world.coordinator.currentGeneration() == before, "no job hook ran")
        #expect(await world.coordinator.openJobIDs(.rvc).isEmpty)
    }
}
