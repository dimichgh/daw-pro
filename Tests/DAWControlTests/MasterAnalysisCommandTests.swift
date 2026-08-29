import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M8 (vm-a) `mixer.masterAnalysis`: the
/// read-only, no-param snapshot command backing the session vibe meter.
/// Headless (no engine injected) the store reports the floor snapshot; with
/// an engine the same wire shape carries live values (proven by the vm-a
/// live self-check + `MasterMixAnalyzerTests` — here we pin the wire shape
/// and the finite-floors contract).
@MainActor
@Suite("Master analysis — control protocol")
struct MasterAnalysisCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    @Test("allCommands advertises mixer.masterAnalysis")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("mixer.masterAnalysis"))
    }

    @Test("headless: wire shape is {bands[24], levelDB, peakDB, centroidHz, flux, correlation, width, balance}, all at floors")
    func headlessFloorShape() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.masterAnalysis"))
        #expect(response.ok)

        let bands = try #require(response.result?["bands"]?.arrayValue)
        #expect(bands.count == MasterAnalysisSnapshot.bandCount)
        for band in bands {
            let value = try #require(band.doubleValue)
            #expect(value == Double(MasterAnalysisSnapshot.floorDB))
            #expect(value.isFinite)
        }
        #expect(response.result?["levelDB"]?.doubleValue
                == Double(MasterAnalysisSnapshot.floorDB))
        #expect(response.result?["peakDB"]?.doubleValue
                == Double(MasterAnalysisSnapshot.floorDB))
        #expect(response.result?["centroidHz"]?.doubleValue == 0)
        #expect(response.result?["flux"]?.doubleValue == 0)
        // m22-d additive stereo keys, at their DOCUMENTED floors:
        // correlation +1 (silence holds nothing out of phase — never a fake
        // 0), width 0 (mono), balance 0 (centered).
        #expect(response.result?["correlation"]?.doubleValue == 1)
        #expect(response.result?["width"]?.doubleValue == 0)
        #expect(response.result?["balance"]?.doubleValue == 0)
        // m27-d additive key: a fresh store never played, so isPlaying
        // defaults false — same "no live signal" fact whether the floor
        // came from being headless or from being stopped.
        #expect(response.result?["transportPlaying"]?.boolValue == false)
    }

    @Test("an engine's snapshot threads through the store onto the wire")
    func engineSnapshotThreadsThrough() async throws {
        let (router, store) = makeRouter()
        let engine = FakeAnalysisEngine()
        var bands = [Float](repeating: -40, count: MasterAnalysisSnapshot.bandCount)
        bands[12] = -6.5
        engine.analysis = MasterAnalysisSnapshot(
            bands: bands, levelDB: -12.25, peakDB: -6.5,
            centroidHz: 1_024, flux: 0.4375,
            correlation: -0.5, width: 0.75, balance: 0.125)
        store.engine = engine

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.masterAnalysis"))
        #expect(response.ok)
        let wireBands = try #require(response.result?["bands"]?.arrayValue)
        #expect(wireBands.count == MasterAnalysisSnapshot.bandCount)
        #expect(wireBands[12].doubleValue == -6.5)
        #expect(response.result?["levelDB"]?.doubleValue == -12.25)
        #expect(response.result?["peakDB"]?.doubleValue == -6.5)
        #expect(response.result?["centroidHz"]?.doubleValue == 1_024)
        #expect(response.result?["flux"]?.doubleValue == 0.4375)
        // m22-d additive stereo keys ride the SAME response.
        #expect(response.result?["correlation"]?.doubleValue == -0.5)
        #expect(response.result?["width"]?.doubleValue == 0.75)
        #expect(response.result?["balance"]?.doubleValue == 0.125)
    }

    @Test("pre-m22-d call sites (no stereo args) publish the stereo floors — additive default")
    func defaultedStereoFieldsReadFloors() async throws {
        let (router, store) = makeRouter()
        let engine = FakeAnalysisEngine()
        // The OLD five-field constructor shape: new fields default to the
        // stereo floors, so an engine predating m22-d stays wire-honest.
        engine.analysis = MasterAnalysisSnapshot(
            bands: [Float](repeating: -40, count: MasterAnalysisSnapshot.bandCount),
            levelDB: -12, peakDB: -6, centroidHz: 500, flux: 0.5)
        store.engine = engine

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.masterAnalysis"))
        #expect(response.ok)
        #expect(response.result?["correlation"]?.doubleValue == 1)
        #expect(response.result?["width"]?.doubleValue == 0)
        #expect(response.result?["balance"]?.doubleValue == 0)
    }

    @Test("m27-d: transportPlaying tracks store.play()/stop() independent of the analysis fields")
    func transportPlayingTracksStoreState() async throws {
        let (router, store) = makeRouter()

        let stoppedResponse = await router.handle(ControlRequest(
            id: "1", command: "mixer.masterAnalysis"))
        #expect(stoppedResponse.ok)
        #expect(stoppedResponse.result?["transportPlaying"]?.boolValue == false)

        store.play()
        let playingResponse = await router.handle(ControlRequest(
            id: "2", command: "mixer.masterAnalysis"))
        #expect(playingResponse.ok)
        #expect(playingResponse.result?["transportPlaying"]?.boolValue == true)
        // Still headless/floor: transportPlaying is independent of the
        // analysis fields themselves — a headless engine reads floor either
        // way, and this key never claims otherwise.
        #expect(playingResponse.result?["levelDB"]?.doubleValue
                == Double(MasterAnalysisSnapshot.floorDB))

        // m25-d: play() headless starts a free-running position ticker —
        // stop() before the test ends so it doesn't outlive this test.
        store.stop()
        let restoppedResponse = await router.handle(ControlRequest(
            id: "3", command: "mixer.masterAnalysis"))
        #expect(restoppedResponse.ok)
        #expect(restoppedResponse.result?["transportPlaying"]?.boolValue == false)
    }
}

/// Minimal engine fake: only the analysis surface matters; everything else
/// rides the protocol's optional-capability defaults.
@MainActor
private final class FakeAnalysisEngine: AudioEngineControlling {
    var analysis: MasterAnalysisSnapshot = .floor
    func masterAnalysis() -> MasterAnalysisSnapshot { analysis }

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
