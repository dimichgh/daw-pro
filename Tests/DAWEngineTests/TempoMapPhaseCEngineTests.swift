import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m12-d Phase C — engine integration through the REAL store mutation
/// (design gate D). Phase B proved the multi-segment schedule math with maps
/// constructed inline; here the SAME boundary map (120 → 90 at beat 4) is
/// installed via `ProjectStore.setTempoMap` and read back through
/// `transport.tempoMap`, so the wire/undo-owning producer and the engine
/// consumer agree bit-for-bit. Onsets are the exact analytic integral (the
/// `==` discipline), reusing the Phase-B closed forms.
@MainActor
@Suite("Tempo map Phase C — real mutation feeds the engine")
struct TempoMapPhaseCEngineTests {

    @Test("a MIDI note at 4.1 scheduled through the store-installed map lands at frame 99 200")
    func realMutationDrivesSchedule() throws {
        let store = ProjectStore()
        try store.setTempoMap(TempoMap(segments: [
            .init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 90),
        ]))
        // The engine consumes exactly what the mutation installed.
        let map = store.transport.tempoMap
        #expect(map.segments.count == 2)

        let rate = 48_000.0
        let clip = Clip(name: "n", startBeat: 0, lengthBeats: 16, notes: [
            MIDINote(pitch: 60, startBeat: 3.9, lengthBeats: 0.05),  // pre-boundary
            MIDINote(pitch: 64, startBeat: 4.1, lengthBeats: 0.4),   // post-boundary
            MIDINote(pitch: 67, startBeat: 3.5, lengthBeats: 1.0),   // crosses beat 4
        ])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: map, sampleRate: rate).events

        // Closed forms (identical to the Phase-B fixture), computed HERE.
        let on39 = Int64((rate * (3.9 * (60.0 / 120.0))).rounded())
        let on41 = Int64((rate * (4.0 * (60.0 / 120.0) + 0.1 * (60.0 / 90.0))).rounded())
        let off45 = Int64((rate * (4.0 * (60.0 / 120.0) + 0.5 * (60.0 / 90.0))).rounded())
        #expect(on39 == 93_600)
        #expect(on41 == 99_200)
        #expect(off45 == 112_000)

        func onset(pitch: UInt8) -> Int64? {
            events.first { $0.pitch == pitch && $0.kind == ScheduledMIDIEvent.noteOn }?.sampleTime
        }
        #expect(onset(pitch: 60) == on39)
        #expect(onset(pitch: 64) == on41)          // the post-boundary integral
        // The crossing note's off integrates piecewise to beat 4.5 → same frame.
        #expect(events.first { $0.pitch == 67 && $0.kind == ScheduledMIDIEvent.noteOff }?.sampleTime == off45)
    }

    @Test("undo of the map restores trivial behavior for the engine schedule")
    func undoRestoresTrivialSchedule() throws {
        let store = ProjectStore()
        try store.setTempoMap(TempoMap(segments: [
            .init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 90),
        ]))
        try store.undo()
        let map = store.transport.tempoMap
        // Trivial 120 BPM everywhere → beat 4.1 is the plain linear form.
        let clip = Clip(name: "n", startBeat: 0, lengthBeats: 8,
                        notes: [MIDINote(pitch: 64, startBeat: 4.1, lengthBeats: 0.4)])
        let events = MIDIEventSchedule.buildEvents(
            clips: [clip], fromBeat: 0, tempoMap: map, sampleRate: 48_000).events
        let expected = Int64((48_000.0 * (4.1 * (60.0 / 120.0))).rounded())
        #expect(events.first { $0.kind == ScheduledMIDIEvent.noteOn }?.sampleTime == expected)
    }
}
