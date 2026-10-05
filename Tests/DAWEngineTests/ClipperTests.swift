import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, DELIBERATELY **NOT** `@MainActor` — the `FreqShifterTests`
// / `PhaserTests` / `TransientShaperTests` rule, for their reasons: the main
// actor is one serialization point for the whole test process, these tests
// render hundreds of thousands of frames, and `MainActorOccupancySiteTests`
// Leg C pins the main-actor SUITE count at its cap with ZERO slack.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-ac — the `.clipper` insert and the `Oversampler` primitive under it.
///
/// ⭐⭐ **THE CENTRAL LEG IS L1, AND IT IS THE ONLY MEASUREMENT THAT CAN TELL AN
/// OVERSAMPLED CLIPPER FROM A NAIVE ONE.** Both are loud. Both are audible. Both
/// produce byte-distinct renders. A demo harness cannot separate them and
/// neither can any "did the output change" assertion — the 2026-09-19 lesson,
/// where a completely inert effect passed a byte-difference gate.
///
/// The one real quality number a clipper has is its **ALIAS FLOOR**: hard
/// clipping generates harmonics far above Nyquist, and at 1× they FOLD BACK onto
/// frequencies unrelated to anything playing. Oversampling exists to suppress
/// exactly that and nothing else. So L1 drives a single sine into a hard clip
/// and reads the energy in the bins the folds land in — bins that are EMPTY
/// before the effect runs — at each of the three shipped factors.
///
/// ⛔ THE FIXTURE IS CHOSEN SO THOSE BINS ARE UNAMBIGUOUS. `f0` = 6300 Hz at
/// 48 kHz: hard clipping is odd-symmetric, so the only real harmonics are
/// 6300 (H1) and 18900 (H3) — every other odd harmonic is above Nyquist and
/// folds. The folds land at 16500 (H5), 3900 (H7), 8700 (H9), 14100 (H13) and
/// 1500 (H15), none of which is a multiple of 6300. A shift in ANY of those five
/// bins is aliasing and can be nothing else.
///
/// ⚠️ H11's fold at 21300 Hz is EXCLUDED from the headline sum, on purpose and
/// not to flatter the number: it sits above `OversamplerDesign`'s protected band
/// (0.42 × 48 kHz = 20 160 Hz), so the filter is only partway into its stopband
/// there. L1c reports it separately.
///
/// ⚠️ EVERY measured frequency is a multiple of 300 Hz and the analysis window is
/// 9 600 samples (5 Hz bins), so every component of the clipped signal sits on an
/// EXACT bin. Rectangular-window leakage between exact bins is zero by
/// orthogonality, which is why no window function appears here and why an "empty"
/// bin can be believed.
@Suite("m39-ac — the clipper clips, and oversampling removes the fold-back", .serialized)
struct ClipperTests {

    private static let sampleRate = 48_000.0

    /// The fixture tone and everything derived from it. All multiples of 300 Hz.
    private static let f0 = 6_300.0
    private static let thirdHarmonic = 18_900.0
    /// Where H5, H7, H9, H13 and H15 land after folding at 48 kHz. Each is
    /// `|k·f0 − n·fs|` for the odd k that exceeds Nyquist, and none coincides
    /// with a harmonic of `f0`.
    private static let aliasBins = [1_500.0, 3_900.0, 8_700.0, 14_100.0, 16_500.0]
    /// H11's fold, above the protected band — reported, never summed.
    private static let unprotectedAliasBin = 21_300.0

    private static let warmupFrames = 2_048
    private static let analysisFrames = 9_600   // 5 Hz bins; 48000/9600 = 5

    // MARK: - Instruments

    /// Goertzel magnitude at `hz` over `buffer`, normalised so a full-scale sine
    /// on an exact bin reads 1.0.
    private static func goertzel(_ buffer: ArraySlice<Float>, hz: Double) -> Double {
        let k = 2 * Double.pi * hz / sampleRate
        let coefficient = 2 * cos(k)
        var s1 = 0.0, s2 = 0.0
        for sample in buffer {
            let s0 = Double(sample) + coefficient * s1 - s2
            s2 = s1
            s1 = s0
        }
        let re = s1 - s2 * cos(k)
        let im = s2 * sin(k)
        return 2 * (re * re + im * im).squareRoot() / Double(buffer.count)
    }

    private static func db(_ magnitude: Double) -> Double {
        20 * log10(max(magnitude, 1e-18))
    }

    private static func sine(hz: Double, frames: Int, amplitude: Double) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    /// Renders `channels` through `effect` in `chunk`-frame quanta, exactly as
    /// the graph would. `poke` runs before each quantum.
    private func processChunked(
        _ effect: ClipperEffect, channels: [[Float]], chunk: Int = 512,
        poke: ((ClipperEffect, Int) -> Void)? = nil
    ) throws -> [[Float]] {
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
        var output = channels.map { _ in [Float]() }
        let total = channels[0].count
        var offset = 0
        var quantum = 0
        while offset < total {
            let frames = min(chunk, total - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<channels.count {
                for frame in 0..<frames {
                    data[channel][frame] = channels[channel][offset + frame]
                }
            }
            poke?(effect, quantum)
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            for channel in 0..<channels.count {
                output[channel].append(contentsOf:
                    UnsafeBufferPointer(start: data[channel], count: frames))
            }
            offset += frames
            quantum += 1
        }
        return output
    }

    private func clip(_ params: ClipperParams, _ input: [Float],
                      chunk: Int = 512) throws -> [Float] {
        let effect = ClipperEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// The five protected alias bins' TOTAL power, in dB. Power, not the loudest
    /// bin: oversampling can move energy between folds, and a single-bin metric
    /// would reward that instead of measuring it.
    private static func aliasFloorDb(_ window: ArraySlice<Float>) -> Double {
        var power = 0.0
        for hz in aliasBins {
            let magnitude = goertzel(window, hz: hz)
            power += magnitude * magnitude
        }
        return 10 * log10(max(power, 1e-36))
    }

    /// Renders the L1 fixture at one factor and returns the analysis window.
    private func clippedTone(oversampling: Double,
                             mode: Double = 0, driveDb: Double = 12) throws -> [Float] {
        let frames = Self.warmupFrames + Self.analysisFrames
        let input = Self.sine(hz: Self.f0, frames: frames, amplitude: 0.5)
        let rendered = try clip(ClipperParams(driveDb: driveDb, ceilingDb: -6, mode: mode,
                                              oversampling: oversampling, mix: 1, outputDb: 0),
                                input)
        return Array(rendered[Self.warmupFrames...])
    }

    // MARK: - L1: THE ALIAS FLOOR — the number this whole item exists for

    @Test("L1 — oversampling drops the alias floor, measured in dB at 1x / 2x / 4x")
    func oversamplingSuppressesTheAliasFloor() throws {
        var floors: [Int: Double] = [:]
        var harmonics: [Int: (h1: Double, h3: Double)] = [:]
        for factor in [1, 2, 4] {
            let window = try clippedTone(oversampling: Double(factor))[...]
            let floor = Self.aliasFloorDb(window)
            floors[factor] = floor
            harmonics[factor] = (Self.db(Self.goertzel(window, hz: Self.f0)),
                                 Self.db(Self.goertzel(window, hz: Self.thirdHarmonic)))
            var perBin = ""
            for hz in Self.aliasBins {
                perBin += " \(Int(hz))Hz=\(String(format: "%.2f", Self.db(Self.goertzel(window, hz: hz))))"
            }
            print("[measured] oversampling \(factor)x — alias floor "
                  + "\(String(format: "%.2f", floor)) dB ·"
                  + " H1=\(String(format: "%.2f", harmonics[factor]!.h1))"
                  + " H3=\(String(format: "%.2f", harmonics[factor]!.h3)) ·"
                  + " per-bin:\(perBin)")
        }

        let one = try #require(floors[1])
        let two = try #require(floors[2])
        let four = try #require(floors[4])
        let deltaTwo = one - two
        let deltaFour = one - four
        print("[measured] ⭐ ALIAS-FLOOR DELTA — 1x→2x: \(String(format: "%.2f", deltaTwo)) dB, "
              + "1x→4x: \(String(format: "%.2f", deltaFour)) dB")

        // ⛔ A NAIVE CLIPPER MUST ACTUALLY ALIAS, or every "it went down"
        // measurement below is a comparison against nothing. -60 dB relative to
        // a full-scale bin is far above any analysis floor here.
        #expect(one > -60, Comment(rawValue:
            "the 1x alias floor is \(one) dB — nothing folded back, so there is nothing for "
            + "oversampling to remove and this whole measurement is vacuous"))
        // THE GATE. Set well below the measurement so a rebuild cannot flicker
        // it, and far above the failure it catches: an oversampler that is not
        // filtering collapses the delta to ~0 dB, not to 20.
        #expect(deltaFour >= 30, Comment(rawValue:
            "4x oversampling dropped the alias floor by only \(deltaFour) dB (floor 30). "
            + "Either the anti-imaging filter, the anti-alias filter, or the factor itself is "
            + "not reaching the render path."))
        #expect(deltaTwo >= 10, Comment(rawValue:
            "2x oversampling dropped the alias floor by only \(deltaTwo) dB (floor 10)"))
        // MORE oversampling is MONOTONICALLY better. This is what the parameter
        // note promises a user, and it is the leg that would catch 2x and 4x
        // being wired to the same kernel.
        #expect(four < two, Comment(rawValue:
            "4x (\(four) dB) is not quieter than 2x (\(two) dB) — the factor is not selecting "
            + "a different filter"))
        #expect(two < one)
    }

    /// ⛔⛔ THE LEG THAT STOPS L1 BEING SATISFIED BY A LOW-PASS FILTER. Anything
    /// that quietly removed high frequencies would drop the alias floor too — and
    /// would also remove H3, which is a REAL harmonic of the clipping and must
    /// survive. If H3 moves between factors, the effect is filtering rather than
    /// oversampling.
    @Test("L1b — the CLIPPING is unchanged: H1 and H3 hold within 0.5 dB across all three factors")
    func oversamplingDoesNotJustFilter() throws {
        var h1: [Double] = []
        var h3: [Double] = []
        for factor in [1, 2, 4] {
            let window = try clippedTone(oversampling: Double(factor))[...]
            h1.append(Self.db(Self.goertzel(window, hz: Self.f0)))
            h3.append(Self.db(Self.goertzel(window, hz: Self.thirdHarmonic)))
        }
        print("[measured] H1 across 1x/2x/4x: \(h1.map { String(format: "%.3f", $0) }) · "
              + "H3: \(h3.map { String(format: "%.3f", $0) })")
        // H3 is at 18 900 Hz, inside the pinned-ripple passband (0.42 × 48 kHz
        // = 20 160 Hz), so the filters must leave it essentially alone.
        let h3Spread = (h3.max() ?? 0) - (h3.min() ?? 0)
        let h1Spread = (h1.max() ?? 0) - (h1.min() ?? 0)
        #expect(h3Spread < 0.5, Comment(rawValue:
            "H3 varies by \(h3Spread) dB across factors — oversampling is changing the CLIPPING "
            + "(or low-passing the result), not just moving the aliases"))
        #expect(h1Spread < 0.5)
        // Both are real signal, not floor.
        #expect((h1.min() ?? -99) > -20)
        #expect((h3.min() ?? -99) > -40, Comment(rawValue:
            "H3 is only \(h3.min() ?? -99) dB — the fixture is barely clipping, so L1 is "
            + "measuring a fold-back that is not really there"))
    }

    @Test("L1c — POSITIVE CONTROL: the probe reads the alias bins as EMPTY on an unclipped tone")
    func theProbeReportsEmptyBinsWhenNothingAliases() throws {
        // Same tone, same effect, but the ceiling is ABOVE the driven peak, so
        // nothing clips and nothing can fold. Every alias bin must read floor.
        // ⭐ Without this, "the alias bins are quiet at 4x" could equally mean
        // "the probe cannot see anything at all".
        let frames = Self.warmupFrames + Self.analysisFrames
        let input = Self.sine(hz: Self.f0, frames: frames, amplitude: 0.5)
        let rendered = try clip(ClipperParams(driveDb: 0, ceilingDb: 0, mode: 0,
                                              oversampling: 1, mix: 1, outputDb: 0), input)
        let window = Array(rendered[Self.warmupFrames...])[...]
        let floor = Self.aliasFloorDb(window)
        let fundamental = Self.db(Self.goertzel(window, hz: Self.f0))
        print("[control] unclipped tone — alias floor \(String(format: "%.2f", floor)) dB, "
              + "H1 \(String(format: "%.2f", fundamental)) dB")
        #expect(fundamental > -12, "the probe cannot even see the tone it was given")
        #expect(floor < -100, Comment(rawValue:
            "an UNCLIPPED tone shows an alias floor of \(floor) dB — the probe is reading "
            + "something other than aliasing, so L1's numbers mean nothing"))
        // And the unprotected bin is empty too, so L1d's number is about the
        // filter rather than about the fixture.
        #expect(Self.db(Self.goertzel(window, hz: Self.unprotectedAliasBin)) < -100)
    }

    @Test("L1d — the bin ABOVE the protected band is reported, not hidden")
    func theUnprotectedBinIsReported() throws {
        var levels: [Double] = []
        for factor in [1, 2, 4] {
            let window = try clippedTone(oversampling: Double(factor))[...]
            levels.append(Self.db(Self.goertzel(window, hz: Self.unprotectedAliasBin)))
        }
        print("[measured] H11's fold at \(Int(Self.unprotectedAliasBin)) Hz (ABOVE the "
              + "\((1 - OversamplerDesign.stopbandEdgeFraction) * Self.sampleRate) Hz protected "
              + "band) across 1x/2x/4x: \(levels.map { String(format: "%.2f", $0) })")
        // It still improves — just not by the protected band's margin, which is
        // exactly why it is excluded from L1's sum rather than quietly included.
        #expect(levels[2] < levels[0])
    }

    // MARK: - L2: the ceiling is a ceiling

    @Test("L2 — at 1x no output sample exceeds the ceiling, and the oversampled overshoot is measured")
    func theCeilingBoundsTheOutput() throws {
        let frames = Self.warmupFrames + Self.analysisFrames
        let input = Self.sine(hz: 1_000, frames: frames, amplitude: 0.9)
        let ceilingDb = -6.0
        let ceiling = pow(10.0, ceilingDb / 20.0)
        var overshoots: [Int: Double] = [:]
        for factor in [1, 2, 4] {
            let rendered = try clip(ClipperParams(driveDb: 18, ceilingDb: ceilingDb, mode: 0,
                                                  oversampling: Double(factor), mix: 1,
                                                  outputDb: 0), input)
            let peak = rendered[Self.warmupFrames...].map { abs(Double($0)) }.max() ?? 0
            let overshootDb = 20 * log10(max(peak, 1e-12) / ceiling)
            overshoots[factor] = overshootDb
            print("[measured] \(factor)x — peak \(peak) vs ceiling \(ceiling): "
                  + "\(String(format: "%+.3f", overshootDb)) dB")
        }
        // ⛔ At 1x the whole path is a pure delay around a memoryless clip, so
        // the bound is EXACT. This is the leg that proves `ceilingDb` means
        // what its note says.
        let one = try #require(overshoots[1])
        #expect(one <= 0, Comment(rawValue:
            "at 1x a sample exceeded the ceiling by \(one) dB — the shaper is not bounding "
            + "the output, which is the one promise this kind makes"))
        // ⚠️ At 2x/4x the decimation filter reconstructs the band-limited wave
        // through the clipped corners, and a band-limited wave through a corner
        // OVERSHOOTS (Gibbs). That is real physics, it is what a true-peak meter
        // reads on any clipped signal, and it is stated in `ceilingDb`'s note as
        // "up to about a decibel". It is NOT fixed by clipping again afterwards:
        // that would put the aliasing straight back.
        for factor in [2, 4] {
            let overshoot = try #require(overshoots[factor])
            #expect(overshoot > 0, Comment(rawValue:
                "\(factor)x overshoot is \(overshoot) dB — a band-limited reconstruction "
                + "through a hard corner MUST overshoot, so 0 suggests the decimation filter "
                + "is not running"))
            #expect(overshoot < 1.5, Comment(rawValue:
                "\(factor)x overshoots the ceiling by \(overshoot) dB, more than the ~1 dB the "
                + "parameter note promises"))
        }
    }

    // MARK: - L3/L4: the latency contract

    @Test("L3 — the round trip delays by EXACTLY 32 samples at every factor")
    func groupDelayIsThirtyTwoSamplesAtEveryFactor() throws {
        let latency = ClipperParams.latencySamples
        for factor in [1, 2, 4] {
            // An impulse well below the ceiling: the path is LINEAR, so what
            // comes out is the filter pair's impulse response and nothing else.
            var input = [Float](repeating: 0, count: 512)
            input[64] = 0.25
            let rendered = try clip(ClipperParams(driveDb: 0, ceilingDb: 0, mode: 0,
                                                  oversampling: Double(factor), mix: 1,
                                                  outputDb: 0), input)
            var peakIndex = 0
            var peak = 0.0
            for (index, value) in rendered.enumerated() where abs(Double(value)) > peak {
                peak = abs(Double(value))
                peakIndex = index
            }
            print("[measured] \(factor)x impulse: peak at sample \(peakIndex) "
                  + "(input at 64), amplitude \(peak)")
            #expect(peakIndex == 64 + latency, Comment(rawValue:
                "\(factor)x put the impulse peak at \(peakIndex); 64 + \(latency) was expected. "
                + "A factor-dependent latency is a SILENT PDC bug — see ClipperEffect DESIGN §3."))
            // Linear phase: the response is symmetric about its peak.
            let left = abs(Double(rendered[peakIndex - 5]))
            let right = abs(Double(rendered[peakIndex + 5]))
            #expect(abs(left - right) < 1e-6 * max(1, peak), Comment(rawValue:
                "\(factor)x response is asymmetric about the peak (\(left) vs \(right)) — "
                + "not linear phase, so the reported group delay is not the real one"))
            // ⛔ At factor 1 the claim is stronger: the kernel degenerates to a
            // pure delay, so the impulse comes back at FULL amplitude.
            if factor == 1 {
                #expect(peak == 0.25, "1x is not a pure delay: peak \(peak), expected 0.25")
            }
        }
    }

    @Test("L4 — latencySamples is 32 at every rate, factor and setting")
    func latencyIsConstant() {
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            for factor in [1.0, 2.0, 4.0] {
                let effect = ClipperEffect(params: ClipperParams(
                    driveDb: 24, ceilingDb: -12, mode: 1, oversampling: factor,
                    mix: 0.4, outputDb: -6))
                effect.prepare(sampleRate: rate, maxFramesPerQuantum: 512, channelCount: 2)
                #expect(effect.latencySamples == 32)
                #expect(effect.latencySamples == OversamplerDesign.latencySamples)
            }
        }
    }

    // MARK: - L5: the identity law

    /// ⛔⛔ THIS KIND'S IDENTITY LAW IS A **DELAYED** IDENTITY, NOT rule 6.0.7's
    /// untouched buffer, and that is deliberate — see `ClipperEffect` DESIGN §4.
    /// An effect that reports 32 samples of latency and then passes audio
    /// through undelayed is mis-aligned against everything PDC compensates
    /// around it.
    @Test("L5 — mix == 0 is a BIT-EXACT 32-sample delay, including -0.0 and subnormals")
    func mixZeroIsABitExactDelayedIdentity() throws {
        let latency = ClipperParams.latencySamples
        // Every OTHER knob non-default and extreme, so this leg proves `mix`
        // ALONE is the gate rather than "nothing was configured".
        let params = ClipperParams(driveDb: 30, ceilingDb: -24, mode: 1,
                                   oversampling: 4, mix: 0, outputDb: 18)
        var input = [Float](repeating: 0, count: 1_024)
        for index in 0..<input.count {
            input[index] = Float(0.4 * sin(Double(index) * 0.17))
        }
        // The values a tolerance comparison cannot see.
        input[100] = -0.0
        input[101] = 0.0
        input[102] = Float.leastNonzeroMagnitude          // subnormal
        input[103] = -Float.leastNonzeroMagnitude
        input[104] = Float.leastNormalMagnitude
        input[105] = -1.0
        input[106] = 1.0
        input[107] = 12.5                                  // way over the ceiling
        let rendered = try clip(params, input)
        #expect(rendered.count == input.count)
        // The first `latency` outputs are the ring's initial zeros.
        for index in 0..<latency {
            #expect(rendered[index].bitPattern == Float(0).bitPattern,
                    "sample \(index) is \(rendered[index]), not the ring's initial zero")
        }
        var mismatches = 0
        for index in latency..<input.count {
            if rendered[index].bitPattern != input[index - latency].bitPattern {
                mismatches += 1
                if mismatches <= 3 {
                    Issue.record("""
                        sample \(index): got \(rendered[index]) \
                        (bits \(rendered[index].bitPattern)), expected \
                        \(input[index - latency]) (bits \(input[index - latency].bitPattern))
                        """)
                }
            }
        }
        #expect(mismatches == 0, "\(mismatches) samples differ from the delayed input")
        // Non-vacuity: the SAME params at mix 1 must differ, or "bit-exact"
        // would be true of an effect that does nothing at any setting.
        var wetParams = params
        wetParams.mix = 1
        let wet = try clip(wetParams, input)
        var differing = 0
        for index in latency..<input.count where wet[index] != rendered[index] { differing += 1 }
        #expect(differing > 100, Comment(rawValue:
            "only \(differing) samples changed at mix 1 — the mix-0 identity above passed "
            + "because the effect does nothing, not because mix 0 is a bypass"))
    }

    // MARK: - L6: the two modes really differ

    @Test("L6 — soft mode generates less harmonic content than hard at the same drive")
    func softModeIsGentlerThanHard() throws {
        let hard = try clippedTone(oversampling: 4, mode: 0)[...]
        let soft = try clippedTone(oversampling: 4, mode: 1)[...]
        let hardH3 = Self.db(Self.goertzel(hard, hz: Self.thirdHarmonic))
        let softH3 = Self.db(Self.goertzel(soft, hz: Self.thirdHarmonic))
        print("[measured] H3 — hard \(String(format: "%.2f", hardH3)) dB, "
              + "soft \(String(format: "%.2f", softH3)) dB")
        #expect(softH3 < hardH3, Comment(rawValue:
            "soft mode's H3 (\(softH3) dB) is not below hard mode's (\(hardH3) dB) — the mode "
            + "switch is not reaching the shaper"))
        // Both still CLIP: the fundamental survives and a third harmonic exists.
        #expect(softH3 > -80)
        #expect(Self.db(Self.goertzel(soft, hz: Self.f0)) > -20)
        // Soft mode still respects the ceiling, exactly, at 1x.
        let ceiling = pow(10.0, -6.0 / 20.0)
        let frames = Self.warmupFrames + 2_048
        let input = Self.sine(hz: 1_000, frames: frames, amplitude: 0.9)
        let rendered = try clip(ClipperParams(driveDb: 24, ceilingDb: -6, mode: 1,
                                              oversampling: 1, mix: 1, outputDb: 0), input)
        let peak = rendered[Self.warmupFrames...].map { abs(Double($0)) }.max() ?? 0
        #expect(peak <= ceiling, "soft mode peaked at \(peak), over the \(ceiling) ceiling")
    }

    @Test("L7 — more drive means more clipping, monotonically")
    func driveIncreasesTheClipping() throws {
        var levels: [Double] = []
        for drive in [0.0, 6.0, 12.0, 18.0] {
            let window = try clippedTone(oversampling: 4, driveDb: drive)[...]
            levels.append(Self.db(Self.goertzel(window, hz: Self.thirdHarmonic)))
        }
        print("[measured] H3 vs drive 0/6/12/18 dB: "
              + "\(levels.map { String(format: "%.2f", $0) })")
        for index in 1..<levels.count {
            #expect(levels[index] > levels[index - 1], Comment(rawValue:
                "H3 did not rise from drive step \(index - 1) to \(index): \(levels)"))
        }
        // The bottom of the sweep must be genuinely small, or "monotonic" is
        // being satisfied inside the noise.
        #expect(levels[0] < levels[3] - 20)
    }

    // MARK: - L8/L9/L10: the guards

    @Test("L8 — hostile automation values never reach the output as NaN, in any slot")
    func hostileAutomationCannotPoisonTheRender() throws {
        let input = Self.sine(hz: 440, frames: 8_192, amplitude: 0.7)
        let effect = ClipperEffect(params: ClipperParams(driveDb: 6, ceilingDb: -3, mode: 0,
                                                         oversampling: 4, mix: 0.8, outputDb: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let hostile: [Double] = [.nan, .infinity, -.infinity, 1e300, -1e300, 0, 1e-300]
        let rendered = try processChunked(effect, channels: [input]) { effect, quantum in
            let value = hostile[quantum % hostile.count]
            for slot in 0...5 {
                effect.storeAutomatedParam(slot: slot, value: value)
            }
            // …and an out-of-range slot, which must be inert.
            effect.storeAutomatedParam(slot: 99, value: 1)
            effect.storeAutomatedParam(slot: -1, value: 1)
        }[0]
        for (index, sample) in rendered.enumerated() where !sample.isFinite {
            Issue.record("sample \(index) is \(sample) after hostile automation")
            break
        }
        let nonFinite = rendered.filter { !$0.isFinite }.count
        #expect(nonFinite == 0, "\(nonFinite) non-finite samples after hostile automation")
        // ⚠️ And it did not merely go silent, which would also be "finite".
        let loudest = rendered.map { abs($0) }.max() ?? 0
        #expect(loudest > 0.01, "the render went silent under automation (peak \(loudest))")
    }

    @Test("L9 — reset() clears the dry ring and both filter histories")
    func resetClearsEverything() throws {
        let effect = ClipperEffect(params: ClipperParams(driveDb: 12, ceilingDb: -6, mode: 0,
                                                         oversampling: 4, mix: 1, outputDb: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let tone = Self.sine(hz: 440, frames: 2_048, amplitude: 0.8)
        _ = try processChunked(effect, channels: [tone, tone])
        let before = effect.nonZeroStateWords
        // Non-vacuity: there has to BE state before a clear can mean anything.
        #expect(before > 0, "nothing was in the filters, so reset() cannot be shown to clear them")
        effect.reset()
        #expect(effect.nonZeroStateWords == 0,
                "reset() left \(effect.nonZeroStateWords) non-zero words")
        // ⚠️ THE OUTPUT CLAIM IS "RAMPS IN", NOT "IS ZERO", AND THE FIRST DRAFT
        // OF THIS LEG GOT IT WRONG. At `mix` 1 the output is the WET path, and a
        // cleared 129-tap FIR fed a fresh signal produces a small but non-zero
        // ramp over its group delay — MEASURED: 3.8e-40 rising through 1e-6 over
        // the first 32 samples. Only at `mix` 0 is the exact-zero claim true,
        // and L5 is where that one lives. What this leg can say is that the
        // ramp starts far below the steady state, which a filter still holding
        // the previous render's tail would not do.
        let after = try processChunked(effect, channels: [tone, tone])[0]
        let steady = after[512...].map { abs($0) }.max() ?? 0
        #expect(steady > 0.1, "the post-reset render is silent, so there is nothing to compare")
        let firstFew = after[0..<8].map { abs($0) }.max() ?? 0
        #expect(firstFew < steady * 1e-3, Comment(rawValue:
            "the first samples after reset() peak at \(firstFew) against a steady state of "
            + "\(steady) — the filters are still carrying the previous render"))
        // And the FILTER histories specifically were the thing cleared.
        effect.reset()
        #expect(effect.filterStateWords == 0)
    }

    @Test("L10 — a subnormal input tail flushes to exactly zero in the filters")
    func denormalsAreFlushed() throws {
        let effect = ClipperEffect(params: ClipperParams(driveDb: 0, ceilingDb: 0, mode: 0,
                                                         oversampling: 4, mix: 1, outputDb: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        // A buffer of nothing but subnormals: every one must be flushed on the
        // way into both histories, so no state word survives.
        let subnormals = [Float](repeating: Float.leastNonzeroMagnitude * 4, count: 2_048)
        _ = try processChunked(effect, channels: [subnormals])
        // ⛔ The two stores have DIFFERENT laws and the instrument is split so
        // the test can state both. The FILTER histories flush on write, so not
        // one subnormal may survive there. The DRY ring deliberately does NOT
        // flush — that is what makes L5's identity bit-exact for subnormals —
        // so it still holds every one of them, and counting it here would have
        // hidden a filter that never flushed anything.
        let filterWords = effect.filterStateWords
        let allWords = effect.nonZeroStateWords
        print("[measured] after a subnormal-only render: \(filterWords) non-zero FIR words, "
              + "\(allWords) including the dry ring")
        #expect(filterWords == 0, Comment(rawValue:
            "\(filterWords) FIR history words hold a subnormal — the flush-on-write is not "
            + "running, and the render thread will pay subnormal arithmetic during silence"))
        // Non-vacuity: the dry ring DID see the subnormals, so the render
        // actually happened and the 0 above is a flush rather than an absence.
        #expect(allWords > 0, Comment(rawValue:
            "nothing at all reached the effect's state — the subnormal render did not run, so "
            + "the flush cannot be shown to have done anything"))
    }

    @Test("L11 — the factor actually reaches the primitive, and a change clears its state")
    func theFactorReachesTheOversampler() throws {
        let effect = ClipperEffect(params: ClipperParams(oversampling: 4))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let tone = Self.sine(hz: 440, frames: 1_024, amplitude: 0.8)
        _ = try processChunked(effect, channels: [tone])
        #expect(effect.activeFactor == 4)
        #expect(effect.nonZeroStateWords > 0)
        // A factor change on the automation path clears the histories — the
        // documented cost, asserted so it cannot silently stop happening.
        let filtersBefore = effect.filterStateWords
        #expect(filtersBefore > 0, "the filters were empty, so a clear cannot be shown")
        effect.storeAutomatedParam(slot: 3, value: 2)
        #expect(effect.activeFactor == 2)
        // The DRY ring survives (it holds BASE-rate samples, which are still
        // valid); the FILTER histories hold samples at the OLD oversampled rate
        // and must go.
        #expect(effect.filterStateWords == 0, Comment(rawValue:
            "a factor change left \(effect.filterStateWords) non-zero FIR words — those are "
            + "samples at the OLD oversampled rate and filtering them against a different "
            + "kernel is filtering garbage"))
        #expect(effect.nonZeroStateWords > 0, "the dry ring was cleared too — it should not be")
        // 3 snaps UP to 4, through the same law the params struct uses.
        effect.storeAutomatedParam(slot: 3, value: 3)
        #expect(effect.activeFactor == 4)
    }

    // MARK: - L12: the render path allocates NOTHING

    private typealias MallocLoggerFn =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    /// Heap cells, NOT stored properties: the hook runs INSIDE malloc with its
    /// locks held, so it must never allocate nor trip a lazy global init.
    private nonisolated(unsafe) static let eventCount =
        UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let watchedThread =
        UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private static let eventHook: MallocLoggerFn = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        if tid == ClipperTests.watchedThread.pointee {
            ClipperTests.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global. Nil is a FAILURE for the caller,
    /// never a skip — a silently-absent probe is vacuity, not a pass.
    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: MallocLoggerFn?.self)
    }

    /// ⛔⛔ SIBLING-IDENTICAL TO `FreqShifterTests`/`PhaserTests`/`RingModTests`
    /// ON PURPOSE. Two local deviations (a Swift `Array` source instead of a raw
    /// pointer, and a hand-made thread) once made this probe disagree with four
    /// neighbours, and the neighbours were right. The `warmup` runs with the
    /// hook live and the counter is zeroed afterwards, because Swift's
    /// `static let` arrays allocate on FIRST TOUCH anywhere in the process.
    private static func mallocEvents(
        slot: UnsafeMutablePointer<MallocLoggerFn?>,
        warmup: () -> Void = {}, _ body: () -> Void
    ) -> Int {
        pthread_threadid_np(nil, &watchedThread.pointee)
        eventCount.pointee = 0
        let previous = slot.pointee  // restore, don't assume it was nil
        slot.pointee = eventHook
        warmup()
        eventCount.pointee = 0   // one-time lazy-global costs are not the measurement
        body()
        slot.pointee = previous
        return eventCount.pointee
    }

    @Test("L12 — process() allocates NOTHING across 2 000 quanta, and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("""
                malloc_logger is unavailable — the allocation probe cannot run. \
                FAILURE, not a skip.
                """)
            return
        }
        let quantum = 256
        let calls = 2_000
        // Everything switched ON: stereo, the most expensive factor, soft mode
        // (the branch with the cubic), a mid mix so the write path runs, and a
        // non-unity trim.
        let effect = ClipperEffect(params: ClipperParams(
            driveDb: 15, ceilingDb: -4.5, mode: 1, oversampling: 4, mix: 0.6, outputDb: -3))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                       channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let data = try #require(buffer.floatChannelData)
        // ⚠️ A RAW POINTER, NOT A SWIFT `Array` — the sibling shape.
        let staged = Self.sine(hz: 220, frames: quantum, amplitude: 0.8)
        let source = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
        defer { source.deallocate() }
        for frame in 0..<quantum { source[frame] = staged[frame] }

        var sum: Float = 0
        let events = Self.mallocEvents(slot: slot, warmup: {
            var warm = 0
            while warm < 4 {
                effect.storeAutomatedParam(slot: 0, value: Double(warm))
                effect.process(buffers: list, frameCount: quantum)
                warm += 1
            }
        }) {
            var call = 0
            while call < calls {
                // ⚠️ RE-STAGE THE INPUT EVERY CALL — a probe measuring a NaN
                // render is measuring nothing.
                var channel = 0
                while channel < 2 {
                    var frame = 0
                    while frame < quantum {
                        data[channel][frame] = source[frame]
                        frame += 1
                    }
                    channel += 1
                }
                if call % 7 == 0 {
                    effect.storeAutomatedParam(slot: 0, value: Double(call % 30))
                }
                // ⛔ The FACTOR change too, every so often: `setFactor` clears
                // the histories, and a clear on the render thread must not
                // allocate either.
                if call % 101 == 0 {
                    effect.storeAutomatedParam(slot: 3, value: call % 202 == 0 ? 2 : 4)
                }
                effect.process(buffers: list, frameCount: quantum)
                sum += data[0][quantum - 1]
                call += 1
            }
        }
        print("[measured] malloc events across \(calls) quanta: \(events)")
        #expect(events == 0, "the render path allocated \(events) times")
        #expect(sum.isFinite)
        #expect(sum != 0, "the measured region rendered silence")
    }

    @Test("L12b — POSITIVE CONTROL: the malloc probe can actually count")
    func theAllocationProbeCanSeeAnAllocation() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⭐ A zero from a probe that never fires and a zero from a render that
        // never allocates are the same number.
        var sink: [[Int]] = []
        let events = Self.mallocEvents(slot: slot) {
            var index = 0
            while index < 200 {
                sink.append([Int](repeating: index, count: 64))
                index += 1
            }
        }
        #expect(events > 0, "the malloc probe counted \(events) events on 200 allocations")
        #expect(sink.count == 200)
    }

    // MARK: - L13: stereo

    @Test("L13 — both channels are clipped, independently and identically")
    func stereoChannelsAreBothProcessed() throws {
        let frames = 4_096
        let left = Self.sine(hz: 1_000, frames: frames, amplitude: 0.9)
        let right = Self.sine(hz: 1_000, frames: frames, amplitude: 0.45)
        let effect = ClipperEffect(params: ClipperParams(driveDb: 12, ceilingDb: -6, mode: 0,
                                                         oversampling: 4, mix: 1, outputDb: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let out = try processChunked(effect, channels: [left, right])
        let ceiling = pow(10.0, -6.0 / 20.0)
        // Both are clipped (this effect has no stereo link by design — each
        // channel meets the same ceiling on its own).
        for channel in 0..<2 {
            let peak = out[channel][1_024...].map { abs(Double($0)) }.max() ?? 0
            #expect(peak > ceiling * 0.9, "channel \(channel) peaked at \(peak), nowhere near the ceiling")
            #expect(peak < ceiling * 1.2)
        }
        // And they are NOT the same signal — a bug that processed channel 0
        // twice would pass every peak assertion above.
        var differing = 0
        for index in 1_024..<frames where out[0][index] != out[1][index] { differing += 1 }
        #expect(differing > 1_000, Comment(rawValue:
                "the two channels are identical — channel 1 was not processed from its own input"))
        // Feeding the SAME signal to both must give the same output, so the
        // difference above is the input and not a per-channel state bug.
        let mirrored = try processChunked(
            { let e = ClipperEffect(params: ClipperParams(driveDb: 12, ceilingDb: -6, mode: 0,
                                                          oversampling: 4, mix: 1, outputDb: 0))
              e.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
              return e }(), channels: [left, left])
        for index in 0..<frames {
            #expect(mirrored[0][index] == mirrored[1][index],
                    "identical inputs gave different outputs at \(index)")
        }
    }
}
