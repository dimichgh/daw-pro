import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M4 (vii-d) automation lanes:
/// automation.addLane|removeLane|setPoints|setLaneEnabled round trips, the
/// `target` wire shape reusing `AutomationTarget`'s OWN Codable (no
/// hand-parsed duplicate in Commands.swift), the store's v0 rejections/
/// unresolvable-target errors surfacing verbatim, per-index point-parse
/// errors, and the `automation` array on project.snapshot. Reuses
/// `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Automation lanes — control protocol")
struct AutomationCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, name: String, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "add-\(name)", command: "track.add",
            params: ["name": .string(name), "kind": .string(kind)]
        ))
        return UUID(uuidString: response.result?["id"]?.stringValue ?? "")!
    }

    private func addLane(_ router: CommandRouter, trackID: UUID, target: JSONValue) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "add-lane", command: "automation.addLane",
            params: ["trackId": .string(trackID.uuidString), "target": target]
        ))
    }

    // MARK: - addLane

    @Test("addLane round-trips the target shape and is idempotent per target")
    func addLaneRoundTripsAndIsIdempotent() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        let first = await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
        #expect(first.ok)
        let lane = try #require(first.result?["lane"])
        let laneID = try #require(lane["id"]?.stringValue)
        #expect(UUID(uuidString: laneID) != nil)
        #expect(lane["target"]?["type"]?.stringValue == "volume")
        #expect(lane["points"]?.arrayValue?.isEmpty == true)
        #expect(lane["isEnabled"]?.boolValue == true)

        // Idempotent: a repeat call for the SAME target returns the SAME lane
        // (no second lane, no new edit).
        let second = await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
        #expect(second.ok)
        #expect(second.result?["lane"]?["id"]?.stringValue == laneID)
    }

    @Test("addLane resolves an effectParam target against a built-in effect, and rejects an unresolvable one")
    func addLaneEffectParamTargetResolvesOrRejects() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let fxResponse = await router.handle(ControlRequest(
            id: "fx", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("gain")]
        ))
        let effectID = try #require(fxResponse.result?["effectId"]?.stringValue)

        let good = await addLane(router, trackID: trackID, target: .object([
            "type": .string("effectParam"), "effectId": .string(effectID), "param": .string("gainLinear"),
        ]))
        #expect(good.ok)
        #expect(good.result?["lane"]?["target"]?["type"]?.stringValue == "effectParam")
        #expect(good.result?["lane"]?["target"]?["param"]?.stringValue == "gainLinear")

        // An unknown effect id does not resolve — a DIFFERENT error from the
        // v0-unsupported case (this target shape IS supported in principle).
        let bad = await addLane(router, trackID: trackID, target: .object([
            "type": .string("effectParam"), "effectId": .string(UUID().uuidString), "param": .string("gainLinear"),
        ]))
        #expect(!bad.ok)
        #expect(bad.error == "automation target does not resolve on that track")
    }

    @Test("addLane rejects a malformed target type before touching the store")
    func addLaneRejectsBadTargetType() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        let response = await addLane(router, trackID: trackID, target: .object(["type": .string("volumeee")]))
        #expect(!response.ok)
        #expect(response.error?.contains("'target' must be") == true)

        // No lane was created despite the attempt.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        #expect(vox["automation"]?.arrayValue?.isEmpty == true)
    }

    @Test("addLane surfaces the store's sendLevel v0 rejection verbatim")
    func addLaneRejectsSendLevelWithStoreMessage() async throws {
        let (router, store) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let bus = store.addTrack(name: "Reverb", kind: .bus)
        let send = try store.addSend(toTrack: trackID, busID: bus.id, level: 1)

        let response = await addLane(router, trackID: trackID, target: .object([
            "type": .string("sendLevel"), "sendId": .string(send.id.uuidString),
        ]))
        #expect(!response.ok)
        // Exact wording is the ProjectError message — the store's honest
        // deferral, not a hand-written duplicate in Commands.swift.
        #expect(response.error == "send-level automation is not supported in v0")
    }

    @Test("addLane on an unknown track surfaces trackNotFound")
    func addLaneUnknownTrack() async throws {
        let (router, _) = makeRouter()
        let response = await addLane(router, trackID: UUID(), target: .object(["type": .string("volume")]))
        #expect(!response.ok)
        #expect(response.error?.contains("No track with id") == true)
    }

    // MARK: - removeLane

    @Test("removeLane deletes the lane; an unknown id surfaces automationLaneNotFound")
    func removeLaneRoundTripAndUnknownLane() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("pan")]))
                .result?["lane"]?["id"]?.stringValue)

        let remove = await router.handle(ControlRequest(
            id: "1", command: "automation.removeLane",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID)]
        ))
        #expect(remove.ok)

        // Gone from the snapshot.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        #expect(vox["automation"]?.arrayValue?.isEmpty == true)

        // Unknown lane id (the same track, since it's now gone from it).
        let unknown = await router.handle(ControlRequest(
            id: "3", command: "automation.removeLane",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID)]
        ))
        #expect(!unknown.ok)
        #expect(unknown.error == "no automation lane with id \(laneID) on that track")
    }

    // MARK: - setPoints

    @Test("setPoints replaces the whole array, canonicalizes, defaults curve, and clamps to the target range")
    func setPointsRoundTripsAndClamps() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
                .result?["lane"]?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([
                        .object(["beat": .number(4), "value": .number(0.5)]),
                        .object(["beat": .number(0), "value": .number(99), "curve": .string("hold")]),
                     ])]
        ))
        #expect(response.ok)
        let points = try #require(response.result?["lane"]?["points"]?.arrayValue)
        // Canonically re-ordered ascending by beat…
        #expect(points.map { $0["beat"]?.doubleValue } == [0, 4])
        // …value clamps to Track.volumeRange (0...2) at the store boundary…
        #expect(points[0]["value"]?.doubleValue == 2)
        // …curve round-trips explicitly, and an omitted curve defaults "linear".
        #expect(points[0]["curve"]?.stringValue == "hold")
        #expect(points[1]["curve"]?.stringValue == "linear")

        // Whole-array replace: a second call with one point drops the first two.
        let replace = await router.handle(ControlRequest(
            id: "2", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([.object(["beat": .number(2), "value": .number(1)])])]
        ))
        #expect(replace.ok)
        #expect(replace.result?["lane"]?["points"]?.arrayValue?.count == 1)
    }

    @Test("setPoints names the offending index on a malformed point")
    func setPointsNamesOffendingIndex() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
                .result?["lane"]?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([
                        .object(["beat": .number(0), "value": .number(1)]),
                        .object(["beat": .number(1), "value": .number(1), "curve": .string("bezier")]),
                     ])]
        ))
        #expect(!response.ok)
        #expect(response.error?.hasPrefix("points[1]") == true)
    }

    @Test("setPoints on an unknown lane surfaces automationLaneNotFound")
    func setPointsUnknownLane() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(UUID().uuidString),
                     "points": .array([])]
        ))
        #expect(!response.ok)
        #expect(response.error?.contains("no automation lane with id") == true)
    }

    // MARK: - setLaneEnabled

    @Test("setLaneEnabled toggles read/manual without touching points")
    func setLaneEnabledRoundTrips() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("volume")]))
                .result?["lane"]?["id"]?.stringValue)

        let disable = await router.handle(ControlRequest(
            id: "1", command: "automation.setLaneEnabled",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID), "enabled": .bool(false)]
        ))
        #expect(disable.ok)
        #expect(disable.result?["lane"]?["isEnabled"]?.boolValue == false)

        let enable = await router.handle(ControlRequest(
            id: "2", command: "automation.setLaneEnabled",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID), "enabled": .bool(true)]
        ))
        #expect(enable.ok)
        #expect(enable.result?["lane"]?["isEnabled"]?.boolValue == true)
    }

    @Test("setLaneEnabled on an unknown lane surfaces automationLaneNotFound")
    func setLaneEnabledUnknownLane() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let response = await router.handle(ControlRequest(
            id: "1", command: "automation.setLaneEnabled",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(UUID().uuidString),
                     "enabled": .bool(true)]
        ))
        #expect(!response.ok)
        #expect(response.error?.contains("no automation lane with id") == true)
    }

    // MARK: - Snapshot

    @Test("project.snapshot carries the automation array with the full lane shape")
    func snapshotCarriesAutomationArray() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")
        let laneID = try #require(
            await addLane(router, trackID: trackID, target: .object(["type": .string("pan")]))
                .result?["lane"]?["id"]?.stringValue)
        let setResponse = await router.handle(ControlRequest(
            id: "pts", command: "automation.setPoints",
            params: ["trackId": .string(trackID.uuidString), "laneId": .string(laneID),
                     "points": .array([.object(["beat": .number(0), "value": .number(-1)])])]
        ))
        #expect(setResponse.ok)

        let snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let vox = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID.uuidString }))
        let automation = try #require(vox["automation"]?.arrayValue)
        #expect(automation.count == 1)
        let lane = try #require(automation.first)
        #expect(lane["id"]?.stringValue == laneID)
        #expect(lane["target"]?["type"]?.stringValue == "pan")
        // pan range is -1...1 — -1 is in range, unclamped.
        #expect(lane["points"]?.arrayValue?.first?["value"]?.doubleValue == -1)
        #expect(lane["isEnabled"]?.boolValue == true)
    }
}
