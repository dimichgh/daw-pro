import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (viii-c) — PDC recompute wiring. Proves the always-on plan drive: every
/// `applyParameters` pass maps strip state into `PDCInput`, computes
/// `PDCPlan`, and pushes each strip's ring target as one atomic store —
/// covering chain edits, bypass toggles, effect removal, routing, and the
/// engine-protocol reporting surface. Graph-level suites read targets back
/// through `compensationState(forStrip:)`; the integration suite drives the
/// real `ProjectStore → AudioEngine` path and reads `pdcReport()`.
@MainActor
@Suite("PDC recompute wiring", .serialized)
struct PDCWiringTests {
    /// The built-in limiter's fixed lookahead at the 48 kHz graph rate.
    private static let limiterLatency = 240

    // MARK: - Harness

    /// Manual-rendering engine + graph at 48 kHz (the EffectChainRenderTests
    /// harness) so the limiter's latency is deterministic (240) without
    /// touching hardware.
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

    private func limiterFX() -> EffectDescriptor {
        EffectDescriptor(kind: .limiter, limiter: LimiterParams(ceilingDb: 0))
    }

    private func target(_ graph: PlaybackGraph, _ stripID: UUID) throws -> Int {
        try #require(graph.compensationState(forStrip: stripID)).currentTarget
    }

    // MARK: - Plan drive on chain edits

    @Test("applyParameters pushes plan targets: dry strip pads to the limiter strip's latency")
    func chainSyncPushesPlanTargets() throws {
        let (_, graph) = try makeManualEngine()
        let dry = Track(name: "Dry", kind: .audio)
        let latent = Track(name: "Limited", kind: .audio, effects: [limiterFX()])
        graph.reconcile(tracks: [dry, latent])
        graph.applyParameters(tracks: [dry, latent])

        // T = 240, B = 0. Dry outputs to master with no sends → the free
        // refinement pads it to T + B = 240; the latent strip is the max.
        #expect(try target(graph, dry.id) == Self.limiterLatency)
        #expect(try target(graph, latent.id) == 0)

        let report = try #require(graph.pdcReport)
        #expect(report.trackStageSamples == Self.limiterLatency)
        #expect(report.busStageSamples == 0)
        #expect(report.maxPathLatencySamples == Self.limiterLatency)
        #expect(report.outputLatencySamples == Self.limiterLatency)
        #expect(report.strips[latent.id]?.chainLatencySamples == Self.limiterLatency)
        #expect(report.strips[latent.id]?.compensationSamples == 0)
        #expect(report.strips[dry.id]?.chainLatencySamples == 0)
        #expect(report.strips[dry.id]?.compensationSamples == Self.limiterLatency)
    }

    @Test("bypass toggle retargets ONLY the toggled strip; totals are bypass-stable")
    func bypassRetargetsOnlyToggledStrip() throws {
        let (_, graph) = try makeManualEngine()
        let dry = Track(name: "Dry", kind: .audio)
        var latent = Track(name: "Limited", kind: .audio, effects: [limiterFX()])
        graph.reconcile(tracks: [dry, latent])
        graph.applyParameters(tracks: [dry, latent])
        try #require(try target(graph, dry.id) == Self.limiterLatency)

        // Bypass: chainLatencyAll keeps the 240 (stable totals — spec §1),
        // so T and the dry strip never move; the toggled strip's ring absorbs
        // the now-absent real delay (active sum 0 → comp 240).
        latent.effects[0].isBypassed = true
        graph.applyParameters(tracks: [dry, latent])
        #expect(try target(graph, dry.id) == Self.limiterLatency)     // unmoved
        #expect(try target(graph, latent.id) == Self.limiterLatency)  // absorbs
        let bypassed = try #require(graph.pdcReport)
        #expect(bypassed.maxPathLatencySamples == Self.limiterLatency)
        #expect(bypassed.strips[latent.id]?.chainLatencySamples == Self.limiterLatency)

        // Un-bypass: back to the original plan, again only this strip moves.
        latent.effects[0].isBypassed = false
        graph.applyParameters(tracks: [dry, latent])
        #expect(try target(graph, dry.id) == Self.limiterLatency)
        #expect(try target(graph, latent.id) == 0)
    }

    @Test("effect removal DOES move the maxima and retargets other strips")
    func removalRetargetsOtherStrips() throws {
        let (_, graph) = try makeManualEngine()
        let dry = Track(name: "Dry", kind: .audio)
        var latent = Track(name: "Limited", kind: .audio, effects: [limiterFX()])
        graph.reconcile(tracks: [dry, latent])
        graph.applyParameters(tracks: [dry, latent])
        try #require(try target(graph, dry.id) == Self.limiterLatency)

        latent.effects = []
        graph.reconcile(tracks: [dry, latent])
        graph.applyParameters(tracks: [dry, latent])
        #expect(try target(graph, dry.id) == 0)
        #expect(try target(graph, latent.id) == 0)
        let report = try #require(graph.pdcReport)
        #expect(report.maxPathLatencySamples == 0)
        #expect(report.strips[latent.id]?.chainLatencySamples == 0)
    }

    // MARK: - Strip-kind coverage

    @Test("instrument strips participate: their renderer ring gets the plan target")
    func instrumentStripsIncluded() throws {
        let (_, graph) = try makeManualEngine()
        let keys = Track(name: "Keys", kind: .instrument)
        let latent = Track(name: "Limited", kind: .audio, effects: [limiterFX()])
        graph.reconcile(tracks: [keys, latent])
        graph.applyParameters(tracks: [keys, latent])

        // The instrument strip is a dry direct-to-master track: pads to T+B.
        #expect(try target(graph, keys.id) == Self.limiterLatency)
        // And a latent instrument chain feeds the maxima like any track.
        var latentKeys = keys
        latentKeys.effects = [limiterFX()]
        var dryAudio = latent
        dryAudio.effects = []
        graph.reconcile(tracks: [latentKeys, dryAudio])
        graph.applyParameters(tracks: [latentKeys, dryAudio])
        #expect(try target(graph, latentKeys.id) == 0)
        #expect(try target(graph, dryAudio.id) == Self.limiterLatency)
    }

    @Test("bus strips: stage split T+B, send-track pads to T, bus return to B")
    func busStageSplitAndSends() throws {
        let (_, graph) = try makeManualEngine()
        let busID = UUID()
        let bus = Track(id: busID, name: "FX Bus", kind: .bus, effects: [limiterFX()])
        // Routed INTO the bus (not direct) — pads to T only; the bus adds B.
        let routed = Track(name: "Routed", kind: .audio, outputBusID: busID)
        // Latent track with a send into the bus.
        let latent = Track(name: "Limited", kind: .audio,
                           sends: [Send(destinationBusID: busID)],
                           effects: [limiterFX()])
        graph.reconcile(tracks: [bus, routed, latent])
        graph.applyParameters(tracks: [bus, routed, latent])

        // T = 240 (latent track), B = 240 (bus limiter).
        #expect(try target(graph, routed.id) == Self.limiterLatency)  // T − 0
        #expect(try target(graph, latent.id) == 0)                     // T − 240
        #expect(try target(graph, busID) == 0)                         // B − 240
        let report = try #require(graph.pdcReport)
        #expect(report.trackStageSamples == Self.limiterLatency)
        #expect(report.busStageSamples == Self.limiterLatency)
        #expect(report.maxPathLatencySamples == 2 * Self.limiterLatency)
        // Direct-to-master WITH a send while B > 0 — the documented §2 skew.
        #expect(report.strips[latent.id]?.skewSamples == Self.limiterLatency)
        #expect(report.strips[routed.id]?.skewSamples == 0)
    }

    @Test("master is excluded by construction: report strips are exactly the track+bus set, output = maxPath")
    func masterExcludedFromPlan() throws {
        let (_, graph) = try makeManualEngine()
        let busID = UUID()
        let tracks = [
            Track(name: "A", kind: .audio, effects: [limiterFX()]),
            Track(name: "Keys", kind: .instrument),
            Track(id: busID, name: "Bus", kind: .bus),
        ]
        graph.reconcile(tracks: tracks)
        graph.applyParameters(tracks: tracks)
        let report = try #require(graph.pdcReport)
        // No phantom master strip in the plan input or the report…
        #expect(Set(report.strips.keys) == Set(tracks.map(\.id)))
        // …and with no master chain today, ruler-to-speaker == maxPath.
        #expect(report.outputLatencySamples == report.maxPathLatencySamples)
    }

    // MARK: - ProjectStore → AudioEngine integration

    @Test("store edits drive the live engine's plan: fx.add / bypass / remove read back via pdcReport")
    func projectStoreEditsDriveEngineRecompute() throws {
        let engine = AudioEngine()  // never prepared — no hardware started
        let store = ProjectStore()
        store.engine = engine

        let dry = store.addTrack(name: "Dry", kind: .audio)
        let fxTrack = store.addTrack(name: "Limited", kind: .audio)
        let effect = try store.addEffect(toTrack: fxTrack.id, kind: .limiter)

        // Rate-agnostic: whatever rate the live graph prepared the limiter
        // at, the dry strip must pad to exactly that latency.
        let latency = store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id)
        #expect(latency > 0)
        var report = try #require(store.pdcReport())
        #expect(report.maxPathLatencySamples == latency)
        #expect(report.strips[dry.id]?.compensationSamples == latency)
        #expect(report.strips[fxTrack.id]?.compensationSamples == 0)
        #expect(report.strips[fxTrack.id]?.chainLatencySamples == latency)

        // Bypass: totals stable, only the toggled strip retargets.
        try store.setEffectBypassed(trackID: fxTrack.id, effectID: effect.id, bypassed: true)
        report = try #require(store.pdcReport())
        #expect(report.maxPathLatencySamples == latency)
        #expect(report.strips[dry.id]?.compensationSamples == latency)
        #expect(report.strips[fxTrack.id]?.compensationSamples == latency)
        #expect(report.strips[fxTrack.id]?.chainLatencySamples == latency)

        // Removal: totals drop, every strip returns to zero.
        try store.removeEffect(trackID: fxTrack.id, effectID: effect.id)
        report = try #require(store.pdcReport())
        #expect(report.maxPathLatencySamples == 0)
        #expect(report.strips[dry.id]?.compensationSamples == 0)
        #expect(report.strips[fxTrack.id]?.compensationSamples == 0)
    }

    // MARK: - m39-ad: a PARAMETER that moves a latency

    /// ⛔⛔ **THE HARDEST CORRECTNESS QUESTION IN m39-ad, ASKED OF THE LIVE
    /// ENGINE RATHER THAN OF THE EFFECT.**
    ///
    /// Every other built-in's `latencySamples` is a constant, or a function of
    /// the sample rate, and `.clipper` went out of its way to KEEP it constant
    /// across its `oversampling` parameter precisely because "param edits never
    /// republish the chain" (`EffectRendering`) — a latency that moved with a
    /// knob would silently stale the PDC plan with every unit test still green.
    ///
    /// `.saturator` cannot take that way out: it is a SHIPPED kind, and
    /// reporting 32 samples at its default would shift every saved project. So
    /// it reports 0 at factor 1 and 32 at 2/4, and the staleness is closed
    /// differently — the factor moves ONLY on a main-actor `apply(params:)`,
    /// which always runs inside `PlaybackGraph.applyParameters`, whose TAIL
    /// calls `recomputeCompensation`.
    ///
    /// ⭐ THIS TEST IS THE PROOF OF THAT CLAIM, AND IT IS NOT AN ARGUMENT ABOUT
    /// THE CODE: it drives the REAL `ProjectStore → AudioEngine` path with a
    /// plain `fx.setParam` and reads the PLAN back. If the recompute ever stops
    /// happening on a parameter edit, the plan stops moving here and this
    /// reddens — while `SaturatorOversamplingTests` stays entirely green,
    /// because nothing in the effect itself would be wrong.
    @Test("m39-ad: a saturator's oversampling edit moves the LIVE PDC plan, in the same pass")
    func saturatorOversamplingEditDrivesTheEngineRecompute() throws {
        let engine = AudioEngine()  // never prepared — no hardware started
        let store = ProjectStore()
        store.engine = engine

        let dry = store.addTrack(name: "Dry", kind: .audio)
        let fxTrack = store.addTrack(name: "Saturated", kind: .audio)
        let effect = try store.addEffect(toTrack: fxTrack.id, kind: .saturator)

        // ── the DEFAULT costs nothing, which is the whole of m39-ad ──────────
        #expect(store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id) == 0,
                Comment(rawValue: "a freshly added saturator reports "
                    + "\(store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id)) "
                    + "samples — at the default it must report 0, or every existing project "
                    + "containing one shifts in time"))
        var report = try #require(store.pdcReport())
        #expect(report.maxPathLatencySamples == 0)
        #expect(report.strips[dry.id]?.compensationSamples == 0)

        // ── turn the knob to 4: the PLAN must move, not just the effect ──────
        _ = try store.setEffectParam(trackID: fxTrack.id, effectID: effect.id,
                                     name: "oversampling", value: 4)
        let oversampled = store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id)
        #expect(oversampled == OversamplerDesign.latencySamples, Comment(rawValue:
            "the effect reports \(oversampled) samples at oversampling 4, expected "
            + "\(OversamplerDesign.latencySamples)"))
        report = try #require(store.pdcReport())
        #expect(report.strips[fxTrack.id]?.chainLatencySamples == oversampled, Comment(rawValue:
            "the CHAIN still reports "
            + "\(report.strips[fxTrack.id]?.chainLatencySamples ?? -1) — `EffectChainState"
            + ".latencySamples` did not see the new value in the pass that published it"))
        #expect(report.maxPathLatencySamples == oversampled, Comment(rawValue:
            "the PDC PLAN still reports \(report.maxPathLatencySamples). The latency moved and "
            + "the plan did not: every other strip is now 32 samples out of alignment and "
            + "nothing else in this tree can see it."))
        #expect(report.strips[dry.id]?.compensationSamples == oversampled, Comment(rawValue:
            "the dry strip did not pad to the saturated strip's new latency"))

        // ── and back to 1: it must UN-move, not latch ────────────────────────
        _ = try store.setEffectParam(trackID: fxTrack.id, effectID: effect.id,
                                     name: "oversampling", value: 1)
        #expect(store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id) == 0)
        report = try #require(store.pdcReport())
        #expect(report.maxPathLatencySamples == 0, Comment(rawValue:
            "the plan latched at \(report.maxPathLatencySamples) after the factor went back "
            + "to 1 — a one-way latency is as stale as a stuck one"))
        #expect(report.strips[dry.id]?.compensationSamples == 0)

        // ── 2 costs the same 32 as 4: it is the FILTER's delay, not the ──────
        //    factor's, so only "1 versus not-1" moves the number.
        _ = try store.setEffectParam(trackID: fxTrack.id, effectID: effect.id,
                                     name: "oversampling", value: 2)
        #expect(store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id)
                == OversamplerDesign.latencySamples)
    }

    /// ⭐ THE INVARIANCE CONTROL FOR THE TEST ABOVE. `.clipper` has an
    /// IDENTICALLY NAMED parameter on the SAME primitive, and its latency must
    /// NOT move with it — a constant 32 at every factor, including 1. If a
    /// future edit "harmonises" the two kinds, one of them becomes a regression:
    /// the clipper's factor is AUTOMATABLE, so a moving latency there really
    /// would stale the plan from the render thread.
    @Test("m39-ad control: the CLIPPER's oversampling edit does NOT move any latency")
    func clipperOversamplingEditLeavesTheLatencyAlone() throws {
        let engine = AudioEngine()
        let store = ProjectStore()
        store.engine = engine

        let fxTrack = store.addTrack(name: "Clipped", kind: .audio)
        let effect = try store.addEffect(toTrack: fxTrack.id, kind: .clipper)
        let atDefault = store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id)
        #expect(atDefault == OversamplerDesign.latencySamples)
        for factor in [1.0, 2.0, 4.0] {
            _ = try store.setEffectParam(trackID: fxTrack.id, effectID: effect.id,
                                         name: "oversampling", value: factor)
            #expect(store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id)
                    == atDefault, Comment(rawValue:
                        "the clipper's latency moved to "
                        + "\(store.effectLatencySamples(trackID: fxTrack.id, effectID: effect.id)) "
                        + "at factor \(factor) — it must be constant, because that kind's "
                        + "factor can be moved from an automation lane"))
        }
    }
}
