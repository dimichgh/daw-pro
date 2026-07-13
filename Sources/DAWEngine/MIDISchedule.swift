import DAWCore
import Foundation

/// One scheduled MIDI event. POD, 24 bytes. `sampleTime` is in frames at the
/// schedule's sample rate, RELATIVE to the schedule anchor (anchor ≡ the
/// transport beat the schedule was built from).
///
/// m16-b2 — THE ONE DATA RULE (design-m16b §4.1): `pitch` ≡ MIDI data1 and
/// `velocity` ≡ MIDI data2 for EVERY kind. Notes already conformed (data1 =
/// key, data2 = velocity); CC is (controller#, value); pitch bend is
/// (LSB, MSB) in wire order; channel pressure is a TWO-byte message
/// (data1 = value, data2 unused = 0). No POD size change — 24 bytes stays
/// 24 bytes; consumers that switch on kinds 0/1 fall through safely.
struct ScheduledMIDIEvent: Equatable {
    var sampleTime: Int64
    var noteID: UInt64          // pairs on/off; unique within one schedule build
    var kind: UInt8             // 0 = noteOn, 1 = noteOff, 2/3/4 = CC/bend/pressure
    var pitch: UInt8            // MIDI data1
    var velocity: UInt8         // MIDI data2

    static let noteOn: UInt8 = 0
    static let noteOff: UInt8 = 1
    static let controlChange: UInt8 = 2    // pitch = controller#, velocity = value
    static let pitchBend: UInt8 = 3        // pitch = LSB (low 7), velocity = MSB (high 7)
    static let channelPressure: UInt8 = 4  // pitch = value (0...127), velocity = 0
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
    ///
    /// m16-b2 controller lanes (design-m16b §4.2/§5): kinds 2/3/4 join the
    /// SAME build. Each clip-lane point whose clip-relative beat ∈ [0,
    /// clipLen) — the note-onset rule verbatim — and whose absolute beat ∈
    /// [fromBeat, onsetEndBeat) emits ONE instantaneous event at the
    /// absolute-integral frame, with consecutive same-lane points that round
    /// to one frame coalesced LAST-WINS (the §7 decimation layer 3, C6). A
    /// CHASE PREFIX then opens every block: for each lane type present in ANY
    /// clip, one synthetic event at the block's own anchor frame
    /// (`round(offsetSeconds · rate)`) carrying the latest point value at a
    /// beat before `fromBeat` — the `MIDIControllerLane.value(atBeat:)`
    /// semantics merged across all clips by latest absolute beat, a clip
    /// wholly before the start point still contributing state — else the
    /// type's `neutralDefault`; injection is SKIPPED when the lane landed a
    /// literal event on that exact frame. The head build chases at `fromBeat`
    /// and every unrolled loop-cycle block (fromBeat == loop.startBeat)
    /// chases at the loop start, so each cycle opens with the state a fresh
    /// seek-to-loop-start would produce (deterministic cycles, §8.6 prune
    /// self-containment). The note NO-CHASE guard survives verbatim.
    ///
    /// m16-b2 signature (C5): returns the events AND the next unconsumed
    /// noteID — controller events consume IDs from the same running counter
    /// (uniqueness = sort determinism), so the old `count / 2` pair
    /// derivation is dead: with mixed kinds it double-books IDs across
    /// appended cycle blocks. Note-only builds are byte-identical (C1b) and
    /// still consume exactly one ID per note.
    static func buildEvents(clips: [Clip], fromBeat: Double, tempoMap: TempoMap,
                            sampleRate: Double,
                            onsetEndBeat: Double? = nil,
                            offsetSeconds: Double = 0,
                            noteIDBase: UInt64 = 0)
        -> (events: [ScheduledMIDIEvent], nextNoteID: UInt64) {
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

        // Controller-lane pass (m16-b2). One walk per (clip, lane) both emits
        // the in-window points and records the chase candidate — points are
        // canonically ascending, so "the latest value in effect before
        // fromBeat" is the last point scanned below the start. Note-only
        // clips add ZERO events here (C1b). Main-actor build math only.
        let anchorFrame = Int64((offsetSeconds * sampleRate).rounded())
        var laneTypes: [MIDIControllerType] = []       // first-seen; sorted at injection
        var seenTypes = Set<MIDIControllerType>()
        var chase: [MIDIControllerType: (beat: Double, value: Int)] = [:]
        var literalAtAnchor = Set<MIDIControllerType>()
        for clip in clips where clip.isMIDI {
            for lane in clip.controllerLanes {
                if seenTypes.insert(lane.type).inserted { laneTypes.append(lane.type) }
                var coalesceIndex = -1
                var coalesceFrame = Int64.min
                for point in lane.points {
                    guard point.beat < clip.lengthBeats else { continue }  // [0, clipLen)
                    let absBeat = clip.startBeat + point.beat
                    if absBeat < fromBeat {
                        // Chase candidate: latest absolute beat wins across
                        // clips; `>=` keeps later-array clips deterministic
                        // on an exact tie.
                        if let best = chase[lane.type], absBeat < best.beat { continue }
                        chase[lane.type] = (absBeat, point.value)
                        continue
                    }
                    if let onsetEndBeat, absBeat >= onsetEndBeat { continue }  // loop window
                    let frame = Int64(((offsetSeconds
                        + tempoMap.seconds(from: fromBeat, to: absBeat)) * sampleRate).rounded())
                    if frame == coalesceFrame {
                        // Same-frame same-lane coalescing: the LAST value wins
                        // in place; the slot's noteID is kept (coalescing
                        // replaces a value, it never mints an ID).
                        events[coalesceIndex] = controllerEvent(
                            type: lane.type, value: point.value,
                            sampleTime: frame, noteID: events[coalesceIndex].noteID)
                    } else {
                        events.append(controllerEvent(
                            type: lane.type, value: point.value,
                            sampleTime: frame, noteID: nextNoteID))
                        nextNoteID += 1
                        coalesceIndex = events.count - 1
                        coalesceFrame = frame
                    }
                    if frame == anchorFrame { literalAtAnchor.insert(lane.type) }
                }
            }
        }
        // Chase prefix (§5): one event per present lane type at the block's
        // anchor frame — rank 1, after same-frame offs and before same-frame
        // ons, so a chased sustain catches and a chased bend applies before
        // the first note sounds. Canonical type order for ID determinism.
        for type in laneTypes.sorted(by: { typeOrderKey($0) < typeOrderKey($1) })
        where !literalAtAnchor.contains(type) {
            events.append(controllerEvent(
                type: type, value: chase[type]?.value ?? type.neutralDefault,
                sampleTime: anchorFrame, noteID: nextNoteID))
            nextNoteID += 1
        }

        events.sort(by: orderedBefore)
        return (events, nextNoteID)
    }

    /// Encodes one controller-lane value as its schedule event under THE ONE
    /// DATA RULE (design-m16b §4.1). Values arrive canonically clamped
    /// (`MIDIControllerLane.canonicalPoints`); the clamps here are defensive.
    private static func controllerEvent(type: MIDIControllerType, value: Int,
                                        sampleTime: Int64,
                                        noteID: UInt64) -> ScheduledMIDIEvent {
        switch type {
        case .cc(let controller):
            return ScheduledMIDIEvent(
                sampleTime: sampleTime, noteID: noteID,
                kind: ScheduledMIDIEvent.controlChange,
                pitch: UInt8(clamping: controller), velocity: UInt8(clamping: value))
        case .pitchBend:
            let clamped = min(max(value, 0), 16_383)
            return ScheduledMIDIEvent(
                sampleTime: sampleTime, noteID: noteID,
                kind: ScheduledMIDIEvent.pitchBend,
                pitch: UInt8(clamped & 0x7F), velocity: UInt8((clamped >> 7) & 0x7F))
        case .channelPressure:
            return ScheduledMIDIEvent(
                sampleTime: sampleTime, noteID: noteID,
                kind: ScheduledMIDIEvent.channelPressure,
                pitch: UInt8(clamping: value), velocity: 0)
        }
    }

    /// Deterministic chase-injection order — the DAWCore canonical lane-type
    /// key mirrored engine-side (cc ascending by controller, then pitchBend,
    /// then channelPressure; CC numbers are clamp-bounded ≤ 127, so the
    /// 1000/1001 sentinels can never collide).
    private static func typeOrderKey(_ type: MIDIControllerType) -> Int {
        switch type {
        case .cc(let controller): return controller
        case .pitchBend: return 1_000
        case .channelPressure: return 1_001
        }
    }

    /// THE canonical event order — one definition shared by the in-build sort
    /// and the extension merge, so they can never disagree. Total over any
    /// valid build family (noteIDs unique, on/off distinct per ID; controller
    /// events carry IDs from the same counter).
    ///
    /// m16-b2 rank (design-m16b §4.1): off(0) < cc/bend/pressure(1) < on(2) at
    /// a shared frame — old notes end, controller state settles, new notes
    /// start. The chase-before-note-on law and the sustain-release-before-
    /// retrigger rule in one stroke; note-only schedules keep the off-before-on
    /// relative order, so existing builds sort byte-identically (C1b).
    static func orderedBefore(_ a: ScheduledMIDIEvent, _ b: ScheduledMIDIEvent) -> Bool {
        if a.sampleTime != b.sampleTime { return a.sampleTime < b.sampleTime }
        let rankA = kindRank(a.kind)
        let rankB = kindRank(b.kind)
        if rankA != rankB { return rankA < rankB }
        if a.pitch != b.pitch { return a.pitch < b.pitch }
        return a.noteID < b.noteID
    }

    @inline(__always)
    private static func kindRank(_ kind: UInt8) -> Int {
        switch kind {
        case ScheduledMIDIEvent.noteOff: return 0
        case ScheduledMIDIEvent.noteOn: return 2
        default: return 1   // controller state settles between offs and ons
        }
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
