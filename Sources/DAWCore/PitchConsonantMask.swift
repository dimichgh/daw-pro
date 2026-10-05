import Foundation

// Natural tuning §2 (m23-nt, NT-C C2): THE CONSONANT MASK.
//
// Design: `docs/design/2026-09-25-natural-tuning.md` §2b.2 and §2b.5, as
// amended by R1 (the crossfade law is engine-side), R15 (ONE soft/gap
// predicate) and R21 (a sound the user drags still moves).
//
// The user's MUST: consonants, breaths and sibilance never change pitch. The
// mechanism is "the gaps play the untouched take": between notes the render
// plays the SOURCE's own samples, inside notes it plays the tuned render,
// unchanged. This file is the pure DAWCore half, a function of SOURCE seconds
// exactly like the level mask (`PitchEditSet.gain(atSourceSecond:)`,
// `PitchNoteLevel.swift`). The mix itself (`StretchCurvePlan.applyConsonantMix`,
// lane NT-E2) reads `tunedWeight(atSourceSecond:)` and nothing else.
//
// ═══════════════════════════════════════════════════════════════════════════
// THE SHAPE
// ═══════════════════════════════════════════════════════════════════════════
//
//  * A REGION is the time between two neighbouring CURVE notes
//    (`NoteSegment.entersPitchCurve`, THE one predicate) whose join is a
//    `.gap` (`PitchEditSet.joinKind`, THE one soft/gap predicate, R15), plus
//    the HEAD (the clip start to the first curve note, by the same join rule)
//    and the TAIL (after the last curve note, to the end of the take). There
//    is no second gap rule in this file: a hole shorter than
//    `consonantMinimumGapSeconds` is a `.soft` join, and it stays WET (tuned),
//    exactly as it renders today. That is the blink rule.
//  * `tunedWeight` is 1 inside every note and in every soft join, 0 inside a
//    region, and one raised-cosine ramp of `consonantFadeSeconds` joins them.
//    ⭐ **THE RAMP SITS ON THE GAP SIDE ONLY**: it starts at exactly 1 on the
//    note's edge and falls to 0 inside the region, so every note sample keeps
//    weight 1 and its bytes (design gate G-C2). The ramp is clamped to half
//    the region, so the two ramps of a short region meet at 0 in its middle
//    and never overlap.
//
// ═══════════════════════════════════════════════════════════════════════════
// R21, AND WHY THE CURVE'S PREDICATE IS THE MASK'S
// ═══════════════════════════════════════════════════════════════════════════
//
// §2b.6 proposed that every `.unpitched` sound sits inside a region, so a
// dragged breath would render as nothing (U-F2). R21 overrides it: "U5 stays:
// a breath or 's' the user drags on purpose still moves". The rule is the
// curve's own: a segment that ENTERS THE PITCH CURVE is a note (wet), one
// that does not is inside a region (dry). `entersPitchCurve` is every note,
// plus a sound that someone moved (`pitchOffsetCents != 0`, R21's words) or
// gave a drift, vibrato or generator value (which the shape setters refuse on
// sounds, so only a hand-authored file carries one; the curve then names it in
// `unresolvedShapingSegmentIDs`). So an untouched sound plays the dry take and
// a dragged one renders moved, and moving the NOTE beside a sound never moves
// the sound. Reading the curve's predicate, never a copy of it, is what keeps
// "what the curve bends" and "what the mask keeps wet" the same set.
//
// ═══════════════════════════════════════════════════════════════════════════
// ⛔ THE ORDER WITH THE LEVEL MASK IS NOT ARBITRARY
// ═══════════════════════════════════════════════════════════════════════════
//
// §2b.4 says the two masks touch disjoint frames, so their order cannot
// change a byte. That stopped being true when U-A put SOUNDS in the table:
// `gain(atSourceSecond:)` reads every segment, sounds included, so a CLEARED
// untouched sound is inside a region (weight 0, dry) AND level-masked (gain
// 0). Mix, then mask: the dry breath times 0 is silence, as the user asked.
// Mask, then mix: the dry source is mixed back over the silenced frames and
// the cleared breath plays again. The render must run the consonant mix
// BEFORE `applyLevelMask`. `PitchConsonantMaskTests` pins the overlap.

/// One stretch of the take the consonant mix plays DRY (natural tuning §2b.2).
/// Built only by `PitchEditSet.consonantRegions()` and the weight's own
/// lookup, from the same one rule.
public struct PitchConsonantRegion: Sendable, Equatable {
    /// Source seconds where the region starts: the end of the curve note
    /// before it, or 0 for the head.
    public let startSeconds: Double
    /// Source seconds where it ends: the start of the curve note after it, or
    /// `+infinity` for the tail (the render clamps it to the take's length).
    public let endSeconds: Double
    /// A curve note ends at `startSeconds`, so a ramp hands over from it.
    /// False for the head, which starts at the clip start.
    public let followsNote: Bool
    /// A curve note starts at `endSeconds`, so a ramp hands over to it.
    /// False for the tail.
    public let precedesNote: Bool

    public init(startSeconds: Double, endSeconds: Double,
                followsNote: Bool, precedesNote: Bool) {
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.followsNote = followsNote
        self.precedesNote = precedesNote
    }

    /// Region length, seconds; `+infinity` for the tail.
    public var durationSeconds: Double { endSeconds - startSeconds }

    /// The ramp length this region applies at each end that meets a note:
    /// `consonantFadeSeconds`, clamped to half the region. NT-E2's per-join
    /// power-matched law (R1) measures its correlation over exactly these
    /// frames.
    public var fadeSeconds: Double {
        Self.clampedFade(PitchEditSet.consonantFadeSeconds, durationSeconds: durationSeconds)
    }

    /// True when `sourceSecond` lies in `[startSeconds, endSeconds]`. Both
    /// ends are included: the weight is exactly 1 there when a note meets it.
    public func contains(_ sourceSecond: Double) -> Bool {
        sourceSecond >= startSeconds && sourceSecond <= endSeconds
    }

    /// `PitchEditSet.tunedWeight(atSourceSecond:)` for a second inside THIS
    /// region (1 outside it), by the same arithmetic. It exists for the mix's
    /// hot loop: gate once on `consonantMixActive`, take `consonantRegions()`
    /// once, then visit only the frames inside each region (cost O(gap
    /// frames)), instead of re-checking the set per frame.
    /// `PitchConsonantMaskTests` pins the two equal on every probed second.
    public func tunedWeight(atSourceSecond sourceSecond: Double) -> Double {
        PitchEditSet.consonantWeight(atSourceSecond: sourceSecond, in: self,
                                     fadeSeconds: PitchEditSet.consonantFadeSeconds)
    }

    /// ⭐ THE HALF-REGION CLAMP, in one place: a fade never exceeds half the
    /// region, so the ramps of a short region meet at 0 and never overlap. A
    /// negative or non-finite fade reads as 0 (a hard switch).
    static func clampedFade(_ fadeSeconds: Double, durationSeconds: Double) -> Double {
        let fade = fadeSeconds.isFinite ? max(0, fadeSeconds) : 0
        return min(fade, max(0, durationSeconds) / 2)
    }
}

/// Why the consonant mix does not run on a clip whose set asks for it
/// (natural tuning §2b.5). The raw value is the wire's string
/// (`clip.getPitchEdits`' `consonantProtection.inactiveReason`); the pitch
/// editor switches on the CASE and says it in its own words ("Off while the
/// whole clip is transposed"), never the wire's.
public enum ConsonantMixInactiveReason: String, Sendable, Equatable, CaseIterable {
    /// `Clip.stretchRatio != 1`. "Dry" would need a second stretcher pass at
    /// the clip term (follow-up N2-F1).
    case clipStretched = "clip stretched"
    /// `Clip.pitchShiftSemitones != 0`. Today consonants FOLLOW a whole-clip
    /// transpose (the curve's clip term); a raw-source mix would silently
    /// stop that.
    case clipTransposed = "clip transposed"
    /// The set retimes a note AND the render reads the time warp. Dormant
    /// while `consonantMixRenderReadsTimeWarp` is false.
    case timeEdits = "time edits"
}

/// The refusal sentences of the consonant setter, in ONE home so the wire
/// (lane NT-W) echoes them verbatim.
public enum PitchConsonantSentences {
    /// `ProjectStore.setClipConsonantProtection` on a clip with no tuning.
    public static let noTuning =
        "This clip has no tuning yet, so there are no breaths or consonants to keep "
            + "untouched. Tune it first (the note editor or `clip.autoCorrectPitch`); "
            + "new tuning already keeps S, T and breath sounds at their own pitch."
}

extension PitchEditSet {

    /// The version of the mask's ARITHMETIC, hashed into the render digest's
    /// consonant block (slot 8, `PitchEditSetDigest`). ⚠️ **BUMP IT** whenever
    /// `tunedWeight(atSourceSecond:)` would return a different number for the
    /// same set: a new `consonantFadeSeconds`, ramp shape, clamp, head/tail
    /// rule, or a change to `joinKind` or `consonantMinimumGapSeconds` (which
    /// also bump `transitionRenderVersion`). The `levelMaskVersion` precedent.
    public static let consonantMaskVersion: Int = 1

    /// THE ramp length, seconds, on the gap side of each note edge that meets
    /// a region. ⚠️ **PROVISIONAL, NOT MEASURED INTO PLACE.** It is §2b.2's
    /// starting candidate (and the level mask's `levelRampSeconds`). NT-G's
    /// M-3 on the user's take (`scratchpad/w1/NTG/results.md` §2 M-3)
    /// measured wet/dry correlation at 5, 10 and 20 ms fades: 31 of 62 edges
    /// reach ρ ≥ 0.9 at every length (median ρ 0.785 / 0.764 / 0.861), so it
    /// does not pick a length. R1 moved the LAW to the engine (a power-matched
    /// crossfade measured per join), which is what that spread asks for.
    /// Changing this bumps `consonantMaskVersion`.
    public static let consonantFadeSeconds: Double = 0.010

    /// DAWCore's copy of `StretchCurvePlan.readsTimeWarp` (DAWEngine), which
    /// DAWCore cannot import. Only `consonantMixInactiveReason` reads it.
    /// ⛔ **A TRIPWIRE PINS THE TWO EQUAL** (`NaturalTuningConsonantDigestTests`,
    /// G-C9): the day C2-3 flips the render's flag that test turns red, and
    /// §2b.5's "time edits" rule must be re-decided (with a warp, output frame
    /// f no longer plays source frame f, so "dry" needs its own mapping).
    public static let consonantMixRenderReadsTimeWarp = false

    /// ⭐ **THE ONE PREDICATE** for "does this set ask for the consonant mix":
    /// the flag is on and the set bends something. A set that bends nothing
    /// (identity, or levels only) never reaches the stretcher, so there is
    /// nothing to protect. The digest's slot 8, `tunedWeight` and the render
    /// all ask this; none restates it. The `hasLevelEdits` precedent.
    public var hasConsonantMix: Bool { keepsConsonantsUntuned && !isPitchIdentity }

    /// The regions the mix plays DRY, ascending, or `[]` when
    /// `keepsConsonantsUntuned` is off. Gated on the flag alone (not on
    /// `hasConsonantMix`), so a drawing of protected time (N2-F4) can show
    /// them before any note moves; `tunedWeight` adds the set-level gate.
    ///
    /// The head starts at 0 and exists only when the first curve note starts
    /// at least `consonantMinimumGapSeconds` in (the same `joinKind` rule,
    /// with the clip start as its left edge). The tail always exists and ends
    /// at `+infinity`. A table with no curve note at all is one region,
    /// `[0, +infinity]`.
    public func consonantRegions() -> [PitchConsonantRegion] {
        guard keepsConsonantsUntuned else { return [] }
        let curveNotes = segments.indices.filter { segments[$0].entersPitchCurve }
        var neighbours: [(Int?, Int?)] = []
        neighbours.reserveCapacity(curveNotes.count + 1)
        var previous: Int? = nil
        for index in curveNotes {
            neighbours.append((previous, Optional(index)))
            previous = index
        }
        neighbours.append((previous, nil))
        return neighbours.compactMap { consonantRegion(afterCurveNote: $0.0, beforeCurveNote: $0.1) }
    }

    /// ⭐ **THE ONE REGION RULE**, for the time between two neighbouring
    /// curve notes (nil left = the clip start, nil right = the end of the
    /// take), or nil when that time plays WET: a `.soft` join (the notes abut,
    /// or the hole is shorter than `consonantMinimumGapSeconds`). Both
    /// `consonantRegions()` and `tunedWeight` build regions here and nowhere
    /// else.
    func consonantRegion(afterCurveNote left: Int?, beforeCurveNote right: Int?) -> PitchConsonantRegion? {
        switch (left, right) {
        case (let left?, let right?):
            guard joinKind(between: left, and: right) == .gap else { return nil }
            return PitchConsonantRegion(startSeconds: segments[left].endSeconds,
                                        endSeconds: segments[right].startSeconds,
                                        followsNote: true, precedesNote: true)
        case (nil, let right?):
            let firstStart = segments[right].startSeconds
            guard Self.joinKind(leftEndSeconds: 0, rightStartSeconds: firstStart) == .gap else {
                return nil
            }
            return PitchConsonantRegion(startSeconds: 0, endSeconds: firstStart,
                                        followsNote: false, precedesNote: true)
        case (let left?, nil):
            return PitchConsonantRegion(startSeconds: segments[left].endSeconds,
                                        endSeconds: .infinity,
                                        followsNote: true, precedesNote: false)
        case (nil, nil):
            return PitchConsonantRegion(startSeconds: 0, endSeconds: .infinity,
                                        followsNote: false, precedesNote: false)
        }
    }

    /// How much of the TUNED render plays at a SOURCE-FILE second, `0...1`;
    /// the rest is the source's own sample. The mix (NT-E2) reads this and
    /// nothing else: per delivered frame, `tuned·w + source·(1 − w)` under
    /// R1's power-matched normalisation.
    ///
    ///  * 1 when `hasConsonantMix` is false, so the weight is always the one
    ///    the render applies (RenderDiff unions frames whose weights differ).
    ///  * 1 inside every curve note, on its edges, and in every soft join.
    ///  * 0 inside a region, beyond its ramps.
    ///  * A raised cosine from exactly 1 at a note's edge to 0, over the
    ///    region's `fadeSeconds`, on the region side only.
    ///
    /// Pure and total: a non-finite second returns 1, and every value is
    /// finite. No allocation: a binary search, then a walk past any sounds to
    /// the neighbouring curve notes, so it is cheap enough per frame.
    public func tunedWeight(atSourceSecond sourceSecond: Double) -> Double {
        guard sourceSecond.isFinite, hasConsonantMix else { return 1 }
        // `low`: the first segment starting AFTER `sourceSecond` (canonical,
        // so ascending and non-overlapping; `init` guarantees it).
        var low = 0
        var high = segments.count
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].startSeconds <= sourceSecond { low = mid + 1 } else { high = mid }
        }
        var left: Int? = nil
        var index = low - 1
        while index >= 0 {
            if segments[index].entersPitchCurve { left = index; break }
            index -= 1
        }
        // Inside (or on the end of) a curve note: tuned, always.
        if let left, sourceSecond <= segments[left].endSeconds { return 1 }
        var right: Int? = nil
        index = low
        while index < segments.count {
            if segments[index].entersPitchCurve { right = index; break }
            index += 1
        }
        guard let region = consonantRegion(afterCurveNote: left, beforeCurveNote: right) else {
            return 1
        }
        return Self.consonantWeight(atSourceSecond: sourceSecond, in: region,
                                    fadeSeconds: Self.consonantFadeSeconds)
    }

    /// The weight inside ONE region, with the fade as a parameter so a test
    /// can show the half-region clamp (with the shipped 10 ms fade and 64 ms
    /// minimum gap the clamp never binds). 1 outside the region.
    static func consonantWeight(atSourceSecond sourceSecond: Double,
                                in region: PitchConsonantRegion,
                                fadeSeconds: Double) -> Double {
        guard region.contains(sourceSecond) else { return 1 }
        let fade = PitchConsonantRegion.clampedFade(fadeSeconds,
                                                    durationSeconds: region.durationSeconds)
        if region.followsNote {
            let intoRegion = sourceSecond - region.startSeconds
            if intoRegion < fade { return handover(progress: intoRegion / fade) }
        }
        if region.precedesNote {
            let beforeNote = region.endSeconds - sourceSecond
            if beforeNote < fade { return handover(progress: beforeNote / fade) }
        }
        return 0
    }

    /// `½ + ½·cos(π·progress)`: exactly 1 at progress 0 (`cos(0) == 1`), so
    /// the sample on a note's edge keeps weight 1 bit for bit; exactly 0 at
    /// progress 1; strictly falling in between.
    static func handover(progress: Double) -> Double {
        0.5 + 0.5 * cos(Double.pi * progress)
    }

    /// Why the mix does not run on this set's clip, or nil when nothing stops
    /// it (natural tuning §2b.5). ⭐ **THE ONE RULE**: the render (through
    /// `StretchCurvePlan.consonantMixInactiveReason`), the wire
    /// (`clip.getPitchEdits`) and the pitch editor's dim line all call this,
    /// never a local `semitones != 0` (the `glideIsEffective` law,
    /// `docs/DESIGN-LANGUAGE.md`).
    ///
    /// nil when `keepsConsonantsUntuned` is off: the mix is off by choice,
    /// not stopped. Otherwise, in order: a stretched clip, a transposed clip,
    /// then retimed notes while the render reads the time warp. The reason
    /// does not depend on whether a note is moved yet, so the editor can say
    /// "off while transposed" before the first drag.
    public func consonantMixInactiveReason(stretchRatio: Double,
                                           clipSemitones: Double) -> ConsonantMixInactiveReason? {
        guard keepsConsonantsUntuned else { return nil }
        if stretchRatio != 1 { return .clipStretched }
        if clipSemitones != 0 { return .clipTransposed }
        if hasTimeEdits && Self.consonantMixRenderReadsTimeWarp { return .timeEdits }
        return nil
    }

    /// True when the render runs the consonant mix for this set on a clip
    /// with these parameters: the set asks (`hasConsonantMix`) and nothing
    /// stops it. The wire's `consonantProtection.active`.
    public func consonantMixIsActive(stretchRatio: Double, clipSemitones: Double) -> Bool {
        hasConsonantMix
            && consonantMixInactiveReason(stretchRatio: stretchRatio, clipSemitones: clipSemitones) == nil
    }
}
