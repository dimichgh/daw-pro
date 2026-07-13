import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m15-c master volume automation: the
/// `trackId:"master"` sentinel on the EXISTING automation.* verbs (param
/// relax — NO new commands), full add/setPoints/setLaneEnabled/removeLane
/// round trips, the volume-only teaching error verbatim, the sentinel-never-
/// leaks pin (m13-d discipline: "master" stays an invalid track id on every
/// non-master-capable verb), and the snapshot mirror over the wire. Reuses
/// `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Master automation — control protocol (m15-c)")
struct MasterAutomationCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addMasterLane(_ router: CommandRouter,
                               target: JSONValue = .object(["type": .string("volume")])) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "add-master-lane", command: "automation.addLane",
            params: ["trackId": .string("master"), "target": target]
        ))
    }

    @Test("full master round trip: addLane → setPoints → setLaneEnabled → removeLane")
    func masterLaneFullRoundTrip() async throws {
        let (router, store) = makeRouter()

        // addLane {trackId:"master", target:{type:"volume"}} → the lane shape.
        let add = await addMasterLane(router)
        #expect(add.ok)
        let lane = try #require(add.result?["lane"])
        let laneID = try #require(lane["id"]?.stringValue)
        #expect(lane["target"]?["type"]?.stringValue == "volume")
        #expect(lane["points"]?.arrayValue?.isEmpty == true)
        #expect(lane["isEnabled"]?.boolValue == true)

        // Idempotent per target — the SAME lane comes back.
        let again = await addMasterLane(router)
        #expect(again.result?["lane"]?["id"]?.stringValue == laneID)

        // setPoints: whole-array replace, canonicalized, clamped to 0...2
        // (the setMasterVolume range), omitted curve defaults "linear".
        let setPoints = await router.handle(ControlRequest(
            id: "pts", command: "automation.setPoints",
            params: ["trackId": .string("master"), "laneId": .string(laneID),
                     "points": .array([
                        .object(["beat": .number(8), "value": .number(0)]),
                        .object(["beat": .number(0), "value": .number(99), "curve": .string("hold")]),
                     ])]
        ))
        #expect(setPoints.ok)
        let points = try #require(setPoints.result?["lane"]?["points"]?.arrayValue)
        #expect(points.map { $0["beat"]?.doubleValue } == [0, 8])
        #expect(points[0]["value"]?.doubleValue == 2)   // clamped to volumeRange
        #expect(points[0]["curve"]?.stringValue == "hold")
        #expect(points[1]["curve"]?.stringValue == "linear")

        // The store's model moved (wire-equivalence at the owner).
        #expect(store.masterAutomation.first?.points.count == 2)

        // setLaneEnabled toggles read/manual.
        let disable = await router.handle(ControlRequest(
            id: "off", command: "automation.setLaneEnabled",
            params: ["trackId": .string("master"), "laneId": .string(laneID),
                     "enabled": .bool(false)]
        ))
        #expect(disable.ok)
        #expect(disable.result?["lane"]?["isEnabled"]?.boolValue == false)

        // removeLane deletes it.
        let remove = await router.handle(ControlRequest(
            id: "rm", command: "automation.removeLane",
            params: ["trackId": .string("master"), "laneId": .string(laneID)]
        ))
        #expect(remove.ok)
        #expect(store.masterAutomation.isEmpty)

        // Unknown lane id afterwards → automationLaneNotFound verbatim.
        let gone = await router.handle(ControlRequest(
            id: "rm2", command: "automation.removeLane",
            params: ["trackId": .string("master"), "laneId": .string(laneID)]
        ))
        #expect(!gone.ok)
        #expect(gone.error == "no automation lane with id \(laneID) on that track")
    }

    @Test("non-volume targets on master teach verbatim; nothing is created")
    func masterRejectsNonVolumeTargets() async throws {
        let (router, store) = makeRouter()

        for target: JSONValue in [
            .object(["type": .string("pan")]),
            .object(["type": .string("sendLevel"), "sendId": .string(UUID().uuidString)]),
            .object(["type": .string("effectParam"), "effectId": .string(UUID().uuidString),
                     "param": .string("gainLinear")]),
        ] {
            let response = await addMasterLane(router, target: target)
            #expect(!response.ok)
            #expect(response.error ==
                "master automation supports the volume target only in v1 — pan, sendLevel, and effectParam lanes live on tracks (pass a track UUID)")
        }
        #expect(store.masterAutomation.isEmpty)
    }

    @Test("the sentinel never leaks: 'master' stays an invalid track id on non-master-capable verbs")
    func sentinelNeverLeaksIntoOtherVerbs() async throws {
        let (router, _) = makeRouter()

        // track.setVolume goes through requireTrackID — the m13-d rejection
        // shape, unchanged by the m15-c param relax.
        let setVolume = await router.handle(ControlRequest(
            id: "1", command: "track.setVolume",
            params: ["trackId": .string("master"), "volume": .number(0.5)]
        ))
        #expect(!setVolume.ok)
        #expect(setVolume.error == "'trackId' is not a valid UUID: master")

        // track.remove likewise.
        let remove = await router.handle(ControlRequest(
            id: "2", command: "track.remove",
            params: ["trackId": .string("master")]
        ))
        #expect(!remove.ok)
        #expect(remove.error == "'trackId' is not a valid UUID: master")
    }

    @Test("track-UUID automation paths are unchanged by the param relax")
    func trackPathsUnchanged() async throws {
        let (router, _) = makeRouter()
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add",
            params: ["name": .string("Vox"), "kind": .string("audio")]
        ))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)

        // A track pan lane still lands (pan is master-rejected but track-legal).
        let panLane = await router.handle(ControlRequest(
            id: "lane", command: "automation.addLane",
            params: ["trackId": .string(trackID),
                     "target": .object(["type": .string("pan")])]
        ))
        #expect(panLane.ok)
        #expect(panLane.result?["lane"]?["target"]?["type"]?.stringValue == "pan")

        // A garbage trackId still names the UUID failure (not the sentinel).
        let bad = await router.handle(ControlRequest(
            id: "bad", command: "automation.addLane",
            params: ["trackId": .string("MASTER"),   // sentinel is exact-lowercase
                     "target": .object(["type": .string("volume")])]
        ))
        #expect(!bad.ok)
        #expect(bad.error == "'trackId' is not a valid UUID: MASTER")
    }

    @Test("project.snapshot carries masterAutomation with the lane shape; key absent when empty")
    func snapshotCarriesMasterAutomation() async throws {
        let (router, _) = makeRouter()

        // Empty session → NO masterAutomation key (omit-when-empty).
        let before = await router.handle(ControlRequest(id: "s0", command: "project.snapshot"))
        #expect(before.result?["masterAutomation"] == nil)

        let laneID = try #require(
            await addMasterLane(router).result?["lane"]?["id"]?.stringValue)
        let setPoints = await router.handle(ControlRequest(
            id: "pts", command: "automation.setPoints",
            params: ["trackId": .string("master"), "laneId": .string(laneID),
                     "points": .array([
                        .object(["beat": .number(0), "value": .number(1)]),
                        .object(["beat": .number(16), "value": .number(0)]),
                     ])]
        ))
        #expect(setPoints.ok)

        let snapshot = await router.handle(ControlRequest(id: "s1", command: "project.snapshot"))
        let lanes = try #require(snapshot.result?["masterAutomation"]?.arrayValue)
        #expect(lanes.count == 1)
        let lane = try #require(lanes.first)
        #expect(lane["id"]?.stringValue == laneID)
        #expect(lane["target"]?["type"]?.stringValue == "volume")
        #expect(lane["points"]?.arrayValue?.count == 2)
        #expect(lane["isEnabled"]?.boolValue == true)
    }
}
