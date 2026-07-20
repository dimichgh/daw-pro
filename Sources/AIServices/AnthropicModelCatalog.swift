import Foundation

/// The Anthropic Messages API `thinking` request-parameter shape for a given
/// model (Anthropic docs, cached 2026-07). `display` only affects the
/// VISIBILITY of the returned thinking text — never behavior or billing.
public enum AnthropicThinkingConfig: Sendable, Equatable {
    /// `{"type":"adaptive","display":"summarized"}` — Sonnet 5 / Opus 4.7 /
    /// Opus 4.8 / Fable 5 / Mythos 5 default to `display: "omitted"` (an
    /// empty thinking text, present but never shown); this opts into a
    /// human-readable summary instead, so the copilot's live transcript can
    /// surface real reasoning (M10-p-6).
    case adaptiveSummarized
    /// `{"type":"adaptive"}` — Sonnet 4.6 / Opus 4.6 predate the `display`
    /// field (added in 4.7) but already return summarized text by default,
    /// so there's nothing to opt into.
    case adaptive
    /// Omit the `thinking` key from the request body entirely. Haiku 4.5
    /// predates adaptive thinking (the old `budget_tokens` era this app never
    /// targets) — sending the param would either be rejected or misbehave.
    /// Also the conservative fallback for any unrecognized model id.
    case omit

    /// The request-body value for the `thinking` key, or nil to omit the key
    /// entirely (`.omit`).
    var wireValue: [String: Any]? {
        switch self {
        case .adaptiveSummarized: return ["type": "adaptive", "display": "summarized"]
        case .adaptive: return ["type": "adaptive"]
        case .omit: return nil
        }
    }
}

/// One row of the Anthropic model catalog: the curated picker fields
/// (`name`/`note`, nil for a lookup-only row not offered in the picker) and
/// the two request-shaping behaviors `AnthropicCopilotProvider` reads for
/// EVERY copilot turn. See `AnthropicModelCatalog`'s doc comment for why all
/// of this lives in one table.
public struct AnthropicModelInfo: Sendable, Equatable {
    public let id: String
    /// User-facing name, or nil for a lookup-only row: `maxOutputTokens`/
    /// `thinking` still resolve correctly if this id is ever reached, it's
    /// simply not offered by the model picker / `ai.copilotSetModel`.
    public let name: String?
    public let note: String?
    public let maxOutputTokens: Int
    public let thinking: AnthropicThinkingConfig

    public init(id: String, name: String?, note: String?, maxOutputTokens: Int, thinking: AnthropicThinkingConfig) {
        self.id = id
        self.name = name
        self.note = note
        self.maxOutputTokens = maxOutputTokens
        self.thinking = thinking
    }
}

/// The single source of truth for every per-model Anthropic copilot behavior
/// (M10-p-6): the max-output-token ceiling, the extended-thinking request
/// config, AND the curated user-facing model picker (id/name/note) — ONE
/// table, several columns, so the picker can never drift from the
/// request-shaping behavior (two separately-maintained lists is exactly the
/// defect class this avoids). Every lookup matches by ID PREFIX, so a
/// date-suffixed model id (e.g. "claude-sonnet-5-20260115") still resolves.
public enum AnthropicModelCatalog {
    /// The copilot's model when no setting has ever been persisted —
    /// byte-identical to `AIConfig.anthropicModel`'s own default.
    public static let defaultModelID = "claude-sonnet-5"

    /// The full per-model lookup table. `curated` (below) is FILTERED from
    /// this exact array — never a separately maintained list.
    public static let all: [AnthropicModelInfo] = [
        AnthropicModelInfo(
            id: "claude-sonnet-5", name: "Sonnet 5", note: "balanced — the default",
            maxOutputTokens: 128_000, thinking: .adaptiveSummarized),
        AnthropicModelInfo(
            id: "claude-opus-4-8", name: "Opus 4.8", note: "flagship reasoning, higher cost",
            maxOutputTokens: 128_000, thinking: .adaptiveSummarized),
        AnthropicModelInfo(
            id: "claude-opus-4-7", name: "Opus 4.7", note: "previous flagship",
            maxOutputTokens: 128_000, thinking: .adaptiveSummarized),
        AnthropicModelInfo(
            id: "claude-sonnet-4-6", name: "Sonnet 4.6", note: "previous-generation balanced",
            maxOutputTokens: 128_000, thinking: .adaptive),
        AnthropicModelInfo(
            id: "claude-fable-5", name: "Fable 5", note: "most capable",
            maxOutputTokens: 128_000, thinking: .adaptiveSummarized),
        AnthropicModelInfo(
            id: "claude-haiku-4-5", name: "Haiku 4.5", note: "fast / economy",
            maxOutputTokens: 64_000, thinking: .omit),
        // Lookup-only rows: kept so their behavior columns still resolve
        // correctly if reached some other way (e.g. an env override or a
        // future direct id), but not offered by the picker.
        AnthropicModelInfo(
            id: "claude-opus-4-6", name: nil, note: nil,
            maxOutputTokens: 128_000, thinking: .adaptive),
        AnthropicModelInfo(
            id: "claude-mythos-5", name: nil, note: nil,
            maxOutputTokens: 128_000, thinking: .adaptiveSummarized),
    ]

    /// The user-selectable subset (id/name/note), in display order — exactly
    /// the `all` rows carrying a curated `name`. `ai.copilotGetModel`'s
    /// `catalog` field, `ai.copilotSetModel`'s validation set, and the
    /// Settings model picker (a later UI phase) all read this ONE array.
    public static let curated: [AnthropicModelInfo] = all.filter { $0.name != nil }

    /// The UserDefaults key the in-app copilot-model setting persists under
    /// — the `copilot.maxRounds` / `controlServer.port` app-preference
    /// naming family.
    public static let userDefaultsKey = "copilot.model"

    /// The `all` row matching `model` by PREFIX, or nil if none matches.
    public static func lookup(forModel model: String) -> AnthropicModelInfo? {
        all.first { model.hasPrefix($0.id) }
    }

    /// `lookup(forModel:)?.maxOutputTokens`, or the conservative 64000
    /// fallback for an unrecognized id — safe on every currently active
    /// model. Used only when `CopilotTurnRequest.maxTokens` is nil ("no
    /// artificial limit" means requesting the model's OWN ceiling).
    public static func maxOutputTokens(forModel model: String) -> Int {
        lookup(forModel: model)?.maxOutputTokens ?? 64_000
    }

    /// `lookup(forModel:)?.thinking`, or `.omit` for an unrecognized id — the
    /// same conservative default Haiku 4.5 uses: never send a `thinking`
    /// param this client hasn't verified a model understands.
    public static func thinkingConfig(forModel model: String) -> AnthropicThinkingConfig {
        lookup(forModel: model)?.thinking ?? .omit
    }
}
