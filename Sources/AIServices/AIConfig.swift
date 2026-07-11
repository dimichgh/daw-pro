import Foundation

/// All AI provider configuration in one place. Keys come from the environment
/// (with .env fallback for development) — never hardcoded, never logged.
public struct AIConfig: Sendable {
    public var anthropicKey: String?
    public var openAIKey: String?
    public var sunoKey: String?
    public var sunoBaseURL: URL

    /// Provider API roots. Real defaults; overridable so the stub-server suites
    /// (and any future self-hosted proxy) can retarget the clients at loopback
    /// WITHOUT the clients hardcoding a hostname. The concrete endpoint paths
    /// (`v1/messages`, `v1/chat/completions`, `v1/images/generations`) are
    /// appended by the clients, so these carry origin only.
    public var anthropicBaseURL: URL
    public var openAIBaseURL: URL

    /// Model IDs live here and only here (see docs/AI-INTEGRATIONS.md).
    public var anthropicModel: String
    public var openAITextModel: String
    public var openAIImageModel: String

    public init(
        anthropicKey: String? = nil,
        openAIKey: String? = nil,
        sunoKey: String? = nil,
        sunoBaseURL: URL = URL(string: "https://api.suno.com/v1")!,
        anthropicBaseURL: URL = URL(string: "https://api.anthropic.com")!,
        openAIBaseURL: URL = URL(string: "https://api.openai.com")!,
        anthropicModel: String = "claude-sonnet-5",
        openAITextModel: String = "gpt-4o",
        openAIImageModel: String = "gpt-image-2"
    ) {
        self.anthropicKey = anthropicKey
        self.openAIKey = openAIKey
        self.sunoKey = sunoKey
        self.sunoBaseURL = sunoBaseURL
        self.anthropicBaseURL = anthropicBaseURL
        self.openAIBaseURL = openAIBaseURL
        self.anthropicModel = anthropicModel
        self.openAITextModel = openAITextModel
        self.openAIImageModel = openAIImageModel
    }

    /// Reads process environment first, then a `.env` file in the working
    /// directory (KEY=VALUE lines, # comments), then — for any provider still
    /// unset — the injected `keyStore` (the Keychain in the app). The env/`.env`
    /// value ALWAYS wins, so passing `keyStore: nil` (the default) reproduces
    /// the pre-Keychain behavior exactly; the Keychain fallback is purely
    /// additive (see `resolveKey`, the single resolution chain both this and the
    /// Settings UI share).
    public static func fromEnvironment(
        dotEnvURL: URL = URL(fileURLWithPath: ".env"),
        keyStore: APIKeyStoring? = nil
    ) -> AIConfig {
        var values = Self.parseDotEnv(at: dotEnvURL)
        for (key, value) in ProcessInfo.processInfo.environment {
            values[key] = value
        }
        var config = AIConfig()
        // env/.env wins; Keychain fills only what env left empty (all via the
        // shared chain, so the precedence can't drift between here and the UI).
        config.anthropicKey = resolveKey(provider: .anthropic, environment: values, store: keyStore).value
        config.openAIKey = resolveKey(provider: .openai, environment: values, store: keyStore).value
        config.sunoKey = resolveKey(provider: .suno, environment: values, store: keyStore).value
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
    /// No key-backed provider is available for a capability (e.g. lyrics writing
    /// prefers Anthropic, falls back to OpenAI, and lands here when NEITHER is
    /// configured). The message is deliberately actionable — it names the app's
    /// Settings panel and the `ai.providerStatus` surface, never the missing key
    /// value — so an agent or the UI can tell the user exactly how to fix it.
    case noProviderConfigured(capability: String)

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
        case .noProviderConfigured(let capability):
            return "No AI provider is configured for \(capability). Add an Anthropic "
                + "or OpenAI API key in the app's Settings panel (⌘,), or check "
                + "ai.providerStatus, then try again."
        }
    }
}

extension Optional where Wrapped == String {
    var nonEmpty: String? {
        guard let self, !self.isEmpty else { return nil }
        return self
    }
}
