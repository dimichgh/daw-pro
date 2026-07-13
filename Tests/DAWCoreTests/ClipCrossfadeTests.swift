import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift, default 2.0 s → 4 beats at 120 BPM) and
// FakeEngine (CoreTests.swift) from the DAWCoreTests target.

/// m11-d — arrange-level clip crossfades + move/import overlap correctness.
/// The settled overlap invariant: no SILENT overlap of ordinary same-track
/// clips. `moveClip` and the targeted import trim/remove the stationary clip;
/// `crossfadeClips` is the ONLY sanctioned overlap (exactly covered by
/// complementary equal-power fades).
@MainActor
@Suite("Clip crossfade + overlap correctness (m11-d)")
struct ClipCrossfadeTests {
    private let url = URL(fileURLWithPath: "/tmp/Loop.wav")

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// A store (FakeMedia 2.0 s) with one audio track holding two 4-beat clips
    /// at [0,4] and [4,8] (imported sequentially).
    private func storeWithTwoAudioClips() throws -> (ProjectStore, UUID, Clip, Clip) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let a = try store.importAudio(url: url, toTrack: track.id)  // [0,4]
        let b = try store.importAudio(url: url, toTrack: track.id)  // [4,8]
        return (store, track.id, a, b)
    }

    /// True when no two clips on the track share any timeline span (the
    /// no-silent-overlap invariant).
    private func noOverlaps(_ store: ProjectStore, _ trackID: UUID) -> Bool {
        let clips = store.tracks.first { $0.id == trackID }!.clips
            .sorted { $0.startBeat < $1.startBeat }
        for i in 1..<max(1, clips.count) {
            if clips[i].startBeat + 1e-9 < clips[i - 1].startBeat + clips[i - 1].lengthBeats {
                return false
            }
        }
        return true
    }

    // MARK: - moveClip overlap resolution

    // 1.
    @Test("move onto a clip's TAIL trims the stationary clip's trailing edge")
    func moveTrimsTail() throws {
        let (store, trackID, a, b) = try storeWithTwoAudioClips()
        // Move B (from [4,8]) to start 2 → active [2,6] covers A's tail [2,4].
        let result = try store.moveClip(trackId: trackID, clipId: b.id, toStartBeat: 2)
        #expect(result.clip.startBeat == 2)
        #expect(result.trimmedClipIDs == [a.id])
        #expect(result.removedClipIDs.isEmpty)

        let trimmedA = store.tracks[0].clips.first { $0.id == a.id }!
        #expect(trimmedA.startBeat == 0)
        #expect(abs(trimmedA.lengthBeats - 2) < 1e-9)   // trailing edge trimmed to 2
        #expect(noOverlaps(store, trackID))
    }

    // 2.
    @Test("move onto a clip's HEAD trims the stationary clip's leading edge + advances the audio offset")
    func moveTrimsHead() throws {
        let (store, trackID, a, b) = try storeWithTwoAudioClips()
        // Move A (from [0,4]) to start 2 → active [2,6] covers B's head [4,6].
        let result = try store.moveClip(trackId: trackID, clipId: a.id, toStartBeat: 2)
        #expect(result.trimmedClipIDs == [b.id])
        let trimmedB = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(trimmedB.startBeat == 6)                 // leading edge trimmed to 6
        #expect(abs(trimmedB.lengthBeats - 2) < 1e-9)
        // Leading-edge trim of 2 beats advances the source offset by 2*60/120 = 1 s.
        #expect(abs(trimmedB.startOffsetSeconds - 1.0) < 1e-9)
        #expect(noOverlaps(store, trackID))
    }

    // 3.
    @Test("a move that fully covers a shorter stationary clip REMOVES it")
    func moveRemovesFullyCovered() throws {
        let (store, trackID, a, b) = try storeWithTwoAudioClips()
        // Shrink B to a 2-beat clip sitting inside A's coming window.
        _ = try store.trimClip(trackId: trackID, clipId: b.id, newStartBeat: 5, newLengthBeats: 2) // [5,7]
        // Move A (4 beats) to start 4 → active [4,8] fully covers B [5,7].
        let result = try store.moveClip(trackId: trackID, clipId: a.id, toStartBeat: 4)
        #expect(result.removedClipIDs == [b.id])
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(store.tracks[0].clips.count == 1)         // only A remains
        #expect(store.tracks[0].clips[0].id == a.id)
    }

    // 4.
    @Test("MIDI move-trim drops notes past the new stationary edge")
    func moveTrimsMIDINotes() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let a = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                      notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let b = try store.addMIDIClip(toTrack: track.id, atBeat: 4, lengthBeats: 4, notes: [
            MIDINote(pitch: 62, startBeat: 0, lengthBeats: 1),   // timeline 4
            MIDINote(pitch: 64, startBeat: 1, lengthBeats: 1),   // timeline 5
            MIDINote(pitch: 65, startBeat: 2, lengthBeats: 1),   // timeline 6 — dropped
            MIDINote(pitch: 67, startBeat: 3, lengthBeats: 1),   // timeline 7 — dropped
        ])
        // Move A (from [0,4]) to start 6 → active [6,10] covers B's tail [6,8].
        let result = try store.moveClip(trackId: track.id, clipId: a.id, toStartBeat: 6)
        #expect(result.trimmedClipIDs == [b.id])
        let trimmedB = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(abs(trimmedB.lengthBeats - 2) < 1e-9)
        let pitches = Set((trimmedB.notes ?? []).map(\.pitch))
        #expect(pitches == [62, 64])                     // local 2/3 (t6/t7) dropped
        #expect(noOverlaps(store, track.id))
    }

    // 5.
    @Test("a move that trims a neighbour is ONE undo step restoring BOTH clips")
    func moveTrimIsOneUndoStep() throws {
        let (store, trackID, a, b) = try storeWithTwoAudioClips()
        let label = "Move Clip '\(b.name)'"
        _ = try store.moveClip(trackId: trackID, clipId: b.id, toStartBeat: 2)
        #expect(store.tracks[0].clips.first { $0.id == a.id }!.lengthBeats < 4)

        #expect(try store.undo() == label)
        // Both the moved clip AND the trimmed neighbour are restored in one step.
        let ra = store.tracks[0].clips.first { $0.id == a.id }!
        let rb = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(ra.startBeat == 0 && ra.lengthBeats == 4)
        #expect(rb.startBeat == 4 && rb.lengthBeats == 4)
    }

    // 6.
    @Test("a plain move onto free space carries empty trimmed/removed arrays")
    func moveNoOverlapNoTrim() throws {
        let (store, trackID, _, b) = try storeWithTwoAudioClips()
        let result = try store.moveClip(trackId: trackID, clipId: b.id, toStartBeat: 20)
        #expect(result.trimmedClipIDs.isEmpty)
        #expect(result.removedClipIDs.isEmpty)
        #expect(result.clip.startBeat == 20)
    }

    // MARK: - crossfadeClips

    /// Splits a freshly-imported 4-beat clip at beat 2 into two adjacent 2-beat
    /// halves A[0,2] and B[2,4], each reading half the 2.0 s source.
    private func storeWithAdjacentHalves() throws -> (ProjectStore, UUID, Clip, Clip) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let whole = try store.importAudio(url: url, toTrack: track.id)  // [0,4]
        let (a, b) = try store.splitClip(trackId: track.id, clipId: whole.id, atBeat: 2)
        return (store, track.id, a, b)
    }

    // 7.
    @Test("crossfade of adjacent clips sets equal-power fades spanning EXACTLY the overlap")
    func crossfadeAdjacentEqualPower() throws {
        let (store, trackID, a, b) = try storeWithAdjacentHalves()
        let result = try store.crossfadeClips(trackId: trackID, clipId: a.id,
                                              otherClipId: b.id, lengthBeats: 1)
        #expect(abs(result.overlapBeats - 1) < 1e-9)
        // Left/right resolved by start beat.
        #expect(result.left.id == a.id && result.right.id == b.id)
        // A extends its tail by 0.5, B extends its head by 0.5 → both 2.5 beats.
        #expect(abs(result.left.lengthBeats - 2.5) < 1e-9)
        #expect(abs(result.right.startBeat - 1.5) < 1e-9)
        #expect(abs(result.right.lengthBeats - 2.5) < 1e-9)
        // The overlap is exactly 1 beat and equal-power on both sides.
        let overlap = (result.left.startBeat + result.left.lengthBeats) - result.right.startBeat
        #expect(abs(overlap - 1) < 1e-9)
        #expect(abs(result.left.fadeOutBeats - 1) < 1e-9)
        #expect(result.left.fadeOutCurve == .equalPower)
        #expect(abs(result.right.fadeInBeats - 1) < 1e-9)
        #expect(result.right.fadeInCurve == .equalPower)
        #expect(noOverlaps(store, trackID) == false)      // the ONLY sanctioned overlap
    }

    // 8.
    @Test("crossfade PRESERVES each clip's opposite fade")
    func crossfadePreservesOtherFade() throws {
        let (store, trackID, a, b) = try storeWithAdjacentHalves()
        // A gets a fade-IN, B gets a fade-OUT — the far sides from the seam.
        _ = try store.setClipFades(trackId: trackID, clipId: a.id, fadeInBeats: 0.5, fadeOutBeats: 0,
                                   fadeInCurve: .linear, fadeOutCurve: .linear)
        _ = try store.setClipFades(trackId: trackID, clipId: b.id, fadeInBeats: 0, fadeOutBeats: 0.5,
                                   fadeInCurve: .linear, fadeOutCurve: .linear)
        let result = try store.crossfadeClips(trackId: trackID, clipId: a.id,
                                              otherClipId: b.id, lengthBeats: 1)
        // The opposite fades survive untouched (no collision — 0.5 + 1 <= 2.5).
        #expect(abs(result.left.fadeInBeats - 0.5) < 1e-9)
        #expect(result.left.fadeInCurve == .linear)
        #expect(abs(result.right.fadeOutBeats - 0.5) < 1e-9)
        #expect(result.right.fadeOutCurve == .linear)
    }

    // 9.
    @Test("crossfade is ONE undo step restoring both clips")
    func crossfadeIsOneUndoStep() throws {
        let (store, trackID, a, b) = try storeWithAdjacentHalves()
        _ = try store.crossfadeClips(trackId: trackID, clipId: a.id,
                                     otherClipId: b.id, lengthBeats: 1)
        #expect(try store.undo() == "Crossfade Clips")
        let ra = store.tracks[0].clips.first { $0.id == a.id }!
        let rb = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(abs(ra.lengthBeats - 2) < 1e-9 && ra.fadeOutBeats == 0)
        #expect(abs(rb.startBeat - 2) < 1e-9 && rb.fadeInBeats == 0)
    }

    // 10.
    @Test("crossfade normalizes a legacy overlap: keeps the overlap, applies the fades")
    func crossfadeNormalizesLegacyOverlap() throws {
        let (store, trackID, a, b) = try storeWithAdjacentHalves()
        // Simulate a pre-fix silent overlap: slide B's start left by 0.5 with no
        // fades (bypassing moveClip's trim via a direct test-only mutation).
        store.tracks[0].clips[1].startBeat = 1.5
        #expect(noOverlaps(store, trackID) == false)      // 0.5-beat silent overlap
        let result = try store.crossfadeClips(trackId: trackID, clipId: a.id,
                                              otherClipId: b.id, lengthBeats: 1)
        // The EXISTING 0.5-beat overlap is kept (not grown to the 1-beat request).
        #expect(abs(result.overlapBeats - 0.5) < 1e-9)
        #expect(abs(result.right.startBeat - 1.5) < 1e-9) // no head extension
        #expect(abs(result.left.lengthBeats - 2) < 1e-9)  // no tail extension
        #expect(abs(result.left.fadeOutBeats - 0.5) < 1e-9)
        #expect(result.left.fadeOutCurve == .equalPower)
        #expect(abs(result.right.fadeInBeats - 0.5) < 1e-9)
        #expect(result.right.fadeInCurve == .equalPower)
    }

    // 11.
    @Test("crossfade throws crossfadeNeedsMaterial naming the clip that can't extend")
    func crossfadeNeedsMaterial() throws {
        let store = ProjectStore()
        store.media = FakeMedia()   // 2.0 s file
        let track = store.addTrack(kind: .audio)
        // A fills the whole 2.0 s source (window ends at the file end → no tail).
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4, audioFileURL: url, startOffsetSeconds: 0)
        // B has head material (offset 0.5 s) and is adjacent.
        let b = Clip(name: "B", startBeat: 4, lengthBeats: 4, audioFileURL: url, startOffsetSeconds: 0.5)
        store.tracks[0].clips = [a, b]
        let err = projectError {
            _ = try store.crossfadeClips(trackId: track.id, clipId: a.id,
                                         otherClipId: b.id, lengthBeats: 1)
        }
        guard case .crossfadeNeedsMaterial(let msg)? = err else {
            Issue.record("expected crossfadeNeedsMaterial, got \(String(describing: err))"); return
        }
        #expect(msg.contains("'A'"))   // names the tail-less clip

        // The mirror: B with no head material errors naming B.
        let a2 = Clip(name: "A2", startBeat: 0, lengthBeats: 2, audioFileURL: url, startOffsetSeconds: 0)
        let b2 = Clip(name: "B2", startBeat: 2, lengthBeats: 2, audioFileURL: url, startOffsetSeconds: 0)
        store.tracks[0].clips = [a2, b2]
        let err2 = projectError {
            _ = try store.crossfadeClips(trackId: track.id, clipId: a2.id,
                                         otherClipId: b2.id, lengthBeats: 1)
        }
        guard case .crossfadeNeedsMaterial(let msg2)? = err2 else {
            Issue.record("expected crossfadeNeedsMaterial for B, got \(String(describing: err2))"); return
        }
        #expect(msg2.contains("'B2'"))
    }

    // 12.
    @Test("crossfade rejects a MIDI clip, a gap, and same-clip ids")
    func crossfadeEligibilityErrors() throws {
        let (store, trackID, a, b) = try storeWithAdjacentHalves()

        // Same clip twice.
        let same = projectError {
            _ = try store.crossfadeClips(trackId: trackID, clipId: a.id, otherClipId: a.id, lengthBeats: 1)
        }
        guard case .crossfadeNotEligible? = same else { Issue.record("expected notEligible (same)"); return }

        // A gap between them (move B far away first — trims nothing).
        _ = try store.moveClip(trackId: trackID, clipId: b.id, toStartBeat: 10)
        let gap = projectError {
            _ = try store.crossfadeClips(trackId: trackID, clipId: a.id, otherClipId: b.id, lengthBeats: 1)
        }
        guard case .crossfadeNotEligible(let gapMsg)? = gap else { Issue.record("expected notEligible (gap)"); return }
        #expect(gapMsg.contains("gap"))

        // A MIDI clip is rejected.
        let inst = store.addTrack(kind: .instrument)
        let m1 = try store.addMIDIClip(toTrack: inst.id, atBeat: 0, lengthBeats: 4)
        let m2 = try store.addMIDIClip(toTrack: inst.id, atBeat: 4, lengthBeats: 4)
        let midi = projectError {
            _ = try store.crossfadeClips(trackId: inst.id, clipId: m1.id, otherClipId: m2.id, lengthBeats: 1)
        }
        guard case .crossfadeNotEligible(let midiMsg)? = midi else { Issue.record("expected notEligible (midi)"); return }
        #expect(midiMsg.contains("MIDI"))
    }

    // MARK: - import overlap resolution

    // 13.
    @Test("a targeted import onto an occupied lane region trims the resident clip (one undo step)")
    func importOntoOccupiedLaneTrims() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let resident = try store.importAudio(url: url, toTrack: track.id)  // [0,4]
        // Import a second file onto the SAME lane at beat 2 → overlaps [2,4].
        let outcomes = try store.importAudioBatch([
            AudioImportRequest(url: url, destination: .existingTrack(track.id), startBeat: 2)
        ])
        #expect(outcomes.count == 1)
        #expect(outcomes[0].error == nil)
        // Resident clip's tail trimmed to 2; the incoming clip lands at [2,6].
        let residentAfter = store.tracks[0].clips.first { $0.id == resident.id }!
        #expect(abs(residentAfter.lengthBeats - 2) < 1e-9)
        #expect(noOverlaps(store, track.id))
        #expect(store.tracks[0].clips.count == 2)

        // The whole import (place + trim) is ONE undo step.
        #expect(store.canUndo)
        _ = try store.undo()
        #expect(store.tracks[0].clips.count == 1)
        #expect(abs(store.tracks[0].clips[0].lengthBeats - 4) < 1e-9)  // resident restored
    }
}

/// m13-b — completes the no-silent-overlap invariant across the four verbs the
/// M13 audit (B2) proved bypassed the m11-d policy: `clip.trim` extend,
/// `clip.stretchToLength`, `clip.addAudio atBeat`, `clip.addMIDI atBeat`, plus
/// the extra geometry-GROWING verb found while auditing (`insertTimeRange`).
/// Every geometry-committing verb now routes through the ONE
/// `resolvingOverlaps` choke point, inside its single `performEdit`. Take/comp
/// members stay exempt (takes intentionally stack). Reuses FakeMedia (2.0 s →
/// 4 beats at 120 BPM) and FakeEngine from the DAWCoreTests target.
@MainActor
@Suite("No-silent-overlap completion — the four bypass verbs (m13-b)")
struct NoSilentOverlapCompletionTests {
    private let url = URL(fileURLWithPath: "/tmp/Loop.wav")

    /// True when no two ORDINARY (non-take) clips on the track share any span.
    private func noOverlaps(_ store: ProjectStore, _ trackID: UUID) -> Bool {
        let clips = store.tracks.first { $0.id == trackID }!.clips
            .filter { $0.takeGroupID == nil }
            .sorted { $0.startBeat < $1.startBeat }
        guard clips.count > 1 else { return true }
        for i in 1..<clips.count {
            if clips[i].startBeat + 1e-9 < clips[i - 1].startBeat + clips[i - 1].lengthBeats {
                return false
            }
        }
        return true
    }

    /// Audio track with two 4-beat clips at [0,4] and [4,8] (sequential import).
    private func twoAudioClips() throws -> (ProjectStore, UUID, Clip, Clip) {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let a = try store.importAudio(url: url, toTrack: track.id)   // [0,4]
        let b = try store.importAudio(url: url, toTrack: track.id)   // [4,8]
        return (store, track.id, a, b)
    }

    // MARK: - clip.trim extend (bypass #1, audit overlap [124,125])

    @Test("trim EXTEND over a neighbour trims the resident's head (no overlap)")
    func trimExtendTrimsResidentHead() throws {
        let (store, trackID, a, b) = try twoAudioClips()
        // Extend A's trailing edge to length 5 → active [0,5] covers B's head [4,5].
        let trimmed = try store.trimClip(trackId: trackID, clipId: a.id,
                                         newStartBeat: 0, newLengthBeats: 5)
        #expect(abs(trimmed.lengthBeats - 5) < 1e-9)
        let residentB = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(abs(residentB.startBeat - 5) < 1e-9)          // leading edge → 5
        #expect(abs(residentB.lengthBeats - 3) < 1e-9)
        // Leading-edge trim of 1 beat advances the source offset by 1*60/120 = 0.5 s.
        #expect(abs(residentB.startOffsetSeconds - 0.5) < 1e-9)
        #expect(noOverlaps(store, trackID))
    }

    @Test("trim EXTEND that trims a neighbour is ONE undo step restoring BOTH clips")
    func trimExtendIsOneUndoStep() throws {
        let (store, trackID, a, b) = try twoAudioClips()
        _ = try store.trimClip(trackId: trackID, clipId: a.id, newStartBeat: 0, newLengthBeats: 5)
        #expect(store.tracks[0].clips.first { $0.id == b.id }!.startBeat == 5)
        #expect(try store.undo() == "Trim Clip '\(a.name)'")
        let ra = store.tracks[0].clips.first { $0.id == a.id }!
        let rb = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(ra.startBeat == 0 && abs(ra.lengthBeats - 4) < 1e-9)
        #expect(rb.startBeat == 4 && abs(rb.lengthBeats - 4) < 1e-9)
    }

    @Test("trim EXTEND leaving a sub-minClipLength remnant REMOVES the resident")
    func trimExtendSubMinRemnantRemovesResident() throws {
        let (store, trackID, a, b) = try twoAudioClips()
        // Extend A to end at 7.99 → B's remnant [7.99,8] = 0.01 < 1/32 → removed.
        _ = try store.trimClip(trackId: trackID, clipId: a.id, newStartBeat: 0, newLengthBeats: 7.99)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id == a.id)
        #expect(store.tracks[0].clips.first { $0.id == b.id } == nil)
        #expect(noOverlaps(store, trackID))
    }

    // MARK: - clip.stretchToLength (bypass #2, audit overlap [124,126])

    @Test("stretchToLength over a neighbour trims the resident's head (no overlap)")
    func stretchTrimsResidentHead() throws {
        let (store, trackID, a, b) = try twoAudioClips()
        // Stretch A from 4 → 6 beats → active [0,6] covers B's head [4,6].
        let stretched = try store.stretchClip(trackId: trackID, clipId: a.id, toLengthBeats: 6)
        #expect(abs(stretched.lengthBeats - 6) < 1e-9)
        let residentB = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(abs(residentB.startBeat - 6) < 1e-9)
        #expect(abs(residentB.lengthBeats - 2) < 1e-9)
        #expect(noOverlaps(store, trackID))
    }

    @Test("stretchToLength that trims a neighbour is ONE undo step restoring BOTH clips")
    func stretchIsOneUndoStep() throws {
        let (store, trackID, a, b) = try twoAudioClips()
        _ = try store.stretchClip(trackId: trackID, clipId: a.id, toLengthBeats: 6)
        #expect(store.tracks[0].clips.first { $0.id == b.id }!.startBeat == 6)
        #expect(try store.undo() == "Stretch Clip '\(a.name)'")
        let ra = store.tracks[0].clips.first { $0.id == a.id }!
        let rb = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(abs(ra.lengthBeats - 4) < 1e-9)
        #expect(rb.startBeat == 4 && abs(rb.lengthBeats - 4) < 1e-9)
    }

    @Test("stretchToLength that fully covers a neighbour REMOVES it")
    func stretchFullyCoversRemovesResident() throws {
        let (store, trackID, a, b) = try twoAudioClips()
        // Shrink B to a 2-beat clip at [4,6], then stretch A to length 8 → [0,8]
        // fully covers B.
        _ = try store.trimClip(trackId: trackID, clipId: b.id, newStartBeat: 4, newLengthBeats: 2)
        _ = try store.stretchClip(trackId: trackID, clipId: a.id, toLengthBeats: 8)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id == a.id)
        #expect(noOverlaps(store, trackID))
    }

    // MARK: - clip.addAudio atBeat (bypass #3, audit overlap [1,120] full doubling)

    @Test("addAudio atBeat over a resident trims the resident's tail (no overlap)")
    func addAudioAtBeatTrimsResidentTail() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let resident = try store.importAudio(url: url, toTrack: track.id)     // [0,4]
        // Land a second clip at beat 2 → active [2,6] covers resident's tail [2,4].
        let landed = try store.importAudio(url: url, toTrack: track.id, atBeat: 2)
        #expect(abs(landed.startBeat - 2) < 1e-9)
        let residentAfter = store.tracks[0].clips.first { $0.id == resident.id }!
        #expect(abs(residentAfter.lengthBeats - 2) < 1e-9)   // tail trimmed to 2
        #expect(store.tracks[0].clips.count == 2)
        #expect(noOverlaps(store, track.id))
    }

    @Test("addAudio atBeat that FULLY doubles a resident collapses to a single clip (worst shape)")
    func addAudioFullDoublingCollapsesToSingle() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let resident = try store.importAudio(url: url, toTrack: track.id)     // [0,4]
        // The audit's worst shape: land a second identical clip AT the resident's
        // start → it fully covers the resident → the silent volume-doubling
        // collapses to ONE clip (the loudness-honesty geometry).
        let landed = try store.importAudio(url: url, toTrack: track.id, atBeat: 0)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id == landed.id)
        #expect(store.tracks[0].clips.first { $0.id == resident.id } == nil)
        #expect(noOverlaps(store, track.id))
    }

    @Test("addAudio atBeat that trims a resident is ONE undo step restoring it")
    func addAudioAtBeatIsOneUndoStep() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let resident = try store.importAudio(url: url, toTrack: track.id)     // [0,4]
        let landed = try store.importAudio(url: url, toTrack: track.id, atBeat: 2)
        #expect(store.tracks[0].clips.first { $0.id == resident.id }!.lengthBeats < 4)
        #expect(try store.undo() == "Import '\(landed.name)'")
        #expect(store.tracks[0].clips.count == 1)
        #expect(abs(store.tracks[0].clips[0].lengthBeats - 4) < 1e-9)   // resident restored
        #expect(store.tracks[0].clips[0].id == resident.id)
    }

    @Test("addAudio atBeat leaving a sub-minClipLength remnant REMOVES the resident")
    func addAudioSubMinRemnantRemovesResident() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let resident = try store.importAudio(url: url, toTrack: track.id)     // [0,4]
        // Land at 0.01 → resident's head remnant [0,0.01] = 0.01 < 1/32 → removed.
        _ = try store.importAudio(url: url, toTrack: track.id, atBeat: 0.01)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips.first { $0.id == resident.id } == nil)
        #expect(noOverlaps(store, track.id))
    }

    // MARK: - clip.addMIDI atBeat (bypass #4, audit overlap [2,4] double-note)

    @Test("addMIDI atBeat over a resident trims the resident's tail notes (no double-note)")
    func addMIDIAtBeatTrimsResidentNotes() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let resident = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),   // timeline 0
            MIDINote(pitch: 62, startBeat: 1, lengthBeats: 1),   // timeline 1
            MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1),   // timeline 2 — dropped
            MIDINote(pitch: 65, startBeat: 3, lengthBeats: 1),   // timeline 3 — dropped
        ])
        // Land a new MIDI clip at beat 2 → active [2,6] covers resident tail [2,4].
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 2, lengthBeats: 4)
        let residentAfter = store.tracks[0].clips.first { $0.id == resident.id }!
        #expect(abs(residentAfter.lengthBeats - 2) < 1e-9)
        #expect(Set((residentAfter.notes ?? []).map(\.pitch)) == [60, 62])
        #expect(noOverlaps(store, track.id))
    }

    @Test("addMIDI atBeat that trims a resident is ONE undo step restoring its notes")
    func addMIDIAtBeatIsOneUndoStep() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let resident = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1),
            MIDINote(pitch: 64, startBeat: 3, lengthBeats: 1),
        ])
        let landed = try store.addMIDIClip(toTrack: track.id, atBeat: 2, lengthBeats: 4)
        #expect(store.tracks[0].clips.first { $0.id == resident.id }!.lengthBeats < 4)
        #expect(try store.undo() == "Add MIDI Clip '\(landed.name)'")
        let restored = store.tracks[0].clips.first { $0.id == resident.id }!
        #expect(abs(restored.lengthBeats - 4) < 1e-9)
        #expect(Set((restored.notes ?? []).map(\.pitch)) == [60, 64])
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("addMIDI atBeat leaving a sub-minClipLength remnant REMOVES the resident")
    func addMIDISubMinRemnantRemovesResident() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let resident = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4)
        // Land at 0.01 → resident head remnant [0,0.01] = 0.01 < 1/32 → removed.
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 0.01, lengthBeats: 4)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips.first { $0.id == resident.id } == nil)
        #expect(noOverlaps(store, track.id))
    }

    // MARK: - insertTimeRange (extra geometry-GROWING verb found by audit)

    @Test("insertTimeRange growth over a neighbour trims it, in ONE undo step")
    func insertTimeRangeGrowthTrimsNeighbour() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let a = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: 4,
                                      notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let b = try store.addMIDIClip(toTrack: track.id, atBeat: 4, lengthBeats: 4)
        // Insert 2 beats of silence inside A → A grows to [0,6], covering B's head [4,6].
        let grown = try store.insertTimeRange(clipID: a.id, atBeat: 2, lengthBeats: 2)
        #expect(abs(grown.lengthBeats - 6) < 1e-9)
        let residentB = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(abs(residentB.startBeat - 6) < 1e-9)
        #expect(abs(residentB.lengthBeats - 2) < 1e-9)
        #expect(noOverlaps(store, track.id))
        // One undo restores BOTH the grown clip and the trimmed neighbour.
        #expect(try store.undo() == "Insert Time Range")
        #expect(abs(store.tracks[0].clips.first { $0.id == a.id }!.lengthBeats - 4) < 1e-9)
        #expect(store.tracks[0].clips.first { $0.id == b.id }!.startBeat == 4)
    }

    // MARK: - Take/comp members stay exempt (regression pin)

    @Test("take-group members STILL STACK — an overlapping verb never trims them")
    func takeMembersStayStacked() throws {
        // Two overlapping audio clips grouped into a take group (members stack).
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     audioFileURL: URL(fileURLWithPath: "/tmp/a.wav"))
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     audioFileURL: URL(fileURLWithPath: "/tmp/b.wav"))
        let track = Track(name: "Aud", kind: .audio, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        store.media = FakeMedia()
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let memberBefore = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })

        // Land a new ordinary clip AT the group's range [0,4] via clip.addAudio.
        let landed = try store.importAudio(url: url, toTrack: track.id, atBeat: 0)

        // The take-group member is UNTOUCHED (takes intentionally stack); the new
        // ordinary clip lands over it.
        let memberAfter = try #require(store.tracks[0].clips.first { $0.id == memberBefore.id })
        #expect(memberAfter.startBeat == memberBefore.startBeat)
        #expect(memberAfter.lengthBeats == memberBefore.lengthBeats)
        #expect(memberAfter.takeGroupID == memberBefore.takeGroupID)
        #expect(store.tracks[0].clips.contains { $0.id == landed.id })
    }
}
