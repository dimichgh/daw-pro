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

// m20-d (m19-k Phase 2): the value injected into LIVE graphs is no longer the
// output device's rate but the constant `AudioEngine.projectSampleRate`, so
// every graph-rate consumer — edge formats, chain DSP, PDC, AU prepare keys —
// is device-INVARIANT and the ONE sample-rate conversion happens on the output
// node's input scope.
//
// HOW THESE CAN FAIL. The pre-m20-d live graph was built with
// `graphRate: currentDeviceRate(of: engine)`, i.e. the output node's rate with
// a 48 kHz zero-guard — which is byte-identical to what `graphFormat()` still
// computes for an UN-INJECTED graph. So `PlaybackGraph(engine:)` on a
// manual-rendering engine pinned at 44.1/96 kHz reproduces the old behaviour
// exactly, and every test below asserts the old value on that control next to
// the new value on the injected graph. No hardware, no CoreAudio mocking.
@MainActor
@Suite("Project-rate live graph (m20-d)")
struct ProjectRateGraphTests {

    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")

    /// A manual-rendering engine pinned at `rate` — its `outputNode` reports
    /// `rate`, which is what the pre-m20-d construction path would have read.
    private func makeManualEngine(rate: Double) throws -> AVAudioEngine {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
        _ = engine.mainMixerNode
        return engine
    }

    @Test("the live graph runs at AudioEngine.projectSampleRate, not the output device's rate")
    func liveGraphRunsAtProjectRate() throws {
        #expect(AudioEngine.projectSampleRate == 48_000)

        // What the pre-m20-d path would have injected: the default output
        // device's nominal rate. NAMED binding — an inline temporary
        // deallocates while the IO node (weak engine back-ref) is still
        // answering the format query (measured SIGSEGV in
        // AVAudioIONodeImpl::GetOutputFormat, EngineRebuildTests).
        let scratch = AVAudioEngine()
        let deviceRate = scratch.outputNode.outputFormat(forBus: 0).sampleRate
        withExtendedLifetime(scratch) {}

        let engine = AudioEngine()
        let graphRate = engine.graph.graphSampleRateForTesting
        // Printed, not just asserted: this leg only DISCRIMINATES when the
        // machine's output device is not already at 48 kHz. The transcript
        // records which of the two it was on this run; the cross-rate proof is
        // the live gate (scripts/gates/m20d-project-rate.mjs, BlackHole staged
        // at 44.1 kHz), where the pre-m20-d engine read 44100 after a rebuild.
        print("[measured] m20-d: default output device rate \(deviceRate), "
              + "live graph rate \(graphRate), "
              + "discriminating: \(deviceRate != AudioEngine.projectSampleRate)")
        #expect(graphRate == AudioEngine.projectSampleRate)
        #expect(engine.graph.graphSampleRate == AudioEngine.projectSampleRate)
    }

    @Test("injected project rate wins over the engine's own rate at 44.1 and 96 kHz")
    func projectRateIsIndependentOfEngineRate() throws {
        for deviceRate in [44_100.0, 96_000.0] {
            let engine = try makeManualEngine(rate: deviceRate)

            // The live shape since m20-d.
            let pinned = PlaybackGraph(engine: engine, graphRate: AudioEngine.projectSampleRate)
            #expect(pinned.graphSampleRate == 48_000)
            #expect(pinned.graphSampleRateForTesting == 48_000)

            // Edges BUILD at the project rate, not the engine's.
            let track = Track(name: "A", kind: .audio,
                              clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)])
            #expect(pinned.reconcile(tracks: [track]))
            let mixer = try #require(pinned.stripMixer(forTrack: track.id))
            #expect(mixer.outputFormat(forBus: 0).sampleRate == 48_000)

            // The pre-m20-d control on the SAME engine: follows the device.
            let following = PlaybackGraph(engine: engine)
            #expect(following.graphSampleRate == deviceRate)
            #expect(following.graphSampleRate != AudioEngine.projectSampleRate)
        }
    }

    @Test("limiter lookahead pins at 240 samples on any device (m19-j sensitivity class dies)")
    func limiterLatencyIsDeviceInvariant() throws {
        func chainLatency(graphRate: Double?, engineRate: Double) throws -> Int {
            let engine = try makeManualEngine(rate: engineRate)
            let graph = PlaybackGraph(engine: engine, graphRate: graphRate)
            let track = Track(name: "Lim", kind: .audio,
                              clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4)],
                              effects: [EffectDescriptor(kind: .limiter)])
            #expect(graph.reconcile(tracks: [track]))
            graph.applyParameters(tracks: [track])
            return graph.chainLatencySamples(forTrack: track.id)
        }

        // 5 ms × 48 000 = 240, whatever the device runs at (design §2.3 A4).
        let at44 = try chainLatency(graphRate: AudioEngine.projectSampleRate, engineRate: 44_100)
        let at96 = try chainLatency(graphRate: AudioEngine.projectSampleRate, engineRate: 96_000)
        print("[measured] m20-d limiter lookahead: 44.1 kHz device \(at44), "
              + "96 kHz device \(at96) (expected 240 / 240)")
        #expect(at44 == 240)
        #expect(at96 == 240)

        // The pre-m20-d control: device-derived, so the pin MOVED per device —
        // round(0.005 × 44 100) = 221, round(0.005 × 96 000) = 480.
        let old44 = try chainLatency(graphRate: nil, engineRate: 44_100)
        let old96 = try chainLatency(graphRate: nil, engineRate: 96_000)
        #expect(old44 == 221)
        #expect(old96 == 480)
        #expect(old44 != 240 && old96 != 240)  // the legs above are not vacuous
    }

    @Test("AU prepare keys are identical across device rates (no re-prepare storm)")
    func auPrepareKeyIsDeviceInvariant() throws {
        let track = Track(name: "Keys", kind: .instrument,
                          instrument: InstrumentDescriptor(
                              kind: .audioUnit,
                              audioUnit: AudioUnitConfig(component: Self.dls)))
        let engine44 = try makeManualEngine(rate: 44_100)
        let engine96 = try makeManualEngine(rate: 96_000)

        // The key AudioEngine.swift:1329/:1381 build: prepareKey fed from
        // `graph.graphSampleRate`. Two engines whose devices disagree by more
        // than an octave produce the SAME key.
        let pinned44 = PlaybackGraph(engine: engine44, graphRate: AudioEngine.projectSampleRate)
        let pinned96 = PlaybackGraph(engine: engine96, graphRate: AudioEngine.projectSampleRate)
        let key44 = try #require(
            AUHostRegistry.prepareKey(track: track, sampleRate: pinned44.graphSampleRate))
        let key96 = try #require(
            AUHostRegistry.prepareKey(track: track, sampleRate: pinned96.graphSampleRate))
        #expect(key44 == key96)
        #expect(key44.sampleRate == 48_000)

        // Bind the PRODUCTION reader to that claim: AudioEngine.swift:1329
        // (instruments) and :1381 (effects) feed `graph.graphSampleRate` into
        // exactly this call, so a live engine must key where the pinned graphs
        // key. Without this leg the two graphs above are constructed with a
        // rate this test itself supplies — the seam, not the engine's choice
        // of value. Reddens if live graph construction ever goes back to
        // injecting the device rate on a non-48 kHz machine.
        let live = AudioEngine()
        let liveKey = try #require(
            AUHostRegistry.prepareKey(track: track, sampleRate: live.graph.graphSampleRate))
        #expect(liveKey == key44)

        // The pre-m20-d control: the same track on the same two devices keyed
        // DIFFERENTLY (44 100 vs 96 000), and a changed key is what released
        // and re-prepared the instrument on every device flip (design §2.2/5).
        let old44 = try #require(
            AUHostRegistry.prepareKey(
                track: track, sampleRate: PlaybackGraph(engine: engine44).graphSampleRate))
        let old96 = try #require(
            AUHostRegistry.prepareKey(
                track: track, sampleRate: PlaybackGraph(engine: engine96).graphSampleRate))
        #expect(old44 != old96)
        #expect(old44.sampleRate == 44_100)
        #expect(old96.sampleRate == 96_000)
    }
}
