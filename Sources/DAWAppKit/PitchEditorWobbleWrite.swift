import Foundation
import DAWCore

// m23-ap C5a-4b — THE WOBBLE TOOL'S ONE WAY INTO THE STORE.
//
// Design: `docs/design/2026-09-24-pitch-editor-vibrato-handle.md` §10 ("the
// UI's commit", the independent read-back) and unpitched design §4 (T-dot-4:
// dot clicks on one note inside the journal's 800 ms window are ONE undo step).
//
// ⭐ **WHY THIS IS HERE AND NOT IN THE APP LAYER.** `PitchCorrectionStaging`
// (DAWApp) is the app's commit funnel, and DAWApp has no test target. A test
// that mirrored its store call would prove the MIRROR folds, and a staging arm
// that picked the wrong setter (a batch write under `structuralKey`, which never
// coalesces) would pass it. So the write and its read-back live in ONE
// function, in DAWAppKit, that the funnel calls and `PitchEditorModelTests`
// calls — a defect planted here turns T-dot-4 red.

/// The Wobble tool's two commit kinds, written to the store and read back.
@MainActor
public enum PitchEditorWobbleWrite {

    /// Writes `kind` if it is a wobble commit and reads it back.
    ///
    /// - `.noteVibrato`: ONE note, `ProjectStore.setClipNoteVibrato` — keyed on
    ///   `PitchCorrectionUndoKey.vibrato(clipID:segmentID:)`, so a second write
    ///   to the same note inside 800 ms folds into the first undo step.
    /// - `.noteVibratoReset`: "Back to how you sang it". One note is the store's
    ///   own reset (`resetClipNoteVibrato`, "Reset Wobble"); several are ONE
    ///   batch write of `NoteVibratoEdit.asSung` under `structuralKey`, so a
    ///   selection is one undo step, never N.
    ///
    /// Returns `nil` for any other kind (not this function's), `true` when the
    /// write TOOK (`took`), `false` when the store accepted it and the table
    /// does not hold it. Throws the store's refusal, in its words.
    public static func commit(_ kind: PitchEditorCommit.Kind, clipID: UUID,
                              seedIfAbsent: PitchEditSet?, to store: ProjectStore) throws -> Bool? {
        switch kind {
        case .noteVibrato(let segmentID, let edit):
            let result = try store.setClipNoteVibrato(clipId: clipID, segmentId: segmentID,
                                                      edit: edit, seedIfAbsent: seedIfAbsent)
            return took(clip: result.clip, segmentIDs: [segmentID], edit: edit)
        case .noteVibratoReset(let segmentIDs):
            let clip: Clip
            if segmentIDs.count == 1, let only = segmentIDs.first {
                clip = try store.resetClipNoteVibrato(clipId: clipID, segmentId: only,
                                                      seedIfAbsent: seedIfAbsent).clip
            } else {
                clip = try store.setClipNotesVibrato(
                    clipId: clipID,
                    edits: segmentIDs.map { NoteVibratoItem(segmentId: $0, edit: .asSung) },
                    seedIfAbsent: seedIfAbsent,
                    undoKey: PitchCorrectionUndoKey.structuralKey).clip
            }
            return took(clip: clip, segmentIDs: segmentIDs, edit: .asSung)
        default:
            return nil
        }
    }

    /// ⛔ **THE INDEPENDENT READ-BACK** (design §10): did a wobble write TAKE?
    /// Every named note's stored fields must equal
    /// `NoteVibratoLimits.clamp(edit, stretchRatio:)` at the clip's OWN ratio —
    /// the one clamp, run here on what was SENT, never the setter's returned
    /// segment (that would check the store against itself and pass a setter
    /// that dropped a field). Field by field where the edit named one (`nil` is
    /// "leave it"). A clamp that throws (a NaN: the store refuses first) and an
    /// empty or missing note are writes that did not take.
    public nonisolated static func took(clip: Clip, segmentIDs: [UUID],
                                        edit: NoteVibratoEdit) -> Bool {
        guard let expected = try? NoteVibratoLimits.clamp(edit, stretchRatio: clip.stretchRatio).edit
        else { return false }
        var stored: [UUID: NoteVibratoEdit] = [:]
        for segment in clip.pitchEdits?.segments ?? [] {
            stored[segment.id] = NoteVibratoEdit(storedIn: segment)
        }
        func same(_ want: Double?, _ got: Double?) -> Bool { want == nil || want == got }
        return !segmentIDs.isEmpty && segmentIDs.allSatisfy { id in
            guard let written = stored[id] else { return false }
            return same(expected.vibratoRateHz, written.vibratoRateHz)
                && same(expected.vibratoDepthCents, written.vibratoDepthCents)
                && same(expected.vibratoOnsetSeconds, written.vibratoOnsetSeconds)
                && same(expected.vibratoPhaseAnchorSeconds, written.vibratoPhaseAnchorSeconds)
                && same(expected.vibratoScale, written.vibratoScale)
                && same(expected.driftScale, written.driftScale)
        }
    }
}
