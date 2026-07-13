import Foundation
import Testing
@testable import DAWCore

// Reuses FakeMedia (ImportTests.swift, default 2.0 s → 4 beats at 120 BPM),
// FakeEngine (CoreTests.swift), and FakeRecordingEngine (RecordingStoreTests.swift)
// from the DAWCoreTests target.

/// m15-d — agent arrangement ergonomics: `duplicateClip`, and the PROJECT-WIDE
/// meter-aware `insertBars` / `deleteBars` that rigidly translate a chunk of the
/// arrangement (clips, markers, tempo + meter maps, automation, loop/punch) in
/// ONE undo. Every policy documented on the store methods is pinned here.
@MainActor
@Suite("Arrangement ergonomics (m15-d)")
struct ArrangeTests {
    private let url = URL(fileURLWithPath: "/tmp/Loop.wav")

    private func projectError(_ body: () throws -> Void) -> ProjectError? {
        do { try body(); return nil }
        catch let error as ProjectError { return error }
        catch { Issue.record("unexpected error type: \(error)"); return nil }
    }

    /// True when no two clips on the track share any timeline span.
    private func noOverlaps(_ store: ProjectStore, _ trackID: UUID) -> Bool {
        let clips = store.tracks.first { $0.id == trackID }!.clips
            .sorted { $0.startBeat < $1.startBeat }
        for i in 1..<max(1, clips.count) where clips.count > 1 {
            if clips[i].startBeat + 1e-9 < clips[i - 1].startBeat + clips[i - 1].lengthBeats {
                return false
            }
        }
        return true
    }

    // MARK: - clip.duplicate

    @Test("duplicate appends flush after the source, value-copies everything, fresh id, ONE undo")
    func duplicateSameTrackAppend() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let a = try store.importAudio(url: url, toTrack: track.id)  // [0,4]
        _ = try store.setClipGain(trackId: track.id, clipId: a.id, gainDb: -6)
        _ = try store.setClipFades(trackId: track.id, clipId: a.id,
                                   fadeInBeats: 1, fadeOutBeats: 0.5,
                                   fadeInCurve: .equalPower, fadeOutCurve: .linear)
        let source = store.tracks[0].clips.first { $0.id == a.id }!

        let before = store.journal.undoStack.count
        let result = try store.duplicateClip(clipId: a.id)
        #expect(store.journal.undoStack.count == before + 1)   // ONE undo

        let dup = result.clip
        #expect(dup.id != a.id)                                 // fresh id
        #expect(abs(dup.startBeat - 4) < 1e-9)                  // flush after [0,4] → 4
        #expect(abs(dup.lengthBeats - 4) < 1e-9)
        // Value-copied fields.
        #expect(dup.gainDb == source.gainDb)
        #expect(dup.fadeInBeats == source.fadeInBeats)
        #expect(dup.fadeOutBeats == source.fadeOutBeats)
        #expect(dup.fadeInCurve == source.fadeInCurve)
        #expect(dup.audioFileURL == source.audioFileURL)
        #expect(dup.takeGroupID == nil)
        #expect(store.tracks[0].clips.count == 2)
        #expect(noOverlaps(store, track.id))

        _ = try store.undo()
        #expect(store.tracks[0].clips.count == 1)               // duplicate gone
    }

    @Test("duplicate to an explicit beat honours toStartBeat")
    func duplicateToBeat() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let a = try store.importAudio(url: url, toTrack: track.id)  // [0,4]
        let result = try store.duplicateClip(clipId: a.id, toStartBeat: 10)
        #expect(abs(result.clip.startBeat - 10) < 1e-9)
    }

    @Test("cross-track MIDI duplicate lands on another instrument track")
    func duplicateCrossTrack() throws {
        let store = ProjectStore()
        let src = store.addTrack(kind: .instrument)
        let dst = store.addTrack(kind: .instrument)
        let note = MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2)
        let clip = try store.addMIDIClip(toTrack: src.id, atBeat: 0, lengthBeats: 4, notes: [note])

        let result = try store.duplicateClip(clipId: clip.id, toStartBeat: 8, toTrackId: dst.id)
        // Lands on dst, source untouched.
        #expect(store.tracks.first { $0.id == dst.id }!.clips.count == 1)
        #expect(store.tracks.first { $0.id == src.id }!.clips.count == 1)
        #expect(result.clip.notes?.count == 1)                  // notes copied
        #expect(abs(result.clip.startBeat - 8) < 1e-9)
    }

    @Test("cross-track duplicate type-checks by content")
    func duplicateTypeMismatch() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let audioTrack = store.addTrack(kind: .audio)
        let instTrack = store.addTrack(kind: .instrument)
        let audioClip = try store.importAudio(url: url, toTrack: audioTrack.id)
        let midiClip = try store.addMIDIClip(toTrack: instTrack.id, atBeat: 0, lengthBeats: 4)

        // Audio clip onto an instrument track → trackKindUnsupported.
        let audioErr = projectError {
            _ = try store.duplicateClip(clipId: audioClip.id, toTrackId: instTrack.id)
        }
        #expect(audioErr?.errorDescription?.contains("only audio tracks accept audio clips") == true)
        // MIDI clip onto an audio track → midiClipsRequireInstrumentTrack.
        let midiErr = projectError {
            _ = try store.duplicateClip(clipId: midiClip.id, toTrackId: audioTrack.id)
        }
        #expect(midiErr?.errorDescription?.contains("only instrument tracks accept MIDI clips") == true)
    }

    @Test("duplicate onto an occupied region trims the resident — no silent overlap")
    func duplicateIntoOverlap() throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        let track = store.addTrack(kind: .audio)
        let a = try store.importAudio(url: url, toTrack: track.id)  // [0,4]
        let b = try store.importAudio(url: url, toTrack: track.id)  // [4,8]
        // Duplicate A onto B's tail: land at 5 → active [5,9] covers only B's
        // tail [5,8] (the source A at [0,4] sits clear of the window).
        let result = try store.duplicateClip(clipId: a.id, toStartBeat: 5)
        #expect(result.trimmedClipIDs == [b.id])
        #expect(result.removedClipIDs.isEmpty)
        #expect(noOverlaps(store, track.id))                   // Δ0 — no doubling
        let trimmedB = store.tracks[0].clips.first { $0.id == b.id }!
        #expect(abs(trimmedB.startBeat - 4) < 1e-9)            // head kept
        #expect(abs(trimmedB.lengthBeats - 1) < 1e-9)         // tail trimmed to 5
    }

    @Test("duplicate of a comp member is refused")
    func duplicateCompMemberRefused() throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .instrument)
        // Inject a take group + its materialized comp member directly (the store
        // forbids ordinary overlapping clips, so a group is only reachable via
        // recording or direct construction).
        let groupID = UUID()
        let lane = TakeLane(name: "Take 1", clip: Clip(name: "t", startBeat: 0, lengthBeats: 4, notes: []))
        let member = Clip(name: "member", startBeat: 0, lengthBeats: 4, notes: [], takeGroupID: groupID)
        store.tracks[0].takeGroups = [TakeGroup(id: groupID, name: "Comp", lanes: [lane])]
        store.tracks[0].clips = [member]
        let err = projectError { _ = try store.duplicateClip(clipId: member.id) }
        #expect(err != nil)   // clipInTakeGroup
    }

    // MARK: - insertBars (multi-segment tempo + meter)

    /// A store with a tempo map [0:120, 20:90] and meter map
    /// [0:4/4, 8:6/8, 20:4/4], three instrument tracks holding one clip each
    /// (before / after / straddling the beat-14 insertion point), a loop, and
    /// two markers. Returns the store + the three clip ids + straddle clip id.
    private func multiSegmentScene() throws
        -> (store: ProjectStore, before: UUID, after: UUID, straddle: UUID) {
        let store = ProjectStore()
        let tA = store.addTrack(kind: .instrument)
        let tB = store.addTrack(kind: .instrument)
        let tC = store.addTrack(kind: .instrument)
        let before = try store.addMIDIClip(toTrack: tA.id, atBeat: 4, lengthBeats: 4)    // [4,8)
        let after = try store.addMIDIClip(toTrack: tB.id, atBeat: 16, lengthBeats: 4)    // [16,20)
        let straddle = try store.addMIDIClip(toTrack: tC.id, atBeat: 12, lengthBeats: 6) // [12,18)
        try store.setLoop(enabled: true, startBeat: 16, endBeat: 20)
        _ = store.addMarker(name: "Before", beat: 4)
        _ = store.addMarker(name: "After", beat: 18)
        let tempo = try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 20, bpm: 90)])
        let meter = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 8, beatsPerBar: 6, beatUnit: 8),
            .init(startBeat: 20, beatsPerBar: 4, beatUnit: 4),
        ])
        try store.setTempoMap(tempo, meterMap: meter)
        return (store, before.id, after.id, straddle.id)
    }

    @Test("insertBars in a 6/8 region inserts 6-beat bars; content + maps shift by the integral")
    func insertBarsMultiSegment() throws {
        let (store, beforeID, afterID, straddleID) = try multiSegmentScene()
        let undoBefore = store.journal.undoStack.count

        // Insert 2 bars at bar 4 (1-based) → 0-based bar 3 → pivot beat 14, in the
        // 6/8 region → bpb 6 → 12 beats inserted.
        let result = try store.insertBars(atBar: 4, count: 2)
        #expect(result.beatsPerBar == 6)                        // 6/8 → 6-beat bars
        #expect(abs(result.atBeat - 14) < 1e-9)
        #expect(abs(result.insertedBeats - 12) < 1e-9)          // 2 × 6
        #expect(store.journal.undoStack.count == undoBefore + 1) // ONE undo

        func clip(_ id: UUID) -> Clip { store.tracks.flatMap(\.clips).first { $0.id == id }! }
        // Before the pivot → unchanged.
        #expect(abs(clip(beforeID).startBeat - 4) < 1e-9)
        // After the pivot → shifted +12.
        #expect(abs(clip(afterID).startBeat - 28) < 1e-9)
        // Straddling clip split: head [12,14) keeps the id; a fresh tail lands at 26.
        let head = clip(straddleID)
        #expect(abs(head.startBeat - 12) < 1e-9)
        #expect(abs(head.lengthBeats - 2) < 1e-9)
        let straddleTrackClips = store.tracks.first { $0.clips.contains { $0.id == straddleID } }!.clips
        #expect(straddleTrackClips.count == 2)
        let tail = straddleTrackClips.first { $0.id != straddleID }!
        #expect(abs(tail.startBeat - 26) < 1e-9)                // [14,18)+12
        #expect(abs(tail.lengthBeats - 4) < 1e-9)

        // Markers: 4 unchanged, 18 → 30.
        #expect(store.markers.map(\.beat).sorted() == [4, 30])
        // Loop [16,20) → [28,32).
        #expect(abs(store.transport.loopStartBeat - 28) < 1e-9)
        #expect(abs(store.transport.loopEndBeat - 32) < 1e-9)
        // Tempo map: segment at 20 → 32.
        #expect(store.transport.tempoMap.segments.map(\.startBeat) == [0, 32])
        // Meter map: change at 20 → 32; change at 8 stays.
        #expect(store.transport.meterMap.changes.map(\.startBeat) == [0, 8, 32])
        #expect(store.transport.meterMap.beatsPerBar(atBeat: 10) == 6)
    }

    @Test("insertBars is ONE undo that restores clips, markers, loop, and BOTH maps")
    func insertBarsUndo() throws {
        let (store, _, afterID, _) = try multiSegmentScene()
        let tempoBefore = store.transport.tempoMap.segments
        let meterBefore = store.transport.meterMap.changes
        let markersBefore = store.markers.map(\.beat).sorted()

        _ = try store.insertBars(atBar: 4, count: 2)
        _ = try store.undo()

        func clip(_ id: UUID) -> Clip { store.tracks.flatMap(\.clips).first { $0.id == id }! }
        #expect(abs(clip(afterID).startBeat - 16) < 1e-9)       // back to [16,20)
        #expect(store.transport.tempoMap.segments == tempoBefore)
        #expect(store.transport.meterMap.changes == meterBefore)
        #expect(store.markers.map(\.beat).sorted() == markersBefore)
        #expect(abs(store.transport.loopStartBeat - 16) < 1e-9)
        #expect(abs(store.transport.loopEndBeat - 20) < 1e-9)
    }

    @Test("insertBars in a trivial 4/4 project inserts 4-beat bars, no map override")
    func insertBarsTrivial() throws {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        _ = try store.addMIDIClip(toTrack: track.id, atBeat: 8, lengthBeats: 4)  // [8,12)
        // Insert 1 bar at bar 2 → pivot beat 4, 4/4 → 4 beats.
        let result = try store.insertBars(atBar: 2, count: 1)
        #expect(result.beatsPerBar == 4)
        #expect(abs(result.insertedBeats - 4) < 1e-9)
        #expect(abs(store.tracks[0].clips[0].startBeat - 12) < 1e-9)  // [8,12) → [12,16)
        #expect(store.transport.tempoMapOverride == nil)              // stays trivial
        #expect(store.transport.meterMapOverride == nil)
    }

    // MARK: - insertBars guards

    @Test("insertBars is refused across a take group")
    func insertBarsTakeGroupRefused() throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .instrument)
        let lane = TakeLane(name: "Take 1", clip: Clip(name: "t", startBeat: 0, lengthBeats: 4, notes: []))
        store.tracks[0].takeGroups = [TakeGroup(name: "Comp", lanes: [lane])]  // range 0…4
        let err = projectError { _ = try store.insertBars(atBar: 1, count: 2) }
        #expect(err?.errorDescription?.contains("flatten it first (take.flatten)") == true)
    }

    @Test("insertBars is refused while recording")
    func insertBarsRecordingRefused() throws {
        let engine = FakeRecordingEngine()
        engine.recordPermission = .granted
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        _ = try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        let err = projectError { _ = try store.insertBars(atBar: 2, count: 1) }
        #expect(err?.errorDescription == "cannot insert bars while recording — stop first")
        store.stop()
    }

    @Test("insertBars validates atBar and count")
    func insertBarsValidation() throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .instrument)
        #expect(projectError { _ = try store.insertBars(atBar: 0, count: 1) } != nil)
        #expect(projectError { _ = try store.insertBars(atBar: 1, count: 0) } != nil)
    }

    // MARK: - deleteBars (straddle policies)

    @Test("deleteBars removes in-range clips, shifts later clips, closes straddles")
    func deleteBarsStraddles() throws {
        let store = ProjectStore()
        let tL = store.addTrack(kind: .instrument)   // head-straddle
        let tR = store.addTrack(kind: .instrument)   // right-straddle
        let tM = store.addTrack(kind: .instrument)   // both-straddle
        let tX = store.addTrack(kind: .instrument)   // before + after
        let l = try store.addMIDIClip(toTrack: tL.id, atBeat: 2, lengthBeats: 4)   // [2,6)
        let r = try store.addMIDIClip(toTrack: tR.id, atBeat: 10, lengthBeats: 4)  // [10,14)
        let m = try store.addMIDIClip(toTrack: tM.id, atBeat: 2, lengthBeats: 12)  // [2,14)
        let bfr = try store.addMIDIClip(toTrack: tX.id, atBeat: 0, lengthBeats: 2) // [0,2)
        let aft = try store.addMIDIClip(toTrack: tX.id, atBeat: 14, lengthBeats: 4) // [14,18)

        // Delete bars 2-3 (1-based fromBar 2, count 2) → [4,12), delta 8.
        let undoBefore = store.journal.undoStack.count
        let result = try store.deleteBars(fromBar: 2, count: 2)
        #expect(store.journal.undoStack.count == undoBefore + 1)  // ONE undo
        #expect(abs(result.fromBeat - 4) < 1e-9)
        #expect(abs(result.deletedBeats - 8) < 1e-9)

        func clip(_ id: UUID) -> Clip? { store.tracks.flatMap(\.clips).first { $0.id == id } }
        // Left-straddle [2,6): tail trimmed off at 4 → [2,4), keeps id.
        let lc = try #require(clip(l.id))
        #expect(abs(lc.startBeat - 2) < 1e-9)
        #expect(abs(lc.lengthBeats - 2) < 1e-9)
        // Right-straddle [10,14): head trimmed, tail [12,14) pulled left → [4,6), keeps id.
        let rc = try #require(clip(r.id))
        #expect(abs(rc.startBeat - 4) < 1e-9)
        #expect(abs(rc.lengthBeats - 2) < 1e-9)
        // Both-straddle [2,14): head [2,4) keeps id; a fresh tail lands at 4 (len 2).
        let mc = try #require(clip(m.id))
        #expect(abs(mc.startBeat - 2) < 1e-9)
        #expect(abs(mc.lengthBeats - 2) < 1e-9)
        let mTrack = store.tracks.first { $0.id == tM.id }!
        #expect(mTrack.clips.count == 2)                          // split into two
        let mTail = mTrack.clips.first { $0.id != m.id }!
        #expect(abs(mTail.startBeat - 4) < 1e-9)
        #expect(abs(mTail.lengthBeats - 2) < 1e-9)
        // before [0,2) unchanged; after [14,18) → [6,10).
        #expect(abs(try #require(clip(bfr.id)).startBeat - 0) < 1e-9)
        #expect(abs(try #require(clip(aft.id)).startBeat - 6) < 1e-9)
    }

    @Test("deleteBars removes in-range markers and shifts the rest")
    func deleteBarsMarkers() throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .instrument)
        _ = store.addMarker(name: "Keep", beat: 2)     // before → unchanged
        let inside = store.addMarker(name: "Gone", beat: 6)   // in [4,12) → removed
        _ = store.addMarker(name: "Shift", beat: 14)   // after → 6
        let result = try store.deleteBars(fromBar: 2, count: 2)  // [4,12), delta 8
        #expect(result.removedMarkerIDs == [inside.id])
        #expect(store.markers.map(\.beat).sorted() == [2, 6])
    }

    @Test("deleteBars removes tempo changes inside the range and pulls later ones left")
    func deleteBarsTempoRemoval() throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .instrument)
        let tempo = try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120),
            .init(startBeat: 6, bpm: 90),    // inside [4,16) → removed
            .init(startBeat: 20, bpm: 100),  // after → 20-12 = 8
        ])
        try store.setTempoMap(tempo)
        // Delete bars 2-4 (fromBar 2, count 3) → [4,16), delta 12.
        _ = try store.deleteBars(fromBar: 2, count: 3)
        #expect(store.transport.tempoMap.segments.map(\.startBeat) == [0, 8])
        #expect(store.transport.tempoMap.bpm(atBeat: 8) == 100)
    }

    @Test("deleteBars clamps a straddling loop and disables a swallowed one")
    func deleteBarsLoop() throws {
        // Straddling loop clamps.
        let s1 = ProjectStore()
        _ = s1.addTrack(kind: .instrument)
        try s1.setLoop(enabled: true, startBeat: 3, endBeat: 13)
        _ = try s1.deleteBars(fromBar: 2, count: 2)   // [4,12), delta 8
        #expect(abs(s1.transport.loopStartBeat - 3) < 1e-9)
        #expect(abs(s1.transport.loopEndBeat - 5) < 1e-9)  // 13 → 5
        #expect(s1.transport.isLoopEnabled)                // still valid, stays on

        // Loop fully inside the deleted range → disabled.
        let s2 = ProjectStore()
        _ = s2.addTrack(kind: .instrument)
        try s2.setLoop(enabled: true, startBeat: 5, endBeat: 11)  // inside [4,12)
        _ = try s2.deleteBars(fromBar: 2, count: 2)
        #expect(!s2.transport.isLoopEnabled)               // swallowed → off
    }

    // MARK: - deleteBars guards

    @Test("deleteBars refuses a meter-boundary-crossing delete that can't splice")
    func deleteBarsMeterBoundaryRefused() throws {
        let store = ProjectStore()
        _ = store.addTrack(kind: .instrument)
        let meter = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 20, beatsPerBar: 3, beatUnit: 4),  // bar 5
            .init(startBeat: 26, beatsPerBar: 4, beatUnit: 4),  // 2 bars of 3/4 later
        ])
        try store.setTempoMap(TempoMap(constantBPM: 120), meterMap: meter)
        // Delete bars 3-6 → [8,23), delta 15 — crosses the 3/4 region; the 4/4
        // change at 26 would land at 11, off the 4/4 barline → refuse.
        let err = projectError { _ = try store.deleteBars(fromBar: 3, count: 4) }
        #expect(err?.errorDescription ==
            "deleting these bars would leave a meter change off its barline — delete within a single time-signature region, or remove the meter change first")
        // Nothing mutated (guards outside the edit body).
        #expect(store.transport.meterMap.changes.map(\.startBeat) == [0, 20, 26])
    }

    @Test("deleteBars is refused while recording")
    func deleteBarsRecordingRefused() throws {
        let engine = FakeRecordingEngine()
        engine.recordPermission = .granted
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(kind: .audio)
        _ = try store.setTrackArm(id: track.id, armed: true)
        try store.record()
        let err = projectError { _ = try store.deleteBars(fromBar: 2, count: 1) }
        #expect(err?.errorDescription == "cannot delete bars while recording — stop first")
        store.stop()
    }
}
