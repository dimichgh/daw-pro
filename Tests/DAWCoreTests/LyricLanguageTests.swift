import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x3: languages in the domain (design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §6.3, §6.6's "CJK tokenizer"
/// row, §6.7, §6.10). NOT `@MainActor`: pure values and functions.
///
/// The tokenizer table is EXACT: cutting Chinese text into words is a rule,
/// not an estimate (§6.6). Every row also checks the invariant
/// `LyricTextEdit.Scan` relies on: each word's `typed` sits in the text at its
/// start offset, character for character.
@Suite("Languages in the lyrics: Chinese words, syllables, the clip's language (p2-sing-x3)")
struct LyricLanguageTests {

    // MARK: - Helpers

    /// One word as "typed/sung/language/holds/line" (language "-" for English).
    static func describe(_ word: LyricWord) -> String {
        "\(word.typed)/\(word.sung)/\(word.language ?? "-")/\(word.holds)/\(word.line)"
    }

    static func row(_ text: String, _ language: String?) -> [String] {
        LyricTokenizer.tokenize(text, language: language).words.map(describe)
    }

    /// Each word's `typed` is the text at its start offset (the curly
    /// apostrophes straightened), and there is one offset per word.
    static func offsetsHold(_ text: String, _ language: String?) -> Bool {
        let words = LyricTokenizer.tokenize(text, language: language).words
        let starts = LyricTokenizer.wordStartOffsets(text, language: language)
        guard starts.count == words.count else { return false }
        let chars = Array(text).map { LyricTokenizer.curlyApostrophes.contains($0.unicodeScalars.first!) ? "'" : $0 }
        for (i, word) in words.enumerated() {
            let own = Array(word.typed)
            guard starts[i] + own.count <= chars.count, Array(chars[starts[i]..<(starts[i] + own.count)]) == own else {
                return false
            }
        }
        return true
    }

    static let tempo = TempoMap(constantBPM: 120)

    static func notes(_ count: Int, start: Int = 0) -> [MIDINote] {
        (0..<count).map { MIDINote(pitch: 60 + $0 % 12, velocity: 100, startBeat: Double(start + $0), lengthBeats: 1) }
    }

    static func clip(_ text: String, _ language: String?, notes count: Int) -> Clip {
        Clip(name: "Melody", startBeat: 0, lengthBeats: Double(count), notes: notes(count),
             lyrics: ClipLyrics(text: text, language: language))
    }

    static func refusal(_ clip: Clip) -> LyricRefusal? {
        do throws(LyricRefusal) {
            _ = try SingPlanner.assignment(for: clip, tempoMap: tempo)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The CJK tokenizer table (exact, §6.6)

    @Test("a line of characters: one word per character, Chinese punctuation kept in typed, dropped for singing")
    func charactersAndPunctuation() {
        let text = "一闪一闪亮晶晶，满天都是小星星。"
        #expect(Self.row(text, "zh") == [
            "一/一/zh/0/0", "闪/闪/zh/0/0", "一/一/zh/0/0", "闪/闪/zh/0/0", "亮/亮/zh/0/0", "晶/晶/zh/0/0",
            "晶，/晶/zh/0/0", "满/满/zh/0/0", "天/天/zh/0/0", "都/都/zh/0/0", "是/是/zh/0/0", "小/小/zh/0/0",
            "星/星/zh/0/0", "星。/星/zh/0/0",
        ])
        #expect(LyricTokenizer.wordStartOffsets(text, language: "zh") == [0, 1, 2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14])
        #expect(Self.offsetsHold(text, "zh"))
        let marks = Self.row("春、夏？秋！冬。", "zh")
        #expect(marks == ["春、/春/zh/0/0", "夏？/夏/zh/0/0", "秋！/秋/zh/0/0", "冬。/冬/zh/0/0"])
        #expect(Self.offsetsHold("春、夏？秋！冬。", "zh"))
    }

    @Test("an opening bracket or quote goes with the word after it; every other mark with the word before")
    func brackets() {
        #expect(Self.row("「你好」，世界！", "zh") == ["「你/你/zh/0/0", "好」，/好/zh/0/0", "世/世/zh/0/0", "界！/界/zh/0/0"])
        #expect(LyricTokenizer.wordStartOffsets("「你好」，世界！", language: "zh") == [0, 2, 5, 6])
        #expect(Self.row("《静夜思》（李白）", "zh")
                == ["《静/静/zh/0/0", "夜/夜/zh/0/0", "思》/思/zh/0/0", "（李/李/zh/0/0", "白）/白/zh/0/0"])
        #expect(Self.offsetsHold("「你好」，世界！", "zh"))
        #expect(Self.offsetsHold("《静夜思》（李白）", "zh"))
    }

    @Test("pinyin with a tone (1-5) is one Mandarin syllable, sung lowercased; a tone outside 1-5 is not")
    func pinyin() {
        let text = "wo3 ai4 ni3, Ni3 hao3"
        #expect(Self.row(text, "zh") == ["wo3/wo3/zh/0/0", "ai4/ai4/zh/0/0", "ni3,/ni3/zh/0/0", "Ni3/ni3/zh/0/0",
                                         "hao3/hao3/zh/0/0"])
        let words = LyricTokenizer.tokenize(text, language: "zh").words
        #expect(words.allSatisfy { !$0.isNumber && !$0.isEnglish && $0.isSingable && $0.parts == [$0.sung] })
        // ü (or v, the keyboard's stand-in) and the light tone 5 are pinyin; 6 and 0 are not tones in Mandarin.
        #expect(Self.row("lü4 lv4 ma5 ni6 a0", "zh") == ["lü4/lü4/zh/0/0", "lv4/lv4/zh/0/0", "ma5/ma5/zh/0/0",
                                                        "ni6/ni6/-/0/0", "a0/a0/-/0/0"])
        #expect(Self.offsetsHold(text, "zh"))
    }

    @Test("jyutping with a tone (1-6) is one Cantonese syllable; Cantonese clips cut characters the same way")
    func jyutping() {
        #expect(Self.row("ngo5 oi3 nei5 ni6", "yue") == ["ngo5/ngo5/yue/0/0", "oi3/oi3/yue/0/0", "nei5/nei5/yue/0/0",
                                                        "ni6/ni6/yue/0/0"])
        #expect(Self.row("一閃一閃", "yue") == ["一/一/yue/0/0", "閃/閃/yue/0/0", "一/一/yue/0/0", "閃/閃/yue/0/0"])
        // ü is pinyin, not jyutping: in a Cantonese clip "lü4" is a word with a letter English lacks.
        let lu = LyricTokenizer.tokenize("lü4", language: "yue").words
        #expect(lu.map(Self.describe) == ["lü4/lü4/-/0/0"])
        #expect(lu.map(\.isSingable) == [false])
    }

    @Test("other Latin words in a Chinese line are English (upstream's rule), and a Latin word after a character starts a new word")
    func englishInsideChinese() {
        #expect(Self.row("我爱你 love you", "zh")
                == ["我/我/zh/0/0", "爱/爱/zh/0/0", "你/你/zh/0/0", "love/love/-/0/0", "you/you/-/0/0"])
        #expect(Self.row("我的iPhone很好", "zh")
                == ["我/我/zh/0/0", "的/的/zh/0/0", "iPhone/iPhone/-/0/0", "很/很/zh/0/0", "好/好/zh/0/0"])
        let ordinal = LyricTokenizer.tokenize("第3名", language: "zh").words
        #expect(ordinal.map(Self.describe) == ["第/第/zh/0/0", "3/3/-/0/0", "名/名/zh/0/0"])
        #expect(ordinal.map(\.isNumber) == [false, true, false])
        // English rules are untouched inside a Chinese clip: hyphen parts, and a hyphenated pinyin pair is English.
        let hyphens = LyricTokenizer.tokenize("twin-kle ni3-hao3", language: "zh").words
        #expect(hyphens.map(Self.describe) == ["twin-kle/twinkle/-/0/0", "ni3-hao3/ni3 hao3/-/0/0"])
        #expect(hyphens.map(\.parts) == [["twin", "kle"], ["ni3", "hao3"]])
        #expect(Self.offsetsHold("我的iPhone很好", "zh"))
    }

    @Test("+ marks hold the character before, glued or standing alone, inside a run of characters too")
    func holds() {
        let text = "一闪+ 一闪++ +星 星+~ 亮+晶"
        #expect(Self.row(text, "zh") == ["一/一/zh/0/0", "闪/闪/zh/1/0", "一/一/zh/0/0", "闪/闪/zh/3/0", "星/星/zh/0/0",
                                         "星/星/zh/1/0", "亮/亮/zh/1/0", "晶/晶/zh/0/0"])
        #expect(LyricTokenizer.wordStartOffsets(text, language: "zh") == [0, 1, 4, 5, 10, 12, 16, 18])
        #expect(Self.offsetsHold(text, "zh"))
        #expect(LyricTokenizer.tokenize(text, language: "zh").words.map(\.markedNotes) == [1, 2, 1, 4, 1, 2, 2, 1])
    }

    @Test("dashes and ellipses separate words and vanish from typed, in a Chinese clip as in an English one")
    func separators() {
        let text = "一闪……一闪——亮"
        #expect(Self.row(text, "zh") == ["一/一/zh/0/0", "闪/闪/zh/0/0", "一/一/zh/0/0", "闪/闪/zh/0/0", "亮/亮/zh/0/0"])
        #expect(LyricTokenizer.wordStartOffsets(text, language: "zh") == [0, 1, 4, 5, 8])
    }

    @Test("lines: characters, English and pinyin on their own lines")
    func mixedLines() {
        let text = LyricTokenizer.tokenize("一闪一闪\nTwinkle twin-kle\n\nni3 hao3", language: "zh")
        #expect(text.words.map(Self.describe) == [
            "一/一/zh/0/0", "闪/闪/zh/0/0", "一/一/zh/0/0", "闪/闪/zh/0/0",
            "Twinkle/Twinkle/-/0/1", "twin-kle/twinkle/-/0/1", "ni3/ni3/zh/0/3", "hao3/hao3/zh/0/3",
        ])
        #expect(text.lines.count == 3)
        #expect(text.language == "zh")
        #expect(Self.offsetsHold("一闪一闪\nTwinkle twin-kle\n\nni3 hao3", "zh"))
    }

    @Test("the extension blocks are characters too; other scripts are words the clip cannot sing")
    func blocksAndOtherScripts() {
        // U+3400 (extension A) and U+20000 (extension B): one word each. U+F900 (a compatibility ideograph) is not
        // in the ranges, so it is a letter English lacks; kana and Hangul too.
        let words = LyricTokenizer.tokenize("\u{3400}\u{20000} \u{F900} 我の歌 한", language: "zh").words
        #expect(words.map(Self.describe) == ["\u{3400}/\u{3400}/zh/0/0", "\u{20000}/\u{20000}/zh/0/0",
                                             "\u{F900}/\u{F900}/-/0/0", "我/我/zh/0/0", "の/の/-/0/0", "歌/歌/zh/0/0",
                                             "한/한/-/0/0"])
        #expect(words.map(\.isSingable) == [true, true, false, true, false, true, false])
        let han: [Character] = ["一", "龥", "\u{3400}", "\u{20000}", "\u{323AF}"]
        let notHan: [Character] = ["a", "の", "，", "\u{F900}", "\u{4DC0}", "\u{A000}"]
        #expect(han.allSatisfy { LyricLanguage.isHan($0) })
        #expect(!notHan.contains { LyricLanguage.isHan($0) })
        #expect(LyricLanguage.containsHan("hello 我") && !LyricLanguage.containsHan("hello"))
    }

    @Test("English clips (nil, \"en\") and unsupported codes cut text exactly as before languages existed")
    func englishIsUnchanged() {
        let chinese = "一闪一闪亮晶晶，"
        let english = LyricTokenizer.tokenize(chinese)
        #expect(english.words.map(Self.describe) == ["一闪一闪亮晶晶，/一闪一闪亮晶晶/-/0/0"])
        #expect(english.words.map(\.isEnglish) == [false])
        let pinyin = LyricTokenizer.tokenize("wo3 ai4 ni3")
        #expect(pinyin.words.map(Self.describe) == ["wo3/wo3/-/0/0", "ai4/ai4/-/0/0", "ni3/ni3/-/0/0"])
        #expect(pinyin.words.allSatisfy { $0.isNumber && $0.isEnglish })
        for text in [chinese, "wo3 ai4 ni3", "Twin-kle, star! 3-2-1 go +", "hello café"] {
            let base = LyricTokenizer.tokenize(text)
            #expect(LyricTokenizer.tokenize(text, language: nil) == base)
            #expect(LyricTokenizer.tokenize(text, language: "en") == base)
            var spanish = base
            spanish.language = "es"
            #expect(LyricTokenizer.tokenize(text, language: "es") == spanish, "same words, the code kept")
            #expect(LyricTokenizer.wordStartOffsets(text, language: "es") == LyricTokenizer.wordStartOffsets(text))
        }
    }

    @Test("cut and slice follow the clip's language")
    func cutFollowsTheLanguage() {
        let text = "一闪一闪亮晶晶"
        let zh = LyricTokenizer.cut(text, beforeWord: 3, language: "zh")
        #expect(zh.left == "一闪一" && zh.right == "闪亮晶晶")
        #expect(LyricTokenizer.slice(text, words: 2..<5, language: "zh") == "一闪亮")
        let english = LyricTokenizer.cut(text, beforeWord: 3)
        #expect(english.left == text && english.right == "", "control: in English the line is one word")
    }

    // MARK: - Pinyin / jyutping recogniser

    @Test("toneSyllable: lowercase letters (ü in Mandarin) then a tone digit of the language")
    func toneSyllables() {
        #expect(LyricLanguage.toneSyllable("Hao3", language: "zh") == "hao3")
        #expect(LyricLanguage.toneSyllable("NÜ3", language: "zh") == "nü3")
        #expect(LyricLanguage.toneSyllable("hao6", language: "zh") == nil)
        #expect(LyricLanguage.toneSyllable("hou6", language: "yue") == "hou6")
        #expect(LyricLanguage.toneSyllable("nü3", language: "yue") == nil)
        #expect(LyricLanguage.toneSyllable("3", language: "zh") == nil)
        #expect(LyricLanguage.toneSyllable("hao", language: "zh") == nil)
        #expect(LyricLanguage.toneSyllable("hao3", language: nil) == nil)
        #expect(LyricLanguage.toneSyllable("hao3", language: "es") == nil)
    }

    // MARK: - Syllables (SyllableCounting)

    @Test("a Chinese word counts 1 syllable whatever counter is passed; the passed counter still moves English words")
    func syllablesByLanguage() throws {
        let notes = Self.notes(4)
        let text = LyricTokenizer.tokenize("一 love", language: "zh")
        let byDefault = try LyricNoteAssigner.assign(text, notes: notes, clipStartBeat: 0, tempoMap: Self.tempo)
        let swapped = try LyricNoteAssigner.assign(text, notes: notes, clipStartBeat: 0, tempoMap: Self.tempo,
                                                   syllables: { _ in 7 })
        #expect(byDefault.words.map(\.syllables) == [1, 1])
        #expect(byDefault.words.map(\.heldNotes) == [0, 2], "spare notes held by the last word")
        #expect(swapped.words.map(\.syllables) == [1, 7], "the counter moved the English word, not the character")
        #expect(swapped.words.map { $0.noteIDs.count } == [1, 3])
        #expect(swapped.words.map(\.heldNotes) == [0, 0])
        #expect(ChineseSyllables.estimate("一") == 1 && ChineseSyllables.estimate("zhuang1") == 1)
        #expect(LyricLanguage.syllableCounter(for: nil).estimate("beautiful") == EnglishSyllables.estimate("beautiful"))
        #expect(LyricLanguage.syllableCounter(for: "yue").estimate("beautiful") == 1)
        #expect(LyricLanguage.syllableCounter(for: "es").estimate("beautiful") == EnglishSyllables.estimate("beautiful"))
    }

    // MARK: - Refusals and copy (§6.7)

    @Test("§6.7's sentences, verbatim")
    func copy() {
        #expect(LyricLanguage.Copy.scriptMismatch == "These look like Chinese characters. Set Language to Chinese "
                + "(Mandarin) or Chinese (Cantonese), and I'll sing them.")
        #expect(LyricLanguage.Copy.languageUnsupported == "I can't sing in that language yet. Set Language to English, "
                + "Chinese (Mandarin) or Chinese (Cantonese).")
        #expect(LyricLanguage.Copy.noSungForm("龘") == "I don't know how to sing '龘'. Try a different character, or "
                + "type its pinyin with a tone number, like ni3.")
        #expect(LyricLanguage.Copy.needsNewerEngine
                == "This language needs a newer singing engine. Update it from the Sing sheet.")
        // Base §5.7 "Not English", unchanged byte for byte (§6.7 row 2).
        #expect(LyricRefusal.notEnglish(word: "café").sentence
                == "I can only sing English words so far — 'café' isn't one I can pronounce.")
    }

    @Test("refusals: Chinese in an English clip is scriptMismatch, other letters 'Not English', an unsupported code languageUnsupported")
    func languageRefusals() {
        // Chinese characters in an English clip (design §6.7 row 1): the first unsingable word decides.
        #expect(Self.refusal(Self.clip("我爱你", nil, notes: 3)) == .scriptMismatch(word: "我爱你"))
        #expect(Self.refusal(Self.clip("hello 我", nil, notes: 3)) == .scriptMismatch(word: "我"))
        #expect(Self.refusal(Self.clip("café 我", nil, notes: 3)) == .notEnglish(word: "café"), "the first decides")
        #expect(LyricRefusal.scriptMismatch(word: "我").sentence == LyricLanguage.Copy.scriptMismatch)
        #expect(LyricRefusal.languageUnsupported(language: "es").sentence == LyricLanguage.Copy.languageUnsupported)
        // Letters a Chinese clip cannot sing either.
        #expect(Self.refusal(Self.clip("我 café", "zh", notes: 3)) == .notEnglish(word: "café"))
        #expect(Self.refusal(Self.clip("我の歌", "zh", notes: 3)) == .notEnglish(word: "の"))
        #expect(Self.refusal(Self.clip("lü4", "yue", notes: 3)) == .notEnglish(word: "lü4"))
        // A code that cannot be sung is refused, never sung as English, even when every word is English.
        #expect(Self.refusal(Self.clip("hola amigo", "es", notes: 3)) == .languageUnsupported(language: "es"))
        #expect(Self.refusal(Self.clip("hello world", "fr", notes: 3)) == .languageUnsupported(language: "fr"))
        #expect(Self.refusal(Self.clip("hello world", "", notes: 3)) == .languageUnsupported(language: ""))
        // Controls: the same words sing in a clip that can sing them.
        #expect(Self.refusal(Self.clip("我爱你", "zh", notes: 3)) == nil)
        #expect(Self.refusal(Self.clip("hello world", nil, notes: 3)) == nil)
        #expect(Self.refusal(Self.clip("hello world", "en", notes: 3)) == nil)
        #expect(Self.refusal(Self.clip("我 love", "yue", notes: 3)) == nil)
        // The one classification, exposed for typing on a note.
        #expect(LyricRefusal.forUnsingable(LyricWord(typed: "我", sung: "我", parts: ["我"], isEnglish: false))
                == .scriptMismatch(word: "我"))
        let first = LyricWord(typed: "hola", sung: "hola", parts: ["hola"])
        #expect(LyricRefusal.forUnsupportedLanguage("es", firstWord: first) == .languageUnsupported(language: "es"))
    }

    @Test("an empty text is 'no words' whatever its language: the language check comes after it")
    func refusalOrder() {
        for language in [nil, "zh", "es", "fr"] as [String?] {
            #expect(throws: LyricRefusal.noWords) {
                _ = try LyricNoteAssigner.assign(LyricText(words: [], language: language), notes: Self.notes(2),
                                                 clipStartBeat: 0, tempoMap: Self.tempo)
            }
        }
        #expect(LyricText(words: [], language: "en").language == nil, "\"en\" is English, stored as nil")
    }

    @Test("isSupported: English (nil or \"en\"), Mandarin and Cantonese; nothing else, Spanish included")
    func supportedCodes() {
        #expect([nil, "en", "zh", "yue"].allSatisfy { LyricLanguage.isSupported($0) })
        #expect(!["es", "fr", "", "ZH", "zh-CN", "cmn"].contains { LyricLanguage.isSupported($0) })
        #expect(LyricLanguage.stored("en") == nil && LyricLanguage.stored("zh") == "zh" && LyricLanguage.stored("es") == "es")
    }

    // MARK: - ClipLyrics.language: storage

    static func sortedJSON<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    static func decodeLyrics(_ json: String) throws -> ClipLyrics {
        try JSONDecoder().decode(ClipLyrics.self, from: Data(json.utf8))
    }

    @Test("a language is written only when the clip has one; \"en\" is English and writes nothing")
    func languageEncoding() throws {
        let english = try Self.sortedJSON(ClipLyrics(text: "la la", language: "en"))
        #expect(english == #"{"text":"la la"}"#)
        #expect(ClipLyrics(text: "la la", language: "en") == ClipLyrics(text: "la la"))
        let chinese = try Self.sortedJSON(ClipLyrics(text: "我爱你", language: "zh"))
        #expect(chinese == #"{"language":"zh","text":"我爱你"}"#)
        #expect(try Self.decodeLyrics(chinese) == ClipLyrics(text: "我爱你", language: "zh"))
        #expect(try Self.decodeLyrics(#"{"language":"yue","text":"一"}"#).language == "yue")
    }

    @Test("decoding: absent, null and \"en\" are English; an unknown code is kept (and refused when sung); a damaged one too")
    func languageDecoding() throws {
        #expect(try Self.decodeLyrics(#"{"text":"x"}"#).language == nil)
        #expect(try Self.decodeLyrics(#"{"language":null,"text":"x"}"#).language == nil)
        #expect(try Self.decodeLyrics(#"{"language":"en","text":"x"}"#).language == nil)
        let french = try Self.decodeLyrics(#"{"language":"fr","text":"x"}"#)
        #expect(french.language == "fr")
        #expect(try Self.sortedJSON(french) == #"{"language":"fr","text":"x"}"#, "kept, never rewritten")
        let damaged = try Self.decodeLyrics(#"{"language":5,"text":"x"}"#)
        #expect(damaged.text == "x" && damaged.language == "", "the clip still loads; its language cannot be sung")
        #expect(!LyricLanguage.isSupported(damaged.language))
    }

    @Test("withText keeps the language; blank text is still no lyrics")
    func withTextAndBlank() {
        let lyrics = ClipLyrics(text: "我爱你", language: "zh")
        #expect(lyrics.withText("你好") == ClipLyrics(text: "你好", language: "zh"))
        #expect(ClipLyrics(text: "x").withText("y").language == nil)
        #expect(ClipLyrics.normalized(ClipLyrics(text: " \n", language: "zh")) == nil)
    }

    @Test("a clip and its ClipDocument carry the language through a save and back")
    func clipAndDocumentCarry() throws {
        let clip = Self.clip("我爱你", "zh", notes: 3)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(clip))
        #expect(back.lyrics?.language == "zh")
        let document = ClipDocument(from: clip, media: nil)
        let reread = try JSONDecoder().decode(ClipDocument.self, from: JSONEncoder().encode(document))
        #expect(reread.lyrics == ClipLyrics(text: "我爱你", language: "zh"))
    }

    // MARK: - Cutting a clip keeps its language

    @Test("a split Chinese clip: words go with the notes they start on, one per character, and both halves stay Chinese")
    func splitKeepsTheLanguage() throws {
        let clip = Self.clip("一闪一闪亮晶晶", "zh", notes: 7)
        let placement = try #require(ClipLyrics.WordPlacement(clip: clip, tempoMap: Self.tempo))
        #expect(placement.onsets == [0, 1, 2, 3, 4, 5, 6])
        #expect(placement.language == "zh")
        let (left, right) = placement.split(atClipBeat: 3)
        #expect(left == ClipLyrics(text: "一闪一", language: "zh"))
        #expect(right == ClipLyrics(text: "闪亮晶晶", language: "zh"))
        #expect(placement.window(2..<5, isFirstWindow: false) == ClipLyrics(text: "一闪亮", language: "zh"))
    }

    @Test("bars deleted through a Chinese clip remove the characters whose notes went, and keep the language")
    func deleteKeepsTheLanguage() {
        let source = Self.clip("一闪一闪亮晶晶", "zh", notes: 7)
        let all = source.notes ?? []
        var head = source
        head.notes = Array(all[0..<3])
        var tail = source
        tail.notes = Array(all[5..<7])
        let out = ClipLyrics.distributeAfterDelete([head, tail], cutFrom: source, atClipBeat: 3, tempoMap: Self.tempo)
        #expect(out.map(\.lyrics) == [ClipLyrics(text: "一闪一", language: "zh"), ClipLyrics(text: "晶晶", language: "zh")])
    }

    // MARK: - The planner

    @Test("a Chinese clip plans one character per note, each SingWord carrying its language; English words carry none")
    func planCarriesTheLanguage() throws {
        let clip = Self.clip("我爱你 love", "zh", notes: 4)
        let plan = try SingPlanner.plan(clip: clip, on: Track(name: "Lead", kind: .instrument), tempoMap: Self.tempo,
                                        meterMap: MeterMap(constant: TimeSignature()), octaveShift: 0)
        let words = try #require(plan.units.first).words
        #expect(words.map(\.text) == ["我", "爱", "你", "love"])
        #expect(words.map(\.language) == ["zh", "zh", "zh", nil])
        #expect(words.map(\.noteIndices) == [[0], [1], [2], [3]])
    }

    @Test("the signature gains a language only when a word has one")
    func signatureAndLanguage() throws {
        func signature(_ text: String, _ language: String?) throws -> String {
            try SingPlanner.plan(clip: Self.clip(text, language, notes: 3), on: Track(name: "Lead", kind: .instrument),
                                 tempoMap: Self.tempo, meterMap: MeterMap(constant: TimeSignature()),
                                 octaveShift: 0).signature
        }
        // The same English words: no word has a language in either clip, so the request is the same.
        #expect(try signature("la la la", "zh") == signature("la la la", nil))
        // The same sung text "wo3 ai4 ni3": English number words, or Mandarin syllables. Only the language differs.
        #expect(try signature("wo3 ai4 ni3", "zh") != signature("wo3 ai4 ni3", nil))
        #expect(try signature("wo3 ai4 ni3", "zh") != signature("wo3 ai4 ni3", "yue"))
    }
}
