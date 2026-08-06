import Foundation
import Testing

@testable import AIServices

/// The pure planner's tests — m23-dl, **rewritten for the 2026-08-05 scope cut**.
///
/// ⚠️⚠️ **Roughly two thirds of this suite was DELETED, not weakened.** The
/// planner used to compare a per-model hold requirement against the machine's
/// available memory and refuse a boot that did not fit; the user removed that:
///
/// > *"let's not check for memory then, let it fail if this happens, but still
/// > good to clean it up"*
///
/// Gone with it: the shortfall arithmetic and its seven-clause refusal message,
/// the estimated-may-warn-never-refuse rule, the hard floor, `force`, and every
/// test that asserted any of them. Those tests were not stale — they were
/// **testing a decision that no longer exists**, and leaving them (or softening
/// them into something that still passed) would have left the suite asserting
/// that a gate the user removed is still there.
///
/// What is left is what the user kept: **unload-before-load** and
/// **single-flight**. The planner no longer has a `memory` field at all, so there
/// is nothing in this file for a memory assertion to be written against.
@Suite("ModelAdmission — the pure planner (m23-dl)")
struct ModelAdmissionTests {

    // MARK: - Fixtures

    static let gib: UInt64 = 1 << 30
    static let epoch = Date(timeIntervalSince1970: 1_770_000_000)

    static func aceStep() -> ModelDescriptor {
        ModelRegistry.aceStep(baseURL: URL(string: "http://127.0.0.1:8001")!)
    }

    static func rvc() -> ModelDescriptor {
        ModelRegistry.rvc(baseURL: URL(string: "http://127.0.0.1:8002")!)
    }

    /// A model that exists only in this test — the N-model claim's probe.
    static func synthetic(_ id: String, estimated: UInt64) -> ModelDescriptor {
        ModelDescriptor(
            id: ModelID(rawValue: id), displayName: "Synthetic \(id)",
            baseURL: URL(string: "http://127.0.0.1:8099")!,
            estimatedHoldBytes: estimated,
            estimatedHoldProvenance: "estimated in a test, never measured resident")
    }

    static func facts(
        request: ModelDescriptor, resident: [ModelAdmission.Resident] = [],
        inFlight: ModelAdmission.InFlight? = nil
    ) -> ModelAdmission.Facts {
        ModelAdmission.Facts(
            request: request, resident: resident, inFlight: inFlight, now: epoch, generation: 7)
    }

    static func resident(
        _ id: ModelID, name: String, hold: UInt64, evictable: Bool = true, jobs: Int = 0
    ) -> ModelAdmission.Resident {
        ModelAdmission.Resident(
            id: id, displayName: name, holdBytes: hold, holdConfidence: .measured,
            isEvictable: evictable, activeJobs: jobs, admittedAt: epoch)
    }

    // MARK: - Unload-before-load

    @Test("Booting a model unloads every other resident model, unconditionally")
    func bootUnloadsTheOthers() throws {
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.rvc, name: "RVC voice conversion", hold: 3 * Self.gib)]))
        // ⚠️ No memory is consulted, and no memory field exists to consult. This
        // is the user's own wording — "unload ACE … when we attempt to load other
        // model" — and it holds on a machine with 127 GiB free.
        #expect(plan.isAdmitted)
        #expect(plan.evicting == [.rvc])
        #expect(plan.protectedByJobs.isEmpty)
    }

    @Test("ANTI-VACUITY TWIN — with nothing else resident, nothing is unloaded")
    func nothingResidentUnloadsNothing() throws {
        let plan = ModelAdmission.resolve(Self.facts(request: Self.aceStep()))
        #expect(plan.isAdmitted)
        #expect(plan.evicting.isEmpty, "an empty plan must come from an empty world")
    }

    @Test("EVERY other evictable model goes, not a memory-derived subset")
    func allOthersAreUnloaded() throws {
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.synthetic("flamingo", estimated: 8 * Self.gib),
            resident: [
                Self.resident(.aceStep, name: "ACE", hold: 74 * Self.gib),
                Self.resident(.rvc, name: "RVC", hold: 3 * Self.gib),
                Self.resident(ModelID(rawValue: "other"), name: "Other", hold: 20 * Self.gib),
            ]))
        // Largest-first ordering survives only so the plan is deterministic and
        // this assertion can name the exact list; nothing depends on it any more,
        // because every candidate is taken.
        #expect(plan.evicting == [.aceStep, ModelID(rawValue: "other"), .rvc])
    }

    @Test("A NON-evictable model is left alone and is not reported as protected by a job")
    func nonEvictableIsNeverTouched() throws {
        let pinned = ModelAdmission.Resident(
            id: .rvc, displayName: "RVC", holdBytes: 3 * Self.gib, isEvictable: false)
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(), resident: [pinned]))
        #expect(plan.evicting.isEmpty)
        #expect(plan.protectedByJobs.isEmpty, "`isEvictable: false` is not a job protection")
    }

    // MARK: - F8: an active job is an absolute veto

    @Test("F8. A model with an active job is NEVER unloaded — and the boot proceeds anyway")
    func busyModelIsProtectedAndTheBootProceeds() throws {
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.rvc, name: "RVC voice conversion",
                                     hold: 3 * Self.gib, jobs: 1)]))
        // ⚠️ Under the old design this was a refusal. Now the busy model stays
        // loaded and the boot goes ahead into whatever memory is left — the
        // user's *"let it fail if this happens"* — because the alternative is
        // unloading a model in the middle of their render, which would be far
        // worse than the memory it reclaims.
        #expect(plan.isAdmitted)
        #expect(plan.evicting.isEmpty)
        #expect(plan.protectedByJobs == [.rvc])

        // ANTI-VACUITY TWIN: the same facts with no job DO unload it.
        let idle = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.rvc, name: "RVC voice conversion", hold: 3 * Self.gib)]))
        #expect(idle.evicting == [.rvc])
    }

    @Test("A skipped cleanup EXPLAINS ITSELF in the message")
    func protectedModelIsNamedInTheMessage() throws {
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.rvc, name: "RVC voice conversion",
                                     hold: 3 * Self.gib, jobs: 2)]))
        let message = ModelAdmission.message(
            for: plan, descriptor: Self.aceStep(), generation: 7)
        #expect(message.contains("RVC voice conversion is busy with 2 jobs"))
        #expect(message.contains("stays loaded"))
        // The honest consequence, said out loud rather than discovered later.
        #expect(message.contains("this load may fail"))
        #expect(message.contains("generation 7"))
    }

    // MARK: - Single-flight: the ONE thing that can still stop a boot

    @Test("A boot in flight blocks every other boot, including the same model")
    func singleFlightBeatsEverything() throws {
        let holder = ModelAdmission.InFlight(
            id: .rvc, displayName: "RVC voice conversion",
            since: Self.epoch.addingTimeInterval(-12), ticket: 41)
        for request in [Self.aceStep(), Self.rvc()] {
            let plan = ModelAdmission.resolve(Self.facts(
                request: request,
                // Even already-resident loses to single-flight: two boots of one
                // model is the double-load this guard exists to prevent.
                resident: [Self.resident(.rvc, name: "RVC", hold: 3 * Self.gib)],
                inFlight: holder))
            guard case .bootInFlight(let named, let seconds) = plan else {
                Issue.record("expected .bootInFlight for \(request.id), got \(plan)")
                return
            }
            #expect(named.ticket == 41)
            #expect(seconds == 12)
            #expect(plan.isAdmitted == false)
            #expect(plan.evicting.isEmpty, "a plan that cannot succeed must not act")
        }
    }

    @Test("ANTI-VACUITY TWIN — with no boot in flight the same facts admit")
    func withoutInFlightItAdmits() throws {
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.rvc, name: "RVC", hold: 3 * Self.gib)]))
        #expect(plan.isAdmitted)
    }

    @Test("The single-flight message names the holder, the age and the ticket")
    func inFlightMessageIsActionable() throws {
        let holder = ModelAdmission.InFlight(
            id: .aceStep, displayName: "ACE-Step song generation", since: Self.epoch, ticket: 41)
        let message = ModelAdmission.inFlightMessage(holder, seconds: 12, generation: 7)
        #expect(message.contains("ACE-Step song generation"))
        #expect(message.contains("12s so far"))
        #expect(message.contains("ticket 41"))
        #expect(message.contains("ai.modelResidency"))
        // ⚠️ NO `force`. It does not exist any more, and offering it here would
        // be offering a way to cause the double-load this guard prevents.
        #expect(!message.lowercased().contains("force"))
    }

    // MARK: - Already resident

    @Test("An already-resident model is a no-op that mints nothing")
    func alreadyResidentIsANoOp() throws {
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.aceStep, name: "ACE-Step song generation",
                                     hold: 74 * Self.gib)]))
        guard case .alreadyResident(let id) = plan else {
            Issue.record("expected .alreadyResident, got \(plan)")
            return
        }
        #expect(id == .aceStep)
        #expect(plan.isAdmitted == false, "there is nothing to boot, so there is no ticket")
        #expect(plan.evicting.isEmpty, "a model must never plan to unload itself")
    }

    // MARK: - The N-model claim

    @Test("A THIRD model needs no planner edit")
    func thirdModelNeedsNoEdit() throws {
        // Registered nowhere in `ModelRegistry`, existing only here.
        let flamingo = Self.synthetic("music-flamingo", estimated: 8 * Self.gib)
        let plan = ModelAdmission.resolve(Self.facts(
            request: flamingo,
            resident: [
                Self.resident(.aceStep, name: "ACE", hold: 74 * Self.gib),
                Self.resident(.rvc, name: "RVC", hold: 3 * Self.gib, jobs: 1),
            ]))
        // Mutual exclusion is a RULE, not a pairwise table: no `ExclusionGroup`,
        // no "large vs small" enum, and this passes with zero changes to
        // `ModelAdmission.swift`.
        #expect(plan.evicting == [.aceStep])
        #expect(plan.protectedByJobs == [.rvc])
    }

    // MARK: - Messages

    @Test("An admit message names each unload and what it frees")
    func admitMessageNamesTheUnloads() throws {
        let plan = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.rvc, name: "RVC voice conversion", hold: 3 * Self.gib)]))
        let message = ModelAdmission.message(
            for: plan, descriptor: Self.aceStep(), generation: 7)
        #expect(message.contains("Loading ACE-Step song generation"))
        #expect(message.contains("Unloading RVC voice conversion first"))
        #expect(message.contains("one local model loaded at a time"))
        #expect(message.contains("generation 7"))
    }

    @Test("An unknown model id teaches the valid ids")
    func unknownModelTeaches() throws {
        let message = ModelAdmission.unknownModelMessage(
            "flamingo", valid: [.aceStep, .rvc], generation: 7)
        #expect(message.contains("\"flamingo\""))
        #expect(message.contains("ace-step and rvc"))
        #expect(message.contains("generation 7"))
    }

    @Test("dryRunMessage keeps the launch command line in BOTH polarities")
    func dryRunKeepsTheCommandLine() throws {
        let launch = "/bin/bash /tmp/ace/run.sh (cwd: /tmp/ace)"
        let admitted = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            resident: [Self.resident(.rvc, name: "RVC", hold: 3 * Self.gib)]))
        let admittedLine = admitted.dryRunMessage(
            launch: launch, descriptor: Self.aceStep(), generation: 7)
        #expect(admittedLine.hasPrefix("[dry-run] would spawn:"))
        #expect(admittedLine.contains("run.sh"))
        #expect(admittedLine.contains("/tmp/ace"))
        // ⚠️ A dry run must SAY it would unload the other model — and, per the
        // coordinator's F15 split, must not actually unload it.
        #expect(admittedLine.contains("Unloading RVC"))

        let blocked = ModelAdmission.resolve(Self.facts(
            request: Self.aceStep(),
            inFlight: ModelAdmission.InFlight(
                id: .rvc, displayName: "RVC", since: Self.epoch, ticket: 41)))
        let blockedLine = blocked.dryRunMessage(
            launch: launch, descriptor: Self.aceStep(), generation: 7)
        #expect(blockedLine.hasPrefix("[dry-run] would NOT spawn:"))
        // Still carries the command line: `SidecarManagerTests`' dry-run test
        // asserts on `run.sh` and the resolved directory, and it has nothing to
        // do with this feature.
        #expect(blockedLine.contains("run.sh"))
        #expect(blockedLine.contains("/tmp/ace"))
    }

    // MARK: - The corroboration figure (it no longer decides anything)

    @Test("A machine-matched observation beats the shipped seed")
    func observationBeatsSeed() throws {
        let observed = ModelObservation(
            modelID: .aceStep, holdBytes: 60 * Self.gib,
            observedAt: Date(timeIntervalSince1970: 1_754_400_000), physicalBytes: 128 * Self.gib)
        let requirement = ModelRegistry.requirement(
            for: Self.aceStep(), observation: observed, physicalBytes: 128 * Self.gib)
        #expect(requirement.bytes == 60 * Self.gib)
        #expect(requirement.confidence == .measured)
        #expect(requirement.provenance.contains("measured on this machine 2025-08-05"))
    }

    @Test("An observation from a DIFFERENT machine is discarded, and the seed survives")
    func foreignObservationIsDiscardedButTheSeedIsNot() throws {
        let foreign = ModelObservation(
            modelID: .aceStep, holdBytes: 12 * Self.gib, observedAt: Self.epoch,
            physicalBytes: 16 * Self.gib)
        let requirement = ModelRegistry.requirement(
            for: Self.aceStep(), observation: foreign, physicalBytes: 128 * Self.gib)
        // A figure LEARNED on another machine is not a measurement of this one…
        #expect(requirement.bytes == ModelRegistry.aceStepMeasuredHoldBytes)
        // …but a model's weights are the same size everywhere, so the SEED is
        // not subject to that rule and survives.
        #expect(requirement.confidence == .measured)
    }

    @Test("A model with no seed and no observation is ESTIMATED")
    func noSeedNoObservationIsEstimated() throws {
        let requirement = ModelRegistry.requirement(
            for: Self.rvc(), observation: nil, physicalBytes: 128 * Self.gib)
        #expect(requirement.bytes == ModelRegistry.rvcEstimatedHoldBytes)
        #expect(requirement.confidence == .estimated)
        #expect(requirement.provenance.contains("never measured resident"))
    }

    @Test("An observation for a DIFFERENT model is ignored")
    func mismatchedObservationIsIgnored() throws {
        let wrongModel = ModelObservation(
            modelID: .rvc, holdBytes: 2 * Self.gib, observedAt: Self.epoch,
            physicalBytes: 128 * Self.gib)
        let requirement = ModelRegistry.requirement(
            for: Self.aceStep(), observation: wrongModel, physicalBytes: 128 * Self.gib)
        #expect(requirement.bytes == ModelRegistry.aceStepMeasuredHoldBytes)
    }

    @Test("ACE's measured hold is still shipped — it is what grades an unload")
    func aceShipsAMeasuredHold() throws {
        let requirement = ModelRegistry.requirement(
            for: Self.aceStep(), observation: nil, physicalBytes: 128 * Self.gib)
        #expect(requirement.confidence == .measured)
        #expect(requirement.bytes == 79_993_765_888)
        // ⚠️ This figure no longer gates anything. It is `expectedHoldBytes` in
        // an `EvictionEvidence`, i.e. the yardstick that turns "ACE unloaded and
        // ~75 GB came back" into a checkable claim rather than a hope. If it were
        // dropped, every unload verdict would collapse to `.inconclusive`.
        #expect(ModelMemory.formatGB(requirement.bytes) == "80.0 GB")
    }
}
