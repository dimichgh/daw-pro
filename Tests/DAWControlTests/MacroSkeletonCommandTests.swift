import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M7 (macro-c) `macro.songSkeleton`: field-named
/// validation (missing genre), the unknown-genre error listing every valid
/// name, the happy-path response shape (tracks + section clips + markers + loop
/// region), custom sections through the wire, and the ONE-undo-step guarantee
/// proven at the wire (a single `edit.undo` restores the prior track count).
/// The marker legs answer a measured field report: `marker.list` used to come
/// back EMPTY on a project the macro had just laid a section layout onto, so
/// every downstream agent had to be hand-fed the beat map. Reuses `FakeMedia`
/// from ControlTests.swift (same target).
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
            // ⚠️ WAS "jazz", WHICH m26-p MADE REAL. A negative fixture must be a
            // string the catalog will never plausibly adopt, not one it merely
            // lacks today — otherwise the test silently inverts when the
            // catalog grows.
            params: ["genre": .string("not-a-real-genre")]
        ))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("not-a-real-genre"))
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

    @Test("the wire result carries a marker per section with real ids, names, and beats")
    func markersInWireResult() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("pop")]
        ))
        #expect(response.ok)

        // One marker per section, same {id,name,beat} shape marker.list uses.
        let markers = try #require(response.result?["markers"]?.arrayValue)
        #expect(markers.count == 8)
        #expect(markers.map { $0["name"]?.stringValue }
                == ["Intro", "Verse", "Chorus", "Verse", "Chorus", "Bridge", "Chorus", "Outro"])
        #expect(markers.map { $0["beat"]?.doubleValue }
                == [0, 16, 48, 80, 112, 144, 160, 192])

        // Every id is a REAL marker id resolvable in the store, with the same
        // name and beat the payload advertised.
        for entry in markers {
            let id = try #require(UUID(uuidString: entry["id"]?.stringValue ?? ""))
            let stored = try #require(store.markers.first { $0.id == id })
            #expect(stored.name == entry["name"]?.stringValue)
            #expect(stored.beat == entry["beat"]?.doubleValue)
        }

        // The markers mirror the section clips: same names, beat == startBeat.
        let clips = try #require(response.result?["sectionClips"]?.arrayValue)
        #expect(markers.map { $0["name"]?.stringValue } == clips.map { $0["name"]?.stringValue })
        #expect(markers.map { $0["beat"]?.doubleValue } == clips.map { $0["startBeat"]?.doubleValue })

        // Existing keys are untouched (additive field only).
        #expect(response.result?["genre"]?.stringValue == "pop")
        #expect(response.result?["arrangementTrackId"]?.stringValue != nil)
        #expect(response.result?["loopEnd"]?.doubleValue == 208)
    }

    @Test("marker.list after a skeleton returns exactly the scaffolded markers")
    func markerListAfterSkeleton() async throws {
        let (router, _) = makeRouter()
        let apply = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: [
                "genre": .string("house"),
                "sections": .array([
                    .object(["name": .string("Intro"), "bars": .number(2)]),
                    .object(["name": .string("Drop"), "bars": .number(4)]),
                    .object(["name": .string("Drop"), "bars": .number(4)]),
                ]),
            ]
        ))
        #expect(apply.ok)
        let scaffolded = try #require(apply.result?["markers"]?.arrayValue)

        // The field report's exact complaint: marker.list must NOT come back
        // empty on a project that visually has a section layout.
        let list = await router.handle(ControlRequest(id: "2", command: "marker.list"))
        #expect(list.ok)
        let listed = try #require(list.result?["markers"]?.arrayValue)
        #expect(!listed.isEmpty)

        // Exactly the scaffolded set — ids, names, and beats, in the same order.
        #expect(listed.map { $0["id"]?.stringValue } == scaffolded.map { $0["id"]?.stringValue })
        #expect(listed.map { $0["name"]?.stringValue } == ["Intro", "Drop", "Drop"])
        #expect(listed.map { $0["beat"]?.doubleValue } == [0, 8, 24])
    }

    @Test("a marker that pre-dates the skeleton survives it, in beat order")
    func preExistingMarkerSurvivesThroughWire() async throws {
        let (router, _) = makeRouter()
        let seed = await router.handle(ControlRequest(
            id: "seed", command: "marker.add",
            params: ["name": .string("My Cue"), "beat": .number(100)]
        ))
        #expect(seed.ok)
        let seedID = try #require(seed.result?["id"]?.stringValue)

        let apply = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: ["genre": .string("pop")]
        ))
        #expect(apply.ok)
        // The result reports only what THIS call created — not the pre-existing one.
        let created = try #require(apply.result?["markers"]?.arrayValue)
        #expect(created.count == 8)
        #expect(!created.contains { $0["id"]?.stringValue == seedID })

        // marker.list carries the merged set, beat-sorted, with the seed
        // INTERLEAVED (beat 100 sits between the 80 and 112 sections) — an
        // append-without-sort would put it last.
        let list = await router.handle(ControlRequest(id: "2", command: "marker.list"))
        let listed = try #require(list.result?["markers"]?.arrayValue)
        #expect(listed.count == 9)
        #expect(listed.map { $0["beat"]?.doubleValue }
                == [0, 16, 48, 80, 100, 112, 144, 160, 192])
        #expect(listed[4]["id"]?.stringValue == seedID)
        #expect(listed[4]["name"]?.stringValue == "My Cue")
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

    /// The `tracks` roster override is an ADDITIVE optional param on the
    /// EXISTING verb — no new command, no new result field. This leg exists
    /// mostly to prove the param actually TRAVERSES the wire: a schema that
    /// accepts `tracks` while the handler drops it typechecks perfectly and
    /// silently scaffolds the genre's roster instead of the caller's.
    @Test("a custom roster flows through the wire; the Arrangement track still lands last")
    func customRosterThroughWire() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: [
                "genre": .string("pop"),
                "sections": .array([
                    .object(["name": .string("A"), "bars": .number(2)]),
                ]),
                "tracks": .array([
                    .object(["name": .string("Rhodes"), "kind": .string("instrument"),
                             "mixerPreset": .string("warm-keys")]),
                    .object(["name": .string("Talkbox"), "kind": .string("audio")]),
                ]),
            ]
        ))
        #expect(response.ok)

        // The roster is the CALLER'S — pop's five default strips are not here.
        let tracks = try #require(response.result?["tracks"]?.arrayValue)
        #expect(tracks.map { $0["name"]?.stringValue } == ["Rhodes", "Talkbox", "Arrangement"])
        #expect(store.tracks.map(\.name) == ["Rhodes", "Talkbox", "Arrangement"])

        // The Arrangement track is LAST and is the id surfaced separately …
        let arrangementID = try #require(response.result?["arrangementTrackId"]?.stringValue)
        #expect(tracks.last?["id"]?.stringValue == arrangementID)
        // … and the beat map the macro exists for survived the override.
        #expect(response.result?["sectionClips"]?.arrayValue?.count == 1)
        #expect(response.result?["markers"]?.arrayValue?.count == 1)
        #expect(response.result?["markers"]?.arrayValue?.first?["name"]?.stringValue == "A")
        #expect(store.markers.map(\.beat) == [0])

        // The preset was applied, not merely echoed back.
        let rhodes = try #require(store.tracks.first { $0.name == "Rhodes" })
        #expect(!rhodes.effects.isEmpty)
        #expect(store.tracks.first { $0.name == "Talkbox" }?.effects.isEmpty == true)
    }

    @Test("a bus-kinded roster track is rejected at the wire with a field-named error")
    func busRosterTrackRejectedAtWire() async throws {
        let (router, store) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "macro.songSkeleton",
            params: [
                "genre": .string("pop"),
                "tracks": .array([
                    .object(["name": .string("Sub Bus"), "kind": .string("bus")]),
                ]),
            ]
        ))
        #expect(!response.ok)
        #expect(response.error?.contains("tracks[0].kind") == true)
        #expect(store.tracks.isEmpty)

        // ANTI-VACUITY: the identical call typed `audio` succeeds, so what the
        // wire refused is the KIND and not the `tracks` param itself.
        let ok = await router.handle(ControlRequest(
            id: "2", command: "macro.songSkeleton",
            params: [
                "genre": .string("pop"),
                "tracks": .array([
                    .object(["name": .string("Sub Bus"), "kind": .string("audio")]),
                ]),
            ]
        ))
        #expect(ok.ok)
        #expect(store.tracks.map(\.name) == ["Sub Bus", "Arrangement"])
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
        #expect(store.markers.count == 8)   // rock = 8 sections

        // A single edit.undo reverts the ENTIRE scaffold — markers included.
        let undo = await router.handle(ControlRequest(id: "2", command: "edit.undo"))
        #expect(undo.ok)
        #expect(undo.result?["undone"]?.stringValue == "Song Skeleton 'Rock'")
        #expect(store.tracks.count == priorCount)
        #expect(!store.transport.isLoopEnabled)
        #expect(store.markers.isEmpty)
        let list = await router.handle(ControlRequest(id: "3", command: "marker.list"))
        #expect(list.result?["markers"]?.arrayValue?.isEmpty == true)
    }
}
