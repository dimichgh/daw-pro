import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for `CopilotLimitsStore` (beta m10-m): the in-app Copilot
/// round-budget setting the Settings → Copilot field edits, persisted through an
/// injected backing. Pure/hermetic (in-memory + spy backings), so round-trip,
/// corrupt-load, and clamp-on-load are pinned without a running app — the
/// `ControlPortStore` idiom, with one deliberate divergence (out-of-range persisted
/// values CLAMP here rather than reading as "no setting").
@MainActor
@Suite("CopilotLimitsStore — round-budget setting (beta m10-m)")
struct CopilotLimitsStoreTests {

    @Test("a never-set store has no configured value and reports the default 30")
    func storeDefaults() {
        let store = CopilotLimitsStore(backing: InMemoryCopilotLimitsBacking())
        #expect(store.configuredMaxRounds == nil)
        #expect(store.maxRounds == CopilotLimits.defaultMaxRounds)
        #expect(store.maxRounds == 30)
    }

    @Test("commit persists a valid value and round-trips it through the backing")
    func storeCommitRoundTrip() {
        let backing = SpyBacking()
        let store = CopilotLimitsStore(backing: backing)

        #expect(store.commit("16") == 16)
        #expect(store.configuredMaxRounds == 16)
        #expect(store.maxRounds == 16)
        #expect(backing.writes == [16])

        // A fresh store over the same backing reloads the persisted value.
        let reloaded = CopilotLimitsStore(backing: backing)
        #expect(reloaded.configuredMaxRounds == 16)
        #expect(reloaded.maxRounds == 16)
    }

    @Test("commit rejects out-of-range / garbage input and changes nothing")
    func storeCommitRejects() {
        let backing = SpyBacking()
        let store = CopilotLimitsStore(backing: backing)
        #expect(store.commit("16") == 16)

        // The field REJECTS out-of-range (inline error), unlike the wire override.
        #expect(store.commit("0") == nil)     // below the floor
        #expect(store.commit("99") == nil)    // above the ceiling
        #expect(store.commit("nope") == nil)  // garbage
        #expect(store.commit("") == nil)      // empty
        #expect(store.configuredMaxRounds == 16)   // unchanged
        #expect(backing.writes == [16])            // no extra writes
    }

    @Test("an absent / corrupt persisted entry flows to the default (backing returns nil)")
    func storeCorruptLoadIsDefault() {
        // A backing that never had a value (or a corrupt one it chose to ignore)
        // returns nil → the store has no setting and the default 30 flows.
        let store = CopilotLimitsStore(backing: InMemoryCopilotLimitsBacking(nil))
        #expect(store.configuredMaxRounds == nil)
        #expect(store.maxRounds == 30)
    }

    @Test("an out-of-range persisted value is CLAMPED on load (not discarded)")
    func storeClampsOnLoad() {
        // 50 (from a build with a wider range, say) clamps to the ceiling — the
        // user's "a lot" intent is preserved rather than snapping back to 8. This is
        // the deliberate divergence from ControlPortStore.
        let high = CopilotLimitsStore(backing: InMemoryCopilotLimitsBacking(50))
        #expect(high.configuredMaxRounds == 32)
        #expect(high.maxRounds == 32)

        let low = CopilotLimitsStore(backing: InMemoryCopilotLimitsBacking(0))
        #expect(low.configuredMaxRounds == 1)
        #expect(low.maxRounds == 1)
    }

    @Test("the UserDefaults backing reads a real number, and ignores a wrong-type entry")
    func userDefaultsBackingTypeSafety() {
        let suiteName = "copilot.limits.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let backing = UserDefaultsCopilotLimitsBacking(defaults: defaults, key: "copilot.maxRounds")

        #expect(backing.loadMaxRounds() == nil)   // never set
        backing.storeMaxRounds(12)
        #expect(backing.loadMaxRounds() == 12)     // round-trips a number

        // A wrong-type (corrupt) entry reads as nil so the default flows, not a coerced 0.
        defaults.set("not-a-number", forKey: "copilot.maxRounds")
        #expect(backing.loadMaxRounds() == nil)
    }

    /// A spy backing that records writes, so the suite can prove commit persists only
    /// valid input (and only through the backing).
    @MainActor
    final class SpyBacking: CopilotLimitsBacking {
        private(set) var writes: [Int] = []
        private var storage: Int?

        init(_ initial: Int? = nil) { self.storage = initial }

        func loadMaxRounds() -> Int? { storage }
        func storeMaxRounds(_ rounds: Int) {
            writes.append(rounds)
            storage = rounds
        }
    }
}
