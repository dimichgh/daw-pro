import DAWCore
import Foundation

/// One scheduled MIDI event. POD, 24 bytes. `sampleTime` is in frames at the
/// schedule's sample rate, RELATIVE to the schedule anchor (anchor ≡ the
/// transport beat the schedule was built from). kind values 2+ are reserved
/// (CC / pitch bend / sustain arrive additively, post-v0).
struct ScheduledMIDIEvent: Equatable {
    var sampleTime: Int64
    var noteID: UInt64          // pairs on/off; unique within one schedule build
    var kind: UInt8             // 0 = noteOn, 1 = noteOff
    var pitch: UInt8            // 0...127
    var velocity: UInt8         // on: 1...127; off: 0

    static let noteOn: UInt8 = 0
    static let noteOff: UInt8 = 1
}

/// Immutable, render-thread-readable schedule for ONE instrument track.
/// Events live in memory the schedule allocates in init and frees in deinit —
/// no Swift Array machinery on the render thread. Published to the render
/// side via `daw_atomic_ptr` (Unmanaged, retained by the slot); retired
/// schedules are kept alive ≥ 1 s by the main actor before release (see
/// `InstrumentRenderer.publish`).
final class MIDIEventSchedule {
    enum Mode {
        case live(anchorHostTime: UInt64)   // event t=0 sounds at this host time
        case offline                        // event t=0 ≡ first pulled sample (latched epoch)
    }

    let generation: UInt64                  // monotonic; render side resets its cursor on change
    let mode: Mode
    let sampleRate: Double
    let events: UnsafeBufferPointer<ScheduledMIDIEvent>  // sorted, owned

    init(generation: UInt64, mode: Mode, sampleRate: Double, events: [ScheduledMIDIEvent]) {
        self.generation = generation
        self.mode = mode
        self.sampleRate = sampleRate
        if events.isEmpty {
            self.events = UnsafeBufferPointer(start: nil, count: 0)
        } else {
            let storage = UnsafeMutableBufferPointer<ScheduledMIDIEvent>.allocate(
                capacity: events.count)
            _ = storage.initialize(from: events)
            self.events = UnsafeBufferPointer(storage)
        }
    }

    deinit {
        if events.baseAddress != nil {
            UnsafeMutableBufferPointer(mutating: events).deallocate()
        }
    }

    /// Pure build math — headless-testable without any engine. Contract
    /// (MIDI data model: SETTLED):
    ///  · a note sounds iff its onset ∈ [0, clip length) in clip-relative beats
    ///  · off at min(note end, clip end); off ≥ on + 1 frame defensively
    ///    (`MIDINote.minLengthBeats` at the 400 BPM tempo cap is ≥ 7 frames at
    ///    48 kHz, so rounding can never collapse a note — the clamp is defense)
    ///  · NO note chase v0: the onset must also be ≥ fromBeat, else BOTH events
    ///    are dropped (a note sounding across the start point does not sound)
    ///  · same-pitch overlaps are legal: noteID pairs ons with their offs
    ///  · sort key: (sampleTime, kindRank[off BEFORE on], pitch, noteID) — the
    ///    off-before-on tie rule is load-bearing: back-to-back same-pitch notes
    ///    ([0,1) then [1,2)) must deliver off(A) before on(B) at the shared
    ///    frame so the new voice isn't killed
    static func buildEvents(clips: [Clip], fromBeat: Double, tempoBPM: Double,
                            sampleRate: Double) -> [ScheduledMIDIEvent] {
        let secondsPerBeat = 60.0 / tempoBPM
        var events: [ScheduledMIDIEvent] = []
        var nextNoteID: UInt64 = 0
        for clip in clips where clip.isMIDI {
            for note in clip.notes ?? [] {
                guard note.startBeat < clip.lengthBeats else { continue }  // [0, clipLen)
                let onBeat = clip.startBeat + note.startBeat
                guard onBeat >= fromBeat else { continue }                 // no chase v0
                let offBeat = clip.startBeat + min(note.endBeat, clip.lengthBeats)
                let on = Int64(((onBeat - fromBeat) * secondsPerBeat * sampleRate).rounded())
                let off = max(on + 1,
                              Int64(((offBeat - fromBeat) * secondsPerBeat * sampleRate).rounded()))
                let id = nextNoteID
                nextNoteID += 1
                let pitch = UInt8(clamping: note.pitch)
                events.append(ScheduledMIDIEvent(
                    sampleTime: on, noteID: id, kind: ScheduledMIDIEvent.noteOn,
                    pitch: pitch, velocity: UInt8(clamping: note.velocity)))
                events.append(ScheduledMIDIEvent(
                    sampleTime: off, noteID: id, kind: ScheduledMIDIEvent.noteOff,
                    pitch: pitch, velocity: 0))
            }
        }
        events.sort { a, b in
            if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
            let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
            if rankA != rankB { return rankA < rankB }
            if a.pitch != b.pitch { return a.pitch < b.pitch }
            return a.noteID < b.noteID
        }
        return events
    }
}
