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
                           tempoBPM: 120, ticksToSeconds: 1e-9)
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
}
