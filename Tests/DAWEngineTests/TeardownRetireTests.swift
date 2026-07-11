import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M9 crash-a regression guard — deterministic ORDERING PIN, not a crash
/// repro. The live crash (played routed session → `project.new` →
/// `track.add` → use-after-free inside
/// `AVAudioEngineGraph::UpdateGraphAfterReconfig`) needs real HAL I/O plus
/// heap reuse, so it is not reachable headless; the proven mechanism
/// (docs/research/fix-teardown-crash.md) is that detaching a once-rendered
/// node while the engine is STOPPED leaves a stale raw node pointer in
/// AVFoundation's internal graph list, which the next running `connect`
/// walks. These tests pin the invariant that closes that window: teardown
/// detaches against a stopped-after-running engine are DEFERRED (node stays
/// attached and strongly held — no freed-memory window), and retire only
/// against a running engine; never-run graphs (offline renders, headless
/// tests) keep detaching immediately. A revert of `retireNode`/
/// `flushRetiredNodes` fails these assertions immediately.
@MainActor
@Suite("Teardown node retirement — M9 crash-a", .serialized)
struct TeardownRetireTests {
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

    /// The crash-shape session in miniature: two synth strips (one routed
    /// through a send) + one bus — covers source nodes, strip mixers, send
    /// gains and the bus sandwich in a single teardown.
    private func routedSession() -> [Track] {
        let busID = UUID()
        return [
            Track(name: "Synth A", kind: .instrument),
            Track(name: "Synth B", kind: .instrument,
                  sends: [Send(destinationBusID: busID, level: 0.4)]),
            Track(id: busID, name: "FX Bus", kind: .bus),
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

    @Test("stopped-after-running teardown defers every detach into the bin (the poison window stays closed)")
    func stoppedTeardownDefersDetaches() throws {
        let (engine, graph) = try makeManualEngine()
        let tracks = routedSession()
        #expect(graph.reconcile(tracks: tracks))
        try engine.start()
        graph.engineHasRun = true  // exactly what AudioEngine.prepare() sets
        try renderOneBlock(engine)
        engine.stop()  // the live quiesce-stop: stopped AFTER having run

        let attachedBefore = engine.attachedNodes
        graph.reconcile(tracks: [])

        // Every removed node was parked, none detached: the bin holds
        // 2×(source+mixer) + 1 send gain + bus (sumMixer+chainHost+mixer) = 8.
        #expect(graph.pendingDetachNodes.count == 8)
        #expect(graph.trackIDs.isEmpty)  // bookkeeping already clean
        // The parked nodes are all still attached (alive in AVFoundation's
        // graph — a freed-while-referenced window cannot exist)...
        #expect(engine.attachedNodes.isSuperset(of: Set(graph.pendingDetachNodes)))
        #expect(engine.attachedNodes.count == attachedBefore.count)

        // ...and a flush attempt while still stopped keeps holding them.
        graph.flushRetiredNodes()
        #expect(graph.pendingDetachNodes.count == 8)

        // Engine back up (the post-reconcile bounce): the flush retires all
        // of them against the RUNNING engine — the AVFoundation state in
        // which detach bookkeeping is proven clean.
        try engine.start()
        let parked = Set(graph.pendingDetachNodes)
        graph.flushRetiredNodes()
        #expect(graph.pendingDetachNodes.isEmpty)
        #expect(engine.attachedNodes.intersection(parked).isEmpty)
        engine.stop()
    }

    @Test("teardown against a running engine detaches immediately (the live-proven path is unchanged)")
    func runningTeardownDetachesImmediately() throws {
        let (engine, graph) = try makeManualEngine()
        let tracks = routedSession()
        #expect(graph.reconcile(tracks: tracks))
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)

        let attachedBefore = engine.attachedNodes
        graph.reconcile(tracks: [])  // engine still running

        #expect(graph.pendingDetachNodes.isEmpty)
        #expect(engine.attachedNodes.count == attachedBefore.count - 8)
        engine.stop()
    }

    @Test("never-run graphs detach immediately while stopped (offline/test build order unchanged)")
    func neverRunGraphDetachesImmediately() throws {
        let (engine, graph) = try makeManualEngine()
        let baseline = engine.attachedNodes.count
        #expect(graph.reconcile(tracks: routedSession()))
        graph.reconcile(tracks: [])  // engine never started, engineHasRun false

        #expect(graph.pendingDetachNodes.isEmpty)
        #expect(engine.attachedNodes.count == baseline)
    }

    @Test("reconcile flushes a leftover bin once the engine is running again")
    func reconcileEntryFlushesBin() throws {
        let (engine, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: routedSession()))
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)
        engine.stop()

        graph.reconcile(tracks: [])
        #expect(graph.pendingDetachNodes.count == 8)
        let parked = Set(graph.pendingDetachNodes)

        // The engine restarts through a path that forgot the explicit flush
        // (defensive seam): the next reconcile drains the bin before it
        // mutates any wiring.
        try engine.start()
        graph.reconcile(tracks: [Track(name: "Fresh", kind: .instrument)])
        #expect(graph.pendingDetachNodes.isEmpty)
        #expect(engine.attachedNodes.intersection(parked).isEmpty)
        engine.stop()
    }
}
