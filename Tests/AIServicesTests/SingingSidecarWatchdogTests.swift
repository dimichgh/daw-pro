import Foundation
import os
import Testing
@testable import AIServices

/// `SingingSidecarWatchdog` coverage (item p2-sing-c), entirely INJECTED — no real process, no
/// real system memory pressure, no real sleep waited beyond a few tens of milliseconds. The
/// end-to-end proof against a REAL spawned stub process (the design's own gate: "a watchdog kill,
/// 512 MB cap against the stub's 600 MB balloon fault") lives in
/// `SingingSidecarManagerWatchdogTests` instead — this file is the pure `decide()` table plus the
/// actor loop's own bookkeeping (arm/disarm/samplesTaken/lastKillReason), which that end-to-end
/// test cannot cheaply isolate on its own.
///
/// Every test that asserts "no kill" also asserts `samplesTaken > 0` (or an explicit lower bound)
/// — the anti-vacuity rule this codebase keeps re-learning: a watchdog that never sampled and one
/// that sampled and correctly found nothing wrong produce the identical `lastKillReason == nil`
/// on their own; only `samplesTaken` tells them apart.
private func rootPid() -> Int32 { 999_999 }   // never a real process -- `kill` is always injected here

/// Thread-safe scripted footprint sequence: returns each value once, in order, then repeats the
/// last one forever (a realistic shape — a real footprint does not oscillate back to `nil`).
private final class ScriptedValues<T: Sendable>: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[T]>(initialState: [])
    init(_ values: [T]) { lock.withLock { $0 = values } }
    func next() -> T {
        lock.withLock { values in
            guard !values.isEmpty else { fatalError("ScriptedValues exhausted with no values at all") }
            if values.count > 1 { return values.removeFirst() }
            return values[0]
        }
    }
}

private final class CallRecorder: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock<[(Int32, SidecarStop.Identity)]>(initialState: [])
    func record(_ pid: Int32, _ identity: SidecarStop.Identity) { lock.withLock { $0.append((pid, identity)) } }
    var calls: [(Int32, SidecarStop.Identity)] { lock.withLock { $0 } }
}

// MARK: - The pure decision table

@Suite("SingingSidecarWatchdog.decide — pure (item p2-sing-c)")
struct SingingSidecarWatchdogDecideTests {
    @Test("under the cap, no pressure -> .ok")
    func underCapNoPressureIsOk() {
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: 10 * 1_048_576, capBytes: 512 * 1_048_576, recentCritical: [false, false])
        #expect(action == .ok)
    }

    @Test("over the cap on a SINGLE sample -> .kill, reason names the cap (no debounce needed for the byte number)")
    func overCapKillsOnOneSample() {
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: 600 * 1_048_576, capBytes: 512 * 1_048_576, recentCritical: [])
        guard case .kill(let trigger, let reason) = action else {
            Issue.record("expected .kill, got \(action)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("cap"))
        #expect(reason.localizedCaseInsensitiveContains("footprint"))
        #expect(trigger == .footprint(bytes: 600 * 1_048_576, capBytes: 512 * 1_048_576))
    }

    @Test("exactly at the cap (not over) -> .ok — the comparison is strictly greater-than")
    func exactlyAtCapIsOk() {
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: 512 * 1_048_576, capBytes: 512 * 1_048_576, recentCritical: [])
        #expect(action == .ok)
    }

    @Test("a nil footprint (could not be read) -> .ok, treated as under the cap, never a kill")
    func nilFootprintIsOk() {
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: nil, capBytes: 512 * 1_048_576, recentCritical: [false])
        #expect(action == .ok)
    }

    @Test("ONE Critical sample alone -> .ok (a single blip never kills)")
    func oneCriticalSampleAloneIsOk() {
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: 10 * 1_048_576, capBytes: 512 * 1_048_576, recentCritical: [true])
        #expect(action == .ok)
    }

    @Test("TWO CONSECUTIVE Critical samples -> .kill, reason names pressure")
    func twoConsecutiveCriticalKills() {
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: 10 * 1_048_576, capBytes: 512 * 1_048_576, recentCritical: [true, true])
        guard case .kill(let trigger, let reason) = action else {
            Issue.record("expected .kill, got \(action)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("pressure")
                || reason.localizedCaseInsensitiveContains("critical"))
        #expect(trigger == .pressure)
    }

    @Test("Critical, then NOT critical, then Critical again -> .ok — not consecutive, never kills")
    func nonConsecutiveCriticalNeverKills() {
        // `decide` only ever sees the last two entries of the ACTUAL rolling window; this directly
        // exercises that a [true, false, true]-shaped window (last two = [false, true]) is .ok.
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: 10 * 1_048_576, capBytes: 512 * 1_048_576, recentCritical: [true, false, true])
        // Only the LAST TWO matter — [false, true] — so this must stay .ok.
        #expect(action == .ok)
    }

    @Test("the footprint cap and the pressure rule are independent: pressure kills even far under the cap")
    func pressureKillsEvenUnderCap() {
        let action = SingingSidecarWatchdog.decide(
            footprintBytes: 1024, capBytes: 512 * 1_048_576, recentCritical: [true, true])
        guard case .kill = action else {
            Issue.record("expected .kill, got \(action)")
            return
        }
    }
}

// MARK: - The actor loop: arm/disarm/samplesTaken/lastKillReason, fully injected

@Suite("SingingSidecarWatchdog — the actor loop, fully injected (item p2-sing-c)")
struct SingingSidecarWatchdogLoopTests {
    private func makeWatchdog(
        capBytes: UInt64 = 512 * 1_048_576,
        footprints: [UInt64?],
        recentCritical: [Bool] = [],
        recorder: CallRecorder
    ) -> SingingSidecarWatchdog {
        let values = ScriptedValues(footprints)
        let criticalValues = recentCritical.isEmpty ? nil : ScriptedValues(recentCritical)
        return SingingSidecarWatchdog(configuration: .init(
            capBytes: capBytes,
            pollIntervalSeconds: 0.01,
            sampleFootprintBytes: { _ in values.next() },
            readMemoryPressureCritical: { criticalValues?.next() ?? false },
            // `rootPid()` below (999_999) is deliberately never a real process -- the REAL
            // liveness default (`kill(pid, 0) == 0`) would report it dead on the very first
            // sample. This suite is about decide/arm/disarm/samplesTaken, not the liveness
            // feature (FIX NOW #4), which gets its own real-process tests.
            pidIsAlive: { _ in true },
            kill: { pid, identity in recorder.record(pid, identity); return true }))
    }

    /// Polls `condition` until it is true, or `timeoutSeconds` elapses — the same shape every
    /// manager-level test in this item already uses for "wait for an async loop to notice
    /// something", restated here for the watchdog's own loop.
    private func waitUntil(
        timeoutSeconds: Double = 3, _ condition: () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }

    @Test("a footprint that crosses the cap on the 3rd sample kills on exactly that sample, and stops sampling after")
    func killsOnTheSampleThatCrossesTheCap() async throws {
        let recorder = CallRecorder()
        let watchdog = makeWatchdog(
            capBytes: 500 * 1_048_576,
            footprints: [10 * 1_048_576, 20 * 1_048_576, 600 * 1_048_576],
            recorder: recorder)
        await watchdog.arm(rootPid: rootPid())

        let killed = await waitUntil { recorder.calls.count > 0 }
        #expect(killed, "the watchdog never called kill")
        #expect(recorder.calls.count == 1, "kill must fire exactly once, got \(recorder.calls)")
        #expect(recorder.calls.first?.0 == rootPid())
        let samplesTaken = await watchdog.samplesTaken
        #expect(samplesTaken == 3, "must kill on the 3rd sample, the first one over the cap")
        let isArmed = await watchdog.isArmed
        #expect(isArmed == false, "the loop disarms itself once it kills")
        let lastKillReason = await watchdog.lastKillReason
        #expect(lastKillReason != nil)
    }

    @Test("an always-under-cap footprint never kills, AND samplesTaken proves the loop actually ran")
    func underCapNeverKillsAndLoopDemonstrablyRan() async throws {
        let recorder = CallRecorder()
        let watchdog = makeWatchdog(footprints: [10 * 1_048_576], recorder: recorder)
        await watchdog.arm(rootPid: rootPid())

        // Not waiting for a kill (there must never be one) -- waiting for samplesTaken to clear a
        // real threshold, which is the anti-vacuity proof itself.
        let ranEnough = await waitUntil { await watchdog.samplesTaken >= 5 }
        #expect(ranEnough, "the loop must take multiple samples over this window")
        #expect(recorder.calls.isEmpty, "an under-cap footprint must never call kill")
        let lastKillReason = await watchdog.lastKillReason
        #expect(lastKillReason == nil)
        let isArmed = await watchdog.isArmed
        #expect(isArmed == true, "still armed -- nothing ever told it to stop")
        await watchdog.disarm()
    }

    @Test("disarm() before the first sample prevents ANY sampling at all")
    func disarmBeforeFirstSamplePreventsSampling() async throws {
        let recorder = CallRecorder()
        // A long poll interval so disarm() below is guaranteed to land before the first sample.
        let watchdog = SingingSidecarWatchdog(configuration: .init(
            capBytes: 1, pollIntervalSeconds: 5,   // cap of 1 byte -- would kill INSTANTLY if ever sampled
            sampleFootprintBytes: { _ in 1_048_576 },
            pidIsAlive: { _ in true },
            kill: { pid, identity in recorder.record(pid, identity); return true }))
        await watchdog.arm(rootPid: rootPid())
        await watchdog.disarm()

        // Wait past what the poll interval would have been, PROVING the disarm landed before any
        // sample by the total absence of a kill despite a cap that would kill on sample one.
        try await Task.sleep(nanoseconds: 300_000_000)
        let samplesTaken = await watchdog.samplesTaken
        #expect(samplesTaken == 0)
        #expect(recorder.calls.isEmpty)
    }

    @Test("disarm() mid-run stops future sampling -- samplesTaken stops growing")
    func disarmMidRunStopsSampling() async throws {
        let recorder = CallRecorder()
        let watchdog = makeWatchdog(footprints: [10 * 1_048_576], recorder: recorder)
        await watchdog.arm(rootPid: rootPid())
        let sampledSome = await waitUntil { await watchdog.samplesTaken >= 3 }
        #expect(sampledSome)
        await watchdog.disarm()
        // AT MOST one more sample can land after `disarm()` returns: a loop iteration that had
        // already passed its `stillArmed` gate (actor-isolated, so this is the one place a benign
        // race is possible) before `disarm()`'s effect became visible. 50 ms is five poll
        // intervals at this test's 10 ms cadence -- ample time for that single in-flight sample,
        // if any, to land and "settle". The REAL proof that the loop has genuinely stopped is
        // comparing two reads AFTER that settling point: if it were still looping, the second
        // read would be higher than the first.
        try await Task.sleep(nanoseconds: 50_000_000)
        let settled = await watchdog.samplesTaken
        try await Task.sleep(nanoseconds: 200_000_000)
        let afterWaiting = await watchdog.samplesTaken
        #expect(afterWaiting == settled, "samplesTaken must stop changing once disarmed")
    }

    @Test("re-arming revokes the previous epoch -- an old, still-in-flight loop iteration never kills using new state")
    func rearmingRevokesThePreviousEpoch() async throws {
        let recorder = CallRecorder()
        // First arming: would kill immediately if it ever got to sample.
        let watchdog = SingingSidecarWatchdog(configuration: .init(
            capBytes: 1, pollIntervalSeconds: 0.01,
            sampleFootprintBytes: { _ in 1_048_576 },
            pidIsAlive: { _ in true },
            kill: { pid, identity in recorder.record(pid, identity); return true }))
        await watchdog.arm(rootPid: 111)
        // Re-arm immediately, before the first poll interval elapses, with a DIFFERENT pid --
        // this is NOT the FIX NOW #3 idempotent case (same pid); a genuinely different pid must
        // still get the full revoke-and-reset treatment.
        await watchdog.arm(rootPid: 222)

        let killed = await waitUntil { !recorder.calls.isEmpty }
        #expect(killed, "the second arming's cap of 1 byte must still kill eventually")
        #expect(recorder.calls.allSatisfy { $0.0 == 222 }, "only the SECOND arming's pid may ever be killed")
    }

    @Test("clearLastKillReason() clears a previous boot's kill record")
    func clearLastKillReasonClearsIt() async throws {
        let recorder = CallRecorder()
        let watchdog = makeWatchdog(capBytes: 1, footprints: [1_048_576], recorder: recorder)
        await watchdog.arm(rootPid: rootPid())
        let killed = await waitUntil { await watchdog.lastKillReason != nil }
        #expect(killed)
        await watchdog.clearLastKillReason()
        let cleared = await watchdog.lastKillReason
        #expect(cleared == nil)
    }

    @Test("2 consecutive Critical samples kill even with a footprint far under the cap, end to end through the loop")
    func consecutiveCriticalKillsThroughTheLoop() async throws {
        let recorder = CallRecorder()
        let watchdog = makeWatchdog(
            footprints: [1024], recentCritical: [true, true], recorder: recorder)
        await watchdog.arm(rootPid: rootPid())
        let killed = await waitUntil { !recorder.calls.isEmpty }
        #expect(killed)
        let reason = await watchdog.lastKillReason
        #expect(reason?.localizedCaseInsensitiveContains("pressure") == true
                || reason?.localizedCaseInsensitiveContains("critical") == true)
        let trigger = await watchdog.lastKillTrigger
        #expect(trigger == .pressure)
    }

    // MARK: - FIX NOW #3(a) (architect review): arm is idempotent for the SAME pid

    @Test("FIX NOW #3(a): re-arming the SAME pid every 10 ms for 1 s at a 50 ms poll does not restart the loop — samples still land, and a Critical kill still fires")
    func idempotentRearmSurvivesAStormAndStillKills() async throws {
        let recorder = CallRecorder()
        let watchdog = SingingSidecarWatchdog(configuration: .init(
            capBytes: 512 * 1_048_576,
            pollIntervalSeconds: 0.05,
            sampleFootprintBytes: { _ in 10 * 1_048_576 },   // always under cap -- isolates from footprint kills
            readMemoryPressureCritical: { true },             // every sample that lands reads Critical
            pidIsAlive: { _ in true },
            kill: { pid, identity in recorder.record(pid, identity); return true }))
        await watchdog.arm(rootPid: rootPid())
        // The re-arm storm: faster than the poll interval (10 ms vs 50 ms), simulating a caller
        // polling `status()` well above the rate the architect's Q3 finding named as sufficient
        // to defeat both kill rules under the OLD (always-revoke) `arm`.
        for _ in 0..<100 {
            await watchdog.arm(rootPid: rootPid())
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        // Coordinator-measured (2026-10-05): a 2s wall-clock bound intermittently undershoots a
        // real system stall this suite has independently measured at ~3.3-3.5s elsewhere this
        // session. Widened to 10s -- pure safety margin, costs nothing on the happy path since
        // `waitUntil` returns the instant its condition is met.
        let sampledDuringOrAfterStorm = await waitUntil(timeoutSeconds: 10) {
            await watchdog.samplesTaken >= 10
        }
        #expect(sampledDuringOrAfterStorm, "idempotent re-arming must not have restarted the loop's debounce window")
        let killed = await waitUntil(timeoutSeconds: 10) { !recorder.calls.isEmpty }
        #expect(killed, "2 consecutive Critical samples must still kill despite the re-arm storm")
    }

    // MARK: - FIX NOW #4(a) (architect review): the loop stops owning a pid it has lost

    @Test("FIX NOW #4(a): once the tracked pid is gone (ESRCH), the loop disarms WITHOUT calling kill")
    func disarmsWithoutKillingWhenPidIsGone() async throws {
        let recorder = CallRecorder()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["0.2"]
        try process.run()
        let pid = process.processIdentifier

        let watchdog = SingingSidecarWatchdog(configuration: .init(
            capBytes: 512 * 1_048_576,
            // The FIRST poll fires well after the 0.2 s sleep has already exited.
            pollIntervalSeconds: 0.4,
            sampleFootprintBytes: { _ in 10 * 1_048_576 },
            readMemoryPressureCritical: { true },   // would WANT to kill, if it ever got to sample
            // `pidIsAlive` left at its REAL default (`Darwin.kill(pid, 0) == 0`) — this IS the
            // mechanism under test, not a spy.
            kill: { killedPid, identity in recorder.record(killedPid, identity); return true }))
        await watchdog.arm(rootPid: pid)
        process.waitUntilExit()   // confirm the sleep is really gone before the loop's first poll

        // Coordinator-measured (2026-10-05, orchestrator verify): intermittent at 2s under a
        // system stall this suite has independently measured at ~3.3-3.5s elsewhere this
        // session. Widened to 10s -- pure safety margin, costs nothing on the happy path.
        let disarmed = await waitUntil(timeoutSeconds: 10) { await watchdog.isArmed == false }
        #expect(disarmed, "the loop must disarm itself once it finds the tracked pid gone")
        #expect(recorder.calls.isEmpty, "a pid that is already gone must never be reported to kill")
    }

    // MARK: - FIX NOW #4(b) (architect review): killTree re-checks identity before signalling

    @Test("FIX NOW #4(b): killTree refuses to signal a pid that is alive but is NOT the sidecar")
    func killTreeRefusesANonSidecarPid() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        // Coordinator-measured (2026-10-05): a short fixed lifetime here is a SECOND, DISTINCT
        // bug from the one `waitUntil` fixes -- under severe load the suite has been measured
        // taking 8-9s, which would EXCEED a 5s sleep regardless of anything the watchdog does,
        // making the fixture die of old age and misread as a wrongful kill. 120s comfortably
        // exceeds the 10s poll bound plus any plausible stall; the test's own `defer` below kills
        // it pid-exact long before that regardless of outcome.
        process.arguments = ["120"]
        try process.run()
        let pid = process.processIdentifier
        defer {
            // The test's own cleanup: kill its own sleep, pid-exact, regardless of outcome.
            if kill(pid, 0) == 0 { kill(pid, SIGTERM) }
        }

        let sidecarIdentity = SidecarStop.Identity(
            argsPattern: #"(^|/)sing/(server|stub_server)\.py(\s|$)"#)
        let watchdog = SingingSidecarWatchdog(configuration: .init(
            capBytes: 1,   // 1 byte -- the injected footprint below is instantly over the cap
            pollIntervalSeconds: 0.05,
            sampleFootprintBytes: { _ in 1_048_576 },
            identity: sidecarIdentity
            // `kill` left at its REAL default (`SingingSidecarWatchdog.killTree`) — this IS the
            // mechanism under test, not a spy.
        ))
        await watchdog.arm(rootPid: pid)
        // Coordinator-directed fix (2026-10-05, orchestrator verify): a FIXED wall-clock sleep
        // here was the root cause of an intermittent failure, MEASURED (not guessed) via a
        // forced-race diagnostic -- the loop's `.kill` case sets `lastKillReason` (inside
        // `recordSample`, a pure bookkeeping side effect) BEFORE it calls `config.kill(...)` and,
        // if refused, clears it again; that gap is normally nanoseconds wide, but a severe system
        // stall can delay the loop's OWN progress enough that a fixed-time test wakes up WHILE
        // the gap is still open, reading the transient non-nil value. The diagnostic (41/41
        // samples, real `killTree`, real identity check) confirmed the target is ALWAYS still
        // alive during that window -- never a wrongful kill, purely a stale read. Fix: wait on
        // the loop's OWN completion signal (`isArmed == false`, which is only set true AFTER the
        // kill case, including any refusal-clearing, has fully finished) instead of wall time.
        let disarmed = await waitUntil(timeoutSeconds: 10) { await watchdog.isArmed == false }
        #expect(disarmed, "the loop must have reached and fully finished processing its kill decision")
        #expect(kill(pid, 0) == 0, "a `/bin/sleep`, not the sidecar, must survive the kill decision")
        let reason = await watchdog.lastKillReason
        #expect(reason == nil, "a kill the identity check REFUSED must not be recorded as a kill -- lastKillReason must stay nil")
    }
}
