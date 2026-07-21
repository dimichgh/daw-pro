import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Engine fake for `mixer.liveLoudness` (m22-c): a settable snapshot plus
/// reset bookkeeping — reset:true must reset THEN return the fresh (empty)
/// snapshot, which is exactly what the real engine's cache does.
@MainActor
private final class FakeLiveLoudnessEngine: AudioEngineControlling {
    var snapshot = LiveLoudnessSnapshot.empty
    private(set) var resetCount = 0
    private(set) var lastResetFlag: Bool?

    func liveLoudness(reset: Bool) -> LiveLoudnessSnapshot? {
        lastResetFlag = reset
        if reset {
            resetCount += 1
            snapshot = .empty
        }
        return snapshot
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
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
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

/// Control-protocol coverage for m22-c `mixer.liveLoudness`: registration
/// (additive-at-END law), wire shape + nil-omission honesty, reset
/// semantics, unknown-key teaching, and the headless / no-capability
/// engineUnavailable path. The DSP truth behind the snapshot is proven by
/// DAWCoreTests (LRA fixtures + the offline-convergence gate) and the
/// engine wrapper by DAWEngineTests/LiveLoudnessAnalyzerTests.
@MainActor
@Suite("Live loudness — control protocol (m22-c)")
struct LiveLoudnessCommandTests {
    private func makeRouter(engine: FakeLiveLoudnessEngine? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    @Test("advertised at the END of allCommands (additive-at-end law); count 143 -> 144 (148 as of m22-g's reference.*)")
    func advertisedAtEnd() {
        #expect(CommandRouter.allCommands.contains("mixer.liveLoudness"))
        // m22-g's reference.* quartet appended after it — no longer LAST,
        // but the additive-at-end law held at ITS landing.
        #expect(CommandRouter.allCommands.count == 152)
        // Additive: the mixer.* neighbors are untouched.
        #expect(CommandRouter.allCommands.contains("mixer.setMasterVolume"))
        #expect(CommandRouter.allCommands.contains("mixer.masterAnalysis"))
    }

    @Test("happy path: the engine snapshot rides the wire verbatim")
    func happyPath() async throws {
        let engine = FakeLiveLoudnessEngine()
        engine.snapshot = LiveLoudnessSnapshot(
            momentaryLufs: -18.5, shortTermLufs: -19.25, maxMomentaryLufs: -15,
            maxShortTermLufs: -16.5, integratedLufs: -20.125, loudnessRangeLu: 6.5,
            truePeakDbtp: -0.8, dcOffset: 0.001, crestFactorDb: 12.5,
            secondsAnalyzed: 42.5)
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(response.ok, "mixer.liveLoudness failed: \(response.error ?? "?")")
        #expect(response.result?["momentaryLufs"]?.doubleValue == -18.5)
        #expect(response.result?["shortTermLufs"]?.doubleValue == -19.25)
        #expect(response.result?["maxMomentaryLufs"]?.doubleValue == -15)
        #expect(response.result?["maxShortTermLufs"]?.doubleValue == -16.5)
        #expect(response.result?["integratedLufs"]?.doubleValue == -20.125)
        #expect(response.result?["loudnessRangeLu"]?.doubleValue == 6.5)
        #expect(response.result?["truePeakDbtp"]?.doubleValue == -0.8)
        #expect(response.result?["dcOffset"]?.doubleValue == 0.001)
        #expect(response.result?["crestFactorDb"]?.doubleValue == 12.5)
        #expect(response.result?["secondsAnalyzed"]?.doubleValue == 42.5)
        // Plain read: no reset happened.
        #expect(engine.resetCount == 0)
        #expect(engine.lastResetFlag == false)
    }

    @Test("nil fields are OMITTED on the wire (nil = no evidence, never 0)")
    func nilOmission() async throws {
        let engine = FakeLiveLoudnessEngine()
        engine.snapshot = LiveLoudnessSnapshot(truePeakDbtp: -12, secondsAnalyzed: 0.3)
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(response.ok)
        #expect(response.result?["truePeakDbtp"]?.doubleValue == -12)
        #expect(response.result?["secondsAnalyzed"]?.doubleValue == 0.3)
        // Warming up: no momentary/integrated/LRA keys AT ALL — an agent
        // must see absence, not a fabricated floor.
        #expect(response.result?["momentaryLufs"] == nil)
        #expect(response.result?["shortTermLufs"] == nil)
        #expect(response.result?["integratedLufs"] == nil)
        #expect(response.result?["loudnessRangeLu"] == nil)
    }

    @Test("reset:true resets THEN returns the fresh snapshot")
    func resetSemantics() async throws {
        let engine = FakeLiveLoudnessEngine()
        engine.snapshot = LiveLoudnessSnapshot(
            momentaryLufs: -10, integratedLufs: -12, secondsAnalyzed: 120)
        let (router, _) = makeRouter(engine: engine)

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness",
            params: ["reset": .bool(true)]))
        #expect(response.ok)
        #expect(engine.resetCount == 1)
        #expect(engine.lastResetFlag == true)
        // The RESPONSE is the post-reset snapshot: empty, not the 120 s run.
        #expect(response.result?["secondsAnalyzed"]?.doubleValue == 0)
        #expect(response.result?["momentaryLufs"] == nil)
        #expect(response.result?["integratedLufs"] == nil)

        // reset:false is a plain read (no second reset).
        let read = await router.handle(ControlRequest(
            id: "2", command: "mixer.liveLoudness",
            params: ["reset": .bool(false)]))
        #expect(read.ok)
        #expect(engine.resetCount == 1)
    }

    @Test("unknown params are rejected with the teaching key list")
    func unknownKeysRejected() async throws {
        let (router, _) = makeRouter(engine: FakeLiveLoudnessEngine())
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness",
            params: ["restart": .bool(true)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'restart'") == true)
        #expect(response.error?.contains("'reset'") == true)
    }

    @Test("headless (no engine): the engineUnavailable teaching error, not a fake meter")
    func headlessTeachingError() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("an engine without live metering (protocol default nil) also refuses readably")
    func engineWithoutCapabilityRefuses() async throws {
        // An engine that does NOT override liveLoudness: the
        // AudioEngineControlling default returns nil and the store maps it
        // to the same teaching error — a live meter is never faked with
        // floors (`store.engine` is weak, so the fake is held locally).
        let store = ProjectStore()
        store.media = FakeMedia()
        let bare = BareEngine()
        store.engine = bare
        let router = CommandRouter(store: store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.liveLoudness"))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }
}

/// The minimal conformance: NO liveLoudness override, so the protocol
/// default (nil) is what the store sees.
@MainActor
private final class BareEngine: AudioEngineControlling {
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
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
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
