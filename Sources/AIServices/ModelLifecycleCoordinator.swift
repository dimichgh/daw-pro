import DAWCore
import Darwin
import Foundation

// MARK: - How the coordinator stops something

/// How the coordinator stops a model without importing `DAWControl` or knowing
/// what a sidecar even is. Both managers conform and register themselves.
///
/// ⚠️⚠️ **`evictWithoutCoordinator` is not a naming quirk — it is a hard rule.**
/// `start()` → admission → the coordinator evicts RVC → `VoiceConversionManager.
/// stop()`; if that routed back through the coordinator we would re-enter the
/// coordinator's actor context mid-mutation. Swift actors are reentrant at every
/// `await`, so there is no deadlock — there is something worse: residency state
/// observable half-updated and a single-flight flag that can be cleared twice.
///
/// **A conformer MUST NOT call `resolveAdmission`, `commitAdmission`,
/// `admitted`, `unload` or `noteJob*` from inside this method.** The coordinator
/// is the only thing that mutates residency, and it does so after this returns.
public protocol ModelEvicting: Sendable {
    var modelID: ModelID { get }
    func evictWithoutCoordinator() async throws -> ModelStopEvidence
}

/// The **authority** limbs of "did it actually stop?", gathered by the evictor
/// itself because only it knows its port, its probe and its process tree.
///
/// ⚠️ This is NOT `EvictionEvidence`. §3.4 of the design has the evictor return
/// the full evidence struct, but §4.4's `EvictionEvidence` carries
/// `generationBefore`/`generationAfter` and the before/after memory samples —
/// and §4.3 forbids the evictor from calling back into the coordinator, which is
/// the only thing that knows the generation and owns the injected memory
/// sampler. The evictor supplies **authority**, the coordinator adds
/// **corroboration**; that is exactly the line §4.4 draws.
public struct ModelStopEvidence: Codable, Sendable, Equatable {
    /// `SidecarProcessDiscovery.listeners(onPort:)` came back
    /// `.nothingListening`.
    ///
    /// ⚠️ `.unavailable` is **NOT** success — "I could not ask" is not "I found
    /// nothing" (m23-az-1). An unavailable lookup sets this `false` and records
    /// why in `portLookupDetail`.
    public var portFree: Bool
    /// Set when the port lookup could not be performed at all, so a `false`
    /// `portFree` can be told apart from a port that is genuinely still held.
    public var portLookupDetail: String?
    /// The health probe is unreachable.
    public var probeUnreachable: Bool
    /// Pids from the **pre-kill captured tree** that are still alive. Captured
    /// before signalling, because a child whose parent exits is reparented to
    /// pid 1 and the linkage is gone.
    public var treePidsAliveAfter: [Int32]
    /// The stop's own message, verbatim, for the report.
    public var detail: String

    public init(
        portFree: Bool, portLookupDetail: String? = nil, probeUnreachable: Bool,
        treePidsAliveAfter: [Int32] = [], detail: String
    ) {
        self.portFree = portFree
        self.portLookupDetail = portLookupDetail
        self.probeUnreachable = probeUnreachable
        self.treePidsAliveAfter = treePidsAliveAfter
        self.detail = detail
    }

    /// All three authority limbs. Any one false ⇒ the unload FAILED.
    public var stopped: Bool {
        portFree && probeUnreachable && treePidsAliveAfter.isEmpty
    }
}

extension ModelStopEvidence {

    /// PURE. Which pids a post-stop liveness check must consult, derived from
    /// the **same** pre-kill capture that did the signalling.
    ///
    /// Taking a fresh `ps` snapshot here instead would be two answers to one
    /// question, and the second one is unreconstructible: a child whose parent
    /// exits is reparented to pid 1 and the linkage is gone (measured at
    /// m23-az-1). `SidecarStop.terminateTree` already captures descendants
    /// before signalling; this reuses that capture.
    ///
    /// ⚠️ **Recycled pids are EXCLUDED, and that is not a shortcut.**
    /// `SidecarStop` marks a pid recycled when its command line changed between
    /// planning and signalling — i.e. the pid now belongs to somebody else, and
    /// it deliberately refused to signal it. Counting it as "our model is still
    /// alive" would report a failed unload because an unrelated process happened
    /// to inherit a number.
    static func capturedTreePids(_ outcome: SidecarStop.TerminationOutcome?) -> [Int32] {
        guard let outcome else { return [] }
        var pids: [Int32] = outcome.targetRecycled ? [] : [outcome.targetPid]
        pids += outcome.descendantsStopped
        pids += outcome.descendantsSurvived
        return pids
    }

    /// The ONE home for gathering the three authority limbs. Impure — an `lsof`
    /// fork and a `kill(pid, 0)` per captured pid — but it signals nothing.
    ///
    /// The health probe itself stays with each manager (each owns its own probe
    /// enum), exactly as `resolvedStopPlan()` already does; only the answer
    /// crosses this boundary.
    static func gather(
        baseURL: URL, probeAnswering: Bool, capturedTreePids: [Int32], detail: String
    ) -> ModelStopEvidence {
        var portFree = false
        var portLookupDetail: String?
        if let port = SidecarProcessDiscovery.port(of: baseURL) {
            switch SidecarProcessDiscovery.listeners(onPort: port) {
            case .nothingListening:
                portFree = true
            case .listeners(let pids):
                portLookupDetail = "port \(port) is still held by pid(s) "
                    + pids.map(String.init).joined(separator: ", ")
            case .unavailable(let reason):
                // ⚠️ NOT success. "I could not ask" is not "I found nothing".
                portLookupDetail = "could not ask who holds port \(port) \u{2014} \(reason)"
            }
        } else {
            portLookupDetail = "no TCP port could be derived from \(baseURL.absoluteString)"
        }
        return ModelStopEvidence(
            portFree: portFree,
            portLookupDetail: portLookupDetail,
            probeUnreachable: !probeAnswering,
            treePidsAliveAfter: capturedTreePids.filter { kill($0, 0) == 0 },
            detail: detail)
    }
}

// MARK: - Eviction vocabulary

public enum EvictionReason: String, Codable, Sendable, Equatable {
    /// `ai.modelUnload` / `ai.sidecarStop` — a human or agent asked.
    case explicit
    /// Unload-before-load: another model is booting. **Unconditional cleanup,
    /// not a memory decision** — the memory gate was cut on 2026-08-05.
    case admission
    /// ⭐ **SHIPPED, ON.** `idleUnloadSeconds` seconds after the model's last job
    /// reached a terminal state (or after it booted and was never used). ACE
    /// ships at 600 s; RVC ships `nil` and never reaches this.
    case idleTimeout
    /// The app is quitting.
    case shutdown
}

/// Did the memory come back? **Corroboration only — this never fails a verb.**
///
/// `availableAtAdmission` is a differential on a shared, noisy counter across a
/// window that can be minutes long: idle drift is ±0.3 GB between adjacent
/// samples, and in the measured file-backed run the baseline moved 2.13 GB and
/// **stayed moved** after the child was killed. Over a real generation job with
/// Chrome and Xcode live it is stale by GBs for reasons that have nothing to do
/// with the sidecar. A memory-gated verdict reports failed unloads that did not
/// fail.
public enum MemoryVerdict: String, Codable, Sendable, Equatable {
    /// Returned ≥ 0.5 × the expected hold.
    case returned
    /// Returned more than the 1 GiB noise floor but less than half.
    case partial
    /// Below the noise floor, or the expected hold is unknown.
    case inconclusive
    /// The expected hold was under 1 GiB — a file-backed model, where nothing
    /// WAS held in the sense this metric counts.
    case notAHold
}

/// Everything observed about one eviction: three authority limbs that can fail
/// the verb, plus memory corroboration that never can.
public struct EvictionEvidence: Codable, Sendable, Equatable {
    public var portFree: Bool
    public var portLookupDetail: String?
    public var probeUnreachable: Bool
    public var treePidsAliveAfter: [Int32]
    public var availableBeforeBytes: UInt64
    public var availableAfterBytes: UInt64
    /// Signed — it may legitimately be negative (another process grew).
    public var memoryReturnedBytes: Int64
    public var memoryVerdict: MemoryVerdict
    public var expectedHoldBytes: UInt64?
    public var generationBefore: UInt64
    public var generationAfter: UInt64

    /// The answer to *"did it stop?"* — and the only thing allowed to fail a
    /// command.
    public var stopped: Bool {
        portFree && probeUnreachable && treePidsAliveAfter.isEmpty
    }
}

public struct EvictionReport: Codable, Sendable, Equatable {
    public var modelID: ModelID
    public var reason: EvictionReason
    /// True only when all three authority limbs agree.
    public var stopped: Bool
    /// The stop's own message plus, on failure, why.
    public var detail: String
    public var evidence: EvictionEvidence
}

/// `ai.modelUnload`'s wire response. Lives here rather than in `DAWControl` for
/// the same reason `SidecarStatus` does: the control protocol and MCP both thread
/// this Codable onto the wire verbatim, and a hand-duplicated shape at each call
/// site is how a wire drifts.
public struct ModelUnloadResponse: Codable, Sendable, Equatable {
    /// The m23-ah nonce AFTER the unload. An unload that did not move this did
    /// not happen.
    public var generation: UInt64
    public var models: [EvictionReport]

    public init(generation: UInt64, models: [EvictionReport]) {
        self.generation = generation
        self.models = models
    }
}

// MARK: - The residency read (scope item ④)

public struct ModelResidencySummary: Codable, Sendable, Equatable {
    public var modelID: ModelID
    public var displayName: String
    public var port: Int?
    /// `resident` | `notResident`
    public var resident: Bool
    /// What an unload of this model is expected to return — **corroboration
    /// only**; it decides nothing (see `HoldRequirement`).
    public var holdBytes: UInt64
    public var holdConfidence: HoldRequirement.Confidence
    public var holdProvenance: String
    public var estimatedHoldBytes: UInt64
    public var activeJobs: Int
    public var admittedAt: Date?
    public var idleForSeconds: Int?
    /// `nil` = idle unload is off for this model (RVC ships this way). ACE ships
    /// `600`.
    public var idleUnloadSeconds: Double?
    /// When the scheduled idle unload will fire, or nil when none is pending.
    /// Makes "is the ten-minute timer actually armed?" observable rather than
    /// inferred.
    public var idleUnloadAt: Date?
    /// What booting this model right now would unload first (unload-before-load),
    /// computed by the SAME planner the boot path uses so a panel and a boot can
    /// never disagree.
    public var nextBootWouldUnload: [ModelID]
    /// …and what it would leave alone because a job is running on it (F8).
    public var nextBootProtectedByJobs: [ModelID]
    /// The planner's own message for that plan.
    public var nextBootPlan: String
    /// Only populated when process detail was explicitly requested — it costs a
    /// `/bin/ps` fork.
    public var treeFootprintBytes: UInt64?
    public var treeResidentBytes: UInt64?
    public var pids: [Int32]?
    /// ⭐ **The honesty field.** `resident` means *this coordinator booted it and
    /// is tracking it*. A sidecar the user started by hand, or one that survived
    /// an app crash, is holding its 80 GB while `resident` reads `false` — which
    /// is exactly the case the user cares about. `portBusy` asks the machine
    /// instead of the bookkeeping: something is listening on this model's port.
    /// Only populated when `includeProcessDetail` is true, because it costs an
    /// `lsof` fork per model.
    ///
    /// ⚠️ `ai.modelUnload` works on an untracked sidecar regardless — it goes
    /// through the manager's real stop path, not through `residents`. Only the
    /// *reporting* depends on this field.
    public var portBusy: Bool?
}

public struct InFlightSummary: Codable, Sendable, Equatable {
    public var modelID: ModelID
    public var displayName: String
    public var seconds: Int
    public var ticket: UInt64
    public var pid: Int32?
}

public struct ResidencyReport: Codable, Sendable, Equatable {
    /// ⭐ The m23-ah nonce. Two reads with the same `generation` describe the
    /// same world, and an eviction that did not bump it did not happen.
    public var generation: UInt64
    public var sampledAt: Date
    public var memory: ModelMemory.Snapshot
    public var policy: ModelLifecyclePolicy
    public var inFlight: InFlightSummary?
    public var models: [ModelResidencySummary]
    /// Age of the cached process snapshot, when one was reused rather than
    /// re-forked.
    public var processDetailAgeSeconds: Int?
}

// MARK: - The coordinator

/// The one actor holding residency bookkeeping, the global single-flight, the
/// monotonic `generation` nonce, and the eviction-verification loop — m23-dl.
///
/// ## What is NOT here
///
/// The decision. `ModelAdmission.resolve` is pure and lives next door; this file
/// gathers facts, acts on the plan, and books the result. That is the
/// `SidecarStopPlanner` shape, deliberately.
///
/// **Also not here: a memory gate.** The user cut it on 2026-08-05 (*"let's not
/// check for memory then, let it fail if this happens, but still good to clean it
/// up"*). Nothing this actor does can refuse a boot for memory. `ModelMemory` is
/// still sampled, but only to answer *"did the unload actually give the memory
/// back?"* — corroboration that is reported and never fails a verb (F3/F4).
///
/// ## The two-method rule (F15) — read before "simplifying" this
///
/// ⚠️⚠️ **`resolveAdmission` and `commitAdmission` must NEVER be folded into one
/// `admit()`.** `resolveAdmission` is read-only (one mach trap, a process
/// snapshot that never signals, and a pure planner) and is safe to call **before**
/// a caller's `dryRun` branch, which is required so a dry run can never describe
/// a different decision than the real path would take. `commitAdmission`
/// **acts**: it mints the flight ticket and it SIGTERMs the models the plan names
/// for eviction, so it may run only **after** the `dryRun` branch has returned.
/// A single `admit()` placed where `resolveAdmission` goes would let
/// `dryRun: true` — a mode whose entire contract is "spawn nothing, signal
/// nothing" — kill the user's live RVC sidecar. The hermetic test seam below
/// means **no test catches that**; it is a review item, so it is stated here at
/// the definition site rather than left to a design document.
///
/// ## The test seam (F2)
///
/// `sampleMemory` and `now` are injected. Without that, an admission check that
/// reads the real machine turns every existing sidecar test into one whose
/// verdict depends on how much Chrome the developer has open — the single most
/// likely way this item breaks the suite.
public actor ModelLifecycleCoordinator {

    /// The process-wide instance the managers will hold in Phase 3.
    ///
    /// ⚠️ **No test may touch this.** One reference creates real directories
    /// under the user's Application Support and makes the suite order-dependent.
    /// Every test constructs its own with a temporary `storageDirectory`.
    public static let shared = ModelLifecycleCoordinator()

    // MARK: Ticket

    /// A minted flight token.
    ///
    /// ⚠️⚠️ **TICKET LIFETIME IS NOT FUNCTION SCOPE (F14).** `SidecarManager.
    /// start()` returns `.starting` when its ~30 s poll window expires, and the
    /// file's own comment says model loads *"can legitimately take ~1 min cold,
    /// well past the 30s window `start()` itself blocks for."* So a
    /// `defer { release(ticket) }` on a cold ACE boot releases the flight token
    /// at 30 s with 80 GB still loading, and the next start is admitted on top
    /// of it — **precisely the double-load this item exists to prevent.**
    ///
    /// The ticket therefore takes the manager's own three `startedAt` clearing
    /// rules: (a) a health probe observes healthy, (b) the tracked process is
    /// found dead, (c) `stop()` runs — plus the stale-ticket backstop, which
    /// only ever reclaims a ticket whose recorded pid is **dead**.
    ///
    /// **Never `defer { Task { await release(ticket) } }`.** Beyond the lifetime
    /// bug, a `Task` inside `defer` is fire-and-forget: unordered with respect to
    /// everything else and outside the actor's serialisation.
    public struct Ticket: Sendable, Equatable {
        public var value: UInt64
        public var modelID: ModelID
        /// Sampled at mint time so `admitted(_:healthy:)` can learn what the boot
        /// actually cost. Corroboration input only.
        public var availableAtAdmission: UInt64
        public var mintedAt: Date
        /// Residency-mutation counter at mint time — the "another model's
        /// residency changed during the boot window" discard rule (§2.3).
        ///
        /// ⚠️ With unload-before-load now unconditional, this discards **most**
        /// observations in practice: every boot that evicts another model bumps
        /// `residencyEpoch`, so the delta is not attributable. That is correct —
        /// the delta would net the victim's release against our load — and it
        /// means a learned figure is only ever recorded for a boot with nothing
        /// else resident. Pinned by a test rather than left as reasoning.
        var residencyEpoch: UInt64
        public var pid: Int32?
    }

    private struct ResidentRecord {
        var descriptor: ModelDescriptor
        var holdBytes: UInt64
        var holdConfidence: HoldRequirement.Confidence
        /// Open job ids, keyed rather than counted so a repeated terminal poll
        /// cannot double-decrement and a repeated submit cannot double-count.
        var jobs: [String: Date]
        var admittedAt: Date
        var lastJobEndedAt: Date?
        var rootPid: Int32?

        /// Jobs still counting toward the F8 veto, i.e. those inside the lease.
        func activeJobs(now: Date, leaseSeconds: Double) -> Int {
            jobs.values.filter { now.timeIntervalSince($0) <= leaseSeconds }.count
        }
    }

    // MARK: State

    /// ⭐ THE m23-ah NONCE. Monotonic, never reset, bumped on EVERY residency
    /// transition: admit, healthy, evict, evict-failed, ticket release,
    /// reclamation. Turns *"did this actually unload?"* from inference into
    /// observation.
    private(set) var generation: UInt64 = 0
    /// Bumped ONLY when a model becomes or stops being resident. Separate from
    /// `generation` on purpose: the observation-discard rule needs "did anyone
    /// else's residency move", and `generation` moves for reasons that are not
    /// residency changes.
    private var residencyEpoch: UInt64 = 0

    private var descriptors: [ModelID: ModelDescriptor] = [:]
    private var evictors: [ModelID: ModelEvicting] = [:]
    private var residents: [ModelID: ResidentRecord] = [:]
    private var inFlight: Ticket?
    private var observations: [ModelID: ModelObservation] = [:]
    private var observationsLoaded = false
    private var lockDescriptor: Int32?

    private var cachedProcessSnapshot: SidecarProcessDiscovery.Snapshot?
    private var cachedProcessSnapshotAt: Date?

    /// Pending idle-unload wake-ups, at most ONE per model. Re-scheduling
    /// cancels the previous task rather than adding a second.
    private var idleTasks: [ModelID: Task<Void, Never>] = [:]
    private var idleDeadlines: [ModelID: Date] = [:]
    /// Which arming a pending wake-up belongs to. See `idleUnloadFired`.
    private var idleEpochs: [ModelID: UInt64] = [:]
    private var idleEpochCounter: UInt64 = 0
    /// Cumulative count of wake-ups ever scheduled. The anti-vacuity assertion
    /// the previous pass deferred needs BOTH this and `pendingIdleUnloads()`:
    /// "exactly one wake-up" is ambiguous between cumulative and pending, and
    /// cancel-and-reschedule moves them differently.
    private var idleWakeUpsScheduled: UInt64 = 0

    public let policy: ModelLifecyclePolicy
    private let sampleMemory: @Sendable () -> ModelMemory.Snapshot
    private let now: @Sendable () -> Date
    private let storageDirectory: URL?
    /// Seconds to wait before sampling memory after a stop. 1.0 s in production
    /// (the measured anonymous run returned to −0.07 GB of baseline within 2 s);
    /// tests set 0. The value is REPORTED, never asserted on, so being early
    /// only makes the verdict more conservative.
    private let settleSeconds: Double
    /// The idle timer's only wait. Injected so a test can drive the timer without
    /// waiting ten real minutes.
    ///
    /// Non-throwing on purpose, but **this was not what fixed the cancellation
    /// crash** — it was tried as a candidate fix and the crash persisted
    /// unchanged. The actual mitigation is in `cancelIdleUnload`, which no longer
    /// cancels at all; read that note for what is and is not established.
    ///
    /// It is kept in this shape only because it is the simpler contract: no
    /// injected stub has ever thrown (`SleepGate`, the one test double, is
    /// `func wait() async`), so `throws` was capability that existed solely for
    /// the real `Task.sleep`. Cancellation is observed via `Task.isCancelled` at
    /// the call site rather than propagated as an error.
    private let sleepSeconds: @Sendable (Double) async -> Void

    public init(
        policy: ModelLifecyclePolicy = .init(),
        sampleMemory: @escaping @Sendable () -> ModelMemory.Snapshot = { ModelMemory.sample() },
        now: @escaping @Sendable () -> Date = { Date() },
        storageDirectory: URL? = nil,
        settleSeconds: Double = 1.0,
        sleepSeconds: @escaping @Sendable (Double) async -> Void = { seconds in
            // ⚠️ `try?`, not `try` — the cancellation must be absorbed HERE, in a
            // concrete closure body, never propagated through the indirect call.
            // See the crash note on `sleepSeconds`.
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        }
    ) {
        self.policy = policy
        self.sampleMemory = sampleMemory
        self.now = now
        self.storageDirectory = storageDirectory
        self.settleSeconds = settleSeconds
        self.sleepSeconds = sleepSeconds
    }

    // MARK: - Registration

    public func register(_ descriptor: ModelDescriptor, evictor: ModelEvicting?) {
        descriptors[descriptor.id] = descriptor
        if let evictor { evictors[descriptor.id] = evictor }
    }

    public func registeredModelIDs() -> [ModelID] {
        descriptors.keys.sorted { $0.rawValue < $1.rawValue }
    }

    public func currentGeneration() -> UInt64 { generation }

    // MARK: - RESOLVE (read-only — safe before a caller's dryRun branch)

    /// READ-ONLY. The pure planner over this actor's own bookkeeping. Signals
    /// nothing, mints nothing, mutates no residency state, and **takes no memory
    /// sample** — there is nothing left for one to decide.
    ///
    /// See the type-level comment: this is one half of the F15 split and must
    /// stay that way.
    ///
    /// ⚠️ **An UNREGISTERED model is admitted, not refused.** Refusing would be a
    /// gate, and there are no gates left; a model nobody registered simply boots
    /// with no lifecycle bookkeeping and no cleanup. This is also what keeps the
    /// process-wide `shared` coordinator inert in tests that never register
    /// anything — `SidecarManagerTests`' dry-run test would otherwise start
    /// reporting a refusal for a reason that has nothing to do with what it
    /// tests (F2).
    public func resolveAdmission(_ id: ModelID) -> ModelAdmission.Plan {
        guard let descriptor = descriptors[id] else {
            return .admit(evicting: [], protectedByJobs: [])
        }
        return plan(for: descriptor)
    }

    /// Whether this coordinator knows the model at all. `false` ⇒ every lifecycle
    /// call for it is inert.
    public func isRegistered(_ id: ModelID) -> Bool { descriptors[id] != nil }

    /// The planner's message for a plan, resolved against the registered
    /// descriptor. Empty for an unregistered model — there is nothing to say
    /// about lifecycle bookkeeping that does not exist.
    public func describe(_ plan: ModelAdmission.Plan, for id: ModelID) -> String {
        guard let descriptor = descriptors[id] else { return "" }
        return ModelAdmission.message(for: plan, descriptor: descriptor, generation: generation)
    }

    /// The dry-run line for a start that will not happen.
    ///
    /// ⚠️ For an **unregistered** model this returns the pre-m23-dl string
    /// byte-for-byte (`"[dry-run] would spawn: <launch>"`). That is not
    /// cosmetic: `SidecarManagerTests`' dry-run test pins the message, and every
    /// test that never registers a model must see exactly what it saw before this
    /// item existed.
    public func dryRunDescription(
        _ plan: ModelAdmission.Plan, for id: ModelID, launch: String
    ) -> String {
        guard let descriptor = descriptors[id] else { return "[dry-run] would spawn: \(launch)" }
        return plan.dryRunMessage(
            launch: launch, descriptor: descriptor, generation: generation)
    }

    /// Somebody stopped this model outside the coordinator — the direct
    /// `ai.sidecarStop` / `vc.sidecarStop` path.
    ///
    /// ⚠️ **Called by the ROUTER, never by a manager.** A manager's `stop()` is
    /// reachable from `evictWithoutCoordinator()`, and calling back into this
    /// actor from there is exactly the re-entrancy F7 forbids. Routing the wire
    /// verb's response through `unload` instead was the design's suggestion, and
    /// it was rejected here: it would have changed `ai.sidecarStop`'s response
    /// type and its stop-honesty error, which m23-bb paid for.
    public func noteStoppedExternally(_ id: ModelID) {
        cancelIdleUnload(id)
        if residents.removeValue(forKey: id) != nil { residencyEpoch &+= 1 }
        if let ticket = inFlight, ticket.modelID == id {
            inFlight = nil
            releaseFlightLock()
        }
        generation &+= 1
    }

    /// The ONE home for building `Facts`. Both the boot path and the residency
    /// read's `nextBootWouldUnload` go through it, which is what makes it
    /// impossible for a panel and a boot to disagree.
    private func plan(for descriptor: ModelDescriptor) -> ModelAdmission.Plan {
        let moment = now()
        let facts = ModelAdmission.Facts(
            request: descriptor,
            resident: residents.values.map { residentFacts($0, at: moment) },
            inFlight: inFlightSummaryForPlanner(),
            now: moment,
            generation: generation)
        return ModelAdmission.resolve(facts)
    }

    private func residentFacts(_ record: ResidentRecord, at moment: Date) -> ModelAdmission.Resident
    {
        ModelAdmission.Resident(
            id: record.descriptor.id,
            displayName: record.descriptor.displayName,
            holdBytes: record.holdBytes,
            holdConfidence: record.holdConfidence,
            isEvictable: record.descriptor.isEvictable,
            activeJobs: record.activeJobs(now: moment, leaseSeconds: policy.jobLeaseSeconds),
            admittedAt: record.admittedAt,
            lastJobEndedAt: record.lastJobEndedAt)
    }

    private func inFlightSummaryForPlanner() -> ModelAdmission.InFlight? {
        guard let ticket = reclaimedInFlight() else { return nil }
        return ModelAdmission.InFlight(
            id: ticket.modelID,
            displayName: descriptors[ticket.modelID]?.displayName ?? ticket.modelID.rawValue,
            since: ticket.mintedAt,
            ticket: ticket.value)
    }

    /// The in-flight ticket, after applying the stale-ticket rule.
    ///
    /// ⚠️ A ticket whose recorded pid is **alive** is NEVER reclaimed on a
    /// timer, however old it is. That is the `kill -0`-on-a-zombie trap in a
    /// different costume: a cold ACE load legitimately outruns any timeout we
    /// would pick, and reclaiming it would readmit a second boot on top of a
    /// live one.
    private func reclaimedInFlight() -> Ticket? {
        guard let ticket = inFlight else { return nil }
        let age = now().timeIntervalSince(ticket.mintedAt)
        guard age > policy.staleTicketSeconds else { return ticket }
        if let pid = ticket.pid, kill(pid, 0) == 0 { return ticket }
        // Older than the window AND (no pid recorded, or the pid is dead).
        inFlight = nil
        releaseFlightLock()
        generation &+= 1
        return nil
    }

    // MARK: - COMMIT (acts — only ever after a caller's dryRun branch)

    /// ACTS: mints the flight ticket and performs the unload-before-load the plan
    /// names.
    ///
    /// ⚠️ Takes the model id explicitly. §3.4 of the design has
    /// `commitAdmission(_ plan:)`, but `ModelAdmission.Plan` does not carry the
    /// requesting model for its admitting case, so that signature cannot know
    /// what it is booting.
    ///
    /// Returns `nil` for a model this coordinator does not know: nothing is
    /// tracked, nothing is minted, no lock is taken and no file is written. That
    /// is what keeps the `shared` instance inert for every test that never
    /// registers anything.
    ///
    /// Re-checks single-flight under the actor before minting, because the plan
    /// may be seconds stale, and re-takes the cross-process `flock`. Losing
    /// either race surfaces as `admissionRefused` carrying the in-flight
    /// message — **never** as a launch error, and never as a silent proceed.
    ///
    /// ⚠️⚠️ **A FAILED EVICTION DOES NOT ABORT THE BOOT any more.** It used to:
    /// the plan promised N bytes, the eviction refused, and the arithmetic no
    /// longer worked, so the boot was refused. With the memory gate cut there is
    /// no arithmetic to invalidate, and refusing here would be exactly the gate
    /// the user removed. The failure stays observable — `generation` bumps, and
    /// the victim keeps showing `resident: true` in `ai.modelResidency` — but the
    /// boot proceeds, which is the user's *"let it fail if this happens"*.
    @discardableResult
    public func commitAdmission(
        _ plan: ModelAdmission.Plan, for id: ModelID
    ) async throws -> Ticket? {
        guard descriptors[id] != nil else { return nil }
        if case .alreadyResident = plan { return nil }
        if case .bootInFlight(let holder, let seconds) = plan {
            throw SidecarError.admissionRefused(ModelAdmission.inFlightMessage(
                holder, seconds: seconds, generation: generation))
        }
        // Re-check under the actor: `resolveAdmission` released isolation
        // between resolving and here.
        if let holder = inFlightSummaryForPlanner() {
            let seconds = max(0, Int(now().timeIntervalSince(holder.since).rounded()))
            throw SidecarError.admissionRefused(ModelAdmission.inFlightMessage(
                holder, seconds: seconds, generation: generation))
        }

        let memory = sampleMemory()
        let ticket = Ticket(
            value: generation &+ 1,
            modelID: id,
            availableAtAdmission: memory.availableBytes,
            mintedAt: now(),
            residencyEpoch: residencyEpoch,
            pid: nil)

        if let failure = acquireFlightLock(ticket: ticket) {
            throw SidecarError.admissionRefused(
                "Another DAW Pro process is loading a model right now (\(failure)). DAW Pro loads "
                    + "one model at a time. Retry once it finishes. "
                    + "Decision generation \(generation).")
        }

        inFlight = ticket
        generation &+= 1
        appendDiagnosticRow(modelID: id, phase: "admit", memory: memory, treeUsage: nil)

        // Unload-before-load. An eviction can legitimately FAIL — `SidecarStop`
        // refuses whenever the sidecar is demonstrably answering but nothing safe
        // to signal was found — and the boot continues either way; see the
        // ⚠️⚠️ note above before "fixing" that into an abort.
        for victim in plan.evicting {
            _ = await performEviction(victim, reason: .admission)
        }
        return ticket
    }

    /// Record the pid the boot spawned, so the stale-ticket rule can tell a
    /// slow boot from a dead one. Phase 3 calls this right after `process.run()`.
    public func recordBootPid(_ ticket: Ticket, pid: Int32) {
        guard var current = inFlight, current.value == ticket.value else { return }
        current.pid = pid
        inFlight = current
    }

    // MARK: - Ticket release: the manager's own three clearing rules

    /// Releases the flight ticket AND records the §2.3 observation.
    ///
    /// ⚠️ Called from the manager's three `startedAt` clearing rules —
    /// **never from a `defer`** (F14).
    ///
    /// ⚠️ **THE ONE HOME FOR GIVING A TICKET BACK.** `healthy: false` is the
    /// boot-failed release (there used to be a separate `abandon(_:)` for that;
    /// it was deleted as dead API — nothing but its own test called it). So every
    /// throwing exit after the mint must reach HERE, in both managers.
    ///
    /// What a leaked ticket costs, since it is invisible rather than loud: it
    /// refuses every later boot with `bootInFlight` until the stale-ticket rule
    /// reclaims it, and the app-side auto-start callers swallow that with `try?`
    /// — so the symptom is "Start does nothing" for two minutes, with no error
    /// anywhere (F14). `SidecarManager.start()`'s `catch` carries the same note
    /// at the call site.
    public func admitted(_ ticket: Ticket, healthy: Bool) {
        guard let current = inFlight, current.value == ticket.value else {
            // A stale ticket (already reclaimed, or superseded). Releasing here
            // would clear somebody else's flight slot.
            return
        }

        let memory = sampleMemory()
        var becameResident = false
        if healthy, let descriptor = descriptors[ticket.modelID] {
            becameResident = true
            // §2.3: if anyone ELSE's residency moved between minting and now,
            // the memory delta is not attributable to this boot. Evaluated
            // BEFORE our own bump, or the model would always disqualify itself.
            let attributionIsOurs = ticket.residencyEpoch == residencyEpoch
            residencyEpoch &+= 1
            // ⚠️ ORDER MATTERS. Record the learned hold FIRST, so the residency
            // record below carries the freshly measured figure rather than the
            // seed — otherwise the unload's memory verdict would be judged
            // against a number the coordinator already knows to be stale.
            recordObservation(
                ticket, attributionIsOurs: attributionIsOurs,
                availableAtHealthy: memory.availableBytes, physicalBytes: memory.physicalBytes)
            let requirement = ModelRegistry.requirement(
                for: descriptor, observation: observations[ticket.modelID],
                physicalBytes: memory.physicalBytes)
            residents[ticket.modelID] = ResidentRecord(
                descriptor: descriptor,
                holdBytes: requirement.bytes,
                holdConfidence: requirement.confidence,
                jobs: [:],
                admittedAt: ticket.mintedAt,
                lastJobEndedAt: nil,
                rootPid: current.pid)
            appendDiagnosticRow(
                modelID: ticket.modelID, phase: "healthy", memory: memory,
                treeUsage: current.pid.map(treeUsage(rootPid:)))
        }

        inFlight = nil
        releaseFlightLock()
        generation &+= 1
        // ⭐ The idle clock starts when the model becomes resident, NOT only when
        // a job ends. A model that boots and is never used is exactly the case
        // the user was killing by hand, and a timer that only ever arms behind a
        // job hook is one missed hook away from never arming at all.
        if becameResident { scheduleIdleUnloadIfNeeded(ticket.modelID) }
    }

    /// §2.3's learning loop — the only thing that ever improves the
    /// corroboration figure. **It cannot affect whether anything boots.**
    ///
    /// An observation is DISCARDED when another model's residency moved during
    /// the boot window (the attribution is not ours), when the delta is negative
    /// or under the 1 GiB noise floor (the load plainly did not happen the way
    /// we think), or when `physicalMemory` differs from the recorded one
    /// (different machine, or a copied profile).
    ///
    /// ⚠️ Since unload-before-load became unconditional, the first of those
    /// discards is the common case: any boot that evicted another model bumped
    /// `residencyEpoch`, and the memory delta would net that model's release
    /// against this one's load. So a hold is learned only on a boot with nothing
    /// else resident. That is correct, and it is pinned by a test rather than
    /// left as an argument.
    private func recordObservation(
        _ ticket: Ticket, attributionIsOurs: Bool, availableAtHealthy: UInt64,
        physicalBytes: UInt64
    ) {
        guard attributionIsOurs else { return }
        guard ticket.availableAtAdmission > availableAtHealthy else { return }
        let hold = ticket.availableAtAdmission - availableAtHealthy
        guard hold >= (1 << 30) else { return }
        loadObservationsIfNeeded()
        observations[ticket.modelID] = ModelObservation(
            modelID: ticket.modelID, holdBytes: hold, observedAt: now(),
            physicalBytes: physicalBytes)
        saveObservations()
    }

    // ⚠️ There is deliberately NO `abandon(_:)` here. It existed, it read well,
    // and it was dead: both managers give the ticket back through
    // `releaseFlightTicket(healthy:)` -> `admitted(_:healthy: false)`, which
    // performs the identical release (clear `inFlight`, drop the flock, bump
    // `generation`) and simply books no residency. A second entry point for
    // "give the slot back" is a second place for the release rules to drift,
    // and dead public API that LOOKS load-bearing is worse than none — the
    // failure it guards against would be discovered by reading a method nothing
    // calls. One home: `admitted(_:healthy:)`.

    /// Read-only view of the current flight ticket, for tests and for the
    /// residency read.
    public func currentInFlight() -> Ticket? { reclaimedInFlight() }

    // MARK: - Jobs
    //
    // Jobs are keyed by the sidecar's own job id, not counted. A counter breaks
    // on exactly the traffic this gets: `ai.generationStatus` is polled in a loop
    // and every poll after the first sees the same terminal state, so a
    // decrementing counter would run negative and un-protect a model that is
    // still rendering. A set is idempotent by construction — repeated ends are
    // no-ops, and so are repeated starts.
    //
    // ⚠️⚠️ **F8 — `activeJobs > 0` is an ABSOLUTE veto on eviction.** It is now
    // the most important guard in the feature: an idle timer that fired during a
    // long generation would be far worse than the leaked memory it replaces.
    // The veto is enforced in three places, and all three are deliberate:
    //   1. the pure planner skips busy models and lists them in `protectedByJobs`;
    //   2. `scheduleIdleUnloadIfNeeded` refuses to arm while a job is open;
    //   3. `idleUnloadFired` re-checks after waking, because the actor is
    //      reentrant across the sleep and a job can start while it is suspended.
    // (2) without (3) is a race; (3) without (2) is a wake-up that exists only to
    // decline. `policy.jobLeaseSeconds` is the backstop for a job nobody ended.

    /// Opens a job against a resident model. `jobID` is the sidecar's own id.
    public func noteJobStarted(_ id: ModelID, jobID: String) {
        guard var record = residents[id] else { return }
        guard record.jobs[jobID] == nil else { return }
        record.jobs[jobID] = now()
        residents[id] = record
        generation &+= 1
        // A model with work on it must not be sitting on an armed idle timer.
        cancelIdleUnload(id)
    }

    /// Closes a job. Idempotent: a second call for the same id changes nothing.
    public func noteJobEnded(_ id: ModelID, jobID: String) {
        guard var record = residents[id] else { return }
        guard record.jobs.removeValue(forKey: jobID) != nil else { return }
        record.lastJobEndedAt = now()
        residents[id] = record
        generation &+= 1
        scheduleIdleUnloadIfNeeded(id)
    }

    /// Open job ids for a model, for the residency read and for tests.
    public func openJobIDs(_ id: ModelID) -> [String] {
        guard let record = residents[id] else { return [] }
        let moment = now()
        return record.jobs
            .filter { moment.timeIntervalSince($0.value) <= policy.jobLeaseSeconds }
            .keys.sorted()
    }

    // MARK: - Idle unload (SHIPPED ON — user decision 2026-08-05)
    //
    // ⚠️⚠️ **F23 IS INVERTED, NOT RESURRECTED.** An earlier pass shipped this off
    // and its comment here said there was deliberately no scheduling code. The
    // user reversed that after describing that they kill the ACE sidecar by hand:
    // *"still good to clean it up"*. F23's actual content — that an "off" model
    // must be GENUINELY INERT, with no `Task` created, no sleep pending and no
    // deadline stored, rather than a timer with a huge interval or one that fires
    // and declines to act — still binds, and RVC ships `nil` so that polarity is
    // live in the product and not only in a fixture.

    /// Arms (or re-arms) the single idle wake-up for a model.
    ///
    /// Called when a model becomes resident and when its last job ends. Always
    /// cancels first: two `noteJobEnded` calls must leave ONE pending wake-up,
    /// not two racing ones.
    private func scheduleIdleUnloadIfNeeded(_ id: ModelID) {
        cancelIdleUnload(id)
        guard let record = residents[id] else { return }
        guard let seconds = record.descriptor.idleUnloadSeconds, seconds > 0 else { return }
        // F8 veto, first of three.
        guard record.activeJobs(now: now(), leaseSeconds: policy.jobLeaseSeconds) == 0 else {
            return
        }
        let deadline = now().addingTimeInterval(seconds)
        idleDeadlines[id] = deadline
        idleWakeUpsScheduled &+= 1
        idleEpochCounter &+= 1
        let epoch = idleEpochCounter
        idleEpochs[id] = epoch
        // The sleep runs HERE rather than inside an actor-isolated method, and
        // the actor is re-entered only once there is a decision to make — with
        // every re-check (epoch, F8) still inside the actor.
        //
        // ⚠️ HONEST PROVENANCE: moving the sleep out of the actor (and switching
        // `Task {}` -> `Task.detached`) were both attempts to fix the
        // cancellation crash described on `cancelIdleUnload`, and NEITHER
        // changed it. They are kept purely on their own merits — an actor method
        // should not sit suspended for ten minutes, and a background timer has no
        // business inheriting the task-locals of whichever caller happened to arm
        // it. Do not read them as the fix, and do not assume reverting them is
        // safe just because they did not fix that crash.
        //
        // ⚠️ `ModelLifecycleCommandTests` arms a genuine 600 s timer (the default
        // `Task.sleep`, not a `SleepGate`) precisely so this path stops being the
        // one no test executes — which is how the crash stayed invisible.
        let sleep = sleepSeconds
        idleTasks[id] = Task.detached { [weak self] in
            await sleep(seconds)
            // Cancelled means a job started, or the model was already unloaded.
            guard !Task.isCancelled else { return }
            guard let self else { return }
            await self.idleDeadlineReached(id, epoch: epoch)
        }
    }

    /// Disarms the idle wake-up **by revoking its epoch, never by cancelling it.**
    ///
    /// ⚠️⚠️ **DO NOT ADD `.cancel()` BACK.** MEASURED, deterministically (3/3 runs,
    /// four different structural variants of the surrounding code): cancelling a
    /// timer task while it is suspended in the real `Task.sleep` aborts the
    /// process out of the Swift concurrency runtime —
    ///
    ///     freed pointer was not the last allocation
    ///     swift_task_dealloc
    ///     closure #1 in ModelLifecycleCoordinator.scheduleIdleUnloadIfNeeded
    ///     thunk for @escaping @isolated(any) @callee_guaranteed @async …
    ///     completeTaskWithClosure
    ///
    /// ⚠️ **The root cause is UNEXPLAINED.** It is a runtime-level fault, not
    /// something in this file's logic, and a standalone Swift 6 program of the
    /// same shape does NOT reproduce it. What is established is narrow and
    /// empirical: *this* build (package Swift 6 + `-enable-testing`, under the
    /// swift-testing runner) aborts when such a task is cancelled. Do not treat
    /// the mechanism as understood, and do not "simplify" this back.
    ///
    /// Dropping the task handle without cancelling is safe **because the epoch
    /// already does this job** — that is what it was built for. The orphaned task
    /// sleeps out its remaining time, wakes, and `idleEpochs[id] == epoch` fails
    /// (the entry is gone, so `nil == epoch` is false), so it returns without
    /// touching anything. It holds only `[weak self]` and a `Double`.
    ///
    /// ⚠️ This path is FREQUENT, not rare: `noteJobStarted` disarms a live timer,
    /// so every generation start on a resident model runs it.
    private func cancelIdleUnload(_ id: ModelID) {
        idleTasks.removeValue(forKey: id)
        idleDeadlines[id] = nil
        idleEpochs[id] = nil
    }

    /// The wake-up, re-entering the actor once the sleep is already over.
    ///
    /// ⚠️ Everything here is re-checked rather than assumed: the sleep happened
    /// OUTSIDE the actor (see `scheduleIdleUnloadIfNeeded` for why it must stay
    /// there), so by the time this runs the world has had ten minutes to move —
    /// a job may have opened, the model may already be gone, or the wake-up may
    /// have been cancelled and re-armed.
    private func idleDeadlineReached(_ id: ModelID, epoch: UInt64) async {
        guard !Task.isCancelled else { return }
        // Only act if we are still the armed wake-up. An epoch, not "is the slot
        // non-nil": a cancel-and-re-arm across the sleep leaves a DIFFERENT task
        // in the slot, and a nil check would happily let this stale one fire.
        guard idleEpochs[id] == epoch else { return }
        idleTasks[id] = nil
        idleDeadlines[id] = nil
        idleEpochs[id] = nil
        // F8 veto, third of three — re-checked after the suspension because the
        // actor is reentrant across it and the world moves.
        guard Self.idleEvictionIsSafe(
            activeJobs: residents[id]?.activeJobs(
                now: now(), leaseSeconds: policy.jobLeaseSeconds),
            bootInFlightForThisModel: inFlight?.modelID == id)
        else { return }
        _ = await performEviction(id, reason: .idleTimeout)
    }

    /// PURE. May a woken idle timer actually evict?
    ///
    /// `activeJobs == nil` means the model is no longer resident — somebody
    /// already unloaded it, and there is nothing to do.
    ///
    /// Split out so both polarities are pinnable without racing a timer: the
    /// integration test can only reach the cancellation route (opening a job
    /// cancels the pending wake-up, which is the correct behaviour), so the
    /// belt-and-braces re-check would otherwise be asserted by nothing.
    static func idleEvictionIsSafe(activeJobs: Int?, bootInFlightForThisModel: Bool) -> Bool {
        guard let activeJobs else { return false }
        return activeJobs == 0 && !bootInFlightForThisModel
    }

    /// Models with an armed idle wake-up, and when each fires. The observable
    /// half of "is the ten-minute timer actually running?"
    public func pendingIdleUnloads() -> [ModelID: Date] { idleDeadlines }

    /// Cumulative wake-ups ever scheduled by this coordinator.
    ///
    /// ⚠️ Reported ALONGSIDE `pendingIdleUnloads()` on purpose: "exactly one
    /// wake-up" is ambiguous between cumulative and pending, and
    /// cancel-and-reschedule moves the two differently. A test that checks only
    /// one of them cannot tell an armed timer from a churning one.
    public func idleWakeUpsEverScheduled() -> UInt64 { idleWakeUpsScheduled }

    // MARK: - Unload

    public func unload(_ id: ModelID, reason: EvictionReason = .explicit) async -> EvictionReport {
        await performEviction(id, reason: reason)
    }

    public func unloadAll(reason: EvictionReason = .explicit) async -> [EvictionReport] {
        var reports: [EvictionReport] = []
        for id in registeredModelIDs() where evictors[id] != nil {
            reports.append(await performEviction(id, reason: reason))
        }
        return reports
    }

    /// ⭐ **The quit path.** Unloads every registered model, whether or not this
    /// coordinator ever booted it — a sidecar started by hand, or one that
    /// outlived a previous app run, is exactly the ~80 GB the user was reclaiming
    /// manually, and `performEviction` reaches it through the manager's real stop
    /// path rather than through `residents`.
    ///
    /// ⚠️ **The caller must actually BLOCK on this.** A bare `Task { await … }`
    /// fired from `applicationWillTerminate` is a silent no-op: the notification
    /// runs inside `NSApplication.terminate:` and the process exits before the
    /// task is ever scheduled, so the "cleanup" never happens and nothing reports
    /// that it didn't.
    ///
    /// ⚠️ **CORRECTED 2026-08-05 — this comment previously described a mechanism
    /// that was never built**, claiming `DAWProApp` bridged through
    /// `applicationShouldTerminate` → `.terminateLater`. It does not. The actual
    /// shape (`DAWProApp.swift:2648-2675`) is a `Task.detached` plus a
    /// `DispatchSemaphore` the main thread waits on, bounded by
    /// `policy.shutdownUnloadTimeoutSeconds` so a wedged sidecar cannot hold Cmd-Q
    /// hostage. The delegate route was considered and rejected there, with
    /// reasons. Both shapes satisfy the "must block" rule above — which is the
    /// part that matters — but a doc comment naming the wrong one sends the next
    /// reader looking for an app delegate that does not exist.
    public func shutdown() async -> [EvictionReport] {
        for id in idleTasks.keys { cancelIdleUnload(id) }
        return await unloadAll(reason: .shutdown)
    }

    /// The ONE eviction path. Used by `unload` and by `commitAdmission`, so an
    /// eviction performed to make room and one performed on request cannot
    /// diverge.
    private func performEviction(_ id: ModelID, reason: EvictionReason) async -> EvictionReport {
        let generationBefore = generation
        let before = sampleMemory()
        let expected = residents[id]?.holdBytes

        guard let evictor = evictors[id] else {
            generation &+= 1
            return EvictionReport(
                modelID: id, reason: reason, stopped: false,
                detail: "No evictor is registered for model id \"\(id.rawValue)\" — valid ids are: "
                    + registeredModelIDs().map(\.rawValue).joined(separator: ", ") + ".",
                evidence: EvictionEvidence(
                    portFree: false, portLookupDetail: "no evictor registered",
                    probeUnreachable: false, treePidsAliveAfter: [],
                    availableBeforeBytes: before.availableBytes,
                    availableAfterBytes: before.availableBytes, memoryReturnedBytes: 0,
                    memoryVerdict: .inconclusive, expectedHoldBytes: expected,
                    generationBefore: generationBefore, generationAfter: generation))
        }

        let stopEvidence: ModelStopEvidence
        do {
            stopEvidence = try await evictor.evictWithoutCoordinator()
        } catch {
            // A thrown stop is a FAILED stop, and every authority limb stays
            // false. Never a success-shaped report for a stop that did not stop.
            stopEvidence = ModelStopEvidence(
                portFree: false, portLookupDetail: "the stop itself failed",
                probeUnreachable: false, treePidsAliveAfter: [],
                detail: error.localizedDescription)
        }
        let detail = stopEvidence.detail

        // ⚠️ No settle wait on the quit path. The delay exists so the memory
        // verdict is measured after the pages come back — and nobody reads a
        // memory verdict from a process that is exiting, while the app's quit is
        // blocked on this returning.
        if settleSeconds > 0, reason != .shutdown {
            try? await Task.sleep(nanoseconds: UInt64(settleSeconds * 1_000_000_000))
        }
        let after = sampleMemory()
        let returned = Int64(after.availableBytes) - Int64(before.availableBytes)

        if stopEvidence.stopped, residents[id] != nil {
            residents[id] = nil
            residencyEpoch &+= 1
        }
        // A model that is gone has nothing to idle-unload; a model that refused
        // to stop should not keep an armed timer that would re-attempt on its
        // own schedule, because the explicit verb already reported the failure.
        cancelIdleUnload(id)
        // Clearing rule (c): any stop of a model ends its tracked boot.
        if let ticket = inFlight, ticket.modelID == id {
            inFlight = nil
            releaseFlightLock()
        }
        generation &+= 1
        appendDiagnosticRow(modelID: id, phase: "evict", memory: after, treeUsage: nil)

        return EvictionReport(
            modelID: id, reason: reason, stopped: stopEvidence.stopped, detail: detail,
            evidence: EvictionEvidence(
                portFree: stopEvidence.portFree,
                portLookupDetail: stopEvidence.portLookupDetail,
                probeUnreachable: stopEvidence.probeUnreachable,
                treePidsAliveAfter: stopEvidence.treePidsAliveAfter,
                availableBeforeBytes: before.availableBytes,
                availableAfterBytes: after.availableBytes,
                memoryReturnedBytes: returned,
                memoryVerdict: Self.memoryVerdict(
                    returnedBytes: returned, expectedHoldBytes: expected),
                expectedHoldBytes: expected,
                generationBefore: generationBefore,
                generationAfter: generation))
    }

    /// PURE. The 1 GiB noise floor and the 0.5 factor are grounded in the
    /// measured post-kill deltas (−0.07 GB / +0.12 GB for the two real holds;
    /// −2.13 GB for the file case where the cache correctly stayed warm).
    static func memoryVerdict(returnedBytes: Int64, expectedHoldBytes: UInt64?) -> MemoryVerdict {
        let noiseFloor: Int64 = 1 << 30
        guard let expected = expectedHoldBytes else { return .inconclusive }
        if expected < UInt64(noiseFloor) { return .notAHold }
        if returnedBytes < noiseFloor { return .inconclusive }
        return returnedBytes >= Int64(expected / 2) ? .returned : .partial
    }

    // MARK: - The residency read (scope item ④)

    /// ⚠️ `includeProcessDetail` defaults **false** because the tree figures come
    /// from `SidecarProcessDiscovery.captureSnapshot()`, which forks `/bin/ps`
    /// — tens of milliseconds. The moment someone puts "resident model" in a
    /// status bar, a 1 Hz poll would fork `ps` once a second forever. `memory` is
    /// always fresh: `ModelMemory.sample()` is one mach trap and costs nothing.
    public func residency(includeProcessDetail: Bool = false) -> ResidencyReport {
        let memory = sampleMemory()
        var snapshot: SidecarProcessDiscovery.Snapshot?
        var snapshotAge: Int?
        if includeProcessDetail {
            snapshot = SidecarProcessDiscovery.captureSnapshot()
            cachedProcessSnapshot = snapshot
            cachedProcessSnapshotAt = now()
        } else if let cached = cachedProcessSnapshot {
            snapshot = cached
            snapshotAge = cachedProcessSnapshotAt.map {
                max(0, Int(now().timeIntervalSince($0).rounded()))
            }
        }

        let holder = reclaimedInFlight()
        let moment = now()
        loadObservationsIfNeeded()
        let models = registeredModelIDs().compactMap { id -> ModelResidencySummary? in
            guard let descriptor = descriptors[id] else { return nil }
            let record = residents[id]
            let requirement = ModelRegistry.requirement(
                for: descriptor, observation: observations[id],
                physicalBytes: memory.physicalBytes)
            let dry = plan(for: descriptor)
            var tree: ModelMemory.TreeUsage?
            if let snapshot, let pid = record?.rootPid {
                tree = ModelMemory.treeUsage(rootPid: pid, snapshot: snapshot)
            }
            let port = SidecarProcessDiscovery.port(of: descriptor.baseURL)
            // Asking the machine instead of the bookkeeping, and only when the
            // caller accepted the fork cost — this is an `lsof` per model.
            var portBusy: Bool?
            if includeProcessDetail, let port {
                switch SidecarProcessDiscovery.listeners(onPort: port) {
                case .listeners: portBusy = true
                case .nothingListening: portBusy = false
                case .unavailable: portBusy = nil   // "could not ask" is not "nothing" (m23-az-1)
                }
            }
            return ModelResidencySummary(
                modelID: id,
                displayName: descriptor.displayName,
                port: port.map(Int.init),
                resident: record != nil,
                holdBytes: record?.holdBytes ?? requirement.bytes,
                holdConfidence: record?.holdConfidence ?? requirement.confidence,
                holdProvenance: requirement.provenance,
                estimatedHoldBytes: descriptor.estimatedHoldBytes,
                activeJobs: record?.activeJobs(
                    now: moment, leaseSeconds: policy.jobLeaseSeconds) ?? 0,
                admittedAt: record?.admittedAt,
                idleForSeconds: record?.lastJobEndedAt.map {
                    max(0, Int(moment.timeIntervalSince($0).rounded()))
                },
                idleUnloadSeconds: descriptor.idleUnloadSeconds,
                idleUnloadAt: idleDeadlines[id],
                nextBootWouldUnload: dry.evicting,
                nextBootProtectedByJobs: dry.protectedByJobs,
                nextBootPlan: ModelAdmission.message(
                    for: dry, descriptor: descriptor, generation: generation),
                treeFootprintBytes: tree?.footprintBytes,
                treeResidentBytes: tree?.residentBytes,
                pids: tree?.pids,
                portBusy: portBusy)
        }

        return ResidencyReport(
            generation: generation,
            sampledAt: memory.sampledAt,
            memory: memory,
            policy: policy,
            inFlight: holder.map {
                InFlightSummary(
                    modelID: $0.modelID,
                    displayName: descriptors[$0.modelID]?.displayName ?? $0.modelID.rawValue,
                    seconds: max(0, Int(now().timeIntervalSince($0.mintedAt).rounded())),
                    ticket: $0.value,
                    pid: $0.pid)
            },
            models: models,
            processDetailAgeSeconds: snapshotAge)
    }

    private func treeUsage(rootPid: Int32) -> ModelMemory.TreeUsage {
        let snapshot = cachedProcessSnapshot ?? SidecarProcessDiscovery.captureSnapshot()
        return ModelMemory.treeUsage(rootPid: rootPid, snapshot: snapshot)
    }

    // MARK: - Learned observations (§2.3) — persistence

    /// Test/inspection accessor.
    public func observation(for id: ModelID) -> ModelObservation? {
        loadObservationsIfNeeded()
        return observations[id]
    }

    private var resolvedStorageDirectory: URL? {
        storageDirectory ?? AppDirectories.applicationSupport(.modelLifecycle)
    }

    private func loadObservationsIfNeeded() {
        guard !observationsLoaded else { return }
        observationsLoaded = true
        guard let url = resolvedStorageDirectory?.appendingPathComponent("observations.json"),
              let data = try? Data(contentsOf: url),
              let rows = try? Self.makeDecoder().decode([ModelObservation].self, from: data)
        else { return }
        for row in rows { observations[row.modelID] = row }
    }

    private func saveObservations() {
        guard let directory = resolvedStorageDirectory else { return }
        let rows = observations.values.sorted { $0.modelID.rawValue < $1.modelID.rawValue }
        guard let data = try? Self.makeEncoder().encode(rows) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: directory.appendingPathComponent("observations.json"), options: .atomic)
    }

    // MARK: - The §7.4 one-shot diagnostic
    //
    // Every admission and eviction writes a full row — all nine memory counters
    // plus tree attribution — so the FIRST real ACE boot answers, from data and
    // without a special session: is the hold in `internalBytes` (a real hold) or
    // `externalBytes` (reclaimable cache)? Does `treeFootprintBytes`
    // under-report the way the measured 4 GiB file mapping did? And what is the
    // true `observedHoldBytes` that replaces the seeded figure?

    private struct DiagnosticRow: Codable {
        var modelID: ModelID
        var phase: String
        var generation: UInt64
        var memory: ModelMemory.Snapshot
        var tree: ModelMemory.TreeUsage?
        var wallClock: Date
    }

    /// Rotate rather than grow forever. One rotation is enough: the interesting
    /// rows are always the most recent boot's.
    private static let diagnosticsByteCap = 4 << 20

    private func appendDiagnosticRow(
        modelID: ModelID, phase: String, memory: ModelMemory.Snapshot,
        treeUsage: ModelMemory.TreeUsage?
    ) {
        // ⚠️ A coordinator with nothing registered writes NOTHING, ever. That is
        // what makes the process-wide `shared` instance safe for the many tests
        // that construct a `CommandRouter` or a `SidecarManager` without ever
        // registering a model: without this guard they would each drop rows into
        // the user's Application Support directory (F2's cousin).
        guard !descriptors.isEmpty else { return }
        guard let directory = resolvedStorageDirectory else { return }
        let row = DiagnosticRow(
            modelID: modelID, phase: phase, generation: generation, memory: memory,
            tree: treeUsage, wallClock: now())
        guard var data = try? Self.makeEncoder().encode(row) else { return }
        data.append(0x0A)
        let url = directory.appendingPathComponent("diagnostics.jsonl")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > Self.diagnosticsByteCap {
            let rotated = directory.appendingPathComponent("diagnostics.1.jsonl")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: url, to: rotated)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Cross-process single-flight (§4.2)
    //
    // ⚠️ THE LOCK RESOLVES UNDER `DAWPRO_PROFILE_ROOT` (m23-ay), so a STAGING
    // instance gets its OWN lock and cannot serialise against the user's live
    // app. That is DELIBERATE — a single global lock would make every gate run
    // block on whatever the user happens to be doing. Do not "fix" it into a
    // machine-wide lock.
    //
    // `flock` and not a pidfile: the kernel releases a `flock` when the fd
    // closes or the process dies, so a crashed app cannot wedge model loading
    // forever. A pidfile would.

    /// Returns nil on success, or a description of the holder on failure.
    private func acquireFlightLock(ticket: Ticket) -> String? {
        guard let directory = resolvedStorageDirectory else { return nil }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("flight.lock").path
        let descriptor = open(path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { return nil }   // fail OPEN: our own record
        if flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let holder = (try? String(contentsOfFile: path, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            close(descriptor)
            return holder?.isEmpty == false ? holder! : "another process holds the boot lock"
        }
        let record = "pid \(getpid()) loading \(ticket.modelID.rawValue) "
            + "(ticket \(ticket.value)) since \(ISO8601DateFormatter().string(from: ticket.mintedAt))"
        ftruncate(descriptor, 0)
        _ = record.withCString { write(descriptor, $0, strlen($0)) }
        lockDescriptor = descriptor
        return nil
    }

    private func releaseFlightLock() {
        guard let descriptor = lockDescriptor else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        lockDescriptor = nil
    }

    // MARK: - Coders
    //
    // Built per call, not held as `static let`: `JSONEncoder`/`JSONDecoder` are
    // not `Sendable`, so a static global of either is a hard error under Swift 6
    // strict concurrency. Both are cheap and neither is on a hot path.

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
