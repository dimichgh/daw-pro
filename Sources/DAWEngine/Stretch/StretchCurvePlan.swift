import AVFAudio
import CryptoKit
import DAWCore
import Foundation

// m23-q Phase 1 — THE TWO THINGS THE RENDER PATH OWNS THAT THE MODEL
// DELIBERATELY DOES NOT: the OUTPUT-FRAME ↔ SOURCE-SECOND mapping, and the
// deterministic digest that puts a clip's pitch edits into the render cache's
// identity.
//
// `PitchCorrection.swift`'s banner states the split: the model is authoritative
// in SOURCE-FILE SECONDS and offers no output-frame overload, because
// converting between the two needs the stretch schedule AND the curve latency,
// and a model that knew about both would be a second place that believes it
// owns the mapping. This file is that one place.

/// The mapping between a stretch render's DELIVERED OUTPUT FRAMES and the
/// SOURCE-FILE SECONDS a `PitchCorrectionCurve` is defined in.
///
/// **The derivation, in full, because every term is load-bearing:**
///
///  1. `StretchRenderCache` renders the WHOLE source file, never a clip window
///     (spec §3 — that is what makes a split clip share one phase-coherent
///     render and clip geometry never invalidate a key). So the render's input
///     frame 0 IS source-file second 0, and `Clip.startOffsetSeconds`,
///     `startBeat` and `lengthBeats` do not enter here at all.
///  2. `OfflineStretcher`'s alignment contract: delivered output frame 0
///     corresponds to input frame 0, and the output is exactly
///     `round(inputFrames × ratio)` frames.
///  3. The ratio is CONSTANT across the render (per-note timing is phase 3 and
///     is explicitly unread today), so the schedule is uniform: delivered
///     output frame `f` is fed by input frame `f / ratio`. ⚠️ m23-ap C2-1
///     added the representation (`PitchTimeWarp`) and the digest's time-warp
///     block, and this is STILL true after it: nothing here builds a W yet.
///     C2-3 makes this step read `W⁻¹(f / (ratio × sampleRate))` (timing
///     design §3.4 step 2), keeping today's expression verbatim as the
///     untimed branch.
///  4. The render runs at the SOURCE file's sample rate (the CAF is written at
///     `format.sampleRate`), so input frame `f / ratio` is source second
///     `f / (ratio × sampleRate)`.
///
/// Drop the ratio from step 3 — the single most likely mistake here — and a
/// correction asked for at source second 1.0 lands at output second 1.0 on a
/// half-speed render instead of 2.0. `PitchCurveRenderTests` renders exactly
/// that case at ratio 2 and measures where the pitch actually moves.
struct StretchCurvePlan: Sendable {
    /// **Does the render read the time warp W?** `false`: step 3 above is
    /// still `f / ratio`, and no render builds a W.
    ///
    /// ⚠️ **C2-3 FLIPS THIS IN THE SAME DIFF THAT MAKES STEP 3 READ W.** The
    /// bridge's time base (`RenderTimeBase`) reads it (p2-ren Stage A). While it
    /// is false, a timing-only edit re-keys the render but renders the same
    /// audio, so a pending clip may play its previous file, which is exact.
    /// Once W is read, a different W is a different time base, and the clip is
    /// silent while its render is pending, as every clip was before the bridge.
    /// Leave it false after C2-3 and the bridge would play the OLD timing for
    /// a moment and call it the previous version: right speed, wrong place.
    static let readsTimeWarp = false

    /// The SOURCE file's sample rate — the rate the render runs at.
    let sampleRate: Double
    /// `Clip.stretchRatio`: output duration multiplier.
    let ratio: Double
    /// The evaluator. Already carries the clip's whole-clip
    /// `pitchShiftSemitones`, which it SUBSUMES (design §6.4/§7.8: no second
    /// whole-clip pitch path) — so a renderer driven by this plan must NOT
    /// also pass `semitones:` to the stretcher.
    let curve: PitchCorrectionCurve

    /// Step 4 above, for a render that holds a plan. It forwards to the static
    /// form below, which is the ONLY expression of the mapping.
    func sourceSecond(forOutputFrame frame: Int) -> Double {
        Self.sourceSecond(forOutputFrame: frame, ratio: ratio, sampleRate: sampleRate)
    }

    /// Step 4 above, and the ONLY expression of it. It is static because a
    /// render that builds NO plan still needs it: I7a's level mask runs on a
    /// level-only render (no curve, no stretcher) and on a stretched clip
    /// whose edits bend no pitch. C2-3 makes this W-aware, once, for both.
    static func sourceSecond(forOutputFrame frame: Int, ratio: Double,
                             sampleRate: Double) -> Double {
        guard ratio > 0, sampleRate > 0 else { return 0 }
        return Double(frame) / (ratio * sampleRate)
    }

    /// The INVERSE of step 4 (I1): the first delivered output frame whose
    /// source second is at or after `sourceSecond`, for a render that holds a
    /// plan. It forwards to the static form below.
    func outputFrame(forSourceSecond sourceSecond: Double) -> Int {
        Self.outputFrame(forSourceSecond: sourceSecond, ratio: ratio, sampleRate: sampleRate)
    }

    /// The INVERSE of step 4, source second → delivered output frame, for any
    /// render, including one with no plan (a pure stretch, or a source file at
    /// ratio 1). I1's audition maps a note's span onto the frames of the file
    /// playback plays through here, and nowhere else.
    ///
    /// ⭐ **NOT A SECOND EXPRESSION OF THE MAPPING.** It is a search over
    /// `sourceSecond(forOutputFrame:ratio:sampleRate:)`: a doubling probe finds
    /// a frame at or past the target, then `firstOutputFrame(atOrAfter…)`
    /// bisects. The forward formula stays the ONLY formula, so C2-3's W makes
    /// BOTH directions W-aware by changing it once (a search needs only that
    /// the forward mapping stays monotone).
    ///
    /// Exact on every frame: `outputFrame(forSourceSecond: sourceSecond(
    /// forOutputFrame: f)) == f` (pinned at ratios 1, 1.5 and 0.5). 0 for a
    /// non-positive or NaN second and for an unusable ratio or rate;
    /// `outputFrameSearchLimit` for a second beyond it.
    static func outputFrame(forSourceSecond sourceSecond: Double, ratio: Double,
                            sampleRate: Double) -> Int {
        guard ratio > 0, sampleRate > 0, !sourceSecond.isNaN, sourceSecond > 0 else { return 0 }
        var high = 1
        while Self.sourceSecond(forOutputFrame: high, ratio: ratio, sampleRate: sampleRate)
            < sourceSecond {
            guard high <= outputFrameSearchLimit / 2 else { return outputFrameSearchLimit }
            high *= 2
        }
        return firstOutputFrame(atOrAfterSourceSecond: sourceSecond, frames: high,
                                ratio: ratio, sampleRate: sampleRate)
    }

    /// The largest frame `outputFrame(forSourceSecond:…)` answers: about 12 h
    /// at 48 kHz, past any file; it only bounds the probe on a bad input.
    static let outputFrameSearchLimit = Int(Int32.max)

    /// The first delivered output frame whose source second is at or after
    /// `sourceSecond`, or `frames` when there is none. It is a binary search
    /// over the forward mapping above (monotone in the frame), so the
    /// mapping keeps one expression and never grows an inverse.
    static func firstOutputFrame(atOrAfterSourceSecond sourceSecond: Double, frames: Int,
                                 ratio: Double, sampleRate: Double) -> Int {
        var low = 0
        var high = max(0, frames)
        while low < high {
            let mid = low + (high - low) / 2
            if Self.sourceSecond(forOutputFrame: mid, ratio: ratio, sampleRate: sampleRate)
                < sourceSecond {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }

    /// **I7a/U-C: THE LEVEL MASK PASS.** It multiplies each delivered output
    /// frame by `PitchEditSet.gain(atSourceSecond:)`, the ONE mask home, at
    /// the source second that frame plays, found through the one mapping
    /// above. Offline only: this runs inside `performRender`'s detached job,
    /// never on the render thread.
    ///
    /// ⭐ **ONLY FRAMES INSIDE A LEVEL-EDITED NOTE ARE VISITED, AND A FRAME
    /// WHOSE MASK IS 1 IS NOT WRITTEN.** Outside those notes the mask is the
    /// literal 1.0 (`PitchNoteLevelTests` pins that bit for bit, including an
    /// untouched note that abuts a cleared one). So every other sample keeps
    /// its bytes by construction, not because `x × 1.0 == x` happens to hold.
    ///
    /// Denormal guard: a product below `Float.leastNormalMagnitude` is
    /// flushed to +0. That can only happen where the mask is below 1, and it
    /// keeps a faded or levelled tail from carrying denormals into the mixer.
    /// A cleared plateau multiplies by exactly 0, so its samples are ±0, and
    /// the flush makes them +0. They are numeric zeros either way (design
    /// §17.5: the gate is `sample == 0`, not a byte compare).
    ///
    /// No-op when the set has no level edit (`PitchEditSet.hasLevelEdits`, the
    /// one predicate), so a set nobody cleared or levelled renders byte for
    /// byte as it did before the mask existed.
    ///
    /// I1-F1: `outputFrameOffset` is the whole-file output frame of
    /// `channels[…][0]`, for a WINDOW of the render (`StretchWindow`). Every
    /// frame is still mapped as a WHOLE-FILE frame, so a window's mask is the
    /// whole-file mask's samples, not a mask of its own. 0 (the whole-file
    /// render) is the arithmetic this pass always did.
    static func applyLevelMask(_ editSet: PitchEditSet, to channels: inout [[Float]],
                               sampleRate: Double, ratio: Double,
                               outputFrameOffset: Int = 0,
                               isCancelled: () -> Bool = { false }) throws {
        guard editSet.hasLevelEdits, let count = channels.first?.count, count > 0 else {
            return
        }
        // Whole-file output frames `outputFrameOffset ..< frames` are present.
        let frames = outputFrameOffset + count
        for note in editSet.segments where note.hasLevelEdits {
            if isCancelled() { throw OfflineStretcherError.cancelled }
            var frame = max(outputFrameOffset,
                            firstOutputFrame(atOrAfterSourceSecond: note.startSeconds,
                                             frames: frames, ratio: ratio,
                                             sampleRate: sampleRate))
            while frame < frames {
                let second = sourceSecond(forOutputFrame: frame, ratio: ratio,
                                          sampleRate: sampleRate)
                guard second < note.endSeconds else { break }
                let gain = editSet.gain(atSourceSecond: second)
                if gain != 1 {
                    let factor = Float(gain)
                    let index = frame - outputFrameOffset
                    for channel in channels.indices {
                        var sample = channels[channel][index] * factor
                        if abs(sample) < Float.leastNormalMagnitude { sample = 0 }
                        channels[channel][index] = sample
                    }
                }
                frame += 1
            }
        }
    }

    /// **THE RENDER'S `D`: the source file's duration that `PitchTimeWarp` is
    /// pinned to** (m23-ap C2-1; timing design §3.2, "Why D is a parameter").
    ///
    /// ONE expression, `Double(file.length) / file.processingFormat.sampleRate`.
    /// It is the one `AudioFileImporter.audioFileInfo(at:)` computes
    /// `durationSeconds` with, which is what the store and the editor read
    /// through `media`. `PitchCurveRenderTests` pins the two BIT-identical on
    /// fixture files. If they ever differ, the display's W and the render's W
    /// differ in their last piece.
    ///
    /// ⚠️ **C2-3 MUST call this in `performRender`, on the reader it already
    /// opened, and must not write its own.** In particular it must not use
    /// the count of frames the read loop delivered: `AVAudioFile.read(into:)`
    /// can return short, and that count is not the file's `length`.
    static func sourceDurationSeconds(of file: AVAudioFile) -> Double {
        let sampleRate = file.processingFormat.sampleRate
        return sampleRate > 0 ? Double(file.length) / sampleRate : 0
    }

    /// What the stretcher should be transposing by at a delivered output frame.
    /// Total: the curve's own evaluator clamps non-finite inputs and results
    /// back to the clip's constant shift, so this can never hand a NaN to
    /// `css_set_transpose_semitones`.
    func semitones(atOutputFrame frame: Int) -> Double {
        curve.semitones(atSourceSecond: sourceSecond(forOutputFrame: frame))
    }

    /// The plan for a render, or `nil` when the clip's edits bend no PITCH and
    /// the render must take the existing constant path BYTE-FOR-BYTE.
    ///
    /// I7a/U-C: the guard is `PitchEditSet.isPitchIdentity`, not `isIdentity`.
    /// A set whose only edits are levels (a cleared note, a per-note level)
    /// takes NO curve. Its level is applied afterwards by `applyLevelMask`,
    /// and on a clip that is neither stretched nor transposed the stretcher
    /// never runs at all (`performRender`'s level-only path).
    ///
    /// `contour` is what `PitchContourCache.renderContour` — THE seam — returned
    /// for this clip's source, and the curve is built through
    /// `PitchRenderContour.curve(editSet:…)` and nothing else, so the render
    /// and a display reading the same seam build the same curve.
    ///
    /// ⚠️ **`nil` IS THE PRE-CONTOUR CURVE, BIT FOR BIT.** A render that needs
    /// no contour (the whole preset ladder, generator-only edits) or whose
    /// contour is unavailable passes `nil`, and gets exactly the curve this
    /// function built before the contour reached the render:
    /// `PitchCorrectionCurve.make(editSet:clipPitchShiftSemitones:)`. Segments
    /// asking for drift/vibrato SHAPING then keep their constant offset and are
    /// named in `curve.unresolvedShapingSegmentIDs`.
    /// `NoteVibratoGeneratorTests`' render goldens stand on this branch.
    static func make(editSet: PitchEditSet?,
                     clipPitchShiftSemitones: Double,
                     sampleRate: Double,
                     ratio: Double,
                     contour: PitchRenderContour? = nil) -> StretchCurvePlan? {
        guard let editSet, !editSet.isPitchIdentity else { return nil }
        let curve = contour?.curve(editSet: editSet,
                                   clipPitchShiftSemitones: clipPitchShiftSemitones)
            ?? PitchCorrectionCurve.make(editSet: editSet,
                                         clipPitchShiftSemitones: clipPitchShiftSemitones)
        return StretchCurvePlan(sampleRate: sampleRate, ratio: ratio, curve: curve)
    }
}

/// The deterministic content digest of a clip's pitch edits — the material
/// that puts an edit set into the render cache's key and into the playback
/// graph's schedule identity.
///
/// ⚠️⚠️ **NOT `Hashable.hashValue`, AND THAT IS THE WHOLE POINT.** Swift's
/// hashing is seeded per PROCESS: the same edit set hashes differently in the
/// next launch, so an on-disk cache keyed on it would miss forever and grow
/// without bound. This is SHA256 over the fields' raw bit patterns, which is
/// stable across launches, machines and OS versions.
///
/// ⚠️ **EVERY STORED FIELD IS HASHED, INCLUDING THE ONES NO RENDERER READS**
/// (`formantOffsetSemitones` and the phase-3 timing deltas). Hashing an unread
/// field costs at worst one redundant re-render when it changes; MISSING a
/// field that later becomes read costs stale audio nobody can explain.
/// `PitchCurveRenderTests.digestCoversEveryStoredField` enumerates
/// `NoteSegment`'s stored properties by REFLECTION and fails when a new one
/// appears, so the next field cannot be added without this being updated.
enum PitchEditSetDigest {
    /// Bumped when the LAYOUT below changes (field order, added field). Not a
    /// quality version — `StretchRenderCache.stretchEngineVersion` owns that.
    ///
    /// ⚠️ **STILL 1 AFTER m23-ap C5a ADDED THREE FIELDS, AND THAT IS NOT AN
    /// OVERSIGHT.** The generator's fields are hashed in a SUFFIX BLOCK that
    /// is emitted only when at least one segment actually carries a generator
    /// (`suffixMarker` below). A set without one therefore produces the SAME
    /// BYTES it produced before those fields existed, so every cache entry on
    /// every existing disk stays valid. Bumping this instead would have
    /// orphaned all of them — correct audio, but a silent re-render of every
    /// corrected vocal in every project, which is precisely the cost the
    /// "appended only when non-empty" rule was invented to avoid when
    /// `pitchEditSetHash` was first added to the key.
    ///
    /// **STILL 1 AFTER m23-ap C2-1 ADDED THE TIME-WARP BLOCK, FOR THE SAME
    /// REASON.** The block is emitted only when a set has time edits, so every
    /// untimed set keeps its bytes. See the block-order note in `hex`.
    ///
    /// **STILL 1 AFTER I7a ADDED THE LEVEL BLOCK (slot 5), AGAIN FOR THE SAME
    /// REASON.** It is emitted only when a note is cleared or levelled, so a
    /// set with neither keeps its bytes.
    static let layoutVersion: UInt64 = 1

    /// Introduces the generator suffix block. An arbitrary, distinctive
    /// constant; its only job is to make the suffix's presence explicit in the
    /// hashed stream rather than implied by length.
    static let suffixMarker: UInt64 = 0x5631_4252_4154_4F01

    /// Introduces the TIME-WARP block (m23-ap C2-1, timing design §3.5).
    /// Distinct from every other block's marker, so which blocks a stream
    /// carries is explicit in the stream, not implied by its length.
    static let timeWarpSuffixMarker: UInt64 = 0x5431_4D45_5752_5001

    /// Introduces the LEVEL block (I7a/U-C, interaction-batch design §17,
    /// slot 5): "L1EVELS" plus a 01, in the style of the two markers above,
    /// and distinct from both.
    static let levelSuffixMarker: UInt64 = 0x4C31_4556_454C_5301

    /// Hex digest, or `""` when the set bends nothing.
    ///
    /// **`""` for nil AND for an identity set**, which is the §6.4 rule
    /// expressed as a key: a clip carrying freshly DETECTED but unedited notes
    /// must produce the same cache key — and therefore the same render, and on
    /// an identity clip the same identity BYPASS — as a clip with no notes at
    /// all. It matches `Clip.hasPitchEdits` by construction, and a test pins
    /// that the two agree.
    static func hex(_ set: PitchEditSet?) -> String {
        guard let set, !set.isIdentity else { return "" }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(40 + set.segments.count * 112)
        func putBits(_ value: UInt64) {
            withUnsafeBytes(of: value.littleEndian) { bytes.append(contentsOf: $0) }
        }
        func putDouble(_ value: Double) { putBits(value.bitPattern) }
        func putInt(_ value: Int) { putBits(UInt64(bitPattern: Int64(value))) }
        func putUUID(_ value: UUID) {
            withUnsafeBytes(of: value.uuid) { bytes.append(contentsOf: $0) }
        }

        putBits(layoutVersion)
        putInt(set.analysisVersion)
        putDouble(set.retuneMs)
        putInt(set.segments.count)
        for segment in set.segments {
            putUUID(segment.id)
            putDouble(segment.startSeconds)
            putDouble(segment.endSeconds)
            putDouble(segment.detectedHz)
            putDouble(segment.detectedConfidence)
            putDouble(segment.pitchOffsetCents)
            putDouble(segment.driftScale)
            putDouble(segment.vibratoScale)
            putDouble(segment.formantOffsetSemitones)
            putDouble(segment.timeStartDeltaSeconds)
            putDouble(segment.timeEndDeltaSeconds)
            putDouble(segment.amplitudeDb)
        }
        // m23-ap C5a — THE GENERATOR SUFFIX. Emitted only when at least one
        // segment carries a generator, so a legacy set hashes byte-for-byte
        // the material it always did (see `layoutVersion`). When it IS
        // emitted it covers EVERY segment's three fields, not just the ones
        // with a depth: a rate changed on a segment whose depth is zero is
        // inert TODAY, and a hash that omitted it would serve the wrong audio
        // the moment that depth became non-zero in the same edit.
        //
        // ═══════════════════════════════════════════════════════════════════
        // ⭐ THE SUFFIX BLOCKS: ONE FIXED ORDER, EACH MARKER-GATED.
        //   1. generator   (m23-ap C5a)   — below
        //   2. anchor      (C5a-1)        — RESERVED SLOT, not yet written
        //   3. time warp   (C2-1)         — below
        //   4. shape       (C5b-1)        — RESERVED SLOT, not yet written
        //   5. level       (I7a/U-C)      — below
        //   6. origin      (U-A)          — RESERVED SLOT, not yet written
        // (vibrato-handle design §7.5; timing design §5.4; interaction-batch
        // design §17; unpitched-notes design §1.4.) Each block is
        // emitted only when some segment uses its feature, so a block
        // inserted into its slot later changes no digest except those of the
        // sets that use it. The order is by slot, never by which item landed
        // first. A block placed out of its slot would change the digest of
        // every set that uses two of these features, relative to the order
        // both design documents fix.
        // ═══════════════════════════════════════════════════════════════════
        //
        // (1) m23-ap C5a — THE GENERATOR SUFFIX.
        if set.segments.contains(where: \.hasGeneratedVibrato) {
            putBits(suffixMarker)
            putInt(set.segments.count)
            for segment in set.segments {
                putDouble(segment.vibratoRateHz)
                putDouble(segment.vibratoDepthCents)
                putDouble(segment.vibratoOnsetSeconds)
            }
        }
        // (2) RESERVED — the vibrato phase-anchor block (C5a-1) goes HERE,
        // after the generator block and BEFORE the time-warp block. Gated on
        // `hasGeneratedVibrato && vibratoPhaseAnchorSeconds != 0` (design
        // §7.5). Nothing is emitted for it today.
        //
        // (3) m23-ap C2-1 — THE TIME-WARP BLOCK. The deltas themselves are
        // already hashed INLINE above, so this block does not carry them. Its
        // one job is the stale-key hazard (timing design F7, §3.5). A set that
        // carried non-zero deltas BEFORE C2 was rendered with them IGNORED,
        // under a key that already included them. On the day the render
        // starts reading them, that same key would serve the stale, unwarped
        // audio. This block re-keys exactly the retimed sets, including
        // those written before C2 existed, and `scheduleVersion` re-keys them
        // again whenever the warped schedule changes. `D` is NOT hashed: it
        // is a property of the source file, whose identity
        // `sourceIdentityFields(source:)` already puts in the render key.
        // Gated on `PitchEditSet.hasTimeEdits`, the one predicate.
        if set.hasTimeEdits {
            putBits(timeWarpSuffixMarker)
            putInt(PitchTimeWarp.scheduleVersion)
        }
        // (4) RESERVED — the drawn-shape block (C5b-1) goes HERE, after the
        // time-warp block. Nothing is emitted for it today.
        //
        // (5) I7a/U-C — THE LEVEL BLOCK (interaction-batch design §17).
        // `amplitudeDb` is already hashed INLINE above, and it stays there:
        // moving it would re-key every set. This block carries the one level
        // field that is not inline, each segment's CLEARED byte. It also closes
        // the stale-key hazard, the time-warp block's F7 precedent. A set that
        // carried a non-zero `amplitudeDb` before U-C was rendered with it
        // IGNORED, under a key that already hashed it. On the day the render
        // reads it, that same key would serve the unlevelled audio. Gated on
        // `PitchEditSet.hasLevelEdits`, the one predicate, so it re-keys
        // exactly the cleared or levelled sets, including those written before
        // U-C. `PitchEditSet.levelMaskVersion` re-keys them again whenever the
        // mask's arithmetic changes.
        if set.hasLevelEdits {
            putBits(levelSuffixMarker)
            putInt(PitchEditSet.levelMaskVersion)
            putInt(set.segments.count)
            for segment in set.segments {
                bytes.append(segment.isCleared ? 1 : 0)
            }
        }
        // (6) RESERVED — the unpitched origin block (U-A) goes HERE, after the
        // level block. Gated on `segments.contains { $0.origin != .detected }`
        // (unpitched-notes design §1.4). Nothing is emitted for it today.
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
