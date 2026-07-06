import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Client-readable error for the app-command-handler tests — mirrors the
/// LocalizedError the real DAWApp handler throws, so we exercise the same
/// error-surfacing path in CommandRouter.handle.
struct StubHandlerError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Deterministic media stand-in so clip.addAudio routes without file I/O.
struct FakeMedia: MediaImporting {
    var info = AudioFileInfo(durationSeconds: 2.0, sampleRate: 44100, channelCount: 2)
    func audioFileInfo(at url: URL) throws -> AudioFileInfo { info }
}

/// Recording engine stand-in so render.mixdown routes without AVFoundation.
/// Transport intents are no-ops; only the mixdown call is captured.
@MainActor
final class FakeEngine: AudioEngineControlling {
    var isRunning = false
    var meteringHandler: ((MeterFrame) -> Void)?
    var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
    var playheadHandler: ((Double) -> Void)?

    private(set) var lastMixdownURL: URL?
    var mixdownStub = AudioFileInfo(durationSeconds: 2.5, sampleRate: 48_000, channelCount: 2)

    var recordPermission: RecordPermission = .granted
    private(set) var permissionRequests = 0
    private(set) var startRecordingURLs: [URL] = []
    private(set) var stopRecordingCount = 0

    func prepare() throws { isRunning = true }
    func shutdown() { isRunning = false }
    func tracksDidChange(_ tracks: [Track]) {}
    func startPlayback(_ transport: TransportState) {}
    func stopPlayback() {}
    func seek(_ transport: TransportState) {}
    func setTempo(_ transport: TransportState) {}
    func loopChanged(_ transport: TransportState) {}
    func masterVolumeChanged(_ volume: Double) {}

    func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
        permissionRequests += 1
    }

    /// Configurable device list, mirroring CoreAudio enumeration; the real
    /// engine's unknown-uid contract (exact message via ProjectError) applies.
    var inputDevices: [AudioInputDevice] = []
    private(set) var selectedInputUID: String?

    func availableInputDevices() -> [AudioInputDevice] { inputDevices }

    func setInputDevice(uid: String?) throws {
        if let uid, !inputDevices.contains(where: { $0.uid == uid }) {
            throw ProjectError.inputDeviceNotFound(uid)
        }
        selectedInputUID = uid
    }

    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        startRecordingURLs.append(url)
    }

    func stopRecording() { stopRecordingCount += 1 }

    func renderMixdown(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       to url: URL) async throws -> AudioFileInfo {
        lastMixdownURL = url
        return mixdownStub
    }

    // M5 (iv-d): a fixed non-silent buffer regardless of the requested track
    // subset/window, so render.measureLoudness/render.bounce/render.stems can
    // route through this shared coverage-loop fake too (the render.mixdown
    // precedent above) — real audio correctness is proven by
    // OfflineBufferRenderTests/StemNullTests (iv-b/iv-c) and RenderCommandTests'
    // dedicated fake.
    func renderOffline(tracks: [Track], tempoBPM: Double, masterVolume: Double,
                       fromBeat: Double, durationSeconds: Double,
                       forcedCompensationTargets: [UUID: Int]?) async throws -> RenderedAudio {
        let frameCount = Int(durationSeconds * 48_000)
        let samples = [Float](repeating: 0.1, count: frameCount)
        return RenderedAudio(sampleRate: 48_000, channelData: [samples, samples])
    }

    func writeAudioFile(_ audio: RenderedAudio, to url: URL) throws -> AudioFileInfo {
        AudioFileInfo(durationSeconds: audio.sampleRate > 0 ? Double(audio.frameCount) / audio.sampleRate : 0,
                     sampleRate: audio.sampleRate, channelCount: audio.channelData.count)
    }
}

@Suite("JSONValue")
struct JSONValueTests {
    @Test("round-trips a nested document")
    func roundTrip() async throws {
        let json = #"{"a": 1.5, "b": "x", "c": [true, null], "d": {"e": 2}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        let data = try JSONEncoder().encode(value)
        let again = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(value == again)
        #expect(value["a"]?.doubleValue == 1.5)
        #expect(value["d"]?["e"]?.doubleValue == 2)
    }

    @Test("encodes any Encodable")
    func encodingInit() async throws {
        let track = Track(name: "Keys", kind: .instrument)
        let value = try JSONValue(encoding: track)
        #expect(value["name"]?.stringValue == "Keys")
        #expect(value["kind"]?.stringValue == "instrument")
    }
}

@MainActor
@Suite("CommandRouter")
struct CommandRouterTests {
    /// `store.engine` is weak — callers passing an engine must hold it for the
    /// test's lifetime.
    private func makeRouter(engine: FakeEngine? = nil) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        return (CommandRouter(store: store), store)
    }

    @Test("transport commands mutate the store")
    func transport() async {
        let (router, store) = makeRouter()

        let play = await router.handle(ControlRequest(id: "1", command: "transport.play"))
        #expect(play.ok)
        #expect(store.transport.isPlaying)

        let tempo = await router.handle(ControlRequest(
            id: "2", command: "transport.setTempo", params: ["bpm": .number(128)]
        ))
        #expect(tempo.ok)
        #expect(tempo.result?.doubleValue == 128)
        #expect(store.transport.tempoBPM == 128)

        let stop = await router.handle(ControlRequest(id: "3", command: "transport.stop"))
        #expect(stop.ok)
        #expect(!store.transport.isPlaying)
    }

    @Test("transport.setLoop enables looping and returns transport state")
    func setLoop() async {
        let (router, store) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setLoop",
            params: ["enabled": .bool(true), "startBeat": .number(4), "endBeat": .number(12)]
        ))
        #expect(response.ok)
        #expect(response.result?["isLoopEnabled"]?.boolValue == true)
        #expect(response.result?["loopStartBeat"]?.doubleValue == 4)
        #expect(response.result?["loopEndBeat"]?.doubleValue == 12)
        #expect(store.transport.isLoopEnabled)
    }

    @Test("transport.setLoop with an inverted range reports a readable error")
    func setLoopInvalidRange() async {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setLoop",
            params: ["enabled": .bool(true), "startBeat": .number(8), "endBeat": .number(4)]
        ))
        #expect(!response.ok)
        #expect(response.error == "loop end must be after loop start")
        #expect(!store.transport.isLoopEnabled)
    }

    @Test("transport.setPunch enables the window and returns transport state")
    func setPunch() async {
        let (router, store) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setPunch",
            params: ["enabled": .bool(true), "inBeat": .number(4), "outBeat": .number(12)]
        ))
        #expect(response.ok)
        #expect(response.result?["isPunchEnabled"]?.boolValue == true)
        #expect(response.result?["punchInBeat"]?.doubleValue == 4)
        #expect(response.result?["punchOutBeat"]?.doubleValue == 12)
        #expect(store.transport.isPunchEnabled)
    }

    @Test("transport.setPunch with an inverted range reports the exact error")
    func setPunchInvalidRange() async {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setPunch",
            params: ["enabled": .bool(true), "inBeat": .number(8), "outBeat": .number(4)]
        ))
        #expect(!response.ok)
        #expect(response.error == "punch out must be after punch in")
        #expect(!store.transport.isPunchEnabled)
    }

    @Test("transport.setMetronome enables the click and returns transport state")
    func setMetronome() async {
        let (router, store) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "transport.setMetronome",
            params: ["enabled": .bool(true), "countInBars": .number(2)]
        ))
        #expect(response.ok)
        #expect(response.result?["isMetronomeEnabled"]?.boolValue == true)
        #expect(response.result?["countInBars"]?.doubleValue == 2)
        #expect(store.transport.isMetronomeEnabled)

        // countInBars clamps to 0...4; omitting it keeps the current value.
        let clamped = await router.handle(ControlRequest(
            id: "2", command: "transport.setMetronome",
            params: ["enabled": .bool(true), "countInBars": .number(9)]
        ))
        #expect(clamped.ok)
        #expect(clamped.result?["countInBars"]?.doubleValue == 4)

        let kept = await router.handle(ControlRequest(
            id: "3", command: "transport.setMetronome", params: ["enabled": .bool(false)]
        ))
        #expect(kept.ok)
        #expect(kept.result?["isMetronomeEnabled"]?.boolValue == false)
        #expect(kept.result?["countInBars"]?.doubleValue == 4)

        let missing = await router.handle(ControlRequest(id: "4", command: "transport.setMetronome"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("enabled") == true)
    }

    @Test("transport.setMetronome while recording reports transportBusy verbatim")
    func setMetronomeWhileRecording() async throws {
        let engine = FakeEngine()
        let (router, store) = makeRouter(engine: engine)
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        #expect(await router.handle(ControlRequest(id: "1", command: "transport.record")).ok)

        let response = await router.handle(ControlRequest(
            id: "2", command: "transport.setMetronome", params: ["enabled": .bool(true)]
        ))
        #expect(!response.ok)
        #expect(response.error == "cannot change metronome while recording — stop first")
        #expect(!store.transport.isMetronomeEnabled)
    }

    @Test("track lifecycle over the protocol")
    func trackLifecycle() async throws {
        let (router, store) = makeRouter()

        let add = await router.handle(ControlRequest(
            id: "1", command: "track.add",
            params: ["name": .string("Drums"), "kind": .string("audio")]
        ))
        #expect(add.ok)
        let trackID = try #require(add.result?["id"]?.stringValue)

        let volume = await router.handle(ControlRequest(
            id: "2", command: "track.setVolume",
            params: ["trackId": .string(trackID), "volume": .number(0.5)]
        ))
        #expect(volume.ok)
        #expect(store.tracks[0].volume == 0.5)

        let remove = await router.handle(ControlRequest(
            id: "3", command: "track.remove", params: ["trackId": .string(trackID)]
        ))
        #expect(remove.ok)
        #expect(store.tracks.isEmpty)
    }

    @Test("mixer.setMasterVolume sets and returns the clamped gain")
    func setMasterVolume() async {
        let (router, store) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.setMasterVolume", params: ["volume": .number(0.5)]
        ))
        #expect(response.ok)
        #expect(response.result?["masterVolume"]?.doubleValue == 0.5)
        #expect(store.masterVolume == 0.5)

        // Out-of-range values clamp; the response reports the applied gain.
        let clamped = await router.handle(ControlRequest(
            id: "2", command: "mixer.setMasterVolume", params: ["volume": .number(3)]
        ))
        #expect(clamped.ok)
        #expect(clamped.result?["masterVolume"]?.doubleValue == 2)
        #expect(store.masterVolume == 2)
    }

    @Test("mixer.setMasterVolume without volume reports the missing param")
    func setMasterVolumeMissingParam() async {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "mixer.setMasterVolume"))
        #expect(!response.ok)
        #expect(response.error?.contains("volume") == true)
        #expect(store.masterVolume == 1)  // untouched on failure
    }

    @Test("clip.addAudio imports onto a track and returns clip JSON")
    func addAudioHappyPath() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .audio).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]
        ))
        #expect(response.ok)
        #expect(response.result?["name"]?.stringValue == "Loop")
        // 2.0s at default 120 BPM = 4 beats.
        #expect(response.result?["lengthBeats"]?.doubleValue == 4)
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("clip.addAudio without path reports the missing param")
    func addAudioMissingPath() async {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .audio).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.addAudio", params: ["trackId": .string(trackID)]
        ))
        #expect(!response.ok)
        #expect(response.error?.contains("path") == true)
    }

    @Test("clip.addAudio with a bad trackId errors")
    func addAudioBadTrack() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.addAudio",
            params: ["trackId": .string("not-a-uuid"), "path": .string("/tmp/Loop.wav")]
        ))
        #expect(!response.ok)
    }

    @Test("render.mixdown returns the contract result shape")
    func renderMixdownHappyPath() async throws {
        let engine = FakeEngine()
        let (router, store) = makeRouter(engine: engine)
        let trackID = store.addTrack(kind: .audio).id.uuidString
        let added = await router.handle(ControlRequest(
            id: "1", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]
        ))
        #expect(added.ok)

        let response = await router.handle(ControlRequest(
            id: "2", command: "render.mixdown",
            params: ["path": .string("/tmp/daw-pro-ctl-mix")]
        ))
        #expect(response.ok)
        #expect(response.result?["path"]?.stringValue == "/tmp/daw-pro-ctl-mix.wav")
        #expect(response.result?["durationSeconds"]?.doubleValue == 2.5)
        #expect(response.result?["sampleRate"]?.doubleValue == 48_000)
        #expect(response.result?["channels"]?.doubleValue == 2)
        #expect(engine.lastMixdownURL?.path == "/tmp/daw-pro-ctl-mix.wav")
    }

    @Test("render.mixdown with nothing to render passes the exact message through")
    func renderMixdownNothingToRender() async {
        let engine = FakeEngine()
        let (router, _) = makeRouter(engine: engine)  // no clips anywhere

        let response = await router.handle(ControlRequest(id: "1", command: "render.mixdown"))
        #expect(!response.ok)
        #expect(response.error == "nothing to render — project has no audio clips")
        #expect(engine.lastMixdownURL == nil)
    }

    // T19.
    @Test("track.setArm round-trips and reports the missing param")
    func setArm() async throws {
        let engine = FakeEngine()
        let (router, store) = makeRouter(engine: engine)
        let trackID = store.addTrack(kind: .audio).id.uuidString

        let arm = await router.handle(ControlRequest(
            id: "1", command: "track.setArm",
            params: ["trackId": .string(trackID), "armed": .bool(true)]
        ))
        #expect(arm.ok)
        #expect(store.tracks[0].isArmed)

        let disarm = await router.handle(ControlRequest(
            id: "2", command: "track.setArm",
            params: ["trackId": .string(trackID), "armed": .bool(false)]
        ))
        #expect(disarm.ok)
        #expect(!store.tracks[0].isArmed)

        let missing = await router.handle(ControlRequest(
            id: "3", command: "track.setArm", params: ["trackId": .string(trackID)]
        ))
        #expect(!missing.ok)
        #expect(missing.error?.contains("armed") == true)

        let gone = await router.handle(ControlRequest(
            id: "4", command: "track.setArm",
            params: ["trackId": .string(UUID().uuidString), "armed": .bool(true)]
        ))
        #expect(!gone.ok)
        #expect(gone.error?.contains("no track") == true)
    }

    // M3 (iv).
    @Test("track.setInstrument overlays fields and returns the resolved instrument object")
    func setInstrumentHappyPath() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "kind": .string("polySynth"),
                "waveform": .string("square"),
                "attack": .number(0.02),
                "cutoffHz": .number(5_000),
                "gain": .number(0.5),
            ]
        ))
        #expect(response.ok)
        // Response is the resolved {kind, polySynth:{...}} instrument object.
        #expect(response.result?["kind"]?.stringValue == "polySynth")
        let poly = try #require(response.result?["polySynth"])
        #expect(poly["waveform"]?.stringValue == "square")
        #expect(poly["attack"]?.doubleValue == 0.02)
        #expect(poly["cutoffHz"]?.doubleValue == 5_000)
        #expect(poly["gain"]?.doubleValue == 0.5)
        // Untouched fields fell back to the defaults.
        #expect(poly["decay"]?.doubleValue == 0.08)
        #expect(poly["sustain"]?.doubleValue == 0.7)
        #expect(store.tracks[0].instrument?.polySynth.waveform == .square)

        // A second partial call keeps every field it doesn't name.
        let overlay = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(instID), "waveform": .string("sine")]
        ))
        #expect(overlay.ok)
        #expect(overlay.result?["polySynth"]?["waveform"]?.stringValue == "sine")
        #expect(overlay.result?["polySynth"]?["attack"]?.doubleValue == 0.02)  // survived
        #expect(overlay.result?["polySynth"]?["gain"]?.doubleValue == 0.5)     // survived
    }

    // M3 (iv).
    @Test("track.setInstrument clamps out-of-range numbers silently, like track.setVolume")
    func setInstrumentClamps() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID), "gain": .number(99), "sustain": .number(-1)]
        ))
        #expect(response.ok)
        #expect(response.result?["polySynth"]?["gain"]?.doubleValue == 1)
        #expect(response.result?["polySynth"]?["sustain"]?.doubleValue == 0)
        #expect(store.tracks[0].instrument?.polySynth.gain == 1)
    }

    // M3 (iv).
    @Test("track.setInstrument names the valid values for a bad kind or waveform")
    func setInstrumentInvalidEnums() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let badKind = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID), "kind": .string("fmSynth")]
        ))
        #expect(!badKind.ok)
        #expect(badKind.error == "kind must be one of testTone|polySynth|sampler|audioUnit")

        let badWave = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(instID), "waveform": .string("noise")]
        ))
        #expect(!badWave.ok)
        #expect(badWave.error == "waveform must be one of saw|square|triangle|sine")

        // Neither rejected call mutated the track.
        #expect(store.tracks[0].instrument == nil)
    }

    // M3 (iv).
    @Test("track.setInstrument reports the instrument-track rule and unknown-track shape verbatim")
    func setInstrumentRejections() async throws {
        let (router, store) = makeRouter()
        let audioID = store.addTrack(kind: .audio).id.uuidString

        let onAudio = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(audioID), "waveform": .string("saw")]
        ))
        #expect(!onAudio.ok)
        #expect(onAudio.error
                == "track kind 'audio' cannot host an instrument — only instrument tracks carry an instrument (add one with track.add kind=instrument)")

        let unknown = UUID()
        let gone = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(unknown.uuidString), "waveform": .string("saw")]
        ))
        #expect(!gone.ok)
        #expect(gone.error == "no track with id \(unknown.uuidString)")

        let badID = await router.handle(ControlRequest(
            id: "3", command: "track.setInstrument",
            params: ["trackId": .string("nope"), "waveform": .string("saw")]
        ))
        #expect(badID.error == "'trackId' is not a valid UUID: nope")
    }

    // M3 (iv).
    @Test("project.snapshot resolves instrument tracks and omits the field on audio tracks")
    func snapshotInstrumentShape() async throws {
        let (router, store) = makeRouter()
        let inst = store.addTrack(kind: .instrument)
        store.addTrack(kind: .audio)
        try store.setInstrument(id: inst.id, waveform: .square)

        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        guard case .array(let tracks)? = response.result?["tracks"] else {
            Issue.record("snapshot has no tracks array"); return
        }
        // Instrument track: resolved {kind, polySynth:{...}}.
        #expect(tracks[0]["instrument"]?["kind"]?.stringValue == "polySynth")
        #expect(tracks[0]["instrument"]?["polySynth"]?["waveform"]?.stringValue == "square")
        // Audio track: the instrument key is omitted entirely (not null).
        #expect(tracks[1]["instrument"] == nil)
        if case .object(let audioTrack) = tracks[1] {
            #expect(audioTrack["instrument"] == nil)
            #expect(!audioTrack.keys.contains("instrument"))
        } else {
            Issue.record("audio track is not an object")
        }
    }

    // M3 (iv).
    @Test("allCommands advertises track.setInstrument")
    func setInstrumentAdvertised() async {
        #expect(CommandRouter.allCommands.contains("track.setInstrument"))
    }

    // M3 (v) — sampler. Real system sound files exist on every macOS install.
    private static let pingPath = "/System/Library/Sounds/Ping.aiff"

    // M3 (v).
    @Test("track.setInstrument accepts a sampler config and echoes zones with a path")
    func setInstrumentSamplerHappyPath() async throws {
        let (router, store) = makeRouter()  // store.media = FakeMedia (readability ok)
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([
                        .object([
                            "path": .string(Self.pingPath),
                            "rootPitch": .number(48),
                            "minPitch": .number(36),
                            "maxPitch": .number(59),
                            "gain": .number(0.9),
                        ]),
                    ]),
                    "oneShot": .bool(true),
                    "attack": .number(0.002),
                    "release": .number(0.1),
                    "gain": .number(0.7),
                ]),
            ]
        ))
        #expect(response.ok)
        #expect(response.result?["kind"]?.stringValue == "sampler")
        let sampler = try #require(response.result?["sampler"])
        #expect(sampler["oneShot"]?.boolValue == true)
        #expect(sampler["attack"]?.doubleValue == 0.002)
        #expect(sampler["release"]?.doubleValue == 0.1)
        #expect(sampler["gain"]?.doubleValue == 0.7)
        guard case .array(let zones)? = sampler["zones"] else {
            Issue.record("sampler has no zones array"); return
        }
        try #require(zones.count == 1)
        #expect(zones[0]["path"]?.stringValue == Self.pingPath)  // filesystem path, not a URL object
        #expect(zones[0]["rootPitch"]?.doubleValue == 48)
        #expect(zones[0]["minPitch"]?.doubleValue == 36)
        #expect(zones[0]["maxPitch"]?.doubleValue == 59)
        #expect(zones[0]["gain"]?.doubleValue == 0.9)
        // The live model stored the zone with the resolved URL.
        #expect(store.tracks[0].instrument?.sampler?.zones.first?.audioFileURL.path == Self.pingPath)

        // A polySynth-only zone default fills in when zone fields are omitted.
        let minimal = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zones": .array([.object(["path": .string(Self.pingPath)])])])]
        ))
        #expect(minimal.ok)
        let z = try #require(minimal.result?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(z["rootPitch"]?.doubleValue == 60)  // model default
        #expect(z["minPitch"]?.doubleValue == 0)
        #expect(z["maxPitch"]?.doubleValue == 127)
        #expect(z["gain"]?.doubleValue == 1)
    }

    // M3 (v).
    @Test("track.setInstrument reports malformed sampler fields with field-path errors")
    func setInstrumentSamplerFieldErrors() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        func set(_ sampler: JSONValue) async -> ControlResponse {
            await router.handle(ControlRequest(id: "x", command: "track.setInstrument",
                params: ["trackId": .string(instID), "sampler": sampler]))
        }

        // A zone missing its required path.
        let noPath = await set(.object(["zones": .array([.object(["rootPitch": .number(60)])])]))
        #expect(noPath.error == "sampler.zones[0].path is required")

        // zones must be an array.
        let notArray = await set(.object(["zones": .string("nope")]))
        #expect(notArray.error == "sampler.zones must be an array")

        // A non-object sampler.
        let notObject = await router.handle(ControlRequest(id: "y", command: "track.setInstrument",
            params: ["trackId": .string(instID), "sampler": .string("nope")]))
        #expect(notObject.error == "sampler must be an object {zones, oneShot?, attack?, release?, gain?}")

        // A mistyped pitch field.
        let badPitch = await set(.object(["zones": .array([
            .object(["path": .string(Self.pingPath), "rootPitch": .number(60.5)])])]))
        #expect(badPitch.error == "sampler.zones[0].rootPitch must be an integer 0-127")

        // Nothing landed on the track across the rejected calls.
        #expect(store.tracks[0].instrument == nil)
    }

    // M3 (v).
    @Test("track.setInstrument surfaces a nonexistent zone file verbatim")
    func setInstrumentSamplerMissingFile() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zones": .array([
                        .object(["path": .string("/nope/Ghost.aiff")])])])]
        ))
        #expect(!response.ok)
        #expect(response.error == "Audio import failed: no file at /nope/Ghost.aiff")
        #expect(store.tracks[0].instrument == nil)
    }

    // M3 (v).
    @Test("project.snapshot emits sampler zones with a filesystem path")
    func snapshotSamplerShape() async throws {
        let (router, store) = makeRouter()
        let inst = store.addTrack(kind: .instrument)
        store.addTrack(kind: .audio)
        try store.setInstrument(
            id: inst.id, kind: .sampler,
            sampler: SamplerParams(zones: [
                SamplerZone(audioFileURL: URL(fileURLWithPath: Self.pingPath), rootPitch: 55)
            ]))

        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        guard case .array(let tracks)? = response.result?["tracks"] else {
            Issue.record("snapshot has no tracks array"); return
        }
        #expect(tracks[0]["instrument"]?["kind"]?.stringValue == "sampler")
        // polySynth params still ride along on the resolved descriptor.
        #expect(tracks[0]["instrument"]?["polySynth"]?["waveform"]?.stringValue != nil)
        let zone = try #require(tracks[0]["instrument"]?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(zone["path"]?.stringValue == Self.pingPath)
        #expect(zone["rootPitch"]?.doubleValue == 55)
        // The audio track still omits the instrument key entirely.
        #expect(tracks[1]["instrument"] == nil)
    }

    // T19.
    @Test("transport.record with no armed tracks passes the exact message through")
    func recordNoArmedTracks() async {
        let engine = FakeEngine()
        let (router, store) = makeRouter(engine: engine)
        store.addTrack(kind: .audio)  // present but not armed

        let response = await router.handle(ControlRequest(id: "1", command: "transport.record"))
        #expect(!response.ok)
        #expect(response.error == "no armed audio or instrument tracks — arm a track (track.setArm) before recording")
        #expect(engine.startRecordingURLs.isEmpty)
        #expect(!store.transport.isRecording)
    }

    // T19.
    @Test("transport.record rolls, then transport.seek reports transportBusy")
    func seekWhileRecording() async throws {
        let engine = FakeEngine()
        let (router, store) = makeRouter(engine: engine)
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        let record = await router.handle(ControlRequest(id: "1", command: "transport.record"))
        #expect(record.ok)
        #expect(record.result?["isRecording"]?.boolValue == true)
        #expect(store.transport.isRecording)
        #expect(engine.startRecordingURLs.count == 1)

        let seek = await router.handle(ControlRequest(
            id: "2", command: "transport.seek", params: ["beats": .number(4)]
        ))
        #expect(!seek.ok)
        #expect(seek.error == "cannot seek while recording — stop first")

        let stop = await router.handle(ControlRequest(id: "3", command: "transport.stop"))
        #expect(stop.ok)
        #expect(engine.stopRecordingCount == 1)
    }

    /// Unique temp directory for the persistence route tests.
    private func tempDir() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ctl-persist-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // 19.
    @Test("project.save returns the save result and the bundle round-trips through project.open")
    func projectSaveAndOpen() async throws {
        let (router, store) = makeRouter()
        store.addTrack(name: "Vox")
        let path = tempDir().appendingPathComponent("Ctl Song").path

        let save = await router.handle(ControlRequest(
            id: "1", command: "project.save", params: ["path": .string(path)]
        ))
        #expect(save.ok)
        #expect(save.result?["path"]?.stringValue?.hasSuffix("Ctl Song.dawproj") == true)
        #expect(save.result?["mediaFilesCopied"]?.doubleValue == 0)
        guard case .array(let warnings)? = save.result?["warnings"] else {
            Issue.record("save result has no warnings array"); return
        }
        #expect(warnings.isEmpty)
        #expect(store.projectPath != nil)
        #expect(!store.isDirty)

        // A fresh store opens it back: response = {warnings, snapshot}.
        let (router2, store2) = makeRouter()
        let open = await router2.handle(ControlRequest(
            id: "2", command: "project.open", params: ["path": .string(path)]
        ))
        #expect(open.ok)
        #expect(open.result?["warnings"] != nil)
        #expect(open.result?["snapshot"]?["name"]?.stringValue == "Ctl Song")
        guard case .array(let tracks)? = open.result?["snapshot"]?["tracks"] else {
            Issue.record("open snapshot has no tracks array"); return
        }
        #expect(tracks.count == 1)
        #expect(tracks[0]["name"]?.stringValue == "Vox")
        #expect(store2.projectPath != nil)
    }

    // 20.
    @Test("project.save on an untitled session reports projectPathRequired verbatim")
    func projectSaveUntitled() async {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "project.save"))
        #expect(!response.ok)
        #expect(response.error
                == "project has no file yet — pass a path to project.save (e.g. ~/Documents/DAW Pro/My Song.dawproj)")
        #expect(store.projectPath == nil)
    }

    // 21.
    @Test("project.open reports openFailed for a missing bundle and flags a missing path")
    func projectOpenMissing() async {
        let (router, _) = makeRouter()
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("gone-\(UUID().uuidString)").path
        let expected = ProjectBundle.normalizedBundleURL(fromPath: missing).path

        let response = await router.handle(ControlRequest(
            id: "1", command: "project.open", params: ["path": .string(missing)]
        ))
        #expect(!response.ok)
        #expect(response.error == "project open failed: no project bundle at \(expected)")

        let noPath = await router.handle(ControlRequest(id: "2", command: "project.open"))
        #expect(!noPath.ok)
        #expect(noPath.error?.contains("path") == true)
    }

    // 22.
    @Test("project.new returns a clean untitled snapshot; project.* refuse while recording")
    func projectNewAndRecordingRefusals() async throws {
        let engine = FakeEngine()
        let (router, store) = makeRouter(engine: engine)
        store.addTrack(name: "Old")

        // discardChanges avoids a flush (which would touch the real Autosave dir).
        let new = await router.handle(ControlRequest(
            id: "1", command: "project.new", params: ["discardChanges": .bool(true)]
        ))
        #expect(new.ok)
        #expect(new.result?["name"]?.stringValue == "Untitled Session")
        guard case .array(let tracks)? = new.result?["tracks"] else {
            Issue.record("new snapshot has no tracks array"); return
        }
        #expect(tracks.isEmpty)
        #expect(new.result?["isDirty"]?.boolValue == false)
        #expect(new.result?["projectPath"] == nil)  // untitled → key omitted

        // Enter recording; all three routes refuse with the exact messages.
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        #expect(await router.handle(ControlRequest(id: "2", command: "transport.record")).ok)

        let save = await router.handle(ControlRequest(
            id: "3", command: "project.save", params: ["path": .string("/tmp/x")]
        ))
        #expect(save.error == "cannot save while recording — stop first")
        let open = await router.handle(ControlRequest(
            id: "4", command: "project.open", params: ["path": .string("/tmp/x")]
        ))
        #expect(open.error == "cannot open a project while recording — stop first")
        let newWhileRecording = await router.handle(ControlRequest(id: "5", command: "project.new"))
        #expect(newWhileRecording.error == "cannot start a new project while recording — stop first")
    }

    /// Two-device fixture shared by the input.* route tests.
    private func inputFixture() -> (CommandRouter, ProjectStore, FakeEngine) {
        let engine = FakeEngine()
        engine.inputDevices = [
            AudioInputDevice(uid: "builtin-mic", name: "MacBook Pro Microphone",
                             sampleRate: 48_000, channelCount: 1, isDefault: true),
            AudioInputDevice(uid: "usb-2i2", name: "Scarlett 2i2",
                             sampleRate: 44_100, channelCount: 2, isDefault: false),
        ]
        let (router, store) = makeRouter(engine: engine)
        return (router, store, engine)
    }

    @Test("input.listDevices returns the {devices: [...]} contract shape")
    func listInputDevices() async throws {
        // store.engine is weak — the engine binding must live to the end.
        let (router, _, engine) = inputFixture()

        let response = await router.handle(ControlRequest(id: "1", command: "input.listDevices"))
        #expect(response.ok)
        guard case .array(let devices)? = response.result?["devices"] else {
            Issue.record("result has no devices array")
            return
        }
        try #require(devices.count == 2)
        #expect(devices.map { $0["uid"]?.stringValue } == engine.inputDevices.map { $0.uid })
        #expect(devices[0]["uid"]?.stringValue == "builtin-mic")
        #expect(devices[0]["name"]?.stringValue == "MacBook Pro Microphone")
        #expect(devices[0]["sampleRate"]?.doubleValue == 48_000)
        #expect(devices[0]["channelCount"]?.doubleValue == 1)
        #expect(devices[0]["isDefault"]?.boolValue == true)
        #expect(devices[1]["uid"]?.stringValue == "usb-2i2")
        #expect(devices[1]["isDefault"]?.boolValue == false)
    }

    @Test("input.setDevice selects, rejects unknown uids, and null resets")
    func setInputDevice() async {
        let (router, store, engine) = inputFixture()

        let select = await router.handle(ControlRequest(
            id: "1", command: "input.setDevice", params: ["uid": .string("usb-2i2")]
        ))
        #expect(select.ok)
        #expect(store.selectedInputDeviceUID == "usb-2i2")
        #expect(engine.selectedInputUID == "usb-2i2")
        // Success result = the same device-list shape, selection applied.
        guard case .array(let devices)? = select.result?["devices"] else {
            Issue.record("setDevice result has no devices array")
            return
        }
        #expect(devices.count == 2)

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "input.setDevice", params: ["uid": .string("ghost")]
        ))
        #expect(!unknown.ok)
        #expect(unknown.error == "no input device with uid 'ghost' — use input.listDevices")
        #expect(store.selectedInputDeviceUID == "usb-2i2")  // untouched on failure

        let reset = await router.handle(ControlRequest(
            id: "3", command: "input.setDevice", params: ["uid": .null]
        ))
        #expect(reset.ok)
        #expect(store.selectedInputDeviceUID == nil)
        #expect(engine.selectedInputUID == nil)
    }

    @Test("input.setDevice while recording reports transportBusy verbatim")
    func setInputDeviceWhileRecording() async throws {
        // store.engine is weak — the engine binding must live to the end.
        let (router, store, engine) = inputFixture()
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        #expect(await router.handle(ControlRequest(id: "1", command: "transport.record")).ok)

        let response = await router.handle(ControlRequest(
            id: "2", command: "input.setDevice", params: ["uid": .string("usb-2i2")]
        ))
        #expect(!response.ok)
        #expect(response.error == "cannot switch input device while recording — stop first")
        #expect(store.selectedInputDeviceUID == nil)
        #expect(engine.selectedInputUID == nil)  // never reached the engine
    }

    // 19.
    @Test("edit.undo after track.add returns the undone label and the post-undo snapshot")
    func editUndoRoundTrip() async throws {
        let (router, store) = makeRouter()

        let add = await router.handle(ControlRequest(
            id: "1", command: "track.add", params: ["name": .string("Vox")]
        ))
        #expect(add.ok)
        #expect(store.tracks.count == 1)

        let undo = await router.handle(ControlRequest(id: "2", command: "edit.undo"))
        #expect(undo.ok)
        #expect(undo.result?["undone"]?.stringValue == "Add Track 'Vox'")
        // The full snapshot rides along, already reflecting the reversal.
        guard case .array(let tracks)? = undo.result?["snapshot"]?["tracks"] else {
            Issue.record("undo result has no snapshot.tracks array"); return
        }
        #expect(tracks.isEmpty)
        #expect(store.tracks.isEmpty)

        // And redo reapplies it, reporting the same label.
        let redo = await router.handle(ControlRequest(id: "3", command: "edit.redo"))
        #expect(redo.ok)
        #expect(redo.result?["redone"]?.stringValue == "Add Track 'Vox'")
        #expect(store.tracks.count == 1)
    }

    // 20.
    @Test("edit.undo / edit.redo on empty history report the exact messages")
    func editUndoRedoEmpty() async {
        let (router, _) = makeRouter()

        let undo = await router.handle(ControlRequest(id: "1", command: "edit.undo"))
        #expect(!undo.ok)
        #expect(undo.error == "nothing to undo")

        let redo = await router.handle(ControlRequest(id: "2", command: "edit.redo"))
        #expect(!redo.ok)
        #expect(redo.error == "nothing to redo")
    }

    // 21.
    @Test("allCommands advertises edit.undo and edit.redo")
    func editCommandsAdvertised() async {
        #expect(CommandRouter.allCommands.contains("edit.undo"))
        #expect(CommandRouter.allCommands.contains("edit.redo"))
    }

    // MIDI 17.
    @Test("clip.addMIDI adds a MIDI clip onto an instrument track and returns clip JSON")
    func addMIDIHappyPath() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.addMIDI",
            params: [
                "trackId": .string(instID),
                "name": .string("Lead"),
                "atBeat": .number(4),
                "lengthBeats": .number(8),
                "notes": .array([
                    .object(["pitch": .number(72), "startBeat": .number(2)]),
                    .object(["pitch": .number(60), "startBeat": .number(0),
                             "velocity": .number(90), "lengthBeats": .number(1.5)]),
                ]),
            ]
        ))
        #expect(response.ok)
        #expect(response.result?["name"]?.stringValue == "Lead")
        #expect(response.result?["startBeat"]?.doubleValue == 4)
        #expect(response.result?["lengthBeats"]?.doubleValue == 8)
        guard case .array(let notes)? = response.result?["notes"] else {
            Issue.record("addMIDI result has no notes array"); return
        }
        #expect(notes.count == 2)
        // Canonically ordered: onset 0 (pitch 60) before onset 2 (pitch 72).
        #expect(notes[0]["pitch"]?.doubleValue == 60)
        #expect(notes[0]["velocity"]?.doubleValue == 90)
        #expect(notes[1]["pitch"]?.doubleValue == 72)
        #expect(notes[1]["velocity"]?.doubleValue == 100)   // default applied
        #expect(store.tracks[0].clips.count == 1)
    }

    // MIDI 18.
    @Test("clip.addMIDI validates track kind, notes shape, and beat params verbatim")
    func addMIDIValidation() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString
        let audioID = store.addTrack(kind: .audio).id.uuidString

        func addMIDI(_ params: [String: JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(id: "x", command: "clip.addMIDI", params: params))
        }

        // Wrong track kind (audio) → verbatim message.
        let wrongKind = await addMIDI(["trackId": .string(audioID)])
        #expect(!wrongKind.ok)
        #expect(wrongKind.error
                == "track kind 'audio' cannot hold MIDI clips — only instrument tracks accept MIDI clips (add one with track.add kind=instrument)")

        // notes not an array.
        let notArray = await addMIDI(["trackId": .string(instID), "notes": .string("nope")])
        #expect(notArray.error == "'notes' must be an array of {pitch, startBeat, velocity?, lengthBeats?, id?}")

        // Per-note field errors, keyed by index.
        let badPitch = await addMIDI(["trackId": .string(instID),
            "notes": .array([.object(["pitch": .number(200), "startBeat": .number(0)])])])
        #expect(badPitch.error == "notes[0].pitch must be an integer 0-127")

        let fractionalPitch = await addMIDI(["trackId": .string(instID),
            "notes": .array([.object(["pitch": .number(60.5), "startBeat": .number(0)])])])
        #expect(fractionalPitch.error == "notes[0].pitch must be an integer 0-127")

        let badStart = await addMIDI(["trackId": .string(instID),
            "notes": .array([.object(["pitch": .number(60), "startBeat": .number(-1)])])])
        #expect(badStart.error == "notes[0].startBeat must be a number >= 0 (beats, relative to the clip start)")

        let badVel = await addMIDI(["trackId": .string(instID),
            "notes": .array([.object(["pitch": .number(60), "startBeat": .number(0),
                                      "velocity": .number(0)])])])
        #expect(badVel.error == "notes[0].velocity must be an integer 1-127 (0 is note-off; omit for the default 100)")

        let badLen = await addMIDI(["trackId": .string(instID),
            "notes": .array([.object(["pitch": .number(60), "startBeat": .number(0),
                                      "lengthBeats": .number(0)])])])
        #expect(badLen.error == "notes[0].lengthBeats must be > 0")

        let badID = await addMIDI(["trackId": .string(instID),
            "notes": .array([.object(["pitch": .number(60), "startBeat": .number(0),
                                      "id": .string("not-a-uuid")])])])
        #expect(badID.error == "notes[0].id is not a valid UUID: not-a-uuid")

        // 4096-notes cap.
        let overCap = Array(repeating: JSONValue.object(
            ["pitch": .number(60), "startBeat": .number(0)]), count: 4097)
        let capped = await addMIDI(["trackId": .string(instID), "notes": .array(overCap)])
        #expect(capped.error == "'notes' exceeds the 4096-notes-per-clip limit (got 4097)")

        // Beat-param guards.
        let negAtBeat = await addMIDI(["trackId": .string(instID), "atBeat": .number(-1)])
        #expect(negAtBeat.error == "'atBeat' must be >= 0")
        let zeroLength = await addMIDI(["trackId": .string(instID), "lengthBeats": .number(0)])
        #expect(zeroLength.error == "'lengthBeats' must be > 0")

        // No clip landed anywhere on a rejected call.
        #expect(store.tracks.allSatisfy { $0.clips.isEmpty })
    }

    // MIDI 19.
    @Test("clip.setNotes replaces notes and reports notAMIDIClip / clipNotFound / bad params verbatim")
    func setNotesRoute() async throws {
        let (router, store) = makeRouter()
        let inst = store.addTrack(kind: .instrument)
        let midiClip = try store.addMIDIClip(toTrack: inst.id)
        let audioTrack = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(
            url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: audioTrack.id)

        // Happy path.
        let ok = await router.handle(ControlRequest(
            id: "1", command: "clip.setNotes",
            params: ["clipId": .string(midiClip.id.uuidString),
                     "notes": .array([.object(["pitch": .number(64), "startBeat": .number(0)])])]
        ))
        #expect(ok.ok)
        guard case .array(let notes)? = ok.result?["notes"] else {
            Issue.record("setNotes result has no notes array"); return
        }
        #expect(notes.count == 1)
        #expect(notes[0]["pitch"]?.doubleValue == 64)
        #expect(store.tracks[0].clips[0].notes?.count == 1)

        // An empty array is valid (clears the clip).
        let cleared = await router.handle(ControlRequest(
            id: "2", command: "clip.setNotes",
            params: ["clipId": .string(midiClip.id.uuidString), "notes": .array([])]
        ))
        #expect(cleared.ok)
        #expect(store.tracks[0].clips[0].notes == [])

        // notAMIDIClip on an audio clip.
        let wrong = await router.handle(ControlRequest(
            id: "3", command: "clip.setNotes",
            params: ["clipId": .string(audioClip.id.uuidString), "notes": .array([])]
        ))
        #expect(wrong.error
                == "clip \(audioClip.id.uuidString) is an audio clip — clip.setNotes applies only to MIDI clips (created via clip.addMIDI)")

        // clipNotFound for an unknown id.
        let unknown = UUID()
        let missing = await router.handle(ControlRequest(
            id: "4", command: "clip.setNotes",
            params: ["clipId": .string(unknown.uuidString), "notes": .array([])]
        ))
        #expect(missing.error
                == "no clip with id \(unknown.uuidString) — use project.snapshot to list clips")

        // Missing notes param, and a malformed clipId.
        let noNotes = await router.handle(ControlRequest(
            id: "5", command: "clip.setNotes",
            params: ["clipId": .string(midiClip.id.uuidString)]
        ))
        #expect(!noNotes.ok)
        #expect(noNotes.error?.contains("notes") == true)

        let badID = await router.handle(ControlRequest(
            id: "6", command: "clip.setNotes",
            params: ["clipId": .string("nope"), "notes": .array([])]
        ))
        #expect(badID.error == "'clipId' is not a valid UUID: nope")
    }

    // MIDI 20.
    @Test("clip.remove removes a clip and reports clipNotFound / bad clipId verbatim")
    func removeClipRoute() async throws {
        let (router, store) = makeRouter()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, name: "Gone")

        let removed = await router.handle(ControlRequest(
            id: "1", command: "clip.remove", params: ["clipId": .string(clip.id.uuidString)]
        ))
        #expect(removed.ok)
        #expect(removed.result?["name"]?.stringValue == "Gone")
        #expect(store.tracks[0].clips.isEmpty)

        let unknown = UUID()
        let missing = await router.handle(ControlRequest(
            id: "2", command: "clip.remove", params: ["clipId": .string(unknown.uuidString)]
        ))
        #expect(missing.error
                == "no clip with id \(unknown.uuidString) — use project.snapshot to list clips")

        let badID = await router.handle(ControlRequest(
            id: "3", command: "clip.remove", params: ["clipId": .string("nope")]
        ))
        #expect(badID.error == "'clipId' is not a valid UUID: nope")
    }

    // MIDI 21.
    @Test("allCommands advertises the MIDI clip commands")
    func midiCommandsAdvertised() async {
        #expect(CommandRouter.allCommands.contains("clip.addMIDI"))
        #expect(CommandRouter.allCommands.contains("clip.setNotes"))
        #expect(CommandRouter.allCommands.contains("clip.remove"))
    }

    // debug.* app-command-handler hook (app-layer surface, off allCommands).
    @Test("debug.captureUI with no app handler installed is an unknown command")
    func appHandlerAbsent() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "debug.captureUI"))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown command") == true)
        // debug.* stays out of the canonical/MCP list by convention.
        #expect(!CommandRouter.allCommands.contains("debug.captureUI"))
    }

    @Test("an installed app handler returning a payload wraps as success")
    func appHandlerSuccess() async {
        let (router, _) = makeRouter()
        router.appCommandHandler = { command, params in
            guard command == "debug.captureUI" else { return nil }
            let scale = params["scale"]?.doubleValue ?? 2
            return .object([
                "path": .string("/tmp/dawpro-capture.png"),
                "width": .number(1280 * scale),
                "height": .number(800 * scale),
            ])
        }
        let response = await router.handle(ControlRequest(
            id: "1", command: "debug.captureUI", params: ["scale": .number(2)]
        ))
        #expect(response.ok)
        #expect(response.result?["path"]?.stringValue == "/tmp/dawpro-capture.png")
        #expect(response.result?["width"]?.doubleValue == 2560)
        #expect(response.result?["height"]?.doubleValue == 1600)
    }

    @Test("an app handler returning nil falls through to the unknown-command error")
    func appHandlerNilFallsThrough() async {
        let (router, _) = makeRouter()
        router.appCommandHandler = { _, _ in nil }
        let response = await router.handle(ControlRequest(id: "1", command: "debug.captureUI"))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown command") == true)
    }

    @Test("an app handler that throws surfaces its message readably")
    func appHandlerThrows() async {
        let (router, _) = makeRouter()
        router.appCommandHandler = { _, _ in
            throw StubHandlerError(message: "cannot write capture to /nope/x.png: permission denied")
        }
        let response = await router.handle(ControlRequest(id: "1", command: "debug.captureUI"))
        #expect(!response.ok)
        #expect(response.error == "cannot write capture to /nope/x.png: permission denied")
    }

    @Test("snapshot returns full session state")
    func snapshot() async {
        let (router, store) = makeRouter()
        store.addTrack(name: "Vox")
        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        #expect(response.result?["name"]?.stringValue == "Untitled Session")
        if case .array(let tracks)? = response.result?["tracks"] {
            #expect(tracks.count == 1)
            #expect(tracks[0]["name"]?.stringValue == "Vox")
        } else {
            Issue.record("snapshot has no tracks array")
        }
    }

    @Test("errors are structured, not crashes")
    func errors() async {
        let (router, _) = makeRouter()

        let unknown = await router.handle(ControlRequest(id: "1", command: "nope.nope"))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("unknown command") == true)

        let missingParam = await router.handle(ControlRequest(id: "2", command: "transport.setTempo"))
        #expect(!missingParam.ok)
        #expect(missingParam.error?.contains("bpm") == true)

        let badID = await router.handle(ControlRequest(
            id: "3", command: "track.setVolume",
            params: ["trackId": .string("not-a-uuid"), "volume": .number(1)]
        ))
        #expect(!badID.ok)

        let goneTrack = await router.handle(ControlRequest(
            id: "4", command: "track.remove",
            params: ["trackId": .string(UUID().uuidString)]
        ))
        #expect(!goneTrack.ok)
        #expect(goneTrack.error?.contains("no track") == true)
    }

    @Test("every advertised command has a route")
    func commandListIsHonest() async throws {
        let engine = FakeEngine()  // render.mixdown + transport.record need an engine
        let (router, store) = makeRouter(engine: engine)
        let track = store.addTrack()
        let trackID = track.id.uuidString
        // An instrument track for clip.addMIDI (MIDI clips are instrument-only).
        let instTrackID = store.addTrack(kind: .instrument).id.uuidString
        // Two buses + a pre-made send so the routing routes have live destinations
        // and a real sendId (track.setSend/removeSend need one) when their turn
        // comes: track.setOutput/addSend target busA, and the pre-made send to
        // busB is the one track.setSend edits and track.removeSend deletes.
        let busA = store.addTrack(name: "BusA", kind: .bus).id.uuidString
        let busB = store.addTrack(name: "BusB", kind: .bus).id.uuidString
        let preSendID = try store.addSend(
            toTrack: track.id, busID: UUID(uuidString: busB)!, level: 1
        ).id.uuidString
        // Automation: a persistent volume lane for setPoints/setLaneEnabled,
        // and a pan lane automation.addLane's dry-run recreates idempotently
        // (same id) and automation.removeLane deletes — both independent of
        // where the four automation.* routes fall in allCommands order.
        let preLaneID = try store.addAutomationLane(trackID: track.id, target: .volume).id.uuidString
        let removableLaneID = try store.addAutomationLane(trackID: track.id, target: .pan).id.uuidString
        // transport.record iterates before track.setArm — arm up front so the
        // record route succeeds when its turn comes.
        try store.setTrackArm(id: track.id, armed: true)
        let paramsByCommand: [String: [String: JSONValue]] = [
            "transport.seek": ["beats": .number(0)],
            "transport.setTempo": ["bpm": .number(120)],
            "transport.setLoop": ["enabled": .bool(true), "startBeat": .number(0), "endBeat": .number(8)],
            // Runs before transport.record in allCommands; the record route
            // then proves a punched record() start succeeds end-to-end.
            "transport.setPunch": ["enabled": .bool(true), "inBeat": .number(0), "outBeat": .number(8)],
            // Runs before transport.record in allCommands — the metronome
            // route is refused mid-take, so ordering is load-bearing here.
            "transport.setMetronome": ["enabled": .bool(true), "countInBars": .number(1)],
            "track.add": [:],
            "track.remove": ["trackId": .string(trackID)],
            "track.rename": ["trackId": .string(trackID), "name": .string("X")],
            "track.setVolume": ["trackId": .string(trackID), "volume": .number(1)],
            "track.setPan": ["trackId": .string(trackID), "pan": .number(0)],
            "track.setMute": ["trackId": .string(trackID), "muted": .bool(false)],
            "track.setSolo": ["trackId": .string(trackID), "soloed": .bool(false)],
            // Routing routes (order in allCommands: setOutput, addSend, setSend,
            // removeSend). addSend targets busA (no existing send there); setSend/
            // removeSend act on the pre-made send to busB.
            "track.setOutput": ["trackId": .string(trackID), "busId": .string(busA)],
            "track.addSend": ["trackId": .string(trackID), "busId": .string(busA)],
            "track.setSend": ["trackId": .string(trackID), "sendId": .string(preSendID), "level": .number(0.5)],
            "track.removeSend": ["trackId": .string(trackID), "sendId": .string(preSendID)],
            // Instrument-only; use the instrument track (the shared trackID is audio).
            "track.setInstrument": ["trackId": .string(instTrackID), "waveform": .string("saw")],
            // fx.add creates an effect on the shared audio track; the effect-id-
            // dependent fx routes (remove/reorder/setBypass/setParam) are excluded
            // below and proven by FXCommandTests. fx.describe needs no params.
            "fx.add": ["trackId": .string(trackID), "kind": .string("gain")],
            "mixer.setMasterVolume": ["volume": .number(1)],
            // automation.addLane targets "pan" — idempotent against the
            // pre-made removableLaneID, so it succeeds regardless of when it
            // runs relative to automation.removeLane below.
            "automation.addLane": ["trackId": .string(trackID), "target": .object(["type": .string("pan")])],
            "automation.setPoints": ["trackId": .string(trackID), "laneId": .string(preLaneID),
                                     "points": .array([.object(["beat": .number(0), "value": .number(1)])])],
            "automation.setLaneEnabled": ["trackId": .string(trackID), "laneId": .string(preLaneID),
                                          "enabled": .bool(true)],
            "automation.removeLane": ["trackId": .string(trackID), "laneId": .string(removableLaneID)],
            "clip.addAudio": ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")],
            // Empty notes → a 4-beat MIDI clip on the instrument track.
            "clip.addMIDI": ["trackId": .string(instTrackID)],
            // Explicit duration so the route succeeds regardless of clip state.
            "render.mixdown": ["durationSeconds": .number(0.1)],
            // Explicit duration so these route regardless of clip state too
            // (M5 iv-d); trackIds omitted = every master input.
            "render.measureLoudness": ["durationSeconds": .number(0.1)],
            "render.bounce": ["durationSeconds": .number(0.1)],
            "render.stems": ["durationSeconds": .number(0.1)],
            "transport.record": [:],
            "track.setArm": ["trackId": .string(trackID), "armed": .bool(true)],
            "input.listDevices": [:],
            // uid omitted = system default, always valid.
            "input.setDevice": [:],
        ]
        for command in CommandRouter.allCommands {
            // track.remove deletes the shared track; the project.* routes need
            // real filesystem setup (or a stopped transport — this loop is mid-
            // record by now); edit.undo/edit.redo are refused mid-take and need
            // real history; clip.setNotes/clip.remove/clip.split/clip.trim/
            // clip.move/clip.setGain/clip.setFades/clip.quantize/
            // clip.detectTransients/clip.quantizeAudio need a clip id that only
            // exists after clip.addMIDI runs; take.* need a group id that only
            // exists after take.group runs on >= 2 overlapping clips;
            // groove.extract/groove.remove need a clip/groove id (groove.list
            // takes no params and is exercised here). ai.sidecarStart/Stop
            // spawn/signal a REAL process via this router's default (real)
            // SidecarManager — legitimately fail/no-op on a machine without
            // ACE-Step installed, so they're excluded here; ai.sidecarStatus
            // is side-effect-free (never throws) and stays IN the loop,
            // exercised against whatever's actually true on disk. ai.generateSong/
            // ai.generationStatus likewise hit a REAL ACEStepClient talking to a
            // REAL (almost certainly not-running-in-CI) sidecar, so they're
            // excluded the same way — the submit/poll contract itself is proven
            // by SongGenerationCommandTests (FakeSongGenerator) and
            // AIServicesTests/ACEStepClientTests (stub HTTP server). All are
            // proven by dedicated tests.
            if ["track.remove", "project.save", "project.open", "project.new",
                "edit.undo", "edit.redo", "clip.setNotes", "clip.remove",
                "clip.split", "clip.trim", "clip.move", "clip.setGain", "clip.setFades",
                "clip.setStretch", "clip.stretchToLength", "clip.quantize",
                "clip.detectTransients", "clip.quantizeAudio",
                "fx.remove", "fx.reorder", "fx.setBypass", "fx.setParam",
                "take.group", "take.setComp", "take.select", "take.removeLane",
                "take.flatten", "take.move", "take.setCrossfade",
                "groove.extract", "groove.remove",
                "ai.sidecarStart", "ai.sidecarStop",
                "ai.generateSong", "ai.generationStatus"].contains(command) {
                continue
            }
            let response = await router.handle(ControlRequest(
                id: command, command: command, params: paramsByCommand[command]
            ))
            #expect(response.ok, "command \(command) failed: \(response.error ?? "?")")
        }
    }
}

@Suite("Transport broadcast payload")
struct TransportBroadcastTests {
    @Test("encodes to the {event, transport} frame shape")
    func broadcastShape() async throws {
        let payload = TransportBroadcast(
            transport: TransportState(isLoopEnabled: true, loopStartBeat: 2, loopEndBeat: 10)
        )
        let value = try JSONValue(encoding: payload)
        #expect(value["event"]?.stringValue == "transport")
        #expect(value["transport"]?["isLoopEnabled"]?.boolValue == true)
        #expect(value["transport"]?["loopStartBeat"]?.doubleValue == 2)
        #expect(value["transport"]?["loopEndBeat"]?.doubleValue == 10)
        // Broadcasts are unsolicited: no request id on the frame.
        #expect(value["id"] == nil)
    }
}
