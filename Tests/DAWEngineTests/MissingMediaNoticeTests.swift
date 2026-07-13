import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m16-c coverage (audit F2, §2-B3): a clip whose media file cannot be OPENED
// at graph-build time is skipped entirely — no player node is created, so the
// m16-a play guard (`startAllPlayers` walks existing ClipNodes only) can
// never see it. Pre-fix that skip was stderr-only: the clip played as silence
// with ZERO notice. These tests pin:
//  - the build-time open catch posts ONE honest `clip-file-missing` notice
//    (clip name + path + beat, missing vs unreadable wordings), and
//  - the evasion mechanism itself: the skipped clip produces NO player node
//    and `startAllPlayers` posts nothing for it (no `clip-unplayable`), and
//  - the once-per-missing-episode discipline (the `stretchPendingNoticed`
//    shape): repeat reconciles/plays never re-post; a healed open re-arms.
@MainActor
@Suite("Missing-media build-time notice (m16-c)")
struct MissingMediaNoticeTests {

    /// The ExceptionArmorTests harness shape: a manual-rendering engine
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

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-missing-media-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 0.5 s of low-amplitude DC as a stereo Float32 WAV at `url`.
    private func writeWav(to url: URL) throws {
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
            channels[0][frame] = 0.05
            channels[1][frame] = 0.05
        }
        buffer.frameLength = 24_000
        try file.write(from: buffer)
    }

    private final class EventBox {
        var events: [EngineNoticeEvent] = []
    }

    private func attachedPlayers(_ engine: AVAudioEngine) -> [AVAudioPlayerNode] {
        engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }
    }

    // MARK: - The B3 gap, closed

    @Test("missing file at graph build: clip skipped with ONE clip-file-missing notice; the play pass sees nothing (the m16-a evasion, pinned)")
    func missingFileAtBuildPostsOnce() throws {
        let (engine, graph) = try makeManualGraph()
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        let url = try tempDir().appendingPathComponent("gone.wav")  // never written

        let clip = Clip(name: "Lost Vox", startBeat: 3, lengthBeats: 2,
                        audioFileURL: url)
        graph.reconcile(tracks: [Track(name: "T", kind: .audio, clips: [clip])])

        // The honest notice, from the open catch itself.
        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-file-missing")
        #expect(event.message.contains("Lost Vox"))
        #expect(event.message.contains("missing"))
        #expect(event.message.contains(url.path))
        #expect(event.beat == 3)

        // The evasion mechanism: NO player node was created for the clip…
        #expect(attachedPlayers(engine).isEmpty)
        // …so the m16-a play guard has nothing to inspect: a play pass posts
        // NOTHING for this clip (pre-m16-c it played as silence, zero notice).
        try engine.start()
        graph.startAllPlayers(at: nil)
        #expect(box.events.count == 1)
        #expect(!box.events.contains { $0.code == "clip-unplayable" })
    }

    @Test("repeat reconciles and play passes never re-post — one notice per missing episode")
    func repeatPassesDoNotRepost() throws {
        let (engine, graph) = try makeManualGraph()
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        let url = try tempDir().appendingPathComponent("gone.wav")
        var track = Track(name: "T", kind: .audio,
                          clips: [Clip(name: "Ghost", startBeat: 0, lengthBeats: 2,
                                       audioFileURL: url)])

        graph.reconcile(tracks: [track])
        #expect(box.events.count == 1)

        // Every reconcile pass retries the open (the clip stays node-less in
        // the signature) — the episode gate keeps the ring from inflating.
        graph.reconcile(tracks: [track])
        graph.reconcile(tracks: [track])
        #expect(box.events.count == 1)

        // Play passes see no node at all — nothing further posts.
        try engine.start()
        graph.startAllPlayers(at: nil)
        graph.startAllPlayers(at: nil)
        #expect(box.events.count == 1)

        // An unrelated edit (a second, healthy-free track) reconciles again:
        // still one post for the same missing episode.
        track.name = "T renamed"
        graph.reconcile(tracks: [track])
        #expect(box.events.count == 1)
    }

    @Test("a healed open re-arms the notice: file restored → node built silently; missing again on a re-add → posts again")
    func healedOpenReArms() throws {
        let (engine, graph) = try makeManualGraph()
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        let url = try tempDir().appendingPathComponent("flaky.wav")
        let clip = Clip(name: "Flaky", startBeat: 0, lengthBeats: 2,
                        audioFileURL: url)
        var track = Track(name: "T", kind: .audio, clips: [clip])

        // Episode 1: missing → one post.
        graph.reconcile(tracks: [track])
        #expect(box.events.count == 1)

        // Heal: the file appears; the retrying reconcile builds the node —
        // no new post (healing is not a degradation).
        try writeWav(to: url)
        graph.reconcile(tracks: [track])
        #expect(attachedPlayers(engine).count == 1)
        #expect(box.events.count == 1)

        // Episode 2: file gone again AND the clip's schedule key changes
        // (moved), forcing a node re-add whose open fails → the re-armed
        // gate posts a second notice at the NEW beat.
        try FileManager.default.removeItem(at: url)
        var moved = clip
        moved.startBeat = 8
        track.clips = [moved]
        graph.reconcile(tracks: [track])
        #expect(box.events.count == 2)
        #expect(box.events.last?.code == "clip-file-missing")
        #expect(box.events.last?.beat == 8)
    }

    @Test("an unreadable (present but corrupt) file posts the couldn't-be-opened wording")
    func unreadableFileWording() throws {
        let (_, graph) = try makeManualGraph()
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        let url = try tempDir().appendingPathComponent("corrupt.wav")
        try Data([0x00, 0x01, 0x02, 0x03, 0xFF, 0xFE, 0xFD, 0xFC]).write(to: url)

        graph.reconcile(tracks: [Track(name: "T", kind: .audio,
                                       clips: [Clip(name: "Damaged", startBeat: 1,
                                                    lengthBeats: 2, audioFileURL: url)])])

        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-file-missing")
        #expect(event.message.contains("Damaged"))
        #expect(event.message.contains("couldn't be opened"))
        #expect(event.beat == 1)
    }

    @Test("negative control: a healthy file builds its node with zero notices")
    func healthyFileZeroNotices() throws {
        let (engine, graph) = try makeManualGraph()
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        let url = try tempDir().appendingPathComponent("fine.wav")
        try writeWav(to: url)

        graph.reconcile(tracks: [Track(name: "T", kind: .audio,
                                       clips: [Clip(name: "Fine", startBeat: 0,
                                                    lengthBeats: 2, audioFileURL: url)])])

        #expect(attachedPlayers(engine).count == 1)
        #expect(box.events.isEmpty)
    }
}
