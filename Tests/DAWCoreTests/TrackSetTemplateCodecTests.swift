import Foundation
import Testing
@testable import DAWCore

// m39-tpl-1 — the template codec's gate
// (docs/design/2026-09-27-multi-instrument-templates.md §8.5, §4.7).
//
// One test per row of §4.7's table, each run BOTH ways: a file from this
// build's format version (the author's problem → REFUSED, naming the path) and
// a file from a newer one (a newer writer's problem → SKIPPED, with the coded
// warning at the same path). Then the version gate, the 2 MB bound, a kind given
// as a number, a truncated file, the read-back rule, the type-strictness
// controls, and the TPL-0 tripwire.
//
// Deliberately NOT `@MainActor`: the codec is pure. The one main-actor pin (the
// limits the codec shares with `macro.songSkeleton`) is an extension of the
// existing `SongSkeletonTests` suite at the bottom of this file.

@Suite("m39-tpl-1: template codec — §4.7's rows both ways, versions, bounds, read-back")
struct TrackSetTemplateCodecTests {
    typealias Codec = TrackSetTemplateCodec

    // MARK: - Helpers

    /// A FILE around `tracks` (JSON array text) at `formatVersion`.
    static func file(_ tracks: String, formatVersion: Int = 1, minReader: Int = 1,
                     top: String = "") -> Data {
        let extra = top.isEmpty ? "" : "\(top), "
        return Data(("{\"format\": \"dawpro.template\", \"formatVersion\": \(formatVersion), "
            + "\"minReaderVersion\": \(minReader), \"id\": \"probe\", \"name\": \"Probe\", "
            + "\(extra)\"tracks\": \(tracks)}").utf8)
    }

    /// An INLINE wire template around `tracks`: no format, id or versions.
    static func inline(_ tracks: String, top: String = "") -> Data {
        let extra = top.isEmpty ? "" : "\(top), "
        return Data("{\"name\": \"Probe\", \(extra)\"tracks\": \(tracks)}".utf8)
    }

    static func refusal(_ data: Data,
                        _ origin: TrackSetTemplateCodec.Origin = .file) -> TemplateRefusal? {
        do {
            _ = try Codec.decode(data, origin: origin)
            return nil
        } catch let refusal as TemplateRefusal {
            return refusal
        } catch {
            return TemplateRefusal(code: .notJSON, path: "<not a TemplateRefusal>",
                                   message: String(describing: error))
        }
    }

    /// The two directions of one row: this version (strict) and a newer one.
    enum Direction: String, CaseIterable, Sendable {
        case sameVersion, newerVersion
        var formatVersion: Int {
            self == .sameVersion
                ? TrackSetTemplate.currentFormatVersion
                : TrackSetTemplate.currentFormatVersion + 1
        }
    }

    /// One row case: a template's tracks, the path the problem sits at, the
    /// refusal code a strict read gives, the warning code a lenient read gives.
    struct RowCase: Sendable, CustomTestStringConvertible {
        let label: String
        let tracks: String
        var top: String = ""
        let path: String
        let refusal: TemplateRefusal.Code
        let warning: TemplateWarning.Code
        var testDescription: String { label }
    }

    /// Runs one row both ways and returns the lenient result for extra checks.
    @discardableResult
    static func checkRow(_ row: RowCase,
                         sourceLocation: SourceLocation = #_sourceLocation)
        -> TrackSetTemplateCodec.Result? {
        let strict = refusal(file(row.tracks, formatVersion: Direction.sameVersion.formatVersion,
                                  top: row.top))
        #expect(strict?.code == row.refusal,
                "\(row.label): same version must be refused as \(row.refusal), got \(String(describing: strict))",
                sourceLocation: sourceLocation)
        #expect(strict?.path == row.path, "\(row.label): refusal path",
                sourceLocation: sourceLocation)
        #expect(strict?.message.isEmpty == false, sourceLocation: sourceLocation)
        let data = file(row.tracks, formatVersion: Direction.newerVersion.formatVersion,
                        top: row.top)
        do {
            let result = try Codec.decode(data, origin: .file)
            let hit = result.warnings.contains { $0.code == row.warning && $0.path == row.path }
            #expect(hit,
                    "\(row.label): a newer version must skip with \(row.warning) at \(row.path); warnings were \(result.warnings)",
                    sourceLocation: sourceLocation)
            return result
        } catch {
            Issue.record("\(row.label): a newer version must NOT be refused: \(error)",
                         sourceLocation: sourceLocation)
            return nil
        }
    }

    static let audio = #"{"key": "a", "name": "A", "kind": "audio""#
    static let lfo = #"{"key": "l", "kind": "lfo"}"#

    // MARK: - §4.7 row 1: an unknown key, at any level

    static let unknownKeyCases: [RowCase] = [
        RowCase(label: "top level", tracks: "[\(audio)}]", top: #""colour": "red""#,
                path: "colour", refusal: .unknownKey, warning: .unknownKeySkipped),
        RowCase(label: "track", tracks: "[\(audio), \"colour\": 1}]",
                path: "tracks[0].colour", refusal: .unknownKey, warning: .unknownKeySkipped),
        RowCase(label: "insert",
                tracks: "[\(audio), \"inserts\": [{\"kind\": \"gain\", \"colour\": 1}]}]",
                path: "tracks[0].inserts[0].colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "instrument (a Poly Synth name no synth has)",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth", "colour": 1}}]"#,
                path: "tracks[0].instrument.colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "sound bank",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "soundBank", "soundBank": {"source": "gm", "colour": 1}}}]"#,
                path: "tracks[0].instrument.soundBank.colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "send",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "sends": [{"bus": "b", "colour": 1}]}, {"key": "b", "name": "B", "kind": "bus"}]"#,
                path: "tracks[0].sends[0].colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "modulation",
                tracks: "[\(audio), \"modulation\": {\"colour\": 1}}]",
                path: "tracks[0].modulation.colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "modulation source",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo", "colour": 1}]}}]"#,
                path: "tracks[0].modulation.sources[0].colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "route",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "volume"}, "depth": 0.1, "colour": 1}]}}]"#,
                path: "tracks[0].modulation.routes[0].colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "route target",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "volume", "colour": 1}, "depth": 0.1}]}}]"#,
                path: "tracks[0].modulation.routes[0].target.colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
        RowCase(label: "audio unit",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "inserts": [{"kind": "audioUnit", "audioUnit": {"subType": "abcd", "manufacturer": "wxyz", "colour": 1}}]}]"#,
                path: "tracks[0].inserts[0].audioUnit.colour", refusal: .unknownKey,
                warning: .unknownKeySkipped),
    ]

    @Test("§4.7 row 1 — an unknown key at any level: refused, or skipped from a newer writer",
          arguments: unknownKeyCases)
    func unknownKeyRow(_ row: RowCase) {
        Self.checkRow(row)
    }

    // MARK: - §4.7 row 2: an unknown effect kind

    @Test("§4.7 row 2 — an unknown effect kind: refused, or the insert and its routes skipped")
    func unknownEffectKindRow() throws {
        let tracks = #"[{"key": "a", "name": "A", "kind": "audio", "inserts": [{"key": "x", "kind": "granulator"}, {"key": "t", "kind": "djFilter"}], "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "effectParam", "insert": "x", "param": "grain"}, "depth": 0.2}, {"source": "l", "target": {"type": "effectParam", "insert": "t", "param": "position"}, "depth": 0.1}]}}]"#
        let result = try #require(Self.checkRow(RowCase(
            label: "unknown effect", tracks: tracks, path: "tracks[0].inserts[0].kind",
            refusal: .unknownKind, warning: .unknownEffectSkipped)))
        let track = try #require(result.template.tracks.first)
        #expect(track.inserts.map(\.kind) == [.djFilter])
        #expect(track.modulationRoutes.count == 1, "the route into the skipped insert must go too")
        #expect(track.modulationRoutes.first?.target == .effectParam(insert: "t", param: "position"))
        #expect(result.warnings.contains {
            $0.code == .unknownEffectSkipped
                && $0.path == "tracks[0].modulation.routes[0].target.insert"
        }, "the cascaded route must be reported, not dropped silently: \(result.warnings)")
    }

    // MARK: - §4.7 row 3: an unknown instrument kind

    @Test("§4.7 row 3 — an unknown instrument kind: refused, or the WHOLE track and its keys skipped")
    func unknownInstrumentKindRow() throws {
        let tracks = #"[{"key": "lead", "name": "Lead", "kind": "instrument", "instrument": {"kind": "theremin"}}, {"key": "duck", "name": "Duck", "kind": "bus", "inserts": [{"kind": "compressor", "sidechainSource": "lead"}]}]"#
        let result = try #require(Self.checkRow(RowCase(
            label: "unknown instrument", tracks: tracks, path: "tracks[0].instrument.kind",
            refusal: .unknownKind, warning: .unknownInstrumentSkipped)))
        #expect(result.template.tracks.map(\.key) == ["duck"], "never a substitute sound")
        #expect(result.template.tracks.first?.inserts.first?.sidechainSource == nil)
        #expect(result.warnings.contains {
            $0.code == .unknownInstrumentSkipped
                && $0.path == "tracks[1].inserts[0].sidechainSource"
        }, "the cascade names the key's position in the FILE: \(result.warnings)")
    }

    @Test("a cascade's warnings name each insert and send where the FILE has it, after earlier skips")
    func cascadePathsNameFilePositions() throws {
        let tracks = #"[{"key": "lead", "name": "Lead", "kind": "instrument", "instrument": {"kind": "theremin"}}, {"key": "duck", "name": "Duck", "kind": "bus", "inserts": [{"kind": "granulator"}, {"kind": "compressor", "sidechainSource": "lead"}], "sends": [{"bus": "room", "level": 0.1}, {"bus": "lead", "level": 0.2}]}, {"key": "room", "name": "Room", "kind": "bus"}]"#
        let result = try Codec.decode(Self.file(tracks, formatVersion: 2), origin: .file)
        let paths = result.warnings.map(\.path)
        #expect(paths.contains("tracks[1].inserts[1].sidechainSource"), "\(paths)")
        #expect(paths.contains("tracks[1].sends[1].bus"), "\(paths)")
        #expect(!paths.contains("tracks[1].inserts[0].sidechainSource"),
                "the kept compressor is the file's SECOND insert")
        let duck = try #require(result.template.tracks.first { $0.key == "duck" })
        #expect(duck.inserts.map(\.kind) == [.compressor])
        #expect(duck.inserts.first?.sidechainSource == nil)
        #expect(duck.sends == [TemplateSend(bus: "room", level: 0.1)])
    }

    @Test("§4.7 — an unknown TRACK kind: refused, or the track and every route into it skipped")
    func unknownTrackKind() throws {
        let tracks = #"[{"key": "a", "name": "A", "kind": "audio", "output": "v", "sends": [{"bus": "v", "level": 0.5}]}, {"key": "v", "name": "V", "kind": "vca"}]"#
        let result = try #require(Self.checkRow(RowCase(
            label: "unknown track kind", tracks: tracks, path: "tracks[1].kind",
            refusal: .unknownKind, warning: .unknownTrackKindSkipped)))
        let track = try #require(result.template.tracks.first)
        #expect(result.template.tracks.count == 1)
        #expect(track.output == nil)
        #expect(track.sends.isEmpty)
        #expect(result.warnings.filter { $0.code == .unknownTrackKindSkipped }.count == 3,
                "the track, its output and its send: \(result.warnings)")
    }

    // MARK: - §4.7 row 4: an unknown setting name

    static let unknownSettingCases: [RowCase] = [
        RowCase(label: "effect setting",
                tracks: "[\(audio), \"inserts\": [{\"kind\": \"compressor\", \"params\": {\"ratio\": 4, \"bogus\": 1}}]}]",
                path: "tracks[0].inserts[0].params.bogus", refusal: .unknownSetting,
                warning: .unknownSettingSkipped),
        RowCase(label: "drum voice setting",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "drumSynth", "drumKit": {"kick": {"bogus": 1}}}}]"#,
                path: "tracks[0].instrument.drumKit.kick.bogus", refusal: .unknownSetting,
                warning: .unknownSettingSkipped),
        RowCase(label: "drum kit-wide setting",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "drumSynth", "drumKit": {"bogus": 1}}}]"#,
                path: "tracks[0].instrument.drumKit.bogus", refusal: .unknownSetting,
                warning: .unknownSettingSkipped),
        RowCase(label: "waveform choice",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth", "waveform": "pulse"}}]"#,
                path: "tracks[0].instrument.waveform", refusal: .unknownSetting,
                warning: .unknownSettingSkipped),
        RowCase(label: "modulation source setting",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo", "params": {"bogus": 1}}]}}]"#,
                path: "tracks[0].modulation.sources[0].params.bogus", refusal: .unknownSetting,
                warning: .unknownSettingSkipped),
        RowCase(label: "route to an effect setting",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "inserts": [{"key": "c", "kind": "compressor"}], "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "effectParam", "insert": "c", "param": "bogus"}, "depth": 0.1}]}}]"#,
                path: "tracks[0].modulation.routes[0].target.param", refusal: .unknownSetting,
                warning: .unknownSettingSkipped),
        RowCase(label: "route to an instrument setting",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth"}, "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "instrumentParam", "param": "bogus"}, "depth": 0.1}]}}]"#,
                path: "tracks[0].modulation.routes[0].target.param", refusal: .unknownSetting,
                warning: .unknownSettingSkipped),
    ]

    @Test("§4.7 row 4 — an unknown setting name: refused listing the valid names, or skipped",
          arguments: unknownSettingCases)
    func unknownSettingRow(_ row: RowCase) {
        Self.checkRow(row)
    }

    @Test("§4.7 row 4 — the refusal lists the kind's valid names, read from the one table")
    func unknownSettingListsValidNames() throws {
        let data = Self.file("[\(Self.audio), \"inserts\": [{\"kind\": \"compressor\", \"params\": {\"bogus\": 1}}]}]")
        let refusal = try #require(Self.refusal(data))
        for spec in EffectParamSpec.specs(for: .compressor) {
            #expect(refusal.message.contains(spec.name), "missing \(spec.name): \(refusal.message)")
        }
        let lenient = try Codec.decode(Self.file(
            "[\(Self.audio), \"inserts\": [{\"kind\": \"compressor\", \"params\": {\"ratio\": 4, \"bogus\": 1}}]}]",
            formatVersion: 2), origin: .file)
        #expect(lenient.template.tracks.first?.inserts.first?.params == ["ratio": 4],
                "the known setting stays, the unknown one goes")
    }

    // MARK: - §4.7 row 5: an unknown modulation source kind or target type

    @Test("§4.7 row 5 — an unknown modulation source kind: refused, or it and its routes skipped")
    func unknownModulationSourceKindRow() throws {
        let tracks = #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "g", "kind": "chaos"}, {"key": "l", "kind": "lfo"}], "routes": [{"source": "g", "target": {"type": "volume"}, "depth": 0.1}, {"source": "l", "target": {"type": "pan"}, "depth": 0.1}]}}]"#
        let result = try #require(Self.checkRow(RowCase(
            label: "unknown source kind", tracks: tracks,
            path: "tracks[0].modulation.sources[0].kind", refusal: .unknownKind,
            warning: .unknownModulationSkipped)))
        let track = try #require(result.template.tracks.first)
        #expect(track.modulationSources.map(\.key) == ["l"])
        #expect(track.modulationRoutes.map(\.target) == [.pan])
        #expect(result.warnings.contains {
            $0.code == .unknownModulationSkipped
                && $0.path == "tracks[0].modulation.routes[0].source"
        })
    }

    static let unknownTargetCases: [RowCase] = [
        RowCase(label: "sendLevel (not spellable in a template)",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "sendLevel"}, "depth": 0.1}]}}]"#,
                path: "tracks[0].modulation.routes[0].target.type", refusal: .unknownKind,
                warning: .unknownModulationSkipped),
        RowCase(label: "a target type no version has",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "tempo"}, "depth": 0.1}]}}]"#,
                path: "tracks[0].modulation.routes[0].target.type", refusal: .unknownKind,
                warning: .unknownModulationSkipped),
    ]

    @Test("§4.7 row 5 — an unknown modulation target type: refused, or the route skipped",
          arguments: unknownTargetCases)
    func unknownTargetTypeRow(_ row: RowCase) throws {
        let result = Self.checkRow(row)
        #expect(result?.template.tracks.first?.modulationRoutes.isEmpty == true)
    }

    // MARK: - §4.7 row 6: a value out of range

    static let over = 1_000_000.0

    static let outOfRangeCases: [RowCase] = [
        RowCase(label: "volume", tracks: "[\(audio), \"volume\": 3}]",
                path: "tracks[0].volume", refusal: .outOfRange, warning: .valueClamped),
        RowCase(label: "pan", tracks: "[\(audio), \"pan\": -2}]",
                path: "tracks[0].pan", refusal: .outOfRange, warning: .valueClamped),
        RowCase(label: "send level",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "sends": [{"bus": "b", "level": 5}]}, {"key": "b", "name": "B", "kind": "bus"}]"#,
                path: "tracks[0].sends[0].level", refusal: .outOfRange, warning: .valueClamped),
        RowCase(label: "effect setting",
                tracks: "[\(audio), \"inserts\": [{\"kind\": \"compressor\", \"params\": {\"ratio\": 50}}]}]",
                path: "tracks[0].inserts[0].params.ratio", refusal: .outOfRange,
                warning: .valueClamped),
        RowCase(label: "Poly Synth number",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth", "cutoffHz": 30000}}]"#,
                path: "tracks[0].instrument.cutoffHz", refusal: .outOfRange,
                warning: .valueClamped),
        RowCase(label: "Poly Synth whole number",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth", "unisonVoices": 12}}]"#,
                path: "tracks[0].instrument.unisonVoices", refusal: .outOfRange,
                warning: .valueClamped),
        RowCase(label: "drum setting",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "drumSynth", "drumKit": {"kick": {"decay": 1000000}}}}]"#,
                path: "tracks[0].instrument.drumKit.kick.decay", refusal: .outOfRange,
                warning: .valueClamped),
        RowCase(label: "choke group",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "drumSynth", "drumKit": {"closedHat": {"chokeGroup": 99}}}}]"#,
                path: "tracks[0].instrument.drumKit.closedHat.chokeGroup", refusal: .outOfRange,
                warning: .valueClamped),
        RowCase(label: "sound bank program",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "soundBank", "soundBank": {"source": "gm", "program": 200}}}]"#,
                path: "tracks[0].instrument.soundBank.program", refusal: .outOfRange,
                warning: .valueClamped),
        RowCase(label: "route depth",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "volume"}, "depth": 2}]}}]"#,
                path: "tracks[0].modulation.routes[0].depth", refusal: .outOfRange,
                warning: .valueClamped),
        RowCase(label: "modulation source setting",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo", "params": {"rateHz": 1000000}}]}}]"#,
                path: "tracks[0].modulation.sources[0].params", refusal: .outOfRange,
                warning: .valueClamped),
    ]

    @Test("§4.7 row 6 — a value out of range: REFUSED naming the range (m34-q), or clamped",
          arguments: outOfRangeCases)
    func outOfRangeRow(_ row: RowCase) {
        Self.checkRow(row)
    }

    @Test("§4.7 row 6 — the refusal names the range and what the value would become; a newer file keeps the clamp")
    func outOfRangeNamesRangeAndResult() throws {
        let range = CompressorParams.ratioRange
        let tracks = "[\(Self.audio), \"inserts\": [{\"kind\": \"compressor\", \"params\": {\"ratio\": 50}}]}]"
        let refusal = try #require(Self.refusal(Self.file(tracks)))
        #expect(refusal.message.contains(ClampNotice.number(range.lowerBound))
                && refusal.message.contains(ClampNotice.number(range.upperBound)),
                "the range: \(refusal.message)")
        #expect(refusal.message.contains("would become \(ClampNotice.number(range.upperBound))"),
                "\(refusal.message)")
        let lenient = try Codec.decode(Self.file(tracks, formatVersion: 2), origin: .file)
        #expect(lenient.template.tracks.first?.inserts.first?.params["ratio"] == range.upperBound)
        let volume = try Codec.decode(Self.file("[\(Self.audio), \"volume\": 3}]", formatVersion: 2),
                                      origin: .file)
        #expect(volume.template.tracks.first?.volume == Track.volumeRange.upperBound)
    }

    // MARK: - Versions

    @Test("minReaderVersion above this build's: the WHOLE file is refused, in words")
    func minReaderVersionRefusesTheFile() throws {
        for origin in [TrackSetTemplateCodec.Origin.file, .inline] {
            let data = origin == .file
                ? Self.file("[\(Self.audio)}]", formatVersion: 2, minReader: 2)
                : Self.inline("[\(Self.audio)}]", top: #""minReaderVersion": 2"#)
            let refusal = try #require(Self.refusal(data, origin))
            #expect(refusal.code == .needsNewerVersion)
            #expect(refusal.message == "This template needs a newer version of DAW Pro.")
        }
        // Control: the same file with minReaderVersion 1 is read (leniently).
        #expect(Self.refusal(Self.file("[\(Self.audio)}]", formatVersion: 2, minReader: 1)) == nil)
    }

    @Test("a FILE must carry format, id and both versions; an inline template may omit them")
    func fileAndInlineRequiredKeys() throws {
        let tracks = "[\(Self.audio)}]"
        let inline = try Codec.decode(Self.inline(tracks), origin: .inline)
        #expect(inline.template.formatVersion == TrackSetTemplate.currentFormatVersion)
        #expect(inline.template.minReaderVersion == 1)
        #expect(inline.template.id.isEmpty)
        #expect(inline.warnings.isEmpty)
        #expect(Self.refusal(Self.inline(tracks), .file)?.code == .notATemplate,
                "a file without format")
        for missing in ["id", "formatVersion", "minReaderVersion"] {
            var object = try JSONSerialization.jsonObject(with: Self.file(tracks)) as! [String: Any]
            object[missing] = nil
            let data = try JSONSerialization.data(withJSONObject: object)
            let refusal = Self.refusal(data, .file)
            #expect(refusal?.code == .missingKey && refusal?.path == missing,
                    "\(missing): \(String(describing: refusal))")
        }
        #expect(Self.refusal(Self.inline("[]"), .inline)?.code == .outOfRange, "no tracks")
        #expect(Self.refusal(Data(#"{"tracks": []}"#.utf8), .inline)?.path == "name")
        let wrongFormat = Data(#"{"format": "somebody.else", "name": "X", "tracks": []}"#.utf8)
        #expect(Self.refusal(wrongFormat, .inline)?.code == .notATemplate)
    }

    // MARK: - The size bound, a kind given as a number, a truncated file

    @Test("a file over 2 MB is refused before parsing; exactly 2 MB is read")
    func sizeBound() throws {
        let tracks = "[\(Self.audio)}]"
        var exact = Self.file(tracks)
        exact.append(Data(repeating: UInt8(ascii: " "), count: Codec.maxFileBytes - exact.count))
        #expect(exact.count == Codec.maxFileBytes)
        #expect(Self.refusal(exact) == nil, "exactly the bound must be read")
        var over = exact
        over.append(UInt8(ascii: " "))
        let refusal = try #require(Self.refusal(over))
        #expect(refusal.code == .tooLarge)
        #expect(Codec.maxFileBytes == 2 * 1024 * 1024)
    }

    static let kindAsNumberCases: [RowCase] = [
        RowCase(label: "track kind", tracks: #"[{"key": "a", "name": "A", "kind": 1}]"#,
                path: "tracks[0].kind", refusal: .wrongType, warning: .unknownKeySkipped),
        RowCase(label: "effect kind",
                tracks: "[\(audio), \"inserts\": [{\"kind\": 3}]}]",
                path: "tracks[0].inserts[0].kind", refusal: .wrongType, warning: .unknownKeySkipped),
        RowCase(label: "instrument kind",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": true}}]"#,
                path: "tracks[0].instrument.kind", refusal: .wrongType,
                warning: .unknownKeySkipped),
        RowCase(label: "modulation source kind",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": 2}]}}]"#,
                path: "tracks[0].modulation.sources[0].kind", refusal: .wrongType,
                warning: .unknownKeySkipped),
    ]

    @Test("a kind given as a number is malformed: refused by EVERY version",
          arguments: kindAsNumberCases)
    func kindGivenAsANumber(_ row: RowCase) {
        for direction in Direction.allCases {
            let refusal = Self.refusal(Self.file(row.tracks, formatVersion: direction.formatVersion))
            #expect(refusal?.code == .wrongType && refusal?.path == row.path,
                    "\(row.label) \(direction): \(String(describing: refusal))")
        }
    }

    @Test("a truncated file is refused as not JSON, never half-read")
    func truncatedFile() throws {
        let whole = Self.file("[\(Self.audio)}]")
        #expect(Self.refusal(whole) == nil, "control: the whole file reads")
        for cut in [1, 10, whole.count / 2, whole.count - 1] {
            let refusal = Self.refusal(whole.prefix(whole.count - cut))
            #expect(refusal?.code == .notJSON, "cut \(cut): \(String(describing: refusal))")
        }
        #expect(Self.refusal(Data())?.code == .notJSON)
    }

    // MARK: - Type strictness (no coercion, in either version)

    static let wrongTypeCases: [RowCase] = [
        RowCase(label: "1 for a switch", tracks: "[\(audio), \"inserts\": [{\"kind\": \"gain\", \"bypassed\": 1}]}]",
                path: "tracks[0].inserts[0].bypassed", refusal: .wrongType, warning: .unknownKeySkipped),
        RowCase(label: "true for a number", tracks: "[\(audio), \"volume\": true}]",
                path: "tracks[0].volume", refusal: .wrongType, warning: .unknownKeySkipped),
        RowCase(label: "a fraction for unisonVoices",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth", "unisonVoices": 2.5}}]"#,
                path: "tracks[0].instrument.unisonVoices", refusal: .wrongType,
                warning: .unknownKeySkipped),
        RowCase(label: "a fraction for subOctave",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth", "subOctave": -1.5}}]"#,
                path: "tracks[0].instrument.subOctave", refusal: .wrongType,
                warning: .unknownKeySkipped),
        RowCase(label: "a fraction for pedalHoldLimit",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "polySynth", "pedalHoldLimit": 4.2}}]"#,
                path: "tracks[0].instrument.pedalHoldLimit", refusal: .wrongType,
                warning: .unknownKeySkipped),
        RowCase(label: "a fraction for a program",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "soundBank", "soundBank": {"source": "gm", "program": 3.5}}}]"#,
                path: "tracks[0].instrument.soundBank.program", refusal: .wrongType,
                warning: .unknownKeySkipped),
        RowCase(label: "a fraction for a bank",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "soundBank", "soundBank": {"source": "gm", "bankMSB": 120.5}}}]"#,
                path: "tracks[0].instrument.soundBank.bankMSB", refusal: .wrongType,
                warning: .unknownKeySkipped),
        RowCase(label: "a fraction for a choke group",
                tracks: #"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "drumSynth", "drumKit": {"closedHat": {"chokeGroup": 2.5}}}}]"#,
                path: "tracks[0].instrument.drumKit.closedHat.chokeGroup", refusal: .wrongType,
                warning: .unknownKeySkipped),
        RowCase(label: "text for a route's enabled",
                tracks: #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo"}], "routes": [{"source": "l", "target": {"type": "pan"}, "depth": 0.1, "enabled": "yes"}]}}]"#,
                path: "tracks[0].modulation.routes[0].enabled", refusal: .wrongType,
                warning: .unknownKeySkipped),
    ]

    @Test("no coercion: a wrong JSON type is refused by every version", arguments: wrongTypeCases)
    func wrongTypesAreRefused(_ row: RowCase) {
        for direction in Direction.allCases {
            let refusal = Self.refusal(Self.file(row.tracks, formatVersion: direction.formatVersion))
            #expect(refusal?.code == .wrongType && refusal?.path == row.path,
                    "\(row.label) \(direction): \(String(describing: refusal))")
        }
    }

    // MARK: - The read-back rule (§5.3)

    @Test("read-back: phaser.stages 5 would become 6 — refused, or 6 with valueChanged")
    func readBackStagesSnap() throws {
        let tracks = "[\(Self.audio), \"inserts\": [{\"kind\": \"phaser\", \"params\": {\"stages\": 5}}]}]"
        let refusal = try #require(Self.refusal(Self.file(tracks)))
        #expect(refusal.code == .readBack)
        #expect(refusal.path == "tracks[0].inserts[0].params.stages")
        #expect(refusal.message.contains("can't hold 5") && refusal.message.contains("would become 6"),
                "\(refusal.message)")
        let lenient = try Codec.decode(Self.file(tracks, formatVersion: 2), origin: .file)
        #expect(lenient.template.tracks.first?.inserts.first?.params["stages"] == 6)
        #expect(lenient.warnings.contains {
            $0.code == .valueChanged && $0.path == "tracks[0].inserts[0].params.stages"
        })
        // Control: an even count reads back and is kept as written.
        let even = try Codec.decode(Self.file(
            "[\(Self.audio), \"inserts\": [{\"kind\": \"phaser\", \"params\": {\"stages\": 8}}]}]"),
                                    origin: .file)
        #expect(even.template.tracks.first?.inserts.first?.params["stages"] == 8)
    }

    @Test("read-back: highPassEnabled 0.7 would become 1 — refused; 1 and 0 are kept")
    func readBackSwitch() throws {
        let tracks = "[\(Self.audio), \"inserts\": [{\"kind\": \"eq\", \"params\": {\"highPassEnabled\": 0.7}}]}]"
        let refusal = try #require(Self.refusal(Self.file(tracks)))
        #expect(refusal.code == .readBack)
        #expect(refusal.message.contains("would become 1"), "\(refusal.message)")
        for value in ["0", "1"] {
            let data = Self.file("[\(Self.audio), \"inserts\": [{\"kind\": \"eq\", \"params\": {\"highPassEnabled\": \(value), \"highPassFreq\": 120}}]}]")
            #expect(Self.refusal(data) == nil, "highPassEnabled \(value) with a corner reads back")
        }
    }

    /// §5.3 [A] replaced by a measurement: over every spec of every built-in
    /// kind, at both bounds, the default, the middle and three interior points,
    /// what a value written through the ONE writer reads back as. A value
    /// either holds (reads back within the tolerance) or clearly moves (a snap
    /// or a coupled switch, off by more than 1e-3 relative). Nothing may land
    /// in between: such a value would be refused although it effectively held,
    /// or accepted although it moved, depending on a tolerance nobody chose.
    @Test("read-back tolerance: in-range values hold or clearly move, never in between")
    func readBackErrorOfInRangeValues() throws {
        var held = 0, moved = 0
        var ambiguous: [String] = []
        var largestHeldError = 0.0
        var smallestMove = Double.infinity
        for kind in EffectDescriptor.Kind.allCases where kind != .audioUnit {
            for spec in EffectParamSpec.specs(for: kind) {
                let lo = spec.range.lowerBound, hi = spec.range.upperBound
                for value in [0.0, 1.0, 0.5, 0.1234567, 0.37, 0.8765].map({ lo + (hi - lo) * $0 })
                    + [spec.defaultValue] {
                    var effect = EffectDescriptor.newlyAdded(kind: kind)
                    effect.applySetting(spec.name, value)
                    let read = try #require(effect.paramValue(spec.name),
                                            "\(kind.rawValue).\(spec.name) has no reading")
                    let error = abs(read - value) / max(1, abs(value))
                    if error <= Codec.readBackTolerance {
                        held += 1
                        largestHeldError = max(largestHeldError, error)
                    } else if error > 1e-3 {
                        moved += 1
                        smallestMove = min(smallestMove, error)
                    } else {
                        ambiguous.append("\(kind.rawValue).\(spec.name) \(value) -> \(read)")
                    }
                }
            }
        }
        print("TPL1-MEASURE read-back: held \(held) (largest error \(largestHeldError)), moved "
              + "\(moved) (smallest move \(smallestMove)), ambiguous \(ambiguous.count)")
        #expect(held > 0 && moved > 0, "positive control: both outcomes must occur")
        #expect(ambiguous.isEmpty, "values that neither held nor clearly moved: \(ambiguous.prefix(5))")
    }

    /// ⚠️ A KNOWN GAP in the read-back rule, measured (reported, not fixed in
    /// TPL-1): four settings are STORED unsnapped and snapped only by the render
    /// (`clipper.mode`, `clipper.oversampling`, `saturator.oversampling`,
    /// `compressor.detectorMode`), and `paramValue` reads the stored value, so a
    /// fraction reads back exactly and passes. `clipper.mode: 0.7` plays as mode
    /// 1. When read-back learns the render's value, this stops recording and
    /// fails: flip it then.
    @Test("KNOWN GAP: clipper.mode 0.7 passes read-back although the render snaps it to 1")
    func unsnappedStoredSettingPassesReadBack() {
        let tracks = "[\(Self.audio), \"inserts\": [{\"kind\": \"clipper\", \"params\": {\"mode\": 0.7}}]}]"
        withKnownIssue("paramValue reads the stored, unsnapped value; only the render snaps it") {
            let refusal = Self.refusal(Self.file(tracks))
            #expect(refusal?.code == .readBack, "\(String(describing: refusal))")
        }
    }

    @Test("read-back applies every setting before reading any, in specs(for:) order")
    func readBackSeesCoupledSettings() throws {
        // Both orders of the EQ's coupled pair land in the same state (§2.3),
        // and both read back as written.
        for params in [#"{"highPassEnabled": 1, "highPassFreq": 120}"#,
                       #"{"highPassFreq": 120, "highPassEnabled": 1}"#] {
            let data = Self.file("[\(Self.audio), \"inserts\": [{\"kind\": \"eq\", \"params\": \(params)}]}]")
            let result = try Codec.decode(data, origin: .file)
            #expect(result.template.tracks.first?.inserts.first?.params
                    == ["highPassEnabled": 1, "highPassFreq": 120])
        }
    }

    // MARK: - Instruments

    @Test("a block that belongs to another instrument kind is refused, with a sentence that teaches")
    func misplacedInstrumentBlocks() throws {
        let cases: [(String, String, String)] = [
            (#"{"kind": "polySynth", "drumKit": {}}"#, "tracks[0].instrument.drumKit", "drumSynth"),
            (#"{"kind": "soundBank", "drumPreset": "808", "soundBank": {"source": "gm"}}"#,
             "tracks[0].instrument.drumPreset", "drumSynth"),
            (#"{"kind": "drumSynth", "cutoffHz": 400}"#, "tracks[0].instrument.cutoffHz", "polySynth"),
            (#"{"kind": "polySynth", "soundBank": {"source": "gm"}}"#,
             "tracks[0].instrument.soundBank", "soundBank"),
        ]
        for (instrument, path, needed) in cases {
            for direction in Direction.allCases {
                let tracks = "[{\"key\": \"a\", \"name\": \"A\", \"kind\": \"instrument\", \"instrument\": \(instrument)}]"
                let refusal = Self.refusal(Self.file(tracks, formatVersion: direction.formatVersion))
                #expect(refusal?.code == .invalidValue && refusal?.path == path,
                        "\(instrument) \(direction): \(String(describing: refusal))")
                #expect(refusal?.message.contains(needed) == true, "\(refusal?.message ?? "")")
            }
        }
    }

    @Test("instruments resolve from the factory values; a sampler object is read since TPL-5b")
    func instrumentsResolve() throws {
        func instrument(_ json: String) throws -> InstrumentDescriptor? {
            let tracks = "[{\"key\": \"a\", \"name\": \"A\", \"kind\": \"instrument\", \"instrument\": \(json)}]"
            return try Codec.decode(Self.file(tracks), origin: .file).template.tracks.first?.instrument
        }
        #expect(try instrument(#"{"kind": "polySynth"}"#) == InstrumentDescriptor(kind: .polySynth))
        var synth = PolySynthParams()
        synth.cutoffHz = 400
        synth.unisonVoices = 3
        synth.subWaveform = .square
        #expect(try instrument(#"{"kind": "polySynth", "cutoffHz": 400, "unisonVoices": 3, "subWaveform": "square"}"#)
                == InstrumentDescriptor(kind: .polySynth, polySynth: synth))
        #expect(try instrument(#"{"kind": "drumSynth"}"#) == InstrumentDescriptor(kind: .drumSynth))
        let lofi = try #require(DrumKitParams.preset(named: "lofi")).params
        #expect(try instrument(#"{"kind": "drumSynth", "drumPreset": "LoFi"}"#)
                == InstrumentDescriptor(kind: .drumSynth, drumKit: lofi), "case-insensitive")
        var dialled = lofi
        dialled.kick.decay = 0.9
        #expect(try instrument(#"{"kind": "drumSynth", "drumPreset": "lofi", "drumKit": {"kick": {"decay": 0.9}}}"#)
                == InstrumentDescriptor(kind: .drumSynth, drumKit: dialled), "preset first, then the kit")
        #expect(try instrument(#"{"kind": "testTone"}"#) == InstrumentDescriptor(kind: .testTone))
        #expect(try instrument(#"{"kind": "sampler"}"#) == InstrumentDescriptor(kind: .sampler))
        // m39-tpl-5b: the `sampler` object is READ (it was refused, `notSupported`,
        // until then); `TemplateSamplerCodecTests` holds the grammar.
        #expect(try instrument(#"{"kind": "sampler", "sampler": {"zones": []}}"#)
                == InstrumentDescriptor(kind: .sampler, sampler: SamplerParams()))
        let zone = try #require(try instrument(#"{"kind": "sampler", "sampler": {"zones": [{"path": "/x/a.wav", "rootPitch": 48}]}}"#)?
            .sampler?.zones.first)
        #expect(zone.rootPitch == 48 && zone.audioFileURL == URL(fileURLWithPath: "/x/a.wav"))
        #expect(TemplateReader.isSamplerZonePlaceholder(zone.id))
        let unit = try #require(try instrument(#"{"kind": "audioUnit", "audioUnit": {"subType": "abcd", "manufacturer": "wxyz", "state": "AQID"}}"#))
        #expect(unit.audioUnit?.component == AudioUnitComponentID(type: "aumu", subType: "abcd",
                                                                   manufacturer: "wxyz"))
        #expect(unit.audioUnit?.stateData == Data([1, 2, 3]))
        #expect(Self.refusal(Self.file(#"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "audioUnit", "audioUnit": {"subType": "abc", "manufacturer": "wxyz"}}}]"#))?.code
                == .invalidValue, "a three-letter code would be padded silently by the model")
        #expect(Self.refusal(Self.file("[\(Self.audio), \"inserts\": [{\"kind\": \"audioUnit\"}]}]"))?.code
                == .missingKey, "an Audio Unit insert with no plug-in would be a silent no-op")
        #expect(Self.refusal(Self.file(#"[{"key": "b", "name": "B", "kind": "bus", "instrument": {"kind": "polySynth"}}]"#))?.code
                == .invalidValue, "a bus has no instrument")
    }

    @Test("sound-bank display names are DERIVED: the General MIDI catalog, else the wire's fallback")
    func soundBankDisplayNames() throws {
        func bank(_ json: String) throws -> SoundBankConfig? {
            let tracks = "[{\"key\": \"a\", \"name\": \"A\", \"kind\": \"instrument\", \"instrument\": {\"kind\": \"soundBank\", \"soundBank\": \(json)}}]"
            return try Codec.decode(Self.file(tracks), origin: .file).template.tracks.first?
                .instrument?.soundBank
        }
        let bass = try #require(try bank(#"{"source": "gm", "program": 33}"#))
        #expect(bass.displayName == GMProgramCatalog.melodic(33).name)
        #expect(bass.bankMSB == GMProgramCatalog.melodicBankMSB && bass.bankLSB == 0)
        let kit = try #require(try bank(#"{"source": "gm", "program": 0, "bankMSB": 120}"#))
        #expect(kit.displayName == GMProgramCatalog.standardDrumKit.name)
        let file = try #require(try bank(#"{"source": "/Banks/My Bank.sf2", "program": 5}"#))
        #expect(file.displayName == "My Bank · P5")
        #expect(file.source == .file(path: "/Banks/My Bank.sf2"))
        #expect(Self.refusal(Self.file(#"[{"key": "a", "name": "A", "kind": "instrument", "instrument": {"kind": "soundBank", "soundBank": {"source": "relative.sf2"}}}]"#))?.code
                == .invalidValue)
    }

    // MARK: - Keys, names, structure

    @Test("keys: lowercase letters, digits and hyphens, unique where they must be")
    func keysAndDuplicates() throws {
        #expect(Self.refusal(Self.file(#"[{"key": "Drums", "name": "D", "kind": "audio"}]"#))?.code
                == .invalidValue)
        #expect(Self.refusal(Self.file(#"[{"key": "a", "name": "A", "kind": "audio"}, {"key": "a", "name": "B", "kind": "audio"}]"#))?.code
                == .duplicateKey)
        #expect(Self.refusal(Self.file("[\(Self.audio), \"inserts\": [{\"key\": \"x\", \"kind\": \"gain\"}, {\"key\": \"x\", \"kind\": \"eq\"}]}]"))?.code
                == .duplicateKey)
        #expect(Self.refusal(Self.file(#"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo"}, {"key": "l", "kind": "macro"}]}}]"#))?.code
                == .duplicateKey)
        let longName = String(repeating: "x", count: Codec.maxNameLength + 1)
        let tooLong = Self.refusal(Self.file("[{\"key\": \"a\", \"name\": \"\(longName)\", \"kind\": \"audio\"}]"))
        #expect(tooLong?.code == .outOfRange && tooLong?.path == "tracks[0].name")
        let shortened = try Codec.decode(Self.file(
            "[{\"key\": \"a\", \"name\": \"\(longName)\", \"kind\": \"audio\"}]", formatVersion: 2),
                                         origin: .file)
        #expect(shortened.template.tracks.first?.name.count == Codec.maxNameLength)
        let tracks = (0...Codec.trackCountRange.upperBound).map {
            "{\"key\": \"t\($0)\", \"name\": \"T\", \"kind\": \"audio\"}"
        }.joined(separator: ", ")
        #expect(Self.refusal(Self.file("[\(tracks)]"))?.code == .outOfRange, "25 tracks")
        #expect(Self.refusal(Self.file(#"[{"key": "a", "name": "  ", "kind": "audio"}]"#))?.code
                == .invalidValue, "a blank name")
    }

    @Test("the summary holds 200 characters and the template name 40 (§4.8): refused, or shortened")
    func summaryAndTemplateNameBounds() throws {
        let tracks = "[\(Self.audio)}]"
        let summary = String(repeating: "s", count: Codec.maxSummaryLength + 1)
        let fits = String(repeating: "s", count: Codec.maxSummaryLength)
        #expect(Self.refusal(Self.file(tracks, top: "\"summary\": \"\(fits)\"")) == nil,
                "control: exactly 200 characters is read")
        let refusal = Self.refusal(Self.file(tracks, top: "\"summary\": \"\(summary)\""))
        #expect(refusal?.code == .outOfRange && refusal?.path == "summary",
                "\(String(describing: refusal))")
        let lenient = try Codec.decode(
            Self.file(tracks, formatVersion: 2, top: "\"summary\": \"\(summary)\""), origin: .file)
        #expect(lenient.template.summary?.count == Codec.maxSummaryLength)
        #expect(lenient.warnings.contains { $0.code == .valueClamped && $0.path == "summary" })
        let longName = String(repeating: "n", count: Codec.maxNameLength + 1)
        let named = Self.refusal(Self.inline(tracks).tpl1ReplacingName(with: longName), .inline)
        #expect(named?.code == .outOfRange && named?.path == "name", "\(String(describing: named))")
        #expect(Codec.maxSummaryLength == 200 && Codec.maxNameLength == 40)
    }

    @Test("song styles must be skeleton genres: refused, or dropped from a newer writer")
    func genres() throws {
        let top = #""songForm": "lo-fi", "genres": ["lo-fi", "polka"]"#
        let refusal = Self.refusal(Self.file("[\(Self.audio)}]", top: top))
        #expect(refusal?.code == .unknownKind && refusal?.path == "genres[1]")
        let lenient = try Codec.decode(Self.file("[\(Self.audio)}]", formatVersion: 2, top: top),
                                       origin: .file)
        #expect(lenient.template.songForm == "lo-fi")
        #expect(lenient.template.genres == ["lo-fi"])
        #expect(lenient.warnings.contains { $0.code == .unknownGenreSkipped && $0.path == "genres[1]" })
    }

    // MARK: - Modulation

    @Test("the modulation applier's names come from its own refusal (positive control: the LFO's eight)")
    func modulationNamesProbe() {
        let lfo = TemplateReader.modulationSettingNames(for: .lfo)
        #expect(lfo.count == 8 && lfo.contains("rateHz") && lfo.contains("waveform"), "\(lfo)")
        for kind in ModulationSourceKind.allCases {
            #expect(!TemplateReader.modulationSettingNames(for: kind).isEmpty, "\(kind)")
        }
    }

    @Test("modulation sources resolve through the applier; its notes pass through")
    func modulationSourcesResolve() throws {
        let tracks = #"[{"key": "a", "name": "A", "kind": "audio", "modulation": {"sources": [{"key": "l", "kind": "lfo", "name": "Breathe", "params": {"waveform": "sine", "rateHz": 0.25, "pulseWidth": 0.3}}], "routes": [{"source": "l", "target": {"type": "volume"}, "depth": -0.2, "enabled": false}]}}]"#
        let result = try Codec.decode(Self.file(tracks), origin: .file)
        let track = try #require(result.template.tracks.first)
        let source = try #require(track.modulationSources.first)
        let expected = try ModulationSourceParams.apply(
            ["waveform": .string("sine"), "rateHz": .number(0.25), "pulseWidth": .number(0.3)],
            to: .defaults(for: .lfo)).params
        #expect(source.params == expected)
        #expect(source.name == "Breathe")
        #expect(track.modulationRoutes
                == [TemplateModRoute(source: "l", target: .volume, depth: -0.2, enabled: false)])
        #expect(result.warnings.contains { $0.code == .modulationSourceWarned },
                "pulseWidth on a sine LFO earns the applier's own note: \(result.warnings)")
    }

    // MARK: - TPL-0's noteLayout

    /// TPL-0 landed `DrumKitParams.noteLayout`; the codec reads it (flipped
    /// from `noteLayoutIsRefusedUntilTPL0`).
    @Test("drumKit.noteLayout is read: gm and pads set the layout, an unknown word is refused or skipped")
    func noteLayoutIsRead() throws {
        func kit(_ json: String, formatVersion: Int = 1) throws -> DrumKitParams? {
            let tracks = "[{\"key\": \"d\", \"name\": \"Drums\", \"kind\": \"instrument\", \"instrument\": {\"kind\": \"drumSynth\", \"drumKit\": \(json)}}]"
            return try Codec.decode(Self.file(tracks, formatVersion: formatVersion), origin: .file)
                .template.tracks.first?.instrument?.drumKit
        }
        #expect(try kit(#"{"noteLayout": "gm"}"#)?.noteLayout == .gm)
        #expect(try kit(#"{"noteLayout": "pads"}"#)?.noteLayout == .pads)
        #expect(try kit(#"{"noteLayout": "gm", "kick": {"decay": 0.9}}"#)?.kick.decay == 0.9)
        let unknown = #"[{"key": "d", "name": "Drums", "kind": "instrument", "instrument": {"kind": "drumSynth", "drumKit": {"noteLayout": "cowbell"}}}]"#
        let refusal = Self.refusal(Self.file(unknown))
        #expect(refusal?.code == .unknownSetting && refusal?.path == "tracks[0].instrument.drumKit.noteLayout")
        #expect(try kit(#"{"noteLayout": "cowbell"}"#, formatVersion: 2)?.noteLayout == .pads)
        let number = Self.refusal(Self.file(#"[{"key": "d", "name": "Drums", "kind": "instrument", "instrument": {"kind": "drumSynth", "drumKit": {"noteLayout": 1}}}]"#))
        #expect(number?.code == .wrongType)
    }

    /// The structural tripwire: the codec's reader writes exactly the fields
    /// `DrumKitParams` stores. Written for TPL-0's `noteLayoutStorage` (read
    /// through `noteLayout`); the next stored field anyone adds fails it until
    /// the reader learns that one too.
    @Test("tripwire: every stored field of DrumKitParams is one the template codec reads")
    func noteLayoutTripwire() {
        let labels = Set(Mirror(reflecting: DrumKitParams()).children.compactMap { $0.label })
        // Positive control: Mirror sees the struct's twelve stored fields today.
        #expect(labels.contains("kick") && labels.contains("accentDepth") && labels.count >= 12,
                "Mirror no longer lists DrumKitParams' fields: \(labels.sorted())")
        let unread = labels.subtracting(TemplateReader.drumKitFieldsRead).sorted()
        #expect(unread.isEmpty, """
            DrumKitParams gained stored field(s) \(unread) that the template codec does not \
            read: teach TrackSetTemplateCodecInstruments.readDrumKit to read it, add it to \
            `TemplateReader.drumKitFieldsRead`, and add its rows to the drum-kit parity table.
            """)
        // And the reverse: every name the reader claims is a real stored field.
        #expect(TemplateReader.drumKitFieldsRead.subtracting(labels).isEmpty,
                "drumKitFieldsRead names a field DrumKitParams does not store")
    }

    // MARK: - The design's own example (§4.3), read in full

    @Test("the §4.3 example decodes to what it says")
    func designExampleDecodes() throws {
        let json = #"""
        {
          "format": "dawpro.template", "formatVersion": 1, "minReaderVersion": 1,
          "id": "lofi-chill", "name": "Lo-Fi Chill",
          "summary": "Dusty drums, a warm electric piano and a round bass, in a small, worn-tape room.",
          "songForm": "lo-fi", "genres": ["lo-fi"],
          "tracks": [
            { "key": "drums", "name": "Drums", "kind": "instrument", "volume": 0.9,
              "instrument": { "kind": "drumSynth", "drumPreset": "lofi", "drumKit": { "noteLayout": "gm" } },
              "inserts": [ { "kind": "saturator", "params": { "driveDb": 4 } } ],
              "sends": [ { "bus": "room", "level": 0.2 } ] },
            { "key": "bass", "name": "Bass", "kind": "instrument", "mixerPreset": "bass-round",
              "instrument": { "kind": "soundBank", "soundBank": { "source": "gm", "program": 33 } } },
            { "key": "keys", "name": "Keys", "kind": "instrument", "output": "duck", "mixerPreset": "warm-keys",
              "instrument": { "kind": "soundBank", "soundBank": { "source": "gm", "program": 4 } },
              "inserts": [ { "key": "tone", "kind": "djFilter", "params": { "position": -0.25 } },
                           { "kind": "chorus" } ],
              "sends": [ { "bus": "room", "level": 0.3 } ],
              "modulation": {
                "sources": [ { "key": "breathe", "kind": "lfo", "params": { "waveform": "sine", "rateHz": 0.25 } } ],
                "routes": [ { "source": "breathe", "depth": 0.1,
                              "target": { "type": "effectParam", "insert": "tone", "param": "position" } } ] } },
            { "key": "vinyl", "name": "Vinyl FX", "kind": "audio", "mixerPreset": "lofi-tape" },
            { "key": "duck", "name": "Keys Duck", "kind": "bus",
              "inserts": [ { "kind": "compressor", "sidechainSource": "drums",
                             "params": { "thresholdDb": -24, "ratio": 3, "attackMs": 5, "releaseMs": 180 } } ] },
            { "key": "room", "name": "Tape Room", "kind": "bus",
              "inserts": [ { "kind": "hallReverb", "params": { "mix": 1, "sizeMeters": 12, "decaySeconds": 1.2 } } ] }
          ]
        }
        """#
        let result = try Codec.decode(Data(json.utf8), origin: .file)
        #expect(result.warnings.isEmpty, "\(result.warnings)")
        let template = result.template
        #expect(template.id == "lofi-chill" && template.name == "Lo-Fi Chill")
        #expect(template.tracks.map(\.key) == ["drums", "bass", "keys", "vinyl", "duck", "room"])
        #expect(template.tracks.map(\.kind) == [.instrument, .instrument, .instrument, .audio, .bus, .bus])
        try #require(template.tracks.count == 6)
        let drums = template.tracks[0]
        #expect(drums.volume == 0.9)
        var lofiGM = try #require(DrumKitParams.preset(named: "lofi")).params
        lofiGM.noteLayout = .gm
        #expect(drums.instrument?.drumKit == lofiGM)
        #expect(drums.sends == [TemplateSend(bus: "room", level: 0.2)])
        let keys = template.tracks[2]
        #expect(keys.output == "duck" && keys.mixerPreset == "warm-keys")
        #expect(keys.instrument?.soundBank?.program == 4)
        #expect(keys.inserts.map(\.key) == ["tone", nil])
        #expect(keys.modulationRoutes.first?.target == .effectParam(insert: "tone", param: "position"))
        let duck = template.tracks[4]
        #expect(duck.inserts.first?.sidechainSource == "drums")
        #expect(duck.inserts.first?.params == ["thresholdDb": -24, "ratio": 3, "attackMs": 5,
                                               "releaseMs": 180])
    }
}

extension Data {
    /// The inline template `{"name": "Probe", ...}` with another name.
    func tpl1ReplacingName(with name: String) -> Data {
        Data(String(decoding: self, as: UTF8.self)
            .replacingOccurrences(of: "\"name\": \"Probe\"", with: "\"name\": \"\(name)\"").utf8)
    }
}

// MARK: - The limits the codec shares with `macro.songSkeleton`

/// The codec keeps its own copies of the skeleton's roster ceiling and label
/// bound because the skeleton's live on `@MainActor ProjectStore`, which a pure
/// codec cannot read. This pins the two together, so they cannot drift.
/// ⚠️ An extension of the existing `@MainActor` suite `SongSkeletonTests`, not a
/// new suite (the `MainActorOccupancySiteTests` cap).
extension SongSkeletonTests {
    @Test("m39-tpl-1: a template's track ceiling and name bound ARE the skeleton's")
    func tpl1TemplateLimitsAreTheSkeletons() {
        #expect(TrackSetTemplateCodec.trackCountRange == ProjectStore.songSkeletonTrackCountRange)
        #expect(TrackSetTemplateCodec.maxNameLength == ProjectStore.songSkeletonSectionNameMaxLength)
    }
}
