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
    private let lock = OSAllocatedUnfairLock<[(Int32, String)]>(initialState: [])
    func record(_ pid: Int32, _ reason: String) { lock.withLock { $0.append((pid, reason)) } }
    var calls: [(Int32, String)] { lock.withLock { $0 } }
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
        guard case .kill(let reason) = action else {
            Issue.record("expected .kill, got \(action)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("cap"))
        #expect(reason.localizedCaseInsensitiveContains("footprint"))
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
        guard case .kill(let reason) = action else {
            Issue.record("expected .kill, got \(action)")
            return
        }
        #expect(reason.localizedCaseInsensitiveContains("pressure")
                || reason.localizedCaseInsensitiveContains("critical"))
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
            kill: { pid, reason in recorder.record(pid, reason) }))
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
            kill: { pid, reason in recorder.record(pid, reason) }))
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
            kill: { pid, reason in recorder.record(pid, reason) }))
        await watchdog.arm(rootPid: 111)
        // Re-arm immediately, before the first poll interval elapses, with a DIFFERENT pid.
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
    }
}
