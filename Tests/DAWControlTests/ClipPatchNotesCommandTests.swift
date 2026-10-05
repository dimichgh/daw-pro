import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m26-a / m27-n — the `clip.patchNotes` wire verb: round-trip,
/// `rejectUnknownKeys` teaching, the counts-only response (no `notes` key,
/// ever), and every guard's surfacing. The store-level algorithm
/// (coalescing, ALL-OR-NOTHING validation, field apply) is proven in
/// `Tests/DAWCoreTests/PatchNotesTests.swift`; this file proves the wire
/// only translates JSON <-> the store call correctly.
@MainActor
@Suite("clip.patchNotes — control protocol (m26-a / m27-n)")
struct ClipPatchNotesCommandTests {

    private func makeHarness() -> (router: CommandRouter, store: ProjectStore, trackID: String) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        return (CommandRouter(store: store), store, track.id.uuidString)
    }

    private func addMIDIClip(_ router: CommandRouter, trackID: String) async throws -> (clipID: String, noteID: String) {
        let response = await router.handle(ControlRequest(
            id: "setup", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4),
                     "notes": .array([
                        .object(["pitch": .number(60), "velocity": .number(90),
                                 "startBeat": .number(0), "lengthBeats": .number(1)]),
                        .object(["pitch": .number(64), "velocity": .number(90),
                                 "startBeat": .number(1), "lengthBeats": .number(1)]),
                     ])]))
        try #require(response.ok, "setup clip.addMIDI failed: \(response.error ?? "?")")
        let clipID = try #require(response.result?["id"]?.stringValue)
        let notes = try #require(response.result?["notes"]?.arrayValue)
        let noteID = try #require(notes.first?["id"]?.stringValue)
        return (clipID, noteID)
    }

    @Test("happy path: counts-only response, no 'notes' key under any circumstance, and the model is actually patched")
    func happyPathHasNoNotesKeyAndReallyPatches() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID), "velocity": .number(30)])])]))
        #expect(response.ok, "clip.patchNotes failed: \(response.error ?? "?")")

        // ⚠️ Assert the ABSENCE explicitly — the whole point of this verb.
        #expect(response.result?["notes"] == nil)
        #expect(response.result?["clipId"]?.stringValue == clipID)
        #expect(response.result?["updated"]?.doubleValue == 1)
        #expect(response.result?["totalNotes"]?.doubleValue == 2)
        #expect(response.result?["latentNotesPastClipEnd"]?.doubleValue == 0)

        // Assert the MODEL, not just the response (a setter's return is not
        // proof it took).
        let patched = store.tracks[0].clips[0].notes!.first { $0.id.uuidString == noteID }!
        #expect(patched.velocity == 30)
        #expect(patched.pitch == 60, "an omitted field must stay exactly as it was")
    }

    @Test("multiple notes in one call patch together, and one undo reverts all of them")
    func batchPatchAndUndo() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, _) = try await addMIDIClip(router, trackID: trackID)
        let ids = store.tracks[0].clips[0].notes!.map(\.id.uuidString)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID), "update": .array(ids.map {
                .object(["id": .string($0), "velocity": .number(111)])
            })]))
        #expect(response.ok, "clip.patchNotes failed: \(response.error ?? "?")")
        #expect(response.result?["updated"]?.doubleValue == 2)
        #expect(store.tracks[0].clips[0].notes!.allSatisfy { $0.velocity == 111 })

        let undo = await router.handle(ControlRequest(id: "2", command: "edit.undo", params: [:]))
        #expect(undo.ok, "edit.undo failed: \(undo.error ?? "?")")
        #expect(store.tracks[0].clips[0].notes!.allSatisfy { $0.velocity == 90 },
                "one undo must revert every note the batch patch touched")
    }

    @Test("startBeat/lengthBeats/pitch round-trip through the wire, omitted fields stay put")
    func everyFieldRoundTrips() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID), "update": .array([
                .object(["id": .string(noteID), "pitch": .number(72),
                         "startBeat": .number(0.5), "lengthBeats": .number(0.25)]),
            ])]))
        #expect(response.ok)
        let patched = store.tracks[0].clips[0].notes!.first { $0.id.uuidString == noteID }!
        #expect(patched.pitch == 72)
        #expect(patched.startBeat == 0.5)
        #expect(patched.lengthBeats == 0.25)
        #expect(patched.velocity == 90, "velocity was never named in this patch — must stay put")
    }

    @Test("latentNotesPastClipEnd reports a patched startBeat landing past the clip end (no auto-extend)")
    func latentNotesReported() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID), "startBeat": .number(10)])])]))
        #expect(response.ok)
        #expect(response.result?["latentNotesPastClipEnd"]?.doubleValue == 1)
        #expect(store.tracks[0].clips[0].lengthBeats == 4, "patchNotes must never auto-extend the clip")
    }

    @Test("empty update is a no-op: ok, zero updated, no undo entry")
    func emptyUpdateIsANoOp() async throws {
        // `journal` is `internal` to DAWCore — invisible even under
        // `@testable import DAWControl` (a different module). `undoLabel`
        // (what edit.undo would revert next) is public and just as
        // decisive: if patchNotes([]) had pushed an entry, this would
        // change from clip.addMIDI's own label to "Patch Notes x0".
        let (router, store, trackID) = makeHarness()
        let (clipID, _) = try await addMIDIClip(router, trackID: trackID)
        let undoLabelBefore = store.undoLabel

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID), "update": .array([])]))
        #expect(response.ok)
        #expect(response.result?["updated"]?.doubleValue == 0)
        #expect(store.undoLabel == undoLabelBefore, "an empty update must not journal an undo entry")
    }

    @Test("rejectUnknownKeys teaches the typo and points at clip.setNotes for add/remove")
    func unknownKeyTeaches() async throws {
        let (router, _, trackID) = makeHarness()
        let (clipID, _) = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID), "update": .array([]), "notes": .array([])]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'notes'") == true)
        #expect(response.error?.contains("clip.setNotes") == true)
    }

    @Test("missing clipId or update are teaching errors")
    func missingRequiredParamsTeach() async throws {
        let (router, _, trackID) = makeHarness()
        let (clipID, _) = try await addMIDIClip(router, trackID: trackID)

        let noClip = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes", params: ["update": .array([])]))
        #expect(!noClip.ok)
        #expect(noClip.error?.contains("clipId") == true)

        let noUpdate = await router.handle(ControlRequest(
            id: "2", command: "clip.patchNotes", params: ["clipId": .string(clipID)]))
        #expect(!noUpdate.ok)
        #expect(noUpdate.error?.contains("update") == true)
    }

    @Test("update[].id is required and must be a valid UUID (schema layer)")
    func updateIDRequiredAndValid() async throws {
        let (router, _, trackID) = makeHarness()
        let (clipID, _) = try await addMIDIClip(router, trackID: trackID)

        let missingID = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID), "update": .array([.object(["velocity": .number(1)])])]))
        #expect(!missingID.ok)
        #expect(missingID.error?.contains("update[0].id") == true)

        let badID = await router.handle(ControlRequest(
            id: "2", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string("not-a-uuid"), "velocity": .number(1)])])]))
        #expect(!badID.ok)
        #expect(badID.error?.contains("update[0].id") == true)
    }

    @Test("out-of-range fields are field-named teaching errors (schema layer), zero mutation")
    func outOfRangeFieldsTeach() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)
        let before = store.tracks[0].clips[0].notes!

        let badPitch = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID), "pitch": .number(200)])])]))
        #expect(!badPitch.ok)
        #expect(badPitch.error?.contains("update[0].pitch") == true)

        let badVelocity = await router.handle(ControlRequest(
            id: "2", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID), "velocity": .number(0)])])]))
        #expect(!badVelocity.ok)
        #expect(badVelocity.error?.contains("update[0].velocity") == true)

        let badLength = await router.handle(ControlRequest(
            id: "3", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID), "lengthBeats": .number(0)])])]))
        #expect(!badLength.ok)
        #expect(badLength.error?.contains("update[0].lengthBeats") == true)

        let badStart = await router.handle(ControlRequest(
            id: "4", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID), "startBeat": .number(-1)])])]))
        #expect(!badStart.ok)
        #expect(badStart.error?.contains("update[0].startBeat") == true)

        #expect(store.tracks[0].clips[0].notes == before, "every rejected call must leave the model untouched")
    }

    @Test("explicit JSON null on an optional field means 'leave it alone', same as omitting it")
    func explicitNullMeansUnchanged() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID), "pitch": .number(72),
                                                "velocity": .null])])]))
        #expect(response.ok, "clip.patchNotes failed: \(response.error ?? "?")")
        let patched = store.tracks[0].clips[0].notes!.first { $0.id.uuidString == noteID }!
        #expect(patched.pitch == 72)
        #expect(patched.velocity == 90, "explicit null must behave exactly like omitting the key")
    }

    @Test("unknown note id surfaces a readable error naming the id — model byte-identical")
    func unknownNoteIDNamesItself() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, _) = try await addMIDIClip(router, trackID: trackID)
        let before = store.tracks[0].clips[0].notes!
        let bogusID = UUID().uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(bogusID), "velocity": .number(1)])])]))
        #expect(!response.ok)
        #expect(response.error?.contains(bogusID) == true, "the error must name the offending id")
        #expect(store.tracks[0].clips[0].notes == before)
    }

    @Test("an unknown id among otherwise-valid ids refuses the WHOLE call — nothing partially applied")
    func unknownIDRefusesWholeBatch() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)
        let before = store.tracks[0].clips[0].notes!

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID), "update": .array([
                .object(["id": .string(noteID), "velocity": .number(1)]),
                .object(["id": .string(UUID().uuidString), "velocity": .number(1)]),
            ])]))
        #expect(!response.ok)
        #expect(store.tracks[0].clips[0].notes == before,
                "the real note's edit must NOT have been applied — all-or-nothing")
    }

    @Test("the same note id named twice in one call is refused, naming the id")
    func duplicateIDRefused() async throws {
        let (router, store, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)
        let before = store.tracks[0].clips[0].notes!

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID), "update": .array([
                .object(["id": .string(noteID), "velocity": .number(10)]),
                .object(["id": .string(noteID), "velocity": .number(20)]),
            ])]))
        #expect(!response.ok)
        #expect(response.error?.contains(noteID) == true)
        #expect(store.tracks[0].clips[0].notes == before)
    }

    @Test("an update entry with no fields set is refused, naming the id")
    func emptyPatchEntryRefused() async throws {
        let (router, _, trackID) = makeHarness()
        let (clipID, noteID) = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(clipID),
                     "update": .array([.object(["id": .string(noteID)])])]))
        #expect(!response.ok)
        #expect(response.error?.contains(noteID) == true)
    }

    @Test("unknown clipId surfaces clipNotFound; audio clip surfaces notAMIDIClip")
    func storeGuardsSurfaceVerbatim() async throws {
        let (router, store, _) = makeHarness()

        let unknown = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(UUID().uuidString),
                     "update": .array([.object(["id": .string(UUID().uuidString), "velocity": .number(1)])])]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)

        store.media = FakeMedia()
        let audioTrack = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"),
                                              toTrack: audioTrack.id)
        let audio = await router.handle(ControlRequest(
            id: "2", command: "clip.patchNotes",
            params: ["clipId": .string(audioClip.id.uuidString),
                     "update": .array([.object(["id": .string(UUID().uuidString), "velocity": .number(1)])])]))
        #expect(!audio.ok)
        #expect(audio.error?.contains("clip.patchNotes") == true)
    }

    /// `store.tracks`' setter is `private` to `ProjectStore.swift` — invisible
    /// even under `@testable import DAWControl`. Forms a REAL take group over
    /// the wire with two overlapping MIDI clips, then targets a lane member —
    /// the actual end-to-end path an agent would hit (the clip.repeatNotes
    /// precedent).
    @Test("a comp member surfaces clipInTakeGroup, formed via a real take.group over the wire")
    func compMemberSurfacesVerbatim() async throws {
        let clips = [0.0, 2.0].map {
            Clip(name: "Riff", startBeat: $0, lengthBeats: 4,
                notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        }
        let track = Track(name: "Keys", kind: .instrument, clips: clips)
        let store = ProjectStore(tracks: [track])
        let router = CommandRouter(store: store)

        let group = await router.handle(ControlRequest(
            id: "g", command: "take.group",
            params: ["trackId": .string(track.id.uuidString),
                     "clipIds": .array(clips.map { .string($0.id.uuidString) })]))
        try #require(group.ok, "take.group failed: \(group.error ?? "?")")
        let memberID = try #require(store.tracks[0].clips.first?.id.uuidString)
        let memberNoteID = try #require(store.tracks[0].clips.first?.notes?.first?.id.uuidString)

        let comp = await router.handle(ControlRequest(
            id: "1", command: "clip.patchNotes",
            params: ["clipId": .string(memberID),
                     "update": .array([.object(["id": .string(memberNoteID), "velocity": .number(1)])])]))
        #expect(!comp.ok)
        #expect(comp.error?.contains("take group") == true)
    }
}
