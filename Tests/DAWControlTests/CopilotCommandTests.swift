import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Wire-level tests for `ai.copilotSend` / `ai.copilotState` / `ai.copilotReset`
/// through `CommandRouter.handle` (M6 rail-c, design §6). Mirrors the
/// `ai.generateSong`/`ai.generationStatus` submit-then-poll precedent.
@MainActor
@Suite("Copilot wire commands")
struct CopilotCommandTests {
    /// A router with a REAL `CopilotEngine` wired via the weak
    /// `copilotEngine` property (the two-phase DAWProApp pattern), backed by
    /// a scripted `FakeCopilotProvider` so no network/keys are involved.
    private func makeWiredRouter(
        scripted: [CopilotReply] = [CopilotReply(blocks: [.text("ok")], stopReason: .endTurn, provider: "fake")]
    ) -> (router: CommandRouter, store: ProjectStore, engine: CopilotEngine) {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider(scripted)
        let engine = CopilotEngine(store: store, dispatch: { await router.handle($0) }, provider: { provider })
        router.copilotEngine = engine
        return (router, store, engine)
    }

    @Test("ai.copilotSend returns a turnId; ai.copilotState shows the finished transcript")
    func sendThenPoll() async throws {
        let (router, _, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("Hello there.")], stopReason: .endTurn, provider: "fake"),
        ])

        let sendResponse = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSend", params: ["message": .string("hi copilot")]
        ))
        #expect(sendResponse.ok)
        let turnId = try #require(sendResponse.result?["turnId"]?.stringValue)
        #expect(sendResponse.result?["status"]?.stringValue == "running")

        await engine.waitForTurn()

        let stateResponse = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotState", params: ["turnId": .string(turnId)]
        ))
        #expect(stateResponse.ok)
        #expect(stateResponse.result?["status"]?.stringValue == "done")
        let transcript = try #require(stateResponse.result?["transcript"]?.arrayValue)
        #expect(transcript.count == 2) // user + assistant
        #expect(transcript[0]["kind"]?.stringValue == "user")
        #expect(transcript[0]["turnId"]?.stringValue == turnId)
        #expect(transcript[1]["kind"]?.stringValue == "assistant")
        #expect(transcript[1]["text"]?.stringValue == "Hello there.")
    }

    @Test("ai.copilotSend while a turn is running returns an error")
    func sendWhileRunningErrors() async throws {
        let (router, _, engine) = makeWiredRouter()
        let first = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSend", params: ["message": .string("first")]
        ))
        #expect(first.ok)

        let second = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotSend", params: ["message": .string("second")]
        ))
        #expect(!second.ok)
        #expect(second.error?.contains("already running") == true)

        await engine.waitForTurn()
    }

    @Test("ai.copilotSend/State/Reset all fail actionably when the engine isn't wired")
    func engineNotWired() async {
        let store = ProjectStore()
        let router = CommandRouter(store: store) // copilotEngine left nil, like a bare test router.

        let sendResponse = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSend", params: ["message": .string("hi")]
        ))
        #expect(!sendResponse.ok)
        #expect(sendResponse.error?.contains("not wired") == true)

        let stateResponse = await router.handle(ControlRequest(id: "2", command: "ai.copilotState"))
        #expect(!stateResponse.ok)
        #expect(stateResponse.error?.contains("not wired") == true)

        let resetResponse = await router.handle(ControlRequest(id: "3", command: "ai.copilotReset"))
        #expect(!resetResponse.ok)
        #expect(resetResponse.error?.contains("not wired") == true)
    }

    @Test("ai.copilotState with an unknown turnId returns current status and an empty transcript")
    func stateWithUnknownTurnID() async throws {
        let (router, _, engine) = makeWiredRouter()
        let sendResponse = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSend", params: ["message": .string("hi")]
        ))
        #expect(sendResponse.ok)
        await engine.waitForTurn()

        let stateResponse = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotState", params: ["turnId": .string("not-a-real-turn-id")]
        ))
        #expect(stateResponse.ok)
        #expect(stateResponse.result?["status"]?.stringValue == "done")
        #expect(stateResponse.result?["transcript"]?.arrayValue?.isEmpty == true)
    }

    @Test("ai.copilotState with no turnId returns the whole session's transcript")
    func stateWithOmittedTurnID() async throws {
        let (router, _, engine) = makeWiredRouter(scripted: [
            CopilotReply(blocks: [.text("one")], stopReason: .endTurn, provider: "fake"),
            CopilotReply(blocks: [.text("two")], stopReason: .endTurn, provider: "fake"),
        ])
        _ = await router.handle(ControlRequest(id: "1", command: "ai.copilotSend", params: ["message": .string("a")]))
        await engine.waitForTurn()
        _ = await router.handle(ControlRequest(id: "2", command: "ai.copilotSend", params: ["message": .string("b")]))
        await engine.waitForTurn()

        let stateResponse = await router.handle(ControlRequest(id: "3", command: "ai.copilotState"))
        #expect(stateResponse.ok)
        let transcript = try #require(stateResponse.result?["transcript"]?.arrayValue)
        #expect(transcript.count == 4) // two whole [user, assistant] exchanges
    }

    @Test("ai.copilotReset cancels an in-flight turn and clears the transcript")
    func resetCancelsAndClears() async throws {
        let (router, _, engine) = makeWiredRouter()
        _ = await router.handle(ControlRequest(id: "1", command: "ai.copilotSend", params: ["message": .string("hi")]))
        await engine.waitForTurn()

        let resetResponse = await router.handle(ControlRequest(id: "2", command: "ai.copilotReset"))
        #expect(resetResponse.ok)

        let stateResponse = await router.handle(ControlRequest(id: "3", command: "ai.copilotState"))
        #expect(stateResponse.ok)
        #expect(stateResponse.result?["status"]?.stringValue == "idle")
        #expect(stateResponse.result?["transcript"]?.arrayValue?.isEmpty == true)
    }

    @Test("ai.copilotSend requires a non-empty message")
    func requiresNonEmptyMessage() async {
        // `router.copilotEngine` is weak (the two-phase DAWProApp pattern) —
        // the `engine` binding must be kept alive for the router to see it.
        let (router, _, engine) = makeWiredRouter()

        let missing = await router.handle(ControlRequest(id: "1", command: "ai.copilotSend"))
        #expect(!missing.ok)
        #expect(missing.error?.contains("message") == true)

        let blank = await router.handle(ControlRequest(
            id: "2", command: "ai.copilotSend", params: ["message": .string("   ")]
        ))
        #expect(!blank.ok)
        #expect(engine.status == .idle) // neither call should have started a turn
    }

    @Test("no configured AI provider surfaces the actionable Settings (⌘,) error over the wire")
    func noProviderSurfacesActionableError() async {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let engine = CopilotEngine(
            store: store,
            dispatch: { await router.handle($0) },
            provider: { throw AIServiceError.noProviderConfigured(capability: "copilot") }
        )
        router.copilotEngine = engine

        let sendResponse = await router.handle(ControlRequest(
            id: "1", command: "ai.copilotSend", params: ["message": .string("hi")]
        ))
        #expect(!sendResponse.ok)
        #expect(sendResponse.error?.contains("Settings") == true)
        #expect(sendResponse.error?.contains("\u{2318},") == true)
    }
}
