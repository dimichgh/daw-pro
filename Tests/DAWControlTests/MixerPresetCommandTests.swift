import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for M7 (macro-b) `mixer.applyPreset`: field-named
/// validation (missing trackId / missing preset), the unknown-preset error
/// listing every valid name, and the happy path returning the resolved chain
/// with the preset's effects in order. Reuses `FakeMedia` from ControlTests.swift
/// (same target).
@MainActor
@Suite("Mixer presets — control protocol")
struct MixerPresetCommandTests {
    private func makeRouter() -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, name: String, kind: String) async -> UUID {
        let response = await router.handle(ControlRequest(
            id: "add-\(name)", command: "track.add",
            params: ["name": .string(name), "kind": .string(kind)]
        ))
        return UUID(uuidString: response.result?["id"]?.stringValue ?? "")!
    }

    @Test("allCommands advertises mixer.applyPreset")
    func advertised() {
        #expect(CommandRouter.allCommands.contains("mixer.applyPreset"))
    }

    @Test("missing trackId is a field-named validation error")
    func missingTrackId() async {
        let (router, _) = makeRouter()
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.applyPreset",
            params: ["preset": .string("warm-keys")]
        ))
        #expect(!response.ok)
        #expect(response.error == "missing or invalid required param 'trackId'")
    }

    @Test("missing preset is a field-named validation error")
    func missingPreset() async {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Keys", kind: "audio")
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.applyPreset",
            params: ["trackId": .string(trackID.uuidString)]
        ))
        #expect(!response.ok)
        #expect(response.error == "missing or invalid required param 'preset'")
    }

    @Test("unknown preset error lists every valid preset name")
    func unknownPresetListsNames() async {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Keys", kind: "audio")
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.applyPreset",
            params: ["trackId": .string(trackID.uuidString), "preset": .string("nope")]
        ))
        #expect(!response.ok)
        let error = response.error ?? ""
        #expect(error.contains("nope"))
        for name in MixerPresetCatalog.names {
            #expect(error.contains(name), "error omits '\(name)': \(error)")
        }
    }

    @Test("happy path returns the resolved chain with the preset's effects in order")
    func happyPathReturnsChain() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Vox", kind: "audio")

        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.applyPreset",
            params: ["trackId": .string(trackID.uuidString), "preset": .string("vocal-presence")]
        ))
        #expect(response.ok)
        #expect(response.result?["trackId"]?.stringValue == trackID.uuidString)
        let effects = try #require(response.result?["effects"]?.arrayValue)
        // vocal-presence = EQ then compressor, in order.
        #expect(effects.map { $0["kind"]?.stringValue } == ["eq", "compressor"])
        // Each effect carries a fresh id, isBypassed=false, and a resolved param map.
        #expect(effects.allSatisfy { $0["isBypassed"]?.boolValue == false })
        #expect(effects.allSatisfy { UUID(uuidString: $0["id"]?.stringValue ?? "") != nil })
        // The compressor's mapped params surface on the wire (fidelity spot-check).
        let comp = try #require(effects.last)
        #expect(comp["params"]?["ratio"]?.doubleValue == 3)
        #expect(comp["params"]?["attackMs"]?.doubleValue == 10)
    }

    @Test("apply REPLACES the prior chain (route level)")
    func applyReplacesChain() async throws {
        let (router, _) = makeRouter()
        let trackID = await addTrack(router, name: "Drums", kind: "audio")
        // Seed an unrelated effect first.
        _ = await router.handle(ControlRequest(
            id: "seed", command: "fx.add",
            params: ["trackId": .string(trackID.uuidString), "kind": .string("reverb")]
        ))
        let response = await router.handle(ControlRequest(
            id: "1", command: "mixer.applyPreset",
            params: ["trackId": .string(trackID.uuidString), "preset": .string("drum-bus-glue")]
        ))
        #expect(response.ok)
        let effects = try #require(response.result?["effects"]?.arrayValue)
        // The reverb is gone; only the preset's chain remains.
        #expect(effects.map { $0["kind"]?.stringValue } == ["eq", "compressor"])
        #expect(!effects.contains { $0["kind"]?.stringValue == "reverb" })
    }
}
