import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m23-p1 — the psychoacoustic bass harmonic enhancer.
///
/// The load-bearing claim is a MEASURED HARMONIC SERIES, not "energy appeared
/// above the crossover" (energy appearing is also what a bug produces). The
/// legs are built so that the obvious wrong implementations each redden a
/// DIFFERENT one:
///
///  · a broadband waveshaper (our `saturator`)  → P1's H2/H4 literals (tanh is
///    odd-symmetric: no even partials at all) and P1's H5 truncation leg.
///  · a bare polynomial with no level tracking  → P2 (the harmonic-to-input
///    ratios would move by ~40 dB across a 20 dB input change).
///  · `amount` wired as a plain output gain     → P3 (the H3/H2 ratio would
///    not move at all).
///  · a fixed high-pass that ignores the corner → P4.
///  · a missing neutral skip                    → P5/P6, separately.
///  · a generator that chatters on silence      → P7/P8.
///
/// EVERY LEVEL LITERAL IN HERE WAS MEASURED AND PASTED, never recomputed from
/// the effect's own constants: recomputing the expected series from the same
/// `crossoverHz` and the same `harmonicWeights` the DSP used would prove the
/// arithmetic and not the DSP. The prediction each literal was checked against
/// is recorded beside it — it comes from independent theory (2nd-order
/// Butterworth magnitudes and `T_n(cos θ) = cos nθ`), not from the code.
@MainActor
@Suite("Bass enhancer — measured harmonic series, level tracking, neutrality (m23-p1)")
struct BassEnhancerTests {
    private static let sampleRate = 48_000.0
    /// 2 s rendered; the tail second is measured. The amplitude detector is a
    /// 50 ms one-pole, so the first ~250 ms is settling — measuring from 0
    /// would fold the settle transient into every level. 48 000 frames at
    /// 48 kHz is a whole number of periods of 50/100/150/200/250 Hz, so the
    /// Goertzel bins are exact.
    private static let totalFrames = 96_000
    private static let window = 48_000..<96_000

    // MARK: - Signal + measurement helpers (FXPack2Tests conventions)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    /// Goertzel single-bin amplitude estimate over `range` (≈ the sinusoid's
    /// peak amplitude when `range` spans whole periods).
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

    /// Runs `channels` through `effect` in 512-frame quanta (state continuity
    /// across quantum boundaries included in the proof). Returns the output.
    /// `beforeEachQuantum` runs immediately before every `process()` call —
    /// the `AutomationRenderer` contract (stores land before the walk, on the
    /// same thread, EVERY quantum; `AutomationRenderer.swift:185`).
    private func processChunked(_ effect: any EffectRendering,
                                channels: [[Float]], chunk: Int = 512,
                                beforeEachQuantum: (any EffectRendering) -> Void = { _ in }
    ) throws -> [[Float]] {
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
            beforeEachQuantum(effect)
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

    /// Renders a mono `dry` through a fresh enhancer (stereo-fed) and returns
    /// channel 0.
    private func render(_ params: BassEnhancerParams, dry: [Float]) throws -> [Float] {
        let effect = BassEnhancerEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return try processChunked(effect, channels: [dry, dry])[0]
    }

    /// The partial levels of `wet`, in dB relative to the INPUT fundamental's
    /// own amplitude — so every number is "how far below the bass note the
    /// generated harmonic sits", which is amplitude-independent by design.
    private func partialsDb(_ wet: [Float], fundamental f0: Double,
                            inputAmplitude: Double) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for n in 1...5 {
            out[n] = dB(goertzel(wet, frequency: f0 * Double(n), in: Self.window)
                        / inputAmplitude)
        }
        return out
    }

    private func assertAllFinite(_ samples: [Float], _ label: String) {
        #expect(samples.allSatisfy { $0.isFinite }, "\(label): NaN/Inf guard")
    }

    // MARK: - P1: the measured harmonic series (the headline gate leg)

    @Test("a pure 50 Hz sine grows a measured 2nd/3rd/4th series above the crossover")
    func pureLowSineGrowsTheMeasuredSeries() throws {
        let f0 = 50.0, amplitude = 0.5
        let dry = sine(f0, amplitude: amplitude, frames: Self.totalFrames)
        let wet = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1), dry: dry)
        let p = partialsDb(wet, fundamental: f0, inputAmplitude: amplitude)
        let dryP = partialsDb(dry, fundamental: f0, inputAmplitude: amplitude)
        print("[measured] p1 series @ f0 50 Hz, fc 80 Hz, amount 1, mix 1 — "
              + "H1 \(p[1]!) dB (dry \(dryP[1]!)), H2 \(p[2]!), H3 \(p[3]!), "
              + "H4 \(p[4]!), H5 \(p[5]!)")

        // THE SERIES. Measured 2026-07-29 and pasted. Before running it, the
        // same numbers were predicted from theory ALONE — H2 −11.22, H3
        // −11.41, H4 −12.76 dB, from the analogue 2nd-order Butterworth
        // magnitudes |LP(50/80)| = 0.9315 and |HP(n·50/80)| = 0.8423/0.9619/
        // 0.9873 and the identity T_n(cos θ) = cos nθ at weights
        // 0.35/0.30/0.25. Prediction and measurement agree to 0.02 dB. THAT
        // is what makes these literals a pin: they were not read off the code
        // under test, and nothing here recomputes them from `crossoverHz` or
        // from `harmonicWeights`. The ±0.35 dB band is for cross-machine libm
        // drift (the m22-a null-pin precedent), not for slack in the claim.
        #expect(abs(p[2]! - -11.231) < 0.35, "H2 \(p[2]!)")
        #expect(abs(p[3]! - -11.421) < 0.35, "H3 \(p[3]!)")
        #expect(abs(p[4]! - -12.782) < 0.35, "H4 \(p[4]!)")

        // TRUNCATION — the leg that separates this from a waveshaper. The
        // generator is three Chebyshev terms, so there IS no 5th partial;
        // whatever lands in that bin is detector-ripple sideband. A `tanh`
        // stage would put H5 within ~15 dB of H3.
        #expect(p[5]! < p[4]! - 20, "H5 \(p[5]!) must sit far below H4 \(p[4]!)")

        // The dry path is untouched: the fundamental comes through at its own
        // level (the effect ADDS, it never filters what you already have).
        #expect(abs(p[1]! - dryP[1]!) < 0.05, "H1 wet \(p[1]!) vs dry \(dryP[1]!)")
        assertAllFinite(wet, "p1")
    }

    // MARK: - P2: level tracking (a property, not arithmetic)

    @Test("the harmonic series holds its shape across a 20 dB input level change")
    func seriesIsLevelIndependent() throws {
        let f0 = 50.0
        let params = BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1)
        let loud = try render(params, dry: sine(f0, amplitude: 0.5, frames: Self.totalFrames))
        let quiet = try render(params, dry: sine(f0, amplitude: 0.05, frames: Self.totalFrames))
        let l = partialsDb(loud, fundamental: f0, inputAmplitude: 0.5)
        let q = partialsDb(quiet, fundamental: f0, inputAmplitude: 0.05)
        print("[measured] p2 level tracking — loud H2/H3/H4 \(l[2]!)/\(l[3]!)/\(l[4]!), "
              + "quiet \(q[2]!)/\(q[3]!)/\(q[4]!)")
        // A bare polynomial shaper's partials scale as A²/A³/A⁴, so a 20 dB
        // input drop would move these by 20/40/60 dB. The detector is what
        // holds them still.
        for n in 2...4 {
            #expect(abs(l[n]! - q[n]!) < 0.5,
                    "H\(n) moved \(l[n]! - q[n]!) dB across a 20 dB input change")
        }
        assertAllFinite(quiet, "p2 quiet")
    }

    // MARK: - P3: `amount` tilts the series — it is not a second output gain

    @Test("raising amount tilts the series toward the higher partials, not just up")
    func amountTiltsTheSeries() throws {
        let f0 = 50.0, amplitude = 0.5
        let dry = sine(f0, amplitude: amplitude, frames: Self.totalFrames)
        let low = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 0.25, mix: 1), dry: dry)
        let high = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1), dry: dry)
        let l = partialsDb(low, fundamental: f0, inputAmplitude: amplitude)
        let h = partialsDb(high, fundamental: f0, inputAmplitude: amplitude)
        // H3 relative to H2 — a pure level control cannot move this at all.
        let tiltLow = l[3]! - l[2]!
        let tiltHigh = h[3]! - h[2]!
        print("[measured] p3 tilt — amount 0.25: H3−H2 \(tiltLow) dB; "
              + "amount 1: H3−H2 \(tiltHigh) dB; overall H2 \(l[2]!) → \(h[2]!)")
        #expect(tiltLow < -12, "at amount 0.25 the series must be 2nd-harmonic dominated")
        #expect(tiltHigh > -3, "at amount 1 the 3rd must come up beside the 2nd")
        #expect(tiltHigh - tiltLow > 9,
                "shape moved only \(tiltHigh - tiltLow) dB: amount is behaving as a gain")
        // It must still raise the level too (a tilt-only control would be a
        // different bug, and this is the half that catches it).
        #expect(h[2]! > l[2]! + 3, "amount must also raise the 2nd partial")
    }

    // MARK: - P4: the crossover really is the crossover

    @Test("raising the crossover above a partial attenuates THAT partial, not the series")
    func crossoverGatesThePartialsIndividually() throws {
        let f0 = 50.0, amplitude = 0.5
        let dry = sine(f0, amplitude: amplitude, frames: Self.totalFrames)
        let near = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1), dry: dry)
        // 250 Hz puts H2 (100 Hz) well BELOW the corner while H4 (200 Hz) is
        // still close to it: the injection high-pass must cut them by very
        // different amounts. A fixed high-pass would cut them equally (0 dB).
        let far = try render(
            BassEnhancerParams(crossoverHz: 250, amount: 1, mix: 1), dry: dry)
        let n = partialsDb(near, fundamental: f0, inputAmplitude: amplitude)
        let f = partialsDb(far, fundamental: f0, inputAmplitude: amplitude)
        let dropH2 = n[2]! - f[2]!
        let dropH4 = n[4]! - f[4]!
        print("[measured] p4 crossover — fc 80 → 250: H2 \(n[2]!) → \(f[2]!) "
              + "(drop \(dropH2) dB), H4 \(n[4]!) → \(f[4]!) (drop \(dropH4) dB)")
        #expect(dropH2 > 10, "H2 must fall a long way once it is below the corner")
        #expect(dropH4 < 7, "H4 sits near the corner and must survive")
        #expect(dropH2 - dropH4 > 6,
                "partials moved together (\(dropH2) vs \(dropH4) dB): filter ignores crossoverHz")
    }

    // MARK: - P5/P6: the two neutral conditions, pinned SEPARATELY

    @Test("amount 0 is bit-exact dry (mix wide open)")
    func amountZeroIsBitExactDry() throws {
        let dry = sine(50, amplitude: 0.5, frames: 24_000)
        let wet = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 0, mix: 1), dry: dry)
        var maxDiff: Float = 0
        for frame in 0..<dry.count { maxDiff = max(maxDiff, abs(wet[frame] - dry[frame])) }
        #expect(maxDiff == 0)
    }

    @Test("mix 0 is bit-exact dry (amount wide open)")
    func mixZeroIsBitExactDry() throws {
        let dry = sine(50, amplitude: 0.5, frames: 24_000)
        let wet = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 0), dry: dry)
        var maxDiff: Float = 0
        for frame in 0..<dry.count { maxDiff = max(maxDiff, abs(wet[frame] - dry[frame])) }
        #expect(maxDiff == 0)
    }

    // MARK: - P5b/P6b: a neutral pass advances NO STATE
    //
    // WHY THESE EXIST. P5/P6 above prove bit-exactness — and MUTATION SHOWED
    // THEY PROVE IT TOO WEAKLY: deleting either half of the effect's `active`
    // guard left both of them GREEN, because `amount == 0` zeroes the series
    // weights and `mix == 0` zeroes the wet gain, so the arithmetic lands on
    // `x + 0.0` (== `x` exactly in IEEE754) with or without the skip. The
    // skip's real, observable consequence is that the two biquads and the
    // detector never run, so a neutral stretch leaves NO warm state behind.
    // Each leg below removes exactly one condition's cover, so they redden
    // DISJOINTLY: the amount leg dies if `amount != 0` is dropped, the mix leg
    // if `mix != 0` is.

    /// Renders `dry` in two halves, applying `second` before the second half.
    private func renderAcrossAParamChange(
        first: BassEnhancerParams, second: BassEnhancerParams, dry: [Float]
    ) throws -> [Float] {
        let effect = BassEnhancerEffect(params: first)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let head = Array(dry[0..<48_000])
        let tail = Array(dry[48_000...])
        _ = try processChunked(effect, channels: [head, head])
        effect.apply(params: second)
        return try processChunked(effect, channels: [tail, tail])[0]
    }

    @Test("a neutral amount-0 stretch leaves no warm state: re-enabling matches a fresh insert")
    func neutralPassAdvancesNoStateAmount() throws {
        let dry = sine(50, amplitude: 0.5, frames: Self.totalFrames)
        let live = BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1)
        let reEnabled = try renderAcrossAParamChange(
            first: BassEnhancerParams(crossoverHz: 80, amount: 0, mix: 1),
            second: live, dry: dry)
        let fresh = try render(live, dry: Array(dry[48_000...]))
        var maxDiff: Float = 0
        for frame in 0..<fresh.count {
            maxDiff = max(maxDiff, abs(reEnabled[frame] - fresh[frame]))
        }
        print("[measured] p5b amount-0 stretch → re-enable, max |Δ| vs fresh \(maxDiff)")
        #expect(maxDiff == 0)
    }

    @Test("a neutral mix-0 stretch leaves no warm state: re-enabling matches a fresh insert")
    func neutralPassAdvancesNoStateMix() throws {
        let dry = sine(50, amplitude: 0.5, frames: Self.totalFrames)
        let live = BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1)
        let reEnabled = try renderAcrossAParamChange(
            first: BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 0),
            second: live, dry: dry)
        let fresh = try render(live, dry: Array(dry[48_000...]))
        var maxDiff: Float = 0
        for frame in 0..<fresh.count {
            maxDiff = max(maxDiff, abs(reEnabled[frame] - fresh[frame]))
        }
        print("[measured] p6b mix-0 stretch → re-enable, max |Δ| vs fresh \(maxDiff)")
        #expect(maxDiff == 0)
    }

    // MARK: - P7/P8: silence and the noise floor

    @Test("digital silence in is EXACTLY silence out (the generator never chatters)")
    func silenceInIsExactlySilenceOut() throws {
        let dry = [Float](repeating: 0, count: 48_000)
        let wet = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1), dry: dry)
        let peak = wet.map { abs($0) }.max() ?? 0
        print("[measured] p7 silence peak \(peak)")
        #expect(peak == 0)
    }

    @Test("a −80 dBFS bass note is enhanced in proportion, not amplified or ignored")
    func noiseFloorLevelStaysProportional() throws {
        let f0 = 50.0, amplitude = 1e-4  // −80 dBFS
        let dry = sine(f0, amplitude: amplitude, frames: Self.totalFrames)
        let wet = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1), dry: dry)
        let p = partialsDb(wet, fundamental: f0, inputAmplitude: amplitude)
        let peak = Double(wet.map { abs($0) }.max() ?? 0)
        print("[measured] p8 @ −80 dBFS — H2 \(p[2]!), H3 \(p[3]!), H4 \(p[4]!), "
              + "output peak \(peak)")
        assertAllFinite(wet, "p8")
        // Same relative series as P1's loud case: the ε in the divisor must
        // not have started swallowing real signal this far up.
        #expect(abs(p[2]! - -11.231) < 1.0, "H2 \(p[2]!)")
        #expect(abs(p[4]! - -12.782) < 1.0, "H4 \(p[4]!)")
        // And nothing ran away: bounded by input + 0.9 × the low band.
        #expect(peak < amplitude * 2)
    }

    // MARK: - P9: content above the crossover is not touched

    @Test("a 1 kHz tone well above the crossover passes through essentially unchanged")
    func contentAboveTheCrossoverIsUntouched() throws {
        let dry = sine(1_000, amplitude: 0.5, frames: Self.totalFrames)
        let wet = try render(
            BassEnhancerParams(crossoverHz: 80, amount: 1, mix: 1), dry: dry)
        let fundamental = dB(goertzel(wet, frequency: 1_000, in: Self.window)
                             / goertzel(dry, frequency: 1_000, in: Self.window))
        let second = dB(goertzel(wet, frequency: 2_000, in: Self.window) / 0.5)
        print("[measured] p9 @ 1 kHz — fundamental \(fundamental) dB, "
              + "2 kHz product \(second) dB")
        #expect(abs(fundamental) < 0.02, "the dry path must not be filtered")
        #expect(second < -45, "nothing above the crossover reaches the generator")
    }

    // MARK: - P10: automation slots match the spec table

    @Test("automation slots 0/1/2 are crossoverHz/amount/mix; bad slots are inert")
    func automationSlotsFollowTheSpecOrder() throws {
        #expect(EffectParamSpec.specs(for: .bassEnhancer).map(\.name)
                == ["crossoverHz", "amount", "mix"])

        let dry = sine(50, amplitude: 0.5, frames: 24_000)

        // Slot 1 (amount) driven to 0 EVERY QUANTUM — that is the
        // `AutomationRenderer` contract (`AutomationRenderer.swift:185`:
        // stores land before `process()`, same thread, every quantum), and it
        // must reach the same bit-exact dry the knob does.
        let automated = BassEnhancerEffect(params: BassEnhancerParams(
            crossoverHz: 80, amount: 1, mix: 1))
        automated.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                          channelCount: 2)
        let silenced = try processChunked(automated, channels: [dry, dry]) { effect in
            effect.storeAutomatedParam(slot: 1, value: 0)
        }[0]
        var maxDiff: Float = 0
        for frame in 0..<dry.count {
            maxDiff = max(maxDiff, abs(silenced[frame] - dry[frame]))
        }
        #expect(maxDiff == 0, "automated amount 0 must be the same bit-exact dry")

        // Slot 0 (crossoverHz) automated to 250 must reproduce the KNOB's
        // 250 Hz render — the store and `apply` share one derive path, so
        // this pins the slot NUMBER, not merely that some slot did something.
        let long = sine(50, amplitude: 0.5, frames: Self.totalFrames)
        let viaSlot = BassEnhancerEffect(params: BassEnhancerParams(
            crossoverHz: 80, amount: 1, mix: 1))
        viaSlot.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let slotDriven = try processChunked(viaSlot, channels: [long, long]) { effect in
            effect.storeAutomatedParam(slot: 0, value: 250)
        }[0]
        let viaKnob = try render(
            BassEnhancerParams(crossoverHz: 250, amount: 1, mix: 1), dry: long)
        let slotH2 = dB(goertzel(slotDriven, frequency: 100, in: Self.window) / 0.5)
        let knobH2 = dB(goertzel(viaKnob, frequency: 100, in: Self.window) / 0.5)
        print("[measured] p10 slot 0 → 250 Hz: H2 \(slotH2) dB vs knob \(knobH2) dB")
        #expect(abs(slotH2 - knobH2) < 0.05, "slot 0 is not crossoverHz")

        // REVERT: a lane that stops storing restores the KNOB value with no
        // main-actor republish (the `AutomationParamOverlay.endQuantum`
        // contract, pinned for GainEffect at AutomationFXParamTests:378).
        // One store, then silence — the enhancer must come BACK.
        let reverting = BassEnhancerEffect(params: BassEnhancerParams(
            crossoverHz: 80, amount: 1, mix: 1))
        reverting.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                          channelCount: 2)
        reverting.storeAutomatedParam(slot: 1, value: 0)  // amount 0 for ONE quantum
        let reverted = try processChunked(reverting, channels: [long, long])[0]
        var earlyDiff: Float = 0
        for frame in 0..<512 { earlyDiff = max(earlyDiff, abs(reverted[frame] - long[frame])) }
        let revertedH2 = dB(goertzel(reverted, frequency: 100, in: Self.window) / 0.5)
        print("[measured] p10 revert — first quantum max |out − in| \(earlyDiff), "
              + "tail H2 \(revertedH2) dB (knob amount 1)")
        #expect(earlyDiff == 0, "the automated quantum must be bit-exact dry")
        #expect(abs(revertedH2 - -11.231) < 0.35,
                "the knob value did not restore once stores stopped")

        // Out-of-range slots and non-finite values are inert (the contract) —
        // driven every quantum, so an inert store cannot hide behind a revert.
        let inert = BassEnhancerEffect(params: BassEnhancerParams(
            crossoverHz: 80, amount: 1, mix: 1))
        inert.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let stillWet = try processChunked(inert, channels: [long, long]) { effect in
            effect.storeAutomatedParam(slot: 7, value: 0)
            effect.storeAutomatedParam(slot: 1, value: .nan)
        }[0]
        let inertH2 = dB(goertzel(stillWet, frequency: 100, in: Self.window) / 0.5)
        print("[measured] p10 inert stores — tail H2 \(inertH2) dB")
        assertAllFinite(stillWet, "p10 inert")
        #expect(abs(inertH2 - -11.231) < 0.35,
                "a rejected store changed the sound — it was not inert")
    }

    // MARK: - P11: the render path allocates nothing (m23-r1 probe recipe)

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
        if tid == BassEnhancerTests.watchedThread.pointee {
            BassEnhancerTests.eventCount.pointee &+= 1
        }
    }

    /// libmalloc's `malloc_logger` global. Nil is a FAILURE for the caller,
    /// never a skip — a silently-absent probe is the vacuity this leg exists
    /// to prevent (m23-r1).
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

    @Test("process() allocates nothing across 4 000 quanta — and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = Self.mallocLoggerSlot() else {
            Issue.record("malloc_logger is unavailable — the allocation probe cannot run. FAILURE, not a skip.")
            return
        }
        let quantum = 512
        let calls = 4_000
        let effect = BassEnhancerEffect(params: BassEnhancerParams(
            crossoverHz: 80, amount: 1, mix: 1))
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: quantum,
                       channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let data = try #require(buffer.floatChannelData)
        // A 50 Hz fundamental keeps the generator genuinely busy (it is the
        // path this leg exists to measure), plus a 750 Hz partner so the
        // low-pass, the detector and the injection high-pass all do work.
        for frame in 0..<quantum {
            let t = Double(frame) / Self.sampleRate
            let value = Float(0.4 * sin(2 * .pi * 50 * t) + 0.2 * sin(2 * .pi * 750 * t))
            data[0][frame] = value
            data[1][frame] = value
        }
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        // Re-staged every call from a RAW buffer (allocated here, outside the
        // window): the chain walk processes IN PLACE, so without re-staging
        // the 4 000 passes would feed each pass's harmonics back into the next
        // and the signal would compound away from anything realistic.
        let staged = UnsafeMutablePointer<Float>.allocate(capacity: quantum)
        defer { staged.deallocate() }
        for frame in 0..<quantum {
            staged[frame] = data[0][frame]
        }
        // Stage once, OUTSIDE the measured window (first-quantum adoption
        // recomputes coefficients; the probe must not see that).
        effect.process(buffers: list, frameCount: quantum)

        // THE MEASURED LOOP IS `while`, NOT `for … in 0..<n`: at -Onone a
        // `for _ in 0..<n {}` with an EMPTY body raises ~2 malloc/free events
        // per iteration from Range iteration itself, which would redden the
        // leg with the harness's own allocations (m23-r1 law).
        let events = Self.mallocEvents(slot: slot) {
            var call = 0
            while call < calls {
                var frame = 0
                while frame < quantum {
                    data[0][frame] = staged[frame]
                    data[1][frame] = staged[frame]
                    frame &+= 1
                }
                effect.process(buffers: list, frameCount: quantum)
                call &+= 1
            }
        }

        // The harness's own discriminator: an identically-shaped loop that
        // DOES allocate must be seen, or the leg above observes nothing.
        var sink: [[Float]] = []
        sink.reserveCapacity(calls)  // outside the measured window
        let controlEvents = Self.mallocEvents(slot: slot) {
            var call = 0
            while call < calls {
                sink.append([Float](repeating: 0, count: 8))
                call &+= 1
            }
        }
        print("[measured] p11 process() malloc/free events \(events) over \(calls) quanta "
              + "(allocating control \(controlEvents))")
        #expect(controlEvents >= calls, "malloc_logger did not fire — the leg is vacuous")
        #expect(events == 0, "process() allocated: \(events) malloc/free events")

        // ANTI-VACUITY: an effect that allocated nothing BECAUSE IT DID
        // NOTHING would pass the leg above. The buffer was re-staged at the
        // top of the LAST call, so any difference from `staged` is work the
        // final `process` did.
        var maxMoved: Float = 0
        for frame in 0..<quantum {
            maxMoved = max(maxMoved, abs(data[0][frame] - staged[frame]))
        }
        print("[measured] p11 last-pass max |out − in| \(maxMoved)")
        #expect(maxMoved > 1e-4,
                "process() left the buffer untouched — the allocation leg is vacuous")
    }

    // MARK: - P12: persistence round-trip (the half-done-registration leg)

    @Test("every bass-enhancer param survives save → reopen, and rides in the file")
    func paramsSurviveASaveAndReopen() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bassenh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = ProjectStore()
        let track = store.addTrack(name: "Bass", kind: .audio)
        let effect = try store.addEffect(toTrack: track.id, kind: .bassEnhancer)
        // Every param moved OFF its default, so a dropped field cannot hide
        // behind the default it would decode to.
        for (name, value) in [("crossoverHz", 140.0), ("amount", 0.8), ("mix", 0.6)] {
            _ = try store.setEffectParam(trackID: track.id, effectID: effect.id,
                                         name: name, value: value)
        }
        // A second, DEFAULTS-ONLY instance on the master chain: it must come
        // back as the right KIND even though it carries no params object.
        let masterFX = try store.addMasterEffect(kind: .bassEnhancer)
        let path = dir.appendingPathComponent("BassEnh").path
        // `saveProject` NORMALIZES the path (it appends `.dawproj`), so the
        // bundle is NOT at `path` — read the location it reports, not the one
        // we asked for.
        let saved = try store.saveProject(to: path)

        // The keys are really on disk (a missing `encodeIfPresent` would let
        // an in-memory-only round trip pass).
        let json = try String(contentsOf: URL(fileURLWithPath: saved.path)
            .appendingPathComponent("project.json"), encoding: .utf8)
        #expect(json.contains("\"bassEnhancer\""), "the params object is not in the file")
        #expect(json.contains("\"crossoverHz\""), "crossoverHz is not in the file")

        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let reTrack = try #require(reopened.tracks.first(where: { $0.name == "Bass" }))
        let reFX = try #require(reTrack.effects.first)
        #expect(reFX.kind == .bassEnhancer)
        #expect(reFX.id == effect.id)
        let p = reFX.resolvedBassEnhancer
        print("[measured] p12 reloaded — crossoverHz \(p.crossoverHz), amount \(p.amount), "
              + "mix \(p.mix)")
        #expect(p.crossoverHz == 140)
        #expect(p.amount == 0.8)
        #expect(p.mix == 0.6)

        let reMaster = try #require(reopened.masterEffects.first)
        #expect(reMaster.kind == .bassEnhancer)
        #expect(reMaster.id == masterFX.id)
        #expect(reMaster.resolvedBassEnhancer == BassEnhancerParams())
    }

    // MARK: - P13: undo labels read as English, not as a raw value

    @Test("the undo label spells the kind out (the default branch would say BassEnhancer)")
    func undoLabelIsBeginnerReadable() throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Bass", kind: .audio)
        _ = try store.addEffect(toTrack: track.id, kind: .bassEnhancer)
        print("[measured] p13 undo label '\(store.undoLabel ?? "nil")'")
        #expect(store.undoLabel == "Add Bass Enhancer to 'Bass'")
    }

    // MARK: - P14: the preset stamp carries the params through the INIT

    /// `MixerPresets.withFreshID()` is the one registration site that P12 does
    /// NOT reach. P12 goes through `ProjectStore.setEffectParam`, which assigns
    /// `effect.bassEnhancer = params` on an already-built descriptor — the
    /// SETTER. `withFreshID()` re-builds the descriptor through
    /// `EffectDescriptor.init`, so a missing `self.bassEnhancer = bassEnhancer`
    /// in that init would silently stamp defaults onto every strip a preset
    /// touches while every other leg here stayed green.
    @Test("stamping a preset keeps the bass-enhancer params (init pass-through)")
    func presetStampCarriesTheParams() throws {
        let template = EffectDescriptor(
            kind: .bassEnhancer, isBypassed: true,
            bassEnhancer: BassEnhancerParams(crossoverHz: 110, amount: 0.8, mix: 0.6))
        let preset = MixerPreset(name: "p14", displayName: "P14", summary: "test",
                                 chain: [template])
        let stamped = try #require(preset.freshChain().first)
        let p = stamped.resolvedBassEnhancer
        print("[measured] p14 stamped — crossoverHz \(p.crossoverHz), amount \(p.amount), "
              + "mix \(p.mix), id-changed \(stamped.id != template.id)")
        #expect(stamped.kind == .bassEnhancer)
        #expect(stamped.id != template.id, "freshChain must mint a new id")
        #expect(stamped.isBypassed, "bypass must ride along too")
        #expect(p.crossoverHz == 110)
        #expect(p.amount == 0.8)
        #expect(p.mix == 0.6)
        // Anti-vacuity: these are not the defaults, so a dropped carry reads as
        // a real difference rather than an indistinguishable no-op.
        #expect(BassEnhancerParams() != p, "the fixture must differ from defaults")
    }
}
