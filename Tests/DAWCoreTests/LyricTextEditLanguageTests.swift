import Foundation
import Testing
@testable import DAWCore

/// p2-sing-x3b: typing a word on one note of a CHINESE clip (`LyricTextEdit` read in the clip's language). Pure
/// values, so NOT `@MainActor`. Layouts are `word@[note indexes]`, as in `LyricTextEditTests`. The store half
/// (`setClipLyrics` keeps the language; the `language:` overload) is in `LyricTextEditStoreTests.swift`.
@Suite("Typing a word onto one note of a Chinese clip: read and stored in the clip's language (p2-sing-x3b)")
struct LyricTextEditLanguageTests {

    static let tempo = TempoMap(constantBPM: 120)

    /// One breath phrase of `count` one-beat notes, touching.
    static func melody(_ count: Int, _ text: String, _ language: String?) -> Clip {
        let notes = (0..<count).map { MIDINote(pitch: 60 + $0, startBeat: Double($0), lengthBeats: 1) }
        return Clip(name: "Melody", lengthBeats: Double(count), notes: notes,
                    lyrics: ClipLyrics(text: text, language: language))
    }

    static func layout(_ a: LyricAssignment, _ clip: Clip) -> [String] {
        let index = Dictionary(uniqueKeysWithValues: clip.notes!.enumerated().map { ($1.id, $0) })
        return a.words.map { "\($0.word.typed)@\($0.noteIDs.map { index[$0]! })" }
    }

    /// Applies `word` on note `index`. The returned assignment must BE the one derivation of the returned text
    /// stored with the clip's language.
    static func type(_ word: String, on index: Int, _ clip: Clip) throws -> (text: String, layout: [String],
                                                                            languages: [String?]) {
        let (text, assignment) = try LyricTextEdit.apply(.typed(word, onNote: clip.notes![index].id), to: clip,
                                                         tempoMap: tempo)
        var edited = clip
        edited.lyrics = clip.lyrics?.withText(text)
        #expect(try SingPlanner.assignment(for: edited, tempoMap: tempo) == assignment)
        return (text, layout(assignment, clip), assignment.words.map { $0.word.language })
    }

    static func refusal(_ word: String, on index: Int, _ clip: Clip) -> LyricEditRefusal? {
        do throws(LyricEditRefusal) {
            _ = try LyricTextEdit.apply(.typed(word, onNote: clip.notes![index].id), to: clip, tempoMap: tempo)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - The table

    @Test("a character typed on a character's note replaces it; the others stay")
    func replaceACharacter() throws {
        let clip = Self.melody(4, "一闪一闪", "zh")
        let out = try Self.type("亮", on: 1, clip)
        #expect(out.text == "一亮一闪")
        #expect(out.layout == ["一@[0]", "亮@[1]", "一@[2]", "闪@[3]"])
        #expect(out.languages == ["zh", "zh", "zh", "zh"])
    }

    @Test("+ on a character's note: the character before holds onto it")
    func holdTheCharacterBefore() throws {
        let clip = Self.melody(4, "一闪一闪", "zh")
        let out = try Self.type("+", on: 1, clip)
        #expect(out.text == "一 +一闪")
        #expect(out.layout == ["一@[0, 1]", "一@[2]", "闪@[3]"])
        // Clearing the note is the same edit.
        #expect(try Self.type("", on: 1, clip).text == "一 +一闪")
    }

    @Test("a character typed on a held note splits the hold: the held character keeps the notes before it")
    func splitAHold() throws {
        let clip = Self.melody(4, "我爱你", "zh")
        let before = try SingPlanner.assignment(for: clip, tempoMap: Self.tempo)
        #expect(Self.layout(before, clip) == ["我@[0]", "爱@[1]", "你@[2, 3]"], "control: 你 holds the spare note")
        let out = try Self.type("啊", on: 3, clip)
        #expect(out.text == "我爱你 啊")
        #expect(out.layout == ["我@[0]", "爱@[1]", "你@[2]", "啊@[3]"])
    }

    @Test("pinyin, jyutping and English typed into a Chinese line are each one word on that note")
    func latinWordsInAChineseLine() throws {
        let clip = Self.melody(3, "我爱你", "zh")
        let pinyin = try Self.type("ni3", on: 2, clip)
        #expect(pinyin.text == "我爱ni3")
        #expect(pinyin.layout == ["我@[0]", "爱@[1]", "ni3@[2]"])
        #expect(pinyin.languages == ["zh", "zh", "zh"])
        let english = try Self.type("love", on: 1, clip)
        #expect(english.text == "我love你")
        #expect(english.languages == ["zh", nil, "zh"])
        let cantonese = try Self.type("ngo5", on: 0, Self.melody(4, "一閃一閃", "yue"))
        #expect(cantonese.text == "ngo5閃一閃")
        #expect(cantonese.layout == ["ngo5@[0]", "閃@[1]", "一@[2]", "閃@[3]"])
        #expect(cantonese.languages == ["yue", "yue", "yue", "yue"])
    }

    @Test("refusals in a Chinese clip, each with its own sentence; Chinese typed into an English clip is scriptMismatch")
    func refusals() {
        let clip = Self.melody(4, "一闪一闪", "zh")
        #expect(Self.refusal("我爱", on: 1, clip) == .wordHasSpace(word: "我爱"), "two characters are two words")
        #expect(Self.refusal("我+", on: 1, clip) == .wordHasMarks(word: "我+"))
        #expect(Self.refusal("，", on: 1, clip) == .wordHasNoLetters(word: "，"))
        #expect(Self.refusal("café", on: 1, clip) == .lyrics(.notEnglish(word: "café")))
        #expect(Self.refusal("の", on: 1, clip) == .lyrics(.notEnglish(word: "の")))
        let english = Self.melody(4, "one two three four", nil)
        let mismatch = Self.refusal("我", on: 1, english)
        #expect(mismatch == .lyrics(.scriptMismatch(word: "我")))
        #expect(mismatch?.sentence == LyricLanguage.Copy.scriptMismatch)
        #expect(Self.refusal("five", on: 1, english) == nil, "control: an English word types on the English clip")
        let spanish = Self.melody(4, "uno dos tres cuatro", "es")
        #expect(Self.refusal("cinco", on: 1, spanish) == .lyrics(.languageUnsupported(language: "es")))
    }

    @Test("the same character typed again changes nothing; an English clip's edit is unchanged by languages")
    func controls() throws {
        let clip = Self.melody(4, "一闪一闪", "zh")
        let same = try LyricTextEdit.apply(.typed("闪", onNote: clip.notes![1].id), to: clip, tempoMap: Self.tempo)
        #expect(same.text == "一闪一闪")
        // The English path is byte-identical to the "en" spelling of the same clip.
        let english = Self.melody(3, "one two three", nil)
        let en = Self.melody(3, "one two three", "en")
        let a = try LyricTextEdit.apply(.typed("four", onNote: english.notes![1].id), to: english, tempoMap: Self.tempo)
        let b = try LyricTextEdit.apply(.typed("four", onNote: en.notes![1].id), to: en, tempoMap: Self.tempo)
        #expect(a.text == "one four three" && b.text == a.text)
    }
}
