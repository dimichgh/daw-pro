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

    /// m25-d end-of-content stop: every bound the store pushed, in order.
    /// Spying the whole sequence (not just the latest value) is what lets a
    /// test prove a take was DISARMED rather than merely never armed.
    private(set) var endStopPushes: [Double?] = []
    var currentEndStop: Double? { endStopPushes.last ?? nil }
    func clearEndStopPushes() { endStopPushes.removeAll() }
    func setEndStop(beat: Double?) { endStopPushes.append(beat) }

    /// m22-c: live loudness support, so the every-command routing loop can
    /// exercise `mixer.liveLoudness` inline (the protocol DEFAULT is nil →
    /// engineUnavailable — that teaching path is pinned in
    /// LiveLoudnessCommandTests). The empty snapshot is the honest
    /// "nothing analyzed yet" answer a real idle engine gives.
    func liveLoudness(reset: Bool) -> LiveLoudnessSnapshot? { .empty }

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

    /// m20-j output twin. `outputDevices` is the raw hardware list WITHOUT
    /// `isSelected` set; `availableOutputDevices()` stamps it from
    /// `selectedOutputUID` exactly as `AudioEngine` does via
    /// `OutputDevices.enumerate(selectedUID:)`, so the wire tests exercise the
    /// real "following the default" vs "pinned" distinction rather than a
    /// hand-written flag.
    var outputDevices: [AudioOutputDevice] = []
    private(set) var selectedOutputUID: String?

    func availableOutputDevices() -> [AudioOutputDevice] {
        outputDevices.map {
            var device = $0
            device.isSelected = selectedOutputUID != nil && $0.uid == selectedOutputUID
            return device
        }
    }

    func setOutputDevice(uid: String?) throws {
        if let uid, !outputDevices.contains(where: { $0.uid == uid }) {
            throw ProjectError.outputDeviceNotFound(uid)
        }
        selectedOutputUID = uid
    }

    func startRecording(_ transport: TransportState, to url: URL,
                        completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {
        startRecordingURLs.append(url)
    }

    func stopRecording() { stopRecordingCount += 1 }

    func renderMixdown(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
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
    func renderOffline(tracks: [Track], tempoMap: TempoMap, masterVolume: Double,
                       masterEffects: [EffectDescriptor],
                       masterAutomation: [AutomationLane],
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
    func setMasterVolume() async throws {
        let (router, store) = makeRouter()

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.setMasterVolume", params: ["volume": .number(0.5)]
        ))
        #expect(response.ok)
        #expect(response.result?["masterVolume"]?.doubleValue == 0.5)
        #expect(store.masterVolume == 0.5)
        // In range: nothing was clamped, so nothing is announced.
        #expect(response.result?["warnings"] == nil)

        // Out-of-range values clamp; the response reports the applied gain.
        //
        // ⭐ m27-c, MEASURED WHILE VERIFYING THAT ITEM'S PREMISE: the item
        // asserts this verb REJECTS above 2.0 while the gain insert clamps.
        // It does NOT — this line is the proof, and it predates m27-c. The
        // asymmetry is real but lives one layer up, in
        // `mixer_set_master_volume`'s zod `.min(0).max(2)`: the MCP tool
        // refuses, the control command clamps. So a WIRE caller could send
        // 3.0 and be told `{masterVolume: 2}` with nothing saying why.
        let clamped = await router.handle(ControlRequest(
            id: "2", command: "mixer.setMasterVolume", params: ["volume": .number(3)]
        ))
        #expect(clamped.ok)
        #expect(clamped.result?["masterVolume"]?.doubleValue == 2)
        #expect(store.masterVolume == 2)
        // m27-c: it now says why, in the same `warnings` shape fx.setParam
        // uses — and points at the cure that actually reaches the level.
        let sentence = try #require(clamped.result?["warnings"]?.arrayValue?.first?.stringValue)
        #expect(sentence.hasPrefix("volume was clamped to its maximum 2 — you asked for 3, "
                                   + "and this control accepts 0 to 2."))
        #expect(sentence.contains("gainLinear reaches 16 (+24.08 dB)"))
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
        #expect(response.error
            == "nothing to render — no clips found in the render range; "
            + "add clips or pass an explicit durationSeconds")
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
        // soundBank joined the list in m10-n-1 (wire-valid via Kind.allCases;
        // the bank param itself is the m10-n-2 wire delta). drumSynth joined at
        // m39-dm the same way — the message is DERIVED from Kind.allCases, so
        // this literal is the pin that proves the derivation still reaches the
        // wire, and it moves once per new kind by design.
        #expect(badKind.error
                == "kind must be one of testTone|polySynth|sampler|audioUnit|soundBank|drumSynth")

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

    // M7 (agent-facing project snapshot).
    @Test("project.overview round-trips the summarized projection with top-level keys and track identity")
    func overviewWireShape() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "Gtr", kind: .audio)

        let response = await router.handle(ControlRequest(id: "1", command: "project.overview"))
        #expect(response.ok)
        // Top-level keys: transport, master, tracks — no wrapping envelope.
        #expect(response.result?["transport"]?["tempoBPM"]?.doubleValue == 120)
        #expect(response.result?["master"]?["volume"]?.doubleValue == 1)
        guard case .array(let tracks)? = response.result?["tracks"] else {
            Issue.record("overview has no tracks array"); return
        }
        #expect(tracks.count == 1)
        #expect(tracks[0]["id"]?.stringValue == track.id.uuidString)
        #expect(tracks[0]["name"]?.stringValue == "Gtr")
        #expect(tracks[0]["kind"]?.stringValue == "audio")
        // Counts, not lists: an empty track carries no clips/automation arrays
        // longer than reality, but the keys themselves stay arrays (empty).
        #expect(tracks[0]["clips"]?.arrayValue?.isEmpty == true)
    }

    // M7.
    @Test("allCommands advertises project.overview")
    func overviewAdvertised() async {
        #expect(CommandRouter.allCommands.contains("project.overview"))
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
        // m34-o: `decay?` and `sustain?` joined the accepted-key list when the
        // sampler gained instrument-level envelope globals. The message is a
        // KEY LIST, so omitting the two new keys would tell a caller they are
        // not accepted — which is now false, and worse than saying nothing.
        #expect(notObject.error
                == "sampler must be an object {zones, oneShot?, attack?, decay?, sustain?, release?, gain?}")

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

    // MARK: - Output devices (m20-j)

    /// Two-device fixture shared by the output.* route tests. Deliberately
    /// shaped like a real rig: the built-in speakers ARE the system default,
    /// the loopback is not — so `isDefault` and `isSelected` can be told apart.
    private func outputFixture() -> (CommandRouter, ProjectStore, FakeEngine) {
        let engine = FakeEngine()
        engine.outputDevices = [
            AudioOutputDevice(uid: "builtin-speakers", name: "MacBook Pro Speakers",
                              sampleRate: 48_000, channelCount: 2, isDefault: true),
            AudioOutputDevice(uid: "BlackHole2ch_UID", name: "BlackHole 2ch",
                              sampleRate: 44_100, channelCount: 2, isDefault: false),
        ]
        let (router, store) = makeRouter(engine: engine)
        return (router, store, engine)
    }

    @Test("output.listDevices returns the {devices: [...]} contract shape")
    func listOutputDevices() async throws {
        // store.engine is weak — the engine binding must live to the end.
        let (router, _, engine) = outputFixture()

        let response = await router.handle(ControlRequest(id: "1", command: "output.listDevices"))
        #expect(response.ok)
        guard case .array(let devices)? = response.result?["devices"] else {
            Issue.record("result has no devices array")
            return
        }
        try #require(devices.count == 2)
        #expect(devices.map { $0["uid"]?.stringValue } == engine.outputDevices.map { $0.uid })
        #expect(devices[0]["uid"]?.stringValue == "builtin-speakers")
        #expect(devices[0]["name"]?.stringValue == "MacBook Pro Speakers")
        #expect(devices[0]["sampleRate"]?.doubleValue == 48_000)
        #expect(devices[0]["channelCount"]?.doubleValue == 2)
        #expect(devices[0]["isDefault"]?.boolValue == true)
        // Nothing pinned yet — the app is FOLLOWING the system default, which
        // is not the same as having selected the default device.
        #expect(devices[0]["isSelected"]?.boolValue == false)
        #expect(devices[1]["uid"]?.stringValue == "BlackHole2ch_UID")
        #expect(devices[1]["isDefault"]?.boolValue == false)
        #expect(devices[1]["isSelected"]?.boolValue == false)
    }

    @Test("output.setDevice selects, rejects unknown uids, and null resets")
    func setOutputDevice() async {
        let (router, store, engine) = outputFixture()

        let select = await router.handle(ControlRequest(
            id: "1", command: "output.setDevice", params: ["uid": .string("BlackHole2ch_UID")]
        ))
        #expect(select.ok)
        #expect(store.selectedOutputDeviceUID == "BlackHole2ch_UID")
        #expect(engine.selectedOutputUID == "BlackHole2ch_UID")
        // Success result = the same device-list shape, selection ALREADY
        // applied — the caller reads the new pin straight off isSelected.
        guard case .array(let devices)? = select.result?["devices"] else {
            Issue.record("setDevice result has no devices array")
            return
        }
        #expect(devices.count == 2)
        #expect(devices[0]["isSelected"]?.boolValue == false)  // the default, not selected
        #expect(devices[1]["isSelected"]?.boolValue == true)   // the pin
        #expect(devices[1]["isDefault"]?.boolValue == false)   // and it is NOT the default

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "output.setDevice", params: ["uid": .string("ghost")]
        ))
        #expect(!unknown.ok)
        #expect(unknown.error == "no output device with uid 'ghost' — use output.listDevices")
        #expect(store.selectedOutputDeviceUID == "BlackHole2ch_UID")  // untouched on failure

        let reset = await router.handle(ControlRequest(
            id: "3", command: "output.setDevice", params: ["uid": .null]
        ))
        #expect(reset.ok)
        #expect(store.selectedOutputDeviceUID == nil)
        #expect(engine.selectedOutputUID == nil)
        guard case .array(let afterReset)? = reset.result?["devices"] else {
            Issue.record("reset result has no devices array")
            return
        }
        #expect(afterReset.allSatisfy { $0["isSelected"]?.boolValue == false })
    }

    /// The F5 "omit = destructive default" shape, copied from input.setDevice
    /// on purpose: omitting `uid` RESETS to the system default, so a typo'd key
    /// must be refused rather than silently bouncing the user's sound back to
    /// the laptop speakers and returning ok.
    @Test("output.setDevice: omitting uid resets, but a typo'd key is refused first")
    func setOutputDeviceOmittedAndTypo() async {
        let (router, store, engine) = outputFixture()
        #expect(await router.handle(ControlRequest(
            id: "1", command: "output.setDevice", params: ["uid": .string("BlackHole2ch_UID")]
        )).ok)

        // A typo'd key does NOT reset the pin — it teaches.
        let typo = await router.handle(ControlRequest(
            id: "2", command: "output.setDevice", params: ["device": .string("BlackHole2ch_UID")]
        ))
        #expect(!typo.ok)
        #expect(typo.error == "output.setDevice: unknown parameter 'device' — valid keys are 'uid'. "
                + "omit 'uid' (or pass it null) to select the system-default output")
        #expect(store.selectedOutputDeviceUID == "BlackHole2ch_UID")  // pin survived the typo
        #expect(engine.selectedOutputUID == "BlackHole2ch_UID")

        // An OMITTED uid is the deliberate reset path.
        let omitted = await router.handle(ControlRequest(id: "3", command: "output.setDevice"))
        #expect(omitted.ok)
        #expect(store.selectedOutputDeviceUID == nil)
        #expect(engine.selectedOutputUID == nil)

        // A non-string, non-null uid is a type error, not a reset.
        let wrongType = await router.handle(ControlRequest(
            id: "4", command: "output.setDevice", params: ["uid": .number(3)]
        ))
        #expect(!wrongType.ok)
        #expect(wrongType.error == "'uid' must be a string or null")
    }

    @Test("output.setDevice while recording reports transportBusy verbatim")
    func setOutputDeviceWhileRecording() async throws {
        // store.engine is weak — the engine binding must live to the end.
        let (router, store, engine) = outputFixture()
        let track = store.addTrack(kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)
        #expect(await router.handle(ControlRequest(id: "1", command: "transport.record")).ok)

        let response = await router.handle(ControlRequest(
            id: "2", command: "output.setDevice", params: ["uid": .string("BlackHole2ch_UID")]
        ))
        #expect(!response.ok)
        #expect(response.error == "cannot switch output device while recording — stop first")
        #expect(store.selectedOutputDeviceUID == nil)
        #expect(engine.selectedOutputUID == nil)  // never reached the engine
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
        // Markers (m11-c): allCommands order is add, remove, rename, move, list —
        // remove runs before rename/move, so give each mutation its OWN pre-made
        // marker (one target can't be shared: remove would delete it first).
        let removableMarkerID = store.addMarker(name: "Rm", beat: 0).id.uuidString
        let renamableMarkerID = store.addMarker(name: "Rn", beat: 4).id.uuidString
        let movableMarkerID = store.addMarker(name: "Mv", beat: 8).id.uuidString
        // m39-e: the seven strip-scoped `mod.*` verbs are DRIVEN, not excluded —
        // every one of them has an honest headless form. allCommands order is
        // describeKinds, addSource, setSource, removeSource, addRoute,
        // setRouteDepth, removeRoute, setMacro, describe, so each mutation gets
        // its OWN pre-made subject: removeSource deletes one source and CASCADES
        // its routes, which would silently disarm the route verbs if they shared
        // one. `mod.describe`/`mod.describeKinds` need no params at all (describe
        // defaults to the master strip) and are covered by the bare call.
        let editableSourceID = try store.addModulationSource(
            on: .track(track.id), kind: .lfo, name: "Edit").source.id.uuidString
        let removableSourceID = try store.addModulationSource(
            on: .track(track.id), kind: .lfo, name: "Rm").source.id.uuidString
        let routeSource = try store.addModulationSource(
            on: .track(track.id), kind: .macro, name: "Macro").source
        let routeSourceID = routeSource.id.uuidString
        let editableRouteID = try store.addModulationRoute(
            on: .track(track.id), sourceID: routeSource.id, target: .volume,
            depth: 0.1).route.id.uuidString
        let removableRouteID = try store.addModulationRoute(
            on: .track(track.id), sourceID: routeSource.id, target: .pan,
            depth: 0.1).route.id.uuidString
        // m39-levels-2 wire: instrument.spreadSlice/setSpreadDirection are
        // DRIVEN, not excluded — the mod.* precedent above, not the
        // instrument.describeSampler exclusion below: THAT verb is excluded
        // because instTrackID's own sampler is never configured (this loop's
        // track.setInstrument entry for instTrackID only sets a waveform).
        // These two get their OWN dedicated sampler-equipped tracks instead
        // of fighting over instTrackID. Each gets its own subject: spreadSlice
        // gets a fresh one-key "chop" zone; setSpreadDirection gets a zone
        // that is ALREADY spread, minted HERE via spreadSlice's own wire call
        // — NOT by relying on allCommands iteration order reaching
        // instrument.spreadSlice before instrument.setSpreadDirection in the
        // loop below, which is incidental placement, not a contract.
        func makeOneKeySamplerTrack() async throws -> (trackID: String, zoneID: String) {
            let sample = BundledSamples.catalog[0]
            let newTrackID = store.addTrack(kind: .instrument).id.uuidString
            let setup = await router.handle(ControlRequest(
                id: "levels-setup-\(newTrackID)", command: "track.setInstrument",
                params: [
                    "trackId": .string(newTrackID),
                    "kind": .string("sampler"),
                    "sampler": .object([
                        "zones": .array([
                            .object([
                                "path": .string(sample.wireName),
                                "rootPitch": .number(Double(sample.rootPitch)),
                                // Explicit, not omitted — an omitted minPitch/
                                // maxPitch defaults to the full 0...127 span,
                                // which leaves no free sixteen-key window
                                // anywhere. One key wide is the chopper's own
                                // shape (SliceToSampler.swift), by hand here.
                                "minPitch": .number(Double(sample.rootPitch)),
                                "maxPitch": .number(Double(sample.rootPitch)),
                            ]),
                        ]),
                    ]),
                ]))
            let newZoneID = try #require(setup.result?["sampler"]?["zones"]?
                .arrayValue?.first?["id"]?.stringValue)
            return (newTrackID, newZoneID)
        }
        let (spreadSliceTrackID, spreadSliceZoneID) = try await makeOneKeySamplerTrack()
        let (setSpreadTrackID, setSpreadSourceZoneID) = try await makeOneKeySamplerTrack()
        let preSpread = await router.handle(ControlRequest(
            id: "levels-setup-prespread", command: "instrument.spreadSlice",
            params: ["trackId": .string(setSpreadTrackID), "zoneId": .string(setSpreadSourceZoneID)]))
        let preSpreadZoneID = try #require(preSpread.result?["id"]?.stringValue)
        // clip.getPlayedPitch (m23-ap C-0c) is DRIVEN, not excluded — unlike
        // clip.detectPitch/clip.autoCorrectPitch/clip.clearPitchEdits/
        // clip.getPitchEdits/clip.setNotePitch/clip.splitNote below (all six
        // excluded because minting their real-clip prerequisite needs a
        // clip.addAudio WIRE call whose id this static paramsByCommand
        // dictionary has no way to capture and reuse). This one is
        // reachable a different way: `clip.addAudio` here, in SETUP, ahead
        // of the loop — its returned clipId IS capturable, because this
        // code runs before paramsByCommand is even built — then
        // `store.setClipNotePitchOffset(..., seedIfAbsent:)` OFF THE WIRE,
        // the C1 seeding rule's own in-process shortcut, mints a one-segment
        // stored note table with no real pitch detector involved. That
        // satisfies clip.getPlayedPitch's own two checks (a real AUDIO clip,
        // a non-empty stored table) without needing FakePitchDetectionEngine
        // machinery this suite's plain FakeEngine does not carry.
        let playedPitchTrackID = store.addTrack(kind: .audio).id.uuidString
        let playedPitchAdd = await router.handle(ControlRequest(
            id: "played-pitch-setup", command: "clip.addAudio",
            params: ["trackId": .string(playedPitchTrackID), "path": .string("/tmp/PlayedPitchFixture.wav")]))
        let playedPitchClipID = try #require(playedPitchAdd.result?["id"]?.stringValue)
        let playedPitchSegmentID = UUID()
        try store.setClipNotePitchOffset(
            clipId: try #require(UUID(uuidString: playedPitchClipID)),
            segmentId: playedPitchSegmentID, offsetCents: 0,
            seedIfAbsent: PitchEditSet(analysisVersion: PitchEditSet.currentAnalysisVersion, segments: [
                NoteSegment(id: playedPitchSegmentID, startSeconds: 0, endSeconds: 1,
                            detectedHz: 220, detectedConfidence: 1),
            ]))
        let paramsByCommand: [String: [String: JSONValue]] = [
            "clip.getPlayedPitch": ["clipId": .string(playedPitchClipID)],
            // I7a: clip.setNoteCleared is DRIVEN, not excluded, on the same
            // setup clip as clip.getPlayedPitch above. Its stored one-note
            // table, seeded off the wire, is exactly what the verb needs, so
            // a real clear routes and succeeds. A cleared note changes nothing
            // clip.getPlayedPitch needs, so their order in allCommands does
            // not matter.
            "clip.setNoteCleared": ["clipId": .string(playedPitchClipID),
                                    "segmentIds": .array([.string(playedPitchSegmentID.uuidString)]),
                                    "cleared": .bool(true)],
            // U-D: clip.setNoteGain is DRIVEN, not excluded, the
            // clip.setNoteCleared precedent immediately above — same setup
            // clip, same stored one-note table. A level write changes
            // nothing clip.getPlayedPitch needs either, so allCommands order
            // still does not matter.
            "clip.setNoteGain": ["clipId": .string(playedPitchClipID),
                                 "segmentIds": .array([.string(playedPitchSegmentID.uuidString)]),
                                 "gainDb": .number(-6)],
            // m23-ap I4 wire leg: clip.setNotePitches is DRIVEN, not
            // excluded, the clip.setNoteCleared/clip.setNoteGain precedent
            // immediately above — same setup clip, same stored one-note
            // table. This test only asserts `response.ok`, never a value, so
            // a pitch write's effect on what clip.getPlayedPitch WOULD then
            // return is irrelevant here (that assertion lives in
            // PitchCorrectionCommandTests, not here) — allCommands order
            // still does not matter.
            "clip.setNotePitches": ["clipId": .string(playedPitchClipID),
                                    "notes": .array([.object([
                                        "segmentId": .string(playedPitchSegmentID.uuidString),
                                        "cents": .number(50),
                                    ])])],
            // m23-ap I1 wire leg: clip.auditionNote is DRIVEN, not excluded,
            // the clip.setNoteCleared/clip.setNoteGain/clip.setNotePitches
            // precedent immediately above — same setup clip, same stored
            // one-note table (a real audio clip, not MIDI; a non-empty
            // stored table — clip.auditionNote's own two prerequisites,
            // identical to clip.getPlayedPitch's). The engine here
            // (FakeEngine) never overrides auditionClipSpan, so it answers
            // through AudioEngineControlling's own protocol-extension
            // default, `.unsupported` — a REAL, non-throwing answer
            // (`audible: false`), which is still `response.ok == true`: a
            // refusal without a throw is a SUCCESS on this door, never an
            // error. allCommands order still does not matter.
            "clip.auditionNote": ["clipId": .string(playedPitchClipID),
                                  "segmentIds": .array([.string(playedPitchSegmentID.uuidString)])],
            // C5a-3/NT-L3: the two vibrato writers are DRIVEN, not excluded,
            // the clip.setNoteCleared/setNoteGain/setNotePitches/auditionNote
            // precedent immediately above — same setup clip, same stored
            // one-note table. Neither writer reads `isCleared` (grepped:
            // NoteVibratoLimits.swift and setClipNotesVibrato's body have no
            // such check), only that the segment's `origin` is not
            // `.unpitched` — still `.detected` here, per the NT-W comment
            // below. `clip.setNoteVibratos` re-sends the same field on the
            // same note right after `clip.setNoteVibrato` (allCommands order:
            // vibrato immediately before vibratos) — a second absolute write
            // of the same value, not a conflict.
            "clip.setNoteVibrato": ["clipId": .string(playedPitchClipID),
                                    "segmentId": .string(playedPitchSegmentID.uuidString),
                                    "vibratoDepthCents": .number(20)],
            "clip.setNoteVibratos": ["clipId": .string(playedPitchClipID),
                                     "notes": .array([.object([
                                         "segmentId": .string(playedPitchSegmentID.uuidString),
                                         "vibratoDepthCents": .number(20),
                                     ])])],
            // m22-g P2: OFF is the idempotent never-refusing side of the A/B
            // monitor (design §5.6) — a legitimate headless route.
            "reference.setMonitor": ["on": .bool(false)],
            // m28-knob. DRIVEN with params rather than EXCLUDED, because both
            // of these have a genuinely inert form and route coverage is worth
            // more than an exclusion entry: an empty `bindings` array clears an
            // already-empty table, and `cancel` disarms a learn that was never
            // armed. ⚠️ `cancel` and NOT `target` on purpose — arming would
            // bring the CoreMIDI client up and connect to the user's real MIDI
            // sources, which a unit test must never do. (Arming IS covered, in
            // MIDIControlTests, against a fake engine.)
            // m23-ct: note.play is DRIVEN, not excluded — and driving it here is
            // the point. It is note.audition's neighbour in allCommands but its
            // OPPOSITE on the one axis that matters: it is deliberately NOT
            // refused while a take is rolling, because this path IS captured.
            // So it is the only note verb this loop can exercise with a REAL
            // pitch at the point where transport.record has left a take open —
            // genuine route coverage, not the degenerate no-op branch the
            // pad.previewEffort exclusion below warns about. A held note is
            // harmless: the store is discarded at the end of the test, and both
            // the controller's 30 s ceiling and the render side's 3 s watchdog
            // would release it anyway.
            "note.play": ["trackId": .string(instTrackID),
                          "pitches": .array([.number(60)])],
            // m23-cv: a pure computation, but it deliberately REFUSES an empty
            // call rather than defaulting to some chord nobody asked for — so
            // the bare loop has to say what to voice. `[1, 5]` is the smallest
            // input that also exercises the voice-leading step.
            "chord.voice": ["degrees": .array([.number(1), .number(5)])],
            // m34-l: the pedal. `down` is REQUIRED and deliberately has no
            // default — "press or lift?" is not a question a verb may guess at,
            // and a defaulted `false` would make a typo'd call silently lift a
            // pedal the user is holding. `true` is used here so the loop
            // exercises the VALIDATED branch rather than the never-refused lift;
            // the store is discarded at the end of the test, and `stopAll` on
            // the next project boundary lifts it regardless.
            "play.sustain": ["trackId": .string(instTrackID), "down": .bool(true)],
            "midi.setControlMap": ["bindings": .array([])],
            "midi.learnControl": ["cancel": .bool(true)],
            "transport.seek": ["beats": .number(0)],
            "marker.add": ["beat": .number(0)],
            "marker.remove": ["markerId": .string(removableMarkerID)],
            "marker.rename": ["markerId": .string(renamableMarkerID), "name": .string("X")],
            "marker.move": ["markerId": .string(movableMarkerID), "beat": .number(0)],
            "transport.setTempo": ["bpm": .number(120)],
            // tempo.map is a read (no params); tempo.setMap needs a valid map.
            "tempo.setMap": ["segments": .array([
                .object(["startBeat": .number(0), "bpm": .number(120)]),
                .object(["startBeat": .number(8), "bpm": .number(90)]),
            ])],
            "transport.setLoop": ["enabled": .bool(true), "startBeat": .number(0), "endBeat": .number(8)],
            // enabled:false (m15-b): macro.songSkeleton re-enables a loop over
            // the whole scaffold before transport.record's turn, and record
            // with loop AND punch both on now refuses by design (the §7
            // teaching error — pinned verbatim in LoopRecordCommandTests, and
            // the punched wire start is proven there too). The record route
            // below therefore proves the LOOP-record start end-to-end; the
            // punch route itself is still exercised (validation + toggle).
            "transport.setPunch": ["enabled": .bool(false), "inBeat": .number(0), "outBeat": .number(8)],
            // Runs before transport.record in allCommands — the metronome
            // route is refused mid-take, so ordering is load-bearing here.
            "transport.setMetronome": ["enabled": .bool(true), "countInBars": .number(1)],
            // m25-d. Registered LAST in allCommands, so this loop reaches it
            // mid-take — and it is deliberately ACCEPTED while recording
            // (inert, never armed) rather than refused, which is exactly what
            // makes it safe to exercise here instead of excluding it. Sending
            // `true` restores the default, leaving no state behind.
            "transport.setStopAtContentEnd": ["enabled": .bool(true)],
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
            // m39-f: STAYS IN THE LOOP, unlike its sibling
            // instrument.describeSampler two screens down in the exclusion
            // list — and the difference is the point, not an oversight. That
            // verb is excluded because a sampler can genuinely be UNCONFIGURED
            // and it refuses when it is; this one cannot hit that state,
            // because every instrument track HAS a poly synth (the default
            // one) and the verb describes it. So a bare call here is a real
            // route exercise with a real answer, which is exactly what this
            // loop is for. It needs only the trackId.
            "instrument.describeSynth": ["trackId": .string(instTrackID)],
            // m39-dm: all three STAY IN THE LOOP for the describeSynth reason
            // directly above — every instrument track carries a drum kit (the
            // default one) whether or not the drum machine is the ACTIVE
            // instrument, so none of them can hit the "unconfigured, therefore
            // refuses" state that excludes instrument.describeSampler. They
            // answer on this poly-synth track with isActiveInstrument: false,
            // which is a real route exercise with a real answer.
            // `instrument.listDrumPresets` takes no params and needs no entry.
            "instrument.setDrumParam": ["trackId": .string(instTrackID),
                                        "name": .string("kick.decay"),
                                        "value": .number(0.4)],
            "instrument.describeDrumKit": ["trackId": .string(instTrackID)],
            // Wholesale: this REPLACES the kick.decay written two entries above.
            // Harmless here — the loop proves routes, not values — but noted so
            // nobody later reads an ordering bug into it.
            "instrument.loadDrumPreset": ["trackId": .string(instTrackID),
                                          "name": .string("909")],
            // m39-levels-2 wire: see the dedicated-track setup above this
            // dictionary — each verb gets its own subject, independent of
            // where the other one falls in allCommands order.
            "instrument.spreadSlice": ["trackId": .string(spreadSliceTrackID),
                                       "zoneId": .string(spreadSliceZoneID)],
            "instrument.setSpreadDirection": ["trackId": .string(setSpreadTrackID),
                                              "spreadZoneId": .string(preSpreadZoneID),
                                              "direction": .string("centered")],
            // m23-h: track.reorder sits at the END of allCommands, by which
            // point track.remove has already deleted the shared audio trackID —
            // so it moves the INSTRUMENT track, which survives the whole loop
            // (bounceInPlace only mutes it). Reordering is audio-inert and
            // touches no id, so landing it at 0 disturbs no later route.
            "track.reorder": ["trackId": .string(instTrackID), "index": .number(0)],
            // m23-k4a: both export verbs stay IN the loop, on `dryRun: true` —
            // which computes the FULL report (so the route is genuinely
            // exercised, not short-circuited) while writing no file at all. A
            // bare `project.exportMIDI` would land a real `.mid` in the system
            // temp directory, which is the `instrument.importSoundBank`
            // real-FS-side-effect exclusion; the dry run sidesteps it without
            // giving up the coverage. `track.exportMIDI` REFUSES a non-
            // instrument track by design, so it names the instrument track that
            // survives the whole loop (the track.reorder rationale above).
            "project.exportMIDI": ["dryRun": .bool(true)],
            "track.exportMIDI": ["trackId": .string(instTrackID), "dryRun": .bool(true)],
            // Bounce the instrument track (a master input that survives the loop —
            // track.remove targets the audio trackID). Explicit duration so the
            // route succeeds before any clip exists (the render.stems precedent);
            // it mutes the source and inserts an audio track, both harmless to the
            // remaining routes. Full coverage in BounceInPlaceCommandTests.
            "track.bounceInPlace": ["trackId": .string(instTrackID), "durationSeconds": .number(0.1)],
            // fx.add creates an effect on the shared audio track; the effect-id-
            // dependent fx routes (remove/reorder/setBypass/setParam) are excluded
            // below and proven by FXCommandTests. fx.describe needs no params.
            "fx.add": ["trackId": .string(trackID), "kind": .string("gain")],
            "mixer.setMasterVolume": ["volume": .number(1)],
            // Replaces the shared track's chain with a curated preset; not
            // effect-id-dependent, so it routes inline here (clean-boost is the
            // simplest — one gain effect). Full coverage in MixerPresetCommandTests.
            "mixer.applyPreset": ["trackId": .string(trackID), "preset": .string("clean-boost")],
            // Scaffolds a genre skeleton (ADDITIVE — appends tracks/clips to the
            // shared project, never wipes it), so it routes inline here with just
            // a genre. Full coverage in MacroSkeletonCommandTests.
            "macro.songSkeleton": ["genre": .string("pop")],
            // automation.addLane targets "pan" — idempotent against the
            // pre-made removableLaneID, so it succeeds regardless of when it
            // runs relative to automation.removeLane below.
            "mod.addSource": ["trackId": .string(trackID), "kind": .string("lfo")],
            "mod.setSource": ["trackId": .string(trackID), "sourceId": .string(editableSourceID),
                              "params": .object(["rateHz": .number(2)])],
            "mod.removeSource": ["trackId": .string(trackID),
                                 "sourceId": .string(removableSourceID)],
            "mod.addRoute": ["trackId": .string(trackID), "sourceId": .string(routeSourceID),
                             "target": .object(["type": .string("volume")]),
                             "depth": .number(-0.1)],
            "mod.setRouteDepth": ["trackId": .string(trackID),
                                  "routeId": .string(editableRouteID), "depth": .number(0.2)],
            "mod.removeRoute": ["trackId": .string(trackID),
                                "routeId": .string(removableRouteID)],
            "mod.setMacro": ["trackId": .string(trackID), "sourceId": .string(routeSourceID),
                             "value": .number(0.5)],
            "automation.addLane": ["trackId": .string(trackID), "target": .object(["type": .string("pan")])],
            "automation.setPoints": ["trackId": .string(trackID), "laneId": .string(preLaneID),
                                     "points": .array([.object(["beat": .number(0), "value": .number(1)])])],
            "automation.setLaneEnabled": ["trackId": .string(trackID), "laneId": .string(preLaneID),
                                          "enabled": .bool(true)],
            "automation.removeLane": ["trackId": .string(trackID), "laneId": .string(removableLaneID)],
            "clip.addAudio": ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")],
            // Empty notes → a 4-beat MIDI clip on the instrument track.
            "clip.addMIDI": ["trackId": .string(instTrackID)],
            // clip.removeMany/clip.moveMany (m23-w): unlike the other per-clip
            // edits below (which need a REAL clip id only clip.addMIDI can
            // mint, out of order in this shared loop), an empty `ids` array
            // is a LEGAL no-op mirroring ProjectStore.removeClips([])/
            // moveClips([], ...) — no clip needed, no undo entry journaled.
            // Routes inline here rather than joining the skip list below.
            // Full coverage (round-trip, all-or-nothing refusals, the
            // whole-group beat-0 clamp, edit.history depth) is in
            // ClipGroupEditCommandTests.
            "clip.removeMany": ["ids": .array([])],
            "clip.moveMany": ["ids": .array([]), "byBeats": .number(0)],
            // clip.moveManyByTracks/clip.moveManyToTrack (m23-aj-2): appended
            // at the very END of allCommands, by which point track.remove has
            // already deleted the shared audio `trackID` — so toTrackId names
            // `instTrackID` (survives the whole loop, same reasoning as
            // track.reorder above). An empty `ids` is a legal no-op for both
            // (moveManyToTrack still validates toTrackId even so). Full
            // coverage in ClipCrossTrackMoveCommandTests.
            "clip.moveManyByTracks": ["ids": .array([]), "byTracks": .number(0)],
            "clip.moveManyToTrack": ["ids": .array([]), "toTrackId": .string(instTrackID)],
            // Project-wide bar edits (m15-d) — no clip id needed; they run before
            // transport.record in allCommands order, so the transport is not yet
            // recording when their turn comes. bar 1 = beat 0. Full coverage in
            // ArrangeCommandTests / DAWCore ArrangeTests.
            "arrange.insertBars": ["atBar": .number(1), "count": .number(1)],
            "arrange.deleteBars": ["fromBar": .number(1), "count": .number(1)],
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
            "output.listDevices": [:],
            // m20-j. uid omitted = follow the system default, always valid —
            // and on this router's FakeEngine that is a pure state reset, no
            // hardware touched. Both output verbs sit BEFORE transport.record
            // in `allCommands`, which matters: output.setDevice is refused
            // while recording, and this loop is mid-take by the time it
            // reaches the verbs after transport.record.
            "output.setDevice": [:],
            // Sound-bank program listing (m10-n): "gm" is present on every macOS,
            // so it routes with no filesystem setup. instrument.listSoundBanks
            // (no params) also stays IN the loop — a scan never errors.
            // instrument.importSoundBank is excluded above (real-FS copy).
            "instrument.listSoundBankPrograms": ["source": .string("gm")],
            // NT-W (natural tuning §1(e)/§4.e): five of the six new verbs are
            // DRIVEN, not excluded, the clip.setNoteCleared/setNoteGain/
            // setNotePitches/auditionNote precedent immediately above — same
            // setup clip, same stored one-note table. None of the five reads
            // or depends on the note's `cleared`/`amplitudeDb`/
            // `pitchOffsetCents` (each earlier verb in this same loop may
            // already have set those), only on `origin` (still `.detected`)
            // and/or the set existing at all — so allCommands order still
            // does not matter. clip.setNoteTransition is the sixth, excluded
            // above (needs a NEXT note this one-note fixture cannot supply).
            "clip.setNoteFormant": ["clipId": .string(playedPitchClipID),
                                    "segmentIds": .array([.string(playedPitchSegmentID.uuidString)]),
                                    "formantSemitones": .number(0)],
            "clip.setFormantCorrection": ["clipId": .string(playedPitchClipID), "amount": .number(1)],
            "clip.setPitchTransitionSmoothness": ["clipId": .string(playedPitchClipID),
                                                  "centsPerSecond": .number(3000)],
            // amount MUST be 0: this note meets no curve neighbour on either
            // side (a one-note table), so any amount above 0 refuses in
            // words (PitchTransitionSentences.nothingToFollow) — 0 is always
            // allowed, the verb's own documented exception.
            "clip.setNoteGlideFollow": ["clipId": .string(playedPitchClipID),
                                        "noteId": .string(playedPitchSegmentID.uuidString),
                                        "amount": .number(0)],
            // NT-W over NT-C C2: needs only pitchEdits != nil, which the
            // shared seed provides regardless of anything an earlier verb in
            // this loop did to the one note it carries. NT-E2 has since
            // landed — the render mix is live; this call still just routes.
            "clip.setConsonantProtection": ["clipId": .string(playedPitchClipID), "enabled": .bool(true)],
            // C5b-3b: clip.setNoteShape is DRIVEN, not excluded — the same
            // shared one-note table as the five verbs above. Unlike
            // clip.setNoteTransition (excluded, five verbs above: needs a
            // NEXT note this one-note fixture cannot supply), a drawn shape
            // needs nothing from a neighbour, only points inside the note's
            // own [0, 1) span, so allCommands order still does not matter.
            "clip.setNoteShape": ["clipId": .string(playedPitchClipID),
                                  "noteId": .string(playedPitchSegmentID.uuidString),
                                  "points": .array([.object(["seconds": .number(0.2), "cents": .number(10)])])],
            // W7-WIRE2: clip.setNoteShapes is DRIVEN, not excluded — the
            // clip.setNoteShape entry above, wrapped in a single-item
            // `notes` array (the batch verb's own shape). Same shared
            // one-note table, same reasoning: allCommands order does not
            // matter.
            "clip.setNoteShapes": ["clipId": .string(playedPitchClipID),
                                   "notes": .array([.object([
                                       "noteId": .string(playedPitchSegmentID.uuidString),
                                       "points": .array([.object(["seconds": .number(0.2), "cents": .number(10)])]),
                                   ])])],
            // X4: clip.upgradeNaturalTuning is DRIVEN, not excluded — needs
            // only pitchEdits != nil, the same shared one-note table every
            // other natural-tuning verb above already needs. By the time the
            // loop reaches this entry, clip.setFormantCorrection above has
            // already set formantCorrection to a real number, so the table
            // is ALREADY at (or past) the seed values and this call is
            // exercised as its own documented NO-OP path — `response.ok`
            // still requires success, so that path routes too, allCommands
            // order does not matter either way.
            "clip.upgradeNaturalTuning": ["clipId": .string(playedPitchClipID)],
            // m39-tpl-6: template.describe is read-only (changes nothing), so
            // it is DRIVEN here rather than excluded — "lofi-chill" is one of
            // BuiltInTemplateCatalog's own ids, always resolvable regardless
            // of the test environment's template-library root.
            "template.describe": ["template": .string("lofi-chill")],
        ]
        for command in CommandRouter.allCommands {
            // track.remove deletes the shared track; the project.* routes need
            // real filesystem setup (or a stopped transport — this loop is mid-
            // record by now); edit.undo/edit.redo are refused mid-take and need
            // real history; clip.setNotes/clip.remove/clip.split/clip.trim/
            // clip.move/clip.setGain/clip.setGainEnvelope/clip.setFades/clip.deleteTimeRange/
            // clip.insertTimeRange/clip.quantize/clip.humanize/
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
            // project.recover (M9 crash-b) needs a live crash-recovery offer AND an
            // `accept` param — a bare router has no offer, so accept:true
            // legitimately returns noRecoveryAvailable. Proven by
            // RecoveryCommandTests (staged offer). project.recoveryStatus takes no
            // params and never throws (reads {available:false} here), so it stays
            // IN the loop.
            if ["track.remove", "project.save", "project.open", "project.new",
                "project.recover",
                "edit.undo", "edit.redo", "clip.setNotes",
                // clip.getNotes needs a clip id like the other per-clip
                // reads (the clip.analyzeAudio/clip.detectPitch rationale) —
                // this loop's clip.addMIDI clip id is minted mid-loop, not
                // known ahead of time. Proven by ClipGetNotesCommandTests
                // (happy path, round trip, both filters, the totalNotes vs
                // returnedNotes split, the read-only pin, and every
                // rejection).
                "clip.getNotes",
                // clip.repeatNotes (m31-c) needs a REAL MIDI clip id and a
                // note already in it, like the other per-clip edits above —
                // this loop's clip.addMIDI clip id is minted mid-loop, not
                // known ahead of time, and a bare call would just be the
                // ordinary "missing or invalid required param 'clipId'"
                // refusal this loop (which sends no params to an unlisted
                // command) cannot express. Proven by
                // ClipRepeatNotesCommandTests (wire round-trip, every
                // rejection, the no-notes-key response shape).
                "clip.repeatNotes",
                // clip.patchNotes (m26-a/m27-n) needs a REAL MIDI clip id
                // and a real note id already in it, like clip.repeatNotes
                // directly above — this loop's clip.addMIDI clip/note ids
                // are minted mid-loop, not known ahead of time, and a bare
                // call would just be the ordinary "missing or invalid
                // required param 'clipId'" refusal this loop (which sends
                // no params to an unlisted command) cannot express. Proven
                // by ClipPatchNotesCommandTests (wire round-trip, every
                // rejection including the ALL-OR-NOTHING unknown/duplicate
                // id refusals, the counts-only response shape).
                "clip.patchNotes",
                // clip.setNotePitch / clip.splitNote (m23-ap Phase 2, item
                // p2-c) need a REAL AUDIO clip id carrying a STORED pitch
                // note table — deeper than clip.repeatNotes/clip.patchNotes
                // directly above: those need a real MIDI clip+note id, these
                // need a real audio clip that has ALREADY been through a
                // full clip.autoCorrectPitch pass (there is no pitch
                // detection on either of these two wire paths, by design —
                // `ProjectStore+PitchNoteEdits.swift`'s own banner), which
                // this params-free loop cannot supply. A bare call is the
                // ordinary "missing or invalid required param 'segmentId'"
                // refusal this loop cannot express. Proven by
                // PitchCorrectionCommandTests (wire round-trip for both,
                // clamp-and-read-back, the absolute-not-delta idempotency
                // check, the split's minimum-half refusal and set-difference
                // right-id, every clip-kind/no-table/unknown-id rejection).
                "clip.setNotePitch", "clip.splitNote",
                "clip.remove",
                "clip.split", "clip.trim", "clip.move",
                // clip.duplicate (m15-d) needs a clip id like the other per-clip
                // edits; proven by ArrangeCommandTests (round-trip + overlap
                // trimming) and DAWCore ArrangeTests.
                "clip.duplicate", "clip.setGain",
                // clip.setGainEnvelope (m13-e) needs a clip id like the other
                // per-clip edits; proven by DAWCore ClipGainEnvelopeStoreTests +
                // the live wire gate. Audio-only (a MIDI clip is rejected).
                "clip.setGainEnvelope",
                // clip.setControllerLane / clip.removeControllerLane (m16-b2) need
                // a MIDI clip id like the other per-clip edits; proven by
                // ControllerLaneCommandTests (round-trip + teaching errors) and
                // DAWCore ControllerLaneStoreTests.
                "clip.setControllerLane", "clip.removeControllerLane",
                // clip.applyBreathContour (m27 leg D) needs a MIDI clip id for
                // the same reason as the two directly above — it is the
                // authoring primitive over that pair, and a bare call is the
                // ordinary "missing or invalid required param 'clipId'"
                // refusal this loop cannot express (it sends no params).
                // Proven by ControllerLaneCommandTests (every-parameter
                // round-trip through a real router call, plus the teaching
                // errors) and DAWCore ControllerLaneStoreTests / DAWEngine
                // SamplerTests' offline-render gate.
                "clip.applyBreathContour",
                // clip.applyEffortShape (breath pad P1) is the composing verb
                // over clip.applyBreathContour and needs the same MIDI clip id
                // — a bare call is the ordinary "missing or invalid required
                // param 'clipId'" refusal this loop, which sends no params,
                // cannot express.
                // ⚠️ P2 (the ring) RETIRED THE SECOND REASON THIS COMMENT USED
                // TO GIVE: `pattern` is NO LONGER required — it is now one of
                // TWO accepted gesture forms (`pattern`, or `ringAngle`
                // [+ optional `ringRadius`/`ring`]), and supplying NEITHER is
                // refused app-side with an error naming both. `clipId` alone
                // still keeps this verb out of the loop, so the exclusion is
                // unchanged in effect — but the rationale is not, and a stale
                // reason is how an exclusion silently goes vacuous.
                // Proven by ControllerLaneCommandTests (round-trip,
                // every-new-parameter reachability, case-insensitive pattern
                // resolution, the unknown-pattern refusal that lists the valid
                // ids, the pattern-owned-key rejections, and P2's ring
                // round-trip / both-forms / orphan-decoration / neither-form
                // fork with positive controls) and DAWCore
                // ControllerLaneStoreTests / EffortPatternTests /
                // EffortRingTests.
                "clip.applyEffortShape",
                "clip.setFades",
                // clip.fitToContent (m21-d) needs a clip id like the other
                // per-clip edits; proven by ClipFitToContentCommandTests
                // (round-trips + changed flag + error taxonomy) and DAWCore
                // FitClipToContentTests.
                "clip.fitToContent",
                // clip.analyzeAudio (m21-e) needs a clip id like the other
                // per-clip reads; the shared fixture's 2 s @ 120 clip clears
                // the >= 1 s window floor but this bare FakeEngine doesn't
                // override analyzeAudioContent, so it would legitimately hit
                // the AudioEngineControlling default's engineUnavailable
                // throw here. Proven by ClipAnalyzeAudioCommandTests (happy
                // path shape, MIDI rejection, unknown clip/key, and the
                // engine-default-throw path) and DAWCore
                // AudioContentAnalyzerTests.
                "clip.analyzeAudio",
                // clip.detectPitch (m23-ap-3) needs a clip id like the other
                // per-clip reads AND a REAL file on disk (detectClipPitch
                // checks FileManager.fileExists before calling the engine) —
                // this bare router's shared clip points at a path nothing
                // wrote, so it would hit the missing-file invalidClipEdit
                // even with an engine override. Proven by
                // ClipDetectPitchCommandTests (happy path shape, honest
                // absence, window clamping, MIDI/missing-file/unknown-clip
                // rejections, and the engine-default-throw path) and
                // DAWEngineTests ClipPitchAnalyzerTests (real SwiftF0
                // inference).
                "clip.detectPitch",
                // clip.autoCorrectPitch (m23-q Phase 2) needs the SAME real
                // clip id + real backing file as clip.detectPitch above (it
                // calls detectClipPitch internally) — this loop's clip id is
                // minted mid-loop and points at no real file. Proven by
                // PitchCorrectionCommandTests (happy path, presets, scale,
                // range validation, MIDI/comp-member/unknown-clip
                // rejections, the hardTune warning) and DAWCore
                // PitchCorrectionWriterTests.
                "clip.autoCorrectPitch",
                // clip.clearPitchEdits / clip.getPitchEdits (m23-q Phase 2)
                // need a clip id like the other per-clip reads above — this
                // loop's clip id is minted mid-loop, not known ahead of time.
                // Both are no-ops/reads on a clip with no edits, so excluding
                // them costs nothing but route coverage, which
                // PitchCorrectionCommandTests supplies directly.
                "clip.clearPitchEdits", "clip.getPitchEdits",
                // clip.crossfade (m11-d) needs TWO adjacent audio clips with source
                // material on each side of the seam — a fixture this shared, single-
                // clip project doesn't have. Proven by ClipCrossfadeCommandTests
                // (import + split + crossfade) and DAWCore ClipCrossfadeTests.
                "clip.crossfade",
                "clip.setStretch", "clip.stretchToLength",
                "clip.deleteTimeRange", "clip.insertTimeRange", "clip.quantize",
                "clip.humanize", "clip.detectTransients", "clip.quantizeAudio",
                // clip.sliceToSampler (m32-b2) is clip-id-dependent like its
                // detectTransients/quantizeAudio siblings above, AND needs a
                // real engine implementing the m32-b2 slice-boundary seam
                // (whose protocol default deliberately THROWS rather than
                // fabricating a geometry). Proven by
                // SliceToSamplerCommandTests (all three modes, the whole
                // rejection ladder, undo granularity, snap reporting, and a
                // save/open/zonePatches round trip), DAWCore
                // SliceToSamplerPlanTests/SliceToSamplerRateTests, and
                // DAWEngine BoundarySnapperTests/
                // SliceToSamplerReconstructionTests.
                "clip.sliceToSampler",
                "fx.remove", "fx.reorder", "fx.setBypass", "fx.setParam",
                // fx.setSidechain (m12-g) is effect-id-dependent AND needs a
                // compressor/gate keyed from a valid source track — the shared
                // single gain effect can't be keyed. Proven by
                // SidechainCommandTests (kick→pad + all four teaching errors).
                "fx.setSidechain",
                // fx.spectrum (m23-r4) is effect-id-dependent exactly like the
                // fx.remove/reorder/setBypass/setParam group above — the
                // exact rationale. Proven by FXSpectrumCommandTests (all
                // twelve gate legs) plus InsertSpectrumCoverageTests/
                // EQCurveEditorModelTests for the tapPoint label agreement.
                "fx.spectrum",
                "take.group", "take.setComp", "take.select", "take.removeLane",
                "take.flatten", "take.move", "take.setCrossfade", "take.autoAlign",
                "groove.extract", "groove.remove",
                // instrument.importSoundBank (m10-n) copies a real file into the
                // central library (~/Library/Application Support/DAWPro/SoundBanks)
                // — excluded here to avoid that real-FS side effect; proven by
                // SoundBankCommandTests with injected temp dirs.
                "instrument.importSoundBank",
                // instrument.importSampleLibrary (m19-c) reads a REAL .sfz +
                // sample files off disk — a fixture this bare loop doesn't
                // stage. Proven end-to-end (happy path, dryRun, every error
                // shape, undo, offline-render gate) by SampleLibraryCommandTests
                // with temp-dir fixtures.
                "instrument.importSampleLibrary",
                // instrument.describeSampler (m26-i) needs a track whose
                // sampler is ACTUALLY configured (`instrument?.sampler !=
                // nil`) — this loop's own `track.setInstrument` entry for
                // `instTrackID` only sets `waveform` (a polySynth knob) and
                // never touches `sampler`, so a bare call here would
                // legitimately hit the "no sampler configured yet" refusal,
                // the au.describeParams "no live hosted instance" rationale.
                // Proven end-to-end (globals, provenance, zone-summary
                // coverage/gaps, paging, every refusal) by
                // InstrumentDescribeSamplerCommandTests.
                "instrument.describeSampler",
                // instrument.probeLiveness (m31-f) RENDERS a velocity
                // ladder offline: it needs a real track carrying a real
                // instrument AND a live engine to render through, neither
                // of which this bare loop stages — the
                // instrument.describeSampler rationale directly above,
                // verbatim. ⚠️ It is a READ-ONLY probe (lands no clip,
                // pushes no undo step) but "read-only" is not the
                // exclusion here; needing a rendered fixture is.
                // TWO suites cover this verb, one per layer: the
                // store/measurement layer — STATIC/LIVE/SILENT/INCONCLUSIVE
                // verdicts, the self-check gate, the no-edit guarantee — is
                // proven by TimbreLivenessProbeTests (DAWCoreTests, calling
                // store.probeInstrumentLiveness directly; it never crosses
                // the control layer). THIS verb's own wire contract — param
                // decoding/defaulting, the control layer's OWN velocities
                // validation, refusal wording, the JSON field shape, and
                // that a failed self-check surfaces as a control-layer
                // ERROR rather than a STATIC verdict — is proven by
                // InstrumentProbeLivenessCommandTests, this target.
                "instrument.probeLiveness",
                // m23-k3: both MIDI-import verbs read a REAL .mid off disk — a
                // fixture this bare loop doesn't stage — and clip.importMIDI
                // additionally needs an existing MIDI clip. The
                // instrument.importSampleLibrary rationale exactly. Both are
                // proven end-to-end (happy path, dryRun, parts/instruments,
                // every §4.3 error row, unknown keys) by
                // MIDIFileImportCommandTests with temp-file fixtures.
                "project.importMIDI", "clip.importMIDI",
                "ai.sidecarStart", "ai.sidecarStop",
                // vc.sidecarStart/Stop (m10-p-3): the EXACT ai.sidecarStart/Stop
                // rationale above, for the RVC voice-conversion sidecar — the
                // default (real) VoiceConversionManager would spawn/signal a
                // REAL process here (and DID, on machines with scripts/rvc
                // installed, until this orchestrator-audit exclusion caught up
                // with the m10-p-3 landing; on a fresh checkout start throws
                // notInstalled and would fail this loop). vc.sidecarStatus is
                // side-effect-free and stays IN the loop, like ai.sidecarStatus.
                // Proven by VoiceConversionCommandTests (fake VoiceConversionManaging).
                "vc.sidecarStart", "vc.sidecarStop",
                "ai.generateSong", "ai.generationStatus",
                // ai.importGeneration (M6 iii-a) needs a succeeded jobId from a
                // REAL generation — proven by SongGenerationCommandTests /
                // GenerationImportTests, excluded here like the other ai.* routes.
                "ai.importGeneration",
                // ai.extractStems/ai.legoGenerate (M6 iii-c) likewise hit a REAL
                // ACEStepClient; ai.importGeneratedStems needs a succeeded
                // composite jobId from a real generation. All three proven by
                // dedicated tests (SongGenerationCommandTests / GenerationImportTests).
                "ai.extractStems", "ai.legoGenerate", "ai.importGeneratedStems",
                // ai.repaintAudio (M6 v-a) likewise hits a REAL ACEStepClient
                // (and requires an existing sourcePath file besides). Proven
                // by RepaintCommandTests (FakeSongGenerator) and
                // AIServicesTests/ACEStepRepaintClientTests (stub HTTP server).
                "ai.repaintAudio",
                // ai.fixClipRegion (M6 v-b) needs an offline-render engine AND
                // a generation source (neither wired on this bare router) plus a
                // real audio clip; ai.importClipFix needs a pending jobId from a
                // real submit. Both proven by ClipFixCommandTests / ClipFixTests
                // (fakes), excluded here like the other ai.* routes.
                "ai.fixClipRegion", "ai.importClipFix",
                // ai.writeLyrics resolves a REAL provider client from the key
                // chain (this router's default KeychainKeyStore + process env);
                // with no key present it legitimately returns the actionable
                // no-provider error, so it's excluded here. Its routing, param
                // validation, project-context defaulting, and no-key path are
                // proven by WriteLyricsCommandTests (fake writer) and its wire
                // shape by AIServicesTests/LyricsWriterTests (stub HTTP server).
                "ai.writeLyrics",
                // ai.copilot* (M6 rail-c; M10-p-6 added GetModel/SetModel; the
                // chat-persist design Phase C added Chats/ResumeChat/
                // DeleteChat/RenameChat) route through CommandRouter.copilotEngine,
                // which is nil on this bare router (only DAWProApp wires it) —
                // all nine legitimately return the actionable "not wired" error
                // here. Proven by CopilotCommandTests (a router with a real
                // CopilotEngine + FakeCopilotProvider), CopilotChatCommandTests
                // (the four new chat verbs), and CopilotEngineTests (the turn
                // loop itself).
                "ai.copilotSend", "ai.copilotState", "ai.copilotReset",
                "ai.copilotGetModel", "ai.copilotSetModel",
                "ai.copilotChats", "ai.copilotResumeChat",
                "ai.copilotDeleteChat", "ai.copilotRenameChat",
                // plugin.openUI / plugin.closeUI (M3 vi-b) route through
                // CommandRouter.pluginUI, the app-layer window seam, which is nil
                // on this bare router (only DAWProApp wires it) — both legitimately
                // return the actionable headless error here. Proven by
                // PluginUICommandTests (router + a fake PluginUIControlling).
                // plugin.listOpenUIs is NOT excluded: it answers ok with
                // {available:false} when the seam is nil.
                "plugin.openUI", "plugin.closeUI",
                // edit.pasteClips (m26-k) routes through CommandRouter.editPaste,
                // the same app-layer-seam-nil-on-a-bare-router rationale as
                // plugin.openUI/closeUI above — it legitimately returns the
                // actionable headless error here. Proven by
                // EditPasteClipsCommandTests (router + a fake EditPasteControlling).
                "edit.pasteClips",
                // au.describeParams / au.setParam (hosted-AU parameter
                // surface) need a LIVE `.ready` hosted Audio Unit behind the
                // target — this bare router's FakeEngine hosts none (the
                // protocol defaults answer "no hosted instance"), so both
                // legitimately return the actionable status-naming error
                // here. Proven by AUParamCommandTests (full wire taxonomy +
                // shapes over a parameter-surface fake) and DAWEngine's
                // AUParameterSurfaceTests (real AUDelay/DLSMusicDevice trees,
                // audible-truth render).
                "au.describeParams", "au.setParam",
                // m23-cw: au.listPresets / au.loadPreset (hosted-AU PRESET
                // surface) are excluded for exactly the reason above and one
                // more. Both need a LIVE `.ready` hosted Audio Unit behind the
                // target, which this bare router's FakeEngine has none of; and
                // this loop passes NO params, so both refuse on the required
                // `trackId` before they ever reach the engine. ⛔ Do NOT "fix"
                // this by inventing a trackId in paramsByCommand: a made-up id
                // would refuse with "No track with id …" instead, which is a
                // DIFFERENT verb working and would silently stop testing what
                // this entry claims to test. Proven by AUPresetCommandTests
                // (full wire taxonomy + shapes over a preset-surface fake) and
                // DAWEngine's AUPresetSurfaceTests (real AUMatrixReverb /
                // AUDelay preset lists, a load that moves the rendered reverb
                // tail, and the save/restore state round trip).
                "au.listPresets", "au.loadPreset",
                // vc.convertVocals/vc.trainVoice (m10-p-4) hit a REAL
                // VoiceConversionClient talking to a REAL (almost certainly
                // not-running-in-CI, and stopped again by the vc.sidecarStop
                // call earlier in THIS SAME loop) sidecar — the ai.generateSong/
                // ai.repaintAudio precedent. Neither also has a fixture this
                // shared, single-clip project can supply (a required voiceId,
                // and EXACTLY ONE of clipId/path or name/datasetDir), so both
                // are excluded here exactly like their ai.* siblings. Proven by
                // dedicated tests: DAWCoreTests/VoiceConversionImportTests
                // (store import/undo/rejections), DAWControlTests/
                // VoiceConversionConvertCommandTests (routing/param-shape/
                // error-surfacing via a fake VoiceConverting), and
                // AIServicesTests/VoiceConversionClientTests (convert/train
                // against a stub facade).
                "vc.convertVocals", "vc.trainVoice",
                // vc.convertClips (m24-m leg A) is the SET form of
                // vc.convertVocals and is excluded for the same three reasons
                // verbatim: a REAL VoiceConversionClient against a REAL
                // (not-running) sidecar, a required voiceId this loop cannot
                // supply, and a required non-empty clipIds. It additionally
                // needs a live ENGINE — the m24-o extraction renders the
                // clip's own window before converting — which this bare
                // router does not have. Proven by dedicated tests:
                // DAWCoreTests/ClipVoiceConversionTests (the store contract:
                // arrangement preservation, one undoable edit, all-or-nothing,
                // every refusal), DAWControlTests/VoiceConvertClipsCommandTests
                // (routing/param-shape/response-encoding via a fake
                // VoiceConverting and a fake render engine), and
                // DAWEngineTests/ClipVoiceConversionRenderTests (the audio
                // itself, sample-exact, through a REAL AudioEngine).
                "vc.convertClips",
                // vc.listVoices (m10-p-5) likewise hits the REAL
                // VoiceConversionClient talking to a REAL (almost certainly
                // not-running-in-CI, and stopped again by the vc.sidecarStop
                // call earlier in THIS SAME loop) sidecar — the
                // vc.convertVocals/vc.trainVoice rationale above verbatim
                // (vc.sidecarStatus, side-effect-free AND never erroring,
                // stays IN the loop). Proven by dedicated tests:
                // DAWControlTests/VoiceListCommandTests (routing/no-params/
                // verbatim-descriptors/error-surfacing via a fake
                // VoiceConverting) and AIServicesTests/
                // VoiceConversionClientTests (listVoices against a stub
                // facade).
                "vc.listVoices",
                // reference.import (m22-g) copies a real file into the central
                // References home (~/Library/Application Support/DAWPro/
                // References) — the instrument.importSoundBank real-FS-side-
                // effect exclusion, verbatim. reference.remove/reference.analyze
                // need a slot that only exists after an import this loop
                // deliberately doesn't run (and analyze additionally needs the
                // analyzeReferenceFile capability this bare FakeEngine doesn't
                // override — the clip.analyzeAudio rationale). All three proven
                // by ReferenceCommandTests with injected temp dirs + a
                // reference-capable fake. reference.status is read-only, never
                // throws, and stays IN the loop.
                "reference.import", "reference.remove",
                "reference.analyze",
                // audio.profileFile (m25-z) needs BOTH a real file on disk
                // (this bare loop stages no fixture, the vc.importVoiceModel/
                // clip.transcribe rationale) AND the profileFile capability
                // this bare FakeEngine doesn't override — the
                // reference.analyze/clip.analyzeAudio rationale. Proven by
                // AudioProfileFileCommandTests with an injected temp file + a
                // profiling-capable fake, and by FileProfilerTests (real DSP,
                // no fake) at the DAWEngine layer.
                "audio.profileFile",
                // reference.setOffset/setTrim/compare (m22-g P2) need a slot
                // that only exists after the import this loop deliberately
                // doesn't run (compare additionally needs a live loudness
                // meter this bare FakeEngine doesn't provide — the
                // mixer.liveLoudness rationale). All three proven by
                // ReferenceMonitorCommandTests with injected temp dirs + a
                // monitor-capable fake. reference.setMonitor stays IN the
                // loop with {on:false} — the idempotent never-refusing OFF.
                "reference.setOffset", "reference.setTrim",
                "reference.compare",
                // m23-d: note.audition is DELIBERATELY refused while a take is
                // rolling (design §9 — anything heard during a take is
                // reasonably assumed to be in it), and this loop leaves
                // transport.record's take rolling by the time the tail is
                // reached. Its route (happy path, every clamp, the
                // refuse-while-recording guard itself) is proven by
                // AuditionCommandTests against a stopped transport — the
                // reference.import rationale.
                "note.audition",
                // pad.previewEffort (breath pad P6) is note.audition's neighbour
                // in allCommands and excluded for note.audition's reason PLUS
                // one of its own. BOTH are written down because either alone
                // invites the wrong repair:
                //  1. `begin`/`move` are refused mid-take (same design §9 rule —
                //     anything heard during a take is assumed to be in it), and
                //     this loop leaves transport.record's take rolling.
                //  2. ⛔ Do NOT "fix" this by feeding it {gesture:"end"}. `end`
                //     is allowed mid-take on purpose, but with no gesture open
                //     it throws by design ("'end' has nothing to release"), so
                //     it would fail here too — and if it ever stopped throwing,
                //     the loop would be exercising the degenerate no-op branch
                //     while looking like route coverage. A green vacuous check
                //     is worse than an honest exclusion.
                // The route (all three phases, both identity guards, the rate
                // cap, the release-to-neutral law) is proven against a stopped
                // transport by PadPreviewCommandTests — the note.audition
                // rationale verbatim.
                "pad.previewEffort",
                // pad.playEffort (m34-f step ②) shares that verb's handler case
                // and is excluded for HALF of its reasons — the half that still
                // applies, and the difference matters enough to write out.
                //  1. ⛔ NOT for the refuse-while-recording reason. This verb is
                //     DELIBERATELY not refused mid-take; that single difference
                //     is the entire feature, and pinning it is
                //     `PadPreviewCommandTests.theTwoVerbsDifferExactlyHere`,
                //     which drives BOTH verbs against one rolling take and
                //     asserts the preview is refused where this one succeeds.
                //  2. It is excluded because a params-free `begin` has no
                //     `trackId`, and this loop supplies none. Feeding it
                //     {gesture:"end"} is the SAME trap `pad.previewEffort`
                //     documents above: with no gesture open it throws by design,
                //     and if it ever stopped throwing the loop would be
                //     exercising a degenerate no-op while looking like coverage.
                "pad.playEffort",
                // clip.transcribe (m23-n2b) hits a REAL WhisperTranscriber —
                // this bare router doesn't inject a fake (there is no
                // WhisperTranscriber protocol to fake; the actor IS the
                // engine, the vc.convertVocals precedent for "real client,
                // no fake seam"). Even with weights installed it would still
                // fail: the shared clip's `/tmp/Loop.wav` is a `FakeMedia`-
                // backed fake path with no decodable audio on disk — the
                // instrument.importSampleLibrary "a fixture this bare loop
                // doesn't stage" rationale. Proven by dedicated tests:
                // DAWCoreTests/ClipTranscriptionSourceTests (the clip -> request
                // mapping + stretch-refusal, no model touched),
                // DAWControlTests/ClipTranscribeCommandTests (wire shape +
                // rejections, no model touched), and
                // DAWControlTests/ClipTranscribeRealFixtureTests (a REAL
                // `say`-generated clip transcribed end to end through the
                // control wire, words on the right beats).
                "clip.transcribe",
                // ai.installSpeechModel (m23-n3b) hits the REAL
                // WhisperModelInstallCoordinator's default (real)
                // WhisperModelInstaller, which stages into the REAL
                // `~/Library/Application Support/DAWPro/Models` — exactly the
                // real-FS side effect instrument.importSoundBank/
                // reference.import are excluded for, PLUS it would spawn a
                // background Task that reaches for the network (blocked in
                // this sandbox, per WhisperModelInstaller's own doc — a real
                // attempt dies at NSURLErrorDomain -1001 after ~60s). Proven
                // by SpeechModelInstallCommandTests with an injected
                // WhisperModelInstallCoordinator (fake InstallFunction, no
                // network, no real Application Support writes).
                // ai.speechModelInstallStatus is read-only against the SAME
                // (never-started, on this bare router) coordinator — answers
                // {state:"idle"} with zero filesystem access — so it stays IN
                // the loop, like ai.sidecarStatus/vc.sidecarStatus.
                "ai.installSpeechModel",
                // ai.modelUnload (m23-dl) takes exactly one of {modelId} or
                // {all}; a bare call is a TEACHING ERROR naming the valid ids,
                // which is the behaviour this loop cannot express (it sends no
                // params). Excluded rather than fed `{all: true}`, because
                // `{all: true}` on the process-wide coordinator would try to
                // stop the user's real sidecars from a unit test. Proven by
                // ModelLifecycleCommandTests, which drives both the one-model
                // and the all form against an injected hermetic coordinator.
                // ⚠️ `ai.modelResidency` is read-only, never throws, touches no
                // filesystem on an unregistered coordinator, and stays IN the
                // loop — the ai.sidecarStatus rationale.
                "ai.modelUnload",
                // vc.importVoiceModel (m23-di-2a) copies a real file into the
                // app-owned voice store (~/Library/Application Support/DAWPro/
                // VoiceModels on this bare router's default
                // voiceModelImportDirectory) — the instrument.importSoundBank/
                // reference.import real-FS-side-effect exclusion, verbatim.
                // It also needs a real modelPath file on disk, a fixture this
                // bare loop doesn't stage. Proven with injected temp dirs by
                // VoiceModelImportCommandTests and AIServicesTests/
                // VoiceModelImportTests.
                "vc.importVoiceModel",
                // vc.installEmbeddedVoice (m24-n) is the SAME exclusion class,
                // twice over: it REQUIRES a `voiceId` this params-free loop
                // cannot supply, and on success it copies a real voice model
                // into the app-owned voice store. It also needs a SAVED project
                // bundle that actually carries an embedded voice — a fixture
                // this bare loop does not stage. Proven end-to-end, with an
                // injected temp voice store and a real save/reopen round trip,
                // by EmbeddedVoiceCommandTests and DAWCoreTests/
                // VoiceProvenanceEmbeddingTests.
                // ⚠️ Its READ sibling `project.embeddedVoices` stays IN the
                // loop: it takes no params, writes nothing, and answers
                // honestly on an empty project.
                "vc.installEmbeddedVoice",
                // m34-h LIVE LOOPING: transport.recordLayer / transport.finishLayer
                // are excluded for OPPOSITE halves of the same state, and both
                // reasons are written down because either alone invites the
                // wrong repair.
                //  1. This loop is mid-take from transport.record onwards, so
                //     transport.recordLayer legitimately refuses — a layer needs
                //     a transport that is playing and NOT already capturing
                //     ("already recording a layer — finish it with
                //     transport.finishLayer first"). That refusal is the verb
                //     working, not failing.
                //  2. ⛔ Do NOT "fix" this by reordering them BEFORE
                //     transport.record. The transport is STOPPED there, and
                //     recordLayer refuses a stopped transport just as firmly
                //     (that is the whole point — it is the mirror image of
                //     transport.record, not a relaxation of it). Neither
                //     position can satisfy both verbs.
                //  3. transport.finishLayer runs against this bare router's
                //     FakeEngine, which does not implement the keep-playing
                //     close, so it answers the AudioEngineControlling default —
                //     "closed nothing" — which the store deliberately turns into
                //     a throw rather than a silent success (a false success
                //     there is a LOST TAKE; see finishLayer's own doc). Feeding
                //     it a real take would still not help: only the real
                //     AudioEngine can close one without stopping.
                // Proven instead by TransportLayerCommandTests (the full wire
                // taxonomy over a spy engine that DOES implement the close) and
                // DAWEngineTests/LiveLayerCaptureTests (the real engine, both
                // layers, playhead advancing across the close).
                "transport.recordLayer", "transport.finishLayer",
                // m34-h-1 LIVE LOOPING, the loop deck. Excluded for reasons
                // that COMPOSE with the two above rather than repeating them,
                // and each one is a verb WORKING:
                //  1. looper.begin refuses outright here — this loop is
                //     mid-take from transport.record onwards, and a deck
                //     session cannot open over a rolling take.
                //  2. looper.armLayer / looper.setLayerMuted need a `trackId` /
                //     `layerId` this params-free loop cannot supply, and a
                //     layer id only exists after a landed pass.
                //  3. looper.finishLayer / looper.undoLayer / looper.end
                //     legitimately refuse with no session open, which is what
                //     they are for. ⛔ Do NOT "fix" this by opening a session
                //     in the loop's fixture: the deck's landing path depends on
                //     the keep-playing close, which this bare router's
                //     FakeEngine does not implement (see point 3 above).
                // ⚠️ looper.status is NOT excluded — it takes no params, writes
                // nothing, and answers null honestly when no deck is open,
                // which is exactly the shape this loop is good at.
                "looper.begin", "looper.armLayer", "looper.finishLayer",
                "looper.undoLayer", "looper.setLayerMuted", "looper.end",
                // m34-c: excluded for two DIFFERENT reasons, both written down
                // because either alone invites the wrong repair.
                //  1. instrument.downloadSoundBank REQUIRES an `id` this
                //     params-free loop cannot supply — and supplying one would
                //     be worse: it would start a REAL 216 MB NETWORK TRANSFER
                //     from every run of the suite. ⛔ Do NOT "fix" this by
                //     adding it to paramsByCommand.
                //  2. instrument.cancelSoundBankDownload legitimately REFUSES
                //     when nothing is running ("there is nothing to cancel"),
                //     which is the verb working, not failing — a no-op success
                //     would let a caller believe it cancelled something. The
                //     loop has nothing in flight by construction.
                // Both are proven end to end, against an injected fake install
                // function with no network, by SoundBankDownloadCommandTests.
                "instrument.downloadSoundBank",
                "instrument.cancelSoundBankDownload",
                // NT-W (natural tuning §4.e): clip.setNoteTransition is
                // excluded, not driven — the shared `playedPitchSegmentID`
                // fixture five verbs above is a ONE-note table, and this
                // verb's own rule (`PitchEditSet.applyingNoteTransition`,
                // `PitchTransitionSentences.lastNoteHasNoSlide`) is that the
                // LAST sung note has no next note to slide into. Extending
                // the shared fixture to two notes would be the wrong fix:
                // clip.getPlayedPitch/setNoteCleared/setNoteGain/
                // setNotePitches/auditionNote all drive against it and may
                // assume a single note. So the refusal here IS the verb
                // working, the instrument.cancelSoundBankDownload precedent
                // immediately above. Proven on a real three-note fixture
                // (soft/gap/last joins) by PitchCorrectionCommandTests'
                // setNoteTransition* tests.
                "clip.setNoteTransition",
                // UB-2: clip.findUnpitchedSounds is excluded, not driven —
                // unlike clip.setNoteVibrato/setNoteVibratos above (same
                // per-note door, same shared fixture), this verb calls
                // `detectClipPitch` (`ProjectStore+PitchCorrection.swift`) to
                // measure the clip's OWN noise floor from real audio frames.
                // The shared fixture's clip was added over
                // `/tmp/PlayedPitchFixture.wav`, a path that does not exist
                // on disk (confirmed: `ls` finds nothing there) — every OTHER
                // verb driven against it only ever reads the STORED note
                // table, never audio content, so the missing file never
                // matters until this one tries to decode it. This router
                // also carries no `FakePitchDetectionEngine` (unlike
                // PitchCorrectionCommandTests's `makeRouter`), so there is no
                // safe stub to detect through either. Proven end to end,
                // against a real (if minimal) audio file and a
                // FakePitchDetectionEngine stub, by
                // PitchCorrectionCommandTests' findUnpitchedSounds* tests.
                "clip.findUnpitchedSounds",
                // M35 — the five `view.*` verbs (the fifth, `view.openPitchEditor`,
                // landed at the m23-ap Phase 2 p2-c pitch-editor command-surface
                // door). Excluded because THIS ROUTER IS HEADLESS BY CONSTRUCTION
                // (no `viewUI` seam installed) and the design's contract is that
                // all five then fail LOUDLY rather than returning a success that
                // means nothing: a `view.capture` that answered `ok` here would
                // be reporting a screenshot of an app that does not exist. So the
                // refusal IS the verb working.
                // ⛔ Do NOT "fix" this by installing a fake seam in this
                // fixture: the loud-refusal contract is the thing most worth
                // protecting, and a fake here would make it untestable in the
                // one place it is asserted.
                // ⚠️ Three of the five would fail for a SECOND, unrelated reason
                // as well — `view.selectClip` and `view.openPitchEditor` need a
                // `clipId` and `view.openEditor` a `trackId`, which this
                // params-free loop cannot supply — and that is recorded so a
                // future reader does not "repair" the wrong half.
                // `view.openPitchEditor` has a THIRD reason on top of those two:
                // its clip lookup and MIDI-clip refusal are ROUTER-SIDE
                // (`Commands.swift`'s own comment on the case), so even a
                // well-formed `clipId` this loop does not have would still need
                // to name a real, existing, non-MIDI clip. All five are proven,
                // headless refusal included, by ViewSurfaceCommandTests.
                "view.capture", "view.selectClip",
                "view.panelLayout", "view.openEditor", "view.openPitchEditor",
                // m39-tpl-6: the five MUTATING template verbs — each one
                // either writes a file (save/import/export), deletes one
                // (remove), or edits the shared fixture's song (apply, one
                // undo step per call). Giving any of them a params table
                // entry here would mean every OTHER command below it in this
                // single params-free loop runs against a project this verb
                // just changed — exactly the shared-fixture risk this test's
                // own comments elsewhere in this file warn against. Proven
                // instead, each with its own isolated router, in
                // TemplateWireCommandTests.swift. template.list and
                // template.describe are read-only and stay DRIVEN above.
                "template.apply", "template.save", "template.remove",
                "template.import", "template.export"].contains(command) {
                continue
            }
            let response = await router.handle(ControlRequest(
                id: command, command: command, params: paramsByCommand[command]
            ))
            #expect(response.ok, "command \(command) failed: \(response.error ?? "?")")
        }
    }

    // MARK: - W7-WNM: the wire number-magnitude ceiling, end to end through
    // the router (walker-level coverage lives in the NEW, nonisolated
    // WireNumberCeilingTests.swift — no new @MainActor suite is added here).

    @Test("W7-WNM: at least one command per family refuses a wire number of 2^53 or more at its known, previously-unguarded Int(_:) site, naming the exact path — both the trap value (1e20) and the plant's value (1e17) are refused, and the process surviving to report it IS the proof (either value would have trapped the whole test binary before this pre-pass existed)")
    func wireNumberCeilingRefusesKnownTrapSitesAcrossCommandFamilies() async {
        let (router, _) = makeRouter()
        let cases: [(command: String, path: String, build: (Double) -> [String: JSONValue])] = [
            ("track.reorder", "params.index",
             { ["index": .number($0)] }),
            ("fx.add", "params.index",
             { ["index": .number($0)] }),
            ("clip.repeatNotes", "params.count",
             { ["count": .number($0)] }),
            ("clip.repeatNotes", "params.transposeSemitones[0]",
             { ["transposeSemitones": .array([.number($0)])] }),
            ("ai.generateSong", "params.seed",
             { ["seed": .number($0)] }),
            ("vc.convertVocals", "params.pitchSemitones",
             { ["pitchSemitones": .number($0)] }),
            ("tempo.setMap", "params.meterChanges[0].beatsPerBar",
             { ["meterChanges": .array([.object(["beatsPerBar": .number($0)])])] }),
            ("project.exportMIDI", "params.format",
             { ["format": .number($0)] }),
            ("track.setInstrument", "params.drumKit.kick.chokeGroup",
             { ["drumKit": .object(["kick": .object(["chokeGroup": .number($0)])])] }),
            ("track.setInstrument", "params.soundBank.program",
             { ["soundBank": .object(["program": .number($0)])] }),
            ("clip.setControllerLane", "params.points[0].value",
             { ["points": .array([.object(["value": .number($0)])])] }),
        ]
        for value: Double in [1e20, 1e17] {
            for row in cases {
                let response = await router.handle(ControlRequest(
                    id: "t", command: row.command, params: row.build(value)))
                #expect(!response.ok, "\(row.command) at \(value) must be refused")
                #expect(response.error == "\(row.path) is too large: "
                    + "wire numbers must be below 9007199254740992",
                        "\(row.command) at \(value): \(response.error ?? "no error")")
            }
        }
    }

    @Test("W7-WNM: 2^53 - 1 passes the pre-pass and reaches the command's own validation next — a positive control that this is not refusing everything")
    func wireNumberCeilingPositiveControlJustUnderTheCeiling() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "p", command: "track.reorder", params: ["index": .number(9_007_199_254_740_991)]))
        #expect(!response.ok)
        #expect(response.error?.contains("too large") != true, "\(response.error ?? "no error")")
        // track.reorder's OWN next check is the missing 'trackId' — proving
        // the value was let through, not swallowed by this pre-pass.
        #expect(response.error == "missing or invalid required param 'trackId'",
                "\(response.error ?? "no error")")
    }

    @Test("W7-WNM: a negative magnitude past the ceiling is refused the same as a positive one")
    func wireNumberCeilingRefusesNegativeMagnitude() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "n", command: "clip.repeatNotes", params: ["count": .number(-1e20)]))
        #expect(response.error == "params.count is too large: wire numbers must be below 9007199254740992",
                "\(response.error ?? "no error")")
    }

    @Test("W7-WNM: the exemption is real end to end too — clip.quantizeAudio's absurd 'divisions' reaches ITS OWN words, not this pre-pass's")
    func wireNumberCeilingExemptionEndToEnd() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "e", command: "clip.quantizeAudio",
            params: ["trackId": .string(UUID().uuidString), "clipId": .string(UUID().uuidString),
                     "divisions": .number(1e20), "strength": .number(0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("'divisions' must be a whole number between") == true,
                "\(response.error ?? "no error")")
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
