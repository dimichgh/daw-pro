import Foundation
import Testing
@testable import DAWCore

/// p2-sing-pr-words phase 2, the store half (design `docs/design/2026-10-12-piano-roll-words.md` §2.8, D6):
/// `ProjectStore.setNoteWords` types a whole line across notes through `setClipLyrics`, the one lyrics write, as ONE
/// undo step "Type Words" with no coalescing key; all or nothing; `dryRun` changes nothing; a line that types the
/// words already there records nothing. The text edit itself is pinned by the nonisolated `LyricLineEditTests`.
///
/// ⚠️ APPENDED to the existing `@MainActor` suite `ProjectStoreClipEditTests` (`ClipEditTests.swift`, unmodified) as
/// an extension, the `LyricTextEditStoreTests.swift` precedent: the tree is at its `@MainActor` suite cap, and this
/// adds no `@Suite`. Helpers carry a `typeLine` prefix so they can never collide with the suite's own.
@MainActor
extension ProjectStoreClipEditTests {

    /// A store with one instrument track: a melody clip at beat 0 (four one-beat notes, touching, so one breath
    /// phrase) with `text`, and a second melody clip at beat 16 that nothing here edits.
    private static func typeLineStore(text: String = "one two three four")
        throws -> (store: ProjectStore, clip: Clip, other: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let notes = [0.0, 1, 2, 3].map { MIDINote(pitch: 60 + Int($0), startBeat: $0, lengthBeats: 1) }
        let added = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: 4, notes: notes)
        let other = try store.addMIDIClip(toTrack: track.id, name: "Other", atBeat: 16, lengthBeats: 4, notes: notes)
        try store.setClipLyrics(clipId: added.id, text: text, undoLabel: "Set Lyrics")
        try store.setClipLyrics(clipId: other.id, text: "la la la la", undoLabel: "Set Lyrics")
        return (store, try #require(typeLineClip(store, added.id)), try #require(typeLineClip(store, other.id)))
    }

    private static func typeLineClip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap { $0.clips }.first { $0.id == id }
    }

    /// The whole project as the autosave writes it, sorted keys, `savedAt` pinned (the clock, not the project):
    /// what "the project did not change" means here (the `typeWordSnapshot` shape).
    private static func typeLineSnapshot(_ store: ProjectStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var document = store.buildAutosaveDocument()
        document.savedAt = Date(timeIntervalSince1970: 0)
        return try encoder.encode(document)
    }

    /// Saves the project to a fresh folder, so it starts unedited; returns the folder to remove.
    private static func typeLineSaved(_ store: ProjectStore, _ label: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prwc-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try store.saveProject(to: dir.appendingPathComponent("Line").path)
        return dir
    }

    @Test("p2-sing-pr-words a whole line is ONE undo step \"Type Words\"; one ⌘Z restores the text byte for byte")
    func typeLineOneUndoStep() throws {
        let (store, clip, other) = try Self.typeLineStore()
        let notes = try #require(clip.notes)
        let beforeTracks = store.tracks
        let beforeText = try #require(clip.lyrics?.text)
        let labels = store.undoHistory().undo

        let result = try store.setNoteWords(clipId: clip.id, startNoteId: notes[1].id, words: ["big", "red", "sky"])
        #expect(result.text == "one big red sky")
        #expect(result.stored && result.changed)
        #expect(result.clipID == clip.id)
        #expect(result.assignment.words.map { $0.word.typed } == ["one", "big", "red", "sky"])
        #expect(Self.typeLineClip(store, clip.id)?.lyrics?.text == "one big red sky", "what the store holds")
        #expect(Self.typeLineClip(store, other.id) == other, "a clip nobody typed on is untouched")
        #expect(ProjectStore.typeWordsUndoLabel == "Type Words")
        #expect(store.undoLabel == ProjectStore.typeWordsUndoLabel)
        #expect(store.undoHistory().undo == [ProjectStore.typeWordsUndoLabel] + labels,
                "three words, exactly ONE new undo step (newest first)")

        #expect(try store.undo() == ProjectStore.typeWordsUndoLabel)
        #expect(store.tracks == beforeTracks)
        let restored = try #require(Self.typeLineClip(store, clip.id)?.lyrics?.text)
        #expect(Array(restored.utf8) == Array(beforeText.utf8), "the previous text, byte for byte")
        #expect(store.undoHistory().undo == labels)
        #expect(try store.redo() == ProjectStore.typeWordsUndoLabel)
        #expect(Self.typeLineClip(store, clip.id)?.lyrics?.text == "one big red sky", "redo puts the whole line back")
    }

    @Test("p2-sing-pr-words a line never folds: a note edit, a line and a line inside the coalescing window are THREE steps")
    func typeLineNeverFolds() throws {
        let (store, clip, _) = try Self.typeLineStore()
        // The injected clock: 2 s past the fixture's own edits, then frozen, so every edit below lands at one instant
        // inside the 800 ms window (the `LyricWordUndoFoldTests` method).
        let clock = TypeLineClock()
        clock.now = clock.now.advanced(by: .seconds(2))
        store.journal.now = { clock.now }
        let notes = try #require(clip.notes)
        let labels = store.undoHistory().undo
        var nudged = notes
        nudged[3].pitch += 1
        _ = try store.setClipNotes(clipID: clip.id, notes: nudged)
        _ = try store.setNoteWords(clipId: clip.id, startNoteId: notes[0].id, words: ["uno", "dos"])
        _ = try store.setNoteWords(clipId: clip.id, startNoteId: notes[2].id, words: ["tres", "cuatro"])
        #expect(store.undoHistory().undo
                == [ProjectStore.typeWordsUndoLabel, ProjectStore.typeWordsUndoLabel, "Edit Notes"] + labels)

        #expect(try store.undo() == ProjectStore.typeWordsUndoLabel)
        let after = try #require(Self.typeLineClip(store, clip.id))
        #expect(after.lyrics?.text == "uno dos three four", "one ⌘Z takes back only the last line")
        #expect(after.notes == nudged, "and the note edit before it is kept")
    }

    @Test("p2-sing-pr-words dryRun returns the same result and changes nothing: project bytes, undo history, the edited mark")
    func typeLineDryRun() throws {
        let (store, clip, _) = try Self.typeLineStore()
        let notes = try #require(clip.notes)
        let dir = try Self.typeLineSaved(store, "dry")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!store.isDirty, "control: a saved project is not marked edited")
        let snapshot = try Self.typeLineSnapshot(store)
        #expect(try Self.typeLineSnapshot(store) == snapshot, "control: two snapshots of an unchanged project agree")
        let labels = store.undoHistory().undo
        #expect(store.canUndo, "control: the setup's own edits are undoable, so 'unchanged' is not 'empty'")

        let dry = try store.setNoteWords(clipId: clip.id, startNoteId: notes[0].id, words: ["uno", "dos"],
                                         dryRun: true)
        #expect(dry.text == "uno dos three four")
        #expect(!dry.stored && dry.changed)
        #expect(try Self.typeLineSnapshot(store) == snapshot)
        #expect(store.undoHistory().undo == labels)
        #expect(!store.isDirty, "a dry run never enters the undo funnel")

        let real = try store.setNoteWords(clipId: clip.id, startNoteId: notes[0].id, words: ["uno", "dos"])
        #expect(real.text == dry.text)
        #expect(real.assignment == dry.assignment)
        #expect(real.stored && real.changed)
        #expect(try Self.typeLineSnapshot(store) != snapshot, "control: the real call did change the project")
        #expect(store.isDirty, "control: the real call is an edit")
    }

    @Test("p2-sing-pr-words a line that types the words already there changes nothing and records no undo step")
    func typeLineNoOp() throws {
        let (store, clip, _) = try Self.typeLineStore()
        let notes = try #require(clip.notes)
        let dir = try Self.typeLineSaved(store, "noop")
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(!store.isDirty, "control: a saved project is not marked edited")
        let snapshot = try Self.typeLineSnapshot(store)
        let labels = store.undoHistory().undo

        let result = try store.setNoteWords(clipId: clip.id, startNoteId: notes[1].id, words: ["two", "three"])
        #expect(result.text == "one two three four")
        #expect(result.stored && !result.changed)
        #expect(store.undoHistory().undo == labels, "no journal entry")
        #expect(try Self.typeLineSnapshot(store) == snapshot)
        #expect(!store.isDirty, "a line that changes nothing is not an edit")
    }

    @Test("p2-sing-pr-words all or nothing: a refusal mid-line writes nothing, not even the words before it")
    func typeLineAllOrNothing() throws {
        let (store, clip, _) = try Self.typeLineStore()
        let notes = try #require(clip.notes)
        let snapshot = try Self.typeLineSnapshot(store)
        #expect(try Self.typeLineSnapshot(store) == snapshot, "control: two snapshots of an unchanged project agree")
        let labels = store.undoHistory().undo

        // "uno" and "dos" go on; "twin-kle" (two parts) lands on a word that sings one note (the v1 limit).
        let refusal = LyricLineEditRefusal.word(index: 2, word: "twin-kle",
                                                refusal: .lyrics(.markedWordDoesNotFit(word: "twinkle", needed: 2)))
        for dryRun in [true, false] {
            #expect(throws: refusal) {
                try store.setNoteWords(clipId: clip.id, startNoteId: notes[0].id, words: ["uno", "dos", "twin-kle"],
                                       dryRun: dryRun)
            }
        }
        #expect(Self.typeLineClip(store, clip.id)?.lyrics?.text == "one two three four",
                "the two words before the refusal were NOT written")
        #expect(try Self.typeLineSnapshot(store) == snapshot)
        #expect(store.undoHistory().undo == labels)

        #expect(throws: LyricLineEditRefusal.lineLongerThanNotes(words: 5, notes: 4)) {
            try store.setNoteWords(clipId: clip.id, startNoteId: notes[0].id, words: ["a", "b", "c", "d", "e"])
        }
        #expect(try Self.typeLineSnapshot(store) == snapshot)
        #expect(store.undoHistory().undo == labels)
    }

    @Test("p2-sing-pr-words refused before anything, like setNoteWord: a stray clip, an audio clip, a comp member")
    func typeLineTargetRefusals() throws {
        let (store, clip, _) = try Self.typeLineStore()
        let notes = try #require(clip.notes)
        let audio = store.addTrack(kind: .audio)
        let tAudio = try #require(store.tracks.firstIndex { $0.id == audio.id })
        let vox = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/prwc-never-read.wav"))
        store.tracks[tAudio].clips = [vox]
        let snapshot = try Self.typeLineSnapshot(store)
        let labels = store.undoHistory().undo

        let stray = UUID()
        do {
            _ = try store.setNoteWords(clipId: stray, startNoteId: notes[0].id, words: ["la"])
            Issue.record("expected clipNotFound")
        } catch ProjectError.clipNotFound(let id) {
            #expect(id == stray)
        }
        for dryRun in [true, false] {
            #expect(throws: LyricEditRefusal.needsMIDIClip) {
                try store.setNoteWords(clipId: vox.id, startNoteId: UUID(), words: ["la"], dryRun: dryRun)
            }
        }
        #expect(try Self.typeLineSnapshot(store) == snapshot)
        #expect(store.undoHistory().undo == labels)

        // A comp member: its clip is rebuilt from the takes, so a direct write is refused.
        let comp = ProjectStore()
        let track = comp.addTrack(kind: .instrument)
        let t = try #require(comp.tracks.firstIndex { $0.id == track.id })
        func takeNotes() -> [MIDINote] { [0.0, 1, 2, 3].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) } }
        let a = Clip(name: "A", lengthBeats: 4, notes: takeNotes(), lyrics: ClipLyrics(text: "one two three four"))
        let b = Clip(name: "B", lengthBeats: 4, notes: takeNotes(), lyrics: ClipLyrics(text: "five six seven eight"))
        comp.tracks[t].clips = [a, b]
        let group = try comp.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(comp.tracks[t].clips.first { $0.takeGroupID == group.id })
        let noteID = try #require(member.notes?.first?.id)
        do {
            _ = try comp.setNoteWords(clipId: member.id, startNoteId: noteID, words: ["la", "di"])
            Issue.record("expected clipInTakeGroup")
        } catch ProjectError.clipInTakeGroup(_, let clipID) {
            #expect(clipID == member.id)
        }
    }
}

/// The injected journal clock for `typeLineNeverFolds`: a reference the journal's closure reads.
private final class TypeLineClock {
    var now = ContinuousClock.now
}
