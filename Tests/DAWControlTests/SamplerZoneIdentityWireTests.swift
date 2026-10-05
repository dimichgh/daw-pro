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

    // MARK: - effectiveGlobals (2026-08-20 field report)

    /// THE reported defect: `instrument.describeSampler` answered "release:
    /// 3.4465" for an instrument that audibly released in 0.5 s, because every
    /// imported zone carried its own `ampeg_release` and the engine prefers a
    /// zone's own value. The engine is right; the ANSWER was wrong — and wrong
    /// in this codebase's signature way, by returning something shaped exactly
    /// like a valid number.
    ///
    /// The top-level `release` deliberately still reports the stored global
    /// (additive-only: `project.snapshot` and every existing reader keep their
    /// byte shape). What is new is that it can no longer be read without
    /// `effectiveGlobals` beside it saying the global is not used and naming
    /// what is.
    @Test("instrument.describeSampler: a global release every zone overrides is reported as INERT, with the values that will actually be heard")
    func describeSamplerReportsInertGlobalRelease() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                         // The reporter's own numbers.
                         "release": .number(3.4465), "attack": .number(0.02),
                         "zones": .array([
                             .object(["path": .string(Self.pingPath), "minPitch": .number(0),
                                     "maxPitch": .number(59), "release": .number(0.5)]),
                             .object(["path": .string(Self.pingPath), "minPitch": .number(60),
                                     "maxPitch": .number(127), "release": .number(0.5)]),
                         ]),
                     ])])).ok)

        let response = await describeSampler(router, trackID)
        #expect(response.ok)
        // The stored global still reports, unchanged — additive-only.
        #expect(response.result?["release"]?.doubleValue == 3.4465)

        let release = try #require(response.result?["effectiveGlobals"]?["release"])
        #expect(release["global"]?.doubleValue == 3.4465)
        #expect(release["globalIsInert"]?.boolValue == true)
        #expect(release["zonesOverriding"]?.doubleValue == 2)
        #expect(release["zonesInheriting"]?.doubleValue == 0)
        // The answer to "then what WILL I hear".
        let values = try #require(release["effectiveValues"]?.arrayValue)
        #expect(values.count == 1)
        #expect(values[0].doubleValue == 0.5)
        #expect(release["effectiveMin"]?.doubleValue == 0.5)
        #expect(release["effectiveMax"]?.doubleValue == 0.5)
        #expect(release["effectiveValuesTruncated"] == nil)   // only-when-true
        // …and in prose, for a caller that reads the sentence and not the flag.
        let note = try #require(release["note"]?.stringValue)
        print("[measured] inert-release note: \(note)")
        #expect(note.contains("NOT"))
        #expect(note.contains("effectiveValues"))
        #expect(note.contains("zonePatches"))
        // Defect A (2026-08-20 sax-team round): the note is read by TWO
        // audiences. `sampler.zonePatches` is a real, working merge path over
        // the RAW control protocol (executed below and in
        // inertGlobalNoteRemedyIsExecutable), but `track_set_instrument`'s MCP
        // schema does NOT expose it — the only MCP tool that reaches it is
        // `instrument_set_sampler_zones`, which this note must name so an
        // MCP-only reader has a remedy they can actually follow.
        #expect(note.contains("instrument_set_sampler_zones"))
        // Defect C: this sampler was built BY HAND (no sourcePath at all) —
        // naming an SFZ opcode here would assert a provenance that never
        // happened, so none may appear.
        #expect(!note.contains("ampeg_release"))

        // Defect D: the top-level scalar keeps reporting the STORED value
        // (round-trip fidelity), so the sibling `warnings` array is what makes
        // the discrepancy impossible to miss for a caller who never descends
        // into `effectiveGlobals` at all — both the stored AND the actually-
        // applied number appear in the SAME sentence.
        let warnings = try #require(response.result?["warnings"]?.arrayValue).map {
            $0.stringValue ?? ""
        }
        print("[measured] top-level warnings: \(warnings)")
        let releaseWarning = try #require(warnings.first { $0.hasPrefix("release:") })
        #expect(releaseWarning.contains("3.4465"))
        #expect(releaseWarning.contains("0.5"))

        // ATTACK is release's twin at the same engine trigger site, and here no
        // zone overrides it — so the SAME response must call one global dead
        // and the other live. A blanket "inert" would pass the release
        // assertions above and fail this one.
        let attack = try #require(response.result?["effectiveGlobals"]?["attack"])
        #expect(attack["globalIsInert"]?.boolValue == false)
        #expect(attack["zonesInheriting"]?.doubleValue == 2)
        #expect(attack["effectiveValues"]?.arrayValue?.first?.doubleValue == 0.02)
        #expect(attack["note"] == nil)                        // nothing to warn about
        // Defect D's discriminator: only ONE global is inert here, so
        // `warnings` must carry exactly one entry, not one per field.
        #expect(warnings.count == 1)
    }

    /// The `note` on an inert global does not just say "this does nothing" — it
    /// prescribes a remedy, and a remedy that refuses is the same class of
    /// defect one layer out (an answer shaped exactly like a good one). So this
    /// test EXECUTES the sentence: it reads the note, performs the
    /// `sampler.zonePatches [{id, release}]` edit the note names, and asserts
    /// the reported effective value moves. Reading the parser and concluding
    /// the keys are accepted is not the same as watching the call land.
    @Test("instrument.describeSampler: the inert-global note prescribes a zonePatches edit that actually WORKS")
    func inertGlobalNoteRemedyIsExecutable() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                         "release": .number(3.4465),
                         "zones": .array([
                             .object(["path": .string(Self.pingPath), "release": .number(0.5)]),
                             .object(["path": .string(Self.pingPath), "release": .number(0.5)]),
                         ]),
                     ])])).ok)

        let before = await describeSampler(router, trackID)
        let note = try #require(before.result?["effectiveGlobals"]?["release"]?["note"]?.stringValue)
        #expect(note.contains("zonePatches"))

        // Do exactly what the note says, with ids read the way it says to.
        let page = await describeSampler(router, trackID, offset: 0, limit: 10)
        let zoneIDs = try #require(page.result?["zones"]?.arrayValue).map {
            $0["id"]?.stringValue ?? ""
        }
        #expect(zoneIDs.count == 2)
        let patch = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID),
                     "sampler": .object(["zonePatches": .array(zoneIDs.map {
                         .object(["id": .string($0), "release": .number(1.25)])
                     })])]))
        #expect(patch.ok, "the remedy the note prescribes must not refuse: \(patch.error ?? "")")

        // …and the report moves to the new number, still inert.
        let after = await describeSampler(router, trackID)
        let release = try #require(after.result?["effectiveGlobals"]?["release"])
        #expect(release["globalIsInert"]?.boolValue == true)
        #expect(release["effectiveValues"]?.arrayValue?.map { $0.doubleValue } == [1.25])
        // The global the note called dead is still exactly where it was — the
        // remedy changed the audio, not the stored knob.
        #expect(after.result?["release"]?.doubleValue == 3.4465)
    }

    /// The MIXED library — some zones overriding, some inheriting. This is the
    /// shape a single boolean cannot describe, and the shape that forces the
    /// computation to be real: an all-overriding fixture passes against a
    /// hardcoded `globalIsInert: true`.
    @Test("instrument.describeSampler: a partly-overridden global stays LIVE and the effective list names both values")
    func describeSamplerReportsMixedOverrides() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                         "release": .number(3.4465),
                         "zones": .array([
                             .object(["path": .string(Self.pingPath), "minPitch": .number(0),
                                     "maxPitch": .number(59), "release": .number(0.5)]),
                             // No release: this one still tracks the global.
                             .object(["path": .string(Self.pingPath), "minPitch": .number(60),
                                     "maxPitch": .number(127)]),
                         ]),
                     ])])).ok)

        let response = await describeSampler(router, trackID)
        let release = try #require(response.result?["effectiveGlobals"]?["release"])
        #expect(release["globalIsInert"]?.boolValue == false)
        #expect(release["zonesOverriding"]?.doubleValue == 1)
        #expect(release["zonesInheriting"]?.doubleValue == 1)
        let values = try #require(release["effectiveValues"]?.arrayValue)
        #expect(values.map { $0.doubleValue } == [0.5, 3.4465])
        // No inert claim, so no note — the global genuinely does something.
        #expect(release["note"] == nil)
        // Defect D's negative control: NOTHING is inert in this response (not
        // release, not attack, not oneShot), so the top-level `warnings` key
        // must be ABSENT, not an empty array — the A-imp-1 idiom this verb
        // already follows for effectiveValuesTruncated/effectiveGlobals
        // itself. This is the discriminating half of the gate: a `warnings`
        // key emitted UNCONDITIONALLY (regardless of whether any global is
        // actually inert) would pass every other assertion in this file and
        // fail only here.
        #expect(response.result?["warnings"] == nil)
    }

    /// A zero-zone sampler has no inheritance to describe, so the key is
    /// ABSENT rather than present-and-meaningless — the same rule
    /// `pitchCoverage`/`velocityCoverage` already follow. Calling that global
    /// "inert" would send a caller to fix the wrong thing: the sampler is
    /// silent because it has no zones.
    @Test("instrument.describeSampler: a zero-zone sampler omits effectiveGlobals entirely")
    func describeSamplerOmitsEffectiveGlobalsWithoutZones() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        #expect(await router.handle(ControlRequest(
            id: "0", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["release": .number(3.4465),
                                         "zones": .array([])])])).ok)
        let response = await describeSampler(router, trackID)
        #expect(response.ok)
        #expect(response.result?["release"]?.doubleValue == 3.4465)
        #expect(response.result?["effectiveGlobals"] == nil)
    }

    /// End-to-end over a REAL `.sfz` import, because "SFZ imports always do
    /// [carry their own release]" is the reporter's claim and a hand-built
    /// fixture cannot test it. `ampeg_release` in `<global>` is the ordinary
    /// way a library authors this, and it reaches every region.
    @Test("instrument.describeSampler: an imported SFZ with ampeg_release in <global> reports the sampler global as inert")
    func describeSamplerInertAfterRealSFZImport() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(kind: .instrument)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("describe-sampler-inert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.pingPath),
            to: dir.appendingPathComponent("ping.aiff"))
        let sfz = dir.appendingPathComponent("Tenor Sax.sfz")
        try Data("""
        <global> ampeg_release=0.5
        <region> sample=ping.aiff lokey=28 hikey=52
        <region> sample=ping.aiff lokey=53 hikey=76
        """.utf8).write(to: sfz)
        _ = try store.importSampleLibrary(trackID: track.id, path: sfz.path)

        // Now set the global the reporter saw. It is accepted and stored…
        #expect(await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(track.id.uuidString),
                     "sampler": .object(["release": .number(3.4465)])])).ok)

        let response = await describeSampler(router, track.id.uuidString)
        #expect(response.ok)
        #expect(response.result?["release"]?.doubleValue == 3.4465)   // …stored…
        let release = try #require(response.result?["effectiveGlobals"]?["release"])
        #expect(release["globalIsInert"]?.boolValue == true)          // …and dead
        #expect(release["zonesOverriding"]?.doubleValue == 2)
        #expect(release["effectiveValues"]?.arrayValue?.first?.doubleValue == 0.5)
        // Defect C's POSITIVE control: real SFZ provenance (`sourcePath` ends
        // in `.sfz`) IS reason enough to name the opcode a caller would find
        // if they opened the file.
        let note = try #require(release["note"]?.stringValue)
        #expect(note.contains("ampeg_release"))
    }

    /// Defect C's other half, over a REAL `.dspreset` import: `sourcePath` is
    /// set here too, but a `.dspreset` group's `release` attribute carries NO
    /// `ampeg_` prefix at all (DSPresetParser.swift) — so gating the opcode
    /// clause on `sourcePath` merely being non-nil (rather than on the file
    /// actually being `.sfz`) would misname this library's own inheritance
    /// mechanism. One `<group>` wraps BOTH samples so both zones inherit the
    /// SAME per-zone release from the group (nearest-wins merge), landing
    /// `zonesOverriding: 2, zonesInheriting: 0` — genuinely inert, same as the
    /// SFZ fixture above, but from a format with no opcode to quote.
    @Test("instrument.describeSampler: an imported .dspreset group release is inert too, but names no SFZ opcode")
    func describeSamplerInertAfterRealDSPresetImportNamesNoOpcode() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(kind: .instrument)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("describe-sampler-dspreset-inert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.pingPath),
            to: dir.appendingPathComponent("a.wav"))
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.pingPath),
            to: dir.appendingPathComponent("b.wav"))
        let dspreset = dir.appendingPathComponent("Tenor Sax.dspreset")
        try Data("""
        <DecentSampler>
          <groups>
            <group release="0.4">
              <sample path="a.wav" loNote="0" hiNote="63" rootNote="60"/>
              <sample path="b.wav" loNote="64" hiNote="127" rootNote="72"/>
            </group>
          </groups>
        </DecentSampler>
        """.utf8).write(to: dspreset)
        _ = try store.importSampleLibrary(trackID: track.id, path: dspreset.path)

        #expect(await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(track.id.uuidString),
                     "sampler": .object(["release": .number(3.4465)])])).ok)

        let response = await describeSampler(router, track.id.uuidString)
        #expect(response.ok)
        #expect(response.result?["sourcePath"]?.stringValue == dspreset.path)  // provenance IS set…
        let release = try #require(response.result?["effectiveGlobals"]?["release"])
        #expect(release["globalIsInert"]?.boolValue == true)                   // …and IS inert…
        #expect(release["zonesOverriding"]?.doubleValue == 2)
        let note = try #require(release["note"]?.stringValue)
        // …but this is not an SFZ, so no opcode is invented.
        #expect(!note.contains("ampeg_release"))
        #expect(!note.contains("ampeg"))
        #expect(note.contains("instrument_set_sampler_zones"))
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

    // MARK: - M32 new zone fields — THE FULL ROUND TRIP, one per field

    /// ⭐⭐ THE SIX-SITE GATE. A new `SamplerZone` field has to land in SIX
    /// places, and TWO of them fail SILENTLY:
    ///
    ///  1 `SamplerZone` + its clamping init ......... won't compile if missed
    ///  2 `parseZoneFields` + `makeZone` ............ unsettable via `zones`
    ///  3 ⚠️ `merge(_:into:)` ....................... SILENT: sets via `zones`,
    ///                                                NO-OPS via `zonePatches`
    ///  4 ⚠️ `SamplerZoneDocument` (property, ....... SILENT: parses, plays,
    ///       `CodingKeys`, BOTH converters)           then VANISHES on save
    ///  5 `samplerZoneSchema` (mcp-server) .......... MCP rejects the key
    ///  6 `samplerZoneJSON` echo .................... unreadable after setting
    ///
    /// Nothing smaller than ONE FULL ROUND TRIP — `zones` → save → open →
    /// `describeSampler` → `zonePatches` → `describeSampler` — walks all six.
    /// A test that only sets and reads back passes with 3 AND 4 missing.
    ///
    /// ⚠️ `zonePatches` is a FIELD of `track.setInstrument`'s `sampler` object,
    /// not a verb of its own.
    private func roundTripZoneField(
        set setValue: JSONValue, then patchValue: JSONValue,
        key: String,
        modelReads: @escaping (SamplerZone) -> JSONValue?,
        file: String = #file
    ) async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString

        // 1. SET through the wholesale `zones` path.
        let set = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath), key: setValue]),
                     ])])]))
        #expect(set.ok, "setting \(key) failed: \(set.error ?? "-")")
        #expect(set.result?["sampler"]?["zones"]?.arrayValue?.first?[key] == setValue,
                "the echo did not report \(key) — site 6")

        // 2. SAVE and REOPEN. `ProjectBundle.planMedia` copies each zone's
        //    source into the bundle, so the path must really exist; Ping.aiff
        //    does.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32-zonefield-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("field.dawproj").path
        let saved = await router.handle(ControlRequest(
            id: "2", command: "project.save", params: ["path": .string(path)]))
        #expect(saved.ok, "save failed: \(saved.error ?? "-")")
        let opened = await router.handle(ControlRequest(
            id: "3", command: "project.open", params: ["path": .string(path)]))
        #expect(opened.ok, "open failed: \(opened.error ?? "-")")

        // 3. The REOPENED model still carries it — site 4.
        let reopened = try #require(store.tracks.first { $0.instrument?.kind == .sampler })
        let reopenedZone = try #require(reopened.instrument?.sampler?.zones.first)
        #expect(modelReads(reopenedZone) == setValue,
                "\(key) did not survive save/open — SamplerZoneDocument (site 4)")

        // 4. …and `describeSampler` reports it. (`zones` is emitted only when
        //    offset/limit are supplied.)
        let described = await describeSampler(router, reopened.id.uuidString, offset: 0, limit: 8)
        #expect(described.ok)
        #expect(described.result?["zones"]?.arrayValue?.first?[key] == setValue)

        // 5. CHANGE it through the merge-by-id `zonePatches` path — site 3,
        //    the one that no-ops silently when `merge(_:into:)` forgets a field.
        let patched = await router.handle(ControlRequest(
            id: "4", command: "track.setInstrument",
            params: ["trackId": .string(reopened.id.uuidString), "kind": .string("sampler"),
                     "sampler": .object(["zonePatches": .array([
                         .object(["id": .string(reopenedZone.id.uuidString), key: patchValue]),
                     ])])]))
        #expect(patched.ok, "patching \(key) failed: \(patched.error ?? "-")")

        // 6. …and the change is really there.
        let redescribed = await describeSampler(router, reopened.id.uuidString, offset: 0, limit: 8)
        #expect(redescribed.result?["zones"]?.arrayValue?.first?[key] == patchValue, """
            zonePatches did not change \(key) — this is the SILENT failure: \
            `merge(_:into:)` (site 3) does not know the field, so the patch parsed, \
            reported success, and changed nothing.
            """)
        let patchedZone = try #require(
            store.tracks.first { $0.instrument?.kind == .sampler }?
                .instrument?.sampler?.zones.first)
        #expect(modelReads(patchedZone) == patchValue)
        #expect(patchedZone.id == reopenedZone.id, "the patch re-minted the zone id")
    }

    @Test("m32-d: `reverse` survives zones → save → open → describeSampler → zonePatches")
    func reverseFieldMakesTheFullRoundTrip() async throws {
        try await roundTripZoneField(set: .bool(true), then: .bool(false), key: "reverse",
                                     modelReads: { $0.reverse.map(JSONValue.bool) })
    }

    @Test("m32-f: `chokeGroup` survives zones → save → open → describeSampler → zonePatches")
    func chokeGroupFieldMakesTheFullRoundTrip() async throws {
        try await roundTripZoneField(set: .number(3), then: .number(9), key: "chokeGroup",
                                     modelReads: { $0.chokeGroup.map { .number(Double($0)) } })
    }

    @Test("m32-f: `chokeGroup` clamps into 0...63 through the model, on BOTH zone paths")
    func chokeGroupClampsOnBothPaths() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let set = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath), "chokeGroup": .number(9_999)]),
                     ])])]))
        #expect(set.ok)
        #expect(set.result?["sampler"]?["zones"]?.arrayValue?.first?["chokeGroup"]?.doubleValue == 63)

        // The merge path must reach the SAME state — a patch must not be able
        // to reach a value the wholesale path cannot.
        let zoneID = try #require(store.tracks.first { $0.id.uuidString == trackID }?
            .instrument?.sampler?.zones.first?.id)
        let patched = await router.handle(ControlRequest(
            id: "2", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zonePatches": .array([
                         .object(["id": .string(zoneID.uuidString),
                                  "chokeGroup": .number(-4)]),
                     ])])]))
        #expect(patched.ok)
        #expect(patched.result?["sampler"]?["zones"]?.arrayValue?.first?["chokeGroup"]?.doubleValue == 0)
    }

    @Test("m32-d: `reverse` must be a boolean, and the error names the field path")
    func reverseRejectsNonBoolean() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let bad = await router.handle(ControlRequest(
            id: "1", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath),
                                  "reverse": .string("yes")]),
                     ])])]))
        #expect(!bad.ok)
        #expect(bad.error?.contains("sampler.zones[0].reverse") == true,
                "error did not name the field path: \(bad.error ?? "-")")
    }

    // MARK: - W7-SMP: the SETTER says when the global it just wrote is inert

    // The sax-team ② record's first open item (2026-08-20): the 3.4465 s release
    // never came from the importer — it arrived through `track.setInstrument`,
    // which ACCEPTED and STORED a global the engine never reads and replied
    // success without a word. The write is deliberately unchanged (a later zone
    // edit can make the global heard again); what changed is that the reply now
    // carries describeSampler's OWN sentence for the globals this call named or
    // made inert.

    /// Seeds a two-zone sampler over the wire whose zones BOTH carry
    /// `field: value`, or — with `inheritingSecond` — only the first does (the
    /// second still hears the global). Returns the track id.
    private func seedOverriding(
        _ router: CommandRouter, _ store: ProjectStore,
        field: String, value: JSONValue, inheritingSecond: Bool = false
    ) async throws -> String {
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        var second: [String: JSONValue] = ["path": .string(Self.pingPath), "minPitch": .number(60)]
        if !inheritingSecond { second[field] = value }
        let seeded = await router.handle(ControlRequest(
            id: "seed", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath), "maxPitch": .number(59),
                                  field: value]),
                         .object(second),
                     ])])]))
        #expect(seeded.ok, "seed \(field): \(seeded.error ?? "")")
        // A seed whose second zone still inherits makes nothing inert, so it
        // stays quiet. Since round 2, a seed where BOTH zones override DOES
        // warn, because that zones write is what makes the global inert;
        // `setterWarnsWhenAZonesWriteMakesAGlobalInert` pins that sentence.
        if inheritingSecond {
            #expect(seeded.result?["warnings"] == nil,
                    "seed \(field): \(stringArray(seeded.result?["warnings"]))")
        }
        return trackID
    }

    private func setSamplerGlobal(
        _ router: CommandRouter, _ trackID: String, _ payload: [String: JSONValue]
    ) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "set", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "sampler": .object(payload)]))
    }

    private func stringArray(_ value: JSONValue?) -> [String] {
        (value?.arrayValue ?? []).map { $0.stringValue ?? "<non-string>" }
    }

    /// THE REPORTER'S OWN PATH, end to end: an SFZ whose `<global>` authors
    /// `ampeg_release`, imported, then the global set to the reported 3.4465 s.
    @Test("W7-SMP: an inert release written through track.setInstrument is stored AND warned about, in describeSampler's own words")
    func setterWarnsOnInertReleaseAfterSFZImport() async throws {
        let (router, store) = makeRouter()
        let track = store.addTrack(kind: .instrument)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setter-inert-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: Self.pingPath),
            to: dir.appendingPathComponent("ping.aiff"))
        let sfz = dir.appendingPathComponent("Tenor Sax.sfz")
        try Data("""
        <global> ampeg_release=0.5
        <region> sample=ping.aiff lokey=28 hikey=52
        <region> sample=ping.aiff lokey=53 hikey=76
        """.utf8).write(to: sfz)
        _ = try store.importSampleLibrary(trackID: track.id, path: sfz.path)

        let set = await setSamplerGlobal(router, track.id.uuidString,
                                         ["release": .number(3.4465)])
        #expect(set.ok)
        // The WRITE is unchanged: accepted, stored, echoed.
        #expect(set.result?["sampler"]?["release"]?.doubleValue == 3.4465)
        #expect(store.tracks.first { $0.id == track.id }?.instrument?.sampler?.release == 3.4465)

        // …and the reply now says it will not be heard.
        let warnings = stringArray(set.result?["warnings"])
        print("[measured] setter warnings: \(warnings)")
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("3.4465") == true)
        #expect(warnings.first?.contains("0.5") == true)

        // ONE HOME: the setter's sentence IS describeSampler's, character for
        // character — not a second wording that can drift from the first.
        let describe = await describeSampler(router, track.id.uuidString)
        let describeRelease = try #require(
            stringArray(describe.result?["warnings"]).first { $0.hasPrefix("release:") })
        #expect(warnings == [describeRelease])

        // The sentence says "See effectiveGlobals.release" — so that key rides
        // in THIS reply, in describe's exact shape, carrying the per-zone fix.
        let release = try #require(set.result?["effectiveGlobals"]?["release"])
        #expect(release["globalIsInert"]?.boolValue == true)
        #expect(release == describe.result?["effectiveGlobals"]?["release"])
        #expect(release["note"]?.stringValue?.contains("instrument_set_sampler_zones") == true)
    }

    /// The census, one global at a time: every field a zone can override
    /// (engine precedence — `SamplerInstrument`'s `-1` inherit sentinel for the
    /// four envelope stages, the −1/0/1 override for one-shot) warns at the
    /// setter, in the sentence describeSampler uses for THAT field.
    @Test("W7-SMP: attack, decay, sustain, release and oneShot each warn at the setter when every zone overrides them")
    func setterWarnsForEveryCensusGlobal() async throws {
        let census: [(field: String, zone: JSONValue, write: JSONValue)] = [
            ("attack", .number(0.3), .number(0.02)),
            ("decay", .number(1.5), .number(4)),
            ("sustain", .number(0.25), .number(0)),
            ("release", .number(0.5), .number(3.4465)),
            ("oneShot", .bool(true), .bool(false)),
        ]
        for entry in census {
            let (router, store) = makeRouter()
            let trackID = try await seedOverriding(router, store, field: entry.field,
                                                   value: entry.zone)
            let set = await setSamplerGlobal(router, trackID, [entry.field: entry.write])
            #expect(set.ok, "\(entry.field): \(set.error ?? "")")
            let warnings = stringArray(set.result?["warnings"])
            #expect(warnings.count == 1, "\(entry.field): \(warnings)")

            let describe = await describeSampler(router, trackID)
            let own = stringArray(describe.result?["warnings"])
                .first { $0.hasPrefix("\(entry.field):") }
            #expect(own != nil, "\(entry.field): describeSampler did not call it inert")
            #expect(warnings == [own ?? "<describe had none>"],
                    "\(entry.field): the setter's sentence is not describeSampler's")
            #expect(set.result?["effectiveGlobals"]?[entry.field]?["globalIsInert"]?.boolValue
                    == true, "\(entry.field)")
        }
    }

    /// The NON-INERT CONTROL: one zone still inherits the global, so the value
    /// written is genuinely heard, and the reply must stay exactly as it was
    /// before W7-SMP — no `warnings`, no `effectiveGlobals`. Then, on the SAME
    /// track, the last inheriting zone gets its own release. That patch warns
    /// (round 2: it is the write that MAKES release inert), and the very same
    /// global write warns: the silence above was a verdict, not a blind spot.
    @Test("W7-SMP control: a global one zone still inherits is live — no warnings, no effectiveGlobals — until that zone overrides it too")
    func setterStaysQuietWhileTheGlobalIsLive() async throws {
        let (router, store) = makeRouter()
        let trackID = try await seedOverriding(router, store, field: "release",
                                               value: .number(0.5), inheritingSecond: true)
        let live = await setSamplerGlobal(router, trackID, ["release": .number(2)])
        #expect(live.ok)
        #expect(live.result?["sampler"]?["release"]?.doubleValue == 2)
        #expect(live.result?["warnings"] == nil,
                "a live global must not warn: \(stringArray(live.result?["warnings"]))")
        #expect(live.result?["effectiveGlobals"] == nil)

        let secondZone = try #require(
            store.tracks.first { $0.id.uuidString == trackID }?.instrument?.sampler?.zones.last?.id)
        let patch = await setSamplerGlobal(router, trackID, ["zonePatches": .array([
            .object(["id": .string(secondZone.uuidString), "release": .number(0.5)]),
        ])])
        #expect(patch.ok)
        let patchWarnings = stringArray(patch.result?["warnings"])
        #expect(patchWarnings.count == 1 && patchWarnings.first?.hasPrefix("release:") == true,
                "the patch that takes the last inheriting zone makes release inert: \(patchWarnings)")
        let inert = await setSamplerGlobal(router, trackID, ["release": .number(2)])
        #expect(stringArray(inert.result?["warnings"]).count == 1,
                "positive control: the same write on the now all-overriding sampler warns")
    }

    /// THE NOISE RULE (m27-b's, one block up in the same reply): only the
    /// globals THIS call wrote may warn. Every zone overrides `release` here, so
    /// a write that touches gain, a live sibling, or a zone must leave the reply
    /// shape untouched — a warning on every call is a warning nobody reads.
    @Test("W7-SMP noise rule: gain, a live sibling global, or a zone patch never warn about an inert release they did not write")
    func setterWarnsOnlyAboutWhatItWrote() async throws {
        let (router, store) = makeRouter()
        let trackID = try await seedOverriding(router, store, field: "release", value: .number(0.5))
        let firstZone = try #require(
            store.tracks.first { $0.id.uuidString == trackID }?.instrument?.sampler?.zones.first?.id)
        let quietPayloads: [[String: JSONValue]] = [
            ["gain": .number(0.4)],                    // multiplies, never inert
            ["attack": .number(0.01)],                 // no zone overrides attack: LIVE
            ["zonePatches": .array([
                .object(["id": .string(firstZone.uuidString), "tuneCents": .number(5)]),
            ])],
        ]
        for payload in quietPayloads {
            let set = await setSamplerGlobal(router, trackID, payload)
            #expect(set.ok, "\(payload.keys.sorted()): \(set.error ?? "")")
            #expect(set.result?["warnings"] == nil,
                    "\(payload.keys.sorted()): \(stringArray(set.result?["warnings"]))")
            #expect(set.result?["effectiveGlobals"] == nil)
        }
        // Positive control on the SAME sampler: writing the inert one warns.
        let loud = await setSamplerGlobal(router, trackID, ["release": .number(1)])
        #expect(stringArray(loud.result?["warnings"]).count == 1)
    }

    /// One reply can owe TWO kinds of warning — a controller lane whose meaning
    /// changed (m27-b) and an inert global (W7-SMP). They share ONE `warnings`
    /// array, controller first; neither may overwrite the other.
    @Test("W7-SMP: controller-lane and inert-global warnings share one `warnings` array, neither overwriting the other")
    func setterMergesWithControllerWarnings() async throws {
        let (router, _) = makeRouter()
        let added = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(added.result?["id"]?.stringValue)
        let clip = await router.handle(ControlRequest(
            id: "m", command: "clip.addMIDI", params: ["trackId": .string(trackID)]))
        let clipID = try #require(clip.result?["id"]?.stringValue)
        let lane = await router.handle(ControlRequest(
            id: "l", command: "clip.setControllerLane", params: [
                "clipId": .string(clipID), "type": .string("cc"),
                "controller": .number(11),
                "points": .array([.object(["beat": .number(0), "value": .number(90)])]),
            ]))
        #expect(lane.ok)

        // ONE call: poly synth → sampler (its CC11 lane becomes live, m27-b)
        // AND a release every new zone overrides (W7-SMP).
        let set = await router.handle(ControlRequest(
            id: "s", command: "track.setInstrument", params: [
                "trackId": .string(trackID), "kind": .string("sampler"),
                "sampler": .object([
                    "release": .number(3.4465),
                    "zones": .array([
                        .object(["path": .string(Self.pingPath), "maxPitch": .number(59),
                                 "release": .number(0.5)]),
                        .object(["path": .string(Self.pingPath), "minPitch": .number(60),
                                 "release": .number(0.5)]),
                    ]),
                ]),
            ]))
        #expect(set.ok)
        let warnings = stringArray(set.result?["warnings"])
        print("[measured] merged warnings: \(warnings)")
        #expect(warnings.count == 2)
        #expect(warnings.first?.contains("CC11") == true, "the controller warning comes first")
        #expect(warnings.last?.hasPrefix("release:") == true, "then the inert-global warning")
        #expect(set.result?["effectiveGlobals"]?["release"]?["globalIsInert"]?.boolValue == true)
    }

    // MARK: - W7-SMP round 2: the echo, and two writes that used to reply in silence

    /// Item 2. m34-o made the sampler's GLOBAL `decay`/`sustain` settable, but
    /// the setter's reply and `project.snapshot` (both built by
    /// `instrumentJSON`) never echoed them, so a caller could not read back
    /// what it had just set. They now ride only when SET, so a sampler that
    /// never set them keeps its wire shape.
    @Test("W7-SMP r2: the setter's reply and project.snapshot echo the global decay and sustain once set, and omit them until then")
    func setterAndSnapshotEchoGlobalDecaySustain() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let plain = await router.handle(ControlRequest(
            id: "plain", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object(["zones": .array([
                         .object(["path": .string(Self.pingPath)]),
                     ])])]))
        #expect(plain.ok, "\(plain.error ?? "")")
        #expect(plain.result?["sampler"]?["decay"] == nil, "never set: no key")
        #expect(plain.result?["sampler"]?["sustain"] == nil, "never set: no key")

        let set = await setSamplerGlobal(router, trackID,
                                         ["decay": .number(2.5), "sustain": .number(0.3)])
        #expect(set.ok, "\(set.error ?? "")")
        #expect(set.result?["sampler"]?["decay"]?.doubleValue == 2.5)
        #expect(set.result?["sampler"]?["sustain"]?.doubleValue == 0.3)
        let stored = store.tracks.first { $0.id.uuidString == trackID }?.instrument?.sampler
        #expect(stored?.decay == 2.5 && stored?.sustain == 0.3,
                "the echo reports what the store holds")

        let snapshot = await router.handle(ControlRequest(id: "snap", command: "project.snapshot"))
        #expect(snapshot.ok)
        let snapTracks = try #require(snapshot.result?["tracks"]?.arrayValue)
        let snapTrack = try #require(snapTracks.first { $0["id"]?.stringValue == trackID })
        #expect(snapTrack["instrument"]?["sampler"]?["decay"]?.doubleValue == 2.5)
        #expect(snapTrack["instrument"]?["sampler"]?["sustain"]?.doubleValue == 0.3)

        // An unrelated write keeps them (the sampler object overlays onto the
        // current one), and the echo shows that too.
        let gain = await setSamplerGlobal(router, trackID, ["gain": .number(0.5)])
        #expect(gain.result?["sampler"]?["decay"]?.doubleValue == 2.5)
        #expect(gain.result?["sampler"]?["sustain"]?.doubleValue == 0.3)
    }

    /// Item 3a. Round 1 warned only about a global the payload NAMED. A `zones`
    /// write where every zone sets its own value makes that global inert just
    /// as surely, and used to reply in silence. It now warns, in
    /// describeSampler's own sentence, about the global it made inert.
    @Test("W7-SMP r2: a zones write that leaves no zone inheriting a global warns about THAT global, in describeSampler's words")
    func setterWarnsWhenAZonesWriteMakesAGlobalInert() async throws {
        let census: [(field: String, zone: JSONValue)] = [
            ("attack", .number(0.3)), ("decay", .number(1.5)), ("sustain", .number(0.25)),
            ("release", .number(0.5)), ("oneShot", .bool(true)),
        ]
        for entry in census {
            let (router, store) = makeRouter()
            let trackID = store.addTrack(kind: .instrument).id.uuidString
            let seeded = await router.handle(ControlRequest(
                id: "seed", command: "track.setInstrument",
                params: ["trackId": .string(trackID), "kind": .string("sampler"),
                         "sampler": .object(["zones": .array([
                             .object(["path": .string(Self.pingPath), "maxPitch": .number(59),
                                      entry.field: entry.zone]),
                             .object(["path": .string(Self.pingPath), "minPitch": .number(60),
                                      entry.field: entry.zone]),
                         ])])]))
            #expect(seeded.ok, "\(entry.field): \(seeded.error ?? "")")
            let warnings = stringArray(seeded.result?["warnings"])
            let describe = await describeSampler(router, trackID)
            let own = stringArray(describe.result?["warnings"])
                .first { $0.hasPrefix("\(entry.field):") }
            #expect(own != nil, "\(entry.field): describeSampler did not call it inert")
            #expect(warnings == [own ?? "<describe had none>"],
                    "\(entry.field): the zones write's warning is not describeSampler's sentence")
            #expect(seeded.result?["effectiveGlobals"]?[entry.field]?["globalIsInert"]?.boolValue
                    == true, "\(entry.field)")
        }
    }

    /// Item 3a, the patch path. The zonePatches write that takes the LAST
    /// inheriting zone is the one that makes the global inert, so it is the one
    /// that warns. Later zone writes on the already-inert sampler do not repeat
    /// it (the noise rule), and a write that hands a zone back stays quiet.
    @Test("W7-SMP r2: patching the LAST inheriting zone warns once; a later patch, and a write that hands a zone back, stay quiet")
    func setterWarnsWhenAPatchTakesTheLastInheritingZone() async throws {
        let (router, store) = makeRouter()
        let trackID = try await seedOverriding(router, store, field: "release",
                                               value: .number(0.5), inheritingSecond: true)
        let secondZone = try #require(
            store.tracks.first { $0.id.uuidString == trackID }?.instrument?.sampler?.zones.last?.id)
        let patch = await setSamplerGlobal(router, trackID, ["zonePatches": .array([
            .object(["id": .string(secondZone.uuidString), "release": .number(0.5)]),
        ])])
        #expect(patch.ok, "\(patch.error ?? "")")
        let warnings = stringArray(patch.result?["warnings"])
        let describe = await describeSampler(router, trackID)
        let describeRelease = stringArray(describe.result?["warnings"])
            .filter { $0.hasPrefix("release:") }
        #expect(describeRelease.count == 1)
        #expect(warnings == describeRelease, "the patch's warning is not describeSampler's sentence")
        #expect(patch.result?["effectiveGlobals"]?["release"]?["globalIsInert"]?.boolValue == true)

        // NOISE: release was ALREADY inert before this patch, so it does not repeat.
        let again = await setSamplerGlobal(router, trackID, ["zonePatches": .array([
            .object(["id": .string(secondZone.uuidString), "release": .number(0.7)]),
        ])])
        #expect(again.ok)
        #expect(again.result?["warnings"] == nil, "\(stringArray(again.result?["warnings"]))")
        #expect(again.result?["effectiveGlobals"] == nil)

        // A zones write that hands zone two back to the global makes release LIVE.
        let handBack = await setSamplerGlobal(router, trackID, ["zones": .array([
            .object(["path": .string(Self.pingPath), "maxPitch": .number(59),
                     "release": .number(0.5)]),
            .object(["path": .string(Self.pingPath), "minPitch": .number(60)]),
        ])])
        #expect(handBack.ok)
        #expect(handBack.result?["warnings"] == nil, "\(stringArray(handBack.result?["warnings"]))")
    }

    /// Item 3b. describeSampler has warned since m34-t that a glide on a POLY
    /// sampler is ignored, while the setter that STORED that glide replied in
    /// silence. The setter now warns when its payload names `glideTime` or
    /// `voiceMode`, the two fields that can put a stored glide under poly, in
    /// describe's own sentence, from the one function both verbs call.
    @Test("W7-SMP r2: the setter warns about a glide it stores under poly, in describeSampler's words, only when the write named the glide or the voice mode")
    func setterWarnsAboutAGlideStoredUnderPoly() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let set = await router.handle(ControlRequest(
            id: "glide", command: "track.setInstrument",
            params: ["trackId": .string(trackID), "kind": .string("sampler"),
                     "sampler": .object([
                         "zones": .array([.object(["path": .string(Self.pingPath)])]),
                         "glideTime": .number(0.3),
                     ])]))
        #expect(set.ok, "\(set.error ?? "")")
        #expect(set.result?["sampler"]?["glideTime"]?.doubleValue == 0.3, "the write is unchanged")
        let warnings = stringArray(set.result?["warnings"])
        let describe = await describeSampler(router, trackID)
        let describeGlide = stringArray(describe.result?["warnings"])
            .filter { $0.hasPrefix("glideTime is") }
        #expect(describeGlide.count == 1)
        #expect(warnings == describeGlide, "the setter's glide sentence is not describeSampler's")
        // A glide is not a zone-overridable global: no effectiveGlobals rides with it.
        #expect(set.result?["effectiveGlobals"] == nil)

        // CONTROL: legato makes the glide heard, and that write is quiet.
        let legato = await setSamplerGlobal(router, trackID, ["voiceMode": .string("legato")])
        #expect(legato.ok)
        #expect(legato.result?["warnings"] == nil, "\(stringArray(legato.result?["warnings"]))")
        // Back to poly: the write that makes the stored glide inert warns again.
        let poly = await setSamplerGlobal(router, trackID, ["voiceMode": .string("poly")])
        #expect(stringArray(poly.result?["warnings"]) == describeGlide)
        // NOISE: a write that names neither field does not repeat it.
        let gain = await setSamplerGlobal(router, trackID, ["gain": .number(0.5)])
        #expect(gain.result?["warnings"] == nil, "\(stringArray(gain.result?["warnings"]))")

        // Not gated on zones, because describe's warning is not: a zoneless
        // sampler's poly glide is just as inert.
        let bareID = store.addTrack(kind: .instrument).id.uuidString
        let bare = await router.handle(ControlRequest(
            id: "bare", command: "track.setInstrument",
            params: ["trackId": .string(bareID), "kind": .string("sampler"),
                     "sampler": .object(["glideTime": .number(0.3)])]))
        #expect(bare.ok, "\(bare.error ?? "")")
        #expect(stringArray(bare.result?["warnings"]) == describeGlide)
    }
}
