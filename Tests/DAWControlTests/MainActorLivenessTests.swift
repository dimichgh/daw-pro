import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m18-b: the main-actor wedge liveness core. The EngineWatchdog testing
/// precedent — every rule driven with INJECTED time (no wall clock, no
/// sleeps): threshold crossing, the becameWedged latch, pong recovery with the
/// retained duration, and the breadcrumb line formatters.
@Suite("Main-actor liveness — state machine")
struct MainActorLivenessStateMachineTests {

    @Test("fresh instance is responsive with zero counters")
    func freshIsResponsive() {
        let liveness = MainActorLiveness()
        #expect(liveness.state(now: 100) == .responsive)
        let snap = liveness.snapshot(now: 100)
        #expect(snap.responsive)
        #expect(snap.wedgedForSeconds == nil)
        #expect(snap.pingsSent == 0)
        #expect(snap.pongsReceived == 0)
        #expect(snap.lastWedgeDurationSeconds == nil)
        #expect(snap.wedgeThresholdSeconds == MainActorLiveness.defaultWedgeThresholdSeconds)
    }

    @Test("an answered ping stays responsive forever after")
    func answeredPingStaysResponsive() {
        var liveness = MainActorLiveness()
        liveness.recordPing(now: 0)
        #expect(liveness.recordPong(now: 0.01) == nil)
        #expect(liveness.state(now: 100) == .responsive)
        #expect(liveness.pingsSent == 1)
        #expect(liveness.pongsReceived == 1)
    }

    @Test("an unanswered ping AT the threshold is still responsive (strictly-older rule)")
    func atThresholdStillResponsive() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        #expect(liveness.state(now: 2.5) == .responsive)
    }

    @Test("an unanswered ping past the threshold is wedged, with a growing duration")
    func overThresholdIsWedged() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        #expect(liveness.state(now: 3) == .wedged(forSeconds: 3))
        #expect(liveness.state(now: 10) == .wedged(forSeconds: 10))
    }

    @Test("later pings queued behind a wedge keep the ORIGINAL anchor — the wedge never looks younger")
    func laterPingsKeepOriginalAnchor() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        liveness.recordPing(now: 1)
        liveness.recordPing(now: 2)
        #expect(liveness.state(now: 4) == .wedged(forSeconds: 4))
        #expect(liveness.pingsSent == 3)
    }

    @Test("check() latches becameWedged exactly once per wedge")
    func checkLatchesOnce() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        #expect(liveness.check(now: 1) == nil)   // under threshold
        #expect(liveness.check(now: 3) == .becameWedged(unresponsiveForSeconds: 3))
        #expect(liveness.check(now: 4) == nil)   // latched — one breadcrumb per wedge
    }

    @Test("a pong recovers a declared wedge and retains the total duration")
    func pongRecovers() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        _ = liveness.check(now: 3)
        #expect(liveness.recordPong(now: 10) == .recovered(totalWedgeSeconds: 10))
        #expect(liveness.state(now: 10.1) == .responsive)
        let snap = liveness.snapshot(now: 10.1)
        #expect(snap.responsive)
        #expect(snap.lastWedgeDurationSeconds == 10)   // retained for reporting
    }

    @Test("a pong with no declared wedge is a plain heartbeat — nil transition")
    func pongWithoutWedgeIsSilent() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        #expect(liveness.recordPong(now: 0.5) == nil)
        #expect(liveness.lastWedgeDurationSeconds == nil)
    }

    @Test("a second wedge after recovery runs a full fresh cycle and updates the retained duration")
    func rewedgeAfterRecovery() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        _ = liveness.check(now: 3)
        _ = liveness.recordPong(now: 10)

        liveness.recordPing(now: 20)
        #expect(liveness.check(now: 23) == .becameWedged(unresponsiveForSeconds: 3))
        #expect(liveness.recordPong(now: 25) == .recovered(totalWedgeSeconds: 5))
        #expect(liveness.snapshot(now: 26).lastWedgeDurationSeconds == 5)
    }

    @Test("the wedged snapshot carries the story the queue tier serves")
    func snapshotWhileWedged() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        liveness.recordPing(now: 1)
        let snap = liveness.snapshot(now: 4)
        #expect(!snap.responsive)
        #expect(snap.wedgedForSeconds == 4)
        #expect(snap.pingsSent == 2)
        #expect(snap.pongsReceived == 0)
        #expect(snap.wedgeThresholdSeconds == 2.5)
    }

    @Test("snapshot is wedged even before check() ran — frame-time truth, not tick granularity")
    func snapshotIndependentOfCheck() {
        var liveness = MainActorLiveness(wedgeThresholdSeconds: 2.5)
        liveness.recordPing(now: 0)
        // No check() tick yet — the queue tier still must see the wedge.
        #expect(liveness.snapshot(now: 5).responsive == false)
        #expect(liveness.snapshot(now: 5).wedgedForSeconds == 5)
    }

    @Test("breadcrumb line formatters — verbatim, ISO8601, one decimal")
    func breadcrumbLines() {
        let epoch = Date(timeIntervalSince1970: 0)
        #expect(MainActorLiveness.wedgeLine(
            unresponsiveForSeconds: 2.6, thresholdSeconds: 2.5, timestamp: epoch)
            == "1970-01-01T00:00:00Z WEDGED main actor unresponsive for 2.6 s (threshold 2.5 s)")
        #expect(MainActorLiveness.recoveryLine(totalWedgeSeconds: 10.3, timestamp: epoch)
            == "1970-01-01T00:00:00Z RECOVERED main actor responsive again after 10.3 s wedged")
    }

    @Test("a fresh monitor snapshot (injected clock, timer never started) is responsive")
    func monitorFreshSnapshot() {
        let monitor = MainActorLivenessMonitor(
            clock: { 42 }, breadcrumb: { _ in })
        let snap = monitor.snapshot()
        #expect(snap.responsive)
        #expect(snap.pingsSent == 0)
        #expect(snap.pongsReceived == 0)
    }
}

/// m18-b: the ControlServer QUEUE-TIER interception — the decision the server
/// makes on its own serial queue BEFORE the MainActor hop, exercised here with
/// fake snapshots (no sockets, no wall time; the live socket path is gated in
/// staging). During a wedge `engine.watchdogStatus` answers from the snapshot
/// and every other verb gets the teaching error VERBATIM — never a silent hang.
@Suite("Main-actor wedge — queue-tier interception")
struct WedgeInterceptionTests {

    private func frame(id: String = "7", command: String) throws -> Data {
        try JSONEncoder().encode(ControlRequest(id: id, command: command))
    }

    private var wedgedSnapshot: MainActorLivenessSnapshot {
        MainActorLivenessSnapshot(
            responsive: false, wedgedForSeconds: 3.4, pingsSent: 12,
            pongsReceived: 8, lastWedgeDurationSeconds: nil,
            wedgeThresholdSeconds: 2.5)
    }

    @Test("responsive snapshot → nil (the normal MainActor route)")
    func responsivePassesThrough() throws {
        let snapshot = MainActorLivenessSnapshot(
            responsive: true, wedgedForSeconds: nil, pingsSent: 5,
            pongsReceived: 5, lastWedgeDurationSeconds: nil,
            wedgeThresholdSeconds: 2.5)
        #expect(ControlServer.wedgeIntercept(
            try frame(command: "project.snapshot"), snapshot: snapshot) == nil)
        #expect(ControlServer.wedgeIntercept(
            try frame(command: "engine.watchdogStatus"), snapshot: snapshot) == nil)
    }

    @Test("wedged: engine.watchdogStatus answers off-main — mainActor carries the story, engine fields honestly omitted")
    func watchdogStatusAnsweredFromSnapshot() throws {
        let response = ControlServer.wedgeIntercept(
            try frame(command: "engine.watchdogStatus"), snapshot: wedgedSnapshot)
        let unwrapped = try #require(response)
        #expect(unwrapped.ok)
        #expect(unwrapped.id == "7")
        #expect(unwrapped.result?["mainActor"]?["responsive"]?.boolValue == false)
        #expect(unwrapped.result?["mainActor"]?["wedgedForSeconds"]?.doubleValue == 3.4)
        // Engine watchdog fields are PRODUCED on the main actor — during a
        // wedge they are omitted, never served stale.
        #expect(unwrapped.result?["state"] == nil)
        #expect(unwrapped.result?["restartCount"] == nil)
        #expect(unwrapped.result?["engineRunning"] == nil)
    }

    @Test("wedged: any other verb gets the teaching error VERBATIM, not a hang")
    func otherVerbGetsTeachingError() throws {
        let response = ControlServer.wedgeIntercept(
            try frame(id: "42", command: "project.snapshot"), snapshot: wedgedSnapshot)
        let unwrapped = try #require(response)
        #expect(!unwrapped.ok)
        #expect(unwrapped.id == "42")
        #expect(unwrapped.error
            == "main actor has been unresponsive for 3.4 s — the app UI is wedged; "
            + "engine.watchdogStatus reports liveness; other commands cannot run "
            + "until it recovers.")
    }

    @Test("wedged: malformed JSON is still answered on the queue tier")
    func malformedStillAnswered() throws {
        let response = ControlServer.wedgeIntercept(
            Data("not json".utf8), snapshot: wedgedSnapshot)
        let unwrapped = try #require(response)
        #expect(!unwrapped.ok)
        #expect(unwrapped.id == "?")
        #expect(unwrapped.error?.contains("malformed request JSON") == true)
    }

    @Test("healthy path: engine.watchdogStatus gains the additive mainActor.responsive:true next to the full engine fields")
    @MainActor
    func healthyResponseCarriesAdditiveField() async throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let router = CommandRouter(store: store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.watchdogStatus"))
        #expect(response.ok)
        #expect(response.result?["mainActor"]?["responsive"]?.boolValue == true)
        // The engine fields stay intact — additive means ADDITIVE.
        #expect(response.result?["state"]?.stringValue == "idle")
        #expect(response.result?["engineRunning"]?.boolValue == false)
    }
}
