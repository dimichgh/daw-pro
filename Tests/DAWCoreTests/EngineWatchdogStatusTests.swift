import Foundation
import Testing
@testable import DAWCore

/// M9 crash-c: the `EngineWatchdogStatus` snapshot type and its
/// optional-capability plumbing — Codable round trip (states encode as
/// plain JSON strings), the `.idle` contract, the protocol default, and the
/// headless store passthrough (the perf-b suite's shape).
@MainActor
@Suite("Engine watchdog status — DAWCore snapshot")
struct EngineWatchdogStatusTests {

    private func sample() -> EngineWatchdogStatus {
        EngineWatchdogStatus(state: .recovering, restartCount: 2,
                             consecutiveFailures: 1, lastHeartbeat: 123_456,
                             engineRunning: true)
    }

    @Test("Codable round trip preserves every field; state is a plain JSON string")
    func codableRoundTrip() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EngineWatchdogStatus.self, from: data)
        #expect(decoded == original)

        // The wire shape: {state: "idle"|"ok"|"recovering"|"failed", ...}.
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["state"] as? String == "recovering")
        for state in [EngineWatchdogStatus.State.idle, .ok, .recovering, .failed] {
            #expect(["idle", "ok", "recovering", "failed"].contains(state.rawValue))
        }
    }

    @Test(".idle is the zero default")
    func idleIsZeroDefault() {
        let idle = EngineWatchdogStatus.idle
        #expect(idle.state == .idle)
        #expect(idle.restartCount == 0)
        #expect(idle.consecutiveFailures == 0)
        #expect(idle.lastHeartbeat == 0)
        #expect(!idle.engineRunning)
    }

    @Test("protocol default: engines without a watchdog report .idle")
    func protocolDefaultIsIdle() {
        // FakeEngine (CoreTests.swift) rides the optional-capability default.
        let engine = FakeEngine()
        #expect(engine.watchdogStatus() == .idle)
    }

    @Test("store passthrough: headless reads .idle, an engine's status threads through")
    func storePassthrough() {
        let store = ProjectStore()
        #expect(store.watchdogStatus() == .idle)

        let engine = FakeWatchdogEngine()
        engine.status = sample()
        store.engine = engine
        #expect(store.watchdogStatus() == sample())
        #expect(engine.reads == 1)
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
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
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
