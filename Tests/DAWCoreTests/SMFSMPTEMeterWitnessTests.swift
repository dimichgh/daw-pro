import Foundation
import Testing
@testable import DAWCore

/// m23-k4a G16 / D-SMPTE — the fixture that WITNESSES m23-k3's one unwitnessed
/// conclusion: that a SMPTE-division file's METER survives import.
///
/// k3 could only assert that from a hand-built IR, because the shipped fixture
/// set carries no `FF 58` on a SMPTE file. This suite closes the gap in two
/// steps, and BOTH are needed:
///
/// 1. `hazard-smpte-meter.mid` is a checked-in byte fixture, hand-derived in the
///    m23-k4a design (§9.3) and pinned at
///    `f6eea5727a18dc65a8e4ccbf396933e9fc6d2962e072e510ea6fc067642a72a1`. Apple's
///    `MusicSequenceFileLoad` was run against exactly these bytes during that
///    design read and ACCEPTED them (status 0), reporting
///    `META type=0x58 len=4 payload=03 02 18 08` on the tempo track.
/// 2. This suite asserts that OUR writer produces those bytes from the IR. That
///    assertion is the whole point: without it Apple arbitrated a hand-authored
///    blob rather than the artifact DAW Pro ships, and the leg would witness
///    nothing about k4a. **If the bytes ever differ, THAT DIFFERENCE IS THE
///    FINDING — report it and re-flag the leg; do not adjust the fixture to
///    match the writer.**
///
/// **What Apple CONFIRMED, and what it did not** — copied into
/// `Fixtures/SMF/README.md`'s "Apple-confirmed / spec-asserted" column verbatim,
/// because getting this wrong is how a leg drifts into claiming more than it
/// proves:
/// - *Apple-confirmed:* the file is a valid SMF; a `0xE728` division does not
///   prevent parsing; the `FF 58` payload bytes are present and readable.
/// - *NOT Apple-confirmed, spec/design-asserted:* any TIMING. Every timestamp
///   comes back `-0.0` and the note duration `0.0` — Apple's beat-native model
///   collapses SMPTE absolute time. So "the note lands at 2.0 beats through the
///   project tempo map" remains OUR claim alone, and is gated below against our
///   own mapper, not against Apple.
@MainActor
@Suite("SMPTE division x meter — the m23-k4a byte witness (G16)")
struct SMFSMPTEMeterWitnessTests {

    /// The IR the fixture encodes: 25 fps x 40 ticks/frame = 1000 ticks/second,
    /// a conductor carrying a name + 500000 µs/qn + 3/4, and one 1000-tick note.
    static func witnessIR() -> StandardMIDIFile {
        StandardMIDIFile(
            format: .simultaneousTracks,
            division: .smpte(framesPerSecond: 25, ticksPerFrame: 40),
            tracks: [
                SMFTrack(name: "Conductor", sourceTrackIndex: 0, channels: [],
                         notes: [], controllers: [], endTick: 1000),
                SMFTrack(name: "Lead", sourceTrackIndex: 1, channels: [0],
                         notes: [SMFNote(tick: 0, lengthTicks: 1000, note: 60,
                                         velocity: 100, releaseVelocity: 64, channel: 0)],
                         controllers: [], endTick: 1000),
            ],
            tempoChanges: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                         sourceTrackIndex: 0)],
            timeSignatures: [SMFTimeSignatureEvent(tick: 0, numerator: 3, denominatorPower: 2,
                                                   clocksPerMetronomeClick: 24,
                                                   thirtySecondNotesPerQuarter: 8,
                                                   sourceTrackIndex: 0)],
            warnings: [])
    }

    @Test("G16a: our writer produces the checked-in fixture BYTE FOR BYTE")
    func writerProducesTheFixture() throws {
        let encoded = try StandardMIDIFileWriter.encode(Self.witnessIR())
        let fixture = try StandardMIDIFileMapperTests.fixtureData("hazard-smpte-meter")
        #expect(encoded == fixture)
        #expect(fixture.count == 84)
        // The header word: bit 15 SET, high byte = -25 in two's complement.
        #expect(Array(fixture[12 ... 13]) == [0xE7, 0x28])
        // The `FF 58 04 03 02 18 08` Apple read back.
        let signature: [UInt8] = [0xFF, 0x58, 0x04, 0x03, 0x02, 0x18, 0x08]
        let bytes = Array(fixture)
        #expect(bytes.indices.contains { index in
            index + signature.count <= bytes.count
                && Array(bytes[index ..< index + signature.count]) == signature
        })
    }

    @Test("G16b: the fixture's meter is adopted, and its tempo map is NOT")
    func meterSurvivesSMPTEImport() throws {
        let file = try StandardMIDIFileMapperTests.decodeFixture("hazard-smpte-meter")
        #expect(file.division == .smpte(framesPerSecond: 25, ticksPerFrame: 40))
        #expect(file.timeSignatures.map(\.numerator) == [3])

        let plan = try SMFProjectMapper.map(
            file,
            options: MIDIImportOptions(atBeat: 0, tempoPolicy: .adopt),
            context: MIDIImportContext(projectHasClips: false,
                                       currentTempoMap: TempoMap(constantBPM: 120),
                                       currentMeterMap: MeterMap(constant: TimeSignature())))

        #expect(plan.report.resolvedTempoPolicy == "adopt")
        // A SMPTE file has no beat-native tempo map to hand over — the tempo
        // half degrades, and it says so.
        #expect(plan.report.tempoAdoptionDegradedToIgnore == true)
        // …while the METER half survives, which is exactly the conclusion m23-k3
        // could only assert from a hand-built IR.
        #expect(plan.report.meterChangesAdopted == 1)
        let meter = try #require(plan.meterMap)
        #expect(meter.changes.count == 1)
        #expect(meter.changes[0].beatsPerBar == 3)
        #expect(meter.changes[0].beatUnit == 4)
    }

    /// OUR claim, gated against OUR mapper — never against Apple, whose loader
    /// returns `-0.0` for every timestamp in this file.
    @Test("G16c: the note's beat comes from the PROJECT's tempo map (our claim, not Apple's)")
    func absoluteTimeGoesThroughTheProjectTempo() throws {
        let file = try StandardMIDIFileMapperTests.decodeFixture("hazard-smpte-meter")
        // 1000 ticks = 1.0 s; at 120 BPM that is 2.0 beats.
        let atOneTwenty = SMFTickClock(division: file.division,
                                       tempoMap: TempoMap(constantBPM: 120))
        #expect(atOneTwenty.beats(tick: 1000) == 2.0)
        #expect(atOneTwenty.ticks(beat: 2.0) == 1000)
        // …and at 60 BPM the SAME tick is 1.0 beat, which is what absolute time
        // MEANS and is why export never emits a SMPTE division.
        let atSixty = SMFTickClock(division: file.division,
                                   tempoMap: TempoMap(constantBPM: 60))
        #expect(atSixty.beats(tick: 1000) == 1.0)
        #expect(atSixty.ticks(beat: 1.0) == 1000)
    }
}
