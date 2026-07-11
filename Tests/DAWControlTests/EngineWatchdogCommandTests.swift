import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M9 (crash-c) `engine.watchdogStatus`: the
/// engine-watchdog state read. The state machine itself is pinned in
/// DAWEngine's `EngineWatchdogTests`; here we pin the wire shape, the
/// headless zero/idle contract, and the no-params tolerance.
@MainActor
@Suite("Engine watchdog status — control protocol")
struct EngineWatchdogCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    @Test("allCommands advertises engine.watchdogStatus")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("engine.watchdogStatus"))
    }

    @Test("headless: the wire shape is the zero/idle status")
    func headlessIdleShape() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.watchdogStatus"))
        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "idle")
        #expect(response.result?["restartCount"]?.doubleValue == 0)
        #expect(response.result?["consecutiveFailures"]?.doubleValue == 0)
        #expect(response.result?["lastHeartbeat"]?.doubleValue == 0)
        #expect(response.result?["engineRunning"]?.boolValue == false)
    }

    @Test("an engine's watchdog status threads through the store onto the wire")
    func engineStatusThreadsThrough() async throws {
        let (router, store) = makeRouter()
        let engine = FakeWatchdogEngine()
        engine.status = EngineWatchdogStatus(
            state: .recovering, restartCount: 2, consecutiveFailures: 1,
            lastHeartbeat: 987_654, engineRunning: true)
        store.engine = engine

        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.watchdogStatus"))
        #expect(response.ok)
        #expect(response.result?["state"]?.stringValue == "recovering")
        #expect(response.result?["restartCount"]?.doubleValue == 2)
        #expect(response.result?["consecutiveFailures"]?.doubleValue == 1)
        #expect(response.result?["lastHeartbeat"]?.doubleValue == 987_654)
        #expect(response.result?["engineRunning"]?.boolValue == true)
        #expect(engine.reads == 1)
    }

    @Test("no params required; unknown extras are ignored (house style)")
    func noParamsTolerance() async throws {
        let (router, store) = makeRouter()
        let engine = FakeWatchdogEngine()
        engine.status = EngineWatchdogStatus(
            state: .ok, restartCount: 1, consecutiveFailures: 0,
            lastHeartbeat: 42, engineRunning: true)
        store.engine = engine

        let sloppy = await router.handle(ControlRequest(
            id: "1", command: "engine.watchdogStatus",
            params: ["bogus": .number(7), "reset": .bool(true)]))
        #expect(sloppy.ok)
        #expect(sloppy.result?["state"]?.stringValue == "ok")
        #expect(sloppy.result?["restartCount"]?.doubleValue == 1)
    }
}

/// Minimal engine fake: only the watchdog surface matters; everything else
/// rides the protocol's optional-capability defaults (the perf-b fake shape).
@MainActor
private final class FakeWatchdogEngine: AudioEngineControlling {
    var status: EngineWatchdogStatus = .idle
    private(set) var reads = 0

    func watchdogStatus() -> EngineWatchdogStatus {
        reads += 1
        return status
    }

    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var isRunning = false
    func prepare() throws {}
    func shutdown() {}
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func renderMixdown(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        throw ProjectError.engineUnavailable
    }
    var recordPermission: RecordPermission { .granted }
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        completion(true)
    }
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        throw ProjectError.engineUnavailable
    }
    func stopRecording() {}
}
