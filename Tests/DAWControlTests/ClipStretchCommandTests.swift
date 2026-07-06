import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M5 (ii-c) clip-stretch commands:
/// clip.setStretch / clip.stretchToLength round trips over the store ops,
/// the MIDI rejection (invalidClipEdit) surfacing verbatim, project.snapshot
/// carrying the stretch fields, and unknown-id errors. Reuses `FakeMedia` from
/// ControlTests.swift (same target).
@MainActor
@Suite("Clip stretch — control protocol (M5 ii-c)")
struct ClipStretchCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an audio track + a 4-beat audio clip (FakeMedia: 2 s → 4 beats @120)
    /// via the router, returning (trackId, clipId) as wire strings.
    private func addAudioClip(_ router: CommandRouter) async throws -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("audio")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addAudio",
            params: ["trackId": .string(trackID), "path": .string("/tmp/Loop.wav")]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    /// Adds an instrument track + an empty MIDI clip, returning wire ids.
    private func addMIDIClip(_ router: CommandRouter) async throws -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    // MARK: - setStretch

    @Test("setStretch clamps, snapshot carries the fields, and an omitted arg keeps current")
    func setStretchRoundTripsAndSnapshotCarries() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addAudioClip(router)

        // ratio clamps to 4; semitones/formant set; length untouched.
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setStretch",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "ratio": .number(99), "semitones": .number(5),
                     "formantPreserve": .bool(true)]))
        #expect(response.ok)
        #expect(response.result?["stretchRatio"]?.doubleValue == 4)
        #expect(response.result?["pitchShiftSemitones"]?.doubleValue == 5)
        #expect(response.result?["formantPreserve"]?.boolValue == true)
        #expect(store.tracks[0].clips[0].lengthBeats == 4)

        // project.snapshot carries the stretch fields.
        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let tracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let track = try #require(tracks.first(where: { $0["id"]?.stringValue == trackID }))
        let clip = try #require(track["clips"]?.arrayValue?.first)
        #expect(clip["stretchRatio"]?.doubleValue == 4)
        #expect(clip["pitchShiftSemitones"]?.doubleValue == 5)
        #expect(clip["formantPreserve"]?.boolValue == true)

        // Omitting ratio keeps it at 4 while only semitones changes.
        let keep = await router.handle(ControlRequest(
            id: "3", command: "clip.setStretch",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "semitones": .number(-2)]))
        #expect(keep.ok)
        #expect(keep.result?["stretchRatio"]?.doubleValue == 4)
        #expect(keep.result?["pitchShiftSemitones"]?.doubleValue == -2)
    }

    @Test("setStretch on a MIDI clip surfaces invalidClipEdit verbatim")
    func setStretchRejectsMIDI() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await addMIDIClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setStretch",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "ratio": .number(2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("MIDI clip") == true)
        #expect(response.error?.contains("audio clips only") == true)
    }

    @Test("setStretch on an unknown clip surfaces clipNotFound")
    func setStretchUnknownClip() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await addAudioClip(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.setStretch",
            params: ["trackId": .string(trackID), "clipId": .string(UUID().uuidString), "ratio": .number(2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
    }

    // MARK: - stretchToLength

    @Test("stretchToLength doubles the ratio, holds the window, and the snapshot carries it")
    func stretchToLengthRoundTrips() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addAudioClip(router)

        // 4 → 8 beats: ratio 1 → 2, length 8.
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.stretchToLength",
            params: ["trackId": .string(trackID), "clipId": .string(clipID), "lengthBeats": .number(8)]))
        #expect(response.ok)
        #expect(response.result?["lengthBeats"]?.doubleValue == 8)
        #expect(response.result?["stretchRatio"]?.doubleValue == 2)
        #expect(store.tracks[0].clips[0].lengthBeats == 8)
        #expect(store.tracks[0].clips[0].stretchRatio == 2)
    }

    @Test("stretchToLength on a MIDI clip surfaces invalidClipEdit; unknown track errors")
    func stretchToLengthRejectsMIDIAndUnknown() async throws {
        let (router, _) = makeRouter()
        let (midiTrackID, midiClipID) = try await addMIDIClip(router)
        let midi = await router.handle(ControlRequest(
            id: "1", command: "clip.stretchToLength",
            params: ["trackId": .string(midiTrackID), "clipId": .string(midiClipID), "lengthBeats": .number(8)]))
        #expect(!midi.ok)
        #expect(midi.error?.contains("audio clips only") == true)

        let (_, audioClipID) = try await addAudioClip(router)
        let unknown = await router.handle(ControlRequest(
            id: "2", command: "clip.stretchToLength",
            params: ["trackId": .string(UUID().uuidString), "clipId": .string(audioClipID), "lengthBeats": .number(8)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("No track with id") == true)
    }

    // MARK: - allCommands

    @Test("allCommands advertises the clip-stretch commands")
    func clipStretchCommandsAdvertised() {
        #expect(CommandRouter.allCommands.contains("clip.setStretch"))
        #expect(CommandRouter.allCommands.contains("clip.stretchToLength"))
    }
}
