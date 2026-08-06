import Foundation

/// **What must happen before a model boots, and it is PURE** — m23-dl.
///
/// Deliberately the exact shape of `SidecarStopPlanner.swift`: read-only fact
/// gathering happens in the coordinator, the decision happens here with zero
/// I/O and zero actor state, and acting on it happens back in the coordinator.
///
/// ## ⚠️⚠️ THE MEMORY GATE WAS CUT — do not build it back
///
/// This file used to carry an admission *arithmetic*: measure the machine,
/// compare against a per-model hold requirement, and refuse the boot when it did
/// not fit. **The user removed that on 2026-08-05:**
///
/// > *"let's not check for memory then, let it fail if this happens, but still
/// > good to clean it up"*
///
/// So there is **no memory check, no refusal, no warning, no shortfall message,
/// no hard floor and no `force` flag** anywhere in the model lifecycle. If a
/// model does not fit, the boot fails the way it failed before this item
/// existed, and that is the accepted outcome. What is left is the *cleanup* the
/// user asked for, which is why this planner still exists at all:
///
/// 1. **Unload-before-load.** Before booting a model, every OTHER resident model
///    is unloaded — **unconditionally**, not because memory is short. This is
///    the user's own earlier wording: *"unload ACE once we are done with song
///    generation or when we attempt to load other model."*
/// 2. **Single-flight.** Two concurrent boots of the same model is still wrong,
///    and it is not a memory check, so it stays.
///
/// Anything that reintroduces "and only if it fits" is out of scope by the
/// user's explicit decision, not by oversight.
///
/// ## Mutual exclusion is a rule, not a table
///
/// There is no `ExclusionGroup` and no "large vs small" enum. Booting anything
/// evicts everything else that is evictable and idle. That survives a third
/// model without an edit, which a pairwise table does not.
public enum ModelAdmission {

    // MARK: - Vocabulary

    /// A model currently holding memory.
    public struct Resident: Sendable, Equatable {
        public var id: ModelID
        /// Carried so the plan's message can say *"stopping RVC voice conversion
        /// first"* without the pure planner reaching for a registry.
        public var displayName: String
        /// Corroboration only — what an unload of this model is expected to
        /// return. **It does not decide whether anything is evicted.**
        public var holdBytes: UInt64
        public var holdConfidence: HoldRequirement.Confidence
        public var isEvictable: Bool
        /// `> 0` ⇒ **never** evicted, and named in the plan's `protectedByJobs`
        /// so a skipped eviction explains itself. F8: this is the most important
        /// guard in the feature — unloading a model mid-generation would be far
        /// worse than the memory it reclaims.
        public var activeJobs: Int
        public var admittedAt: Date
        public var lastJobEndedAt: Date?

        public init(
            id: ModelID, displayName: String, holdBytes: UInt64,
            holdConfidence: HoldRequirement.Confidence = .estimated, isEvictable: Bool = true,
            activeJobs: Int = 0, admittedAt: Date = Date(), lastJobEndedAt: Date? = nil
        ) {
            self.id = id
            self.displayName = displayName
            self.holdBytes = holdBytes
            self.holdConfidence = holdConfidence
            self.isEvictable = isEvictable
            self.activeJobs = activeJobs
            self.admittedAt = admittedAt
            self.lastJobEndedAt = lastJobEndedAt
        }
    }

    /// The global single-flight holder (§4.2). GLOBAL, not per-model: per-model
    /// locks do not solve the problem the user named, because ACE and a second
    /// large model booting concurrently is the dangerous case and two per-model
    /// locks both succeed.
    public struct InFlight: Sendable, Equatable {
        public var id: ModelID
        public var displayName: String
        public var since: Date
        /// The m23-ah nonce for this boot.
        public var ticket: UInt64

        public init(id: ModelID, displayName: String, since: Date, ticket: UInt64) {
            self.id = id
            self.displayName = displayName
            self.since = since
            self.ticket = ticket
        }
    }

    /// Everything the decision reasons over. A value type — that is the point.
    ///
    /// ⚠️ **There is no `memory`, no `requirement`, no `policy` and no `force`
    /// field, and their absence is the scope cut made structural.** A planner
    /// that cannot see how much memory the machine has cannot grow a memory gate
    /// back by accident; someone would have to add the field first, and that
    /// edit is visible in review.
    public struct Facts: Sendable, Equatable {
        public var request: ModelDescriptor
        public var resident: [Resident]
        public var inFlight: InFlight?
        public var now: Date
        /// The coordinator's monotonic nonce at the moment the facts were
        /// gathered. Quoted in every message so a retry can be proven to be a
        /// NEW decision rather than a cached one (the m23-ah pattern).
        public var generation: UInt64

        public init(
            request: ModelDescriptor, resident: [Resident] = [], inFlight: InFlight? = nil,
            now: Date = Date(), generation: UInt64 = 0
        ) {
            self.request = request
            self.resident = resident
            self.inFlight = inFlight
            self.now = now
            self.generation = generation
        }
    }

    // MARK: - The verdict

    public enum Plan: Sendable, Equatable {
        /// Already up — `start()`'s existing early return. No-op.
        ///
        /// ⚠️ Mints NO ticket: there is nothing to boot and nothing to release,
        /// and a ticket minted here would leak a flight slot until the stale
        /// timer reclaimed it.
        case alreadyResident(ModelID)

        /// Boot it, having first unloaded `evicting` — which is **everything
        /// else that is resident, evictable and idle**, not a memory-derived
        /// subset. `protectedByJobs` lists what was left alone because a job is
        /// running on it (F8), so a skipped cleanup explains itself instead of
        /// looking like a bug.
        ///
        /// Both lists may be empty; an empty `evicting` is the normal single-
        /// model case, not a degenerate one.
        case admit(evicting: [EvictionOption], protectedByJobs: [EvictionOption])

        /// The one thing that can still stop a boot: another boot is already in
        /// flight. **Not a memory refusal** — nothing about this consults the
        /// machine — and there is no `force` that overrides it, because forcing a
        /// second concurrent load is exactly the double-load the guard exists to
        /// prevent.
        case bootInFlight(InFlight, seconds: Int)
    }

    /// A model we are stopping, or deliberately not stopping, and what that is
    /// worth — so the plan's message is data rather than prose assembled at a
    /// call site.
    public struct EvictionOption: Sendable, Equatable {
        public var id: ModelID
        public var displayName: String
        /// Corroboration figure only (see `HoldRequirement`).
        public var holdBytes: UInt64
        /// Number of jobs holding it, `0` when it is genuinely free to stop.
        public var activeJobs: Int

        public init(id: ModelID, displayName: String, holdBytes: UInt64, activeJobs: Int = 0) {
            self.id = id
            self.displayName = displayName
            self.holdBytes = holdBytes
            self.activeJobs = activeJobs
        }
    }

    // MARK: - THE DECISION (pure)

    /// ## Ordering — this order IS the design, not an implementation detail
    ///
    /// 1. `inFlight != nil` → `.bootInFlight`, **even for the same model**. Two
    ///    boots of one model is the double-load this item exists to prevent.
    /// 2. already resident → `.alreadyResident`.
    /// 3. otherwise → `.admit`, evicting every other resident that is evictable
    ///    and has `activeJobs == 0`, listing the rest as `protectedByJobs`.
    ///
    /// ⚠️ **Step 3 is unconditional and takes no measurement.** There is no
    /// "would it fit anyway" branch, because a boot is never blocked and so the
    /// answer could not change anything: the eviction is the *cleanup*, and the
    /// user asked for it to happen whenever another model loads.
    ///
    /// ⚠️ **A busy model is skipped, and the boot proceeds anyway.** Under the
    /// old design a protected model produced a refusal; now it produces a
    /// `protectedByJobs` entry and the boot goes ahead into whatever memory is
    /// left. That is the user's *"let it fail if this happens"* — and it is
    /// strictly better than the alternative, which is unloading a model in the
    /// middle of the user's render.
    public static func resolve(_ facts: Facts) -> Plan {
        if let inFlight = facts.inFlight {
            let seconds = max(0, Int(facts.now.timeIntervalSince(inFlight.since).rounded()))
            return .bootInFlight(inFlight, seconds: seconds)
        }

        if facts.resident.contains(where: { $0.id == facts.request.id }) {
            return .alreadyResident(facts.request.id)
        }

        let others = facts.resident.filter { $0.id != facts.request.id && $0.isEvictable }
        // Largest hold first, ties broken by id: purely so the plan is
        // deterministic and a test can assert on the exact list. Nothing depends
        // on the order any more — every candidate is taken.
        let ordering: (Resident, Resident) -> Bool = { first, second in
            first.holdBytes == second.holdBytes
                ? first.id.rawValue < second.id.rawValue
                : first.holdBytes > second.holdBytes
        }
        let evicting = others.filter { $0.activeJobs == 0 }.sorted(by: ordering)
        let blocked = others.filter { $0.activeJobs > 0 }.sorted(by: ordering)

        return .admit(
            evicting: evicting.map(Self.option(for:)),
            protectedByJobs: blocked.map(Self.option(for:)))
    }

    private static func option(for resident: Resident) -> EvictionOption {
        EvictionOption(
            id: resident.id, displayName: resident.displayName,
            holdBytes: resident.holdBytes, activeJobs: resident.activeJobs)
    }
}

// MARK: - Plan accessors

extension ModelAdmission.Plan {
    /// True for `.admit`; false for `.alreadyResident` (nothing to boot) and
    /// `.bootInFlight`.
    public var isAdmitted: Bool {
        if case .admit = self { return true }
        return false
    }

    /// The models this plan will unload before booting.
    public var evicting: [ModelID] {
        if case .admit(let evicting, _) = self { return evicting.map(\.id) }
        return []
    }

    /// The models left resident because a job is running on them (F8).
    public var protectedByJobs: [ModelID] {
        if case .admit(_, let blocked) = self { return blocked.map(\.id) }
        return []
    }

    public var inFlightHolder: ModelAdmission.InFlight? {
        if case .bootInFlight(let holder, _) = self { return holder }
        return nil
    }
}

// MARK: - Messages (pure)

extension ModelAdmission {

    /// The message for any plan.
    ///
    /// ⚠️ Every branch quotes the `generation` nonce. Two messages with the same
    /// generation describe the same world; an unload that did not bump it did
    /// not happen (m23-ah).
    public static func message(for plan: Plan, descriptor: ModelDescriptor, generation: UInt64)
        -> String
    {
        switch plan {
        case .alreadyResident:
            return "\(descriptor.displayName) is already loaded — nothing to do. "
                + "(decision generation \(generation))"

        case .admit(let evicting, let blocked):
            var text = "Loading \(descriptor.displayName)."
            for one in evicting {
                text += " Unloading \(one.displayName) first to free about "
                    + "\(ModelMemory.formatGB(one.holdBytes)) — DAW Pro keeps one local model "
                    + "loaded at a time."
            }
            for one in blocked {
                text += " \(one.displayName) is busy with \(one.activeJobs) "
                    + "job\(one.activeJobs == 1 ? "" : "s"), so it stays loaded and its "
                    + "~\(ModelMemory.formatGB(one.holdBytes)) is not freed; if the machine runs "
                    + "short of memory this load may fail."
            }
            return text + " (decision generation \(generation))"

        case .bootInFlight(let inFlight, let seconds):
            return inFlightMessage(inFlight, seconds: seconds, generation: generation)
        }
    }

    /// The single-flight message. Its own function because `commitAdmission`
    /// re-checks single-flight under the actor after the plan was resolved and
    /// needs to say the same thing.
    public static func inFlightMessage(
        _ inFlight: InFlight, seconds: Int, generation: UInt64
    ) -> String {
        "Another model is already loading: \(inFlight.displayName) "
            + "(\(seconds)s so far, ticket \(inFlight.ticket)). DAW Pro loads one model at a "
            + "time, so two large models can never land on this machine at once. Poll "
            + "ai.modelResidency and retry once it reports no boot in flight. "
            + "Decision generation \(generation)."
    }

    /// The m23-cy teaching-error pattern: name the valid ids in the failure.
    ///
    /// ⚠️ Reachable from `ai.modelUnload` and `ai.modelResidency`, **not** from
    /// the boot path. An unregistered model boots with no lifecycle bookkeeping
    /// and no cleanup rather than being refused — refusing there would be a gate,
    /// and there are no gates left.
    public static func unknownModelMessage(
        _ requested: String, valid: [ModelID], generation: UInt64
    ) -> String {
        "Unknown model id \"\(requested)\". Valid ids are: \(list(valid.map(\.rawValue))). "
            + "Decision generation \(generation)."
    }

    /// "a, b and c" — used for model-id lists in teaching errors.
    static func list(_ items: [String]) -> String {
        switch items.count {
        case 0: return "none"
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

// MARK: - Dry-run rendering

extension ModelAdmission.Plan {
    /// The dry-run line, in both polarities.
    ///
    /// ⚠️ **`launch` appears in EVERY branch**, admitted or not.
    /// `Tests/AIServicesTests/SidecarManagerTests.swift`'s existing dry-run test
    /// asserts the message contains `run.sh`, the resolved directory path, and
    /// `[dry-run]`; a branch that dropped the command line would break a test
    /// that has nothing to do with this feature.
    ///
    /// ⚠️⚠️ **A dry run must SAY it would unload the other model and must not
    /// unload it.** That split is F15 and it is now more dangerous than it was
    /// under the old design, not less: eviction used to happen only when memory
    /// was short (rare), and it is now the normal plan whenever a second model is
    /// resident. See `ModelLifecycleCoordinator`'s two-method rule.
    public func dryRunMessage(
        launch: String, descriptor: ModelDescriptor, generation: UInt64
    ) -> String {
        let detail = ModelAdmission.message(
            for: self, descriptor: descriptor, generation: generation)
        guard case .bootInFlight = self else {
            return "[dry-run] would spawn: \(launch) \u{2014} \(detail)"
        }
        return "[dry-run] would NOT spawn: \(launch) \u{2014} \(detail)"
    }
}
