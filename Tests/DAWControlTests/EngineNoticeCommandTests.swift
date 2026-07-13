import AVFAudio
import Foundation
import Testing
import DAWCore
import DAWEngine
@testable import DAWControl

/// m15-e wire coverage: `project.snapshot` carries the engine-notices ring as
/// a top-level `engineNotices` array — a snapshot EXTENSION, no new command
/// (wire count stays 123). Headless suite pins the null case (key ABSENT on a
/// clean session), the coalesced wire shape, and the project.new clear; the
/// live suite is the mandatory end-to-end gate: a REAL `AudioEngine` with a
/// bake failure forced exactly like the transient-I/O condition (file deleted
/// after reconcile, before the bake) posts through the store into a real
/// `project.snapshot`, coalesces on a second degraded pass, and clears on
/// project.new. Reuses `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Engine notices — control protocol (m15-e)")
struct EngineNoticeCommandTests {

    /// Minimal engine that stores the installed notice handler (the store's
    /// real installation path).
    final class NoticeStubEngine: AudioEngineControlling {
        var isRunning = false
        var meteringHandler: ((MeterFrame) -> Void)?
        var trackMeteringHandler: ((UUID, MeterFrame) -> Void)?
        var playheadHandler: ((Double) -> Void)?
        var engineNoticeHandler: ((EngineNoticeEvent) -> Void)?

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
            AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 2)
        }
        var recordPermission: RecordPermission = .granted
        func requestRecordPermission(_ completion: @escaping @MainActor (Bool) -> Void) {
            completion(true)
        }
        func setInputDevice(uid: String?) throws {}
        func availableInputDevices() -> [AudioInputDevice] { [] }
        func startRecording(_ transport: TransportState, to url: URL,
                            completion: @escaping @MainActor (Result<RecordingResult, Error>) -> Void) throws {}
        func stopRecording() {}
    }

    private func makeRouter() -> (CommandRouter, ProjectStore, NoticeStubEngine) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let engine = NoticeStubEngine()
        store.engine = engine
        return (CommandRouter(store: store), store, engine)
    }

    @Test("null case: a clean session's snapshot has NO engineNotices key")
    func cleanSessionOmitsKey() async throws {
        let (router, store, _) = makeRouter()
        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        #expect(response.result?["engineNotices"] == nil)
        // Byte-level: the serialized snapshot carries no trace of the key.
        let bytes = try JSONEncoder().encode(store.snapshot())
        let json = try #require(String(data: bytes, encoding: .utf8))
        #expect(!json.contains("engineNotices"))
    }

    @Test("posted notices thread through project.snapshot with the {code,message,beat,count,lastAt} shape")
    func noticesThreadThrough() async throws {
        let (router, _, engine) = makeRouter()
        engine.engineNoticeHandler?(EngineNoticeEvent(
            code: "clip-envelope-skipped",
            message: "The gain envelope on 'Pad' couldn't be applied this pass — the clip played on time, without its envelope or fades.",
            beat: 4))
        engine.engineNoticeHandler?(EngineNoticeEvent(
            code: "clip-envelope-skipped",
            message: "The gain envelope on 'Pad' couldn't be applied this pass — the clip played on time, without its envelope or fades.",
            beat: 4))

        let response = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(response.ok)
        let notices = try #require(response.result?["engineNotices"]?.arrayValue)
        #expect(notices.count == 1)  // coalesced by code
        let notice = try #require(notices.first)
        #expect(notice["code"]?.stringValue == "clip-envelope-skipped")
        #expect(notice["message"]?.stringValue?.contains("Pad") == true)
        #expect(notice["beat"]?.doubleValue == 4)
        #expect(notice["count"]?.doubleValue == 2)
        #expect(notice["lastAt"]?.doubleValue == 2)
    }

    @Test("project.open with missing media echoes clip-file-missing into the ring (m16-c): the open response's snapshot AND a later poll both carry it")
    func openEchoesMissingMediaOverTheWire() async throws {
        let (router, store, _) = makeRouter()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("m16c-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A saved bundle whose media file is then deleted (audit B3 shape;
        // FakeMedia supplies the import facts, so stub bytes suffice).
        let src = dir.appendingPathComponent("Vox.wav")
        try Data([0x52, 0x49, 0x46, 0x46, 0x00]).write(to: src)
        let track = store.addTrack(kind: .audio)
        try store.importAudio(url: src, toTrack: track.id)
        let path = dir.appendingPathComponent("Silent").path
        try store.saveProject(to: path)
        try FileManager.default.removeItem(
            at: URL(fileURLWithPath: store.projectPath!).appendingPathComponent("media/Vox.wav"))

        let open = await router.handle(ControlRequest(
            id: "o", command: "project.open", params: ["path": .string(path)]))
        #expect(open.ok)
        // The response still warns (unchanged behavior)…
        let warnings = try #require(open.result?["warnings"]?.arrayValue)
        #expect(warnings.contains { $0.stringValue?.hasPrefix("missing media:") == true })
        // …and its snapshot now carries the same facts as a notice.
        let openNotices = try #require(
            open.result?["snapshot"]?["engineNotices"]?.arrayValue)
        #expect(openNotices.first?["code"]?.stringValue == "clip-file-missing")

        // The load-bearing agent story: a LATER snapshot poll — without the
        // open response in hand — still sees the degradation.
        let poll = await router.handle(ControlRequest(id: "s", command: "project.snapshot"))
        let polled = try #require(poll.result?["engineNotices"]?.arrayValue)
        #expect(polled.count == 1)
        #expect(polled.first?["code"]?.stringValue == "clip-file-missing")
        #expect(polled.first?["message"]?.stringValue?.contains("Vox") == true)
        #expect(polled.first?["message"]?.stringValue?.contains("will be silent") == true)
    }

    @Test("project.new clears the ring over the wire")
    func projectNewClears() async throws {
        let (router, _, engine) = makeRouter()
        engine.engineNoticeHandler?(EngineNoticeEvent(
            code: "clip-stretch-pending", message: "still stretching"))

        let fresh = await router.handle(ControlRequest(
            id: "1", command: "project.new",
            params: ["discardChanges": .bool(true)]))
        #expect(fresh.ok)
        #expect(fresh.result?["engineNotices"] == nil)

        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        #expect(snapshot.result?["engineNotices"] == nil)
    }
}

/// The mandatory m15-e end-to-end gate, LIVE: real `AudioEngine`, real file,
/// real bake failure, real `project.snapshot`. Serialized (hardware I/O);
/// skips silently on machines without an output device (the
/// `LoopRecordEngineTests` escape).
@MainActor
@Suite("Engine notices — live end-to-end (m15-e)", .serialized)
struct EngineNoticeLiveTests {

    /// 0.5 s of low-amplitude DC, stereo Float32 WAV in a fresh temp dir.
    private func wavFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-notice-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("bed.wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000.0,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = try #require(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 48_000, channels: 2,
                                                interleaved: false))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: 24_000))
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<24_000 {
            channels[0][frame] = 0.02
            channels[1][frame] = 0.02
        }
        buffer.frameLength = 24_000
        try file.write(from: buffer)
        return url
    }

    @Test("forced bake failure reaches project.snapshot; repeat coalesces to count 2; project.new clears")
    func forcedBakeFailureEndToEnd() async throws {
        // The PRODUCTION lifecycle (DAWProApp): engine attached cold, all
        // edits reconcile against the never-run engine, and the FIRST
        // transport.play runs prepare() lazily inside startPlayback.
        let engine = AudioEngine()
        defer { engine.shutdown() }

        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let router = CommandRouter(store: store)

        // Track + audio clip with fades, over the wire.
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let wav = try wavFixture()
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string(wav.path)]))
        #expect(addClip.ok)
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        let fades = await router.handle(ControlRequest(
            id: "f", command: "clip.setFades",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "fadeInBeats": .number(0.5), "fadeOutBeats": .number(0.5)]))
        #expect(fades.ok)

        // The engine's player opened the file at reconcile; now it vanishes
        // — the next schedule's bake reader cannot open it (the live
        // transient-I/O condition the m13-e fallback covers).
        try FileManager.default.removeItem(at: wav)

        // Play: the clip still schedules (timing wins) AND the notice lands.
        let play = await router.handle(ControlRequest(id: "p1", command: "transport.play"))
        #expect(play.ok)
        guard engine.isRunning else {
            return  // headless machine without an output device (prepare refused)
        }
        let first = await router.handle(ControlRequest(id: "s1", command: "project.snapshot"))
        let notices = try #require(first.result?["engineNotices"]?.arrayValue)
        #expect(notices.count == 1)
        let notice = try #require(notices.first)
        #expect(notice["code"]?.stringValue == "clip-fades-skipped")
        #expect(notice["message"]?.stringValue?.contains("without its fades") == true)
        #expect(notice["count"]?.doubleValue == 1)
        _ = await router.handle(ControlRequest(id: "st1", command: "transport.stop"))

        // A second degraded pass coalesces — one entry, count 2.
        _ = await router.handle(ControlRequest(
            id: "sk", command: "transport.seek", params: ["beats": .number(0)]))
        let replay = await router.handle(ControlRequest(id: "p2", command: "transport.play"))
        #expect(replay.ok)
        let second = await router.handle(ControlRequest(id: "s2", command: "project.snapshot"))
        let coalesced = try #require(second.result?["engineNotices"]?.arrayValue)
        #expect(coalesced.count == 1)
        #expect(coalesced.first?["count"]?.doubleValue == 2)
        _ = await router.handle(ControlRequest(id: "st2", command: "transport.stop"))

        // Project boundary clears the ring.
        let fresh = await router.handle(ControlRequest(
            id: "n", command: "project.new", params: ["discardChanges": .bool(true)]))
        #expect(fresh.ok)
        #expect(fresh.result?["engineNotices"] == nil)
    }
}
