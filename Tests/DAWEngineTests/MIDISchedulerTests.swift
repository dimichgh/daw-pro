import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// M3 (iii) schedule-build math: pure, engine-free assertions on
/// `MIDIEventSchedule.buildEvents`. 48 kHz, 120 BPM unless noted —
/// 1 beat = 24 000 frames. Frame values are EXACT.
@Suite("MIDI schedule build math")
struct MIDISchedulerTests {
    private let rate = 48_000.0

    private func midiClip(startBeat: Double, lengthBeats: Double,
                          notes: [MIDINote]) -> Clip {
        Clip(name: "midi", startBeat: startBeat, lengthBeats: lengthBeats, notes: notes)
    }

    // A. Basic placement.
    @Test("clip@1, note p60 v100 @0 len 1 → on 24000 / off 48000, exact events")
    func basicPlacement() {
        let clip = midiClip(startBeat: 1, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: rate)
        let expected = [
            ScheduledMIDIEvent(sampleTime: 24_000, noteID: 0, kind: 0, pitch: 60, velocity: 100),
            ScheduledMIDIEvent(sampleTime: 48_000, noteID: 0, kind: 1, pitch: 60, velocity: 0),
        ]
        #expect(events == expected)
    }

    // B. fromBeat offset + no-chase.
    @Test("fromBeat 2 suppresses earlier onsets entirely (no chase); later note exact")
    func fromBeatSuppressesEarlierOnsets() {
        let clip = midiClip(startBeat: 1, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, velocity: 90, startBeat: 1.5, lengthBeats: 0.5),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 2, tempoMap: TempoMap(constantBPM: 120), sampleRate: rate)
        // p60 (absolute onset 1.0 < 2) contributes ZERO events — its on AND
        // off are both suppressed. p64: on at beat 2.5, off at beat 3.0.
        #expect(events.count == 2)
        #expect(events[0].kind == 0 && events[0].pitch == 64 && events[0].velocity == 90)
        #expect(events[0].sampleTime == 12_000)
        #expect(events[1].kind == 1 && events[1].pitch == 64 && events[1].velocity == 0)
        #expect(events[1].sampleTime == 24_000)
        #expect(events[0].noteID == events[1].noteID)
        #expect(!events.contains { $0.pitch == 60 })
    }

    // C. Truncation at clip end; half-open [0, clipLen) onset window.
    @Test("note spilling past the clip truncates at the clip end; onset ≥ clipLen drops")
    func truncationAtClipEnd() {
        let spilling = midiClip(startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 1.5, lengthBeats: 4),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [spilling], fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: rate)
        #expect(events.count == 2)
        #expect(events[1].sampleTime - events[0].sampleTime == 12_000)  // off at clip end

        let atEnd = midiClip(startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 2.0, lengthBeats: 1),
        ])
        #expect(MIDIEventSchedule.buildEvents(
            clips: [atEnd], fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: rate).isEmpty)

        let pastEnd = midiClip(startBeat: 0, lengthBeats: 2, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 2.5, lengthBeats: 1),
        ])
        #expect(MIDIEventSchedule.buildEvents(
            clips: [pastEnd], fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: rate).isEmpty)
    }

    // D. Same-pitch overlap → distinct paired noteIDs.
    @Test("same-pitch overlap: 4 events, distinct noteIDs, offs pair their ons")
    func samePitchOverlap() {
        let clip = midiClip(startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2),
            MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 2),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: rate)
        #expect(events.count == 4)
        #expect(events[0].sampleTime == 0 && events[0].kind == 0)
        #expect(events[1].sampleTime == 24_000 && events[1].kind == 0)
        #expect(events[2].sampleTime == 48_000 && events[2].kind == 1)
        #expect(events[3].sampleTime == 72_000 && events[3].kind == 1)
        let idA = events[0].noteID
        let idB = events[1].noteID
        #expect(idA != idB)
        #expect(events[2].noteID == idA)  // first off pairs the first on
        #expect(events[3].noteID == idB)
    }

    // E. Adjacency tie: off BEFORE on at the shared frame (load-bearing —
    // back-to-back same-pitch notes must not have the new voice killed).
    @Test("back-to-back same-pitch notes: off precedes on at the shared frame")
    func adjacencyOffBeforeOn() {
        let clip = midiClip(startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 60, velocity: 100, startBeat: 1, lengthBeats: 1),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: TempoMap(constantBPM: 120), sampleRate: rate)
        #expect(events.count == 4)
        let shared = events.filter { $0.sampleTime == 24_000 }
        #expect(shared.count == 2)
        #expect(shared[0].kind == 1)   // off first…
        #expect(shared[1].kind == 0)   // …then on, in array order
        #expect(shared[0].noteID == events[0].noteID)
        #expect(shared[1].noteID == events[3].noteID)
    }

    // F. Rounding floor at the tempo cap.
    @Test("400 BPM, minimum-length note → off − on == 7 frames")
    func roundingFloorAtTempoCap() {
        let clip = midiClip(startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 0.001),
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: TempoMap(constantBPM: 400), sampleRate: rate)
        #expect(events.count == 2)
        let width = events[1].sampleTime - events[0].sampleTime
        #expect(width >= 1)
        #expect(width == 7)  // 0.001 beat × 0.15 s/beat × 48000 = 7.2 → 7
    }
}
