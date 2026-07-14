import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// THE m13-d (C0) GATING SPIKE for the master insert chain
/// (docs/research/design-m13d-master-chain.md §8-C0; kept like the m12-a
/// `SidechainBusSpikeTests` — a permanent bit-transparency gate, not a
/// throwaway).
///
/// Question under measurement — condition zero for the whole feature: is the
/// ALWAYS-INSTALLED master insert point BIT-TRANSPARENT with an empty chain
/// against today's shape? The m12-b byte anchors are the permanent null-case
/// oracle, so an empty master chain MUST reproduce the pre-m13-d output
/// exactly — every float of every render, not "close".
///
/// C0 VERDICT (measured 2026-07-12): design D1 (pre-fader sandwich,
/// `masterSumMixer → chainHost → mainMixerNode`) FAILED — 1-ulp drift from
/// frame 241 (0x3f172767 vs 0x3f172768) on the representative session,
/// because `AVAudioMixerNode` applies its output volume PER INPUT during
/// accumulation (`a·v + b·v + c·v`), while D1 sums at unity first
/// (`(a+b+c)·v`) — non-associative float math under any non-unity master
/// fader. Per the design's explicit ladder (§8-C0), the production shape is
/// the fallback §1-B POST-FADER insert
/// (`mainMixerNode → masterChainHost → outputNode`), which leaves the strip
/// sum and fader math untouched by construction; THIS suite now gates that
/// shape and must stay byte-identical forever.
///
/// The A/B rig is the REAL production render loop both times:
/// `OfflineRenderer.render` over the same `PlaybackGraph`, with the
/// C0-spike-only seam (`masterSandwichEnabled = false`) reproducing the
/// pre-m13-d topology code path verbatim. The representative session carries
/// every summing shape the anchors exercise: audio + instrument + bus +
/// send + per-track effects (limiter latency → live PDC plan) + non-unity
/// masterVolume.
///
/// The anchor half of C0 (m12-b SHAs byte-identical through the insert
/// build) runs over the wire against the saved gate project — recorded in
/// the m13-d roadmap entry, re-run per era.
@MainActor
@Suite("Master sandwich — C0 bit-transparency spike (m13-d)", .serialized)
struct MasterSandwichTransparencyTests {

    // MARK: - Representative session (design §8-C0)

    /// audio ("Gtr": EQ + limiter inserts, send → bus) + audio ("Bass",
    /// panned) + instrument ("Keys", poly synth notes) + bus ("FXBus",
    /// delay) — non-unity master fader applied by the caller.
    private func representativeSession() throws -> [Track] {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        let bus = Track(id: busID, name: "FXBus", kind: .bus,
                        effects: [EffectDescriptor(
                            kind: .delay,
                            delay: DelayParams(timeMs: 200, feedback: 0.4, mix: 0.5,
                                               pingPong: 0, highCutHz: 10_000))])
        var eq = EQParams()
        eq.peak1GainDb = 3
        let gtr = Track(name: "Gtr", kind: .audio, volume: 0.9, pan: -0.3,
                        clips: [Clip(name: "g", startBeat: 0, lengthBeats: 4,
                                     audioFileURL: fixtures.cos1k48)],
                        sends: [Send(destinationBusID: busID, level: 0.5)],
                        effects: [EffectDescriptor(kind: .eq, eq: eq),
                                  EffectDescriptor(kind: .limiter)])
        let bass = Track(name: "Bass", kind: .audio, volume: 0.8, pan: 0.4,
                         clips: [Clip(name: "b", startBeat: 0, lengthBeats: 4,
                                      audioFileURL: fixtures.cos1k48Quarter)])
        var keys = Track(name: "Keys", kind: .instrument)
        keys.clips = [Clip(name: "k", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1),
            MIDINote(pitch: 67, velocity: 110, startBeat: 2, lengthBeats: 1.5),
        ])]
        return [gtr, bass, keys, bus]
    }

    private func render(sandwich: Bool, masterEffects: [EffectDescriptor] = [],
                        tracks: [Track]) throws -> RenderedAudio {
        let renderer = OfflineRenderer()
        renderer.masterSandwichEnabled = sandwich
        return try renderer.render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, durationSeconds: 1.5, masterVolume: 0.85,
            masterEffects: masterEffects)
    }

    /// Bit-pattern equality: byte-identical, stricter than Float `==`
    /// (distinguishes -0.0 from 0.0).
    private func bitIdentical(_ a: RenderedAudio, _ b: RenderedAudio)
        -> (identical: Bool, firstDiff: String) {
        guard a.channelData.count == b.channelData.count else {
            return (false, "channel counts \(a.channelData.count) vs \(b.channelData.count)")
        }
        for channel in 0..<a.channelData.count {
            let lhs = a.channelData[channel]
            let rhs = b.channelData[channel]
            guard lhs.count == rhs.count else {
                return (false, "ch \(channel) frame counts \(lhs.count) vs \(rhs.count)")
            }
            for frame in 0..<lhs.count where lhs[frame].bitPattern != rhs[frame].bitPattern {
                return (false, "ch \(channel) frame \(frame): "
                        + "\(lhs[frame]) (0x\(String(lhs[frame].bitPattern, radix: 16))) vs "
                        + "\(rhs[frame]) (0x\(String(rhs[frame].bitPattern, radix: 16)))")
            }
        }
        return (true, "none")
    }

    // MARK: - C0: the bit-transparency measurement

    @Test("empty §1-B master insert is BYTE-IDENTICAL to today's shape on the representative session")
    func emptySandwichIsBitTransparent() throws {
        let tracks = try representativeSession()

        // Baseline determinism first: the A/B comparison is only meaningful
        // if the legacy shape reproduces itself (the m12-a determinism rule).
        let legacy1 = try render(sandwich: false, tracks: tracks)
        let legacy2 = try render(sandwich: false, tracks: tracks)
        let legacyDeterminism = bitIdentical(legacy1, legacy2)
        try #require(legacyDeterminism.identical,
                     "legacy shape not deterministic: \(legacyDeterminism.firstDiff)")

        // THE measurement: §1-B insert (empty chain) vs today's shape.
        let sandwich = try render(sandwich: true, tracks: tracks)
        let verdict = bitIdentical(legacy1, sandwich)

        // Real audio on both sides — never two agreeing silences.
        let frames = legacy1.channelData[0].count
        let legacyRMS = TestSignals.rms(legacy1.channelData[0], in: 0..<frames)
        print("[measured] C0 transparency over \(frames) frames × "
              + "\(legacy1.channelData.count) ch: byte-identical \(verdict.identical) "
              + "(first diff: \(verdict.firstDiff)); legacy ch0 RMS \(legacyRMS)")
        #expect(legacyRMS > 0.05)
        #expect(verdict.identical, "§1-B master insert not bit-transparent: \(verdict.firstDiff)")

        // And the insert build is deterministic in its own right.
        let sandwich2 = try render(sandwich: true, tracks: tracks)
        #expect(bitIdentical(sandwich, sandwich2).identical)
    }

    @Test("a non-empty master chain actually processes (the transparency above is not a dead code path)")
    func nonEmptyChainProcesses() throws {
        let tracks = try representativeSession()
        let clean = try render(sandwich: true, tracks: tracks)
        // gain 0.5 on master: linear, zero-latency — output must differ.
        let halved = try render(
            sandwich: true,
            masterEffects: [EffectDescriptor(kind: .gain,
                                             gain: GainParams(gainLinear: 0.5))],
            tracks: tracks)
        let frames = min(clean.channelData[0].count, halved.channelData[0].count)
        var maxRatioError: Float = 0
        for frame in 0..<frames where abs(clean.channelData[0][frame]) > 1e-3 {
            let ratio = halved.channelData[0][frame] / clean.channelData[0][frame]
            maxRatioError = max(maxRatioError, abs(ratio - 0.5))
        }
        print("[measured] C0 non-empty chain: max |ratio - 0.5| over audible frames = \(maxRatioError)")
        #expect(maxRatioError < 1e-4)
    }

    // MARK: - R1 pins (EngineRebuildTests style)

    private func makeManualEngine() throws -> (AVAudioEngine, PlaybackGraph) {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        return (engine, graph)
    }

    private func renderOneBlock(_ engine: AVAudioEngine) throws {
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        let status = try engine.renderOffline(1_024, to: buffer)
        try #require(status == .success)
    }

    @Test("ensureMasterSandwich is idempotent, attach-only, and NEVER sets needsEngineRebuild")
    func sandwichCreationNeverAnnounces() throws {
        let (engine, graph) = try makeManualEngine()
        var announces = 0
        graph.willMutateRoutingTopology = { announces += 1 }

        // First reconcile (empty session) builds the insert.
        graph.reconcile(tracks: [])
        #expect(graph.masterChainHost != nil)
        #expect(!graph.needsEngineRebuild)
        #expect(announces == 0)
        let attachedAfterBuild = engine.attachedNodes.count
        let hostIdentity = try #require(graph.masterChainHost)
        // §1-B wiring: mainMixer → chainHost (bus 0) → outputNode.
        let inputPoint = engine.inputConnectionPoint(for: hostIdentity, inputBus: 0)
        #expect(inputPoint?.node === engine.mainMixerNode)
        #expect(hostIdentity.engine === engine)

        // Idempotent across further reconciles — and across the
        // once-rendered boundary (the m13-a poison precondition).
        //
        // EXPECTATION REPLACEMENT (m16-h): this pass used to birth strips
        // on the RUNNING once-rendered engine and assert no announce — the
        // exact shape the reconfig defect rode (a post-start strip sandwich
        // hosts permanently unstartable players), which reconcile now
        // announces BY DESIGN (design-m16h-reconfig.md Leg 2; pinned in
        // EngineRebuildTests C7a). The sandwich-transparency target of this
        // pin is preserved: the post-boundary reconcile keeps the SAME
        // track (no birth) and ensureMasterSandwich runs again directly —
        // still zero announces, zero rebuild debt, stable host identity.
        let trackA = Track(name: "A", kind: .audio)
        graph.reconcile(tracks: [trackA])
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)
        graph.ensureMasterSandwich()
        graph.reconcile(tracks: [trackA])

        #expect(!graph.needsEngineRebuild)
        #expect(announces == 0)
        #expect(graph.masterChainHost === hostIdentity)
        #expect(engine.attachedNodes.contains(hostIdentity))
        #expect(engine.attachedNodes.count >= attachedAfterBuild)
        engine.stop()
    }

    @Test("a master chain edit on a once-rendered engine is a chain publish — no rebuild, node identity stable")
    func masterChainEditIsNeverTopology() throws {
        let (engine, graph) = try makeManualEngine()
        graph.reconcile(tracks: [Track(name: "A", kind: .audio)])
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)

        let hostBefore = try #require(graph.masterChainHost)
        let attachedBefore = engine.attachedNodes.count

        // The live fx.add path: descriptors land, one parameter pass syncs.
        graph.masterEffects = [EffectDescriptor(kind: .eq),
                               EffectDescriptor(kind: .limiter)]
        graph.applyParameters(tracks: [Track(name: "A", kind: .audio)])

        #expect(!graph.needsEngineRebuild)
        #expect(graph.masterChainHost === hostBefore)
        #expect(engine.attachedNodes.count == attachedBefore)
        // The chain state saw the edit: the limiter's lookahead is live…
        #expect(graph.masterChainState?.latencySamples == 240)
        // …and the PDC report carries it (report-only, design D5).
        #expect(graph.pdcReport?.masterChainLatencySamples == 240)
        engine.stop()
    }
}
