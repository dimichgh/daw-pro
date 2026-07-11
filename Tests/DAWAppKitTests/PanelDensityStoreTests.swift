import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `PanelDensityStore` (M8 sp-a): the per-panel Simple/Pro
/// density model that every panel binds to. Driven against an injected spy
/// backing so the suite is hermetic (no UserDefaults, no relaunch) while proving
/// the same write-through the app's UserDefaults backing relies on. The
/// `debug.panelDensity` command's mode parsing (`PanelDensity(rawValue:)`) is
/// covered here too, since its handler lives in the un-testable DAWApp executable
/// target (see the report note).
@MainActor
@Suite("PanelDensityStore — Simple/Pro (M8 sp-a)")
struct PanelDensityStoreTests {

    /// A spy backing that records every read/write, so the suite can assert the
    /// store persists through it (and only through it).
    final class SpyBacking: PanelDensityBacking {
        private(set) var storage: [String: PanelDensity]
        private(set) var writes: [(panel: String, mode: PanelDensity)] = []
        private(set) var reads: [String] = []

        init(_ initial: [String: PanelDensity] = [:]) { self.storage = initial }

        func loadDensity(forPanel panelID: String) -> PanelDensity? {
            reads.append(panelID)
            return storage[panelID]
        }
        func storeDensity(_ density: PanelDensity, forPanel panelID: String) {
            writes.append((panelID, density))
            storage[panelID] = density
        }
    }

    // MARK: - Default

    @Test("a never-set panel defaults to Simple")
    func defaultIsSimple() {
        let store = PanelDensityStore(backing: SpyBacking())
        #expect(store.density(forPanel: "pianoRoll") == .simple)
        #expect(PanelDensity.simple == PanelDensity.allCases.first)  // Simple leads the chip order
    }

    @Test("a store with no injected backing still defaults to Simple")
    func defaultBackingIsSimple() {
        let store = PanelDensityStore()
        #expect(store.density(forPanel: "mixer") == .simple)
    }

    // MARK: - Round-trip

    @Test("set then get round-trips within a session")
    func setGetRoundTrip() {
        let store = PanelDensityStore(backing: SpyBacking())
        store.setDensity(.pro, forPanel: "pianoRoll")
        #expect(store.density(forPanel: "pianoRoll") == .pro)
        store.setDensity(.simple, forPanel: "pianoRoll")
        #expect(store.density(forPanel: "pianoRoll") == .simple)
    }

    @Test("toggle flips Simple↔Pro")
    func toggleFlips() {
        let store = PanelDensityStore(backing: SpyBacking())
        #expect(store.density(forPanel: "arrange") == .simple)
        store.toggle(forPanel: "arrange")
        #expect(store.density(forPanel: "arrange") == .pro)
        store.toggle(forPanel: "arrange")
        #expect(store.density(forPanel: "arrange") == .simple)
    }

    // MARK: - Persistence write-through

    @Test("every set writes through to the injected backing")
    func writeThrough() {
        let backing = SpyBacking()
        let store = PanelDensityStore(backing: backing)
        store.setDensity(.pro, forPanel: "pianoRoll")
        #expect(backing.writes.count == 1)
        #expect(backing.writes.last?.panel == "pianoRoll")
        #expect(backing.writes.last?.mode == .pro)
        #expect(backing.storage["pianoRoll"] == .pro)
    }

    @Test("a store reads its initial value from the backing (sticky across a reopen)")
    func readsFromBacking() {
        // Simulate a relaunch: a fresh store over a backing that already holds Pro.
        let backing = SpyBacking(["pianoRoll": .pro])
        let store = PanelDensityStore(backing: backing)
        #expect(store.density(forPanel: "pianoRoll") == .pro)     // persisted preference wins
        #expect(store.density(forPanel: "mixer") == .simple)      // untouched panel still defaults
    }

    // MARK: - Per-panel independence

    @Test("panels are independent — a Pro piano roll leaves the mixer Simple")
    func perPanelIndependence() {
        let store = PanelDensityStore(backing: SpyBacking())
        store.setDensity(.pro, forPanel: "pianoRoll")
        #expect(store.density(forPanel: "pianoRoll") == .pro)
        #expect(store.density(forPanel: "mixer") == .simple)
        store.setDensity(.pro, forPanel: "mixer")
        store.setDensity(.simple, forPanel: "pianoRoll")
        #expect(store.density(forPanel: "pianoRoll") == .simple)
        #expect(store.density(forPanel: "mixer") == .pro)
    }

    // MARK: - Mode parsing (the debug.panelDensity command's contract)

    @Test("PanelDensity round-trips its raw value; unknown raw is nil")
    func rawValueParsing() {
        #expect(PanelDensity(rawValue: "simple") == .simple)
        #expect(PanelDensity(rawValue: "pro") == .pro)
        #expect(PanelDensity(rawValue: "SIMPLE") == nil)   // case-sensitive wire value
        #expect(PanelDensity(rawValue: "bogus") == nil)
        #expect(PanelDensity.simple.rawValue == "simple")
        #expect(PanelDensity.pro.rawValue == "pro")
    }

    // MARK: - Backing conformances

    @Test("InMemory + UserDefaults backings both round-trip")
    func backingsRoundTrip() {
        let mem = InMemoryPanelDensityBacking()
        mem.storeDensity(.pro, forPanel: "x")
        #expect(mem.loadDensity(forPanel: "x") == .pro)
        #expect(mem.loadDensity(forPanel: "y") == nil)

        // A private suite name keeps the test off the real standard defaults.
        let suite = "PanelDensityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ud = UserDefaultsPanelDensityBacking(defaults: defaults)
        #expect(ud.loadDensity(forPanel: "pianoRoll") == nil)
        ud.storeDensity(.pro, forPanel: "pianoRoll")
        #expect(ud.loadDensity(forPanel: "pianoRoll") == .pro)
        #expect(defaults.string(forKey: "panelDensity.pianoRoll") == "pro")  // keyed panelDensity.<id>
    }
}
