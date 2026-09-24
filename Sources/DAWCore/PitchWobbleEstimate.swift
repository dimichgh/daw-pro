import Foundation

// m23-ap C5a-0 / C5a-0b — THE WOBBLE ESTIMATOR: how fast and how wide a SUNG
// note wobbles.
//
// Design: `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §8 (what is
// measured, the method), §15 T5/T6, and **§18 (C5a-0b: every threshold
// re-picked against the PRODUCT detector — it supersedes §8.5)**.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⛔ READ THIS BEFORE PRINTING ANY NUMBER THIS FILE RETURNS
// ═══════════════════════════════════════════════════════════════════════════
//
// The pitch editor prints "about 5.5 per second, about 40 cents each way"
// about a singer's OWN voice from this reading, and hands a sung wobble over
// to a synthesised one at the reading's rate, depth and phase. The number is
// about a person, so its honesty matters more than its polish. Two layers,
// two suites (§18.1.1):
//
//  * **THE ARITHMETIC** (`PitchWobbleEstimateTests`, T5): on an exact sine
//    plus a quadratic trend plus σ = 3 c white noise, this estimator sits AT
//    the Cramér–Rao floor — its rate spread is 0.95–1.12 × σ_f and its
//    depth spread 0.95–1.11 × σ_A in every T5 cell (400 notes each). It is
//    not the loose link.
//  * **THE PRODUCT CHAIN** (`PitchWobbleDetectorTests`, T6: SwiftF0, then
//    this). ANYTHING A PERSON IS SHOWN MUST RESPECT T6, NEVER T5. SwiftF0 is
//    NOT a 256-bin quantiser; it ERASES small modulation:
//    - a ±20 c wobble is INVISIBLE at mid pitch (fits 3.4–9.0 c, 36 of 36
//      notes `.noWobble` — T6 pins this as a tripwire);
//    - ±25 c reads 12–18 c, ±40 c reads 0.75–0.99 of itself at mid pitch;
//    - and below ~110 Hz the whole response collapses (§18.1.6): see
//      `response(pitchHz:)` for where a depth may be calibrated at all.
//  * ⚠️ **THE DETECTOR ALSO INVENTS.** Near a boundary between two of its
//    outputs, a ±8 c wobble swings the output across it and fits as a
//    13.8–15.7 c two-level square wave (A3 + 14…18 c). That is why a READ
//    depth under `reportFloorCents` (20 c) is `.noWobble`: the reading cannot
//    tell such an artefact from a real, compressed ±25 c wobble, and a keep
//    lever applied to an artefact would write it into the audio (§18.1.4).
//  * `.noWobble` therefore means "no wobble THE APP CAN MEASURE", never "no
//    wobble" — a singer's ±25 c wobble is real and reads `.noWobble`.
//  * **A depth is a MEASUREMENT OF THE CONTOUR, not of the voice.** The
//    handoff seeds `depth ÷ response(pitchHz:)` (§18.2) and is refused where
//    `response` is `nil`; the readout never prints that calibrated number as a
//    measurement, and prints no width at all where no block covers the pitch
//    (§18.3).
//
// ═══════════════════════════════════════════════════════════════════════════
// WHAT IT IS
// ═══════════════════════════════════════════════════════════════════════════
//
// A least-squares sine fit with a quadratic detrend over the note's middle
// 80 %, scanning 3–9 Hz (§8.2). Pure and total: seconds and cents in, a
// reading out. No clock, no I/O, no actor, never on the render thread.
//
// **Not the tests' one-bin projection** (`M23QToneTracker.fitSinusoid`): a
// projection's amplitude is biased by a partial number of cycles, and a short
// note is ALWAYS a partial number of cycles. Planted as a defect on C5a-0's
// §8.5a grid (a lattice model, since retired), the projection read depths up
// to 13.5 c wrong (50 of 1296 notes past 7 c) where the joint fit's worst was
// 7.35 c.

/// Why a note's wobble could not be measured.
public enum PitchWobbleShortfall: String, Sendable, Equatable {
    /// Fewer than `PitchWobbleEstimate.minimumSamples` usable samples were
    /// handed in.
    case tooFewSamples
    /// The measured middle of the note holds fewer than
    /// `PitchWobbleEstimate.minimumCycles` cycles at the best rate.
    case tooShort
    /// Either the best rate sat on the edge of the scan (no wobble inside
    /// 3–9 Hz explains the contour better than a slower or faster shape), or
    /// the sine explains less than `PitchWobbleEstimate.minimumFit` of what
    /// the trend leaves.
    case tooUneven
}

/// One note's wobble, as the estimator reads it.
public enum PitchWobbleReading: Sendable, Equatable {
    /// `rateHz`: cycles per second OF THE TIME AXIS GIVEN (source seconds for
    /// `sung`, edited seconds for `played`; a HEARD rate is that divided by
    /// the clip's stretch ratio — design V5). `depthCents`: a PEAK, "each
    /// way", like `NoteSegment.vibratoDepthCents`. `anchorSeconds`: a RISING
    /// zero crossing of the fitted sine, the one nearest the middle of the
    /// measured span, so `sin(2π · rateHz · (t − anchorSeconds))` is the
    /// fitted wobble's shape. `fit`: the share of the detrended variance the
    /// sine explains, 0…1.
    case wobble(rateHz: Double, depthCents: Double, anchorSeconds: Double, fit: Double)
    /// The fitted wobble is below `PitchWobbleEstimate.reportFloorCents`.
    /// ⚠️ "No wobble the app can measure" — NOT "no wobble" (design §8.6,
    /// §18.1.4): through the product detector a real ±25 c wobble reads here.
    case noWobble
    /// The reading exists but cannot be trusted, and says why.
    case unmeasurable(PitchWobbleShortfall)
}

/// The estimator. See the banner above for what its numbers may be used for.
public enum PitchWobbleEstimate {

    // MARK: - The picks (design §8.4, re-picked against the product in §18)
    //
    // ⚠️ C5a-0b moved none of §8.2's picks; it ADDED `reportFloorCents`
    // (§18.1.4). None may be loosened to make a bound pass (§8.5, §18.4).

    /// **THE REPORT FLOOR, cents** (design §18.1.4): a fitted depth below this
    /// is `.noWobble`, "no wobble the app can measure".
    ///
    /// Why 20, measured through the product detector (`PitchWobbleDetectorTests`):
    /// a TRUE ±8 c wobble near a boundary between two SwiftF0 outputs comes
    /// back as a two-level square wave and fits 13.8–15.7 c (A3 + 14…18 c);
    /// its ceiling is that square wave's fundamental, 4/π × 12.90 = 16.4 c.
    /// A reading in that band cannot be told from a real, compressed ±25 c
    /// wobble (which fits 12.1–17.9 c), and the "your wobble" branch's keep
    /// lever renders `(k − 1) ×` what was DETECTED — so an artefact read as a
    /// wobble would be written into the audio. On the user's own take every
    /// real wobble read ≥ 22.0 c, so the floor costs nothing there.
    ///
    /// ⚠️ NOT a second home for `PitchCorrectionMath.detectorResolutionFloorCents`
    /// (12.90 c, §8.3): that one says what a single detected value can
    /// resolve and is the READOUTS' floor; this one says what the product can
    /// honestly call a wobble. Different questions, different constants.
    public static let reportFloorCents = 20.0

    /// Fewer samples than this, counted as HANDED IN (finite pairs, before
    /// the trims), is `.tooFewSamples`. 24 frames at SwiftF0's 62.5 fps is
    /// 0.384 s.
    ///
    /// ⚠️ Counted BEFORE the trims (§18.1.3, kept as built). Counted after
    /// them, `.tooShort` could never fire at 5.5 Hz: 24 trimmed frames already
    /// span 2.02 cycles (23 frame steps of 16 ms). So a 0.35 s note (21–22
    /// frames) is `.tooFewSamples`, and a 0.40 s note (25 frames; 21 kept,
    /// spanning 1.76 cycles at 5.5 Hz) is `.tooShort`; both read "too short to
    /// measure" (§18.3).
    public static let minimumSamples = 24

    /// Share of the samples dropped at EACH end before fitting — onset scoops
    /// and releases are not the wobble.
    public static let trimFraction = 0.1

    /// The trims drop at least this many samples at each end.
    public static let minimumTrimSamples = 2

    /// The candidate rates, Hz of the given time axis.
    ///
    /// The 3.0 Hz edge STAYS (§18.1.5): on the user's take the notes whose best
    /// rate sits at or just inside it (3.00–3.18 Hz, 28–176 c) are slides and
    /// bends, not wobbles — sung vibrato reads 4.3–7.6 Hz there. A best rate
    /// AT an edge is `.unmeasurable(.tooUneven)`.
    public static let scanRangeHz: ClosedRange<Double> = 3.0...9.0

    /// The scan's step, Hz. The best step is refined by a parabola through its
    /// two neighbours, so the step is not the reading's resolution.
    public static let scanStepHz = 0.02

    /// The measured middle of the note must hold at least this many cycles at
    /// the best rate, measured from its first kept sample to its last.
    public static let minimumCycles = 2.0

    /// The sine must explain at least this share of what the quadratic trend
    /// leaves (`fit`), or the wobble is `.tooUneven`.
    public static let minimumFit = 0.4

    // MARK: - The readings

    /// **Read a wobble from raw samples.** `times` in seconds (any origin),
    /// `cents` against any constant reference: the fit's own constant term
    /// absorbs the reference, so it cannot move the reading.
    ///
    /// Total: pairs with a non-finite value are dropped, the pairs are sorted
    /// by time, and unequal array lengths are read pairwise up to the shorter.
    public static func read(times: [Double], cents: [Double]) -> PitchWobbleReading {
        switch Prepared.make(times: times, cents: cents) {
        case .refused(let shortfall):
            return .unmeasurable(shortfall)
        case .ready(let prepared):
            guard let analysis = analyse(prepared) else { return .unmeasurable(.tooUneven) }
            return analysis.reading
        }
    }

    /// **The per-tick readout: depth and anchor at a KNOWN rate.** No rescan —
    /// one 5-parameter solve on the same trimmed, centred, detrended samples
    /// `read` fits (§8.2 step 7).
    ///
    /// `nil` when fewer than `minimumSamples` usable samples are handed in,
    /// when `rateHz` is not a positive finite number, or when the fit is
    /// degenerate at that rate.
    ///
    /// ⚠️ **NO FLOOR IS APPLIED HERE.** This returns the raw fitted depth; a
    /// caller deciding whether what is left still counts as a wobble compares
    /// it with `reportFloorCents` itself — the floor `read` applies — so the
    /// readout and `read` cannot disagree about it.
    /// (`PitchCorrectionMath.detectorResolutionFloorCents` answers a different
    /// question: what one detected VALUE can resolve.)
    public static func refit(times: [Double], cents: [Double],
                             rateHz: Double) -> (depthCents: Double, anchorSeconds: Double)? {
        guard rateHz.isFinite, rateHz > 0,
              case .ready(let prepared) = Prepared.make(times: times, cents: cents),
              let fit = prepared.fit(rateHz: rateHz) else { return nil }
        return (fit.depth, prepared.anchor(of: fit, rateHz: rateHz))
    }

    /// **The SUNG reading** (§8.1): the note's voiced frames with
    /// `timeSeconds` in `[startSeconds, endSeconds)` — the attribution rule
    /// `PitchCorrectionCurve.make` shapes with — timed at the frame CENTRE
    /// (`+ contour.frameValueOffsetSeconds`, the measured 8.58 ms detector
    /// lead), in cents against `detectedHz`.
    ///
    /// `nil` unless the contour is `.detected`: the editor's window detection
    /// is a different analysis (09-24 doc F18), and a reading of it would
    /// describe a line the render does not shape against.
    ///
    /// A segment whose `detectedHz` is not a positive number (a hand-built or
    /// corrupt one) is read against its own frames' median instead: the
    /// reference only shifts the fit's constant term, and `cents(from: 0, …)`
    /// would otherwise turn every frame into 0 and report `.noWobble` about a
    /// note nobody measured.
    public static func sung(_ segment: NoteSegment,
                            contour: PitchRenderContour) -> PitchWobbleReading? {
        guard let detection = contour.detection else { return nil }
        let offset = contour.frameValueOffsetSeconds
        var times: [Double] = []
        var hz: [Double] = []
        for frame in detection.frames {
            guard let f = frame.frequencyHz,
                  frame.timeSeconds >= segment.startSeconds,
                  frame.timeSeconds < segment.endSeconds else { continue }
            times.append(frame.timeSeconds + offset)
            hz.append(f)
        }
        let reference = segment.detectedHz > 0
            ? segment.detectedHz
            : (PitchCorrectionMath.medianFrequency(hz) ?? 0)
        let cents = hz.map { PitchCorrectionMath.cents(from: reference, to: $0) }
        return read(times: times, cents: cents)
    }

    /// **The PLAYED reading** (§8.1): the line's points attributed to the note
    /// by frame CENTRE in `[startSeconds, endSeconds)` — the
    /// `PitchPlayedLine.noteSummaries` rule — at `Point.editedSeconds`, in
    /// cents against the note's played median.
    ///
    /// The caller builds `line` (the DRAFT played line, with any drawn C5b
    /// shape cleared from its table copy — §8.1, §13); this only reads it.
    public static func played(_ segment: NoteSegment,
                              line: PitchPlayedLine) -> PitchWobbleReading {
        var times: [Double] = []
        var midi: [Double] = []
        for run in line.runs {
            for point in run where point.sourceSeconds >= segment.startSeconds
                && point.sourceSeconds < segment.endSeconds {
                times.append(point.editedSeconds)
                midi.append(point.playedMidi)
            }
        }
        let median = PitchCorrectionMath.median(midi) ?? 0
        return read(times: times, cents: midi.map { ($0 - median) * 100 })
    }

    // MARK: - The product's depth response (design §18.2, measured by T6)

    /// **How much of a real wobble's depth the PRODUCT CHAIN reads** at a
    /// note's pitch: the MEDIAN `read ÷ true` share that
    /// `PitchWobbleDetectorTests` (T6) measured — SwiftF0, then this
    /// estimator, on tones carrying a known wobble — for the measured pitch
    /// block covering `pitchHz`. `nil` outside every block, and `nil` for a
    /// block whose share could not be held inside [0.5, 1.1] (§18.4's stop
    /// condition).
    ///
    /// For the handoff seed (§18.2): `readDepth ÷ response(pitchHz:)` corrects
    /// the MEASUREMENT of what was sung; the generator still renders exactly
    /// the depth the model stores. Where this is `nil` the handoff is refused
    /// and the readout prints the speed only (§18.3).
    ///
    /// ⚠️ **A MEDIAN, NOT A PER-NOTE TRUTH.** Inside one block a single note's
    /// share spreads over the band T6 pins (`PitchWobbleDetectorTests`), so a
    /// calibrated depth is "about", never a measurement to print.
    public static func response(pitchHz: Double) -> Double? {
        guard pitchHz.isFinite, pitchHz > 0 else { return nil }
        for block in responseBlocks where block.coversHz.contains(pitchHz) {
            return block.medianShare
        }
        return nil
    }

    /// One measured pitch block of the product chain's depth response.
    struct ResponseBlock: Sendable, Equatable {
        /// The name T6 logs it under.
        let name: String
        /// The pitches T6 measured the block at, Hz, low to high.
        let measuredHz: [Double]
        /// Where the block's share applies (see `responseBlocks`).
        let coversHz: Range<Double>
        /// The MEDIAN read ÷ true share T6 measured over the block's notes,
        /// rounded to 0.01; `nil` where §18.4's stop condition fired.
        let medianShare: Double?
    }

    /// **The measured blocks, low to high** (§18.1.2 mid, §18.1.6 low).
    ///
    /// MEASURED 2026-09-24 (C5a-0b, `PitchWobbleDetectorTests`), read ÷ true
    /// over ±40/±80 c, 4.5–7.5 Hz, on the blocks' tones:
    ///  * **82.4 Hz — `nil`, STOPPED:** 0.303…0.827. An 8-partial ±40 c
    ///    wobble reads 0.30–0.39 of itself at every rate (`.noWobble`).
    ///  * **110.0 Hz — `nil`, STOPPED:** 0.472…0.976 (median 0.873). The
    ///    share falls with the RATE: an 8-partial ±40 c wobble reads 0.775 at
    ///    4.5 Hz and 0.472 at 7.5 Hz. No band inside [0.5, 1.1] holds it.
    ///  * **146.8 Hz — 0.83:** 0.740…0.895 (median 0.834, 32 notes).
    ///  * **mid 220–330 Hz — 0.88:** 0.747…0.987 (median 0.8775, 72 notes; ±40 c
    ///    alone 0.845, ±80 c alone 0.893 — the product's transfer is not linear
    ///    in depth, so no single share is exact).
    /// This singer's median note is 106 Hz: for most of their notes this
    /// returns `nil` (§18.3's speed-only row, the handoff refused).
    ///
    /// ⚠️ **WHERE A BLOCK APPLIES IS [INFERRED], not measured:** each pitch
    /// belongs to the block of its NEAREST measured pitch (the band edges are
    /// geometric midpoints between neighbouring measured pitches), and the two
    /// outer edges mirror the inner half-spacing, so no block reaches further
    /// past its outermost measured pitch than it reaches toward its neighbour.
    /// A pitch whose nearest measured pitch belongs to a `nil` block gets
    /// `nil`; it never borrows a neighbour's share. What IS measured about
    /// the edges (T6 `theResponseEdgesHold`): at 127.1, 179.7 and 380.8 Hz the
    /// product's share stays inside [0.5, 1.1] (0.774…1.085), but the edge
    /// medians sit up to 0.07 from their block's.
    static let responseBlocks: [ResponseBlock] = {
        let e2 = 82.4, a2 = 110.0, d3 = 146.8
        let mid = [220.0, 246.94, 329.63]
        func between(_ a: Double, _ b: Double) -> Double { (a * b).squareRoot() }
        let bottom = e2 * (e2 / a2).squareRoot()
        let top = mid[2] * (mid[2] / mid[1]).squareRoot()
        return [
            ResponseBlock(name: "82.4 Hz", measuredHz: [e2],
                          coversHz: bottom..<between(e2, a2), medianShare: nil),
            ResponseBlock(name: "110.0 Hz", measuredHz: [a2],
                          coversHz: between(e2, a2)..<between(a2, d3), medianShare: nil),
            ResponseBlock(name: "146.8 Hz", measuredHz: [d3],
                          coversHz: between(a2, d3)..<between(d3, mid[0]), medianShare: 0.83),
            ResponseBlock(name: "mid 220–330 Hz", measuredHz: mid,
                          coversHz: between(d3, mid[0])..<top, medianShare: 0.88),
        ]
    }()

    // MARK: - The analysis (internal: `read` is `analyse` then `step`)

    /// Everything the decision is made from. Internal so the validation can
    /// see WHICH refusal fired (the reading's `.tooUneven` covers two rules);
    /// `read` returns `reading`, which is `step` and nothing else.
    struct Analysis: Sendable, Equatable {
        /// The rule that decides the reading, in the order it is checked.
        enum Step: String, Sendable, Equatable {
            case belowFloor, scanEdge, tooShort, uneven, wobble
        }

        /// Best rate after the parabolic refinement (the edge rate, unrefined,
        /// when `atScanEdge`).
        let rateHz: Double
        let depthCents: Double
        let anchorSeconds: Double
        let fit: Double
        /// The best candidate was the first or the last of the scan.
        let atScanEdge: Bool
        /// First kept sample to last kept sample, seconds.
        let spanSeconds: Double
        /// Samples handed in (finite pairs) and samples fitted (after trims).
        let handedIn: Int
        let fitted: Int

        /// **THE DECISION ORDER.** §8.2 step 6's order — floor, then
        /// `tooShort`, then the fit — with step 4's scan-edge refusal placed
        /// AFTER the floor rather than before it. The floor is the REPORT
        /// floor, `reportFloorCents` (§18.1.4), not the detector's 12.90 c
        /// resolution floor.
        ///
        /// ⚠️ That placement DIVERGES from step 4's letter, deliberately: a
        /// FLAT note has `RSS(ω) ≈ 0` at every candidate, so its best
        /// candidate is an arbitrary one — the first, an edge, on an exact
        /// tie — and the edge rule firing first would read it `.tooUneven`
        /// where the negative control says `.noWobble`. With the floor
        /// first, a flat note is `.noWobble` BECAUSE its depth is under the
        /// floor, which is the claim. The edge rule still comes before
        /// `tooShort`, whose cycle count is meaningless at an edge rate.
        var step: Step {
            if depthCents < PitchWobbleEstimate.reportFloorCents { return .belowFloor }
            if atScanEdge { return .scanEdge }
            if spanSeconds * rateHz < PitchWobbleEstimate.minimumCycles { return .tooShort }
            if fit < PitchWobbleEstimate.minimumFit { return .uneven }
            return .wobble
        }

        var reading: PitchWobbleReading {
            switch step {
            case .belowFloor: return .noWobble
            case .scanEdge, .uneven: return .unmeasurable(.tooUneven)
            case .tooShort: return .unmeasurable(.tooShort)
            case .wobble:
                return .wobble(rateHz: rateHz, depthCents: depthCents,
                               anchorSeconds: anchorSeconds, fit: fit)
            }
        }
    }

    /// The analysis behind `read`, or `nil` wherever `read` refuses before
    /// fitting anything. Internal: for the validation.
    static func analyse(times: [Double], cents: [Double]) -> Analysis? {
        guard case .ready(let prepared) = Prepared.make(times: times, cents: cents) else {
            return nil
        }
        return analyse(prepared)
    }

    /// Scan, refine, refit (§8.2 steps 3–5). `nil` only when no candidate
    /// yields a solvable fit.
    static func analyse(_ p: Prepared) -> Analysis? {
        let count = Int(((scanRangeHz.upperBound - scanRangeHz.lowerBound) / scanStepHz)
            .rounded()) + 1
        var explained = [Double](repeating: -.infinity, count: count)
        p.scan(firstHz: scanRangeHz.lowerBound, stepHz: scanStepHz, into: &explained)

        var best = 0
        for j in 1..<count where explained[j] > explained[best] { best = j }
        guard explained[best].isFinite else { return nil }

        // Parabola through the best candidate and its two neighbours, on the
        // residual (RSS = RSS_trend − explained). An edge has one neighbour,
        // so it is not refined — and is refused below the floor check.
        let atEdge = best == 0 || best == count - 1
        var delta = 0.0
        if !atEdge, explained[best - 1].isFinite, explained[best + 1].isFinite {
            let below = -explained[best - 1], centre = -explained[best], above = -explained[best + 1]
            let curvature = below - 2 * centre + above
            if curvature > 0, curvature.isFinite {
                delta = min(0.5, max(-0.5, 0.5 * (below - above) / curvature))
            }
        }
        let rate = scanRangeHz.lowerBound + (Double(best) + delta) * scanStepHz
        guard let fit = p.fit(rateHz: rate) else { return nil }
        return Analysis(rateHz: rate,
                        depthCents: fit.depth,
                        anchorSeconds: p.anchor(of: fit, rateHz: rate),
                        fit: p.rssTrend > Prepared.negligibleRSS
                            ? min(1, max(0, fit.explained / p.rssTrend)) : 0,
                        atScanEdge: atEdge,
                        spanSeconds: p.spanSeconds,
                        handedIn: p.handedIn,
                        fitted: p.u.count)
    }

    // MARK: - The arithmetic

    /// The trimmed, centred, detrended samples every fit on one note shares.
    ///
    /// **The model** at angular rate ω is `c = p0 + p1·v + p2·v² + a·sin(ωu)
    /// + b·cos(ωu)`, where `u = t − t_mid` and `v = u / halfSpan` (the SAME
    /// quadratic in a scaled abscissa, for conditioning). It is solved as the
    /// full 5-parameter least squares, by Frisch–Waugh–Lovell: the samples
    /// are detrended once (`yd`, `rssTrend`), and per ω the sine and cosine
    /// are residualised against the quadratic, which leaves a 2 × 2 solve.
    /// That IS the joint fit, not a detrend-then-project approximation.
    struct Prepared: Sendable {
        /// A trend residual at or below this (cents², summed) is a flat note:
        /// there is no variance for a sine to explain, and `fit` is 0.
        static let negligibleRSS = 1e-9

        let handedIn: Int
        let u: [Double]
        let v: [Double]
        let yd: [Double]
        let rssTrend: Double
        /// (QᵀQ)⁻¹ for Q = [1, v, v²], row-major.
        let gram: [Double]
        let middleSeconds: Double
        let spanSeconds: Double

        /// What `make` produced: samples ready to fit, or the refusal that
        /// comes before any fit.
        enum Preparation { case ready(Prepared), refused(PitchWobbleShortfall) }

        struct Fit { let a: Double; let b: Double; let explained: Double
            var depth: Double { (a * a + b * b).squareRoot() }
        }

        /// The prepared samples, or the refusal that comes before any fit:
        /// `.tooFewSamples` below `minimumSamples` finite pairs; `.tooShort`
        /// when the kept samples have no duration to fit a quadratic across
        /// (fewer than three distinct instants).
        static func make(times: [Double], cents: [Double]) -> Preparation {
            var pairs: [(t: Double, c: Double)] = []
            pairs.reserveCapacity(min(times.count, cents.count))
            for (t, c) in zip(times, cents) where t.isFinite && c.isFinite {
                pairs.append((t, c))
            }
            guard pairs.count >= PitchWobbleEstimate.minimumSamples else {
                return .refused(.tooFewSamples)
            }
            pairs.sort { $0.t < $1.t }

            let trim = max(PitchWobbleEstimate.minimumTrimSamples,
                           Int(PitchWobbleEstimate.trimFraction * Double(pairs.count)))
            let kept = pairs[trim..<(pairs.count - trim)]
            guard let first = kept.first?.t, let last = kept.last?.t, last > first else {
                return .refused(.tooShort)
            }
            let middle = (first + last) / 2
            let half = (last - first) / 2
            let u = kept.map { $0.t - middle }
            let v = u.map { $0 / half }
            let y = kept.map(\.c)

            // The quadratic alone: its Gram matrix, inverse, and residual.
            var q = [Double](repeating: 0, count: 9)
            var qy = [Double](repeating: 0, count: 3)
            for i in v.indices {
                let v1 = v[i], v2 = v[i] * v[i]
                q[0] += 1; q[1] += v1; q[2] += v2
                q[4] += v1 * v1; q[5] += v1 * v2; q[8] += v2 * v2
                qy[0] += y[i]; qy[1] += v1 * y[i]; qy[2] += v2 * y[i]
            }
            q[3] = q[1]; q[6] = q[2]; q[7] = q[5]
            guard let gram = invert3(q) else { return .refused(.tooShort) }
            let beta = (0..<3).map { r in
                gram[3 * r] * qy[0] + gram[3 * r + 1] * qy[1] + gram[3 * r + 2] * qy[2]
            }
            var yd = [Double](repeating: 0, count: y.count)
            var rss = 0.0
            for i in y.indices {
                yd[i] = y[i] - (beta[0] + beta[1] * v[i] + beta[2] * v[i] * v[i])
                rss += yd[i] * yd[i]
            }
            return .ready(Prepared(handedIn: pairs.count, u: u, v: v, yd: yd, rssTrend: rss,
                                     gram: gram, middleSeconds: middle, spanSeconds: last - first))
        }

        /// The 5-parameter fit at one rate, from fresh sines and cosines.
        func fit(rateHz: Double) -> Fit? {
            let omega = 2 * Double.pi * rateHz
            var sums = Sums()
            for i in u.indices {
                sums.add(s: sin(omega * u[i]), c: cos(omega * u[i]), v: v[i], y: yd[i])
            }
            return solve(sums)
        }

        /// `explained[j]` for candidate `firstHz + j·stepHz`: the variance the
        /// sine removes beyond the quadratic, i.e. `RSS_trend − RSS(ω)`.
        /// `-∞` where the fit is degenerate.
        ///
        /// Sines advance by an exact rotation per step (`sin(ω+Δ)u` from
        /// `sin ωu`, `cos ωu` and a per-sample `sin Δu`, `cos Δu`), re-seeded
        /// from `sin`/`cos` every 50 candidates so rounding cannot accumulate.
        func scan(firstHz: Double, stepHz: Double, into explained: inout [Double]) {
            let n = u.count
            let deltaOmega = 2 * Double.pi * stepHz
            let rotateCos = u.map { cos(deltaOmega * $0) }
            let rotateSin = u.map { sin(deltaOmega * $0) }
            var s = [Double](repeating: 0, count: n)
            var c = [Double](repeating: 0, count: n)
            for j in explained.indices {
                let omega = 2 * Double.pi * (firstHz + Double(j) * stepHz)
                var sums = Sums()
                if j % 50 == 0 {
                    for i in 0..<n {
                        s[i] = sin(omega * u[i])
                        c[i] = cos(omega * u[i])
                        sums.add(s: s[i], c: c[i], v: v[i], y: yd[i])
                    }
                } else {
                    for i in 0..<n {
                        let nextS = s[i] * rotateCos[i] + c[i] * rotateSin[i]
                        let nextC = c[i] * rotateCos[i] - s[i] * rotateSin[i]
                        s[i] = nextS
                        c[i] = nextC
                        sums.add(s: nextS, c: nextC, v: v[i], y: yd[i])
                    }
                }
                explained[j] = solve(sums)?.explained ?? -.infinity
            }
        }

        /// The rising zero crossing of the fitted sine nearest the middle of
        /// the kept span: `a·sin(ωu) + b·cos(ωu) = A·sin(ωu + φ)` with
        /// `φ = atan2(b, a)` rises through zero at `u = −φ/ω`, which
        /// `atan2`'s range already places within half a period of the middle.
        func anchor(of fit: Fit, rateHz: Double) -> Double {
            let omega = 2 * Double.pi * rateHz
            let period = 1 / rateHz
            var tau = middleSeconds - atan2(fit.b, fit.a) / omega
            tau -= ((tau - middleSeconds) / period).rounded() * period
            return tau
        }

        /// Running sums for one candidate rate.
        struct Sums {
            var s = 0.0, vs = 0.0, v2s = 0.0
            var c = 0.0, vc = 0.0, v2c = 0.0
            var ss = 0.0, sc = 0.0, cc = 0.0
            var sy = 0.0, cy = 0.0

            @inline(__always)
            mutating func add(s si: Double, c ci: Double, v vi: Double, y yi: Double) {
                let v2 = vi * vi
                s += si; vs += vi * si; v2s += v2 * si
                c += ci; vc += vi * ci; v2c += v2 * ci
                ss += si * si; sc += si * ci; cc += ci * ci
                sy += si * yi; cy += ci * yi
            }
        }

        /// Frisch–Waugh–Lovell: residualise sin and cos against the quadratic
        /// (`x⊥·y⊥ = x·y − (Qᵀx)ᵀ(QᵀQ)⁻¹(Qᵀy)`), then the 2 × 2 normal solve.
        /// `yd` is already orthogonal to the quadratic, so `s⊥·yd = s·yd`.
        func solve(_ m: Sums) -> Fit? {
            let qs = (m.s, m.vs, m.v2s)
            let qc = (m.c, m.vc, m.v2c)
            func quadratic(_ x: (Double, Double, Double), _ y: (Double, Double, Double)) -> Double {
                let g = gram
                let gy0 = g[0] * y.0 + g[1] * y.1 + g[2] * y.2
                let gy1 = g[3] * y.0 + g[4] * y.1 + g[5] * y.2
                let gy2 = g[6] * y.0 + g[7] * y.1 + g[8] * y.2
                return x.0 * gy0 + x.1 * gy1 + x.2 * gy2
            }
            let sss = m.ss - quadratic(qs, qs)
            let ssc = m.sc - quadratic(qs, qc)
            let scc = m.cc - quadratic(qc, qc)
            let det = sss * scc - ssc * ssc
            guard det.isFinite, sss > 0, scc > 0, det > 1e-12 * sss * scc else { return nil }
            let a = (scc * m.sy - ssc * m.cy) / det
            let b = (sss * m.cy - ssc * m.sy) / det
            let explained = a * m.sy + b * m.cy
            guard a.isFinite, b.isFinite, explained.isFinite else { return nil }
            return Fit(a: a, b: b, explained: explained)
        }

        /// Inverse of a symmetric 3 × 3 (row-major), or `nil` when singular.
        static func invert3(_ m: [Double]) -> [Double]? {
            let c00 = m[4] * m[8] - m[5] * m[7]
            let c01 = m[5] * m[6] - m[3] * m[8]
            let c02 = m[3] * m[7] - m[4] * m[6]
            let det = m[0] * c00 + m[1] * c01 + m[2] * c02
            guard det.isFinite, abs(det) > 1e-12 * max(1, abs(m[0] * m[4] * m[8])) else {
                return nil
            }
            let c10 = m[2] * m[7] - m[1] * m[8]
            let c11 = m[0] * m[8] - m[2] * m[6]
            let c12 = m[1] * m[6] - m[0] * m[7]
            let c20 = m[1] * m[5] - m[2] * m[4]
            let c21 = m[2] * m[3] - m[0] * m[5]
            let c22 = m[0] * m[4] - m[1] * m[3]
            return [c00 / det, c10 / det, c20 / det,
                    c01 / det, c11 / det, c21 / det,
                    c02 / det, c12 / det, c22 / det]
        }
    }
}
