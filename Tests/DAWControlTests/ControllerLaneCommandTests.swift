import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m16-b2: `clip.setControllerLane` /
/// `clip.removeControllerLane` — the round-trip, the verbatim teaching errors
/// (bad type, cc-without-controller, empty points, per-type value domains,
/// non-MIDI, caps, lane-not-found listing, rejectUnknownKeys), and the
/// `project.snapshot` carry (present when non-empty, omitted when empty). The
/// wire strings here ARE the contract (MCP surfaces them verbatim in phase 3).
@MainActor
@Suite("Controller lanes — control protocol (m16-b2)")
struct ControllerLaneCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// An instrument track with an empty MIDI clip; returns the clip id.
    private func midiClip(_ router: CommandRouter) async throws -> String {
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let add = await router.handle(ControlRequest(
            id: "m", command: "clip.addMIDI", params: ["trackId": .string(trackID)]))
        return try #require(add.result?["id"]?.stringValue)
    }

    // MARK: - round-trip

    @Test("clip.setControllerLane echoes the stored lane; removeControllerLane clears it")
    func roundTrip() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let set = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID),
                "type": .string("cc"),
                "controller": .number(1),
                "points": .array([
                    .object(["beat": .number(0), "value": .number(0)]),
                    .object(["beat": .number(4), "value": .number(127)]),
                ]),
            ]))
        #expect(set.ok)
        let lanes = try #require(set.result?["controllerLanes"]?.arrayValue)
        #expect(lanes.count == 1)
        #expect(lanes[0]["type"]?["type"]?.stringValue == "cc")
        #expect(lanes[0]["type"]?["controller"]?.doubleValue == 1)
        #expect(lanes[0]["points"]?.arrayValue?.count == 2)

        let remove = await router.handle(ControlRequest(
            id: "r", command: "clip.removeControllerLane", params: [
                "clipId": .string(clipID), "type": .string("cc"), "controller": .number(1),
            ]))
        #expect(remove.ok)
        // The lane is gone → omit-when-empty means no controllerLanes key.
        #expect(remove.result?["controllerLanes"] == nil)
    }

    @Test("clip.setControllerLane pitchBend needs no controller and accepts the 0-16383 domain")
    func pitchBendRoundTrip() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let set = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID),
                "type": .string("pitchBend"),
                "points": .array([.object(["beat": .number(0), "value": .number(8192)]),
                                  .object(["beat": .number(1), "value": .number(16383)])]),
            ]))
        #expect(set.ok)
        let lanes = try #require(set.result?["controllerLanes"]?.arrayValue)
        #expect(lanes[0]["type"]?["type"]?.stringValue == "pitchBend")
        #expect(lanes[0]["points"]?.arrayValue?.last?["value"]?.doubleValue == 16383)
    }

    // MARK: - teaching errors (verbatim)

    private func setError(_ router: CommandRouter, _ params: [String: JSONValue]) async -> String {
        let response = await router.handle(ControlRequest(
            id: "e", command: "clip.setControllerLane", params: params))
        return response.error ?? ""
    }

    @Test("teaching errors are verbatim: bad type, cc-without-controller, empty, value domains")
    func teachingErrors() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let pts: JSONValue = .array([.object(["beat": .number(0), "value": .number(0)])])

        // Bad type string names the valid types.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("mod"), "points": pts])
            .contains(#"'type' must be one of "cc", "pitchBend", "channelPressure""#))

        // cc without controller.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("cc"), "points": pts])
            == #"'controller' is required when type is "cc" — an integer 0-127 (1 = mod wheel, 64 = sustain)"#)

        // Empty points steer to the remove verb.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                        "points": .array([])])
            == "'points' must be non-empty — use clip.removeControllerLane to delete a lane")

        // pitchBend value out of the 0-16383 domain.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                        "points": .array([.object(["beat": .number(0), "value": .number(20000)])])])
            == "points[0].value must be 0-16383 for pitchBend (8192 = center)")

        // cc value out of the 0-127 domain.
        #expect(await setError(router, ["clipId": .string(clipID), "type": .string("cc"), "controller": .number(1),
                                        "points": .array([.object(["beat": .number(0), "value": .number(200)])])])
            == "points[0].value must be 0-127")
    }

    @Test("an audio clip is rejected (notAMIDIClip surfaces)")
    func audioRejected() async throws {
        let (router, _) = makeRouter()
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let add = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
        let clipID = try #require(add.result?["id"]?.stringValue)
        let err = await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                          "points": .array([.object(["beat": .number(0), "value": .number(8192)])])])
        #expect(err.contains("audio clip"))
    }

    @Test("the 16-lanes cap surfaces its teaching error")
    func laneCapError() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        for n in 0..<16 {
            let r = await router.handle(ControlRequest(
                id: "l\(n)", command: "clip.setControllerLane", params: [
                    "clipId": .string(clipID), "type": .string("cc"), "controller": .number(Double(n)),
                    "points": .array([.object(["beat": .number(0), "value": .number(1)])])]))
            #expect(r.ok)
        }
        let err = await setError(router, ["clipId": .string(clipID), "type": .string("pitchBend"),
                                          "points": .array([.object(["beat": .number(0), "value": .number(8192)])])])
        #expect(err.contains("already has 16 controller lanes — remove one first"))
    }

    @Test("removeControllerLane on an unknown lane lists the existing lanes")
    func removeUnknownLists() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        _ = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID), "type": .string("cc"), "controller": .number(64),
                "points": .array([.object(["beat": .number(0), "value": .number(127)])])]))
        let remove = await router.handle(ControlRequest(
            id: "r", command: "clip.removeControllerLane", params: [
                "clipId": .string(clipID), "type": .string("channelPressure")]))
        #expect(!remove.ok)
        #expect(remove.error?.contains("cc64") == true)   // the existing lane is listed
    }

    @Test("rejectUnknownKeys fires on both verbs")
    func rejectUnknownKeys() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)
        let set = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID), "type": .string("pitchBend"),
                "points": .array([.object(["beat": .number(0), "value": .number(8192)])]),
                "curve": .string("linear")]))   // unknown key
        #expect(!set.ok)
        #expect(set.error?.contains("unknown parameter") == true)
        #expect(set.error?.contains("'curve'") == true)

        let remove = await router.handle(ControlRequest(
            id: "r", command: "clip.removeControllerLane", params: [
                "clipId": .string(clipID), "type": .string("pitchBend"), "bogus": .bool(true)]))
        #expect(!remove.ok)
        #expect(remove.error?.contains("unknown parameter") == true)
    }

    // MARK: - snapshot carry

    @Test("project.snapshot carries controllerLanes when present and omits them when empty")
    func snapshotCarry() async throws {
        let (router, _) = makeRouter()
        let clipID = try await midiClip(router)

        // Before any lane: the snapshot clip has no controllerLanes key.
        var snap = await router.handle(ControlRequest(id: "q1", command: "project.snapshot", params: nil))
        var clip = try #require(snap.result?["tracks"]?.arrayValue?.first?["clips"]?.arrayValue?.first)
        #expect(clip["controllerLanes"] == nil)

        _ = await router.handle(ControlRequest(
            id: "s", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID), "type": .string("cc"), "controller": .number(11),
                "points": .array([.object(["beat": .number(0), "value": .number(64)]),
                                  .object(["beat": .number(2), "value": .number(127)])])]))

        // After: the lane rides the snapshot verbatim.
        snap = await router.handle(ControlRequest(id: "q2", command: "project.snapshot", params: nil))
        clip = try #require(snap.result?["tracks"]?.arrayValue?.first?["clips"]?.arrayValue?.first)
        let lanes = try #require(clip["controllerLanes"]?.arrayValue)
        #expect(lanes.count == 1)
        #expect(lanes[0]["type"]?["controller"]?.doubleValue == 11)
        #expect(lanes[0]["points"]?.arrayValue?.count == 2)
    }
}
