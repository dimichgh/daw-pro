import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// MIDICaptureSession beat math and pairing, on synthetic `LiveMIDIEvent`s
/// with fabricated host times. `ticksToSeconds` is injected as 1e-9 (1 tick ≡
/// 1 ns) so the tick → beat math is EXACT: at 120 BPM one beat is 0.5 s ≡
/// 500_000_000 ticks.
@MainActor
@Suite("MIDI capture session")
struct MIDICaptureTests {
    /// Anchor at 1e9 ticks, beat 8, 120 BPM — mirrors a take started at beat 8.
    private static let anchorTicks: UInt64 = 1_000_000_000
    private static let anchorBeats = 8.0
    private static let ticksPerBeat: UInt64 = 500_000_000  // 0.5 s at 120 BPM

    private func makeSession(anchorBeats: Double = MIDICaptureTests.anchorBeats) -> MIDICaptureSession {
        MIDICaptureSession(anchorHostTime: Self.anchorTicks, anchorBeats: anchorBeats,
                           tempoMap: TempoMap(constantBPM: 120), ticksToSeconds: 1e-9)
    }

    /// Host time for an ABSOLUTE beat position (may be before the anchor).
    private func ticks(atBeat beat: Double) -> UInt64 {
        let delta = (beat - Self.anchorBeats) * Double(Self.ticksPerBeat)
        return delta >= 0
            ? Self.anchorTicks + UInt64(delta)
            : Self.anchorTicks - UInt64(-delta)
    }

    private func on(_ pitch: UInt8, atBeat beat: Double, velocity: UInt8 = 100) -> LiveMIDIEvent {
        LiveMIDIEvent(hostTime: ticks(atBeat: beat), source: 1,
                      kind: ScheduledMIDIEvent.noteOn, pitch: pitch,
                      velocity: velocity, channel: 0)
    }

    private func off(_ pitch: UInt8, atBeat beat: Double) -> LiveMIDIEvent {
        LiveMIDIEvent(hostTime: ticks(atBeat: beat), source: 1,
                      kind: ScheduledMIDIEvent.noteOff, pitch: pitch,
                      velocity: 0, channel: 0)
    }

    @Test("captured beats match the anchor math exactly")
    func capturedBeatsMatchAnchorMath() {
        let session = makeSession()
        session.ingest(on(60, atBeat: 9))     // 1 beat after the anchor
        session.ingest(off(60, atBeat: 10.5))
        let result = session.finish(atBeat: 12)
        #expect(result.notes.count == 1)
        let note = result.notes[0]
        #expect(note.pitch == 60)
        #expect(note.velocity == 100)
        #expect(note.startBeat == 1.0)      // clip-relative: 9 − 8, EXACT
        #expect(note.lengthBeats == 1.5)    // 10.5 − 9, EXACT
        #expect(!result.droppedEvents)
    }

    @Test("a pre-anchor note-on is dropped (count-in), and its off drops with it")
    func preAnchorNoteOnIsDropped() {
        let session = makeSession()
        session.ingest(on(60, atBeat: 7.5))   // during the count-in
        session.ingest(off(60, atBeat: 9))    // its off is now an orphan
        session.ingest(on(64, atBeat: 8))     // exactly at the anchor: kept
        session.ingest(off(64, atBeat: 9))
        let result = session.finish(atBeat: 10)
        #expect(result.notes.map(\.pitch) == [64])
        #expect(result.notes[0].startBeat == 0)
    }

    @Test("an interleaved chord pairs notes by pitch")
    func interleavedChordPairsNotesByPitch() {
        let session = makeSession()
        session.ingest(on(60, atBeat: 8))
        session.ingest(on(64, atBeat: 8.25))
        session.ingest(on(67, atBeat: 8.5))
        session.ingest(off(64, atBeat: 9))     // offs out of on-order
        session.ingest(off(67, atBeat: 9.5))
        session.ingest(off(60, atBeat: 10))
        let result = session.finish(atBeat: 12)
        #expect(result.notes.count == 3)
        let byPitch = Dictionary(uniqueKeysWithValues: result.notes.map { ($0.pitch, $0) })
        #expect(byPitch[60]?.startBeat == 0 && byPitch[60]?.lengthBeats == 2)
        #expect(byPitch[64]?.startBeat == 0.25 && byPitch[64]?.lengthBeats == 0.75)
        #expect(byPitch[67]?.startBeat == 0.5 && byPitch[67]?.lengthBeats == 1)
    }

    @Test("retrigger of an open pitch closes the previous note at the new onset")
    func retriggerOfOpenPitchClosesPreviousAtNewOnset() {
        let session = makeSession()
        session.ingest(on(60, atBeat: 8, velocity: 90))
        session.ingest(on(60, atBeat: 9, velocity: 110))  // retrigger while open
        session.ingest(off(60, atBeat: 10))
        let result = session.finish(atBeat: 12)
        #expect(result.notes.count == 2)
        #expect(result.notes[0].startBeat == 0 && result.notes[0].lengthBeats == 1)
        #expect(result.notes[0].velocity == 90)
        #expect(result.notes[1].startBeat == 1 && result.notes[1].lengthBeats == 1)
        #expect(result.notes[1].velocity == 110)
    }

    @Test("open notes clamp to the stop beat at finish")
    func openNotesClampToStopBeat() {
        let session = makeSession()
        session.ingest(on(60, atBeat: 9))  // never released
        let result = session.finish(atBeat: 12)
        #expect(result.notes.count == 1)
        #expect(result.notes[0].startBeat == 1)
        #expect(result.notes[0].lengthBeats == 3)  // clamped to stop (12 − 9)
    }

    @Test("an orphan note-off is ignored")
    func orphanNoteOffIsIgnored() {
        let session = makeSession()
        session.ingest(off(60, atBeat: 9))  // no matching on
        let result = session.finish(atBeat: 10)
        #expect(result.notes.isEmpty)
    }

    @Test("result notes are canonically ordered and clip-relative")
    func resultNotesAreCanonicallyOrderedAndClipRelative() {
        let session = makeSession()
        // Land in scrambled close order and scrambled pitch-at-same-beat order.
        session.ingest(on(72, atBeat: 10))
        session.ingest(on(60, atBeat: 10))
        session.ingest(on(64, atBeat: 8.5))
        session.ingest(off(72, atBeat: 11))
        session.ingest(off(64, atBeat: 9))
        session.ingest(off(60, atBeat: 11))
        let result = session.finish(atBeat: 12)
        #expect(result.notes.map(\.pitch) == [64, 60, 72])       // onset, then pitch
        #expect(result.notes.map(\.startBeat) == [0.5, 2, 2])    // all clip-relative
        #expect(result.notes == MIDINote.canonicallyOrdered(result.notes))
    }

    @Test("lengthBeats rounds up to a whole beat, minimum one")
    func lengthBeatsRoundsUpToWholeBeatMinimumOne() {
        let partial = makeSession()
        partial.ingest(on(60, atBeat: 8))
        partial.ingest(off(60, atBeat: 9))
        #expect(partial.finish(atBeat: 10.3).lengthBeats == 3)   // ceil(2.3)

        let instant = makeSession()
        #expect(instant.finish(atBeat: 8).lengthBeats == 1)      // max(1, 0)

        let whole = makeSession()
        #expect(whole.finish(atBeat: 12).lengthBeats == 4)       // exact stays exact
    }

    @Test("an empty capture yields no notes (and no dropped flag)")
    func emptyCaptureYieldsNoNotes() {
        let session = makeSession()
        let result = session.finish(atBeat: 16)
        #expect(result.notes.isEmpty)
        #expect(!result.droppedEvents)
    }

    @Test("markDropped surfaces as droppedEvents in the result")
    func markDroppedSurfaces() {
        let session = makeSession()
        session.markDropped()
        #expect(session.finish(atBeat: 9).droppedEvents)
    }

    // MARK: - m16-b3 controller capture (design-m16b §8.4, C12)

    private func cc(_ controller: UInt8, _ value: UInt8, atBeat beat: Double) -> LiveMIDIEvent {
        LiveMIDIEvent(hostTime: ticks(atBeat: beat), source: 1,
                      kind: ScheduledMIDIEvent.controlChange, pitch: controller,
                      velocity: value, channel: 0)
    }

    private func bend(_ value14: Int, atBeat beat: Double) -> LiveMIDIEvent {
        LiveMIDIEvent(hostTime: ticks(atBeat: beat), source: 1,
                      kind: ScheduledMIDIEvent.pitchBend, pitch: UInt8(value14 & 0x7F),
                      velocity: UInt8((value14 >> 7) & 0x7F), channel: 0)
    }

    private func pressure(_ value: UInt8, atBeat beat: Double) -> LiveMIDIEvent {
        LiveMIDIEvent(hostTime: ticks(atBeat: beat), source: 1,
                      kind: ScheduledMIDIEvent.channelPressure, pitch: value,
                      velocity: 0, channel: 0)
    }

    private func lane(_ result: MIDIRecordingResult,
                      _ type: MIDIControllerType) -> MIDIControllerLane? {
        result.controllerLanes.first { $0.type == type }
    }

    /// Values pin EXACT; beats pin to ≤ 1e-9 (the m15-b G1 tolerance idiom —
    /// the tick → seconds → beat round trip is deterministic but sits within
    /// an ulp of the nominal beat at some grid positions).
    private func expectPoints(_ points: [MIDIControllerPoint],
                              _ expected: [(beat: Double, value: Int)]) {
        #expect(points.count == expected.count)
        for (point, want) in zip(points, expected) {
            #expect(point.value == want.value)
            #expect(abs(point.beat - want.beat) <= 1e-9)
        }
    }

    @Test("C12: CC / bend / pressure accumulate into canonical lanes with the anchor beat math")
    func controllerEventsAccumulateIntoLanes() throws {
        let session = makeSession()
        session.ingest(cc(87, 10, atBeat: 9))          // clip-relative beat 1
        session.ingest(pressure(99, atBeat: 9.25))
        session.ingest(bend(6_674, atBeat: 9.5))       // MSB 52 / LSB 18 reassembled
        session.ingest(cc(87, 20, atBeat: 10))
        let result = session.finish(atBeat: 12)

        // Canonical lane order: cc ascending, then pitchBend, then pressure.
        #expect(result.controllerLanes.map(\.type) == [
            .cc(controller: 87), .pitchBend, .channelPressure,
        ])
        expectPoints(try #require(lane(result, .cc(controller: 87))).points,
                     [(1, 10), (2, 20)])
        // The §4.1 reassembly: (MSB << 7) | LSB round-trips the 14-bit value.
        expectPoints(try #require(lane(result, .pitchBend)).points, [(1.5, 6_674)])
        expectPoints(try #require(lane(result, .channelPressure)).points, [(1.25, 99)])
    }

    @Test("C12: consecutive duplicate values drop (repeated CC bytes are idempotent)")
    func duplicateControllerValuesDrop() throws {
        let session = makeSession()
        session.ingest(cc(87, 10, atBeat: 9))
        session.ingest(cc(87, 10, atBeat: 9.5))   // duplicate → dropped
        session.ingest(cc(87, 10, atBeat: 10))    // duplicate → dropped
        session.ingest(cc(87, 20, atBeat: 10.5))  // new value → stored
        let result = session.finish(atBeat: 12)
        expectPoints(try #require(lane(result, .cc(controller: 87))).points,
                     [(1, 10), (2.5, 20)])
    }

    @Test("C12: sub-5 ms runs are suppressed but the FINAL value always lands at its own timestamp")
    func spacingSuppressionKeepsFinalValue() throws {
        // At 120 BPM, 5 ms = 0.01 beat. Three events inside one 5 ms window:
        // only the first and the run's FINAL value survive.
        let session = makeSession()
        session.ingest(cc(1, 10, atBeat: 9))
        session.ingest(cc(1, 20, atBeat: 9.002))   // +1 ms → suppressed
        session.ingest(cc(1, 30, atBeat: 9.004))   // +2 ms → replaces the pending
        let result = session.finish(atBeat: 12)
        let points = try #require(lane(result, .cc(controller: 1))).points
        #expect(points.count == 2)
        #expect(points[0] == MIDIControllerPoint(beat: 1, value: 10))
        #expect(points[1].value == 30)                       // the endpoint survived
        // ≤ 5e-9: the fixture's ticks(atBeat:) truncates to whole ticks — one
        // nanosecond tick = 2e-9 beats at 120 BPM (harness quantization, not
        // implementation error).
        #expect(abs(points[1].beat - 1.004) <= 5e-9)         // at its OWN timestamp
    }

    @Test("C12: a suppressed value that then HOLDS ≥ 5 ms commits at its own timestamp (not lost, not smeared)")
    func pendingValueThatHoldsCommits() throws {
        let session = makeSession()
        session.ingest(cc(1, 10, atBeat: 9))
        session.ingest(cc(1, 20, atBeat: 9.002))   // +1 ms → suppressed…
        session.ingest(cc(1, 30, atBeat: 9.2))     // …but 20 then HELD ~99 ms
        let result = session.finish(atBeat: 12)
        let points = try #require(lane(result, .cc(controller: 1))).points
        #expect(points.count == 3)
        #expect(points[0] == MIDIControllerPoint(beat: 1, value: 10))
        #expect(points[1].value == 20)               // the held value is audible truth
        // ≤ 5e-9: whole-tick fixture quantization (see above).
        #expect(abs(points[1].beat - 1.002) <= 5e-9)
        #expect(points[2].value == 30)
        #expect(abs(points[2].beat - 1.2) <= 5e-9)
    }

    @Test("C12: a fast continuous ramp thins to the spacing law with the endpoint kept")
    func fastRampThinsToSpacing() throws {
        // 20 events, 3 ms apart (host ticks directly — every comparison sits
        // a full millisecond away from the 5 ms boundary), values 1...20.
        // Stores land at 0/6/12/…/54 ms (values 1, 3, 5, …, 19); the pending
        // endpoint (20 @ 57 ms) flushes at finish at its own timestamp.
        let session = makeSession()
        for i in 0..<20 {
            session.ingest(LiveMIDIEvent(
                hostTime: Self.anchorTicks + UInt64(i) * 3_000_000, source: 1,
                kind: ScheduledMIDIEvent.controlChange, pitch: 11,
                velocity: UInt8(i + 1), channel: 0))
        }
        let result = session.finish(atBeat: 12)
        let points = try #require(lane(result, .cc(controller: 11))).points
        #expect(points.map(\.value) == [1, 3, 5, 7, 9, 11, 13, 15, 17, 19, 20])
        // 57 ms at 120 BPM = 0.114 beats — the endpoint's OWN timestamp.
        #expect(abs(points.last!.beat - 0.114) <= 1e-9)
    }

    @Test("C12: pre-anchor controller values LATCH (latest wins) and land at clip-relative beat 0 — the count-in pedal")
    func preAnchorLatchMaterializesAtBeatZero() throws {
        let session = makeSession()
        session.ingest(cc(64, 64, atBeat: 7))      // during the count-in…
        session.ingest(cc(64, 127, atBeat: 7.5))   // …latest pre-anchor value wins
        session.ingest(cc(64, 0, atBeat: 10))      // pedal up mid-take
        let result = session.finish(atBeat: 12)
        let points = try #require(lane(result, .cc(controller: 64))).points
        #expect(points.first?.beat == 0)           // the latch lands EXACTLY at 0
        expectPoints(points, [(0, 127), (2, 0)])
    }

    @Test("C12: a latch-only lane (pedal held through the whole take) still lands its beat-0 point")
    func latchOnlyLaneLandsSinglePoint() throws {
        let session = makeSession()
        session.ingest(cc(64, 127, atBeat: 7.5))   // count-in only, never moved
        let result = session.finish(atBeat: 12)
        #expect(try #require(lane(result, .cc(controller: 64))).points ==
                [MIDIControllerPoint(beat: 0, value: 127)])
    }

    @Test("C12: the first post-anchor event duplicating the latch drops (the latch timestamp is the truth)")
    func latchDuplicateFirstPostAnchorDrops() throws {
        let session = makeSession()
        session.ingest(cc(64, 127, atBeat: 7))
        session.ingest(cc(64, 127, atBeat: 9))     // same value → dropped
        let result = session.finish(atBeat: 12)
        #expect(try #require(lane(result, .cc(controller: 64))).points ==
                [MIDIControllerPoint(beat: 0, value: 127)])
    }

    @Test("C12: interleaved controllers never disturb note pairing (capture-side pitch-map bypass)")
    func controllersDoNotDisturbNotePairing() throws {
        let session = makeSession()
        session.ingest(on(60, atBeat: 9))
        session.ingest(cc(60, 99, atBeat: 9.5))    // controller 60 == the open PITCH
        session.ingest(bend(16_383, atBeat: 9.75))
        session.ingest(off(60, atBeat: 10))
        let result = session.finish(atBeat: 12)
        #expect(result.notes.count == 1)
        #expect(result.notes[0].startBeat == 1 && result.notes[0].lengthBeats == 1)
        expectPoints(try #require(lane(result, .cc(controller: 60))).points, [(1.5, 99)])
        expectPoints(try #require(lane(result, .pitchBend)).points, [(1.75, 16_383)])
    }

    @Test("C12: a note-only capture reports EMPTY controllerLanes (the additive default)")
    func noteOnlyCaptureYieldsEmptyLanes() {
        let session = makeSession()
        session.ingest(on(60, atBeat: 9))
        session.ingest(off(60, atBeat: 10))
        #expect(session.finish(atBeat: 12).controllerLanes.isEmpty)
        // And the result type's default keeps every pre-CC construction valid.
        #expect(MIDIRecordingResult(notes: [], lengthBeats: 1).controllerLanes.isEmpty)
    }

    @Test("C12: at the 16384-point store cap the lane halves and its spacing widens (never exceeds the wire cap)")
    func capWideningKeepsLaneUnderStoreCap() throws {
        // 20 000 distinct-value events at 6 ms spacing (> the 5 ms law, so
        // every one would store without the cap).
        let session = makeSession()
        for i in 0..<20_000 {
            session.ingest(cc(2, UInt8((i % 100) + 1), atBeat: 9 + Double(i) * 0.012))
        }
        let result = session.finish(atBeat: 9 + 20_000 * 0.012 + 1)
        let points = try #require(lane(result, .cc(controller: 2))).points
        #expect(points.count <= ProjectStore.maxControllerPointsPerLane)
        #expect(points.count > 8_000)                 // still a dense capture
        // First point and the gesture endpoint both survived the widening.
        #expect(points.first == MIDIControllerPoint(beat: 1, value: 1))
        #expect(points.last?.value == (19_999 % 100) + 1)
    }
}
