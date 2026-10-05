import Foundation
import DAWCore

// W7-NTU (natural tuning `docs/design/2026-09-25-natural-tuning.md` §1(f)
// item 4, wording R26) — THE FAR-MOVE HINT: after a pitch drag that leaves a
// note 3 semitones or more from where it was sung, on a vocal that keeps less
// than half of its voice size, one line of prose says what to turn up.
//
// ⭐ **PRESENTATION ONLY.** Nothing here writes, and nothing on the wire
// reports it: the `farMoves` report (unpitched design §3.3) is still owed to
// the wire and belongs to §4/§2, which this does not claim.
//
// ⭐ **READ FROM THE TABLE AS IT IS NOW, NEVER FROM THE DRAG.** The model keeps
// only WHICH notes the last pitch drag moved (`PitchEditorModel
// .farMoveNoteIDs`); how far each one sits, and how much voice size the vocal
// keeps, are read from the stored table every time the hint is asked. So the
// hint appears once the store holds the move, and goes by itself when the move
// is undone or the amount is turned up. And a vocal tuned before this update
// is updated by its first note change (ruling (b), `PitchEditSet
// .afterHandEdit(from:)`), to 100 %, so a move on one of those never shows it:
// the amount it would ask for is already in force.

/// The far-move hint's rule (§1(f) item 4).
public enum PitchEditorFarMoveHint {

    /// "3+ semitones" (the paste's rule): a note this far from where it was
    /// sung, or farther, is a far move. Inclusive.
    public static let farMoveCents = 300.0

    /// The amount of voice size kept below which the hint shows: "the set's
    /// effective correction is < 0.5". Exclusive: at exactly half, no hint.
    public static let keepBelow = 0.5

    /// The voice size the render keeps for `table` on a clip whose
    /// whole-clip "keeps voice" flag is `formantPreserve`: the set's own
    /// amount, or, on a vocal with none (tuned before this update), the
    /// clip flag's 1 or 0. The render's own rule
    /// (`PitchCorrectionCurve.formantSemitones`, `c = formantCorrection ??
    /// (formantPreserve ? 1 : 0)`). A non-finite amount reads as none.
    public static func effectiveKeep(_ table: PitchEditSet, formantPreserve: Bool) -> Double {
        if let amount = table.formantCorrection, amount.isFinite { return amount }
        return formantPreserve ? 1 : 0
    }

    /// The hint's words, or nil. `movedNoteIDs` are the notes the last pitch
    /// drag committed; each is looked up in `table` (the stored table, NOW).
    /// nil when no moved note is a far move, or the vocal keeps half its voice
    /// size or more.
    public static func line(movedNoteIDs: [UUID], table: PitchEditSet,
                            formantPreserve: Bool) -> String? {
        guard !movedNoteIDs.isEmpty,
              effectiveKeep(table, formantPreserve: formantPreserve) < keepBelow
        else { return nil }
        let moved = Set(movedNoteIDs)
        let far = table.segments.contains {
            moved.contains($0.id) && abs($0.pitchOffsetCents) >= farMoveCents
        }
        return far ? PitchEditorFormantCopy.farMoveHint : nil
    }
}
