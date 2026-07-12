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
        // m10-t: init performs ZERO store access — the old synchronous
        // `refresh()` here resolved each row through the value-reading `key(for:)`,
        // which, for a rebuilt/foreign-identity binary with a stored key, parked on
        // the macOS Keychain consent dialog BEFORE the window (and the control
        // server) existed — an indefinite, UI-less hang. Env is a pure dict lookup
        // (no store, no prompt), so env-locked rows resolve immediately and keep
        // their precedence; every other key row starts `.checking` until the async
        // `refresh()` (kicked AFTER the window appears) probes the Keychain.
        resolveEnvOnly()
    }

    /// Resolves ONLY the environment source for each key row — a pure dict lookup
    /// that touches neither the store nor the network, so it never prompts or
    /// blocks. Env-provided rows become `.env` (locked, highest precedence);
    /// everything else stays `.checking` until the presence probe runs.
    private func resolveEnvOnly() {
        for i in rows.indices {
            guard case .key(let provider) = rows[i].kind else { continue }
            if let envValue = environment[provider.environmentKey], !envValue.isEmpty {
                rows[i].status = .env
            } else {
                rows[i].status = .checking
            }
        }
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

    // MARK: - Resolution (presence only — never the value)

    /// Recomputes each keychain-backed row's state via the NON-VALUE presence
    /// probe (m10-t). Env rows are already resolved (init, no store) and are left
    /// untouched. The probe runs OFF the main actor: it is designed not to block,
    /// but a wedged `securityd` must still never freeze the UI — so the store call
    /// hops to a detached task and only the mapped results come back to the actor.
    /// No key VALUE is ever read here.
    ///
    /// Kicked AFTER the window appears (see DAWProApp), never from `init`.
    public func refresh() async {
        let providers = pendingProbeProviders()
        guard !providers.isEmpty else { return }
        let store = self.store   // Sendable; safe to cross into the detached task.
        let presences: [AIProviderID: KeyPresence] = await Task.detached(priority: .utility) {
            var out: [AIProviderID: KeyPresence] = [:]
            for provider in providers { out[provider] = store.keyPresence(for: provider) }
            return out
        }.value
        apply(presences)
    }

    /// Debug/capture ONLY: resolves presence SYNCHRONOUSLY on the current actor.
    /// Safe because captures always drive an `InMemoryKeyStore` (never the real
    /// Keychain), so there is no prompt and no possible block — the async
    /// `refresh()` off-main path is reserved for the real Keychain at launch.
    /// Public only so the app's `debug.settingsSeed` capture handler can call it
    /// (the `setSavedMaskForCapture` precedent).
    public func resolveForCapture() {
        var presences: [AIProviderID: KeyPresence] = [:]
        for provider in pendingProbeProviders() {
            presences[provider] = store.keyPresence(for: provider)
        }
        apply(presences)
    }

    /// The key rows still awaiting a Keychain probe: every `.key` row whose
    /// environment variable is NOT set (env rows are resolved without the store
    /// and must never be probed — that preserves env precedence AND avoids a
    /// pointless store hit).
    private func pendingProbeProviders() -> [AIProviderID] {
        rows.compactMap { row in
            guard case .key(let provider) = row.kind else { return nil }
            if let envValue = environment[provider.environmentKey], !envValue.isEmpty { return nil }
            return provider
        }
    }

    /// Applies presence results to the matching rows (env rows are absent from
    /// `presences`, so they are never overwritten).
    private func apply(_ presences: [AIProviderID: KeyPresence]) {
        for i in rows.indices {
            guard case .key(let provider) = rows[i].kind,
                  let presence = presences[provider] else { continue }
            rows[i].status = Self.status(for: presence)
        }
    }

    /// Maps a presence probe result to a keychain-row status. Extracted so it is
    /// testable headless and shared by the async/sync/capture paths.
    static func status(for presence: KeyPresence) -> ProviderRow.Status {
        switch presence {
        case .present: return .keychain
        case .interactionRequired: return .keychainConsentRequired
        case .absent: return .notSet
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
        // We KNOW the outcome without a probe: a save only reaches here for a
        // non-env row (env rows are locked and refused above), and the key is now
        // stored → `.keychain`. Setting it directly avoids a redundant store read
        // (and never touches the value-reading path). Consent-gated same-process
        // saves read cleanly on the next real use.
        rows[i].status = .keychain
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
        // Only non-env rows reach here (env rows are locked/refused), and the key
        // is now removed → `.notSet`. Set directly; no probe needed.
        rows[i].status = .notSet
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

    /// A row's resolution state (m10-t). `checking` is the honest INITIAL state
    /// before the async presence probe has run — the UI shows "checking", never a
    /// false "NOT SET". `env`/`keychain` are usable-now; `keychainConsentRequired`
    /// means a key is stored but macOS will prompt to read it on first use.
    public enum Status: Sendable, Equatable {
        case checking
        case notSet
        case env
        case keychain
        case keychainConsentRequired
    }

    public let kind: Kind
    public let title: String
    public let subtitle: String
    /// Suno is a dormant fallback — flagged so the view can badge it.
    public let dormant: Bool

    /// Resolution state (meaningful only for `.key` rows). Starts `.checking` so
    /// the row never lies before the presence probe lands.
    public internal(set) var status: Status = .checking
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

    /// Resolved source, derived from `status` (unchanged meaning for consumers):
    /// `env`, `keychain` (incl. consent-gated), else `none`.
    public var source: APIKeySource {
        switch status {
        case .env: return .env
        case .keychain, .keychainConsentRequired: return .keychain
        case .notSet, .checking: return .none
        }
    }

    /// Whether a key is available (env or keychain — a consent-gated keychain key
    /// still counts as configured). False while `.checking` and when `.notSet`.
    public var configured: Bool {
        switch status {
        case .env, .keychain, .keychainConsentRequired: return true
        case .notSet, .checking: return false
        }
    }

    /// True before the first presence probe resolves this row (drives the neutral
    /// "checking" badge so the UI never claims NOT SET prematurely). Only key rows
    /// can be "checking" — the keyless ACE-Step info row is never resolving.
    public var isChecking: Bool { provider != nil && status == .checking }

    /// True when a key is stored but macOS will require an interactive prompt to
    /// read its value on first use — the row is configured, but should say so.
    public var consentRequired: Bool { status == .keychainConsentRequired }

    /// True when set by an environment variable — the UI can't edit it (remove
    /// the env var to manage it in-app).
    public var isLocked: Bool { status == .env }

    /// True when this row accepts key entry (a key-backed row that isn't
    /// env-locked).
    public var isEditable: Bool { provider != nil && !isLocked }
}
