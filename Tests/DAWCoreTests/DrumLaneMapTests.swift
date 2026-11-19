import Foundation
import Testing
@testable import DAWCore

/// m39-w4-2 — `DrumLaneMap`, the one home for "which rows does a drum
/// instrument have", and `DrumVoice.primaryNote(in:)`.
/// `docs/design/2026-10-07-loop-drum-depth.md` §3.2–§3.3 and §9.2.
///
/// The goldens below are HAND-TYPED on purpose. Derived expectations (from
/// `primaryNote`, `voice(forNote:)` or `displayName`) would move with a wrong
/// edit and stay green; a literal list is the one thing that notices.
///
/// Deliberately NOT `@MainActor`: everything here is a pure value type.
@Suite("Drum lane map (m39-w4-2)")
struct DrumLaneMapTests {

    // MARK: - Fixtures

    static func drumMachine(_ layout: DrumNoteLayout?) -> InstrumentDescriptor {
        guard let layout else { return InstrumentDescriptor(kind: .drumSynth) }
        return InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams(noteLayout: layout))
    }

    static func bank(msb: Int, source: SoundBankSource = .generalMIDI) -> InstrumentDescriptor {
        InstrumentDescriptor(kind: .soundBank,
                             soundBank: SoundBankConfig(source: source, program: 0, bankMSB: msb))
    }

    static func track(_ instrument: InstrumentDescriptor?, notes: [MIDINote] = []) -> Track {
        Track(name: "Lane", kind: .instrument,
              clips: notes.isEmpty ? [] : [Clip(name: "Beat", startBeat: 0, lengthBeats: 4,
                                                notes: notes)],
              instrument: instrument)
    }

    /// (note, label, voice) — the shape a golden is compared in.
    static func triples(_ lanes: [DrumLane]?) -> [String] {
        (lanes ?? []).map { "\($0.note) \($0.label) \($0.voice?.rawValue ?? "-")" }
    }

    // MARK: - P2: primaryNote round-trips through the one note map

    @Test("P2: voice(forNote: primaryNote(in: l), layout: l) == voice, for all 8 voices in both layouts")
    func primaryNoteRoundTrips() {
        for layout in DrumNoteLayout.allCases {
            for voice in DrumVoice.allCases {
                let note = voice.primaryNote(in: layout)
                #expect(DrumVoice.voice(forNote: note, layout: layout) == voice,
                        "\(voice) at \(note) in \(layout) plays something else")
            }
        }
        // In pads the primary note IS the voice's one note.
        for voice in DrumVoice.allCases {
            #expect(voice.primaryNote(in: .pads) == voice.note)
        }
        #expect(DrumVoice.allCases.count == 8)
    }

    // MARK: - Goldens (hand-typed)

    @Test("golden: a pads drum machine has 8 rows, 36 to 43, in voice order")
    func padsGolden() {
        #expect(Self.triples(DrumLaneMap.lanes(for: Self.drumMachine(.pads))) == [
            "36 Kick kick", "37 Snare snare", "38 Closed Hat closedHat", "39 Open Hat openHat",
            "40 Clap clap", "41 Tom tom", "42 Rim rim", "43 Cymbal cymbal",
        ])
    }

    @Test("golden: a gm drum machine has 8 rows on the General MIDI notes")
    func gmGolden() {
        #expect(Self.triples(DrumLaneMap.lanes(for: Self.drumMachine(.gm))) == [
            "36 Kick kick", "38 Snare snare", "42 Closed Hat closedHat", "46 Open Hat openHat",
            "39 Clap clap", "45 Tom tom", "37 Rim rim", "49 Cymbal cymbal",
        ])
    }

    @Test("a never-configured drum machine is the factory kit, which is pads")
    func factoryDrumMachineIsPads() {
        let factory = DrumLaneMap.lanes(for: Self.drumMachine(nil))
        #expect(factory != nil)
        #expect(factory == DrumLaneMap.lanes(for: Self.drumMachine(.pads)))
    }

    @Test("the General MIDI percussion bank keeps its 17 rows and names, unchanged")
    func generalMIDIBankKeepsItsRows() throws {
        let lanes = try #require(DrumLaneMap.lanes(for: Self.bank(msb: GMProgramCatalog.percussionBankMSB)))
        #expect(lanes.count == 17)
        #expect(lanes.map(\.note) == InstrumentFamilyResolver.percussionNotes.map(\.note))
        #expect(lanes.map(\.label) == InstrumentFamilyResolver.percussionNotes.map(\.gmName))
        #expect(lanes.allSatisfy { $0.voice == nil })
        // Pinned verbatim so a silent re-label of the table is visible here.
        #expect(lanes.first { $0.note == 35 }?.label == "Acoustic Bass Drum")
        #expect(lanes.first { $0.note == 36 }?.label == "Bass Drum 1")
        #expect(lanes.first { $0.note == 38 }?.label == "Acoustic Snare")
        #expect(lanes.first { $0.note == 59 }?.label == "Ride Cymbal 2")
        // An SF2 on bank 120 is a drum kit too (kind-gated, not source-gated).
        #expect(DrumLaneMap.lanes(for: Self.bank(msb: GMProgramCatalog.percussionBankMSB,
                                                 source: .file(path: "/x/kit.sf2"))) == lanes)
        #expect(DrumLaneMap.generalMIDIPercussionLanes == lanes)
    }

    @Test("everything that is not a drum instrument has no drum rows")
    func nonDrumInstrumentsHaveNoRows() {
        #expect(DrumLaneMap.lanes(for: nil) == nil)
        #expect(DrumLaneMap.lanes(for: InstrumentDescriptor()) == nil)            // poly synth
        #expect(DrumLaneMap.lanes(for: InstrumentDescriptor(kind: .testTone)) == nil)
        #expect(DrumLaneMap.lanes(for: InstrumentDescriptor(kind: .sampler)) == nil)
        #expect(DrumLaneMap.lanes(for: InstrumentDescriptor(kind: .audioUnit)) == nil)
        #expect(DrumLaneMap.lanes(for: Self.bank(msb: GMProgramCatalog.melodicBankMSB)) == nil)
        #expect(DrumLaneMap.lanes(for: InstrumentDescriptor(kind: .soundBank)) == nil)
        // The kind is what is heard: a gm kit carried under the poly synth is not a kit.
        #expect(DrumLaneMap.lanes(for: InstrumentDescriptor(
            kind: .polySynth, drumKit: DrumKitParams(noteLayout: .gm))) == nil)
    }

    // MARK: - Two questions, two predicates

    @Test("the lane map agrees with SMFProjectExporter.isDrumKit on every sound bank, and differs on a pads drum machine")
    func agreesWithTheExportPredicateWhereItMust() {
        let banks: [InstrumentDescriptor] = [
            Self.bank(msb: GMProgramCatalog.percussionBankMSB),
            Self.bank(msb: GMProgramCatalog.melodicBankMSB),
            Self.bank(msb: GMProgramCatalog.percussionBankMSB, source: .file(path: "/x/kit.sf2")),
            Self.bank(msb: 7),
            InstrumentDescriptor(kind: .soundBank),
        ]
        for instrument in banks {
            #expect((DrumLaneMap.lanes(for: instrument) != nil)
                    == SMFProjectExporter.isDrumKit(Self.track(instrument)),
                    "the two predicates drifted on \(String(describing: instrument.soundBank))")
        }
        // The deliberate disagreement (design §3.3): a pads drum machine HAS
        // drum rows but is NOT a General MIDI kit, so it must not export on
        // channel 10.
        let pads = Self.drumMachine(.pads)
        #expect(DrumLaneMap.lanes(for: pads) != nil)
        #expect(SMFProjectExporter.isDrumKit(Self.track(pads)) == false)
        let gm = Self.drumMachine(.gm)
        #expect(DrumLaneMap.lanes(for: gm) != nil)
        #expect(SMFProjectExporter.isDrumKit(Self.track(gm)))
    }

    // MARK: - I2: MIDI export channels are unchanged

    @Test("I2: MIDI export channel assignment is unchanged for every fixture track")
    func exportChannelsAreUnchanged() throws {
        let beat = [MIDINote(pitch: 36, velocity: 100, startBeat: 0, lengthBeats: 0.25),
                    MIDINote(pitch: 38, velocity: 100, startBeat: 1, lengthBeats: 0.25)]
        let tracks = [
            Self.track(InstrumentDescriptor(), notes: beat),                                  // melodic
            Self.track(Self.bank(msb: GMProgramCatalog.percussionBankMSB), notes: beat),      // GM kit
            Self.track(Self.drumMachine(.pads), notes: beat),                                 // pads DM
            Self.track(Self.drumMachine(.gm), notes: beat),                                   // gm DM
            Self.track(InstrumentDescriptor(kind: .sampler), notes: beat),                    // sampler
        ]
        let plan = try SMFProjectExporter.map(
            tracks: tracks, projectName: "w42", tempoMap: TempoMap(constantBPM: 120),
            meterMap: MeterMap(constant: TimeSignature()), options: MIDIExportOptions())
        // Hand-typed: drum kits on 9, everything else on the melodic channels
        // in order. A pads drum machine has drum ROWS but stays melodic here.
        #expect(plan.report.tracks.map(\.channel) == [0, 9, 1, 9, 2])
    }
}
