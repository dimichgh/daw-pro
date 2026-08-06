import AIServices
import DAWCore
import Foundation
import Testing

@testable import DAWControl

// MARK: - Local hermetic fixtures
//
// ⚠️ Deliberate duplicates of `AIServicesTests`' `MachineStub`/`SpyEvictor`.
// Swift test targets do not share symbols, and the alternative — promoting them
// into shipping `AIServices` code so two suites can see one copy — would put a
// test double in the product. Two small doubles is the cheaper mistake.

/// Injected memory sample + clock. Nothing here reads the host, so no verdict in
/// this suite depends on how much Chrome the developer has open.
final class MachineStub: @unchecked Sendable {
    private let lock = NSLock()
    private let availableBytes: UInt64
    private let physicalBytes: UInt64
    private let instant: Date

    init(availableGiB: UInt64, physicalGiB: UInt64 = 128, at instant: Date) {
        self.availableBytes = availableGiB << 30
        self.physicalBytes = physicalGiB << 30
        self.instant = instant
    }

    var now: Date { lock.lock(); defer { lock.unlock() }; return instant }

    var snapshot: ModelMemory.Snapshot {
        lock.lock(); defer { lock.unlock() }
        let used = physicalBytes - min(physicalBytes, availableBytes)
        return ModelMemory.Snapshot(
            pageSizeBytes: 16384, physicalBytes: physicalBytes, internalBytes: used,
            purgeableBytes: 0, wiredBytes: 0, compressorBytes: 0, freeBytes: availableBytes,
            speculativeBytes: 0, externalBytes: 0, sampledAt: instant)
    }
}

/// Records calls and **stops nothing** — no process on 8001/8002 is ever
/// signalled by this suite.
actor SpyEvictor: ModelEvicting {
    nonisolated let modelID: ModelID
    private var calls = 0
    private let stopsCleanly: Bool

    init(modelID: ModelID, stopsCleanly: Bool = true) {
        self.modelID = modelID
        self.stopsCleanly = stopsCleanly
    }

    func callCount() -> Int { calls }

    func evictWithoutCoordinator() async throws -> ModelStopEvidence {
        calls += 1
        return ModelStopEvidence(
            portFree: stopsCleanly,
            portLookupDetail: stopsCleanly ? nil : "port still held (spy)",
            probeUnreachable: stopsCleanly,
            treePidsAliveAfter: stopsCleanly ? [] : [4242],
            detail: stopsCleanly ? "spy stopped it" : "spy did not stop it")
    }
}

/// Control-protocol coverage for m23-dl's two additions — `ai.modelResidency`
/// (the read) and `ai.modelUnload` (the N-model verb).
///
/// ⚠️⚠️ **NO SIDECAR IS EVER STARTED, and no real one is ever stopped.** Every
/// router here is built with its OWN hermetic `ModelLifecycleCoordinator`
/// (temporary storage, stubbed memory sample and clock, spy evictors that stop
/// nothing), never the process-wide `.shared` one. A test that reached `.shared`
/// would SIGTERM whatever the developer happens to be running on 8001/8002.
///
/// ⚠️ What this suite does NOT assert, because it no longer exists: any
/// admission refusal for memory. The user cut the memory gate on 2026-08-05
/// (*"let's not check for memory then, let it fail if this happens"*), so no verb
/// on this wire can refuse a boot for memory and there is no `force` parameter
/// anywhere. See `ModelAdmissionTests` for what replaced it.
@MainActor
@Suite("Model lifecycle — control protocol (m23-dl)")
struct ModelLifecycleCommandTests {

    private static let gib: UInt64 = 1 << 30
    private static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeCoordinator(storage: URL) -> ModelLifecycleCoordinator {
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        return ModelLifecycleCoordinator(
            sampleMemory: { machine.snapshot },
            now: { machine.now },
            storageDirectory: storage,
            settleSeconds: 0)
    }

    /// ⚠️ `idleUnloadSeconds` defaults to nil, matching `ModelDescriptor`'s own
    /// default — a model with no idle configuration arms NO timer. Tests that
    /// assert about the idle clock must pass it explicitly; without that, an
    /// assertion like "closing the last job re-arms the wake-up" fails against
    /// perfectly correct code, and the tempting fix (assert `== nil`) would
    /// silently pin the opposite of the intended claim.
    private func descriptor(
        _ id: String, port: Int, hold: UInt64, idleUnloadSeconds: Double? = nil
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: ModelID(rawValue: id), displayName: "Model \(id)",
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            seededHoldBytes: hold, seededHoldProvenance: "measured in a test",
            estimatedHoldBytes: hold,
            estimatedHoldProvenance: "estimated in a test, never measured resident",
            idleUnloadSeconds: idleUnloadSeconds)
    }

    private func makeRouter(
        _ coordinator: ModelLifecycleCoordinator,
        songGenerator: SongGenerating? = nil
    ) -> CommandRouter {
        let store = ProjectStore()
        store.media = FakeMedia()
        if let songGenerator {
            return CommandRouter(
                store: store, songGenerator: songGenerator, modelLifecycle: coordinator)
        }
        return CommandRouter(store: store, modelLifecycle: coordinator)
    }

    /// Boots a model into residency the way a real `start()` does, so the job
    /// hooks below have something that can actually be evicted.
    private func makeResident(
        _ coordinator: ModelLifecycleCoordinator, _ id: ModelID
    ) async throws {
        let plan = await coordinator.resolveAdmission(id)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: id))
        await coordinator.admitted(ticket, healthy: true)
    }

    private static func tempDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("m23dl-wire-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: - Wire law

    @Test("both verbs are registered at the END of allCommands; count 171 -> 173")
    func commandsRegisteredAtTheEnd() {
        let all = CommandRouter.allCommands
        #expect(all.count == 173)
        #expect(all.dropLast().last == "ai.modelResidency")
        #expect(all.last == "ai.modelUnload")
        // Additive: every neighbouring lifecycle verb is untouched, in place.
        for name in ["ai.sidecarStatus", "ai.sidecarStart", "ai.sidecarStop",
                     "vc.sidecarStatus", "vc.sidecarStart", "vc.sidecarStop"] {
            #expect(all.contains(name), "\(name) missing")
        }
        // ⚠️ NO `force` was added to either start verb. It would have overridden
        // the memory refusal that no longer exists, and
        // `WireHardeningM16ETests` uses `force` as its stray-param probe against
        // `ai.sidecarStop` — adding it symmetrically would break that test in a
        // way that reads as mysterious rather than deliberate.
        #expect(!all.contains("ai.sidecarStartForced"))
    }

    // MARK: - ai.modelResidency

    @Test("ai.modelResidency reports the nonce, the machine and every registered model")
    func residencyShape() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: nil)
        await coordinator.register(
            descriptor("rvc", port: 8002, hold: 3 * Self.gib), evictor: nil)
        let router = makeRouter(coordinator)

        let response = await router.handle(
            ControlRequest(id: "1", command: "ai.modelResidency"))
        #expect(response.ok, "\(response.error ?? "?")")
        let result = try #require(response.result)
        #expect(result["generation"]?.doubleValue != nil)
        #expect(result["memory"]?.objectValue?["availableBytes"]?.doubleValue
            == Double(110 * Self.gib))
        let models = try #require(result["models"]?.arrayValue)
        #expect(models.count == 2)
        let ace = try #require(models.first { $0.objectValue?["modelID"]?.stringValue == "ace-step" }?
            .objectValue)
        #expect(ace["port"]?.doubleValue == 8001)
        #expect(ace["resident"]?.boolValue == false)
        #expect(ace["holdConfidence"]?.stringValue == "measured")
        // ⚠️ Off by default: `portBusy`/`pids` cost a `ps` and an `lsof` spawn
        // per model, and the obvious next feature is a 1 Hz status-bar poll.
        #expect(ace["portBusy"] == nil)
        #expect(ace["pids"] == nil)
    }

    @Test("ai.modelResidency accepts includeProcessDetail and rejects a stray param")
    func residencyParams() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let router = makeRouter(coordinator)

        let accepted = await router.handle(ControlRequest(
            id: "1", command: "ai.modelResidency",
            params: ["includeProcessDetail": .bool(false)]))
        #expect(accepted.ok, "\(accepted.error ?? "?")")

        let rejected = await router.handle(ControlRequest(
            id: "2", command: "ai.modelResidency", params: ["bogus": .bool(true)]))
        #expect(rejected.ok == false)
        #expect(rejected.error?.contains("bogus") == true)
    }

    @Test("includeProcessDetail: true really probes the port — portBusy is false, not absent")
    func residencyProcessDetailProbesTheHost() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        // ⚠️⚠️ **PORT 49731, DELIBERATELY.** Not 8001 and not 8002: this leg is
        // the one place in the suite that actually runs `lsof`, and pointing it
        // at a real sidecar port would make the verdict depend on whether the
        // developer happens to have ACE or RVC running. A high port nothing
        // listens on is the only port whose answer is knowable in advance.
        await coordinator.register(
            descriptor("ace-step", port: 49731, hold: 74 * Self.gib), evictor: nil)
        let router = makeRouter(coordinator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.modelResidency",
            params: ["includeProcessDetail": .bool(true)]))
        #expect(response.ok, "\(response.error ?? "?")")
        let ace = try #require(response.result?["models"]?.arrayValue?.first?.objectValue)

        // ⭐ THE POINT OF THIS TEST. `portBusy` exists so `resident: false` cannot
        // lie about a HAND-STARTED sidecar the coordinator never admitted. Every
        // other test in this suite asserts it is `nil` (off by default), which
        // means the branch that computes it — an `lsof` spawn per model — was
        // never once executed in Swift. A `portBusy` that always crashed, always
        // returned nil, or spawned nothing would have passed the whole suite.
        #expect(ace["portBusy"] != nil, "the field must be PRESENT when it was asked for")
        #expect(ace["portBusy"]?.boolValue == false, "nothing listens on 49731")
        #expect(ace["resident"]?.boolValue == false)
    }

    @Test("The nonce MOVES across an unload — an unload that did not bump it did not happen")
    func residencyNonceMoves() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let spy = SpyEvictor(modelID: .aceStep)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: spy)
        let router = makeRouter(coordinator)

        let before = await router.handle(ControlRequest(id: "1", command: "ai.modelResidency"))
        let generationBefore = try #require(before.result?["generation"]?.doubleValue)

        let unload = await router.handle(ControlRequest(
            id: "2", command: "ai.modelUnload", params: ["modelId": .string("ace-step")]))
        #expect(unload.ok, "\(unload.error ?? "?")")

        let after = await router.handle(ControlRequest(id: "3", command: "ai.modelResidency"))
        let generationAfter = try #require(after.result?["generation"]?.doubleValue)
        #expect(generationAfter > generationBefore)
        #expect(await spy.callCount() == 1)
    }

    // MARK: - ai.modelUnload

    @Test("ai.modelUnload with a modelId returns evidence for exactly that model")
    func unloadOneModel() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let aceSpy = SpyEvictor(modelID: .aceStep)
        let rvcSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: aceSpy)
        await coordinator.register(
            descriptor("rvc", port: 8002, hold: 3 * Self.gib), evictor: rvcSpy)
        let router = makeRouter(coordinator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.modelUnload", params: ["modelId": .string("ace-step")]))
        #expect(response.ok, "\(response.error ?? "?")")
        let models = try #require(response.result?["models"]?.arrayValue)
        #expect(models.count == 1)
        let report = try #require(models.first?.objectValue)
        #expect(report["modelID"]?.stringValue == "ace-step")
        #expect(report["stopped"]?.boolValue == true)
        #expect(report["reason"]?.stringValue == "explicit")
        // The three AUTHORITY limbs ride the wire — this is what makes
        // "did it unload?" an observation instead of a claim.
        let evidence = try #require(report["evidence"]?.objectValue)
        #expect(evidence["portFree"]?.boolValue == true)
        #expect(evidence["probeUnreachable"]?.boolValue == true)
        #expect(evidence["treePidsAliveAfter"]?.arrayValue?.isEmpty == true)
        // Corroboration rides too, and it decided nothing.
        #expect(evidence["memoryVerdict"]?.stringValue != nil)
        #expect(await aceSpy.callCount() == 1)
        #expect(await rvcSpy.callCount() == 0, "only the named model is stopped")
    }

    @Test("ai.modelUnload with all: true unloads every registered model")
    func unloadAllModels() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let aceSpy = SpyEvictor(modelID: .aceStep)
        let rvcSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: aceSpy)
        await coordinator.register(
            descriptor("rvc", port: 8002, hold: 3 * Self.gib), evictor: rvcSpy)
        let router = makeRouter(coordinator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.modelUnload", params: ["all": .bool(true)]))
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["models"]?.arrayValue?.count == 2)
        #expect(await aceSpy.callCount() == 1)
        #expect(await rvcSpy.callCount() == 1)
    }

    @Test("BOTH and NEITHER are teaching errors naming the valid ids (m23-cy pattern)")
    func exactlyOneOfModelIdOrAll() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let spy = SpyEvictor(modelID: .aceStep)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: spy)
        await coordinator.register(
            descriptor("rvc", port: 8002, hold: 3 * Self.gib), evictor: nil)
        let router = makeRouter(coordinator)

        let both = await router.handle(ControlRequest(
            id: "1", command: "ai.modelUnload",
            params: ["modelId": .string("ace-step"), "all": .bool(true)]))
        #expect(both.ok == false)
        #expect(both.error?.contains("exactly one") == true)
        #expect(both.error?.contains("ace-step") == true)
        #expect(both.error?.contains("rvc") == true)

        let neither = await router.handle(ControlRequest(
            id: "2", command: "ai.modelUnload"))
        #expect(neither.ok == false)
        #expect(neither.error?.contains("exactly one") == true)
        #expect(neither.error?.contains("rvc") == true)

        // ⭐ ANTI-VACUITY: neither malformed call signalled anything.
        #expect(await spy.callCount() == 0)
    }

    @Test("An unknown modelId teaches the valid ids and stops nothing")
    func unknownModelIdTeaches() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let spy = SpyEvictor(modelID: .aceStep)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: spy)
        let router = makeRouter(coordinator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.modelUnload", params: ["modelId": .string("flamingo")]))
        #expect(response.ok == false)
        #expect(response.error?.contains("flamingo") == true)
        #expect(response.error?.contains("ace-step") == true)
        #expect(await spy.callCount() == 0)
    }

    @Test("POSITIVE CONTROL — a stop that did not stop ERRORS, never reports success")
    func failedUnloadIsAnError() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let spy = SpyEvictor(modelID: .aceStep, stopsCleanly: false)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: spy)
        let router = makeRouter(coordinator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.modelUnload", params: ["modelId": .string("ace-step")]))
        // A verb that cannot produce this result is vacuous — and reporting
        // ok for a stop that did not stop is the m23-bb / m23-ah defect family.
        #expect(response.ok == false)
        #expect(response.error?.contains("Unload FAILED") == true)
        #expect(response.error?.contains("ace-step") == true)
        #expect(response.error?.contains("ai.modelResidency") == true)
        #expect(await spy.callCount() == 1, "it really did try")
    }

    // MARK: - The production job hooks (F8)
    //
    // ⚠️⚠️ **WITHOUT THESE TESTS THE HOOKS WERE STRUCTURALLY UNCOVERED.** Every
    // other `ai.generateSong` test in this target builds its router over the
    // process-wide `.shared` coordinator, which has no descriptors registered
    // and is therefore INERT — `noteJobStarted` is a no-op there. Measured: the
    // five `await noteACEJobStarted(...)` call sites could be deleted outright
    // and the entire Swift suite still passed. These two tests are the only
    // thing standing between "F8 is enforced" and "F8 is a comment".

    @Test("F8 chain. generateSong OPENS a job; a terminal generationStatus CLOSES it")
    func jobHooksOpenAndCloseAcrossTheWire() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let spy = SpyEvictor(modelID: .aceStep)
        // ⚠️ 600 s idle, i.e. the shipping ACE value. It must be LONG: this
        // coordinator sleeps for real (no injected clock on the timer), so a
        // short value would arm a wake-up that fires mid-test and calls the spy,
        // turning the `callCount() == 0` anti-vacuity check into a flake. At
        // 600 s the timer provably cannot fire inside a ~0.02 s test, so every
        // assertion below is about ARMING, never about firing — firing is
        // covered hermetically in `ModelLifecycleCoordinatorTests` via SleepGate.
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib, idleUnloadSeconds: 600),
            evictor: spy)
        try await makeResident(coordinator, .aceStep)
        // ⚠️ `Comment` takes a LITERAL — a `+` concatenation does not compile.
        #expect(await coordinator.pendingIdleUnloads()[.aceStep] != nil,
                """
                becoming resident arms the clock even with no job — a model that boots and is \
                never used is exactly the case the user was killing by hand
                """)

        let generator = FakeSongGenerator()
        await generator.setGenerateResult(.success(
            SongGenerationSubmission(jobID: "job-1", state: .queued, queuePosition: 1)))
        let router = makeRouter(coordinator, songGenerator: generator)

        #expect(await coordinator.openJobIDs(.aceStep).isEmpty, "nothing open before the submit")

        let submit = await router.handle(ControlRequest(
            id: "1", command: "ai.generateSong",
            params: ["prompt": .string("a slow synthwave ballad")]))
        #expect(submit.ok, "\(submit.error ?? "?")")
        #expect(await coordinator.openJobIDs(.aceStep) == ["job-1"],
                "the submit must protect the model by the SIDECAR's job id")

        // While a job is open the model is untouchable, which is the whole point.
        #expect(await coordinator.pendingIdleUnloads()[.aceStep] == nil,
                "the idle clock must NOT be running mid-render")

        // A non-terminal poll leaves it open.
        await generator.setStatusResult(.success(
            SongGenerationStatus(jobID: "job-1", state: .running)))
        let running = await router.handle(ControlRequest(
            id: "2", command: "ai.generationStatus", params: ["jobId": .string("job-1")]))
        #expect(running.ok, "\(running.error ?? "?")")
        #expect(await coordinator.openJobIDs(.aceStep) == ["job-1"], "`running` closes nothing")

        // The terminal poll closes it — and re-arms the idle clock.
        await generator.setStatusResult(.success(
            SongGenerationStatus(jobID: "job-1", state: .succeeded)))
        let done = await router.handle(ControlRequest(
            id: "3", command: "ai.generationStatus", params: ["jobId": .string("job-1")]))
        #expect(done.ok, "\(done.error ?? "?")")
        #expect(await coordinator.openJobIDs(.aceStep).isEmpty, "the terminal state closes the job")
        #expect(await coordinator.pendingIdleUnloads()[.aceStep] != nil,
                "closing the last job must ARM the idle unload — otherwise the model sits forever")

        // Idempotent: this verb is polled in a loop, and every poll after the
        // first sees the same terminal state.
        let again = await router.handle(ControlRequest(
            id: "4", command: "ai.generationStatus", params: ["jobId": .string("job-1")]))
        #expect(again.ok)
        #expect(await coordinator.openJobIDs(.aceStep).isEmpty)
        #expect(await spy.callCount() == 0, "nothing in this test may evict anything")
    }

    @Test("F8 regression. A TRANSIENT status error must NOT close a job that is still rendering")
    func transientStatusErrorKeepsTheJobOpen() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        await coordinator.register(
            descriptor("ace-step", port: 8001, hold: 74 * Self.gib), evictor: nil)
        try await makeResident(coordinator, .aceStep)

        let generator = FakeSongGenerator()
        await generator.setGenerateResult(.success(
            SongGenerationSubmission(jobID: "job-1", state: .queued, queuePosition: 1)))
        let router = makeRouter(coordinator, songGenerator: generator)
        _ = await router.handle(ControlRequest(
            id: "1", command: "ai.generateSong", params: ["prompt": .string("x")]))
        #expect(await coordinator.openJobIDs(.aceStep) == ["job-1"])

        // ⚠️⚠️ **THE BUG THIS PINS.** The error path used to close the job on ANY
        // thrown error, which INVERTED F8: the success path is careful (terminal
        // states only) while "I could not ask" — one dropped connection during a
        // multi-minute render — dropped activeJobs to 0 and let the next boot
        // SIGTERM ACE mid-generation. Exactly the failure F8 exists to prevent,
        // introduced by the hook written to enforce it.
        for transient in [
            ACEStepError.sidecarUnreachable("connection reset"),
            ACEStepError.requestFailed(status: 504, body: "gateway timeout"),
            ACEStepError.malformedResponse("truncated body"),
        ] {
            await generator.setStatusResult(.failure(transient))
            let response = await router.handle(ControlRequest(
                id: "p", command: "ai.generationStatus", params: ["jobId": .string("job-1")]))
            #expect(response.ok == false, "a transient failure is still an ERROR to the caller")
            #expect(await coordinator.openJobIDs(.aceStep) == ["job-1"],
                    "\(transient) must leave the render protected — the lease self-heals it")
        }

        // ⭐ ANTI-VACUITY, both directions. The loop above would pass just as well
        // against a build where NOTHING ever closes a job, so prove the errors
        // that DO mean "over" still close it.
        await generator.setStatusResult(.failure(
            ACEStepError.jobFailed(jobID: "job-1", message: "CUDA OOM")))
        let failed = await router.handle(ControlRequest(
            id: "f", command: "ai.generationStatus", params: ["jobId": .string("job-1")]))
        #expect(failed.ok == false)
        #expect(await coordinator.openJobIDs(.aceStep).isEmpty,
                "an upstream job FAILURE is terminal and must close the job")
    }

    @Test("F8 unit. errorProvesJobIsOver splits terminal from transient, and defaults to transient")
    func errorClassificationIsAsymmetric() {
        #expect(CommandRouter.errorProvesJobIsOver(
            ACEStepError.jobFailed(jobID: "j", message: "boom")))
        #expect(CommandRouter.errorProvesJobIsOver(ACEStepError.jobNotFound("j")))

        #expect(!CommandRouter.errorProvesJobIsOver(ACEStepError.sidecarUnreachable("reset")))
        #expect(!CommandRouter.errorProvesJobIsOver(
            ACEStepError.requestFailed(status: 504, body: "")))
        #expect(!CommandRouter.errorProvesJobIsOver(ACEStepError.malformedResponse("")))
        #expect(!CommandRouter.errorProvesJobIsOver(
            ACEStepError.modelSlotUnavailable(model: "m", detail: "")))

        // A foreign error (a different provider, a URLError) says nothing about
        // the job. The safe direction for an unknown error is KEEP PROTECTING.
        struct Foreign: Error {}
        #expect(!CommandRouter.errorProvesJobIsOver(Foreign()))
        #expect(!CommandRouter.errorProvesJobIsOver(URLError(.timedOut)))
    }

    @Test("ai.modelUnload rejects an unknown key")
    func unloadRejectsUnknownKeys() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let coordinator = makeCoordinator(storage: storage)
        let router = makeRouter(coordinator)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.modelUnload",
            params: ["modelId": .string("ace-step"), "force": .bool(true)]))
        #expect(response.ok == false)
        // ⚠️ `force` is an unknown key here BECAUSE the memory gate it would
        // have overridden does not exist. If a later cycle adds it, that is a
        // product decision the user has to make, not a schema oversight.
        #expect(response.error?.contains("force") == true)
    }
}
