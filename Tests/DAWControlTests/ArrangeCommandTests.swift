import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m15-d: `clip.duplicate` (round-trip + overlap
/// honesty), the project-wide `arrange.insertBars` / `arrange.deleteBars`
/// verbs, and the F5 "omit = destructive default" hardening on `track.setOutput`
/// and `input.setDevice`. Reuses `FakeMedia` from ControlTests.swift (same
/// target; 2.0 s → 4 beats at 120 BPM).
@MainActor
@Suite("Arrangement ergonomics + F5 hardening — control protocol")
struct ArrangeCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, kind: String) async throws -> String {
        let response = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string(kind)]))
        return try #require(response.result?["id"]?.stringValue)
    }

    // MARK: - clip.duplicate

    @Test("clip.duplicate returns the new clip unwrapped, plus trimmed/removed arrays")
    func duplicateRoundTrip() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addTrack(router, kind: "audio")
        let add = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
        let clipID = try #require(add.result?["id"]?.stringValue)

        let dup = await router.handle(ControlRequest(
            id: "d", command: "clip.duplicate", params: ["clipId": .string(clipID)]))
        #expect(dup.ok)
        // Unwrapped clip fields (the track.add/clip.addMIDI convention).
        #expect(dup.result?["startBeat"]?.doubleValue == 4)     // flush after [0,4]
        #expect(dup.result?["id"]?.stringValue != clipID)       // fresh id
        // Additive honesty arrays (the clip.move shape), empty on free space.
        #expect(dup.result?["trimmed"]?.arrayValue?.isEmpty == true)
        #expect(dup.result?["removed"]?.arrayValue?.isEmpty == true)
    }

    @Test("clip.duplicate onto an occupied region reports the trimmed resident")
    func duplicateIntoOverlap() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addTrack(router, kind: "audio")
        var ids: [String] = []
        for i in 0..<2 {
            let add = await router.handle(ControlRequest(
                id: "a\(i)", command: "clip.addAudio",
                params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
            ids.append(try #require(add.result?["id"]?.stringValue))
        }
        // Duplicate clip 0 onto clip 1's tail (land at 5 → active [5,9] covers
        // only clip 1's tail; the source clip 0 at [0,4] sits clear).
        let dup = await router.handle(ControlRequest(
            id: "d", command: "clip.duplicate",
            params: ["clipId": .string(ids[0]), "toStartBeat": .number(5)]))
        #expect(dup.ok)
        #expect(dup.result?["trimmed"]?.arrayValue?.map(\.stringValue) == [ids[1]])
    }

    @Test("clip.duplicate rejects a negative toStartBeat and a non-string toTrackId")
    func duplicateBadParams() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addTrack(router, kind: "audio")
        let add = await router.handle(ControlRequest(
            id: "a", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
        let clipID = try #require(add.result?["id"]?.stringValue)
        let neg = await router.handle(ControlRequest(
            id: "n", command: "clip.duplicate",
            params: ["clipId": .string(clipID), "toStartBeat": .number(-1)]))
        #expect(neg.error == "'toStartBeat' must be >= 0")
    }

    // MARK: - arrange.insertBars / deleteBars

    @Test("arrange.insertBars shifts content and reports the inserted beats")
    func insertBarsRoundTrip() async throws {
        let (router, store) = makeRouter()
        let trackID = try await addTrack(router, kind: "instrument")
        _ = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "atBeat": .number(8), "lengthBeats": .number(4)]))
        let ins = await router.handle(ControlRequest(
            id: "i", command: "arrange.insertBars",
            params: ["atBar": .number(2), "count": .number(1)]))   // pivot beat 4, 4/4 → 4 beats
        #expect(ins.ok)
        #expect(ins.result?["atBeat"]?.doubleValue == 4)
        #expect(ins.result?["insertedBeats"]?.doubleValue == 4)
        #expect(ins.result?["beatsPerBar"]?.doubleValue == 4)
        #expect(abs(store.tracks[0].clips[0].startBeat - 12) < 1e-9)  // [8,12) → [12,16)
    }

    @Test("arrange.deleteBars reports removed clip and marker ids")
    func deleteBarsRoundTrip() async throws {
        let (router, store) = makeRouter()
        let trackID = try await addTrack(router, kind: "instrument")
        let add = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "atBeat": .number(4), "lengthBeats": .number(4)]))
        let clipID = try #require(add.result?["id"]?.stringValue)
        let mk = await router.handle(ControlRequest(
            id: "m", command: "marker.add", params: ["name": .string("Gone"), "beat": .number(6)]))
        let markerID = try #require(mk.result?["id"]?.stringValue)

        // Delete bars 2-3 → [4,12): the clip [4,8) and marker at 6 are inside.
        let del = await router.handle(ControlRequest(
            id: "d", command: "arrange.deleteBars",
            params: ["fromBar": .number(2), "count": .number(2)]))
        #expect(del.ok)
        #expect(del.result?["fromBeat"]?.doubleValue == 4)
        #expect(del.result?["deletedBeats"]?.doubleValue == 8)
        #expect(del.result?["removedClipIds"]?.arrayValue?.map(\.stringValue) == [clipID])
        #expect(del.result?["removedMarkerIds"]?.arrayValue?.map(\.stringValue) == [markerID])
        #expect(store.markers.isEmpty)
    }

    @Test("arrange.insertBars validates atBar and count via teaching errors")
    func insertBarsValidation() async throws {
        let (router, _) = makeRouter()
        _ = try await addTrack(router, kind: "instrument")
        let bad = await router.handle(ControlRequest(
            id: "b", command: "arrange.insertBars",
            params: ["atBar": .number(0), "count": .number(1)]))
        #expect(bad.error?.contains("'atBar' must be >= 1") == true)
    }

    // MARK: - F5 hardening (audit F4/F5)

    @Test("track.setOutput rejects a typo'd key with a teaching error listing valid keys")
    func setOutputRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addTrack(router, kind: "audio")
        // The audit's measured trap: `{output: <busId>}` (key typo'd) would
        // silently un-route to master and return ok. Now it is rejected verbatim.
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.setOutput",
            params: ["trackId": .string(trackID), "output": .string(trackID)]))
        #expect(response.error ==
            "track.setOutput: unknown parameter 'output' — valid keys are 'busId', 'trackId'. omit 'busId' (or pass it null) to route the track to master")
    }

    @Test("track.setOutput legal calls (busId set, null, omitted) are NOT regressed")
    func setOutputLegalCallsSurvive() async throws {
        let (router, _) = makeRouter()
        let busID = try await addTrack(router, kind: "bus")
        let trackID = try await addTrack(router, kind: "audio")
        // busId set.
        let set = await router.handle(ControlRequest(
            id: "1", command: "track.setOutput",
            params: ["trackId": .string(trackID), "busId": .string(busID)]))
        #expect(set.ok)
        #expect(set.result?["outputBusId"]?.stringValue == busID)
        // busId null → master.
        let null = await router.handle(ControlRequest(
            id: "2", command: "track.setOutput",
            params: ["trackId": .string(trackID), "busId": .null]))
        #expect(null.ok)
        // busId omitted → master (the sanctioned shorthand).
        let omit = await router.handle(ControlRequest(
            id: "3", command: "track.setOutput", params: ["trackId": .string(trackID)]))
        #expect(omit.ok)
        #expect(omit.result?["outputBusId"] == JSONValue.null)
    }

    @Test("input.setDevice rejects a typo'd key (same omit=destructive-default class)")
    func inputSetDeviceRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "input.setDevice", params: ["device": .string("built-in")]))
        #expect(response.error ==
            "input.setDevice: unknown parameter 'device' — valid keys are 'uid'. omit 'uid' (or pass it null) to select the system-default input")
    }
}
