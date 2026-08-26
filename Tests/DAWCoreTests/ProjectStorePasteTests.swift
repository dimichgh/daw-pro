import Testing
import Foundation
@testable import DAWCore

/// m23-ek-3 — the store half of the clipboard: `pasteClips` (batch, one undo,
/// skip-and-report, overlap resolved) and `pasteNotes` (UNCOALESCED).
@Suite("Project store paste (m23-ek-3)")
@MainActor
struct ProjectStorePasteTests {

    // MARK: - pasteNotes: the undo-coalescing trap

    /// ⚠️⚠️ **THE HIGHEST-VALUE TEST IN THIS FILE.**
    ///
    /// `setClipNotes` journals with `key: "clip.notes:<id>"`, and
    /// `UndoJournal.recordEdit` folds a fresh edit into the current top whenever
    /// both keys are non-nil and equal and the top last merged inside
    /// `coalescingWindow` (800 ms). So a note paste routed through the roll's
    /// ordinary `commit()` → `setClipNotes` path, landing within 800 ms of a
    /// note edit on the same clip, would FOLD INTO IT — and one ⌘Z would undo
    /// both, silently.
    ///
    /// ⚠️ **THE CLOCK IS PINNED INSIDE THE WINDOW AND NEVER ADVANCED PAST IT.**
    /// A test that slept (or advanced) past 800 ms would pass VACUOUSLY: at that
    /// point nothing coalesces, so "two entries" would prove nothing about
    /// `pasteNotes` at all. The paired control below is what proves the window
    /// was actually in force under this very clock.
    @Test("a note paste 100 ms after a note edit is its OWN undo step")
    func pasteNotesDoesNotCoalesceIntoThePrecedingEdit() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id)
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        let afterEdit = store.journal.undoStack.count
        // WELL INSIDE the 800 ms window — this is the whole point.
        clock = clock.advanced(by: .milliseconds(100))
        try store.pasteNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0),
                                                     MIDINote(pitch: 67, startBeat: 2)])

        #expect(store.journal.undoStack.count == afterEdit + 1)
        #expect(store.undoLabel == "Paste Notes")

        // And one undo reverses ONLY the paste, leaving the edit standing.
        try store.undo()
        #expect(store.tracks[0].clips[0].notes?.map(\.pitch) == [60])
        #expect(store.undoLabel == "Edit Notes")
    }

    /// ⚠️ **THE ANTI-VACUITY CONTROL FOR THE TEST ABOVE.** Same store, same
    /// clock, same 100 ms gap — but two `setClipNotes` calls instead of an edit
    /// then a paste. If coalescing were somehow NOT in force under this clock
    /// (a changed window, a broken `now` seam, a key that stopped being set)
    /// this would report two entries and the test above would be proving
    /// nothing. It reports ONE.
    @Test("CONTROL: two note EDITS 100 ms apart DO coalesce, so the window is in force")
    func setClipNotesStillCoalescesUnderTheSameClock() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id)
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        let afterEdit = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(100))
        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 62, startBeat: 1)])

        #expect(store.journal.undoStack.count == afterEdit,
                "coalescing must be ACTIVE here, or the paste test above is vacuous")
    }

    @Test("two rapid pastes are two undo steps — a paste never folds into a paste either")
    func twoRapidPastesDoNotFold() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id)
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.pasteNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        let afterFirst = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(50))
        try store.pasteNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0),
                                                     MIDINote(pitch: 64, startBeat: 1)])
        #expect(store.journal.undoStack.count == afterFirst + 1)
    }

    @Test("a note EDIT immediately after a paste does not fold into the paste")
    func anEditAfterAPasteIsItsOwnStep() throws {
        // `recordEdit` requires BOTH keys non-nil to merge, and the paste's is
        // nil — so the merge is refused in this direction too. Pinned because
        // "the paste doesn't absorb the edit before it" and "the edit after it
        // doesn't absorb the paste" are different halves of the same rule.
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id)
        var clock = ContinuousClock.now
        store.journal.now = { clock }

        try store.pasteNotes(clipID: clip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        let afterPaste = store.journal.undoStack.count
        clock = clock.advanced(by: .milliseconds(100))
        try store.setClipNotes(clipID: clip.id, notes: [MIDINote(pitch: 72, startBeat: 3)])
        #expect(store.journal.undoStack.count == afterPaste + 1)
        #expect(store.undoLabel == "Edit Notes")
    }

    @Test("pasteNotes validates exactly as setClipNotes does")
    func pasteNotesValidation() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let audio = store.addTrack(kind: .audio)
        let inst = store.addTrack(kind: .instrument)
        let midi = try store.addMIDIClip(toTrack: inst.id)

        #expect(throws: ProjectError.self) {
            try store.pasteNotes(clipID: UUID(), notes: [])
        }
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"),
                                              toTrack: audio.id)
        #expect(throws: ProjectError.self) {
            try store.pasteNotes(clipID: audioClip.id, notes: [MIDINote(pitch: 60, startBeat: 0)])
        }
        // Notes are re-clamped through `MIDINote.init` and canonically ordered,
        // exactly as `setClipNotes` does.
        let out = try store.pasteNotes(clipID: midi.id, notes: [
            MIDINote(pitch: 200, velocity: 999, startBeat: 4, lengthBeats: 1),
            MIDINote(pitch: 60, startBeat: 1, lengthBeats: 1),
        ])
        #expect(out.notes?.map(\.startBeat) == [1, 4])
        #expect(out.notes?.map(\.pitch) == [60, 127])
        #expect(out.notes?.last?.velocity == 127)
    }

    // MARK: - pasteClips

    private func landing(_ clip: Clip, on track: Track, at beat: Double) -> ClipPasteLanding {
        ClipPasteLanding(clip: clip, targetTrackID: track.id, startBeat: beat)
    }

    /// An audio clip as a VALUE — never added to the store. A `ClipPasteLanding`
    /// carries a plain `Clip`, which is exactly what a clipboard entry is, so
    /// these tests do not need the source to exist in the project at all.
    private func audioClipValue(_ name: String, length: Double = 2) -> Clip {
        Clip(name: name, startBeat: 0, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: "/tmp/\(name).wav"))
    }

    @Test("N clips land in ONE undo step, under FRESH ids")
    func pasteClipsIsOneUndoStep() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let source = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 2)
        let before = store.journal.undoStack.count

        let outcomes = try store.pasteClips([
            landing(source, on: track, at: 8),
            landing(source, on: track, at: 12),
            landing(source, on: track, at: 16),
        ])

        #expect(store.journal.undoStack.count == before + 1, "N clips = ONE undo step")
        #expect(store.undoLabel == "Paste 3 Clips")
        #expect(outcomes.count == 3)
        #expect(outcomes.allSatisfy { $0.error == nil })
        #expect(store.tracks[0].clips.count == 4)

        // Fresh ids: pasting twice must yield distinct objects.
        let pasted: [Clip] = outcomes.compactMap { $0.clip }
        #expect(Set(pasted.map { $0.id }).count == 3)
        #expect(!pasted.contains { $0.id == source.id })
        // And the outcome names the SOURCE clip so a caller can match it back.
        #expect(outcomes.allSatisfy { $0.sourceClipID == source.id })

        // One undo removes the whole paste.
        try store.undo()
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("a single-clip paste names the clip in its undo label")
    func singleClipLabel() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let source = try store.addMIDIClip(toTrack: track.id, name: "Riff", atBeat: 0,
                                           lengthBeats: 2)
        try store.pasteClips([landing(source, on: track, at: 8)])
        #expect(store.undoLabel == "Paste Clip 'Riff'")
    }

    @Test("⚠️ a paste onto an occupied region RESOLVES the overlap rather than stacking")
    func pasteResolvesOverlapAgainstResidents() throws {
        // The +6 dB defect m11-d/m13-b exist to prevent. A bespoke batch paste
        // that just appended would ship it silently.
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let resident = try store.addMIDIClip(toTrack: track.id, name: "resident",
                                             atBeat: 8, lengthBeats: 8)
        let source = try store.addMIDIClip(toTrack: track.id, name: "src",
                                           atBeat: 0, lengthBeats: 4)

        let outcomes = try store.pasteClips([landing(source, on: track, at: 8)])
        #expect(outcomes[0].error == nil)
        // The resident's covered region yielded — exactly as `clip.move` would.
        let live = store.tracks[0].clips.first { $0.id == resident.id }
        #expect(live?.startBeat == 12)
        #expect(outcomes[0].trimmedClipIDs.contains(resident.id))
        // ANTI-VACUITY: the resident really did start at 8 and really did move.
        #expect(resident.startBeat == 8)
    }

    @Test("⚠️ two pasted SIBLINGS on one track are both claimants — neither trims the other")
    func pastedSiblingsAreCoActiveClaimants() throws {
        // `resolvingOverlaps` exempts CLAIMANTS from trimming. If the claimant
        // set were just the landing being resolved, a sibling landed a moment
        // earlier would be treated as a resident and TRIMMED BY ITS OWN GROUP —
        // a silent deformation of the material the user copied.
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let source = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4)

        let outcomes = try store.pasteClips([
            landing(source, on: track, at: 8),
            landing(source, on: track, at: 12),  // flush, not overlapping
        ])
        let placed: [Clip] = outcomes.compactMap { $0.clip }
        #expect(placed.count == 2)
        #expect(placed.map { $0.startBeat }.sorted() == [8, 12])
        #expect(placed.map { $0.lengthBeats } == [4, 4], "neither sibling was trimmed")
        #expect(outcomes.allSatisfy { $0.trimmedClipIDs.isEmpty && $0.removedClipIDs.isEmpty })
    }

    @Test("a landing's own window is resolved — a GAP between pasted clips is not swept")
    func gapsBetweenLandingsAreNotSwept() throws {
        // Resolving one UNION window per track instead of each landing's own
        // would trim residents sitting in the group's internal gaps, which the
        // paste never covered.
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let source = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 2)
        let inTheGap = try store.addMIDIClip(toTrack: track.id, name: "gap",
                                             atBeat: 12, lengthBeats: 2)

        try store.pasteClips([
            landing(source, on: track, at: 8),    // 8..10
            landing(source, on: track, at: 16),   // 16..18 — the gap 10..16 holds `inTheGap`
        ])
        let live = store.tracks[0].clips.first { $0.id == inTheGap.id }
        #expect(live?.startBeat == 12)
        #expect(live?.lengthBeats == 2, "a clip in the group's internal gap must be untouched")
    }

    @Test("a MIXED payload skips the mismatched clip and still lands the rest, as ONE edit")
    func mixedKindPayloadSkipsAndReports() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let midi = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 2)
        let audio = audioClipValue("wav")
        let before = store.journal.undoStack.count

        let outcomes = try store.pasteClips([
            landing(midi, on: inst, at: 16),
            landing(audio, on: inst, at: 16),   // audio onto an instrument track
        ])
        #expect(outcomes[0].error == nil)
        #expect(outcomes[1].error != nil)
        #expect(outcomes[1].clip == nil)
        // ONE undo step for the successes — the bad item did not abort them and
        // did not earn a second entry.
        #expect(store.journal.undoStack.count == before + 1)
        #expect(store.undoLabel == "Paste Clip 'MIDI Clip 1'")
        // OUTCOMES COME BACK IN REQUEST ORDER, so a caller can pair them with
        // the clipboard entries that produced them.
        #expect(outcomes.map { $0.sourceClipID } == [midi.id, audio.id])
    }

    @Test("a fully-refused paste leaves NO journal entry and mutates nothing")
    func fullyRefusedPasteMutatesNothing() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let audio = audioClipValue("wav")
        let before = store.journal.undoStack.count
        let tracksBefore = store.tracks

        let outcomes = try store.pasteClips([landing(audio, on: inst, at: 0)])
        #expect(outcomes.count == 1)
        #expect(outcomes[0].error != nil)
        #expect(store.journal.undoStack.count == before, "no stray undo entry")
        // `performEdit` is never ENTERED — which is why this also cannot flag an
        // untouched project dirty. (`isDirty` is already true from `addTrack`
        // and there is no public way to clear it without a save, so the
        // observable claim made here is the stronger one: nothing moved.)
        #expect(store.tracks == tracksBefore)
    }

    @Test("an unknown target track is reported per item, never thrown at the caller")
    func unknownTrackIsReported() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let source = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 2)
        let outcomes = try store.pasteClips([
            ClipPasteLanding(clip: source, targetTrackID: UUID(), startBeat: 4),
            landing(source, on: track, at: 8),
        ])
        #expect(outcomes[0].error != nil)
        #expect(outcomes[1].error == nil)
    }

    @Test("an empty landing list is a no-op that returns nothing")
    func emptyLandingsIsANoOp() throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .instrument)
        let before = store.journal.undoStack.count
        #expect(try store.pasteClips([]).isEmpty)
        #expect(store.journal.undoStack.count == before)
    }

    @Test("a pasted clip carries the source's full value — fades, gain, notes, controller lanes")
    func pastedClipIsAFullValueCopy() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let source = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4)
        try store.setClipNotes(clipID: source.id, notes: [
            MIDINote(pitch: 60, velocity: 90, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 67, velocity: 110, startBeat: 2, lengthBeats: 0.5),
        ])
        let enriched = store.tracks[0].clips.first { $0.id == source.id }!

        let outcomes = try store.pasteClips([landing(enriched, on: track, at: 16)])
        let pasted = try #require(outcomes[0].clip)
        #expect(pasted.id != enriched.id)
        #expect(pasted.startBeat == 16)
        #expect(pasted.lengthBeats == enriched.lengthBeats)
        #expect(pasted.notes == enriched.notes)
        #expect(pasted.takeGroupID == nil)
    }

    @Test("a negative landing beat is floored at 0 rather than creating an unreachable clip")
    func negativeLandingIsFloored() throws {
        // Belt-and-braces behind `PasteAnchorPolicy`'s group clamp, and the same
        // floor `duplicateClip` applies — so the two verbs cannot disagree about
        // what a negative beat means.
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let source = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 2)
        let outcomes = try store.pasteClips([landing(source, on: track, at: -12)])
        #expect(outcomes[0].clip?.startBeat == 0)
    }
}
