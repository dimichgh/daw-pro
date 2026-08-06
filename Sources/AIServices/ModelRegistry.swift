import Foundation

/// Which local model is which — m23-dl.
///
/// A `RawRepresentable` struct rather than an `enum` on purpose: a third model
/// (Music Flamingo, m23-dg) must be addable with **one** static member and no
/// exhaustive-switch fallout anywhere. Encodes as a bare string on the wire.
public struct ModelID: RawRepresentable, Codable, Sendable, Hashable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// The ACE-Step-1.5 song-generation sidecar (loopback 8001).
    public static let aceStep = ModelID(rawValue: "ace-step")
    /// The RVC voice-conversion sidecar (loopback 8002).
    public static let rvc = ModelID(rawValue: "rvc")
    // m23-dg adds `.musicFlamingo` HERE and nowhere else. If adding a model
    // requires an edit anywhere but this file and one `register(...)` call,
    // something has grown a pairwise special case — see `ModelAdmission`.
}

extension ModelID: CustomStringConvertible {
    public var description: String { rawValue }
}

/// How much memory a model needs, **and where that number came from**.
///
/// ⚠️⚠️ **THIS NUMBER DECIDES NOTHING (scope cut, 2026-08-05).** The user's
/// ruling was *"let's not check for memory then, let it fail if this happens,
/// but still good to clean it up"* — so there is no admission gate, nothing is
/// ever refused for memory, and `force` does not exist. The requirement's only
/// surviving job is **corroboration**: it is `EvictionEvidence.expectedHoldBytes`,
/// the yardstick `MemoryVerdict` uses to answer *"did the unload actually return
/// the memory?"* instead of guessing. A wrong figure here makes a verdict
/// `.partial` instead of `.returned`; it can no longer stop a boot, and it must
/// never be wired back into one.
///
/// The provenance survives with it, because a corroboration figure whose origin
/// the report hides is a number nobody can argue with: *"about 3.2 GB (estimated
/// from on-disk size; never measured resident)"* reads very differently from
/// *"about 80.0 GB (measured on this machine 2026-08-05)"*.
public struct HoldRequirement: Codable, Sendable, Equatable {

    /// Where a hold figure came from. **It labels a corroboration figure and
    /// gates nothing.** This enum lived on `ModelAdmission` while the planner
    /// reasoned about memory; it moved here when the planner stopped, so that no
    /// reader infers from its address that admission still consults it.
    public enum Confidence: String, Codable, Sendable, Equatable {
        /// Observed for THIS model — learned on this machine, or shipped as a
        /// seeded measurement.
        case measured
        /// Never observed; derived from on-disk size or a guess.
        case estimated
    }

    public var bytes: UInt64
    public var confidence: Confidence
    /// The clause a refusal/warning message drops in verbatim, e.g. "measured on
    /// this machine 2026-08-06" or "estimated from on-disk size, never measured
    /// resident on this machine".
    public var provenance: String
    /// When the measurement was taken; nil for an estimate.
    public var measuredAt: Date?

    public init(
        bytes: UInt64, confidence: Confidence, provenance: String,
        measuredAt: Date? = nil
    ) {
        self.bytes = bytes
        self.confidence = confidence
        self.provenance = provenance
        self.measuredAt = measuredAt
    }
}

/// One resident-model observation, learned on THIS machine (§2.3).
///
/// Persisted so it survives relaunch. `physicalBytes` is recorded so a profile
/// copied to a different machine cannot pass its learned figures off as local
/// measurements.
public struct ModelObservation: Codable, Sendable, Equatable {
    public var modelID: ModelID
    public var holdBytes: UInt64
    public var observedAt: Date
    public var physicalBytes: UInt64

    public init(modelID: ModelID, holdBytes: UInt64, observedAt: Date, physicalBytes: UInt64) {
        self.modelID = modelID
        self.holdBytes = holdBytes
        self.observedAt = observedAt
        self.physicalBytes = physicalBytes
    }
}

/// Everything the lifecycle manager needs to know about one model.
///
/// ⚠️ **No `stopVocabulary` field**, despite §3.2. Two reasons, both hard:
/// `SidecarStop.Vocabulary` is nested in an **internal** enum (so a `public`
/// descriptor cannot carry it) and it is not `Codable` (so `ModelDescriptor:
/// Codable` would not synthesise). It is also redundant — the registered
/// `ModelEvicting` is the thing that actually performs the stop, and a
/// descriptor carrying stop wording would be a second home for it.
public struct ModelDescriptor: Codable, Sendable, Equatable {
    public var id: ModelID
    /// User-facing, and it lands verbatim in refusal messages.
    public var displayName: String
    /// The sidecar's own base URL. **The port is derived from this**
    /// (`SidecarProcessDiscovery.port(of:)`) and hardcoded nowhere, which is how
    /// tests point a descriptor at an ephemeral port.
    public var baseURL: URL

    /// A hold that has been **measured for this model** and ships with the
    /// product. `nil` when nobody has ever measured it.
    ///
    /// ⭐ **Why this is separate from the learned observation store, and why the
    /// §2.3 `physicalMemory` discard rule does NOT apply to it.** §2.3's rule
    /// exists so a profile copied between machines cannot present another
    /// machine's *learned* figures as local measurements. A seeded figure is a
    /// different thing: a model's weights are the same size on every machine.
    /// The seed therefore survives on every machine; a machine-matched learned
    /// observation **overrides** it.
    public var seededHoldBytes: UInt64?
    /// Provenance clause for `seededHoldBytes`.
    public var seededHoldProvenance: String?

    /// The fallback when nothing has ever been measured. Corroboration only —
    /// like every other figure here, it cannot stop a boot.
    public var estimatedHoldBytes: UInt64
    public var estimatedHoldProvenance: String

    /// May this model be evicted to make room for another? A model in the middle
    /// of a user-visible job is protected by `activeJobs`, never by this flag.
    public var isEvictable: Bool

    /// Idle-unload seconds, or `nil` = **never**.
    ///
    /// ⚠️⚠️ **THE DEFAULT WAS REVERSED BY THE USER ON 2026-08-05.** An earlier
    /// pass shipped `nil` everywhere ("ship it off, decide later"); the user then
    /// described killing the ACE sidecar by hand and ruled *"still good to clean
    /// it up"*. So **ACE ships `600`** — ten idle minutes after a generation job
    /// reaches a terminal state, or after it boots and is never used. Do not
    /// re-file this as F23; F23 (an "off" state implemented as a dormant timer)
    /// is inverted, not resurrected.
    ///
    /// `nil` must still be **genuinely inert** — no `Task` created, no
    /// `Task.sleep` pending, no deadline stored, `noteJobEnded` schedules
    /// nothing. It does **not** mean a timer with a very large interval or
    /// `.greatestFiniteMagnitude`, and it does not mean a timer that fires and
    /// declines to act: a dormant timer is still a scheduled wake-up, still a
    /// cancellation path that can leak, and still a code path that can fire
    /// after the actor's state has moved on. RVC ships `nil`, so both polarities
    /// are live in the product and neither is only exercised by a test fixture.
    public var idleUnloadSeconds: Double?

    public init(
        id: ModelID, displayName: String, baseURL: URL, seededHoldBytes: UInt64? = nil,
        seededHoldProvenance: String? = nil, estimatedHoldBytes: UInt64,
        estimatedHoldProvenance: String, isEvictable: Bool = true,
        idleUnloadSeconds: Double? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.baseURL = baseURL
        self.seededHoldBytes = seededHoldBytes
        self.seededHoldProvenance = seededHoldProvenance
        self.estimatedHoldBytes = estimatedHoldBytes
        self.estimatedHoldProvenance = estimatedHoldProvenance
        self.isEvictable = isEvictable
        self.idleUnloadSeconds = idleUnloadSeconds
    }
}

/// The lifecycle knobs.
///
/// ⚠️ **`reserveBytes` and `hardFloorBytes` are GONE, deliberately.** They were
/// the admission arithmetic's headroom and its one refusal for an unmeasured
/// model. The user cut the memory gate on 2026-08-05, so both had no caller left;
/// they were removed rather than left looking load-bearing. Nothing here may grow
/// back into a boot-blocking threshold without the user saying so.
public struct ModelLifecyclePolicy: Codable, Sendable, Equatable {
    /// How long a boot may hold the global flight ticket before a **dead**-pid
    /// reclamation may take it back. A ticket whose pid is ALIVE is never
    /// reclaimed on a timer — that is the `kill -0`-on-a-zombie trap in a
    /// different costume.
    public var staleTicketSeconds: Double

    /// ⭐ **The self-heal for a job nobody ever ended.** `activeJobs > 0` is an
    /// absolute veto on eviction (F8), and jobs are opened by a submit verb and
    /// closed by whichever poll first observes a terminal state. A caller that
    /// submits and never polls would otherwise pin its model resident forever —
    /// idle unload would never schedule and unload-before-load would never fire,
    /// i.e. the cleanup this item exists for would silently stop happening.
    ///
    /// A job older than this stops counting toward the veto. One hour is far
    /// past any observed ACE-Step render (minutes, not tens of minutes) and far
    /// short of "forever", so the veto still protects every real job.
    public var jobLeaseSeconds: Double

    /// How long the app's quit path waits for the shutdown unload before giving
    /// up and letting the process exit. A wedged sidecar must not be able to
    /// block Cmd-Q.
    public var shutdownUnloadTimeoutSeconds: Double

    public init(
        staleTicketSeconds: Double = 120,
        jobLeaseSeconds: Double = 3600,
        shutdownUnloadTimeoutSeconds: Double = 10
    ) {
        self.staleTicketSeconds = staleTicketSeconds
        self.jobLeaseSeconds = jobLeaseSeconds
        self.shutdownUnloadTimeoutSeconds = shutdownUnloadTimeoutSeconds
    }
}

/// The shipped model descriptors, and the ONE home for the requirement lookup.
///
/// There is deliberately **no** `ExclusionGroup` and no "large vs small" enum.
/// Mutual exclusion is an *arithmetic consequence* — if two models do not fit,
/// one is evicted — which is the only formulation that survives a third model
/// without an edit. A table would need a new pairwise rule every time.
public enum ModelRegistry {

    /// ACE-Step's hold, **measured, not guessed** (§16.1). Two independent
    /// observations on 2026-08-05:
    ///
    /// | source | figure |
    /// |---|---|
    /// | the user's own memory monitor with ACE loaded | **80 GB** |
    /// | m23-ac-3e-2 teardown: `vm_stat` free pages `1,166,504 → 5,744,768` @ 16384 B | **+75.0 GB returned to FREE** |
    ///
    /// ⭐ **The teardown figure is what refutes the "it is mostly reclaimable
    /// page cache" hypothesis.** File-backed pages do **not** return to `free`
    /// when the mapping process dies (measured: a `SIGKILL`ed 4 GiB file-mmap
    /// child left `external` at 29.80 GB and `free` recovered nothing). So
    /// ≥75 GB *returning to free* means ≥75 GB was anonymous/wired — exactly the
    /// pages `usedBytes` counts. The hypothesis was reasonable and it was wrong.
    ///
    /// ⚠️ Since the scope cut this figure **blocks nothing**. It is the yardstick
    /// an unload's `MemoryVerdict` is measured against: 74.5 GiB =
    /// 79,993,765,888 B = **80.0 GB**, the user's own monitor reading, so
    /// "ACE unloaded and ~75 GB came back" is a checkable claim rather than a
    /// hope.
    public static let aceStepMeasuredHoldBytes: UInt64 = 79_993_765_888

    public static let aceStepHoldProvenance =
        "measured on this machine 2026-08-05, from two independent observations"

    /// RVC is a PLACEHOLDER and is flagged as such everywhere it is used: the
    /// whole `scripts/rvc` tree is 1.7 GB on disk and it is a small model, but
    /// nobody has measured its resident hold. `.estimated` ⇒ an unload's memory
    /// verdict against it is a weak claim, which is why the verdict names its
    /// provenance.
    public static let rvcEstimatedHoldBytes: UInt64 = 3 << 30

    /// ⭐ **Ten idle minutes, and it SHIPS ON for ACE** (user, 2026-08-05). The
    /// number is the user's own: they were killing the sidecar by hand because
    /// it holds ~80 GB, and ten minutes is long enough that a pause between two
    /// generations does not pay a ~60 s cold reload, short enough that walking
    /// away from the machine gives the memory back.
    public static let aceStepIdleUnloadSeconds: Double = 600

    public static func aceStep(baseURL: URL) -> ModelDescriptor {
        ModelDescriptor(
            id: .aceStep,
            displayName: "ACE-Step song generation",
            baseURL: baseURL,
            seededHoldBytes: aceStepMeasuredHoldBytes,
            seededHoldProvenance: aceStepHoldProvenance,
            // Deliberately the SAME figure as the seed. If the seed is ever
            // dropped, the warn path must not silently become a smaller,
            // friendlier number that admits an 80 GB model into 20 GB of RAM.
            estimatedHoldBytes: aceStepMeasuredHoldBytes,
            estimatedHoldProvenance:
                "estimated from ACE-Step's on-disk checkpoint tree; never measured resident",
            isEvictable: true,
            // ON. USER DECISION 2026-08-05, reversing the earlier "ship it off".
            idleUnloadSeconds: aceStepIdleUnloadSeconds)
    }

    public static func rvc(baseURL: URL) -> ModelDescriptor {
        ModelDescriptor(
            id: .rvc,
            displayName: "RVC voice conversion",
            baseURL: baseURL,
            seededHoldBytes: nil,
            seededHoldProvenance: nil,
            estimatedHoldBytes: rvcEstimatedHoldBytes,
            estimatedHoldProvenance:
                "estimated from the 1.7 GB on-disk RVC tree; never measured resident on this machine",
            isEvictable: true,
            // ⚠️ DELIBERATELY `nil`, and NOT a leftover of the withdrawn "ship it
            // off" default. RVC holds an estimated ~3 GB against ACE's measured
            // ~80 GB, and a voice-conversion reload costs the user a wait for
            // memory nobody was short of. It is still unloaded on quit and still
            // unloaded before another model boots — it just does not run a clock
            // of its own. This is also the shipped `nil` polarity the idle tests
            // pin, so "off" is proven inert on a real descriptor.
            idleUnloadSeconds: nil)
    }

    /// PURE. The ONE home for *"what does this model need, and how do we know?"*
    ///
    /// Precedence: a learned observation for **this** machine beats the shipped
    /// seed, which beats the estimate. Writing the `??` chain a second time
    /// anywhere else is how the message and the decision start disagreeing.
    public static func requirement(
        for descriptor: ModelDescriptor, observation: ModelObservation?, physicalBytes: UInt64
    ) -> HoldRequirement {
        if let observation, observation.modelID == descriptor.id,
           // §2.3: a figure learned on a different machine is not a measurement
           // of THIS one.
           observation.physicalBytes == physicalBytes,
           observation.holdBytes > 0 {
            return HoldRequirement(
                bytes: observation.holdBytes,
                confidence: .measured,
                provenance: "measured on this machine "
                    + Self.provenanceDate(observation.observedAt),
                measuredAt: observation.observedAt)
        }
        if let seeded = descriptor.seededHoldBytes {
            return HoldRequirement(
                bytes: seeded,
                confidence: .measured,
                provenance: descriptor.seededHoldProvenance ?? "measured",
                measuredAt: nil)
        }
        return HoldRequirement(
            bytes: descriptor.estimatedHoldBytes,
            confidence: .estimated,
            provenance: descriptor.estimatedHoldProvenance,
            measuredAt: nil)
    }

    /// `2026-08-06`, UTC. Built from `Calendar` rather than a `DateFormatter`
    /// for two reasons: a `static let DateFormatter` is a non-`Sendable` global
    /// and does not compile under Swift 6 strict concurrency, and a localised
    /// date quoted inside a message that also carries byte figures reads as a
    /// different measurement to a reader in another locale.
    static func provenanceDate(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
