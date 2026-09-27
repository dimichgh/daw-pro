import Foundation
import DAWCore

// m23-ap C5a-4b — THE GENERALISED DRAFT (design
// `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §16 "Shared shapes:
// build each once", V4).
//
// ⭐ **ONE DRAFT PATH FOR EVERY TOOL.** `PitchEditorModel.rebuildDraftLine` (and
// the Wobble tool's handoff read) hand the note table and every changing note to
// `PitchEditorDraftEdit.draftSet`, then run the result through
// `PitchPlayedLine.make` — the render's own function. They never set a field
// themselves. So a pitch drag, a wobble drag and whatever comes next (C2-5's
// `.timing`, C5b's `.shape`) draw their live line through the SAME
// transform-then-make, and "the line during the drag is the line the release
// plays" has one home instead of one per tool.
//
// ⭐⭐ **EACH CASE RUNS THE VERY SET TRANSFORM ITS COMMIT RUNS — NOT A COPY OF
// IT.** That is the whole contract:
//  * `.pitch` → `PitchEditSet.applyingNotePitchOffsets`, the transform both
//    pitch commits run (`setClipNotePitchOffset(s)`): the same clamp, and
//    `afterHandEdit(from:)` LAST (D4-1's hook with its no-op rule: an edit
//    that changed no note upgrades nothing).
//  * `.wobble` → `PitchEditSet.applyingNoteVibratos`, the transform both wobble
//    setters run (`setClipNoteVibrato` / `setClipNotesVibrato`): the one clamp
//    at the clip's ratio, `NoteVibratoClamp.applied`.
//  * `.shape` (C5b-4b, the freehand brush) → `PitchEditSet.applyingNoteShapes`,
//    the transform `setClipNoteShapes` runs: trim, zero-fill, clamp, normalise,
//    the sound refusal, then `afterHandEdit(from:)` LAST. Every note one stroke
//    touched goes through ONE call, so the draft is the one set the release's
//    one store call writes (all or nothing, as the store is).
// ⛔ WHY THE SET TRANSFORM AND NOT A PER-NOTE FIELD WRITE (natural tuning
// D4-1, the user's Q-U1 = (b), 2026-09-26): a hand edit that CHANGES a note
// on a vocal that `predatesNaturalTuning` upgrades the WHOLE set
// (`afterHandEdit(from:)`, whose no-op rule leaves an edit that changed
// nothing un-upgraded), which is a set-level change no per-note write can
// reproduce. A draft that wrote only
// the note's fields would draw the old rule during the drag and play the new
// one after the release, the day `handEditUpgradesLegacyVocal` is true — and
// whether a wobble edit upgrades is `applyingNoteVibratos`' call to make, in
// DAWCore; routing through it means the draft follows whatever it decides.
// `.wobble` carries the clip's stretch ratio because that transform needs it.
//
// A transform that REFUSES (it cannot for a live gesture: every id is a drawn
// note and every value already went through the same clamp) leaves the table
// as it was, which is exactly what the store holds after a refused commit.
//
// FOR C5b AND C2-5: add a case, and a branch in `draftSet` that calls the SET
// transform your release's store setter calls (C5b-1's shapes transform; for
// timing, the one `setClipNoteTiming` will call). Never write a draft field
// yourself, and never branch `rebuildDraftLine` on the tool: build a list of
// `(segmentID, PitchEditorDraftEdit)` and let `draftSet` do the writing.

/// One note's live, UNCOMMITTED edit, as the draft line draws it.
public enum PitchEditorDraftEdit: Sendable, Equatable {
    /// C1 — the note's pitch offset, cents, STORED space, already snapped and
    /// clamped by the drag (`PitchEditorDragDraft.offsetCents`).
    case pitch(offsetCents: Double)
    /// C5a — the note's six wobble fields, at the clip's `stretchRatio` (the
    /// clamp's heard-rate ceiling depends on it).
    case wobble(NoteVibratoEdit, stretchRatio: Double)
    /// C5b — the note's WHOLE new drawing (`PitchShapeStroke.commit()`'s value
    /// for it), not a patch: exactly what the release hands `setClipNoteShapes`.
    case shape(NoteShapeSamples)

    /// ⭐ **THE ONE DRAFT PATH.** `table` with every edit applied through the
    /// SAME DAWCore set transform its commit runs (see the banner), so the draft
    /// set IS the set the release stores — `afterHandEdit(from:)` and all.
    ///
    /// - `clipID` only words a refusal the live draft never reaches.
    /// - Pitch, wobble and shape edits never share one gesture; all three are
    ///   accepted anyway, in that order, each kind through ONE call of its own
    ///   transform.
    public static func draftSet(_ table: PitchEditSet,
                                applying edits: [(segmentID: UUID, edit: PitchEditorDraftEdit)],
                                clipID: UUID) -> PitchEditSet {
        var set = table
        var offsets: [NotePitchOffset] = []
        var wobbles: [NoteVibratoItem] = []
        var shapes: [UUID: NoteShapeSamples] = [:]
        var ratio = 1.0
        for entry in edits {
            switch entry.edit {
            case .pitch(let offsetCents):
                offsets.append(NotePitchOffset(segmentId: entry.segmentID, offsetCents: offsetCents))
            case .wobble(let edit, let stretchRatio):
                wobbles.append(NoteVibratoItem(segmentId: entry.segmentID, edit: edit))
                ratio = stretchRatio
            case .shape(let samples):
                shapes[entry.segmentID] = samples
            }
        }
        if !offsets.isEmpty, let next = try? set.applyingNotePitchOffsets(offsets, clipId: clipID) {
            set = next
        }
        if !wobbles.isEmpty,
           let next = try? set.applyingNoteVibratos(wobbles, stretchRatio: ratio, clipId: clipID) {
            set = next.set
        }
        if !shapes.isEmpty, let next = try? set.applyingNoteShapes(shapes, clipId: clipID) {
            set = next
        }
        return set
    }
}
