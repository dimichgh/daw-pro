import Foundation

// p2-seg S2 — automatic note splitting INSIDE an unbroken voiced run.
// Design: `docs/design/2026-09-24-pitch-note-splitting.md` §1 (the rule), §2 (the
// over-split guard), §12/§14 (rulings that amend it), §13 (the measured bounds).
//
// ⭐ **`voicedRuns` IS THE RUN RULE AND IS NOT CHANGED; THIS IS LAYERED ON TOP.**
// A run is a stretch the singer never stopped in. A NOTE is a part of a run. The
// played line and the editor's measured contour stay per RUN (a cut inside a run
// would draw a hole where the singer never stopped); only the two NOTE-TABLE
// builders — `PitchAutoCorrect.editSet` and `PitchNoteTable.detected` — read parts.
// That is what keeps "the editor and the corrector cannot disagree about what a
// note is": both call `parts(in:frameRateHz:onsetSeconds:)` and nothing else.
//
// ⭐ **A RUN WITH NOTHING TO SPLIT COMES OUT AS THE `VoicedRun` ITSELF, FIELD FOR
// FIELD** (design §2.4). The no-split branch returns the run's own numbers, never
// recomputed ones, so over-split protection and backward compatibility are ONE
// property, and `PitchNoteSplitterTests` checks it on every fixture.
//
// Pure: no clock, no I/O, no store, no engine. It runs on the main actor inside
// the two builders, never on the render thread (design §0 "Invariants checked").

/// One NOTE of a voiced run: a held plateau, or a transition (a slide into, between
/// or out of held notes) that lasted longer than the scoop limit.
///
/// Frame convention (design §1.1): a part covers whole detector frames. Its outer
/// edges are its run's own `startSeconds`/`endSeconds`; every INTERIOR boundary is
/// the first frame of the next part (its `timeSeconds`), so two abutting parts share
/// that boundary bit for bit and `PitchEditSet.canonical` has nothing to heal.
/// (`last.timeSeconds + 1/rate` would only abut to ~1e-15 s — measured 3.6e-15 s on
/// the user's take, design §11.5 — and the canonicaliser would then trim or gap.)
public struct NotePart: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// A held note: one plateau (§1.3 step 3–4) plus any leftover of at most
        /// the scoop limit absorbed into it (step 5). ⚠️ A run that is NOT split is
        /// ONE `.held` part equal to its `VoicedRun`, whatever its shape — a pure
        /// glide or a shaky note included (§1.3 step 6): it is today's note, and
        /// every slide shape maps it to today's segment.
        case held
        /// A lead-in, link or tail-off LONGER than the scoop limit (§1.3 step 5).
        /// What a correction does to it is the slide-shape policy
        /// (`PitchAutoCorrect.slideShape`), never this type's business.
        case transition
    }

    public let kind: Kind
    /// Source-file seconds, the `ClipPitchFrame.timeSeconds` domain.
    public let startSeconds: Double
    public let endSeconds: Double
    /// MEDIAN of the part's own raw frames, Hz — `VoicedRun.centreHz`'s estimator
    /// (`PitchCorrectionMath.medianFrequency`). For an unsplit run it IS the run's.
    public let centreHz: Double
    /// Median of the part's per-frame confidences. Voicing evidence only.
    public let medianConfidence: Double
    /// How many voiced frames the part covers.
    public let frameCount: Int
    /// Which `PitchAutoCorrect.voicedRuns` element the part came from.
    public let runIndex: Int
    /// That run's OWN median (`VoicedRun.centreHz`). Slide shape (c) locks every
    /// part of a run to the run's note (design §3.2), which no single part carries.
    public let runCentreHz: Double

    public init(kind: Kind, startSeconds: Double, endSeconds: Double, centreHz: Double,
                medianConfidence: Double, frameCount: Int, runIndex: Int, runCentreHz: Double) {
        self.kind = kind
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.centreHz = centreHz
        self.medianConfidence = medianConfidence
        self.frameCount = frameCount
        self.runIndex = runIndex
        self.runCentreHz = runCentreHz
    }

    /// The unsplit run, as one part: every number is the `VoicedRun`'s own (§2.4).
    init(unsplit run: VoicedRun, runIndex: Int) {
        self.init(kind: .held, startSeconds: run.startSeconds, endSeconds: run.endSeconds,
                  centreHz: run.centreHz, medianConfidence: run.medianConfidence,
                  frameCount: run.frameCount, runIndex: runIndex, runCentreHz: run.centreHz)
    }
}

/// The note splitter (design §1.3), on top of `PitchAutoCorrect.voicedRuns`.
///
/// **The rule, per run, in cents relative to the run's own median:**
///  1. de-glitch: a centred running median `x` of width `deglitchSeconds`;
///  2. centre track: a centred running median `y` of `x` over `P` frames, one
///     cycle of the slowest wobble the product models;
///     ⚠️ both windows SHRINK SYMMETRICALLY at the run's edges and never read
///     across one (design §12 item 6 — an edge-CLAMPED window changes 10 of the
///     user's 42 runs, §11.6; a fixture pins the symmetric rule);
///  3. plateaus: a greedy left-to-right scan of `y` that grows a stretch while
///     `max(y) − min(y) ≤ B` and accepts it at `≥ T` frames (then continues at the
///     frame that broke the band), else advances one frame;
///  4. merge: neighbouring plateaus, with the frames between them, merge while
///     their centres — the MEAN of `x` over each plateau — differ by less than
///     `τ_long` (both plateaus ≥ `P` frames) or `τ_short` (either shorter); the
///     FIRST qualifying pair left to right merges, then the scan restarts;
///  5. leftovers: a lead-in or tail-off of `≤ S` frames joins its plateau; a link
///     of `≤ S` frames is cut at ONE frame (at an onset when §1.5 finds one, else
///     at the first link frame whose `x` crosses the mean of the two plateau
///     centres; no crossing → the link's end); anything longer is a `.transition`;
///  6. emit: zero plateaus, or one plateau and no transition → the `VoicedRun`
///     itself; otherwise one `.held` per plateau and one `.transition` per long
///     leftover, each centred on the MEDIAN of its own raw frames.
///
/// Every frame count derives from the frame rate (`frameCounts(frameRateHz:)`):
/// a backend with a different rate gets the same SECONDS, rounded up to whole
/// frames. Onsets only ever MOVE a cut f0 already found; an onset alone never cuts
/// (§1.2, §1.5).
public enum PitchNoteSplitter {

    // MARK: - The constants — each is the ONE home for its number

    /// **De-glitch width, seconds** (§1.4 row 1): 80 ms = 5 frames at 62.5 fps
    /// (rounded UP to an odd count, so the median is centred).
    ///
    /// Bounds, both facts: a width-5 median REMOVES every feature of ≤ 2 frames —
    /// the isolated 1-frame and short octave-high glitches measured on the user's
    /// take (vibrato doc §18.5) — and KEEPS every feature of ≥ 3 frames, which is
    /// under `PitchAutoCorrect.minimumNoteSeconds` (0.06 s = 4 frames), so no real
    /// note can be de-glitched away. `frameCounts` carries both numbers and
    /// `PitchNoteSplitterTests` checks the second bound at several rates.
    public static let deglitchSeconds: Double = 0.080

    /// **`B`, the plateau band, cents** (§1.4): a held note's centre track `y`
    /// stays within this.
    ///
    /// Lower bound (a fact about the detector): SwiftF0 outputs 25.79 c bins
    /// (`PitchCorrectionMath.detectorResolutionFloorCents` is half of one), so a
    /// median of quantised frames moves in WHOLE bins; measured synthetic, a steady
    /// ±37 c or ±50 c note's `y` strays at most one bin from its centre, so a
    /// steady note spans ≤ 2 bins = 51.6 c. Upper bound: a semitone step (100 c)
    /// must break the band (measured: a 199 c and a 70 c step both do).
    public static let plateauBandCents: Double = 52

    /// **`T`, the shortest plateau, seconds: 0.128 s = 8 frames at 62.5 fps**
    /// (§1.4, re-picked with measured bounds by R1, §13.1; ruled §14 item 1).
    ///
    /// * Lower bound — no fake notes on a slide [MEASURED synthetic, 16 bin
    ///   offsets × 10 lengths = 160 fixtures per speed]: a wobble-free slide at
    ///   700 c/s keeps `y` inside the band for 7 frames, at 800 c/s for 6–7, so
    ///   8 is the smallest T that rejects both (0 of 160 split at every speed
    ///   ≥ 700 c/s). At T = 7, 147/160 split at 700 c/s and §5.3's own 800 c/s ×
    ///   1 s fixture comes out `T H7 T` at 6 of 16 offsets. Margin: 1 frame.
    /// * Upper bound — catch the held notes [MEASURED real take]: the shortest
    ///   plateaus that must lock are exactly 8 frames (0:16.4's D3 tail, 0:31.4's
    ///   D3, 0:09.2's A2). Margin: 0 — the ≥ 2-frame margin cannot be met on this
    ///   take (T ≤ 6 breaks §2.5), a fact about the take, not a choice (§13.1).
    /// * Recorded cost at 8: run 28 (23.712 s) keeps its 7-frame A#2 tail absorbed
    ///   and Hard Tune plays it ~150 c flat (§13.4, §15.2; filed p2-seg-F-tail).
    /// * ⚠️ **R1's FLIP CONDITION (§13.1, §14 item 1):** if the slow-slide floor is
    ///   moved from 800 to 900 c/s (with §5.3's fixture moved with it), T = 7 is
    ///   better on every real-take and jitter measure (0 single-frame ops unlock a
    ///   named held note against 26 at T = 8; run 28's tail is caught). The flip is
    ///   this ONE line plus a gate re-run — but §14 item 1 measured a REAL fake
    ///   plateau at T = 7 (run 24, 19.280 s, a wobbling rise), which is why it
    ///   stands at 8.
    public static let minimumPlateauSeconds: Double = 0.128

    /// **`S`, the scoop / release limit, seconds: 0.128 s = 8 frames at 62.5 fps**
    /// (§1.4; R1, §13.1). A lead-in, link or tail-off of at most this belongs to
    /// its plateau; a longer one is its own `.transition`.
    ///
    /// * Lower bound [MEASURED synthetic, 640 scoops of 48–120 ms, 100–500 c, with
    ///   and without ±37 c wobble]: every scoop ≤ 120 ms leaves a lead-in of at
    ///   most 7 frames, so S = 8 keeps all 640 whole with 1 frame to spare (S = 6
    ///   splits 59–62 of them, breaking §2.2).
    /// * Upper bound [MEASURED real take]: the take's short links are 7, 7
    ///   (0:07.6) and 8 frames (0:22.6), so no S in 6…8 has 2 frames of margin to
    ///   all three. At S = 8, 0:22.6's 8-frame link is absorbed (cut at one frame):
    ///   both its held notes still lock (§13.1).
    /// * Recorded (§13.3, §14 item 4): wobbling RELEASES of 96–120 ms leave
    ///   tail-offs of up to 11 frames, and 23 of 640 split at S = 8 — §2.2's
    ///   release claim fails at the top of its range. Not retuned.
    /// * The flip condition that applies to T applies here: any change is a
    ///   re-run of R1's sweep, never a blind edit.
    public static let scoopLimitSeconds: Double = 0.128

    /// **`τ_long`, cents**: two plateaus that are BOTH at least `P` frames long
    /// merge when their centres (mean of `x`) differ by less than this (§1.4).
    ///
    /// Lower bound: a mean over at least one full cycle cancels the wobble to
    /// ≤ 0.217 × depth (the sinc's first sidelobe) and averages the bin staircase
    /// down. Upper bound: half a semitone, where `nearestAllowedMidi` flips on a
    /// chromatic scale — a smaller step cannot move a snapped note further than it
    /// moves the sung one.
    public static let mergeLongCents: Double = 50

    /// **`τ_short`, cents**: the merge threshold when EITHER plateau is shorter
    /// than `P` frames (§1.4).
    ///
    /// Lower bound [MEASURED synthetic, full-bin quantisation, 3–9 Hz, 16
    /// phases]: the worst mean-of-`x` difference between two ADJACENT 8-frame
    /// windows of ONE steady wobbling note is 45.1 c for a ±37 c reading and
    /// 80.6 c for a ±50 c one, so anything above 80.6 c keeps a wobble up to a
    /// ±50 c reading as one note. Upper bound: one semitone, the smallest scale
    /// step. It takes the top of (80.6, 100] because 80 c did NOT reduce F-semi
    /// (eighth notes 100 c apart still gave 2–4 parts), so a lower value buys
    /// nothing and gives up margin.
    public static let mergeShortCents: Double = 100

    // MARK: - Frame counts

    /// The rule's frame counts at one frame rate.
    public struct FrameCounts: Sendable, Equatable {
        /// De-glitch median width (odd).
        public let deglitch: Int
        /// `P`: the centre-track median width (odd) — one cycle of the slowest
        /// wobble, `PitchWobbleEstimate.scanRangeHz.lowerBound` (3.0 Hz): 21 frames
        /// (336 ms) at 62.5 fps. ⚠️ NOT `NoteSegment.vibratoRateHzRange` (0…8, the
        /// GENERATED-vibrato range, where 0 means off).
        public let centreTrack: Int
        /// `T`, frames.
        public let minimumPlateau: Int
        /// `S`, frames.
        public let scoopLimit: Int
        /// `PitchAutoCorrect.minimumNoteSeconds` in whole frames — the bound the
        /// others are held against: the de-glitch keeps features of
        /// `(deglitch + 1) / 2` frames, which must not exceed it, and `T` and `S`
        /// must exceed it, so neither a `.held` nor a `.transition` part can be
        /// shorter than a note (§1.3 step 6).
        public let minimumNote: Int
    }

    /// The product rule's frame counts at `frameRateHz`, or `nil` for a rate that
    /// is not a real positive number (the same inputs `voicedRuns` answers with
    /// no runs).
    public static func frameCounts(frameRateHz: Double) -> FrameCounts? {
        Rule.product.frameCounts(frameRateHz: frameRateHz)
    }

    // MARK: - The splitter

    /// Split every voiced run of `frames` into its notes.
    ///
    /// - Parameters:
    ///   - frames: a detection's frames, voiced and unvoiced, in any order —
    ///     exactly what `PitchAutoCorrect.voicedRuns` accepts, and that function is
    ///     what finds the runs; this never re-derives a run edge.
    ///   - frameRateHz: the detector's own reported rate.
    ///   - onsetSeconds: onset markers in SOURCE-FILE seconds (the
    ///     `detectTransients` domain). They only MOVE a short-link cut that f0
    ///     already found (§1.5), never create one. ⚠️ **Every production caller
    ///     passes `[]`**: onset placement (S3) is not scheduled (design §12 item 3
    ///     — across the take's 17 cuts onsets landed within ±2 frames 6 times, no
    ///     better than chance), and the frames' time base is still only [INFERRED]
    ///     to match the markers' (F-time).
    /// - Returns: the parts of every run, in time order. A run that does not split
    ///   is ONE `.held` part equal to its `VoicedRun` (§2.4). Empty exactly when
    ///   `voicedRuns` is.
    public static func parts(in frames: [ClipPitchFrame], frameRateHz: Double,
                             onsetSeconds: [Double] = []) -> [NotePart] {
        parts(in: frames, frameRateHz: frameRateHz, onsetSeconds: onsetSeconds, rule: .product)
    }

    /// The same, under an explicit rule. `Rule.product` is the ONLY rule the product
    /// uses; a test builds a PLANTED rule (one constant moved) to prove that a
    /// threshold pin can fail, without editing this file.
    static func parts(in frames: [ClipPitchFrame], frameRateHz: Double,
                      onsetSeconds: [Double], rule: Rule) -> [NotePart] {
        analyse(frames, frameRateHz: frameRateHz, onsetSeconds: onsetSeconds, rule: rule)
            .flatMap(\.parts)
    }

    // MARK: - The rule, as one value

    /// The rule's numbers in one value. `product` is built from the named
    /// constants above and from `PitchWobbleEstimate.scanRangeHz.lowerBound`, and
    /// from nothing else.
    struct Rule: Sendable, Equatable {
        var deglitchSeconds: Double
        var slowestWobbleHz: Double
        var plateauBandCents: Double
        var minimumPlateauSeconds: Double
        var scoopLimitSeconds: Double
        var mergeLongCents: Double
        var mergeShortCents: Double

        static let product = Rule(
            deglitchSeconds: PitchNoteSplitter.deglitchSeconds,
            slowestWobbleHz: PitchWobbleEstimate.scanRangeHz.lowerBound,
            plateauBandCents: PitchNoteSplitter.plateauBandCents,
            minimumPlateauSeconds: PitchNoteSplitter.minimumPlateauSeconds,
            scoopLimitSeconds: PitchNoteSplitter.scoopLimitSeconds,
            mergeLongCents: PitchNoteSplitter.mergeLongCents,
            mergeShortCents: PitchNoteSplitter.mergeShortCents)

        func frameCounts(frameRateHz: Double) -> FrameCounts? {
            let rate = PitchCorrectionMath.finite(frameRateHz, default: 0)
            guard rate > 0, slowestWobbleHz > 0 else { return nil }
            return FrameCounts(
                deglitch: PitchNoteSplitter.oddFrames(atLeast: deglitchSeconds * rate),
                centreTrack: PitchNoteSplitter.oddFrames(atLeast: rate / slowestWobbleHz),
                minimumPlateau: PitchNoteSplitter.wholeFrames(atLeast: minimumPlateauSeconds * rate),
                scoopLimit: PitchNoteSplitter.wholeFrames(atLeast: scoopLimitSeconds * rate),
                minimumNote: PitchNoteSplitter.wholeFrames(
                    atLeast: PitchAutoCorrect.minimumNoteSeconds * rate))
        }
    }

    /// Seconds × rate, rounded UP to whole frames.
    ///
    /// ⚠️ **The `1e-9` is load-bearing.** `0.128 × 62.5` and `0.080 × 62.5` are not
    /// exact in binary floating point; a product one ulp above the integer would
    /// round UP to 9 and 6. A frame count within a billionth of an integer IS that
    /// integer. `PitchNoteSplitterTests` pins (5, 21, 8, 8) at 62.5 fps.
    static func wholeFrames(atLeast value: Double) -> Int {
        guard value.isFinite, value > 0 else { return 1 }
        return max(1, Int((value - 1e-9).rounded(.up)))
    }

    /// The smallest ODD whole-frame count ≥ `value` (a median over an odd count is
    /// centred and is an element of the window).
    static func oddFrames(atLeast value: Double) -> Int {
        let k = wholeFrames(atLeast: value)
        return k % 2 == 1 ? k : k + 1
    }

    // MARK: - The analysis (internal: tests pin its intermediate stages)

    /// One run, analysed. Every index is RUN-LOCAL (0 is the run's first frame).
    struct RunAnalysis: Sendable {
        let run: VoicedRun
        let runIndex: Int
        /// The run's frames, in time order — `nil` when they could not be
        /// re-found (defensive; then the run is emitted unsplit).
        let frames: [ClipPitchFrame]?
        /// Raw cents relative to the run's own median, the de-glitched track `x`,
        /// and the centre track `y`.
        let cents: [Double]
        let x: [Double]
        let y: [Double]
        /// Step 3's plateaus, and what step 4 left of them.
        let rawPlateaus: [Range<Int>]
        let plateaus: [Range<Int>]
        /// Each emitted part's frame range, in time order, with its kind.
        let ranges: [(kind: NotePart.Kind, frames: Range<Int>)]
        let parts: [NotePart]
    }

    /// Every run of `frames`, analysed under `rule`.
    static func analyse(_ frames: [ClipPitchFrame], frameRateHz: Double,
                        onsetSeconds: [Double], rule: Rule) -> [RunAnalysis] {
        let runs = PitchAutoCorrect.voicedRuns(in: frames, frameRateHz: frameRateHz)
        guard !runs.isEmpty, let counts = rule.frameCounts(frameRateHz: frameRateHz) else { return [] }
        // Non-empty runs mean the rate passed `voicedRuns`' own guard; the period
        // is computed exactly as it computes a run's end.
        let period = 1 / PitchCorrectionMath.finite(frameRateHz, default: 0)
        // THE ORDER `voicedRuns` WALKS — the same sort on the same input — so the
        // frames of run k are found again by position, not by a time window.
        let ordered = frames.sorted { $0.timeSeconds < $1.timeSeconds }
        let onsets = onsetSeconds.filter(\.isFinite).sorted()
        var cursor = 0
        return runs.enumerated().map { index, run in
            let runFrames = Self.frames(of: run, in: ordered, cursor: &cursor, period: period)
            return analyse(run: run, runIndex: index, frames: runFrames, counts: counts,
                           rule: rule, onsets: onsets, period: period)
        }
    }

    /// Re-find a run's frames in the sorted input: `frameCount` consecutive voiced
    /// frames starting at the first voiced frame (at or after `cursor`) whose time
    /// is the run's start, and ending exactly where the run says it ends. `nil`
    /// (and the cursor untouched) if anything does not line up.
    private static func frames(of run: VoicedRun, in ordered: [ClipPitchFrame],
                               cursor: inout Int, period: Double) -> [ClipPitchFrame]? {
        var i = cursor
        while i < ordered.count,
              !(ordered[i].frequencyHz != nil && ordered[i].timeSeconds == run.startSeconds) {
            i += 1
        }
        guard i < ordered.count, run.frameCount > 0, i + run.frameCount <= ordered.count else {
            return nil
        }
        let slice = ordered[i ..< i + run.frameCount]
        // A non-finite frame time cannot be a part boundary (`NoteSegment` would
        // heal it to 0), so such a run is emitted whole — `ClipPitchFrame` does
        // not validate its time, and the detector never produces one.
        guard slice.allSatisfy({ $0.frequencyHz != nil && $0.timeSeconds.isFinite }),
              let last = slice.last, last.timeSeconds + period == run.endSeconds else { return nil }
        cursor = i + run.frameCount
        return Array(slice)
    }

    /// §1.3 on one run.
    ///
    /// ⭐ **DECISION FOR DECISION, THIS IS S1's `split_run`** (the python in the
    /// durable p2-seg folder, `s1/s1-split.py`, that R1 swept and item L rendered
    /// the listening set from): the same windows, the same greedy scan, the same
    /// first-pair merge, the same crossing rule. `NoteSplitListeningTests` pass 3
    /// compares every run's parts against that file's cut list and renders the
    /// result against L's WAVs bit for bit. The ONE deliberate difference is the
    /// time of an interior boundary (see `NotePart`): S1 wrote
    /// `last.timeSeconds + 1/rate`, L rendered the next part's first frame time,
    /// and this is L's.
    private static func analyse(run: VoicedRun, runIndex: Int, frames: [ClipPitchFrame]?,
                                counts: FrameCounts, rule: Rule, onsets: [Double],
                                period: Double) -> RunAnalysis {
        func whole(cents: [Double] = [], x: [Double] = [], y: [Double] = [],
                   rawPlateaus: [Range<Int>] = [], plateaus: [Range<Int>] = []) -> RunAnalysis {
            RunAnalysis(run: run, runIndex: runIndex, frames: frames, cents: cents, x: x, y: y,
                        rawPlateaus: rawPlateaus, plateaus: plateaus,
                        ranges: [(.held, 0 ..< run.frameCount)],
                        parts: [NotePart(unsplit: run, runIndex: runIndex)])
        }
        // Defensive, never reached by the detector: frames that could not be
        // re-found, or a pitch that is not a real positive number (decoding and
        // `var` mutation both bypass `ClipPitchFrame`'s precondition). Such a run
        // is today's note, whole — never a NaN in a cents track.
        guard let frames, frames.count == run.frameCount,
              run.centreHz.isFinite, run.centreHz > 0 else { return whole() }
        var hz: [Double] = []
        hz.reserveCapacity(frames.count)
        for frame in frames {
            guard let f = frame.frequencyHz, f.isFinite, f > 0 else { return whole() }
            hz.append(f)
        }
        let n = hz.count
        // Every number below is in cents relative to the run's OWN centre (§1.3).
        let cents = hz.map { 1200 * log2($0 / run.centreHz) }
        guard cents.allSatisfy(\.isFinite) else { return whole() }

        // 1. De-glitch, and 2. the centre track. Both windows shrink
        //    SYMMETRICALLY at the run's edges (§12 item 6).
        let x = runningMedian(cents, halfWidth: counts.deglitch / 2)
        let y = runningMedian(x, halfWidth: counts.centreTrack / 2)
        // 3. Plateaus, and 4. what merging leaves of them.
        let rawPlateaus = plateauScan(y, band: rule.plateauBandCents, minimumLength: counts.minimumPlateau)
        let plateaus = merge(rawPlateaus, x: x, longLength: counts.centreTrack, rule: rule)
        guard let first = plateaus.first, let last = plateaus.last else {
            // Zero plateaus: a pure glide, a shaky note — today's note (§1.3 step 6).
            return whole(cents: cents, x: x, y: y, rawPlateaus: rawPlateaus, plateaus: plateaus)
        }

        // 5. The leftovers. `spans` are the held parts: each plateau, grown by
        //    whatever short leftover it absorbs.
        var spans = plateaus
        var transitions: [Range<Int>] = []
        let leadIn = 0 ..< first.lowerBound
        if leadIn.count > counts.scoopLimit {
            transitions.append(leadIn)
        } else {
            spans[0] = 0 ..< spans[0].upperBound
        }
        let tailOff = last.upperBound ..< n
        if tailOff.count > counts.scoopLimit {
            transitions.append(tailOff)
        } else {
            spans[spans.count - 1] = spans[spans.count - 1].lowerBound ..< n
        }
        for i in plateaus.indices.dropLast() {
            let link = plateaus[i].upperBound ..< plateaus[i + 1].lowerBound
            if link.count > counts.scoopLimit {
                transitions.append(link)
                continue
            }
            let cut = linkCut(link, x: x, left: meanCentre(plateaus[i], x), right: meanCentre(plateaus[i + 1], x),
                              frames: frames, onsets: onsets, period: period)
            spans[i] = spans[i].lowerBound ..< cut
            spans[i + 1] = cut ..< spans[i + 1].upperBound
        }

        // 6. Emit. One plateau and no transition is today's note, whole.
        guard plateaus.count > 1 || !transitions.isEmpty else {
            return whole(cents: cents, x: x, y: y, rawPlateaus: rawPlateaus, plateaus: plateaus)
        }
        let ranges = (spans.map { (kind: NotePart.Kind.held, frames: $0) }
                      + transitions.map { (kind: NotePart.Kind.transition, frames: $0) })
            .sorted { $0.frames.lowerBound < $1.frames.lowerBound }
        var parts: [NotePart] = []
        parts.reserveCapacity(ranges.count)
        for (k, range) in ranges.enumerated() {
            // Outer edges are the run's own; an interior boundary is the next
            // part's first frame START, so neighbours share it bit for bit.
            let start = k == 0 ? run.startSeconds : frames[range.frames.lowerBound].timeSeconds
            let end = k == ranges.count - 1
                ? run.endSeconds : frames[ranges[k + 1].frames.lowerBound].timeSeconds
            // Each part is centred on the MEDIAN of its own raw frames: the
            // estimator `voicedRuns` uses for a run (§1.3 step 6).
            guard let centre = PitchCorrectionMath.medianFrequency(Array(hz[range.frames])),
                  end > start else { return whole(cents: cents, x: x, y: y,
                                                  rawPlateaus: rawPlateaus, plateaus: plateaus) }
            parts.append(NotePart(
                kind: range.kind, startSeconds: start, endSeconds: end, centreHz: centre,
                medianConfidence: PitchCorrectionMath.median(frames[range.frames].map(\.confidence)) ?? 0,
                frameCount: range.frames.count, runIndex: runIndex, runCentreHz: run.centreHz))
        }
        return RunAnalysis(run: run, runIndex: runIndex, frames: frames, cents: cents, x: x, y: y,
                           rawPlateaus: rawPlateaus, plateaus: plateaus, ranges: ranges, parts: parts)
    }

    // MARK: - The steps

    /// A centred running median of odd width `2·halfWidth + 1` whose window
    /// SHRINKS SYMMETRICALLY near an edge (width `2·min(halfWidth, k, n−1−k) + 1`
    /// at index `k`), so it never reads across the run's edge and is always
    /// centred. Every window is odd, so every output is an ELEMENT of its input.
    /// ⚠️ A monotone edge is a fixed point of this filter; an edge-CLAMPED window
    /// is not, and changes 10 of the user's 42 runs (design §11.6, §12 item 6).
    static func runningMedian(_ values: [Double], halfWidth: Int) -> [Double] {
        let n = values.count
        guard halfWidth > 0, n > 2 else { return values }
        var out = [Double](repeating: 0, count: n)
        var window: [Double] = []
        window.reserveCapacity(2 * halfWidth + 1)
        for k in 0 ..< n {
            let h = min(halfWidth, k, n - 1 - k)
            window.removeAll(keepingCapacity: true)
            window.append(contentsOf: values[(k - h) ... (k + h)])
            window.sort()
            out[k] = window[h]
        }
        return out
    }

    /// §1.3 step 3: scan `y` left to right; grow a stretch while
    /// `max − min ≤ band`; accept it at `≥ minimumLength` frames and continue AT
    /// the frame that broke the band, else advance one frame. Greedy, no look-back.
    static func plateauScan(_ y: [Double], band: Double, minimumLength: Int) -> [Range<Int>] {
        var plateaus: [Range<Int>] = []
        var s = 0
        while s < y.count {
            var lo = y[s], hi = y[s]
            var e = s + 1
            while e < y.count, max(hi, y[e]) - min(lo, y[e]) <= band {
                lo = min(lo, y[e])
                hi = max(hi, y[e])
                e += 1
            }
            if e - s >= minimumLength {
                plateaus.append(s ..< e)
                s = e
            } else {
                s += 1
            }
        }
        return plateaus
    }

    /// A plateau's MERGE centre: the MEAN of `x` over it (§1.3 step 4) — a mean
    /// cancels wobble without the whole-bin jumps a median of quantised frames
    /// makes. Used to merge and to place a short link's cut, never emitted.
    static func meanCentre(_ plateau: Range<Int>, _ x: [Double]) -> Double {
        x[plateau].reduce(0, +) / Double(plateau.count)
    }

    /// §1.3 step 4: merge the FIRST neighbouring pair (left to right, with the
    /// frames between them) whose merge centres differ by less than `τ_long`
    /// when both are at least `longLength` (= `P`) frames, else `τ_short`; then
    /// start again, until no pair merges. (S1 found no run of the take whose
    /// result depends on the merge order, §11.6.)
    static func merge(_ raw: [Range<Int>], x: [Double], longLength: Int, rule: Rule) -> [Range<Int>] {
        var plateaus = raw
        var merged = true
        while merged {
            merged = false
            for i in plateaus.indices.dropLast() {
                let a = plateaus[i], b = plateaus[i + 1]
                let tau = a.count >= longLength && b.count >= longLength
                    ? rule.mergeLongCents : rule.mergeShortCents
                if abs(meanCentre(a, x) - meanCentre(b, x)) < tau {
                    plateaus[i] = a.lowerBound ..< b.upperBound
                    plateaus.remove(at: i + 1)
                    merged = true
                    break
                }
            }
        }
        return plateaus
    }

    /// §1.3 step 5 and §1.5: where a SHORT link (≤ `S` frames) between two
    /// plateaus is cut — the index of the first frame of the right-hand part,
    /// in `link.lowerBound … link.upperBound`.
    ///
    /// f0 decides: the first link frame whose `x` crosses the mid of the two
    /// merge centres, in the direction of the step; no crossing → the link's
    /// end. An onset may then MOVE it (never create it): an onset inside the
    /// link or within one frame of either end puts the cut on the frame start
    /// nearest that onset, kept inside the link's own cut range; of several,
    /// the one nearest the f0 cut wins (ties: the earlier).
    static func linkCut(_ link: Range<Int>, x: [Double], left: Double, right: Double,
                        frames: [ClipPitchFrame], onsets: [Double], period: Double) -> Int {
        let mid = (left + right) / 2
        var f0Cut = link.upperBound
        for k in link where (right > left && x[k] >= mid) || (right < left && x[k] <= mid) {
            f0Cut = k
            break
        }
        guard !onsets.isEmpty, !link.isEmpty else { return f0Cut }
        // The cut positions a link allows, and the time each one sits at: the
        // START of frame k (`link.upperBound` is the right plateau's first frame).
        let candidates = link.lowerBound ... link.upperBound
        let from = frames[link.lowerBound].timeSeconds - period
        let to = frames[link.upperBound].timeSeconds + period
        var best: Int?
        for onset in onsets where onset >= from {
            if onset > to { break }
            var nearest = candidates.lowerBound
            for k in candidates where abs(frames[k].timeSeconds - onset) < abs(frames[nearest].timeSeconds - onset) {
                nearest = k
            }
            if let current = best {
                let d = abs(nearest - f0Cut), dc = abs(current - f0Cut)
                if d < dc || (d == dc && nearest < current) { best = nearest }
            } else {
                best = nearest
            }
        }
        return best ?? f0Cut
    }
}
