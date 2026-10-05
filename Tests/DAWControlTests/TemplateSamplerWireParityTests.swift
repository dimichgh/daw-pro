import Foundation
import Testing
@testable import DAWCore
@testable import DAWControl

// m39-tpl-5b — a template's `sampler` object reads as `track.setInstrument`'s does
// (docs/design/2026-09-27-multi-instrument-templates.md §4.5: "the same `sampler`
// object `track.setInstrument` takes"; the TPL-1 drum-kit parity pattern).
//
// The wire's reader, `CommandRouter.parseSampler`, is PRIVATE, so its side of every
// row goes through the verb itself: `track.setInstrument {kind: "sampler", sampler}`
// on a FRESH instrument track (the base a template's new track has), with
// `FakeMedia` and zone files that really exist (generated in a temp folder; the
// store checks each file is there before the edit). The codec's side is
// `TrackSetTemplateCodec.decode` of a one-track FILE, read strictly (formatVersion
// 1) and as a newer writer's (formatVersion 2).
//
// Every deliberate difference is a ROW, never left to be rediscovered:
//  · the wire CLAMPS, SWAPS, RAISES or DROPS a value silently; the codec refuses it
//    from a same-version file and, from a newer one, stores exactly what the wire
//    stores, saying so (`wireAlters`);
//  · the wire IGNORES a key it does not know; the codec refuses it, or skips it from
//    a newer file (`unknownKey`) — the D2 lesson, §4.7;
//  · a zone `id`, `zonePatches` and a RELATIVE path mean something only on a track
//    that already exists (or in the app's working folder): the wire takes them, a
//    template refuses them in every version (`templateCannotMean`).
//
// ⚠️ An extension of the existing `@MainActor` suite `CommandRouterTests`, NOT a new
// suite (the `MainActorOccupancySiteTests` cap, 393 of 394). Helpers carry a
// `tpl5b` prefix.

/// What one row expects of the two readers.
enum TPL5BSamplerParityExpectation: String, Sendable, CaseIterable {
    /// Both read it, to the same Sampler; no warning in either version.
    case same
    /// A wrong JSON type: both refuse, in every version.
    case wrongType
    /// A mode the wire does not know: the wire refuses; the codec refuses it from a
    /// same-version file and skips it (`unknownSettingSkipped`) from a newer one.
    case unknownName
    /// A key the wire IGNORES: the codec refuses it (strict) or skips it
    /// (`unknownKeySkipped`), and then reads exactly what the wire stored.
    case unknownKey
    /// Out of a range the wire also REFUSES: the codec refuses it from a
    /// same-version file and clamps it (`valueClamped`) from a newer one.
    case outOfRange
    /// The wire stores something other than what was written, silently (a clamp,
    /// a swapped span, a raised end, a dropped crossfade); the codec refuses it
    /// (strict) and, from a newer file, stores exactly what the wire stores, with
    /// `valueClamped`/`valueChanged`.
    case wireAlters
    /// Both refuse, in every version (a missing path, an unknown bundled sample,
    /// `zonePatches` that name no zone or come with `zones`).
    case refusedEverywhere
    /// The wire accepts it; a template cannot mean it, so the codec refuses it in
    /// every version (a zone id, `zonePatches: []`, a relative path).
    case templateCannotMean
}

struct TPL5BSamplerParityRow: Sendable, CustomStringConvertible {
    let label: String
    /// `$A` and `$B` are replaced by two real files' absolute paths, `$REL` by a
    /// RELATIVE path to the first one.
    let json: String
    let expectation: TPL5BSamplerParityExpectation
    /// The strict refusal's code, where the category allows more than one.
    var code: TemplateRefusal.Code?
    var description: String { "\(label) \(json)" }
}

enum TPL5BSamplerParity {
    typealias Row = TPL5BSamplerParityRow

    /// A valid example for EVERY zone key but `path` (a test pins the key set).
    static let zoneExamples: [String: String] = [
        "rootPitch": "48", "minPitch": "12", "maxPitch": "100", "gain": "1.75",
        "minVelocity": "5", "maxVelocity": "120", "group": "3", "seqLength": "4",
        "seqPosition": "1", "randMin": "0.1", "randMax": "0.9", "tuneCents": "-1200",
        "pan": "-0.5", "ampVelTrack": "0", "oneShot": "true", "startFrame": "10",
        "endFrame": "500", "attack": "1", "decay": "8", "sustain": "0", "release": "0.001",
        "loopMode": "\"sustain\"", "loopStart": "5", "loopEnd": "900",
        "crossfade": #"{"controller": 11, "ccInLo": 20}"#, "reverse": "true", "chokeGroup": "0",
    ]

    /// A valid example for EVERY global key but `zones`.
    static let globalExamples: [String: String] = [
        "oneShot": "true", "attack": "0.25", "release": "3", "gain": "1",
        "expressionModDepth": "0.75", "expressionFilterDepth": "0.5", "expressionFilterCC": "1",
        "bendRangeSemitones": "0", "voiceMode": "\"mono\"", "decay": "0.5", "sustain": "0.5",
        "pedalHoldLimit": "1", "glideTime": "0.5", "glideMode": "\"constantTime\"",
    ]

    static let everyZoneField = #"{"path": "$A", "rootPitch": 48, "minPitch": 36, "maxPitch": 72, "gain": 1.5, "minVelocity": 10, "maxVelocity": 100, "group": 2, "seqLength": 3, "seqPosition": 2, "randMin": 0.25, "randMax": 0.75, "tuneCents": -35.5, "pan": 0, "ampVelTrack": 0.6, "oneShot": true, "startFrame": 100, "endFrame": 40000, "attack": 0.02, "decay": 0.3, "sustain": 0.7, "release": 0.9, "loopMode": "continuous", "loopStart": 2000, "loopEnd": 30000, "crossfade": {"controller": 1, "ccInLo": 0, "ccInHi": 40, "ccOutLo": 80, "ccOutHi": 127, "velInLo": 1, "velInHi": 30, "velOutLo": 90, "velOutHi": 126}, "reverse": false, "chokeGroup": 63}"#

    static func zone(_ fields: String) -> String { #"{"zones": [{"path": "$A", "# + fields + "}]}" }

    static let fixedRows: [Row] = [
        // Both read it.
        .init(label: "empty object", json: "{}", expectation: .same),
        .init(label: "no zones", json: #"{"zones": []}"#, expectation: .same),
        .init(label: "a zone with only its file", json: #"{"zones": [{"path": "$A"}]}"#, expectation: .same),
        .init(label: "a zone with every field", json: #"{"zones": ["# + everyZoneField + "]}",
              expectation: .same),
        .init(label: "two zones, two files",
              json: #"{"zones": [{"path": "$A", "maxPitch": 59}, {"path": "$B", "minPitch": 60, "rootPitch": 72}]}"#,
              expectation: .same),
        .init(label: "every global",
              json: #"{"oneShot": true, "attack": 0.5, "release": 2, "gain": 0.3, "expressionModDepth": 0.5, "expressionFilterDepth": 1, "expressionFilterCC": 2, "bendRangeSemitones": 48, "voiceMode": "legato", "decay": 8, "sustain": 0, "pedalHoldLimit": 128, "glideTime": 4, "glideMode": "constantRate"}"#,
              expectation: .same),
        .init(label: "range floors", json: #"{"attack": 0, "release": 0.001, "gain": 0, "glideTime": 0, "pedalHoldLimit": 1}"#,
              expectation: .same),
        .init(label: "modes in any case", json: #"{"voiceMode": "MONO", "glideMode": "CONSTANTRATE"}"#,
              expectation: .same),
        .init(label: "null modes mean not set", json: #"{"voiceMode": null, "glideMode": null}"#,
              expectation: .same),
        .init(label: "a bundled sample", json: #"{"zones": [{"path": "builtin:test-tone-a4", "rootPitch": 69}]}"#,
              expectation: .same),
        .init(label: "an empty crossfade is none", json: zone(#""crossfade": {}"#), expectation: .same),
        .init(label: "a whole number written with a point", json: zone(#""rootPitch": 60.0"#),
              expectation: .same),
        .init(label: "an explicit pan 0 (the -3 dB centre)", json: zone(#""pan": 0"#), expectation: .same),
        // Wrong JSON types.
        .init(label: "a list for the sampler", json: "[]", expectation: .wrongType),
        .init(label: "an object for zones", json: #"{"zones": {}}"#, expectation: .wrongType),
        .init(label: "a number for a zone", json: #"{"zones": [1]}"#, expectation: .wrongType),
        .init(label: "a number for a path", json: #"{"zones": [{"path": 5}]}"#, expectation: .wrongType),
        .init(label: "text for a root note", json: zone(#""rootPitch": "C4""#), expectation: .wrongType),
        .init(label: "a fractional root note", json: zone(#""rootPitch": 60.5"#), expectation: .wrongType),
        .init(label: "a number for a switch", json: zone(#""oneShot": 1"#), expectation: .wrongType),
        .init(label: "null for a gain", json: zone(#""gain": null"#), expectation: .wrongType),
        .init(label: "a number for a crossfade", json: zone(#""crossfade": 3"#), expectation: .wrongType),
        .init(label: "a number for a loop mode", json: zone(#""loopMode": 1"#), expectation: .wrongType),
        .init(label: "text for the sampler's switch", json: #"{"oneShot": "yes"}"#, expectation: .wrongType),
        .init(label: "true for a number", json: #"{"attack": true}"#, expectation: .wrongType),
        .init(label: "a number for a voice mode", json: #"{"voiceMode": 3}"#, expectation: .wrongType),
        .init(label: "a fractional hold limit", json: #"{"pedalHoldLimit": 2.5}"#, expectation: .wrongType),
        .init(label: "a fractional crossfade bound", json: zone(#""crossfade": {"controller": 1.5}"#),
              expectation: .wrongType),
        // Names the wire does not know.
        .init(label: "an unknown voice mode", json: #"{"voiceMode": "drone"}"#, expectation: .unknownName),
        .init(label: "an unknown glide mode", json: #"{"glideMode": "fast"}"#, expectation: .unknownName),
        .init(label: "a loop mode in the wrong case", json: zone(#""loopMode": "Sustain""#),
              expectation: .unknownName),
        // Keys the wire ignores.
        .init(label: "the provenance echo sourcePath", json: #"{"sourcePath": "/x/kit.sfz"}"#,
              expectation: .unknownKey),
        .init(label: "the provenance echo name", json: #"{"name": "Kit"}"#, expectation: .unknownKey),
        .init(label: "an unknown sampler key", json: #"{"bogus": 1}"#, expectation: .unknownKey),
        .init(label: "an unknown zone key", json: zone(#""warmth": 3"#), expectation: .unknownKey),
        .init(label: "an unknown crossfade key", json: zone(#""crossfade": {"controller": 1, "ccInLo": 5, "curve": "power"}"#),
              expectation: .unknownKey),
        // Out of a range the wire refuses too.
        .init(label: "a bend range above 48", json: #"{"bendRangeSemitones": 60}"#, expectation: .outOfRange),
        .init(label: "a global decay above 8", json: #"{"decay": 9}"#, expectation: .outOfRange),
        .init(label: "a global sustain above 1", json: #"{"sustain": 1.5}"#, expectation: .outOfRange),
        .init(label: "a hold limit of 0", json: #"{"pedalHoldLimit": 0}"#, expectation: .outOfRange),
        .init(label: "a glide above 4 s", json: #"{"glideTime": 5}"#, expectation: .outOfRange),
        // The wire stores something else, silently.
        .init(label: "an attack above 1", json: #"{"attack": 2}"#, expectation: .wireAlters, code: .outOfRange),
        .init(label: "a release of 0", json: #"{"release": 0}"#, expectation: .wireAlters, code: .outOfRange),
        .init(label: "a gain above 1", json: #"{"gain": 1.5}"#, expectation: .wireAlters, code: .outOfRange),
        .init(label: "a negative mod depth", json: #"{"expressionModDepth": -1}"#, expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a controller above 127", json: #"{"expressionFilterCC": 200}"#, expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a root note above 127", json: zone(#""rootPitch": 200"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a negative low note", json: zone(#""minPitch": -5"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a zone gain above 2", json: zone(#""gain": 3"#), expectation: .wireAlters, code: .outOfRange),
        .init(label: "a velocity above 127", json: zone(#""minVelocity": 130"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a negative group", json: zone(#""group": -1"#), expectation: .wireAlters, code: .outOfRange),
        .init(label: "a round robin of 0", json: zone(#""seqLength": 0"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a retune past 4 octaves", json: zone(#""tuneCents": 5000"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a pan past hard right", json: zone(#""pan": 2"#), expectation: .wireAlters, code: .outOfRange),
        .init(label: "a velocity depth above 1", json: zone(#""ampVelTrack": 1.5"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a negative start frame", json: zone(#""startFrame": -10"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a zone attack above 1", json: zone(#""attack": 2"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a zone decay above 8", json: zone(#""decay": 9"#), expectation: .wireAlters, code: .outOfRange),
        .init(label: "a zone sustain above 1", json: zone(#""sustain": 2"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a zone release above 8", json: zone(#""release": 10"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a choke group above 63", json: zone(#""chokeGroup": 64"#), expectation: .wireAlters,
              code: .outOfRange),
        .init(label: "a crossfade controller above 127", json: zone(#""crossfade": {"controller": 200}"#),
              expectation: .wireAlters, code: .outOfRange),
        .init(label: "a key span written upside down", json: zone(#""minPitch": 70, "maxPitch": 60"#),
              expectation: .wireAlters, code: .readBack),
        .init(label: "a velocity span written upside down", json: zone(#""minVelocity": 100, "maxVelocity": 10"#),
              expectation: .wireAlters, code: .readBack),
        .init(label: "a random span written upside down", json: zone(#""randMin": 0.8, "randMax": 0.2"#),
              expectation: .wireAlters, code: .readBack),
        .init(label: "an end before its start", json: zone(#""startFrame": 500, "endFrame": 100"#),
              expectation: .wireAlters, code: .readBack),
        .init(label: "a loop end on its start", json: zone(#""loopStart": 900, "loopEnd": 900"#),
              expectation: .wireAlters, code: .readBack),
        .init(label: "a round-robin position past its length", json: zone(#""seqLength": 2, "seqPosition": 5"#),
              expectation: .wireAlters, code: .readBack),
        .init(label: "a crossfade that can never change a gain", json: zone(#""crossfade": {"ccInLo": 10}"#),
              expectation: .wireAlters, code: .readBack),
        // Both refuse, in every version.
        .init(label: "a zone with no file", json: #"{"zones": [{"rootPitch": 60}]}"#,
              expectation: .refusedEverywhere, code: .missingKey),
        .init(label: "an unknown bundled sample", json: #"{"zones": [{"path": "builtin:nope"}]}"#,
              expectation: .refusedEverywhere, code: .invalidValue),
        .init(label: "zones AND zonePatches", json: #"{"zones": [], "zonePatches": []}"#,
              expectation: .refusedEverywhere, code: .invalidValue),
        .init(label: "a patch naming no zone",
              json: #"{"zonePatches": [{"id": "7E3D5A11-0000-4000-8000-0000000000AA", "gain": 0.5}]}"#,
              expectation: .refusedEverywhere, code: .invalidValue),
        // A template cannot mean these.
        .init(label: "a zone id", json: #"{"zones": [{"path": "$A", "id": "6F1A2B3C-0000-4000-8000-000000000001"}]}"#,
              expectation: .templateCannotMean),
        .init(label: "an empty zonePatches", json: #"{"zonePatches": []}"#, expectation: .templateCannotMean),
        .init(label: "a relative path", json: #"{"zones": [{"path": "$REL"}]}"#, expectation: .templateCannotMean),
    ]

    /// One `.same` row per key, generated from the example tables, so every
    /// field goes through both readers on its own.
    static func everyKeyRows() -> [Row] {
        zoneExamples.keys.sorted().map { key in
            Row(label: "zone \(key)", json: zone("\"\(key)\": \(zoneExamples[key]!)"), expectation: .same)
        } + globalExamples.keys.sorted().map { key in
            Row(label: "global \(key)", json: "{\"\(key)\": \(globalExamples[key]!)}", expectation: .same)
        }
    }

    /// The codec's reading of `json` as a template track's `sampler`.
    static func codec(_ json: String, formatVersion: Int)
        -> (sampler: SamplerParams?, refusal: TemplateRefusal?, warnings: [TemplateWarning]) {
        let text = "{\"format\": \"dawpro.template\", \"formatVersion\": \(formatVersion), "
            + "\"minReaderVersion\": 1, \"id\": \"parity\", \"name\": \"Parity\", \"tracks\": "
            + "[{\"key\": \"s\", \"name\": \"Sampler\", \"kind\": \"instrument\", \"instrument\": "
            + "{\"kind\": \"sampler\", \"sampler\": \(json)}}]}"
        do {
            let result = try TrackSetTemplateCodec.decode(Data(text.utf8), origin: .file)
            return (result.template.tracks.first?.instrument?.sampler ?? SamplerParams(), nil,
                    result.warnings)
        } catch let refusal as TemplateRefusal {
            return (nil, refusal, [])
        } catch {
            return (nil, TemplateRefusal(code: .notJSON, path: "<unexpected>", message: "\(error)"), [])
        }
    }

    /// A Sampler's reading, INDEPENDENT of the code under test: every global by
    /// `Mirror` (zones aside), then each zone's fields by `Mirror` with its id left
    /// out and its file read as a path.
    static func reading(_ sampler: SamplerParams?) -> [String]? {
        guard let sampler else { return nil }
        var lines = Mirror(reflecting: sampler).children.compactMap { child -> String? in
            guard let label = child.label, label != "zones" else { return nil }
            return "\(label)=\(child.value)"
        }
        for (index, zone) in sampler.zones.enumerated() {
            for child in Mirror(reflecting: zone).children {
                guard let label = child.label, label != "id" else { continue }
                lines.append(label == "audioFileURL"
                             ? "zone\(index).file=\(zone.audioFileURL.path)"
                             : "zone\(index).\(label)=\(child.value)")
            }
        }
        return lines
    }
}

extension CommandRouterTests {
    /// Two generated WAVs in a fresh temp folder (never the user's files).
    private func tpl5bFixtureFiles() throws -> (a: String, b: String) {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("tpl5b-parity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var paths: [String] = []
        for name in ["kick", "snare"] {
            var wav = Data("RIFF".utf8)
            withUnsafeBytes(of: UInt32(36 + 200).littleEndian) { wav.append(contentsOf: $0) }
            wav.append(contentsOf: Array("WAVEfmt ".utf8))
            for value in [UInt32(16)] { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
            for value in [UInt16(1), UInt16(1)] { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
            for value in [UInt32(44_100), UInt32(88_200)] {
                withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
            }
            for value in [UInt16(2), UInt16(16)] { withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) } }
            wav.append(contentsOf: Array("data".utf8))
            withUnsafeBytes(of: UInt32(200).littleEndian) { wav.append(contentsOf: $0) }
            wav.append(Data(count: 200))
            let url = folder.appendingPathComponent("\(name).wav")
            try wav.write(to: url)
            paths.append(url.path)
        }
        return (paths[0], paths[1])
    }

    /// The wire's reading: `track.setInstrument {kind: "sampler", sampler}` on a
    /// FRESH instrument track — the verb that calls the private `parseSampler`.
    private func tpl5bWireSampler(_ json: String) async -> (sampler: SamplerParams?, error: String?) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let router = CommandRouter(store: store)
        let track = store.addTrack(kind: .instrument)
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        } catch {
            return (nil, "not JSON: \(error)")
        }
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(track.id.uuidString), "kind": .string("sampler"),
                     "sampler": value]))
        guard response.ok else { return (nil, response.error ?? "refused") }
        return (store.tracks.first { $0.id == track.id }?.instrument?.sampler ?? SamplerParams(), nil)
    }

    @Test("m39-tpl-5b: a template's Sampler reads as track.setInstrument's parseSampler does, every difference a pinned row")
    func tpl5bSamplerParityWithTheWire() async throws {
        // Positive controls on the generated rows: every key has an example.
        #expect(Set(TPL5BSamplerParity.zoneExamples.keys)
                == Set(TemplateReader.samplerZoneKeys).subtracting(["path"]))
        #expect(Set(TPL5BSamplerParity.globalExamples.keys)
                == Set(TemplateReader.samplerKeys).subtracting(["zones"]))
        let files = try tpl5bFixtureFiles()
        let relative = String(repeating: "../", count: 64) + files.a.dropFirst()
        let rows = TPL5BSamplerParity.fixedRows + TPL5BSamplerParity.everyKeyRows()
        var tally: [TPL5BSamplerParityExpectation: Int] = [:]
        for row in rows {
            tally[row.expectation, default: 0] += 1
            let json = row.json.replacingOccurrences(of: "$A", with: files.a)
                .replacingOccurrences(of: "$B", with: files.b)
                .replacingOccurrences(of: "$REL", with: relative)
            let wire = await tpl5bWireSampler(json)
            let strict = TPL5BSamplerParity.codec(json, formatVersion: 1)
            let newer = TPL5BSamplerParity.codec(json, formatVersion: 2)
            let wireReading = TPL5BSamplerParity.reading(wire.sampler)
            switch row.expectation {
            case .same:
                #expect(wireReading != nil && TPL5BSamplerParity.reading(strict.sampler) == wireReading
                        && TPL5BSamplerParity.reading(newer.sampler) == wireReading,
                        "\(row): wire \(String(describing: wire.error)), codec \(String(describing: strict.refusal))")
                #expect(strict.warnings.isEmpty && newer.warnings.isEmpty, "\(row): \(strict.warnings)")
            case .wrongType:
                #expect(wire.sampler == nil, "\(row): the wire must refuse")
                #expect(strict.refusal?.code == .wrongType && newer.refusal?.code == .wrongType,
                        "\(row): \(String(describing: strict.refusal)) / \(String(describing: newer.refusal))")
            case .unknownName:
                #expect(wire.sampler == nil, "\(row): the wire must refuse")
                #expect(strict.refusal?.code == .unknownSetting, "\(row): \(String(describing: strict.refusal))")
                #expect(newer.sampler != nil
                        && newer.warnings.contains { $0.code == .unknownSettingSkipped },
                        "\(row): a newer file skips the name: \(newer.warnings)")
            case .unknownKey:
                #expect(wireReading != nil, "\(row): the wire ignores the key: \(String(describing: wire.error))")
                #expect(strict.refusal?.code == .unknownKey, "\(row): \(String(describing: strict.refusal))")
                #expect(TPL5BSamplerParity.reading(newer.sampler) == wireReading
                        && newer.warnings.contains { $0.code == .unknownKeySkipped },
                        "\(row): a newer file skips the key and reads what the wire stored: \(newer.warnings)")
            case .outOfRange:
                #expect(wire.sampler == nil, "\(row): the wire refuses this range too")
                #expect(strict.refusal?.code == .outOfRange, "\(row): \(String(describing: strict.refusal))")
                #expect(newer.sampler != nil && newer.warnings.contains { $0.code == .valueClamped },
                        "\(row): a newer file clamps (its range may be wider): \(newer.warnings)")
            case .wireAlters:
                #expect(wireReading != nil, "\(row): the wire stores it: \(String(describing: wire.error))")
                #expect(strict.refusal?.code == row.code, "\(row): \(String(describing: strict.refusal))")
                #expect(TPL5BSamplerParity.reading(newer.sampler) == wireReading,
                        "\(row): a newer file stores exactly what the wire stores")
                #expect(!newer.warnings.isEmpty && newer.warnings.allSatisfy {
                    $0.code == .valueClamped || $0.code == .valueChanged
                }, "\(row): \(newer.warnings)")
            case .refusedEverywhere:
                #expect(wire.sampler == nil, "\(row): the wire must refuse")
                #expect(strict.refusal?.code == row.code && newer.refusal?.code == row.code,
                        "\(row): \(String(describing: strict.refusal)) / \(String(describing: newer.refusal))")
            case .templateCannotMean:
                #expect(wireReading != nil, "\(row): the wire takes it: \(String(describing: wire.error))")
                #expect(strict.refusal?.code == .invalidValue && newer.refusal?.code == .invalidValue,
                        "\(row): \(String(describing: strict.refusal)) / \(String(describing: newer.refusal))")
            }
        }
        let counts = TPL5BSamplerParityExpectation.allCases
            .map { "\($0.rawValue): \(tally[$0] ?? 0)" }.joined(separator: ", ")
        print("TPL5B-MEASURE sampler parity rows: \(rows.count) — \(counts)")
    }
}
