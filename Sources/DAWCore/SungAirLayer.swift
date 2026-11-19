import Foundation

/// The "air" (breathiness) layer of a sung take (p2-sing-x5, DSP half;
/// design `docs/design/2026-10-06-p2-sing-expansion.md` §5.4).
///
/// The singing engine has no breathiness input (design §2.3), so DAW Pro adds
/// a soft band of noise to the notes the user chose, AFTER the engine sang
/// and BEFORE the take's loudness gain. It is baked into the take: changing it
/// later re-assembles the take from the phrase cache (no model time) and lands
/// a new one.
///
/// ## What it adds, sample by sample
///
/// Inside a span, at sample `i`:
///
///     out[i] = take[i] + noise(i) × envelope(i) × gain(i)
///
/// * `noise` is white noise from `SplitMix64` (seeded by the take's seed, see
///   `seedSalt`), band-shaped by a 4th-order Butterworth high-pass at
///   `highPassHz` and a 4th-order Butterworth low-pass at `lowPassHz` (each two
///   biquads, plain loops, no Accelerate), then scaled to unit RMS by the
///   cascade's own impulse energy, so `gain` is exactly "how far under the
///   voice".
/// * `envelope` is the take's OWN loudness: the RMS of each
///   `envelopeBlockSeconds` block of the take as it came in, linearly
///   interpolated between block centres. The air rises and falls with the
///   voice, and silence inside a span gets none.
/// * `gain` is the span's plateau, `10^(levelDb / 20)`, reached through ONE
///   raised-cosine ramp of `rampSeconds` (clamped to half the span) INSIDE the
///   span at each edge, the `PitchNoteLevel` shape. Where two air spans abut
///   (the same sample after rounding: legato notes do), the shared edge sits
///   at the MIDPOINT of the two plateaus from both sides, as
///   `PitchEditSet.gain(atSourceSecond:)` does, so the air does not dip
///   between two airy notes.
///
/// ## The two invariants (each has a test, and plant 2 of §5.7 breaks one)
///
/// * ⛔ **OUTSIDE EVERY SPAN, THE TAKE IS BIT-IDENTICAL.** Only samples whose
///   gain is above 0 are written; a sample is never "written back" with `+ 0`
///   (`-0.0 + 0.0` is `+0.0`, a different bit pattern). The ramps sit inside
///   the span, so the sample on a span's first edge is untouched too.
/// * **The same take, spans and seed give the same bytes.** The noise of a run
///   of abutting spans depends only on the seed and the run's first sample, so
///   changing one note's air never re-rolls another note's noise.
///
/// ## Not render material, never on the render thread
///
/// Pure, offline, `Sendable` value types; the sing job calls it in its
/// detached finishing task on a buffer it owns. It allocates (one output
/// copy, one envelope array) and must never be called from an audio callback.
///
/// ## Defaults [A]
///
/// Every number here is an [A] pick (design §5.4; listening round A decides
/// the levels): the band edges, the ramp, the envelope block, the three level
/// anchors. ⚠️ MEASURED 2026-10-06 (W8-X5D): on real SoulX takes the energy
/// above 2 kHz sits about 20 dB under the whole voice, so "a little" (−24 dB)
/// adds only about 1.5 dB above 2 kHz there, short of design §5.7's +3 dB bar;
/// "some" (−18 dB) clears it. Reported for round A; the levels are unchanged.
public enum SungAirLayer {

    /// One stretch of the take that gets air, in the take's own seconds.
    public struct Span: Sendable, Equatable {
        /// Where the air starts and ends, seconds from the start of the take.
        public var startSeconds: Double
        public var endSeconds: Double
        /// How far under the voice the air sits, dB (negative). Use
        /// `levelDb(forAir:)`.
        public var levelDb: Double

        public init(startSeconds: Double, endSeconds: Double, levelDb: Double) {
            self.startSeconds = startSeconds
            self.endSeconds = endSeconds
            self.levelDb = levelDb
        }
    }

    // MARK: - The level scale [A: listening round A]

    /// The Air slider's named points (`SingStyle.air`): "a little", "some",
    /// "lots". ONE home for the UI's marks and the wire's examples.
    public static let airLittle: Double = 1.0 / 3
    public static let airSome: Double = 2.0 / 3
    public static let airLots: Double = 1.0

    /// dB under the voice at `air` = 0+ (the bottom of the scale) and the dB
    /// per unit of `air`: `levelDb = floorDb + dbPerUnit × air`, so a little,
    /// some and lots land on −24, −18 and −12 dB (design §5.4).
    public static let floorDb: Double = -30
    public static let dbPerUnit: Double = 18

    /// The air's level under the voice for `air` (0…1, `SingStyle.airRange`),
    /// or nil for none: 0, a negative, NaN or an infinity add no air. Above 1
    /// reads as 1 (lots).
    public static func levelDb(forAir air: Double) -> Double? {
        guard air.isFinite, air > 0 else { return nil }
        return floorDb + dbPerUnit * min(air, SingStyle.airRange.upperBound)
    }

    // MARK: - The shape [A]

    /// The raised-cosine ramp at each edge of a span, seconds, inside the span
    /// and clamped to half of it.
    public static let rampSeconds: Double = 0.020
    /// The envelope's block, seconds: the take's "10 ms loudness envelope".
    public static let envelopeBlockSeconds: Double = 0.010
    /// The noise band's edges, Hz. The low-pass is capped at 0.45 × the sample
    /// rate and the high-pass kept below it, so any rate gets a valid band.
    public static let highPassHz: Double = 1_500
    public static let lowPassHz: Double = 9_000
    /// Mixed into the take's seed so the air's noise is its own stream ("SungAir1").
    public static let seedSalt: UInt64 = 0x5375_6E67_4169_7231
    /// Noise run through the filters, and thrown away, before a run's first
    /// sample, so a run starts on settled filters.
    public static let warmUpSamples = 4_096

    // MARK: - The pass

    /// `take` with air added inside `spans` (see the type's doc). Returns
    /// `take` unchanged for no spans, an empty take or a sample rate that is
    /// not a positive finite number. Spans are read in the take's seconds,
    /// rounded to the nearest sample, clamped to the take, sorted, and made
    /// non-overlapping first-wins (a later span starts where an earlier one
    /// ends); a span shorter than two samples, or with a non-finite time or
    /// level, adds nothing.
    ///
    /// A non-finite input sample is never "fixed" (the landing gates refuse
    /// such a take), counts as silence in the envelope, and no new non-finite
    /// sample is ever written.
    public static func apply(_ spans: [Span], to take: [Float], sampleRate: Double,
                             seed: UInt64) -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0, !take.isEmpty else { return take }
        let runs = Self.runs(of: spans, count: take.count, sampleRate: sampleRate)
        guard !runs.isEmpty else { return take }

        let envelope = Envelope(take, blockSize: max(1, Int((envelopeBlockSeconds * sampleRate).rounded())))
        let design = BandDesign(sampleRate: sampleRate)
        let rampSamples = max(1, (rampSeconds * sampleRate).rounded())
        var out = take
        for run in runs {
            var rng = SplitMix64(seed: seed ^ seedSalt ^ (UInt64(run[0].start) &* 0x9E37_79B9_7F4A_7C15))
            var band = design.makeFilter()
            for _ in 0..<warmUpSamples { _ = band.process(uniform(&rng)) }
            for (k, span) in run.enumerated() {
                let plateau = pow(10, span.levelDb / 20)
                let before = k == 0 ? 0 : (pow(10, run[k - 1].levelDb / 20) + plateau) / 2
                let after = k + 1 == run.count ? 0 : (plateau + pow(10, run[k + 1].levelDb / 20)) / 2
                let ramp = min(rampSamples, Double(span.end - span.start) / 2)
                for i in span.start..<span.end {
                    // The noise advances on EVERY sample of the run, written or not, so a
                    // sample's noise never depends on which samples around it were written.
                    let noise = band.process(uniform(&rng)) * design.unitRmsScale
                    let into = Double(i - span.start)
                    let beforeEnd = Double(span.end - i)
                    let gain: Double
                    if into < ramp {
                        gain = raisedCosine(from: before, to: plateau, progress: into / ramp)
                    } else if beforeEnd < ramp {
                        gain = raisedCosine(from: after, to: plateau, progress: beforeEnd / ramp)
                    } else {
                        gain = plateau
                    }
                    guard gain > 0 else { continue }
                    let level = envelope.value(at: i)
                    guard level > 0 else { continue }
                    let air = Float(noise * level * gain)
                    guard air.isFinite, air != 0 else { continue }
                    out[i] = take[i] + air
                }
            }
        }
        return out
    }

    // MARK: - Pieces (internal so the tests can read them)

    /// A span in samples, `[start, end)`, with its level.
    struct SampleSpan: Equatable {
        var start: Int
        var end: Int
        var levelDb: Double
    }

    /// `spans` in samples, canonical, grouped into runs of abutting spans.
    static func runs(of spans: [Span], count: Int, sampleRate: Double) -> [[SampleSpan]] {
        var placed: [SampleSpan] = []
        for span in spans {
            guard span.startSeconds.isFinite, span.endSeconds.isFinite, span.levelDb.isFinite else { continue }
            let start = min(max(0, (span.startSeconds * sampleRate).rounded()), Double(count))
            let end = min(max(0, (span.endSeconds * sampleRate).rounded()), Double(count))
            guard end - start >= 2 else { continue }
            placed.append(SampleSpan(start: Int(start), end: Int(end), levelDb: span.levelDb))
        }
        placed.sort { ($0.start, $0.end) < ($1.start, $1.end) }
        var canonical: [SampleSpan] = []
        for var span in placed {
            if let last = canonical.last, span.start < last.end { span.start = last.end }
            guard span.end - span.start >= 2 else { continue }
            canonical.append(span)
        }
        var runs: [[SampleSpan]] = []
        for span in canonical {
            if let last = runs.last?.last, last.end == span.start {
                runs[runs.count - 1].append(span)
            } else {
                runs.append([span])
            }
        }
        return runs
    }

    /// `edge + (plateau − edge) × (½ − ½·cos(π·progress))`: exactly `edge` at
    /// progress 0 (`PitchEditSet.raisedCosine`'s shape).
    static func raisedCosine(from edge: Double, to plateau: Double, progress: Double) -> Double {
        edge + (plateau - edge) * (0.5 - 0.5 * cos(Double.pi * progress))
    }

    /// Uniform in [−1, 1) from the top 53 bits.
    static func uniform(_ rng: inout SplitMix64) -> Double {
        Double(rng.next() >> 11) * 0x1p-53 * 2 - 1
    }

    /// The take's own loudness: block RMS, linearly interpolated between block
    /// centres (flat before the first centre and after the last).
    struct Envelope {
        let blocks: [Double]
        let blockSize: Int

        init(_ take: [Float], blockSize: Int) {
            self.blockSize = blockSize
            var blocks: [Double] = []
            blocks.reserveCapacity(take.count / blockSize + 1)
            var start = 0
            while start < take.count {
                let end = min(start + blockSize, take.count)
                var sum = 0.0
                for i in start..<end {
                    let x = Double(take[i])
                    if x.isFinite { sum += x * x }
                }
                blocks.append((sum / Double(end - start)).squareRoot())
                start = end
            }
            self.blocks = blocks
        }

        func value(at i: Int) -> Double {
            let position = (Double(i) + 0.5) / Double(blockSize) - 0.5
            if position <= 0 { return blocks[0] }
            let lower = Int(position)
            if lower >= blocks.count - 1 { return blocks[blocks.count - 1] }
            let fraction = position - Double(lower)
            return blocks[lower] + (blocks[lower + 1] - blocks[lower]) * fraction
        }
    }

    /// One RBJ biquad, transposed direct form II, in Double.
    struct Biquad {
        var b0 = 0.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
        var z1 = 0.0, z2 = 0.0

        static func highPass(_ hz: Double, q: Double, sampleRate: Double) -> Biquad {
            let w0 = 2 * Double.pi * hz / sampleRate
            let alpha = sin(w0) / (2 * q)
            let c = cos(w0)
            let a0 = 1 + alpha
            return Biquad(b0: (1 + c) / 2 / a0, b1: -(1 + c) / a0, b2: (1 + c) / 2 / a0,
                          a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }

        static func lowPass(_ hz: Double, q: Double, sampleRate: Double) -> Biquad {
            let w0 = 2 * Double.pi * hz / sampleRate
            let alpha = sin(w0) / (2 * q)
            let c = cos(w0)
            let a0 = 1 + alpha
            return Biquad(b0: (1 - c) / 2 / a0, b1: (1 - c) / a0, b2: (1 - c) / 2 / a0,
                          a1: -2 * c / a0, a2: (1 - alpha) / a0)
        }

        mutating func process(_ x: Double) -> Double {
            let y = b0 * x + z1
            z1 = b1 * x - a1 * y + z2
            z2 = b2 * x - a2 * y
            return y
        }
    }

    /// The band: 4th-order Butterworth high-pass then 4th-order Butterworth
    /// low-pass (two biquads each, Q = 0.5412 and 1.3066), and the scale that
    /// makes uniform noise through it unit RMS.
    struct BandDesign {
        static let butterworthQs: [Double] = [0.541_196_100_146_197, 1.306_562_964_876_376_5]
        let highPassHz: Double
        let lowPassHz: Double
        let sampleRate: Double
        /// 1 / (RMS of uniform [−1, 1) noise through the cascade): √3 / √Σh².
        let unitRmsScale: Double

        init(sampleRate: Double) {
            let low = min(SungAirLayer.lowPassHz, 0.45 * sampleRate)
            let high = min(SungAirLayer.highPassHz, 0.5 * low)
            self.sampleRate = sampleRate
            self.lowPassHz = low
            self.highPassHz = high
            var impulse = Filter(stages: Self.stages(highPassHz: high, lowPassHz: low,
                                                     sampleRate: sampleRate))
            var energy = 0.0
            let length = max(16_384, Int(sampleRate / 2))
            for n in 0..<length {
                let h = impulse.process(n == 0 ? 1 : 0)
                energy += h * h
            }
            self.unitRmsScale = energy > 0 ? (3.0 / energy).squareRoot() : 0
        }

        func makeFilter() -> Filter {
            Filter(stages: Self.stages(highPassHz: highPassHz, lowPassHz: lowPassHz, sampleRate: sampleRate))
        }

        static func stages(highPassHz: Double, lowPassHz: Double, sampleRate: Double) -> [Biquad] {
            butterworthQs.map { Biquad.highPass(highPassHz, q: $0, sampleRate: sampleRate) }
                + butterworthQs.map { Biquad.lowPass(lowPassHz, q: $0, sampleRate: sampleRate) }
        }
    }

    /// The four biquads in series.
    struct Filter {
        var stages: [Biquad]

        mutating func process(_ x: Double) -> Double {
            var y = x
            for index in stages.indices { y = stages[index].process(y) }
            return y
        }
    }
}

// MARK: - W9-AIR: air tied to the voice (p2-sing-x9-air, listening round A2)

/// The user heard today's layer as "static across the whole track" (Sung Vocal Picks round A, 2026-10-07): above
/// 4 kHz it is a near-steady hiss on every sung note, because its noise follows only the voice's LOUDNESS. Breath in
/// a real voice is tied to the voice more tightly: it takes on the voice's tone (its spectral envelope) and it beats
/// with each vocal-fold cycle. Hermes 1991 (Speech Communication 10:497-502): high-passed noise whose temporal
/// envelope has the same periodicity as the pulse train fuses with the vowel; unmodulated noise is heard as a
/// separate sound.
///
/// ⛔ INTERNAL: the seam of listening round A2, NOT the product. The sing job calls `apply(_:to:sampleRate:seed:)`,
/// which is `.loudness`, byte for byte; nothing here is reachable from the wire, the MCP or a default. Shipping a
/// coupled method needs a version in the saved style first (an absent field must decode as today's layer).
///
/// Not render material: offline, on a buffer the caller owns, it allocates; never call it from an audio callback.
extension SungAirLayer {

    /// How tightly the air is tied to the voice: round A2's ONE axis, one coupling added per step.
    enum Coupling: String, CaseIterable, Sendable {
        /// Today's layer (`apply(_:to:sampleRate:seed:)`): one band of noise following the voice's loudness.
        case loudness
        /// Also follows the voice's TONE: a bank of `coupledBandCount` bands over the air's band, each band's noise
        /// at the voice's OWN level in that band (10 ms blocks), tilted up `coupledTiltDbPerOctave`, and only on
        /// voiced sound (`voicedWeight`). No pulsing.
        case tone
        /// `.tone`, also beating with each vocal-fold cycle: times the fast envelope of the voice's own top band over
        /// its 10 ms level (`pulseCurve`), so the breath is self-aligned with the voice's own pulses (no pitch track).
        case tonePulse
    }

    /// The bands of the tone bank, log-spaced over the air's band (`highPassHz`…`lowPassHz`, capped as `BandDesign`).
    static let coupledBandCount = 8
    /// The bank's tilt, dB per octave up from the bank's bottom edge: aspiration noise is a flatter source than the
    /// voiced sound, so breath shows most at the top.
    static let coupledTiltDbPerOctave: Double = 6
    /// Voiced sound: the share of a 10 ms block's energy below `voicedSplitHz`, through a smoothstep from
    /// `voicedShareLow` (weight 0) to `voicedShareHigh` (weight 1). "s", "t" and "k" sit far below; vowels above.
    static let voicedSplitHz: Double = 1_000
    static let voicedShareLow: Double = 0.35
    static let voicedShareHigh: Double = 0.65
    /// The pulse: the voice's own band from `pulseBandLowHz` to the air's top, squared, smoothed zero-phase at
    /// `pulseEnvelopeHz` (fast enough to follow a 440 Hz vocal-fold cycle), over its 10 ms RMS, capped at
    /// `pulseCap` (a block-edge guard, not a sound choice).
    static let pulseBandLowHz: Double = 2_000
    static let pulseEnvelopeHz: Double = 800
    static let pulseCap: Double = 4

    /// `take` with air added inside `spans`, tied to the voice as `coupling` says. `.loudness` IS
    /// `apply(_:to:sampleRate:seed:)`. The coupled methods keep its rules: outside every span the take is
    /// bit-identical (and so is any non-finite input sample, anywhere); the same take, spans and seed give the same
    /// bytes; no new non-finite, subnormal or zero sample is written. Their LEVEL is matched to today's layer: the
    /// added energy over the whole take equals today's expected energy for the same spans (a whole-take match, so
    /// one note's air depends on the rest of the take: right for a listening round, NOT shippable as is).
    static func apply(_ spans: [Span], to take: [Float], sampleRate: Double, seed: UInt64,
                      coupling: Coupling) -> [Float] {
        switch coupling {
        case .loudness: return apply(spans, to: take, sampleRate: sampleRate, seed: seed)
        case .tone: return applyCoupled(spans, to: take, sampleRate: sampleRate, seed: seed, pulsed: false)
        case .tonePulse: return applyCoupled(spans, to: take, sampleRate: sampleRate, seed: seed, pulsed: true)
        }
    }

    static func applyCoupled(_ spans: [Span], to take: [Float], sampleRate: Double, seed: UInt64,
                             pulsed: Bool) -> [Float] {
        guard sampleRate.isFinite, sampleRate > 0, !take.isEmpty else { return take }
        let runs = Self.runs(of: spans, count: take.count, sampleRate: sampleRate)
        guard !runs.isEmpty else { return take }

        let blockSize = max(1, Int((envelopeBlockSeconds * sampleRate).rounded()))
        let voice = take.map { $0.isFinite ? Double($0) : 0 }
        let loudness = Envelope(take, blockSize: blockSize)
        let bank = ToneBank(sampleRate: sampleRate)
        let voiced = BlockCurve(blocks: voicedWeights(voice, blockSize: blockSize, sampleRate: sampleRate),
                                blockSize: blockSize)
        var bandLevels: [BlockCurve] = []
        bandLevels.reserveCapacity(bank.bands.count)
        var scratch = [Double](repeating: 0, count: voice.count)
        for band in bank.bands {
            var filter = band.makeFilter()
            for i in voice.indices { scratch[i] = filter.process(voice[i]) }
            bandLevels.append(BlockCurve(blocks: blockRMS(scratch, blockSize: blockSize), blockSize: blockSize))
        }
        let pulse = pulsed ? pulseCurve(voice, blockSize: blockSize, sampleRate: sampleRate) : nil
        let weights = bank.bands.map { $0.unitRmsScale * $0.tilt }

        // Pass 1: the unscaled air, today's expected energy for the same spans (`target`), and the air's own.
        let rampSamples = max(1, (rampSeconds * sampleRate).rounded())
        var air = scratch
        for i in air.indices { air[i] = 0 }
        var target = 0.0
        var energy = 0.0
        for run in runs {
            var rng = SplitMix64(seed: seed ^ seedSalt ^ (UInt64(run[0].start) &* 0x9E37_79B9_7F4A_7C15))
            var filters = bank.bands.map { $0.makeFilter() }
            for _ in 0..<warmUpSamples {
                let u = uniform(&rng)
                for b in filters.indices { _ = filters[b].process(u) }
            }
            for (k, span) in run.enumerated() {
                let plateau = pow(10, span.levelDb / 20)
                let before = k == 0 ? 0 : (pow(10, run[k - 1].levelDb / 20) + plateau) / 2
                let after = k + 1 == run.count ? 0 : (plateau + pow(10, run[k + 1].levelDb / 20)) / 2
                let ramp = min(rampSamples, Double(span.end - span.start) / 2)
                for i in span.start..<span.end {
                    // The noise advances on EVERY sample of the run, as in today's layer.
                    let u = uniform(&rng)
                    var shaped = 0.0
                    for b in filters.indices {
                        shaped += filters[b].process(u) * weights[b] * bandLevels[b].value(at: i)
                    }
                    let into = Double(i - span.start)
                    let beforeEnd = Double(span.end - i)
                    let gain: Double
                    if into < ramp {
                        gain = raisedCosine(from: before, to: plateau, progress: into / ramp)
                    } else if beforeEnd < ramp {
                        gain = raisedCosine(from: after, to: plateau, progress: beforeEnd / ramp)
                    } else {
                        gain = plateau
                    }
                    guard gain > 0 else { continue }
                    let level = loudness.value(at: i)
                    guard level > 0 else { continue }
                    target += (gain * level) * (gain * level)
                    var value = shaped * gain * voiced.value(at: i)
                    if let pulse { value *= pulse[i] }
                    guard value.isFinite else { continue }
                    air[i] = value
                    energy += value * value
                }
            }
        }
        guard target > 0, energy > 0, target.isFinite, energy.isFinite else { return take }

        // Pass 2: scale to today's energy and write; outside the spans `air` is 0 and nothing is written.
        let scale = (target / energy).squareRoot()
        var out = take
        for run in runs {
            for span in run {
                for i in span.start..<span.end where air[i] != 0 && take[i].isFinite {
                    let added = Float(air[i] * scale)
                    guard added.isNormal else { continue }
                    let sum = take[i] + added
                    guard sum.isFinite else { continue }
                    out[i] = sum
                }
            }
        }
        return out
    }

    // MARK: Pieces of the coupled methods (internal so the tests can read them)

    /// A per-block value, read between block centres exactly as `Envelope.value(at:)` reads its blocks.
    struct BlockCurve {
        let blocks: [Double]
        let blockSize: Int

        func value(at i: Int) -> Double {
            guard !blocks.isEmpty else { return 0 }
            let position = (Double(i) + 0.5) / Double(blockSize) - 0.5
            if position <= 0 { return blocks[0] }
            let lower = Int(position)
            if lower >= blocks.count - 1 { return blocks[blocks.count - 1] }
            let fraction = position - Double(lower)
            return blocks[lower] + (blocks[lower + 1] - blocks[lower]) * fraction
        }
    }

    /// RMS of each `blockSize` block (the last may be short).
    static func blockRMS(_ x: [Double], blockSize: Int) -> [Double] {
        var blocks: [Double] = []
        blocks.reserveCapacity(x.count / blockSize + 1)
        var start = 0
        while start < x.count {
            let end = min(start + blockSize, x.count)
            var sum = 0.0
            for i in start..<end { sum += x[i] * x[i] }
            blocks.append((sum / Double(end - start)).squareRoot())
            start = end
        }
        return blocks
    }

    /// 0…1 per block: how much of the block is voiced sound (see `voicedSplitHz`). A silent block is 0.
    static func voicedWeights(_ voice: [Double], blockSize: Int, sampleRate: Double) -> [Double] {
        let split = min(voicedSplitHz, 0.45 * sampleRate)
        var low = Filter(stages: BandDesign.butterworthQs.map { Biquad.lowPass(split, q: $0, sampleRate: sampleRate) })
        var weights: [Double] = []
        weights.reserveCapacity(voice.count / blockSize + 1)
        var start = 0
        while start < voice.count {
            let end = min(start + blockSize, voice.count)
            var all = 0.0
            var below = 0.0
            for i in start..<end {
                let x = voice[i]
                let y = low.process(x)
                all += x * x
                below += y * y
            }
            weights.append(all > 0 ? voicedWeight(share: below / all) : 0)
            start = end
        }
        return weights
    }

    /// The smoothstep from `voicedShareLow` to `voicedShareHigh`; a non-finite share is 0.
    static func voicedWeight(share: Double) -> Double {
        guard share.isFinite else { return 0 }
        let t = min(max((share - voicedShareLow) / (voicedShareHigh - voicedShareLow), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Per sample: the voice's own top-band envelope (fast) over its 10 ms RMS, 0 where that band is silent.
    static func pulseCurve(_ voice: [Double], blockSize: Int, sampleRate: Double) -> [Double] {
        let top = min(lowPassHz, 0.45 * sampleRate)
        let bottom = min(pulseBandLowHz, 0.5 * top)
        let band = zeroPhase(voice, stages: BandDesign.stages(highPassHz: bottom, lowPassHz: top,
                                                               sampleRate: sampleRate))
        let slow = BlockCurve(blocks: blockRMS(band, blockSize: blockSize), blockSize: blockSize)
        var power = band
        for i in power.indices { power[i] = band[i] * band[i] }
        let smooth = zeroPhase(power, stages: [Biquad.lowPass(min(pulseEnvelopeHz, 0.45 * sampleRate),
                                                              q: 0.5.squareRoot(), sampleRate: sampleRate)])
        var pulse = smooth
        for i in pulse.indices {
            let level = slow.value(at: i)
            let ratio = level > 0 ? max(0, smooth[i]).squareRoot() / level : 0
            pulse[i] = ratio.isFinite ? min(ratio, pulseCap) : 0
        }
        return pulse
    }

    /// `x` through `stages` forward, then backward (zero phase, the magnitude squared).
    static func zeroPhase(_ x: [Double], stages: [Biquad]) -> [Double] {
        var y = x
        var forward = Filter(stages: stages)
        for i in y.indices { y[i] = forward.process(y[i]) }
        var backward = Filter(stages: stages)
        for i in y.indices.reversed() { y[i] = backward.process(y[i]) }
        return y
    }

    /// The tone bank: `coupledBandCount` log-spaced bands over the air's band, each a 4th-order Butterworth
    /// high-pass and low-pass (as `BandDesign`), with its unit-RMS scale and its tilt.
    struct ToneBank {
        struct Band {
            let lowHz: Double
            let highHz: Double
            let stages: [Biquad]
            /// 1 / (RMS of uniform [−1, 1) noise through the band).
            let unitRmsScale: Double
            /// Amplitude factor of the tilt at the band's centre.
            let tilt: Double

            func makeFilter() -> Filter { Filter(stages: stages) }
        }

        let bands: [Band]

        init(sampleRate: Double) {
            let top = min(SungAirLayer.lowPassHz, 0.45 * sampleRate)
            let bottom = min(SungAirLayer.highPassHz, 0.5 * top)
            let count = SungAirLayer.coupledBandCount
            let ratio = pow(top / bottom, 1 / Double(count))
            let exponent = SungAirLayer.coupledTiltDbPerOctave / (20 * log10(2.0))
            var bands: [Band] = []
            for k in 0..<count {
                let low = bottom * pow(ratio, Double(k))
                let high = bottom * pow(ratio, Double(k + 1))
                let stages = BandDesign.stages(highPassHz: low, lowPassHz: high, sampleRate: sampleRate)
                var impulse = Filter(stages: stages)
                var energy = 0.0
                for n in 0..<max(16_384, Int(sampleRate / 2)) {
                    let h = impulse.process(n == 0 ? 1 : 0)
                    energy += h * h
                }
                bands.append(Band(lowHz: low, highHz: high, stages: stages,
                                  unitRmsScale: energy > 0 ? (3 / energy).squareRoot() : 0,
                                  tilt: pow((low * high).squareRoot() / bottom, exponent)))
            }
            self.bands = bands
        }
    }
}
