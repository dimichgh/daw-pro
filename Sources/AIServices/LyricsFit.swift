import DAWCore
import Foundation

// p2-sing-x7b (design `docs/design/2026-10-06-p2-sing-expansion.md` §8.3): lyrics written to fit a melody clip. The
// writer is asked for ONE line per breath phrase with at most that phrase's notes in syllables, and its reply is
// CHECKED, never trusted: the base assigner must take it line for line (`LyricAssignment.Mode.linePerPhrase`) and
// every line's syllables must be at most its phrase's notes. One retry names the lines that failed; whatever comes
// back then is returned WITH its fit report. Nothing here stores anything: `ai.writeLyrics {fitClipId}` returns the
// text, and the Sing sheet's "Write words for me" (x8) puts it in the words box.

/// What a fit-to-the-tune lyrics request tells the writer (`LyricsWriteRequest.fit`): the melody's breath phrases,
/// in order, and, on the one retry, the sentences that name the lines that did not fit.
public struct LyricsFitBrief: Sendable, Equatable {
    /// One breath phrase of the melody (`PhraseDetection`, the assigner's own phrases).
    public struct Phrase: Sendable, Equatable {
        /// Notes in the phrase: the most syllables its line may have.
        public var notes: Int
        /// From the phrase's first note to the end of its last, in seconds at the song's tempo.
        public var seconds: Double

        public init(notes: Int, seconds: Double) {
            self.notes = notes
            self.seconds = seconds
        }
    }

    public var phrases: [Phrase]
    /// Sentences naming what did not fit last time ("Line 2 has 9 syllables, but phrase 2 has only 6 notes."); empty
    /// on the first try.
    public var problems: [String]

    public init(phrases: [Phrase], problems: [String] = []) {
        self.phrases = phrases
        self.problems = problems
    }
}

/// One line of a fit report: phrase `phrase` (1-based) has `notes` notes; its line has `syllables` syllables.
public struct LyricsFitLine: Sendable, Equatable {
    public var phrase: Int
    public var notes: Int
    public var syllables: Int
    public var fits: Bool

    public init(phrase: Int, notes: Int, syllables: Int, fits: Bool) {
        self.phrase = phrase
        self.notes = notes
        self.syllables = syllables
        self.fits = fits
    }
}

/// The check of one reply against the melody.
public struct LyricsFitReport: Sendable, Equatable {
    /// One entry per phrase, or per line when there are more lines than phrases (those read `notes` 0).
    public var lines: [LyricsFitLine]
    /// True only when the assigner took the text line for line AND every line fits.
    public var allFit: Bool
    /// For the writer's retry: what did not fit, one sentence each. Empty when `allFit`.
    public var problems: [String]
}

/// What `LyricsFit.write` returns: the (cleaned) lyrics, the provider, the report on them, and how many times the
/// writer was asked (1, or 2 after the retry).
public struct LyricsFitOutcome: Sendable, Equatable {
    public var result: LyricsWriteResult
    public var report: LyricsFitReport
    public var attempts: Int
}

public enum LyricsFit {

    /// The melody's breath phrases, as the assigner sees them (`SingPlanner.melody` → `PhraseDetection.phrases` at the
    /// assigner's own threshold), with each phrase's note count and length in seconds.
    public static func phrases(of clip: Clip, tempoMap: TempoMap) -> [LyricsFitBrief.Phrase] {
        let melody = SingPlanner.melody(of: clip).notes
        return PhraseDetection.phrases(in: melody, maxGapBeats: HumanizeLegato.defaultMaxGapBeats).map { phrase in
            LyricsFitBrief.Phrase(
                notes: phrase.noteIDs.count,
                seconds: tempoMap.seconds(from: clip.startBeat + phrase.startBeat, to: clip.startBeat + phrase.endBeat))
        }
    }

    /// The reply as lyrics: every ACE-style section tag (`[verse]`, `[Chorus 2]`) removed wherever it appears, each
    /// line trimmed, blank lines dropped.
    public static func cleaned(_ text: String) -> String {
        let untagged = text.replacingOccurrences(of: #"\[[^\]\n]*\]"#, with: "", options: .regularExpression)
        return untagged.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Checks `text` (already cleaned) against `clip`'s melody, sung in `language` (a `ClipLyrics` code; nil =
    /// English): the base assigner must take it in line-per-phrase mode, and each line's syllables (the assigner's
    /// own count) must be at most its phrase's notes.
    public static func check(_ text: String, clip: Clip, language: String?, tempoMap: TempoMap) -> LyricsFitReport {
        let phrases = Self.phrases(of: clip, tempoMap: tempoMap)
        var probe = clip
        probe.lyrics = ClipLyrics(text: text, language: language)
        let tokenized = LyricTokenizer.tokenize(text, language: language)
        var problems: [String] = []
        var syllablesPerLine: [Int]
        var assignerTookIt = false
        do throws(LyricRefusal) {
            let assignment = try SingPlanner.assignment(for: probe, tempoMap: tempoMap)
            if assignment.mode == .linePerPhrase {
                assignerTookIt = true
                syllablesPerLine = (0..<phrases.count).map { p in
                    assignment.words.filter { $0.phrase == p }.reduce(0) { $0 + $1.syllables }
                }
            } else {
                syllablesPerLine = tokenized.lines.map(Self.syllables)
            }
        } catch {
            syllablesPerLine = tokenized.lines.map(Self.syllables)
            problems.append(Copy.assignerRefused(error.sentence))
        }
        let lineCount = tokenized.lines.count
        if lineCount != phrases.count {
            problems.insert(Copy.lineCount(lines: lineCount, phrases: phrases.count), at: 0)
        }
        var lines: [LyricsFitLine] = []
        for i in 0..<max(phrases.count, syllablesPerLine.count) {
            let notes = i < phrases.count ? phrases[i].notes : 0
            let syllables = i < syllablesPerLine.count ? syllablesPerLine[i] : 0
            let fits = assignerTookIt && i < phrases.count && i < syllablesPerLine.count && syllables <= notes
            if i < phrases.count, i < syllablesPerLine.count, syllables > notes {
                problems.append(Copy.tooManySyllables(line: i + 1, syllables: syllables, notes: notes))
            }
            lines.append(LyricsFitLine(phrase: i + 1, notes: notes, syllables: syllables, fits: fits))
        }
        let allFit = assignerTookIt && !lines.isEmpty && lines.allSatisfy { $0.fits }
        return LyricsFitReport(lines: lines, allFit: allFit, problems: allFit ? [] : problems)
    }

    /// Asks `writer` for lyrics that fit `clip` (`request.fit` is filled in here), checks them, and asks ONCE more,
    /// naming what failed, when they do not fit. The second reply is returned whether or not it fits, with its report.
    /// Throws what the writer throws (no key, a network error); never stores anything.
    public static func write(_ request: LyricsWriteRequest, clip: Clip, language: String?, tempoMap: TempoMap,
                             writer: any LyricsGenerating) async throws -> LyricsFitOutcome {
        let phrases = Self.phrases(of: clip, tempoMap: tempoMap)
        var asked = request
        asked.fit = LyricsFitBrief(phrases: phrases)
        var reply = try await writer.writeLyrics(asked)
        var text = cleaned(reply.lyrics)
        var report = check(text, clip: clip, language: language, tempoMap: tempoMap)
        var attempts = 1
        if !report.allFit {
            asked.fit = LyricsFitBrief(phrases: phrases, problems: report.problems)
            reply = try await writer.writeLyrics(asked)
            text = cleaned(reply.lyrics)
            report = check(text, clip: clip, language: language, tempoMap: tempoMap)
            attempts = 2
        }
        return LyricsFitOutcome(result: LyricsWriteResult(lyrics: text, provider: reply.provider), report: report,
                                attempts: attempts)
    }

    /// The assigner's syllable count for one line when it did not take the text line for line (the same rule as
    /// `LyricNoteAssigner.assign`: a hyphenated word's parts, else its language's estimate, at least 1).
    static func syllables(_ line: [LyricWord]) -> Int {
        line.reduce(0) { total, word in
            total + (word.parts.count > 1 ? word.parts.count
                         : max(1, LyricLanguage.syllableCounter(for: word.language).estimate(word.sung)))
        }
    }

    /// The sentences. `notFit` is design §14 "Write words for me" VERBATIM; the writer-facing ones are PROVISIONAL.
    public enum Copy {
        /// §14: "Some lines didn't fit the tune: {lines}. Edit them, or try again." `{lines}` = the line numbers
        /// ("2", "2 and 4", "1, 2 and 4") [PROVISIONAL fill].
        public static func notFit(lines: [Int]) -> String {
            "Some lines didn't fit the tune: \(listed(lines.map(String.init))). Edit them, or try again."
        }

        static func lineCount(lines: Int, phrases: Int) -> String {
            "You wrote \(lines) line\(lines == 1 ? "" : "s"), but the tune has \(phrases) phrase\(phrases == 1 ? "" : "s"). "
                + "Write exactly \(phrases) line\(phrases == 1 ? "" : "s"), one for each phrase."
        }

        static func tooManySyllables(line: Int, syllables: Int, notes: Int) -> String {
            "Line \(line) has \(syllables) syllables, but phrase \(line) has only \(notes) note\(notes == 1 ? "" : "s")."
        }

        static func assignerRefused(_ sentence: String) -> String {
            "The words couldn't be placed on the notes: \(sentence)"
        }

        static func listed(_ items: [String]) -> String {
            guard items.count > 1 else { return items.first ?? "" }
            return items.dropLast().joined(separator: ", ") + " and " + items.last!
        }
    }
}
