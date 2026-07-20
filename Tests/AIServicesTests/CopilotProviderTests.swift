import Foundation
import Testing
@testable import AIServices

/// Suite A (M6 rail-b): request-shape pinning + response parsing for
/// `AnthropicCopilotProvider`/`OpenAICopilotProvider`, plus the
/// `resolveCopilotProvider` chain. Reuses `StubTextAPIServer`
/// (LyricsWriterTests.swift) — the same loopback stub-HTTP precedent, so no
/// new server plumbing is introduced.

// MARK: - Shared fixtures

private let toolSchema = Data(#"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#.utf8)

private func sampleTools() -> [CopilotToolSpec] {
    [CopilotToolSpec(name: "track_add", description: "Adds a new track to the project.", inputSchemaJSON: toolSchema)]
}

/// A short history with an INTACT tool_use/tool_result pair: user text →
/// assistant tool_use → user tool_result — exercising exactly the shape the
/// engine feeds back each round (design §5).
private func historyWithToolPair() -> [CopilotMessage] {
    let inputJSON = Data(#"{"name":"Drums"}"#.utf8)
    return [
        CopilotMessage(role: .user, blocks: [.text("add a drum track")]),
        CopilotMessage(
            role: .assistant,
            blocks: [.toolUse(id: "call_1", name: "track_add", inputJSON: inputJSON)]),
        CopilotMessage(
            role: .user,
            blocks: [.toolResult(id: "call_1", content: #"{"trackId":"abc12345"}"#, isError: false)]),
    ]
}

private func turnRequest(maxTokens: Int? = 4096) -> CopilotTurnRequest {
    CopilotTurnRequest(
        system: "you are the copilot inside DAW Pro",
        messages: historyWithToolPair(),
        tools: sampleTools(),
        maxTokens: maxTokens)
}

/// Reads the outgoing request body as a JSON object.
private func bodyJSON(_ data: Data?) throws -> [String: Any] {
    let data = try #require(data)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// Byte-order-independent JSON object equality (`JSONSerialization` does not
/// guarantee multi-key ordering across encode/decode round trips).
private func jsonObjectsEqual(_ lhs: Data, _ rhs: Data) throws -> Bool {
    let l = try JSONSerialization.jsonObject(with: lhs) as? NSDictionary
    let r = try JSONSerialization.jsonObject(with: rhs) as? NSDictionary
    return l == r
}

/// Wraps a canned `[String]` line array as an `AsyncStream<String>` — since
/// `assembleSSE` now consumes a generic `AsyncSequence` (M10-p-6-c: it must
/// process lines LIVE, never buffer them into an array first), a test that
/// wants to drive it DIRECTLY (bypassing `provider.complete`/the loopback
/// stub server entirely) needs this tiny adapter. Yields every line then
/// finishes immediately (no artificial delay) — fine for a test that only
/// cares about the FINAL assembled content, not live-delivery timing (the
/// dedicated liveness test below drives its own hand-built `AsyncStream`
/// instead, since it specifically controls WHEN each line arrives).
private func linesStream(_ lines: [String]) -> AsyncStream<String> {
    AsyncStream { continuation in
        for line in lines { continuation.yield(line) }
        continuation.finish()
    }
}

/// The RAW `event:`/`data:` line pairs for a canned event list — i.e. what
/// `URLSession.AsyncBytes.lines` decodes an SSE body down to (no blank
/// separator lines; per `assembleSSE`'s doc comment, those aren't reliably
/// preserved anyway, so they're never relied on). Companion to `sseResponse`
/// below, which wraps the same shape into a full HTTP `Data` response for the
/// loopback stub server; this one skips the HTTP envelope entirely for tests
/// that call `assembleSSE` directly via `linesStream`.
private func rawSSELines(_ events: [(event: String, data: [String: Any])]) -> [String] {
    var lines: [String] = []
    for (event, data) in events {
        let json = try! JSONSerialization.data(withJSONObject: data)
        lines.append("event: \(event)")
        lines.append("data: \(String(data: json, encoding: .utf8)!)")
    }
    return lines
}

/// Collects `CopilotStreamEvent`s in the order `onEvent` fires them — an
/// actor so the `@Sendable` closure `AnthropicCopilotProvider.complete`
/// invokes can safely append across the network-read loop.
private actor StreamEventRecorder {
    private(set) var events: [CopilotStreamEvent] = []
    func record(_ event: CopilotStreamEvent) {
        events.append(event)
    }
}

// MARK: - SSE stub-response fixtures (AnthropicCopilotProvider now streams)

/// A real `text/event-stream` HTTP response: one "event: <name>\ndata:
/// <json>\n\n" block per entry. `StubTextAPIServer` is a genuine TCP
/// responder (LyricsWriterTests.swift), so this exercises the SAME
/// `URLSession.shared.bytes(for:)` streaming path
/// `AnthropicCopilotProvider.complete` uses in production — no
/// application-level mocking, matching `StubTextAPIServer.jsonResponse`'s own
/// house style.
private func sseResponse(_ events: [(event: String, data: [String: Any])]) -> Data {
    var body = ""
    for (event, data) in events {
        let json = try! JSONSerialization.data(withJSONObject: data)
        body += "event: \(event)\ndata: \(String(data: json, encoding: .utf8)!)\n\n"
    }
    let bodyData = Data(body.utf8)
    var header = "HTTP/1.1 200 OK\r\n"
    header += "Content-Type: text/event-stream\r\n"
    header += "Content-Length: \(bodyData.count)\r\n"
    header += "Connection: close\r\n\r\n"
    return Data(header.utf8) + bodyData
}

/// Wraps a list of already-COMPLETE (delta-free) content blocks in the
/// minimal SSE envelope every real `/v1/messages` stream carries:
/// `message_start`, one `content_block_start`/`content_block_stop` pair per
/// block with NO `_delta` events (`assembleSSE` seeds a block straight from
/// `content_block`'s own fields, so an already-complete block needs no
/// deltas to reassemble correctly), `message_delta` (stop_reason),
/// `message_stop`. NOT valid for a `tool_use` block — `assembleSSE` always
/// reconstructs `input` from `input_json_delta` accumulation at
/// `content_block_stop`, discarding whatever rode along in
/// `content_block_start`, so a tool_use fixture must use `toolUseSSEEvents`
/// instead (see the tests that mix the two).
private func minimalSSEResponse(content: [[String: Any]], stopReason: String) -> Data {
    var events: [(event: String, data: [String: Any])] = [("message_start", ["type": "message_start"])]
    for (index, block) in content.enumerated() {
        events.append(("content_block_start", ["type": "content_block_start", "index": index, "content_block": block]))
        events.append(("content_block_stop", ["type": "content_block_stop", "index": index]))
    }
    events.append(("message_delta", ["type": "message_delta", "delta": ["stop_reason": stopReason]]))
    events.append(("message_stop", ["type": "message_stop"]))
    return sseResponse(events)
}

/// The event sequence a REAL tool_use block streams as: `content_block_start`
/// with an EMPTY `input`, one or more `input_json_delta` chunks (split across
/// several deltas when `partialJSONChunks.count > 1`, exactly like a real
/// argument object arriving piecemeal), then `content_block_stop`.
private func toolUseSSEEvents(
    index: Int, id: String, name: String, partialJSONChunks: [String]
) -> [(event: String, data: [String: Any])] {
    var events: [(event: String, data: [String: Any])] = [
        ("content_block_start", [
            "type": "content_block_start", "index": index,
            "content_block": ["type": "tool_use", "id": id, "name": name, "input": [String: Any]()],
        ]),
    ]
    for chunk in partialJSONChunks {
        events.append(("content_block_delta", [
            "type": "content_block_delta", "index": index,
            "delta": ["type": "input_json_delta", "partial_json": chunk],
        ]))
    }
    events.append(("content_block_stop", ["type": "content_block_stop", "index": index]))
    return events
}

// MARK: - Anthropic wire shape

@Suite("AnthropicCopilotProvider — request shape + reply parsing against a stub")
struct AnthropicCopilotProviderTests {
    @Test("pins model/max_tokens/stream/system/tools[].{name,description,input_schema}, message roles, and matched tool_use/tool_result ids; headers carry x-api-key + anthropic-version")
    func requestShape() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(content: [["type": "text", "text": "ok"]], stopReason: "end_turn"),
            forKey: "POST /v1/messages")

        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        _ = try await provider.complete(turnRequest(maxTokens: 777))

        #expect(server.callCount(forKey: "POST /v1/messages") == 1)
        let headers = server.lastHeaders(forKey: "POST /v1/messages")
        #expect(headers["x-api-key"] == "sk-ant-STUBKEY")
        #expect(headers["anthropic-version"] == "2023-06-01")

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        #expect(body["model"] as? String == "claude-sonnet-5")
        #expect(body["max_tokens"] as? Int == 777)   // explicit maxTokens passes through unchanged
        #expect(body["stream"] as? Bool == true)
        #expect(body["system"] as? String == "you are the copilot inside DAW Pro")

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools.count == 1)
        #expect(tools[0]["name"] as? String == "track_add")
        #expect(tools[0]["description"] as? String == "Adds a new track to the project.")
        let schema = try #require(tools[0]["input_schema"] as? [String: Any])
        #expect(schema["type"] as? String == "object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        #expect(messages.count == 3)
        #expect(messages[0]["role"] as? String == "user")
        let userContent = try #require(messages[0]["content"] as? [[String: Any]])
        #expect(userContent[0]["type"] as? String == "text")
        #expect(userContent[0]["text"] as? String == "add a drum track")

        #expect(messages[1]["role"] as? String == "assistant")
        let assistantContent = try #require(messages[1]["content"] as? [[String: Any]])
        #expect(assistantContent[0]["type"] as? String == "tool_use")
        #expect(assistantContent[0]["id"] as? String == "call_1")
        #expect(assistantContent[0]["name"] as? String == "track_add")
        let input = try #require(assistantContent[0]["input"] as? [String: Any])
        #expect(input["name"] as? String == "Drums")

        #expect(messages[2]["role"] as? String == "user")
        let resultContent = try #require(messages[2]["content"] as? [[String: Any]])
        #expect(resultContent[0]["type"] as? String == "tool_result")
        // tool_use/tool_result ids stay matched across the pair.
        #expect(resultContent[0]["tool_use_id"] as? String == "call_1")
        #expect(resultContent[0]["content"] as? String == #"{"trackId":"abc12345"}"#)
        #expect(resultContent[0]["is_error"] as? Bool == false)
    }

    @Test("text-only reply with stop_reason end_turn parses to a single .text block")
    func parsesTextOnlyEndTurn() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(content: [["type": "text", "text": "Done!"]], stopReason: "end_turn"),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks == [.text("Done!")])
        #expect(reply.stopReason == .endTurn)
        #expect(reply.provider == "anthropic")
    }

    @Test("a single tool_use reply (input arriving via input_json_delta) parses id/name/input and stop_reason tool_use")
    func parsesSingleToolUse() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        var events: [(event: String, data: [String: Any])] = [("message_start", ["type": "message_start"])]
        events += toolUseSSEEvents(
            index: 0, id: "call_9", name: "transport_play", partialJSONChunks: [#"{"fromBeat":0}"#])
        events.append(("message_delta", ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]))
        events.append(("message_stop", ["type": "message_stop"]))
        server.setResponse(sseResponse(events), forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks.count == 1)
        guard case .toolUse(let id, let name, let inputJSON) = reply.blocks[0] else {
            Issue.record("expected a .toolUse block, got \(reply.blocks[0])")
            return
        }
        #expect(id == "call_9")
        #expect(name == "transport_play")
        #expect(try jsonObjectsEqual(inputJSON, Data(#"{"fromBeat":0}"#.utf8)))
        #expect(reply.stopReason == .toolUse)
    }

    @Test("multiple tool_use blocks in one reply parse in order, all captured")
    func parsesMultipleToolUseBlocks() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        var events: [(event: String, data: [String: Any])] = [
            ("message_start", ["type": "message_start"]),
            ("content_block_start", ["type": "content_block_start", "index": 0,
                                      "content_block": ["type": "text", "text": "On it."]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
        ]
        events += toolUseSSEEvents(index: 1, id: "call_1", name: "track_add", partialJSONChunks: [#"{"name":"Drums"}"#])
        events += toolUseSSEEvents(index: 2, id: "call_2", name: "track_add", partialJSONChunks: [#"{"name":"Bass"}"#])
        events.append(("message_delta", ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]))
        events.append(("message_stop", ["type": "message_stop"]))
        server.setResponse(sseResponse(events), forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks.count == 3)
        #expect(reply.blocks[0] == .text("On it."))
        guard case .toolUse(let id1, let name1, let input1) = reply.blocks[1] else {
            Issue.record("expected .toolUse at index 1"); return
        }
        #expect(id1 == "call_1")
        #expect(name1 == "track_add")
        #expect(try jsonObjectsEqual(input1, Data(#"{"name":"Drums"}"#.utf8)))
        guard case .toolUse(let id2, let name2, let input2) = reply.blocks[2] else {
            Issue.record("expected .toolUse at index 2"); return
        }
        #expect(id2 == "call_2")
        #expect(name2 == "track_add")
        #expect(try jsonObjectsEqual(input2, Data(#"{"name":"Bass"}"#.utf8)))
    }

    @Test("stop_reason max_tokens maps to .maxTokens")
    func maxTokensStopReason() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(content: [["type": "text", "text": "partial"]], stopReason: "max_tokens"),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())
        #expect(reply.stopReason == .maxTokens)
    }

    @Test("a thinking block preceding text+tool_use is preserved as .thinking (summary extracted), in position; the conversation still parses")
    func thinkingBlockPrecedingTextAndToolUse() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        var events: [(event: String, data: [String: Any])] = [
            ("message_start", ["type": "message_start"]),
            ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": [
                "type": "thinking", "thinking": "deciding which tool to call...", "signature": "sig-abc",
            ]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
            ("content_block_start", ["type": "content_block_start", "index": 1,
                                      "content_block": ["type": "text", "text": "On it."]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 1]),
        ]
        events += toolUseSSEEvents(index: 2, id: "call_1", name: "track_add", partialJSONChunks: [#"{"name":"Drums"}"#])
        events.append(("message_delta", ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]))
        events.append(("message_stop", ["type": "message_stop"]))
        server.setResponse(sseResponse(events), forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks.count == 3)
        guard case .thinking(let summary, let rawJSON) = reply.blocks[0] else {
            Issue.record("expected .thinking at index 0, got \(reply.blocks[0])")
            return
        }
        #expect(summary == "deciding which tool to call...")
        #expect(try jsonObjectsEqual(
            rawJSON,
            Data(#"{"type":"thinking","thinking":"deciding which tool to call...","signature":"sig-abc"}"#.utf8)))
        #expect(reply.blocks[1] == .text("On it."))
        guard case .toolUse(let id, let name, let input) = reply.blocks[2] else {
            Issue.record("expected .toolUse at index 2, got \(reply.blocks[2])")
            return
        }
        #expect(id == "call_1")
        #expect(name == "track_add")
        #expect(try jsonObjectsEqual(input, Data(#"{"name":"Drums"}"#.utf8)))
        #expect(reply.stopReason == .toolUse)
    }

    @Test("thinking block content:[thinking(signature+text), text] parses to [.thinking, .text] (summary extracted) and round-trips byte-for-byte through wireContent")
    func thinkingThenTextRoundTripsThroughWireContent() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(
                content: [
                    ["type": "thinking", "thinking": "stepping through the request...", "signature": "sig-round-trip"],
                    ["type": "text", "text": "Here's my answer."],
                ],
                stopReason: "end_turn"),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks.count == 2)
        guard case .thinking(let summary, _) = reply.blocks[0] else {
            Issue.record("expected .thinking at index 0, got \(reply.blocks[0])")
            return
        }
        #expect(summary == "stepping through the request...")
        #expect(reply.blocks[1] == .text("Here's my answer."))

        // The thinking block's rawJSON round-trips through wireContent to a
        // semantically identical JSON object (signature included) — the
        // engine re-sends this exact message as history on the next round.
        let wire = try AnthropicCopilotProvider.wireContent(reply.blocks)
        #expect(wire.count == 2)
        let wireThinking = wire[0]
        #expect(wireThinking["type"] as? String == "thinking")
        #expect(wireThinking["thinking"] as? String == "stepping through the request...")
        #expect(wireThinking["signature"] as? String == "sig-round-trip")
    }

    @Test("all-thinking content with stop_reason max_tokens parses to blocks containing only .thinking, with an EMPTY summary (display: \"omitted\")")
    func allThinkingMaxTokensReply() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(
                content: [["type": "thinking", "thinking": "", "signature": "sig-omitted"]],
                stopReason: "max_tokens"),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks.count == 1)
        guard case .thinking(let summary, _) = reply.blocks[0] else {
            Issue.record("expected .thinking, got \(reply.blocks[0])")
            return
        }
        #expect(summary.isEmpty)
        #expect(reply.stopReason == .maxTokens)
    }

    @Test("redacted_thinking is preserved as .thinking with an EMPTY summary (its real content is `data`, never shown); a truly unknown block type is still skipped")
    func redactedThinkingPreservedUnknownSkipped() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(
                content: [
                    ["type": "redacted_thinking", "data": "encrypted-blob"],
                    ["type": "some_future_block_kind", "stuff": "whatever"],
                    ["type": "text", "text": "Done."],
                ],
                stopReason: "end_turn"),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        // The unknown block type is skipped; only the redacted_thinking (as
        // .thinking) and the text block survive.
        #expect(reply.blocks.count == 2)
        guard case .thinking(let summary, let rawJSON) = reply.blocks[0] else {
            Issue.record("expected .thinking at index 0, got \(reply.blocks[0])")
            return
        }
        #expect(summary.isEmpty)
        #expect(try jsonObjectsEqual(rawJSON, Data(#"{"type":"redacted_thinking","data":"encrypted-blob"}"#.utf8)))
        #expect(reply.blocks[1] == .text("Done."))
    }

    @Test("an error envelope (e.g. 529 overloaded_error) throws with the API's own type/message")
    func errorEnvelopeSurfacesAPIMessage() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                status: 529,
                #"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        do {
            _ = try await provider.complete(turnRequest())
            Issue.record("expected complete to throw")
        } catch let error as AIServiceError {
            let message = try #require(error.errorDescription)
            #expect(message.contains("overloaded_error"))
            #expect(message.contains("Overloaded"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    @Test("an HTTP 401 maps to AIServiceError.requestFailed")
    func httpErrorMapsToRequestFailed() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(status: 401, #"{"error":"invalid key"}"#),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        await #expect(throws: AIServiceError.self) {
            _ = try await provider.complete(turnRequest())
        }
    }

    @Test("a non-JSON body throws .malformedResponse with an actionable, key-free message")
    func garbageBodyMapsToMalformedResponse() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.jsonResponse("not json at all {{{"), forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        do {
            _ = try await provider.complete(turnRequest())
            Issue.record("expected .malformedResponse to be thrown")
        } catch let error as AIServiceError {
            guard case .malformedResponse = error else {
                Issue.record("expected .malformedResponse, got \(error)")
                return
            }
            let message = try #require(error.errorDescription)
            #expect(!message.isEmpty)
            #expect(!message.contains("sk-ant-STUBKEY"))
        }
    }

    // MARK: - No artificial limit: streaming (user directive — "let's not limit the tokens")

    @Test("nil maxTokens sends the model's looked-up max_tokens ceiling and stream:true")
    func nilMaxTokensUsesModelLookupAndStreams() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(content: [["type": "text", "text": "ok"]], stopReason: "end_turn"),
            forKey: "POST /v1/messages")

        // server.config()'s AIConfig defaults anthropicModel to "claude-sonnet-5".
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        _ = try await provider.complete(turnRequest(maxTokens: nil))

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        #expect(body["max_tokens"] as? Int == 128_000)
        #expect(body["stream"] as? Bool == true)
    }

    // MARK: - Extended thinking request config, per model (M10-p-6)

    @Test("claude-sonnet-5 (display:\"omitted\" default) requests adaptive thinking with display:summarized")
    func sonnet5RequestsSummarizedThinking() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(content: [["type": "text", "text": "ok"]], stopReason: "end_turn"),
            forKey: "POST /v1/messages")
        // server.config()'s AIConfig defaults anthropicModel to "claude-sonnet-5".
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        _ = try await provider.complete(turnRequest())

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] as? String == "summarized")
    }

    @Test("claude-sonnet-4-6 (pre-\"display\" field) requests bare adaptive thinking, no display key")
    func sonnet46RequestsBareAdaptiveThinking() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(content: [["type": "text", "text": "ok"]], stopReason: "end_turn"),
            forKey: "POST /v1/messages")
        var config = server.config(anthropicKey: "sk-ant-STUBKEY")
        config.anthropicModel = "claude-sonnet-4-6"
        let provider = AnthropicCopilotProvider(config: config)
        _ = try await provider.complete(turnRequest())

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        let thinking = try #require(body["thinking"] as? [String: Any])
        #expect(thinking["type"] as? String == "adaptive")
        #expect(thinking["display"] == nil)
    }

    @Test("claude-haiku-4-5 (pre-adaptive-thinking) omits the thinking key from the request body entirely")
    func haikuOmitsThinkingKey() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            minimalSSEResponse(content: [["type": "text", "text": "ok"]], stopReason: "end_turn"),
            forKey: "POST /v1/messages")
        var config = server.config(anthropicKey: "sk-ant-STUBKEY")
        config.anthropicModel = "claude-haiku-4-5"
        let provider = AnthropicCopilotProvider(config: config)
        _ = try await provider.complete(turnRequest())

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        #expect(body["thinking"] == nil)
        // Still the right, smaller ceiling — the thinking omission and the
        // max-output lookup are independent columns of the SAME table.
        #expect(body["max_tokens"] as? Int == 4096)   // turnRequest()'s explicit default maxTokens
    }

    @Test("a fully delta-driven SSE transcript (thinking deltas + signature, text deltas, split tool_use input) assembles to the SAME CopilotReply as the equivalent non-streaming fixture")
    func sseAssemblyMatchesNonStreamingEquivalent() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }

        var events: [(event: String, data: [String: Any])] = [
            ("message_start", ["type": "message_start"]),
            // Block 0: thinking, built from TWO thinking_delta chunks + a signature_delta.
            ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": [
                "type": "thinking", "thinking": "", "signature": "",
            ]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "thinking_delta", "thinking": "weighing the "]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "thinking_delta", "thinking": "options..."]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "signature_delta", "signature": "sig-delta-assembled"]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
            // Block 1: text, built from TWO text_delta chunks.
            ("content_block_start", ["type": "content_block_start", "index": 1,
                                      "content_block": ["type": "text", "text": ""]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 1,
                                      "delta": ["type": "text_delta", "text": "Adding the "]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 1,
                                      "delta": ["type": "text_delta", "text": "track now."]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 1]),
        ]
        // Block 2: tool_use, input split across THREE input_json_delta chunks.
        events += toolUseSSEEvents(
            index: 2, id: "call_1", name: "track_add",
            partialJSONChunks: [#"{"na"#, #"me":"Dru"#, #"ms"}"#])
        events.append(("message_delta", ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]))
        events.append(("message_stop", ["type": "message_stop"]))
        server.setResponse(sseResponse(events), forKey: "POST /v1/messages")

        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let streamedReply = try await provider.complete(turnRequest())

        // The equivalent already-complete (non-streaming) fixture, parsed
        // through the SAME `parseReply` the assembled SSE dict also runs
        // through — streaming must be a transport/assembly concern only.
        let nonStreamingJSON = Data(#"""
        {"content":[
            {"type":"thinking","thinking":"weighing the options...","signature":"sig-delta-assembled"},
            {"type":"text","text":"Adding the track now."},
            {"type":"tool_use","id":"call_1","name":"track_add","input":{"name":"Drums"}}
        ],"stop_reason":"tool_use"}
        """#.utf8)
        let nonStreamingReply = try AnthropicCopilotProvider.parseReply(nonStreamingJSON, status: 200)

        // Compare block-by-block rather than via `CopilotReply`'s derived
        // `==`: a `.thinking` block's `rawJSON` is a `Data` byte-compare, and
        // `JSONSerialization` does not guarantee identical key ORDER between
        // two independently-built dictionaries with the same keys/values
        // (see `jsonObjectsEqual`'s own doc comment above) — the streamed and
        // non-streaming paths build their `[String: Any]` differently even
        // though they're semantically identical, so `.thinking` needs the
        // same order-independent comparison every other JSON-payload test
        // here uses (its `summary` half is an ordinary `String ==`, so a
        // straight `.thinking == .thinking` still isn't safe to use here).
        #expect(streamedReply.blocks.count == nonStreamingReply.blocks.count)
        #expect(streamedReply.stopReason == nonStreamingReply.stopReason)
        #expect(streamedReply.stopReason == .toolUse)
        for (streamedBlock, fixtureBlock) in zip(streamedReply.blocks, nonStreamingReply.blocks) {
            switch (streamedBlock, fixtureBlock) {
            case (.thinking(let streamedSummary, let streamedJSON), .thinking(let fixtureSummary, let fixtureJSON)):
                #expect(streamedSummary == fixtureSummary)
                #expect(try jsonObjectsEqual(streamedJSON, fixtureJSON))
            default:
                #expect(streamedBlock == fixtureBlock)
            }
        }

        guard case .thinking(let summary, let rawJSON) = streamedReply.blocks[0] else {
            Issue.record("expected .thinking at index 0, got \(streamedReply.blocks[0])")
            return
        }
        #expect(summary == "weighing the options...")
        #expect(try jsonObjectsEqual(
            rawJSON,
            Data(#"{"type":"thinking","thinking":"weighing the options...","signature":"sig-delta-assembled"}"#.utf8)))
    }

    @Test("onEvent fires ordered thinkingDelta/textDelta events with the correct blockIndex, in the order the SSE stream produced them — no event for the tool_use block (partial JSON isn't displayable)")
    func onEventFiresOrderedDeltasWithBlockIndexes() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }

        var events: [(event: String, data: [String: Any])] = [
            ("message_start", ["type": "message_start"]),
            ("content_block_start", ["type": "content_block_start", "index": 0, "content_block": [
                "type": "thinking", "thinking": "", "signature": "",
            ]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "thinking_delta", "thinking": "weighing "]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "thinking_delta", "thinking": "options..."]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
            ("content_block_start", ["type": "content_block_start", "index": 1,
                                      "content_block": ["type": "text", "text": ""]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 1,
                                      "delta": ["type": "text_delta", "text": "Adding "]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 1,
                                      "delta": ["type": "text_delta", "text": "the track."]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 1]),
        ]
        events += toolUseSSEEvents(index: 2, id: "call_1", name: "track_add", partialJSONChunks: [#"{"name":"Drums"}"#])
        events.append(("message_delta", ["type": "message_delta", "delta": ["stop_reason": "tool_use"]]))
        events.append(("message_stop", ["type": "message_stop"]))
        server.setResponse(sseResponse(events), forKey: "POST /v1/messages")

        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let recorder = StreamEventRecorder()
        _ = try await provider.complete(turnRequest(), onEvent: { event in
            await recorder.record(event)
        })

        let recorded = await recorder.events
        #expect(recorded.count == 4)   // 2 thinkingDelta + 2 textDelta — none for the tool_use block.
        guard case .thinkingDelta(let index0, let text0) = recorded[0] else {
            Issue.record("expected thinkingDelta at 0, got \(recorded[0])"); return
        }
        #expect(index0 == 0); #expect(text0 == "weighing ")
        guard case .thinkingDelta(let index1, let text1) = recorded[1] else {
            Issue.record("expected thinkingDelta at 1, got \(recorded[1])"); return
        }
        #expect(index1 == 0); #expect(text1 == "options...")
        guard case .textDelta(let index2, let text2) = recorded[2] else {
            Issue.record("expected textDelta at 2, got \(recorded[2])"); return
        }
        #expect(index2 == 1); #expect(text2 == "Adding ")
        guard case .textDelta(let index3, let text3) = recorded[3] else {
            Issue.record("expected textDelta at 3, got \(recorded[3])"); return
        }
        #expect(index3 == 1); #expect(text3 == "the track.")
    }

    @Test("an 'error' SSE event mid-stream throws with the envelope's own type/message, same shape as a non-streaming error envelope")
    func sseErrorEventMidStreamThrows() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        let events: [(event: String, data: [String: Any])] = [
            ("message_start", ["type": "message_start"]),
            ("content_block_start", ["type": "content_block_start", "index": 0,
                                      "content_block": ["type": "text", "text": ""]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "text_delta", "text": "part"]]),
            ("error", ["type": "error", "error": ["type": "overloaded_error", "message": "Overloaded"]]),
        ]
        server.setResponse(sseResponse(events), forKey: "POST /v1/messages")

        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        do {
            _ = try await provider.complete(turnRequest())
            Issue.record("expected complete to throw")
        } catch let error as AIServiceError {
            let message = try #require(error.errorDescription)
            #expect(message.contains("overloaded_error"))
            #expect(message.contains("Overloaded"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: - Live streaming (M10-p-6-c: liveness fix)
    //
    // A live-staging gate found that `complete()` collected the WHOLE SSE
    // response into a `[String]` array BEFORE ever calling `assembleSSE`, so
    // every `onEvent` delta fired in one burst after the network read
    // finished — a real turn producing a 2040-char streamed answer, polled
    // via `ai.copilotState` every 100ms for the whole turn, showed ZERO
    // `partial: true` entries. The fix: `complete()` no longer buffers (it
    // hands `byteStream.lines` to `assembleSSE` directly), and `assembleSSE`
    // is now generic over any `AsyncSequence & Sendable` of `String` lines
    // rather than pinned to `[String]`, so a test can drive it from a
    // hand-controlled `AsyncStream` and prove delivery is actually live —
    // not just that the FINAL assembled result is correct (the existing
    // suite above already proved that; it could not have caught this class
    // of defect, since a stub server always resolves at the SAME `await` a
    // real one does regardless of whether the events fired live or in a
    // burst just before it).

    @Test("assembleSSE processes a canned line array wrapped as an AsyncStream (the direct-call/non-network path) to the correct assembled dict, firing onEvent for each delta in order")
    func assembleSSEDirectCallOverAsyncStream() async throws {
        let events: [(event: String, data: [String: Any])] = [
            ("message_start", ["type": "message_start"]),
            ("content_block_start", ["type": "content_block_start", "index": 0,
                                      "content_block": ["type": "text", "text": ""]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "text_delta", "text": "Hello "]]),
            ("content_block_delta", ["type": "content_block_delta", "index": 0,
                                      "delta": ["type": "text_delta", "text": "there."]]),
            ("content_block_stop", ["type": "content_block_stop", "index": 0]),
            ("message_delta", ["type": "message_delta", "delta": ["stop_reason": "end_turn"]]),
            ("message_stop", ["type": "message_stop"]),
        ]
        let recorder = StreamEventRecorder()
        let assembled = try await AnthropicCopilotProvider.assembleSSE(
            linesStream(rawSSELines(events)), onEvent: { event in await recorder.record(event) })

        let data = try JSONSerialization.data(withJSONObject: assembled)
        let reply = try AnthropicCopilotProvider.parseReply(data, status: 200)
        #expect(reply.blocks == [.text("Hello there.")])
        #expect(reply.stopReason == .endTurn)

        let recorded = await recorder.events
        #expect(recorded.count == 2)
        guard case .textDelta(let index0, let text0) = recorded[0] else {
            Issue.record("expected textDelta at 0, got \(recorded[0])"); return
        }
        #expect(index0 == 0); #expect(text0 == "Hello ")
        guard case .textDelta(let index1, let text1) = recorded[1] else {
            Issue.record("expected textDelta at 1, got \(recorded[1])"); return
        }
        #expect(index1 == 0); #expect(text1 == "there.")
    }

    @Test("onEvent fires DURING consumption, not after the stream completes — a hand-driven AsyncStream confirms the delta's onEvent has ALREADY fired before the remaining lines are even yielded")
    func onEventFiresLiveNotAfterStreamCompletes() async throws {
        let (lineStream, lineContinuation) = AsyncStream<String>.makeStream()
        let (signalStream, signalContinuation) = AsyncStream<Void>.makeStream()

        // `assembleSSE` returns `[String: Any]`, which isn't `Sendable`, so a
        // `Task` can't hand it back directly — re-serialize to `Data` (which
        // IS `Sendable`) inside the task and parse outside it instead.
        let assembleTask = Task<Data, Error> {
            let assembled = try await AnthropicCopilotProvider.assembleSSE(lineStream, onEvent: { event in
                if case .textDelta = event {
                    signalContinuation.yield(())
                }
            })
            return try JSONSerialization.data(withJSONObject: assembled)
        }

        // Everything needed to produce and FLUSH one text_delta: per
        // assembleSSE's own event-boundary rule (its doc comment), a flush
        // is triggered by the NEXT "event:" line — so the
        // "event: content_block_stop" line below is what actually fires
        // onEvent for the content_block_delta queued just above it.
        lineContinuation.yield("event: message_start")
        lineContinuation.yield(#"data: {"type":"message_start"}"#)
        lineContinuation.yield("event: content_block_start")
        lineContinuation.yield(
            #"data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#)
        lineContinuation.yield("event: content_block_delta")
        lineContinuation.yield(
            #"data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hello"}}"#)
        lineContinuation.yield("event: content_block_stop")   // flushes the delta above -> onEvent fires HERE

        // Prove liveness: race the signal against a short timeout rather
        // than the stream's own completion — this can only pass if
        // `onEvent` fires DURING consumption, since nothing below has been
        // sent yet and the stream is still wide open.
        let firedLive = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                var iterator = signalStream.makeAsyncIterator()
                await iterator.next()
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let result = await group.next() ?? false
            group.cancelAll()
            return result
        }
        #expect(firedLive, "onEvent for the text_delta never fired before the 2s timeout — streaming is buffered, not live")

        // ONLY NOW send the rest of the stream and finish it — if onEvent
        // had instead waited for this, the assertion above would already
        // have failed via the timeout race.
        lineContinuation.yield(#"data: {"type":"content_block_stop","index":0}"#)
        lineContinuation.yield("event: message_delta")
        lineContinuation.yield(#"data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#)
        lineContinuation.yield("event: message_stop")
        lineContinuation.yield(#"data: {"type":"message_stop"}"#)
        lineContinuation.finish()

        let data = try await assembleTask.value
        let reply = try AnthropicCopilotProvider.parseReply(data, status: 200)
        #expect(reply.blocks == [.text("Hello")])
        #expect(reply.stopReason == .endTurn)
    }
}

// MARK: - AnthropicModelCatalog — per-model max-output-token + thinking-config lookup (M10-p-6)

@Suite("AnthropicModelCatalog — no-artificial-limit + thinking-config lookup")
struct AnthropicModelCatalogTests {
    @Test("known 128K-ceiling models resolve by prefix, including a date-suffixed id")
    func knownModelsResolveTo128K() {
        for model in [
            "claude-sonnet-5", "claude-sonnet-5-20260115",
            "claude-sonnet-4-6", "claude-opus-4-6", "claude-opus-4-7", "claude-opus-4-8",
            "claude-fable-5", "claude-mythos-5",
        ] {
            #expect(AnthropicModelCatalog.maxOutputTokens(forModel: model) == 128_000, "\(model)")
        }
    }

    @Test("claude-haiku-4-5 resolves to 64K, including a date-suffixed id")
    func haikuResolvesTo64K() {
        #expect(AnthropicModelCatalog.maxOutputTokens(forModel: "claude-haiku-4-5") == 64_000)
        #expect(AnthropicModelCatalog.maxOutputTokens(forModel: "claude-haiku-4-5-20260201") == 64_000)
    }

    @Test("an unknown/future model id falls back to the conservative 64K ceiling")
    func unknownModelFallsBackTo64K() {
        #expect(AnthropicModelCatalog.maxOutputTokens(forModel: "claude-nonexistent-9") == 64_000)
        #expect(AnthropicModelCatalog.maxOutputTokens(forModel: "") == 64_000)
    }

    @Test("sonnet-5/opus-4-7/opus-4-8/fable-5/mythos-5 request adaptive thinking with display:summarized")
    func summarizedDisplayModels() {
        for model in ["claude-sonnet-5", "claude-opus-4-7", "claude-opus-4-8", "claude-fable-5", "claude-mythos-5"] {
            #expect(AnthropicModelCatalog.thinkingConfig(forModel: model) == .adaptiveSummarized, "\(model)")
        }
    }

    @Test("sonnet-4-6/opus-4-6 (pre-\"display\" field) request bare adaptive thinking, no display key")
    func bareAdaptiveModels() {
        for model in ["claude-sonnet-4-6", "claude-opus-4-6"] {
            #expect(AnthropicModelCatalog.thinkingConfig(forModel: model) == .adaptive, "\(model)")
        }
    }

    @Test("haiku-4-5 and an unrecognized id omit the thinking key entirely")
    func omittedThinkingModels() {
        #expect(AnthropicModelCatalog.thinkingConfig(forModel: "claude-haiku-4-5") == .omit)
        #expect(AnthropicModelCatalog.thinkingConfig(forModel: "claude-nonexistent-9") == .omit)
    }

    @Test("curated is a strict, name-bearing subset of all — the 6 picker-offered models, with the default among them")
    func curatedIsSubsetOfAll() {
        let curatedIDs = Set(AnthropicModelCatalog.curated.map(\.id))
        let allIDs = Set(AnthropicModelCatalog.all.map(\.id))
        #expect(curatedIDs.isSubset(of: allIDs))
        #expect(AnthropicModelCatalog.curated.allSatisfy { $0.name != nil })
        #expect(curatedIDs.count == 6)
        #expect(curatedIDs.contains(AnthropicModelCatalog.defaultModelID))
        // Lookup-only rows are deliberately excluded from the picker.
        #expect(!curatedIDs.contains("claude-opus-4-6"))
        #expect(!curatedIDs.contains("claude-mythos-5"))
    }
}

// MARK: - OpenAI translation

@Suite("OpenAICopilotProvider — tool_calls translation + reply parsing against a stub")
struct OpenAICopilotProviderTests {
    @Test("toolUse → tool_calls (args JSON round-trips), toolResult → role:\"tool\", Bearer auth, function-tool shape")
    func requestShape() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.openAIResponse("ok"), forKey: "POST /v1/chat/completions")

        let provider = OpenAICopilotProvider(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        _ = try await provider.complete(turnRequest(maxTokens: 512))

        let headers = server.lastHeaders(forKey: "POST /v1/chat/completions")
        #expect(headers["authorization"] == "Bearer sk-openai-STUBKEY")

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/chat/completions"))
        #expect(body["model"] as? String == "gpt-4o")
        #expect(body["max_tokens"] as? Int == 512)

        let tools = try #require(body["tools"] as? [[String: Any]])
        #expect(tools[0]["type"] as? String == "function")
        let function = try #require(tools[0]["function"] as? [String: Any])
        #expect(function["name"] as? String == "track_add")
        #expect(function["description"] as? String == "Adds a new track to the project.")
        let parameters = try #require(function["parameters"] as? [String: Any])
        #expect(parameters["type"] as? String == "object")

        let messages = try #require(body["messages"] as? [[String: Any]])
        // system, user text, assistant tool_calls, tool result — 4 wire messages.
        #expect(messages.count == 4)
        #expect(messages[0]["role"] as? String == "system")
        #expect(messages[1]["role"] as? String == "user")
        #expect(messages[1]["content"] as? String == "add a drum track")

        #expect(messages[2]["role"] as? String == "assistant")
        let toolCalls = try #require(messages[2]["tool_calls"] as? [[String: Any]])
        #expect(toolCalls[0]["id"] as? String == "call_1")
        #expect(toolCalls[0]["type"] as? String == "function")
        let toolCallFunction = try #require(toolCalls[0]["function"] as? [String: Any])
        #expect(toolCallFunction["name"] as? String == "track_add")
        let argumentsString = try #require(toolCallFunction["arguments"] as? String)
        let argumentsData = try #require(argumentsString.data(using: .utf8))
        #expect(try jsonObjectsEqual(argumentsData, Data(#"{"name":"Drums"}"#.utf8)))

        #expect(messages[3]["role"] as? String == "tool")
        #expect(messages[3]["tool_call_id"] as? String == "call_1")
        #expect(messages[3]["content"] as? String == #"{"trackId":"abc12345"}"#)
    }

    @Test("nil maxTokens OMITS the max_tokens field entirely (OpenAI already treats absence as \"use the model maximum\"); non-nil still sends it")
    func nilMaxTokensOmitsField() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.openAIResponse("ok"), forKey: "POST /v1/chat/completions")
        let provider = OpenAICopilotProvider(config: server.config(openAIKey: "sk-openai-STUBKEY"))

        _ = try await provider.complete(turnRequest(maxTokens: nil))
        let nilBody = try bodyJSON(server.lastBody(forKey: "POST /v1/chat/completions"))
        #expect(nilBody["max_tokens"] == nil)

        _ = try await provider.complete(turnRequest(maxTokens: 512))
        let explicitBody = try bodyJSON(server.lastBody(forKey: "POST /v1/chat/completions"))
        #expect(explicitBody["max_tokens"] as? Int == 512)
    }

    @Test("a tool_calls reply parses id/name/arguments back into .toolUse blocks and stop_reason tool_use")
    func parsesToolCallsReply() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[
                    {"id":"call_1","type":"function","function":{"name":"track_add","arguments":"{\"name\":\"Drums\"}"}}
                ]},"finish_reason":"tool_calls"}]}
                """#),
            forKey: "POST /v1/chat/completions")
        let provider = OpenAICopilotProvider(config: server.config(openAIKey: "sk-openai-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks.count == 1)
        guard case .toolUse(let id, let name, let inputJSON) = reply.blocks[0] else {
            Issue.record("expected a .toolUse block, got \(reply.blocks[0])")
            return
        }
        #expect(id == "call_1")
        #expect(name == "track_add")
        #expect(try jsonObjectsEqual(inputJSON, Data(#"{"name":"Drums"}"#.utf8)))
        #expect(reply.stopReason == .toolUse)
        #expect(reply.provider == "openai")
    }

    @Test("an assistant message containing a .thinking block is skipped in wireMessages, never thrown")
    func thinkingBlockSkippedInWireMessages() throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"...","signature":"sig-1"}"#.utf8)
        let messages: [CopilotMessage] = [
            CopilotMessage(role: .user, blocks: [.text("add a drum track")]),
            CopilotMessage(
                role: .assistant,
                blocks: [
                    .thinking(summary: "...", rawJSON: thinkingJSON),
                    .toolUse(id: "call_1", name: "track_add", inputJSON: Data(#"{"name":"Drums"}"#.utf8)),
                ]),
            CopilotMessage(
                role: .user,
                blocks: [.toolResult(id: "call_1", content: #"{"trackId":"abc12345"}"#, isError: false)]),
        ]

        let wire = try OpenAICopilotProvider.wireMessages(system: "you are the copilot", messages: messages)

        // system, user text, assistant tool_calls (thinking skipped), tool result — 4 wire messages.
        #expect(wire.count == 4)
        let assistantMessage = wire[2]
        #expect(assistantMessage["role"] as? String == "assistant")
        let toolCalls = try #require(assistantMessage["tool_calls"] as? [[String: Any]])
        #expect(toolCalls.count == 1)
        #expect(toolCalls[0]["id"] as? String == "call_1")
    }

    @Test("a user message containing only a .thinking block is skipped, producing no wire user message")
    func thinkingOnlyUserMessageSkipped() throws {
        let thinkingJSON = Data(#"{"type":"thinking","thinking":"...","signature":"sig-2"}"#.utf8)
        let messages: [CopilotMessage] = [
            CopilotMessage(role: .user, blocks: [.thinking(summary: "...", rawJSON: thinkingJSON)]),
        ]

        let wire = try OpenAICopilotProvider.wireMessages(system: "you are the copilot", messages: messages)

        // Only the leading system message — the thinking-only user message contributes nothing.
        #expect(wire.count == 1)
        #expect(wire[0]["role"] as? String == "system")
    }

    @Test("finish_reason stop/tool_calls/length map onto the same StopReason enum as Anthropic")
    func finishReasonMap() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        let provider = OpenAICopilotProvider(config: server.config(openAIKey: "sk-openai-STUBKEY"))

        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"stop"}]}"#),
            forKey: "POST /v1/chat/completions")
        #expect(try await provider.complete(turnRequest()).stopReason == .endTurn)

        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"tool_calls"}]}"#),
            forKey: "POST /v1/chat/completions")
        #expect(try await provider.complete(turnRequest()).stopReason == .toolUse)

        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"{"choices":[{"message":{"role":"assistant","content":"hi"},"finish_reason":"length"}]}"#),
            forKey: "POST /v1/chat/completions")
        #expect(try await provider.complete(turnRequest()).stopReason == .maxTokens)
    }
}

// MARK: - resolveCopilotProvider chain

@Suite("resolveCopilotProvider — Anthropic first, OpenAI fallback, else actionable error")
struct ResolveCopilotProviderTests {
    @Test("Anthropic is preferred when both keys are present")
    func anthropicPreferred() throws {
        let store = InMemoryKeyStore([.anthropic: "sk-ant-A", .openai: "sk-openai-B"])
        let provider = try resolveCopilotProvider(environment: [:], store: store)
        #expect(provider is AnthropicCopilotProvider)
    }

    @Test("falls back to OpenAI when only OpenAI has a key")
    func openAIFallback() throws {
        let store = InMemoryKeyStore([.openai: "sk-openai-B"])
        let provider = try resolveCopilotProvider(environment: [:], store: store)
        #expect(provider is OpenAICopilotProvider)
    }

    @Test("no provider configured throws an actionable error naming Settings + ⌘, and leaking no key material")
    func neitherThrowsActionable() {
        let store = InMemoryKeyStore()
        do {
            _ = try resolveCopilotProvider(environment: ["ANTHROPIC_API_KEY": ""], store: store)
            Issue.record("expected resolveCopilotProvider to throw")
        } catch let error as AIServiceError {
            guard case .noProviderConfigured(let capability) = error else {
                Issue.record("expected .noProviderConfigured, got \(error)")
                return
            }
            #expect(capability == "copilot")
            let message = try! #require(error.errorDescription)
            #expect(message.contains("Settings"))
            #expect(message.contains("⌘,"))
            #expect(!message.contains("sk-"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }
}

// MARK: - Copilot-turn HTTP timeout (staging follow-up: "The request timed out.")

/// A live-staging round trip surfaced that `maxTokens: 16000` + Sonnet 5's
/// adaptive thinking can legitimately run past `URLRequest`'s default 60s
/// `timeoutInterval`, which `HTTP.postJSON` didn't let callers override. No
/// network call here — `HTTP.makeRequest` builds the `URLRequest` the same
/// way `postJSON` does but without sending it, so the `timeoutSeconds` wiring
/// (and therefore the exact call both copilot providers make) is pinned
/// directly.
@Suite("Copilot-turn HTTP timeout")
struct CopilotTurnTimeoutTests {
    @Test("turnTimeoutSeconds is generous enough to survive a real thinking-heavy generation, not 60s territory")
    func turnTimeoutSecondsIsGenerous() {
        #expect(CopilotTurnRequest.turnTimeoutSeconds >= 300)
    }

    @Test("HTTP.makeRequest with timeoutSeconds: nil leaves URLRequest's own 60s default untouched")
    func makeRequestNilTimeoutPreservesDefault() throws {
        let request = try HTTP.makeRequest(
            to: URL(string: "http://127.0.0.1:1")!, headers: [:], body: [:], timeoutSeconds: nil)
        #expect(request.timeoutInterval == 60)
    }

    @Test("HTTP.makeRequest with the copilot turn timeout sets timeoutInterval to exactly that value — the same call both providers make")
    func makeRequestCopilotTimeoutIsThreadedThrough() throws {
        let request = try HTTP.makeRequest(
            to: URL(string: "http://127.0.0.1:1")!,
            headers: [:],
            body: [:],
            timeoutSeconds: CopilotTurnRequest.turnTimeoutSeconds)
        #expect(request.timeoutInterval == CopilotTurnRequest.turnTimeoutSeconds)
    }
}
