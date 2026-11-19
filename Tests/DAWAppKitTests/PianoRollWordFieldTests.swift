import CoreGraphics
import DAWAppKit
import DAWCore
import Foundation
import Testing

/// p2-sing-pr-words (design 2026-10-12 §2.6 D5) — the piano roll's word field, headless: it opens by the Sing sheet's
/// own rule, walks the melody with Tab / ⇧Tab, keeps a refused Return open, closes on a refused blur, closes WITHOUT
/// writing when the clip changes from outside, and survives the echo of its own commit.
///
/// Every write goes through a REAL `ProjectStore.setNoteWord`, behind a spy that counts the calls.
/// ⚠️ NOT a `@MainActor` suite (the cap): the suite is nonisolated and each test is a `@MainActor` function.
@Suite("Piano roll words — the word field (p2-sing-pr-words)")
struct PianoRollWordFieldTests {

    /// THE store writer, spied.
    @MainActor
    private final class WriterSpy {
        let store: ProjectStore
        let clipID: UUID
        private(set) var calls: [(noteID: UUID, word: String)] = []
        init(store: ProjectStore, clipID: UUID) {
            self.store = store
            self.clipID = clipID
        }
        func write(_ noteID: UUID, _ word: String) throws -> LyricNoteWordResult {
            calls.append((noteID, word))
            return try store.setNoteWord(clipId: clipID, noteId: noteID, word: word)
        }
    }

    @MainActor
    private struct Rig {
        let store: ProjectStore
        let trackID: UUID
        let clipID: UUID
        let model: PianoRollWordsModel
        let spy: WriterSpy
        var clip: Clip { PianoRollWordsFixture.clip(store, clipID)! }
        var notes: [MIDINote] { clip.notes ?? [] }
        var text: String? { clip.lyrics?.text }

        /// The roll's `.onChange` path, fed the clip the store HOLDS.
        @discardableResult
        func sync() -> Bool {
            model.update(clip: clip, tempoMap: store.transport.tempoMap,
                         leadLyrics: SungWordsFreshness.leadLyrics(for: clipID, in: store.tracks))
        }
    }

    @MainActor
    private static func rig(pitches: [Int] = [60, 62, 64, 65], lyrics: String? = "one two three four") throws -> Rig {
        let (store, track, clip) = try PianoRollWordsFixture.store(pitches: pitches, lyrics: lyrics)
        let rig = Rig(store: store, trackID: track, clipID: clip, model: PianoRollWordsModel(),
                      spy: WriterSpy(store: store, clipID: clip))
        rig.sync()
        return rig
    }

    // MARK: Opening — the Sing sheet's rule

    @Test("the field opens by the Sing sheet's OWN rule: the word on its first note, + on a held note, the unsung sentence")
    @MainActor
    func openingIsTheSheets() throws {
        // "hi there" on four notes: "there" holds the last notes (rule 5.2).
        let rig = try Self.rig(lyrics: "hi there")
        let notes = rig.notes
        let track = try #require(rig.store.tracks.first { $0.id == rig.trackID })
        let preview = SingSheetPreview.make(clip: rig.clip, track: track, text: try #require(rig.text),
                                            octaveShift: 0, tempoMap: rig.store.transport.tempoMap,
                                            meterMap: MeterMap(constant: TimeSignature()))
        for note in notes {
            let opened = try #require(rig.model.openField(noteID: note.id))
            #expect(opened == note.id)
            #expect(rig.model.field == SingNoteWordField.opening(for: note.id, in: preview),
                    "the roll and the sheet disagree about note \(notes.firstIndex { $0.id == note.id }!)")
        }
        rig.model.openField(noteID: notes[0].id)
        #expect(rig.model.field?.draft == "hi")
        rig.model.openField(noteID: notes[3].id)
        #expect(rig.model.field?.draft == "+", "a held note opens on +")

        // An unsung note (flow mode, fewer words than phrases): empty, with the sentence, and it can still commit.
        let notesTwoPhrases = [0.0, 1, 3, 4].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) }
        let store = ProjectStore()
        let lead = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: lead.id, name: "Two", atBeat: 0, lengthBeats: 5,
                                         notes: notesTwoPhrases)
        try store.setClipLyrics(clipId: clip.id, text: "hello", undoLabel: "Set Lyrics")
        let model = PianoRollWordsModel()
        model.update(clip: try #require(PianoRollWordsFixture.clip(store, clip.id)), tempoMap: store.transport.tempoMap,
                     leadLyrics: [])
        let unsung = try #require(model.words.unsungNoteIDs.first, "positive control: the fixture leaves notes unsung")
        model.openField(noteID: unsung)
        #expect(model.field?.draft == "")
        #expect(model.field?.refusal == LyricEditRefusal.noteNotSung(noteID: unsung).sentence)
        #expect(model.field?.canCommit == true)
    }

    @Test("no stored words: the field never opens (the lane's empty state sends the user to the words box)")
    @MainActor
    func noWordsNeverOpens() throws {
        let rig = try Self.rig(lyrics: nil)
        #expect(!rig.model.canOpenField)
        #expect(rig.model.openField(noteID: rig.notes[0].id) == nil)
        #expect(rig.model.field == nil)
        #expect(rig.model.openField(selection: Set(rig.notes.map(\.id))) == nil)
    }

    @Test("a REFUSED derivation (W > N): the field opens with that sentence, cannot commit, and a blur just closes it")
    @MainActor
    func refusedDerivationField() throws {
        let rig = try Self.rig(lyrics: "one two three four five")
        let refusal = try #require(rig.model.words.refusal, "positive control: the stored words do not fit")
        #expect(rig.model.canOpenField, "the clip HAS stored words")
        rig.model.openField(noteID: rig.notes[0].id)
        #expect(rig.model.field?.canCommit == false)
        #expect(rig.model.field?.refusal == refusal)
        rig.model.setDraft("zero")
        let result = rig.model.commitField(advance: .next, write: rig.spy.write)
        #expect(result == PianoRollWordCommit(changed: false, refusal: refusal, fieldNoteID: rig.notes[0].id))
        #expect(rig.spy.calls.isEmpty, "a field that cannot commit never asks the store")
        #expect(rig.model.commitFieldOnFocusLoss(write: rig.spy.write) == .nothing)
        #expect(rig.model.field == nil)
    }

    @Test("a click on a hyphen PART opens the field on its word's FIRST note, on the whole word")
    @MainActor
    func partOpensTheFirstNote() throws {
        let rig = try Self.rig(pitches: [60, 62, 64], lyrics: "twin-kle star")
        let notes = rig.notes
        let rects = notes.map { (id: $0.id, rect: PianoRollModel.noteRect($0, rowHeight: 14, pixelsPerBeat: 64)) }
        let items = rig.model.layout(noteRects: rects, textWidths: [:])
        let kle = try #require(items.first { $0.text == "kle" }, "positive control: the part is drawn")
        #expect(kle.noteID == notes[1].id)
        #expect(rig.model.openField(wordIndex: kle.wordIndex) == notes[0].id)
        #expect(rig.model.field?.draft == "twin-kle")
        #expect(rig.model.field?.refusal == nil)
    }

    @Test("Return with notes selected opens on the EARLIEST selected melody note; a chord's lower note is never chosen")
    @MainActor
    func returnOpensTheEarliestSelectedMelodyNote() throws {
        let (store, _, clipID) = try PianoRollWordsFixture.store(pitches: [60, 62, 64], lyrics: "one two three")
        // Add a lower chord note under note 1 (beat 1): the singer sings the top note there.
        var notes = try #require(PianoRollWordsFixture.clip(store, clipID)?.notes)
        let low = MIDINote(pitch: 40, startBeat: 1, lengthBeats: 1)
        notes.append(low)
        _ = try store.setClipNotes(clipID: clipID, notes: notes)
        let model = PianoRollWordsModel()
        model.update(clip: try #require(PianoRollWordsFixture.clip(store, clipID)), tempoMap: store.transport.tempoMap,
                     leadLyrics: [])
        let top = notes[1]
        #expect(model.openField(selection: [low.id, top.id, notes[2].id]) == top.id)
        #expect(model.field?.draft == "two")
        // Only the chord note selected: the field opens there and says it is not sung.
        #expect(model.openField(selection: [low.id]) == low.id)
        #expect(model.field?.refusal == LyricEditRefusal.noteNotSung(noteID: low.id).sentence)
    }

    // MARK: Committing

    @Test("Return writes ONE word through the store's writer, closes, and reports `changed` (the roll engages on it)")
    @MainActor
    func returnCommits() throws {
        let rig = try Self.rig()
        let notes = rig.notes
        rig.model.openField(noteID: notes[1].id)
        rig.model.setDraft("big")
        let result = rig.model.commitField(advance: .none, write: rig.spy.write)
        #expect(result == PianoRollWordCommit(changed: true, refusal: nil, fieldNoteID: nil))
        #expect(rig.spy.calls.count == 1)
        #expect(rig.text == "one big three four")
        #expect(rig.store.undoLabel == ProjectStore.typeWordUndoLabel)
        #expect(rig.model.field == nil)
        #expect(rig.model.words.items.map(\.typed) == ["one", "big", "three", "four"], "derived from the stored text")

        // An unchanged field writes nothing and does not engage.
        rig.model.openField(noteID: notes[0].id)
        let none = rig.model.commitField(advance: .none, write: rig.spy.write)
        #expect(none == PianoRollWordCommit(changed: false, refusal: nil, fieldNoteID: nil))
        #expect(rig.spy.calls.count == 1, "draft == original writes nothing")
    }

    @Test("⭐ Tab / ⇧Tab walk the MELODY (chord notes skipped); Tab on the last note closes, ⇧Tab on the first too")
    @MainActor
    func tabWalksTheMelody() throws {
        let (store, _, clipID) = try PianoRollWordsFixture.store(pitches: [60, 62, 64, 65], lyrics: "a b c d")
        var notes = try #require(PianoRollWordsFixture.clip(store, clipID)?.notes)
        notes.append(MIDINote(pitch: 40, startBeat: 2, lengthBeats: 1))      // a chord note under note 2
        _ = try store.setClipNotes(clipID: clipID, notes: notes)
        let clip = try #require(PianoRollWordsFixture.clip(store, clipID))
        let model = PianoRollWordsModel()
        model.update(clip: clip, tempoMap: store.transport.tempoMap, leadLyrics: [])
        let melody = SingPlanner.melody(of: clip).notes.map(\.id)
        #expect(melody.count == 4, "positive control: the chord note is not in the melody")
        let spy = WriterSpy(store: store, clipID: clipID)

        model.openField(noteID: melody[0])
        var visited = [melody[0]]
        while let next = model.commitField(advance: .next, write: spy.write).fieldNoteID { visited.append(next) }
        #expect(visited == melody)
        #expect(model.field == nil, "Tab on the last note closes")

        model.openField(noteID: melody[3])
        var back = [melody[3]]
        while let previous = model.commitField(advance: .previous, write: spy.write).fieldNoteID { back.append(previous) }
        #expect(back == melody.reversed())
        #expect(model.field == nil, "⇧Tab on the first note closes")
        #expect(spy.calls.isEmpty, "walking without typing writes nothing")
    }

    @Test("⭐ the own-commit ECHO: Tab opens the next note on fresh words, and the store's echo neither derives nor closes it")
    @MainActor
    func ownCommitEchoKeepsTheFieldOpen() throws {
        let rig = try Self.rig()
        let notes = rig.notes
        rig.model.openField(noteID: notes[0].id)
        rig.model.setDraft("uno")
        let before = rig.model.derivationCount
        let result = rig.model.commitField(advance: .next, write: rig.spy.write)
        #expect(result.changed)
        #expect(result.fieldNoteID == notes[1].id)
        #expect(rig.model.derivationCount == before + 1, "exactly one derivation per commit")
        #expect(rig.model.field?.draft == "two", "the next note opened on FRESH words")
        #expect(rig.model.words.items.first?.typed == "uno")

        // The store's change reaches the roll one body pass later: the SAME inputs, so a no-op.
        #expect(!rig.sync(), "the echo must not derive")
        #expect(rig.model.derivationCount == before + 1)
        #expect(rig.model.field?.noteID == notes[1].id, "the echo must not close the field Tab just opened")
    }

    @Test("the echo matches a CHINESE clip too: the store keeps the language, and so does the memo")
    @MainActor
    func ownCommitEchoKeepsTheLanguage() throws {
        let (store, _, clipID) = try PianoRollWordsFixture.store(pitches: [60, 62, 64, 65], lyrics: nil)
        try store.setClipLyrics(clipId: clipID, text: "我爱你们", language: "zh", undoLabel: "Set Lyrics")
        let model = PianoRollWordsModel()
        let clip = { PianoRollWordsFixture.clip(store, clipID)! }
        model.update(clip: clip(), tempoMap: store.transport.tempoMap, leadLyrics: [])
        let spy = WriterSpy(store: store, clipID: clipID)
        model.openField(noteID: try #require(clip().notes?[0].id))
        model.setDraft("你")
        #expect(model.commitField(advance: .next, write: spy.write).changed)
        #expect(clip().lyrics?.language == "zh", "positive control: the store kept the language")
        let count = model.derivationCount
        #expect(!model.update(clip: clip(), tempoMap: store.transport.tempoMap, leadLyrics: []))
        #expect(model.derivationCount == count)
        #expect(model.field != nil)
    }

    @Test("a refused Return keeps the field OPEN with the store's sentence, and nothing is written")
    @MainActor
    func refusedReturnStaysOpen() throws {
        let rig = try Self.rig()
        let notes = rig.notes
        let textBefore = rig.text
        rig.model.openField(noteID: notes[1].id)
        rig.model.setDraft("two words")
        let result = rig.model.commitField(advance: .next, write: rig.spy.write)
        let sentence = LyricEditRefusal.wordHasSpace(word: "two words").sentence
        #expect(result == PianoRollWordCommit(changed: false, refusal: sentence, fieldNoteID: notes[1].id))
        #expect(rig.model.field?.noteID == notes[1].id, "the field stays, on the same note (Tab did not move)")
        #expect(rig.model.field?.refusal == sentence)
        #expect(rig.model.field?.draft == "two words", "what was typed is kept")
        #expect(rig.text == textBefore, "nothing written")
        #expect(rig.spy.calls.count == 1, "positive control: the store WAS asked, and refused")
    }

    @Test("a refused commit on FOCUS LOSS closes the field and hands the sentence back for the amber notice")
    @MainActor
    func refusedBlurClosesAndReturnsTheSentence() throws {
        let rig = try Self.rig()
        let textBefore = rig.text
        rig.model.openField(noteID: rig.notes[2].id)
        rig.model.setDraft("two words")
        let result = rig.model.commitFieldOnFocusLoss(write: rig.spy.write)
        #expect(result == PianoRollWordCommit(changed: false, refusal: LyricEditRefusal.wordHasSpace(word: "two words").sentence,
                                              fieldNoteID: nil))
        #expect(rig.model.field == nil, "a blur never leaves a field open")
        #expect(rig.text == textBefore)
        // And a blur with NO field open (Return or Escape already closed it) does nothing at all.
        #expect(rig.model.commitFieldOnFocusLoss(write: rig.spy.write) == .nothing)
        #expect(rig.spy.calls.count == 1)
    }

    @Test("a successful commit on focus loss writes and closes")
    @MainActor
    func blurCommits() throws {
        let rig = try Self.rig()
        rig.model.openField(noteID: rig.notes[3].id)
        rig.model.setDraft("more")
        let result = rig.model.commitFieldOnFocusLoss(write: rig.spy.write)
        #expect(result == PianoRollWordCommit(changed: true, refusal: nil, fieldNoteID: nil))
        #expect(rig.text == "one two three more")
    }

    @Test("Escape cancels: nothing written, the field closed")
    @MainActor
    func escapeCancels() throws {
        let rig = try Self.rig()
        rig.model.openField(noteID: rig.notes[0].id)
        rig.model.setDraft("zero")
        rig.model.cancelField()
        #expect(rig.model.field == nil)
        #expect(rig.spy.calls.isEmpty)
        #expect(rig.text == "one two three four")
    }

    @Test("⭐ an OUTSIDE change to the clip closes the open field WITHOUT writing (an agent, undo, a note edit)")
    @MainActor
    func outsideChangeClosesWithoutWriting() throws {
        let rig = try Self.rig()
        rig.model.openField(noteID: rig.notes[1].id)
        rig.model.setDraft("half-typed")
        // An agent changes the notes (`clip.setNotes` → `setClipNotes`), and the roll's `.onChange` runs.
        var moved = rig.notes
        moved[3].pitch = 70
        _ = try rig.store.setClipNotes(clipID: rig.clipID, notes: moved)
        #expect(rig.sync(), "positive control: the outside change is a new input")
        #expect(rig.model.field == nil, "the field closed")
        #expect(rig.spy.calls.isEmpty, "and wrote nothing")
        #expect(rig.text == "one two three four")

        // Undo of an earlier word is an outside change too.
        rig.model.openField(noteID: rig.notes[0].id)
        rig.model.setDraft("uno")
        #expect(rig.model.commitField(advance: .next, write: rig.spy.write).changed)
        rig.sync()
        #expect(rig.model.field != nil, "positive control: the echo kept the field")
        _ = try rig.store.undo()
        #expect(rig.sync())
        #expect(rig.model.field == nil, "undo closed the field")
        #expect(rig.model.words.items.first?.typed == "one", "and the lane shows the restored words")
    }

    @Test("stale: a word edit on a sung clip turns the notice on; a lead take of ANOTHER clip never does")
    @MainActor
    func staleAfterAWordEdit() throws {
        let rig = try Self.rig()
        let text = try #require(rig.text)
        let lead = Track(name: "Vocal", kind: .audio,
                         sungVocalProvenance: PianoRollWordsFixture.take(lyrics: text, from: rig.clipID))
        let other = Track(name: "Other", kind: .audio,
                          sungVocalProvenance: PianoRollWordsFixture.take(lyrics: "x", from: UUID()))
        let leads = SungWordsFreshness.leadLyrics(for: rig.clipID, in: [lead, other])
        #expect(leads == [text])
        rig.model.update(clip: rig.clip, tempoMap: rig.store.transport.tempoMap, leadLyrics: leads)
        #expect(!rig.model.isStale)
        rig.model.openField(noteID: rig.notes[0].id)
        rig.model.setDraft("uno")
        rig.model.commitField(advance: .none, write: rig.spy.write)
        #expect(rig.model.isStale, "the commit folds the new text into the freshness check at once")
    }
}

extension PianoRollWordsFixture {
    /// A sung take's record: sung from `clip` with `lyrics`, as `partRole` (nil = a take sung on its own).
    static func take(lyrics: String, from clip: UUID?, partRole: String? = nil) -> SungVocalProvenance {
        SungVocalProvenance(engineId: "fake", engineCommit: "", weightsRevision: "", facadeVersion: 1,
                            voiceId: "builtin-1", voiceName: "Built-in singer", voiceKind: "builtIn",
                            lyricsText: lyrics, sourceClipId: clip, octaveShift: 0, seed: 7, nSteps: 1, cfg: 1,
                            partRole: partRole)
    }
}
