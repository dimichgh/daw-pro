import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`. The main actor is
// ONE serialization point for the whole test process: when the m32-d/f render
// tests first shipped as extensions of a `@MainActor .serialized` suite they
// reddened a test in a COMPLETELY DIFFERENT suite —
// `AUPrepareRenegotiationStressTests`' m23-as-2 discriminator went 0.0438 s →
// 3.2067 s — because `AUHostRegistry.prepare` is `@MainActor` and its measured
// wall time includes queue wait behind every other `@MainActor` test body doing
// CPU work. These tests render tens of seconds of audio and need no main-actor
// state at all. Read the m32-d ROADMAP entry before adding `@MainActor` here.
//
// The one main-actor thing an effect owns is `apply(params:)`; these tests
// construct effects with their params instead, which is the FXPack2 /
// BassEnhancer precedent for a param set that never changes mid-render.
//
// FIXTURE NOTE (m32-h): every signal here is SYNTHESIZED in memory. Nothing
// reads an audio file, so the live `AVAudioFile.read(into:)` mono short-read
// defect cannot reach these gates.

/// m32-e — the bit-crush / sample-rate-reduction insert.
///
/// ⭐ **Every claim is MEASURED FROM RENDERED OUTPUT, never read back from the
/// parameter.** A test that asserts `params.bits == 12` proves the struct stores
/// a number. The gates here count the distinct output levels a ramp produces,
/// measure the length of the hold runs a signal is frozen into, and compare two
/// spectra — so a quantizer neutered to a passthrough, an accumulator reset per
/// block, or an `antiAlias` flag wired to nothing each redden a DIFFERENT leg.
///
/// The legs are built so the obvious wrong implementations separate:
///
///  · quantizer replaced by a passthrough      → L1/L2 (level counts), while
///    the identity control L5 stays GREEN — which is the whole point of having
///    an always-on identity control: without it "the effect did nothing" is
///    indistinguishable from "the effect worked".
///  · `round(x·L)/L` with a symmetric clamp    → L1/L2 by exactly one level
///    (2^N + 1 instead of 2^N).
///  · integer modulo of a frame counter        → L4 (chunk invariance), which
///    the run-length legs alone cannot see.
///  · accumulator reset at the top of `process`→ L4.
///  · `antiAlias` accepted but not applied     → L6a/L6b, in two directions.
///  · a post-filter but no pre-filter          → L6b only (L6a passes).
///  · `dither` accepted but not applied        → L7.
///  · quantizing per OUTPUT sample rather than
///    at capture, with dither on               → L2d (runs stop being flat).
@Suite("Bit crusher — measured levels, hold runs, aliasing (m32-e)", .serialized)
struct BitCrusherTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (FXPack2Tests conventions)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    /// A full-scale ramp from −1 to +1 inclusive. `frames` must be ≥ 2.
    private func ramp(frames: Int) -> [Float] {
        (0..<frames).map { Float(-1.0 + 2.0 * Double($0) / Double(frames - 1)) }
    }

    /// Deterministic pseudo-noise in ±`amplitude`. A ramp is the WRONG input for
    /// the run-length legs: adjacent captures would often quantize to the same
    /// code and two runs would merge into one long one, which reads as a failure
    /// of the accumulator when it is really a property of the signal.
    private func noise(amplitude: Double, frames: Int) -> [Float] {
        var rng: UInt32 = 0x2545_F491
        return (0..<frames).map { _ in
            rng ^= rng << 13; rng ^= rng >> 17; rng ^= rng << 5
            return Float((Double(rng) / 4_294_967_296.0 * 2 - 1) * amplitude)
        }
    }

    /// A repeating ±0.95 sawtooth. ⚠️ THE RUN-LENGTH LEGS NEED THIS AND NOT
    /// `noise`: with random input two ADJACENT captures occasionally quantize to
    /// the SAME code and their two runs MERGE into one double-length run, which
    /// reads as an accumulator failure when it is really a property of the
    /// signal. MEASURED with 16-bit noise at 0.9 — about 59 000 reachable codes,
    /// so P(adjacent equal) ≈ 1.7e-5 and a 52 000-run window expects ~0.9
    /// merges; the first draft of this suite saw exactly 2. A sawtooth whose
    /// per-sample step is 5.2x the 16-bit LSB (period 12 000 over a 1.9 span =
    /// 1.583e-4 against an LSB of 3.052e-5) makes adjacent captures provably
    /// distinct, so a merge cannot happen at all.
    private func sawtooth(period: Int, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(-0.95 + 1.9 * Double($0 % period) / Double(period - 1))
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

    private func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    /// Lengths of the maximal runs of EQUAL consecutive samples, dropping the
    /// final (possibly truncated) run so a window boundary cannot fake a short one.
    private func runLengths(_ samples: [Float]) -> [Int] {
        guard !samples.isEmpty else { return [] }
        var runs: [Int] = []
        var current = 1
        for index in 1..<samples.count {
            if samples[index] == samples[index - 1] {
                current += 1
            } else {
                runs.append(current)
                current = 1
            }
        }
        return runs
    }

    /// Runs `channels` through `effect` in `chunk`-frame quanta (state continuity
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

    /// One mono pass through a freshly prepared crusher.
    private func crush(_ params: BitCrusherParams, _ input: [Float],
                       chunk: Int = 512) throws -> [Float] {
        let effect = BitCrusherEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// `downsampleHz` at the graph rate — every sample is captured, so the
    /// sample-rate stage is transparent and ONLY the quantizer is under test.
    private static let noDownsample = 48_000.0

    // MARK: - L1/L2: bit depth, MEASURED as distinct output levels

    /// ⭐ THE LEVEL COUNT IS COUNTED, NOT ASSERTED FROM THE PARAMETER. Reading
    /// `params.bits` back would prove the struct stores a number and nothing
    /// about the DSP. 65 536 ramp frames give ≥ 16 input samples per code at 12
    /// bits, so every code in the range is reachable.
    @Test("bits N renders EXACTLY 2^N distinct levels on a full-scale ramp")
    func bitDepthProducesExactlyTwoToTheNLevels() throws {
        let input = ramp(frames: 65_536)
        for bits in [1, 2, 4, 8, 12] {
            let out = try crush(
                BitCrusherParams(bits: Double(bits), downsampleHz: Self.noDownsample), input)
            let levels = Set(out)
            print("[measured] bits \(bits): \(levels.count) distinct output levels")
            #expect(levels.count == 1 << bits,
                    "bits \(bits) produced \(levels.count) levels, expected \(1 << bits)")
        }
    }

    /// The codes are a converter's, not a rounding trick's: the lowest level is
    /// exactly −1 (code −2^(N−1)) and the highest is 1 − 2^−(N−1) (code
    /// 2^(N−1)−1), so the set is asymmetric by exactly one step. A symmetric
    /// `round(x·L)/L` would put +1.0 in the set and give 2^N + 1 levels.
    @Test("the 16 levels at bits 4 are a converter's code range, listed exactly")
    func fourBitLevelsAreAConvertersCodeRange() throws {
        let out = try crush(
            BitCrusherParams(bits: 4, downsampleHz: Self.noDownsample), ramp(frames: 65_536))
        let levels = Set(out).sorted()
        // MEASURED AND PASTED (codes −8…7 over a scale of 8), never recomputed
        // from the effect's own constants.
        let expected: [Float] = [-1.0, -0.875, -0.75, -0.625, -0.5, -0.375, -0.25, -0.125,
                                 0.0, 0.125, 0.25, 0.375, 0.5, 0.625, 0.75, 0.875]
        print("[measured] bits 4 levels: \(levels)")
        #expect(levels == expected)
        #expect(!levels.contains(1.0), "a symmetric clamp would add a 17th level at +1.0")
    }

    // MARK: - L3/L2d: the hold pattern, MEASURED as run lengths

    /// ⭐ THE RUN LENGTH IS MEASURED FROM THE OUTPUT, NOT READ FROM THE SETTING.
    /// At a 48 kHz graph rate with `downsampleHz: 8000` every output sample must
    /// repeat in runs of exactly 48000/8000 = 6.
    @Test("downsampleHz R against graph rate G holds every sample for exactly G/R")
    func holdRunLengthIsGraphRateOverDownsampleRate() throws {
        // 16 bits so the quantizer practically never merges two adjacent
        // captures into one run — the run structure under test is the
        // accumulator's, not the quantizer's.
        for (rate, expected) in [(8_000.0, 6), (12_000.0, 4), (16_000.0, 3), (1_000.0, 48)] {
            let out = try crush(
                BitCrusherParams(bits: 16, downsampleHz: rate),
                sawtooth(period: 12_000, frames: 24_000))
            let runs = runLengths(out)
            let histogram = Dictionary(grouping: runs, by: { $0 }).mapValues(\.count)
            print("[measured] downsampleHz \(rate): run histogram \(histogram)")
            #expect(Set(runs) == [expected],
                    "downsampleHz \(rate) should hold every sample \(expected)x, got \(histogram)")
        }
    }

    /// ⭐ The reason the design mandates an accumulator rather than integer
    /// modulo: 48000/26040 is 1.8433, so the runs MUST be a mix of 1 and 2 whose
    /// mean is the true ratio. An integer scheme can only produce one length.
    @Test("the SP-1200's non-integer 26040 Hz holds in mixed runs averaging 1.8433")
    func nonIntegerRateProducesMixedRuns() throws {
        let out = try crush(
            BitCrusherParams(bits: 16, downsampleHz: 26_040),
            sawtooth(period: 12_000, frames: 96_000))
        let runs = runLengths(out)
        let histogram = Dictionary(grouping: runs, by: { $0 }).mapValues(\.count)
        let mean = Double(runs.reduce(0, +)) / Double(runs.count)
        print("[measured] 26040 Hz: run histogram \(histogram), mean run \(mean)")
        #expect(Set(runs) == [1, 2], "expected a mix of 1s and 2s, got \(histogram)")
        // 48000/26040 = 1.8433179723502304 exactly. MEASURED here: 1.8433243…
        #expect(abs(mean - 48_000.0 / 26_040.0) < 0.001,
                "mean run \(mean) should sit on the true ratio 1.84332")
    }

    /// ⭐ THE DISCRIMINATOR THE RUN-LENGTH LEGS CANNOT SEE. An accumulator that
    /// re-phases at every block boundary (integer modulo of the frame index, or
    /// a reset at the top of `process`) still produces runs of the right length
    /// — it just produces DIFFERENT ONES depending on the host's buffer size.
    /// Byte-identity across three block sizes is what pins that shut.
    @Test("the hold pattern is byte-identical whichever block size renders it")
    func holdPatternIsChunkInvariant() throws {
        let input = noise(amplitude: 0.8, frames: 12_000)
        let params = BitCrusherParams(bits: 12, downsampleHz: 26_040)
        let whole = try crush(params, input, chunk: 12_000)
        for chunk in [512, 256, 1_024, 333] {
            let chunked = try crush(params, input, chunk: chunk)
            var firstDifference: Int?
            for index in 0..<min(whole.count, chunked.count) where whole[index] != chunked[index] {
                firstDifference = index
                break
            }
            print("[measured] chunk \(chunk): first differing frame "
                + "\(firstDifference.map(String.init) ?? "none")")
            #expect(chunked == whole,
                    "chunk \(chunk) diverged from the single-block render")
        }
    }

    /// With dither ON the runs must STILL be flat: dither is applied ONCE per
    /// capture, not per output sample. Quantizing per output sample would give
    /// every frame of a run its own noise and shatter the hold structure.
    @Test("dither does not break the hold runs (it is applied at capture)")
    func ditherKeepsHoldRunsFlat() throws {
        let out = try crush(
            BitCrusherParams(bits: 8, downsampleHz: 8_000, dither: true),
            noise(amplitude: 0.7, frames: 24_000))
        let runs = runLengths(out)
        let histogram = Dictionary(grouping: runs, by: { $0 }).mapValues(\.count)
        print("[measured] dithered run histogram \(histogram)")
        // ⚠️ THE ASSERTION IS "no run is SHORTER than the hold period, and every
        // run is a whole multiple of it" — NOT "every run is exactly 6". At 8
        // bits over ±0.7 there are only ~179 reachable codes, so adjacent
        // captures collide about once in 179 and their runs MERGE into 12;
        // MEASURED, 26 merges in 3 973 runs, against ~22 expected. A merge is
        // the signal's doing and is invisible to the ear. A SHORTENED run would
        // be the real defect — that is what quantizing per output sample
        // instead of at capture produces, and this catches it.
        #expect(runs.min() == 6, "dither must not shorten the runs, got \(histogram)")
        #expect(runs.allSatisfy { $0 % 6 == 0 },
                "every run must be a whole multiple of the hold period, got \(histogram)")
    }

    // MARK: - L5: the ALWAYS-ON positive control

    /// ⭐⭐ THE CONTROL THAT MAKES EVERY OTHER LEG MEAN SOMETHING. Without it, an
    /// effect whose `process` is `{}` passes the mix-0 leg, both anti-alias
    /// legs by producing nothing, and is only caught obliquely elsewhere. Here a
    /// crusher configured to do nothing must MEASURABLY do nothing.
    ///
    /// ⚠️ RECONCILIATION, stated rather than hidden: the item's wording asks for
    /// `bits: 32`, and this test passes exactly that — but `BitCrusherParams`'
    /// range is 1…16 (the design doc's table), so 32 CLAMPS to 16. The
    /// resulting error is bounded by half a 16-bit step, 2^−16 = 1.526e-5, which
    /// is what "near-identity" means here and what the assertion measures. The
    /// range was not widened: in Float32 every setting from 25 to 32 bits is
    /// indistinguishable, and eight settings that do nothing is a lying
    /// parameter surface.
    @Test("bits 32 (clamped to 16) at the graph rate is a near-identity passthrough")
    func identityControlIsNearPassthrough() throws {
        let input = sine(997, amplitude: 0.9, frames: 48_000)
        let out = try crush(
            BitCrusherParams(bits: 32, downsampleHz: Self.noDownsample), input)
        #expect(out.count == input.count)
        let maxError = zip(input, out).map { abs(Double($0) - Double($1)) }.max() ?? 0
        print("[measured] identity control max |error| = \(maxError) (half a 16-bit step = 1.526e-5)")
        #expect(maxError <= 2e-5, "a transparent setting must pass the signal through")

        // ...and the tolerance is not vacuous: the SAME assertion on a real
        // crush must FAIL, or "near-identity" would just mean "any output".
        let crushed = try crush(
            BitCrusherParams(bits: 4, downsampleHz: Self.noDownsample), input)
        let crushedError = zip(input, crushed).map { abs(Double($0) - Double($1)) }.max() ?? 0
        print("[measured] bits 4 max |error| = \(crushedError)")
        #expect(crushedError > 2e-5, "the identity tolerance must not admit a 4-bit crush")
    }

    // MARK: - L6: the anti-alias switch, in BOTH directions

    /// ⭐ PROVES THE DEFAULT MATTERS. A zero-order hold at R images the
    /// fundamental f to R−f, R+f, 2R−f … With `antiAlias: false` (the DEFAULT,
    /// and the authentic setting) that image is plainly there; with `true` the
    /// reconstruction filter removes it. Both directions are asserted, because a
    /// crusher that ALWAYS aliases and one that NEVER does both pass a one-sided
    /// test — and the fundamental is checked in both modes so "quieter" cannot
    /// pass by muting everything.
    @Test("antiAlias false leaves the hold image at R-f; true removes it")
    func antiAliasRemovesTheReconstructionImage() throws {
        let f = 1_000.0, rate = 8_000.0
        let input = sine(f, amplitude: 0.8, frames: 48_000)
        let window = 24_000..<48_000  // skip the filter's settling
        let params = { (aa: Bool) in
            BitCrusherParams(bits: 16, downsampleHz: rate, antiAlias: aa)
        }
        let raw = try crush(params(false), input)
        let filtered = try crush(params(true), input)

        let rawFundamental = goertzel(raw, frequency: f, in: window)
        let filteredFundamental = goertzel(filtered, frequency: f, in: window)
        let rawImage = goertzel(raw, frequency: rate - f, in: window)
        let filteredImage = goertzel(filtered, frequency: rate - f, in: window)

        print("[measured] image at \(rate - f) Hz: antiAlias false "
            + "\(dB(rawImage / rawFundamental)) dB rel. fundamental, true "
            + "\(dB(filteredImage / filteredFundamental)) dB rel. fundamental")
        print("[measured] fundamental: false \(dB(rawFundamental)) dBFS, "
            + "true \(dB(filteredFundamental)) dBFS")

        // The image is REAL and audible with the default off (sinc rolloff puts
        // it about −17 dB under the fundamental).
        #expect(dB(rawImage / rawFundamental) > -24,
                "the authentic default must actually alias")
        // Turning the filter on buys real attenuation of it.
        #expect(dB(filteredImage) < dB(rawImage) - 12,
                "antiAlias: true must measurably remove the image")
        // ...and does NOT do it by muting the whole signal.
        #expect(abs(dB(filteredFundamental) - dB(rawFundamental)) < 1.5,
                "the fundamental must survive both modes within ~1.5 dB")
    }

    /// The OTHER half of the switch, which the image leg cannot see: a post-only
    /// implementation passes `antiAliasRemovesTheReconstructionImage` while
    /// still folding input content down. Input at 5 kHz is ABOVE the 4 kHz
    /// reduced Nyquist, so the hold folds it to |8000 − 5000| = 3000 Hz.
    @Test("antiAlias false folds above-Nyquist input down to 3 kHz; true does not")
    func antiAliasPreventsInputFoldback() throws {
        // ⚠️ 11 kHz, NOT the 5 kHz this leg first used. The pre-filter's corner
        // is `rate/2` = 4 kHz, and a 4th-order Butterworth only 0.32 octaves
        // above its corner attenuates 8.4 dB — MEASURED at 5 kHz: a 9.2 dB
        // reduction, which is the filter working correctly and still failing a
        // 20 dB assertion. At 11 kHz (2.75x the corner) theory says 35.1 dB, so
        // the leg now measures the switch rather than the probe's bad luck.
        let f = 11_000.0, rate = 8_000.0, alias = 3_000.0
        let input = sine(f, amplitude: 0.8, frames: 48_000)
        let window = 24_000..<48_000
        let raw = try crush(
            BitCrusherParams(bits: 16, downsampleHz: rate, antiAlias: false), input)
        let filtered = try crush(
            BitCrusherParams(bits: 16, downsampleHz: rate, antiAlias: true), input)

        let rawAlias = goertzel(raw, frequency: alias, in: window)
        let filteredAlias = goertzel(filtered, frequency: alias, in: window)
        print("[measured] fold-down at \(alias) Hz: antiAlias false \(dB(rawAlias)) dBFS, "
            + "true \(dB(filteredAlias)) dBFS")
        #expect(dB(rawAlias) > -20, "5 kHz into an 8 kHz hold must fold down to 3 kHz")
        #expect(dB(filteredAlias) < dB(rawAlias) - 20,
                "the PRE-filter must stop the fold-down; a post-only filter cannot")
    }

    // MARK: - L7: the dither switch

    /// ⭐ PROVES THE FLAG IS NOT DECORATIVE, using the sharpest possible probe: a
    /// DC input BELOW half an LSB. Undithered it quantizes to a single code
    /// forever (a constant); dithered it must straddle codes. This is exactly
    /// what dither is FOR, so a decorative flag cannot fake it.
    @Test("dither turns a sub-LSB constant into a straddling signal")
    func ditherIsAudiblyWired() throws {
        // bits 4 → LSB = 1/8 = 0.125, half an LSB = 0.0625. 0.03 rounds to code 0.
        let input = [Float](repeating: 0.03, count: 24_000)
        let dry = try crush(
            BitCrusherParams(bits: 4, downsampleHz: Self.noDownsample, dither: false), input)
        let wet = try crush(
            BitCrusherParams(bits: 4, downsampleHz: Self.noDownsample, dither: true), input)
        print("[measured] sub-LSB DC: undithered levels \(Set(dry).sorted()), "
            + "dithered levels \(Set(wet).sorted())")
        #expect(Set(dry) == [0.0], "without dither a sub-LSB constant vanishes entirely")
        #expect(Set(wet).count > 1, "with dither it must straddle at least two codes")
        // The dithered mean recovers the input the undithered quantizer erased —
        // the actual purpose of dither, not merely "the output changed".
        let wetMean = wet.reduce(0.0) { $0 + Double($1) } / Double(wet.count)
        print("[measured] dithered mean \(wetMean) vs input 0.03")
        #expect(abs(wetMean - 0.03) < 0.01)
    }

    /// A dithered render is still REPRODUCIBLE: the generator is seeded
    /// deterministically, so this repo can keep pinning renders by digest.
    @Test("dither is deterministic across renders and independent per channel")
    func ditherIsDeterministicAndDecorrelated() throws {
        let params = BitCrusherParams(bits: 6, downsampleHz: 26_040, dither: true)
        let input = sine(220, amplitude: 0.5, frames: 24_000)
        #expect(try crush(params, input) == (try crush(params, input)),
                "a dithered render must be reproducible")

        let effect = BitCrusherEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let stereo = try processChunked(effect, channels: [input, input])
        let identical = zip(stereo[0], stereo[1]).allSatisfy { $0 == $1 }
        print("[measured] stereo dither channels identical: \(identical)")
        #expect(!identical, "left and right must not share one dither sequence")
    }

    // MARK: - L8: neutrality, safety, and the defaults

    @Test("mix 0 is bit-exact dry and advances no state")
    func mixZeroIsBitExactDry() throws {
        let input = sine(440, amplitude: 0.7, frames: 12_000)
        let effect = BitCrusherEffect(params: BitCrusherParams(bits: 3, mix: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let out = try processChunked(effect, channels: [input])[0]
        #expect(out == input, "mix 0 must be bit-exact dry")
    }

    @Test("mix 0.5 sits between the dry input and the fully crushed signal")
    func mixBlendsParallel() throws {
        let input = sine(440, amplitude: 0.7, frames: 12_000)
        let params = { (mix: Double) in
            BitCrusherParams(bits: 4, downsampleHz: 12_000, mix: mix)
        }
        let full = try crush(params(1), input)
        let half = try crush(params(0.5), input)
        // Sample-by-sample, the blend must be the exact average of the two
        // ends. Broken into named steps: the one-line form times out the
        // type-checker on this compiler.
        var residual = 0.0
        for index in 0..<input.count {
            let dry = Double(input[index])
            let wet = Double(full[index])
            let expected = 0.5 * (dry + wet)
            residual = max(residual, abs(Double(half[index]) - expected))
        }
        print("[measured] |mix 0.5 − mean(dry, wet)| max = \(residual)")
        #expect(residual < 1e-6)
    }

    /// Non-finite input must not become non-finite output, and — the part that
    /// matters more here than in a stateless effect — must not STICK: a NaN
    /// captured into the hold register would be re-emitted for a whole run, and
    /// a NaN in the anti-alias recursion would poison it permanently.
    @Test("NaN and infinity in never produce non-finite out, and do not stick")
    func nonFiniteInputIsSanitized() throws {
        var input = sine(440, amplitude: 0.5, frames: 12_000)
        input[100] = .nan
        input[101] = .infinity
        input[102] = -.infinity
        input[5_000] = .nan
        for aa in [false, true] {
            let out = try crush(
                BitCrusherParams(bits: 8, downsampleHz: 8_000, antiAlias: aa), input)
            let bad = out.enumerated().filter { !$0.element.isFinite }.map(\.offset)
            print("[measured] antiAlias \(aa): non-finite output frames \(bad.prefix(5))")
            #expect(bad.isEmpty, "antiAlias \(aa) leaked \(bad.count) non-finite samples")
        }
    }

    /// Silence in, exact silence out — no denormal residue idling in the
    /// recursions after a loud passage.
    @Test("a loud passage followed by silence decays to exact zeros")
    func silenceDecaysToExactZero() throws {
        let loud = sine(120, amplitude: 0.95, frames: 4_800)
        let input = loud + [Float](repeating: 0, count: 24_000)
        let out = try crush(
            BitCrusherParams(bits: 10, downsampleHz: 26_040, antiAlias: true), input)
        let tail = out[(out.count - 4_800)...]
        let worst = tail.map { abs(Double($0)) }.max() ?? 0
        print("[measured] tail max |sample| after silence: \(worst)")
        #expect(worst == 0, "the tail must be EXACT zero, not a denormal floor")
    }

    /// The SP-1200 defaults are the item's whole point — pinned as literals so
    /// a well-meaning "let us turn on the filter" is a red test, not a shipped
    /// change of character.
    @Test("the defaults are the SP-1200: 12 bits, 26040 Hz, no filtering, no dither")
    func defaultsAreTheSP1200() {
        let p = BitCrusherParams()
        #expect(p.bits == 12)
        #expect(p.downsampleHz == 26_040)
        #expect(p.antiAlias == false, "the aliasing IS the character — see the research doc §2.4")
        #expect(p.dither == false, "dither removes the quantization character")
        #expect(p.mix == 1)

        let specs = EffectParamSpec.specs(for: .bitCrusher)
        #expect(specs.map(\.name) == ["bits", "downsampleHz", "antiAlias", "dither", "mix"])
        #expect(specs.map(\.defaultValue) == [12, 26_040, 0, 0, 1])
        // The spec table and the struct cannot fork: a client reading defaults
        // from `fx.describe` must get the same crusher a fresh insert renders.
        #expect(specs[0].defaultValue == p.bits)
        #expect(specs[1].defaultValue == p.downsampleHz)
        #expect(specs[2].defaultValue == (p.antiAlias ? 1 : 0))
        #expect(specs[3].defaultValue == (p.dither ? 1 : 0))
        #expect(specs[4].defaultValue == p.mix)
    }

    /// `bits` is numeric on the wire but discrete in the DSP, and the clamp is
    /// what stands between an agent's `1e9` and a shift that traps ON THE RENDER
    /// THREAD (the m32-f `1 << 99` lesson).
    @Test("bits clamps, rounds, and survives NaN without trapping")
    func bitsClampAndRound() {
        #expect(BitCrusherParams(bits: 12.4).bits == 12)
        #expect(BitCrusherParams(bits: 12.6).bits == 13)
        #expect(BitCrusherParams(bits: 0).bits == 1)
        #expect(BitCrusherParams(bits: -5).bits == 1)
        #expect(BitCrusherParams(bits: 32).bits == 16)
        #expect(BitCrusherParams(bits: 1e9).bits == 16)
        // `clamped` is min(max(…)) and BOTH comparisons are false against NaN,
        // so a NaN survives a clamp. Int(Double.nan) traps.
        #expect(BitCrusherParams(bits: .nan).bits == 12)
        #expect(BitCrusherParams(downsampleHz: .nan).downsampleHz == 26_040)
        #expect(BitCrusherParams(downsampleHz: 1e9).downsampleHz == 48_000)
        #expect(BitCrusherParams(downsampleHz: 1).downsampleHz == 1_000)
        #expect(BitCrusherParams(mix: 5).mix == 1)
    }

    /// Automation writes FIELD BY FIELD into the overlay, bypassing the params
    /// init — so the derive has to re-clamp or an out-of-range lane builds an
    /// illegal shift. This renders after poking every slot past its range.
    @Test("out-of-range automation stores cannot trap or destabilize the render")
    func automationStoresAreFencedAgainstTraps() throws {
        let effect = BitCrusherEffect(params: BitCrusherParams())
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let input = sine(440, amplitude: 0.6, frames: 4_800)
        // Every slot, well past both ends, plus a non-finite and an unknown slot.
        for (slot, value) in [(0, 1e9), (0, -1e9), (0, Double.nan), (1, 1e12), (1, -5),
                              (2, 7), (3, -3), (4, 99), (9, 1), (-1, 1)] {
            effect.storeAutomatedParam(slot: slot, value: value)
        }
        let out = try processChunked(effect, channels: [input])[0]
        // `allSatisfy(\.isFinite)` inside #expect expands to a rethrows call
        // the macro cannot prove non-throwing; the explicit closure compiles.
        let allFinite = out.allSatisfy { $0.isFinite }
        #expect(allFinite)
        #expect(out.count == input.count)
    }

    /// The insert reports no fixed latency — the chain's PDC must not shift a
    /// crushed track against an uncrushed one.
    @Test("the crusher reports zero latency")
    func latencyIsZero() {
        let effect = BitCrusherEffect(params: BitCrusherParams())
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(effect.latencySamples == 0)
    }

    /// The kind is registered end to end: the factory builds the right class and
    /// re-applying params in place reaches the render (a factory that returned a
    /// `PassthroughEffect` would pass every DSP leg above, which never asks the
    /// factory for anything).
    @Test("the factory builds a BitCrusherEffect and applyParams reaches it")
    @MainActor
    func factoryWiring() throws {
        let descriptor = EffectDescriptor(
            kind: .bitCrusher,
            bitCrusher: BitCrusherParams(bits: 4, downsampleHz: 12_000))
        let instance = EffectFactory.makeInstance(for: descriptor)
        #expect(instance is BitCrusherEffect)
        instance.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let input = ramp(frames: 8_192)
        let crushed = try processChunked(instance, channels: [input])[0]
        #expect(Set(crushed).count <= 16, "the factory instance must really crush to 4 bits")

        // Now push a DIFFERENT param set through applyParams and prove the sound
        // follows. `apply` publishes for the NEXT quantum, so re-prepare and
        // render again rather than asserting on the same pass.
        var updated = descriptor
        updated.bitCrusher = BitCrusherParams(bits: 2, downsampleHz: 12_000)
        EffectFactory.applyParams(updated, to: instance)
        instance.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let recrushed = try processChunked(instance, channels: [input])[0]
        print("[measured] after applyParams(bits: 2): \(Set(recrushed).count) levels")
        #expect(Set(recrushed).count == 4, "applyParams must reach the live instance")
    }
}
