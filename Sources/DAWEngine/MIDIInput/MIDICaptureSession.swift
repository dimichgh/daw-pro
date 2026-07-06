import DAWCore
import Foundation

/// Accumulates one take's live MIDI events into `MIDINote`s — main actor,
/// never the render thread (fed by the ~30 Hz capture-ring drain).
///
/// Time base: the SAME `PlaybackAnchor` the audio writer uses —
/// `beat(hostTime) = anchorBeats + Δticks · ticksToSeconds · tempo/60` with
/// signed tick math (mirror of `derivedBeats`). Count-in inherits for free:
/// the anchor is already count-in-delayed, and note-ons with beat < the
/// anchor beat are dropped (mirror of the writer's pre-anchor trim; their
/// offs drop with them as orphans). Tempo is fixed per take (`setTempo`
/// refuses mid-take), so drift is impossible by construction.
///
/// Pairing: channel-agnostic pitch → open note map. A note-off closes the
/// open pitch; orphan offs are dropped; a RETRIGGER of an open pitch closes
/// the previous note at the new onset, then opens a new one (deterministic,
/// no overlap loss). At `finish`, open notes clamp to the stop beat.
@MainActor
final class MIDICaptureSession {
    private let anchorHostTime: UInt64
    private let anchorBeats: Double
    private let tempoBPM: Double
    private let ticksToSeconds: Double
    /// pitch → (ABSOLUTE onset beat, velocity) for currently open notes.
    private var openNotes: [UInt8: (onBeat: Double, velocity: Int)] = [:]
    private var closed: [MIDINote] = []
    private var dropped = false

    init(anchorHostTime: UInt64, anchorBeats: Double, tempoBPM: Double, ticksToSeconds: Double) {
        self.anchorHostTime = anchorHostTime
        self.anchorBeats = anchorBeats
        self.tempoBPM = tempoBPM
        self.ticksToSeconds = ticksToSeconds
    }

    /// The capture ring overflowed mid-take: events were lost. Surfaced as
    /// `MIDIRecordingResult.droppedEvents`.
    func markDropped() {
        dropped = true
    }

    func ingest(_ event: LiveMIDIEvent) {
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
    func finish(atBeat stopBeat: Double) -> MIDIRecordingResult {
        for (pitch, open) in openNotes {
            closed.append(note(pitch: pitch, velocity: open.velocity,
                               onBeat: open.onBeat, offBeat: stopBeat))
        }
        openNotes.removeAll()
        return MIDIRecordingResult(
            notes: MIDINote.canonicallyOrdered(closed),
            lengthBeats: max(1, (stopBeat - anchorBeats).rounded(.up)),
            droppedEvents: dropped
        )
    }

    /// Signed host-tick → absolute beat math (mirror of `derivedBeats`).
    private func beat(forHostTime hostTime: UInt64) -> Double {
        let seconds = hostTime >= anchorHostTime
            ? Double(hostTime - anchorHostTime) * ticksToSeconds
            : -Double(anchorHostTime - hostTime) * ticksToSeconds
        return anchorBeats + seconds * tempoBPM / 60.0
    }

    /// Clip-relative note; `MIDINote.init` clamps length to ≥ 0.001 beats.
    private func note(pitch: UInt8, velocity: Int, onBeat: Double, offBeat: Double) -> MIDINote {
        MIDINote(pitch: Int(pitch), velocity: velocity,
                 startBeat: onBeat - anchorBeats, lengthBeats: offBeat - onBeat)
    }
}
