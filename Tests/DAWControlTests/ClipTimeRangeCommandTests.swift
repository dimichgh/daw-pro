import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for the MIDI time-range commands (beta m10-h):
/// clip.deleteTimeRange / clip.insertTimeRange round-trips over the DAWCore
/// primitives, in CLIP-LOCAL beats, plus their validation errors surfacing
/// verbatim through the LocalizedError map. The store-op semantics are pinned in
/// DAWCore's MIDITimeRangeTests; here we assert the wire shape and error surface.
@MainActor
@Suite("Clip time-range — control protocol")
struct ClipTimeRangeCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an instrument track + a `length`-beat MIDI clip carrying `notes`
    /// (each `[pitch, startBeat, lengthBeats]`), returning (trackId, clipId).
    private func addClip(_ router: CommandRouter, length: Double,
                         notes: [(Double, Double, Double)]) async throws -> (String, String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let noteValues: [JSONValue] = notes.map { p, s, l in
            .object(["pitch": .number(p), "startBeat": .number(s), "lengthBeats": .number(l)])
        }
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(length),
                     "notes": .array(noteValues)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    // MARK: - deleteTimeRange

    @Test("deleteTimeRange closes the gap and shrinks the clip")
    func deleteRoundTrips() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addClip(router, length: 16, notes: [
            (60, 0, 2), (62, 5, 2), (64, 8, 2), (65, 12, 1),
        ])

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.deleteTimeRange",
            params: ["clipId": .string(clipID), "startBeat": .number(4), "lengthBeats": .number(4)]))
        #expect(response.ok)
        #expect(response.result?["lengthBeats"]?.doubleValue == 12)
        let notes = try #require(response.result?["notes"]?.arrayValue)
        // 62 (onset inside) dropped; 64→4, 65→8.
        let starts = notes.compactMap { $0["startBeat"]?.doubleValue }.sorted()
        #expect(starts == [0, 4, 8])
    }

    @Test("deleteTimeRange rejects a non-MIDI clip and a bad range verbatim")
    func deleteErrors() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addClip(router, length: 8, notes: [])

        // Zero length.
        let zero = await router.handle(ControlRequest(
            id: "z", command: "clip.deleteTimeRange",
            params: ["clipId": .string(clipID), "startBeat": .number(0), "lengthBeats": .number(0)]))
        #expect(!zero.ok)
        #expect(zero.error?.contains("must be > 0") == true)

        // startBeat past the clip end.
        let outside = await router.handle(ControlRequest(
            id: "o", command: "clip.deleteTimeRange",
            params: ["clipId": .string(clipID), "startBeat": .number(20), "lengthBeats": .number(4)]))
        #expect(!outside.ok)
        #expect(outside.error?.contains("outside clip") == true)

        // Missing required param.
        let missing = await router.handle(ControlRequest(
            id: "m", command: "clip.deleteTimeRange",
            params: ["clipId": .string(clipID), "startBeat": .number(0)]))
        #expect(!missing.ok)
        #expect(missing.error?.contains("lengthBeats") == true)

        // Unknown clip id.
        let unknown = await router.handle(ControlRequest(
            id: "u", command: "clip.deleteTimeRange",
            params: ["clipId": .string(UUID().uuidString), "startBeat": .number(0), "lengthBeats": .number(4)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip") == true)
    }

    // MARK: - insertTimeRange

    @Test("insertTimeRange pushes later notes right and grows the clip")
    func insertRoundTrips() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addClip(router, length: 8, notes: [
            (60, 0, 1), (62, 4, 2), (64, 6, 1),
        ])

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.insertTimeRange",
            params: ["clipId": .string(clipID), "atBeat": .number(4), "lengthBeats": .number(4)]))
        #expect(response.ok)
        #expect(response.result?["lengthBeats"]?.doubleValue == 12)
        let notes = try #require(response.result?["notes"]?.arrayValue)
        let starts = notes.compactMap { $0["startBeat"]?.doubleValue }.sorted()
        #expect(starts == [0, 8, 10])   // 60 stays, 62→8, 64→10
    }

    @Test("insertTimeRange surfaces validation errors verbatim")
    func insertErrors() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addClip(router, length: 8, notes: [])

        let neg = await router.handle(ControlRequest(
            id: "n", command: "clip.insertTimeRange",
            params: ["clipId": .string(clipID), "atBeat": .number(0), "lengthBeats": .number(-1)]))
        #expect(!neg.ok)
        #expect(neg.error?.contains("must be > 0") == true)

        let outside = await router.handle(ControlRequest(
            id: "o", command: "clip.insertTimeRange",
            params: ["clipId": .string(clipID), "atBeat": .number(9), "lengthBeats": .number(4)]))
        #expect(!outside.ok)
        #expect(outside.error?.contains("outside clip") == true)
    }

    @Test("insertTimeRange rejects an audio clip as not-MIDI")
    func insertRejectsAudio() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: track.id)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.insertTimeRange",
            params: ["clipId": .string(clip.id.uuidString), "atBeat": .number(0), "lengthBeats": .number(4)]))
        #expect(!response.ok)
        #expect(response.error?.contains("not a MIDI") == true || response.error?.contains("MIDI") == true)
    }

    // MARK: - catalog membership

    @Test("both commands are registered in allCommands")
    func commandsRegistered() {
        #expect(CommandRouter.allCommands.contains("clip.deleteTimeRange"))
        #expect(CommandRouter.allCommands.contains("clip.insertTimeRange"))
    }
}
