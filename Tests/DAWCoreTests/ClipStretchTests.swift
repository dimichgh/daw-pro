import Foundation
import Testing
@testable import DAWCore

// Reuses fakes already defined in the DAWCoreTests target:
//   FakeMedia (ImportTests.swift), FakeEngine (CoreTests.swift).
// FakeMedia's default info is 2.0 s → 4 beats at the default 120 BPM.

@Suite("Clip — stretch model (M5 ii-c)")
struct ClipStretchModelTests {
    private func audioURL() -> URL { URL(fileURLWithPath: "/tmp/x.wav") }

    private func encodeToObject(_ clip: Clip) throws -> [String: Any] {
        let data = try JSONEncoder().encode(clip)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // 1.
    @Test("stretch fields default and clamp through init")
    func defaultsAndClamping() {
        let plain = Clip(name: "p")
        #expect(plain.stretchRatio == 1)
        #expect(plain.pitchShiftSemitones == 0)
        #expect(plain.formantPreserve == false)
        #expect(plain.isStretchIdentity)

        // Ratio clamps to [0.25, 4]; semitones to [-24, 24].
        #expect(Clip(name: "hi", stretchRatio: 99, pitchShiftSemitones: 99).stretchRatio == 4)
        #expect(Clip(name: "hi", stretchRatio: 99, pitchShiftSemitones: 99).pitchShiftSemitones == 24)
        #expect(Clip(name: "lo", stretchRatio: 0.001, pitchShiftSemitones: -99).stretchRatio == 0.25)
        #expect(Clip(name: "lo", stretchRatio: 0.001, pitchShiftSemitones: -99).pitchShiftSemitones == -24)
        #expect(Clip.stretchRatioRange == 0.25...4)
        #expect(Clip.pitchShiftSemitonesRange == -24...24)

        // formantPreserve alone (no pitch shift) is still identity; a pitch shift is not.
        #expect(Clip(name: "f", formantPreserve: true).isStretchIdentity)
        #expect(!Clip(name: "s", pitchShiftSemitones: 3).isStretchIdentity)
        #expect(!Clip(name: "r", stretchRatio: 2).isStretchIdentity)
    }

    // 2.
    @Test("sourceWindowSeconds derives lengthBeats·60/tempo / ratio")
    func derivedWindow() {
        // 4 beats @120 BPM, ratio 1 → 2.0 s of source.
        let a = Clip(name: "a", lengthBeats: 4, audioFileURL: audioURL())
        #expect(abs(a.sourceWindowSeconds(tempoMap: TempoMap(constantBPM: 120)) - 2.0) < 1e-12)
        // Same length at ratio 2 reads HALF the source window (1.0 s).
        let b = Clip(name: "b", lengthBeats: 4, audioFileURL: audioURL(), stretchRatio: 2)
        #expect(abs(b.sourceWindowSeconds(tempoMap: TempoMap(constantBPM: 120)) - 1.0) < 1e-12)
    }

    // 3.
    @Test("unedited clip encodes NO stretch keys (byte-identical to a pre-stretch clip)")
    func omitWhenDefault() throws {
        let audio = Clip(name: "a", lengthBeats: 4, audioFileURL: audioURL())
        let object = try encodeToObject(audio)
        #expect(Set(object.keys) == ["id", "name", "startBeat", "lengthBeats", "audioFileURL", "isAIGenerated"])
        for key in ["stretchRatio", "pitchShiftSemitones", "formantPreserve"] {
            #expect(object[key] == nil)
        }
    }

    // 4.
    @Test("edited stretch fields round-trip; each default stays omitted")
    func editedRoundTrip() throws {
        let clip = Clip(name: "e", lengthBeats: 8, audioFileURL: audioURL(),
                        stretchRatio: 1.5, pitchShiftSemitones: -5, formantPreserve: true)
        let data = try JSONEncoder().encode(clip)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["stretchRatio"] != nil)
        #expect(object["pitchShiftSemitones"] != nil)
        #expect(object["formantPreserve"] != nil)
        #expect(try JSONDecoder().decode(Clip.self, from: data) == clip)

        // ratio at 1 and formant false stay omitted while a pitch shift is present.
        let pitchOnly = Clip(name: "p", audioFileURL: audioURL(), pitchShiftSemitones: 7)
        let pObj = try encodeToObject(pitchOnly)
        #expect(pObj["stretchRatio"] == nil)
        #expect(pObj["formantPreserve"] == nil)
        #expect(pObj["pitchShiftSemitones"] != nil)
    }
}

@Suite("ClipDocument — stretch persistence (M5 ii-c)")
struct ClipStretchPersistenceTests {
    // 5.
    @Test("unedited clip persists no stretch keys; edited fields survive a round trip")
    func persistence() throws {
        let plain = Clip(name: "p", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        let plainData = try JSONEncoder().encode(ClipDocument(from: plain, media: "media/x.wav"))
        let plainObject = try #require(try JSONSerialization.jsonObject(with: plainData) as? [String: Any])
        for key in ["stretchRatio", "pitchShiftSemitones", "formantPreserve"] {
            #expect(plainObject[key] == nil)
        }

        let edited = Clip(name: "e", lengthBeats: 8, audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"),
                          stretchRatio: 0.5, pitchShiftSemitones: 12, formantPreserve: true)
        let data = try JSONEncoder().encode(ClipDocument(from: edited, media: "media/x.wav"))
        let decoded = try JSONDecoder().decode(ClipDocument.self, from: data)
        #expect(decoded.stretchRatio == 0.5)
        #expect(decoded.pitchShiftSemitones == 12)
        #expect(decoded.formantPreserve == true)
    }
}

@MainActor
@Suite("ProjectStore — clip stretch (M5 ii-c)")
struct ProjectStoreClipStretchTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// A store with one audio track holding one imported clip (start 0, 4 beats
    /// at 120 BPM, ratio 1), named "Loop".
    private func storeWithAudioClip() throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: track.id)
        return (store, track.id, clip)
    }

    private func storeWithMIDIClip() throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4, notes: [])
        return (store, track.id, clip)
    }

    // 6.
    @Test("setClipStretch clamps, nil keeps current, and coalesces into one undo step")
    func setStretchClampAndKeep() throws {
        let (store, trackID, clip) = try storeWithAudioClip()

        // ratio set, semitones/formant nil → keep defaults; ratio clamps.
        _ = try store.setClipStretch(trackId: trackID, clipId: clip.id, ratio: 99)
        #expect(store.tracks[0].clips[0].stretchRatio == 4)
        #expect(store.tracks[0].clips[0].pitchShiftSemitones == 0)
        #expect(store.tracks[0].clips[0].formantPreserve == false)
        // Length is NOT touched by the direct set.
        #expect(store.tracks[0].clips[0].lengthBeats == 4)

        // semitones set, ratio nil → ratio stays 4; semitones clamps.
        _ = try store.setClipStretch(trackId: trackID, clipId: clip.id, semitones: -99, formantPreserve: true)
        #expect(store.tracks[0].clips[0].stretchRatio == 4)
        #expect(store.tracks[0].clips[0].pitchShiftSemitones == -24)
        #expect(store.tracks[0].clips[0].formantPreserve == true)

        // The rapid same-key edits fold into one entry → undo → back to identity.
        #expect(try store.undo() == "Set Clip Stretch")
        #expect(store.tracks[0].clips[0].isStretchIdentity)
        #expect(store.tracks[0].clips[0].stretchRatio == 1)
    }

    // 7.
    @Test("setClipStretch rejects a MIDI clip with invalidClipEdit")
    func setStretchRejectsMIDI() throws {
        let (store, trackID, clip) = try storeWithMIDIClip()
        let e = projectError { _ = try store.setClipStretch(trackId: trackID, clipId: clip.id, ratio: 2) }
        guard case .invalidClipEdit? = e else {
            Issue.record("expected invalidClipEdit, got \(String(describing: e))"); return
        }
        // The clip is untouched.
        #expect(store.tracks[0].clips[0].stretchRatio == 1)
    }

    // 8.
    @Test("stretchClip: doubling the length doubles the ratio and the source window is invariant")
    func stretchCompoundMath() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        let windowBefore = clip.sourceWindowSeconds(tempoMap: store.transport.tempoMap)

        let updated = try store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: 8)
        #expect(updated.lengthBeats == 8)
        #expect(abs(updated.stretchRatio - 2) < 1e-12)   // ratio 1 · (8/4)
        let windowAfter = updated.sourceWindowSeconds(tempoMap: store.transport.tempoMap)
        #expect(abs(windowAfter - windowBefore) < 1e-12) // source window held constant

        // Halving the (now 8-beat) clip back to 4 restores ratio 1.
        let halved = try store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: 4)
        #expect(halved.lengthBeats == 4)
        #expect(abs(halved.stretchRatio - 1) < 1e-12)
    }

    // 9.
    @Test("stretchClip: ratio clamp re-derives the length so the window survives")
    func stretchRatioClampReDerivesLength() throws {
        let (store, trackID, clip) = try storeWithAudioClip()  // length 4, ratio 1
        let windowBefore = clip.sourceWindowSeconds(tempoMap: store.transport.tempoMap)

        // toLength 20 → desired ratio 5, clamps to 4 → length re-derives to 16.
        let updated = try store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: 20)
        #expect(updated.stretchRatio == 4)
        #expect(abs(updated.lengthBeats - 16) < 1e-12)
        let windowAfter = updated.sourceWindowSeconds(tempoMap: store.transport.tempoMap)
        #expect(abs(windowAfter - windowBefore) < 1e-12)
    }

    // 10.
    @Test("stretchClip: fades re-clamp proportionally to the new (shorter) length")
    func stretchFadesReclamp() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipFades(trackId: trackID, clipId: clip.id,
                                   fadeInBeats: 2, fadeOutBeats: 2,
                                   fadeInCurve: .linear, fadeOutCurve: .linear)
        // Stretch DOWN to length 3: fades 2 + 2 = 4 > 3 → scale 3/4 → 1.5 each.
        let updated = try store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: 3)
        #expect(abs(updated.fadeInBeats - 1.5) < 1e-9)
        #expect(abs(updated.fadeOutBeats - 1.5) < 1e-9)
    }

    // 11.
    @Test("stretchClip rejects a MIDI clip with invalidClipEdit")
    func stretchRejectsMIDI() throws {
        let (store, trackID, clip) = try storeWithMIDIClip()
        let e = projectError { _ = try store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: 8) }
        guard case .invalidClipEdit? = e else {
            Issue.record("expected invalidClipEdit, got \(String(describing: e))"); return
        }
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
    }

    // 12.
    @Test("splitClip copies the stretch params to BOTH halves")
    func splitCopiesStretch() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipStretch(trackId: trackID, clipId: clip.id,
                                     ratio: 2, semitones: 3, formantPreserve: true)

        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 2)
        for half in [first, second] {
            #expect(half.stretchRatio == 2)
            #expect(half.pitchShiftSemitones == 3)
            #expect(half.formantPreserve == true)
        }
    }

    // 13.
    @Test("trimClip preserves the stretch params (geometry-free)")
    func trimPreservesStretch() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipStretch(trackId: trackID, clipId: clip.id,
                                     ratio: 1.5, semitones: -2, formantPreserve: true)
        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id,
                                         newStartBeat: 1, newLengthBeats: 2)
        #expect(trimmed.stretchRatio == 1.5)
        #expect(trimmed.pitchShiftSemitones == -2)
        #expect(trimmed.formantPreserve == true)
    }

    // 14.
    @Test("undo restores BOTH lengthBeats and stretchRatio in one step")
    func undoRestoresLengthAndRatio() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: 8)
        #expect(store.tracks[0].clips[0].lengthBeats == 8)
        #expect(store.tracks[0].clips[0].stretchRatio == 2)

        #expect(try store.undo() == "Stretch Clip 'Loop'")
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
        #expect(store.tracks[0].clips[0].stretchRatio == 1)
    }
}
