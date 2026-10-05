import Foundation

// I1-F1: THE SET A PITCH DRAG WOULD COMMIT, BUILT WITHOUT COMMITTING IT.
//
// `ProjectStore.previewClipNotePitchDraft` hands the engine a DRAFT edit set to
// span-render while a drag is still in flight. The draft has to be exactly the
// set the release will store, or the user hears one thing while dragging and
// gets another on release.
//
// ⭐ ONE HOME (m23-ap I1 UI hooks, item 0). I1-F1 wrote this transform beside
// a commit that built the stored set inline (two homes, held together by a
// test). Both commits now CALL it: `setClipNotePitchOffsets` (a group drag,
// `clip.setNotePitches`) and `setClipNotePitchOffset` (a one-note drag,
// `clip.setNotePitch`), in `ProjectStore+PitchNoteEdits.swift`. So the clamp,
// the fold of a repeated id and the refusals exist once, here.
//
// `ClipNoteSpanAuditionTests`' agreement test STAYS: for every input the draft
// equals what each commit stores, and a refused commit is a refused draft. It
// is now the guard against a SECOND home coming back — an inline copy in a
// commit with a different clamp turns it red (planted and shown red when this
// became one home).

extension PitchEditSet {

    /// This set with each named note's `pitchOffsetCents` set to its offset
    /// (ABSOLUTE cents from the note's detected centre, the commit's number),
    /// exactly as `ProjectStore.setClipNotePitchOffsets` would store it:
    ///  * each offset is made finite (NaN and ±∞ read as 0) and clamped to
    ///    `NoteSegment.pitchOffsetCentsRange` (±2400 c) BEFORE anything else,
    ///    so "the same offset twice" is judged on what would be written;
    ///  * a repeated id with the same clamped offset is folded; with two
    ///    different offsets it is refused in words;
    ///  * an unknown id is refused, naming how many notes the set carries;
    ///  * an empty list is refused.
    /// All or nothing: a refusal returns no set. `clipId` only words the
    /// refusals.
    public func applyingNotePitchOffsets(_ offsets: [NotePitchOffset],
                                         clipId: UUID) throws -> PitchEditSet {
        guard !offsets.isEmpty else {
            throw ProjectError.invalidClipEdit(
                "Name at least one note to tune. Read the clip's note ids with "
                    + "`clip.getPitchEdits` first.")
        }
        var table = self
        var resolved: [(index: Int, cents: Double)] = []
        var named: [UUID: Double] = [:]
        for offset in offsets {
            let cents = PitchCorrectionMath.finite(offset.offsetCents, default: 0)
                .clamped(to: NoteSegment.pitchOffsetCentsRange)
            if let earlier = named[offset.segmentId] {
                guard earlier == cents else {
                    throw ProjectError.invalidClipEdit(
                        "Note \(offset.segmentId) is named twice with two different pitches "
                            + "(\(earlier) and \(cents) cents). Name each note once.")
                }
                continue
            }
            named[offset.segmentId] = cents
            guard let index = table.segments.firstIndex(where: { $0.id == offset.segmentId }) else {
                throw ProjectError.invalidClipEdit(
                    "No note with id \(offset.segmentId) on clip \(clipId). That clip carries "
                        + "\(table.segments.count) note(s); read them back with "
                        + "`clip.getPitchEdits` before editing one.")
            }
            resolved.append((index, cents))
        }
        for entry in resolved {
            table.segments[entry.index].pitchOffsetCents = entry.cents
        }
        // Natural tuning D4-1 (b), the user's ruling of 2026-09-26: a pitch
        // drag is a HAND edit, so on a vocal tuned before natural tuning it
        // updates the whole vocal; a drag that ends where it started changes
        // no note and updates nothing (the no-op rule). Here, in the one
        // home, so the drag's draft (`previewClipNotePitchDraft`) plays the
        // SAME set both commits store.
        return table.afterHandEdit(from: self)
    }
}

// MARK: - Natural tuning §4: the slide transforms (NT-C C4)
//
// The same ONE-HOME rule as `applyingNotePitchOffsets`, for the joins: the
// store's commit (`ProjectStore.setClipNoteTransition` /
// `setClipNoteGlideFollow` / `setClipPitchTransitionSmoothness`) and any draft
// (the pitch editor's rear-edge drag, NT-U2) call THESE, so what a drag draws
// and plays is what its release stores. The curve does the rest: every width
// the set carries is read through `PitchEditSet.softJoin`, so a draft built
// here draws its line through the same `make` the render uses.

/// The refusal sentences of the three slide verbs, ONE home. The wire lane
/// (NT-W) echoes them verbatim.
public enum PitchTransitionSentences {
    /// A slide width that is not 0/null (Auto) or a positive number of ms.
    public static func widthNotANumber(_ value: Double) -> String {
        "The slide width has to be 0 or null (Auto), or a number of milliseconds from "
            + "30 to 1000; \(value) is not one. Nothing was changed."
    }

    /// A SOUND named as the left note of a slide.
    public static func soundHasNoSlide(_ segmentId: UUID) -> String {
        "Note \(segmentId) is a sound with no sung pitch (a breath or a consonant), so it "
            + "has no slide into the next note to shape. Nothing was changed. Name a sung note."
    }

    /// The last sung note: nothing after it to slide into.
    public static func lastNoteHasNoSlide(_ segmentId: UUID) -> String {
        "Note \(segmentId) is the last sung note on this clip, so there is no next note for "
            + "it to slide into. Nothing was changed. Name the note on the LEFT of the slide "
            + "you want to shape."
    }

    /// A note whose right edge faces a gap (R15 `.gap`).
    public static func gapHasNoSlide(_ segmentId: UUID) -> String {
        "Note \(segmentId) is followed by a gap (a silence, a breath or a consonant) before "
            + "the next sung note, so there is no slide between them to shape. Nothing was "
            + "changed."
    }

    /// A smoothness of exactly 0: legacy is Undo's job, never a setting (§4.e).
    public static let smoothnessZero =
        "The slide smoothness has to be a speed from 500 to 20000 cents per second, or null "
        + "for the default (3000). 0 is not a setting: to go back to how this vocal slid "
        + "before, use Undo. Nothing was changed."

    /// A smoothness that is negative or not a number.
    public static func smoothnessNotANumber(_ value: Double) -> String {
        "The slide smoothness has to be a speed from 500 to 20000 cents per second, or null "
            + "for the default (3000); \(value) is not one. Nothing was changed."
    }

    /// A follow amount that is not a number.
    public static func followNotANumber(_ value: Double) -> String {
        "The follow amount has to be a number from 0 (the slide keeps its own pitch) to 1 "
            + "(it follows the notes on both sides fully); \(value) is not one. Nothing was "
            + "changed."
    }

    /// A SOUND named to follow its neighbours.
    public static func soundCannotFollow(_ segmentId: UUID) -> String {
        "Note \(segmentId) is a sound with no sung pitch (a breath or a consonant), so it "
            + "cannot follow the notes beside it like a sung slide. Nothing was changed. Name "
            + "a sung note."
    }

    /// A follow asked of a note joined to no curve note on either side.
    public static func nothingToFollow(_ segmentId: UUID) -> String {
        "Note \(segmentId) meets no sung note on either side (there is a gap before it and "
            + "after it), so there is nothing for it to follow. Nothing was changed. Name a "
            + "slide that sits between two notes."
    }
}

extension PitchEditSet {

    /// This set with the join to the RIGHT of `segmentId` given a width,
    /// exactly as `ProjectStore.setClipNoteTransition` stores it (§4.e):
    ///  * nil or 0 = Auto (`transitionOutMs` 0); a positive width is clamped
    ///    to `NoteSegment.transitionOutMsRange` (30...1000 ms of the ORIGINAL
    ///    take). The note-length clamp is NOT stored: the curve applies it
    ///    (`softJoin`), and `joinReading(afterSegmentAt:)` reports what
    ///    applies, so a later split or retime cannot leave a stale clamp;
    ///  * refused in words: a negative or non-finite width, an unknown note
    ///    (naming the count), a SOUND, the LAST curve note, and a note whose
    ///    right edge faces a GAP (R15);
    ///  * writes that one field and nothing else, then
    ///    `afterHandEdit(from: self)`.
    /// On a LEGACY set (`predatesNaturalTuning`) a width that changes the
    /// note also updates the whole vocal (D4-1 (b), the user's ruling of
    /// 2026-09-26): every join takes the default slope, not only this one.
    /// The width it already has changes nothing, so it updates nothing.
    public func applyingNoteTransition(segmentId: UUID, widthMs: Double?,
                                       clipId: UUID) throws -> PitchEditSet {
        let width = widthMs ?? 0
        guard width.isFinite, width >= 0 else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.widthNotANumber(width))
        }
        let index = try Self.transitionIndex(of: segmentId, in: self, clipId: clipId)
        guard segments[index].origin != .unpitched else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.soundHasNoSlide(segmentId))
        }
        guard let next = nextCurveNoteIndex(after: index) else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.lastNoteHasNoSlide(segmentId))
        }
        guard joinKind(between: index, and: next) == .soft else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.gapHasNoSlide(segmentId))
        }
        var table = self
        table.segments[index].transitionOutMs = width > 0
            ? width.clamped(to: NoteSegment.transitionOutMsRange) : 0
        return table.afterHandEdit(from: self)
    }

    /// This set with `segmentId`'s follow amount set, exactly as
    /// `ProjectStore.setClipNoteGlideFollow` stores it (§4.e
    /// `clip.setNoteGlideFollow`): 0 = the slide keeps its own pitch, 1 =
    /// it tilts from the previous note's offset to the next one's.
    ///  * a finite amount is clamped to `NoteSegment.glideFollowRange`;
    ///  * refused in words: a non-finite amount, an unknown note, a SOUND,
    ///    and an amount above 0 on a note joined to no curve note on either
    ///    side (the write would take and do nothing). 0 is always allowed;
    ///  * any sung note may follow, not only a `.transition` part: an agent
    ///    marks the slides of a preset-built table this way (the preset seed
    ///    never does, (a-T)), and `origin` tells it which ones are slides;
    ///  * writes that one field and nothing else, then
    ///    `afterHandEdit(from: self)` (a follow already at that amount
    ///    changes nothing, so it updates nothing).
    public func applyingNoteGlideFollow(segmentId: UUID, amount: Double,
                                        clipId: UUID) throws -> PitchEditSet {
        guard amount.isFinite else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.followNotANumber(amount))
        }
        let index = try Self.transitionIndex(of: segmentId, in: self, clipId: clipId)
        guard segments[index].origin != .unpitched else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.soundCannotFollow(segmentId))
        }
        let clamped = amount.clamped(to: NoteSegment.glideFollowRange)
        if clamped > 0 {
            let before = previousCurveNoteIndex(before: index)
                .map { joinKind(between: $0, and: index) == .soft } ?? false
            let after = nextCurveNoteIndex(after: index)
                .map { joinKind(between: index, and: $0) == .soft } ?? false
            guard before || after else {
                throw ProjectError.invalidClipEdit(PitchTransitionSentences.nothingToFollow(segmentId))
            }
        }
        var table = self
        table.segments[index].glideFollow = clamped
        return table.afterHandEdit(from: self)
    }

    /// This set with its slide smoothness set, exactly as
    /// `ProjectStore.setClipPitchTransitionSmoothness` stores it (§4.e):
    /// nil = `defaultTransitionSlope`; a positive value is clamped to
    /// `transitionSlopeRange`; 0, a negative value and a non-finite one are
    /// refused in words (going back to legacy is Undo's job, not a setting).
    /// An explicit request, so on a LEGACY set it upgrades THIS field alone
    /// (§4.j, X4), regardless of D4-1: it is a set-level switch, not a hand
    /// edit, and never calls `afterHandEdit()`. Nothing else moves.
    public func applyingTransitionSmoothness(centsPerSecond: Double?) throws -> PitchEditSet {
        let slope = centsPerSecond ?? Self.defaultTransitionSlope
        guard slope != 0 else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.smoothnessZero)
        }
        guard slope.isFinite, slope > 0 else {
            throw ProjectError.invalidClipEdit(PitchTransitionSentences.smoothnessNotANumber(slope))
        }
        var table = self
        table.transitionSlopeCentsPerSecond = slope.clamped(to: Self.transitionSlopeRange)
        return table
    }

    /// The note's index, or the per-note setters' unknown-note refusal in the
    /// same words (`ProjectStore`'s `segmentIndex`, `applyingNotePitchOffsets`).
    private static func transitionIndex(of segmentId: UUID, in set: PitchEditSet,
                                        clipId: UUID) throws -> Int {
        guard let index = set.segments.firstIndex(where: { $0.id == segmentId }) else {
            throw ProjectError.invalidClipEdit(
                "No note with id \(segmentId) on clip \(clipId). That clip carries "
                    + "\(set.segments.count) note(s); read them back with "
                    + "`clip.getPitchEdits` before editing one.")
        }
        return index
    }
}
