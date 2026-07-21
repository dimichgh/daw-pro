import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m21-d's `clip.fitToContent`: the one-gesture
/// "make the clip the size its material is". Happy paths for MIDI (trim to the
/// last note's end) and audio (trim to the source's remaining duration),
/// the honest `changed:false` echoes (empty MIDI clip / already exact), the
/// error taxonomy (unknown track/clip, comp member, unknown param keys), and
/// the additive-at-END command-list law. Reuses `FakeMedia` from
/// ControlTests.swift (same target).
@MainActor
@Suite("Clip fit-to-content — control protocol")
struct ClipFitToContentCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Adds an instrument track and an 8-beat MIDI clip whose material ends at
    /// the odd beat 2.37 (the verified complaint's shape), returning wire ids.
    private func addOversizedMIDIClip(_ router: CommandRouter) async throws -> (trackID: String, clipID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: [
                "trackId": .string(trackID), "lengthBeats": .number(8),
                "notes": .array([
                    .object(["pitch": .number(60), "startBeat": .number(0), "lengthBeats": .number(1)]),
                    .object(["pitch": .number(64), "startBeat": .number(1.5), "lengthBeats": .number(0.87)]),
                ]),
            ]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)
        return (trackID, clipID)
    }

    @Test("MIDI: response is the updated clip plus changed:true; length lands on the last note's end")
    func midiFitRoundTrips() async throws {
        let (router, store) = makeRouter()
        let (trackID, clipID) = try await addOversizedMIDIClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.fitToContent",
            params: ["trackId": .string(trackID), "clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["id"]?.stringValue == clipID)
        #expect(response.result?["changed"]?.boolValue == true)
        let length = try #require(response.result?["lengthBeats"]?.doubleValue)
        #expect(abs(length - 2.37) < 1e-9)
        #expect(abs(store.tracks[0].clips[0].lengthBeats - 2.37) < 1e-9)

        // A second fit finds nothing to do: same clip back, changed:false, and
        // the store is untouched.
        let again = await router.handle(ControlRequest(
            id: "2", command: "clip.fitToContent",
            params: ["trackId": .string(trackID), "clipId": .string(clipID)]))
        #expect(again.ok)
        #expect(again.result?["changed"]?.boolValue == false)
        #expect(abs(store.tracks[0].clips[0].lengthBeats - 2.37) < 1e-9)
    }

    @Test("MIDI: a zero-note clip echoes changed:false (no-op, never an error)")
    func emptyMIDIClipNoOp() async throws {
        let (router, store) = makeRouter()
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let addClip = await router.handle(ControlRequest(
            id: "c", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4)]))
        let clipID = try #require(addClip.result?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.fitToContent",
            params: ["trackId": .string(trackID), "clipId": .string(clipID)]))
        #expect(response.ok)
        #expect(response.result?["changed"]?.boolValue == false)
        #expect(response.result?["lengthBeats"]?.doubleValue == 4)
        #expect(store.tracks[0].clips[0].lengthBeats == 4)
    }

    @Test("audio: fit shrinks an over-long clip to the source's remaining duration")
    func audioFitRoundTrips() async throws {
        let (router, store) = makeRouter()
        // FakeMedia: 2.0 s source @120 BPM = 4 beats. Import, then stretch the
        // visible window to 8 beats so fit has work to do.
        let track = store.addTrack(kind: .audio)
        let clip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"), toTrack: track.id)
        _ = try store.trimClip(trackId: track.id, clipId: clip.id, newStartBeat: 0, newLengthBeats: 8)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.fitToContent",
            params: ["trackId": .string(track.id.uuidString), "clipId": .string(clip.id.uuidString)]))
        #expect(response.ok)
        #expect(response.result?["changed"]?.boolValue == true)
        let length = try #require(response.result?["lengthBeats"]?.doubleValue)
        #expect(abs(length - 4) < 1e-9)
        #expect(response.result?["startBeat"]?.doubleValue == 0)
    }

    @Test("unknown track / clip surface trackNotFound / clipNotFound verbatim")
    func unknownTrackOrClip() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await addOversizedMIDIClip(router)

        let unknownTrack = await router.handle(ControlRequest(
            id: "1", command: "clip.fitToContent",
            params: ["trackId": .string(UUID().uuidString), "clipId": .string(clipID)]))
        #expect(!unknownTrack.ok)
        #expect(unknownTrack.error?.contains("No track with id") == true)

        let unknownClip = await router.handle(ControlRequest(
            id: "2", command: "clip.fitToContent",
            params: ["trackId": .string(trackID), "clipId": .string(UUID().uuidString)]))
        #expect(!unknownClip.ok)
        #expect(unknownClip.error?.contains("no clip with id") == true)
    }

    @Test("comp member is rejected with the teaching take-group message")
    func compMemberRejected() async throws {
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        let b = Clip(name: "B", startBeat: 0, lengthBeats: 4,
                     notes: [MIDINote(pitch: 62, startBeat: 0, lengthBeats: 1)])
        let track = Track(name: "Keys", kind: .instrument, clips: [a, b])
        let store = ProjectStore(tracks: [track])
        let router = CommandRouter(store: store)
        _ = try store.groupTakes(trackId: track.id, clipIds: [a.id, b.id])
        let member = try #require(store.tracks[0].clips.first { $0.takeGroupID != nil })

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.fitToContent",
            params: ["trackId": .string(track.id.uuidString), "clipId": .string(member.id.uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("take group") == true)
    }

    @Test("unknown params are rejected with the teaching key list")
    func unknownKeysRejected() async throws {
        let (router, _) = makeRouter()
        let (trackID, clipID) = try await addOversizedMIDIClip(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.fitToContent",
            params: ["trackId": .string(trackID), "clipId": .string(clipID),
                     "lengthBeats": .number(2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'lengthBeats'") == true)
        #expect(response.error?.contains("'clipId', 'trackId'") == true)
    }

    @Test("clip.fitToContent is advertised in allCommands (additive-at-end law); count 152")
    func advertisedAtEnd() {
        #expect(CommandRouter.allCommands.contains("clip.fitToContent"))
        // m21-e's clip.analyzeAudio, then m22-c's mixer.liveLoudness, then
        // m22-g's reference.* quartets (P1 four + P2 four) appended after it
        // — clip.fitToContent is no longer LAST, but the additive-at-end law
        // held at ITS landing; count moved 142 -> 143 -> 144 -> 148 -> 152.
        #expect(CommandRouter.allCommands.last == "reference.compare")
        #expect(CommandRouter.allCommands.count == 152)
        // The verb is additive: its clip.* neighbors are untouched.
        #expect(CommandRouter.allCommands.contains("clip.trim"))
        #expect(CommandRouter.allCommands.contains("clip.split"))
    }
}
