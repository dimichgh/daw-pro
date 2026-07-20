import Foundation
import Testing
import DAWCore
import AIServices
@testable import DAWControl

/// Scripted `CopilotProviding` stand-in: returns each of `scripted` in order
/// and records every `CopilotTurnRequest` it receives, so tests can inspect
/// the per-round system/context/history/tools sent to the provider. An
/// optional `delayNanoseconds` sleeps before returning — `Task.sleep` is
/// cancellation-aware (throws `CancellationError` if the calling Task was
/// cancelled), which the cancel() test relies on.
///
/// M10-p-6 additions (all additive/defaulted, so every pre-existing call site
/// above keeps compiling unchanged): `events` scripts a per-round sequence of
/// `CopilotStreamEvent`s fired (awaited, in order) through the caller's
/// `onEvent` BEFORE that round's reply/throw — the live-partial-transcript
/// tests' seam. `midStreamProbes` fires an optional hook right after a
/// round's events (and before its reply/throw), letting a test synchronously
/// inspect `engine.transcript` mid-stream (everything here runs
/// MainActor-awaited off the engine's own call stack, in order). `throwOnRound`
/// makes ROUND `n` (0-based call count) throw instead of returning
/// `scripted[n]` — the thrown-mid-stream finalization tests' seam.
actor FakeCopilotProvider: CopilotProviding {
    private var scripted: [CopilotReply]
    private let delayNanoseconds: UInt64
    private var scriptedEvents: [[CopilotStreamEvent]]
    private var midStreamProbes: [(@MainActor () async -> Void)?]
    private let throwOnRound: [Int: Error]
    private(set) var requests: [CopilotTurnRequest] = []

    init(
        _ scripted: [CopilotReply],
        delayNanoseconds: UInt64 = 0,
        events: [[CopilotStreamEvent]] = [],
        midStreamProbes: [(@MainActor () async -> Void)?] = [],
        throwOnRound: [Int: Error] = [:]
    ) {
        self.scripted = scripted
        self.delayNanoseconds = delayNanoseconds
        self.scriptedEvents = events
        self.midStreamProbes = midStreamProbes
        self.throwOnRound = throwOnRound
    }

    func complete(
        _ request: CopilotTurnRequest,
        onEvent: (@Sendable (CopilotStreamEvent) async -> Void)?
    ) async throws -> CopilotReply {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        let roundIndex = requests.count
        requests.append(request)

        let events = scriptedEvents.isEmpty ? [] : scriptedEvents.removeFirst()
        for event in events {
            await onEvent?(event)
        }
        let probe = midStreamProbes.isEmpty ? nil : midStreamProbes.removeFirst()
        await probe?()

        if let error = throwOnRound[roundIndex] {
            throw error
        }
        guard !scripted.isEmpty else {
            return CopilotReply(
                blocks: [.text("(fake provider ran out of scripted replies)")],
                stopReason: .endTurn, provider: "fake")
        }
        return scripted.removeFirst()
    }
}

/// Thrown by a provider factory that should never be reached — the
/// `noProviderConfigured` stand-in for the synchronous-throw test.
struct FakeProviderError: Error, LocalizedError {
    var errorDescription: String? { "no AI provider configured — add a key in Settings (\u{2318},)" }
}

/// Builds a helper `.text(...)` reply, the common "end the turn" shape used
/// by most scripts below.
private func textReply(_ text: String) -> CopilotReply {
    CopilotReply(blocks: [.text(text)], stopReason: .endTurn, provider: "fake")
}

/// A mutable main-actor slot the m10-m resolver reads, so a test can change the
/// engine's round budget BETWEEN turns and prove the next turn honors the new value.
@MainActor final class RoundCapBox {
    var cap: Int
    init(_ cap: Int) { self.cap = cap }
}

/// A mutable main-actor slot for the engine ITSELF (M10-p-6 streaming tests):
/// a `midStreamProbes` closure needs to read `engine.transcript`, but it's
/// built as an ARGUMENT to the very `makeEngine`/`CopilotEngine.init` call
/// that produces `engine` — a forward reference nothing else resolves. The
/// box sidesteps it: the closure captures the (already-constructed) box and
/// reads `box.engine` LAZILY when it actually fires, by which point the test
/// has assigned the real engine into it.
@MainActor final class EngineBox {
    var engine: CopilotEngine?
    init() {}
}

/// Builds a helper single-tool-call reply.
private func toolReply(id: String = UUID().uuidString, name: String, args: [String: JSONValue]) -> CopilotReply {
    let json = (try? JSONEncoder().encode(JSONValue.object(args))) ?? Data("{}".utf8)
    return CopilotReply(blocks: [.toolUse(id: id, name: name, inputJSON: json)], stopReason: .toolUse, provider: "fake")
}

@MainActor
@Suite("Copilot engine turn loop")
struct CopilotEngineTests {
    /// Real `CommandRouter` over a real, headless `ProjectStore` (no audio
    /// engine attached — the ControlTests precedent) so tool calls actually
    /// mutate project state through the exact router path `ai.copilotSend`
    /// uses in production.
    private func makeEngine(
        scripted: [CopilotReply],
        maxToolRounds: Int = 8,
        historyLimit: Int = 20,
        delayNanoseconds: UInt64 = 0,
        events: [[CopilotStreamEvent]] = [],
        midStreamProbes: [(@MainActor () async -> Void)?] = [],
        throwOnRound: [Int: Error] = [:]
    ) -> (engine: CopilotEngine, store: ProjectStore, provider: FakeCopilotProvider) {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider(
            scripted, delayNanoseconds: delayNanoseconds,
            events: events, midStreamProbes: midStreamProbes, throwOnRound: throwOnRound)
        let engine = CopilotEngine(
            store: store,
            dispatch: { await router.handle($0) },
            provider: { provider },
            catalog: CopilotToolCatalog.v1,
            // m10-m: the round budget is now an injected resolver; a fixed Int caller
            // migrates mechanically to a constant closure.
            maxToolRounds: { maxToolRounds },
            historyLimit: historyLimit
        )
        return (engine, store, provider)
    }

    // MARK: - Basic turn shapes

    @Test("a text-only reply completes the turn with a user+assistant transcript")
    func textOnlyReply() async throws {
        let (engine, _, _) = makeEngine(scripted: [textReply("Sure, done.")])
        let turnID = try engine.send("say hi")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        #expect(engine.currentTurnID == turnID)
        let kinds = engine.transcript.map(\.kind)
        guard case .user(let userText) = kinds[0] else { Issue.record("expected a leading user entry"); return }
        #expect(userText == "say hi")
        guard case .assistant(let assistantText) = kinds[1] else { Issue.record("expected an assistant entry"); return }
        #expect(assistantText == "Sure, done.")
    }

    @Test("zero blocks + endTurn completes the turn with a failure entry naming the stop reason, never '(no response)'")
    func zeroBlockReply() async throws {
        let empty = CopilotReply(blocks: [], stopReason: .endTurn, provider: "fake")
        let (engine, _, _) = makeEngine(scripted: [empty])
        _ = try engine.send("...")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        let hasFailureEntry = engine.transcript.contains {
            if case .failure(let text) = $0.kind {
                return text.contains("no visible output") && text.contains("end_turn")
            }
            return false
        }
        #expect(hasFailureEntry)
        let noOldString = engine.transcript.allSatisfy {
            if case .assistant(let text) = $0.kind { return text != "(no response)" }
            return true
        }
        #expect(noOldString)
    }

    @Test("an all-thinking reply with an EMPTY summary that hit max_tokens fails the turn with an actionable token-limit entry")
    func allThinkingEmptySummaryMaxTokensReplyFails() async throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"","signature":"sig-abc"}"#.utf8)
        let allThinking = CopilotReply(
            blocks: [.thinking(summary: "", rawJSON: thinkingJSON)], stopReason: .maxTokens, provider: "fake")
        let (engine, _, _) = makeEngine(scripted: [allThinking])
        _ = try engine.send("do something complex")
        await engine.waitForTurn()

        #expect(engine.status == .failed)
        let hasTokenLimitFailure = engine.transcript.contains {
            if case .failure(let text) = $0.kind { return text.contains("token limit") }
            return false
        }
        #expect(hasTokenLimitFailure)
        let noOldString = engine.transcript.allSatisfy {
            if case .assistant(let text) = $0.kind { return text != "(no response)" }
            return true
        }
        #expect(noOldString)
        // §11.2: an empty-summary thinking block never gets its own
        // transcript entry (nothing to show).
        let hasThinkingEntry = engine.transcript.contains {
            if case .thinking = $0.kind { return true }
            return false
        }
        #expect(!hasThinkingEntry)
    }

    @Test("a non-empty-summary thinking block gets its own transcript entry, never counted as visible output, and is echoed back verbatim in the SECOND provider request")
    func thinkingBlockTranscriptEntryAndEchoedInHistory() async throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"reasoning...","signature":"sig-xyz"}"#.utf8)
        let thinkingThenTool = CopilotReply(
            blocks: [
                .thinking(summary: "reasoning...", rawJSON: thinkingJSON),
                .toolUse(id: "call_1", name: "track_add", inputJSON: Data(#"{"name":"Drums"}"#.utf8)),
            ],
            stopReason: .toolUse, provider: "fake")
        let (engine, _, provider) = makeEngine(scripted: [
            thinkingThenTool,
            textReply("Added it."),
        ])
        _ = try engine.send("add a drum track")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        // A non-empty summary gets its own, finalized (non-partial), transcript entry.
        let thinkingEntry = engine.transcript.first {
            if case .thinking(let text) = $0.kind { return text == "reasoning..." }
            return false
        }
        #expect(thinkingEntry != nil)
        #expect(thinkingEntry?.partial == false)

        let requests = await provider.requests
        #expect(requests.count == 2)
        // The SECOND request's history carries the assistant message from
        // round one, with the thinking block still present verbatim.
        let assistantMessage = try #require(requests[1].messages.first { $0.role == .assistant })
        #expect(assistantMessage.blocks.contains(.thinking(summary: "reasoning...", rawJSON: thinkingJSON)))
        // ...and the tool result rides in the following user message, as before.
        let toolResultMessage = try #require(requests[1].messages.last)
        guard case .toolResult(let id, _, let isError) = toolResultMessage.blocks.first! else {
            Issue.record("expected a toolResult block"); return
        }
        #expect(id == "call_1")
        #expect(!isError)
    }

    @Test("request budget: every provider round asks for maxTokens == nil (no artificial cap — the provider requests its model's own maximum)")
    func requestBudgetIsUncapped() async throws {
        let (engine, _, provider) = makeEngine(scripted: [textReply("done")])
        _ = try engine.send("hello")
        await engine.waitForTurn()

        let requests = await provider.requests
        #expect(!requests.isEmpty)
        for request in requests {
            #expect(request.maxTokens == nil)
        }
    }

    // MARK: - Tool execution against the real router

    @Test("one tool round actually mutates the store and feeds the result back")
    func oneToolRoundMutatesStore() async throws {
        let (engine, store, provider) = makeEngine(scripted: [
            toolReply(name: "track_add", args: ["name": .string("Lead Synth"), "kind": .string("instrument")]),
            textReply("Added it."),
        ])
        _ = try engine.send("add an instrument track called Lead Synth")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        #expect(store.tracks.count == 1)
        #expect(store.tracks.first?.name == "Lead Synth")

        // The tool result fed back to the SECOND round carries the created track.
        let secondRoundRequests = await provider.requests
        #expect(secondRoundRequests.count == 2)
        let lastMessage = try #require(secondRoundRequests[1].messages.last)
        guard case .toolResult(_, let content, let isError) = lastMessage.blocks.first! else {
            Issue.record("expected a toolResult block"); return
        }
        #expect(!isError)
        #expect(content.contains("Lead Synth"))
    }

    @Test("multi-round: the second round's context reflects the track created in round one")
    func multiRoundContextRebuild() async throws {
        let (engine, store, provider) = makeEngine(scripted: [
            toolReply(name: "track_add", args: ["name": .string("Drums"), "kind": .string("instrument")]),
            textReply("Track added."),
        ])
        _ = try engine.send("add a drum track")
        await engine.waitForTurn()

        let newTrack = try #require(store.tracks.first(where: { $0.name == "Drums" }))
        let id8 = String(newTrack.id.uuidString.lowercased().prefix(8))

        let requests = await provider.requests
        #expect(requests.count == 2)
        #expect(!requests[0].system.contains(id8), "the track doesn't exist yet in round 1's context")
        #expect(requests[1].system.contains(id8), "round 2's rebuilt context should show the new track")
    }

    @Test("id-prefix expansion resolves a short id to the right track")
    func idPrefixExpansion() async throws {
        let store = ProjectStore()
        let track = store.addTrack(name: "Bass", kind: .instrument)
        let id8 = String(track.id.uuidString.lowercased().prefix(8))
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider([
            toolReply(name: "track_setVolume", args: ["trackId": .string(id8), "volume": .number(0.25)]),
            textReply("Done."),
        ])
        let engine = CopilotEngine(store: store, dispatch: { await router.handle($0) }, provider: { provider })

        _ = try engine.send("turn the bass down")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        #expect(store.tracks.first(where: { $0.id == track.id })?.volume == 0.25)
    }

    @Test("a command error returns as an isError tool_result, not a thrown failure")
    func commandErrorBecomesToolResult() async throws {
        let (engine, store, provider) = makeEngine(scripted: [
            toolReply(name: "track_setVolume", args: ["trackId": .string("not-a-real-id"), "volume": .number(0.5)]),
            textReply("Handled the error."),
        ])
        _ = try engine.send("lower some track's volume")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        #expect(store.tracks.isEmpty)
        let failedResult = engine.transcript.contains {
            if case .toolResult(_, let ok, _) = $0.kind { return !ok }
            return false
        }
        #expect(failedResult)

        let requests = await provider.requests
        let lastMessage = try #require(requests[1].messages.last)
        guard case .toolResult(_, _, let isError) = lastMessage.blocks.first! else {
            Issue.record("expected a toolResult block"); return
        }
        #expect(isError)
    }

    @Test("a hallucinated tool name errors without ever calling the router")
    func hallucinatedToolName() async throws {
        let (engine, store, _) = makeEngine(scripted: [
            toolReply(name: "definitely_not_a_real_tool", args: [:]),
            textReply("Oops."),
        ])
        _ = try engine.send("do the thing")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        #expect(store.tracks.isEmpty)
        let unknownToolResult = engine.transcript.contains {
            if case .toolResult(let command, let ok, let summary) = $0.kind {
                return command == "definitely.not.a.real.tool" && !ok && summary.contains("unknown tool")
            }
            return false
        }
        #expect(unknownToolResult)
    }

    @Test("a denylisted command (track_remove) is never in the catalog, so it's never dispatched")
    func denylistedCommandNeverDispatches() async throws {
        let store = ProjectStore()
        let seeded = store.addTrack(name: "Keep Me")
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider([
            toolReply(name: "track_remove", args: ["trackId": .string(seeded.id.uuidString)]),
            textReply("Removed."),
        ])
        let engine = CopilotEngine(store: store, dispatch: { await router.handle($0) }, provider: { provider })

        _ = try engine.send("remove that track")
        await engine.waitForTurn()

        #expect(store.tracks.contains { $0.id == seeded.id })
        let unknownToolResult = engine.transcript.contains {
            if case .toolResult(_, let ok, let summary) = $0.kind { return !ok && summary.contains("unknown tool") }
            return false
        }
        #expect(unknownToolResult)
    }

    // MARK: - Runaway guards

    @Test("exhausting the tool-round limit still ends in .done, with a failure entry")
    func roundLimitExhaustion() async throws {
        let alwaysToolCall = toolReply(name: "project_snapshot", args: [:])
        let (engine, _, _) = makeEngine(
            scripted: [alwaysToolCall, alwaysToolCall, alwaysToolCall, alwaysToolCall],
            maxToolRounds: 2
        )
        _ = try engine.send("keep going forever")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        let limitEntry = engine.transcript.contains {
            if case .failure(let text) = $0.kind { return text.contains("tool-round limit") }
            return false
        }
        #expect(limitEntry)
    }

    // MARK: - Configurable round budget (beta m10-m)

    /// The limit-message text for a turn that exhausted its budget, or nil.
    private func limitFailureText(_ engine: CopilotEngine) -> String? {
        for entry in engine.transcript {
            if case .failure(let text) = entry.kind, text.contains("tool-round limit") { return text }
        }
        return nil
    }

    @Test("a cap of 1 stops after exactly one round, with the limit message showing 1")
    func capOfOneStopsAfterOneRound() async throws {
        let alwaysToolCall = toolReply(name: "project_snapshot", args: [:])
        let (engine, _, provider) = makeEngine(
            scripted: [alwaysToolCall, alwaysToolCall, alwaysToolCall],
            maxToolRounds: 1)
        _ = try engine.send("keep going")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        #expect(await provider.requests.count == 1)   // exactly one provider round
        let text = try #require(limitFailureText(engine))
        #expect(text.contains("tool-round limit (1)"))
    }

    @Test("a resolver change between turns takes effect on the next turn")
    func resolverChangeBetweenTurns() async throws {
        let box = RoundCapBox(1)
        let alwaysToolCall = toolReply(name: "project_snapshot", args: [:])
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider(Array(repeating: alwaysToolCall, count: 6))
        let engine = CopilotEngine(
            store: store,
            dispatch: { await router.handle($0) },
            provider: { provider },
            maxToolRounds: { box.cap })

        _ = try engine.send("first")
        await engine.waitForTurn()
        let afterFirst = await provider.requests.count
        #expect(afterFirst == 1)   // cap 1 → one round this turn

        box.cap = 2                // change the setting between turns
        _ = try engine.send("second")
        await engine.waitForTurn()
        let afterSecond = await provider.requests.count
        #expect(afterSecond - afterFirst == 2)   // cap 2 now → two rounds this turn
    }

    @Test("a per-turn override outranks the resolver for that turn only")
    func overrideOutranksResolver() async throws {
        let alwaysToolCall = toolReply(name: "project_snapshot", args: [:])
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider(Array(repeating: alwaysToolCall, count: 6))
        // Resolver would allow 8 rounds; the override pins this one turn to 1.
        let engine = CopilotEngine(
            store: store,
            dispatch: { await router.handle($0) },
            provider: { provider },
            maxToolRounds: { 8 })

        _ = try engine.send("just once", maxRoundsOverride: 1)
        await engine.waitForTurn()

        #expect(await provider.requests.count == 1)
        let text = try #require(limitFailureText(engine))
        #expect(text.contains("tool-round limit (1)"))
    }

    @Test("an override below the floor clamps up to 1 (never zero rounds)")
    func overrideClampsLowerBound() async throws {
        let alwaysToolCall = toolReply(name: "project_snapshot", args: [:])
        let (engine, _, provider) = makeEngine(
            scripted: [alwaysToolCall, alwaysToolCall], maxToolRounds: 8)

        _ = try engine.send("zero please", maxRoundsOverride: 0)
        await engine.waitForTurn()

        // clamp(0) == 1 → exactly one round ran (a turn that can never think is useless).
        #expect(await provider.requests.count == 1)
        let text = try #require(limitFailureText(engine))
        #expect(text.contains("tool-round limit (1)"))
    }

    @Test("send while a turn is running throws")
    func sendWhileRunningThrows() throws {
        let (engine, _, _) = makeEngine(scripted: [textReply("...")])
        _ = try engine.send("first")
        #expect(engine.status == .running)
        #expect(throws: (any Error).self) {
            try engine.send("second")
        }
    }

    @Test("cancel() stops an in-flight turn with status .cancelled")
    func cancelStopsInFlightTurn() async throws {
        let (engine, _, _) = makeEngine(scripted: [textReply("too slow")], delayNanoseconds: 200_000_000)
        _ = try engine.send("take your time")
        engine.cancel()
        await engine.waitForTurn()

        #expect(engine.status == .cancelled)
        let cancelledEntry = engine.transcript.contains {
            if case .failure(let text) = $0.kind { return text == "cancelled" }
            return false
        }
        #expect(cancelledEntry)
    }

    @Test("reset() clears the transcript and returns to idle")
    func resetClearsState() async throws {
        let (engine, _, _) = makeEngine(scripted: [textReply("done")])
        _ = try engine.send("hello")
        await engine.waitForTurn()
        #expect(!engine.transcript.isEmpty)

        engine.reset()

        #expect(engine.transcript.isEmpty)
        #expect(engine.status == .idle)
        #expect(engine.currentTurnID == nil)
    }

    @Test("a throwing provider factory fails send() synchronously, before status changes")
    func providerFactoryThrowSynchronously() {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let engine = CopilotEngine(
            store: store,
            dispatch: { await router.handle($0) },
            provider: { throw FakeProviderError() }
        )
        #expect(throws: FakeProviderError.self) {
            try engine.send("hi")
        }
        #expect(engine.status == .idle)
    }

    // MARK: - Live partial transcript (M10-p-6)

    @Test("live thinkingDelta/textDelta events create partial:true transcript entries mid-turn, which finalize (partial cleared, no duplicate) once the round completes")
    func streamedPartialsAppearMidTurnThenFinalize() async throws {
        var midStreamPartialCount = 0
        var midStreamThinkingText: String?
        // The probe closure needs a reference to `engine`, but `engine` is
        // the RESULT of the `makeEngine` call the probe is itself an
        // argument to — a box sidesteps the forward-reference: the closure
        // captures `box` (already constructed) and reads `box.engine`
        // LAZILY when it actually fires, by which point `engine` has been
        // assigned into it below.
        let box = EngineBox()
        let (engine, _, _) = makeEngine(
            scripted: [
                CopilotReply(
                    blocks: [
                        .thinking(
                            summary: "weighing options...",
                            rawJSON: Data(
                                #"{"type":"thinking","thinking":"weighing options...","signature":"sig"}"#.utf8)),
                        .text("Adding the track now."),
                    ],
                    stopReason: .endTurn, provider: "fake"),
            ],
            events: [[
                .thinkingDelta(blockIndex: 0, text: "weighing "),
                .thinkingDelta(blockIndex: 0, text: "options..."),
                .textDelta(blockIndex: 1, text: "Adding the "),
                .textDelta(blockIndex: 1, text: "track now."),
            ]],
            midStreamProbes: [{ @MainActor in
                guard let engine = box.engine else { return }
                let partials = engine.transcript.filter { $0.partial }
                midStreamPartialCount = partials.count
                if let firstThinking = partials.first(where: {
                    if case .thinking = $0.kind { return true }; return false
                }), case .thinking(let text) = firstThinking.kind {
                    midStreamThinkingText = text
                }
            }]
        )
        box.engine = engine
        _ = try engine.send("add a drum track")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        // Mid-stream (captured by the probe, fired AFTER all four scripted
        // events but BEFORE the round's reply lands): two live partial
        // entries, the thinking one already showing its fully-accumulated
        // text (both its deltas fired before the probe).
        #expect(midStreamPartialCount == 2)
        #expect(midStreamThinkingText == "weighing options...")

        // After completion: exactly one entry per block, none left partial —
        // the streamed deltas never duplicated into a second entry.
        let thinkingEntries = engine.transcript.filter { if case .thinking = $0.kind { return true }; return false }
        let assistantEntries = engine.transcript.filter { if case .assistant = $0.kind { return true }; return false }
        #expect(thinkingEntries.count == 1)
        #expect(assistantEntries.count == 1)
        #expect(thinkingEntries.allSatisfy { !$0.partial })
        #expect(assistantEntries.allSatisfy { !$0.partial })
        if case .thinking(let text) = thinkingEntries.first?.kind {
            #expect(text == "weighing options...")
        }
        if case .assistant(let text) = assistantEntries.first?.kind {
            #expect(text == "Adding the track now.")
        }
        #expect(!engine.transcript.contains { $0.partial })
    }

    @Test("a thrown (non-cancellation) error mid-stream finalizes any live partial entries alongside the failure entry — no orphaned streaming state")
    func thrownMidStreamFinalizesPartials() async throws {
        struct BoomError: Error, LocalizedError {
            var errorDescription: String? { "boom" }
        }
        let (engine, _, _) = makeEngine(
            scripted: [],
            events: [[.thinkingDelta(blockIndex: 0, text: "still deciding...")]],
            throwOnRound: [0: BoomError()]
        )
        _ = try engine.send("do something")
        await engine.waitForTurn()

        #expect(engine.status == .failed)
        let thinkingEntry = engine.transcript.first { if case .thinking = $0.kind { return true }; return false }
        #expect(thinkingEntry != nil)
        #expect(thinkingEntry?.partial == false)
        if case .thinking(let text) = thinkingEntry?.kind {
            #expect(text == "still deciding...")
        }
        let hasFailureEntry = engine.transcript.contains {
            if case .failure(let text) = $0.kind { return text.contains("boom") }
            return false
        }
        #expect(hasFailureEntry)
        #expect(!engine.transcript.contains { $0.partial })
    }

    @Test("a CancellationError mid-stream finalizes live partial entries alongside the 'cancelled' failure entry")
    func cancellationMidStreamFinalizesPartials() async throws {
        let (engine, _, _) = makeEngine(
            scripted: [],
            events: [[.textDelta(blockIndex: 0, text: "half a reply")]],
            throwOnRound: [0: CancellationError()]
        )
        _ = try engine.send("do something")
        await engine.waitForTurn()

        #expect(engine.status == .cancelled)
        let assistantEntry = engine.transcript.first { if case .assistant = $0.kind { return true }; return false }
        #expect(assistantEntry != nil)
        #expect(assistantEntry?.partial == false)
        if case .assistant(let text) = assistantEntry?.kind {
            #expect(text == "half a reply")
        }
        #expect(!engine.transcript.contains { $0.partial })
    }

    @Test("a non-empty-summary thinking-only reply (no text/tool_use) still takes the honest §11.2 no-visible-output path — the summary IS shown, but never counts as visible output")
    func nonEmptyThinkingAloneIsStillNoVisibleOutput() async throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"still working through it...","signature":"sig"}"#.utf8)
        let allThinking = CopilotReply(
            blocks: [.thinking(summary: "still working through it...", rawJSON: thinkingJSON)],
            stopReason: .endTurn, provider: "fake")
        let (engine, _, _) = makeEngine(scripted: [allThinking])
        _ = try engine.send("what should I do next?")
        await engine.waitForTurn()

        // §11.2: not a hard failure — "nothing [visible] to show" ends the turn .done.
        #expect(engine.status == .done)
        let hasNoVisibleOutputFailure = engine.transcript.contains {
            if case .failure(let text) = $0.kind { return text.contains("no visible output") }
            return false
        }
        #expect(hasNoVisibleOutputFailure)
        let thinkingEntry = engine.transcript.first {
            if case .thinking(let text) = $0.kind { return text == "still working through it..." }
            return false
        }
        #expect(thinkingEntry != nil)
        #expect(thinkingEntry?.partial == false)
    }

    // MARK: - History trimming

    @Test("history trims at exchange boundaries, dropping the oldest whole turn")
    func historyTrimsAtExchangeBoundaries() async throws {
        // historyLimit 3 -> at most one full [user, assistant] exchange (2
        // messages) survives after a second exchange lands, since dropping
        // only ever removes a WHOLE exchange.
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider([textReply("ok one"), textReply("ok two"), textReply("ok three")])
        let engine = CopilotEngine(
            store: store, dispatch: { await router.handle($0) }, provider: { provider }, historyLimit: 3)

        _ = try engine.send("first message")
        await engine.waitForTurn()
        _ = try engine.send("second message")
        await engine.waitForTurn()
        _ = try engine.send("third message")
        await engine.waitForTurn()

        let requests = await provider.requests
        let lastRequestMessages = try #require(requests.last).messages
        // The head of the trimmed history is always a plain user TEXT message.
        let head = try #require(lastRequestMessages.first)
        guard case .user = head.role else { Issue.record("head should be a user message"); return }
        guard case .text(let headText) = head.blocks.first! else {
            Issue.record("head should be plain text, not a tool result"); return
        }
        // The very first exchange ("first message") should have aged out.
        #expect(headText != "first message")
    }

    @Test("an oversized tool result is truncated with a marker, not sent whole")
    func oversizedToolResultIsTruncated() async throws {
        let store = ProjectStore()
        let instrumentTrack = store.addTrack(name: "Piano", kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: instrumentTrack.id, name: "Big Clip", atBeat: 0, lengthBeats: 64, notes: [])
        let router = CommandRouter(store: store)

        // 200 notes easily blow past the 4,000-char tool_result cap once
        // JSON-encoded as the updated clip's full note array.
        var manyNotes: [JSONValue] = []
        for index in 0..<200 {
            manyNotes.append(.object([
                "pitch": .number(Double(40 + (index % 40))),
                "startBeat": .number(Double(index) * 0.25),
                "lengthBeats": .number(0.25),
                "velocity": .number(100),
            ]))
        }
        let provider = FakeCopilotProvider([
            toolReply(name: "clip_setNotes", args: ["clipId": .string(clip.id.uuidString), "notes": .array(manyNotes)]),
            textReply("Wrote the notes."),
        ])
        let engine = CopilotEngine(store: store, dispatch: { await router.handle($0) }, provider: { provider })

        _ = try engine.send("fill that clip with notes")
        await engine.waitForTurn()

        let requests = await provider.requests
        let toolResultMessage = try #require(requests[1].messages.last)
        guard case .toolResult(_, let content, let isError) = toolResultMessage.blocks.first! else {
            Issue.record("expected a toolResult block"); return
        }
        #expect(!isError)
        #expect(content.count <= 4000)
        #expect(content.hasSuffix("[truncated]"))
    }

    // MARK: - Chat persistence lifecycle (chat-persist design §5)

    /// A minimal archived-chat fixture for resume/delete/eviction tests.
    private func archivedChat(
        title: String = "archived", updatedAt: TimeInterval = 1_000,
        userText: String = "remember the magic word xyzzy",
        assistantText: String = "Noted: xyzzy.",
        droppedEntries: Int? = nil
    ) -> CopilotChatDocument {
        CopilotChatDocument(
            id: UUID(), title: title,
            createdAt: Date(timeIntervalSince1970: 500),
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            droppedEntries: droppedEntries,
            transcript: [
                .init(turnId: "t1", kind: "user", text: userText),
                .init(turnId: "t1", kind: "assistant", text: assistantText),
            ],
            providerMessages: [
                .init(role: "user", blocks: [.init(type: "text", text: userText)]),
                .init(role: "assistant", blocks: [.init(type: "text", text: assistantText)]),
            ])
    }

    @Test("send() derives the chat title from the first user message and arms the store's chat-dirty autosave paths")
    func sendDerivesTitleAndArmsChatDirty() async throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("hi!")])
        #expect(engine.chatTitle == nil)
        #expect(!store.chatsDirty)

        _ = try engine.send("add a funky bassline\nwith swing")
        await engine.waitForTurn()

        #expect(engine.chatTitle == "add a funky bassline with swing")
        #expect(store.chatsDirty)
        #expect(store.chatRevision > 0)
        #expect(!store.isDirty)  // a text-only turn is not musical work (L4)
    }

    @Test("reset() archives the conversation into the store and returns its id; the engine starts a fresh chat")
    func resetArchivesAndStartsFresh() async throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("done")])
        _ = try engine.send("hello")
        await engine.waitForTurn()
        let chatIDBefore = engine.currentChatID

        let result = engine.reset()

        #expect(result.archivedChatId == chatIDBefore)
        #expect(result.evictedChatId == nil)
        #expect(store.copilotChats.count == 1)
        #expect(store.copilotChats.first?.id == chatIDBefore)
        #expect(store.copilotChats.first?.title == "hello")
        #expect(store.copilotChats.first?.transcript.count == 2)  // user + assistant
        #expect(engine.transcript.isEmpty)
        #expect(engine.status == .idle)
        #expect(engine.currentTurnID == nil)
        #expect(engine.currentChatID != chatIDBefore)
        #expect(engine.chatTitle == nil)
    }

    @Test("reset() on an empty conversation archives nothing")
    func resetOnEmptyArchivesNothing() {
        let (engine, store, _) = makeEngine(scripted: [])
        let result = engine.reset()
        #expect(result.archivedChatId == nil)
        #expect(result.evictedChatId == nil)
        #expect(store.copilotChats.isEmpty)
    }

    @Test("reset() at the archive cap surfaces the evicted chat's id (§7.1, never silent)")
    func resetAtCapSurfacesEvictedId() async throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("ok")])
        var oldest: CopilotChatDocument?
        for index in 0..<CopilotChatLimits.maxArchivedChats {
            let chat = archivedChat(title: "old \(index)", updatedAt: 1_000 + TimeInterval(index))
            if index == 0 { oldest = chat }
            store.archiveCopilotChat(chat)
        }
        _ = try engine.send("the 21st conversation")
        await engine.waitForTurn()

        let result = engine.reset()
        #expect(result.evictedChatId == oldest?.id)
        #expect(store.copilotChats.count == CopilotChatLimits.maxArchivedChats)
    }

    @Test("the archived chat's provider history is thinking-free (L1 through the real reset path)")
    func resetArchivesThinkingFreeHistory() async throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"secret","signature":"sig-LEAK"}"#.utf8)
        let reply = CopilotReply(
            blocks: [
                .thinking(summary: "reasoning aloud", rawJSON: thinkingJSON),
                .text("Visible answer."),
            ],
            stopReason: .endTurn, provider: "fake")
        let (engine, store, _) = makeEngine(scripted: [reply])
        _ = try engine.send("think hard")
        await engine.waitForTurn()
        engine.reset()

        let archived = try #require(store.copilotChats.first)
        #expect(!archived.providerMessages.flatMap(\.blocks).contains { $0.type == "thinking" })
        // The visible answer and the display-side thinking summary survive.
        #expect(archived.providerMessages.last?.blocks.map(\.type) == ["text"])
        #expect(archived.transcript.contains { $0.kind == "thinking" && $0.text == "reasoning aloud" })
        let encoded = String(decoding: (try? JSONEncoder().encode(archived)) ?? Data(), as: UTF8.self)
        #expect(!encoded.contains("sig-LEAK"))
    }

    @Test("L2 turn-end strip: the NEXT turn's request carries the prior assistant message thinking-free; an all-thinking turn leaves the placeholder, never an empty message")
    func turnEndStripKeepsHistoryModelSwitchSafe() async throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"...","signature":"sig"}"#.utf8)
        let allThinking = CopilotReply(
            blocks: [.thinking(summary: "pondered silently", rawJSON: thinkingJSON)],
            stopReason: .endTurn, provider: "fake")
        let (engine, _, provider) = makeEngine(scripted: [allThinking, textReply("second turn done")])

        _ = try engine.send("first")
        await engine.waitForTurn()
        _ = try engine.send("second")
        await engine.waitForTurn()

        let requests = await provider.requests
        #expect(requests.count == 2)
        let priorAssistant = try #require(requests[1].messages.first { $0.role == .assistant })
        // Thinking gone at the turn boundary (L2) — and the message was NOT
        // dropped or left empty: the placeholder text block stands in.
        #expect(priorAssistant.blocks == [.text("(the model produced no visible output this turn)")])
    }

    @Test("persistableChatSnapshot() is nil for a fresh chat and drops in-flight partials (L3)")
    func snapshotProviderContract() throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("done")])
        // Fresh, empty chat → no snapshot (never noise-persisted).
        #expect(engine.persistableChatSnapshot() == nil)
        // The engine's init wired the store's provider closure to the same
        // method — the app bootstrap and the fixtures share it by construction.
        #expect(store.copilotActiveChatProvider != nil)
        #expect(store.copilotActiveChatProvider?() == nil)
    }

    @Test("a save captures the ACTIVE conversation through the wired provider closure (the instrumentStateProvider pattern)")
    func saveCapturesActiveChat() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chat-save-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let (engine, store, _) = makeEngine(scripted: [textReply("saved reply")])
        _ = try engine.send("persist me")
        await engine.waitForTurn()

        let path = dir.appendingPathComponent("Live").path
        _ = try store.saveProject(to: path)

        let document = try ProjectBundle.read(from: ProjectBundle.normalizedBundleURL(fromPath: path))
        let chats = try #require(document.copilotChats)
        #expect(chats.count == 1)
        #expect(chats[0].id == engine.currentChatID)
        #expect(chats[0].title == "persist me")
        #expect(chats[0].transcript.map(\.kind) == ["user", "assistant"])
        #expect(!store.chatsDirty)
    }

    @Test("resumeChat restores the transcript + history, adopts the chat identity, and the next turn's provider request carries the restored messages")
    func resumeRestoresAndContinues() async throws {
        let (engine, store, provider) = makeEngine(scripted: [textReply("continuing where we left off")])
        let chat = archivedChat(title: "magic word chat", droppedEntries: 3)
        store.archiveCopilotChat(chat)

        let result = try engine.resumeChat(id: chat.id)
        #expect(result.archivedChatId == nil)  // current chat was empty — nothing archived
        #expect(store.copilotChats.isEmpty)    // taken out of the archive
        #expect(engine.currentChatID == chat.id)
        #expect(engine.chatTitle == "magic word chat")
        #expect(engine.chatDroppedEntries == 3)  // inherited honesty (L6)
        #expect(engine.status == .idle)
        #expect(engine.transcript.count == 2)
        #expect(engine.transcript.allSatisfy { !$0.partial })

        _ = try engine.send("what was the magic word?")
        await engine.waitForTurn()

        let request = try #require(await provider.requests.first)
        // The restored exchange precedes the new question in provider history.
        guard case .text(let restoredHead) = try #require(request.messages.first).blocks.first else {
            Issue.record("expected restored user text at the head"); return
        }
        #expect(restoredHead == "remember the magic word xyzzy")
        #expect(request.messages.count == 3)  // restored user + assistant, then the new ask
    }

    @Test("resumeChat archives the current non-empty conversation first (L5 — never lost)")
    func resumeArchivesCurrentFirst() async throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("first chat reply")])
        _ = try engine.send("first conversation")
        await engine.waitForTurn()
        let firstChatID = engine.currentChatID

        let chat = archivedChat()
        store.archiveCopilotChat(chat)
        let result = try engine.resumeChat(id: chat.id)

        #expect(result.archivedChatId == firstChatID)
        #expect(store.copilotChats.count == 1)  // the swapped-out chat took its place
        #expect(store.copilotChats.first?.id == firstChatID)
        #expect(engine.currentChatID == chat.id)
    }

    @Test("resumeChat while a turn is running throws the exact teaching error and changes nothing")
    func resumeWhileRunningThrows() async throws {
        let (engine, store, _) = makeEngine(
            scripted: [textReply("slow")], delayNanoseconds: 200_000_000)
        let chat = archivedChat()
        store.archiveCopilotChat(chat)
        _ = try engine.send("busy now")
        #expect(engine.status == .running)

        do {
            _ = try engine.resumeChat(id: chat.id)
            Issue.record("resumeChat should throw while running")
        } catch let error as ControlError {
            #expect(error.message ==
                "a copilot turn is already running — wait for it (poll ai.copilotState) "
                + "or ai.copilotReset to cancel and archive it first")
        }
        #expect(store.copilotChats.count == 1)  // untouched
        engine.cancel()
        await engine.waitForTurn()
    }

    @Test("resumeChat with an unknown id throws the teaching error without archiving anything")
    func resumeUnknownIdThrows() async throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("reply")])
        _ = try engine.send("current work")
        await engine.waitForTurn()
        let unknown = UUID()

        do {
            _ = try engine.resumeChat(id: unknown)
            Issue.record("resumeChat should throw for an unknown id")
        } catch let error as ControlError {
            #expect(error.message == "unknown chatId '\(unknown.uuidString)' — list chats with ai.copilotChats")
        }
        // The current conversation was NOT archived on the failed resume.
        #expect(store.copilotChats.isEmpty)
        #expect(!engine.transcript.isEmpty)
    }

    @Test("a resumed chat with a broken tool pairing resumes display-only: transcript intact, provider history sanitized to empty")
    func resumeWithBrokenPairingIsDisplayOnly() async throws {
        var chat = archivedChat(title: "hand-edited")
        chat.providerMessages = [
            .init(role: "user", blocks: [.init(type: "text", text: "ask")]),
            .init(role: "assistant", blocks: [
                .init(type: "toolUse", toolUseId: "call_A", name: "track_add", inputJSON: "{}"),
            ]),
            .init(role: "user", blocks: [
                .init(type: "toolResult", toolUseId: "call_WRONG", content: "?", isError: false),
            ]),
        ]
        let (engine, store, provider) = makeEngine(scripted: [textReply("fresh context reply")])
        store.archiveCopilotChat(chat)
        _ = try engine.resumeChat(id: chat.id)

        #expect(engine.transcript.count == 2)  // the display transcript survives

        _ = try engine.send("continue")
        await engine.waitForTurn()
        let request = try #require(await provider.requests.first)
        // Fresh provider context: ONLY the new ask went to the model.
        #expect(request.messages.count == 1)
    }

    @Test("deleteChat(active) while idle drops the conversation permanently and mints a fresh chat; while running it throws")
    func deleteActiveChatRules() async throws {
        let (engine, store, _) = makeEngine(
            scripted: [textReply("one"), textReply("two")], delayNanoseconds: 100_000_000)
        _ = try engine.send("delete me later")
        await engine.waitForTurn()
        let activeID = engine.currentChatID

        // Running → the teaching error, nothing dropped.
        _ = try engine.send("second turn")
        #expect(engine.status == .running)
        do {
            _ = try engine.deleteChat(id: engine.currentChatID)
            Issue.record("deleteChat(active) should throw while running")
        } catch let error as ControlError {
            #expect(error.message.contains("the active conversation and a turn is running"))
            #expect(error.message.contains("ai.copilotReset"))
        }
        await engine.waitForTurn()

        // Idle → allowed: permanent drop, fresh chat, nothing archived.
        let wasActive = try engine.deleteChat(id: activeID)
        #expect(wasActive)
        #expect(engine.transcript.isEmpty)
        #expect(engine.status == .idle)
        #expect(engine.currentChatID != activeID)
        #expect(store.copilotChats.isEmpty)  // deleted, NOT archived (the one destructive verb)
    }

    @Test("deleteChat on an archived id removes it; an unknown id throws the teaching error")
    func deleteArchivedAndUnknown() throws {
        let (engine, store, _) = makeEngine(scripted: [])
        let chat = archivedChat()
        store.archiveCopilotChat(chat)

        #expect(try engine.deleteChat(id: chat.id) == false)  // wasActive: false
        #expect(store.copilotChats.isEmpty)

        let unknown = UUID()
        do {
            _ = try engine.deleteChat(id: unknown)
            Issue.record("deleteChat should throw for an unknown id")
        } catch let error as ControlError {
            #expect(error.message == "unknown chatId '\(unknown.uuidString)' — list chats with ai.copilotChats")
        }
    }

    @Test("renameChat renames the active chat (clamped to 120 chars) and archived chats; unknown ids throw")
    func renameActiveAndArchived() async throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("ok")])
        _ = try engine.send("original")
        await engine.waitForTurn()

        try engine.renameChat(id: engine.currentChatID, title: String(repeating: "r", count: 300))
        #expect(engine.chatTitle?.count == CopilotChatLimits.maxTitleLength)

        let chat = archivedChat()
        store.archiveCopilotChat(chat)
        try engine.renameChat(id: chat.id, title: "renamed archive")
        #expect(store.copilotChats.first?.title == "renamed archive")

        #expect(throws: ControlError.self) {
            try engine.renameChat(id: UUID(), title: "nope")
        }
    }

    @Test("projectDidTransition clears the conversation WITHOUT archiving — wired through the store's boundary handler on project.new")
    func projectTransitionClearsWithoutArchiving() async throws {
        let (engine, store, _) = makeEngine(scripted: [textReply("pre-transition reply")])
        _ = try engine.send("work in the old project")
        await engine.waitForTurn()
        #expect(!engine.transcript.isEmpty)
        let chatIDBefore = engine.currentChatID

        // The engine's init wired store.copilotProjectBoundaryHandler; a real
        // project.new must clear the engine through it.
        try store.newProject(discardChanges: true)

        #expect(engine.transcript.isEmpty)
        #expect(engine.status == .idle)
        #expect(engine.currentChatID != chatIDBefore)
        #expect(store.copilotChats.isEmpty)  // cleared, never archived (§4.5)
    }

    @Test("§5.4 generation guard: a project replacement mid-turn cancels the turn before any tool dispatch lands on the new project")
    func generationGuardStopsStaleToolDispatch() async throws {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider(
            [
                toolReply(name: "track_add", args: ["name": .string("Stale Track")]),
                textReply("never reached"),
            ],
            midStreamProbes: [{ @MainActor in
                // Replace the project WHILE round 1's reply is still in
                // flight. The boundary handler is deliberately UNWIRED below,
                // so only the §5.4 generation guard stands between the stale
                // turn and the new project — belt & suspenders, tested alone.
                try? store.newProject(discardChanges: true)
            }])
        let engine = CopilotEngine(
            store: store, dispatch: { await router.handle($0) }, provider: { provider })
        store.copilotProjectBoundaryHandler = nil  // isolate the §5.4 guard

        _ = try engine.send("add a track")
        await engine.waitForTurn()

        #expect(engine.status == .cancelled)
        #expect(store.tracks.isEmpty)  // NO stale tool edit landed on the new project
        #expect(engine.transcript.contains {
            if case .failure(let text) = $0.kind { return text == "project changed mid-turn — cancelled" }
            return false
        })
    }

    @Test("§5.5 regression: reset() during an in-flight provider await leaves the fresh session untouched — no stray 'cancelled' entry, no status overwrite")
    func resetDuringTurnLeavesFreshStateClean() async throws {
        let (engine, store, _) = makeEngine(
            scripted: [textReply("too slow")], delayNanoseconds: 100_000_000)
        _ = try engine.send("take your time")
        #expect(engine.status == .running)

        let result = engine.reset()
        // The in-flight turn had a live user entry — reset archives it (L5).
        #expect(result.archivedChatId != nil)
        #expect(store.copilotChats.count == 1)

        // Let the cancelled task's catch path run to completion.
        try await Task.sleep(nanoseconds: 300_000_000)

        // The fresh session is pristine: the old turn's catch must not have
        // appended its failure entry or overwritten `.idle` with `.cancelled`.
        #expect(engine.status == .idle)
        #expect(engine.transcript.isEmpty)
        #expect(engine.currentTurnID == nil)
    }

    @Test("seedForCapture stages the truncation banner and derives the chat title (Phase D additive params)")
    func seedForCaptureStagesDroppedEntriesAndTitle() throws {
        let (engine, _, _) = makeEngine(scripted: [])

        engine.seedForCapture(
            turnID: "seed", status: .done,
            entries: [.user("brighten the mix a little"), .assistant("Done.")],
            droppedEntries: 40)
        #expect(engine.chatDroppedEntries == 40)
        // The title derives from the seeded first user entry, so the rail's
        // current-chat header line reads honestly over a seeded fake.
        #expect(engine.chatTitle == "brighten the mix a little")
        // The additive `droppedEntries` field rides `ai.copilotState` (L6).
        guard case .object(let state) = engine.stateJSON(turnID: nil) else {
            Issue.record("expected an object state"); return
        }
        #expect(state["droppedEntries"] == .number(40))

        // A fresh seed never inherits the previous seed's banner or title.
        engine.seedForCapture(turnID: "seed2", status: .done, entries: [.assistant("Hello.")])
        #expect(engine.chatDroppedEntries == 0)
        #expect(engine.chatTitle == nil)
        guard case .object(let cleared) = engine.stateJSON(turnID: nil) else {
            Issue.record("expected an object state"); return
        }
        #expect(cleared["droppedEntries"] == nil)
    }
}
