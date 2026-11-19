import Foundation

/// The languages a clip's lyrics can be sung in (p2-sing-x3, design
/// `docs/design/2026-10-06-p2-sing-expansion.md` §6.3).
///
/// A language is a code on `ClipLyrics.language`. **English is the absence of
/// a code** (nil), so every clip written before languages existed, and every
/// English clip after, stores no code at all and encodes byte for byte as it
/// did (design §9 S1). `"en"` is accepted where a code is given and stored as
/// nil, so English has one spelling.
///
/// | Code | Language | Ships |
/// |---|---|---|
/// | nil (`"en"`) | English | today |
/// | `"zh"` | Chinese (Mandarin), simplified or traditional characters | x3 (this item) |
/// | `"yue"` | Chinese (Cantonese) | x3 (this item) |
/// | anything else (`"es"`, `"fr"`, …) | decodes, and is REFUSED at sing time | never silently sung as English |
///
/// Spanish (`"es"`, design §6.5, "experimental, last") is OUT of item x3: it is
/// refused like any other unsupported code until its own item adds it.
public enum LyricLanguage {

    /// English, as a code. Stored as nil (`stored(_:)`).
    public static let english = "en"
    /// Chinese (Mandarin).
    public static let mandarin = "zh"
    /// Chinese (Cantonese).
    public static let cantonese = "yue"

    /// The codes, besides English (nil), that lyrics can be sung in.
    public static let chinese: [String] = [mandarin, cantonese]

    /// `code` as `ClipLyrics` stores it: `"en"` is English, which is stored as
    /// nil; every other code is kept exactly as given, supported or not (an
    /// unsupported one is refused at sing time, never dropped or rewritten).
    public static func stored(_ code: String?) -> String? {
        code == english ? nil : code
    }

    /// True when lyrics in `code` can be sung: English (nil or `"en"`),
    /// `"zh"` or `"yue"`.
    public static func isSupported(_ code: String?) -> Bool {
        guard let code = stored(code) else { return true }
        return chinese.contains(code)
    }

    /// True for `"zh"` and `"yue"`: the clips whose Chinese characters are cut
    /// one per word by `LyricTokenizer`.
    public static func isChinese(_ code: String?) -> Bool {
        guard let code else { return false }
        return chinese.contains(code)
    }

    // MARK: - Chinese characters

    /// The Han characters a Chinese clip sings one per note: the CJK Unified
    /// Ideographs block U+4E00–9FFF (upstream's own Chinese test,
    /// `upstream/preprocess/tools/g2p.py:8`, `[一-鿿]`) plus its
    /// extension blocks: A (U+3400–4DBF), B (U+20000–2A6DF), C to F and I
    /// (U+2A700–2EE5F, contiguous) and G to H (U+30000–323AF). The
    /// compatibility ideographs (U+F900–FAFF, U+2F800–2FA1F) are not in it.
    /// Whether the singing engine knows a character is the facade's question
    /// (design §6.4): an extension-block character it cannot read is refused
    /// there, naming it.
    public static func isHan(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0x20000...0x2A6DF, 0x2A700...0x2EE5F, 0x30000...0x323AF:
            return true
        default:
            return false
        }
    }

    /// True when `character` is a Han character: its first scalar is one (a
    /// variation selector after it does not change that).
    public static func isHan(_ character: Character) -> Bool {
        character.unicodeScalars.first.map { isHan($0) } ?? false
    }

    /// True when `text` holds at least one Han character.
    public static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { isHan($0) }
    }

    // MARK: - Pinyin and jyutping

    /// The syllable `word` spells in romanised Chinese with its tone digit,
    /// lowercased, or nil when it is not one (design §6.3):
    ///
    /// - Mandarin (`"zh"`): pinyin, letters a–z or ü, then a tone 1–5
    ///   (5 is the light tone): `^[a-zü]+[1-5]$`. "wo3", "lü4", "lv4".
    /// - Cantonese (`"yue"`): jyutping, letters a–z, then a tone 1–6:
    ///   `^[a-z]+[1-6]$`. "ngo5", "nei5".
    ///
    /// Capitals are accepted ("Wo3" at the start of a line) and the syllable is
    /// returned lowercased, which is how the engine's syllable table spells
    /// them. Whether the table has that exact syllable is the facade's
    /// question (design §6.4: a missing tone falls back, a missing syllable is
    /// refused naming it). Any other code returns nil.
    public static func toneSyllable(_ word: String, language: String?) -> String? {
        let maxTone: Int
        if language == mandarin {
            maxTone = 5
        } else if language == cantonese {
            maxTone = 6
        } else {
            return nil
        }
        let lower = word.lowercased()
        guard let last = lower.last, last.isASCII, let tone = last.wholeNumberValue,
              (1...maxTone).contains(tone) else { return nil }
        let letters = lower.dropLast()
        guard !letters.isEmpty,
              letters.allSatisfy({ ($0.isASCII && $0.isLetter) || (language == mandarin && $0 == "ü") }) else {
            return nil
        }
        return lower
    }

    // MARK: - Copy (design §6.7)

    /// The sentences for lyrics in a language that cannot be sung as they
    /// are (design §6.7). Pinned verbatim by `LyricLanguageTests`.
    ///
    /// `LyricRefusal.scriptMismatch` and `.languageUnsupported` say the
    /// first two (wire codes `lyricsScriptMismatch` /
    /// `lyricsLanguageUnsupported`).
    public enum Copy {
        /// §6.7 row 1: Chinese characters typed into an English clip
        /// (`lyricsScriptMismatch`).
        public static let scriptMismatch =
            "These look like Chinese characters. Set Language to Chinese (Mandarin) or Chinese (Cantonese), "
            + "and I'll sing them."
        /// PROVISIONAL (not in design §6.7, which has no row for a code it
        /// does not know): a clip whose language cannot be sung
        /// (`lyricsLanguageUnsupported`). §6.7's "This language needs a newer
        /// singing engine" is for an engine that is too old, which is not
        /// true of a code like "fr", so it is not reused here.
        public static let languageUnsupported =
            "I can't sing in that language yet. Set Language to English, Chinese (Mandarin) or Chinese (Cantonese)."
        /// §6.7 row 3: a Chinese clip, a character the engine has no sung
        /// form for. The FACADE says this (its `unknownPhone`, design §6.4);
        /// kept here so the app and the facade say the same words.
        public static func noSungForm(_ character: String) -> String {
            "I don't know how to sing '\(character)'. Try a different character, or type its pinyin with a tone "
                + "number, like ni3."
        }
        /// §6.7 row 5: the installed engine is too old for the language.
        public static let needsNewerEngine = "This language needs a newer singing engine. Update it from the Sing sheet."
    }
}

// MARK: - Counting syllables, by language

/// How many syllables a lyric word has, for sharing spare notes (design §3.3
/// rule 5.1). Picked by the word's language (design §6.3):
/// `EnglishSyllables` for English (unchanged), `ChineseSyllables` for a
/// Chinese character or a pinyin/jyutping syllable.
public protocol SyllableCounting {
    /// The estimate for one sung word, at least 1.
    static func estimate(_ word: String) -> Int
}

extension EnglishSyllables: SyllableCounting {}

/// A Chinese lyric word is ONE syllable: a Han character, or a pinyin or
/// jyutping syllable with its tone (`LyricTokenizer` makes nothing else in a
/// Chinese clip carry a Chinese language), so it asks for one note.
public enum ChineseSyllables: SyllableCounting {
    public static func estimate(_ word: String) -> Int { 1 }
}

extension LyricLanguage {

    /// The counter for a word in `language` (`LyricWord.language`, nil =
    /// English).
    public static func syllableCounter(for language: String?) -> any SyllableCounting.Type {
        isChinese(language) ? ChineseSyllables.self : EnglishSyllables.self
    }
}
