import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m23-w: `clip.removeMany {ids:[uuid]}` and
/// `clip.moveMany {ids:[uuid], byBeats:Double}` — the wire half of m23-g1's
/// group delete and m23-g2's group drag. The DOMAIN claims (whole-group
/// beat-0 clamp, non-contiguous overlap resolution, permutation invariance)
/// are already proven end-to-end in `Tests/DAWCoreTests/RemoveClipsTests.swift`
/// and `ClipGroupMoveTests.swift` — this suite exercises WIRE behaviour only:
/// request/response shape, `rejectUnknownKeys`, all-or-nothing errors
/// surfacing VERBATIM against the single-clip verbs, and `edit.history` depth
/// (the claim a mutation that loops the single-clip verb would get wrong
/// silently). Reuses `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Group clip edit — control protocol (m23-w)")
struct ClipGroupEditCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    @discardableResult
    private func addClip(
        _ store: ProjectStore, track: UUID, name: String, atBeat: Double, lengthBeats: Double = 4
    ) throws -> UUID {
        try store.addMIDIClip(toTrack: track, name: name, atBeat: atBeat, lengthBeats: lengthBeats).id
    }

    private func undoDepth(_ router: CommandRouter) async throws -> Int {
        let history = await router.handle(ControlRequest(id: "h", command: "edit.history"))
        return try #require(history.result?["undo"]?.arrayValue).count
    }

    /// A router over a store PRE-SEEDED with one ordinary audio clip (far
    /// away, at beat 32) plus two OVERLAPPING audio clips (0–4, 2–6 — a
    /// connected overlap chain) that get formed into a take group over the
    /// wire. Overlapping clips can't be produced through any add/move wire
    /// path (every route resolves through the no-silent-overlap choke point,
    /// m13-b) — the `TakeCommandTests.makeOverlappingRouter` precedent: seed
    /// the overlap at the MODEL layer via `ProjectStore(tracks:)`.
    private func makeTakeGroupFixture()
        -> (router: CommandRouter, store: ProjectStore, trackID: String, ordinaryID: UUID) {
        let url = URL(fileURLWithPath: "/tmp/Loop.wav")
        let ordinary = Clip(name: "Ordinary", startBeat: 32, lengthBeats: 4, audioFileURL: url)
        let a = Clip(name: "A", startBeat: 0, lengthBeats: 4, audioFileURL: url)
        let b = Clip(name: "B", startBeat: 2, lengthBeats: 4, audioFileURL: url)
        let track = Track(name: "Audio", kind: .audio, clips: [ordinary, a, b])
        let store = ProjectStore(tracks: [track])
        store.media = FakeMedia()
        return (CommandRouter(store: store), store, track.id.uuidString, ordinary.id)
    }

    /// Forms a group from the fixture's two overlapping clips and returns the
    /// materialized member clip's current id (the one clip.remove/clip.move
    /// would be asked to edit, distinct from the pre-group source clip ids).
    private func groupAndMemberID(
        _ router: CommandRouter, store: ProjectStore, trackID: String, ordinaryID: UUID
    ) async throws -> String {
        let sourceIDs = store.tracks[0].clips
            .filter { $0.id != ordinaryID }
            .map { $0.id.uuidString }
        let group = await router.handle(ControlRequest(
            id: "g", command: "take.group",
            params: ["trackId": .string(trackID), "clipIds": .array(sourceIDs.map(JSONValue.string))]))
        #expect(group.ok)
        return try #require(store.tracks[0].clips.first { $0.id != ordinaryID }?.id.uuidString)
    }

    // MARK: - clip.removeMany

    @Test("removeMany deletes 3 clips across 2 tracks in exactly ONE edit.history step")
    func removeManyRoundTrip() async throws {
        let (router, store) = makeRouter()
        let t1 = store.addTrack(name: "One", kind: .instrument)
        let t2 = store.addTrack(name: "Two", kind: .instrument)
        let a1 = try addClip(store, track: t1.id, name: "A1", atBeat: 0)
        let a2 = try addClip(store, track: t1.id, name: "A2", atBeat: 8)
        let b1 = try addClip(store, track: t2.id, name: "B1", atBeat: 4)

        let before = try await undoDepth(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.removeMany",
            params: ["ids": .array([a1, a2, b1].map { .string($0.uuidString) })]))
        #expect(response.ok)
        let clips = try #require(response.result?["clips"]?.arrayValue)
        #expect(clips.map { $0["id"]?.stringValue } == [a1, a2, b1].map { $0.uuidString })
        #expect(store.tracks[0].clips.isEmpty)
        #expect(store.tracks[1].clips.isEmpty)

        // EXACTLY one new edit.history entry — not three.
        #expect(try await undoDepth(router) == before + 1)

        let undo = await router.handle(ControlRequest(id: "u", command: "edit.undo"))
        #expect(undo.ok)
        #expect(store.tracks[0].clips.map(\.name) == ["A1", "A2"])
        #expect(store.tracks[1].clips.map(\.name) == ["B1"])
        #expect(try await undoDepth(router) == before)
    }

    @Test("removeMany refuses a take-group member with the SAME error clip.remove gives")
    func removeManyTakeGroupMemberSameErrorAsSingle() async throws {
        let (router, store, trackID, ordinaryID) = makeTakeGroupFixture()
        let memberID = try await groupAndMemberID(
            router, store: store, trackID: trackID, ordinaryID: ordinaryID)

        let singleResponse = await router.handle(ControlRequest(
            id: "single", command: "clip.remove", params: ["clipId": .string(memberID)]))
        #expect(!singleResponse.ok)
        #expect(singleResponse.error?.contains("belongs to take group") == true)

        let manyResponse = await router.handle(ControlRequest(
            id: "many", command: "clip.removeMany",
            params: ["ids": .array([.string(ordinaryID.uuidString), .string(memberID)])]))
        #expect(!manyResponse.ok)
        #expect(manyResponse.error == singleResponse.error, "must be the SAME error, not a rewording")

        // ALL-OR-NOTHING: the ordinary clip, listed FIRST, must not have been
        // removed by the time the member refusal was hit.
        #expect(store.tracks[0].clips.contains { $0.id == ordinaryID })
    }

    @Test("removeMany refuses an unknown id with NO partial mutation")
    func removeManyUnknownIDRefusesWhole() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "One", kind: .instrument)
        let a = try addClip(store, track: track.id, name: "A", atBeat: 0)
        let b = try addClip(store, track: track.id, name: "B", atBeat: 8)
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.removeMany",
            params: ["ids": .array([.string(a.uuidString), .string(UUID().uuidString), .string(b.uuidString)])]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
        // Neither valid clip (one listed BEFORE, one AFTER the bad id) was removed.
        #expect(store.tracks[0].clips.map(\.name) == ["A", "B"])
        #expect(try await undoDepth(router) == before)
    }

    @Test("removeMany with empty ids is a no-op: {clips: []}, edit.history unchanged")
    func removeManyEmptyIDsIsNoOp() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "One", kind: .instrument)
        try addClip(store, track: track.id, name: "A", atBeat: 0)
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.removeMany", params: ["ids": .array([])]))
        #expect(response.ok)
        #expect(response.result?["clips"]?.arrayValue?.isEmpty == true)
        #expect(store.tracks[0].clips.count == 1)
        #expect(try await undoDepth(router) == before)
    }

    @Test("a single-id removeMany behaves identically to clip.remove")
    func removeManySingleIDMatchesSingle() async throws {
        // ONE clip, removed twice (undo between), so both calls act on the
        // EXACT SAME id/fields — `Clip.init` mints a fresh random id per
        // construction, so two separately-built fixtures could never compare
        // this way.
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "One", kind: .instrument)
        let clip = try addClip(store, track: track.id, name: "Solo", atBeat: 4)

        let single = await router.handle(ControlRequest(
            id: "single", command: "clip.remove", params: ["clipId": .string(clip.uuidString)]))
        #expect(single.ok)
        #expect(store.tracks[0].clips.isEmpty)

        let undo = await router.handle(ControlRequest(id: "u", command: "edit.undo"))
        #expect(undo.ok)
        #expect(store.tracks[0].clips.count == 1)

        let many = await router.handle(ControlRequest(
            id: "many", command: "clip.removeMany", params: ["ids": .array([.string(clip.uuidString)])]))
        #expect(many.ok)
        #expect(store.tracks[0].clips.isEmpty)

        // Same removed clip, field-for-field.
        let removedClips = try #require(many.result?["clips"]?.arrayValue)
        #expect(removedClips.count == 1)
        #expect(removedClips[0]["id"]?.stringValue == single.result?["id"]?.stringValue)
        #expect(removedClips[0]["name"]?.stringValue == single.result?["name"]?.stringValue)
        #expect(removedClips[0]["startBeat"]?.doubleValue == single.result?["startBeat"]?.doubleValue)
    }

    @Test("removeMany rejects an unknown parameter key at the boundary")
    func removeManyRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.removeMany",
            params: ["ids": .array([]), "clipIds": .array([])]))
        #expect(!response.ok)
        #expect(response.error?.contains("clipIds") == true)
        #expect(response.error?.contains("clip.removeMany") == true)
    }

    // MARK: - clip.moveMany

    @Test("moveMany translates 3 clips by a delta clamped at the whole-group beat-0 wall")
    func moveManyWholeGroupClamp() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "Keys", kind: .instrument)
        let c0 = try addClip(store, track: track.id, name: "C2", atBeat: 2)
        let c1 = try addClip(store, track: track.id, name: "C6", atBeat: 6)
        let c2 = try addClip(store, track: track.id, name: "C20", atBeat: 20)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveMany",
            params: ["ids": .array([c0, c1, c2].map { .string($0.uuidString) }),
                     "byBeats": .number(-8)]))
        #expect(response.ok)
        #expect(response.result?["requestedDeltaBeats"]?.doubleValue == -8)
        #expect(response.result?["effectiveDeltaBeats"]?.doubleValue == -2)
        #expect(response.result?["clamped"]?.boolValue == true)
        #expect(response.result?["trimmedClipIDs"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["removedClipIDs"]?.arrayValue?.isEmpty == true)

        let clips = try #require(response.result?["clips"]?.arrayValue)
        #expect(clips.count == 3)
        let byStart = clips.compactMap { $0["startBeat"]?.doubleValue }.sorted()
        #expect(byStart == [0, 4, 18])
        // Every spacing survives the clamp intact.
        #expect(byStart[1] - byStart[0] == 4)
        #expect(byStart[2] - byStart[1] == 14)
        #expect(store.tracks[0].clips.map(\.startBeat).sorted() == [0, 4, 18])
    }

    @Test("moveMany: leftmost clip already at beat 0 with a negative delta clamps to effective 0 — a no-op edit")
    func moveManyClampAtWallIsANoOp() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "Keys", kind: .instrument)
        let c0 = try addClip(store, track: track.id, name: "C0", atBeat: 0)
        let c1 = try addClip(store, track: track.id, name: "C8", atBeat: 8)
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveMany",
            params: ["ids": .array([c0, c1].map { .string($0.uuidString) }), "byBeats": .number(-4)]))
        #expect(response.ok)
        #expect(response.result?["requestedDeltaBeats"]?.doubleValue == -4)
        #expect(response.result?["effectiveDeltaBeats"]?.doubleValue == 0)
        // Distinct from a literal byBeats:0 call — the clamp DID reduce the
        // request even though the net effect was zero, and says so honestly.
        #expect(response.result?["clamped"]?.boolValue == true)
        #expect(store.tracks[0].clips.map(\.startBeat) == [0, 8])
        // No edit was performed — no undo entry journaled.
        #expect(try await undoDepth(router) == before)
    }

    @Test("moveMany refuses a take-group member with the SAME error clip.move gives")
    func moveManyTakeGroupMemberSameErrorAsSingle() async throws {
        let (router, store, trackID, ordinaryID) = makeTakeGroupFixture()
        let memberID = try await groupAndMemberID(
            router, store: store, trackID: trackID, ordinaryID: ordinaryID)

        let singleResponse = await router.handle(ControlRequest(
            id: "single", command: "clip.move",
            params: ["trackId": .string(trackID), "clipId": .string(memberID), "toStartBeat": .number(10)]))
        #expect(!singleResponse.ok)
        #expect(singleResponse.error?.contains("belongs to take group") == true)

        let manyResponse = await router.handle(ControlRequest(
            id: "many", command: "clip.moveMany",
            params: ["ids": .array([.string(ordinaryID.uuidString), .string(memberID)]),
                     "byBeats": .number(4)]))
        #expect(!manyResponse.ok)
        #expect(manyResponse.error == singleResponse.error, "must be the SAME error, not a rewording")
        // ALL-OR-NOTHING: the ordinary clip, listed FIRST, must not have moved.
        #expect(store.tracks[0].clips.first { $0.id == ordinaryID }?.startBeat == 32)
    }

    @Test("moveMany refuses an unknown id with NO partial mutation")
    func moveManyUnknownIDRefusesWhole() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "One", kind: .instrument)
        let a = try addClip(store, track: track.id, name: "A", atBeat: 0)
        let b = try addClip(store, track: track.id, name: "B", atBeat: 8)
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveMany",
            params: ["ids": .array([.string(a.uuidString), .string(UUID().uuidString), .string(b.uuidString)]),
                     "byBeats": .number(4)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no clip with id") == true)
        #expect(store.tracks[0].clips.map(\.startBeat) == [0, 8])
        #expect(try await undoDepth(router) == before)
    }

    @Test("moveMany with empty ids is a no-op: effectiveDeltaBeats 0, edit.history unchanged")
    func moveManyEmptyIDsIsNoOp() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "One", kind: .instrument)
        try addClip(store, track: track.id, name: "A", atBeat: 0)
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveMany", params: ["ids": .array([]), "byBeats": .number(4)]))
        #expect(response.ok)
        #expect(response.result?["clips"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["effectiveDeltaBeats"]?.doubleValue == 0)
        #expect(response.result?["clamped"]?.boolValue == false)
        #expect(store.tracks[0].clips.count == 1)
        #expect(try await undoDepth(router) == before)
    }

    @Test("moveMany's trimmedClipIDs/removedClipIDs are wired, not just present-and-empty")
    func moveManyReportsResidentTrimAndRemoval() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(name: "Keys", kind: .instrument)
        // Movers at 0 and 16 shifted +8 land on [8,12) and [24,28); the
        // resident at 8 is exactly covered by the first and REMOVED — the
        // ClipGroupMoveTests "removalReportedOnce" domain fixture, over the
        // wire.
        let mover0 = try addClip(store, track: track.id, name: "M0", atBeat: 0)
        let resident = try addClip(store, track: track.id, name: "R8", atBeat: 8)
        let mover16 = try addClip(store, track: track.id, name: "M16", atBeat: 16)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveMany",
            params: ["ids": .array([mover0, mover16].map { .string($0.uuidString) }),
                     "byBeats": .number(8)]))
        #expect(response.ok)
        #expect(response.result?["removedClipIDs"]?.arrayValue == [.string(resident.uuidString)])
        #expect(response.result?["trimmedClipIDs"]?.arrayValue?.isEmpty == true)
        #expect(!store.tracks[0].clips.contains { $0.id == resident })
    }

    @Test("moveMany rejects an unknown parameter key at the boundary")
    func moveManyRejectsUnknownKey() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveMany",
            params: ["ids": .array([]), "byBeats": .number(0), "toStartBeat": .number(4)]))
        #expect(!response.ok)
        #expect(response.error?.contains("toStartBeat") == true)
        #expect(response.error?.contains("clip.moveMany") == true)
    }

    // MARK: - Wire registration (additive-at-end law)

    @Test("clip.removeMany and clip.moveMany are registered at the END of allCommands")
    func registeredAtEndOfAllCommands() {
        // m23-af appended `transport.panic` after this pair, so both slide
        // one rung up — they did not move, they are simply no longer last.
        // m23-aj-2 then appended `clip.moveManyByTracks`/`clip.moveManyToTrack`
        // after THAT, so all three slide one rung further up in turn.
        // …and m23-dl appended `ai.modelResidency`/`ai.modelUnload` after THOSE,
        // so every entry slides two rungs further up in turn.
        #expect(CommandRouter.allCommands.dropLast(6).last == "clip.removeMany")
        #expect(CommandRouter.allCommands.dropLast(5).last == "clip.moveMany")
        #expect(CommandRouter.allCommands.dropLast(4).last == "transport.panic")
        #expect(CommandRouter.allCommands.dropLast(3).last == "clip.moveManyByTracks")
        #expect(CommandRouter.allCommands.dropLast(2).last == "clip.moveManyToTrack")
        #expect(CommandRouter.allCommands.dropLast().last == "ai.modelResidency")
        #expect(CommandRouter.allCommands.last == "ai.modelUnload")
    }
}
