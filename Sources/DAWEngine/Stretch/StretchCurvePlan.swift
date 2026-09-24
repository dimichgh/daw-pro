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
///     output frame `f` is fed by input frame `f / ratio`.
///  4. The render runs at the SOURCE file's sample rate (the CAF is written at
///     `format.sampleRate`), so input frame `f / ratio` is source second
///     `f / (ratio × sampleRate)`.
///
/// Drop the ratio from step 3 — the single most likely mistake here — and a
/// correction asked for at source second 1.0 lands at output second 1.0 on a
/// half-speed render instead of 2.0. `PitchCurveRenderTests` renders exactly
/// that case at ratio 2 and measures where the pitch actually moves.
struct StretchCurvePlan: Sendable {
    /// The SOURCE file's sample rate — the rate the render runs at.
    let sampleRate: Double
    /// `Clip.stretchRatio`: output duration multiplier.
    let ratio: Double
    /// The evaluator. Already carries the clip's whole-clip
    /// `pitchShiftSemitones`, which it SUBSUMES (design §6.4/§7.8: no second
    /// whole-clip pitch path) — so a renderer driven by this plan must NOT
    /// also pass `semitones:` to the stretcher.
    let curve: PitchCorrectionCurve

    /// Step 4 above, and the ONLY expression of it.
    func sourceSecond(forOutputFrame frame: Int) -> Double {
        guard ratio > 0, sampleRate > 0 else { return 0 }
        return Double(frame) / (ratio * sampleRate)
    }

    /// What the stretcher should be transposing by at a delivered output frame.
    /// Total: the curve's own evaluator clamps non-finite inputs and results
    /// back to the clip's constant shift, so this can never hand a NaN to
    /// `css_set_transpose_semitones`.
    func semitones(atOutputFrame frame: Int) -> Double {
        curve.semitones(atSourceSecond: sourceSecond(forOutputFrame: frame))
    }

    /// The plan for a render, or `nil` when the clip's edits bend nothing and
    /// the render must take the existing constant path BYTE-FOR-BYTE.
    ///
    /// ⚠️ `contour` is the DETECTED per-frame pitch, which is deliberately not
    /// persisted (§7.3). Segments asking for drift/vibrato SHAPING with no
    /// contour to shape still apply their constant offset and are named in
    /// `curve.unresolvedShapingSegmentIDs`; the default auto-correct policy
    /// (`preserveVibrato: true`) never produces one, so nothing today reaches
    /// that branch.
    static func make(editSet: PitchEditSet?,
                     clipPitchShiftSemitones: Double,
                     sampleRate: Double,
                     ratio: Double,
                     contour: [ClipPitchFrame] = []) -> StretchCurvePlan? {
        guard let editSet, !editSet.isIdentity else { return nil }
        return StretchCurvePlan(
            sampleRate: sampleRate,
            ratio: ratio,
            curve: PitchCorrectionCurve.make(
                editSet: editSet, contour: contour,
                clipPitchShiftSemitones: clipPitchShiftSemitones))
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
    static let layoutVersion: UInt64 = 1

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
        var hasher = SHA256()
        hasher.update(data: Data(bytes))
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
