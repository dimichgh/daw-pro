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

    public func complete(system: String, user: String, maxTokens: Int = 2048) async throws -> String {
        guard let key = config.anthropicKey else {
            throw AIServiceError.notConfigured("ANTHROPIC_API_KEY")
        }
        let (data, _) = try await HTTP.postJSON(
            to: URL(string: "https://api.anthropic.com/v1/messages")!,
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
        guard let content = object["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw AIServiceError.malformedResponse("missing content[0].text")
        }
        return text
    }
}
