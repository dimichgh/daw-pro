import AIServices
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `CopilotModelStore` (M10-p-6): the in-app Copilot
/// model setting a future Settings picker will edit, persisted through an
/// injected backing. Pure/hermetic (in-memory + spy backings), so round-trip,
/// corrupt-load, and reject-on-load are pinned without a running app — the
/// `CopilotLimitsStoreTests` idiom, with its own deliberate divergence: an
/// invalid/no-longer-curated persisted id is treated as "no setting" (there's
/// no sensible "nearest valid model" to clamp to), not clamped.
@MainActor
@Suite("CopilotModelStore — model setting (M10-p-6)")
struct CopilotModelStoreTests {
    @Test("a never-set store has no configured value and reports the default claude-sonnet-5")
    func storeDefaults() {
        let store = CopilotModelStore(backing: InMemoryCopilotModelBacking())
        #expect(store.configuredModel == nil)
        #expect(store.effectiveModel == AnthropicModelCatalog.defaultModelID)
        #expect(store.effectiveModel == "claude-sonnet-5")
    }

    @Test("commit persists a valid curated id and round-trips it through the backing")
    func storeCommitRoundTrip() {
        let backing = SpyBacking()
        let store = CopilotModelStore(backing: backing)

        #expect(store.commit("claude-opus-4-8") == "claude-opus-4-8")
        #expect(store.configuredModel == "claude-opus-4-8")
        #expect(store.effectiveModel == "claude-opus-4-8")
        #expect(backing.writes == ["claude-opus-4-8"])

        // A fresh store over the same backing reloads the persisted value —
        // the cross-instance persistence a real app relaunch relies on.
        let reloaded = CopilotModelStore(backing: backing)
        #expect(reloaded.configuredModel == "claude-opus-4-8")
        #expect(reloaded.effectiveModel == "claude-opus-4-8")
    }

    @Test("commit rejects an uncurated / unknown id and changes nothing")
    func storeCommitRejectsUnknown() {
        let backing = SpyBacking()
        let store = CopilotModelStore(backing: backing)
        #expect(store.commit("claude-opus-4-8") == "claude-opus-4-8")

        #expect(store.commit("claude-nonexistent-9") == nil)
        // A lookup-only (non-curated) row is also rejected — not offered by the picker.
        #expect(store.commit("claude-opus-4-6") == nil)
        #expect(store.commit("") == nil)
        #expect(store.configuredModel == "claude-opus-4-8")   // unchanged
        #expect(backing.writes == ["claude-opus-4-8"])         // no extra writes
    }

    @Test("an absent / corrupt persisted entry flows to the default (backing returns nil)")
    func storeCorruptLoadIsDefault() {
        let store = CopilotModelStore(backing: InMemoryCopilotModelBacking(nil))
        #expect(store.configuredModel == nil)
        #expect(store.effectiveModel == "claude-sonnet-5")
    }

    @Test("a persisted id that's no longer curated is treated as no setting on load")
    func storeUncuratedPersistedValueIsDefaultOnLoad() {
        let store = CopilotModelStore(backing: InMemoryCopilotModelBacking("claude-ancient-relic"))
        #expect(store.configuredModel == nil)
        #expect(store.effectiveModel == "claude-sonnet-5")
    }

    @Test("the UserDefaults backing reads a real string, and ignores a wrong-type entry")
    func userDefaultsBackingTypeSafety() {
        let suiteName = "copilot.model.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backing = UserDefaultsCopilotModelBacking(defaults: defaults, key: "copilot.model")

        #expect(backing.loadModel() == nil)   // never set
        backing.storeModel("claude-fable-5")
        #expect(backing.loadModel() == "claude-fable-5")   // round-trips a string

        // A wrong-type (corrupt) entry reads as nil so the default flows.
        defaults.set(42, forKey: "copilot.model")
        #expect(backing.loadModel() == nil)
    }

    /// A spy backing that records writes, so the suite can prove commit
    /// persists only valid input (and only through the backing).
    @MainActor
    final class SpyBacking: CopilotModelBacking {
        private(set) var writes: [String] = []
        private var storage: String?

        init(_ initial: String? = nil) { self.storage = initial }

        func loadModel() -> String? { storage }
        func storeModel(_ modelID: String) {
            writes.append(modelID)
            storage = modelID
        }
    }
}
