import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift) / FakeEngine (CoreTests.swift) from the
// DAWCoreTests target. FakeMedia's default info is 2.0 s → 4 beats @120 BPM.

/// m13-e — per-clip gain envelope. G1 (the pure evaluator), the store edit
/// boundary (clamp/canonicalize/coalesce/reject), clip-geometry interplay
/// (split/trim/move/overlap continuity), and G4 (persistence omit-when-empty +
/// round-trip deep-equal). Envelope truth is always `Clip.envelopeGain` /
/// `Clip.envelopeDb` — the tests never re-derive interpolation elsewhere.
@Suite("Clip gain envelope — model (m13-e)")
struct ClipGainEnvelopeModelTests {
    private func audioURL() -> URL { URL(fileURLWithPath: "/tmp/x.wav") }

    // MARK: - G1 evaluator: interpolation

    // 1.
    @Test("envelopeDb: linear-in-dB interpolation at/between points, constant beyond the ends")
    func interpolation() {
        let pts = [ClipGainPoint(beat: 0, gainDb: 0), ClipGainPoint(beat: 2, gainDb: -12)]
        // Exactly ON the points.
        #expect(Clip.envelopeDb(points: pts, atBeat: 0) == 0)
        #expect(Clip.envelopeDb(points: pts, atBeat: 2) == -12)
        // Midpoint: linear in dB → −6 exactly.
        #expect(Clip.envelopeDb(points: pts, atBeat: 1) == -6)
        // Quarter / three-quarter points.
        #expect(Clip.envelopeDb(points: pts, atBeat: 0.5) == -3)
        #expect(Clip.envelopeDb(points: pts, atBeat: 1.5) == -9)
        // Constant BEFORE the first and AT/AFTER the last.
        #expect(Clip.envelopeDb(points: pts, atBeat: -5) == 0)
        #expect(Clip.envelopeDb(points: pts, atBeat: 3) == -12)
        #expect(Clip.envelopeDb(points: pts, atBeat: 99) == -12)
        // Empty → 0 dB defensively.
        #expect(Clip.envelopeDb(points: [], atBeat: 1) == 0)
        // Single point → constant everywhere.
        let one = [ClipGainPoint(beat: 1, gainDb: 4)]
        #expect(Clip.envelopeDb(points: one, atBeat: 0) == 4)
        #expect(Clip.envelopeDb(points: one, atBeat: 5) == 4)
    }

    // 2.
    @Test("envelopeGain folds static gain × fades × envelope factor")
    func foldsWithGainAndFades() {
        let clip = Clip(name: "e", lengthBeats: 4, audioFileURL: audioURL(),
                        gainDb: -6, fadeInBeats: 1, fadeOutBeats: 1,
                        gainEnvelope: [ClipGainPoint(beat: 0, gainDb: 0),
                                       ClipGainPoint(beat: 4, gainDb: -12)])
        // Reference: staticGain × fadeIn × fadeOut × 10^(envDb/20), computed
        // independently of envelopeGain.
        func reference(_ beat: Double) -> Double {
            let staticGain = pow(10.0, -6.0 / 20.0)
            let fadeIn = beat < 1 ? beat / 1.0 : 1.0
            let fadeOut = beat > 3 ? (1 - (beat - 3) / 1.0) : 1.0
            let envDb = 0 + (-12 - 0) * (beat / 4.0)   // linear across the whole clip
            let env = pow(10.0, envDb / 20.0)
            return staticGain * fadeIn * fadeOut * env
        }
        for beat in stride(from: 0.0, through: 4.0, by: 0.1) {
            let got = clip.envelopeGain(atBeat: beat)
            #expect(abs(got - reference(beat)) < 1e-12, "beat \(beat): \(got) vs \(reference(beat))")
        }
    }

    // 3.
    @Test("empty envelope == legacy behavior BIT-FOR-BIT (no multiply)")
    func emptyIsLegacyBitIdentical() {
        // A clip with gain + fades but NO envelope must evaluate to the EXACT
        // Double the pre-m13-e formula (static × fades, zero envelope multiply)
        // produced — the null-case invariant.
        let clip = Clip(name: "n", lengthBeats: 4, audioFileURL: audioURL(),
                        gainDb: -3, fadeInBeats: 1.5, fadeOutBeats: 0.5,
                        fadeInCurve: .equalPower)
        #expect(clip.gainEnvelope.isEmpty)
        func legacy(_ beat: Double) -> Double {
            let staticGain = pow(10.0, -3.0 / 20.0)
            let b = min(max(0, beat), 4)
            var factor = staticGain
            if b < 1.5 { factor *= sin((b / 1.5) * .pi / 2) }   // equal-power fade-in
            if b > 3.5 { factor *= (1 - (b - 3.5) / 0.5) }       // linear fade-out
            return factor
        }
        for beat in stride(from: 0.0, through: 4.0, by: 0.05) {
            // Exact bitwise equality: an empty envelope must not perturb a single ULP.
            #expect(clip.envelopeGain(atBeat: beat) == legacy(beat))
        }

        // And a UNITY single-point 0 dB envelope multiplies by exactly 1.0, so
        // it is bit-identical to the empty case (× 1.0 is IEEE-transparent).
        var unity = clip
        unity.gainEnvelope = [ClipGainPoint(beat: 0, gainDb: 0)]
        for beat in stride(from: 0.0, through: 4.0, by: 0.05) {
            #expect(unity.envelopeGain(atBeat: beat) == clip.envelopeGain(atBeat: beat))
        }
    }

    // MARK: - Canonicalization + clamping

    // 4.
    @Test("canonicalGainEnvelope: clamps beats into [0,length] and gain into range, sorts, dedupes last-wins")
    func canonicalization() {
        let raw = [
            ClipGainPoint(beat: 3, gainDb: -6),
            ClipGainPoint(beat: 1, gainDb: 0),
            ClipGainPoint(beat: 1, gainDb: 5),      // duplicate beat — last wins
            ClipGainPoint(beat: 99, gainDb: 999),   // beat over length, gain over range
        ]
        let canon = Clip.canonicalGainEnvelope(raw, lengthBeats: 4)
        // Sorted ascending, distinct beats.
        #expect(canon.map(\.beat) == canon.map(\.beat).sorted())
        #expect(Set(canon.map(\.beat)).count == canon.count)
        // beat 1 deduped to the LAST value (5 dB), the 99 clamps to 4 with gain 24.
        #expect(canon.first { $0.beat == 1 }?.gainDb == 5)
        #expect(canon.first { $0.beat == 4 }?.gainDb == 24)      // gain clamped to +24
        // ClipGainPoint init clamps beat >= 0 and gain into range.
        #expect(ClipGainPoint(beat: -3, gainDb: -999).beat == 0)
        #expect(ClipGainPoint(beat: -3, gainDb: -999).gainDb == -72)
    }

    // MARK: - Split / trim continuity (windowedGainEnvelope)

    // 5.
    @Test("windowedGainEnvelope: split seam value is continuous across both halves")
    func splitContinuity() {
        let env = [ClipGainPoint(beat: 0, gainDb: 0),
                   ClipGainPoint(beat: 4, gainDb: -12)]   // −3 dB/beat
        let firstHalf = Clip.windowedGainEnvelope(env, delta: 0, newLength: 1)
        let secondHalf = Clip.windowedGainEnvelope(env, delta: 1, newLength: 3)
        // Left half ends at beat 1; right half begins at beat 0 — both must be
        // the interpolated value at the seam (−3 dB).
        let leftSeam = Clip.envelopeDb(points: firstHalf, atBeat: 1)
        let rightSeam = Clip.envelopeDb(points: secondHalf, atBeat: 0)
        #expect(abs(leftSeam - (-3)) < 1e-12)
        #expect(abs(rightSeam - (-3)) < 1e-12)
        #expect(abs(leftSeam - rightSeam) < 1e-12)
        // Empty stays empty.
        #expect(Clip.windowedGainEnvelope([], delta: 1, newLength: 3).isEmpty)
    }
}

@MainActor
@Suite("Clip gain envelope — store + persistence (m13-e)")
struct ClipGainEnvelopeStoreTests {
    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    private func storeWithAudioClip() throws -> (store: ProjectStore, trackID: UUID, clip: Clip) {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: 2.0, sampleRate: 44_100, channelCount: 2))
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: track.id)
        return (store, track.id, clip)
    }

    // 6.
    @Test("setClipGainEnvelope: clamps + canonicalizes, echoes the stored envelope, one undo")
    func setAndUndo() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        let out = try store.setClipGainEnvelope(trackId: trackID, clipId: clip.id, points: [
            ClipGainPoint(beat: 2, gainDb: -6),
            ClipGainPoint(beat: 0, gainDb: 0),      // out of order — canonicalizes
            ClipGainPoint(beat: 99, gainDb: 999),   // clamps beat→4, gain→24
        ])
        #expect(out.gainEnvelope.map(\.beat) == [0, 2, 4])
        #expect(out.gainEnvelope.last?.gainDb == 24)
        #expect(store.tracks[0].clips[0].gainEnvelope.count == 3)

        #expect(try store.undo() == "Set Clip Gain Envelope")
        #expect(store.tracks[0].clips[0].gainEnvelope.isEmpty)
    }

    // 7.
    @Test("empty points CLEARS the envelope")
    func clearWithEmpty() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        _ = try store.setClipGainEnvelope(trackId: trackID, clipId: clip.id,
                                          points: [ClipGainPoint(beat: 1, gainDb: -3)])
        #expect(!store.tracks[0].clips[0].gainEnvelope.isEmpty)
        let cleared = try store.setClipGainEnvelope(trackId: trackID, clipId: clip.id, points: [])
        #expect(cleared.gainEnvelope.isEmpty)
    }

    // 8.
    @Test("rapid edits coalesce under one undo step (drag gesture)")
    func coalescingUndo() throws {
        let (store, trackID, clip) = try storeWithAudioClip()
        // Simulate a breakpoint drag: many whole-array submits in quick succession.
        for db in stride(from: 0.0, through: -10.0, by: -1.0) {
            _ = try store.setClipGainEnvelope(trackId: trackID, clipId: clip.id,
                                              points: [ClipGainPoint(beat: 2, gainDb: db)])
        }
        #expect(store.tracks[0].clips[0].gainEnvelope.first?.gainDb == -10)
        // ONE coalesced entry → a single undo returns to the pre-gesture (empty) state.
        #expect(try store.undo() == "Set Clip Gain Envelope")
        #expect(store.tracks[0].clips[0].gainEnvelope.isEmpty)
    }

    // 9.
    @Test("MIDI clip is rejected — gain envelopes apply to audio clips only")
    func midiRejected() throws {
        let store = ProjectStore()
        let inst = store.addTrack(kind: .instrument)
        let midi = try store.addMIDIClip(toTrack: inst.id, lengthBeats: 4,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let error = projectError {
            _ = try store.setClipGainEnvelope(trackId: inst.id, clipId: midi.id,
                                              points: [ClipGainPoint(beat: 1, gainDb: -3)])
        }
        guard case .invalidClipEdit(let message)? = error else {
            Issue.record("expected invalidClipEdit, got \(String(describing: error))")
            return
        }
        #expect(message.contains("gain envelopes apply to audio clips only"))
    }

    // 10.
    @Test("split partitions the envelope with a continuous seam (live store)")
    func splitPartitions() throws {
        let (store, trackID, clip) = try storeWithAudioClip()   // 4 beats
        _ = try store.setClipGainEnvelope(trackId: trackID, clipId: clip.id, points: [
            ClipGainPoint(beat: 0, gainDb: 0),
            ClipGainPoint(beat: 4, gainDb: -12),
        ])
        let (first, second) = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: 1)
        // Both halves keep an envelope; the seam value matches on both sides.
        #expect(!first.gainEnvelope.isEmpty)
        #expect(!second.gainEnvelope.isEmpty)
        let leftSeam = Clip.envelopeDb(points: first.gainEnvelope, atBeat: first.lengthBeats)
        let rightSeam = Clip.envelopeDb(points: second.gainEnvelope, atBeat: 0)
        #expect(abs(leftSeam - (-3)) < 1e-9)     // −3 dB/beat × 1 beat
        #expect(abs(leftSeam - rightSeam) < 1e-9)
    }

    // 11.
    @Test("trim re-windows the envelope; move carries it for free")
    func trimAndMove() throws {
        let (store, trackID, clip) = try storeWithAudioClip()   // 4 beats
        _ = try store.setClipGainEnvelope(trackId: trackID, clipId: clip.id, points: [
            ClipGainPoint(beat: 0, gainDb: 0),
            ClipGainPoint(beat: 4, gainDb: -12),
        ])
        // Trim the leading edge in by 1 beat: new window [1,3], length 2.
        let trimmed = try store.trimClip(trackId: trackID, clipId: clip.id,
                                         newStartBeat: 1, newLengthBeats: 2)
        #expect(!trimmed.gainEnvelope.isEmpty)
        // The trimmed clip's beat 0 corresponds to old beat 1 (−3 dB).
        #expect(abs(Clip.envelopeDb(points: trimmed.gainEnvelope, atBeat: 0) - (-3)) < 1e-9)
        // Move it: envelope is clip-relative, so it is byte-preserved.
        let before = store.tracks[0].clips[0].gainEnvelope
        _ = try store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: 8)
        #expect(store.tracks[0].clips[0].gainEnvelope == before)
    }

    // 12.
    @Test("overlap-trim keeps the stationary clip's envelope (no silent drop)")
    func overlapTrimPreservesEnvelope() throws {
        let store = ProjectStore()
        store.media = FakeMedia(info: AudioFileInfo(
            durationSeconds: 2.0, sampleRate: 44_100, channelCount: 2))
        let track = store.addTrack(kind: .audio)
        // Two clips: resident [0,4], mover imported then placed to overlap the tail.
        let resident = try store.importAudio(url: URL(fileURLWithPath: "/tmp/A.wav"), toTrack: track.id)
        _ = try store.setClipGainEnvelope(trackId: track.id, clipId: resident.id, points: [
            ClipGainPoint(beat: 0, gainDb: 0),
            ClipGainPoint(beat: 4, gainDb: -12),
        ])
        let mover = try store.importAudio(url: URL(fileURLWithPath: "/tmp/B.wav"), toTrack: track.id)
        // Move the mover to start at beat 2, overlapping the resident's tail →
        // resident trims its tail to [0,2] via the overlap choke point.
        _ = try store.moveClip(trackId: track.id, clipId: mover.id, toStartBeat: 2)
        let trimmedResident = try #require(store.tracks[0].clips.first { $0.id == resident.id })
        #expect(abs(trimmedResident.lengthBeats - 2) < 1e-9)
        // Envelope survived the trim (its beat 0 is still 0 dB).
        #expect(!trimmedResident.gainEnvelope.isEmpty)
        #expect(abs(Clip.envelopeDb(points: trimmedResident.gainEnvelope, atBeat: 0) - 0) < 1e-9)
    }

    // MARK: - G4 persistence

    // 13.
    @Test("empty envelope writes NO gainEnvelope key to disk (model + DTO)")
    func omitWhenEmpty() throws {
        let clip = Clip(name: "a", lengthBeats: 4, audioFileURL: URL(fileURLWithPath: "/tmp/x.wav"))
        // Model Codable.
        let modelObj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(clip)) as? [String: Any]
        #expect(modelObj?["gainEnvelope"] == nil)
        // ProjectDocument DTO (the disk path).
        let dto = ClipDocument(from: clip, media: nil)
        let dtoObj = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(dto)) as? [String: Any]
        #expect(dtoObj?["gainEnvelope"] == nil)
    }

    // 14.
    @Test("a non-trivial envelope round-trips deep-equal through save→reopen (the DTO)")
    func roundTripDeepEqual() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-envpersist-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (store, trackID, clip) = try storeWithAudioClip()
        let points = [
            ClipGainPoint(beat: 0, gainDb: 0),
            ClipGainPoint(beat: 1.5, gainDb: -6),
            ClipGainPoint(beat: 4, gainDb: 3),
        ]
        _ = try store.setClipGainEnvelope(trackId: trackID, clipId: clip.id, points: points)
        let path = dir.appendingPathComponent("Env").path
        try store.saveProject(to: path)

        // On-disk DTO carries the key.
        let document = try ProjectBundle.read(from: URL(fileURLWithPath: store.projectPath!))
        let clipDoc = try #require(document.tracks.first?.clips.first)
        #expect(clipDoc.gainEnvelope?.count == 3)

        // Reopen → deep-equal envelope.
        let reopened = ProjectStore()
        try reopened.openProject(at: path)
        let restored = try #require(reopened.tracks.first?.clips.first)
        #expect(restored.gainEnvelope == store.tracks[0].clips[0].gainEnvelope)
        #expect(restored.gainEnvelope.map(\.beat) == [0, 1.5, 4])
        #expect(restored.gainEnvelope.map(\.gainDb) == [0, -6, 3])
    }
}
