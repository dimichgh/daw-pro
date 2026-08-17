import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m26-g: zone IDENTITY over the wire. The emitter has published `zone.id`
/// since m19-a, but `parseSampler` never read one — it minted a fresh `UUID`
/// per array element, so a `project.snapshot` → `track.setInstrument` round
/// trip silently renumbered the entire keyzone map. Nothing observable broke
/// at the time, which is why it survived: the zones still played. It breaks
/// the moment anything wants to ADDRESS a zone (m26-g's `zonePatches`, the
/// m26-i sampler editor), and it quietly desynchronises any id an agent
/// recorded from an earlier snapshot.
///
/// m26-i's `instrument.describeSampler` tests (MARK below) live in THIS file
/// and THIS struct rather than a new one, deliberately: this repo caps the
/// tree's `@MainActor`-isolated `@Suite` count at a review-cadence bound
/// (`MainActorOccupancySiteTests`'s "Leg C"), and the tree was already sitting
/// at that cap when this item started — a new `@Suite` here would have tripped
/// it and demanded a fresh occupancy-gate campaign just to add a read-only
/// command's tests. Same milestone, same fixture family (`makeRouter`/
/// `pingPath`/`seedThreeZones` below), same file target class; folding in is
/// free and the suite count stays flat.
///
/// Reuses `FakeMedia` from ControlTests.swift (same target).
@MainActor
@Suite("Sampler zone identity + provenance — control protocol (m26-g/m26-h/m26-i)")
struct SamplerZoneIdentityWireTests {
    private static let pingPath = "/System/Library/Sounds/Ping.aiff"

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    /// Sets a three-zone sampler and returns (trackId, the model's zone ids).
    private func seedThreeZones(_ router: CommandRouter, _ store: ProjectStore)
        async throws -> (String, [UUID]) {
        let instID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "seed", command: "track.setInstrument",
            params: [
                "trackId": .string(instID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([
                        .object(["path": .string(Self.pingPath), "minPitch": .number(0),
                                 "maxPitch": .number(47), "rootPitch": .number(36)]),
                        .object(["path": .string(Self.pingPath), "minPitch": .number(48),
                                 "maxPitch": .number(71), "rootPitch": .number(60)]),
                        .object(["path": .string(Self.pingPath), "minPitch": .number(72),
                                 "maxPitch": .number(127), "rootPitch": .number(84)]),
                    ]),
                ]),
            ]))
        #expect(response.ok)
        let ids = store.tracks[0].instrument?.sampler?.zones.map(\.id) ?? []
        #expect(ids.count == 3)
        return (instID, ids)
    }

    /// THE m26-g REGRESSION. Snapshot a sampler track, feed the emitted zones
    /// straight back through `track.setInstrument`, and every id must be the
    /// id it was. Before the fix this failed on all three.
    @Test("snapshot → setInstrument round trip preserves every zone id")
    func snapshotRoundTripPreservesZoneIDs() async throws {
        let (router, store) = makeRouter()
        let (instID, originalIDs) = try await seedThreeZones(router, store)

        // Read the zones back exactly as an agent would.
        let snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        #expect(snapshot.ok)
        let emitted = try #require(
            snapshot.result?["tracks"]?.arrayValue?.first?["instrument"]?["sampler"]?["zones"]?
                .arrayValue)
        #expect(emitted.count == 3)
        #expect(emitted.compactMap { $0["id"]?.stringValue }
            == originalIDs.map(\.uuidString))

        // …and send them straight back, unmodified. This is the documented
        // read-modify-write shape for a wholesale zone edit.
        let echo = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zones": .array(emitted)])]))
        #expect(echo.ok)

        // THE POINT: identity survived the trip.
        #expect(store.tracks[0].instrument?.sampler?.zones.map(\.id) == originalIDs)
        // …and so did the mapping the ids name.
        #expect(store.tracks[0].instrument?.sampler?.zones.map(\.minPitch) == [0, 48, 72])
    }

    @Test("an omitted zone id still mints a fresh one — authoring a new map needs no ids")
    func absentIDMintsFresh() async throws {
        let (router, store) = makeRouter()
        let (instID, originalIDs) = try await seedThreeZones(router, store)

        // A wholesale replace with NO ids: three brand-new zones.
        let replaced = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath)]),
                     ])])]))
        #expect(replaced.ok)
        let ids = try #require(store.tracks[0].instrument?.sampler?.zones.map(\.id))
        #expect(ids.count == 1)
        #expect(!originalIDs.contains(ids[0]))
    }

    /// ⭐ THE COMPATIBILITY PIN FOR THE ORCHESTRATOR'S 2026-08-17 RULING.
    ///
    /// Copying one track's zone map onto ANOTHER track — snapshot A, send to B
    /// with A's ids attached — SUCCEEDED before m26-g (ids were silently
    /// re-minted). m26-g's first implementation made it a hard error, which is
    /// a live behaviour change on a shipped verb. The ruling: keep it working
    /// on the `zones` REPLACE path, because the hazard that error guarded
    /// against (zone ids must be globally unique — `ProjectDocument.swift:893`
    /// keys every zone's sample-file reference out of ONE project-wide
    /// `mediaRefs` by zone id) is one that honouring ids INTRODUCED. The old
    /// re-mint was safe; a blanket reject charges existing callers for a new
    /// feature's hazard.
    ///
    /// It must not be SILENT, though — hence `remintedZoneIDs`. A caller that
    /// believed it was preserving ids is told, by id, that it was not.
    @Test("copying a zone map onto ANOTHER track still works, and reports the re-minted ids")
    func crossTrackCopyRemintsAndReports() async throws {
        let (router, store) = makeRouter()
        let (sourceID, sourceIDs) = try await seedThreeZones(router, store)

        let snapshot = await router.handle(ControlRequest(id: "1", command: "project.snapshot"))
        let emitted = try #require(
            snapshot.result?["tracks"]?.arrayValue?.first?["instrument"]?["sampler"]?["zones"]?
                .arrayValue)

        // A SECOND track, and A's zones — ids and all — sent to it.
        let destID = store.addTrack(kind: .instrument).id.uuidString
        let copied = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(destID),
                     "kind": .string("sampler"),
                     "sampler": .object(["zones": .array(emitted)])]))

        // (1) It SUCCEEDS. This is the call the first implementation broke.
        #expect(copied.ok, "cross-track zone copy must not refuse: \(copied.error ?? "")")

        // (2) The destination got the map, under FRESH ids — never A's, or the
        //     two tracks would collide in `mediaRefs` on the next save.
        let destZones = try #require(store.tracks[1].instrument?.sampler?.zones)
        #expect(destZones.count == 3)
        #expect(destZones.map(\.minPitch) == [0, 48, 72])
        #expect(Set(destZones.map(\.id)).isDisjoint(with: Set(sourceIDs)))

        // (3) The SOURCE is untouched — its ids are still its own.
        #expect(store.tracks[0].instrument?.sampler?.zones.map(\.id) == sourceIDs)

        // (4) And the substitution was REPORTED, by id, in send order.
        #expect(copied.result?["remintedZoneIDs"]?.arrayValue?.compactMap(\.stringValue)
            == sourceIDs.map(\.uuidString))

        // ANTI-VACUITY: the field is absent — not an empty array — on the
        // ordinary same-track round trip, where nothing was substituted. A
        // field that is always present is a field nobody reads.
        let sameTrack = await router.handle(ControlRequest(
            id: "3", command: "track.setInstrument",
            params: ["trackId": .string(sourceID),
                     "sampler": .object(["zones": .array(emitted)])]))
        #expect(sameTrack.ok)
        #expect(sameTrack.result?["remintedZoneIDs"] == nil)
        #expect(store.tracks[0].instrument?.sampler?.zones.map(\.id) == sourceIDs)
    }

    // MARK: - zonePatches (merge by id)

    @Test("zonePatches edits the named zone IN PLACE and leaves every other zone standing")
    func zonePatchesMergeByID() async throws {
        let (router, store) = makeRouter()
        let (instID, ids) = try await seedThreeZones(router, store)
        // An unrelated edit between the seed and the patch, so the undo
        // assertion at the end means something. `setInstrument` coalesces on
        // key "track.instrument:<id>", so back-to-back instrument edits inside
        // the coalescing window MERGE into one journal entry — pre-existing
        // behaviour that the wholesale `zones` path shares, and without this
        // barrier a single undo walks past the seed and leaves no instrument.
        _ = store.addTrack(kind: .audio)

        // Patch the LAST zone only — the case that would expose a
        // dictionary-rebuild reorder, since a reorder is invisible when you
        // patch the first one.
        let patched = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object([
                         "zonePatches": .array([
                             .object(["id": .string(ids[2].uuidString),
                                      "gain": .number(0.25),
                                      "tuneCents": .number(-1_200)]),
                         ]),
                         // A global rides along in the same call — the whole
                         // point of finding 12: tune one knob, keep the library.
                         "release": .number(0.4),
                     ])]))
        #expect(patched.ok)

        let sampler = try #require(store.tracks[0].instrument?.sampler)
        // ORDER and identity are untouched. Zone order is load-bearing (first
        // zone whose span contains the pitch wins on overlap), so this is not
        // a cosmetic assertion.
        #expect(sampler.zones.map(\.id) == ids)
        #expect(sampler.zones.map(\.minPitch) == [0, 48, 72])
        // The patch landed on the zone it named…
        #expect(sampler.zones[2].gain == 0.25)
        #expect(sampler.zones[2].tuneCents == -1_200)
        // …and on nothing else.
        #expect(sampler.zones[0].gain == 1)
        #expect(sampler.zones[1].gain == 1)
        #expect(sampler.zones[2].rootPitch == 84)   // unmentioned → kept
        #expect(sampler.zones[2].maxPitch == 127)
        #expect(sampler.release == 0.4)

        // A patch is ONE journaled edit on the SAME path every sampler edit
        // uses — not a new mutation cadence. Asserted rather than assumed:
        // m25-k was a correct policy invoked at the wrong cadence, and undo
        // coalescing hid it completely.
        #expect(store.undoLabel == "Change Instrument")
        _ = try store.undo()
        let reverted = try #require(store.tracks[0].instrument?.sampler)
        #expect(reverted.zones.map(\.id) == ids)          // identity survives undo
        #expect(reverted.zones.map(\.minPitch) == [0, 48, 72])
        #expect(reverted.zones[2].gain == 1)              // the patch is gone
        #expect(reverted.zones[2].tuneCents == nil)
        #expect(reverted.release != 0.4)
    }

    @Test("an unmentioned patch field keeps its value — including its nil-ness")
    func zonePatchesPreserveNilness() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(instID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath),
                                  "tuneCents": .number(50),
                                  "group": .number(3)]),
                     ])])])).ok)
        let id = try #require(store.tracks[0].instrument?.sampler?.zones.first?.id)

        let patched = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zonePatches": .array([
                         .object(["id": .string(id.uuidString), "gain": .number(0.5)]),
                     ])])]))
        #expect(patched.ok)
        let zone = try #require(store.tracks[0].instrument?.sampler?.zones.first)
        #expect(zone.gain == 0.5)
        #expect(zone.tuneCents == 50)     // SET stays set
        #expect(zone.group == 3)
        #expect(zone.pan == nil)          // nil stays nil — NOT an implicit 0
        #expect(zone.loopMode == nil)

        // The patched zone still emits only the keys that are set, so the
        // wire shape does not grow just because a zone was touched.
        let zoneJSON = try #require(patched.result?["sampler"]?["zones"]?.arrayValue?.first)
        #expect(zoneJSON["pan"] == nil)
        #expect(zoneJSON["loopMode"] == nil)
        #expect(zoneJSON["id"]?.stringValue == id.uuidString)
    }

    @Test("a patch clamps through the model exactly like the wholesale path")
    func zonePatchesClampThroughModel() async throws {
        let (router, store) = makeRouter()
        let (instID, ids) = try await seedThreeZones(router, store)

        let patched = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zonePatches": .array([
                         // maxPitch below the zone's CURRENT minPitch (48):
                         // swaps, as the wholesale path does.
                         .object(["id": .string(ids[1].uuidString),
                                  "maxPitch": .number(20),
                                  "gain": .number(9)]),   // → 2 (the A5 ceiling)
                     ])])]))
        #expect(patched.ok)
        let zone = try #require(store.tracks[0].instrument?.sampler?.zones[1])
        #expect(zone.minPitch == 20)
        #expect(zone.maxPitch == 48)
        #expect(zone.gain == 2)
    }

    // MARK: - teaching errors

    @Test("zones + zonePatches in one call is a teaching error naming both keys")
    func zonesAndPatchesTogetherRefuse() async throws {
        let (router, store) = makeRouter()
        let (instID, ids) = try await seedThreeZones(router, store)

        let both = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object([
                         "zones": .array([.object(["path": .string(Self.pingPath)])]),
                         "zonePatches": .array([
                             .object(["id": .string(ids[0].uuidString), "gain": .number(0.5)]),
                         ]),
                     ])]))
        #expect(both.error?.hasPrefix(
            "sampler takes exactly one of 'zones' or 'zonePatches', not both.") == true)
        // Nothing landed.
        #expect(store.tracks[0].instrument?.sampler?.zones.map(\.id) == ids)
        #expect(store.tracks[0].instrument?.sampler?.zones[0].gain == 1)
    }

    @Test("a malformed, unknown or duplicated zone id refuses by name and lands nothing")
    func zoneIDErrors() async throws {
        let (router, store) = makeRouter()
        let (instID, ids) = try await seedThreeZones(router, store)
        let stranger = UUID()

        func patch(_ patches: [JSONValue]) async -> ControlResponse {
            await router.handle(ControlRequest(
                id: "x", command: "track.setInstrument",
                params: ["trackId": .string(instID),
                         "sampler": .object(["zonePatches": .array(patches)])]))
        }

        // Not a UUID at all — the error names the field AND the value.
        let notUUID = await patch([.object(["id": .string("zone-2"), "gain": .number(0.5)])])
        #expect(notUUID.error == "sampler.zonePatches[0].id is not a valid UUID: \"zone-2\". "
            + "Send the id project.snapshot emitted for this zone, or omit 'id' to create a "
            + "NEW zone.")

        // Not a string.
        let notString = await patch([.object(["id": .number(2), "gain": .number(0.5)])])
        #expect(notString.error?.hasPrefix("sampler.zonePatches[0].id must be a UUID string")
            == true)

        // Well-formed but names no zone HERE — never a silent insert.
        let unknown = await patch([.object(["id": .string(stranger.uuidString),
                                            "gain": .number(0.5)])])
        #expect(unknown.error == "sampler.zonePatches[0].id \"\(stranger.uuidString)\" names no "
            + "zone on this track. Ids are per-track: omit 'id' on every zone to author a new "
            + "map or to copy one onto a DIFFERENT track, or re-read the current ids from "
            + "project.snapshot's instrument.sampler.zones[].id.")

        // The same id twice — the project file keys per-zone media by id, so a
        // duplicate would make two zones share one sample file on save.
        let duplicate = await patch([
            .object(["id": .string(ids[0].uuidString), "gain": .number(0.5)]),
            .object(["id": .string(ids[0].uuidString), "gain": .number(0.6)]),
        ])
        #expect(duplicate.error?.hasPrefix(
            "sampler.zonePatches[1].id \"\(ids[0].uuidString)\" appears more than once") == true)

        // A patch with no id at all.
        let noID = await patch([.object(["gain": .number(0.5)])])
        #expect(noID.error?.hasPrefix("sampler.zonePatches[0].id is required") == true)

        // Wrong container types.
        let notArray = await router.handle(ControlRequest(
            id: "y", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zonePatches": .string("nope")])]))
        #expect(notArray.error == "sampler.zonePatches must be an array")
        let notObject = await patch([.string("nope")])
        #expect(notObject.error == "sampler.zonePatches[0] must be an object")

        // Across every refusal above: the track is exactly as it was.
        let sampler = try #require(store.tracks[0].instrument?.sampler)
        #expect(sampler.zones.map(\.id) == ids)
        #expect(sampler.zones.allSatisfy { $0.gain == 1 })
    }

    @Test("the duplicate-id rule applies to the wholesale zones path too")
    func duplicateIDInZonesRefuses() async throws {
        let (router, store) = makeRouter()
        let (instID, ids) = try await seedThreeZones(router, store)

        let duplicate = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID),
                     "sampler": .object(["zones": .array([
                         .object(["id": .string(ids[0].uuidString),
                                  "path": .string(Self.pingPath)]),
                         .object(["id": .string(ids[0].uuidString),
                                  "path": .string(Self.pingPath)]),
                     ])])]))
        #expect(duplicate.error?.hasPrefix(
            "sampler.zones[1].id \"\(ids[0].uuidString)\" appears more than once") == true)
        #expect(store.tracks[0].instrument?.sampler?.zones.map(\.id) == ids)
    }

    // MARK: - m26-h provenance on the wire

    @Test("an imported library reports its source path and name; a hand-built one reports neither")
    func provenanceOnTheWire() async throws {
        let (router, store) = makeRouter()
        let instID = store.addTrack(kind: .instrument)

        // A hand-built sampler claims no provenance, and emits NEITHER key —
        // the pre-m26-h wire shape, byte for byte.
        let handBuilt = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(instID.id.uuidString), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath)]),
                     ])])]))
        #expect(handBuilt.ok)
        #expect(handBuilt.result?["sampler"]?["sourcePath"] == nil)
        #expect(handBuilt.result?["sampler"]?["name"] == nil)

        // Import a real library on the SAME track.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sampler-prov-wire-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.pingPath),
            to: dir.appendingPathComponent("ping.aiff"))
        let sfz = dir.appendingPathComponent("Session Bass.sfz")
        try Data("<region> sample=ping.aiff lokey=28 hikey=52\n".utf8).write(to: sfz)
        _ = try store.importSampleLibrary(trackID: instID.id, path: sfz.path)

        let snapshot = await router.handle(ControlRequest(id: "2", command: "project.snapshot"))
        let sampler = try #require(
            snapshot.result?["tracks"]?.arrayValue?.first?["instrument"]?["sampler"])
        #expect(sampler["sourcePath"]?.stringValue == sfz.path)
        #expect(sampler["name"]?.stringValue == "Session Bass")

        // A partial update must not erase it — this is the exact call from
        // finding 12, one knob on an imported library.
        let tweak = await router.handle(ControlRequest(
            id: "3", command: "track.setInstrument",
            params: ["trackId": .string(instID.id.uuidString),
                     "sampler": .object(["release": .number(0.4)])]))
        #expect(tweak.ok)
        #expect(tweak.result?["sampler"]?["sourcePath"]?.stringValue == sfz.path)
        #expect(tweak.result?["sampler"]?["name"]?.stringValue == "Session Bass")
        #expect(store.tracks[0].instrument?.sampler?.displayName == "Session Bass")

        // Echoing the emitted sampler object straight back is NOT an error —
        // unknown input keys stay ignored precisely so a read-modify-write
        // round trip cannot fail on the keys the reader just handed out.
        let echoed = await router.handle(ControlRequest(
            id: "4", command: "track.setInstrument",
            params: ["trackId": .string(instID.id.uuidString), "sampler": sampler]))
        #expect(echoed.ok)
        #expect(store.tracks[0].instrument?.sampler?.sourcePath == sfz.path)
    }

    // MARK: - instrument.describeSampler (m26-i)

    /// Wire surface of `instrument.describeSampler`: the read-only sibling of
    /// `au.describeParams` for the built-in Sampler, added because
    /// `project.snapshot` measured 296,809 bytes on the user's real song and
    /// the only other way to see "which library is loaded and how is it
    /// mapped" was eyeballing that whole payload.
    private func describeSampler(
        _ router: CommandRouter, _ trackID: String, offset: Double? = nil, limit: Double? = nil
    ) async -> ControlResponse {
        var params: [String: JSONValue] = ["trackId": .string(trackID)]
        if let offset { params["offset"] = .number(offset) }
        if let limit { params["limit"] = .number(limit) }
        return await router.handle(ControlRequest(
            id: "d", command: "instrument.describeSampler", params: params))
    }

    @Test("instrument.describeSampler rejects unknown parameter keys, even though this verb is read-only")
    func describeSamplerRejectsUnknownKeys() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.describeSampler",
            params: ["trackId": .string(trackID), "bogus": .bool(true)]))
        #expect(response.error?.contains("'bogus'") == true)
        #expect(response.error?.contains("instrument.describeSampler") == true)
    }

    @Test("instrument.describeSampler: an unknown track id refuses with noTrack")
    func describeSamplerUnknownTrackRefuses() async throws {
        let (router, _) = makeRouter()
        let response = await describeSampler(router, UUID().uuidString)
        #expect(response.error?.hasPrefix("no track with id") == true)
    }

    @Test("instrument.describeSampler: an audio track refuses with the SAME wording track.setInstrument already throws")
    func describeSamplerNonInstrumentTrackRefusesWithSharedWording() async throws {
        let (router, store) = makeRouter()
        let audioID = store.addTrack(kind: .audio).id.uuidString

        let describeResponse = await describeSampler(router, audioID)
        let setResponse = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(audioID), "kind": .string("sampler")]))

        #expect(describeResponse.error != nil)
        #expect(describeResponse.error == setResponse.error)
        #expect(describeResponse.error == "track kind 'audio' cannot host an instrument — "
            + "only instrument tracks carry an instrument (add one with track.add kind=instrument)")
    }

    @Test("instrument.describeSampler: a bus track refuses the same way")
    func describeSamplerBusTrackRefuses() async throws {
        let (router, store) = makeRouter()
        let busID = store.addTrack(kind: .bus).id.uuidString
        let response = await describeSampler(router, busID)
        #expect(response.error == "track kind 'bus' cannot host an instrument — "
            + "only instrument tracks carry an instrument (add one with track.add kind=instrument)")
    }

    @Test("instrument.describeSampler: an instrument track that never configured a sampler refuses with an actionable message")
    func describeSamplerNeverConfiguredRefuses() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        // Default instrument is polySynth; never touched `sampler`.
        let response = await describeSampler(router, trackID)
        #expect(response.error?.contains("has no sampler configured yet") == true)
        #expect(response.error?.contains("instrument.importSampleLibrary") == true)
        #expect(response.error?.contains("track.setInstrument") == true)
    }

    @Test("instrument.describeSampler: a sampler with zero zones (the deliberate `zones: []` clear) is a legal SUCCESS, not a refusal")
    func describeSamplerEmptySamplerSucceeds() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let seed = await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([])])]))
        #expect(seed.ok)

        let response = await describeSampler(router, trackID)
        #expect(response.ok, "empty sampler must describe cleanly: \(response.error ?? "")")
        #expect(response.result?["zoneSummary"]?["count"]?.doubleValue == 0)
        #expect(response.result?["zoneSummary"]?["pitchCoverage"] == nil)
        #expect(response.result?["zoneSummary"]?["velocityCoverage"] == nil)
        #expect(response.result?["zoneSummary"]?["groupCount"]?.doubleValue == 0)
        #expect(response.result?["zoneSummary"]?["distinctSampleFiles"]?.doubleValue == 0)
    }

    @Test("instrument.describeSampler: globals and no-paging summary for a single hand-built zone")
    func describeSamplerGlobalsAndSummaryForOneZone() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let seed = await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                         "oneShot": .bool(true), "attack": .number(0.02),
                         "release": .number(1.5), "gain": .number(0.6),
                         "zones": .array([
                             .object(["path": .string(Self.pingPath), "minPitch": .number(24),
                                     "maxPitch": .number(96)]),
                         ]),
                     ])]))
        #expect(seed.ok)

        let response = await describeSampler(router, trackID)
        #expect(response.ok)
        #expect(response.result?["trackId"]?.stringValue == trackID)
        #expect(response.result?["kind"]?.stringValue == "sampler")
        #expect(response.result?["oneShot"]?.boolValue == true)
        #expect(response.result?["attack"]?.doubleValue == 0.02)
        #expect(response.result?["release"]?.doubleValue == 1.5)
        #expect(response.result?["gain"]?.doubleValue == 0.6)
        #expect(response.result?["sourcePath"] == nil)
        #expect(response.result?["displayName"] == nil)

        let summary = try #require(response.result?["zoneSummary"])
        #expect(summary["count"]?.doubleValue == 1)
        #expect(summary["pitchCoverage"]?["min"]?.doubleValue == 24)
        #expect(summary["pitchCoverage"]?["max"]?.doubleValue == 96)
        #expect(summary["pitchCoverage"]?["gaps"] == nil)
        // No velocity range set anywhere -> nil folds to the FULL 0-127 span.
        #expect(summary["velocityCoverage"]?["min"]?.doubleValue == 0)
        #expect(summary["velocityCoverage"]?["max"]?.doubleValue == 127)
        #expect(summary["groupCount"]?.doubleValue == 1)
        #expect(summary["distinctSampleFiles"]?.doubleValue == 1)

        // No offset/limit given -> zones/offset/limit/returnedZones/truncated
        // are all ABSENT, not empty-defaulted.
        #expect(response.result?["zones"] == nil)
        #expect(response.result?["offset"] == nil)
        #expect(response.result?["limit"] == nil)
        #expect(response.result?["returnedZones"] == nil)
        #expect(response.result?["truncated"] == nil)
    }

    @Test("instrument.describeSampler: the response describes sampler config even when a DIFFERENT kind is now active")
    func describeSamplerDescribesRegardlessOfActiveKind() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath)]),
                     ])])])).ok)
        // Switch the ACTIVE instrument away from sampler — the sampler
        // config is documented to survive the switch (InstrumentDescriptor).
        #expect(await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("polySynth")])).ok)

        let response = await describeSampler(router, trackID)
        #expect(response.ok, "a read must not refuse where the write still preserves the config")
        #expect(response.result?["kind"]?.stringValue == "polySynth")
        #expect(response.result?["zoneSummary"]?["count"]?.doubleValue == 1)
    }

    @Test("instrument.describeSampler: an interior pitch gap between zone islands is reported, not hidden by the envelope")
    func describeSamplerPitchGapReported() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath), "minPitch": .number(0),
                                 "maxPitch": .number(34)]),
                         // A hole: 35-59 is uncovered.
                         .object(["path": .string(Self.pingPath), "minPitch": .number(60),
                                 "maxPitch": .number(90)]),
                     ])])])).ok)

        let response = await describeSampler(router, trackID)
        #expect(response.ok)
        let coverage = try #require(response.result?["zoneSummary"]?["pitchCoverage"])
        #expect(coverage["min"]?.doubleValue == 0)
        #expect(coverage["max"]?.doubleValue == 90)
        let gaps = try #require(coverage["gaps"]?.arrayValue)
        #expect(gaps.count == 1)
        #expect(gaps[0]["min"]?.doubleValue == 35)
        #expect(gaps[0]["max"]?.doubleValue == 59)
    }

    @Test("instrument.describeSampler: touching (adjacent) zones report NO gap")
    func describeSamplerTouchingZonesNoGap() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath), "minPitch": .number(0),
                                 "maxPitch": .number(59)]),
                         .object(["path": .string(Self.pingPath), "minPitch": .number(60),
                                 "maxPitch": .number(127)]),
                     ])])])).ok)

        let response = await describeSampler(router, trackID)
        let coverage = try #require(response.result?["zoneSummary"]?["pitchCoverage"])
        #expect(coverage["min"]?.doubleValue == 0)
        #expect(coverage["max"]?.doubleValue == 127)
        #expect(coverage["gaps"] == nil)
    }

    @Test("instrument.describeSampler: a velocity layering gap is reported, with nil defaulting to the full 0-127 span")
    func describeSamplerVelocityGapReported() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath), "minVelocity": .number(0),
                                 "maxVelocity": .number(40)]),
                         .object(["path": .string(Self.pingPath), "minVelocity": .number(100),
                                 "maxVelocity": .number(127)]),
                     ])])])).ok)

        let response = await describeSampler(router, trackID)
        let coverage = try #require(response.result?["zoneSummary"]?["velocityCoverage"])
        #expect(coverage["min"]?.doubleValue == 0)
        #expect(coverage["max"]?.doubleValue == 127)
        let gaps = try #require(coverage["gaps"]?.arrayValue)
        #expect(gaps.count == 1)
        #expect(gaps[0]["min"]?.doubleValue == 41)
        #expect(gaps[0]["max"]?.doubleValue == 99)
    }

    @Test("instrument.describeSampler: distinct sample files and group count are counted correctly")
    func describeSamplerDistinctFilesAndGroups() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let otherPath = "/System/Library/Sounds/Pop.aiff"
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath), "group": .number(0)]),
                         .object(["path": .string(Self.pingPath), "group": .number(1)]),
                         .object(["path": .string(otherPath)]),  // group omitted -> implicit 0
                     ])])])).ok)

        let response = await describeSampler(router, trackID)
        let summary = try #require(response.result?["zoneSummary"])
        #expect(summary["count"]?.doubleValue == 3)
        #expect(summary["groupCount"]?.doubleValue == 2)   // {0, 1}
        #expect(summary["distinctSampleFiles"]?.doubleValue == 2)
    }

    @Test("instrument.describeSampler: an imported library's sourcePath/displayName are surfaced; a hand-built sampler shows neither")
    func describeSamplerProvenanceSurfaced() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("describe-sampler-prov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.pingPath),
            to: dir.appendingPathComponent("ping.aiff"))
        let sfz = dir.appendingPathComponent("Upright Bass.sfz")
        try Data("<region> sample=ping.aiff lokey=28 hikey=52\n".utf8).write(to: sfz)
        _ = try store.importSampleLibrary(trackID: trackID.id, path: sfz.path)

        let response = await describeSampler(router, trackID.id.uuidString)
        #expect(response.ok)
        #expect(response.result?["sourcePath"]?.stringValue == sfz.path)
        #expect(response.result?["displayName"]?.stringValue == "Upright Bass")
    }

    @Test("instrument.describeSampler: offset/limit page the zone list; omitting both omits it entirely")
    func describeSamplerPaging() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let zones: [JSONValue] = (0..<5).map { i in
            .object(["path": .string(Self.pingPath), "rootPitch": .number(Double(i))])
        }
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array(zones)])])).ok)
        let allIDs = store.tracks[0].instrument?.sampler?.zones.map(\.id) ?? []
        #expect(allIDs.count == 5)

        // A page in the middle.
        let page = await describeSampler(router, trackID, offset: 1, limit: 2)
        #expect(page.ok)
        #expect(page.result?["offset"]?.doubleValue == 1)
        #expect(page.result?["limit"]?.doubleValue == 2)
        #expect(page.result?["returnedZones"]?.doubleValue == 2)
        #expect(page.result?["truncated"]?.boolValue == true)
        let pageZones = try #require(page.result?["zones"]?.arrayValue)
        #expect(pageZones.count == 2)
        #expect(pageZones.map { $0["id"]?.stringValue } == [allIDs[1].uuidString, allIDs[2].uuidString])

        // limit alone -> offset defaults to 0.
        let limitOnly = await describeSampler(router, trackID, limit: 3)
        #expect(limitOnly.result?["offset"]?.doubleValue == 0)
        #expect(limitOnly.result?["returnedZones"]?.doubleValue == 3)
        #expect(limitOnly.result?["truncated"]?.boolValue == true)

        // offset alone -> limit defaults to 500 (well above 5), so the rest
        // of the array comes back untruncated.
        let offsetOnly = await describeSampler(router, trackID, offset: 3)
        #expect(offsetOnly.result?["limit"]?.doubleValue == 500)
        #expect(offsetOnly.result?["returnedZones"]?.doubleValue == 2)
        #expect(offsetOnly.result?["truncated"]?.boolValue == false)

        // An offset past the end -> an empty, untruncated page (never an error).
        let past = await describeSampler(router, trackID, offset: 100)
        #expect(past.ok)
        #expect(past.result?["returnedZones"]?.doubleValue == 0)
        #expect(past.result?["truncated"]?.boolValue == false)
        #expect(past.result?["zones"]?.arrayValue?.isEmpty == true)
    }

    @Test("instrument.describeSampler: negative or non-integer offset/limit refuse readably")
    func describeSamplerPagingRefusals() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath)]),
                     ])])])).ok)

        let negativeOffset = await describeSampler(router, trackID, offset: -1)
        #expect(negativeOffset.error == "'offset' must be an integer >= 0")

        let fractionalOffset = await describeSampler(router, trackID, offset: 1.5)
        #expect(fractionalOffset.error == "'offset' must be an integer >= 0")

        let fractionalLimit = await describeSampler(router, trackID, limit: 2.5)
        #expect(fractionalLimit.error?.hasPrefix("'limit' must be an integer") == true)
    }

    @Test("instrument.describeSampler: limit clamps silently into 1...5000 rather than erroring")
    func describeSamplerLimitClamps() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath)]),
                     ])])])).ok)

        let hugeLimit = await describeSampler(router, trackID, offset: 0, limit: 999_999)
        #expect(hugeLimit.ok)
        #expect(hugeLimit.result?["limit"]?.doubleValue == 5_000)

        let zeroLimit = await describeSampler(router, trackID, offset: 0, limit: 0)
        #expect(zeroLimit.ok)
        #expect(zeroLimit.result?["limit"]?.doubleValue == 1)
    }
}
