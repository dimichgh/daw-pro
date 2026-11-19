import Foundation
import Testing
@testable import DAWCore

/// W9-DRUMDEF (m39-hat-default + m39-dm-gm-default) — a NEW drum machine starts
/// with the user's picks, and a SAVED one keeps its sound.
///
/// The picks (2026-10-07): `hats-level` = 2, "as loud as the Mac kit" → the
/// hi-hats at +23.4 dB and the cymbals at +5.7 dB (W8-HAT's listening spec,
/// variant `2-at-mac-kit-level`); `dm-notes` = `gm-pads` → the General MIDI
/// drum keys, the pads still playing the eight drums in order.
///
/// ⛔ The literals 23.4 / 5.7 / `gm` are typed HERE on purpose, beside the
/// model's constants: a test that only compared the model against itself would
/// follow any edit of the constants and prove nothing about the pick.
///
/// Deliberately NOT `@MainActor`: everything here is a value type or the pure
/// template codec. The store half is in `DrumKitStoreTests` (an existing
/// `@MainActor` suite); the render half in `DrumNewKitDefaultRenderTests`.
@Suite("Drum machine — a new one starts with the user's picks (W9-DRUMDEF)")
struct DrumNewKitDefaultTests {

    static let pickedHatsDb = 23.4
    static let pickedCymbalsDb = 5.7

    // MARK: - The new kit, and the kit a saved song plays

    @Test("A new drum machine's kit is the picks, and differs from the factory kit in nothing else")
    func newKitIsThePicks() {
        let kit = DrumKitParams.newDrumMachineKit
        #expect(kit.hatsLevelDb == Self.pickedHatsDb)
        #expect(kit.cymbalsLevelDb == Self.pickedCymbalsDb)
        #expect(kit.noteLayout == .gm)
        #expect(DrumKitParams.newKitHatsLevelDb == Self.pickedHatsDb)
        #expect(DrumKitParams.newKitCymbalsLevelDb == Self.pickedCymbalsDb)
        #expect(DrumKitParams.newKitNoteLayout == .gm)
        // Put the four settings back (W9-HEAD's kit gain is the fourth) and it IS the factory kit, whole-struct.
        var back = kit
        back.hatsLevelDb = DrumKitParams.savedKitLevelTrimDb
        back.cymbalsLevelDb = DrumKitParams.savedKitLevelTrimDb
        back.noteLayout = .pads
        back.gain = 1.0
        #expect(back == DrumKitParams(), "a new drum machine differs from the factory kit in more than the picks")
        // It is the 808 preset in the General MIDI layout, at the new-kit gain.
        #expect(kit.matchingPreset?.name == "808")
        let eight = DrumKitParams.preset(named: "808")
        #expect(eight.map { $0.params.applyingPreset($0) } == eight?.params)
        // W9-HEAD (the orchestrator's ruling): the presets carry the new-kit gain too, so this holds again.
        #expect(eight.map { kit.applyingPreset($0) } == kit, "loading 808 onto a new drum machine changes it")
    }

    /// ⛔ THE KIT A NIL PLAYS. `DrumKitParams()` must stay exactly the kit every
    /// saved song with a never-edited drum machine plays: trims at the saved-kit
    /// neutral and the pad layout, encoded with NEITHER key.
    @Test("DrumKitParams() is still the kit a saved song plays: trims 0 dB, pad layout, neither key saved")
    func factoryKitIsTheSavedKit() throws {
        let kit = DrumKitParams()
        #expect(kit.hatsLevelDb == 0 && kit.cymbalsLevelDb == 0)
        #expect(kit.hatsLevelDb == DrumKitParams.savedKitLevelTrimDb)
        #expect(kit.noteLayout == .pads)
        let text = String(decoding: try JSONEncoder().encode(kit), as: UTF8.self)
        for key in ["hatsLevelDb", "cymbalsLevelDb", "noteLayout"] {
            #expect(text.contains(key) == false, "the factory kit now saves \(key)")
        }
        // Control: the new kit DOES save all three.
        let newText = String(decoding: try JSONEncoder().encode(DrumKitParams.newDrumMachineKit),
                             as: UTF8.self)
        for key in ["\"hatsLevelDb\"", "\"cymbalsLevelDb\"", "\"noteLayout\""] {
            #expect(newText.contains(key), "the new kit does not save \(key)")
        }
    }

    /// ⛔ A BYTE GATE IS BLIND TO A DECODE DEFAULT, so the decoded VALUES are
    /// asserted from bytes written before the trims and the layout existed (the
    /// two pre-TPL-0 fixtures `DrumKitNoteLayoutTests` freezes), and from an
    /// instrument with no `drumKit` key at all.
    @Test("A saved kit without the trim and layout keys decodes to 0 dB and pads; no kit plays the factory kit")
    func savedKitsDecodeToTheOldSound() throws {
        for (name, old) in [("default", DrumKitNoteLayoutTests.preTPL0DefaultKitCompact),
                            ("custom", DrumKitNoteLayoutTests.preTPL0CustomKitCompact)] {
            for key in ["hatsLevelDb", "cymbalsLevelDb", "noteLayout"] {
                #expect(old.contains(key) == false, "the \(name) fixture carries \(key)")
            }
            let kit = try JSONDecoder().decode(DrumKitParams.self, from: Data(old.utf8))
            #expect(kit.hatsLevelDb == 0, "\(name): hats decoded to \(kit.hatsLevelDb)")
            #expect(kit.cymbalsLevelDb == 0, "\(name): cymbals decoded to \(kit.cymbalsLevelDb)")
            #expect(kit.noteLayout == .pads, "\(name): layout decoded to \(kit.noteLayout)")
        }
        let document = try JSONDecoder().decode(InstrumentDocument.self,
                                                from: Data(#"{"kind":"drumSynth"}"#.utf8))
        #expect(document.drumKit == nil)
        let descriptor = InstrumentDescriptor(kind: .drumSynth, drumKit: document.drumKit)
        #expect(descriptor.resolvedDrumKit == DrumKitParams())
        #expect(descriptor.resolvedDrumKit.hatsLevelDb == 0)
        #expect(descriptor.resolvedDrumKit.noteLayout == .pads)
    }

    // MARK: - What a nil kit resolves to, and the kind-change rule

    @Test("A nil kit plays the factory kit on a drum machine, and a new drum machine's kit everywhere else")
    func nilResolvesByKind() {
        for kind in InstrumentDescriptor.Kind.allCases {
            let resolved = InstrumentDescriptor(kind: kind).resolvedDrumKit
            if kind == .drumSynth {
                #expect(resolved == DrumKitParams(), "a saved never-edited drum machine changed sound")
            } else {
                #expect(resolved == DrumKitParams.newDrumMachineKit, "\(kind): not the new kit")
            }
        }
        // A stored kit always wins.
        var dialled = DrumKitParams()
        dialled.setValue(0.9, forParamName: "kick.decay")
        for kind in InstrumentDescriptor.Kind.allCases {
            #expect(InstrumentDescriptor(kind: kind, drumKit: dialled).resolvedDrumKit == dialled)
        }
    }

    /// ⭐ THE ONE RULE FOR A KIND CHANGE, every pair. Entering the drum machine
    /// writes the new kit; leaving a never-edited one writes the factory kit it
    /// played; every other change leaves nil as nil (no drum kit grows in a
    /// file that never had one); a stored kit rides along untouched.
    @Test("drumKitCarried(into:): births, leavings, and every other kind change, pair by pair")
    func kindChangeRule() {
        var dialled = DrumKitParams()
        dialled.setValue(1.7, forParamName: "snare.tune")
        for from in InstrumentDescriptor.Kind.allCases {
            for to in InstrumentDescriptor.Kind.allCases {
                let carried = InstrumentDescriptor(kind: from).drumKitCarried(into: to)
                switch (from == .drumSynth, to == .drumSynth) {
                case (false, true):
                    #expect(carried == DrumKitParams.newDrumMachineKit, "\(from) → \(to): not born new")
                case (true, false):
                    #expect(carried == DrumKitParams(), "\(from) → \(to): the saved sound was not kept")
                default:
                    #expect(carried == nil, "\(from) → \(to): a kit grew where none was")
                }
                #expect(InstrumentDescriptor(kind: from, drumKit: dialled).drumKitCarried(into: to) == dialled,
                        "\(from) → \(to): a stored kit did not ride along")
            }
        }
    }

    // MARK: - Presets

    /// Every factory preset carries the new-kit trims, so loading one onto a
    /// new drum machine keeps the hats where the user picked them, and
    /// `instrument.loadDrumPreset` still replaces all 77 values. The layout
    /// stays the kit's (`applyingPreset`).
    @Test("Every factory preset carries the picked hat and cymbal levels, and keeps the kit's layout")
    func presetsCarryThePicks() throws {
        #expect(DrumKitParams.presets.count == 5)
        for preset in DrumKitParams.presets {
            #expect(preset.params.hatsLevelDb == Self.pickedHatsDb, "\(preset.name)")
            #expect(preset.params.cymbalsLevelDb == Self.pickedCymbalsDb, "\(preset.name)")
            #expect(preset.params.noteLayout == .pads, "\(preset.name): a preset sets the layout")
            let onNew = DrumKitParams.newDrumMachineKit.applyingPreset(preset)
            #expect(onNew.noteLayout == .gm && onNew.hatsLevelDb == Self.pickedHatsDb, "\(preset.name)")
            // ⚠️ Loading a preset onto a kit saved before the pick RAISES its hats:
            // loading a preset is an edit (documented on `presetBase`).
            let onOld = DrumKitParams().applyingPreset(preset)
            #expect(onOld.noteLayout == .pads && onOld.hatsLevelDb == Self.pickedHatsDb, "\(preset.name)")
        }
        // The 808 preset is the factory SOUND: only the two trims and W9-HEAD's kit gain differ.
        var eight = try #require(DrumKitParams.preset(named: "808")).params
        eight.hatsLevelDb = 0
        eight.cymbalsLevelDb = 0
        eight.gain = 1.0
        #expect(eight == DrumKitParams())
    }

    /// `describeDrumKit` and the MCP schema report each parameter's "default":
    /// what a NEW drum machine starts at. The sound parameters are the factory
    /// kit's; the two trims are the picks, and `kit.gain` is W9-HEAD's headroom.
    @Test("Every spec default is a new drum machine's value; only the kit gain and the two trims differ from the factory kit")
    func specDefaultsAreTheNewKit() {
        let newKit = DrumKitParams.newDrumMachineKit
        let factory = DrumKitParams()
        var differing: [String] = []
        for spec in DrumKitParams.paramSpecs {
            #expect(newKit.value(forParamName: spec.name) == spec.defaultValue, "\(spec.name)")
            if factory.value(forParamName: spec.name) != spec.defaultValue { differing.append(spec.name) }
        }
        #expect(differing == ["kit.gain", "kit.hatsLevelDb", "kit.cymbalsLevelDb"])
        let hats = DrumKitParams.paramSpecs.first { $0.name == "kit.hatsLevelDb" }
        #expect(hats?.note?.contains("23.4") == true, "the hats' meaning does not state the new start")
    }

    // MARK: - Templates

    private static func templateInstrument(_ json: String) throws -> InstrumentDescriptor? {
        let file = "{\"format\": \"dawpro.template\", \"formatVersion\": 1, \"minReaderVersion\": 1, "
            + "\"id\": \"probe\", \"name\": \"Probe\", \"tracks\": [{\"key\": \"d\", \"name\": \"Drums\", "
            + "\"kind\": \"instrument\", \"instrument\": \(json)}]}"
        return try TrackSetTemplateCodec.decode(Data(file.utf8), origin: .file).template.tracks.first?.instrument
    }

    /// A template's drum machine is a NEW one, written explicitly; a template
    /// that names a kit without a preset reads over the factory kit, the base
    /// every saved template was written against.
    @Test("Templates: no kit is a new drum machine; a preset plays in the new layout; a bare kit block is exact")
    func templateDrumMachines() throws {
        let bare = try Self.templateInstrument(#"{"kind": "drumSynth"}"#)
        #expect(bare == InstrumentDescriptor(kind: .drumSynth, drumKit: .newDrumMachineKit))

        let lofi = try #require(DrumKitParams.preset(named: "lofi"))
        let preset = try Self.templateInstrument(#"{"kind": "drumSynth", "drumPreset": "LoFi"}"#)
        #expect(preset == InstrumentDescriptor(kind: .drumSynth,
                                               drumKit: DrumKitParams.newDrumMachineKit.applyingPreset(lofi)))
        #expect(preset?.drumKit?.noteLayout == .gm)
        #expect(preset?.drumKit?.hatsLevelDb == Self.pickedHatsDb)

        let padsPreset = try Self.templateInstrument(
            #"{"kind": "drumSynth", "drumPreset": "lofi", "drumKit": {"noteLayout": "pads"}}"#)
        #expect(padsPreset?.drumKit?.noteLayout == .pads, "a named layout must win")

        // A kit block alone: over the FACTORY kit, exactly as before this change.
        var expected = DrumKitParams()
        expected.kick.decay = 0.9
        let exact = try Self.templateInstrument(#"{"kind": "drumSynth", "drumKit": {"kick": {"decay": 0.9}}}"#)
        #expect(exact == InstrumentDescriptor(kind: .drumSynth, drumKit: expected))
        let empty = try Self.templateInstrument(#"{"kind": "drumSynth", "drumKit": {}}"#)
        #expect(empty == InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams()))
    }

    /// The writer half: a captured drum machine names the kit it PLAYS, so a
    /// saved song's never-edited drum machine comes back as itself, and a new
    /// one comes back new.
    @Test("Template capture names the kit a drum machine plays, and it reads back as that kit")
    func capturedDrumMachinesReadBack() throws {
        let cases: [(String, InstrumentDescriptor, DrumKitParams)] = [
            ("never edited", InstrumentDescriptor(kind: .drumSynth), DrumKitParams()),
            ("new", InstrumentDescriptor(kind: .drumSynth, drumKit: .newDrumMachineKit), .newDrumMachineKit),
        ]
        for (name, descriptor, plays) in cases {
            let track = Track(name: "Drums", kind: .instrument, instrument: descriptor)
            let captured = try TemplateCapture.capture(tracks: [track], selected: [track.id], name: "Probe",
                                                       id: "probe")
            let data = try TemplateCapture.canonicalJSON(captured.template)
            let text = String(decoding: data, as: UTF8.self)
            #expect(text.contains("\"drumKit\""), "\(name): the kit was not written")
            let read = try TrackSetTemplateCodec.decode(data, origin: .file).template
            let readKit = read.tracks.first?.instrument?.resolvedDrumKit
            #expect(readKit == plays, "\(name): the template plays a different kit")
        }
    }

    /// The three built-in templates with a drum machine (the one the user
    /// listened to among them) start it with the picks and their preset's sound.
    @Test("The built-in drum templates start a new drum machine: their preset's sound, gm, the picked levels")
    func builtInDrumTemplates() throws {
        let listing = BuiltInTemplateCatalog.load()
        #expect(listing.unreadable.isEmpty)
        var found: [String: String] = [:]
        for entry in listing.templates {
            for track in entry.template.tracks where track.instrument?.kind == .drumSynth {
                let kit = try #require(track.instrument?.drumKit, "\(entry.id): the kit is not explicit")
                #expect(kit.noteLayout == .gm, "\(entry.id)")
                #expect(kit.hatsLevelDb == Self.pickedHatsDb, "\(entry.id)")
                #expect(kit.cymbalsLevelDb == Self.pickedCymbalsDb, "\(entry.id)")
                found[entry.id] = kit.matchingPreset?.name ?? "custom"
            }
        }
        #expect(found == ["hip-hop-808": "808", "lofi-chill": "lofi", "house-club": "909"])
    }

    /// The probe's kit name (`livenessInstrumentDetail`): a saved song's
    /// never-edited 808, and a preset loaded before the picks, are still named
    /// by their preset; a new drum machine is "808"; a real edit is custom.
    @Test("A preset saved before the picks keeps its name; a new drum machine is the 808 kit")
    func presetNamesSurviveThePicks() async throws {
        let lofi = try #require(DrumKitParams.preset(named: "lofi"))
        var savedLofi = lofi.params
        savedLofi.hatsLevelDb = DrumKitParams.savedKitLevelTrimDb
        savedLofi.cymbalsLevelDb = DrumKitParams.savedKitLevelTrimDb
        var edited = DrumKitParams()
        edited.setValue(2.5, forParamName: "kick.decay")
        var oneTrim = DrumKitParams()
        oneTrim.hatsLevelDb = 9
        let kits: [(String, DrumKitParams?, String)] = [
            ("never edited, saved", nil, "drum machine, 808 kit"),
            ("factory kit, saved", DrumKitParams(), "drum machine, 808 kit"),
            ("lofi, saved before the picks", savedLofi, "drum machine, lofi kit"),
            ("new drum machine", .newDrumMachineKit, "drum machine, 808 kit"),
            ("edited", edited, "drum machine, custom kit"),
            ("only the hats moved", oneTrim, "drum machine, custom kit"),
        ]
        for (label, kit, want) in kits {
            let got = await MainActor.run {
                ProjectStore.livenessInstrumentDetail(InstrumentDescriptor(kind: .drumSynth, drumKit: kit))
            }
            #expect(got == want, "\(label): \(String(describing: got))")
        }
    }
}
