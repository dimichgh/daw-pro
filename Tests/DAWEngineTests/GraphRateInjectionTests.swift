import AVFAudio
import DAWCore
import Testing
@testable import DAWEngine

// m20-c (m19-k Phase 1): the graph's processing rate is an INJECTED
// construction parameter, not a live output-node query. These tests pin the
// seam directly — a graph built with an explicit non-default rate reports it
// and builds its edges at it, regardless of the engine's own rate — rather
// than only by whole-suite invariance. No live hardware: manual-rendering
// engines throughout.
@MainActor
@Suite("Graph rate injection (m20-c)")
struct GraphRateInjectionTests {

    private func makeManualEngine() throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 512)
        _ = engine.mainMixerNode
        return engine
    }

    @Test("injected non-default rate wins over the engine's rate and shapes the built formats")
    func injectedRateWins() throws {
        let engine = try makeManualEngine()  // engine pinned at 48 kHz
        let graph = PlaybackGraph(engine: engine, graphRate: 44_100)

        // The seam itself: the graph reports the INJECTED rate, not the
        // engine's 48 kHz manual-rendering rate.
        #expect(graph.graphSampleRateForTesting == 44_100)
        #expect(graph.graphSampleRate == 44_100)

        // And formats BUILD at it: reconcile one strip and read the strip
        // mixer's output-bus format (set by the explicit-format connect).
        let track = Track(name: "A", kind: .audio,
                          clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])
        #expect(graph.reconcile(tracks: [track]))
        let mixer = try #require(graph.stripMixer(forTrack: track.id))
        #expect(mixer.outputFormat(forBus: 0).sampleRate == 44_100)
    }

    @Test("un-injected construction keeps the legacy engine-rate query")
    func defaultFollowsEngine() throws {
        let engine = try makeManualEngine()
        let graph = PlaybackGraph(engine: engine)
        #expect(graph.graphSampleRateForTesting == 48_000)
        #expect(graph.graphSampleRate == 48_000)
    }
}
