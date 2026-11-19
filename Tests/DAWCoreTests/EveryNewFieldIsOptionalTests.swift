import Foundation
import Testing
@testable import DAWCore

/// S7 of design `docs/design/2026-10-06-p2-sing-expansion.md` §9.2: every NEW field the singing expansion adds is
/// optional, so a file (or a value) written before it existed still reads. For each new `Codable` field, a FULL
/// JSON with that one key removed must still decode, to the field's "absent" value. NOT `@MainActor`: values only.
///
/// This file holds item x3's fields (`ClipLyrics.language`, `SingWord.language`). Item x5's fields
/// (`Clip.singStyle`, the provenance fields) are pinned by W8-X5M in its own file.
///
/// ⚠️ `SingWord` is NOT `Codable` (`Sources/DAWCore/SingPlanner.swift`, `public struct SingWord: Equatable,
/// Sendable`): the design's S7 row assumed it was. Nothing decodes one; the wire form the facade reads is
/// AIServices' `SingingPhraseWord`. Its one door is its init, so S7 pins there that the field is optional: the
/// init without it compiles and leaves it nil.
@Suite("Every new field is optional: a JSON without it still decodes (design 2026-10-06 §9.2 S7)")
struct EveryNewFieldIsOptionalTests {

    /// `json` (an object) with the key at `path` removed, re-serialised with sorted keys.
    static func removing(_ path: [String], from json: String) throws -> String {
        func strip(_ value: Any, _ path: ArraySlice<String>) -> Any {
            guard let key = path.first, var object = value as? [String: Any] else { return value }
            if path.count == 1 {
                object.removeValue(forKey: key)
            } else if let inner = object[key] {
                object[key] = strip(inner, path.dropFirst())
            }
            return object
        }
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let data = try JSONSerialization.data(withJSONObject: strip(object, path[...]), options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    @Test("ClipLyrics.language: the lyrics without the key decode, as English")
    func clipLyricsLanguage() throws {
        let full = try Self.encode(ClipLyrics(text: "我爱你", language: "zh"))
        #expect(full.contains(#""language":"zh""#), "control: the full JSON carries the key")
        let without = try Self.removing(["language"], from: full)
        #expect(without != full && !without.contains("language"))
        let decoded = try JSONDecoder().decode(ClipLyrics.self, from: Data(without.utf8))
        #expect(decoded == ClipLyrics(text: "我爱你"))
        #expect(decoded.language == nil)
    }

    @Test("ClipLyrics.language inside a clip: the clip without the key decodes, keeping its words")
    func clipLyricsLanguageInAClip() throws {
        let clip = Clip(name: "Melody", startBeat: 0, lengthBeats: 3,
                        notes: [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)],
                        lyrics: ClipLyrics(text: "我爱你", language: "zh"))
        let full = try Self.encode(clip)
        #expect(full.contains(#""language":"zh""#), "control")
        let without = try Self.removing(["lyrics", "language"], from: full)
        #expect(!without.contains("language") && without.contains("我爱你"))
        let decoded = try JSONDecoder().decode(Clip.self, from: Data(without.utf8))
        #expect(decoded.lyrics == ClipLyrics(text: "我爱你"))
        #expect(decoded.notes?.count == 1, "control: the rest of the clip came back")
    }

    @Test("SingWord.language: optional at its only door, the init (SingWord is not Codable)")
    func singWordLanguage() {
        let english = SingWord(text: "star", typed: "star!", noteIndices: [0])
        #expect(english.language == nil)
        let chinese = SingWord(text: "星", typed: "星。", noteIndices: [0], language: "zh")
        #expect(chinese.language == "zh", "control: the field is there")
        #expect(english != SingWord(text: "star", typed: "star!", noteIndices: [0], language: "zh"),
                "control: equality sees it")
    }
}
