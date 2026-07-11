import Foundation

/// OpenAI client — text fallback and image generation (GPT Image) for UI assets.
public struct OpenAIClient: LyricsGenerating, ImageGenerating {
    let config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    public func generateLyrics(theme: String, style: String?) async throws -> String {
        // The key guard lives in `chat` (its single round-trip); `generateLyrics`
        // just shapes the prompt.
        let user = style.map { "Theme: \(theme)\nStyle: \($0)" } ?? "Theme: \(theme)"
        return try await chat(
            system: "You are a professional lyricist. Write complete, singable lyrics with section labels like [Verse 1] and [Chorus]. Return only the lyrics.",
            user: user)
    }

    /// M6 lyrics workshop: the OpenAI equivalent of `AnthropicClient.writeLyrics`
    /// — same shared `LyricsPromptBuilder` system/user prompts over chat
    /// completions. Reports itself as the provider.
    public func writeLyrics(_ request: LyricsWriteRequest) async throws -> LyricsWriteResult {
        let text = try await chat(
            system: LyricsPromptBuilder.systemPrompt(request),
            user: LyricsPromptBuilder.userPrompt(request))
        return LyricsWriteResult(lyrics: text, provider: AIProviderID.openai.rawValue)
    }

    /// One chat-completions round trip with a system + user message.
    private func chat(system: String, user: String) async throws -> String {
        guard let key = config.openAIKey else {
            throw AIServiceError.notConfigured("OPENAI_API_KEY")
        }
        let (data, status) = try await HTTP.postJSON(
            to: config.openAIBaseURL.appendingPathComponent("v1/chat/completions"),
            headers: ["Authorization": "Bearer \(key)"],
            body: [
                "model": config.openAITextModel,
                "messages": [
                    ["role": "system", "content": system],
                    ["role": "user", "content": user],
                ],
            ]
        )
        let object = try HTTP.json(data)

        // Defensive: surface the API's own error type/message rather than
        // falling through to the "missing message.content" guard below
        // (mirrors `AnthropicClient.complete`; `postJSON` already handles
        // the ordinary non-2xx case with identical formatting).
        if let errorMessage = HTTP.errorEnvelopeMessage(object) {
            throw AIServiceError.requestFailed(status: status, body: errorMessage)
        }

        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIServiceError.malformedResponse("missing choices[0].message in OpenAI response")
        }

        // `message.content` can be a plain string, `null` (a reply that only
        // carries `tool_calls`), or an array of typed content parts
        // (`{"type":"text","text":...}` / `{"type":"output_text","text":...}`)
        // — extract text from every shape rather than assuming a string.
        if let text = Self.extractText(from: message["content"]), !text.isEmpty {
            return text
        }
        if let refusal = message["refusal"] as? String, !refusal.isEmpty {
            throw AIServiceError.malformedResponse("model declined to respond: \(refusal)")
        }
        throw AIServiceError.malformedResponse(
            "missing choices[0].message.content in OpenAI response (no refusal given either)")
    }

    /// Extracts plain text from an OpenAI `message.content`: a plain string
    /// returns as-is; an array of typed parts has its `text` fields joined
    /// with "\n"; anything else (including `null`, e.g. a tool-calls-only
    /// reply) returns `nil`.
    static func extractText(from content: Any?) -> String? {
        if let text = content as? String {
            return text
        }
        if let parts = content as? [[String: Any]] {
            let texts = parts.compactMap { $0["text"] as? String }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        }
        return nil
    }

    public func generateImage(prompt: String, size: String = "1024x1024") async throws -> Data {
        guard let key = config.openAIKey else {
            throw AIServiceError.notConfigured("OPENAI_API_KEY")
        }
        let (data, _) = try await HTTP.postJSON(
            to: config.openAIBaseURL.appendingPathComponent("v1/images/generations"),
            headers: ["Authorization": "Bearer \(key)"],
            body: [
                "model": config.openAIImageModel,
                "prompt": prompt,
                "size": size,
            ]
        )
        let object = try HTTP.json(data)
        guard let images = object["data"] as? [[String: Any]],
              let base64 = images.first?["b64_json"] as? String,
              let png = Data(base64Encoded: base64) else {
            throw AIServiceError.malformedResponse("missing data[0].b64_json")
        }
        return png
    }
}
