import Foundation
import Testing
@testable import DAWCore

/// p2-sing-pr-words phase 2 (design `docs/design/2026-10-12-piano-roll-words.md` §2.8): typing or pasting a whole
/// line of words across notes is ONE new text, built word by word with the one-note edit
/// (`LyricTextEdit.applyLine`), then checked as a whole. Pure values, so NOT `@MainActor`. The store half
/// (`ProjectStore.setNoteWords`: one undo step "Type Words", all or nothing, `dryRun`, the no-op) is in
/// `LyricLineEditStoreTests.swift`, an extension of the existing `@MainActor` suite `ProjectStoreClipEditTests` (no
/// new `@Suite` there).
///
/// Layouts are written `word@[note indexes]` (indexes into the clip's notes in time order), as in
/// `LyricTextEditTests`.
@Suite("Typing a whole line across notes: one new text, word by word through the one-note edit (p2-sing-pr-words)")
struct LyricLineEditTests {

    /// 120 BPM: one beat is 0.5 s.
    static let tempo = TempoMap(constantBPM: 120)

    /// Phrases of `sizes` notes, one beat each and touching; a one-beat rest (a breath, well over 0.125 beats)
    /// between phrases.
    static func melody(_ sizes: [Int], _ text: String?, language: String? = nil) -> Clip {
        var notes: [MIDINote] = []
        var beat = 0.0
        for size in sizes {
            for _ in 0..<size {
                notes.append(MIDINote(pitch: 60 + notes.count % 12, startBeat: beat, lengthBeats: 1))
                beat += 1
            }
            beat += 1
        }
        return Clip(name: "Melody", lengthBeats: beat, notes: notes,
                    lyrics: text.map { ClipLyrics(text: $0, language: language) })
    }

    static func layout(_ a: LyricAssignment, _ clip: Clip) -> [String] {
        let index = Dictionary(uniqueKeysWithValues: clip.notes!.enumerated().map { ($1.id, $0) })
        return a.words.map { "\($0.word.typed)@\($0.noteIDs.map { index[$0]! })" }
    }

    static func before(_ clip: Clip) throws -> [String] {
        layout(try SingPlanner.assignment(for: clip, tempoMap: tempo), clip)
    }

    /// Types `words` from note `index`; returns the text and the layout. The returned assignment must BE the one
    /// derivation of the returned text, stored with the clip's language.
    static func line(_ words: [String], from index: Int, _ clip: Clip) throws -> (text: String, layout: [String]) {
        let (text, assignment) = try LyricTextEdit.applyLine(words: words, startingAt: clip.notes![index].id,
                                                             to: clip, tempoMap: tempo)
        var edited = clip
        edited.lyrics = clip.lyrics?.withText(text)
        #expect(try SingPlanner.assignment(for: edited, tempoMap: tempo) == assignment)
        return (text, layout(assignment, clip))
    }

    static func refusal(_ words: [String], startingAt noteID: UUID, _ clip: Clip) -> LyricLineEditRefusal? {
        do throws(LyricLineEditRefusal) {
            _ = try LyricTextEdit.applyLine(words: words, startingAt: noteID, to: clip, tempoMap: tempo)
            return nil
        } catch {
            return error
        }
    }

    static func refusal(_ words: [String], from index: Int, _ clip: Clip) -> LyricLineEditRefusal? {
        refusal(words, startingAt: clip.notes![index].id, clip)
    }

    // MARK: - Lines

    @Test("a line of N words on N notes: each word on its own note, in order")
    func lineOnEveryNote() throws {
        let clip = Self.melody([4], "one two three four")
        let all = try Self.line(["uno", "dos", "tres", "cuatro"], from: 0, clip)
        #expect(all.text == "uno dos tres cuatro")
        #expect(all.layout == ["uno@[0]", "dos@[1]", "tres@[2]", "cuatro@[3]"])
        let middle = try Self.line(["big", "red"], from: 1, clip)
        #expect(middle.text == "one big red four")
        #expect(middle.layout == ["one@[0]", "big@[1]", "red@[2]", "four@[3]"])
    }

    @Test("a line that crosses a held (+) word: one word per note; the held word is split, never moved")
    func lineCrossesAHeldWord() throws {
        let clip = Self.melody([5], "one love + + two")
        #expect(try Self.before(clip) == ["one@[0]", "love@[1, 2, 3]", "two@[4]"], "control: love holds three notes")
        let across = try Self.line(["I", "need", "you", "so"], from: 0, clip)
        #expect(across.text == "I need you so two")
        #expect(across.layout == ["I@[0]", "need@[1]", "you@[2]", "so@[3]", "two@[4]"])
        // Ending on the held word's FIRST note: the last word keeps its held notes (the one-note edit's rule).
        let short = try Self.line(["I", "need"], from: 0, clip)
        #expect(short.text == "I need + + two")
        #expect(short.layout == ["I@[0]", "need@[1, 2, 3]", "two@[4]"])
        // Starting INSIDE the held word: it keeps the notes before the line.
        let inside = try Self.line(["you", "so"], from: 2, clip)
        #expect(inside.text == "one love you so two")
        #expect(inside.layout == ["one@[0]", "love@[1]", "you@[2]", "so@[3]", "two@[4]"])
    }

    @Test("+ (or an empty word) in a line holds the word before onto that note, as in the one-note field")
    func lineHolds() throws {
        let clip = Self.melody([4], "a b c d")
        let held = try Self.line(["la", "+", "di"], from: 0, clip)
        #expect(held.text == "la + di d")
        #expect(held.layout == ["la@[0, 1]", "di@[2]", "d@[3]"])
        #expect(try Self.line(["la", "", "di"], from: 0, clip).text == "la + di d")
    }

    @Test("a line runs on across a breath into the next line of the tune")
    func lineAcrossABreath() throws {
        let clip = Self.melody([3, 3], "a b c\nd e f")
        let out = try Self.line(["x", "y", "z"], from: 1, clip)
        #expect(out.text == "a x y\nz e f")
        #expect(out.layout == ["a@[0]", "x@[1]", "y@[2]", "z@[3]", "e@[4]", "f@[5]"])
    }

    @Test("hyphenated parts: one note per part, and the next word goes on the note after them")
    func hyphenatedParts() throws {
        let clip = Self.melody([4], "a + b c")
        #expect(try Self.before(clip) == ["a@[0, 1]", "b@[2]", "c@[3]"], "control: a's slot spans two notes")
        let out = try Self.line(["twin-kle", "star"], from: 0, clip)
        #expect(out.text == "twin-kle star c")
        #expect(out.layout == ["twin-kle@[0, 1]", "star@[2]", "c@[3]"])

        // On a held word's later note: the word before keeps its first note, the parts take the rest.
        let held = Self.melody([5], "a b + + c")
        let split = try Self.line(["x", "twin-kle"], from: 1, held)
        #expect(split.text == "a x twin-kle c")
        #expect(split.layout == ["a@[0]", "x@[1]", "twin-kle@[2, 3]", "c@[4]"])

        // Known limit v1 (design §2.8): a word that sings ONE note cannot take a hyphenated word's two parts.
        let narrow = Self.melody([4], "a b c d")
        #expect(Self.refusal(["twin-kle"], from: 0, narrow)
                == .word(index: 0, word: "twin-kle", refusal: .lyrics(.markedWordDoesNotFit(word: "twinkle", needed: 2))))

        // Parts count as notes: 3 words fit 4 notes, but their 5 parts do not.
        let over = Self.refusal(["twin-kle", "lit-tle", "star"], from: 0, clip)
        #expect(over == .lineNeedsMoreNotes(needed: 5, notes: 4))
        #expect(over?.sentence == "Each part of a hyphenated word takes a note of its own, so these words need 5 notes, "
                + "but only 4 are left from here. Remove a word or a hyphen, or add notes.")
    }

    @Test("Chinese: one character per note, cut the way the clip reads it; the clip stays Chinese")
    func chineseOneCharacterPerNote() throws {
        #expect(LyricTextEdit.lineWords("亮晶晶", language: "zh") == ["亮", "晶", "晶"])
        #expect(LyricTextEdit.lineWords("一闪，一闪 +", language: "zh") == ["一", "闪，", "一", "闪", "+"])
        #expect(LyricTextEdit.lineWords("一闪", language: nil) == ["一闪"], "an English clip cuts at whitespace only")
        #expect(LyricTextEdit.lineWords("  twin-kle\tlittle\nstar ", language: nil) == ["twin-kle", "little", "star"])

        let clip = Self.melody([4], "一闪一闪", language: "zh")
        let words = LyricTextEdit.lineWords("亮晶晶", language: "zh")
        let (text, assignment) = try LyricTextEdit.applyLine(words: words, startingAt: clip.notes![1].id, to: clip,
                                                             tempoMap: Self.tempo)
        #expect(text == "一亮晶晶")
        #expect(Self.layout(assignment, clip) == ["一@[0]", "亮@[1]", "晶@[2]", "晶@[3]"])
        #expect(assignment.words.map { $0.word.language } == ["zh", "zh", "zh", "zh"])

        // control: the same characters as ONE element are refused like the one-note field refuses them.
        #expect(Self.refusal(["亮晶晶"], from: 1, clip)
                == .word(index: 0, word: "亮晶晶", refusal: .wordHasSpace(word: "亮晶晶")))
        // Characters typed into an English clip: refused, naming the word.
        let english = Self.melody([4], "a b c d")
        #expect(Self.refusal(["亮"], from: 0, english)
                == .word(index: 0, word: "亮", refusal: .lyrics(.scriptMismatch(word: "亮"))))
    }

    @Test("the line goes on the melody: a chord's lower note never gets a word, and cannot start a line")
    func chordNotesAreSkipped() throws {
        let low = MIDINote(pitch: 60, startBeat: 1, lengthBeats: 1)
        let notes = [MIDINote(pitch: 62, startBeat: 0, lengthBeats: 1), low,
                     MIDINote(pitch: 67, startBeat: 1, lengthBeats: 1), MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1)]
        let clip = Clip(name: "Chords", lengthBeats: 3, notes: notes, lyrics: ClipLyrics(text: "a b c"))
        let (text, assignment) = try LyricTextEdit.applyLine(words: ["x", "y", "z"], startingAt: notes[0].id,
                                                             to: clip, tempoMap: Self.tempo)
        #expect(text == "x y z")
        #expect(assignment.words.map { $0.noteIDs } == [[notes[0].id], [notes[2].id], [notes[3].id]])
        #expect(Self.refusal(["x"], startingAt: low.id, clip) == .cannotStart(.noteNotSung(noteID: low.id)))
    }

    // MARK: - Refusals

    @Test("too many words for the notes left: the design's sentence; the notes left run on to the clip's end")
    func tooManyWords() {
        let clip = Self.melody([4], "a b c d")
        let six = Self.refusal(["one", "two", "three", "four", "five", "six"], from: 0, clip)
        #expect(six == .lineLongerThanNotes(words: 6, notes: 4))
        #expect(six?.sentence == "You typed 6 words but only 4 notes are left from here. Remove 2 words, or add notes.")
        let two = Self.refusal(["one", "two"], from: 3, clip)
        #expect(two?.sentence == "You typed 2 words but only 1 note is left from here. Remove 1 word, or add notes.")
        // Past a breath, to the clip's end.
        let phrases = Self.melody([2, 2], "a b\nc d")
        #expect(Self.refusal(["w", "x", "y", "z"], from: 1, phrases) == .lineLongerThanNotes(words: 4, notes: 3))
        #expect(Self.refusal(["w", "x", "y"], from: 1, phrases) == nil, "control: exactly the notes left fits")
    }

    @Test("a refusal names the word that cannot go on its note")
    func refusalNamesTheWord() throws {
        let clip = Self.melody([4], "a b c d")
        let foreign = Self.refusal(["la", "café", "di"], from: 0, clip)
        #expect(foreign == .word(index: 1, word: "café", refusal: .lyrics(.notEnglish(word: "café"))))
        #expect(foreign?.sentence == "I couldn't put 'café' on its note. "
                + "I can only sing English words so far — 'café' isn't one I can pronounce.")
        #expect(Self.refusal(["la", "star+"], from: 0, clip)
                == .word(index: 1, word: "star+", refusal: .wordHasMarks(word: "star+")))
        #expect(Self.refusal([" two words "], from: 0, clip)
                == .word(index: 0, word: "two words", refusal: .wordHasSpace(word: "two words")))

        // A + on the first note of a line of the tune has no word before it to hold.
        let phrases = Self.melody([2, 2], "a b\nc d")
        #expect(Self.refusal(["+"], from: 2, phrases)
                == .word(index: 0, word: "+", refusal: .nothingToHold(noteID: phrases.notes![2].id)))
        #expect(Self.refusal([""], from: 2, phrases)?.sentence.hasPrefix("I couldn't put '+' on its note.") == true,
                "an empty word reads as the + it means")

        // A line that runs into a part of the tune no word reaches yet. Two words on three lines of the tune: the
        // assigner leaves the MIDDLE one silent (MEASURED on [2, 2, 2] in this suite's first run; the control
        // re-checks it on this fixture).
        let silent = Self.melody([1, 1, 1], "a b")
        let ids = try #require(silent.notes).map { $0.id }
        #expect(try SingPlanner.assignment(for: silent, tempoMap: Self.tempo).unsungNoteIDs == [ids[1]],
                "control: the middle line of the tune is silent")
        #expect(Self.refusal(["x", "y"], from: 0, silent)
                == .word(index: 1, word: "y", refusal: .noteNotSung(noteID: ids[1])))
        // Starting on a silent note: nothing to type over.
        #expect(Self.refusal(["x"], from: 1, silent) == .cannotStart(.noteNotSung(noteID: ids[1])))
        // Splitting a held word adds a word; with as many words as lines of the tune the silent line would get one,
        // so words would move: the one-note edit's own round trip refuses, and the line names the word.
        let held = Self.melody([2, 2, 2], "a b")
        #expect(Self.refusal(["x", "y"], from: 0, held) == .word(index: 1, word: "y", refusal: .unstable))
    }

    @Test("nothing can start: a note not in the clip, an empty line, no words yet, an audio clip, words that do not fit")
    func cannotStart() {
        let clip = Self.melody([4], "a b c d")
        let stray = UUID()
        #expect(Self.refusal(["la"], startingAt: stray, clip) == .cannotStart(.noteNotFound(noteID: stray)))
        #expect(Self.refusal([], from: 0, clip) == .noWords)
        #expect(Self.refusal(["la"], from: 0, Self.melody([4], nil)) == .cannotStart(.noText))
        let audio = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/prwc-never-read.wav"))
        #expect(Self.refusal(["la"], startingAt: UUID(), audio) == .cannotStart(.needsMIDIClip))
        // The words as they are do not fit the notes: the assigner's own refusal, nothing to type on.
        let crowded = Self.refusal(["la"], from: 0, Self.melody([2], "a b c"))
        guard case .cannotStart(.lyrics(.tooManyWords(let words, let notes, _))) = crowded else {
            Issue.record("expected the assigner's W > N refusal, got \(String(describing: crowded))")
            return
        }
        #expect(words == 3 && notes == 2)
    }

    @Test("every refusal has a sentence, and an error screen shows that same sentence")
    func everyRefusalHasASentence() {
        let all: [LyricLineEditRefusal] = [
            .cannotStart(.noText), .noWords, .lineLongerThanNotes(words: 6, notes: 4),
            .lineNeedsMoreNotes(needed: 5, notes: 4),
            .word(index: 0, word: "café", refusal: .lyrics(.notEnglish(word: "café"))), .unstable,
        ]
        for refusal in all {
            #expect(!refusal.sentence.isEmpty)
            #expect(refusal.errorDescription == refusal.sentence)
            #expect((refusal as any Error).localizedDescription == refusal.sentence)
        }
        #expect(LyricLineEditRefusal.cannotStart(.noText).sentence == LyricEditRefusal.noText.sentence)
    }

    // MARK: - The round trip, and the no-op

    @Test("the round trip: every word with no note under the line sings exactly the notes it sang, in every mode")
    func roundTrip() throws {
        let cases: [(sizes: [Int], text: String, words: [String], from: Int)] = [
            ([3, 4], "hello world one two three", ["x", "y"], 2),          // flow, with spare notes
            ([3, 3], "a b c\nd e f", ["x", "y"], 4),                       // one line per phrase
            ([5], "one love + + two", ["x", "y"], 2),                     // inside a held word
            ([2, 2, 2], "a b", ["x"], 0),                                  // flow, a silent phrase
            ([2, 3, 2], "la la la la la la la", ["la", "di", "da"], 3),   // the same word many times
        ]
        for c in cases {
            let clip = Self.melody(c.sizes, c.text)
            let before = try SingPlanner.assignment(for: clip, tempoMap: Self.tempo)
            let start = clip.notes![c.from].id
            let (text, after) = try LyricTextEdit.applyLine(words: c.words, startingAt: start, to: clip,
                                                            tempoMap: Self.tempo)
            var edited = clip
            edited.lyrics = ClipLyrics(text: text)
            #expect(try SingPlanner.assignment(for: edited, tempoMap: Self.tempo) == after, "the one derivation")
            #expect(after.mode == before.mode && after.unsungNoteIDs == before.unsungNoteIDs, "\(c.text)")

            let melody = SingPlanner.melody(of: clip).notes.map { $0.id }
            let first = try #require(melody.firstIndex(of: start))
            let under = Set(melody[first..<(first + c.words.count)])
            let outside = before.words.filter { under.isDisjoint(with: $0.noteIDs) }
            #expect(!outside.isEmpty, "control: \(c.text) has words the line does not touch")
            for word in outside {
                #expect(after.words.contains {
                    $0.word.typed == word.word.typed && $0.noteIDs == word.noteIDs && $0.phrase == word.phrase
                }, "\(c.text): '\(word.word.typed)' kept exactly its notes")
            }
            for (i, typed) in c.words.enumerated() {
                let sung = after.words.first { $0.noteIDs.first == melody[first + i] }
                #expect(sung?.word.typed == typed, "\(c.text): '\(typed)' starts on its own note")
            }
        }
    }

    @Test("a line that types the words the notes already sing returns the text unchanged, byte for byte")
    func noOpLine() throws {
        let clip = Self.melody([4], "one two three four")
        let same = try Self.line(["two", "three"], from: 1, clip)
        #expect(Array(same.text.utf8) == Array("one two three four".utf8))

        let held = Self.melody([4], "hello world")
        #expect(try Self.before(held) == ["hello@[0, 1]", "world@[2, 3]"], "control: each word holds a spare note")
        let kept = try Self.line(["hello", "+", "world", "+"], from: 0, held)
        #expect(Array(kept.text.utf8) == Array("hello world".utf8))
        #expect(try Self.line(["hello", "+", "earth", "+"], from: 0, held).text != "hello world",
                "control: one different word is a change")
    }
}
