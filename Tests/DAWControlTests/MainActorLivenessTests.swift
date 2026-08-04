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

    /// m23-av: a fixed, fake in-flight array. No engine, no clock, no sleeps —
    /// the queue tier's job is to RELAY what the ledger produced, and that is
    /// the only thing these legs assert about it.
    private static let fakeInFlight: [EngineAUPrepareStats.InFlightEntry] = [
        .init(slot: "instrument", id: "11111111-2222-3333-4444-555555555555",
              component: AudioUnitComponentID(subType: "VmbA", manufacturer: "VmbA"),
              startedSecondsAgo: 61.9, deadlineSeconds: 10, overdue: true),
    ]
    private static let fakeInFlightProvider:
        @Sendable () -> [EngineAUPrepareStats.InFlightEntry] = { fakeInFlight }

    @Test("responsive snapshot → nil (the normal MainActor route)")
    func responsivePassesThrough() throws {
        let snapshot = MainActorLivenessSnapshot(
            responsive: true, wedgedForSeconds: nil, pingsSent: 5,
            pongsReceived: 5, lastWedgeDurationSeconds: nil,
            wedgeThresholdSeconds: 2.5)
        #expect(ControlServer.wedgeIntercept(
            try frame(command: "project.snapshot"), snapshot: snapshot,
            inFlight: Self.fakeInFlightProvider) == nil)
        #expect(ControlServer.wedgeIntercept(
            try frame(command: "engine.watchdogStatus"), snapshot: snapshot,
            inFlight: Self.fakeInFlightProvider) == nil)
        // W4 — m23-av: a RESPONSIVE snapshot must take the normal route for
        // the new verb too. A provider that is present must not tempt the
        // queue tier into answering when it does not need to.
        #expect(ControlServer.wedgeIntercept(
            try frame(command: "engine.auPrepareStats"), snapshot: snapshot,
            inFlight: Self.fakeInFlightProvider) == nil)
    }

    @Test("wedged: engine.watchdogStatus answers off-main — mainActor carries the story, engine fields honestly omitted")
    func watchdogStatusAnsweredFromSnapshot() throws {
        let response = ControlServer.wedgeIntercept(
            try frame(command: "engine.watchdogStatus"), snapshot: wedgedSnapshot,
            inFlight: Self.fakeInFlightProvider)
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
        // m23-av: the watchdog's own payload gains NOTHING. `inFlight` rides
        // engine.auPrepareStats, which is the verb that claims to answer
        // "what is the AU host doing".
        #expect(unwrapped.result?["inFlight"] == nil)
    }

    // MARK: - m23-av: engine.auPrepareStats during a wedge

    /// W1 — the item's headline: the verb that was UNANSWERABLE during a wedge
    /// now answers, with the ledger's array relayed verbatim.
    @Test("wedged: engine.auPrepareStats answers off-main with the in-flight ledger, not the teaching error")
    func auPrepareStatsAnsweredFromLedger() throws {
        let response = ControlServer.wedgeIntercept(
            try frame(command: "engine.auPrepareStats"), snapshot: wedgedSnapshot,
            inFlight: Self.fakeInFlightProvider)
        let unwrapped = try #require(response)
        #expect(unwrapped.ok)
        #expect(unwrapped.id == "7")
        #expect(unwrapped.result?["mainActor"]?["responsive"]?.boolValue == false)
        #expect(unwrapped.result?["mainActor"]?["wedgedForSeconds"]?.doubleValue == 3.4)

        let entry = try #require(unwrapped.result?["inFlight"]?.arrayValue?.first)
        #expect(unwrapped.result?["inFlight"]?.arrayValue?.count == 1)
        #expect(entry["slot"]?.stringValue == "instrument")
        #expect(entry["id"]?.stringValue == "11111111-2222-3333-4444-555555555555")
        #expect(entry["startedSecondsAgo"]?.doubleValue == 61.9)
        #expect(entry["deadlineSeconds"]?.doubleValue == 10)
        #expect(entry["overdue"]?.boolValue == true)
        // The component rides in the wire's ONE spelling — an object, never a
        // second string form like "aumu/VmbA/VmbA".
        #expect(entry["component"]?["type"]?.stringValue == "aumu")
        #expect(entry["component"]?["subType"]?.stringValue == "VmbA")
        #expect(entry["component"]?["manufacturer"]?.stringValue == "VmbA")
    }

    /// W2 — the main-actor-produced fields are ABSENT, not zero. Emitting
    /// `instrumentPrepares: 0` during a wedge would be a lie the caller cannot
    /// detect; this is the `engine.watchdogStatus` honesty rule applied to the
    /// same problem.
    @Test("wedged: the auPrepareStats payload OMITS the counters and arrays rather than zeroing them")
    func wedgedPayloadOmitsMainActorProducedFields() throws {
        let response = ControlServer.wedgeIntercept(
            try frame(command: "engine.auPrepareStats"), snapshot: wedgedSnapshot,
            inFlight: Self.fakeInFlightProvider)
        let unwrapped = try #require(response)
        #expect(unwrapped.result?["instrumentPrepares"] == nil)
        #expect(unwrapped.result?["instrumentReleases"] == nil)
        #expect(unwrapped.result?["effectPrepares"] == nil)
        #expect(unwrapped.result?["effectReleases"] == nil)
        #expect(unwrapped.result?["tracks"] == nil)
        #expect(unwrapped.result?["effects"] == nil)
        // The whole key set, so a later additive field has to be considered
        // here rather than sliding in unnoticed.
        #expect(unwrapped.result?.objectValue?.keys.sorted() == ["inFlight", "mainActor"])
    }

    /// W6 — THE HONESTY HOLE. With no provider injected the server does not
    /// know whether anything is in flight, so it says NOTHING. `inFlight: []`
    /// would assert "nothing is in flight" — false under a doctrine literally
    /// named detection and honesty. The payload degrades to exactly the
    /// watchdog answer, which says nothing untrue.
    @Test("wedged with a NIL in-flight provider: the inFlight key is OMITTED, never an empty array")
    func nilProviderOmitsTheKeyEntirely() throws {
        let response = ControlServer.wedgeIntercept(
            try frame(command: "engine.auPrepareStats"), snapshot: wedgedSnapshot,
            inFlight: nil)
        let unwrapped = try #require(response)
        #expect(unwrapped.ok)
        #expect(unwrapped.result?["mainActor"]?["responsive"]?.boolValue == false)
        #expect(unwrapped.result?["inFlight"] == nil)
        #expect(unwrapped.result?.objectValue?.keys.sorted() == ["mainActor"])

        // ANTI-BLINDNESS CONTROL: `JSONValue`'s subscript returns nil for an
        // ABSENT key and `.array([])` for a present empty array, so the
        // assertion above really does discriminate the two.
        let emptyArray = JSONValue.object(["inFlight": .array([])])
        #expect(emptyArray["inFlight"] == .array([]))
        #expect(emptyArray["inFlight"] != nil)
    }

    /// W3 — widening the allow-list must not widen it to everything.
    @Test("wedged: any other verb gets the teaching error VERBATIM, not a hang")
    func otherVerbGetsTeachingError() throws {
        let response = ControlServer.wedgeIntercept(
            try frame(id: "42", command: "project.snapshot"), snapshot: wedgedSnapshot,
            inFlight: Self.fakeInFlightProvider)
        let unwrapped = try #require(response)
        #expect(!unwrapped.ok)
        #expect(unwrapped.id == "42")
        #expect(unwrapped.error
            == "main actor has been unresponsive for 3.4 s — the app UI is wedged; "
            + "engine.watchdogStatus reports liveness and engine.auPrepareStats "
            + "reports any AU prepare still in flight; other commands cannot run "
            + "until it recovers.")
        // A verb refused by the allow-list gets NO payload at all — the
        // teaching error is the whole answer.
        #expect(unwrapped.result == nil)
    }

    @Test("wedged: malformed JSON is still answered on the queue tier")
    func malformedStillAnswered() throws {
        let response = ControlServer.wedgeIntercept(
            Data("not json".utf8), snapshot: wedgedSnapshot,
            inFlight: Self.fakeInFlightProvider)
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

    /// W5 — m23-av: the healthy `engine.auPrepareStats` response carries the
    /// same discriminator. It is what lets a client tell the full form from
    /// the wedged partial one WITHOUT counting keys.
    @Test("healthy path: engine.auPrepareStats gains mainActor.responsive:true alongside the full counters")
    @MainActor
    func healthyPrepareStatsCarriesAdditiveField() async throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let router = CommandRouter(store: store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.auPrepareStats"))
        #expect(response.ok)
        #expect(response.result?["mainActor"]?["responsive"]?.boolValue == true)
        // The counters stay intact — additive means ADDITIVE. This is also
        // what distinguishes the healthy form from the wedged one, where they
        // are absent.
        #expect(response.result?["instrumentPrepares"]?.doubleValue == 0)
        #expect(response.result?["tracks"]?.arrayValue?.isEmpty == true)
        // Headless: no engine, so nothing can be in flight — and here `[]` is
        // the TRUTH, produced by the ledger, not a guess by the wire tier.
        #expect(response.result?["inFlight"]?.arrayValue?.isEmpty == true)
    }
}
