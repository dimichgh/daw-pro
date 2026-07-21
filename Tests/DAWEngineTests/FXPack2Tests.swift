import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M4 (iv) built-in FX pack 2 — reverb, delay, saturator, gate, chorus —
/// proven with known-signal assertions: impulse tail growth/decay for the
/// reverb, exact-sample echo offsets and feedback ratios for the delay,
/// Goertzel odd-harmonic ratios for the saturator, exact silence/unity and
/// hold bridging for the gate, static-shift null failure for the chorus,
/// bit-exact mix-0 dry paths, render-to-render determinism, and model
/// persistence for all five kinds.
@MainActor
@Suite("FX pack 2 — space & color", .serialized)
struct FXPack2Tests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (FXPack1Tests conventions)

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

    private func energy(_ samples: [Float], in range: Range<Int>) -> Double {
        var total = 0.0
        for index in range {
            total += Double(samples[index]) * Double(samples[index])
        }
        return total
    }

    private func assertAllFinite(_ channels: [[Float]]) {
        for channel in channels {
            let allFinite = channel.allSatisfy { $0.isFinite }
            #expect(allFinite)  // NaN/Inf guard
        }
    }

    /// Bit-exact null: every output sample EQUALS the input sample.
    private func assertBitExactDry(_ wet: [[Float]], _ dry: [Float]) {
        for channel in wet {
            var maxDiff: Float = 0
            for frame in 0..<dry.count {
                maxDiff = max(maxDiff, abs(channel[frame] - dry[frame]))
            }
            #expect(maxDiff == 0)
        }
    }

    /// Stereo test program: two sines, well inside full scale.
    private func program(frames: Int) -> [Float] {
        mix(sine(1_000, amplitude: 0.25, frames: frames),
            sine(313, amplitude: 0.2, frames: frames))
    }

    // MARK: - Reverb

    @Test("reverb impulse grows a tail and decays")
    func reverbImpulseGrowsATailAndDecays() throws {
        var dry = [Float](repeating: 0, count: 48_000)
        dry[0] = 1
        let reverb = ReverbEffect(params: ReverbParams(
            roomSize: 0.5, damping: 0.3, mix: 1, preDelayMs: 0, width: 1))
        reverb.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(reverb, channels: [dry, dry])

        // Wet energy exists well after the impulse (tail rings ≥ 100 ms)…
        let at100ms = energy(wet[0], in: 4_800..<9_600)
        // …and the late window carries LESS energy than the early one (decay).
        let early = energy(wet[0], in: 2_400..<12_000)     // 50–250 ms
        let late = energy(wet[0], in: 28_800..<38_400)     // 600–800 ms
        print("[measured] reverb impulse: energy @100–200 ms \(at100ms), "
              + "early(50–250 ms) \(early), late(600–800 ms) \(late)")
        #expect(at100ms > 1e-8)
        #expect(late < early)
        #expect(late > 0)  // still ringing, not truncated
        assertAllFinite(wet)
    }

    @Test("reverb mix 0 is bit-exact dry")
    func reverbMixZeroIsBitExactDry() throws {
        let dry = program(frames: 24_000)
        let reverb = ReverbEffect(params: ReverbParams(mix: 0))
        reverb.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(reverb, channels: [dry, dry])
        assertBitExactDry(wet, dry)
    }

    // MARK: - Delay

    @Test("delay echo lands at exactly round(timeMs × rate / 1000) samples")
    func delayEchoLandsAtExactSampleOffset() throws {
        // 350 ms @ 48 kHz → exactly 16 800 samples; 333 ms → 15 984.
        for (timeMs, expected) in [(350.0, 16_800), (333.0, 15_984), (1.0, 48)] {
            var dry = [Float](repeating: 0, count: expected + 2_000)
            dry[0] = 1
            let delay = DelayEffect(params: DelayParams(
                timeMs: timeMs, feedback: 0, mix: 1))
            delay.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
            let wet = try processChunked(delay, channels: [dry, dry])
            let hits = wet[0].indices.filter { wet[0][$0] != 0 }
            print("[measured] delay \(timeMs) ms: echo at \(hits) (expected [\(expected)]), "
                  + "value \(wet[0][expected])")
            #expect(hits == [expected])
            #expect(wet[0][expected] == 1)
        }
    }

    @Test("delay feedback produces decaying repeats (second ≈ feedback × first)")
    func delayFeedbackProducesDecayingRepeats() throws {
        // 100 ms delay, feedback 0.5. The feedback high-cut is DC-unity (a
        // one-pole low-pass), so the SIGNED SUM over each echo window is an
        // LP-shape-independent amplitude measure: sum₂ / sum₁ = feedback.
        let delaySamples = 4_800
        var dry = [Float](repeating: 0, count: 14_000)
        dry[0] = 1
        let delay = DelayEffect(params: DelayParams(
            timeMs: 100, feedback: 0.5, mix: 1, highCutHz: 8_000))
        delay.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(delay, channels: [dry, dry])

        func windowSum(around center: Int) -> Double {
            var total = 0.0
            for index in (center - 10)..<(center + 400) { total += Double(wet[0][index]) }
            return total
        }
        let first = windowSum(around: delaySamples)
        let second = windowSum(around: 2 * delaySamples)
        let ratio = second / first
        print("[measured] delay feedback: first echo sum \(first), second \(second), "
              + "ratio \(ratio) (expected 0.5 ± 10%)")
        #expect(first > 0.9)                    // first echo is the unfiltered impulse
        #expect(abs(ratio - 0.5) < 0.05)        // ±10% of 0.5
        assertAllFinite(wet)
    }

    @Test("delay mix 0 is bit-exact dry")
    func delayMixZeroIsBitExactDry() throws {
        let dry = program(frames: 24_000)
        let delay = DelayEffect(params: DelayParams(mix: 0))
        delay.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(delay, channels: [dry, dry])
        assertBitExactDry(wet, dry)
    }

    @Test("ping-pong crossfeeds the feedback between channels")
    func delayPingPongCrossfeeds() throws {
        // Impulse on the LEFT only: first echo stays left; the SECOND echo
        // (first trip through the crossfed feedback) lands on the RIGHT.
        let delaySamples = 4_800
        var dryL = [Float](repeating: 0, count: 14_000)
        dryL[0] = 1
        let dryR = [Float](repeating: 0, count: 14_000)
        let delay = DelayEffect(params: DelayParams(
            timeMs: 100, feedback: 0.5, mix: 1, pingPong: 1, highCutHz: 20_000))
        delay.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(delay, channels: [dryL, dryR])
        let firstL = energy(wet[0], in: (delaySamples - 10)..<(delaySamples + 400))
        let firstR = energy(wet[1], in: (delaySamples - 10)..<(delaySamples + 400))
        let secondL = energy(wet[0], in: (2 * delaySamples - 10)..<(2 * delaySamples + 400))
        let secondR = energy(wet[1], in: (2 * delaySamples - 10)..<(2 * delaySamples + 400))
        print("[measured] ping-pong: first L \(firstL) R \(firstR); "
              + "second L \(secondL) R \(secondR)")
        #expect(firstL > 0.9 && firstR == 0)    // first echo: left only
        #expect(secondR > 0.9 * 0.25 * 0.8)     // second echo crossed to the right
        #expect(secondL < secondR * 1e-6)       // …and left is silent there
    }

    // MARK: - Saturator

    @Test("saturator generates odd harmonics (H3 ≫ floor, H2 ≪ H3)")
    func saturatorGeneratesOddHarmonics() throws {
        let dry = sine(1_000, amplitude: 0.5, frames: 48_000)
        let saturator = SaturatorEffect(params: SaturatorParams(
            driveDb: 24, mix: 1, outputDb: 0))
        saturator.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(saturator, channels: [dry, dry])

        let window = 0..<48_000  // whole periods of 1/2/3 kHz
        let h1 = goertzel(wet[0], frequency: 1_000, in: window)
        let h2 = goertzel(wet[0], frequency: 2_000, in: window)
        let h3 = goertzel(wet[0], frequency: 3_000, in: window)
        print("[measured] saturator 24 dB drive: H1 \(h1), H2 \(h2), H3 \(h3), "
              + "H3/H1 \(h3 / h1), H2/H3 \(h2 / h3)")
        #expect(h3 / h1 > 0.05)          // strong odd-harmonic generation
        #expect(h2 < h3 * 1e-3)          // tanh is odd-symmetric: even floor only
        assertAllFinite(wet)
    }

    @Test("saturator mix 0 is bit-exact dry")
    func saturatorMixZeroIsBitExactDry() throws {
        let dry = program(frames: 24_000)
        let saturator = SaturatorEffect(params: SaturatorParams(mix: 0))
        saturator.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(saturator, channels: [dry, dry])
        assertBitExactDry(wet, dry)
    }

    // MARK: - Gate

    @Test("gate silences below threshold and passes above (exact 0 / bit-exact 1)")
    func gateSilencesBelowThresholdAndPassesAbove() throws {
        // Loud 1 kHz sine at −12 dBFS for 0.5 s, then a CONSTANT 0.001
        // (−60 dBFS, below the −20 dB threshold) for 0.5 s: after the
        // detector decay (~220 samples) + hold (10 ms) + release (20 ms) the
        // output must be EXACTLY zero despite the nonzero input.
        let dropAt = 24_000, total = 48_000
        var dry = sine(1_000, amplitude: 0.25, frames: total)
        for frame in dropAt..<total { dry[frame] = 0.001 }
        let gate = GateEffect(params: GateParams(
            thresholdDb: -20, attackMs: 1, holdMs: 10, releaseMs: 20))
        gate.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(gate, channels: [dry, dry])

        // Fully open = bit-exact passthrough (no multiply at all).
        var maxDiff: Float = 0
        for frame in 2_400..<23_800 {
            maxDiff = max(maxDiff, abs(wet[0][frame] - dry[frame]))
        }
        // Fully closed = true silence (input still 0.001 there).
        let firstZero = try #require((dropAt..<total).first(where: { frame in
            (frame..<min(frame + 100, total)).allSatisfy { wet[0][$0] == 0 }
        }))
        let closedResidual = (27_000..<total).map { abs(wet[0][$0]) }.max() ?? 0
        print("[measured] gate: open null max diff \(maxDiff), "
              + "first sustained zero at \(firstZero - dropAt) samples after the drop "
              + "(detector ~220 + hold 480 + release 960), closed residual \(closedResidual)")
        #expect(maxDiff == 0)
        #expect(closedResidual == 0)
        #expect(firstZero - dropAt < 2_400)  // closed well inside 50 ms
        assertAllFinite(wet)
    }

    @Test("gate hold keeps the gate open across short gaps")
    func gateHoldKeepsOpenAcrossShortGaps() throws {
        // DC program: loud 0.25, a 20 ms gap at 0.001, loud again. With
        // hold 50 ms > gap, the gate must stay FULLY open (gain exactly 1)
        // through the whole gap: output == 0.001 bit-exact everywhere in it.
        let gapStart = 14_400, gapEnd = 15_360, total = 24_000  // 20 ms gap
        var dry = [Float](repeating: 0.25, count: total)
        for frame in gapStart..<gapEnd { dry[frame] = 0.001 }
        let held = GateEffect(params: GateParams(
            thresholdDb: -20, attackMs: 1, holdMs: 50, releaseMs: 5))
        held.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wetHeld = try processChunked(held, channels: [dry, dry])
        let gapMin = (gapStart..<gapEnd).map { wetHeld[0][$0] }.min() ?? 0
        print("[measured] gate hold 50 ms across 20 ms gap: min gap output \(gapMin) "
              + "(expected exactly 0.001)")
        #expect(gapMin == 0.001)  // gain stayed exactly 1 — hold bridged the gap

        // Control: hold 0 + 5 ms release closes INSIDE the same gap
        // (detector decay ~220 + release 240 ≪ 960), proving the hold above
        // (not a slow release) is what bridged it.
        let unheld = GateEffect(params: GateParams(
            thresholdDb: -20, attackMs: 1, holdMs: 0, releaseMs: 5))
        unheld.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wetUnheld = try processChunked(unheld, channels: [dry, dry])
        let closedInGap = (gapStart..<gapEnd).contains { wetUnheld[0][$0] == 0 }
        #expect(closedInGap)
    }

    // MARK: - Chorus

    @Test("chorus modulates delay over time (no static shift nulls it)")
    func chorusModulatesDelayOverTime() throws {
        let dry = sine(440, amplitude: 0.5, frames: 48_000)
        let chorus = ChorusEffect(params: ChorusParams(rateHz: 2, depthMs: 5, mix: 1))
        chorus.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(chorus, channels: [dry, dry])
        assertAllFinite(wet)

        // Against EVERY static integer shift (0…30 ms), the residual stays a
        // large fraction of the output energy: the tap moves over time, so no
        // fixed delay of the dry signal reproduces the output.
        let window = 2_400..<26_400
        let outEnergy = energy(wet[0], in: window)
        var minResidual = Double.greatestFiniteMagnitude
        var bestShift = 0
        for shift in 0...1_440 {
            var residual = 0.0
            for frame in window {
                let diff = Double(wet[0][frame]) - Double(dry[frame - shift >= 0 ? frame - shift : 0])
                residual += diff * diff
            }
            if residual < minResidual {
                minResidual = residual
                bestShift = shift
            }
        }
        print("[measured] chorus static-null: out energy \(outEnergy), best static shift "
              + "\(bestShift) leaves residual \(minResidual) "
              + "(\(minResidual / outEnergy) of output energy)")
        #expect(minResidual > 0.2 * outEnergy)

        // Full param sweep: corners of rate × depth × mix stay finite.
        let sweepInput = program(frames: 9_600)
        for rate in [ChorusParams.rateRange.lowerBound, ChorusParams.rateRange.upperBound] {
            for depth in [ChorusParams.depthRange.lowerBound, ChorusParams.depthRange.upperBound] {
                for mixValue in [0.0, 0.5, 1.0] {
                    let swept = ChorusEffect(params: ChorusParams(
                        rateHz: rate, depthMs: depth, mix: mixValue))
                    swept.prepare(sampleRate: Self.sampleRate,
                                  maxFramesPerQuantum: 512, channelCount: 2)
                    let out = try processChunked(swept, channels: [sweepInput, sweepInput])
                    assertAllFinite(out)
                }
            }
        }
    }

    @Test("chorus mix 0 is bit-exact dry")
    func chorusMixZeroIsBitExactDry() throws {
        let dry = program(frames: 24_000)
        let chorus = ChorusEffect(params: ChorusParams(mix: 0))
        chorus.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(chorus, channels: [dry, dry])
        assertBitExactDry(wet, dry)
    }

    // MARK: - Determinism (all five)

    @Test("all five pack-2 effects render deterministically (null 0.0)")
    func fxPack2RendersDeterministically() throws {
        let dry = program(frames: 24_000)
        let makers: [(String, () -> any EffectRendering)] = [
            ("reverb", { ReverbEffect(params: ReverbParams(mix: 0.5)) }),
            ("delay", { DelayEffect(params: DelayParams(timeMs: 125, feedback: 0.4, mix: 0.5)) }),
            ("saturator", { SaturatorEffect(params: SaturatorParams(driveDb: 18)) }),
            ("gate", { GateEffect(params: GateParams(thresholdDb: -30)) }),
            ("chorus", { ChorusEffect(params: ChorusParams(rateHz: 1.3, depthMs: 4, mix: 0.5)) }),
        ]
        for (name, make) in makers {
            let first = make()
            first.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
            let a = try processChunked(first, channels: [dry, dry])
            let second = make()
            second.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
            let b = try processChunked(second, channels: [dry, dry])
            var maxDiff: Float = 0
            for channel in 0..<2 {
                for frame in 0..<dry.count {
                    maxDiff = max(maxDiff, abs(a[channel][frame] - b[channel][frame]))
                }
            }
            print("[measured] \(name) render-to-render null: max diff \(maxDiff)")
            #expect(maxDiff == 0)
            assertAllFinite(a)
        }
    }

    // MARK: - Model: describe + persistence

    @Test("all nine kinds describe; pack-2 params round-trip through the bundle")
    func fxPack2AllKindsPersistAndDescribe() throws {
        // The kind table now spans both packs plus the M4 (v) hosted-AU kind
        // (order = declaration order).
        #expect(EffectDescriptor.Kind.allCases.map(\.rawValue) == [
            "gain", "eq", "compressor", "limiter",
            "reverb", "delay", "saturator", "gate", "chorus", "audioUnit",
        ])
        #expect(EffectParamSpec.specs(for: .reverb).map(\.name)
                == ["roomSize", "damping", "mix", "preDelayMs", "width"])
        // m22-f: sync/division APPENDED so the five legacy automation slots
        // (0…4) never move.
        #expect(EffectParamSpec.specs(for: .delay).map(\.name)
                == ["timeMs", "feedback", "mix", "pingPong", "highCutHz", "sync", "division"])
        #expect(EffectParamSpec.specs(for: .saturator).map(\.name)
                == ["driveDb", "mix", "outputDb"])
        #expect(EffectParamSpec.specs(for: .gate).map(\.name)
                == ["thresholdDb", "attackMs", "holdMs", "releaseMs"])
        #expect(EffectParamSpec.specs(for: .chorus).map(\.name)
                == ["rateHz", "depthMs", "mix"])

        // Round-trip: one of each pack-2 kind with a non-default param.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fxpack2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        let track = store.addTrack(name: "Wet", kind: .audio)
        let edits: [(EffectDescriptor.Kind, String, Double)] = [
            (.reverb, "roomSize", 0.8),
            (.delay, "timeMs", 500),
            (.saturator, "driveDb", 24),
            (.gate, "thresholdDb", -55),
            (.chorus, "rateHz", 2.5),
        ]
        for (kind, name, value) in edits {
            let effect = try store.addEffect(toTrack: track.id, kind: kind)
            _ = try store.setEffectParam(trackID: track.id, effectID: effect.id,
                                         name: name, value: value)
        }
        let path = dir.appendingPathComponent("Pack2").path
        try store.saveProject(to: path)

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reTrack = try #require(reopened.tracks.first(where: { $0.name == "Wet" }))
        #expect(reTrack.effects.map(\.kind)
                == [.reverb, .delay, .saturator, .gate, .chorus])
        #expect(reTrack.effects[0].resolvedReverb.roomSize == 0.8)
        #expect(reTrack.effects[0].resolvedReverb.mix == 0.35)      // default survives
        #expect(reTrack.effects[1].resolvedDelay.timeMs == 500)
        #expect(reTrack.effects[1].resolvedDelay.pingPong == 0)     // default survives
        #expect(reTrack.effects[2].resolvedSaturator.driveDb == 24)
        #expect(reTrack.effects[3].resolvedGate.thresholdDb == -55)
        #expect(reTrack.effects[4].resolvedChorus.rateHz == 2.5)
    }
}
