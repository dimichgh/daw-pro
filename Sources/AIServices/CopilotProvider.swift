import Foundation

/// The in-app copilot's provider seam (M6 rail-b). `CopilotEngine` (DAWControl)
/// drives a tool-calling conversation against whichever provider is resolved
/// here; AIServices cannot see DAWControl's `JSONValue`, so every schema/tool-
/// input value crossing this seam is pre-encoded JSON `Data` — Sendable, no new
/// JSON type, no duplication. See docs/research/design-rail-a-copilot.md §2/§5.

// MARK: - Wire-agnostic types (§2)

/// One tool the model may call. `name` is the WIRE name (dots already mapped to
/// underscores by the catalog — see design §3); `inputSchemaJSON` is a JSON
/// Schema object, pre-encoded by the catalog so this module never touches
/// `JSONValue`.
public struct CopilotToolSpec: Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchemaJSON: Data

    public init(name: String, description: String, inputSchemaJSON: Data) {
        self.name = name
        self.description = description
        self.inputSchemaJSON = inputSchemaJSON
    }
}

/// One block of a `CopilotMessage`'s content, provider-agnostic. `toolUse` is
/// model-initiated ("call this tool with this input"); `toolResult` is the
/// engine's response, always carried in a `.user`-role message (Anthropic
/// requires tool results to ride in the immediately-next user turn).
public enum CopilotContentBlock: Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, inputJSON: Data)
    case toolResult(id: String, content: String, isError: Bool)
}

/// One turn of conversation history. `blocks` preserves order — a `toolUse`/
/// `toolResult` pair must stay matched by `id` across adjacent messages or the
/// Anthropic API 400s.
public struct CopilotMessage: Sendable, Equatable {
    public enum Role: String, Sendable, Equatable { case user, assistant }
    public var role: Role
    public var blocks: [CopilotContentBlock]

    public init(role: Role, blocks: [CopilotContentBlock]) {
        self.role = role
        self.blocks = blocks
    }
}

/// One provider round: the (context-carrying) system prompt, trimmed history
/// with tool pairs intact, the tool catalog, and a token cap.
public struct CopilotTurnRequest: Sendable {
    public var system: String
    public var messages: [CopilotMessage]
    public var tools: [CopilotToolSpec]
    public var maxTokens: Int

    public init(
        system: String,
        messages: [CopilotMessage],
        tools: [CopilotToolSpec],
        maxTokens: Int = 4096
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }
}

/// A provider's reply to one turn round: the emitted blocks (text and/or
/// `toolUse`), why it stopped, and which vendor produced it.
public struct CopilotReply: Sendable, Equatable {
    /// Normalized across vendors: Anthropic's `stop_reason` and OpenAI's
    /// `finish_reason` both map onto this. `.other` preserves the raw wire
    /// value for anything neither maps to a known case (diagnostic only).
    public enum StopReason: Sendable, Equatable {
        case endTurn
        case toolUse
        case maxTokens
        case other(String)
    }

    public var blocks: [CopilotContentBlock]
    public var stopReason: StopReason
    public var provider: String

    public init(blocks: [CopilotContentBlock], stopReason: StopReason, provider: String) {
        self.blocks = blocks
        self.stopReason = stopReason
        self.provider = provider
    }
}

/// A vendor-agnostic tool-calling text provider for the copilot. Non-streaming
/// v1 — one request, one reply, per round (design D5).
public protocol CopilotProviding: Sendable {
    func complete(_ request: CopilotTurnRequest) async throws -> CopilotReply
}

// MARK: - Provider resolution

/// Resolves a configured copilot provider: `AnthropicCopilotProvider`
/// (preferred) or `OpenAICopilotProvider`, keyed from the shared env/Keychain
/// resolution chain, with `baseConfig`'s model IDs/base URLs preserved (so a
/// stub-server suite can retarget it) — the exact chain shape as
/// `resolveLyricsWriter` (Providers.swift), mirrored here for the "copilot"
/// capability. Throws the actionable, key-value-free
/// `AIServiceError.noProviderConfigured` when neither provider has a key.
public func resolveCopilotProvider(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: APIKeyStoring?,
    config baseConfig: AIConfig = AIConfig()
) throws -> any CopilotProviding {
    if let anthropicKey = resolveKey(provider: .anthropic, environment: environment, store: store).value {
        var config = baseConfig
        config.anthropicKey = anthropicKey
        return AnthropicCopilotProvider(config: config)
    }
    if let openAIKey = resolveKey(provider: .openai, environment: environment, store: store).value {
        var config = baseConfig
        config.openAIKey = openAIKey
        return OpenAICopilotProvider(config: config)
    }
    throw AIServiceError.noProviderConfigured(capability: "copilot")
}

// MARK: - Anthropic

/// Anthropic Messages API tool-calling client for the copilot. Raw URLSession,
/// keys in headers only, bodies never logged — same plumbing style as
/// `AnthropicClient`.
public struct AnthropicCopilotProvider: CopilotProviding {
    let config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    public func complete(_ request: CopilotTurnRequest) async throws -> CopilotReply {
        guard let key = config.anthropicKey else {
            throw AIServiceError.notConfigured("ANTHROPIC_API_KEY")
        }
        let body: [String: Any] = [
            "model": config.anthropicModel,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": try Self.wireMessages(request.messages),
            "tools": try Self.wireTools(request.tools),
        ]
        let (data, status) = try await HTTP.postJSON(
            to: config.anthropicBaseURL.appendingPathComponent("v1/messages"),
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
            ],
            body: body
        )
        return try Self.parseReply(data, status: status)
    }

    /// `{name, description, input_schema}` per catalog entry.
    static func wireTools(_ tools: [CopilotToolSpec]) throws -> [[String: Any]] {
        try tools.map { tool in
            [
                "name": tool.name,
                "description": tool.description,
                "input_schema": try decodedJSONObject(tool.inputSchemaJSON),
            ]
        }
    }

    /// `{role, content:[...]}` — content blocks: `text` / `tool_use` (id, name,
    /// input) / `tool_result` (tool_use_id, content, is_error).
    static func wireMessages(_ messages: [CopilotMessage]) throws -> [[String: Any]] {
        try messages.map { message in
            [
                "role": message.role.rawValue,
                "content": try wireContent(message.blocks),
            ]
        }
    }

    static func wireContent(_ blocks: [CopilotContentBlock]) throws -> [[String: Any]] {
        try blocks.map { block in
            switch block {
            case .text(let text):
                return ["type": "text", "text": text]
            case .toolUse(let id, let name, let inputJSON):
                return [
                    "type": "tool_use",
                    "id": id,
                    "name": name,
                    "input": try decodedJSONObject(inputJSON),
                ]
            case .toolResult(let id, let content, let isError):
                return [
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": content,
                    "is_error": isError,
                ]
            }
        }
    }

    /// Parses `{content:[...], stop_reason}` into a `CopilotReply`. Any
    /// unparsable body (invalid JSON, non-object top level, or a
    /// missing/malformed `content` array) throws the actionable
    /// `AIServiceError.malformedResponse` — never a raw Foundation error.
    /// `status` is the response's HTTP status (always 2xx when this is
    /// reached from `complete` — `postJSON` throws on non-2xx before this
    /// runs); it only carries forward into the defensive error-envelope
    /// check below.
    static func parseReply(_ data: Data, status: Int) throws -> CopilotReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.malformedResponse("top-level response is not a JSON object")
        }

        // Defensive: surface the API's own error type/message rather than
        // falling through to the "missing 'content' array" guard below — an
        // error envelope that somehow arrives on a 2xx status (`postJSON`
        // already handles the ordinary non-2xx case with identical
        // formatting; see `AnthropicClient.complete` for the same pattern).
        if let message = HTTP.errorEnvelopeMessage(object) {
            throw AIServiceError.requestFailed(status: status, body: message)
        }

        guard let contentArray = object["content"] as? [[String: Any]] else {
            throw AIServiceError.malformedResponse("missing 'content' array in Anthropic response")
        }
        var blocks: [CopilotContentBlock] = []
        for item in contentArray {
            guard let type = item["type"] as? String else {
                throw AIServiceError.malformedResponse("content block missing 'type'")
            }
            switch type {
            case "text":
                guard let text = item["text"] as? String else {
                    throw AIServiceError.malformedResponse("text block missing 'text'")
                }
                blocks.append(.text(text))
            case "tool_use":
                guard let id = item["id"] as? String, let name = item["name"] as? String else {
                    throw AIServiceError.malformedResponse("tool_use block missing 'id'/'name'")
                }
                let input = item["input"] ?? [String: Any]()
                let inputData = try JSONSerialization.data(withJSONObject: input)
                blocks.append(.toolUse(id: id, name: name, inputJSON: inputData))
            case "thinking", "redacted_thinking":
                // Extended-thinking blocks can precede text/tool_use blocks
                // in a conversation turn — tolerated (skipped), never thrown.
                continue
            default:
                // Forward-compatible: ignore block kinds this client doesn't know yet.
                continue
            }
        }
        let stopReason = mapStopReason(object["stop_reason"] as? String)
        return CopilotReply(blocks: blocks, stopReason: stopReason, provider: AIProviderID.anthropic.rawValue)
    }

    static func mapStopReason(_ raw: String?) -> CopilotReply.StopReason {
        switch raw {
        case "end_turn": return .endTurn
        case "tool_use": return .toolUse
        case "max_tokens": return .maxTokens
        case let other?: return .other(other)
        case nil: return .other("unknown")
        }
    }
}

// MARK: - OpenAI

/// OpenAI chat-completions tool-calling client for the copilot — the fallback
/// when no Anthropic key is configured. Translates the shared block model onto
/// OpenAI's `tool_calls`/`role: "tool"` shape.
public struct OpenAICopilotProvider: CopilotProviding {
    let config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    public func complete(_ request: CopilotTurnRequest) async throws -> CopilotReply {
        guard let key = config.openAIKey else {
            throw AIServiceError.notConfigured("OPENAI_API_KEY")
        }
        let body: [String: Any] = [
            "model": config.openAITextModel,
            "max_tokens": request.maxTokens,
            "messages": try Self.wireMessages(system: request.system, messages: request.messages),
            "tools": try Self.wireTools(request.tools),
        ]
        let (data, status) = try await HTTP.postJSON(
            to: config.openAIBaseURL.appendingPathComponent("v1/chat/completions"),
            headers: ["Authorization": "Bearer \(key)"],
            body: body
        )
        return try Self.parseReply(data, status: status)
    }

    /// `{type:"function", function:{name, description, parameters}}` per catalog entry.
    static func wireTools(_ tools: [CopilotToolSpec]) throws -> [[String: Any]] {
        try tools.map { tool in
            [
                "type": "function",
                "function": [
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": try decodedJSONObject(tool.inputSchemaJSON),
                ],
            ]
        }
    }

    /// A leading `role:"system"` message, then one entry per `CopilotMessage`:
    /// `.assistant` text/toolUse blocks become one `role:"assistant"` message
    /// (text → `content`, toolUse → `tool_calls`); `.user` toolResult blocks
    /// each become their OWN `role:"tool"` message (OpenAI requires one tool
    /// message per call), while any plain text in a `.user` message becomes an
    /// ordinary `role:"user"` message.
    static func wireMessages(system: String, messages: [CopilotMessage]) throws -> [[String: Any]] {
        var wire: [[String: Any]] = [["role": "system", "content": system]]
        for message in messages {
            switch message.role {
            case .user:
                var textParts: [String] = []
                for block in message.blocks {
                    switch block {
                    case .text(let text):
                        textParts.append(text)
                    case .toolResult(let id, let content, _):
                        wire.append(["role": "tool", "tool_call_id": id, "content": content])
                    case .toolUse:
                        throw AIServiceError.malformedResponse(
                            "unexpected tool_use block in a user-role CopilotMessage")
                    }
                }
                if !textParts.isEmpty {
                    wire.append(["role": "user", "content": textParts.joined(separator: "\n")])
                }
            case .assistant:
                var textParts: [String] = []
                var toolCalls: [[String: Any]] = []
                for block in message.blocks {
                    switch block {
                    case .text(let text):
                        textParts.append(text)
                    case .toolUse(let id, let name, let inputJSON):
                        let arguments = String(data: inputJSON, encoding: .utf8) ?? "{}"
                        toolCalls.append([
                            "id": id,
                            "type": "function",
                            "function": ["name": name, "arguments": arguments],
                        ])
                    case .toolResult:
                        throw AIServiceError.malformedResponse(
                            "unexpected tool_result block in an assistant-role CopilotMessage")
                    }
                }
                var entry: [String: Any] = ["role": "assistant"]
                entry["content"] = textParts.isEmpty ? NSNull() : textParts.joined(separator: "\n")
                if !toolCalls.isEmpty {
                    entry["tool_calls"] = toolCalls
                }
                wire.append(entry)
            }
        }
        return wire
    }

    /// Parses `{choices:[{message:{content, tool_calls}, finish_reason}]}` into
    /// a `CopilotReply`. Any unparsable body throws the actionable
    /// `AIServiceError.malformedResponse` — never a raw Foundation error.
    /// `status` is the response's HTTP status; see the Anthropic
    /// `parseReply`'s doc comment for why it's threaded through.
    static func parseReply(_ data: Data, status: Int) throws -> CopilotReply {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AIServiceError.malformedResponse("top-level response is not a JSON object")
        }

        // Defensive: surface the API's own error message rather than falling
        // through to the "missing 'choices[0]'" guard below — see the
        // Anthropic `parseReply` above for the identical pattern.
        if let message = HTTP.errorEnvelopeMessage(object) {
            throw AIServiceError.requestFailed(status: status, body: message)
        }

        guard let choices = object["choices"] as? [[String: Any]], let first = choices.first else {
            throw AIServiceError.malformedResponse("missing 'choices[0]' in OpenAI response")
        }
        guard let message = first["message"] as? [String: Any] else {
            throw AIServiceError.malformedResponse("missing 'choices[0].message' in OpenAI response")
        }
        var blocks: [CopilotContentBlock] = []
        if let content = message["content"] as? String, !content.isEmpty {
            blocks.append(.text(content))
        }
        if let toolCalls = message["tool_calls"] as? [[String: Any]] {
            for call in toolCalls {
                guard let id = call["id"] as? String,
                      let function = call["function"] as? [String: Any],
                      let name = function["name"] as? String
                else {
                    throw AIServiceError.malformedResponse("tool_calls entry missing 'id'/'function.name'")
                }
                let argumentsString = function["arguments"] as? String ?? "{}"
                guard let argumentsData = argumentsString.data(using: .utf8),
                      (try? JSONSerialization.jsonObject(with: argumentsData)) != nil
                else {
                    throw AIServiceError.malformedResponse("tool_calls entry has non-JSON 'function.arguments'")
                }
                blocks.append(.toolUse(id: id, name: name, inputJSON: argumentsData))
            }
        }
        let stopReason = mapStopReason(first["finish_reason"] as? String)
        return CopilotReply(blocks: blocks, stopReason: stopReason, provider: AIProviderID.openai.rawValue)
    }

    static func mapStopReason(_ raw: String?) -> CopilotReply.StopReason {
        switch raw {
        case "stop": return .endTurn
        case "tool_calls": return .toolUse
        case "length": return .maxTokens
        case let other?: return .other(other)
        case nil: return .other("unknown")
        }
    }
}

// MARK: - Shared encode helper

/// Decodes a pre-encoded JSON-object `Data` (a `CopilotToolSpec.inputSchemaJSON`
/// or a `CopilotContentBlock.toolUse`/`.toolResult` payload) back into a
/// `JSONSerialization`-compatible `Any` for embedding into an outgoing request
/// body. The `Data` always originates from valid JSON (the catalog's own
/// encoding or a prior parsed reply), so a throw here indicates a caller bug,
/// not a network/provider failure.
private func decodedJSONObject(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
}
