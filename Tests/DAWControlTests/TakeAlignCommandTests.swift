import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M6 (v-d) `take.autoAlign`: field-named param
/// validation (ids, searchWindowMs range), the full wire round-trip against a
/// planted +80 ms lane offset (apply and dry-run), and the store rejections
/// surfacing verbatim. Reuses `FakeMedia` (ControlTests.swift) and
/// `FakeTransientEngine` (ClipTransientCommandTests.swift — one shared onset
/// stub works because the LANES sit 0.16 beats apart, so identical
/// source-file onsets land 80 ms apart on the timeline).
@MainActor
@Suite("Take auto-align — control protocol (M6 v-d)")
struct TakeAlignCommandTests {

    private func makeRouter(engine: FakeTransientEngine? = nil, tracks: [Track] = [])
        -> (CommandRouter, ProjectStore) {
        let store = tracks.isEmpty ? ProjectStore() : ProjectStore(tracks: tracks)
        store.media = FakeMedia()  // 2.0 s → 4 beats @ 120 bpm (the default tempo)
        if let engine { store.engine = engine }
        return (CommandRouter(store: store), store)
    }

    /// A pre-seeded audio track with two OVERLAPPING 4-beat clips at beats 0 and
    /// 0.16 (the candidate 80 ms late @ 120 BPM; lane 0 = reference at 0, lane 1
    /// = the late take). Post-m13-b no wire verb places overlapping ordinary
    /// clips (the no-silent-overlap invariant is now complete), so the fixture
    /// seeds the overlap it intends to group at the MODEL layer.
    private func offsetTrack() -> (track: Track, trackID: String, clipIDs: [String]) {
        let url = URL(fileURLWithPath: "/tmp/Loop.wav")
        let clips = [0.0, 0.16].map {
            Clip(name: "Loop", startBeat: $0, lengthBeats: 4, audioFileURL: url)
        }
        let track = Track(name: "Audio", kind: .audio, clips: clips)
        return (track, track.id.uuidString, clips.map { $0.id.uuidString })
    }

    /// Groups the two seeded overlapping clips, returning the wire ids.
    private func makeOffsetGroup(_ router: CommandRouter, trackID: String, clipIDs: [String]) async throws
        -> (groupID: String, laneIDs: [String]) {
        let group = await router.handle(ControlRequest(
            id: "g", command: "take.group",
            params: ["trackId": .string(trackID),
                     "clipIds": .array(clipIDs.map(JSONValue.string))]))
        #expect(group.ok)
        let groupID = try #require(group.result?["group"]?["id"]?.stringValue)
        let laneIDs = try #require(group.result?["group"]?["lanes"]?.arrayValue?
            .map { $0["id"]?.stringValue }).compactMap { $0 }
        return (groupID, laneIDs)
    }

    // MARK: - Round trip

    @Test("take.autoAlign recovers the planted 80 ms, moves the lane, and reports the wire shape")
    func roundTripApply() async throws {
        let engine = FakeTransientEngine()
        engine.stubMarkers = [0.5, 1.0, 1.5].map { TransientMarker(timeSeconds: $0, strength: 1) }
        let (track, trackID, clipIDs) = offsetTrack()
        let (router, store) = makeRouter(engine: engine, tracks: [track])
        let (groupID, laneIDs) = try await makeOffsetGroup(router, trackID: trackID, clipIDs: clipIDs)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.autoAlign",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "laneId": .string(laneIDs[1])]))
        #expect(response.ok, "\(response.error ?? "?")")
        // Response IS the report (wire contract).
        let offsetMs = try #require(response.result?["offsetMs"]?.doubleValue)
        let offsetBeats = try #require(response.result?["offsetBeats"]?.doubleValue)
        #expect(abs(offsetMs - 80.0) < 1e-6)
        #expect(abs(offsetBeats - 0.16) < 1e-9)
        #expect(response.result?["matchedOnsets"]?.doubleValue == 3)
        #expect(response.result?["referenceOnsets"]?.doubleValue == 3)
        #expect(response.result?["candidateOnsets"]?.doubleValue == 3)
        #expect(response.result?["confidence"]?.doubleValue == 1)
        #expect(response.result?["applied"]?.boolValue == true)

        // The lane moved by −offset (0.16 → ~0 beats); detection hit BOTH
        // lanes' files on the shared detector at the 0.5 default.
        let lane = try #require(store.tracks[0].takeGroups[0].lanes.last)
        #expect(abs(lane.clip.startBeat) < 1e-9)
        #expect(engine.detectCalls == 2)
        #expect(engine.lastSensitivity == 0.5)
    }

    @Test("apply: false measures without mutating")
    func roundTripDryRun() async throws {
        let engine = FakeTransientEngine()
        engine.stubMarkers = [0.5, 1.0, 1.5].map { TransientMarker(timeSeconds: $0, strength: 1) }
        let (track, trackID, clipIDs) = offsetTrack()
        let (router, store) = makeRouter(engine: engine, tracks: [track])
        let (groupID, laneIDs) = try await makeOffsetGroup(router, trackID: trackID, clipIDs: clipIDs)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.autoAlign",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "laneId": .string(laneIDs[1]), "apply": .bool(false)]))
        #expect(response.ok, "\(response.error ?? "?")")
        #expect(response.result?["applied"]?.boolValue == false)
        let offsetMs = try #require(response.result?["offsetMs"]?.doubleValue)
        #expect(abs(offsetMs - 80.0) < 1e-6)
        // Nothing moved.
        let lane = try #require(store.tracks[0].takeGroups[0].lanes.last)
        #expect(abs(lane.clip.startBeat - 0.16) < 1e-9)
    }

    // MARK: - Param validation (field-named)

    @Test("missing ids are field-named errors")
    func missingIDs() async throws {
        let (router, _) = makeRouter()
        let noTrack = await router.handle(ControlRequest(
            id: "1", command: "take.autoAlign", params: [:]))
        #expect(!noTrack.ok)
        #expect(noTrack.error == "missing or invalid required param 'trackId'")

        let noGroup = await router.handle(ControlRequest(
            id: "2", command: "take.autoAlign",
            params: ["trackId": .string(UUID().uuidString)]))
        #expect(!noGroup.ok)
        #expect(noGroup.error == "missing or invalid required param 'groupId'")

        let noLane = await router.handle(ControlRequest(
            id: "3", command: "take.autoAlign",
            params: ["trackId": .string(UUID().uuidString),
                     "groupId": .string(UUID().uuidString)]))
        #expect(!noLane.ok)
        #expect(noLane.error == "missing or invalid required param 'laneId'")
    }

    @Test("searchWindowMs outside 10...500 is a field-named error")
    func windowRange() async throws {
        let (router, _) = makeRouter()
        for bad in [5.0, 501.0, 0.0, -20.0] {
            let response = await router.handle(ControlRequest(
                id: "1", command: "take.autoAlign",
                params: ["trackId": .string(UUID().uuidString),
                         "groupId": .string(UUID().uuidString),
                         "laneId": .string(UUID().uuidString),
                         "searchWindowMs": .number(bad)]))
            #expect(!response.ok)
            #expect(response.error
                    == "'searchWindowMs' must be between 10 and 500 (milliseconds of ± search around the take's current position)")
        }
        // Boundary values pass validation (and then fail later on the unknown
        // track — proving the range gate, not the store, rejected above).
        for good in [10.0, 500.0] {
            let response = await router.handle(ControlRequest(
                id: "2", command: "take.autoAlign",
                params: ["trackId": .string(UUID().uuidString),
                         "groupId": .string(UUID().uuidString),
                         "laneId": .string(UUID().uuidString),
                         "searchWindowMs": .number(good)]))
            #expect(!response.ok)
            #expect(response.error?.contains("No track with id") == true)
        }
    }

    // MARK: - Store rejections surface verbatim

    @Test("aligning the reference lane against itself surfaces invalidComp")
    func selfAlign() async throws {
        let engine = FakeTransientEngine()
        let (track, trackID, clipIDs) = offsetTrack()
        let (router, _) = makeRouter(engine: engine, tracks: [track])
        let (groupID, laneIDs) = try await makeOffsetGroup(router, trackID: trackID, clipIDs: clipIDs)
        let response = await router.handle(ControlRequest(
            id: "1", command: "take.autoAlign",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "laneId": .string(laneIDs[0])]))
        #expect(!response.ok)
        #expect(response.error?.contains("first lane") == true)
        #expect(response.error?.contains("reference") == true)
    }

    @Test("inconclusive alignment surfaces alignmentInconclusive with counts and advice")
    func inconclusive() async throws {
        let engine = FakeTransientEngine()   // no onsets stubbed → 0 + 0
        let (track, trackID, clipIDs) = offsetTrack()
        let (router, _) = makeRouter(engine: engine, tracks: [track])
        let (groupID, laneIDs) = try await makeOffsetGroup(router, trackID: trackID, clipIDs: clipIDs)
        let response = await router.handle(ControlRequest(
            id: "1", command: "take.autoAlign",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "laneId": .string(laneIDs[1])]))
        #expect(!response.ok)
        #expect(response.error?.contains("reference lane has 0 onsets") == true)
        #expect(response.error?.contains("searchWindowMs") == true)
        #expect(response.error?.contains("take.move") == true)
    }

    @Test("no timeline headroom surfaces alignmentWouldCrossTimelineStart verbatim, unmutated")
    func noHeadroom() async throws {
        // Both lanes at beat 0; the candidate's onsets are planted 80 ms late
        // via the per-call stub queue (reference detected first) — so the
        // apply needs 0.16 beats of headroom the lane doesn't have.
        let engine = FakeTransientEngine()
        engine.stubMarkersQueue = [
            [0.5, 1.0, 1.5].map { TransientMarker(timeSeconds: $0, strength: 1) },
            [0.58, 1.08, 1.58].map { TransientMarker(timeSeconds: $0, strength: 1) },
        ]
        // Both lanes seeded at beat 0 (the overlap is directly modelled —
        // post-m13-b no wire verb places overlapping ordinary clips).
        let url = URL(fileURLWithPath: "/tmp/Loop.wav")
        let seedClips = [Clip(name: "Loop", startBeat: 0, lengthBeats: 4, audioFileURL: url),
                         Clip(name: "Loop", startBeat: 0, lengthBeats: 4, audioFileURL: url)]
        let track = Track(name: "Audio", kind: .audio, clips: seedClips)
        let (router, store) = makeRouter(engine: engine, tracks: [track])
        let trackID = track.id.uuidString
        let group = await router.handle(ControlRequest(
            id: "g", command: "take.group",
            params: ["trackId": .string(trackID),
                     "clipIds": .array(seedClips.map { JSONValue.string($0.id.uuidString) })]))
        let groupID = try #require(group.result?["group"]?["id"]?.stringValue)
        let laneIDs = try #require(group.result?["group"]?["lanes"]?.arrayValue?
            .map { $0["id"]?.stringValue }).compactMap { $0 }

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.autoAlign",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "laneId": .string(laneIDs[1])]))
        #expect(!response.ok)
        // Exact wire text (contract for the live-check script).
        #expect(response.error
                == "aligning this take means moving it 80.0 ms (0.1600 beats) earlier, but it "
                + "starts at beat 0.0000 — only 0.0 ms of headroom before the timeline start; "
                + "move the group to a later position first (take.move), then align again")
        // Nothing moved.
        #expect(store.tracks[0].takeGroups[0].lanes[1].clip.startBeat == 0)
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func headless() async throws {
        let (track, trackID, clipIDs) = offsetTrack()
        let (router, _) = makeRouter(tracks: [track])   // no engine
        let (groupID, laneIDs) = try await makeOffsetGroup(router, trackID: trackID, clipIDs: clipIDs)
        let response = await router.handle(ControlRequest(
            id: "1", command: "take.autoAlign",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "laneId": .string(laneIDs[1])]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    // MARK: - Surface

    @Test("allCommands advertises take.autoAlign")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("take.autoAlign"))
    }
}
