import Foundation

/// OpenAI client — text fallback and image generation (GPT Image) for UI assets.
public struct OpenAIClient: LyricsGenerating, ImageGenerating {
    let config: AIConfig

    public init(config: AIConfig) {
        self.config = config
    }

    public func generateLyrics(theme: String, style: String?) async throws -> String {
        guard let key = config.openAIKey else {
            throw AIServiceError.notConfigured("OPENAI_API_KEY")
        }
        let user = style.map { "Theme: \(theme)\nStyle: \($0)" } ?? "Theme: \(theme)"
        let (data, _) = try await HTTP.postJSON(
            to: URL(string: "https://api.openai.com/v1/chat/completions")!,
            headers: ["Authorization": "Bearer \(key)"],
            body: [
                "model": config.openAITextModel,
                "messages": [
                    [
                        "role": "system",
                        "content": "You are a professional lyricist. Write complete, singable lyrics with section labels like [Verse 1] and [Chorus]. Return only the lyrics.",
                    ],
                    ["role": "user", "content": user],
                ],
            ]
        )
        let object = try HTTP.json(data)
        guard let choices = object["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let text = message["content"] as? String else {
            throw AIServiceError.malformedResponse("missing choices[0].message.content")
        }
        return text
    }

    public func generateImage(prompt: String, size: String = "1024x1024") async throws -> Data {
        guard let key = config.openAIKey else {
            throw AIServiceError.notConfigured("OPENAI_API_KEY")
        }
        let (data, _) = try await HTTP.postJSON(
            to: URL(string: "https://api.openai.com/v1/images/generations")!,
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
