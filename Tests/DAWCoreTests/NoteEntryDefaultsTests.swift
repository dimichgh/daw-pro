import Foundation
import Testing
@testable import DAWCore

/// m39-w4-3 — `NoteEntryDefaults`, the ONE home for the velocity a hand-entered
/// note is born at. `docs/design/2026-10-07-loop-drum-depth.md` §3.4 and §9.2.
///
/// The gates hold a FIXTURE drum constant of 80. At the shipped 100 the drum and
/// melodic answers coincide, so a test at 100 cannot tell "reads the lane map"
/// from "reads nothing at all"; at 80 it can.
///
/// Deliberately NOT `@MainActor`: everything here is a pure value type.
@Suite("Note entry defaults (m39-w4-3)")
struct NoteEntryDefaultsTests {

    // MARK: - Fixtures

    static let fixture = NoteEntryDefaults.Values(drumVelocity: 80)

    static func drumMachine(_ layout: DrumNoteLayout?) -> InstrumentDescriptor {
        guard let layout else { return InstrumentDescriptor(kind: .drumSynth) }
        return InstrumentDescriptor(kind: .drumSynth, drumKit: DrumKitParams(noteLayout: layout))
    }

    static func bank(msb: Int) -> InstrumentDescriptor {
        InstrumentDescriptor(kind: .soundBank,
                             soundBank: SoundBankConfig(source: .generalMIDI, program: 0, bankMSB: msb))
    }

    static func track(_ instrument: InstrumentDescriptor?) -> Track {
        Track(name: "Entry", kind: .instrument, clips: [], instrument: instrument)
    }

    /// (name, instrument, has drum rows) — every fixture both gates walk.
    static let fixtures: [(String, InstrumentDescriptor?, Bool)] = [
        ("drum machine, default (pads) layout", drumMachine(nil), true),
        ("drum machine, pads layout", drumMachine(.pads), true),
        ("drum machine, gm layout", drumMachine(.gm), true),
        ("GM percussion bank 120", bank(msb: GMProgramCatalog.percussionBankMSB), true),
        ("GM melodic bank 121", bank(msb: 121), false),
        ("poly synth", InstrumentDescriptor(), false),
        ("sampler", InstrumentDescriptor(kind: .sampler), false),
        ("test tone", InstrumentDescriptor(kind: .testTone), false),
        ("no instrument", nil, false),
    ]

    // MARK: - N1: the shipped constants

    /// The three numbers the design fixes (§3.4). `drumVelocity` stays 100 until
    /// the user's L1 pick (`decisions/drums-w4`, field `L1`): when that pick
    /// lands, THIS pin moves with the one constant, on purpose.
    @Test("The shipped entry velocities are the design's: melodic 100, drum 100 (L1 pending), accent 127")
    func shippedConstantsAreTheDesignValues() {
        #expect(NoteEntryDefaults.melodicVelocity == 100)
        #expect(NoteEntryDefaults.drumVelocity == 100)
        #expect(NoteEntryDefaults.accentVelocity == 127)
        #expect(NoteEntryDefaults.Values.shipped == NoteEntryDefaults.Values(
            melodicVelocity: 100, drumVelocity: 100, accentVelocity: 127))
        // The accent is the MIDI maximum, so it passes ANY drum-machine accent
        // threshold the kit can hold (1…127).
        #expect(NoteEntryDefaults.accentVelocity == MIDINote.velocityRange.upperBound)
        #expect(Double(NoteEntryDefaults.accentVelocity) >= DrumKitParams.accentThresholdRange.upperBound)
    }

    // MARK: - N2 (P1, the DAWCore half): the drum default follows the LANE MAP

    /// P1 with a fixture drum constant of 80: every track with drum rows mints
    /// 80, every other track 100. The pads drum machine is the row that tells
    /// the two predicates apart, and the "why" is pinned beside it:
    /// `SMFProjectExporter.isDrumKit` answers NO for it (it is not a General MIDI
    /// kit), so a drum default chosen through `isDrumKit` would hand our own
    /// drum machine the melodic velocity.
    @Test("A track with drum rows gets the drum default (fixture 80), every other track the melodic one")
    func drumDefaultFollowsTheLaneMapNotIsDrumKit() {
        for (name, instrument, hasRows) in Self.fixtures {
            let lanes = DrumLaneMap.lanes(for: instrument)
            #expect((lanes != nil) == hasRows, "fixture premise: \(name)")
            #expect(Self.fixture.velocity(drumLanes: lanes) == (hasRows ? 80 : 100), "\(name)")
            #expect(Self.fixture.velocity(hasDrumLanes: hasRows) == (hasRows ? 80 : 100), "\(name)")
        }
        // The "why", measured on the same fixture the gate reads.
        let pads = Self.drumMachine(nil)
        #expect(pads.resolvedDrumKit.noteLayout == .pads)
        #expect(SMFProjectExporter.isDrumKit(Self.track(pads)) == false)
        #expect(DrumLaneMap.lanes(for: pads) != nil)
        #expect(Self.fixture.velocity(drumLanes: DrumLaneMap.lanes(for: pads)) == 80)
    }

    // MARK: - N3 (I1, the DAWCore half): zero behaviour change at the shipped values

    @Test("At the shipped values every fixture mints 100, exactly as before the item")
    func shippedEntryVelocityIsHundredOnEveryFixture() {
        for (name, instrument, _) in Self.fixtures {
            let lanes = DrumLaneMap.lanes(for: instrument)
            #expect(NoteEntryDefaults.velocity(drumLanes: lanes) == 100, "\(name)")
            #expect(NoteEntryDefaults.Values.shipped.velocity(drumLanes: lanes) == 100, "\(name)")
        }
        #expect(NoteEntryDefaults.velocity(hasDrumLanes: true) == 100)
        #expect(NoteEntryDefaults.velocity(hasDrumLanes: false) == 100)
    }
}
