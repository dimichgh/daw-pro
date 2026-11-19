import Foundation
import Testing
@testable import DAWCore

/// W9-AIR (p2-sing-x9-air): the coupled air of listening round A2 (`SungAirLayer.Coupling`), an INTERNAL seam.
///
/// The boring controls first: today's layer keeps its bytes (a golden MEASURED on the original file, sha256
/// 6bbefdf1…, before any W9-AIR edit), `.loudness` IS today's layer, and outside the spans every bit stays. Then the
/// physics, each with today's layer as the POSITIVE control that reads the other way: the coupled air follows the
/// voice's tone, `.tonePulse` beats with the vocal-fold cycle while `.tone` does not (an in-suite negative control),
/// "s"-like sound gets no air, and the level matches today's. Then the guards: silence, NaN/inf, subnormal, rates.
///
/// Pure and nonisolated (`MainActorOccupancySiteTests` Leg C caps `@MainActor` suites).
@Suite("W9-AIR — coupled air: today's bytes kept, tone, pulse, voiced only, level, guards")
struct SungAirCouplingTests {

    static let rate = SungAirLayerTests.rate

    // MARK: - Instruments (independent of the coupling code: plain biquads, a single-bin DFT)

    static func fnv1a(_ samples: [Float]) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for sample in samples {
            var bits = sample.bitPattern
            for _ in 0..<4 {
                hash ^= UInt64(bits & 0xFF)
                hash = hash &* 0x0000_0100_0000_01B3
                bits >>= 8
            }
        }
        return hash
    }

    static func goldenInput() -> (take: [Float], spans: [SungAirLayer.Span]) {
        let take = SungAirLayerTests.voice(seconds: 1.5)
        let spans = [SungAirLayerTests.span(0.2, 0.7, air: SungAirLayer.airSome),
                     SungAirLayerTests.span(0.7, 1.2, air: SungAirLayer.airLots)]
        return (take, spans)
    }

    /// `out − take` per sample, in Double.
    static func added(_ out: [Float], _ take: [Float]) -> [Double] {
        zip(out, take).map { Double($0) - Double($1) }
    }

    /// 4th-order Butterworth high-pass (forward).
    static func highPass(_ x: [Double], _ hz: Double, rate: Double = rate) -> [Double] {
        var filter = SungAirLayer.Filter(stages: SungAirLayer.BandDesign.butterworthQs.map {
            SungAirLayer.Biquad.highPass(hz, q: $0, sampleRate: rate)
        })
        return x.map { filter.process($0) }
    }

    /// Mean square of `x` over `[from, to)` seconds, in dB (−300 for nothing).
    static func db(_ x: [Double], _ from: Double, _ to: Double, rate: Double = rate) -> Double {
        let a = Int(from * rate), b = min(x.count, Int(to * rate))
        guard b > a else { return -300 }
        let ms = x[a..<b].reduce(0) { $0 + $1 * $1 } / Double(b - a)
        return ms > 0 ? 10 * log10(ms) : -300
    }

    /// The envelope of `x`'s 2-8 kHz band (squared, zero-phase low-passed at 1 kHz, square root), and its
    /// modulation depth at `hz` over `[from, to)` seconds: 2·|DFT at hz| / DC, Hann-windowed.
    static func pulseDepth(_ x: [Double], hz: Double, from: Double, to: Double) -> Double {
        var band = SungAirLayer.Filter(stages: SungAirLayer.BandDesign.stages(highPassHz: 2_000, lowPassHz: 8_000,
                                                                           sampleRate: rate))
        let power = x.map { let y = band.process($0); return y * y }
        let smooth = SungAirLayer.zeroPhase(power, stages: [SungAirLayer.Biquad.lowPass(1_000, q: 0.5.squareRoot(),
                                                                                         sampleRate: rate)])
        let a = Int(from * rate), b = Int(to * rate), n = b - a
        var re = 0.0, im = 0.0, dc = 0.0
        for j in 0..<n {
            let e = max(0, smooth[a + j]).squareRoot()
            let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(j) / Double(n - 1))
            let phase = 2 * Double.pi * hz * Double(j) / rate
            re += e * w * cos(phase)
            im -= e * w * sin(phase)
            dc += e * w
        }
        return dc > 0 ? 2 * (re * re + im * im).squareRoot() / dc : 0
    }

    /// A sung vowel at `f0`: partials 1…40 at k^−slope, RMS `rms` (the `SungAirLayerTests.voice` recipe).
    static func vowel(seconds: Double, f0: Double, slope: Double, rms: Double) -> [Double] {
        let count = Int(seconds * rate)
        var out = [Double](repeating: 0, count: count)
        for k in 1...40 where Double(k) * f0 < rate / 2 {
            let amplitude = pow(Double(k), -slope)
            let step = 2 * Double.pi * Double(k) * f0 / rate
            for i in 0..<count { out[i] += amplitude * sin(step * Double(i) + 0.7 * Double(k)) }
        }
        let now = (out.reduce(0) { $0 + $1 * $1 } / Double(count)).squareRoot()
        return out.map { $0 * rms / now }
    }

    static func span(_ start: Double, _ end: Double) -> SungAirLayer.Span {
        SungAirLayerTests.span(start, end, air: SungAirLayer.airSome)
    }

    static let coupled: [SungAirLayer.Coupling] = [.tone, .tonePulse]

    // MARK: - Today's layer keeps its bytes

    @Test("today's layer: the bytes MEASURED on the original file before any W9-AIR edit")
    func todaysLayerGolden() {
        let (take, spans) = Self.goldenInput()
        #expect(Self.fnv1a(take) == 0xa505_424d_6a0c_45f5, "the golden's INPUT moved: the test voice changed")
        let out = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 42)
        #expect(Self.fnv1a(out) == 0x7bda_aa25_ba49_6f4b, "today's layer changed its bytes")
    }

    @Test(".loudness IS today's layer, bit for bit", arguments: [UInt64(42), 7, 0xDEAD_BEEF])
    func loudnessIsTodaysLayer(seed: UInt64) {
        let (take, spans) = Self.goldenInput()
        let today = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: seed)
        let coupled = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: seed, coupling: .loudness)
        #expect(today.map { $0.bitPattern } == coupled.map { $0.bitPattern })
    }

    @Test("outside every span the take keeps every bit; inside, the air is written",
          arguments: SungAirCouplingTests.coupled)
    func outsideSpansBitIdentical(coupling: SungAirLayer.Coupling) {
        var take = SungAirLayerTests.voice(seconds: 1.5)
        take[100] = -0.0                       // a −0.0 outside the spans must stay −0.0
        let spans = [Self.span(0.3, 0.6), Self.span(0.6, 0.9), Self.span(1.1, 1.3)]
        let out = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 9, coupling: coupling)
        let inside = [(Int(0.3 * Self.rate), Int(0.9 * Self.rate)), (Int(1.1 * Self.rate), Int(1.3 * Self.rate))]
        var outsideMoved = 0, insideMoved = 0, insideCount = 0
        for i in take.indices {
            let isInside = inside.contains { i >= $0.0 && i < $0.1 }
            let moved = out[i].bitPattern != take[i].bitPattern
            if isInside {
                insideCount += 1
                if moved { insideMoved += 1 }
            } else if moved {
                outsideMoved += 1
            }
        }
        #expect(outsideMoved == 0, "\(outsideMoved) samples moved outside the spans")
        #expect(out[100].bitPattern == (-0.0 as Float).bitPattern)
        // `.tonePulse` writes nothing BETWEEN the test voice's own bursts (its pulse is 0 there, MEASURED 68 % of
        // samples written on this sawtooth-like voice), so its floor is lower; every 10 ms block still gets air.
        let floor = coupling == .tonePulse ? 0.5 : 0.9
        #expect(Double(insideMoved) >= floor * Double(insideCount), "air written on \(insideMoved)/\(insideCount)")
        var emptyBlocks = 0
        for range in inside {
            var start = range.0
            while start + 480 <= range.1 {
                if !(start..<(start + 480)).contains(where: { out[$0].bitPattern != take[$0].bitPattern }) {
                    emptyBlocks += 1
                }
                start += 480
            }
        }
        #expect(emptyBlocks == 0, "\(emptyBlocks) 10 ms blocks inside the spans got no air")
        print("W9AIR| \(coupling) inside written \(insideMoved)/\(insideCount), empty blocks \(emptyBlocks)")
    }

    @Test("the same take, spans and seed give the same bytes; another seed gives other bytes",
          arguments: SungAirCouplingTests.coupled)
    func deterministic(coupling: SungAirLayer.Coupling) {
        let take = SungAirLayerTests.voice(seconds: 1.2)
        let spans = [Self.span(0.2, 1.0)]
        let a = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 7, coupling: coupling)
        let b = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 7, coupling: coupling)
        let c = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 8, coupling: coupling)
        #expect(a.map { $0.bitPattern } == b.map { $0.bitPattern })
        #expect(a.map { $0.bitPattern } != c.map { $0.bitPattern })
    }

    // MARK: - Level: matched to today's layer

    @Test("the added energy equals today's layer's for the same spans (± 0.3 dB)", arguments: SungAirCouplingTests.coupled)
    func levelMatchesTodaysLayer(coupling: SungAirLayer.Coupling) {
        let (take, spans) = Self.goldenInput()
        let today = Self.added(SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 42), take)
        let coupled = Self.added(SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 42,
                                                    coupling: coupling), take)
        let delta = Self.db(coupled, 0, 1.5) - Self.db(today, 0, 1.5)
        print("W9AIR| \(coupling) added energy vs today's: \(delta) dB")
        #expect(abs(delta) <= 0.3, "added energy \(delta) dB vs today's")
    }

    // MARK: - Tone: the air follows the voice's own spectrum

    @Test("bright vowel then dark vowel at one loudness: the coupled air's top follows the voice's; today's does not")
    func followsTheVoicesTone() {
        let bright = Self.vowel(seconds: 0.8, f0: 220, slope: 0.8, rms: 0.1)
        let dark = Self.vowel(seconds: 0.8, f0: 220, slope: 2.2, rms: 0.1)
        let take = (bright + dark).map { Float($0) }
        let spans = [Self.span(0.05, 1.55)]
        let voiceTop = Self.highPass(take.map { Double($0) }, 4_000)
        let voiceStep = Self.db(voiceTop, 0.2, 0.7) - Self.db(voiceTop, 1.0, 1.5)
        #expect(voiceStep >= 10, "the test voice is not brighter in its first half: \(voiceStep) dB")

        func airStep(_ coupling: SungAirLayer.Coupling) -> Double {
            let out = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 3, coupling: coupling)
            let top = Self.highPass(Self.added(out, take), 4_000)
            return Self.db(top, 0.2, 0.7) - Self.db(top, 1.0, 1.5)
        }
        let today = airStep(.loudness)
        print("W9AIR| tone: voice top step \(voiceStep) dB; today's air \(today) dB; "
              + "tone \(airStep(.tone)) dB; tonePulse \(airStep(.tonePulse)) dB")
        #expect(abs(today) <= 1.5, "POSITIVE CONTROL: today's air should be blind to tone, steps \(today) dB")
        for coupling in Self.coupled {
            let step = airStep(coupling)
            #expect(step >= 10, "\(coupling): air top steps only \(step) dB (voice \(voiceStep) dB)")
            #expect(abs(step - voiceStep) <= 4, "\(coupling): air top \(step) dB vs voice \(voiceStep) dB")
        }
    }

    // MARK: - Pulse: .tonePulse beats with the vocal-fold cycle; .tone and today's do not

    @Test("the air's top-band envelope at the voice's f0: .tonePulse deep, .tone and today's flat")
    func pulsesWithTheVoice() {
        let take = SungAirLayerTests.voice(seconds: 1.5, f0: 200)
        let spans = [Self.span(0.1, 1.4)]
        let voiceDepth = Self.pulseDepth(take.map { Double($0) }, hz: 200, from: 0.3, to: 1.2)
        #expect(voiceDepth >= 0.25, "CONTROL: the instrument cannot see the voice's own pulsing (\(voiceDepth))")
        func depth(_ coupling: SungAirLayer.Coupling) -> Double {
            let out = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 5, coupling: coupling)
            return Self.pulseDepth(Self.added(out, take), hz: 200, from: 0.3, to: 1.2)
        }
        let today = depth(.loudness), tone = depth(.tone), pulsed = depth(.tonePulse)
        print("W9AIR| pulse depth at f0: voice \(voiceDepth), today's \(today), tone \(tone), tonePulse \(pulsed)")
        #expect(today <= 0.1, "today's air pulses: \(today)")
        #expect(tone <= 0.1, "NEGATIVE CONTROL: .tone pulses: \(tone)")
        #expect(pulsed >= 0.25, ".tonePulse does not pulse: \(pulsed) (voice \(voiceDepth))")
        #expect(pulsed >= 3 * max(tone, 0.01), ".tonePulse \(pulsed) vs .tone \(tone)")
    }

    // MARK: - Voiced sound only

    @Test("an 's' between two vowels at one loudness: the coupled air skips it; today's does not")
    func voicedSoundOnly() {
        let vowel = Self.vowel(seconds: 0.6, f0: 220, slope: 1.35, rms: 0.1)
        var rng = SplitMix64(seed: 11)
        let white = (0..<Int(0.4 * Self.rate)).map { _ in Double(rng.next() >> 11) * 0x1p-53 * 2 - 1 }
        var hiss = Self.highPass(white, 3_000)
        let hissRms = (hiss.reduce(0) { $0 + $1 * $1 } / Double(hiss.count)).squareRoot()
        hiss = hiss.map { $0 * 0.1 / hissRms }
        let take = (vowel + hiss + vowel).map { Float($0) }
        let spans = [Self.span(0.05, 1.55)]
        func ratio(_ coupling: SungAirLayer.Coupling) -> Double {
            let air = Self.added(SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 4,
                                                    coupling: coupling), take)
            let voiced = (Self.db(air, 0.15, 0.5) + Self.db(air, 1.1, 1.45)) / 2
            return Self.db(air, 0.7, 0.9) - voiced
        }
        let today = ratio(.loudness)
        print("W9AIR| 's' vs vowels: today's \(today) dB, tone \(ratio(.tone)) dB, tonePulse \(ratio(.tonePulse)) dB")
        #expect(abs(today) <= 3, "POSITIVE CONTROL: today's air on the 's' vs the vowels: \(today) dB")
        for coupling in Self.coupled {
            let r = ratio(coupling)
            #expect(r <= -15, "\(coupling): air on the 's' is only \(r) dB under the vowels'")
        }
    }

    @Test("the voiced weight's smoothstep: 0 at 0.35, 1 at 0.65, 0.5 midway, 0 for NaN")
    func voicedWeightCurve() {
        #expect(SungAirLayer.voicedWeight(share: 0.2) == 0)
        #expect(SungAirLayer.voicedWeight(share: SungAirLayer.voicedShareLow) == 0)
        #expect(SungAirLayer.voicedWeight(share: SungAirLayer.voicedShareHigh) == 1)
        #expect(abs(SungAirLayer.voicedWeight(share: 0.5) - 0.5) < 1e-12)
        #expect(SungAirLayer.voicedWeight(share: 0.9) == 1)
        #expect(SungAirLayer.voicedWeight(share: .nan) == 0)
    }

    // MARK: - Guards

    @Test("silence gets no air: the take comes back bit-identical", arguments: SungAirCouplingTests.coupled)
    func silenceGetsNoAir(coupling: SungAirLayer.Coupling) {
        let zeros = [Float](repeating: 0, count: Int(Self.rate))
        let negatives = [Float](repeating: -0.0, count: Int(Self.rate))
        for take in [zeros, negatives] {
            let out = SungAirLayer.apply([Self.span(0.1, 0.9)], to: take, sampleRate: Self.rate, seed: 1,
                                         coupling: coupling)
            #expect(out.map { $0.bitPattern } == take.map { $0.bitPattern })
        }
        #expect(SungAirLayer.pulseCurve([Double](repeating: 0, count: 4_800), blockSize: 480,
                                        sampleRate: Self.rate).allSatisfy { $0 == 0 })
        #expect(SungAirLayer.BlockCurve(blocks: [], blockSize: 480).value(at: 3) == 0)
    }

    @Test("NaN and ±inf input samples keep their bits; no new non-finite sample", arguments: SungAirCouplingTests.coupled)
    func nonFiniteInput(coupling: SungAirLayer.Coupling) {
        var take = SungAirLayerTests.voice(seconds: 1.5)
        let planted: [Int: Float] = [30_000: .nan, 30_010: .infinity, 1_000: -.infinity]
        for (i, x) in planted { take[i] = x }
        let out = SungAirLayer.apply([Self.span(0.2, 1.2)], to: take, sampleRate: Self.rate, seed: 2,
                                     coupling: coupling)
        for (i, _) in planted { #expect(out[i].bitPattern == take[i].bitPattern, "sample \(i) changed") }
        let newNonFinite = out.indices.filter { planted[$0] == nil && !out[$0].isFinite }
        #expect(newNonFinite.isEmpty, "new non-finite samples at \(newNonFinite.prefix(5))")
        #expect(out.indices.contains { out[$0].bitPattern != take[$0].bitPattern }, "no air was written at all")
    }

    @Test("a take so quiet its air would be subnormal is left bit-identical (today's writes it: the control)")
    func subnormalAirNotWritten() {
        let take = SungAirLayerTests.voice(seconds: 1.0).map { $0 * 1e-38 }
        let spans = [Self.span(0.1, 0.9)]
        let today = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 6)
        let todayMoved = take.indices.filter { today[$0].bitPattern != take[$0].bitPattern }.count
        #expect(todayMoved > 0, "CONTROL: this input should give today's layer subnormal air to write")
        for coupling in Self.coupled {
            let out = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 6, coupling: coupling)
            #expect(out.map { $0.bitPattern } == take.map { $0.bitPattern }, "\(coupling) wrote subnormal air")
        }
    }

    @Test("no spans, an empty take or a bad sample rate return the take; 8 kHz works",
          arguments: SungAirCouplingTests.coupled)
    func edgeInputs(coupling: SungAirLayer.Coupling) {
        let take = SungAirLayerTests.voice(seconds: 0.5)
        for rate in [0.0, -48_000, .nan, .infinity] {
            #expect(SungAirLayer.apply([Self.span(0.1, 0.4)], to: take, sampleRate: rate, seed: 1,
                                       coupling: coupling).map { $0.bitPattern } == take.map { $0.bitPattern })
        }
        #expect(SungAirLayer.apply([], to: take, sampleRate: Self.rate, seed: 1, coupling: coupling)
                    .map { $0.bitPattern } == take.map { $0.bitPattern })
        #expect(SungAirLayer.apply([Self.span(0.1, 0.4)], to: [], sampleRate: Self.rate, seed: 1,
                                   coupling: coupling).isEmpty)

        let low = 8_000.0
        let count = Int(0.5 * low)
        let slow = (0..<count).map { i in Float(0.3 * sin(2 * Double.pi * 220 * Double(i) / low)
                                                + 0.05 * sin(2 * Double.pi * 2_420 * Double(i) / low)) }
        let out = SungAirLayer.apply([Self.span(0.1, 0.4)], to: slow, sampleRate: low, seed: 1, coupling: coupling)
        #expect(out.allSatisfy { $0.isFinite })
        #expect(slow.indices.contains { out[$0] != slow[$0] }, "no air at 8 kHz")
    }
}
