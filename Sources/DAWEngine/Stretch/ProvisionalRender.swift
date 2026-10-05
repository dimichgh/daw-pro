import AVFAudio
import CryptoKit
import DAWCore
import Darwin
import Foundation
import os

/// p2-ren Stage B (design `docs/design/2026-09-25-incremental-note-render.md`
/// §6, §11 step 10): **THE PROVISIONAL RENDER.** A quick stand-in for the
/// render an edit asks for, played until that exact whole-file render commits:
/// the clip's last COMMITTED render (or its source), with the frames the edit
/// changes replaced by a span render (I1-F1's `renderOutputFrames`), joined at
/// two crossfaded seams placed at quiet points.
///
/// Pure but for file I/O, blocking, allocating: call it off the main actor,
/// never on the render thread (`ProvisionalRenderStore` runs it on its own
/// serial queue). Nothing here commits under a render key: the file it writes
/// lives only at `ProvisionalRenderStore`'s `<newKey>~<baseName>.caf`, so the
/// cache's lost-rename rule can never make it a key's permanent render
/// (design §10 failure mode 2).
///
/// What it builds, by what `RenderDiff.extent` finds:
///  * **nothing differs** → the base itself (`Kind.baseAsIs`): exact;
///  * **only levels differ and neither render runs the stretcher** (the
///    level-only path, or a source): the changed frames are source × the new
///    mask, rendered through the one loop's window (bit-exact, R6), with no
///    crossfade: the result is BYTE-identical to the final (`levelOnlyExact`);
///  * **only levels differ and both run the stretcher with equal transposes**:
///    the stretcher's output is the same, so the base is rescaled by
///    new mask / old mask where the old mask is ≥ 1e-3 (`rescale`): exact to
///    float rounding;
///  * **otherwise** (`spliced`): a span render over the extent, crossfaded
///    into the base at a quiet seam on each side. Approximate, by design: the
///    phase wake (`StretchWindow.swift`'s banner; R5) means the base after
///    the right seam has the final's pitch and level with other partial
///    phases.
enum ProvisionalRender {

    // MARK: - The delegated defaults (design §14), each set by measurement

    struct Tuning: Equatable, Sendable {
        /// How far from the extent each seam is searched for. MEASURED
        /// 2026-09-25 on the user's take (`ProvisionalRenderTests.
        /// provisionalVersusFinalOnTheUsersTake`, 7 notes × {source, render}
        /// base, 28 seams each way): 0.5 s gave patches of 1.08 s mean (1.31 s
        /// max) built in 96 ms mean; 1.0 s gave 1.61 s (2.44 s) in 149 ms, for
        /// seams only 1.7 dB quieter (median 20.8 vs 22.5 dB under the active
        /// level). Both passed every G2/G3 gate. The shorter window wins.
        var seamSearchSeconds: Double = 0.5
        /// The right seam's search starts this far past the last differing
        /// frame: the stretcher's block (its windows are 120 ms at every rate,
        /// `OfflineStretcher.curveLatencyCompensation`'s structural argument),
        /// inside which the last changed transpose still shapes the output.
        var smearSeconds: Double = 0.12
        /// The RMS window a seam's quietness is measured over.
        var rmsWindowSeconds: Double = 0.010
        /// A seam at or below this many dB under the clip's active level is
        /// QUIET and gets the short crossfade. The design's default, KEPT and
        /// INERT on the user's take: no seam of 56 (both windows above) came
        /// within 28 dB of it, so every crossfade there was the voiced 30 ms,
        /// and all 56 passed G3. Nothing measured argues for moving it.
        var quietBelowActiveDb: Double = 40
        var quietCrossfadeSeconds: Double = 0.010
        var voicedCrossfadeSeconds: Double = 0.030
        /// At or above this normalised correlation of the two sides over the
        /// crossfade, the equal-GAIN law (the sides are one signal and
        /// equal-power would bump +3 dB); below it, equal-POWER.
        var equalGainCorrelation: Double = 0.9
        /// What a seam whose correlation is BELOW that threshold gets.
        /// MEASURED 2026-09-25 (`ProvisionalRenderTests.seamLawMeasurement`,
        /// 8 single-note edits on a synthetic voice, 16 seams, ρ −0.25…0.77):
        /// the design's equal-POWER failed G3's envelope bound on 8 of 16 (the
        /// left seams, ρ ≈ 0.5: +1.6 to +2.2 dB of bump, the partly-correlated
        /// case equal-power over-sums); POWER-MATCHED passed all 16 (envelope
        /// −2.75…+0.92 dB). Equal-gain at ρ ≥ 0.9 is unchanged.
        var partialCorrelationLaw: Law = .powerMatched
        /// The cap (design §6 step 3): a spliced provisional is built only when
        /// its span render plus pre-roll is at most this fraction of the file…
        var capFraction: Double = 0.40
        /// …and at most this many seconds. Otherwise the bridge plays on.
        var capSeconds: Double = 20

        static let product = Tuning()

        /// Every field that shapes a patch's samples (the cap does not), for
        /// `PatchMemo`'s key.
        var fingerprint: String {
            [seamSearchSeconds, smearSeconds, rmsWindowSeconds, quietBelowActiveDb,
             quietCrossfadeSeconds, voicedCrossfadeSeconds, equalGainCorrelation]
                .map { String($0.bitPattern) }.joined(separator: " ") + " " + partialCorrelationLaw.rawValue
        }
    }

    // MARK: - Inputs and outputs

    /// The file a provisional is built from: the clip's last committed render
    /// with the same time base, or its source (an identity clip). Never
    /// another provisional (design §6 step 1: content must not depend on edit
    /// history).
    struct Base: Sendable, Equatable {
        let url: URL
        /// The params that file is the render of (identity for a source).
        let params: StretchRenderCache.Params
        /// The name this base contributes to a provisional's file name: the
        /// committed file's own key, or `src-<source identity digest>`.
        let name: String
        /// The file is the clip's source, not a render.
        let isSource: Bool
        /// The file is its params' constant-offset FALLBACK (committed at the
        /// legacy key when detection was unavailable): it was rendered with
        /// no contour, whatever the contour cache says now.
        let contourFallback: Bool
    }

    struct Job: Sendable {
        let source: URL
        let base: Base
        /// What the edit asks for.
        let params: StretchRenderCache.Params
        let newKey: String
        /// Where the file goes (`ProvisionalRenderStore`): never `<key>.caf`.
        let destination: URL
        let renderCacheDirectory: URL
        let detector: PitchContourCache.Detector
        /// Patches already built for this base, reused where a region's
        /// inputs are unchanged (`PatchMemo`). nil: build everything.
        var memo: PatchMemo? = nil
    }

    enum Kind: String, Sendable, Equatable {
        case baseAsIs = "base-as-is"
        case levelOnlyExact = "level-only-exact"
        case rescale
        case spliced
    }

    enum Assembly: String, Sendable, Equatable {
        /// No file written: the base is served.
        case none
        /// An APFS clone of the base, patched in place (`clonefile` + `pwrite`).
        case clone = "clone-and-patch"
        /// A streaming rewrite with `performRender`'s settings: the reference,
        /// the fallback, and the path for a SOURCE base.
        case rewrite
    }

    enum Law: String, Sendable, Equatable {
        case equalGain = "equal-gain"
        case equalPower = "equal-power"
        /// Linear ramps divided by √(s² + b² + 2ρsb), ρ the sides' measured
        /// correlation clamped to [0, 1]: the mix keeps the sides' power for
        /// any ρ (equal-gain at ρ = 1, equal-power-like at ρ = 0). Equal-power
        /// on PARTLY correlated sides bumps: +1.9 dB at ρ = 0.56.
        case powerMatched = "power-matched"
    }

    /// One seam, as built, for the report and the gates.
    struct Seam: Sendable, Equatable {
        enum Side: String, Sendable { case left, right }
        let side: Side
        /// The crossfade's centre, in whole-file output frames.
        let centreFrame: Int
        let crossfadeFrames: Int
        let law: Law
        /// The base's `rmsWindowSeconds` RMS at the seam, dBFS.
        let seamRmsDb: Double
        /// The clip's active level (the 90th percentile of the 10 ms RMS over
        /// every frame this build read), dBFS.
        let activeRmsDb: Double
        let correlation: Double
        /// At or below `Tuning.quietBelowActiveDb` under the active level.
        let isQuiet: Bool
    }

    struct Built: Sendable {
        /// The file to play: the destination, or the base itself (`baseAsIs`).
        let url: URL
        let kind: Kind
        let extent: RenderDiff.Extent
        /// The frames that differ from the base, when a file was written.
        let patchedFrames: [Range<Int>]
        let seams: [Seam]
        let assembly: Assembly
        /// Frames the span renders cover (0 for the exact kinds), and which
        /// whole-file frames each was (one per changed region).
        let spanFrames: Int
        var spanRanges: [Range<Int>] = []
        /// Of `spanFrames`: rendered by this build, and reused from `PatchMemo`.
        var renderedSpanFrames = 0
        var reusedSpanFrames = 0
        /// Wall time of each step, milliseconds: contour + extent, base reads
        /// and seams, span render, assembly.
        let millis: [String: Double]
    }

    enum Outcome: Sendable {
        case built(Built)
        /// No provisional: the bridge plays on until the final. The reason is
        /// for the report and the tests.
        case declined(String)
    }

    // MARK: - The builder

    static func build(_ job: Job, tuning: Tuning = .product,
                      isCancelled: () -> Bool) throws -> Outcome {
        var millis: [String: Double] = [:]
        var clock = DispatchTime.now().uptimeNanoseconds
        func lap(_ name: String) {
            let now = DispatchTime.now().uptimeNanoseconds
            millis[name] = Double(now - clock) / 1e6
            clock = now
        }
        let source = try StretchRenderCache.SpanSource.open(job.source)
        let sampleRate = source.sampleRate
        let channels = source.channels
        let baseContour: PitchRenderContour? = job.base.contourFallback ? nil
            : try StretchRenderCache.resolveRenderContour(
                params: job.base.params, source: job.source,
                renderCacheDirectory: job.renderCacheDirectory, detector: job.detector,
                isCancelled: isCancelled).curveContour
        let newContour = try StretchRenderCache.resolveRenderContour(
            params: job.params, source: job.source,
            renderCacheDirectory: job.renderCacheDirectory, detector: job.detector,
            isCancelled: isCancelled).curveContour
        let newSide = RenderDiff.Side(params: job.params, curveContour: newContour)
        let diff = try RenderDiff.extent(
            old: RenderDiff.Side(params: job.base.params, curveContour: baseContour),
            new: newSide,
            sourceFrames: source.frames, channels: channels, sampleRate: sampleRate,
            isCancelled: isCancelled)
        lap("extent")
        let extent: RenderDiff.Extent
        switch diff {
        case .failure(let refusal): return .declined(refusal.description)
        case .success(let value): extent = value
        }
        let base = try StretchRenderCache.SpanSource.open(job.base.url)
        guard base.frames == extent.outputFrames, base.channels == channels,
              base.sampleRate == sampleRate else {
            return .declined("the base file (\(base.frames) frames) is not the length "
                             + "the new render will have (\(extent.outputFrames))")
        }
        if extent.isEmpty {
            return .built(Built(url: job.base.url, kind: .baseAsIs, extent: extent,
                                patchedFrames: [], seams: [], assembly: .none, spanFrames: 0,
                                millis: millis))
        }

        var patches: [Patch] = []
        var kind: Kind
        var seams: [Seam] = []
        var spanRanges: [Range<Int>] = []
        var rendered = 0, reused = 0
        if extent.oldLoop == .sourceTimesMask, extent.newLoop == .sourceTimesMask {
            // Both renders are source × mask: the changed frames through the
            // one loop's window are the final's own bytes, and every other
            // frame of the base already is.
            kind = .levelOnlyExact
            for range in extent.maskRanges {
                let span = try StretchRenderCache.renderOutputFrames(
                    range, of: source, params: job.params,
                    renderCacheDirectory: job.renderCacheDirectory, detector: job.detector,
                    isCancelled: isCancelled)
                patches.append(Patch(firstFrame: range.lowerBound, planar: span.planar))
            }
            lap("span")
        } else if extent.oldLoop == .stretcher, extent.newLoop == .stretcher,
                  extent.pitchRanges.isEmpty,
                  let rescaled = try rescalePatches(extent: extent, base: base, old: job.base.params,
                                                    new: job.params, sampleRate: sampleRate,
                                                    isCancelled: isCancelled) {
            kind = .rescale
            patches = rescaled
            lap("rescale")
        } else {
            kind = .spliced
            switch try splice(job: job, newSide: newSide, extent: extent, source: source,
                              base: base, tuning: tuning, isCancelled: isCancelled, lap: lap) {
            case .declined(let reason): return .declined(reason)
            case .patches(let built, let seamList, let ranges, let fresh, let memoised):
                patches = built
                seams = seamList
                spanRanges = ranges
                rendered = fresh
                reused = memoised
            }
        }
        if isCancelled() { throw OfflineStretcherError.cancelled }
        let assembly = try assemble(base: job.base.url, baseIsSource: job.base.isSource,
                                    patches: patches, outputFrames: extent.outputFrames,
                                    channels: channels, sampleRate: sampleRate,
                                    sourceFormat: sourceProcessingFormat(job.source),
                                    to: job.destination, isCancelled: isCancelled)
        lap("assemble")
        return .built(Built(url: job.destination, kind: kind, extent: extent,
                            patchedFrames: patches.map { $0.frames }, seams: seams,
                            assembly: assembly,
                            spanFrames: spanRanges.reduce(0) { $0 + $1.count },
                            spanRanges: spanRanges, renderedSpanFrames: rendered,
                            reusedSpanFrames: reused, millis: millis))
    }

    /// Frames to write over the base: planar Float32 for whole-file output
    /// frames `firstFrame ..< firstFrame + planar[0].count`.
    struct Patch: Sendable {
        let firstFrame: Int
        let planar: [[Float]]
        var frames: Range<Int> { firstFrame..<(firstFrame + (planar.first?.count ?? 0)) }
    }

    /// The level rescale (design §6, "two special cases"): where only the
    /// masks differ and the stretcher output is the same, each changed frame
    /// is base / oldMask × newMask, with the mask pass's own denormal flush.
    /// nil when the old mask is below 1e-3 at a changed frame (un-clearing a
    /// note cannot be recovered from a zeroed base): the splice takes it.
    static func rescalePatches(extent: RenderDiff.Extent, base: StretchRenderCache.SpanSource,
                               old: StretchRenderCache.Params, new: StretchRenderCache.Params,
                               sampleRate: Double,
                               isCancelled: () -> Bool) throws -> [Patch]? {
        var patches: [Patch] = []
        for range in extent.maskRanges {
            let oldMask = try RenderDiff.maskValues(old.pitchEdits, range: range,
                                                    sampleRate: sampleRate, ratio: old.ratio)
            let newMask = try RenderDiff.maskValues(new.pitchEdits, range: range,
                                                    sampleRate: sampleRate, ratio: new.ratio)
            guard !oldMask.contains(where: { $0 < 1e-3 }) else { return nil }
            var planar = try base.read(range, isCancelled)
            for channel in planar.indices {
                for i in 0..<range.count {
                    var sample = oldMask[i] == 1 ? planar[channel][i]
                        : planar[channel][i] / oldMask[i]
                    if newMask[i] != 1 { sample *= newMask[i] }
                    if abs(sample) < Float.leastNormalMagnitude { sample = 0 }
                    planar[channel][i] = sample
                }
            }
            patches.append(Patch(firstFrame: range.lowerBound, planar: planar))
        }
        return patches
    }

    private enum SpliceResult {
        case declined(String)
        case patches([Patch], [Seam], spans: [Range<Int>], rendered: Int, reused: Int)
    }

    /// The general case: the extent's changes grouped into CLUSTERS (changes
    /// closer than two seam windows share one span), and per cluster the
    /// seams, the span render and the crossfades. A cluster per region keeps
    /// the rendered frames to what changed when a set's edits since its base
    /// are far apart (two notes a minute apart are two short spans, not one
    /// long one).
    ///
    /// ⭐ **EACH CLUSTER'S PATCH IS A PURE FUNCTION OF ITS OWN INPUTS**: the
    /// base, the cluster's frames, the tuning, and the new render's transposes,
    /// formant shift and base (an ENGAGED render, natural tuning §1) and mask
    /// over the widest window its seams, span and pre-roll can reach. Its
    /// seams, its crossfade lengths (the active level is the
    /// cluster's own, from the frames it read) and its law depend on nothing
    /// else, so a patch built for an earlier edit whose inputs over that
    /// window are the same is the same patch, and `job.memo` returns it. That
    /// is what keeps a burst of edits between two landed finals from
    /// re-rendering every earlier edit's region (MEASURED before the memo on
    /// the user's take: 82 → 708 ms over 9 edits as the regions accumulated).
    /// The cap applies to the frames this build RENDERS.
    private static func splice(job: Job, newSide: RenderDiff.Side, extent: RenderDiff.Extent,
                               source: StretchRenderCache.SpanSource,
                               base: StretchRenderCache.SpanSource, tuning: Tuning,
                               isCancelled: () -> Bool,
                               lap: (String) -> Void) throws -> SpliceResult {
        let sampleRate = source.sampleRate
        let outputFrames = extent.outputFrames
        func frames(_ seconds: Double) -> Int { max(1, Int((seconds * sampleRate).rounded())) }
        let window = frames(tuning.seamSearchSeconds)
        let smear = frames(tuning.smearSeconds)
        let rms = frames(tuning.rmsWindowSeconds)
        let xfVoiced = frames(tuning.voicedCrossfadeSeconds)
        let xfQuiet = frames(tuning.quietCrossfadeSeconds)
        let half = xfVoiced / 2 + rms / 2 + 1
        let preRoll = StretchRenderCache.minimumPreRollFrames(sampleRate: sampleRate)
        let cap = min(Int(tuning.capFraction * Double(outputFrames)), frames(tuning.capSeconds))
        // Clusters: changed ranges whose gap leaves no room for a right seam
        // window, a smear and a left seam window between them are one.
        var clusters: [Range<Int>] = []
        for range in RenderDiff.merged(extent.pitchRanges + extent.maskRanges) {
            if let last = clusters.last, range.lowerBound - last.upperBound <= 2 * (window + half) + smear {
                clusters[clusters.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                clusters.append(range)
            }
        }
        // Each cluster's memo key: everything its patch reads.
        let newPlan = RenderDiff.plan(for: newSide, sampleRate: sampleRate)
        let newFormant = RenderDiff.formantCurve(newSide, plan: newPlan)
        let compensation = OfflineStretcher.curveLatencyCompensation(sampleRate: sampleRate)
        func memoKey(_ cluster: Range<Int>) throws -> String {
            let lo = max(0, cluster.lowerBound - window - half)
            let hi = min(outputFrames, cluster.upperBound + smear + window + half)
            let firstChunk = max(0, (lo - preRoll) / extent.interval - 1)
            let lastChunk = hi + 2 * extent.interval >= extent.chunks * extent.interval
                ? extent.chunks - 1 : min(extent.chunks - 1, hi / extent.interval + 1)
            var hasher = SHA256()
            func add(_ text: String) {
                hasher.update(data: Data(text.utf8))
                hasher.update(data: Data([0]))
            }
            add(job.base.name)
            add("\(job.params.ratio.bitPattern) \(job.params.semitones.bitPattern) \(job.params.formantPreserve)")
            add(tuning.fingerprint)
            add("\(cluster.lowerBound) \(cluster.upperBound) \(firstChunk) \(max(firstChunk, lastChunk))")
            var bits: [UInt32] = []
            for chunk in firstChunk...max(firstChunk, lastChunk) {
                bits.append(RenderDiff.transpose(newSide, plan: newPlan, loop: extent.newLoop, chunk: chunk,
                                                 interval: extent.interval,
                                                 compensation: compensation).bitPattern)
            }
            bits.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            // Natural tuning §1(d), NT-PK: an ENGAGED render hands the
            // stretcher a formant shift and base beside every transpose, and a
            // Voice edit (a note's offset, the set's amount) changes them with
            // every transpose unchanged. Without them here a Voice re-edit got
            // the previous edit's key and replayed ITS voice until the final.
            // Read through the extent's own function (`RenderDiff.formant`),
            // chunk for chunk. Only when engaged, so a legacy set's key keeps
            // p2-ren's bytes (`NaturalTuningProvisionalMemoTests`' golden).
            if let newFormant {
                var voice: [UInt32] = []
                for chunk in firstChunk...max(firstChunk, lastChunk) {
                    let values = RenderDiff.formant(newFormant, chunk: chunk, interval: extent.interval,
                                                    compensation: compensation)
                    voice.append(values.semitones.bitPattern)
                    voice.append(values.baseHz.bitPattern)
                }
                add("formant")
                voice.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            }
            // Natural tuning §2 (NT-E2), X6: the consonant mix blends each
            // region frame with the source, and a toggle changes those frames
            // with every transpose unchanged. Without the weights here, a toggle
            // whose regions lie inside the moved note's own changed chunks keeps
            // the cluster's bounds, gets the previous edit's key, and replays
            // ITS (unmixed) gaps until the final. Read through the extent's own
            // functions (`RenderDiff.consonantRegions` / `consonantWeights`,
            // which run the mix pass itself). Only when the new render runs the
            // mix, so every other key keeps its bytes.
            let consonantRegions = RenderDiff.consonantRegions(newSide, plan: newPlan)
            if !consonantRegions.isEmpty {
                let weights = try RenderDiff.consonantWeights(consonantRegions, range: lo..<hi,
                                                              sampleRate: sampleRate,
                                                              ratio: job.params.ratio)
                add("consonant")
                weights.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            }
            // A mask of literal ones IS no mask (the pass writes only gain ≠ 1),
            // so both hash alike: a level edit elsewhere keeps this key.
            var mask: [Float] = []
            if let set = job.params.pitchEdits, set.hasLevelEdits {
                mask = try RenderDiff.maskValues(set, range: lo..<hi, sampleRate: sampleRate,
                                                 ratio: job.params.ratio)
            }
            if mask.allSatisfy({ $0 == 1 }) {
                add("no mask")
            } else {
                mask.withUnsafeBytes { hasher.update(bufferPointer: $0) }
            }
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
        var results = [PatchMemo.Entry?](repeating: nil, count: clusters.count)
        var keys: [String] = []
        var reused = 0
        for (index, cluster) in clusters.enumerated() {
            let key = try memoKey(cluster)
            keys.append(key)
            if let hit = job.memo?.entry(key) {
                results[index] = hit
                reused += hit.span.count
            }
        }
        // Seams for the clusters to render, from the base.
        struct Plan {
            let index: Int
            let left: SeamCandidate?
            let right: SeamCandidate?
            var levels: [Float]
            let span: Range<Int>
        }
        var plans: [Plan] = []
        for (index, cluster) in clusters.enumerated() where results[index] == nil {
            let first = cluster.lowerBound
            let rightStart = min(outputFrames, cluster.upperBound + smear)
            let leftLo = max(half, first - window)
            let leftHi = first - half
            let rightLo = rightStart + half
            let rightHi = min(outputFrames - half, rightStart + window)
            var levels: [Float] = []
            var left: SeamCandidate?
            if leftHi >= leftLo {
                let read = (leftLo - half)..<first
                let audio = try base.read(read, isCancelled)
                let best = quietestCentre(audio, offset: read.lowerBound, candidates: leftLo...leftHi,
                                          rms: rms, levels: &levels)
                left = SeamCandidate(frame: best.frame, db: best.db, read: read, audio: audio)
            }
            var right: SeamCandidate?
            if rightHi >= rightLo {
                let read = rightStart..<(rightHi + half)
                let audio = try base.read(read, isCancelled)
                let best = quietestCentre(audio, offset: read.lowerBound, candidates: rightLo...rightHi,
                                          rms: rms, levels: &levels)
                right = SeamCandidate(frame: best.frame, db: best.db, read: read, audio: audio)
            }
            // The widest span either crossfade could need (the voiced one).
            let span = (left.map { $0.frame - xfVoiced / 2 } ?? 0)
                ..< (right.map { $0.frame - xfVoiced / 2 + xfVoiced } ?? outputFrames)
            plans.append(Plan(index: index, left: left, right: right, levels: levels, span: span))
        }
        lap("seams")
        let toRender = plans.reduce(0) { $0 + $1.span.count + preRoll }
        guard toRender <= cap else {
            return .declined("the regions to render are \(toRender) frames, over the cap of \(cap)")
        }
        var rendered = 0
        for var plan in plans {
            let spanStart = plan.span.lowerBound
            var planar = try StretchRenderCache.renderOutputFrames(
                plan.span, of: source, params: job.params,
                renderCacheDirectory: job.renderCacheDirectory, detector: job.detector,
                isCancelled: isCancelled).planar
            rendered += plan.span.count
            appendBlockLevels(planar, rms: rms, into: &plan.levels)
            let active = percentileDb(plan.levels, 0.9)
            var trimStart = 0
            var trimEnd = planar[0].count
            var seams: [Seam] = []
            for (side, candidate) in [(Seam.Side.left, plan.left), (.right, plan.right)] {
                guard let candidate else { continue }
                let quiet = candidate.db <= active - tuning.quietBelowActiveDb
                let xf = quiet ? xfQuiet : xfVoiced
                let fadeStart = candidate.frame - xf / 2
                let offset = fadeStart - candidate.read.lowerBound
                let baseSlice = candidate.audio.map { Array($0[offset..<(offset + xf)]) }
                let result = crossfade(&planar, at: fadeStart - spanStart, count: xf, base: baseSlice,
                                       intoSpan: side == .left, tuning: tuning)
                if side == .left { trimStart = fadeStart - spanStart } else { trimEnd = fadeStart + xf - spanStart }
                seams.append(Seam(side: side, centreFrame: candidate.frame, crossfadeFrames: xf,
                                  law: result.law, seamRmsDb: candidate.db, activeRmsDb: active,
                                  correlation: result.correlation, isQuiet: quiet))
            }
            let entry = PatchMemo.Entry(
                patch: Patch(firstFrame: spanStart + trimStart,
                             planar: planar.map { Array($0[trimStart..<trimEnd]) }),
                seams: seams, span: plan.span)
            job.memo?.store(keys[plan.index], entry)
            results[plan.index] = entry
        }
        lap("span")
        let entries = results.compactMap { $0 }
        return .patches(entries.map(\.patch), entries.flatMap(\.seams), spans: entries.map(\.span),
                        rendered: rendered, reused: reused)
    }

    /// Patches built for a base, by everything each one reads (`splice`'s memo
    /// key), least recently used first out. Bounded in bytes. Thread-safe;
    /// in practice touched only by `ProvisionalRenderStore`'s serial queue.
    final class PatchMemo: Sendable {
        struct Entry: Sendable {
            let patch: Patch
            let seams: [Seam]
            let span: Range<Int>
            var bytes: Int { patch.planar.reduce(0) { $0 + $1.count * MemoryLayout<Float>.size } }
        }
        private struct State {
            var entries: [String: Entry] = [:]
            var order: [String] = []
            var bytes = 0
        }
        private let state = OSAllocatedUnfairLock(initialState: State())
        let maxBytes: Int

        init(maxBytes: Int = 64 << 20) { self.maxBytes = maxBytes }

        func entry(_ key: String) -> Entry? {
            state.withLock { state in
                guard let entry = state.entries[key] else { return nil }
                state.order.removeAll { $0 == key }
                state.order.append(key)
                return entry
            }
        }

        func store(_ key: String, _ entry: Entry) {
            state.withLock { state in
                if let old = state.entries.removeValue(forKey: key) {
                    state.bytes -= old.bytes
                    state.order.removeAll { $0 == key }
                }
                state.entries[key] = entry
                state.order.append(key)
                state.bytes += entry.bytes
                while state.bytes > maxBytes, state.order.count > 1 {
                    let oldest = state.order.removeFirst()
                    if let gone = state.entries.removeValue(forKey: oldest) { state.bytes -= gone.bytes }
                }
            }
        }

        var countForTesting: Int { state.withLock { $0.entries.count } }
        var bytesForTesting: Int { state.withLock { $0.bytes } }
        /// The stored keys, least recently used first: what a golden pins.
        var keysForTesting: [String] { state.withLock { $0.order } }
    }

    /// One seam's chosen centre, its RMS, and the base frames read around it.
    private struct SeamCandidate {
        let frame: Int
        let db: Double
        let read: Range<Int>
        let audio: [[Float]]
    }

    /// The candidate centre with the lowest `rms`-frame RMS of `planar`
    /// (channels averaged in power), and that RMS in dBFS. Also appends the
    /// region's 10 ms block levels to `levels` for the active level.
    static func quietestCentre(_ planar: [[Float]], offset: Int, candidates: ClosedRange<Int>,
                               rms: Int, levels: inout [Float]) -> (frame: Int, db: Double) {
        let count = planar.first?.count ?? 0
        var prefix = [Double](repeating: 0, count: count + 1)
        for i in 0..<count {
            var power = 0.0
            for channel in planar.indices { power += Double(planar[channel][i] * planar[channel][i]) }
            prefix[i + 1] = prefix[i] + power / Double(max(1, planar.count))
        }
        var best = (frame: candidates.lowerBound, power: Double.infinity)
        for centre in candidates {
            let lo = centre - rms / 2 - offset
            let hi = lo + rms
            guard lo >= 0, hi <= count else { continue }
            let power = (prefix[hi] - prefix[lo]) / Double(rms)
            if power < best.power { best = (centre, power) }
        }
        appendBlockLevels(planar, rms: rms, into: &levels)
        return (best.frame, decibels(best.power.isFinite ? best.power : 0))
    }

    static func appendBlockLevels(_ planar: [[Float]], rms: Int, into levels: inout [Float]) {
        let count = planar.first?.count ?? 0
        var start = 0
        while start + rms <= count {
            var power = 0.0
            for channel in planar.indices {
                for i in start..<(start + rms) {
                    power += Double(planar[channel][i] * planar[channel][i])
                }
            }
            levels.append(Float(decibels(power / Double(rms * max(1, planar.count)))))
            start += rms
        }
    }

    static func decibels(_ power: Double) -> Double { 10 * log10(max(power, 1e-24)) }

    static func percentileDb(_ levels: [Float], _ p: Double) -> Double {
        guard !levels.isEmpty else { return -240 }
        let sorted = levels.sorted()
        return Double(sorted[min(sorted.count - 1, Int(p * Double(sorted.count - 1)))])
    }

    /// Crossfades `count` frames of `planar` starting at `start` with `base`
    /// (`count` frames per channel): base → span when `intoSpan`, span → base
    /// otherwise. The law comes from the two sides' normalised correlation.
    static func crossfade(_ planar: inout [[Float]], at start: Int, count: Int, base: [[Float]],
                          intoSpan: Bool, tuning: Tuning) -> (law: Law, correlation: Double) {
        var cross = 0.0, basePower = 0.0, spanPower = 0.0
        for channel in planar.indices {
            for i in 0..<count {
                let b = Double(base[channel][i]), s = Double(planar[channel][start + i])
                cross += b * s
                basePower += b * b
                spanPower += s * s
            }
        }
        let denominator = (basePower * spanPower).squareRoot()
        let correlation = denominator > 1e-20 ? cross / denominator : 1
        let law: Law = correlation >= tuning.equalGainCorrelation ? .equalGain
            : tuning.partialCorrelationLaw
        let rho = min(1, max(0, correlation))
        for i in 0..<count {
            let t = (Double(i) + 0.5) / Double(count)
            let toSpan = intoSpan ? t : 1 - t
            let spanGain: Float, baseGain: Float
            switch law {
            case .equalGain:
                spanGain = Float(toSpan)
                baseGain = Float(1 - toSpan)
            case .equalPower:
                spanGain = Float(sin(Double.pi / 2 * toSpan))
                baseGain = Float(cos(Double.pi / 2 * toSpan))
            case .powerMatched:
                let norm = (toSpan * toSpan + (1 - toSpan) * (1 - toSpan)
                    + 2 * rho * toSpan * (1 - toSpan)).squareRoot()
                spanGain = Float(toSpan / norm)
                baseGain = Float((1 - toSpan) / norm)
            }
            for channel in planar.indices {
                planar[channel][start + i] = baseGain * base[channel][i]
                    + spanGain * planar[channel][start + i]
            }
        }
        return (law, correlation)
    }

    // MARK: - Assembly

    /// The processing format a render of `source` is written in.
    static func sourceProcessingFormat(_ source: URL) throws -> AVAudioFormat {
        try AVAudioFile(forReading: source).processingFormat
    }

    /// Writes the base with `patches` over it to `destination` (atomically:
    /// a partial, then a rename). Clone-and-patch when the base is a render
    /// file whose layout is exactly what `performRender` writes; the streaming
    /// rewrite otherwise (and when cloning fails). The two produce the same
    /// bytes (`ProvisionalRenderTests.cloneAndPatchEqualsRewrite`).
    static func assemble(base: URL, baseIsSource: Bool, patches: [Patch], outputFrames: Int,
                         channels: Int, sampleRate: Double, sourceFormat: AVAudioFormat,
                         to destination: URL, forceRewrite: Bool = false,
                         isCancelled: () -> Bool) throws -> Assembly {
        let partial = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).partial")
        defer { try? FileManager.default.removeItem(at: partial) }  // no-op after rename
        var assembly = Assembly.rewrite
        if !forceRewrite, !baseIsSource,
           let layout = CAFLayout.parse(base), layout.matches(channels: channels,
                                                            sampleRate: sampleRate,
                                                            frames: outputFrames),
           clonefile(base.path, partial.path, 0) == 0 {
            do {
                try patchInPlace(partial, layout: layout, patches: patches)
                assembly = .clone
            } catch {
                try? FileManager.default.removeItem(at: partial)
            }
        }
        if assembly == .rewrite {
            try rewrite(base: base, patches: patches, outputFrames: outputFrames,
                        sourceFormat: sourceFormat, to: partial, isCancelled: isCancelled)
        }
        if isCancelled() { throw OfflineStretcherError.cancelled }
        do {
            try FileManager.default.moveItem(at: partial, to: destination)
        } catch {
            // The same pair built twice: deterministic content, so the one on
            // disk is ours.
            guard FileManager.default.fileExists(atPath: destination.path) else { throw error }
        }
        return assembly
    }

    /// `pwrite`s each patch, interleaved little-endian Float32, at its frames'
    /// offset in the clone's data payload.
    static func patchInPlace(_ url: URL, layout: CAFLayout, patches: [Patch]) throws {
        #if !_endian(little)
        throw OfflineStretcherError.unsupportedFormat("big-endian host")
        #else
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        for patch in patches {
            let frames = patch.planar.first?.count ?? 0
            guard frames > 0 else { continue }
            let channels = patch.planar.count
            var interleaved = [Float](repeating: 0, count: frames * channels)
            for channel in 0..<channels {
                for i in 0..<frames { interleaved[i * channels + channel] = patch.planar[channel][i] }
            }
            var offset = off_t(layout.payloadOffset + patch.firstFrame * layout.bytesPerFrame)
            try interleaved.withUnsafeBytes { raw in
                var written = 0
                while written < raw.count {
                    let n = pwrite(fd, raw.baseAddress! + written, raw.count - written, offset)
                    guard n > 0 else {
                        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    }
                    written += n
                    offset += off_t(n)
                }
            }
        }
        #endif
    }

    /// THE REFERENCE: read the base through `AVAudioFile` in blocks, overlay
    /// the patches, and write with `performRender`'s settings.
    static func rewrite(base: URL, patches: [Patch], outputFrames: Int,
                        sourceFormat: AVAudioFormat, to partial: URL,
                        isCancelled: () -> Bool) throws {
        let reader = try AVAudioFile(forReading: base)
        let format = reader.processingFormat
        guard Int(reader.length) == outputFrames,
              format.channelCount == sourceFormat.channelCount,
              format.sampleRate == sourceFormat.sampleRate else {
            throw OfflineStretcherError.invalidInput("base \(base.lastPathComponent) does not match")
        }
        let block = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(block)) else {
            throw OfflineStretcherError.allocationFailed
        }
        let writer = try AVAudioFile(forWriting: partial,
                                     settings: StretchRenderCache.renderFileSettings(
                                        sourceFormat: sourceFormat),
                                     commonFormat: .pcmFormatFloat32, interleaved: false)
        var position = 0
        while position < outputFrames {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            let want = min(block, outputFrames - position)
            try reader.read(into: buffer, frameCount: AVAudioFrameCount(want))
            let got = Int(buffer.frameLength)
            guard got > 0, let data = buffer.floatChannelData else {
                throw OfflineStretcherError.invalidInput("short read of \(base.lastPathComponent)")
            }
            let blockRange = position..<(position + got)
            for patch in patches {
                let overlap = patch.frames.clamped(to: blockRange)
                guard !overlap.isEmpty else { continue }
                for channel in 0..<Int(format.channelCount) {
                    for frame in overlap {
                        data[channel][frame - position] = patch.planar[channel][frame - patch.firstFrame]
                    }
                }
            }
            try writer.write(from: buffer)
            position += got
        }
    }

    /// The layout of a Float32 CAF as `AVAudioFile` writes a render file,
    /// parsed STRICTLY: anything else takes the rewrite.
    struct CAFLayout: Equatable, Sendable {
        let sampleRate: Double
        let channels: Int
        let bytesPerFrame: Int
        /// Byte offset of frame 0 (after the data chunk's edit count).
        let payloadOffset: Int
        let frames: Int

        func matches(channels: Int, sampleRate: Double, frames: Int) -> Bool {
            self.channels == channels && self.sampleRate == sampleRate && self.frames == frames
        }

        /// MEASURED 2026-09-25 (`ProvisionalRenderTests.cafLayoutOfARenderFile`
        /// pins it): the header `AVAudioFile` writes is content-independent,
        /// `desc` flags are 3 (float | little-endian), and the `data` chunk is
        /// last with its size filled in.
        static func parse(_ url: URL) -> CAFLayout? {
            guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
            defer { try? handle.close() }
            guard let fileSize = try? handle.seekToEnd(),
                  (try? handle.seek(toOffset: 0)) != nil,
                  let head = try? handle.read(upToCount: 65_536), head.count >= 8 else { return nil }
            let bytes = [UInt8](head)
            func u32(_ at: Int) -> UInt32 {
                bytes[at..<(at + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
            }
            func u64(_ at: Int) -> UInt64 {
                bytes[at..<(at + 8)].reduce(0) { ($0 << 8) | UInt64($1) }
            }
            guard bytes[0..<4] == [0x63, 0x61, 0x66, 0x66],  // "caff"
                  bytes[4] == 0, bytes[5] == 1 else { return nil }  // version 1
            var at = 8
            var desc: (rate: Double, channels: Int, bytesPerFrame: Int)?
            while at + 12 <= bytes.count {
                let type = String(bytes: bytes[at..<(at + 4)], encoding: .ascii) ?? ""
                let size = Int64(bitPattern: u64(at + 4))
                let body = at + 12
                if type == "desc" {
                    guard size == 32, body + 32 <= bytes.count else { return nil }
                    let rate = Double(bitPattern: u64(body))
                    let formatID = u32(body + 8)
                    let flags = u32(body + 12)
                    let bytesPerPacket = Int(u32(body + 16))
                    let framesPerPacket = u32(body + 20)
                    let channels = Int(u32(body + 24))
                    let bits = u32(body + 28)
                    guard formatID == 0x6c70_636d,  // "lpcm"
                          flags == 3, bits == 32, framesPerPacket == 1, channels >= 1,
                          bytesPerPacket == 4 * channels else { return nil }
                    desc = (rate, channels, bytesPerPacket)
                } else if type == "data" {
                    guard let desc, size >= 4 else { return nil }
                    let payload = body + 4  // after the edit count
                    let payloadBytes = Int(size) - 4
                    guard UInt64(payload + payloadBytes) == fileSize,
                          payloadBytes % desc.bytesPerFrame == 0 else { return nil }
                    return CAFLayout(sampleRate: desc.rate, channels: desc.channels,
                                     bytesPerFrame: desc.bytesPerFrame, payloadOffset: payload,
                                     frames: payloadBytes / desc.bytesPerFrame)
                }
                guard size >= 0 else { return nil }
                at = body + Int(size)
            }
            return nil
        }
    }
}
