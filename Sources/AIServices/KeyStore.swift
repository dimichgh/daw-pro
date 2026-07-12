import Foundation
import Security
import os

/// The API-key seam (M6): where provider keys are RESOLVED and STORED, kept in
/// one place so the security invariant is enforceable by reading a single file.
///
/// SECURITY INVARIANT (house directive — never hardcode, never commit, never
/// log key values, not even at debug level): key VALUES never cross the control
/// WebSocket or MCP. Agents' conversations are logged, so a "set key" command
/// would leak a secret. Keys enter the app ONLY via
///   (a) environment variables — dev, highest precedence, unchanged behavior, or
///   (b) the Settings UI → the system Keychain.
/// The wire gets a STATUS-ONLY surface (`AIProviderStatus`): booleans + an
/// env/keychain/none source enum, never a value and never a length. There is
/// deliberately NO set-key command anywhere in `DAWControl`/MCP.
///
/// ACE-Step is the local, keyless generation sidecar — it needs no key and is
/// intentionally NOT a member of `AIProviderID`.

/// A key-backed AI provider. ACE-Step (local sidecar) is keyless and absent by
/// design. `rawValue` is both the Keychain account and the wire `provider` id.
public enum AIProviderID: String, CaseIterable, Sendable, Codable, Equatable {
    case anthropic
    case openai
    case suno

    /// The process-environment variable that supplies this provider's key in
    /// dev (the highest-precedence source — see `resolveKey`). These EXACT
    /// names are what the clients have always read
    /// (`AIConfig.fromEnvironment`); keeping them verbatim means env-provided
    /// keys behave identically before and after this seam landed.
    public var environmentKey: String {
        switch self {
        case .anthropic: return "ANTHROPIC_API_KEY"
        case .openai: return "OPENAI_API_KEY"
        case .suno: return "SUNO_API_KEY"
        }
    }
}

/// Where a resolved key came from. `env` wins over `keychain`; `none` means no
/// key is available. Reported alongside the value by `resolveKey` and — value
/// stripped — on the wire via `AIProviderStatus`.
public enum APIKeySource: String, Sendable, Codable, Equatable {
    case env
    case keychain
    case none
}

/// The result of a NON-VALUE presence probe (m10-t): does a key exist for this
/// provider, WITHOUT reading — and therefore without decrypting — its value.
/// This is the seam that keeps app startup from ever blocking on a Keychain
/// consent prompt: unlike `key(for:)` (a value read that trips the item's ACL
/// dialog for a foreign-identity binary), a presence probe reads metadata only
/// and never prompts, never blocks.
///
/// - `present`: a key is stored and its metadata read cleanly (usable now).
/// - `absent`: no key is stored for this provider.
/// - `interactionRequired`: a key IS stored, but macOS will demand an
///   interactive consent/auth prompt to actually read its VALUE (e.g. a
///   rebuilt binary with a new code-signing identity hitting the item's ACL).
///   Surfaced truthfully so the UI can say "stored — macOS will ask on first
///   use"; the probe itself never triggers that prompt.
public enum KeyPresence: Sendable, Equatable {
    case present
    case absent
    case interactionRequired
}

/// The result of resolving a provider's key: the value (nil when `source`
/// is `.none`) and where it came from. Callers that only need presence read
/// `source`; the value is used solely to configure a provider client and is
/// never persisted or logged by this layer.
public struct ResolvedKey: Sendable, Equatable {
    public var value: String?
    public var source: APIKeySource

    public init(value: String?, source: APIKeySource) {
        self.value = value
        self.source = source
    }
}

/// Storage seam for provider keys. Synchronous by design (Keychain SecItem is
/// synchronous; the in-memory store is trivially so), and `Sendable` so a
/// single instance can be shared across the `@MainActor` Settings model and the
/// `CommandRouter`. NOTE: there is intentionally no "list all keys" or "read for
/// display" affordance beyond `key(for:)` — the Settings model never reads a
/// stored value back for display (see `SettingsModel`).
public protocol APIKeyStoring: Sendable {
    /// The stored key for `provider`, or nil when none is stored. Used to
    /// CONFIGURE a client — the interactive, value-reading path that MAY prompt
    /// (correct on USE, when a window exists) and must NEVER be called during
    /// startup or from a wire status handler.
    func key(for provider: AIProviderID) -> String?
    /// Stores (adds or replaces) the key for `provider`.
    func setKey(_ key: String, for provider: AIProviderID) throws
    /// Removes any stored key for `provider`. A no-op when none is stored.
    func removeKey(for provider: AIProviderID) throws
    /// PRESENCE ONLY (m10-t): whether a key exists, without reading its value —
    /// so it never decrypts the secret and therefore never triggers the Keychain
    /// consent prompt or blocks. Backs status surfaces (Settings, the
    /// `ai.providerStatus` wire limb) that used to route through the value-reading
    /// `key(for:)` and could hang before the window existed.
    func keyPresence(for provider: AIProviderID) -> KeyPresence
}

extension APIKeyStoring {
    /// Default presence: fall back to a value read. SAFE for the in-memory/fake
    /// stores (they never prompt or block), so tests and previews keep compiling
    /// with no change. `KeychainKeyStore` OVERRIDES this with a real
    /// attributes-only, UI-skipping probe — the whole point of the seam is that
    /// the REAL Keychain never uses this value-reading fallback.
    public func keyPresence(for provider: AIProviderID) -> KeyPresence {
        key(for: provider) != nil ? .present : .absent
    }
}

/// The env-first resolution chain: a process/dev environment variable wins
/// (unchanged dev behavior); else the Keychain; else nil. Reports the SOURCE
/// alongside the value so callers (Settings UI, `ai.providerStatus`) can show
/// "ENV — locked" vs "KEYCHAIN" vs "NOT SET" without ever exposing the value.
///
/// - Parameters:
///   - provider: the key-backed provider to resolve.
///   - environment: the environment to consult (defaults to the process
///     environment; injectable for tests and for captures).
///   - store: the Keychain/in-memory store to fall back to; nil skips it.
public func resolveKey(
    provider: AIProviderID,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: APIKeyStoring?
) -> ResolvedKey {
    if let envValue = environment[provider.environmentKey], !envValue.isEmpty {
        return ResolvedKey(value: envValue, source: .env)
    }
    if let store, let stored = store.key(for: provider), !stored.isEmpty {
        return ResolvedKey(value: stored, source: .keychain)
    }
    return ResolvedKey(value: nil, source: .none)
}

// MARK: - Keychain-backed store

/// `SecItem` generic-password store (service `com.dawpro.api-keys`, account =
/// `AIProviderID.rawValue`, `kSecAttrAccessibleAfterFirstUnlock`). Add/update/
/// delete/read and not-found are all handled cleanly; nothing here logs a key.
public struct KeychainKeyStore: APIKeyStoring {
    /// The default Keychain service (namespace) for API keys.
    public static let defaultService = "com.dawpro.api-keys"

    private let service: String

    /// - Parameter service: the Keychain service namespace. Overridable so a
    ///   capture/test can isolate itself from real keys.
    public init(service: String = KeychainKeyStore.defaultService) {
        self.service = service
    }

    public func key(for provider: AIProviderID) -> String? {
        var query = baseQuery(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    public func setKey(_ key: String, for provider: AIProviderID) throws {
        let data = Data(key.utf8)
        let query = baseQuery(provider)
        // Update-then-add: avoids the duplicate-item error on a re-save while
        // leaving a fresh add to set the accessibility class.
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainError(status: addStatus, operation: "add")
            }
            return
        }
        throw KeychainError(status: updateStatus, operation: "update")
    }

    public func removeKey(for provider: AIProviderID) throws {
        let status = SecItemDelete(baseQuery(provider) as CFDictionary)
        // Already absent is a clean no-op, not an error.
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    /// PRESENCE PROBE (m10-t) — the non-blocking, non-prompting counterpart to
    /// `key(for:)`. Two properties make it safe to call before the window exists
    /// (and from a wire handler):
    ///   1. `kSecReturnAttributes` (NOT `kSecReturnData`): reads metadata only, so
    ///      the secret is never decrypted and the item's ACL consent dialog — the
    ///      exact prompt that hung startup for a rebuilt, different-identity binary
    ///      — is never engaged.
    ///   2. `kSecUseAuthenticationUISkip`: should any authentication still be
    ///      required, `securityd` returns an ERROR INSTANTLY instead of parking on
    ///      a modal, so a wedged/consent-gated item can never block the caller.
    /// Maps success → `.present`, not-found → `.absent`, and any "needs
    /// interaction" status → `.interactionRequired` (truthful: the value is there
    /// but a prompt will appear on first real USE). Logs NOTHING (house directive).
    public func keyPresence(for provider: AIProviderID) -> KeyPresence {
        var query = baseQuery(provider)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUISkip
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return .present
        case errSecItemNotFound:
            return .absent
        // errSecInteractionRequired (brief) plus errSecInteractionNotAllowed — the
        // status `UISkip` actually returns when an item would need a prompt — both
        // mean "stored, but reading the value needs interaction". Additive to the
        // brief's single mapping for robustness (labeled in the report).
        case errSecInteractionRequired, errSecInteractionNotAllowed:
            return .interactionRequired
        default:
            // Any other status: no usable key AND we must not block — report absent.
            return .absent
        }
    }

    private func baseQuery(_ provider: AIProviderID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: provider.rawValue,
        ]
    }
}

/// A Keychain failure carrying only the `OSStatus` + operation — deliberately
/// NEVER the key value or its length (house "never log key values" directive).
public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    public var errorDescription: String? {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Keychain error"
        return "Keychain \(operation) failed (OSStatus \(status)): \(detail)"
    }
}

// MARK: - In-memory store (tests + previews + captures)

/// A process-lifetime store for tests, SwiftUI previews, and capture seeds. The
/// dictionary lives inside an `OSAllocatedUnfairLock`, so the type is genuinely
/// `Sendable` under Swift 6 strict concurrency WITHOUT `@unchecked` — every
/// access is serialized by the lock and no reference to the state escapes it.
public final class InMemoryKeyStore: APIKeyStoring, Sendable {
    private let storage = OSAllocatedUnfairLock<[AIProviderID: String]>(initialState: [:])

    public init() {}

    /// Seed with initial keys (e.g. a preview/capture with one provider set).
    public init(_ initial: [AIProviderID: String]) {
        storage.withLock { $0 = initial }
    }

    public func key(for provider: AIProviderID) -> String? {
        storage.withLock { $0[provider] }
    }

    public func setKey(_ key: String, for provider: AIProviderID) throws {
        storage.withLock { $0[provider] = key }
    }

    public func removeKey(for provider: AIProviderID) throws {
        storage.withLock { $0[provider] = nil }
    }
}

// MARK: - Wire status (booleans/enums only — never a value)

/// The ONLY key-related fact that crosses the control plane / MCP: per-provider
/// presence + source. Carries NO key material and NO length — booleans and the
/// `env|keychain|none` enum only (see the file-level security invariant and the
/// `ai.providerStatus` command doc). Codable so `DAWControl` threads it verbatim.
public struct AIProviderStatus: Codable, Sendable, Equatable {
    /// `AIProviderID.rawValue`.
    public var provider: String
    /// True when a key is available from either source. A keychain key that is
    /// stored but consent-gated STILL reads `true` (it is configured; the source
    /// is `keychain`) — see `consentRequired`.
    public var configured: Bool
    /// Where the key would come from: `env`, `keychain`, or `none`.
    public var source: APIKeySource
    /// ADDITIVE (m10-t): true only when `source == .keychain` AND macOS will
    /// require an interactive consent/auth prompt to READ the value on first use
    /// (a rebuilt binary with a fresh code-signing identity, say). `configured`
    /// and `source` keep their existing meanings for current consumers; this is a
    /// truthful extra signal, defaulting false so old readers are unaffected.
    public var consentRequired: Bool

    public init(
        provider: String,
        configured: Bool,
        source: APIKeySource,
        consentRequired: Bool = false
    ) {
        self.provider = provider
        self.configured = configured
        self.source = source
        self.consentRequired = consentRequired
    }
}

/// Builds the per-provider status report for every `AIProviderID` via the
/// NON-VALUE presence probe (m10-t): env still wins WITHOUT touching the store,
/// else a `keyPresence` probe that never reads the value, never prompts, and
/// never blocks — so a headless `ai.providerStatus` caller can no longer trip
/// the Keychain consent dialog the way the old `resolveKey` (value-read) path
/// could. Only source/presence leave this function; no value is ever read here.
public func providerStatuses(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    store: APIKeyStoring?
) -> [AIProviderStatus] {
    AIProviderID.allCases.map { provider in
        // Env wins — a pure dict lookup, no store access, no prompt.
        if let envValue = environment[provider.environmentKey], !envValue.isEmpty {
            return AIProviderStatus(provider: provider.rawValue, configured: true, source: .env)
        }
        // Else PRESENCE ONLY — never the value.
        switch store?.keyPresence(for: provider) ?? .absent {
        case .present:
            return AIProviderStatus(provider: provider.rawValue, configured: true, source: .keychain)
        case .interactionRequired:
            return AIProviderStatus(
                provider: provider.rawValue, configured: true, source: .keychain,
                consentRequired: true)
        case .absent:
            return AIProviderStatus(provider: provider.rawValue, configured: false, source: .none)
        }
    }
}
