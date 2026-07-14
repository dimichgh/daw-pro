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

    // MARK: - m16-h: the deep post-start reconfig defect
    // (docs/research/design-m16h-reconfig.md — C7 pins a–d.)
    // A strip sandwich born on a RUNNING engine hosts permanently
    // unstartable players (AVFAudio's running-engine reconfig does not
    // propagate player-start eligibility across a ≥2-deep post-start
    // subtree). Leg 2: strip birth on a running once-rendered engine is
    // announce-class. Leg 1: `rebuildEngine` defers `engine.start()` unless
    // a resume is pending or an armed instrument needs live-thru.

    /// 1 s of low-amplitude DC as a stereo Float32 WAV in a fresh temp dir
    /// (the ExceptionArmorTests fixture, verbatim).
    private func wavFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m16h-\(UUID().uuidString)")
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

    @Test("m16-h C7a: AUDIO strip birth on a running once-rendered engine announces and aborts BEFORE any node of the sandwich attaches")
    func audioStripBirthOnRunningOnceRenderedEngineAborts() throws {
        let (engine, graph) = try makeManualEngine()
        var announces = 0
        graph.willMutateRoutingTopology = { announces += 1 }
        let keeper = Track(name: "A", kind: .audio)
        #expect(graph.reconcile(tracks: [keeper]))
        try engine.start()
        graph.engineHasRun = true  // exactly what AudioEngine.prepare() sets
        try renderOneBlock(engine)

        let attachedBefore = engine.attachedNodes.count
        #expect(graph.reconcile(tracks: [keeper, Track(name: "B", kind: .audio)]))

        #expect(graph.needsEngineRebuild)
        #expect(announces == 1)  // the birth announced (quiescence hook fired)
        // Announce-before-attach: not one node of the new sandwich exists on
        // the doomed engine — it is discarded wholesale and the fresh
        // engine cold-builds the strip start-era.
        #expect(engine.attachedNodes.count == attachedBefore)
        #expect(graph.trackIDs.count == 1)
        engine.stop()
    }

    @Test("m16-h C7a: BUS strip birth on a running once-rendered engine announces and aborts before any attach")
    func busBirthOnRunningOnceRenderedEngineAborts() throws {
        let (engine, graph) = try makeManualEngine()
        var announces = 0
        graph.willMutateRoutingTopology = { announces += 1 }
        let keeper = Track(name: "A", kind: .audio)
        #expect(graph.reconcile(tracks: [keeper]))
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)

        let attachedBefore = engine.attachedNodes.count
        #expect(graph.reconcile(tracks: [keeper, Track(name: "FX", kind: .bus)]))

        #expect(graph.needsEngineRebuild)
        #expect(announces == 1)
        #expect(engine.attachedNodes.count == attachedBefore)
        #expect(graph.trackIDs.count == 1)
        engine.stop()
    }

    @Test("m16-h C7b: never-run engine strip birth attaches directly (the cold build order, unchanged)")
    func neverRunEngineStripBirthAttachesDirectly() throws {
        let (engine, graph) = try makeManualEngine()
        var announces = 0
        graph.willMutateRoutingTopology = { announces += 1 }
        #expect(graph.reconcile(tracks: [Track(name: "A", kind: .audio)]))
        let attachedAfterFirst = engine.attachedNodes.count
        #expect(graph.reconcile(tracks: [Track(name: "A", kind: .audio),
                                         Track(name: "B", kind: .audio)]))

        #expect(!graph.needsEngineRebuild)
        #expect(announces == 0)  // trivial cold attaches never announce
        // The second strip sandwich (sumMixer + chainHost + mixer) attached.
        #expect(engine.attachedNodes.count == attachedAfterFirst + 3)
        #expect(graph.trackIDs.count == 2)
    }

    @Test("m16-h C7d: a clip added to an EXISTING (start-era) strip while running flags NO rebuild and never announces")
    func clipOntoExistingStripWhileRunningFlagsNoRebuild() throws {
        let (engine, graph) = try makeManualEngine()
        var announces = 0
        graph.willMutateRoutingTopology = { announces += 1 }
        let trackID = UUID()
        #expect(graph.reconcile(tracks: [Track(id: trackID, name: "A", kind: .audio)]))
        try engine.start()
        graph.engineHasRun = true
        try renderOneBlock(engine)

        let attachedBefore = engine.attachedNodes.count
        let clip = Clip(name: "c", startBeat: 0, lengthBeats: 2,
                        audioFileURL: try wavFixture())
        // Signature changed (caller restarts players) but the daily
        // import-onto-existing-track flow stays zero-cost: a depth-1 player
        // attach onto a start-era strip is clean (design-m16h §2-E9).
        #expect(graph.reconcile(tracks: [
            Track(id: trackID, name: "A", kind: .audio, clips: [clip]),
        ]))
        #expect(!graph.needsEngineRebuild)
        #expect(announces == 0)
        #expect(engine.attachedNodes.count == attachedBefore + 1)  // the player
        engine.stop()
    }

    @Test("m16-h C7c: a project-boundary rebuild with no resume and no armed instrument leaves the engine STOPPED and NEVER-RUN; later strip birth attaches cold, once per storm")
    func deferredRebuildLeavesEngineStoppedAndNeverRun() {
        let engine = AudioEngine()
        engine.tracksDidChange([Track(name: "A", kind: .audio)])
        engine.graph.engineHasRun = true  // exactly what prepare() sets
        let graphBefore = ObjectIdentifier(engine.graph)

        engine.projectWillReplace()
        engine.tracksDidChange([Track(name: "B", kind: .audio)])

        // The engine was replaced (A1) but Leg 1 DEFERRED the start: the
        // fresh engine is stopped and never-run — the fresh-launch cold
        // regime — so everything added next attaches before the first start.
        #expect(ObjectIdentifier(engine.graph) != graphBefore)
        #expect(!engine.isRunning)
        #expect(!engine.graph.engineHasRun)
        #expect(!engine.graph.needsEngineRebuild)

        // A post-boundary storm costs NOTHING further: more strips attach
        // directly to the same never-run engine (no announce, no rebuild).
        let graphAfterBoundary = ObjectIdentifier(engine.graph)
        engine.tracksDidChange([Track(name: "B", kind: .audio),
                                Track(name: "C", kind: .audio),
                                Track(name: "D", kind: .bus)])
        #expect(ObjectIdentifier(engine.graph) == graphAfterBoundary)
        #expect(!engine.isRunning)
        #expect(!engine.graph.engineHasRun)
        #expect(!engine.graph.needsEngineRebuild)
        #expect(engine.graph.trackIDs.count == 3)
        engine.shutdown()
    }

    @Test("m16-h C7c: a rebuild with an ARMED instrument track starts the engine (live-thru must keep sounding)")
    func rebuildWithArmedInstrumentStartsEngine() throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            // Headless machine without an output device — the deferred-start
            // half is pinned above; the live half runs where hardware exists
            // (the liveSmoke idiom).
            return
        }
        let armed = Track(name: "Keys", kind: .instrument, isArmed: true,
                          instrument: InstrumentDescriptor(kind: .testTone))
        engine.projectWillReplace()  // prepare() set engineHasRun — A1 fires
        engine.tracksDidChange([armed])

        #expect(engine.isRunning)
        #expect(engine.graph.engineHasRun)
        #expect(!engine.graph.needsEngineRebuild)
        engine.shutdown()
    }

    @Test("m16-h C7c + Leg 2 live: mid-play strip birth rebuilds, RESUMES playback, and the engine runs")
    func midPlayStripBirthRebuildsAndResumes() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return  // headless machine — liveSmoke idiom
        }
        let keys = Track(name: "Keys", kind: .instrument,
                         clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 64, notes: [
                             MIDINote(pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 64),
                         ])],
                         instrument: InstrumentDescriptor(kind: .testTone))
        engine.tracksDidChange([keys])
        var pushes: [Double] = []
        engine.playheadHandler = { pushes.append($0) }
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        try await Task.sleep(for: .milliseconds(250))
        let graphBefore = ObjectIdentifier(engine.graph)

        // track.add during playback: Leg 2 announces the strip birth, the
        // hook winds playback down capturing resume state, rebuildEngine
        // cold-builds WITH the new strip and Leg 1's resume condition
        // starts + resumes — the m13-a send-add interruption class.
        engine.tracksDidChange([keys, Track(name: "Gtr", kind: .audio)])

        #expect(ObjectIdentifier(engine.graph) != graphBefore)  // rebuilt
        #expect(engine.isRunning)
        #expect(engine.graph.engineHasRun)
        #expect(!engine.graph.needsEngineRebuild)

        // Playback resumed: the playhead keeps advancing monotonically.
        let pushesAtRebuild = pushes.count
        let lastBeat = pushes.last ?? 0
        try await Task.sleep(for: .milliseconds(300))
        #expect(pushes.count > pushesAtRebuild)
        #expect((pushes.last ?? 0) >= lastBeat)

        engine.stopPlayback()
        engine.shutdown()
    }
}
