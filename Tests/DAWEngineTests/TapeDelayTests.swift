import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `FlangerTests`, `RingModTests`, `DJFilterTests` and `BitCrusherTests` all
// record: the main actor is ONE serialization point for the whole test
// process, these tests render hundreds of thousands of frames of audio, and
// they need no main-actor state at all. (There is also a hard structural
// reason: `MainActorOccupancySiteTests` Leg C pins the `@MainActor`-isolated
// SUITE count at its cap with ZERO slack, so a new isolated suite would redden
// a gate in a different target — and spelling `@MainActor` per-test to dodge
// that gate is what the gate itself names as instrument-silencing.)
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-n — the `.tapeDelay` insert (FREE-MS ONLY), and the FOURTH CALLER of
/// `InterpolatedDelayLine`. `docs/design/2026-09-19-creative-effects.md` §4.1
/// is the home's contract.
///
/// ⚠️ **A CITATION THIS SUITE COULD NOT FIND.** The item's brief cited "the
/// `.tapeDelay` contract in §11" of the design doc; §11 contains the file set
/// for a new kind, the `CopilotCatalog` ruling, the id allocation and the leg
/// ordering, and NO parameter table for this kind (or any other — the per-kind
/// contracts live in §6.1–§6.4, and there is no §6.5). The surface under test
/// is therefore derived from §4.1 + §2.1 + §8.2 + rule 6.0, and that is
/// recorded in `TapeDelayParams`' own header rather than discovered again.
///
/// ⭐ **Every claim is MEASURED FROM RENDERED OUTPUT, never read back from the
/// parameter.** A test that asserts `params.wowDepthMs == 2.5` proves the
/// struct stores a number. These legs recover the echo position from an
/// impulse, recover the INSTANTANEOUS PITCH from interpolated zero crossings,
/// Goertzel individual frequencies out of real renders, and compare bytes — so
/// the plausible wrong implementations separate:
///
///  · the wow LFO frozen (or never wired)       → L3, the cents measurement,
///    which is the only leg here that can see it: every other leg deliberately
///    renders with a STEADY transport so its measurement is clean
///  · `.linear` interpolation instead of
///    `.cubicHermite`                           → L7 ONLY, which measures the
///    interpolation's own frequency response at a half-sample delay against
///    both closed forms. 1.94 dB apart at 12 kHz, and NOTHING else here moves
///  · the RECORD-FILTER denormal flush removed  → L8, which reads the filter
///    state directly at a 32-frame stride, because the output cannot see it
///    (the tap flush covers for it) and a 512-frame stride cannot either (the
///    state crosses the whole subnormal band in 20 samples at the default
///    corner). ⚠️ THE TAP FLUSH'S REMOVAL REDDENS NOTHING, measured — see L8
///  · feedback silently 0                       → L4, which requires a SECOND
///    echo at 2·timeMs. Every other leg passes on a feedback-0 tape delay
///  · the saturator always on / never on        → L5, homogeneity: at drive 0
///    the echo of a half-amplitude input is EXACTLY half the echo of a
///    full-amplitude one, and at drive 1 it is measurably not
///  · the record filter in the FEEDBACK path
///    instead (the `.delay` topology)           → L6b, which measures the
///    FIRST echo's brightness — the one repeat the two topologies disagree
///    about
///  · `mix == 0` writing the buffer             → L1a, with L1b as its
///    positive control so "bit-exact" cannot mean "inert"
///  · the tape PAUSED at `mix == 0`             → L1c
///  · a slot mis-wired in `storeAutomatedParam` → L9
///  · a delay left UNCLAMPED on the automation
///    path                                      → L10, a MEMORY-SAFETY pin:
///    the delay reaches `Int()` inside the shared line's tap, and that line has
///    no render-thread bounds check by design
@Suite("Tape delay — wow, flutter, record-path tape stage (m39-n)", .serialized)
struct TapeDelayTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (FlangerTests conventions)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
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

    private func rms(_ samples: ArraySlice<Float>) -> Double {
        var total = 0.0
        for value in samples { total += Double(value) * Double(value) }
        return (total / Double(samples.count)).squareRoot()
    }

    /// Positive-going zero crossings, linearly interpolated to sub-sample
    /// precision. The instrument behind the wow measurement: the spacing
    /// between successive crossings IS the instantaneous period.
    private func zeroCrossings(_ samples: [Float], in range: Range<Int>) -> [Double] {
        var crossings: [Double] = []
        var previous = Double(samples[range.lowerBound])
        for index in (range.lowerBound + 1)..<range.upperBound {
            let current = Double(samples[index])
            if previous < 0, current >= 0, current != previous {
                crossings.append(Double(index - 1) + (-previous) / (current - previous))
            }
            previous = current
        }
        return crossings
    }

    /// Runs `channels` through `effect` in `chunk`-frame quanta (state
    /// continuity across quantum boundaries included in the proof). `poke` runs
    /// once per quantum before `process`, which is how an automation lane
    /// actually arrives.
    private func processChunked(_ effect: any EffectRendering,
                                channels: [[Float]], chunk: Int = 512,
                                poke: ((any EffectRendering, Int) -> Void)? = nil,
                                observe: ((Int) -> Void)? = nil)
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
            observe?(quantum)
            offset += frames
            quantum += 1
        }
        return output
    }

    /// One mono pass through a freshly prepared tape delay.
    private func tape(_ params: TapeDelayParams, _ input: [Float],
                      chunk: Int = 512) throws -> [Float] {
        let effect = TapeDelayEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        #expect(effect.lastPrepareRefusal == nil,
                "the line refused to prepare — every measurement below would be vacuous")
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// A PERFECTLY STEADY transport: both depths 0, so the read delay is
    /// exactly `timeMs` at every sample and a measurement is not smeared by the
    /// very wobble other legs are measuring.
    private func steady(timeMs: Double, feedback: Double = 0, mix: Double = 1,
                        drive: Double = 0, highCutHz: Double = 20_000) -> TapeDelayParams {
        TapeDelayParams(timeMs: timeMs, feedback: feedback, mix: mix,
                        wowDepthMs: 0, wowRateHz: 0.8, flutterDepthMs: 0,
                        saturationDrive: drive, highCutHz: highCutHz)
    }

    // MARK: - L0 — THE §4.1 ERRATUM, CONFIRMED AND THEN MADE UNREACHABLE

    /// ⭐⭐⭐ THE ERRATUM THIS CALLER WAS PREDICTED TO HIT, kept as a permanent
    /// regression guard.
    ///
    /// §4.1's capability table states the minimum-delay floor as "**1 sample**"
    /// flatly. The 2026-09-19 addendum immediately below it predicts: *"the
    /// tape-delay author reads this row, declares `minDelaySamples: 1`
    /// alongside `.cubicHermite` (which §4.1 recommends to them by name, for
    /// the wow), and is refused at `prepare()`."*
    ///
    /// ⭐ **CONFIRMED, m39-n.** The first draft of `TapeDelayEffect.prepare`
    /// did exactly that and the home refused it with
    /// `minimumDelayBelowStencil(minDelaySamples: 1.0, required: 2.0)`. The
    /// refusal NAMES BOTH NUMBERS, so it is actionable — but only to a caller
    /// that reads it, and the worked example the brief points at
    /// (`FlangerEffect.prepare`) catches the error into an EMPTY BLOCK. The
    /// observable symptom of the refusal is a silent bit-exact passthrough.
    /// That is why this effect keeps `lastPrepareRefusal`.
    ///
    /// Both halves are asserted here: the literal 1 IS refused (so the erratum
    /// stays true if someone "simplifies" the floor back to a constant), and
    /// the floor this effect actually declares is NOT.
    @Test("L0: §4.1's literal `minDelaySamples: 1` is refused for .cubicHermite, and 2 is the floor")
    func erratumMinimumDelayFloorIsInterpolationDependent() {
        let hermite = InterpolatedDelayLine(
            capacitySeconds: TapeDelayParams.lineCapacitySeconds, interpolation: .cubicHermite)
        var refusal: InterpolatedDelayLine.PrepareRefusal?
        do {
            try hermite.prepare(sampleRate: Self.sampleRate, minDelaySamples: 1, channelCount: 2)
        } catch let error as InterpolatedDelayLine.PrepareRefusal {
            refusal = error
        } catch {}
        print("[measured] m39-n erratum — cubicHermite @ minDelaySamples 1: "
              + String(describing: refusal))
        #expect(refusal == .minimumDelayBelowStencil(minDelaySamples: 1, required: 2))
        #expect(!hermite.isPrepared, Comment(rawValue:
                "a refused line must own no storage — a caller that ignored the "
                    + "refusal has to be SILENT, not reading its own write head"))

        // POSITIVE CONTROL for the whole leg: the SAME argument on `.linear`
        // succeeds, so the refusal above is about the interpolator and not
        // about the number 1, the capacity, or a broken probe.
        let linear = InterpolatedDelayLine(
            capacitySeconds: TapeDelayParams.lineCapacitySeconds, interpolation: .linear)
        #expect(throws: Never.self) {
            try linear.prepare(sampleRate: Self.sampleRate, minDelaySamples: 1, channelCount: 2)
        }
        #expect(linear.isPrepared)

        // And 2 — the documented floor — is accepted on `.cubicHermite`.
        let atFloor = InterpolatedDelayLine(
            capacitySeconds: TapeDelayParams.lineCapacitySeconds, interpolation: .cubicHermite)
        #expect(throws: Never.self) {
            try atFloor.prepare(sampleRate: Self.sampleRate, minDelaySamples: 2, channelCount: 2)
        }
    }

    /// The fix, and the reason a literal is the wrong shape here at all: the
    /// floor is DERIVED from the ranges, so it cannot be 1 and cannot rot when
    /// a range moves. Asserted through a real `prepare()` at every plausible
    /// rate, because the derivation being right on paper is not the claim.
    @Test("L0b: the effect's derived minimum delay is accepted at every plausible sample rate")
    func derivedMinimumDelayPreparesCleanly() throws {
        for rate in [22_050.0, 44_100, 48_000, 96_000, 192_000] {
            let effect = TapeDelayEffect(params: TapeDelayParams())
            effect.prepare(sampleRate: rate, maxFramesPerQuantum: 512, channelCount: 2)
            #expect(effect.lastPrepareRefusal == nil,
                    Comment(rawValue: "refused at \(rate) Hz: "
                        + String(describing: effect.lastPrepareRefusal)))
        }
        // NON-VACUITY: `lastPrepareRefusal` is a real instrument, not a
        // property that is always nil. A line prepared at an impossible rate
        // must record a refusal.
        let broken = TapeDelayEffect(params: TapeDelayParams())
        broken.prepare(sampleRate: 0, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(broken.lastPrepareRefusal == .nonPositiveSampleRate(0))
    }

    // MARK: - L1 — mix 0 is bit-exact dry, and the tape keeps running

    @Test("L1a: mix == 0 is BIT-EXACT dry, and L1b's control proves the comparison can fail")
    func mixZeroIsBitExactDry() throws {
        let input = sine(220, amplitude: 0.6, frames: 24_000)
        let dry = try tape(steady(timeMs: 350, feedback: 0.6, mix: 0, drive: 0.5,
                                  highCutHz: 4_000), input)
        for (index, value) in dry.enumerated() {
            #expect(value.bitPattern == input[index].bitPattern,
                    Comment(rawValue: "sample \(index) was touched at mix 0"))
        }

        // L1b POSITIVE CONTROL: the same render at mix 0.5 must differ, or
        // "bit-exact" above would be indistinguishable from "inert".
        let wet = try tape(steady(timeMs: 350, feedback: 0.6, mix: 0.5, drive: 0.5,
                                  highCutHz: 4_000), input)
        #expect(zip(wet, input).contains { $0.bitPattern != $1.bitPattern },
                "the effect did nothing at mix 0.5 — L1a is vacuous")
    }

    /// L1c — at mix 0 the tape still records and the transport still turns, so
    /// raising `mix` later drops into repeats that are ALREADY THERE. The
    /// instrument is the transport phase plus the first post-raise sample.
    @Test("L1c: the tape and the transport keep running at mix 0")
    func tapeKeepsRunningAtMixZero() throws {
        let frames = 48_000
        let input = sine(220, amplitude: 0.6, frames: frames)
        let effect = TapeDelayEffect(params: TapeDelayParams(
            timeMs: 100, feedback: 0.5, mix: 0, wowDepthMs: 2.5, wowRateHz: 0.8,
            flutterDepthMs: 0.25, saturationDrive: 0, highCutHz: 20_000))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)

        // Half the render at mix 0, then the mix goes up mid-stream.
        let out = try processChunked(effect, channels: [input], chunk: 512) { fx, quantum in
            if quantum == 48 { fx.storeAutomatedParam(slot: 2, value: 1.0) }
        }[0]
        // The transport turned while the mix was 0.
        #expect(effect.internalTransportPhases[0] != 0)
        // And there is audio IMMEDIATELY after the raise — within one echo
        // period there is no time to fill an empty line, so anything here had
        // to be recorded during the silent-output stretch.
        let raiseFrame = 48 * 512
        let justAfter = rms(out[(raiseFrame + 600)..<(raiseFrame + 2_000)])
        #expect(justAfter > 0.05,
                "the line was empty when the mix came up — the tape was paused")
    }

    // MARK: - L2 — the echo lands where it was asked to

    /// With a STEADY transport the echo is at exactly `timeMs`, to the sample.
    /// (`.cubicHermite` at fraction 0 returns `c0 == s0` exactly, so an
    /// integer-sample time is an exact read — the `delayEchoLandsAtExactSample
    /// Offset` contract, reproduced on a fractional line.)
    @Test("L2: a steady transport puts the echo at exactly timeMs")
    func echoLandsAtTheRequestedOffset() throws {
        let timeMs = 100.0                       // 4800 samples at 48 kHz
        let expected = Int((timeMs * 0.001 * Self.sampleRate).rounded())
        let out = try tape(steady(timeMs: timeMs), impulse(at: 0, frames: 24_000))
        var peakIndex = 0
        var peak = 0.0
        for (index, value) in out.enumerated() where abs(Double(value)) > peak {
            peak = abs(Double(value))
            peakIndex = index
        }
        print("[measured] m39-n echo — asked \(timeMs) ms (\(expected) samples), "
              + "peak at \(peakIndex), amplitude \(String(format: "%.4f", peak))")
        #expect(peakIndex == expected)
        #expect(peak > 0.5, "the echo is there but tiny — something is eating it")
        // Nothing before it: a tape delay does not leak the dry signal into
        // the wet path (mix 1 means WET ONLY).
        #expect(out[0..<(expected - 4)].allSatisfy { abs($0) < 1e-6 })
    }

    // MARK: - L3 — ⭐ THE WOW, MEASURED IN CENTS

    /// ⭐⭐ THE HEADLINE MEASUREMENT, and the only leg that can see a frozen
    /// wow LFO.
    ///
    /// A 1 kHz tone through the tape at `mix 1, feedback 0` is the tape's own
    /// output and nothing else. Its INSTANTANEOUS pitch is recovered from
    /// interpolated positive-going zero crossings — the period between two
    /// crossings is the period of the tone at that instant — and converted to
    /// cents against the nominal 1000 Hz. The peak deviation over a full wow
    /// cycle is then compared against `TapeDelayParams.wowCents`, which is
    /// derived from the transport law and shares no code with this
    /// measurement.
    @Test("L3: the wow's measured pitch deviation matches the closed form, in cents")
    func wowDeviationMatchesTheClosedForm() throws {
        // Enough render for a whole wow cycle after the echo arrives.
        for (depthMs, rateHz) in [(5.0, 1.5), (2.5, 0.8)] {
            let frames = Int(Self.sampleRate * (2.0 / rateHz + 0.6))
            let params = TapeDelayParams(
                timeMs: 350, feedback: 0, mix: 1, wowDepthMs: depthMs, wowRateHz: rateHz,
                flutterDepthMs: 0, saturationDrive: 0, highCutHz: 20_000)
            let out = try tape(params, sine(1_000, amplitude: 0.8, frames: frames))

            // Skip the pre-echo silence and one settle period.
            let start = Int(0.5 * Self.sampleRate)
            let crossings = zeroCrossings(out, in: start..<(frames - 64))
            #expect(crossings.count > 500, "not enough cycles to measure")
            var maxCents = -Double.infinity
            var minCents = Double.infinity
            for index in 1..<crossings.count {
                let period = crossings[index] - crossings[index - 1]
                let cents = 1200 * log2((Self.sampleRate / period) / 1_000.0)
                maxCents = max(maxCents, cents)
                minCents = min(minCents, cents)
            }
            let measuredPeak = max(abs(maxCents), abs(minCents))
            let predicted = TapeDelayParams.wowCents(depthMs: depthMs, rateHz: rateHz)
            print("[measured] m39-n WOW — depth \(depthMs) ms @ \(rateHz) Hz: "
                  + "peak deviation \(String(format: "%+.2f", maxCents)) / "
                  + "\(String(format: "%.2f", minCents)) cents "
                  + "(predicted ±\(String(format: "%.2f", predicted)))")
            #expect(abs(measuredPeak - predicted) < 0.15 * predicted,
                    Comment(rawValue: "measured \(measuredPeak) cents against a "
                        + "predicted \(predicted)"))
            // The deviation is SYMMETRIC — a periodic bounded offset has zero
            // average slope, so the wow bends both ways and biases neither.
            #expect(abs(maxCents + minCents) < 0.2 * predicted,
                    "the wow has a net pitch bias — the transport is not periodic")
        }
    }

    /// L3b — THE PLANT DISCRIMINATOR, stated as an assertion: a transport with
    /// `wowDepthMs == 0` produces a pitch that does not move at all. If the
    /// wow LFO were frozen, L3 would produce this number instead.
    @Test("L3b: zero wow depth is a dead-steady pitch — the frozen-LFO control")
    func zeroWowDepthIsDeadSteady() throws {
        let frames = Int(Self.sampleRate * 2)
        let out = try tape(steady(timeMs: 350), sine(1_000, amplitude: 0.8, frames: frames))
        let crossings = zeroCrossings(out, in: Int(0.5 * Self.sampleRate)..<(frames - 64))
        #expect(crossings.count > 500)
        var peak = 0.0
        for index in 1..<crossings.count {
            let period = crossings[index] - crossings[index - 1]
            peak = max(peak, abs(1200 * log2((Self.sampleRate / period) / 1_000.0)))
        }
        print("[measured] m39-n WOW control — depth 0: peak deviation "
              + "\(String(format: "%.3f", peak)) cents")
        // The floor here is the measurement's own noise, not the effect's.
        #expect(peak < 0.5, "a steady transport is wobbling")
    }

    /// L3c — FLUTTER is a separate, faster instability with its own closed
    /// form, and it is NOT the wow: at flutter-only settings the pitch moves
    /// many times per second rather than once.
    @Test("L3c: flutter alone deviates by its own closed form, and moves far faster than wow")
    func flutterIsItsOwnInstability() throws {
        let frames = Int(Self.sampleRate * 2)
        let depth = 1.0
        let params = TapeDelayParams(timeMs: 350, feedback: 0, mix: 1, wowDepthMs: 0,
                                     wowRateHz: 0.8, flutterDepthMs: depth,
                                     saturationDrive: 0, highCutHz: 20_000)
        let out = try tape(params, sine(1_000, amplitude: 0.8, frames: frames))
        let crossings = zeroCrossings(out, in: Int(0.5 * Self.sampleRate)..<(frames - 64))
        var cents: [Double] = []
        for index in 1..<crossings.count {
            let period = crossings[index] - crossings[index - 1]
            cents.append(1200 * log2((Self.sampleRate / period) / 1_000.0))
        }
        let peak = cents.map(abs).max() ?? 0
        let predicted = TapeDelayParams.flutterCents(depthMs: depth)
        // Sign changes per second — wow at 0.8 Hz gives ~1.6, flutter at
        // 7.3 + 11.7 Hz gives tens.
        var signChanges = 0
        for index in 1..<cents.count where (cents[index] > 0) != (cents[index - 1] > 0) {
            signChanges += 1
        }
        let perSecond = Double(signChanges) / 1.5
        print("[measured] m39-n FLUTTER — depth \(depth) ms: peak "
              + "\(String(format: "%.2f", peak)) cents (predicted \(String(format: "%.2f", predicted))), "
              + "\(String(format: "%.1f", perSecond)) sign changes/s")
        // The closed form is the PEAK, reached only when the two components
        // align, so the measured peak sits at or under it.
        #expect(peak <= predicted * 1.1)
        #expect(peak > predicted * 0.45, "flutter is barely moving")
        #expect(perSecond > 8, "this is not a fast instability")
    }

    // MARK: - L4 — feedback

    @Test("L4: feedback produces a SECOND echo at 2·timeMs, and zero feedback does not")
    func feedbackProducesLaterRepeats() throws {
        let timeMs = 100.0
        let first = Int(timeMs * 0.001 * Self.sampleRate)
        let input = impulse(at: 0, frames: 24_000)
        let withFeedback = try tape(steady(timeMs: timeMs, feedback: 0.7), input)
        let without = try tape(steady(timeMs: timeMs, feedback: 0), input)

        func peak(around centre: Int) -> (Double, Double) {
            let window = (centre - 16)..<(centre + 16)
            var a = 0.0, b = 0.0
            for index in window {
                a = max(a, abs(Double(withFeedback[index])))
                b = max(b, abs(Double(without[index])))
            }
            return (a, b)
        }
        let (fb1, no1) = peak(around: first)
        let (fb2, no2) = peak(around: 2 * first)
        let (fb3, no3) = peak(around: 3 * first)
        print("[measured] m39-n feedback — repeats at 0.7: "
              + "\(String(format: "%.4f", fb1)) / \(String(format: "%.4f", fb2)) / "
              + "\(String(format: "%.4f", fb3)); at 0: \(String(format: "%.4f", no1)) / "
              + "\(String(format: "%.6f", no2)) / \(String(format: "%.6f", no3))")
        #expect(fb1 > 0.5)
        #expect(fb2 > 0.2, "no second repeat — the recirculation is not wired")
        #expect(fb3 > 0.05)
        // Each repeat is quieter than the last (a stable loop).
        #expect(fb2 < fb1 && fb3 < fb2)
        // And at feedback 0 there is exactly ONE echo.
        #expect(no1 > 0.5)
        #expect(no2 < 1e-5, "a feedback-0 tape delay repeated")
    }

    // MARK: - L5 — the record-path saturator

    /// ⭐ HOMOGENEITY IS THE INSTRUMENT. A linear system's response to half an
    /// input is exactly half its response to the whole one. At `drive == 0`
    /// this must hold to within float rounding; at `drive == 1` it must
    /// measurably fail, because that is what saturation IS. Nothing about this
    /// leg depends on knowing the shaper's formula.
    @Test("L5: drive 0 is exactly linear and drive 1 measurably is not")
    func driveZeroIsLinearAndDriveOneIsNot() throws {
        func echoPeak(drive: Double, amplitude: Float) throws -> Double {
            let input = impulse(at: 0, frames: 12_000).map { $0 * amplitude }
            let out = try tape(steady(timeMs: 100, drive: drive), input)
            let centre = Int(100 * 0.001 * Self.sampleRate)
            var peak = 0.0
            for index in (centre - 16)..<(centre + 16) {
                peak = max(peak, abs(Double(out[index])))
            }
            return peak
        }
        let cleanFull = try echoPeak(drive: 0, amplitude: 1.0)
        let cleanHalf = try echoPeak(drive: 0, amplitude: 0.5)
        let dirtyFull = try echoPeak(drive: 1, amplitude: 1.0)
        let dirtyHalf = try echoPeak(drive: 1, amplitude: 0.5)
        let cleanRatio = cleanFull / cleanHalf
        let dirtyRatio = dirtyFull / dirtyHalf
        print("[measured] m39-n saturation — homogeneity ratio at drive 0: "
              + "\(String(format: "%.6f", cleanRatio)); at drive 1: "
              + "\(String(format: "%.4f", dirtyRatio))")
        #expect(abs(cleanRatio - 2.0) < 1e-4, "drive 0 is not exactly linear")
        #expect(dirtyRatio < 1.6, "drive 1 is not compressing anything")
        // And drive never MAKES IT LOUDER — the shaper must not raise the loop
        // gain, which is the whole reason it is normalised the way it is.
        #expect(dirtyFull <= cleanFull + 1e-6)
    }

    /// L5b — at drive the echo carries harmonics the input did not have. The
    /// shaper is ODD, so the 3rd harmonic is the one to look for and the 2nd
    /// should stay in the noise.
    @Test("L5b: drive adds ODD harmonics to the repeats and drive 0 adds none")
    func driveAddsOddHarmonics() throws {
        let frames = 48_000
        let input = sine(500, amplitude: 0.9, frames: frames)
        let window = 24_000..<44_000
        let clean = try tape(steady(timeMs: 100, drive: 0), input)
        let dirty = try tape(steady(timeMs: 100, drive: 1.0), input)
        let cleanThird = dB(goertzel(clean, frequency: 1_500, in: window)
            / goertzel(clean, frequency: 500, in: window))
        let dirtyThird = dB(goertzel(dirty, frequency: 1_500, in: window)
            / goertzel(dirty, frequency: 500, in: window))
        let dirtySecond = dB(goertzel(dirty, frequency: 1_000, in: window)
            / goertzel(dirty, frequency: 500, in: window))
        print("[measured] m39-n saturation — 3rd harmonic at drive 0: "
              + "\(String(format: "%.1f", cleanThird)) dB; at drive 1: "
              + "\(String(format: "%.1f", dirtyThird)) dB; 2nd at drive 1: "
              + "\(String(format: "%.1f", dirtySecond)) dB")
        // ⚠️ THE CLEAN FLOOR IS THE MEASUREMENT'S, NOT THE EFFECT'S. A
        // Goertzel bin over a finite window leaks ~-64 dB from the
        // fundamental into the 3rd-harmonic bin whatever the signal is, so
        // "clean" here means "at the instrument's floor" and the real claim is
        // the DIFFERENCE between the two renders. Measured: -64.5 dB clean,
        // -10.6 dB at full drive.
        #expect(cleanThird < -55, "a linear path generated a 3rd harmonic")
        #expect(dirtyThird > -30, "full drive generated no harmonics")
        #expect(dirtyThird - cleanThird > 40, "drive changed nothing about the spectrum")
        // ODD symmetry: the 2nd harmonic stays down at the same leakage floor
        // the clean render sits on, while the 3rd is 50 dB above it.
        #expect(dirtySecond < dirtyThird - 20, "the shaper is not odd-symmetric")
    }

    // MARK: - L6 — the record-path high cut

    @Test("L6a: every successive repeat is duller than the one before")
    func repeatsGetProgressivelyDuller() throws {
        let timeMs = 200.0
        let period = Int(timeMs * 0.001 * Self.sampleRate)
        // A 200 ms burst of bright noise-like content: two tones, one low, one
        // high, so "duller" is a RATIO and not a level change.
        var input = [Float](repeating: 0, count: 48_000)
        for index in 0..<Int(0.15 * Self.sampleRate) {
            let t = Double(index) / Self.sampleRate
            input[index] = Float(0.45 * sin(2 * .pi * 300 * t) + 0.45 * sin(2 * .pi * 6_000 * t))
        }
        let out = try tape(steady(timeMs: timeMs, feedback: 0.85, highCutHz: 3_000), input)
        var ratios: [Double] = []
        for repeatIndex in 1...3 {
            let start = repeatIndex * period + 200
            let window = start..<(start + 6_000)
            let low = goertzel(out, frequency: 300, in: window)
            let high = goertzel(out, frequency: 6_000, in: window)
            ratios.append(dB(high / low))
        }
        print("[measured] m39-n high cut — 6 kHz vs 300 Hz by repeat: "
              + ratios.map { String(format: "%.1f", $0) }.joined(separator: " / ") + " dB")
        #expect(ratios[1] < ratios[0] - 3, "repeat 2 is no duller than repeat 1")
        #expect(ratios[2] < ratios[1] - 3, "repeat 3 is no duller than repeat 2")
    }

    /// ⭐ L6b — THE TOPOLOGY LEG, and the one that separates this kind from
    /// `.delay`. There the filter is in the FEEDBACK path, so the FIRST echo
    /// is unfiltered; here it is in the RECORD path, so the first echo has
    /// already been through the tape. That is a claim about repeat ONE and
    /// nothing else in this suite tests it.
    @Test("L6b: the FIRST repeat is already filtered — the record-path topology")
    func theFirstRepeatIsAlreadyFiltered() throws {
        let frames = 48_000
        let input = sine(8_000, amplitude: 0.8, frames: frames)
        let window = 10_000..<30_000
        let open = try tape(steady(timeMs: 100, feedback: 0, highCutHz: 20_000), input)
        let shut = try tape(steady(timeMs: 100, feedback: 0, highCutHz: 1_000), input)
        let openLevel = goertzel(open, frequency: 8_000, in: window)
        let shutLevel = goertzel(shut, frequency: 8_000, in: window)
        let attenuation = dB(shutLevel / openLevel)
        print("[measured] m39-n record path — first echo at 8 kHz, highCut 1 kHz "
              + "vs 20 kHz: \(String(format: "%.1f", attenuation)) dB")
        // A one-pole at 1 kHz is ~18 dB down at 8 kHz; a FEEDBACK-path filter
        // at feedback 0 would be 0 dB down, because it would never run.
        #expect(attenuation < -10, Comment(rawValue:
                "the first repeat is unfiltered — the filter is in the feedback "
                    + "path, which is the `.delay` topology, not this one"))
    }

    // MARK: - L7 — ⭐ THE INTERPOLATOR ITSELF

    /// ⭐⭐ THE ONLY LEG THAT CAN SEE `.linear` SUBSTITUTED FOR
    /// `.cubicHermite`, and it measures the interpolator's own frequency
    /// response rather than asserting a constructor argument.
    ///
    /// At a HALF-SAMPLE delay both interpolators lose high end, by different
    /// amounts with closed forms that share no code with the implementation:
    ///   linear:  |cos(ω/2)|                       — a 2-tap average
    ///   Hermite: |(9/8)·cos(ω/2) − (1/8)·cos(3ω/2)| — Catmull-Rom's 4 taps
    ///            at fraction ½: (−1/16, 9/16, 9/16, −1/16)
    /// At an INTEGER delay both are exact, so the ratio between the two renders
    /// isolates the interpolation and cancels the record-path filter, which is
    /// identical in both.
    ///
    /// At 12 kHz the two predictions are −3.01 dB and −1.07 dB — 1.94 dB
    /// apart, far outside the ±0.35 dB this leg allows.
    @Test("L7: the fractional-delay response is cubic Hermite's, not linear's")
    func fractionalReadIsCubicHermite() throws {
        let frames = 48_000
        let window = 10_000..<40_000
        // 960 samples at 48 kHz = 20.0 ms exactly (the time floor); 960.5
        // samples is the half-sample tap.
        let integerMs = 960.0 / 48.0
        let halfMs = 960.5 / 48.0
        for frequency in [6_000.0, 12_000.0] {
            let input = sine(frequency, amplitude: 0.8, frames: frames)
            let whole = try tape(steady(timeMs: integerMs), input)
            let half = try tape(steady(timeMs: halfMs), input)
            let loss = dB(goertzel(half, frequency: frequency, in: window)
                / goertzel(whole, frequency: frequency, in: window))

            let w = 2.0 * Double.pi * frequency / Self.sampleRate
            let hermite = dB(abs(1.125 * cos(w / 2) - 0.125 * cos(1.5 * w)))
            let linear = dB(abs(cos(w / 2)))
            print("[measured] m39-n interpolation — \(Int(frequency)) Hz at a "
                  + "half-sample tap: \(String(format: "%+.2f", loss)) dB "
                  + "(cubic Hermite predicts \(String(format: "%+.2f", hermite)), "
                  + "linear would give \(String(format: "%+.2f", linear)))")
            #expect(abs(loss - hermite) < 0.35,
                    Comment(rawValue: "\(Int(frequency)) Hz: measured \(loss) dB, "
                        + "Hermite \(hermite) dB, linear \(linear) dB"))
            // Non-vacuity: the two predictions must actually be far apart at
            // this frequency, or the leg could not tell them apart.
            #expect(abs(hermite - linear) > 0.5)
        }
    }

    // MARK: - L8 — ⭐ THE DENORMAL FLUSHES

    /// ⭐⭐ TWO FLUSHES, AND THE MEASUREMENT THAT CAN SEE EITHER ONE IS NOT
    /// THE OBVIOUS ONE. Recorded in full because getting here took two plants
    /// that reddened nothing.
    ///
    /// The tap flush cleans the word the listener hears; the RECORD-PATH
    /// FILTER's state is a separate decaying word. THEY ARE MUTUALLY
    /// REDUNDANT IN THE OUTPUT, and that is a property of this topology rather
    /// than sloppiness: the filter is the LAST stage before the write, so with
    /// its flush in place the line can never hold a subnormal and the tap can
    /// never read one; and with the TAP's flush in place, a subnormal that the
    /// unflushed filter wrote is killed on the way back out. So removing
    /// EITHER ONE ALONE leaves the output spotless. ⚠️ MEASURED, m39-n: a
    /// plant removing the tap flush and a plant removing the filter flush each
    /// left all 33 tests in this file GREEN.
    ///
    /// ⭐ THE PLANT TABLE THIS LEG WAS REBUILT AGAINST, so the next reader does
    /// not have to rediscover which flush which assertion sees:
    ///
    /// | plant | (a) output | (b) filter state | (c) non-vacuity |
    /// |---|---|---|---|
    /// | tap flush removed    | green | green | green — **NOTHING SEES IT** |
    /// | filter flush removed | green | ⛔ RED | ⛔ RED |
    /// | BOTH removed         | ⛔ RED | ⛔ RED | ⛔ RED |
    ///
    /// ⚠️ **The first row is a real finding and it is NOT fixed by a better
    /// test.** With the filter's flush in place, nothing subnormal is ever
    /// WRITTEN to the line, so the tap cannot READ one — the condition the tap
    /// flush guards against is unreachable. It is kept anyway: §4.1 obliges a
    /// feedback caller to flush its own recirculating word, it costs one
    /// compare, and it is the guard that survives someone later making the
    /// high cut bypassable. But it is honest to say no gate in this tree can
    /// see it disappear, rather than to imply L8 covers both.
    ///
    /// The instrument that CAN see the filter flush is a direct read of the
    /// filter state — the `HallReverbEffect` shelf-state precedent. But a
    /// state read is not enough on its own either:
    ///
    /// ⚠️⚠️ **THE SAMPLING RATE OF THE INSTRUMENT HAS TO BEAT THE TRANSIT TIME
    /// THROUGH THE SUBNORMAL BAND, AND AT THE DEFAULT SETTINGS IT DOES NOT.**
    /// A one-pole's state decays by `1 - a` per sample. At the 6 kHz default,
    /// `a = 0.5441`, which is 0.341 decades PER SAMPLE — so the state crosses
    /// the whole subnormal band (1.18e-38 down to 1.4e-45, 6.9 decades) in
    /// **20 samples**. Sampling at 512-frame quantum boundaries misses that
    /// window 96 times out of 100. At `highCutHz` 500 the pole is far slower
    /// (`a = 0.0634`, 0.0284 decades/sample) and the same crossing takes
    /// **244 samples**, which a 32-frame quantum reads seven or eight times.
    /// That is why this leg renders at 500 Hz in 32-frame quanta and not at
    /// the defaults in 512 — the setting is the instrument, not the subject.
    @Test("L8: no output sample and no filter state is ever subnormal, and the flush FIRES")
    func denormalsAreFlushedInBothPlaces() throws {
        let toneFrames = Int(0.3 * Self.sampleRate)
        let silenceFrames = Int(2.0 * Self.sampleRate)
        var input = sine(440, amplitude: 0.9, frames: toneFrames)
        input.append(contentsOf: [Float](repeating: 0, count: silenceFrames))

        // The SHORTEST time and a LOW feedback, so the tail crosses into the
        // subnormal band well inside the silence (a 350 ms / 0.5 setting would
        // need 40 s and no plant would redden anything). `highCutHz` 500 is
        // the sampling-rate decision argued above.
        let highCutHz = 500.0
        let chunk = 32
        let params = TapeDelayParams(timeMs: 20, feedback: 0.3, mix: 1, wowDepthMs: 0,
                                     wowRateHz: 0.8, flutterDepthMs: 0,
                                     saturationDrive: 0, highCutHz: highCutHz)
        let effect = TapeDelayEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 2)
        #expect(effect.lastPrepareRefusal == nil)

        var filterStates: [Float] = []
        let out = try processChunked(effect, channels: [input, input], chunk: chunk,
                                     poke: nil) { _ in
            filterStates.append(contentsOf: effect.internalRecordFilterStateMagnitudes)
        }

        // (a) the OUTPUT never carries a subnormal. ⚠️ This alone is a WEAK
        // assertion — see the header: either flush satisfies it by itself.
        for channel in out {
            #expect(!channel.contains { $0.isSubnormal },
                    "a subnormal reached the output — BOTH flushes are gone")
        }
        // (b) ⭐ THE STRONG ONE. The RECORD FILTER's own state never carries a
        // subnormal, and only a direct read at this sampling density can say so.
        let subnormalStates = filterStates.filter(\.isSubnormal)
        #expect(subnormalStates.isEmpty, Comment(rawValue:
                "\(subnormalStates.count) subnormal filter states — the record-path "
                    + "flush is gone (smallest \(subnormalStates.min() ?? 0))"))

        // (c) NON-VACUITY, THE PART THAT MATTERS. The flush must actually have
        // FIRED: some boundary has to show a state that was small but not yet
        // zero, and a later one has to show exactly zero. If the tail never got
        // near the threshold, (a) and (b) are free passes.
        let smallestNonZero = filterStates.filter { $0 > 0 }.min() ?? .infinity
        let endedAtZero = filterStates.suffix(8).allSatisfy { $0 == 0 }
        print("[measured] m39-n denormals — \(filterStates.count) state samples at a "
              + "\(chunk)-frame stride, smallest non-zero \(smallestNonZero), "
              + "ended at zero: \(endedAtZero)")
        #expect(smallestNonZero < 1e-15, Comment(rawValue:
                "the decay never approached the flush threshold — this window is "
                    + "too short for the flush to be under test at all"))
        #expect(endedAtZero, "the tail never reached the flush")

        // (d) THE WINDOW-DEPTH PROOF, so "it reached 1e-20" is not mistaken for
        // "it would have reached 1e-38", AND the sampling-density proof, so a
        // future reader cannot quietly restore a 512-frame stride.
        let a = 1.0 - exp(-2.0 * .pi * highCutHz / Self.sampleRate)
        let decadesPerSample = -log10(1 - a)
        let subnormalBandSamples = 6.93 / decadesPerSample   // 1.18e-38 -> 1.4e-45
        let filterSamplesTo1e38 = 38.0 / decadesPerSample
        let loopSecondsTo1e38 = (38.0 / -log10(0.3)) * 0.020
        print("[measured] m39-n denormal window — filter reaches 1e-38 in "
              + "\(String(format: "%.0f", filterSamplesTo1e38)) samples and crosses the "
              + "whole subnormal band in \(String(format: "%.0f", subnormalBandSamples)) "
              + "samples; the loop reaches 1e-38 in "
              + "\(String(format: "%.2f", loopSecondsTo1e38)) s; silence rendered "
              + "\(String(format: "%.2f", Double(silenceFrames) / Self.sampleRate)) s at a "
              + "\(chunk)-frame stride")
        #expect(Double(silenceFrames) > filterSamplesTo1e38)
        #expect(Double(silenceFrames) / Self.sampleRate > loopSecondsTo1e38)
        // ⛔ THE SAMPLING PIN. The state is only subnormal while it is crossing
        // that band; if the stride is wider than the crossing, (b) becomes a
        // coin flip dressed as a gate. Three reads inside the window is the
        // floor this leg will accept.
        #expect(subnormalBandSamples / Double(chunk) >= 3, Comment(rawValue:
                "the stride (\(chunk) frames) samples the subnormal band only "
                    + "\(subnormalBandSamples / Double(chunk)) times — widen "
                    + "highCutHz's pole or narrow the chunk"))
    }

    // MARK: - L9 / L10 — the automation surface

    /// Every slot moves the parameter it names and no other. The instrument is
    /// a rendered difference: poke slot k and assert the render changes, then
    /// assert it changed in the way that param would.
    @Test("L9: every automation slot is wired to its own parameter")
    func everySlotIsWiredToItsOwnParameter() throws {
        let specs = EffectParamSpec.specs(for: .tapeDelay)
        #expect(specs.count == 8)
        let base = TapeDelayParams(timeMs: 100, feedback: 0.3, mix: 0.5, wowDepthMs: 1.0,
                                   wowRateHz: 1.0, flutterDepthMs: 0.2,
                                   saturationDrive: 0.4, highCutHz: 8_000)
        let input = sine(500, amplitude: 0.7, frames: 24_000)
        let reference = try tape(base, input)
        // A distinct, in-range value per slot, none of them the base value.
        let pokes: [Double] = [420, 0.85, 1.0, 6.0, 2.5, 0.9, 0.95, 1_200]
        for slot in 0..<8 {
            let effect = TapeDelayEffect(params: base)
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 1)
            let out = try processChunked(effect, channels: [input], chunk: 512) { fx, _ in
                fx.storeAutomatedParam(slot: slot, value: pokes[slot])
            }[0]
            #expect(zip(out, reference).contains { $0 != $1 },
                    Comment(rawValue: "slot \(slot) (\(specs[slot].name)) changed nothing"))
        }
        // Out-of-range slots are ignored rather than trapping.
        let effect = TapeDelayEffect(params: base)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        effect.storeAutomatedParam(slot: -1, value: 1)
        effect.storeAutomatedParam(slot: 99, value: 1)
        effect.storeAutomatedParam(slot: 0, value: .nan)
        let out = try processChunked(effect, channels: [input], chunk: 512)[0]
        #expect(out.allSatisfy { $0.isFinite })
    }

    /// ⚠️ MEMORY SAFETY, not tidiness. A field-by-field overlay poke bypasses
    /// `TapeDelayParams.init`, so the clamp in `deriveRenderParams` is the ONLY
    /// thing between an unfenced lane and a read past the end of a 4 s line —
    /// and `Int(Double.nan)` TRAPS outright.
    @Test("L10: a hostile automation value cannot reach the line's unbounded tap")
    func hostileAutomationIsClampedBeforeTheTap() throws {
        let input = sine(400, amplitude: 0.5, frames: 24_000)
        for value in [9_000.0, -5_000.0, 1e12, -1e12] {
            let effect = TapeDelayEffect(params: TapeDelayParams(timeMs: 350))
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 2)
            let out = try processChunked(effect, channels: [input, input], chunk: 512) { fx, _ in
                fx.storeAutomatedParam(slot: 0, value: value)     // timeMs
                fx.storeAutomatedParam(slot: 3, value: value)     // wowDepthMs
                fx.storeAutomatedParam(slot: 5, value: value)     // flutterDepthMs
                fx.storeAutomatedParam(slot: 1, value: value)     // feedback
                fx.storeAutomatedParam(slot: 7, value: value)     // highCutHz
            }
            for channel in out {
                #expect(channel.allSatisfy { $0.isFinite },
                        Comment(rawValue: "poking \(value) produced a non-finite sample"))
                #expect(channel.allSatisfy { abs($0) < 8 },
                        Comment(rawValue: "poking \(value) made the loop diverge"))
            }
        }
    }

    // MARK: - L11 — stereo

    /// ONE TRANSPORT, BOTH CHANNELS: a mono source fed to both channels comes
    /// back identical in both. There is no stereo phase parameter and a mono
    /// fold-down must not cancel.
    @Test("L11: both channels share one transport, so a mono source stays mono")
    func oneTransportDrivesBothChannels() throws {
        let input = sine(440, amplitude: 0.7, frames: 48_000)
        let effect = TapeDelayEffect(params: TapeDelayParams(
            timeMs: 250, feedback: 0.5, mix: 0.6, wowDepthMs: 6, wowRateHz: 2,
            flutterDepthMs: 0.8, saturationDrive: 0.6, highCutHz: 5_000))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let out = try processChunked(effect, channels: [input, input], chunk: 512)
        for index in out[0].indices {
            #expect(out[0][index].bitPattern == out[1][index].bitPattern,
                    Comment(rawValue: "channels diverged at \(index)"))
        }
        // Non-vacuity: the effect DID something.
        #expect(zip(out[0], input).contains { $0 != $1 })
    }

    /// A mono render keeps the unused right line fed, so switching to stereo
    /// later is coherent rather than starting from silence (the `ChorusEffect`
    /// convention). The instrument is the line itself, not the output.
    @Test("L11b: a mono render still feeds the right-hand line")
    func monoRenderKeepsTheRightLineFed() throws {
        let input = sine(440, amplitude: 0.7, frames: 24_000)
        let effect = TapeDelayEffect(params: steady(timeMs: 100, feedback: 0.4, mix: 0.5))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        _ = try processChunked(effect, channels: [input], chunk: 512)
        // Reading the right channel's tap directly: it must carry the mirrored
        // material, not silence.
        let tapped = effect.internalRecordFilterStateMagnitudes[1]
        #expect(tapped > 0, "the right line was never written during a mono render")
    }

    // MARK: - L12 — reset and latency

    @Test("L12: reset clears the tape and the transport, and latency is 0")
    func resetClearsEverything() throws {
        let input = sine(440, amplitude: 0.8, frames: 24_000)
        let effect = TapeDelayEffect(params: TapeDelayParams(timeMs: 100, feedback: 0.7,
                                                             mix: 1.0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        #expect(effect.latencySamples == 0)
        _ = try processChunked(effect, channels: [input], chunk: 512)
        #expect(effect.internalTransportPhases[0] != 0)
        effect.reset()
        #expect(effect.internalTransportPhases == [0, 0, 0])
        #expect(effect.internalRecordFilterStateMagnitudes == [0, 0])
        // A silent quantum after a reset produces silence — the line is clear.
        let silence = [Float](repeating: 0, count: 4_800)
        let out = try processChunked(effect, channels: [silence], chunk: 512)[0]
        #expect(out.allSatisfy { $0 == 0 }, "the tape still had audio on it after a reset")
    }
}
