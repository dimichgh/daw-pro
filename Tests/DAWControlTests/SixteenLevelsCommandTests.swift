import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m39-levels-2 wire: control-protocol coverage for `instrument.spreadSlice`
/// (leg 1, `ProjectStore.addSixteenLevelsSpread`) and
/// `instrument.setSpreadDirection` (leg 2, `ProjectStore.setSixteenLevelsDirection`)
/// — SIXTEEN LEVELS' two deferred wire legs. See `Sources/DAWCore/
/// SixteenLevels.swift`'s file header for the design rule (ADD a zone, never
/// edit one) both verbs are thin wire wrappers over.
///
/// Happy paths (default "up", explicit "centered"), every named refusal
/// (`notASampler`, `zoneNotFound`, `noFreeWindow`, `notASpread`), the honest
/// `changed:false` no-op, unknown-key and bad-direction teaching errors on
/// both verbs, `instrument.describeSampler`'s additive `spreadDirection`
/// field, and a round-trip proof that a spread made over the wire is FIELD-
/// FOR-FIELD the same zone `SixteenLevels.zone(from:base:direction:)` — the
/// pure function the pad grid itself calls — would have built by hand.
@MainActor
@Suite("Sixteen Levels — control protocol (m39-levels-2 wire)")
struct SixteenLevelsCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private static let sample = BundledSamples.catalog[0]

    /// Adds an instrument track with ONE sampler zone — the bundled test tone,
    /// one key wide (`minPitch == maxPitch == rootPitch`, the chopper's own
    /// shape) — the slice a spread is made FROM. Returns wire ids.
    private func addTrackWithOneSlice(_ router: CommandRouter) async throws
        -> (trackID: String, zoneID: String) {
        let addTrack = await router.handle(ControlRequest(
            id: "t", command: "track.add", params: ["kind": .string("instrument")]))
        let trackID = try #require(addTrack.result?["id"]?.stringValue)
        let setInstrument = await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument",
            params: [
                "trackId": .string(trackID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([
                        .object([
                            "path": .string(Self.sample.wireName),
                            "rootPitch": .number(Double(Self.sample.rootPitch)),
                            // Explicit, not omitted: an OMITTED minPitch/maxPitch
                            // defaults to the full 0...127 span (SamplerZone's own
                            // documented default for a hand-authored zone), which
                            // would leave no free sixteen-key window anywhere and
                            // make every spread in this file refuse with
                            // noFreeWindow. One key wide — minPitch == maxPitch ==
                            // rootPitch — is the CHOPPER's own shape
                            // (SliceToSampler.swift), reproduced by hand here.
                            "minPitch": .number(Double(Self.sample.rootPitch)),
                            "maxPitch": .number(Double(Self.sample.rootPitch)),
                        ]),
                    ]),
                ]),
            ]))
        #expect(setInstrument.ok, "\(setInstrument.error ?? "")")
        let zoneID = try #require(setInstrument.result?["sampler"]?["zones"]?
            .arrayValue?.first?["id"]?.stringValue)
        return (trackID, zoneID)
    }

    // ── instrument.spreadSlice ──────────────────────────────────────────────

    @Test("default direction is up: the slice's own pitch is the LOWEST of the sixteen")
    func spreadSliceDefaultsToUp() async throws {
        let (router, store) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID)]))
        #expect(response.ok, "\(response.error ?? "")")
        let result = try #require(response.result)
        #expect(result["spreadDirection"]?.stringValue == "up")
        let newZoneID = try #require(result["id"]?.stringValue)
        #expect(newZoneID != zoneID, "spreadSlice ADDS a zone; it never returns the source's own id")
        let minPitch = try #require(result["minPitch"]?.doubleValue)
        let maxPitch = try #require(result["maxPitch"]?.doubleValue)
        let rootPitch = try #require(result["rootPitch"]?.doubleValue)
        #expect(maxPitch - minPitch == 15, "sixteen keys, inclusive")
        #expect(rootPitch == minPitch, "'up': the slice's own pitch is the LOWEST of the sixteen")

        // ADDS one zone; edits none — the source slice is untouched.
        let sampler = try #require(store.tracks[0].instrument?.sampler)
        #expect(sampler.zones.count == 2)
        let source = try #require(sampler.zones.first { $0.id.uuidString == zoneID })
        #expect(source.minPitch == source.maxPitch, "the source slice's own key is unchanged")
    }

    @Test("explicit 'centered' direction: the slice's own pitch sits in the MIDDLE, eight keys up")
    func spreadSliceExplicitCentered() async throws {
        let (router, _) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID),
                     "direction": .string("centered")]))
        #expect(response.ok, "\(response.error ?? "")")
        let result = try #require(response.result)
        #expect(result["spreadDirection"]?.stringValue == "centered")
        let minPitch = try #require(result["minPitch"]?.doubleValue)
        let rootPitch = try #require(result["rootPitch"]?.doubleValue)
        #expect(rootPitch == minPitch + 8, "'centered': the ninth pad, eight keys up")
    }

    @Test("unknown track surfaces noTrack verbatim")
    func spreadSliceUnknownTrack() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(UUID().uuidString), "zoneId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("No track with id") == true)
    }

    @Test("a track not playing the built-in Sampler is refused (notASampler)")
    func spreadSliceNotASampler() async throws {
        let (router, store) = makeRouter()
        let audioTrackID = store.addTrack(kind: .audio).id.uuidString
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(audioTrackID), "zoneId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("built-in Sampler") == true)
    }

    @Test("an unknown zoneId is refused and points at instrument.describeSampler")
    func spreadSliceZoneNotFound() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error?.contains("instrument.describeSampler") == true)
    }

    @Test("a keymap with no free sixteen-key window anywhere is refused (noFreeWindow)")
    func spreadSliceNoFreeWindow() async throws {
        let (router, store) = makeRouter()
        let trackID = store.addTrack(kind: .instrument).id.uuidString
        let setInstrument = await router.handle(ControlRequest(
            id: "i", command: "track.setInstrument",
            params: [
                "trackId": .string(trackID),
                "kind": .string("sampler"),
                "sampler": .object([
                    "zones": .array([
                        .object([
                            "path": .string(Self.sample.wireName),
                            "rootPitch": .number(Double(Self.sample.rootPitch)),
                            "minPitch": .number(0), "maxPitch": .number(127),
                        ]),
                    ]),
                ]),
            ]))
        let zoneID = try #require(setInstrument.result?["sampler"]?["zones"]?
            .arrayValue?.first?["id"]?.stringValue)

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("no room for a spread") == true)
    }

    @Test("unknown params are rejected with the teaching key list")
    func spreadSliceUnknownKeysRejected() async throws {
        let (router, _) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID),
                     "sourceZoneId": .string(zoneID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'sourceZoneId'") == true)
        #expect(response.error?.contains("'direction', 'trackId', 'zoneId'") == true)
    }

    @Test("a bad direction string is a teaching error naming both legal values")
    func spreadSliceBadDirectionRejected() async throws {
        let (router, _) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID),
                     "direction": .string("sideways")]))
        #expect(!response.ok)
        #expect(response.error?.contains("'up'") == true)
        #expect(response.error?.contains("'centered'") == true)
    }

    // ── instrument.setSpreadDirection ───────────────────────────────────────

    @Test("flipping a live spread reports changed:true and actually moves rootPitch")
    func setSpreadDirectionFlipsAndReportsChanged() async throws {
        let (router, store) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let spread = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID)]))
        let spreadZoneID = try #require(spread.result?["id"]?.stringValue)
        let originalRoot = try #require(spread.result?["rootPitch"]?.doubleValue)

        let flip = await router.handle(ControlRequest(
            id: "2", command: "instrument.setSpreadDirection",
            params: ["trackId": .string(trackID), "spreadZoneId": .string(spreadZoneID),
                     "direction": .string("centered")]))
        #expect(flip.ok, "\(flip.error ?? "")")
        #expect(flip.result?["changed"]?.boolValue == true)
        #expect(flip.result?["spreadDirection"]?.stringValue == "centered")
        let newRoot = try #require(flip.result?["rootPitch"]?.doubleValue)
        #expect(newRoot == originalRoot + 8)

        // The STORE actually moved — never trust the response alone.
        let stored = try #require(store.tracks[0].instrument?.sampler?.zones
            .first { $0.id.uuidString == spreadZoneID })
        #expect(Double(stored.rootPitch) == newRoot)
    }

    @Test("asking for the direction a spread already runs is an honest no-op: changed:false, nothing written")
    func setSpreadDirectionNoOp() async throws {
        let (router, store) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let spread = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID)]))
        let spreadZoneID = try #require(spread.result?["id"]?.stringValue)
        let beforeZone = try #require(store.tracks[0].instrument?.sampler?.zones
            .first { $0.id.uuidString == spreadZoneID })

        // Same direction it already runs ("up", the default it was made with).
        let again = await router.handle(ControlRequest(
            id: "2", command: "instrument.setSpreadDirection",
            params: ["trackId": .string(trackID), "spreadZoneId": .string(spreadZoneID),
                     "direction": .string("up")]))
        #expect(again.ok, "\(again.error ?? "")")
        #expect(again.result?["changed"]?.boolValue == false)
        let afterZone = try #require(store.tracks[0].instrument?.sampler?.zones
            .first { $0.id.uuidString == spreadZoneID })
        #expect(afterZone == beforeZone, "a no-op must write NOTHING — the zone is byte-identical")
    }

    @Test("re-rooting a zone that is not spread-shaped is refused (notASpread), never silently applied")
    func setSpreadDirectionNotASpreadRefused() async throws {
        let (router, _) = makeRouter()
        // The SOURCE slice itself: one key wide, not sixteen — not a spread.
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.setSpreadDirection",
            params: ["trackId": .string(trackID), "spreadZoneId": .string(zoneID),
                     "direction": .string("centered")]))
        #expect(!response.ok)
        #expect(response.error?.contains("not a Sixteen Levels spread") == true)
    }

    @Test("an unknown spreadZoneId surfaces zoneNotFound")
    func setSpreadDirectionZoneNotFound() async throws {
        let (router, _) = makeRouter()
        let (trackID, _) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.setSpreadDirection",
            params: ["trackId": .string(trackID), "spreadZoneId": .string(UUID().uuidString),
                     "direction": .string("up")]))
        #expect(!response.ok)
        #expect(response.error?.contains("instrument.describeSampler") == true)
    }

    @Test("unknown params are rejected with the teaching key list")
    func setSpreadDirectionUnknownKeysRejected() async throws {
        let (router, _) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.setSpreadDirection",
            params: ["trackId": .string(trackID), "spreadZoneId": .string(zoneID),
                     "direction": .string("up"), "zoneId": .string(zoneID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("unknown parameter 'zoneId'") == true)
    }

    @Test("a bad direction string is a teaching error naming both legal values")
    func setSpreadDirectionBadDirectionRejected() async throws {
        let (router, _) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.setSpreadDirection",
            params: ["trackId": .string(trackID), "spreadZoneId": .string(zoneID),
                     "direction": .string("down")]))
        #expect(!response.ok)
        #expect(response.error?.contains("'up'") == true)
        #expect(response.error?.contains("'centered'") == true)
    }

    @Test("direction is REQUIRED on the setter — there is no 'up' default, unlike spreadSlice")
    func setSpreadDirectionRequiresDirection() async throws {
        let (router, _) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.setSpreadDirection",
            params: ["trackId": .string(trackID), "spreadZoneId": .string(zoneID)]))
        #expect(!response.ok)
        #expect(response.error?.contains("direction") == true)
    }

    // ── instrument.describeSampler's additive spreadDirection field ────────

    @Test("describeSampler reports each zone's spreadDirection: null for an ordinary slice, set for a spread")
    func describeSamplerReportsSpreadDirection() async throws {
        let (router, _) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)
        let spread = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID),
                     "direction": .string("centered")]))
        let spreadZoneID = try #require(spread.result?["id"]?.stringValue)

        let described = await router.handle(ControlRequest(
            id: "2", command: "instrument.describeSampler",
            params: ["trackId": .string(trackID), "offset": .number(0), "limit": .number(50)]))
        #expect(described.ok, "\(described.error ?? "")")
        let zones = try #require(described.result?["zones"]?.arrayValue)
        #expect(zones.count == 2)
        let source = try #require(zones.first { $0["id"]?.stringValue == zoneID })
        #expect(source["spreadDirection"] == .null, "an ordinary one-key slice is not a spread")
        let spreadZone = try #require(zones.first { $0["id"]?.stringValue == spreadZoneID })
        #expect(spreadZone["spreadDirection"]?.stringValue == "centered")
    }

    // ── allCommands advertisement ───────────────────────────────────────────

    @Test("both verbs are advertised in allCommands, next to instrument.describeSampler")
    func advertisedInAllCommands() {
        #expect(CommandRouter.allCommands.contains("instrument.spreadSlice"))
        #expect(CommandRouter.allCommands.contains("instrument.setSpreadDirection"))
        #expect(CommandRouter.allCommands.contains("instrument.describeSampler"))
    }

    // ── round-trip proof: wire == the pure function the pad grid itself calls ─

    /// Proves `instrument.spreadSlice`'s zone is FIELD-FOR-FIELD what a hand
    /// on the pads would have made — i.e. it is not a second implementation.
    /// `SixteenLevels.zone(from:base:direction:)` is the exact pure function
    /// `PadGridStaging.swift`'s chop/spread path builds its keymap through
    /// (see that file's `padGridSetZones`); `SixteenLevelsTests` separately
    /// pins the grid itself to agree with this same function, so wire == pure
    /// == grid is a closed chain without importing DAWAppKit into this target.
    @Test("a spread made over the wire is field-for-field the zone SixteenLevels.zone(from:base:direction:) builds")
    func wireSpreadMatchesThePureFunctionThePadGridUses() async throws {
        let (router, store) = makeRouter()
        let (trackID, zoneID) = try await addTrackWithOneSlice(router)

        // What the PAD GRID would compute: the same free-window search, over
        // the SAME starting keymap, before either path writes anything.
        let sourceZone = try #require(store.tracks[0].instrument?.sampler?.zones
            .first { $0.id.uuidString == zoneID })
        let existingZones = try #require(store.tracks[0].instrument?.sampler?.zones)
        let base = try #require(SixteenLevels.freeBase(zones: existingZones))
        let handMade = SixteenLevels.zone(from: sourceZone, base: base, direction: .centered)

        let response = await router.handle(ControlRequest(
            id: "1", command: "instrument.spreadSlice",
            params: ["trackId": .string(trackID), "zoneId": .string(zoneID),
                     "direction": .string("centered")]))
        #expect(response.ok, "\(response.error ?? "")")
        let wireZoneID = try #require(response.result?["id"]?.stringValue)
        let wireMade = try #require(store.tracks[0].instrument?.sampler?.zones
            .first { $0.id.uuidString == wireZoneID })

        // Every field `SixteenLevels.zone(from:base:direction:)` sets, field
        // by field — `id` excepted, since each path deliberately mints a
        // FRESH one (copying the source's own id would let removing the
        // spread take the source slice with it).
        #expect(wireMade.audioFileURL == handMade.audioFileURL)
        #expect(wireMade.rootPitch == handMade.rootPitch)
        #expect(wireMade.minPitch == handMade.minPitch)
        #expect(wireMade.maxPitch == handMade.maxPitch)
        #expect(wireMade.gain == handMade.gain)
        #expect(wireMade.tuneCents == handMade.tuneCents)
        #expect(wireMade.pan == handMade.pan)
        #expect(wireMade.ampVelTrack == handMade.ampVelTrack)
        #expect(wireMade.startFrame == handMade.startFrame)
        #expect(wireMade.endFrame == handMade.endFrame)
        #expect(wireMade.attack == handMade.attack)
        #expect(wireMade.decay == handMade.decay)
        #expect(wireMade.sustain == handMade.sustain)
        #expect(wireMade.release == handMade.release)
        #expect(wireMade.reverse == handMade.reverse)
        #expect(wireMade.id != handMade.id, "each path mints its own fresh id, deliberately")
    }
}
