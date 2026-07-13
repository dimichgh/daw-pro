import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m15-e (audit F6) engine-side coverage: the REAL `PlaybackGraph` posts an
/// `EngineNoticeEvent` from each schedule-time degradation site — the
/// envelope/fade bake-failure fallbacks ("timing wins") and the
/// stretch-pending silence transition — with honest codes, readable messages,
/// and the affected clip's start beat. Bake failures are forced exactly like
/// the live transient-I/O condition: the file opens fine at reconcile (the
/// player holds it) and is DELETED before the bake's fresh reader opens.
/// All sites are main-actor schedule/reconcile code; the sink is exercised
/// through the same `noticeSink` property `AudioEngine.wireGraphHooks`
/// installs.
@MainActor
@Suite("Engine notices — PlaybackGraph posts (m15-e)")
struct EngineNoticeEngineTests {

    // MARK: - Harness

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

    /// Writes 1 s of low-amplitude DC as a stereo Float32 WAV into a fresh
    /// temp directory, returning the file URL.
    private func wavFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-notice-\(UUID().uuidString)")
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

    private func collectingSink(_ graph: PlaybackGraph) -> EventBox {
        let box = EventBox()
        graph.noticeSink = { box.events.append($0) }
        return box
    }

    // MARK: - Fade bake failure (linear schedule path)

    @Test("deleted-under-us file: the fade bake catch posts clip-fades-skipped, once per schedule pass")
    func fadeBakeFailurePostsPerPass() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Guitar Tail", startBeat: 1, lengthBeats: 2,
                        audioFileURL: url, fadeInBeats: 0.5, fadeOutBeats: 0.5)
        let tracks = [Track(name: "Gtr", kind: .audio, clips: [clip])]

        // Reconcile opens the player's file while it still exists.
        graph.reconcile(tracks: tracks)
        #expect(box.events.isEmpty)

        // The live transient-I/O shape: the file vanishes before the bake's
        // fresh reader opens it.
        try FileManager.default.removeItem(at: url)
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))

        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-fades-skipped")
        #expect(event.message.contains("Guitar Tail"))
        #expect(event.beat == 1)

        // Every degraded schedule pass posts again (the store coalesces).
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        #expect(box.events.count == 2)
        #expect(box.events.allSatisfy { $0.code == "clip-fades-skipped" })
    }

    // MARK: - Envelope bake failure (m13-h2 fallback)

    @Test("deleted-under-us file: the envelope bake catch posts clip-envelope-skipped")
    func envelopeBakeFailurePosts() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Synth Swell", startBeat: 0, lengthBeats: 2,
                        audioFileURL: url,
                        gainEnvelope: [ClipGainPoint(beat: 0, gainDb: 0),
                                       ClipGainPoint(beat: 2, gainDb: -12)])
        graph.reconcile(tracks: [Track(name: "Syn", kind: .audio, clips: [clip])])
        try FileManager.default.removeItem(at: url)

        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))

        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-envelope-skipped")
        #expect(event.message.contains("Synth Swell"))
        #expect(event.beat == 0)
    }

    // MARK: - Loop-cycle bake failure

    @Test("loop schedule: BOTH the head and the cycle-plan fade bakes post on failure")
    func loopCycleBakeFailurePosts() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Loop Bed", startBeat: 0, lengthBeats: 2,
                        audioFileURL: url, fadeInBeats: 0.5, fadeOutBeats: 0.5)
        graph.reconcile(tracks: [Track(name: "Bed", kind: .audio, clips: [clip])])
        try FileManager.default.removeItem(at: url)

        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120),
                          loop: PlaybackGraph.LoopWindow(startBeat: 0, endBeat: 2))

        // One post from the truncated head schedule, one from buildCyclePlan
        // — same code (one degradation family; the store coalesces to one
        // ring entry, count 2).
        #expect(box.events.count == 2)
        #expect(box.events.allSatisfy { $0.code == "clip-fades-skipped" })
        #expect(box.events.allSatisfy { $0.beat == 0 })
        #expect(box.events.contains { $0.message.contains("looped repeats") })
    }

    // MARK: - Stretch-pending silence

    @Test("stretch-pending posts ONCE per pending episode; a ready resolution re-arms the gate")
    func stretchPendingPostsOncePerEpisode() throws {
        let (_, graph) = try makeManualGraph()
        let box = collectingSink(graph)
        let url = try wavFixture()
        let clip = Clip(name: "Slowed Vox", startBeat: 4, lengthBeats: 2,
                        audioFileURL: url, stretchRatio: 1.5)
        var tracks = [Track(name: "Vox", kind: .audio, clips: [clip])]

        graph.stretchResolver = { _ in .pending }
        graph.reconcile(tracks: tracks)

        #expect(box.events.count == 1)
        let event = try #require(box.events.first)
        #expect(event.code == "clip-stretch-pending")
        #expect(event.message.contains("Slowed Vox"))
        #expect(event.beat == 4)

        // Still pending on the next pass — reconcile re-resolves every pass,
        // but the episode was already noticed.
        graph.reconcile(tracks: tracks)
        #expect(box.events.count == 1)

        // The render lands: the clip schedules for real and the gate re-arms.
        graph.stretchResolver = { _ in .ready(url) }
        graph.reconcile(tracks: tracks)
        #expect(box.events.count == 1)

        // A re-edit back into a pending render (new schedule key) posts again
        // — a NEW pending episode.
        graph.stretchResolver = { _ in .pending }
        tracks[0].clips[0].stretchRatio = 2.0
        graph.reconcile(tracks: tracks)
        #expect(box.events.count == 2)
        #expect(box.events.last?.code == "clip-stretch-pending")
    }
}
