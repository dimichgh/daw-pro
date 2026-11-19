import Foundation
import Testing
import DAWCore
@testable import DAWControl

// m39-render-pass-race, the WIRE leg. `track.bounceInPlace` whose song closes while it renders must answer with the
// store's refusal sentence (the router's LocalizedError mapping), not an "internal error" dump and not a success, and
// nothing may land in the song that is open now. The store-level matrix (New and Open, in the probe and in the render)
// is `RenderPassRaceTests` in DAWEngineTests. Reuses `FakeRenderEngine` (its `duringRender` hook) and `FakeMedia`.
//
// Nonisolated suite over a `@MainActor` test function (no new `@MainActor` suite).

@Suite("m39-render-pass-race — track.bounceInPlace refuses on the wire when the song changes mid-bounce")
struct RenderPassRaceWireTests {

    @Test("track.bounceInPlace: New Project during the render -> a readable failure, nothing lands, no file")
    @MainActor
    func bounceRefusesOnTheWireWhenTheSongChanges() async throws {
        let engine = FakeRenderEngine()
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        let imports = FileManager.default.temporaryDirectory
            .appendingPathComponent("race-wire-\(UUID().uuidString)", isDirectory: true)
        store.generationImportsDirectory = imports
        defer { try? FileManager.default.removeItem(at: imports) }
        let router = CommandRouter(store: store)
        let add = await router.handle(ControlRequest(
            id: "add", command: "track.add",
            params: ["kind": .string("instrument"), "name": .string("Synth")]))
        let sourceID = try #require(add.result?["id"]?.stringValue)
        let bounce = ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(sourceID), "durationSeconds": .number(1.0), "muteSource": .bool(false)])

        // Control: with no switch the same request lands (so the refusal below is the switch, not the request).
        let landed = await router.handle(bounce)
        #expect(landed.ok, "control bounce failed: \(landed.error ?? "?")")
        #expect(store.tracks.map(\.name) == ["Synth", "Synth (Bounced)"])
        #expect(engine.writtenFiles.count == 1)

        // The switch: New Project pressed while the bounce renders.
        engine.duringRender = { [weak store] in try? store?.newProject(discardChanges: true) }
        let refused = await router.handle(bounce)
        let message = refused.error ?? ""
        print("[RACE] wire refusal: ok \(refused.ok), error \(message)")
        #expect(!refused.ok, "the bounce claimed a landing in a song that closed")
        #expect(message.contains("nothing was added"), "not the refusal sentence: \(message)")
        #expect(!message.hasPrefix("internal error"), "the refusal reached the wire as a dump: \(message)")
        #expect(store.tracks.isEmpty, "the new song gained a track: \(store.tracks.map(\.name))")
        #expect(engine.writtenFiles.count == 1, "a second bounce file was written for a song that closed")
        #expect(store.undoLabel == nil, "the new song gained an undo step: \(store.undoLabel ?? "")")
    }
}
