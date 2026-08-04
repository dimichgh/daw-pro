import DAWCore
import Foundation

/// m23-av — the in-flight prepare ledger's PURE state machine: which prepare
/// bodies have armed a deadline race and not yet published an outcome.
///
/// This fact has no other home in the tree. `status`/`effectStatus` hold the
/// PUBLISHED outcome and are main-actor-owned; `attempted`/`effectAttempted`
/// hold the idempotency key. None of them can say "a prepare for slot S has
/// been running for 47 s against a 10 s budget", and none of them can be read
/// at all while a plugin synchronously holds the main actor — which is exactly
/// when the question is worth asking.
///
/// EVIDENCE IN, VERDICT OUT. `arm` records only when the race started and what
/// budget it was armed against. `overdue` is computed in `entries(now:)` and
/// never stored, so this type is not a second publisher of the timeout outcome
/// (`DeadlineRace` resolves `.timedOut` off-main; the registry publishes
/// `status[id] = .failed("… timed out …")` when the actor is free again). Two
/// publishers of one outcome is the failure mode this shape exists to avoid.
///
/// All time is INJECTED (`MainActorLiveness` / `EngineWatchdog` discipline):
/// no sleeps, no wall clock, fully headless-testable.
struct AUPrepareLedgerState: Sendable {

    /// Which chain a prepare body belongs to. Half of the key, never
    /// decoration: instrument and effect prepares run on SEPARATE chains
    /// (`prepareChains` vs `effectPrepareChains`) and can therefore be in
    /// flight at the same instant for the SAME UUID.
    enum Slot: String, Sendable, CaseIterable {
        case instrument
        case effect
    }

    /// (kind, id) — NEVER id alone. See `Slot`.
    struct Key: Hashable, Sendable {
        let slot: Slot
        let id: UUID
    }

    /// What one arming recorded. A point-in-time snapshot of the EVENT, like a
    /// log line — written once, never updated, deleted at disarm. It is not a
    /// mirror of `attempted[id].component` any more than a log line is.
    struct Record: Sendable {
        let component: AudioUnitComponentID?
        let armedAt: Double
        let deadlineSeconds: Double
    }

    private var records: [Key: Record] = [:]

    init() {}

    /// Records that a prepare body for `(slot, id)` armed its race at `at`
    /// against a `deadlineSeconds` budget.
    ///
    /// ⚠️ REPLACES an existing record for the same key, and this DELIBERATELY
    /// DIVERGES from `MainActorLiveness.recordPing`, which keeps the OLDEST
    /// anchor. Do not "correct" it to match that precedent — the two answer
    /// different questions. There, later pings are queued BEHIND the first and
    /// keeping the oldest is what stops a wedge looking younger than it is.
    /// Here, `prepareChains` serialises prepare bodies per id, so arm/disarm
    /// is strictly nested and a replace can only happen if a record LEAKED.
    /// Keeping the oldest in that case would let one leak permanently mask
    /// every later prepare for that slot; replacing loses only the leak.
    mutating func arm(slot: Slot, id: UUID, component: AudioUnitComponentID?,
                      at armedAt: Double, deadlineSeconds: Double) {
        records[Key(slot: slot, id: id)] = Record(
            component: component, armedAt: armedAt, deadlineSeconds: deadlineSeconds)
    }

    /// Drops the record for `(slot, id)`. A no-op for a key that was never
    /// armed (or already disarmed) — publication must never depend on the
    /// ledger's state.
    mutating func disarm(slot: Slot, id: UUID) {
        records[Key(slot: slot, id: id)] = nil
    }

    /// Every armed-but-unpublished prepare as of `now`, with `overdue`
    /// DERIVED here and nowhere else.
    ///
    /// Sorted by `(slot, id)` on the WIRE spellings, so two reads diff
    /// positionally. A dictionary's iteration order is randomized per process
    /// and would make any diff nondeterministic.
    func entries(now: Double) -> [EngineAUPrepareStats.InFlightEntry] {
        records
            .map { key, record in
                let elapsed = now - record.armedAt
                return EngineAUPrepareStats.InFlightEntry(
                    slot: key.slot.rawValue,
                    id: key.id.uuidString,
                    component: record.component,
                    startedSecondsAgo: elapsed,
                    deadlineSeconds: record.deadlineSeconds,
                    overdue: elapsed > record.deadlineSeconds)
            }
            .sorted { ($0.slot, $0.id) < ($1.slot, $1.id) }
    }
}

/// m23-av — the `nonisolated`, lock-protected wrapper any thread may read
/// WITHOUT touching the main actor. That is the whole point: during a
/// main-actor wedge every other AU-prepare fact is unreachable.
///
/// @unchecked Sendable justification: the one mutable field, `state`, is read
/// and written ONLY while `lock` is held; `clock` is an immutable `@Sendable`
/// closure fixed at init. `NSLock` (not `Synchronization.Mutex`) because the
/// package's deployment floor is macOS 14 and `Mutex` is macOS 15+ — the
/// `DeadlineResumeGate` / `MainActorLivenessMonitor` precedent.
///
/// REAL-TIME SAFETY: the render thread NEVER touches this. Its readers are the
/// main actor (arm/disarm and the healthy `prepareStats()` read), the control
/// server's private dispatch queue, and tests. The render path reaches AU
/// state only through `HostedAUInstrument`'s captured blocks, which touch
/// neither `status` nor this ledger.
final class AUPrepareLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var state = AUPrepareLedgerState()
    private let clock: @Sendable () -> Double

    /// MACH UPTIME, not wall time, and the choice is load-bearing: mach uptime
    /// PAUSES across system sleep, so closing the lid mid-prepare cannot make
    /// a prepare look overdue by hours. This is the EngineWatchdog
    /// no-wall-time law. (Not gated by any test — a mutation to `Date()` would
    /// pass every leg; catching it needs a real system sleep. Stated here
    /// rather than hidden.)
    init(clock: @escaping @Sendable () -> Double = {
        Double(DispatchTime.now().uptimeNanoseconds) / 1e9
    }) {
        self.clock = clock
    }

    func arm(slot: AUPrepareLedgerState.Slot, id: UUID,
             component: AudioUnitComponentID?, deadlineSeconds: Double) {
        let now = clock()
        lock.lock()
        state.arm(slot: slot, id: id, component: component,
                  at: now, deadlineSeconds: deadlineSeconds)
        lock.unlock()
    }

    func disarm(slot: AUPrepareLedgerState.Slot, id: UUID) {
        lock.lock()
        state.disarm(slot: slot, id: id)
        lock.unlock()
    }

    /// The ONE read. The healthy path (`AUHostRegistry.prepareStats()`) and
    /// the wedged path (`ControlServer.wedgeIntercept`) both land here, so
    /// there is no second computation to diverge.
    func snapshot() -> [EngineAUPrepareStats.InFlightEntry] {
        let now = clock()
        lock.lock()
        defer { lock.unlock() }
        return state.entries(now: now)
    }

    /// Seconds of a `Duration`, exactly.
    ///
    /// ⚠️ NOT `Double(duration.components.seconds)`: that truncates, so a
    /// 200 ms budget becomes 0.0 and EVERY entry reads instantly overdue.
    /// The attoseconds term is the whole correctness of sub-second budgets.
    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }
}
