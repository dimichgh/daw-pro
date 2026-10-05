import Foundation
import Testing
@testable import DAWCore

// m39-tpl-2 — `TemplateBuilder.plan` (docs/design/2026-09-27-multi-instrument-
// templates.md §5.3, §8.6's builder rows). NO `@MainActor`: the builder is pure
// and nonisolated, so its suite is too (§5.8, and the suite-cap rule).
//
// Every refusal is asserted by CODE, PATH and WORDS — a refusal that names the
// wrong place is a wrong answer an agent will act on. The templates are built
// in Swift (not through the codec) wherever the point is the builder's own
// check: a template built in Swift never passed the codec's checks, and the
// song skeleton's rosters will be built exactly that way (TPL-3).

/// Deterministic ids: 00000000-0000-4000-8000-000000000001, …002, … in call order.
final class TPL2SequentialIDs {
    private(set) var count = 0

    func next() -> UUID {
        count += 1
        return Self.id(count)
    }

    static func id(_ n: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012x", n))!
    }
}

/// One refusal row: the template, and what the refusal must say.
struct TPL2RefusalCase: Sendable, CustomTestStringConvertible {
    let label: String
    let template: TrackSetTemplate
    let code: TemplateRefusal.Code
    let path: String
    let says: [String]

    var testDescription: String { label }
}

@Suite("m39-tpl-2: TemplateBuilder.plan")
struct TemplateBuilderTests {
    // MARK: - Helpers

    static func template(_ tracks: [TemplateTrack],
                         formatVersion: Int = TrackSetTemplate.currentFormatVersion,
                         name: String = "Probe") -> TrackSetTemplate {
        TrackSetTemplate(formatVersion: formatVersion, name: name, tracks: tracks)
    }

    /// A track named after its key ("drums" → "Drums").
    static func track(_ key: String, _ kind: TrackKind = .audio,
                      _ configure: (inout TemplateTrack) -> Void = { _ in }) -> TemplateTrack {
        var track = TemplateTrack(key: key, name: key.prefix(1).uppercased() + key.dropFirst(),
                                  kind: kind)
        configure(&track)
        return track
    }

    static let lfo = TemplateModSource(key: "lfo", kind: .lfo)

    static func refusal(_ template: TrackSetTemplate) -> TemplateRefusal? {
        do {
            _ = try TemplateBuilder.plan(template)
            return nil
        } catch let refusal as TemplateRefusal {
            return refusal
        } catch {
            return TemplateRefusal(code: .notJSON, path: "<not a TemplateRefusal>",
                                   message: String(describing: error))
        }
    }

    static func check(_ row: TPL2RefusalCase) {
        guard let refusal = refusal(row.template) else {
            Issue.record("\(row.label): planned, but must be refused at \(row.path)")
            return
        }
        #expect(refusal.code == row.code, "\(row.label): \(refusal)")
        #expect(refusal.path == row.path, "\(row.label): \(refusal)")
        for words in row.says {
            #expect(refusal.message.contains(words),
                    "\(row.label): '\(refusal.message)' does not say '\(words)'")
        }
    }

    /// The design's own example (§4.3), as an inline wire template.
    static let lofiChillJSON = #"""
    {
      "name": "Lo-Fi Chill",
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

    static func lofiChill() throws -> TrackSetTemplate {
        try TrackSetTemplateCodec.decode(Data(lofiChillJSON.utf8), origin: .inline).template
    }

    /// A kind whose settings can be modulated, with as many of them as any
    /// kind has (so the budget tests need the fewest inserts).
    static func richestModulatableKind() -> (kind: EffectDescriptor.Kind, params: [String]) {
        var best: (EffectDescriptor.Kind, [String]) = (.gain, [])
        for kind in EffectDescriptor.Kind.allCases where kind != .audioUnit {
            let names = EffectParamSpec.specs(for: kind)
                .filter { $0.modulatable != .refused }.map(\.name)
            if names.count > best.1.count { best = (kind, names) }
        }
        return best
    }

    /// A track whose modulation moves `count` DISTINCT effect settings.
    static func modulatedTrack(_ key: String, distinctSettings count: Int) -> TemplateTrack {
        let (kind, params) = richestModulatableKind()
        var inserts: [TemplateInsert] = []
        var routes: [TemplateModRoute] = []
        var made = 0
        var insertIndex = 0
        while made < count {
            let insertKey = "fx\(insertIndex)"
            inserts.append(TemplateInsert(key: insertKey, kind: kind))
            for param in params where made < count {
                routes.append(TemplateModRoute(
                    source: "lfo", target: .effectParam(insert: insertKey, param: param),
                    depth: 0.1))
                made += 1
            }
            insertIndex += 1
        }
        return track(key) {
            $0.inserts = inserts
            $0.modulationSources = [lfo]
            $0.modulationRoutes = routes
        }
    }

    // MARK: - The design's example, end to end

    @Test("the §4.3 example plans every block: tracks, chains, routing, keys, modulation, resources")
    func designExamplePlansEveryBlock() throws {
        let template = try Self.lofiChill()
        let ids = TPL2SequentialIDs()
        let plan = try TemplateBuilder.plan(template, makeID: ids.next)
        let keys = ["drums", "bass", "keys", "vinyl", "duck", "room"]
        try #require(plan.tracks.count == 6)
        #expect(plan.tracks.map(\.name) == ["Drums", "Bass", "Keys", "Vinyl FX", "Keys Duck",
                                            "Tape Room"])
        #expect(plan.tracks.map(\.kind) == [.instrument, .instrument, .instrument, .audio, .bus,
                                            .bus])
        // Track ids are the first six ids minted, in template order.
        #expect(plan.tracks.map(\.id) == (1...6).map(TPL2SequentialIDs.id))
        for (index, key) in keys.enumerated() {
            #expect(plan.keyToTrackID[key] == plan.tracks[index].id, "\(key)")
        }
        let (drums, bass, keysTrack, vinyl, duck, room) =
            (plan.tracks[0], plan.tracks[1], plan.tracks[2], plan.tracks[3], plan.tracks[4],
             plan.tracks[5])
        #expect(drums.volume == 0.9)
        #expect(drums.instrument == template.tracks[0].instrument)
        #expect(drums.effects.map(\.kind) == [.saturator])
        #expect(drums.sends.map(\.destinationBusID) == [room.id])
        #expect(drums.sends.map(\.level) == [0.2])
        let bassPreset = try #require(MixerPresetCatalog.preset(named: "bass-round"))
        #expect(bass.effects.map(\.kind) == bassPreset.chain.map(\.kind))
        #expect(bass.instrument?.soundBank?.program == 33)
        let keysPreset = try #require(MixerPresetCatalog.preset(named: "warm-keys"))
        #expect(keysTrack.effects.map(\.kind) == keysPreset.chain.map(\.kind) + [.djFilter, .chorus])
        #expect(keysTrack.outputBusID == duck.id)
        #expect(keysTrack.sends.map(\.destinationBusID) == [room.id])
        let tone = keysTrack.effects[keysPreset.chain.count]
        #expect(tone.paramValue("position") == -0.25)
        #expect(keysTrack.modulationSources.map(\.kind) == [.lfo])
        #expect(keysTrack.modulationRoutes.count == 1)
        #expect(keysTrack.modulationRoutes.first?.target
                == .effectParam(effectID: tone.id, paramName: "position"))
        #expect(keysTrack.modulationRoutes.first?.sourceID == keysTrack.modulationSources.first?.id)
        #expect(vinyl.effects.count == (MixerPresetCatalog.preset(named: "lofi-tape")?.chain.count ?? -1))
        #expect(duck.effects.first?.sidechainSourceTrackID == drums.id)
        #expect(duck.effects.first?.paramValue("ratio") == 3)
        #expect(room.effects.map(\.kind) == [.hallReverb])
        #expect(plan.hasRouting)
        #expect(plan.slotsUsed == ["drums": 0, "bass": 0, "keys": 1, "vinyl": 0, "duck": 0,
                                   "room": 0])
        #expect(plan.resources.map(\.path) == ["tracks[1].instrument.soundBank",
                                               "tracks[2].instrument.soundBank"])
        #expect(plan.resources.map(\.trackKey) == ["bass", "keys"])
        // The one route earns a warning exactly when its target is `warned`.
        let positionSpec = EffectParamSpec.specs(for: .djFilter).first { $0.name == "position" }
        let warned = positionSpec?.modulatable == .warned
        #expect(plan.warnings.count == (warned ? 1 : 0), "\(plan.warnings)")
        // Every effect id is distinct across the plan.
        let effectIDs = plan.tracks.flatMap { $0.effects.map(\.id) }
        #expect(Set(effectIDs).count == effectIDs.count)
    }

    // MARK: - Step 1: references

    static var stepOneCases: [TPL2RefusalCase] {
        [
            TPL2RefusalCase(
                label: "an output to a bus key that does not exist",
                template: template([track("a") { $0.output = "verb" }, track("room", .bus)]),
                code: .invalidValue, path: "tracks[0].output",
                says: ["there is no bus with the key 'verb'", "The buses in this template are: room."]),
            TPL2RefusalCase(
                label: "an output to a track that is not a bus",
                template: template([track("a") { $0.output = "b" }, track("b")]),
                code: .invalidValue, path: "tracks[0].output",
                says: ["'b' is not a bus", "This template has no buses."]),
            TPL2RefusalCase(
                label: "a send to a bus key that does not exist (§6.4's own example)",
                template: template([track("a") { $0.sends = [TemplateSend(bus: "verb")] },
                                    track("room", .bus), track("duck", .bus)]),
                code: .invalidValue, path: "tracks[0].sends[0].bus",
                says: ["there is no bus with the key 'verb'",
                       "The buses in this template are: room, duck."]),
            TPL2RefusalCase(
                label: "a sidechain from a track key that does not exist",
                template: template([track("duck", .bus) {
                    $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "drums")]
                }]),
                code: .invalidValue, path: "tracks[0].inserts[0].sidechainSource",
                says: ["there is no track with the key 'drums'"]),
            TPL2RefusalCase(
                label: "a sidechain from a bus",
                template: template([track("a"), track("b1", .bus), track("duck", .bus) {
                    $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "b1")]
                }]),
                code: .invalidValue, path: "tracks[2].inserts[0].sidechainSource",
                says: ["'b1' is a bus"]),
            TPL2RefusalCase(
                label: "a route from a source key the track does not have",
                template: template([track("a") {
                    $0.modulationSources = [lfo]
                    $0.modulationRoutes = [TemplateModRoute(source: "lfo2", target: .volume, depth: 0.1)]
                }]),
                code: .invalidValue, path: "tracks[0].modulation.routes[0].source",
                says: ["no modulation source with the key 'lfo2'", "Its sources are: lfo."]),
            TPL2RefusalCase(
                label: "a route to an insert key the track does not have",
                template: template([track("a") {
                    $0.inserts = [TemplateInsert(key: "comp", kind: .compressor)]
                    $0.modulationSources = [lfo]
                    $0.modulationRoutes = [TemplateModRoute(
                        source: "lfo", target: .effectParam(insert: "eq", param: "ratio"), depth: 0.1)]
                }]),
                code: .invalidValue, path: "tracks[0].modulation.routes[0].target.insert",
                says: ["no effect with the key 'eq'", "Its effects with keys are: comp."]),
            TPL2RefusalCase(
                label: "two tracks with one key",
                template: template([track("a"), track("a")]),
                code: .duplicateKey, path: "tracks[1].key", says: ["'a'"]),
            TPL2RefusalCase(
                label: "two inserts with one key",
                template: template([track("a") {
                    $0.inserts = [TemplateInsert(key: "x", kind: .gain), TemplateInsert(key: "x", kind: .gain)]
                }]),
                code: .duplicateKey, path: "tracks[0].inserts[1].key", says: ["'x'"]),
            TPL2RefusalCase(
                label: "two modulation sources with one key",
                template: template([track("a") { $0.modulationSources = [lfo, lfo] }]),
                code: .duplicateKey, path: "tracks[0].modulation.sources[1].key", says: ["'lfo'"]),
            TPL2RefusalCase(
                label: "no tracks at all",
                template: template([]),
                code: .outOfRange, path: "tracks", says: ["1 to 24 tracks", "this one has 0"]),
        ]
    }

    @Test("step 1 refuses every reference that does not resolve, naming the path and what exists",
          arguments: TemplateBuilderTests.stepOneCases)
    func stepOneRefusesUnresolvedReferences(_ row: TPL2RefusalCase) {
        Self.check(row)
    }

    @Test("a step-1 refusal mints no ids at all: references are judged before anything is built")
    func stepOneMintsNoIDs() {
        for row in Self.stepOneCases {
            let ids = TPL2SequentialIDs()
            #expect(throws: TemplateRefusal.self, "\(row.label)") {
                _ = try TemplateBuilder.plan(row.template, makeID: ids.next)
            }
            #expect(ids.count == 0, "\(row.label): \(ids.count) ids minted before the refusal")
        }
        // Control: a template that plans mints ids (so the count above can move).
        let ids = TPL2SequentialIDs()
        _ = try? TemplateBuilder.plan(Self.template([Self.track("a")]), makeID: ids.next)
        #expect(ids.count == 1)
    }

    // MARK: - Step 2: build

    static var stepTwoCases: [TPL2RefusalCase] {
        [
            TPL2RefusalCase(
                label: "an instrument on a bus",
                template: template([track("b", .bus) {
                    $0.instrument = InstrumentDescriptor(kind: .polySynth)
                }]),
                code: .invalidValue, path: "tracks[0].instrument",
                says: ["only an instrument track can have an instrument", "a bus"]),
            TPL2RefusalCase(
                label: "a mixer preset that does not exist",
                template: template([track("a") { $0.mixerPreset = "nope" }]),
                code: .unknownKind, path: "tracks[0].mixerPreset",
                says: ["no mixer preset called 'nope'", MixerPresetCatalog.names[0]]),
            TPL2RefusalCase(
                label: "an Audio Unit insert with no plug-in",
                template: template([track("a") { $0.inserts = [TemplateInsert(kind: .audioUnit)] }]),
                code: .missingKey, path: "tracks[0].inserts[0].audioUnit", says: ["plug-in"]),
            TPL2RefusalCase(
                label: "a plug-in on an insert that is not an Audio Unit",
                template: template([track("a") {
                    $0.inserts = [TemplateInsert(kind: .gain, audioUnit: AudioUnitConfig(
                        component: AudioUnitComponentID(type: "aufx", subType: "dely",
                                                        manufacturer: "appl")))]
                }]),
                code: .invalidValue, path: "tracks[0].inserts[0].audioUnit",
                says: ["only an effect whose kind is \"audioUnit\""]),
            TPL2RefusalCase(
                label: "an effect setting name the kind does not have",
                template: template([track("a") {
                    $0.inserts = [TemplateInsert(kind: .compressor, params: ["loudness": 1])]
                }]),
                code: .unknownSetting, path: "tracks[0].inserts[0].params.loudness",
                says: ["no setting called 'loudness'", "ratio"]),
            TPL2RefusalCase(
                label: "seventeen inserts",
                template: template([track("a") {
                    $0.inserts = Array(repeating: TemplateInsert(kind: .gain), count: 17)
                }]),
                code: .outOfRange, path: "tracks[0].inserts",
                says: ["at most 16 effects", "would have 17"]),
        ]
    }

    @Test("step 2 refuses what cannot be built, naming the path",
          arguments: TemplateBuilderTests.stepTwoCases)
    func stepTwoRefusesWhatCannotBeBuilt(_ row: TPL2RefusalCase) {
        Self.check(row)
    }

    @Test("the 16-effect cap counts the mixer preset's chain AND the inserts: 16 builds, 17 is refused")
    func chainCapCountsThePresetAndTheInserts() throws {
        let preset = try #require(MixerPresetCatalog.v1.first { !$0.chain.isEmpty })
        let fits = TemplateBuilder.maxEffectsPerChain - preset.chain.count
        let atCap = Self.template([Self.track("a") {
            $0.mixerPreset = preset.name
            $0.inserts = Array(repeating: TemplateInsert(kind: .gain), count: fits)
        }])
        let plan = try TemplateBuilder.plan(atCap)
        #expect(plan.tracks.first?.effects.count == TemplateBuilder.maxEffectsPerChain)
        Self.check(TPL2RefusalCase(
            label: "one over the cap with a preset",
            template: Self.template([Self.track("a") {
                $0.mixerPreset = preset.name
                $0.inserts = Array(repeating: TemplateInsert(kind: .gain), count: fits + 1)
            }]),
            code: .outOfRange, path: "tracks[0].inserts",
            says: ["would have 17", "(\(preset.chain.count) from the mixer preset '\(preset.name)')"]))
    }

    // MARK: - Step 3: the read-back rule

    static var readBackCases: [TPL2RefusalCase] {
        let ratio = EffectParamSpec.specs(for: .compressor).first { $0.name == "ratio" }!.range
        let tooHigh = ratio.upperBound * 10
        return [
            TPL2RefusalCase(
                label: "phaser.stages 5 snaps to 6",
                template: template([track("a") {
                    $0.inserts = [TemplateInsert(kind: .phaser, params: ["stages": 5])]
                }]),
                code: .readBack, path: "tracks[0].inserts[0].params.stages",
                says: ["stages can't hold 5; it would become 6."]),
            TPL2RefusalCase(
                label: "compressor.ratio above its range is clamped",
                template: template([track("a") {
                    $0.inserts = [TemplateInsert(kind: .compressor, params: ["ratio": tooHigh])]
                }]),
                code: .readBack, path: "tracks[0].inserts[0].params.ratio",
                says: ["ratio can't hold \(ClampNotice.number(tooHigh)); it would become "
                    + "\(ClampNotice.number(ratio.upperBound))."]),
            TPL2RefusalCase(
                label: "a volume of 3 is clamped to 2 by Track.init",
                template: template([track("a") { $0.volume = 3 }]),
                code: .readBack, path: "tracks[0].volume",
                says: ["volume can't hold 3; it would become 2."]),
            TPL2RefusalCase(
                label: "a pan of -1.5 is clamped by Track.init",
                template: template([track("a") { $0.pan = -1.5 }]),
                code: .readBack, path: "tracks[0].pan",
                says: ["pan can't hold -1.5"]),
            TPL2RefusalCase(
                label: "a send level of 2.5 is clamped by Send.init",
                template: template([track("a") { $0.sends = [TemplateSend(bus: "room", level: 2.5)] },
                                    track("room", .bus)]),
                code: .readBack, path: "tracks[0].sends[0].level",
                says: ["level can't hold 2.5"]),
            TPL2RefusalCase(
                label: "a route depth of 1.5 is clamped by ModulationRoute.init",
                template: template([track("a") {
                    $0.modulationSources = [lfo]
                    $0.modulationRoutes = [TemplateModRoute(source: "lfo", target: .volume, depth: 1.5)]
                }]),
                code: .readBack, path: "tracks[0].modulation.routes[0].depth",
                says: ["depth can't hold 1.5"]),
        ]
    }

    @Test("step 3: a planted snap or clamp is REFUSED — the reading, not the setter, is the proof",
          arguments: TemplateBuilderTests.readBackCases)
    func readBackRefusesAPlantedSnapOrClamp(_ row: TPL2RefusalCase) {
        Self.check(row)
    }

    @Test("step 3 for a NEWER file: the reading is kept, with valueChanged — and in range, nothing is said")
    func readBackOfANewerFileWarnsAndKeepsTheReading() throws {
        let newer = Self.template([Self.track("a") {
            $0.inserts = [TemplateInsert(kind: .phaser, params: ["stages": 5])]
        }], formatVersion: TrackSetTemplate.currentFormatVersion + 1)
        let plan = try TemplateBuilder.plan(newer)
        #expect(plan.tracks.first?.effects.first?.paramValue("stages") == 6)
        #expect(plan.warnings.map(\.code) == [.valueChanged])
        #expect(plan.warnings.first?.path == "tracks[0].inserts[0].params.stages")
        #expect(plan.warnings.first?.message.contains("so it was set to 6") == true)
        // Control: a value that holds earns no warning in either version.
        for version in [TrackSetTemplate.currentFormatVersion,
                        TrackSetTemplate.currentFormatVersion + 1] {
            let holds = Self.template([Self.track("a") {
                $0.inserts = [TemplateInsert(kind: .phaser, params: ["stages": 6])]
                $0.volume = 0.5
            }], formatVersion: version)
            let quiet = try TemplateBuilder.plan(holds)
            #expect(quiet.warnings.isEmpty, "v\(version): \(quiet.warnings)")
            #expect(quiet.tracks.first?.volume == 0.5)
        }
    }

    // MARK: - Step 4: wiring

    static var stepFourCases: [TPL2RefusalCase] {
        [
            TPL2RefusalCase(
                label: "a bus that plays into another bus",
                template: template([track("b1", .bus) { $0.output = "b2" }, track("b2", .bus)]),
                code: .invalidValue, path: "tracks[0].output",
                says: ["'B1' is a bus", "main output"]),
            TPL2RefusalCase(
                label: "a bus with a send",
                template: template([track("b1", .bus) { $0.sends = [TemplateSend(bus: "b2")] },
                                    track("b2", .bus)]),
                code: .invalidValue, path: "tracks[0].sends[0].bus",
                says: ["'B1' is a bus"]),
            TPL2RefusalCase(
                label: "two sends from one track into one bus",
                template: template([track("a") {
                    $0.sends = [TemplateSend(bus: "room"), TemplateSend(bus: "room", level: 0.5)]
                }, track("room", .bus)]),
                code: .invalidValue, path: "tracks[0].sends[1].bus",
                says: ["'A' already sends to 'Room'"]),
            TPL2RefusalCase(
                label: "a sidechain on a reverb",
                template: template([track("drums"), track("duck", .bus) {
                    $0.inserts = [TemplateInsert(kind: .hallReverb, sidechainSource: "drums")]
                }]),
                code: .invalidValue, path: "tracks[1].inserts[0].sidechainSource",
                says: ["only be set on a compressor or a gate", "hallReverb"]),
            TPL2RefusalCase(
                label: "a sidechain on an instrument track",
                template: template([track("drums"), track("keys", .instrument) {
                    $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "drums")]
                }]),
                code: .invalidValue, path: "tracks[1].inserts[0].sidechainSource",
                says: ["'Keys' is an instrument track", "bus"]),
            TPL2RefusalCase(
                label: "a second keyed effect on one strip",
                template: template([track("drums"), track("hats"), track("duck", .bus) {
                    $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "drums"),
                                  TemplateInsert(kind: .gate, sidechainSource: "hats")]
                }]),
                code: .invalidValue, path: "tracks[2].inserts[1].sidechainSource",
                says: ["'Duck' already has an effect that listens"]),
            TPL2RefusalCase(
                label: "a track keyed by itself",
                template: template([track("a") {
                    $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "a")]
                }]),
                code: .invalidValue, path: "tracks[0].inserts[0].sidechainSource",
                says: ["a track can't listen to itself"]),
            TPL2RefusalCase(
                label: "two tracks keying each other (a loop inside the template)",
                template: template([
                    track("a") { $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "b")] },
                    track("b") { $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "a")] },
                ]),
                code: .invalidValue, path: "tracks[1].inserts[0].sidechainSource",
                says: ["feedback loop", "'B' already feeds 'A'", "B → A → B"]),
        ]
    }

    @Test("step 4 refuses what RoutingRules and SidechainRules forbid, in the template's words",
          arguments: TemplateBuilderTests.stepFourCases)
    func stepFourRefusesRoutingTheRulesForbid(_ row: TPL2RefusalCase) {
        Self.check(row)
    }

    @Test("the loop check sees the whole template: outputs, sends and earlier keys, never the song")
    func templateInternalLoopCheckSeesEarlierKeys() throws {
        // Legal: a bus keyed by a track that plays into it (no loop: a bus feeds
        // only the master).
        let ducking = Self.template([
            Self.track("drums") { $0.output = "duck" },
            Self.track("duck", .bus) {
                $0.inserts = [TemplateInsert(kind: .compressor, sidechainSource: "drums")]
            },
        ])
        let plan = try TemplateBuilder.plan(ducking)
        #expect(plan.tracks[1].effects[0].sidechainSourceTrackID == plan.tracks[0].id)
        #expect(plan.tracks[0].outputBusID == plan.tracks[1].id)
        // A three-track ring a → b → c → a is refused at the key that closes it,
        // which only the EARLIER keys reveal.
        let ring = Self.template([
            Self.track("a") { $0.inserts = [TemplateInsert(kind: .gate, sidechainSource: "c")] },
            Self.track("b") { $0.inserts = [TemplateInsert(kind: .gate, sidechainSource: "a")] },
            Self.track("c") { $0.inserts = [TemplateInsert(kind: .gate, sidechainSource: "b")] },
        ])
        let refusal = try #require(Self.refusal(ring))
        #expect(refusal.path == "tracks[2].inserts[0].sidechainSource", "\(refusal)")
        #expect(refusal.message.contains("feedback loop"), "\(refusal)")
        // Control: the same three keys without the closing one plan fine.
        var open = ring
        open.tracks[2].inserts = [TemplateInsert(kind: .gate)]
        _ = try TemplateBuilder.plan(open)
    }

    // MARK: - Step 5: modulation

    static var stepFiveCases: [TPL2RefusalCase] {
        // A discrete setting, found in the table rather than named from memory
        // (`delay.sync`/`division` refuse for a different reason, so skip them).
        let discrete: (EffectDescriptor.Kind, String) = {
            for kind in EffectDescriptor.Kind.allCases where kind != .audioUnit && kind != .delay {
                if let spec = EffectParamSpec.specs(for: kind).first(where: { $0.modulatable == .refused }) {
                    return (kind, spec.name)
                }
            }
            return (.gain, "none-found")
        }()
        let plug = AudioUnitConfig(component: AudioUnitComponentID(
            type: "aufx", subType: "dely", manufacturer: "appl"))
        func routed(_ target: TemplateTarget, inserts: [TemplateInsert] = [],
                    kind: TrackKind = .audio,
                    instrument: InstrumentDescriptor? = nil) -> TrackSetTemplate {
            template([track("a", kind) {
                $0.instrument = instrument
                $0.inserts = inserts
                $0.modulationSources = [lfo]
                $0.modulationRoutes = [TemplateModRoute(source: "lfo", target: target, depth: 0.1)]
            }])
        }
        return [
            TPL2RefusalCase(
                label: "a discrete setting (\(discrete.0.rawValue).\(discrete.1))",
                template: routed(.effectParam(insert: "fx", param: discrete.1),
                                 inserts: [TemplateInsert(key: "fx", kind: discrete.0)]),
                code: .invalidValue, path: "tracks[0].modulation.routes[0].target",
                says: ["(discrete)"]),
            TPL2RefusalCase(
                label: "an effect setting the kind does not have",
                template: routed(.effectParam(insert: "fx", param: "bogus"),
                                 inserts: [TemplateInsert(key: "fx", kind: .compressor)]),
                code: .unknownSetting, path: "tracks[0].modulation.routes[0].target",
                says: ["(unknownParam)", "ratio"]),
            TPL2RefusalCase(
                label: "a hosted Audio Unit insert",
                template: routed(.effectParam(insert: "plug", param: "anything"),
                                 inserts: [TemplateInsert(key: "plug", kind: .audioUnit,
                                                          audioUnit: plug)]),
                code: .invalidValue, path: "tracks[0].modulation.routes[0].target",
                says: ["(hostedAudioUnit)"]),
            TPL2RefusalCase(
                label: "an instrument setting on an audio track",
                template: routed(.instrumentParam(param: "cutoffHz")),
                code: .invalidValue, path: "tracks[0].modulation.routes[0].target",
                says: ["(noInstrument)"]),
            TPL2RefusalCase(
                label: "an instrument setting on a sound-bank instrument",
                template: routed(.instrumentParam(param: "cutoffHz"), kind: .instrument,
                                 instrument: InstrumentDescriptor(
                                    kind: .soundBank,
                                    soundBank: SoundBankConfig(source: .generalMIDI, program: 0))),
                code: .invalidValue, path: "tracks[0].modulation.routes[0].target",
                says: ["(hostedInstrument)"]),
            TPL2RefusalCase(
                label: "seventeen modulation sources",
                template: template([track("a") {
                    $0.modulationSources = (0..<17).map {
                        TemplateModSource(key: "s\($0)", kind: .lfo)
                    }
                }]),
                code: .outOfRange, path: "tracks[0].modulation.sources",
                says: ["at most 16 modulation sources", "this one has 17"]),
            TPL2RefusalCase(
                label: "sixty-five routes (all to the volume, so no effect-setting slot is used)",
                template: template([track("a") {
                    $0.modulationSources = [lfo]
                    $0.modulationRoutes = Array(
                        repeating: TemplateModRoute(source: "lfo", target: .volume, depth: 0.1),
                        count: 65)
                }]),
                code: .outOfRange, path: "tracks[0].modulation.routes[64]",
                says: ["at most 64 modulation routes", "route 65"]),
        ]
    }

    @Test("step 5 refuses modulation the rules forbid, with ModulationRules' own reason",
          arguments: TemplateBuilderTests.stepFiveCases)
    func stepFiveRefusesForbiddenModulation(_ row: TPL2RefusalCase) {
        Self.check(row)
    }

    @Test("the 64-slot budget is PER TRACK: 64 distinct settings fit on each of two tracks; 65 on one is refused")
    func slotBudgetIsCountedPerTrack() throws {
        let limit = ModulationLimits.maxRoutes
        let full = Self.template([Self.modulatedTrack("a", distinctSettings: limit),
                                  Self.modulatedTrack("b", distinctSettings: limit)])
        let plan = try TemplateBuilder.plan(full)
        #expect(plan.slotsUsed == ["a": limit, "b": limit])
        #expect(plan.tracks.map { ModulationRules.slotsUsed(by: $0) } == [limit, limit])
        #expect(plan.tracks[0].effects.count <= TemplateBuilder.maxEffectsPerChain)
        let over = Self.template([Self.modulatedTrack("a", distinctSettings: limit + 1)])
        let refusal = try #require(Self.refusal(over))
        #expect(refusal.code == .outOfRange, "\(refusal)")
        #expect(refusal.path == "tracks[0].modulation.routes[\(limit)]", "\(refusal)")
        #expect(refusal.message.contains("SHARE one \(limit)-slot budget"), "\(refusal)")
        // Two routes to ONE setting cost one slot, not two.
        var shared = Self.modulatedTrack("a", distinctSettings: 1)
        shared.modulationRoutes.append(shared.modulationRoutes[0])
        let sharedPlan = try TemplateBuilder.plan(Self.template([shared]))
        #expect(sharedPlan.slotsUsed == ["a": 1])
        #expect(sharedPlan.tracks[0].modulationRoutes.count == 2)
    }

    @Test("a `warned` target becomes a plan warning with mod.addRoute's own sentence; a `yes` target says nothing")
    func warnedTargetBecomesAPlanWarning() throws {
        var found: (EffectDescriptor.Kind, String)?
        var plain: (EffectDescriptor.Kind, String)?
        for kind in EffectDescriptor.Kind.allCases where kind != .audioUnit {
            for spec in EffectParamSpec.specs(for: kind) {
                if found == nil, spec.modulatable == .warned { found = (kind, spec.name) }
                if plain == nil, spec.modulatable == .yes { plain = (kind, spec.name) }
            }
        }
        let (warnedKind, warnedParam) = try #require(found)
        let (plainKind, plainParam) = try #require(plain)
        func plan(_ kind: EffectDescriptor.Kind, _ param: String) throws -> TemplatePlan {
            try TemplateBuilder.plan(Self.template([Self.track("a") {
                $0.inserts = [TemplateInsert(key: "fx", kind: kind)]
                $0.modulationSources = [Self.lfo]
                $0.modulationRoutes = [TemplateModRoute(
                    source: "lfo", target: .effectParam(insert: "fx", param: param), depth: 0.2)]
            }]))
        }
        let warnedPlan = try plan(warnedKind, warnedParam)
        let effect = try #require(warnedPlan.tracks.first?.effects.first)
        let expected = try ModulationRules.validate(
            target: .effectParam(effectID: effect.id, paramName: warnedParam),
            on: .track(warnedPlan.tracks[0]))
        try #require(expected.count == 1)
        #expect(warnedPlan.warnings == [TemplateWarning(
            code: .modulationTargetWarned, path: "tracks[0].modulation.routes[0].target",
            message: TemplateReader.splitModulationWarning(expected[0]).sentence)])
        #expect(try plan(plainKind, plainParam).warnings.isEmpty)
    }

    // MARK: - Ids

    /// The plan's tracks as JSON with every EFFECT id replaced by its position
    /// (effect ids come from the one-home factories, not from `makeID`).
    static func normalized(_ plan: TemplatePlan) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var text = String(decoding: try encoder.encode(plan.tracks), as: UTF8.self)
        for (t, track) in plan.tracks.enumerated() {
            for (e, effect) in track.effects.enumerated() {
                text = text.replacingOccurrences(of: effect.id.uuidString, with: "effect-\(t)-\(e)")
            }
        }
        return text
    }

    @Test("makeID makes a plan deterministic (effect ids aside) and the default makes two plans disjoint")
    func makeIDIsDeterministicAndFreshByDefault() throws {
        let template = try Self.lofiChill()
        let first = TPL2SequentialIDs()
        let second = TPL2SequentialIDs()
        let planA = try TemplateBuilder.plan(template, makeID: first.next)
        let planB = try TemplateBuilder.plan(template, makeID: second.next)
        #expect(try Self.normalized(planA) == Self.normalized(planB))
        #expect(planA.keyToTrackID == planB.keyToTrackID)
        // makeID minted exactly the tracks, sends, sources and routes.
        let minted = planA.tracks.count + planA.tracks.reduce(0) {
            $0 + $1.sends.count + $1.modulationSources.count + $1.modulationRoutes.count
        }
        #expect(first.count == minted)
        // The normalisation hides nothing it should not: only effect ids moved.
        #expect(try Self.normalized(planA).contains("effect-2-"))

        // Production ids: two plans of the same template share no id at all.
        let one = try TemplateBuilder.plan(template)
        let two = try TemplateBuilder.plan(template)
        func allIDs(_ plan: TemplatePlan) -> Set<UUID> {
            var ids: Set<UUID> = []
            for track in plan.tracks {
                ids.insert(track.id)
                track.effects.forEach { ids.insert($0.id) }
                track.sends.forEach { ids.insert($0.id) }
                track.modulationSources.forEach { ids.insert($0.id) }
                track.modulationRoutes.forEach { ids.insert($0.id) }
            }
            return ids
        }
        #expect(allIDs(one).isDisjoint(with: allIDs(two)))
        #expect(allIDs(one).count == minted + one.tracks.reduce(0) { $0 + $1.effects.count })
    }

    // MARK: - hasRouting and resources

    @Test("hasRouting is true exactly for an output into a bus, a send, or a sidechain key")
    func hasRoutingIsTrueExactlyForRouting() throws {
        let plain = Self.template([Self.track("a"), Self.track("k", .instrument),
                                   Self.track("room", .bus) {
                                       $0.inserts = [TemplateInsert(kind: .compressor)]
                                   }])
        #expect(try TemplateBuilder.plan(plain).hasRouting == false)
        var output = plain
        output.tracks[0].output = "room"
        #expect(try TemplateBuilder.plan(output).hasRouting)
        var send = plain
        send.tracks[1].sends = [TemplateSend(bus: "room", level: 0.5)]
        #expect(try TemplateBuilder.plan(send).hasRouting)
        var key = plain
        key.tracks[2].inserts[0].sidechainSource = "a"
        #expect(try TemplateBuilder.plan(key).hasRouting)
    }

    @Test("resources list every sound bank, sampler zone file and Audio Unit, with its path")
    func resourcesListEveryFileBackedItem() throws {
        let gm = SoundBankConfig(source: .generalMIDI, program: 4)
        let file = SoundBankConfig(source: .file(path: "/nowhere/strings.sf2"), program: 48)
        let zones = [SamplerZone(audioFileURL: URL(fileURLWithPath: "/nowhere/kick.wav"))]
        let synth = AudioUnitConfig(component: AudioUnitComponentID(subType: "syn1",
                                                                    manufacturer: "acme"))
        let fx = AudioUnitConfig(component: AudioUnitComponentID(type: "aufx", subType: "dely",
                                                                 manufacturer: "appl"))
        let template = Self.template([
            Self.track("gm", .instrument) {
                $0.instrument = InstrumentDescriptor(kind: .soundBank, soundBank: gm)
            },
            Self.track("file", .instrument) {
                $0.instrument = InstrumentDescriptor(kind: .soundBank, soundBank: file)
            },
            Self.track("smp", .instrument) {
                $0.instrument = InstrumentDescriptor(kind: .sampler,
                                                     sampler: SamplerParams(zones: zones))
            },
            Self.track("au", .instrument) {
                $0.instrument = InstrumentDescriptor(kind: .audioUnit, audioUnit: synth)
                $0.inserts = [TemplateInsert(kind: .gain), TemplateInsert(kind: .audioUnit, audioUnit: fx)]
            },
            Self.track("synth", .instrument) {
                $0.instrument = InstrumentDescriptor(kind: .polySynth)
            },
            Self.track("emptysampler", .instrument) {
                $0.instrument = InstrumentDescriptor(kind: .sampler)
            },
        ])
        let plan = try TemplateBuilder.plan(template)
        #expect(plan.resources == [
            TemplateResource(trackKey: "gm", path: "tracks[0].instrument.soundBank",
                             item: .soundBank(gm)),
            TemplateResource(trackKey: "file", path: "tracks[1].instrument.soundBank",
                             item: .soundBank(file)),
            TemplateResource(trackKey: "smp", path: "tracks[2].instrument.sampler",
                             item: .samplerZones(zones)),
            TemplateResource(trackKey: "au", path: "tracks[3].instrument.audioUnit",
                             item: .audioUnitInstrument(synth)),
            TemplateResource(trackKey: "au", path: "tracks[3].inserts[1].audioUnit",
                             item: .audioUnitEffect(fx)),
        ])
        // The builder only LISTS them: a bank file that is not there still plans.
        #expect(plan.tracks[1].instrument?.soundBank == file)
    }

    // MARK: - m39-tpl-5b: a Sampler's zones get new ids

    @Test("m39-tpl-5b: makeID mints every Sampler zone id, per track after the track ids and before its sends; nothing else about a zone moves")
    func samplerZonesGetIDsFromMakeID() throws {
        let zones = (0..<3).map { index in
            SamplerZone(id: TemplateReader.samplerZoneID(index),
                        audioFileURL: URL(fileURLWithPath: "/nowhere/z\(index).wav"),
                        rootPitch: 40 + index, pan: 0, chokeGroup: index)
        }
        // An INACTIVE Sampler block rides on a Poly Synth: the project file saves
        // its zones too (`ProjectBundle.planMedia` reads every track's
        // `instrument.sampler`), so they are re-identified as well.
        var synth = InstrumentDescriptor(kind: .polySynth)
        synth.sampler = SamplerParams(zones: [zones[0]])
        let template = Self.template([
            Self.track("kit", .instrument) {
                $0.instrument = InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: zones))
            },
            Self.track("lead", .instrument) {
                $0.instrument = synth
                $0.sends = [TemplateSend(bus: "room", level: 0.5)]
            },
            Self.track("room", .bus),
        ])
        let ids = TPL2SequentialIDs()
        let plan = try TemplateBuilder.plan(template, makeID: ids.next)
        // Tracks 1–3, then the kit's three zones (4–6), then the lead's inactive
        // zone (7) and its send (8).
        #expect(plan.tracks.map { $0.id } == (1...3).map(TPL2SequentialIDs.id))
        let kitZones = try #require(plan.tracks[0].instrument?.sampler?.zones)
        #expect(kitZones.map { $0.id } == (4...6).map(TPL2SequentialIDs.id))
        #expect(plan.tracks[1].instrument?.sampler?.zones.map { $0.id } == [TPL2SequentialIDs.id(7)])
        #expect(plan.tracks[1].sends.map { $0.id } == [TPL2SequentialIDs.id(8)])
        #expect(ids.count == 8)
        // Only the id moved: every other field of every zone is the template's.
        for (built, spec) in zip(kitZones, zones) {
            #expect(TemplateReader.samplerZone(built, id: spec.id) == spec)
        }
        // No placeholder reaches a track, and two production plans share no zone id.
        let one = try TemplateBuilder.plan(template)
        let two = try TemplateBuilder.plan(template)
        func zoneIDs(_ plan: TemplatePlan) -> [UUID] {
            plan.tracks.flatMap { $0.instrument?.sampler?.zones.map { $0.id } ?? [] }
        }
        #expect(zoneIDs(one).count == 4)
        #expect(!zoneIDs(one).contains { TemplateReader.isSamplerZonePlaceholder($0) })
        #expect(Set(zoneIDs(one)).isDisjoint(with: Set(zoneIDs(two))))
        #expect(Set(zoneIDs(one)).count == 4)
        // The resources still list the template's zone FILES (what the store checks).
        #expect(one.resources.count == 1)
    }
}
