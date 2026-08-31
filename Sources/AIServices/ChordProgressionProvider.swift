import Foundation
import DAWCore

// m34-g — PLAYBOX'S AI LEG.
//
// ⭐ **NO NEW PROVIDER.** This rides the SAME Anthropic/OpenAI clients, the same
// key-resolution chain and the same `AIServiceError` vocabulary that the lyrics
// workshop uses (`resolveLyricsWriter`, Providers.swift) — the roadmap named
// that explicitly, and a second HTTP client for four integers would be absurd.
//
// ⛔⛔ **THE MODEL'S ANSWER IS NEVER TRUSTED AND NEVER SHOWN.** It is parsed by
// `PlayboxProgression.parseDegrees` (DAWCore) and, if it does not survive,
// discarded — the caller falls back to the local variation and SAYS SO. No model
// text ever reaches the strip, so a prompt-injected sentence has no surface to
// appear on.
//
// ⛔ **KEYS ARE READ FOR PRESENCE AND NEVER RETURNED OR LOGGED** — the invariant
// the whole KeyStore seam enforces. An unconfigured provider is reported as a
// STATE (`AIServiceError.noProviderConfigured`), never as a key value.

/// Produces a chord progression, as scale degrees, for a project's key/tempo/
/// section.
public protocol ChordProgressionGenerating: Sendable {
    /// - Returns: a plan whose `degrees` have ALREADY passed
    ///   `PlayboxProgression.validate`, and whose provenance names the provider.
    /// - Throws: `AIServiceError` on transport/format failure. ⚠️ A conformer
    ///   must NOT silently fall back to the local library here — the FALLBACK IS
    ///   THE CALLER'S DECISION, because only the caller can tell the user which
    ///   path ran, and a fallback hidden behind a successful return is exactly
    ///   the "record says X, source says Y" defect this tree keeps closing.
    func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan
}

extension AnthropicClient: ChordProgressionGenerating {
    public func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
        let text = try await complete(
            system: PlayboxProgression.systemPrompt(),
            user: PlayboxProgression.userPrompt(request),
            // Four integers. A 2048-token budget on this would be paying for
            // room the answer must never use.
            maxTokens: 256)
        return try Self.plan(fromModelText: text, provider: AIProviderID.anthropic.rawValue)
    }

    /// Shared by both clients: parse, validate, and turn a refusal into a
    /// readable `malformedResponse` rather than a silent local fallback.
    static func plan(fromModelText text: String, provider: String) throws -> PlayboxPlan {
        guard let degrees = PlayboxProgression.parseDegrees(fromModelText: text) else {
            // ⚠️ The model's text is NOT interpolated into this message. It is
            // untrusted and can be arbitrarily long; the caller shows this
            // string to the user. Only its shape is reported.
            throw AIServiceError.malformedResponse(
                "the model did not answer with a usable diatonic progression "
                + "(expected a JSON array of \(PlayboxProgression.degreeRange.lowerBound)–"
                + "\(PlayboxProgression.degreeRange.upperBound) scale degrees, "
                + "got \(text.count) characters that did not parse)")
        }
        return PlayboxPlan(
            degrees: degrees,
            name: "Playbox",
            provenance: PlayboxProvenance(kind: .ai, detail: provider))
    }
}

extension OpenAIClient: ChordProgressionGenerating {
    public func generateProgression(_ request: PlayboxRequest) async throws -> PlayboxPlan {
        let text = try await completeText(
            system: PlayboxProgression.systemPrompt(),
            user: PlayboxProgression.userPrompt(request))
        return try AnthropicClient.plan(fromModelText: text,
                                        provider: AIProviderID.openai.rawValue)
    }
}

// MARK: - Provider selection

/// Resolves a configured progression generator — Anthropic first, else OpenAI —
/// with `baseConfig`'s model IDs / base URLs preserved so a stub-server suite can
/// retarget it at loopback.
///
/// ⭐ **IT REUSES `selectLyricsProvider`'S CHAIN VERBATIM.** Two functions that
/// agree about which providers exist are two things to keep in step; this is the
/// same question ("who has a key?") asked for a different capability.
///
/// - Throws: `AIServiceError.noProviderConfigured(capability: "chord-progression")`
///   when neither provider has a key. ⛔ **THAT IS NOT A FAILURE OF THE FEATURE**
///   — Playbox's caller catches it and runs the local variation path, then says
///   on screen that it did.
public func resolveChordProgressionGenerator(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: APIKeyStoring?,
    config baseConfig: AIConfig = AIConfig()
) throws -> any ChordProgressionGenerating {
    switch selectLyricsProvider(environment: environment, store: store) {
    case .anthropic:
        var config = baseConfig
        config.anthropicKey = resolveKey(provider: .anthropic,
                                         environment: environment, store: store).value
        return AnthropicClient(config: config)
    case .openai:
        var config = baseConfig
        config.openAIKey = resolveKey(provider: .openai,
                                      environment: environment, store: store).value
        return OpenAIClient(config: config)
    default:
        throw AIServiceError.noProviderConfigured(capability: "chord-progression")
    }
}
