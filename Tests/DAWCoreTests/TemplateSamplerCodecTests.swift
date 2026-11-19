import Foundation
import Testing
@testable import DAWCore

// m39-tpl-5b — the template codec's Sampler: its key lists against the model, the
// ONE re-identify helper, the reader and the writer, zone identity, and §4.7
// (docs/design/2026-09-27-multi-instrument-templates.md §2.2, §4.5, §4.7, §7.2).
// NO `@MainActor`: the codec, capture and the builder are pure. Agreement with the
// wire's `parseSampler`, row by row, is `CommandRouterTests.tpl5bSamplerParityWithTheWire`
// (DAWControlTests: the one test target that sees both).

@Suite("m39-tpl-5b: the template codec's Sampler — keys, identity, reader, writer, versions")
struct TemplateSamplerCodecTests {
    // MARK: - Fixtures

    /// A zone with EVERY field set to something that is not its default
    /// (`unsetFields` proves it, by `Mirror`).
    static func fullZone(id: UUID = UUID(), path: String = "/tpl5b/full kick.wav") -> SamplerZone {
        SamplerZone(
            id: id, audioFileURL: URL(fileURLWithPath: path), rootPitch: 48, minPitch: 36,
            maxPitch: 72, gain: 1.25, minVelocity: 10, maxVelocity: 100, group: 2, seqLength: 3,
            seqPosition: 2, randMin: 0.25, randMax: 0.75, tuneCents: -35.5, pan: 0.4,
            ampVelTrack: 0.6, oneShot: true, startFrame: 100, endFrame: 40_000, attack: 0.02,
            decay: 0.3, sustain: 0.7, release: 0.9, loopMode: .sustain, loopStart: 2_000,
            loopEnd: 30_000,
            crossfade: SamplerCrossfade(controller: 1, ccInLo: 0, ccInHi: 40, ccOutLo: 80,
                                        ccOutHi: 127, velInLo: 1, velInHi: 30, velOutLo: 90,
                                        velOutHi: 126),
            reverse: true, chokeGroup: 7, drumRole: .snare)
    }

    /// A Sampler with every global set away from `SamplerParams()`, two full
    /// zones, AND the provenance trio a template must drop.
    static func fullSampler() -> SamplerParams {
        var sampler = SamplerParams(
            zones: [fullZone(), fullZone(path: "/tpl5b/full snare.wav")], oneShot: true,
            attack: 0.05, release: 1.5, gain: 0.6, sourcePath: "/tpl5b/kit.sfz", displayName: "Kit",
            expressionModDepth: 0.5, expressionFilterDepth: 0.25, expressionFilterCC: 2,
            bendRangeSemitones: 12, voiceMode: .legato, decay: 1.2, sustain: 0.4,
            pedalHoldLimit: 8, glideTime: 0.12, glideMode: .constantRate)
        sampler.markSliceKit()
        return sampler
    }

    /// The labels of `value`'s optional stored properties that are nil.
    static func unsetFields(_ value: Any) -> [String] {
        Mirror(reflecting: value).children.compactMap { child -> String? in
            let inner = Mirror(reflecting: child.value)
            return inner.displayStyle == .optional && inner.children.isEmpty ? child.label : nil
        }
    }

    static func labels(_ value: Any) -> Set<String> {
        Set(Mirror(reflecting: value).children.compactMap { $0.label })
    }

    /// A one-track template FILE whose instrument is `{"kind": "sampler", "sampler": <sampler>}`.
    static func file(_ sampler: String, formatVersion: Int = 1, minReaderVersion: Int = 1) -> Data {
        Data(("{\"format\": \"dawpro.template\", \"formatVersion\": \(formatVersion), "
            + "\"minReaderVersion\": \(minReaderVersion), \"id\": \"smp\", \"name\": \"Sampler\", "
            + "\"tracks\": [{\"key\": \"kit\", \"name\": \"Kit\", \"kind\": \"instrument\", "
            + "\"instrument\": {\"kind\": \"sampler\", \"sampler\": \(sampler)}}]}").utf8)
    }

    struct Outcome {
        var sampler: SamplerParams?
        var refusal: TemplateRefusal?
        var warnings: [TemplateWarning] = []
    }

    static func read(_ sampler: String, formatVersion: Int = 1) -> Outcome {
        do {
            let result = try TrackSetTemplateCodec.decode(file(sampler, formatVersion: formatVersion),
                                                          origin: .file)
            return Outcome(sampler: result.template.tracks.first?.instrument?.sampler,
                           warnings: result.warnings)
        } catch let refusal as TemplateRefusal {
            return Outcome(refusal: refusal)
        } catch {
            return Outcome(refusal: TemplateRefusal(code: .notJSON, path: "?", message: "\(error)"))
        }
    }

    static func zone(_ fields: String, formatVersion: Int = 1) -> Outcome {
        read(#"{"zones": [{"path": "/x/a.wav", "# + fields + "}]}", formatVersion: formatVersion)
    }

    // MARK: - The key lists ARE the model's fields

    @Test("The key lists are the model's stored properties: every Sampler field, every zone field (path for its file), every crossfade field")
    func keyListsAreTheModelsFields() {
        let params = Self.labels(SamplerParams())
        #expect(params.contains("zones") && params.contains("glideMode"), "positive control: Mirror reads labels")
        #expect(Set(TemplateReader.samplerKeys)
                == params.subtracting(["sourcePath", "displayName", "sliceKit"]),
                "a SamplerParams field the template codec does not read or write")
        #expect(TemplateReader.samplerKeys.count == Set(TemplateReader.samplerKeys).count)
        let zone = Self.labels(Self.fullZone())
        #expect(Set(TemplateReader.samplerZoneKeys)
                == zone.subtracting(["id", "audioFileURL"]).union(["path"]),
                "a SamplerZone field the template codec does not read or write")
        #expect(TemplateReader.samplerZoneKeys.count == Set(TemplateReader.samplerZoneKeys).count)
        #expect(Set(TemplateReader.samplerCrossfadeKeys) == Self.labels(SamplerCrossfade()))
    }

    @Test("The fixtures set EVERY field (by Mirror), so the tests below cannot pass by leaving one out")
    func fixturesSetEveryField() throws {
        #expect(Self.unsetFields(Self.fullZone()).isEmpty, "\(Self.unsetFields(Self.fullZone()))")
        #expect(Self.unsetFields(try #require(Self.fullZone().crossfade)).isEmpty)
        #expect(Self.unsetFields(Self.fullSampler()).isEmpty, "\(Self.unsetFields(Self.fullSampler()))")
        // Positive control: an unset field IS seen.
        #expect(Self.unsetFields(SamplerZone(audioFileURL: URL(fileURLWithPath: "/x"))).contains("pan"))
    }

    // MARK: - Zone identity

    @Test("The re-identify helper copies every field but the id; placeholders are deterministic and recognisable")
    func reidentifyCopiesEveryField() {
        let source = Self.fullZone()
        let newID = UUID()
        let copy = TemplateReader.samplerZone(source, id: newID)
        #expect(copy.id == newID)
        #expect(TemplateReader.samplerZone(copy, id: source.id) == source, "a field was not copied")
        let moved = TemplateReader.samplerZone(source, id: source.id,
                                               audioFileURL: URL(fileURLWithPath: "/elsewhere.wav"))
        #expect(moved.audioFileURL.path == "/elsewhere.wav" && moved.rootPitch == source.rootPitch)
        // Placeholders.
        #expect(TemplateReader.samplerZoneID(0) == TemplateReader.samplerZoneID(0))
        #expect(TemplateReader.samplerZoneID(0) != TemplateReader.samplerZoneID(1))
        #expect((0..<300).allSatisfy { TemplateReader.isSamplerZonePlaceholder(TemplateReader.samplerZoneID($0)) })
        #expect(Set((0..<300).map { TemplateReader.samplerZoneID($0) }).count == 300)
        #expect(!TemplateReader.isSamplerZonePlaceholder(UUID()), "positive control")
    }

    @Test("Decoding gives each zone its placeholder id, the same bytes the same value every time")
    func decodingIsDeterministic() throws {
        let json = #"{"zones": [{"path": "/x/a.wav"}, {"path": "/x/b.wav"}, {"path": "/x/a.wav", "minPitch": 70}]}"#
        let first = try #require(Self.read(json).sampler)
        let second = try #require(Self.read(json).sampler)
        #expect(first == second)
        #expect(first.zones.map { $0.id } == (0..<3).map { TemplateReader.samplerZoneID($0) })
    }

    // MARK: - Writer + reader: every field travels

    @Test("Every Sampler and zone field is WRITTEN (the writer's keys are the full lists) and READ back exactly; provenance is never written")
    func everyFieldTravels() throws {
        let sampler = Self.fullSampler()
        guard case .object(let written) = TemplateReader.samplerObject(sampler) else {
            Issue.record("the writer did not write an object"); return
        }
        #expect(Set(written.keys) == Set(TemplateReader.samplerKeys))
        guard case .array(let zones)? = written["zones"], case .object(let zone)? = zones.first,
              case .object(let crossfade)? = zone["crossfade"] else {
            Issue.record("no zone object was written"); return
        }
        #expect(Set(zone.keys) == Set(TemplateReader.samplerZoneKeys))
        #expect(Set(crossfade.keys) == Set(TemplateReader.samplerCrossfadeKeys))

        let track = Track(name: "Kit", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .sampler, sampler: sampler))
        let captured = try TemplateCapture.capture(tracks: [track], selected: [track.id],
                                                   name: "Full", id: "full")
        let data = try TemplateCapture.canonicalJSON(captured.template)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("sourcePath") && !text.contains("displayName") && !text.contains("sliceKit"))
        // §4.7: this build writes formatVersion 1 / minReaderVersion 1 for a Sampler too.
        #expect(text.contains("\"formatVersion\": 1,") && text.contains("\"minReaderVersion\": 1,"))
        let decoded = try TrackSetTemplateCodec.decode(data, origin: .file)
        #expect(decoded.warnings.isEmpty, "\(decoded.warnings)")
        #expect(decoded.template == (try TemplateCapture.canonical(captured.template)))
        // Built: the song gets exactly the source's sound, under new zone ids.
        let built = try #require(try TemplateBuilder.plan(decoded.template).tracks.first?.instrument?.sampler)
        var expected = sampler
        expected.sourcePath = nil
        expected.displayName = nil
        expected.sliceKit = nil
        #expect(built.zones.count == 2)
        for (zone, source) in zip(built.zones, expected.zones) {
            #expect(zone.id != source.id && !TemplateReader.isSamplerZonePlaceholder(zone.id))
            #expect(TemplateReader.samplerZone(zone, id: source.id) == source)
        }
        var globals = built
        globals.zones = expected.zones
        #expect(globals == expected)
    }

    @Test("A zone's file: an absolute path, a home-folder path (expanded, as the wire does), or a bundled sample — written back as builtin:")
    func zoneFiles() throws {
        let home = try #require(Self.read(#"{"zones": [{"path": "~/Samples/a.wav"}]}"#).sampler?.zones.first)
        #expect(home.audioFileURL.path == NSHomeDirectory() + "/Samples/a.wav")
        let bundled = try #require(Self.read(#"{"zones": [{"path": "builtin:test-tone-a4", "rootPitch": 69}]}"#)
            .sampler?.zones.first)
        #expect(bundled.audioFileURL.path == (try BundledSamples.resolve("builtin:test-tone-a4")).path)
        #expect(TemplateReader.samplerZoneReading(bundled, "path") == .string("builtin:test-tone-a4"),
                "the writer names the bundled sample, so the template works wherever the app lives")
        #expect(TemplateReader.samplerZoneReading(home, "path") == .string(home.audioFileURL.path))
        let unknown = Self.read(#"{"zones": [{"path": "builtin:nope"}]}"#).refusal
        #expect(unknown?.code == .invalidValue && unknown?.message.contains("builtin:test-tone-a4") == true)
        for relative in ["kick.wav", "Samples/kick.wav", "", "./kick.wav"] {
            let refusal = Self.read("{\"zones\": [{\"path\": \"\(relative)\"}]}").refusal
            #expect(refusal?.code == .invalidValue && refusal?.path == "tracks[0].instrument.sampler.zones[0].path",
                    "'\(relative)': \(String(describing: refusal))")
        }
        #expect(Self.read(#"{"zones": [{"rootPitch": 60}]}"#).refusal?.code == .missingKey)
    }

    // MARK: - Refusals, strict and lenient

    @Test("What a template cannot mean is refused in EVERY version: a zone id, zonePatches")
    func templateCannotMean() {
        for version in [1, 2] {
            let id = Self.read(#"{"zones": [{"path": "/x/a.wav", "id": "6F1A2B3C-0000-4000-8000-000000000001"}]}"#,
                               formatVersion: version).refusal
            #expect(id?.code == .invalidValue && id?.path == "tracks[0].instrument.sampler.zones[0].id"
                    && id?.message.contains("new ids") == true, "v\(version): \(String(describing: id))")
            let patches = Self.read(#"{"zonePatches": []}"#, formatVersion: version).refusal
            #expect(patches?.code == .invalidValue && patches?.path == "tracks[0].instrument.sampler.zonePatches",
                    "v\(version): \(String(describing: patches))")
        }
    }

    @Test("Values the model would change are refused from a same-version file and kept AS THE MODEL STORES THEM, said so, from a newer one")
    func readBackStrictAndLenient() throws {
        // (fields, the strict code, what a newer file's zone holds)
        let rows: [(String, TemplateRefusal.Code, (SamplerZone) -> Bool)] = [
            (#""minPitch": 70, "maxPitch": 60"#, .readBack, { $0.minPitch == 60 && $0.maxPitch == 70 }),
            (#""rootPitch": 200"#, .outOfRange, { $0.rootPitch == 127 }),
            (#""group": -1"#, .outOfRange, { $0.group == 0 }),
            (#""endFrame": 0"#, .readBack, { $0.endFrame == 1 }),
            (#""seqLength": 2, "seqPosition": 3"#, .readBack, { $0.seqPosition == 2 }),
            (#""crossfade": {"ccInLo": 10}"#, .readBack, { $0.crossfade == nil }),
            (#""chokeGroup": 64"#, .outOfRange, { $0.chokeGroup == 63 }),
        ]
        for (fields, code, holds) in rows {
            let strict = Self.zone(fields)
            #expect(strict.refusal?.code == code, "\(fields): \(String(describing: strict.refusal))")
            let newer = Self.zone(fields, formatVersion: 2)
            let zone = try #require(newer.sampler?.zones.first, "\(fields)")
            #expect(holds(zone), "\(fields): \(zone)")
            #expect(!newer.warnings.isEmpty && newer.warnings.allSatisfy {
                $0.code == .valueClamped || $0.code == .valueChanged
            }, "\(fields): \(newer.warnings)")
        }
        // A clamp is reported ONCE (valueClamped), not again by the read-back.
        #expect(Self.zone(#""rootPitch": 200"#, formatVersion: 2).warnings.map { $0.code } == [.valueClamped])
        // The strict sentences name the setting and what it would become.
        #expect(Self.zone(#""minPitch": 70, "maxPitch": 60"#).refusal?.message
            == "maxPitch can't hold 60; it would become 70.")
        #expect(Self.zone(#""group": -1"#).refusal?.message == "group is a whole number from 0 up; -1 would become 0.")
    }

    @Test("Modes: voice and glide modes in any case (as the wire); a loop mode exactly; an unknown one refused, or skipped from a newer file")
    func modes() throws {
        let read = try #require(Self.read(#"{"voiceMode": "LeGaTo", "glideMode": "CONSTANTRATE"}"#).sampler)
        #expect(read.voiceMode == .legato && read.glideMode == .constantRate)
        #expect(try #require(Self.read(#"{"voiceMode": null}"#).sampler).voiceMode == nil)
        #expect(Self.read(#"{"voiceMode": "drone"}"#).refusal?.code == .unknownSetting)
        let newer = Self.read(#"{"voiceMode": "drone"}"#, formatVersion: 2)
        #expect(newer.sampler?.voiceMode == nil && newer.warnings.map { $0.code } == [.unknownSettingSkipped])
        #expect(Self.zone(#""loopMode": "Sustain""#).refusal?.code == .unknownSetting)
        #expect(Self.zone(#""loopMode": "continuous""#).sampler?.zones.first?.loopMode == .continuous)
    }

    // MARK: - §4.7: versions

    @Test("§4.7: a NEWER writer's Sampler keeps every zone and skips only what this build doesn't know, said so; a file needing a newer reader is refused whole; this build writes v1")
    func versions() throws {
        let json = #"{"glow": 1, "zones": [{"path": "/x/a.wav", "rootPitch": 50, "warmth": 3}]}"#
        let strict = Self.read(json)
        #expect(strict.refusal?.code == .unknownKey && strict.refusal?.path == "tracks[0].instrument.sampler.glow")
        let newer = Self.read(json, formatVersion: 2)
        let sampler = try #require(newer.sampler)
        #expect(sampler.zones.count == 1 && sampler.zones.first?.rootPitch == 50)
        #expect(newer.warnings.map { $0.path } == ["tracks[0].instrument.sampler.glow",
                                                   "tracks[0].instrument.sampler.zones[0].warmth"])
        #expect(newer.warnings.allSatisfy { $0.code == .unknownKeySkipped })
        let needsNewer = try? TrackSetTemplateCodec.decode(
            Self.file(#"{"zones": [{"path": "/x/a.wav"}]}"#, formatVersion: 2, minReaderVersion: 2),
            origin: .file)
        #expect(needsNewer == nil)
        do {
            _ = try TrackSetTemplateCodec.decode(
                Self.file(#"{"zones": []}"#, formatVersion: 2, minReaderVersion: 2), origin: .file)
            Issue.record("a file needing a newer reader was read")
        } catch let refusal as TemplateRefusal {
            #expect(refusal.code == .needsNewerVersion)
        }
        #expect(TrackSetTemplate.currentFormatVersion == 1, "TPL-5b bumps no version (see the report)")
    }

    // MARK: - Capture

    @Test("Capture keeps a Sampler's zones under placeholder ids with their files by path, drops provenance, and says so for a slice kit")
    func captureNormalizesASampler() throws {
        let sampler = Self.fullSampler()
        let track = Track(name: "Chops", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .sampler, sampler: sampler))
        let captured = try TemplateCapture.capture(tracks: [track], selected: [track.id], name: "Chops")
        let held = try #require(captured.template.tracks.first?.instrument?.sampler)
        #expect(held.zones.map { $0.id } == [TemplateReader.samplerZoneID(0), TemplateReader.samplerZoneID(1)])
        #expect(held.zones.map { $0.audioFileURL.path } == sampler.zones.map { $0.audioFileURL.path })
        #expect(held.sourcePath == nil && held.displayName == nil && held.sliceKit == nil)
        #expect(captured.warnings == [TemplateWarning(
            code: .valueChanged, path: "tracks[0].instrument.sampler",
            message: "'Chops' was made by Chop to Sampler. The template keeps its slices but not "
                + "that mark, so changing the song's key will move this track's notes too.")])
        // No mark, no warning.
        var plain = sampler
        plain.sliceKit = nil
        let quiet = Track(name: "Kit", kind: .instrument,
                          instrument: InstrumentDescriptor(kind: .sampler, sampler: plain))
        #expect(try TemplateCapture.capture(tracks: [quiet], selected: [quiet.id], name: "Kit").warnings.isEmpty)
    }
}
