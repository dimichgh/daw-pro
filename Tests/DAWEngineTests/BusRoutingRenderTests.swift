import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// Bus routing & sends proof for M4 (i): per-bus mixers under the main mix,
/// track fan-out (output destination + dedicated send-gain node per send),
/// post-fader send math, the v0 solo matrix, and the structural/in-place
/// split — all rendered offline through the same PlaybackGraph the live
/// engine uses, against the 1 kHz cosine fixtures at 48 kHz.
/// Steady-window baseline RMS for the amp-0.5 fixture: 0.5/√2 ≈ 0.3536.
@MainActor
@Suite("Bus routing & sends — offline render", .serialized)
struct BusRoutingRenderTests {
    /// Steady-state window: clip starts at beat 0, so frames 12k–36k sit well
    /// inside the tone with margin on both sides of a 1.0 s render.
    private static let window = 12_000..<36_000
    /// amp 0.5 / √2.
    private static let baselineRMS: Float = 0.3536

    private func sourceTrack(clip url: URL, volume: Double = 1,
                             isMuted: Bool = false, isSoloed: Bool = false,
                             outputBusID: UUID? = nil,
                             sends: [Send] = []) -> Track {
        Track(name: "SRC", kind: .audio, volume: volume,
              isMuted: isMuted, isSoloed: isSoloed,
              clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4,
                           audioFileURL: url)],
              outputBusID: outputBusID, sends: sends)
    }

    private func bus(_ id: UUID, name: String = "Bus", volume: Double = 1,
                     isMuted: Bool = false, isSoloed: Bool = false) -> Track {
        Track(id: id, name: name, kind: .bus, volume: volume,
              isMuted: isMuted, isSoloed: isSoloed)
    }

    private func maxAbsDifference(_ a: RenderedAudio, _ b: RenderedAudio) -> Float {
        var maxDiff: Float = 0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            let lhs = a.channelData[channel]
            let rhs = b.channelData[channel]
            for frame in 0..<min(lhs.count, rhs.count) {
                maxDiff = max(maxDiff, abs(lhs[frame] - rhs[frame]))
            }
        }
        return maxDiff
    }

    // MARK: - Spike (risk register #1: fan-out under manual rendering)

    @Test("routing through a unity bus nulls exactly against a master-routed render")
    func unityBusRoutingNullsAgainstMaster() throws {
        let fixtures = try TestSignals.fixtures()
        let master = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let busID = UUID()
        let routed = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48, outputBusID: busID),
                     bus(busID)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        #expect(master.frameCount == 48_000)
        #expect(routed.frameCount == 48_000)
        let maxDiff = maxAbsDifference(master, routed)
        print("[measured] unity bus routing null: max |master − bus@unity| = \(maxDiff)")
        #expect(maxDiff == 0)
    }

    @Test("bus meter taps deliver nonzero frames for the bus id during an offline render")
    func busMeterTapsFire() async throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        let renderer = OfflineRenderer()
        var frames: [UUID: [MeterFrame]] = [:]
        renderer.meterSink = { trackID, frame in
            frames[trackID, default: []].append(frame)
        }
        _ = try renderer.render(
            tracks: [sourceTrack(clip: fixtures.cos1k48, outputBusID: busID),
                     bus(busID)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        // Tap frames hop to the main actor as queued Tasks; the pulls are
        // synchronous, so they only land once we suspend. Drain them.
        try await Task.sleep(for: .milliseconds(300))

        let busFrames = try #require(frames[busID])
        let maxRMS = busFrames.map(\.rms).max() ?? 0
        print("[measured] bus meter tap: \(busFrames.count) frames, "
              + "max RMS \(maxRMS) (expected ≈ 0.3536)")
        #expect(abs(maxRMS - Self.baselineRMS) < 0.06)
    }

    // MARK: - Gain math

    @Test("bus volume 0.5 halves a routed track's rendered RMS")
    func busVolumeScalesRoutedTrack() throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        let audio = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48, outputBusID: busID),
                     bus(busID, volume: 0.5)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let expected = Self.baselineRMS / 2
        for channel in audio.channelData {
            let rms = TestSignals.rms(channel, in: Self.window)
            print("[measured] bus volume 0.5 RMS: \(rms) (expected \(expected) ± 2%)")
            #expect(abs(rms - expected) < 0.02 * expected)
        }
    }

    @Test("send 0.5 into a bus at 0.5 lands at exactly ×0.25 (direct path killed)")
    func sendGainMathIsExact() throws {
        let fixtures = try TestSignals.fixtures()
        let busA = UUID()  // direct-path sink at volume 0
        let busB = UUID()  // send return at volume 0.5
        let audio = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48, outputBusID: busA,
                                 sends: [Send(destinationBusID: busB, level: 0.5)]),
                     bus(busA, name: "Kill", volume: 0),
                     bus(busB, name: "Return", volume: 0.5)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let expected = Self.baselineRMS * 0.25
        for channel in audio.channelData {
            let rms = TestSignals.rms(channel, in: Self.window)
            print("[measured] send 0.5 × bus 0.5 RMS: \(rms) (expected \(expected) ± 2%)")
            #expect(abs(rms - expected) < 0.02 * expected)
        }
    }

    @Test("sends are post-fader: track volume 0.5 halves the send return")
    func postFaderSendFollowsTrackVolume() throws {
        let fixtures = try TestSignals.fixtures()
        let busA = UUID()  // direct-path sink at volume 0
        let busB = UUID()  // unity send return
        let audio = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48, volume: 0.5,
                                 outputBusID: busA,
                                 sends: [Send(destinationBusID: busB, level: 1)]),
                     bus(busA, name: "Kill", volume: 0),
                     bus(busB, name: "Return")],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        // Post-fader: the send tap sits after track volume → ×0.5. A
        // pre-fader tap would read ×1.0 here.
        let expected = Self.baselineRMS / 2
        for channel in audio.channelData {
            let rms = TestSignals.rms(channel, in: Self.window)
            print("[measured] post-fader send RMS: \(rms) (expected \(expected) ± 2%)")
            #expect(abs(rms - expected) < 0.02 * expected)
        }
    }

    @Test("a muted track is silent on its sends and on the bus meter")
    func mutedTrackIsSilentOnItsSends() async throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        let renderer = OfflineRenderer()
        var frames: [UUID: [MeterFrame]] = [:]
        renderer.meterSink = { trackID, frame in
            frames[trackID, default: []].append(frame)
        }
        let audio = try renderer.render(
            tracks: [sourceTrack(clip: fixtures.cos1k48, isMuted: true,
                                 sends: [Send(destinationBusID: busID, level: 1)]),
                     bus(busID)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        for channel in audio.channelData {
            let peak = TestSignals.peak(channel, in: 0..<channel.count)
            print("[measured] muted track w/ unity send: output peak \(peak)")
            #expect(peak < 1e-6)
        }
        try await Task.sleep(for: .milliseconds(300))
        let busFrames = frames[busID] ?? []
        let busPeak = busFrames.map(\.peak).max() ?? 0
        print("[measured] muted track w/ unity send: bus meter peak \(busPeak) "
              + "over \(busFrames.count) frames")
        #expect(busFrames.allSatisfy { $0.peak < 1e-6 && $0.rms < 1e-6 })
    }

    // MARK: - Solo matrix (v0: solo-in-place, bus mixers never solo-gated)

    @Test("a soloed track routed through a bus stays audible")
    func soloedTrackStaysAudibleThroughItsBus() throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        // The non-soloed neighbor carries the LOUDER amp-0.5 tone straight to
        // master: any leak pushes the RMS visibly above the routed track alone.
        let audio = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48Quarter, isSoloed: true,
                                 outputBusID: busID),
                     sourceTrack(clip: fixtures.cos1k48),
                     bus(busID)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let expected = Self.baselineRMS / 2  // amp 0.25 fixture
        let rms = TestSignals.rms(audio.channelData[0], in: Self.window)
        print("[measured] soloed track through bus RMS: \(rms) (expected \(expected) ± 2%)")
        #expect(abs(rms - expected) < 0.02 * expected)
    }

    @Test("soloing a bus solos its feeders in place — direct outs included, non-feeders silent")
    func soloingABusSolosItsFeeders() throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        // Feeder: amp 0.25, direct out to master PLUS a unity send into the
        // soloed bus → 0.25 + 0.25 = amp 0.5 (RMS 0.3536) iff the direct out
        // survives. Non-feeder: amp 0.5 straight to master — its leak would
        // read amp 1.0 (RMS 0.707).
        let audio = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48Quarter,
                                 sends: [Send(destinationBusID: busID, level: 1)]),
                     sourceTrack(clip: fixtures.cos1k48),
                     bus(busID, isSoloed: true)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let expected = Self.baselineRMS  // 0.25 direct + 0.25 return, in phase
        let rms = TestSignals.rms(audio.channelData[0], in: Self.window)
        print("[measured] soloed bus feeder RMS: \(rms) "
              + "(expected \(expected) ± 2%; 0.177 = direct out lost, 0.707 = non-feeder leak)")
        #expect(abs(rms - expected) < 0.02 * expected)
    }

    @Test("soloing a track keeps its send return audible (bus is not solo-gated)")
    func soloedTrackKeepsSendReturnAudible() throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        // Soloed amp-0.25 track: direct out + unity send through a unity bus
        // → 0.25 + 0.25 = amp 0.5 (RMS 0.3536). A solo-gated bus would leave
        // only the direct 0.25 (RMS 0.177). The non-soloed amp-0.5 neighbor
        // must contribute nothing.
        let audio = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48Quarter, isSoloed: true,
                                 sends: [Send(destinationBusID: busID, level: 1)]),
                     sourceTrack(clip: fixtures.cos1k48),
                     bus(busID)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        let expected = Self.baselineRMS
        let rms = TestSignals.rms(audio.channelData[0], in: Self.window)
        print("[measured] soloed track send return RMS: \(rms) "
              + "(expected \(expected) ± 2%; 0.177 = return solo-gated)")
        #expect(abs(rms - expected) < 0.02 * expected)
    }

    // MARK: - Structural vs in-place

    /// Manual-rendering engine + graph pair mirroring OfflineRenderer's
    /// setup, for tests that must reconcile MID-render or inspect node
    /// identity across a reconcile.
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

    /// Pulls `frames` frames from a running manual-rendering engine, appending
    /// deinterleaved samples to `channelData`.
    private func pull(_ engine: AVAudioEngine, frames: Int,
                      into channelData: inout [[Float]]) throws {
        let format = engine.manualRenderingFormat
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_096))
        var rendered = 0
        while rendered < frames {
            let request = AVAudioFrameCount(min(frames - rendered, 4_096))
            let status = try engine.renderOffline(request, to: buffer)
            try #require(status == .success)
            let source = try #require(buffer.floatChannelData)
            let count = Int(buffer.frameLength)
            for channel in 0..<channelData.count {
                channelData[channel].append(contentsOf:
                    UnsafeBufferPointer(start: source[channel], count: count))
            }
            rendered += count
        }
    }

    @Test("a send LEVEL change is in-place: reconcile false, same gain node, clean plateaus")
    func sendLevelChangeIsNotStructural() throws {
        let fixtures = try TestSignals.fixtures()
        let busA = UUID()  // direct-path sink at volume 0
        let busB = UUID()  // unity send return
        let send = Send(destinationBusID: busB, level: 1)
        let before = sourceTrack(clip: fixtures.cos1k48, outputBusID: busA,
                                 sends: [send])
        var after = before
        after.sends[0].level = 0.5
        let buses = [bus(busA, name: "Kill", volume: 0), bus(busB, name: "Return")]

        let (engine, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: [before] + buses))
        graph.applyParameters(tracks: [before] + buses)
        try engine.start()
        graph.applyParameters(tracks: [before] + buses)
        graph.scheduleAll(fromBeat: 0, tempoBPM: 120)
        graph.startAllPlayers(at: nil)

        var channelData: [[Float]] = [[], []]
        try pull(engine, frames: 24_000, into: &channelData)

        // The level-only change: NOT structural, and the gain node survives.
        let nodeBefore = try #require(
            graph.sendGainNode(forTrack: before.id, sendID: send.id))
        let changed = graph.reconcile(tracks: [after] + buses)
        #expect(!changed)
        graph.applyParameters(tracks: [after] + buses)
        let nodeAfter = try #require(
            graph.sendGainNode(forTrack: after.id, sendID: send.id))
        #expect(nodeBefore === nodeAfter)

        try pull(engine, frames: 24_000, into: &channelData)
        engine.stop()

        // Two gain plateaus (send 1.0 → amp 0.5, send 0.5 → amp 0.25), no
        // full-scale discontinuity anywhere across the change.
        let left = channelData[0]
        let plateau1 = TestSignals.rms(left, in: 12_000..<22_000)
        let plateau2 = TestSignals.rms(left, in: 36_000..<46_000)
        let globalPeak = TestSignals.peak(left, in: 0..<left.count)
        print("[measured] send-level plateaus: \(plateau1) → \(plateau2) "
              + "(expected 0.3536 → 0.1768), global peak \(globalPeak)")
        #expect(abs(plateau1 - Self.baselineRMS) < 0.02 * Self.baselineRMS)
        #expect(abs(plateau2 - Self.baselineRMS / 2) < 0.02 * Self.baselineRMS / 2)
        #expect(globalPeak < 0.51)
    }

    @Test("changing a track's output routing is structural")
    func outputRoutingChangeIsStructural() throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        let toMaster = sourceTrack(clip: fixtures.cos1k48)
        var toBus = toMaster
        toBus.outputBusID = busID

        let (_, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: [toMaster, bus(busID)]))    // initial build
        #expect(!graph.reconcile(tracks: [toMaster, bus(busID)]))   // steady state
        #expect(graph.reconcile(tracks: [toBus, bus(busID)]))       // routing change
        #expect(graph.reconcile(tracks: [toMaster, bus(busID)]))    // and back
    }

    @Test("adding and removing a bus is structural")
    func busAddRemoveIsStructural() throws {
        let fixtures = try TestSignals.fixtures()
        let track = sourceTrack(clip: fixtures.cos1k48)
        let busID = UUID()

        let (_, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: [track]))                   // initial build
        #expect(graph.reconcile(tracks: [track, bus(busID)]))       // bus added
        #expect(!graph.reconcile(tracks: [track, bus(busID)]))      // steady state
        #expect(graph.reconcile(tracks: [track]))                   // bus removed
    }

    @Test("bus deletion falls back to master: dangling routing renders a null against plain master")
    func busDeletionFallbackNullsAgainstPlainMaster() throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        // ProjectStore clears routing refs inside the bus-removal edit; this
        // exercises the graph's DEFENSIVE half — the bus disappears while the
        // track still references it (output AND a send), so the output falls
        // back to the main mix and the send is dropped.
        let track = sourceTrack(clip: fixtures.cos1k48, outputBusID: busID,
                                sends: [Send(destinationBusID: busID, level: 1)])

        let (engine, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: [track, bus(busID)]))   // routed into the bus
        #expect(graph.reconcile(tracks: [track]))               // bus deleted, refs dangle
        graph.applyParameters(tracks: [track])
        try engine.start()
        graph.applyParameters(tracks: [track])
        graph.scheduleAll(fromBeat: 0, tempoBPM: 120)
        graph.startAllPlayers(at: nil)
        var channelData: [[Float]] = [[], []]
        try pull(engine, frames: 48_000, into: &channelData)
        engine.stop()

        let master = try OfflineRenderer().render(
            tracks: [sourceTrack(clip: fixtures.cos1k48)],
            tempoBPM: 120, fromBeat: 0, durationSeconds: 1.0
        )
        var maxDiff: Float = 0
        for channel in 0..<2 {
            for frame in 0..<min(channelData[channel].count,
                                 master.channelData[channel].count) {
                maxDiff = max(maxDiff,
                              abs(channelData[channel][frame] - master.channelData[channel][frame]))
            }
        }
        print("[measured] bus-deletion fallback null: max |fallback − master| = \(maxDiff)")
        #expect(maxDiff == 0)
    }

    // MARK: - Live-rewire regressions (M4 i live E2E)

    /// Live BUG regression (offline analog): a send added MID-PLAY was silent
    /// on its bus. The live fix quiesces the transport BEFORE the engine
    /// stops for the rewire, resets, restarts, and resumes through the
    /// cold-start primitive (see the hook rationale in AudioEngine.init).
    /// This pins that exact order — quiesce → engine.stop → reconcile →
    /// volumes → reset → start → pans → cold-start resume — and that BOTH
    /// restart paths (the bounce resume, and a plain transport stop/play
    /// cycle afterwards) deliver identical send energy, matching a
    /// from-scratch reference render. The live "leg stays silent when the
    /// engine bounces under live schedules" behavior is only provable live.
    @Test("mid-run send add: quiesced bounce order wires the branch; both restart paths match")
    func midRunSendAddRewiresAndAppliesLevel() throws {
        let fixtures = try TestSignals.fixtures()
        let busA = UUID()
        let busB = UUID()
        let before = sourceTrack(clip: fixtures.cos1k48, outputBusID: busA)
        var after = before
        let send = Send(destinationBusID: busB, level: 0.5)
        after.sends = [send]
        let buses = [bus(busA, name: "A"), bus(busB, name: "B")]

        let (engine, graph) = try makeManualEngine()
        var hookFired = 0
        graph.willMutateRoutingTopology = { hookFired += 1 }
        #expect(graph.reconcile(tracks: [before] + buses))
        graph.applyParameters(tracks: [before] + buses)
        try engine.start()
        graph.applyParameters(tracks: [before] + buses)
        graph.scheduleAll(fromBeat: 0, tempoBPM: 120)
        graph.startAllPlayers(at: nil)
        var channelData: [[Float]] = [[], []]
        try pull(engine, frames: 24_000, into: &channelData)
        #expect(hookFired == 1)  // fresh track wired into busA (non-trivial)

        // The live bounce, in AudioEngine's exact order: QUIESCE first
        // (players stopped, schedules unpublished), THEN engine.stop,
        // reconcile stopped, volumes pre-start, reset, start, pans
        // post-start, cold-start resume.
        graph.stopAllPlayers()
        engine.stop()
        #expect(graph.reconcile(tracks: [after] + buses))   // structural: send added
        #expect(hookFired == 2)
        graph.applyParameters(tracks: [after] + buses)
        engine.reset()
        try engine.start()
        graph.applyParameters(tracks: [after] + buses)
        graph.scheduleAll(fromBeat: 1.0, tempoBPM: 120)     // 24k frames = 1 beat
        graph.startAllPlayers(at: nil)
        try pull(engine, frames: 24_000, into: &channelData)

        // Path 2 — the C-case transport cycle on the same engine: plain
        // player stop/reschedule/start, no rewire, no bounce.
        graph.stopAllPlayers()
        graph.scheduleAll(fromBeat: 1.0, tempoBPM: 120)
        graph.startAllPlayers(at: nil)
        try pull(engine, frames: 24_000, into: &channelData)
        engine.stop()

        let gainVolume = try #require(
            graph.sendGainNode(forTrack: after.id, sendID: send.id)).outputVolume
        // Direct busA@unity (0.5) + send 0.5 → busB@unity (0.25) = amp 0.75.
        let bounceRMS = TestSignals.rms(channelData[0], in: 30_000..<46_000)
        let cycleRMS = TestSignals.rms(channelData[0], in: 54_000..<70_000)
        // From-scratch reference over the same beats (cold start, send wired
        // before the first pull) — both paths must match it.
        let reference = try OfflineRenderer().render(
            tracks: [after] + buses, tempoBPM: 120,
            fromBeat: 1.0, durationSeconds: 0.5
        )
        let referenceRMS = TestSignals.rms(reference.channelData[0], in: 6_000..<22_000)
        let expected = Self.baselineRMS * 1.5
        print("[measured] mid-run send add: bounce-resume RMS \(bounceRMS), "
              + "transport-cycle RMS \(cycleRMS), cold-start reference RMS \(referenceRMS) "
              + "(expected \(expected) ± 2%), gain outputVolume \(gainVolume)")
        #expect(gainVolume == 0.5)
        #expect(abs(bounceRMS - expected) < 0.02 * expected)
        #expect(abs(cycleRMS - expected) < 0.02 * expected)
        #expect(abs(referenceRMS - expected) < 0.02 * expected)
        #expect(abs(bounceRMS - cycleRMS) < 0.005 * expected)
        #expect(abs(bounceRMS - referenceRMS) < 0.005 * expected)
    }

    /// Live BUG regression (offline analog): removing a bus SEGFAULTed the
    /// running app. Pins reconcile's teardown order in one {bus + routed
    /// track} → {no bus, rerouted track} pass: the source mixer's old fan-out
    /// is severed BEFORE anything detaches, the removed bus mixer leaves the
    /// engine, the surviving send gets a fresh wired gain, and no connection
    /// point still references the dead bus. The render-thread crash itself is
    /// only provable live.
    @Test("mid-run bus removal leaves no dangling connections")
    func busRemovalMidRunLeavesNoDanglingConnections() throws {
        let fixtures = try TestSignals.fixtures()
        let busA = UUID()
        let busB = UUID()
        let send = Send(destinationBusID: busB, level: 0.5)
        let routed = sourceTrack(clip: fixtures.cos1k48, outputBusID: busA,
                                 sends: [send])
        // Post-deletion shape exactly as ProjectStore produces it: output
        // rerouted to master, the send to the SURVIVING bus kept.
        var rerouted = routed
        rerouted.outputBusID = nil
        let withBuses = [routed, bus(busA, name: "A"), bus(busB, name: "B")]
        let afterRemoval = [rerouted, bus(busB, name: "B")]

        let (engine, graph) = try makeManualEngine()
        #expect(graph.reconcile(tracks: withBuses))
        graph.applyParameters(tracks: withBuses)
        try engine.start()
        graph.applyParameters(tracks: withBuses)
        graph.scheduleAll(fromBeat: 0, tempoBPM: 120)
        graph.startAllPlayers(at: nil)
        var channelData: [[Float]] = [[], []]
        try pull(engine, frames: 24_000, into: &channelData)

        let oldGain = try #require(graph.sendGainNode(forTrack: routed.id, sendID: send.id))
        let deadBusMixer = try #require(graph.busMixerNode(forBus: busA))

        // The bug-2 pass, mid-run (manual rendering; the graph's own ordering
        // must hold even without the live engine bounce).
        #expect(graph.reconcile(tracks: afterRemoval))
        graph.applyParameters(tracks: afterRemoval)

        #expect(graph.busMixerNode(forBus: busA) == nil)
        #expect(deadBusMixer.engine == nil)          // detached, not orphaned
        #expect(oldGain.engine == nil)               // old gain fully torn down
        let newGain = try #require(graph.sendGainNode(forTrack: rerouted.id, sendID: send.id))
        #expect(newGain !== oldGain)
        let mixer = try #require(graph.sourceMixerNode(forTrack: rerouted.id))
        let points = engine.outputConnectionPoints(for: mixer, outputBus: 0)
        #expect(points.count == 2)                   // master + surviving send gain
        #expect(points.contains { $0.node === engine.mainMixerNode })
        #expect(points.contains { $0.node === newGain })
        #expect(!points.contains { $0.node === deadBusMixer })

        // Keeps rendering, and the surviving send still sums: direct master
        // (0.5) + send 0.5 → busB@unity (0.25) = amp 0.75.
        graph.stopAllPlayers()
        graph.scheduleAll(fromBeat: 1.0, tempoBPM: 120)
        graph.startAllPlayers(at: nil)
        try pull(engine, frames: 24_000, into: &channelData)
        engine.stop()
        let rms = TestSignals.rms(channelData[0], in: 30_000..<46_000)
        let expected = Self.baselineRMS * 1.5
        print("[measured] mid-run bus removal: post-change RMS \(rms) (expected \(expected) ± 2%)")
        #expect(abs(rms - expected) < 0.02 * expected)
    }

    /// Pins the live-bounce trigger semantics: the hook must fire for every
    /// routing-topology mutation (rewire, send add, bus removal, routed-track
    /// teardown) and must NEVER fire for unfed bus adds, trivial fresh
    /// tracks, no-op passes, or — critically — send LEVEL changes (a fader
    /// drag must not bounce the engine).
    @Test("routing-rewire hook fires only for non-trivial topology changes")
    func routingRewireHookFiresOnlyForNonTrivialChanges() throws {
        let fixtures = try TestSignals.fixtures()
        let busA = UUID()
        let busB = UUID()
        let (_, graph) = try makeManualEngine()
        var fired = 0
        graph.willMutateRoutingTopology = { fired += 1 }

        let trivial = sourceTrack(clip: fixtures.cos1k48)
        graph.reconcile(tracks: [trivial])
        #expect(fired == 0)                          // fresh trivial track

        graph.reconcile(tracks: [trivial, bus(busA), bus(busB)])
        #expect(fired == 0)                          // unfed bus adds

        var routed = trivial
        routed.outputBusID = busA
        graph.reconcile(tracks: [routed, bus(busA), bus(busB)])
        #expect(fired == 1)                          // output rewire

        graph.reconcile(tracks: [routed, bus(busA), bus(busB)])
        #expect(fired == 1)                          // no-op pass

        var withSend = routed
        let send = Send(destinationBusID: busB, level: 1)
        withSend.sends = [send]
        graph.reconcile(tracks: [withSend, bus(busA), bus(busB)])
        #expect(fired == 2)                          // send added

        var levelOnly = withSend
        levelOnly.sends[0].level = 0.25
        graph.reconcile(tracks: [levelOnly, bus(busA), bus(busB)])
        #expect(fired == 2)                          // send LEVEL: never fires

        var offBusA = levelOnly
        offBusA.outputBusID = nil
        graph.reconcile(tracks: [offBusA, bus(busB)])
        #expect(fired == 3)                          // bus removal + rewire

        graph.reconcile(tracks: [bus(busB)])
        #expect(fired == 4)                          // routed-track teardown
    }
}
