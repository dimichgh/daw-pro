import Foundation
import Testing
@testable import DAWCore

/// p2-sing-pr-words (design 2026-10-12 §1.3, §2.7 D6, §6.1) — A WORD EDIT NEVER FOLDS INTO A NOTE EDIT.
///
/// The piano roll's note commit is `setClipNotes`, journaled with `key: "clip.notes:<id>"`; the undo journal folds an
/// edit into the top entry when both keys are equal and non-nil inside 800 ms (`UndoJournal.coalescingWindow`). Words
/// are written by `setNoteWord` → `setClipLyrics` → `writeLyrics`, which passes NO key — so a note drag, a typed word
/// and another note drag inside 800 ms are three undo steps, and one ⌘Z takes back exactly the last of them. That
/// holds by construction today; this pins it, because one "harmless" coalescing key added to `writeLyrics` would make
/// ⌘Z after typing a word also throw away the note edit before it.
///
/// The clock is INJECTED. The fixture's own edits happen, then the clock jumps 2 s (past the 800 ms window, so nothing
/// a test does can fold into the fixture's "Set Lyrics"), then it FREEZES: the test's edits all land at one instant,
/// inside the window, deterministically.
/// ⚠️ NOT a `@MainActor` suite (the cap): nonisolated, each test a `@MainActor` function.
@Suite("A word edit never folds into a note edit (p2-sing-pr-words)")
struct LyricWordUndoFoldTests {

    /// The injected clock: a reference the journal's closure reads.
    private final class Clock {
        var now = ContinuousClock.now
    }

    /// One instrument track, one melody clip at beat 0 (four touching one-beat notes) with `text`; then the clock
    /// jumps past the coalescing window and stays frozen.
    @MainActor
    private static func store(text: String = "one two three four") throws -> (ProjectStore, Clip) {
        let store = ProjectStore()
        let clock = Clock()
        store.journal.now = { clock.now }
        let track = store.addTrack(kind: .instrument)
        let notes = [0.0, 1, 2, 3].map { MIDINote(pitch: 60 + Int($0), startBeat: $0, lengthBeats: 1) }
        let added = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: 4, notes: notes)
        try store.setClipLyrics(clipId: added.id, text: text, undoLabel: "Set Lyrics")
        let clip = try #require(store.tracks.flatMap(\.clips).first { $0.id == added.id })
        clock.now = clock.now.advanced(by: .seconds(2))
        return (store, clip)
    }

    @MainActor
    private static func clip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap(\.clips).first { $0.id == id }
    }

    /// The same notes with note 3 one semitone up: a note edit that moves no word.
    private static func nudged(_ notes: [MIDINote]) -> [MIDINote] {
        var out = notes
        out[3].pitch += 1
        return out
    }

    @Test("positive control: two NOTE edits inside the window DO fold — the clock and the key really coalesce here")
    @MainActor
    func noteEditsFold() throws {
        let (store, clip) = try Self.store()
        let notes = try #require(clip.notes)
        let before = store.undoHistory().undo
        _ = try store.setClipNotes(clipID: clip.id, notes: Self.nudged(notes))
        var again = Self.nudged(notes)
        again[2].pitch += 1
        _ = try store.setClipNotes(clipID: clip.id, notes: again)
        #expect(store.undoHistory().undo.count == before.count + 1, "same key, same instant: one entry")
    }

    @Test("⭐ a note edit, then a typed word inside the window: TWO undo steps; one ⌘Z takes back only the word")
    @MainActor
    func noteThenWord() throws {
        let (store, clip) = try Self.store()
        let notes = try #require(clip.notes)
        let before = store.undoHistory().undo
        _ = try store.setClipNotes(clipID: clip.id, notes: Self.nudged(notes))
        let typed = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "big")
        #expect(typed.changed, "positive control: the word was written")
        #expect(store.undoHistory().undo == [ProjectStore.typeWordUndoLabel, "Edit Notes"] + before)

        #expect(try store.undo() == ProjectStore.typeWordUndoLabel)
        let after = try #require(Self.clip(store, clip.id))
        #expect(after.lyrics?.text == "one two three four", "the word is back")
        #expect(after.notes == Self.nudged(notes), "and the note edit before it is KEPT")
        #expect(store.undoHistory().undo == ["Edit Notes"] + before)
    }

    @Test("⭐ a typed word, then a note edit inside the window: TWO undo steps; one ⌘Z takes back only the note edit")
    @MainActor
    func wordThenNote() throws {
        let (store, clip) = try Self.store()
        let notes = try #require(clip.notes)
        let before = store.undoHistory().undo
        _ = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "big")
        _ = try store.setClipNotes(clipID: clip.id, notes: Self.nudged(notes))
        #expect(store.undoHistory().undo == ["Edit Notes", ProjectStore.typeWordUndoLabel] + before)

        #expect(try store.undo() == "Edit Notes")
        let after = try #require(Self.clip(store, clip.id))
        #expect(after.notes == notes, "the note edit is undone")
        #expect(after.lyrics?.text == "one big three four", "and the word typed before it is KEPT")
    }

    @Test("two words typed back to back are two steps too (one per word, as in the Sing sheet)")
    @MainActor
    func wordThenWord() throws {
        let (store, clip) = try Self.store()
        let notes = try #require(clip.notes)
        let before = store.undoHistory().undo
        _ = try store.setNoteWord(clipId: clip.id, noteId: notes[0].id, word: "uno")
        _ = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "dos")
        #expect(store.undoHistory().undo == [ProjectStore.typeWordUndoLabel, ProjectStore.typeWordUndoLabel] + before)
    }
}
