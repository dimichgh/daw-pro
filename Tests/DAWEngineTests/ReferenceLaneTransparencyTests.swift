import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// m22-g P2 gates (design-m22g-reference-tracks §9):
//
//  · T7 — THE load-bearing transparency gate: the same representative
//    session manual-rendered through a lane-OFF vs lane-ON graph (reference
//    silent, gate open) must be BYTE-IDENTICAL — every float of every
//    frame, bit-pattern compared (distinguishes −0.0 from +0.0, per the
//    §5.7 zero-sign wrinkle: any delta, including signed-zero-only, is a
//    STOP-AND-REPORT, never a self-approved escape). The A/B rig is the
//    REAL production render loop both times (`OfflineRenderer.render`),
//    the m13-d C0 idiom; the lane seam on OfflineRenderer exists for THIS
//    gate only and defaults false in every production path.
//  · Lane pins — default-false fail-safe on both graph and renderer;
//    lane-on topology (gate/sum/player/gain wiring, outputNode fed by
//    monitorSum, single-creation-site idempotence, zero announces, zero
//    rebuild debt); lane-off graphs keep the exact historic shape.
//  · D8 (meter-reads-mix) — the live engine's master tap stays on the
//    CHAIN HOST, upstream of the gate, with the lane present.
//  · T8 — LEVEL-MATCH HONESTY (the roadmap gate): the store-computed
//    `matchGainDb` applied to real samples and re-measured through the
//    REAL `Loudness.measure` lands on the basis within 0.2 LU; the
//    ceiling-clamped case measures ≤ −1.0 dBTP.
//  · D6 mapping — reference file time across a multi-segment tempo map is
//    the control-plane integral (the m22-f law), pinned exactly.
//  · Live smoke (liveSmoke idiom, headless machines return early) — arm
//    while stopped (no schedule), roll-start schedule with the exact
//    deferred-start split and the D7 PDC anchor delay, mid-play offset
//    re-anchor, toggle-off ledger clear.

@MainActor
@Suite("Reference monitor lane — T7/T8 gates (m22-g P2)", .serialized)
struct ReferenceLaneTransparencyTests {

    // MARK: - Representative session (the m13-d C0 session, verbatim shape)

    /// audio ("Gtr": EQ + limiter inserts, send → bus) + audio ("Bass",
    /// panned) + instrument ("Keys", poly synth notes) + bus ("FXBus",
    /// delay) — non-unity master fader applied by the caller: every summing
    /// shape the byte anchors exercise.
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

    private func render(lane: Bool, tracks: [Track]) throws -> RenderedAudio {
        let renderer = OfflineRenderer()
        renderer.referenceLaneEnabled = lane
        return try renderer.render(
            tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, durationSeconds: 1.5, masterVolume: 0.85,
            masterEffects: [])
    }

    /// Bit-pattern equality: byte-identical, stricter than Float `==`
    /// (distinguishes −0.0 from +0.0 — the §5.7 wrinkle is DETECTED, never
    /// silently absorbed).
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

    // MARK: - T7: the transparency measurement

    @Test("T7: lane-off vs lane-on render of the representative session is BYTE-IDENTICAL (reference silent)")
    func laneIsBitTransparent() throws {
        let tracks = try representativeSession()

        // Baseline determinism first (the m12-a rule): the comparison only
        // means something if the lane-off shape reproduces itself.
        let off1 = try render(lane: false, tracks: tracks)
        let off2 = try render(lane: false, tracks: tracks)
        let offDeterminism = bitIdentical(off1, off2)
        try #require(offDeterminism.identical,
                     "lane-off shape not deterministic: \(offDeterminism.firstDiff)")

        // THE measurement: production shape vs lane-on (gate open, player
        // never scheduled — the exact live null state).
        let on = try render(lane: true, tracks: tracks)
        let verdict = bitIdentical(off1, on)

        // Real audio on both sides — never two agreeing silences.
        let frames = off1.channelData[0].count
        let offRMS = TestSignals.rms(off1.channelData[0], in: 0..<frames)
        print("[measured] T7 lane transparency over \(frames) frames × "
              + "\(off1.channelData.count) ch: byte-identical \(verdict.identical) "
              + "(first diff: \(verdict.firstDiff)); lane-off ch0 RMS \(offRMS)")
        #expect(offRMS > 0.05)
        #expect(verdict.identical,
                "monitor lane not bit-transparent: \(verdict.firstDiff)")

        // And the lane-on build is deterministic in its own right.
        let on2 = try render(lane: true, tracks: tracks)
        #expect(bitIdentical(on, on2).identical)
    }

    @Test("T7 fail-safe pins: the lane flag defaults FALSE on graph and renderer alike")
    func laneDefaultsOff() {
        #expect(PlaybackGraph(engine: AVAudioEngine()).referenceLaneEnabled == false)
        #expect(OfflineRenderer().referenceLaneEnabled == false)
    }

    // MARK: - Lane topology pins (the m13-d R1 idiom)

    private func makeManualEngine(lane: Bool) throws -> (AVAudioEngine, PlaybackGraph) {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        graph.referenceLaneEnabled = lane
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format,
                                             maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        return (engine, graph)
    }

    @Test("lane-on topology: chainHost → gate → sum → output plus player → gain → sum; idempotent, zero announces, zero rebuild debt")
    func laneTopology() throws {
        let (engine, graph) = try makeManualEngine(lane: true)
        var announces = 0
        graph.willMutateRoutingTopology = { announces += 1 }

        graph.reconcile(tracks: [])
        let chainHost = try #require(graph.masterChainHost)
        let gate = try #require(graph.mixMonitorGate)
        let sum = try #require(graph.monitorSum)
        let player = try #require(graph.referencePlayer)
        let gain = try #require(graph.referenceGain)
        #expect(!graph.needsEngineRebuild)
        #expect(announces == 0)

        // Wiring: output is fed by the SUM (the single-input-bus law), the
        // gate by the chain host (bus 0), the gain by the player, the sum by
        // gate (bus 0) + gain (bus 1).
        #expect(engine.inputConnectionPoint(for: engine.outputNode, inputBus: 0)?.node === sum)
        #expect(engine.inputConnectionPoint(for: gate, inputBus: 0)?.node === chainHost)
        #expect(engine.inputConnectionPoint(for: sum, inputBus: 0)?.node === gate)
        #expect(engine.inputConnectionPoint(for: sum, inputBus: 1)?.node === gain)
        #expect(engine.inputConnectionPoint(for: gain, inputBus: 0)?.node === player)

        // Defaults: mix audible, unity everywhere, ledger down.
        #expect(gate.outputVolume == 1)
        #expect(gain.outputVolume == 1)
        #expect(sum.outputVolume == 1)
        #expect(graph.referenceScheduled == false)

        // Param-class control writes land on the nodes.
        graph.setMixMonitorGate(open: false)
        #expect(gate.outputVolume == 0)
        graph.setMixMonitorGate(open: true)
        #expect(gate.outputVolume == 1)
        graph.setReferenceMonitorGain(linear: 0.5)
        #expect(gain.outputVolume == 0.5)

        // Idempotent single creation site: node identities stable across
        // further sandwich calls + reconciles, still zero announces.
        graph.ensureMasterSandwich()
        graph.reconcile(tracks: [Track(name: "A", kind: .audio)])
        #expect(graph.mixMonitorGate === gate)
        #expect(graph.monitorSum === sum)
        #expect(graph.referencePlayer === player)
        #expect(graph.referenceGain === gain)
        #expect(!graph.needsEngineRebuild)
        #expect(announces == 0)

        // Ledger-gated no-ops: stop with nothing scheduled is free and the
        // restart seam (stopAllPlayers) leaves the ledger down.
        graph.stopReference()
        graph.stopAllPlayers()
        #expect(graph.referenceScheduled == false)
    }

    @Test("lane-off graphs keep the exact historic shape: chainHost feeds outputNode directly, no lane nodes exist")
    func laneOffShapeUnchanged() throws {
        let (engine, graph) = try makeManualEngine(lane: false)
        graph.reconcile(tracks: [])
        let chainHost = try #require(graph.masterChainHost)
        #expect(engine.inputConnectionPoint(for: engine.outputNode, inputBus: 0)?.node === chainHost)
        #expect(graph.mixMonitorGate == nil)
        #expect(graph.monitorSum == nil)
        #expect(graph.referencePlayer == nil)
        #expect(graph.referenceGain == nil)
        // Monitor controls are inert no-ops without the lane.
        graph.setMixMonitorGate(open: false)
        graph.setReferenceMonitorGain(linear: 0.25)
        let file = try dummyFile()
        #expect(graph.scheduleReference(
            file: file, fileStartSeconds: 0, playerDelaySeconds: 0) == false)
    }

    /// Minimal real audio file for the schedule-refusal pin above.
    private func dummyFile() throws -> AVAudioFile {
        try AVAudioFile(forReading: TestSignals.fixtures().cos1k48)
    }

    // MARK: - T8: level-match honesty (the roadmap gate — real Loudness math)

    /// Stereo sine program at `amplitude`, 48 kHz.
    private func sineProgram(amplitude: Float, seconds: Double) -> RenderedAudio {
        let rate = 48_000.0
        let frames = Int(rate * seconds)
        var channel = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            channel[i] = amplitude * Float(sin(2.0 * .pi * 997.0 * Double(i) / rate))
        }
        return RenderedAudio(sampleRate: rate, channelData: [channel, channel])
    }

    private func applied(gainDb: Double, to audio: RenderedAudio) -> RenderedAudio {
        let linear = Float(pow(10, gainDb / 20))
        return RenderedAudio(
            sampleRate: audio.sampleRate,
            channelData: audio.channelData.map { channel in channel.map { $0 * linear } })
    }

    @Test("T8: gained reference re-measured through Loudness.measure lands on the live basis within 0.2 LU")
    func levelMatchHonestyLiveBasis() throws {
        let program = sineProgram(amplitude: 0.125, seconds: 6)
        let ref = Loudness.measure(program)
        let refLufs = try #require(ref.integratedLufs)
        let basis = -16.0
        let match = ReferenceLevelMatch.compute(
            mixIntegratedLufs: basis, refIntegratedLufs: refLufs,
            refTruePeakDbtp: ref.truePeakDbtp, trimDb: 0)
        #expect(match.matchBasis == "liveIntegrated")
        #expect(match.ceilingLimited == false)

        let gained = Loudness.measure(applied(gainDb: match.matchGainDb, to: program))
        let achieved = try #require(gained.integratedLufs)
        print("[measured] T8 live basis: ref \(refLufs) LUFS, gain \(match.matchGainDb) dB, "
              + "achieved \(achieved) LUFS vs basis \(basis)")
        #expect(abs(achieved - basis) <= 0.2)
    }

    @Test("T8: no mix reading → the −14 LUFS fallback basis, measured end-to-end")
    func levelMatchHonestyFallbackBasis() throws {
        let program = sineProgram(amplitude: 0.125, seconds: 6)
        let ref = Loudness.measure(program)
        let refLufs = try #require(ref.integratedLufs)
        let match = ReferenceLevelMatch.compute(
            mixIntegratedLufs: nil, refIntegratedLufs: refLufs,
            refTruePeakDbtp: ref.truePeakDbtp, trimDb: 0)
        #expect(match.matchBasis == "fallbackTarget")
        #expect(match.ceilingLimited == false)

        let gained = Loudness.measure(applied(gainDb: match.matchGainDb, to: program))
        let achieved = try #require(gained.integratedLufs)
        print("[measured] T8 fallback basis: ref \(refLufs) LUFS, gain \(match.matchGainDb) dB, "
              + "achieved \(achieved) LUFS vs −14")
        #expect(abs(achieved - ReferenceLevelMatch.fallbackTargetLufs) <= 0.2)
    }

    @Test("T8: ceiling clamp — matching UP stops at −1.0 dBTP exactly, measured on the gained audio")
    func levelMatchHonestyCeilingClamp() throws {
        // Loud-ish reference (≈ −3 dBTP) asked to match a much louder basis.
        let program = sineProgram(amplitude: 0.708, seconds: 6)
        let ref = Loudness.measure(program)
        let refLufs = try #require(ref.integratedLufs)
        let refTP = try #require(ref.truePeakDbtp)
        let basis = refLufs + 8  // requested +8 dB — far past the headroom
        let match = ReferenceLevelMatch.compute(
            mixIntegratedLufs: basis, refIntegratedLufs: refLufs,
            refTruePeakDbtp: refTP, trimDb: 0)
        #expect(match.ceilingLimited == true)
        // The clamp law exactly: refTP + gain == −1.0.
        #expect(abs((refTP + match.matchGainDb) - ReferenceLevelMatch.ceilingDbtp) < 1e-12)

        let gained = Loudness.measure(applied(gainDb: match.matchGainDb, to: program))
        let gainedTP = try #require(gained.truePeakDbtp)
        print("[measured] T8 ceiling: ref TP \(refTP) dBTP, clamped gain \(match.matchGainDb) dB, "
              + "gained TP \(gainedTP) dBTP (ceiling −1.0)")
        // Re-measured true peak honors the ceiling (float re-measure slack
        // only — the law itself is exact above).
        #expect(gainedTP <= ReferenceLevelMatch.ceilingDbtp + 0.05)
        #expect(gainedTP >= ReferenceLevelMatch.ceilingDbtp - 0.5)
    }

    // MARK: - D6 mapping law across a tempo change (control-plane integrals)

    @Test("reference file time across a multi-segment map is the exact tempo integral plus offset")
    func offsetMappingAcrossTempoChange() throws {
        // 120 BPM for beats [0, 8) — 0.5 s/beat, then 60 BPM — 1 s/beat.
        let map = try TempoMap(segments: [
            TempoMap.Segment(startBeat: 0, bpm: 120),
            TempoMap.Segment(startBeat: 8, bpm: 60),
        ])
        // Beat 12 = 8·0.5 + 4·1 = 8 s of timeline.
        #expect(AudioEngine.referenceFileSeconds(
            atBeat: 12, tempoMap: map, offsetSeconds: 0) == 8.0)
        #expect(AudioEngine.referenceFileSeconds(
            atBeat: 12, tempoMap: map, offsetSeconds: 2.5) == 10.5)
        // Inside the first segment the second segment never leaks.
        #expect(AudioEngine.referenceFileSeconds(
            atBeat: 4, tempoMap: map, offsetSeconds: 0) == 2.0)
        // Negative offset defers: beat 0 maps to file time −5 (the caller
        // splits that into fileStart 0 + playerDelay 5).
        #expect(AudioEngine.referenceFileSeconds(
            atBeat: 0, tempoMap: map, offsetSeconds: -5) == -5.0)
    }

    // MARK: - Live smoke (liveSmoke idiom — headless machines return early)

    /// Writes a 10 s stereo sine .caf for the live reference player.
    private func writeReferenceFixture() throws -> URL {
        let rate = 48_000.0
        let frames = Int(rate * 10)
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<frames {
            let sample = 0.1 * Float(sin(2.0 * .pi * 440.0 * Double(frame) / rate))
            channels[0][frame] = sample
            channels[1][frame] = sample
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("m22g-ref-\(UUID().uuidString).caf")
        try autoreleasepool {
            let writer = try AVAudioFile(forWriting: url, settings: format.settings,
                                         commonFormat: .pcmFormatFloat32, interleaved: false)
            try writer.write(from: buffer)
        }
        return url
    }

    @Test("live smoke: stopped arm → roll-start schedule (deferred start + D7 latency delay) → mid-play offset re-anchor → off")
    func liveMonitorScheduleSmoke() async throws {
        let engine = AudioEngine()
        do {
            try engine.prepare()
        } catch {
            return  // headless machine without an output device
        }
        defer { engine.shutdown() }

        // A limiter strip gives the session real PDC latency (240-sample
        // lookahead — the masterChainEditIsNeverTopology figure), so the D7
        // anchor delay is a NON-ZERO measured quantity here.
        let fixtures = try TestSignals.fixtures()
        let track = Track(name: "L", kind: .audio,
                          clips: [Clip(name: "c", startBeat: 0, lengthBeats: 8,
                                       audioFileURL: fixtures.cos1k48)],
                          effects: [EffectDescriptor(kind: .limiter)])
        engine.tracksDidChange([track])
        let report = try #require(engine.pdcReport())
        #expect(report.outputLatencySamples == 240)

        // D8 pin: with the lane present, the master tap rides the CHAIN
        // HOST — upstream of the gate: meters keep reading the MIX while B
        // is engaged (the level-match basis survives auditioning).
        #expect(engine.graph.mixMonitorGate != nil)
        #expect(engine.meterTapNodeForTesting === engine.graph.masterChainHost)

        let refURL = try writeReferenceFixture()
        defer { try? FileManager.default.removeItem(at: refURL) }
        let slot = ReferenceSlot(name: "ref", sourcePath: refURL.path,
                                 offsetSeconds: -5)
        engine.referenceChanged(slot)

        // Arm while STOPPED: monitor state + gate land, but nothing is
        // scheduled (schedules are monitor-gated AND transport-gated).
        try engine.setReferenceMonitor(on: true, matchGainDb: -6)
        #expect(engine.referenceMonitoringForTesting == true)
        #expect(engine.referenceScheduledForTesting == false)
        #expect(engine.graph.mixMonitorGate?.outputVolume == 0)
        let expectedLinear = Float(pow(10, -6.0 / 20))
        let appliedLinear = try #require(engine.graph.referenceGain?.outputVolume)
        #expect(abs(appliedLinear - expectedLinear) < 1e-6)

        // Roll start from beat 0: mapping is exact — file time −5 splits
        // into fileStart 0 + playerDelay 5; the anchor carries the D7
        // latency delay (240 samples at the graph rate).
        var transport = TransportState()
        transport.isPlaying = true
        engine.startPlayback(transport)
        #expect(engine.referenceScheduledForTesting == true)
        let sched = try #require(engine.lastReferenceScheduleForTesting)
        #expect(sched.fileStartSeconds == 0)
        #expect(sched.playerDelaySeconds == 5)
        let graphRate = engine.graph.graphSampleRate
        #expect(abs(sched.latencySeconds - 240.0 / graphRate) < 1e-12)

        // Mid-play offset change → player-local re-anchor at the newly
        // mapped position: fileStart = timeline(W) + 1 ≥ 1, no deferral.
        engine.referenceChanged(ReferenceSlot(
            id: slot.id, name: "ref", sourcePath: refURL.path, offsetSeconds: 1))
        #expect(engine.referenceScheduledForTesting == true)
        let resched = try #require(engine.lastReferenceScheduleForTesting)
        #expect(resched.fileStartSeconds >= 1.0)
        #expect(resched.playerDelaySeconds == 0)

        // Toggle OFF: player-local stop (ledger down), mix un-gates — the
        // transport itself never moved (still anchored/playing).
        try engine.setReferenceMonitor(on: false, matchGainDb: 0)
        #expect(engine.referenceMonitoringForTesting == false)
        #expect(engine.referenceScheduledForTesting == false)
        #expect(engine.graph.mixMonitorGate?.outputVolume == 1)

        engine.stopPlayback()
    }
}
