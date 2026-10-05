import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (ii) insert-chain proof, rendered offline through the same
/// `PlaybackGraph` the live engine uses. The gain effect's output is exactly
/// assertable (×0.5 / ×2 are exact Float multiplies), so chain math, order,
/// bypass, and the never-structural rule all pin bit-exact.
/// 48 kHz, 120 BPM; amp-0.5 cosine fixture → steady-window RMS 0.3536.
@MainActor
@Suite("Effect chains — offline render", .serialized)
struct EffectChainRenderTests {
    private static let window = 12_000..<36_000
    private static let baselineRMS: Float = 0.3536

    // MARK: - Test-only effects

    /// Hard clipper at ±limit — order-sensitive against gain, which is what
    /// makes `chainOrderAppliesEffectsSequentially` provable.
    private final class ClipEffect: EffectRendering, @unchecked Sendable {
        let limit: Float
        init(limit: Float) { self.limit = limit }
        func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
        func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
                for frame in 0..<frames {
                    data[frame] = max(-limit, min(limit, data[frame]))
                }
            }
        }
        func reset() {}
        var latencySamples: Int { 0 }
    }

    /// Writes a DC constant — proves the walk RAN (a gain on silence would
    /// still be silence).
    private final class DCProbeEffect: EffectRendering, @unchecked Sendable {
        let value: Float
        init(value: Float) { self.value = value }
        func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
        func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
            for buffer in buffers {
                guard let data = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                let frames = min(frameCount, Int(buffer.mDataByteSize) / MemoryLayout<Float>.stride)
                for frame in 0..<frames { data[frame] = value }
            }
        }
        func reset() {}
        var latencySamples: Int { 0 }
    }

    /// Records the walk's calls in order — pins reset-before-process.
    private final class SequenceProbeEffect: EffectRendering, @unchecked Sendable {
        var calls: [String] = []  // test-thread-only (synchronous walks)
        func prepare(sampleRate: Double, maxFramesPerQuantum: Int, channelCount: Int) {}
        func process(buffers: UnsafeMutableAudioBufferListPointer, frameCount: Int) {
            calls.append("process")
        }
        func reset() { calls.append("reset") }
        var latencySamples: Int { 0 }
    }

    // MARK: - Helpers

    private func gainFX(_ gain: Double, id: UUID = UUID(),
                        bypassed: Bool = false) -> EffectDescriptor {
        EffectDescriptor(id: id, kind: .gain, isBypassed: bypassed,
                         gain: GainParams(gainLinear: gain))
    }

    private func audioTrack(clip url: URL, volume: Double = 1,
                            outputBusID: UUID? = nil, sends: [Send] = [],
                            effects: [EffectDescriptor] = []) -> Track {
        Track(name: "SRC", kind: .audio, volume: volume,
              clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4,
                           audioFileURL: url)],
              outputBusID: outputBusID, sends: sends, effects: effects)
    }

    private func render(_ tracks: [Track], seconds: Double = 1.0) throws -> RenderedAudio {
        try OfflineRenderer().render(tracks: tracks, tempoMap: TempoMap(constantBPM: 120),
                                     fromBeat: 0, durationSeconds: seconds)
    }

    /// max |a − scale·b| over both channels.
    private func maxScaledDifference(_ a: RenderedAudio, _ b: RenderedAudio,
                                     scale: Float = 1) -> Float {
        var maxDiff: Float = 0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            let lhs = a.channelData[channel]
            let rhs = b.channelData[channel]
            for frame in 0..<min(lhs.count, rhs.count) {
                maxDiff = max(maxDiff, abs(lhs[frame] - scale * rhs[frame]))
            }
        }
        return maxDiff
    }

    /// Constant-filled stereo buffer for direct processor walks.
    private func makeConstantBuffer(_ value: Float, frames: Int) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<frames { channels[channel][frame] = value }
        }
        return buffer
    }

    // MARK: - Chain math (exact)

    @Test("gain 0.5 insert multiplies known samples exactly")
    func gainEffectMultipliesKnownSamplesExactly() throws {
        let fixtures = try TestSignals.fixtures()
        let dry = try render([audioTrack(clip: fixtures.cos1k48)])
        let wet = try render([audioTrack(clip: fixtures.cos1k48,
                                         effects: [gainFX(0.5)])])
        let dryPeak = TestSignals.peak(dry.channelData[0], in: Self.window)
        let maxDiff = maxScaledDifference(wet, dry, scale: 0.5)
        print("[measured] gain 0.5 insert: max |wet − 0.5·dry| = \(maxDiff), dry peak \(dryPeak)")
        #expect(dryPeak > 0.45)  // real signal, not silence-vs-silence
        #expect(maxDiff == 0)
    }

    @Test("gain 2.0 then gain 0.5 compose multiplicatively — nulls against dry")
    func twoGainStagesComposeMultiplicatively() throws {
        let fixtures = try TestSignals.fixtures()
        let dry = try render([audioTrack(clip: fixtures.cos1k48)])
        let wet = try render([audioTrack(clip: fixtures.cos1k48,
                                         effects: [gainFX(2.0), gainFX(0.5)])])
        let maxDiff = maxScaledDifference(wet, dry)
        print("[measured] 2.0 × 0.5 chain null: max |wet − dry| = \(maxDiff)")
        #expect(TestSignals.peak(dry.channelData[0], in: Self.window) > 0.45)
        #expect(maxDiff == 0)
    }

    @Test("chain order is sequential: gain→clip ≠ clip→gain, both exact")
    func chainOrderAppliesEffectsSequentially() throws {
        // Direct processor walk with a test-only clipper: constant 0.5 input.
        //   gain 2 → clip 0.6:  0.5 → 1.0 → 0.6
        //   clip 0.6 → gain 2:  0.5 → 0.5 → 1.0
        func walk(order: [any EffectRendering]) throws -> Float {
            let processor = EffectChainProcessor()
            var units = ContiguousArray<ChainEffectUnit>()
            for instance in order {
                instance.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
                units.append(ChainEffectUnit(id: UUID(), kind: .gain,
                                             instance: instance, isBypassed: false))
            }
            processor.publish(EffectChainSnapshot(units: units))
            let buffer = try makeConstantBuffer(0.5, frames: 512)
            processor.process(bufferList: buffer.mutableAudioBufferList, frameCount: 512)
            let channels = try #require(buffer.floatChannelData)
            // Every frame identical by construction — spot the first, verify the last.
            #expect(channels[0][511] == channels[0][0])
            #expect(channels[1][0] == channels[0][0])
            return channels[0][0]
        }
        let gainThenClip = try walk(order: [GainEffect(params: GainParams(gainLinear: 2)),
                                            ClipEffect(limit: 0.6)])
        let clipThenGain = try walk(order: [ClipEffect(limit: 0.6),
                                            GainEffect(params: GainParams(gainLinear: 2))])
        print("[measured] chain order: gain→clip = \(gainThenClip), clip→gain = \(clipThenGain)")
        #expect(gainThenClip == 0.6)
        #expect(clipThenGain == 1.0)
        #expect(gainThenClip != clipThenGain)
    }

    @Test("a bypassed effect renders a bit-exact null against dry")
    func bypassedEffectRendersBitExactNull() throws {
        let fixtures = try TestSignals.fixtures()
        let dry = try render([audioTrack(clip: fixtures.cos1k48)])
        let wet = try render([audioTrack(clip: fixtures.cos1k48,
                                         effects: [gainFX(0.25, bypassed: true)])])
        let maxDiff = maxScaledDifference(wet, dry)
        print("[measured] bypassed insert null: max |wet − dry| = \(maxDiff)")
        #expect(TestSignals.peak(dry.channelData[0], in: Self.window) > 0.45)
        #expect(maxDiff == 0)
    }

    // MARK: - Sandwich transparency

    @Test("empty chains are bit-exact transparent on audio and bus strips")
    func emptyChainIsBitExactTransparent() throws {
        let fixtures = try TestSignals.fixtures()
        // Audio strip: the full sandwich (players → sumMixer → chainHost →
        // mixer) with no effects must reproduce the source file bit-exact.
        let rendered = try render([audioTrack(clip: fixtures.cos1k48)])
        let source = try TestSignals.readFile(fixtures.cos1k48)
        var audioDiff: Float = 0
        for channel in 0..<2 {
            for frame in 0..<48_000 {
                audioDiff = max(audioDiff,
                                abs(rendered.channelData[channel][frame] - source[channel][frame]))
            }
        }
        print("[measured] empty-chain audio sandwich vs source file: max diff = \(audioDiff)")
        #expect(audioDiff == 0)

        // Bus strip: routing through a no-effects bus (double sandwich) must
        // null against the master-routed render.
        let busID = UUID()
        let routed = try render([audioTrack(clip: fixtures.cos1k48, outputBusID: busID),
                                 Track(id: busID, name: "Bus", kind: .bus)])
        let busDiff = maxScaledDifference(routed, rendered)
        print("[measured] empty-chain bus sandwich null: max diff = \(busDiff)")
        #expect(busDiff == 0)
    }

    // MARK: - All strip kinds process

    @Test("instrument, audio, and bus chains all process (incl. the silence path)")
    func instrumentAudioAndBusChainsAllProcess() throws {
        let fixtures = try TestSignals.fixtures()

        // Instrument strip: chain runs inside the renderer, zero extra nodes.
        let midiClip = Clip(name: "midi", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 69, velocity: 127, startBeat: 0, lengthBeats: 2),
        ])
        func instrumentTrack(effects: [EffectDescriptor]) -> Track {
            Track(name: "Keys", kind: .instrument, clips: [midiClip],
                  instrument: InstrumentDescriptor(kind: .testTone), effects: effects)
        }
        let instDry = try render([instrumentTrack(effects: [])])
        let instWet = try render([instrumentTrack(effects: [gainFX(0.5)])])
        let instDiff = maxScaledDifference(instWet, instDry, scale: 0.5)
        print("[measured] instrument chain ×0.5: max |wet − 0.5·dry| = \(instDiff)")
        #expect(TestSignals.peak(instDry.channelData[0], in: Self.window) > 0.2)
        #expect(instDiff == 0)

        // Audio strip: chain runs inside the ChainHostAU sandwich.
        let audioDry = try render([audioTrack(clip: fixtures.cos1k48)])
        let audioWet = try render([audioTrack(clip: fixtures.cos1k48,
                                              effects: [gainFX(0.5)])])
        let audioDiff = maxScaledDifference(audioWet, audioDry, scale: 0.5)
        print("[measured] audio chain ×0.5: max |wet − 0.5·dry| = \(audioDiff)")
        #expect(audioDiff == 0)

        // Bus strip: chain sits between the bus sum and the bus fader.
        let busID = UUID()
        let busWet = try render([audioTrack(clip: fixtures.cos1k48, outputBusID: busID),
                                 Track(id: busID, name: "Bus", kind: .bus,
                                       effects: [gainFX(0.5)])])
        let busDiff = maxScaledDifference(busWet, audioDry, scale: 0.5)
        print("[measured] bus chain ×0.5: max |wet − 0.5·master| = \(busDiff)")
        #expect(busDiff == 0)

        // Silence path: with no schedule published, a non-empty chain still
        // processes every quantum (tails must ring) and the quantum is NOT
        // reported silent. The DC probe proves the walk actually ran.
        let renderer = InstrumentRenderer(instrument: TestToneInstrument(), sampleRate: 48_000)
        let probe = DCProbeEffect(value: 0.25)
        renderer.chain.publish(EffectChainSnapshot(units: [
            ChainEffectUnit(id: UUID(), kind: .gain, instance: probe, isBypassed: false),
        ]))
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        buffer.frameLength = 512
        var timestamp = AudioTimeStamp()
        timestamp.mSampleTime = 0
        timestamp.mFlags = .sampleTimeValid
        var silence = ObjCBool(true)
        let status = renderer.renderQuantum(
            timestamp: &timestamp, frameCount: 512,
            audioBufferList: buffer.mutableAudioBufferList, isSilence: &silence)
        #expect(status == noErr)
        #expect(!silence.boolValue)
        let channels = try #require(buffer.floatChannelData)
        #expect(channels[0][0] == 0.25 && channels[0][511] == 0.25)
        // And with NO chain published, the silence path stays silent.
        let bare = InstrumentRenderer(instrument: TestToneInstrument(), sampleRate: 48_000)
        var bareSilence = ObjCBool(false)
        _ = bare.renderQuantum(timestamp: &timestamp, frameCount: 512,
                               audioBufferList: buffer.mutableAudioBufferList,
                               isSilence: &bareSilence)
        #expect(bareSilence.boolValue)
    }

    @Test("a bus chain processes send returns (direct path killed)")
    func busChainProcessesSendReturns() throws {
        let fixtures = try TestSignals.fixtures()
        let killBus = UUID()   // direct-path sink at volume 0
        let returnBus = UUID() // unity send return with a ×0.5 chain
        let master = try render([audioTrack(clip: fixtures.cos1k48)])
        let wet = try render([
            audioTrack(clip: fixtures.cos1k48, outputBusID: killBus,
                       sends: [Send(destinationBusID: returnBus, level: 1)]),
            Track(id: killBus, name: "Kill", kind: .bus, volume: 0),
            Track(id: returnBus, name: "Return", kind: .bus,
                  effects: [gainFX(0.5)]),
        ])
        // Unity send → return sum → chain ×0.5 → unity bus fader = 0.5×master
        // (the kill path contributes exact zeros at volume 0).
        let maxDiff = maxScaledDifference(wet, master, scale: 0.5)
        let rms = TestSignals.rms(wet.channelData[0], in: Self.window)
        let expected = Self.baselineRMS / 2
        print("[measured] send-return bus chain: max |wet − 0.5·master| = \(maxDiff), "
              + "RMS \(rms) (expected \(expected) ± 2%)")
        #expect(maxDiff < 1e-6)
        #expect(abs(rms - expected) < 0.02 * expected)
    }

    // MARK: - Never-structural rule

    /// Manual-rendering engine + graph pair (the BusRoutingRenderTests
    /// harness) for mid-render chain edits and node-identity assertions.
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

    @Test("mid-render chain edits are non-structural: reconcile false, node identity stable, instances survive reorder")
    func chainEditMidRenderIsNonStructural() throws {
        let fixtures = try TestSignals.fixtures()
        let busID = UUID()
        let plain = audioTrack(clip: fixtures.cos1k48, outputBusID: busID)
        let bus = Track(id: busID, name: "Bus", kind: .bus)

        let (engine, graph) = try makeManualEngine()
        var hookFired = 0
        graph.willMutateRoutingTopology = { hookFired += 1 }
        #expect(graph.reconcile(tracks: [plain, bus]))
        #expect(hookFired == 1)  // fresh track wired into the bus (non-trivial)
        graph.applyParameters(tracks: [plain, bus])
        try engine.start()
        graph.applyParameters(tracks: [plain, bus])
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        graph.startAllPlayers(at: nil)
        var channelData: [[Float]] = [[], []]
        try pull(engine, frames: 24_000, into: &channelData)

        // Capture the whole node identity surface before the chain edits.
        let sourceMixer = try #require(graph.sourceMixerNode(forTrack: plain.id))
        let busMixer = try #require(graph.busMixerNode(forBus: busID))
        let trackHost = try #require(graph.chainHostNode(forTrack: plain.id))
        let busHost = try #require(graph.chainHostNode(forTrack: busID))

        // Edit 1 (mid-render): add gain 0.25 to the track and 0.5 to the bus.
        let trackFX = gainFX(0.25)
        let busFX = gainFX(0.5)
        var trackWithFX = plain
        trackWithFX.effects = [trackFX]
        var busWithFX = bus
        busWithFX.effects = [busFX]
        #expect(!graph.reconcile(tracks: [trackWithFX, busWithFX]))  // NOT structural
        #expect(hookFired == 1)                                      // no engine bounce
        graph.applyParameters(tracks: [trackWithFX, busWithFX])
        try pull(engine, frames: 24_000, into: &channelData)

        // Edit 2: add a second track effect (gain 2.0 → chain product 0.5).
        let trackFX2 = gainFX(2.0)
        trackWithFX.effects = [trackFX, trackFX2]
        #expect(!graph.reconcile(tracks: [trackWithFX, busWithFX]))
        graph.applyParameters(tracks: [trackWithFX, busWithFX])
        let unitA = try #require(
            graph.effectChainState(forTrack: plain.id)?.unit(forEffect: trackFX.id))
        let unitB = try #require(
            graph.effectChainState(forTrack: plain.id)?.unit(forEffect: trackFX2.id))
        try pull(engine, frames: 24_000, into: &channelData)

        // Edit 3: REORDER the track chain — gains commute, so the audio is
        // unchanged, but the snapshot order must flip and both INSTANCES
        // must survive (DSP state carries across chain edits).
        trackWithFX.effects = [trackFX2, trackFX]
        #expect(!graph.reconcile(tracks: [trackWithFX, busWithFX]))
        graph.applyParameters(tracks: [trackWithFX, busWithFX])
        #expect(graph.effectChainState(forTrack: plain.id)?
            .unit(forEffect: trackFX.id) === unitA)
        #expect(graph.effectChainState(forTrack: plain.id)?
            .unit(forEffect: trackFX2.id) === unitB)
        let snapshot = try #require(
            graph.effectChainState(forTrack: plain.id)?.processor.currentSnapshot)
        #expect(snapshot.units.map(\.id) == [trackFX2.id, trackFX.id])
        try pull(engine, frames: 24_000, into: &channelData)
        engine.stop()

        // Node identity: the sandwich never rebuilt across any chain edit.
        #expect(graph.sourceMixerNode(forTrack: plain.id) === sourceMixer)
        #expect(graph.busMixerNode(forBus: busID) === busMixer)
        #expect(graph.chainHostNode(forTrack: plain.id) === trackHost)
        #expect(graph.chainHostNode(forTrack: busID) === busHost)
        #expect(hookFired == 1)

        // Gain plateaus (all adoptions exact — fresh instances adopt without
        // ramping): 1.0 → ×0.125 (0.25·0.5) → ×0.25 (0.25·2·0.5) → ×0.25.
        let left = channelData[0]
        let p0 = TestSignals.rms(left, in: 8_000..<22_000)
        let p1 = TestSignals.rms(left, in: 30_000..<46_000)
        let p2 = TestSignals.rms(left, in: 54_000..<70_000)
        let p3 = TestSignals.rms(left, in: 78_000..<94_000)
        print("[measured] chain-edit plateaus: \(p0) → \(p1) → \(p2) → \(p3) "
              + "(expected 0.3536 → 0.0442 → 0.0884 → 0.0884)")
        #expect(abs(p0 - Self.baselineRMS) < 0.02 * Self.baselineRMS)
        #expect(abs(p1 - Self.baselineRMS * 0.125) < 0.02 * Self.baselineRMS * 0.125)
        #expect(abs(p2 - Self.baselineRMS * 0.25) < 0.02 * Self.baselineRMS * 0.25)
        #expect(abs(p3 - Self.baselineRMS * 0.25) < 0.02 * Self.baselineRMS * 0.25)
    }

    @Test("a param change lands in place — same snapshot, same unit, new gain")
    func paramChangeAppliesInPlaceWithoutSnapshotRepublish() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let id = UUID()
        state.sync(descriptors: [gainFX(0.5, id: id)], sampleRate: 48_000)
        let snapshotBefore = try #require(processor.currentSnapshot)
        let unitBefore = try #require(state.unit(forEffect: id))

        // First walk adopts 0.5 EXACTLY (prepared value, no ramp).
        let buffer1 = try makeConstantBuffer(1.0, frames: 512)
        processor.process(bufferList: buffer1.mutableAudioBufferList, frameCount: 512)
        let channels1 = try #require(buffer1.floatChannelData)
        #expect(channels1[0][0] == 0.5 && channels1[0][511] == 0.5)

        // Param scrub 0.5 → 0.25: an atomic POD publish inside the instance.
        state.sync(descriptors: [gainFX(0.25, id: id)], sampleRate: 48_000)
        #expect(processor.currentSnapshot === snapshotBefore)  // NO republish
        #expect(state.unit(forEffect: id) === unitBefore)      // same live unit

        // The change smooths over ~5 ms (240 frames at 48 kHz) and is EXACT
        // once the ramp lands.
        let buffer2 = try makeConstantBuffer(1.0, frames: 512)
        processor.process(bufferList: buffer2.mutableAudioBufferList, frameCount: 512)
        let channels2 = try #require(buffer2.floatChannelData)
        #expect(abs(channels2[0][0] - 0.5) < 0.01)   // ramp starts near old value
        #expect(channels2[0][300] == 0.25)           // exact after the ramp
        #expect(channels2[0][511] == 0.25)
        var monotone = true
        for frame in 1..<512 where channels2[0][frame] > channels2[0][frame - 1] + 1e-6 {
            monotone = false
        }
        #expect(monotone)  // zipper-free: strictly non-increasing ramp

        let buffer3 = try makeConstantBuffer(1.0, frames: 512)
        processor.process(bufferList: buffer3.mutableAudioBufferList, frameCount: 512)
        let channels3 = try #require(buffer3.floatChannelData)
        #expect(channels3[0][0] == 0.25 && channels3[0][511] == 0.25)
        print("[measured] param scrub: ramp start \(channels2[0][0]), "
              + "settled \(channels3[0][0]) (exact 0.25)")
    }

    @Test("un-bypass resets effect state before the next process (m15-f: fade-out processes, steady bypass skips, double-arm resets twice)")
    func unbypassResetsEffectState() throws {
        let processor = EffectChainProcessor()
        let probe = SequenceProbeEffect()
        let unit = ChainEffectUnit(id: UUID(), kind: .gain,
                                   instance: probe, isBypassed: false)
        processor.publish(EffectChainSnapshot(units: [unit]))
        // 512-frame walks: the 480-frame (10 ms @ 48 kHz) bypass crossfade
        // completes inside one walk.
        let buffer = try makeConstantBuffer(0.5, frames: 512)
        func walk() {
            processor.process(bufferList: buffer.mutableAudioBufferList, frameCount: 512)
        }

        walk()
        #expect(probe.calls == ["process"])

        unit.setBypassed(true)
        walk()  // m15-f: the fade-OUT walk still processes (tail under the falling gain)
        #expect(probe.calls == ["process", "process"])
        walk()  // steady bypass: skipped entirely (the pre-m15f law)
        #expect(probe.calls == ["process", "process"])

        unit.setBypassed(false)  // arms the reset flag
        walk()
        // reset BEFORE process — the resetFlag law, verbatim through the fade-in.
        #expect(probe.calls == ["process", "process", "reset", "process"])
        walk()  // fade done: plain steady processing
        #expect(probe.calls == ["process", "process", "reset", "process", "process"])

        // Stop-time tail cut: requestResetAll arms every unit the same way.
        processor.requestResetAll()
        probe.calls = []
        walk()
        #expect(probe.calls == ["reset", "process"])

        // m15-f flush-family double-arm: exactly TWO reset walks, then done.
        processor.requestResetAll(passes: 2)
        probe.calls = []
        walk()
        walk()
        walk()
        #expect(probe.calls == ["reset", "process", "reset", "process", "process"])
    }

    @Test("v0 chains report zero insert latency through graph and engine")
    func chainLatencyReportsZeroForV0Chain() throws {
        let fixtures = try TestSignals.fixtures()
        let track = audioTrack(clip: fixtures.cos1k48,
                               effects: [gainFX(0.5), gainFX(2.0)])
        let (_, graph) = try makeManualEngine()
        graph.reconcile(tracks: [track])
        graph.applyParameters(tracks: [track])
        #expect(graph.chainLatencySamples(forTrack: track.id) == 0)
        #expect(graph.chainLatencySamples(forTrack: UUID()) == 0)  // unknown id

        // Engine forwarder (headless — never started) + protocol default.
        let engine = AudioEngine()
        #expect(engine.insertChainLatencySamples(forTrack: UUID()) == 0)
    }

    /// m39-y L9, the CHAIN half. `TransientShaperTests` asserts the unit's own
    /// `latencySamples == 0`; this asserts what that is FOR — that inserting it
    /// leaves the chain total unmoved, so it adds no new latency source to the
    /// insert PDC measured sample-exact at m25-n.
    ///
    /// ⛔ It lives here rather than in `TransientShaperTests` because
    /// `EffectChainState` is `@MainActor` and `MainActorOccupancySiteTests`
    /// Leg C pins the `@MainActor` SUITE count at its cap with ZERO SLACK — so
    /// a new main-actor suite is not available and per-test annotation is
    /// forbidden. This suite is already main-actor-isolated.
    ///
    /// ⚠️ It carries its own POSITIVE CONTROL: a `.limiter` in the same
    /// position DOES move the total. Without that, "the total did not move"
    /// would be equally consistent with a chain-latency accessor that always
    /// reports 0.
    @Test("m39-y L9 — a transient shaper leaves the chain latency total unmoved, and a limiter in the same slot moves it")
    func transientShaperAddsNoChainLatency() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)

        state.sync(descriptors: [gainFX(0.5)], sampleRate: 48_000)
        let baseline = state.latencySamples

        state.sync(descriptors: [gainFX(0.5),
                                 EffectDescriptor(kind: .transientShaper,
                                                  transientShaper: TransientShaperParams(
                                                      attackDb: 12, sustainDb: -8,
                                                      attackMs: 40, sustainMs: 900))],
                   sampleRate: 48_000)
        let withShaper = state.latencySamples

        state.sync(descriptors: [gainFX(0.5),
                                 EffectDescriptor(kind: .limiter,
                                                  limiter: LimiterParams())],
                   sampleRate: 48_000)
        let withLimiter = state.latencySamples

        print("[measured] m39-y L9 chain latency: gain-only \(baseline), "
              + "+ transientShaper \(withShaper), + limiter \(withLimiter)")
        #expect(baseline == 0)
        #expect(withShaper == baseline,
                "the transient shaper moved the chain total to \(withShaper) — it has entered the PDC path and must be re-measured against m25-n")
        // POSITIVE CONTROL: the accessor can report a non-zero.
        #expect(withLimiter > 0,
                "the chain-latency accessor reported 0 for a LOOKAHEAD limiter — it cannot see latency at all, so the assertion above proves nothing")
    }

    /// m39-z L8b — the CHAIN half, for the m39-y reason above (this suite is
    /// already main-actor-isolated and a new main-actor suite is not available).
    /// A frequency shifter is a filter network, not a delay line: its group
    /// delay is frequency-dependent like `.eq`'s and `.phaser`'s, so it declares
    /// 0 and must not move the chain total.
    ///
    /// ⚠ CARRIES ITS OWN POSITIVE CONTROL, without which "the total did not
    /// move" is equally consistent with an accessor that always reports 0.
    @Test("m39-z L8b — a frequency shifter leaves the chain latency total unmoved, and a limiter in the same slot moves it")
    func freqShifterAddsNoChainLatency() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)

        state.sync(descriptors: [gainFX(0.5)], sampleRate: 48_000)
        let baseline = state.latencySamples

        state.sync(descriptors: [gainFX(0.5),
                                 EffectDescriptor(kind: .freqShifter,
                                                  freqShifter: FreqShifterParams(
                                                      shiftHz: 733.5, fineHz: 12.5,
                                                      stereoSpreadHz: -9, mix: 1))],
                   sampleRate: 48_000)
        let withShifter = state.latencySamples

        state.sync(descriptors: [gainFX(0.5),
                                 EffectDescriptor(kind: .limiter,
                                                  limiter: LimiterParams())],
                   sampleRate: 48_000)
        let withLimiter = state.latencySamples

        print("[measured] m39-z L8b chain latency: gain-only \(baseline), "
              + "+ freqShifter \(withShifter), + limiter \(withLimiter)")
        #expect(baseline == 0)
        #expect(withShifter == baseline,
                "the frequency shifter moved the chain total to \(withShifter) — it has entered the PDC path and must be re-measured against m25-n")
        // POSITIVE CONTROL: the accessor can report a non-zero.
        #expect(withLimiter > 0,
                "the chain-latency accessor reported 0 for a LOOKAHEAD limiter — it cannot see latency at all, so the assertion above proves nothing")
    }

    /// m39-y A8, the SECOND half. `EffectFactory.makeInstance` is exercised by
    /// every other render in the tree; `EffectFactory.applyParams` is not —
    /// nothing else constructs a shaper and then scrubs a knob on the LIVE
    /// instance. That arm is an inert-effect shape: a mistyped cast
    /// (`as? PhaserEffect`) compiles to `nil?.apply(…)`, every knob move on a
    /// playing track silently no-ops, and the whole suite stays green because
    /// every other test builds a fresh instance carrying the value already.
    ///
    /// The knob moved is `outputDb`, not `attackDb`, for the same reason L8
    /// uses it: on a CONSTANT buffer the three detector envelopes converge, the
    /// differentials go to 0, and `attackDb` is multiplied by ≈0 — a plant on
    /// the multiplicative path would not reach the output. `outputDb` is on the
    /// unconditional path, so the assertion is about the apply, not the DSP.
    @Test("m39-y A8 — a transient-shaper knob scrub lands on the LIVE instance (EffectFactory.applyParams), same unit, no snapshot republish")
    func transientShaperParamScrubAppliesInPlace() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let id = UUID()
        func shaper(outputDb: Double) -> EffectDescriptor {
            EffectDescriptor(id: id, kind: .transientShaper,
                             transientShaper: TransientShaperParams(
                                 attackDb: 0, sustainDb: 0, outputDb: outputDb))
        }

        state.sync(descriptors: [shaper(outputDb: 0)], sampleRate: 48_000)
        let snapshotBefore = try #require(processor.currentSnapshot)
        let unitBefore = try #require(state.unit(forEffect: id))

        // Neutral: attack/sustain 0 means shapeDb is 0 whatever the detector
        // reads, so the walk is a pure `outputDb` multiply of 0.5.
        let buffer1 = try makeConstantBuffer(0.5, frames: 512)
        processor.process(bufferList: buffer1.mutableAudioBufferList, frameCount: 512)
        let channels1 = try #require(buffer1.floatChannelData)
        #expect(abs(channels1[0][511] - 0.5) < 1e-6)

        // The scrub: +12 dB on the live unit.
        state.sync(descriptors: [shaper(outputDb: 12)], sampleRate: 48_000)
        #expect(processor.currentSnapshot === snapshotBefore)  // NO republish
        #expect(state.unit(forEffect: id) === unitBefore)      // same live unit

        // One quantum of per-sample interpolation, then exact.
        let buffer2 = try makeConstantBuffer(0.5, frames: 512)
        processor.process(bufferList: buffer2.mutableAudioBufferList, frameCount: 512)
        let buffer3 = try makeConstantBuffer(0.5, frames: 512)
        processor.process(bufferList: buffer3.mutableAudioBufferList, frameCount: 512)
        let channels3 = try #require(buffer3.floatChannelData)
        let settled = Double(channels3[0][511])
        let expected = 0.5 * pow(10.0, 12.0 / 20.0)
        let settledDb = 20.0 * log10(settled / 0.5)
        print("[measured] m39-y A8 live apply: 0.5 → \(settled) "
              + "(\(settledDb) dB, expected +12.000, target \(expected))")
        #expect(abs(settledDb - 12.0) < 0.01,
                "the +12 dB scrub reached the live instance as \(settledDb) dB — if it reads 0, EffectFactory.applyParams never touched this instance and every knob move on a playing track is inert")
        // Anti-vacuity: the ramp had to move, so the walk above is not simply
        // re-reading a value that was there from construction.
        let channels2 = try #require(buffer2.floatChannelData)
        #expect(Double(channels2[0][0]) < settled - 1e-4,
                "the first post-scrub sample already sat at the settled value — this walk did not observe an apply, it observed a rebuild")
    }
}
