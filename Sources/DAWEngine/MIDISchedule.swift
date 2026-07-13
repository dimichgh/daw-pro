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
    /// Timeline identity (m14-b L-2, design §8.1 / §9-C2): schedules that
    /// share a `timelineID` share ONE anchor (`.live` host time / `.offline`
    /// latched epoch) and extend each other APPEND-ONLY — on a generation
    /// change with an UNCHANGED timelineID the render side RE-SEEKS its
    /// cursor (bounded binary search to the delivered watermark) instead of
    /// resetting to 0, so an extension republish never re-fires delivered
    /// note-ons and never skips pending note-offs. A CHANGED timelineID is a
    /// fresh anchor: full cursor reset + epoch re-latch (the pre-L-2
    /// behavior, still what every stop/seek/edit restart publishes). Defaults
    /// to `generation` — unique per publish — so every schedule built without
    /// an explicit family id is its own fresh timeline by construction.
    let timelineID: UInt64
    let mode: Mode
    let sampleRate: Double
    let events: UnsafeBufferPointer<ScheduledMIDIEvent>  // sorted, owned

    init(generation: UInt64, mode: Mode, sampleRate: Double, events: [ScheduledMIDIEvent],
         timelineID: UInt64? = nil) {
        self.generation = generation
        self.timelineID = timelineID ?? generation
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
    ///
    /// m14-b (L-2) loop-unroll parameters, all defaulted so every pre-L-2
    /// call is bit-identical (`0.0 + x == x` in IEEE):
    ///  · `onsetEndBeat`: exclusive onset window end — under a live loop only
    ///    ons in [fromBeat, onsetEndBeat) sound; a note's OFF may land past
    ///    it (tails ring through the seam, design §5). nil = no window.
    ///  · `offsetSeconds`: the SECOND-DOMAIN cycle offset, added BEFORE the
    ///    single `.rounded()` — `round((offset + integral) · rate)` is the
    ///    absolute-integral discipline (design §8.2 / C3); rounding the terms
    ///    separately could drift ±1 frame.
    ///  · `noteIDBase`: first noteID of this build — per-cycle blocks appended
    ///    into one schedule need schedule-wide unique IDs.
    static func buildEvents(clips: [Clip], fromBeat: Double, tempoMap: TempoMap,
                            sampleRate: Double,
                            onsetEndBeat: Double? = nil,
                            offsetSeconds: Double = 0,
                            noteIDBase: UInt64 = 0) -> [ScheduledMIDIEvent] {
        // m12-b (design row 37): event frames are the tempo-map integral from
        // the schedule anchor — `round(seconds(from: fromBeat, to: beat) ·
        // rate)`. Trivial-map arithmetic is bit-identical to the old
        // `(beat − fromBeat) · spb` (the map's same-segment fast path). The
        // no-chase guard below is beat-domain and stays untouched.
        var events: [ScheduledMIDIEvent] = []
        var nextNoteID: UInt64 = noteIDBase
        for clip in clips where clip.isMIDI {
            for note in clip.notes ?? [] {
                guard note.startBeat < clip.lengthBeats else { continue }  // [0, clipLen)
                let onBeat = clip.startBeat + note.startBeat
                guard onBeat >= fromBeat else { continue }                 // no chase v0
                if let onsetEndBeat, onBeat >= onsetEndBeat { continue }   // loop window
                let offBeat = clip.startBeat + min(note.endBeat, clip.lengthBeats)
                let on = Int64(((offsetSeconds
                    + tempoMap.seconds(from: fromBeat, to: onBeat)) * sampleRate).rounded())
                let off = max(on + 1,
                              Int64(((offsetSeconds
                                  + tempoMap.seconds(from: fromBeat, to: offBeat)) * sampleRate).rounded()))
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
        events.sort(by: orderedBefore)
        return events
    }

    /// THE canonical event order — one definition shared by the in-build sort
    /// and the extension merge, so they can never disagree. Total over any
    /// valid build family (noteIDs unique, on/off distinct per ID).
    static func orderedBefore(_ a: ScheduledMIDIEvent, _ b: ScheduledMIDIEvent) -> Bool {
        if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
        let rankA = a.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        let rankB = b.kind == ScheduledMIDIEvent.noteOff ? 0 : 1
        if rankA != rankB { return rankA < rankB }
        if a.pitch != b.pitch { return a.pitch < b.pitch }
        return a.noteID < b.noteID
    }

    /// Merges two canonically-sorted event arrays into one (m14-b L-2). Used
    /// to append a loop cycle's block: straddling note-offs from earlier
    /// cycles may land INSIDE the appended cycle's span, so plain
    /// concatenation would leave the array unsorted and the render slice
    /// would deliver the next cycle's ons LATE (blocked behind a later off).
    /// The merge keeps the global order; every element of `a` below `b`'s
    /// first time keeps its exact index — the delivered prefix is untouched
    /// (the C2 append-only law: appended events are strictly future).
    static func mergeSorted(_ a: [ScheduledMIDIEvent],
                            _ b: [ScheduledMIDIEvent]) -> [ScheduledMIDIEvent] {
        if b.isEmpty { return a }
        if a.isEmpty { return b }
        var merged: [ScheduledMIDIEvent] = []
        merged.reserveCapacity(a.count + b.count)
        var i = 0
        var j = 0
        while i < a.count, j < b.count {
            // `a` wins non-strict ties: existing events stay ahead of appended
            // ones at equal order (cannot occur in a valid family; defensive).
            if orderedBefore(b[j], a[i]) {
                merged.append(b[j])
                j += 1
            } else {
                merged.append(a[i])
                i += 1
            }
        }
        merged.append(contentsOf: a[i...])
        merged.append(contentsOf: b[j...])
        return merged
    }

    /// First index whose event time is ≥ `t` (bounded binary search — the
    /// render side's extension re-seek; `events.count` when every event is
    /// earlier). RENDER-THREAD SAFE: index math on the borrowed buffer only.
    static func lowerBound(_ events: UnsafeBufferPointer<ScheduledMIDIEvent>,
                           _ t: Int64) -> Int {
        var lo = 0
        var hi = events.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if events[mid].sampleTime < t { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }
}
