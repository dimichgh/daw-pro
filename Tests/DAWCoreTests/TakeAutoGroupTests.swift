import Foundation
import Testing
@testable import DAWCore

/// Headless coverage for the M5 (iii-b) recording auto-group hook (spec §3):
/// `finishTake`'s audio-side auto-grouping against whatever already sits on
/// the track when a take lands. Reuses `FakeRecordingEngine` (audio takes,
/// from RecordingStoreTests.swift) and `FakeTakeEngine` (MIDI takes, from
/// MIDIRecordingStoreTests.swift) — both `internal` types in this same test
/// target. `record()`/`finishTake()` exercise the REAL `ProjectStore`
/// `finishTake` path headlessly (no live engine, no microphone needed), so
/// this doubles as the "store-level hook with a headless test that simulates
/// the finish" fallback the task called for if a fully live path weren't
/// reachable — here the store path IS reachable, so it's exercised directly.
@MainActor
@Suite("Recording auto-group — ProjectStore (M5 iii-b, spec §3)")
struct TakeAutoGroupTests {
    private func audioTake(_ url: URL, durationSeconds: Double = 2) -> RecordingResult {
        RecordingResult(
            fileURL: url,
            info: AudioFileInfo(durationSeconds: durationSeconds, sampleRate: 48_000, channelCount: 1),
            startOffsetSeconds: 0
        )
    }

    /// Records one audio take (record → stop → finish) from the CURRENT
    /// playhead via `FakeRecordingEngine`.
    private func recordAudioTake(_ store: ProjectStore, _ engine: FakeRecordingEngine) throws {
        try store.record()
        store.stop()
        let url = try #require(engine.startRecordingURLs.last)
        engine.finishTake(.success(audioTake(url)))
    }

    // MARK: - Case 3: disjoint → plain clip (unaffected, today's behavior)

    @Test("disjoint takes (no overlap) land as ordinary clips — unaffected by auto-group")
    func disjointTakesStayPlain() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        try recordAudioTake(store, engine)  // lands at beat 0, length 4 (2 s @ 120 bpm)
        try store.seek(toBeats: 8)          // well past the first take's end
        try recordAudioTake(store, engine)

        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.count == 2)
        #expect(store.tracks[0].clips.map(\.startBeat) == [0, 8])
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID == nil })
    }

    // MARK: - Case 2: overlaps a plain clip → groupTakes semantics

    @Test("overlapping a plain clip groups them (newest wins), one undo step covers the whole take")
    func overlapFormsGroupFromPlainClips() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        try recordAudioTake(store, engine)  // Take 1 lands as a plain clip at beat 0
        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.count == 1)

        try recordAudioTake(store, engine)  // Take 2, same range → groups with Take 1
        #expect(store.undoLabel == "Record Take 2")  // ONE undo step for the whole group

        let groups = store.tracks[0].takeGroups
        #expect(groups.count == 1)
        #expect(groups[0].lanes.map(\.name) == ["Gtr Take 1", "Gtr Take 2"])
        #expect(groups[0].comp.count == 1)
        #expect(store.tracks[0].clips.count == 1)  // comp = newest lane, full range
        #expect(store.tracks[0].clips[0].name == "Gtr Take 2")
        #expect(store.tracks[0].clips[0].takeGroupID == groups[0].id)

        // One undo step restores the pre-group (plain-clip) state entirely.
        try store.undo()
        #expect(store.tracks[0].takeGroups.isEmpty)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].name == "Gtr Take 1")
    }

    // MARK: - Case 1: overlaps an EXISTING group's range → append a lane

    @Test("overlapping an EXISTING group's range appends a lane; newest still wins")
    func overlapAppendsLaneToExistingGroup() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Gtr", kind: .audio)
        try store.setTrackArm(id: track.id, armed: true)

        try recordAudioTake(store, engine)  // Take 1 (plain)
        try recordAudioTake(store, engine)  // Take 2 → groups with Take 1 (2 lanes)
        #expect(store.tracks[0].takeGroups.count == 1)
        #expect(store.tracks[0].takeGroups[0].lanes.count == 2)

        try recordAudioTake(store, engine)  // Take 3, same range → appends a THIRD lane
        #expect(store.undoLabel == "Record Take 3")  // still ONE step

        let groups = store.tracks[0].takeGroups
        #expect(groups.count == 1)  // still ONE group, never a second
        #expect(groups[0].lanes.map(\.name) == ["Gtr Take 1", "Gtr Take 2", "Gtr Take 3"])
        #expect(groups[0].comp.count == 1)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].name == "Gtr Take 3")  // newest still wins

        // One undo step peels back to the 2-lane group.
        try store.undo()
        #expect(store.tracks[0].takeGroups.count == 1)
        #expect(store.tracks[0].takeGroups[0].lanes.count == 2)
        #expect(store.tracks[0].clips[0].name == "Gtr Take 2")
    }

    // MARK: - Multi-track: only OVERLAPPING tracks group; others stay plain

    @Test("auto-group is per-track: an unarmed/disjoint track's clip is untouched by a sibling's grouping")
    func autoGroupIsPerTrack() throws {
        let engine = FakeRecordingEngine()
        let store = ProjectStore()
        store.engine = engine
        let grouped = store.addTrack(name: "Lead", kind: .audio)
        let plain = store.addTrack(name: "Rhythm", kind: .audio)
        try store.setTrackArm(id: grouped.id, armed: true)
        try store.setTrackArm(id: plain.id, armed: true)

        try recordAudioTake(store, engine)  // both tracks land a plain take-1 clip at beat 0

        // Disarm "plain" so only "grouped" records the overlapping take 2.
        try store.setTrackArm(id: plain.id, armed: false)
        try recordAudioTake(store, engine)

        #expect(store.tracks[0].takeGroups.count == 1)   // Lead grouped
        #expect(store.tracks[1].takeGroups.isEmpty)      // Rhythm untouched
        #expect(store.tracks[1].clips.count == 1)
        #expect(store.tracks[1].clips[0].name == "Rhythm Take 1")
    }

    // MARK: - MIDI is unaffected in v0

    @Test("MIDI re-recording over the same region does NOT auto-group (v0 scope, audio-only)")
    func midiUnaffected() throws {
        let engine = FakeTakeEngine()
        let store = ProjectStore()
        store.engine = engine
        let track = store.addTrack(name: "Keys", kind: .instrument)
        try store.setTrackArm(id: track.id, armed: true)

        let notes = [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)]
        try store.record()
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: nil, midi: MIDIRecordingResult(notes: notes, lengthBeats: 4))))

        try store.record()  // same range again
        store.stop()
        engine.finishTake(.success(TakeResult(
            audio: nil, midi: MIDIRecordingResult(notes: notes, lengthBeats: 4))))

        #expect(store.tracks[0].takeGroups.isEmpty)  // explicit take.group still available
        #expect(store.tracks[0].clips.count == 2)
        #expect(store.tracks[0].clips.map(\.name) == ["Keys Take 1", "Keys Take 2"])
    }
}
