import Foundation
import Testing
@testable import DAWCore

/// p2-sing-d1: `LyricTokenizer`, typed lyrics into words and lines (design
/// §3.2). NOT `@MainActor`: pure functions.
@Suite("Lyric tokenizer — words, lines, markup (p2-sing-d1)")
struct LyricTokenizerTests {

    private func words(_ text: String) -> [LyricWord] { LyricTokenizer.tokenize(text).words }

    // MARK: Words and lines

    @Test("words split on whitespace; line breaks separate lines; empty lines are not lines")
    func wordsAndLines() {
        let text = LyricTokenizer.tokenize("Twinkle twinkle\n\n  little   star \r\nhow I wonder")
        #expect(text.words.map(\.sung) == ["Twinkle", "twinkle", "little", "star", "how", "I", "wonder"])
        #expect(text.words.map(\.line) == [0, 0, 2, 2, 3, 3, 3])
        #expect(text.lines.count == 3)
        #expect(text.lines.map { $0.map(\.sung) } == [["Twinkle", "twinkle"], ["little", "star"], ["how", "I", "wonder"]])
    }

    @Test("a line of only punctuation is not a line")
    func punctuationOnlyLine() {
        let text = LyricTokenizer.tokenize("la la\n...!\nla")
        #expect(text.lines.count == 2)
    }

    // MARK: Punctuation, apostrophes, separators

    @Test("punctuation is dropped for singing and kept in what was typed")
    func punctuation() {
        let w = words("Hello, world! (Yes.) \"Quoted\"")
        #expect(w.map(\.sung) == ["Hello", "world", "Yes", "Quoted"])
        #expect(w.map(\.typed) == ["Hello,", "world!", "(Yes.)", "\"Quoted\""])
    }

    @Test("curly apostrophes become straight ones; an apostrophe survives only inside a word")
    func apostrophes() {
        let w = words("Don’t can‘t ʼtil lovin' 'cause rock'n'roll")
        #expect(w.map(\.sung) == ["Don't", "can't", "til", "lovin", "cause", "rock'n'roll"])
        #expect(w[0].typed == "Don't")
    }

    @Test("dashes, an ellipsis, slashes and runs of hyphens or dots separate words")
    func separators() {
        #expect(words("love—hate love–hate wait…what wait...what and/or no--way").map(\.sung)
                == ["love", "hate", "love", "hate", "wait", "what", "wait", "what", "and", "or", "no", "way"])
    }

    @Test("a lone & is sung as 'and'")
    func ampersand() {
        #expect(words("rock & roll").map(\.sung) == ["rock", "and", "roll"])
    }

    // MARK: Markup

    @Test("+ and +~ each give the previous word one more note")
    func holds() {
        let w = words("star + + shine +~ bright")
        #expect(w.map(\.sung) == ["star", "shine", "bright"])
        #expect(w.map(\.holds) == [2, 1, 0])
        #expect(w.map(\.markedNotes) == [3, 2, 1])
        #expect(w.map(\.hasMarkup) == [true, true, false])
    }

    @Test("marks glued to a word count the same as marks standing alone")
    func gluedMarks() {
        let w = words("star+ shine+~+ +bright")
        #expect(w.map(\.sung) == ["star", "shine", "bright"])
        // "+bright": a leading mark belongs to the word before ("shine").
        #expect(w.map(\.holds) == [1, 3, 0])
        #expect(words("go ++").map(\.holds) == [2])
    }

    @Test("a + with no word before it on its line is ignored and reported")
    func orphanHold() {
        let text = LyricTokenizer.tokenize("+ la\nla\n+ la +")
        #expect(text.words.map(\.holds) == [0, 0, 1])
        #expect(text.orphanHoldLines == [0, 2])
    }

    @Test("a hyphen inside a word asks for one note per part and sings the joined word")
    func hyphenParts() {
        let w = words("twin-kle, beau-ti-ful -dash trail-")
        #expect(w.map(\.sung) == ["twinkle", "beautiful", "dash", "trail"])
        #expect(w.map(\.parts) == [["twin", "kle"], ["beau", "ti", "ful"], ["dash"], ["trail"]])
        #expect(w.map(\.markedNotes) == [2, 3, 1, 1])
    }

    // MARK: Refusable words and numbers

    @Test("letters outside English are marked; accents count, as the design states")
    func nonEnglish() {
        let text = LyricTokenizer.tokenize("hello café straße привет ok")
        #expect(text.words.map(\.isEnglish) == [true, false, false, false, true])
        #expect(text.nonEnglishWords.map(\.sung) == ["café", "straße", "привет"])
    }

    @Test("numbers are one word each; a decimal point and a thousands comma stay inside")
    func numbers() {
        let w = words("99 bottles, 2nd time, 3.5 miles, 1,000 ways. 7!")
        #expect(w.map(\.sung) == ["99", "bottles", "2nd", "time", "3.5", "miles", "1,000", "ways", "7"])
        #expect(w.map(\.isNumber) == [true, false, true, false, true, false, true, false, true])
        #expect(w.allSatisfy { $0.isEnglish })
    }

    /// The rule agreed with the singing facade (p2-sing-b, deviation 8): the
    /// facade expands a word's text ("42" to "forty two", hyphens to spaces)
    /// and sings the expansion across THAT word's notes, so a number stays one
    /// lyric word here and nothing sung carries a hyphen.
    @Test("a number or a hyphenated word stays ONE lyric word, and nothing sung carries a hyphen")
    func numbersAndHyphensStayOneWord() {
        let w = words("42 well-known 1999 21st 3-2-1")
        #expect(w.map(\.sung) == ["42", "wellknown", "1999", "21st", "3 2 1"])
        #expect(w.map(\.markedNotes) == [1, 2, 1, 1, 3])
        let sung = words("twin-kle well-known a-b-c --x-- 3-2-1 -dash trail- 9-to-5").map(\.sung)
        #expect(sung == ["twinkle", "wellknown", "abc", "x", "3 2 1", "dash", "trail", "9 to 5"])
        #expect(sung.allSatisfy { !$0.contains("-") })
    }

    @Test("an empty or blank text has no words")
    func empty() {
        #expect(words("").isEmpty)
        #expect(words("  \n \n\t").isEmpty)
        #expect(words("!?.,").isEmpty)
    }
}
