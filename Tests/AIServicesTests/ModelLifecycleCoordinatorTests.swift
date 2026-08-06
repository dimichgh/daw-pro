import Darwin
import Foundation
import Testing

@testable import AIServices

// MARK: - Hermetic seams (§7.0)

/// The injected memory sample and clock (F2).
///
/// ⚠️ The memory half survives the 2026-08-05 scope cut even though **nothing
/// decides anything from it any more**: `ModelMemory` is now only the
/// corroboration behind `EvictionEvidence.memoryVerdict` (*did the unload really
/// give the memory back?*). Keeping it injected is still what stops this item
/// turning `SidecarManagerTests` into tests whose verdict depends on how much
/// Chrome the developer has open.
///
/// `@unchecked Sendable` with a lock rather than an actor because
/// `ModelLifecycleCoordinator`'s `sampleMemory`/`now` are **synchronous**
/// `@Sendable` closures — deliberately, since `ModelMemory.sample()` is one mach
/// trap and making it `async` would put an actor hop on the cheapest thing here.
final class MachineStub: @unchecked Sendable {
    private let lock = NSLock()
    private var availableBytes: UInt64
    private var instant: Date
    private let physicalBytes: UInt64

    init(availableGiB: UInt64, physicalGiB: UInt64 = 128, at instant: Date) {
        self.availableBytes = availableGiB << 30
        self.physicalBytes = physicalGiB << 30
        self.instant = instant
    }

    func setAvailable(giB: UInt64) {
        lock.lock(); defer { lock.unlock() }
        availableBytes = giB << 30
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        instant = instant.addingTimeInterval(seconds)
    }

    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return instant
    }

    var snapshot: ModelMemory.Snapshot {
        lock.lock(); defer { lock.unlock() }
        let used = physicalBytes - min(physicalBytes, availableBytes)
        return ModelMemory.Snapshot(
            pageSizeBytes: 16384, physicalBytes: physicalBytes, internalBytes: used,
            purgeableBytes: 0, wiredBytes: 0, compressorBytes: 0, freeBytes: availableBytes,
            speculativeBytes: 0, externalBytes: 0, sampledAt: instant)
    }
}

/// A spy evictor: records calls and **stops nothing**. Every eviction test uses
/// it, so no test in this file signals a real process or needs a sidecar.
actor SpyEvictor: ModelEvicting {
    nonisolated let modelID: ModelID
    private var calls = 0
    private var stopsCleanly: Bool
    private var throwsInstead: Bool

    init(modelID: ModelID, stopsCleanly: Bool = true, throwsInstead: Bool = false) {
        self.modelID = modelID
        self.stopsCleanly = stopsCleanly
        self.throwsInstead = throwsInstead
    }

    func callCount() -> Int { calls }

    func setStopsCleanly(_ value: Bool) { stopsCleanly = value }

    func evictWithoutCoordinator() async throws -> ModelStopEvidence {
        calls += 1
        if throwsInstead {
            throw SidecarError.stopFailed("the spy was told to fail")
        }
        return ModelStopEvidence(
            portFree: stopsCleanly,
            portLookupDetail: stopsCleanly ? nil : "port still held (spy)",
            probeUnreachable: stopsCleanly,
            treePidsAliveAfter: stopsCleanly ? [] : [4242],
            detail: stopsCleanly ? "spy stopped it" : "spy did not stop it")
    }
}

/// A test-controlled stand-in for the idle timer's ten-minute sleep.
///
/// ⚠️ The coordinator's `sleepSeconds` seam is `async throws` on purpose, and so
/// is this: a non-throwing stub that returned immediately would make every
/// "the wake-up was cancelled" assertion vacuous, because the wake-up would
/// already have run before the cancel arrived.
actor SleepGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var entries = 0

    init(openImmediately: Bool = false) { self.isOpen = openImmediately }

    /// How many times the coordinator entered the sleep — i.e. how many wake-ups
    /// actually started running.
    func entryCount() -> Int { entries }

    func wait() async {
        entries += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

// MARK: - The suite

@Suite("ModelLifecycleCoordinator (m23-dl)")
struct ModelLifecycleCoordinatorTests {

    static let gib: UInt64 = 1 << 30
    static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    /// ⚠️ Every coordinator here gets its OWN temporary storage directory.
    /// `ModelLifecycleCoordinator.shared` is NEVER touched: one reference would
    /// create real directories under the user's Application Support and make the
    /// suite order-dependent.
    static func tempDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m23dl-\(UUID().uuidString)", isDirectory: true)
        return url
    }

    static func model(
        _ id: String, holdGiB: UInt64, measured: Bool = true, evictable: Bool = true,
        port: Int = 8099, idleSeconds: Double? = nil
    ) -> ModelDescriptor {
        ModelDescriptor(
            id: ModelID(rawValue: id),
            displayName: "Model \(id)",
            baseURL: URL(string: "http://127.0.0.1:\(port)")!,
            seededHoldBytes: measured ? holdGiB << 30 : nil,
            seededHoldProvenance: measured ? "measured in a test" : nil,
            estimatedHoldBytes: holdGiB << 30,
            estimatedHoldProvenance: "estimated in a test, never measured resident",
            isEvictable: evictable,
            idleUnloadSeconds: idleSeconds)
    }

    static func coordinator(
        machine: MachineStub, storage: URL, settleSeconds: Double = 0,
        policy: ModelLifecyclePolicy = .init(),
        // ⚠️ NON-throwing, mirroring the coordinator's own signature. No stub here
        // ever threw, so nothing was lost. (This is NOT what fixed the
        // cancellation crash — see `ModelLifecycleCoordinator.cancelIdleUnload`.)
        sleepSeconds: (@Sendable (Double) async -> Void)? = nil
    ) -> ModelLifecycleCoordinator {
        if let sleepSeconds {
            return ModelLifecycleCoordinator(
                policy: policy,
                sampleMemory: { machine.snapshot },
                now: { machine.now },
                storageDirectory: storage,
                settleSeconds: settleSeconds,
                sleepSeconds: sleepSeconds)
        }
        return ModelLifecycleCoordinator(
            policy: policy,
            sampleMemory: { machine.snapshot },
            now: { machine.now },
            storageDirectory: storage,
            settleSeconds: settleSeconds)
    }

    /// Drives a model all the way to resident through the real path.
    @discardableResult
    static func makeResident(
        _ coordinator: ModelLifecycleCoordinator, _ id: ModelID
    ) async throws -> ModelLifecycleCoordinator.Ticket {
        let plan = await coordinator.resolveAdmission(id)
        #expect(plan.isAdmitted, "fixture setup expected an admit, got \(plan)")
        let ticket = try #require(
            try await coordinator.commitAdmission(plan, for: id),
            "fixture setup expected a ticket — is the model registered?")
        await coordinator.admitted(ticket, healthy: true)
        return ticket
    }

    /// Polls a condition to a deadline. The idle timer fires on its own `Task`,
    /// so a test cannot `await` it directly; this is the bounded alternative to
    /// an unbounded `while true`.
    ///
    /// ⚠️ **THE TIMEOUT IS A CONTENTION ALLOWANCE, NOT A WEAKENED ASSERTION.**
    /// It was 3.0 s, which is enormous in isolation — the idle-eviction test
    /// clears it in 0.007 s, a ~400x margin — and still timed out inside the full
    /// 5094-test parallel run, where hundreds of suites compete for the
    /// cooperative pool. MEASURED: passes 3/3 filtered, failed 1/1 in the full
    /// run at 3.0 s. Nothing about what is asserted changed; a wake-up that never
    /// fires still fails, it just no longer fails because the scheduler was busy.
    /// Raising this is the same call as `ModelMemoryLiveTests`' retry loop.
    static func eventually(
        _ description: String, timeout: Double = 30.0, _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        Issue.record("timed out waiting for: \(description)")
        return false
    }

    // MARK: - The F15 split — resolve is read-only, commit acts

    @Test("F15. resolveAdmission plans the unload-before-load and performs NOTHING")
    func resolveAdmissionIsReadOnly() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 100, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)

        let victimSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(Self.model("rvc", holdGiB: 20), evictor: victimSpy)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, port: 8001), evictor: SpyEvictor(modelID: .aceStep))
        try await Self.makeResident(coordinator, .rvc)

        let generationBefore = await coordinator.currentGeneration()
        let plan = await coordinator.resolveAdmission(.aceStep)
        #expect(plan.evicting == [.rvc], "the plan must NAME the unload-before-load")

        // ⭐ THE ASSERTION. If `resolveAdmission` and `commitAdmission` were one
        // `admit()` placed where a caller's `dryRun` branch can still return,
        // `dryRun: true` — a mode whose entire contract is "spawn nothing,
        // signal nothing" — would have SIGTERMed the user's live RVC sidecar
        // right here. ⚠️ MORE dangerous since the scope cut, not less: eviction
        // used to need memory to be short, and is now the normal plan.
        #expect(await victimSpy.callCount() == 0, "resolve must signal nothing")
        let report = await coordinator.residency()
        #expect(report.models.first { $0.modelID == .rvc }?.resident == true)
        #expect(await coordinator.currentInFlight() == nil, "resolve mints no ticket")
        #expect(await coordinator.currentGeneration() == generationBefore,
                "a read-only resolution is not a residency transition")

        // ANTI-VACUITY TWIN: the real path DOES evict, exactly once.
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        #expect(await victimSpy.callCount() == 1)
        let afterCommit = await coordinator.residency()
        #expect(afterCommit.models.first { $0.modelID == .rvc }?.resident == false)
        #expect(await coordinator.currentInFlight()?.value == ticket.value)
    }

    @Test("A read-only resolution writes NOTHING to disk")
    func resolveAdmissionTouchesNoFiles() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 100, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)

        _ = await coordinator.resolveAdmission(.aceStep)
        #expect(!FileManager.default.fileExists(atPath: storage.path),
                "resolve created \(storage.path) — it must not take the lock or write diagnostics")

        // Twin: committing DOES create the storage (lock + diagnostics), so the
        // assertion above is about resolve, not about a directory nothing ever
        // writes.
        let plan = await coordinator.resolveAdmission(.aceStep)
        _ = try await coordinator.commitAdmission(plan, for: .aceStep)
        #expect(FileManager.default.fileExists(
            atPath: storage.appendingPathComponent("flight.lock").path))
    }

    @Test("An UNREGISTERED coordinator is entirely inert — no ticket, no files")
    func unregisteredCoordinatorIsInert() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)

        // ⚠️ Admitted, NOT refused. Refusing an unregistered model would be a
        // gate, and the user cut every gate; it is also what keeps the shared
        // instance harmless for the many tests that never register anything.
        let plan = await coordinator.resolveAdmission(.aceStep)
        #expect(plan.isAdmitted)
        #expect(plan.evicting.isEmpty)
        let ticket = try await coordinator.commitAdmission(plan, for: .aceStep)
        #expect(ticket == nil, "nothing is minted for a model nobody registered")
        #expect(await coordinator.currentInFlight() == nil)
        #expect(!FileManager.default.fileExists(atPath: storage.path),
                "an inert coordinator must not create \(storage.path)")
        #expect(await coordinator.isRegistered(.aceStep) == false)
        #expect(await coordinator.dryRunDescription(plan, for: .aceStep, launch: "run.sh")
            == "[dry-run] would spawn: run.sh",
            "the pre-m23-dl dry-run string must survive byte-for-byte")
    }

    // MARK: - Unload-before-load is UNCONDITIONAL (the user's cleanup ask)

    @Test("Booting a model unloads the other one even with memory to spare")
    func unloadBeforeLoadIsUnconditional() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        // 127 of 128 GiB free: under the old design nothing would be evicted,
        // because everything fit. The user asked for the cleanup regardless —
        // "unload ACE … when we attempt to load other model".
        let machine = MachineStub(availableGiB: 127, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        let victimSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(Self.model("rvc", holdGiB: 3), evictor: victimSpy)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        try await Self.makeResident(coordinator, .rvc)

        let plan = await coordinator.resolveAdmission(.aceStep)
        #expect(plan.evicting == [.rvc])
        _ = try await coordinator.commitAdmission(plan, for: .aceStep)
        #expect(await victimSpy.callCount() == 1)
    }

    @Test("A model that FAILS to unload does not abort the boot — it stays observable")
    func failedEvictionDoesNotAbortTheBoot() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 100, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        let victimSpy = SpyEvictor(modelID: .rvc, stopsCleanly: false)
        await coordinator.register(Self.model("rvc", holdGiB: 20), evictor: victimSpy)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        try await Self.makeResident(coordinator, .rvc)

        let plan = await coordinator.resolveAdmission(.aceStep)
        #expect(plan.evicting == [.rvc])
        // ⚠️ This used to THROW: the plan promised bytes, the eviction refused,
        // and the arithmetic no longer worked. There is no arithmetic left, and
        // refusing here would be exactly the gate the user removed. The boot
        // proceeds — *"let it fail if this happens"*.
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        #expect(await coordinator.currentInFlight()?.value == ticket.value)
        // …and the failure stays OBSERVABLE rather than silent.
        let residency = await coordinator.residency()
        #expect(residency.models.first { $0.modelID == .rvc }?.resident == true,
                "a victim that refused to stop must keep reporting itself resident")
    }

    // MARK: - Ticket lifetime is not function scope (F14)

    @Test("F14. The ticket outlives commitAdmission and blocks every other boot")
    func ticketOutlivesTheCallThatMintedIt() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        await coordinator.register(Self.model("rvc", holdGiB: 3, port: 8002), evictor: nil)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))

        // 1-2. The ticket is STILL HELD after the call that minted it returned.
        //      This is the assertion a `defer { release(ticket) }` fails, and it
        //      is the whole point of the test: `start()` returns `.starting` at
        //      ~30 s while a cold load runs past 60 s.
        #expect(await coordinator.currentInFlight()?.value == ticket.value)

        // 3. A second boot of the SAME model, and of the OTHER model, both
        //    refuse and name the holder. ⚠️ This is the ONE thing that can still
        //    stop a boot, and it is not a memory check.
        for id in [ModelID.aceStep, .rvc] {
            let blocked = await coordinator.resolveAdmission(id)
            guard case .bootInFlight(let holder, let seconds) = blocked else {
                Issue.record("expected .bootInFlight for \(id), got \(blocked)")
                return
            }
            #expect(holder.ticket == ticket.value)
            #expect(seconds == 0)
            #expect(blocked.isAdmitted == false)
            await #expect(throws: SidecarError.self) {
                _ = try await coordinator.commitAdmission(blocked, for: id)
            }
        }

        // 4. Releasing it via the manager's clearing rule (a).
        let generationBefore = await coordinator.currentGeneration()
        await coordinator.admitted(ticket, healthy: true)
        #expect(await coordinator.currentInFlight() == nil)
        #expect(await coordinator.currentGeneration() > generationBefore)

        // 5. ANTI-VACUITY TWIN: the other model now proceeds. Without this,
        //    step 3 could pass because nothing ever admits.
        #expect(await coordinator.resolveAdmission(.rvc).isAdmitted)
    }

    /// ⚠️ Retargeted from a since-deleted `abandon(_:)`. That method was a second
    /// entry point for the same release and NOTHING IN PRODUCTION CALLED IT —
    /// this test was its only caller, so it read as covered while the path the
    /// managers actually take was the one under test everywhere else. The path
    /// exercised below is the real one: `SidecarManager`/`VoiceConversionManager`
    /// both fail through `releaseFlightTicket(healthy: false)`.
    @Test("F14b. admitted(healthy: false) gives the slot back — the boot-failed-after-mint path")
    func abandonReleasesTheSlot() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        await coordinator.register(Self.model("rvc", holdGiB: 3, port: 8002), evictor: nil)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        // `process.run()` threw, or the child exited during the boot poll —
        // exactly what both managers' `catch` blocks do.
        await coordinator.admitted(ticket, healthy: false)

        // A leaked ticket refuses every later boot for `staleTicketSeconds`, and
        // the app-side auto-start callers swallow that with `try?`.
        #expect(await coordinator.currentInFlight() == nil)
        #expect(await coordinator.resolveAdmission(.rvc).isAdmitted)
        // The model never became resident — nothing booted.
        #expect(await coordinator.residency().models
            .first { $0.modelID == .aceStep }?.resident == false)
    }

    @Test("A stale ticket whose pid is DEAD is reclaimed")
    func staleTicketWithADeadPidIsReclaimed() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)
        await coordinator.register(Self.model("rvc", holdGiB: 3, port: 8002), evictor: nil)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        // macOS PID_MAX is 99999, so this pid provably does not exist.
        await coordinator.recordBootPid(ticket, pid: 999_999)
        #expect(kill(999_999, 0) != 0, "the fixture pid must genuinely not exist")

        // Not yet stale.
        machine.advance(60)
        #expect(await coordinator.currentInFlight() != nil)

        // Past the window, pid dead ⇒ reclaimed.
        machine.advance(120)
        #expect(await coordinator.currentInFlight() == nil)
        #expect(await coordinator.resolveAdmission(.rvc).isAdmitted)
    }

    @Test("A stale ticket whose pid is ALIVE is NEVER reclaimed")
    func staleTicketWithALivePidIsNotReclaimed() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)
        await coordinator.register(Self.model("rvc", holdGiB: 3, port: 8002), evictor: nil)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        // Our own pid is unambiguously alive.
        await coordinator.recordBootPid(ticket, pid: getpid())

        machine.advance(10_000)
        // ⚠️ This is the `kill -0`-on-a-zombie trap in a different costume: a
        // cold model load legitimately outruns any timeout we would pick, and
        // reclaiming its ticket readmits a second boot on top of a live one.
        #expect(await coordinator.currentInFlight()?.value == ticket.value,
                "a ticket whose pid is alive must never be reclaimed on a timer")
        #expect(await coordinator.resolveAdmission(.rvc).isAdmitted == false)
    }

    // MARK: - The learned corroboration figure

    @Test("A boot with nothing else resident records the learned footprint")
    func ordinaryAdmissionRecordsTheObservation() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        #expect(ticket.availableAtAdmission == 110 * Self.gib)
        machine.setAvailable(giB: 70)
        await coordinator.admitted(ticket, healthy: true)
        #expect(await coordinator.observation(for: .aceStep)?.holdBytes == 40 * Self.gib)

        // And the residency record carries the LEARNED figure, not the seed.
        let row = try #require(
            await coordinator.residency().models.first { $0.modelID == .aceStep })
        #expect(row.holdBytes == 40 * Self.gib)
        #expect(row.holdConfidence == .measured)
        #expect(row.holdProvenance.contains("measured on this machine"))
    }

    @Test("A boot that EVICTED something records nothing — the delta is not ours")
    func evictingBootRecordsNoObservation() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(
            Self.model("rvc", holdGiB: 20), evictor: SpyEvictor(modelID: .rvc))
        await coordinator.register(Self.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        try await Self.makeResident(coordinator, .rvc)

        let plan = await coordinator.resolveAdmission(.aceStep)
        #expect(plan.evicting == [.rvc])
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        machine.setAvailable(giB: 70)
        await coordinator.admitted(ticket, healthy: true)

        // ⚠️ Since unload-before-load became unconditional this is the COMMON
        // case, not an edge one: the delta nets RVC's release against ACE's load,
        // so it is not a measurement of either. The residency-epoch guard is what
        // discards it, and this is the test that says so out loud.
        #expect(await coordinator.observation(for: .aceStep) == nil,
                "an observation taken across another model's eviction is not attributable")
    }

    @Test("A delta below the 1 GiB noise floor is DISCARDED")
    func tinyDeltaIsNotAnObservation() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        // The load "finished" having moved nothing — plainly not what we think.
        await coordinator.admitted(ticket, healthy: true)
        #expect(await coordinator.observation(for: .aceStep) == nil)
    }

    @Test("An unhealthy boot records nothing and leaves the model non-resident")
    func failedBootRecordsNothing() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)

        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        machine.setAvailable(giB: 70)
        // Clearing rule (b): the tracked process was found dead.
        await coordinator.admitted(ticket, healthy: false)

        #expect(await coordinator.observation(for: .aceStep) == nil)
        #expect(await coordinator.currentInFlight() == nil, "the ticket is released either way")
        let report = await coordinator.residency()
        #expect(report.models.first { $0.modelID == .aceStep }?.resident == false)
    }

    @Test("Observations survive a relaunch")
    func observationsPersist() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let first = Self.coordinator(machine: machine, storage: storage)
        await first.register(Self.model("ace-step", holdGiB: 34), evictor: nil)
        let plan = await first.resolveAdmission(.aceStep)
        let ticket = try #require(try await first.commitAdmission(plan, for: .aceStep))
        machine.setAvailable(giB: 70)
        await first.admitted(ticket, healthy: true)

        let second = Self.coordinator(machine: machine, storage: storage)
        await second.register(Self.model("ace-step", holdGiB: 34), evictor: nil)
        #expect(await second.observation(for: .aceStep)?.holdBytes == 40 * Self.gib)
    }

    // MARK: - Idle unload: SHIPPED ON (user decision 2026-08-05)

    @Test("The SHIPPED values: ACE idle-unloads at 600 s, RVC never")
    func shippedIdleValues() {
        let ace = ModelRegistry.aceStep(baseURL: URL(string: "http://127.0.0.1:8001")!)
        let rvc = ModelRegistry.rvc(baseURL: URL(string: "http://127.0.0.1:8002")!)
        // ⭐ The mechanism tests below prove the timer WORKS. Only this pin proves
        // it is switched ON in the product — the two are different claims, and a
        // suite that only had the first would stay green with the feature off.
        #expect(ace.idleUnloadSeconds == 600)
        #expect(ModelRegistry.aceStepIdleUnloadSeconds == 600)
        // ⚠️ `nil`, not `.greatestFiniteMagnitude` and not a very large interval.
        // A dormant timer is still a scheduled wake-up, still a cancellation path
        // that can leak, and still a code path that can fire after the actor's
        // state has moved on (F23's surviving content).
        #expect(rvc.idleUnloadSeconds == nil)
    }

    @Test("A configured idle unload schedules EXACTLY ONE wake-up and DOES evict")
    func idleUnloadFiresAndEvicts() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        // ⚠️ Held CLOSED until the scenario is set up. With an
        // open-immediately gate the first arming races the job hooks and the
        // wake-up count is 1 or 2 depending on scheduling — a test that is
        // green-or-red by timing, which is worse than no test.
        let gate = SleepGate()
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            sleepSeconds: { _ in await gate.wait() })
        let spy = SpyEvictor(modelID: .aceStep)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, idleSeconds: 600), evictor: spy)
        try await Self.makeResident(coordinator, .aceStep)
        await coordinator.noteJobStarted(.aceStep, jobID: "job-1")
        machine.advance(45)
        await coordinator.noteJobEnded(.aceStep, jobID: "job-1")

        // ⚠️ "exactly one wake-up" is ambiguous between cumulative and pending,
        // and cancel-and-reschedule moves the two differently — so both are
        // asserted. Two ARMINGS happened (becoming resident, then the job
        // ending), the first was cancelled by the job, and exactly ONE is armed.
        #expect(await coordinator.idleWakeUpsEverScheduled() == 2)
        #expect(await coordinator.pendingIdleUnloads()
            == [.aceStep: Self.epoch.addingTimeInterval(45 + 600)])

        await gate.open()
        #expect(await Self.eventually("the idle timer evicts") {
            await spy.callCount() == 1
        })
        // Ten idle minutes after the generation reached a terminal state, the
        // ~80 GB goes back — the thing the user was doing by hand with `kill`.
        #expect(await coordinator.pendingIdleUnloads().isEmpty, "nothing is left armed")
        #expect(await coordinator.residency().models
            .first { $0.modelID == .aceStep }?.resident == false)
        // The stale first arming resumed too and DECLINED — exactly one eviction,
        // not two.
        #expect(await gate.entryCount() == 2)
        #expect(await spy.callCount() == 1)
    }

    @Test("ANTI-VACUITY TWIN — a nil idle configuration schedules ZERO wake-ups")
    func idleOffSchedulesNothing() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let gate = SleepGate(openImmediately: true)
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            sleepSeconds: { _ in await gate.wait() })
        let spy = SpyEvictor(modelID: .rvc)
        // The SHIPPED `nil` polarity — this is RVC's real configuration.
        await coordinator.register(Self.model("rvc", holdGiB: 3, idleSeconds: nil), evictor: spy)
        try await Self.makeResident(coordinator, .rvc)
        await coordinator.noteJobStarted(.rvc, jobID: "job-1")
        await coordinator.noteJobEnded(.rvc, jobID: "job-1")

        // Advance a hundred years and give any scheduled task every chance.
        machine.advance(60 * 60 * 24 * 365 * 100)
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 2_000_000) }

        #expect(await coordinator.idleWakeUpsEverScheduled() == 0, "off means NOTHING is scheduled")
        #expect(await gate.entryCount() == 0, "off means no sleep is ever entered")
        #expect(await coordinator.pendingIdleUnloads().isEmpty)
        #expect(await spy.callCount() == 0)
        let row = try #require(await coordinator.residency().models.first { $0.modelID == .rvc })
        #expect(row.resident == true)
        #expect(row.idleUnloadSeconds == nil)
        #expect(row.idleUnloadAt == nil)
    }

    @Test("Idle arms on BECOMING RESIDENT, not only behind a job hook")
    func idleArmsWithoutAnyJob() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let gate = SleepGate()   // held closed: we assert on the ARMING, not the fire
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            sleepSeconds: { _ in await gate.wait() })
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, idleSeconds: 600),
            evictor: SpyEvictor(modelID: .aceStep))
        try await Self.makeResident(coordinator, .aceStep)

        // ⚠️ A model that boots and is never used is exactly what the user was
        // killing by hand, and a timer that only ever arms behind a job hook is
        // one missed hook away from never arming at all.
        #expect(await coordinator.idleWakeUpsEverScheduled() == 1)
        let pending = await coordinator.pendingIdleUnloads()
        #expect(pending[.aceStep] == Self.epoch.addingTimeInterval(600))
        let row = try #require(
            await coordinator.residency().models.first { $0.modelID == .aceStep })
        #expect(row.idleUnloadAt == Self.epoch.addingTimeInterval(600),
                "an armed timer must be observable, not inferred")
        await gate.open()
    }

    // ⚠️ "DISARMS", not "cancels": the wake-up is revoked by dropping its epoch,
    // and the orphaned task is deliberately NOT `.cancel()`ed — cancelling one
    // suspended in the real `Task.sleep` aborts the process. See
    // `ModelLifecycleCoordinator.cancelIdleUnload`. What this test pins is the
    // OBSERVABLE contract (deadlines, epochs, wake-up counts), which is exactly
    // why it kept passing while that fault went unnoticed.
    @Test("F8. An open job DISARMS the armed wake-up, and closing it re-arms ONE")
    func activeJobCancelsTheIdleWakeUp() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let gate = SleepGate()
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            sleepSeconds: { _ in await gate.wait() })
        let spy = SpyEvictor(modelID: .aceStep)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, idleSeconds: 600), evictor: spy)
        try await Self.makeResident(coordinator, .aceStep)
        #expect(await coordinator.pendingIdleUnloads().count == 1)

        // A generation starts while the wake-up is armed and suspended.
        await coordinator.noteJobStarted(.aceStep, jobID: "job-1")
        #expect(await coordinator.pendingIdleUnloads().isEmpty,
                "an armed timer must not survive the start of a job")

        // ⭐ Release the suspended wake-up. Its epoch is stale and the model is
        // busy, so it must decline. An idle timer that fired during a long
        // generation would be far worse than the leaked memory it replaces.
        await gate.open()
        for _ in 0..<5 { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(await spy.callCount() == 0, "F8: activeJobs > 0 is an ABSOLUTE veto")
        #expect(await coordinator.residency().models
            .first { $0.modelID == .aceStep }?.resident == true)

        // ANTI-VACUITY TWIN: once the job ends, exactly ONE wake-up re-arms and
        // this time it evicts.
        await coordinator.noteJobEnded(.aceStep, jobID: "job-1")
        #expect(await Self.eventually("the re-armed timer evicts") {
            await spy.callCount() == 1
        })
    }

    @Test("F8b. idleEvictionIsSafe pins the post-wake re-check in both polarities")
    func idleEvictionSafetyIsPure() {
        // The route a live test cannot reach: opening a job cancels the pending
        // wake-up, so this belt-and-braces re-check would otherwise be asserted
        // by nothing at all.
        #expect(ModelLifecycleCoordinator.idleEvictionIsSafe(
            activeJobs: 0, bootInFlightForThisModel: false))
        #expect(ModelLifecycleCoordinator.idleEvictionIsSafe(
            activeJobs: 1, bootInFlightForThisModel: false) == false)
        #expect(ModelLifecycleCoordinator.idleEvictionIsSafe(
            activeJobs: 0, bootInFlightForThisModel: true) == false)
        // Already unloaded by somebody else.
        #expect(ModelLifecycleCoordinator.idleEvictionIsSafe(
            activeJobs: nil, bootInFlightForThisModel: false) == false)
    }

    @Test("Two consecutive job-ends leave exactly ONE pending wake-up, not two")
    func rearmingReplacesRatherThanAccumulates() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let gate = SleepGate()
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            sleepSeconds: { _ in await gate.wait() })
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, idleSeconds: 600),
            evictor: SpyEvictor(modelID: .aceStep))
        try await Self.makeResident(coordinator, .aceStep)

        for index in 0..<3 {
            await coordinator.noteJobStarted(.aceStep, jobID: "job-\(index)")
            machine.advance(30)
            await coordinator.noteJobEnded(.aceStep, jobID: "job-\(index)")
        }
        #expect(await coordinator.pendingIdleUnloads().count == 1)
        // The deadline moved with the last job — the clock RESTARTS, it does not
        // keep the first arming's deadline.
        #expect(await coordinator.pendingIdleUnloads()[.aceStep]
            == Self.epoch.addingTimeInterval(90 + 600))
        #expect(await coordinator.idleWakeUpsEverScheduled() == 4,
                "one arming on becoming resident plus one per job-end")
        await gate.open()
    }

    // MARK: - Jobs are keyed, not counted

    @Test("Job bookkeeping is idempotent: repeated polls cannot un-protect a model")
    func jobBookkeepingIsIdempotent() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34), evictor: SpyEvictor(modelID: .aceStep))
        try await Self.makeResident(coordinator, .aceStep)

        await coordinator.noteJobStarted(.aceStep, jobID: "job-1")
        await coordinator.noteJobStarted(.aceStep, jobID: "job-2")
        await coordinator.noteJobStarted(.aceStep, jobID: "job-1")   // duplicate submit
        #expect(await coordinator.openJobIDs(.aceStep) == ["job-1", "job-2"])

        // ⚠️ THE CASE A COUNTER GETS WRONG. `ai.generationStatus` is polled in a
        // loop and every poll after the first sees the same terminal state; a
        // decrementing counter would run to zero (and below) and un-protect a
        // model that is still rendering job-2.
        for _ in 0..<5 { await coordinator.noteJobEnded(.aceStep, jobID: "job-1") }
        #expect(await coordinator.openJobIDs(.aceStep) == ["job-2"])
        let row = try #require(
            await coordinator.residency().models.first { $0.modelID == .aceStep })
        #expect(row.activeJobs == 1)
    }

    @Test("A job nobody ever closed stops vetoing after the lease")
    func jobLeaseSelfHeals() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            policy: ModelLifecyclePolicy(jobLeaseSeconds: 3600))
        await coordinator.register(
            Self.model("rvc", holdGiB: 3), evictor: SpyEvictor(modelID: .rvc))
        await coordinator.register(Self.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        try await Self.makeResident(coordinator, .rvc)
        await coordinator.noteJobStarted(.rvc, jobID: "abandoned")

        // Inside the lease: protected, so a boot of ACE leaves RVC alone.
        var plan = await coordinator.resolveAdmission(.aceStep)
        #expect(plan.evicting.isEmpty)
        #expect(plan.protectedByJobs == [.rvc])

        // ⭐ Past it: a caller that submitted and never polled must not pin its
        // model resident forever — that would silently stop ALL the cleanup this
        // item exists for.
        machine.advance(3601)
        plan = await coordinator.resolveAdmission(.aceStep)
        #expect(plan.evicting == [.rvc])
        #expect(plan.protectedByJobs.isEmpty)
    }

    // MARK: - F8 through the eviction path

    @Test("F8. A model with an active job is not unloaded to make room for another")
    func activeJobBlocksEvictionThroughTheCoordinator() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 100, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        let victimSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(Self.model("rvc", holdGiB: 20), evictor: victimSpy)
        await coordinator.register(Self.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        try await Self.makeResident(coordinator, .rvc)
        await coordinator.noteJobStarted(.rvc, jobID: "job-1")

        let plan = await coordinator.resolveAdmission(.aceStep)
        // ⚠️ The boot is ADMITTED and the busy model is left alone. Under the old
        // design this was a refusal; now the boot proceeds into whatever memory
        // is left — the user's *"let it fail"* — because the alternative is
        // unloading a model in the middle of their render.
        #expect(plan.isAdmitted)
        #expect(plan.evicting.isEmpty)
        #expect(plan.protectedByJobs == [.rvc])
        _ = try await coordinator.commitAdmission(plan, for: .aceStep)
        #expect(await victimSpy.callCount() == 0)

        // …and the message says so, rather than silently skipping the cleanup.
        let message = await coordinator.describe(plan, for: .aceStep)
        #expect(message.contains("busy with 1 job"))

        // Twin: once the job ends, the same request unloads it.
        await coordinator.admitted(
            try #require(await coordinator.currentInFlight()), healthy: false)
        await coordinator.noteJobEnded(.rvc, jobID: "job-1")
        #expect(await coordinator.resolveAdmission(.aceStep).evicting == [.rvc])
    }

    // MARK: - Eviction reporting, including the case that must FAIL

    @Test("A clean unload drops residency, bumps the generation and reports evidence")
    func cleanUnloadIsObservable() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        let spy = SpyEvictor(modelID: .aceStep)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: spy)
        try await Self.makeResident(coordinator, .aceStep)

        machine.setAvailable(giB: 70)     // the load took 40 GiB
        machine.setAvailable(giB: 110)    // …and the unload gave it back
        let report = await coordinator.unload(.aceStep)

        #expect(report.stopped)
        #expect(report.evidence.portFree)
        #expect(report.evidence.probeUnreachable)
        #expect(report.evidence.treePidsAliveAfter.isEmpty)
        #expect(report.evidence.generationAfter > report.evidence.generationBefore,
                "an eviction that did not bump the nonce did not happen")
        let residency = await coordinator.residency()
        #expect(residency.models.first { $0.modelID == .aceStep }?.resident == false)
    }

    @Test("POSITIVE CONTROL — a stop that did not stop is reported as a FAILURE")
    func failedUnloadIsNotReportedAsSuccess() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        let spy = SpyEvictor(modelID: .aceStep, stopsCleanly: false)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: spy)
        try await Self.makeResident(coordinator, .aceStep)

        let report = await coordinator.unload(.aceStep)
        // ⭐ A verification that cannot produce this result is vacuous.
        #expect(report.stopped == false)
        #expect(report.evidence.portFree == false)
        #expect(report.evidence.treePidsAliveAfter == [4242])
        // And the model is STILL resident: a refusal mutates nothing.
        let residency = await coordinator.residency()
        #expect(residency.models.first { $0.modelID == .aceStep }?.resident == true)
    }

    @Test("A stop that THROWS is a failed stop, with every authority limb false")
    func thrownStopIsAFailure() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        let spy = SpyEvictor(modelID: .aceStep, throwsInstead: true)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: spy)
        try await Self.makeResident(coordinator, .aceStep)

        let report = await coordinator.unload(.aceStep)
        #expect(report.stopped == false)
        #expect(report.detail.contains("the spy was told to fail"))
        #expect(await coordinator.residency().models
            .first { $0.modelID == .aceStep }?.resident == true)
    }

    @Test("Unloading an unregistered model is a teaching error naming the valid ids")
    func unknownModelUnloadTeaches() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)
        await coordinator.register(Self.model("rvc", holdGiB: 3, port: 8002), evictor: nil)

        let report = await coordinator.unload(ModelID(rawValue: "flamingo"))
        #expect(report.stopped == false)
        #expect(report.detail.contains("ace-step"))
        #expect(report.detail.contains("rvc"))

        let message = ModelAdmission.unknownModelMessage(
            "flamingo", valid: await coordinator.registeredModelIDs(), generation: 7)
        #expect(message.contains("ace-step and rvc"))
        #expect(message.contains("generation 7"))
        // ⚠️ The BOOT path does not teach — it admits. Refusing an unregistered
        // model would be a gate, and there are no gates left.
        #expect(await coordinator.resolveAdmission(ModelID(rawValue: "flamingo")).isAdmitted)
    }

    // MARK: - Quit and external stops

    @Test("shutdown() unloads every registered model and disarms every timer")
    func shutdownUnloadsEverything() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let gate = SleepGate()
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            sleepSeconds: { _ in await gate.wait() })
        let aceSpy = SpyEvictor(modelID: .aceStep)
        let rvcSpy = SpyEvictor(modelID: .rvc)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, port: 8001, idleSeconds: 600), evictor: aceSpy)
        await coordinator.register(Self.model("rvc", holdGiB: 3, port: 8002), evictor: rvcSpy)
        try await Self.makeResident(coordinator, .aceStep)
        #expect(await coordinator.pendingIdleUnloads().count == 1)

        let reports = await coordinator.shutdown()

        // ⚠️ BOTH models are stopped, including the one this coordinator never
        // booted: a sidecar the user started by hand is exactly the ~80 GB they
        // were reclaiming with `kill`.
        #expect(reports.count == 2)
        #expect(reports.allSatisfy { $0.reason == .shutdown })
        #expect(await aceSpy.callCount() == 1)
        #expect(await rvcSpy.callCount() == 1)
        #expect(await coordinator.pendingIdleUnloads().isEmpty)
        await gate.open()
    }

    @Test("noteStoppedExternally reconciles the bookkeeping after ai.sidecarStop")
    func externalStopReconciles() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let gate = SleepGate()
        let coordinator = Self.coordinator(
            machine: machine, storage: storage,
            sleepSeconds: { _ in await gate.wait() })
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34, idleSeconds: 600),
            evictor: SpyEvictor(modelID: .aceStep))
        try await Self.makeResident(coordinator, .aceStep)
        let generationBefore = await coordinator.currentGeneration()

        await coordinator.noteStoppedExternally(.aceStep)

        #expect(await coordinator.residency().models
            .first { $0.modelID == .aceStep }?.resident == false)
        #expect(await coordinator.pendingIdleUnloads().isEmpty,
                "a model that is gone must not keep an armed timer")
        #expect(await coordinator.currentGeneration() > generationBefore)
        await gate.open()
    }

    // MARK: - Cross-process single flight (§4.2)

    @Test("Two coordinators sharing a storage root serialise on the flock")
    func crossProcessLockRefusesASecondBoot() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        // Two separate coordinators standing in for two processes: `flock` is
        // held per OPEN FILE DESCRIPTION, so two independent `open()`s conflict
        // whether or not they are in the same process.
        let appSide = Self.coordinator(machine: machine, storage: storage)
        let stagingSide = Self.coordinator(machine: machine, storage: storage)
        for coordinator in [appSide, stagingSide] {
            await coordinator.register(Self.model("ace-step", holdGiB: 34), evictor: nil)
            await coordinator.register(Self.model("rvc", holdGiB: 3, port: 8002), evictor: nil)
        }

        let first = await appSide.resolveAdmission(.aceStep)
        let ticket = try #require(try await appSide.commitAdmission(first, for: .aceStep))

        // The second coordinator's OWN in-flight state is empty, so only the
        // file lock can stop it — which is the whole point of having one.
        #expect(await stagingSide.currentInFlight() == nil)
        let second = await stagingSide.resolveAdmission(.rvc)
        #expect(second.isAdmitted, "in-process state alone would let this through")
        await #expect(throws: SidecarError.self) {
            _ = try await stagingSide.commitAdmission(second, for: .rvc)
        }

        // ANTI-VACUITY TWIN: once the first releases, the second proceeds.
        await appSide.admitted(ticket, healthy: true)
        let retry = await stagingSide.resolveAdmission(.rvc)
        _ = try await stagingSide.commitAdmission(retry, for: .rvc)
    }

    // MARK: - Pure helpers

    @Test("memoryVerdict classifies all four cases")
    func memoryVerdictClassification() {
        let gib = Int64(Self.gib)
        // Expected hold unknown ⇒ nothing to compare against.
        #expect(ModelLifecycleCoordinator.memoryVerdict(
            returnedBytes: 40 * gib, expectedHoldBytes: nil) == .inconclusive)
        // A model that was never really a hold — the file-backed shape, where
        // `phys_footprint` measured 0.00 GB for a 4 GiB mapping.
        #expect(ModelLifecycleCoordinator.memoryVerdict(
            returnedBytes: 0, expectedHoldBytes: 500_000_000) == .notAHold)
        // Below the 1 GiB noise floor, including negative (another process grew).
        #expect(ModelLifecycleCoordinator.memoryVerdict(
            returnedBytes: 500_000_000, expectedHoldBytes: 40 * Self.gib) == .inconclusive)
        #expect(ModelLifecycleCoordinator.memoryVerdict(
            returnedBytes: -2 * gib, expectedHoldBytes: 40 * Self.gib) == .inconclusive)
        // More than the floor but under half.
        #expect(ModelLifecycleCoordinator.memoryVerdict(
            returnedBytes: 10 * gib, expectedHoldBytes: 40 * Self.gib) == .partial)
        // At or above half.
        #expect(ModelLifecycleCoordinator.memoryVerdict(
            returnedBytes: 20 * gib, expectedHoldBytes: 40 * Self.gib) == .returned)
        #expect(ModelLifecycleCoordinator.memoryVerdict(
            returnedBytes: 40 * gib, expectedHoldBytes: 40 * Self.gib) == .returned)
    }

    @Test("capturedTreePids reuses the pre-kill capture and excludes RECYCLED pids")
    func capturedTreePidsExcludesRecycled() {
        #expect(ModelStopEvidence.capturedTreePids(nil).isEmpty)

        let outcome = SidecarStop.TerminationOutcome(
            targetPid: 100, forcedTarget: false, targetSurvived: false, targetRecycled: false,
            descendantsStopped: [101], descendantsSurvived: [102], descendantsRecycled: [103])
        // Stopped AND survived are both consulted — including the ones we
        // believe are dead is what lets this catch a stop that lied.
        #expect(ModelStopEvidence.capturedTreePids(outcome) == [100, 101, 102])

        // A recycled pid now belongs to somebody else; SidecarStop deliberately
        // refused to signal it, and counting it alive would report a failed
        // unload because an unrelated process inherited a number.
        let recycledTarget = SidecarStop.TerminationOutcome(
            targetPid: 100, targetRecycled: true, descendantsStopped: [101])
        #expect(ModelStopEvidence.capturedTreePids(recycledTarget) == [101])
    }

    @Test("gather() treats an UNAVAILABLE port lookup as not-free, never as success")
    func portLookupUnavailableIsNotSuccess() {
        // A URL with no derivable port exercises the same "could not ask" branch
        // without depending on whether `lsof` exists on the test machine.
        let evidence = ModelStopEvidence.gather(
            baseURL: URL(string: "mailto:nobody@example.com")!, probeAnswering: false,
            capturedTreePids: [], detail: "stopped")
        #expect(evidence.portFree == false, "\"I could not ask\" is not \"I found nothing\"")
        #expect(evidence.portLookupDetail?.isEmpty == false)
        #expect(evidence.stopped == false)
    }

    // MARK: - The residency read

    @Test("residency() answers nextBootWouldUnload from the SAME planner the boot path uses")
    func residencyUsesTheSamePlanner() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        let ace = ModelRegistry.aceStep(baseURL: URL(string: "http://127.0.0.1:8001")!)
        await coordinator.register(ace, evictor: nil)
        await coordinator.register(
            Self.model("rvc", holdGiB: 3, port: 8002), evictor: SpyEvictor(modelID: .rvc))

        let empty = await coordinator.residency()
        let aceRow = try #require(empty.models.first { $0.modelID == .aceStep })
        #expect(aceRow.port == 8001)
        #expect(aceRow.resident == false)
        #expect(aceRow.holdConfidence == .measured)
        #expect(aceRow.nextBootWouldUnload.isEmpty)
        #expect(empty.memory.availableBytes == 110 * Self.gib)
        #expect(empty.policy.staleTicketSeconds == 120)
        // No process detail was asked for, so no `ps`/`lsof` fork happened.
        #expect(aceRow.pids == nil)
        #expect(aceRow.portBusy == nil)

        // With RVC resident, the SAME planner drives both the panel and the boot.
        try await Self.makeResident(coordinator, .rvc)
        let loaded = await coordinator.residency()
        let aceRow2 = try #require(loaded.models.first { $0.modelID == .aceStep })
        #expect(aceRow2.nextBootWouldUnload == [.rvc])
        #expect(aceRow2.nextBootPlan.contains("Unloading"))
        #expect(await coordinator.resolveAdmission(.aceStep).evicting
            == aceRow2.nextBootWouldUnload)
    }

    @Test("The generation nonce is monotonic across every residency transition")
    func generationIsMonotonic() async throws {
        let storage = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 110, at: Self.epoch)
        let coordinator = Self.coordinator(machine: machine, storage: storage)
        await coordinator.register(
            Self.model("ace-step", holdGiB: 34), evictor: SpyEvictor(modelID: .aceStep))

        var seen: [UInt64] = [await coordinator.currentGeneration()]
        let plan = await coordinator.resolveAdmission(.aceStep)
        let ticket = try #require(try await coordinator.commitAdmission(plan, for: .aceStep))
        seen.append(await coordinator.currentGeneration())
        await coordinator.admitted(ticket, healthy: true)
        seen.append(await coordinator.currentGeneration())
        await coordinator.noteJobStarted(.aceStep, jobID: "job-1")
        seen.append(await coordinator.currentGeneration())
        await coordinator.noteJobEnded(.aceStep, jobID: "job-1")
        seen.append(await coordinator.currentGeneration())
        _ = await coordinator.unload(.aceStep)
        seen.append(await coordinator.currentGeneration())

        #expect(seen == seen.sorted(), "the nonce must never go backwards")
        #expect(Set(seen).count == seen.count, "every transition must be observable")
    }
}
