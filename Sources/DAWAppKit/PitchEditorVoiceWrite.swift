import Foundation
import DAWCore

// W7-NTU U3 — THE VOICE TOOL'S ONE WAY INTO THE STORE.
//
// Design: `docs/design/2026-09-25-natural-tuning.md` §1(f) items 2-3 (the Voice
// drag, its double-click, the note menu's Voice row) and D4-1 (b), the user's
// ruling that the FIRST hand edit on an old vocal updates the whole vocal.
//
// ⭐ **WHY THIS IS HERE AND NOT IN THE APP LAYER** — `PitchEditorWobbleWrite`'s
// reason, unchanged: `PitchCorrectionStaging` (DAWApp) is the app's commit
// funnel, and DAWApp has no test target. A test that mirrored its store call
// would prove the MIRROR. So the write and its read-back live in ONE function,
// here, that the funnel calls and `PitchEditorModelTests` calls.
//
// ⛔ **THE READ-BACK READS THE STORE, NEVER THE SETTER'S RETURN**
// (`PitchEditorSingerWrite`'s rule): the clip is looked up in `store.tracks`
// AFTER the write and compared, WHOLE, with an expectation built from what was
// SENT and from the set as it was BEFORE.

/// The Voice tool's commit kind, written to the store and read back.
@MainActor
public enum PitchEditorVoiceWrite {

    /// Writes `kind` if it is a Voice commit, and reads it back.
    ///
    /// `.noteFormant`: ONE `ProjectStore.setClipNoteFormant` call for every
    /// note it names, so a drag, a double-click and a menu row over a
    /// selection are each ONE undo step ("Set Note Voice", `structuralKey`).
    ///
    /// Returns `nil` for any other kind (not this function's), `true` when the
    /// write TOOK (`took`), and `false` when the store accepted it and does not
    /// hold it. Throws the store's refusal, in its words.
    public static func commit(_ kind: PitchEditorCommit.Kind, clipID: UUID,
                              seedIfAbsent: PitchEditSet?, to store: ProjectStore) throws -> Bool? {
        guard case .noteFormant(let segmentIDs, let semitones) = kind else { return nil }
        // The set the store will edit: its own table, or the seed it is handed
        // when the clip has none (`ProjectStore.noteTable(...seedIfAbsent:)`).
        let before = PitchEditorSingerWrite.storedTable(clipID, in: store) ?? seedIfAbsent
        _ = try store.setClipNoteFormant(clipId: clipID, segmentIds: segmentIDs,
                                         semitones: semitones, seedIfAbsent: seedIfAbsent)
        return took(before: before, segmentIDs: segmentIDs, semitones: semitones,
                    stored: PitchEditorSingerWrite.storedTable(clipID, in: store))
    }

    /// ⛔ **THE INDEPENDENT READ-BACK.** The stored set must be EXACTLY the set
    /// from `before`, with every named note's Voice at the value SENT (through
    /// the store's one clamp, ±24, a non-finite value read as 0), then passed
    /// through D4-1's one home, `afterHandEdit(from:)`. So the expectation
    /// carries all of it:
    ///  * an old vocal's first changing Voice edit updates the whole vocal (the
    ///    user's ruling (b)), in the same step;
    ///  * a consonant OFF somebody chose is kept through that update
    ///    (NT-C2-F1), and a picked slide smoothness too;
    ///  * nothing else moves.
    /// The WHOLE set is compared, never one field: a store that also moved a
    /// pitch, skipped the update or switched the chosen OFF back on reads NO.
    /// A named note that is not in `before`, an empty list and a missing table
    /// are writes that did not take.
    public nonisolated static func took(before: PitchEditSet?, segmentIDs: [UUID],
                                        semitones: Double, stored: PitchEditSet?) -> Bool {
        guard let before, !before.isEmpty, let stored, !segmentIDs.isEmpty else { return false }
        let value = PitchCorrectionMath.finite(semitones, default: 0)
            .clamped(to: NoteSegment.formantOffsetSemitonesRange)
        let named = Set(segmentIDs)
        var expected = before
        var found = Set<UUID>()
        for index in expected.segments.indices where named.contains(expected.segments[index].id) {
            expected.segments[index].formantOffsetSemitones = value
            found.insert(expected.segments[index].id)
        }
        guard found == named else { return false }
        return stored == expected.afterHandEdit(from: before)
    }
}
