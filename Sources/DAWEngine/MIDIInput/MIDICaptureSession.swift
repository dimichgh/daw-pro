import DAWCore
import Foundation

/// Accumulates one take's live MIDI events into `MIDINote`s (and, since
/// m16-b3, controller lanes) — main actor, never the render thread (fed by
/// the ~30 Hz capture-ring drain).
///
/// Time base: the SAME `PlaybackAnchor` the audio writer uses —
/// `beat(hostTime) = tempoMap.beat(from: anchorBeats, elapsedSeconds:
/// Δticks · ticksToSeconds)` with signed tick math (mirror of
/// `derivedBeats`; m12-b design row 54). Count-in inherits for free: the
/// anchor is already count-in-delayed, and note-ons with beat < the anchor
/// beat are dropped (mirror of the writer's pre-anchor trim; their offs drop
/// with them as orphans). The map is fixed per take (`setTempo` refuses
/// mid-take), so drift is impossible by construction.
///
/// Pairing: channel-agnostic pitch → open note map. A note-off closes the
/// open pitch; orphan offs are dropped; a RETRIGGER of an open pitch closes
/// the previous note at the new onset, then opens a new one (deterministic,
/// no overlap loss). At `finish`, open notes clamp to the stop beat.
///
/// Controllers (kinds 2/3/4, design-m16b §8.4): events accumulate into
/// per-type point lanes through the same frozen-map beat math, thinned AT
/// INGEST per the §7 capture law — consecutive duplicate values drop
/// (repeated CC bytes are semantically idempotent), stored points keep
/// ≥ `minPointSpacingSeconds` spacing, and the FINAL value of a suppressed
/// run is always emitted at its own timestamp (a fast gesture's endpoint is
/// never lost — the one sanctioned spacing exception). Pre-anchor controller
/// events LATCH (latest wins) instead of dropping: a controller VALUE at
/// take start is the truth (unlike a partial note, which would be a lie), so
/// the latch materializes as a clip-relative beat-0 point — the count-in
/// pedal case. `finish` needs no clamp for lanes: points are instantaneous.
@MainActor
final class MIDICaptureSession {
    /// §7 layer-1 thinning: minimum spacing between STORED points per lane
    /// (≈ 200 Hz/lane — measured-safe by 30×, design-m16b §7). `nonisolated`:
    /// a pure constant, used as a struct default in a nonisolated context.
    nonisolated static let minPointSpacingSeconds = 0.005

    private let anchorHostTime: UInt64
    private let anchorBeats: Double
    private let tempoMap: TempoMap
    private let ticksToSeconds: Double
    /// pitch → (ABSOLUTE onset beat, velocity) for currently open notes.
    private var openNotes: [UInt8: (onBeat: Double, velocity: Int)] = [:]
    private var closed: [MIDINote] = []
    private var dropped = false

    /// One controller stream's in-flight capture state (design-m16b §8.4).
    private struct LaneCapture {
        /// Latest value seen BEFORE the anchor (the count-in latch): the
        /// state in effect when the take starts. Materializes as a
        /// clip-relative beat-0 point at the first post-anchor touch of this
        /// lane (or at `finish` if nothing else arrives).
        var preAnchorValue: Int?
        /// Stored (already thinned) points, clip-relative beats, in arrival
        /// order — arrival is host-time-ordered (single-producer FIFO ring),
        /// so this is ascending by construction.
        var points: [MIDIControllerPoint] = []
        /// Anchor-relative seconds of the last STORED point (spacing law).
        var lastStoredSeconds: Double = -.infinity
        /// The currently suppressed run's newest event: committed at its own
        /// timestamp once it has HELD ≥ the spacing (the next value change
        /// arrives ≥ spacing later), or at `finish` — the final-value law.
        /// Replaced in place while the run keeps moving inside the window.
        var pending: (beat: Double, seconds: Double, value: Int)?
        /// Per-lane minimum spacing; starts at `minPointSpacingSeconds` and
        /// DOUBLES on each cap-overflow thinning pass (the §7 "second-stage
        /// spacing widening" — capture never exceeds the store's
        /// 16384-points-per-lane teaching cap).
        var minSpacingSeconds = MIDICaptureSession.minPointSpacingSeconds
    }
    private var lanes: [MIDIControllerType: LaneCapture] = [:]

    init(anchorHostTime: UInt64, anchorBeats: Double, tempoMap: TempoMap, ticksToSeconds: Double) {
        self.anchorHostTime = anchorHostTime
        self.anchorBeats = anchorBeats
        self.tempoMap = tempoMap
        self.ticksToSeconds = ticksToSeconds
    }

    /// The capture ring overflowed mid-take: events were lost. Surfaced as
    /// `MIDIRecordingResult.droppedEvents`.
    func markDropped() {
        dropped = true
    }

    func ingest(_ event: LiveMIDIEvent) {
        // Kinds 2/3/4 (m16-b3) route to the lane accumulator and never touch
        // the note pairing map — an interleaved CC can't corrupt an open note.
        if event.kind >= ScheduledMIDIEvent.controlChange {
            ingestController(event)
            return
        }
        let beat = beat(forHostTime: event.hostTime)
        if event.kind == ScheduledMIDIEvent.noteOn {
            // Pre-anchor (count-in / lead-in) ons are dropped, like the audio
            // writer's pre-anchor trim. Their offs become orphans and drop too.
            guard beat >= anchorBeats else { return }
            if let open = openNotes[event.pitch] {
                // Retrigger of an open pitch: close the previous note at the
                // new onset, then open the new one.
                closed.append(note(pitch: event.pitch, velocity: open.velocity,
                                   onBeat: open.onBeat, offBeat: beat))
            }
            openNotes[event.pitch] = (onBeat: beat, velocity: Int(event.velocity))
        } else {
            guard let open = openNotes.removeValue(forKey: event.pitch) else { return }  // orphan off
            closed.append(note(pitch: event.pitch, velocity: open.velocity,
                               onBeat: open.onBeat, offBeat: beat))
        }
    }

    /// Ends the take at `stopBeat` (computed from `derivedBeats()` BEFORE
    /// playback teardown): open notes clamp to the stop beat, notes come back
    /// clip-relative and canonically ordered, and the clip length is the
    /// whole-beat cover of the take (min 1 — matches `addMIDIClip` sizing).
    /// Controller lanes flush their suppressed-run tail (final-value law),
    /// materialize untouched count-in latches at beat 0, and come back
    /// canonical (`Clip.canonicalControllerLanes` — sorted by type key).
    func finish(atBeat stopBeat: Double) -> MIDIRecordingResult {
        for (pitch, open) in openNotes {
            closed.append(note(pitch: pitch, velocity: open.velocity,
                               onBeat: open.onBeat, offBeat: stopBeat))
        }
        openNotes.removeAll()
        var finishedLanes: [MIDIControllerLane] = []
        for (type, var lane) in lanes {
            if let pending = lane.pending {
                // The final value of a suppressed run is never lost — emitted
                // at its own timestamp even inside the spacing window (§7).
                lane.points.append(MIDIControllerPoint(beat: pending.beat, value: pending.value))
                lane.pending = nil
            }
            if lane.points.isEmpty, let latched = lane.preAnchorValue {
                // Count-in-only lane (pedal pressed during the count-in and
                // never moved): the state at take start is still the truth.
                lane.points.append(MIDIControllerPoint(beat: 0, value: latched))
            }
            if !lane.points.isEmpty {
                finishedLanes.append(MIDIControllerLane(type: type, points: lane.points))
            }
        }
        lanes.removeAll()
        return MIDIRecordingResult(
            notes: MIDINote.canonicallyOrdered(closed),
            lengthBeats: max(1, (stopBeat - anchorBeats).rounded(.up)),
            droppedEvents: dropped,
            controllerLanes: Clip.canonicalControllerLanes(finishedLanes)
        )
    }

    // MARK: - Controller lanes (m16-b3)

    /// Kind ≥ 2 ingest: map the event to its lane type + raw value (the §4.1
    /// one-data-rule — bend reassembles `(MSB << 7) | LSB`), then apply the
    /// §7 thinning law streaming-style. Amortized-allocation only (dictionary
    /// + growing arrays, the `closed` notes discipline) — never the render
    /// thread.
    private func ingestController(_ event: LiveMIDIEvent) {
        let type: MIDIControllerType
        let value: Int
        switch event.kind {
        case ScheduledMIDIEvent.controlChange:
            type = .cc(controller: Int(event.pitch & 0x7F))
            value = Int(event.velocity & 0x7F)
        case ScheduledMIDIEvent.pitchBend:
            type = .pitchBend
            value = (Int(event.velocity & 0x7F) << 7) | Int(event.pitch & 0x7F)
        case ScheduledMIDIEvent.channelPressure:
            type = .channelPressure
            value = Int(event.pitch & 0x7F)
        default:
            return  // future kinds: ignored until modeled
        }
        let seconds = elapsedSeconds(forHostTime: event.hostTime)
        var lane = lanes[type] ?? LaneCapture()
        defer { lanes[type] = lane }

        // Pre-anchor values LATCH (latest wins): the state at take start.
        guard seconds >= 0 else {
            lane.preAnchorValue = value
            return
        }
        // Materialize the count-in latch at clip-relative beat 0 the first
        // time this lane is touched after the anchor; the thinning below then
        // treats it as the first stored point (a duplicate first event drops).
        if lane.points.isEmpty, lane.pending == nil, let latched = lane.preAnchorValue {
            lane.points.append(MIDIControllerPoint(beat: 0, value: latched))
            lane.lastStoredSeconds = 0
            lane.preAnchorValue = nil
        }

        // §7 duplicate drop, against the latest STREAM value (pending wins —
        // if the run already reached this value, the earlier timestamp is
        // when it became true).
        if value == (lane.pending?.value ?? lane.points.last?.value) { return }

        // A suppressed run whose newest value has now HELD ≥ the spacing is
        // no fast wiggle — commit it at its own timestamp (final-value law;
        // this is the one place a stored point may sit closer than the
        // spacing to its predecessor).
        if let pending = lane.pending, seconds - pending.seconds >= lane.minSpacingSeconds {
            store(&lane, beat: pending.beat, seconds: pending.seconds, value: pending.value)
            lane.pending = nil
        }

        // Clip-relative beat via the SAME frozen-map inverse integral the
        // note path uses (one clock for the whole take).
        let beat = tempoMap.beat(from: anchorBeats, elapsedSeconds: seconds) - anchorBeats
        if seconds - lane.lastStoredSeconds >= lane.minSpacingSeconds {
            // Far enough from the last stored point: store directly. Any
            // still-pending older value was interior to a fast run — dropped
            // (that is the thinning's whole point).
            store(&lane, beat: beat, seconds: seconds, value: value)
            lane.pending = nil
        } else {
            // Inside the spacing window: the run is suppressed; track its
            // newest value so the endpoint can never be lost.
            lane.pending = (beat: beat, seconds: seconds, value: value)
        }
    }

    /// Appends one stored point and applies the §7 second-stage widening: at
    /// the store's 16384-points-per-lane teaching cap, interior density
    /// halves (first/last kept) and the lane's spacing doubles, so a capture
    /// can never exceed what `clip.setControllerLane` would accept.
    private func store(_ lane: inout LaneCapture, beat: Double, seconds: Double, value: Int) {
        lane.points.append(MIDIControllerPoint(beat: beat, value: value))
        lane.lastStoredSeconds = seconds
        if lane.points.count >= ProjectStore.maxControllerPointsPerLane {
            var thinned: [MIDIControllerPoint] = []
            thinned.reserveCapacity(lane.points.count / 2 + 1)
            let lastIndex = lane.points.count - 1
            for index in lane.points.indices where index % 2 == 0 || index == lastIndex {
                thinned.append(lane.points[index])
            }
            lane.points = thinned
            lane.minSpacingSeconds *= 2
        }
    }

    // MARK: - Time base

    /// Signed host-tick → anchor-relative seconds (negative during count-in).
    private func elapsedSeconds(forHostTime hostTime: UInt64) -> Double {
        hostTime >= anchorHostTime
            ? Double(hostTime - anchorHostTime) * ticksToSeconds
            : -Double(anchorHostTime - hostTime) * ticksToSeconds
    }

    /// Signed host-tick → absolute beat math (mirror of `derivedBeats`):
    /// the map's inverse integral from the take anchor (m12-b, row 54).
    private func beat(forHostTime hostTime: UInt64) -> Double {
        tempoMap.beat(from: anchorBeats, elapsedSeconds: elapsedSeconds(forHostTime: hostTime))
    }

    /// Clip-relative note; `MIDINote.init` clamps length to ≥ 0.001 beats.
    private func note(pitch: UInt8, velocity: Int, onBeat: Double, offBeat: Double) -> MIDINote {
        MIDINote(pitch: Int(pitch), velocity: velocity,
                 startBeat: onBeat - anchorBeats, lengthBeats: offBeat - onBeat)
    }
}
