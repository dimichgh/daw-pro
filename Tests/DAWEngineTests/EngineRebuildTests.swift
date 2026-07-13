import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m13-a engine-discard regression guard (supersedes `TeardownRetireTests`,
/// the M9 retire-bin pins — docs/research/design-m13a-teardown-crash.md).
///
/// The live crash class (six identical `.ips` on 2026-07-12, two binaries:
/// announce-class teardown → quiesce-stop → park → restart → flush-detach →
/// `AVAudioEngineGraph::UpdateGraphAfterReconfig` KERN_INVALID_ADDRESS)
/// needs real HAL I/O plus heap reuse, so it is not reachable headless; C0's
/// instrumented repro pinned the mechanism (the FIRST post-restart detach of
/// the routed strip mixer faults — nodes that rendered and then sat attached
/// across a stop→start boundary are already stale in AVFoundation's node
/// vector). These tests pin the invariant that closes the class BY
/// CONSTRUCTION: a once-rendered engine is never surgically detached —
/// announce-class passes abort into `needsEngineRebuild` (before the first
/// topology mutation), stopped-after-run teardowns leave nodes attached and
/// flag the rebuild, and `AudioEngine.tracksDidChange` replaces the WHOLE
/// engine + graph. Never-run graphs (offline renders, headless tests) keep
/// detaching immediately — the cold build order, byte-identical to always.
@MainActor
@Suite("Engine rebuild — m13-a teardown discipline", .serialized)
struct EngineRebuildTests {
    private static let dls = AudioUnitComponentID(subType: "dls ", manufacturer: "appl")

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

    /// One routed source strip + two buses — the deterministic C0 crash
    /// recipe (a SINGLE source track, so the teardown pass meets the
    /// announce-worthy strip first, whatever the dictionary order).
    private func routedSession(busA: UUID = UUID(), busB: UUID = UUID()) -> [Track] {
        [
            Track(name: "Src", kind: .audio, outputBusID: busA,
                  sends: [Send(destinationBusID: busB, level: 0.4)]),
            Track(id: busA, name: "Bus A", kind: .bus),
            Track(id: busB, name: "Bus B", kind: .bus),
        ]
    }

    /// Renders one quantum so every node has genuinely rendered before the
    /// teardown under test (the "once-rendered" precondition of the poison).
    private func renderOneBlock(_ engine: AVAudioEngine) throws {
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: engine.manualRenderingFormat, frameCapacity: 4_096))
        let status = try engine.renderOffline(1_024, to: buffer)
        try #require(status == .success)
    }

    @Test("announce-class teardown on a once-rendered engine ABORTS before any topology mutation and flags the rebuild")
    func announceAbortsOnceRenderedEngine() throws {
        let (engine, graph) = try makeManualEngine()
        var announces = 0
        graph.willMutateRoutingTopology = { announces += 1 }
        #expect(graph.reconcile(tracks: routedSession()))
        let announcesAfterBuild = announces  // the fresh non-trivial wiring announced (never-run: pass proceeded)
        try engine.start()
        graph.engineHasRun = true  // exactly what AudioEngine.prepare() sets
        try renderOneBlock(engine)

        let attachedBefore = engine.attachedNodes.count
        #expect(graph.reconcile(tracks: []))  // announce-class: routed strip teardown

        #expect(graph.needsEngineRebuild)
        #expect(announces == announcesAfterBuild + 1)  // hook still fired (quiescence)
        // The abort landed BEFORE the first topology mutation: nothing was
        // detached, and the node tree is intact — the graph is discarded
        // wholesale by the engine owner, never picked apart.
        #expect(engine.attachedNodes.count == attachedBefore)
        #expect(graph.trackIDs.count == 3)
        engine.stop()
    }

    @Test("plain teardown while STOPPED after running detaches nothing, flags the rebuild, nodes stay attached")
    func stoppedAfterRunPlainTeardownFlagsRebuild() throws {
        let (engine, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: [Track(name: "A", kind: .audio)]))
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)
        engine.stop()  // stopped AFTER having run — the poison precondition

        let attachedBefore = engine.attachedNodes.count
        #expect(graph.reconcile(tracks: []))

        // No surgical detach happened (the stale-entry window cannot open):
        // the nodes stay attached — alive in the engine's own strong set —
        // and the graph asks for the whole-engine rebuild instead.
        #expect(graph.needsEngineRebuild)
        #expect(engine.attachedNodes.count == attachedBefore)
        #expect(graph.trackIDs.isEmpty)  // bookkeeping completed (non-announce pass runs through)
    }

    @Test("never-run graphs detach immediately while stopped (offline/test build order unchanged)")
    func neverRunGraphDetachesImmediately() throws {
        let (engine, graph) = try makeManualEngine()
        // m13-d: the PERMANENT master chain insert forms on the first
        // reconcile and never detaches — baseline after it exists, so this
        // pin keeps measuring exactly the strip teardown discipline.
        graph.ensureMasterSandwich()
        let baseline = engine.attachedNodes.count
        #expect(graph.reconcile(tracks: routedSession()))
        graph.reconcile(tracks: [])  // engine never started, engineHasRun false

        #expect(!graph.needsEngineRebuild)
        #expect(engine.attachedNodes.count == baseline)
    }

    @Test("trivial-strip teardown against a RUNNING engine detaches immediately (the live-proven boundary-free path)")
    func runningTrivialTeardownDetachesImmediately() throws {
        let (engine, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: [Track(name: "A", kind: .audio)]))
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)

        let attachedBefore = engine.attachedNodes.count
        graph.reconcile(tracks: [])  // engine still running, never stop→started

        #expect(!graph.needsEngineRebuild)
        // The strip sandwich (sumMixer + chainHost + mixer) detached live.
        #expect(engine.attachedNodes.count == attachedBefore - 3)
        engine.stop()
    }

    @Test("a rebuild-flagged graph REFUSES further mutation (the doomed engine is never touched again)")
    func rebuildFlaggedGraphRefusesMutation() throws {
        let (engine, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: [Track(name: "A", kind: .audio)]))
        let attachedBefore = engine.attachedNodes.count
        let signatureBefore = graph.signature

        graph.needsEngineRebuild = true
        #expect(graph.reconcile(tracks: []))  // reports "changed", mutates nothing

        #expect(engine.attachedNodes.count == attachedBefore)
        #expect(graph.signature == signatureBefore)
        #expect(graph.trackIDs.count == 1)
    }

    @Test("projectWillReplace: no-op before the engine ever ran; unconditional rebuild flag once rendered (A1)")
    func projectWillReplaceGating() {
        let engine = AudioEngine()
        engine.tracksDidChange([Track(name: "A", kind: .audio)])

        engine.projectWillReplace()
        #expect(!engine.graph.needsEngineRebuild)  // never-ran: nothing to protect

        engine.graph.engineHasRun = true  // exactly what prepare() sets
        engine.projectWillReplace()
        #expect(engine.graph.needsEngineRebuild)   // A1: unconditional once rendered
    }

    @Test("rebuild preserves registry instruments by identity, chain latency from descriptors, and recomputes PDC")
    func rebuildPreservesChainsInstrumentsAndPDC() async throws {
        let engine = AudioEngine()
        // Prepare the hosted instrument at the SAME rate the engine's graph
        // will use, so the sync pass never re-prepares (identity must be
        // attributable to the rebuild alone). The scratch engine must be a
        // NAMED binding: an inline temporary deallocates while the IO node
        // (weak engine back-ref) is still answering the format query —
        // measured SIGSEGV in AVAudioIONodeImpl::GetOutputFormat.
        let scratch = AVAudioEngine()
        let scratchRate = scratch.outputNode.outputFormat(forBus: 0).sampleRate
        withExtendedLifetime(scratch) {}
        let graphRate = scratchRate > 0 ? scratchRate : 48_000
        let busID = UUID()
        let keys = Track(name: "Keys", kind: .instrument,
                         instrument: InstrumentDescriptor(
                             kind: .audioUnit,
                             audioUnit: AudioUnitConfig(component: Self.dls)))
        let limited = Track(name: "Lim", kind: .audio,
                            sends: [Send(destinationBusID: busID, level: 0.4)],
                            effects: [EffectDescriptor(kind: .limiter)])
        let plain = Track(name: "Plain", kind: .audio)
        let bus = Track(id: busID, name: "FX", kind: .bus)
        await engine.auRegistry.prepare(track: keys, sampleRate: graphRate)
        let instrumentBefore = try #require(engine.hostedInstrumentAudioUnit(forTrack: keys.id))

        engine.tracksDidChange([keys, limited, plain, bus])
        let graphBefore = ObjectIdentifier(engine.graph)
        #expect(engine.insertChainLatencySamples(forTrack: limited.id) == 240)

        // The "once-rendered" precondition without hardware — exactly what a
        // successful prepare() sets. The announce-class rewire below then
        // routes tracksDidChange through rebuildEngine. (Inside the rebuild
        // the fresh engine may or may not start — no output device on CI —
        // and every assertion below is valid either way: a failed start
        // leaves a clean NEVER-RUN graph by design.)
        engine.graph.engineHasRun = true
        var rewired = limited
        rewired.sends = []  // routing-key change = announce-class
        engine.tracksDidChange([keys, rewired, plain, bus])

        // The ENGINE was replaced, not surgically mutated.
        #expect(ObjectIdentifier(engine.graph) != graphBefore)
        #expect(!engine.graph.needsEngineRebuild)  // the fresh graph carries no debt
        // Chain state rebuilt from descriptors on the fresh graph: the
        // limiter's lookahead latency is reproduced exactly.
        #expect(engine.insertChainLatencySamples(forTrack: limited.id) == 240)
        // PDC recomputed against the rebuilt strips: the limiter strip
        // reports its chain, the plain strip pads to the track stage.
        let report = try #require(engine.pdcReport())
        #expect(report.trackStageSamples == 240)
        #expect(report.strips[limited.id]?.chainLatencySamples == 240)
        #expect(report.strips[plain.id]?.compensationSamples == 240)
        // Instrument descriptors preserved in the rebuilt signature...
        #expect(engine.graph.instrumentSignature[keys.id]?.audioUnitComponent == Self.dls)
        // ...and the REGISTRY instance survived engine replacement by
        // IDENTITY — hosted-AU state is ours, never an engine citizen.
        #expect(engine.hostedInstrumentAudioUnit(forTrack: keys.id) === instrumentBefore)
        engine.shutdown()
    }
}
