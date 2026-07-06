import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M5 (i-c) clip-edit commands: clip.split|trim|
/// move|setGain|setFades round trips over the i-a store operations landed in
/// ProjectStore, store rejections (invalidClipEdit/trackNotFound/clipNotFound)
/// surfacing verbatim, the fade-curve field-named parse error, an undo
/// reverting a split, and project.snapshot carrying the edited fields
/// (gainDb/fades) afterward. Reuses `FakeMedia` from ControlTests.swift (same
/// target).
@MainActor
@Suite("Clip editing — control protocol")
struct ClipEditCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an instrument track and an 8-beat MIDI clip with one note in each
    /// half (pitch 60 at beat 1, pitch 72 at beat 5) via the router, returning
    /// (trackId, clipId) as wire strings.
    private func addSplittableClip(_ router: CommandRouter) async throws -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: [
                "trackId": .string(trackID), "lengthBeats": .number(8),
                "notes": .array([
                    .object(["pitch": .number(60), "startBeat": .number(1), "lengthBeats": .number(1)]),
                    .object(["pitch": .number(72), "startBeat": .number(5), "lengthBeats": .number(1)]),
                ]),
            ]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    // MARK: - split

    @Test("split returns two clips whose fields match the store math")
    func splitRoundTrips() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.split",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "atBeat": .number(4)]))
        #expect(response.ok)
        let first = try #require(response.result?["first"])
        let second = try #require(response.result?["second"])

        // Left half preserves the original id and covers [0, 4).
        #expect(first["id"]?.stringValue == clipID)
        #expect(first["startBeat"]?.doubleValue == 0)
        #expect(first["lengthBeats"]?.doubleValue == 4)
        let firstNotes = try #require(first["notes"]?.arrayValue)
        #expect(firstNotes.count == 1)
        #expect(firstNotes[0]["pitch"]?.doubleValue == 60)
        #expect(firstNotes[0]["startBeat"]?.doubleValue == 1)

        // Right half is a NEW id, starts at 4, covers the remaining 4 beats,
        // and its note is rebased to the new clip's own start (5 - 4 = 1).
        let secondID = try #require(second["id"]?.stringValue)
        #expect(secondID != clipID)
        #expect(second["startBeat"]?.doubleValue == 4)
        #expect(second["lengthBeats"]?.doubleValue == 4)
        let secondNotes = try #require(second["notes"]?.arrayValue)
        #expect(secondNotes.count == 1)
        #expect(secondNotes[0]["pitch"]?.doubleValue == 72)
        #expect(secondNotes[0]["startBeat"]?.doubleValue == 1)

        // Both clips now live on the track.
        #expect(store.tracks[0].clips.count == 2)
    }

    @Test("split at the clip's own edge surfaces invalidClipEdit verbatim")
    func splitAtEdgeErrors() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.split",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "atBeat": .number(0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("split point must be strictly inside") == true)
    }

    @Test("split on an unknown track/clip surfaces trackNotFound/clipNotFound")
    func splitUnknownTrackOrClip() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let unknownTrack = await router.handle(ControlRequest(
            id: "1", command: "clip.split",
            params: ["trackId": .string(UUID().uuidString), "clipId": .string(clipID), "atBeat": .number(4)]))
        #expect(!unknownTrack.ok)
        #expect(unknownTrack.error?.contains("No track with id") == true)

        let unknownClip = await router.handle(ControlRequest(
            id: "2", command: "clip.split",
            params: ["trackId": .string(trackID), "clipId": .string(UUID().uuidString), "atBeat": .number(4)]))
        #expect(!unknownClip.ok)
        #expect(unknownClip.error?.contains("no clip with id") == true)
    }

    @Test("edit.undo reverts a split back to the single original clip")
    func undoRevertsSplit() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let split = await router.handle(ControlRequest(
            id: "1", command: "clip.split",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "atBeat": .number(4)]))
        #expect(split.ok)
        #expect(store.tracks[0].clips.count == 2)

        let undo = await router.handle(ControlRequest(id: "2", command: "edit.undo"))
        #expect(undo.ok)
        #expect(store.tracks[0].clips.count == 1)
        #expect(store.tracks[0].clips[0].id.uuidString == clipID)
        #expect(store.tracks[0].clips[0].lengthBeats == 8)
    }

    // MARK: - trim

    @Test("trim ripples the visible window without renaming the clip")
    func trimRoundTrips() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.trim",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "newStartBeat": .number(2), "newLengthBeats": .number(4)]))
        #expect(response.ok)
        #expect(response.result?["id"]?.stringValue == clipID)
        #expect(response.result?["startBeat"]?.doubleValue == 2)
        #expect(response.result?["lengthBeats"]?.doubleValue == 4)
        #expect(store.tracks[0].clips[0].startBeat == 2)
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
    }

    @Test("trim on an unknown clip surfaces clipNotFound")
    func trimUnknownClip() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await addSplittableClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.trim",
            params: ["trackId": .string(trackID), "clipId": .string(UUID().uuidString),
                     "newStartBeat": .number(0), "newLengthBeats": .number(4)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    // MARK: - move

    @Test("move slides a clip's timeline start, clamped to >= 0")
    func moveRoundTrips() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.move",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "toStartBeat": .number(-3)]))
        #expect(response.ok)
        #expect(response.result?["startBeat"]?.doubleValue == 0)
        #expect(store.tracks[0].clips[0].startBeat == 0)
    }

    @Test("move on an unknown track surfaces trackNotFound")
    func moveUnknownTrack() async throws {
        let (router, _) = makeRouter()
        let (_, clipID) = try await addSplittableClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.move",
            params: ["trackId": .string(UUID().uuidString), "clipId": .string(clipID), "toStartBeat": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("No track with id") == true)
    }

    // MARK: - setGain

    @Test("setGain clamps to Clip.gainDbRange and the snapshot carries it")
    func setGainRoundTripsAndSnapshotCarries() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setGain",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "gainDb": .number(-6)]))
        #expect(response.ok)
        #expect(response.result?["gainDb"]?.doubleValue == -6)
        #expect(store.tracks[0].clips[0].gainDb == -6)

        // project.snapshot carries the current gainDb.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let track = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID }))
        let clip = try #require(track["clips"]?.arrayValue?.first)
        #expect(clip["gainDb"]?.doubleValue == -6)

        // Out-of-range clamps to Clip.gainDbRange (-72...24).
        let clamped = await router.handle(ControlRequest(
            id: "3", command: "clip.setGain",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "gainDb": .number(999)]))
        #expect(clamped.ok)
        #expect(clamped.result?["gainDb"]?.doubleValue == 24)
    }

    @Test("setGain on an unknown clip surfaces clipNotFound")
    func setGainUnknownClip() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await addSplittableClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setGain",
            params: ["trackId": .string(trackID), "clipId": .string(UUID().uuidString), "gainDb": .number(0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    // MARK: - setFades

    @Test("setFades parses curve strings, defaults to linear, and the snapshot carries the result")
    func setFadesRoundTripsAndSnapshotCarries() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setFades",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "fadeInBeats": .number(1), "fadeOutBeats": .number(1),
                     "fadeInCurve": .string("equalPower")]))
        #expect(response.ok)
        #expect(response.result?["fadeInBeats"]?.doubleValue == 1)
        #expect(response.result?["fadeOutBeats"]?.doubleValue == 1)
        #expect(response.result?["fadeInCurve"]?.stringValue == "equalPower")
        // fadeOutCurve omitted -> defaults "linear" -> omitted from Codable at
        // the default (Clip's own omit-when-default encode).
        #expect(response.result?["fadeOutCurve"]?.stringValue == nil)

        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let track = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID }))
        let clip = try #require(track["clips"]?.arrayValue?.first)
        #expect(clip["fadeInBeats"]?.doubleValue == 1)
        #expect(clip["fadeOutBeats"]?.doubleValue == 1)
        #expect(clip["fadeInCurve"]?.stringValue == "equalPower")
    }

    @Test("setFades names the offending field on a bad curve string")
    func setFadesBadCurveNamesField() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await addSplittableClip(router)

        let badFadeOut = await router.handle(ControlRequest(
            id: "1", command: "clip.setFades",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "fadeInBeats": .number(1), "fadeOutBeats": .number(1),
                     "fadeOutCurve": .string("bezier")]))
        #expect(!badFadeOut.ok)
        #expect(badFadeOut.error?.contains("'fadeOutCurve' must be") == true)

        let badFadeIn = await router.handle(ControlRequest(
            id: "2", command: "clip.setFades",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "fadeInBeats": .number(1), "fadeOutBeats": .number(1),
                     "fadeInCurve": .string("bezier")]))
        #expect(!badFadeIn.ok)
        #expect(badFadeIn.error?.contains("'fadeInCurve' must be") == true)
    }

    @Test("setFades on an unknown clip surfaces clipNotFound")
    func setFadesUnknownClip() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await addSplittableClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setFades",
            params: ["trackId": .string(trackID), "clipId": .string(UUID().uuidString),
                     "fadeInBeats": .number(0), "fadeOutBeats": .number(0)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    // MARK: - allCommands

    @Test("allCommands advertises the clip-edit commands")
    func clipEditCommandsAdvertised() {
        #expect(CommandRouter.allCommands.contains("clip.split"))
        #expect(CommandRouter.allCommands.contains("clip.trim"))
        #expect(CommandRouter.allCommands.contains("clip.move"))
        #expect(CommandRouter.allCommands.contains("clip.setGain"))
        #expect(CommandRouter.allCommands.contains("clip.setFades"))
    }
}
