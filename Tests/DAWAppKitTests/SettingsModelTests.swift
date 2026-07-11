import Foundation
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
    func clearRemoves() {
        let store = InMemoryKeyStore([.openai: "sk-existing"])
        let m = model(store: store)
        m.refresh()
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
}
