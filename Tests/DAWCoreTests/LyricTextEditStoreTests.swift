import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x1, the store half: `ProjectStore.setNoteWord` types a word on one
/// note through `setClipLyrics`, the one lyrics write, as ONE undo step "Type
/// Word"; `dryRun` changes nothing. The text edit itself is pinned by the
/// nonisolated `LyricTextEditTests`.
///
/// ⚠️ APPENDED to the existing `@MainActor` suite `ProjectStoreClipEditTests`
/// (`ClipEditTests.swift`, unmodified) as an extension: the tree is at its
/// `@MainActor` suite cap, and this adds no `@Suite`. Helpers carry a
/// `typeWord` prefix so they can never collide with the suite's own.
@MainActor
extension ProjectStoreClipEditTests {

    /// A store with one instrument track: a melody clip at beat 0 (four
    /// one-beat notes, touching, so one breath phrase) with `text`, and a
    /// second melody clip at beat 16 that nothing here edits.
    private static func typeWordStore(text: String = "hello world")
        throws -> (store: ProjectStore, trackID: UUID, clip: Clip, other: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let notes = [0.0, 1, 2, 3].map { MIDINote(pitch: 60 + Int($0), startBeat: $0, lengthBeats: 1) }
        let added = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0, lengthBeats: 4, notes: notes)
        let other = try store.addMIDIClip(toTrack: track.id, name: "Other", atBeat: 16, lengthBeats: 4, notes: notes)
        try store.setClipLyrics(clipId: added.id, text: text, undoLabel: "Set Lyrics")
        try store.setClipLyrics(clipId: other.id, text: "la la la la", undoLabel: "Set Lyrics")
        let clip = try #require(typeWordClip(store, added.id))
        return (store, track.id, clip, try #require(typeWordClip(store, other.id)))
    }

    private static func typeWordClip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap { $0.clips }.first { $0.id == id }
    }

    /// The whole project as the autosave writes it, sorted keys: what "the
    /// project did not change" means here. `savedAt` is the one field that is
    /// the clock, not the project (`ProjectDocument.init` stamps `Date()`), so
    /// it is pinned; the tests' controls showed two snapshots differ otherwise.
    private static func typeWordSnapshot(_ store: ProjectStore) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var document = store.buildAutosaveDocument()
        document.savedAt = Date(timeIntervalSince1970: 0)
        return try encoder.encode(document)
    }

    @Test("p2-sing-x1 Type Word is ONE undo step through the one lyrics write; undo restores the exact text bytes")
    func typeWordOneUndoStep() throws {
        let (store, _, clip, other) = try Self.typeWordStore()
        let notes = try #require(clip.notes)
        let beforeTracks = store.tracks
        let beforeText = try #require(clip.lyrics?.text)
        let beforeLabels = store.undoHistory().undo

        let result = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "big")
        #expect(result.text == "hello big world +")
        #expect(result.stored && result.changed)
        #expect(result.assignment.words.map { $0.word.typed } == ["hello", "big", "world"])
        #expect(Self.typeWordClip(store, clip.id)?.lyrics?.text == "hello big world +", "what the store holds")
        #expect(Self.typeWordClip(store, other.id) == other, "a clip nobody typed on is untouched")
        #expect(store.undoLabel == "Type Word")
        #expect(store.undoHistory().undo == ["Type Word"] + beforeLabels, "exactly one new undo step (newest first)")

        #expect(try store.undo() == "Type Word")
        #expect(store.tracks == beforeTracks)
        let restored = try #require(Self.typeWordClip(store, clip.id)?.lyrics?.text)
        #expect(Array(restored.utf8) == Array(beforeText.utf8), "the previous text, byte for byte")
        #expect(store.undoHistory().undo == beforeLabels)
    }

    @Test("p2-sing-x1 dryRun returns the same result and changes nothing: project bytes, undo history, the edited mark")
    func typeWordDryRun() throws {
        let (store, _, clip, _) = try Self.typeWordStore()
        let notes = try #require(clip.notes)
        // Saved, so the project starts unedited: an edit that went through the
        // store's undo funnel would mark it edited even if nothing changed.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x1-type-word-dry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try store.saveProject(to: dir.appendingPathComponent("Dry").path)
        #expect(!store.isDirty, "control: a saved project is not marked edited")
        let snapshot = try Self.typeWordSnapshot(store)
        #expect(try Self.typeWordSnapshot(store) == snapshot, "control: two snapshots of an unchanged project agree")
        let canUndo = store.canUndo
        let labels = store.undoHistory().undo
        #expect(canUndo, "control: the setup's own edits are undoable, so 'unchanged' is not 'empty'")

        let dry = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "big", dryRun: true)
        #expect(dry.text == "hello big world +")
        #expect(!dry.stored && dry.changed)
        #expect(try Self.typeWordSnapshot(store) == snapshot)
        #expect(store.canUndo == canUndo)
        #expect(store.undoHistory().undo == labels)
        #expect(!store.isDirty, "a dry run never enters the undo funnel")

        // The real call returns what the dry run promised.
        let real = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "big")
        #expect(real.text == dry.text)
        #expect(real.assignment == dry.assignment)
        #expect(try Self.typeWordSnapshot(store) != snapshot, "control: the real call did change the project")
        #expect(store.isDirty, "control: the real call is an edit")
    }

    @Test("p2-sing-x1 an edit that changes nothing records no undo step")
    func typeWordNoOp() throws {
        let (store, _, clip, _) = try Self.typeWordStore()
        let notes = try #require(clip.notes)
        let labels = store.undoHistory().undo
        let result = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "+")   // hello already holds it
        #expect(result.text == "hello world")
        #expect(result.stored && !result.changed)
        #expect(store.undoHistory().undo == labels)
    }

    @Test("p2-sing-x1 refusals reach the caller and change nothing")
    func typeWordRefusals() throws {
        let (store, _, clip, _) = try Self.typeWordStore()
        let notes = try #require(clip.notes)
        // An audio clip too, so the audio refusal has a real clip to refuse.
        let audio = store.addTrack(kind: .audio)
        let tAudio = try #require(store.tracks.firstIndex { $0.id == audio.id })
        let vox = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x1-never-read.wav"))
        store.tracks[tAudio].clips = [vox]
        let snapshot = try Self.typeWordSnapshot(store)
        #expect(try Self.typeWordSnapshot(store) == snapshot, "control: two snapshots of an unchanged project agree")
        let labels = store.undoHistory().undo

        let stray = UUID()
        do {
            _ = try store.setNoteWord(clipId: stray, noteId: notes[0].id, word: "la")
            Issue.record("expected clipNotFound")
        } catch ProjectError.clipNotFound(let id) {
            #expect(id == stray)
        }
        #expect(throws: LyricEditRefusal.wordHasSpace(word: "two words")) {
            try store.setNoteWord(clipId: clip.id, noteId: notes[0].id, word: "two words")
        }
        #expect(throws: LyricEditRefusal.nothingToHold(noteID: notes[0].id)) {
            try store.setNoteWord(clipId: clip.id, noteId: notes[0].id, word: "+", dryRun: true)
        }
        // An audio clip has no notes to type on.
        #expect(throws: LyricEditRefusal.needsMIDIClip) {
            try store.setNoteWord(clipId: vox.id, noteId: UUID(), word: "la")
        }
        #expect(throws: LyricEditRefusal.needsMIDIClip) {
            try store.setClipLyrics(clipId: vox.id, text: "la", undoLabel: "Set Lyrics")
        }
        #expect(try Self.typeWordSnapshot(store) == snapshot)
        #expect(store.undoHistory().undo == labels)
    }

    @Test("p2-sing-x1 setClipLyrics, the one lyrics write: blank clears to nil, over 4,000 characters is refused, one undo step")
    func typeWordSetter() throws {
        let (store, _, clip, _) = try Self.typeWordStore()
        let labels = store.undoHistory().undo
        try store.setClipLyrics(clipId: clip.id, text: " \n ", undoLabel: "Clear Lyrics")
        #expect(Self.typeWordClip(store, clip.id)?.lyrics == nil, "blank text is the one 'no lyrics' state")
        #expect(store.undoHistory().undo == ["Clear Lyrics"] + labels)
        let limit = String(repeating: "a", count: ClipLyrics.maxTextLength)
        try store.setClipLyrics(clipId: clip.id, text: limit, undoLabel: "Set Lyrics")
        #expect(Self.typeWordClip(store, clip.id)?.lyrics?.text == limit, "exactly the limit is accepted")
        #expect(throws: LyricEditRefusal.tooLong(characters: ClipLyrics.maxTextLength + 1)) {
            try store.setClipLyrics(clipId: clip.id, text: limit + "a", undoLabel: "Set Lyrics")
        }
        #expect(Self.typeWordClip(store, clip.id)?.lyrics?.text == limit)
        _ = try store.undo()
        #expect(Self.typeWordClip(store, clip.id)?.lyrics == nil)
        _ = try store.undo()
        #expect(Self.typeWordClip(store, clip.id)?.lyrics?.text == "hello world")
    }

    @Test("p2-sing-x1 a comp member's words are refused like every ordinary clip edit (the comp rebuilds the member)")
    func typeWordCompMember() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let t = try #require(store.tracks.firstIndex { $0.id == track.id })
        func takeNotes() -> [MIDINote] { [0.0, 1, 2, 3].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) } }
        let a = Clip(name: "A", lengthBeats: 4, notes: takeNotes(), lyrics: ClipLyrics(text: "one two three four"))
        let b = Clip(name: "B", lengthBeats: 4, notes: takeNotes(), lyrics: ClipLyrics(text: "five six seven eight"))
        store.tracks[t].clips = [a, b]
        let group = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(store.tracks[t].clips.first { $0.takeGroupID == group.id })
        let noteID = try #require(member.notes?.first?.id)
        do {
            _ = try store.setNoteWord(clipId: member.id, noteId: noteID, word: "la")
            Issue.record("expected clipInTakeGroup")
        } catch ProjectError.clipInTakeGroup(_, let clipID) {
            #expect(clipID == member.id)
        }
    }
}

// MARK: - p2-sing-x3b: the clip's language through the one lyrics write

/// APPENDED by W8-X3b to the same `@MainActor` suite (`ProjectStoreClipEditTests`), no new `@Suite`.
@MainActor
extension ProjectStoreClipEditTests {

    private static func languageClip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.flatMap { $0.clips }.first { $0.id == id }
    }

    @Test("p2-sing-x3b setClipLyrics with a language sets it; the text-only call KEEPS it; one undo step each")
    func languageKeptByTheTextOnlyWrite() throws {
        let (store, _, clip, _) = try Self.typeWordStore(text: "一闪一闪")
        #expect(clip.lyrics?.language == nil, "control: the fixture's clip starts English")
        let labels = store.undoHistory().undo
        try store.setClipLyrics(clipId: clip.id, text: "一闪一闪", language: "zh", undoLabel: "Set Language")
        #expect(Self.languageClip(store, clip.id)?.lyrics == ClipLyrics(text: "一闪一闪", language: "zh"))
        #expect(store.undoHistory().undo == ["Set Language"] + labels, "a language-only change is ONE undo step")
        try store.setClipLyrics(clipId: clip.id, text: "一闪一闪亮", undoLabel: "Set Lyrics")
        #expect(Self.languageClip(store, clip.id)?.lyrics == ClipLyrics(text: "一闪一闪亮", language: "zh"),
                "the text-only write never resets the language")
        #expect(try store.undo() == "Set Lyrics")
        #expect(Self.languageClip(store, clip.id)?.lyrics == ClipLyrics(text: "一闪一闪", language: "zh"))
        #expect(try store.undo() == "Set Language")
        #expect(Self.languageClip(store, clip.id)?.lyrics == ClipLyrics(text: "一闪一闪"))
    }

    @Test("p2-sing-x3b the language overload: \"en\" is English, an unsupported code is refused and changes nothing")
    func languageOverloadRefusals() throws {
        let (store, _, clip, _) = try Self.typeWordStore()
        try store.setClipLyrics(clipId: clip.id, text: "hello world", language: "en", undoLabel: "Set Lyrics")
        #expect(Self.languageClip(store, clip.id)?.lyrics?.language == nil)
        let before = store.tracks
        let labels = store.undoHistory().undo
        for code in ["fr", "es", ""] {
            #expect(throws: LyricEditRefusal.lyrics(.languageUnsupported(language: code))) {
                try store.setClipLyrics(clipId: clip.id, text: "bonjour", language: code, undoLabel: "Set Lyrics")
            }
        }
        #expect(store.tracks == before && store.undoHistory().undo == labels, "nothing changed")
        #expect(LyricEditRefusal.lyrics(.languageUnsupported(language: "fr")).sentence
                == LyricLanguage.Copy.languageUnsupported)
        // Blank text clears the lyrics, language and all (the one "no lyrics" state).
        try store.setClipLyrics(clipId: clip.id, text: " ", language: "zh", undoLabel: "Clear Lyrics")
        #expect(Self.languageClip(store, clip.id)?.lyrics == nil)
    }

    @Test("p2-sing-x3b Type Word on a Chinese clip types a character on one note and the clip stays Chinese")
    func typeWordOnAChineseClip() throws {
        let (store, _, clip, _) = try Self.typeWordStore()
        try store.setClipLyrics(clipId: clip.id, text: "一闪一闪", language: "zh", undoLabel: "Set Lyrics")
        let notes = try #require(clip.notes)
        let result = try store.setNoteWord(clipId: clip.id, noteId: notes[1].id, word: "亮")
        #expect(result.text == "一亮一闪" && result.stored && result.changed)
        #expect(result.assignment.words.map { $0.word.typed } == ["一", "亮", "一", "闪"])
        #expect(Self.languageClip(store, clip.id)?.lyrics == ClipLyrics(text: "一亮一闪", language: "zh"))
        #expect(store.undoLabel == "Type Word")
        let held = try store.setNoteWord(clipId: clip.id, noteId: notes[3].id, word: "+")
        #expect(held.text == "一亮一 +")
        #expect(Self.languageClip(store, clip.id)?.lyrics?.language == "zh")
    }
}
