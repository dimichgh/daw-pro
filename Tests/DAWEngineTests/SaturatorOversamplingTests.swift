import AVFAudio
import DAWCore
import Foundation
import Testing

@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, DELIBERATELY **NOT** `@MainActor` — the `ClipperTests` /
// `FreqShifterTests` / `PhaserTests` rule, for their reasons: the main actor is
// one serialization point for the whole test process, these tests render
// hundreds of thousands of frames, and `MainActorOccupancySiteTests` Leg C pins
// the main-actor SUITE count at its cap with ZERO slack. The two legs that
// genuinely need the main actor (the chain-level latency republish and the PDC
// plan) live in `PDCWiringTests`, which is already `@MainActor`.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-ad — `.saturator` gains the `Oversampler`, and its default does not move.
///
/// ⭐⭐ **THE TWO CENTRAL LEGS ARE L0 AND L1, AND THEY PULL IN OPPOSITE
/// DIRECTIONS.** L0 says the effect must not have changed; L1 says it must have
/// gained something. Either one alone is satisfiable by a broken build — an
/// effect that ignores the new parameter passes L0 perfectly, and an effect that
/// oversamples unconditionally passes L1 perfectly.
///
/// **L0 — THE DEFAULT IS BIT-FOR-BIT v0.** `.saturator` is a SHIPPED kind. A
/// default of 2 or 4 would change what every saved project sounds like AND shift
/// it by the 32 samples the filters cost. So the default is 1, the oversampling
/// path is SKIPPED there rather than run at factor 1, and `latencySamples` is 0.
/// L0 compares BIT PATTERNS against v0's arithmetic restated in this file.
/// ⚠️ That restatement is a RE-DERIVATION, not an independent instrument — it
/// could in principle be wrong in the same way the code is. The genuinely
/// independent check is `scripts/gates/m39ad-saturator-default-bytes.mjs`, which
/// compares a rendered wav's sha256 against one captured from the last build in
/// which this parameter did not exist. The two answer the same question from
/// opposite ends.
///
/// **L1 — THE ALIAS FLOOR, THE ONLY MEASUREMENT THAT CAN TELL AN OVERSAMPLED
/// SATURATOR FROM A NAIVE ONE.** Both are loud. Both are audible. Both produce
/// byte-distinct renders. A demo harness cannot separate them — the 2026-09-19
/// lesson, where a completely inert effect passed a byte-difference gate. `tanh`
/// is odd-symmetric, so a single sine at f0 comes out as f0 plus ODD harmonics,
/// and the ones above Nyquist FOLD BACK onto frequencies unrelated to anything
/// playing. L1 reads the energy in those folds at each shipped factor.
///
/// ⛔ THE FIXTURE IS CHOSEN SO THOSE BINS ARE UNAMBIGUOUS. `f0` = 6300 Hz at
/// 48 kHz: the only real harmonics below Nyquist are 6300 (H1) and 18900 (H3);
/// every other odd harmonic folds, landing at 16500 (H5), 3900 (H7), 8700 (H9),
/// 14100 (H13) and 1500 (H15), none of which is a multiple of 6300. A shift in
/// ANY of those five bins is aliasing and can be nothing else. Every measured
/// frequency is a multiple of 300 Hz and the analysis window is 9 600 samples
/// (5 Hz bins), so every component sits on an EXACT bin: rectangular-window
/// leakage between exact bins is zero by orthogonality, which is why no window
/// function appears here and why an "empty" bin can be believed.
@Suite("m39-ad — the saturator gains oversampling without moving its default", .serialized)
struct SaturatorOversamplingTests {

    private static let sampleRate = 48_000.0

    /// The fixture tone and everything derived from it. All multiples of 300 Hz.
    private static let f0 = 6_300.0
    private static let thirdHarmonic = 18_900.0
    private static let aliasBins = [1_500.0, 3_900.0, 8_700.0, 14_100.0, 16_500.0]
    /// H11's fold, above the protected band — reported, never summed.
    private static let unprotectedAliasBin = 21_300.0

    private static let warmupFrames = 2_048
    private static let analysisFrames = 9_600   // 5 Hz bins; 48000/9600 = 5

    /// The round-trip latency at factors 2 and 4, through the ONE home.
    private static let oversampledLatency = OversamplerDesign.latencySamples

    // MARK: - Instruments

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
        _ effect: SaturatorEffect, channels: [[Float]], chunk: Int = 512,
        poke: ((SaturatorEffect, Int) -> Void)? = nil
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

    private func saturate(_ params: SaturatorParams, _ input: [Float],
                          chunk: Int = 512) throws -> [Float] {
        let effect = SaturatorEffect(params: params)
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
    private func saturatedTone(oversampling: Double) throws -> ArraySlice<Float> {
        let frames = Self.warmupFrames + Self.analysisFrames
        let input = Self.sine(hz: Self.f0, frames: frames, amplitude: 0.5)
        // driveDb 36 is the maximum: tanh(0.5 · 63.1) = tanh(31.6) is 1.0 to
        // fourteen decimal places, so the shaper is producing a square wave and
        // the odd harmonics are as large as this kind can make them. A gently
        // driven tanh is a near-linear gain stage and every bin below would be
        // vacuously quiet.
        let out = try saturate(
            SaturatorParams(driveDb: 36, mix: 1, outputDb: 0, oversampling: oversampling),
            input)
        return out[Self.warmupFrames..<frames]
    }

    // MARK: - L0: THE DEFAULT HAS NOT MOVED

    /// v0's arithmetic, restated here from the documented contract:
    /// `wet = tanh(g·x)·g^(−1/2)·out`, blended `dry·(1−mix) + wet·mix`, every
    /// operation in `Float` and in this order.
    ///
    /// ⛔ THE ORDER AND THE TYPES ARE THE TEST. A `Double` intermediate, a fused
    /// multiply-add, or a reassociation would each give a DIFFERENT float — and
    /// a reassociated float tap was invisible to all fifteen unit tests of
    /// another kind in this tree and caught only by a byte gate. This function
    /// exists so that failure mode is visible HERE too.
    private static func v0Reference(_ input: [Float], driveDb: Double,
                                    mix: Double, outputDb: Double) -> [Float] {
        let g = pow(10.0, driveDb / 20.0)
        let post = Float(pow(g, -0.5) * pow(10.0, outputDb / 20.0))
        let drive = Float(g)
        let mixGain = Float(mix)
        let dryGain = 1 - mixGain
        return input.map { dry in
            let wet = tanhf(drive * dry) * post
            return dry * dryGain + wet * mixGain
        }
    }

    @Test("L0a — the shipped default is oversampling 1, and 1 means ZERO added latency")
    func defaultIsOneAndCostsNoLatency() {
        let params = SaturatorParams()
        #expect(params.oversampling == 1,
                Comment(rawValue: "a shipped kind may not change what it does at its default "
                    + "(and since the 2026-09-20 ruling a NEW clipper starts at 1 as well)"))
        #expect(SaturatorParams.latencySamples(oversampling: 1) == 0)
        let effect = SaturatorEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(effect.latencySamples == 0,
                Comment(rawValue: "32 samples of shift at the default is exactly the regression "
                    + "m39-ad exists to refuse — the clipper reports 32 even at 1x and this "
                    + "kind must NOT"))
        #expect(effect.activeFactor == 1)
    }

    @Test("L0b — at the default the output is BIT-IDENTICAL to v0's arithmetic")
    func defaultOutputIsBitIdenticalToV0() throws {
        // Material with real dynamic range, not a steady tone: quiet passages
        // (where tanh is near-linear) and loud ones (where it bends) round
        // differently, so a change in the arithmetic shows up in one or the
        // other.
        let frames = 4_096
        var input = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            let t = Double(index) / Self.sampleRate
            let envelope = 0.02 + 0.95 * abs(sin(2 * Double.pi * 3 * t))
            input[index] = Float(envelope * sin(2 * Double.pi * 411 * t)
                                 + 0.2 * envelope * sin(2 * Double.pi * 2_733 * t))
        }
        let params = SaturatorParams()
        let rendered = try saturate(params, input)
        let reference = Self.v0Reference(input, driveDb: params.driveDb,
                                         mix: params.mix, outputDb: params.outputDb)
        #expect(rendered.count == reference.count)
        var mismatches = 0
        var firstMismatch = -1
        for index in 0..<min(rendered.count, reference.count)
        where rendered[index].bitPattern != reference[index].bitPattern {
            mismatches += 1
            if firstMismatch < 0 { firstMismatch = index }
        }
        #expect(mismatches == 0, Comment(rawValue:
            "\(mismatches) of \(frames) samples differ from v0's arithmetic, first at "
            + "\(firstMismatch). The default is no longer what it was, and every saved project "
            + "containing a saturator has changed."))
        // POSITIVE CONTROL: the comparison can FAIL. A reference computed with
        // one knob moved must NOT match — otherwise "0 mismatches" could mean
        // the loop never ran.
        let wrong = Self.v0Reference(input, driveDb: params.driveDb + 0.5,
                                     mix: params.mix, outputDb: params.outputDb)
        var wrongMismatches = 0
        for index in 0..<frames where rendered[index].bitPattern != wrong[index].bitPattern {
            wrongMismatches += 1
        }
        #expect(wrongMismatches > frames / 2, Comment(rawValue:
            "POSITIVE CONTROL FAILED: a deliberately wrong reference matched in "
            + "\(frames - wrongMismatches) places. The bit comparison above proves nothing."))
    }

    /// ⛔⛔ **L0b IS NOT ENOUGH, AND THE REASON IS A MEASURED BLIND SPOT.**
    /// `mix` defaults to 1, so `dryGain` is 0 and the blend degenerates to
    /// `dry·0 + wet·1`. MEASURED during this build: replacing the blend with the
    /// algebraically identical `(dry − wet)·dryGain + wet` — the classic
    /// reassociation, which rounds differently in general — changed NOTHING at
    /// the default, passed L0b, and passed the cross-build sha256 gate. It is a
    /// true negative there (both forms really are exact when `dryGain` is 0),
    /// but it means NEITHER instrument protects the blend at its default.
    ///
    /// Existing projects do NOT all sit at the default. This leg therefore
    /// re-runs the bit comparison over settings where every term is live: a
    /// PARTIAL mix, a non-unity trim, a drive at each end of the range.
    @Test("L0e — the factor-1 arithmetic is v0's at NON-default settings too, including a partial mix")
    func nonDefaultSettingsAreAlsoBitIdenticalToV0() throws {
        let frames = 4_096
        var input = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            let t = Double(index) / Self.sampleRate
            let envelope = 0.03 + 0.9 * abs(sin(2 * Double.pi * 2.7 * t))
            input[index] = Float(envelope * sin(2 * Double.pi * 311 * t)
                                 + 0.3 * envelope * sin(2 * Double.pi * 1_907 * t))
        }
        // ⚠️ EVERY ONE OF THESE HAS `mix` STRICTLY BETWEEN 0 AND 1 except the
        // endpoints, which are included deliberately: 0 is the untouched-buffer
        // law and 1 is the default's degenerate blend.
        let settings: [(Double, Double, Double)] = [
            (12, 0.5, 0), (29, 0.37, -5), (0, 0.5, 7), (36, 0.01, -12),
            (18, 0.99, 3), (12, 1, 0), (6, 0.25, -2),
        ]
        for (driveDb, mix, outputDb) in settings {
            let rendered = try saturate(
                SaturatorParams(driveDb: driveDb, mix: mix, outputDb: outputDb,
                                oversampling: 1), input)
            let reference = Self.v0Reference(input, driveDb: driveDb, mix: mix,
                                             outputDb: outputDb)
            var mismatches = 0
            var firstMismatch = -1
            for index in 0..<frames
            where rendered[index].bitPattern != reference[index].bitPattern {
                mismatches += 1
                if firstMismatch < 0 { firstMismatch = index }
            }
            #expect(mismatches == 0, Comment(rawValue:
                "drive \(driveDb), mix \(mix), trim \(outputDb): \(mismatches) of \(frames) "
                + "samples differ from v0's arithmetic, first at \(firstMismatch). A project "
                + "sitting at these settings has changed."))
        }
    }

    @Test("L0c — explicit oversampling 1 is bit-identical to the default, and 4 is NOT")
    func explicitOneMatchesDefaultAndFourDoesNot() throws {
        let frames = 4_096
        let input = Self.sine(hz: 1_000, frames: frames, amplitude: 0.7)
        let byDefault = try saturate(SaturatorParams(), input)
        let explicitOne = try saturate(
            SaturatorParams(driveDb: 12, mix: 1, outputDb: 0, oversampling: 1), input)
        for index in 0..<frames {
            #expect(byDefault[index].bitPattern == explicitOne[index].bitPattern,
                    Comment(rawValue: "the default does not resolve to factor 1 (index \(index))"))
        }
        // ⭐ INVARIANCE CONTROL. Without this, an effect that ignored the
        // parameter entirely would pass every assertion above.
        let four = try saturate(
            SaturatorParams(driveDb: 12, mix: 1, outputDb: 0, oversampling: 4), input)
        var differing = 0
        for index in 0..<frames where four[index] != byDefault[index] { differing += 1 }
        #expect(differing > frames / 2, Comment(rawValue:
            "factor 4 rendered the same as factor 1 in \(frames - differing) of \(frames) "
            + "samples — the parameter is inert and L1's numbers below would be meaningless"))
    }

    @Test("L0d — a project saved BEFORE this parameter existed decodes to 1")
    func legacyJSONDecodesToFactorOne() throws {
        // Exactly the shape `ProjectDocument` wrote before m39-ad: three keys.
        let legacy = #"{"driveDb":24,"mix":0.5,"outputDb":-3}"#
        let decoded = try JSONDecoder().decode(
            SaturatorParams.self, from: Data(legacy.utf8))
        #expect(decoded.oversampling == 1, Comment(rawValue:
            "a saved project with no `oversampling` key must decode to the setting at which "
            + "this effect is what it was when that project was saved"))
        #expect(decoded.driveDb == 24)
        #expect(decoded.mix == 0.5)
        #expect(decoded.outputDb == -3)
        // POSITIVE CONTROL: the decoder does read the key when it IS present.
        let modern = #"{"driveDb":24,"mix":0.5,"outputDb":-3,"oversampling":4}"#
        #expect(try JSONDecoder().decode(SaturatorParams.self,
                                         from: Data(modern.utf8)).oversampling == 4)
    }

    // MARK: - L1: THE ALIAS FLOOR

    @Test("L1 — 4x drops the alias floor far below 1x, monotonically, and H1/H3 do not move")
    func oversamplingSuppressesTheFoldBack() throws {
        let one = try saturatedTone(oversampling: 1)
        let two = try saturatedTone(oversampling: 2)
        let four = try saturatedTone(oversampling: 4)

        let floors = [one, two, four].map { Self.aliasFloorDb($0) }
        let h1 = [one, two, four].map { Self.db(Self.goertzel($0, hz: Self.f0)) }
        let h3 = [one, two, four].map { Self.db(Self.goertzel($0, hz: Self.thirdHarmonic)) }
        let unprotected = [one, two, four]
            .map { Self.db(Self.goertzel($0, hz: Self.unprotectedAliasBin)) }
        print("[measured] m39-ad alias floor dB — 1x \(floors[0]), 2x \(floors[1]), "
              + "4x \(floors[2]); delta 1x→4x \(floors[0] - floors[2])")
        print("[measured] m39-ad H1 \(h1) · H3 \(h3) · H11 fold \(unprotected)")

        // The naive path must really alias, or every number below is vacuous.
        #expect(floors[0] > -60, Comment(rawValue:
            "at factor 1 the alias floor is \(floors[0]) dB — NOTHING folded back, so there is "
            + "nothing for oversampling to remove and the deltas below mean nothing"))
        // The headline.
        #expect(floors[0] - floors[2] > 25, Comment(rawValue:
            "4x dropped the alias floor by only \(floors[0] - floors[2]) dB"))
        // ⭐⭐ MONOTONIC — proves the factor selects a DIFFERENT filter each
        // time rather than the same one three times.
        #expect(floors[2] < floors[1], Comment(rawValue:
            "4x (\(floors[2])) is not below 2x (\(floors[1]))"))
        #expect(floors[1] < floors[0], Comment(rawValue:
            "2x (\(floors[1])) is not below 1x (\(floors[0]))"))
        // ⭐⭐ THE INVARIANCE LEGS. On m39-ac a planted `factor = 1` left the
        // headline metric comfortably above its floor and was caught ONLY here.
        // Oversampling changes WHERE the tanh runs, not WHAT it does, so the two
        // real in-band harmonics must be identical across the factors. Anything
        // that "fixed" the aliasing by low-passing would fail this and nothing
        // else.
        #expect(h1.max()! - h1.min()! < 0.5, Comment(rawValue:
            "H1 varies by \(h1.max()! - h1.min()!) dB across the factors"))
        #expect(h3.max()! - h3.min()! < 0.5, Comment(rawValue:
            "H3 (a REAL harmonic of the saturation, well inside the passband) varies by "
            + "\(h3.max()! - h3.min()!) dB across the factors — oversampling is changing the "
            + "saturation, or low-passing the result"))
        #expect(h3.min()! > -60, Comment(rawValue:
            "H3 reads \(h3.min()!) dB — the fixture is barely saturating"))
    }

    @Test("L1b — the alias bins are EMPTY before the effect runs (the probe is not seeing ghosts)")
    func theAliasBinsAreEmptyWithoutTheEffect() {
        let frames = Self.warmupFrames + Self.analysisFrames
        let bare = Self.sine(hz: Self.f0, frames: frames, amplitude: 0.5)
        let window = bare[Self.warmupFrames..<frames]
        let floor = Self.aliasFloorDb(window)
        let fundamental = Self.db(Self.goertzel(window, hz: Self.f0))
        print("[measured] m39-ad bare tone — H1 \(fundamental) dB, alias floor \(floor) dB")
        // ⭐ A NEGATIVE RESULT FROM A HAND-BUILT PROBE IS THE WEAKEST EVIDENCE
        // THERE IS. The probe must FIND the tone that is certainly there before
        // "these bins are empty" is believed.
        #expect(fundamental > -12, Comment(rawValue:
            "PROBE IS BLIND: the bare tone's own \(Self.f0) Hz reads \(fundamental) dB"))
        #expect(floor < -100, Comment(rawValue:
            "the alias bins already contain \(floor) dB WITHOUT the effect — L1 cannot "
            + "attribute anything it measures to the saturator"))
    }

    // MARK: - L2: LATENCY

    @Test("L2 — latencySamples is 0 at factor 1 and 32 at factors 2 and 4, at every site")
    func latencyIsZeroAtOneAndThirtyTwoAbove() {
        for (value, expected) in [(1.0, 0), (2.0, Self.oversampledLatency),
                                  (4.0, Self.oversampledLatency)] {
            #expect(SaturatorParams.latencySamples(oversampling: value) == expected)
            let effect = SaturatorEffect(params: SaturatorParams(oversampling: value))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 2)
            #expect(effect.latencySamples == expected, Comment(rawValue:
                "factor \(value) reported \(effect.latencySamples), expected \(expected)"))
        }
        // The snap feeds the latency too: 3 resolves UP to 4, so it costs 32.
        #expect(SaturatorParams.latencySamples(oversampling: 3) == Self.oversampledLatency)
        // ⛔ And the CLIPPER's number is deliberately different at factor 1 —
        // a constant 32 there, 0 here. If these two ever agree at factor 1, one
        // of the two designs has been "harmonised" into a regression.
        #expect(ClipperParams.latencySamples == Self.oversampledLatency)
        #expect(SaturatorParams.latencySamples(oversampling: 1) == 0)
    }

    @Test("L2b — an impulse comes out 32 samples late at 2x/4x and on time at 1x")
    func impulseArrivesLateOnlyWhenOversampling() throws {
        let frames = 1_024
        for (factor, expectedPeak) in [(1.0, 0), (2.0, Self.oversampledLatency),
                                       (4.0, Self.oversampledLatency)] {
            var input = [Float](repeating: 0, count: frames)
            input[0] = 0.5
            // driveDb 0 keeps tanh in its near-linear region, so the output is
            // the FILTER's impulse response rather than a shaped one and the
            // peak position is unambiguous.
            let out = try saturate(
                SaturatorParams(driveDb: 0, mix: 1, outputDb: 0, oversampling: factor), input)
            var peakIndex = 0
            var peak: Float = 0
            for index in 0..<frames where abs(out[index]) > peak {
                peak = abs(out[index]); peakIndex = index
            }
            print("[measured] m39-ad factor \(factor): impulse peak at \(peakIndex), "
                  + "amplitude \(peak)")
            #expect(peakIndex == expectedPeak, Comment(rawValue:
                "factor \(factor) put the impulse peak at \(peakIndex), expected \(expectedPeak) "
                + "— the reported latency and the actual delay disagree, which is a PDC "
                + "misalignment of exactly that many samples"))
            #expect(peak > 0.1, Comment(rawValue:
                "factor \(factor) lost the impulse (peak \(peak)) — a measurement of WHERE a "
                + "peak is means nothing if there is no peak"))
        }
    }

    // MARK: - L3: THE IDENTITY LAWS — one per factor

    @Test("L3a — at factor 1, mix 0 leaves the buffer COMPLETELY untouched, bit for bit")
    func mixZeroAtFactorOneIsBitExactUntouched() throws {
        let frames = 1_024
        var input = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            input[index] = Float(0.4 * sin(2 * Double.pi * 640 * Double(index) / Self.sampleRate))
        }
        // ⛔ The values a "harmless" arithmetic no-op would destroy.
        input[3] = -0.0
        input[4] = Float(bitPattern: 1)             // the smallest subnormal
        input[5] = -Float(bitPattern: 1)
        input[6] = .infinity
        input[7] = -.infinity
        // Every OTHER knob non-default, so this proves a law and not a bypass.
        let out = try saturate(
            SaturatorParams(driveDb: 31, mix: 0, outputDb: -7, oversampling: 1), input)
        for index in 0..<frames {
            #expect(out[index].bitPattern == input[index].bitPattern, Comment(rawValue:
                "sample \(index): \(out[index]) is not bit-identical to \(input[index])"))
        }
        // −0.0 specifically: `dry * 0 + wet * 0` would give +0.0 and pass an
        // `==` comparison while failing this one.
        #expect(out[3].sign == .minus, Comment(rawValue:
            "negative zero came back as +0.0 — the buffer WAS written"))
    }

    @Test("L3b — at factor 2/4, mix 0 is the input DELAYED BY 32, bit for bit")
    func mixZeroAtOversampledFactorsIsADelayedIdentity() throws {
        let frames = 2_048
        let latency = Self.oversampledLatency
        for factor in [2.0, 4.0] {
            var input = [Float](repeating: 0, count: frames)
            for index in 0..<frames {
                input[index] = Float(
                    0.4 * sin(2 * Double.pi * 640 * Double(index) / Self.sampleRate))
            }
            input[100] = -0.0
            input[101] = Float(bitPattern: 1)
            input[102] = -Float(bitPattern: 1)
            input[103] = .infinity
            let out = try saturate(
                SaturatorParams(driveDb: 31, mix: 0, outputDb: -7, oversampling: factor), input)
            // An effect reporting 32 samples of latency that then passed audio
            // through UNDELAYED would be mis-aligned by 32 against everything
            // PDC compensates around it.
            for index in latency..<frames {
                #expect(out[index].bitPattern == input[index - latency].bitPattern,
                        Comment(rawValue: "factor \(factor), sample \(index): \(out[index]) is "
                            + "not bit-identical to in[\(index - latency)] = "
                            + "\(input[index - latency])"))
            }
            #expect(out[100 + latency].sign == .minus, Comment(rawValue:
                "factor \(factor): negative zero came back as +0.0 — the dry path is not a "
                + "plain copy"))
            #expect(out[101 + latency].bitPattern == Float(bitPattern: 1).bitPattern,
                    Comment(rawValue: "factor \(factor): the dry ring flushed a subnormal — it "
                        + "must NOT; only the Oversampler's own histories do that"))
        }
    }

    // MARK: - L4: THE SNAP

    @Test("L4 — the snap is the roster's, re-derived by brute force, and the clipper's exactly")
    func snapMatchesTheRosterAndTheClipper() {
        /// Nearest supported factor, ties resolving UPWARD — re-derived from
        /// `OversamplerDesign.supportedFactors` rather than restating the
        /// thresholds, so a change to the roster reddens this instead of
        /// silently disagreeing with it.
        func brute(_ value: Double) -> Int {
            let clamped = min(max(value, 1), 4)
            var best = OversamplerDesign.supportedFactors[0]
            var bestDistance = Double.infinity
            for candidate in OversamplerDesign.supportedFactors {
                let distance = abs(Double(candidate) - clamped)
                if distance < bestDistance || (distance == bestDistance && candidate > best) {
                    best = candidate
                    bestDistance = distance
                }
            }
            return best
        }
        var checked = 0
        var value = -2.0
        while value <= 6.0 {
            let mine = SaturatorParams.oversamplingFactor(at: value)
            #expect(mine == brute(value), Comment(rawValue:
                "\(value) snapped to \(mine), brute force says \(brute(value))"))
            // ⛔ AND THE CLIPPER'S, EXACTLY. The rule is a property of the
            // filter family, not of either kind; two copies could drift.
            #expect(mine == ClipperParams.oversamplingFactor(at: value), Comment(rawValue:
                "\(value): saturator snaps to \(mine), clipper to "
                + "\(ClipperParams.oversamplingFactor(at: value))"))
            #expect(OversamplerDesign.supportedFactors.contains(mine))
            checked += 1
            value += 0.01
        }
        print("[measured] m39-ad snap sweep — \(checked) values agreed with the roster "
              + "and with the clipper")
        #expect(checked > 700, "the sweep barely ran")
        // The documented ties, named rather than left to the sweep.
        #expect(SaturatorParams.oversamplingFactor(at: 1.5) == 2)
        #expect(SaturatorParams.oversamplingFactor(at: 3.0) == 4)
        #expect(SaturatorParams.oversamplingFactor(at: .nan) == OversamplerDesign.maxFactor)
        // The init snaps too, so a stored value is always a legal factor.
        #expect(SaturatorParams(oversampling: 3).oversampling == 4)
        #expect(SaturatorParams(oversampling: 1.5).oversampling == 2)
        #expect(SaturatorParams(oversampling: .nan).oversampling == 1)
    }

    @Test("L4b — the snapped factor reaches the PRIMITIVE, not just the params struct")
    func theFactorReachesTheOversampler() throws {
        for (requested, expected) in [(1.0, 1), (1.4, 1), (1.5, 2), (2.0, 2),
                                      (3.0, 4), (4.0, 4)] {
            let effect = SaturatorEffect(params: SaturatorParams(oversampling: requested))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 256,
                           channelCount: 1)
            // The factor is adopted at the first quantum, not at init.
            _ = try processChunked(effect, channels: [[Float](repeating: 0.1, count: 256)],
                                   chunk: 256)
            #expect(effect.activeFactor == expected, Comment(rawValue:
                "requested \(requested): the primitive is at \(effect.activeFactor), "
                + "expected \(expected)"))
        }
    }

    // MARK: - L5: THE FACTOR IS INERT TO AUTOMATION

    /// ⛔⛔ **THE HARDEST CORRECTNESS PROPERTY IN m39-ad.** This kind's latency
    /// depends on the factor, and the PDC plan is rebuilt ONLY on a main-actor
    /// parameter pass. If an automation lane could move the factor from the
    /// render thread, the plan would go stale with every other test still green
    /// — the exact failure `OversamplerDesign` §3 describes. Slot 3 is therefore
    /// inert here, the `delay.sync` / `delay.division` precedent.
    @Test("L5 — automation CANNOT move the oversampling factor, and the other slots still work")
    func automationCannotMoveTheFactor() throws {
        let effect = SaturatorEffect(params: SaturatorParams(
            driveDb: 12, mix: 1, outputDb: 0, oversampling: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 256, channelCount: 1)
        let input = Self.sine(hz: 1_000, frames: 1_024, amplitude: 0.6)
        let out = try processChunked(effect, channels: [input], chunk: 256) { effect, _ in
            // Every plausible way an automation lane could try to move it.
            effect.storeAutomatedParam(slot: 3, value: 4)
            effect.storeAutomatedParam(slot: 3, value: 2)
            effect.storeAutomatedParam(slot: 4, value: 4)
        }
        #expect(effect.activeFactor == 1, Comment(rawValue:
            "automation moved the factor to \(effect.activeFactor). The PDC plan is now stale "
            + "by 32 samples and nothing else in this suite can see it."))
        #expect(effect.latencySamples == 0, Comment(rawValue:
            "automation moved the reported latency to \(effect.latencySamples)"))
        #expect(out[0].count == 1_024)
        // ⭐ POSITIVE CONTROL: slot 3 being ignored must not mean the whole
        // automation path is dead. Slot 0 (driveDb) must still land.
        let live = SaturatorEffect(params: SaturatorParams(driveDb: 0, mix: 1, outputDb: 0))
        live.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 256, channelCount: 1)
        let quiet = try processChunked(live, channels: [input], chunk: 256) { effect, _ in
            effect.storeAutomatedParam(slot: 0, value: 36)
        }
        let plain = try saturate(SaturatorParams(driveDb: 0, mix: 1, outputDb: 0), input)
        var moved = 0
        for index in 0..<1_024 where quiet[0][index] != plain[index] { moved += 1 }
        #expect(moved > 512, Comment(rawValue:
            "POSITIVE CONTROL FAILED: automating driveDb changed \(moved) of 1024 samples — "
            + "the automation path itself is dead, so 'slot 3 is inert' proves nothing"))
    }

    // MARK: - L6: RESET AND STATE

    @Test("L6 — reset() clears the dry ring and both filter histories")
    func resetClearsEverything() throws {
        let effect = SaturatorEffect(params: SaturatorParams(
            driveDb: 18, mix: 0.5, outputDb: 0, oversampling: 4))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 256, channelCount: 2)
        let input = Self.sine(hz: 700, frames: 1_024, amplitude: 0.8)
        _ = try processChunked(effect, channels: [input, input], chunk: 256)
        // POSITIVE CONTROL first: there must BE state, or "reset cleared it" is
        // a statement about nothing.
        let before = effect.nonZeroStateWords
        print("[measured] m39-ad state words after render: \(before)")
        #expect(before > 0, "nothing accumulated state, so reset() cannot be shown to clear it")
        #expect(effect.filterStateWords > 0, "the FIR histories are empty")
        effect.reset()
        #expect(effect.nonZeroStateWords == 0, Comment(rawValue:
            "reset() left \(effect.nonZeroStateWords) non-zero state words"))
    }

    @Test("L6b — changing the factor clears the dry ring, so no stale burst crosses the change")
    func aFactorChangeClearsTheDryRing() async throws {
        let effect = SaturatorEffect(params: SaturatorParams(
            driveDb: 18, mix: 0, outputDb: 0, oversampling: 4))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 256, channelCount: 1)
        let loud = [Float](repeating: 0.9, count: 512)
        _ = try processChunked(effect, channels: [loud], chunk: 256)
        #expect(effect.nonZeroStateWords > 0)
        // A main-actor publish is the ONLY way the factor moves.
        await MainActor.run {
            effect.apply(params: SaturatorParams(driveDb: 18, mix: 0, outputDb: 0,
                                                 oversampling: 2))
        }
        let silence = [Float](repeating: 0, count: 512)
        let out = try processChunked(effect, channels: [silence], chunk: 256)
        // The ring was cleared with the factor, so the loud tail cannot come
        // back out through the new path.
        for index in 0..<512 {
            #expect(out[0][index] == 0, Comment(rawValue:
                "sample \(index) = \(out[0][index]): audio from before the factor change "
                + "leaked through the new one"))
        }
        #expect(effect.activeFactor == 2)
        #expect(effect.latencySamples == Self.oversampledLatency)
    }

    // MARK: - L7: STEREO

    @Test("L7 — both channels are saturated, independently, at every factor")
    func stereoChannelsAreBothProcessed() throws {
        let frames = 4_096
        let left = Self.sine(hz: 1_000, frames: frames, amplitude: 0.9)
        let right = Self.sine(hz: 1_000, frames: frames, amplitude: 0.3)
        for factor in [1.0, 2.0, 4.0] {
            let effect = SaturatorEffect(params: SaturatorParams(
                driveDb: 24, mix: 1, outputDb: 0, oversampling: factor))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 2)
            let out = try processChunked(effect, channels: [left, right])
            // Both channels moved (a channel left untouched would match input).
            for channel in 0..<2 {
                var changed = 0
                let source = channel == 0 ? left : right
                for index in 1_024..<frames where out[channel][index] != source[index] {
                    changed += 1
                }
                #expect(changed > 1_000, Comment(rawValue:
                    "factor \(factor), channel \(channel): only \(changed) samples changed"))
            }
            // And they are NOT the same signal — a bug that processed channel 0
            // twice would pass every assertion above.
            var differing = 0
            for index in 1_024..<frames where out[0][index] != out[1][index] { differing += 1 }
            #expect(differing > 1_000, Comment(rawValue:
                "factor \(factor): the two channels are identical — channel 1 was not "
                + "processed from its own input"))
            // Identical inputs must give identical outputs, so the difference
            // above is the input and not a per-channel state bug.
            let mirrorEffect = SaturatorEffect(params: SaturatorParams(
                driveDb: 24, mix: 1, outputDb: 0, oversampling: factor))
            mirrorEffect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                                 channelCount: 2)
            let mirrored = try processChunked(mirrorEffect, channels: [left, left])
            for index in 0..<frames {
                #expect(mirrored[0][index] == mirrored[1][index], Comment(rawValue:
                    "factor \(factor): identical inputs gave different outputs at \(index)"))
            }
        }
    }

    // MARK: - L8: NaN AND DENORMALS

    @Test("L8 — a NaN does not poison the oversampled path forever, and subnormals stay finite")
    func nonFiniteInputCannotKillTheStrip() throws {
        let frames = 4_096
        for factor in [2.0, 4.0] {
            var input = Self.sine(hz: 800, frames: frames, amplitude: 0.6)
            input[500] = .nan
            input[501] = .infinity
            input[502] = -.infinity
            let out = try saturate(
                SaturatorParams(driveDb: 20, mix: 1, outputDb: 0, oversampling: factor), input)
            // The damage is BOUNDED: within the filter's own span the output is
            // finite again and the tone is back. A NaN in the decimation
            // history would silence (or NaN) the strip permanently.
            let recoverFrom = 502 + 4 * OversamplerDesign.latencySamples
            var nonFinite = 0
            for index in recoverFrom..<frames where !out[index].isFinite { nonFinite += 1 }
            #expect(nonFinite == 0, Comment(rawValue:
                "factor \(factor): \(nonFinite) non-finite samples remain \(recoverFrom - 502) "
                + "samples after the NaN — it is in a filter history with no path back"))
            var energy = 0.0
            for index in (frames - 1_024)..<frames { energy += Double(out[index] * out[index]) }
            #expect(energy > 1e-3, Comment(rawValue:
                "factor \(factor): the strip is silent long after the NaN (energy \(energy))"))
        }
    }

    @Test("L8b — a stream of subnormals produces finite output and never a NaN")
    func subnormalsAreHandled() throws {
        let frames = 2_048
        var input = [Float](repeating: 0, count: frames)
        for index in 0..<frames { input[index] = Float(bitPattern: UInt32(1 + index % 7)) }
        for factor in [1.0, 2.0, 4.0] {
            let out = try saturate(
                SaturatorParams(driveDb: 36, mix: 1, outputDb: 0, oversampling: factor), input)
            for index in 0..<frames {
                #expect(out[index].isFinite, Comment(rawValue:
                    "factor \(factor), sample \(index): \(out[index])"))
            }
        }
    }

    // MARK: - L9: the render path allocates NOTHING

    // The hook, the counter cells and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe): one measurement at a time.
    // `warmup:` runs with the hook live and the counter is zeroed after it.

    /// ⛔ RUN AT BOTH FACTORS. Factor 1 is a DIFFERENT function
    /// (`processAtBaseRate`) from factors 2/4 (`processOversampled`), and the
    /// default is the one every existing project uses.
    @Test("L9 — process() allocates NOTHING across 2 000 quanta, at factor 1 AND at factor 4",
          arguments: [1.0, 4.0])
    func processIsAllocationFree(factor: Double) throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("""
                malloc_logger is unavailable — the allocation probe cannot run. \
                FAILURE, not a skip.
                """)
            return
        }
        let quantum = 256
        let calls = 2_000
        let effect = SaturatorEffect(params: SaturatorParams(
            driveDb: 21, mix: 0.6, outputDb: -3, oversampling: factor))
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
        let events = MallocProbe.events(slot: slot, warmup: {
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
                // The REFUSED slot too: being ignored must also be free.
                if call % 101 == 0 {
                    effect.storeAutomatedParam(slot: 3, value: call % 202 == 0 ? 2 : 4)
                }
                effect.process(buffers: list, frameCount: quantum)
                sum += data[0][quantum - 1]
                call += 1
            }
        }
        print("[measured] m39-ad malloc events at factor \(factor) across \(calls) quanta: "
              + "\(events)")
        #expect(events == 0, Comment(rawValue:
            "the render path allocated \(events) times at factor \(factor)"))
        #expect(sum.isFinite)
        #expect(sum != 0, "the measured region rendered silence")
        #expect(effect.activeFactor == SaturatorParams.oversamplingFactor(at: factor))
    }

    @Test("L9b — POSITIVE CONTROL: the malloc probe can actually count")
    func theAllocationProbeCanSeeAnAllocation() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⭐ A zero from a probe that never fires and a zero from a render that
        // never allocates are the same number.
        var sink: [[Int]] = []
        let events = MallocProbe.events(slot: slot) {
            var index = 0
            while index < 200 {
                sink.append([Int](repeating: index, count: 64))
                index += 1
            }
        }
        #expect(events > 0, Comment(rawValue:
            "the malloc probe counted \(events) events on 200 allocations"))
        #expect(sink.count == 200)
    }
}
