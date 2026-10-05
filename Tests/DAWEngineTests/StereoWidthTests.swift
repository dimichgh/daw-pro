import AVFAudio
import Darwin
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `TapeDelayTests`, `FlangerTests`, `RingModTests`, `DJFilterTests` and
// `BitCrusherTests` all record: the main actor is ONE serialization point for
// the whole test process, these tests render hundreds of thousands of frames of
// audio, and they need no main-actor state at all. (There is also a hard
// structural reason: `MainActorOccupancySiteTests` Leg C pins the
// `@MainActor`-isolated SUITE count at its cap with ZERO slack, so a new
// isolated suite would redden a gate in a different target — and spelling
// `@MainActor` per-test to dodge that gate is what the gate itself names as
// instrument-silencing.)
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m23-dj — the `.stereoWidth` insert. `docs/ROADMAP.md:1190` is the item, and
/// the item's own words set this suite's shape: *"MONO COMPATIBILITY IS THE
/// ACCEPTANCE TEST, NOT A NICE-TO-HAVE: sum the output to mono and assert the
/// level and spectrum against the dry input."*
///
/// ⭐⭐ **THE ORACLE HAS ITS OWN POSITIVE CONTROLS, AND THEY ARE THE POINT.**
/// This design satisfies mono compatibility BY CONSTRUCTION — it only ever
/// touches the side channel — which means a passing oracle proves almost
/// nothing on its own: an INERT effect would pass it too, and so would a
/// half-built one. So L1 runs the identical measurement over two widener
/// implementations written HERE, in the test, that the item names as wrong:
///
///  · **L1b — a Haas widener** (right channel delayed 15 ms). Widens on
///    speakers; the mono sum combs, with complete nulls at the odd multiples
///    of 33.33 Hz. The oracle must SEE that.
///  · **L1c — a "normalised" widener** that scales the mid by 1/√2 to keep the
///    channel level constant. This is the exact failure the item names —
///    *"a widener that loses 3 dB of vocal when summed"* — and it is invisible
///    to any test that only looks at the stereo output.
///
/// An oracle that cannot redden on those two is not measuring anything.
///
/// ⭐ Every other claim is MEASURED FROM RENDERED OUTPUT, never read back from
/// a parameter. The plausible wrong implementations separate:
///
///  · the whole effect inert / never wired      → L2, L3, L4, each of which
///    needs a specific number to MOVE by a specific amount
///  · `width` applied to the mid as well        → L1, which would then show a
///    level change in the mono sum
///  · the bass-mono crossover built as
///    `x - lowpass²(x)` instead of two cascaded
///    high-passes                               → L4a ONLY. Both are
///    "12 dB/oct-looking" code; they differ by 15.7 dB at 40 Hz and by
///    nothing at all above 1 kHz. This author shipped the wrong one first
///  · the neutral position writing the buffer   → L5a, with L5b as its
///    positive control so "bit-exact" cannot mean "inert"
///  · the decorrelator PAUSED at neutral        → L5c
///  · the per-sample interpolation deleted      → L6
///  · `previous* = target*` snapping removed    → L7, where the bypass never
///    re-engages after a ride. ⚠️ Deliberately uses 1.37, not 1.5: the
///    accumulation of a power-of-two delta is EXACT, so a round number would
///    make this leg pass with the snap gone
///  · a denormal flush removed                  → L8
///  · a slot mis-wired in `storeAutomatedParam` → L9
///  · an allocation on the render path          → L11
@Suite("Stereo width — mono-compatibility oracle, decorrelation, bass mono (m23-dj)", .serialized)
struct StereoWidthTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal helpers

    private func sine(_ frequency: Double, amplitude: Double, frames: Int,
                      phase: Double = 0) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate + phase))
        }
    }

    private func sum(_ parts: [[Float]]) -> [Float] {
        guard let first = parts.first else { return [] }
        var out = first
        for part in parts.dropFirst() {
            for index in 0..<out.count { out[index] += part[index] }
        }
        return out
    }

    /// Frequencies that live in the MID of `program`, i.e. the ones a mono
    /// fold-down actually carries.
    private static let midProbes = [110.0, 440.0, 1_200.0, 4_000.0]
    /// Frequencies that live in the SIDE, i.e. the ones a mono fold-down must
    /// carry NONE of, before or after.
    private static let sideProbes = [220.0, 700.0, 2_500.0]

    /// A realistic stereo program: shared centre content plus channel-specific
    /// content, built so `L + R` has real energy (a pure anti-phase fixture
    /// would make the oracle's denominator zero and its ratios meaningless).
    private func program(frames: Int) -> (left: [Float], right: [Float]) {
        let mid = sum([
            sine(110, amplitude: 0.25, frames: frames),
            sine(440, amplitude: 0.20, frames: frames, phase: 0.7),
            sine(1_200, amplitude: 0.15, frames: frames, phase: 1.9),
            sine(4_000, amplitude: 0.10, frames: frames, phase: 2.6),
        ])
        let side = sum([
            sine(220, amplitude: 0.12, frames: frames, phase: 0.3),
            sine(700, amplitude: 0.10, frames: frames, phase: 1.1),
            sine(2_500, amplitude: 0.08, frames: frames, phase: 2.2),
        ])
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            left[index] = mid[index] + side[index]
            right[index] = mid[index] - side[index]
        }
        return (left, right)
    }

    /// ⭐⭐ THE FIXTURE THAT MAKES A BIT-EXACTNESS CLAIM FALSIFIABLE, and it
    /// had to be found the hard way. One channel enormous, the other seven
    /// orders of magnitude down, so `0.5(L+R) ± 0.5(L−R)` genuinely destroys
    /// the small one: an implementation that COMPUTES the identity instead of
    /// skipping the write fails here and passes on anything balanced.
    ///
    /// ⚠️ **A PLANTED DEFECT REDDENED NOTHING UNTIL THIS EXISTED.** L7 first
    /// used the balanced `program()` fixture, and on balanced material the
    /// mid/side round trip happens to BE bit-exact — so removing the
    /// interpolation-endpoint snap (which leaves `width` at 0.9999999999999956
    /// forever, a value that is exactly 1.0 once narrowed to `Float`) changed
    /// not one byte. The gate could not fail. It can now.
    private func asymmetricProgram(frames: Int) -> (left: [Float], right: [Float]) {
        let loud = sine(300, amplitude: 0.9, frames: frames)
        let quiet = sine(2_100, amplitude: 1e-7, frames: frames)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            left[index] = quiet[index]
            right[index] = loud[index]
        }
        return (left, right)
    }

    private func impulse(at index: Int, frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        samples[index] = 1
        return samples
    }

    // MARK: - Measurement helpers

    private func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    private func rms(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        var total = 0.0
        for value in samples { total += value * value }
        return (total / Double(samples.count)).squareRoot()
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        guard !samples.isEmpty else { return 0 }
        var total = 0.0
        for value in samples { total += Double(value) * Double(value) }
        return (total / Double(samples.count)).squareRoot()
    }

    /// Goertzel single-bin AMPLITUDE estimate (the `TapeDelayTests` shape,
    /// widened to `[Double]` so a mono SUM can be measured without first
    /// rounding it back to `Float` — the residuals here live well below a
    /// `Float` ULP and rounding would destroy exactly what is being measured).
    private func goertzel(_ samples: [Double], frequency: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / Self.sampleRate
        let coeff = 2.0 * cos(w)
        var s1 = 0.0, s2 = 0.0
        for value in samples {
            let s0 = value + coeff * s1 - s2
            s2 = s1
            s1 = s0
        }
        let power = s1 * s1 + s2 * s2 - coeff * s1 * s2
        return max(power, 0).squareRoot() * 2.0 / Double(samples.count)
    }

    /// Raw DFT magnitude at one frequency — for IMPULSE RESPONSES, where the
    /// Goertzel amplitude scaling above (which assumes a steady sinusoid) is
    /// the wrong normalisation.
    private func dftMagnitude(_ samples: [Float], frequency: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / Self.sampleRate
        var re = 0.0, im = 0.0
        for (index, value) in samples.enumerated() {
            let angle = w * Double(index)
            re += Double(value) * cos(angle)
            im -= Double(value) * sin(angle)
        }
        return (re * re + im * im).squareRoot()
    }

    /// Pearson correlation between two channels — the `MasterMixAnalyzer`
    /// (m22-d) instrument, so the numbers here are the ones the UI shows.
    private func correlation(_ left: [Float], _ right: [Float]) -> Double {
        var lr = 0.0, ll = 0.0, rr = 0.0
        for index in 0..<min(left.count, right.count) {
            let l = Double(left[index]), r = Double(right[index])
            lr += l * r
            ll += l * l
            rr += r * r
        }
        let denominator = (ll * rr).squareRoot()
        return denominator > 0 ? lr / denominator : 1
    }

    /// `S² / (M² + S²)` — m22-d's stereo-width figure, 0 for a mono signal.
    private func widthFigure(_ left: [Float], _ right: [Float]) -> Double {
        var midEnergy = 0.0, sideEnergy = 0.0
        for index in 0..<min(left.count, right.count) {
            let m = (Double(left[index]) + Double(right[index])) * 0.5
            let s = (Double(left[index]) - Double(right[index])) * 0.5
            midEnergy += m * m
            sideEnergy += s * s
        }
        let total = midEnergy + sideEnergy
        return total > 0 ? sideEnergy / total : 0
    }

    // MARK: - ⭐⭐ THE ORACLE

    private struct MonoVerdict {
        /// Broadband level change of the mono fold-down, in dB.
        let levelDeltaDb: Double
        /// Worst per-frequency deviation of the fold-down, in dB, over the
        /// MID probes (the only ones a fold-down carries).
        let worstBandDeltaDb: Double
        /// Which probe produced it.
        let worstBandHz: Double
        /// RMS of (mono out − mono dry), relative to the dry INPUT rms.
        let residualDb: Double
        /// Largest side-only leak into the fold-down, absolute amplitude.
        let worstSideLeak: Double
        let perBand: [(hz: Double, deltaDb: Double)]
    }

    /// Sums both renders to mono and compares LEVEL and SPECTRUM, exactly as
    /// `m23-dj` demands. Used unchanged on the real effect and on the two
    /// deliberately-wrong wideners built below it.
    private func monoVerdict(dryL: [Float], dryR: [Float],
                             outL: [Float], outR: [Float]) -> MonoVerdict {
        let count = min(min(dryL.count, dryR.count), min(outL.count, outR.count))
        var dryMono = [Double](repeating: 0, count: count)
        var outMono = [Double](repeating: 0, count: count)
        var residual = [Double](repeating: 0, count: count)
        var dryInput = [Double](repeating: 0, count: count)
        for index in 0..<count {
            dryMono[index] = Double(dryL[index]) + Double(dryR[index])
            outMono[index] = Double(outL[index]) + Double(outR[index])
            residual[index] = outMono[index] - dryMono[index]
            dryInput[index] = Double(dryL[index])
        }
        var bands: [(hz: Double, deltaDb: Double)] = []
        var worst = 0.0, worstHz = 0.0
        for hz in Self.midProbes {
            let delta = dB(goertzel(outMono, frequency: hz))
                - dB(goertzel(dryMono, frequency: hz))
            bands.append((hz, delta))
            if abs(delta) > abs(worst) { worst = delta; worstHz = hz }
        }
        var leak = 0.0
        for hz in Self.sideProbes {
            leak = max(leak, goertzel(outMono, frequency: hz))
        }
        return MonoVerdict(
            levelDeltaDb: dB(rms(outMono)) - dB(rms(dryMono)),
            worstBandDeltaDb: worst, worstBandHz: worstHz,
            residualDb: dB(rms(residual)) - dB(rms(dryInput)),
            worstSideLeak: leak, perBand: bands)
    }

    // MARK: - Render helpers

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

    /// One stereo pass through a freshly prepared widener.
    private func widen(_ params: StereoWidthParams, _ left: [Float], _ right: [Float],
                       chunk: Int = 512,
                       poke: ((any EffectRendering, Int) -> Void)? = nil)
        throws -> (left: [Float], right: [Float]) {
        let effect = StereoWidthEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        #expect(effect.lastPrepareRefusal == nil,
                "a decorrelator line refused to prepare — every measurement below would be vacuous")
        let out = try processChunked(effect, channels: [left, right], chunk: chunk, poke: poke)
        return (out[0], out[1])
    }

    // MARK: - The two DELIBERATELY WRONG wideners the item names

    /// ⛔ A HAAS WIDENER — the cheap trick the item calls out first. Widens
    /// convincingly on speakers and combs in mono, with complete nulls at the
    /// odd multiples of 1/(2·15 ms) = 33.33 Hz.
    private func haasWiden(_ left: [Float], _ right: [Float], delayMs: Double = 15)
        -> (left: [Float], right: [Float]) {
        let delay = Int((delayMs * 0.001 * Self.sampleRate).rounded())
        var outR = [Float](repeating: 0, count: right.count)
        for index in 0..<right.count where index >= delay {
            outR[index] = right[index - delay]
        }
        return (left, outR)
    }

    /// ⛔ A "LEVEL-NORMALISED" WIDENER — scales the MID so the per-channel
    /// level stays constant as width rises. Sounds fine in stereo and loses
    /// 3.01 dB of centre the moment anything sums to mono: the item's exact
    /// *"loses 3 dB of vocal"* failure.
    private func normalisedWiden(_ left: [Float], _ right: [Float], width: Float = 1.6)
        -> (left: [Float], right: [Float]) {
        var outL = [Float](repeating: 0, count: left.count)
        var outR = [Float](repeating: 0, count: right.count)
        let midGain = Float(1.0 / 2.0.squareRoot())
        for index in 0..<left.count {
            let mid = (left[index] + right[index]) * 0.5
            let side = (left[index] - right[index]) * 0.5
            outL[index] = mid * midGain + side * width
            outR[index] = mid * midGain - side * width
        }
        return (outL, outR)
    }

    // MARK: - L1 — THE ACCEPTANCE TEST, AND THE TWO CONTROLS THAT MAKE IT REAL

    @Test("L1a: summed to mono, the widened output matches the dry input in LEVEL and SPECTRUM")
    func monoFoldDownIsUnchangedByConstruction() throws {
        let frames = 48_000
        let (dryL, dryR) = program(frames: frames)
        // Deliberately aggressive: wide, heavily decorrelated, bass fully
        // centred. If anything in this effect could break the fold-down, this
        // is the setting that would.
        let params = StereoWidthParams(width: 1.8, spread: 0.8,
                                       bassMonoHz: 200, bassMonoAmount: 1)
        let (outL, outR) = try widen(params, dryL, dryR)

        // It must actually have DONE something, or the fold-down is trivially
        // unchanged. This is the leg's own non-vacuity control.
        let dryWidth = widthFigure(dryL, dryR)
        let outWidth = widthFigure(outL, outR)
        print("[measured] m23-dj L1a width figure \(dryWidth) -> \(outWidth)")
        #expect(outWidth > dryWidth + 0.1,
                "the widener did not widen — the fold-down proof below would be vacuous")

        let verdict = monoVerdict(dryL: dryL, dryR: dryR, outL: outL, outR: outR)
        print("""
            [measured] m23-dj L1a mono fold-down — level \(verdict.levelDeltaDb) dB, \
            worst band \(verdict.worstBandDeltaDb) dB at \(verdict.worstBandHz) Hz, \
            residual \(verdict.residualDb) dB, side leak \(verdict.worstSideLeak)
            """)
        for band in verdict.perBand {
            print("[measured]   \(band.hz) Hz: \(band.deltaDb) dB")
        }
        #expect(abs(verdict.levelDeltaDb) < 0.005,
                "the mono fold-down changed level by \(verdict.levelDeltaDb) dB")
        #expect(abs(verdict.worstBandDeltaDb) < 0.02,
                "the mono fold-down changed \(verdict.worstBandDeltaDb) dB at \(verdict.worstBandHz) Hz")
        #expect(verdict.residualDb < -100,
                "the mono residual is \(verdict.residualDb) dB — float rounding alone is far below this")
        #expect(verdict.worstSideLeak < 1e-5,
                "side content leaked \(verdict.worstSideLeak) into the fold-down")
    }

    @Test("L1b POSITIVE CONTROL: the same oracle CATCHES a Haas widener collapsing in mono")
    func oracleCatchesAHaasWidener() throws {
        let frames = 48_000
        let (dryL, dryR) = program(frames: frames)
        let (outL, outR) = haasWiden(dryL, dryR)
        let verdict = monoVerdict(dryL: dryL, dryR: dryR, outL: outL, outR: outR)
        print("""
            [measured] m23-dj L1b HAAS control — level \(verdict.levelDeltaDb) dB, \
            worst band \(verdict.worstBandDeltaDb) dB at \(verdict.worstBandHz) Hz, \
            residual \(verdict.residualDb) dB
            """)
        for band in verdict.perBand {
            print("[measured]   \(band.hz) Hz: \(band.deltaDb) dB")
        }
        // ⭐ THIS IS WHAT MAKES L1a MEAN SOMETHING. A 15 ms delay on one side
        // combs the fold-down; the oracle has to see it, or L1a is a test that
        // cannot fail.
        #expect(abs(verdict.worstBandDeltaDb) > 3,
                "the oracle did not see a Haas comb — it cannot detect the failure it exists for")
        #expect(verdict.residualDb > -20,
                "the oracle's residual leg did not see a Haas comb")
    }

    @Test("L1c POSITIVE CONTROL: the same oracle CATCHES the 3 dB the item names")
    func oracleCatchesAThreeDecibelLoss() throws {
        let frames = 48_000
        let (dryL, dryR) = program(frames: frames)
        let (outL, outR) = normalisedWiden(dryL, dryR)
        let verdict = monoVerdict(dryL: dryL, dryR: dryR, outL: outL, outR: outR)
        print("""
            [measured] m23-dj L1c NORMALISED control — level \(verdict.levelDeltaDb) dB, \
            worst band \(verdict.worstBandDeltaDb) dB at \(verdict.worstBandHz) Hz
            """)
        // The item: "a widener that loses 3 dB of vocal when summed is a bug
        // that ships silently". The loss is 20*log10(1/sqrt(2)) = -3.0103 dB,
        // uniform across the spectrum, which is why a per-band check alone
        // would also have to catch it — and does.
        #expect(abs(verdict.levelDeltaDb + 3.0103) < 0.01,
                "measured \(verdict.levelDeltaDb) dB, expected -3.0103")
        for band in verdict.perBand {
            #expect(abs(band.deltaDb + 3.0103) < 0.05,
                    "\(band.hz) Hz read \(band.deltaDb) dB")
        }
    }

    // MARK: - L2 — `width`, and the silent no-op it has on mono material

    @Test("L2a: width 0 removes the side EXACTLY and leaves the mid untouched; width 2 doubles it")
    func widthScalesOnlyTheSide() throws {
        let frames = 48_000
        // One mid tone and one side tone, so each claim reads off one bin.
        let mid = sine(440, amplitude: 0.3, frames: frames)
        let side = sine(1_000, amplitude: 0.25, frames: frames)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            left[index] = mid[index] + side[index]
            right[index] = mid[index] - side[index]
        }
        // `bassMonoAmount: 0` isolates `width` — the crossover is a separate
        // leg and would otherwise touch the 440 Hz side content.
        func sideAmplitude(at width: Double) throws -> (side: Double, mid: Double) {
            let (outL, outR) = try widen(
                StereoWidthParams(width: width, spread: 0, bassMonoAmount: 0), left, right)
            var s = [Double](repeating: 0, count: frames)
            var m = [Double](repeating: 0, count: frames)
            for index in 0..<frames {
                s[index] = (Double(outL[index]) - Double(outR[index])) * 0.5
                m[index] = (Double(outL[index]) + Double(outR[index])) * 0.5
            }
            return (goertzel(s, frequency: 1_000), goertzel(m, frequency: 440))
        }

        let unity = try sideAmplitude(at: 1)
        let mono = try sideAmplitude(at: 0)
        let doubled = try sideAmplitude(at: 2)
        print("""
            [measured] m23-dj L2a side@1kHz — width 0: \(mono.side), \
            width 1: \(unity.side), width 2: \(doubled.side); \
            mid@440 \(mono.mid) / \(unity.mid) / \(doubled.mid)
            """)
        #expect(abs(unity.side - 0.25) < 0.002, "width 1 must pass the side through")
        #expect(dB(mono.side / unity.side) < -80,
                "width 0 left \(dB(mono.side / unity.side)) dB of side behind")
        #expect(abs(dB(doubled.side / unity.side) - 6.0206) < 0.05,
                "width 2 gave \(dB(doubled.side / unity.side)) dB, not +6.02")
        // THE MID IS UNTOUCHED AT EVERY WIDTH — the structural law, measured.
        #expect(abs(mono.mid - unity.mid) < 1e-6)
        #expect(abs(doubled.mid - unity.mid) < 1e-6)
    }

    @Test("L2b: width does NOTHING on a mono source, BIT-EXACTLY — the documented trap, measured")
    func widthIsASilentNoOpOnMonoMaterial() throws {
        let frames = 8_192
        let source = sum([
            sine(300, amplitude: 0.3, frames: frames),
            sine(1_700, amplitude: 0.2, frames: frames, phase: 1.3),
        ])
        // Identical channels: a mono source in a stereo buffer, which is how
        // the graph delivers one.
        for width in [0.0, 0.5, 2.0] {
            let (outL, outR) = try widen(
                StereoWidthParams(width: width, spread: 0, bassMonoAmount: 0),
                source, source)
            for index in 0..<frames {
                #expect(outL[index].bitPattern == source[index].bitPattern,
                        "width \(width) changed L at \(index)")
                #expect(outR[index].bitPattern == source[index].bitPattern,
                        "width \(width) changed R at \(index)")
            }
        }
        // ⭐ THE POINT: this is not a bug, it is arithmetic — `width` is a gain
        // on `L - R`, and on a mono source that is zero. An agent that widens
        // a mono synth with `width` and reports success has shipped
        // silence-shaped success, which is why the trap is in the param note,
        // the MCP text and the wire-reference skill. `spread` is the control
        // that works here, and L3b proves it does.
    }

    @Test("L2c: `width: 0` ALONE IS NOT A MONO-MAKER — the default spread rebuilds a side channel")
    func widthZeroAloneDoesNotFoldToMono() throws {

        // ⭐⭐ THIS LEG EXISTS BECAUSE THE PROSE GOT IT WRONG FIRST, AND THE
        // WRONG VERSION SHIPPED IN FOUR PLACES: the `width` param note, the
        // MCP `fxKindSchema`, the wire-reference skill's recipe table and the
        // MCP README all said "`width: 0` is a real mono-maker". It is not.
        // The side path is `side * width + decorrelated * spread`, and
        // `spread` DEFAULTS TO 0.3 — so a freshly added insert at `width: 0`
        // still emits a side channel, just a synthesized one. An agent asked
        // to "make this mono" that sends `width: 0` and reports done has
        // shipped exactly this tree's characteristic failure: a valid-looking
        // answer that nothing compared against the truth.
        //
        // ⚠️ The mono-COMPATIBILITY guarantee is untouched by this — the fold-
        // down still matches (L1a). The defect was never the audio; it was a
        // recipe that produced the opposite of what it promised, silently.
        let frames = 16_384
        let mid = sine(440, amplitude: 0.3, frames: frames)
        let side = sine(1_000, amplitude: 0.25, frames: frames)
        var stereoL = [Float](repeating: 0, count: frames)
        var stereoR = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            stereoL[index] = mid[index] + side[index]
            stereoR[index] = mid[index] - side[index]
        }

        // (1) STEREO SOURCE, width 0 at the DEFAULT spread: still stereo.
        let defaults = StereoWidthParams()
        #expect(defaults.spread == 0.3, "this leg's whole premise is the default")
        let (stillL, stillR) = try widen(
            StereoWidthParams(width: 0, spread: defaults.spread, bassMonoAmount: 0),
            stereoL, stereoR)
        let residualWidth = widthFigure(stillL, stillR)
        print("[measured] m23-dj L2c — stereo source, width 0 @ default spread: "
              + "width figure \(residualWidth) (input \(widthFigure(stereoL, stereoR)))")
        #expect(residualWidth > 0.01,
                "width 0 at the default spread must NOT be mono — read \(residualWidth)")

        // (2) THE SAME SETTING ON A MONO SOURCE COMES OUT *WIDER* THAN IT WENT
        //     IN. This is the sharpest form of the trap: the one request where
        //     a mono-maker is most likely to be asked for is the one where the
        //     recipe does the opposite.
        let monoSource = sum([
            sine(300, amplitude: 0.3, frames: frames),
            sine(1_700, amplitude: 0.2, frames: frames, phase: 1.3),
        ])
        #expect(widthFigure(monoSource, monoSource) < 1e-12, "the fixture must start mono")
        let (widerL, widerR) = try widen(
            StereoWidthParams(width: 0, spread: defaults.spread, bassMonoAmount: 0),
            monoSource, monoSource)
        let grownWidth = widthFigure(widerL, widerR)
        print("[measured] m23-dj L2c — MONO source, width 0 @ default spread: "
              + "width figure 0.0 -> \(grownWidth)")
        #expect(grownWidth > 0.01,
                "width 0 on mono material must be measurably WIDER, not mono — \(grownWidth)")

        // (3) THE CORRECTED RECIPE: `width: 0` AND `spread: 0` TOGETHER. This
        //     is what every one of the four prose sites now says.
        let (monoL, monoR) = try widen(
            StereoWidthParams(width: 0, spread: 0, bassMonoAmount: 0), stereoL, stereoR)
        let folded = widthFigure(monoL, monoR)
        print("[measured] m23-dj L2c — corrected recipe width 0 + spread 0: width figure \(folded)")
        #expect(folded < 1e-9, "the documented mono recipe must actually be mono — \(folded)")
        // And it is mono the strong way: the channels are BIT-identical.
        for index in 0..<frames {
            #expect(monoL[index].bitPattern == monoR[index].bitPattern,
                    "channels differ at \(index) after the documented mono recipe")
        }
    }

    // MARK: - L3 — `spread`: true stereo out of a mono source

    @Test("L3a: spread 0 leaves a mono source BIT-EXACTLY mono")
    func spreadZeroSynthesizesNothing() throws {
        let frames = 8_192
        let source = sine(500, amplitude: 0.4, frames: frames)
        let (outL, outR) = try widen(
            StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0), source, source)
        for index in 0..<frames {
            #expect(outL[index].bitPattern == source[index].bitPattern)
            #expect(outR[index].bitPattern == source[index].bitPattern)
        }
    }

    @Test("L3b: spread turns a MONO source into a decorrelated stereo one — and the fold-down survives it")
    func spreadCreatesTrueStereoFromMono() throws {
        let frames = 48_000
        let source = sum([
            sine(300, amplitude: 0.22, frames: frames),
            sine(760, amplitude: 0.18, frames: frames, phase: 0.9),
            sine(1_900, amplitude: 0.14, frames: frames, phase: 2.1),
            sine(4_400, amplitude: 0.10, frames: frames, phase: 0.4),
        ])
        #expect(correlation(source, source) > 0.9999, "the input is mono by construction")
        #expect(widthFigure(source, source) < 1e-12)

        var previousWidth = -1.0
        for spread in [0.25, 0.5, 1.0] {
            let (outL, outR) = try widen(
                StereoWidthParams(width: 1, spread: spread, bassMonoAmount: 0),
                source, source)
            let corr = correlation(outL, outR)
            let figure = widthFigure(outL, outR)
            print("[measured] m23-dj L3b spread \(spread) — correlation \(corr), width figure \(figure)")
            #expect(corr < 0.98, "spread \(spread) left the channels correlated at \(corr)")
            #expect(figure > 0.01, "spread \(spread) manufactured no side energy")
            // Monotone: more spread, more side. An agent reasoning about the
            // control needs that to be true.
            #expect(figure > previousWidth)
            previousWidth = figure

            // ⭐ AND THE WHOLE POINT: the mono fold-down of a MANUFACTURED
            // stereo image is still exactly the mono source it came from.
            let verdict = monoVerdict(dryL: source, dryR: source, outL: outL, outR: outR)
            #expect(abs(verdict.levelDeltaDb) < 0.005,
                    "spread \(spread) moved the fold-down by \(verdict.levelDeltaDb) dB")
            #expect(verdict.residualDb < -100,
                    "spread \(spread) left a \(verdict.residualDb) dB mono residual")
        }
    }

    /// ⭐⭐ THE HONEST COST, MEASURED OUT OF A RENDER RATHER THAN ASSERTED.
    /// `StereoWidthParams.channelPeakDb`/`channelNotchDb` claim the per-channel
    /// ripple is exactly `20·log10(1 ± spread)`. This recovers the channel's
    /// own frequency response from an impulse render and checks both extremes
    /// — and, in the same measurement, checks that the SUM of the two channels
    /// is flat to within a whisker, which is the frequency-domain statement of
    /// L1.
    @Test("L3c: the per-channel ripple IS 20*log10(1 +/- spread), and the SUM is flat")
    func perChannelRippleMatchesTheClosedForm() throws {
        let frames = 32_768
        let spread = 0.3
        let ping = impulse(at: 0, frames: frames)
        let (outL, outR) = try widen(
            StereoWidthParams(width: 1, spread: spread, bassMonoAmount: 0), ping, ping)

        var sumChannel = [Float](repeating: 0, count: frames)
        for index in 0..<frames { sumChannel[index] = outL[index] + outR[index] }

        var peak = 0.0, notch = .infinity as Double
        var worstSumError = 0.0
        var probes = 0
        // A log grid from 120 Hz to 12 kHz: dense enough that the all-pass
        // chain's phase passes through both extremes many times inside it.
        var hz = 120.0
        while hz < 12_000 {
            let magnitude = dftMagnitude(outL, frequency: hz)
            peak = max(peak, magnitude)
            notch = min(notch, magnitude)
            // |H_L + H_R| must be exactly 2 (the impulse, doubled) at EVERY
            // frequency: the side terms are +s·A and −s·A and they cancel.
            worstSumError = max(worstSumError,
                                abs(dftMagnitude(sumChannel, frequency: hz) - 2))
            probes += 1
            hz *= 1.01
        }
        print("""
            [measured] m23-dj L3c over \(probes) probes — channel peak \(dB(peak)) dB \
            (law \(StereoWidthParams.channelPeakDb(spread: spread))), \
            notch \(dB(notch)) dB (law \(StereoWidthParams.channelNotchDb(spread: spread))), \
            worst |sum| error \(worstSumError)
            """)
        #expect(probes > 400, "the grid is too coarse to find the extremes")
        #expect(abs(dB(peak) - StereoWidthParams.channelPeakDb(spread: spread)) < 0.15,
                "measured peak \(dB(peak)) dB against the law's \(StereoWidthParams.channelPeakDb(spread: spread))")
        #expect(abs(dB(notch) - StereoWidthParams.channelNotchDb(spread: spread)) < 0.15,
                "measured notch \(dB(notch)) dB against the law's \(StereoWidthParams.channelNotchDb(spread: spread))")
        // ⭐ THE FREQUENCY-DOMAIN FORM OF THE ACCEPTANCE TEST: flat, at every
        // probe, while each channel alone ripples by 5.4 dB peak-to-notch.
        #expect(worstSumError < 1e-4,
                "the summed response deviated by \(worstSumError) from a flat 2.0")
    }

    /// ⭐ THE DECORRELATOR IS A DIFFUSE NETWORK, NOT A DELAYED COPY — which is
    /// the distinction the item was raised on. A single delayed copy in the
    /// side path would be just as mono-safe (anything of the form
    /// `S' = F(M)` is) and would produce the SAME ±spread ripple bounds, so
    /// neither L1 nor L3c can tell them apart. What separates them is TIME:
    /// an all-pass chain smears the impulse over hundreds of samples at
    /// irregular spacings, while a delay puts all of it in one.
    ///
    /// The measurement is direct, because at `spread 1` on a mono input the
    /// output's side channel IS the network's impulse response: `L = M + A(M)`
    /// and `R = M − A(M)`, so `(L − R)/2 = A(M)`.
    @Test("L3d: the decorrelator DISPERSES the impulse instead of delaying it")
    func decorrelatorIsDiffuseNotADelayedCopy() throws {
        let frames = 16_384
        let ping = impulse(at: 0, frames: frames)
        let (outL, outR) = try widen(
            StereoWidthParams(width: 1, spread: 1, bassMonoAmount: 0), ping, ping)
        var response = [Double](repeating: 0, count: frames)
        for index in 0..<frames {
            response[index] = (Double(outL[index]) - Double(outR[index])) * 0.5
        }
        let peak = response.map(abs).max() ?? 0
        let totalEnergy = response.reduce(0) { $0 + $1 * $1 }
        let largestSampleEnergy = peak * peak
        let significant = response.filter { abs($0) > peak * 0.01 }.count
        print("""
            [measured] m23-dj L3d decorrelator impulse response — peak \(peak), \
            \(significant) samples above 1% of peak, largest single sample carries \
            \(largestSampleEnergy / max(totalEnergy, 1e-30) * 100)% of the energy
            """)
        #expect(totalEnergy > 0, "the decorrelator produced nothing at all")
        // A single delayed copy would put 100% of the energy in ONE sample and
        // leave exactly one sample above the 1% line.
        #expect(significant > 200, """
            only \(significant) samples carry the decorrelator's output — this is a DELAYED \
            COPY, not a diffuse network, and it will comb audibly where an all-pass chain \
            would not
            """)
        #expect(largestSampleEnergy / totalEnergy < 0.5, """
            one sample carries \(largestSampleEnergy / totalEnergy * 100)% of the \
            decorrelator's energy — the chain is not dispersing
            """)
    }

    // MARK: - L4 — bass mono, and the crossover direction this author got wrong

    /// ⛔ THE LEG THAT CAUGHT A REAL BUG. The first draft computed the
    /// high-passed side as `built − lowpass²(built)`. That factors as
    /// `(1 − LP)(1 + LP)`: a SIX dB/oct high-pass with a +6 dB lift, not the
    /// twelve this control claims. It looks identical in the source, it is
    /// identical above 1 kHz, and at 40 Hz it removes 4.3 dB where the correct
    /// structure removes 20.0 dB. Only a measurement below the corner can tell
    /// them apart, so this is that measurement.
    @Test("L4a: bassMonoAmount 1 removes side content below the corner at a real 12 dB/oct")
    func bassMonoIsTwelveDecibelsPerOctave() throws {
        let frames = 48_000
        func sideAttenuationDb(at hz: Double, amount: Double) throws -> Double {
            let tone = sine(hz, amplitude: 0.4, frames: frames)
            var left = [Float](repeating: 0, count: frames)
            var right = [Float](repeating: 0, count: frames)
            for index in 0..<frames {
                left[index] = tone[index]        // pure SIDE: L = +s, R = -s
                right[index] = -tone[index]
            }
            let (outL, outR) = try widen(
                StereoWidthParams(width: 1, spread: 0, bassMonoHz: 120,
                                  bassMonoAmount: amount), left, right)
            var side = [Double](repeating: 0, count: frames)
            for index in 0..<frames {
                side[index] = (Double(outL[index]) - Double(outR[index])) * 0.5
            }
            // Skip the first 20 % so the crossover's own settling is out of
            // the window.
            let settled = Array(side[(frames / 5)...])
            return dB(goertzel(settled, frequency: hz) / 0.4)
        }

        let at30 = try sideAttenuationDb(at: 30, amount: 1)
        let at40 = try sideAttenuationDb(at: 40, amount: 1)
        let at80 = try sideAttenuationDb(at: 80, amount: 1)
        let at2k = try sideAttenuationDb(at: 2_000, amount: 1)
        print("""
            [measured] m23-dj L4a side attenuation at amount 1 — \
            30 Hz \(at30) dB, 40 Hz \(at40) dB, 80 Hz \(at80) dB, 2 kHz \(at2k) dB; \
            slope 30->60 implied \(at40 - at80) dB per octave (40->80)
            """)
        // ⛔ THE DISCRIMINATOR. A true 12 dB/oct pair reads about -20 dB at
        // 40 Hz against a 120 Hz corner; the `1 - LP²` impostor reads about
        // -4.3 dB there. A bound of -12 sits between them with room on both
        // sides and does not depend on the exact one-pole mapping.
        #expect(at40 < -12,
                "40 Hz side content only fell \(at40) dB — this is the 6 dB/oct impostor")
        #expect(at30 < at40, "attenuation must deepen as frequency falls")
        #expect(at40 < at80, "attenuation must deepen as frequency falls")
        // Slope: halving the frequency must cost roughly 12 dB, not 6.
        let slope = at40 - at80
        #expect(slope < -8, "measured \(slope) dB per octave between 80 and 40 Hz")
        // …and it leaves the top end alone, or it is a width control and not a
        // bass control.
        #expect(abs(at2k) < 0.3, "2 kHz side content moved \(at2k) dB")
    }

    @Test("L4b: bassMonoAmount 0 is EXACTLY off — the corner frequency then changes nothing")
    func bassMonoAmountZeroIsExactlyOff() throws {
        let frames = 16_384
        let tone = sine(40, amplitude: 0.4, frames: frames)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            left[index] = tone[index]
            right[index] = -tone[index]
        }
        // ⚠️ `width` is deliberately 1.5, not 1, so the effect is NOT at its
        // neutral position and the buffer really is being written — otherwise
        // this leg would be measuring the bit-exact bypass instead.
        let low = try widen(StereoWidthParams(width: 1.5, spread: 0, bassMonoHz: 20,
                                              bassMonoAmount: 0), left, right)
        let high = try widen(StereoWidthParams(width: 1.5, spread: 0, bassMonoHz: 500,
                                               bassMonoAmount: 0), left, right)
        // A frequency knob on a fully bypassed filter is not a setting: the two
        // renders must be BIT-IDENTICAL. This is the measured form of the
        // `bassMonoHz` note's "does nothing when amount is 0".
        for index in 0..<frames {
            #expect(low.left[index].bitPattern == high.left[index].bitPattern,
                    "bassMonoHz changed the output at amount 0, index \(index)")
            #expect(low.right[index].bitPattern == high.right[index].bitPattern)
        }
        // And the side really did survive: 1.5x of it, untouched at 40 Hz.
        var side = [Double](repeating: 0, count: frames)
        for index in 0..<frames {
            side[index] = (Double(low.left[index]) - Double(low.right[index])) * 0.5
        }
        let amplitude = goertzel(Array(side[(frames / 4)...]), frequency: 40)
        print("[measured] m23-dj L4b 40 Hz side at amount 0 — \(amplitude) (expect 0.6)")
        #expect(abs(amplitude - 0.6) < 0.01)
    }

    // MARK: - L5 — the bit-exact bypass, its positive control, and the fed state

    @Test("L5a: the neutral position is a BIT-EXACT passthrough on wildly asymmetric material")
    func neutralPositionIsBitExact() throws {
        let frames = 16_384
        // Deliberately hostile to a mid/side ROUND TRIP — see
        // `asymmetricProgram`'s own note for why a balanced fixture here would
        // make this leg unfalsifiable.
        let (left, right) = asymmetricProgram(frames: frames)
        let (outL, outR) = try widen(
            StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0), left, right)
        var mismatches = 0
        for index in 0..<frames {
            if outL[index].bitPattern != left[index].bitPattern { mismatches += 1 }
            if outR[index].bitPattern != right[index].bitPattern { mismatches += 1 }
        }
        #expect(mismatches == 0, "\(mismatches) samples changed at the neutral position")
    }

    @Test("L5b POSITIVE CONTROL: a hair off neutral and the byte comparison REDDENS")
    func bitExactBypassPositiveControl() throws {
        let frames = 4_096
        let (left, right) = program(frames: frames)
        let neutral = try widen(
            StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0), left, right)
        // ⚠️ THE PERTURBED PARAM IS `width`, NOT `bassMonoHz`. With the amount
        // at 0 the crossover is fully bypassed, so a frequency move CORRECTLY
        // changes nothing — a control built on it would read as one that
        // cannot fail. `StereoWidthParams.isNeutral` names the three that can
        // leave the bypass, and this uses one of them.
        let nudged = try widen(
            StereoWidthParams(width: 1 + 1e-6, spread: 0, bassMonoAmount: 0), left, right)
        var differing = 0
        for index in 0..<frames where
            nudged.left[index].bitPattern != neutral.left[index].bitPattern {
            differing += 1
        }
        print("[measured] m23-dj L5b — \(differing) of \(frames) samples differ at width 1+1e-6")
        #expect(differing > frames / 2, """
            a 1e-6 width change moved only \(differing) samples — the byte comparison in L5a \
            is not sensitive enough to be evidence
            """)
        // And the two remaining neutral fields do the same, so all three legs
        // of `isNeutral` are proven live rather than assumed.
        let spread = try widen(
            StereoWidthParams(width: 1, spread: 1e-6, bassMonoAmount: 0), left, right)
        let amount = try widen(
            StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 1e-6), left, right)
        #expect((0..<frames).contains {
            spread.left[$0].bitPattern != neutral.left[$0].bitPattern
        }, "a spread of 1e-6 did not leave the bypass")
        #expect((0..<frames).contains {
            amount.left[$0].bitPattern != neutral.left[$0].bitPattern
        }, "a bassMonoAmount of 1e-6 did not leave the bypass")
    }

    @Test("L5c: the decorrelator KEEPS RUNNING through the bypass, so a later spread raise is coherent")
    func decorrelatorRunsThroughTheBypass() throws {
        let chunk = 512
        let quanta = 40
        let frames = chunk * quanta
        let source = sum([
            sine(320, amplitude: 0.3, frames: frames),
            sine(1_100, amplitude: 0.2, frames: frames, phase: 1.4),
        ])
        let raiseAt = 20

        // Run A: neutral for 20 quanta, then `spread` raised.
        let fed = StereoWidthEffect(
            params: StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0))
        fed.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        let outFed = try processChunked(fed, channels: [source, source], chunk: chunk) { effect, q in
            if q >= raiseAt { effect.storeAutomatedParam(slot: 1, value: 0.6) }
        }

        // Run B: the SAME raise, on an effect whose lines were reset at the
        // raise — i.e. exactly what a "skip the decorrelator while bypassed"
        // implementation would produce.
        let starved = StereoWidthEffect(
            params: StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0))
        starved.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        let outStarved = try processChunked(
            starved, channels: [source, source], chunk: chunk) { effect, q in
            if q == raiseAt { effect.reset() }
            if q >= raiseAt { effect.storeAutomatedParam(slot: 1, value: 0.6) }
        }

        // Compare the FIRST quantum after the raise. A fed chain opens into a
        // settled image; a starved one swells up out of silence.
        let window = (raiseAt * chunk)..<((raiseAt + 1) * chunk)
        var fedSide = [Float](), starvedSide = [Float]()
        for index in window {
            fedSide.append((outFed[0][index] - outFed[1][index]) * 0.5)
            starvedSide.append((outStarved[0][index] - outStarved[1][index]) * 0.5)
        }
        let fedRms = rms(fedSide[...])
        let starvedRms = rms(starvedSide[...])
        print("""
            [measured] m23-dj L5c first quantum after the raise — \
            fed side rms \(fedRms), starved side rms \(starvedRms), \
            ratio \(dB(fedRms / max(starvedRms, 1e-30))) dB
            """)
        #expect(fedRms > 0, "the fed run produced no side at all — the raise never took")
        #expect(fedRms > starvedRms * 1.2, """
            the decorrelator carried no history through the bypass: a fed chain measured \
            \(fedRms) against a starved chain's \(starvedRms). Skipping the chain while \
            neutral is exactly the change this leg exists to catch.
            """)
    }

    // MARK: - L6 — the mandatory internal smoothing (rule 6.0.6)

    @Test("L6: a width STEP at a quantum boundary is ramped across the quantum, not applied at once")
    func widthStepsAreSmoothedAcrossTheQuantum() throws {
        let chunk = 512
        let quanta = 8
        let frames = chunk * quanta
        // A side tone only, so the step's whole effect lands on one signal
        // whose natural slew is known exactly. ⚠️ 375 Hz is PERIOD-ALIGNED to
        // the 512-frame quantum (128 samples per period, four per quantum), so
        // a per-quantum amplitude measurement is not a function of where the
        // window happens to start. A 200 Hz tone here read 6.27 dB instead of
        // 6.02 for exactly that reason, and the error was in the ruler.
        let tone = sine(375, amplitude: 0.4, frames: frames)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            left[index] = tone[index]
            right[index] = -tone[index]
        }
        let stepAt = 4
        let effect = StereoWidthEffect(
            params: StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        let out = try processChunked(effect, channels: [left, right], chunk: chunk) { fx, q in
            if q >= stepAt { fx.storeAutomatedParam(slot: 0, value: 2.0) }
        }

        let boundary = stepAt * chunk
        // The signal's own maximum slew, measured from the SAME render well
        // away from the boundary, so the bound is derived and not guessed.
        var naturalSlew = 0.0
        for index in (boundary - 400)..<(boundary - 4) {
            naturalSlew = max(naturalSlew, abs(Double(out[0][index] - out[0][index - 1])))
        }
        var boundarySlew = 0.0
        var worstIndex = 0
        for index in (boundary - 2)...(boundary + 2) {
            let slew = abs(Double(out[0][index] - out[0][index - 1]))
            if slew > boundarySlew { boundarySlew = slew; worstIndex = index }
        }
        print("""
            [measured] m23-dj L6 — natural slew \(naturalSlew), \
            slew at the boundary \(boundarySlew) (index \(worstIndex)), \
            ratio \(boundarySlew / max(naturalSlew, 1e-12))
            """)
        // Unsmoothed, the boundary sample jumps by a whole extra side sample —
        // up to 0.4 here, roughly 7x the 200 Hz tone's own per-sample slew.
        // Smoothed, the extra width arrives 1/512 at a time and the boundary
        // is indistinguishable from any other sample.
        #expect(boundarySlew < naturalSlew * 1.6, """
            the width step landed as a \(boundarySlew) jump against a natural slew of \
            \(naturalSlew) — the per-sample interpolation is not in force
            """)
        // Non-vacuity: the step must actually have HAPPENED. Measured with
        // Goertzel at the tone's own frequency rather than broadband RMS, so
        // the number is the side AMPLITUDE and not a window artefact.
        var before = [Double](), after = [Double]()
        for index in 0..<boundary {
            before.append((Double(out[0][index]) - Double(out[1][index])) * 0.5)
        }
        for index in (boundary + chunk)..<frames {
            after.append((Double(out[0][index]) - Double(out[1][index])) * 0.5)
        }
        let growth = dB(goertzel(after, frequency: 375) / goertzel(before, frequency: 375))
        print("[measured] m23-dj L6 side growth across the step — \(growth) dB (expect +6.02)")
        #expect(abs(growth - 6.0206) < 0.1, "the automated width step never took")
    }

    // MARK: - L7 — the bypass re-engages after a ride (the endpoint SNAP)

    /// ⚠️⚠️ TWO CHOICES HERE ARE LOAD-BEARING, AND BOTH WERE FOUND BY PLANTING
    /// THE DEFECT AND WATCHING NOTHING HAPPEN.
    ///
    /// 1. **`width` rides to 0.33, and the value is EMPIRICAL, not decorative.**
    ///    Whether the accumulator lands back on exactly 1.0 is data-dependent:
    ///    a delta of `0.5/512` is an exact binary fraction, so a 1.5 ride
    ///    returns to exactly 1.0 and the leg passes with the snap deleted —
    ///    and so does 1.37, measured. 0.33 leaves a residue of
    ///    1.000000000000007, which is what disables the bypass. Only 99 of the
    ///    1650 three-decimal widths in [0.3, 1.95] leave any residue at all,
    ///    so this number was FOUND by planting the defect, not chosen.
    /// 2. **The fixture is `asymmetricProgram`, not `program`.** Even at
    ///    0.9999999999999956 the accumulated `width` narrows to exactly `1.0f`
    ///    in the render path, so the effect computes `M ± S` — and on BALANCED
    ///    material that round trip is bit-exact, so the planted defect still
    ///    changed not one byte. It takes a fixture the round trip can actually
    ///    destroy.
    @Test("L7: after a width ride returns to neutral, the bypass RE-ENGAGES and is bit-exact again")
    func bypassReEngagesAfterARide() throws {
        let chunk = 512
        let quanta = 8
        let frames = chunk * quanta
        let (left, right) = asymmetricProgram(frames: frames)
        let effect = StereoWidthEffect(
            params: StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        let rideStart = 2, rideEnd = 4
        let out = try processChunked(effect, channels: [left, right], chunk: chunk) { fx, q in
            if q >= rideStart && q < rideEnd {
                fx.storeAutomatedParam(slot: 0, value: 0.33)
            } else if q >= rideEnd {
                fx.storeAutomatedParam(slot: 0, value: 1.0)
            }
        }

        func mismatches(in quantum: Int) -> Int {
            var count = 0
            for index in (quantum * chunk)..<((quantum + 1) * chunk) {
                if out[0][index].bitPattern != left[index].bitPattern { count += 1 }
                if out[1][index].bitPattern != right[index].bitPattern { count += 1 }
            }
            return count
        }
        let duringRide = mismatches(in: rideStart + 1)
        let rampBack = mismatches(in: rideEnd)
        let settled = mismatches(in: rideEnd + 1)
        let laterStill = mismatches(in: rideEnd + 2)
        print("""
            [measured] m23-dj L7 mismatching samples — during the ride \(duringRide), \
            ramp-back quantum \(rampBack), first settled quantum \(settled), \
            next \(laterStill)
            """)
        #expect(duringRide > 0, "the ride never took — the rest of this leg is vacuous")
        #expect(rampBack > 0,
                "the return to neutral snapped instead of ramping, which is a click")
        #expect(settled == 0, """
            the bit-exact bypass did NOT re-engage one quantum after the ride ended \
            (\(settled) samples still differ). The interpolation endpoints are not being \
            snapped to their targets, so `width` is settling a few ULPs off 1.0.
            """)
        #expect(laterStill == 0)
    }

    // MARK: - L8 — denormals

    @Test("L8: after a burst, the decorrelator tail reaches EXACT zero rather than grinding through subnormals")
    func denormalFlushKillsTheTail() throws {
        let chunk = 512
        let burstFrames = 4_800          // 0.1 s
        let silenceFrames = 96_000       // 2.0 s
        let frames = burstFrames + silenceFrames
        var source = [Float](repeating: 0, count: frames)
        // A broadband burst, so every stage of the chain is excited.
        var rng = SystemRandomNumberGenerator()
        for index in 0..<burstFrames {
            source[index] = Float(Double.random(in: -0.8...0.8, using: &rng))
        }
        // spread 1 puts the decorrelator's ENTIRE output into the buffer, so
        // the tail is visible from the output rather than only from the state.
        let (outL, outR) = try widen(
            StereoWidthParams(width: 1, spread: 1, bassMonoAmount: 0),
            source, source, chunk: chunk)

        // Find the last non-zero sample in either channel.
        var lastNonZero = -1
        for index in stride(from: frames - 1, through: 0, by: -1) {
            if outL[index] != 0 || outR[index] != 0 { lastNonZero = index; break }
        }
        let settleSeconds = Double(lastNonZero - burstFrames) / Self.sampleRate
        print("""
            [measured] m23-dj L8 — last non-zero output sample \(lastNonZero) of \(frames), \
            \(settleSeconds) s after the burst ended
            """)
        // ⛔ THE DISCRIMINATOR. With the 1e-20 flush the chain's slowest mode
        // (13.1 ms at g = 0.62) crosses the threshold in about 1.3 s. WITHOUT
        // it the state keeps decaying through normal floats for another second
        // and a half before it even reaches the subnormal band, so the output
        // is still non-zero at 2.0 s and this leg reddens.
        #expect(lastNonZero >= 0, "the effect produced no output at all")
        #expect(settleSeconds < 1.8, """
            the tail was still non-zero \(settleSeconds) s after the burst — the recirculating \
            all-pass values are not being denormal-flushed
            """)
        // Non-vacuity: it really did ring for a while first, so "reaches zero"
        // is not "was always zero".
        #expect(settleSeconds > 0.2, "the tail died suspiciously fast — is the chain running?")
        // And nothing subnormal ever reached the buffer.
        var subnormals = 0
        for index in 0..<frames {
            if outL[index] != 0 && abs(outL[index]) < .leastNormalMagnitude { subnormals += 1 }
            if outR[index] != 0 && abs(outR[index]) < .leastNormalMagnitude { subnormals += 1 }
        }
        #expect(subnormals == 0, "\(subnormals) subnormal samples reached the output")
    }

    // MARK: - L9 — the automation surface

    @Test("L9: every slot drives its OWN parameter, and out-of-range or non-finite pokes are inert")
    func automationSlotsAreWiredToTheRightParameters() throws {
        let chunk = 512
        let frames = chunk * 12
        let mid = sine(440, amplitude: 0.3, frames: frames)
        let side = sine(1_500, amplitude: 0.25, frames: frames)
        let bassSide = sine(45, amplitude: 0.25, frames: frames)
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        for index in 0..<frames {
            left[index] = mid[index] + side[index] + bassSide[index]
            right[index] = mid[index] - side[index] - bassSide[index]
        }

        /// Side amplitude at `hz` in the settled second half of the render.
        func sideAt(_ hz: Double, poking slot: Int, to value: Double,
                    from base: StereoWidthParams) throws -> Double {
            let effect = StereoWidthEffect(params: base)
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk,
                           channelCount: 2)
            let out = try processChunked(effect, channels: [left, right], chunk: chunk) { fx, _ in
                fx.storeAutomatedParam(slot: slot, value: value)
            }
            var s = [Double](repeating: 0, count: frames / 2)
            for index in 0..<(frames / 2) {
                let at = index + frames / 2
                s[index] = (Double(out[0][at]) - Double(out[1][at])) * 0.5
            }
            return goertzel(s, frequency: hz)
        }

        let flat = StereoWidthParams(width: 1, spread: 0, bassMonoAmount: 0)
        // slot 0 — width
        let widened = try sideAt(1_500, poking: 0, to: 2.0, from: flat)
        #expect(abs(dB(widened / 0.25) - 6.0206) < 0.1,
                "slot 0 is not `width`: 1.5 kHz side read \(dB(widened / 0.25)) dB")
        // slot 1 — spread (measured on a MONO fixture so nothing else can move)
        let monoSource = sine(900, amplitude: 0.4, frames: frames)
        let spreadEffect = StereoWidthEffect(params: flat)
        spreadEffect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk,
                             channelCount: 2)
        let spreadOut = try processChunked(
            spreadEffect, channels: [monoSource, monoSource], chunk: chunk) { fx, _ in
            fx.storeAutomatedParam(slot: 1, value: 0.7)
        }
        #expect(widthFigure(spreadOut[0], spreadOut[1]) > 0.01,
                "slot 1 is not `spread`: a mono source stayed mono")
        // slot 3 — bassMonoAmount, and then slot 2 — bassMonoHz, which is only
        // observable once slot 3 is non-zero.
        let bassOn = StereoWidthParams(width: 1, spread: 0, bassMonoHz: 120,
                                       bassMonoAmount: 1)
        let amountOff = try sideAt(45, poking: 3, to: 0.0, from: bassOn)
        let amountOn = try sideAt(45, poking: 3, to: 1.0, from: bassOn)
        print("[measured] m23-dj L9 45 Hz side — amount 0: \(amountOff), amount 1: \(amountOn)")
        #expect(dB(amountOn / amountOff) < -10, "slot 3 is not `bassMonoAmount`")
        let cornerLow = try sideAt(45, poking: 2, to: 20.0, from: bassOn)
        let cornerHigh = try sideAt(45, poking: 2, to: 500.0, from: bassOn)
        print("[measured] m23-dj L9 45 Hz side — corner 20 Hz: \(cornerLow), 500 Hz: \(cornerHigh)")
        #expect(cornerHigh < cornerLow * 0.5, "slot 2 is not `bassMonoHz`")

        // Inert pokes: an out-of-range slot and a non-finite value must change
        // nothing at all, measured as bit-identity against no poke.
        let clean = try widen(bassOn, left, right, chunk: chunk)
        for (slot, value) in [(-1, 0.5), (4, 0.5), (99, 0.5), (0, Double.nan),
                              (1, Double.infinity)] {
            let effect = StereoWidthEffect(params: bassOn)
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk,
                           channelCount: 2)
            let out = try processChunked(effect, channels: [left, right], chunk: chunk) { fx, _ in
                fx.storeAutomatedParam(slot: slot, value: value)
            }
            var differing = 0
            for index in 0..<frames where
                out[0][index].bitPattern != clean.left[index].bitPattern {
                differing += 1
            }
            #expect(differing == 0,
                    Comment(rawValue: "storeAutomatedParam(slot: \(slot), value: \(value)) "
                        + "was not inert (\(differing) samples moved)"))
        }
    }

    // MARK: - L10 — determinism, latency, finiteness, and the mono buffer

    @Test("L10a: two renders from the same state are BIT-IDENTICAL, and latencySamples is 0")
    func rendersAreDeterministicAndLatencyFree() throws {
        let frames = 8_192
        let (left, right) = program(frames: frames)
        let params = StereoWidthParams(width: 1.7, spread: 0.55, bassMonoHz: 90,
                                       bassMonoAmount: 0.8)
        let first = try widen(params, left, right)
        let second = try widen(params, left, right)
        for index in 0..<frames {
            #expect(first.left[index].bitPattern == second.left[index].bitPattern)
            #expect(first.right[index].bitPattern == second.right[index].bitPattern)
        }
        let effect = StereoWidthEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(effect.latencySamples == 0)
        // Quantum size must not change the result either: the interpolation is
        // per-sample across whatever span arrives, but with STEADY params both
        // endpoints are equal, so there is nothing to ramp and the two must
        // agree bit for bit.
        let chunked = try widen(params, left, right, chunk: 128)
        for index in 0..<frames {
            #expect(chunked.left[index].bitPattern == first.left[index].bitPattern,
                    "quantum size changed the output at \(index)")
        }
    }

    @Test("L10b: the output stays finite at every extreme, on hostile input")
    func outputStaysFiniteAtTheExtremes() throws {
        let frames = 8_192
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        var rng = SystemRandomNumberGenerator()
        for index in 0..<frames {
            left[index] = Float(Double.random(in: -1...1, using: &rng))
            right[index] = -left[index] * 0.999   // near-perfect anti-phase
        }
        for params in [
            StereoWidthParams(width: 2, spread: 1, bassMonoHz: 20, bassMonoAmount: 1),
            StereoWidthParams(width: 0, spread: 1, bassMonoHz: 500, bassMonoAmount: 0),
            StereoWidthParams(width: 2, spread: 0, bassMonoHz: 500, bassMonoAmount: 1),
        ] {
            let (outL, outR) = try widen(params, left, right)
            for index in 0..<frames {
                #expect(outL[index].isFinite, "non-finite L at \(index) for \(params)")
                #expect(outR[index].isFinite, "non-finite R at \(index) for \(params)")
            }
        }
    }

    @Test("L10c: a MONO buffer passes through bit-exact — there is no second channel to widen into")
    func monoBufferPassesThrough() throws {
        let frames = 4_096
        let source = sum([
            sine(250, amplitude: 0.4, frames: frames),
            sine(1_300, amplitude: 0.3, frames: frames, phase: 0.6),
        ])
        let effect = StereoWidthEffect(
            params: StereoWidthParams(width: 2, spread: 1, bassMonoAmount: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let out = try processChunked(effect, channels: [source], chunk: 512)
        for index in 0..<frames {
            #expect(out[0][index].bitPattern == source[index].bitPattern,
                    "a mono buffer was modified at \(index)")
        }
    }

    // MARK: - L11 — the render path allocates NOTHING

    /// The `InsertSpectrumChainTests` probe, applied directly to this effect
    /// so no `@MainActor` chain plumbing is needed. `malloc_logger` is
    /// libmalloc's hook behind `MallocStackLogging`; it fires on EVERY malloc
    /// AND free, so a transient allocation is counted twice rather than
    /// cancelling out. Unavailable is a FAILURE, never a skip.
    private typealias MallocLoggerFn =
        @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    private nonisolated(unsafe) static let eventCount =
        UnsafeMutablePointer<Int>.allocate(capacity: 1)
    private nonisolated(unsafe) static let watchedThread =
        UnsafeMutablePointer<UInt64>.allocate(capacity: 1)

    private static let eventHook: MallocLoggerFn = { _, _, _, _, _, _ in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)  // no allocation, safe under malloc
        if tid == StereoWidthTests.watchedThread.pointee {
            StereoWidthTests.eventCount.pointee &+= 1
        }
    }

    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: MallocLoggerFn?.self)
    }

    @Test("L11: 4000 quanta of process() raise ZERO malloc/free events — an ABSOLUTE zero, not a delta")
    func processAllocatesNothing() throws {
        let slot = try #require(Self.mallocLoggerSlot(),
                                "malloc_logger is unavailable — this gate scored NOTHING")
        let chunk = 512
        let effect = StereoWidthEffect(
            params: StereoWidthParams(width: 1.6, spread: 0.45, bassMonoHz: 110,
                                      bassMonoAmount: 0.9))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)

        // Preallocated buffer list — the harness must not contribute events.
        let storage = UnsafeMutablePointer<Float>.allocate(capacity: chunk * 2)
        defer { storage.deallocate() }
        storage.initialize(repeating: 0, count: chunk * 2)
        let list = AudioBufferList.allocate(maximumBuffers: 2)
        defer { free(list.unsafeMutablePointer) }
        for channel in 0..<2 {
            list[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(chunk * MemoryLayout<Float>.stride),
                mData: UnsafeMutableRawPointer(storage + channel * chunk))
        }
        let tone = sine(440, amplitude: 0.4, frames: chunk)
        let tone2 = sine(660, amplitude: 0.3, frames: chunk)
        for index in 0..<chunk {
            storage[index] = tone[index]
            storage[chunk + index] = tone2[index]
        }
        // Warm up OUTSIDE the measurement: first-call lazy initialisation is
        // real and is not a render-path allocation.
        effect.process(buffers: list, frameCount: chunk)

        pthread_threadid_np(nil, &Self.watchedThread.pointee)
        Self.eventCount.pointee = 0
        let previous = slot.pointee
        slot.pointee = Self.eventHook
        var quantum = 0
        while quantum < 4_000 {
            effect.process(buffers: list, frameCount: chunk)
            // The automation store is on the same render thread and must be
            // allocation-free too.
            effect.storeAutomatedParam(slot: 0, value: 1.2 + Double(quantum % 7) * 0.05)
            quantum += 1
        }
        slot.pointee = previous
        let events = Self.eventCount.pointee
        print("[measured] m23-dj L11 — \(events) malloc/free events across 4000 quanta")
        #expect(events == 0, "the render path raised \(events) malloc/free events")

        // POSITIVE CONTROL: the probe must be capable of counting. If this
        // reads 0 too, the hook never fired and the assertion above is
        // meaningless.
        pthread_threadid_np(nil, &Self.watchedThread.pointee)
        Self.eventCount.pointee = 0
        slot.pointee = Self.eventHook
        var sink: [Int] = []
        var index = 0
        while index < 200 { sink.append(index); index += 1 }
        slot.pointee = previous
        let controlEvents = Self.eventCount.pointee
        print("[measured] m23-dj L11 control — \(controlEvents) events from a growing array")
        #expect(controlEvents > 0, """
            the malloc probe counted NOTHING while an array grew 200 times — the hook never \
            fired, so the zero above is not evidence
            """)
        #expect(sink.count == 200)
    }

    // MARK: - L12 — the prepare-time refusal is visible, not silent

    @Test("L12: a nonsense sample rate is REFUSED and recorded rather than silently widening nothing")
    func prepareRefusalIsObservable() throws {
        let effect = StereoWidthEffect(params: StereoWidthParams(spread: 0.5))
        // ⚠️ 100 Hz, not 200. The declared floor is the ROUNDED stage delay,
        // and at 200 Hz the shortest stage (2.9 ms = 0.58 samples) rounds UP
        // to 1 — which `.linear`'s stencil accepts, correctly. 100 Hz rounds
        // it to 0, which is the condition the home exists to refuse. (This
        // author reached for 200 first and watched the leg pass for the wrong
        // reason.)
        effect.prepare(sampleRate: 100, maxFramesPerQuantum: 512, channelCount: 2)
        let refusal = try #require(effect.lastPrepareRefusal,
                                   "a sub-stencil rate was accepted — the floor is not checked")
        print("[measured] m23-dj L12 refusal — \(refusal)")
        // …and a real rate is not refused, so the check above is not simply
        // "prepare always refuses".
        let ok = StereoWidthEffect(params: StereoWidthParams(spread: 0.5))
        ok.prepare(sampleRate: 44_100, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(ok.lastPrepareRefusal == nil)
    }
}

