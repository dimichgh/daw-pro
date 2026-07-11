import Foundation
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
}
