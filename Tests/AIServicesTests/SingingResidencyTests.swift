import Foundation
import Testing
@testable import AIServices

/// Architect FIX-NOW #2 proof (item p2-sing-c, `$S/w7/SC/ARCH-REVIEW.md` §3): `residentFacts`
/// (`ModelLifecycleCoordinator.swift:572-583`) must carry `record.descriptor.yieldsWhenBusy`
/// through to the planner's input, or a busy SoulX resolves through the REAL coordinator exactly
/// like RVC in `ModelLifecycleCoordinatorTests.activeJobBlocksEvictionThroughTheCoordinator` —
/// `protectedByJobs`, never evicted — even though `ModelAdmission.resolve` itself (the pure
/// planner, covered by `ModelAdmissionTests.busySoulXYields`) has always handled a
/// correctly-populated `Resident.yieldsWhenBusy` right. This is the ONE place that populates it
/// from the registered descriptor; a test of the pure planner alone cannot catch a coordinator
/// that never wires the flag through in the first place.
///
/// Lives in its OWN file, not `ModelLifecycleCoordinatorTests.swift` -- that file is
/// `ModelLifecycleCoordinatorTests.swift` is the lane that owns `ModelLifecycleCoordinator.swift`
/// (W7-S0); the orchestrator's grant for item p2-sing-c covers exactly ONE source line there, not
/// an edit to that lane's test file. `ModelLifecycleCoordinatorTests`'s helpers
/// (`tempDirectory`, `model`, `coordinator`, `makeResident`, `epoch`) and the top-level
/// `MachineStub`/`SpyEvictor` types are all `internal` (no `private`/`fileprivate` anywhere in
/// that file, confirmed by reading it), so this file reuses them across the module rather than
/// duplicating ~40 lines of fixture code.
@Suite("ModelLifecycleCoordinator residency — architect FIX-NOW #2 (item p2-sing-c)")
struct SingingResidencyTests {
    @Test("FIX-NOW #2. A busy yieldsWhenBusy resident (SoulX) is evicted through the REAL coordinator, never protectedByJobs")
    func yieldsWhenBusyResidentEvictsThroughTheRealCoordinator() async throws {
        let storage = ModelLifecycleCoordinatorTests.tempDirectory()
        defer { try? FileManager.default.removeItem(at: storage) }
        let machine = MachineStub(availableGiB: 100, at: ModelLifecycleCoordinatorTests.epoch)
        let coordinator = ModelLifecycleCoordinatorTests.coordinator(machine: machine, storage: storage)
        let victimSpy = SpyEvictor(modelID: .soulxSinger)
        await coordinator.register(
            ModelRegistry.soulxSinger(baseURL: URL(string: "http://127.0.0.1:8099")!),
            evictor: victimSpy)
        await coordinator.register(
            ModelLifecycleCoordinatorTests.model("ace-step", holdGiB: 34, port: 8001), evictor: nil)
        try await ModelLifecycleCoordinatorTests.makeResident(coordinator, .soulxSinger)
        await coordinator.noteJobStarted(.soulxSinger, jobID: "job-1")

        let plan = await coordinator.resolveAdmission(.aceStep)
        #expect(
            plan.evicting == [.soulxSinger],
            "a busy, yieldsWhenBusy resident must be evicted, not protected — got \(plan)")
        #expect(
            plan.protectedByJobs.isEmpty,
            "yieldsWhenBusy is the ONE exception to F8's busy veto — got \(plan)")
        _ = try await coordinator.commitAdmission(plan, for: .aceStep)
        #expect(await victimSpy.callCount() == 1)
    }
}
