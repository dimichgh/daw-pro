import DAWCore
import Foundation
import Testing

/// m23-at — `DeadlineRace` must be a REAL wall-clock deadline.
///
/// The defect this pins: the shape in `AUHostRegistry.raceAgainstTimeout`
/// (DELETED in m23-at — do not go looking for it) scheduled its timeout as
/// `Task { @MainActor in try? await
/// Task.sleep(for: timeout); … }`, so the sleeper had to RE-ACQUIRE the main
/// actor to fire. `.seconds(10)` therefore meant "10 s of sleep PLUS an
/// unbounded wait behind whatever is holding the actor" — and the guard's
/// whole purpose is to bound a plugin that is holding the actor.
///
/// Leg 1 (`timeoutFiresWhileMainActorIsHogged`) is the claim. Leg 2 exists so
/// that a primitive which ALWAYS times out cannot pass leg 1 and call itself
/// fixed. Both are mandatory.
///
/// Deliberately NOT `@MainActor`: every test here must arm the race from off
/// the main actor, which is also the property that makes leg 1 possible at
/// all.
///
/// `.serialized` is justified narrowly and is NOT the usual "quiet the
/// machine" reflex the repo has disproved elsewhere: leg 1 DELIBERATELY
/// starves the main actor, and legs 2–4 all need it. Serializing stops this
/// suite from poisoning itself. It does nothing about sibling suites, and is
/// not claimed to.
@Suite(.serialized)
struct DeadlineRaceTests {

    /// Cross-executor mailbox for the main-actor hog: a "spinning now" flag
    /// and the instant the spin actually ENDED. Both are needed —
    ///  · the flag stops leg 1 arming before the hog has been scheduled, which
    ///    would silently measure an UNCONTENDED actor (a pass for the wrong
    ///    reason);
    ///  · the end instant is what makes leg 1's bound RELATIVE and
    ///    self-validating: an arming that completed strictly before the spin
    ///    ended is, by construction, an arming a main-actor-bound deadline
    ///    could not have served.
    ///
    /// @unchecked Sendable: both fields are touched only under `lock`.
    private final class SpinWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var spinning = false
        private var ended: ContinuousClock.Instant?

        func markSpinning() {
            lock.lock(); spinning = true; lock.unlock()
        }

        func markEnded(_ instant: ContinuousClock.Instant) {
            lock.lock(); ended = instant; lock.unlock()
        }

        var isSpinning: Bool {
            lock.lock(); defer { lock.unlock() }
            return spinning
        }

        var endInstant: ContinuousClock.Instant? {
            lock.lock(); defer { lock.unlock() }
            return ended
        }
    }

    /// Holds the main actor for `duration` with a SYNCHRONOUS busy loop. It
    /// must be a spin, not `Task.sleep`: sleeping suspends and hands the actor
    /// back, which is the opposite of the condition under test.
    @MainActor
    private static func spinHoldingMainActor(for duration: Duration, window: SpinWindow) {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: duration)
        window.markSpinning()
        while clock.now < deadline { /* hold the actor, do not suspend */ }
        window.markEnded(clock.now)
    }

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1e18
    }

    // MARK: - Leg 1: the deadline fires while the main actor is hogged

    /// THE regression guard. A main-actor task spins for `hogDuration`; from a
    /// non-main task we arm races with a 200 ms budget and trivial work.
    ///
    /// The per-arming assertion is fully RELATIVE and needs no wall-clock
    /// constant: an arming counts only if it finished strictly INSIDE the hog
    /// window, and every counted arming must be `.timedOut`. A main-actor-
    /// bound deadline cannot produce a single such arming — measured, in a
    /// standalone harness that ran the old and new shapes side by side under
    /// an identical hog: old 0/6, new 6/6, old always returning `.value` at
    /// t ≈ the hog duration.
    ///
    /// The absolute budget-proximity check is stated on the MEDIAN, not on
    /// each arming, on purpose: one descheduled cooperative-pool thread under
    /// full-suite load can stretch a single arming without the deadline being
    /// main-actor-bound, and reddening on that would be a false alarm. The
    /// median still has full teeth against the defect — the broken shape's
    /// median sits at the hog duration, 5× the ceiling.
    ///
    /// One hog covers FOUR armings rather than one per iteration: N=12 costs
    /// ~3 s of main-actor starvation instead of ~12 s, which matters because
    /// this test runs inside a parallel suite whose siblings are mostly
    /// `@MainActor`-isolated. Iterations 2–4 of each round also skip the
    /// start-race handshake entirely — the actor is provably already held.
    @Test
    func timeoutFiresWhileMainActorIsHogged() async throws {
        let hogDuration = Duration.milliseconds(1_000)
        let budget = Duration.milliseconds(200)
        let medianCeiling = Duration.milliseconds(600)
        let requiredArmings = 10
        let armingsPerRound = 4
        let maxRounds = 8

        var elapsedInsideWindow: [Duration] = []
        var discarded = 0
        var round = 0
        let clock = ContinuousClock()

        while elapsedInsideWindow.count < requiredArmings && round < maxRounds {
            round += 1
            let window = SpinWindow()
            let hog = Task { @MainActor in
                Self.spinHoldingMainActor(for: hogDuration, window: window)
            }
            // Wait for the hog to actually be ON the actor. Polling sleeps run
            // on the cooperative pool, so this loop is not itself blocked by
            // the hog. The cap is generous because under full-suite load the
            // main actor is routinely unavailable for tens of seconds (the
            // very condition m23-at is about) — a tight cap here would fail
            // the test for the thing it is trying to prove.
            var waited = Duration.zero
            while !window.isSpinning && waited < .seconds(90) {
                try await Task.sleep(for: .milliseconds(1))
                waited += .milliseconds(1)
            }
            try #require(window.isSpinning, """
                the main-actor hog never started within 90 s, so leg 1 could not \
                be armed against a held actor. This is main-actor starvation from \
                SIBLING suites, not a DeadlineRace failure.
                """)

            var roundMeasurements: [(start: ContinuousClock.Instant,
                                      end: ContinuousClock.Instant,
                                      timedOut: Bool,
                                      describe: String)] = []
            for _ in 0..<armingsPerRound {
                let start = clock.now
                let outcome = await DeadlineRace.run(timeout: budget) { 7 }
                let end = clock.now
                let timedOut: Bool
                let describe: String
                switch outcome {
                case .timedOut: timedOut = true;  describe = "timedOut"
                case .value(let v): timedOut = false; describe = "value(\(v))"
                case .error(let e): timedOut = false; describe = "error(\(e))"
                }
                roundMeasurements.append((start, end, timedOut, describe))
            }
            _ = await hog.value

            let spinEnd = try #require(window.endInstant,
                                       "the hog finished without recording its end instant")
            for m in roundMeasurements {
                guard m.end < spinEnd else {
                    // The hog's 1 s spin expired before this arming completed,
                    // so it no longer proves anything about a HELD actor.
                    // Discard rather than assert — asserting on it would make
                    // the test measure pool scheduling, not the deadline.
                    discarded += 1
                    continue
                }
                elapsedInsideWindow.append(m.start.duration(to: m.end))
                #expect(m.timedOut, """
                    an arming that completed INSIDE the main-actor hog window returned \
                    \(m.describe) after \(m.start.duration(to: m.end)) against a \(budget) \
                    budget. Only a deadline that does not need the main actor can resolve \
                    inside that window, so this means the deadline is main-actor-bound \
                    again (m23-at).
                    """)
            }
        }

        let secs = elapsedInsideWindow.map(Self.seconds).sorted()
        print("[measured] m23-at leg 1: \(secs.count) armings inside the hog window "
              + "(\(discarded) discarded, \(round) rounds), budget 200 ms, hog 1000 ms — "
              + "elapsed s: " + secs.map { String(format: "%.3f", $0) }.joined(separator: ", "))

        try #require(elapsedInsideWindow.count >= requiredArmings, """
            only \(elapsedInsideWindow.count) of the required \(requiredArmings) armings \
            landed inside a hog window after \(round) rounds — the machine was too \
            starved to run the experiment, which is not the same as the experiment failing.
            """)
        let median = secs[secs.count / 2]
        #expect(median <= Self.seconds(medianCeiling), """
            median deadline latency \(median) s against a \(budget) budget \
            (ceiling \(medianCeiling)). Every arming still resolved inside the hog \
            window, so the deadline is not main-actor-bound — but it is far slower \
            than its budget.
            """)
    }

    // MARK: - Leg 2: the converse — uncontended work is NOT timed out

    /// Guards against the degenerate "fix" that satisfies leg 1 by always
    /// timing out: trivial main-actor work must actually return its value.
    ///
    /// The budget is 60 s and that number carries NO claim — it is not a
    /// latency assertion, it just has to be larger than the main-actor
    /// starvation this suite's siblings produce. Measured at 5 s it failed 5
    /// of 20 iterations inside a full parallel run, and those failures were
    /// CORRECT behaviour (the actor genuinely was unavailable for over 5 s;
    /// m23-ab-3 measured 20–24 s holds). A degenerate always-timeout
    /// primitive fails this leg at any budget, which is the only property
    /// leg 2 needs.
    @Test
    func uncontendedWorkReturnsItsValue() async throws {
        for iteration in 0..<20 {
            let outcome = await DeadlineRace.run(timeout: .seconds(60)) { iteration * 3 }
            switch outcome {
            case .value(let v):
                #expect(v == iteration * 3)
            case .timedOut:
                Issue.record("iteration \(iteration): trivial work timed out against a 60 s budget")
            case .error(let e):
                Issue.record("iteration \(iteration): unexpected error \(e)")
            }
        }
    }

    // MARK: - Leg 3: the once-gate holds across executors

    /// The two resumers now live on DIFFERENT executors, so the once-guard
    /// needs a real lock. This tests that lock the only way it can be tested:
    /// by aiming both resumers at the same instant, 100 times. A broken gate
    /// does not return a wrong value — `CheckedContinuation` TRAPS on the
    /// second resume and takes the whole test process down.
    ///
    /// Note that EVERY iteration is a genuine double-resume attempt regardless
    /// of who wins: only the DEADLINE task is cancelled when work wins, so the
    /// work task always runs to completion and always calls `gate.resume`,
    /// even after the deadline has already resumed the continuation. The
    /// alternating 40/60 ms work sleep against the 50 ms budget just makes
    /// sure both ORDERINGS are exercised rather than only the one this
    /// machine happens to favour.
    ///
    /// MEASURED, so nobody reads the printed split as a regression: isolated
    /// this is 50 value / 50 timedOut, exactly as the alternation intends —
    /// but under a full parallel run it collapses to 0 / 100, because the work
    /// task's hop onto a contended main actor costs more than the 10 ms the
    /// alternation is playing with. Both figures are correct and neither is
    /// asserted on. Under load the leg still tests what it is for (every
    /// iteration is a double-resume attempt), it just stops covering the
    /// work-wins ordering — that coverage comes from the isolated run.
    @Test
    func concurrentResumersNeverDoubleResume() async throws {
        var timedOut = 0
        var valued = 0
        for iteration in 0..<100 {
            let workSleep: Duration = iteration.isMultiple(of: 2)
                ? .milliseconds(40) : .milliseconds(60)
            let outcome = await DeadlineRace.run(timeout: .milliseconds(50)) {
                try await Task.sleep(for: workSleep)
                return true
            }
            switch outcome {
            case .timedOut: timedOut += 1
            case .value: valued += 1
            case .error(let e):
                // NOT a legal outcome: only the DEADLINE task is cancelled,
                // and an unstructured `Task {}` does not inherit cancellation,
                // so the work task's sleep can never throw. An error here
                // means something else broke.
                Issue.record("iteration \(iteration): unexpected error \(e)")
            }
        }
        // No expectation on the SPLIT — either side winning is correct, and
        // which one wins depends on machine load. The teeth are (a) reaching
        // this line at all, since a broken gate TRAPS, and (b) the count: all
        // 100 races must have resolved to one of the two legal outcomes.
        print("[measured] m23-at leg 3: 100 coincident races → \(valued) value / \(timedOut) timedOut")
        #expect(valued + timedOut == 100)
    }

    // MARK: - Leg 4: thrown errors surface as .error

    private struct Boom: Error, Equatable { let tag: String }

    @Test
    func thrownWorkSurfacesAsError() async throws {
        let outcome: DeadlineOutcome<Int> = await DeadlineRace.run(timeout: .seconds(60)) {
            throw Boom(tag: "m23-at")
        }
        switch outcome {
        case .error(let e):
            #expect(e as? Boom == Boom(tag: "m23-at"))
        case .value(let v):
            Issue.record("throwing work returned \(v)")
        case .timedOut:
            Issue.record("throwing work timed out against a 60 s budget")
        }
    }
}
