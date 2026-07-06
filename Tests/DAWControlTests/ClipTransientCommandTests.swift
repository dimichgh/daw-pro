import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Engine fake for `clip.detectTransients` (M5 iii-e): returns stubbed
/// SOURCE-FILE-second markers and records the forwarded call, so the tests
/// pin the store's window filtering + beat mapping without real analysis.
@MainActor
final class FakeTransientEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?
    var recordPermission: RecordPermission = .granted

    var stubMarkers: [TransientMarker] = []
    var detectCalls = 0
    var lastURL: URL?
    var lastSensitivity: Double?

    func detectTransients(inFileAt url: URL, sensitivity: Double) async throws -> [TransientMarker] {
        detectCalls += 1
        lastURL = url
        lastSensitivity = sensitivity
        return stubMarkers
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
    func renderMixdown(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
    }
}

/// Control-protocol coverage for M5 (iii-e) `clip.detectTransients`: happy
/// path with window filtering + beat mapping (spec §7 wire shape), the trim
/// re-window, sensitivity forwarding/default/validation, and the MIDI /
/// unknown-clip / headless rejections verbatim. Reuses `FakeMedia` from
/// ControlTests.swift (2 s file → 4 beats @ 120).
@MainActor
@Suite("Clip transients — control protocol (M5 iii-e)")
struct ClipTransientCommandTests {
    private func makeRouter(engine: FakeTransientEngine? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    /// Audio track + 4-beat audio clip at `atBeat` (FakeMedia: 2 s @ 120),
    /// returning wire ids.
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

    @Test("happy path: window-filtered, beat-mapped, count on the wire")
    func detectTransientsHappyPath() async throws {
        let engine = FakeTransientEngine()
        // Clip at beat 4, window [0, 2) source seconds (2 s file, offset 0).
        // 2.5 s is PAST the source window; 2.0 sits exactly on the half-open
        // boundary — both must be filtered out.
        engine.stubMarkers = [
            TransientMarker(timeSeconds: 0.5, strength: 1.0),
            TransientMarker(timeSeconds: 1.5, strength: 0.75),
            TransientMarker(timeSeconds: 2.0, strength: 0.5),
            TransientMarker(timeSeconds: 2.5, strength: 0.25),
        ]
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router, atBeat: 4)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectTransients",
            params: ["clipId": .string(clipID), "sensitivity": .number(0.8)]))
        #expect(response.ok)
        #expect(response.result?["count"]?.doubleValue == 2)
        let transients = try #require(response.result?["transients"]?.arrayValue)
        #expect(transients.count == 2)
        // beat = startBeat(4) + t · tempo/60 (ratio 1, offset 0) @ 120 BPM.
        #expect(transients[0]["sourceSeconds"]?.doubleValue == 0.5)
        #expect(transients[0]["beat"]?.doubleValue == 5.0)
        #expect(transients[0]["strength"]?.doubleValue == 1.0)
        #expect(transients[1]["sourceSeconds"]?.doubleValue == 1.5)
        #expect(transients[1]["beat"]?.doubleValue == 7.0)
        #expect(transients[1]["strength"]?.doubleValue == 0.75)
        // The engine saw the clip's file and the requested sensitivity.
        #expect(engine.detectCalls == 1)
        #expect(engine.lastURL?.path == "/tmp/Loop.wav")
        #expect(engine.lastSensitivity == 0.8)
    }

    @Test("trimmed clip re-windows: markers filter and map through the new offset")
    func detectTransientsAfterTrim() async throws {
        let engine = FakeTransientEngine()
        engine.stubMarkers = [
            TransientMarker(timeSeconds: 0.25, strength: 0.4),  // before window
            TransientMarker(timeSeconds: 0.5, strength: 1.0),
            TransientMarker(timeSeconds: 1.2, strength: 0.6),
        ]
        let (router, _) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router, atBeat: 4)

        // Trim the head: [4,8) → [5,8). Content stays put, so the source
        // offset advances by 1 beat = 0.5 s → window [0.5, 2.0).
        let trim = await router.handle(ControlRequest(
            id: "trim", command: "clip.trim",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "newStartBeat": .number(5), "newLengthBeats": .number(3)]))
        #expect(trim.ok)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectTransients", params: ["clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["count"]?.doubleValue == 2)
        let transients = try #require(response.result?["transients"]?.arrayValue)
        // beat = 5 + (t − 0.5) · 2.
        #expect(transients[0]["sourceSeconds"]?.doubleValue == 0.5)
        #expect(transients[0]["beat"]?.doubleValue == 5.0)
        #expect(transients[1]["sourceSeconds"]?.doubleValue == 1.2)
        #expect(transients[1]["beat"]?.doubleValue == 5 + (1.2 - 0.5) * 2)
        // Omitted sensitivity defaults to 0.5 on the engine call.
        #expect(engine.lastSensitivity == 0.5)
    }

    @Test("MIDI clip surfaces transientsRequireAudioClip verbatim")
    func detectTransientsRejectsMIDI() async throws {
        let engine = FakeTransientEngine()  // ProjectStore.engine is weak — keep it alive
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addMIDIClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectTransients", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "clip \(clipID) is a MIDI clip — clip.detectTransients applies only to audio clips (MIDI notes already carry their onsets)")
    }

    @Test("unknown clip surfaces clipNotFound; missing clipId is field-named")
    func detectTransientsUnknownClip() async throws {
        let engine = FakeTransientEngine()  // ProjectStore.engine is weak — keep it alive
        let (router, _) = makeRouter(engine: engine)
        _ = try await addAudioClip(router)
        let unknown = await router.handle(ControlRequest(
            id: "1", command: "clip.detectTransients",
            params: ["clipId": .string(UUID().uuidString)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)

        let missing = await router.handle(ControlRequest(
            id: "2", command: "clip.detectTransients"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("clipId") == true)
    }

    @Test("sensitivity outside 0...1 is a field-named param error, engine untouched")
    func detectTransientsSensitivityValidation() async throws {
        let engine = FakeTransientEngine()
        let (router, _) = makeRouter(engine: engine)
        let (_, clipID) = try await addAudioClip(router)
        for bad in [-0.1, 1.5] {
            let response = await router.handle(ControlRequest(
                id: "1", command: "clip.detectTransients",
                params: ["clipId": .string(clipID), "sensitivity": .number(bad)]))
            #expect(!response.ok)
            #expect(response.error?.contains("'sensitivity' must be between 0 and 1") == true)
        }
        #expect(engine.detectCalls == 0)
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func detectTransientsHeadless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let (_, clipID) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.detectTransients", params: ["clipId": .string(clipID)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("clip.detectTransients is a registered command")
    func commandRegistered() {
        #expect(CommandRouter.allCommands.contains("clip.detectTransients"))
    }
}
