import Foundation

// m39-tpl-1 — THE ONE CODEC for templates
// (docs/design/2026-09-27-multi-instrument-templates.md §4.5–§4.8, §5.1).
//
// Built-in templates, saved `.dawtemplate` files, inline wire objects and
// `template.describe` replies are the SAME JSON; this decodes all of them.
// Pure: Foundation only, nonisolated, no store, no engine, no file system.
//
// What it owns (§5.1): NAMES, RANGES and VERSIONS — every key, kind and setting
// name is known, every value is in range, and every written effect setting
// READS BACK as written. What it does NOT own, and leaves to the builder
// (TPL-2's `TemplateBuilder.plan`): whether a reference RESOLVES (a send to a
// bus key the template does not have), routing legality (a bus that sends),
// the sidechain rules (`SidechainRules`), whether a route target may be
// modulated (`ModulationRules`), and the 64-slot budget.
//
// ⭐ KINDS ARE JUDGED AS RAW STRINGS. Nothing here decodes a kind straight into
// a typed enum, so an unknown kind is this codec's controlled refusal (or, from
// a newer writer, a coded skip) — never a `DecodingError`, and never the
// project format's "an unknown instrument kind fails the whole open" (F-1).
//
// ⭐ THE VERSION RULE, per element (§4.7): a problem the reader can blame on the
// AUTHOR is refused; a problem it can blame on a NEWER WRITER is skipped with a
// coded warning. A file whose `formatVersion` is this build's (or omitted, as
// every inline wire template may) is read STRICTLY; a file from a newer
// `formatVersion` is read LENIENTLY. A malformed value (a kind given as a
// number, a fraction where a whole number goes, a truncated file) is refused in
// both modes: no writer, old or new, produces one.
//
// ⭐ OUT-OF-RANGE VALUES ARE REFUSED, not clamped — stricter than `fx.add` and
// `mod.addSource`, on purpose: the m34-q law (`track.setInstrument`: "an agent
// that asked for 20 unison voices and silently got 8 has no way to find out").
// A template is written once and applied many times, so a value that does not
// hold is a bug to fix where it was written.

public enum TrackSetTemplateCodec {
    /// The first key of every template file.
    public static let format = "dawpro.template"
    /// A file above this is refused before it is parsed. [A] — bounds the
    /// main-actor decode; an Audio Unit's saved `state` is the only large
    /// field, and TPL-5 measures real ones and sets the final bound (§4.8).
    public static let maxFileBytes = 2 * 1024 * 1024
    /// Tracks per template: the skeleton's roster ceiling, the SAME number, so
    /// the two scaffolds cannot drift (a test pins them equal).
    public static let trackCountRange: ClosedRange<Int> = 1...24
    /// Template, track and modulation-source names: the skeleton's one-home
    /// label bound (a test pins them equal).
    public static let maxNameLength = 40
    /// [A] §4.8.
    public static let maxSummaryLength = 200
    /// [A] §4.4: 1–32 lowercase letters, digits and hyphens.
    public static let maxKeyLength = 32
    /// [A] Built-in ids are kebab-case; saved ids are `user-<uuid>` (41
    /// characters). Letters, digits and hyphens, at most 64.
    public static let maxIDLength = 64
    /// §5.3's read-back rule: a written setting must read back within this
    /// RELATIVE distance of what was written. [A] set by measurement — see
    /// `TrackSetTemplateCodecTests.readBackErrorOfInRangeValues`.
    public static let readBackTolerance = 1e-9

    /// Where the bytes came from. A FILE must carry `format`, `id`,
    /// `formatVersion` and `minReaderVersion`; an INLINE wire template may omit
    /// all four (it is then read as this build's version, strictly), and must
    /// still carry `name` and `tracks` (§4.7).
    public enum Origin: Sendable, Equatable {
        case file
        case inline
    }

    /// A decoded template and what the reader worked around to get it.
    public struct Result: Sendable, Equatable {
        public var template: TrackSetTemplate
        public var warnings: [TemplateWarning]
    }

    /// Decodes one template. Throws `TemplateRefusal`, naming the path and what
    /// would be valid, for anything it will not accept.
    public static func decode(_ data: Data, origin: Origin) throws -> Result {
        guard data.count <= maxFileBytes else {
            throw TemplateRefusal(
                code: .tooLarge, path: "",
                message: "This template file is \(data.count) bytes, and a template can be at "
                    + "most \(maxFileBytes) bytes (2 MB).")
        }
        let json: TemplateJSON
        do {
            json = try JSONDecoder().decode(TemplateJSON.self, from: data)
        } catch {
            throw TemplateRefusal(
                code: .notJSON, path: "",
                message: "This isn't a complete template: the file is not valid JSON. It may "
                    + "have been cut short while it was being saved or copied.")
        }
        var reader = TemplateReader(origin: origin)
        let template = try reader.readTemplate(json)
        return Result(template: template, warnings: reader.warnings)
    }
}

// MARK: - The JSON tree

/// A JSON value, decoded through `Codable`. DAWCore has no JSON tree of its own
/// (DAWControl's `JSONValue` is invisible from here), and templates need the
/// exact JSON TYPE of every value: a `1` where a switch belongs, or a `true`
/// where a number belongs, is refused rather than coerced.
enum TemplateJSON: Decodable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([TemplateJSON])
    case object([String: TemplateJSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([TemplateJSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: TemplateJSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "not a JSON value")
        }
    }

    /// A novice-readable name for the JSON type, for "must be a number" errors.
    var typeName: String {
        switch self {
        case .null: return "null"
        case .bool: return "true or false"
        case .number: return "a number"
        case .string: return "text"
        case .array: return "a list"
        case .object: return "an object"
        }
    }
}
