import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Wire-level tests for `ai.copilotGetModel` / `ai.copilotSetModel` (M10-p-6)
/// through `CommandRouter.handle` — the `ai.copilotSend`/`State`/`Reset`
/// (`CopilotCommandTests`) precedent, for the model-selection pair.
@MainActor
@Suite("Copilot model-selection wire commands (M10-p-6)")
struct CopilotModelCommandTests {
    /// A main-actor slot standing in for a real `CopilotModelStore` (which
    /// lives in DAWAppKit, not reachable from DAWControlTests) — shared
    /// across `modelResolver`/`modelSetter` closures exactly the way the app
    /// bootstrap shares ONE `CopilotModelStore` with the engine, so a test
    /// can prove persistence ACROSS separately-constructed `CopilotEngine`
    /// instances (the "survives relaunch" contract) without that module.
    @MainActor final class SharedModelBox {
        var model = AnthropicModelCatalog.defaultModelID
    }

    /// A router with a REAL `CopilotEngine` wired via the weak
    /// `copilotEngine` property, whose model resolver/setter read/write
    /// `box` — so the caller can construct a SECOND router+engine over the
    /// SAME box to prove persistence across instances.
    private func makeWiredRouter(box: SharedModelBox) -> (router: CommandRouter, engine: CopilotEngine) {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider([CopilotReply(blocks: [.text("ok")], stopReason: .endTurn, provider: "fake")])
        let engine = CopilotEngine(
            store: store,
            dispatch: { await router.handle($0) },
            provider: { provider },
            modelResolver: { [box] in box.model },
            modelSetter: { [box] modelID in box.model = modelID })
        router.copilotEngine = engine
        return (router, engine)
    }

    @Test("ai.copilotGetModel returns the default model plus the curated catalog when nothing's been set")
    func getModelDefaultsAndCatalog() async throws {
        let (router, engine) = makeWiredRouter(box: SharedModelBox())
        let response = await router.handle(ControlRequest(id: "1", command: "ai.copilotGetModel"))
        #expect(response.ok)
        #expect(response.result?["model"]?.stringValue == "claude-sonnet-5")
        let catalog = try #require(response.result?["catalog"]?.arrayValue)
        #expect(catalog.count == 6)
        let ids = catalog.compactMap { $0["id"]?.stringValue }
        #expect(Set(ids) == Set(AnthropicModelCatalog.curated.map(\.id)))
        // Every entry carries a non-empty name/note (never falls back to the
        // raw id/empty string for a CURATED row).
        for entry in catalog {
            #expect(entry["name"]?.stringValue?.isEmpty == false)
        }
        #expect(engine.status == .idle)   // keeps the weakly-held engine alive
    }

    @Test("ai.copilotSetModel with a curated id persists it, echoes {model}, and ai.copilotGetModel reflects it")
    func setModelRoundTrip() async throws {
        let box = SharedModelBox()
        // `router.copilotEngine` is weak (the two-phase DAWProApp pattern) —
        // `engine` must stay alive for the router to see it.
        let (router, engine) = makeWiredRouter(box: box)

        let setResponse = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSetModel", params: ["model": .string("claude-fable-5")]))
        #expect(setResponse.ok)
        #expect(setResponse.result?["model"]?.stringValue == "claude-fable-5")
        #expect(box.model == "claude-fable-5")

        let getResponse = await router.handle(ControlRequest(id: "2", command: "ai.copilotGetModel"))
        #expect(getResponse.ok)
        #expect(getResponse.result?["model"]?.stringValue == "claude-fable-5")
        #expect(engine.status == .idle)   // keeps the weakly-held engine alive
    }

    @Test("ai.copilotSetModel with an unknown id throws a teaching error listing every valid id, and persists nothing")
    func setModelUnknownIDTeachingError() async throws {
        let box = SharedModelBox()
        // `router.copilotEngine` is weak — `engine` must stay alive.
        let (router, engine) = makeWiredRouter(box: box)

        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSetModel", params: ["model": .string("claude-nonexistent-9")]))
        #expect(!response.ok)
        let message = try #require(response.error)
        #expect(message.contains("claude-nonexistent-9"))
        for id in AnthropicModelCatalog.curated.map(\.id) {
            #expect(message.contains(id), "teaching error should list \(id)")
        }
        #expect(box.model == AnthropicModelCatalog.defaultModelID)   // unchanged
        #expect(engine.status == .idle)   // keeps the weakly-held engine alive
    }

    @Test("ai.copilotSetModel rejects a lookup-only (non-curated) id the same as a truly unknown one")
    func setModelRejectsLookupOnlyID() async throws {
        let box = SharedModelBox()
        // `router.copilotEngine` is weak — `engine` must stay alive.
        let (router, engine) = makeWiredRouter(box: box)

        // claude-opus-4-6 resolves fine internally (AnthropicModelCatalog.lookup)
        // but is deliberately excluded from the picker/validation set.
        let response = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSetModel", params: ["model": .string("claude-opus-4-6")]))
        #expect(!response.ok)
        #expect(response.error?.contains("claude-opus-4-6") == true)
        #expect(engine.status == .idle)   // keeps the weakly-held engine alive
    }

    @Test("a model set on one CopilotEngine instance is honored by a second instance over the SAME persisted setting")
    func modelPersistsAcrossEngineInstances() async throws {
        let box = SharedModelBox()

        // "Instance 1" (a session, or before an app relaunch) sets the model.
        // `router.copilotEngine` is weak — `engine1` must stay alive for the
        // duration of this call.
        let (router1, engine1) = makeWiredRouter(box: box)
        let setResponse = await router1.handle(ControlRequest(
            id: "1", command: "ai.copilotSetModel", params: ["model": .string("claude-haiku-4-5")]))
        #expect(setResponse.ok)
        #expect(engine1.status == .idle)   // keeps the weakly-held engine alive

        // "Instance 2" (a FRESH CopilotEngine/CommandRouter — the "app relaunch"
        // stand-in) reads through the SAME underlying setting and sees it.
        let (router2, engine2) = makeWiredRouter(box: box)
        #expect(engine2.currentModel == "claude-haiku-4-5")
        let getResponse = await router2.handle(ControlRequest(id: "2", command: "ai.copilotGetModel"))
        #expect(getResponse.ok)
        #expect(getResponse.result?["model"]?.stringValue == "claude-haiku-4-5")
    }

    @Test("ai.copilotGetModel/SetModel fail actionably when the engine isn't wired")
    func engineNotWired() async throws {
        let store = ProjectStore()
        let router = CommandRouter(store: store) // copilotEngine left nil.

        let getResponse = await router.handle(ControlRequest(id: "1", command: "ai.copilotGetModel"))
        #expect(!getResponse.ok)
        #expect(getResponse.error?.contains("not wired") == true)

        let setResponse = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotSetModel", params: ["model": .string("claude-sonnet-5")]))
        #expect(!setResponse.ok)
        #expect(setResponse.error?.contains("not wired") == true)
    }

    @Test("ai.copilotSetModel requires the model param; unknown keys are rejected on both commands")
    func paramValidation() async throws {
        // `router.copilotEngine` is weak — `engine` must stay alive.
        let (router, engine) = makeWiredRouter(box: SharedModelBox())

        let missing = await router.handle(ControlRequest(id: "1", command: "ai.copilotSetModel"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("model") == true)

        let extraOnGet = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotGetModel", params: ["oops": .bool(true)]))
        #expect(!extraOnGet.ok)

        let extraOnSet = await router.handle(ControlRequest(
            id: "3", command: "ai.copilotSetModel",
            params: ["model": .string("claude-sonnet-5"), "oops": .bool(true)]))
        #expect(!extraOnSet.ok)
        #expect(engine.status == .idle)   // keeps the weakly-held engine alive
    }

    @Test("an engine using the default (no injected model resolver/setter) still round-trips through the wire commands")
    func defaultEngineModelResolverRoundTrips() async throws {
        // No `modelResolver`/`modelSetter` injected — the engine's own
        // per-instance DefaultModelBox fallback (most production/UI call
        // sites BEFORE a Settings picker lands, and every pre-M10-p-6 test).
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider([CopilotReply(blocks: [.text("ok")], stopReason: .endTurn, provider: "fake")])
        let engine = CopilotEngine(store: store, dispatch: { await router.handle($0) }, provider: { provider })
        router.copilotEngine = engine

        let getBefore = await router.handle(ControlRequest(id: "1", command: "ai.copilotGetModel"))
        #expect(getBefore.result?["model"]?.stringValue == "claude-sonnet-5")

        let set = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotSetModel", params: ["model": .string("claude-opus-4-7")]))
        #expect(set.ok)

        let getAfter = await router.handle(ControlRequest(id: "3", command: "ai.copilotGetModel"))
        #expect(getAfter.result?["model"]?.stringValue == "claude-opus-4-7")
        #expect(engine.currentModel == "claude-opus-4-7")
    }
}
