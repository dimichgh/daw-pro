import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `FlangerTests`, `RingModTests`, `DJFilterTests` and `BitCrusherTests` all
// record: the main actor is ONE serialization point for the whole test process,
// these tests render hundreds of thousands of frames of audio, and they need no
// main-actor state at all. (There is also a hard structural reason today:
// `MainActorOccupancySiteTests` Leg C pins the `@MainActor`-isolated SUITE count
// at its cap with ZERO slack.)
//
// The one main-actor thing an effect owns is `apply(params:)`; these tests
// construct effects with their params, and use the nonisolated render-thread
// `storeAutomatedParam` where a value has to move mid-render.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-o — the `.phaser` insert. `PhaserParams` holds the laws; this suite
/// proves the RENDERED AUDIO obeys them.
///
/// ⭐⭐ **THE CENTRAL LEG IS L4, AND IT IS THE ONLY KIND OF TEST THAT CAN TELL A
/// PHASER FROM A FLANGER.** Both kinds sweep, both "whoosh", and a test that
/// shows "the output changed" cannot distinguish them. So ONE notch-finder is
/// run over BOTH shipped kinds and each law is asserted to fit its own effect
/// **and to be REJECTED by the other**. A phaser that had quietly been built as
/// a flanger would pass every other leg in this file.
///
/// ⭐ **Every claim is MEASURED FROM RENDERED OUTPUT, never read back from the
/// parameter.** The plausible wrong implementations separate:
///
///  · the all-pass coefficient SIGN inverted (the easy
///    mistake — `(1−t)/(1+t)` instead of `(t−1)/(t+1)`)  → MEASURED by
///    planting it: `PhaserParamsTests`' −90° leg (19 issues), L2's notch
///    positions (82 issues) and ALSO L3's count. ⚠️ An earlier draft of this
///    comment claimed "L2 ONLY, the count passes either way" — that was
///    reasoning, not measurement, and the plant refuted it: the wrong sign puts
///    the corner near DC instead of at `centerHz`, which drags notches out of
///    the 15 Hz–12 kHz scan window, so the COUNT changes too. L3 reddens for a
///    WINDOW reason, not because a count can tell the two signs apart; L2 is
///    still the leg that discriminates.
///  · a harmonic comb (i.e. someone built a flanger)     → L4, the cross test
///  · `stages` ignored / hardcoded                       → L3, which renders
///    four different counts and measures each
///  · feedback silently 0, or its SIGN inverted          → L5, measured against
///    the closed form; nothing else here can see it
///  · the per-section denormal flush removed             → L6, which asserts NO
///    OUTPUT OR STATE VALUE IS SUBNORMAL and runs at feedback 0 as well as
///    0.9, because every section is its own IIR
///  · the LFO frozen                                     → L7; every other leg
///    renders at `depthOctaves: 0` so the measurement is of an LTI system
///  · `mix == 0` writing the buffer                      → L1a, with L1b as its
///    positive control so "bit-exact" cannot mean "inert"
///  · the chain PAUSED at `mix == 0`                     → L1c
///  · `stereoPhaseDeg` ignored                           → L8
///  · a slot mis-wired in `storeAutomatedParam`          → L9
///  · stale state spliced back in on a stage change      → L10
///  · the 32-frame coefficient STEPPED, not interpolated → L14, and ONLY L14:
///    every other spectral leg here renders at `depthOctaves: 0`, where the
///    coefficient never moves and the two shapes are identical
///  · an allocation on the render path                   → L15 (§12 gate 2),
///    with L15b as the probe's own positive control
@Suite("Phaser — non-harmonic swept notches, per-section flush (m39-o)", .serialized)
struct PhaserTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (FlangerTests conventions)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    private func constant(_ value: Float, frames: Int) -> [Float] {
        [Float](repeating: value, count: frames)
    }

    private func impulse(frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        samples[0] = 1
        return samples
    }

    private func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    private func mean(_ samples: [Float], in range: Range<Int>) -> Double {
        var total = 0.0
        for index in range { total += Double(samples[index]) }
        return total / Double(range.count)
    }

    /// Exact DTFT magnitude of a FULLY DECAYED impulse response at `frequency`.
    /// Because the response has decayed inside the window there is no
    /// truncation, so this is the true frequency response and the nulls are as
    /// deep as the arithmetic allows — which is what makes notch-finding here a
    /// sharp instrument rather than a fuzzy one.
    private func magnitude(_ ir: [Float], at frequency: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / Self.sampleRate
        var re = 0.0, im = 0.0
        var index = 0
        while index < ir.count {
            let value = Double(ir[index])
            let angle = w * Double(index)
            re += value * cos(angle)
            im -= value * sin(angle)
            index += 1
        }
        return (re * re + im * im).squareRoot()
    }

    /// Finds every notch in `ir` between `lo` and `hi` Hz: a coarse log scan for
    /// local minima deeper than `thresholdDb` relative to unity, then a ternary
    /// refinement of each so the reported frequency is not grid-limited.
    ///
    /// ⭐ ONE FINDER, USED ON BOTH KINDS (L4). If it were tuned to the phaser it
    /// could not be evidence about the flanger.
    /// ⚠️ `lo` DEFAULTS TO 15 Hz AND THAT IS NOT DECORATION. The first version
    /// of this finder started at 40 Hz and silently reported 3 notches for an
    /// 8-section chain and 5 for a 12-section one — because a phaser's LOWEST
    /// notch sits well BELOW its corner (0.199x it at 8 stages, 0.132x at 12),
    /// so a 150 Hz corner puts it at 29.8 Hz and 19.8 Hz. A scan window that
    /// crops the answer produces a confident wrong count, not an error.
    private func findNotches(_ ir: [Float], lo: Double = 15, hi: Double = 12_000,
                             points: Int = 700, thresholdDb: Double = -12) -> [Double] {
        let ratio = hi / lo
        var grid = [Double](repeating: 0, count: points)
        var levels = [Double](repeating: 0, count: points)
        for index in 0..<points {
            grid[index] = lo * pow(ratio, Double(index) / Double(points - 1))
            levels[index] = dB(magnitude(ir, at: grid[index]))
        }
        var found: [Double] = []
        for index in 1..<(points - 1)
        where levels[index] < levels[index - 1] && levels[index] <= levels[index + 1]
            && levels[index] < thresholdDb {
            // Ternary search between the bracketing grid points.
            var low = grid[index - 1], high = grid[index + 1]
            for _ in 0..<60 {
                let a = low + (high - low) / 3
                let b = high - (high - low) / 3
                if magnitude(ir, at: a) < magnitude(ir, at: b) { high = b } else { low = a }
            }
            found.append((low + high) / 2)
        }
        return found
    }

    /// Runs `channels` through `effect` in `chunk`-frame quanta (state
    /// continuity across quantum boundaries included in the proof). `poke` runs
    /// once per quantum before `process`, which is how an automation lane
    /// actually arrives.
    private func processChunked(_ effect: any EffectRendering,
                                channels: [[Float]], chunk: Int = 512,
                                poke: ((any EffectRendering, Int) -> Void)? = nil)
        throws -> [[Float]] {
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

    /// One mono pass through a freshly prepared phaser.
    private func phase(_ params: PhaserParams, _ input: [Float],
                       chunk: Int = 512) throws -> [Float] {
        let effect = PhaserEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// One stereo pass through a freshly prepared phaser.
    private func phaseStereo(_ params: PhaserParams, left: [Float], right: [Float],
                             chunk: Int = 512) throws -> (left: [Float], right: [Float]) {
        let effect = PhaserEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        let out = try processChunked(effect, channels: [left, right], chunk: chunk)
        return (out[0], out[1])
    }

    /// ⭐ THE MEASUREMENT CONFIGURATION, and it is a real setting rather than a
    /// test-only back door: `depthOctaves: 0` freezes the sweep, which makes the
    /// effect LINEAR AND TIME-INVARIANT — so one impulse response characterises
    /// it completely and the notches can be located exactly. `feedback: 0` and
    /// `mix: 0.5` put the dry and wet paths at equal weight, where the nulls are
    /// complete (the response is `(1 + A(z))/2` and `A` is all-pass).
    private func parked(centerHz: Double = 300, stages: Double = 8,
                        feedback: Double = 0, mix: Double = 0.5) -> PhaserParams {
        PhaserParams(rateHz: 0.02, centerHz: centerHz, depthOctaves: 0, stages: stages,
                     feedback: feedback, mix: mix, stereoPhaseDeg: 0)
    }

    private static let irFrames = 8_192

    // MARK: - L1: the mix convention (rule 6.0.7)

    /// ⚠️⚠️ **"BIT-EXACT" IS COMPARED BITWISE, AND THE FIXTURE CARRIES −0.0 —
    /// BOTH BECAUSE THE OBVIOUS FORM OF THIS LEG IS BLIND.** The first version
    /// was `#expect(out == input)` on a sine, and it **passed with the
    /// `mix != 0` guard deleted**, measured by planting exactly that. Two
    /// independent reasons, and each alone is enough:
    ///
    ///  1. At `mix == 0` the replacement arithmetic is `dry·1 + wet·0`, which
    ///     for every NORMAL float is exactly `dry`. A sine fixture therefore
    ///     cannot distinguish "never written" from "written with a neutral
    ///     blend". The one input that can is **−0.0**: `−0.0·1 + wet·0` is
    ///     `−0.0 + 0.0` = `+0.0`, a different bit pattern.
    ///  2. …which `==` STILL cannot see, because IEEE says `−0.0 == +0.0`.
    ///     An array `==` on `[Float]` is not a bit comparison and must not be
    ///     used to prove one.
    ///
    /// So the fixture now contains signed zeros, subnormals and full-scale
    /// values, and the comparison is on `bitPattern`.
    @Test("L1a — mix 0 is BIT-EXACT dry, bit pattern for bit pattern")
    func mixZeroIsBitExactDry() throws {
        var input = sine(220, amplitude: 0.7, frames: 4_096)
        // The values that separate "untouched" from "neutrally blended".
        input[0] = -0.0
        input[1] = 0.0
        input[2] = -Float.leastNonzeroMagnitude
        input[3] = Float.leastNonzeroMagnitude
        input[4] = -1.0
        input[5] = 1.0
        input[6] = -Float.leastNormalMagnitude
        let out = try phase(PhaserParams(mix: 0), input)
        #expect(out.count == input.count)
        var firstDifference: Int?
        for index in 0..<min(out.count, input.count)
        where out[index].bitPattern != input[index].bitPattern {
            firstDifference = index
            break
        }
        #expect(firstDifference == nil, """
            the buffer was WRITTEN at mix 0 — first differing sample is \
            \(firstDifference ?? -1)
            """)
        // NON-VACUITY: the fixture really does carry a negative zero, which is
        // the sample that makes the bitwise comparison worth making.
        #expect(input[0].bitPattern == Float(-0.0).bitPattern)
        #expect(input[0].bitPattern != Float(0.0).bitPattern)
        #expect(input[0] == Float(0.0), "…and `==` cannot tell them apart, which is the point")
    }

    @Test("L1b — positive control: the same render at mix 0.5 is NOT the input")
    func mixNonZeroChangesTheBuffer() throws {
        let input = sine(220, amplitude: 0.7, frames: 4_096)
        let out = try phase(PhaserParams(mix: 0.5), input)
        #expect(out != input)
        var maxDiff = 0.0
        for index in 0..<input.count {
            maxDiff = max(maxDiff, abs(Double(out[index] - input[index])))
        }
        print("[measured] L1b max deviation from dry at mix 0.5: \(maxDiff)")
        #expect(maxDiff > 0.05)
    }

    /// ⛔ THE `ChorusEffect` CONVENTION: at `mix == 0` the buffer is untouched
    /// but the chain and the LFO KEEP RUNNING, so raising `mix` later picks up
    /// mid-sweep rather than swelling from silence. An implementation that
    /// early-returns out of `process` passes L1a and fails here.
    @Test("L1c — at mix 0 the all-pass chain still runs, so a later mix raise is not silence")
    func chainKeepsRunningWhileMixIsZero() throws {
        let frames = 4_096
        let input = sine(400, amplitude: 0.6, frames: frames * 2)
        let effect = PhaserEffect(params: PhaserParams(rateHz: 0.02, centerHz: 300,
                                                       depthOctaves: 0, stages: 8,
                                                       feedback: 0.8, mix: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        // First half at mix 0 (bit-exact), then the lane raises mix to 0.5.
        let out = try processChunked(effect, channels: [input], chunk: 512) { fx, quantum in
            if quantum >= frames / 512 { fx.storeAutomatedParam(slot: 5, value: 0.5) }
        }[0]
        for index in 0..<frames { #expect(out[index] == input[index]) }
        // The first quantum AFTER the raise is already fully developed: a chain
        // that had been reset would start from a transient.
        let firstAfter = out[(frames + 64)..<(frames + 512)]
        var energy = 0.0
        for value in firstAfter { energy += Double(value) * Double(value) }
        let rms = (energy / Double(firstAfter.count)).squareRoot()
        print("[measured] L1c RMS in the first quantum after the mix raise: \(rms)")
        #expect(rms > 0.1)
    }

    // MARK: - L2: ⭐ THE NOTCH POSITIONS — the leg the coefficient sign fails

    /// ⭐⭐ §12 gate 9's shape for this kind: the notches are measured out of a
    /// rendered impulse response and compared with `PhaserParams.notchHz`.
    ///
    /// ⛔ THIS IS THE ONLY LEG IN THE FILE THAT SEES A COEFFICIENT-SIGN ERROR.
    /// `(1−t)/(1+t)` is also a stable all-pass and also yields `stages/2`
    /// notches, so L3's count leg is blind to it. Only a POSITION measurement
    /// separates them — and it separates them violently, because the wrong sign
    /// puts no notch at all anywhere near the predicted frequency.
    @Test("⭐ L2 — rendered notches land where PhaserParams.notchHz says, at every stage count")
    func renderedNotchesMatchTheLaw() throws {
        var checked = 0
        for stages in [4.0, 6, 8, 12] {
            for centerHz in [150.0, 300, 700] {
                let params = parked(centerHz: centerHz, stages: stages)
                let ir = try phase(params, impulse(frames: Self.irFrames))
                let expected = (0..<PhaserParams.notchCount(stages: stages)).map {
                    PhaserParams.notchHz(cornerHz: centerHz, stages: stages, index: $0,
                                         sampleRate: Self.sampleRate)
                }
                for (index, predicted) in expected.enumerated()
                where predicted > 45 && predicted < 11_500 {
                    // The depth AT the predicted frequency is the assertion: a
                    // phaser whose notch is elsewhere shows no null here.
                    let atNotch = dB(magnitude(ir, at: predicted))
                    let shoulder = max(dB(magnitude(ir, at: predicted * 0.5)),
                                       dB(magnitude(ir, at: predicted * 2.0)))
                    print("[measured] stages \(Int(stages)) centre \(centerHz) notch \(index) "
                          + "@\(predicted) Hz: \(atNotch) dB, shoulders \(shoulder) dB")
                    #expect(atNotch < -40,
                            "stages \(Int(stages)) centre \(centerHz): no null at the predicted \(predicted) Hz — the coefficient sign is the first thing to check")
                    #expect(shoulder > atNotch + 30, "the null is not localised")
                    checked += 1
                }
            }
        }
        print("[measured] L2 checked \(checked) predicted notch positions")
        #expect(checked >= 30, "the notch grid went vacuous")
    }

    // MARK: - L3: the notch COUNT scales with `stages`

    /// ⭐ §12's "assert the notch count scales with `stages`". Every two sections
    /// buy exactly one notch. ⚠️ A SINGLE STAGE COUNT COULD NOT CATCH A
    /// HARDCODED N, which is why four are rendered.
    @Test("⭐ L3 — the measured notch COUNT is exactly stages/2, for 4, 6, 8 and 12")
    func notchCountScalesWithStages() throws {
        var counts: [Int: Int] = [:]
        for stages in [4.0, 6, 8, 12] {
            // 150 Hz puts every notch of even a 12-section chain inside the
            // scan band: the ratios run 0.132 … 7.60, so 19.8 Hz … 1 140 Hz.
            let ir = try phase(parked(centerHz: 150, stages: stages),
                               impulse(frames: Self.irFrames))
            let notches = findNotches(ir, lo: 15, hi: 8_000)
            print("[measured] stages \(Int(stages)): \(notches.count) notches at \(notches)")
            counts[Int(stages)] = notches.count
            #expect(notches.count == PhaserParams.notchCount(stages: stages),
                    "stages \(Int(stages)) produced \(notches.count) notches, expected \(PhaserParams.notchCount(stages: stages))")
        }
        // Non-vacuity: the four counts are genuinely different, so a finder that
        // always returned the same number could not have passed.
        #expect(Set(counts.values).count == 4)
        #expect(counts[4] == 2 && counts[6] == 3 && counts[8] == 4 && counts[12] == 6)
    }

    // MARK: - L4: ⭐⭐ THE CROSS TEST — a phaser is not a flanger, MEASURED

    /// ⭐⭐⭐ THE LEG THIS WHOLE ITEM IS ABOUT. One notch-finder, two shipped
    /// effect kinds, four assertions:
    ///
    ///   1. the PHASER's measured notches fit `PhaserParams.notchHz`
    ///   2. the PHASER's measured notches do NOT fit a flanger's odd-harmonic
    ///      comb built from its own first notch
    ///   3. the FLANGER's measured notches fit `FlangerParams.combNotchHz`
    ///   4. the FLANGER's measured notches do NOT fit the phaser ratio law
    ///
    /// 1 and 3 alone would pass if both kinds were flangers. 2 and 4 are what
    /// make this a discrimination rather than two independent self-checks, and
    /// 3 is the positive control that proves the finder works on material it
    /// was not tuned for.
    @Test("⭐⭐ L4 — the phaser's notches are NON-harmonic and the flanger's ARE, same finder")
    func phaserAndFlangerSeparateUnderTheSameMeasurement() throws {
        // --- the phaser: 8 sections, parked at 150 Hz -------------------------
        let phaserIR = try phase(parked(centerHz: 150, stages: 8),
                                 impulse(frames: Self.irFrames))
        let phaserNotches = findNotches(phaserIR, lo: 15, hi: 8_000)
        #expect(phaserNotches.count == 4)
        let phaserRatios = phaserNotches.map { $0 / phaserNotches[0] }
        print("[measured] PHASER notches \(phaserNotches) ratios \(phaserRatios)")

        // (1) fits its own law
        for index in 0..<phaserNotches.count {
            let predicted = PhaserParams.notchHz(cornerHz: 150, stages: 8, index: index,
                                                 sampleRate: Self.sampleRate)
            #expect(abs(phaserNotches[index] - predicted) / predicted < 0.02,
                    "phaser notch \(index) measured \(phaserNotches[index]) vs law \(predicted)")
        }
        // (2) does NOT fit the flanger's odd-harmonic comb
        for index in 1..<phaserNotches.count {
            let harmonic = Double(2 * index + 1)
            let error = abs(phaserRatios[index] - harmonic) / harmonic
            print("[measured] phaser ratio \(index): \(phaserRatios[index]) vs comb \(harmonic) — \(error * 100) % off")
            #expect(error > 0.10,
                    "the phaser's notch \(index) sits within 10 % of a flanger comb line — it is not obeying the non-harmonic law")
        }

        // --- the flanger: the same finder, on the shipped sibling -------------
        // Parked the way FlangerTests parks it: the sweep floor plus half the
        // minimum depth, so the comb is static for the measurement.
        let flangerParams = FlangerParams(rateHz: 0.02, depthMs: 0.1, delayMs: 2.0,
                                          feedback: 0, mix: 0.5, stereoPhaseDeg: 0)
        let flangerEffect = FlangerEffect(params: flangerParams)
        flangerEffect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                              channelCount: 1)
        let flangerIR = try processChunked(
            flangerEffect, channels: [impulse(frames: Self.irFrames)], chunk: 512)[0]
        let flangerNotches = findNotches(flangerIR, lo: 15, hi: 8_000)
        print("[measured] FLANGER notches \(flangerNotches)")
        // ⭐ THE COUNT IS ALREADY A SEPARATION: a comb fills the band, a phaser
        // puts a handful in it.
        #expect(flangerNotches.count > 2 * phaserNotches.count,
                "the flanger comb should be far denser than the phaser's \(phaserNotches.count) notches in the same band")
        let flangerRatios = flangerNotches.map { $0 / flangerNotches[0] }

        // (3) POSITIVE CONTROL — the finder works on the other kind too, and the
        // flanger's notches ARE the odd-harmonic comb.
        let parkedDelayMs = FlangerParams.sweptDelayMs(phaseRadians: 0, delayMs: 2.0,
                                                       depthMs: 0.1)
        for index in 0..<min(4, flangerNotches.count) {
            let predicted = FlangerParams.combNotchHz(delayMs: parkedDelayMs, index: index)
            #expect(abs(flangerNotches[index] - predicted) / predicted < 0.02,
                    "flanger notch \(index) measured \(flangerNotches[index]) vs comb law \(predicted) — if THIS fails, the finder is broken and nothing above is evidence")
            #expect(abs(flangerRatios[index] - Double(2 * index + 1)) < 0.05)
        }

        // (4) the flanger does NOT fit the phaser law
        for index in 1..<min(4, flangerNotches.count) {
            let phaserRatio = PhaserParams.notchRatio(stages: 8, index: index)
                / PhaserParams.notchRatio(stages: 8, index: 0)
            let error = abs(flangerRatios[index] - phaserRatio) / phaserRatio
            print("[measured] flanger ratio \(index): \(flangerRatios[index]) vs phaser law \(phaserRatio) — \(error * 100) % off")
            #expect(error > 0.10,
                    "the flanger's notch \(index) sits within 10 % of the phaser ratio law — the two laws are not discriminating")
        }
    }

    // MARK: - L5: the feedback, measured as a steady-state gain

    private func measuredDCGain(feedback: Double, mix: Double) throws -> Double {
        // An all-pass chain has gain +1 at DC, so a constant input settles at
        // `(1-mix) + mix/(1-feedback)`. 24 576 frames is long enough for the
        // slowest section (0.96 pole) to settle by orders of magnitude.
        let frames = 24_576
        let out = try phase(parked(centerHz: 300, stages: 8, feedback: feedback, mix: mix),
                            constant(0.25, frames: frames))
        return mean(out, in: (frames - 4_096)..<frames) / 0.25
    }

    @Test("L5a — DC gain at the defaults is (1-mix) + mix/(1-feedback) = 1.5")
    func dcGainAtDefaultsMatchesTheClosedForm() throws {
        let measured = try measuredDCGain(feedback: 0.5, mix: 0.5)
        let expected = PhaserParams.dcGain(feedback: 0.5, mix: 0.5)
        print("[measured] L5a DC gain \(measured) vs closed form \(expected)")
        #expect(abs(measured - expected) < 0.02)
    }

    @Test("L5b — feedback 0 gives exactly unity, which every other leg assumes")
    func dcGainWithoutFeedbackIsUnity() throws {
        let measured = try measuredDCGain(feedback: 0, mix: 0.5)
        print("[measured] L5b DC gain at feedback 0: \(measured)")
        #expect(abs(measured - 1) < 0.01)
    }

    /// ⛔ THE ONLY LEG THAT SEES AN INVERTED FEEDBACK SIGN. −0.5 and +0.5 give
    /// the same |response| shape and the same notch positions, so every spectral
    /// leg above is blind to the sign; the DC gains are 0.833 and 1.5.
    @Test("L5c — NEGATIVE feedback gives 0.833, not 1.5: the sign is wired, not just the value")
    func dcGainWithNegativeFeedbackIsBelowUnity() throws {
        let measured = try measuredDCGain(feedback: -0.5, mix: 0.5)
        let expected = PhaserParams.dcGain(feedback: -0.5, mix: 0.5)
        print("[measured] L5c DC gain at feedback -0.5: \(measured) vs \(expected)")
        #expect(abs(measured - expected) < 0.02)
        #expect(measured < 1)
    }

    @Test("L5d — heavy feedback (0.9) gives 5.5, which is the level warning the note makes")
    func dcGainWithHeavyFeedbackMatchesTheClosedForm() throws {
        let measured = try measuredDCGain(feedback: 0.9, mix: 0.5)
        let expected = PhaserParams.dcGain(feedback: 0.9, mix: 0.5)
        print("[measured] L5d DC gain at feedback 0.9: \(measured) vs \(expected)")
        #expect(abs(measured - expected) / expected < 0.03)
    }

    // MARK: - L6: the PER-SECTION denormal flush

    /// ⛔ **THE OBLIGATION THAT IS NOT THE FLANGER'S.** The flanger owns ONE
    /// recirculating word; every first-order all-pass here is its own IIR with a
    /// pole at |a|, so each decays into subnormals on silence INDEPENDENTLY —
    /// **including at feedback 0**, which is the case a flanger-shaped flush
    /// would leave uncovered. Both are rendered.
    /// ⚠️⚠️ **THE OUTPUT-ONLY FORM OF THIS LEG WAS BLIND, AND IT WAS MEASURED
    /// BLIND RATHER THAN SUSPECTED.** The first version asserted only "no
    /// OUTPUT sample is subnormal" — the `FlangerTests` L6 shape, which is
    /// correct THERE because the flanger's one recirculating word IS its
    /// output. Planting the deletion of every per-section flush left all 35
    /// phaser tests GREEN: the chain output is flushed separately, so it never
    /// carries a subnormal regardless of what the sections hold, and an
    /// output-only assertion cannot fail. The leg now reads the SECTION STATE
    /// through `subnormalSectionStateCount`, polled once per quantum across the
    /// whole tail, because a single reading at the end can miss the band
    /// entirely — the state decays THROUGH subnormal territory and out the
    /// other side to hard zero.
    @Test("L6 — no section STATE is subnormal across a decaying tail, at feedback 0 AND 0.9")
    func sectionTailsAreDenormalFlushed() throws {
        for feedback in [0.0, 0.9] {
            let burst = 2_048
            let tail = 40_960
            var input = sine(300, amplitude: 0.9, frames: burst)
            input.append(contentsOf: [Float](repeating: 0, count: tail))
            // 20 Hz puts the slowest pole at 0.9974 — the worst-case decay, and
            // the one that actually reaches subnormal territory.
            // 20 Hz is the slowest pole the surface offers (a = -0.99739), so
            // an unflushed state decays through the subnormal band somewhere
            // around sample 33 500 and underflows to hard zero near 41 300 —
            // which is exactly why this polls EVERY quantum instead of looking
            // once at the end.
            let effect = PhaserEffect(
                params: PhaserParams(rateHz: 0.02, centerHz: 20, depthOctaves: 0,
                                     stages: 12, feedback: feedback, mix: 1.0))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 2)
            var subnormalStateQuanta = 0
            var sawNormalState = false
            var sawZeroState = false
            let out = try processChunked(effect, channels: [input, input], chunk: 512) { fx, _ in
                guard let phaser = fx as? PhaserEffect else { return }
                if phaser.subnormalSectionStateCount > 0 { subnormalStateQuanta += 1 }
                let peak = phaser.peakAbsoluteSectionState
                if peak.isNormal { sawNormalState = true }
                if peak == 0 { sawZeroState = true }
            }
            var subnormals = 0
            var nonZeroInTail = 0
            for channel in out {
                for index in burst..<channel.count {
                    let value = channel[index]
                    if value != 0 && !value.isNormal { subnormals += 1 }
                    if value != 0 { nonZeroInTail += 1 }
                }
            }
            print("[measured] L6 feedback \(feedback): \(subnormalStateQuanta) quanta with a "
                  + "subnormal SECTION STATE, \(subnormals) subnormal output samples, "
                  + "\(nonZeroInTail) non-zero tail samples, "
                  + "sawNormal=\(sawNormalState) sawZero=\(sawZeroState)")
            // ⭐ THE LOAD-BEARING ASSERTION — the one the output-only form could
            // not make.
            #expect(subnormalStateQuanta == 0,
                    "a section state went subnormal on \(subnormalStateQuanta) quanta — the per-section flush is missing")
            #expect(subnormals == 0)
            // NON-VACUITY, three ways. A chain that never rang, or one that was
            // already at hard zero before the tail began, would report zero
            // subnormals for reasons that have nothing to do with flushing.
            #expect(nonZeroInTail > 1_000,
                    "the tail is empty, so 'no subnormals' is not evidence of anything")
            #expect(sawNormalState,
                    "the section state was never normal, so it never had anywhere to decay FROM")
            #expect(sawZeroState,
                    "the section state never reached zero, so the tail never decayed far enough to enter the subnormal band at all")
        }
    }

    // MARK: - L7: the LFO actually moves the notches

    /// Every other leg renders at `depthOctaves: 0` so its measurement is of an
    /// LTI system. This is the one that MOVES, and it is what a frozen LFO
    /// fails: a fixed probe tone's envelope must both peak and null as a notch
    /// sweeps across it.
    @Test("L7 — the sweep moves: a fixed probe tone's envelope both peaks and nulls")
    func theLFOSweepsTheNotchesAcrossTheProbe() throws {
        let frames = 96_000  // two seconds, i.e. two full 1 Hz LFO cycles
        let probe = sine(600, amplitude: 0.8, frames: frames)
        let out = try phase(PhaserParams(rateHz: 1.0, centerHz: 120, depthOctaves: 3,
                                          stages: 8, feedback: 0.6, mix: 0.5), probe)
        // Envelope over 1024-frame windows.
        var peaks: [Double] = []
        var index = 8_192
        while index + 1_024 <= frames {
            var maxValue = 0.0
            for offset in 0..<1_024 { maxValue = max(maxValue, abs(Double(out[index + offset]))) }
            peaks.append(maxValue)
            index += 1_024
        }
        let high = peaks.max() ?? 0
        let low = peaks.min() ?? 0
        print("[measured] L7 probe envelope: \(low) … \(high), swing \(dB(high / max(low, 1e-12))) dB")
        #expect(high > 0.5)
        #expect(low < 0.25)
        #expect(dB(high / max(low, 1e-12)) > 8)

        // POSITIVE CONTROL: the SAME settings with the sweep frozen give a
        // near-constant envelope, so the swing above is the LFO and not the
        // material.
        let frozen = try phase(PhaserParams(rateHz: 1.0, centerHz: 120, depthOctaves: 0,
                                             stages: 8, feedback: 0.6, mix: 0.5), probe)
        var frozenPeaks: [Double] = []
        index = 8_192
        while index + 1_024 <= frames {
            var maxValue = 0.0
            for offset in 0..<1_024 {
                maxValue = max(maxValue, abs(Double(frozen[index + offset])))
            }
            frozenPeaks.append(maxValue)
            index += 1_024
        }
        let frozenSwing = dB((frozenPeaks.max() ?? 1) / max(frozenPeaks.min() ?? 1, 1e-12))
        print("[measured] L7 frozen-sweep envelope swing: \(frozenSwing) dB")
        #expect(frozenSwing < 1.0)
    }

    // MARK: - L8: stereo

    @Test("L8a — stereoPhaseDeg 0 renders the two channels identically, bit for bit")
    func zeroStereoPhaseIsMonoSafe() throws {
        let input = sine(330, amplitude: 0.6, frames: 8_192)
        let (left, right) = try phaseStereo(
            PhaserParams(rateHz: 2, centerHz: 300, depthOctaves: 3, stages: 8,
                         feedback: 0.5, mix: 0.5, stereoPhaseDeg: 0),
            left: input, right: input)
        #expect(left == right)
    }

    @Test("L8b — stereoPhaseDeg 180 makes the two channels differ, and audibly")
    func stereoPhaseSeparatesTheChannels() throws {
        let input = sine(330, amplitude: 0.6, frames: 8_192)
        let (left, right) = try phaseStereo(
            PhaserParams(rateHz: 2, centerHz: 300, depthOctaves: 3, stages: 8,
                         feedback: 0.5, mix: 0.5, stereoPhaseDeg: 180),
            left: input, right: input)
        #expect(left != right)
        var maxDiff = 0.0
        for index in 0..<left.count {
            maxDiff = max(maxDiff, abs(Double(left[index] - right[index])))
        }
        print("[measured] L8b max L/R difference at 180 deg: \(maxDiff)")
        #expect(maxDiff > 0.1)
    }

    // MARK: - L9: the automation slot map (§12 gate 3's render-side half)

    /// ⛔ SLOT ORDER IS `EffectParamSpec.specs(for: .phaser)`: 0 rateHz,
    /// 1 centerHz, 2 depthOctaves, 3 stages, 4 feedback, 5 mix,
    /// 6 stereoPhaseDeg. A transposition here re-points every saved lane, so
    /// each slot is driven to a value whose EFFECT is distinguishable.
    @Test("L9 — storeAutomatedParam drives the RIGHT parameter per slot")
    func automationSlotsAreWiredToTheRightParameters() throws {
        let input = sine(500, amplitude: 0.7, frames: 8_192)

        func automated(slot: Int, value: Double) throws -> [Float] {
            let effect = PhaserEffect(params: parked(centerHz: 300, stages: 8,
                                                      feedback: 0.4, mix: 0.5))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 1)
            return try processChunked(effect, channels: [input], chunk: 512) { fx, _ in
                fx.storeAutomatedParam(slot: slot, value: value)
            }[0]
        }

        // Slot 5 = mix. Driving it to 0 is the BIT-EXACT bypass — no other slot
        // can produce that, so this pins slot 5 uniquely and exactly.
        #expect(try automated(slot: 5, value: 0) == input)

        // Slot 3 = stages. Driving it to 4 must change the NOTCH COUNT of the
        // rendered impulse response from 4 to 2 — a structural signature no
        // other slot produces.
        func automatedIR(slot: Int, value: Double) throws -> [Float] {
            let effect = PhaserEffect(params: parked(centerHz: 150, stages: 8))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 1)
            return try processChunked(effect, channels: [impulse(frames: Self.irFrames)],
                                      chunk: 512) { fx, _ in
                fx.storeAutomatedParam(slot: slot, value: value)
            }[0]
        }
        let fourStages = findNotches(try automatedIR(slot: 3, value: 4), lo: 15, hi: 8_000)
        print("[measured] L9 slot 3 -> stages 4: \(fourStages.count) notches at \(fourStages)")
        #expect(fourStages.count == 2)
        // Non-vacuity: the un-automated fixture has 4.
        #expect(findNotches(try phase(parked(centerHz: 150, stages: 8),
                                      impulse(frames: Self.irFrames)),
                            lo: 15, hi: 8_000).count == 4)

        // Slot 1 = centerHz. Driving it to 700 must MOVE the notches, and to
        // where `notchHz` says for 700 — not merely somewhere else.
        let moved = findNotches(try automatedIR(slot: 1, value: 700), lo: 15, hi: 11_500)
        let predicted = PhaserParams.notchHz(cornerHz: 700, stages: 8, index: 0,
                                             sampleRate: Self.sampleRate)
        print("[measured] L9 slot 1 -> centre 700: first notch \(moved.first ?? -1) vs \(predicted)")
        #expect(moved.isEmpty == false)
        #expect(abs((moved[0]) - predicted) / predicted < 0.03)

        // Slot 4 = feedback. Its signature is the DC gain, which no spectral
        // slot moves in the same way.
        let effect = PhaserEffect(params: parked(centerHz: 300, stages: 8,
                                                  feedback: 0, mix: 0.5))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let steady = try processChunked(effect, channels: [constant(0.25, frames: 24_576)],
                                        chunk: 512) { fx, _ in
            fx.storeAutomatedParam(slot: 4, value: 0.5)
        }[0]
        let gain = mean(steady, in: 20_480..<24_576) / 0.25
        print("[measured] L9 slot 4 -> feedback 0.5: DC gain \(gain)")
        #expect(abs(gain - 1.5) < 0.03)

        // Every slot does SOMETHING different: the six audio-affecting slots
        // produce six distinct renders. (Slot 6 needs stereo to show, so it is
        // covered by L8 instead and excluded here.)
        let renders = [
            try automated(slot: 0, value: 8),
            try automated(slot: 1, value: 900),
            try automated(slot: 2, value: 4),
            try automated(slot: 3, value: 2),
            try automated(slot: 4, value: -0.9),
            try automated(slot: 5, value: 1),
        ]
        for i in 0..<renders.count {
            for j in (i + 1)..<renders.count {
                #expect(renders[i] != renders[j], "slots \(i) and \(j) render identically")
            }
        }
    }

    // MARK: - L10: the stage-count change clears stale state

    /// ⚠️ Sections above the count stop being VISITED, so their state freezes
    /// rather than decaying. Splicing a frozen value back in would click. The
    /// derive clears all sections when the count changes; this proves the
    /// cleared chain is the one that renders, by driving the count down and back
    /// up under a LOUD signal and asserting the result stays bounded and finite.
    @Test("L10 — a stage-count change clears state: no stale splice, no blow-up")
    func stageCountChangeClearsState() throws {
        let frames = 24_576
        let input = sine(220, amplitude: 0.95, frames: frames)
        let effect = PhaserEffect(params: PhaserParams(rateHz: 0.5, centerHz: 300,
                                                        depthOctaves: 2, stages: 12,
                                                        feedback: 0.9, mix: 1.0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let out = try processChunked(effect, channels: [input], chunk: 512) { fx, quantum in
            // Ramp the count down to 2 and back up to 12, repeatedly.
            let counts: [Double] = [12, 8, 4, 2, 4, 8, 12]
            fx.storeAutomatedParam(slot: 3, value: counts[quantum % counts.count])
        }[0]
        var peak: Float = 0
        for value in out {
            #expect(value.isFinite)
            peak = max(peak, abs(value))
        }
        print("[measured] L10 peak under a thrashing stage count at feedback 0.9: \(peak)")
        #expect(peak < 60, "a stale section spliced back in has run away")
        #expect(peak > 0.1, "the render went silent — this leg would then prove nothing")
    }

    // MARK: - L11: the contract every insert owes the graph

    @Test("L11a — latencySamples is 0 (rule 6.0.9) and two renders are bit-identical")
    func reportsNoLatencyAndIsDeterministic() throws {
        let params = PhaserParams(rateHz: 3, centerHz: 250, depthOctaves: 2.5, stages: 10,
                                  feedback: 0.7, mix: 0.6, stereoPhaseDeg: 120)
        let effect = PhaserEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(effect.latencySamples == 0)
        let input = sine(180, amplitude: 0.8, frames: 16_384)
        let first = try phaseStereo(params, left: input, right: input)
        let second = try phaseStereo(params, left: input, right: input)
        #expect(first.left == second.left)
        #expect(first.right == second.right)
    }

    @Test("L11b — hostile finite input stays finite: no NaN, no inf, bounded output")
    func survivesHostileFiniteInput() throws {
        var input = [Float](repeating: 0, count: 16_384)
        for index in 0..<input.count {
            // Full-scale alternating impulses plus DC — the worst case for a
            // recirculating structure at maximum feedback.
            input[index] = index % 2 == 0 ? 1.0 : -1.0
            if index % 97 == 0 { input[index] = 1.0 }
        }
        let out = try phase(PhaserParams(rateHz: 10, centerHz: 20, depthOctaves: 4,
                                          stages: 12, feedback: 0.95, mix: 1.0), input)
        var peak: Float = 0
        for value in out {
            #expect(value.isFinite)
            peak = max(peak, abs(value))
        }
        print("[measured] L11b peak under a full-scale hostile input at feedback 0.95: \(peak)")
        #expect(peak < 200)
    }

    @Test("L11c — reset() clears the tail: the chain is silent again afterwards")
    func resetClearsTheChain() throws {
        let effect = PhaserEffect(params: PhaserParams(rateHz: 0.02, centerHz: 300,
                                                        depthOctaves: 0, stages: 12,
                                                        feedback: 0.9, mix: 1.0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        _ = try processChunked(effect, channels: [sine(300, amplitude: 0.9, frames: 8_192)],
                               chunk: 512)
        // Non-vacuity control: WITHOUT the reset the chain is still ringing.
        let ringing = try processChunked(effect, channels: [constant(0, frames: 2_048)],
                                         chunk: 512)[0]
        var ringingPeak: Float = 0
        for value in ringing { ringingPeak = max(ringingPeak, abs(value)) }
        #expect(ringingPeak > 0.01, "nothing was ringing, so the reset proves nothing")

        effect.reset()
        let afterReset = try processChunked(effect, channels: [constant(0, frames: 2_048)],
                                            chunk: 512)[0]
        print("[measured] L11c ringing before reset \(ringingPeak), after reset "
              + "\(afterReset.map { abs($0) }.max() ?? 0)")
        #expect(afterReset.allSatisfy { $0 == 0 })
    }

    // MARK: - L12: the internal smoothing rule 6.0.6 makes mandatory

    /// ⚠️ **THE FIXTURE TRAP, NAMED: `mix == 0.5` MAKES `dryGain == mixGain`**,
    /// so a dry/wet swap is invisible there. This leg ramps to 0.3, where the
    /// two differ, and the previous value is 0.9.
    @Test("L12 — an automated mix jump RAMPS across the quantum, it does not step")
    func mixIsInterpolatedPerSample() throws {
        let frames = 4_096
        let input = sine(500, amplitude: 0.8, frames: frames)
        let effect = PhaserEffect(params: PhaserParams(rateHz: 0.02, centerHz: 300,
                                                        depthOctaves: 0, stages: 8,
                                                        feedback: 0.7, mix: 0.9))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let jumpQuantum = 4
        let out = try processChunked(effect, channels: [input], chunk: 512) { fx, quantum in
            if quantum >= jumpQuantum { fx.storeAutomatedParam(slot: 5, value: 0.3) }
        }[0]
        // The largest sample-to-sample step inside the jump quantum must be no
        // worse than in a steady one. A per-quantum step would show a single
        // discontinuity at the boundary.
        func maxStep(_ range: Range<Int>) -> Double {
            var worst = 0.0
            for index in range.dropFirst() {
                worst = max(worst, abs(Double(out[index] - out[index - 1])))
            }
            return worst
        }
        let atJump = maxStep((jumpQuantum * 512 - 2)..<(jumpQuantum * 512 + 512))
        let steady = maxStep((jumpQuantum * 512 + 512)..<(jumpQuantum * 512 + 1_024))
        print("[measured] L12 max step across the jump \(atJump) vs steady \(steady)")
        #expect(atJump < steady * 1.6,
                "the mix jump stepped rather than ramping — rule 6.0.6's smoothing is missing")
        // Non-vacuity: the mix really did move, so a no-op would not pass.
        let before = maxStep(1_024..<1_536)
        print("[measured] L12 pre-jump step scale \(before)")
        #expect(abs(before - steady) > 1e-6)
    }

    // MARK: - L13: the mix-0.5 null depth, and what mix 1 honestly does

    /// The `mix` note claims two things that can be measured: the notches are
    /// DEEPEST at 0.5, and at mix 1 with feedback 0 the effect is an all-pass —
    /// i.e. it changes no frequency's LEVEL at all. That second claim is the
    /// honest "this can sound like nothing is happening" warning, and it would
    /// be a bug report if it were not documented.
    @Test("L13 — notches are deepest at mix 0.5; mix 1 at feedback 0 is flat by measurement")
    func mixShapesTheNullDepthAndMixOneIsFlat() throws {
        let notch = PhaserParams.notchHz(cornerHz: 300, stages: 8, index: 1,
                                         sampleRate: Self.sampleRate)
        var depths: [Double: Double] = [:]
        for mix in [0.25, 0.5, 0.75] {
            let ir = try phase(parked(centerHz: 300, stages: 8, mix: mix),
                               impulse(frames: Self.irFrames))
            depths[mix] = dB(magnitude(ir, at: notch))
        }
        print("[measured] L13 null depth at \(notch) Hz by mix: \(depths)")
        #expect(depths[0.5]! < depths[0.25]! - 20)
        #expect(depths[0.5]! < depths[0.75]! - 20)

        // mix 1, feedback 0: an all-pass chain alone. Flat magnitude everywhere.
        let allPass = try phase(parked(centerHz: 300, stages: 8, feedback: 0, mix: 1),
                                impulse(frames: Self.irFrames))
        var worst = 0.0
        for probe in [60.0, 150, 300, 700, 1_500, 4_000, 9_000] {
            worst = max(worst, abs(dB(magnitude(allPass, at: probe))))
        }
        print("[measured] L13 all-pass flatness at mix 1 / feedback 0: \(worst) dB")
        #expect(worst < 0.1, "an all-pass chain must not change any frequency's level")
    }

    // MARK: - L14: the coefficient is INTERPOLATED, not stepped every 32 frames

    /// ⚠️⚠️ **EVERY OTHER SPECTRAL LEG IN THIS FILE RENDERS AT
    /// `depthOctaves: 0`, WHERE THE COEFFICIENT NEVER MOVES** — so none of them
    /// can see whether the 32-frame coefficient stride (rule 6.0.6) is
    /// interpolated per sample or slammed at each block boundary. That is
    /// exactly the shape this tree calls a structurally blind assertion, and it
    /// is why this leg exists as a separate measurement rather than a comment.
    ///
    /// ⭐ THE INSTRUMENT: a block-rate STEP is periodic at `fs / 32` = 1500 Hz,
    /// so it does not spray energy at random — it puts it at the carrier ±
    /// multiples of exactly 1500 Hz. Rendering at `mix: 1, feedback: 0` makes
    /// the IDEAL system a pure all-pass (measured flat to 1.2e-05 dB by L13),
    /// so any magnitude at those offsets is the update artifact and nothing
    /// else. The sweep is run at the FASTEST and DEEPEST the surface allows
    /// (`rateHz: 10`, `depthOctaves: 4`, `centerHz: 1000`, corner 1 kHz →
    /// 16 kHz), which is where the per-block coefficient jump is largest.
    ///
    /// ⭐ THE ASSERTION IS SELF-NORMALISING: the stride offset is compared with
    /// NEIGHBOURING offsets that carry the same sweep sidebands but no stride
    /// component. An absolute threshold would be a number tuned to today's
    /// level; this one asks whether 1500 Hz is SPECIAL, which is the actual
    /// question.
    // ⚠️ THE NAME SAYS "ARTIFACT CEILING", NOT "NO LINE AT fs/32", AND THE
    // FIRST NAME WAS THE SECOND ONE. There IS a line at fs/32 with the
    // CORRECT code — −77.8 dB of it. A test named for an absence its own
    // measurement refutes is this tree's characteristic failure in miniature.
    @Test("L14 — the 32-frame coefficient stride is interpolated: block-rate artifact ceiling below -65 dB")
    func coefficientUpdatesAreInterpolatedNotStepped() throws {
        let frames = 24_576
        let carrier = 997.0
        let stride = Self.sampleRate / 32  // 1 500 Hz
        let input = sine(carrier, amplitude: 0.8, frames: frames)
        // Fastest, deepest sweep the ranges allow — the worst case for a
        // stepped coefficient — with the ideal response flat.
        let out = try phase(PhaserParams(rateHz: 10, centerHz: 1_000, depthOctaves: 4,
                                         stages: 8, feedback: 0, mix: 1,
                                         stereoPhaseDeg: 0), input)

        // Hann-windowed DTFT: a rectangular window's leakage from an 0.8
        // carrier would swamp everything measured below.
        func line(_ hz: Double, of samples: [Float]) -> Double {
            let w = 2.0 * Double.pi * hz / Self.sampleRate
            var re = 0.0, im = 0.0
            var index = 0
            while index < samples.count {
                let hann = 0.5 - 0.5 * cos(2.0 * Double.pi * Double(index)
                                           / Double(samples.count - 1))
                let value = Double(samples[index]) * hann
                re += value * cos(w * Double(index))
                im -= value * sin(w * Double(index))
                index += 1
            }
            return (re * re + im * im).squareRoot()
        }
        func line(_ hz: Double) -> Double { line(hz, of: out) }

        let carrierLevel = line(carrier)
        #expect(carrierLevel > 0, "the probe measured silence")
        func relative(_ hz: Double) -> Double { dB(line(hz) / carrierLevel) }

        // ⚠️⚠️ **THE LINE AT EXACTLY `fs/32` IS NOT THE DISCRIMINATING
        // MEASUREMENT, AND ASSUMING IT WAS COST A RUN.** Measured both ways by
        // planting the step: the upper stride line at 997+1500 Hz reads
        // −77.8 dB interpolated and −73.6 dB stepped — **FOUR dB apart**, which
        // no honest threshold separates. The reason is that the artifact is not
        // one clean line: the sweep is itself moving at 10 Hz, so the stepping
        // energy lands on a CLUSTER around `f0 ± k·fs/32`, and a probe aimed at
        // the exact centre can sit in a null of it. 9 Hz away, at 2506 Hz, the
        // same two renders read −80.6 dB and −44.9 dB. Both stride lines are
        // still printed because they are the cheapest hint at WHY a failure
        // happened, but they are evidence, not the gate.
        let strideUpper = relative(carrier + stride)
        let strideLower = relative(abs(carrier - stride))

        // The artifact band: from well above the carrier and its sweep
        // sidebands, up to 20 kHz. At `mix 1 / feedback 0` the ideal system is
        // an all-pass, so EVERY one of these is artifact and nothing else.
        var profile: [(Double, Double)] = []
        var worstHz = 0.0
        var worst = -Double.infinity
        var probe = 1_800.0
        while probe < 20_000 {
            let level = relative(probe)
            profile.append((probe, level))
            if level > worst { worst = level; worstHz = probe }
            probe *= 1.18
        }
        print("""
              [measured] L14 stride lines: upper \(strideUpper) dB, lower \
              \(strideLower) dB — NOT the gate. Artifact floor: worst \(worst) \
              dB at \(worstHz) Hz over \(profile.count) probes. Profile: \
              \(profile.map { ("\(Int($0.0)) Hz", (($0.1) * 10).rounded() / 10) })
              """)
        // ⭐ THE THRESHOLD SITS BETWEEN TWO MEASURED NUMBERS rather than being
        // invented. Worst probe over this grid: **−80.6 dB with the shipped
        // per-sample interpolation, −44.9 dB with it planted out** (both at
        // 2506 Hz), a 35.7 dB separation. −65 dB leaves 15.6 dB of headroom
        // above what the shipped code does and 20.1 dB below what the defect
        // does. The arithmetic is deterministic, so these numbers reproduce.
        #expect(worst < -65,
                "the modulation artifact floor is \(worst) dB at \(worstHz) Hz — the 32-frame coefficient is being stepped at the block boundary, not interpolated per sample")

        // NON-VACUITY, TWO WAYS. (1) The sweep really ran, so this is not a
        // measurement of a frozen system in which every offset is equally
        // empty — at 10 Hz the sweep puts real sidebands beside the carrier.
        let sweepSideband = relative(carrier + 10)
        print("[measured] L14 sweep sideband at carrier+10 Hz: \(sweepSideband) dB")
        #expect(sweepSideband > worst + 40,
                "the LFO did not modulate — this leg measured a frozen system")
        // (2) POSITIVE CONTROL ON THE PROBE ITSELF. Every number above is a
        // very small one, and a `line()` that silently read zero inside the
        // artifact band would produce the same green. So the SAME function is
        // run at 4 kHz — deep inside that band — over a signal that certainly
        // has content there, and must come back loud.
        let controlLevel = dB(line(4_000, of: sine(4_000, amplitude: 0.5, frames: frames))
                              / carrierLevel)
        print("[measured] L14 probe control: a real 4 kHz tone reads \(controlLevel) dB")
        #expect(controlLevel > -20,
                "the probe cannot see a tone it is pointed at — every artifact reading above is worthless")
    }

    // MARK: - L15: the render path allocates NOTHING (§12 gate 2, absolute zero)

    // The hook, the counter cells and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe): one measurement at a time.

    @Test("L15 — process() allocates NOTHING across 4 000 quanta, and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
            return
        }
        let quantum = 512
        let calls = 4_000
        // Everything switched ON: the LONGEST chain (12 sections, the deepest
        // per-sample loop), a live sweep so the 32-frame coefficient derive
        // runs, feedback so the recirculation path is live, and a stereo phase
        // offset so the right channel's coefficient is derived separately.
        let effect = PhaserEffect(params: PhaserParams(
            rateHz: 6, centerHz: 400, depthOctaves: 4, stages: 12,
            feedback: 0.8, mix: 0.5, stereoPhaseDeg: 90))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                       channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let data = try #require(buffer.floatChannelData)
        for frame in 0..<quantum {
            let t = Double(frame) / Self.sampleRate
            let value = Float(0.4 * sin(2.0 * .pi * 110 * t) + 0.3 * sin(2.0 * .pi * 2_700 * t))
            data[0][frame] = value
            data[1][frame] = value
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        // ⚠️⚠️ **THE BUFFER IS RE-STAGED EVERY CALL, AND THAT IS NOT TIDINESS.**
        // `process` works IN PLACE, so re-processing one staged chunk 4 000
        // times feeds the effect its own output. At `mix 0.5 / feedback 0.8`
        // this kind's DC gain is `(1−mix) + mix/(1−feedback)` = **3.0**, so the
        // signal grows 3× per pass and reaches `inf`, then `NaN`, long before
        // call 4 000. MEASURED: the first version of this leg reported
        // `sum → nan` — and note what that means, because it is the whole
        // lesson: the allocation count was a clean **0** the entire time. A
        // probe measuring a NaN render is measuring nothing, and it says so in
        // the same green tone as a probe measuring a real one. (The
        // `InsertSpectrumChain` gate avoids this by rendering unity gain; this
        // kind has no unity-gain setting that also exercises feedback.)
        let source = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
        defer { source.deallocate() }
        for frame in 0..<quantum { source[frame] = data[0][frame] }

        var sum: Float = 0
        let events = MallocProbe.events(slot: slot) {
            var call = 0
            while call < calls {
                // `while`, not `for … in`, for the reason the header records:
                // a `Range` iteration inside the measured window would raise
                // the harness's own allocations.
                var frame = 0
                while frame < quantum {
                    data[0][frame] = source[frame]
                    data[1][frame] = source[frame]
                    frame &+= 1
                }
                // The automation store is on the same render thread and is part
                // of the contract, so it is inside the probe — including
                // `stages` (slot 3), whose derive runs the even-snap and, when
                // the count actually changes, clears the section state.
                effect.storeAutomatedParam(slot: 1, value: 100 + Double(call % 30) * 30)
                effect.storeAutomatedParam(slot: 3, value: Double(4 + (call % 5) * 2))
                effect.process(buffers: list, frameCount: quantum)
                sum += data[0][quantum - 1]
                call += 1
            }
        }
        print("[measured] m39-o phaser render allocation events over \(calls) quanta: \(events)")
        #expect(events == 0, "process() raised \(events) malloc/free events")
        // NON-VACUITY: the probe measured a render that actually happened.
        #expect(sum != 0, "the probe ran over a silent/no-op render")
        #expect(sum.isFinite)
    }

    @Test("L15b — POSITIVE CONTROL: the malloc probe can actually count")
    func theAllocationProbeCanSeeAnAllocation() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⭐ A zero from a probe that never fires and a zero from a render that
        // never allocates are the same number. This makes the probe report a
        // non-zero on work that certainly allocates.
        var sink: [[Int]] = []
        let events = MallocProbe.events(slot: slot) {
            var index = 0
            while index < 200 {
                sink.append([Int](repeating: index, count: 64))
                index += 1
            }
        }
        #expect(events > 0, "the malloc probe counted \(events) events on 200 array allocations")
        #expect(sink.count == 200)
    }
}
