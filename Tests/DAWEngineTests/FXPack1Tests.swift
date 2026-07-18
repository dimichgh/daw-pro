import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (iii) built-in FX pack 1 — parametric EQ, compressor, limiter — proven
/// with known-signal assertions: Goertzel band gains for the EQ, static-curve
/// and time-constant measurements for the compressor, hard ceiling and exact
/// lookahead latency for the limiter, plus chain-latency summing and
/// whole-chain determinism through the offline renderer.
@MainActor
@Suite("FX pack 1 — dynamics & tone", .serialized)
struct FXPack1Tests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers

    /// sin at `frequency`, `amplitude`, phase 0 — one channel.
    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    private func mix(_ a: [Float], _ b: [Float]) -> [Float] {
        zip(a, b).map(+)
    }

    /// Goertzel single-bin amplitude estimate over `range` (≈ the sinusoid's
    /// peak amplitude when `range` spans whole periods).
    private func goertzel(_ samples: [Float], frequency: Double, in range: Range<Int>) -> Double {
        let w = 2.0 * Double.pi * frequency / Self.sampleRate
        let coeff = 2.0 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for index in range {
            let s0 = Double(samples[index]) + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(power, 0).squareRoot() * 2.0 / Double(range.count)
    }

    private func dB(_ ratio: Double) -> Double { 20.0 * log10(ratio) }

    /// Runs `channels` through `effect` in 512-frame quanta (state continuity
    /// across quantum boundaries included in the proof). Returns the output.
    private func processChunked(_ effect: any EffectRendering,
                                channels: [[Float]], chunk: Int = 512) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
        var output = channels.map { _ in [Float]() }
        let total = channels[0].count
        var offset = 0
        while offset < total {
            let frames = min(chunk, total - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<channels.count {
                for frame in 0..<frames {
                    data[channel][frame] = channels[channel][offset + frame]
                }
            }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            for channel in 0..<channels.count {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: frames))
            }
            offset += frames
        }
        return output
    }

    private func maxAbs(_ samples: [Float], in range: Range<Int>? = nil) -> Float {
        var maximum: Float = 0
        for index in (range ?? samples.indices) {
            maximum = max(maximum, abs(samples[index]))
        }
        return maximum
    }

    private func assertAllFinite(_ channels: [[Float]]) {
        for channel in channels {
            let allFinite = channel.allSatisfy { $0.isFinite }
            #expect(allFinite)  // NaN/Inf guard
        }
    }

    /// Settled analysis window: skip 4 800 frames (100 ms — filters settle),
    /// then a whole second (integral periods for every test frequency).
    private static let settle = 4_800
    private static let window = settle..<(settle + 48_000)
    private static let totalFrames = settle + 48_000

    // MARK: - EQ

    @Test("eq peak boost raises the target band only (+12 dB @ 1 kHz, 100 Hz flat)")
    func eqPeakBoostRaisesTargetBandOnly() throws {
        let dry = mix(sine(1_000, amplitude: 0.25, frames: Self.totalFrames),
                      sine(100, amplitude: 0.25, frames: Self.totalFrames))
        let eq = EQEffect(params: EQParams(peak1Freq: 1_000, peak1GainDb: 12, peak1Q: 1))
        eq.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(eq, channels: [dry, dry])

        let gain1k = dB(goertzel(wet[0], frequency: 1_000, in: Self.window)
                        / goertzel(dry, frequency: 1_000, in: Self.window))
        let gain100 = dB(goertzel(wet[0], frequency: 100, in: Self.window)
                         / goertzel(dry, frequency: 100, in: Self.window))
        print("[measured] eq peak +12 dB @ 1 kHz: 1 kHz gain \(gain1k) dB, 100 Hz gain \(gain100) dB")
        #expect(abs(gain1k - 12) < 0.5)
        #expect(abs(gain100) < 0.5)
        // Both channels get identical filtering.
        #expect(wet[0] == wet[1])
        assertAllFinite(wet)
    }

    @Test("eq at neutral settings is transparent (all gains 0 dB)")
    func eqNeutralSettingsAreTransparent() throws {
        let dry = mix(sine(1_000, amplitude: 0.25, frames: Self.totalFrames),
                      sine(100, amplitude: 0.25, frames: Self.totalFrames))
        let eq = EQEffect()  // every band at 0 dB
        eq.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(eq, channels: [dry, dry])
        var maxDiff: Float = 0
        for frame in 0..<dry.count {
            maxDiff = max(maxDiff, abs(wet[0][frame] - dry[frame]))
        }
        // Measured 0: a 0 dB band is skipped outright, so neutral is a
        // bit-exact no-op by construction (stronger than the ≤ 1e-7 bar).
        print("[measured] eq neutral null: max |wet − dry| = \(maxDiff)")
        #expect(maxDiff == 0)
    }

    @Test("eq shelves shape the low and high ends")
    func eqShelvesShapeLowAndHighEnds() throws {
        // Low shelf −12 dB @ 100 Hz: drops 50 Hz (analog prototype ≈ −11.1 dB
        // one octave below the corner), leaves 5 kHz untouched.
        let lowDry = mix(sine(50, amplitude: 0.25, frames: Self.totalFrames),
                         sine(5_000, amplitude: 0.25, frames: Self.totalFrames))
        let lowShelf = EQEffect(params: EQParams(lowShelfFreq: 100, lowShelfGainDb: -12))
        lowShelf.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let lowWet = try processChunked(lowShelf, channels: [lowDry, lowDry])
        let gain50 = dB(goertzel(lowWet[0], frequency: 50, in: Self.window)
                        / goertzel(lowDry, frequency: 50, in: Self.window))
        let gain5k = dB(goertzel(lowWet[0], frequency: 5_000, in: Self.window)
                        / goertzel(lowDry, frequency: 5_000, in: Self.window))
        print("[measured] low shelf −12 dB @ 100 Hz: 50 Hz \(gain50) dB, 5 kHz \(gain5k) dB")
        #expect(gain50 < -9.0 && gain50 > -13.5)
        #expect(abs(gain5k) < 0.5)

        // High shelf +6 dB @ 8 kHz: raises 12 kHz, leaves 500 Hz untouched.
        let highDry = mix(sine(500, amplitude: 0.25, frames: Self.totalFrames),
                          sine(12_000, amplitude: 0.25, frames: Self.totalFrames))
        let highShelf = EQEffect(params: EQParams(highShelfFreq: 8_000, highShelfGainDb: 6))
        highShelf.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let highWet = try processChunked(highShelf, channels: [highDry, highDry])
        let gain12k = dB(goertzel(highWet[0], frequency: 12_000, in: Self.window)
                         / goertzel(highDry, frequency: 12_000, in: Self.window))
        let gain500 = dB(goertzel(highWet[0], frequency: 500, in: Self.window)
                         / goertzel(highDry, frequency: 500, in: Self.window))
        print("[measured] high shelf +6 dB @ 8 kHz: 12 kHz \(gain12k) dB, 500 Hz \(gain500) dB")
        #expect(gain12k > 4.0 && gain12k < 6.5)
        #expect(abs(gain500) < 0.5)
        assertAllFinite(lowWet)
        assertAllFinite(highWet)
    }

    // MARK: - Compressor

    @Test("compressor static curve matches the ratio (thr+12 in → thr+3 out at 4:1)")
    func compressorStaticCurveMatchesRatio() throws {
        // Steady 1 kHz sine at threshold + 12 dB peak (−18 + 12 = −6 dBFS).
        let amplitude = pow(10.0, -6.0 / 20.0)
        let frames = 96_000  // 2 s — attack/release fully settled at the tail
        let dry = sine(1_000, amplitude: amplitude, frames: frames)
        let comp = CompressorEffect(params: CompressorParams(
            thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100, kneeDb: 6, makeupDb: 0))
        comp.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(comp, channels: [dry, dry])

        // 12 dB over at 4:1 → 3 dB over out: peak ≈ −15 dBFS in the settled tail.
        let settledWindow = 72_000..<96_000
        let outPeakDb = dB(Double(maxAbs(wet[0], in: settledWindow)))
        print("[measured] compressor static curve: in peak −6 dBFS → out peak \(outPeakDb) dBFS "
              + "(expected −15 ± 1)")
        #expect(abs(outPeakDb - (-15.0)) < 1.0)

        // Below threshold (and below the knee): exact unity — bit-exact null.
        let quiet = sine(1_000, amplitude: pow(10.0, -30.0 / 20.0), frames: 48_000)
        let comp2 = CompressorEffect(params: CompressorParams(
            thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100, kneeDb: 6, makeupDb: 0))
        comp2.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let quietWet = try processChunked(comp2, channels: [quiet, quiet])
        var maxDiff: Float = 0
        for frame in 0..<quiet.count {
            maxDiff = max(maxDiff, abs(quietWet[0][frame] - quiet[frame]))
        }
        print("[measured] compressor below-threshold null: max |wet − dry| = \(maxDiff)")
        #expect(maxDiff == 0)
        assertAllFinite(wet)
    }

    @Test("compressor attack and release follow the time constants (63% points)")
    func compressorAttackAndReleaseFollowTimeConstants() throws {
        // DC step fixture: quiet → threshold+12 dB at frame 1 000 → quiet at
        // frame 37 000. DC through a gain stage makes gain[n] = out[n]/in[n]
        // directly measurable per sample.
        let loud = Float(pow(10.0, -6.0 / 20.0))   // −6 dBFS = thr + 12
        let quiet: Float = 0.01                     // −40 dBFS, below the knee
        let stepAt = 1_000, dropAt = 37_000, total = 72_000
        var dry = [Float](repeating: quiet, count: total)
        for frame in stepAt..<dropAt { dry[frame] = loud }

        let comp = CompressorEffect(params: CompressorParams(
            thresholdDb: -18, ratio: 4, attackMs: 10, releaseMs: 100, kneeDb: 6, makeupDb: 0))
        comp.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(comp, channels: [dry, dry])
        let gains = (0..<total).map { Double(wet[0][$0]) / Double(dry[$0]) }

        // Attack: one-pole target is −9 dB reduction; 63.2% of that in dB is
        // −5.6906 dB → gain 0.5195, nominally 480 samples (10 ms) after the
        // step. Window tolerance ×2 both ways.
        let attackTarget = pow(10.0, -9.0 * (1.0 - exp(-1.0)) / 20.0)
        let attackHit = try #require(
            (stepAt..<dropAt).first(where: { gains[$0] <= attackTarget })) - stepAt
        print("[measured] compressor attack 63% point: \(attackHit) samples "
              + "(nominal 480 @ 10 ms, window 240…960)")
        #expect(attackHit >= 240 && attackHit <= 960)

        // Release: envelope decays from −9 dB toward 0; 63.2% recovered is
        // −3.3109 dB → gain 0.6832, nominally 4 800 samples (100 ms) after
        // the drop.
        let releaseTarget = pow(10.0, -9.0 * exp(-1.0) / 20.0)
        let releaseHit = try #require(
            (dropAt..<total).first(where: { gains[$0] >= releaseTarget })) - dropAt
        print("[measured] compressor release 63% point: \(releaseHit) samples "
              + "(nominal 4 800 @ 100 ms, window 2 400…9 600)")
        #expect(releaseHit >= 2_400 && releaseHit <= 9_600)
    }

    // MARK: - Limiter

    @Test("limiter output never exceeds the ceiling on +6 dBFS bursts")
    func limiterNeverExceedsCeiling() throws {
        // Pathological program: alternating 100 ms bursts of a +6 dBFS 1 kHz
        // sine (amplitude 2.0) and −20 dBFS quiet, five cycles.
        var dry = [Float]()
        for _ in 0..<5 {
            dry += sine(1_000, amplitude: 2.0, frames: 4_800)
            dry += sine(1_000, amplitude: 0.1, frames: 4_800)
        }
        let ceilingLinear = Float(pow(10.0, -1.0 / 20.0))  // −1 dBFS
        let limiter = LimiterEffect(params: LimiterParams(ceilingDb: -1, releaseMs: 50))
        limiter.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(limiter, channels: [dry, dry])

        // Hard guarantee: EVERY output sample ≤ ceiling (the lookahead design
        // holds from sample 0, stricter than the post-settle bar).
        let outPeak = max(maxAbs(wet[0]), maxAbs(wet[1]))
        print("[measured] limiter ceiling: max |out| = \(outPeak) vs ceiling \(ceilingLinear) "
              + "(input peak 2.0 = +6 dBFS)")
        #expect(outPeak <= ceilingLinear + 1e-6)
        #expect(outPeak > ceilingLinear * 0.9)  // it actually limited, not muted
        assertAllFinite(wet)

        // Below the ceiling: unity — output is the delayed input, bit-exact.
        let calm = sine(1_000, amplitude: 0.5, frames: 24_000)
        let limiter2 = LimiterEffect(params: LimiterParams(ceilingDb: -1, releaseMs: 50))
        limiter2.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let calmWet = try processChunked(limiter2, channels: [calm, calm])
        var maxDiff: Float = 0
        for frame in 240..<calm.count {
            maxDiff = max(maxDiff, abs(calmWet[0][frame] - calm[frame - 240]))
        }
        print("[measured] limiter below-ceiling null (240-sample shift): max diff = \(maxDiff)")
        #expect(maxDiff == 0)
        #expect(maxAbs(calmWet[0], in: 0..<240) == 0)  // primed with silence
    }

    @Test("limiter reports and exhibits the 5 ms lookahead latency")
    func limiterReportsAndExhibitsLookaheadLatency() throws {
        let limiter = LimiterEffect()
        limiter.prepare(sampleRate: 48_000, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(limiter.latencySamples == 240)
        #expect(limiter.latencySamples == Int((0.005 * 48_000).rounded()))

        // A below-ceiling impulse at frame 100 must arrive EXACTLY at 340.
        var dry = [Float](repeating: 0, count: 1_024)
        dry[100] = 0.5
        let wet = try processChunked(limiter, channels: [dry, dry])
        let hits = wet[0].indices.filter { wet[0][$0] != 0 }
        print("[measured] limiter impulse: in @ 100 → out @ \(hits), value \(wet[0][340])")
        #expect(hits == [340])
        #expect(wet[0][340] == 0.5)

        // Rate dependence: 44.1 kHz → round(0.005 × 44 100) = 221.
        let limiter44 = LimiterEffect()
        limiter44.prepare(sampleRate: 44_100, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(limiter44.latencySamples == 221)

        // m19-j: 24 kHz — the rate a Bluetooth headset's default device
        // really runs at in mic mode (AirPods). The latency is
        // round(lookaheadSeconds × rate) at EVERY rate, never a constant;
        // this is the by-construction proof behind the device-rate-derived
        // PDC expectations in MasterChainRenderTests C7 / EngineRebuildTests.
        let limiter24 = LimiterEffect()
        limiter24.prepare(sampleRate: 24_000, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(limiter24.latencySamples == 120)
        #expect(limiter24.latencySamples
            == Int((LimiterParams.lookaheadSeconds * 24_000).rounded()))
    }

    // MARK: - Chain latency + determinism (graph level)

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

    @Test("chain latency sums across effects (gain 0 + limiter 240; bypass drops it)")
    func chainLatencySumsAcrossEffects() throws {
        let fixtures = try TestSignals.fixtures()
        let gainFX = EffectDescriptor(kind: .gain, gain: GainParams(gainLinear: 0.5))
        var limiterFX = EffectDescriptor(kind: .limiter)
        var track = Track(name: "SRC", kind: .audio,
                          clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)],
                          effects: [gainFX, limiterFX])
        let (_, graph) = try makeManualEngine()
        graph.reconcile(tracks: [track])
        graph.applyParameters(tracks: [track])
        let active = graph.chainLatencySamples(forTrack: track.id)
        print("[measured] chain latency gain+limiter: \(active) samples (expected 240)")
        #expect(active == 240)

        // Per-effect query (feeds the snapshot's per-effect latencySamples
        // via AudioEngine.effectLatencySamples → the ProjectStore forwarder):
        // the LIVE limiter instance reports its real 240 @ 48 kHz.
        let perLimiter = graph.effectLatencySamples(forTrack: track.id, effectID: limiterFX.id)
        let perGain = graph.effectLatencySamples(forTrack: track.id, effectID: gainFX.id)
        print("[measured] per-effect latency: limiter \(perLimiter), gain \(perGain)")
        #expect(perLimiter == 240)
        #expect(perGain == 0)
        #expect(graph.effectLatencySamples(forTrack: track.id, effectID: UUID()) == 0)  // unknown effect
        #expect(graph.effectLatencySamples(forTrack: UUID(), effectID: limiterFX.id) == 0)  // unknown track

        // Sum-non-bypassed rule: a bypassed limiter contributes nothing to
        // the TRACK total, while the per-effect value stays 240 (latency is
        // a property of the effect instance, not of its bypass state).
        limiterFX.isBypassed = true
        track.effects = [gainFX, limiterFX]
        graph.reconcile(tracks: [track])
        graph.applyParameters(tracks: [track])
        let bypassed = graph.chainLatencySamples(forTrack: track.id)
        print("[measured] chain latency with limiter bypassed: \(bypassed) samples "
              + "(per-effect still \(graph.effectLatencySamples(forTrack: track.id, effectID: limiterFX.id)))")
        #expect(bypassed == 0)
        #expect(graph.effectLatencySamples(forTrack: track.id, effectID: limiterFX.id) == 240)
    }

    @Test("a full eq→compressor→limiter chain renders deterministically")
    func fxChainRendersDeterministically() throws {
        let fixtures = try TestSignals.fixtures()
        let effects = [
            EffectDescriptor(kind: .eq, eq: EQParams(peak1Freq: 1_000, peak1GainDb: 6)),
            EffectDescriptor(kind: .compressor,
                             compressor: CompressorParams(thresholdDb: -18, ratio: 4)),
            EffectDescriptor(kind: .limiter, limiter: LimiterParams(ceilingDb: -6)),
        ]
        let track = Track(name: "SRC", kind: .audio,
                          clips: [Clip(name: "clip", startBeat: 0, lengthBeats: 4,
                                       audioFileURL: fixtures.cos1k48)],
                          effects: effects)
        let first = try OfflineRenderer().render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                                 fromBeat: 0, durationSeconds: 1.0)
        let second = try OfflineRenderer().render(tracks: [track], tempoMap: TempoMap(constantBPM: 120),
                                                  fromBeat: 0, durationSeconds: 1.0)
        var maxDiff: Float = 0
        var peak: Float = 0
        for channel in 0..<2 {
            for frame in 0..<first.channelData[channel].count {
                maxDiff = max(maxDiff,
                              abs(first.channelData[channel][frame]
                                  - second.channelData[channel][frame]))
                peak = max(peak, abs(first.channelData[channel][frame]))
            }
            let allFinite = first.channelData[channel].allSatisfy { $0.isFinite }
            #expect(allFinite)  // NaN/Inf guard
        }
        let ceiling = Float(pow(10.0, -6.0 / 20.0))
        print("[measured] chain determinism: max render-to-render diff = \(maxDiff), "
              + "peak \(peak) (ceiling \(ceiling))")
        #expect(maxDiff == 0)                    // identical renders null exact
        #expect(peak > 0.1)                      // real signal came through
        #expect(peak <= ceiling + 1e-6)          // limiter held through the chain
    }
}
