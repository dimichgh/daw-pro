import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `DJFilterTests` and `BitCrusherTests` both record: the main actor is ONE
// serialization point for the whole test process, these tests render hundreds
// of thousands of frames of audio, and they need no main-actor state at all.
// (There is also a hard structural reason today: `MainActorOccupancySiteTests`
// Leg C pins the `@MainActor`-isolated SUITE count at its cap with zero slack,
// so a new isolated suite would redden a gate in a different target.)
//
// The one main-actor thing an effect owns is `apply(params:)`; these tests
// construct effects with their params instead — the FXPack2 / BitCrusher /
// DJFilter precedent for a param set that never changes mid-render.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-m — the `.ringMod` insert: the input multiplied by a band-limited
/// carrier. `docs/design/2026-09-19-creative-effects.md` §6.4 is the contract
/// and §12 gate 9 names the numbers this suite has to produce ("sidebands at
/// `f ± fc` present and the carrier absent from the output").
///
/// ⭐ **Every claim is MEASURED FROM RENDERED OUTPUT, never read back from the
/// parameter.** A test that asserts `params.carrierHz == 440` proves the struct
/// stores a number. These legs Goertzel individual spectral bins out of real
/// renders, count zero crossings to recover an instantaneous frequency, and
/// compare bytes — so the plausible wrong implementations separate:
///
///  · a TREMOLO shipped as a ring modulator (`1 + c` instead of `c`)
///                                                     → L2a, measured. ⚠️ NOT
///    L2b: `x·(1+c)` leaks the INPUT, not the carrier, and L2b watches the
///    carrier's bin. The two absences are different assertions and the plant
///    proved it — L2b stayed green under the tremolo and fires on `out + k·c`.
///  · the CARRIER summed into the output (`+ k·c`)     → L2b
///  · the carrier hard-coded / `carrierHz` not wired   → L2c
///  · the fold-back "fixed" by oversampling            → L3a (the folded tone
///    is measured WHERE `foldedHz` says it lands, not merely "something differs")
///  · `inputHighCutHz` inert                           → L3b, L8
///  · the high-cut moved onto the WHOLE signal         → L3c. ⚠️ L3b renders
///    at mix 1 and cannot see it; that was found by planting, not by reading.
///  · ⭐ A NAIVE (non-band-limited) SAW/SQUARE/TRIANGLE → L4a/L4b/L4c. These
///    are the legs the design's §6.4.2 part 1 exists for, and each was proved
///    by PLANTING the naive generator and watching exactly that leg redden.
///  · the carrier phase RESET on a parameter change    → L5 (the sample-to-
///    sample delta leg); nothing else in this file can see it
///  · the per-sample increment interpolation DELETED   → L6 ONLY, MEASURED:
///    planting a true carrier step (`incrementDelta = 0`, `increment =
///    targetIncrement`) reddened 1 leg of 31. Every other leg renders with a
///    STATIC param set or a CONSTANT automated value, so all 30 stay green
///    through that deletion — and the interpolation is what earns `carrierHz`
///    its `yes` modulation verdict (rule 6.0.6).
///  · `stereoSpreadDeg` ignored                        → L7b
///  · `mix == 0` writing the buffer                    → L1a, with L1b as its
///    positive control so "bit-exact" cannot mean "inert"
///  · the oscillator PAUSED at `mix == 0`              → L1c
///  · denormal flush removed                           → L10d, but ONLY at the
///    2 048-frame silence it now uses; at 8 192 frames Float32 underflow hides
///    it and the leg passed with the flush deleted. Measured, not reasoned.
///  · a slot mis-wired in `storeAutomatedParam`        → L9
///  · the sub-audio TREMOLO RATE claim                 → L4f, and that leg is
///    here because the claim was WRONG in five shipped places: "a 2 Hz carrier
///    gives four pulses a second" is true at `mix: 1` and false at the DEFAULT
///    `mix: 0.5`. The rendered demo measured 2.00 Hz where the docs said 4.
@Suite("Ring modulator — sidebands, band-limited carrier, RT-safety (m39-m)", .serialized)
struct RingModTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (DJFilterTests conventions)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    private func constant(_ value: Float, frames: Int) -> [Float] {
        [Float](repeating: value, count: frames)
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

    /// Runs `channels` through `effect` in `chunk`-frame quanta (state
    /// continuity across quantum boundaries included in the proof).
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

    /// One mono pass through a freshly prepared ring modulator.
    private func ring(_ params: RingModParams, _ input: [Float],
                      chunk: Int = 512) throws -> [Float] {
        let effect = RingModEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// The RAW CARRIER, recovered by feeding a DC input of 1.0 at `mix: 1`.
    /// ⭐ This is the measurement trick the whole band-limiting half of this
    /// suite rests on: `out = x · c`, so with `x ≡ 1` the output IS the
    /// carrier and its spectrum can be read directly instead of inferred
    /// through a product. (The input high-cut has a DC gain of EXACTLY 1 —
    /// `(b0+b1+b2)/(1+a1+a2) = 2(1-cos w0)/2(1-cos w0)` for an RBJ low-pass —
    /// so it does not scale the result; L4d is the positive control for that.)
    private func carrierRender(_ params: RingModParams, frames: Int,
                               chunk: Int = 512) throws -> [Float] {
        var settled = params
        settled.mix = 1
        return try ring(settled, constant(1, frames: frames), chunk: chunk)
    }

    /// Standard settled analysis window — the first 8 192 frames are discarded
    /// so neither the input filter's start-up transient nor the one-quantum
    /// parameter prime is inside it.
    private static let analysisFrames = 65_536
    private static var analysisWindow: Range<Int> { 8_192..<analysisFrames }

    // MARK: - L0: the laws (the ONE HOMES the DSP, the tests and the UI read)

    @Test("L0a — the waveform index law: rounds, clamps, and survives a NaN")
    func waveformLawMatchesTheFrozenContract() {
        #expect(RingModParams.waveform(at: 0) == .sine)
        #expect(RingModParams.waveform(at: 1) == .triangle)
        #expect(RingModParams.waveform(at: 2) == .square)
        #expect(RingModParams.waveform(at: 3) == .saw)
        // `.rounded()` — the contract's word, and it is half-up at .5.
        #expect(RingModParams.waveform(at: 1.4) == .triangle)
        #expect(RingModParams.waveform(at: 1.5) == .square)
        #expect(RingModParams.waveform(at: 2.6) == .saw)
        // Out of range clamps rather than wrapping or trapping.
        #expect(RingModParams.waveform(at: -7) == .sine)
        #expect(RingModParams.waveform(at: 99) == .saw)
        // ⚠️ THE LEG THAT MATTERS: this value reaches `Int(_:)` on the RENDER
        // THREAD via `storeAutomatedParam`, which bypasses the clamping init.
        // `Int(Double.nan)` TRAPS — it does not return 0 — so deleting the
        // `isFinite` guard does not redden this test, it CRASHES the process.
        // That is the strongest possible form of "this line is load-bearing".
        #expect(RingModParams.waveform(at: .nan) == .sine)
        #expect(RingModParams.waveform(at: .infinity) == .sine)
        #expect(RingModParams.waveform(at: -.infinity) == .sine)
        // And the init SNAPS, so `fx.describe` reports the index in force.
        #expect(RingModParams(waveform: 2.7).waveform == 3)
        #expect(RingModParams(waveform: .nan).waveform == 0)
    }

    @Test("L0b — the sideband law, the fold law, and the phase-offset law")
    func spectralLawsMatchTheFrozenContract() {
        // THE law of this effect: an input partial becomes a PAIR, and neither
        // the partial nor the carrier is in that pair.
        let pair = RingModParams.sidebandsHz(inputHz: 1_000, carrierHz: 440)
        #expect(abs(pair.lower - 560) < 1e-9)
        #expect(abs(pair.upper - 1_440) < 1e-9)
        // A carrier ABOVE the partial reflects rather than going negative —
        // which is why sweeping the carrier up through a note makes the lower
        // sideband fall to 0 Hz and rise again.
        #expect(abs(RingModParams.sidebandsHz(inputHz: 200, carrierHz: 900).lower - 700) < 1e-9)
        // Fold-back: where an above-Nyquist product actually lands.
        #expect(abs(RingModParams.foldedHz(25_000, sampleRate: 48_000) - 23_000) < 1e-9)
        #expect(abs(RingModParams.foldedHz(48_000, sampleRate: 48_000) - 0) < 1e-9)
        #expect(abs(RingModParams.foldedHz(50_000, sampleRate: 48_000) - 2_000) < 1e-9)
        // Below Nyquist nothing folds — the identity half, without which the
        // law could be "always returns something plausible".
        #expect(abs(RingModParams.foldedHz(1_000, sampleRate: 48_000) - 1_000) < 1e-9)
        #expect(RingModParams.foldedHz(.nan, sampleRate: 48_000) == 0)
        // Degrees → cycles, the unit a phase accumulator wants.
        #expect(RingModParams.carrierPhaseOffsetCycles(stereoSpreadDeg: 0) == 0)
        #expect(abs(RingModParams.carrierPhaseOffsetCycles(stereoSpreadDeg: 90) - 0.25) < 1e-12)
        #expect(abs(RingModParams.carrierPhaseOffsetCycles(stereoSpreadDeg: 180) - 0.5) < 1e-12)
        #expect(RingModParams.carrierPhaseOffsetCycles(stereoSpreadDeg: .nan) == 0)
        #expect(RingModParams.carrierPhaseOffsetCycles(stereoSpreadDeg: 400) == 0.5)
    }

    // MARK: - L1: the bit-exact dry mix (rule 6.0.7)

    @Test("L1a — mix 0 is BIT-EXACT dry: not close, identical, at every waveform")
    func mixZeroIsBitExactDry() throws {
        var input = sine(220, amplitude: 0.7, frames: 20_000)
        for index in 0..<input.count where index % 3 == 0 {
            input[index] += Float(0.2 * sin(2.0 * .pi * 5_000 * Double(index) / Self.sampleRate))
        }
        for shape in 0...3 {
            let output = try ring(
                RingModParams(carrierHz: 137, mix: 0, waveform: Double(shape),
                              inputHighCutHz: 900, stereoSpreadDeg: 90),
                input)
            #expect(output == input,
                    "waveform \(shape) at mix 0 changed the buffer — it must not be touched")
        }
    }

    @Test("L1b — POSITIVE CONTROL: the identity above is the MIX, not an inert effect")
    func theBitExactClaimIsNotVacuous() throws {
        let input = sine(220, amplitude: 0.7, frames: 20_000)
        // ⭐ A bit-exact result from an effect that does nothing and one from an
        // effect correctly bypassing itself are the same bytes. This shows the
        // same effect, same input, one parameter moved, is NOT bit-exact.
        let wet = try ring(RingModParams(carrierHz: 137, mix: 1), input)
        #expect(wet != input, "mix 1 produced an identical buffer — the effect is inert")
        // And it is not merely different, it is DIFFERENT IN THE RIGHT PLACE:
        // 220 Hz is gone and 357 / 83 Hz have appeared.
        let window = 4_096..<20_000
        let inputAt220 = goertzel(input, frequency: 220, in: window)
        #expect(dB(goertzel(wet, frequency: 220, in: window) / inputAt220) < -40)
        #expect(dB(goertzel(wet, frequency: 357, in: window) / inputAt220) > -12)
        #expect(dB(goertzel(wet, frequency: 83, in: window) / inputAt220) > -12)
    }

    @Test("L1c — the carrier KEEPS RUNNING at mix 0, so raising the mix is phase-coherent")
    func theOscillatorAdvancesThroughABitExactBypass() throws {
        // Rule 6.0.7's second half, and the only leg that can see it: an effect
        // that PAUSES its oscillator during a bypass passes L1a perfectly and
        // then jumps in phase the moment the mix comes back up.
        let frames = 8 * 512
        let input = sine(300, amplitude: 0.6, frames: frames)
        let quanta = frames / 512

        func render(mixAt: (Int) -> Double) throws -> [Float] {
            let effect = RingModEffect(params: RingModParams(carrierHz: 610, mix: 0))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
            let format = try #require(AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            var output: [Float] = []
            for quantum in 0..<quanta {
                buffer.frameLength = 512
                let data = try #require(buffer.floatChannelData)
                for frame in 0..<512 { data[0][frame] = input[quantum * 512 + frame] }
                effect.storeAutomatedParam(slot: 1, value: mixAt(quantum))
                effect.process(
                    buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                    frameCount: 512)
                output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: 512))
            }
            return output
        }

        // A: bypassed for four quanta, then wet. B: wet the whole way.
        let bypassedFirst = try render { $0 < 4 ? 0 : 1 }
        let wetThroughout = try render { _ in 1 }
        // Skip the mix RAMP quantum (quantum 4) and compare what follows. If
        // the oscillator paused during the bypass, the carrier in A is four
        // quanta behind and these do not match.
        let compare = 5 * 512..<frames
        var maxDelta = 0.0
        for index in compare {
            maxDelta = max(maxDelta, abs(Double(bypassedFirst[index] - wetThroughout[index])))
        }
        print("[measured] m39-m mix-0 phase coherence, max |Δ| after re-entry: \(maxDelta)")
        #expect(maxDelta < 1e-6,
                "the carrier did not advance through the bit-exact bypass (max Δ \(maxDelta))")
        // NON-VACUITY: the signals being compared are not silence.
        #expect(wetThroughout[compare.lowerBound...].contains { abs($0) > 0.05 })
    }

    // MARK: - L2: §12 gate 9 — the sidebands, and the two ABSENCES

    @Test("L2a — sidebands at f ± fc carry the energy, and the INPUT TONE is gone")
    func sidebandsLandWhereTheLawSays() throws {
        // A sine at f times a sine at fc is EXACTLY (A/2)·[cos 2π(f-fc)t −
        // cos 2π(f+fc)t]. Both sidebands at HALF the input amplitude, and
        // nothing at f. That is an arithmetic prediction, so it is asserted as
        // a number rather than as "something changed".
        let f = 1_000.0, fc = 440.0, amplitude = 0.5
        let input = sine(f, amplitude: amplitude, frames: Self.analysisFrames)
        let output = try ring(RingModParams(carrierHz: fc, mix: 1), input)
        let window = Self.analysisWindow
        let pair = RingModParams.sidebandsHz(inputHz: f, carrierHz: fc)

        let lower = goertzel(output, frequency: pair.lower, in: window)
        let upper = goertzel(output, frequency: pair.upper, in: window)
        let residualInput = goertzel(output, frequency: f, in: window)
        print("[measured] m39-m sidebands f=\(f) fc=\(fc): "
              + "lower \(pair.lower) Hz = \(dB(lower / amplitude)) dB rel input, "
              + "upper \(pair.upper) Hz = \(dB(upper / amplitude)) dB, "
              + "residual at f = \(dB(residualInput / amplitude)) dB")
        // Predicted −6.02 dB relative to the input amplitude, on both.
        #expect(abs(dB(lower / amplitude) - (-6.0206)) < 0.15,
                "lower sideband measured \(dB(lower / amplitude)) dB, predicted -6.02")
        #expect(abs(dB(upper / amplitude) - (-6.0206)) < 0.15,
                "upper sideband measured \(dB(upper / amplitude)) dB, predicted -6.02")
        // ⛔ THE INPUT TONE IS NOT IN THE OUTPUT. A tremolo (`1 + c`) keeps it
        // at full strength, and a tremolo is the single most likely wrong
        // implementation of this effect.
        #expect(dB(residualInput / amplitude) < -55,
                "input tone survived at \(dB(residualInput / amplitude)) dB: an AM, not a ring mod")
    }

    @Test("L2b — §12 gate 9: the CARRIER is absent from the output")
    func theCarrierDoesNotLeak() throws {
        // "A ring modulator that leaks its carrier is an amplitude modulator."
        // A carrier leak means a component AT fc, which appears exactly when
        // the output contains `k·c` — i.e. when the implementation added the
        // carrier, or gave the input path a DC offset.
        let f = 1_000.0, fc = 440.0, amplitude = 0.5
        let input = sine(f, amplitude: amplitude, frames: Self.analysisFrames)
        for mix in [0.35, 0.5, 1.0] {
            let output = try ring(RingModParams(carrierHz: fc, mix: mix), input)
            let atCarrier = goertzel(output, frequency: fc, in: Self.analysisWindow)
            print("[measured] m39-m carrier leak at mix \(mix): "
                  + "\(dB(atCarrier / amplitude)) dB rel input")
            #expect(dB(atCarrier / amplitude) < -60,
                    "the carrier leaked at \(dB(atCarrier / amplitude)) dB (mix \(mix))")
        }
    }

    @Test("L2c — the sidebands MOVE with carrierHz, over three decades")
    func sidebandsTrackTheCarrier() throws {
        // A hard-coded carrier, or a `carrierHz` that never reaches the
        // oscillator, passes L2a at one setting and fails here.
        let f = 2_000.0, amplitude = 0.5
        let input = sine(f, amplitude: amplitude, frames: Self.analysisFrames)
        for fc in [5.0, 110.0, 440.0, 1_200.0, 4_800.0] {
            let output = try ring(RingModParams(carrierHz: fc, mix: 1), input)
            let pair = RingModParams.sidebandsHz(inputHz: f, carrierHz: fc)
            let lower = goertzel(output, frequency: pair.lower, in: Self.analysisWindow)
            // And a DECOY bin: where a carrier of 440 would have put it. At
            // fc = 440 the decoy IS the real one, so it is skipped there.
            let decoy = fc == 440
                ? lower
                : goertzel(output, frequency: abs(f - 440), in: Self.analysisWindow)
            print("[measured] m39-m carrier \(fc) Hz → lower sideband "
                  + "\(pair.lower) Hz at \(dB(lower / amplitude)) dB "
                  + "(decoy 1560 Hz at \(dB(decoy / amplitude)) dB)")
            #expect(abs(dB(lower / amplitude) - (-6.0206)) < 0.35,
                    "carrier \(fc): sideband measured \(dB(lower / amplitude)) dB")
            if fc != 440 {
                #expect(dB(decoy / amplitude) < -40,
                        "energy at the 440 Hz-carrier position while the carrier is \(fc)")
            }
        }
    }

    // MARK: - L3: fold-back is REAL, is WHERE the law says, and is CONTROLLABLE

    @Test("L3a — an above-Nyquist product FOLDS BACK to exactly foldedHz (not oversampled away)")
    func foldBackLandsWhereTheLawSays() throws {
        // ⛔ Design §6.4.2 part 2: this is deliberately NOT oversampled away.
        // f = 20 kHz, fc = 5 kHz ⇒ the upper sideband is 25 kHz, above the
        // 24 kHz Nyquist, and lands at 48000 − 25000 = 23 000 Hz.
        let f = 20_000.0, fc = 5_000.0, amplitude = 0.5
        let input = sine(f, amplitude: amplitude, frames: Self.analysisFrames)
        let output = try ring(RingModParams(carrierHz: fc, mix: 1), input)
        let pair = RingModParams.sidebandsHz(inputHz: f, carrierHz: fc)
        let foldedTo = RingModParams.foldedHz(pair.upper, sampleRate: Self.sampleRate)
        #expect(abs(foldedTo - 23_000) < 1e-9)

        let folded = goertzel(output, frequency: foldedTo, in: Self.analysisWindow)
        let lower = goertzel(output, frequency: pair.lower, in: Self.analysisWindow)
        // A DECOY at the un-folded position, which cannot be represented and
        // must read as nothing beyond the folded tone's own skirt.
        print("[measured] m39-m fold-back: upper sideband \(pair.upper) Hz lands at "
              + "\(foldedTo) Hz at \(dB(folded / amplitude)) dB; "
              + "lower \(pair.lower) Hz at \(dB(lower / amplitude)) dB")
        #expect(dB(folded / amplitude) > -14,
                "the folded tone is missing (\(dB(folded / amplitude)) dB): something filtered it")
        #expect(dB(lower / amplitude) > -14)
    }

    @Test("L3b — inputHighCutHz REMOVES the fold-back while sparing the low sidebands")
    func theHighCutIsTheFoldBackControl() throws {
        // The two-tone input is the point: 300 Hz (well inside any high-cut)
        // plus 20 kHz (the partial that folds). Pulling the high-cut to 4 kHz
        // must kill the FOLDED tone and leave the 300 Hz sidebands standing —
        // a build where `inputHighCutHz` is inert fails the first half, and one
        // where the filter sits on the WHOLE signal fails the second.
        let low = 300.0, high = 20_000.0, fc = 5_000.0
        var input = sine(low, amplitude: 0.45, frames: Self.analysisFrames)
        let bright = sine(high, amplitude: 0.45, frames: Self.analysisFrames)
        for index in 0..<input.count { input[index] += bright[index] }

        let foldedTo = RingModParams.foldedHz(high + fc, sampleRate: Self.sampleRate)
        let lowSideband = RingModParams.sidebandsHz(inputHz: low, carrierHz: fc).upper

        let open = try ring(RingModParams(carrierHz: fc, mix: 1, inputHighCutHz: 20_000), input)
        let cut = try ring(RingModParams(carrierHz: fc, mix: 1, inputHighCutHz: 4_000), input)

        let foldOpen = goertzel(open, frequency: foldedTo, in: Self.analysisWindow)
        let foldCut = goertzel(cut, frequency: foldedTo, in: Self.analysisWindow)
        let keepOpen = goertzel(open, frequency: lowSideband, in: Self.analysisWindow)
        let keepCut = goertzel(cut, frequency: lowSideband, in: Self.analysisWindow)
        print("[measured] m39-m high-cut: folded tone at \(foldedTo) Hz "
              + "\(dB(foldOpen)) dB open → \(dB(foldCut)) dB at 4 kHz "
              + "(Δ \(dB(foldCut / foldOpen)) dB); 300 Hz sideband at \(lowSideband) Hz "
              + "\(dB(keepOpen)) → \(dB(keepCut)) dB (Δ \(dB(keepCut / keepOpen)) dB)")
        #expect(dB(foldCut / foldOpen) < -40,
                "the high-cut only removed \(dB(foldCut / foldOpen)) dB of fold-back")
        #expect(abs(dB(keepCut / keepOpen)) < 0.5,
                "high-cut moved the 300 Hz sideband \(dB(keepCut / keepOpen)) dB: not a PRE-filter")
    }

    @Test("L3c — the high-cut is a PRE-filter: at mix < 1 the DRY path keeps its top end")
    func theHighCutSparesTheDryPath() throws {
        // ⚠️ L3b CANNOT SEE THIS and said it could, which was found by planting
        // the whole-signal filter and watching L3b stay green: L3b renders at
        // `mix: 1`, where there is no dry path to spare. This leg renders at
        // `mix: 0.5` with a 15 kHz probe and a 4 kHz high-cut. The wet path puts
        // its energy at 15 000 ± carrier, so whatever sits at EXACTLY 15 kHz is
        // the dry signal and nothing else.
        let probe = 15_000.0, amplitude = 0.5
        let input = sine(probe, amplitude: amplitude, frames: Self.analysisFrames)
        let output = try ring(
            RingModParams(carrierHz: 617, mix: 0.5, inputHighCutHz: 4_000), input)
        let atProbe = goertzel(output, frequency: probe, in: Self.analysisWindow)
        // Predicted: the dry half, untouched. −6.02 dB.
        let section = EQFilterResponse.cutSection(
            highPass: false, freq: 4_000, q: EQFilterResponse.butterworth2Q,
            sampleRate: Self.sampleRate)
        let ifFiltered = EQFilterResponse.magnitudeDb(
            section, frequency: probe, sampleRate: Self.sampleRate) - 6.0206
        print("[measured] m39-m dry path at 15 kHz through a 4 kHz high-cut: "
              + "\(dB(atProbe / amplitude)) dB; PRE-filter predicts -6.02, "
              + "a whole-signal filter predicts \(ifFiltered)")
        #expect(abs(dB(atProbe / amplitude) - (-6.0206)) < 0.3,
                "the dry path measured \(dB(atProbe / amplitude)) dB: the high-cut is not a PRE-filter")
    }

    // MARK: - L4: the carrier's own harmonics are BAND-LIMITED (§6.4.2 part 1)
    //
    // ⭐⭐ THESE ARE THE LEGS THE DESIGN'S FIRST ALIASING RULE EXISTS FOR, and
    // each one was proved by PLANTING the naive generator in `RingModEffect
    // .carrier` and confirming that exactly this leg reddened. The measurement
    // rests on `carrierRender`: with a DC input of 1.0 at mix 1 the output IS
    // the carrier, so its harmonics and their aliases read directly.
    //
    // ⚠️ TWO THINGS ABOUT THE MEASUREMENT, BOTH OF WHICH WERE WRONG IN THE
    // FIRST DRAFT AND SET A FALSE FLOOR:
    //
    // 1. THE CARRIER IS AN EXACT BIN of the analysis window. 57 344 frames at
    //    48 kHz gives 0.8371 Hz bins, and a round 2 917 Hz sits between two of
    //    them — so the FUNDAMENTAL leaks into every bin the probe scans and the
    //    measured "alias floor" bottoms out around −64 dB no matter what the
    //    oscillator does. A pure SINE carrier read −64 dB of "alias", which is
    //    how the leak was caught. `3485 · 48000 / 57344` is an exact bin, and
    //    because 48 000 Hz is itself bin 57 344, every FOLDED harmonic of it is
    //    an exact bin too. The floor then drops to the Float32 storage noise.
    //    It is still an awkward number (2 917.08 Hz) rather than a round one,
    //    for the original reason: it shares no small factor with the sample
    //    rate, so aliases land BETWEEN the legitimate harmonics where a single
    //    Goertzel bin can tell them apart. A round 3 000 Hz would have hidden
    //    every alias underneath a real harmonic and made all four waveforms
    //    look band-limited.
    //
    // 2. ⭐ THE SCORE IS THE WORST ALIAS **IN THE AUDIBLE BAND**, not the worst
    //    anywhere. The largest aliases from any of these shapes are the
    //    harmonics just above Nyquist folding to just below it — 21–24 kHz,
    //    which nobody hears. Scoring those would have condemned a perfectly
    //    good oscillator for inaudible content and, worse, would have hidden
    //    the real difference: in the band people actually hear, PolyBLEP buys
    //    15–19 dB over a naive generator, while across the whole spectrum it
    //    looks like 8.
    private static let aliasCarrier = 3_485.0 * 48_000.0 / 57_344.0   // 2 917.08 Hz
    /// Aliases above this are real but inaudible; see note 2 above.
    private static let audibleCeilingHz = 16_000.0

    /// The worst AUDIBLE alias in the output, and the fundamental, both in dB.
    /// Harmonics up to Nyquist are LEGITIMATE and excluded; everything above
    /// has folded and is aliasing.
    private func aliasFloorDb(_ carrier: [Float]) -> (fundamental: Double, worstAlias: Double,
                                                      at: Double) {
        let window = Self.analysisWindow
        let fundamental = goertzel(carrier, frequency: Self.aliasCarrier, in: window)
        let firstFolded = Int((Self.sampleRate / 2 / Self.aliasCarrier).rounded(.up))
        var worst = 0.0
        var worstAt = 0.0
        for harmonic in firstFolded...240 {
            let folded = RingModParams.foldedHz(
                Double(harmonic) * Self.aliasCarrier, sampleRate: Self.sampleRate)
            guard folded > 40, folded < Self.audibleCeilingHz else { continue }
            // Skip anything that folded onto a LEGITIMATE harmonic's bin — that
            // energy is the harmonic, not an alias.
            let onALegitimateHarmonic = (1..<firstFolded).contains {
                abs(Double($0) * Self.aliasCarrier - folded) < 30
            }
            guard !onALegitimateHarmonic else { continue }
            let magnitude = goertzel(carrier, frequency: folded, in: window)
            if magnitude > worst {
                worst = magnitude
                worstAt = folded
            }
        }
        return (dB(fundamental), dB(worst / fundamental), worstAt)
    }

    @Test("L4a — the SAW carrier is band-limited: PolyBLEP, not a raw ramp")
    func sawCarrierIsBandLimited() throws {
        let rendered = try carrierRender(
            RingModParams(carrierHz: Self.aliasCarrier, waveform: 3),
            frames: Self.analysisFrames)
        let (fundamental, worst, at) = aliasFloorDb(rendered)
        print("[measured] m39-m saw carrier: fundamental \(fundamental) dB, "
              + "worst AUDIBLE alias \(worst) dB at \(at) Hz")
        // ⭐ PLANTED, and this is the number that justifies the threshold:
        // `return 2 * phase - 1` with the polyBLEP term deleted measures its
        // worst audible alias at −20.8 dB — the 1/n of a raw ramp, plainly
        // audible. PolyBLEP measures about −36. −30 sits between them with
        // ~9 dB of margin on the passing side and ~9 dB on the failing side.
        #expect(worst < -30,
                "worst saw alias is \(worst) dB at \(at) Hz: the carrier is not band-limited")
        // NON-VACUITY: the fundamental is really there, so "no alias" cannot
        // mean "no signal".
        #expect(fundamental > -12, "the carrier itself measured \(fundamental) dB")
    }

    @Test("L4b — the SQUARE carrier is band-limited: PolyBLEP on both edges")
    func squareCarrierIsBandLimited() throws {
        let rendered = try carrierRender(
            RingModParams(carrierHz: Self.aliasCarrier, waveform: 2),
            frames: Self.analysisFrames)
        let (fundamental, worst, at) = aliasFloorDb(rendered)
        print("[measured] m39-m square carrier: fundamental \(fundamental) dB, "
              + "worst AUDIBLE alias \(worst) dB at \(at) Hz")
        // ⭐ PLANTED: a raw `phase < 0.5 ? 1 : -1` — the `sign(sin)` square the
        // design explicitly refuses — measures its worst audible alias at
        // −20.8 dB against PolyBLEP's −36.
        #expect(worst < -30,
                "worst square alias is \(worst) dB at \(at) Hz — this is a sign(sin) square")
        #expect(fundamental > -12)
    }

    @Test("L4c — the TRIANGLE carrier is band-limited: PolyBLAMP on both corners")
    func triangleCarrierIsBandLimited() throws {
        let rendered = try carrierRender(
            RingModParams(carrierHz: Self.aliasCarrier, waveform: 1),
            frames: Self.analysisFrames)
        let (fundamental, worst, at) = aliasFloorDb(rendered)
        print("[measured] m39-m triangle carrier: fundamental \(fundamental) dB, "
              + "worst AUDIBLE alias \(worst) dB at \(at) Hz")
        // A triangle's harmonics fall as 1/n², so a NAIVE one is far less
        // violent than a naive saw — which is exactly why it needs its own
        // threshold rather than the saw's, and why "it sounds fine" is not a
        // test. ⭐ PLANTED: the naive triangle (the polyBLAMP terms deleted)
        // measures −41.7 dB against PolyBLAMP's −57.
        #expect(worst < -48,
                "worst triangle alias is \(worst) dB at \(at) Hz — the corners are not rounded")
        #expect(fundamental > -12)
    }

    @Test("L4d — POSITIVE CONTROL: a SINE carrier has no harmonics at all, and DC gain is 1")
    func theAliasProbeReadsACleanCarrierAsClean() throws {
        // ⭐ Without this, "worst alias < −30 dB" could be reporting a probe
        // that cannot see anything. A sine carrier is the reference: it has ONE
        // partial, so every bin the probe scans must read as nothing.
        let rendered = try carrierRender(
            RingModParams(carrierHz: Self.aliasCarrier, waveform: 0),
            frames: Self.analysisFrames)
        let (fundamental, worst, at) = aliasFloorDb(rendered)
        print("[measured] m39-m sine carrier: fundamental \(fundamental) dB, "
              + "worst bin \(worst) dB at \(at) Hz")
        // ⚠️ THIS LEG CAUGHT THE PROBE'S OWN FLOOR. With a non-bin carrier it
        // read −64 dB of "alias" from a signal that has exactly one partial —
        // which would have been recorded as the oscillator's noise floor and
        // was actually the Goertzel leaking the fundamental. See the note above
        // `aliasCarrier`.
        #expect(worst < -100, "a sine carrier showed \(worst) dB at \(at) Hz")
        // And the DC-gain-1 claim `carrierRender` rests on: a unit DC input
        // produces a unit-amplitude carrier, so the fundamental of a sine is
        // −6.02 dB (amplitude 0.5 in the Goertzel's ±peak convention is 1.0
        // peak → the bin reads 1.0; dB(1) = 0).
        #expect(abs(fundamental) < 0.1,
                "the DC path is not unity — the carrier measured \(fundamental) dB")
    }

    @Test("L4e — every waveform peaks at ±1, so a shape change is a timbre change")
    func waveformsSharePeakAmplitude() throws {
        var peaks: [Double] = []
        for shape in 0...3 {
            let rendered = try carrierRender(
                RingModParams(carrierHz: 220, waveform: Double(shape)), frames: 16_384)
            let peak = rendered[4_096...].map { abs(Double($0)) }.max() ?? 0
            peaks.append(peak)
        }
        print("[measured] m39-m carrier peaks (sine/tri/square/saw): \(peaks)")
        for (shape, peak) in peaks.enumerated() {
            #expect(abs(peak - 1) < 0.02,
                    "waveform \(shape) peaks at \(peak), not ±1 — a shape switch would jump level")
        }
    }

    // MARK: - L4f: the SUB-AUDIO region, where the teaching text was WRONG

    @Test("L4f — a sub-audio carrier is a TREMOLO, and its RATE depends on mix")
    func subAudioCarrierTremoloRateDependsOnMix() throws {
        // ⚠️⚠️ THIS LEG EXISTS BECAUSE I ASSERTED THE WRONG NUMBER IN FIVE
        // PLACES AND THE RENDERED DEMO CAUGHT IT. The claim was "a 2 Hz sine
        // carrier gives FOUR pulses a second, because the carrier crosses zero
        // twice per cycle". That is true at `mix: 1` and FALSE at the DEFAULT
        // `mix: 0.5`, which is the setting a user will actually meet first.
        //
        // The arithmetic, once written down: the output is
        // `x · (mix·c + (1 − mix))`, so the envelope factor is
        // `|mix·c + (1 − mix)|`. That expression goes NEGATIVE — and therefore
        // gets rectified into a doubled pulse — only when `mix > 0.5`. At
        // exactly 0.5 it grazes zero once per cycle and the heard rate is the
        // CARRIER rate. Below 0.5 it never reaches zero at all: a shallower
        // tremolo, still at the carrier rate.
        //
        // The measurement is the RECTIFIED ENVELOPE's own dominant frequency,
        // which is what "pulses per second" means to a listener.
        let carrier = 2.0
        let frames = 8 * 48_000
        let input = sine(220, amplitude: 0.7, frames: frames)

        func envelopeRateHz(mix: Double) throws -> Double {
            let output = try ring(RingModParams(carrierHz: carrier, mix: mix), input)
            // Rectify and decimate to a 200 Hz envelope, mean-removed.
            let step = 240
            var envelope: [Double] = []
            var start = 48_000                      // skip the prime quantum
            while start + step < frames {
                var sum = 0.0
                for index in start..<(start + step) { sum += abs(Double(output[index])) }
                envelope.append(sum / Double(step))
                start += step
            }
            let mean = envelope.reduce(0, +) / Double(envelope.count)
            for index in envelope.indices { envelope[index] -= mean }
            // Scan the envelope's own spectrum for its strongest component.
            var bestRate = 0.0
            var best = 0.0
            var rate = 0.5
            while rate <= 12.0 {
                let w = 2 * Double.pi * rate / 200.0
                let k = 2 * cos(w)
                var s1 = 0.0, s2 = 0.0
                for value in envelope { let s0 = value + k * s1 - s2; s2 = s1; s1 = s0 }
                let magnitude = max(s1 * s1 + s2 * s2 - k * s1 * s2, 0).squareRoot()
                if magnitude > best { best = magnitude; bestRate = rate }
                rate += 0.05
            }
            return bestRate
        }

        let atHalf = try envelopeRateHz(mix: 0.5)
        let atFull = try envelopeRateHz(mix: 1.0)
        let atQuarter = try envelopeRateHz(mix: 0.25)
        print("[measured] m39-m sub-audio tremolo rate from a \(carrier) Hz carrier — "
              + "mix 0.25: \(atQuarter) Hz, mix 0.5 (the DEFAULT): \(atHalf) Hz, "
              + "mix 1.0: \(atFull) Hz")
        #expect(abs(atQuarter - carrier) < 0.15, "mix 0.25 pulsed at \(atQuarter) Hz")
        #expect(abs(atHalf - carrier) < 0.15,
                "mix 0.5 pulsed at \(atHalf) Hz, not the carrier rate \(carrier)")
        #expect(abs(atFull - 2 * carrier) < 0.15,
                "mix 1.0 pulsed at \(atFull) Hz, not the doubled rate \(2 * carrier)")
    }

    // MARK: - L5: phase continuity across a carrierHz change (§6.4.1's `yes`)

    @Test("L5 — a carrierHz change is a FREQUENCY step, never a phase discontinuity")
    func phaseIsContinuousAcrossACarrierChange() throws {
        // ⚠️ The ONLY leg that can see a phase reset. Everything else in this
        // file either holds the carrier still or measures a spectrum, and a
        // spectrum measured over 65 k frames barely notices one click.
        //
        // With a DC input at mix 1 the output IS the carrier, so a phase
        // discontinuity is visible as a single oversized sample-to-sample step.
        let quanta = 12
        let frames = quanta * 512
        let effect = RingModEffect(params: RingModParams(carrierHz: 100, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var output: [Float] = []
        for quantum in 0..<quanta {
            buffer.frameLength = 512
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<512 { data[0][frame] = 1 }
            // Four carrier changes, each a large jump.
            effect.storeAutomatedParam(slot: 0, value: [100.0, 700.0, 250.0, 900.0][quantum % 4])
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: 512)
            output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: 512))
        }
        // The largest legitimate step: a 900 Hz sine advances 2π·900/48000 =
        // 0.1178 per sample at its steepest. A phase RESET jumps by up to 2.0.
        var maxStep = 0.0
        var maxStepAt = 0
        for index in 1..<frames {
            let step = abs(Double(output[index] - output[index - 1]))
            if step > maxStep { maxStep = step; maxStepAt = index }
        }
        print("[measured] m39-m max carrier sample-to-sample step across four "
              + "carrier changes: \(maxStep) at frame \(maxStepAt) "
              + "(a 900 Hz sine's own maximum is 0.1178)")
        // PLANTED: `carrierPhase = 0` added to `deriveRenderParams` takes this
        // to ~1.4 and reddens nothing else in the file.
        #expect(maxStep < 0.15, "a phase discontinuity of \(maxStep) at frame \(maxStepAt)")
        #expect(output.allSatisfy { $0.isFinite })
    }

    // MARK: - L6: the per-sample increment interpolation (rule 6.0.6)

    @Test("L6 — a carrierHz STEP is RAMPED across the quantum, not applied at frame 0")
    func theCarrierIncrementIsSmoothedAcrossTheQuantum() throws {
        // ⚠️⚠️ THE ONE LEG THAT SEES THE SMOOTHING. Everything above renders
        // with a static param set or a constant automated value, so a build
        // with `previousIncrement = targetIncrement` written at the top of
        // `process` — the interpolation deleted outright — passes every one of
        // them. §6.4.1 grants `carrierHz` a `yes` modulation verdict BECAUSE a
        // swept carrier does not zipper; an ungated mandate is a comment.
        //
        // The discriminator is CYCLES COMPLETED inside the step quantum, read
        // as zero crossings. Ramping 100 → 700 Hz linearly over 512 frames at
        // 48 kHz completes (100+700)/2 × 512/48000 = 4.27 cycles ⇒ ~8.5
        // crossings. Stepping straight to 700 Hz completes 7.47 cycles ⇒ ~14.9.
        // The two cannot be confused.
        let quanta = 10
        let stepQuantum = 8
        let effect = RingModEffect(params: RingModParams(carrierHz: 100, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var output: [Float] = []
        for quantum in 0..<quanta {
            buffer.frameLength = 512
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<512 { data[0][frame] = 1 }
            effect.storeAutomatedParam(slot: 0, value: quantum < stepQuantum ? 100 : 700)
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: 512)
            output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: 512))
        }

        func crossings(_ range: Range<Int>) -> Int {
            var count = 0
            for index in range.lowerBound + 1..<range.upperBound
            where (output[index] >= 0) != (output[index - 1] >= 0) { count += 1 }
            return count
        }
        let stepRange = stepQuantum * 512..<(stepQuantum + 1) * 512
        let settledRange = (stepQuantum + 1) * 512..<(stepQuantum + 2) * 512
        let held = crossings((stepQuantum - 1) * 512..<stepQuantum * 512)
        let ramped = crossings(stepRange)
        let settled = crossings(settledRange)
        print("[measured] m39-m carrier-step smoothing — zero crossings per 512-frame "
              + "quantum: held@100Hz \(held) (predicted 2), RAMP quantum \(ramped) "
              + "(predicted ~8.5 smoothed / ~14.9 stepped), settled@700Hz \(settled) "
              + "(predicted ~14.9)")
        #expect(held <= 3, "the held quantum is not running at 100 Hz (\(held) crossings)")
        #expect((7...11).contains(ramped),
                "step quantum shows \(ramped) crossings; smoothed ~8.5, deleted interpolation ~14.9")
        #expect(settled >= 13, "the quantum after the step is not at 700 Hz (\(settled))")
    }

    // MARK: - L7: stereo

    @Test("L7a — stereoSpreadDeg 0 leaves the two channels IDENTICAL (mono-safe by default)")
    func zeroSpreadIsMonoSafe() throws {
        let signal = sine(440, amplitude: 0.6, frames: 16_384)
        let effect = RingModEffect(params: RingModParams(carrierHz: 137, mix: 0.7))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let stereo = try processChunked(effect, channels: [signal, signal])
        #expect(stereo[0] == stereo[1],
                "the default spread of 0 produced different channels — it is not mono-safe")
        // And each channel matches a MONO render, which is only true if the two
        // channels keep separate filter state.
        let mono = try ring(RingModParams(carrierHz: 137, mix: 0.7), signal)
        #expect(stereo[0] == mono)
    }

    @Test("L7b — stereoSpreadDeg 180 puts the carriers in ANTIPHASE: R == −L at mix 1")
    func fullSpreadInvertsTheRightCarrier() throws {
        // A build that ignores `stereoSpreadDeg` passes L7a perfectly and
        // fails here; a build that treats degrees as radians lands nowhere near
        // antiphase.
        let signal = sine(440, amplitude: 0.6, frames: 16_384)
        let effect = RingModEffect(params: RingModParams(
            carrierHz: 137, mix: 1, stereoSpreadDeg: 180))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let stereo = try processChunked(effect, channels: [signal, signal])
        var maxResidual = 0.0
        var peak = 0.0
        for index in 4_096..<16_384 {
            maxResidual = max(maxResidual, abs(Double(stereo[0][index] + stereo[1][index])))
            peak = max(peak, abs(Double(stereo[0][index])))
        }
        print("[measured] m39-m spread 180: max |L + R| = \(maxResidual) against a "
              + "peak of \(peak)")
        #expect(peak > 0.1, "the render is silent — the antiphase claim would be vacuous")
        #expect(maxResidual < peak * 1e-4,
                "R is not the inverse of L (residual \(maxResidual) vs peak \(peak))")
        // 90° is NEITHER identical nor inverted — the in-between is real.
        let quarter = RingModEffect(params: RingModParams(
            carrierHz: 137, mix: 1, stereoSpreadDeg: 90))
        quarter.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let quartered = try processChunked(quarter, channels: [signal, signal])
        #expect(quartered[0] != quartered[1])
        var quarterResidual = 0.0
        for index in 4_096..<16_384 {
            quarterResidual = max(quarterResidual,
                                  abs(Double(quartered[0][index] + quartered[1][index])))
        }
        #expect(quarterResidual > peak * 0.1,
                "a 90 degree spread behaved like 180 degrees")
    }

    // MARK: - L8: the input high-cut's MEASURED response, including the default

    @Test("L8 — the pre-filter is a 2-pole Butterworth, and the default's droop is stated")
    func inputHighCutMatchesItsPredictedResponse() throws {
        // The filter is on the CARRIER PATH, so its response shows up in the
        // sideband amplitude: `|H(f)| · A/2`. Predicted from
        // `EQFilterResponse.magnitudeDb` — the same declared home the DSP reads
        // its coefficients from — so this is a prediction-vs-render pin, not a
        // golden number nobody can re-derive.
        let fc = 440.0, amplitude = 0.5
        for (highCut, probe) in [(20_000.0, 1_000.0), (20_000.0, 10_000.0),
                                 (20_000.0, 15_000.0), (4_000.0, 1_000.0),
                                 (4_000.0, 8_000.0), (500.0, 2_000.0)] {
            let input = sine(probe, amplitude: amplitude, frames: Self.analysisFrames)
            let output = try ring(
                RingModParams(carrierHz: fc, mix: 1, inputHighCutHz: highCut), input)
            let pair = RingModParams.sidebandsHz(inputHz: probe, carrierHz: fc)
            let measured = goertzel(output, frequency: pair.lower, in: Self.analysisWindow)
            let section = EQFilterResponse.cutSection(
                highPass: false, freq: highCut, q: EQFilterResponse.butterworth2Q,
                sampleRate: Self.sampleRate)
            let predicted = EQFilterResponse.magnitudeDb(
                section, frequency: probe, sampleRate: Self.sampleRate) - 6.0206
            let measuredDb = dB(measured / amplitude)
            print("[measured] m39-m pre-filter @\(Int(highCut)) Hz, probe \(Int(probe)) Hz: "
                  + "sideband \(measuredDb) dB, predicted \(predicted) dB")
            #expect(abs(measuredDb - predicted) < 0.35,
                    "high-cut \(highCut) at \(probe) Hz: measured \(measuredDb), predicted \(predicted)")
        }
    }

    // MARK: - L9: the automation slot map (§12 gate 3's render-side half)

    @Test("L9 — storeAutomatedParam drives the RIGHT parameter per slot, and bad input is inert")
    func automationSlotsAreWiredToTheRightParameters() throws {
        // `EffectParamSpec.specs(for: .ringMod)` order is 0 carrierHz, 1 mix,
        // 2 waveform, 3 inputHighCutHz, 4 stereoSpreadDeg. A transposed pair
        // here re-points every saved automation lane on every shipped insert.
        let frames = 32_768
        let f = 2_000.0, amplitude = 0.5
        let input = sine(f, amplitude: amplitude, frames: frames)
        let window = 8_192..<frames

        func automated(slot: Int, value: Double) throws -> [Float] {
            let effect = RingModEffect(params: RingModParams(
                carrierHz: 440, mix: 1, waveform: 0, inputHighCutHz: 20_000,
                stereoSpreadDeg: 0))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
            let format = try #require(AVAudioFormat(
                standardFormatWithSampleRate: Self.sampleRate, channels: 1))
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            var output: [Float] = []
            var offset = 0
            while offset < frames {
                buffer.frameLength = 512
                let data = try #require(buffer.floatChannelData)
                for frame in 0..<512 { data[0][frame] = input[offset + frame] }
                effect.storeAutomatedParam(slot: slot, value: value)
                effect.process(
                    buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                    frameCount: 512)
                output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: 512))
                offset += 512
            }
            return output
        }

        // Slot 0 → carrierHz. 1 200 Hz moves the lower sideband to 800 Hz.
        let slot0 = try automated(slot: 0, value: 1_200)
        #expect(dB(goertzel(slot0, frequency: 800, in: window) / amplitude) > -8)
        #expect(dB(goertzel(slot0, frequency: 1_560, in: window) / amplitude) < -40,
                "slot 0 did not move the carrier off 440 Hz")
        // Slot 1 → mix. 0 is the bit-exact bypass, so the INPUT survives.
        let slot1 = try automated(slot: 1, value: 0)
        #expect(slot1 == input, "slot 1 is not mix")
        // Slot 2 → waveform. A saw carrier puts a sideband pair around the
        // SECOND carrier harmonic (880 Hz) that a sine carrier cannot produce.
        let slot2 = try automated(slot: 2, value: 3)
        #expect(dB(goertzel(slot2, frequency: 2_000 - 880, in: window) / amplitude) > -22,
                "slot 2 is not waveform — no second-harmonic sideband appeared")
        // Slot 3 → inputHighCutHz. 500 Hz kills a 2 kHz probe entirely.
        let slot3 = try automated(slot: 3, value: 500)
        #expect(dB(goertzel(slot3, frequency: 1_560, in: window) / amplitude) < -25,
                "slot 3 is not the input high-cut")
        // Slot 4 → stereoSpreadDeg, inaudible on mono: the render must be
        // IDENTICAL to the un-automated one, which is the honest assertion.
        let slot4 = try automated(slot: 4, value: 180)
        let reference = try automated(slot: 9, value: 0)  // out of range ⇒ inert
        #expect(slot4 == reference, "slot 4 changed a MONO render")
        // Out-of-range slots and non-finite values are inert, not crashes.
        for (slot, value) in [(0, Double.nan), (2, Double.nan), (-1, 1.0), (5, 1.0),
                              (0, Double.infinity), (3, -Double.infinity)] {
            let guarded = try automated(slot: slot, value: value)
            #expect(guarded.allSatisfy { $0.isFinite },
                    "slot \(slot) value \(value) produced a non-finite render")
        }
    }

    // MARK: - L10: determinism, latency, denormals

    @Test("L10a — two identical renders are bit-identical, at every waveform")
    func rendersAreDeterministic() throws {
        let input = sine(330, amplitude: 0.55, frames: 12_000)
        for shape in 0...3 {
            let params = RingModParams(carrierHz: 617, mix: 0.6, waveform: Double(shape),
                                       inputHighCutHz: 7_000, stereoSpreadDeg: 45)
            #expect(try ring(params, input) == (try ring(params, input)))
        }
    }

    @Test("L10b — a static render is identical at 128, 256, 512 and 1024-frame quanta")
    func renderIsBlockSizeInvariant() throws {
        // With a static param set every interpolation delta is zero, so the
        // only remaining block-size coupling would be a bug: a coefficient
        // stride that reads the wrong endpoint, or a phase that restarts at a
        // quantum boundary.
        let input = sine(330, amplitude: 0.55, frames: 12_288)
        let params = RingModParams(carrierHz: 617, mix: 0.6, waveform: 2,
                                   inputHighCutHz: 7_000)
        let reference = try ring(params, input, chunk: 512)
        for chunk in [128, 256, 1_024] {
            #expect(try ring(params, input, chunk: chunk) == reference,
                    "the render changed at a \(chunk)-frame quantum")
        }
    }

    @Test("L10c — the ring modulator reports ZERO added latency (rule 6.0.9)")
    func latencyIsZero() {
        #expect(RingModEffect(params: RingModParams()).latencySamples == 0)
    }

    @Test("L10d — the tail lands on EXACT zero FAST, which is the denormal flush")
    func theTailFlushesToZero() throws {
        // The input high-cut is a recursive filter; at its 500 Hz minimum the
        // poles sit at radius ~0.955, so an un-flushed build idles in SUBNORMAL
        // territory for thousands of samples after every fade-out — on the
        // render thread, during silence, which is exactly when nobody is
        // looking.
        //
        // ⚠️ THE SILENCE LENGTH IS THE WHOLE TEST, and the first draft got it
        // wrong. With an 8 192-frame tail the state reaches ~1e-165 on its own,
        // which UNDERFLOWS Float32 to exactly 0 whether or not anything flushed
        // it — so the leg passed with the flush deleted outright (PLANTED and
        // confirmed). 2 048 frames is inside the window where the two builds
        // differ: flushed reaches exact zero at ~1 230 frames, un-flushed is
        // still carrying ~3e-42, which Float32 represents.
        let loud = sine(200, amplitude: 1, frames: 4_096)
        let silence = [Float](repeating: 0, count: 2_048)
        let output = try ring(
            RingModParams(carrierHz: 300, mix: 1, inputHighCutHz: 500), loud + silence)
        #expect(output.allSatisfy { $0.isFinite })
        let tail = output[(output.count - 384)...]
        let worst = tail.map { abs($0) }.max() ?? 0
        print("[measured] m39-m denormal flush — max |tail| over the last 384 frames "
              + "of a 2 048-frame silence: \(worst)")
        #expect(tail.allSatisfy { $0 == 0 },
                "the tail never reached exact zero; max |tail| \(worst)")
        // NON-VACUITY: the loud part was not silent either.
        #expect(output[1_024..<4_096].contains { abs($0) > 0.1 })
    }

    @Test("L10e — non-finite and out-of-range PARAMETERS cannot poison the oscillator")
    func badParametersAreFenced() throws {
        let input = sine(400, amplitude: 0.5, frames: 8_192)
        for params in [
            RingModParams(carrierHz: .nan, mix: .nan, waveform: .nan,
                          inputHighCutHz: .nan, stereoSpreadDeg: .nan),
            RingModParams(carrierHz: .infinity, mix: 99, waveform: -99,
                          inputHighCutHz: 1e12, stereoSpreadDeg: -1e9),
            RingModParams(carrierHz: -1e9, mix: -5, waveform: 1e9,
                          inputHighCutHz: -0, stereoSpreadDeg: 1e9),
        ] {
            let output = try ring(params, input)
            #expect(output.allSatisfy { $0.isFinite },
                    "a fenced parameter set produced a non-finite render")
        }
    }

    @Test("L10f — a 20 kHz high-cut stays stable at a 32 kHz project rate")
    func theHighCutSurvivesALowProjectRate() throws {
        // 20 kHz is ABOVE the 16 kHz Nyquist of a 32 kHz project, where an
        // unclamped coefficient derivation runs past its asymptote. The clamp
        // lives in `EQFilterResponse.cutSection` (`min(freq, sampleRate · 0.49)`),
        // which is why the DSP does not carry its own.
        let frames = 8_192
        let effect = RingModEffect(params: RingModParams(carrierHz: 900, mix: 1,
                                                        inputHighCutHz: 20_000))
        effect.prepare(sampleRate: 32_000, maxFramesPerQuantum: 512, channelCount: 1)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 32_000,
                                                channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var peak: Float = 0
        var offset = 0
        while offset < frames {
            buffer.frameLength = 512
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<512 {
                data[0][frame] = Float(0.5 * sin(2.0 * .pi * 500 * Double(offset + frame) / 32_000))
            }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: 512)
            for frame in 0..<512 {
                #expect(data[0][frame].isFinite)
                peak = max(peak, abs(data[0][frame]))
            }
            offset += 512
        }
        #expect(peak > 0.05 && peak < 1.5, "peak \(peak) at a 32 kHz project rate")
    }

    @Test("L10g — reset() clears the tail AND the phase: a post-reset render matches a fresh one")
    func resetClearsEverything() throws {
        let params = RingModParams(carrierHz: 417, mix: 1, waveform: 1, inputHighCutHz: 1_200)
        let loud = sine(150, amplitude: 1, frames: 4_096)
        let probe = sine(150, amplitude: 0.3, frames: 8_192)

        let reused = RingModEffect(params: params)
        reused.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        _ = try processChunked(reused, channels: [loud])
        reused.reset()
        let afterReset = try processChunked(reused, channels: [probe])[0]
        #expect(afterReset == (try ring(params, probe)), "reset() left state behind")
    }

    // MARK: - L11: the render path allocates NOTHING (§12 gate 2, absolute zero)

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
        pthread_threadid_np(nil, &tid)  // no allocation, safe under malloc
        if tid == RingModTests.watchedThread.pointee {
            RingModTests.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global. Nil is a FAILURE for the caller,
    /// never a skip — a silently-absent probe is vacuity, not a pass.
    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: MallocLoggerFn?.self)
    }

    private static func mallocEvents(
        slot: UnsafeMutablePointer<MallocLoggerFn?>, _ body: () -> Void
    ) -> Int {
        pthread_threadid_np(nil, &watchedThread.pointee)
        eventCount.pointee = 0
        let previous = slot.pointee  // restore, don't assume it was nil
        slot.pointee = eventHook
        body()
        slot.pointee = previous
        return eventCount.pointee
    }

    @Test("L11 — process() allocates NOTHING across 4 000 quanta, and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
            return
        }
        let quantum = 512
        let calls = 4_000
        // Everything switched ON: the most expensive waveform (saw, whose
        // polyBLEP branch runs at both wrap edges), a mid mix so the write path
        // runs, a real filter corner, and a non-zero stereo spread so the right
        // channel's carrier is computed separately.
        let effect = RingModEffect(params: RingModParams(
            carrierHz: 2_917, mix: 0.6, waveform: 3, inputHighCutHz: 6_000,
            stereoSpreadDeg: 90))
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
            let value = Float(0.4 * sin(2.0 * .pi * 90 * t) + 0.3 * sin(2.0 * .pi * 3_300 * t))
            data[0][frame] = value
            data[1][frame] = value
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var sum: Float = 0
        let events = Self.mallocEvents(slot: slot) {
            var call = 0
            while call < calls {
                // The automation store is on the same render thread and is part
                // of the contract, so it is inside the probe — including the
                // `waveform` slot, whose derive runs an `Int()` conversion.
                effect.storeAutomatedParam(slot: 0, value: 100 + Double(call % 40) * 100)
                effect.storeAutomatedParam(slot: 2, value: Double(call % 4))
                effect.process(buffers: list, frameCount: quantum)
                sum += data[0][0]
                call += 1
            }
        }
        print("[measured] m39-m ringMod render allocation events over \(calls) quanta: \(events)")
        #expect(events == 0, "process() raised \(events) malloc/free events")
        // NON-VACUITY: the probe measured a render that actually happened.
        #expect(sum != 0, "the probe ran over a silent/no-op render")
        #expect(sum.isFinite)
    }

    @Test("L11b — POSITIVE CONTROL: the malloc probe can actually count")
    func theAllocationProbeCanSeeAnAllocation() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        // ⭐ A zero from a probe that never fires and a zero from a render that
        // never allocates are the same number. This makes the probe report a
        // non-zero on work that certainly allocates.
        var sink: [[Int]] = []
        let events = Self.mallocEvents(slot: slot) {
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
