import AVFAudio
import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m22-a EQ v2 — HP/LP bands, shelf Q, per-band bypass — proven against the
/// load-bearing regression pin: `LegacyEQReference` replicates the PRE-m22-a
/// `EQEffect` render math expression-for-expression, and the null test asserts
/// an all-nil-new-fields EQ renders BIT-IDENTICAL to it. This file was run
/// against the pre-m22-a `EQEffect` FIRST (the reference passed bit-exact
/// against the shipping binary before any DSP change landed), so the reference
/// IS the captured legacy behavior, not a guess.
@MainActor
@Suite("EQ v2 — HP/LP, shelf Q, per-band bypass", .serialized)
struct EQv2Tests {
    private static let sampleRate = 48_000.0

    // MARK: - Signal + measurement helpers (the FXPack1 idiom)

    private func sine(_ frequency: Double, amplitude: Double, frames: Int) -> [Float] {
        (0..<frames).map {
            Float(amplitude * sin(2.0 * .pi * frequency * Double($0) / Self.sampleRate))
        }
    }

    private func mix(_ signals: [[Float]]) -> [Float] {
        var out = [Float](repeating: 0, count: signals[0].count)
        for signal in signals {
            for index in out.indices { out[index] += signal[index] }
        }
        return out
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

    private func dB(_ ratio: Double) -> Double { 20.0 * log10(ratio) }

    /// Runs `channels` through `effect` in 512-frame quanta.
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

    /// FNV-1a 64 over the Float bit patterns — render fingerprints for the
    /// [measured] evidence lines (cross-run, same-machine stable).
    private func fingerprint(_ channels: [[Float]]) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for channel in channels {
            for sample in channel {
                var bits = sample.bitPattern
                for _ in 0..<4 {
                    hash = (hash ^ UInt64(bits & 0xFF)) &* 0x100000001b3
                    bits >>= 8
                }
            }
        }
        return String(format: "%016llx", hash)
    }

    /// Settled analysis window: 100 ms settle, then one whole second.
    private static let settle = 4_800
    private static let window = settle..<(settle + 48_000)
    private static let totalFrames = settle + 48_000

    // MARK: - The pre-m22-a legacy reference

    /// Bit-exact replica of the PRE-m22-a `EQEffect`: RBJ cookbook biquads —
    /// low shelf, peak, peak, high shelf in series — TDF2 with Float64 state,
    /// shelves at fixed slope S = 1 (`alpha = sinW0 / 2 * √2`, i.e. effective
    /// Q = 1/√2), a band with gain EXACTLY 0 dB skipped outright (state never
    /// advanced), 512-frame chunk boundaries with the 1e-25 denormal flush
    /// after each band/channel chunk — every expression copied verbatim so
    /// float rounding matches to the last bit.
    private struct LegacyEQReference {
        private var coeffs = [Double](repeating: 0, count: 4 * 5)
        private var bandActive = [Bool](repeating: false, count: 4)

        init(params: EQParams, sampleRate: Double) {
            setBand(0, kind: 0, freq: params.lowShelfFreq,
                    gainDb: params.lowShelfGainDb, q: 1, sampleRate: sampleRate)
            setBand(1, kind: 1, freq: params.peak1Freq,
                    gainDb: params.peak1GainDb, q: params.peak1Q, sampleRate: sampleRate)
            setBand(2, kind: 1, freq: params.peak2Freq,
                    gainDb: params.peak2GainDb, q: params.peak2Q, sampleRate: sampleRate)
            setBand(3, kind: 2, freq: params.highShelfFreq,
                    gainDb: params.highShelfGainDb, q: 1, sampleRate: sampleRate)
        }

        private mutating func setBand(_ band: Int, kind: Int, freq: Double, gainDb: Double,
                                      q: Double, sampleRate: Double) {
            bandActive[band] = gainDb != 0
            guard bandActive[band] else { return }
            let a = pow(10.0, gainDb / 40.0)
            let f = min(freq, sampleRate * 0.49)
            let w0 = 2.0 * Double.pi * f / sampleRate
            let cosW0 = cos(w0)
            let sinW0 = sin(w0)
            var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
            switch kind {
            case 1:  // peaking, alpha from Q
                let alpha = sinW0 / (2.0 * q)
                b0 = 1.0 + alpha * a
                b1 = -2.0 * cosW0
                b2 = 1.0 - alpha * a
                a0 = 1.0 + alpha / a
                a1 = -2.0 * cosW0
                a2 = 1.0 - alpha / a
            default:  // shelves, slope S = 1
                let alpha = sinW0 / 2.0 * (2.0).squareRoot()
                let sqrtA = a.squareRoot()
                let twoSqrtAAlpha = 2.0 * sqrtA * alpha
                if kind == 0 {  // low shelf
                    b0 = a * ((a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha)
                    b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0)
                    b2 = a * ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha)
                    a0 = (a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha
                    a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosW0)
                    a2 = (a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha
                } else {  // high shelf
                    b0 = a * ((a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha)
                    b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0)
                    b2 = a * ((a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha)
                    a0 = (a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha
                    a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosW0)
                    a2 = (a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha
                }
            }
            let base = band * 5
            coeffs[base] = b0 / a0
            coeffs[base + 1] = b1 / a0
            coeffs[base + 2] = b2 / a0
            coeffs[base + 3] = a1 / a0
            coeffs[base + 4] = a2 / a0
        }

        /// Chunked render — same channel-major-then-band nesting and chunk
        /// boundaries as `EQEffect.process` driven by `processChunked`.
        func render(channels: [[Float]], chunk: Int = 512) -> [[Float]] {
            var out = channels
            // TDF2 state per (band, channel): s1, s2.
            var state = [Double](repeating: 0, count: 4 * channels.count * 2)
            let total = channels[0].count
            var offset = 0
            while offset < total {
                let frames = min(chunk, total - offset)
                for channel in 0..<channels.count {
                    for band in 0..<4 where bandActive[band] {
                        let base = band * 5
                        let b0 = coeffs[base], b1 = coeffs[base + 1], b2 = coeffs[base + 2]
                        let a1 = coeffs[base + 3], a2 = coeffs[base + 4]
                        let sBase = (band * channels.count + channel) * 2
                        var s1 = state[sBase]
                        var s2 = state[sBase + 1]
                        for frame in 0..<frames {
                            let x = Double(out[channel][offset + frame])
                            let y = b0 * x + s1
                            s1 = b1 * x - a1 * y + s2
                            s2 = b2 * x - a2 * y
                            out[channel][offset + frame] = Float(y)
                        }
                        if abs(s1) < 1e-25 { s1 = 0 }
                        if abs(s2) < 1e-25 { s2 = 0 }
                        state[sBase] = s1
                        state[sBase + 1] = s2
                    }
                }
                offset += frames
            }
            return out
        }
    }

    /// Legacy params exercising all four legacy bands (both shelf kinds AND
    /// both peaks non-neutral, off-default Qs) — the null-pin fixture.
    private static let legacyParams = EQParams(
        lowShelfFreq: 120, lowShelfGainDb: 4.5,
        peak1Freq: 450, peak1GainDb: -3.5, peak1Q: 1.8,
        peak2Freq: 3_200, peak2GainDb: 2.5, peak2Q: 0.9,
        highShelfFreq: 9_000, highShelfGainDb: -4)

    private func nullPinInput() -> [Float] {
        mix([sine(50, amplitude: 0.15, frames: Self.totalFrames),
             sine(450, amplitude: 0.15, frames: Self.totalFrames),
             sine(3_200, amplitude: 0.15, frames: Self.totalFrames),
             sine(12_000, amplitude: 0.15, frames: Self.totalFrames)])
    }

    // MARK: - The null pin (the load-bearing regression test)

    @Test("all new fields nil renders BIT-IDENTICAL to the pre-m22-a path")
    func allNilNewFieldsRenderBitIdenticalToLegacy() throws {
        let dry = nullPinInput()
        let eq = EQEffect(params: Self.legacyParams)
        eq.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let wet = try processChunked(eq, channels: [dry, dry])
        let reference = LegacyEQReference(params: Self.legacyParams, sampleRate: Self.sampleRate)
            .render(channels: [dry, dry])
        print("[measured] eq v2 null pin: EQEffect fingerprint \(fingerprint(wet)) "
              + "vs legacy reference \(fingerprint(reference))")
        #expect(wet[0] == reference[0])  // bit-identical, sample for sample
        #expect(wet[1] == reference[1])
    }

    // MARK: - HP/LP slope measurements

    /// Renders `params` over `dry` (stereo) and returns channel 0.
    private func renderMono(_ params: EQParams, dry: [Float]) throws -> [Float] {
        let eq = EQEffect(params: params)
        eq.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        return try processChunked(eq, channels: [dry, dry])[0]
    }

    private func gainDb(_ wet: [Float], _ dry: [Float], at frequency: Double) -> Double {
        dB(goertzel(wet, frequency: frequency, in: Self.window)
           / goertzel(dry, frequency: frequency, in: Self.window))
    }

    @Test("high-pass @ 100 Hz: −3 dB corner, ~−12/−24 dB one octave below per slope")
    func highPassSlopesMeasured() throws {
        let dry = mix([sine(50, amplitude: 0.2, frames: Self.totalFrames),
                       sine(100, amplitude: 0.2, frames: Self.totalFrames),
                       sine(1_000, amplitude: 0.2, frames: Self.totalFrames)])
        let hp12 = try renderMono(EQParams(highPassFreq: 100), dry: dry)
        let hp24 = try renderMono(
            EQParams(highPassFreq: 100, highPassSlopeDbPerOct: 24), dry: dry)

        // Butterworth analog prototype: |H| at fc/2 is −12.30 dB (2nd order)
        // and −24.08 dB (4th order); −3.01 dB at the corner for BOTH.
        let g50at12 = gainDb(hp12, dry, at: 50)
        let g50at24 = gainDb(hp24, dry, at: 50)
        let corner12 = gainDb(hp12, dry, at: 100)
        let corner24 = gainDb(hp24, dry, at: 100)
        let pass12 = gainDb(hp12, dry, at: 1_000)
        let pass24 = gainDb(hp24, dry, at: 1_000)
        print("[measured] HP 100 Hz: 50 Hz \(g50at12) dB @12, \(g50at24) dB @24; "
              + "corner \(corner12)/\(corner24) dB; 1 kHz \(pass12)/\(pass24) dB")
        #expect(abs(g50at12 - (-12.3)) < 1.0)
        #expect(abs(g50at24 - (-24.1)) < 1.5)
        // The 24 dB/oct render sits ~12 dB deeper than the 12 dB/oct one at
        // the same corner, one octave down.
        #expect(abs((g50at24 - g50at12) - (-11.8)) < 1.5)
        #expect(abs(corner12 - (-3.0)) < 0.5)
        #expect(abs(corner24 - (-3.0)) < 0.5)
        // Passband stays flat (Butterworth, either slope).
        #expect(abs(pass12) < 0.5)
        #expect(abs(pass24) < 0.5)
    }

    @Test("low-pass @ 2 kHz: −3 dB corner, ~−12/−24 dB one octave above per slope")
    func lowPassSlopesMeasured() throws {
        let dry = mix([sine(500, amplitude: 0.2, frames: Self.totalFrames),
                       sine(2_000, amplitude: 0.2, frames: Self.totalFrames),
                       sine(4_000, amplitude: 0.2, frames: Self.totalFrames)])
        let lp12 = try renderMono(EQParams(lowPassFreq: 2_000), dry: dry)
        let lp24 = try renderMono(
            EQParams(lowPassFreq: 2_000, lowPassSlopeDbPerOct: 24), dry: dry)

        let g4kAt12 = gainDb(lp12, dry, at: 4_000)
        let g4kAt24 = gainDb(lp24, dry, at: 4_000)
        let corner12 = gainDb(lp12, dry, at: 2_000)
        let corner24 = gainDb(lp24, dry, at: 2_000)
        let pass12 = gainDb(lp12, dry, at: 500)
        let pass24 = gainDb(lp24, dry, at: 500)
        print("[measured] LP 2 kHz: 4 kHz \(g4kAt12) dB @12, \(g4kAt24) dB @24; "
              + "corner \(corner12)/\(corner24) dB; 500 Hz \(pass12)/\(pass24) dB")
        // Bilinear warping steepens the octave-above readings slightly vs the
        // analog −12.3/−24.1; tolerances stated accordingly.
        #expect(abs(g4kAt12 - (-12.3)) < 1.5)
        #expect(abs(g4kAt24 - (-24.1)) < 2.5)
        #expect(abs(corner12 - (-3.0)) < 0.5)
        #expect(abs(corner24 - (-3.0)) < 0.5)
        #expect(abs(pass12) < 0.5)
        #expect(abs(pass24) < 0.5)
        // NaN/denormal guard on the steep cascade.
        #expect(lp24.allSatisfy { $0.isFinite })
    }

    // MARK: - Per-band bypass (a TRUE no-op)

    @Test("a bypassed band is coefficient-identical to the band being absent")
    func perBandBypassIsTrueNoOp() throws {
        let dry = nullPinInput()

        // Every band non-neutral + HP/LP on, but ALL bands bypassed: the EQ
        // must pass the input through BIT-EXACT (band absent ≡ band off).
        let allOff = EQParams(
            lowShelfFreq: 120, lowShelfGainDb: 4.5,
            peak1Freq: 450, peak1GainDb: -3.5, peak1Q: 1.8,
            peak2Freq: 3_200, peak2GainDb: 2.5, peak2Q: 0.9,
            highShelfFreq: 9_000, highShelfGainDb: -4,
            highPassFreq: 200, highPassSlopeDbPerOct: 24, highPassEnabled: false,
            lowPassFreq: 5_000, lowPassSlopeDbPerOct: 24, lowPassEnabled: false,
            lowShelfEnabled: false, peak1Enabled: false,
            peak2Enabled: false, highShelfEnabled: false)
        let bypassedWet = try renderMono(allOff, dry: dry)
        var maxDiff: Float = 0
        for frame in 0..<dry.count {
            maxDiff = max(maxDiff, abs(bypassedWet[frame] - dry[frame]))
        }
        print("[measured] all-bands-bypassed null: max |wet − dry| = \(maxDiff)")
        #expect(maxDiff == 0)

        // One band bypassed ≡ that band's field absent: bit-identical renders.
        var oneOff = Self.legacyParams
        oneOff.peak1Enabled = false
        var oneAbsent = Self.legacyParams
        oneAbsent.peak1GainDb = 0  // 0 dB = the band's absent/neutral encoding
        let offWet = try renderMono(oneOff, dry: dry)
        let absentWet = try renderMono(oneAbsent, dry: dry)
        #expect(offWet == absentWet)

        // `*Enabled` nil ≡ explicit true (the nil-default law).
        var explicitOn = Self.legacyParams
        explicitOn.peak1Enabled = true
        explicitOn.lowShelfEnabled = true
        let nilWet = try renderMono(Self.legacyParams, dry: dry)
        let onWet = try renderMono(explicitOn, dry: dry)
        #expect(nilWet == onWet)
    }

    // MARK: - Shelf Q

    @Test("shelf Q: nil matches the legacy fixed slope; a high Q audibly resonates")
    func shelfQNilMatchesLegacyAndHighQDiffers() throws {
        let dry = mix([sine(100, amplitude: 0.15, frames: Self.totalFrames),
                       sine(300, amplitude: 0.15, frames: Self.totalFrames),
                       sine(2_000, amplitude: 0.15, frames: Self.totalFrames)])
        let base = EQParams(lowShelfFreq: 200, lowShelfGainDb: -12)

        // nil Q ≡ the pre-m22-a shelf (bit-exact vs the legacy reference).
        let nilQWet = try renderMono(base, dry: dry)
        let reference = LegacyEQReference(params: base, sampleRate: Self.sampleRate)
            .render(channels: [dry, dry])
        #expect(nilQWet == reference[0])

        // Q = the documented nil-equivalent (1/√2) is the same filter to
        // within float-rounding dust (the constants differ only in expression
        // order inside the coefficient math).
        var explicitQ = base
        explicitQ.lowShelfQ = EQParams.defaultShelfQ
        let explicitWet = try renderMono(explicitQ, dry: dry)
        var maxDiff: Float = 0
        for frame in 0..<dry.count {
            maxDiff = max(maxDiff, abs(explicitWet[frame] - nilQWet[frame]))
        }
        print("[measured] shelf Q 0.707-explicit vs nil: max diff = \(maxDiff)")
        #expect(maxDiff < 1e-5)

        // A high shelf Q audibly resonates near the corner — the new control
        // genuinely changes the sound.
        var resonant = base
        resonant.lowShelfQ = 4
        let resonantWet = try renderMono(resonant, dry: dry)
        let g300nil = gainDb(nilQWet, dry, at: 300)
        let g300res = gainDb(resonantWet, dry, at: 300)
        print("[measured] shelf −12 dB @ 200 Hz, 300 Hz gain: nil-Q \(g300nil) dB, "
              + "Q=4 \(g300res) dB")
        #expect(abs(g300res - g300nil) > 1.0)
        #expect(resonantWet.allSatisfy { $0.isFinite })
    }

    // MARK: - Automation slots (the m22-a appends)

    @Test("automation slots 10-12 drive the high-pass on the render thread")
    func automationSlotsDriveHighPass() throws {
        let dry = mix([sine(50, amplitude: 0.2, frames: Self.totalFrames),
                       sine(1_000, amplitude: 0.2, frames: Self.totalFrames)])
        // Default params — HP off at the knobs; the automation store turns it
        // on per quantum (slot 10 freq, 11 slope, 12 enabled), exactly like a
        // lane would.
        let eq = EQEffect()
        eq.prepare(sampleRate: Self.sampleRate, maxFramesPerQuantum: 512, channelCount: 2)
        let format = try #require(AVAudioFormat(
            standardFormatWithSampleRate: Self.sampleRate, channels: 2))
        let buffer = try #require(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
        var wet = [Float]()
        var offset = 0
        while offset < dry.count {
            let frames = min(512, dry.count - offset)
            buffer.frameLength = AVAudioFrameCount(frames)
            let data = try #require(buffer.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<frames { data[channel][frame] = dry[offset + frame] }
            }
            // The AutomationRenderer contract: stores land BEFORE process(),
            // same thread, every quantum.
            eq.storeAutomatedParam(slot: 10, value: 100)
            eq.storeAutomatedParam(slot: 11, value: 24)
            eq.storeAutomatedParam(slot: 12, value: 1)
            eq.process(
                buffers: UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList),
                frameCount: frames)
            wet.append(contentsOf: UnsafeBufferPointer(start: data[0], count: frames))
            offset += frames
        }
        let g50 = gainDb(wet, dry, at: 50)
        let g1k = gainDb(wet, dry, at: 1_000)
        print("[measured] automated HP (slots 10-12, 100 Hz @ 24 dB/oct): "
              + "50 Hz \(g50) dB, 1 kHz \(g1k) dB")
        #expect(abs(g50 - (-24.1)) < 1.5)
        #expect(abs(g1k) < 0.5)
    }
}
