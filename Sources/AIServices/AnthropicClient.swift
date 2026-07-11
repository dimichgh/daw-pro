import Foundation

/// Anthropic Messages API client — primary provider for lyrics and any
/// creative/reasoning text in the app.
public struct AnthropicClient: LyricsGenerating {
    let config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    public func generateLyrics(theme: String, style: String?) async throws -> String {
        try await complete(
            system: """
            You are a professional lyricist working inside a DAW. Write complete, \
            singable lyrics with clear section labels in square brackets: [Verse 1], \
            [Chorus], [Bridge], etc. Match the requested style's rhythm and vocabulary. \
            Return only the lyrics — no commentary.
            """,
            user: style.map { "Theme: \(theme)\nStyle: \($0)" } ?? "Theme: \(theme)"
        )
    }

    /// M6 lyrics workshop: teaches the bracketed ACE-Step format + singability and
    /// weaves in the project context via `LyricsPromptBuilder`; REFINE mode sends
    /// the existing lyrics + instruction. Reports itself as the provider.
    public func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
        let text = try await complete(
            system: LyricsPromptBuilder.systemPrompt(request),
            user: LyricsPromptBuilder.userPrompt(request)
        )
        return LyricsWriteResult(lyrics: text, provider: AIProviderID.anthropic.rawValue)
    }

    public func complete(system: String, user: String, maxTokens: Int = 2048) async throws -> String {
        guard let key = config.anthropicKey else {
            throw AIServiceError.notConfigured("ANTHROPIC_API_KEY")
        }
        let (data, status) = try await HTTP.postJSON(
            to: config.anthropicBaseURL.appendingPathComponent("v1/messages"),
            headers: [
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
            ],
            body: [
                "model": config.anthropicModel,
                "max_tokens": maxTokens,
                "system": system,
                "messages": [["role": "user", "content": user]],
            ]
        )
        let object = try HTTP.json(data)

        // Defensive: surface the API's own error type/message (e.g.
        // "overloaded_error: Overloaded") rather than falling through to the
        // "no text content" guard below — covers an error envelope that
        // somehow arrives on a 2xx status (`postJSON` already handles the
        // ordinary non-2xx case with identical formatting).
        if let message = HTTP.errorEnvelopeMessage(object) {
            throw AIServiceError.requestFailed(status: status, body: message)
        }

        guard let content = object["content"] as? [[String: Any]] else {
            throw AIServiceError.malformedResponse("missing 'content' array in Anthropic response")
        }

        // Modern Claude models can lead with "thinking"/"redacted_thinking"
        // blocks (extended thinking) before any text, and can emit
        // "tool_use" blocks too — content[0] is NOT guaranteed to be text.
        // Collect text from EVERY "text" block (in order) and join them,
        // silently skipping every other block type.
        let texts = content.compactMap { block -> String? in
            guard block["type"] as? String == "text" else { return nil }
            return block["text"] as? String
        }
        guard !texts.isEmpty else {
            let blockTypes = content.compactMap { $0["type"] as? String }
            let stopReason = object["stop_reason"] as? String ?? "unknown"
            throw AIServiceError.malformedResponse(
                "no text content block in Anthropic response (block types present: "
                    + "\(blockTypes.isEmpty ? "none" : blockTypes.joined(separator: ", "))"
                    + ", stop_reason: \(stopReason))"
            )
        }
        return texts.joined(separator: "\n")
    }
}
