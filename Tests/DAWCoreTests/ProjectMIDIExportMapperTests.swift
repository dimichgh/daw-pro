import Foundation
import Testing
@testable import DAWCore

/// m23-k4a Step 2 — `SMFProjectExporter`, the headless export mapper.
///
/// Every mapping VERDICT is gated here against hand-built project values: no
/// `ProjectStore`, no undo journal, no disk. What is left for
/// `ProjectStoreMIDIExportTests` is exactly the store's own business — the dry
/// run's inertness, the destination policy, and the refusals.
///
/// **Every leg below names the mutation that reddens it.** A leg with no
/// discriminator is vacuous, and this chain has shipped several: on-grid beats
/// cannot separate `round` from `floor`/`trunc`/`ceil`, and round-tripping k3's
/// spine tempo 666666 µs/qn is verifiably vacuous under all four rules.
@Suite("SMF project export mapper (m23-k4a)")
struct ProjectMIDIExportMapperTests {

    // MARK: - Builders

    static func note(_ pitch: Int, _ start: Double, _ length: Double,
                     velocity: Int = 100) -> MIDINote {
        MIDINote(pitch: pitch, velocity: velocity, startBeat: start, lengthBeats: length)
    }

    static func midiClip(start: Double = 0, length: Double, notes: [MIDINote],
                         lanes: [MIDIControllerLane] = [],
                         gainDb: Double = 0, stretch: Double = 1) -> Clip {
        var clip = Clip(name: "Clip", startBeat: start, lengthBeats: length,
                        notes: notes, controllerLanes: lanes)
        clip.gainDb = gainDb
        clip.stretchRatio = stretch
        return clip
    }

    static func instrumentTrack(_ name: String, _ clips: [Clip],
                                instrument: InstrumentDescriptor? = nil,
                                muted: Bool = false, soloed: Bool = false) -> Track {
        Track(name: name, kind: .instrument, isMuted: muted, isSoloed: soloed,
              clips: clips, instrument: instrument)
    }

    static func export(_ tracks: [Track],
                       name: String = "Song",
                       tempoMap: TempoMap = TempoMap(constantBPM: 120),
                       meterMap: MeterMap = MeterMap(constant: TimeSignature()),
                       division: Int = MIDIExportOptions.defaultTicksPerQuarterNote,
                       format: SMFFormat = .simultaneousTracks,
                       trackIDs: [UUID]? = nil) throws -> MIDIExportPlan {
        try SMFProjectExporter.map(
            tracks: tracks, projectName: name, tempoMap: tempoMap, meterMap: meterMap,
            options: MIDIExportOptions(division: .ticksPerQuarterNote(division),
                                       format: format, trackIDs: trackIDs))
    }

    /// Encode, decode and map back onto the project model — the full round trip
    /// through the SHIPPED reader and the SHIPPED import mapper, not a private
    /// inverse written for the test.
    static func reimport(_ plan: MIDIExportPlan,
                         tempoPolicy: MIDITempoPolicy = .ignore) throws -> MIDIImportPlan {
        let bytes = try StandardMIDIFileWriter.encode(plan.file)
        let decoded = try StandardMIDIFileReader.decode(bytes)
        return try SMFProjectMapper.map(
            decoded,
            options: MIDIImportOptions(atBeat: 0, tempoPolicy: tempoPolicy),
            context: MIDIImportContext(projectHasClips: false,
                                       currentTempoMap: TempoMap(constantBPM: 120),
                                       currentMeterMap: MeterMap(constant: TimeSignature())))
    }

    /// Notes of the ONE exported part, in tick order.
    static func exportedNotes(_ plan: MIDIExportPlan, chunk: Int = 1) -> [SMFNote] {
        plan.file.tracks[chunk].notes
    }

    // MARK: - G1: off-grid round trip, with the rounding rule PINNED

    /// **G1 — the headline leg, replacing the roadmap's vacuous one.**
    ///
    /// The roadmap's original gate ("the exported project re-imports with the
    /// same notes") passes under `round`, `floor`, `trunc` AND `ceil` on every
    /// fixture in the repo, because their beats are exact integer multiples of
    /// the division. This one carries two beats that are not.
    ///
    /// Expectations are written as `Double(9601)/Double(9600)` — never as a
    /// decimal literal, and never recomputed through the function under test.
    ///
    /// **Honest limit:** `floor` and `trunc` are provably indistinguishable at
    /// non-negative beats, and every beat in the model is non-negative. This leg
    /// separates `round` from BOTH of them as a pair, and from `ceil`; it does
    /// not, and cannot, separate them from each other.
    @Test("G1: off-grid beats survive the round trip, and pin round over floor/trunc/ceil")
    func offGridRoundTripPinsTheRoundingRule() throws {
        let clip = Self.midiClip(length: 4, notes: [
            Self.note(48, 0, 0.5),           // on grid — cannot discriminate anything
            Self.note(60, 1.00006, 0.5),     // * 9600 = 9600.576 -> 9601
            Self.note(62, 1.00001, 0.5),     // * 9600 = 9600.096 -> 9600
            Self.note(50, 2, 0.5),           // on grid
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])

        let reimported = try Self.reimport(plan)
        let notes = try #require(reimported.tracks.first?.clip.notes)
        func beat(ofPitch pitch: Int) throws -> Double {
            try #require(notes.first { $0.pitch == pitch }).startBeat
        }

        #expect(try beat(ofPitch: 60) == Double(9601) / Double(9600))
        #expect(try beat(ofPitch: 62) == Double(9600) / Double(9600))
        #expect(try beat(ofPitch: 48) == 0)
        #expect(try beat(ofPitch: 50) == 2)

        // THE DISCRIMINATOR, made visible: `floor`/`trunc` would bring pitch 60
        // back at exactly 1.0, and `ceil` would bring pitch 62 back at
        // 9601/9600. Both expectations above would fail; the on-grid pair would
        // not notice.
        #expect(Double(9601) / Double(9600) != 1.0)

        // And the loss is REPORTED rather than silent — the whole D-OFFGRID
        // verdict in one line.
        #expect(plan.report.notesQuantized == 2)
        #expect(plan.report.maxQuantizationErrorBeats > 0)
        #expect(plan.report.maxQuantizationErrorBeats <= 0.5 / 9600 + 1e-12)
        #expect(plan.report.degradations.contains { $0.contains("nearest tick") })
    }

    // MARK: - G2: the length rule REVERSES

    /// **G2 — flush legato at an OFF-GRID boundary.**
    ///
    /// Mutation that reddens it: change `SMFTickClock.noteTicks` to
    /// independently-rounded lengths (`round(lengthBeats · t)`). Nothing else in
    /// this suite catches that — G1 and G11 both stay green.
    ///
    /// The boundary MUST be off-grid or the leg is vacuous: the two forms agree
    /// at every on-grid position.
    @Test("G2: flush legato survives — note-off tick == next note-on tick")
    func flushLegatoSurvives() throws {
        let start = 0.3000625            // * 9600 = 2880.6 -> 2881
        let length = 0.7000625           // * 9600 = 6720.6 -> 6721 INDEPENDENTLY
        let boundary = start + length    // * 9600 = 9601.2 -> 9601

        let clip = Self.midiClip(length: 4, notes: [
            Self.note(60, start, length),
            Self.note(60, boundary, 0.5),
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        let notes = Self.exportedNotes(plan)
        #expect(notes.count == 2)
        #expect(notes[0].tick == 2881)
        #expect(notes[0].tick + notes[0].lengthTicks == notes[1].tick)
        #expect(notes[1].tick == 9601)

        // The fixture DISCRIMINATES: the independent form gives 6721 here, so
        // the note-off would land at 9602, one tick PAST the next onset.
        #expect(Int((length * 9600).rounded()) == 6721)
        #expect(notes[0].lengthTicks == 6720)

        // Nothing was treated as an overlap, so no truncation was minted by the
        // rounding choice — which is the failure the independent form causes on
        // a SUBSEQUENT export.
        #expect(plan.report.overlappingSamePitchNotesTruncated == 0)

        // And it comes back as two notes whose boundary is still flush.
        let back = try #require(Self.reimport(plan).tracks.first?.clip.notes)
        #expect(back.count == 2)
        #expect(back[0].startBeat + back[0].lengthBeats == back[1].startBeat)
    }

    // MARK: - G3: same-pitch overlap

    /// **G3 —** the one place the FORMAT forces a change to authored content.
    ///
    /// Mutation that reddens it: emit the nested pair instead of truncating. The
    /// file still LOADS everywhere (Apple accepts it), and comes back with the
    /// two lengths SWAPPED, because every reader pairs FIFO. A leg that only
    /// asserted "two notes come back" would pass that broken implementation.
    @Test("G3: nested same-pitch notes are truncated, and re-import agrees")
    func samePitchOverlapTruncates() throws {
        let clip = Self.midiClip(length: 8, notes: [
            Self.note(60, 0, 4),
            Self.note(60, 1, 1),
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.report.overlappingSamePitchNotesTruncated == 1)
        #expect(plan.report.overlappingSamePitchNotesDropped == 0)

        let notes = Self.exportedNotes(plan)
        #expect(notes.map(\.tick) == [0, 9600])
        #expect(notes.map(\.lengthTicks) == [9600, 9600])

        let back = try #require(Self.reimport(plan).tracks.first?.clip.notes)
        #expect(back.count == 2)
        // NOT the swapped 4/1 (or 2/3) pair a nested emission produces.
        #expect(back.map(\.lengthBeats) == [1.0, 1.0])
        #expect(back.map(\.startBeat) == [0.0, 1.0])
    }

    @Test("G3b: two identical onsets on one pitch drop the shorter one")
    func samePitchIdenticalOnsetsDrop() throws {
        let clip = Self.midiClip(length: 8, notes: [
            Self.note(60, 0, 2),
            Self.note(60, 0, 1),
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.report.overlappingSamePitchNotesDropped == 1)
        #expect(plan.report.overlappingSamePitchNotesTruncated == 0)
        let notes = Self.exportedNotes(plan)
        #expect(notes.count == 1)
        // The LONGER survives: a drop should lose as little music as possible.
        #expect(notes[0].lengthTicks == 19200)
    }

    /// THREE onsets on one pitch at one tick. Pinned because the counter's
    /// semantics are not self-evident from the rule: `overlappingSamePitchNotesDropped`
    /// counts NOTES DROPPED (2 here), not drop EVENTS or collisions (1 pile-up).
    @Test("G3b2: three coincident onsets on one pitch leave the longest, and count TWO drops")
    func threeCoincidentOnsets() throws {
        let clip = Self.midiClip(length: 8, notes: [
            Self.note(60, 0, 1), Self.note(60, 0, 2), Self.note(60, 0, 3),
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.report.overlappingSamePitchNotesDropped == 2)
        #expect(plan.report.overlappingSamePitchNotesTruncated == 0)
        let notes = Self.exportedNotes(plan)
        #expect(notes.count == 1)
        #expect(notes[0].lengthTicks == 28800)
    }

    @Test("G3c: an onset exactly at the previous note's end is FLUSH, not overlapping")
    func flushIsNotOverlap() throws {
        let clip = Self.midiClip(length: 8, notes: [
            Self.note(60, 0, 1),
            Self.note(60, 1, 1),
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.report.overlappingSamePitchNotesTruncated == 0)
        #expect(plan.report.overlappingSamePitchNotesDropped == 0)
        #expect(Self.exportedNotes(plan).map(\.lengthTicks) == [9600, 9600])
    }

    // MARK: - G4/G5: tempo

    /// **G4 — the µs/quarter rounding rule.**
    ///
    /// The obvious leg is VACUOUS: `60e6 / (60e6/666666)` computes to EXACTLY
    /// 666666.0, so k3's spine tempo cannot separate `round`, `floor`, `ceil` or
    /// `trunc`. These two tempos can, and BOTH are needed — either alone leaves
    /// one rule alive.
    @Test("G4: 61 and 104 BPM pin round over floor/trunc/ceil for microseconds/quarter")
    func microsecondsPerQuarterRounding() throws {
        let map = try TempoMap(segments: [.init(startBeat: 0, bpm: 61),
                                          .init(startBeat: 4, bpm: 104)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [])], tempoMap: map)
        #expect(plan.file.tempoChanges.map(\.microsecondsPerQuarterNote) == [983607, 576923])

        // The fixture discriminates, proven in the leg:
        #expect((60_000_000.0 / 61).rounded(.down) == 983606)     // floor/trunc differ
        #expect((60_000_000.0 / 104).rounded(.up) == 576924)      // ceil differs

        // And the recorded vacuity of the obvious alternative, so nobody
        // "simplifies" this leg back to the spine fixture's tempo.
        let spine = 60_000_000.0 / (60_000_000.0 / 666_666.0)
        #expect(spine.rounded() == 666_666)
        #expect(spine.rounded(.down) == 666_666)
        #expect(spine.rounded(.up) == 666_666)
        #expect(spine.rounded(.towardZero) == 666_666)
    }

    /// **G5 —** D2's exactness holds in the direction IMPORT runs; the direction
    /// EXPORT runs is NOT exact, and the report says so.
    ///
    /// The first half is a CONTROL, not a discriminator: it re-runs k3's D2 in
    /// the µ → bpm → µ direction over the whole clamp window (sampled, not
    /// exhausted — 2.85 M iterations in a debug build would be mistaken for the
    /// known `EQCurveEditorModelTests` perf flake), including the measured worst
    /// case µ = 2,807,175 as a NAMED input.
    ///
    /// The DISCRIMINATOR is the second half: an implementation that reports
    /// `maxTempoRoundTripErrorBPM == 0` unconditionally passes the first half.
    @Test("G5: bpm -> microseconds -> bpm is inexact, and the report carries the number")
    func tempoRoundTripError() throws {
        // Control: the direction m23-k3 verified, still exact.
        var sampled = [2_807_175, 150_000, 3_000_000, 500_000, 666_666]
        sampled += stride(from: 150_000, through: 3_000_000, by: 7919)
        for micro in sampled {
            let bpm = 60_000_000.0 / Double(micro)
            #expect(Int((60_000_000.0 / bpm).rounded()) == micro, "mu=\(micro)")
        }

        // The discriminator: 140 BPM does NOT round-trip, 120 does.
        let inexact = try Self.export([Self.instrumentTrack("Lead", [])],
                                      tempoMap: TempoMap(constantBPM: 140))
        #expect(inexact.report.maxTempoRoundTripErrorBPM > 0)
        // 60e6/140 = 428571.428…, so the file stores 428571 and reads back as
        // 140.00014…. Tiny, and it moves ZERO notes — the spine has no tempo
        // term — but it is real, and the report is where it is visible instead
        // of being folklore.
        #expect(abs(inexact.report.maxTempoRoundTripErrorBPM - 0.00014000014) < 1e-9)
        #expect(inexact.file.tempoChanges[0].microsecondsPerQuarterNote == 428_571)

        let exact = try Self.export([Self.instrumentTrack("Lead", [])],
                                    tempoMap: TempoMap(constantBPM: 120))
        #expect(exact.report.maxTempoRoundTripErrorBPM == 0)
        #expect(exact.file.tempoChanges[0].microsecondsPerQuarterNote == 500_000)
    }

    @Test("two tempo segments that round onto one tick keep the first, and name the loser")
    func tempoCollisionAtOneTick() throws {
        // REACHABLE: `TempoMap.init` requires strictly increasing start beats
        // with NO minimum gap, so 1e-9 beats apart is a legal map.
        let map = try TempoMap(segments: [.init(startBeat: 0, bpm: 120),
                                          .init(startBeat: 1e-9, bpm: 90)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [])], tempoMap: map)
        #expect(plan.file.tempoChanges.count == 1)
        #expect(plan.file.tempoChanges[0].microsecondsPerQuarterNote == 500_000)
        #expect(plan.report.tempoSegmentsCollidingAtSameTick.count == 1)
        #expect(plan.report.tempoSegmentsCollidingAtSameTick[0].contains("90"))
    }

    // MARK: - G6: the conductor, and meter VERBATIM

    /// **G6 —** export is the IDENTITY of import for meter, gated from the
    /// export side.
    ///
    /// Mutation that reddens it: emit the meter TRANSLATED
    /// (`numerator = beatsPerBar · 4 / beatUnit`), which brings 6/8 back as 3/8
    /// or 12/8. This is m23-k3's §1.3 reversal, and the leg that proves the two
    /// halves are mutual inverses.
    @Test("G6: the conductor carries the whole tempo and meter map, verbatim")
    func conductorCarriesTheMaps() throws {
        let tempo = try TempoMap(segments: [.init(startBeat: 0, bpm: 120),
                                            .init(startBeat: 8, bpm: 90)])
        let meter = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 8, beatsPerBar: 6, beatUnit: 8),
            .init(startBeat: 14, beatsPerBar: 3, beatUnit: 4),
        ])
        let clip = Self.midiClip(length: 16, notes: [Self.note(60, 0, 1)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])],
                                   tempoMap: tempo, meterMap: meter)

        // Chunk 0 is the conductor: the project name, the maps, and NO notes.
        #expect(plan.file.tracks[0].name == "Song")
        #expect(plan.file.tracks[0].notes.isEmpty)
        #expect(plan.file.tracks[0].controllers.isEmpty)
        #expect(plan.file.tracks[0].channels.isEmpty)
        #expect(plan.file.tempoChanges.allSatisfy { $0.sourceTrackIndex == 0 })
        #expect(plan.file.timeSignatures.allSatisfy { $0.sourceTrackIndex == 0 })

        // VERBATIM, both fields.
        #expect(plan.file.timeSignatures.map(\.numerator) == [4, 6, 3])
        #expect(plan.file.timeSignatures.map(\.denominatorPower) == [2, 3, 2])
        #expect(plan.report.tempoSegmentsWritten == 2)
        #expect(plan.report.meterChangesWritten == 3)
        #expect(plan.report.substitutedDefaultMeterAtZero == false)

        // And it comes back EQUAL through the shipped importer.
        let back = try Self.reimport(plan, tempoPolicy: .adopt)
        let backMeter = try #require(back.meterMap)
        #expect(backMeter.changes.map(\.beatsPerBar) == [4, 6, 3])
        #expect(backMeter.changes.map(\.beatUnit) == [4, 8, 4])
        #expect(backMeter.changes.map(\.startBeat) == [0, 8, 14])
        let backTempo = try #require(back.tempoMap)
        #expect(backTempo.segments.map(\.startBeat) == [0, 8])
        // 120 BPM round-trips EXACTLY (500000 µs/qn); 90 does NOT — 60e6/90 is
        // 666666.67, the file stores 666667, and it reads back as 89.999955.
        // The report's own number is exactly that difference, which closes the
        // evidence chain: `maxTempoRoundTripErrorBPM` is not a formula, it is
        // what a re-import actually sees.
        #expect(backTempo.segments[0].bpm == 120)
        #expect(abs(backTempo.segments[1].bpm - 90) == plan.report.maxTempoRoundTripErrorBPM)
        #expect(plan.report.maxTempoRoundTripErrorBPM > 0)
    }

    /// The conductor is emitted UNCONDITIONALLY, so the chunk count is a
    /// function of the project's TRACK STRUCTURE and never of its content.
    @Test("a default 120 BPM / 4-4 project still gets a conductor chunk")
    func conductorIsUnconditional() throws {
        let plan = try Self.export([Self.instrumentTrack("Lead", [])])
        #expect(plan.file.tracks.count == 2)
        #expect(plan.file.tempoChanges.count == 1)
        #expect(plan.file.timeSignatures.count == 1)
    }

    // MARK: - G9: the vacuity guard

    /// **G9 — the leg that keeps every other leg honest.**
    ///
    /// A clean project must produce an all-zero/empty loss section and
    /// `degradations == []`, with NO exemption. Without it, a mapper that
    /// reports something on every project passes every hazard leg and the report
    /// becomes noise nobody reads.
    ///
    /// **Fixture constraint, and it is not optional:** the tracks must NOT carry
    /// GM sound-bank instruments, because every GM track increments
    /// `programChangesNotWritten` (the k2 gap — the byte-frozen writer does not
    /// emit `Cn`). `polySynth` is the default and is what is used here. When the
    /// k2 follow-up lands and program changes actually reach the bytes, this
    /// constraint lifts.
    @Test("G9: a clean project reports NO loss at all")
    func cleanProjectIsSilent() throws {
        let lead = Self.instrumentTrack("Lead", [
            Self.midiClip(start: 0, length: 4, notes: [
                Self.note(60, 0, 1), Self.note(64, 1, 1), Self.note(67, 2, 2),
            ], lanes: [MIDIControllerLane(type: .cc(controller: 11), points: [
                .init(beat: 0, value: 100), .init(beat: 2, value: 64),
            ])]),
        ])
        let bass = Self.instrumentTrack("Bass", [
            Self.midiClip(start: 4, length: 4, notes: [Self.note(36, 0, 4)]),
        ])
        let report = try Self.export([lead, bass]).report

        #expect(report.notesQuantized == 0)
        #expect(report.controllerPointsQuantized == 0)
        #expect(report.maxQuantizationErrorBeats == 0)
        #expect(report.maxQuantizationErrorMs == 0)
        #expect(report.maxTempoRoundTripErrorBPM == 0)
        #expect(report.notesWidenedToOneTick == 0)
        #expect(report.overlappingSamePitchNotesTruncated == 0)
        #expect(report.overlappingSamePitchNotesDropped == 0)
        #expect(report.notesPastClipEnd == 0)
        #expect(report.controllerPointsPastClipEnd == 0)
        #expect(report.clipsWithGainNotExported == 0)
        #expect(report.clipsWithStretchNotExported == 0)
        #expect(report.audioClipsSkipped == 0)
        #expect(report.droppedMeterChanges.isEmpty)
        #expect(report.tempoSegmentsCollidingAtSameTick.isEmpty)
        #expect(report.substitutedDefaultMeterAtZero == false)
        #expect(report.programChangesNotWritten == 0)
        #expect(report.channelsWrapped == 0)
        #expect(report.trackNamesLostToFormat0 == 0)
        #expect(report.mutedTracksExported.isEmpty)
        #expect(report.soloedTracksPresent == false)
        #expect(report.degradations == [])

        // And it did export what it was given, so the leg is not vacuously
        // green on an empty project.
        #expect(report.tracksExported == 2)
        #expect(report.notesExported == 4)
        #expect(report.controllerPointsExported == 2)
    }

    /// **G-M3's discriminator, stated as its own leg.** A quantization error
    /// computed from the formula `0.5/t` instead of through
    /// `clock.beats(clock.ticks(beat:))` would report 5.2e-5 beats here.
    @Test("quantization error is measured through the clock, not from a formula")
    func quantizationErrorIsMeasuredNotDerived() throws {
        let onGrid = try Self.export([Self.instrumentTrack("Lead", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1), Self.note(62, 2.5, 0.25)]),
        ])])
        #expect(onGrid.report.maxQuantizationErrorBeats == 0)
        #expect(0.5 / 9600.0 > 0)   // the formula the leg forbids is non-zero
    }

    // MARK: - G10: byte determinism

    /// **G10 —** the only leg that catches a `Dictionary`-shaped grouping. k2's
    /// own sort key is total, so the bytes wobble only if the IR's CONSTRUCTION
    /// order does, which no functional leg observes.
    @Test("G10: exporting the same project twice produces identical bytes")
    func exportIsDeterministic() throws {
        // Several clips sharing a startBeat, several lanes, several pitches —
        // every place an unordered grouping could leak.
        var clips: [Clip] = []
        for index in 0 ..< 6 {
            let i = Double(index)
            let notes: [MIDINote] = [Self.note(60 + index, i * 0.25, 0.5),
                                     Self.note(72 - index, i * 0.5, 0.25)]
            let cc = MIDIControllerLane(type: .cc(controller: 11),
                                        points: [MIDIControllerPoint(beat: i * 0.5,
                                                                     value: index)])
            let bend = MIDIControllerLane(type: .pitchBend,
                                          points: [MIDIControllerPoint(beat: i * 0.5,
                                                                       value: 8192)])
            let pressure = MIDIControllerLane(type: .channelPressure,
                                              points: [MIDIControllerPoint(beat: i * 0.25,
                                                                           value: 40)])
            clips.append(Self.midiClip(start: 0, length: 8, notes: notes,
                                       lanes: [cc, bend, pressure]))
        }
        let tracks = [Self.instrumentTrack("A", clips),
                      Self.instrumentTrack("B", Array(clips.reversed()))]

        var previous: Data?
        for _ in 0 ..< 8 {
            let bytes = try StandardMIDIFileWriter.encode(Self.export(tracks).file)
            if let previous { #expect(bytes == previous) }
            previous = bytes
        }
        #expect((previous?.count ?? 0) > 0)
    }

    // MARK: - G11: as authored, not as heard

    /// **G11 — the decision the design most nearly went the other way on.**
    ///
    /// Mutation that reddens it: apply `MIDISchedule`'s playback window
    /// (`note.startBeat < clip.lengthBeats`, `min(note.endBeat, clip.lengthBeats)`).
    /// The first note would VANISH and the second would be truncated to beat 2.
    ///
    /// This is also the round-trip guarantee for clips `clip.importMIDI` itself
    /// produces: that command deliberately imports content past the clip end and
    /// reports it rather than trimming, so a windowing export would silently
    /// delete exactly the content DAW Pro just created.
    @Test("G11: notes past a clip's end export at their authored positions, and are reported")
    func contentPastClipEndSurvives() throws {
        let clip = Self.midiClip(length: 2, notes: [
            Self.note(60, 3, 1),      // starts past the end
            Self.note(64, 1, 4),      // starts inside, extends past
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        let notes = Self.exportedNotes(plan)
        #expect(notes.count == 2)
        #expect(notes.map(\.tick) == [9600, 28800])
        #expect(notes.map(\.lengthTicks) == [38400, 9600])
        #expect(plan.report.notesPastClipEnd == 2)

        // …and it is a FACT about the project, not a loss taken: it pushes no
        // `degradations` line, so it cannot make G9 permanently red.
        #expect(plan.report.degradations == [])
    }

    /// The half-open interval, which is the difference between G9 passing and
    /// failing on every ordinary project.
    @Test("a note ending exactly AT the clip end is not past it")
    func noteEndingAtClipEndIsInside() throws {
        let clip = Self.midiClip(length: 4, notes: [Self.note(60, 3, 1)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.report.notesPastClipEnd == 0)
    }

    // MARK: - G12: mix state is exported, not honoured

    /// **G12 —** mutation that reddens it: filter on `isMuted`/`isSoloed`.
    ///
    /// The `degradations == []` half is what keeps the leg honest against an
    /// implementation that exports everything but shouts about it.
    @Test("G12: muted and soloed tracks are exported, reported, and not honoured")
    func mixStateIsSerialisedNotRendered() throws {
        let muted = Self.instrumentTrack("Muted", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)]),
        ], muted: true)
        let soloed = Self.instrumentTrack("Soloed", [
            Self.midiClip(length: 4, notes: [Self.note(64, 0, 1)]),
        ], soloed: true)
        let report = try Self.export([muted, soloed]).report

        #expect(report.tracksExported == 2)
        #expect(report.notesExported == 2)
        #expect(report.mutedTracksExported == ["Muted"])
        #expect(report.soloedTracksPresent == true)
        #expect(report.tracks.allSatisfy { $0.exported })
        #expect(report.degradations == [])
    }

    // MARK: - Skips and the ledger

    @Test("audio and bus tracks produce no chunk, one ledger row, and a reason")
    func nonInstrumentTracksAreSkipped() throws {
        let audio = Track(name: "Vox", kind: .audio)
        let bus = Track(name: "Reverb", kind: .bus)
        let lead = Self.instrumentTrack("Lead", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)]),
        ])
        let plan = try Self.export([audio, lead, bus])

        // 1 conductor + 1 instrument chunk. The chunk count follows the TRACK
        // STRUCTURE, never the content.
        #expect(plan.file.tracks.count == 2)
        #expect(plan.report.tracks.map(\.index) == [0, 1, 2])
        #expect(plan.report.tracks.map(\.exported) == [false, true, false])
        #expect(plan.report.tracks[0].skipReason?.contains("audio track") == true)
        #expect(plan.report.tracks[2].skipReason?.contains("bus track") == true)
        #expect(plan.report.tracks[1].chunkIndex == 1)
        #expect(plan.report.tracks[0].chunkIndex == nil)
    }

    /// The asymmetry with audio tracks is deliberate: an EMPTY instrument track
    /// is still a part of the arrangement, and the receiving DAW gets the layout.
    @Test("an instrument track with no clips is still exported, as a named empty chunk")
    func emptyInstrumentTrackIsExported() throws {
        let plan = try Self.export([Self.instrumentTrack("Empty", [])])
        #expect(plan.file.tracks.count == 2)
        #expect(plan.file.tracks[1].name == "Empty")
        #expect(plan.file.tracks[1].notes.isEmpty)
        // The IR's own contract: `channels` lists the channels appearing in the
        // part's EVENTS, and a silent part has none.
        #expect(plan.file.tracks[1].channels.isEmpty)
        #expect(plan.report.tracks[0].channel == 0)   // …but a channel WAS allocated
        #expect(try StandardMIDIFileWriter.encode(plan.file).count > 0)
    }

    @Test("an audio clip parked on an instrument track is skipped and counted")
    func audioClipOnInstrumentTrack() throws {
        var track = Self.instrumentTrack("Lead", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)]),
        ])
        track.clips.append(Clip(name: "Stray", startBeat: 8, lengthBeats: 4,
                                audioFileURL: URL(fileURLWithPath: "/tmp/x.wav")))
        let report = try Self.export([track]).report
        #expect(report.audioClipsSkipped == 1)
        #expect(report.notesExported == 1)
        #expect(report.degradations.contains { $0.contains("audio clip") })
    }

    // MARK: - Channels and program change

    @Test("channels are allocated one per track, drums on 9, and wraps are reported")
    func channelAllocation() throws {
        var drums = Self.instrumentTrack("Drums", [])
        drums.instrument = InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                       bankMSB: GMProgramCatalog.percussionBankMSB))
        let melodic = (0 ..< 17).map { Self.instrumentTrack("T\($0)", []) }
        let plan = try Self.export([drums] + melodic)

        #expect(plan.report.tracks[0].channel == 9)
        // 0…8 then 10…15, then wrap to 0.
        #expect(plan.report.tracks[1].channel == 0)
        #expect(plan.report.tracks[9].channel == 8)
        #expect(plan.report.tracks[10].channel == 10)
        #expect(plan.report.tracks[15].channel == 15)
        #expect(plan.report.tracks[16].channel == 0)
        #expect(plan.report.channelsWrapped == 2)
        #expect(plan.report.degradations.contains { $0.contains("reuse a MIDI channel") })
    }

    /// A `.polySynth` track can be HOLDING a percussion `SoundBankConfig` it does
    /// not play: `InstrumentDescriptor` carries every kind's parameters at once,
    /// so switching kinds round-trips the user's settings. The drum rule must
    /// therefore read `kind`, not the leftover config. (The design's §4.3
    /// pseudocode omits this test — see the item report.)
    @Test("a polySynth track holding a stale percussion bank does NOT take channel 9")
    func staleSoundBankDoesNotStealTheDrumChannel() throws {
        var track = Self.instrumentTrack("Synth", [])
        track.instrument = InstrumentDescriptor(
            kind: .polySynth,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                       bankMSB: GMProgramCatalog.percussionBankMSB))
        let report = try Self.export([track]).report
        #expect(report.tracks[0].channel == 0)
        #expect(report.tracks[0].program == nil)
        #expect(report.programChangesNotWritten == 0)
    }

    /// The k2 gap, gated so it cannot be smuggled through: the IR carries the
    /// program change, the BYTES DO NOT, and the report says so in a typed field
    /// AND in prose.
    @Test("a GM track's program change rides the IR, is NOT in the bytes, and is reported")
    func programChangeIsReportedNotWritten() throws {
        var track = Self.instrumentTrack("Trumpet", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)]),
        ])
        track.instrument = InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 56))
        let plan = try Self.export([track])

        #expect(plan.file.tracks[1].programChanges.map(\.program) == [56])
        #expect(plan.report.tracks[0].program == 56)
        #expect(plan.report.tracks[0].programName == GMProgramCatalog.name(forProgram: 56))
        #expect(plan.report.programChangesNotWritten == 1)
        #expect(plan.report.degradations.contains { $0.contains("program-change") })

        // The BYTES: no `Cn` event. Asserted through the SHIPPED PARSER, not by
        // scanning for a 0xC0-0xCF byte — a naive scan is a false positive
        // waiting to happen (the VLQ for a 9600-tick delta is 0xCB 0x00). The
        // reader has parsed `Cn` since m23-k3 Step 0, so if the writer emitted
        // one it would show up here. This is the assertion that turns "we did
        // not write it" from a claim into a fact.
        let bytes = try StandardMIDIFileWriter.encode(plan.file)
        let decoded = try StandardMIDIFileReader.decode(bytes)
        #expect(decoded.tracks.allSatisfy { $0.programChanges.isEmpty })
    }

    /// Gated on `source == .generalMIDI` and not merely on `kind == .soundBank`:
    /// a `.file(path:)` SF2's program number addresses THAT FILE'S bank, so
    /// writing it as a GM program would name a different instrument everywhere
    /// else.
    @Test("a file-backed sound bank reports no GM program")
    func fileSoundBankHasNoGMProgram() throws {
        var track = Self.instrumentTrack("Custom", [])
        track.instrument = InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .file(path: "/tmp/bank.sf2"), program: 56))
        let report = try Self.export([track]).report
        #expect(report.tracks[0].program == nil)
        #expect(report.programChangesNotWritten == 0)
    }

    @Test("no bank-select CC is ever emitted")
    func noBankSelectCC() throws {
        var track = Self.instrumentTrack("Piano", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)]),
        ])
        track.instrument = InstrumentDescriptor(
            kind: .soundBank,
            soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                       bankMSB: GMProgramCatalog.melodicBankMSB))
        let plan = try Self.export([track])
        #expect(plan.file.tracks[1].controllers.isEmpty)
    }

    // MARK: - G14: meter guards

    /// **G14 —** both inputs are REACHABLE over `tempo.setMap`:
    /// `MeterMap.Change.init` applies only `max(1, …)`. Silently coercing 5 to 4
    /// (or clamping 300 to 255) would produce a file naming a meter the project
    /// never held.
    @Test("G14: a non-power-of-two denominator at beat 0 drops, and 4/4 is substituted")
    func nonPowerOfTwoDenominatorAtZero() throws {
        let meter = try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 5)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)]),
        ])], meterMap: meter)

        #expect(plan.report.droppedMeterChanges.count == 1)
        #expect(plan.report.droppedMeterChanges[0].contains("4/5"))
        #expect(plan.report.substitutedDefaultMeterAtZero == true)
        #expect(plan.file.timeSignatures.count == 1)
        #expect(plan.file.timeSignatures[0].numerator == 4)
        #expect(plan.file.timeSignatures[0].denominatorPower == 2)

        // The BYTES carry FF 58 04 04 02 18 08 — the file must declare a meter
        // at tick 0, and the leg that only checked the counter would pass an
        // implementation that dropped it and left the file with none.
        let bytes = Array(try StandardMIDIFileWriter.encode(plan.file))
        let signature: [UInt8] = [0xFF, 0x58, 0x04, 0x04, 0x02, 0x18, 0x08]
        #expect(bytes.indices.contains { index in
            index + signature.count <= bytes.count
                && Array(bytes[index ..< index + signature.count]) == signature
        })
    }

    @Test("G14b: a 300-beat bar drops with a cause, and change 0 is untouched")
    func beatsPerBarOutOfByteRange() throws {
        let meter = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 8, beatsPerBar: 300, beatUnit: 4),
        ])
        let plan = try Self.export([Self.instrumentTrack("Lead", [])], meterMap: meter)
        #expect(plan.report.droppedMeterChanges.count == 1)
        #expect(plan.report.droppedMeterChanges[0].contains("300"))
        #expect(plan.report.substitutedDefaultMeterAtZero == false)
        #expect(plan.file.timeSignatures.map(\.numerator) == [4])
    }

    // MARK: - G15: the tick ceiling

    /// **G15 —** mutation that reddens it: let `SMFEncodeError.deltaTimeTooLarge`
    /// surface raw. That message speaks in TICKS, names no beat, and offers no
    /// escape. The second half proves the limit is division-dependent and not a
    /// project-size cap.
    @Test("G15: content past the VLQ ceiling refuses at 9600 and succeeds at 480")
    func tickCeilingRefusal() throws {
        let clip = Self.midiClip(start: 30_000, length: 4, notes: [Self.note(60, 0, 1)])
        let tracks = [Self.instrumentTrack("Far", [clip])]

        #expect(throws: MIDIExportError.self) {
            try Self.export(tracks)
        }
        do {
            _ = try Self.export(tracks)
            Issue.record("expected a refusal at division 9600")
        } catch let error as MIDIExportError {
            guard case .contentTooFarFromStart(let beat, let limit, let division) = error else {
                Issue.record("wrong case: \(error)")
                return
            }
            #expect(beat >= 30_000)
            #expect(limit == Double(0x0FFF_FFFF) / 9600.0)
            #expect(division == 9600)
            #expect(error.localizedDescription.contains("480"))
        }

        // The same project, one parameter different, succeeds.
        let smaller = try Self.export(tracks, division: 480)
        #expect(smaller.report.notesExported == 1)
        #expect(smaller.report.ticksPerQuarterNote == 480)
    }

    // MARK: - Format 0

    @Test("format 0 merges into one chunk and reports the track names it costs")
    func formatZeroMerges() throws {
        let tracks = [
            Self.instrumentTrack("Lead", [Self.midiClip(length: 4,
                                                        notes: [Self.note(60, 0, 1)])]),
            Self.instrumentTrack("Bass", [Self.midiClip(length: 4,
                                                        notes: [Self.note(36, 0, 1)])]),
        ]
        let plan = try Self.export(tracks, format: .singleTrack)
        #expect(plan.report.format == 0)
        // The conductor's name survives the merge (k2's `Part.merged` keeps the
        // FIRST non-nil name), so BOTH track names are lost.
        #expect(plan.report.trackNamesLostToFormat0 == 2)
        #expect(plan.report.tracks.allSatisfy { $0.chunkIndex == 0 })

        let decoded = try StandardMIDIFileReader.decode(
            StandardMIDIFileWriter.encode(plan.file))
        #expect(decoded.format == .singleTrack)
        // One chunk, but the per-track CHANNELS make it re-import as two parts.
        #expect(decoded.tracks.count == 2)
        #expect(decoded.tracks.map(\.channel) == [0, 1])
    }

    // MARK: - Selection

    @Test("trackIds selects in PROJECT order whatever order the ids arrive in")
    func selectionKeepsProjectOrder() throws {
        let a = Self.instrumentTrack("A", [Self.midiClip(length: 4,
                                                         notes: [Self.note(60, 0, 1)])])
        let b = Self.instrumentTrack("B", [Self.midiClip(length: 4,
                                                         notes: [Self.note(62, 0, 1)])])
        let c = Self.instrumentTrack("C", [Self.midiClip(length: 4,
                                                         notes: [Self.note(64, 0, 1)])])
        let plan = try Self.export([a, b, c], trackIDs: [c.id, a.id])
        #expect(plan.report.tracks.map(\.name) == ["A", "C"])
        #expect(plan.report.tracks.map(\.index) == [0, 2])
        #expect(plan.file.tracks.count == 3)
        #expect(plan.file.tracks[1].name == "A")
        #expect(plan.file.tracks[2].name == "C")
    }

    // MARK: - Clip attributes that are NOT baked in

    @Test("clip gain, envelope, fades, stretch and pitch shift are reported, not baked")
    func clipAttributesAreNotBaked() throws {
        var clip = Self.midiClip(length: 4, notes: [Self.note(60, 0, 1, velocity: 100)],
                                 gainDb: -6, stretch: 2)
        clip.pitchShiftSemitones = 5
        clip.fadeInBeats = 0.5
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.report.clipsWithGainNotExported == 1)
        #expect(plan.report.clipsWithStretchNotExported == 1)
        // The velocity is the AUTHORED one, not one scaled by -6 dB.
        #expect(Self.exportedNotes(plan)[0].velocity == 100)
        // …and the note is at its authored position, not stretched by 2x.
        #expect(Self.exportedNotes(plan)[0].tick == 0)
        #expect(Self.exportedNotes(plan)[0].lengthTicks == 9600)
    }

    // MARK: - Trailing silence, controller lanes, and release velocity

    /// m23-k3's R6 reads a clip's length back OUT of `part.endTick`, so trailing
    /// silence must be written IN or the round trip loses it.
    @Test("a clip's full span is written into endTick, so its length round-trips")
    func trailingSilenceSurvives() throws {
        let clip = Self.midiClip(length: 16, notes: [Self.note(60, 0, 1)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.file.tracks[1].endTick == 16 * 9600)
        #expect(plan.report.endTick == 16 * 9600)
        #expect(plan.report.endBeat == 16)

        let back = try #require(Self.reimport(plan).tracks.first?.clip)
        #expect(back.lengthBeats == 16)
    }

    @Test("controller lanes export with their values, and re-import unchanged")
    func controllerLanesSurvive() throws {
        let lanes = [
            MIDIControllerLane(type: .cc(controller: 11),
                               points: [.init(beat: 0, value: 20), .init(beat: 1, value: 100)]),
            MIDIControllerLane(type: .pitchBend,
                               points: [.init(beat: 0.5, value: 16383)]),
            MIDIControllerLane(type: .channelPressure,
                               points: [.init(beat: 1.5, value: 77)]),
        ]
        let clip = Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)], lanes: lanes)
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(plan.report.controllerPointsExported == 4)
        #expect(plan.report.tracks[0].controllerLanes
                == ["cc11", "channelPressure", "pitchBend"].sorted())

        let back = try #require(Self.reimport(plan).tracks.first?.clip.controllerLanes)
        #expect(back.count == 3)
        let bend = try #require(back.first { $0.type == .pitchBend })
        // The 14-bit LSB-first split survives, including the top of the range —
        // the value m23-k2 found a hole at.
        #expect(bend.points.map(\.value) == [16383])
        let cc = try #require(back.first { $0.type == .cc(controller: 11) })
        #expect(cc.points.map(\.value) == [20, 100])
        #expect(cc.points.map(\.beat) == [0, 1])
    }

    /// Release velocity 64 is the one value INVENTED rather than read, and it is
    /// chosen so a note we write does not mint a
    /// `notesWithDroppedReleaseVelocity` entry on the way back — which would
    /// make G9 on the RETURN leg permanently red.
    @Test("release velocity is 64, so a re-import reports no dropped release velocity")
    func releaseVelocityIsTheNoInformationValue() throws {
        let clip = Self.midiClip(length: 4, notes: [Self.note(60, 0, 1), Self.note(64, 1, 1)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(Self.exportedNotes(plan).allSatisfy { $0.releaseVelocity == 64 })
        #expect(try Self.reimport(plan).report.notesWithDroppedReleaseVelocity == 0)
    }

    @Test("a note shorter than one tick is widened rather than lost")
    func minimumLengthIsOneTick() throws {
        // MIDINote.minLengthBeats is 0.001; at t = 96 that is 0.096 ticks.
        let clip = Self.midiClip(length: 4, notes: [Self.note(60, 0, MIDINote.minLengthBeats)])
        let plan = try Self.export([Self.instrumentTrack("Lead", [clip])], division: 96)
        #expect(Self.exportedNotes(plan)[0].lengthTicks == 1)
        #expect(plan.report.notesWidenedToOneTick == 1)
        #expect(plan.report.degradations.contains { $0.contains("widened") })

        // …and at the default division it does not fire at all.
        let fine = try Self.export([Self.instrumentTrack("Lead", [clip])])
        #expect(fine.report.notesWidenedToOneTick == 0)
        // 0.001 * 9600 = 9.6, which ROUNDS to 10 — the endpoint form again, and
        // a reminder that "the minimum length in ticks" is not `floor`.
        #expect(Self.exportedNotes(fine)[0].lengthTicks == 10)
    }

    // MARK: - The report's own contracts

    @Test("string loss lists are capped at 32 entries with a trailing count")
    func lossListsAreCapped() throws {
        // 40 muted tracks: the typed count stays exact, the list does not grow
        // without bound into an agent's context.
        let tracks = (0 ..< 40).map { Self.instrumentTrack("M\($0)", [], muted: true) }
        let report = try Self.export(tracks).report
        #expect(report.mutedTracksExported.count == MIDIExportReport.maxReportedEntries + 1)
        #expect(report.mutedTracksExported.last == "… and 8 more")
    }

    @Test("the report encodes to JSON with trackId spelled the way every command spells it")
    func reportIsCodable() throws {
        let report = try Self.export([Self.instrumentTrack("Lead", [
            Self.midiClip(length: 4, notes: [Self.note(60, 0, 1)]),
        ])]).report
        let data = try JSONEncoder().encode(report)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let trackRows = try #require(json["tracks"] as? [[String: Any]])
        #expect(trackRows[0]["trackId"] != nil)
        #expect(trackRows[0]["trackID"] == nil)
        let decoded = try JSONDecoder().decode(MIDIExportReport.self, from: data)
        #expect(decoded == report)
    }

    // MARK: - D-DIVISION's derivation, as a leg rather than a claim

    /// 9600 is DERIVED, not conventional, and this is the derivation that
    /// matters most in practice: it is exact for every MPC swing preset DAW
    /// Pro's own quantizer produces (the offsets are `P/100` and `P/200`, so 5²
    /// is required), which 480, 960 and 15360 are NOT.
    @Test("the default division is exact for DAW Pro's own swing offsets, unlike 480/960")
    func defaultDivisionCapturesSwing() throws {
        let groove = try #require(GrooveTemplate.builtin(named: "swing8:66"))
        let offsets = groove.offsets.filter { $0 != 0 }
        #expect(!offsets.isEmpty)

        func exact(at t: Int) -> Bool {
            offsets.allSatisfy { offset in
                let product = offset * Double(t)
                return abs(product - product.rounded()) <= 1e-9
            }
        }
        #expect(exact(at: MIDIExportOptions.defaultTicksPerQuarterNote))
        #expect(!exact(at: 480))
        #expect(!exact(at: 960))
        #expect(!exact(at: 15360))
    }
}
