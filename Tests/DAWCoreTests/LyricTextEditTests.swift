import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x1: typing a word onto one note is an edit of the clip's TEXT
/// (`LyricTextEdit`, design `docs/design/2026-10-06-p2-sing-expansion.md`
/// §3.2), checked by deriving the words again. Pure values, so NOT
/// `@MainActor`. The store method (`ProjectStore.setNoteWord`, one undo step
/// "Type Word", `dryRun`) is pinned in `LyricTextEditStoreTests.swift`, an
/// extension of the existing `ProjectStoreClipEditTests` suite.
///
/// Layouts are written `word@[note indexes]` (indexes into the clip's notes
/// in time order), so each table row reads like the strip of word chips.
@Suite("Typing a word onto one note: a text edit the words are derived from again (p2-sing-x1)")
struct LyricTextEditTests {

    /// 120 BPM: one beat is 0.5 s.
    static let tempo = TempoMap(constantBPM: 120)

    /// Phrases of `sizes` notes, one beat each and touching; a one-beat rest
    /// (a breath, well over 0.125 beats) between phrases.
    static func melody(_ sizes: [Int], _ text: String?) -> Clip {
        var notes: [MIDINote] = []
        var beat = 0.0
        for size in sizes {
            for _ in 0..<size {
                notes.append(MIDINote(pitch: 60 + notes.count % 12, startBeat: beat, lengthBeats: 1))
                beat += 1
            }
            beat += 1
        }
        return Clip(name: "Melody", lengthBeats: beat, notes: notes, lyrics: text.map { ClipLyrics(text: $0) })
    }

    static func note(_ clip: Clip, _ index: Int) -> UUID { clip.notes![index].id }

    static func layout(_ a: LyricAssignment, _ clip: Clip) -> [String] {
        let index = Dictionary(uniqueKeysWithValues: clip.notes!.enumerated().map { ($1.id, $0) })
        return a.words.map { "\($0.word.typed)@\($0.noteIDs.map { index[$0]! })" }
    }

    static func before(_ clip: Clip) throws -> [String] {
        layout(try SingPlanner.assignment(for: clip, tempoMap: tempo), clip)
    }

    /// Applies `word` (`""` clears) on note `index`; returns the text and layout.
    static func type(_ word: String, on index: Int, _ clip: Clip) throws -> (text: String, layout: [String]) {
        let (text, assignment) = try LyricTextEdit.apply(.typed(word, onNote: note(clip, index)), to: clip,
                                                         tempoMap: tempo)
        // The returned assignment IS the one derivation of the returned text.
        var edited = clip
        edited.lyrics = ClipLyrics(text: text)
        #expect(try SingPlanner.assignment(for: edited, tempoMap: tempo) == assignment)
        return (text, layout(assignment, clip))
    }

    static func refusal(_ edit: LyricNoteEdit, _ clip: Clip) -> LyricEditRefusal? {
        do throws(LyricEditRefusal) {
            _ = try LyricTextEdit.apply(edit, to: clip, tempoMap: tempo)
            return nil
        } catch {
            return error
        }
    }

    static func refusal(_ word: String, on index: Int, _ clip: Clip) -> LyricEditRefusal? {
        refusal(.typed(word, onNote: note(clip, index)), clip)
    }

    // MARK: - The table (design §3.5)

    @Test("replace a word at its first note: only that word changes")
    func replaceAtWordStart() throws {
        let clip = Self.melody([3], "one two three")
        #expect(try Self.before(clip) == ["one@[0]", "two@[1]", "three@[2]"])
        let out = try Self.type("four", on: 1, clip)
        #expect(out.text == "one four three")
        #expect(out.layout == ["one@[0]", "four@[1]", "three@[2]"])
    }

    @Test("type on a note a word holds by itself (a spare note): the word keeps the notes before it, the new word takes the rest")
    func splitAHeldNote() throws {
        let clip = Self.melody([4], "hello world")
        // Rule 5.1 gives "hello" (2 syllables) a spare note; rule 5.2 holds "world" across the last.
        #expect(try Self.before(clip) == ["hello@[0, 1]", "world@[2, 3]"])
        let mid = try Self.type("big", on: 1, clip)
        #expect(mid.text == "hello big world +", "the freeze wrote world's + mark: the box now shows why it holds")
        #expect(mid.layout == ["hello@[0]", "big@[1]", "world@[2, 3]"])
        let last = try Self.type("now", on: 3, clip)
        #expect(last.text == "hello + world now")
        #expect(last.layout == ["hello@[0, 1]", "world@[2]", "now@[3]"])
    }

    @Test("type on a + note: the + that sang it becomes the new word")
    func typeOnAPlusNote() throws {
        let clip = Self.melody([3], "la + la")
        #expect(try Self.before(clip) == ["la@[0, 1]", "la@[2]"])
        let out = try Self.type("di", on: 1, clip)
        #expect(out.text == "la di la")
        #expect(out.layout == ["la@[0]", "di@[1]", "la@[2]"])
    }

    @Test("clear a word, or type +: the word before holds on")
    func clearAndPlus() throws {
        let clip = Self.melody([3], "one two three")
        let cleared = try Self.type("", on: 1, clip)
        #expect(cleared.text == "one + three")
        #expect(cleared.layout == ["one@[0, 1]", "three@[2]"])
        let plus = try Self.type("+", on: 1, clip)
        #expect(plus == cleared)
        let tilde = try Self.type(" +~ ", on: 1, clip)
        #expect(tilde == cleared, "OpenUtau's +~ means the same, and spaces around are trimmed")
        // A word on more than one note loses only its first note.
        let held = Self.melody([3], "star! moon")
        #expect(try Self.before(held) == ["star!@[0]", "moon@[1, 2]"])
        let out = try Self.type("", on: 1, held)
        #expect(out.text == "star! + moon", "the mark goes after the word's own punctuation")
        #expect(out.layout == ["star!@[0, 1]", "moon@[2]"])
    }

    @Test("+ on a note that is already held, or the same word again, changes nothing: the text comes back as it was")
    func noOps() throws {
        let plus = Self.melody([3], "la + la")
        let out = try Self.type("+", on: 1, plus)
        #expect(out.text == "la + la")
        let held = Self.melody([4], "hello world")
        let again = try Self.type("hello", on: 0, held)
        #expect(again.text == "hello world", "no freeze marks for an edit that changes nothing")
        let clearHeld = try Self.type("", on: 3, held)
        #expect(clearHeld.text == "hello world")
    }

    @Test("words with hyphen parts: typed onto a word, typed over one, and the notes a hyphenated word needs")
    func hyphenParts() throws {
        // A hyphenated word typed on a word that sings two notes.
        let two = Self.melody([4], "hello world")
        let typed = try Self.type("twin-kle", on: 0, two)
        #expect(typed.text == "twin-kle world +")
        #expect(typed.layout == ["twin-kle@[0, 1]", "world@[2, 3]"])
        // A plain word typed over a hyphenated one keeps its notes with a +.
        let hyphenated = Self.melody([3], "twin-kle star")
        #expect(try Self.before(hyphenated) == ["twin-kle@[0, 1]", "star@[2]"])
        let over = try Self.type("moon", on: 0, hyphenated)
        #expect(over.text == "moon + star")
        #expect(over.layout == ["moon@[0, 1]", "star@[2]"])
        // "+" on the second part: already that word's note.
        #expect(try Self.type("+", on: 1, hyphenated).text == "twin-kle star")
        // A word on one of a hyphenated word's own parts: refused, with a sentence.
        let inside = Self.refusal("moon", on: 1, hyphenated)
        #expect(inside == .noteInsideHyphenatedWord(word: "twin-kle"))
        #expect(inside?.sentence == "This note sings part of 'twin-kle'. To change it, edit 'twin-kle' in the words box.")
        let lead = Self.melody([3], "la twin-kle")
        #expect(Self.refusal("", on: 1, lead) == .noteInsideHyphenatedWord(word: "twin-kle"),
                "clearing a hyphenated word's first note would leave it fewer notes than parts")
        // A hyphenated word needs a note per part.
        let short = Self.refusal("twin-kle", on: 1, Self.melody([3], "one two three"))
        #expect(short == .lyrics(.markedWordDoesNotFit(word: "twinkle", needed: 2)))
        #expect(short?.sentence == "'twinkle' needs 2 notes without a breath in between, and the tune has no room "
                + "for that. Remove some of its + marks or hyphens.")
    }

    @Test("punctuation and line breaks stay with the words they follow")
    func punctuationAndLineBreaks() throws {
        let clip = Self.melody([3, 3], "Oh, say\ncan you see")
        #expect(try Self.before(clip) == ["Oh,@[0]", "say@[1, 2]", "can@[3]", "you@[4]", "see@[5]"])
        let out = try Self.type("yeah", on: 2, clip)
        #expect(out.text == "Oh, say yeah\ncan you see")
        #expect(out.layout == ["Oh,@[0]", "say@[1]", "yeah@[2]", "can@[3]", "you@[4]", "see@[5]"])
        let star = Self.melody([7, 4], "Twin-kle, twin-kle, lit-tle star!\r\nHow I won-der")
        let swapped = try Self.type("you", on: 8, star)
        #expect(swapped.text == "Twin-kle, twin-kle, lit-tle star!\r\nHow you won-der")
        let curly = try Self.type("don’t", on: 1, Self.melody([3], "one two three"))
        #expect(curly.text == "one don’t three", "the word goes in exactly as typed")
        #expect(curly.layout == ["one@[0]", "don't@[1]", "three@[2]"])
    }

    @Test("an edit on one line of the tune leaves every other line byte-identical (linePerPhrase)")
    func otherLinesByteIdentical() throws {
        let clip = Self.melody([4, 3], "hello world\nlet it be")
        #expect(try Self.before(clip) == ["hello@[0, 1]", "world@[2, 3]", "let@[4]", "it@[5]", "be@[6]"])
        let second = try Self.type("us", on: 5, clip)
        #expect(second.text == "hello world\nlet us be", "line 1 was not frozen: no marks appear on it")
        let first = try Self.type("big", on: 1, clip)
        #expect(first.text == "hello big world +\nlet it be")
        #expect(first.text.split(separator: "\n", omittingEmptySubsequences: false).last == "let it be")
    }

    @Test("a linePerPhrase text stays in that mode")
    func staysLinePerPhrase() throws {
        let clip = Self.melody([4, 3], "hello world\nlet it be")
        for (word, index) in [("big", 1), ("", 2), ("+", 5), ("now", 3)] {
            let (_, assignment) = try LyricTextEdit.apply(.typed(word, onNote: Self.note(clip, index)), to: clip,
                                                          tempoMap: Self.tempo)
            #expect(assignment.mode == .linePerPhrase, "\(word.debugDescription) on \(index)")
        }
    }

    @Test("flow mode: every word is frozen, so marks added for one line of the tune cannot move words on another")
    func flowFreezesEveryWord() throws {
        // Flow (1 text line, 2 phrases). "a" alone on phrase 0 holds a spare note; "c" holds one in phrase 1.
        let clip = Self.melody([2, 3], "a b c")
        #expect(try Self.before(clip) == ["a@[0, 1]", "b@[2]", "c@[3, 4]"])
        let out = try Self.type("d", on: 4, clip)
        // Freezing only phrase 1 ("a b c d") would raise the words' total and pull "b" into phrase 0.
        #expect(out.text == "a + b c d")
        #expect(out.layout == ["a@[0, 1]", "b@[2]", "c@[3]", "d@[4]"])
        var onlyPhraseOne = clip
        onlyPhraseOne.lyrics = ClipLyrics(text: "a b c d")
        #expect(try Self.before(onlyPhraseOne) == ["a@[0]", "b@[1]", "c@[2]", "d@[3, 4]"],
                "control: the one-phrase freeze would have moved b and c")
    }

    // MARK: - Every refusal, with its sentence

    @Test("refusals about the clip and the note, each with its sentence")
    func clipAndNoteRefusals() throws {
        let audio = Clip(name: "Vox", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x1-not-read.wav"))
        let onAudio = Self.refusal(.setWord(noteID: UUID(), word: "la"), audio)
        #expect(onAudio == .needsMIDIClip)
        #expect(onAudio?.sentence == "Sing needs a melody clip with notes. This one is audio.")

        let bare = Self.melody([3], nil)
        #expect(Self.refusal("la", on: 0, bare) == .noText)
        #expect(Self.refusal("la", on: 0, bare)?.sentence
                == "Type the words in the box first; then you can change single notes.")
        #expect(Self.refusal("la", on: 0, Self.melody([3], "!!! ...")) == .noText, "punctuation only: no words")

        let stray = UUID()
        #expect(Self.refusal(.setWord(noteID: stray, word: "la"), Self.melody([3], "la")) == .noteNotFound(noteID: stray))
        #expect(LyricEditRefusal.noteNotFound(noteID: stray).sentence == "I couldn't find that note in this clip.")

        let notSung = "This note isn't sung: it is part of a chord, or no words reach this line yet."
        // A chord: the lower note is dropped by the one-note-at-a-time rule.
        let low = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let chord = Clip(name: "Chord", lengthBeats: 2, notes: [low, MIDINote(pitch: 64, startBeat: 0, lengthBeats: 1),
                                                                MIDINote(pitch: 62, startBeat: 1, lengthBeats: 1)],
                         lyrics: ClipLyrics(text: "la la"))
        #expect(Self.refusal(.setWord(noteID: low.id, word: "oh"), chord) == .noteNotSung(noteID: low.id))
        #expect(Self.refusal(.setWord(noteID: low.id, word: "oh"), chord)?.sentence == notSung)
        // A line of the tune the words do not reach (flow mode, fewer words than lines).
        let silent = Self.melody([1, 1], "one")
        #expect(try Self.before(silent) == ["one@[0]"])
        #expect(Self.refusal("two", on: 1, silent) == .noteNotSung(noteID: Self.note(silent, 1)))
        // A note past the clip's end does not play, so it is not sung.
        let late = MIDINote(pitch: 60, startBeat: 3, lengthBeats: 1)
        let short = Clip(name: "Short", lengthBeats: 2, notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1), late],
                         lyrics: ClipLyrics(text: "la"))
        #expect(Self.refusal(.setWord(noteID: late.id, word: "oh"), short) == .noteNotSung(noteID: late.id))
    }

    @Test("refusals about the typed word, each with its sentence")
    func wordRefusals() {
        let clip = Self.melody([3], "one two three")
        for word in ["two words", "wait...what", "a/b", "line\nbreak"] {
            #expect(Self.refusal(word, on: 1, clip) == .wordHasSpace(word: word), "\(word.debugDescription)")
        }
        #expect(LyricEditRefusal.wordHasSpace(word: "a b").sentence
                == "Type one word per note. To type several, use the words box.")
        for word in ["star+", "+star", "++"] {
            #expect(Self.refusal(word, on: 1, clip) == .wordHasMarks(word: word), "\(word)")
        }
        #expect(LyricEditRefusal.wordHasMarks(word: "star+").sentence
                == "Type the word without + marks. To hold the word before onto this note, type just +.")
        for word in ["!", "—"] {
            #expect(Self.refusal(word, on: 1, clip) == .wordHasNoLetters(word: word), "\(word)")
        }
        #expect(LyricEditRefusal.wordHasNoLetters(word: "!").sentence
                == "Type a word with letters or numbers, or type + to hold the word before onto this note.")
        let foreign = Self.refusal("café", on: 1, clip)
        #expect(foreign == .lyrics(.notEnglish(word: "café")))
        #expect(foreign?.sentence == "I can only sing English words so far — 'café' isn't one I can pronounce.")
    }

    @Test("refusals about where the word would go, each with its sentence")
    func placementRefusals() {
        // The text as it is does not fit the notes: the assigner's own refusal and sentence
        // (one text line on one phrase is line-per-phrase, so the refusal names line 0).
        let tooMany = Self.refusal("la", on: 0, Self.melody([3], "a b c d"))
        #expect(tooMany == .lyrics(.tooManyWords(words: 4, notes: 3, line: 0)))
        #expect(tooMany?.sentence == "This line has 4 words but the tune has 3 notes. Each note sings one word, "
                + "so remove 1 word or add 1 note.")
        // + on the first note of a line of the tune, or of the clip.
        let lines = Self.melody([2, 2], "one two\nthree four")
        #expect(Self.refusal("+", on: 2, lines) == .nothingToHold(noteID: Self.note(lines, 2)))
        #expect(Self.refusal("", on: 0, lines) == .nothingToHold(noteID: Self.note(lines, 0)))
        #expect(LyricEditRefusal.nothingToHold(noteID: UUID()).sentence
                == "This note starts a new line of the tune, so there's no word before it to hold. Type a word instead.")
        // Flow mode with a silent line of the tune: a third word lets the words reach it, so the others would move.
        let silent = Self.melody([2, 1, 1], "hello there")
        #expect((try? Self.before(silent)) == ["hello@[0, 1]", "there@[2]"])
        let moved = Self.refusal("big", on: 1, silent)
        #expect(moved == .unstable)
        #expect(moved?.sentence == "I couldn't place that word without moving others. Type the line in the box instead.")
        // Over the length limit once the freeze and the word are written.
        let long = Self.melody([3], "hello" + String(repeating: "!", count: 3_990))
        let over = Self.refusal("word", on: 2, long)
        #expect(over == .tooLong(characters: 4_002))
        #expect(over?.sentence == "The words can be up to 4,000 characters long, and this would go over. Shorten them first.")
        #expect(LyricEditRefusal.grouped(4_000) == "4,000")
        #expect(LyricEditRefusal.grouped(999) == "999")
        #expect(LyricEditRefusal.grouped(1_234_567) == "1,234,567")
    }

    @Test("the edit kinds the wire's word maps to")
    func typedShapes() {
        let id = UUID()
        #expect(LyricNoteEdit.typed("", onNote: id) == .clearWord(noteID: id))
        #expect(LyricNoteEdit.typed("  ", onNote: id) == .clearWord(noteID: id))
        #expect(LyricNoteEdit.typed("+", onNote: id) == .setWord(noteID: id, word: "+"))
        #expect(LyricNoteEdit.typed("la", onNote: id) == .setWord(noteID: id, word: "la"))
        #expect(LyricNoteEdit.typed("la", onNote: id).noteID == id)
    }

    // MARK: - The round-trip property (design §3.5)

    /// One word as the property compares it: what is sung, where, on which notes.
    struct Shape: Equatable, CustomStringConvertible {
        var typed: String
        var sung: String
        var parts: [String]
        var line: Int
        var phrase: Int
        var noteIDs: [UUID]
        var description: String { "\(typed)@\(noteIDs.count)" }
    }

    enum Expected: Equatable {
        case unchanged
        case words([Shape])
        case refused(LyricEditRefusal)
    }

    static let plainWords = ["la", "star", "hello", "twinkle", "beautiful", "everything", "42", "don't", "don’t", "&",
                             "love", "a", "the", "moon", "yeah", "oh", "night,", "light!", "sky.", "3.5"]
    static let hyphenatedWords = ["twin-kle", "lit-tle", "ev-er-y", "a-way", "3-2-1"]
    /// Typed words with the refusal they must get, whatever the note.
    static let invalidWords: [String: LyricEditRefusal] = [
        "a b": .wordHasSpace(word: "a b"), "wait...what": .wordHasSpace(word: "wait...what"),
        "!": .wordHasNoLetters(word: "!"), "star+": .wordHasMarks(word: "star+"),
        "café": .lyrics(.notEnglish(word: "café")),
    ]

    /// What the property expects, worked out here from the assignment before the
    /// edit and the edit alone (design §3.2's rule), never from `apply`'s code.
    static func expected(_ edit: LyricNoteEdit, _ before: LyricAssignment) -> Expected {
        var word = ""
        if case .setWord(_, let typed) = edit { word = typed.trimmingCharacters(in: .whitespaces) }
        if let refusal = invalidWords[word] { return .refused(refusal) }
        let n = edit.noteID
        guard let k = before.words.firstIndex(where: { $0.noteIDs.contains(n) }) else {
            return .refused(.noteNotSung(noteID: n))
        }
        let slot = before.words[k]
        let j = slot.noteIDs.firstIndex(of: n)!
        let count = slot.noteIDs.count
        let parts = max(1, slot.word.parts.count)
        var shapes = before.words.map {
            Shape(typed: $0.word.typed, sung: $0.word.sung, parts: $0.word.parts, line: $0.word.line,
                  phrase: $0.phrase, noteIDs: $0.noteIDs)
        }
        if word.isEmpty || word == "+" {
            if j > 0 { return .unchanged }
            if k == 0 || before.words[k - 1].phrase != slot.phrase { return .refused(.nothingToHold(noteID: n)) }
            if count > 1 && count - 1 < parts { return .refused(.noteInsideHyphenatedWord(word: slot.word.typed)) }
            shapes[k - 1].noteIDs.append(n)
            shapes[k].noteIDs.removeFirst()
            if shapes[k].noteIDs.isEmpty { shapes.remove(at: k) }
            return .words(shapes)
        }
        let new = LyricTokenizer.tokenize(word).words[0]
        let newParts = max(1, new.parts.count)
        var placed = Shape(typed: new.typed, sung: new.sung, parts: new.parts, line: slot.word.line,
                           phrase: slot.phrase, noteIDs: slot.noteIDs)
        if j == 0 {
            if new.typed == slot.word.typed, new.sung == slot.word.sung, new.parts == slot.word.parts {
                return .unchanged
            }
            if newParts > count { return .refused(.lyrics(.markedWordDoesNotFit(word: new.sung, needed: newParts))) }
            shapes[k] = placed
            return .words(shapes)
        }
        if j < parts { return .refused(.noteInsideHyphenatedWord(word: slot.word.typed)) }
        if newParts > count - j { return .refused(.lyrics(.markedWordDoesNotFit(word: new.sung, needed: newParts))) }
        shapes[k].noteIDs = Array(slot.noteIDs[..<j])
        placed.noteIDs = Array(slot.noteIDs[j...])
        shapes.insert(placed, at: k + 1)
        return .words(shapes)
    }

    /// A clip of 1-4 breath phrases of 1-6 notes: lengths and articulation
    /// gaps vary, some onsets carry a lower chord note (dropped), some clips a
    /// note past their end (not played). Its text is either one line per
    /// phrase or words flowing over the phrases, with hyphen parts, + marks
    /// (standing alone or glued on), punctuation and line breaks.
    static func randomClip(_ rng: inout LyricEditFuzzRNG) -> Clip {
        func chance(_ p: Double) -> Bool { Double.random(in: 0..<1, using: &rng) < p }
        let sizes = (0..<Int.random(in: 1...4, using: &rng)).map { _ in Int.random(in: 1...6, using: &rng) }
        var notes: [MIDINote] = []
        var beat = 0.0
        for size in sizes {
            for _ in 0..<size {
                let length = [0.25, 0.5, 1, 1.5].randomElement(using: &rng)!
                let pitch = Int.random(in: 55...76, using: &rng)
                notes.append(MIDINote(pitch: pitch, startBeat: beat, lengthBeats: length))
                if chance(0.07) {
                    notes.append(MIDINote(pitch: pitch - Int.random(in: 1...7, using: &rng), startBeat: beat,
                                          lengthBeats: length))
                }
                beat += length + [0, 0, 0.0625].randomElement(using: &rng)!
            }
            beat += [0.5, 1, 2].randomElement(using: &rng)!
        }
        if chance(0.1) { notes.append(MIDINote(pitch: 60, startBeat: beat + 0.5, lengthBeats: 1)) }

        // Words: each asks for `demand` notes (hyphen parts + marks), within a budget of notes.
        func words(budget: Int, count: Int) -> [String] {
            var out: [String] = []
            var left = budget
            for w in 0..<count {
                let mustLeave = count - w - 1
                var word = Self.plainWords.randomElement(using: &rng)!
                var demand = 1
                if chance(0.15) {
                    let candidate = Self.hyphenatedWords.randomElement(using: &rng)!
                    let parts = candidate.split(separator: "-").count
                    if parts <= left - mustLeave { word = candidate; demand = parts }
                }
                while left - mustLeave - demand > 0, chance(0.15) {
                    word += [" +", "+", " +~"].randomElement(using: &rng)!
                    demand += 1
                }
                left -= demand
                out.append(word)
            }
            return out
        }
        let text: String
        if chance(0.5) {
            // One line per phrase.
            text = sizes.map { size in
                words(budget: size, count: Int.random(in: 1...size, using: &rng)).joined(separator: " ")
            }.joined(separator: ["\n", "\n", "\n\n", "\r\n"].randomElement(using: &rng)!)
        } else {
            // Flowing over the phrases, broken into lines at random.
            let total = sizes.reduce(0, +)
            let flowing = words(budget: total, count: Int.random(in: 1...total, using: &rng))
            var joined = ""
            for (i, word) in flowing.enumerated() {
                if i > 0 { joined += chance(0.2) ? "\n" : " " }
                joined += word
            }
            text = joined
        }
        return Clip(name: "Fuzz", startBeat: Double(Int.random(in: 0...8, using: &rng)), lengthBeats: beat,
                    notes: notes, lyrics: ClipLyrics(text: text))
    }

    static func randomEdit(on noteID: UUID, _ rng: inout LyricEditFuzzRNG) -> LyricNoteEdit {
        let roll = Double.random(in: 0..<1, using: &rng)
        if roll < 0.15 { return .clearWord(noteID: noteID) }
        if roll < 0.27 { return .setWord(noteID: noteID, word: "+") }
        if roll < 0.32 { return .setWord(noteID: noteID, word: Self.invalidWords.keys.sorted().randomElement(using: &rng)!) }
        let pool = Self.plainWords + Self.hyphenatedWords
        return .setWord(noteID: noteID, word: pool.randomElement(using: &rng)!)
    }

    @Test("⭐ round trip on 500 seeded clips, every note edited: each edit is refused with a listed refusal or changes exactly the edited notes")
    func roundTripProperty() throws {
        var rng = LyricEditFuzzRNG(seed: 0x0510_ED17_2026)
        var clips = 0, unfit = 0, lineClips = 0, flowClips = 0, silentFlowClips = 0
        var edits = 0, changed = 0, unchanged = 0, mismatches = 0
        var refusals: [String: Int] = [:]
        var unstableStable = 0, unstableModeFlip = 0, unstableSilentFlow = 0
        var firstMismatch: String?
        func note(_ text: String) {
            mismatches += 1
            if firstMismatch == nil { firstMismatch = text }
        }

        for _ in 0..<500 {
            let clip = Self.randomClip(&rng)
            let tempo = TempoMap(constantBPM: [90.0, 120, 140].randomElement(using: &rng)!)
            clips += 1
            guard let before = try? SingPlanner.assignment(for: clip, tempoMap: tempo) else { unfit += 1; continue }
            let text = clip.lyrics!.text
            let silentFlow = before.mode == .flow && !before.unsungNoteIDs.isEmpty
            if before.mode == .linePerPhrase { lineClips += 1 } else if silentFlow { silentFlowClips += 1 } else { flowClips += 1 }

            for melodyNote in clip.notes! {
                let edit = Self.randomEdit(on: melodyNote.id, &rng)
                edits += 1
                let want = Self.expected(edit, before)
                let context = "text \(text.debugDescription), edit \(edit)"
                do throws(LyricEditRefusal) {
                    let (newText, after) = try LyricTextEdit.apply(edit, to: clip, tempoMap: tempo)
                    var edited = clip
                    edited.lyrics = ClipLyrics(text: newText)
                    guard (try? SingPlanner.assignment(for: edited, tempoMap: tempo)) == after else {
                        note("returned assignment is not the derivation of the returned text: \(context)")
                        continue
                    }
                    switch want {
                    case .unchanged:
                        if newText == text, after == before { unchanged += 1 } else { note("expected no change: \(context)") }
                    case .words(let shapes):
                        let got = after.words.map {
                            Shape(typed: $0.word.typed, sung: $0.word.sung, parts: $0.word.parts, line: $0.word.line,
                                  phrase: $0.phrase, noteIDs: $0.noteIDs)
                        }
                        guard got == shapes, after.mode == before.mode, after.unsungNoteIDs == before.unsungNoteIDs else {
                            note("wrong words \(got) vs \(shapes) -> \(newText.debugDescription): \(context)")
                            continue
                        }
                        if before.mode == .linePerPhrase {
                            // Every line but the edited word's own is byte-identical.
                            let line = before.words.first { $0.noteIDs.contains(melodyNote.id) }!.word.line
                            let old = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                            let new = newText.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
                            let others = old.count == new.count
                                && old.indices.allSatisfy { $0 == line || old[$0] == new[$0] }
                            if !others { note("another line changed -> \(newText.debugDescription): \(context)") }
                        }
                        changed += 1
                    case .refused(let refusal):
                        note("expected \(refusal), got a success \(newText.debugDescription): \(context)")
                    }
                } catch {
                    let kind = "\(error)".prefix { $0 != "(" }
                    refusals[String(kind), default: 0] += 1
                    if error == .unstable {
                        guard case .words = want else { note("unstable where \(want) was expected: \(context)"); continue }
                        // The one case this domain can legitimately move: a flow-mode hold that removes the only
                        // word on its text line drops the non-empty line count by one, and when that makes it EQUAL
                        // the phrase count, rule 1 switches the text to line-per-phrase. Only that exact cause is
                        // exempt; any other unstable here is a splice defect.
                        let slot = before.words.first { $0.noteIDs.contains(melodyNote.id) }!
                        let isHold: Bool
                        if case .clearWord = edit { isHold = true } else if case .setWord(_, "+") = edit { isHold = true } else { isHold = false }
                        let flipsMode = before.mode == .flow && isHold && slot.noteIDs.count == 1
                            && before.words.filter { $0.word.line == slot.word.line }.count == 1
                            && before.lineCount - 1 == before.phraseCount
                        if silentFlow { unstableSilentFlow += 1 } else if flipsMode { unstableModeFlip += 1 } else {
                            unstableStable += 1
                            if firstMismatch == nil { firstMismatch = "unstable in the stable domain: \(context)" }
                        }
                    } else if want != .refused(error) {
                        note("refused \(error), expected \(want): \(context)")
                    }
                }
            }
        }

        let summary = "LYRIC-EDIT-PROPERTY clips=\(clips) unfit=\(unfit) linePerPhrase=\(lineClips) flow=\(flowClips) "
            + "flowWithSilentLines=\(silentFlowClips) edits=\(edits) changed=\(changed) unchanged=\(unchanged) "
            + "refusals=\(refusals.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: ",")) "
            + "unstableStable=\(unstableStable) unstableModeFlip=\(unstableModeFlip) "
            + "unstableSilentFlow=\(unstableSilentFlow) mismatches=\(mismatches)"
        print(summary)
        #expect(mismatches == 0, "\(firstMismatch ?? "") — \(summary)")
        #expect(unstableStable == 0, "\(firstMismatch ?? "") — \(summary)")
        // Controls: the generator reaches every branch the property is about.
        #expect(clips == 500)
        #expect(lineClips > 100 && flowClips > 50 && silentFlowClips > 5, "\(summary)")
        #expect(edits > 3_000, "\(summary)")
        #expect(changed > edits / 4, "\(summary)")
        #expect(unchanged > 20, "\(summary)")
        for kind in ["noteNotSung", "nothingToHold", "noteInsideHyphenatedWord", "lyrics", "wordHasSpace",
                     "wordHasMarks", "wordHasNoLetters"] {
            #expect((refusals[kind] ?? 0) > 0, "control: no \(kind) refusal was reached — \(summary)")
        }
    }
}

/// SplitMix64, seeded: the same clips on every run.
struct LyricEditFuzzRNG: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
