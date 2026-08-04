import Foundation
import Testing

// m23-bu-1 LIVE GATE — HOW STARVED IS THE MAIN ACTOR, REALLY, AND DOES
// `.serialized` HELP?
//
// THE QUESTION m23-bq's close left open. Legs that assert "the playhead
// advanced N times in a 1200 ms window" measure the Swift Testing HARNESS
// under `./scripts/test.sh`, not the code, once enough @MainActor suites are
// running concurrently — this tree has ~96 of them in Tests/DAWEngineTests
// alone. m23-bq measured filtered-alone runs collecting ~35 playhead pushes
// where the full suite collected 3, 3, and 2, and one nominally-3200 ms
// sample landed at 10415 ms. This file turns that anecdote into a number and
// answers the load-bearing design question before bu-2 builds anything on
// top of it: does marking a suite `.serialized` protect it from OTHER
// suites' contention, or only from its own?
//
// THE RIG. `FineCadencePinger` fires ping ticks at a fixed cadence (default
// 10 ms) on a DEDICATED background dispatch queue — deliberately NOT the
// Swift concurrency cooperative thread pool, so the tick itself is immune to
// the starvation being measured; only the two hops posted per tick pay for
// it:
//   · a `Task(priority: .medium) { @MainActor in … }` hop — what every live
//     timing leg in this tree actually pays every time it pushes a playhead
//     value or polls a render clock.
//   · a `Task.detached(priority: .medium) { … }` hop — plain cooperative-pool
//     scheduling, no actor involved.
//   · a QUEUE-JITTER sample, taken SYNCHRONOUSLY inside the timer callback
//     itself, before either Task is even created — no actor, no cooperative
//     pool, not even Swift concurrency. This is the leg that keeps the other
//     two honest: `Task.detached` still runs on the cooperative thread pool,
//     so a large nonisolated gap is ambiguous between "the OS ran out of
//     real CPU/threads for anything" and "libdispatch's global concurrent
//     queues (which back the pool) are themselves queued behind other
//     dispatch work, while a plain dedicated serial queue would have been
//     scheduled promptly." The queue-jitter sample answers that: it is
//     driven by `DispatchSource.makeTimerSource` on a queue this file owns
//     and nothing else touches, so if IT is prompt while the nonisolated
//     Task is not, the bottleneck is specifically Swift concurrency's pool,
//     not the machine being out of schedulable threads.
// Both Task hops use the SAME EXPLICIT priority on purpose: `Task { @MainActor }`
// inherits the creating context's priority while `Task.detached` does not,
// so leaving either implicit would let a priority mismatch masquerade as an
// isolation-domain finding — and that finding is exactly what bu-2's fix
// hangs on:
//   · main-actor gaps large, nonisolated AND queue-jitter gaps small ⇒
//     MAIN-ACTOR CONTENTION SPECIFICALLY (queued @MainActor jobs from other
//     suites) — the fix is isolating timing-sensitive work off the shared
//     queue, or accepting the exposure and designing the metric to survive
//     it (see docs/ARCHITECTURE.md).
//   · main-actor AND nonisolated gaps large, queue-jitter small ⇒ Swift
//     concurrency's COOPERATIVE POOL is queued (too many concurrent Tasks
//     for the runtime to service promptly) while the OS itself can still
//     schedule a plain dispatch queue on time — the fix is reducing
//     concurrent TASK fan-out (e.g. suite parallelism), not the main actor.
//   · all three large, including queue-jitter ⇒ genuine OS-level CPU /
//     thread oversubscription — nothing this file's rig runs on gets a
//     timely thread, cooperative pool or not.
// This is the SHAPE of `Sources/DAWControl/MainActorLiveness.swift`'s
// `MainActorLivenessMonitor`, at a cadence two orders of magnitude finer:
// that monitor's 1 s ping / 2.5 s threshold exists to catch a multi-second
// WEDGE, not the 100–500 ms starvation this item measures — reusing it
// unmodified would have been too coarse to see anything.
//
// ⚠️ LEEWAY IS A MEASUREMENT PARAMETER, NOT DECORATION. The liveness
// monitor's 100 ms leeway at a 1 s cadence is harmless; copied to a 10 ms
// cadence it would let libdispatch legitimately COALESCE ticks, which would
// look exactly like starvation and quietly corrupt every number below. This
// rig uses ~1 ms leeway and reports `fired` (ticks the timer actually
// delivered) separately from `nominal` (ticks the schedule promised) — MEASURED
// (m23-bu-1, full-suite run): `fired` reads within 1 of `nominal` even under
// the full 4497-test load (400 vs 399, 400 vs 400), while the queue-jitter leg
// stayed in the tens-of-ms range in the same run. Read together those two
// facts settle the question this comment used to leave open: the tiny
// fired/nominal gap is a BOUNDARY artifact (whether `stop()` lands before or
// after the one scheduled tick nearest the end of the window), not evidence
// of coalescing or of the dedicated queue itself being starved.
//
// FOUR SUITES, four separable questions:
//   A. `MainActorStarvationProbeTests` — plain, NOT `.serialized`. The
//      ordinary shape of a live timing leg in this tree.
//   B. `MainActorStarvationSerializedProbeTests` — BYTE-IDENTICAL test body,
//      `.serialized`. Run under the SAME full-suite invocation as A (both
//      opt into the one shared env var below), so both experience the exact
//      same ambient load at the exact same instant — a paired comparison,
//      not "ran alone" vs "ran alongside something, maybe". If `.serialized`
//      protected against cross-suite contention, B would read close to its
//      own "filtered alone" baseline even embedded in the full run, while A
//      would not; if it does not, A and B read alike.
//   C. `MainActorSerializedScopeControlTests` — the POSITIVE CONTROL for the
//      trait itself, ONE suite with TWO tests. Without this, "B is starved
//      just like A" is ambiguous between "`.serialized` doesn't help across
//      suites" and "the annotation did nothing at all, including within its
//      own suite" — this tree's own law (a leg never seen red is worthless)
//      applied to a trait, not just an assertion. Each test prints its
//      absolute epoch-ms span; non-overlapping spans is a within-suite
//      serialization proof.
//   D. `MainActorStarvationCalibrationTests` — a DELIBERATE, known-magnitude
//      main-actor block (`Thread.sleep`, 1.5 s), launched from inside the
//      SAME test as the measurement so their overlap is not scheduling luck.
//      Answers "how do I know a small gap means no starvation, rather than a
//      broken pinger?" — the rig is proven able to see a real block before
//      its silence on the ambient case is trusted. GATED SEPARATELY (see
//      below): this genuinely blocks the WHOLE PROCESS's main thread, and
//      must never bleed into suite A/B's ambient reading.
//
// TWO ENV VARS, DELIBERATELY SEPARATE (the m23-bt precedent: a var nobody can
// run unattended is not a verification, and a var that silently pulls in a
// DIFFERENT kind of test is not a clean measurement):
//
//     DAWPRO_MEASURE_MAINACTOR=1 ./scripts/test.sh
//         Runs A, B, C. Safe to include in a normal full-suite invocation —
//         no thread is ever deliberately blocked. This is what to run to
//         answer "how starved is the main actor right now, on this machine,
//         under this suite".
//
//     DAWPRO_MEASURE_MAINACTOR_CALIBRATION=1 ./scripts/test.sh --filter MainActorStarvationCalibrationTests
//         Runs ONLY D. Kept out of the general var on purpose: D blocks the
//         real main thread for 1.5 s, and if it ran embedded in the same
//         process as A/B's ambient measurement it would inject a synthetic
//         1.5 s outlier into what is supposed to be an HONEST ambient
//         reading. Run it on its own, once, to trust the rig; it does not
//         need to run every time.
//
// A normal `./scripts/test.sh` run (neither var set) costs nothing: every
// `@Test` below is `.enabled(if:)`-gated and Swift Testing skips a disabled
// test without invoking its body.
//
// ⚠️ WHAT THIS FILE DOES NOT PROVE. It measures SCHEDULING delay on THIS
// machine, under THIS suite, at THIS commit — not a guarantee about any other
// machine's core count or any future suite's size. See docs/ARCHITECTURE.md
// for the settled rule this measurement exists to justify, and its own
// "known limit, filed not hidden" clause.

// MARK: - Shared measurement rig (fileprivate — used by every suite below)

/// One ping's round trip, recorded under a lock. `fired` counts every tick
/// the timer delivered, whether or not its hop has landed yet; `gapsMs`
/// records `(landed − fired)` in milliseconds for every hop that DID land.
fileprivate final class GapRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = 0
    private var gapsMs: [Double] = []

    func recordFired() {
        lock.lock(); fired += 1; lock.unlock()
    }

    func recordLanded(gapMs: Double) {
        lock.lock(); gapsMs.append(gapMs); lock.unlock()
    }

    func snapshot() -> (fired: Int, gapsMs: [Double]) {
        lock.lock()
        defer { lock.unlock() }
        return (fired, gapsMs)
    }
}

/// A finished distribution, ready to print. `neverLanded` is the count Step 2
/// asked for directly: pings the timer fired that had not landed by the end
/// of the observation window (duration + grace) — the sparse-sample failure
/// mode that let m23-bq's freeze ship unnoticed.
///
/// ⚠️ `maxMs`/`p50Ms`/`p95Ms`/`p99Ms` ARE COMPUTED OVER THE LANDED SUBSET ONLY
/// (`gapsMs`), never over `fired`. When `neverLanded > 0` these are therefore
/// RIGHT-CENSORED LOWER BOUNDS, not the true distribution: every never-landed
/// ping has already waited, by construction, at least
/// `(duration + grace) − itsSentMs` without landing — which is provably
/// GREATER than every value in the landed set (a ping that landed sooner
/// would already be counted as landed). Do not compare a censored channel's
/// percentile against an uncensored channel's percentile and conclude the
/// censored one is "smaller" or "similar" — read `neverLanded` first. See
/// docs/ARCHITECTURE.md's m23-bu-1 entry for a worked example of getting
/// this wrong on the first pass and the corrected reading.
fileprivate struct GapStats {
    let nominal: Int
    let fired: Int
    let landed: Int
    let neverLanded: Int
    let maxMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double

    static func compute(nominal: Int, fired: Int, gapsMs: [Double]) -> GapStats {
        let sorted = gapsMs.sorted()
        func pct(_ p: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let idx = min(sorted.count - 1, max(0, Int((Double(sorted.count) * p).rounded(.up)) - 1))
            return sorted[idx]
        }
        return GapStats(nominal: nominal, fired: fired, landed: sorted.count,
                        neverLanded: fired - sorted.count, maxMs: sorted.last ?? 0,
                        p50Ms: pct(0.50), p95Ms: pct(0.95), p99Ms: pct(0.99))
    }

    var rendered: String {
        var s = "nominal=\(nominal) fired=\(fired) landed=\(landed) neverLanded=\(neverLanded)"
            + " max=" + String(format: "%.0f", maxMs) + "ms"
            + " p50=" + String(format: "%.0f", p50Ms) + "ms"
            + " p95=" + String(format: "%.0f", p95Ms) + "ms"
            + " p99=" + String(format: "%.0f", p99Ms) + "ms"
        // neverLanded > 0 means max/p50/p95/p99 above are computed over the
        // LANDED subset only and are right-censored LOWER BOUNDS — see the
        // struct doc comment. Flagged in-line so a reader of raw test output
        // (not just the source) cannot miss it and compare two channels'
        // percentiles as if both were complete distributions.
        if neverLanded > 0 {
            s += " [CENSORED: \(neverLanded) never landed — max/p50/p95/p99 above are LOWER BOUNDS]"
        }
        return s
    }
}

/// Fires at a fixed cadence on its own dedicated queue and posts one
/// main-actor hop plus one nonisolated hop per tick. See the file header for
/// why the queue, the leeway, and the shared priority are each load-bearing.
fileprivate final class FineCadencePinger: @unchecked Sendable {
    static let hopPriority: TaskPriority = .medium

    private let queue = DispatchQueue(label: "dawpro.m23bu.pinger", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private let mainRecorder = GapRecorder()
    private let nonisolatedRecorder = GapRecorder()
    /// Recorded SYNCHRONOUSLY inside the timer callback itself, on the
    /// dedicated queue — no Task, no actor, no cooperative pool involved.
    /// This is the discriminator between "Swift concurrency's cooperative
    /// pool is queued" and "the OS genuinely could not schedule ANY thread,
    /// including a plain libdispatch one" — see the file header.
    private let queueJitterRecorder = GapRecorder()
    private var tickIndex = 0
    private let cadenceMs: Double
    private let startUptimeNs: UInt64

    init(cadenceMs: Double) {
        self.cadenceMs = cadenceMs
        self.startUptimeNs = DispatchTime.now().uptimeNanoseconds
    }

    private func nowMs() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- startUptimeNs) / 1_000_000
    }

    func start() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(Int(cadenceMs)),
                        leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let sentMs = nowMs()
        // Jitter of the CALLBACK ITSELF against the cadence libdispatch was
        // told to keep, measured before any Task is created. `queue` is a
        // plain serial DispatchQueue — mutating `tickIndex` here needs no
        // lock, because the timer's event handler is always serialized onto
        // this same queue.
        let expectedMs = Double(tickIndex) * cadenceMs
        tickIndex += 1
        queueJitterRecorder.recordFired()
        queueJitterRecorder.recordLanded(gapMs: sentMs - expectedMs)
        let mainRecorder = self.mainRecorder
        let nonisolatedRecorder = self.nonisolatedRecorder
        let start = startUptimeNs
        mainRecorder.recordFired()
        nonisolatedRecorder.recordFired()
        Task(priority: Self.hopPriority) { @MainActor in
            let landedMs = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            mainRecorder.recordLanded(gapMs: landedMs - sentMs)
        }
        Task.detached(priority: Self.hopPriority) {
            let landedMs = Double(DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000
            nonisolatedRecorder.recordLanded(gapMs: landedMs - sentMs)
        }
    }

    func stats(nominal: Int) -> (main: GapStats, nonisolated: GapStats, queueJitter: GapStats) {
        let m = mainRecorder.snapshot()
        let n = nonisolatedRecorder.snapshot()
        let j = queueJitterRecorder.snapshot()
        return (GapStats.compute(nominal: nominal, fired: m.fired, gapsMs: m.gapsMs),
                GapStats.compute(nominal: nominal, fired: n.fired, gapsMs: n.gapsMs),
                GapStats.compute(nominal: nominal, fired: j.fired, gapsMs: j.gapsMs))
    }
}

fileprivate enum MainActorStarvationProbe {
    static let isEnabled = ProcessInfo.processInfo
        .environment["DAWPRO_MEASURE_MAINACTOR"] == "1"

    /// Runs the pinger for `durationSeconds`, then waits `graceSeconds` before
    /// reading. The grace period is not decoration: a pong queued behind a
    /// long starvation episode still deserves the chance to land inside what
    /// this file calls "the window" — without it, a merely-LATE pong would be
    /// misreported as one that never landed at all.
    static func measure(durationSeconds: Double, cadenceMs: Double = 10,
                        graceSeconds: Double = 2) async
        -> (main: GapStats, nonisolated: GapStats, queueJitter: GapStats) {
        let pinger = FineCadencePinger(cadenceMs: cadenceMs)
        pinger.start()
        try? await Task.sleep(for: .milliseconds(Int(durationSeconds * 1000)))
        pinger.stop()
        try? await Task.sleep(for: .milliseconds(Int(graceSeconds * 1000)))
        let nominal = Int((durationSeconds * 1000) / cadenceMs)
        return pinger.stats(nominal: nominal)
    }

    /// Absolute wall time in ms since the epoch — printed alongside every
    /// `[measured]` line so spans from DIFFERENT suites/tests in the SAME
    /// `swift test` process can be correlated after the fact to check they
    /// genuinely overlapped, instead of assuming it.
    static func epochMs() -> Double { Date().timeIntervalSince1970 * 1000 }
}

// MARK: - A. Plain probe — the ordinary shape of a live timing leg

@Suite("Main-actor starvation probe — plain (m23-bu-1)")
struct MainActorStarvationProbeTests {
    @Test("live: main-actor vs nonisolated ping gaps, plain (unserialized) suite",
          .enabled(if: MainActorStarvationProbe.isEnabled))
    func measureGaps() async throws {
        let startEpoch = MainActorStarvationProbe.epochMs()
        let (main, nonisolated, queueJitter) = await MainActorStarvationProbe.measure(durationSeconds: 4)
        let endEpoch = MainActorStarvationProbe.epochMs()
        print("[measured] m23-bu PLAIN epoch=\(Int(startEpoch))-\(Int(endEpoch))"
              + " mainActor:\(main.rendered)")
        print("[measured] m23-bu PLAIN nonisolated:\(nonisolated.rendered)")
        print("[measured] m23-bu PLAIN queueJitter:\(queueJitter.rendered)")
        let broken = "the pinger itself never fired a single tick — the RIG is broken, not "
            + "measuring anything. main:\(main.rendered) nonisolated:\(nonisolated.rendered)"
        #expect(main.fired > 0 && nonisolated.fired > 0, "\(broken)")
    }
}

// MARK: - B. IDENTICAL body, `.serialized` — settles what the trait scopes to

@Suite("Main-actor starvation probe — .serialized (m23-bu-1)", .serialized)
struct MainActorStarvationSerializedProbeTests {
    @Test("live: main-actor vs nonisolated ping gaps, .serialized suite",
          .enabled(if: MainActorStarvationProbe.isEnabled))
    func measureGaps() async throws {
        let startEpoch = MainActorStarvationProbe.epochMs()
        let (main, nonisolated, queueJitter) = await MainActorStarvationProbe.measure(durationSeconds: 4)
        let endEpoch = MainActorStarvationProbe.epochMs()
        print("[measured] m23-bu SERIALIZED epoch=\(Int(startEpoch))-\(Int(endEpoch))"
              + " mainActor:\(main.rendered)")
        print("[measured] m23-bu SERIALIZED nonisolated:\(nonisolated.rendered)")
        print("[measured] m23-bu SERIALIZED queueJitter:\(queueJitter.rendered)")
        let broken = "the pinger itself never fired a single tick — the RIG is broken, not "
            + "measuring anything. main:\(main.rendered) nonisolated:\(nonisolated.rendered)"
        #expect(main.fired > 0 && nonisolated.fired > 0, "\(broken)")
    }
}

// MARK: - C. Positive control for `.serialized` ITSELF (within-suite proof)

/// Without this, "B is starved just like A" is ambiguous between "`.serialized`
/// doesn't help across suites" and "the annotation did nothing at all,
/// including within its own suite" — a `.serialized` header that never proved
/// it does anything is exactly the "leg never seen red" trap this tree
/// otherwise guards against, applied to a trait instead of an assertion.
@Suite(".serialized within-suite proof (m23-bu-1)", .serialized)
struct MainActorSerializedScopeControlTests {
    @Test("live: span A", .enabled(if: MainActorStarvationProbe.isEnabled))
    func spanA() async throws {
        let start = MainActorStarvationProbe.epochMs()
        try? await Task.sleep(for: .milliseconds(400))
        let end = MainActorStarvationProbe.epochMs()
        print("[measured] m23-bu SERIALIZED-SPAN A epoch=\(Int(start))-\(Int(end))")
    }

    @Test("live: span B", .enabled(if: MainActorStarvationProbe.isEnabled))
    func spanB() async throws {
        let start = MainActorStarvationProbe.epochMs()
        try? await Task.sleep(for: .milliseconds(400))
        let end = MainActorStarvationProbe.epochMs()
        print("[measured] m23-bu SERIALIZED-SPAN B epoch=\(Int(start))-\(Int(end))")
    }
}

// MARK: - D. Calibration — proves the rig can see a REAL block (own env var)

/// `Thread.sleep` on the main actor deliberately blocks the WHOLE PROCESS's
/// real main thread for 1.5 s. Safe ONLY because it is opt-in under its own
/// var, separate from `DAWPRO_MEASURE_MAINACTOR` — see the file header for
/// why it must never run embedded in the ambient A/B/C measurement.
fileprivate enum MainActorStarvationCalibration {
    static let isEnabled = ProcessInfo.processInfo
        .environment["DAWPRO_MEASURE_MAINACTOR_CALIBRATION"] == "1"
}

@Suite("Known-magnitude main-actor block — pinger calibration (m23-bu-1)")
struct MainActorStarvationCalibrationTests {
    @Test("live: calibration — a deliberate main-actor block must show up as a comparable gap",
          .enabled(if: MainActorStarvationCalibration.isEnabled))
    func calibrationBlockIsDetected() async throws {
        let blockMs = 1_500.0
        // Launched from INSIDE this same test so the overlap with the probe
        // below is not a matter of scheduling luck between two independent
        // suites/tests — see the file header on why that distinction matters.
        // `Thread.sleep` is unavailable from an `async` context (Swift 6 will
        // not let async code accidentally block a thread), so the deliberate
        // block runs inside a plain, non-async closure dispatched onto
        // `DispatchQueue.main` — the same underlying queue/thread Swift
        // Concurrency's `@MainActor` executor is backed by on Apple
        // platforms, so this blocks the real main thread exactly as intended.
        let blocker = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.main.async {
                    Thread.sleep(forTimeInterval: blockMs / 1000)
                    continuation.resume()
                }
            }
        }
        let (main, nonisolated, queueJitter) = await MainActorStarvationProbe.measure(
            durationSeconds: 4, cadenceMs: 10, graceSeconds: 2)
        _ = await blocker.value
        print("[measured] m23-bu CALIBRATION block=\(Int(blockMs))ms mainActor:\(main.rendered)")
        print("[measured] m23-bu CALIBRATION nonisolated:\(nonisolated.rendered)")
        print("[measured] m23-bu CALIBRATION queueJitter:\(queueJitter.rendered)")
        let missed = "the pinger failed to detect a deliberate \(Int(blockMs)) ms main-actor "
            + "block (max main-actor gap only \(Int(main.maxMs)) ms) — the RIG cannot be "
            + "trusted to measure real starvation. " + main.rendered
        #expect(main.maxMs >= blockMs * 0.5, "\(missed)")
    }
}
