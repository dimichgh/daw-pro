import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m39-w4-2 — the step grid reads `DrumLaneMap` (design
/// `docs/design/2026-10-07-loop-drum-depth.md` §3.2–§3.3, §9.2).
///
/// Three claims, each pinned separately:
///  - I1, INVARIANCE: a General MIDI percussion bank and a melodic track get
///    exactly the rows they got before, pinned against a VERBATIM frozen copy
///    of the function this item replaced (not against the new code's own
///    forwarding wrapper, which would be a tautology).
///  - Our drum machine gets its own eight rows, kick at the bottom, in BOTH
///    note layouts (hand-typed goldens).
///  - The editor-mode feed: a `pads` drum machine opens in STEPS.
///
/// Deliberately NOT `@MainActor`: every function here is a pure static.
@Suite("Step sequencer — drum lanes from the lane map (m39-w4-2)")
struct StepSequencerDrumLaneTests {

    // MARK: - The frozen oracle (today's function, copied verbatim on 2026-10-07)

    /// `StepSequencerLanes.lanes(isDrumKit:notes:)` as it stood at `e7e4d24`
    /// before m39-w4-2, with `melodicWindow` inlined as its literal 48...71.
    static func frozenLanes(isDrumKit: Bool, notes: [MIDINote]) -> [StepSequencerLane] {
        var pitches = Set(notes.map(\.pitch))
        if isDrumKit {
            pitches.formUnion(InstrumentFamilyResolver.percussionNotes.map(\.note))
        } else {
            pitches.formUnion(48...71)
        }
        return pitches.sorted(by: >).map { pitch in
            let named = isDrumKit ? InstrumentFamilyResolver.percussionNote(pitch) : nil
            return StepSequencerLane(
                pitch: pitch,
                label: named?.gmName ?? Fundamental.noteName(midiNote: pitch),
                isNamedPercussion: named != nil)
        }
    }

    // MARK: - Fixtures

    static func notes(_ pitches: [Int]) -> [MIDINote] {
        pitches.enumerated().map { index, pitch in
            MIDINote(pitch: pitch, startBeat: Double(index) * 0.25, lengthBeats: 0.25)
        }
    }

    /// Empty, an uncovered GM note (39), a kick/snare/hat beat, a note two
    /// octaves up, the whole GM range, the two extremes, a chord, the window.
    static let noteFixtures: [[Int]] = [
        [], [39], [36, 38, 42], [90], Array(35...81), [0, 127], [60, 64, 67], Array(48...71),
    ]

    static let gmBank = InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                   bankMSB: GMProgramCatalog.percussionBankMSB))

    static func drumMachine(_ layout: DrumNoteLayout?) -> InstrumentDescriptor {
        guard let layout else { return InstrumentDescriptor(kind: .drumSynth) }
        return InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams(noteLayout: layout))
    }

    static func track(_ instrument: InstrumentDescriptor?) -> Track {
        Track(name: "Lane", kind: .instrument, clips: [], instrument: instrument)
    }

    static let songGrid = PianoRollSongGrid.Context(
        clipStartBeat: 0, meterMap: MeterMap(constant: TimeSignature(beatsPerBar: 4)))

    // MARK: - I1: GM bank and melodic rows are unchanged

    @Test("I1: a GM percussion bank and a melodic track get exactly the rows they got before")
    func gmBankAndMelodicRowsAreUnchanged() {
        let gm = DrumLaneMap.lanes(for: Self.gmBank)
        let melodic = DrumLaneMap.lanes(for: InstrumentDescriptor())
        #expect(gm != nil)
        #expect(melodic == nil)
        for pitches in Self.noteFixtures {
            let notes = Self.notes(pitches)
            let oldDrum = Self.frozenLanes(isDrumKit: true, notes: notes)
            let oldMelodic = Self.frozenLanes(isDrumKit: false, notes: notes)
            #expect(StepSequencerLanes.lanes(drumLanes: gm, notes: notes) == oldDrum,
                    "GM bank rows moved for \(pitches)")
            #expect(StepSequencerLanes.lanes(drumLanes: melodic, notes: notes) == oldMelodic,
                    "melodic rows moved for \(pitches)")
            // The forwarding Bool form keeps its old answer too.
            #expect(StepSequencerLanes.lanes(isDrumKit: true, notes: notes) == oldDrum)
            #expect(StepSequencerLanes.lanes(isDrumKit: false, notes: notes) == oldMelodic)
            // And the geometry draws those rows, opening a drum grid at the bottom.
            let drumGeometry = StepSequencerGeometry.make(
                drumLanes: gm, notes: notes, clipLengthBeats: 4, resolution: .sixteenth,
                songGrid: Self.songGrid)
            #expect(drumGeometry.lanes == oldDrum)
            #expect(drumGeometry.opensAtBottom)
            let melodicGeometry = StepSequencerGeometry.make(
                drumLanes: melodic, notes: notes, clipLengthBeats: 4, resolution: .sixteenth,
                songGrid: Self.songGrid)
            #expect(melodicGeometry.lanes == oldMelodic)
            #expect(!melodicGeometry.opensAtBottom)
        }
    }

    // MARK: - Our drum machine's own rows

    @Test("a pads drum machine's grid reads Kick to Cymbal, kick at the bottom, every row named")
    func padsDrumMachineRows() {
        let lanes = StepSequencerLanes.lanes(
            drumLanes: DrumLaneMap.lanes(for: Self.drumMachine(.pads)), notes: [])
        // Row 0 is the TOP row (high pitch first, the piano roll's axis).
        #expect(lanes.map(\.pitch) == [43, 42, 41, 40, 39, 38, 37, 36])
        #expect(lanes.map(\.label) == ["Cymbal", "Rim", "Tom", "Clap", "Open Hat",
                                       "Closed Hat", "Snare", "Kick"])
        #expect(lanes.allSatisfy { $0.isNamedPercussion })
        // A never-configured drum machine is the same grid.
        #expect(StepSequencerLanes.lanes(
            drumLanes: DrumLaneMap.lanes(for: Self.drumMachine(nil)), notes: []) == lanes)
    }

    @Test("a gm drum machine's grid sits on the General MIDI notes, kick at the bottom")
    func gmDrumMachineRows() {
        let lanes = StepSequencerLanes.lanes(
            drumLanes: DrumLaneMap.lanes(for: Self.drumMachine(.gm)), notes: [])
        #expect(lanes.map(\.pitch) == [49, 46, 45, 42, 39, 38, 37, 36])
        #expect(lanes.map(\.label) == ["Cymbal", "Open Hat", "Tom", "Closed Hat", "Clap",
                                       "Snare", "Rim", "Kick"])
        #expect(lanes.allSatisfy { $0.isNamedPercussion })
    }

    @Test("a note outside the drum machine's rows still gets a row, named by its note")
    func presentNoteOutsideTheMapStillGetsARow() {
        let lanes = StepSequencerLanes.lanes(
            drumLanes: DrumLaneMap.lanes(for: Self.drumMachine(.pads)),
            notes: Self.notes([50, 36]))
        #expect(lanes.count == 9)
        let stray = lanes.first { $0.pitch == 50 }
        #expect(stray?.label == "D3")
        #expect(stray?.isNamedPercussion == false)
        #expect(lanes.first?.pitch == 50)   // highest pitch on top
        #expect(lanes.last?.label == "Kick")
    }

    // MARK: - The editor-mode feed

    @Test("a pads drum machine opens in STEPS; the old export predicate opened it in the piano roll")
    func padsDrumMachineOpensInSteps() {
        for instrument in [Self.drumMachine(.pads), Self.drumMachine(nil), Self.drumMachine(.gm),
                           Self.gmBank] {
            #expect(ClipEditorModePolicy.resolve(
                override: nil, isDrumKit: DrumLaneMap.lanes(for: instrument) != nil) == .steps,
                "\(instrument.kind) did not open in steps")
        }
        // The C14 defect this item fixes, shown with the predicate it replaced.
        #expect(ClipEditorModePolicy.resolve(
            override: nil,
            isDrumKit: SMFProjectExporter.isDrumKit(Self.track(Self.drumMachine(.pads)))) == .notes)
        // A melodic track still opens in the piano roll, and the user's pick wins.
        #expect(ClipEditorModePolicy.resolve(
            override: nil, isDrumKit: DrumLaneMap.lanes(for: InstrumentDescriptor()) != nil) == .notes)
        #expect(ClipEditorModePolicy.resolve(
            override: .notes,
            isDrumKit: DrumLaneMap.lanes(for: Self.drumMachine(.pads)) != nil) == .notes)
        // The geometry opens a drum machine's grid at the bottom, like a GM kit.
        #expect(StepSequencerGeometry.make(
            drumLanes: DrumLaneMap.lanes(for: Self.drumMachine(.pads)), notes: [],
            clipLengthBeats: 4, resolution: .sixteenth, songGrid: Self.songGrid).opensAtBottom)
    }
}
