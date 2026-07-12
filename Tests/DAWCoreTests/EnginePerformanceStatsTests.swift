import Foundation
import Testing
@testable import DAWCore

/// M9 perf-b: the `EnginePerformanceStats` snapshot type and its
/// optional-capability plumbing — Codable round trip, the `.idle` contract,
/// the protocol default, and the headless store passthrough.
@MainActor
@Suite("Engine performance stats — DAWCore snapshot")
struct EnginePerformanceStatsTests {

    private func sample() -> EnginePerformanceStats {
        EnginePerformanceStats(
            callbackCount: 1_234, renderedFrames: 631_808,
            renderTimeNs: 87_654_321, peakCallbackNs: 2_345_678,
            overrunCount: 3, averageLoad: 0.1875, recentLoad: 0.25,
            sampleRate: 48_000, quantumFrames: 512,
            sinceResetSeconds: 13.5)
    }

    @Test("Codable round trip preserves every field")
    func codableRoundTrip() throws {
        let original = sample()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(EnginePerformanceStats.self, from: data)
        #expect(decoded == original)
    }

    @Test(".idle is the all-zero window and every field is finite")
    func idleIsAllZeroAndFinite() {
        let idle = EnginePerformanceStats.idle
        #expect(idle.callbackCount == 0)
        #expect(idle.renderedFrames == 0)
        #expect(idle.renderTimeNs == 0)
        #expect(idle.peakCallbackNs == 0)
        #expect(idle.overrunCount == 0)
        #expect(idle.averageLoad == 0)
        #expect(idle.recentLoad == 0)
        #expect(idle.sampleRate == 0)
        #expect(idle.quantumFrames == 0)
        #expect(idle.sinceResetSeconds == 0)
        for value in [idle.averageLoad, idle.recentLoad, idle.sampleRate,
                      idle.sinceResetSeconds] {
            #expect(value.isFinite)
        }
    }

    @Test("protocol default: engines without telemetry report .idle")
    func protocolDefaultIsIdle() {
        // FakeEngine (CoreTests.swift) rides the optional-capability default.
        let engine = FakeEngine()
        #expect(engine.performanceStats(reset: false) == .idle)
        #expect(engine.performanceStats(reset: true) == .idle)
    }

    @Test("store passthrough: headless reads .idle, an engine's stats and reset flag thread through")
    func storePassthrough() {
        let store = ProjectStore()
        #expect(store.performanceStats() == .idle)
        #expect(store.performanceStats(reset: true) == .idle)

        let engine = FakePerformanceEngine()
        engine.stats = sample()
        store.engine = engine
        #expect(store.performanceStats() == sample())
        #expect(engine.resetFlags == [false])
        #expect(store.performanceStats(reset: true) == sample())
        #expect(engine.resetFlags == [false, true])
    }
}

/// Minimal engine fake: only the telemetry surface matters; everything else
/// rides the protocol's optional-capability defaults (the vm-a fake shape).
@MainActor
private final class FakePerformanceEngine: AudioEngineControlling {
    var stats: EnginePerformanceStats = .idle
    private(set) var resetFlags: [Bool] = []

    func performanceStats(reset: Bool) -> EnginePerformanceStats {
        resetFlags.append(reset)
        return stats
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
