import Foundation

/// All AI provider configuration in one place. Keys come from the environment
/// (with .env fallback for development) — never hardcoded, never logged.
public struct AIConfig: Sendable {
    public var anthropicKey: String?
    public var openAIKey: String?
    public var sunoKey: String?
    public var sunoBaseURL: URL

    /// Model IDs live here and only here (see docs/AI-INTEGRATIONS.md).
    public var anthropicModel: String
    public var openAITextModel: String
    public var openAIImageModel: String

    public init(
        anthropicKey: String? = nil,
        openAIKey: String? = nil,
        sunoKey: String? = nil,
        sunoBaseURL: URL = URL(string: "https://api.suno.com/v1")!,
        anthropicModel: String = "claude-sonnet-5",
        openAITextModel: String = "gpt-4o",
        openAIImageModel: String = "gpt-image-2"
    ) {
        self.anthropicKey = anthropicKey
        self.openAIKey = openAIKey
        self.sunoKey = sunoKey
        self.sunoBaseURL = sunoBaseURL
        self.anthropicModel = anthropicModel
        self.openAITextModel = openAITextModel
        self.openAIImageModel = openAIImageModel
    }

    /// Reads process environment first, then a `.env` file in the working
    /// directory (KEY=VALUE lines, # comments).
    public static func fromEnvironment(
        dotEnvURL: URL = URL(fileURLWithPath: ".env")
    ) -> AIConfig {
        var values = Self.parseDotEnv(at: dotEnvURL)
        for (key, value) in ProcessInfo.processInfo.environment {
            values[key] = value
        }
        var config = AIConfig()
        config.anthropicKey = values["ANTHROPIC_API_KEY"].nonEmpty
        config.openAIKey = values["OPENAI_API_KEY"].nonEmpty
        config.sunoKey = values["SUNO_API_KEY"].nonEmpty
        if let base = values["SUNO_API_BASE"].nonEmpty, let url = URL(string: base) {
            config.sunoBaseURL = url
        }
        if let model = values["OPENAI_IMAGE_MODEL"].nonEmpty {
            config.openAIImageModel = model
        }
        return config
    }

    static func parseDotEnv(at url: URL) -> [String: String] {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        var values: [String: String] = [:]
        for line in contents.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"),
                  let equals = trimmed.firstIndex(of: "=") else { continue }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equals)...])
                .trimmingCharacters(in: .whitespaces)
            values[key] = value
        }
        return values
    }
}

public enum AIServiceError: Error, LocalizedError {
    case notConfigured(String)
    case requestFailed(status: Int, body: String)
    case malformedResponse(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .notConfigured(let key):
            return "\(key) is not set — add it to .env (see .env.example)"
        case .requestFailed(let status, let body):
            return "provider request failed (HTTP \(status)): \(body.prefix(500))"
        case .malformedResponse(let detail):
            return "could not parse provider response: \(detail)"
        case .notImplemented(let detail):
            return detail
        }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
