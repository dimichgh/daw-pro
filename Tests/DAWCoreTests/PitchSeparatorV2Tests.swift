import Foundation
import Testing

@testable import DAWCore

/// Natural tuning §3b / §3g **G1** (W7-C3): the drift/wobble separator v2, and
/// the branch that keeps every equal-scale render bit for bit.
///
/// Three parts, each with the control that must come out the other way:
///  * **§A EQUAL SCALES STAY BIT FOR BIT.** `PitchCorrectionCurve.make` keeps
///    the v1 lines for every note whose `driftScale == vibratoScale`, which is
///    every set the product has ever written. `FrozenV1Shaping` below is a
///    FROZEN copy of those lines (the `PrePitchNoteSplitReference` pattern: it
///    must never track the product). The product's stored shaping samples must
///    equal it bit for bit on 0/0, 0.5/0.5 and 1.7/1.7, also when an unequal
///    note sits in the same set. Negative control: the unequal note must NOT
///    equal it. Plant, run once and recorded in the lane's STATUS: routing equal
///    notes through v2 turns §A red.
///  * **§B THE KERNEL**, `PitchCorrectionMath.triangularAverage`, on known
///    signals: DC gain 1, the interior impulse response IS the triangle, the
///    discrete sinc² response at 0.5 / 1 / 3 / 4 / 5.5 / 8 Hz, never negative
///    on a 0-15 Hz sweep (control: the v1 boxcar reads −0.2155 at 5.5 Hz, so
///    the sweep can see an inversion), both edge rules, NaN, subnormal and
///    degenerate inputs.
///  * **§C THE ONE PREDICATE**: `NoteSegment.takesSeparatedShaping`,
///    `PitchEditSet.needsSeparatedShaping`, `PitchRenderContour.shapingVersion(for:)`,
///    and the curve's branch agreeing with them.
///
/// Pure DAWCore arithmetic: no render, no actor.
@Suite("Natural tuning §3 G1 — separator v2 and the equal-scale branch (W7-C3)")
struct PitchSeparatorV2Tests {

    // MARK: - The frozen v1 lines

    /// ⛔ **FROZEN.** `PitchCorrectionCurve.make`'s contour-shaping lines for ONE
    /// segment, with `PitchCorrectionMath.movingAverage`, `.cents` and `.finite`
    /// inlined, VERBATIM as they stood before W7-C3 (tree `813c415` + the wave-7
    /// working tree, 2026-09-27 05:45 PDT). It is the oracle §A compares the
    /// product against, so it must NEVER be edited to follow the product. If the
    /// equal-scale branch ever changes on purpose, `PitchRenderContour
    /// .shapingVersion` is bumped in the same change and this oracle is retired
    /// with a note, never quietly updated.
    enum FrozenV1Shaping {
        struct Samples: Equatable {
            let startSeconds: Double
            let stepSeconds: Double
            let semitones: [Double]
        }

        /// What `make` stored for `segment`: the empty samples (0, 0, []) when the
        /// segment asks for no shaping or cannot be shaped.
        static func samples(segment: NoteSegment, contour: [ClipPitchFrame],
                            contourValueOffsetSeconds: Double) -> Samples {
            let valueOffset = finite(contourValueOffsetSeconds, default: 0)
            let voiced = contour
                .filter { $0.frequencyHz != nil }
                .sorted { $0.timeSeconds < $1.timeSeconds }
            var shaping: [Double] = []
            var shapingStart = 0.0
            var shapingStep = 0.0
            if segment.driftScale != 1 || segment.vibratoScale != 1 {
                let frames = voiced.filter {
                    $0.timeSeconds >= segment.startSeconds && $0.timeSeconds < segment.endSeconds
                }
                if frames.count >= 2, segment.detectedHz > 0 {
                    let step = (frames[frames.count - 1].timeSeconds - frames[0].timeSeconds)
                        / Double(frames.count - 1)
                    if step > 0 {
                        let cents = frames.map {
                            Self.cents(from: segment.detectedHz,
                                       to: $0.frequencyHz ?? segment.detectedHz)
                        }
                        let drift = movingAverage(cents, windowSeconds: 0.25, stepSeconds: step)
                        shaping = zip(cents, drift).map { total, macro in
                            let vibrato = total - macro
                            return ((segment.driftScale - 1) * macro
                                + (segment.vibratoScale - 1) * vibrato) / 100
                        }
                        shapingStart = frames[0].timeSeconds + valueOffset
                        shapingStep = step
                    }
                }
            }
            return Samples(startSeconds: shapingStart, stepSeconds: shapingStep, semitones: shaping)
        }

        static func finite(_ value: Double, default fallback: Double) -> Double {
            value.isFinite ? value : fallback
        }

        static func cents(from: Double, to: Double) -> Double {
            guard from.isFinite, to.isFinite, from > 0, to > 0 else { return 0 }
            return 1200 * log2(to / from)
        }

        static func movingAverage(_ values: [Double],
                                  windowSeconds: Double,
                                  stepSeconds: Double) -> [Double] {
            guard !values.isEmpty else { return [] }
            guard stepSeconds > 0, windowSeconds > 0 else { return values }
            let halfWidth = max(0, Int((windowSeconds / stepSeconds / 2).rounded()))
            guard halfWidth > 0 else { return values }
            var out = [Double](repeating: 0, count: values.count)
            for i in values.indices {
                let low = max(0, i - halfWidth)
                let high = min(values.count - 1, i + halfWidth)
                var sum = 0.0
                for j in low...high { sum += values[j] }
                out[i] = sum / Double(high - low + 1)
            }
            return out
        }
    }

    // MARK: - Fixture

    static let frameStep = 0.016

    /// A detector-like contour: 62.5 frames per second from 0 to 4 s, a slow
    /// wander, a 5.5 Hz wobble and a fast 13 Hz ripple, with an UNVOICED hole at
    /// [1.5, 1.6) s (a hole ends a note; no frame is invented for it).
    static func contour() -> [ClipPitchFrame] {
        var frames: [ClipPitchFrame] = []
        var t = 0.0
        var index = 0
        while t < 4.0 {
            if t >= 1.5 && t < 1.6 {
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: nil, confidence: 0.2,
                                             levelDbfs: -30, absence: .belowConfidence))
            } else {
                let cents = 20 * sin(2 * .pi * 0.5 * t) + 35 * sin(2 * .pi * 5.5 * t + 0.3)
                    + 3 * sin(2 * .pi * 13 * t)
                frames.append(ClipPitchFrame(timeSeconds: t, frequencyHz: 220 * pow(2, cents / 1200),
                                             confidence: 0.95, levelDbfs: -12, absence: nil))
            }
            index += 1
            t = Double(index) * frameStep
        }
        return frames
    }

    static func note(_ start: Double, _ end: Double, drift: Double, vibrato: Double,
                     hz: Double = 221.3) -> NoteSegment {
        NoteSegment(startSeconds: start, endSeconds: end, detectedHz: hz, detectedConfidence: 0.95,
                    pitchOffsetCents: -12, driftScale: drift, vibratoScale: vibrato)
    }

    /// Three notes: before the hole, after it, and a third abutting the second.
    static func set(_ scales: [(Double, Double)]) -> PitchEditSet {
        precondition(scales.count == 3)
        return PitchEditSet(segments: [
            note(0.1, 1.5, drift: scales[0].0, vibrato: scales[0].1),
            note(1.6, 2.6, drift: scales[1].0, vibrato: scales[1].1),
            note(2.6, 3.9, drift: scales[2].0, vibrato: scales[2].1),
        ], retuneMs: 30)
    }

    static func product(_ set: PitchEditSet, offset: Double,
                        separator: PitchCorrectionCurve.Separator = .production)
        -> [FrozenV1Shaping.Samples] {
        let curve = PitchCorrectionCurve.make(editSet: set, contour: contour(),
                                              contourValueOffsetSeconds: offset,
                                              separator: separator)
        return curve.shapingSamplesForTesting.map {
            FrozenV1Shaping.Samples(startSeconds: $0.startSeconds, stepSeconds: $0.stepSeconds,
                                    semitones: $0.semitones)
        }
    }

    static func frozen(_ set: PitchEditSet, offset: Double) -> [FrozenV1Shaping.Samples] {
        set.segments.map {
            FrozenV1Shaping.samples(segment: $0, contour: contour(), contourValueOffsetSeconds: offset)
        }
    }

    /// Bit-for-bit equality of two sample blocks (`==` would let −0.0 match
    /// 0.0 and would fail on NaN == NaN).
    static func bitIdentical(_ a: FrozenV1Shaping.Samples, _ b: FrozenV1Shaping.Samples) -> Bool {
        a.startSeconds.bitPattern == b.startSeconds.bitPattern
            && a.stepSeconds.bitPattern == b.stepSeconds.bitPattern
            && a.semitones.count == b.semitones.count
            && zip(a.semitones, b.semitones).allSatisfy { $0.bitPattern == $1.bitPattern }
    }

    // MARK: - §A equal scales stay bit for bit

    @Test("§A equal-scale notes store the frozen v1 shaping bit for bit (0/0, 0.5/0.5, 1.7/1.7)",
          arguments: [0.0, 0.5 / 62.5])
    func equalScalesAreBitIdenticalToTheFrozenLines(offset: Double) {
        let set = Self.set([(0, 0), (0.5, 0.5), (1.7, 1.7)])
        let product = Self.product(set, offset: offset)
        let frozen = Self.frozen(set, offset: offset)
        #expect(product.count == 3 && frozen.count == 3)
        for (index, (p, f)) in zip(product, frozen).enumerated() {
            #expect(!f.semitones.isEmpty, "note \(index): the fixture shaped nothing, so this proves nothing")
            #expect(Self.bitIdentical(p, f),
                    "note \(index) (\(set.segments[index].driftScale)/\(set.segments[index].vibratoScale)) left the frozen v1 lines: equal scales must never reach the v2 separator")
        }
        // Every separator agrees on equal scales: no test value can reach the branch.
        for separator: PitchCorrectionCurve.Separator in [
            .v1Everywhere, .triangular(windowSeconds: 0.16, edge: .reflect), .kernelTaps([0.25, 0.5, 0.25]),
        ] {
            let other = Self.product(set, offset: offset, separator: separator)
            let agrees = other.count == frozen.count
                && zip(other, frozen).allSatisfy { Self.bitIdentical($0.0, $0.1) }
            #expect(agrees, "separator \(separator) reached an equal-scale note")
        }
    }

    @Test("§A an unequal note beside equal ones: the equal ones stay frozen, the unequal one does NOT")
    func unequalNoteDoesNotDisturbItsEqualNeighbours() {
        let set = Self.set([(0.5, 0.5), (0, 1), (1.7, 1.7)])
        let offset = 0.5 / 62.5
        let product = Self.product(set, offset: offset)
        let frozen = Self.frozen(set, offset: offset)
        #expect(Self.bitIdentical(product[0], frozen[0]))
        #expect(Self.bitIdentical(product[2], frozen[2]))
        // NEGATIVE CONTROL: the unequal note takes v2 and differs from v1.
        #expect(!Self.bitIdentical(product[1], frozen[1]),
                "an unequal (0/1) note stored the v1 shaping: the v2 separator never ran")
        #expect(product[1].semitones.count == frozen[1].semitones.count)
        #expect(product[1].startSeconds.bitPattern == frozen[1].startSeconds.bitPattern)
        // And the v1 seam IS today's arithmetic: G3's negative control renders v1, not a lookalike.
        let v1 = Self.product(set, offset: offset, separator: .v1Everywhere)
        #expect(Self.bitIdentical(v1[1], frozen[1]),
                "Separator.v1Everywhere is not the frozen v1 arithmetic")
    }

    @Test("§A null: a contour exactly at the detected centre shapes to exact zeros under every separator")
    func centredContourShapesToZero() {
        let frames = (0..<200).map {
            ClipPitchFrame(timeSeconds: Double($0) * Self.frameStep, frequencyHz: 220, confidence: 0.95,
                           levelDbfs: -12, absence: nil)
        }
        for (drift, vibrato) in [(0.0, 0.0), (0.0, 1.0), (1.0, 0.0), (2.5, 0.3)] {
            let set = PitchEditSet(segments: [
                NoteSegment(startSeconds: 0, endSeconds: 3.2, detectedHz: 220, detectedConfidence: 0.95,
                            driftScale: drift, vibratoScale: vibrato)
            ], retuneMs: 30)
            let samples = PitchCorrectionCurve.make(editSet: set, contour: frames).shapingSamplesForTesting
            #expect(samples.count == 1 && samples[0].semitones.count == 200)
            #expect(samples[0].semitones.allSatisfy { $0 == 0 },
                    "\(drift)/\(vibrato): a contour with no movement was shaped")
        }
    }

    // MARK: - §B the kernel on known signals

    static let window = 0.25
    /// h = round(0.25 / 0.016 / 2) = 8, M = 2h + 1 = 17 taps per boxcar.
    static let m = 17

    /// The discrete triangle's response: the boxcar's, squared.
    static func triangleResponse(_ f: Double, m: Int = m, step: Double = frameStep) -> Double {
        let boxcar = sin(.pi * f * Double(m) * step) / (Double(m) * sin(.pi * f * step))
        return f == 0 ? 1 : boxcar * boxcar
    }

    /// The gain a centred average gives a long cosine at `f`, read on the
    /// interior (a symmetric kernel on a cosine returns H(f)·cosine exactly).
    static func measuredGain(_ f: Double, average: ([Double]) -> [Double]) -> Double {
        let n = 1500
        let x = (0..<n).map { cos(2 * .pi * f * Double($0) * frameStep) }
        let y = average(x)
        var num = 0.0, den = 0.0
        for i in 100..<(n - 100) { num += x[i] * y[i]; den += x[i] * x[i] }
        return num / den
    }

    @Test("§B DC gain is 1 on both edges, and the interior impulse response IS the triangle")
    func dcGainAndImpulseResponse() {
        for edge in PitchCorrectionMath.AverageEdge.allCases {
            let flat = PitchCorrectionMath.triangularAverage(
                [Double](repeating: 0.1, count: 120), windowSeconds: Self.window,
                stepSeconds: Self.frameStep, edge: edge)
            #expect(flat.count == 120)
            #expect(flat.allSatisfy { abs($0 - 0.1) <= 1e-15 }, "\(edge): DC gain is not 1")
        }
        var impulse = [Double](repeating: 0, count: 121)
        impulse[60] = 1
        let response = PitchCorrectionMath.triangularAverage(
            impulse, windowSeconds: Self.window, stepSeconds: Self.frameStep, edge: .truncate)
        for k in -40...40 {
            let expected = abs(k) <= Self.m - 1
                ? Double(Self.m - abs(k)) / Double(Self.m * Self.m) : 0
            #expect(response[60 + k].bitPattern == expected.bitPattern,
                    "tap \(k): \(response[60 + k]) vs \(expected)")
        }
        #expect(abs(response.reduce(0, +) - 1) < 1e-13)
    }

    @Test("§B the response is sinc², at the design's key points and on the measured signal")
    func frequencyResponseAtKeyPoints() {
        // [sin(πfMT) / (M·sin(πfT))]², M = 17, T = 16 ms, to 6 places (the
        // design §3b's 4-place figures, 0.9408 … 0.0062, one rounding coarser).
        let expected: [(Double, Double)] = [(0.5, 0.940811), (1, 0.779759), (3, 0.045775),
                                            (4, 0.006464), (5.5, 0.046437), (8, 0.006231)]
        for (f, h) in expected {
            let analytic = Self.triangleResponse(f)
            let measured = Self.measuredGain(f) {
                PitchCorrectionMath.triangularAverage($0, windowSeconds: Self.window,
                                                      stepSeconds: Self.frameStep, edge: .truncate)
            }
            #expect(abs(analytic - h) < 1e-6, "\(f) Hz: analytic \(analytic) vs the table's \(h)")
            #expect(abs(measured - analytic) < 1e-6, "\(f) Hz: measured \(measured) vs analytic \(analytic)")
        }
    }

    @Test("§B never negative from 0 to 15 Hz; the v1 boxcar IS negative at 5.5 Hz (the control)")
    func neverInvertsWhereTheBoxcarDoes() {
        var worst = Double.infinity
        for step in 1...75 {
            let f = Double(step) * 0.2
            let gain = Self.measuredGain(f) {
                PitchCorrectionMath.triangularAverage($0, windowSeconds: Self.window,
                                                      stepSeconds: Self.frameStep, edge: .reflect)
            }
            worst = min(worst, gain)
        }
        #expect(worst > -1e-9, "the v2 kernel inverted some band: minimum gain \(worst)")
        let boxcar = Self.measuredGain(5.5) {
            PitchCorrectionMath.movingAverage($0, windowSeconds: 0.25, stepSeconds: Self.frameStep)
        }
        #expect(abs(boxcar - (-0.215492)) < 1e-5,
                "control: the v1 boxcar should read −0.215492 at 5.5 Hz, read \(boxcar)")
    }

    @Test("§B edges: truncate renormalises what is in reach, reflect mirrors the note")
    func edgeRules() {
        // Truncate, impulse at the first frame: out[0] = M / (M(M+1)/2) = 2/(M+1).
        var first = [Double](repeating: 0, count: 80)
        first[0] = 1
        let truncated = PitchCorrectionMath.triangularAverage(
            first, windowSeconds: Self.window, stepSeconds: Self.frameStep, edge: .truncate)
        #expect(abs(truncated[0] - 2.0 / Double(Self.m + 1)) < 1e-15)
        // Reflect, impulse at frame 1: x[−1] mirrors x[1], so out[0] = 2(M−1)/M².
        var second = [Double](repeating: 0, count: 80)
        second[1] = 1
        let reflected = PitchCorrectionMath.triangularAverage(
            second, windowSeconds: Self.window, stepSeconds: Self.frameStep, edge: .reflect)
        #expect(abs(reflected[0] - 2.0 * Double(Self.m - 1) / Double(Self.m * Self.m)) < 1e-15)
        // Reflect keeps a symmetric note symmetric.
        let symmetric = (0..<41).map { 5 * cos(Double($0 - 20) * 0.37) + Double(abs($0 - 20)) }
        let mirrored = PitchCorrectionMath.triangularAverage(
            symmetric, windowSeconds: Self.window, stepSeconds: Self.frameStep, edge: .reflect)
        for i in 0..<41 { #expect(abs(mirrored[i] - mirrored[40 - i]) < 1e-12) }
        // A note SHORTER than the kernel: reflection repeats, against a brute-force reference.
        let short = [3.0, -1.0, 2.0]
        let out = PitchCorrectionMath.triangularAverage(
            short, windowSeconds: Self.window, stepSeconds: Self.frameStep, edge: .reflect)
        func pingPong(_ j: Int) -> Int {
            let period = 4
            let r = ((j % period) + period) % period
            return r < 3 ? r : period - r
        }
        for i in 0..<3 {
            var sum = 0.0, norm = 0.0
            for k in -(Self.m - 1)...(Self.m - 1) {
                let w = Double(Self.m - abs(k))
                sum += w * short[pingPong(i + k)]
                norm += w
            }
            #expect(abs(out[i] - sum / norm) < 1e-12, "short note frame \(i)")
        }
        #expect(PitchCorrectionMath.triangularAverage([4.5], windowSeconds: Self.window,
                                                      stepSeconds: Self.frameStep, edge: .reflect) == [4.5])
    }

    @Test("§B totality: NaN is left out, subnormals stay finite, degenerate inputs return the input")
    func totality() {
        var withNaN = (0..<60).map { sin(Double($0) * 0.2) }
        withNaN[30] = .nan
        for edge in PitchCorrectionMath.AverageEdge.allCases {
            let out = PitchCorrectionMath.triangularAverage(
                withNaN, windowSeconds: Self.window, stepSeconds: Self.frameStep, edge: edge)
            #expect(out.allSatisfy { $0.isFinite }, "\(edge): a NaN leaked into the drift")
        }
        let out = PitchCorrectionMath.triangularAverage(
            withNaN, windowSeconds: Self.window, stepSeconds: Self.frameStep, edge: .truncate)
        var sum = 0.0, norm = 0.0
        for k in -(Self.m - 1)...(Self.m - 1) where k != 0 {
            let w = Double(Self.m - abs(k))
            sum += w * withNaN[30 + k]
            norm += w
        }
        #expect(abs(out[30] - sum / norm) < 1e-12, "the NaN frame is not the average of the rest")
        let tiny = PitchCorrectionMath.triangularAverage(
            [Double](repeating: 1e-310, count: 50), windowSeconds: Self.window,
            stepSeconds: Self.frameStep, edge: .truncate)
        #expect(tiny.allSatisfy { $0.isFinite && $0 >= 0 })
        #expect(PitchCorrectionMath.triangularAverage([], windowSeconds: 0.25, stepSeconds: 0.016,
                                                      edge: .truncate).isEmpty)
        let input = [1.0, 2.0, 4.0]
        for (w, s) in [(0.0, 0.016), (0.25, 0.0), (.nan, 0.016), (0.25, .infinity), (0.01, 0.016)] {
            #expect(PitchCorrectionMath.triangularAverage(input, windowSeconds: w, stepSeconds: s,
                                                          edge: .truncate) == input, "(\(w), \(s))")
        }
    }

    // MARK: - §C the one predicate

    @Test("§C takesSeparatedShaping, needsSeparatedShaping and the per-set shaping version")
    func thePredicateAndTheVersion() {
        // `at` places each note in its own second: a set heals overlaps
        // FIRST-WINS (`PitchEditSet.canonical`), so notes sharing one span
        // would collapse to the first and the set would say nothing.
        func seg(_ d: Double, _ v: Double, at second: Double = 0) -> NoteSegment {
            NoteSegment(startSeconds: second, endSeconds: second + 1, detectedHz: 220,
                        detectedConfidence: 1, driftScale: d, vibratoScale: v)
        }
        #expect(!seg(1, 1).takesSeparatedShaping)
        #expect(!seg(0, 0).takesSeparatedShaping)
        #expect(!seg(0.5, 0.5).takesSeparatedShaping)
        #expect(!seg(-0.0, 0).takesSeparatedShaping, "−0.0 and 0 are equal scales")
        #expect(seg(0, 1).takesSeparatedShaping)
        #expect(seg(1, 0).takesSeparatedShaping)
        #expect(seg(0.5, 0.25).takesSeparatedShaping)

        #expect(PitchRenderContour.shapingVersion == 1)
        #expect(PitchRenderContour.separatedShapingVersion == 2)
        let equal = PitchEditSet(segments: [seg(0, 0), seg(0.5, 0.5, at: 1), seg(1, 1, at: 2)], retuneMs: 30)
        let mixed = PitchEditSet(segments: [seg(0, 0), seg(0, 1, at: 1), seg(1, 1, at: 2)], retuneMs: 30)
        #expect(equal.segments.count == 3 && mixed.segments.count == 3, "the fixture lost a note")
        #expect(!equal.needsSeparatedShaping && mixed.needsSeparatedShaping)
        #expect(!PitchEditSet.empty.needsSeparatedShaping)
        #expect(PitchRenderContour.shapingVersion(for: nil) == 1)
        #expect(PitchRenderContour.shapingVersion(for: equal) == 1)
        #expect(PitchRenderContour.shapingVersion(for: mixed) == 2)
        #expect(PitchRenderContour.shapingVersion(for: PitchEditSet(segments: [seg(1, 0)], retuneMs: 30)) == 2)
    }

    @Test("§C the branch IS the predicate: v1 lines iff the note does not take separated shaping")
    func branchFollowsThePredicate() {
        let pairs: [(Double, Double)] = [(0, 0), (0, 1), (1, 0), (0.3, 0.3), (0.3, 0.31), (2, 2),
                                         (4, 0), (1, 1.0000001), (1.7, 1.7)]
        for (d, v) in pairs {
            let set = Self.set([(d, v), (0.5, 0.5), (1, 1)])
            let product = Self.product(set, offset: 0)
            let frozen = Self.frozen(set, offset: 0)
            let takesV2 = set.segments[0].takesSeparatedShaping
            #expect(Self.bitIdentical(product[0], frozen[0]) == !takesV2,
                    "\(d)/\(v): takesSeparatedShaping says \(takesV2) but the curve disagrees")
        }
    }

    @Test("§C the separator seams: .production is the picked kernel, .triangular is triangularAverage")
    func separatorSeams() {
        let set = Self.set([(0.5, 0.5), (0, 1), (1.7, 1.7)])
        let production = Self.product(set, offset: 0)
        let picked = Self.product(set, offset: 0, separator: .triangular(
            windowSeconds: PitchCorrectionCurve.separatedDriftWindowSeconds,
            edge: PitchCorrectionCurve.separatedDriftEdge))
        let agrees = production.count == 3 && picked.count == 3
            && zip(production, picked).allSatisfy { Self.bitIdentical($0.0, $0.1) }
        #expect(agrees, ".production is not the picked kernel")
        // A window 0.1 s longer is ≥ 3 more taps a side at 16 ms frames, so it
        // MUST move the unequal note, and must not touch the equal ones.
        let other = Self.product(set, offset: 0, separator: .triangular(
            windowSeconds: PitchCorrectionCurve.separatedDriftWindowSeconds + 0.1,
            edge: PitchCorrectionCurve.separatedDriftEdge))
        #expect(!Self.bitIdentical(other[1], production[1]),
                "a different window changed nothing on the unequal note: the seam is dead")
        #expect(Self.bitIdentical(other[0], production[0]) && Self.bitIdentical(other[2], production[2]))
    }
}
