import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, DELIBERATELY **NOT** `@MainActor` — the `PhaserTests` /
// `RingModTests` / `FlangerTests` rule, for their reasons: the main actor is one
// serialization point for the whole test process, these tests render hundreds of
// thousands of frames, and `MainActorOccupancySiteTests` Leg C pins the
// main-actor SUITE count at its cap with ZERO slack.
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-z — the `.freqShifter` insert. `FreqShifterParams` holds the laws; this
/// suite proves the RENDERED AUDIO obeys them.
///
/// ⭐⭐ **THE CENTRAL LEG IS L1, AND IT IS THE ONLY KIND OF TEST THAT CAN TELL A
/// FREQUENCY SHIFTER FROM A RING MODULATOR.** Both are "a carrier times the
/// signal", both sound metallic, and a test that shows "the output changed"
/// cannot distinguish them — nor can a byte-difference gate, which was MEASURED
/// on 2026-09-19 to pass a completely inert effect. So L1 measures **three
/// separate spectral bins** and asserts the shape that only single-sideband
/// modulation produces:
///
///   · the WANTED sideband at `f0 + Δ` is present at nearly full amplitude
///   · the UNWANTED sideband at `f0 − Δ` is suppressed by ≥ 40 dB
///   · the CARRIER leakage at `f0` itself is suppressed by ≥ 40 dB
///
/// A ring modulator fails the second (both sidebands are equal). A tremolo or
/// an amplitude modulator fails the third. An inert effect fails the first.
///
/// ⛔ **40 dB IS THE GATE, ~49.7 dB IS THE MEASUREMENT.** The margin is
/// deliberate: it is wide enough that a rebuild on another machine cannot
/// flicker, and narrow enough that losing the network's quadrature (which
/// collapses the rejection to ~0 dB) reddens instantly.
/// ⛔⛔ `.serialized` IS LOAD-BEARING AND WAS PAID FOR TWICE.
/// L11 installs a process-global `malloc_logger` hook. Without this trait the
/// suite's other sixteen tests — most of which render through Swift `Array`s —
/// run CONCURRENTLY with it, and L11 read **3 764 686** events in one full-suite
/// run while reading a clean 0 in the very next one and 0 in every filtered run.
/// ⚠️ An intermittent that reports a LARGE number is survivable; the same race
/// reporting a SMALL one would read as "the render path allocates a little",
/// which is a sentence that must never be true and would be debugged as a real
/// DSP defect. Every sibling probe in this directory (`PhaserTests`,
/// `RingModTests`, `StereoWidthTests`, `BitCrusherTests`, `TransientShaperTests`)
/// carries `.serialized` for the same reason; this suite was the only one that
/// did not, which is the SECOND time this probe's instrument disagreed with its
/// neighbours and the neighbours were right. When four instruments agree and
/// yours does not, suspect your instrument.
@Suite("m39-z — the frequency shifter renders single-sideband", .serialized)
struct FreqShifterTests {

    private static let sampleRate = 48_000.0

    // MARK: - Instruments

    /// Goertzel magnitude at `hz`, normalised so a full-scale sine at an exact
    /// bin reads 1.0.
    ///
    /// ⚠️ EVERY CALLER USES A WINDOW OF EXACTLY `sampleRate` SAMPLES, so the bin
    /// spacing is 1 Hz and every integer frequency is an EXACT bin. That is not
    /// a detail: with a ragged window the spectral leakage floor is about
    /// −52 dB, which is ABOVE the −49.7 dB rejection being measured, and the
    /// test would be reading its own window rather than the effect.
    private static func goertzel(_ buffer: [Float], hz: Double) -> Double {
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

    private static func sine(hz: Double, frames: Int, amplitude: Double = 0.5) -> [Float] {
        (0..<frames).map { Float(amplitude * sin(2 * Double.pi * hz * Double($0) / sampleRate)) }
    }

    /// Renders `channels` through `effect` in `chunk`-frame quanta, exactly as
    /// the graph would. `poke` runs before each quantum.
    private func processChunked(
        _ effect: FreqShifterEffect, channels: [[Float]], chunk: Int = 512,
        poke: ((FreqShifterEffect, Int) -> Void)? = nil
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

    private func shift(_ params: FreqShifterParams, _ input: [Float],
                       chunk: Int = 512) throws -> [Float] {
        let effect = FreqShifterEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk, channelCount: 1)
        return try processChunked(effect, channels: [input], chunk: chunk)[0]
    }

    /// Discards the network's start-up transient, then keeps EXACTLY one second
    /// so every integer frequency is an exact Goertzel bin.
    private static let warmupFrames = 8_192
    private static var analysisFrames: Int { Int(sampleRate) }
    private static var totalFrames: Int { warmupFrames + analysisFrames }

    private func analyse(_ rendered: [Float]) -> [Float] {
        Array(rendered[Self.warmupFrames...])
    }

    // MARK: - L1: THE PHYSICS

    /// ⛔ The leg the whole kind stands on. Three bins, three different failure
    /// modes, each naming the wrong implementation it catches.
    @Test("L1 — a sine at f0 shifted by +D appears at f0+D, with BOTH the image and the carrier down >= 40 dB")
    func upwardShiftIsSingleSideband() throws {
        let f0 = 1_000.0
        let delta = 200.0
        let input = Self.sine(hz: f0, frames: Self.totalFrames)
        let rendered = try shift(
            FreqShifterParams(shiftHz: delta, mix: 1), input)
        let tail = analyse(rendered)

        let wanted = Self.db(Self.goertzel(tail, hz: f0 + delta))
        let image = Self.db(Self.goertzel(tail, hz: f0 - delta))
        let carrier = Self.db(Self.goertzel(tail, hz: f0))
        print("[measured] up-shift: wanted \(f0 + delta) Hz \(wanted) dB | "
              + "image \(f0 - delta) Hz \(image) dB | carrier \(f0) Hz \(carrier) dB "
              + "| rejection \(wanted - image) dB")

        // 1. THE EFFECT HAPPENED. Input is 0.5 full-scale = −6.02 dB; the
        //    network is all-pass so the wanted sideband keeps that amplitude.
        #expect(wanted > -7.5, "nothing arrived at f0+D — the effect is INERT")
        #expect(wanted < -4.5, "f0+D is louder than the input — the network is not all-pass")
        // 2. NOT A RING MODULATOR. A ring mod puts the image at the SAME
        //    amplitude as the wanted sideband; this is the assertion that
        //    separates the two kinds, and it is what the all-pass sign trap
        //    (DESIGN §2.2) breaks.
        #expect(wanted - image >= 40, """
            unwanted sideband only \(wanted - image) dB down — this is DOUBLE-sideband \
            modulation, i.e. a ring modulator, not a frequency shifter
            """)
        // 3. NOT A TREMOLO / AMPLITUDE MODULATOR. Those keep the original
        //    partial; true SSB removes it.
        #expect(wanted - carrier >= 40, """
            the original f0 survives only \(wanted - carrier) dB down — the input is leaking \
            through, which makes this an amplitude modulator
            """)
    }

    /// ⛔ ANTI-VACUITY FOR THE PROBE ITSELF. A Goertzel that reads ~0 everywhere
    /// would pass nothing, but one that reads FULL SCALE everywhere would pass
    /// L1's first assertion while the other two carried the weight. This shows
    /// the probe resolves the three bins on a signal whose spectrum is known.
    @Test("L1b — POSITIVE CONTROL: the Goertzel probe separates bins on a known signal")
    func theGoertzelProbeIsSharp() {
        let pure = Self.sine(hz: 1_000, frames: Self.analysisFrames, amplitude: 0.5)
        let atSignal = Self.db(Self.goertzel(pure, hz: 1_000))
        let atImage = Self.db(Self.goertzel(pure, hz: 800))
        let atOther = Self.db(Self.goertzel(pure, hz: 1_200))
        print("[measured] probe on a pure 1 kHz sine: @1000 \(atSignal) dB, "
              + "@800 \(atImage) dB, @1200 \(atOther) dB")
        #expect(abs(atSignal - (-6.0206)) < 0.01, "the probe misreads a known amplitude")
        // The floor must be far below the 40 dB the gate asserts, or L1 would
        // be measuring the window instead of the effect.
        #expect(atImage < -100)
        #expect(atOther < -100)
    }

    /// The SIGN is the direction, and that is the mechanism that lets `shiftHz`
    /// sweep through zero. A build that took `abs(shiftHz)` would pass L1 and
    /// fail here.
    @Test("L2 — a NEGATIVE shift puts the energy BELOW f0, not above it")
    func downwardShiftGoesDown() throws {
        let f0 = 1_000.0
        let delta = 200.0
        let input = Self.sine(hz: f0, frames: Self.totalFrames)
        let tail = analyse(try shift(FreqShifterParams(shiftHz: -delta, mix: 1), input))

        let wanted = Self.db(Self.goertzel(tail, hz: f0 - delta))
        let image = Self.db(Self.goertzel(tail, hz: f0 + delta))
        print("[measured] down-shift: wanted \(f0 - delta) Hz \(wanted) dB | "
              + "image \(f0 + delta) Hz \(image) dB | rejection \(wanted - image) dB")
        #expect(wanted > -7.5)
        #expect(wanted - image >= 40, """
            a negative shift must select the LOWER sideband — got only \(wanted - image) dB \
            of separation
            """)
    }

    /// ⭐ THE INHARMONICITY, MEASURED. This is the assertion that states what
    /// makes the kind worth having: a harmonic series goes in, a NON-harmonic
    /// set of partials comes out, and a pitch shifter could not do this.
    @Test("L3 — a harmonic series 100/200/300 becomes 200/300/400, which is NOT a harmonic series")
    func aHarmonicSeriesBecomesInharmonic() throws {
        let frames = Self.totalFrames
        var input = [Float](repeating: 0, count: frames)
        for harmonic in [100.0, 200.0, 300.0] {
            let partial = Self.sine(hz: harmonic, frames: frames, amplitude: 0.2)
            for index in 0..<frames { input[index] += partial[index] }
        }
        let tail = analyse(try shift(FreqShifterParams(shiftHz: 100, mix: 1), input))

        let landed = [200.0, 300.0, 400.0].map { Self.db(Self.goertzel(tail, hz: $0)) }
        // Where a PITCH shifter of the same musical size would have put them.
        let pitched = [400.0, 600.0].map { Self.db(Self.goertzel(tail, hz: $0)) }
        print("[measured] shifted partials @200/300/400 Hz: \(landed); "
              + "pitch-shifter positions @400/600: \(pitched)")
        for (index, level) in landed.enumerated() {
            #expect(level > -22, "partial \(index) did not land at its shifted frequency")
        }
        // ⛔ 600 Hz is where a 2x PITCH shift would have put the 300 Hz partial.
        // It must be EMPTY — that absence is the difference between the two
        // kinds, and it is positively controlled by the three assertions above
        // showing this probe does find partials where they are.
        #expect(pitched[1] < -45, """
            energy at 600 Hz means the partials were MULTIPLIED, not shifted — this is \
            behaving like a pitch shifter
            """)
        // The original harmonics are gone.
        #expect(Self.db(Self.goertzel(tail, hz: 100)) < -45)
    }

    /// The fold is real physics and it is documented as such, so it is pinned:
    /// shifting a 100 Hz tone down 300 Hz reflects it back up to 200 Hz.
    @Test("L4 — shifting DOWN past 0 Hz reflects, exactly as FreqShifterParams.shiftedHz says")
    func downwardShiftPastZeroReflects() throws {
        let f0 = 100.0
        let delta = -300.0
        let expected = FreqShifterParams.shiftedHz(inputHz: f0, effectiveShiftHz: delta)
        #expect(expected == 200)
        let input = Self.sine(hz: f0, frames: Self.totalFrames)
        let tail = analyse(try shift(FreqShifterParams(shiftHz: delta, mix: 1), input))
        let folded = Self.db(Self.goertzel(tail, hz: expected))
        print("[measured] 100 Hz shifted -300 Hz lands at \(expected) Hz: \(folded) dB")
        #expect(folded > -7.5, "the fold did not happen where the law says it does")
    }

    /// The coarse and fine knobs are ONE control, and the render path must use
    /// the sum — not `shiftHz` alone.
    @Test("L5 — fineHz reaches the oscillator: shiftHz 200 + fineHz 7 lands at f0+207")
    func fineShiftIsSummedIntoTheCarrier() throws {
        let f0 = 1_000.0
        let input = Self.sine(hz: f0, frames: Self.totalFrames)
        let tail = analyse(
            try shift(FreqShifterParams(shiftHz: 200, fineHz: 7, mix: 1), input))
        let atSum = Self.db(Self.goertzel(tail, hz: 1_207))
        let atCoarseOnly = Self.db(Self.goertzel(tail, hz: 1_200))
        print("[measured] coarse+fine: @1207 \(atSum) dB | @1200 (coarse only) \(atCoarseOnly) dB")
        #expect(atSum > -7.5, "fineHz never reached the oscillator")
        #expect(atSum - atCoarseOnly > 20,
                "energy sits at the COARSE frequency — fineHz is being dropped")
    }

    // MARK: - L6: rule 6.0.7, both halves

    /// ⛔ BIT PATTERNS, not a tolerance. At `mix == 0` the buffer is never
    /// written, so the output is the input's exact bits — including for −0.0,
    /// which a `dry + 0` formulation would silently turn into +0.0.
    @Test("L6 — mix == 0 is BIT-EXACT dry, including -0.0 and subnormals")
    func mixZeroIsBitExactDry() throws {
        var input = Self.sine(hz: 440, frames: 4_096, amplitude: 0.7)
        // The values a tolerance-based comparison cannot see.
        input[0] = -0.0
        input[1] = Float(bitPattern: 1)           // smallest subnormal
        input[2] = -Float(bitPattern: 3)
        input[3] = 0.0
        // Non-zero on EVERY other knob, so this proves `mix` alone is the gate.
        let rendered = try shift(
            FreqShifterParams(shiftHz: 733.5, fineHz: 12.5, stereoSpreadHz: -9,
                              mix: 0, outputDb: 18), input)
        #expect(rendered.count == input.count)
        for index in 0..<input.count {
            #expect(rendered[index].bitPattern == input[index].bitPattern,
                    "frame \(index) changed at mix == 0: \(input[index]) -> \(rendered[index])")
        }
        // ⭐ POSITIVE CONTROL: the same probe must SEE a change when mix is
        // non-zero, or "identical bits" is evidence of nothing.
        let wet = try shift(
            FreqShifterParams(shiftHz: 733.5, fineHz: 12.5, mix: 1), input)
        let changed = (0..<input.count).contains { wet[$0].bitPattern != input[$0].bitPattern }
        #expect(changed, "the bit comparison cannot see a change — L6 is vacuous")
    }

    /// The OTHER half of rule 6.0.7, which has no other instrument: the
    /// oscillators must keep running at `mix == 0` so raising `mix` later is
    /// phase-coherent rather than a jump.
    @Test("L6b — at mix == 0 the carriers STILL ADVANCE, so un-muting is phase-coherent")
    func carriersAdvanceAtMixZero() throws {
        let effect = FreqShifterEffect(
            params: FreqShifterParams(shiftHz: 500, stereoSpreadHz: 6, mix: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        #expect(effect.carrierPhases.left == 0)
        let input = Self.sine(hz: 440, frames: 4_096)
        _ = try processChunked(effect, channels: [input, input])
        let phases = effect.carrierPhases
        print("[measured] carrier phases after 4096 frames at mix 0: \(phases)")
        #expect(phases.left != 0, "the carrier froze at mix == 0 — un-muting would jump")
        // The spread makes the two sides genuinely diverge.
        #expect(phases.left != phases.right,
                "stereoSpreadHz did not separate the two carriers")
        // …and the all-pass network ran too, not just the oscillator.
        #expect(effect.nonZeroStateWords > 0,
                "the Hilbert network is idle at mix == 0 — raising mix would start from silence")
    }

    // MARK: - L7: stereo

    @Test("L7 — stereoSpreadHz makes the two channels genuinely different, and 0 keeps them identical")
    func stereoSpreadSeparatesTheChannels() throws {
        let input = Self.sine(hz: 1_000, frames: Self.totalFrames)

        let noSpread = FreqShifterEffect(params: FreqShifterParams(shiftHz: 200, mix: 1))
        noSpread.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let flat = try processChunked(noSpread, channels: [input, input])
        // ⛔ At spread 0 the two sides must be BIT-IDENTICAL: same network, same
        // increment, same everything. Anything else is uninitialised state.
        #expect(flat[0].map(\.bitPattern) == flat[1].map(\.bitPattern),
                "the channels differ at stereoSpreadHz == 0 — mono compatibility is broken")

        let spread = FreqShifterEffect(
            params: FreqShifterParams(shiftHz: 200, stereoSpreadHz: 8, mix: 1))
        spread.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wide = try processChunked(spread, channels: [input, input])
        #expect(wide[0].map(\.bitPattern) != wide[1].map(\.bitPattern))
        // …and the difference is the DECLARED one: left +4 Hz, right −4 Hz.
        let left = analyse(wide[0])
        let right = analyse(wide[1])
        let leftAtPlus = Self.db(Self.goertzel(left, hz: 1_204))
        let rightAtMinus = Self.db(Self.goertzel(right, hz: 1_196))
        let leftAtMinus = Self.db(Self.goertzel(left, hz: 1_196))
        print("[measured] spread 8 Hz: L@1204 \(leftAtPlus) dB, R@1196 \(rightAtMinus) dB, "
              + "L@1196 \(leftAtMinus) dB")
        #expect(leftAtPlus > -7.5, "left did not take +spread/2")
        #expect(rightAtMinus > -7.5, "right did not take -spread/2")
        #expect(leftAtPlus - leftAtMinus > 20, "the two sides are not separated in frequency")
    }

    /// ⛔⛔ THE NOTE ON `stereoSpreadHz` SAYS "It does nothing on a mono track."
    /// THIS IS THE LEG THAT MAKES THAT SENTENCE TRUE RATHER THAN A CLAIM.
    ///
    /// The spread is defined as a LEFT/RIGHT difference — left takes
    /// `+spread/2`, right `−spread/2`. On a mono track there is no right
    /// channel, so applying half of it to the only channel would detune the
    /// whole track by an amount the user asked to apply to the STEREO IMAGE,
    /// and `effectiveShiftHz` (which reports `shiftHz + fineHz`, with no
    /// spread) would under-report the real shift by that much. ⚠️ L7 exercises
    /// only the stereo path and cannot see this.
    @Test("L7b — stereoSpreadHz does NOTHING on a mono track, exactly as its note promises")
    func stereoSpreadIsIgnoredOnMono() throws {
        let f0 = 1_000.0
        let input = Self.sine(hz: f0, frames: Self.totalFrames)
        // Prepared for ONE channel — a mono strip.
        let effect = FreqShifterEffect(
            params: FreqShifterParams(shiftHz: 200, stereoSpreadHz: 8, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let tail = analyse(try processChunked(effect, channels: [input])[0])

        let atShift = Self.db(Self.goertzel(tail, hz: 1_200))
        let atShiftPlusHalfSpread = Self.db(Self.goertzel(tail, hz: 1_204))
        print("[measured] mono + spread 8: @1200 \(atShift) dB · @1204 \(atShiftPlusHalfSpread) dB")
        #expect(atShift > -7.5, "the mono render did not land at shiftHz")
        #expect(atShift - atShiftPlusHalfSpread > 20, """
            a mono track was shifted to 1204 Hz, i.e. half the stereo spread leaked into the \
            only channel. `stereoSpreadHz`'s note promises it does nothing on a mono track, \
            and `effectiveShiftHz` would under-report the real shift by spread/2.
            """)
        // ⭐ POSITIVE CONTROL: the same probe on the STEREO path must FIND the
        // 1204 Hz component, or "1204 is empty" is evidence of nothing.
        let stereoEffect = FreqShifterEffect(
            params: FreqShifterParams(shiftHz: 200, stereoSpreadHz: 8, mix: 1))
        stereoEffect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                             channelCount: 2)
        let left = analyse(try processChunked(stereoEffect, channels: [input, input])[0])
        let stereoAt1204 = Self.db(Self.goertzel(left, hz: 1_204))
        print("[measured] STEREO control: left @1204 \(stereoAt1204) dB")
        #expect(stereoAt1204 > -7.5,
                "the probe cannot see a 1204 Hz component even on the stereo path")
    }

    // MARK: - L8: latency

    /// Keeps the m25-n insert-PDC guarantee honest. ⛔ THE CHAIN HALF LIVES IN
    /// `EffectChainRenderTests` (m39-z L8b), because `EffectChainState` is
    /// `@MainActor` and `MainActorOccupancySiteTests` Leg C pins the main-actor
    /// SUITE count at its cap with ZERO SLACK — the m39-y precedent exactly.
    @Test("L8 — latencySamples is 0 at every prepared rate and every setting")
    func latencyIsZero() {
        let effect = FreqShifterEffect(params: FreqShifterParams(
            shiftHz: 2_000, fineHz: 20, stereoSpreadHz: -20, mix: 1, outputDb: 24))
        #expect(effect.latencySamples == 0)
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            effect.prepare(sampleRate: rate, maxFramesPerQuantum: 512, channelCount: 2)
            #expect(effect.latencySamples == 0, "non-zero latency at \(rate) Hz")
        }
    }

    // MARK: - L9: robustness

    /// A NaN reaching the phase accumulator is unrecoverable, so the derive
    /// re-guards every field even though `init` already clamped.
    @Test("L9 — a NaN poked straight into an automation slot never reaches the output")
    func nanAutomationCannotPoisonTheRender() throws {
        let effect = FreqShifterEffect(params: FreqShifterParams(shiftHz: 300, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let input = Self.sine(hz: 440, frames: 8_192)
        let rendered = try processChunked(effect, channels: [input]) { fx, quantum in
            if quantum == 2 {
                // Every slot, every poison, including out-of-range slots.
                for slot in -1...5 {
                    fx.storeAutomatedParam(slot: slot, value: .nan)
                    fx.storeAutomatedParam(slot: slot, value: .infinity)
                    fx.storeAutomatedParam(slot: slot, value: -.infinity)
                }
            }
        }[0]
        #expect(rendered.allSatisfy { $0.isFinite }, """
            a NaN or infinity reached the output — the strip would be silent forever
            """)
        // And it still renders SOMETHING: a guard that silenced the strip would
        // also satisfy `isFinite`.
        #expect(rendered.contains { abs($0) > 0.01 },
                "the render went silent — the guard is a mute, not a guard")
    }

    /// Denormal flush: after a loud burst followed by silence, EVERY section's
    /// state must reach EXACTLY zero rather than decaying forever.
    ///
    /// ⭐⭐ THE SILENCE LENGTH IS DERIVED, NOT GUESSED, AND THE FIRST DRAFT GOT IT
    /// WRONG IN A WAY WORTH RECORDING. With no input each section decays as
    /// `y[n] = a·y[n−2]`, so reaching the `1e-20` flush floor takes
    /// `log(1e-20)/log(a)` TWO-SAMPLE steps. For the slowest shipped
    /// coefficient (I's `0.999009677…`) that is 46 479 steps = **92 957 samples
    /// = 1.937 s**. A one-second silence left EXACTLY TWO words non-zero — that
    /// section's `y[n−1]` and `y[n−2]` — which is what the failing first draft
    /// measured, and the agreement between the prediction and the measured 2 is
    /// what identified it as a wrong TEST rather than a missing flush.
    ///
    /// ⚠️ Note what the flush is and is not for: `1e-20` is nowhere near
    /// `Double`'s subnormal range (~2.2e-308), so this is a pragmatic early cut
    /// that stops the network doing arithmetic on inaudible tails — `DelayEffect`'s
    /// constant, applied per section because ten independent IIRs decay
    /// separately and one flush at the end would leave nine of them running.
    @Test("L9b — every section flushes to exactly zero on silence")
    func denormalsAreFlushed() throws {
        let effect = FreqShifterEffect(params: FreqShifterParams(shiftHz: 400, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let burst = Self.sine(hz: 1_000, frames: 4_096, amplitude: 1.0)
        _ = try processChunked(effect, channels: [burst])
        #expect(effect.nonZeroStateWords > 0, "the burst left no state — the probe is vacuous")
        // 3 s — comfortably past the derived 1.937 s worst case above.
        _ = try processChunked(effect, channels: [[Float](repeating: 0, count: 144_000)])
        #expect(effect.nonZeroStateWords == 0, """
            \(effect.nonZeroStateWords) state words are still non-zero after a second of \
            silence — the per-section denormal flush is not reaching every section
            """)
    }

    @Test("L9c — reset() clears the network and the carriers")
    func resetClearsEverything() throws {
        let effect = FreqShifterEffect(params: FreqShifterParams(shiftHz: 400, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let burst = Self.sine(hz: 1_000, frames: 4_096, amplitude: 1.0)
        _ = try processChunked(effect, channels: [burst, burst])
        #expect(effect.nonZeroStateWords > 0)
        #expect(effect.carrierPhases.left != 0)
        effect.reset()
        #expect(effect.nonZeroStateWords == 0)
        #expect(effect.carrierPhases.left == 0)
        #expect(effect.carrierPhases.right == 0)
    }

    // MARK: - L10: smoothing is not deletable

    /// ⛔ THIS LEG EXISTS BECAUSE MANDATORY SMOOTHING HAS BEEN FOUND DELETABLE
    /// WITH A FULLY GREEN SUITE IN THIS TREE BEFORE.
    ///
    /// ⚠️⚠️ **AND ITS FIRST DRAFT MEASURED THE WRONG QUANTITY — RECORDED BECAUSE
    /// THE MISTAKE IS THE INSTRUCTIVE PART.** That draft looked for a large
    /// SINGLE-SAMPLE JUMP in the output while sweeping `shiftHz`, by analogy
    /// with a gain step. It cannot work: the oscillator accumulates PHASE, so
    /// stepping its FREQUENCY per quantum leaves the carrier perfectly
    /// continuous — there is no discontinuity to find. The plant
    /// (`incrementL = targetIncrementL`, i.e. the interpolation deleted
    /// outright) left that draft GREEN. A leg with no plant that reddens it is
    /// not a leg.
    ///
    /// ⭐ What a per-quantum step actually changes is HOW MUCH PHASE ACCUMULATES
    /// across the quantum, and that is exactly measurable. Sweeping the
    /// increment from `a` to `b` over `N` frames advances the phase by the
    /// TRAPEZOIDAL sum `N·(a+b)/2` when interpolated per sample, and by the
    /// ENDPOINT sum `N·b` when the increment is stepped. Those differ by
    /// `N·(b−a)/2`, which for a real sweep is many cycles. `carrierPhases` is
    /// the instrument.
    @Test("L10 — the phase increment is interpolated per SAMPLE: accumulated phase is the trapezoidal sum, not the endpoint sum")
    func incrementIsInterpolatedPerSample() throws {
        let frames = 512
        let startHz = 0.0
        let endHz = 1_000.0
        let effect = FreqShifterEffect(params: FreqShifterParams(shiftHz: startHz, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: frames, channelCount: 1)
        // One quantum at the start value, so `previous` is primed AT `startHz`.
        let input = Self.sine(hz: 1_000, frames: frames, amplitude: 0.5)
        _ = try processChunked(effect, channels: [input], chunk: frames)
        let before = effect.carrierPhases.left

        // Now demand `endHz` for the NEXT quantum. The increment must sweep
        // across it, not jump to it.
        _ = try processChunked(effect, channels: [input], chunk: frames) { fx, _ in
            fx.storeAutomatedParam(slot: 0, value: endHz)
        }
        let after = effect.carrierPhases.left

        // Phase is kept in CYCLES and wraps at 1, so compare the wrapped values.
        //
        // ⚠️ THE EXACT LAW IS THE LEFT-ENDPOINT SUM, NOT THE TRAPEZOID, and the
        // half-step difference is a real property of the implementation rather
        // than rounding: the loop USES `increment` and only then adds `delta`,
        // so the values applied are `a + k·delta` for k = 0…N−1 and the total is
        // `N·a + (b−a)·(N−1)/2`. The trapezoid `N·(a+b)/2` is larger by exactly
        // `(b−a)/2` — one half of one increment step. MEASURED: asserting the
        // trapezoid reddened this leg by 0.010416666 cycles = 1/96, which is
        // that half-step to the digit. Asserting a law you have not derived from
        // the code is how a correct implementation gets "fixed".
        let span = Double(frames)
        let a = startHz / Self.sampleRate
        let b = endHz / Self.sampleRate
        let leftEndpoint = span * a + (b - a) * (span - 1) / 2
        let stepped = span * b          // what deleting the interpolation gives
        func wrap(_ v: Double) -> Double { v - v.rounded(.down) }
        let advanced = wrap(after - before + 1)
        print("[measured] phase advanced \(advanced) cycles; the per-sample law predicts "
              + "\(wrap(leftEndpoint)); a per-quantum STEP would give \(wrap(stepped))")
        #expect(abs(advanced - wrap(leftEndpoint)) < 1e-9, """
            the carrier advanced \(advanced) cycles across the quantum; per-sample \
            interpolation requires \(wrap(leftEndpoint)). A per-quantum step gives \
            \(wrap(stepped)) — the interpolation has been deleted.
            """)
        // ⛔ NON-VACUITY: the two laws must actually DISAGREE here, or the
        // assertion above is satisfied by both and proves nothing.
        #expect(abs(wrap(leftEndpoint) - wrap(stepped)) > 0.01, """
            the interpolated and stepped predictions coincide — this fixture cannot \
            distinguish them, so pick a larger sweep
            """)

        // And the audio stays finite and non-silent through the sweep.
        let rendered = try shift(FreqShifterParams(shiftHz: 500, mix: 1),
                                 Self.sine(hz: 1_000, frames: 4_096))
        #expect(rendered.allSatisfy { $0.isFinite })
    }

    // MARK: - L11: the render path allocates NOTHING

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
        if tid == FreqShifterTests.watchedThread.pointee {
            FreqShifterTests.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global. Nil is a FAILURE for the caller,
    /// never a skip — a silently-absent probe is vacuity, not a pass.
    private static func mallocLoggerSlot() -> UnsafeMutablePointer<MallocLoggerFn?>? {
        guard let raw = dlsym(UnsafeMutableRawPointer(bitPattern: -2),
                              "malloc_logger") else { return nil }
        return raw.assumingMemoryBound(to: MallocLoggerFn?.self)
    }

    /// ⛔⛔ SIBLING-IDENTICAL TO `PhaserTests`/`RingModTests`/`TransientShaperTests`
    /// ON PURPOSE, AND THE ONE DEVIATION IS `warmup`.
    ///
    /// ⚠️ MEASURED, AND THE LESSON IS ABOUT DEVIATING: an earlier draft ran the
    /// measured body on a THREAD THIS FUNCTION CREATED, reasoning that a
    /// process-global `malloc_logger` shared with four other suites could have
    /// its attribution disturbed under parallel execution. That reasoning was
    /// wrong in a checkable way — in the very same full run, all four sibling
    /// probes read **0** while this one read 3 835 259 and then 239. The
    /// difference was never the scheduler: it was two local deviations from the
    /// sibling shape (a Swift `Array` source instead of a raw pointer, and the
    /// extra thread). **When four neighbouring instruments agree and yours does
    /// not, suspect your instrument.**
    ///
    /// `warmup` runs with the hook live and the counter is zeroed after it.
    /// ⚠️ THAT ORDER IS LOAD-BEARING: Swift's `static let` arrays
    /// (`FreqShifterParams.hilbertI`/`hilbertQ`) allocate on FIRST TOUCH
    /// anywhere in the process, so whichever test reaches them first pays a real
    /// `malloc` inside `swift_once`. MEASURED: without the warm-up this leg
    /// reported an order-dependent 0, 2, 5 and 6 events on identical code.
    /// A probe that reports a SMALL non-zero is the dangerous kind — it reads as
    /// "the render path allocates a little", a sentence that should never be
    /// true and that would be debugged as a real defect.
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

    @Test("L11 — process() allocates NOTHING across 4 000 quanta, and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("""
                malloc_logger is unavailable — the allocation probe cannot run. \
                FAILURE, not a skip.
                """)
            return
        }
        let quantum = 512
        let calls = 4_000
        // Everything switched ON: stereo (both networks and both oscillators
        // live), a spread so the two increments differ, a non-unity trim, and a
        // mid-range mix so the write path runs too.
        let effect = FreqShifterEffect(
            params: FreqShifterParams(shiftHz: 733.5, fineHz: 12.5, stereoSpreadHz: -9,
                                      mix: 0.6, outputDb: -3))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                       channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let data = try #require(buffer.floatChannelData)
        // ⚠️ A RAW POINTER, NOT A SWIFT `Array` — the `PhaserTests` shape, and
        // the second of the two deviations that made this probe disagree with
        // its four siblings. An `Array` read inside the measured window carries
        // the language's own bookkeeping into the measurement.
        let staged = Self.sine(hz: 220, frames: quantum, amplitude: 0.6)
        let source = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
        defer { source.deallocate() }
        for frame in 0..<quantum { source[frame] = staged[frame] }

        // ⛔⛔ THE WARM-UP IS NOT OPTIONAL, AND IT RUNS ON THE MEASURED THREAD.
        // ⚠️ A flake that reports a SMALL non-zero is the dangerous kind: it
        // reads as "the render path allocates a little", a sentence that should
        // never be true and that would be debugged as a real defect. See
        // `mallocEvents` for the two measured causes.
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
                // ⚠️ RE-STAGE THE INPUT EVERY CALL. `PhaserTests` records a run
                // where the render drifted to NaN while the allocation count
                // stayed a clean 0 — a probe measuring NaN is measuring
                // nothing.
                var channel = 0
                while channel < 2 {
                    var frame = 0
                    while frame < quantum {
                        data[channel][frame] = source[frame]
                        frame += 1
                    }
                    channel += 1
                }
                // An automation poke every few quanta, so the derive path is
                // inside the measured region too.
                if call % 7 == 0 {
                    effect.storeAutomatedParam(slot: 0, value: Double(call % 1_000) - 500)
                }
                effect.process(buffers: list, frameCount: quantum)
                sum += data[0][quantum - 1]
                call += 1
            }
        }
        print("[measured] malloc events across \(calls) quanta: \(events)")
        #expect(events == 0, "the render path allocated \(events) times")
        // The render actually produced finite audio — see the NaN note above.
        #expect(sum.isFinite)
        #expect(sum != 0, "the measured region rendered silence")
    }

    @Test("L11b — POSITIVE CONTROL: the malloc probe can actually count")
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
}
