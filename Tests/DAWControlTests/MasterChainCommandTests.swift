import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for the MASTER insert chain (m13-d d-2) — the
/// `trackId:"master"` sentinel on the five chain verbs (`fx.add`/`fx.remove`/
/// `fx.reorder`/`fx.setBypass`/`fx.setParam`), the two named `fx.setSidechain`
/// rejections, and the snapshot's top-level `masterEffects` + `pdc`
/// `masterChainLatencySamples`. Headless twin of the C6 live gate: the store
/// itself is covered by DAWCore's MasterChainStoreTests — this pins the WIRE
/// boundary (sentinel resolution + verbatim errors + result/snapshot shape).
/// Reuses `FakeMedia` from ControlTests.swift.
@MainActor
@Suite("Master insert chain — control protocol (fx.* sentinel)")
struct MasterChainCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addMaster(_ router: CommandRouter, kind: String) async -> ControlResponse {
        await router.handle(ControlRequest(
            id: "fx-add-master-\(kind)", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string(kind)]))
    }

    private func snapshot(_ router: CommandRouter) async -> JSONValue? {
        await router.handle(ControlRequest(id: "snap", command: "project.snapshot", params: [:])).result
    }

    // MARK: - Sentinel round-trip on all five verbs

    @Test("add → snapshot → setParam → setBypass → reorder → remove, all via the master sentinel")
    func sentinelRoundTrip() async throws {
        let (router, store) = makeRouter()

        // fx.add master: echoes the sentinel + returns the effectId.
        let addEQ = await addMaster(router, kind: "eq")
        #expect(addEQ.ok)
        #expect(addEQ.result?["trackId"]?.stringValue == "master")
        let eqID = try #require(addEQ.result?["effectId"]?.stringValue)
        #expect(store.masterEffects.count == 1)

        // Snapshot carries top-level masterEffects (present + populated) and the
        // additive pdc.masterChainLatencySamples field.
        let snap = try #require(await snapshot(router))
        let masterEffects = try #require(snap["masterEffects"]?.arrayValue)
        #expect(masterEffects.count == 1)
        #expect(masterEffects.first?["id"]?.stringValue == eqID)
        #expect(masterEffects.first?["kind"]?.stringValue == "eq")
        #expect(snap["pdc"]?["masterChainLatencySamples"] != nil)

        // fx.setParam master (coalesced under the master key; returns the chain).
        let setParam = await router.handle(ControlRequest(
            id: "fx-param", command: "fx.setParam",
            params: ["trackId": .string("master"), "effectId": .string(eqID),
                     "name": .string("peak1GainDb"), "value": .number(3.0)]))
        #expect(setParam.ok)
        #expect(setParam.result?["trackId"]?.stringValue == "master")

        // fx.setBypass master.
        let bypass = await router.handle(ControlRequest(
            id: "fx-byp", command: "fx.setBypass",
            params: ["trackId": .string("master"), "effectId": .string(eqID),
                     "bypassed": .bool(true)]))
        #expect(bypass.ok)
        #expect(store.masterEffects.first?.isBypassed == true)

        // A second effect so reorder has two to move.
        let addLim = await addMaster(router, kind: "limiter")
        let limID = try #require(addLim.result?["effectId"]?.stringValue)
        #expect(store.masterEffects.map(\.id.uuidString) == [eqID, limID])

        // fx.reorder master: move the limiter to the front.
        let reorder = await router.handle(ControlRequest(
            id: "fx-reo", command: "fx.reorder",
            params: ["trackId": .string("master"), "effectId": .string(limID),
                     "index": .number(0)]))
        #expect(reorder.ok)
        #expect(store.masterEffects.map(\.id.uuidString) == [limID, eqID])

        // fx.remove master.
        let remove = await router.handle(ControlRequest(
            id: "fx-rem", command: "fx.remove",
            params: ["trackId": .string("master"), "effectId": .string(eqID)]))
        #expect(remove.ok)
        #expect(store.masterEffects.map(\.id.uuidString) == [limID])
    }

    // MARK: - Snapshot masterEffects is ALWAYS present (empty array default)

    @Test("snapshot masterEffects is present as [] with an empty chain")
    func masterEffectsAlwaysPresent() async throws {
        let (router, _) = makeRouter()
        let snap = try #require(await snapshot(router))
        let masterEffects = try #require(snap["masterEffects"]?.arrayValue,
                                         "masterEffects must be present (empty array) even with no chain")
        #expect(masterEffects.isEmpty)
    }

    // MARK: - The three teaching errors, verbatim

    @Test("fx.add audioUnit on master → masterChainBuiltInOnly verbatim")
    func masterRejectsAudioUnit() async {
        let (router, store) = makeRouter()
        let response = await addMaster(router, kind: "audioUnit")
        #expect(!response.ok)
        #expect(response.error == "the master chain hosts built-in effects only in v1 — pick one of gain|eq|compressor|limiter|reverb|delay|saturator|gate|chorus")
        #expect(store.masterEffects.isEmpty)   // nothing added on error
    }

    @Test("fx.setSidechain trackId:master → sidechainMasterUnsupported verbatim")
    func masterRejectsSidechainDestination() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "sc-master-dest", command: "fx.setSidechain",
            params: ["trackId": .string("master"),
                     "effectId": .string(UUID().uuidString),
                     "sourceTrackId": .string(UUID().uuidString)]))
        #expect(!response.ok)
        #expect(response.error == "the master chain cannot host a sidechain-keyed effect — key an effect on a track or bus instead")
    }

    @Test("fx.setSidechain sourceTrackId:master → master-output-key-source verbatim")
    func masterRejectsSidechainSource() async throws {
        let (router, store) = makeRouter()
        // A real keyable effect on a real track, so we get PAST the destination
        // parse and hit the sourceTrackId site specifically.
        let track = await router.handle(ControlRequest(
            id: "t", command: "track.add",
            params: ["name": .string("Pad"), "kind": .string("audio")]))
        let trackID = try #require(track.result?["id"]?.stringValue)
        let comp = await router.handle(ControlRequest(
            id: "c", command: "fx.add",
            params: ["trackId": .string(trackID), "kind": .string("compressor")]))
        let compID = try #require(comp.result?["effectId"]?.stringValue)
        let response = await router.handle(ControlRequest(
            id: "sc-master-src", command: "fx.setSidechain",
            params: ["trackId": .string(trackID),
                     "effectId": .string(compID),
                     "sourceTrackId": .string("master")]))
        #expect(!response.ok)
        #expect(response.error == "the master output cannot be a sidechain key source")
        // Nothing keyed.
        #expect(store.tracks.first(where: { $0.id.uuidString == trackID })?
            .effects.first?.sidechainSourceTrackID == nil)
    }

    // MARK: - The sentinel does NOT leak into requireTrackID verbs

    @Test("track.setVolume {trackId:\"master\"} stays an invalid-UUID error (no sentinel leak)")
    func sentinelDoesNotLeak() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "vol", command: "track.setVolume",
            params: ["trackId": .string("master"), "volume": .number(0.5)]))
        #expect(!response.ok)
        #expect(response.error == "'trackId' is not a valid UUID: master")
    }
}
