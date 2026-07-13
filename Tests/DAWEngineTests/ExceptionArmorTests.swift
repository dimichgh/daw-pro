import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m16-a coverage (docs/research/design-m16a-canvas-crash.md §6):
//
// C4 — the ObjC exception barrier: a caught NSException converts to the typed
// `EngineError.engineException` (name + reason + context preserved, teaching
// copy on `errorDescription`); the happy path returns the body's value; Swift
// errors thrown by the body propagate UNCHANGED (the barrier is transparent
// to everything but ObjC raises).
//
// C5 — the disconnected-player play guard: `startAllPlayers` /
// `prepareAllPlayers` never hand a detached/disconnected player to AVFAudio
// (pre-fix, `playAtTime:` raised "player started when in a disconnected
// state" there — the proven MainActor poisoner); a skipped clip posts ONE
// honest `clip-unplayable` notice through the m15-e `noticeSink`, and
// connected players still start (the negative control — plus every existing
// playback suite, which is the broader proof normal start is untouched).

// MARK: - C4: the barrier

@Suite("ObjC exception barrier (m16-a C4)")
struct ObjCExceptionBarrierTests {

    @Test("a raised NSException converts to engineException with name/reason/context preserved")
    func nsExceptionConverts() throws {
        let thrown = #expect(throws: EngineError.self) {
            try withObjCExceptionBarrier("barrier unit test") {
                NSException(name: NSExceptionName("DAWTestRaise"),
                            reason: "synthetic raise for the barrier test",
                            userInfo: nil).raise()
                return 0  // unreachable — the raise unwinds
            }
        }
        guard case let .engineException(name, reason, context) = try #require(thrown) else {
            Issue.record("expected .engineException, got \(String(describing: thrown))")
            return
        }
        #expect(name == "DAWTestRaise")
        #expect(reason == "synthetic raise for the barrier test")
        #expect(context == "barrier unit test")
        // The teaching copy the wire's LocalizedError mapping surfaces.
        let message = try #require(thrown?.errorDescription)
        #expect(message.contains("synthetic raise for the barrier test"))
        #expect(message.contains("barrier unit test"))
        #expect(message.contains("play again, or reopen the project"))
    }

    @Test("no exception: the body's value returns untouched")
    func happyPathReturnsValue() throws {
        let value = try withObjCExceptionBarrier("barrier unit test") { 40 + 2 }
        #expect(value == 42)
    }

    @Test("a Swift error thrown by the body propagates unchanged, never converted")
    func swiftErrorPropagatesUnchanged() {
        struct Marker: Error, Equatable { let tag: String }
        #expect(throws: Marker(tag: "untouched")) {
            try withObjCExceptionBarrier("barrier unit test") {
                throw Marker(tag: "untouched")
            }
        }
    }
}

// MARK: - C5: the play guard

@MainActor
@Suite("Disconnected-player play guard (m16-a C5)")
struct PlayerStartGuardTests {

    /// The EngineNoticeEngineTests harness shape: a manual-rendering engine
    /// (headless, no hardware) whose graph the tests reconcile directly.
    private func makeManualGraph() throws -> (AVAudioEngine, PlaybackGraph) {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        return (engine, graph)
    }

    /// 1 s of low-amplitude DC as a stereo Float32 WAV in a fresh temp dir.
    private func wavFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-armor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("tone.wav")
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
                                                   frameCapacity: 48_000))
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<48_000 {
            channels[0][frame] = 0.05
            channels[1][frame] = 0.05
        }
        buffer.frameLength = 48_000
        try file.write(from: buffer)
        return url
    }

    private final class EventBox {
        var events: [EngineNoticeEvent] = []
    }

    /// Builds one scheduled single-clip graph ready for `startAllPlayers`:
    /// reconcile (attaches + connects the clip player), manual-mode engine
    /// start, schedule pass. Returns the graph, the clip's player (the only
    /// `AVAudioPlayerNode` this harness attaches), the notice box, and the
    /// fixture URL.
    private func makeScheduledSingleClip(
        name: String, startBeat: Double
    ) throws -> (AVAudioEngine, PlaybackGraph, AVAudioPlayerNode, EventBox, URL) {
        let (engine, graph) = try makeManualGraph()
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        let url = try wavFixture()
        let clip = Clip(name: name, startBeat: startBeat, lengthBeats: 2,
                        audioFileURL: url)
        graph.reconcile(tracks: [Track(name: "T", kind: .audio, clips: [clip])])
        try engine.start()
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        let player = try #require(
            engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        return (engine, graph, player, box, url)
    }

    @Test("attached-but-disconnected player: startAllPlayers completes, skips it, posts clip-unplayable")
    func disconnectedPlayerIsSkippedWithNotice() throws {
        let (engine, graph, player, box, _) =
            try makeScheduledSingleClip(name: "Ghost Gtr", startBeat: 1)
        // The pre-fix poisoner state: attached to the engine, no output
        // connection ("player started when in a disconnected state").
        engine.disconnectNodeOutput(player)

        graph.startAllPlayers(at: nil)  // pre-fix: NSException raises HERE

        #expect(!player.isPlaying)
        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-unplayable")
        #expect(event.message.contains("Ghost Gtr"))
        #expect(event.message.contains("wasn't connected"))
        #expect(event.beat == 1)
    }

    @Test("negative control: a connected player still starts, zero notices")
    func connectedPlayerStillStarts() throws {
        let (_, graph, player, box, _) =
            try makeScheduledSingleClip(name: "Healthy Keys", startBeat: 0)

        graph.startAllPlayers(at: nil)

        #expect(player.isPlaying)
        #expect(box.events.isEmpty)
    }

    @Test("missing source file: the skip notice says the file is missing")
    func missingFileWordsTheNotice() throws {
        let (engine, graph, player, box, url) =
            try makeScheduledSingleClip(name: "Lost Vox", startBeat: 2)
        engine.disconnectNodeOutput(player)
        try FileManager.default.removeItem(at: url)

        graph.startAllPlayers(at: nil)

        // The schedule pass above already ran; the only NEW event is the
        // start-time skip (the fixture has no fades/envelope, so no bake
        // fallback fires).
        let event = try #require(box.events.last)
        #expect(box.events.count == 1)
        #expect(event.code == "clip-unplayable")
        #expect(event.message.contains("Lost Vox"))
        #expect(event.message.contains("missing (moved or deleted)"))
        #expect(event.beat == 2)
    }

    @Test("prepareAllPlayers guards too — silently (the start posts the notice), and a fully DETACHED player is skipped as well")
    func prepareGuardsSilentlyAndDetachedSkips() throws {
        let (engine, graph, player, box, _) =
            try makeScheduledSingleClip(name: "Orphan Pad", startBeat: 0)
        // Detach outright: the graph's clip node still holds the player, but
        // `player.engine == nil` — the other half of the playability check.
        engine.disconnectNodeOutput(player)
        engine.detach(player)

        graph.prepareAllPlayers(withFrameCount: 4_096)  // pre-fix: raise territory
        #expect(box.events.isEmpty)  // prepare never posts — one notice per start, not two

        graph.startAllPlayers(at: nil)
        #expect(!player.isPlaying)
        #expect(box.events.count == 1)
        #expect(box.events.first?.code == "clip-unplayable")
    }
}
