import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m31-c — the `clip.repeatNotes` wire verb: round-trip, `rejectUnknownKeys`
/// teaching, the counts-only response (no `notes` key, ever), and every
/// guard's LocalizedError surfacing. The store-level algorithm (geometry,
/// coalescing, meter span, auto-extend, transpose/clamp) is proven in
/// `Tests/DAWCoreTests/RepeatNotesTests.swift`; this file proves the wire
/// only translates JSON <-> the store call correctly.
@MainActor
@Suite("clip.repeatNotes — control protocol (m31-c)")
struct ClipRepeatNotesCommandTests {

    private func makeHarness() -> (router: CommandRouter, store: ProjectStore, trackID: String) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        return (CommandRouter(store: store), store, track.id.uuidString)
    }

    private func addMIDIClip(_ router: CommandRouter, trackID: String) async throws -> String {
        let response = await router.handle(ControlRequest(
            id: "setup", command: "clip.addMIDI",
            params: ["trackId": .string(trackID), "lengthBeats": .number(4),
                     "notes": .array([.object(["pitch": .number(60), "startBeat": .number(0),
                                               "lengthBeats": .number(1)])])]))
        try #require(response.ok, "setup clip.addMIDI failed: \(response.error ?? "?")")
        return try #require(response.result?["id"]?.stringValue)
    }

    @Test("happy path: counts-only response, no 'notes' key under any circumstance")
    func happyPathHasNoNotesKey() async throws {
        let (router, _, trackID) = makeHarness()
        let clipID = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID), "fromBeat": .number(0), "toBeat": .number(1),
                     "periodBeats": .number(4), "count": .number(3)]))
        #expect(response.ok, "clip.repeatNotes failed: \(response.error ?? "?")")

        // ⚠️ Assert the ABSENCE explicitly — the whole point of this verb.
        #expect(response.result?["notes"] == nil)
        #expect(response.result?["clipId"]?.stringValue == clipID)
        #expect(response.result?["copiesMade"]?.doubleValue == 3)
        #expect(response.result?["sourceNoteCount"]?.doubleValue == 1)
        #expect(response.result?["notesAdded"]?.doubleValue == 3)
        #expect(response.result?["totalNotes"]?.doubleValue == 4)
        #expect(response.result?["patternSpanBeats"]?.doubleValue == 1)
        #expect(response.result?["firstCopyStartBeat"]?.doubleValue == 4)
        #expect(response.result?["lastCopyEndBeat"]?.doubleValue == 13)
        #expect(response.result?["meterChangesInSpan"]?.doubleValue == 0)
        #expect(response.result?["preExistingNotesInSpan"]?.doubleValue == 0)
        #expect(response.result?["copiesOverlapEachOther"]?.boolValue == false)
        #expect(response.result?["pitchesClamped"]?.doubleValue == 0)
        // extendRefusal must ride as explicit JSON null, not an absent key —
        // an agent should be able to rely on the key always being present.
        #expect(response.result?["extendRefusal"] == .null)
    }

    @Test("extendClip default true grows the clip; explicit false leaves it and reports latent notes")
    func extendClipDefaultAndOverride() async throws {
        let (router, _, trackID) = makeHarness()
        let clipID = try await addMIDIClip(router, trackID: trackID)

        let grown = await router.handle(ControlRequest(
            id: "1", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID), "fromBeat": .number(0), "toBeat": .number(1),
                     "periodBeats": .number(4), "count": .number(3)]))
        #expect(grown.ok)
        #expect(grown.result?["extended"]?.boolValue == true)
        #expect((grown.result?["clipLengthBeats"]?.doubleValue ?? 0) > 4)

        let clipID2 = try await addMIDIClip(router, trackID: trackID)
        let notExtended = await router.handle(ControlRequest(
            id: "2", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID2), "fromBeat": .number(0), "toBeat": .number(1),
                     "periodBeats": .number(4), "count": .number(3), "extendClip": .bool(false)]))
        #expect(notExtended.ok)
        #expect(notExtended.result?["extended"]?.boolValue == false)
        #expect(notExtended.result?["clipLengthBeats"]?.doubleValue == 4)
        #expect((notExtended.result?["latentNotesPastClipEnd"]?.doubleValue ?? 0) == 3)
    }

    @Test("transposeSemitones and noteIds round-trip through the wire")
    func transposeAndNoteIDsRoundTrip() async throws {
        let (router, store, trackID) = makeHarness()
        let clipID = try await addMIDIClip(router, trackID: trackID)
        let noteID = store.tracks[0].clips[0].notes!.first!.id.uuidString

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID), "noteIds": .array([.string(noteID)]),
                     "periodBeats": .number(4), "count": .number(2),
                     "transposeSemitones": .array([.number(0), .number(12)])]))
        #expect(response.ok, "clip.repeatNotes failed: \(response.error ?? "?")")
        #expect(response.result?["copiesMade"]?.doubleValue == 2)
        #expect(response.result?["notesAdded"]?.doubleValue == 2)
        #expect(response.result?["pitchesClamped"]?.doubleValue == 0)

        let pitches = store.tracks[0].clips[0].notes?
            .filter { $0.startBeat > 0 }
            .sorted { $0.startBeat < $1.startBeat }
            .map(\.pitch)
        #expect(pitches == [60, 72])
    }

    @Test("rejectUnknownKeys teaches the typo and includes the clip-relative-beats hint")
    func unknownKeyTeaches() async throws {
        let (router, _, trackID) = makeHarness()
        let clipID = try await addMIDIClip(router, trackID: trackID)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID), "periodBeats": .number(1), "count": .number(1),
                     "coutn": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'coutn'") == true)
        #expect(response.error?.contains("CLIP-relative") == true)
    }

    @Test("missing clipId, periodBeats, or count are teaching errors")
    func missingRequiredParamsTeach() async throws {
        let (router, _, trackID) = makeHarness()
        let clipID = try await addMIDIClip(router, trackID: trackID)

        let noClip = await router.handle(ControlRequest(
            id: "1", command: "clip.repeatNotes",
            params: ["periodBeats": .number(1), "count": .number(1)]))
        #expect(!noClip.ok)
        #expect(noClip.error?.contains("clipId") == true)

        let noPeriod = await router.handle(ControlRequest(
            id: "2", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID), "count": .number(1)]))
        #expect(!noPeriod.ok)
        #expect(noPeriod.error?.contains("periodBeats") == true)

        let noCount = await router.handle(ControlRequest(
            id: "3", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID), "periodBeats": .number(1)]))
        #expect(!noCount.ok)
        #expect(noCount.error?.contains("count") == true)

        let fractionalCount = await router.handle(ControlRequest(
            id: "4", command: "clip.repeatNotes",
            params: ["clipId": .string(clipID), "periodBeats": .number(1), "count": .number(1.5)]))
        #expect(!fractionalCount.ok)
        #expect(fractionalCount.error?.contains("count") == true)
    }

    @Test("unknown clipId surfaces clipNotFound; audio clip surfaces notAMIDIClip")
    func storeGuardsSurfaceVerbatim() async throws {
        let (router, store, _) = makeHarness()

        let unknown = await router.handle(ControlRequest(
            id: "1", command: "clip.repeatNotes",
            params: ["clipId": .string(UUID().uuidString), "periodBeats": .number(1), "count": .number(1)]))
        #expect(!unknown.ok)
        #expect(unknown.error?.contains("no clip with id") == true)

        store.media = FakeMedia()
        let audioTrack = store.addTrack(kind: .audio)
        let audioClip = try store.importAudio(url: URL(fileURLWithPath: "/tmp/Loop.wav"),
                                              toTrack: audioTrack.id)
        let audio = await router.handle(ControlRequest(
            id: "2", command: "clip.repeatNotes",
            params: ["clipId": .string(audioClip.id.uuidString), "periodBeats": .number(1),
                     "count": .number(1)]))
        #expect(!audio.ok)
        #expect(audio.error?.contains("repeat") == true)
    }

    /// `store.tracks`' setter is `private` to `ProjectStore.swift` — invisible
    /// even under `@testable import DAWControl` (that only opens DAWControl's
    /// own internals, not DAWCore's). So, unlike the DAWCoreTests guard test
    /// (which pokes `takeGroupID` directly), this one forms a REAL take group
    /// over the wire with two overlapping MIDI clips, then targets a lane
    /// member — the actual end-to-end path an agent would hit.
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

        let comp = await router.handle(ControlRequest(
            id: "1", command: "clip.repeatNotes",
            params: ["clipId": .string(memberID), "periodBeats": .number(1), "count": .number(1)]))
        #expect(!comp.ok)
        #expect(comp.error?.contains("take group") == true)
    }
}
