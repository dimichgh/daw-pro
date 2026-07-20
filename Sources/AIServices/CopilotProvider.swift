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
    /// An Anthropic extended-thinking (or redacted_thinking) block (renamed
    /// from `.opaque` in M10-p-6, when thinking summaries became
    /// user-visible). `summary` is the block's user-VISIBLE thinking text —
    /// `""` for a `redacted_thinking` block (its real content is `data`,
    /// never shown) or a `thinking` block whose `display` mode is "omitted"
    /// (Sonnet 5 / Opus 4.7 / 4.8 / Fable 5's DEFAULT — see
    /// `AnthropicModelCatalog`; the copilot requests `display: "summarized"`
    /// to get non-empty text). `rawJSON` is the block's COMPLETE wire object,
    /// carried VERBATIM (including `signature`) for `wireContent`'s history
    /// echo — Anthropic requires the exact block to ride back unmodified on
    /// the next round of the same conversation, regardless of `summary`.
    /// `CopilotEngine` surfaces non-empty summaries as `.thinking` transcript
    /// entries (§11.2: never counted as VISIBLE output, even so).
    case thinking(summary: String, rawJSON: Data)
}

/// One live delta the copilot may stream mid-turn, for a real-time partial
/// transcript (M10-p-6). No tool_use delta — partial JSON isn't
/// human-displayable, so tool calls only ever appear once complete (see
/// `CopilotEngine`'s block-walk, unchanged for `.toolUse`). The streamed
/// events are UI-only: the reply `assembleSSE`/`parseReply` produce remains
/// the single source of truth for history and tool execution.
public enum CopilotStreamEvent: Sendable {
    /// A chunk of a thinking block's visible summary text, at `blockIndex`
    /// (the position `content_block_start` assigned it — 0-based, per
    /// provider response). Never fires for `display: "omitted"` (its summary
    /// is always empty, so there's nothing to stream).
    case thinkingDelta(blockIndex: Int, text: String)
    /// A chunk of a text block's content, at `blockIndex`.
    case textDelta(blockIndex: Int, text: String)
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
/// with tool pairs intact, the tool catalog, and an optional token cap.
public struct CopilotTurnRequest: Sendable {
    public var system: String
    public var messages: [CopilotMessage]
    public var tools: [CopilotToolSpec]
    /// The requested output-token cap for this round. `nil` — the default —
    /// means NO ARTIFICIAL LIMIT: the provider requests its model's own
    /// maximum output tokens (`AnthropicCopilotProvider.maxOutputTokens`
    /// looks it up and streams the response, per Anthropic's "128K max
    /// output requires streaming for large outputs"; `OpenAICopilotProvider`
    /// omits the field entirely, which OpenAI already treats as "use the
    /// model's own maximum"). The field survives non-nil so a caller (a test,
    /// or a future deliberately-cheap round) can still pin an explicit
    /// smaller budget.
    public var maxTokens: Int?

    public init(
        system: String,
        messages: [CopilotMessage],
        tools: [CopilotToolSpec],
        maxTokens: Int? = nil
    ) {
        self.system = system
        self.messages = messages
        self.tools = tools
        self.maxTokens = maxTokens
    }

    /// The HTTP timeout both copilot providers use for a turn round, in place
    /// of `HTTP.postJSON`'s default 60s. `timeoutInterval` is an IDLE timer —
    /// it resets on every received byte/chunk, not a total-duration cap — so
    /// this bounds a genuinely hung connection without capping a long-running
    /// but live streamed generation (Anthropic) or a slower non-streaming
    /// OpenAI fallback call. Do not raise this to "cover" a slow response: if
    /// truncation (not latency) is the symptom, the fix is the per-model
    /// max-output lookup, not this constant.
    public static let turnTimeoutSeconds: TimeInterval = 600
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

/// A vendor-agnostic tool-calling text provider for the copilot: one request,
/// one reply, per round (design D5) — `AnthropicCopilotProvider` fulfils that
/// contract over SSE streaming internally (M10-p-6), `OpenAICopilotProvider`
/// non-streaming; callers see the same one-`await`-one-`CopilotReply` shape
/// either way.
public protocol CopilotProviding: Sendable {
    /// - Parameter onEvent: fired (awaited, in order — this provides
    ///   backpressure and guarantees delivery order) for each live delta a
    ///   streaming provider can surface, so a caller (`CopilotEngine`) can
    ///   maintain a real-time partial transcript. `nil` (the common case for
    ///   a direct/test call) means "don't bother" — never required for
    ///   correctness, since `complete`'s RETURNED `CopilotReply` is always
    ///   the authoritative, complete answer regardless of whether/how the
    ///   caller consumed the stream. `OpenAICopilotProvider` never invokes it
    ///   (it has nothing to stream).
    func complete(
        _ request: CopilotTurnRequest,
        onEvent: (@Sendable (CopilotStreamEvent) async -> Void)?
    ) async throws -> CopilotReply
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
/// `AnthropicClient`. Streams (`stream: true`) unconditionally: the copilot
/// never caps output artificially (`CopilotTurnRequest.maxTokens == nil` is
/// the normal case), and Anthropic's own docs say 128K max output "requires
/// streaming for large outputs" — a non-streaming request at that budget
/// would just recreate the original request-timeout defect at scale.
public struct AnthropicCopilotProvider: CopilotProviding {
    let config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    public func complete(
        _ request: CopilotTurnRequest,
        onEvent: (@Sendable (CopilotStreamEvent) async -> Void)? = nil
    ) async throws -> CopilotReply {
        guard let key = config.anthropicKey else {
            throw AIServiceError.notConfigured("ANTHROPIC_API_KEY")
        }
        let maxTokens = request.maxTokens ?? AnthropicModelCatalog.maxOutputTokens(forModel: config.anthropicModel)
        var body: [String: Any] = [
            "model": config.anthropicModel,
            "max_tokens": maxTokens,
            "system": request.system,
            "messages": try Self.wireMessages(request.messages),
            "tools": try Self.wireTools(request.tools),
            "stream": true,
        ]
        // Extended thinking (M10-p-6): per-model config from the ONE catalog
        // that also drives `maxOutputTokens` above and the curated model
        // picker — see `AnthropicModelCatalog`. Omitted entirely for a model
        // that predates it (Haiku 4.5) or is unrecognized.
        if let thinkingValue = AnthropicModelCatalog.thinkingConfig(forModel: config.anthropicModel).wireValue {
            body["thinking"] = thinkingValue
        }
        let urlRequest = try HTTP.makeRequest(
            to: config.anthropicBaseURL.appendingPathComponent("v1/messages"),
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
            ],
            body: body,
            timeoutSeconds: CopilotTurnRequest.turnTimeoutSeconds
        )
        let (byteStream, response) = try await URLSession.shared.bytes(for: urlRequest)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            // A non-2xx response to a streaming request still arrives as an
            // ordinary (non-SSE) error body — same shape `HTTP.postJSON`
            // throws for every other provider call, so `errorBodyText` (and
            // its error-envelope detection) applies unchanged.
            var errorData = Data()
            for try await byte in byteStream {
                errorData.append(byte)
            }
            throw AIServiceError.requestFailed(status: status, body: HTTP.errorBodyText(errorData))
        }
        let assembled = try await Self.assembleSSE(byteStream.lines, onEvent: onEvent)
        let data = try JSONSerialization.data(withJSONObject: assembled)
        return try Self.parseReply(data, status: status)
    }

    /// Consumes an SSE line sequence from `/v1/messages` (`stream: true`)
    /// LIVE — line by line, AS the network delivers them, never buffered
    /// into an array first (a prior version collected the whole response
    /// before assembling, which silently killed real-time streaming: every
    /// `onEvent` delta fired in one burst after the read completed, so a
    /// live partial transcript never actually appeared live — caught by a
    /// staging gate polling `ai.copilotState` mid-turn and observing zero
    /// `partial: true` entries). Assembles into the SAME top-level
    /// dictionary shape the non-streaming API returns (`{"content": [...],
    /// "stop_reason": ...}`), so it can be fed through the ordinary,
    /// UNFORKED `parseReply` below once the sequence ends — streaming is a
    /// transport/assembly concern only, never a second parsing path. `Lines`
    /// is generic (rather than pinned to `AsyncLineSequence<URLSession.
    /// AsyncBytes>`) so a test can drive this from any `String`-element async
    /// sequence it controls (an `AsyncStream`, in particular, to prove
    /// liveness deterministically) without touching the network at all;
    /// `Sendable` matches what `byteStream.lines` provides under Swift 6
    /// strict concurrency.
    ///
    /// Event boundaries are detected by the NEXT `event:` line (or end of
    /// stream) closing out the PREVIOUS one — NOT by the blank line the SSE
    /// spec nominally uses as a separator: `URLSession.AsyncBytes`'s `.lines`
    /// does not reliably preserve those blank lines (empirically confirmed
    /// against a real loopback stream — they get coalesced away), so relying
    /// on them silently dropped every event and produced an empty reply.
    ///
    /// Handles: `content_block_start` (seeds a block from its own fields — a
    /// `text`/`thinking` block's initial text is normally empty and grows via
    /// deltas; a `redacted_thinking` block arrives COMPLETE here, with no
    /// deltas at all); `content_block_delta` (`text_delta`/`thinking_delta`/
    /// `signature_delta` append onto the seeded block; `input_json_delta`
    /// accumulates a tool_use's `partial_json` text SEPARATELY, reconstructed
    /// into `input` at `content_block_stop` — an empty accumulation parses as
    /// `{}`); `message_delta` (captures `delta.stop_reason`); an `error`
    /// event (handed straight back AS the assembled dict, so `parseReply`'s
    /// EXISTING `errorEnvelopeMessage` defensive check throws it — no forked
    /// error path). `message_start`/`message_stop`/`ping`/anything
    /// unrecognized: no-ops. A transcript with no `data:` lines at all (not
    /// SSE-shaped) throws `.malformedResponse`, matching the non-streaming
    /// client's "unparsable body" guarantee.
    ///
    /// `onEvent`, when non-nil, is AWAITED inline for every non-empty
    /// `text_delta`/`thinking_delta` AS it's processed, DURING the `for try
    /// await` line loop below — this is the one place a `CopilotStreamEvent`
    /// is ever produced, and it fires mid-stream by construction now that
    /// the loop consumes `lines` directly rather than a pre-collected array.
    /// Await here (not a fire-and-forget `Task`) preserves stream ORDER end
    /// to end and gives the caller real backpressure; it does not change
    /// what gets assembled — the returned dictionary is unaffected by
    /// whether/how a caller consumes the events.
    static func assembleSSE<Lines: AsyncSequence & Sendable>(
        _ lines: Lines,
        onEvent: (@Sendable (CopilotStreamEvent) async -> Void)? = nil
    ) async throws -> [String: Any] where Lines.Element == String {
        var contentBlocks: [Int: [String: Any]] = [:]
        var partialJSON: [Int: String] = [:]
        var order: [Int] = []
        var stopReason: String?
        var sawAnyDataLine = false
        var errorEventObject: [String: Any]?

        var currentEvent: String?
        var dataLines: [String] = []

        // Processes whatever event/data accumulated so far, then resets —
        // called both when a NEW "event:" line starts (closing the previous
        // one) and once more after the loop (closing the last one).
        func flushPendingEvent() async {
            defer { currentEvent = nil; dataLines = [] }
            guard errorEventObject == nil,
                  let event = currentEvent, !dataLines.isEmpty,
                  let dataObject = try? JSONSerialization.jsonObject(
                      with: Data(dataLines.joined(separator: "\n").utf8)) as? [String: Any]
            else { return }

            switch event {
            case "error":
                errorEventObject = dataObject
            case "content_block_start":
                guard let index = dataObject["index"] as? Int,
                      let block = dataObject["content_block"] as? [String: Any]
                else { return }
                contentBlocks[index] = block
                partialJSON[index] = ""
                order.append(index)
            case "content_block_delta":
                guard let index = dataObject["index"] as? Int,
                      let delta = dataObject["delta"] as? [String: Any],
                      let deltaType = delta["type"] as? String
                else { return }
                switch deltaType {
                case "text_delta":
                    let fragment = delta["text"] as? String ?? ""
                    let existing = contentBlocks[index]?["text"] as? String ?? ""
                    contentBlocks[index]?["text"] = existing + fragment
                    if let onEvent, !fragment.isEmpty {
                        await onEvent(.textDelta(blockIndex: index, text: fragment))
                    }
                case "thinking_delta":
                    let fragment = delta["thinking"] as? String ?? ""
                    let existing = contentBlocks[index]?["thinking"] as? String ?? ""
                    contentBlocks[index]?["thinking"] = existing + fragment
                    if let onEvent, !fragment.isEmpty {
                        await onEvent(.thinkingDelta(blockIndex: index, text: fragment))
                    }
                case "signature_delta":
                    let existing = contentBlocks[index]?["signature"] as? String ?? ""
                    contentBlocks[index]?["signature"] = existing + (delta["signature"] as? String ?? "")
                case "input_json_delta":
                    partialJSON[index, default: ""] += delta["partial_json"] as? String ?? ""
                default:
                    break   // forward-compatible: unknown delta kinds ignored
                }
            case "content_block_stop":
                guard let index = dataObject["index"] as? Int else { return }
                if contentBlocks[index]?["type"] as? String == "tool_use" {
                    let jsonText = partialJSON[index] ?? ""
                    let inputText = jsonText.isEmpty ? "{}" : jsonText
                    contentBlocks[index]?["input"] =
                        (try? JSONSerialization.jsonObject(with: Data(inputText.utf8))) ?? [String: Any]()
                }
            case "message_delta":
                if let delta = dataObject["delta"] as? [String: Any] {
                    stopReason = (delta["stop_reason"] as? String) ?? stopReason
                }
            default:
                break   // message_start / message_stop / ping: no action needed
            }
        }

        for try await line in lines {
            if line.hasPrefix("event:") {
                await flushPendingEvent()
                currentEvent = String(line.dropFirst("event:".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("data:") {
                sawAnyDataLine = true
                dataLines.append(String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces))
                continue
            }
            // A blank separator line (when present) or any other line (SSE
            // "id:"/"retry:", comments, ...) carries no information of its
            // own — event boundaries are handled above, on the NEXT
            // "event:" line, not here.
        }
        await flushPendingEvent()

        if let errorEventObject {
            // Hand the error envelope straight to `parseReply`'s EXISTING
            // defensive `errorEnvelopeMessage` check (identical to a 2xx
            // envelope in the non-streaming path) — no forked error handling.
            return errorEventObject
        }

        guard sawAnyDataLine else {
            throw AIServiceError.malformedResponse("response was not a valid SSE stream (no 'data:' lines)")
        }

        var result: [String: Any] = ["content": order.compactMap { contentBlocks[$0] }]
        if let stopReason { result["stop_reason"] = stopReason }
        return result
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
            case .thinking(_, let rawJSON):
                // Round-trips a preserved thinking/redacted_thinking block
                // byte-for-byte semantically (signature included) — the
                // `summary` text is a UI-facing derivative, never part of the
                // wire echo. See `CopilotContentBlock.thinking`'s doc comment.
                guard let object = try decodedJSONObject(rawJSON) as? [String: Any] else {
                    throw AIServiceError.malformedResponse("thinking content block did not round-trip to a JSON object")
                }
                return object
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
                // in a conversation turn, and the API requires them to be
                // echoed back VERBATIM (signature intact) on the next round
                // of the same conversation — so the whole block object is
                // preserved, not dropped, regardless of `summary`. A
                // `redacted_thinking` block's real content is `data`, never
                // shown, so its summary is always "". A `thinking` block's
                // `thinking` text is "" under the default `display:
                // "omitted"` and non-empty under the requested `"summarized"`
                // (see `AnthropicModelCatalog`) — either way it's a valid
                // block that must round-trip unchanged.
                let rawJSON = try JSONSerialization.data(withJSONObject: item)
                let summary = (type == "thinking") ? (item["thinking"] as? String ?? "") : ""
                blocks.append(.thinking(summary: summary, rawJSON: rawJSON))
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

    public func complete(
        _ request: CopilotTurnRequest,
        onEvent: (@Sendable (CopilotStreamEvent) async -> Void)? = nil
    ) async throws -> CopilotReply {
        // Non-streaming fallback — nothing to stream, so `onEvent` (accepted
        // only for protocol conformance) is never invoked.
        guard let key = config.openAIKey else {
            throw AIServiceError.notConfigured("OPENAI_API_KEY")
        }
        var body: [String: Any] = [
            "model": config.openAITextModel,
            "messages": try Self.wireMessages(system: request.system, messages: request.messages),
            "tools": try Self.wireTools(request.tools),
        ]
        // nil == "no artificial limit": OMIT the field entirely rather than
        // sending a value — OpenAI already treats an absent max-tokens field
        // as "use the model's own maximum". This provider is the dormant
        // fallback and stays non-streaming (see `AnthropicCopilotProvider`
        // for the primary, now-streaming path).
        if let maxTokens = request.maxTokens {
            body["max_tokens"] = maxTokens
        }
        let (data, status) = try await HTTP.postJSON(
            to: config.openAIBaseURL.appendingPathComponent("v1/chat/completions"),
            headers: ["Authorization": "Bearer \(key)"],
            body: body,
            timeoutSeconds: CopilotTurnRequest.turnTimeoutSeconds
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
                    case .thinking:
                        // Cross-provider replay: an Anthropic thinking block
                        // riding in shared `history` means nothing to OpenAI
                        // — silently skipped, never thrown.
                        continue
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
                    case .thinking:
                        // Cross-provider replay: an Anthropic thinking block
                        // riding in shared `history` means nothing to OpenAI
                        // — silently skipped, never thrown.
                        continue
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
