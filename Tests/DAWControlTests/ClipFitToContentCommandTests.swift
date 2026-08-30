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
        // m22-g's reference.* quartets (P1 four + P2 four), then m23-d's
        // note.audition, then m23-h's track.reorder appended after it —
        // clip.fitToContent is no longer LAST, but the additive-at-end law held
        // at ITS landing; count moved 142 -> 143 -> 144 -> 148 -> 152 -> 153
        // -> 154.
        // …and m23-k4a's export pair after that; count 156 -> 158. Then
        // m23-n2b's clip.transcribe; count 158 -> 159. Then m23-n3b's
        // install/status pair; count 159 -> 161 — clip.transcribe is no
        // longer last (see SpeechModelInstallCommandTests for that leg).
        #expect(CommandRouter.allCommands.count == 195)   // 159 -> 161 at m23-n3b -> 162 at m23-r4 -> 163 at m23-o1 -> 165 at m23-w -> 166 at m23-af -> 168 at m20-j -> 169 at m23-br-1 -> 171 at m23-aj-2 -> 173 at m23-dl -> 174 at m23-di-2a -> 175 at m25-d -> 176 at m25-z -> 177 at m23-ap-3 -> 178 (clip.getNotes) -> 179 (m26-i instrument.describeSampler) -> 180 (edit.pasteClips) -> 181 (m27 leg D clip.applyBreathContour, placed next to its controller-lane siblings, NOT at the tail) -> 182 (breath pad P1 clip.applyEffortShape, placed next to clip.applyBreathContour, NOT at the tail) -> 183 (breath pad P6 pad.previewEffort, placed next to note.audition — the other 'sounds now, outside the timeline, not an edit' verb — NOT at the tail) -> 186 (m28-knob midi.getControlMap/setControlMap/learnControl, placed next to midi.listInputs — their only sibling on this surface — and BEFORE transport.record, NOT at the tail) -> 187 (m31-f instrument.probeLiveness) -> 188 (m31-c clip.repeatNotes, placed next to clip.setNotes/clip.getNotes, NOT at the tail) -> 189 (m26-a/m27-n clip.patchNotes, placed next to clip.repeatNotes, NOT at the tail) -> 190 (m32-b2 clip.sliceToSampler, placed next to clip.detectTransients/clip.quantizeAudio, NOT at the tail) -> 191 (m24-m leg A vc.convertClips, placed next to vc.convertVocals — its single-clip sibling — NOT at the tail) -> 193 (m24-n project.embeddedVoices next to project.snapshot/project.open, and vc.installEmbeddedVoice next to vc.importVoiceModel, both at the tail per the additive-at-end law) -> 194 (m23-ct note.play, placed next to note.audition/pad.previewEffort — the other 'sounds now, outside the timeline' verbs — NOT at the tail; a tail append reddened 19 end-relative assertions across 7 files on this item's first run) -> 195 (m23-cv chord.voice, a PURE read-only computation, placed next to note.play and NOT at the tail: LivePlayCommandTests pins note.play to pad.previewEffort + 1, so an insertion BEFORE it would redden that instead)
        // -> 187 (m31-f instrument.probeLiveness, placed next to instrument.describeSampler — its read-only instrument.* sibling — NOT at the tail)
        // The verb is additive: its clip.* neighbors are untouched.
        #expect(CommandRouter.allCommands.contains("clip.trim"))
        #expect(CommandRouter.allCommands.contains("clip.split"))
    }
}
