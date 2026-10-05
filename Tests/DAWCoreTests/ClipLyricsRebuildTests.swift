import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d1b: when an edit cuts a melody clip into pieces, each piece keeps
/// the words that START on its own notes (`ClipLyrics.WordPlacement`), and the
/// text is cut between words by `LyricTokenizer`'s own scan. Pure values, so
/// NOT `@MainActor`. The store sites (split, trims, duplicate, paste, the bar
/// insert/delete, take flatten, save/reopen) are pinned by SD2's extension of
/// `ProjectStoreClipEditTests` in `ClipLyricsRebuildStoreTests.swift`.
@Suite("Clip lyrics when a clip is cut: the words go with the notes they start on (p2-sing-d1b)")
struct ClipLyricsRebuildTests {

    static let tempo = TempoMap(constantBPM: 120)

    /// One note per onset, `length` beats each, pitches rising.
    static func melody(_ onsets: [Double], length: Double = 1, lyrics: String?) -> Clip {
        let notes = onsets.enumerated().map {
            MIDINote(pitch: 60 + $0.offset, startBeat: $0.element, lengthBeats: length)
        }
        return Clip(name: "Melody", lengthBeats: (onsets.last ?? 0) + length, notes: notes,
                    lyrics: lyrics.map { ClipLyrics(text: $0) })
    }

    // MARK: - Where words start, and cutting the text

    @Test("each word starts at its first own character; a + glued to its front belongs to the word before")
    func wordStartOffsets() {
        #expect(LyricTokenizer.wordStartOffsets("twin-kle, twin-kle +\nlit-tle star") == [0, 10, 21, 29])
        #expect(LyricTokenizer.wordStartOffsets("la +la") == [0, 4])
        #expect(LyricTokenizer.wordStartOffsets("don’t stop") == [0, 6])
        #expect(LyricTokenizer.wordStartOffsets("wait...what love—hate") == [0, 7, 12, 17])
        #expect(LyricTokenizer.wordStartOffsets("la ! la") == [0, 5])
        #expect(LyricTokenizer.wordStartOffsets("rock & roll") == [0, 5, 7])
        #expect(LyricTokenizer.wordStartOffsets("  \n ") == [])
        #expect(LyricTokenizer.wordStartOffsets("") == [])
    }

    @Test("the text is cut between words, verbatim: punctuation, + marks and line breaks stay with what they follow")
    func cutBetweenWords() {
        let text = "twin-kle, twin-kle +\nlit-tle star"
        let (l0, r0) = LyricTokenizer.cut(text, beforeWord: 0)
        #expect(l0 == "")
        #expect(r0 == text)
        let (l1, r1) = LyricTokenizer.cut(text, beforeWord: 1)
        #expect(l1 == "twin-kle,")
        #expect(r1 == "twin-kle +\nlit-tle star")
        let (l2, r2) = LyricTokenizer.cut(text, beforeWord: 2)
        #expect(l2 == "twin-kle, twin-kle +", "the hold stays with its word; the line break that parted them goes")
        #expect(r2 == "lit-tle star")
        let (l4, r4) = LyricTokenizer.cut(text, beforeWord: 4)
        #expect(l4 == text)
        #expect(r4 == "")
        let (lh, rh) = LyricTokenizer.cut("la +la", beforeWord: 1)
        #expect(lh == "la +", "a + glued to the front of a word holds the word BEFORE it")
        #expect(rh == "la")
        #expect(LyricTokenizer.slice(text, words: 1..<3) == "twin-kle +\nlit-tle")
        #expect(LyricTokenizer.slice(text, words: 2..<2) == "")
    }

    /// Texts built from pieces that exercise every tokenizer rule: markup,
    /// the three curly apostrophes, numbers, separators, non-English letters,
    /// combining marks, emoji, every kind of line break and odd spaces.
    static let pieces: [String] = [
        "la", "Twin-kle,", "don’t", "don‘t", "donʼt", "lovin’", "'cause", "3-2-1", "42", "3.5", "1,000", "2nd",
        "café", "straße", "&", "+", "+~", "++", "star+", "+star", "!", "!+", ",", "...", "..", "--", "-", ".",
        "—", "–", "…", "/", "\\", "'", "e\u{301}", "\u{301}", "👍🏽", "🇺🇸", "\u{0600}1", "wait...what",
        "love—hate", "x/y", "a", "Z", "\t", "\r\n", "\n", "\r", "\u{2028}", " ", "  ", "\u{00A0}",
    ]
    static let joiners = [" ", "", "\n", "  ", ", "]

    static func randomText(_ rng: inout LyricFuzzRNG) -> String {
        var text = ""
        for _ in 0..<Int.random(in: 0...10, using: &rng) {
            text += pieces[Int.random(in: 0..<pieces.count, using: &rng)]
            text += joiners[Int.random(in: 0..<joiners.count, using: &rng)]
        }
        return text
    }

    /// A word as the assigner reads it, minus its line (a cut renumbers lines).
    static func shape(_ word: LyricWord) -> String {
        "\(word.typed)|\(word.sung)|\(word.parts)|\(word.holds)|\(word.isNumber)|\(word.isEnglish)"
    }

    @Test("⭐ tokenize is unchanged by the one-scan rewrite (1500 seeded texts vs a frozen copy of the old tokenizer), and every cut splits the words exactly")
    func tokenizeUnchangedAndCutsAreExact() {
        var rng = LyricFuzzRNG(seed: 0x70_4E17_5D2)
        var withWords = 0
        var cuts = 0
        for _ in 0..<1500 {
            let text = Self.randomText(&rng)
            let now = LyricTokenizer.tokenize(text)
            let before = PreD1bLyricTokenizer.tokenize(text)
            #expect(now == before, "text: \(text.debugDescription)")
            let words = now.words
            let offsets = LyricTokenizer.wordStartOffsets(text)
            #expect(offsets.count == words.count, "text: \(text.debugDescription)")
            if !words.isEmpty { withWords += 1 }
            for k in 0...words.count {
                let (left, right) = LyricTokenizer.cut(text, beforeWord: k)
                let leftWords = LyricTokenizer.tokenize(left).words
                let rightWords = LyricTokenizer.tokenize(right).words
                let leftShapes = leftWords.map(Self.shape)
                let rightShapes = rightWords.map(Self.shape)
                let expectedLeft = words.prefix(k).map(Self.shape)
                let expectedRight = words.dropFirst(k).map(Self.shape)
                #expect(leftShapes == expectedLeft, "cut \(k) of \(text.debugDescription)")
                #expect(rightShapes == expectedRight, "cut \(k) of \(text.debugDescription)")
                // Lines survive too: the left keeps its numbers, the right counts from its first word's line.
                // Except at k == 0: the right is then the WHOLE text, verbatim (`cut`'s documented rule, so
                // leading line breaks typed before the first word are kept), and keeps the text's own numbers.
                let leftLines = leftWords.map { $0.line }
                let rightLines = rightWords.map { $0.line }
                let expectedLeftLines = words.prefix(k).map { $0.line }
                let firstRightLine = (k > 0 && k < words.count) ? words[k].line : 0
                let expectedRightLines = words.dropFirst(k).map { $0.line - firstRightLine }
                #expect(leftLines == expectedLeftLines, "cut \(k) of \(text.debugDescription)")
                #expect(rightLines == expectedRightLines, "cut \(k) of \(text.debugDescription)")
                cuts += 1
            }
        }
        #expect(withWords > 1000, "control: most texts have words (\(withWords))")
        #expect(cuts > 4000, "control: many cuts checked (\(cuts))")
    }

    @Test("control: the frozen copy is not the live tokenizer (it disagrees once a rule is changed by hand)")
    func frozenCopyIsIndependent() {
        // The live tokenizer maps U+02BC to an apostrophe; a copy that did not
        // would disagree on "donʼt". This pins that the differential test above
        // compares two implementations, not one implementation with itself.
        #expect(PreD1bLyricTokenizer.tokenize("donʼt").words.first?.sung == "don't")
        #expect(PreD1bLyricTokenizer.tokenizeWithoutCurlyMap("donʼt").words.first?.sung
                != LyricTokenizer.tokenize("donʼt").words.first?.sung)
    }

    // MARK: - Splitting a clip's text

    @Test("a split gives each half the words that start on its notes, both ways")
    func splitBothWays() throws {
        let clip = Self.melody([0, 1, 2, 3], lyrics: "one two\nthree four")
        let placement = try #require(ClipLyrics.WordPlacement(clip: clip, tempoMap: Self.tempo))
        #expect(placement.onsets == [0, 1, 2, 3])
        let mid = placement.split(atClipBeat: 2)
        #expect(mid.left == ClipLyrics(text: "one two"))
        #expect(mid.right == ClipLyrics(text: "three four"))
        let inside = placement.split(atClipBeat: 2.5)
        #expect(inside.left == ClipLyrics(text: "one two\nthree"), "'three' started before the cut: it stays left")
        #expect(inside.right == ClipLyrics(text: "four"))
        let early = placement.split(atClipBeat: 0.5)
        #expect(early.left == ClipLyrics(text: "one"))
        #expect(early.right == ClipLyrics(text: "two\nthree four"))
        let atZero = placement.split(atClipBeat: 0)
        #expect(atZero.left == nil)
        #expect(atZero.right == ClipLyrics(text: "one two\nthree four"))
        let pastAll = placement.split(atClipBeat: 3.5)
        #expect(pastAll.left == ClipLyrics(text: "one two\nthree four"))
        #expect(pastAll.right == nil)
    }

    @Test("a held word (a melisma) goes with the note it STARTS on")
    func heldWordGoesWithItsFirstNote() throws {
        let clip = Self.melody([0, 1, 2], lyrics: "hel-lo world")
        let placement = try #require(ClipLyrics.WordPlacement(clip: clip, tempoMap: Self.tempo))
        #expect(placement.onsets == [0, 2])
        let halves = placement.split(atClipBeat: 1.5)
        #expect(halves.left == ClipLyrics(text: "hel-lo"))
        #expect(halves.right == ClipLyrics(text: "world"))
    }

    @Test("text the assigner refuses stays whole on the left, and the right gets none")
    func refusedTextStaysLeft() throws {
        for text in ["one two three", "café au lait"] {
            let clip = Self.melody([0, 1], lyrics: text)
            let placement = try #require(ClipLyrics.WordPlacement(clip: clip, tempoMap: Self.tempo))
            #expect(placement.onsets == nil, "\(text)")
            let halves = placement.split(atClipBeat: 1)
            #expect(halves.left == ClipLyrics(text: text))
            #expect(halves.right == nil)
        }
        #expect(ClipLyrics.WordPlacement(clip: Self.melody([0], lyrics: nil), tempoMap: Self.tempo) == nil)
    }

    @Test("a comp member carries the words that start in its window; unplaceable text goes whole to the first")
    func windows() throws {
        let clip = Self.melody([0, 1, 2, 3], lyrics: "one two\nthree four")
        let placement = try #require(ClipLyrics.WordPlacement(clip: clip, tempoMap: Self.tempo))
        #expect(placement.window(0..<2, isFirstWindow: true) == ClipLyrics(text: "one two"))
        #expect(placement.window(1..<3, isFirstWindow: false) == ClipLyrics(text: "two\nthree"))
        #expect(placement.window(2.5..<4, isFirstWindow: false) == ClipLyrics(text: "four"))
        #expect(placement.window(3.5..<4, isFirstWindow: false) == nil)

        let refused = try #require(ClipLyrics.WordPlacement(clip: Self.melody([0], lyrics: "one two"),
                                                            tempoMap: Self.tempo))
        #expect(refused.window(0..<1, isFirstWindow: true) == ClipLyrics(text: "one two"))
        #expect(refused.window(0..<1, isFirstWindow: false) == nil)
    }

    @Test("distribute: two pieces are a split; one piece is the only survivor and keeps what it carried")
    func distribute() {
        let source = Self.melody([0, 1, 2, 3], lyrics: "one two\nthree four")
        var head = source
        head.lengthBeats = 2
        var tail = source
        tail.startBeat = 10
        let two = ClipLyrics.distribute([head, tail], cutFrom: source, atClipBeat: 2, tempoMap: Self.tempo)
        #expect(two.count == 2)
        #expect(two.first?.lyrics == ClipLyrics(text: "one two"))
        #expect(two.last?.lyrics == ClipLyrics(text: "three four"))
        let one = ClipLyrics.distribute([tail], cutFrom: source, atClipBeat: 2, tempoMap: Self.tempo)
        #expect(one == [tail])
        let plain = Self.melody([0, 1], lyrics: nil)
        let untouched = ClipLyrics.distribute([plain, plain], cutFrom: plain, atClipBeat: 1, tempoMap: Self.tempo)
        #expect(untouched == [plain, plain])
    }

    // MARK: - Take flatten (CompFlattener, pure)

    @Test("take flatten: each comp member carries its own lane's words for its window, none twice")
    func flattenMembers() {
        let one = TakeLane(name: "Take 1", clip: Self.melody([0, 1, 2, 3], lyrics: "one two three four"))
        let two = TakeLane(name: "Take 2", clip: Self.melody([0, 1, 2, 3], lyrics: "uno dos tres cuatro"))
        let group = TakeGroup(name: "Takes", lanes: [one, two],
                              comp: [CompSegment(laneID: one.id, startBeat: 0, endBeat: 2),
                                     CompSegment(laneID: two.id, startBeat: 2, endBeat: 3),
                                     CompSegment(laneID: one.id, startBeat: 3, endBeat: 4)])
        let members = CompFlattener.flatten(group, tempoMap: Self.tempo)
        let texts = members.map { $0.lyrics?.text }
        #expect(texts == ["one two", "tres", "four"])
        let laneTexts = group.lanes.map { $0.clip.lyrics?.text }
        #expect(laneTexts == ["one two three four", "uno dos tres cuatro"], "the lanes keep their whole text")
    }

    @Test("take flatten: a lane whose text cannot be placed gives all of it to its FIRST member only")
    func flattenRefusedLane() {
        let lane = TakeLane(name: "Take 1", clip: Self.melody([0, 1], lyrics: "one two three"))
        let group = TakeGroup(name: "Takes", lanes: [lane],
                              comp: [CompSegment(laneID: lane.id, startBeat: 1, endBeat: 2),
                                     CompSegment(laneID: lane.id, startBeat: 0, endBeat: 1)])
        let members = CompFlattener.flatten(group, tempoMap: Self.tempo)
        let texts = members.map { $0.lyrics?.text }
        #expect(texts == ["one two three", nil], "the first member in time order keeps it all")
    }

    @Test("take flatten: an audio lane and a lane without lyrics give members none")
    func flattenWithoutLyrics() {
        let audio = TakeLane(name: "Vox", clip: Clip(name: "Vox", lengthBeats: 4,
                                                     audioFileURL: URL(fileURLWithPath: "/tmp/sd2-take.wav")))
        let plain = TakeLane(name: "Keys", clip: Self.melody([0, 1, 2, 3], lyrics: nil))
        for lane in [audio, plain] {
            let group = TakeGroup(name: "Takes", lanes: [lane],
                                  comp: [CompSegment(laneID: lane.id, startBeat: 0, endBeat: 4)])
            let members = CompFlattener.flatten(group, tempoMap: Self.tempo)
            let texts = members.map { $0.lyrics?.text }
            #expect(texts == [nil])
        }
    }
}

/// SplitMix64, seeded: the same texts on every run.
struct LyricFuzzRNG: RandomNumberGenerator {
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

/// ⛔ FROZEN: `LyricTokenizer.tokenize` exactly as W7-SD1 installed it (the
/// tree's `Sources/DAWCore/LyricTokenizer.swift` before p2-sing-d1b, sha256
/// 8c04a868…), kept ONLY as the reference for the differential test above.
/// p2-sing-d1b rewrote `tokenize` as one scan that also reports where each
/// word starts; this copy proves the words did not change. Never edit it to
/// make a test pass.
enum PreD1bLyricTokenizer {

    static func tokenize(_ text: String) -> LyricText {
        tokenize(text, mapsCurlyApostrophes: true)
    }

    /// The same, with the curly-apostrophe map switched off: the control that
    /// shows this copy is a separate implementation.
    static func tokenizeWithoutCurlyMap(_ text: String) -> LyricText {
        tokenize(text, mapsCurlyApostrophes: false)
    }

    private static func tokenize(_ text: String, mapsCurlyApostrophes: Bool) -> LyricText {
        var words: [LyricWord] = []
        var orphanHoldLines: [Int] = []
        let straightened = text.map {
            mapsCurlyApostrophes && curlyApostrophes.contains($0) ? "'" : String($0)
        }.joined()

        for (lineIndex, line) in straightened.split(omittingEmptySubsequences: false,
                                                    whereSeparator: \.isNewline).enumerated() {
            var lineWords: [LyricWord] = []
            func addHolds(_ count: Int) {
                guard count > 0 else { return }
                if lineWords.isEmpty {
                    if orphanHoldLines.last != lineIndex { orphanHoldLines.append(lineIndex) }
                } else {
                    lineWords[lineWords.count - 1].holds += count
                }
            }
            for rawToken in separatingWords(String(line)).split(whereSeparator: \.isWhitespace) {
                var token = String(rawToken)
                let leading = peelMarks(&token, fromEnd: false)
                let trailing = peelMarks(&token, fromEnd: true)
                addHolds(leading)
                if token == "&" {
                    lineWords.append(LyricWord(typed: "&", sung: "and", parts: ["and"], holds: trailing,
                                               line: lineIndex))
                    continue
                }
                guard var word = makeWord(typed: token, line: lineIndex) else {
                    addHolds(trailing)
                    continue
                }
                word.holds = trailing
                lineWords.append(word)
            }
            words += lineWords
        }
        return LyricText(words: words, orphanHoldLines: orphanHoldLines)
    }

    private static let curlyApostrophes: Set<Character> = ["\u{2019}", "\u{2018}", "\u{02BC}"]
    private static let wordSeparators: Set<Character> = ["\u{2014}", "\u{2013}", "\u{2012}", "\u{2015}", "\u{2026}", "/", "\\"]

    private static func separatingWords(_ line: String) -> String {
        let chars = Array(line)
        var out = ""
        var k = 0
        while k < chars.count {
            let ch = chars[k]
            if wordSeparators.contains(ch) {
                out.append(" ")
                k += 1
            } else if (ch == "-" || ch == "."), k + 1 < chars.count, chars[k + 1] == ch {
                while k < chars.count, chars[k] == ch { k += 1 }
                out.append(" ")
            } else {
                out.append(ch)
                k += 1
            }
        }
        return out
    }

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

    private static func trimmingApostrophes(_ part: String) -> String {
        var trimmed = Substring(part)
        while trimmed.first == "'" { trimmed.removeFirst() }
        while trimmed.last == "'" { trimmed.removeLast() }
        return String(trimmed)
    }

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
                current.append(ch)
            } else if ch.isLetter || ch.isNumber {
                current.append(ch)
                english = false
            }
        }
        parts.append(current)
        parts = parts.map(trimmingApostrophes).filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
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
