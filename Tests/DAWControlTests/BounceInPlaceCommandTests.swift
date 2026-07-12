import Foundation
import Testing
import DAWCore
@testable import DAWControl

/// Control-protocol coverage for `track.bounceInPlace` (m11-e): the happy-path
/// response shape ({track, clip, file, sourceTrackId, sourceMuted,
/// measurement}), the muteSource/name knobs, field-named param validation,
/// eligibility parity with render.stems (bus-routed rejection verbatim), and
/// the ONE-undo composite. Reuses `FakeRenderEngine`/`FakeMedia` — no
/// AVFoundation, no real render.
@MainActor
@Suite("track.bounceInPlace — control protocol (m11-e)")
struct BounceInPlaceCommandTests {
    // `ProjectStore.engine` is a WEAK reference, so the engine must be held
    // strongly by the caller for the router's lifetime (the RenderCommandTests
    // precedent) — hence it is passed in, not created inline.
    private func makeRouter(engine: FakeRenderEngine) -> (CommandRouter, ProjectStore) {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = engine
        store.generationImportsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bounce-cmd-\(UUID().uuidString)", isDirectory: true)
        return (CommandRouter(store: store), store)
    }

    private func addTrack(_ router: CommandRouter, kind: String, name: String) async throws -> String {
        let r = await router.handle(ControlRequest(
            id: "add", command: "track.add",
            params: ["kind": .string(kind), "name": .string(name)]))
        return try #require(r.result?["id"]?.stringValue)
    }

    @Test("happy path: bounces an instrument track, response carries track/clip/file/measurement")
    func happyPath() async throws {
        let engine = FakeRenderEngine()
        let (router, store) = makeRouter(engine: engine)
        let sourceID = try await addTrack(router, kind: "instrument", name: "Synth")

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(sourceID), "durationSeconds": .number(1.0)]))
        #expect(response.ok, "bounceInPlace failed: \(response.error ?? "?")")

        #expect(response.result?["track"]?["name"]?.stringValue == "Synth (Bounced)")
        #expect(response.result?["track"]?["kind"]?.stringValue == "audio")
        #expect(response.result?["clip"]?["startBeat"]?.doubleValue == 0)
        #expect(response.result?["file"]?.stringValue?.hasSuffix(".wav") == true)
        #expect(response.result?["sourceTrackId"]?.stringValue == sourceID)
        #expect(response.result?["sourceMuted"]?.boolValue == true)
        #expect(response.result?["measurement"]?["integratedLufs"]?.doubleValue != nil)

        // The new audio track landed directly after the source; source muted; ONE undo.
        #expect(store.tracks.count == 2)
        #expect(store.tracks[0].id.uuidString == sourceID)
        #expect(store.tracks[0].isMuted == true)
        #expect(store.tracks[1].name == "Synth (Bounced)")
        #expect(store.undoLabel == "Bounce in Place")
    }

    @Test("muteSource:false keeps the source audible")
    func muteSourceFalse() async throws {
        let engine = FakeRenderEngine()
        let (router, store) = makeRouter(engine: engine)
        let sourceID = try await addTrack(router, kind: "instrument", name: "Bass")
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(sourceID), "durationSeconds": .number(1.0),
                     "muteSource": .bool(false)]))
        #expect(response.ok, "bounceInPlace failed: \(response.error ?? "?")")
        #expect(response.result?["sourceMuted"]?.boolValue == false)
        #expect(store.tracks.first(where: { $0.id.uuidString == sourceID })?.isMuted == false)
    }

    @Test("name overrides the default track/clip name")
    func nameOverride() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let sourceID = try await addTrack(router, kind: "instrument", name: "Lead")
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(sourceID), "durationSeconds": .number(1.0),
                     "name": .string("Committed Lead")]))
        #expect(response.ok, "bounceInPlace failed: \(response.error ?? "?")")
        #expect(response.result?["track"]?["name"]?.stringValue == "Committed Lead")
        #expect(response.result?["clip"]?["name"]?.stringValue == "Committed Lead")
    }

    @Test("bus-routed source rejects stemNotMasterInput verbatim (render.stems parity)")
    func busRoutedRejection() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let busID = try await addTrack(router, kind: "bus", name: "Drum Bus")
        let sourceID = try await addTrack(router, kind: "audio", name: "Snare")
        let route = await router.handle(ControlRequest(
            id: "r", command: "track.setOutput",
            params: ["trackId": .string(sourceID), "busId": .string(busID)]))
        #expect(route.ok)

        let response = await router.handle(ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(sourceID), "durationSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "'Snare' is routed to bus 'Drum Bus' — its signal is part of that bus's stem")
    }

    @Test("a bus bounces successfully (eligibility parity with stems)")
    func busBounces() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let busID = try await addTrack(router, kind: "bus", name: "Group")
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(busID), "durationSeconds": .number(1.0)]))
        #expect(response.ok, "bus bounce failed: \(response.error ?? "?")")
        #expect(response.result?["track"]?["name"]?.stringValue == "Group (Bounced)")
    }

    @Test("fromBeat/durationSeconds are field-named validated")
    func validation() async throws {
        let engine = FakeRenderEngine()
        let (router, _) = makeRouter(engine: engine)
        let sourceID = try await addTrack(router, kind: "instrument", name: "Keys")

        let badFromBeat = await router.handle(ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(sourceID), "fromBeat": .number(-1)]))
        #expect(!badFromBeat.ok)
        #expect(badFromBeat.error?.contains("'fromBeat' must be >= 0") == true)

        let badDuration = await router.handle(ControlRequest(
            id: "2", command: "track.bounceInPlace",
            params: ["trackId": .string(sourceID), "durationSeconds": .number(0)]))
        #expect(!badDuration.ok)
        #expect(badDuration.error?.contains("'durationSeconds' must be > 0") == true)
    }

    @Test("headless (no engine) surfaces engineUnavailable")
    func headless() async throws {
        let store = ProjectStore()
        store.media = FakeMedia()
        store.engine = nil
        let router = CommandRouter(store: store)
        let source = store.addTrack(name: "A", kind: .instrument)
        let response = await router.handle(ControlRequest(
            id: "1", command: "track.bounceInPlace",
            params: ["trackId": .string(source.id.uuidString), "durationSeconds": .number(1.0)]))
        #expect(!response.ok)
        #expect(response.error == "audio engine not available")
    }

    @Test("track.bounceInPlace is a registered command")
    func registered() {
        #expect(CommandRouter.allCommands.contains("track.bounceInPlace"))
    }
}
