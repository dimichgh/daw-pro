import Foundation
import os
import Testing
@testable import AIServices

/// The API-key seam (M6): the env-first resolution chain, the in-memory store,
/// the status report (values/lengths never surface), and a live Keychain
/// round-trip. No network, no process spawn — the suite stays green headless.
///
/// House directive under test throughout: a key VALUE is only ever read to
/// CONFIGURE resolution; the status surface (`providerStatuses`) exposes booleans
/// and the env/keychain/none source only.
@Suite("API key store + resolution chain (M6)")
struct KeyStoreTests {

    // MARK: - Resolution chain

    @Test("env beats keychain")
    func envBeatsKeychain() {
        let store = InMemoryKeyStore([.anthropic: "sk-keychain-value"])
        let env = ["ANTHROPIC_API_KEY": "sk-env-value"]
        let resolved = resolveKey(provider: .anthropic, environment: env, store: store)
        #expect(resolved.source == .env)
        #expect(resolved.value == "sk-env-value")
    }

    @Test("keychain used when no env var is set")
    func keychainWhenNoEnv() {
        let store = InMemoryKeyStore([.openai: "sk-keychain-openai"])
        let resolved = resolveKey(provider: .openai, environment: [:], store: store)
        #expect(resolved.source == .keychain)
        #expect(resolved.value == "sk-keychain-openai")
    }

    @Test("none when neither env nor keychain has a key")
    func noneWhenNothing() {
        let store = InMemoryKeyStore()
        let resolved = resolveKey(provider: .suno, environment: [:], store: store)
        #expect(resolved.source == .none)
        #expect(resolved.value == nil)
    }

    @Test("an empty env var does not count as configured — falls through to keychain")
    func emptyEnvFallsThrough() {
        let store = InMemoryKeyStore([.anthropic: "sk-keychain"])
        let resolved = resolveKey(provider: .anthropic, environment: ["ANTHROPIC_API_KEY": ""], store: store)
        #expect(resolved.source == .keychain)
    }

    @Test("nil store with no env resolves to none (pre-Keychain default behavior)")
    func nilStoreNoEnvIsNone() {
        let resolved = resolveKey(provider: .anthropic, environment: [:], store: nil)
        #expect(resolved.source == .none)
        #expect(resolved.value == nil)
    }

    @Test("env var names match the exact names the clients have always read")
    func environmentKeyNames() {
        #expect(AIProviderID.anthropic.environmentKey == "ANTHROPIC_API_KEY")
        #expect(AIProviderID.openai.environmentKey == "OPENAI_API_KEY")
        #expect(AIProviderID.suno.environmentKey == "SUNO_API_KEY")
    }

    @Test("ACE-Step is keyless: it is not a member of AIProviderID")
    func aceStepIsNotAProvider() {
        #expect(AIProviderID.allCases.count == 3)
        #expect(!AIProviderID.allCases.map(\.rawValue).contains("ace-step"))
        #expect(!AIProviderID.allCases.map(\.rawValue).contains("acestep"))
    }

    // MARK: - InMemoryKeyStore round-trip

    @Test("in-memory store add / read / overwrite / remove")
    func inMemoryRoundTrip() throws {
        let store = InMemoryKeyStore()
        #expect(store.key(for: .openai) == nil)
        try store.setKey("first", for: .openai)
        #expect(store.key(for: .openai) == "first")
        try store.setKey("second", for: .openai)
        #expect(store.key(for: .openai) == "second")
        try store.removeKey(for: .openai)
        #expect(store.key(for: .openai) == nil)
        // Removing an absent key is a clean no-op.
        try store.removeKey(for: .openai)
    }

    // MARK: - AIConfig wiring (additive; env unchanged, keychain fills gaps)

    @Test("AIConfig with nil store and no env is fully unset (unchanged default)")
    func configNilStoreUnset() {
        // A dot-env path that doesn't exist keeps the process env as the only
        // source; on CI/dev this may or may not carry keys, so we assert the
        // shape (a nil store never INVENTS a key), not a concrete value.
        let store = InMemoryKeyStore()
        // With an empty environment + empty store, all three resolve to none.
        for provider in AIProviderID.allCases {
            #expect(resolveKey(provider: provider, environment: [:], store: store).source == .none)
        }
    }

    // MARK: - Status report (booleans/enums only)

    @Test("providerStatuses reports configured + source, never a value")
    func statusesReportSourceOnly() {
        let store = InMemoryKeyStore([.openai: "sk-secret-should-not-leak-1234"])
        let env = ["ANTHROPIC_API_KEY": "sk-env-should-not-leak-5678"]
        let statuses = providerStatuses(environment: env, store: store)

        #expect(statuses.count == 3)
        let byProvider = Dictionary(uniqueKeysWithValues: statuses.map { ($0.provider, $0) })
        #expect(byProvider["anthropic"]?.configured == true)
        #expect(byProvider["anthropic"]?.source == .env)
        #expect(byProvider["openai"]?.configured == true)
        #expect(byProvider["openai"]?.source == .keychain)
        #expect(byProvider["suno"]?.configured == false)
        #expect(byProvider["suno"]?.source == APIKeySource.none)

        // Prove no key material rode along: encode the report and scan the JSON.
        let data = try! JSONEncoder().encode(statuses)
        let json = String(data: data, encoding: .utf8)!
        #expect(!json.contains("sk-secret-should-not-leak-1234"))
        #expect(!json.contains("sk-env-should-not-leak-5678"))
    }

    // MARK: - Live Keychain round-trip
    //
    // Generic-password items created and read by the SAME process do not
    // prompt on macOS, so this runs headless on a CLI test host. It uses an
    // ISOLATED service namespace so it can never read, overwrite, or delete a
    // real DAW Pro key, and always cleans up.

    @Test("Keychain add / read / update / delete round-trip (isolated namespace)")
    func keychainRoundTrip() throws {
        let service = "com.dawpro.api-keys.test.\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service)
        defer { try? store.removeKey(for: .suno) }

        #expect(store.key(for: .suno) == nil)
        try store.setKey("sk-live-keychain-abcd", for: .suno)
        #expect(store.key(for: .suno) == "sk-live-keychain-abcd")
        // Re-save overwrites in place (update path).
        try store.setKey("sk-live-keychain-wxyz", for: .suno)
        #expect(store.key(for: .suno) == "sk-live-keychain-wxyz")
        try store.removeKey(for: .suno)
        #expect(store.key(for: .suno) == nil)
        // Delete of an absent item is a clean no-op, not a throw.
        try store.removeKey(for: .suno)
    }

    // MARK: - m10-t: non-value presence probe + presence-based status

    /// The default `keyPresence` (used by in-memory/fake stores) mirrors `key(for:)`
    /// presence without any prompt/block risk.
    @Test("default keyPresence falls back to presence-from-value for in-memory stores")
    func defaultPresenceFallback() {
        let store = InMemoryKeyStore([.openai: "sk-x"])
        #expect(store.keyPresence(for: .openai) == .present)
        #expect(store.keyPresence(for: .anthropic) == .absent)
    }

    /// The REAL `KeychainKeyStore.keyPresence` code path (success / not-found
    /// branches) exercised headless: same-process items don't prompt on macOS, and
    /// an isolated namespace keeps it away from real DAW Pro keys.
    @Test("KeychainKeyStore.keyPresence round-trip (isolated namespace, no prompt in-process)")
    func keychainPresenceRoundTrip() throws {
        let service = "com.dawpro.api-keys.test.\(UUID().uuidString)"
        let store = KeychainKeyStore(service: service)
        defer { try? store.removeKey(for: .suno) }

        #expect(store.keyPresence(for: .suno) == .absent)
        try store.setKey("sk-live-presence-abcd", for: .suno)
        #expect(store.keyPresence(for: .suno) == .present)
        try store.removeKey(for: .suno)
        #expect(store.keyPresence(for: .suno) == .absent)
    }

    @Test("providerStatuses maps presence → source/configured/consentRequired")
    func statusesFromPresence() {
        let store = RecordingKeyStore([
            .anthropic: .present,
            .openai: .interactionRequired,
            .suno: .absent,
        ])
        let statuses = providerStatuses(environment: [:], store: store)
        let byId = Dictionary(uniqueKeysWithValues: statuses.map { ($0.provider, $0) })

        #expect(byId["anthropic"]?.configured == true)
        #expect(byId["anthropic"]?.source == .keychain)
        #expect(byId["anthropic"]?.consentRequired == false)
        // Stored-but-consent-gated stays configured=true / source=keychain — only the
        // additive flag changes, so existing consumers are unaffected.
        #expect(byId["openai"]?.configured == true)
        #expect(byId["openai"]?.source == .keychain)
        #expect(byId["openai"]?.consentRequired == true)
        #expect(byId["suno"]?.configured == false)
        #expect(byId["suno"]?.source == APIKeySource.none)
        #expect(byId["suno"]?.consentRequired == false)
    }

    /// The m10-t WIRE-LIMB regression pin: the status report must resolve through
    /// the presence probe and never the value-reading `key(for:)` (which could trip
    /// the consent prompt for a headless caller).
    @Test("providerStatuses never uses the value-reading key(for:) path")
    func statusesNeverValueRead() {
        let store = RecordingKeyStore([.anthropic: .present, .openai: .interactionRequired])
        _ = providerStatuses(environment: [:], store: store)
        #expect(!store.didValueRead)
    }

    @Test("providerStatuses: env still wins and does not probe the store")
    func statusesEnvWins() {
        let store = RecordingKeyStore([.anthropic: .interactionRequired])
        let statuses = providerStatuses(environment: ["ANTHROPIC_API_KEY": "sk-env"], store: store)
        let anthropic = statuses.first { $0.provider == "anthropic" }!
        #expect(anthropic.source == .env)
        #expect(anthropic.configured == true)
        #expect(anthropic.consentRequired == false)
        // Env short-circuits BEFORE any store access — the forbidden value-read path
        // (and any probe) is untouched.
        #expect(!store.didValueRead)
    }

    @Test("AIProviderStatus.consentRequired defaults false (additive, back-compatible)")
    func consentDefaultsFalse() {
        let status = AIProviderStatus(provider: "openai", configured: true, source: .keychain)
        #expect(status.consentRequired == false)
        // Encodes the field but never a value/length.
        let json = String(data: try! JSONEncoder().encode(status), encoding: .utf8)!
        #expect(json.contains("consentRequired"))
        #expect(!json.contains("\"length\""))
    }
}

/// A fake store that returns a scripted `KeyPresence` and RECORDS whether the
/// forbidden value-reading `key(for:)` path was ever hit — so the suite can pin
/// that the status surface resolves via presence only (m10-t). Sendable via a lock
/// (no `@unchecked`).
private final class RecordingKeyStore: APIKeyStoring, Sendable {
    private let box: OSAllocatedUnfairLock<(presence: [AIProviderID: KeyPresence], valueRead: Bool)>

    init(_ presence: [AIProviderID: KeyPresence]) {
        box = OSAllocatedUnfairLock(initialState: (presence, false))
    }

    func key(for provider: AIProviderID) -> String? {
        box.withLock { $0.valueRead = true }
        return nil
    }
    func setKey(_ key: String, for provider: AIProviderID) throws {}
    func removeKey(for provider: AIProviderID) throws {}
    func keyPresence(for provider: AIProviderID) -> KeyPresence {
        box.withLock { $0.presence[provider] ?? .absent }
    }

    var didValueRead: Bool { box.withLock { $0.valueRead } }
}
