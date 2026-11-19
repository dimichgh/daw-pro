import Foundation
import Testing
@testable import DAWCore

/// S7 (design `docs/design/2026-10-06-p2-sing-expansion.md` §9.2) for p2-sing-x5's fields: `Clip.singStyle` and
/// every field nested in it, its `ClipDocument` mirror, and `SungVocalProvenance.style`. A FULL JSON with exactly
/// one of those keys removed must still decode, and the field must read as its default — so a file written by an
/// older build, or trimmed by hand, still opens. (W8-X3 owns `EveryNewFieldIsOptionalTests.swift` for its own
/// fields; this file is x5's.) Pure values, so NOT `@MainActor`.
///
/// Plant that must turn it red: make one field non-optional (e.g. decode `air` with `decode` instead of
/// `decodeIfPresent`).
@Suite("S7 (p2-sing-x5): every new singing-style field may be missing from a file")
struct SingStyleFieldsOptionalTests {

    static let noteKey = "00000000-0000-0000-0000-000000000101"
    static var noteID: UUID { UUID(uuidString: noteKey)! }

    /// Every field set: a clip-wide choice in each, and one note's choice in each.
    static var fullStyle: SingStyle {
        SingStyle(vibrato: .wide, air: 0.5, followVelocity: true,
                  notes: [noteID: NoteSingStyle(vibrato: .straight, air: 0.25)])
    }

    static var melody: Clip {
        Clip(id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!, name: "Melody", lengthBeats: 4,
             notes: [MIDINote(id: noteID, pitch: 60, startBeat: 0, lengthBeats: 1)], singStyle: fullStyle)
    }

    static var record: SungVocalProvenance {
        SungVocalProvenance(
            engineId: "soulx-singer", engineCommit: "abc1234", weightsRevision: "rev-1", facadeVersion: 1,
            voiceId: "builtin-1", voiceName: "Built-in singer", voiceKind: SungVocalProvenance.VoiceKind.builtIn,
            lyricsText: "la", sourceClipId: melody.id, octaveShift: 0, seed: 7, nSteps: 32, cfg: 1.5,
            renderedAt: Date(timeIntervalSince1970: 1_790_000_000), style: fullStyle)
    }

    /// Each key path under the style's own key, one at a time.
    static let paths: [[String]] = [
        [], ["vibrato"], ["air"], ["followVelocity"], ["notes"], ["notes", noteKey, "vibrato"], ["notes", noteKey, "air"],
    ]

    /// What the style reads as once the key at `path` (under the style's key) is removed.
    static func expected(afterRemoving path: [String]) -> SingStyle? {
        var style: SingStyle? = fullStyle
        switch path {
        case []: style = nil
        case ["vibrato"]: style?.vibrato = nil
        case ["air"]: style?.air = nil
        case ["followVelocity"]: style?.followVelocity = nil
        case ["notes"]: style?.notes = nil
        case ["notes", noteKey, "vibrato"]: style?.notes?[noteID]?.vibrato = nil
        case ["notes", noteKey, "air"]: style?.notes?[noteID]?.air = nil
        default: Issue.record("no expectation for \(path)")
        }
        return style
    }

    static func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    static func removing(_ path: [String], from object: [String: Any]) -> [String: Any] {
        guard let first = path.first else { return object }
        var out = object
        if path.count == 1 {
            out.removeValue(forKey: first)
        } else if let inner = object[first] as? [String: Any] {
            out[first] = removing(Array(path.dropFirst()), from: inner)
        }
        return out
    }

    static func decode<T: Decodable>(_ type: T.Type, _ object: [String: Any]) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }

    @Test("S7 control: the full JSON has every key, decodes with every field set, and losing a REQUIRED key fails")
    func controls() throws {
        let clip = try Self.object(Self.melody)
        let style = try #require(clip["singStyle"] as? [String: Any])
        #expect(Set(style.keys) == ["vibrato", "air", "followVelocity", "notes"])
        let note = try #require((style["notes"] as? [String: Any])?[Self.noteKey] as? [String: Any])
        #expect(Set(note.keys) == ["vibrato", "air"])
        #expect(try Self.decode(Clip.self, clip).singStyle == Self.fullStyle)
        #expect(try Self.decode(ClipDocument.self, Self.object(ClipDocument(from: Self.melody, media: nil))).singStyle
                == Self.fullStyle)
        #expect(try Self.decode(SungVocalProvenance.self, Self.object(Self.record)).style == Self.fullStyle)
        // The harness CAN fail: a clip with no id is a damaged file.
        #expect(throws: DecodingError.self) { _ = try Self.decode(Clip.self, Self.removing(["id"], from: clip)) }
        // And a removal really removes (the nested path walks into the note's own object).
        let trimmed = Self.removing(["singStyle", "notes", Self.noteKey, "air"], from: clip)
        let trimmedNote = ((trimmed["singStyle"] as? [String: Any])?["notes"] as? [String: Any])?[Self.noteKey]
        #expect((trimmedNote as? [String: Any]).map { Set($0.keys) } == ["vibrato"])
    }

    @Test("S7: Clip.singStyle and each field inside it may be missing")
    func clipFields() throws {
        let full = try Self.object(Self.melody)
        for path in Self.paths {
            let json = Self.removing(["singStyle"] + path, from: full)
            do {
                #expect(try Self.decode(Clip.self, json).singStyle == Self.expected(afterRemoving: path),
                        "Clip, \(path) removed")
            } catch {
                Issue.record("Clip did not decode with singStyle\(path) removed: \(error)")
            }
        }
    }

    @Test("S7: ClipDocument.singStyle (the file's own clip record) and each field inside it may be missing")
    func clipDocumentFields() throws {
        let full = try Self.object(ClipDocument(from: Self.melody, media: nil))
        for path in Self.paths {
            let json = Self.removing(["singStyle"] + path, from: full)
            do {
                #expect(try Self.decode(ClipDocument.self, json).singStyle == Self.expected(afterRemoving: path),
                        "ClipDocument, \(path) removed")
            } catch {
                Issue.record("ClipDocument did not decode with singStyle\(path) removed: \(error)")
            }
        }
    }

    @Test("S7: SungVocalProvenance.style and each field inside it may be missing")
    func provenanceFields() throws {
        let full = try Self.object(Self.record)
        for path in Self.paths {
            let json = Self.removing(["style"] + path, from: full)
            do {
                #expect(try Self.decode(SungVocalProvenance.self, json).style == Self.expected(afterRemoving: path),
                        "SungVocalProvenance, \(path) removed")
            } catch {
                Issue.record("SungVocalProvenance did not decode with style\(path) removed: \(error)")
            }
        }
        // And a record without a style writes no key at all (the synthesized encoder omits a nil optional).
        var plain = Self.record
        plain.style = nil
        #expect(try Self.object(plain)["style"] == nil)
    }
}

// MARK: - S7 rows for p2-sing-x6's provenance fields (APPENDED by W8-X6)

/// S7 (design §9.2) for `SungVocalProvenance.partRole` and `.harmony` (and every field inside `harmony`): a FULL JSON
/// with exactly one of those keys removed still decodes, reading the field as its default; a record without them
/// writes neither key. Plant that must turn it red: decode `partRole` with `decode` instead of `decodeIfPresent`.
extension SingStyleFieldsOptionalTests {

    static var partRecord: SungVocalProvenance {
        var record = Self.record
        record.partRole = SungVocalProvenance.PartRole.harmony
        record.harmony = SungVocalHarmony(spec: HarmonySpec(interval: .sixth, direction: .below, chordSource: .thisClip),
                                          key: SongKey(tonicPitchClass: 9, mode: .minor, source: .estimated,
                                                       confidence: 0.75),
                                          chordToneRank: .third)
        return record
    }

    static let harmonyKeys = ["interval", "direction", "chordSource", "keyTonicPitchClass", "keyMode", "keySource",
                              "keyConfidence", "chordToneRank"]

    @Test("S7 (x6): SungVocalProvenance.partRole, .harmony and each field inside harmony may be missing")
    func partFields() throws {
        let full = try Self.object(Self.partRecord)
        // Control: the full record carries every key, and decodes to itself.
        let harmony = try #require(full["harmony"] as? [String: Any])
        #expect(Set(harmony.keys) == Set(Self.harmonyKeys))
        #expect(full["partRole"] as? String == "harmony")
        #expect(try Self.decode(SungVocalProvenance.self, full) == Self.partRecord)
        #expect(try Self.decode(SungVocalProvenance.self, full).harmony?.spec
                == HarmonySpec(interval: .sixth, direction: .below, chordSource: .thisClip))
        #expect(try Self.decode(SungVocalProvenance.self, full).harmony?.key
                == SongKey(tonicPitchClass: 9, mode: .minor, source: .estimated, confidence: 0.75))

        #expect(try Self.decode(SungVocalProvenance.self, Self.removing(["partRole"], from: full)).partRole == nil)
        let noHarmony = try Self.decode(SungVocalProvenance.self, Self.removing(["harmony"], from: full))
        #expect(noHarmony.harmony == nil)
        #expect(noHarmony.partRole == "harmony")
        for key in Self.harmonyKeys {
            do {
                let decoded = try Self.decode(SungVocalProvenance.self, Self.removing(["harmony", key], from: full))
                let mirror = Mirror(reflecting: try #require(decoded.harmony))
                let value = mirror.children.first { $0.label == key }?.value
                #expect(value.map { "\($0)" } == "nil", "harmony.\(key) removed should read nil")
            } catch {
                Issue.record("SungVocalProvenance did not decode with harmony.\(key) removed: \(error)")
            }
        }
        // A value from a later build still opens: the typed views read nil, the record keeps the raw string.
        var later = harmony
        later["interval"] = "ninth"
        var json = full
        json["harmony"] = later
        let decoded = try Self.decode(SungVocalProvenance.self, json)
        #expect(decoded.harmony?.interval == "ninth")
        #expect(decoded.harmony?.spec == nil)
        // A record without either writes no key at all (S2: older files re-encode to their own bytes).
        let plain = try Self.object(Self.record)
        #expect(plain["partRole"] == nil && plain["harmony"] == nil)
    }
}
