import Foundation
import Testing
@testable import DAWCore

// Reuses fakes already defined in the DAWCoreTests target:
//   FakeMedia (ImportTests.swift). Default info: 2.0 s → 4 beats at 120 BPM.

/// `ProjectStore.fitClipToContent` (m21-d): one-gesture "make the clip the
/// size its material is". MIDI trims (or extends) the trailing edge to the
/// last note's end; audio to the source file's remaining duration from the
/// current offset (tempo-map- and stretch-aware). Leading edge never moves;
/// empty MIDI clips are an honest no-op (`changed: false`); comp members are
/// rejected through the shared `requireNotCompMember` guard.
@MainActor
@Suite("ProjectStore — fit clip to content")
struct FitClipToContentTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// A store with one audio track holding one imported clip (start 0, source
    /// `durationSeconds` at 120 BPM → 2 beats per second, offset 0).
    private func storeWithAudioClip(
        durationSeconds: Double = 2.0
    ) throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: durationSeconds, sampleRate: 44_100, channelCount: 2))
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: track.id)
        return (store, track.id, clip)
    }

    // MARK: - MIDI

    @Test("MIDI: trailing edge lands EXACTLY on the last note's end (the odd AI length)")
    func midiFitsToLastNoteEnd() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        // The verified complaint's shape: an 8-beat clip whose material actually
        // ends at an odd, snap-hostile beat (2.37).
        let clip = try store.addMIDIClip(toTrack: inst.id, atBeat: 1, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, startBeat: 1.5, lengthBeats: 0.87),   // ends at 2.37
        ])

        let (fitted, changed) = try store.fitClipToContent(trackId: inst.id, clipId: clip.id)
        #expect(changed)
        #expect(fitted.id == clip.id)
        #expect(fitted.startBeat == 1)                     // leading edge unmoved
        #expect(abs(fitted.lengthBeats - 2.37) < 1e-12)    // note-end exactness
        #expect(fitted.notes?.count == 2)                  // nothing dropped/truncated
        #expect(store.tracks[0].clips[0].lengthBeats == fitted.lengthBeats)

        // Undo journals under the op's own label.
        #expect(try store.undo() == "Fit Clip to Content")
        #expect(store.tracks[0].clips[0].lengthBeats == 8)
    }

    @Test("MIDI: an overhanging last note EXTENDS the clip to cover it")
    func midiFitExtendsToOverhangingNote() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
        ])
        // setClipNotes does not clamp to the clip window, so a note can overhang
        // the 4-beat clip; fit means "match the content" in either direction.
        _ = try store.setClipNotes(clipID: clip.id, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 6),
        ])

        let (fitted, changed) = try store.fitClipToContent(trackId: inst.id, clipId: clip.id)
        #expect(changed)
        #expect(fitted.startBeat == 0)
        #expect(abs(fitted.lengthBeats - 6) < 1e-12)
    }

    @Test("MIDI: already exact → changed:false, clip untouched, no undo entry")
    func midiAlreadyExactIsHonestNoOp() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, startBeat: 2, lengthBeats: 2),        // ends at 4 == length
        ])

        let (echoed, changed) = try store.fitClipToContent(trackId: inst.id, clipId: clip.id)
        #expect(!changed)
        #expect(echoed == store.tracks[0].clips[0])
        // No "Fit Clip to Content" journal entry — the next undo is the add.
        #expect(try store.undo() != "Fit Clip to Content")
    }

    @Test("MIDI: a clip with ZERO notes is a no-op (changed:false), never an error")
    func midiEmptyClipNoOp() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 4, notes: [])

        let (echoed, changed) = try store.fitClipToContent(trackId: inst.id, clipId: clip.id)
        #expect(!changed)
        #expect(echoed.lengthBeats == 4)
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
        #expect(try store.undo() != "Fit Clip to Content")
    }

    @Test("comp member rejected with clipInTakeGroup (shared requireNotCompMember guard)")
    func compMemberRejected() throws {
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 62, startBeat: 0, lengthBeats: 1)])
        let track = Track(name: "Keys", kind: .instrument, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })

        let err = projectError {
            _ = try store.fitClipToContent(trackId: track.id, clipId: member.id)
        }
        if case .clipInTakeGroup? = err {} else {
            Issue.record("expected clipInTakeGroup, got \(String(describing: err))")
        }
    }

    @Test("unknown track / clip surface trackNotFound / clipNotFound")
    func unknownIDs() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        let e1 = projectError { _ = try store.fitClipToContent(trackId: UUID(), clipId: clip.id) }
        guard case .trackNotFound? = e1 else { Issue.record("expected trackNotFound"); return }
        let e2 = projectError { _ = try store.fitClipToContent(trackId: trackID, clipId: UUID()) }
        guard case .clipNotFound? = e2 else { Issue.record("expected clipNotFound"); return }
    }

    // MARK: - Audio

    @Test("audio: a clip longer than its source SHRINKS to the source's remaining duration")
    func audioShrinksToSource() throws {
        // 2.0 s source @120 BPM = 4 beats; stretch the visible window to 8.
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.trimClip(trackId: trackID, clipId: clip.id, newStartBeat: 0, newLengthBeats: 8)

        let (fitted, changed) = try store.fitClipToContent(trackId: trackID, clipId: clip.id)
        #expect(changed)
        #expect(fitted.startBeat == 0)
        #expect(abs(fitted.lengthBeats - 4) < 1e-9)    // never longer than the source
    }

    @Test("audio: fit honors the current startOffsetSeconds (remaining source only)")
    func audioFitFromOffset() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        // Head-trim 1 beat in: offset 0.5 s, remaining source 1.5 s = 3 beats;
        // then tail-trim to 1 beat so fit has something to restore.
        _ = try store.trimClip(trackId: trackID, clipId: clip.id, newStartBeat: 1, newLengthBeats: 1)

        let (fitted, changed) = try store.fitClipToContent(trackId: trackID, clipId: clip.id)
        #expect(changed)
        #expect(fitted.startBeat == 1)                                 // leading edge unmoved
        #expect(abs(fitted.startOffsetSeconds - 0.5) < 1e-12)          // offset untouched
        #expect(abs(fitted.lengthBeats - 3) < 1e-9)                    // 1.5 s @120 = 3 beats
    }

    @Test("audio: already exactly source-length → changed:false")
    func audioAlreadyExact() throws {
        // importAudio sizes the clip to the file: 2.0 s @120 = 4 beats exactly.
        let (store, trackID, clip) = try storeWithAudioClip()
        #expect(clip.lengthBeats == 4)

        let (echoed, changed) = try store.fitClipToContent(trackId: trackID, clipId: clip.id)
        #expect(!changed)
        #expect(echoed.lengthBeats == 4)
        #expect(try store.undo() != "Fit Clip to Content")
    }

    @Test("audio: the fit length follows the tempo (same source, different beats)")
    func audioFitIsTempoDependent() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.trimClip(trackId: trackID, clipId: clip.id, newStartBeat: 0, newLengthBeats: 1)

        // At 60 BPM a beat is a full second, so the 2.0 s source spans 2 beats.
        try store.setTempo(60)
        let (at60, _) = try store.fitClipToContent(trackId: trackID, clipId: clip.id)
        #expect(abs(at60.lengthBeats - 2) < 1e-9)

        // Back at 120 BPM the same source spans 4 beats.
        try store.setTempo(120)
        let (at120, changed) = try store.fitClipToContent(trackId: trackID, clipId: clip.id)
        #expect(changed)
        #expect(abs(at120.lengthBeats - 4) < 1e-9)
    }

    @Test("audio: stretched material occupies ratio× the source on the timeline")
    func audioFitIsStretchAware() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipStretch(trackId: trackID, clipId: clip.id, ratio: 2)

        // 2.0 s source at ratio 2 covers 4 s of timeline = 8 beats @120.
        let (fitted, changed) = try store.fitClipToContent(trackId: trackID, clipId: clip.id)
        #expect(changed)
        #expect(abs(fitted.lengthBeats - 8) < 1e-9)
    }
}
