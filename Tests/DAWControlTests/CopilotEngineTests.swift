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
actor FakeCopilotProvider: CopilotProviding {
    private var scripted: [CopilotReply]
    private let delayNanoseconds: UInt64
    private(set) var requests: [CopilotTurnRequest] = []

    init(_ scripted: [CopilotReply], delayNanoseconds: UInt64 = 0) {
        self.scripted = scripted
        self.delayNanoseconds = delayNanoseconds
    }

    func complete(_ request: CopilotTurnRequest) async throws -> CopilotReply {
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        requests.append(request)
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
        delayNanoseconds: UInt64 = 0
    ) -> (engine: CopilotEngine, store: ProjectStore, provider: FakeCopilotProvider) {
        let store = ProjectStore()
        let router = CommandRouter(store: store)
        let provider = FakeCopilotProvider(scripted, delayNanoseconds: delayNanoseconds)
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

    @Test("zero blocks in a reply completes the turn with a synthetic '(no response)' entry")
    func zeroBlockReply() async throws {
        let empty = CopilotReply(blocks: [], stopReason: .endTurn, provider: "fake")
        let (engine, _, _) = makeEngine(scripted: [empty])
        _ = try engine.send("...")
        await engine.waitForTurn()

        #expect(engine.status == .done)
        let hasSyntheticEntry = engine.transcript.contains {
            if case .assistant(let text) = $0.kind { return text == "(no response)" }
            return false
        }
        #expect(hasSyntheticEntry)
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
}
