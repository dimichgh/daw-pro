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
        // attributable to the rebuild alone). m20-d: that rate is
        // `AudioEngine.projectSampleRate`, NOT the output device's — reading
        // the device here (what this test did before m20-d, via a scratch
        // AVAudioEngine's output format) would prepare at 44 100 on a 44.1 kHz
        // interface while the graph ran at 48 000, the sync pass would
        // re-prepare, and the very invariant this test isolates would break.
        // It passed on this machine only because the device happens to be at
        // 48 kHz — a pass for a reason unrelated to correctness. (That the
        // LIVE graph really adopts this constant is pinned once, in
        // ProjectRateGraphTests.liveGraphRunsAtProjectRate; asserting it again
        // HERE against the same symbol would be `x == x`.)
        let graphRate = AudioEngine.projectSampleRate
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
        // m20-d: the m19-j sensitivity class is dead (design §2.3 A4). The
        // LIVE graph prepares the limiter at `AudioEngine.projectSampleRate`,
        // so the 5 ms lookahead is 240 samples on EVERY device — a 24 kHz
        // Bluetooth headset no longer drags it to 120. The derivation is kept
        // deliberately: it is now constant-valued by construction, which makes
        // it an INVARIANCE pin (it reddens if the live graph ever goes back to
        // following the device) rather than the device-tracking expectation it
        // used to be.
        //
        // m23-ar: routed through the ONE HOME instead of re-typing the formula.
        // The `insertChainLatencySamples == lookahead` cross-checks below are
        // therefore now both-sides-from-`lookaheadSamples` and pin the PDC
        // PLUMBING, not the derivation. ⚠️ `== 240` MUST STAY A LITERAL — it is
        // the only independent oracle left here.
        let lookahead = LimiterParams.lookaheadSamples(
            sampleRate: engine.graph.graphSampleRateForTesting)
        #expect(lookahead == 240)  // pre-m20-d on a 44.1 kHz device this read 221
        #expect(engine.insertChainLatencySamples(forTrack: limited.id) == lookahead)

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
        #expect(engine.insertChainLatencySamples(forTrack: limited.id) == lookahead)
        // PDC recomputed against the rebuilt strips: the limiter strip
        // reports its chain, the plain strip pads to the track stage.
        let report = try #require(engine.pdcReport())
        #expect(report.trackStageSamples == lookahead)
        #expect(report.strips[limited.id]?.chainLatencySamples == lookahead)
        #expect(report.strips[plain.id]?.compensationSamples == lookahead)
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

    /// m23-bs-3a leg A-L1′ — the rebuild-resume property witness.
    ///
    /// ⚠️ THE ARITHMETIC IS DONE HERE, NEVER BY THE ENGINE (design §9.1). An
    /// in-engine anchor-DIFFERENCE seam would recompute the fix's own expression
    /// and subtract it from itself: identically zero by algebra, green against a
    /// broken `TempoMap`, a wrong loop branch or a sign error. The engine exports
    /// RAW SCALARS; the closed form lives test-side.
    ///
    /// The epsilon and β are taken from `RecoveryPlayheadTests` rather than
    /// re-typed: 1e-12 is DERIVED (see that constant's doc comment — measured
    /// worst 2.2e-16 = one ULP, and the design's "measured-worst × 10" rule is
    /// degenerate at zero), and a second copy of a number whose justification is
    /// a doc comment is a second home for the justification too.
    private static func assertRebuildResumeIsOnTheOutgoingLine(
        engine: AudioEngine,
        before: (startBeats: Double, anchorHostTime: UInt64)?,
        nSnapshot: Int,
        continuationsBefore: Int
    ) {
        guard let before else {
            let never: String = "m23-bs-3a A-L1′: there was no anchor before the rebuild — the "
                + "transport never started, so nothing below this could be read."
            Issue.record("\(never)")
            return
        }
        guard let after = engine.anchorLineForTesting else {
            let dropped: String = "m23-bs-3a A-L1′: there is no anchor AFTER the rebuild — the "
                + "transport was silently dropped rather than resumed. Check stderr for a "
                + "rebuild start failure."
            Issue.record("\(dropped)")
            return
        }

        let deltaSeconds = after.anchorHostTime >= before.anchorHostTime
            ? AVAudioTime.seconds(forHostTime: after.anchorHostTime - before.anchorHostTime)
            : -AVAudioTime.seconds(forHostTime: before.anchorHostTime - after.anchorHostTime)
        let beta = RecoveryPlayheadTests.beatsPerSecond
        let epsilon = RecoveryPlayheadTests.continuityEpsilonBeats
        let expected = before.startBeats + beta * deltaSeconds
        let residue = abs(after.startBeats - expected)
        let overrunBeats = beta * engine.lastContinuationOverrunSecondsForTesting

        let rendered = "b0=" + String(format: "%.6f", before.startBeats)
            + " b1=" + String(format: "%.6f", after.startBeats)
            + " dt=" + String(format: "%.4f", deltaSeconds) + "s"
            + " n=\(engine.lastContinuationPlayerCountForTesting)/snapshot=\(nSnapshot)"
            + " horizon=" + String(format: "%.4f", engine.lastContinuationHorizonSecondsForTesting)
            + "s overruns=\(engine.continuationOverrunCountForTesting)"
            + " overrunSec=" + String(format: "%.4f",
                                      engine.lastContinuationOverrunSecondsForTesting)
            + " clampDowns=\(engine.continuationClampDownCountForTesting)"
            + " continuations=\(continuationsBefore)->"
            + "\(engine.continuationStartCountForTesting)"
        print("[measured] m23-bs-3a A-L1′ \(rendered)")
        print("[measured] m23-bs-3a A-L1′ residue=" + String(format: "%.3e", residue)
              + " beats (epsilon " + String(format: "%.3e", epsilon) + ")")

        // THE DISCRIMINATOR (m23-bt's `recoveryRestartCountForTesting` shape).
        // `lastContinuation*ForTesting` are written by EVERY continuation site,
        // so without this every assertion below could be a read-back of some
        // OTHER event's values that happen to match.
        let wrongEvent: String = "m23-bs-3a A-L1′: the continuation-start counter went "
            + "\(continuationsBefore) -> \(engine.continuationStartCountForTesting) across the "
            + "rebuild. It must advance by EXACTLY ONE: zero means the rebuild resume never "
            + "took the continuation path (so every seam below still holds someone else's "
            + "values and this leg is green for the wrong reason); more than one means "
            + "something else continued in the same window and the seams describe THAT. "
            + rendered
        #expect(engine.continuationStartCountForTesting == continuationsBefore + 1,
                "\(wrongEvent)")

        // ANTI-VACUITY — the trap this test's fixture change exists to escape.
        let hollow: String = "ANTI-VACUITY FAILURE: the ROLLING fixture had ZERO startable "
            + "players, so the count reads 0 on both sides of the landmine and the L3 half "
            + "proves nothing. `startablePlayerCount` walks trackNodes (AUDIO clip nodes); "
            + "instrument tracks live in instrumentNodes and contribute none. The audio clip "
            + "must be in the INITIAL set (not on the track being added — that node does not "
            + "exist at quiesce) and must still sit in the FUTURE at the bounce. " + rendered
        #expect(nSnapshot >= 1, "\(hollow)")

        // L3 — THE READ SITE. At this site the resume-time read returns 0 BY
        // CONSTRUCTION: `rebuildEngine`'s graph is a different object that has
        // never been scheduled. A reported 0 therefore means the count read
        // moved out of the quiesce block.
        let landmine: String = "m23-bs-3a LANDMINE (§14.3): the rebuild resume forecast its "
            + "horizon from \(engine.lastContinuationPlayerCountForTesting) startable players "
            + "where this test's own pre-trigger snapshot says \(nSnapshot). A reported 0 means "
            + "the count is being read at the RESUME site, where the rebuilt graph has never "
            + "been scheduled and always reads 0 — the horizon then collapses to the floor for "
            + "every project size, silently. Read it at QUIESCE, above stopAllPlayers(), and "
            + "carry it. " + rendered
        #expect(engine.lastContinuationPlayerCountForTesting == nSnapshot, "\(landmine)")

        // The horizon identity — an EXACT read-back against the ONE home. This
        // is what makes a degenerate horizon (≡ 0, which would make L1 skip
        // forever while testing nothing) RED here rather than merely silent.
        let expectedHorizon = StartAnchorBudget.continuationHorizonSeconds(
            forStartablePlayerCount: nSnapshot)
        let drifted: String = "the horizon the rebuild resume used "
            + "(\(engine.lastContinuationHorizonSecondsForTesting)) is not "
            + "StartAnchorBudget.continuationHorizonSeconds(\(nSnapshot)) = \(expectedHorizon). "
            + "Either a second copy of the budget formula has appeared, or the horizon is no "
            + "longer computed from the count this leg pins. " + rendered
        #expect(engine.lastContinuationHorizonSecondsForTesting == expectedHorizon, "\(drifted)")

        let bug: String = "the continuation anchor was clamped DOWN — a caller computed its "
            + "horizon somewhere other than StartAnchorBudget. " + rendered
        #expect(engine.continuationClampDownCountForTesting == 0, "\(bug)")

        // L2 — CONSISTENCY, NEVER SKIPPED. Relates two INDEPENDENTLY exported
        // quantities, so it holds regardless of load or which path ran.
        let inconsistent: String = "m23-bs-3a A-L1′ L2: the rebuild-resume anchor is off the "
            + "outgoing line by more than the engine's OWN reported overrun. residue="
            + String(format: "%.3e", residue) + " reportedOverrunBeats="
            + String(format: "%.3e", overrunBeats) + ". This is a WRONG DERIVATION, not load — "
            + "the two quantities are exported independently, so no amount of starvation can "
            + "produce it. Suspect the tempo map, the loop branch or a sign. " + rendered
        #expect(residue <= overrunBeats + epsilon, "\(inconsistent)")

        // L1 — THE REGRESSION GUARD. This engine is fresh and this is its first
        // continuation, so a non-zero cumulative overrun count IS this event's.
        if engine.continuationOverrunCountForTesting > 0 {
            print("[measured] m23-bs-3a A-L1′ L1 SKIPPED — budget overrun x"
                  + "\(engine.continuationOverrunCountForTesting), worst "
                  + String(format: "%.1f",
                           engine.lastContinuationOverrunSecondsForTesting * 1000)
                  + " ms. L2 and L3 still ran.")
            return
        }
        let why: String = "m23-bs-3a REGRESSION: the cold-rebuild resume did NOT land on the "
            + "outgoing anchor's line, and the engine reported NO overrun — so this is the "
            + "DERIVATION, not the budget. The rebuild resume must predict the instant its "
            + "anchor will land on (`continuationAnchorInstant`), derive the beat FOR that "
            + "instant off the CARRIED AnchorLine (`resumeBeat(at:line:)`), and pass BOTH via "
            + "`.atHostTime`. A frozen quiesce beat, or a beat derived at resume-entry and "
            + "anchored a lead later, steps the transport backward by the whole rebuild — "
            + "permanently, and compounding on every occurrence. residue="
            + String(format: "%.3e", residue) + " " + rendered
        #expect(residue <= epsilon, "\(why)")
    }

    /// m16-h C7c + Leg 2's original subject: a mid-play strip birth announces,
    /// quiesces, cold-rebuilds and RESUMES. **m23-bs-3a folds leg A-L1′ onto
    /// this session** — the rebuild resume is the m20-e device-flip path and the
    /// one bs-3a site that is reachable, and this test already rolls live
    /// playback across exactly that event. **bs-3a therefore adds ZERO live
    /// playback sessions.**
    ///
    /// ⚠️ THE FIXTURE CHANGE IS MANDATORY AND IT IS NOT WHERE THE DESIGN SAID.
    /// §14.8 describes the fixture as "one `.testTone` INSTRUMENT track plus an
    /// empty audio track" and asks for one audio clip. That describes the
    /// POST-trigger state: the empty `Track(name: "Gtr")` is the rebuild TRIGGER,
    /// added after the roll. The count A-L1′ asserts on is captured at QUIESCE —
    /// inside `willMutateRoutingTopology`, during the reconcile that announces —
    /// so a clip on the track being ADDED is invisible to it (the node does not
    /// exist yet and has never been scheduled). The audio clip has to be in the
    /// INITIAL, ROLLING set, or `nSnapshot == 0`, the engine reports 0, and
    /// `0 == 0` passes vacuously — the exact trap §14.8 warns about, reached by
    /// following §14.8's own fixture description.
    ///
    /// `startablePlayerCount` walks `trackNodes` (AUDIO clip nodes); instrument
    /// tracks live in `instrumentNodes` and contribute NONE, which is why the
    /// original all-MIDI fixture could not carry this leg. The clip sits in the
    /// FUTURE (bs-1's beats 4…28 convention) because `scheduleAll` drops a clip
    /// whose source is exhausted at the resume beat.
    ///
    /// WHAT A-L1′ ASSERTS, and why each is separable:
    ///   L1 (the derivation) — the resume anchor is on the OUTGOING anchor's
    ///      line: `b1 == b0 + β·Δt`. Reds if the rebuild resume goes back to
    ///      `.asSoonAsPractical`, or derives its beat anywhere but AT the instant
    ///      it anchors on.
    ///   +1 (the discriminator) — `continuationStartCountForTesting` advanced by
    ///      exactly one ACROSS this event. Without it, every other assertion here
    ///      could be reading a recovery's leftovers.
    ///   L2 (consistency, never skipped) — the residue never exceeds the engine's
    ///      OWN reported overrun. Two independently exported quantities, so no
    ///      amount of starvation can produce a violation: a failure is a WRONG
    ///      DERIVATION (tempo map, loop branch, sign).
    ///   L3 (the budget's read site) — the engine forecast from the QUIESCE
    ///      count, not from the rebuilt graph's 0. Plus an exact horizon
    ///      read-back against `StartAnchorBudget`, which is what makes a
    ///      degenerate horizon (≡ 0) red here rather than merely skip L1.
    ///
    /// ⚠️ L1 SKIPS LOUDLY on an engine-reported overrun — a machine fact, not a
    /// defect — and L2/L3 are what stop that skip from becoming a coverage hole.
    /// m23-bu-3: 120 BPM (the `TransportState` default) → 1 beat = 500 ms of
    /// music, so wall-time-implied beat = elapsedMs × this factor. Named so a
    /// bare 0.002 in a diff reads as "the tempo conversion", not a stray
    /// magic number — mirrors `RecoveryPlayheadTests.beatsPerMillisecond`
    /// (`Tests/DAWEngineTests/RecoveryPlayheadTests.swift:284`).
    private static let beatsPerMillisecond = 1.0 / 500.0

    /// m23-bu-3: the lag-GROWTH ceiling for `midPlayStripBirthRebuildsAndResumes`'s
    /// post-mark observation window. Full derivation lives on the assertion
    /// below (pass bound, measured values, fail requirement, margins) —
    /// summary: 0.5 beats, 1.9× the derived pass bound (≈0.265), 5.7× the
    /// largest measured growth (0.087), 4× below where a total freeze ends up
    /// (~2.0 over a 1 s window).
    private static let maxLagGrowthBeats = 0.5

    @Test("m16-h C7c + Leg 2 live: mid-play strip birth rebuilds, RESUMES playback, and the engine runs")
    func midPlayStripBirthRebuildsAndResumes() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return  // headless machine — liveSmoke idiom
        }
        // m23-bu-3: teardown moved into `defer`. The StarvationWitness
        // classification below adds two early-return exit paths (`.starved`
        // skip, `.renderDead` failure) that the two explicit teardown calls
        // formerly sitting at the bottom of this function would not have
        // covered — `defer` makes every exit path (including the throwing
        // `TestSignals.fixtures()` call just below) tear the engine down the
        // same way the normal-completion path always did.
        defer {
            engine.stopPlayback()
            engine.shutdown()
        }
        let keys = Track(name: "Keys", kind: .instrument,
                         clips: [Clip(name: "midi", startBeat: 0, lengthBeats: 64, notes: [
                             MIDINote(pitch: 69, velocity: 100, startBeat: 0, lengthBeats: 64),
                         ])],
                         instrument: InstrumentDescriptor(kind: .testTone))
        // m23-bs-3a: a REAL AUDIO PLAYER in the rolling set — see this test's
        // doc comment. Without it A-L1′'s L3 half is vacuous.
        let fixtures = try TestSignals.fixtures()
        let audio = Track(name: "Bed", kind: .audio,
                          clips: [Clip(name: "future", startBeat: 4, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)])
        engine.tracksDidChange([keys, audio])
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        // m23-bu-3: t0 taken immediately AFTER startPlayback returns, so the
        // schedule pass itself sits outside the measured span — mirrors
        // `RecoveryPlayheadTests.measure()`
        // (Tests/DAWEngineTests/RecoveryPlayheadTests.swift:310-318). No
        // `await` separates `startPlayback` from the handler assignment
        // below, so no push can land in the gap and be missed.
        let t0 = Date()
        var pushes: [Double] = []
        // m23-bu-3: timestamped samples alongside the existing beats-only
        // `pushes` array — `pushes` still carries the surviving
        // monotonicity/backward-step assertion below.
        var samples: [(ms: Double, beat: Double)] = []
        engine.playheadHandler = { beat in
            pushes.append(beat)
            samples.append((Date().timeIntervalSince(t0) * 1000, beat))
        }
        try await Task.sleep(for: .milliseconds(250))
        let graphBefore = ObjectIdentifier(engine.graph)

        // m23-bs-3a A-L1′ — read the OUTGOING line and the quiesce-comparable
        // count immediately before the trigger. The snapshot is comparable to
        // the engine's own quiesce read because the enqueue ledger is only
        // zeroed by `stopAllPlayers()`, which the hook reaches AFTER its read.
        let before = engine.anchorLineForTesting
        let nSnapshot = engine.graph.startablePlayerCount
        let continuationsBefore = engine.continuationStartCountForTesting

        // track.add during playback: Leg 2 announces the strip birth, the
        // hook winds playback down capturing resume state, rebuildEngine
        // cold-builds WITH the new strip and Leg 1's resume condition
        // starts + resumes — the m13-a send-add interruption class.
        engine.tracksDidChange([keys, audio, Track(name: "Gtr", kind: .audio)])

        #expect(ObjectIdentifier(engine.graph) != graphBefore)  // rebuilt
        #expect(engine.isRunning)
        #expect(engine.graph.engineHasRun)
        #expect(!engine.graph.needsEngineRebuild)

        Self.assertRebuildResumeIsOnTheOutgoingLine(
            engine: engine, before: before, nSnapshot: nSnapshot,
            continuationsBefore: continuationsBefore)

        // m23-bu-3 — THE MARK. Everything from here is the fixed observation
        // window the growth metric below judges.
        let lastBeat = pushes.last ?? 0
        let markMs = Date().timeIntervalSince(t0) * 1000
        let callbackCountBefore = engine.performanceStats(reset: false).callbackCount

        // FIXED window, not the m19-e bounded poll it replaces (that poll
        // exited on the FIRST push after the mark, healthy or not). Deleting
        // it looks wrong next to that de-flake comment's own reasoning, so
        // here is why it is safe: a bounded poll on PUSH COUNT is blind to a
        // frozen transport by construction — a frozen transport still
        // republishes the SAME beat at ~30 Hz, so the poll's own exit
        // condition (`pushes.count <= pushesAtRebuild`) clears on the very
        // first frozen tick, and so did both assertions it used to gate
        // (`pushes.count > pushesAtRebuild`, `pushes.last >= lastBeat`) —
        // callback liveness, the anti-pattern `docs/ARCHITECTURE.md:849`
        // names as its worked counter-example.
        //
        // A LAG-GROWTH metric is what a freeze cannot fake, and a FIXED
        // window (rather than a poll) is safe for it for a reason that is
        // measured, not theory: under main-actor starvation the playhead
        // task simply does not run; when it finally does, it pushes the
        // CURRENT beat at a CURRENT timestamp, so a delayed sample reads LOW
        // lag, never high. Starvation costs the sample COUNT, never sample
        // ACCURACY — the only exposure that leaves is a sparse/zero sample
        // count, which `StarvationWitness` classifies below rather than this
        // window trying to poll around it.
        try await Task.sleep(for: .milliseconds(1000))
        // Read BEFORE stopPlayback()/shutdown() (both now in `defer`) —
        // StarvationWitness's precondition needs a window with no
        // `performanceStats(reset: true)` in between (its header).
        let callbackCountAfter = engine.performanceStats(reset: false).callbackCount

        // Backward-step guard — RETITLED, and it is NOT a freeze detector:
        // the growth metric below is one-sided (it only sees the transport
        // fall BEHIND wall time) and cannot see the m23-bs defect class,
        // where a recovery path steps the transport BACKWARD and then
        // recovers within the window. Two separable properties, two
        // assertions; this one runs unconditionally because it needs
        // neither `samples` nor a minimum sample count to mean something.
        #expect((pushes.last ?? 0) >= lastBeat)

        let after = samples.filter { $0.ms > markMs }
        switch StarvationWitness.classify(
            mainActorSampleCount: after.count, minimumSamples: 2,
            callbackCountBefore: callbackCountBefore, callbackCountAfter: callbackCountAfter
        ) {
        case .starved(let delta, let minimum):
            // Deliberately NON-DEFAULT `minimumSamples: 2` — not an invented
            // number: a lag-GROWTH metric is undefined with fewer than two
            // post-mark samples, so 2 is this metric's true requirement.
            StarvationWitness.printSkip(
                leg: "midPlayStripBirthRebuildsAndResumes",
                mainActorSampleCount: after.count, minimumSamples: minimum,
                callbackDelta: delta)
            return
        case .renderDead:
            let dead: String = "midPlayStripBirthRebuildsAndResumes: fewer than 2 usable "
                + "post-mark playhead samples AND the render thread's own callbackCount did not "
                + "advance either (\(callbackCountBefore)→\(callbackCountAfter)) — a dead "
                + "transport, not a starved main actor."
            Issue.record("\(dead)")
            return
        case .usable:
            break
        }

        // m23-bu-3 — THE GROWTH CEILING.
        //
        // Metric: for each post-mark sample, lag = (wall-time-implied beat) −
        // (pushed beat); the assertion is maxLag − minLag across those
        // samples — the GROWTH of the lag, not its absolute value. Growth,
        // not absolute lag, because this leg has NO control run to cancel the
        // systematic offset the way `RecoveryPlayheadTests` does with its
        // delta metric: there is always a constant offset (audio begins one
        // start-lead after t0; measured ~0.12-0.14 beats). Growth cancels any
        // constant offset within a single run, which makes the ceiling
        // independent of how large that offset is — and that matters here
        // because this leg's resume path currently runs through
        // `AudioEngine.swift:1329-1337`, m23-bs-3a code the user has not yet
        // ruled on. If bs-3a is reverted the constant offset grows (it
        // becomes the whole rebuild gap) but the GROWTH does not, so this
        // ceiling holds under either ruling.
        //
        // Ceiling: 0.5 beats (`Self.maxLagGrowthBeats`).
        //  - Pass bound, DERIVED (not measured): the legitimate lag excursion
        //    is the anchor plateau — `elapsedSeconds` clamps to the anchor's
        //    start beat until the chosen instant arrives. Bounded by
        //    `StartAnchorBudget.continuationHorizonSeconds
        //    (forStartablePlayerCount:)` = lead(n) + 0.030 s
        //    (`Sources/DAWEngine/StartAnchorBudget.swift:117`), which for
        //    this leg's small n is 0.06 + 0.030 = 0.090 s = 0.180 beats. Add
        //    one buffer quantum of sampling jitter (2048 frames @ 48 kHz =
        //    42.7 ms = 0.085 beats). Derived bound ≈ 0.265 beats.
        //  - Measured: worst-case absolute lag 0.121 beats isolated / 0.143
        //    beats under the full parallel suite; growth 0.087 isolated /
        //    ~0.000 under the full suite (contention cut the post-mark
        //    sample count from 27 to 9 and moved the lag by 0.02 beats — the
        //    starvation-robustness claim above, measured).
        //  - Fail requirement: a frozen transport accumulates lag at exactly
        //    2 beats/second, so it crosses 0.5 beats 250 ms into the window
        //    and reaches ~2.0 beats by the end of a nominal 1000 ms window.
        //  - Margins: 1.9× above the derived pass bound, 5.7× above the
        //    largest measured growth, 4× below where a total freeze ends up.
        //
        // Blind spot, stated honestly: growth cannot see a freeze that both
        // STARTS and ENDS between two consecutive samples. Not the m23-bq
        // class here — the measured worst-case inter-sample gap under
        // full-suite contention was 244 ms, and the defect class is
        // multi-second.
        //
        // The sentinel-init loop below is only reachable with `after.count >=
        // 2` (`.usable` guarantees that via `minimumSamples: 2` above), so
        // `minLag`/`maxLag` are always overwritten before use.
        var minLag = Double.greatestFiniteMagnitude
        var maxLag = -Double.greatestFiniteMagnitude
        for sample in after {
            let expected = sample.ms * Self.beatsPerMillisecond
            let lag = expected - sample.beat
            minLag = min(minLag, lag)
            maxLag = max(maxLag, lag)
        }
        let growth = maxLag - minLag
        print("[measured] m23-bu-3 lagGrowth=" + String(format: "%.3f", growth)
              + " beats over \(after.count) post-mark samples (ceiling "
              + "\(Self.maxLagGrowthBeats))")
        let why = "m23-bq/m23-bu-3 REGRESSION: the transport's lag against wall time grew by "
            + String(format: "%.3f", growth) + " beats across the post-mark window — a frozen "
            + "or badly-degrading resume. samples=\(after.count)"
        #expect(growth <= Self.maxLagGrowthBeats, "\(why)")
    }
}
