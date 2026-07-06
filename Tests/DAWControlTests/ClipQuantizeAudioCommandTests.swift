import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M5 (iii-f) `clip.quantizeAudio`: the async
/// detect → slice → nudge path, param-surface validation, and the store
/// rejections surfaced verbatim. Reuses `FakeTransientEngine`
/// (ClipTransientCommandTests.swift) for stubbed onsets and `FakeMedia`
/// (ControlTests.swift, 2 s file → 4 beats @ 120).
@MainActor
@Suite("Clip audio quantize — control protocol (M5 iii-f)")
struct ClipQuantizeAudioCommandTests {

    private func makeRouter(engine: FakeTransientEngine? = nil) -> (CommandRouter, ProjectStore) {
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

    @Test("happy path: detects then returns head+slices; sensitivity forwarded")
    func happyPath() async throws {
        let engine = FakeTransientEngine()
        // Window [0, 2)s → beats [0, 4). Onsets 0.55/0.95/1.55 s → beats 1.1/1.9/3.1.
        engine.stubMarkers = [
            TransientMarker(timeSeconds: 0.55, strength: 1.0),
            TransientMarker(timeSeconds: 0.95, strength: 0.8),
            TransientMarker(timeSeconds: 1.55, strength: 0.6),
        ]
        let (router, store) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "gridBeats": .number(1.0), "strength": .number(1.0),
                     "sensitivity": .number(0.7), "crossfadeMs": .number(10)]))
        #expect(response.ok)
        let clips = try #require(response.result?["clips"]?.arrayValue)
        #expect(clips.count == 4)                     // head + 3 slices
        #expect(clips[0]["startBeat"]?.doubleValue == 0)   // head anchored at clip start
        #expect(store.tracks[0].clips.count == 4)
        #expect(engine.detectCalls == 1)
        #expect(engine.lastSensitivity == 0.7)
        #expect(engine.lastURL?.path == "/tmp/Loop.wav")
    }

    @Test("missing gridBeats and out-of-range knobs are field-named errors")
    func paramValidation() async throws {
        let engine = FakeTransientEngine()
        let (router, _) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)
        func send(_ extra: [String: JSONValue]) async -> ControlResponse {
            var p: [String: JSONValue] = ["trackId": .string(trackID), "clipId": .string(clipID)]
            p.merge(extra) { _, new in new }
            return await router.handle(ControlRequest(id: "x", command: "clip.quantizeAudio", params: p))
        }
        // Missing gridBeats.
        var r = await send([:])
        #expect(!r.ok); #expect(r.error?.contains("gridBeats") == true)
        // gridBeats <= 0.
        r = await send(["gridBeats": .number(0)])
        #expect(!r.ok); #expect(r.error?.contains("'gridBeats' must be greater than 0") == true)
        // strength out of range.
        r = await send(["gridBeats": .number(1), "strength": .number(2)])
        #expect(!r.ok); #expect(r.error?.contains("'strength' must be between 0 and 1") == true)
        // swing out of range.
        r = await send(["gridBeats": .number(1), "swing": .number(80)])
        #expect(!r.ok); #expect(r.error?.contains("'swing' must be between 50 and 75") == true)
        // sensitivity out of range.
        r = await send(["gridBeats": .number(1), "sensitivity": .number(-1)])
        #expect(!r.ok); #expect(r.error?.contains("'sensitivity' must be between 0 and 1") == true)
        // crossfadeMs out of range.
        r = await send(["gridBeats": .number(1), "crossfadeMs": .number(100)])
        #expect(!r.ok); #expect(r.error?.contains("'crossfadeMs' must be between 0 and 50") == true)
        // None of the invalid requests reached the engine.
        #expect(engine.detectCalls == 0)
    }

    @Test("MIDI clip surfaces quantizeRequiresAudioClip verbatim, before detection")
    func rejectsMIDI() async throws {
        let engine = FakeTransientEngine()
        let (router, _) = makeRouter(engine: engine)
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "gridBeats": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "clip \(clipID) is a MIDI clip — clip.quantizeAudio applies only to audio clips; use clip.quantize for MIDI notes")
        #expect(engine.detectCalls == 0)   // failed fast
    }

    @Test("non-identity stretch surfaces audioQuantizeStretchUnsupported verbatim")
    func rejectsStretch() async throws {
        let engine = FakeTransientEngine()
        let stretched = Clip(name: "s", startBeat: 0, lengthBeats: 4,
                             audioFileURL: URL(fileURLWithPath: "/tmp/s.wav"),
                             stretchRatio: 2)
        let track = Track(name: "Aud", kind: .audio, clips: [stretched])
        let store = ProjectStore(tracks: [track])
        store.engine = engine
        let router = CommandRouter(store: store)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(track.id.uuidString),
                     "clipId": .string(stretched.id.uuidString),
                     "gridBeats": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "clip \(stretched.id.uuidString) has a non-identity time-stretch — un-stretch it (clip.setStretch ratio 1, pitch 0) or bounce it first; elastic audio-quantize (per-slice stretch) lands in a future version")
        #expect(engine.detectCalls == 0)
    }

    @Test("fewer than 2 usable transients surfaces audioQuantizeNoTransients")
    func rejectsTooFewTransients() async throws {
        let engine = FakeTransientEngine()
        engine.stubMarkers = [TransientMarker(timeSeconds: 0.9, strength: 1)]  // one only
        let (router, store) = makeRouter(engine: engine)
        let (trackID, clipID) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "gridBeats": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("fewer than 2 usable transients") == true)
        #expect(store.tracks[0].clips.count == 1)   // untouched
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func headless() async throws {
        let (router, _) = makeRouter(engine: nil)
        let (trackID, clipID) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.quantizeAudio",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "gridBeats": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("clip.quantizeAudio is a registered command")
    func commandRegistered() {
        #expect(CommandRouter.allCommands.contains("clip.quantizeAudio"))
    }
}
