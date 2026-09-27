import Foundation

// UE-2 — HOW A SOUND WITH NO PITCH LOOKS in the note editor, as a decision the
// surface READS rather than re-derives. Design
// `docs/design/2026-09-24-unpitched-notes-presets-midi-targets.md` §1.9 (Melodyne
// shows them "displayed hatched") and §1.10 (U-E: "sounds drawn hatched and faint
// at their anchor"; F-many: "a take just above the guard floods the view, so
// sounds draw faint").
//
// ⭐ **ONE PREDICATE HOME FOR THE LOOK.** `DAWApp` has no test target, so a look
// decided inside the Canvas is testable by nothing but a grep. The Canvas
// switches on `NoteBlob.look`; the precedence (a CLEARED sound draws cleared) is
// pinned here, headless, and `debug.pitchEditor` echoes the same value per drawn
// note, so a staging gate reads the look the surface was handed.
//
// Pure: no store, no view, no model.

/// Which of the surface's three blob looks a note is drawn in.
public enum PitchEditorBlobLook: String, Sendable, Equatable, CaseIterable {
    /// A sung note: an opaque plate whose wash encodes confidence (voicing,
    /// never accuracy), `signal` once its pitch is edited.
    case note
    /// A SOUND with no detected pitch (`NoteOrigin.unpitched`): hatched and
    /// faint at its borrowed anchor, at a FIXED strength, never the confidence
    /// wash. Its ~0.59 median confidence would otherwise draw it as a
    /// middling note, which is the one thing it is not.
    case sound
    /// Silenced in place (`NoteSegment.isCleared`): hollow and dashed.
    case cleared
}

extension NoteBlob {
    /// The look this blob is drawn in. ⚠️ **CLEARED IS ASKED FIRST**, for the
    /// reason `hasEdits`' doc gives for the tuned accent: a cleared blob plays
    /// silence, and a hatch drawn over a hollow box would read as "something
    /// is still here". A cleared sound therefore looks like any cleared note;
    /// the selection line and the menu ("Restore Sound") still name it.
    public var look: PitchEditorBlobLook {
        if isCleared { return .cleared }
        return isUnpitched ? .sound : .note
    }
}

/// The words that go with the sound look.
public enum PitchEditorSoundLook {

    /// The header's legend when the surface draws notes and no sound: the
    /// confidence encoding, in a person's words (§5.5.4: voicing, not accuracy).
    public static let notesLegend = "Fainter notes mean we are less sure you were singing there."

    /// What the stripes mean, said once in the header rather than on every
    /// sound: a dense take has dozens, and a word over each one is the
    /// flood F-many warns about.
    public static let soundsLegend = "Striped boxes are sounds with no pitch, like a breath or an \"s\"."

    /// The legend the header draws: nothing when no notes are drawn, the
    /// confidence line, and the stripes line only while at least one SOUND is
    /// drawn (a legend for a mark that is not on screen explains nothing).
    public static func legend(drawsNotes: Bool, drawsSounds: Bool) -> String {
        guard drawsNotes else { return "" }
        return drawsSounds ? notesLegend + " " + soundsLegend : notesLegend
    }
}
