import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for m23-aj-2: `clip.moveManyByTracks
/// {ids, byTracks, byBeats?}` and `clip.moveManyToTrack {ids, toTrackId,
/// byBeats?}` — the WIRE half of m23-aj-1's cross-track group move
/// (`ProjectStore.moveClips(ids:byTracks:byBeats:)` /
/// `moveClips(ids:toTrackId:byBeats:)`, the vertical twins of
/// `clip.moveMany`). The DOMAIN claims (landing policy, the two-phase
/// mechanic, the manufactured-collision refusal) are already proven
/// end-to-end in `Tests/DAWCoreTests/ClipCrossTrackMoveTests.swift` — this
/// suite exercises WIRE behaviour only: request/response shape,
/// `rejectUnknownKeys`, the `byTracks` INTEGRALITY refusal (the design's
/// §9.1 premise was MEASURED FALSE — the existing integer-parameter path
/// truncates, it does not refuse), the two-key OMISSION on the `.toTrack`
/// response (§9.2), and the manufactured-collision message surfaced
/// BYTE-EXACT (no wire-side mapping — `CommandRouter.handle`'s blanket
/// `LocalizedError` arm).
///
/// Design record: `docs/research/design-m23aj-cross-track-move.md` (§9).
@MainActor
@Suite("Cross-track clip move — control protocol (m23-aj-2)")
struct ClipCrossTrackMoveCommandTests {

    // MARK: - Fixture and helpers (mirrors ClipCrossTrackMoveTests's DAWCore fixture)

    /// `[inst A, inst B, inst C, bus D, audio E]` — the same layout m23-aj-1's
    /// DAWCore suite uses, so a wire leg and its domain counterpart reason
    /// about identical geometry.
    private func wireFixture(
        clipsOnA: [Clip] = [], clipsOnB: [Clip] = [],
        clipsOnC: [Clip] = [], clipsOnE: [Clip] = []
    ) -> (router: CommandRouter, store: ProjectStore, tracks: [Track]) {
        let tracks = [
            Track(name: "A", kind: .instrument, clips: clipsOnA),
            Track(name: "B", kind: .instrument, clips: clipsOnB),
            Track(name: "C", kind: .instrument, clips: clipsOnC),
            Track(name: "D", kind: .bus),
            Track(name: "E", kind: .audio, clips: clipsOnE),
        ]
        let store = ProjectStore(tracks: tracks)
        store.media = FakeMedia()
        return (CommandRouter(store: store), store, tracks)
    }

    private func midi(_ name: String, at beat: Double, length: Double = 4,
                      id: UUID = UUID()) -> Clip {
        Clip(id: id, name: name, startBeat: beat, lengthBeats: length,
             notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 2)])
    }

    private func audio(_ name: String, at beat: Double, length: Double = 4,
                       id: UUID = UUID()) -> Clip {
        Clip(id: id, name: name, startBeat: beat, lengthBeats: length,
             audioFileURL: URL(fileURLWithPath: "/tmp/daw-pro-m23aj2.wav"))
    }

    private func undoDepth(_ router: CommandRouter) async throws -> Int {
        let history = await router.handle(ControlRequest(id: "h", command: "edit.history"))
        return try #require(history.result?["undo"]?.arrayValue).count
    }

    // MARK: - clip.moveManyByTracks

    @Test("byTracks happy path: a group spanning 2 tracks moves down 1 with relative offsets intact")
    func byTracksHappyPath() async throws {
        let x = midi("X", at: 0)
        let y = midi("Y", at: 4)
        let (router, store, tracks) = wireFixture(clipsOnA: [x], clipsOnB: [y])

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([x.id, y.id].map { .string($0.uuidString) }),
                     "byTracks": .number(1)]))
        #expect(response.ok)
        #expect(response.result?["requestedTrackDelta"]?.doubleValue == 1)
        #expect(response.result?["effectiveTrackDelta"]?.doubleValue == 1)
        #expect(response.result?["clampedTracks"]?.boolValue == false)
        let landings = try #require(response.result?["landings"]?.arrayValue)
        #expect(landings.count == 2)
        let toTrackIds = Set(landings.compactMap { $0["toTrackId"]?.stringValue })
        #expect(toTrackIds == Set([tracks[1].id.uuidString, tracks[2].id.uuidString]))
        #expect(store.tracks[1].clips.map(\.name) == ["X"])
        #expect(store.tracks[2].clips.map(\.name) == ["Y"])
        // Relative beat offset (4 beats apart) survives the vertical move.
        let starts = (response.result?["clips"]?.arrayValue ?? [])
            .compactMap { $0["startBeat"]?.doubleValue }.sorted()
        #expect(starts == [0, 4])
    }

    @Test("byTracks vertical clamp: already at the bottom track, a runaway positive delta clamps to 0")
    func byTracksVerticalClamp() async throws {
        let p = audio("P", at: 0)
        let (router, store, tracks) = wireFixture(clipsOnE: [p])

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([.string(p.id.uuidString)]), "byTracks": .number(5)]))
        #expect(response.ok)
        #expect(response.result?["requestedTrackDelta"]?.doubleValue == 5)
        #expect(response.result?["effectiveTrackDelta"]?.doubleValue == 0)
        #expect(response.result?["clampedTracks"]?.boolValue == true)
        let landings = try #require(response.result?["landings"]?.arrayValue)
        #expect(landings.count == 1)
        #expect(landings[0]["fromTrackId"]?.stringValue == tracks[4].id.uuidString)
        #expect(landings[0]["toTrackId"]?.stringValue == tracks[4].id.uuidString)
        // A whole-group clamp to 0 is a NO-OP: project untouched.
        #expect(store.tracks == tracks)
    }

    @Test("byTracks beat-0 clamp: byBeats carrying the leftmost clip past 0 is reduced, never per-clip")
    func byTracksBeat0Clamp() async throws {
        let m = midi("M", at: 2)
        let (router, store, _) = wireFixture(clipsOnA: [m])
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([.string(m.id.uuidString)]), "byTracks": .number(0),
                     "byBeats": .number(-8)]))
        #expect(response.ok)
        #expect(response.result?["requestedDeltaBeats"]?.doubleValue == -8)
        #expect(response.result?["effectiveDeltaBeats"]?.doubleValue == -2)
        #expect(response.result?["clamped"]?.boolValue == true)
        #expect(store.tracks[0].clips.first?.startBeat == 0)
        #expect(try await undoDepth(router) == before + 1)
    }

    @Test("byTracks: empty ids is a legal no-op, and the response STILL carries both track-delta keys")
    func byTracksEmptyIdsIsNoOp() async throws {
        let (router, _, _) = wireFixture()
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([]), "byTracks": .number(1)]))
        #expect(response.ok)
        #expect(response.result?["landings"]?.arrayValue?.isEmpty == true)
        #expect(response.result?["clips"]?.arrayValue?.isEmpty == true)
        // Contrast with clip.moveManyToTrack (below): byTracks ALWAYS reports
        // both track-delta fields, even for a no-op.
        #expect(response.result?["requestedTrackDelta"]?.doubleValue == 1)
        #expect(response.result?["effectiveTrackDelta"]?.doubleValue == 0)
        #expect(try await undoDepth(router) == before)
    }

    @Test("byTracks rejects an unknown parameter key at the boundary")
    func byTracksRejectsUnknownKey() async throws {
        let (router, _, _) = wireFixture()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([]), "byTracks": .number(0), "toTrackId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("toTrackId") == true)
        #expect(response.error?.contains("clip.moveManyByTracks") == true)
    }

    @Test("byTracks is REFUSED when non-integral, never truncated (the design §9.1 correction)")
    func byTracksNonIntegralIsRefused() async throws {
        let m = midi("M", at: 0)
        let (router, store, _) = wireFixture(clipsOnA: [m])
        let snapshot = store.tracks

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([.string(m.id.uuidString)]), "byTracks": .number(1.5)]))
        #expect(!response.ok)
        #expect(response.error?.contains("byTracks") == true)
        #expect(response.error?.contains("whole number") == true)
        // NOT silently truncated to 1 — the clip must not have moved at all.
        #expect(store.tracks == snapshot)
    }

    @Test("byTracks is required — omitting it is refused, not defaulted to 0")
    func byTracksMissingIsRefused() async throws {
        let (router, _, _) = wireFixture()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks", params: ["ids": .array([])]))
        #expect(!response.ok)
        #expect(response.error?.contains("byTracks") == true)
    }

    @Test("byTracks kind refusal: a MIDI clip landing on an audio track refuses the WHOLE move")
    func byTracksMIDIOntoAudioTrackRefuses() async throws {
        let m = midi("M", at: 0)
        let (router, store, _) = wireFixture(clipsOnC: [m])   // C is index 2
        let snapshot = store.tracks

        // C -> +2 lands on E (audio, index 4).
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([.string(m.id.uuidString)]), "byTracks": .number(2)]))
        #expect(!response.ok)
        #expect(response.error?.contains("cannot hold MIDI clips") == true)
        #expect(store.tracks == snapshot)
    }

    @Test("byTracks kind refusal: ANYTHING landing on a bus refuses the WHOLE move")
    func byTracksOntoBusRefuses() async throws {
        let m = midi("M", at: 0)
        let (router, store, _) = wireFixture(clipsOnC: [m])   // C index 2, D (bus) index 3
        let snapshot = store.tracks

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyByTracks",
            params: ["ids": .array([.string(m.id.uuidString)]), "byTracks": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("cannot hold") == true)
        #expect(store.tracks == snapshot)
    }

    // MARK: - clip.moveManyToTrack

    @Test("toTrack happy path: a 2-track group COLLAPSES onto one track, beat offsets intact")
    func toTrackHappyPath() async throws {
        let x = midi("X", at: 0)
        let y = midi("Y", at: 4)
        let (router, store, tracks) = wireFixture(clipsOnA: [x], clipsOnB: [y])

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([x.id, y.id].map { .string($0.uuidString) }),
                     "toTrackId": .string(tracks[2].id.uuidString)]))
        #expect(response.ok)
        let landings = try #require(response.result?["landings"]?.arrayValue)
        #expect(landings.allSatisfy { $0["toTrackId"]?.stringValue == tracks[2].id.uuidString })
        #expect(store.tracks[2].clips.map(\.name).sorted() == ["X", "Y"])
        let starts = (response.result?["clips"]?.arrayValue ?? [])
            .compactMap { $0["startBeat"]?.doubleValue }.sorted()
        #expect(starts == [0, 4])
    }

    @Test("toTrack beat-0 clamp: byBeats carrying the leftmost clip past 0 is reduced")
    func toTrackBeat0Clamp() async throws {
        let m = midi("M", at: 2)
        let (router, store, tracks) = wireFixture(clipsOnA: [m])
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([.string(m.id.uuidString)]), "toTrackId": .string(tracks[0].id.uuidString),
                     "byBeats": .number(-8)]))
        #expect(response.ok)
        #expect(response.result?["effectiveDeltaBeats"]?.doubleValue == -2)
        #expect(response.result?["clamped"]?.boolValue == true)
        #expect(store.tracks[0].clips.first?.startBeat == 0)
        #expect(try await undoDepth(router) == before + 1)
    }

    @Test("toTrack: empty ids with a VALID toTrackId is still a legal no-op")
    func toTrackEmptyIdsValidDestinationIsNoOp() async throws {
        let (router, _, tracks) = wireFixture()
        let before = try await undoDepth(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([]), "toTrackId": .string(tracks[0].id.uuidString)]))
        #expect(response.ok)
        #expect(response.result?["landings"]?.arrayValue?.isEmpty == true)
        #expect(try await undoDepth(router) == before)
    }

    @Test("toTrack: an unknown toTrackId is refused EVEN WHEN ids is empty")
    func toTrackUnknownDestinationRefusedEvenWhenEmpty() async throws {
        let (router, _, _) = wireFixture()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([]), "toTrackId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("No track with id") == true)
    }

    @Test("toTrack rejects an unknown parameter key at the boundary")
    func toTrackRejectsUnknownKey() async throws {
        let (router, _, tracks) = wireFixture()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([]), "toTrackId": .string(tracks[0].id.uuidString),
                     "byTracks": .number(1)]))
        #expect(!response.ok)
        #expect(response.error?.contains("byTracks") == true)
        #expect(response.error?.contains("clip.moveManyToTrack") == true)
    }

    @Test("toTrack is required — omitting toTrackId is refused")
    func toTrackMissingDestinationIsRefused() async throws {
        let (router, _, _) = wireFixture()
        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack", params: ["ids": .array([])]))
        #expect(!response.ok)
        #expect(response.error?.contains("toTrackId") == true)
    }

    @Test("toTrack kind refusal: an audio clip landing on an instrument track refuses the WHOLE move")
    func toTrackAudioOntoInstrumentTrackRefuses() async throws {
        let a = audio("A", at: 0)
        let (router, store, tracks) = wireFixture(clipsOnE: [a])
        let snapshot = store.tracks

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([.string(a.id.uuidString)]), "toTrackId": .string(tracks[0].id.uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("only audio tracks accept audio clips") == true)
        #expect(store.tracks == snapshot)
    }

    @Test("toTrack manufactured-collision refusal surfaces the DAWCore message BYTE-EXACT")
    func toTrackManufacturedCollisionByteExact() async throws {
        // Two movers from DIFFERENT source tracks, same beats: a collision this
        // verb itself MANUFACTURES by collapsing them onto C. `CommandRouter`
        // has NO wire-side error mapping for this case (the blanket
        // `LocalizedError` arm at `Commands.swift`), so this pins that the wire
        // message is IDENTICAL to `ProjectError.errorDescription`, not merely
        // that it contains the right words.
        let x = midi("X", at: 0)
        let y = midi("Y", at: 0)
        let (router, store, tracks) = wireFixture(clipsOnA: [x], clipsOnB: [y])
        let snapshot = store.tracks

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([x.id, y.id].map { .string($0.uuidString) }),
                     "toTrackId": .string(tracks[2].id.uuidString)]))
        #expect(!response.ok)
        let expected = "clips 'X' (\(x.id.uuidString)) and 'Y'"
            + " (\(y.id.uuidString)) would overlap on the destination track — moving several tracks'"
            + " clips onto one track needs them at different beats (move them one at a time, or use"
            + " clip.moveManyByTracks to keep them on separate tracks)"
        #expect(response.error == expected)
        #expect(store.tracks == snapshot)
    }

    @Test("toTrack response OMITS requestedTrackDelta/effectiveTrackDelta — ABSENT, not null")
    func toTrackResponseOmitsTrackDeltaKeys() async throws {
        let m = midi("M", at: 0)
        let (router, _, tracks) = wireFixture(clipsOnA: [m])

        let response = await router.handle(ControlRequest(
            id: "1", command: "clip.moveManyToTrack",
            params: ["ids": .array([.string(m.id.uuidString)]), "toTrackId": .string(tracks[1].id.uuidString)]))
        #expect(response.ok)
        // A destination-shaped move has no delta to report; a synthesized 0
        // would be indistinguishable from "the clamp reduced the request to
        // nothing" — so the keys are OMITTED, and the subscript reading nil
        // for an ABSENT key (never a `.null` value, per the encoder) is exactly
        // what proves the omission rather than a coincidental miss.
        #expect(response.result?["requestedTrackDelta"] == nil)
        #expect(response.result?["effectiveTrackDelta"] == nil)
        #expect(response.result?["clampedTracks"] != nil, "the rest of the shape is still present")
    }

    // MARK: - Wire registration (additive-at-end law)

    @Test("clip.moveManyByTracks and clip.moveManyToTrack are registered at the END of allCommands")
    func registeredAtEndOfAllCommands() {
        #expect(CommandRouter.allCommands.dropLast().last == "clip.moveManyByTracks")
        #expect(CommandRouter.allCommands.last == "clip.moveManyToTrack")
    }
}
