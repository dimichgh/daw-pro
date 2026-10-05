import Foundation
import Testing
@testable import DAWCore
@testable import DAWControl

// m39-tpl-1 — where a template's instrument grammar must agree with the wire
// (docs/design/2026-09-27-multi-instrument-templates.md §5.2).
//
// A template file is decoded in DAWCore, which cannot see DAWControl, so the
// agreement with `track.setInstrument` has to be measured from HERE, the one
// test target that sees both:
//
// 1. the Poly Synth's setting names: `PolySynthParams.settingNames` (DAWCore,
//    moved from `PolySynthDescription.order`) against the keys the verb REALLY
//    accepts, read out of its own refusal — never a second hand-typed list —
//    and every name's range against `instrument.describeSynth`'s min/max;
// 2. the drum-kit object: one table of `drumKit` objects parsed by the wire's
//    `CommandRouter.parseDrumKit` AND by the template codec, with the two
//    deliberate differences (the codec refuses what the wire clamps or
//    truncates) pinned as rows rather than left to be rediscovered.
//
// ⚠️ An extension of the existing `@MainActor` suite `CommandRouterTests`, NOT a
// new suite (the `MainActorOccupancySiteTests` cap): `CommandRouter` is
// main-actor isolated. Helpers carry a `tpl1` prefix so they cannot collide
// with the suite's own (the `PolySynthRichnessWireTests` precedent).

/// What one drum-kit row expects of the two readers.
enum TPL1DrumParityExpectation: String, Sendable, CaseIterable {
    /// Both read it, to the same kit.
    case same
    /// A name neither knows: the wire refuses; the codec refuses it from a
    /// same-version file and skips it (`unknownSettingSkipped`) from a newer one.
    case unknownName
    /// A wrong JSON type: both refuse, in every version.
    case wrongType
    /// Out of range: the wire CLAMPS silently; the codec refuses it (m34-q)
    /// from a same-version file and clamps it, like the wire, from a newer one.
    case wireClampsCodecRefuses
    /// A fractional choke group: the wire TRUNCATES (`Int(2.5)` is 2); the
    /// codec refuses it as the wrong type in every version.
    case wireTruncatesCodecRefuses
}

struct TPL1DrumParityRow: Sendable, CustomStringConvertible {
    let label: String
    let json: String
    let expectation: TPL1DrumParityExpectation
    var description: String { "\(label) \(json)" }
}

enum TPL1DrumParity {
    /// The hand-written rows: the grammar's edges, TPL-0's `noteLayout` included.
    static let fixedRows: [TPL1DrumParityRow] = [
        .init(label: "empty object", json: "{}", expectation: .same),
        .init(label: "one voice setting", json: #"{"kick": {"decay": 0.9}}"#, expectation: .same),
        .init(label: "two drums and a kit setting",
              json: #"{"kick": {"decay": 0.9, "level": 0.5}, "snare": {"pan": -0.25}, "gain": 0.6}"#,
              expectation: .same),
        .init(label: "choke group set", json: #"{"closedHat": {"chokeGroup": 5}}"#, expectation: .same),
        .init(label: "choke group cleared", json: #"{"closedHat": {"chokeGroup": null}}"#,
              expectation: .same),
        .init(label: "the read-only note is ignored", json: #"{"kick": {"note": 99}}"#,
              expectation: .same),
        .init(label: "an empty drum", json: #"{"tom": {}}"#, expectation: .same),
        .init(label: "General MIDI layout", json: #"{"noteLayout": "gm"}"#, expectation: .same),
        .init(label: "pad layout", json: #"{"noteLayout": "pads", "kick": {"decay": 0.9}}"#,
              expectation: .same),
        .init(label: "an unknown layout", json: #"{"noteLayout": "cowbell"}"#, expectation: .unknownName),
        .init(label: "a number for the layout", json: #"{"noteLayout": 1}"#, expectation: .wrongType),
        .init(label: "unknown kit-wide name", json: #"{"bogus": 1}"#, expectation: .unknownName),
        .init(label: "unknown drum setting", json: #"{"kick": {"bogus": 1}}"#,
              expectation: .unknownName),
        .init(label: "a drum that is not an object", json: #"{"kick": 1}"#, expectation: .wrongType),
        .init(label: "text for a number", json: #"{"kick": {"decay": "long"}}"#,
              expectation: .wrongType),
        .init(label: "true for a number", json: #"{"kick": {"decay": true}}"#,
              expectation: .wrongType),
        .init(label: "text for a kit setting", json: #"{"gain": "loud"}"#, expectation: .wrongType),
        .init(label: "text for a choke group", json: #"{"closedHat": {"chokeGroup": "a"}}"#,
              expectation: .wrongType),
        .init(label: "an array for the kit", json: "[]", expectation: .wrongType),
        .init(label: "a setting above its range", json: #"{"kick": {"decay": 1000000}}"#,
              expectation: .wireClampsCodecRefuses),
        .init(label: "a kit setting below its range", json: #"{"gain": -5}"#,
              expectation: .wireClampsCodecRefuses),
        .init(label: "a choke group above its range", json: #"{"closedHat": {"chokeGroup": 99}}"#,
              expectation: .wireClampsCodecRefuses),
        .init(label: "a fractional choke group", json: #"{"closedHat": {"chokeGroup": 2.5}}"#,
              expectation: .wireTruncatesCodecRefuses),
    ]

    /// One row per drum parameter, generated from the ONE name table
    /// (`DrumKitParams.paramSpecs`), at an interior point of its range, so
    /// every one of the 75 names goes through both readers.
    static func everySpecRows() -> [TPL1DrumParityRow] {
        DrumKitParams.paramSpecs.map { spec in
            let value = spec.range.lowerBound
                + (spec.range.upperBound - spec.range.lowerBound) * 0.37
            let leaf = "\"\(spec.leaf.rawValue)\": \(value)"
            let json = spec.voice.map { "{\"\($0.rawValue)\": {\(leaf)}}" } ?? "{\(leaf)}"
            return .init(label: spec.name, json: json, expectation: .same)
        }
    }

    /// The codec's reading of `json` as a template track's drum kit: the kit,
    /// or the refusal, plus the warnings.
    static func codec(_ json: String, formatVersion: Int)
        -> (kit: DrumKitParams?, refusal: TemplateRefusal?, warnings: [TemplateWarning]) {
        let text = "{\"format\": \"dawpro.template\", \"formatVersion\": \(formatVersion), "
            + "\"minReaderVersion\": 1, \"id\": \"parity\", \"name\": \"Parity\", \"tracks\": "
            + "[{\"key\": \"d\", \"name\": \"Drums\", \"kind\": \"instrument\", \"instrument\": "
            + "{\"kind\": \"drumSynth\", \"drumKit\": \(json)}}]}"
        do {
            let result = try TrackSetTemplateCodec.decode(Data(text.utf8), origin: .file)
            return (result.template.tracks.first?.instrument?.drumKit, nil, result.warnings)
        } catch let refusal as TemplateRefusal {
            return (nil, refusal, [])
        } catch {
            return (nil, TemplateRefusal(code: .notJSON, path: "<unexpected>",
                                         message: "\(error)"), [])
        }
    }
}

extension CommandRouterTests {
    private func tpl1MakeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// The wire's reading: `CommandRouter.parseDrumKit` over a factory kit —
    /// the function `track.setInstrument` calls, on the base a fresh drum
    /// machine has. Returns the kit or the refusal's text.
    private func tpl1WireDrumKit(_ json: String) -> (kit: DrumKitParams?, error: String?) {
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
            return (try CommandRouter.parseDrumKit(value, base: DrumKitParams()), nil)
        } catch {
            return (nil, "\(error)")
        }
    }

    // MARK: - The Poly Synth's names (moved to `PolySynthParams.settingNames`)

    @Test("m39-tpl-1: PolySynthParams.settingNames IS the Poly Synth part of track.setInstrument's allow-list")
    func tpl1SynthSettingNamesAreTheVerbsAllowList() async throws {
        let (router, store) = tpl1MakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let refusal = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "zzNotAKey": .number(1)]))
        #expect(!refusal.ok)
        let message = try #require(refusal.error)
        let range = try #require(message.range(of: "valid keys are "),
                                 "the refusal no longer lists its valid keys: \(message)")
        let advertised = Set(message[range.upperBound...]
            .components(separatedBy: ", ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "' .")) })
        // Positive control on the parse: two keys everybody knows are there.
        #expect(advertised.contains("cutoffHz") && advertised.contains("trackId"),
                "the allow-list parse is broken: \(advertised.sorted())")

        // The keys that are not Poly Synth settings: the track, the kind switch
        // and the four wholesale configs of the OTHER instruments.
        let notSettings: Set<String> = [
            "trackId", "kind", "sampler", "audioUnit", "soundBank", "drumKit",
        ]
        let names = PolySynthParams.settingNames
        #expect(Set(names).count == names.count, "a setting name is listed twice: \(names)")
        let accepted = advertised.subtracting(notSettings)
        #expect(Set(names) == accepted, """
            PolySynthParams.settingNames and track.setInstrument disagree. Accepted but not \
            listed: \(accepted.subtracting(names).sorted()). Listed but not accepted: \
            \(Set(names).subtracting(accepted).sorted()).
            """)
        // The verb's description forwards to the one list, order included.
        #expect(PolySynthDescription.order == names)
    }

    @Test("m39-tpl-1: every Poly Synth setting's kind and range IS what instrument.describeSynth publishes")
    func tpl1SynthSettingKindsMatchDescribeSynth() async throws {
        let (router, store) = tpl1MakeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.describeSynth", params: ["trackId": .string(trackID)]))
        guard case .object(let root)? = response.result,
              case .object(let parameters)? = root["parameters"] else {
            Issue.record("describeSynth returned no parameters object: \(String(describing: response.error))")
            return
        }
        #expect(parameters.count == PolySynthParams.settingNames.count, "positive control")
        let waveforms = PolySynthParams.Waveform.allCases.map { JSONValue.string($0.rawValue) }
        for name in PolySynthParams.settingNames {
            guard case .object(let described)? = parameters[name] else {
                Issue.record("describeSynth does not describe \(name)"); continue
            }
            switch PolySynthParams.settingKind(named: name) {
            case .number(let range):
                #expect(described["min"] == .number(range.lowerBound)
                        && described["max"] == .number(range.upperBound),
                        "\(name): \(range) vs \(String(describing: described["min"]))…\(String(describing: described["max"]))")
                #expect(described["integer"] != .bool(true), "\(name) is described as whole")
            case .integer(let range):
                #expect(described["min"] == .number(Double(range.lowerBound))
                        && described["max"] == .number(Double(range.upperBound)),
                        "\(name): \(range)")
            case .waveform:
                #expect(described["values"] == .array(waveforms), "\(name)")
            case nil:
                Issue.record("\(name) is listed but has no kind")
            }
        }
        #expect(PolySynthParams.settingKind(named: "zzNotAKey") == nil)
    }

    // MARK: - The drum-kit object: one table, two readers

    @Test("m39-tpl-1: a template's drumKit reads as track.setInstrument's parseDrumKit does, bar two pinned differences")
    func tpl1DrumKitParityWithTheWire() throws {
        let rows = TPL1DrumParity.fixedRows + TPL1DrumParity.everySpecRows()
        // Positive control on the generated rows: every name in the one table.
        #expect(TPL1DrumParity.everySpecRows().count == DrumKitParams.paramSpecs.count
                && DrumKitParams.paramSpecs.count >= 75)
        var tally: [TPL1DrumParityExpectation: Int] = [:]
        for row in rows {
            tally[row.expectation, default: 0] += 1
            let wire = tpl1WireDrumKit(row.json)
            let strict = TPL1DrumParity.codec(row.json, formatVersion: 1)
            let newer = TPL1DrumParity.codec(row.json, formatVersion: 2)
            switch row.expectation {
            case .same:
                #expect(wire.kit != nil && strict.kit == wire.kit && newer.kit == wire.kit,
                        "\(row): wire \(String(describing: wire.error)), codec \(String(describing: strict.refusal))")
                #expect(strict.warnings.isEmpty && newer.warnings.isEmpty, "\(row)")
            case .unknownName:
                #expect(wire.kit == nil, "\(row): the wire must refuse")
                #expect(strict.refusal?.code == .unknownSetting, "\(row): \(String(describing: strict.refusal))")
                #expect(newer.kit == DrumKitParams()
                        && newer.warnings.contains { $0.code == .unknownSettingSkipped },
                        "\(row): a newer file skips the name: \(newer.warnings)")
            case .wrongType:
                #expect(wire.kit == nil, "\(row): the wire must refuse")
                #expect(strict.refusal?.code == .wrongType && newer.refusal?.code == .wrongType,
                        "\(row): \(String(describing: strict.refusal)) / \(String(describing: newer.refusal))")
            case .wireClampsCodecRefuses:
                #expect(wire.kit != nil && wire.kit != DrumKitParams(),
                        "\(row): the wire clamps and keeps the edge value")
                #expect(strict.refusal?.code == .outOfRange, "\(row): \(String(describing: strict.refusal))")
                #expect(newer.kit == wire.kit
                        && newer.warnings.contains { $0.code == .valueClamped },
                        "\(row): a newer file clamps exactly as the wire does")
            case .wireTruncatesCodecRefuses:
                #expect(wire.kit?.closedHat.chokeGroup == 2, "\(row): the wire truncates 2.5 to 2")
                #expect(strict.refusal?.code == .wrongType && newer.refusal?.code == .wrongType,
                        "\(row): the codec refuses a fraction in every version")
            }
        }
        let counts = TPL1DrumParityExpectation.allCases
            .map { "\($0.rawValue): \(tally[$0] ?? 0)" }.joined(separator: ", ")
        print("TPL1-MEASURE drum parity rows: \(rows.count) — \(counts)")
    }
}
