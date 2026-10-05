import Foundation
import Testing
@testable import DAWCore

// m23-ap C5a-0b — T5 `sungWobbleMeasurement`: THE ESTIMATOR'S ARITHMETIC,
// AGAINST ITS OWN INFORMATION LIMIT. Design
// `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §18.1.1 (supersedes
// §8.5(a)), §18.1.3–§18.1.5, §15 T5. Source: `Sources/DAWCore/PitchWobbleEstimate.swift`.
//
// ═══════════════════════════════════════════════════════════════════════════
// WHAT THIS SUITE IS FOR — AND WHAT IT IS NOT
// ═══════════════════════════════════════════════════════════════════════════
//
// T5 tests the estimator's ARITHMETIC. It says nothing about SwiftF0: the
// product detector is not the 256-bin lattice C5a-0's fixtures modelled, and
// anything a person is shown must respect T6 (`PitchWobbleDetectorTests`),
// never this suite (§18.1.1).
//
// ═══════════════════════════════════════════════════════════════════════════
// THE FIXTURES — FIXED BEFORE THE FIRST RUN (seed 0xC5A0B5, 100 per rate)
// ═══════════════════════════════════════════════════════════════════════════
//
//  * `ClipPitchFrame`s on the detector's 62.5 fps grid, `timeSeconds` at the
//    frame START (the contract), each value taken at the frame CENTRE — so the
//    notes are read through `sung(_:contour:)`, the product's entry point.
//  * The value is an EXACT sine plus a quadratic trend plus seeded Gaussian
//    noise, σ = 3 c per frame (§18.1.1's pick: voice-like jitter, well above
//    the detector's steady spread). No lattice, no rate jitter, no scoop: the
//    bounds below are the information limit of THIS model, so the fixture must
//    be the model.
//  * The grid: rate {4.5, 5.5, 6.5, 7.5} Hz × depth {20, 40, 80} c × duration
//    {0.6, 1.0, 2.0} s × 100 seeds; the trend cycles none / +30 c ramp /
//    +40 c arch by seed. A CELL is (duration, depth) — the two things the
//    floors depend on — so each cell holds 400 notes.
//  * The bounds are read from `analyse` (the arithmetic), not from the
//    reading, so the ±20 c notes that land under the 20 c report floor stay
//    in the statistics instead of being selected out of them.
//
// ═══════════════════════════════════════════════════════════════════════════
// THE BOUNDS, AND THE ONE PLACE THIS SUITE DEPARTS FROM §18.1.1'S TEXT
// ═══════════════════════════════════════════════════════════════════════════
//
// The Cramér–Rao floors of a real sinusoid in white noise, per note, from its
// own N (samples fitted) and T (first kept sample to last):
//
//     σ_A = σ·√(2/N)                  σ_f = √24·σ / (2π·A·T·√N)
//
// ⚠️ **§18.1.1 prints σ_f = √12·σ / (2π·A·T·√N). That is √2 BELOW the floor.**
// The Fisher information of the rate is (A²/2σ²)·Σu², with Σu² = N(N²−1)Δ²/12
// for N samples Δ apart — the SAME factor ½ that gives §18.1.1's own
// σ_A = σ·√(2/N) — so var(f) = 24σ² / (4π²·A²·N·T²). Measured before this
// suite was written, on this estimator: its rate spread is 0.93–1.11 × the √24
// floor in all 36 (rate × depth × duration) cells, and the exact Fisher bound
// WITH the three trend nuisance parameters is 1.00–1.12 × it — the estimator
// sits AT the limit. Against the printed √12 form, "p95 ≤ 2.5 × σ_f" is 1.77 ×
// the true floor, below the 1.96 that ANY unbiased estimator's p95 must reach:
// it fails 35 of those 36 cells, and all 9 of this suite's cells (table
// below). So this suite uses the √24 floor and keeps §18.1.1's factor 2.5
// exactly; nothing else about the bound moved.
//
//  * rate: p95 of |error| / σ_f ≤ 2.5, per cell (the factor absorbs the trend
//    nuisance and the grid + parabola refinement, §18.1.1);
//  * depth: every note |error| ≤ 3·σ_A + 1 c;
//  * anchor: every note within 5 ms on cells ≥ 1.0 s, 8 ms at 0.6 s.
//
// MEASURED 2026-09-24 (C5a-0b): 400 notes per cell, the suite's own
// `wobble-estimate|` lines, identical on every run (fixed seeds):
//
//  | cell        | rate p95/σ_f | printed √12 | rate spread/σ_f | depth worst/bound | depth spread/σ_A | anchor p95 / max |
//  |-------------|--------------|-------------|-----------------|-------------------|------------------|------------------|
//  | 0.6 s ±20 c | 2.000        | 2.828 ✘     | 1.009           | 0.794             | 1.040            | 2.45 / 4.53 ms   |
//  | 0.6 s ±40 c | 2.097        | 2.966 ✘     | 1.046           | 0.612             | 1.074            | 1.16 / 2.45 ms   |
//  | 0.6 s ±80 c | 2.252        | 3.185 ✘     | 1.123           | 0.749             | 1.007            | 0.62 / 1.15 ms   |
//  | 1.0 s ±20 c | 1.899        | 2.686 ✘     | 1.012           | 0.546             | 0.962            | 2.11 / 4.63 ms   |
//  | 1.0 s ±40 c | 2.064        | 2.918 ✘     | 1.029           | 0.746             | 1.107            | 0.83 / 1.62 ms   |
//  | 1.0 s ±80 c | 1.806        | 2.554 ✘     | 0.967           | 0.607             | 0.989            | 0.48 / 0.87 ms   |
//  | 2.0 s ±20 c | 1.992        | 2.817 ✘     | 1.024           | 0.628             | 0.946            | 1.16 / 2.08 ms   |
//  | 2.0 s ±40 c | 1.932        | 2.732 ✘     | 0.948           | 0.651             | 1.008            | 0.55 / 1.18 ms   |
//  | 2.0 s ±80 c | 1.902        | 2.689 ✘     | 0.997           | 0.694             | 0.987            | 0.28 / 0.51 ms   |
//
//  bounds: rate 2.5; depth 1.0 of 3·σ_A + 1 c; anchor 8 ms at 0.6 s, 5 ms at
//  ≥ 1.0 s. Also: the trend moves nothing (worst 2.5e-14 Hz, 1.4e-13 c,
//  6.7e-16 s); ±20 c, AT the report floor, reads a wobble on 617 of 1200
//  notes; a 2.5 Hz ±80 c movement fits 57–69 c at the 3.00 Hz edge; white
//  noise is refused by the fit threshold on 12 of 20 seeds.
//
// ═══════════════════════════════════════════════════════════════════════════
// PLANTED DEFECTS (§18.1.1, §18.1.3–§18.1.5), each applied in an ISOLATED COPY
// of the tree, seen red, and reverted (C5a-0b, 2026-09-24)
// ═══════════════════════════════════════════════════════════════════════════
//
//  * +0.1 Hz on the refined rate → "§18.1.1 rate": p95 3.80 × the floor
//    (0.6 s ±20 c); the depth, anchor and doubled-axis tests go red with it.
//  * depth × 0.9 → "§18.1.1 depth": all 400 notes of every ±80 c cell past
//    their bound (±40 c: 334–400 of 400).
//  * anchor + a quarter period → "§18.1.1 anchor": 52–58 ms.
//  * `reportFloorCents` back to 12.9 → "§18.1.4 the report floor": all 8
//    ±16 c notes read a wobble (they fit 14.9–16.6 c).
//  * scan widened to 2.0 Hz → "§18.1.5 control": the 2.5 Hz movement reads
//    `.tooShort` on 3 of 4 seeds and `.wobble` on 1 — not the `.wobble`
//    §18.1.5 predicts, because its kept span holds only 1.96 cycles. Red
//    either way.
//  * `response` returning 1.0 → "§18.2 response(pitchHz:) is nil outside…".
//  * (not named by the design) samples counted AFTER the trims → "§18.1.3
//    control": 0.40 s reads `.tooFewSamples`.
//  * (§15 T5 (i)) the quadratic detrend removed → the trend-invariance
//    control (0.276 Hz apart); the rate, depth and anchor bounds go red too.

@Suite("C5a-0b T5 — sungWobbleMeasurement: the estimator's arithmetic against its Cramér–Rao floor")
struct PitchWobbleEstimateTests {

    static func say(_ message: String) { print("wobble-estimate| \(message)") }
    static func f(_ x: Double, _ digits: Int = 3) -> String { String(format: "%.\(digits)f", x) }

    /// Deterministic generator — a fixed seed per fixture set, so a failure is
    /// a reproducible note, not "sometimes".
    struct SplitMix {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        mutating func unit() -> Double { Double(next() >> 11) / Double(UInt64(1) << 53) }
        mutating func gauss() -> Double {
            let u1 = max(unit(), 1e-300), u2 = unit()
            return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
        }
    }

    // MARK: - The noise model and its floors

    static let frameRate = 62.5
    static let period = 1 / 62.5
    /// §18.1.1: per-frame Gaussian noise, cents.
    static let sigma = 3.0
    /// Any pitch: the cents are taken against it and back, exactly.
    static let baseHz = 220.0

    /// The Cramér–Rao floor on the rate, Hz, for `n` samples spanning
    /// `span` seconds of a sine of peak `depth` in σ-cent white noise. See
    /// the header for why √24 and not §18.1.1's printed √12.
    static func rateFloor(depth: Double, span: Double, n: Int) -> Double {
        24.0.squareRoot() * sigma / (2 * .pi * depth * span * Double(n).squareRoot())
    }

    /// The Cramér–Rao floor on the depth, cents: σ·√(2/N).
    static func depthFloor(n: Int) -> Double { sigma * (2 / Double(n)).squareRoot() }

    /// §18.1.1's anchor bounds, seconds.
    static func anchorBound(duration: Double) -> Double { duration >= 1.0 ? 0.005 : 0.008 }

    enum Trend: String, CaseIterable, Sendable { case none, ramp, arch }

    /// One synthetic sung note: an exact sine on a quadratic trend, plus the
    /// note's own seeded noise stream (so the same note can be rebuilt with a
    /// different trend and the SAME noise).
    struct Note: Sendable {
        var rate: Double
        var depth: Double
        var duration: Double
        var trend: Trend
        var phase0: Double
        var start: Double
        var noiseSeed: UInt64
        var noise = PitchWobbleEstimateTests.sigma

        init(rate: Double, depth: Double, duration: Double, trend: Trend = .none,
             rng: inout SplitMix) {
            self.rate = rate
            self.depth = depth
            self.duration = duration
            self.trend = trend
            self.phase0 = 2 * .pi * rng.unit()
            self.start = 1.0 + PitchWobbleEstimateTests.period * rng.unit()
            self.noiseSeed = rng.next()
        }

        func trendCents(_ t: Double) -> Double {
            let x = (t - start) / duration
            switch trend {
            case .none: return 0
            case .ramp: return 30 * x
            case .arch: return 40 * (1 - (2 * x - 1) * (2 * x - 1))
            }
        }

        /// `timeSeconds` at the frame START; the value at the frame CENTRE.
        var frames: [ClipPitchFrame] {
            let period = PitchWobbleEstimateTests.period
            var stream = SplitMix(state: noiseSeed)
            var out: [ClipPitchFrame] = []
            var k = Int((start * PitchWobbleEstimateTests.frameRate).rounded(.up))
            while Double(k) * period < start + duration {
                let frameStart = Double(k) * period
                if frameStart >= start {
                    let t = frameStart + period / 2
                    let cents = trendCents(t) + depth * sin(2 * .pi * rate * (t - start) + phase0)
                        + noise * stream.gauss()
                    out.append(ClipPitchFrame(timeSeconds: frameStart,
                                              frequencyHz: PitchWobbleEstimateTests.baseHz * pow(2, cents / 1200),
                                              confidence: 0.99, levelDbfs: -20, absence: nil))
                }
                k += 1
            }
            return out
        }

        /// The sine's rising zero crossing nearest `t`.
        func truthCrossing(near t: Double) -> Double {
            let cycle = ((2 * .pi * rate * (t - start) + phase0) / (2 * .pi)).rounded()
            return start + (2 * .pi * cycle - phase0) / (2 * .pi * rate)
        }
    }

    static func contour(_ frames: [ClipPitchFrame]) -> PitchRenderContour {
        .detected(PitchDetectionResult(
            frames: frames, frameCount: frames.count,
            voicedFrameCount: frames.filter { $0.frequencyHz != nil }.count,
            voicedFraction: 1, frameRateHz: frameRate, analysisSampleRateHz: 16_000,
            sourceSampleRateHz: 48_000, windowStartSeconds: 0,
            windowDurationSeconds: (frames.last?.timeSeconds ?? 0) + period,
            confidenceThreshold: 0.9, silenceFloorDbfs: -75,
            minFrequencyHz: 46.875, maxFrequencyHz: 2093.75))
    }

    /// The note the frames make — first frame start to last frame end, which
    /// is how `PitchAutoCorrect.voicedRuns` bounds a run.
    static func segment(_ frames: [ClipPitchFrame], detectedHz: Double = baseHz) -> NoteSegment {
        NoteSegment(startSeconds: frames.first?.timeSeconds ?? 0,
                    endSeconds: (frames.last?.timeSeconds ?? 0) + period,
                    detectedHz: detectedHz, detectedConfidence: 0.99)
    }

    /// What `sung` reads, and the analysis behind it on the SAME samples
    /// `sung` builds (frame centre, cents against the note's pitch).
    static func read(_ note: Note) -> (reading: PitchWobbleReading, analysis: PitchWobbleEstimate.Analysis?) {
        let frames = note.frames
        let contour = contour(frames)
        let reading = PitchWobbleEstimate.sung(segment(frames), contour: contour) ?? .unmeasurable(.tooFewSamples)
        let analysis = PitchWobbleEstimate.analyse(
            times: frames.map { $0.timeSeconds + contour.frameValueOffsetSeconds },
            cents: frames.map { PitchCorrectionMath.cents(from: baseHz, to: $0.frequencyHz!) })
        return (reading, analysis)
    }

    static func measured(_ reading: PitchWobbleReading) -> (rate: Double, depth: Double, anchor: Double)? {
        guard case let .wobble(rate, depth, anchor, _) = reading else { return nil }
        return (rate, depth, anchor)
    }

    /// Nearest-rank 95th percentile.
    static func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .nan }
        return sorted[max(0, Int((0.95 * Double(sorted.count)).rounded(.up)) - 1)]
    }

    static func spread(_ xs: [Double]) -> Double {
        guard xs.count > 1 else { return .nan }
        let mean = xs.reduce(0, +) / Double(xs.count)
        return (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
    }

    // MARK: - The grid, computed once

    struct GridNote: Sendable {
        let note: Note
        let reading: PitchWobbleReading
        let analysis: PitchWobbleEstimate.Analysis?
        var cell: String { "\(note.duration) s ±\(Int(note.depth)) c" }
        var label: String { "\(cell) \(note.rate) Hz \(note.trend.rawValue)" }
    }

    static let seedsPerRate = 100
    static let rates = [4.5, 5.5, 6.5, 7.5]
    static let depths = [20.0, 40.0, 80.0]
    static let durations = [0.6, 1.0, 2.0]

    static let grid: [GridNote] = {
        var rng = SplitMix(state: 0xC5A0B5)
        var notes: [Note] = []
        for duration in durations {
            for depth in depths {
                for rate in rates {
                    for seed in 0..<seedsPerRate {
                        notes.append(Note(rate: rate, depth: depth, duration: duration,
                                          trend: Trend.allCases[seed % Trend.allCases.count], rng: &rng))
                    }
                }
            }
        }
        // Readings are pure and independent: read them concurrently.
        let all = notes
        let slots = UnsafeMutableBufferPointer<GridNote?>.allocate(capacity: all.count)
        slots.initialize(repeating: nil)
        defer { slots.deallocate() }
        let box = UncheckedSendableSlots(buffer: slots)
        DispatchQueue.concurrentPerform(iterations: all.count) { index in
            let (reading, analysis) = read(all[index])
            box.buffer[index] = GridNote(note: all[index], reading: reading, analysis: analysis)
        }
        return slots.map { $0! }
    }()

    /// Each index is written by exactly one iteration of `concurrentPerform`.
    struct UncheckedSendableSlots: @unchecked Sendable {
        let buffer: UnsafeMutableBufferPointer<GridNote?>
    }

    /// Cells in a stable order: duration, then depth.
    static var cells: [String] {
        durations.flatMap { d in depths.map { "\(d) s ±\(Int($0)) c" } }
    }

    // MARK: - §18.1.1: the three bounds

    @Test("§18.1.1 rate: per cell, the p95 rate error is at most 2.5 × the Cramér–Rao floor")
    func rateIsWithinItsFloor() throws {
        var byCell: [String: [(z: Double, error: Double, floor: Double)]] = [:]
        for g in Self.grid {
            let a = try #require(g.analysis, "\(g.label): no analysis")
            let floor = Self.rateFloor(depth: g.note.depth, span: a.spanSeconds, n: a.fitted)
            let error = a.rateHz - g.note.rate
            byCell[g.cell, default: []].append((abs(error) / floor, error, floor))
        }
        for cell in Self.cells {
            let rows = try #require(byCell[cell])
            let p = Self.p95(rows.map(\.z))
            let meanFloor = rows.map(\.floor).reduce(0, +) / Double(rows.count)
            Self.say("rate \(cell): n \(rows.count), σ_f \(Self.f(meanFloor, 5)) Hz, p95 |e|/σ_f \(Self.f(p, 3)) "
                + "(bound 2.5; §18.1.1's printed √12 form: \(Self.f(p * 2.0.squareRoot(), 3))), "
                + "spread/σ_f \(Self.f(Self.spread(rows.map(\.error)) / meanFloor, 3)), "
                + "p95 |e| \(Self.f(Self.p95(rows.map { abs($0.error) }), 4)) Hz")
            #expect(p <= 2.5, "\(cell): p95 rate error is \(p) × the Cramér–Rao floor")
        }
    }

    @Test("§18.1.1 depth: every note's depth error is at most 3·σ_A + 1 c")
    func depthIsWithinItsFloor() throws {
        var worst: [String: (ratio: Double, error: Double, label: String)] = [:]
        var errors: [String: [Double]] = [:]
        var over: [String] = []
        for g in Self.grid {
            let a = try #require(g.analysis, "\(g.label): no analysis")
            let error = a.depthCents - g.note.depth
            let bound = 3 * Self.depthFloor(n: a.fitted) + 1
            errors[g.cell, default: []].append(error)
            if abs(error) / bound > (worst[g.cell]?.ratio ?? -1) { worst[g.cell] = (abs(error) / bound, error, g.label) }
            if abs(error) > bound { over.append("\(g.label): \(Self.f(error, 2)) c (bound \(Self.f(bound, 2)))") }
        }
        for cell in Self.cells {
            let w = try #require(worst[cell])
            let e = try #require(errors[cell])
            let floor = Self.depthFloor(n: try #require(Self.grid.first { $0.cell == cell }?.analysis?.fitted))
            Self.say("depth \(cell): worst \(Self.f(w.error, 2)) c = \(Self.f(w.ratio, 3)) of its bound "
                + "(\(w.label)); spread/σ_A \(Self.f(Self.spread(e) / floor, 3))")
        }
        for line in over.prefix(10) { Self.say("  over: \(line)") }
        #expect(over.isEmpty, "\(over.count) notes past 3·σ_A + 1 c")
    }

    @Test("§18.1.1 anchor: the rising crossing lands within 5 ms (≥ 1.0 s) and 8 ms (0.6 s) of the fixture's own")
    func anchorIsWithinItsBound() throws {
        var byCell: [String: [Double]] = [:]
        var over: [String] = []
        for g in Self.grid {
            let a = try #require(g.analysis, "\(g.label): no analysis")
            let error = abs(a.anchorSeconds - g.note.truthCrossing(near: a.anchorSeconds))
            byCell[g.cell, default: []].append(error * 1000)
            if error > Self.anchorBound(duration: g.note.duration) {
                over.append("\(g.label): \(Self.f(error * 1000, 2)) ms")
            }
        }
        for cell in Self.cells {
            let v = try #require(byCell[cell])
            Self.say("anchor \(cell): p95 \(Self.f(Self.p95(v), 2)) ms, max \(Self.f(v.max() ?? .nan, 2)) ms")
        }
        for line in over.prefix(10) { Self.say("  over: \(line)") }
        #expect(over.isEmpty, "\(over.count) anchors past their bound")
    }

    /// The trend is a NUISANCE the model fits jointly: adding any quadratic to
    /// the samples cannot move the least-squares sine. The boring invariance
    /// control — a detrend defect shows here first.
    @Test("the trend is a nuisance: the same noise with no trend, a ramp or an arch reads the same wobble")
    func theTrendDoesNotMoveTheReading() throws {
        var rng = SplitMix(state: 0x7E2D)
        var worst = (rate: 0.0, depth: 0.0, anchor: 0.0, fit: 0.0)
        for duration in Self.durations {
            for depth in Self.depths {
                for rate in Self.rates {
                    let base = Note(rate: rate, depth: depth, duration: duration, rng: &rng)
                    let plain = try #require(Self.read(base).analysis)
                    for trend in [Trend.ramp, .arch] {
                        var moved = base
                        moved.trend = trend
                        let other = try #require(Self.read(moved).analysis)
                        worst.rate = max(worst.rate, abs(other.rateHz - plain.rateHz))
                        worst.depth = max(worst.depth, abs(other.depthCents - plain.depthCents))
                        worst.anchor = max(worst.anchor, abs(other.anchorSeconds - plain.anchorSeconds))
                        worst.fit = max(worst.fit, abs(other.fit - plain.fit))
                    }
                }
            }
        }
        Self.say("trend invariance, worst over 36 notes × 2 trends: rate \(worst.rate) Hz, depth \(worst.depth) c, "
            + "anchor \(worst.anchor) s, fit \(worst.fit)")
        // Rounding only: a million times under the smallest bound above.
        #expect(worst.rate <= 1e-6)
        #expect(worst.depth <= 1e-6)
        #expect(worst.anchor <= 1e-6)
        #expect(worst.fit <= 1e-6)
    }

    /// A note whose depth sits at least 3·σ_A + 1 c above the report floor,
    /// with at least 2 cycles in its measured middle, is read as a wobble —
    /// and `sung` reads exactly what `analyse` decides on the same samples.
    @Test("§18.1.1 the grid: every note clear of the report floor reads a wobble, and sung agrees with analyse")
    func clearNotesReadAWobble() throws {
        var refused: [String] = []
        var disagree = 0
        var twenty = (wobble: 0, total: 0)
        for g in Self.grid {
            let a = try #require(g.analysis)
            if g.reading != a.reading { disagree += 1 }
            let clear = g.note.depth - (3 * Self.depthFloor(n: a.fitted) + 1) >= PitchWobbleEstimate.reportFloorCents
            if clear, Self.measured(g.reading) == nil { refused.append("\(g.label): \(g.reading)") }
            if g.note.depth == 20 {
                twenty.total += 1
                if Self.measured(g.reading) != nil { twenty.wobble += 1 }
            }
        }
        Self.say("grid: \(Self.grid.count) notes; \(refused.count) clear of the floor refused; "
            + "±20 c (AT the report floor) read a wobble on \(twenty.wobble) of \(twenty.total)")
        for line in refused.prefix(10) { Self.say("  refused: \(line)") }
        #expect(Self.grid.count == Self.durations.count * Self.depths.count * Self.rates.count * Self.seedsPerRate)
        #expect(refused.isEmpty, "\(refused.count) notes clear of the report floor were not read as a wobble")
        #expect(disagree == 0, "sung and analyse disagreed on \(disagree) notes")
    }

    // MARK: - §18.1.4: the report floor fires where it says

    /// 1.0 s at 5.5 Hz: N ≈ 50, so 3·σ_A + 1 ≈ 2.8 c. ±16 c cannot fit
    /// above 18.8 c and ±24 c cannot fit below 21.2 c: the pair brackets
    /// the 20 c report floor from the depth bound alone.
    @Test("§18.1.4 the report floor: ±16 c reads no wobble and ±24 c reads a wobble")
    func theReportFloorBracket() throws {
        var rng = SplitMix(state: 0x2016)
        #expect(PitchWobbleEstimate.reportFloorCents == 20.0)
        for _ in 0..<8 {
            let under = Self.read(Note(rate: 5.5, depth: 16, duration: 1.0, rng: &rng))
            #expect(under.reading == .noWobble, "±16 c: \(under.reading)")
            #expect(under.analysis?.step == .belowFloor)
            let over = Self.read(Note(rate: 5.5, depth: 24, duration: 1.0, rng: &rng))
            #expect(Self.measured(over.reading) != nil, "±24 c: \(over.reading)")
        }
    }

    @Test("control: a flat line reads no wobble, because it is under the floor")
    func aFlatLineReadsNoWobble() throws {
        var rng = SplitMix(state: 0xF1A7)
        for _ in 0..<4 {
            let reading = Self.read(Note(rate: 5.5, depth: 0, duration: 1.0, rng: &rng)).reading
            #expect(reading == .noWobble, "\(reading)")
        }
        // Noiseless: under the floor, not refused at the scan edge — a flat
        // line's residual is flat in rate, so its best candidate is arbitrary.
        let times = (0..<62).map { 1.0 + Double($0) * Self.period }
        let analysis = try #require(PitchWobbleEstimate.analyse(times: times,
                                                               cents: [Double](repeating: 3, count: 62)))
        #expect(analysis.step == .belowFloor)
    }

    // MARK: - §18.1.3: the two short-note refusals, in their order

    /// 0.35 s is 21–22 frames: under the 24 handed in, `.tooFewSamples`.
    /// 0.40 s is 25 frames; 2 trimmed at each end leaves 21, spanning
    /// 20 × 16 ms = 0.32 s = 1.76 cycles at 5.5 Hz: `.tooShort`.
    @Test("§18.1.3 control: 0.35 s at 5.5 Hz is too few samples, 0.40 s is too short")
    func bothShortNoteRefusalsFire() throws {
        var rng = SplitMix(state: 0x35_40)
        for _ in 0..<4 {
            let short = Note(rate: 5.5, depth: 40, duration: 0.35, rng: &rng)
            #expect(short.frames.count < PitchWobbleEstimate.minimumSamples, "\(short.frames.count) frames")
            #expect(Self.read(short).reading == .unmeasurable(.tooFewSamples), "0.35 s: \(Self.read(short).reading)")
            let brief = Note(rate: 5.5, depth: 40, duration: 0.40, rng: &rng)
            #expect(brief.frames.count == 25, "\(brief.frames.count) frames")
            let (reading, analysis) = Self.read(brief)
            #expect(reading == .unmeasurable(.tooShort), "0.40 s: \(reading)")
            let a = try #require(analysis)
            #expect(a.fitted == 21 && a.step == .tooShort, "0.40 s: \(a.fitted) fitted, step \(a.step)")
            #expect(a.spanSeconds * a.rateHz < PitchWobbleEstimate.minimumCycles)
        }
    }

    // MARK: - §18.1.5: the scan edge

    /// A 2.5 Hz ±80 c movement has no candidate inside 3–9 Hz: its best rate
    /// is the scan's lower EDGE, and the edge rule refuses it.
    @Test("§18.1.5 control: a 2.5 Hz ±80 c movement over 1.0 s is refused at the scan edge")
    func aSlowMovementIsRefusedAtTheEdge() throws {
        var rng = SplitMix(state: 0x25ED)
        #expect(PitchWobbleEstimate.scanRangeHz.lowerBound == 3.0)
        for _ in 0..<4 {
            let (reading, analysis) = Self.read(Note(rate: 2.5, depth: 80, duration: 1.0, rng: &rng))
            let a = try #require(analysis)
            Self.say("2.5 Hz ±80 c 1.0 s: \(reading) [step \(a.step.rawValue), \(Self.f(a.depthCents, 1)) c at "
                + "\(Self.f(a.rateHz, 2)) Hz]")
            #expect(reading == .unmeasurable(.tooUneven), "\(reading)")
            #expect(a.step == .scanEdge, "step \(a.step)")
        }
    }

    // MARK: - The other negative controls

    @Test("control: of 20 seeded ±30 c random walks, at most one reads a wobble")
    func randomWalksRarelyReadAsAWobble() {
        var wobbles = 0
        for seed in 1...20 {
            var rng = SplitMix(state: UInt64(seed))
            var walk: [Double] = [0]
            for _ in 1..<62 { walk.append(walk[walk.count - 1] + rng.gauss()) }
            let low = walk.min()!, high = walk.max()!
            let scale = 30 / max((high - low) / 2, 1e-9)
            let cents = walk.map { ($0 - (low + high) / 2) * scale }
            let times = cents.indices.map { 1.0 + Double($0) * Self.period + Self.period / 2 }
            let reading = PitchWobbleEstimate.read(times: times, cents: cents)
            if Self.measured(reading) != nil { wobbles += 1 }
            Self.say("walk \(seed): \(reading)")
        }
        #expect(wobbles <= 1, "\(wobbles) of 20 random walks read as a wobble")
    }

    /// The walks die at the floor (a ±30 c walk is smooth; the quadratic takes
    /// most of it), so they never reach `F ≥ 0.4`. White noise does: this
    /// proves the fit threshold can fire.
    @Test("F ≥ 0.4 can fire: white noise is refused, some of it by the fit threshold")
    func noiseIsRefusedByTheFitThreshold() {
        var byFit = 0
        for seed in 1...20 {
            var rng = SplitMix(state: UInt64(0xF17 + seed))
            let seconds = seed <= 10 ? 1.0 : 2.0
            let cents = (0..<Int(seconds * Self.frameRate)).map { _ in 60 * rng.gauss() }
            let times = cents.indices.map { 1.0 + Double($0) * Self.period + Self.period / 2 }
            let reading = PitchWobbleEstimate.read(times: times, cents: cents)
            #expect(Self.measured(reading) == nil, "noise seed \(seed) read as a wobble: \(reading)")
            if PitchWobbleEstimate.analyse(times: times, cents: cents)?.step == .uneven { byFit += 1 }
        }
        Self.say("noise: \(byFit) of 20 refused by the fit threshold")
        #expect(byFit >= 1, "the fit threshold never fired on noise, so nothing shows it can")
    }

    // MARK: - The other doors

    @Test("refit at a known rate recovers depth and anchor, and agrees with read at the rate read found")
    func refitAtAKnownRate() throws {
        var rng = SplitMix(state: 0x2EF1)
        let note = Note(rate: 5.5, depth: 40, duration: 1.0, rng: &rng)
        let frames = note.frames
        let times = frames.map { $0.timeSeconds + Self.period / 2 }
        let cents = frames.map { 1200 * log2($0.frequencyHz! / Self.baseHz) }
        let atTruth = try #require(PitchWobbleEstimate.refit(times: times, cents: cents, rateHz: 5.5))
        let fitted = try #require(PitchWobbleEstimate.analyse(times: times, cents: cents)).fitted
        #expect(abs(atTruth.depthCents - 40) <= 3 * Self.depthFloor(n: fitted) + 1)
        #expect(abs(atTruth.anchorSeconds - note.truthCrossing(near: atTruth.anchorSeconds)) <= 0.005)
        let m = try #require(Self.measured(PitchWobbleEstimate.read(times: times, cents: cents)))
        let again = try #require(PitchWobbleEstimate.refit(times: times, cents: cents, rateHz: m.rate))
        #expect(abs(again.depthCents - m.depth) < 1e-9)
        #expect(abs(again.anchorSeconds - m.anchor) < 1e-9)
        #expect(PitchWobbleEstimate.refit(times: times, cents: cents, rateHz: 0) == nil)
        #expect(PitchWobbleEstimate.refit(times: times, cents: cents, rateHz: .nan) == nil)
        #expect(PitchWobbleEstimate.refit(times: Array(times.prefix(23)), cents: cents, rateHz: 5.5) == nil)
    }

    @Test("the rate is per second of the time axis given: the same samples on a doubled axis read half the rate")
    func rateIsPerSecondOfTheGivenAxis() throws {
        var rng = SplitMix(state: 0xD0B1)
        let frames = Note(rate: 6.5, depth: 40, duration: 2.0, rng: &rng).frames
        let times = frames.map { $0.timeSeconds + Self.period / 2 }
        let cents = frames.map { 1200 * log2($0.frequencyHz! / Self.baseHz) }
        let normal = try #require(Self.measured(PitchWobbleEstimate.read(times: times, cents: cents)))
        let slowed = try #require(Self.measured(PitchWobbleEstimate.read(times: times.map { $0 * 2 }, cents: cents)))
        #expect(abs(normal.rate - 6.5) <= 0.05)
        #expect(abs(slowed.rate - normal.rate / 2) <= 0.01, "doubled axis read \(slowed.rate) Hz")
        #expect(abs(slowed.depth - normal.depth) <= 0.5)
    }

    /// The played reading of a note nobody edited is the sung reading; a pitch
    /// move shifts the line by a constant and must not change the wobble.
    @Test("played: an unedited note reads as sung, and a pitch move does not change its wobble")
    func thePlayedReadingOfAnUneditedNote() throws {
        var rng = SplitMix(state: 0x9A7E)
        let frames = Note(rate: 5.5, depth: 40, duration: 1.0, rng: &rng).frames
        let contour = Self.contour(frames)
        let note = Self.segment(frames)
        let sungReading = try #require(PitchWobbleEstimate.sung(note, contour: contour))
        let sung = try #require(Self.measured(sungReading))
        for offset in [0.0, 100.0, -35.0] {
            var moved = note
            moved.pitchOffsetCents = offset
            let line = PitchPlayedLine.make(contour: contour, fallback: nil,
                                            editSet: PitchEditSet(segments: [moved]),
                                            clipPitchShiftSemitones: 0, sourceWindow: 0..<10)
            #expect(line.basis == .render)
            let played = try #require(Self.measured(PitchWobbleEstimate.played(moved, line: line)))
            #expect(abs(played.rate - sung.rate) < 1e-6, "offset \(offset): \(played.rate) vs \(sung.rate)")
            #expect(abs(played.depth - sung.depth) < 1e-6, "offset \(offset): \(played.depth) vs \(sung.depth)")
            #expect(abs(played.anchor - sung.anchor) < 1e-6)
        }
    }

    @Test("sung reads only a detected contour")
    func sungNeedsADetectedContour() {
        var rng = SplitMix(state: 0x51)
        let frames = Note(rate: 5.5, depth: 40, duration: 1.0, rng: &rng).frames
        let note = Self.segment(frames)
        #expect(PitchWobbleEstimate.sung(note, contour: .unavailable(reason: "x")) == nil)
        #expect(PitchWobbleEstimate.sung(note, contour: .analysisVersionMismatch(editSet: 1, detector: 2)) == nil)
        #expect(PitchWobbleEstimate.sung(note, contour: Self.contour(frames)) != nil)
        // A note with no usable reference is read against its own frames,
        // never flattened to zero by `cents(from: 0, …)`.
        let orphan = Self.segment(frames, detectedHz: 0)
        #expect(Self.measured(PitchWobbleEstimate.sung(orphan, contour: Self.contour(frames)) ?? .noWobble) != nil)
    }

    @Test("garbage in is refused, never propagated")
    func garbageIsRefused() {
        #expect(PitchWobbleEstimate.read(times: [], cents: []) == .unmeasurable(.tooFewSamples))
        let times = (0..<40).map { Double($0) * Self.period }
        let cents = times.map { 40 * sin(2 * .pi * 5.5 * $0) }
        // NaNs are dropped; what is left is counted.
        var poisoned = cents
        for i in stride(from: 0, to: 40, by: 2) { poisoned[i] = .nan }
        #expect(PitchWobbleEstimate.read(times: times, cents: poisoned) == .unmeasurable(.tooFewSamples))
        // Every sample at one instant has no duration.
        #expect(PitchWobbleEstimate.read(times: [Double](repeating: 1, count: 40), cents: cents)
                == .unmeasurable(.tooShort))
        // Unequal lengths are read pairwise up to the shorter.
        #expect(PitchWobbleEstimate.read(times: times, cents: Array(cents.prefix(20)))
                == .unmeasurable(.tooFewSamples))
        // Order does not matter.
        #expect(PitchWobbleEstimate.read(times: times.reversed(), cents: cents.reversed())
                == PitchWobbleEstimate.read(times: times, cents: cents))
    }

    // MARK: - §18.2: the shape of `response(pitchHz:)` (its VALUES are T6's)

    /// The values are measured through the product detector by T6's
    /// calibration test; this pins what can be checked without it: `nil`
    /// outside every block, blocks that tile without overlap, every measured
    /// pitch inside its own block, and every share inside §18.4's [0.5, 1.1].
    @Test("§18.2 response(pitchHz:) is nil outside every block, and its blocks tile in order")
    func responseHasItsShape() throws {
        let blocks = PitchWobbleEstimate.responseBlocks
        #expect(!blocks.isEmpty)
        for (lower, upper) in zip(blocks, blocks.dropFirst()) {
            #expect(lower.coversHz.upperBound == upper.coversHz.lowerBound, "\(lower.name) → \(upper.name)")
        }
        for block in blocks {
            for hz in block.measuredHz {
                #expect(block.coversHz.contains(hz), "\(block.name) does not cover its own \(hz) Hz")
                #expect(PitchWobbleEstimate.response(pitchHz: hz) == block.medianShare, "\(block.name) at \(hz) Hz")
            }
            if let share = block.medianShare {
                #expect(share >= 0.5 && share <= 1.1, "\(block.name): \(share) is outside [0.5, 1.1]")
            }
        }
        let bottom = try #require(blocks.first?.coversHz.lowerBound)
        let top = try #require(blocks.last?.coversHz.upperBound)
        for hz in [bottom * 0.99, top, top * 1.5, 1000, 0, -110, .nan, .infinity] {
            #expect(PitchWobbleEstimate.response(pitchHz: hz) == nil, "\(hz) Hz")
        }
    }
}
