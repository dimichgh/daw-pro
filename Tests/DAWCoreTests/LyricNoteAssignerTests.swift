import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d1: `LyricNoteAssigner`, which note each lyric word sings (design
/// §3.3 rules 1-7). NOT `@MainActor`: a pure function of its arguments.
///
/// Layouts are written as `word@[note indexes]`, indexes into the melody in
/// time order, so a table reads like the design's rules.
@Suite("Lyric note assigner — rules 1-7 (p2-sing-d1)")
struct LyricNoteAssignerTests {

    /// 120 BPM: one beat is 0.5 s.
    private let map = TempoMap(constantBPM: 120)

    /// Phrases of `sizes` notes, each note one beat long and touching the
    /// next; a one-beat rest (a breath, well over 0.125 beats) between phrases.
    private func melody(_ sizes: [Int], noteBeats: Double = 1) -> [MIDINote] {
        var notes: [MIDINote] = []
        var beat = 0.0
        for size in sizes {
            for _ in 0..<size {
                notes.append(MIDINote(pitch: 60 + notes.count % 12, startBeat: beat, lengthBeats: noteBeats))
                beat += noteBeats
            }
            beat += 1
        }
        return notes
    }

    private func assign(_ text: String, _ notes: [MIDINote], clipStartBeat: Double = 0,
                        tempoMap: TempoMap? = nil,
                        syllables: (String) -> Int = EnglishSyllables.estimate) throws -> LyricAssignment {
        try LyricNoteAssigner.assign(LyricTokenizer.tokenize(text), notes: notes, clipStartBeat: clipStartBeat,
                                     tempoMap: tempoMap ?? map, syllables: syllables)
    }

    private func refusal(_ text: String, _ notes: [MIDINote]) -> LyricRefusal? {
        do {
            _ = try LyricNoteAssigner.assign(LyricTokenizer.tokenize(text), notes: notes, clipStartBeat: 0, tempoMap: map)
            return nil
        } catch {
            return error
        }
    }

    private func layout(_ a: LyricAssignment, _ notes: [MIDINote]) -> [String] {
        let index = Dictionary(uniqueKeysWithValues: MIDINote.canonicallyOrdered(notes).enumerated().map { ($1.id, $0) })
        return a.words.map { "\($0.word.sung)@\($0.noteIDs.map { index[$0]! })" }
    }

    /// Rule 2's invariant, checked against the tree's own breath definition.
    private func expectNoWordCrossesABreath(_ a: LyricAssignment, _ notes: [MIDINote],
                                            sourceLocation: SourceLocation = #_sourceLocation) {
        let phraseOf = Dictionary(uniqueKeysWithValues: PhraseDetection.phrases(in: MIDINote.canonicallyOrdered(notes))
            .enumerated().flatMap { p, phrase in phrase.noteIDs.map { ($0, p) } })
        for word in a.words {
            let phrases = Set(word.noteIDs.map { phraseOf[$0]! })
            #expect(phrases.count == 1, "'\(word.word.sung)' crosses a breath: phrases \(phrases.sorted())",
                    sourceLocation: sourceLocation)
        }
    }

    // MARK: Rule 4 — as many words as notes

    @Test("rule 4: W = N, one note each, no warnings")
    func oneNoteEach() throws {
        let notes = melody([4])
        let a = try assign("one two three four", notes)
        #expect(layout(a, notes) == ["one@[0]", "two@[1]", "three@[2]", "four@[3]"])
        #expect(a.warnings.isEmpty)
        #expect(a.words.allSatisfy { !$0.held })
    }

    // MARK: Rule 1 — lines against phrases

    @Test("rule 1: as many lines as phrases, line i sings phrase i")
    func linePerPhrase() throws {
        let notes = melody([3, 3])
        let a = try assign("la la\nsing it now", notes)
        #expect(a.mode == .linePerPhrase)
        #expect(a.lineCount == 2 && a.phraseCount == 2)
        #expect(layout(a, notes) == ["la@[0]", "la@[1, 2]", "sing@[3]", "it@[4]", "now@[5]"])
    }

    @Test("rule 1: otherwise the words flow across the phrases, ignoring line breaks")
    func flowAcrossPhrases() throws {
        let notes = melody([4, 4])
        let a = try assign("a b c\nd e f\ng h", notes)                    // 3 lines, 2 phrases
        #expect(a.mode == .flow)
        #expect(layout(a, notes) == ["a@[0]", "b@[1]", "c@[2]", "d@[3]", "e@[4]", "f@[5]", "g@[6]", "h@[7]"])
    }

    @Test("rule 1 flow: words spread in proportion to each phrase's notes")
    func flowIsProportional() throws {
        let notes = melody([2, 6])
        let a = try assign("a b c d", notes)                                // one line, two phrases
        #expect(a.mode == .flow)
        // 4 words over 2 + 6 notes: one word to the short phrase, three to the long one.
        #expect(a.words.map(\.phrase) == [0, 1, 1, 1])
        expectNoWordCrossesABreath(a, notes)
    }

    @Test("breaths are the tree's one definition: a 0.125-beat gap joins, a wider gap breathes")
    func breathThreshold() throws {
        let joined = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
                      MIDINote(pitch: 62, startBeat: 1 + HumanizeLegato.defaultMaxGapBeats, lengthBeats: 1)]
        #expect(try assign("a b", joined).phraseCount == 1)
        let breathed = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
                        MIDINote(pitch: 62, startBeat: 1.2, lengthBeats: 1)]
        #expect(try assign("a b", breathed).phraseCount == 2)
    }

    // MARK: Rule 2 — never across a breath

    @Test("rule 2: a word never crosses a breath, even when that leaves a note to hold")
    func neverCrossesABreath() throws {
        let notes = melody([2, 2])
        let a = try assign("a twin-kle", notes)                             // flow: one line, two phrases
        #expect(layout(a, notes) == ["a@[0, 1]", "twinkle@[2, 3]"])
        #expect(a.words[0].heldNotes == 1)
        expectNoWordCrossesABreath(a, notes)
    }

    @Test("rule 2 holds across many flows (every word stays inside one phrase)",
          arguments: [
              ("la la la la la", [2, 3, 2]), ("a twin-kle b + c", [3, 1, 4]), ("x y", [1, 1, 5]),
              ("beau-ti-ful day +", [4, 3]), ("one two three four five six seven", [3, 2, 4, 1]),
          ])
    func invariantAcrossFlows(text: String, sizes: [Int]) throws {
        let notes = melody(sizes)
        expectNoWordCrossesABreath(try assign(text, notes), notes)
    }

    // MARK: Rule 3 — markup first

    @Test("rule 3: hyphen parts and + marks are honoured exactly")
    func markupFirst() throws {
        let notes = melody([5])
        let a = try assign("twin-kle lit-tle star", notes)
        #expect(layout(a, notes) == ["twinkle@[0, 1]", "little@[2, 3]", "star@[4]"])
        let tied = try assign("star + shine", melody([3]))
        #expect(tied.words.map(\.noteIDs.count) == [2, 1])
        #expect(tied.words.allSatisfy { !$0.held })                         // a typed + is not "held"
    }

    @Test("rule 3: a marked word never takes a spare note under 5.1")
    func markedWordsAreNotReshared() throws {
        // "beau-ti-ful" is marked (3 notes); "go" is one syllable. The spare
        // note is held by the last word, never given to the marked word.
        let notes = melody([5])
        let a = try assign("beau-ti-ful go", notes)
        #expect(layout(a, notes) == ["beautiful@[0, 1, 2]", "go@[3, 4]"])
        #expect(a.words[1].heldNotes == 1)
    }

    // MARK: Rule 5 — spare notes

    @Test("rule 5.1: spare notes go to words with more syllables than notes")
    func spareNotesToSyllables() throws {
        let notes = melody([4])
        let a = try assign("beautiful day", notes)
        #expect(layout(a, notes) == ["beautiful@[0, 1, 2]", "day@[3]"])
        #expect(a.warnings.isEmpty)
    }

    @Test("rule 5.1: a number is one word, sharing spare notes by its SPOKEN syllables ('42' is 'forty two')")
    func numberSharesBySpokenSyllables() throws {
        let notes = melody([4])
        let a = try assign("42 go", notes)
        #expect(layout(a, notes) == ["42@[0, 1, 2]", "go@[3]"])
        #expect(a.words[0].syllables == 3)
        #expect(a.warnings.isEmpty)
    }

    @Test("rule 5.1: one each, left to right, in rounds")
    func oneEachInRounds() throws {
        let four = melody([4])
        #expect(layout(try assign("beautiful wonderful", four), four) == ["beautiful@[0, 1]", "wonderful@[2, 3]"])
        let three = melody([3])
        #expect(layout(try assign("beautiful wonderful", three), three) == ["beautiful@[0, 1]", "wonderful@[2]"])
    }

    @Test("rule 5.2: what is left is held by the word before the spare notes, with the §5.7 sentence")
    func heldWord() throws {
        let notes = melody([5])
        let a = try assign("la la", notes)
        #expect(layout(a, notes) == ["la@[0]", "la@[1, 2, 3, 4]"])
        #expect(a.words[1].held && a.words[1].heldNotes == 3)
        #expect(a.warnings == [.heldWord(word: "la", spareNotes: 3, line: 0)])
        #expect(a.warnings[0].sentence == "The tune has 3 more notes than your words need. I held 'la' across them. "
                + "Add words, or drag a word to cover different notes.")
        let one = try assign("la la", melody([3]))
        #expect(one.warnings[0].sentence == "The tune has 1 more note than your words need. I held 'la' across it. "
                + "Add words, or drag a word to cover different notes.")
    }

    // MARK: Rule 6 — W > N refused, never guessed

    @Test("rule 6: W > N is refused with §5.7's exact sentence")
    func tooManyWords() {
        let r = refusal("a b c d e", melody([3]))
        #expect(r == .tooManyWords(words: 5, notes: 3, line: 0))
        #expect(r?.sentence == "This line has 5 words but the tune has 3 notes. "
                + "Each note sings one word, so remove 2 words or add 2 notes.")
    }

    @Test("rule 6: under rule 1 the numbers are the line's and its phrase's, not the totals")
    func tooManyWordsPerLine() {
        let r = refusal("a b\nc d e f", melody([2, 2]))
        #expect(r == .tooManyWords(words: 4, notes: 2, line: 1))
        #expect(r?.sentence == "This line has 4 words but the tune has 2 notes. "
                + "Each note sings one word, so remove 2 words or add 2 notes.")
    }

    @Test("rule 6 in flow mode counts the whole melody; one of anything is singular")
    func tooManyWordsFlowAndSingular() {
        #expect(refusal("a b c d e", melody([2, 2])) == .tooManyWords(words: 5, notes: 4, line: nil))
        #expect(refusal("a b c", melody([2]))?.sentence == "This line has 3 words but the tune has 2 notes. "
                + "Each note sings one word, so remove 1 word or add 1 note.")
        #expect(refusal("a b", melody([1]))?.sentence == "This line has 2 words but the tune has 1 note. "
                + "Each note sings one word, so remove 1 word or add 1 note.")
    }

    @Test("rule 6: markup asking for more notes than exist is refused too")
    func markupOverDemand() {
        #expect(refusal("twin-kle star", melody([2])) == .markupNeedsMoreNotes(needed: 3, notes: 2, line: 0))
        // Enough notes overall, but "twinkle" needs two in one breath and the
        // flow leaves it none: refused, not squeezed across the breath.
        #expect(refusal("a twin-kle b", melody([2, 2])) == .markedWordDoesNotFit(word: "twinkle", needed: 2))
    }

    @Test("no words, and non-English words, are refused with §5.7's sentences")
    func noWordsAndNotEnglish() {
        #expect(refusal("", melody([2])) == .noWords)
        #expect(refusal(" !!! \n", melody([2]))?.sentence == "Type the words you want me to sing.")
        let r = refusal("hello café", melody([2]))
        #expect(r == .notEnglish(word: "café"))
        #expect(r?.sentence == "I can only sing English words so far — 'café' isn't one I can pronounce.")
    }

    // MARK: Rule 7 — squeezed words

    @Test("rule 7: 3+ syllables on one note under 0.3 s warns, with §5.7's sentence")
    func squeezedWord() throws {
        let short = melody([2], noteBeats: 0.5)                            // 0.25 s at 120 BPM
        let a = try assign("beautiful day", short)
        #expect(a.words[0].noteIDs.count == 1)
        guard case .squeezedWord(let word, let id, let seconds)? = a.warnings.first else {
            Issue.record("no squeezed-word warning: \(a.warnings)"); return
        }
        #expect(word == "beautiful" && id == a.words[0].noteIDs[0] && abs(seconds - 0.25) < 1e-9)
        #expect(a.warnings[0].sentence == "'beautiful' is squeezed onto one short note, so it may sound rushed.")
        #expect(try assign("beautiful day", melody([2])).warnings.isEmpty)          // 0.5 s: fine
        #expect(try assign("happy day", short).warnings.isEmpty)                     // 2 syllables: fine
    }

    @Test("rule 7 times notes through the tempo map, at the clip's place on the timeline")
    func squeezeUsesTheTempoMap() throws {
        // 60 BPM until beat 8, then 240 BPM: a one-beat note is 1 s early, 0.25 s late.
        let map = try TempoMap(segments: [.init(startBeat: 0, bpm: 60), .init(startBeat: 8, bpm: 240)])
        let notes = melody([2])
        #expect(try assign("beautiful day", notes, clipStartBeat: 0, tempoMap: map).warnings.isEmpty)
        #expect(try assign("beautiful day", notes, clipStartBeat: 8, tempoMap: map).warnings.count == 1)
    }

    // MARK: Flow mode's edges

    @Test("fewer words than phrases: some phrases stay silent, reported, never crossed")
    func silentPhrases() throws {
        let notes = melody([1, 1, 1])
        let a = try assign("la la", notes)
        #expect(a.unsungNoteIDs.count == 1)
        #expect(a.warnings.contains(.unsungPhrases(phrases: 1, notes: 1)))
        expectNoWordCrossesABreath(a, notes)
    }

    @Test("a + with no word before it is reported as a warning")
    func orphanHoldWarns() throws {
        let a = try assign("+ la", melody([1]))
        #expect(a.warnings == [.orphanHold(line: 0)])
    }

    // MARK: Derived, never stored; a miscount only shares spare notes

    @Test("the assignment is derived from the notes: the same text follows edited notes")
    func derivedFromNotes() throws {
        let text = LyricTokenizer.tokenize("a b")
        let first = melody([2]), second = melody([3])
        let one = try LyricNoteAssigner.assign(text, notes: first, clipStartBeat: 0, tempoMap: map)
        let two = try LyricNoteAssigner.assign(text, notes: second, clipStartBeat: 0, tempoMap: map)
        #expect(Set(one.words.flatMap(\.noteIDs)) == Set(first.map(\.id)))
        #expect(Set(two.words.flatMap(\.noteIDs)) == Set(second.map(\.id)))
    }

    @Test("note order in the input does not matter")
    func orderIndependent() throws {
        let notes = melody([3, 2])
        let a = try assign("one two three four five", notes)
        let b = try assign("one two three four five", notes.reversed())
        #expect(a == b)
    }

    @Test("a syllable miscount changes only how spare notes are shared, never which phrase a word sings")
    func miscountOnlySharesSpares() throws {
        let notes = melody([5, 3, 6])
        let text = "beautiful day tonight wonderful now la me go"
        let real = try assign(text, notes)
        let allOne = try assign(text, notes, syllables: { _ in 1 })
        let allFive = try assign(text, notes, syllables: { _ in 5 })
        #expect(real.words.map(\.phrase) == allOne.words.map(\.phrase))
        #expect(real.words.map(\.phrase) == allFive.words.map(\.phrase))
        #expect(layout(real, notes) != layout(allOne, notes))              // the counter did matter somewhere
    }
}
