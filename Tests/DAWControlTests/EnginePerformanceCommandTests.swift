import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M9 (perf-b) `engine.performanceStats`: the
/// render-load/overrun telemetry read (and read-then-reset) command. The
/// counter math itself is pinned in DAWEngine's `EnginePerformanceTests`;
/// here we pin the wire shape, the reset-param threading, and the headless
/// all-zero contract.
@MainActor
@Suite("Engine performance stats — control protocol")
struct EnginePerformanceCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    @Test("allCommands advertises engine.performanceStats")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("engine.performanceStats"))
    }

    @Test("headless: the wire shape is the full all-zero window")
    func headlessZeroShape() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.performanceStats"))
        #expect(response.ok)

        for field in ["callbackCount", "renderedFrames", "renderTimeNs",
                      "peakCallbackNs", "overrunCount", "quantumFrames"] {
            #expect(response.result?[field]?.doubleValue == 0, "\(field)")
        }
        for field in ["averageLoad", "recentLoad", "sampleRate",
                      "sinceResetSeconds"] {
            let value = try #require(response.result?[field]?.doubleValue, "\(field)")
            #expect(value == 0, "\(field)")
            #expect(value.isFinite, "\(field)")
        }
    }

    @Test("an engine's stats thread through the store onto the wire")
    func engineStatsThreadThrough() async throws {
        let (router, store) = makeRouter()
        let engine = FakePerformanceEngine()
        engine.stats = EnginePerformanceStats(
            callbackCount: 96, renderedFrames: 49_152,
            renderTimeNs: 12_500_000, peakCallbackNs: 400_000,
            overrunCount: 2, averageLoad: 0.0122, recentLoad: 0.03125,
            sampleRate: 48_000, quantumFrames: 512, sinceResetSeconds: 2.5)
        store.engine = engine

        let response = await router.handle(ControlRequest(
            id: "1", command: "engine.performanceStats"))
        #expect(response.ok)
        #expect(response.result?["callbackCount"]?.doubleValue == 96)
        #expect(response.result?["renderedFrames"]?.doubleValue == 49_152)
        #expect(response.result?["renderTimeNs"]?.doubleValue == 12_500_000)
        #expect(response.result?["peakCallbackNs"]?.doubleValue == 400_000)
        #expect(response.result?["overrunCount"]?.doubleValue == 2)
        #expect(response.result?["averageLoad"]?.doubleValue == 0.0122)
        #expect(response.result?["recentLoad"]?.doubleValue == 0.03125)
        #expect(response.result?["sampleRate"]?.doubleValue == 48_000)
        #expect(response.result?["quantumFrames"]?.doubleValue == 512)
        #expect(response.result?["sinceResetSeconds"]?.doubleValue == 2.5)
        // Default is a plain read — reset must NOT be requested.
        #expect(engine.resetFlags == [false])
    }

    @Test("reset param threads through; omitted/non-bool reset reads false (house style)")
    func resetParamThreading() async throws {
        let (router, store) = makeRouter()
        let engine = FakePerformanceEngine()
        store.engine = engine

        _ = await router.handle(ControlRequest(
            id: "1", command: "engine.performanceStats",
            params: ["reset": .bool(true)]))
        _ = await router.handle(ControlRequest(
            id: "2", command: "engine.performanceStats",
            params: ["reset": .bool(false)]))
        // House style for optional params: a wrong-typed value falls back to
        // the default, and unknown extra params are ignored, never an error.
        let sloppy = await router.handle(ControlRequest(
            id: "3", command: "engine.performanceStats",
            params: ["reset": .string("yes"), "bogus": .number(1)]))
        #expect(sloppy.ok)
        #expect(engine.resetFlags == [true, false, false])
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
