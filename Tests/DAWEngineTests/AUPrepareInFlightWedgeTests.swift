import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-av — THE LEG THAT DISTINGUISHES THIS ITEM FROM m23-at.
///
/// m23-at proved the prepare DEADLINE fires while the main actor is hogged.
/// This proves the DECISION IS READABLE while the actor is still held — which
/// it was not: every AU-prepare fact lived behind `@MainActor`, so
/// `engine.auPrepareStats` was unanswerable during exactly the wedge it is
/// most useful in.
///
/// ⚠️ THE HOG MUST BE INSIDE `instantiator`. A sibling hog (a separate task
/// holding the actor while the prepare is trivial) re-proves m23-at and proves
/// NOTHING here: the property under test is that the prepare's OWN work holds
/// the actor, so `performPrepare` cannot resume to publish its outcome. If a
/// future refactor moves the spin out of the instantiator closure, E1 still
/// passes and silently stops testing this item — E4 is the premise pin that
/// would notice.
///
/// PHASE 0 RECORD (2026-08-03, before any production code existed): this same
/// shape reading the then-only surface, `await registry.prepareStats()`,
/// failed on its ASSERTION — the read took 1.129 s and completed 0.39 ms AFTER
/// the spin released the actor, having waited out the whole remaining spin.
/// That is the defect, measured.
///
/// Deliberately NOT `@MainActor`: the reader must run off-main, which is the
/// property under test. `.serialized` because this leg starves the main actor
/// for 1.5 s and must not poison its own siblings — it does nothing about
/// sibling SUITES and is not claimed to.
@Suite(.serialized)
struct AUPrepareInFlightWedgeTests {

    /// Cross-executor mailbox for the in-instantiator hog — the
    /// `DeadlineRaceTests.SpinWindow` shape. The end instant is what makes
    /// E1's bound RELATIVE and self-validating: a read that completed strictly
    /// before the spin ended is, by construction, a read a main-actor-gated
    /// surface could not have served.
    ///
    /// @unchecked Sendable: both fields are touched only under `lock`.
    private final class SpinWindow: @unchecked Sendable {
        private let lock = NSLock()
        private var spinning = false
        private var ended: ContinuousClock.Instant?

        func markSpinning() { lock.lock(); spinning = true; lock.unlock() }
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

    /// A component that REALLY EXISTS: the `instantiator` seam is only reached
    /// after `AVAudioUnitComponentManager.components(matching:)` matches, so a
    /// bogus component would return `.missing` and never arm anything.
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")

    private static func auTrack() -> Track {
        Track(name: "AU", kind: .instrument, clips: [],
              instrument: InstrumentDescriptor(
                  kind: .audioUnit, audioUnit: AudioUnitConfig(component: dls)))
    }

    @Test("the in-flight ledger answers OFF-MAIN while the prepare body holds the main actor")
    func inFlightIsReadableWhileTheActorIsHeld() async throws {
        // MEASURED, and the reason these three numbers are what they are.
        // The ARM→SPIN gap is unbounded under load: arming happens on the main
        // actor at `status[id] = .pending`, then `DeadlineRace.run` posts
        // `Task { @MainActor in work() }`, which must RE-ACQUIRE the actor
        // `performPrepare` just released — behind every @MainActor sibling
        // suite. A first version of this leg anchored the early read to the
        // SPIN and measured that gap at 5.62 s in a full 4712-test run
        // against a 200 ms budget, failing its own precondition. The early
        // read is therefore anchored to the ARM (observed through the ledger
        // itself, off-main), whose only lag is this test's own 1 ms poll.
        let hogDuration = Duration.milliseconds(2_000)
        let budget = Duration.milliseconds(500)
        let margin = Duration.milliseconds(250)
        let clock = ContinuousClock()
        let window = SpinWindow()

        let registry = await AUHostRegistry()
        await MainActor.run {
            registry.instantiator = { _, _ in
                // A SPIN, not `Task.sleep`: sleeping suspends and hands the
                // actor back, which is the opposite of the condition under
                // test.
                window.markSpinning()
                let deadline = clock.now.advanced(by: hogDuration)
                while clock.now < deadline { /* hold the actor, do not suspend */ }
                window.markEnded(clock.now)
                throw CancellationError()
            }
        }

        let track = Self.auTrack()
        // Fire-and-forget: `prepare` is @MainActor and awaits its own chain
        // task, so awaiting it here would deadlock the reads below.
        let handle = Task { @MainActor in
            await registry.prepare(track: track, sampleRate: 48_000, timeout: budget)
        }

        // ── E3, first half: the EARLY read, anchored to the ARM ──
        // HONESTY NOTE, because the pair is easy to over-read: the LATE read
        // below is provably taken while the actor is held (E1 asserts it
        // landed inside the spin window). This EARLY one is not — at arm time
        // `performPrepare` has just released the actor to await its race. What
        // the pair proves is that `overdue` is DERIVED rather than stored or
        // hardcoded; that the true half happens under a held actor is E1's
        // claim, not this one's.
        // Poll (off-main, 1 ms, on the cooperative pool) for the ledger to
        // become non-empty. That transition IS the arm, and polling for it is
        // itself only possible because the read is nonisolated — on the old
        // surface this loop could not exist.
        var early: [EngineAUPrepareStats.InFlightEntry] = []
        var waited = Duration.zero
        while early.isEmpty && waited < .seconds(90) {
            early = registry.inFlightSnapshot()
            if !early.isEmpty { break }
            try await Task.sleep(for: .milliseconds(1))
            waited += .milliseconds(1)
        }
        let earlyEntry = try #require(early.first, """
            no prepare armed within 90 s — main-actor starvation from SIBLING suites \
            before the prepare body even reached its arm site, not an m23-av failure.
            """)
        // SELF-VALIDATING PRECONDITION: if even the arm→poll lag exceeded the
        // budget the leg is INCONCLUSIVE on its own `#require` rather than
        // falsely red on the assertion below. With the read anchored to the
        // arm this is ~1 ms against a 500 ms budget (a ~500× margin), not the
        // unbounded actor-reacquisition gap.
        try #require(earlyEntry.startedSecondsAgo < earlyEntry.deadlineSeconds, """
            the arm→poll lag was \(earlyEntry.startedSecondsAgo) s against a \
            \(earlyEntry.deadlineSeconds) s budget, so the "early" read was already past \
            the deadline and cannot witness the false→true flip. Machine starvation, \
            not a failure.
            """)
        #expect(earlyEntry.overdue == false, """
            an entry armed \(earlyEntry.startedSecondsAgo) s ago against a \
            \(earlyEntry.deadlineSeconds) s budget reported overdue. `overdue` must be \
            DERIVED from the evidence, not hardcoded.
            """)

        // Handshake, off-main on the cooperative pool (the hog does not block
        // it): without this the LATE read might measure an UNCONTENDED actor —
        // a pass for the wrong reason. This is the unbounded wait; it is
        // deliberately AFTER the early read.
        waited = .zero
        while !window.isSpinning && waited < .seconds(90) {
            try await Task.sleep(for: .milliseconds(1))
            waited += .milliseconds(1)
        }
        try #require(window.isSpinning, """
            the in-instantiator hog never started within 90 s, so the late read could not \
            be taken against a held actor. This is main-actor starvation from SIBLING \
            suites, not an m23-av failure.
            """)

        // Sleep past the deadline. Elapsed-since-arm is now at least
        // `budget + margin` (and under load far more, since the arm preceded
        // the spin), so the late entry MUST be overdue.
        try await Task.sleep(for: budget + margin)

        // PRECONDITION for E1/E2: if the spin already ended we slept through
        // the window and the experiment did not run.
        try #require(window.endInstant == nil, """
            the \(hogDuration) spin ended before the late read was taken (slept \
            \(budget + margin)) — the machine was too starved to run the experiment, \
            which is not the same as the experiment failing. Raise hogDuration; never \
            lower the margin.
            """)

        let t0 = clock.now
        let late = registry.inFlightSnapshot()
        let t1 = clock.now

        _ = await handle.value
        let spinEnd = try #require(window.endInstant, "the hog never recorded its end instant")

        print("[measured] m23-av: early overdue=\(earlyEntry.overdue) at "
              + "\(earlyEntry.startedSecondsAgo) s; late entries=\(late.count); "
              + "read took \(t0.duration(to: t1)); read end vs spin end = "
              + "\(spinEnd.duration(to: t1)) (negative = inside the spin window)")

        // ── E1: the read COMPLETED strictly inside the spin window ──
        // Fully relative, no wall-clock constant. A main-actor-gated read
        // cannot produce this: it would queue behind the spin and land after
        // `spinEnd`, which is exactly what Phase 0 measured.
        //
        // ⚠️ ORDER IS LOAD-BEARING, and it was WRONG in this leg's first
        // version. E2's `try #require(late.first)` used to run first, so the
        // measured E1-M-b mutation (`DispatchQueue.main.sync` inside
        // `AUPrepareLedger.snapshot()`) aborted the test at E2 and E1's
        // assertion NEVER EXECUTED: blocking until the actor frees means the
        // read lands after the DISARM and observes an EMPTY ledger, so the
        // count check fires before the timing check ever gets a turn. The
        // timing claim is asserted FIRST so it cannot be shadowed by a
        // consequence of the same defect. (This is the m23-au S6 shape:
        // a design's predicted leg was not the leg that reddened.)
        #expect(t1 < spinEnd, """
            the off-main read completed \(spinEnd.duration(to: t1)) AFTER the spin \
            released the main actor (read took \(t0.duration(to: t1)); the spin had \
            \(t0.duration(to: spinEnd)) left to run when the read was armed). The read \
            is main-actor-gated again — that is the m23-av defect.
            """)

        // ── E4: PREMISE PIN, not a defect guard ──
        // The published status moved only AFTER the spin released. This is
        // what makes the ledger necessary at all. It reddens if publication
        // ever becomes non-main — i.e. if out-of-process hosting (route (b))
        // lands — which would be good news, not a regression. Do not
        // over-trust it as a guard.
        let published = await MainActor.run { registry.status[track.id] }
        if case .failed(let reason)? = published {
            #expect(reason.contains("timed out"))
        } else {
            Issue.record("expected .failed after the race timed out, got \(String(describing: published))")
        }

        // ── E5: disarm fired ──
        #expect(registry.inFlightSnapshot().isEmpty, """
            the ledger still holds \(registry.inFlightSnapshot()) after the prepare \
            published its outcome — a leaked record reports overdue forever.
            """)

        // ── E2: WHAT the ledger says, read while the actor was still held ──
        // LAST, and deliberately so: this is the only block that ABORTS (its
        // `try #require`), and everything above must get its turn regardless.
        // In the first version E4 and E5 sat below this `#require` and were
        // silently skipped by the very mutation (E1-M-b) that made `late`
        // empty — a leg that never executes gates nothing. Same lesson as the
        // E1/E2 reorder above, found the same way.
        #expect(late.count == 1, "expected exactly one in-flight entry, got \(late)")
        let entry = try #require(late.first)
        #expect(entry.slot == "instrument")
        #expect(entry.id == track.id.uuidString)
        #expect(entry.deadlineSeconds == 0.5)
        #expect(entry.component == Self.dls)
        #expect(entry.overdue == true, """
            an entry armed \(entry.startedSecondsAgo) s ago against a \
            \(entry.deadlineSeconds) s budget did not report overdue.
            """)
        #expect(entry.startedSecondsAgo > entry.deadlineSeconds)
    }
}
