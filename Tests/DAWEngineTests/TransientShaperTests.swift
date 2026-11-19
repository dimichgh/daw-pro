import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `PhaserTests`, `FlangerTests`, `RingModTests` and `BitCrusherTests` all
// record: the main actor is ONE serialization point for the whole test process,
// these tests render hundreds of thousands of frames, and they need no
// main-actor state. There is also a hard structural reason today —
// `MainActorOccupancySiteTests` Leg C pins the `@MainActor`-isolated SUITE count
// at its cap with ZERO SLACK. The one main-actor thing an effect owns is
// `apply(params:)`; these tests construct effects with their params and use the
// nonisolated render-thread `storeAutomatedParam` where a value must move
// mid-render. (L9's chain half lives in the already-`@MainActor`
// `EffectChainRenderTests` for the same reason.)
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-y — the `.transientShaper` insert. `TransientShaperParams` holds the
/// laws; this suite proves the RENDERED AUDIO obeys them.
///
/// ⭐⭐ **THE CENTRAL LEGS ARE L5 AND L6, AND THEY ARE WHAT A TRANSIENT SHAPER
/// *IS*.** Any gain-modulating effect can show "the output changed". Only two
/// claims separate this kind from a compressor with a fast attack:
///   · **L5 — INDEPENDENCE.** `attackDb` moves the front of a sound and leaves
///     the tail alone; `sustainDb` moves the tail and leaves the front alone.
///   · **L6 — LEVEL INDEPENDENCE.** The same hit 20 dB quieter gets the SAME
///     shaping, because the detector compares the signal to ITSELF.
/// An implementation that got either wrong would pass every other leg here.
///
/// ⛔ **EVERY PLANT IN THIS FILE WAS RUN, AND ITS REDNESS RECORDED IN THE CLOSE.**
/// A plant that has never been run is indistinguishable from one that cannot
/// fire — and this design's own first draft carried two plants that were
/// multiplied by zero under their leg's own settings and could never have gone
/// red while reading as rigorous.
///
/// ⚠️⚠️ **THE FIXTURE'S DECAY IS τ = 40 ms AND THE REPEAT IS 400 ms — NOT the
/// design doc's 5 ms / 250 ms, and the change is MEASURED rather than taste.**
/// With a 5 ms tail a −12 dBFS burst crosses the −70 dBFS `detectorFloorDb`
/// about 33 ms after the burst ends, i.e. ~53 ms after onset — so the
/// independence window `[50 ms, 200 ms]` would sit almost entirely inside
/// HARD-GATED SILENCE, where the effect is designed to do nothing and both
/// renders are trivially identical. That leg would have passed vacuously, in
/// exactly the shape this tree keeps producing. At τ = 40 ms the signal is
/// −51 dBFS at the far end of the window, comfortably above the floor, and the
/// leg measures the effect instead of the gate. ⛔ Do not "correct" the fixture
/// back to the design's numbers and then report a pass.
@Suite("Transient shaper — independent, level-independent, zero-latency (m39-y)",
       .serialized)
struct TransientShaperTests {
    private static let sampleRate = 48_000.0

    // MARK: - Fixtures

    /// ⛔ **THE FIXTURE IS NOT A DIRAC CLICK, AND THE REASON IS STRUCTURAL.**
    /// Zero lookahead means the gain rises AFTER the leading edge. A one-sample
    /// click is over before any boost lands, so a click-train measurement would
    /// read ≈ 0 dB at `attackDb +6` and an implementer would conclude the effect
    /// is inert when it is working correctly.
    ///
    /// 1 kHz sine, `onMs` at full amplitude, then an exponential amplitude decay
    /// with time constant `decayTauMs`, repeated every `periodMs`.
    private func burstEnvelope(peak: Double, onMs: Double = 20, decayTauMs: Double = 40,
                               periodMs: Double = 400, bursts: Int = 4) -> [Double] {
        let period = Int(periodMs * 0.001 * Self.sampleRate)
        var env = [Double](repeating: 0, count: period * bursts)
        let onFrames = Int(onMs * 0.001 * Self.sampleRate)
        let tau = decayTauMs * 0.001 * Self.sampleRate
        for burst in 0..<bursts {
            let base = burst * period
            for frame in 0..<period {
                env[base + frame] = frame < onFrames
                    ? peak
                    : peak * exp(-Double(frame - onFrames) / tau)
            }
        }
        return env
    }

    private func burstOnsets(periodMs: Double = 400, bursts: Int = 4) -> [Int] {
        let period = Int(periodMs * 0.001 * Self.sampleRate)
        return (0..<bursts).map { $0 * period }
    }

    /// The AUDIBLE fixture: a 1 kHz sine under the burst envelope. Used for the
    /// peak-window measurements, where the sine's own crest is where the peak
    /// lands.
    private func sineBursts(peakDb: Double) -> [Float] {
        let env = burstEnvelope(peak: pow(10, peakDb / 20))
        return env.enumerated().map { index, amplitude in
            Float(amplitude * sin(2.0 * .pi * 1_000 * Double(index) / Self.sampleRate))
        }
    }

    /// ⭐ **THE GAIN PROBE, AND IT IS AN INSTRUMENT RATHER THAN A SHORTCUT.**
    /// The same burst envelope on an ALTERNATING ±1 carrier (a full-scale
    /// Nyquist tone). Two properties follow, and both matter:
    ///   1. `|x[n]|` IS the envelope exactly, with no rectifier ripple — so the
    ///      detector sees a clean envelope and the measurement is of the
    ///      detector rather than of a sine's zero crossings.
    ///   2. `x[n]` is NEVER ZERO, so `out[n] / in[n]` is the applied gain at
    ///      EVERY sample. That is a measurement of the RENDERED AUDIO, not a
    ///      parameter read back — which is the only kind of evidence this tree
    ///      accepts about what an effect did.
    private func probeBursts(peakDb: Double) -> (signal: [Float], envelope: [Double]) {
        let env = burstEnvelope(peak: pow(10, peakDb / 20))
        let signal = env.enumerated().map { index, amplitude in
            Float(amplitude * (index % 2 == 0 ? 1.0 : -1.0))
        }
        return (signal, env)
    }

    /// A steady, settled, constant-amplitude probe — no transient at all, so the
    /// shaping terms are inert and only the static path is left. This is what
    /// makes L8 measure SMOOTHING rather than the detector.
    private func steadyProbe(peakDb: Double, frames: Int) -> [Float] {
        let amplitude = Float(pow(10, peakDb / 20))
        return (0..<frames).map { $0 % 2 == 0 ? amplitude : -amplitude }
    }

    // MARK: - Render helpers

    private func processChunked(_ effect: TransientShaperEffect, channels: [[Float]],
                                chunk: Int,
                                poke: ((TransientShaperEffect, Int) -> Void)? = nil)
        throws -> [[Float]] {
        let total = channels[0].count
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(channels.count)))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
        var output = [[Float]](repeating: [], count: channels.count)
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

    /// One STEREO pass (identical L/R, so the stereo link is unambiguous)
    /// through a freshly prepared shaper. Returns the left channel.
    private func shape(_ params: TransientShaperParams, _ input: [Float],
                       chunk: Int = 512) throws -> [Float] {
        let effect = TransientShaperEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: chunk,
                       channelCount: 2)
        return try processChunked(effect, channels: [input, input], chunk: chunk)[0]
    }

    private func dB(_ ratio: Double) -> Double { 20 * log10(max(ratio, 1e-30)) }

    private func peak(_ samples: [Float], _ range: Range<Int>) -> Double {
        var maximum = 0.0
        for index in range where index >= 0 && index < samples.count {
            maximum = max(maximum, Double(abs(samples[index])))
        }
        return maximum
    }

    private func frames(_ ms: Double) -> Int { Int(ms * 0.001 * Self.sampleRate) }

    /// Mean of the per-burst peak ratio, in dB, of `shaped` against `reference`
    /// over a window `[startMs, endMs]` measured from each burst's onset.
    private func windowGainDb(shaped: [Float], reference: [Float],
                              startMs: Double, endMs: Double) -> [Double] {
        burstOnsets().map { onset in
            let range = (onset + frames(startMs))..<(onset + frames(endMs))
            return dB(peak(shaped, range)) - dB(peak(reference, range))
        }
    }

    // MARK: - L3: the detector's step response

    /// ⛔ PLANT: point `envAttack`'s coefficient at `aFastAtk` (making it a near
    /// copy of `envFast`) → `dA` collapses to ~1.5 dB at 3·fastAttackMs and the
    /// first assertion reddens.
    @Test("L3 — the detector's step response: dA fires on a rise and RETURNS TO ZERO; dS is silent on the rise and fires on the fall")
    func detectorStepResponse() throws {
        let attackMs = 30.0
        let params = TransientShaperParams(attackMs: attackMs, sustainMs: 200)
        let effect = TransientShaperEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 1, channelCount: 1)

        let stepFrames = frames(400)
        let tailFrames = frames(400)
        let amplitude: Float = 0.25  // −12 dBFS, well above the −70 dB floor

        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        let data = try #require(buffer.floatChannelData)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        func step(_ value: Float) -> (dA: Double, dS: Double) {
            data[0][0] = value
            effect.process(buffers: list, frameCount: 1)
            let env = effect.detectorEnvelopes
            let floorLin = TransientShaperParams.detectorFloorLinear
            guard env.fast >= floorLin else { return (0, 0) }
            let a = max(env.attack, floorLin)
            let s = max(env.sustain, floorLin)
            return (max(0, 20 * log10(env.fast / a)), max(0, 20 * log10(s / env.fast)))
        }

        // (a) On the RISE: dA saturates almost at once, dS stays silent.
        var dAAtThreeFastTaus = 0.0
        var maxDSDuringStep = 0.0
        var dAAtFourAttacks = 0.0
        let threeFastTaus = max(1, frames(TransientShaperParams.fastAttackMs * 3))
        let fourAttacks = frames(attackMs * 4)
        for frame in 0..<stepFrames {
            let (dA, dS) = step(amplitude)
            if frame == threeFastTaus { dAAtThreeFastTaus = dA }
            if frame == fourAttacks { dAAtFourAttacks = dA }
            if frame < fourAttacks { maxDSDuringStep = max(maxDSDuringStep, dS) }
        }
        print("[measured] m39-y L3 rise: dA at 3·fastAttackMs = "
              + "\(dAAtThreeFastTaus) dB; dA at 4·attackMs = \(dAAtFourAttacks) dB; "
              + "max dS during the step = \(maxDSDuringStep) dB")
        #expect(dAAtThreeFastTaus > TransientShaperParams.fullShapeDifferentialDb,
                "dA must saturate within three fast-attack time constants")
        // ⭐ THE RETURN TO ZERO IS THE HALF THAT MAKES INDEPENDENCE POSSIBLE. A
        // detector that fires on a rise is easy; one that STOPS is the design.
        #expect(dAAtFourAttacks < 0.5,
                "dA must fall below 0.5 dB within 4·attackMs of a step onset")
        #expect(maxDSDuringStep < 0.5,
                "dS must stay silent while the signal is rising or steady")

        // (b) On the FALL: dS fires. ⚠️⚠️ THE STEP FALLS TO −32 dBFS, NOT TO
        // SILENCE, AND THAT IS MEASURED RATHER THAN TIDY. Dropping to 0 puts
        // `envFast` under `detectorFloorDb` about 33 ms later, after which the
        // HARD GATE forces both differentials to 0 — correctly. The first
        // version of this leg did exactly that and read `dS = 0` at 200 ms,
        // which looks like a broken detector and is actually the noise gate
        // doing its job. Falling to a level well ABOVE the floor measures the
        // detector; the gate gets its own leg below.
        var dSAtHalfSustain = 0.0
        var dSAtSustain = 0.0
        var maxDAInTail = 0.0
        let halfSustainFrames = frames(100)
        let sustainFrames = frames(200)
        for frame in 0..<tailFrames {
            let (dA, dS) = step(amplitude * 0.1)  // −20 dB, i.e. −32 dBFS
            if frame == halfSustainFrames { dSAtHalfSustain = dS }
            if frame == sustainFrames { dSAtSustain = dS }
            maxDAInTail = max(maxDAInTail, dA)
        }
        print("[measured] m39-y L3 fall: dS at 0.5·sustainMs = \(dSAtHalfSustain) dB, "
              + "at sustainMs = \(dSAtSustain) dB; max dA through the whole tail = "
              + "\(maxDAInTail) dB")
        #expect(dSAtHalfSustain > TransientShaperParams.fullShapeDifferentialDb,
                "dS must saturate well within one sustainMs of the step's end")
        #expect(maxDAInTail < 0.5, "dA must stay at zero through a decay")
    }

    /// ⛔ §3.4's HARD GATE, which is not merely a ratio clamp. Without it the
    /// ratio of two near-zero envelopes is noise and the unit would apply up to
    /// ±20 dB of shaping to room tone. This is the leg that proves it, and it
    /// exists separately because L3's first draft measured the gate by accident
    /// and read it as a dead detector.
    @Test("The −70 dBFS detector floor is a HARD GATE: nothing below it is shaped, and something above it is")
    func detectorFloorHardGatesTheShaping() throws {
        let params = TransientShaperParams(attackDb: 20, sustainDb: 20,
                                           attackMs: 5, sustainMs: 200)
        // A burst 6 dB ABOVE the floor: shaped. A burst 6 dB BELOW it: not.
        for (peakDb, shouldShape) in [(-64.0, true), (-76.0, false)] {
            let input = sineBursts(peakDb: peakDb)
            let out = try shape(params, input)
            var worstDb = 0.0
            for index in 0..<input.count where input[index] != 0 {
                let g = dB(Double(out[index]) / Double(input[index]))
                if abs(g) > abs(worstDb) { worstDb = g }
            }
            print("[measured] m39-y floor gate at \(peakDb) dBFS "
                  + "(floor \(TransientShaperParams.detectorFloorDb)): largest gain "
                  + "applied \(worstDb) dB")
            if shouldShape {
                #expect(worstDb > 6.0,
                        "a burst ABOVE the floor was not shaped — the gate is too high")
            } else {
                #expect(abs(worstDb) < 1e-6,
                        "a burst BELOW the floor was shaped by \(worstDb) dB — room tone gets treated")
            }
        }
    }

    // MARK: - L4: bit-exact dry at the defaults

    /// ⚠️⚠️ **"BIT-EXACT" IS COMPARED BITWISE, AND THE FIXTURE CARRIES −0.0.**
    /// `#expect(out == input)` on an `[Float]` is NOT a bit comparison: IEEE
    /// says `−0.0 == +0.0`, so an implementation that replaced every sample with
    /// `+0.0 + x·g` would pass it. The fixture therefore carries signed zeros,
    /// subnormals and full-scale values, and the comparison is on `bitPattern`.
    @Test("L4 — at the DEFAULTS the render is BIT-IDENTICAL to its input, sample for sample, by IEEE and not by tolerance")
    func defaultsAreBitExactDry() throws {
        var input: [Float] = [0, -0.0, 1, -1, .leastNonzeroMagnitude,
                              -.leastNonzeroMagnitude, 1e-30, -1e-30]
        // DETERMINISTIC pseudo-random rather than `SystemRandomNumberGenerator`:
        // a bit-identity failure has to be reproducible from the test alone.
        var state: UInt64 = 0x2545_F491_4F6C_DD1D
        while input.count < 4_000 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let unit = Double(state >> 11) / Double(1 << 53)
            input.append(Float(unit * 2 - 1))
        }
        let out = try shape(TransientShaperParams(), input)
        #expect(out.count == input.count)
        var mismatches = 0
        var firstMismatch = -1
        for index in 0..<min(out.count, input.count)
        where out[index].bitPattern != input[index].bitPattern {
            if firstMismatch < 0 { firstMismatch = index }
            mismatches += 1
        }
        print("[measured] m39-y L4 bit-identity over \(input.count) frames: "
              + "\(mismatches) mismatching bit patterns (first at \(firstMismatch))")
        #expect(mismatches == 0,
                "\(mismatches) samples differ; first at index \(firstMismatch)")
        // NON-VACUITY: the fixture actually carries the values that can expose a
        // non-identity blend.
        #expect(input.contains { $0.bitPattern == Float(-0.0).bitPattern })
        #expect(input.contains { $0 != 0 && !$0.isNormal })
    }

    /// ⭐ THE FOLD'S OTHER HALF. `mixWet·g + mixDry` collapses to `g` at
    /// `mix == 1`, which is what L4 proves. This proves the fold is NOT just
    /// `g`: at `mix == 0` the gain is EXACTLY 1 even at `attackDb +20`, and at
    /// `mix == 0.5` the result sits strictly between dry and fully wet.
    /// ⚠️ THE LOOP IS NEVER SKIPPED AT `mix == 0`: the detector must keep
    /// running, or an automated `mix` 0→1 would snap from stale envelopes. The
    /// envelope read below is what proves it did.
    @Test("L4b — the dry/wet fold: mix 0 is bit-exact dry WITH THE DETECTOR STILL RUNNING, and mix 0.5 is strictly between")
    func mixFoldIsAnIdentityAtZeroAndBlendsBetween() throws {
        let input = sineBursts(peakDb: -12)
        let onset = burstOnsets()[1]
        let window = (onset)..<(onset + frames(8.678))

        let dry = try shape(TransientShaperParams(attackMs: 30), input)
        let wet = try shape(
            TransientShaperParams(attackDb: 20, attackMs: 30, mix: 1), input)
        let half = try shape(
            TransientShaperParams(attackDb: 20, attackMs: 30, mix: 0.5), input)

        // mix 0 — bit-exact, and the detector kept running.
        let effect = TransientShaperEffect(
            params: TransientShaperParams(attackDb: 20, attackMs: 30, mix: 0))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let silent = try processChunked(effect, channels: [input, input], chunk: 512)[0]
        var mismatches = 0
        for index in 0..<input.count where silent[index].bitPattern != input[index].bitPattern {
            mismatches += 1
        }
        let envelopes = effect.detectorEnvelopes
        print("[measured] m39-y L4b mix 0: \(mismatches) bit mismatches; "
              + "detector envelopes after the render fast=\(envelopes.fast) "
              + "attack=\(envelopes.attack) sustain=\(envelopes.sustain)")
        #expect(mismatches == 0, "mix 0 must be bit-exact dry")
        #expect(envelopes.sustain > 0,
                "the detector was SKIPPED at mix 0 — an automated mix 0→1 would snap from stale envelopes")

        let dryPeak = peak(dry, window)
        let wetPeak = peak(wet, window)
        let halfPeak = peak(half, window)
        print("[measured] m39-y L4b fold: dry \(dB(dryPeak)) dB, "
              + "mix 0.5 \(dB(halfPeak)) dB, mix 1 \(dB(wetPeak)) dB")
        #expect(wetPeak > halfPeak + 1e-6)
        #expect(halfPeak > dryPeak + 1e-6)
    }

    // MARK: - L5: independence — which IS the effect's definition

    /// ⛔⛔ **THE ACCEPTANCE NUMBERS.** A1/A2 are what makes `attackDb` a
    /// falsifiable promise rather than a dimensionless knob.
    @Test("L5a — attackDb lands its FULL amount inside attackWindowMs and leaves the tail alone (the A1/A2/A3 acceptance numbers)")
    func attackLandsInItsWindowAndNowhereElse() throws {
        let input = sineBursts(peakDb: -12)
        let attackMs = 30.0
        let windowMs = TransientShaperParams.attackWindowMs(attackMs: attackMs)
        #expect(abs(windowMs - 8.678) < 1e-3)

        let reference = try shape(TransientShaperParams(attackMs: attackMs), input)
        let boosted = try shape(
            TransientShaperParams(attackDb: 6, attackMs: attackMs), input)
        let cut = try shape(
            TransientShaperParams(attackDb: -6, attackMs: attackMs), input)
        let nine = try shape(
            TransientShaperParams(attackDb: 9, attackMs: attackMs), input)

        // A1 — the boost lands, +6.00 dB ± 0.5.
        let a1 = windowGainDb(shaped: boosted, reference: reference,
                              startMs: 0, endMs: windowMs)
        print("[measured] m39-y A1 attack boost per burst: \(a1) dB (expected +6.00)")
        for value in a1 { #expect(abs(value - 6.0) < 0.5, "A1 read \(value) dB") }

        // A2 — the cut lands, −6.00 dB ± 0.5.
        let a2 = windowGainDb(shaped: cut, reference: reference,
                              startMs: 0, endMs: windowMs)
        print("[measured] m39-y A2 attack cut per burst: \(a2) dB (expected −6.00)")
        for value in a2 { #expect(abs(value + 6.0) < 0.5, "A2 read \(value) dB") }

        // A3 — INDEPENDENCE. At +9 dB of punch the window [50, 200] ms after
        // each onset is untouched. ⛔ The window start is not arbitrary: `dA`
        // returns to 0 only once `envAttack` has crossed ABOVE `envFast`, so the
        // crossing is measured below and asserted to happen FIRST.
        let a3 = windowGainDb(shaped: nine, reference: reference,
                              startMs: 50, endMs: 200)
        print("[measured] m39-y A3 independence per burst: \(a3) dB (expected 0.00)")
        for value in a3 { #expect(abs(value) < 0.5, "A3 read \(value) dB") }

        // NON-VACUITY: the same comparison in the ATTACK window is nowhere near
        // 0, so A3's zero is a result and not an artefact of a dead measurement.
        let sanity = windowGainDb(shaped: nine, reference: reference,
                                  startMs: 0, endMs: windowMs)
        print("[measured] m39-y A3 non-vacuity — same pair inside the attack "
              + "window: \(sanity) dB")
        for value in sanity { #expect(value > 8.0, "the +9 dB boost did not land") }
    }

    /// ⭐ THE CROSSING, MEASURED. §3.3's precise claim is that `dA` is 0 once
    /// `envAttack` has crossed ABOVE `envFast` — NOT "throughout any decay",
    /// which is the over-general version and is false for a slow onset. This
    /// leg measures WHEN the crossing happens for this fixture and asserts it
    /// is before A3's window opens, so A3 does not silently depend on the
    /// special case it happens to be measuring.
    @Test("L5a-crossing — envAttack crosses above envFast well before the independence window opens")
    func attackReferenceCrossesBeforeTheIndependenceWindow() throws {
        let attackMs = 30.0
        let effect = TransientShaperEffect(
            params: TransientShaperParams(attackMs: attackMs, sustainMs: 200))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 1, channelCount: 1)
        let input = sineBursts(peakDb: -12)

        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        buffer.frameLength = 1
        let data = try #require(buffer.floatChannelData)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var crossingFrame = -1
        let limit = burstOnsets()[1]
        for frame in 0..<limit {
            data[0][0] = input[frame]
            effect.process(buffers: list, frameCount: 1)
            let env = effect.detectorEnvelopes
            if crossingFrame < 0, frame > frames(1), env.attack > env.fast {
                crossingFrame = frame
            }
        }
        let crossingMs = Double(crossingFrame) * 1_000 / Self.sampleRate
        print("[measured] m39-y envAttack crosses above envFast at frame "
              + "\(crossingFrame) = \(crossingMs) ms after onset "
              + "(A3's window opens at 50 ms)")
        #expect(crossingFrame > 0, "the crossing never happened")
        #expect(crossingMs < 50.0,
                "the crossing at \(crossingMs) ms is inside A3's window — A3 would be measuring the special case rather than the law")
    }

    /// The other half of independence, and it has its OWN plant because the two
    /// directions fail independently.
    @Test("L5b — sustainDb moves the TAIL and leaves the attack window alone, in both directions")
    func sustainMovesTheTailAndNotTheFront() throws {
        let input = sineBursts(peakDb: -12)
        let attackMs = 30.0
        let windowMs = TransientShaperParams.attackWindowMs(attackMs: attackMs)
        let reference = try shape(TransientShaperParams(attackMs: attackMs), input)
        let shorter = try shape(
            TransientShaperParams(sustainDb: -9, attackMs: attackMs, sustainMs: 200), input)
        let longer = try shape(
            TransientShaperParams(sustainDb: 9, attackMs: attackMs, sustainMs: 200), input)

        // INDEPENDENCE: the attack window is untouched at −9 dB of body.
        let front = windowGainDb(shaped: shorter, reference: reference,
                                 startMs: 0, endMs: windowMs)
        print("[measured] m39-y L5b attack window at sustainDb −9: \(front) dB "
              + "(expected 0.00)")
        for value in front { #expect(abs(value) < 0.5, "L5b front read \(value) dB") }

        // AND THE TAIL DID MOVE — in the stated direction. Negative SHORTENS
        // (pulls the ring-out down), positive LENGTHENS. Getting this backwards
        // is the single most likely implementation error, so it is asserted by
        // SIGN and not just by magnitude.
        let tailDown = windowGainDb(shaped: shorter, reference: reference,
                                    startMs: 80, endMs: 200)
        let tailUp = windowGainDb(shaped: longer, reference: reference,
                                  startMs: 80, endMs: 200)
        print("[measured] m39-y L5b tail at sustainDb −9: \(tailDown) dB; "
              + "at +9: \(tailUp) dB")
        for value in tailDown { #expect(value < -6.0, "−9 dB of body read \(value) dB") }
        for value in tailUp { #expect(value > 6.0, "+9 dB of body read \(value) dB") }

        // ⚠️ AND THE TAIL DOES NOT RING FOREVER at +9: `envSustain` is itself
        // decaying, so the boost saturates and then falls away. The LATE tail
        // must still be quieter than the early tail.
        let onset = burstOnsets()[1]
        let early = peak(longer, (onset + frames(80))..<(onset + frames(120)))
        let late = peak(longer, (onset + frames(250))..<(onset + frames(300)))
        print("[measured] m39-y L5b +9 tail decay: early \(dB(early)) dB, "
              + "late \(dB(late)) dB")
        #expect(late < early, "a +9 dB body must lengthen the tail, not freeze it")
    }

    // MARK: - L6: LEVEL INDEPENDENCE — the detector's central claim

    /// ⭐⭐ **THE MOST IMPORTANT LEG IN THIS FILE, AND THE ONE THE DESIGN'S
    /// CENTRAL CHOICE STANDS OR FALLS ON.** The differentials are dB RATIOS of
    /// LINEAR envelopes. A linear one-pole has a level-proportional step
    /// response, so `envFast / envAttack` is invariant under a change of input
    /// gain — and therefore so is every dB the effect applies.
    ///
    /// ⛔ **IT HAS TWO ASSERTIONS AND IT NEEDS BOTH.** "The two trajectories
    /// agree" is satisfied trivially by an effect that does nothing at either
    /// level, which is exactly what the classic wrong formulation degenerates
    /// to. So the leg FIRST proves real shaping is present at both levels, and
    /// only then that they agree.
    ///
    /// ⚠️ The comparison is restricted to where the QUIETER render is above the
    /// `detectorFloorDb` hard gate. The floor is level-dependent BY DESIGN — it
    /// is an absolute noise gate — so including gated samples would be
    /// measuring the gate, not the detector.
    @Test("L6 — the SAME burst 20 dB quieter gets the SAME shaping, sample for sample, within 0.1 dB")
    func shapingIsLevelIndependent() throws {
        let loud = probeBursts(peakDb: -12)
        let quiet = probeBursts(peakDb: -32)
        let params = TransientShaperParams(attackDb: 9, sustainDb: -6,
                                           attackMs: 30, sustainMs: 200)
        let loudOut = try shape(params, loud.signal)
        let quietOut = try shape(params, quiet.signal)

        let floorLin = TransientShaperParams.detectorFloorLinear
        var worst = 0.0
        var worstFrame = -1
        var compared = 0
        var loudRange = (lo: 0.0, hi: 0.0)
        var quietRange = (lo: 0.0, hi: 0.0)
        for index in 0..<loud.signal.count {
            // Both renders must be above the ABSOLUTE floor for the comparison
            // to be about the detector at all. 6 dB of margin.
            guard quiet.envelope[index] >= floorLin * 2 else { continue }
            let loudGain = dB(Double(loudOut[index]) / Double(loud.signal[index]))
            let quietGain = dB(Double(quietOut[index]) / Double(quiet.signal[index]))
            loudRange = (min(loudRange.lo, loudGain), max(loudRange.hi, loudGain))
            quietRange = (min(quietRange.lo, quietGain), max(quietRange.hi, quietGain))
            let delta = abs(loudGain - quietGain)
            if delta > worst { worst = delta; worstFrame = index }
            compared += 1
        }
        print("[measured] m39-y L6 over \(compared) frames: worst disagreement "
              + "\(worst) dB at frame \(worstFrame); loud gain range "
              + "\(loudRange.lo)…\(loudRange.hi) dB; quiet gain range "
              + "\(quietRange.lo)…\(quietRange.hi) dB")

        // (i) NON-VACUITY, and it is what kills the degenerate wrong
        //     formulation: real shaping is present at BOTH levels.
        #expect(compared > frames(400), "too few comparable frames — the mask is wrong")
        #expect(loudRange.hi - loudRange.lo > 5.0,
                "the LOUD render shows only \(loudRange.hi - loudRange.lo) dB of shaping — this leg would agree vacuously")
        #expect(quietRange.hi - quietRange.lo > 5.0,
                "the QUIET render shows only \(quietRange.hi - quietRange.lo) dB of shaping — the effect is level-DEPENDENT")
        // (ii) …and the two trajectories agree.
        #expect(worst < 0.1, "worst per-sample disagreement \(worst) dB")
    }

    // MARK: - L7: allocation-free on the render path

    /// `malloc_logger` is called on BOTH allocate and free, so a transient
    /// allocation is counted twice rather than cancelling out. Unavailable is a
    /// FAILURE, never a skip.
    // The hook, the counter cells and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe): one measurement at a time.

    @Test("L7 — process() allocates NOTHING across 4 000 quanta, and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
            return
        }
        let quantum = 512
        let calls = 4_000
        // Everything switched ON: both amounts non-zero (so both `log10`s and
        // the `pow` are live), a short attack and a long sustain, a partial mix
        // so the fold is exercised, and an output trim.
        let effect = TransientShaperEffect(params: TransientShaperParams(
            attackDb: 12, sustainDb: -8, attackMs: 3, sustainMs: 400,
            outputDb: -3, mix: 0.7))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                       channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let data = try #require(buffer.floatChannelData)

        // ⚠️⚠️ THE BUFFER IS RE-STAGED EVERY CALL, AND THAT IS NOT TIDINESS.
        // `process` works IN PLACE. This kind is a pure gain stage, so at
        // `attackDb 12` re-processing its own output compounds the boost every
        // pass and would reach `inf` and then `NaN` long before call 4 000 —
        // and `PhaserTests` records exactly that run, where the allocation count
        // stayed a clean 0 the entire time. A probe measuring a NaN render is
        // measuring nothing, in the same green tone as a probe measuring a real
        // one.
        let source = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
        defer { source.deallocate() }
        for frame in 0..<quantum {
            let t = Double(frame) / Self.sampleRate
            // A transient every quantum, so the detector is never merely idle.
            let burst = frame < 64 ? 1.0 : 0.15
            source[frame] = Float(burst * 0.4 * sin(2.0 * .pi * 220 * t))
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)

        var sum: Float = 0
        let events = MallocProbe.events(slot: slot) {
            var call = 0
            while call < calls {
                // `while`, not `for … in`: a `Range` iteration inside the
                // measured window would raise the harness's own allocations.
                var frame = 0
                while frame < quantum {
                    data[0][frame] = source[frame]
                    data[1][frame] = source[frame]
                    frame &+= 1
                }
                // The automation store runs on the same render thread and is
                // part of the contract, so it is INSIDE the probe — including
                // the two time constants, whose derive runs four `exp` calls.
                effect.storeAutomatedParam(slot: 0, value: Double(call % 21) - 10)
                effect.storeAutomatedParam(slot: 2, value: 0.5 + Double(call % 40))
                effect.storeAutomatedParam(slot: 3, value: 50 + Double(call % 500))
                effect.process(buffers: list, frameCount: quantum)
                sum += data[0][100]
                call += 1
            }
        }
        print("[measured] m39-y render allocation events over \(calls) quanta: \(events)")
        #expect(events == 0, "process() raised \(events) malloc/free events")
        // NON-VACUITY: the probe measured a render that actually happened.
        #expect(sum != 0, "the probe ran over a silent/no-op render")
        #expect(sum.isFinite)
    }

    @Test("L7b — POSITIVE CONTROL: the malloc probe can actually count")
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
        #expect(events > 0, "the malloc probe counted \(events) events")
        #expect(sink.count == 200)
    }

    // MARK: - L8: smoothing is NOT deletable

    /// ⛔ **THIS LEG EXISTS BECAUSE m39-j PROVED MANDATORY SMOOTHING WAS
    /// DELETABLE WITH 24/24 TESTS GREEN** (`ROADMAP.md:4173-4176`).
    ///
    /// ⚠️ **IT AUTOMATES `outputDb`, NOT `attackDb`, AND THAT IS THE WHOLE
    /// POINT OF THE LEG.** On the steady signal this needs, `dA` is ≈ 0, so
    /// `attackDb · shapedFraction(dA)` is ≈ 0 and an `attackDb` step would be
    /// invisible whether it were smoothed or not — the plant would be
    /// multiplied by zero and the leg would be unfalsifiable while reading as
    /// rigorous. `outputDb` is on the unconditional path, so it is the one
    /// parameter whose smoothing this leg can actually see.
    @Test("L8 — an automated parameter step is interpolated ACROSS the quantum, not applied at its first sample")
    func parameterStepsAreSmoothedAcrossTheQuantum() throws {
        let quantum = 512
        let input = steadyProbe(peakDb: -12, frames: quantum * 6)
        let effect = TransientShaperEffect(params: TransientShaperParams())
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                       channelCount: 1)
        // The step lands at the top of quantum 3, after the envelopes have
        // settled on a constant signal.
        let out = try processChunked(effect, channels: [input], chunk: quantum) { fx, q in
            if q >= 3 { fx.storeAutomatedParam(slot: 4, value: 12) }
        }[0]

        var worstStep = 0.0
        var worstFrame = -1
        let boundary = quantum * 3
        for index in (boundary - 8)..<(boundary + quantum) {
            let here = dB(Double(out[index]) / Double(input[index]))
            let before = dB(Double(out[index - 1]) / Double(input[index - 1]))
            let step = abs(here - before)
            if step > worstStep { worstStep = step; worstFrame = index }
        }
        let settled = dB(Double(out[boundary + quantum + 10])
                         / Double(input[boundary + quantum + 10]))
        print("[measured] m39-y L8 largest single-sample gain step across the "
              + "boundary: \(worstStep) dB at frame \(worstFrame) "
              + "(per-sample budget 12/512 = \(12.0 / 512.0) dB); "
              + "settled gain \(settled) dB")
        // The per-sample interpolation step for a 12 dB move over 512 frames is
        // 0.0234 dB; 0.1 dB is 4× headroom and 120× tighter than the 12 dB jump
        // the plant produces.
        #expect(worstStep < 0.1,
                "a \(worstStep) dB single-sample jump — the interpolation is gone")
        // NON-VACUITY: the parameter really did move by the full amount.
        #expect(abs(settled - 12.0) < 0.05,
                "the automated outputDb never reached its target (\(settled) dB)")
    }

    // MARK: - L2d: the RENDER half of the frozen slot order

    /// ⛔ **L2/L2b/L2c pin `EffectParamSpec.specs(for: .transientShaper)` — the
    /// index a lane is LABELLED with. This pins the other end: the field
    /// `storeAutomatedParam(slot:)` actually moves.** Nothing else in the tree
    /// compares them. L8 settles slot 4 (`outputDb`) and L7 pokes 0, 2 and 3
    /// while asserting only that no allocation happened — so a transposed arm
    /// (`case 1: overlay.effective.attackMs = value`) would ship an automation
    /// lane the UI labels "sustainDb" that moves the ATTACK TIME, with every
    /// other leg in this file green.
    ///
    /// Method: for each slot, one instance is driven through the AUTOMATION path
    /// (constructed at `ctor`, then poked every quantum) and one through the
    /// KNOB path (constructed with the same value set by NAME). They must render
    /// the same audio. That is only evidence if the seven reference renders are
    /// mutually distinguishable, so the pairwise leg runs FIRST: if any two
    /// settings rendered alike, a swap between them would be invisible and this
    /// leg would pass vacuously.
    @Test("L2d — every automation slot moves the parameter its frozen spec index names, and the seven reference settings are pairwise distinguishable")
    func automationSlotsMoveTheParameterTheirIndexNames() throws {
        let input = probeBursts(peakDb: -12).signal
        let base = TransientShaperParams()

        // (slot, name, params the automated instance is BUILT with, poked value,
        //  the same setting reached by NAME through the init)
        let rows: [(slot: Int, name: String, ctor: TransientShaperParams,
                    value: Double, knob: TransientShaperParams)] = [
            (0, "attackDb", base, 12,
             TransientShaperParams(attackDb: 12)),
            (1, "sustainDb", base, 12,
             TransientShaperParams(sustainDb: 12)),
            // A time constant is inert unless its half is shaping, so slots 2
            // and 3 are poked on top of a shaping ctor.
            (2, "attackMs", TransientShaperParams(attackDb: 12), 40,
             TransientShaperParams(attackDb: 12, attackMs: 40)),
            (3, "sustainMs", TransientShaperParams(sustainDb: 12), 600,
             TransientShaperParams(sustainDb: 12, sustainMs: 600)),
            (4, "outputDb", base, 6,
             TransientShaperParams(outputDb: 6)),
            (5, "mix", TransientShaperParams(outputDb: 6), 0.25,
             TransientShaperParams(outputDb: 6, mix: 0.25)),
        ]

        func maxDifference(_ lhs: [Float], _ rhs: [Float]) -> Double {
            var worst = 0.0
            for index in 0..<min(lhs.count, rhs.count) {
                worst = max(worst, Double(abs(lhs[index] - rhs[index])))
            }
            return worst
        }

        // ── Leg 1: the reference renders are mutually distinguishable.
        let references = [("base", base)] + rows.map { ($0.name, $0.knob) }
        let rendered = try references.map { try shape($0.1, input) }
        var closest = Double.infinity
        var closestPair = ""
        for i in 0..<rendered.count {
            for j in (i + 1)..<rendered.count {
                let difference = maxDifference(rendered[i], rendered[j])
                if difference < closest {
                    closest = difference
                    closestPair = "\(references[i].0) vs \(references[j].0)"
                }
            }
        }
        print("[measured] m39-y L2d closest reference pair: \(closestPair) "
              + "at max|Δ| = \(closest)")
        #expect(closest > 1e-4,
                "two of the seven reference settings render within \(closest) of each other (\(closestPair)) — a slot transposed between them would be INVISIBLE and the mapping leg below proves nothing")

        // ── Leg 2: slot s, driven as automation, renders as its NAMED field.
        for (index, row) in rows.enumerated() {
            let effect = TransientShaperEffect(params: row.ctor)
            effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                           channelCount: 2)
            // Re-poked every quantum: a lane that stops writing is a lane that
            // vanished, and `overlay.endQuantum()` would revert it by design.
            let automated = try processChunked(effect, channels: [input, input],
                                               chunk: 512) { fx, _ in
                fx.storeAutomatedParam(slot: row.slot, value: row.value)
            }[0]
            let knob = rendered[index + 1]
            let difference = maxDifference(automated, knob)
            // What the WRONG answer would look like, quantified: the nearest
            // other reference render.
            var nearestOther = Double.infinity
            var nearestName = ""
            for (other, name) in references.enumerated().map({ ($0.offset, $0.element.0) })
            where other != index + 1 {
                let d = maxDifference(automated, rendered[other])
                if d < nearestOther { nearestOther = d; nearestName = name }
            }
            print("[measured] m39-y L2d slot \(row.slot) (\(row.name)): "
                  + "automation vs knob max|Δ| = \(difference); "
                  + "nearest OTHER setting \(nearestName) at \(nearestOther)")
            #expect(difference < 1e-6,
                    "slot \(row.slot) was supposed to move `\(row.name)`, but its render differs from the knob path by \(difference) and sits \(nearestOther) from `\(nearestName)` — the slot is wired to the wrong field")
        }
    }

    // MARK: - L9: latency is ZERO

    @Test("L9 — latencySamples is 0, at every prepared rate and every setting")
    func latencyIsZero() {
        let effect = TransientShaperEffect(params: TransientShaperParams(
            attackDb: 20, sustainDb: -20, attackMs: 50, sustainMs: 1_000,
            outputDb: 24, mix: 0.5))
        #expect(effect.latencySamples == 0)
        for rate in [44_100.0, 48_000.0, 96_000.0] {
            effect.prepare(sampleRate: rate, maxFramesPerQuantum: 512, channelCount: 2)
            #expect(effect.latencySamples == 0, "non-zero latency at \(rate) Hz")
        }
        // ⛔ If this ever changes, the effect has entered the insert-PDC
        // guarantee measured sample-exact at m25-n and MUST be re-measured
        // against it. See `EffectChainRenderTests`' chain-total leg for the
        // other half of this assertion.
    }

    // MARK: - Denormals and NaN

    /// Every one of the three envelopes is its own one-pole IIR and each decays
    /// into subnormals on silence INDEPENDENTLY — so one flush is not enough,
    /// and an output-only assertion is blind by construction (the `PhaserTests`
    /// L6 lesson: that shape passed with every per-section flush deleted).
    /// This reports the STATE.
    @Test("Denormals — all three envelopes flush to hard zero on silence, having actually decayed THROUGH the subnormal band")
    func envelopesFlushOnSilence() throws {
        let effect = TransientShaperEffect(params: TransientShaperParams(
            attackDb: 12, sustainDb: 12, attackMs: 0.1, sustainMs: 20))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let loud = [Float](repeating: 0.5, count: 512)
        _ = try processChunked(effect, channels: [loud, loud], chunk: 512)
        let peakState = effect.detectorEnvelopes
        // The chain really was excited, so "0 subnormals" later cannot be a
        // reading from state that was already at hard zero.
        #expect(peakState.fast > 0.1 && peakState.attack > 0.1 && peakState.sustain > 0.1)

        let silence = [Float](repeating: 0, count: 48_000)
        let out = try processChunked(effect, channels: [silence, silence], chunk: 512)
        let rest = effect.detectorEnvelopes
        print("[measured] m39-y denormal flush after 1 s of silence: "
              + "fast=\(rest.fast) attack=\(rest.attack) sustain=\(rest.sustain)")
        #expect(rest.fast == 0 && rest.attack == 0 && rest.sustain == 0,
                "an envelope is sitting in the subnormal band on silence")
        #expect(!out[0].contains { !$0.isFinite })
    }

    /// A field-by-field overlay poke bypasses `TransientShaperParams.init`, so
    /// the clamping the init does is NOT in force — and a NaN reaching `pow`
    /// would poison the interpolation accumulators PERMANENTLY, silencing the
    /// strip for the rest of the session.
    @Test("NaN guard — an out-of-range or non-finite automation store cannot poison the render")
    func automationStoresCannotPoisonTheRender() throws {
        let effect = TransientShaperEffect(params: TransientShaperParams())
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 1)
        let input = sineBursts(peakDb: -12)
        let out = try processChunked(effect, channels: [input], chunk: 512) { fx, q in
            // Non-finite: must be inert. Out-of-range: must be clamped. An
            // out-of-range SLOT: inert.
            fx.storeAutomatedParam(slot: 0, value: .nan)
            fx.storeAutomatedParam(slot: 2, value: .infinity)
            fx.storeAutomatedParam(slot: 9, value: 1_000)
            fx.storeAutomatedParam(slot: 4, value: Double(q % 2 == 0 ? 9_999 : -9_999))
        }
        let bad = out[0].filter { !$0.isFinite }.count
        let loudest = out[0].map { abs($0) }.max() ?? 0
        print("[measured] m39-y NaN guard: \(bad) non-finite output samples, "
              + "peak \(loudest)")
        #expect(bad == 0)
        // outputDb clamps to ±24 dB; the input peaks at −12 dBFS, so the
        // arithmetic ceiling is −12 + 24 + 24 (maxShapeDb) = +36 dBFS ≈ 63.1.
        #expect(loudest < 64.0)
        #expect(loudest > 0)
    }
}
