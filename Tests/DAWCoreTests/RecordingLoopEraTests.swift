import CryptoKit
import Foundation
import Testing
@testable import DAWCore

/// m15-b G3 — the non-loop recording ERA: loop-DISABLED recording must be
/// byte-identical before/after the loop-record landing. This suite drives the
/// full store record → finish fan-out for every non-loop take shape (plain,
/// lagged under a multi-segment frozen map, punch-shaped offsets, auto-group
/// re-record, MIDI, mixed) and hashes the ENTIRE landed geometry — every
/// double printed at full precision (%.17g), so a single-ulp drift in any
/// landing formula flips the SHA.
///
/// The pinned digest was MEASURED on the pre-m15-b tree (2026-07-13, baseline
/// 2173/254) before any production change of this item — the suppression-lift
/// A/B artifact. If this pin ever breaks, the non-loop record path changed:
/// that is a regression, not an expectation to update.
@MainActor
@Suite("Recording non-loop era (m15-b G3)")
struct RecordingLoopEraTests {

    // MARK: - Canonical geometry dump (id-free, full precision)

    private func f(_ v: Double) -> String { String(format: "%.17g", v) }

    /// Canonical, UUID-free rendering of everything a take can land: clips
    /// (geometry + notes + group membership as a FLAG), take groups (lanes,
    /// comp, crossfade), and the recording error surface.
    private func canon(_ store: ProjectStore) -> String {
        var out = ""
        for track in store.tracks {
            out += "track \(track.name) [\(track.kind.rawValue)]\n"
            for clip in track.clips {
                out += "  clip \(clip.name) start=\(f(clip.startBeat)) len=\(f(clip.lengthBeats))"
                out += " off=\(f(clip.startOffsetSeconds)) grouped=\(clip.takeGroupID != nil)"
                out += " audio=\(clip.audioFileURL?.lastPathComponent ?? "-")\n"
                for n in clip.notes ?? [] {
                    out += "    note p=\(n.pitch) v=\(n.velocity) s=\(f(n.startBeat)) l=\(f(n.lengthBeats))\n"
                }
            }
            for group in track.takeGroups {
                out += "  group \(group.name) xf=\(f(group.crossfadeSeconds))\n"
                for lane in group.lanes {
                    let c = lane.clip
                    out += "    lane \(lane.name) start=\(f(c.startBeat)) len=\(f(c.lengthBeats))"
                    out += " off=\(f(c.startOffsetSeconds)) notes=\((c.notes ?? []).count)\n"
                    for n in c.notes ?? [] {
                        out += "      note p=\(n.pitch) v=\(n.velocity) s=\(f(n.startBeat)) l=\(f(n.lengthBeats))\n"
                    }
                }
                for seg in group.comp {
                    out += "    comp s=\(f(seg.startBeat)) e=\(f(seg.endBeat))\n"
                }
            }
        }
        out += "undo=\(store.undoLabel ?? "-") err=\(store.lastRecordingError ?? "-")\n"
        return out
    }

    private func audio(_ url: URL, duration: Double, lag: Double) -> RecordingResult {
        RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: duration, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: lag
        )
    }

    /// One audio record → stop → finish round trip on `FakeTakeEngine`.
    private func takeRound(_ store: ProjectStore, _ engine: FakeTakeEngine,
                           duration: Double, lag: Double,
                           midi: MIDIRecordingResult? = nil) throws {
        try store.record()
        store.stop()
        let url = engine.startTakeAudioURLs.last.flatMap { $0 }
            ?? URL(fileURLWithPath: "/tmp/era-midi-only.wav")
        let audioSide: RecordingResult? = engine.startTakeAudioURLs.last.flatMap { $0 }
            .map { _ in audio(url, duration: duration, lag: lag) }
        engine.finishTake(.success(TakeResult(audio: audioSide, midi: midi)))
    }

    // MARK: - The era

    @Test("non-loop record fan-out geometry: SHA pinned across the m15-b lift")
    func nonLoopEraDigest() throws {
        var transcript = ""

        // Scenario 1 — plain audio take at beat 0, zero lag, then a lagged
        // take at a seeked position under a MULTI-SEGMENT frozen map.
        do {
            let engine = FakeTakeEngine()
            let store = ProjectStore()
            store.engine = engine
            let track = store.addTrack(name: "Gtr", kind: .audio)
            try store.setTrackArm(id: track.id, armed: true)
            try takeRound(store, engine, duration: 2.0, lag: 0)

            try store.setTempoMap(try TempoMap(segments: [
                TempoMap.Segment(startBeat: 0, bpm: 120),
                TempoMap.Segment(startBeat: 8, bpm: 90),
            ]))
            try store.seek(toBeats: 7)  // take crosses the 120→90 boundary
            try takeRound(store, engine, duration: 3.0, lag: 0.0250244140625)
            transcript += "S1\n" + canon(store)
        }

        // Scenario 2 — punch-shaped offsets: the writer reports offset =
        // punch-in − record start (+ lag) and the window's duration; the
        // store formula must land the clip at the punch-in beat.
        do {
            let engine = FakeTakeEngine()
            let store = ProjectStore()
            store.engine = engine
            let track = store.addTrack(name: "Vox", kind: .audio)
            try store.setTrackArm(id: track.id, armed: true)
            try store.setPunch(enabled: true, inBeat: 4, outBeat: 8)
            try store.seek(toBeats: 2)
            // 120 BPM: punch-in is 1.0 s past the record start, window 2.0 s.
            try takeRound(store, engine, duration: 2.0, lag: 1.0)
            transcript += "S2\n" + canon(store)
        }

        // Scenario 3 — overlap re-record: plain → group (case 2) → lane
        // append (case 1); the auto-group fan-out is part of the era.
        do {
            let engine = FakeTakeEngine()
            let store = ProjectStore()
            store.engine = engine
            let track = store.addTrack(name: "Keys", kind: .audio)
            try store.setTrackArm(id: track.id, armed: true)
            try takeRound(store, engine, duration: 2.0, lag: 0)
            try takeRound(store, engine, duration: 2.0, lag: 0)
            try takeRound(store, engine, duration: 2.0, lag: 0)
            transcript += "S3\n" + canon(store)
        }

        // Scenario 4 — MIDI-only and mixed takes (notes land verbatim, punch
        // never trims MIDI, empty-MIDI discard message).
        do {
            let engine = FakeTakeEngine()
            let store = ProjectStore()
            store.engine = engine
            let inst = store.addTrack(name: "Synth", kind: .instrument)
            try store.setTrackArm(id: inst.id, armed: true)
            let notes = [
                MIDINote(pitch: 60, velocity: 96, startBeat: 0.5, lengthBeats: 1.25),
                MIDINote(pitch: 64, velocity: 80, startBeat: 2.0, lengthBeats: 0.5),
            ]
            try takeRound(store, engine, duration: 0, lag: 0,
                          midi: MIDIRecordingResult(notes: notes, lengthBeats: 4))
            // Mixed: arm an audio sibling too.
            let gtr = store.addTrack(name: "Amp", kind: .audio)
            try store.setTrackArm(id: gtr.id, armed: true)
            try takeRound(store, engine, duration: 1.5, lag: 0,
                          midi: MIDIRecordingResult(notes: notes, lengthBeats: 4))
            // Empty MIDI take → discarded with the exact message.
            try store.record()
            store.stop()
            engine.finishTake(.success(TakeResult(
                audio: nil, midi: MIDIRecordingResult(notes: [], lengthBeats: 1))))
            transcript += "S4\n" + canon(store)
        }

        let digest = SHA256.hash(data: Data(transcript.utf8))
            .map { String(format: "%02x", $0) }.joined()
        print("[measured] m15-b G3 era digest: \(digest)")
        #expect(digest == "7013644e18c0c01f51eeb07bcda2779f4ffa10705f6dbb146bdee5b1bf111a34")
    }
}
