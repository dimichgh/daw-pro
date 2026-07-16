import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M7 (macro-c) `macro.songSkeleton`: field-named
/// validation (missing genre), the unknown-genre error listing every valid
/// name, the happy-path response shape (tracks + section clips + loop region),
/// custom sections through the wire, and the ONE-undo-step guarantee proven at
/// the wire (a single `edit.undo` restores the prior track count). Reuses
/// `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Song skeleton — control protocol")
struct MacroSkeletonCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    @Test("allCommands advertises macro.songSkeleton")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("macro.songSkeleton"))
    }

    @Test("missing genre is a field-named validation error listing every valid genre (m16-e, audit F8c)")
    func missingGenre() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton", params: [:]
        ))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("missing or invalid required param 'genre'"))
        for name in SongSkeletonCatalog.names {
            #expect(error.contains(name), "error omits '\(name)': \(error)")
        }
    }

    @Test("unknown top-level key is rejected with a teaching error (m16-e)")
    func unknownKeyRejected() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("pop"), "gener": .string("pop")]
        ))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("'gener'"))
        #expect(error.contains("macro.songSkeleton"))
    }

    @Test("unknown genre error lists every valid genre name")
    func unknownGenreListsNames() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("jazz")]
        ))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("jazz"))
        for name in SongSkeletonCatalog.names {
            #expect(error.contains(name), "error omits '\(name)': \(error)")
        }
    }

    @Test("happy path returns tracks, section clips, and the loop region")
    func happyPathShape() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("pop")]
        ))
        #expect(response.ok)

        #expect(response.result?["genre"]?.stringValue == "pop")
        #expect(response.result?["tempoBPM"]?.doubleValue == 120)

        // Tracks: the pop roster (5) + the Arrangement guide track = 6, each with
        // a real UUID id resolvable in the store.
        let tracks = try #require(response.result?["tracks"]?.arrayValue)
        #expect(tracks.count == 6)
        for entry in tracks {
            let id = try #require(UUID(uuidString: entry["id"]?.stringValue ?? ""))
            #expect(store.tracks.contains { $0.id == id })
            #expect(entry["name"]?.stringValue != nil)
        }
        // The arrangement id is surfaced separately and is the last track.
        let arrangementID = try #require(response.result?["arrangementTrackId"]?.stringValue)
        #expect(tracks.last?["id"]?.stringValue == arrangementID)

        // Section clips: pop = 8 sections, contiguous, ending at 208 beats.
        let clips = try #require(response.result?["sectionClips"]?.arrayValue)
        #expect(clips.count == 8)
        #expect(clips.first?["name"]?.stringValue == "Intro")
        #expect(clips.first?["startBeat"]?.doubleValue == 0)
        #expect(clips.first?["lengthBeats"]?.doubleValue == 16)
        var cursor = 0.0
        for clip in clips {
            #expect(clip["startBeat"]?.doubleValue == cursor)
            cursor += clip["lengthBeats"]?.doubleValue ?? 0
        }
        #expect(cursor == 208)

        // Loop region: 0 → total arrangement length.
        #expect(response.result?["loopStart"]?.doubleValue == 0)
        #expect(response.result?["loopEnd"]?.doubleValue == 208)
        #expect(store.transport.isLoopEnabled)
        #expect(store.transport.loopEndBeat == 208)
    }

    @Test("custom sections flow through the wire")
    func customSectionsThroughWire() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: [
                "genre": .string("house"),
                "tempoBPM": .number(126),
                "sections": .array([
                    .object(["name": .string("A"), "bars": .number(2)]),
                    .object(["name": .string("B"), "bars": .number(4)]),
                ]),
            ]
        ))
        #expect(response.ok)
        #expect(response.result?["tempoBPM"]?.doubleValue == 126)
        #expect(store.transport.tempoBPM == 126)

        let clips = try #require(response.result?["sectionClips"]?.arrayValue)
        #expect(clips.map { $0["name"]?.stringValue } == ["A", "B"])
        #expect(clips.map { $0["startBeat"]?.doubleValue } == [0, 8])
        #expect(clips.map { $0["lengthBeats"]?.doubleValue } == [8, 16])
        #expect(response.result?["loopEnd"]?.doubleValue == 24)
    }

    @Test("bad bars through the wire is a field-named error")
    func badBarsThroughWire() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: [
                "genre": .string("pop"),
                "sections": .array([
                    .object(["name": .string("Bad"), "bars": .number(0)]),
                ]),
            ]
        ))
        #expect(!response.ok)
        #expect(response.error?.contains("sections[0].bars") == true)
    }

    @Test("the whole scaffold is ONE undo step at the wire")
    func oneUndoStepThroughWire() async throws {
        let (router, store) = makeRouter()
        // Seed one pre-existing track so we prove a full revert, not back-to-empty.
        _ = await router.handle(ControlRequest(
            id: "seed", command: "track.add",
            params: ["name": .string("Existing"), "kind": .string("audio")]
        ))
        let priorCount = store.tracks.count

        let apply = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("rock")]
        ))
        #expect(apply.ok)
        #expect(store.tracks.count > priorCount)

        // A single edit.undo reverts the ENTIRE scaffold.
        let undo = await router.handle(ControlRequest(id: "2", command: "edit.undo"))
        #expect(undo.ok)
        #expect(undo.result?["undone"]?.stringValue == "Song Skeleton 'Rock'")
        #expect(store.tracks.count == priorCount)
        #expect(!store.transport.isLoopEnabled)
    }
}
