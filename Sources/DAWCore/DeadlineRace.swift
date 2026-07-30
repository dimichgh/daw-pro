import Foundation

/// The result of racing a main-actor unit of work against a wall-clock
/// deadline. `error` carries whatever `work` threw; `Error` refines `Sendable`
/// in Swift 6, so the case does not weaken the enum's conformance.
public enum DeadlineOutcome<T: Sendable>: Sendable {
    case value(T)
    case error(any Error)
    case timedOut
}

/// A REAL deadline for main-actor work (m23-at).
///
/// The shape this replaces raced two `Task { @MainActor in … }` closures: the
/// work, and a `Task.sleep(for: timeout)` backstop. Both hops were main-actor
/// isolated, so the sleeper had to RE-ACQUIRE the main actor to fire — the
/// "timeout" was `timeout` PLUS an unbounded queueing delay behind whatever
/// was hogging the actor. That disables the guard in exactly the case it
/// exists for: a plugin that wedges the main actor (see the Surge XT wedge in
/// the project's AU-hosting lore) is precisely a main actor that cannot run
/// the timeout task. MEASURED under a full parallel test run: a GM AUSampler
/// prepare took 20–24 s against a 10 s wall and still "succeeded" ~75–80% of
/// the time, with elapsed time not predicting the outcome — a scheduling coin
/// flip, not a deadline.
///
/// Here the deadline runs on the cooperative pool (`Task.detached`) and never
/// touches the main actor, so it fires on wall time regardless of main-actor
/// contention. The work still runs `@MainActor`, because AU property access
/// must — that half was never the bug.
///
/// The tasks are UNSTRUCTURED on purpose (this half of the old design was
/// correct and is preserved): a stalled AU call is abandoned, never awaited,
/// so nothing downstream blocks past `timeout`. First resume wins. Because the
/// two resumers now run on DIFFERENT executors, the once-guard needs a real
/// lock — see `DeadlineResumeGate`.
public enum DeadlineRace {

    /// Races `work` against `timeout`.
    ///
    /// `nonisolated` is load-bearing, not decoration: arming must not itself
    /// require the main actor, or a caller (or a test) could not start the
    /// race while the actor is hogged — which is the entire scenario the
    /// deadline exists for.
    ///
    /// - Parameters:
    ///   - timeout: wall-clock budget. Real, not advisory.
    ///   - work: the main-actor-isolated work. Runs to completion even if the
    ///     deadline wins; its result is simply discarded.
    /// - Returns: `.value`/`.error` if `work` finished first, `.timedOut`
    ///   otherwise.
    nonisolated public static func run<T: Sendable>(
        timeout: Duration,
        _ work: @escaping @MainActor () async throws -> T
    ) async -> DeadlineOutcome<T> {
        await withCheckedContinuation { continuation in
            let gate = DeadlineResumeGate<T>(continuation)

            // Created FIRST so the work task can capture and cancel it.
            // Default priority deliberately: a deadline deprioritized under a
            // saturated cooperative pool is a new source of late firing.
            let deadline = Task.detached {
                do {
                    try await Task.sleep(for: timeout)
                } catch {
                    // Cancelled because the work already won. Returning here
                    // is REQUIRED: `try?` would swallow the CancellationError
                    // and fall through to resume `.timedOut`, which the gate
                    // would drop today but which would be a live bug the
                    // moment the gate stopped being a once-guard.
                    return
                }
                gate.resume(.timedOut)
            }

            Task { @MainActor in
                do {
                    let value = try await work()
                    gate.resume(.value(value))
                } catch {
                    gate.resume(.error(error))
                }
                deadline.cancel()
            }
        }
    }
}

/// Resumes a `CheckedContinuation` exactly once, from ANY executor.
///
/// @unchecked Sendable justification: the one mutable field, `continuation`,
/// is read and written ONLY while `lock` is held, and the take-and-clear in
/// `resume` is a single critical section — so at most one caller can ever
/// observe a non-nil continuation. Every other stored property is a `let` of a
/// Sendable type. `NSLock` (not `Synchronization.Mutex`) because the package's
/// deployment floor is macOS 14 and `Mutex` is macOS 15+; the precedent is
/// `DAWControl.MainActorLivenessMonitor`.
///
/// The resume happens OUTSIDE the lock on purpose: resuming a continuation can
/// synchronously run the awaiting task's next partial function on this thread,
/// and holding a lock across arbitrary resumed code is a deadlock hazard.
private final class DeadlineResumeGate<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<DeadlineOutcome<T>, Never>?

    init(_ continuation: CheckedContinuation<DeadlineOutcome<T>, Never>) {
        self.continuation = continuation
    }

    func resume(_ outcome: DeadlineOutcome<T>) {
        lock.lock()
        let claimed = continuation
        continuation = nil
        lock.unlock()
        claimed?.resume(returning: outcome)
    }
}
