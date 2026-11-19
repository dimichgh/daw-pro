import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x5 (DSP half, W8-X5D): the air layer, design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §5.4 / §5.7 "Air layer".
/// Pre-registered in the lane's PREDICTIONS P2 (and the P0 result that fixed
/// the test voice) before this file existed.
///
/// ⭐ The boring control first: OUTSIDE the spans every sample keeps its bit
/// pattern (§5.7's plant 2 lets the fade run 5 ms past a span and must turn it
/// red). Then the physics: the air sits at its stated level under the voice,
/// in its band, follows the voice, and is the same for the same seed.
///
/// Pure and nonisolated (`MainActorOccupancySiteTests` Leg C caps
/// `@MainActor` suites).
@Suite("p2-sing-x5 — SungAirLayer: bit-identical outside the spans, level, band, seed")
struct SungAirLayerTests {

    static let rate = 48_000.0

    /// The test voice (PREDICTIONS "P0 RESULT"): f0 220 Hz, partials 1…40 at
    /// k^−1.35, so its energy above 2 kHz sits −20.4 dB under the whole voice,
    /// the median MEASURED on real SoulX takes (−20.7 / −20.2 dB). Peak 0.5.
    static func voice(seconds: Double, f0: Double = 220) -> [Float] {
        let count = Int(seconds * rate)
        var out = [Double](repeating: 0, count: count)
        for k in 1...40 where Double(k) * f0 < rate / 2 {
            let amplitude = pow(Double(k), -1.35)
            let step = 2 * Double.pi * Double(k) * f0 / rate
            let phase = 0.7 * Double(k)
            for i in 0..<count { out[i] += amplitude * sin(step * Double(i) + phase) }
        }
        let peak = out.map(abs).max() ?? 1
        return out.map { Float($0 * 0.5 / peak) }
    }

    static func span(_ start: Double, _ end: Double, air: Double) -> SungAirLayer.Span {
        SungAirLayer.Span(startSeconds: start, endSeconds: end, levelDb: SungAirLayer.levelDb(forAir: air)!)
    }

    static func samples(_ seconds: Double) -> Int { Int((seconds * rate).rounded()) }

    static func rms(_ x: ArraySlice<Float>) -> Double {
        (x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))).squareRoot()
    }

    static func db(_ x: Double) -> Double { 20 * log10(x) }

    /// The indices whose bit pattern differs.
    static func changed(_ a: [Float], _ b: [Float]) -> [Int] {
        zip(a, b).enumerated().compactMap { $0.element.0.bitPattern != $0.element.1.bitPattern ? $0.offset : nil }
    }

    // MARK: - The instrument: an FFT that is not the layer's filters

    /// Power spectrum of a Hann-windowed `x` (count a power of two), bin k at
    /// k × rate / count Hz. Radix-2, iterative, Double.
    static func powerSpectrum(_ x: [Double]) -> [Double] {
        let n = x.count
        precondition(n > 0 && n & (n - 1) == 0)
        var re = x.enumerated().map { $0.element * (0.5 - 0.5 * cos(2 * .pi * Double($0.offset) / Double(n))) }
        var im = [Double](repeating: 0, count: n)
        var j = 0
        for i in 1..<n {
            var bit = n >> 1
            while j & bit != 0 { j ^= bit; bit >>= 1 }
            j |= bit
            if i < j { re.swapAt(i, j); im.swapAt(i, j) }
        }
        var length = 2
        while length <= n {
            let angle = -2 * Double.pi / Double(length)
            for start in stride(from: 0, to: n, by: length) {
                for k in 0..<(length / 2) {
                    let wr = cos(angle * Double(k)), wi = sin(angle * Double(k))
                    let a = start + k, b = a + length / 2
                    let tr = re[b] * wr - im[b] * wi, ti = re[b] * wi + im[b] * wr
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                }
            }
            length <<= 1
        }
        return (0...(n / 2)).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }

    /// Power between `low` and `high` Hz of `x[from ..< from + 16384]`.
    static func bandPower(_ x: [Float], from: Int, _ low: Double, _ high: Double) -> Double {
        let n = 16_384
        let spectrum = powerSpectrum(x[from..<(from + n)].map(Double.init))
        var sum = 0.0
        for (k, p) in spectrum.enumerated() {
            let hz = Double(k) * rate / Double(n)
            if hz >= low && hz < high { sum += p }
        }
        return sum
    }

    // MARK: - The level scale

    @Test("the level scale: a little / some / lots = −24 / −18 / −12 dB; none, NaN and below 0 add nothing")
    func levelScale() throws {
        #expect(abs(try #require(SungAirLayer.levelDb(forAir: SungAirLayer.airLittle)) + 24) < 1e-9)
        #expect(abs(try #require(SungAirLayer.levelDb(forAir: SungAirLayer.airSome)) + 18) < 1e-9)
        #expect(abs(try #require(SungAirLayer.levelDb(forAir: SungAirLayer.airLots)) + 12) < 1e-9)
        #expect(SungAirLayer.levelDb(forAir: 0) == nil)
        #expect(SungAirLayer.levelDb(forAir: -0.5) == nil)
        #expect(SungAirLayer.levelDb(forAir: .nan) == nil)
        #expect(SungAirLayer.levelDb(forAir: .infinity) == nil)
        #expect(SungAirLayer.levelDb(forAir: 3) == -12, "above 1 reads as lots")
    }

    // MARK: - ⭐ The boring control

    @Test("outside every span each sample keeps its bit pattern (span start sample included, end exclusive)",
          arguments: [SungAirLayer.airLittle, SungAirLayer.airLots])
    func outsideSpansBitIdentical(air: Double) {
        var take = Self.voice(seconds: 2.0)
        take[0] = -0.0                                   // a −0.0 outside must stay −0.0
        take[Self.samples(0.95)] = -0.0
        let spans = [Self.span(0.20, 0.50, air: air), Self.span(0.50, 0.90, air: air),   // two abutting
                     Self.span(1.30, 1.70, air: air)]
        let out = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 42)
        let inside = [Self.samples(0.20)..<Self.samples(0.90), Self.samples(1.30)..<Self.samples(1.70)]
        let moved = Self.changed(take, out)
        let outside = moved.filter { i in !inside.contains { $0.contains(i) } }
        #expect(outside.isEmpty, "\(outside.count) samples outside the spans changed, first \(outside.prefix(5))")
        #expect(!moved.contains(Self.samples(0.20)) && !moved.contains(Self.samples(1.30)),
                "the sample on a span's first edge must be untouched")
        #expect(out[0].bitPattern == (-0.0 as Float).bitPattern)
        // The positive control: the instrument can see a change, and the spans did change.
        #expect(moved.count > Self.samples(0.6), "only \(moved.count) samples changed inside 0.7 s of spans")
        #expect(Self.changed(take, take).isEmpty)
    }

    @Test("the same seed gives the same bytes; another seed changes only the spans")
    func determinism() {
        let take = Self.voice(seconds: 1.5)
        let spans = [Self.span(0.4, 1.1, air: SungAirLayer.airSome)]
        let a = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 7)
        let b = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 7)
        let c = SungAirLayer.apply(spans, to: take, sampleRate: Self.rate, seed: 8)
        #expect(Self.changed(a, b).isEmpty, "the same seed rendered different bytes")
        let differ = Self.changed(a, c)
        let span = Self.samples(0.4)..<Self.samples(1.1)
        #expect(differ.allSatisfy { span.contains($0) }, "another seed changed a sample outside the span")
        #expect(Double(differ.count) > 0.9 * Double(span.count), "another seed changed only \(differ.count) samples")
    }

    // MARK: - The physics

    @Test("the air sits at its level under the voice: −24 / −18 / −12 dB ± 1.5 over the span's plateau",
          arguments: [SungAirLayer.airLittle, SungAirLayer.airSome, SungAirLayer.airLots])
    func levelCalibration(air: Double) throws {
        let take = Self.voice(seconds: 1.5)
        let out = SungAirLayer.apply([Self.span(0.3, 1.2, air: air)], to: take, sampleRate: Self.rate, seed: 3)
        let plateau = Self.samples(0.35)..<Self.samples(1.15)
        let added = plateau.map { out[$0] - take[$0] }
        let measured = Self.db(Self.rms(added[...]) / Self.rms(take[plateau]))
        let wanted = try #require(SungAirLayer.levelDb(forAir: air))
        print("air-layer| level air \(air): \(String(format: "%.2f", measured)) dB (wanted \(wanted))")
        #expect(abs(measured - wanted) <= 1.5, "air \(air) sits at \(measured) dB, wanted \(wanted) ± 1.5")
    }

    @Test("the air is a band: at least 20 dB less power below 500 Hz than in 2-8 kHz")
    func bandShape() {
        let take = Self.voice(seconds: 1.5)
        let out = SungAirLayer.apply([Self.span(0.2, 1.3, air: SungAirLayer.airLots)], to: take,
                                     sampleRate: Self.rate, seed: 11)
        let added = zip(out, take).map { $0 - $1 }
        let from = Self.samples(0.35)
        let low = Self.bandPower(added, from: from, 20, 500)
        let mid = Self.bandPower(added, from: from, 2_000, 8_000)
        let ratio = 10 * log10(mid / low)
        print("air-layer| band: 2-8 kHz is \(String(format: "%.1f", ratio)) dB above 20-500 Hz")
        #expect(ratio >= 20, "the air's low end is only \(ratio) dB under its 2-8 kHz band")
    }

    /// Design §5.7's bar, "+3 dB above 2 kHz in the spans at a little", on a
    /// voice whose energy above 2 kHz is what real SoulX takes measured. The
    /// lane pre-registered "a little" FAILING it (+1.5 dB predicted) and "some"
    /// and "lots" passing (+4.2, +8.7). A MEASURED design conflict between two
    /// [A] numbers, held inside `withKnownIssue` for listening round A, never
    /// "fixed" by quietly changing the voice or the level.
    @Test("energy above 2 kHz rises by at least 3 dB in the span (a little: known miss on a real-voice spectrum)",
          arguments: [SungAirLayer.airLittle, SungAirLayer.airSome, SungAirLayer.airLots])
    func highBandRise(air: Double) {
        let take = Self.voice(seconds: 1.5)
        let out = SungAirLayer.apply([Self.span(0.2, 1.3, air: air)], to: take, sampleRate: Self.rate, seed: 5)
        let from = Self.samples(0.35)
        let before = Self.bandPower(take, from: from, 2_000, Self.rate / 2)
        let after = Self.bandPower(out, from: from, 2_000, Self.rate / 2)
        let rise = 10 * log10(after / before)
        let voiceRatio = 10 * log10(before / Self.bandPower(take, from: from, 0, Self.rate / 2))
        print("air-layer| air \(air): above 2 kHz +\(String(format: "%.2f", rise)) dB "
              + "(voice above 2 kHz at \(String(format: "%.1f", voiceRatio)) dB)")
        if air == SungAirLayer.airLittle {
            withKnownIssue("""
                MEASURED design conflict (W8-X5D, 2026-10-06): real SoulX takes carry about −20 dB of their \
                energy above 2 kHz, so air at −24 dB adds about +1.5 dB there, short of design §5.7's +3 dB. \
                Both numbers are [A]; listening round A decides.
                """) {
                #expect(rise >= 3, "a little: +\(rise) dB above 2 kHz")
            }
        } else {
            #expect(rise >= 3, "air \(air): +\(rise) dB above 2 kHz")
        }
    }

    @Test("the air follows the voice: a voice 20 dB quieter gets air 20 dB quieter (± 1.5)")
    func followsTheEnvelope() {
        var take = Self.voice(seconds: 1.6)
        let quietFrom = Self.samples(0.8)
        for i in quietFrom..<take.count { take[i] *= 0.1 }
        let out = SungAirLayer.apply([Self.span(0.2, 1.4, air: SungAirLayer.airLots)], to: take,
                                     sampleRate: Self.rate, seed: 9)
        let added = zip(out, take).map { $0 - $1 }
        let loud = Self.rms(added[Self.samples(0.3)..<Self.samples(0.7)])
        let quiet = Self.rms(added[Self.samples(0.9)..<Self.samples(1.3)])
        let drop = Self.db(loud / quiet)
        print("air-layer| envelope: air dropped \(String(format: "%.2f", drop)) dB for a 20 dB quieter voice")
        #expect(abs(drop - 20) <= 1.5)
    }

    @Test("silence inside a span gets no air: beyond one envelope block from its edges it stays bit-identical")
    func silenceStaysSilent() {
        var take = Self.voice(seconds: 1.5)
        let hole = Self.samples(0.6)..<Self.samples(0.9)
        for i in hole { take[i] = 0 }
        let out = SungAirLayer.apply([Self.span(0.2, 1.3, air: SungAirLayer.airLots)], to: take,
                                     sampleRate: Self.rate, seed: 13)
        let block = Self.samples(SungAirLayer.envelopeBlockSeconds)
        let deep = (hole.lowerBound + 2 * block)..<(hole.upperBound - 2 * block)
        #expect(Self.changed(Array(take[deep]), Array(out[deep])).isEmpty, "air was added to silence")
        // An all-silent take is returned unchanged.
        let silent = [Float](repeating: 0, count: Self.samples(1.0))
        #expect(Self.changed(silent, SungAirLayer.apply([Self.span(0.1, 0.9, air: 1)], to: silent,
                                                        sampleRate: Self.rate, seed: 1)).isEmpty)
    }

    @Test("two abutting airy notes share their edge (no dip); a one-sample gap is the control that dips")
    func abuttingSpansDoNotDip() {
        let take = Self.voice(seconds: 1.4)
        let edge = 0.7
        let joined = SungAirLayer.apply([Self.span(0.2, edge, air: 1), Self.span(edge, 1.2, air: 1)],
                                        to: take, sampleRate: Self.rate, seed: 21)
        let gap = 1.0 / Self.rate
        let split = SungAirLayer.apply([Self.span(0.2, edge - gap, air: 1), Self.span(edge, 1.2, air: 1)],
                                       to: take, sampleRate: Self.rate, seed: 21)
        func airRms(_ out: [Float], _ range: Range<Int>) -> Double {
            Self.rms(range.map { out[$0] - take[$0] }[...])
        }
        let junction = (Self.samples(edge) - Self.samples(0.004))..<(Self.samples(edge) + Self.samples(0.004))
        let plateau = Self.samples(0.4)..<Self.samples(0.6)
        let joinedDip = Self.db(airRms(joined, junction) / airRms(joined, plateau))
        let splitDip = Self.db(airRms(split, junction) / airRms(split, plateau))
        print("air-layer| junction: abutting \(String(format: "%.1f", joinedDip)) dB, 1-sample gap "
              + "\(String(format: "%.1f", splitDip)) dB")
        #expect(joinedDip > -3, "abutting spans dip \(joinedDip) dB at their shared edge")
        #expect(splitDip < -6, "the control (a gap) should dip and reads \(splitDip) dB: the instrument is blind")
    }

    @Test("no new non-finite sample: a NaN stays only where it was")
    func nonFiniteGuard() {
        var take = Self.voice(seconds: 1.0)
        let bad = Self.samples(0.5)
        take[bad] = .nan
        let out = SungAirLayer.apply([Self.span(0.2, 0.8, air: 1)], to: take, sampleRate: Self.rate, seed: 4)
        let nonFinite = out.indices.filter { !out[$0].isFinite }
        #expect(nonFinite == [bad])
        #expect(Self.changed(take, out).count > Self.samples(0.5), "the NaN stopped the layer")
    }

    @Test("nothing to do returns the take unchanged: no spans, empty or out-of-range spans, a bad rate, an empty take")
    func degenerateInputs() {
        let take = Self.voice(seconds: 0.5)
        #expect(Self.changed(take, SungAirLayer.apply([], to: take, sampleRate: Self.rate, seed: 1)).isEmpty)
        let odd = [SungAirLayer.Span(startSeconds: 0.3, endSeconds: 0.3, levelDb: -12),
                   SungAirLayer.Span(startSeconds: 0.4, endSeconds: 0.2, levelDb: -12),
                   SungAirLayer.Span(startSeconds: 2, endSeconds: 3, levelDb: -12),
                   SungAirLayer.Span(startSeconds: .nan, endSeconds: 0.4, levelDb: -12),
                   SungAirLayer.Span(startSeconds: 0.1, endSeconds: 0.4, levelDb: .nan)]
        #expect(Self.changed(take, SungAirLayer.apply(odd, to: take, sampleRate: Self.rate, seed: 1)).isEmpty)
        let spans = [Self.span(0.1, 0.4, air: 1)]
        for rate in [0.0, -48_000, .nan, .infinity] {
            #expect(Self.changed(take, SungAirLayer.apply(spans, to: take, sampleRate: rate, seed: 1)).isEmpty)
        }
        #expect(SungAirLayer.apply(spans, to: [], sampleRate: Self.rate, seed: 1).isEmpty)
    }
}
