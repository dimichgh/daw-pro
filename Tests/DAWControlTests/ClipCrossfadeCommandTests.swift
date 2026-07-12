import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m11-d: `clip.move`'s additive overlap-policy
/// response fields (`trimmed`/`removed`), and the new `clip.crossfade` command
/// (happy path + field-named eligibility/material errors). Reuses `FakeMedia`
/// from ControlTests.swift (same target; 2.0 s → 4 beats at 120 BPM).
@MainActor
@Suite("Clip crossfade + overlap — control protocol")
struct ClipCrossfadeCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an audio track and appends `count` 4-beat audio clips (sequential:
    /// [0,4], [4,8], …). Returns (trackId, [clipId…]).
    private func audioTrackWithClips(_ router: CommandRouter, count: Int)
        async throws -> (trackID: String, clipIDs: [String]) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        var ids: [String] = []
        for i in 0..<count {
            let add = await router.handle(ControlRequest(
                id: "a\(i)", command: "clip.addAudio",
                params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
            ids.append(try #require(add.result?["id"]?.stringValue))
        }
        return (trackID, ids)
    }

    // MARK: - clip.move additive response

    @Test("clip.move carries trimmed[] naming a trimmed neighbour")
    func moveResponseCarriesTrimmed() async throws {
        let (router, store) = makeRouter()
        let (trackID, ids) = try await audioTrackWithClips(router, count: 2)  // [0,4],[4,8]

        // Move the second clip onto the first's tail → first trims to [0,2].
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.move",
            params: ["trackId": .string(trackID), "clipId": .string(ids[1]), "toStartBeat": .number(2)]))
        #expect(response.ok)
        #expect(response.result?["startBeat"]?.doubleValue == 2)   // existing field intact
        let trimmed = try #require(response.result?["trimmed"]?.arrayValue)
        #expect(trimmed.map(\.stringValue) == [ids[0]])
        #expect(response.result?["removed"]?.arrayValue?.isEmpty == true)
        // No silent overlap remains.
        #expect(abs(store.tracks[0].clips.first { $0.id.uuidString == ids[0] }!.lengthBeats - 2) < 1e-9)
    }

    @Test("clip.move onto free space carries empty trimmed/removed arrays")
    func moveResponseEmptyArrays() async throws {
        let (router, _) = makeRouter()
        let (trackID, ids) = try await audioTrackWithClips(router, count: 2)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.move",
            params: ["trackId": .string(trackID), "clipId": .string(ids[1]), "toStartBeat": .number(20)]))
        #expect(response.ok)
        #expect(response.result?["trimmed"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["removed"]?.arrayValue?.isEmpty == true)
    }

    // MARK: - clip.crossfade

    /// Adds an audio track, imports a 4-beat clip, splits it at beat 2 → two
    /// adjacent 2-beat halves. Returns (trackId, leftId, rightId).
    private func adjacentHalves(_ router: CommandRouter)
        async throws -> (trackID: String, leftID: String, rightID: String) {
        let (trackID, ids) = try await audioTrackWithClips(router, count: 1)
        let split = await router.handle(ControlRequest(
            id: "s", command: "clip.split",
            params: ["trackId": .string(trackID), "clipId": .string(ids[0]), "atBeat": .number(2)]))
        let left = try #require(split.result?["first"]?["id"]?.stringValue)
        let right = try #require(split.result?["second"]?["id"]?.stringValue)
        return (trackID, left, right)
    }

    @Test("crossfade returns left/right/overlapBeats with equal-power fades spanning the overlap")
    func crossfadeRoundTrips() async throws {
        let (router, store) = makeRouter()
        let (trackID, leftID, rightID) = try await adjacentHalves(router)

        // Pass the ids in the OPPOSITE order to prove ordering is resolved by start.
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.crossfade",
            params: ["trackId": .string(trackID), "clipId": .string(rightID),
                     "otherClipId": .string(leftID), "lengthBeats": .number(1)]))
        #expect(response.ok)
        #expect(response.result?["overlapBeats"]?.doubleValue == 1)
        let left = try #require(response.result?["left"])
        let right = try #require(response.result?["right"])
        #expect(left["id"]?.stringValue == leftID)
        #expect(right["id"]?.stringValue == rightID)
        #expect(left["fadeOutBeats"]?.doubleValue == 1)
        #expect(left["fadeOutCurve"]?.stringValue == "equalPower")
        #expect(right["fadeInBeats"]?.doubleValue == 1)
        #expect(right["fadeInCurve"]?.stringValue == "equalPower")

        // One undo step reverts the whole crossfade.
        let history = await router.handle(ControlRequest(id: "h", command: "edit.history"))
        #expect(history.result?["undo"]?.arrayValue?.first?.stringValue == "Crossfade Clips")
        _ = await router.handle(ControlRequest(id: "u", command: "edit.undo"))
        let l = store.tracks[0].clips.first { $0.id.uuidString == leftID }!
        #expect(l.fadeOutBeats == 0 && abs(l.lengthBeats - 2) < 1e-9)
    }

    @Test("crossfade surfaces the field-named notEligible error on a gap")
    func crossfadeGapError() async throws {
        let (router, _) = makeRouter()
        let (trackID, leftID, rightID) = try await adjacentHalves(router)
        // Pull the right clip away to open a gap (trims nothing — free space).
        _ = await router.handle(ControlRequest(
            id: "m", command: "clip.move",
            params: ["trackId": .string(trackID), "clipId": .string(rightID), "toStartBeat": .number(20)]))
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.crossfade",
            params: ["trackId": .string(trackID), "clipId": .string(leftID),
                     "otherClipId": .string(rightID), "lengthBeats": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("gap") == true)
    }

    @Test("crossfade surfaces crossfadeNeedsMaterial when a clip can't extend")
    func crossfadeNeedsMaterialError() async throws {
        let (router, store) = makeRouter()
        let (trackID, ids) = try await audioTrackWithClips(router, count: 1)  // [0,4], whole 2.0 s file
        // Append an adjacent clip with a head but WHOLE-FILE left neighbour: the
        // left clip fills the source, so it has no tail to extend. Add a second
        // clip butted at beat 4 (offset 0 → no head material either).
        let add = await router.handle(ControlRequest(
            id: "a2", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
        let secondID = try #require(add.result?["id"]?.stringValue)
        #expect(store.tracks[0].clips.count == 2)   // [0,4] and [4,8], both whole-file

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.crossfade",
            params: ["trackId": .string(trackID), "clipId": .string(ids[0]),
                     "otherClipId": .string(secondID), "lengthBeats": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("crossfade") == true)   // names the material gap
    }

    @Test("clip.crossfade is a registered command")
    func crossfadeIsRegistered() {
        #expect(CommandRouter.allCommands.contains("clip.crossfade"))
    }
}
