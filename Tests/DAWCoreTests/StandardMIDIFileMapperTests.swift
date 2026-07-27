import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// m23-k3 Standard MIDI File → project mapping (`SMFProjectMapper`).
///
/// THREE KINDS OF INPUT, deliberately not mixed:
///
/// 1. **`apple-type1.mid`** — the one genuinely third-party file, and the spine
///    of this suite (G4/G9). Its expectations were pinned by the orchestrator
///    from k1's IR dump BEFORE this mapper existed, so the table below is not
///    derived from the code under test.
/// 2. **`hazard-type1-multichannel.mid`** — the ONE new byte fixture, because
///    the claim it carries is a PARSING claim (that k1 really does hand the
///    mapper a format-1 `SMFTrack` with `channels.count == 2`). No hand-built IR
///    can prove that: a hand-built IR is exactly what would be assumed. Apple's
///    loader confirms the bytes (one `MusicTrack`, events on 2 channels).
/// 3. **Hand-built `StandardMIDIFile` values** for the remaining hazards. The
///    mapper's input IS a `StandardMIDIFile`, and those hazards encode MAPPING
///    decisions, not parsing claims — so routing them through 60 bytes of
///    hand-authored SMF would add an unvalidated authoring step between the
///    hazard and the assertion without adding evidence. This SCOPES the ONE
///    HAZARD PER FIXTURE law, it does not relax it, and it comes with the rule
///    that makes it safe: **every hand-built IR here is one the reader can
///    actually produce**, and where reachability is itself the claim, bytes are
///    used instead (case 2).
@MainActor
@Suite("Standard MIDI File → project mapping (m23-k3)")
struct StandardMIDIFileMapperTests {

    // MARK: - Helpers

    static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "mid",
                              subdirectory: "Fixtures/SMF"),
            "fixture \(name).mid is not in the test bundle")
        return try Data(contentsOf: url)
    }

    static func decodeFixture(_ name: String) throws -> StandardMIDIFile {
        try StandardMIDIFileReader.decode(fixtureData(name))
    }

    /// A project with nothing in it — the `auto` policy's adopt case.
    static func emptyContext() -> MIDIImportContext {
        MIDIImportContext(projectHasClips: false,
                          currentTempoMap: TempoMap(constantBPM: 120),
                          currentMeterMap: MeterMap(constant: TimeSignature()))
    }

    static func mapFile(_ file: StandardMIDIFile,
                        options: MIDIImportOptions = MIDIImportOptions(),
                        context: MIDIImportContext? = nil) throws -> MIDIImportPlan {
        try SMFProjectMapper.map(file, options: options, context: context ?? emptyContext())
    }

    /// A one-part metrical file at 480 tpqn, with whatever global events the
    /// case under test needs. This is the reader's own output shape: a format-1
    /// file whose chunk 0 is the conductor and chunk 1 the part.
    static func ir(tempo: [SMFTempoEvent] = [],
                   meter: [SMFTimeSignatureEvent] = [],
                   notes: [SMFNote] = [SMFNote(tick: 0, lengthTicks: 480, note: 60,
                                               velocity: 100, releaseVelocity: 64, channel: 0)],
                   controllers: [SMFControllerEvent] = [],
                   endTick: Int = 960,
                   division: SMFDivision = .ticksPerQuarterNote(480),
                   format: SMFFormat = .simultaneousTracks,
                   programChanges: [SMFProgramChangeEvent] = [],
                   polyAftertouch: Int = 0) -> StandardMIDIFile {
        let channels = Set(notes.map(\.channel) + controllers.map(\.channel)).sorted()
        return StandardMIDIFile(
            format: format, division: division,
            tracks: [
                SMFTrack(name: "Conductor", sourceTrackIndex: 0, channels: [],
                         notes: [], controllers: [], endTick: endTick),
                SMFTrack(name: "Part", sourceTrackIndex: 1, channels: channels,
                         notes: notes, controllers: controllers, endTick: endTick,
                         programChanges: programChanges,
                         polyAftertouchEventCount: polyAftertouch),
            ],
            tempoChanges: tempo, timeSignatures: meter, warnings: [])
    }

    // MARK: - Fixture integrity

    /// The pin for the ONE new byte fixture. Same job as k1's own pin test: it
    /// proves the bytes are the ones Apple's loader validated, AND that the
    /// resource is actually bundled (a nil `Bundle.module.url` would otherwise
    /// make the multi-channel legs vacuous by absence).
    @Test("The new multi-channel fixture loads from the bundle with its pinned SHA-256")
    func newFixtureBytesAreUnmodified() throws {
        let data = try Self.fixtureData("hazard-type1-multichannel")
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #expect(actual == "eee5e36b653e3d7c0194c2a99c68d9bc72cd09e3671237183e5e9d69be112339",
                "hazard-type1-multichannel.mid has changed on disk — Apple's confirmation of its reading no longer applies until it is re-validated")
    }

    // MARK: - G1a / G1b — the tick→beat conversion

    /// INVARIANT, NOT A DISCRIMINATOR — and labelled so no future reader
    /// re-promotes it. `beats(k·t) == Double(k)` exactly is what makes
    /// `note.startBeat == 4.0` a legal assertion, but it was MEASURED to hold
    /// under BOTH the single division R1 requires and the reciprocal-multiply it
    /// forbids, at every division a MIDI file actually uses. It catches nothing.
    @Test("G1a (invariant) — an integer beat is exact at every real-world division")
    func integerBeatsAreExact() {
        for t in [1, 24, 48, 96, 120, 192, 240, 384, 480, 960, 1920, 15360] {
            let clock = SMFTickClock(division: .ticksPerQuarterNote(t),
                                     tempoMap: TempoMap(constantBPM: 120))
            for k in [0, 1, 2, 3, 4, 7, 16, 64, 999, 4321] {
                #expect(clock.beats(tick: k * t) == Double(k))
            }
        }
    }

    /// THE ACTUAL DISCRIMINATOR. Both halves are asserted on purpose: a
    /// one-sided equality invites a test author to compute the expected value as
    /// `23.0 * recip`, which passes under either implementation and re-opens the
    /// vacuity. The third assertion is the POSITIVE CONTROL — pure arithmetic,
    /// no mapper involved — so the suite itself demonstrates that the two forms
    /// CAN diverge; without it, a future reader doubting this leg has no way to
    /// check short of re-running the measurement.
    @Test("G1b (discriminator) — tick 23 at t=480 is the single division, not the reciprocal")
    func rawTickUsesASingleDivision() {
        let clock = SMFTickClock(division: .ticksPerQuarterNote(480),
                                 tempoMap: TempoMap(constantBPM: 120))
        #expect(clock.beats(tick: 23) == Double(23) / Double(480))
        #expect(clock.beats(tick: 23) != Double(23) * (1.0 / Double(480)))
        // Positive control: the reciprocal form provably fails at t = 49, k = 1
        // (985 of the first 4000 divisions fail somewhere — none of them a
        // division any MIDI file uses, which is exactly why G1a cannot catch it).
        #expect(Double(49 * 1) * (1.0 / Double(49)) != Double(1))
    }

    /// G2 — R3. The length MUST be non-dyadic or the leg is vacuous: a plain
    /// eighth note (240 ticks at t=480) is bit-identical under endpoint
    /// subtraction at all 20,001 measured sixteenth-grid positions, while this
    /// triplet eighth (160 ticks = 1/3 beat) diverges at 19,998 of them.
    @Test("G2 (metrical) — equal lengthTicks give bit-identical lengthBeats at any position")
    func metricalLengthIsPositionIndependent() {
        let clock = SMFTickClock(division: .ticksPerQuarterNote(480),
                                 tempoMap: TempoMap(constantBPM: 120))
        let reference = clock.lengthBeats(tick: 0, lengthTicks: 160)
        for tick in [30, 120, 160, 240, 481, 1441, 9601, 100_003] {
            #expect(clock.lengthBeats(tick: tick, lengthTicks: 160) == reference,
                    "lengthBeats moved with position at tick \(tick) — that is endpoint subtraction, which R3 forbids on the metrical path")
        }
        // Demonstrate the bug the leg exists to catch, so the leg is visibly
        // non-vacuous: the forbidden form DOES diverge on this input.
        // (Tick 120, not tick 30: at t=480 the two forms happen to AGREE at 30,
        // which is precisely why "pick any old position" is not good enough and
        // the divergent set had to be measured.)
        let endpointAtZero = clock.beats(tick: 0 + 160) - clock.beats(tick: 0)
        let endpointAt120 = clock.beats(tick: 120 + 160) - clock.beats(tick: 120)
        #expect(endpointAtZero != endpointAt120)
    }

    /// G3 — D2's round-trip theorem over exactly the window the transport clamp
    /// permits, which is what k4's export inherits. SAMPLED, not exhausted: all
    /// 2,850,001 values were run once in C with zero failures, so the Swift leg
    /// is a regression guard, not a rediscovery — and an exhaustive debug-build
    /// run would cost seconds and be mistaken for a perf flake. µ = 2,807,175 is
    /// a NAMED input: it is the measured worst case (absolute error 4.66e-10),
    /// and no sampling scheme finds an extremum by luck.
    @Test("G3 — µs/quarter → BPM → µs/quarter is exact across the clamp window")
    func bpmRoundTripsExactly() {
        var inputs = Set([150_000, 3_000_000, 500_000, 666_666, 2_807_175])
        inputs.formUnion(stride(from: 150_000, through: 3_000_000, by: 97))
        for centre in [150_000, 500_000, 666_666, 3_000_000] {
            inputs.formUnion(max(150_000, centre - 2_000)...min(3_000_000, centre + 2_000))
        }
        for micros in inputs.sorted() {
            let bpm = 60_000_000.0 / Double(micros)
            #expect(Int((60_000_000.0 / bpm).rounded()) == micros,
                    "µs/quarter \(micros) did not survive the round trip through BPM")
        }
    }

    // MARK: - G4 — the spine fixture

    /// The roadmap's headline claim, on the one genuinely third-party file.
    /// Every expectation here was pinned before the mapper existed.
    @Test("G4 — apple-type1.mid imports as 2 tracks, notes on beats 0/1/2/3, tempo 120 → 90.00009")
    func appleType1MapsExactly() throws {
        let file = try Self.decodeFixture("apple-type1")
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        // D4: THREE chunks in, TWO tracks out. Chunk 0 is the conductor — no
        // notes and no controllers — so it produces no track, and its tempo
        // payload was already hoisted to file level by k1.
        #expect(plan.tracks.count == 2)
        #expect(plan.report.tracksCreated == 2)
        #expect(plan.report.parts.count == 3)
        #expect(plan.report.parts[0].imported == false)
        #expect(plan.report.parts[0].skipReason == "no notes or controller data")
        #expect(plan.report.parts[1].imported)
        #expect(plan.report.parts[2].imported)
        #expect(plan.report.parts[1].channel == 0)
        #expect(plan.report.parts[2].channel == 1)

        // Every one of these beat values is exactly representable, so `==` is
        // the right assertion and a tolerance would be weaker than the claim.
        for (index, pitches) in [(0, [60, 62, 64, 66]), (1, [48, 50, 52, 54])] {
            let notes = try #require(plan.tracks[index].clip.notes)
            #expect(notes.map(\.startBeat) == [0.0, 1.0, 2.0, 3.0])
            #expect(notes.map(\.lengthBeats) == [0.5, 0.5, 0.5, 0.5])
            #expect(notes.map(\.pitch) == pitches)
            #expect(notes.map(\.velocity) == [70, 80, 90, 100])

            // CC 11 on EACH track separately — 3 points per track, not 6 on one.
            let lanes = plan.tracks[index].clip.controllerLanes
            #expect(lanes.count == 1)
            #expect(lanes[0].type == .cc(controller: 11))
            #expect(lanes[0].points.map(\.beat) == [0.0, 0.5, 1.0])
            #expect(lanes[0].points.map(\.value) == [20, 60, 100])
        }
        #expect(plan.report.notesImported == 8)
        #expect(plan.report.controllerPointsImported == 6)

        // D2: the tempo is the FULL-PRECISION division, never a snap to a nice
        // value. Written as the expression, never as a decimal literal —
        // 60e6/666666 is 90.00009000009000009…, and both the first design draft
        // and the project memory carried a wrong transcription of those digits.
        let tempo = try #require(plan.tempoMap)
        #expect(tempo.segments.count == 2)
        #expect(tempo.segments[0].startBeat == 0.0)
        #expect(tempo.segments[0].bpm == 120.0)
        #expect(tempo.segments[1].startBeat == 4.0)
        #expect(tempo.segments[1].bpm == 60_000_000.0 / 666_666.0)
        #expect(plan.report.tempoSegmentsAdopted == 2)
        #expect(plan.report.adoptedTempoBPM == 120.0)

        // H4c FOR METER — the trap. This file carries NO `FF 58` at all, so it
        // has no meter map; synthesizing 4/4 here and then "adopting" it would
        // stomp a 3/4 project with a meter the file never contained.
        #expect(plan.meterMap == nil)
        #expect(plan.report.meterChangesAdopted == 0)
        #expect(plan.report.fileCarriedNoMeterMap)
        #expect(plan.report.synthesizedLeadingMeter == false)
        #expect(plan.report.fileCarriedNoTempoMap == false)
    }

    /// The §0 spine, made testable: the tempo policy changes the MAP and NOTHING
    /// ELSE. If any note beat differs between the two runs, beats are not affine
    /// in ticks somewhere.
    @Test("G4 — adopt and ignore put every note on the identical beat")
    func policyDoesNotMoveNotes() throws {
        let file = try Self.decodeFixture("apple-type1")
        let adopted = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))
        let ignored = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .ignore))

        #expect(adopted.tracks.map { $0.clip.notes ?? [] }.map { $0.map(\.startBeat) }
                == ignored.tracks.map { $0.clip.notes ?? [] }.map { $0.map(\.startBeat) })
        #expect(ignored.tempoMap == nil)
        #expect(ignored.report.tempoSegmentsAdopted == 0)
        #expect(ignored.report.resolvedTempoPolicy == "ignore")
        #expect(adopted.report.resolvedTempoPolicy == "adopt")
    }

    /// G9 — the vacuity guard. Without it, a mapper that reports SOMETHING on
    /// every file passes every hazard leg and the report becomes noise nobody
    /// reads. `fileCarriedNoMeterMap` fires here and is deliberately NOT part of
    /// the loss section: it states a fact about the file, not a loss we took.
    @Test("G9 (vacuity guard) — a clean file reports no losses and no degradations at all")
    func cleanFileReportsNothing() throws {
        let file = try Self.decodeFixture("apple-type1")
        let report = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt)).report

        #expect(report.degradations == [])
        #expect(report.clampedTempoEvents == [])
        #expect(report.droppedMeterChanges == [])
        #expect(report.conflictingDuplicateTempoEvents == [])
        #expect(report.conflictingDuplicateMeterEvents == [])
        #expect(report.droppedMalformedTempoEvents == [])
        #expect(report.tempoAdoptionDegradedToIgnore == false)
        #expect(report.synthesizedLeadingTempo == false)
        #expect(report.synthesizedLeadingMeter == false)
        #expect(report.notesWithDroppedReleaseVelocity == 0)
        #expect(report.notesStretchedToMinimumLength == 0)
        #expect(report.shortestRequestedLengthBeats == nil)
        #expect(report.droppedControllerLanes == [:])
        #expect(report.decimatedControllerLanes == [:])
        #expect(report.droppedProgramChanges == 0)
        #expect(report.polyAftertouchEventsDropped == 0)
        #expect(report.notesPastClipEnd == 0)
        #expect(report.controllerPointsPastClipEnd == 0)
        #expect(report.fileWarnings == [])
        #expect(report.isAbsoluteTime == false)
    }

    // MARK: - G10 / G11c — H5a, the multi-channel format-1 split

    /// H5a, the most structural decision in the design, on the one new byte
    /// fixture. The TRACK COUNT is the weak half of this leg; the CONTROLLER
    /// LANES are the strong half — a mapper that creates 2 tracks but merges
    /// both channels' CC 11 into one of them passes a count-only assertion, and
    /// the equal-beat last-wins dedupe would silently eat one of the values.
    @Test("G11c — a format-1 MTrk on two channels splits into two tracks with SEPARATE CC lanes")
    func formatOneMultiChannelSplits() throws {
        let file = try Self.decodeFixture("hazard-type1-multichannel")
        // The parsing claim the bytes carry, asserted before the mapping one.
        let source = try #require(file.tracks.first { $0.sourceTrackIndex == 1 })
        #expect(source.channels == [0, 1])
        #expect(source.channel == nil)

        let plan = try Self.mapFile(file)
        #expect(plan.tracks.count == 2)
        #expect(plan.tracks[0].track.name == "Duo (ch 1)")
        #expect(plan.tracks[1].track.name == "Duo (ch 2)")

        let first = plan.tracks[0].clip
        let second = plan.tracks[1].clip
        #expect(first.notes?.map(\.pitch) == [60])
        #expect(second.notes?.map(\.pitch) == [48])
        // The discriminating half: each track keeps its OWN cc11 value.
        #expect(first.controllerLanes.count == 1)
        #expect(second.controllerLanes.count == 1)
        #expect(first.controllerLanes[0].points.map(\.value) == [20])
        #expect(second.controllerLanes[0].points.map(\.value) == [100])
        // And the notes still land where the ticks put them.
        #expect(first.notes?.map(\.startBeat) == [0.0])
        #expect(first.notes?.map(\.lengthBeats) == [1.0])
    }

    // MARK: - G10 — the hand-built IR hazard cases

    /// H4b — a file whose first tempo event is not at tick 0. The spec default
    /// is legitimate HERE and only here: the user asked to adopt a map, and
    /// 120-before-the-first-event is that map's spec-defined content.
    @Test("G10 tempo-late — a first tempo event past tick 0 gets a synthesized 120 BPM prefix")
    func lateFirstTempoIsCompleted() throws {
        let file = Self.ir(tempo: [SMFTempoEvent(tick: 480, microsecondsPerQuarterNote: 500_000,
                                                 sourceTrackIndex: 0)])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        let tempo = try #require(plan.tempoMap)
        #expect(tempo.segments.map(\.startBeat) == [0.0, 1.0])
        #expect(tempo.segments.map(\.bpm) == [120.0, 120.0])
        #expect(plan.report.synthesizedLeadingTempo)
        #expect(plan.report.fileCarriedNoTempoMap == false)
        // The notes did not move — a tempo hazard is never a position hazard.
        #expect(plan.tracks[0].clip.notes?.map(\.startBeat) == [0.0])
    }

    /// H3 — the real-world failure mode: exporters that stamp a default
    /// `FF 51 500000` into EVERY chunk. Under last-wins, chunk 1's default would
    /// override a conductor track that says 90 BPM. The array is authored in the
    /// reader's own `(tick, sourceTrackIndex)` hoist order, which is what makes
    /// "do not re-sort" observable (G11d).
    @Test("G10/G11b/G11d tempo-duplicate — two tempos at tick 0: the FIRST wins and is reported")
    func duplicateTempoFirstWins() throws {
        let file = Self.ir(tempo: [
            SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 666_666, sourceTrackIndex: 0),
            SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000, sourceTrackIndex: 1),
        ])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        let tempo = try #require(plan.tempoMap)
        #expect(tempo.segments.count == 1)
        // The conductor's 90.00009 BPM survived; chunk 1's 120 did not.
        #expect(tempo.segments[0].bpm == 60_000_000.0 / 666_666.0)
        #expect(plan.report.conflictingDuplicateTempoEvents.count == 1)
        let conflict = plan.report.conflictingDuplicateTempoEvents[0]
        #expect(conflict.contains("666666"))
        #expect(conflict.contains("500000"))
        #expect(plan.tracks[0].clip.notes?.map(\.startBeat) == [0.0])
    }

    /// Identical duplicates are noise, not loss — reporting them would fire on
    /// every file an ordinary exporter writes.
    @Test("G10 tempo-duplicate — two IDENTICAL tempos at one tick report nothing")
    func identicalDuplicateTempoIsSilent() throws {
        let file = Self.ir(tempo: [
            SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000, sourceTrackIndex: 0),
            SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000, sourceTrackIndex: 1),
        ])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))
        #expect(plan.report.conflictingDuplicateTempoEvents == [])
        #expect(plan.tempoMap?.segments.count == 1)
    }

    /// §2.3 step 3.5 — `FF 51 03 00 00 00` is a well-framed event k1 accepts,
    /// and `60e6 / 0` is +infinity, which the `Segment` clamp silently turns
    /// into 400 BPM and would print to the user as "requested BPM inf". The
    /// distinction from H4c is load-bearing: this file DID assert a tempo map,
    /// it asserted an unusable one, so `fileCarriedNoTempoMap` stays FALSE.
    @Test("G10 tempo-malformed — a zero µs/quarter is dropped, not clamped to 400 BPM")
    func malformedTempoIsDropped() throws {
        let file = Self.ir(tempo: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 0,
                                                 sourceTrackIndex: 0)])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        #expect(plan.tempoMap == nil)
        #expect(plan.report.droppedMalformedTempoEvents.count == 1)
        #expect(plan.report.clampedTempoEvents == [])
        #expect(plan.report.fileCarriedNoTempoMap == false)
        #expect(plan.report.tempoSegmentsAdopted == 0)
        #expect(plan.tracks[0].clip.notes?.map(\.startBeat) == [0.0])
    }

    /// H1 — an absurd tempo is clamped, reported, and moves NOTHING. Refusing an
    /// otherwise-good file over one silly `FF 51` would be hostile; silence is
    /// the only unacceptable option.
    @Test("G10 tempo-clamp — an out-of-range BPM is clamped, named, and moves no note")
    func extremeTempoIsClampedAndReported() throws {
        let file = Self.ir(tempo: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 1,
                                                 sourceTrackIndex: 0)])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        #expect(plan.tempoMap?.segments[0].bpm == TransportState.tempoRange.upperBound)
        #expect(plan.report.clampedTempoEvents.count == 1)
        #expect(plan.report.clampedTempoEvents[0].contains("400"))
        #expect(plan.tracks[0].clip.notes?.map(\.startBeat) == [0.0])
        #expect(plan.tracks[0].clip.notes?.map(\.lengthBeats) == [1.0])
    }

    /// H2 — a meter change the model refuses, because it does not sit on a
    /// barline of the meter accumulated before it. Dropping changes only the bar
    /// NUMBERING, never a note; snapping would move the downbeat grid to a place
    /// the file never named.
    @Test("G10 meter-offbar — a mid-bar 3/4 is dropped with an off-barline reason")
    func offBarlineMeterChangeIsDropped() throws {
        let file = Self.ir(meter: [
            SMFTimeSignatureEvent(tick: 0, numerator: 4, denominatorPower: 2,
                                  clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0),
            SMFTimeSignatureEvent(tick: 720, numerator: 3, denominatorPower: 2,
                                  clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0),
        ])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        let meter = try #require(plan.meterMap)
        #expect(meter.changes.count == 1)
        #expect(meter.changes[0].beatsPerBar == 4)
        #expect(plan.report.droppedMeterChanges.count == 1)
        #expect(plan.report.droppedMeterChanges[0].contains("mid-bar"))
        #expect(plan.report.meterChangesAdopted == 1)
        #expect(plan.tracks[0].clip.notes?.map(\.startBeat) == [0.0])
    }

    /// §1.3 — the numerator/denominator pair is imported VERBATIM, and §1.3-3,
    /// its most likely support question. Two readings of ONE decision, not two
    /// hazards: the same verbatim mapping produces both. A "helpful" translation
    /// to (3, 8) would break the first half; treating the drop as a parse
    /// failure would break the second.
    @Test("G10 meter-eighths — 6/8 imports as (6,8) verbatim, and the file's own bar 2 drops")
    func eighthMeterIsVerbatimAndItsBarlineDrops() throws {
        let file = Self.ir(meter: [
            SMFTimeSignatureEvent(tick: 0, numerator: 6, denominatorPower: 3,
                                  clocksPerMetronomeClick: 36, thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0),
            // Tick 1440 = beat 3 = the FILE's bar 2 (a 6/8 bar is 3 quarter
            // notes). DAW Pro v1 counts a 6/8 bar as SIX quarter notes, so
            // 3/6 = 0.5 bars and the model refuses it.
            SMFTimeSignatureEvent(tick: 1440, numerator: 4, denominatorPower: 2,
                                  clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0),
        ])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        let meter = try #require(plan.meterMap)
        #expect(meter.changes.count == 1)
        // VERBATIM: 6/8 is (6, 8). Translating to (3, 8) would make import
        // disagree with hand-entry and ship a numerator-12 bug into k4's export.
        #expect(meter.changes[0].beatsPerBar == 6)
        #expect(meter.changes[0].beatUnit == 8)
        #expect(plan.report.droppedMeterChanges.count == 1)
        let reason = plan.report.droppedMeterChanges[0]
        // The reason must name the CAUSE — DAW Pro's bar length, not the file's
        // — or it reads as though their file were broken.
        #expect(reason.contains("6/8"))
        #expect(reason.contains("DAW Pro v1"))
        #expect(reason.contains("mid-bar") == false)
    }

    /// §1.3-1 — malformed meter events are dropped BEFORE a `Change` is built,
    /// because `Change.init`'s `max(1, …)` would silently turn `0/4` into `1/4`
    /// and `2^255` is not a denominator any `Int` can hold.
    @Test("G10 meter-malformed — an unrepresentable denominator and a zero numerator drop")
    func malformedMeterEventsAreDropped() throws {
        let file = Self.ir(meter: [
            SMFTimeSignatureEvent(tick: 0, numerator: 4, denominatorPower: 2,
                                  clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0),
            SMFTimeSignatureEvent(tick: 1920, numerator: 4, denominatorPower: 255,
                                  clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0),
            SMFTimeSignatureEvent(tick: 3840, numerator: 0, denominatorPower: 2,
                                  clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                                  sourceTrackIndex: 0),
        ])
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        #expect(plan.meterMap?.changes.count == 1)
        #expect(plan.report.droppedMeterChanges.count == 2)
        #expect(plan.meterMap?.changes[0].beatsPerBar == 4)
    }

    /// H6c — both producers of a zero-length note in one case, because they are
    /// one hazard: a note-off at the note-on's own tick, and a dangling onset at
    /// end-of-track that k1 closes with `lengthTicks = 0`.
    @Test("G10 zero-length — sub-minimum notes are stretched and counted, with the shortest named")
    func zeroLengthNotesAreStretchedAndCounted() throws {
        let file = Self.ir(notes: [
            SMFNote(tick: 0, lengthTicks: 0, note: 60, velocity: 100,
                    releaseVelocity: 0, channel: 0),
            SMFNote(tick: 960, lengthTicks: 0, note: 62, velocity: 90,
                    releaseVelocity: 0, channel: 0),
        ])
        let plan = try Self.mapFile(file)

        let notes = try #require(plan.tracks[0].clip.notes)
        #expect(notes.map(\.lengthBeats) == [MIDINote.minLengthBeats, MIDINote.minLengthBeats])
        #expect(notes.map(\.startBeat) == [0.0, 2.0])
        #expect(plan.report.notesStretchedToMinimumLength == 2)
        #expect(plan.report.shortestRequestedLengthBeats == 0.0)
    }

    /// H5b — 0 and 64 are the two conventional "no information" release
    /// velocities (0 is also what a `9n`-velocity-0 note-off produces), so
    /// counting them would make this field fire on every ordinary file. G9 is
    /// the other half of this claim.
    @Test("G10 release-velocity — only a MEANINGFUL release velocity is counted as dropped")
    func onlyMeaningfulReleaseVelocityIsReported() throws {
        let file = Self.ir(notes: [
            SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                    releaseVelocity: 0, channel: 0),
            SMFNote(tick: 480, lengthTicks: 480, note: 62, velocity: 100,
                    releaseVelocity: 64, channel: 0),
            SMFNote(tick: 960, lengthTicks: 480, note: 64, velocity: 100,
                    releaseVelocity: 100, channel: 0),
        ])
        let plan = try Self.mapFile(file)
        #expect(plan.report.notesWithDroppedReleaseVelocity == 1)
    }

    /// H7 lane priority, and the leg that makes it non-vacuous: a naive "most
    /// points wins" rule VISIBLY drops CC 64, the ONE controller DAW Pro's
    /// built-in instruments actually act on, in favour of dense controller spam.
    @Test("G10/G12 many-cc — the 16-lane cap keeps sustain and drops the spam, caps hold exactly")
    func laneCapKeepsSustainOverSpam() throws {
        var controllers: [SMFControllerEvent] = []
        // CC 64 (sustain): 2 points — the LEAST populated lane in the file.
        for (index, tick) in [0, 960].enumerated() {
            controllers.append(SMFControllerEvent(tick: tick, channel: 0,
                                                  type: .cc(controller: 64),
                                                  value: index == 0 ? 127 : 0))
        }
        // 20 junk CC streams, each far denser than sustain.
        for controller in 20..<40 {
            for step in 0..<50 {
                controllers.append(SMFControllerEvent(tick: step * 10, channel: 0,
                                                      type: .cc(controller: controller),
                                                      value: step))
            }
        }
        let file = Self.ir(controllers: controllers)
        let plan = try Self.mapFile(file)

        let lanes = plan.tracks[0].clip.controllerLanes
        #expect(lanes.count == ProjectStore.maxControllerLanesPerClip)
        #expect(lanes.contains { $0.type == .cc(controller: 64) },
                "sustain was dropped in favour of denser junk — the priority head is the whole point of H7's rule")
        // 21 lanes in (sustain + 20 junk), 16 kept, so 5 dropped by name.
        #expect(plan.report.droppedControllerLanes.count
                == 21 - ProjectStore.maxControllerLanesPerClip)
        // G12 post-conditions: the mapper is the ONLY enforcement of these caps
        // on the import path, because it builds Clip values offline and never
        // crosses `ProjectStore.setControllerLane`'s boundary.
        #expect(lanes.count <= ProjectStore.maxControllerLanesPerClip)
        for lane in lanes {
            #expect(lane.points.count <= ProjectStore.maxControllerPointsPerLane)
        }
        #expect(plan.tracks[0].clip.notes?.map(\.startBeat) == [0.0])
    }

    /// H7 point decimation — measured on the CANONICAL list, so a dense stream
    /// that dedupes below the cap is left completely alone (decimating the raw
    /// stream would discard data the cap never objected to).
    @Test("G12 decimation — an over-cap lane is thinned below the cap, keeping first and last")
    func overCapLaneIsDecimated() throws {
        // `cap * 2` EXACTLY, and the exactness is the whole test. At any n that
        // is a multiple of the cap the stride is an integer, the grid alone
        // consumes the entire budget (32768/2 = 16384 = cap), and the file's
        // last point sits at odd offset 32767 — so an implementation that
        // APPENDS the last point returns cap + 1 and breaks the post-condition
        // by one. `cap * 2 + 3` — the obvious "comfortably over the cap" input,
        // and the one this test used first — gives stride 3 and lands at 10925,
        // a third of the budget: it cannot fail no matter how the endpoint rule
        // is written. A generic over-cap input is not a discriminator here; the
        // multiple-of-cap boundary is.
        let cap = ProjectStore.maxControllerPointsPerLane
        let count = cap * 2
        let controllers = (0..<count).map {
            SMFControllerEvent(tick: $0, channel: 0, type: .cc(controller: 11), value: $0 % 128)
        }
        let file = Self.ir(controllers: controllers, endTick: count)
        let plan = try Self.mapFile(file)

        let lane = try #require(plan.tracks[0].clip.controllerLanes.first)
        #expect(lane.points.count <= cap)
        #expect(lane.points.count == cap, "the grid fills the budget exactly at n = 2·cap")
        #expect(lane.points.first?.beat == 0.0)
        // The LAST point always survives: lanes are stepwise, so truncating the
        // tail would leave a stuck value that never resolves. When the grid is
        // already full it REPLACES the final grid point rather than extending
        // past it, which is how both rules hold at once.
        #expect(lane.points.last?.beat == Double(count - 1) / 480.0)
        #expect(plan.report.decimatedControllerLanes["cc11"] == lane.points.count)
    }

    /// The post-condition swept directly over `decimate`, across the boundary
    /// class the fixture test can only sample once. Every exact multiple of the
    /// cap is a candidate failure; so is every n whose last offset misses the
    /// grid. Cheap to check exhaustively at a small cap, and the small cap is
    /// the same arithmetic as the real one.
    @Test("G12 decimation — count <= cap and endpoints preserved, swept across the boundary")
    func decimationPostConditionHoldsAtEveryBoundary() throws {
        for cap in [2, 3, 5, 16, 100] {
            for count in (cap + 1)...(cap * 4 + 1) {
                let points = (0..<count).map {
                    MIDIControllerPoint(beat: Double($0), value: $0 % 128)
                }
                let thinned = SMFProjectMapper.decimate(points, cap: cap)
                #expect(thinned.count <= cap,
                        "cap \(cap), n \(count): decimation must never exceed the cap")
                #expect(thinned.first?.beat == 0.0, "cap \(cap), n \(count): first point kept")
                #expect(thinned.last?.beat == Double(count - 1),
                        "cap \(cap), n \(count): last point kept")
                // Strictly increasing — a replacement must not duplicate or
                // reorder the point it displaces.
                #expect(zip(thinned, thinned.dropFirst()).allSatisfy { $0.beat < $1.beat },
                        "cap \(cap), n \(count): points stay strictly ordered")
            }
        }
    }

    /// The clip-end boundary, at EXACTLY the end beat and for BOTH kinds of
    /// content. A clip spans the half-open range `[0, length)`, so a note or a
    /// point sitting precisely ON the end is unreachable — equally, and for the
    /// same reason. The two counters were briefly spelled `>=` and `>`, which no
    /// test could tell apart because nothing in the suite put content exactly on
    /// the boundary; this is that test, and it fails if either leg drifts.
    @Test("clip end is half-open: content exactly at the end counts as past it, notes and points alike")
    func contentExactlyAtTheClipEndIsPastIt() throws {
        let file = Self.ir(
            notes: [SMFNote(tick: 0, lengthTicks: 240, note: 60,
                            velocity: 100, releaseVelocity: 64, channel: 0),
                    // Exactly beat 2.0 at 480 tpqn.
                    SMFNote(tick: 960, lengthTicks: 240, note: 62,
                            velocity: 100, releaseVelocity: 64, channel: 0)],
            controllers: [SMFControllerEvent(tick: 0, channel: 0,
                                             type: .cc(controller: 11), value: 10),
                          // Exactly beat 2.0 as well.
                          SMFControllerEvent(tick: 960, channel: 0,
                                             type: .cc(controller: 11), value: 90)],
            endTick: 1200)
        var context = Self.emptyContext()
        context.targetClipLengthBeats = 2.0
        let plan = try Self.mapFile(file, context: context)

        #expect(plan.report.notesPastClipEnd == 1)
        #expect(plan.report.controllerPointsPastClipEnd == 1,
                "a controller point exactly at the clip end is as unreachable as a note there — the two counters must use the same comparison")
        // The negative control: at a length that genuinely contains beat 2.0,
        // BOTH counters drop to zero, so the assertion above is about the
        // boundary and not about the content merely existing.
        var roomier = Self.emptyContext()
        roomier.targetClipLengthBeats = 2.5
        let inside = try Self.mapFile(file, context: roomier)
        #expect(inside.report.notesPastClipEnd == 0)
        #expect(inside.report.controllerPointsPastClipEnd == 0)
    }

    /// A dense stream that CANONICALIZES below the cap needs no decimation at
    /// all — the other half of the "canonical first" rule, and the case a
    /// raw-stream implementation gets wrong.
    @Test("G12 decimation — a stream that dedupes below the cap is not thinned")
    func denseButDeduplicatingLaneIsUntouched() throws {
        // 3× the cap in EVENTS, but only 100 distinct ticks.
        var controllers: [SMFControllerEvent] = []
        for round in 0..<(ProjectStore.maxControllerPointsPerLane / 25) {
            for tick in 0..<100 {
                controllers.append(SMFControllerEvent(tick: tick, channel: 0,
                                                      type: .cc(controller: 11),
                                                      value: (round + tick) % 128))
            }
        }
        let file = Self.ir(controllers: controllers)
        let plan = try Self.mapFile(file)
        #expect(plan.tracks[0].clip.controllerLanes.first?.points.count == 100)
        #expect(plan.report.decimatedControllerLanes == [:])
    }

    /// §2.2 — the SMPTE carve-out, on the existing fixture. Ticks are ABSOLUTE
    /// time there: 25 fps × 40 ticks/frame = 1000 ticks/s, so a 1000-tick note
    /// is 1.0 s, which at 120 BPM is 2.0 beats. The file's `FF 51` events do not
    /// govern its clock, so there is no tempo map to adopt.
    @Test("G10 smpte — absolute time maps through the project tempo and tempo adoption degrades")
    func smpteUsesAbsoluteTime() throws {
        let file = try Self.decodeFixture("hazard-smpte-division")
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        #expect(plan.report.isAbsoluteTime)
        #expect(plan.tempoMap == nil)
        #expect(plan.report.tempoAdoptionDegradedToIgnore)
        #expect(plan.report.tempoSegmentsAdopted == 0)
        // "adopt", not "ignore": the degradation is TEMPO-specific. See
        // `smpteMeterSurvivesTempoDegradation` for why the distinction is not
        // cosmetic. The report says more than one bit, so no information is lost
        // by keeping the policy honest here.
        #expect(plan.report.resolvedTempoPolicy == "adopt")
        let notes = try #require(plan.tracks[0].clip.notes)
        #expect(notes.count == 1)
        #expect(notes[0].startBeat == 0.0)
        #expect(notes[0].lengthBeats == 2.0)
        #expect(plan.report.degradations.contains { $0.contains("SMPTE") })
    }

    /// §2.2 — a SMPTE file's TEMPO events are meaningless (they do not govern
    /// its clock), but its METER events are not: meter is a bar-grid concept,
    /// not a clock, so "3/4 at tick 0" is a true statement about a SMPTE file in
    /// a way that "120 BPM" is not. The shipped fixture carries no `FF 58`, so
    /// it cannot tell the two readings apart — this is a hand-built IR because
    /// the distinction is invisible on every file we have.
    @Test("G10 smpte — a meter change at tick 0 still adopts while the tempo does not")
    func smpteMeterSurvivesTempoDegradation() throws {
        let file = Self.ir(
            tempo: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                  sourceTrackIndex: 0)],
            meter: [SMFTimeSignatureEvent(tick: 0, numerator: 3, denominatorPower: 2,
                                          clocksPerMetronomeClick: 24,
                                          thirtySecondNotesPerQuarter: 8,
                                          sourceTrackIndex: 0)],
            notes: [SMFNote(tick: 0, lengthTicks: 1000, note: 60,
                            velocity: 100, releaseVelocity: 64, channel: 0)],
            endTick: 1000,
            division: .smpte(framesPerSecond: 25, ticksPerFrame: 40))
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))

        #expect(plan.report.isAbsoluteTime)
        #expect(plan.report.tempoAdoptionDegradedToIgnore)
        // The tempo half is dead...
        #expect(plan.report.tempoSegmentsAdopted == 0)
        // ...and the meter half is NOT. A `resolved = .ignore` flip would zero
        // this too, silently, and the only file that could catch it is this one.
        #expect(plan.report.meterChangesAdopted == 1)
        let meter = try #require(plan.meterMap)
        #expect(meter.changes.count == 1)
        #expect(meter.changes[0].beatsPerBar == 3)
        #expect(meter.changes[0].startBeat == 0.0)
        // §2.5's `(nil, meter?)` case: the PROJECT's current tempo map rides
        // through unchanged so `applyTempoMap`'s wholesale replace lands the
        // meter without moving the tempo.
        let tempo = try #require(plan.tempoMap)
        #expect(tempo == TempoMap(constantBPM: 120))
    }

    /// D3 — program change is CAPTURED and REPORTED whatever `instruments` says;
    /// only the descriptor assignment is gated. The GM default is `none` in k3
    /// because bulk sound-bank assignment is an unmeasured main-actor cost.
    @Test("G10 program-change — reported under 'none', applied under 'gm', channel 10 is the kit")
    func programChangesAreReportedAndOptionallyApplied() throws {
        let notes = [
            SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                    releaseVelocity: 64, channel: 0),
            SMFNote(tick: 0, lengthTicks: 480, note: 38, velocity: 100,
                    releaseVelocity: 64, channel: 9),
        ]
        let file = Self.ir(notes: notes, programChanges: [
            SMFProgramChangeEvent(tick: 0, channel: 0, program: 56),
            SMFProgramChangeEvent(tick: 960, channel: 0, program: 40),
            SMFProgramChangeEvent(tick: 0, channel: 9, program: 0),
        ])

        let reported = try Self.mapFile(file)
        #expect(reported.report.parts[1].programChange == 56)
        #expect(reported.report.parts[1].programName == "Trumpet")
        #expect(reported.report.parts[2].programName == GMProgramCatalog.standardDrumKit.name)
        // The second program change on channel 0 is a drop: a DAW Pro track
        // holds one instrument for its whole length.
        #expect(reported.report.droppedProgramChanges == 1)
        // Default is `none` — nothing was assigned.
        #expect(reported.tracks[0].track.instrument == nil)
        #expect(reported.report.instrumentsAssigned == "none")

        let assigned = try Self.mapFile(file, options: MIDIImportOptions(instruments: .gm))
        let melodic = try #require(assigned.tracks[0].track.instrument)
        #expect(melodic.kind == .soundBank)
        #expect(melodic.soundBank?.program == 56)
        #expect(melodic.soundBank?.bankMSB == GMProgramCatalog.melodicBankMSB)
        // Channel 10 (index 9) is GM percussion by convention, whatever program
        // it names — this file names program 0, which as a MELODIC program would
        // be a grand piano.
        let drums = try #require(assigned.tracks[1].track.instrument)
        #expect(drums.soundBank?.bankMSB == GMProgramCatalog.percussionBankMSB)
        #expect(drums.soundBank?.displayName == GMProgramCatalog.standardDrumKit.name)
    }

    /// D3 — poly aftertouch has nowhere to go in the model, so the count is all
    /// that survives. The point of Step 0 was to stop the loss being silent.
    @Test("G10 poly-aftertouch — the count is reported and nothing is invented")
    func polyAftertouchIsCounted() throws {
        let file = Self.ir(polyAftertouch: 7)
        let plan = try Self.mapFile(file)
        #expect(plan.report.polyAftertouchEventsDropped == 7)
        #expect(plan.tracks[0].clip.controllerLanes.isEmpty)
        #expect(plan.report.degradations.contains { $0.contains("aftertouch") })
    }

    /// D4′ — format 2 declares INDEPENDENT sequences; DAW Pro lays them out
    /// simultaneously and says so. A sequential layout is a musical judgement
    /// with no third-party reference to check against.
    @Test("G10 format-2 — independent sequences are laid out simultaneously and reported")
    func formatTwoIsReported() throws {
        let file = Self.ir(format: .independentSequences)
        let plan = try Self.mapFile(file)
        #expect(plan.report.format == 2)
        #expect(plan.report.degradations.contains { $0.contains("independent sequences") })
    }

    // MARK: - Options plumbing

    /// D1′ — `adopt` at a non-zero beat is a REFUSAL, because adoption is
    /// defined as a wholesale REPLACE and an offset adoption would be a MERGE: a
    /// different operation with its own unanswered questions. Refusing a
    /// self-contradictory explicit request beats silently doing a third thing.
    @Test("D1′ — explicit adopt at a non-zero atBeat refuses and names both escapes")
    func adoptAtNonZeroBeatRefuses() throws {
        let file = Self.ir(tempo: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                                 sourceTrackIndex: 0)])
        #expect(throws: MIDIImportError.tempoAdoptionRequiresBeatZero(atBeat: 8)) {
            try Self.mapFile(file, options: MIDIImportOptions(atBeat: 8, tempoPolicy: .adopt))
        }
        // `auto` at a non-zero beat simply resolves to ignore — the user named
        // no policy, so there is nothing to contradict.
        let auto = try Self.mapFile(file, options: MIDIImportOptions(atBeat: 8, tempoPolicy: .auto))
        #expect(auto.report.resolvedTempoPolicy == "ignore")
        #expect(auto.tempoMap == nil)
    }

    /// G5 (mapper half) — `auto` resolves both ways off `importGeneration`'s
    /// exact empty-project predicate, which is passed IN as `projectHasClips`.
    /// These are the legs that catch a predicate copied wrong.
    @Test("G5 — auto adopts into an empty project and ignores into a populated one")
    func autoResolvesBothWays() throws {
        let file = Self.ir(tempo: [SMFTempoEvent(tick: 0, microsecondsPerQuarterNote: 500_000,
                                                 sourceTrackIndex: 0)])
        let empty = try Self.mapFile(file)
        #expect(empty.report.resolvedTempoPolicy == "adopt")
        #expect(empty.tempoMap != nil)

        let populated = try Self.mapFile(
            file, context: MIDIImportContext(projectHasClips: true,
                                             currentTempoMap: TempoMap(constantBPM: 90),
                                             currentMeterMap: MeterMap(constant: TimeSignature())))
        #expect(populated.report.resolvedTempoPolicy == "ignore")
        #expect(populated.tempoMap == nil)
    }

    /// §2.5 — a file with a meter map but no tempo map adopts the METER only,
    /// carrying the project's CURRENT tempo through unchanged (`applyTempoMap`
    /// requires both, and replaces wholesale). `tempoSegmentsAdopted` stays 0
    /// because nothing about the tempo moved.
    @Test("§2.5 — a meter-only adoption carries the project's own tempo map through")
    func meterOnlyAdoptionKeepsProjectTempo() throws {
        let file = Self.ir(meter: [SMFTimeSignatureEvent(
            tick: 0, numerator: 3, denominatorPower: 2, clocksPerMetronomeClick: 24,
            thirtySecondNotesPerQuarter: 8, sourceTrackIndex: 0)])
        let context = MIDIImportContext(projectHasClips: false,
                                        currentTempoMap: TempoMap(constantBPM: 91),
                                        currentMeterMap: MeterMap(constant: TimeSignature()))
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt),
                                    context: context)
        #expect(plan.tempoMap?.segments == [TempoMap.Segment(startBeat: 0, bpm: 91)])
        #expect(plan.meterMap?.changes[0].beatsPerBar == 3)
        #expect(plan.report.tempoSegmentsAdopted == 0)
        #expect(plan.report.meterChangesAdopted == 1)
        #expect(plan.report.fileCarriedNoTempoMap)
    }

    /// §3.4 — the track-count guard, and the escape it names.
    @Test("§3.4 — over 32 tracks refuses unless force, and a dry run still computes everything")
    func trackCountGuardRefusesAndForceOverrides() throws {
        var tracks: [SMFTrack] = []
        for index in 0..<(SMFProjectMapper.maxImportedTracks + 1) {
            tracks.append(SMFTrack(
                name: "P\(index)", sourceTrackIndex: index, channels: [0],
                notes: [SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                                releaseVelocity: 64, channel: 0)],
                controllers: [], endTick: 480))
        }
        let file = StandardMIDIFile(format: .simultaneousTracks,
                                    division: .ticksPerQuarterNote(480), tracks: tracks,
                                    tempoChanges: [], timeSignatures: [], warnings: [])
        #expect(throws: MIDIImportError.tooManyTracks(
            count: SMFProjectMapper.maxImportedTracks + 1,
            limit: SMFProjectMapper.maxImportedTracks)) {
            try Self.mapFile(file)
        }
        let forced = try Self.mapFile(file, options: MIDIImportOptions(force: true))
        #expect(forced.tracks.count == SMFProjectMapper.maxImportedTracks + 1)
        // …and `parts` is the other escape the error names.
        let subset = try Self.mapFile(file, options: MIDIImportOptions(parts: [0, 1, 2]))
        #expect(subset.tracks.count == 3)
        #expect(subset.report.parts.filter { !$0.imported }.count == tracks.count - 3)
        #expect(subset.report.parts[3].skipReason == "not selected for import")
    }

    /// The part index space is the FULL enumeration including skipped parts, so
    /// `parts: [0]` means the same thing in a dry run and a real run — and an
    /// index that names nothing is an error, not a silent empty import.
    @Test("§3.1 — part indices span skipped parts too, and an out-of-range index is an error")
    func partIndicesSpanSkippedParts() throws {
        let file = try Self.decodeFixture("apple-type1")
        // Part 0 is the conductor. Selecting it alone imports nothing.
        let conductorOnly = try Self.mapFile(file, options: MIDIImportOptions(parts: [0]))
        #expect(conductorOnly.tracks.isEmpty)
        let secondOnly = try Self.mapFile(file, options: MIDIImportOptions(parts: [1]))
        #expect(secondOnly.tracks.count == 1)
        #expect(secondOnly.tracks[0].clip.notes?.map(\.pitch) == [60, 62, 64, 66])

        #expect(throws: MIDIImportError.partIndexOutOfRange(index: 9, partCount: 3)) {
            try Self.mapFile(file, options: MIDIImportOptions(parts: [9]))
        }
    }

    /// R5 vs R2 — `atBeat` belongs on the CLIP, never on a note. A double
    /// application would put every note at `2 × atBeat`, which is the single
    /// easiest bug to write here.
    @Test("R5 — atBeat moves the clip and leaves every note beat untouched")
    func atBeatMovesTheClipOnly() throws {
        let file = try Self.decodeFixture("apple-type1")
        let plan = try Self.mapFile(file, options: MIDIImportOptions(atBeat: 16,
                                                                     tempoPolicy: .ignore))
        #expect(plan.tracks.allSatisfy { $0.clip.startBeat == 16 })
        #expect(plan.tracks[0].clip.notes?.map(\.startBeat) == [0.0, 1.0, 2.0, 3.0])
    }

    /// R6 — `endTick` is authoritative for the clip length, so trailing silence
    /// survives the import instead of being trimmed away.
    @Test("R6 — a part's trailing silence survives as clip length")
    func trailingSilenceSurvives() throws {
        let file = Self.ir(notes: [SMFNote(tick: 0, lengthTicks: 480, note: 60, velocity: 100,
                                           releaseVelocity: 64, channel: 0)],
                           endTick: 3840)
        let plan = try Self.mapFile(file)
        #expect(plan.tracks[0].clip.lengthBeats == 8.0)
    }

    /// The report's `[String]` lists are bounded at APPEND time: a pathological
    /// file must not mint a ten-thousand-element array that rides the wire into
    /// an agent's context. The typed counts alongside stay exact.
    @Test("§5 — a pathological file's report lists cap at 32 entries plus an overflow line")
    func reportListsAreCapped() throws {
        var meter: [SMFTimeSignatureEvent] = [SMFTimeSignatureEvent(
            tick: 0, numerator: 4, denominatorPower: 2, clocksPerMetronomeClick: 24,
            thirtySecondNotesPerQuarter: 8, sourceTrackIndex: 0)]
        for index in 1...200 {
            // Every one lands mid-bar, so every one is dropped.
            meter.append(SMFTimeSignatureEvent(
                tick: 480 * index * 4 + 240, numerator: 3, denominatorPower: 2,
                clocksPerMetronomeClick: 24, thirtySecondNotesPerQuarter: 8,
                sourceTrackIndex: 0))
        }
        let file = Self.ir(meter: meter)
        let plan = try Self.mapFile(file, options: MIDIImportOptions(tempoPolicy: .adopt))
        #expect(plan.report.droppedMeterChanges.count
                == MIDIImportReport.maxReportedEntries + 1)
        #expect(plan.report.droppedMeterChanges.last?.hasPrefix("… and ") == true)
        #expect(plan.report.droppedMeterChanges.last?.contains("168") == true)
    }
}
