import Testing
import Foundation
@testable import DAWCore

/// m26-a / m27-n — `ProjectStore.patchNotes`: BY-ID partial note edit, the
/// missing rung between `clip.getNotes` (read) and `clip.setNotes`
/// (whole-array replace). Built to the `repeatNotes` shape
/// (`ProjectStore+RepeatNotes.swift`) for the same coalescing reason:
/// `setClipNotes` coalesces same-clip edits within 800 ms, and a batch patch
/// must not fold into a neighbouring edit or vice versa.
@MainActor
@Suite("Patch notes (m26-a / m27-n)")
struct PatchNotesTests {

    // MARK: - Helpers

    private func makeStore(
        clipNotes: [MIDINote] = [
            MIDINote(pitch: 60, velocity: 90, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, velocity: 90, startBeat: 1, lengthBeats: 1),
            MIDINote(pitch: 67, velocity: 90, startBeat: 2, lengthBeats: 1),
        ],
        clipLengthBeats: Double = 4
    ) throws -> (store: ProjectStore, track: Track, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0,
                                         lengthBeats: clipLengthBeats, notes: clipNotes)
        return (store, track, clip)
    }

    // MARK: - 1. The coalescing trap — the highest-value tests in this file

    /// ⚠️⚠️ THE TEST THE NAIVE IMPLEMENTATION (`getNotes` -> mutate -> whole-
    /// array `setClipNotes`, OR a `patchNotes` that reuses `setClipNotes`'s
    /// coalescing key) PASSES WITHOUT EVER SEEING THE BUG IT EXISTS TO
    /// CATCH. Verified by planting `key: "clip.notes:\(clipID.uuidString)"`
    /// on `patchNotes`'s own `performEdit` call — see the task report for
    /// the plant-and-redden record.
    @Test("a patch 100 ms after a note edit is its OWN undo step")
    func patchDoesNotCoalesceIntoThePrecedingEdit() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        // A GENUINE change — `performEdit` only journals when the captured
        // state actually differs, so resubmitting the notes unchanged would
        // silently journal NOTHING and make this test vacuous.
        var editedNotes = store.tracks[0].clips[0].notes!
        editedNotes[1].pitch = 65
        try store.setClipNotes(clipID: clip.id, notes: editedNotes)
        let afterEdit = store.journal.undoStack.count
        // WELL INSIDE the 800 ms window — this is the whole point.
        clock = clock.advanced(by: .milliseconds(100))
        let noteID = store.tracks[0].clips[0].notes![0].id
        try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, velocity: 40)])

        #expect(store.journal.undoStack.count == afterEdit + 1)
        #expect(store.undoLabel == "Patch Notes \u{00D7}1")

        // One undo reverses ONLY the patch, leaving the edit standing.
        try store.undo()
        #expect(store.tracks[0].clips[0].notes?.first { $0.id == noteID }?.velocity == 90)
        #expect(store.undoLabel == "Edit Notes")
    }

    /// ⚠️ ANTI-VACUITY CONTROL, for THIS suite's own store/clock (the repeat
    /// suite's control does not cover a different store instance). Same gap,
    /// same clock, two ordinary edits instead of edit-then-patch: reports
    /// ONE entry, proving the window is actually active here.
    @Test("CONTROL: two note EDITS 100 ms apart DO coalesce under this store's clock")
    func setClipNotesStillCoalescesUnderTheSameClock() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        let afterEdit = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(100))
        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 62, startBeat: 1)])

        #expect(store.journal.undoStack.count == afterEdit,
                "coalescing must be ACTIVE here, or the patch test above is vacuous")
    }

    @Test("a note EDIT 100 ms after a patch does not fold into the patch (reverse order)")
    func editAfterPatchIsItsOwnStep() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let noteID = store.tracks[0].clips[0].notes![0].id
        try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, velocity: 40)])
        let afterPatch = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(100))
        // A GENUINE change, same reason as the test above.
        var editedNotes = store.tracks[0].clips[0].notes!
        editedNotes[1].pitch = 65
        try store.setClipNotes(clipID: clip.id, notes: editedNotes)

        #expect(store.journal.undoStack.count == afterPatch + 1)
        #expect(store.undoLabel == "Edit Notes")
    }

    @Test("two rapid patches are two undo steps — patch never folds into patch either")
    func twoRapidPatchesDoNotFold() throws {
        let (store, _, clip) = try makeStore()
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        let noteID = store.tracks[0].clips[0].notes![0].id
        try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, velocity: 40)])
        let afterFirst = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(50))
        try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, velocity: 20)])

        #expect(store.journal.undoStack.count == afterFirst + 1)
    }

    // MARK: - 2. One undo restores every patched note together

    @Test("one undo restores ALL notes a batch patch touched, together")
    func undoRestoresEveryPatchedNoteTogether() throws {
        let (store, _, clip) = try makeStore()
        let originalNotes = store.tracks[0].clips[0].notes!
        let ids = originalNotes.map(\.id)

        try store.patchNotes(clipID: clip.id, update: ids.map { NotePatch(id: $0, velocity: 111) })
        #expect(store.tracks[0].clips[0].notes!.allSatisfy { $0.velocity == 111 })

        try store.undo()
        #expect(store.tracks[0].clips[0].notes == originalNotes)
    }

    // MARK: - 3. Field-by-field apply

    @Test("patching one field leaves the other three exactly as they were")
    func patchingOneFieldLeavesOthersUntouched() throws {
        let (store, _, clip) = try makeStore()
        let original = store.tracks[0].clips[0].notes![0]

        try store.patchNotes(clipID: clip.id, update: [NotePatch(id: original.id, pitch: 72)])
        let patched = store.tracks[0].clips[0].notes!.first { $0.id == original.id }!

        #expect(patched.pitch == 72)
        #expect(patched.velocity == original.velocity)
        #expect(patched.startBeat == original.startBeat)
        #expect(patched.lengthBeats == original.lengthBeats)
    }

    @Test("patching all four fields at once on multiple notes")
    func patchingAllFieldsOnMultipleNotes() throws {
        let (store, _, clip) = try makeStore()
        let notes = store.tracks[0].clips[0].notes!
        let report = try store.patchNotes(clipID: clip.id, update: [
            NotePatch(id: notes[0].id, pitch: 48, velocity: 30, startBeat: 0.5, lengthBeats: 0.25),
            NotePatch(id: notes[1].id, pitch: 50, velocity: 31, startBeat: 1.5, lengthBeats: 0.25),
        ])

        #expect(report.updated == 2)
        #expect(report.totalNotes == 3)
        let byID = Dictionary(uniqueKeysWithValues: store.tracks[0].clips[0].notes!.map { ($0.id, $0) })
        #expect(byID[notes[0].id]?.pitch == 48)
        #expect(byID[notes[0].id]?.velocity == 30)
        #expect(byID[notes[0].id]?.startBeat == 0.5)
        #expect(byID[notes[0].id]?.lengthBeats == 0.25)
        #expect(byID[notes[1].id]?.pitch == 50)
        // The untouched third note is byte-identical.
        #expect(byID[notes[2].id] == notes[2])
    }

    @Test("out-of-range fields are re-clamped through MIDINote's own init, belt-and-braces with the wire's teaching errors")
    func outOfRangeFieldsAreClamped() throws {
        let (store, _, clip) = try makeStore()
        let noteID = store.tracks[0].clips[0].notes![0].id
        try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, pitch: 999, velocity: 0)])
        let patched = store.tracks[0].clips[0].notes!.first { $0.id == noteID }!
        #expect(patched.pitch == 127)
        #expect(patched.velocity == 1)
    }

    // MARK: - 4. Response shape

    @Test("report totalNotes and updated count are correct and stable across a pure field edit")
    func reportCounts() throws {
        let (store, _, clip) = try makeStore()
        let noteID = store.tracks[0].clips[0].notes![0].id
        let report = try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, velocity: 77)])
        #expect(report.clipID == clip.id)
        #expect(report.updated == 1)
        #expect(report.totalNotes == 3, "patchNotes never adds or removes a note")
        #expect(report.latentNotesPastClipEnd == 0)
    }

    @Test("latentNotesPastClipEnd reports a patched startBeat landing past the clip end — no auto-extend")
    func latentNotesPastClipEndReported() throws {
        let (store, _, clip) = try makeStore(clipLengthBeats: 4)
        let noteID = store.tracks[0].clips[0].notes![0].id
        let report = try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, startBeat: 10)])
        #expect(report.latentNotesPastClipEnd == 1)
        // The clip did NOT grow — the whole point of "no auto-extend".
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
        // The note is still there — legal but latent (m18-f), not dropped.
        #expect(store.tracks[0].clips[0].notes!.contains { $0.id == noteID && $0.startBeat == 10 })
    }

    // MARK: - 5. Empty update — no-op, no mutation

    @Test("empty update: zeroed report, no mutation, dirty flag and undo depth untouched")
    func emptyUpdateIsANoOp() throws {
        let (store, _, clip) = try makeStore()
        let before = store.tracks[0].clips[0].notes!
        let dirtyBefore = store.isDirty
        let undoDepthBefore = store.journal.undoStack.count

        let report = try store.patchNotes(clipID: clip.id, update: [])

        #expect(report.updated == 0)
        #expect(report.totalNotes == 3)
        #expect(store.tracks[0].clips[0].notes == before)
        #expect(store.journal.undoStack.count == undoDepthBefore)
        #expect(store.isDirty == dirtyBefore, "an empty update must not even mark the project dirty")
    }

    // MARK: - 6. ALL-OR-NOTHING validation — model byte-identical after every refusal

    @Test("guard: unknown note id -> invalidClipEdit naming the id, model byte-identical")
    func guardUnknownNoteID() throws {
        let (store, _, clip) = try makeStore()
        let before = store.tracks[0].clips[0].notes!
        let bogusID = UUID()
        do {
            _ = try store.patchNotes(clipID: clip.id, update: [NotePatch(id: bogusID, velocity: 50)])
            Issue.record("expected invalidClipEdit")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains(bogusID.uuidString) == true)
        }
        #expect(store.tracks[0].clips[0].notes == before, "a refused patch must not touch the model")
    }

    @Test("guard: unknown id among otherwise-valid ids refuses the WHOLE call — nothing partially applied")
    func guardUnknownIDRefusesWholeBatch() throws {
        let (store, _, clip) = try makeStore()
        let before = store.tracks[0].clips[0].notes!
        let realID = before[0].id
        let bogusID = UUID()
        do {
            _ = try store.patchNotes(clipID: clip.id, update: [
                NotePatch(id: realID, velocity: 1),
                NotePatch(id: bogusID, velocity: 1),
            ])
            Issue.record("expected invalidClipEdit")
        } catch is ProjectError {
            // expected
        }
        #expect(store.tracks[0].clips[0].notes == before,
                "the real id's edit must NOT have been applied — all-or-nothing")
    }

    @Test("guard: the same note id named twice in one call -> invalidClipEdit naming it, model byte-identical")
    func guardDuplicateNoteID() throws {
        let (store, _, clip) = try makeStore()
        let before = store.tracks[0].clips[0].notes!
        let noteID = before[0].id
        do {
            _ = try store.patchNotes(clipID: clip.id, update: [
                NotePatch(id: noteID, velocity: 10),
                NotePatch(id: noteID, velocity: 20),
            ])
            Issue.record("expected invalidClipEdit")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains(noteID.uuidString) == true)
            #expect(error.errorDescription?.contains("more than once") == true)
        }
        #expect(store.tracks[0].clips[0].notes == before)
    }

    @Test("guard: an update entry with no fields set -> invalidClipEdit naming the id, model byte-identical")
    func guardEmptyPatchEntry() throws {
        let (store, _, clip) = try makeStore()
        let before = store.tracks[0].clips[0].notes!
        let noteID = before[0].id
        do {
            _ = try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID)])
            Issue.record("expected invalidClipEdit")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains(noteID.uuidString) == true)
            #expect(error.errorDescription?.contains("nothing to change") == true)
        }
        #expect(store.tracks[0].clips[0].notes == before)
    }

    @Test("guard: unknown clip id -> clipNotFound")
    func guardClipNotFound() throws {
        let (store, _, _) = try makeStore()
        #expect(throws: ProjectError.self) {
            try store.patchNotes(clipID: UUID(), update: [NotePatch(id: UUID(), velocity: 1)])
        }
    }

    @Test("guard: comp member -> clipInTakeGroup")
    func guardCompMember() throws {
        let (store, _, clip) = try makeStore()
        let idx = store.tracks[0].clips.firstIndex { $0.id == clip.id }!
        let noteID = store.tracks[0].clips[idx].notes![0].id
        store.tracks[0].clips[idx].takeGroupID = UUID()
        do {
            _ = try store.patchNotes(clipID: clip.id, update: [NotePatch(id: noteID, velocity: 1)])
            Issue.record("expected clipInTakeGroup")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("take group") == true)
        }
    }

    @Test("guard: audio clip -> notAMIDIClip naming clip.patchNotes")
    func guardAudioClip() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: track.id)
        do {
            _ = try store.patchNotes(clipID: audioClip.id, update: [NotePatch(id: UUID(), velocity: 1)])
            Issue.record("expected notAMIDIClip")
        } catch let error as ProjectError {
            #expect(error.errorDescription?.contains("clip.patchNotes") == true)
        }
    }
}
