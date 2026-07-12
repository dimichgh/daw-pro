import Foundation
import os
import Testing
import AIServices
@testable import DAWAppKit

/// Headless coverage for `SettingsModel` (M6): save/clear, masking, env-locked
/// rows, and validation — driven against an `InMemoryKeyStore`, so no Keychain
/// or process env is touched. The security invariant (never hold/expose a stored
/// value) is asserted structurally: the model shows a source and a session mask,
/// never a read-back plaintext.
@MainActor
@Suite("Settings model — API keys (M6)")
struct SettingsModelTests {

    private func model(
        store: InMemoryKeyStore = InMemoryKeyStore(),
        env: [String: String] = [:]
    ) -> SettingsModel {
        SettingsModel(store: store, environment: env)
    }

    // MARK: - Row shape

    @Test("rows cover anthropic/openai/suno + the keyless ACE-Step info row")
    func rowShape() {
        let m = model()
        #expect(m.rows.count == 4)
        #expect(m.rows.map(\.id) == ["anthropic", "openai", "suno", "ace-step"])
        let suno = m.rows.first { $0.id == "suno" }
        #expect(suno?.dormant == true)
        let ace = m.rows.first { $0.id == "ace-step" }
        #expect(ace?.provider == nil)
        #expect(ace?.subtitle.contains("no key") == true)
    }

    // MARK: - Save + mask

    @Test("save stores the key, sets a masked display, and clears the draft")
    func saveStoresAndMasks() {
        let store = InMemoryKeyStore()
        let m = model(store: store)
        m.setDraft("sk-ant-abcdEFGH1234", for: .anthropic)
        #expect(m.canSave(.anthropic))
        #expect(m.save(.anthropic) == .saved)

        let row = m.rows.first { $0.id == "anthropic" }!
        #expect(row.configured)
        #expect(row.source == .keychain)
        #expect(row.draftKey.isEmpty)                  // draft wiped after save
        #expect(row.savedMask == "•••• 1234")          // last-4 mask only
        #expect(store.key(for: .anthropic) == "sk-ant-abcdEFGH1234")  // reached the store
        // The mask never contains the full key.
        #expect(row.savedMask?.contains("abcd") == false)
    }

    @Test("save trims surrounding whitespace before storing")
    func saveTrims() {
        let store = InMemoryKeyStore()
        let m = model(store: store)
        m.setDraft("  sk-openai-XYZ9  ", for: .openai)
        #expect(m.save(.openai) == .saved)
        #expect(store.key(for: .openai) == "sk-openai-XYZ9")
    }

    // MARK: - Clear

    @Test("clear removes the stored key and the mask")
    func clearRemoves() async {
        let store = InMemoryKeyStore([.openai: "sk-existing"])
        let m = model(store: store)
        await m.refresh()
        #expect(m.rows.first { $0.id == "openai" }?.configured == true)

        #expect(m.clear(.openai) == .cleared)
        let row = m.rows.first { $0.id == "openai" }!
        #expect(!row.configured)
        #expect(row.source == APIKeySource.none)
        #expect(row.savedMask == nil)
        #expect(store.key(for: .openai) == nil)
    }

    // MARK: - Env-locked rows

    @Test("an env-sourced row is locked, read-only, and refuses save/clear")
    func envLocked() {
        let store = InMemoryKeyStore()
        let m = model(store: store, env: ["ANTHROPIC_API_KEY": "sk-env-provided"])
        let row = m.rows.first { $0.id == "anthropic" }!
        #expect(row.source == .env)
        #expect(row.configured)
        #expect(row.isLocked)
        #expect(!row.isEditable)

        // Attempts to edit an env row are rejected and never touch the store.
        m.setDraft("sk-attempt-override", for: .anthropic)
        #expect(!m.canSave(.anthropic))
        #expect(m.save(.anthropic) == .locked)
        #expect(m.clear(.anthropic) == .locked)
        #expect(store.key(for: .anthropic) == nil)
    }

    @Test("env wins over an existing keychain key and locks the row")
    func envBeatsKeychainInModel() {
        let store = InMemoryKeyStore([.openai: "sk-keychain"])
        let m = model(store: store, env: ["OPENAI_API_KEY": "sk-env"])
        let row = m.rows.first { $0.id == "openai" }!
        #expect(row.source == .env)
        #expect(row.isLocked)
    }

    // MARK: - Validation

    @Test("empty / whitespace-only drafts are invalid")
    func rejectsEmpty() {
        let m = model()
        m.setDraft("   ", for: .suno)
        #expect(!m.canSave(.suno))
        #expect(m.save(.suno) == .invalid)
    }

    @Test("a draft with an interior newline or space is a mis-paste — rejected")
    func rejectsInteriorWhitespace() {
        let m = model()
        m.setDraft("sk-part1\nsk-part2", for: .suno)
        #expect(m.save(.suno) == .invalid)

        m.setDraft("Bearer sk-realkey", for: .suno)
        #expect(m.save(.suno) == .invalid)

        m.setDraft("sk-with space", for: .suno)
        #expect(m.save(.suno) == .invalid)
    }

    @Test("mask helper shows only the last four characters, dots for short keys")
    func maskHelper() {
        #expect(SettingsModel.mask("sk-abcd1234") == "•••• 1234")
        #expect(SettingsModel.mask("abcd") == "•••• abcd")
        #expect(SettingsModel.mask("ab") == "••••")
        #expect(SettingsModel.mask("") == "••••")
    }

    @Test("validatedKey trims and rejects interior whitespace")
    func validatedKeyHelper() {
        #expect(SettingsModel.validatedKey("  sk-ok  ") == "sk-ok")
        #expect(SettingsModel.validatedKey("") == nil)
        #expect(SettingsModel.validatedKey("a b") == nil)
        #expect(SettingsModel.validatedKey("a\tb") == nil)
    }

    // MARK: - m10-t: no init store access, off-main presence probe

    /// THE regression pin for the startup hang: constructing the model must never
    /// touch the store — not the value-reading `key(for:)` (which triggered the
    /// Keychain consent dialog before the window existed) and not even the
    /// presence probe. All resolution is deferred to the async `refresh()`.
    @Test("init makes ZERO store calls — the m10-t startup-hang regression pin")
    func initTouchesNoStore() {
        let store = CountingKeyStore(presence: [.anthropic: .present, .openai: .present, .suno: .present])
        _ = SettingsModel(store: store, environment: [:])
        #expect(store.valueReads == 0)
        #expect(store.totalPresenceCalls == 0)
    }

    @Test("init makes ZERO store calls even when an env key is present")
    func initTouchesNoStoreWithEnv() {
        let store = CountingKeyStore(presence: [.openai: .present])
        _ = SettingsModel(store: store, environment: ["ANTHROPIC_API_KEY": "sk-env"])
        #expect(store.valueReads == 0)
        #expect(store.totalPresenceCalls == 0)
    }

    @Test("rows start in the honest .checking state before any probe")
    func rowsStartChecking() {
        let store = CountingKeyStore(presence: [.anthropic: .present])
        let m = SettingsModel(store: store, environment: [:])
        for id in ["anthropic", "openai", "suno"] {
            let row = m.rows.first { $0.id == id }!
            #expect(row.isChecking)
            #expect(!row.configured)
            #expect(row.source == APIKeySource.none)
        }
    }

    @Test("refresh probes each keychain row exactly once — never a value read")
    func refreshProbesOncePerRow() async {
        let store = CountingKeyStore(presence: [.anthropic: .present, .openai: .absent, .suno: .present])
        let m = SettingsModel(store: store, environment: [:])
        await m.refresh()
        #expect(store.valueReads == 0)
        #expect(store.presenceCalls(for: .anthropic) == 1)
        #expect(store.presenceCalls(for: .openai) == 1)
        #expect(store.presenceCalls(for: .suno) == 1)
    }

    @Test("presence maps to truthful row state including interactionRequired")
    func presenceMapsToRowState() async {
        let store = CountingKeyStore(presence: [
            .anthropic: .present,
            .openai: .interactionRequired,
            .suno: .absent,
        ])
        let m = SettingsModel(store: store, environment: [:])
        await m.refresh()

        let anthropic = m.rows.first { $0.id == "anthropic" }!
        #expect(anthropic.status == .keychain)
        #expect(anthropic.configured)
        #expect(anthropic.source == .keychain)
        #expect(!anthropic.consentRequired)
        #expect(!anthropic.isChecking)

        // A stored-but-consent-gated key is STILL configured (source keychain), and
        // the row says so truthfully via `consentRequired`.
        let openai = m.rows.first { $0.id == "openai" }!
        #expect(openai.status == .keychainConsentRequired)
        #expect(openai.configured)
        #expect(openai.source == .keychain)
        #expect(openai.consentRequired)
        #expect(!openai.isChecking)

        let suno = m.rows.first { $0.id == "suno" }!
        #expect(suno.status == .notSet)
        #expect(!suno.configured)
        #expect(suno.source == APIKeySource.none)
    }

    @Test("env precedence short-circuits the store — the env row is never probed")
    func envShortCircuitsProbe() async {
        let store = CountingKeyStore(presence: [
            .anthropic: .present, .openai: .present, .suno: .present,
        ])
        let m = SettingsModel(store: store, environment: ["ANTHROPIC_API_KEY": "sk-env"])
        // Env resolves at init without any store access.
        let anthropic = m.rows.first { $0.id == "anthropic" }!
        #expect(anthropic.source == .env)
        #expect(anthropic.isLocked)
        #expect(!anthropic.isChecking)

        await m.refresh()
        #expect(store.presenceCalls(for: .anthropic) == 0)   // env row never touches the store
        #expect(store.presenceCalls(for: .openai) == 1)
        #expect(store.presenceCalls(for: .suno) == 1)
        #expect(store.valueReads == 0)
    }

    @Test("resolveForCapture resolves presence synchronously (capture path)")
    func resolveForCaptureSync() {
        let store = InMemoryKeyStore([.openai: "sk-x"])
        let m = SettingsModel(store: store, environment: [:])
        #expect(m.rows.first { $0.id == "openai" }?.isChecking == true)
        m.resolveForCapture()
        let row = m.rows.first { $0.id == "openai" }!
        #expect(row.status == .keychain)
        #expect(row.configured)
    }

    @Test("status(for:) maps presence → row status")
    func statusMappingHelper() {
        #expect(SettingsModel.status(for: .present) == .keychain)
        #expect(SettingsModel.status(for: .absent) == .notSet)
        #expect(SettingsModel.status(for: .interactionRequired) == .keychainConsentRequired)
    }
}

/// A fake store that COUNTS accesses so the suite can pin the m10-t invariants:
/// `init` must make zero calls, the status path must use the presence probe (never
/// the value-reading `key(for:)`), and env rows must not be probed at all. Thread-
/// safe (the probe runs off the main actor in `refresh()`), Sendable without
/// `@unchecked` — every access is serialized by the lock.
private final class CountingKeyStore: APIKeyStoring, Sendable {
    private struct Box: Sendable {
        var valueReads = 0
        var presenceCalls: [AIProviderID: Int] = [:]
        var presence: [AIProviderID: KeyPresence]
    }
    private let lock: OSAllocatedUnfairLock<Box>

    init(presence: [AIProviderID: KeyPresence] = [:]) {
        lock = OSAllocatedUnfairLock(initialState: Box(presence: presence))
    }

    /// The forbidden value-reading path — records a hit so a test can assert it
    /// stays at zero.
    func key(for provider: AIProviderID) -> String? {
        lock.withLock { $0.valueReads += 1 }
        return nil
    }
    func setKey(_ key: String, for provider: AIProviderID) throws {}
    func removeKey(for provider: AIProviderID) throws {}

    func keyPresence(for provider: AIProviderID) -> KeyPresence {
        lock.withLock { box in
            box.presenceCalls[provider, default: 0] += 1
            return box.presence[provider] ?? .absent
        }
    }

    var valueReads: Int { lock.withLock { $0.valueReads } }
    var totalPresenceCalls: Int { lock.withLock { $0.presenceCalls.values.reduce(0, +) } }
    func presenceCalls(for provider: AIProviderID) -> Int {
        lock.withLock { $0.presenceCalls[provider] ?? 0 }
    }
}
