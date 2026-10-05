import Foundation

/// One lyric word and the notes it sings.
public struct AssignedLyricWord: Equatable, Sendable {
    /// The word, as tokenized.
    public var word: LyricWord
    /// Its notes, in order. Never empty. All in one breath phrase (rule 2).
    public var noteIDs: [UUID]
    /// Clip-relative onset of the first note, in beats.
    public var startBeat: Double
    /// Clip-relative end of the last note, in beats.
    public var endBeat: Double
    /// Which breath phrase (0-based) the notes are in.
    public var phrase: Int
    /// The syllable count used for sharing spare notes: the hyphen parts when
    /// the word was hyphenated, else `EnglishSyllables`' estimate (at least 1).
    public var syllables: Int
    /// Spare notes this word holds across under rule 5.2 (the automatic
    /// melisma). 0 for a word that got none. Notes asked for with `+` are
    /// NOT counted here: those the user typed.
    public var heldNotes: Int

    /// True when rule 5.2 made this word hold across spare notes. It is what
    /// the "Held words" warning lists and what stretches a word chip.
    public var held: Bool { heldNotes > 0 }

    public init(word: LyricWord, noteIDs: [UUID], startBeat: Double, endBeat: Double,
                phrase: Int, syllables: Int, heldNotes: Int) {
        self.word = word
        self.noteIDs = noteIDs
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.phrase = phrase
        self.syllables = syllables
        self.heldNotes = heldNotes
    }
}

/// Something worth telling the user about an assignment that still sings.
public enum LyricWarning: Equatable, Sendable {
    /// Rule 5.2: `word` holds across `spareNotes` notes nobody else needed.
    case heldWord(word: String, spareNotes: Int, line: Int)
    /// Rule 7: a word of three or more syllables on one note shorter than
    /// 0.3 s.
    case squeezedWord(word: String, noteID: UUID, seconds: Double)
    /// Flow mode with fewer words than phrases: `phrases` phrases (`notes`
    /// notes) have no word and stay silent. NOT in design §5.7.
    case unsungPhrases(phrases: Int, notes: Int)
    /// A `+` with no word before it on its line (it is ignored). NOT in
    /// design §5.7.
    case orphanHold(line: Int)

    /// The sentence the user reads. §5.7's copy where §5.7 has a row; the two
    /// cases marked "NOT in design §5.7" carry provisional copy of ours.
    public var sentence: String {
        switch self {
        case .heldWord(let word, let spare, _):
            // §5.7 "Held words", with the singular written out for one note
            // (§5.7's template would read "1 more notes … across them").
            let notes = spare == 1 ? "1 more note" : "\(spare) more notes"
            let them = spare == 1 ? "it" : "them"
            return "The tune has \(notes) than your words need. I held '\(word)' across \(them). "
                + "Add words, or drag a word to cover different notes."
        case .squeezedWord(let word, _, _):
            return "'\(word)' is squeezed onto one short note, so it may sound rushed."
        case .unsungPhrases(let phrases, _):
            // PROVISIONAL (not in design §5.7). §5.7 calls a breath phrase a
            // "line" of the tune ("I had to split a very long line").
            let lines = phrases == 1 ? "1 line of the tune stays" : "\(phrases) lines of the tune stay"
            let them = phrases == 1 ? "it" : "them"
            return "There are fewer words than lines in the tune, so \(lines) silent. Add words to sing \(them)."
        case .orphanHold:
            // PROVISIONAL (not in design §5.7).
            return "A + at the start of a line has no word before it, so I ignored it."
        }
    }
}

/// Why lyrics cannot be sung on these notes. Never guessed (design §3.3
/// rule 6): the assigner refuses and says exactly what to change.
public enum LyricRefusal: Error, Equatable, Sendable {
    /// No words at all. §5.7 "No lyrics".
    case noWords
    /// A word with letters that are not English. §5.7 "Not English".
    case notEnglish(word: String)
    /// W > N: more words than notes. `line` is the text line (0-based) when
    /// rule 1 pairs lines with phrases, nil when the words flow. §5.7 "W > N".
    case tooManyWords(words: Int, notes: Int, line: Int?)
    /// Fewer words than notes, but the `+` marks and hyphen parts ask for
    /// more notes than there are. NOT in design §5.7.
    case markupNeedsMoreNotes(needed: Int, notes: Int, line: Int?)
    /// Enough notes overall, but a marked word needs more notes in one
    /// breath than any place the words can flow to offers. NOT in §5.7.
    case markedWordDoesNotFit(word: String, needed: Int)

    public var sentence: String {
        switch self {
        case .noWords:
            return "Type the words you want me to sing."
        case .notEnglish(let word):
            return "I can only sing English words so far — '\(word)' isn't one I can pronounce."
        case .tooManyWords(let w, let n, _):
            // §5.7 "W > N" verbatim, except that a count of one is written in
            // the singular ("1 word", "1 note") where the template would say
            // "1 words" / "1 notes".
            let extra = w - n
            return "This line has \(count(w, "word")) but the tune has \(count(n, "note")). "
                + "Each note sings one word, so remove \(count(extra, "word")) or add \(count(extra, "note"))."
        case .markupNeedsMoreNotes(let needed, let n, _):
            // PROVISIONAL (not in design §5.7).
            return "With your + marks and hyphens, the words need \(count(needed, "note")) "
                + "but the tune has \(n). Remove some marks, or add \(count(needed - n, "note"))."
        case .markedWordDoesNotFit(let word, let needed):
            // PROVISIONAL (not in design §5.7).
            return "'\(word)' needs \(count(needed, "note")) without a breath in between, and the tune has "
                + "no room for that. Remove some of its + marks or hyphens."
        }
    }

    private func count(_ n: Int, _ noun: String) -> String {
        n == 1 ? "1 \(noun)" : "\(n) \(noun)s"
    }
}

/// Which note each lyric word sings (p2-sing-d1, design §3.3). Derived, never
/// stored (§3.1).
public struct LyricAssignment: Equatable, Sendable {
    /// How words met phrases (rule 1).
    public enum Mode: String, Equatable, Sendable {
        /// As many non-empty lines as breath phrases: line i sings phrase i.
        case linePerPhrase
        /// Otherwise: the words flow across the phrases in order.
        case flow
    }

    public var mode: Mode
    /// Every word, in reading order, with its notes.
    public var words: [AssignedLyricWord]
    /// The melody's breath phrases, from `PhraseDetection`.
    public var phraseCount: Int
    /// The text's non-empty lines.
    public var lineCount: Int
    /// Notes no word sings: only in flow mode, when there are fewer words
    /// than phrases. Empty otherwise.
    public var unsungNoteIDs: [UUID]
    public var warnings: [LyricWarning]

    public init(mode: Mode, words: [AssignedLyricWord], phraseCount: Int, lineCount: Int,
                unsungNoteIDs: [UUID], warnings: [LyricWarning]) {
        self.mode = mode
        self.words = words
        self.phraseCount = phraseCount
        self.lineCount = lineCount
        self.unsungNoteIDs = unsungNoteIDs
        self.warnings = warnings
    }
}

/// Assigns lyric words to melody notes (design §3.3).
///
/// ## Inputs
///
/// - the tokenized text (`LyricTokenizer`);
/// - the melody's notes AFTER §3.4's monophony rule. That rule belongs to
///   `SingPlanner` (item p2-sing-d2); this type does not resolve chords, and
///   two notes that start together are treated as two notes in a row;
/// - the clip's start beat and the tempo map, only to time rule 7's
///   0.3 s in seconds;
/// - a syllable counter, `EnglishSyllables.estimate` unless a test swaps it.
///
/// Notes are grouped into breath phrases by the tree's ONE breath definition,
/// `PhraseDetection.phrases(in:maxGapBeats:)`, at its threshold,
/// `HumanizeLegato.defaultMaxGapBeats` (0.125 beats).
///
/// ## The rules, in the order they apply
///
/// 1. If the text has as many non-empty lines as the melody has phrases,
///    line i sings phrase i. Otherwise the words flow, in order, across the
///    phrases.
/// 2. A word never crosses a breath: all its notes are in one phrase.
/// 3. Markup is honoured first: each hyphen part and each `+` is one note
///    of that word, and a marked word never takes a spare note under 5.1.
/// 4. W = N: one note each.
/// 5. W < N: the spare notes go first, one each and left to right in rounds,
///    to unmarked words with more syllables than notes; whatever is left is
///    held by the phrase's last word (a melisma), with a warning.
/// 6. W > N is refused with the numbers, per line under rule 1. A text whose
///    markup asks for more notes than exist is refused too.
/// 7. A word with more syllables than notes is fine; a word of 3+ syllables
///    on one note shorter than 0.3 s gets a warning.
///
/// ## How the words flow when rule 1 does not apply (a design choice)
///
/// The design does not say how many words each phrase gets in flow mode.
/// Here, the words are spread in PROPORTION TO EACH PHRASE'S NOTES, counting
/// each word as the notes its markup asks for (1 for an unmarked word): a
/// phrase with twice the notes gets about twice the words. Words keep their
/// order, a phrase never gets more than its notes, and a phrase is left with
/// no words only when there are fewer words than phrases (then its notes are
/// `unsungNoteIDs`, with a warning).
///
/// The split deliberately ignores syllable ESTIMATES, so §3.3's promise holds
/// in both modes: "a miscount only changes how spare notes are shared". The
/// cost: a line whose words are uneven in length can put a word one phrase
/// early or late, which a line break (rule 1) or a `+` fixes exactly.
///
/// Among splits that match the proportion equally well, earlier phrases take
/// more words. The split is found exactly (a small dynamic program over word
/// and phrase boundaries), so it never fails to find one that fits when any
/// does.
public enum LyricNoteAssigner {

    /// Rule 7: this many syllables or more on one note...
    public static let squeezeSyllables = 3
    /// ...shorter than this many seconds draws a warning.
    public static let squeezeSeconds = 0.3

    public static func assign(
        _ text: LyricText,
        notes: [MIDINote],
        clipStartBeat: Double,
        tempoMap: TempoMap,
        syllables: (String) -> Int = EnglishSyllables.estimate
    ) throws(LyricRefusal) -> LyricAssignment {
        let words = text.words
        guard !words.isEmpty else { throw .noWords }
        if let foreign = words.first(where: { !$0.isEnglish }) { throw .notEnglish(word: foreign.sung) }

        let melody = MIDINote.canonicallyOrdered(notes)
        let byID = Dictionary(melody.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let phrases = PhraseDetection.phrases(in: melody, maxGapBeats: HumanizeLegato.defaultMaxGapBeats)
        let phraseNotes: [[MIDINote]] = phrases.map { $0.noteIDs.compactMap { byID[$0] } }
        let lines = text.lines

        // Which words sing which phrase: consecutive word ranges, one per phrase.
        let mode: LyricAssignment.Mode = lines.count == phrases.count ? .linePerPhrase : .flow
        var ranges: [Range<Int>] = []
        switch mode {
        case .linePerPhrase:
            var start = 0
            for (i, line) in lines.enumerated() {
                let available = phraseNotes[i].count
                if line.count > available {
                    throw .tooManyWords(words: line.count, notes: available, line: line[0].line)
                }
                let needed = line.reduce(0) { $0 + $1.markedNotes }
                if needed > available {
                    throw .markupNeedsMoreNotes(needed: needed, notes: available, line: line[0].line)
                }
                ranges.append(start..<(start + line.count))
                start += line.count
            }
        case .flow:
            if words.count > melody.count {
                throw .tooManyWords(words: words.count, notes: melody.count, line: nil)
            }
            let demands = words.map(\.markedNotes)
            let needed = demands.reduce(0, +)
            if needed > melody.count {
                throw .markupNeedsMoreNotes(needed: needed, notes: melody.count, line: nil)
            }
            guard let breaks = flowBreaks(demands: demands, capacities: phraseNotes.map(\.count)) else {
                let worst = words.indices.max { demands[$0] < demands[$1] || (demands[$0] == demands[$1] && $0 > $1) }!
                throw .markedWordDoesNotFit(word: words[worst].sung, needed: demands[worst])
            }
            ranges = zip(breaks, breaks.dropFirst()).map { $0..<$1 }
        }

        // Within each phrase: markup first, then spare notes (rules 3-5).
        var warnings: [LyricWarning] = text.orphanHoldLines.map { .orphanHold(line: $0) }
        var assigned: [AssignedLyricWord] = []
        var unsung: [UUID] = []
        var silentPhrases = 0
        for (p, range) in ranges.enumerated() {
            let phraseWords = Array(words[range])
            let notesHere = phraseNotes[p]
            guard !phraseWords.isEmpty else {
                silentPhrases += 1
                unsung += notesHere.map(\.id)
                continue
            }
            let counted = phraseWords.map { word in
                word.parts.count > 1 ? word.parts.count : max(1, syllables(word.sung))
            }
            let (counts, heldByLast) = share(words: phraseWords, syllables: counted, notes: notesHere.count)
            var position = 0
            for (k, word) in phraseWords.enumerated() {
                let mine = Array(notesHere[position..<(position + counts[k])])
                position += counts[k]
                let isLast = k == phraseWords.count - 1
                let held = isLast ? heldByLast : 0
                assigned.append(AssignedLyricWord(
                    word: word, noteIDs: mine.map(\.id), startBeat: mine[0].startBeat,
                    endBeat: mine.map(\.endBeat).max() ?? mine[0].endBeat, phrase: p,
                    syllables: counted[k], heldNotes: held))
                if held > 0 {
                    warnings.append(.heldWord(word: word.sung, spareNotes: held, line: word.line))
                }
                if mine.count == 1, counted[k] >= squeezeSyllables {
                    let seconds = tempoMap.seconds(from: clipStartBeat + mine[0].startBeat,
                                                   to: clipStartBeat + mine[0].endBeat)
                    if seconds < squeezeSeconds {
                        warnings.append(.squeezedWord(word: word.sung, noteID: mine[0].id, seconds: seconds))
                    }
                }
            }
        }
        if silentPhrases > 0 { warnings.append(.unsungPhrases(phrases: silentPhrases, notes: unsung.count)) }

        return LyricAssignment(mode: mode, words: assigned, phraseCount: phrases.count, lineCount: lines.count,
                               unsungNoteIDs: unsung, warnings: warnings)
    }

    // MARK: - Rules 3-5 inside one phrase

    /// How many notes each word of one phrase gets, and how many spare notes
    /// the last word holds. The words' markup must already fit (`notes` is at
    /// least the sum of `markedNotes`).
    static func share(words: [LyricWord], syllables: [Int], notes: Int) -> (counts: [Int], heldByLast: Int) {
        var counts = words.map(\.markedNotes)
        var spare = notes - counts.reduce(0, +)
        // 5.1: one spare note each, left to right, in rounds, to unmarked
        // words with more syllables than notes. A spare note is only ever one
        // no word needs, so this never takes a note a later word needs.
        while spare > 0 {
            var gave = false
            for k in words.indices where spare > 0 && !words[k].hasMarkup && syllables[k] > counts[k] {
                counts[k] += 1
                spare -= 1
                gave = true
            }
            if !gave { break }
        }
        // 5.2: what is left, the word before the spare notes holds across.
        // Words are laid out in order, so the spares sit at the phrase's end.
        let held = max(0, spare)
        if held > 0 { counts[counts.count - 1] += held }
        return (counts, held)
    }

    // MARK: - Flow mode: which words go to which phrase

    /// The first word index of each phrase, plus `demands.count` at the end
    /// (so phrase p sings words `breaks[p]..<breaks[p + 1]`), or nil when no
    /// split fits every word's markup inside one phrase.
    ///
    /// Minimises, in order: (1) the number of phrases with no words, then
    /// (2) the squared gap between the notes asked for so far and the
    /// proportional share at the end of every phrase. Ties go to the split in
    /// which earlier phrases take more words.
    static func flowBreaks(demands: [Int], capacities: [Int]) -> [Int]? {
        let wordCount = demands.count, phraseCount = capacities.count
        guard phraseCount > 0 else { return wordCount == 0 ? [0] : nil }
        var asked = [0]                                   // asked[k]: notes asked for by words 0..<k
        for d in demands { asked.append(asked[asked.count - 1] + d) }
        let totalAsked = Double(asked[wordCount])
        let totalNotes = Double(capacities.reduce(0, +))
        guard totalNotes > 0 else { return nil }

        struct Cost: Comparable {
            var silent: Int
            var squared: Double
            static func < (a: Cost, b: Cost) -> Bool {
                a.silent != b.silent ? a.silent < b.silent : a.squared < b.squared
            }
        }
        let width = wordCount + 1
        var cost = [Cost?](repeating: nil, count: phraseCount * width)
        var back = [Int](repeating: -1, count: phraseCount * width)
        var notesSoFar = 0
        for p in 0..<phraseCount {
            notesSoFar += capacities[p]
            let target = totalAsked * Double(notesSoFar) / totalNotes
            let starts: [Int] = p == 0 ? [0] : (0...wordCount).filter { cost[(p - 1) * width + $0] != nil }
            for from in starts {                          // ascending, so ties keep the larger `from`
                let before = p == 0 ? Cost(silent: 0, squared: 0) : cost[(p - 1) * width + from]!
                var to = from
                while to <= wordCount, asked[to] - asked[from] <= capacities[p] {
                    let gap = Double(asked[to]) - target
                    let candidate = Cost(silent: before.silent + (to == from ? 1 : 0),
                                         squared: before.squared + gap * gap)
                    let slot = p * width + to
                    if let best = cost[slot], best < candidate {
                        // keep the better one already there
                    } else {
                        cost[slot] = candidate
                        back[slot] = from
                    }
                    to += 1
                }
            }
        }
        guard cost[(phraseCount - 1) * width + wordCount] != nil else { return nil }
        var breaks = [wordCount]
        var k = wordCount
        for p in stride(from: phraseCount - 1, through: 1, by: -1) {
            k = back[p * width + k]
            breaks.append(k)
        }
        breaks.append(0)
        return breaks.reversed()
    }
}
