import Accelerate
import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

// ⚠️⚠️ ITS OWN SUITE, AND DELIBERATELY **NOT** `@MainActor`, for the reason
// `FlangerTests`, `RingModTests`, `DJFilterTests` and `BitCrusherTests` all
// record: the main actor is ONE serialization point for the whole test process,
// these tests render millions of frames of audio, and they need no main-actor
// state at all. (There is also a hard structural reason today:
// `MainActorOccupancySiteTests` Leg C pins the `@MainActor`-isolated SUITE
// count at its cap with ZERO slack, so a new isolated suite would redden a gate
// in a different target — and spelling `@MainActor` per-test to dodge that gate
// is what the gate itself names as instrument-silencing.)
//
// FIXTURE NOTE: every signal here is SYNTHESIZED in memory. Nothing reads an
// audio file, so no file-IO defect can reach these gates.

/// m39-l — the `.hallReverb` insert: an 8-line FDN, and the THIRD CALLER of
/// `InterpolatedDelayLine`. `docs/design/2026-09-19-creative-effects.md` §5 and
/// §6.2 are the contract; §12 gate 9 names the numbers this suite has to
/// produce ("measured RT60 within 10 % of `decaySeconds`; `sizeMeters` changes
/// echo density with `decaySeconds` held — the test that proves the feature
/// exists; `highDecayMultiplier 0.1` measurably shortens the HF tail").
///
/// ⭐ **Every claim is MEASURED FROM RENDERED OUTPUT, never read back from the
/// parameter**, with two deliberate exceptions that are named as such (H7b and
/// H8b) because the thing they pin is provably invisible at the output. The
/// plausible wrong implementations this suite separates:
///
///  · the tail modulation FROZEN (the anti-metallic
///    fix, absent)                                     → H6a, spectral
///    flatness of the late tail. The ONLY leg that sees it.
///  · all 8 lines sharing ONE LFO phase                → H6b, structural, and
///    it is structural ON PURPOSE — see its own comment
///  · Householder mixing replaced by IDENTITY          → H5, echo density in
///    the first 150 ms. Nothing else here can see it: an unmixed bank of 8
///    combs still decays at the right rate, still has a size, still passes
///    every absorption leg
///  · the absorption shelves ZEROED (no two-band decay) → H4
///  · the denormal flush removed, output word          → H7a
///  · the denormal flush removed, SHELF STATES         → H7b ONLY, because
///    flush (a) cleans the output and leaves the shelves grinding
///  · `mix == 0` writing the buffer                    → H1a, with H1b as its
///    positive control so "bit-exact" cannot mean "inert"
///  · the pre-delay line REFUSED at `preDelayMs: 0`    → H2a, which is the
///    silent-passthrough trap the `+1` sample floor exists to prevent
///  · a slot mis-wired in `storeAutomatedParam`        → H9
///  · a param left UNCLAMPED on the automation path    → H10, a MEMORY-SAFETY
///    pin: the delay reaches `Int()` inside the shared line's tap and that
///    line has no render-thread bounds check by design
@Suite("Hall reverb — 8-line FDN, two-band absorption, anti-metallic tail (m39-l)",
       .serialized)
struct HallReverbTests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (FlangerTests conventions)

    private func impulse(at index: Int, frames: Int) -> [Float] {
        var samples = [Float](repeating: 0, count: frames)
        samples[index] = 1
        return samples
    }

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    private func silence(frames: Int) -> [Float] { [Float](repeating: 0, count: frames) }

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

    /// Power spectrum of `count` samples starting at `start`, Hann-windowed,
    /// via vDSP. `count` MUST be a power of two.
    private func powerSpectrum(_ samples: [Float], start: Int, count: Int) -> [Double] {
        let log2n = vDSP_Length(log2(Double(count)).rounded())
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return [] }
        defer { vDSP_destroy_fftsetup(setup) }
        var windowed = [Float](repeating: 0, count: count)
        var window = [Float](repeating: 0, count: count)
        vDSP_hann_window(&window, vDSP_Length(count), Int32(vDSP_HANN_NORM))
        for index in 0..<count {
            windowed[index] = samples[start + index] * window[index]
        }
        var real = [Float](repeating: 0, count: count / 2)
        var imaginary = [Float](repeating: 0, count: count / 2)
        var magnitudes = [Float](repeating: 0, count: count / 2)
        real.withUnsafeMutableBufferPointer { realPtr in
            imaginary.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(
                        to: DSPComplex.self, capacity: count / 2
                    ) { reinterpreted in
                        vDSP_ctoz(reinterpreted, 2, &split, 1, vDSP_Length(count / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(count / 2))
            }
        }
        return magnitudes.map { Double($0) }
    }

    /// Spectral flatness (Wiener entropy) in dB over a frequency band — the
    /// geometric mean of the power spectrum divided by its arithmetic mean.
    ///
    /// ⭐ THIS IS THE ANTI-METALLIC INSTRUMENT, and the reason it is the right
    /// one: a fixed-length recirculating network rings at a fixed set of modal
    /// frequencies, so its spectrum is a picket fence of sharp peaks with deep
    /// valleys between them — geometric mean far below arithmetic mean, hence a
    /// very negative flatness. Sliding each line's length smears those modes
    /// across a band, the valleys fill in, and flatness RISES toward 0 dB. The
    /// measure sees exactly the physical thing the fix is for.
    private func spectralFlatnessDb(_ power: [Double], lowHz: Double, highHz: Double,
                                    fftSize: Int) -> Double {
        let binHz = Self.sampleRate / Double(fftSize)
        let lowBin = max(1, Int(lowHz / binHz))
        let highBin = min(power.count - 1, Int(highHz / binHz))
        guard highBin > lowBin else { return 0 }
        var logSum = 0.0
        var linearSum = 0.0
        var count = 0
        for bin in lowBin...highBin {
            let value = max(power[bin], 1e-30)
            logSum += log(value)
            linearSum += value
            count += 1
        }
        let geometric = exp(logSum / Double(count))
        let arithmetic = linearSum / Double(count)
        return 10 * log10(geometric / arithmetic)
    }

    /// Spectral CREST in dB over a band — peak bin over mean bin. The other
    /// half of the same picture: modes that stand still produce tall isolated
    /// peaks, and smearing them lowers the tallest one.
    private func spectralCrestDb(_ power: [Double], lowHz: Double, highHz: Double,
                                 fftSize: Int) -> Double {
        let binHz = Self.sampleRate / Double(fftSize)
        let lowBin = max(1, Int(lowHz / binHz))
        let highBin = min(power.count - 1, Int(highHz / binHz))
        guard highBin > lowBin else { return 0 }
        var peak = 0.0
        var linearSum = 0.0
        var count = 0
        for bin in lowBin...highBin {
            peak = max(peak, power[bin])
            linearSum += power[bin]
            count += 1
        }
        return 10 * log10(max(peak, 1e-30) / max(linearSum / Double(count), 1e-30))
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
        let frames = channels[0].count
        let buffer = try #require(AVAudioPCMBuffer(
            pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk)))
        var output = channels.map { [Float](repeating: 0, count: $0.count) }
        var position = 0
        while position < frames {
            let size = min(chunk, frames - position)
            buffer.frameLength = AVAudioFrameCount(size)
            let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            for channel in 0..<channels.count {
                guard let data = list[channel].mData?
                    .assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<size { data[index] = channels[channel][position + index] }
                list[channel].mDataByteSize =
                    UInt32(size * MemoryLayout<Float>.stride)
            }
            poke?(effect, position)
            effect.process(buffers: list, frameCount: size)
            for channel in 0..<channels.count {
                guard let data = list[channel].mData?
                    .assumingMemoryBound(to: Float.self) else { continue }
                for index in 0..<size { output[channel][position + index] = data[index] }
            }
            position += size
        }
        return output
    }

    /// Builds a prepared effect. `prepare` is nonisolated on the protocol and
    /// allocates — it is the main-actor call, made here before any render, as
    /// the contract requires.
    private func prepared(_ params: HallReverbParams,
                          channelCount: Int = 2) -> HallReverbEffect {
        let effect = HallReverbEffect(params: params)
        effect.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512,
                       channelCount: channelCount)
        return effect
    }

    /// Params tuned to isolate the TANK: full wet, late only, no diffusion, no
    /// pre-delay, no HF damping. Nothing here is a default — every leg that
    /// uses it says which axis it is moving.
    private func tankOnly(decaySeconds: Double = 2.0, sizeMeters: Double = 12,
                          modDepthMs: Double = 0, modRateHz: Double = 0.3,
                          highDecayMultiplier: Double = 1.0,
                          lowDecayMultiplier: Double = 1.0) -> HallReverbParams {
        HallReverbParams(mix: 1, decaySeconds: decaySeconds, sizeMeters: sizeMeters,
                         preDelayMs: 0, width: 1, diffusion: 0, earlyLateBalance: 1,
                         lowDecayMultiplier: lowDecayMultiplier,
                         highDecayMultiplier: highDecayMultiplier,
                         lowCrossoverHz: 200, highCrossoverHz: 6_000,
                         modRateHz: modRateHz, modDepthMs: modDepthMs, freeze: 0)
    }

    // MARK: - H0: it renders at all, and the numbers are printed

    @Test("H0 — a default hall renders a wet tail, and it is not the dry signal")
    func defaultHallProducesATail() throws {
        let frames = Int(Self.sampleRate * 1.5)
        let effect = prepared(HallReverbParams())
        let dry = impulse(at: 64, frames: frames)
        let out = try processChunked(effect, channels: [dry, dry])
        let tail = rms(out[0][Int(Self.sampleRate * 0.3)..<Int(Self.sampleRate * 1.0)])
        print("[measured] H0 default-hall tail RMS 0.3–1.0 s = \(tail)")
        #expect(tail > 1e-6, "the default hall produced no tail at all")
        // Non-vacuity: the dry impulse alone has NO energy in that window.
        let dryTail = rms(dry[Int(Self.sampleRate * 0.3)..<Int(Self.sampleRate * 1.0)])
        #expect(dryTail == 0, "control failed — the input already had late energy")
    }

    // MARK: - H1: mix == 0 is BIT-EXACT dry, and the tank keeps running

    @Test("H1a — mix 0 never writes the buffer: bit-exact dry, every sample")
    func mixZeroIsBitExactDry() throws {
        let frames = 8_192
        var params = HallReverbParams()
        params.mix = 0
        let effect = prepared(params)
        let dry = sine(220, amplitude: 0.4, frames: frames)
        let out = try processChunked(effect, channels: [dry, dry])
        #expect(out[0] == dry, "mix 0 altered the left channel")
        #expect(out[1] == dry, "mix 0 altered the right channel")
    }

    @Test("H1b — POSITIVE CONTROL: the same render at mix 1 is NOT the dry signal")
    func mixOneIsNotDry() throws {
        let frames = 8_192
        var params = HallReverbParams()
        params.mix = 1
        let effect = prepared(params)
        let dry = sine(220, amplitude: 0.4, frames: frames)
        let out = try processChunked(effect, channels: [dry, dry])
        #expect(out[0] != dry, "control failed — mix 1 produced the dry signal, so H1a is vacuous")
    }

    @Test("H1c — the tank keeps RUNNING at mix 0: raising mix later picks up a live tail")
    func mixZeroKeepsTheTankRunning() throws {
        let frames = Int(Self.sampleRate * 0.6)
        var muted = HallReverbParams()
        muted.mix = 0
        let effect = prepared(muted)
        // Half a second of signal at mix 0, then mix 1 on a SILENT input. If the
        // tank were paused there would be nothing to hear.
        let dry = sine(330, amplitude: 0.5, frames: frames) + silence(frames: frames)
        var raised = HallReverbParams()
        raised.mix = 1
        let out = try processChunked(effect, channels: [dry, dry], chunk: 512) { fx, position in
            guard position >= frames else { return }
            // slot 0 is `mix` (the frozen order) — the render-thread setter.
            fx.storeAutomatedParam(slot: 0, value: 1)
        }
        _ = raised
        let afterward = rms(out[0][(frames + 2_048)..<(frames * 2)])
        print("[measured] H1c tail RMS after raising mix on silence = \(afterward)")
        #expect(afterward > 1e-5,
                "the tank was paused while mix was 0 — raising mix found nothing")
    }

    // MARK: - H2: the pre-delay floor, and the silent-passthrough trap it prevents

    @Test("H2a — preDelayMs 0 still produces a WET tail (the +1 sample floor)")
    func preDelayZeroIsNotASilentPassthrough() throws {
        // ⛔ THE TRAP THIS LEG EXISTS FOR. `preDelayRange.lowerBound` is 0 and
        // `InterpolatedDelayLine.prepare()` refuses a declared minimum of 0 —
        // and a refused line is SILENT, not loud. Without
        // `HallReverbParams.preDelayFloorSamples` the whole effect would be a
        // permanent bit-exact passthrough here while every other leg in this
        // file, which uses a non-zero pre-delay, stayed green.
        let frames = Int(Self.sampleRate * 1.0)
        var params = HallReverbParams()
        params.preDelayMs = 0
        params.mix = 1
        let effect = prepared(params)
        let dry = impulse(at: 0, frames: frames)
        let out = try processChunked(effect, channels: [dry, dry])
        let tail = rms(out[0][2_048..<frames])
        print("[measured] H2a preDelayMs 0 tail RMS = \(tail)")
        #expect(tail > 1e-6, "preDelayMs 0 produced silence — the line refused at prepare")
        #expect(out[0] != dry, "preDelayMs 0 passed the input through unchanged")
    }

    @Test("H2b — preDelayMs MOVES the first wet arrival, measured from the render")
    func preDelayMovesTheFirstArrival() throws {
        let frames = Int(Self.sampleRate * 0.6)
        var measured: [Double] = []
        for preDelayMs in [0.0, 50.0, 150.0] {
            let params = HallReverbParams(mix: 1, decaySeconds: 2, sizeMeters: 12,
                                          preDelayMs: preDelayMs, width: 1, diffusion: 0,
                                          earlyLateBalance: 1, lowDecayMultiplier: 1,
                                          highDecayMultiplier: 1, lowCrossoverHz: 200,
                                          highCrossoverHz: 6_000, modRateHz: 0.3,
                                          modDepthMs: 0, freeze: 0)
            let effect = prepared(params)
            let out = try processChunked(effect, channels: [impulse(at: 0, frames: frames),
                                                            impulse(at: 0, frames: frames)])
            let first = out[0].firstIndex { abs($0) > 1e-5 } ?? -1
            let seconds = Double(first) / Self.sampleRate
            let expected = HallReverbParams.firstArrivalSeconds(sizeMeters: 12,
                                                                preDelayMs: preDelayMs)
            measured.append(seconds)
            print("[measured] H2b preDelayMs \(preDelayMs): first wet arrival at sample "
                  + "\(first) = \(seconds) s, closed form \(expected) s")
            #expect(abs(seconds - expected) < 0.002,
                    "first arrival \(seconds) s is not the closed form \(expected) s")
        }
        #expect(measured[0] < measured[1] && measured[1] < measured[2],
                "pre-delay did not move the first arrival monotonically")
    }

    // MARK: - H3: RT60 — `decaySeconds` means SECONDS (§12 gate 9)

    /// Schroeder backward integration, the standard method: the reverse
    /// cumulative energy curve, least-squares fitted between −5 dB and −35 dB
    /// and extrapolated to −60 (T30). A window-by-window RMS reading of the
    /// same render is dominated by modal beating and was measurably biased;
    /// this is not.
    private func schroederRT60(_ samples: [Float], from start: Int) -> Double {
        guard start < samples.count else { return -1 }
        var energy = [Double](repeating: 0, count: samples.count - start)
        var running = 0.0
        var index = samples.count - 1
        while index >= start {
            running += Double(samples[index]) * Double(samples[index])
            energy[index - start] = running
            index -= 1
        }
        let total = energy[0]
        guard total > 0 else { return -1 }
        let curve = energy.map { 10 * log10(max($0 / total, 1e-30)) }
        guard let i5 = curve.firstIndex(where: { $0 <= -5 }),
              let i35 = curve.firstIndex(where: { $0 <= -35 }), i35 > i5 else { return -1 }
        var sumX = 0.0, sumY = 0.0, sumXX = 0.0, sumXY = 0.0, count = 0.0
        var i = i5
        while i <= i35 {
            let x = Double(i) / Self.sampleRate
            let y = curve[i]
            sumX += x; sumY += y; sumXX += x * x; sumXY += x * y; count += 1
            i += 16
        }
        let slope = (count * sumXY - sumX * sumY) / (count * sumXX - sumX * sumX)
        return slope < 0 ? -60.0 / slope : -1
    }

    @Test("H3 — measured RT60 is within 10 % of decaySeconds across the range")
    func rt60MatchesDecaySeconds() throws {
        for decay in [0.5, 1.0, 2.0, 4.0] {
            let frames = Int(Self.sampleRate * (decay * 1.3 + 0.5))
            let effect = prepared(tankOnly(decaySeconds: decay))
            let dry = impulse(at: 64, frames: frames)
            let out = try processChunked(effect, channels: [dry, dry])
            let measured = schroederRT60(out[0], from: 1_500)
            let ratio = measured / decay
            print("[measured] H3 decaySeconds \(decay) → Schroeder RT60 \(measured) s "
                  + "(ratio \(ratio))")
            #expect(ratio > 0.88 && ratio < 1.12,
                    "RT60 for decaySeconds \(decay) measured \(measured) s, ratio \(ratio)")
        }
    }

    @Test("H3b — RT60 is a real TIME, not a feedback number: doubling decay doubles it")
    func rt60ScalesWithTheParameter() throws {
        var results: [Double] = []
        for decay in [1.0, 2.0, 4.0] {
            let frames = Int(Self.sampleRate * (decay * 1.3 + 0.5))
            let effect = prepared(tankOnly(decaySeconds: decay))
            let dry = impulse(at: 64, frames: frames)
            let out = try processChunked(effect, channels: [dry, dry])
            results.append(schroederRT60(out[0], from: 1_500))
        }
        print("[measured] H3b RT60 ladder = \(results)")
        #expect(results[1] / results[0] > 1.8 && results[1] / results[0] < 2.2)
        #expect(results[2] / results[1] > 1.8 && results[2] / results[1] < 2.2)
    }

    // MARK: - H4: two-band absorption (§12 gate 9)

    @Test("H4a — highDecayMultiplier 0.1 measurably shortens the HF tail")
    func highDecayMultiplierShortensTheTop() throws {
        let frames = Int(Self.sampleRate * 3.0)
        var levels: [Double] = []
        for multiplier in [1.0, 0.5, 0.1] {
            let effect = prepared(tankOnly(decaySeconds: 4, highDecayMultiplier: multiplier))
            let dry = impulse(at: 64, frames: frames)
            let out = try processChunked(effect, channels: [dry, dry])
            let late = Int(Self.sampleRate * 1.0)..<Int(Self.sampleRate * 2.0)
            let high = goertzel(out[0], frequency: 8_000, in: late)
            let mid = goertzel(out[0], frequency: 1_000, in: late)
            let ratio = dB(high / max(mid, 1e-30))
            levels.append(ratio)
            print("[measured] H4a highDecayMultiplier \(multiplier): 8 kHz − 1 kHz "
                  + "in the 1–2 s tail = \(ratio) dB")
        }
        // Strictly monotonic and a LARGE separation: the parameter is doing the
        // work, not a rounding difference.
        #expect(levels[0] > levels[1], "0.5 did not damp more than 1.0")
        #expect(levels[1] > levels[2], "0.1 did not damp more than 0.5")
        #expect(levels[0] - levels[2] > 20,
                "0.1 vs 1.0 separated by only \(levels[0] - levels[2]) dB")
    }

    @Test("H4b — lowDecayMultiplier moves the BASS tail, in both directions")
    func lowDecayMultiplierMovesTheBottom() throws {
        let frames = Int(Self.sampleRate * 3.0)
        var levels: [Double] = []
        for multiplier in [4.0, 1.0, 0.25] {
            let effect = prepared(tankOnly(decaySeconds: 4, lowDecayMultiplier: multiplier))
            let dry = impulse(at: 64, frames: frames)
            let out = try processChunked(effect, channels: [dry, dry])
            let late = Int(Self.sampleRate * 1.0)..<Int(Self.sampleRate * 2.0)
            let low = goertzel(out[0], frequency: 80, in: late)
            let mid = goertzel(out[0], frequency: 1_000, in: late)
            let ratio = dB(low / max(mid, 1e-30))
            levels.append(ratio)
            print("[measured] H4b lowDecayMultiplier \(multiplier): 80 Hz − 1 kHz "
                  + "in the 1–2 s tail = \(ratio) dB")
        }
        #expect(levels[0] > levels[1], "4.0 did not hold the bass longer than 1.0")
        #expect(levels[1] > levels[2], "1.0 did not hold the bass longer than 0.25")
        #expect(levels[0] - levels[2] > 20,
                "4.0 vs 0.25 separated by only \(levels[0] - levels[2]) dB")
    }

    // MARK: - H5: `sizeMeters` is a real size, and Householder mixing is real

    @Test("H5a — sizeMeters moves the first arrival and the echo spacing, decay HELD")
    func sizeMovesTheRoomNotTheDecay() throws {
        let frames = Int(Self.sampleRate * 0.5)
        var arrivals: [Int] = []
        for size in [12.0, 24.0, 48.0] {
            let effect = prepared(tankOnly(decaySeconds: 2, sizeMeters: size))
            let dry = impulse(at: 0, frames: frames)
            let out = try processChunked(effect, channels: [dry, dry])
            let first = out[0].firstIndex { abs($0) > 1e-5 } ?? -1
            arrivals.append(first)
            let expected = HallReverbParams.firstArrivalSeconds(sizeMeters: size,
                                                                preDelayMs: 0)
            print("[measured] H5a sizeMeters \(size): first arrival sample \(first) "
                  + "(closed form \(expected * Self.sampleRate))")
        }
        // The pre-delay floor is ONE sample, so doubling size doubles the
        // arrival to within a sample. THE TEST THAT PROVES THE FEATURE EXISTS:
        // `.reverb` cannot do this at all, at any setting.
        let a = Double(arrivals[0] - 1), b = Double(arrivals[1] - 1), c = Double(arrivals[2] - 1)
        #expect(abs(b / a - 2) < 0.02, "12→24 m gave a ratio of \(b / a), not 2")
        #expect(abs(c / b - 2) < 0.02, "24→48 m gave a ratio of \(c / b), not 2")
    }

    @Test("H5b — Householder mixing: the tail is a WASH, not 8 independent combs")
    func householderMixingBuildsDensity() throws {
        // ⛔ THE LEG FOR IDENTITY MIXING, AND IT IS THE SECOND ONE WRITTEN.
        // Replace `y_i = t_i − (2/N)Σt` with `y_i = t_i` and you have eight
        // INDEPENDENT comb filters: each still decays at its own RT60, still
        // scales with `sizeMeters`, still absorbs per band — H3, H4 and H5a all
        // stay green — but the echoes never cross between lines, so the tail
        // stays a sparse superposition of eight periodic pulse trains instead
        // of building into a wash.
        //
        // ⚠️ TWO MEASURES THAT DID NOT WORK ARE RECORDED HERE SO THEY ARE NOT
        // RE-TRIED. (1) Counting samples above 2 % of peak in the first 150 ms:
        // MEASURED 297 with mixing and 152 without — the first draft's
        // threshold of 120 passed BOTH, so the plant survived its own test.
        // (2) Autocorrelation at the eight line lags, which should be huge for
        // a pure comb: MEASURED 0.180 with mixing and 0.191 without. No
        // separation at all. What DOES separate, measured on the same renders,
        // is how much of a LATE window is occupied.
        let frames = Int(Self.sampleRate * 0.6)
        let effect = prepared(tankOnly(decaySeconds: 3, sizeMeters: 12))
        let dry = impulse(at: 0, frames: frames)
        let out = try processChunked(effect, channels: [dry, dry])
        let first = Int(Self.sampleRate * 0.30)
        let last = Int(Self.sampleRate * 0.50)
        let window = Array(out[0][first..<last])
        let peak = window.map { abs($0) }.max() ?? 1
        let occupancy = Double(window.filter { abs($0) > peak * 0.05 }.count)
            / Double(window.count)
        let crest = dB(Double(peak) / max(rms(out[0][first..<last]), 1e-30))
        print("[measured] H5b 0.30–0.50 s window — occupancy above 5 % of peak "
              + "\(occupancy), crest \(crest) dB")
        // MEASURED: occupancy 0.0550 mixed vs 0.0202 unmixed (2.7×);
        // crest 23.73 dB mixed vs 28.17 dB unmixed. Thresholds sit between,
        // with ~57 % and ~2.3 dB of margin on each side.
        #expect(occupancy > 0.035, """
                only \(occupancy) of the late window is occupied — the network is not \
                cross-mixing
                """)
        #expect(crest < 26.0,
                "crest \(crest) dB — the tail is isolated pulses, not a wash")
    }

    // MARK: - H6: THE ANTI-METALLIC CLAIM, MEASURED

    @Test("H6a — tail modulation RAISES spectral flatness: the anti-metallic fix, measured")
    func tailModulationRemovesTheRinging() throws {
        // ⭐ THE HEADLINE MEASUREMENT. A fixed-length recirculating network rings
        // at a fixed set of modal frequencies — a picket fence of sharp spectral
        // peaks with deep valleys between them, which the ear reports as a
        // metallic, pitched tail. Sliding each line's length independently
        // smears those modes and fills the valleys in. Spectral FLATNESS (the
        // geometric mean of the power spectrum over its arithmetic mean) sees
        // exactly that and nothing else: it is scale-free, so it cannot be
        // fooled by a level change, and this leg asserts the tail LEVEL is
        // unchanged as its own control.
        let fftSize = 131_072
        let startSeconds = 1.0
        let seconds = startSeconds + Double(fftSize) / Self.sampleRate + 0.1
        let frames = Int(Self.sampleRate * seconds)
        var flatness: [Double] = []
        var crest: [Double] = []
        var tailLevel: [Double] = []
        for depth in [0.0, 0.15, 1.0] {
            let effect = prepared(tankOnly(decaySeconds: 8, sizeMeters: 12,
                                           modDepthMs: depth, modRateHz: 0.3))
            let dry = impulse(at: 64, frames: frames)
            let out = try processChunked(effect, channels: [dry, dry])
            let power = powerSpectrum(out[0], start: Int(Self.sampleRate * startSeconds),
                                      count: fftSize)
            let f = spectralFlatnessDb(power, lowHz: 500, highHz: 6_000, fftSize: fftSize)
            let c = spectralCrestDb(power, lowHz: 500, highHz: 6_000, fftSize: fftSize)
            let level = rms(out[0][Int(Self.sampleRate * 1.0)..<Int(Self.sampleRate * 2.0)])
            flatness.append(f)
            crest.append(c)
            tailLevel.append(level)
            print("[measured] H6a modDepthMs \(depth) @ 0.3 Hz — spectral flatness "
                  + "\(f) dB, crest \(c) dB, tail RMS \(level)")
        }
        // The DEFAULT depth (0.15 ms) must do the job, not just a heroic one.
        let gainAtDefault = flatness[1] - flatness[0]
        print("[measured] H6a ⭐ flatness gain at the DEFAULT 0.15 ms depth = "
              + "\(gainAtDefault) dB; at 1.0 ms = \(flatness[2] - flatness[0]) dB")
        #expect(flatness[0] < -25,
                """
                unmodulated flatness \(flatness[0]) dB is already smooth — the \
                instrument cannot show an improvement it has no room for
                """)
        #expect(gainAtDefault > 12,
                "the default modulation depth raised flatness by only \(gainAtDefault) dB")
        #expect(flatness[2] > flatness[1], "1.0 ms did not smear more than 0.15 ms")
        #expect(crest[0] > crest[2], "the tallest mode did not come down with modulation")
        // CONTROL: this is not a level effect. If the tail got quieter, flatness
        // would be measuring loudness, not ringing.
        let levelChangeDb = dB(tailLevel[1] / tailLevel[0])
        print("[measured] H6a control — tail level change at default depth = "
              + "\(levelChangeDb) dB")
        #expect(abs(levelChangeDb) < 1.0,
                "the tail level moved \(levelChangeDb) dB, so flatness may be reading level")
    }

    @Test("H6b — the 8 LFO phases are INDEPENDENT, and no output measure sees this")
    func modulationPhasesAreIndependent() throws {
        // ⚠️ STRUCTURAL ON PURPOSE, AND SAID SO RATHER THAN DRESSED UP. Eight
        // lines sharing ONE phase still smear the modes — common-mode drift is
        // still drift — so H6a's flatness stays green under that defect. What
        // the shared phase loses is the DECORRELATION between lines: all eight
        // pitch-wobble together, which is a chorus on the whole tank instead of
        // air. The honest instrument for that is the phase set itself.
        let effect = prepared(HallReverbParams())
        let phases = effect.internalModulationPhases
        #expect(phases.count == HallReverbParams.lineCount)
        let sorted = phases.sorted()
        var minimumGap = Double.greatestFiniteMagnitude
        for index in 1..<sorted.count { minimumGap = min(minimumGap, sorted[index] - sorted[index - 1]) }
        print("[measured] H6b phases = \(phases.map { ($0 * 100).rounded() / 100 }), "
              + "minimum gap \(minimumGap) rad")
        #expect(Set(phases).count == HallReverbParams.lineCount,
                "two lines share an LFO phase")
        #expect(minimumGap > 0.3,
                "the closest two phases are only \(minimumGap) rad apart")
        // ⚠️ AN ASSERTION THAT WAS HERE AND IS DELIBERATELY GONE, recorded so it
        // is not re-added: the first draft also demanded no pair be within
        // 0.2 rad of ANTIPHASE, on the theory that antiphase re-couples a pair.
        // It FAILED (four pairs sit 0.175 rad from π) and the theory was wrong —
        // two lines drifting in opposition are maximally decorrelated, which is
        // the goal. The defect this leg exists for is all eight sharing ONE
        // phase, and distinctness plus a minimum gap is exactly that.
        //
        // The phases must also be STABLE across a reset, or a stop/start would
        // re-roll the network's character.
        effect.reset()
        #expect(effect.internalModulationPhases == phases,
                "reset() changed the phase spread")
    }

    // MARK: - H7: denormals — THREE recirculating words, and one is invisible

    @Test("H7a — no OUTPUT sample is subnormal after the tail decays into silence")
    func outputCarriesNoSubnormals() throws {
        // ⚠️ `decaySeconds: 0.1`, THE MINIMUM, AND 5 s OF SILENCE — BOTH NUMBERS
        // ARE MEASURED REQUIREMENTS, NOT ROUND ONES. The first draft used
        // `decaySeconds: 0.5` and 3 s, and it PASSED WITH THE FLUSH REMOVED:
        // at 120 dB/s the tank only reaches ~1.2e-24 in that time, which is
        // fourteen orders of magnitude ABOVE the subnormal boundary
        // (1.18e-38), so there was nothing to detect and "zero subnormals"
        // meant "zero samples in range". At 0.1 s the decay is ~600 dB/s and
        // the tank crosses into subnormal territory after about 1.3 s.
        // MEASURED with the flush removed under these settings: 13 225
        // subnormal output samples, minimum |value| 1e-45 — the smallest
        // Float32 there is.
        let signalFrames = Int(Self.sampleRate * 0.25)
        let silentFrames = Int(Self.sampleRate * 5.0)
        let effect = prepared(tankOnly(decaySeconds: 0.1, sizeMeters: 12))
        let dry = sine(440, amplitude: 0.5, frames: signalFrames)
            + silence(frames: silentFrames)
        let out = try processChunked(effect, channels: [dry, dry])
        var subnormals = 0
        var nonZero = 0
        for channel in out {
            for value in channel[signalFrames...] {
                if value != 0 && abs(value) < Float.leastNormalMagnitude { subnormals += 1 }
                if value != 0 { nonZero += 1 }
            }
        }
        print("[measured] H7a subnormal output samples = \(subnormals), non-zero = \(nonZero)")
        #expect(subnormals == 0, "\(subnormals) subnormal samples reached the output")
        // NON-VACUITY: the window must actually contain a decaying tail, or
        // "no subnormals" is just "no samples".
        #expect(nonZero > 10_000,
                "only \(nonZero) non-zero samples in the tail — the leg is vacuous")
    }

    @Test("H7b — no SHELF STATE is subnormal either, which H7a provably cannot see")
    func shelfStatesCarryNoSubnormals() throws {
        // ⛔ THE LEG THAT EXISTS BECAUSE THE OBVIOUS ONE IS BLIND. Flush (a) cuts
        // the tapped value, so the OUTPUT is clean whatever the shelves are
        // doing. Remove flush (b) alone and H7a stays green while sixteen
        // subnormal one-pole states grind through every sample of silence, at
        // the orders-of-magnitude penalty subnormal arithmetic carries, on the
        // render thread, during silence — which is exactly when nobody looks.
        let signalFrames = Int(Self.sampleRate * 0.25)
        let silentFrames = Int(Self.sampleRate * 4.0)
        let effect = prepared(tankOnly(decaySeconds: 0.4, sizeMeters: 12,
                                       highDecayMultiplier: 0.5, lowDecayMultiplier: 0.5))
        let dry = sine(440, amplitude: 0.5, frames: signalFrames)
            + silence(frames: silentFrames)
        _ = try processChunked(effect, channels: [dry, dry])
        let magnitudes = effect.internalShelfStateMagnitudes
        let subnormal = magnitudes.filter { $0 != 0 && $0 < Float.leastNormalMagnitude }
        print("[measured] H7b shelf state magnitudes = \(magnitudes), "
              + "subnormal count \(subnormal.count)")
        #expect(magnitudes.count == HallReverbParams.lineCount * 2)
        #expect(subnormal.isEmpty,
                "\(subnormal.count) shelf states are subnormal: \(subnormal)")
    }

    @Test("H7d — no DIFFUSER state is subnormal, sampled WHILE the decay passes through")
    func diffuserStatesCarryNoSubnormals() throws {
        // ⛔ THE THIRD FLUSH SITE, AND IT WAS UNPINNED UNTIL A PLANT SAID SO.
        // Removing flush (c) reddened NOTHING — not H7a (the output), not H7b
        // (the shelves) — and that is a finding rather than a reassurance: the
        // header claims three flushed words and only two of them had a gate.
        //
        // ⚠️ WHY THE OBVIOUS SHAPE FAILS HERE. H7b reads the shelf state ONCE
        // at the end of the silence, which works because a one-pole fed by a
        // decaying tank settles into subnormals and STAYS there. A Schroeder
        // allpass does not: it decays by its coefficient (0.7) once per loop
        // length, so it crosses the whole subnormal band — 1.18e-38 down to
        // 1e-45, about 25 loops — in roughly a quarter of a second and is
        // exactly zero after that. A single read at the end of a 5 s silence
        // sees 0 and passes. This samples every 512-frame quantum across the
        // whole decay instead, which is the only instrument that can see a
        // transient state defect.
        let signalFrames = Int(Self.sampleRate * 0.25)
        let silentFrames = Int(Self.sampleRate * 6.0)
        let effect = prepared(tankOnly(decaySeconds: 0.1, sizeMeters: 12))
        let dry = sine(440, amplitude: 0.5, frames: signalFrames)
            + silence(frames: silentFrames)
        var subnormalWords = 0
        var samplesTaken = 0
        var smallestNonZero = Float.greatestFiniteMagnitude
        _ = try processChunked(effect, channels: [dry, dry], poke: { instance, position in
            guard position >= signalFrames, let hall = instance as? HallReverbEffect else { return }
            samplesTaken += 1
            for magnitude in hall.internalDiffuserStateMagnitudes where magnitude != 0 {
                if magnitude < Float.leastNormalMagnitude { subnormalWords += 1 }
                smallestNonZero = min(smallestNonZero, magnitude)
            }
        })
        print("""
              [measured] H7d diffuser state: \(subnormalWords) subnormal words over \
              \(samplesTaken) quantum boundaries, smallest non-zero \(smallestNonZero)
              """)
        // NON-VACUITY FIRST: the sampler must have run, and the store must be
        // the real one, or "zero subnormals" is "zero reads".
        #expect(samplesTaken > 500, "only \(samplesTaken) state reads — the poke never fired")
        #expect(effect.internalDiffuserStateMagnitudes.count > 1_000, """
                the diffuser store is \(effect.internalDiffuserStateMagnitudes.count) words, \
                which is not the prepared tank
                """)
        #expect(subnormalWords == 0,
                "\(subnormalWords) diffuser words were subnormal, smallest \(smallestNonZero)")
    }

    @Test("H7c — POSITIVE CONTROL: a subnormal Float IS detected by these predicates")
    func subnormalDetectionWorks() {
        // A predicate that has never fired is indistinguishable from one that
        // cannot. `1e-40` is subnormal for Float32 (the boundary is ~1.18e-38).
        let planted: Float = 1e-40
        #expect(planted != 0, """
                1e-40 flushed to zero — this machine is in FTZ mode and H7a/H7b cannot fail
                """)
        #expect(abs(planted) < Float.leastNormalMagnitude,
                "the subnormal predicate does not recognise a subnormal")
    }

    // MARK: - H8: freeze holds, and does not grow

    @Test("H8 — freeze holds the tail flat for 15 s and never grows (Hermite stability)")
    func freezeHoldsWithoutGrowing() throws {
        // ⚠️ THIS IS ALSO THE STABILITY PIN FOR `.cubicHermite`, which is not a
        // passive interpolator and here sits in a feedback loop at UNITY gain.
        // Worst case on purpose: the SHORTEST lines (`sizeMeters: 1`), i.e. the
        // most recirculations per second any setting can produce.
        let signalFrames = Int(Self.sampleRate * 0.5)
        let holdFrames = Int(Self.sampleRate * 16.0)
        let params = HallReverbParams(mix: 1, decaySeconds: 20, sizeMeters: 1,
                                      preDelayMs: 0, width: 1, diffusion: 0.7,
                                      earlyLateBalance: 1, lowDecayMultiplier: 4,
                                      highDecayMultiplier: 1, lowCrossoverHz: 200,
                                      highCrossoverHz: 6_000, modRateHz: 0.3,
                                      modDepthMs: 0.15, freeze: 1)
        let effect = prepared(params)
        let dry = sine(440, amplitude: 0.5, frames: signalFrames) + silence(frames: holdFrames)
        let out = try processChunked(effect, channels: [dry, dry])
        let early = rms(out[0][Int(Self.sampleRate * 1.0)..<Int(Self.sampleRate * 2.0)])
        let late = rms(out[0][Int(Self.sampleRate * 15.0)..<Int(Self.sampleRate * 16.0)])
        let growth = dB(late / max(early, 1e-30))
        print("[measured] H8 freeze: early RMS \(early), late RMS \(late), "
              + "growth \(growth) dB over 14 s")
        #expect(early > 1e-4, "freeze held nothing — the leg is vacuous")
        #expect(growth < 1.0, "the frozen tank GREW by \(growth) dB — unstable")
        #expect(growth > -6.0, "the frozen tank lost \(growth) dB — it is not holding")
        #expect(out[0].allSatisfy { $0.isFinite }, "the frozen tank produced a non-finite sample")
    }

    // MARK: - H9/H10: the automation surface

    @Test("H9 — every automation slot reaches its OWN parameter (order is frozen)")
    func automationSlotsAreWiredToTheRightParams() throws {
        let names = EffectParamSpec.specs(for: .hallReverb).map(\.name)
        #expect(names.count == 14)
        // Slot 0 is `mix`, and it is the one slot whose effect is unmistakable
        // from the output: driving it to 0 makes the render bit-exact dry.
        let frames = 8_192
        var params = HallReverbParams()
        params.mix = 1
        let effect = prepared(params)
        let dry = sine(220, amplitude: 0.4, frames: frames)
        let out = try processChunked(effect, channels: [dry, dry], chunk: 512) { fx, _ in
            fx.storeAutomatedParam(slot: 0, value: 0)
        }
        #expect(out[0] == dry, "slot 0 is not `mix` — driving it to 0 was not bit-exact dry")
        // And an OUT-OF-RANGE slot is inert rather than mis-assigned.
        let effect2 = prepared(params)
        let out2 = try processChunked(effect2, channels: [dry, dry], chunk: 512) { fx, _ in
            fx.storeAutomatedParam(slot: 14, value: 0)
            fx.storeAutomatedParam(slot: -1, value: 0)
        }
        #expect(out2[0] != dry, "an out-of-range slot silenced the effect")
    }

    @Test("H10 — MEMORY SAFETY: an unclamped automated size/depth cannot reach the tap")
    func automationValuesAreReClamped() throws {
        // A field-by-field overlay poke bypasses `HallReverbParams.init`, so the
        // clamping the init does is NOT in force on this path. `sizeMeters` and
        // `modDepthMs` sum into a delay that reaches `Int(delay)` inside
        // `InterpolatedDelayLine.tap`, and that line has NO render-thread bounds
        // check by design (§4.1): an unclamped 600 m would read off the end of a
        // 0.256 s line. This leg runs the whole surface out of range and asserts
        // the render is finite and bounded — a failure here is a CRASH, not a
        // wrong number, which is why it is a test and not a comment.
        let frames = 16_384
        let effect = prepared(HallReverbParams(mix: 1))
        let dry = sine(220, amplitude: 0.4, frames: frames)
        let out = try processChunked(effect, channels: [dry, dry], chunk: 512) { fx, position in
            let absurd: Double = position % 1_024 == 0 ? 1e9 : -1e9
            for slot in 0...13 { fx.storeAutomatedParam(slot: slot, value: absurd) }
            // Non-finite values must be INERT, never stored: `Int(Double.nan)` traps.
            for slot in 0...13 {
                fx.storeAutomatedParam(slot: slot, value: .nan)
                fx.storeAutomatedParam(slot: slot, value: .infinity)
            }
        }
        #expect(out[0].allSatisfy { $0.isFinite },
                "an out-of-range automation value produced a non-finite sample")
        #expect(out[0].allSatisfy { abs($0) < 100 },
                "an out-of-range automation value produced an unbounded sample")
    }

    // MARK: - H11: latency, and the render path allocates NOTHING

    @Test("H11 — latencySamples is 0: preDelayMs is signal the user asked for")
    func latencyIsZero() {
        for preDelayMs in [0.0, 120.0, 250.0] {
            var params = HallReverbParams()
            params.preDelayMs = preDelayMs
            #expect(prepared(params).latencySamples == 0)
        }
    }

    // The hook, the counter cells and the process-wide window lock live in
    // `Support/MallocProbe.swift` (m39-test-mallocprobe): one measurement at a time.

    @Test("H12 — process() allocates NOTHING across 2 000 quanta, and it actually ran")
    func processIsAllocationFree() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("""
                malloc_logger is unavailable — the allocation probe cannot run. \
                FAILURE, not a skip.
                """)
            return
        }
        let quantum = 512
        let calls = 2_000
        // Everything switched ON and MOVING: automation stores every quantum, a
        // non-zero mix, modulation running, both shelves doing work.
        let effect = prepared(HallReverbParams(mix: 0.5, decaySeconds: 4, sizeMeters: 20,
                                               preDelayMs: 30, width: 1.1, diffusion: 0.8,
                                               earlyLateBalance: 0.2,
                                               lowDecayMultiplier: 2,
                                               highDecayMultiplier: 0.3,
                                               lowCrossoverHz: 300,
                                               highCrossoverHz: 4_000, modRateHz: 1.5,
                                               modDepthMs: 0.5, freeze: 0))
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate,
                                                channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format,
                                                   frameCapacity: AVAudioFrameCount(quantum)))
        buffer.frameLength = AVAudioFrameCount(quantum)
        let list = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        for channel in 0..<2 {
            guard let data = list[channel].mData?
                .assumingMemoryBound(to: Float.self) else { continue }
            for index in 0..<quantum {
                data[index] = Float(sin(2.0 * .pi * 220.0 * Double(index) / Self.sampleRate))
            }
        }
        // Warm every lazy path BEFORE the probe arms: the first call adopts the
        // snapshot and derives, which is where a one-time allocation would hide.
        effect.process(buffers: list, frameCount: quantum)
        effect.storeAutomatedParam(slot: 2, value: 25)

        let events = MallocProbe.events(slot: slot) {
            var call = 0
            while call < calls {
                effect.storeAutomatedParam(slot: 2, value: 12 + Double(call % 30))
                effect.process(buffers: list, frameCount: quantum)
                call += 1
            }
        }
        print("[measured] H12 malloc/free events across \(calls) quanta = \(events)")
        #expect(events == 0, "process() raised \(events) malloc/free events")
    }

    @Test("H12b — POSITIVE CONTROL: the malloc probe can actually count")
    func mallocProbeCounts() throws {
        guard let slot = MallocProbe.slot() else {
            Issue.record("malloc_logger is unavailable — FAILURE, not a skip.")
            return
        }
        let events = MallocProbe.events(slot: slot) {
            var sink = 0
            for _ in 0..<200 {
                let scratch = [Int](repeating: 1, count: 64)
                sink &+= scratch.count
            }
            _ = sink
        }
        print("[measured] H12b control — probe counted \(events) events on 200 allocations")
        #expect(events > 0, "the malloc probe counted \(events) events on 200 allocations")
    }

    // MARK: - H13: stereo, width, and mono fold-down

    @Test("H13 — width 0 makes the wet MONO; width 1 does not")
    func widthControlsTheWetImage() throws {
        let frames = Int(Self.sampleRate * 1.0)
        var differences: [Double] = []
        for width in [0.0, 1.0] {
            let params = HallReverbParams(mix: 1, decaySeconds: 2, sizeMeters: 12,
                                          preDelayMs: 20, width: width, diffusion: 0.7,
                                          earlyLateBalance: 0, lowDecayMultiplier: 1,
                                          highDecayMultiplier: 0.5, lowCrossoverHz: 200,
                                          highCrossoverHz: 6_000, modRateHz: 0.3,
                                          modDepthMs: 0.15, freeze: 0)
            let effect = prepared(params)
            let dry = impulse(at: 64, frames: frames)
            let out = try processChunked(effect, channels: [dry, dry])
            var difference = 0.0
            for index in 0..<frames {
                difference += Double(out[0][index] - out[1][index])
                    * Double(out[0][index] - out[1][index])
            }
            differences.append((difference / Double(frames)).squareRoot())
            print("[measured] H13 width \(width): L−R RMS = \(differences.last!)")
        }
        #expect(differences[0] < 1e-9,
                "width 0 left the wet in stereo (L−R RMS \(differences[0]))")
        #expect(differences[1] > 1e-5, """
                width 1 produced a mono wet signal — the two output vectors are not orthogonal
                """)
    }

    // MARK: - H15: determinism (§12 gate 8)

    @Test("H15 — two renders from the same start are BIT-IDENTICAL, and reset() is total")
    func rendersAreDeterministic() throws {
        // Eight LFOs, sixteen filter states, nine delay lines and a freeze
        // ramp: a single piece of state that `reset()` forgets makes the second
        // render differ, and on a reverb tail that reads as "it sounds slightly
        // different each time" rather than as a bug anyone can point at.
        let frames = Int(Self.sampleRate * 1.0)
        let params = HallReverbParams(mix: 0.7, decaySeconds: 3, sizeMeters: 20,
                                      preDelayMs: 35, width: 1.1, diffusion: 0.8,
                                      earlyLateBalance: -0.3, lowDecayMultiplier: 2,
                                      highDecayMultiplier: 0.3, lowCrossoverHz: 300,
                                      highCrossoverHz: 4_000, modRateHz: 1.2,
                                      modDepthMs: 0.8, freeze: 0)
        let dry = sine(330, amplitude: 0.5, frames: frames)
        let first = try processChunked(prepared(params), channels: [dry, dry])

        // (a) a FRESH instance must match.
        let second = try processChunked(prepared(params), channels: [dry, dry])
        #expect(first == second, "two fresh instances rendered differently")

        // (b) and so must a REUSED one that has been reset — the harder case,
        // because it is the one that catches state `reset()` forgets.
        let reused = prepared(params)
        _ = try processChunked(reused, channels: [dry, dry])
        reused.reset()
        let third = try processChunked(reused, channels: [dry, dry])
        #expect(first == third, "reset() did not clear everything the first render left")

        // POSITIVE CONTROL: the comparison can fail. One parameter moved by a
        // hair must change the bytes, or "bit-identical" means "cannot differ".
        var perturbed = params
        perturbed.sizeMeters = 20.0001
        let fourth = try processChunked(prepared(perturbed), channels: [dry, dry])
        #expect(first != fourth,
                "a 0.1 mm size change produced an identical render — the comparison is broken")
    }

    // MARK: - H14: the pre-delay line's interpolation floor is the one that matters

    @Test("H14 — the tank lines clear cubicHermite's 2-sample floor at every rate")
    func tankLinesClearTheHermiteStencilFloor() {
        // §4.1's addendum: `.cubicHermite` reads one sample NEWER than the tap,
        // so its floor is 2, not the table's flat 1. The tank's declared minimum
        // is the shortest line at `sizeMeters: 1`. This asserts the margin
        // rather than trusting it, at every rate CoreAudio actually delivers.
        for rate in [44_100.0, 48_000.0, 88_200.0, 96_000.0] {
            let floor = HallReverbParams.minimumLineDelaySamples(sampleRate: rate)
            print("[measured] H14 minimum tank delay at \(rate) Hz = \(floor) samples")
            #expect(floor >= 2,
                    "at \(rate) Hz the tank floor is \(floor) samples, below Hermite's 2")
        }
        // And the pre-delay's floor is exactly 1, which is why THAT line is
        // `.linear`: Hermite would refuse it.
        #expect(HallReverbParams.preDelayFloorSamples == 1)
        #expect(InterpolatedDelayLine.Interpolation.cubicHermite.minimumSupportedDelaySamples == 2)
        #expect(InterpolatedDelayLine.Interpolation.linear.minimumSupportedDelaySamples == 1)
    }

    // MARK: - H16: the FACTORY SEAM, which nothing else in this file reaches

    /// ⭐ `EffectFactory.makeInstance` and `EffectFactory.applyParams` are the
    /// ONLY path a descriptor takes to become audio in the live and offline
    /// graphs alike, and both are hand-written `switch` arms ending in an
    /// optional cast: `(instance as? HallReverbEffect)?.apply(params:)`. A
    /// copy-pasted arm that names the wrong type, or the wrong `resolvedX`
    /// accessor, compiles, runs, returns normally — and does NOTHING. Every
    /// other test in this file constructs `HallReverbEffect` directly and so
    /// cannot see that at all; a setter's return is not proof it took.
    ///
    /// The discriminator is which render the factory path MATCHES. If
    /// `applyParams` were inert, the instance would keep the params it was
    /// CONSTRUCTED with, and the second leg would match `renderA` instead of
    /// `renderB` — so the two `#expect`s below fail in opposite directions and
    /// one of them must catch a dead arm.
    ///
    /// ⚠️ `MainActor.run` rather than an `@MainActor` annotation on this suite:
    /// `EffectFactory` is main-actor-isolated, but the main-actor SUITE census
    /// (`MainActorOccupancySiteTests`) is at its cap, and a DSP suite over
    /// plain nonisolated types must not spend a slot to call one factory.
    @Test("H16 — EffectFactory make/applyParams actually reach the DSP")
    func factorySeamCarriesTheParams() async throws {
        let frames = Int(Self.sampleRate * 0.5)
        let dry = impulse(at: 64, frames: frames)

        let paramsA = HallReverbParams(mix: 0.5, decaySeconds: 1.2, sizeMeters: 6,
                                       preDelayMs: 5, width: 1, diffusion: 0.6,
                                       earlyLateBalance: 0, lowDecayMultiplier: 1,
                                       highDecayMultiplier: 0.5, lowCrossoverHz: 200,
                                       highCrossoverHz: 6_000, modRateHz: 0.3,
                                       modDepthMs: 0.15, freeze: 0)
        var paramsB = paramsA
        paramsB.sizeMeters = 45
        paramsB.decaySeconds = 7
        paramsB.highDecayMultiplier = 0.9

        let descriptorA = EffectDescriptor(kind: .hallReverb, hallReverb: paramsA)
        let descriptorB = EffectDescriptor(kind: .hallReverb, hallReverb: paramsB)

        // Leg 1 — `makeInstance` builds the real type AND carries the params.
        // ⚠️ The cast happens INSIDE the hop because `any EffectRendering` is
        // not `Sendable`; `HallReverbEffect` is (`@unchecked`), and a nil here
        // IS the "factory built the wrong type" failure.
        let madeA = try #require(await MainActor.run {
            EffectFactory.makeInstance(for: descriptorA) as? HallReverbEffect
        }, "the factory did not build a HallReverbEffect")
        madeA.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let renderMadeA = try processChunked(madeA, channels: [dry, dry])
        let renderA = try processChunked(prepared(paramsA), channels: [dry, dry])
        #expect(renderMadeA == renderA, """
                makeInstance produced a different render from the same params — \
                the arm is building the wrong thing or dropping the descriptor
                """)

        // Leg 2 — `applyParams` overwrites them on an EXISTING instance. The
        // apply lands before `prepare`, so there is no smoothing ramp to
        // confound the comparison: this asks whether the value ARRIVED.
        let applied = try #require(await MainActor.run { () -> HallReverbEffect? in
            let instance = EffectFactory.makeInstance(for: descriptorA)
            EffectFactory.applyParams(descriptorB, to: instance)
            return instance as? HallReverbEffect
        })
        applied.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let renderApplied = try processChunked(applied, channels: [dry, dry])
        let renderB = try processChunked(prepared(paramsB), channels: [dry, dry])
        #expect(renderApplied == renderB,
                "applyParams did not deliver descriptorB's params to the DSP")
        #expect(renderApplied != renderA, """
                applyParams was INERT — the instance still renders its construction \
                params, which is exactly what a dead `as?` arm looks like
                """)
    }
}

