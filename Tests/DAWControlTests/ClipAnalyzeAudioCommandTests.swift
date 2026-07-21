import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Engine fake for `clip.analyzeAudio` (m21-e, design-clip-analyze-audio §4-5):
/// returns a stubbed `AudioContentAnalysis` and records the forwarded call, so
/// the tests pin the wire shape + window forwarding without real DSP. Unlike
/// `FakeTransientEngine`, an empty/zeroed stub would be a LIE for this surface
/// (design §4) — every test sets `stubResult` explicitly.
@MainActor
final class FakeAudioAnalysisEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var stubResult = AudioContentAnalysis(
        durationSeconds: 2.0, windowStartSeconds: 0, sampleRate: 44_100,
        samplePeakDb: -0.3, rmsDb: -14.2,
        key: KeyEstimate(
            tonic: "A", mode: "minor", confidence: 0.78, tonal: true,
            alternatives: [
                KeyAlternative(tonic: "C", mode: "major", score: 0.71),
                KeyAlternative(tonic: "E", mode: "minor", score: 0.55),
                KeyAlternative(tonic: "D", mode: "minor", score: 0.40),
            ]),
        // Nullable-tempo pin (design §4): no periodic evidence in this stub.
        tempo: TempoEstimate(
            bpm: nil, confidence: 0.1, steady: false, beatOffsetSeconds: nil,
            alternates: []),
        spectral: SpectralBalance(
            bands: (0..<24).map { -40.0 + Double($0) },
            centroidHz: 1834.0,
            summary: SpectralSummary(
                subDb: -38.1, bassDb: -20.3, lowMidDb: -18.9, midDb: -16.4,
                highMidDb: -22.0, airDb: -30.5)),
        analyzerVersion: 1)
    var analyzeCalls = 0
    var lastURL: URL?
    var lastWindowStart: Double?
    var lastWindowDuration: Double?

    func analyzeAudioContent(
        inFileAt url: URL, windowStartSeconds: Double, windowDurationSeconds: Double
    ) async throws -> AudioContentAnalysis {
        analyzeCalls += 1
        lastURL = url
        lastWindowStart = windowStartSeconds
        lastWindowDuration = windowDurationSeconds
        return stubResult
    }

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}
    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {}
    func availableInputDevices() -> [AudioInputDevice] { [] }
    func setInputDevice(uid: String?) throws {}
    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
    func stopRecording() {}
    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
}

/// Control-protocol coverage for m21-e `clip.analyzeAudio`: happy-path wire
/// shape (key block, nullable tempo, 24 spectral bands, playback omitted for
/// an identity clip), the MIDI/unknown-clip/unknown-key rejections verbatim,
/// and the engine-default-throw path (a real `AudioEngineControlling` that
/// simply doesn't override `analyzeAudioContent`). Reuses `FakeMedia` from
/// ControlTests.swift (2 s file → 4 beats @ 120) — same fixture as
/// `clip.detectTransients`'s ClipTransientCommandTests.
@MainActor
@Suite("Clip audio analysis — control protocol (m21-e)")
struct ClipAnalyzeAudioCommandTests {
    private func makeRouter(engine: (any AudioEngineControlling)? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    private func addAudioClip(_ router: CommandRouter, atBeat: Double = 0) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav"),
                     "atBeat": .number(atBeat)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    private func addMIDIClip(_ router: CommandRouter) async throws
        -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    @Test("happy path: key block, nullable tempo, 24 bands, playback omitted for an identity clip")
    func analyzeHappyPath() async throws {
        let engine = FakeAudioAnalysisEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.analyzeAudio", params: ["clipId": .string(clipID)]))
        #expect(response.ok)

        let analysis = try #require(response.result?["analysis"]?.objectValue)
        #expect(analysis["durationSeconds"]?.doubleValue == 2.0)
        #expect(analysis["windowStartSeconds"]?.doubleValue == 0)
        #expect(analysis["sampleRate"]?.doubleValue == 44_100)
        #expect(analysis["samplePeakDb"]?.doubleValue == -0.3)
        #expect(analysis["rmsDb"]?.doubleValue == -14.2)
        #expect(analysis["analyzerVersion"]?.doubleValue == 1)

        let key = try #require(analysis["key"]?.objectValue)
        #expect(key["tonic"]?.stringValue == "A")
        #expect(key["mode"]?.stringValue == "minor")
        #expect(key["confidence"]?.doubleValue == 0.78)
        #expect(key["tonal"]?.boolValue == true)
        #expect(key["alternatives"]?.arrayValue?.count == 3)
        #expect(key["alternatives"]?.arrayValue?.first?["tonic"]?.stringValue == "C")

        // Nullable-tempo pin: no periodic evidence → bpm/beatOffsetSeconds
        // are absent on the wire (synthesized Codable omits nil optionals).
        let tempo = try #require(analysis["tempo"]?.objectValue)
        #expect(tempo["bpm"] == nil)
        #expect(tempo["beatOffsetSeconds"] == nil)
        #expect(tempo["steady"]?.boolValue == false)
        #expect(tempo["confidence"]?.doubleValue == 0.1)
        #expect(tempo["alternates"]?.arrayValue?.isEmpty == true)

        let spectral = try #require(analysis["spectral"]?.objectValue)
        #expect(spectral["bands"]?.arrayValue?.count == 24)
        #expect(spectral["centroidHz"]?.doubleValue == 1834.0)
        let summary = try #require(spectral["summary"]?.objectValue)
        #expect(summary["subDb"]?.doubleValue == -38.1)
        #expect(summary["airDb"]?.doubleValue == -30.5)

        // Identity clip (stretch 1, pitch 0): echo present, playback omitted.
        #expect(response.result?["stretchRatio"]?.doubleValue == 1)
        #expect(response.result?["pitchShiftSemitones"]?.doubleValue == 0)
        #expect(response.result?["playback"] == nil)

        // The engine saw the clip's file and its current source window
        // (2 s file → 4 beats @ 120 → 2 s window, offset 0).
        #expect(engine.analyzeCalls == 1)
        #expect(engine.lastURL?.path == "/tmp/Loop.wav")
        #expect(engine.lastWindowStart == 0)
        #expect(engine.lastWindowDuration == 2.0)
    }

    @Test("MIDI clip surfaces analysisRequiresAudioClip verbatim")
    func analyzeRejectsMIDI() async throws {
        let engine = FakeAudioAnalysisEngine()  // ProjectStore.engine is weak — keep it alive
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addMIDIClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.analyzeAudio", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "clip \(clipID) is a MIDI clip — clip.analyzeAudio applies only to audio clips (read MIDI notes directly for key and timing)")
        #expect(engine.analyzeCalls == 0)
    }

    @Test("unknown clip surfaces clipNotFound; missing clipId is field-named")
    func analyzeUnknownClip() async throws {
        let engine = FakeAudioAnalysisEngine()  // ProjectStore.engine is weak — keep it alive
        let (router, _) = makeRouter(engine: engine)
        _ = try await addAudioClip(router)
        let unknown = await router.handle(ControlRequest(
            id: "1", command: "clip.analyzeAudio",
            params: ["clipId": .string(UUID().uuidString)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)

        let missing = await router.handle(ControlRequest(
            id: "2", command: "clip.analyzeAudio"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("clipId") == true)
    }

    @Test("unknown params are rejected with the teaching key list")
    func analyzeUnknownKeysRejected() async throws {
        let engine = FakeAudioAnalysisEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.analyzeAudio",
            params: ["clipId": .string(clipID), "sensitivity": .number(0.5)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'sensitivity'") == true)
        #expect(response.error?.contains("valid keys are 'clipId'") == true)
        #expect(engine.analyzeCalls == 0)
    }

    @Test("engine-default-throw path: a real engine that doesn't override analyzeAudioContent surfaces engineUnavailable")
    func analyzeEngineDefaultThrow() async throws {
        // FakeEngine (ControlTests.swift) conforms to AudioEngineControlling
        // but does NOT override analyzeAudioContent — it inherits the
        // protocol's THROWING default (design §4: a fabricated empty
        // analysis would be a lie, unlike detectTransients' honest `[]`).
        let engine = FakeEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.analyzeAudio", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func analyzeHeadless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let (_, clipID) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.analyzeAudio", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("clip.analyzeAudio is a registered command, appended after clip.fitToContent")
    func commandRegistered() {
        let all = CommandRouter.allCommands
        #expect(all.contains("clip.analyzeAudio"))
        // Relative order, not `.last`: the tail moves with every append
        // (additive-at-end law); the current-tail + count tripwire lives in
        // the NEWEST command's own registration test.
        if let analyzeIndex = all.firstIndex(of: "clip.analyzeAudio"),
           let fitIndex = all.firstIndex(of: "clip.fitToContent") {
            #expect(fitIndex < analyzeIndex)
        } else {
            Issue.record("clip.analyzeAudio or clip.fitToContent missing from allCommands")
        }
    }
}
