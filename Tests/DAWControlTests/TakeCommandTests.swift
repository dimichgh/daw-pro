import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M5 (iii-b) take/comp commands: the 7
/// `take.*` verbs (group/setComp/select/removeLane/flatten/move/setCrossfade),
/// param validation, store rejections surfacing verbatim, and
/// `project.snapshot` carrying `takeGroups`/`takeGroupID`. Reuses `FakeMedia`
/// from ControlTests.swift (same target). Recording auto-group has its own
/// headless coverage in Tests/DAWCoreTests (finishTake needs a live engine to
/// exercise end-to-end; see ProjectStoreTakesAutoGroupTests).
@MainActor
@Suite("Take commands — control protocol (M5 iii-b)")
struct TakeCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()  // 2.0 s → 4 beats @ 120 bpm (the default tempo)
        return (CommandRouter(store: store), store)
    }

    /// Adds an audio track plus three OVERLAPPING 4-beat clips at 0/2/4 beats
    /// (0–4, 2–6, 4–8 — a connected overlap chain), returning the wire ids.
    private func addOverlappingClips(_ router: CommandRouter) async throws -> (trackID: String, clipIDs: [String]) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        var clipIDs: [String] = []
        for atBeat in [0.0, 2.0, 4.0] {
            let addClip = await router.handle(ControlRequest(
                id: "c", command: "clip.addAudio",
                params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav"),
                         "atBeat": .number(atBeat)]))
            clipIDs.append(try #require(addClip.result?["id"]?.stringValue))
        }
        return (trackID, clipIDs)
    }

    /// Forms a group from the three overlapping clips, returning the wire ids
    /// (trackID, groupID, laneIDs oldest-first).
    private func makeGroup(_ router: CommandRouter) async throws -> (trackID: String, groupID: String, laneIDs: [String]) {
        let (trackID, clipIDs) = try await addOverlappingClips(router)
        let group = await router.handle(ControlRequest(
            id: "g", command: "take.group",
            params: ["trackId": .string(trackID),
                     "clipIds": .array(clipIDs.map(JSONValue.string))]))
        #expect(group.ok)
        let laneIDs = try #require(group.result?["group"]?["lanes"]?.arrayValue?.map { $0["id"]?.stringValue })
            .compactMap { $0 }
        let groupID = try #require(group.result?["group"]?["id"]?.stringValue)
        return (trackID, groupID, laneIDs)
    }

    // MARK: - take.group

    @Test("take.group forms lanes oldest-first, newest-wins comp, and materializes members")
    func groupHappyPath() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipIDs) = try await addOverlappingClips(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.group",
            params: ["trackId": .string(trackID),
                     "clipIds": .array(clipIDs.map(JSONValue.string)), "name": .string("Vox Takes")]))
        #expect(response.ok)
        let group = try #require(response.result?["group"])
        #expect(group["name"]?.stringValue == "Vox Takes")
        let lanes = try #require(group["lanes"]?.arrayValue)
        #expect(lanes.count == 3)
        let comp = try #require(group["comp"]?.arrayValue)
        #expect(comp.count == 1)
        let newestLaneID = try #require(lanes.last?["id"]?.stringValue)
        #expect(comp[0]["laneId"]?.stringValue == newestLaneID)

        // Source clips are gone from the track; members carry the marker.
        #expect(store.tracks[0].clips.allSatisfy { $0.takeGroupID != nil })
        #expect(!store.tracks[0].clips.isEmpty)
    }

    @Test("take.group rejections: fewer than 2 clips, and an unknown clip id")
    func groupRejections() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipIDs) = try await addOverlappingClips(router)

        let tooFew = await router.handle(ControlRequest(
            id: "1", command: "take.group",
            params: ["trackId": .string(trackID), "clipIds": .array([.string(clipIDs[0])])]))
        #expect(!tooFew.ok)
        #expect(tooFew.error?.contains("at least 2") == true)

        let unknown = await router.handle(ControlRequest(
            id: "2", command: "take.group",
            params: ["trackId": .string(trackID),
                     "clipIds": .array([.string(clipIDs[0]), .string(UUID().uuidString)])]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)
    }

    // MARK: - clip edits reject comp members verbatim

    @Test("clip.trim on a take-group member surfaces clipInTakeGroup verbatim")
    func memberEditRejected() async throws {
        let (router, store) = makeRouter()
        let (trackID, groupID, _) = try await makeGroup(router)
        let memberID = try #require(store.tracks[0].clips.first?.id.uuidString)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.trim",
            params: ["trackId": .string(trackID), "clipId": .string(memberID),
                     "newStartBeat": .number(1), "newLengthBeats": .number(2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("belongs to take group") == true)
        #expect(response.error?.contains("take.flatten") == true)
        _ = groupID
    }

    // MARK: - take.setComp

    @Test("take.setComp replaces the comp wholesale and rebuilds members")
    func setCompHappyPath() async throws {
        let (router, store) = makeRouter()
        let (trackID, groupID, laneIDs) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.setComp",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "segments": .array([
                         .object(["laneId": .string(laneIDs[0]), "startBeat": .number(0), "endBeat": .number(3)]),
                         .object(["laneId": .string(laneIDs[1]), "startBeat": .number(3), "endBeat": .number(8)]),
                     ])]))
        #expect(response.ok)
        let comp = try #require(response.result?["group"]?["comp"]?.arrayValue)
        #expect(comp.count == 2)
        let clips = try #require(response.result?["clips"]?.arrayValue)
        #expect(clips.count == 2)
        #expect(store.tracks[0].clips.count == 2)
    }

    @Test("take.setComp rejections: unknown lane and inverted segment")
    func setCompRejections() async throws {
        let (router, _) = makeRouter()
        let (trackID, groupID, laneIDs) = try await makeGroup(router)

        let unknownLane = await router.handle(ControlRequest(
            id: "1", command: "take.setComp",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "segments": .array([
                         .object(["laneId": .string(UUID().uuidString), "startBeat": .number(0), "endBeat": .number(4)]),
                     ])]))
        #expect(!unknownLane.ok)
        #expect(unknownLane.error?.contains("unknown take") == true)

        let inverted = await router.handle(ControlRequest(
            id: "2", command: "take.setComp",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "segments": .array([
                         .object(["laneId": .string(laneIDs[0]), "startBeat": .number(4), "endBeat": .number(0)]),
                     ])]))
        #expect(!inverted.ok)
        #expect(inverted.error?.contains("end must be after") == true)
    }

    @Test("take.setComp surfaces a per-index error for a malformed segment")
    func setCompMalformedSegment() async throws {
        let (router, _) = makeRouter()
        let (trackID, groupID, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.setComp",
            params: ["trackId": .string(trackID), "groupId": .string(groupID),
                     "segments": .array([.object(["startBeat": .number(0), "endBeat": .number(4)])])]))
        #expect(!response.ok)
        #expect(response.error?.contains("segments[0]") == true)
    }

    // MARK: - take.select

    @Test("take.select swaps the comp to one full-range segment on the chosen lane")
    func selectHappyPath() async throws {
        let (router, store) = makeRouter()
        let (trackID, groupID, laneIDs) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.select",
            params: ["trackId": .string(trackID), "groupId": .string(groupID), "laneId": .string(laneIDs[0])]))
        #expect(response.ok)
        let comp = try #require(response.result?["group"]?["comp"]?.arrayValue)
        #expect(comp.count == 1)
        #expect(comp[0]["laneId"]?.stringValue == laneIDs[0])
        #expect(store.tracks[0].clips.count == 1)
    }

    @Test("take.select on an unknown lane surfaces laneNotFound verbatim")
    func selectUnknownLane() async throws {
        let (router, _) = makeRouter()
        let (trackID, groupID, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.select",
            params: ["trackId": .string(trackID), "groupId": .string(groupID), "laneId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no take (lane) with that id") == true)
    }

    // MARK: - take.removeLane

    @Test("take.removeLane deletes an unused lane")
    func removeLaneHappyPath() async throws {
        let (router, _) = makeRouter()
        let (trackID, groupID, laneIDs) = try await makeGroup(router)
        // Comp defaults to the newest (last) lane; lane 0 is unused.
        let response = await router.handle(ControlRequest(
            id: "1", command: "take.removeLane",
            params: ["trackId": .string(trackID), "groupId": .string(groupID), "laneId": .string(laneIDs[0])]))
        #expect(response.ok)
        let lanes = try #require(response.result?["group"]?["lanes"]?.arrayValue)
        #expect(lanes.count == 2)
    }

    @Test("take.removeLane rejects a lane the comp still references")
    func removeLaneInUse() async throws {
        let (router, _) = makeRouter()
        let (trackID, groupID, laneIDs) = try await makeGroup(router)
        // Comp defaults to the newest (last) lane — referenced, so removing it fails.
        let response = await router.handle(ControlRequest(
            id: "1", command: "take.removeLane",
            params: ["trackId": .string(trackID), "groupId": .string(groupID), "laneId": .string(laneIDs.last!)]))
        #expect(!response.ok)
        #expect(response.error?.contains("referenced by the comp") == true)
    }

    // MARK: - take.flatten

    @Test("take.flatten dissolves the group and restores editability")
    func flattenHappyPath() async throws {
        let (router, store) = makeRouter()
        let (trackID, groupID, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.flatten",
            params: ["trackId": .string(trackID), "groupId": .string(groupID)]))
        #expect(response.ok)
        let clips = try #require(response.result?["clips"]?.arrayValue)
        #expect(clips.count == 1)
        #expect(clips[0]["takeGroupID"] == nil)
        #expect(store.tracks[0].takeGroups.isEmpty)

        // Now editable again.
        let memberID = try #require(store.tracks[0].clips.first?.id.uuidString)
        let trim = await router.handle(ControlRequest(
            id: "2", command: "clip.trim",
            params: ["trackId": .string(trackID), "clipId": .string(memberID),
                     "newStartBeat": .number(1), "newLengthBeats": .number(2)]))
        #expect(trim.ok)
    }

    @Test("take.flatten on an unknown group surfaces takeGroupNotFound verbatim")
    func flattenUnknownGroup() async throws {
        let (router, _) = makeRouter()
        let (trackID, _, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.flatten",
            params: ["trackId": .string(trackID), "groupId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no take group with that id") == true)
    }

    // MARK: - take.move

    @Test("take.move shifts lanes, comp, and members together")
    func moveHappyPath() async throws {
        let (router, store) = makeRouter()
        let (trackID, groupID, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.move",
            params: ["trackId": .string(trackID), "groupId": .string(groupID), "toStartBeat": .number(10)]))
        #expect(response.ok)
        let firstLane = try #require(response.result?["group"]?["lanes"]?.arrayValue?.first)
        #expect(firstLane["clip"]?["startBeat"]?.doubleValue == 10)
        let clips = try #require(response.result?["clips"]?.arrayValue)
        #expect(clips.allSatisfy { ($0["startBeat"]?.doubleValue ?? -1) >= 10 })
        #expect(store.tracks[0].clips.allSatisfy { $0.startBeat >= 10 })
    }

    @Test("take.move on an unknown track surfaces trackNotFound verbatim")
    func moveUnknownTrack() async throws {
        let (router, _) = makeRouter()
        let (_, groupID, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.move",
            params: ["trackId": .string(UUID().uuidString), "groupId": .string(groupID), "toStartBeat": .number(10)]))
        #expect(!response.ok)
        #expect(response.error?.contains("No track with id") == true)
    }

    // MARK: - take.setCrossfade

    @Test("take.setCrossfade clamps to 0...0.2 and rebuilds members")
    func setCrossfadeHappyPath() async throws {
        let (router, store) = makeRouter()
        let (trackID, groupID, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.setCrossfade",
            params: ["trackId": .string(trackID), "groupId": .string(groupID), "seconds": .number(5)]))
        #expect(response.ok)
        #expect(response.result?["group"]?["crossfadeSeconds"]?.doubleValue == 0.2)
        #expect(response.result?["clips"]?.arrayValue != nil)
        _ = store
    }

    @Test("take.setCrossfade on an unknown group surfaces takeGroupNotFound verbatim")
    func setCrossfadeUnknownGroup() async throws {
        let (router, _) = makeRouter()
        let (trackID, _, _) = try await makeGroup(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "take.setCrossfade",
            params: ["trackId": .string(trackID), "groupId": .string(UUID().uuidString), "seconds": .number(0.02)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no take group with that id") == true)
    }

    // MARK: - snapshot carries takeGroups / takeGroupID

    @Test("project.snapshot carries track.takeGroups and clip.takeGroupID")
    func snapshotCarriesTakeFields() async throws {
        let (router, _) = makeRouter()
        let (trackID, groupID, laneIDs) = try await makeGroup(router)

        let snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let track = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID }))
        let groups = try #require(track["takeGroups"]?.arrayValue)
        #expect(groups.count == 1)
        #expect(groups[0]["id"]?.stringValue == groupID)
        #expect(groups[0]["lanes"]?.arrayValue?.map { $0["id"]?.stringValue } == laneIDs)

        let clips = try #require(track["clips"]?.arrayValue)
        #expect(!clips.isEmpty)
        #expect(clips.allSatisfy { $0["takeGroupID"]?.stringValue == groupID })
    }

    // MARK: - allCommands

    @Test("allCommands advertises the seven take.* commands")
    func takeCommandsAdvertised() {
        for command in ["take.group", "take.setComp", "take.select", "take.removeLane",
                         "take.flatten", "take.move", "take.setCrossfade"] {
            #expect(CommandRouter.allCommands.contains(command))
        }
    }
}
