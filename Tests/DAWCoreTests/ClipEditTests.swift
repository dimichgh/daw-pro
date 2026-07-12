import Foundation
import Testing
@testable import DAWCore

// Reuses fakes already defined in the DAWCoreTests target:
//   FakeMedia (ImportTests.swift), FakeEngine (CoreTests.swift).
// FakeMedia's default info is 2.0 s → 4 beats at the default 120 BPM.

@Suite("Clip — edit model")
struct ClipEditModelTests {
    private func audioURL() -> URL { URL(fileURLWithPath: "/tmp/x.wav") }

    // 1.
    @Test("edit fields default and clamp through init")
    func defaultsAndClamping() {
        let plain = Clip(name: "p")
        #expect(plain.startOffsetSeconds == 0)
        #expect(plain.gainDb == 0)
        #expect(plain.fadeInBeats == 0)
        #expect(plain.fadeOutBeats == 0)
        #expect(plain.fadeInCurve == .linear)
        #expect(plain.fadeOutCurve == .linear)

        // Negatives floor to 0; gain clamps to the upper bound.
        let hi = Clip(name: "hi", startOffsetSeconds: -5, gainDb: 999,
                      fadeInBeats: -3, fadeOutBeats: -1)
        #expect(hi.startOffsetSeconds == 0)
        #expect(hi.gainDb == 24)
        #expect(hi.fadeInBeats == 0)
        #expect(hi.fadeOutBeats == 0)

        // Gain clamps to the lower bound.
        #expect(Clip(name: "lo", gainDb: -999).gainDb == -72)
        #expect(Clip.gainDbRange == -72...24)
    }

    // 2.
    @Test("unedited clip encodes NO new keys (byte-identical to a pre-edit clip)")
    func omitWhenDefault() throws {
        let audio = Clip(name: "a", lengthBeats: 4, audioFileURL: audioURL())
        let object = try encodeToObject(audio)
        #expect(Set(object.keys) == ["id", "name", "startBeat", "lengthBeats", "audioFileURL", "isAIGenerated"])

        let midi = Clip(name: "m", lengthBeats: 4, notes: [])
        let midiObject = try encodeToObject(midi)
        #expect(Set(midiObject.keys) == ["id", "name", "startBeat", "lengthBeats", "notes", "isAIGenerated"])

        for key in ["startOffsetSeconds", "gainDb", "fadeInBeats", "fadeOutBeats", "fadeInCurve", "fadeOutCurve"] {
            #expect(object[key] == nil)
            #expect(midiObject[key] == nil)
        }
    }

    // 3.
    @Test("edited fields round-trip; a fade curve at its .linear default is omitted")
    func editedRoundTrip() throws {
        let clip = Clip(name: "e", lengthBeats: 8, audioFileURL: audioURL(),
                        startOffsetSeconds: 0.5, gainDb: -6, fadeInBeats: 1, fadeOutBeats: 2,
                        fadeInCurve: .equalPower, fadeOutCurve: .linear)
        let data = try JSONEncoder().encode(clip)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["startOffsetSeconds"] != nil)
        #expect(object["gainDb"] != nil)
        #expect(object["fadeInBeats"] != nil)
        #expect(object["fadeOutBeats"] != nil)
        #expect(object["fadeInCurve"] != nil)
        #expect(object["fadeOutCurve"] == nil)   // .linear default → omitted

        #expect(try JSONDecoder().decode(Clip.self, from: data) == clip)
    }

    // 4.
    @Test("envelopeGain: static gain and linear/equal-power fade midpoints")
    func envelopeMidpoints() {
        // Static gain only: -6 dB ≈ 0.5012 linear.
        let gained = Clip(name: "g", lengthBeats: 4, audioFileURL: audioURL(), gainDb: -6)
        #expect(abs(gained.envelopeGain(atBeat: 2) - 0.501187) < 1e-4)

        // Linear fade-in: midpoint 0.5, full at the end, 0 at the head.
        let linIn = Clip(name: "l", lengthBeats: 4, audioFileURL: audioURL(), fadeInBeats: 2)
        #expect(abs(linIn.envelopeGain(atBeat: 1) - 0.5) < 1e-12)
        #expect(abs(linIn.envelopeGain(atBeat: 2) - 1.0) < 1e-12)
        #expect(linIn.envelopeGain(atBeat: 0) == 0)

        // Equal-power fade-in midpoint = sin(π/4) ≈ 0.7071.
        let epIn = Clip(name: "e", lengthBeats: 4, audioFileURL: audioURL(),
                        fadeInBeats: 2, fadeInCurve: .equalPower)
        #expect(abs(epIn.envelopeGain(atBeat: 1) - 0.70710678) < 1e-6)

        // Linear fade-out: midpoint 0.5; 0 at the tail; a beat past the end
        // clamps into [0, lengthBeats] (still the tail → 0).
        let linOut = Clip(name: "o", lengthBeats: 4, audioFileURL: audioURL(), fadeOutBeats: 2)
        #expect(abs(linOut.envelopeGain(atBeat: 3) - 0.5) < 1e-12)
        #expect(linOut.envelopeGain(atBeat: 4) == 0)
        #expect(linOut.envelopeGain(atBeat: 99) == 0)
    }

    // 5.
    @Test("envelopeGain: overlapping fades compose by multiplication")
    func overlappingFades() {
        // Each fade = the whole clip length → they overlap; at the midpoint the
        // fade-in factor (0.5) and fade-out factor (0.5) multiply.
        let clip = Clip(name: "x", lengthBeats: 4, audioFileURL: audioURL(),
                        fadeInBeats: 4, fadeOutBeats: 4)
        #expect(abs(clip.envelopeGain(atBeat: 2) - 0.25) < 1e-12)
    }

    private func encodeToObject(_ clip: Clip) throws -> [String: Any] {
        let data = try JSONEncoder().encode(clip)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

@MainActor
@Suite("ProjectStore — clip editing")
struct ProjectStoreClipEditTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// A store with one audio track holding one imported clip (start 0, 4 beats
    /// at 120 BPM, offset 0), named "Loop".
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

    // 6.
    @Test("splitClip: audio source-offset math at 120 BPM + geometry + single undo step")
    func splitAudioOffset() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        #expect(clip.lengthBeats == 4)

        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 1)
        #expect(first.id == clip.id)
        #expect(first.startBeat == 0)
        #expect(first.lengthBeats == 1)
        #expect(first.startOffsetSeconds == 0)
        #expect(second.id != clip.id)
        #expect(second.startBeat == 1)
        #expect(second.lengthBeats == 3)
        #expect(abs(second.startOffsetSeconds - 0.5) < 1e-12)   // 1 beat @120 = 0.5 s
        #expect(store.tracks[0].clips.map(\.id) == [first.id, second.id])

        // No coalescing: one undo restores the single original clip.
        #expect(try store.undo() == "Split Clip 'Loop'")
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id == clip.id)
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
    }

    // 7.
    @Test("splitClip: MIDI notes partition, overhanging note truncates, right side rebases")
    func splitMIDIPartition() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2),  // wholly left
            MIDINote(pitch: 62, startBeat: 3, lengthBeats: 3),  // overhangs split → truncated
            MIDINote(pitch: 64, startBeat: 4, lengthBeats: 2),  // at split → right, rebased to 0
            MIDINote(pitch: 65, startBeat: 5, lengthBeats: 1),  // right, rebased to 1
        ])

        let (first, second) = try store.splitClip(trackId: inst.id, clipId: clip.id, atBeat: 4)

        let left = first.notes ?? []
        #expect(left.count == 2)
        #expect(left.map(\.pitch) == [60, 62])
        let truncated = try #require(left.first { $0.pitch == 62 })
        #expect(truncated.startBeat == 3)
        #expect(abs(truncated.lengthBeats - 1) < 1e-12)         // 3→4 boundary

        let right = second.notes ?? []
        #expect(right.count == 2)
        #expect(right.map(\.startBeat) == [0, 1])               // rebased by −4
        #expect(right.map(\.pitch) == [64, 65])
    }

    // 8.
    @Test("splitClip: fades redistribute and gain copies to both halves")
    func splitFadeGainRedistribution() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: -3)
        _ = try store.setClipFades(trackId: trackID, clipId: clip.id,
                                   fadeInBeats: 1, fadeOutBeats: 1,
                                   fadeInCurve: .equalPower, fadeOutCurve: .equalPower)

        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 2)
        // Left keeps fade-in, loses fade-out (curve resets to the omitted default).
        #expect(first.fadeInBeats == 1)
        #expect(first.fadeOutBeats == 0)
        #expect(first.fadeInCurve == .equalPower)
        #expect(first.fadeOutCurve == .linear)
        // Right gains a 0 fade-in, keeps the fade-out.
        #expect(second.fadeInBeats == 0)
        #expect(second.fadeOutBeats == 1)
        #expect(second.fadeInCurve == .linear)
        #expect(second.fadeOutCurve == .equalPower)
        // Gain copied to both.
        #expect(first.gainDb == -3)
        #expect(second.gainDb == -3)
    }

    // 9.
    @Test("splitClip: rejects an out-of-bounds beat and unknown track/clip")
    func splitErrors() throws {
        let (store, trackID, clip) = try storeWithAudioClip()

        for beat in [-1.0, 0.0, 4.0, 10.0] {   // <=start, at edges, past end
            let e = projectError { _ = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: beat) }
            guard case .invalidClipEdit? = e else {
                Issue.record("expected invalidClipEdit at beat \(beat), got \(String(describing: e))"); return
            }
        }
        #expect(store.tracks[0].clips.count == 1)   // nothing split

        let unkTrack = projectError { _ = try store.splitClip(trackId: UUID(), clipId: clip.id, atBeat: 2) }
        guard case .trackNotFound? = unkTrack else { Issue.record("expected trackNotFound"); return }
        let unkClip = projectError { _ = try store.splitClip(trackId: trackID, clipId: UUID(), atBeat: 2) }
        guard case .clipNotFound? = unkClip else { Issue.record("expected clipNotFound"); return }
    }

    // 10.
    @Test("trimClip: leading-edge move advances audio offset; trailing shrink keeps the id")
    func trimAudioLeadingEdge() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id,
                                         newStartBeat: 1, newLengthBeats: 3)
        #expect(trimmed.id == clip.id)
        #expect(trimmed.startBeat == 1)
        #expect(trimmed.lengthBeats == 3)
        #expect(abs(trimmed.startOffsetSeconds - 0.5) < 1e-12)   // +1 beat @120 = +0.5 s
    }

    // 11.
    @Test("trimClip: MIDI notes drop when outside, truncate at the edges, and shift")
    func trimMIDINotes() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 8, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),  // wholly before new edge → dropped
            MIDINote(pitch: 62, startBeat: 1, lengthBeats: 3),  // straddles → front-truncated
            MIDINote(pitch: 64, startBeat: 4, lengthBeats: 1),  // inside → shifted left
        ])

        let trimmed = try store.trimClip(trackId: inst.id, clipId: clip.id,
                                         newStartBeat: 2, newLengthBeats: 6)
        let notes = trimmed.notes ?? []
        #expect(notes.count == 2)
        #expect(notes.map(\.startBeat) == [0, 2])
        let front = try #require(notes.first { $0.pitch == 62 })
        #expect(front.startBeat == 0)
        #expect(abs(front.lengthBeats - 2) < 1e-12)              // [1,4] shifted −2 → [−1,2] → [0,2]
    }

    // 12.
    @Test("trimClip: fades re-clamp proportionally and length floors at the minimum")
    func trimFadeReclampAndMinLength() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipFades(trackId: trackID, clipId: clip.id,
                                   fadeInBeats: 2, fadeOutBeats: 1,
                                   fadeInCurve: .linear, fadeOutCurve: .linear)
        // New length 2: fades 2 + 1 = 3 > 2 → scale 2/3 → 4/3 and 2/3 (ratio kept).
        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id,
                                         newStartBeat: 0, newLengthBeats: 2)
        #expect(abs(trimmed.fadeInBeats - 4.0 / 3.0) < 1e-9)
        #expect(abs(trimmed.fadeOutBeats - 2.0 / 3.0) < 1e-9)
        #expect(abs((trimmed.fadeInBeats + trimmed.fadeOutBeats) - 2) < 1e-9)

        // A zero/negative length floors to the clip minimum.
        let floored = try store.trimClip(trackId: trackID, clipId: clip.id,
                                         newStartBeat: 0, newLengthBeats: 0)
        #expect(floored.lengthBeats == ProjectStore.minClipLengthBeats)
    }

    // 13.
    @Test("moveClip: clamps the new start to >= 0")
    func moveClamp() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        #expect(try store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: -5).clip.startBeat == 0)
        #expect(try store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: 12).clip.startBeat == 12)
    }

    // 14.
    @Test("setClipGain: clamps, and rapid same-key edits coalesce into one undo step")
    func gainAndUndo() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: -6)
        #expect(store.tracks[0].clips[0].gainDb == -6)
        _ = try store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: -999)
        #expect(store.tracks[0].clips[0].gainDb == -72)
        _ = try store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: 999)
        #expect(store.tracks[0].clips[0].gainDb == 24)

        // The three sub-800 ms same-key edits fold into one entry → undo → 0 dB.
        #expect(try store.undo() == "Set Clip Gain")
        #expect(store.tracks[0].clips[0].gainDb == 0)
    }

    // 15.
    @Test("setClipFades: proportional reduction on conflict, curves set, one undo step")
    func fadesProportionalAndUndo() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        // 3 + 3 = 6 > length 4 → scale 4/6 → each 2.
        let updated = try store.setClipFades(trackId: trackID, clipId: clip.id,
                                             fadeInBeats: 3, fadeOutBeats: 3,
                                             fadeInCurve: .equalPower, fadeOutCurve: .linear)
        #expect(abs(updated.fadeInBeats - 2) < 1e-12)
        #expect(abs(updated.fadeOutBeats - 2) < 1e-12)
        #expect(updated.fadeInCurve == .equalPower)
        #expect(updated.fadeOutCurve == .linear)

        #expect(try store.undo() == "Set Clip Fades")
        #expect(store.tracks[0].clips[0].fadeInBeats == 0)
        #expect(store.tracks[0].clips[0].fadeOutBeats == 0)
        #expect(store.tracks[0].clips[0].fadeInCurve == .linear)
    }

    // 16.
    @Test("clip-edit ops reject unknown track and clip")
    func editErrors() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        let bogus = UUID()

        let e1 = projectError { _ = try store.moveClip(trackId: bogus, clipId: clip.id, toStartBeat: 0) }
        guard case .trackNotFound? = e1 else { Issue.record("move: expected trackNotFound"); return }

        let e2 = projectError { _ = try store.setClipGain(trackId: trackID, clipId: bogus, gainDb: 0) }
        guard case .clipNotFound? = e2 else { Issue.record("gain: expected clipNotFound"); return }

        let e3 = projectError {
            _ = try store.trimClip(trackId: bogus, clipId: clip.id, newStartBeat: 0, newLengthBeats: 1)
        }
        guard case .trackNotFound? = e3 else { Issue.record("trim: expected trackNotFound"); return }

        let e4 = projectError {
            _ = try store.setClipFades(trackId: trackID, clipId: bogus, fadeInBeats: 0, fadeOutBeats: 0,
                                       fadeInCurve: .linear, fadeOutCurve: .linear)
        }
        guard case .clipNotFound? = e4 else { Issue.record("fades: expected clipNotFound"); return }
    }
}

@Suite("ClipDocument — edit persistence")
struct ClipEditPersistenceTests {
    // 17.
    @Test("unedited clip persists no edit keys; edited fields survive a round trip")
    func persistence() throws {
        // A pre-edit clip carries no edit keys on disk (byte-identical to a
        // pre-edit save; media is written as an explicit key per the schema).
        let plain = Clip(name: "p", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        let plainDoc = ClipDocument(from: plain, media: "media/x.wav")
        let plainData = try JSONEncoder().encode(plainDoc)
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        #expect(Set(plainObject.keys) == ["id", "name", "startBeat", "lengthBeats", "media", "isAIGenerated"])

        // Edited fields persist and decode back to the same values; a .linear
        // curve stays omitted (nil on decode → the model default on load).
        let edited = Clip(name: "e", lengthBeats: 8, audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                          startOffsetSeconds: 0.5, gainDb: -6, fadeInBeats: 1, fadeOutBeats: 2,
                          fadeInCurve: .equalPower, fadeOutCurve: .linear)
        let data = try JSONEncoder().encode(ClipDocument(from: edited, media: "media/x.wav"))
        let decoded = try JSONDecoder().decode(ClipDocument.self, from: data)
        #expect(decoded.startOffsetSeconds == 0.5)
        #expect(decoded.gainDb == -6)
        #expect(decoded.fadeInBeats == 1)
        #expect(decoded.fadeOutBeats == 2)
        #expect(decoded.fadeInCurve == .equalPower)
        #expect(decoded.fadeOutCurve == nil)
    }
}
