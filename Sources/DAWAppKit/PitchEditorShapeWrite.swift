import Foundation
import DAWCore

// m23-ap C5b-4b — THE FREEHAND BRUSH'S ONE WAY INTO THE STORE.
//
// Design: `docs/design/2026-09-24-pitch-editor-timing-and-freehand.md` §5.3
// ("commit on release": one stroke is ONE `setClipNoteShapes` call, ONE undo
// step) and §5.5 (the note menu's "Reset drawn shape").
//
// ⭐ **WHY THIS IS HERE AND NOT IN THE APP LAYER** — `PitchEditorWobbleWrite`'s
// reason, unchanged: `PitchCorrectionStaging` (DAWApp) is the app's commit
// funnel and DAWApp has no test target. A test that mirrored its store call
// would prove the MIRROR is one undo step, and a staging arm that wrote each
// note on its own (N undo steps for one stroke) would pass it. So the write and
// its read-back live in ONE function, in DAWAppKit, that the funnel calls and
// `PitchEditorModelTests` calls: a defect planted here turns the suite red.

/// The brush's commit kind (and the note menu's reset), written to the store
/// and read back.
@MainActor
public enum PitchEditorShapeWrite {

    /// Writes `kind` if it is a shape commit and reads it back.
    ///
    /// - `.noteShapes`: EVERY note the stroke drew on (or the menu reset) in ONE
    ///   `ProjectStore.setClipNoteShapes` call — one journal entry, "Draw Pitch"
    ///   or "Reset Drawn Shape", under `structuralKey` (a stroke is a deliberate
    ///   act and never folds into the one before it), and one
    ///   `tracksDidChange`.
    ///
    /// Returns `nil` for any other kind (not this function's), `true` when the
    /// write TOOK (`took`), `false` when the store accepted it and the table
    /// does not hold it. Throws the store's refusal, in its words.
    public static func commit(_ kind: PitchEditorCommit.Kind, clipID: UUID,
                              seedIfAbsent: PitchEditSet?, to store: ProjectStore) throws -> Bool? {
        guard case .noteShapes(let shapes) = kind else { return nil }
        let clip = try store.setClipNoteShapes(clipId: clipID, shapes: shapes,
                                               seedIfAbsent: seedIfAbsent)
        return took(clip: clip, shapes: shapes)
    }

    /// ⛔ **THE INDEPENDENT READ-BACK**: did a shape write TAKE? Every named
    /// note's STORED drawing must equal what was SENT, normalised for that
    /// stored note (`NoteShapeSamples.normalised(for:)`: trimmed to the note,
    /// zero-filled, clamped, an all-zero write stored as a clear). The rule is
    /// run here on the write, never read off the setter's return, which would
    /// check the store against itself. An empty map and a missing note are
    /// writes that did not take.
    public nonisolated static func took(clip: Clip, shapes: [UUID: NoteShapeSamples]) -> Bool {
        var stored: [UUID: NoteSegment] = [:]
        for segment in clip.pitchEdits?.segments ?? [] {
            stored[segment.id] = segment
        }
        return !shapes.isEmpty && shapes.allSatisfy { id, write in
            guard let note = stored[id] else { return false }
            return NoteShapeSamples(storedIn: note) == write.normalised(for: note)
        }
    }
}
