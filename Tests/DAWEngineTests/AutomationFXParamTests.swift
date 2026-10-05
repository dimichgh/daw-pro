import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (vii-c) automation read path for BUILT-IN effect params — schedule
/// resolution (paramName → slot), quantum-start stores into the live chain
/// units before the walk, the analytic quantum-step envelope through a gain
/// insert, delay-mix automation bringing echoes in over a bounce, bypass
/// inertness, mid-play republish without restart, knob revert when lanes
/// vanish, missing-effect guard rails, and bit-exact determinism.
@MainActor
@Suite("Automation engine — effect-param lanes", .serialized)
struct AutomationFXParamTests {
    private static let sampleRate = 48_000.0
    /// The OfflineRenderer pull size: the effect-param envelope steps on these
    /// boundaries, so this must BE the renderer's block rather than a copy of
    /// it. It was the literal `4_096` until m28-bug lowered the block to 512;
    /// the staircase this suite measures is unchanged in KIND, it simply has 8×
    /// as many steps, which is the automation-resolution half of that fix.
    private static let quantum = RenderBlockSize.offlineFrames
    /// Whole quanta inside the 96 000-frame render (the last is partial).
    private static let wholeQuanta = 96_000 / RenderBlockSize.offlineFrames - 1

    // MARK: - Harness helpers (AutomationEngineTests idiom)

    private func stereoBuffer(frames: Int, fill: Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<frames { data[channel][frame] = fill }
        }
        return buffer
    }

    private func offlineTimestamp(sample: Double) -> AudioTimeStamp {
        var ts = AudioTimeStamp()
        ts.mSampleTime = sample
        ts.mFlags = .sampleTimeValid
        return ts
    }

    private func writeConstantWAV(value: Float, frames: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("automation-fx-dc-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: Self.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings,
                                   commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: stereoBuffer(frames: frames, fill: value))
        return url
    }

    private func makeGraph(tracks: [Track],
                           playheadBeat: Double = 0) throws -> (AVAudioEngine, PlaybackGraph) {
        let engine = AVAudioEngine()
        let graph = PlaybackGraph(engine: engine)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4_096)
        _ = engine.mainMixerNode
        _ = graph.reconcile(tracks: tracks)
        graph.applyParameters(tracks: tracks, playheadBeat: playheadBeat)
        return (engine, graph)
    }

    private func bitDiffCount(_ a: RenderedAudio, _ b: RenderedAudio) -> Int {
        var diffs = 0
        for channel in 0..<min(a.channelData.count, b.channelData.count) {
            for frame in 0..<min(a.channelData[channel].count, b.channelData[channel].count)
            where a.channelData[channel][frame].bitPattern
                != b.channelData[channel][frame].bitPattern {
                diffs += 1
            }
        }
        return diffs
    }

    /// Runs `frames` of ones through one effect instance directly (the
    /// render-surface unit-test contract) and returns channel 0.
    private func processOnes(_ effect: any EffectRendering, frames: Int) throws -> [Float] {
        let buffer = try stereoBuffer(frames: frames, fill: 1)
        effect.process(buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                       frameCount: frames)
        let data = try #require(buffer.floatChannelData)
        return Array(UnsafeBufferPointer(start: data[0], count: frames))
    }

    // MARK: - 1. Build resolution (paramName → slot; unresolvable = inert)

    @Test("resolveEffectParamLanes maps names to spec slots and drops unresolvable lanes")
    func resolveMapsNamesToSlotsAndDropsUnresolvable() {
        let delayFX = EffectDescriptor(kind: .delay)
        let gainFX = EffectDescriptor(kind: .gain)
        let auFX = EffectDescriptor(kind: .audioUnit)
        let points = [AutomationPoint(beat: 0, value: 0.5)]
        let lanes = [
            AutomationLane(target: .effectParam(effectID: delayFX.id, paramName: "mix"),
                           points: points),
            AutomationLane(target: .effectParam(effectID: gainFX.id, paramName: "gainLinear"),
                           points: points),
            // Unresolvable, all inert by construction:
            AutomationLane(target: .effectParam(effectID: UUID(), paramName: "mix"),
                           points: points),                                  // deleted effect
            AutomationLane(target: .effectParam(effectID: auFX.id, paramName: "mix"),
                           points: points),                                  // .audioUnit (empty specs)
            AutomationLane(target: .effectParam(effectID: delayFX.id, paramName: "nope"),
                           points: points),                                  // unknown param
            AutomationLane(target: .effectParam(effectID: delayFX.id, paramName: "feedback"),
                           points: points, isEnabled: false),                // disabled
            AutomationLane(target: .effectParam(effectID: delayFX.id, paramName: "timeMs"),
                           points: []),                                      // empty
            AutomationLane(target: .volume, points: points),                 // not an FX lane
        ]
        let specs = AutomationSchedule.resolveEffectParamLanes(
            automation: lanes, effects: [delayFX, gainFX, auFX])
        #expect(specs.count == 2)
        #expect(specs[0].effectID == delayFX.id)
        #expect(specs[0].paramSlot == 2)   // specs(for: .delay): 0 timeMs, 1 feedback, 2 mix
        #expect(specs[1].effectID == gainFX.id)
        #expect(specs[1].paramSlot == 0)   // specs(for: .gain): 0 gainLinear

        // Build carries the tracks; a schedule with ONLY effect lanes builds.
        let schedule = AutomationSchedule.build(
            volumeLane: nil, panLane: nil, effectParamLanes: specs,
            fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: 48_000, generation: 1, mode: .offline)
        #expect(schedule?.effectParamTracks.count == 2)
        #expect(schedule?.volumePoints.count == 0)
        #expect(AutomationSchedule.build(
            volumeLane: nil, panLane: nil, effectParamLanes: [],
            fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: 48_000,
            generation: 1, mode: .offline) == nil)
    }

    // MARK: - 2. Analytic quantum-step gain envelope in an offline bounce

    @Test("offline bounce: gainLinear ramp lane steps once per quantum at the lane's quantum-start value")
    func gainLinearLaneStepsPerQuantumMatchAnalytic() throws {
        // DC 0.25 for 2 s; the gain insert's gainLinear lane ramps 0→1 over
        // beats 0…4 (120 BPM = 96 000 samples). The lane is evaluated at the
        // QUANTUM START only (no intra-quantum ramp — spec), so the envelope
        // is a staircase on RenderBlockSize.offlineFrames boundaries;
        // GainEffect's own ~5 ms declick ramp settles 240 frames in, landing
        // EXACTLY on the stepped target for the rest of the quantum.
        // ⚠️ At a 512-frame quantum the settled window is only frames 260…511 —
        // still past the 240-frame declick, but the margin is 20 frames, not
        // 3 856. A slower declick would break this test before it broke audio.
        let url = try writeConstantWAV(value: 0.25, frames: 96_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let fx = EffectDescriptor(kind: .gain)   // knob at unity — the lane must rule
        let track = Track(
            name: "DC", kind: .audio,
            clips: [Clip(name: "dc", startBeat: 0, lengthBeats: 4, audioFileURL: url)],
            effects: [fx],
            automation: [AutomationLane(
                target: .effectParam(effectID: fx.id, paramName: "gainLinear"),
                points: [AutomationPoint(beat: 0, value: 0),
                         AutomationPoint(beat: 4, value: 1)])])
        let audio = try OfflineRenderer(sampleRate: Self.sampleRate).render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120), fromBeat: 0, durationSeconds: 2.0)
        #expect(audio.frameCount == 96_000)
        let out = audio.channelData[0]

        var maxDiff = 0.0
        var maxIntraQuantumSpread: Float = 0
        var stepCount = 0
        for k in 0...Self.wholeQuanta {
            let start = k * Self.quantum
            let settledFrom = start + 260          // past the 240-frame declick
            let settledTo = start + Self.quantum - 1
            let expectedGain = Double(start) / 96_000.0   // lane value at quantum START
            maxDiff = max(maxDiff, abs(Double(out[settledTo]) - 0.25 * expectedGain))
            // Stepped, not ramped: the settled region is EXACTLY constant.
            var lo = out[settledFrom]
            var hi = out[settledFrom]
            for frame in settledFrom...settledTo {
                lo = min(lo, out[frame])
                hi = max(hi, out[frame])
            }
            maxIntraQuantumSpread = max(maxIntraQuantumSpread, hi - lo)
            if k > 0, out[settledTo] > out[settledTo - Self.quantum] { stepCount += 1 }
        }
        print("[measured] gainLinear staircase: max |settled − 0.25·laneValue(quantumStart)| "
              + "= \(maxDiff); max intra-quantum settled spread = \(maxIntraQuantumSpread); "
              + "\(stepCount)/\(Self.wholeQuanta) quantum boundaries stepped upward")
        #expect(maxDiff < 1e-6)                 // quantum-start value, exactly held
        #expect(maxIntraQuantumSpread == 0)     // staircase — constant inside the quantum
        #expect(stepCount == Self.wholeQuanta)  // every boundary steps (monotone lane)
    }

    // MARK: - 3. Delay mix 0→1: dry early, echoes later (+ determinism)

    @Test("delay mix lane 0→1: bit-exact dry early, recirculated echoes audible after the step; bounce is deterministic")
    func delayMixLaneBringsEchoesInOverTime() throws {
        // 0.25 s DC burst at 0.5, then silence. Delay: 250 ms (12 000
        // samples), feedback 0.8, KNOB mix 0.7 — the lane holds mix at 0
        // until beat 2 (48 000), so the knob must NOT leak: the burst passes
        // dry and the first recirculations are inaudible. After the step to
        // 1, the still-ringing feedback line becomes audible.
        let url = try writeConstantWAV(value: 0.5, frames: 12_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let fx = EffectDescriptor(kind: .delay,
                                  delay: DelayParams(timeMs: 250, feedback: 0.8, mix: 0.7))
        let track = Track(
            name: "Burst", kind: .audio,
            clips: [Clip(name: "b", startBeat: 0, lengthBeats: 0.5, audioFileURL: url)],
            effects: [fx],
            automation: [AutomationLane(
                target: .effectParam(effectID: fx.id, paramName: "mix"),
                points: [AutomationPoint(beat: 0, value: 0, curve: .hold),
                         AutomationPoint(beat: 2, value: 1, curve: .hold)])])
        let renderer = OfflineRenderer(sampleRate: Self.sampleRate)
        let audio = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 1.5)
        let out = audio.channelData[0]

        var dryDiff: Float = 0
        for frame in 100...11_000 { dryDiff = max(dryDiff, abs(out[frame] - 0.5)) }
        var earlyEchoPeak: Float = 0
        for frame in 13_000...23_000 { earlyEchoPeak = max(earlyEchoPeak, abs(out[frame])) }
        var lateEchoPeak: Float = 0
        for frame in 50_000...58_000 { lateEchoPeak = max(lateEchoPeak, abs(out[frame])) }
        print("[measured] delay-mix lane: dry region |out − 0.5| ≤ \(dryDiff); "
              + "first-echo window peak (mix 0) = \(earlyEchoPeak); "
              + "post-step echo window peak (mix 1) = \(lateEchoPeak)")
        #expect(dryDiff < 1e-6)          // mix 0 is bit-exact dry despite the 0.7 knob
        #expect(earlyEchoPeak < 1e-6)    // echoes exist in the line but are inaudible
        #expect(lateEchoPeak > 0.1)      // ≈ 0.8³ · 0.5 recirculation surfaces after the step

        // Determinism: the automated bounce is bit-identical run-to-run.
        let again = try renderer.render(tracks: [track], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 1.5)
        let diffs = bitDiffCount(audio, again)
        print("[measured] determinism: \(diffs) differing bit patterns across two bounces "
              + "of \(audio.frameCount) × 2 samples")
        #expect(diffs == 0)
    }

    // MARK: - 4. Bypassed effect: lane does nothing audible until un-bypass

    @Test("a lane on a bypassed effect is inaudible (bit-exact vs no effect); un-bypassed it rules")
    func laneOnBypassedEffectIsInertUntilUnbypass() throws {
        let url = try writeConstantWAV(value: 0.5, frames: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let fxID = UUID()
        let lane = AutomationLane(
            target: .effectParam(effectID: fxID, paramName: "gainLinear"),
            points: [AutomationPoint(beat: 0, value: 0.25),
                     AutomationPoint(beat: 4, value: 0.25)])
        func track(effects: [EffectDescriptor], automation: [AutomationLane]) -> Track {
            Track(name: "T", kind: .audio,
                  clips: [Clip(name: "dc", startBeat: 0, lengthBeats: 4, audioFileURL: url)],
                  effects: effects, automation: automation)
        }
        let renderer = OfflineRenderer(sampleRate: Self.sampleRate)
        let plain = try renderer.render(
            tracks: [track(effects: [], automation: [])], tempoMap: TempoMap(constantBPM: 120), durationSeconds: 1.0)
        let bypassed = try renderer.render(
            tracks: [track(effects: [EffectDescriptor(id: fxID, kind: .gain, isBypassed: true)],
                           automation: [lane])],
            tempoMap: TempoMap(constantBPM: 120), durationSeconds: 1.0)
        let active = try renderer.render(
            tracks: [track(effects: [EffectDescriptor(id: fxID, kind: .gain)],
                           automation: [lane])],
            tempoMap: TempoMap(constantBPM: 120), durationSeconds: 1.0)
        let bypassDiffs = bitDiffCount(plain, bypassed)
        let settled = active.channelData[0][10_000]
        print("[measured] bypassed-effect lane: \(bypassDiffs) differing bit patterns vs "
              + "no-effect render; un-bypassed settled output = \(settled) (expected 0.125)")
        #expect(bypassDiffs == 0)                        // bypass wins: lane inaudible
        #expect(abs(Double(settled) - 0.125) < 1e-6)     // un-bypassed: 0.5 × lane 0.25
    }

    // MARK: - 5. Mid-play lane edit: republish without restart

    @Test("mid-play FX-param lane edit republishes the automation schedule only — no player/MIDI restart")
    func midPlayFXParamEditRepublishesWithoutRestart() throws {
        let url = try writeConstantWAV(value: 0.5, frames: 48_000)
        defer { try? FileManager.default.removeItem(at: url) }
        let fx = EffectDescriptor(kind: .gain)
        var audio = Track(
            name: "A", kind: .audio,
            clips: [Clip(name: "c", startBeat: 0, lengthBeats: 4, audioFileURL: url)],
            effects: [fx],
            automation: [AutomationLane(
                target: .effectParam(effectID: fx.id, paramName: "gainLinear"),
                points: [AutomationPoint(beat: 0, value: 0.5),
                         AutomationPoint(beat: 4, value: 1)])])
        let inst = Track(
            name: "I", kind: .instrument,
            clips: [Clip(name: "m", startBeat: 0, lengthBeats: 4,
                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])])
        let (engine, graph) = try makeGraph(tracks: [audio, inst])
        try engine.start()
        graph.applyParameters(tracks: [audio, inst])
        graph.scheduleAll(fromBeat: 0, tempoMap: TempoMap(constantBPM: 120))
        graph.startAllPlayers(at: nil)
        let midiRenderer = try #require(graph.instrumentRenderer(forTrack: inst.id))
        let midiBefore = try #require(midiRenderer.currentSchedule)
        let head = try #require(graph.automationRenderer(forTrack: audio.id))
        let before = try #require(head.currentSchedule)
        #expect(before.effectParamTracks.count == 1)
        #expect(before.effectParamTracks[0].effectID == fx.id)
        #expect(before.effectParamTracks[0].paramSlot == 0)   // gainLinear
        #expect(before.effectParamTracks[0].points.map(\.value) == [0.5, 1])

        audio.automation = [AutomationLane(
            target: .effectParam(effectID: fx.id, paramName: "gainLinear"),
            points: [AutomationPoint(beat: 0, value: 0.1),
                     AutomationPoint(beat: 2, value: 0.9)])]
        #expect(graph.reconcile(tracks: [audio, inst]) == false)  // no structural change
        graph.applyParameters(tracks: [audio, inst], playheadBeat: 1)

        let midiAfter = try #require(midiRenderer.currentSchedule)
        #expect(midiAfter === midiBefore)                       // no reschedule
        #expect(midiAfter.generation == midiBefore.generation)
        let after = try #require(head.currentSchedule)
        #expect(after.generation > before.generation)           // only automation moved
        #expect(after.effectParamTracks[0].points.map(\.value) == [0.1, 0.9])
        print("[measured] no-restart: MIDI generation \(midiBefore.generation) → "
              + "\(midiAfter.generation) (same object: \(midiAfter === midiBefore)); "
              + "automation generation \(before.generation) → \(after.generation)")

        // Disabling the last lane while rolling unpublishes the schedule —
        // the render side's per-quantum stores stop, so the effect reverts
        // to its knob params (proven render-side in the revert test below).
        audio.automation[0].isEnabled = false
        #expect(graph.reconcile(tracks: [audio, inst]) == false)
        graph.applyParameters(tracks: [audio, inst], playheadBeat: 1)
        #expect(head.currentSchedule == nil)
        graph.stopAllPlayers()
        engine.stop()
    }

    // MARK: - 6. Guard rails on the render surface

    @Test("a schedule track for a MISSING effect id is inert on the render thread; a matching one stores")
    func missingEffectTrackIsInertOnRenderThread() throws {
        let liveGain = GainEffect(params: GainParams(gainLinear: 1))
        liveGain.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 4_096, channelCount: 2)
        let unit = ChainEffectUnit(id: UUID(), kind: .gain, instance: liveGain, isBypassed: false)
        let chain = EffectChainProcessor()
        chain.publish(EffectChainSnapshot(units: [unit]))

        // Track 0 targets a GHOST effect id (deleted / stale) — must be
        // skipped without crash or store; track 1 targets the live unit.
        let ghostID = UUID()
        let points = [AutomationBreakpoint(sampleTime: 0, value: 0.5, holdsSegment: false)]
        let renderer = AutomationRenderer()
        renderer.publish(AutomationSchedule(
            generation: 1, mode: .offline, sampleRate: Self.sampleRate,
            volumePoints: [], panPoints: [],
            effectParamTracks: [(effectID: ghostID, paramSlot: 0, points: points),
                                (effectID: unit.id, paramSlot: 0, points: points)]))
        var ts = offlineTimestamp(sample: 0)
        renderer.storeEffectParams(chain: chain, frameCount: 512, timestamp: &ts)
        // The live unit received 0.5 (settles after the ~5 ms declick); the
        // ghost track changed nothing and crashed nothing.
        let out = try processOnes(liveGain, frames: 1_024)
        #expect(out[1_023] == 0.5)
        print("[measured] guard rail: ghost-effect track skipped; live unit settled to "
              + "\(out[1_023]) after one quantum (expected 0.5)")

        // Out-of-range slot on a live unit: inert by the effect's own guard.
        renderer.publish(AutomationSchedule(
            generation: 2, mode: .offline, sampleRate: Self.sampleRate,
            volumePoints: [], panPoints: [],
            effectParamTracks: [(effectID: unit.id, paramSlot: 99, points: points)]))
        var ts2 = offlineTimestamp(sample: 0)
        renderer.storeEffectParams(chain: chain, frameCount: 512, timestamp: &ts2)
        let out2 = try processOnes(liveGain, frames: 1_024)
        // No store arrived this quantum → the overlay reverts to the KNOB
        // value (unity), not the previously automated 0.5.
        #expect(out2[1_023] == 1.0)
    }

    @Test("when stores stop (lane removed / transport stopped), the effect reverts to its knob params")
    func effectRevertsToKnobParamsWhenStoresStop() throws {
        let gain = GainEffect(params: GainParams(gainLinear: 1))
        gain.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 4_096, channelCount: 2)
        // Quantum 1: automated to 2.0 — settles exactly on the target.
        gain.storeAutomatedParam(slot: 0, value: 2.0)
        let automated = try processOnes(gain, frames: 1_024)
        #expect(automated[1_023] == 2.0)
        // Quantum 2: NO store (schedule republished without this effect) —
        // the knob value (unity) restores via the same ~5 ms declick ramp,
        // with no main-actor republish involved.
        let reverted = try processOnes(gain, frames: 1_024)
        print("[measured] knob revert: settled \(automated[1_023]) while automated, "
              + "\(reverted[1_023]) one quantum after stores stopped (knob = 1)")
        #expect(reverted[1_023] == 1.0)
        // Out-of-range slots and non-finite values are inert stores.
        gain.storeAutomatedParam(slot: 3, value: 0.1)
        gain.storeAutomatedParam(slot: 0, value: .nan)
        let untouched = try processOnes(gain, frames: 1_024)
        #expect(untouched[1_023] == 1.0)
    }

    // MARK: - m39-e P3 — modulation composes into the value this path computes

    /// ⭐ THE CONSEQUENCE §3.3 WARNS IS EASY TO GET WRONG: today a target with
    /// NO automation lane never appears in `schedule.effectParamTracks`, so
    /// nothing stores it. A modulated-but-UNAUTOMATED param therefore needs a
    /// SYNTHETIC ONE-POINT HOLD track carrying the knob value — and one point,
    /// not zero, because a zero-point track is skipped twice over and would
    /// look exactly like a route that does nothing.
    ///
    /// This measures the whole chain: the synthetic track is built, the store
    /// runs, and the MODULATED value — not the knob value — reaches the live
    /// effect.
    @Test("⭐ m39-e P3: a modulated-but-UNAUTOMATED effect param reaches the effect through a synthetic one-point track")
    func modulatedButUnautomatedEffectParamReachesTheEffect() throws {
        var gainEffect = EffectDescriptor(kind: .gain)
        gainEffect.gain = GainParams(gainLinear: 1.0)
        // A macro at full travel through a NEGATIVE depth: a deterministic,
        // position-independent offset, so the assertion is arithmetic rather
        // than a phase guess.
        let macro = ModulationSource(kind: .macro, params: .macro(MacroSourceParams(value: 1)))
        let route = ModulationRoute(
            sourceID: macro.id,
            target: .effectParam(effectID: gainEffect.id, paramName: "gainLinear"),
            depth: -0.25)

        // The synthetic lane the graph builds for exactly this case.
        let synthetic = ModulationSnapshotBuilder.syntheticEffectParamLanes(
            routes: [route], effects: [gainEffect], automation: [])
        #expect(synthetic.count == 1, "one route, one synthetic track")
        #expect(synthetic.first?.points.count == 1,
                "ONE point, not zero — a zero-point track is silently inert")
        #expect(synthetic.first?.points.first?.value == 1.0, "carrying the KNOB value")

        // An already-AUTOMATED param must NOT get a second track: two stores
        // into one slot per quantum would be a last-writer-wins race.
        let lane = AutomationLane(target: route.target,
                                  points: [AutomationPoint(beat: 0, value: 0.5)])
        let none = ModulationSnapshotBuilder.syntheticEffectParamLanes(
            routes: [route], effects: [gainEffect], automation: [lane])
        #expect(none.isEmpty, "an automated param already has a track")

        // Render it: build the schedule from the synthetic track and let the
        // renderer's pre-walk store run against a live chain.
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        state.sync(descriptors: [gainEffect], sampleRate: Self.sampleRate)
        let renderer = AutomationRenderer()
        let schedule = try #require(AutomationSchedule.build(
            volumeLane: nil, panLane: nil,
            effectParamLanes: synthetic,
            fromBeat: 0, tempoMap: TempoMap(constantBPM: 120),
            sampleRate: Self.sampleRate, generation: 1, mode: .offline))
        renderer.publish(schedule)
        renderer.publishModulation(try #require(ModulationSnapshotBuilder.build(
            strip: ModulationSnapshotBuilder.Strip(
                sources: [macro], routes: [route], effects: [gainEffect]),
            generation: 1, timelineID: 1, sampleRate: Self.sampleRate,
            originSample: 0, positionValid: true)))

        var ts = offlineTimestamp(sample: 0)
        renderer.storeEffectParams(chain: processor, frameCount: Self.quantum, timestamp: &ts)

        // `gainLinear` is 0…16 LINEAR, so a -0.25 offset on a normalised base
        // of 1/16 clamps the normalised value to 0 → the effect's floor.
        let spec = try #require(EffectParamSpec.specs(for: .gain)
            .first { $0.name == "gainLinear" })
        let expected = ModulationDepthLaw.value(base: 1.0, sum: -0.25,
                                                range: spec.range, curve: spec.curve)
        let buffer = try stereoBuffer(frames: Self.quantum, fill: 1)
        processor.process(bufferList: buffer.mutableAudioBufferList,
                          frameCount: Self.quantum, key: nil)
        let data = try #require(buffer.floatChannelData)
        // The gain effect's store ends in a ~5 ms declick ramp (§2.4), so the
        // LAST sample of the quantum is the one that has travelled furthest
        // toward the target — the value is asserted as a DIRECTION plus a
        // bound, not as an instantaneous equality the smoother cannot give.
        let last = data[0][Self.quantum - 1]
        print("[measured] m39-e P3: knob 1.0, macro 1.0 at depth -0.25 → target "
              + "\(expected); rendered last sample \(last)")
        #expect(expected < 1.0, "the modulated target must be BELOW the knob value")
        #expect(last < 1.0, "the effect must actually have moved toward it")

        // CONTROL: with NO modulation published the same schedule stores the
        // knob value, and unity gain leaves the signal alone.
        let controlProcessor = EffectChainProcessor()
        let controlState = EffectChainState(processor: controlProcessor)
        controlState.sync(descriptors: [gainEffect], sampleRate: Self.sampleRate)
        let controlRenderer = AutomationRenderer()
        controlRenderer.publish(try #require(AutomationSchedule.build(
            volumeLane: nil, panLane: nil, effectParamLanes: synthetic,
            fromBeat: 0, tempoMap: TempoMap(constantBPM: 120),
            sampleRate: Self.sampleRate, generation: 1, mode: .offline)))
        var controlTS = offlineTimestamp(sample: 0)
        controlRenderer.storeEffectParams(chain: controlProcessor,
                                          frameCount: Self.quantum, timestamp: &controlTS)
        let controlBuffer = try stereoBuffer(frames: Self.quantum, fill: 1)
        controlProcessor.process(bufferList: controlBuffer.mutableAudioBufferList,
                                 frameCount: Self.quantum, key: nil)
        let controlData = try #require(controlBuffer.floatChannelData)
        print("[measured] m39-e P3 CONTROL (no modulation published): last sample "
              + "\(controlData[0][Self.quantum - 1])")
        #expect(controlData[0][Self.quantum - 1] == 1.0,
                "without modulation the synthetic track stores the knob, which is unity")
    }

}
