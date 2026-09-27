import Foundation
import Testing
@testable import DAWCore

/// m39-tpl-0 (W7-TPL0) — THE DRUM MACHINE'S NOTE LAYOUT, model half: the map,
/// the decode contract, the preset rule, the preset NAME, and the one predicate
/// (`SMFProjectExporter.isDrumKit`) the step sequencer and MIDI export ask.
/// `docs/design/2026-09-27-multi-instrument-templates.md` §3.
///
/// ⛔ THE TWO-GUARD RULE AGAIN (`DrumKitTests`' header): the render byte gate in
/// `DrumNoteLayoutRenderTests` builds its kits in code and never goes through
/// the decoder, so it CANNOT see a decoder that reads an absent layout as `gm`
/// (the plant §8.8 names). The decode contract is pinned HERE instead, with a
/// fixture written by the pre-TPL-0 encoder, not by an initialiser.
///
/// Deliberately NOT `@MainActor`: everything here is a pure value type except
/// `ProjectStore.livenessInstrumentDetail`, reached through one
/// `MainActor.run` hop.
@Suite("Drum kit — note layout (TPL-0)")
struct DrumKitNoteLayoutTests {

    // MARK: - The map

    /// §3.3's table, written out BY HAND. Deriving it from the switch would make
    /// this assertion agree with whatever the switch happens to say.
    static let designGM: [DrumVoice: [UInt8]] = [
        .kick: [35, 36], .rim: [37], .snare: [38, 40], .clap: [39],
        .closedHat: [42, 44], .openHat: [46],
        .tom: [41, 43, 45, 47, 48, 50], .cymbal: [49, 51, 52, 53, 55, 57, 59],
    ]

    /// Today's pad map, also by hand.
    static let designPads: [DrumVoice: UInt8] = [
        .kick: 36, .snare: 37, .closedHat: 38, .openHat: 39,
        .clap: 40, .tom: 41, .rim: 42, .cymbal: 43,
    ]

    @Test("The gm column is exactly the design's table, and every other note is silent")
    func gmMatchesTheDesignTable() {
        var expected: [UInt8: DrumVoice] = [:]
        for (voice, notes) in Self.designGM {
            for note in notes { expected[note] = voice }
        }
        #expect(expected.count == 22, "the design table names 22 GM notes")
        for value in 0...255 {
            let note = UInt8(value)
            #expect(DrumVoice.voice(forNote: note, layout: .gm) == expected[note],
                    "gm note \(note)")
        }
    }

    @Test("The pads column is today's 36–43 map, and the old entry point is it")
    func padsIsTheLegacyMap() {
        for (voice, note) in Self.designPads {
            #expect(voice.note == note, "\(voice).note moved")
            #expect(DrumVoice.voice(forNote: note, layout: .pads) == voice)
        }
        for value in 0...255 where !(36...43).contains(value) {
            #expect(DrumVoice.voice(forNote: UInt8(value), layout: .pads) == nil,
                    "pads note \(value)")
        }
        for value in 0...255 {
            #expect(DrumVoice.voice(forNote: UInt8(value))
                        == DrumVoice.voice(forNote: UInt8(value), layout: .pads),
                    "voice(forNote:) left the pads column at \(value)")
        }
    }

    @Test("notes(in:) is derived from the map: the table in gm, one note per voice in pads")
    func notesInEachLayout() {
        for voice in DrumVoice.allCases {
            #expect(voice.notes(in: .gm) == Self.designGM[voice], "\(voice) in gm")
            #expect(voice.notes(in: .pads) == [voice.note], "\(voice) in pads")
        }
    }

    /// §3.3's honest limit: the GM notes outside the table are silent and
    /// LISTED rather than discovered by an agent wondering where its cowbell went.
    @Test("The silent General MIDI drum notes are listed, and every GM note is either played or listed")
    func silentGMNotesAreListed() {
        let gmSilent: [UInt8] = [54, 56, 58] + Array(UInt8(60)...UInt8(81))
        #expect(DrumNoteLayout.gm.silentGMNotes == gmSilent)
        let padsSilent: [UInt8] = [35] + Array(UInt8(44)...UInt8(81))
        #expect(DrumNoteLayout.pads.silentGMNotes == padsSilent)
        for layout in DrumNoteLayout.allCases {
            let played = DrumVoice.allCases
                .flatMap { $0.notes(in: layout) }
                .filter { DrumNoteLayout.generalMIDIPercussionNotes.contains($0) }
            #expect(Set(played).isDisjoint(with: layout.silentGMNotes))
            #expect(Set(played).union(layout.silentGMNotes)
                        == Set(DrumNoteLayout.generalMIDIPercussionNotes),
                    "\(layout): a GM drum note is neither played nor listed")
        }
        #expect(DrumNoteLayout.gm.summary.isEmpty == false)
        #expect(DrumNoteLayout.pads.summary.isEmpty == false)
    }

    // MARK: - The decode contract

    /// ⛔ BYTES WRITTEN BY THE PRE-TPL-0 ENCODER (the v0 run, 2026-09-27,
    /// `$S/w7/TPL0/probe-before.txt`): the `lofi` preset with both hat chokes
    /// cleared, the rim in group 5 and `kick.decay` 1.3, compact and key-sorted.
    static let preTPL0CustomKitCompact = #"{"accentDepth":0.25,"accentThreshold":100,"clap":{"decay":0.28,"drive":0.05,"level":0.75,"pan":-0.15,"snap":0.5,"spread":0.011,"tone":0.25,"tune":780,"velocity":0.6},"closedHat":{"decay":0.035,"drive":0,"level":0.7,"pan":0.1,"snap":0.5,"tone":0.15,"tune":1,"velocity":0.75},"cymbal":{"band":2200,"decay":0.7,"drive":0,"level":0.55,"pan":-0.2,"snap":0.5,"tone":0.15,"tune":1,"velocity":0.8},"gain":0.9,"kick":{"decay":1.3,"drive":0.55,"level":0.9,"pan":0,"pitchAmount":3.2,"pitchDecay":0.045,"snap":0.1,"tone":0.18,"tune":48,"velocity":0.55},"openHat":{"decay":0.2,"drive":0,"level":0.7,"pan":0.1,"snap":0.5,"tone":0.15,"tune":1,"velocity":0.7},"rim":{"chokeGroup":5,"decay":0.028,"drive":0,"level":0.6,"pan":0.3,"snap":0.4,"tone":0.3,"tune":1700,"velocity":0.7},"snare":{"decay":0.15,"drive":0.4,"level":0.8,"noiseTone":1100,"pan":0,"partial2Ratio":1.83,"snap":0.55,"tone":0.2,"tune":180,"velocity":0.85},"tom":{"decay":0.38,"drive":0.05,"level":0.8,"pan":-0.25,"pitchAmount":0.45,"snap":0.25,"tone":0.5,"tune":120,"velocity":0.8},"velocityToTone":0.2}"#
    /// The factory kit, same encoder.
    static let preTPL0DefaultKitCompact = #"{"accentDepth":0.25,"accentThreshold":100,"clap":{"decay":0.28,"drive":0.05,"level":0.75,"pan":-0.15,"snap":0.5,"spread":0.011,"tone":0.55,"tune":1000,"velocity":0.6},"closedHat":{"chokeGroup":0,"decay":0.05,"drive":0,"level":0.7,"pan":0.1,"snap":0.5,"tone":0.5,"tune":1,"velocity":0.75},"cymbal":{"band":3440,"decay":1.1,"drive":0,"level":0.55,"pan":-0.2,"snap":0.5,"tone":0.45,"tune":1,"velocity":0.8},"gain":1,"kick":{"decay":0.62,"drive":0.12,"level":0.9,"pan":0,"pitchAmount":3.2,"pitchDecay":0.045,"snap":0.18,"tone":0.5,"tune":52,"velocity":0.55},"openHat":{"chokeGroup":0,"decay":0.32,"drive":0,"level":0.7,"pan":0.1,"snap":0.5,"tone":0.5,"tune":1,"velocity":0.7},"rim":{"decay":0.028,"drive":0,"level":0.6,"pan":0.3,"snap":0.4,"tone":0.3,"tune":1700,"velocity":0.7},"snare":{"decay":0.19,"drive":0.1,"level":0.8,"noiseTone":2200,"pan":0,"partial2Ratio":1.83,"snap":0.55,"tone":0.5,"tune":180,"velocity":0.85},"tom":{"decay":0.38,"drive":0.05,"level":0.8,"pan":-0.25,"pitchAmount":0.45,"snap":0.25,"tone":0.5,"tune":120,"velocity":0.8},"velocityToTone":0.4}"#
    /// The same two kits as the PROJECT WRITER encodes them
    /// (`ProjectBundle.swift`: `[.prettyPrinted, .sortedKeys]`): byte count and
    /// FNV-1a 64 of the pre-TPL-0 bytes.
    static let preTPL0CustomKitPretty = (count: 1641, fnv: "144ebb76d352d85c")
    static let preTPL0DefaultKitPretty = (count: 1661, fnv: "dd4ce73bc428537a")

    static func fnv(_ data: Data) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in data {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    @Test("A kit saved before TPL-0 decodes to pads and re-encodes to the SAME bytes")
    func oldKitJSONDecodesToPadsAndReencodesIdentically() throws {
        let compact = JSONEncoder()
        compact.outputFormatting = [.sortedKeys]
        let pretty = JSONEncoder()
        pretty.outputFormatting = [.prettyPrinted, .sortedKeys]
        let fixtures: [(String, String, (count: Int, fnv: String))] = [
            ("custom", Self.preTPL0CustomKitCompact, Self.preTPL0CustomKitPretty),
            ("default", Self.preTPL0DefaultKitCompact, Self.preTPL0DefaultKitPretty),
        ]
        for (name, old, oldPretty) in fixtures {
            #expect(old.contains("noteLayout") == false, "the \(name) fixture is not pre-TPL-0")
            let kit = try JSONDecoder().decode(DrumKitParams.self, from: Data(old.utf8))
            #expect(kit.noteLayout == .pads, "an old \(name) kit did not decode to pads")
            let again = String(decoding: try compact.encode(kit), as: UTF8.self)
            #expect(again == old, "the \(name) kit's saved bytes changed")
            let prettyAgain = try pretty.encode(kit)
            #expect(prettyAgain.count == oldPretty.count
                        && Self.fnv(prettyAgain) == oldPretty.fnv,
                    Comment(rawValue: "the \(name) kit's PROJECT-FILE bytes changed: "
                        + "\(prettyAgain.count) B, \(Self.fnv(prettyAgain)) vs "
                        + "\(oldPretty.count) B, \(oldPretty.fnv)"))
        }
        // The fixture really is the non-default kit it says it is, so the round
        // trip above carried information.
        let custom = try JSONDecoder().decode(
            DrumKitParams.self, from: Data(Self.preTPL0CustomKitCompact.utf8))
        #expect(custom.kick.decay == 1.3)
        #expect(custom.rim.chokeGroup == 5)
        #expect(custom.closedHat.chokeGroup == nil)
        #expect(custom != DrumKitParams())
    }

    @Test("gm is written and round-trips; pads is never written")
    func gmRoundTripsAndPadsIsNeverWritten() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var gm = DrumKitParams()
        gm.noteLayout = .gm
        let gmText = String(decoding: try encoder.encode(gm), as: UTF8.self)
        #expect(gmText.contains(#""noteLayout":"gm""#), "a gm kit did not save its layout")
        let back = try JSONDecoder().decode(DrumKitParams.self, from: Data(gmText.utf8))
        #expect(back.noteLayout == .gm)
        #expect(back == gm)

        var flipped = DrumKitParams()
        flipped.noteLayout = .gm
        flipped.noteLayout = .pads
        let padsText = String(decoding: try encoder.encode(flipped), as: UTF8.self)
        #expect(padsText.contains("noteLayout") == false, "pads was written")
        #expect(flipped == DrumKitParams(), "an explicit pads kit differs from an absent one")
        #expect(DrumKitParams(noteLayout: .pads) == DrumKitParams())
        #expect(DrumKitParams(noteLayout: .gm) == gm)
    }

    /// The render instance dedupes publishes on `!=`. A layout that equality
    /// ignored would never reach the render thread.
    @Test("A gm kit is not equal to its pads twin")
    func layoutIsPartOfEquality() {
        #expect(DrumKitParams(noteLayout: .gm) != DrumKitParams())
        var edited = DrumKitParams()
        edited.setValue(0.9, forParamName: "kick.decay")
        var editedGM = edited
        editedGM.noteLayout = .gm
        #expect(editedGM != edited)
    }

    @Test("An unknown layout reads as pads; a non-string layout is refused")
    func unknownLayoutReadsAsPads() throws {
        let unknown = #"{"kick":{"tune":40},"noteLayout":"gm2"}"#
        let kit = try JSONDecoder().decode(DrumKitParams.self, from: Data(unknown.utf8))
        #expect(kit.noteLayout == .pads)
        #expect(kit.kick.tune == 40, "the rest of the kit still decoded")
        let wrongType = #"{"noteLayout":5}"#
        #expect(throws: (any Error).self) {
            _ = try JSONDecoder().decode(DrumKitParams.self, from: Data(wrongType.utf8))
        }
        // Control: the real spelling decodes.
        let known = #"{"noteLayout":"gm"}"#
        #expect(try JSONDecoder().decode(DrumKitParams.self, from: Data(known.utf8))
                    .noteLayout == .gm)
    }

    // MARK: - Presets: a preset changes the sound, never the layout

    @Test("Loading each of the five presets keeps the kit's layout and takes the preset's sound")
    func presetsKeepTheLayout() {
        #expect(DrumKitParams.presets.count == 5)
        for layout in DrumNoteLayout.allCases {
            var kit = DrumKitParams()
            kit.setValue(2.5, forParamName: "kick.decay")
            kit.noteLayout = layout
            for preset in DrumKitParams.presets {
                let loaded = kit.applyingPreset(preset)
                #expect(loaded.noteLayout == layout,
                        "\(preset.name) moved a \(layout) kit's layout")
                var sound = loaded
                sound.noteLayout = .pads
                #expect(sound == preset.params, "\(preset.name)'s sound did not land whole")
            }
        }
    }

    @Test("A gm kit is still named by its preset; a custom kit is not")
    func matchingPresetIgnoresTheLayout() {
        for preset in DrumKitParams.presets {
            var gm = preset.params
            gm.noteLayout = .gm
            #expect(gm.matchingPreset?.name == preset.name, "gm \(preset.name)")
            #expect(preset.params.matchingPreset?.name == preset.name, "pads \(preset.name)")
        }
        var custom = DrumKitParams()
        custom.setValue(2.5, forParamName: "kick.decay")
        #expect(custom.matchingPreset == nil)
        custom.noteLayout = .gm
        #expect(custom.matchingPreset == nil)
    }

    /// The gate's row: "A `gm` lofi kit is still reported as the lofi kit."
    @Test("probeLiveness names a gm lofi kit as the lofi kit")
    func livenessNamesTheSoundNotTheLayout() async throws {
        let lofi = try #require(DrumKitParams.preset(named: "lofi")).params
        var gmLofi = lofi
        gmLofi.noteLayout = .gm
        var custom = lofi
        custom.setValue(2.5, forParamName: "kick.decay")
        let names: [String?] = await MainActor.run {
            [
                ProjectStore.livenessInstrumentDetail(
                    InstrumentDescriptor(kind: .drumSynth, drumKit: lofi)),
                ProjectStore.livenessInstrumentDetail(
                    InstrumentDescriptor(kind: .drumSynth, drumKit: gmLofi)),
                ProjectStore.livenessInstrumentDetail(
                    InstrumentDescriptor(kind: .drumSynth, drumKit: custom)),
            ]
        }
        #expect(names[0] == "drum machine, lofi kit")
        #expect(names[1] == "drum machine, lofi kit", "a gm lofi kit was renamed")
        #expect(names[2] == "drum machine, custom kit")
    }

    // MARK: - The one predicate the step sequencer and MIDI export ask

    static func track(_ instrument: InstrumentDescriptor?, notes: [MIDINote] = []) -> Track {
        Track(name: "Drums", kind: .instrument,
              clips: notes.isEmpty ? [] : [Clip(name: "Beat", startBeat: 0, lengthBeats: 4,
                                                notes: notes)],
              instrument: instrument)
    }

    @Test("isDrumKit: a gm drum machine is a GM drum kit; a pads one is not")
    func isDrumKitFollowsTheLayout() {
        let gm = InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams(noteLayout: .gm))
        #expect(SMFProjectExporter.isDrumKit(Self.track(gm)))
        #expect(SMFProjectExporter.isDrumKit(Self.track(
            InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams()))) == false)
        // A never-configured drum machine is the factory kit, which is pads.
        #expect(SMFProjectExporter.isDrumKit(Self.track(
            InstrumentDescriptor(kind: .drumSynth))) == false)
        // The kit rides kind switches: a gm kit under the poly synth is not heard.
        #expect(SMFProjectExporter.isDrumKit(Self.track(
            InstrumentDescriptor(kind: .polySynth, drumKit: DrumKitParams(noteLayout: .gm))))
            == false)
        // Controls: the percussion bank still is, a melodic bank still is not.
        #expect(SMFProjectExporter.isDrumKit(Self.track(InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                       bankMSB: GMProgramCatalog.percussionBankMSB)))))
        #expect(SMFProjectExporter.isDrumKit(Self.track(InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                       bankMSB: GMProgramCatalog.melodicBankMSB)))) == false)
        #expect(SMFProjectExporter.isDrumKit(Self.track(nil)) == false)
    }

    /// The export caller, end to end: a gm drum machine's beat lands on the GM
    /// drum channel (9), so any General MIDI player plays the right drums; a
    /// pads one keeps today's melodic channel.
    @Test("MIDI export puts a gm drum machine on the GM drum channel")
    func exportUsesTheDrumChannelForGM() throws {
        let beat = [MIDINote(pitch: 36, velocity: 100, startBeat: 0, lengthBeats: 0.25),
                    MIDINote(pitch: 38, velocity: 100, startBeat: 1, lengthBeats: 0.25)]
        let gm = Self.track(InstrumentDescriptor(kind: .drumSynth,
                                                 drumKit: DrumKitParams(noteLayout: .gm)),
                            notes: beat)
        let pads = Self.track(InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams()),
                              notes: beat)
        let plan = try SMFProjectExporter.map(
            tracks: [pads, gm], projectName: "tpl0", tempoMap: TempoMap(constantBPM: 120),
            meterMap: MeterMap(constant: TimeSignature()), options: MIDIExportOptions())
        #expect(plan.report.tracks.count == 2)
        #expect(plan.report.tracks[0].channel == 0, "a pads drum machine left channel 0")
        #expect(plan.report.tracks[1].channel == SMFProjectExporter.drumChannel,
                "a gm drum machine is not on the GM drum channel")
    }
}
