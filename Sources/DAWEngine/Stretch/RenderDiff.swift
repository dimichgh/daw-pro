import DAWCore
import Foundation

/// p2-ren Stage B (design `docs/design/2026-09-25-incremental-note-render.md`
/// §1 R4, §6 step 2, §11 step 9): **WHERE TWO RENDERS OF ONE SOURCE, ONE TIME
/// BASE, DIFFER**, computed from what the render EVALUATES, never from the
/// edit set's fields (failure mode 5: a field compare misses whatever a future
/// field changes).
///
/// The whole-file render reads exactly three things that an edit can change:
///  1. **the transpose**, handed to the stretcher once per chunk of its curve
///     loop, as a `Float`, from the plan at `OfflineStretcher.curveLookupFrame`
///     (`OfflineStretcher.curveLoop`), and, for a set that
///     `engagesFormantCurve` (natural tuning §1(d)), the formant shift and
///     base handed over beside it at the same lookup frame;
///  2. **the consonant mix's weight** (natural tuning §2, X6), which blends
///     each delivered frame between a note's edges with the source
///     (`StretchCurvePlan.applyConsonantMix`); and
///  3. **the level mask**, applied to each delivered frame afterwards
///     (`StretchCurvePlan.applyLevelMask`).
/// So two renders whose stretchers receive equal transposes up to chunk `k`
/// produce BIT-IDENTICAL output up to frame `k × interval` (same input, same
/// parameters, same state: the stretcher is deterministic), and differ
/// afterwards only where a transpose differs or, then on, by the phase wake
/// the first difference leaves (`StretchWindow.swift`'s banner, MEASURED:
/// +5.7 dB of waveform residual 5 s after one +200 c note, same pitch and
/// level). The mask is exact frame by frame.
///
/// **EVERY BRANCH IS READ AS THE CURVE LOOP AT ITS EFFECTIVE TRANSPOSE.**
///  * the curve path: its plan's value at each chunk's lookup frame;
///  * the constant path: `params.semitones` at every chunk. The constant loop
///    and the curve loop with a constant curve are BIT-identical
///    (`OfflineStretcherCurveTests` (d): at ratio 1, 0 and +2 st, pinned; at
///    ratio 1.5, measured 0 differing samples of 216 000);
///  * the level-only path and a clip that plays its source: 0 at every chunk.
///    The stretcher does NOT run there, so this equivalence is APPROXIMATE:
///    MEASURED 2026-09-25 on the user's take (`ProvisionalRenderTests.
///    firstEditColouringProbe`), the curve render at ratio 1 and 0 st matches
///    the source at −127 to −130 dB after the file's first 0.2 s (−76 to −84 dB
///    over whole prefixes, worst |Δ| 0.0005 at 3 ms: the stretcher's start).
///    `Extent.prefixExact` says which kind of prefix a result has.
///
/// Pure and deterministic. Evaluates two curves at every chunk of the file
/// (cheap arithmetic, but it grows with the take; MEASURED in §12's G1), and
/// the masks only inside level-edited notes. Call it off the main actor.
enum RenderDiff {

    /// One side of the comparison: what a render of `params` evaluates.
    struct Side: Sendable {
        /// The render's parameters. Identity params stand for a clip that plays
        /// its source file.
        let params: StretchRenderCache.Params
        /// The detected contour this render SHAPES against, exactly as
        /// `StretchRenderCache.resolveRenderContour` handed it to the render
        /// (`nil` for a set that needs none and for a fallback render).
        let curveContour: PitchRenderContour?
    }

    /// Which loop produces a render's samples.
    enum Loop: Equatable, Sendable {
        /// The stretcher runs (the curve or the constant path).
        case stretcher
        /// It does not: the level-only path, or the source file itself.
        case sourceTimesMask
    }

    /// Where the two renders differ, in the WHOLE-FILE render's output frames.
    struct Extent: Equatable, Sendable {
        /// The curve loop's chunk (the stretcher's own hop), frames.
        let interval: Int
        /// Both renders' length: `round(sourceFrames × ratio)`.
        let outputFrames: Int
        /// The chunks of the curve loop's chunked middle (1 when it has none:
        /// the pre-roll's value then drives the flush).
        let chunks: Int
        /// Frames whose STRETCHER-SIDE render differs: runs of chunks whose
        /// transposes (and, when both sides are engaged, formant shift or
        /// base) differ, as output frames `[k0 × interval, (k1 + 1) ×
        /// interval)` (the last run of the file reaches `outputFrames`: the
        /// flush drains the last transpose), UNIONED with `consonantRanges`
        /// (natural tuning §2, X6). Every frame BEFORE the first run is
        /// identical in the two renders (exact or approximate, `prefixExact`).
        /// Ascending, disjoint.
        ///
        /// ⚠️ The consonant frames go HERE, never into `maskRanges`: a mask
        /// range is a frame the provisional may RESCALE from the base
        /// (`ProvisionalRender.rescalePatches`, new mask / old mask), and a
        /// consonant weight is a blend with the source, not a gain. In
        /// `maskRanges` a consonant-only edit (a toggle) would rescale by
        /// equal masks and serve the base unchanged; here it takes the splice,
        /// whose span render runs the mix.
        let pitchRanges: [Range<Int>]
        /// Frames whose level masks differ, exactly. Ascending, disjoint.
        let maskRanges: [Range<Int>]
        /// True when both renders run the SAME loop (so every frame before the
        /// first difference is bit-identical); false when one runs the
        /// stretcher and the other does not (identical to the stretcher's
        /// ratio-1, 0-st colouring, measured above).
        let prefixExact: Bool
        /// The two sides' loops.
        let oldLoop: Loop
        let newLoop: Loop
        /// Natural tuning §2 (NT-E2, X6): frames whose CONSONANT-MIX weight
        /// differs, exactly (already unioned into `pitchRanges`; kept apart
        /// for the gates and the report). Ascending, disjoint.
        var consonantRanges: [Range<Int>] = []

        /// No frame differs: the new render IS the old one (a timing-only
        /// edit while the render ignores W, an edit the render never reads).
        var isEmpty: Bool { pitchRanges.isEmpty && maskRanges.isEmpty }

        /// The first frame that can differ, or nil when none does.
        var firstDifferingFrame: Int? {
            [pitchRanges.first?.lowerBound, maskRanges.first?.lowerBound].compactMap { $0 }.min()
        }
    }

    /// Why no extent could be computed: the difference is not local, or the
    /// two renders are not comparable frame for frame.
    enum Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        case timeBase
        case formantFlag
        case formantAcrossLoops
        /// Natural tuning §1(d) item 2: one side renders the per-hop formant
        /// curve and the other does not. Their transposes can be identical
        /// chunk for chunk (a legacy set given an amount), yet every hop that
        /// moves pitch now runs the formant stage, so no local extent exists.
        case formantCurveEngagement
        case badShape
        var description: String {
            switch self {
            case .timeBase: return "the stretch ratio differs (a different time base)"
            case .formantFlag: return "the formant setting differs, which changes every frame"
            case .formantAcrossLoops:
                return "one render runs the stretcher with formant preservation and the other does not run it"
            case .formantCurveEngagement:
                return "one render shapes the voice note by note and the other does not"
            case .badShape: return "the source's shape is unusable"
            }
        }
    }

    /// The loop a render of `params` runs, by `StretchRenderCache.renderAudio`'s
    /// own three-way branch (and the identity bypass before it).
    static func loop(of params: StretchRenderCache.Params, plan: StretchCurvePlan?) -> Loop {
        if params.isIdentity { return .sourceTimesMask }
        if plan != nil { return .stretcher }
        if params.pitchEdits?.hasLevelEdits == true,
           OfflineStretcher.isIdentity(ratio: params.ratio, semitones: params.semitones) {
            return .sourceTimesMask
        }
        return .stretcher
    }

    /// The transpose a render of `side` hands the stretcher for `chunk`, as
    /// the `Float` it receives: its plan's value at the chunk's compensated
    /// lookup frame (`OfflineStretcher.curveLoop`); the clip's constant shift
    /// on the constant path; 0 where the stretcher does not run.
    static func transpose(_ side: Side, plan: StretchCurvePlan?, loop: Loop, chunk: Int,
                          interval: Int,
                          compensation: OfflineStretcher.CurveLatencyCompensation) -> Float {
        if let plan {
            let lookup = OfflineStretcher.curveLookupFrame(
                outputFrame: chunk * interval, compensation: compensation,
                intervalSamples: interval)
            return Float(plan.semitones(atOutputFrame: lookup))
        }
        return loop == .stretcher ? Float(side.params.semitones) : 0
    }

    /// Natural tuning §1(d) item 3: the formant shift and base an ENGAGED
    /// render hands the stretcher for `chunk`, as the two `Float`s the shim
    /// receives (`OfflineStretcher.applyFormant`), at the chunk's compensated
    /// lookup frame, the transpose's own. Compared with `==`, like the
    /// transpose: ±0 st is one formant multiplier.
    static func formant(_ curve: OfflineStretcher.FormantCurve, chunk: Int, interval: Int,
                        compensation: OfflineStretcher.CurveLatencyCompensation)
        -> FormantValues {
        let lookup = OfflineStretcher.curveLookupFrame(
            outputFrame: chunk * interval, compensation: compensation,
            intervalSamples: interval)
        return FormantValues(semitones: Float(curve.semitonesAtOutputFrame(lookup)),
                             baseHz: Float(curve.baseHzAtOutputFrame(lookup)))
    }

    /// One chunk's formant values, as the shim receives them.
    struct FormantValues: Equatable, Sendable {
        let semitones: Float
        let baseHz: Float
    }

    /// Natural tuning §1(d) item 1: the per-hop formant curve a render of
    /// `side` hands the stretcher beside the transpose, built as the render
    /// builds it (`StretchRenderCache.renderAudio`: the plan, the clip's
    /// flag), or nil when the side is not engaged. The ONE home for the
    /// extent's two sides and `ProvisionalRender`'s patch-memo key (NT-PK).
    static func formantCurve(_ side: Side, plan: StretchCurvePlan?) -> OfflineStretcher.FormantCurve? {
        plan?.formantCurve(formantPreserve: side.params.formantPreserve)
    }

    /// The plan `renderAudio` builds for a side, built the same way
    /// (`StretchCurvePlan.make`, R7: with the contour the render uses).
    static func plan(for side: Side, sampleRate: Double) -> StretchCurvePlan? {
        guard !side.params.isIdentity else { return nil }
        return StretchCurvePlan.make(editSet: side.params.pitchEdits,
                                     clipPitchShiftSemitones: side.params.semitones,
                                     sampleRate: sampleRate, ratio: side.params.ratio,
                                     contour: side.curveContour)
    }

    /// Where `new` differs from `old`, or why that cannot be said.
    ///
    /// The transpose is compared as the `Float` the stretcher receives, with
    /// `==` (so ±0, which the stretcher maps to the same multiplier, are one
    /// value). `isCancelled` is polled every 1024 chunks and per level note.
    static func extent(old: Side, new: Side, sourceFrames: Int, channels: Int,
                       sampleRate: Double,
                       isCancelled: () -> Bool = { false }) throws -> Result<Extent, Refusal> {
        guard sourceFrames >= 1, channels >= 1, sampleRate.isFinite, sampleRate > 0 else {
            return .failure(.badShape)
        }
        let oldRatio = old.params.isIdentity ? 1.0 : old.params.ratio
        let newRatio = new.params.isIdentity ? 1.0 : new.params.ratio
        guard oldRatio.bitPattern == newRatio.bitPattern else { return .failure(.timeBase) }
        let oldPlan = plan(for: old, sampleRate: sampleRate)
        let newPlan = plan(for: new, sampleRate: sampleRate)
        let oldLoop = loop(of: old.params, plan: oldPlan)
        let newLoop = loop(of: new.params, plan: newPlan)
        if oldLoop == .stretcher, newLoop == .stretcher,
           old.params.formantPreserve != new.params.formantPreserve {
            return .failure(.formantFlag)
        }
        // Natural tuning §1(d) item 1: the per-hop formant curve each side's
        // render hands the stretcher, built exactly as the render builds it
        // (the plan, the clip's flag). nil = not engaged, and then that side
        // renders, and is compared, exactly as before §1.
        let oldFormant = formantCurve(old, plan: oldPlan)
        let newFormant = formantCurve(new, plan: newPlan)
        // The ratio-1, 0-st equivalence was measured WITHOUT formant
        // preservation; with it the stretcher takes another branch
        // (`signalsmith-stretch.h` `processFormants`), unmeasured here.
        // §1(d) item 4: an ENGAGED stretcher side runs that branch too.
        // (A side that does not run the stretcher has no plan, so it is never
        // engaged: this is the only refusal an engaged side vs the source
        // file can meet, which is why it is checked before item 2.)
        if oldLoop != newLoop {
            let stretcherSide = oldLoop == .stretcher ? old : new
            let stretcherFormant = oldLoop == .stretcher ? oldFormant : newFormant
            if stretcherSide.params.formantPreserve || stretcherFormant != nil {
                return .failure(.formantAcrossLoops)
            }
        }
        // §1(d) item 2: both run the stretcher and exactly one is engaged.
        if (oldFormant != nil) != (newFormant != nil) {
            return .failure(.formantCurveEngagement)
        }
        // X6, §2 (NT-E2): the consonant mix is NOT refused, even when one
        // side runs it and the other does not (a toggle): its frames are
        // compared in step 3 below, like the level mask, and unioned into the
        // extent. A toggle dirties every gap, so it usually meets the
        // provisional's cap and the bridge plays until the final: correct,
        // just not incremental.
        let schedule = try OfflineStretcher.curveSchedule(
            sourceFrames: sourceFrames, channels: channels, sampleRate: sampleRate,
            ratio: newRatio)
        let interval = schedule.blockFrames
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)

        func transpose(_ side: Side, _ plan: StretchCurvePlan?, _ loop: Loop, chunk: Int) -> Float {
            RenderDiff.transpose(side, plan: plan, loop: loop, chunk: chunk, interval: interval,
                                 compensation: compensation)
        }

        // 1. The transpose, chunk by chunk, over the whole chunked middle.
        //    §1(d) item 3: when BOTH sides are engaged, the chunk's formant
        //    shift and base as well, the tuple `(T, F, base)` the loop hands
        //    the stretcher, into the same ranges. A side pair with neither
        //    engaged compares the transpose alone, as before §1.
        let chunks = schedule.processOut > 0 ? (schedule.processOut + interval - 1) / interval : 1
        var chunkRanges: [Range<Int>] = []
        var runStart: Int?
        for chunk in 0..<chunks {
            if chunk & 1023 == 0, isCancelled() { throw OfflineStretcherError.cancelled }
            var differs = transpose(old, oldPlan, oldLoop, chunk: chunk)
                != transpose(new, newPlan, newLoop, chunk: chunk)
            if !differs, let oldFormant, let newFormant {
                differs = formant(oldFormant, chunk: chunk, interval: interval,
                                  compensation: compensation)
                    != formant(newFormant, chunk: chunk, interval: interval,
                               compensation: compensation)
            }
            if differs, runStart == nil { runStart = chunk }
            if !differs, let start = runStart {
                chunkRanges.append((start * interval)..<min(schedule.outputFrames, chunk * interval))
                runStart = nil
            }
        }
        if let start = runStart {
            // The last chunk's transpose also drives the flush: to the end.
            chunkRanges.append((start * interval)..<schedule.outputFrames)
        }

        // 2. The level masks, frame by frame, only where either can be ≠ 1.
        let maskRanges = try differingMaskFrames(old: old.params.pitchEdits,
                                                 new: new.params.pitchEdits,
                                                 outputFrames: schedule.outputFrames,
                                                 sampleRate: sampleRate, ratio: newRatio,
                                                 isCancelled: isCancelled)

        // 3. X6, natural tuning §2 (NT-E2): the consonant-mix weights, frame
        //    by frame, only inside either side's regions (outside them both
        //    weights are the literal 1). Unioned into `pitchRanges`, never
        //    `maskRanges` (see `Extent.pitchRanges`).
        //
        //    ⭐ THE HISTORY CAVEAT, DECIDED "BOUNDED", NOT WIDENED. R1's ρ is
        //    measured on the wet audio, and the wet audio after a changed chunk
        //    carries the phase wake (above), which never decays in a take with
        //    no digital silence (M-1: 14 gaps over 11 s after one moved note).
        //    So a fade downstream of a changed chunk can have other gains in
        //    the new render with equal weights. Widening the extent over every
        //    such fade would reach the end of the file and put every edit over
        //    the provisional's cap. It is not needed: outside `pitchRanges`
        //    the provisional already plays the base's wake, and a base's fade
        //    is a power-matched blend of that same wake with the source, so it
        //    keeps the sides' level by construction. It differs from the
        //    final's fade only by the wet side's partial phases, the class of
        //    difference every downstream NOTE frame already has, and a gap's
        //    interior (w 0) is the source in both, exactly.
        //    `NaturalTuningRenderDiffTests` measures the fades against the
        //    notes on a provisional.
        //
        //    ⭐ COMPARED ONLY WHEN BOTH SIDES RUN THE STRETCHER. A side that
        //    does not (the level-only path, or a clip playing its source)
        //    plays the SOURCE, which is the mix's dry signal at every frame.
        //    Against it, a mixed render's region interior is the same bytes,
        //    and its fades blend the source with a wet side this function
        //    already equates with the source outside `pitchRanges` (the loop
        //    stance above: the ratio-1, 0-st stretcher ≈ the source). Reading
        //    that side as "weight 1" instead would mark every gap of the file
        //    on the FIRST edit of every new vocal (flag on, base = the source)
        //    and push it over the provisional's cap (measured in
        //    `NaturalTuningRenderDiffTests`).
        var consonantRanges: [Range<Int>] = []
        if oldLoop == .stretcher, newLoop == .stretcher {
            consonantRanges = try differingConsonantFrames(
                old: old, oldPlan: oldPlan, new: new, newPlan: newPlan,
                outputFrames: schedule.outputFrames, sampleRate: sampleRate, ratio: newRatio,
                isCancelled: isCancelled)
        }
        return .success(Extent(interval: interval, outputFrames: schedule.outputFrames,
                               chunks: chunks,
                               pitchRanges: merged(chunkRanges + consonantRanges),
                               maskRanges: maskRanges,
                               prefixExact: oldLoop == newLoop,
                               oldLoop: oldLoop, newLoop: newLoop,
                               consonantRanges: consonantRanges))
    }

    /// Natural tuning §2 (NT-E2, X6): the frames where the two renders'
    /// consonant-mix weights differ. A side's weight is the mix's own `w`
    /// where its render RUNS the mix (a plan, and
    /// `StretchCurvePlan.consonantMixActive`, the render's gate) and 1
    /// elsewhere, so a toggle, a trim that moves a note's edge beside a
    /// region, or a sound dragged into or out of the curve (R21) each mark the
    /// frames they move. A split marks none: its halves abut bit for bit
    /// (`ProjectStore.splitClipNoteSegment`), a soft join, so no region moves.
    ///
    /// ⭐ **THE SHORT-CIRCUIT, EXACT (W7-NTE2, 2026-09-27).** The comparison
    /// computes `consonantWeights(oldRegions, …)` and
    /// `consonantWeights(newRegions, …)` over the SAME ranges at the SAME
    /// rate and ratio: this function receives ONE `sampleRate`, ONE `ratio`
    /// and ONE `outputFrames` for both sides (`extent` passes them only after
    /// refusing unequal ratios, `.timeBase`), and the ranges come from both
    /// lists together. The weights read nothing else: the mix pass on a
    /// buffer of ones reads the regions' four stored fields, DAWCore's
    /// constant `consonantFadeSeconds` and the frame mapping. So the region
    /// lists are the ONLY per-side input, and when they are the same BIT FOR
    /// BIT (`sameRegionBits`) every weight pair is too and no frame can
    /// differ: `[]`, without computing a weight. A pitch-only edit (the
    /// common case: a region is note TIMES, the flag and the mix gate) takes
    /// it, and so does a split. MEASURED 2026-09-27 on the user's 33 s take
    /// (debug build, `consonantWeightsCostPerEdit`): the union went from 119
    /// to 0.07 ms per pitch-only edit, and that edit's whole provisional build
    /// from 232 to 113 ms.
    /// `NaturalTuningConsonantRenderDiffTests.shortCircuitIsExact` checks each
    /// kind of edit against the full comparison.
    static func differingConsonantFrames(old: Side, oldPlan: StretchCurvePlan?, new: Side,
                                         newPlan: StretchCurvePlan?, outputFrames: Int,
                                         sampleRate: Double, ratio: Double,
                                         isCancelled: () -> Bool) throws -> [Range<Int>] {
        let oldRegions = consonantRegions(old, plan: oldPlan)
        let newRegions = consonantRegions(new, plan: newPlan)
        if sameRegionBits(oldRegions, newRegions) { return [] }
        return try differingConsonantFrames(oldRegions: oldRegions, newRegions: newRegions,
                                            outputFrames: outputFrames, sampleRate: sampleRate,
                                            ratio: ratio, isCancelled: isCancelled)
    }

    /// True when two region lists hold the same values BIT FOR BIT: the same
    /// count and, region by region, the same `startSeconds` and `endSeconds`
    /// bit patterns and the same two flags. Stricter than `==`, which calls
    /// +0 and −0 equal. These four ARE `PitchConsonantRegion`'s stored
    /// fields (`shortCircuitIsExact` pins them by reflection, so a fifth
    /// cannot slip past this check).
    static func sameRegionBits(_ a: [PitchConsonantRegion], _ b: [PitchConsonantRegion]) -> Bool {
        guard a.count == b.count else { return false }
        for (x, y) in zip(a, b) {
            guard x.startSeconds.bitPattern == y.startSeconds.bitPattern,
                  x.endSeconds.bitPattern == y.endSeconds.bitPattern,
                  x.followsNote == y.followsNote, x.precedesNote == y.precedesNote else {
                return false
            }
        }
        return true
    }

    /// The comparison itself, with no short-circuit: both lists' weights over
    /// every frame either list covers, and the runs where their bit patterns
    /// differ.
    static func differingConsonantFrames(oldRegions: [PitchConsonantRegion],
                                         newRegions: [PitchConsonantRegion], outputFrames: Int,
                                         sampleRate: Double, ratio: Double,
                                         isCancelled: () -> Bool) throws -> [Range<Int>] {
        var candidates: [Range<Int>] = []
        for region in oldRegions + newRegions {
            let lo = StretchCurvePlan.firstOutputFrame(
                atOrAfterSourceSecond: region.startSeconds, frames: outputFrames,
                ratio: ratio, sampleRate: sampleRate)
            let hi = region.endSeconds.isFinite
                ? StretchCurvePlan.firstOutputFrame(atOrAfterSourceSecond: region.endSeconds,
                                                    frames: outputFrames, ratio: ratio,
                                                    sampleRate: sampleRate)
                : outputFrames
            if hi > lo { candidates.append(lo..<hi) }
        }
        var differing: [Range<Int>] = []
        for range in merged(candidates) {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let oldWeights = try consonantWeights(oldRegions, range: range, sampleRate: sampleRate,
                                                  ratio: ratio)
            let newWeights = try consonantWeights(newRegions, range: range, sampleRate: sampleRate,
                                                  ratio: ratio)
            var runStart: Int?
            for i in 0..<range.count {
                let differs = oldWeights[i].bitPattern != newWeights[i].bitPattern
                if differs, runStart == nil { runStart = i }
                if !differs, let start = runStart {
                    differing.append((range.lowerBound + start)..<(range.lowerBound + i))
                    runStart = nil
                }
            }
            if let start = runStart { differing.append((range.lowerBound + start)..<range.upperBound) }
        }
        return differing
    }

    /// The regions a render of `side` mixes dry, or `[]` when it runs no mix:
    /// `StretchRenderCache.renderAudio`'s own gate (a plan, and
    /// `consonantMixActive`), asked the same way.
    static func consonantRegions(_ side: Side, plan: StretchCurvePlan?) -> [PitchConsonantRegion] {
        guard plan != nil, StretchCurvePlan.consonantMixActive(side.params),
              let set = side.params.pitchEdits else { return [] }
        return set.consonantRegions()
    }

    /// THE MIX'S weight at whole-file output frames `range`: 1 where it does
    /// not write. Exactly the `w` the render blends with: the one pass
    /// (`StretchCurvePlan.applyConsonantMix`) run on a buffer of ones with a
    /// silent source, where the law's ρ reads 1 (`n` = 1) and the output IS
    /// `w`. The level mask's `maskValues` idiom.
    static func consonantWeights(_ regions: [PitchConsonantRegion], range: Range<Int>,
                                 sampleRate: Double, ratio: Double) throws -> [Float] {
        var ones = [[Float](repeating: 1, count: range.count)]
        guard !regions.isEmpty, !range.isEmpty else { return ones[0] }
        try StretchCurvePlan.applyConsonantMix(
            regions, wet: &ones, dry: [[Float](repeating: 0, count: range.count)],
            sampleRate: sampleRate, ratio: ratio, outputFrameOffset: range.lowerBound)
        return ones[0]
    }

    /// The frames where the two sets' level masks differ, computed by THE mask
    /// pass itself (`StretchCurvePlan.applyLevelMask` on a buffer of ones, at
    /// GLOBAL frames), over every level-edited note of either set: a note's
    /// mask depends on its NEIGHBOURS' edges (`PitchNoteLevel.swift`'s
    /// abutting rule), so a per-note field compare would be wrong. Outside
    /// those notes both masks are the literal 1.
    static func differingMaskFrames(old: PitchEditSet?, new: PitchEditSet?, outputFrames: Int,
                                    sampleRate: Double, ratio: Double,
                                    isCancelled: () -> Bool) throws -> [Range<Int>] {
        var candidates: [Range<Int>] = []
        for set in [old, new] {
            guard let set, set.hasLevelEdits else { continue }
            for note in set.segments where note.hasLevelEdits {
                let lo = StretchCurvePlan.firstOutputFrame(
                    atOrAfterSourceSecond: note.startSeconds, frames: outputFrames,
                    ratio: ratio, sampleRate: sampleRate)
                let hi = StretchCurvePlan.firstOutputFrame(
                    atOrAfterSourceSecond: note.endSeconds, frames: outputFrames,
                    ratio: ratio, sampleRate: sampleRate)
                if hi > lo { candidates.append(lo..<hi) }
            }
        }
        var differing: [Range<Int>] = []
        for range in merged(candidates) {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let oldMask = try maskValues(old, range: range, sampleRate: sampleRate, ratio: ratio)
            let newMask = try maskValues(new, range: range, sampleRate: sampleRate, ratio: ratio)
            var runStart: Int?
            for i in 0..<range.count {
                let differs = oldMask[i].bitPattern != newMask[i].bitPattern
                if differs, runStart == nil { runStart = i }
                if !differs, let start = runStart {
                    differing.append((range.lowerBound + start)..<(range.lowerBound + i))
                    runStart = nil
                }
            }
            if let start = runStart { differing.append((range.lowerBound + start)..<range.upperBound) }
        }
        return differing
    }

    /// THE mask's factor at whole-file output frames `range`: 1 where the set
    /// applies no mask. Exactly what `applyLevelMask` multiplies a frame by
    /// (a ones buffer through the one pass).
    static func maskValues(_ set: PitchEditSet?, range: Range<Int>, sampleRate: Double,
                           ratio: Double) throws -> [Float] {
        var ones = [[Float](repeating: 1, count: range.count)]
        if let set {
            try StretchCurvePlan.applyLevelMask(set, to: &ones, sampleRate: sampleRate, ratio: ratio,
                                                outputFrameOffset: range.lowerBound)
        }
        return ones[0]
    }

    /// `ranges` sorted, with overlapping or touching ranges joined.
    static func merged(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) where !range.isEmpty {
            if let last = out.last, range.lowerBound <= last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
