import Foundation
import Testing
@testable import DAWCore

// Reuses fakes already defined in the DAWCoreTests target:
//   FakeMedia (ImportTests.swift), FakeEngine (CoreTests.swift).

@Suite("MIDINote")
struct MIDINoteTests {
    // 1.
    @Test("init clamps pitch, velocity, startBeat, and length")
    func clamping() {
        let low = MIDINote(pitch: -5, velocity: -10, startBeat: -3, lengthBeats: -1)
        #expect(low.pitch == 0)
        #expect(low.velocity == 1)          // velocity floor is 1 (0 = note-off)
        #expect(low.startBeat == 0)
        #expect(low.lengthBeats == MIDINote.minLengthBeats)

        let high = MIDINote(pitch: 999, velocity: 999, startBeat: 8, lengthBeats: 2)
        #expect(high.pitch == 127)
        #expect(high.velocity == 127)
        #expect(high.startBeat == 8)
        #expect(high.lengthBeats == 2)

        // Defaults: velocity 100, length 1.0.
        let plain = MIDINote(pitch: 60, startBeat: 1)
        #expect(plain.velocity == 100)
        #expect(plain.lengthBeats == 1.0)
    }

    // 2.
    @Test("endBeat and canonicallyOrdered sort by onset, pitch, then id")
    func orderingAndEnd() {
        let a = MIDINote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
                         pitch: 64, startBeat: 1, lengthBeats: 2)
        #expect(a.endBeat == 3)

        let b = MIDINote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
                         pitch: 60, startBeat: 0, lengthBeats: 1)
        let c = MIDINote(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
                         pitch: 62, startBeat: 0, lengthBeats: 1)
        // Same onset+pitch, different id → id.uuidString breaks the tie.
        let d1 = MIDINote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!,
                          pitch: 60, startBeat: 0)
        let d2 = MIDINote(id: UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!,
                          pitch: 60, startBeat: 0)

        let ordered = MIDINote.canonicallyOrdered([a, c, b, d2, d1])
        // Onset 0 group first (pitch 60 ×3 by ascending uuidString: ...002,
        // ...00A, ...00B; then pitch 62), then onset 1.
        #expect(ordered.map(\.id) == [b.id, d1.id, d2.id, c.id, a.id])
    }

    // 3.
    @Test("Codable: required pitch+startBeat, defaulted id/velocity/length, all five keys round-trip")
    func codable() throws {
        // Minimal payload: only pitch + startBeat present.
        let minimal = #"{"pitch": 67, "startBeat": 2.5}"#
        let note = try JSONDecoder().decode(MIDINote.self, from: Data(minimal.utf8))
        #expect(note.pitch == 67)
        #expect(note.startBeat == 2.5)
        #expect(note.velocity == 100)       // default
        #expect(note.lengthBeats == 1.0)    // default

        // A decoded out-of-range payload is routed through the clamping init.
        let wild = #"{"pitch": 200, "velocity": 0, "startBeat": -1, "lengthBeats": -4}"#
        let clamped = try JSONDecoder().decode(MIDINote.self, from: Data(wild.utf8))
        #expect(clamped.pitch == 127)
        #expect(clamped.velocity == 1)
        #expect(clamped.startBeat == 0)
        #expect(clamped.lengthBeats == MIDINote.minLengthBeats)

        // Full round trip writes all five keys.
        let full = MIDINote(pitch: 48, velocity: 90, startBeat: 3, lengthBeats: 1.5)
        let data = try JSONEncoder().encode(full)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["id", "pitch", "velocity", "startBeat", "lengthBeats"])
        #expect(try JSONDecoder().decode(MIDINote.self, from: data) == full)
    }
}

@Suite("Clip — MIDI payload")
struct ClipMIDITests {
    // 4.
    @Test("isMIDI + mutual exclusion: notes win over audioFileURL")
    func mutualExclusion() {
        let audio = Clip(name: "a", audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        #expect(!audio.isMIDI)
        #expect(audio.notes == nil)
        #expect(audio.audioFileURL != nil)

        // notes present (even empty) → MIDI, and audioFileURL is dropped.
        let midi = Clip(name: "m", audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"), notes: [])
        #expect(midi.isMIDI)
        #expect(midi.notes == [])
        #expect(midi.audioFileURL == nil)
    }

    // 5.
    @Test("init canonically orders the note payload")
    func initOrders() {
        let hi = MIDINote(pitch: 72, startBeat: 4)
        let lo = MIDINote(pitch: 48, startBeat: 0)
        let clip = Clip(name: "m", notes: [hi, lo])
        #expect(clip.notes?.map(\.startBeat) == [0, 4])
    }
}

@MainActor
@Suite("ProjectStore — MIDI clips")
struct ProjectStoreMIDITests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    // 6.
    @Test("addMIDIClip: instrument-only, default length, name, append position")
    func addHappyPath() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)

        // Empty clip → 4-beat default, auto name, starts at 0.
        let empty = try store.addMIDIClip(toTrack: inst.id)
        #expect(empty.isMIDI)
        #expect(empty.notes == [])
        #expect(empty.lengthBeats == 4)
        #expect(empty.startBeat == 0)
        #expect(empty.name == "MIDI Clip 1")

        // Note-seeded clip: length = ceil(max note end), min 1. Note ends at 3.5.
        let seeded = try store.addMIDIClip(
            toTrack: inst.id,
            notes: [MIDINote(pitch: 60, startBeat: 2, lengthBeats: 1.5)]
        )
        #expect(seeded.lengthBeats == 4)              // ceil(3.5) = 4
        #expect(seeded.startBeat == 4)                // appended after the 4-beat clip
        #expect(seeded.name == "MIDI Clip 2")
        #expect(seeded.notes?.count == 1)

        // Explicit atBeat + lengthBeats + name are honored.
        let explicit = try store.addMIDIClip(
            toTrack: inst.id, name: "Bass", atBeat: 16, lengthBeats: 8
        )
        #expect(explicit.startBeat == 16)
        #expect(explicit.lengthBeats == 8)
        #expect(explicit.name == "Bass")
        #expect(store.tracks[0].clips.count == 3)
    }

    // 7.
    @Test("addMIDIClip throws trackNotFound and midiClipsRequireInstrumentTrack verbatim")
    func addRejections() {
        let store = ProjectStore()
        let bogus = UUID()
        let missing = projectError { _ = try store.addMIDIClip(toTrack: bogus) }
        guard case .trackNotFound(let id)? = missing, id == bogus else {
            Issue.record("expected trackNotFound, got \(String(describing: missing))"); return
        }

        let audio = store.addTrack(kind: .audio)
        let wrongKind = projectError { _ = try store.addMIDIClip(toTrack: audio.id) }
        guard case .midiClipsRequireInstrumentTrack(let kind)? = wrongKind, kind == .audio else {
            Issue.record("expected midiClipsRequireInstrumentTrack, got \(String(describing: wrongKind))"); return
        }
        #expect(wrongKind?.errorDescription
                == "track kind 'audio' cannot hold MIDI clips — only instrument tracks accept MIDI clips (add one with track.add kind=instrument)")
        #expect(store.tracks[0].clips.isEmpty)  // nothing landed on the audio track
    }

    // 8.
    @Test("setClipNotes replaces, re-clamps, and canonically orders; guards apply")
    func setNotes() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id)

        var wild = MIDINote(pitch: 60, startBeat: 4)
        wild.pitch = 999          // mutate out of range after construction
        let updated = try store.setClipNotes(clipID: clip.id, notes: [
            wild,
            MIDINote(pitch: 62, startBeat: 0),
        ])
        // Re-clamped (pitch 127) and reordered by onset (0 before 4).
        #expect(updated.notes?.map(\.startBeat) == [0, 4])
        #expect(updated.notes?.last?.pitch == 127)
        #expect(store.tracks[0].clips[0].notes?.count == 2)

        // clipNotFound for an unknown id.
        let bogus = UUID()
        let missing = projectError { _ = try store.setClipNotes(clipID: bogus, notes: []) }
        guard case .clipNotFound(let id)? = missing, id == bogus else {
            Issue.record("expected clipNotFound, got \(String(describing: missing))"); return
        }
        #expect(missing?.errorDescription
                == "no clip with id \(bogus.uuidString) — use project.snapshot to list clips")

        // notAMIDIClip for an audio clip.
        let audioTrack = store.addTrack(kind: .audio)
        store.media = FakeMedia()
        let audioClip = try store.importAudio(
            url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: audioTrack.id
        )
        let wrong = projectError { _ = try store.setClipNotes(clipID: audioClip.id, notes: []) }
        guard case .notAMIDIClip(let cid)? = wrong, cid == audioClip.id else {
            Issue.record("expected notAMIDIClip, got \(String(describing: wrong))"); return
        }
        #expect(wrong?.errorDescription
                == "clip \(audioClip.id.uuidString) is an audio clip — clip.setNotes applies only to MIDI clips (created via clip.addMIDI)")
    }

    // 9.
    @Test("removeClip removes an audio or MIDI clip and returns it; clipNotFound otherwise")
    func removeClip() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let inst = store.addTrack(kind: .instrument)
        let audio = store.addTrack(kind: .audio)
        let midiClip = try store.addMIDIClip(toTrack: inst.id)
        let audioClip = try store.importAudio(
            url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: audio.id
        )

        let removedMIDI = try store.removeClip(id: midiClip.id)
        #expect(removedMIDI.id == midiClip.id)
        #expect(store.tracks[0].clips.isEmpty)

        let removedAudio = try store.removeClip(id: audioClip.id)
        #expect(removedAudio.id == audioClip.id)
        #expect(store.tracks[1].clips.isEmpty)

        let bogus = UUID()
        let missing = projectError { _ = try store.removeClip(id: bogus) }
        guard case .clipNotFound(let id)? = missing, id == bogus else {
            Issue.record("expected clipNotFound, got \(String(describing: missing))"); return
        }
    }
}
