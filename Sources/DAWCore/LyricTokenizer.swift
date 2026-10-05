import Foundation

/// One word of typed lyrics, as `LyricNoteAssigner` sees it (design §3.2).
public struct LyricWord: Equatable, Sendable {
    /// The token as typed, with curly apostrophes already straightened, its
    /// `+` marks peeled off and punctuation kept: what a word chip shows
    /// ("star,").
    public var typed: String
    /// The word as it is sung: punctuation dropped, hyphen parts joined (with
    /// a space across a digit), an apostrophe kept only inside the word
    /// ("twin-kle," sings "twinkle"; "3-2-1" sings "3 2 1"; "lovin'" sings
    /// "lovin"; "3.5" stays "3.5" for the facade to read aloud). Never holds
    /// a hyphen.
    public var sung: String
    /// The hyphen parts, in order ("twin", "kle"). One element for a word
    /// with no hyphen. Each part asks for one note of its own.
    public var parts: [String]
    /// How many `+` marks follow this word. Each one means "this word also
    /// takes the next note" (a tie, not a new syllable).
    public var holds: Int
    /// The line of the text this word is on, 0-based, counting empty lines.
    public var line: Int
    /// True for a number ("99", "2nd", "3.5"): the engine's text front end
    /// reads it aloud (design §3.2).
    public var isNumber: Bool
    /// False when the word uses a letter or digit that is not English
    /// ("café", "straße"). The assigner refuses the whole text then.
    public var isEnglish: Bool

    public init(typed: String, sung: String, parts: [String], holds: Int = 0, line: Int = 0,
                isNumber: Bool = false, isEnglish: Bool = true) {
        self.typed = typed
        self.sung = sung
        self.parts = parts
        self.holds = holds
        self.line = line
        self.isNumber = isNumber
        self.isEnglish = isEnglish
    }

    /// The notes the typed markup asks for: one per hyphen part, plus one per
    /// `+`. At least 1.
    public var markedNotes: Int { max(1, parts.count) + holds }

    /// True when the user marked this word by hand (hyphen parts or a `+`).
    /// Markup is honoured first and never re-shared (design §3.3 rule 3).
    public var hasMarkup: Bool { parts.count > 1 || holds > 0 }
}

/// Typed lyrics, split into words and lines. Pure data: `LyricTokenizer`
/// makes it, `LyricNoteAssigner` reads it.
public struct LyricText: Equatable, Sendable {
    /// Every word, in reading order.
    public var words: [LyricWord]
    /// Lines (0-based, as in `LyricWord.line`) holding a `+` that had no word
    /// before it on the same line. Those marks are ignored, and the assigner
    /// says so with a warning.
    public var orphanHoldLines: [Int]

    public init(words: [LyricWord], orphanHoldLines: [Int] = []) {
        self.words = words
        self.orphanHoldLines = orphanHoldLines
    }

    /// The NON-EMPTY lines, in order: each one the words of one text line.
    /// A line with no words (blank, or only punctuation) is not a line here;
    /// design §3.3 rule 1 counts only non-empty lines.
    public var lines: [[LyricWord]] {
        var out: [[LyricWord]] = []
        for word in words {
            if let last = out.last?.last, last.line == word.line {
                out[out.count - 1].append(word)
            } else {
                out.append([word])
            }
        }
        return out
    }

    /// The words that are not English, in order.
    public var nonEnglishWords: [LyricWord] { words.filter { !$0.isEnglish } }
}

/// Splits typed lyrics into words and lines (design §3.2).
///
/// - **Words** split on whitespace. A dash (— or –), an ellipsis (…), a slash,
///   and two or more hyphens or dots in a row also separate words, so
///   "wait...what" and "love—hate" are two words each.
/// - **Punctuation** is dropped for singing but kept in `LyricWord.typed`.
///   Curly apostrophes (’ ‘ ʼ) become `'` before anything else happens.
/// - **Line breaks** separate lines, which rule 1 of the assigner uses.
/// - **`+`** standing alone means "the previous word also takes the next
///   note". OpenUtau's **`+~`** means the same (design §3.2: the engine makes
///   no distinction between a new syllable and a tie). `++` is two holds. A `+`
///   glued to the end of a word ("star+") counts the same as one standing
///   alone; glued to the front ("+star") it belongs to the word before.
/// - **A hyphen inside a word** ("twin-kle") asks for one note per part; the
///   word is sung joined ("twinkle"), except across a digit ("3-2-1" sings
///   "3 2 1", never "321"). So `LyricWord.sung` never holds a hyphen, and the
///   singing facade's hyphen-to-space rule (`scripts/sing/singlib/phonemes.py`)
///   can never re-split a lyric word ("twin kle").
/// - **Non-English words** (a letter or digit outside A–Z, a–z, 0–9) are
///   marked, and the assigner refuses the text with a sentence naming the
///   first one. Accents count as non-English, as the design states.
/// - **Numbers** are ONE lyric word each ("42", "2nd", "3.5", "1,000"), even
///   though they are sung as several ("forty two"). The facade expands a word
///   with g2p_en's own `normalize_numbers` and sings the whole expansion across
///   that one word's notes, and `EnglishSyllables` counts the expansion (3 for
///   "42"), so spare notes still go where the syllables are (rule 5.1). Design
///   §3.2's "[A] g2p_en's own normalisation" was refuted by p2-sing-b: it is the
///   facade's pre-step that makes this true. A lone "&" is sung as "and".
public enum LyricTokenizer {

    public static func tokenize(_ text: String) -> LyricText {
        scan(text).text
    }

    /// The characters read as an apostrophe and straightened to `'` before
    /// anything else: U+2019 (’), U+2018 (‘) and U+02BC (ʼ). THE ONE LIST:
    /// `WordErrorRate` maps the same three (design §4.6), so the words the
    /// word check scores are the words this tokenizer produced.
    public static let curlyApostrophes: Set<Unicode.Scalar> = ["\u{2019}", "\u{2018}", "\u{02BC}"]

    // MARK: - Where each word begins (p2-sing-d1b: splitting a clip's text)

    /// Where each word of `tokenize(text)` begins in `text`, as a `Character`
    /// offset: at its first own character, after any `+` marks glued to its
    /// front (those belong to the word before). One entry per word, in order.
    ///
    /// It comes out of the SAME scan as `tokenize`, not a second parser, so
    /// a cut made here can never disagree with the words the assigner saw.
    static func wordStartOffsets(_ text: String) -> [Int] {
        scan(text).offsets
    }

    /// Cuts `text` in two so that words `0..<k` are on the left and the rest
    /// on the right (the clip-split rule, `ClipLyrics.WordPlacement.split`).
    ///
    /// The cut falls at word k's first own character, so punctuation, `+`
    /// marks and line breaks before it stay left, and everything from it on
    /// goes right, verbatim. Only the whitespace at the very end of the left
    /// part is dropped (it separated the two halves). `k <= 0` puts all of
    /// the text right, `k >= ` the word count puts it all left.
    static func cut(_ text: String, beforeWord k: Int) -> (left: String, right: String) {
        let count = wordStartOffsets(text).count
        guard k > 0 else { return ("", text) }
        guard k < count else { return (text, "") }
        return (slice(text, words: 0..<k), slice(text, words: k..<count))
    }

    /// The part of `text` that holds the words in `range`: from word
    /// `range.lowerBound`'s first own character (from the very start of the
    /// text when that is word 0) up to word `range.upperBound`'s (to the very
    /// end when there is none). When it stops before a word, the whitespace
    /// at its end is dropped. An empty range is "".
    static func slice(_ text: String, words range: Range<Int>) -> String {
        let offsets = wordStartOffsets(text)
        guard !range.isEmpty, range.lowerBound < offsets.count else { return "" }
        let chars = Array(text)
        let start = range.lowerBound <= 0 ? 0 : offsets[range.lowerBound]
        guard range.upperBound < offsets.count else { return String(chars[start...]) }
        var part = chars[start..<offsets[range.upperBound]]
        while let last = part.last, last.isWhitespace { part.removeLast() }
        return String(part)
    }

    // MARK: - The scan

    /// `tokenize`'s body, which also records where each word starts. Works on
    /// an array of `Character`s so that offsets into it are offsets into
    /// `text`: the curly map is one character for one, and `separatingWords`
    /// keeps the line's length.
    private static func scan(_ text: String) -> (text: LyricText, offsets: [Int]) {
        var words: [LyricWord] = []
        var offsets: [Int] = []
        var orphanHoldLines: [Int] = []
        let straightened: [Character] = text.map { curlyApostropheCharacters.contains($0) ? "'" : $0 }

        // Lines, as `split(omittingEmptySubsequences: false, whereSeparator:
        // \.isNewline)` would cut them: an empty text is one empty line, and
        // a trailing line break leaves an empty last line.
        var lineStart = 0
        var lineIndex = 0
        while true {
            var lineEnd = lineStart
            while lineEnd < straightened.count, !straightened[lineEnd].isNewline { lineEnd += 1 }
            let line = separatingWords(straightened[lineStart..<lineEnd])

            var lineWords: [LyricWord] = []
            func addHolds(_ count: Int) {
                guard count > 0 else { return }
                if lineWords.isEmpty {
                    if orphanHoldLines.last != lineIndex { orphanHoldLines.append(lineIndex) }
                } else {
                    lineWords[lineWords.count - 1].holds += count
                }
            }
            // Tokens: the runs of non-whitespace, as `split(whereSeparator:
            // \.isWhitespace)` would cut them.
            var k = 0
            while k < line.count {
                guard !line[k].isWhitespace else { k += 1; continue }
                let tokenStart = k
                while k < line.count, !line[k].isWhitespace { k += 1 }
                var token = String(line[tokenStart..<k])
                let length = token.count
                let leading = peelMarks(&token, fromEnd: false)
                let wordStart = lineStart + tokenStart + (length - token.count)
                let trailing = peelMarks(&token, fromEnd: true)
                addHolds(leading)
                if token == "&" {
                    lineWords.append(LyricWord(typed: "&", sung: "and", parts: ["and"], holds: trailing,
                                               line: lineIndex))
                    offsets.append(wordStart)
                    continue
                }
                guard var word = makeWord(typed: token, line: lineIndex) else {
                    addHolds(trailing)          // "!+" : the mark still belongs to the word before
                    continue
                }
                word.holds = trailing
                lineWords.append(word)
                offsets.append(wordStart)
            }
            words += lineWords
            guard lineEnd < straightened.count else { break }
            lineStart = lineEnd + 1
            lineIndex += 1
        }
        return (LyricText(words: words, orphanHoldLines: orphanHoldLines), offsets)
    }

    // MARK: - Pieces

    private static let curlyApostropheCharacters: Set<Character> = Set(curlyApostrophes.map(Character.init))
    private static let wordSeparators: Set<Character> = ["\u{2014}", "\u{2013}", "\u{2012}", "\u{2015}", "\u{2026}", "/", "\\"]

    /// Replaces word-separating punctuation with spaces: dashes, an ellipsis,
    /// slashes, and runs of two or more hyphens or dots. One space per
    /// character replaced, so the line keeps its length and a word's offset in
    /// it is its offset in the text (the tokens are the same as if each run
    /// became one space: tokens split on runs of whitespace).
    private static func separatingWords(_ line: ArraySlice<Character>) -> [Character] {
        let chars = Array(line)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var k = 0
        while k < chars.count {
            let ch = chars[k]
            if wordSeparators.contains(ch) {
                out.append(" ")
                k += 1
            } else if (ch == "-" || ch == "."), k + 1 < chars.count, chars[k + 1] == ch {
                while k < chars.count, chars[k] == ch {
                    out.append(" ")
                    k += 1
                }
            } else {
                out.append(ch)
                k += 1
            }
        }
        return out
    }

    /// Removes a run of `+` / `+~` marks from one end of `token` and returns
    /// how many `+` it held.
    private static func peelMarks(_ token: inout String, fromEnd: Bool) -> Int {
        var count = 0
        while true {
            if fromEnd {
                if token.hasSuffix("+~") { token.removeLast(2); count += 1 }
                else if token.hasSuffix("+") { token.removeLast(); count += 1 }
                else { return count }
            } else {
                if token.hasPrefix("+~") { token.removeFirst(2); count += 1 }
                else if token.hasPrefix("+") { token.removeFirst(); count += 1 }
                else { return count }
            }
        }
    }

    /// "'cause" sings "cause" and "lovin'" sings "lovin": an apostrophe is
    /// kept only inside a word ("don't").
    private static func trimmingApostrophes(_ part: String) -> String {
        var trimmed = Substring(part)
        while trimmed.first == "'" { trimmed.removeFirst() }
        while trimmed.last == "'" { trimmed.removeLast() }
        return String(trimmed)
    }

    /// One word from a token with its marks already peeled, or nil when the
    /// token is only punctuation.
    private static func makeWord(typed: String, line: Int) -> LyricWord? {
        let chars = Array(typed)
        var parts: [String] = []
        var current = ""
        var english = true
        for (k, ch) in chars.enumerated() {
            if ch.isASCII && (ch.isLetter || ch.isNumber) {
                current.append(ch)
            } else if ch == "'" {
                current.append(ch)
            } else if ch == "-" {
                parts.append(current)
                current = ""
            } else if (ch == "." || ch == ","), k > 0, k + 1 < chars.count,
                      chars[k - 1].isASCII, chars[k - 1].isNumber,
                      chars[k + 1].isASCII, chars[k + 1].isNumber {
                current.append(ch)                                   // 3.5, 1,000
            } else if ch.isLetter || ch.isNumber {
                current.append(ch)                                   // café: kept, and refused
                english = false
            }
            // Anything else is punctuation or a symbol: dropped for singing.
        }
        parts.append(current)
        parts = parts.map(trimmingApostrophes).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        // Parts are sung joined ("twin-kle" sings "twinkle"), except across a
        // digit: "3-2-1" sings "3 2 1" ("three two one"), never "321".
        var sung = parts[0]
        for part in parts.dropFirst() {
            if let left = sung.last, let right = part.first,
               (left.isASCII && left.isNumber) || (right.isASCII && right.isNumber) {
                sung += " "
            }
            sung += part
        }
        return LyricWord(typed: typed, sung: sung, parts: parts, holds: 0, line: line,
                         isNumber: sung.contains { $0.isASCII && $0.isNumber }, isEnglish: english)
    }
}
