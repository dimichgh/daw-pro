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
    /// main-actor-bound, and reddening on that would be a false alarm.
    ///
    /// The median does NOT have teeth against the m23-at defect itself
    /// (m23-as-2c correction — a prior version of this comment claimed the
    /// opposite and was wrong, and it contradicted this file's own line
    /// above: "old always returning `.value` at t ≈ the hog duration"). Under
    /// the broken shape EVERY arming resolves `.value` before the hog
    /// releases — measured 0 of 32 armings counted across 8 rounds — so
    /// `elapsedInsideWindow` is EMPTY and `secs[secs.count / 2]` below never
    /// executes; there is no median to have teeth. The defect is instead
    /// caught by the threshold-free per-arming discriminator added in
    /// m23-as-2c (see below, ahead of the starvation `#require`), which runs
    /// over EVERY arming — counted AND discarded — rather than only the
    /// counted set the old `#expect(m.timedOut, …)` was limited to. The
    /// median ceiling's real remaining job, once that discriminator exists,
    /// is narrower and orthogonal: catching a deadline that DOES fire on the
    /// cooperative pool but grossly late — a different defect from
    /// main-actor-binding, since the discriminator only requires
    /// `.timedOut`, not `.timedOut` within any particular latency.
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
        // m23-as-2c: coupled to `budget`, not a bare constant. Before this,
        // `budget` and `medianCeiling` drifted independently — retune
        // `budget` to 50 ms and the bare 600 ms ceiling silently became a
        // 550 ms tolerance instead of the intended 400 ms.
        //
        // ⚠️ What the additive tie fixes is NOT the multiple. `budget + 400`
        // at a 50 ms budget is still 9× the budget; the ratio blows up either
        // way and that was never the point. What it fixes is that the term
        // being tolerated — wake-up LATENESS — is ADDITIVE and does not scale
        // with the budget, so it belongs in an additive tie. A multiplicative
        // tie between an additive pair is the m23-as-2a category error.
        //
        // ⚠️ And on how much lateness this actually tolerates: MEASURED
        // lateness is ~7–8 ms (median 0.207–0.208 s against a 200 ms budget),
        // so 400 ms is a ~50× margin on the only term that varies. By the
        // m23-as-2a taxonomy that makes this a TRIPWIRE, not a budget — it
        // cannot flake, and "grossly late" has to be very gross indeed before
        // it speaks. That is a deliberate accepted trade, not an oversight:
        // the defect this suite exists for is now caught by the per-arming
        // discriminator below, which needs no margin at all.
        //
        // This is a COUPLING fix, NOT a
        // robustness fix: measured inflation for this quantity is ~1.00×
        // (isolated `--filter` runs, 5×12 armings: median 0.207–0.208 s;
        // full parallel suite, 4693 tests / 483 suites, 94.0 s: median
        // 0.208 s) — there is no load contamination here to defend against,
        // unlike the AU-prepare quantities in m23-as-2a/2b. Its remaining
        // job is narrow: catching a deadline that DOES fire (so the
        // per-arming discriminator below is silent) but grossly late on the
        // cooperative pool — a distinct defect from main-actor-binding. At
        // the current 200 ms budget this evaluates to EXACTLY the old bare
        // 600 ms, so this is a behavior-preserving refactor today; the only
        // thing that changes is what happens if `budget` is ever retuned.
        let medianCeiling = budget + .milliseconds(400)
        let requiredArmings = 10
        let armingsPerRound = 4
        let maxRounds = 8

        var elapsedInsideWindow: [Duration] = []
        var discarded = 0
        var round = 0
        let clock = ContinuousClock()
        // m23-as-2c: violations of the threshold-free per-arming rule
        // below, tallied across every round and EVERY arming — counted or
        // discarded alike. Populated only by a real regression; see the
        // `#require` that reads it after the loop.
        var deadlineBoundViolations: [(elapsed: Duration, describe: String)] = []

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
                // m23-as-2c: a THRESHOLD-FREE rule, checked on EVERY arming
                // regardless of the counted/discarded split below. If the
                // deadline (arming start + budget) fell strictly before the
                // hog released, `work`'s @MainActor task cannot even be
                // SCHEDULED until the hog releases the actor — the hog is a
                // synchronous spin, not a suspension point — while the
                // deadline task needs no actor at all. So if the deadline's
                // own wall-clock sleep resolves before that release, it
                // reaches the once-gate first and the outcome MUST be
                // `.timedOut`; only a main-actor-bound deadline (m23-at) can
                // turn that into `.value`. This is what the old counted-only
                // `#expect(m.timedOut, …)` below lacked: under the m23-at
                // defect `elapsedInsideWindow` stays empty (nothing is ever
                // counted), so that `#expect` never runs even once, and the
                // regression escapes as the starvation message further down.
                // Checking it here, ahead of the discard, means it still has
                // armings to examine either way.
                //
                // Soundness caveat, stated rather than hidden: this assumes
                // the cooperative pool schedules the DEADLINE task itself
                // promptly enough to sleep out `budget` before `spinEnd`. If
                // the pool were saturated enough to delay the deadline
                // task's own wake-up past the hog's release, a CORRECT
                // implementation could land here too and read as a false
                // violation — this rule's soundness is not delay-immune the
                // way the relative `m.end < spinEnd` discard below is.
                // Measured against a full parallel suite (4693 tests / 483
                // suites, ~92 s) this rule did not fire — 12/12 armings
                // landed `.timedOut` at ~0.205–0.210 s median, same shape as
                // isolated — but that is one observation, not a proof the
                // pool can never be starved that badly.
                if m.start.advanced(by: budget) < spinEnd, !m.timedOut {
                    deadlineBoundViolations.append((m.start.duration(to: m.end), m.describe))
                }

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

        // m23-as-2c: THE headline fix. Asserted before the starvation
        // `#require` below on purpose, so that when both conditions hold on
        // a loaded machine the regression message — not the starvation one
        // — is what the reader sees. This is what the mutation test proved
        // was missing: mutating `DeadlineRace.run` back to the pre-m23-at
        // `Task { @MainActor in … }` shape produced 0 counted armings (32
        // discarded, 8 rounds), and the test failed ONLY with "the machine
        // was too starved to run the experiment" — exactly backwards for a
        // real regression, and exactly the message an autonomous loop or CI
        // triages as flake and ignores.
        let violationCount = deadlineBoundViolations.count
        let example = deadlineBoundViolations.first.map { "\($0.describe) after \($0.elapsed)" }
            ?? "n/a"
        try #require(deadlineBoundViolations.isEmpty, """
            \(violationCount) arming(s) had a deadline that should have fired strictly \
            inside the hog window (arming start + \(budget) budget < hog end) but \
            instead resolved \(example). The main actor was provably held through the \
            whole budget, so @MainActor work could not have run — this means the \
            deadline itself is main-actor-bound again (m23-at). This is NOT machine \
            starvation: starvation (checked next) means too FEW armings landed inside \
            the hog window to reach the required sample size, never a qualifying \
            arming that resolves the wrong way.
            """)

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
