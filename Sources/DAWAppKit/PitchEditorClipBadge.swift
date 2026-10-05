import DAWCore

// m23-ap I7b-2 — THE NOTE EDITOR HEADER'S ONE CLIP BADGE.
//
// Until I7b-2 the header drew "TUNING APPLIED" on `Clip.hasPitchEdits`, and
// since I7a that predicate is also true for a clip whose ONLY edits clear
// notes or change their level (the level mask is part of it, on purpose: it
// is the wire's answer and it offers Remove Tuning). MEASURED on staging
// (I7b's look): a clip with three cleared notes and not one pitch moved wore
// "TUNING APPLIED" — a sentence a novice believes, about a retune that never
// happened.
//
// ⭐ **ONE SLOT, AT MOST ONE FACE.** `.tuningApplied` when a pitch moved
// (`Clip.hasTuningEdits`), else `.notesEdited` when the clip carries any edit
// (`Clip.hasPitchEdits`), else nothing. Because a moved pitch is itself an
// edit, a badge is drawn EXACTLY when `hasPitchEdits` holds — exactly when
// the pane offers Remove Tuning — so an edited clip is never unmarked and a
// badge never promises an edit Remove Tuning would not find.
//
// The view draws `title` and reports the same value to its spy
// (`PitchEditorChromeLedger`, echoed by `debug.pitchEditor`'s
// `chrome.tuningApplied` / `chrome.notesEdited` / `chrome.clipBadgeText`), so
// the echo can only agree with the screen.

/// The badge the note editor's header draws beside the clip name: what the
/// clip's stored edits AMOUNT TO, in the words a novice reads. Pure.
public enum PitchEditorClipBadge: String, Sendable, Equatable, CaseIterable {
    /// A pitch moved — some note's pitch, shape, formant or timing is edited
    /// (`Clip.hasTuningEdits`). The render has a pitch curve to play.
    case tuningApplied
    /// The clip carries edits and NONE of them moves a pitch: every one clears
    /// a note or changes its level. The take plays at its own pitch.
    case notesEdited

    /// The words drawn, verbatim.
    public var title: String {
        switch self {
        case .tuningApplied: "TUNING APPLIED"
        case .notesEdited: "NOTES EDITED"
        }
    }

    /// The badge for this clip, or nil when it carries no edit.
    public static func resolve(_ clip: Clip) -> PitchEditorClipBadge? {
        if clip.hasTuningEdits { return .tuningApplied }
        if clip.hasPitchEdits { return .notesEdited }
        return nil
    }
}
