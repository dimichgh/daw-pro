import AIServices
import CoreGraphics
import DAWAppKit
import DAWCore
import Foundation
import Testing

/// p2-sing-pr-words (design 2026-10-12 §2.4, §6.1) — the words the piano roll's Words lane draws are THE ONE
/// DERIVATION, `SingPlanner.assignment`: the answer `clip.getLyrics` gives, word for word. Never a second rule.
///
/// ⚠️ NOT `@MainActor` (the suite cap): the derivation is pure. The model's spy test is one `@MainActor` function.
@Suite("Piano roll words — the one derivation (p2-sing-pr-words)")
struct PianoRollWordsDerivationTests {

    private static let tempo = TempoMap(constantBPM: 120)

    /// What the lane and the planner must agree on, word by word.
    private struct Placed: Equatable {
        var typed: String
        var parts: [String]
        var noteIDs: [UUID]
        var held: Bool
        var phrase: Int
    }

    private static func lane(_ clip: Clip) -> [Placed] {
        PianoRollWords.derive(clip: clip, tempoMap: tempo).items.map {
            Placed(typed: $0.typed, parts: $0.parts, noteIDs: $0.noteIDs, held: $0.held, phrase: $0.phrase)
        }
    }

    private static func planner(_ clip: Clip) throws -> [Placed] {
        try SingPlanner.assignment(for: clip, tempoMap: tempo).words.map {
            Placed(typed: $0.word.typed, parts: $0.word.parts, noteIDs: $0.noteIDs, held: $0.held, phrase: $0.phrase)
        }
    }

    // MARK: Agreement with the planner

    @Test("English, one word per note: the lane's words ARE the planner's, typed text and notes")
    func englishOneWordPerNote() throws {
        let clip = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "hello big world now")
        let words = PianoRollWords.derive(clip: clip, tempoMap: Self.tempo)
        #expect(Self.lane(clip) == (try Self.planner(clip)))
        #expect(words.items.map(\.typed) == ["hello", "big", "world", "now"], "positive control: the fixture places words")
        #expect(words.items.map(\.index) == [0, 1, 2, 3])
        #expect(words.refusal == nil)
        #expect(words.melodyNoteIDs == SingPlanner.melody(of: clip).notes.map(\.id))
    }

    @Test("a held word (rule 5.2) and a typed + hold agree with the planner; only the automatic one has a sentence")
    func heldWords() throws {
        let auto = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "hi there")
        #expect(Self.lane(auto) == (try Self.planner(auto)))
        let autoWords = PianoRollWords.derive(clip: auto, tempoMap: Self.tempo)
        let holder = try #require(autoWords.items.last)
        #expect(holder.held, "the fixture must exercise rule 5.2")
        #expect(holder.noteIDs.count > 1)
        let assigned = try #require(try SingPlanner.assignment(for: auto, tempoMap: Self.tempo).words.last)
        #expect(holder.heldSentence == LyricWarning.heldWord(word: assigned.word.sung, spareNotes: assigned.heldNotes,
                                                             line: assigned.word.line).sentence)

        let typed = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "hi + there now")
        #expect(Self.lane(typed) == (try Self.planner(typed)))
        let first = try #require(PianoRollWords.derive(clip: typed, tempoMap: Self.tempo).items.first)
        #expect(first.noteIDs.count == 2, "the typed + holds the next note")
        #expect(!first.held, "a hold the user typed is not rule 5.2's")
        #expect(first.heldSentence == nil)
    }

    @Test("a hyphenated word keeps its parts, each on its own note, exactly as the planner places them")
    func hyphenated() throws {
        let clip = PianoRollWordsFixture.clip(pitches: [60, 62, 64], lyrics: "twin-kle star")
        #expect(Self.lane(clip) == (try Self.planner(clip)))
        let word = try #require(PianoRollWords.derive(clip: clip, tempoMap: Self.tempo).items.first)
        #expect(word.typed == "twin-kle")
        #expect(word.parts == ["twin", "kle"])
        #expect(word.noteIDs == Array(try #require(clip.notes).prefix(2).map(\.id)))
    }

    @Test("a Chinese clip: one character per word, the planner's way, and the language is carried")
    func chinese() throws {
        let clip = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "我爱你们", language: "zh")
        let words = PianoRollWords.derive(clip: clip, tempoMap: Self.tempo)
        #expect(Self.lane(clip) == (try Self.planner(clip)))
        #expect(words.items.map(\.typed) == ["我", "爱", "你", "们"])
        #expect(words.language == "zh")
        #expect(words.refusal == nil)
    }

    @Test("flow with fewer words than phrases: the unsung notes are the planner's")
    func flowWithUnsung() throws {
        // Two breath phrases: a full beat of rest between notes 2 and 3 (the breath rule's gap is 0.125 beats).
        let notes = [0.0, 1, 3, 4].map { MIDINote(pitch: 60, startBeat: $0, lengthBeats: 1) }
        let clip = Clip(name: "Melody", lengthBeats: 5, notes: notes, lyrics: ClipLyrics(text: "hello"))
        let words = PianoRollWords.derive(clip: clip, tempoMap: Self.tempo)
        let assignment = try SingPlanner.assignment(for: clip, tempoMap: Self.tempo)
        #expect(assignment.phraseCount == 2, "the fixture must have two phrases")
        #expect(!assignment.unsungNoteIDs.isEmpty, "positive control: some notes stay unsung")
        #expect(words.unsungNoteIDs == assignment.unsungNoteIDs)
        #expect(Self.lane(clip) == (try Self.planner(clip)))
    }

    @Test("⭐ a chord: only the TOP note is sung, so the lower note never carries a word (the melody, not clip.notes)")
    func chordNotesGetNoWord() throws {
        // Beat 1 is a chord: 64 over 60. The singer sings 64 there.
        let low = MIDINote(pitch: 60, startBeat: 1, lengthBeats: 1)
        let notes = [MIDINote(pitch: 62, startBeat: 0, lengthBeats: 1), low,
                     MIDINote(pitch: 64, startBeat: 1, lengthBeats: 1), MIDINote(pitch: 65, startBeat: 2, lengthBeats: 1)]
        let clip = Clip(name: "Chords", lengthBeats: 3, notes: notes, lyrics: ClipLyrics(text: "one two three"))
        let words = PianoRollWords.derive(clip: clip, tempoMap: Self.tempo)
        #expect(Self.lane(clip) == (try Self.planner(clip)))
        #expect(words.items.count == 3, "positive control: every word is placed")
        #expect(!words.items.contains { $0.noteIDs.contains(low.id) }, "the chord's lower note sings nothing")
        #expect(!words.melodyNoteIDs.contains(low.id))
        #expect(words.word(singing: low.id) == nil)
    }

    // MARK: Refusals and the empty state — `clip.getLyrics`'s answer

    @Test("W > N: no word is drawn and the refusal is clip.getLyrics's problem sentence")
    func tooManyWords() throws {
        let clip = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "one two three four five")
        let words = PianoRollWords.derive(clip: clip, tempoMap: Self.tempo)
        #expect(words.items.isEmpty, "never the last good words")
        #expect(words.unsungNoteIDs.isEmpty)
        let refusal = LyricRefusal.tooManyWords(words: 5, notes: 4, line: nil)
        #expect(words.refusal == SingJobError.planRefused(.lyrics(refusal)).errorDescription, "the wire's wrapper")
        #expect(words.refusal == "This line has 5 words but the tune has 4 notes. Each note sings one word, "
                + "so remove 1 word or add 1 note.")
        // The derivation itself refuses the same way (the comparison is with the planner, not a restatement).
        #expect(throws: LyricRefusal.self) { try SingPlanner.assignment(for: clip, tempoMap: Self.tempo) }
    }

    @Test("a text of only + marks has lyrics but no words: refused like clip.getLyrics, never an empty lane")
    func marksOnly() {
        let clip = PianoRollWordsFixture.clip(pitches: [60, 62], lyrics: "+")
        #expect(clip.lyrics != nil, "positive control: the clip HAS lyrics")
        let words = PianoRollWords.derive(clip: clip, tempoMap: Self.tempo)
        #expect(words.items.isEmpty)
        #expect(words.refusal == LyricRefusal.noWords.sentence)
    }

    @Test("no lyrics: no words and NO refusal (the lane's empty state); an audio clip likewise")
    func noLyrics() {
        let clip = PianoRollWordsFixture.clip(pitches: [60, 62], lyrics: nil)
        let words = PianoRollWords.derive(clip: clip, tempoMap: Self.tempo)
        #expect(words.items.isEmpty)
        #expect(words.refusal == nil)
        #expect(words.melodyNoteIDs.count == 2, "the melody is still known (Tab's order)")
        let audio = Clip(name: "Audio", audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        #expect(PianoRollWords.derive(clip: audio, tempoMap: Self.tempo) == .empty)
    }

    // MARK: Eligibility (design §2.3, F2)

    @Test("eligible: a MIDI clip on a track the SINGER sings — never on its drum rule, never an audio clip")
    func eligibility() {
        let clip = PianoRollWordsFixture.clip(pitches: [60], lyrics: "la")
        #expect(PianoRollWords.isEligible(clip: clip, on: Track(name: "Lead", kind: .instrument)))
        let drums = Track(name: "Drums", kind: .instrument, instrument: InstrumentDescriptor(kind: .drumSynth))
        #expect(ProjectTranspose.isDrumTrack(drums), "positive control: the planner calls this a drum track")
        #expect(!PianoRollWords.isEligible(clip: clip, on: drums))
        let audio = Clip(name: "Audio", audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        #expect(!PianoRollWords.isEligible(clip: audio, on: Track(name: "Vox", kind: .audio)))
    }

    // MARK: The model's spy (design §6.1 "PianoRollWordsModel spy")

    @Test("⭐ derivationCount moves ONCE per input change — never across 100 layouts or 100 unchanged updates")
    @MainActor
    func derivesOncePerInputChange() throws {
        let clip = PianoRollWordsFixture.clip(pitches: [60, 62, 64, 65], lyrics: "hello big world now")
        let model = PianoRollWordsModel()
        #expect(model.derivationCount == 0)
        #expect(model.update(clip: clip, tempoMap: Self.tempo, leadLyrics: []))
        #expect(model.derivationCount == 1)
        #expect(model.words.items.count == 4, "positive control: the model derived the fixture")

        let notes = try #require(clip.notes)
        let widths = Dictionary(uniqueKeysWithValues: PianoRollWordLane.texts(of: model.words).map { ($0, CGFloat(30)) })
        for step in 0..<100 {
            // A drag frame: the DRAFT's rects move; the clip value does not.
            let ppb = CGFloat(16 + step)
            let rects = notes.map { (id: $0.id, rect: PianoRollModel.noteRect($0, rowHeight: 14, pixelsPerBeat: ppb)) }
            #expect(!model.layout(noteRects: rects, textWidths: widths).isEmpty)
            #expect(!model.update(clip: clip, tempoMap: Self.tempo, leadLyrics: []), "an unchanged clip derives nothing")
        }
        #expect(model.derivationCount == 1, "laying out and unchanged updates must never derive")

        var moved = clip
        moved.notes?[0].pitch = 67
        #expect(model.update(clip: moved, tempoMap: Self.tempo, leadLyrics: []))
        #expect(model.derivationCount == 2, "a note change derives exactly once")
        #expect(!model.update(clip: moved, tempoMap: Self.tempo, leadLyrics: ["something"]))
        #expect(model.derivationCount == 2, "a freshness-only change derives nothing")
        #expect(model.update(clip: moved, tempoMap: TempoMap(constantBPM: 90), leadLyrics: ["something"]))
        #expect(model.derivationCount == 3, "a tempo change is an input change")
    }
}

/// Clips for the p2-sing-pr-words suites. Named for this item so it can never collide with another fixture.
enum PianoRollWordsFixture {
    /// One melody clip at beat 0, one beat per note, touching (one breath phrase), with `lyrics` (nil = none).
    static func clip(pitches: [Int], lyrics: String?, language: String? = nil) -> Clip {
        let notes = pitches.enumerated().map { i, p in MIDINote(pitch: p, startBeat: Double(i), lengthBeats: 1) }
        return Clip(name: "Melody", lengthBeats: Double(pitches.count), notes: notes,
                    lyrics: lyrics.map { ClipLyrics(text: $0, language: language) })
    }

    /// A store with one instrument track holding one melody clip (one beat per note), its lyrics stored through the
    /// store's own writer.
    @MainActor
    static func store(pitches: [Int], lyrics: String?) throws -> (store: ProjectStore, track: UUID, clip: UUID) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let notes = pitches.enumerated().map { i, p in MIDINote(pitch: p, startBeat: Double(i), lengthBeats: 1) }
        let clip = try store.addMIDIClip(toTrack: track.id, name: "Melody", atBeat: 0,
                                         lengthBeats: Double(pitches.count), notes: notes)
        if let lyrics { try store.setClipLyrics(clipId: clip.id, text: lyrics, undoLabel: "Set Lyrics") }
        return (store, track.id, clip.id)
    }

    @MainActor
    static func clip(_ store: ProjectStore, _ id: UUID) -> Clip? {
        store.tracks.lazy.flatMap(\.clips).first { $0.id == id }
    }
}
