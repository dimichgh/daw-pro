import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m39-w4-8 — the pad grid's drum map, headless (`PadGridDrumMap`).
///
/// Non-isolated on purpose: the map is pure, so this suite costs nothing against
/// the `@MainActor` suite cap. The model and the seam (`PadGridModel`, the
/// letter keys, the spy sink) are tested in `PadGridTests`, inside the existing
/// `MusicalTypingControllerTests` suite.
@Suite("Pad grid drum map (m39-w4-8)")
struct PadGridDrumMapTests {

    private static func drumMachine(_ layout: DrumNoteLayout,
                                    edit: (inout DrumKitParams) -> Void = { _ in })
        -> InstrumentDescriptor {
        var kit = DrumKitParams(noteLayout: layout)
        edit(&kit)
        return InstrumentDescriptor(kind: .drumSynth, drumKit: kit)
    }

    // MARK: - Pads 1–8 are the eight drums, in either layout

    /// ⭐ PAD i IS VOICE i, AT THE LANE'S NOTE. Read against the two one-homes
    /// (`DrumVoice.voice(forSlot:)` for the order, `DrumLaneMap` for the note),
    /// never against a literal table — and then ALSO against the design's own
    /// literal (§7) so a change to either one-home is seen.
    @Test("pad i plays voice i at its lane note, in pads AND gm")
    func padsAreTheEightDrums() throws {
        for layout in DrumNoteLayout.allCases {
            let instrument = Self.drumMachine(layout)
            let pads = try #require(PadGridDrumMap.drumMachinePads(for: instrument))
            let lanes = try #require(DrumLaneMap.lanes(for: instrument))
            #expect(pads.count == 8, "\(layout)")
            for (index, pad) in pads.enumerated() {
                let voice = try #require(DrumVoice.voice(forSlot: Int32(index)))
                #expect(pad.voice == voice, "\(layout) pad \(index + 1)")
                #expect(pad.note == lanes.first { $0.voice == voice }?.note, "\(layout) \(voice)")
                #expect(pad.label == voice.displayName)
                // "A row labelled X plays X": the note sounds THIS voice.
                #expect(DrumVoice.voice(forNote: UInt8(pad.note), layout: layout) == voice)
            }
        }
        // The design's literals (§7): pads = 36 + i; gm = the GM drum notes.
        #expect(PadGridDrumMap.drumMachinePads(for: Self.drumMachine(.pads))?.map(\.note)
                == [36, 37, 38, 39, 40, 41, 42, 43])
        #expect(PadGridDrumMap.drumMachinePads(for: Self.drumMachine(.gm))?.map(\.note)
                == [36, 38, 42, 46, 39, 45, 37, 49])
        #expect(PadGridDrumMap.drumMachinePads(for: Self.drumMachine(.gm))?.map(\.label)
                == ["Kick", "Snare", "Closed Hat", "Open Hat", "Clap", "Tom", "Rim", "Cymbal"])
    }

    @Test("a never-configured drum machine (nil kit) is the factory kit: pads layout")
    func nilKitIsTheFactoryKit() {
        let bare = InstrumentDescriptor(kind: .drumSynth)
        #expect(PadGridDrumMap.drumMachinePads(for: bare)?.map(\.note)
                == [36, 37, 38, 39, 40, 41, 42, 43])
    }

    @Test("everything that is not our drum machine gets NO map — the grid keeps its arithmetic")
    func onlyTheDrumMachineHasAMap() {
        #expect(PadGridDrumMap.drumMachinePads(for: nil) == nil)
        #expect(PadGridDrumMap.drumMachinePads(for: InstrumentDescriptor(kind: .polySynth)) == nil)
        #expect(PadGridDrumMap.drumMachinePads(for: InstrumentDescriptor(kind: .testTone)) == nil)
        #expect(PadGridDrumMap.drumMachinePads(
            for: InstrumentDescriptor(kind: .sampler, sampler: SamplerParams())) == nil)
        // ⚠️ The GM SOUND BANK has drum ROWS (17 of them) but no drum-machine
        // pads: design §7 scopes this item to `.drumSynth`. Control: it really
        // is a drum instrument to the lane map.
        let gmKit = InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                       bankMSB: GMProgramCatalog.percussionBankMSB))
        #expect(DrumLaneMap.lanes(for: gmKit) != nil, "control: the GM kit has drum rows")
        #expect(PadGridDrumMap.drumMachinePads(for: gmKit) == nil)
    }

    // MARK: - P2: the choke glyph follows the GROUP

    /// ⭐ P2 (design §9 m39-w4-8): the link shows on exactly the pads whose
    /// RESOLVED choke group matches. Three fixtures, one per way it can lie.
    @Test("⭐ P2 — the choke link follows the resolved GROUP, not the drum's name")
    func chokeLinkFollowsTheGroup() throws {
        func linkGroups(_ instrument: InstrumentDescriptor) throws -> [Int?] {
            let pads = try #require(PadGridDrumMap.drumMachinePads(for: instrument))
            return PadGridDrumMap.chokeLinks(groups: pads.map(\.chokeGroup),
                                             names: pads.map(\.label),
                                             keys: pads.map(\.note)).map { $0?.group }
        }
        // 1. The factory kit: the two hats, group 0, nothing else.
        #expect(try linkGroups(Self.drumMachine(.gm))
                == [nil, nil, 0, 0, nil, nil, nil, nil])
        // 2. The hat choke CLEARED (a user's edit, stored as nil): no link
        //    anywhere — the open hat alone in group 0 cuts nothing.
        #expect(try linkGroups(Self.drumMachine(.gm) { $0.closedHat.chokeGroup = nil })
                == [nil, nil, nil, nil, nil, nil, nil, nil])
        // 3. Clap and rim put in group 3: they link, the hats keep theirs.
        #expect(try linkGroups(Self.drumMachine(.pads) {
            $0.clap.chokeGroup = 3
            $0.rim.chokeGroup = 3
        }) == [nil, nil, 0, 0, 3, nil, 3, nil])
        // The partners are named in the pads' own words.
        let pads = try #require(PadGridDrumMap.drumMachinePads(for: Self.drumMachine(.gm)))
        let links = PadGridDrumMap.chokeLinks(groups: pads.map(\.chokeGroup),
                                              names: pads.map(\.label), keys: pads.map(\.note))
        #expect(links[2]?.partners == ["Open Hat"])
        #expect(links[3]?.partners == ["Closed Hat"])
        #expect(links[2]?.sentence
                == "Linked with Open Hat: these cut each other off, like a real hi-hat.")
    }

    @Test("a member alone in its group, or sharing it only with layers on its own note, shows no link")
    func loneOrSameNoteMembersAreNotLinked() {
        let links = PadGridDrumMap.chokeLinks(
            groups: [5, 7, 7, 9, 9, 9],
            names: ["A", "B", "B-layer", "C", "D", "E"],
            keys: [36, 38, 38, 40, 41, 42])
        #expect(links[0] == nil)                       // alone in group 5
        #expect(links[1] == nil && links[2] == nil)    // group 7 is one note, layered
        #expect(links[3]?.partners == ["D", "E"])
        #expect(links[4]?.sentence
                == "Linked with C and E: these cut each other off, like a real hi-hat.")
        #expect(PadGridDrumMap.list(["A", "B", "C"]) == "A, B and C")
    }

    // MARK: - Role labels for a kit-sorted chop

    private static func zone(_ note: Int, role: DrumVoice?, choke: Int? = nil) -> SamplerZone {
        SamplerZone(audioFileURL: URL(fileURLWithPath: "/tmp/loop.wav"),
                    rootPitch: note, minPitch: note, maxPitch: note,
                    startFrame: note * 100, endFrame: note * 100 + 90,
                    chokeGroup: choke, drumRole: role)
    }

    @Test("a kit-sorted chop's pads read the STEP GRID's row labels, note for note")
    func sortedKitLabelsAreTheLaneLabels() throws {
        // `KitSliceLayout`'s shape: kicks 36/35, snares 38/40, hats 42/46, others 84+.
        let zones = [Self.zone(42, role: .closedHat, choke: 0), Self.zone(36, role: .kick),
                     Self.zone(38, role: .snare), Self.zone(46, role: .openHat, choke: 0),
                     Self.zone(35, role: .kick), Self.zone(84, role: nil),
                     Self.zone(40, role: .snare), Self.zone(85, role: nil)]
        let labels = PadGridDrumMap.samplerDrumLabels(zones: zones)
        #expect(labels == [36: "Kick", 35: "Kick 2", 38: "Snare", 40: "Snare 2",
                           42: "Closed Hat", 46: "Open Hat", 84: "Other", 85: "Other 2"])
        // ONE HOME: exactly what `DrumLaneMap` gives the step grid's rows.
        let lanes = try #require(DrumLaneMap.lanes(
            for: InstrumentDescriptor(kind: .sampler, sampler: SamplerParams(zones: zones))))
        #expect(Dictionary(uniqueKeysWithValues: lanes.map { ($0.note, $0.label) }) == labels)
    }

    @Test("a plain (chromatic) chop has NO drum labels — it draws what it drew before")
    func plainChopHasNoLabels() {
        let zones = (0..<8).map { Self.zone(36 + $0, role: nil) }
        #expect(PadGridDrumMap.samplerDrumLabels(zones: zones).isEmpty)
        #expect(PadGridDrumMap.samplerDrumLabels(zones: []).isEmpty)
    }
}
