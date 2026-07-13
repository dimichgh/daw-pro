import AVFAudio
import CryptoKit
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m15-f — chain-local click polish. Two mechanisms, both measured pre-fix
/// on this exact probe shape (2026-07-13, un-fixed tree):
///
///  (1) F9 bypass-toggle click (audit-m15 B3): the swap was a hard step —
///      ×4-gain bypass mid-sine completed between two adjacent SAMPLES
///      (max adjacent 1 ms-window ΔRMS 0.437, per-sample Δ 0.476 against a
///      0.046 natural slope). Fixed: 10 ms equal-power crossfade at the walk
///      swap point (`ChainEffectUnit.renderCrossfade`).
///
///  (2) m14-d edit-seam echo blip: a single-armed chain reset is consumed at
///      the top of the SAME walk that still processes the one in-flight
///      pre-flush quantum — ring wiped, then re-dirtied; measured echo peak
///      0.250 at EXACTLY the delay spacing (onset 9 920 == leak + 4 800),
///      feedback repeat 0.125. Fixed: the flush family double-arms LIVE
///      (`requestResetAll(passes: 2)`); the negative control below keeps the
///      pre-fix class reproducible forever.
///
/// Null era: the no-toggle chain render SHA was pinned on the PRE-change
/// tree and must hold verbatim (`0a6fc1c5…`).
@MainActor
@Suite("Chain click polish (m15-f)", .serialized)
struct ChainClickPolishTests {
    private static let rate = 48_000.0
    private static let quantum = 512
    private static let fadeFrames = 480  // 10 ms @ 48 kHz

    // MARK: - Helpers

    private func makeBuffer(frames: Int) throws -> AVAudioPCMBuffer {
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// 440 Hz stereo sine at `amp`, phase-continuous from absolute frame
    /// `startFrame`, identical channels — the audit B3 sustained-pad stand-in.
    private func sineSample(_ frame: Int, amp: Float) -> Float {
        amp * Float(sin(2.0 * Double.pi * 440.0 * Double(frame) / Self.rate))
    }

    private func fillSine(_ buffer: AVAudioPCMBuffer, startFrame: Int, amp: Float) throws {
        let channels = try #require(buffer.floatChannelData)
        for frame in 0..<Int(buffer.frameLength) {
            let value = sineSample(startFrame + frame, amp: amp)
            channels[0][frame] = value
            channels[1][frame] = value
        }
    }

    private func fillSilence(_ buffer: AVAudioPCMBuffer) throws {
        let channels = try #require(buffer.floatChannelData)
        for channel in 0..<2 {
            channels[channel].update(repeating: 0, count: Int(buffer.frameLength))
        }
    }

    private func append(_ buffer: AVAudioPCMBuffer, to output: inout [Float]) throws {
        let channels = try #require(buffer.floatChannelData)
        output.append(contentsOf:
            UnsafeBufferPointer(start: channels[0], count: Int(buffer.frameLength)))
    }

    // MARK: - Crossfade shape

    @Test("equal-power law: toward² + away² == 1, monotone, exact endpoints")
    func equalPowerGainLawHolds() {
        var previous = ChainEffectUnit.crossfadeGains(progress: 0)
        #expect(previous.toward == 0)
        #expect(previous.away == 1)
        for step in 1...512 {
            let gains = ChainEffectUnit.crossfadeGains(progress: Float(step) / 512)
            let power = gains.toward * gains.toward + gains.away * gains.away
            #expect(abs(power - 1) < 1e-6)
            #expect(gains.toward >= previous.toward)  // monotone rise
            #expect(gains.away <= previous.away)      // monotone fall
            previous = gains
        }
        let end = ChainEffectUnit.crossfadeGains(progress: 1)
        #expect(end.toward == 1)
        #expect(abs(end.away) < 1e-6)
        // Out-of-range progress clamps (the walk's tail frames past fade end).
        let over = ChainEffectUnit.crossfadeGains(progress: 1.5)
        #expect(over.toward == 1 && abs(over.away) < 1e-6)
    }

    // MARK: - Bypass toggle A/B (the audit B3 probe, post-fix)

    @Test("bypass toggle mid-sustain crossfades equal-power over 10 ms — no step above threshold (pre-fix: ΔRMS 0.437 / sample Δ 0.476)")
    func bypassToggleFadesEqualPowerOverTenMs() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let fxID = UUID()
        func descriptor(bypassed: Bool) -> EffectDescriptor {
            EffectDescriptor(id: fxID, kind: .gain, isBypassed: bypassed,
                             gain: GainParams(gainLinear: 4))
        }
        state.sync(descriptors: [descriptor(bypassed: false)], sampleRate: Self.rate)

        var output: [Float] = []
        let buffer = try makeBuffer(frames: Self.quantum)
        let toggleQuantum = 20
        for q in 0..<40 {
            if q == toggleQuantum {
                state.sync(descriptors: [descriptor(bypassed: true)], sampleRate: Self.rate)
            }
            try fillSine(buffer, startFrame: q * Self.quantum, amp: 0.2)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: Self.quantum)
            try append(buffer, to: &output)
        }
        let toggleFrame = toggleQuantum * Self.quantum  // 10_240

        // Plateaus are EXACT: ×4 before the toggle, ×1 (bit-exact dry) from
        // the first post-fade quantum on.
        for frame in 0..<toggleFrame {
            #expect(output[frame] == 4 * sineSample(frame, amp: 0.2))
            if output[frame] != 4 * sineSample(frame, amp: 0.2) { break }
        }
        for frame in (toggleFrame + Self.quantum)..<output.count {
            #expect(output[frame] == sineSample(frame, amp: 0.2))
            if output[frame] != sineSample(frame, amp: 0.2) { break }
        }

        // The fade quantum follows the equal-power curve EXACTLY (same Float
        // expression the render evaluates; progress clamps past fade end).
        var maxCurveError: Float = 0
        for frame in toggleFrame..<(toggleFrame + Self.quantum) {
            let input = sineSample(frame, amp: 0.2)
            let progress = Float(frame - toggleFrame) / Float(Self.fadeFrames)
            let (toward, away) = ChainEffectUnit.crossfadeGains(progress: progress)
            let expected = (4 * input) * away + input * toward  // wet falls, dry rises
            maxCurveError = max(maxCurveError, abs(output[frame] - expected))
        }
        #expect(maxCurveError < 1e-6)

        // Smoothness thresholds (stated): max adjacent 1 ms-window ΔRMS
        // ≤ 0.12 — the honest 10 ms ramp of this 0.42 RMS swing peaks
        // ≈ 0.066/ms, plus the phase jitter a 1 ms window carries on a
        // 440 Hz tone (a window spans under half a period); pre-fix measured
        // 0.437 on the same metric — 4.5× the bound. Max per-sample Δ
        // ≤ 0.05 (natural 440 Hz slope at the ×4 amplitude is 0.046; the
        // fade adds ≤ 0.004; pre-fix measured 0.476).
        let windowFrames = 48
        var rmsSeries: [Float] = []
        var frame = toggleFrame - 5 * windowFrames
        while frame + windowFrames <= toggleFrame + 15 * windowFrames {
            rmsSeries.append(TestSignals.rms(output, in: frame..<(frame + windowFrames)))
            frame += windowFrames
        }
        var maxAdjacentDelta: Float = 0
        for index in 1..<rmsSeries.count {
            maxAdjacentDelta = max(maxAdjacentDelta,
                                   abs(rmsSeries[index] - rmsSeries[index - 1]))
        }
        var maxSampleDelta: Float = 0
        for index in (toggleFrame - 96)..<(toggleFrame + 576) {
            maxSampleDelta = max(maxSampleDelta, abs(output[index] - output[index - 1]))
        }
        #expect(maxAdjacentDelta <= 0.12)
        #expect(maxSampleDelta <= 0.05)

        // The audit gate: ≥ 5 ms of ramp where there was a ≤ 2 ms step —
        // count 1 ms windows sitting strictly BETWEEN the plateaus (5 %
        // guard bands). Pre-fix a hard swap puts ≤ 1 window between.
        let highRMS = TestSignals.rms(output, in: (toggleFrame - 4_800)..<toggleFrame)
        let lowRMS = TestSignals.rms(
            output, in: (toggleFrame + 1_024)..<(toggleFrame + 5_824))
        let betweenWindows = rmsSeries.filter {
            $0 < highRMS * 0.95 && $0 > lowRMS * 1.05
        }.count
        #expect(betweenWindows >= 5)

        // Envelope monotonicity, asserted on the effective GAIN trajectory
        // (4·away + toward) — the output follows it BIT-EXACTLY per the
        // curve pin above, and 1 ms RMS windows are too phase-jittered on a
        // 440 Hz tone to carry this assertion honestly. Correlated equal-
        // power overshoots by exactly √17/4 (+3.08 %) at p = atan(1/4)·2/π,
        // then falls strictly monotone.
        var gains: [Float] = []
        for fadeFrame in 0...Self.fadeFrames {
            let (toward, away) = ChainEffectUnit.crossfadeGains(
                progress: Float(fadeFrame) / Float(Self.fadeFrames))
            gains.append(4 * away + toward)
        }
        let maxGain = try #require(gains.max())
        let peakIndex = try #require(gains.firstIndex(of: maxGain))
        var monotoneAfterPeak = true
        for index in (peakIndex + 1)..<gains.count
        where gains[index] > gains[index - 1] + 1e-6 {
            monotoneAfterPeak = false
        }
        #expect(maxGain <= 4 * 1.031)  // the analytic √17/4 bound
        #expect(monotoneAfterPeak)

        print("[measured] m15-f bypass fade: plateau RMS \(highRMS) → \(lowRMS), "
              + "max adjacent 1 ms ΔRMS \(maxAdjacentDelta) (pre-fix 0.437, threshold 0.12), "
              + "max per-sample Δ \(maxSampleDelta) (pre-fix 0.476, threshold 0.05), "
              + "curve error \(maxCurveError), between-plateau windows \(betweenWindows), "
              + "gain overshoot ×\(maxGain / 4)")
    }

    @Test("un-bypass fades in FROM the dry level and settles exact ×4 in 10 ms")
    func unbypassFadesInFromDryLevel() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let fxID = UUID()
        func descriptor(bypassed: Bool) -> EffectDescriptor {
            EffectDescriptor(id: fxID, kind: .gain, isBypassed: bypassed,
                             gain: GainParams(gainLinear: 4))
        }
        state.sync(descriptors: [descriptor(bypassed: true)], sampleRate: Self.rate)

        var output: [Float] = []
        let buffer = try makeBuffer(frames: Self.quantum)
        let toggleQuantum = 10
        for q in 0..<20 {
            if q == toggleQuantum {
                state.sync(descriptors: [descriptor(bypassed: false)], sampleRate: Self.rate)
            }
            try fillSine(buffer, startFrame: q * Self.quantum, amp: 0.2)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: Self.quantum)
            try append(buffer, to: &output)
        }
        let toggleFrame = toggleQuantum * Self.quantum

        // Bypassed steady: bit-exact dry. Fade start: EXACTLY dry (toward
        // gain 0 at progress 0). Settled: exact ×4 from the next quantum.
        for frame in 0..<toggleFrame where output[frame] != sineSample(frame, amp: 0.2) {
            Issue.record("bypassed region not bit-exact dry at \(frame)")
            break
        }
        #expect(output[toggleFrame] == sineSample(toggleFrame, amp: 0.2))
        var maxCurveError: Float = 0
        for frame in toggleFrame..<(toggleFrame + Self.quantum) {
            let input = sineSample(frame, amp: 0.2)
            let progress = Float(frame - toggleFrame) / Float(Self.fadeFrames)
            let (toward, away) = ChainEffectUnit.crossfadeGains(progress: progress)
            let expected = (4 * input) * toward + input * away  // wet rises, dry falls
            maxCurveError = max(maxCurveError, abs(output[frame] - expected))
        }
        #expect(maxCurveError < 1e-6)
        for frame in (toggleFrame + Self.quantum)..<output.count
        where output[frame] != 4 * sineSample(frame, amp: 0.2) {
            Issue.record("settled region not exact ×4 at \(frame)")
            break
        }
        print("[measured] m15-f un-bypass fade-in: curve error \(maxCurveError)")
    }

    @Test("un-bypass never replays stale tails through the fade-in (resetFlag law) and the ring restarts clean")
    func unbypassFadesInOnCleanRing() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let fxID = UUID()
        // 50 ms delay = 2 400 frames @ 48 kHz.
        func descriptor(bypassed: Bool) -> EffectDescriptor {
            EffectDescriptor(id: fxID, kind: .delay, isBypassed: bypassed,
                             delay: DelayParams(timeMs: 50, feedback: 0.5, mix: 0.5))
        }
        state.sync(descriptors: [descriptor(bypassed: false)], sampleRate: Self.rate)

        var output: [Float] = []
        let buffer = try makeBuffer(frames: Self.quantum)
        // Active content fills the ring, then bypass freezes it with a tail.
        for q in 0..<20 {
            if q == 12 {
                state.sync(descriptors: [descriptor(bypassed: true)], sampleRate: Self.rate)
            }
            try fillSine(buffer, startFrame: q * Self.quantum, amp: 0.5)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: Self.quantum)
            try append(buffer, to: &output)
        }
        // Steady-bypass region (post-fade) is bit-exact dry.
        for frame in (14 * Self.quantum)..<(20 * Self.quantum)
        where output[frame] != sineSample(frame, amp: 0.5) {
            Issue.record("steady bypass not bit-exact dry at \(frame)")
            break
        }

        // Un-bypass into SILENCE: the armed reset must clear the frozen ring
        // BEFORE the fade-in processes — nothing may replay.
        state.sync(descriptors: [descriptor(bypassed: false)], sampleRate: Self.rate)
        for _ in 0..<20 {
            try fillSilence(buffer)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: Self.quantum)
            try append(buffer, to: &output)
        }
        let staleTailPeak = TestSignals.peak(
            output, in: (20 * Self.quantum)..<(40 * Self.quantum))
        #expect(staleTailPeak == 0)

        // The ring is alive and clean: one content quantum echoes at exactly
        // the delay spacing. Phase offset 1_000 so the quantum's FIRST sample
        // is non-zero (a sine from phase 0 starts at 0 and would shift the
        // onset detector by one frame).
        try fillSine(buffer, startFrame: 1_000, amp: 0.5)
        processor.process(bufferList: buffer.mutableAudioBufferList,
                          frameCount: Self.quantum)
        try append(buffer, to: &output)
        for _ in 0..<10 {
            try fillSilence(buffer)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: Self.quantum)
            try append(buffer, to: &output)
        }
        let contentStart = 40 * Self.quantum
        let echoOnset = TestSignals.firstFrame(
            in: Array(output[(contentStart + Self.quantum)...]), exceeding: 1e-6)
            .map { $0 + contentStart + Self.quantum }
        let echoPeak = TestSignals.peak(
            output, in: (contentStart + 2_400)..<(contentStart + 2_400 + Self.quantum))
        #expect(echoOnset == contentStart + 2_400)
        #expect(echoPeak > 0.1)
        print("[measured] m15-f clean-ring restart: stale-tail peak \(staleTailPeak), "
              + "echo onset \(String(describing: echoOnset)) (expected \(contentStart + 2_400)), "
              + "echo peak \(echoPeak)")
    }

    @Test("mid-fade reversal is continuous and settles exact (position inversion)")
    func midFadeReversalIsContinuousAndSettlesExact() throws {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let fxID = UUID()
        func descriptor(bypassed: Bool) -> EffectDescriptor {
            EffectDescriptor(id: fxID, kind: .gain, isBypassed: bypassed,
                             gain: GainParams(gainLinear: 4))
        }
        state.sync(descriptors: [descriptor(bypassed: false)], sampleRate: Self.rate)

        // 128-frame quanta: reverse after 256 fade frames (progress 0.53).
        let small = 128
        var output: [Float] = []
        let buffer = try makeBuffer(frames: small)
        for q in 0..<40 {
            if q == 10 {
                state.sync(descriptors: [descriptor(bypassed: true)], sampleRate: Self.rate)
            }
            if q == 12 {  // 256 frames into the 480-frame fade-out
                state.sync(descriptors: [descriptor(bypassed: false)], sampleRate: Self.rate)
            }
            try fillSine(buffer, startFrame: q * small, amp: 0.2)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: small)
            try append(buffer, to: &output)
        }

        // Continuity throughout (natural slope 0.046 + fade slope bound).
        var maxSampleDelta: Float = 0
        for index in 1..<(20 * small) {
            maxSampleDelta = max(maxSampleDelta, abs(output[index] - output[index - 1]))
        }
        #expect(maxSampleDelta <= 0.05)

        // Position inversion: 256 fade frames remain after the reversal —
        // settled EXACT ×4 from frame 12·128 + 256 on (quantum boundary 14).
        let settleFrame = 14 * small
        for frame in settleFrame..<output.count
        where output[frame] != 4 * sineSample(frame, amp: 0.2) {
            Issue.record("post-reversal region not exact ×4 at \(frame)")
            break
        }
        // No reset fired on the reversal (un-bypass arms one, but the fade
        // never completed toward bypass — gain state must be seamless): the
        // reversal-point sample stays inside the plateau envelope.
        #expect(abs(output[12 * small]) <= 0.81)
        print("[measured] m15-f mid-fade reversal: max per-sample Δ \(maxSampleDelta), "
              + "settled exact at frame \(settleFrame)")
    }

    // MARK: - Edit-seam echo blip A/B (the m14-d mechanism, deterministic)

    /// Builds the m14-d race deterministically: content fills the ring, the
    /// flush arms `passes` resets, then ONE in-flight pre-flush quantum walks
    /// (the reset consumes at its top, the stale signal enters the wiped
    /// ring), then silence. Returns (output, leakStart).
    private func runEditSeam(passes: UInt32) throws -> ([Float], Int) {
        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        let descriptor = EffectDescriptor(
            id: UUID(), kind: .delay,
            delay: DelayParams(timeMs: 100, feedback: 0.5, mix: 0.5))  // 4 800 frames
        state.sync(descriptors: [descriptor], sampleRate: Self.rate)

        var output: [Float] = []
        let buffer = try makeBuffer(frames: Self.quantum)
        for q in 0..<10 {
            try fillSine(buffer, startFrame: q * Self.quantum, amp: 0.5)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: Self.quantum)
            try append(buffer, to: &output)
        }
        processor.requestResetAll(passes: passes)
        try fillSine(buffer, startFrame: 10 * Self.quantum, amp: 0.5)
        processor.process(bufferList: buffer.mutableAudioBufferList,
                          frameCount: Self.quantum)
        try append(buffer, to: &output)
        for _ in 0..<30 {
            try fillSilence(buffer)
            processor.process(bufferList: buffer.mutableAudioBufferList,
                              frameCount: Self.quantum)
            try append(buffer, to: &output)
        }
        return (output, 10 * Self.quantum)
    }

    @Test("NEGATIVE CONTROL: a single-armed flush leaks the in-flight quantum — echo blips at exactly the delay spacing (the m14-d class)")
    func editSeamEchoBlipSingleArmLeaks() throws {
        let (output, leakStart) = try runEditSeam(passes: 1)
        let delaySamples = 4_800
        let gapPeak = TestSignals.peak(
            output, in: (leakStart + Self.quantum)..<(leakStart + delaySamples))
        let echoPeak = TestSignals.peak(
            output,
            in: (leakStart + delaySamples)..<(leakStart + delaySamples + Self.quantum))
        let echoOnset = TestSignals.firstFrame(
            in: Array(output[(leakStart + Self.quantum)...]), exceeding: 1e-6)
            .map { $0 + leakStart + Self.quantum }
        let repeatPeak = TestSignals.peak(
            output,
            in: (leakStart + 2 * delaySamples)..<(leakStart + 2 * delaySamples + Self.quantum))
        #expect(gapPeak == 0)                            // the ring WAS wiped…
        #expect(echoPeak > 0.1)                          // …then re-dirtied: the blip
        #expect(echoOnset == leakStart + delaySamples)   // at exactly the delay spacing
        #expect(repeatPeak > 0.04)                       // decaying repeats
        print("[measured] m15-f edit-seam NEGATIVE control (single arm): gap \(gapPeak), "
              + "echo \(echoPeak) at \(String(describing: echoOnset)) "
              + "(delay spacing \(leakStart + delaySamples)), repeat \(repeatPeak)")
    }

    @Test("THE FIX: the double-armed flush wipes the leaked quantum — the first post-restart quantum renders on a clean ring")
    func editSeamEchoBlipDoubleArmRendersCleanRing() throws {
        let (output, leakStart) = try runEditSeam(passes: 2)
        // The leaked quantum itself plays out dry·(1−mix) EXACTLY: reset #1
        // consumed at its top (delayed == 0), the wet path ran.
        var leakError: Float = 0
        for frame in leakStart..<(leakStart + Self.quantum) {
            leakError = max(leakError,
                            abs(output[frame] - 0.5 * sineSample(frame, amp: 0.5)))
        }
        #expect(leakError == 0)
        // Everything after it is IDENTICALLY silent: reset #2 consumed on the
        // next walk, before the echo could emerge.
        let postPeak = TestSignals.peak(
            output, in: (leakStart + Self.quantum)..<output.count)
        #expect(postPeak == 0)
        print("[measured] m15-f edit-seam FIX (double arm): leaked-quantum error \(leakError), "
              + "post-seam peak \(postPeak) (pre-fix class: echo 0.250 + repeat 0.125)")
    }

    @Test("stopAllPlayers double-arms the chain reset LIVE and single-arms under manual rendering")
    func stopAllPlayersDoubleArmsLiveOnly() throws {
        let fxID = UUID()
        let track = Track(name: "FX", kind: .audio,
                          effects: [EffectDescriptor(id: fxID, kind: .delay)])

        // LIVE-mode engine (never started; no clips → no players to poke).
        let liveEngine = AVAudioEngine()
        let liveGraph = PlaybackGraph(engine: liveEngine)
        _ = liveGraph.reconcile(tracks: [track])
        liveGraph.applyParameters(tracks: [track])
        let liveUnit = try #require(
            liveGraph.effectChainState(forTrack: track.id)?.unit(forEffect: fxID))
        #expect(liveUnit.pendingResetPasses == 0)
        liveGraph.stopAllPlayers()
        #expect(liveUnit.pendingResetPasses == 2)

        // Manual-rendering engine: single arm (control and render are
        // serialized — no in-flight quantum exists; offline content restarts
        // on the next pull, where a second reset would cut a real tail).
        let manualEngine = AVAudioEngine()
        let format = try #require(
            AVAudioFormat(standardFormatWithSampleRate: Self.rate, channels: 2))
        try manualEngine.enableManualRenderingMode(.offline, format: format,
                                                   maximumFrameCount: 4_096)
        let manualGraph = PlaybackGraph(engine: manualEngine)
        _ = manualGraph.reconcile(tracks: [track])
        manualGraph.applyParameters(tracks: [track])
        let manualUnit = try #require(
            manualGraph.effectChainState(forTrack: track.id)?.unit(forEffect: fxID))
        manualGraph.stopAllPlayers()
        #expect(manualUnit.pendingResetPasses == 1)
        print("[measured] m15-f flush arms: live \(liveUnit.pendingResetPasses), "
              + "manual \(manualUnit.pendingResetPasses)")
    }

    // MARK: - Crossfade length plumbing

    @Test("crossfade length tracks the prepared sample rate (10 ms at 48/96/44.1 kHz)")
    func crossfadeLengthTracksPreparedRate() throws {
        let fxID = UUID()
        let descriptors = [EffectDescriptor(id: fxID, kind: .gain)]

        let processor = EffectChainProcessor()
        let state = EffectChainState(processor: processor)
        state.sync(descriptors: descriptors, sampleRate: 48_000)
        let unit = try #require(state.unit(forEffect: fxID))
        #expect(unit.crossfadeFrames == 480)

        // Rate change re-prepares surviving units — the length follows.
        state.sync(descriptors: descriptors, sampleRate: 96_000)
        #expect(state.unit(forEffect: fxID) === unit)
        #expect(unit.crossfadeFrames == 960)

        let state44 = EffectChainState(processor: EffectChainProcessor())
        state44.sync(descriptors: descriptors, sampleRate: 44_100)
        #expect(try #require(state44.unit(forEffect: fxID)).crossfadeFrames == 441)
    }

    // MARK: - Null era (byte-identity with no toggles and no seams)

    @Test("null era: a no-toggle chain render is byte-identical to the pre-m15f tree (pinned SHA)")
    func nullEraChainRenderByteIdentical() throws {
        let fixtures = try TestSignals.fixtures()
        let track = Track(name: "SRC", kind: .audio,
                          clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)],
                          effects: [
                              EffectDescriptor(kind: .delay,
                                               delay: DelayParams(timeMs: 250, feedback: 0.4,
                                                                  mix: 0.3)),
                              EffectDescriptor(kind: .gain,
                                               gain: GainParams(gainLinear: 0.5)),
                              EffectDescriptor(kind: .saturator, isBypassed: true),
                          ])
        func sha(_ audio: RenderedAudio) -> String {
            var hasher = SHA256()
            for channel in audio.channelData {
                channel.withUnsafeBufferPointer { samples in
                    hasher.update(data: Data(buffer: samples))
                }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        let first = try OfflineRenderer().render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, durationSeconds: 2.0)
        let second = try OfflineRenderer().render(
            tracks: [track], tempoMap: TempoMap(constantBPM: 120),
            fromBeat: 0, durationSeconds: 2.0)
        print("[era] m15f chain null SHA \(sha(first)) (repeat \(sha(second)))")
        #expect(sha(first) == sha(second))
        // Measured on the PRE-change tree, 2026-07-13 (active delay tails, an
        // active gain, and a constant-BYPASSED saturator through the walk).
        #expect(sha(first)
            == "0a6fc1c5d68c025bbde78b7fb4c9c3062f606494a042936316ff323d743bcd45")
    }
}
