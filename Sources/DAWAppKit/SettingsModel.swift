import Foundation
import AIServices

/// Headless state for the Settings → API Keys panel (M6). Mirrors the
/// `SketchpadModel` pattern: `@MainActor @Observable`, zero AppKit/SwiftUI, all
/// logic here so the view is thin and the suite drives it against an
/// `InMemoryKeyStore`.
///
/// SECURITY: the model NEVER holds a stored key beyond the `save()` call. It
/// resolves only the SOURCE (env/keychain/none) for display, never reading a
/// stored plaintext back for the UI. A just-saved key is shown as a masked
/// "•••• 1234" derived from the value the user typed THIS session — cleared on
/// the next `refresh`/relaunch. Env-sourced rows are locked (the UI can't edit
/// an environment variable).
@MainActor
@Observable
public final class SettingsModel {
    /// The provider rows in display order: anthropic, openai, suno (dormant),
    /// then the keyless ACE-Step info row.
    public private(set) var rows: [ProviderRow]

    private let store: APIKeyStoring
    private let environment: [String: String]

    public init(
        store: APIKeyStoring,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.store = store
        self.environment = environment
        self.rows = Self.makeRows()
        refresh()
    }

    static func makeRows() -> [ProviderRow] {
        [
            ProviderRow(
                kind: .key(.anthropic),
                title: "Anthropic",
                subtitle: "Lyrics, naming, and music-theory reasoning",
                dormant: false
            ),
            ProviderRow(
                kind: .key(.openai),
                title: "OpenAI",
                subtitle: "Text fallback and GPT Image (UI assets)",
                dormant: false
            ),
            ProviderRow(
                kind: .key(.suno),
                title: "Suno",
                subtitle: "Cloud song generation — dormant fallback",
                dormant: true
            ),
            ProviderRow(
                kind: .localKeyless,
                title: "ACE-Step",
                subtitle: "Local sidecar — no key needed",
                dormant: false
            ),
        ]
    }

    // MARK: - Resolution (source only — never the value)

    /// Recomputes each key row's `source`/`configured` from the resolution chain.
    /// The resolved VALUE is discarded here — only presence and source drive the
    /// UI, so the model never retains stored key material.
    public func refresh() {
        for i in rows.indices {
            guard case .key(let provider) = rows[i].kind else { continue }
            let source = resolveKey(provider: provider, environment: environment, store: store).source
            rows[i].source = source
            rows[i].configured = source != .none
        }
    }

    // MARK: - Draft entry

    /// The current draft key for `provider` (empty when none / after a save).
    public func draft(for provider: AIProviderID) -> String {
        row(provider)?.draftKey ?? ""
    }

    /// Updates the draft key for `provider` as the user types.
    public func setDraft(_ value: String, for provider: AIProviderID) {
        guard let i = index(provider) else { return }
        rows[i].draftKey = value
    }

    /// True when the current draft would pass validation (drives the Save enable
    /// state). Env-locked rows are never savable regardless.
    public func canSave(_ provider: AIProviderID) -> Bool {
        guard let r = row(provider), !r.isLocked else { return false }
        return Self.validatedKey(r.draftKey) != nil
    }

    // MARK: - Save / clear

    /// The outcome of a save/clear, so the view can surface an inline message
    /// without the model owning presentation. `failed` carries the Keychain
    /// error text (which never includes the key value).
    public enum ActionResult: Equatable, Sendable {
        case saved
        case cleared
        case invalid
        case locked
        case failed(String)
    }

    /// Validates and stores the draft for `provider`, then shows a session-only
    /// mask and clears the draft. Refuses env-locked rows and invalid drafts.
    @discardableResult
    public func save(_ provider: AIProviderID) -> ActionResult {
        guard let i = index(provider) else { return .failed("unknown provider") }
        if rows[i].isLocked { return .locked }
        guard let validated = Self.validatedKey(rows[i].draftKey) else { return .invalid }
        do {
            try store.setKey(validated, for: provider)
        } catch {
            return .failed(Self.errorMessage(error))
        }
        // Mask is derived from the value we just saved — never read back from
        // the store — and lives only for this session.
        rows[i].savedMask = Self.mask(validated)
        rows[i].draftKey = ""
        refresh()
        return .saved
    }

    /// Removes any stored key for `provider` and clears its mask/draft. Refuses
    /// env-locked rows.
    @discardableResult
    public func clear(_ provider: AIProviderID) -> ActionResult {
        guard let i = index(provider) else { return .failed("unknown provider") }
        if rows[i].isLocked { return .locked }
        do {
            try store.removeKey(for: provider)
        } catch {
            return .failed(Self.errorMessage(error))
        }
        rows[i].savedMask = nil
        rows[i].draftKey = ""
        refresh()
        return .cleared
    }

    // MARK: - Capture seeding (debug only)

    /// Sets a row's masked display directly, for a capture that needs to show a
    /// just-saved key without driving the real Keychain. Debug/capture use only
    /// (the `SketchpadModel.setCandidatesForCapture` precedent).
    public func setSavedMaskForCapture(_ mask: String?, for provider: AIProviderID) {
        guard let i = index(provider) else { return }
        rows[i].savedMask = mask
    }

    // MARK: - Validation / masking helpers

    /// A draft is valid when, after trimming outer whitespace, it is non-empty
    /// AND contains no interior whitespace or newline (a real API key has none —
    /// interior whitespace means a mis-paste: a stray line break, a doubled key,
    /// or a "Bearer " prefix). Returns the trimmed key, or nil when invalid.
    /// The value is never logged.
    static func validatedKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) != nil { return nil }
        return trimmed
    }

    /// "•••• 1234" — a fixed dot run plus the last four characters, so a
    /// just-saved key reads as present without exposing it. A key shorter than
    /// four characters shows only the dots. Session-only; never persisted.
    static func mask(_ key: String) -> String {
        guard key.count >= 4 else { return "••••" }
        return "•••• \(key.suffix(4))"
    }

    static func errorMessage(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            return description
        }
        return "\(error)"
    }

    private func index(_ provider: AIProviderID) -> Int? {
        rows.firstIndex { $0.provider == provider }
    }

    private func row(_ provider: AIProviderID) -> ProviderRow? {
        index(provider).map { rows[$0] }
    }
}

/// One row in the Settings → API Keys panel. Either a key-backed provider
/// (editable unless env-locked) or the keyless local sidecar (informational).
public struct ProviderRow: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A key-backed provider (editable — save/clear a Keychain key).
        case key(AIProviderID)
        /// The local ACE-Step sidecar: no key, informational row only.
        case localKeyless
    }

    public let kind: Kind
    public let title: String
    public let subtitle: String
    /// Suno is a dormant fallback — flagged so the view can badge it.
    public let dormant: Bool

    /// Resolved source (meaningful only for `.key` rows; `.none` otherwise).
    public internal(set) var source: APIKeySource = .none
    /// Whether a key is available (env or keychain).
    public internal(set) var configured: Bool = false
    /// Transient entry text.
    public internal(set) var draftKey: String = ""
    /// Session-only masked display of a just-saved key (nil when none).
    public internal(set) var savedMask: String?

    public init(kind: Kind, title: String, subtitle: String, dormant: Bool) {
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.dormant = dormant
    }

    /// Stable id: the provider raw value, or "ace-step" for the keyless row.
    public var id: String {
        switch kind {
        case .key(let provider): return provider.rawValue
        case .localKeyless: return "ace-step"
        }
    }

    /// The backing provider, or nil for the keyless row.
    public var provider: AIProviderID? {
        if case .key(let provider) = kind { return provider }
        return nil
    }

    /// True when set by an environment variable — the UI can't edit it (remove
    /// the env var to manage it in-app).
    public var isLocked: Bool { source == .env }

    /// True when this row accepts key entry (a key-backed row that isn't
    /// env-locked).
    public var isEditable: Bool { provider != nil && !isLocked }
}
