import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// m32-e — the bit-crusher's WIRE surface, walked end to end.
///
/// ⭐ THE POINT OF THIS FILE IS THE SILENT SITES. A new `EffectKind` breaks the
/// build at every exhaustive switch, so `EffectFactory`, `ProjectStore`'s
/// display name and param setter, the `fx.describe` schema and the editor's
/// group table all announce themselves. **`ProjectDocument.EffectDocument` does
/// not.** Its stored properties, its explicit `CodingKeys`, and BOTH of its
/// converters are hand-enumerated with no synthesis to save you — forget one and
/// the effect adds fine, renders fine, echoes fine, and then VANISHES on
/// save/load, which is the failure a wire test that never saves cannot see.
///
/// So the round trip below is one test on purpose: add with seeded params →
/// echo → SAVE → OPEN → echo again → change a param → echo again. That single
/// path crosses the descriptor, the document's encoder, its decoder, its
/// `effectDescriptor()` rebuild, `applyEffectParam`, and the `fx` echo.
@MainActor
@Suite("Bit crusher wire + persistence (m32-e)")
struct BitCrusherWireTests {

    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter) async throws -> String {
        let response = await router.handle(ControlRequest(
            id: "t", command: "track.add",
            params: ["name": .string("Chop"), "kind": .string("audio")]))
        #expect(response.ok, "track.add failed: \(response.error ?? "-")")
        return try #require(response.result?["id"]?.stringValue)
    }

    /// The effect's params object as the wire reports it, from a snapshot.
    private func params(_ router: CommandRouter, trackID: String,
                        effectID: String) async throws -> JSONValue {
        let snapshot = await router.handle(
            ControlRequest(id: "snap", command: "project.snapshot"))
        #expect(snapshot.ok)
        let track = try #require(snapshot.result?["tracks"]?.arrayValue?
            .first { $0["id"]?.stringValue == trackID })
        let effect = try #require(track["effects"]?.arrayValue?
            .first { $0["id"]?.stringValue == effectID })
        return try #require(effect["params"])
    }

    // MARK: - The round trip

    @Test("bitCrusher params survive add -> save -> open -> setParam, on the wire")
    func paramsRoundTripThroughTheBundle() async throws {
        let (router, store) = makeRouter()
        let trackID = try await addTrack(router)

        // 1. ADD with every param seeded away from its default, so a site that
        //    silently substitutes defaults is caught rather than flattered.
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID), "kind": .string("bitCrusher"),
                     "params": .object([
                         "bits": .number(6),
                         "downsampleHz": .number(11_025),
                         "antiAlias": .number(1),
                         "dither": .number(1),
                         "mix": .number(0.4),
                     ])]))
        #expect(added.ok, "fx.add failed: \(added.error ?? "-")")
        let effectID = try #require(added.result?["effectId"]?.stringValue)

        let seeded = try await params(router, trackID: trackID, effectID: effectID)
        #expect(seeded["bits"]?.doubleValue == 6)
        #expect(seeded["downsampleHz"]?.doubleValue == 11_025)
        #expect(seeded["antiAlias"]?.doubleValue == 1)
        #expect(seeded["dither"]?.doubleValue == 1)
        #expect(seeded["mix"]?.doubleValue == 0.4)

        // 2. SAVE and REOPEN.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("daw-pro-m32e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("crush.dawproj").path
        let saved = await router.handle(ControlRequest(
            id: "2", command: "project.save", params: ["path": .string(path)]))
        #expect(saved.ok, "save failed: \(saved.error ?? "-")")
        let opened = await router.handle(ControlRequest(
            id: "3", command: "project.open", params: ["path": .string(path)]))
        #expect(opened.ok, "open failed: \(opened.error ?? "-")")

        // 3. The REOPENED project still carries every field. THIS is the leg
        //    that reddens when EffectDocument forgets the key.
        let reopenedTrack = try #require(store.tracks.first { $0.name == "Chop" })
        let reopenedEffect = try #require(reopenedTrack.effects.first)
        #expect(reopenedEffect.kind == .bitCrusher)
        let crusher = try #require(reopenedEffect.bitCrusher,
                                   "the params struct did not survive the bundle")
        #expect(crusher.bits == 6)
        #expect(crusher.downsampleHz == 11_025)
        #expect(crusher.antiAlias)
        #expect(crusher.dither)
        #expect(crusher.mix == 0.4)

        // …and the wire echo agrees with the model after reopen.
        let afterOpen = try await params(router, trackID: reopenedTrack.id.uuidString,
                                         effectID: reopenedEffect.id.uuidString)
        #expect(afterOpen["bits"]?.doubleValue == 6)
        #expect(afterOpen["downsampleHz"]?.doubleValue == 11_025)
        #expect(afterOpen["antiAlias"]?.doubleValue == 1)
        #expect(afterOpen["dither"]?.doubleValue == 1)
        #expect(afterOpen["mix"]?.doubleValue == 0.4)

        // 4. CHANGE the two boolean params back off through fx.setParam — the
        //    0/1 numeric surface, both directions.
        for (name, value) in [("antiAlias", 0.0), ("dither", 0.0)] {
            let set = await router.handle(ControlRequest(
                id: "set-\(name)", command: "fx.setParam",
                params: ["trackId": .string(reopenedTrack.id.uuidString),
                         "effectId": .string(reopenedEffect.id.uuidString),
                         "name": .string(name), "value": .number(value)]))
            #expect(set.ok, "fx.setParam \(name) failed: \(set.error ?? "-")")
        }
        let afterSet = try await params(router, trackID: reopenedTrack.id.uuidString,
                                        effectID: reopenedEffect.id.uuidString)
        #expect(afterSet["antiAlias"]?.doubleValue == 0)
        #expect(afterSet["dither"]?.doubleValue == 0)
        // …and the untouched params did not move (a rebuild that drops fields).
        #expect(afterSet["bits"]?.doubleValue == 6)
        #expect(afterSet["downsampleHz"]?.doubleValue == 11_025)
        #expect(afterSet["mix"]?.doubleValue == 0.4)
    }

    /// A fresh insert with no seeded params echoes the SP-1200 defaults — the
    /// authored character reaches an agent that adds the effect and reads back.
    @Test("a fresh bitCrusher insert echoes the SP-1200 defaults on the wire")
    func freshInsertEchoesTheDefaults() async throws {
        let (router, _) = makeRouter()
        let trackID = try await addTrack(router)
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID), "kind": .string("bitCrusher")]))
        #expect(added.ok, "fx.add failed: \(added.error ?? "-")")
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        let echoed = try await params(router, trackID: trackID, effectID: effectID)
        #expect(echoed["bits"]?.doubleValue == 12)
        #expect(echoed["downsampleHz"]?.doubleValue == 26_040)
        #expect(echoed["antiAlias"]?.doubleValue == 0)
        #expect(echoed["dither"]?.doubleValue == 0)
        #expect(echoed["mix"]?.doubleValue == 1)
        // No `warnings` key: the defaults clamp nothing.
        #expect(added.result?["warnings"] == nil)
    }

    /// `bits` is numeric on the wire and discrete in the DSP. An out-of-range
    /// request CLAMPS and SAYS SO (the m27-c clamp-notice contract), and a
    /// fractional one ROUNDS — silently, because rounding within the legal range
    /// is not a clamp.
    @Test("bits clamps with a warning and rounds without one")
    func bitsClampsLoudlyAndRoundsQuietly() async throws {
        let (router, store) = makeRouter()
        let trackID = try await addTrack(router)
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string(trackID), "kind": .string("bitCrusher"),
                     "params": .object(["bits": .number(64)])]))
        #expect(added.ok)
        let warnings = try #require(added.result?["warnings"]?.arrayValue,
                                   "a clamped seed must warn (m27-c)")
        #expect(warnings.contains { $0.stringValue?.contains("bits") == true },
                "the clamp notice must name the param: \(warnings)")
        let effectID = try #require(added.result?["effectId"]?.stringValue)
        #expect(try await params(router, trackID: trackID,
                                 effectID: effectID)["bits"]?.doubleValue == 16)

        let rounded = await router.handle(ControlRequest(
            id: "2", command: "fx.setParam",
            params: ["trackId": .string(trackID), "effectId": .string(effectID),
                     "name": .string("bits"), "value": .number(9.7)]))
        #expect(rounded.ok)
        #expect(try await params(router, trackID: trackID,
                                 effectID: effectID)["bits"]?.doubleValue == 10)
        #expect(store.tracks.first?.effects.first?.bitCrusher?.bits == 10)
    }

    /// The master chain hosts built-in kinds, and the new one is built in — the
    /// natural place for this effect on a whole beat.
    @Test("bitCrusher is legal on the master chain")
    func bitCrusherIsLegalOnMaster() async throws {
        let (router, store) = makeRouter()
        let added = await router.handle(ControlRequest(
            id: "1", command: "fx.add",
            params: ["trackId": .string("master"), "kind": .string("bitCrusher"),
                     "params": .object(["downsampleHz": .number(40_000)])]))
        #expect(added.ok, "master fx.add failed: \(added.error ?? "-")")
        #expect(store.masterEffects.first?.kind == .bitCrusher)
        // 40 kHz is the Akai MPC60's rate — the "cleaner than an SP-1200" flavour.
        #expect(store.masterEffects.first?.bitCrusher?.downsampleHz == 40_000)
    }

    /// `fx.describe` teaches the two authenticity switches. The defaults are the
    /// item, so the notes are pinned to actually SAY the default is off and why
    /// — a note that only recites the range teaches nothing an agent can act on.
    @Test("fx.describe teaches why antiAlias and dither default OFF")
    func describeTeachesTheAuthenticityDefaults() async throws {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "fx.describe", params: ["kind": .string("bitCrusher")]))
        #expect(response.ok)
        let specs = try #require(response.result?["kinds"]?.arrayValue?.first?["params"]?
            .arrayValue)
        func note(_ name: String) -> String {
            specs.first { $0["name"]?.stringValue == name }?["note"]?.stringValue ?? ""
        }
        #expect(note("antiAlias").contains("DEFAULT"))
        #expect(note("antiAlias").lowercased().contains("alias"))
        #expect(note("dither").contains("DEFAULT"))
        #expect(note("bits").contains("2^bits"))
        // The SP-1200 rate is on the wire as a teachable number, not folklore.
        #expect(note("downsampleHz").contains("26040"))
        #expect(specs.first { $0["name"]?.stringValue == "downsampleHz" }?["default"]?
            .doubleValue == 26_040)
    }
}
