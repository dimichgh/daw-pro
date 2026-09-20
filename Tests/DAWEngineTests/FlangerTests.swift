import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `RingModTests`, `DJFilterTests` and `BitCrusherTests` all record: the main
// actor is ONE serialization point for the whole test process, these tests
// render hundreds of thousands of frames of audio, and they need no main-actor
// state at all. (There is also a hard structural reason today:
// `MainActorOccupancySiteTests` Leg C pins the `@MainActor`-isolated SUITE
// count at its cap with ZERO slack, so a new isolated suite would redden a gate
// in a different target — and spelling `@MainActor` per-test to dodge that gate
// is what the gate itself names as instrument-silencing.)
//
// The one main-actor thing an effect owns is `apply(params:)`; these tests
// construct effects with their params, and use the nonisolated render-thread
// `storeAutomatedParam` where a value has to move mid-render.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-j — the `.flanger` insert, and the SECOND CALLER of
/// `InterpolatedDelayLine`. `docs/design/2026-09-19-creative-effects.md` §6.3
/// is the contract; §4.1 is the home's contract and §12 gate 9 names the
/// numbers this suite has to produce ("notch positions at `1/(2·delay)` odd
/// multiples; `delay > 0` asserted across the whole `depthMs` range — the
/// §6.3.2 bug, pinned").
///
/// ⭐ **Every claim is MEASURED FROM RENDERED OUTPUT, never read back from the
/// parameter.** A test that asserts `params.feedback == 0.5` proves the struct
/// stores a number. These legs recover the delay from an impulse's CENTROID,
/// Goertzel individual comb notches out of real renders, measure a
/// steady-state DC gain against closed-form arithmetic, and compare bytes — so
/// the plausible wrong implementations separate:
///
///  · feedback silently 0 (the recirculation never wired)  → L4a/L4d, measured
///    against the closed form `(1-mix) + mix/(1-feedback)`. NOTHING else in
///    this file can see it: a feedback-0 flanger still combs, still sweeps,
///    still passes every notch and envelope leg.
///  · the feedback SIGN inverted                           → L4c ONLY, for the
///    same reason: `-0.5` and `+0.5` give the same |comb| shape but DC gains
///    of 0.833 and 1.5.
///  · a BIPOLAR sweep (the §6.3.2 classic bug)             → L2a, which
///    measures the delay at LFO phase 0 and separates `delayMs + depthMs/2`
///    (correct) from `delayMs` (bipolar) by 144 samples
///  · the LFO frozen                                       → L5, the envelope
///    swing; every other leg here deliberately renders with a NEAR-STATIC
///    sweep so its measurement is clean, so L5 is the only one that moves
///  · the denormal flush removed (the §4.1 obligation this
///    caller owns, because the shared line has none)       → L6, which asserts
///    NO OUTPUT SAMPLE IS SUBNORMAL and carries its own non-vacuity control
///  · `mix == 0` writing the buffer                        → L1a, with L1b as
///    its positive control so "bit-exact" cannot mean "inert"
///  · the line PAUSED at `mix == 0`                        → L1c
///  · `stereoPhaseDeg` ignored                             → L7b
///  · a slot mis-wired in `storeAutomatedParam`            → L8
///  · a delay left UNCLAMPED on the automation path        → L9, which is a
///    MEMORY-SAFETY pin: the summed delay reaches `Int()` inside the shared
///    line's tap, and that line has no render-thread bounds check by design
@Suite("Flanger — swept comb, bipolar feedback, denormal flush (m39-j)", .serialized)
struct FlangerTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (RingModTests conventions)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    private func constant(_ value: Float, frames: Int) -> [Float] {
        [Float](repeating: value, count: frames)
    }

    private func impulse(at index: Int, frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        samples[index] = 1
        return samples
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

    private func mean(_ samples: [Float], in range: Range<Int>) -> Double {
        var total = 0.0
        for index in range { total += Double(samples[index]) }
        return total / Double(range.count)
    }

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        var total = 0.0
        for value in samples { total += Double(value) * Double(value) }
        return (total / Double(samples.count)).squareRoot()
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

    /// One mono pass through a freshly prepared flanger.
    private func flange(_ params: FlangerParams, _ input: [Float],
                        chunk: Int = 512) throws -> [Float] {
        let effect = FlangerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// One stereo pass through a freshly prepared flanger.
    private func flangeStereo(_ params: FlangerParams, left: [Float], right: [Float],
                              chunk: Int = 512) throws -> (left: [Float], right: [Float]) {
        let effect = FlangerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        let out = try processChunked(effect, channels: [left, right], chunk: chunk)
        return (out[0], out[1])
    }

    /// A sweep that is effectively STATIC for the length of a measurement:
    /// `rateHz` at its 0.02 Hz minimum and `depthMs` at its 0.1 ms minimum, so
    /// the delay moves by well under a thousandth of itself across the window.
    /// The delay it parks at is `delayMs + 0.05` ms (the §6.3.2 law at φ ≈ 0).
    private func parked(delayMs: Double, feedback: Double, mix: Double) -> FlangerParams {
        FlangerParams(rateHz: 0.02, depthMs: 0.1, delayMs: delayMs,
                      feedback: feedback, mix: mix, stereoPhaseDeg: 0)
    }

    private static let analysisFrames = 24_576
    private static var analysisWindow: Range<Int> { 4_096..<analysisFrames }

    // MARK: - L0: the laws (the ONE HOMES the DSP, the tests and the wire read)

    /// ⛔ THE §6.3.2 PIN, and §12 gate 9's words verbatim: "`delay > 0`
    /// asserted across the whole `depthMs` range". This is the classic
    /// flanger bug — a bipolar sweep goes NEGATIVE whenever `depthMs >
    /// delayMs`, and both ranges are 0.1…10 so the shipped surface permits it
    /// trivially. The grid below includes every such combination.
    @Test("L0a — the sweep law is UPWARD ONLY: delay never leaves [delayMs, delayMs+depthMs]")
    func sweepLawIsUpwardOnlyAcrossTheWholeSurface() {
        var checked = 0
        var minimumSeen = Double.infinity
        for delayMs in stride(from: 0.1, through: 10.0, by: 0.7) {
            for depthMs in stride(from: 0.1, through: 10.0, by: 0.7) {
                for step in 0..<64 {
                    let phase = Double(step) * 2 * .pi / 64
                    let delay = FlangerParams.sweptDelayMs(
                        phaseRadians: phase, delayMs: delayMs, depthMs: depthMs)
                    checked += 1
                    minimumSeen = min(minimumSeen, delay)
                    #expect(delay >= delayMs - 1e-12, """
                        delay \(delay) dipped BELOW the floor \(delayMs) at phase \(phase) \
                        with depth \(depthMs) — this is the §6.3.2 bipolar-sweep bug
                        """)
                    #expect(delay <= delayMs + depthMs + 1e-12)
                }
            }
        }
        // Non-vacuity: the grid actually ran, and it genuinely covered the
        // depth > floor region the bug lives in.
        #expect(checked == 15 * 15 * 64)
        #expect(minimumSeen >= FlangerParams.delayRange.lowerBound)
        #expect(abs(minimumSeen - 0.1) < 1e-9, "the grid never visited the sweep floor")
        // The law at the two phases the render legs below measure.
        #expect(abs(FlangerParams.sweptDelayMs(phaseRadians: 0, delayMs: 1, depthMs: 6) - 4)
                < 1e-12)
        #expect(abs(FlangerParams.sweptDelayMs(phaseRadians: .pi / 2, delayMs: 1, depthMs: 6) - 7)
                < 1e-12)
        #expect(abs(FlangerParams.sweptDelayMs(phaseRadians: -.pi / 2, delayMs: 1, depthMs: 6) - 1)
                < 1e-12)
        // ⚠️ THE GUARD THAT MATTERS: this value reaches `Int(_:)` on the RENDER
        // THREAD inside `InterpolatedDelayLine.tap`, and `Int(Double.nan)`
        // TRAPS — it does not return 0. Removing the `isFinite` guard does not
        // redden this test, it CRASHES the process.
        #expect(FlangerParams.sweptDelayMs(phaseRadians: .nan, delayMs: 2, depthMs: 3) == 2)
        #expect(FlangerParams.sweptDelayMs(phaseRadians: 0, delayMs: .nan, depthMs: 3) >= 0.1)
        #expect(FlangerParams.sweptDelayMs(phaseRadians: 0, delayMs: 2, depthMs: .nan) >= 2)
        // And out-of-range inputs CLAMP rather than escaping the line.
        #expect(FlangerParams.sweptDelayMs(phaseRadians: .pi / 2, delayMs: 500, depthMs: 500)
                == 20)
    }

    @Test("L0b — the comb law, the phase-offset law, the DC law, and the declared capacity")
    func spectralAndGainLawsMatchTheFrozenContract() {
        // Notches at the ODD multiples of 1/(2·delay): at 2.5 ms that is
        // 200, 600, 1000 Hz — the numbers L3 then measures out of real audio.
        #expect(abs(FlangerParams.combNotchHz(delayMs: 2.5, index: 0) - 200) < 1e-9)
        #expect(abs(FlangerParams.combNotchHz(delayMs: 2.5, index: 1) - 600) < 1e-9)
        #expect(abs(FlangerParams.combNotchHz(delayMs: 2.5, index: 2) - 1_000) < 1e-9)
        #expect(abs(FlangerParams.combNotchHz(delayMs: 1.0, index: 0) - 500) < 1e-9)
        #expect(abs(FlangerParams.combNotchHz(delayMs: 0.1, index: 0) - 5_000) < 1e-9)
        #expect(FlangerParams.combNotchHz(delayMs: 0, index: 0) == 0)
        #expect(FlangerParams.combNotchHz(delayMs: .nan, index: 0) == 0)
        #expect(FlangerParams.combNotchHz(delayMs: 2.5, index: -1) == 0)

        // Degrees → radians, clamped and NaN-safe.
        #expect(FlangerParams.stereoPhaseOffsetRadians(stereoPhaseDeg: 0) == 0)
        #expect(abs(FlangerParams.stereoPhaseOffsetRadians(stereoPhaseDeg: 90) - .pi / 2) < 1e-12)
        #expect(abs(FlangerParams.stereoPhaseOffsetRadians(stereoPhaseDeg: 180) - .pi) < 1e-12)
        #expect(abs(FlangerParams.stereoPhaseOffsetRadians(stereoPhaseDeg: 900) - .pi) < 1e-12)
        #expect(FlangerParams.stereoPhaseOffsetRadians(stereoPhaseDeg: .nan) == 0)

        // The DC law — the closed form L4 measures against. These four numbers
        // are what make "feedback is wired, with the right sign" falsifiable.
        #expect(abs(FlangerParams.dcGain(feedback: 0.5, mix: 0.5) - 1.5) < 1e-12)
        #expect(abs(FlangerParams.dcGain(feedback: 0, mix: 0.5) - 1.0) < 1e-12)
        #expect(abs(FlangerParams.dcGain(feedback: -0.5, mix: 0.5) - (5.0 / 6.0)) < 1e-12)
        #expect(abs(FlangerParams.dcGain(feedback: 0.9, mix: 0.5) - 5.5) < 1e-12)
        #expect(abs(FlangerParams.dcGain(feedback: 0.9, mix: 0) - 1.0) < 1e-12)
        #expect(FlangerParams.dcGain(feedback: .nan, mix: .nan).isFinite)

        // The capacity the engine declares to the shared line: exactly the
        // largest delay the upward sweep can reach (§6.3.2's 20 ms).
        #expect(abs(FlangerParams.lineCapacitySeconds - 0.020) < 1e-15)
        #expect(FlangerParams.lineCapacitySeconds
                == (FlangerParams.delayRange.upperBound
                    + FlangerParams.depthRange.upperBound) * 0.001)

        // Defaults are the frozen table's defaults, not whatever init fell out.
        let defaults = FlangerParams()
        #expect(defaults.rateHz == 0.3)
        #expect(defaults.depthMs == 3)
        #expect(defaults.delayMs == 1.0)
        #expect(defaults.feedback == 0.5)
        #expect(defaults.mix == 0.5)
        #expect(defaults.stereoPhaseDeg == 90)
        // The clamping init, including the NEGATIVE end of `feedback` —
        // the only range in the tree that crosses zero on purpose.
        #expect(FlangerParams(feedback: -5).feedback == -0.95)
        #expect(FlangerParams(feedback: 5).feedback == 0.95)
        #expect(FlangerParams(feedback: .nan).feedback == 0.5)
        #expect(FlangerParams(delayMs: 0).delayMs == 0.1)
        #expect(FlangerParams(depthMs: 1_000).depthMs == 10)
    }

    // MARK: - L1: the mix convention (rule 6.0.7)

    @Test("L1a — mix 0 is BIT-EXACT dry, sample for sample")
    func mixZeroIsBitExactDry() throws {
        let input = sine(440, amplitude: 0.6, frames: 8_192)
        let out = try flange(FlangerParams(mix: 0), input)
        #expect(out == input, "mix 0 touched the buffer")
    }

    @Test("L1b — positive control: the same render at mix 0.5 is NOT the input")
    func mixNonZeroChangesTheBuffer() throws {
        let input = sine(440, amplitude: 0.6, frames: 8_192)
        let out = try flange(FlangerParams(mix: 0.5), input)
        #expect(out != input, "mix 0.5 changed nothing — L1a's 'bit-exact' would be vacuous")
        // And it changed it AUDIBLY, not by one LSB.
        let differences = zip(out, input).filter { abs($0 - $1) > 1e-4 }.count
        #expect(differences > 4_000, "only \(differences) samples moved")
    }

    /// The other half of rule 6.0.7: at `mix == 0` the buffer is untouched but
    /// the LINE KEEPS RUNNING, so raising the mix later picks up mid-sweep
    /// rather than starting from silence. Measured by filling the line at
    /// mix 0 and then reading it at mix 1 over SILENCE — if the line had been
    /// paused there would be nothing to read.
    @Test("L1c — at mix 0 the delay line still runs, so a later mix raise is not silence")
    func lineKeepsRunningWhileMixIsZero() throws {
        let frames = 8_192
        let fill = sine(300, amplitude: 0.7, frames: frames)
        let silence = [Float](repeating: 0, count: frames)
        let params = parked(delayMs: 4, feedback: 0.7, mix: 0)

        let effect = FlangerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        // Phase 1: real signal, mix parked at 0 (bit-exact dry).
        let dry = try processChunked(effect, channels: [fill])[0]
        #expect(dry == fill)
        // Phase 2: silence, mix raised to 1 through the automation path.
        let tail = try processChunked(effect, channels: [silence]) { effect, _ in
            effect.storeAutomatedParam(slot: 4, value: 1)
        }[0]
        let energy = rms(tail[1_024..<4_096])
        #expect(energy > 1e-3, "the line was empty — it was paused while mix was 0 (rms \(energy))")

        // POSITIVE CONTROL: an effect that never SAW the signal produces
        // nothing at all from the same silence, so the assertion above is
        // about the stored line and not about the code path.
        let fresh = FlangerEffect(params: params)
        fresh.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let nothing = try processChunked(fresh, channels: [silence]) { effect, _ in
            effect.storeAutomatedParam(slot: 4, value: 1)
        }[0]
        #expect(rms(nothing[1_024..<4_096]) == 0)
    }

    // MARK: - L2: the delay itself, recovered from a rendered impulse

    /// ⛔ THE §6.3.2 DISCRIMINATOR, and the reason it is an impulse test rather
    /// than a spectral one: at LFO phase 0 the correct upward-only law gives
    /// `delayMs + depthMs/2` while the classic bipolar bug gives `delayMs`.
    /// With delayMs 1 and depthMs 6 those are 192 and 48 samples — 144 samples
    /// apart, which no tolerance can blur.
    ///
    /// The measurement is the CENTROID of the output impulse, which is exact:
    /// linear interpolation splits a unit impulse across `floor(D)` and
    /// `floor(D)+1` with weights `1-frac` and `frac`, whose centroid is D.
    @Test("L2a — the rendered delay at LFO phase 0 is delayMs + depthMs/2, not delayMs")
    func renderedDelayAtPhaseZeroFollowsTheUpwardLaw() throws {
        let frames = 4_096
        // rate at its 0.02 Hz minimum: the LFO advances 0.0000251 rad over the
        // impulse's whole 192-sample flight, so the delay is static to 7 digits.
        let params = FlangerParams(rateHz: 0.02, depthMs: 6, delayMs: 1,
                                   feedback: 0, mix: 1, stereoPhaseDeg: 0)
        let out = try flange(params, impulse(at: 0, frames: frames))

        var weight = 0.0, moment = 0.0
        for (index, value) in out.enumerated() {
            let magnitude = Double(abs(value))
            weight += magnitude
            moment += magnitude * Double(index)
        }
        #expect(weight > 0.9, "the impulse never came out (total weight \(weight))")
        let centroid = moment / weight
        let expected = FlangerParams.sweptDelayMs(phaseRadians: 0, delayMs: 1, depthMs: 6)
            * 0.001 * Self.sampleRate
        #expect(abs(expected - 192) < 1e-9)
        #expect(abs(centroid - expected) < 1.0, """
            delay measured \(centroid) samples, law says \(expected). A BIPOLAR sweep \
            would land at 48 (delayMs alone) — this is the §6.3.2 bug.
            """)
    }

    /// The sweep TRAVELS, and it reaches its declared ceiling. Measured at LFO
    /// phase π/2, where the law gives `delayMs + depthMs` (7 ms = 336 samples)
    /// and where the sweep is stationary, so the flight-time error is
    /// second-order.
    @Test("L2b — at LFO phase pi/2 the rendered delay is delayMs + depthMs (the sweep ceiling)")
    func renderedDelayAtPhaseQuarterReachesTheCeiling() throws {
        let rate = 2.0
        let quarter = Int(Self.sampleRate / (4 * rate))   // 6 000 frames = pi/2
        let frames = quarter + 4_096
        let params = FlangerParams(rateHz: rate, depthMs: 6, delayMs: 1,
                                   feedback: 0, mix: 1, stereoPhaseDeg: 0)
        let out = try flange(params, impulse(at: quarter, frames: frames))

        var weight = 0.0, moment = 0.0
        for index in quarter..<frames {
            let magnitude = Double(abs(out[index]))
            weight += magnitude
            moment += magnitude * Double(index - quarter)
        }
        #expect(weight > 0.9)
        let centroid = moment / weight
        let expected = FlangerParams.sweptDelayMs(phaseRadians: .pi / 2, delayMs: 1, depthMs: 6)
            * 0.001 * Self.sampleRate
        #expect(abs(expected - 336) < 1e-9)
        #expect(abs(centroid - expected) < 3.0,
                "delay measured \(centroid) samples at phase pi/2, law says \(expected)")
    }

    // MARK: - L3: the comb (§12 gate 9's "notches at 1/(2·delay) odd multiples")

    @Test("L3a — notches land on the ODD multiples of 1/(2*delay) and peaks on the even ones")
    func combNotchesLandWhereTheLawSays() throws {
        // The parked sweep sits at 2.45 + 0.05 = 2.5 ms, so the first notch is
        // at 200 Hz. feedback 0 and mix 0.5 is where the nulls are complete.
        let delayMs = 2.5
        let params = parked(delayMs: 2.45, feedback: 0, mix: 0.5)
        let amplitude = 0.5
        var notchDepths: [Double] = []

        for index in 0..<3 {
            let notch = FlangerParams.combNotchHz(delayMs: delayMs, index: index)
            let out = try flange(params, sine(notch, amplitude: amplitude,
                                              frames: Self.analysisFrames))
            let level = dB(goertzel(out, frequency: notch, in: Self.analysisWindow) / amplitude)
            notchDepths.append(level)
            #expect(level < -25, "notch \(index) at \(notch) Hz measured only \(level) dB")
        }
        #expect(notchDepths.count == 3)

        // The EVEN multiples are the peaks: at feedback 0 and mix 0.5 the
        // delayed copy arrives in phase, so the gain is unity, not a null.
        for index in 1...2 {
            let peak = Double(2 * index) / (2 * delayMs * 0.001)
            let out = try flange(params, sine(peak, amplitude: amplitude,
                                              frames: Self.analysisFrames))
            let level = dB(goertzel(out, frequency: peak, in: Self.analysisWindow) / amplitude)
            #expect(abs(level) < 1.0, "peak at \(peak) Hz measured \(level) dB, expected ~0")
        }
    }

    /// The positive control for L3a: the SAME probe through the SAME effect at
    /// mix 0 shows no notch at all, so "we measured a null" cannot mean "we
    /// measured silence" or "the probe tone was never there".
    @Test("L3b — positive control: at mix 0 the notch frequency comes through untouched")
    func noCombWithoutMix() throws {
        let notch = FlangerParams.combNotchHz(delayMs: 2.5, index: 0)
        let amplitude = 0.5
        let out = try flange(parked(delayMs: 2.45, feedback: 0, mix: 0),
                             sine(notch, amplitude: amplitude, frames: Self.analysisFrames))
        let level = dB(goertzel(out, frequency: notch, in: Self.analysisWindow) / amplitude)
        #expect(abs(level) < 0.5, "the 200 Hz probe measured \(level) dB at mix 0")
    }

    // MARK: - L4: the feedback, measured as a steady-state gain
    //
    // ⭐ THIS IS THE ONLY GROUP THAT CAN SEE THE FEEDBACK AT ALL. On a CONSTANT
    // input the swept delay is irrelevant — every path just sums — so the
    // recirculating comb converges to `1/(1-feedback)` exactly, whatever the
    // delay is doing, and the whole unit to `(1-mix) + mix/(1-feedback)`.
    // A flanger whose feedback was never wired (0) and one whose feedback sign
    // was flipped both pass every notch, envelope and sweep leg in this file.

    private func measuredDCGain(feedback: Double, mix: Double) throws -> Double {
        let frames = 65_536
        let params = FlangerParams(rateHz: 0.3, depthMs: 3, delayMs: 1,
                                   feedback: feedback, mix: mix, stereoPhaseDeg: 0)
        let out = try flange(params, constant(1, frames: frames))
        // The last eighth: the comb has recirculated hundreds of times by then
        // even at feedback 0.9 (a ~120-sample round trip over 57 000 samples).
        return mean(out, in: (frames - 8_192)..<frames)
    }

    @Test("L4a — DC gain at the defaults is (1-mix) + mix/(1-feedback) = 1.5")
    func dcGainAtDefaultsMatchesTheClosedForm() throws {
        let measured = try measuredDCGain(feedback: 0.5, mix: 0.5)
        let expected = FlangerParams.dcGain(feedback: 0.5, mix: 0.5)
        #expect(abs(measured - expected) < 0.01,
                "measured \(measured), closed form \(expected)")
    }

    @Test("L4b — feedback 0 gives exactly unity, which is what the other legs assume")
    func dcGainWithoutFeedbackIsUnity() throws {
        let measured = try measuredDCGain(feedback: 0, mix: 0.5)
        #expect(abs(measured - 1.0) < 0.01, "measured \(measured)")
    }

    /// ⛔ THE SIGN LEG. `+0.5` and `-0.5` produce the same comb MAGNITUDE
    /// response (peaks and notches swap places, which no single-frequency
    /// probe distinguishes) but DC gains of 1.5 and 0.833. This is the only
    /// assertion in the file that separates them.
    @Test("L4c — NEGATIVE feedback gives 0.833, not 1.5: the sign is wired, not just the value")
    func dcGainWithNegativeFeedbackIsBelowUnity() throws {
        let measured = try measuredDCGain(feedback: -0.5, mix: 0.5)
        let expected = FlangerParams.dcGain(feedback: -0.5, mix: 0.5)
        #expect(abs(expected - 5.0 / 6.0) < 1e-12)
        #expect(abs(measured - expected) < 0.01,
                "measured \(measured), closed form \(expected) — an INVERTED sign reads 1.5")
        // And it is unambiguously on the other side of unity from L4a.
        #expect(measured < 0.95)
    }

    @Test("L4d — heavy feedback (0.9) gives 5.5, which is the level warning the note makes")
    func dcGainWithHeavyFeedbackMatchesTheClosedForm() throws {
        let measured = try measuredDCGain(feedback: 0.9, mix: 0.5)
        let expected = FlangerParams.dcGain(feedback: 0.9, mix: 0.5)
        #expect(abs(expected - 5.5) < 1e-12)
        #expect(abs(measured - expected) < 0.05,
                "measured \(measured), closed form \(expected)")
        // The dB figure the param note and the MCP description both quote.
        #expect(abs(20 * log10(expected / FlangerParams.dcGain(feedback: 0, mix: 0.5)) - 14.8)
                < 0.1)
    }

    // MARK: - L5: the LFO actually moves the comb

    /// A frozen LFO parks the comb, and a parked comb on a fixed probe tone
    /// gives a FLAT envelope. A moving one drags the notch across the probe,
    /// so the envelope must both reach near-unity and collapse to a null
    /// within the same render. Both halves are asserted, because a freeze at
    /// ANY phase fails one of them.
    @Test("L5 — the sweep moves: a fixed probe tone's envelope both peaks and nulls")
    func theLFOSweepsTheCombAcrossTheProbe() throws {
        let frames = 65_536                       // 1.365 s
        let amplitude = 0.5
        // delay 1…4 ms puts the first notch between 125 Hz and 500 Hz, so a
        // 200 Hz probe is crossed by the notch twice per LFO cycle.
        let params = FlangerParams(rateHz: 2, depthMs: 3, delayMs: 1,
                                   feedback: 0, mix: 0.5, stereoPhaseDeg: 0)
        let out = try flange(params, sine(200, amplitude: amplitude, frames: frames))

        var envelope: [Double] = []
        var index = 4_096
        while index + 512 <= frames {
            envelope.append(rms(out[index..<(index + 512)]))
            index += 512
        }
        let reference = amplitude / 2.0.squareRoot()   // the probe's own rms
        let peak = envelope.max() ?? 0
        let trough = envelope.min() ?? 0
        #expect(envelope.count > 100)
        #expect(peak > reference * 0.5,
                "envelope never rose (peak \(peak) vs probe rms \(reference)) — LFO frozen?")
        #expect(trough < reference * 0.08,
                "envelope never nulled (trough \(trough) vs probe rms \(reference)) — LFO frozen?")
    }

    // MARK: - L6: the denormal flush this caller OWNS (design §4.1)

    /// ⛔ `InterpolatedDelayLine` deliberately carries NO denormal flushing —
    /// the chorus is feedback-free and provably cannot generate denormals, so
    /// a per-sample branch in the shared home would tax a caller that does not
    /// need one. This effect IS a feedback structure, so the flush is ITS job,
    /// and this is the leg that proves it happened.
    ///
    /// The geometry is deliberate and was computed, not guessed: a 0.15 ms
    /// round trip is 7.2 samples, and at feedback 0.5 the tail needs
    /// `ln(1e-38)/ln(0.5) ≈ 126` round trips — about 900 samples — to reach
    /// the subnormal boundary. So a 16 384-frame render straddles the whole
    /// subnormal window with room to spare. (Geometry matters: `RingModTests`
    /// records the same leg passing WITH the flush deleted at a longer window,
    /// because Float32 had already underflowed to zero by then.)
    @Test("L6 — no output sample is subnormal, on either channel, after a decaying tail")
    func feedbackTailIsDenormalFlushed() throws {
        let frames = 16_384
        var left = [Float](repeating: 0, count: frames)
        var right = [Float](repeating: 0, count: frames)
        left[0] = 1
        right[0] = 1
        let params = FlangerParams(rateHz: 0.02, depthMs: 0.1, delayMs: 0.1,
                                   feedback: 0.5, mix: 1, stereoPhaseDeg: 0)
        let out = try flangeStereo(params, left: left, right: right)

        for (name, channel) in [("L", out.left), ("R", out.right)] {
            let subnormals = channel.enumerated().filter { $0.element.isSubnormal }
            #expect(subnormals.isEmpty, """
                channel \(name) carried \(subnormals.count) SUBNORMAL sample(s), first at \
                index \(subnormals.first?.offset ?? -1) — the feedback flush is missing
                """)
            // NON-VACUITY, and it is the whole point: "no subnormals" must not
            // be able to mean "no tail". The decay has to actually pass
            // through the tiny-but-normal region on its way down.
            let tiny = channel.filter { $0 != 0 && abs($0) < 1e-10 }
            #expect(!tiny.isEmpty, """
                channel \(name) never produced a small non-zero value — there was no tail to \
                flush, so the assertion above proved nothing
                """)
            // And the tail is genuinely a decaying one, not a DC offset.
            #expect(channel[0..<64].contains { abs($0) > 0.1 })
            #expect(rms(channel[8_192..<frames]) < 1e-12)
        }
    }

    // MARK: - L7: stereo

    @Test("L7a — stereoPhaseDeg 0 renders the two channels identically, bit for bit")
    func zeroStereoPhaseIsMonoSafe() throws {
        let input = sine(440, amplitude: 0.6, frames: 16_384)
        let params = FlangerParams(rateHz: 1, depthMs: 4, delayMs: 1,
                                   feedback: 0.6, mix: 0.5, stereoPhaseDeg: 0)
        let out = try flangeStereo(params, left: input, right: input)
        #expect(out.left == out.right, "stereoPhaseDeg 0 is not mono-safe")
    }

    @Test("L7b — stereoPhaseDeg 180 makes the two channels differ, and audibly")
    func stereoPhaseSeparatesTheChannels() throws {
        let input = sine(440, amplitude: 0.6, frames: 16_384)
        let params = FlangerParams(rateHz: 1, depthMs: 4, delayMs: 1,
                                   feedback: 0.6, mix: 0.5, stereoPhaseDeg: 180)
        let out = try flangeStereo(params, left: input, right: input)
        #expect(out.left != out.right, "stereoPhaseDeg 180 was ignored")
        let divergence = zip(out.left, out.right).filter { abs($0 - $1) > 1e-3 }.count
        #expect(divergence > 8_000, "only \(divergence) samples differ — the offset is cosmetic")
    }

    // MARK: - L8: the automation slot map (§12 gate 3's render-side half)

    /// `EffectParamSpec.specs(for: .flanger)` order is 0 rateHz, 1 depthMs,
    /// 2 delayMs, 3 feedback, 4 mix, 5 stereoPhaseDeg. A transposed pair here
    /// re-points every saved automation lane on every shipped insert. Each
    /// slot is checked by rendering it against the SAME value delivered
    /// through the constructor — bit-identical or the slot is mis-wired.
    @Test("L8 — storeAutomatedParam drives the RIGHT parameter per slot")
    func automationSlotsAreWiredToTheRightParameters() throws {
        let input = sine(330, amplitude: 0.5, frames: 8_192)
        let base = FlangerParams(rateHz: 0.3, depthMs: 3, delayMs: 1,
                                 feedback: 0.5, mix: 0.5, stereoPhaseDeg: 0)

        func automated(slot: Int, value: Double) throws -> [Float] {
            let effect = FlangerEffect(params: base)
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
            return try processChunked(effect, channels: [input]) { effect, _ in
                effect.storeAutomatedParam(slot: slot, value: value)
            }[0]
        }

        let expectations: [(slot: Int, value: Double, params: FlangerParams)] = [
            (0, 7.5, FlangerParams(rateHz: 7.5, depthMs: 3, delayMs: 1,
                                   feedback: 0.5, mix: 0.5, stereoPhaseDeg: 0)),
            (1, 9.0, FlangerParams(rateHz: 0.3, depthMs: 9, delayMs: 1,
                                   feedback: 0.5, mix: 0.5, stereoPhaseDeg: 0)),
            (2, 6.0, FlangerParams(rateHz: 0.3, depthMs: 3, delayMs: 6,
                                   feedback: 0.5, mix: 0.5, stereoPhaseDeg: 0)),
            (3, -0.8, FlangerParams(rateHz: 0.3, depthMs: 3, delayMs: 1,
                                    feedback: -0.8, mix: 0.5, stereoPhaseDeg: 0)),
            (4, 0.0, FlangerParams(rateHz: 0.3, depthMs: 3, delayMs: 1,
                                   feedback: 0.5, mix: 0, stereoPhaseDeg: 0)),
        ]
        let reference = try flange(base, input)
        for (slot, value, params) in expectations {
            let viaSlot = try automated(slot: slot, value: value)
            let viaParams = try flange(params, input)
            #expect(viaSlot == viaParams, "slot \(slot) is not wired to the expected parameter")
            // …and it actually CHANGED something, so "identical" is a match
            // and not two inert renders agreeing with each other.
            #expect(viaSlot != reference, "slot \(slot) changed nothing at all")
        }
        // Slot 5 is stereoPhaseDeg, which is inaudible on a MONO render — so
        // the honest assertion is that it leaves a mono render untouched.
        let slot5 = try automated(slot: 5, value: 180)
        #expect(slot5 == reference, "slot 5 changed a MONO render")
        // Out-of-range slots and non-finite values are inert, not crashes.
        for (slot, value) in [(0, Double.nan), (2, Double.nan), (3, Double.nan),
                              (-1, 1.0), (6, 1.0), (0, Double.infinity),
                              (2, -Double.infinity)] {
            let guarded = try automated(slot: slot, value: value)
            #expect(guarded == reference, "slot \(slot) value \(value) was not inert")
        }
    }

    // MARK: - L9: the clamp, which here is MEMORY SAFETY and not tidiness

    /// A field-by-field overlay poke bypasses `FlangerParams.init`, so the
    /// clamping the init does is NOT in force on the render thread. The summed
    /// delay reaches `Int(delay)` inside `InterpolatedDelayLine.tap`, and that
    /// line has NO render-thread bounds check BY DESIGN (§4.1) — so an
    /// unclamped 50 ms would index off the end of a 20 ms line. Asserting
    /// bit-identity with the clamped value is the strong form of "it was
    /// clamped": it is also a proof the render did not read garbage.
    @Test("L9 — an out-of-range automated delay CLAMPS rather than indexing off the line")
    func outOfRangeAutomatedDelayIsClamped() throws {
        let input = sine(330, amplitude: 0.5, frames: 16_384)

        func automated(slot: Int, value: Double) throws -> [Float] {
            let effect = FlangerEffect(params: FlangerParams())
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
            return try processChunked(effect, channels: [input]) { effect, _ in
                effect.storeAutomatedParam(slot: slot, value: value)
            }[0]
        }

        // delayMs 50 must render exactly as delayMs 10 (the range ceiling).
        let wild = try automated(slot: 2, value: 50)
        let clamped = try automated(slot: 2, value: FlangerParams.delayRange.upperBound)
        #expect(wild == clamped, "an out-of-range delayMs did not clamp to 10 ms")
        #expect(wild.allSatisfy { $0.isFinite })
        // …and 10 ms is genuinely different from the 1 ms default, so the
        // comparison above is between two REAL renders.
        let shortDelay = try automated(slot: 2, value: 1)
        #expect(clamped != shortDelay)

        // depthMs 1e9 must render exactly as depthMs 10.
        let wildDepth = try automated(slot: 1, value: 1e9)
        let maxDepth = try automated(slot: 1, value: 10)
        #expect(wildDepth == maxDepth)
        #expect(wildDepth.allSatisfy { $0.isFinite })

        // feedback 5 must clamp to 0.95 and stay bounded — an unclamped
        // feedback above 1 is an unstable recirculation, not a loud one.
        let wildFeedback = try automated(slot: 3, value: 5)
        let maxFeedback = try automated(slot: 3, value: 0.95)
        #expect(wildFeedback == maxFeedback)
        #expect(wildFeedback.allSatisfy { $0.isFinite && abs($0) < 50 })
    }

    // MARK: - L10: the contract every insert owes the graph

    @Test("L10a — latencySamples is 0 (rule 6.0.9) and two renders are bit-identical")
    func reportsNoLatencyAndIsDeterministic() throws {
        let effect = FlangerEffect(params: FlangerParams())
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(effect.latencySamples == 0)

        let input = sine(220, amplitude: 0.6, frames: 16_384)
        let params = FlangerParams(rateHz: 1.7, depthMs: 5, delayMs: 0.6,
                                   feedback: 0.8, mix: 0.7, stereoPhaseDeg: 120)
        let first = try flangeStereo(params, left: input, right: input)
        let second = try flangeStereo(params, left: input, right: input)
        #expect(first.left == second.left)
        #expect(first.right == second.right)
    }

    @Test("L10b — hostile finite input stays finite: no NaN, no inf, bounded output")
    func survivesHostileFiniteInput() throws {
        let frames = 32_768
        // Full-scale square-ish material plus DC, at the maximum feedback.
        let input = (0..<frames).map { index -> Float in
            index % 97 == 0 ? 1.0 : (index % 2 == 0 ? 0.9 : -0.9)
        }
        let params = FlangerParams(rateHz: 10, depthMs: 10, delayMs: 0.1,
                                   feedback: 0.95, mix: 1, stereoPhaseDeg: 180)
        let out = try flangeStereo(params, left: input, right: input.map { -$0 })
        for channel in [out.left, out.right] {
            #expect(channel.allSatisfy { $0.isFinite })
            #expect(channel.allSatisfy { !$0.isSubnormal })
            // 1/(1-0.95) = 20 is the DC ceiling; nothing may exceed it wildly.
            #expect(channel.allSatisfy { abs($0) < 60 })
        }
    }

    @Test("L10c — reset() clears the tail: the line is silent again afterwards")
    func resetClearsTheLine() throws {
        let frames = 8_192
        let silence = [Float](repeating: 0, count: frames)
        var fill = [Float](repeating: 0, count: frames)
        fill[0] = 1
        let params = FlangerParams(rateHz: 0.02, depthMs: 0.1, delayMs: 5,
                                   feedback: 0.9, mix: 1, stereoPhaseDeg: 0)

        let effect = FlangerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        _ = try processChunked(effect, channels: [fill])
        // Without a reset the tail is still ringing — the control for the
        // assertion below, so "silent after reset" cannot mean "silent anyway".
        let ringing = try processChunked(effect, channels: [silence])[0]
        #expect(rms(ringing[0..<2_048]) > 1e-4, "there was no tail to clear")

        effect.reset()
        let cleared = try processChunked(effect, channels: [silence])[0]
        #expect(cleared.allSatisfy { $0 == 0 }, "reset() left audio in the line")
    }

    // MARK: - L12: the internal smoothing rule 6.0.6 makes mandatory
    //
    // ⭐ THIS GROUP EXISTS BECAUSE IT WAS MISSING AND THE PLANTS PROVED IT.
    // Deleting the per-sample `mix` interpolation left all 22 other legs in
    // this file GREEN — every one of them renders with a STATIC parameter set
    // or a constant automated value, so nothing could see a per-quantum step.
    // Rule 6.0.6 is what earns `delayMs`/`depthMs`/`mix` their `yes`
    // modulation verdicts instead of `warned`, so an unpinned smoother is a
    // verdict this tree cannot support. (The m39-e shape, again: a feature
    // whose whole suite could not fail.)

    /// A single-quantum jump in an automated value must arrive as a RAMP.
    /// Measured as the largest sample-to-sample step in the output: a
    /// per-quantum `mix` step of 0.1 → 0.9 at feedback 0.9 moves the DC output
    /// from 1.9 to 9.1, which is a 7.2 discontinuity in ONE sample if the
    /// interpolation is missing and 0.014 per sample if it is not.
    @Test("L12a — an automated mix jump ramps across the quantum, it does not step")
    func mixIsInterpolatedPerSample() throws {
        let frames = 24_576
        let jumpQuantum = 24                       // frame 12 288
        let params = FlangerParams(rateHz: 0.02, depthMs: 0.1, delayMs: 0.5,
                                   feedback: 0.9, mix: 0.1, stereoPhaseDeg: 0)
        let effect = FlangerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let out = try processChunked(effect, channels: [constant(1, frames: frames)]) {
            effect, quantum in
            effect.storeAutomatedParam(slot: 4, value: quantum < jumpQuantum ? 0.1 : 0.9)
        }[0]

        // Settle past the recirculation's own fill (a 26-sample round trip at
        // feedback 0.9 needs ~3 300 samples to converge).
        var largestStep = 0.0
        for index in 8_192..<frames {
            largestStep = max(largestStep, abs(Double(out[index]) - Double(out[index - 1])))
        }
        #expect(largestStep < 0.05, """
            a single sample moved by \(largestStep) — an automated mix jump STEPPED at the \
            quantum boundary instead of ramping across it (rule 6.0.6)
            """)
        // NON-VACUITY: the jump really happened, so "no step" is not "no move".
        let before = mean(out, in: 11_264..<12_288)
        let after = mean(out, in: 20_480..<frames)
        #expect(abs(before - 1.9) < 0.05, "pre-jump DC measured \(before)")
        #expect(abs(after - 9.1) < 0.05, "post-jump DC measured \(after)")
    }

    /// The same obligation for the DELAY, and this is the leg that supports
    /// `delayMs`'s `yes` verdict where `delay.timeMs` is `warned`: that effect
    /// reads its line at an INTEGER offset and steps whole samples; this one
    /// reads a fractional interpolated tap AND glides the floor per sample, so
    /// the same control that clicks there must not click here. Automated as a
    /// repeating square wave so no single jump can land on a lucky phase.
    @Test("L12b — an automated delayMs jump glides: no click where delay.timeMs would click")
    func delayIsInterpolatedPerSample() throws {
        let frames = 49_152
        let amplitude = 0.5
        let input = sine(500, amplitude: amplitude, frames: frames)
        let params = FlangerParams(rateHz: 0.02, depthMs: 0.1, delayMs: 0.5,
                                   feedback: 0, mix: 1, stereoPhaseDeg: 0)
        let effect = FlangerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let out = try processChunked(effect, channels: [input]) { effect, quantum in
            effect.storeAutomatedParam(slot: 2, value: (quantum / 8) % 2 == 0 ? 0.5 : 9.9)
        }[0]

        // The probe's OWN largest per-sample step, which is the floor any
        // honest threshold has to clear: 0.5·2π·500/48 000.
        let probeStep = amplitude * 2 * .pi * 500 / Self.sampleRate
        #expect(abs(probeStep - 0.0327) < 0.001)
        var largestStep = 0.0
        for index in 4_096..<frames {
            largestStep = max(largestStep, abs(Double(out[index]) - Double(out[index - 1])))
        }
        #expect(largestStep < probeStep * 3, """
            a single sample moved by \(largestStep) against the probe's own \(probeStep) — the \
            delay JUMPED at a quantum boundary instead of gliding (rule 6.0.6)
            """)
        // NON-VACUITY: the delay really did travel 451 samples and back, many
        // times, so "no click" is not "nothing was automated".
        let half = Float(amplitude * 0.5)
        #expect(out.contains { abs($0) > half })
    }

    // MARK: - L11: the shared home, used unchanged (design §4.1)

    /// The flanger is the SECOND caller of `InterpolatedDelayLine`, chosen for
    /// that role because it is the cheapest way to find out the home is wrong.
    /// This leg states what it asks of the home, so a later change to the home
    /// that breaks a feedback caller reddens HERE with a readable reason
    /// rather than as a mysterious flanger defect.
    @Test("L11 — the shared delay line accepts this caller's declared invariants unchanged")
    func sharedLineAcceptsTheFlangersInvariants() throws {
        // Capacity in SECONDS, no default, linear interpolation — the home's
        // safe default, which the design forbids "improving" to cubicHermite.
        let line = InterpolatedDelayLine(
            capacitySeconds: FlangerParams.lineCapacitySeconds, interpolation: .linear)
        // The floor this effect declares at prepare: delayRange.lowerBound.
        let minDelay = FlangerParams.delayRange.lowerBound * 0.001 * Self.sampleRate
        #expect(abs(minDelay - 4.8) < 1e-9, "0.1 ms at 48 kHz is 4.8 samples")
        #expect(minDelay >= InterpolatedDelayLine.Interpolation.linear
            .minimumSupportedDelaySamples)
        try line.prepare(sampleRate: Self.sampleRate, minDelaySamples: minDelay, channelCount: 2)
        #expect(line.isPrepared)
        // The largest delay the upward sweep can reach fits, with the home's
        // interpolation margin still inside the buffer.
        let maxDelay = (FlangerParams.delayRange.upperBound + FlangerParams.depthRange.upperBound)
            * 0.001 * Self.sampleRate
        #expect(maxDelay < Double(line.capacityPerChannel))

        // ⛔ AND THE REFUSAL THE DESIGN INSISTS ON: a caller whose minimum can
        // reach 0 — through-zero flanging — is refused at prepare, loudly.
        // This effect must never defeat that; it is a separate kind if anyone
        // ever wants it (§6.3.2).
        let tzf = InterpolatedDelayLine(capacitySeconds: 0.020, interpolation: .linear)
        #expect(throws: InterpolatedDelayLine.PrepareRefusal.self) {
            try tzf.prepare(sampleRate: Self.sampleRate, minDelaySamples: 0, channelCount: 2)
        }
        #expect(!tzf.isPrepared)
    }

    /// A rate low enough to make 0.1 ms fall below the linear stencil's
    /// 1-sample floor is refused by the home, and this effect then passes the
    /// buffer through BIT-EXACT DRY rather than reading its own write head.
    /// (Unreachable from CoreAudio — it needs a sample rate under 10 kHz — but
    /// the failure mode it prevents is reading uninitialised memory, so it is
    /// asserted rather than reasoned about.)
    @Test("L11b — a refused prepare degrades to bit-exact dry, never to garbage")
    func refusedPrepareIsSilentNotGarbage() throws {
        let lowRate = 8_000.0   // 0.1 ms = 0.8 samples, below the 1-sample floor
        let effect = FlangerEffect(params: FlangerParams())
        effect.prepare(sampleRate: lowRate, maxFramesPerQuantum: 512, channelCount: 2)
        let frames = 4_096
        let input = (0..<frames).map { Float(sin(2.0 * .pi * 300 * Double($0) / lowRate) * 0.6) }

        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: lowRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var output: [Float] = []
        var offset = 0
        while offset < frames {
            buffer.frameLength = 512
            let data = try #require(buffer.floatChannelData)
            for frame in 0..<512 { data[0][frame] = input[offset + frame] }
            effect.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: 512)
            output.append(contentsOf: UnsafeBufferPointer(start: data[0], count: 512))
            offset += 512
        }
        #expect(output == input, "a refused prepare must pass the buffer through untouched")
    }
}
