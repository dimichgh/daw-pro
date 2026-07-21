import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m22-b Phase 1 — F7, the anti-drift pin (design-m22b-eq-curve-editor §8.2):
/// the DAWCore `EQFilterResponse` PREDICTION is held against the REAL
/// `EQEffect` render, sine by sine. This is the "the curve provably never
/// drifts from the engine" gate — if the shared math and the DSP ever
/// diverge, this fails before any UI draws a lie.
///
/// The measurement harness is a LOCAL copy of the EQv2Tests goertzel idiom
/// (that suite's helpers are private, and the standing null pin file is
/// UNTOUCHABLE by law — copied, not shared).
@MainActor
@Suite("EQ response pin — predicted vs rendered (m22-b F7)", .serialized)
struct EQResponsePinTests {
    private static let sampleRate = 48_000.0

    /// Settled analysis window: 100 ms settle, then one whole second (integer
    /// Hz test tones → an integer number of cycles per window → no leakage).
    private static let settle = 4_800
    private static let window = settle..<(settle + 48_000)
    private static let totalFrames = settle + 48_000

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    /// Goertzel single-bin amplitude estimate over `range`.
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

    /// Runs `channels` through `effect` in 512-frame quanta.
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

    /// The §8.2 rich param set: every band shaping at once — HP 24 @ 120,
    /// LS −4 @ 150 Q 2, P1 +5 @ 800 Q 3, P2 −6 @ 2.5 k Q 0.8, HS +3 @ 8 k
    /// (legacy nil Q), LP 12 @ 12 k.
    private static let richParams = EQParams(
        lowShelfFreq: 150, lowShelfGainDb: -4,
        peak1Freq: 800, peak1GainDb: 5, peak1Q: 3,
        peak2Freq: 2_500, peak2GainDb: -6, peak2Q: 0.8,
        highShelfFreq: 8_000, highShelfGainDb: 3,
        highPassFreq: 120, highPassSlopeDbPerOct: 24,
        lowPassFreq: 12_000, lowPassSlopeDbPerOct: 12,
        lowShelfQ: 2)

    @Test("F7: predicted response matches the rendered EQEffect within 0.1 dB")
    func predictedResponseMatchesRenderedOutput() throws {
        // 10 log-spaced probe frequencies, rounded to integer Hz so the 1 s
        // goertzel window holds an integer cycle count (leak-free bins).
        let frequencies = EQFilterResponse.logFrequencyGrid(count: 10, lo: 40, hi: 16_000)
            .map { $0.rounded() }
        var maxDelta = 0.0
        for frequency in frequencies {
            let dry = sine(frequency, amplitude: 0.2, frames: Self.totalFrames)
            let eq = EQEffect(params: Self.richParams)
            eq.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                       channelCount: 2)
            let wet = try processChunked(eq, channels: [dry, dry])[0]
            let measured = dB(goertzel(wet, frequency: frequency, in: Self.window)
                              / goertzel(dry, frequency: frequency, in: Self.window))
            let predicted = EQFilterResponse.responseDb(
                params: Self.richParams, frequency: frequency, sampleRate: Self.sampleRate)
            let delta = abs(predicted - measured)
            maxDelta = max(maxDelta, delta)
            print("[measured] F7 \(Int(frequency)) Hz: predicted \(predicted) dB, "
                  + "rendered \(measured) dB, |Δ| \(delta) dB")
            #expect(delta <= 0.1, "\(Int(frequency)) Hz")
            #expect(wet.allSatisfy { $0.isFinite })
        }
        print("[measured] F7 max |predicted − rendered| = \(maxDelta) dB over "
              + "\(frequencies.count) frequencies")
    }
}
