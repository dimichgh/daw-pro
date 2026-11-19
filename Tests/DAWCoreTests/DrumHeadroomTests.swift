import Foundation
import Testing
@testable import DAWCore

/// W9-HEAD (m39-dm-headroom) — a NEW drum machine starts with headroom: kit gain
/// 0.7 (−3.1 dB), so a plain beat on a new song stays under −1 dBTP, and every
/// factory preset carries the same headroom (the orchestrator's rulings: lofi keeps
/// its step below the others, 0.9 × 0.7 = 0.63, and acoustic takes the same step on
/// the headroom alone). A SAVED drum machine keeps its own
/// gain, and the built-in templates that name a preset PIN the gain they always
/// played at, so neither moves.
///
/// ⛔ The literals 0.7 / 1.0 / 0.9 are typed HERE on purpose, beside the model's
/// constants: a test that only compared the model against itself would follow any
/// edit of the constants and prove nothing.
///
/// Deliberately NOT `@MainActor`: value types and the pure template codec only. The
/// render half (true peak, the hats-vs-snare balance) is `DrumHeadroomRenderTests`.
@Suite("Drum machine — a new one starts with headroom (W9-HEAD)")
struct DrumHeadroomTests {

    static let newKitGain = 0.7

    @Test("A new drum machine starts at kit gain 0.7; the factory kit and a nil kit stay at 1.0")
    func newKitHasHeadroom() {
        #expect(DrumKitParams.newKitGain == Self.newKitGain)
        #expect(DrumKitParams.newDrumMachineKit.gain == Self.newKitGain)
        #expect(DrumKitParams().gain == 1.0, "the kit every saved song plays changed level")
        #expect(InstrumentDescriptor(kind: .drumSynth).resolvedDrumKit.gain == 1.0,
                "a saved never-edited drum machine changed level")
        // The picks themselves did not move: only the gain is new.
        let kit = DrumKitParams.newDrumMachineKit
        #expect(kit.hatsLevelDb == 23.4 && kit.cymbalsLevelDb == 5.7 && kit.noteLayout == .gm)
        // Every birth by a kind change gets it; leaving a never-edited drum machine keeps 1.0.
        for kind in InstrumentDescriptor.Kind.allCases where kind != .drumSynth {
            #expect(InstrumentDescriptor(kind: kind).drumKitCarried(into: .drumSynth)?.gain == Self.newKitGain,
                    "\(kind) → drum machine: not born with headroom")
            #expect(InstrumentDescriptor(kind: .drumSynth).drumKitCarried(into: kind)?.gain == 1.0,
                    "drum machine → \(kind): the saved level was not kept")
        }
    }

    /// ⛔ A BYTE GATE IS BLIND TO A DECODE DEFAULT. Kits saved before the headroom
    /// carry their own `gain` key (the encoder always writes it); a kit with NO gain
    /// key at all decodes to 1.0, never to the new-kit gain.
    @Test("A saved kit decodes its own gain, and a kit with no gain key decodes 1.0, never 0.7")
    func savedKitsKeepTheirGain() throws {
        let factory = try JSONDecoder().decode(DrumKitParams.self,
                                               from: Data(DrumKitNoteLayoutTests.preTPL0DefaultKitCompact.utf8))
        #expect(factory.gain == 1.0)
        let custom = try JSONDecoder().decode(DrumKitParams.self,
                                              from: Data(DrumKitNoteLayoutTests.preTPL0CustomKitCompact.utf8))
        #expect(custom.gain == 0.9)
        // The same factory bytes with the gain key cut out.
        var object = try #require(try JSONSerialization.jsonObject(
            with: Data(DrumKitNoteLayoutTests.preTPL0DefaultKitCompact.utf8)) as? [String: Any])
        let removed = object.removeValue(forKey: "gain")
        #expect(removed != nil, "control: the fixture carried a gain key")
        let noGain = try JSONDecoder().decode(DrumKitParams.self,
                                              from: try JSONSerialization.data(withJSONObject: object))
        #expect(noGain.gain == 1.0, "a kit without a gain key decoded to \(noGain.gain)")
        // A new drum machine's kit SAVES its gain and reads it back.
        let saved = try JSONEncoder().encode(DrumKitParams.newDrumMachineKit)
        #expect(try JSONDecoder().decode(DrumKitParams.self, from: saved) == DrumKitParams.newDrumMachineKit)
        #expect(String(decoding: saved, as: UTF8.self).contains("\"gain\""))
    }

    @Test("Every factory preset carries the headroom: 0.7, lofi and acoustic 0.63; before it 1.0 (lofi 0.9), all else equal")
    func presetsCarryTheHeadroom() throws {
        let gains = Dictionary(uniqueKeysWithValues: DrumKitParams.presets.map { ($0.name, $0.params.gain) })
        #expect(gains == ["808": 0.7, "909": 0.7, "acoustic": 0.63, "lofi": 0.63, "trap": 0.7])
        let before = Dictionary(uniqueKeysWithValues: DrumKitParams.presetsBeforeHeadroom.map {
            ($0.name, $0.params.gain)
        })
        #expect(before == ["808": 1.0, "909": 1.0, "acoustic": 1.0, "lofi": 0.9, "trap": 1.0])
        // Lofi keeps its step below the others; acoustic takes the same step on the headroom alone
        // (its old self stays at 1.0, above).
        #expect(gains["lofi"].map { $0 / Self.newKitGain } == 0.9)
        #expect(gains["acoustic"].map { $0 / Self.newKitGain } == 0.9)
        // Same kits, same order; the gain is the ONLY difference.
        #expect(DrumKitParams.presets.map(\.name) == DrumKitParams.presetsBeforeHeadroom.map(\.name))
        for (now, then) in zip(DrumKitParams.presets, DrumKitParams.presetsBeforeHeadroom) {
            var lifted = then.params
            lifted.gain = now.params.gain
            #expect(lifted == now.params, "\(now.name) differs from its old self in more than the gain")
            #expect(now.summary == then.summary)
        }
        // So loading a preset onto a new drum machine keeps the headroom: 808 changes nothing.
        let eight = try #require(DrumKitParams.preset(named: "808"))
        #expect(DrumKitParams.newDrumMachineKit.applyingPreset(eight) == DrumKitParams.newDrumMachineKit)
    }

    /// `describeDrumKit` and the MCP schema report each parameter's "default": what a
    /// new drum machine starts at (the trims' rule).
    @Test("kit.gain's default is the new drum machine's 0.7, and its note says 1.0 is the saved level")
    func specDefaultIsTheNewKit() throws {
        let spec = try #require(DrumKitParams.paramSpecs.first { $0.name == "kit.gain" })
        #expect(spec.defaultValue == Self.newKitGain)
        #expect(spec.range == 0...2, "the range moved")
        let note = try #require(spec.note)
        #expect(note.contains("0.7") && note.contains("1.0"), "the note does not state both levels: \(note)")
    }

    /// The probe's kit name. A new drum machine is "808"; a kit loaded before the
    /// headroom (or pinned by a built-in template) keeps its name at its OLD gain;
    /// any other gain is a custom kit.
    @Test("matchingPreset names a preset at its new gain and at its old one, and nothing in between")
    func presetNamesSurviveTheHeadroom() throws {
        let newKit = DrumKitParams.newDrumMachineKit
        #expect(newKit.matchingPreset?.name == "808")
        let lofi = try #require(DrumKitParams.preset(named: "lofi"))
        let oldLofi = try #require(DrumKitParams.presetsBeforeHeadroom.first { $0.name == "lofi" })
        #expect(oldLofi.params.gain == 0.9)
        // Loaded now, onto a new drum machine.
        #expect(newKit.applyingPreset(lofi).matchingPreset?.name == "lofi")
        // Loaded before the headroom: with the picked levels (a built-in template), and
        // before the picks too (both levels 0, the pad layout).
        #expect(newKit.applyingPreset(oldLofi).matchingPreset?.name == "lofi")
        var savedLong = oldLofi.params
        savedLong.hatsLevelDb = 0
        savedLong.cymbalsLevelDb = 0
        #expect(savedLong.matchingPreset?.name == "lofi")
        #expect(DrumKitParams().matchingPreset?.name == "808", "a never-edited saved drum machine")
        // Acoustic, the same four ways: now (0.63), pinned at its old 1.0 with the picked levels, and
        // saved before the picks; at 0.7 it is custom. Plus its new 0.63 with both levels back at 0.
        let acoustic = try #require(DrumKitParams.preset(named: "acoustic"))
        let oldAcoustic = try #require(DrumKitParams.presetsBeforeHeadroom.first { $0.name == "acoustic" })
        #expect(acoustic.params.gain == 0.63 && oldAcoustic.params.gain == 1.0)
        #expect(newKit.applyingPreset(acoustic).matchingPreset?.name == "acoustic")
        #expect(newKit.applyingPreset(oldAcoustic).matchingPreset?.name == "acoustic")
        var savedAcoustic = oldAcoustic.params
        savedAcoustic.hatsLevelDb = 0
        savedAcoustic.cymbalsLevelDb = 0
        #expect(savedAcoustic.matchingPreset?.name == "acoustic")
        var acousticWithoutPicks = newKit.applyingPreset(acoustic)
        acousticWithoutPicks.hatsLevelDb = 0
        acousticWithoutPicks.cymbalsLevelDb = 0
        #expect(acousticWithoutPicks.matchingPreset?.name == "acoustic", "acoustic at 0.63, both levels 0")
        var acousticAtNewKitGain = newKit.applyingPreset(acoustic)
        acousticAtNewKitGain.gain = Self.newKitGain
        #expect(acousticAtNewKitGain.matchingPreset == nil, "acoustic at 0.7 is neither its new 0.63 nor its old 1.0")
        // Any other gain is custom — including lofi at exactly 0.7 (the option-A rule is gone).
        var other = newKit
        other.gain = 0.6
        #expect(other.matchingPreset == nil, "a kit at gain 0.6 read as a preset")
        var lofiAtNewKitGain = newKit.applyingPreset(lofi)
        lofiAtNewKitGain.gain = Self.newKitGain
        #expect(lofiAtNewKitGain.matchingPreset == nil, "lofi at 0.7 is neither its new 0.63 nor its old 0.9")
        // Control: a real sound edit is still custom.
        var edited = newKit
        edited.setValue(2.5, forParamName: "kick.decay")
        #expect(edited.matchingPreset == nil)
    }

    private static func templateInstrument(_ json: String) throws -> InstrumentDescriptor? {
        let file = "{\"format\": \"dawpro.template\", \"formatVersion\": 1, \"minReaderVersion\": 1, "
            + "\"id\": \"probe\", \"name\": \"Probe\", \"tracks\": [{\"key\": \"d\", \"name\": \"Drums\", "
            + "\"kind\": \"instrument\", \"instrument\": \(json)}]}"
        return try TrackSetTemplateCodec.decode(Data(file.utf8), origin: .file).template.tracks.first?.instrument
    }

    /// ⛔ The user judged the picks on the Hip-Hop 808 template: the built-in
    /// templates must not move. Each one that names a preset PINS the kit gain it
    /// always played at in its own file, so it reads exactly the kit it read before.
    @Test("The built-in drum templates pin their old gain (1, lofi 0.9) in their files; a bare template drum machine is new")
    func templatesPinTheirGain() throws {
        let listing = BuiltInTemplateCatalog.load()
        #expect(listing.unreadable.isEmpty)
        var found: [String: Double] = [:]
        for entry in listing.templates {
            for track in entry.template.tracks where track.instrument?.kind == .drumSynth {
                let kit = try #require(track.instrument?.drumKit, "\(entry.id)")
                found[entry.id] = kit.gain
                // The kit it read before the headroom: its preset at the old gain, General MIDI keys.
                #expect(DrumKitParams.presetsBeforeHeadroom.contains {
                    DrumKitParams.newDrumMachineKit.applyingPreset($0) == kit
                }, "\(entry.id): the kit is not its old preset")
            }
        }
        #expect(found == ["hip-hop-808": 1.0, "lofi-chill": 0.9, "house-club": 1.0])
        // Census of the shipped FILES: every drum machine that names a preset states its gain.
        let directory = try #require(BuiltInTemplateCatalog.directoryURL())
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".\(BuiltInTemplateCatalog.fileExtension)") }
        #expect(names.count == 10, "control: the ten shipped files")
        var pinned: [String] = []
        for name in names {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            for track in root["tracks"] as? [[String: Any]] ?? [] {
                guard let instrument = track["instrument"] as? [String: Any],
                      instrument["drumPreset"] != nil else { continue }
                let kit = instrument["drumKit"] as? [String: Any]
                let gain = kit?["gain"] as? NSNumber
                #expect(gain != nil, "\(name): a drum machine names a preset but not its gain")
                pinned.append(name)
            }
        }
        #expect(pinned.sorted() == ["hip-hop-808.dawtemplate", "house-club.dawtemplate", "lofi-chill.dawtemplate"])
        // A template drum machine that names a preset WITHOUT a gain plays the preset as it is now.
        let lofi = try #require(DrumKitParams.preset(named: "lofi"))
        let unpinned = try Self.templateInstrument(#"{"kind": "drumSynth", "drumPreset": "lofi"}"#)
        #expect(unpinned?.drumKit == DrumKitParams.newDrumMachineKit.applyingPreset(lofi))
        #expect(unpinned?.drumKit?.gain == 0.63)
        let bare = try Self.templateInstrument(#"{"kind": "drumSynth"}"#)
        #expect(bare?.drumKit?.gain == Self.newKitGain)
        let kitOnly = try Self.templateInstrument(#"{"kind": "drumSynth", "drumKit": {"kick": {"decay": 0.9}}}"#)
        #expect(kitOnly?.drumKit?.gain == 1.0, "a saved template's kit block moved")
    }
}
