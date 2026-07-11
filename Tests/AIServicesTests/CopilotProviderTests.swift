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

private func turnRequest(maxTokens: Int = 4096) -> CopilotTurnRequest {
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

// MARK: - Anthropic wire shape

@Suite("AnthropicCopilotProvider — request shape + reply parsing against a stub")
struct AnthropicCopilotProviderTests {
    @Test("pins model/max_tokens/system/tools[].{name,description,input_schema}, message roles, and matched tool_use/tool_result ids; headers carry x-api-key + anthropic-version")
    func requestShape() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(StubTextAPIServer.anthropicResponse("ok"), forKey: "POST /v1/messages")

        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        _ = try await provider.complete(turnRequest(maxTokens: 777))

        #expect(server.callCount(forKey: "POST /v1/messages") == 1)
        let headers = server.lastHeaders(forKey: "POST /v1/messages")
        #expect(headers["x-api-key"] == "sk-ant-STUBKEY")
        #expect(headers["anthropic-version"] == "2023-06-01")

        let body = try bodyJSON(server.lastBody(forKey: "POST /v1/messages"))
        #expect(body["model"] as? String == "claude-sonnet-5")
        #expect(body["max_tokens"] as? Int == 777)
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
            StubTextAPIServer.jsonResponse(#"{"content":[{"type":"text","text":"Done!"}],"stop_reason":"end_turn"}"#),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks == [.text("Done!")])
        #expect(reply.stopReason == .endTurn)
        #expect(reply.provider == "anthropic")
    }

    @Test("a single tool_use reply parses id/name/input and stop_reason tool_use")
    func parsesSingleToolUse() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"{"content":[{"type":"tool_use","id":"call_9","name":"transport_play","input":{"fromBeat":0}}],"stop_reason":"tool_use"}"#),
            forKey: "POST /v1/messages")
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
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"content":[
                    {"type":"text","text":"On it."},
                    {"type":"tool_use","id":"call_1","name":"track_add","input":{"name":"Drums"}},
                    {"type":"tool_use","id":"call_2","name":"track_add","input":{"name":"Bass"}}
                ],"stop_reason":"tool_use"}
                """#),
            forKey: "POST /v1/messages")
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
            StubTextAPIServer.jsonResponse(#"{"content":[{"type":"text","text":"partial"}],"stop_reason":"max_tokens"}"#),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())
        #expect(reply.stopReason == .maxTokens)
    }

    @Test("a thinking block preceding text+tool_use is skipped; the conversation still parses")
    func thinkingBlockPrecedingTextAndToolUse() async throws {
        let server = StubTextAPIServer(); try server.start(); defer { server.stop() }
        server.setResponse(
            StubTextAPIServer.jsonResponse(
                #"""
                {"content":[
                    {"type":"thinking","thinking":"deciding which tool to call..."},
                    {"type":"text","text":"On it."},
                    {"type":"tool_use","id":"call_1","name":"track_add","input":{"name":"Drums"}}
                ],"stop_reason":"tool_use"}
                """#),
            forKey: "POST /v1/messages")
        let provider = AnthropicCopilotProvider(config: server.config(anthropicKey: "sk-ant-STUBKEY"))
        let reply = try await provider.complete(turnRequest())

        #expect(reply.blocks.count == 2)
        #expect(reply.blocks[0] == .text("On it."))
        guard case .toolUse(let id, let name, let input) = reply.blocks[1] else {
            Issue.record("expected .toolUse at index 1, got \(reply.blocks[1])")
            return
        }
        #expect(id == "call_1")
        #expect(name == "track_add")
        #expect(try jsonObjectsEqual(input, Data(#"{"name":"Drums"}"#.utf8)))
        #expect(reply.stopReason == .toolUse)
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
