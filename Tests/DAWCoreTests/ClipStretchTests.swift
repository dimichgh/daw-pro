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

    // MARK: - C2-0 (F13): split and trims advance the offset in SOURCE seconds
    //
    // C2-0 (design 2026-09-24, finding F13). `Clip.startOffsetSeconds` is
    // SOURCE seconds: the engine reads a stretched clip's render at frame
    // `startOffsetSeconds × stretchRatio × fileRate` (`PlaybackGraph`, both the
    // linear and the cycle schedule). A split or a leading-edge trim moves the
    // clip's window by a TIMELINE span, so the offset must advance by that
    // span DIVIDED BY THE RATIO — the rule `CompFlattener` already applies
    // (`Takes.swift`, "the splitClip math, generalized for stretch").
    //
    // Every case cuts a clip 8 beats = 4 s of timeline in (120 BPM):
    //  - ratio 2: 4 s of timeline is 2 s of source, so the offset advances
    //    +2 s. The undivided math advances +4 s and SKIPS 4 s of stretched audio.
    //  - ratio 0.5: 4 s of timeline is 8 s of source, so the offset advances
    //    +8 s. The undivided math advances +4 s: the error FLIPS SIGN and the
    //    listener hears 2 s of stretched audio TWICE.
    //
    // The public-path tests pin the survivor sets too, so they prove the
    // offset fix changed no decision about which clips survive an overlap
    // (m33-j).
    //
    // In THIS suite, not a new one, on purpose: tests 12 and 13 above are the
    // split/trim stretch tests F13 found checking everything but the offset,
    // so this is their home. It also keeps the `@MainActor` suite count (the
    // review cadence, `MainActorOccupancySiteTests` Leg C) where it was.

    private static let bpm = 120.0          // 1 beat = 0.5 s
    private static let clipStart = 4.0      // beats
    private static let clipLength = 16.0    // beats = 8 s of timeline
    private static let startOffset = 1.0    // SOURCE seconds
    private static let cutBeat = 12.0       // clipStart + 8 beats = 4 s of timeline in
    private static let cutTimelineSeconds = 4.0

    /// The oracle: the left edge's source second plus the cut's timeline span
    /// ÷ the ratio. Deliberately NOT computed through any store helper.
    private static func expectedOffset(ratio: Double) -> Double {
        startOffset + cutTimelineSeconds / ratio
    }

    private static func stretchedClip(ratio: Double) -> Clip {
        Clip(name: "Vox", startBeat: clipStart, lengthBeats: clipLength,
             audioFileURL: URL(fileURLWithPath: "/tmp/c2-0-vox.wav"),
             startOffsetSeconds: startOffset, stretchRatio: ratio)
    }

    /// A 120 BPM store with one audio track holding exactly `clips` — built
    /// directly (`tracks` is internal(set)) so no OTHER edit site, trim or
    /// stretch, runs while the fixture is made.
    private static func store(with clips: [Clip]) throws -> (store: ProjectStore, trackID: UUID) {
        let store = ProjectStore()
        store.media = FakeMedia()
        try store.setTempo(bpm)
        let track = store.addTrack(kind: .audio)
        let index = try #require(store.tracks.firstIndex { $0.id == track.id })
        store.tracks[index].clips = clips
        return (store, track.id)
    }

    /// The source second a clip's window ENDS on — invariant under a
    /// leading-edge trim, because the content stays fixed on the timeline.
    private static func sourceEnd(_ clip: Clip, _ map: TempoMap) -> Double {
        clip.startOffsetSeconds + clip.sourceWindowSeconds(tempoMap: map)
    }

    // MARK: Site 1 — splitClip

    @Test("splitClip: the right half starts where the left half's SOURCE window ends",
          arguments: [2.0, 0.5])
    func splitAdvancesBySourceSeconds(ratio: Double) throws {
        let clip = Self.stretchedClip(ratio: ratio)
        let (store, trackID) = try Self.store(with: [clip])
        let map = store.transport.tempoMap

        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id,
                                                  atBeat: Self.cutBeat)
        let expected = Self.expectedOffset(ratio: ratio)
        let seamGap = second.startOffsetSeconds - Self.sourceEnd(first, map)
        print("[measured] C2-0 split ratio \(ratio): right offset \(second.startOffsetSeconds) s "
              + "(expected \(expected) s), source gap at the seam \(seamGap) s")
        #expect(first.startOffsetSeconds == Self.startOffset)
        #expect(abs(second.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): right half offset \(second.startOffsetSeconds) s, expected \(expected) s")
        #expect(abs(seamGap) < 1e-12,
                "ratio \(ratio): the right half must start on the left half's last source second")
        #expect(store.tracks[0].clips.map(\.startOffsetSeconds)
                == [first.startOffsetSeconds, second.startOffsetSeconds])
    }

    // MARK: Site 2 — applyTrimWindow (reached by trimClip)

    @Test("trimClip: a leading edge moved 4 s in advances the offset by 4 s ÷ ratio",
          arguments: [2.0, 0.5])
    func trimAdvancesBySourceSeconds(ratio: Double) throws {
        let clip = Self.stretchedClip(ratio: ratio)
        let (store, trackID) = try Self.store(with: [clip])
        let map = store.transport.tempoMap

        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id,
                                         newStartBeat: Self.cutBeat,
                                         newLengthBeats: Self.clipLength - 8)
        let expected = Self.expectedOffset(ratio: ratio)
        let endDrift = Self.sourceEnd(trimmed, map) - Self.sourceEnd(clip, map)
        print("[measured] C2-0 trim ratio \(ratio): offset \(trimmed.startOffsetSeconds) s "
              + "(expected \(expected) s), window-end drift \(endDrift) s")
        #expect(abs(trimmed.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): trimmed offset \(trimmed.startOffsetSeconds) s, expected \(expected) s")
        #expect(abs(endDrift) < 1e-12,
                "ratio \(ratio): a leading-edge trim must not move the clip's last source second")
    }

    @Test("trimClip: revealing 2 s of head moves the offset BACK by 2 s ÷ ratio",
          arguments: [2.0, 0.5])
    func trimRevealRetreatsBySourceSeconds(ratio: Double) throws {
        // Offset 5 s of source leaves room to reveal without touching the
        // max(0, …) clamp at either ratio.
        let clip = Clip(name: "Vox", startBeat: Self.clipStart, lengthBeats: Self.clipLength,
                        audioFileURL: URL(fileURLWithPath: "/tmp/c2-0-vox.wav"),
                        startOffsetSeconds: 5, stretchRatio: ratio)
        let (store, trackID) = try Self.store(with: [clip])
        let map = store.transport.tempoMap

        // Leading edge 4 beats = 2 s of timeline to the LEFT.
        let revealed = try store.trimClip(trackId: trackID, clipId: clip.id,
                                          newStartBeat: 0, newLengthBeats: Self.clipLength + 4)
        let expected = 5 - 2 / ratio
        let endDrift = Self.sourceEnd(revealed, map) - Self.sourceEnd(clip, map)
        print("[measured] C2-0 reveal ratio \(ratio): offset \(revealed.startOffsetSeconds) s "
              + "(expected \(expected) s), window-end drift \(endDrift) s")
        #expect(abs(revealed.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): revealed offset \(revealed.startOffsetSeconds) s, expected \(expected) s")
        #expect(abs(endDrift) < 1e-12)
    }

    // MARK: Site 3 — clipTrimmedToWindow (static, and every public path to it)

    @Test("clipTrimmedToWindow (static): a window 4 s in advances the offset by 4 s ÷ ratio",
          arguments: [2.0, 0.5])
    func staticWindowTrimAdvancesBySourceSeconds(ratio: Double) throws {
        let clip = Self.stretchedClip(ratio: ratio)
        let map = TempoMap(constantBPM: Self.bpm)
        let trimmed = try #require(ProjectStore.clipTrimmedToWindow(
            clip, newStart: Self.cutBeat, newLength: Self.clipLength - 8, tempoMap: map))
        let expected = Self.expectedOffset(ratio: ratio)
        print("[measured] C2-0 clipTrimmedToWindow ratio \(ratio): offset "
              + "\(trimmed.startOffsetSeconds) s (expected \(expected) s)")
        #expect(abs(trimmed.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): windowed offset \(trimmed.startOffsetSeconds) s, expected \(expected) s")
        #expect(abs(Self.sourceEnd(trimmed, map) - Self.sourceEnd(clip, map)) < 1e-12)
    }

    @Test("moveClip over a stretched clip's head: the survivor advances by 4 s ÷ ratio",
          arguments: [2.0, 0.5])
    func overlapHeadTrimThroughMove(ratio: Double) throws {
        let stationary = Self.stretchedClip(ratio: ratio)                 // [4, 20)
        let mover = Clip(name: "Drop", startBeat: 40, lengthBeats: 8,     // ratio 1, clear
                         audioFileURL: URL(fileURLWithPath: "/tmp/c2-0-drop.wav"))
        let (store, trackID) = try Self.store(with: [stationary, mover])

        // Land the mover on [4, 12): it covers the stationary clip's first
        // 8 beats (4 s), so the overlap choke point trims that clip's head.
        let result = try store.moveClip(trackId: trackID, clipId: mover.id, toStartBeat: 4)
        // Survival is unchanged by C2-0: one trimmed, none removed.
        #expect(result.trimmedClipIDs == [stationary.id])
        #expect(result.removedClipIDs.isEmpty)
        let survivor = try #require(store.tracks[0].clips.first { $0.id == stationary.id })
        #expect(survivor.startBeat == Self.cutBeat)
        #expect(survivor.lengthBeats == Self.clipLength - 8)
        let expected = Self.expectedOffset(ratio: ratio)
        print("[measured] C2-0 move-overlap ratio \(ratio): survivor offset "
              + "\(survivor.startOffsetSeconds) s (expected \(expected) s)")
        #expect(abs(survivor.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): survivor offset \(survivor.startOffsetSeconds) s, expected \(expected) s")
    }

    @Test("importAudio(overwrite:) over a stretched clip's head: the survivor advances by 4 s ÷ ratio",
          arguments: [2.0, 0.5])
    func overlapHeadTrimThroughImport(ratio: Double) throws {
        let stationary = Self.stretchedClip(ratio: ratio)                 // [4, 20)
        let (store, trackID) = try Self.store(with: [stationary])
        // A 4 s file at 120 BPM is 8 beats: landing at beat 4 covers [4, 12).
        store.media = FakeMedia(info: AudioFileInfo(durationSeconds: 4, sampleRate: 48_000,
                                                    channelCount: 2))
        let result = try store.importAudio(url: URL(fileURLWithPath: "/tmp/c2-0-import.wav"),
                                           toTrack: trackID, atBeat: 4, overwrite: true)
        #expect(result.trimmedClipIDs == [stationary.id])
        #expect(result.removedClipIDs.isEmpty)
        let survivor = try #require(store.tracks[0].clips.first { $0.id == stationary.id })
        #expect(survivor.startBeat == Self.cutBeat)
        let expected = Self.expectedOffset(ratio: ratio)
        print("[measured] C2-0 import-overlap ratio \(ratio): survivor offset "
              + "\(survivor.startOffsetSeconds) s (expected \(expected) s)")
        #expect(abs(survivor.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): survivor offset \(survivor.startOffsetSeconds) s, expected \(expected) s")
    }

    @Test("insertBars through a stretched clip: the pushed-right tail continues the head's audio",
          arguments: [2.0, 0.5])
    func insertBarsTailAdvancesBySourceSeconds(ratio: Double) throws {
        let clip = Self.stretchedClip(ratio: ratio)                       // [4, 20)
        let (store, _) = try Self.store(with: [clip])
        let map = store.transport.tempoMap

        // 4/4: bar 4 starts at beat 12 — 8 beats = 4 s into the clip.
        let result = try store.insertBars(atBar: 4, count: 1)
        #expect(result.atBeat == Self.cutBeat)
        let pieces = store.tracks[0].clips.sorted { $0.startBeat < $1.startBeat }
        try #require(pieces.count == 2)
        let (head, tail) = (pieces[0], pieces[1])
        #expect(head.id == clip.id)
        #expect(head.startOffsetSeconds == Self.startOffset)
        #expect(tail.startBeat == Self.cutBeat + result.insertedBeats)
        let expected = Self.expectedOffset(ratio: ratio)
        print("[measured] C2-0 insertBars ratio \(ratio): tail offset \(tail.startOffsetSeconds) s "
              + "(expected \(expected) s), head ends on source second \(Self.sourceEnd(head, map))")
        #expect(abs(tail.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): tail offset \(tail.startOffsetSeconds) s, expected \(expected) s")
    }

    @Test("deleteBars over a stretched clip's head: the pulled-left remainder advances by 4 s ÷ ratio",
          arguments: [2.0, 0.5])
    func deleteBarsRemainderAdvancesBySourceSeconds(ratio: Double) throws {
        let clip = Self.stretchedClip(ratio: ratio)                       // [4, 20)
        let (store, _) = try Self.store(with: [clip])

        // 4/4: bars 2–3 are beats [4, 12) — the clip's first 8 beats (4 s).
        let result = try store.deleteBars(fromBar: 2, count: 2)
        #expect(result.removedClipIDs.isEmpty)
        let pieces = store.tracks[0].clips
        try #require(pieces.count == 1)
        let remainder = pieces[0]
        #expect(remainder.id == clip.id)
        #expect(remainder.startBeat == Self.clipStart)
        #expect(remainder.lengthBeats == Self.clipLength - 8)
        let expected = Self.expectedOffset(ratio: ratio)
        print("[measured] C2-0 deleteBars ratio \(ratio): remainder offset "
              + "\(remainder.startOffsetSeconds) s (expected \(expected) s)")
        #expect(abs(remainder.startOffsetSeconds - expected) < 1e-12,
                "ratio \(ratio): remainder offset \(remainder.startOffsetSeconds) s, expected \(expected) s")
    }

    // MARK: Ratio 1 — bit-identical to the undivided formula at every site

    @Test("ratio 1: split, trim and window-trim offsets are BIT-identical to the undivided formula")
    func ratioOneIsBitIdentical() throws {
        // Deliberately unround numbers, so a divide that is not an exact
        // identity (or any other reshaping of the sum) shows in the last bit.
        let bpm = 97.0
        let clip = Clip(name: "Plain", startBeat: 2.25, lengthBeats: 13.5,
                        audioFileURL: URL(fileURLWithPath: "/tmp/c2-0-plain.wav"),
                        startOffsetSeconds: 0.123)
        #expect(clip.stretchRatio == 1)
        let cut = 2.25 + 5.37

        func freshStore() throws -> (ProjectStore, UUID) {
            let store = ProjectStore()
            try store.setTempo(bpm)
            let track = store.addTrack(kind: .audio)
            store.tracks[0].clips = [clip]
            return (store, track.id)
        }

        let (splitStore, splitTrack) = try freshStore()
        let map = splitStore.transport.tempoMap
        let legacy = clip.startOffsetSeconds + map.seconds(from: clip.startBeat, to: cut)
        let (_, right) = try splitStore.splitClip(trackId: splitTrack, clipId: clip.id, atBeat: cut)
        #expect(right.startOffsetSeconds.bitPattern == legacy.bitPattern)

        let (trimStore, trimTrack) = try freshStore()
        let trimmed = try trimStore.trimClip(trackId: trimTrack, clipId: clip.id,
                                             newStartBeat: cut, newLengthBeats: 13.5 - 5.37)
        #expect(trimmed.startOffsetSeconds.bitPattern == legacy.bitPattern)

        let windowed = try #require(ProjectStore.clipTrimmedToWindow(
            clip, newStart: cut, newLength: 13.5 - 5.37, tempoMap: map))
        #expect(windowed.startOffsetSeconds.bitPattern == legacy.bitPattern)
        print("[measured] C2-0 ratio-1 legacy offset \(legacy) s: split \(right.startOffsetSeconds), "
              + "trim \(trimmed.startOffsetSeconds), window \(windowed.startOffsetSeconds)")
    }
}
