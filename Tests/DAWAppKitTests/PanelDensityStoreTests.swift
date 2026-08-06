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

        /// Every panel the store asked to REMOVE (m23-ej-1). Recorded separately
        /// from `writes` so a test can prove a clear reached the persistence
        /// seam at all — a clear that only evicted the store's cache would look
        /// identical in this session and come back after a relaunch.
        private(set) var removals: [String] = []

        init(_ initial: [String: PanelDensity] = [:]) { self.storage = initial }

        func loadDensity(forPanel panelID: String) -> PanelDensity? {
            reads.append(panelID)
            return storage[panelID]
        }
        func storeDensity(_ density: PanelDensity, forPanel panelID: String) {
            writes.append((panelID, density))
            storage[panelID] = density
        }
        /// Implemented HERE, not inherited from a protocol default, so the
        /// m23-du enumeration is exercised THROUGH THE SEAM and not only on the
        /// concrete backings. Nothing is defaulted into `storage`, so it already
        /// is the explicit set.
        func storedDensities() -> [String: PanelDensity] { storage }
        /// Drops the key — the panel becomes never-set, NOT explicitly `.simple`.
        func removeDensity(forPanel panelID: String) {
            removals.append(panelID)
            storage.removeValue(forKey: panelID)
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

    // MARK: - Stored vs effective (m23-du(a))

    /// THE discriminating test for m23-du(a). `density(forPanel:)` answers
    /// "what is the UI showing" and folds "never set" into "Simple"; a gate that
    /// restores from THAT converts an unset key into an explicit one, silently
    /// changing what a fresh machine looks like. `storedDensity(forPanel:)` must
    /// keep the two apart.
    @Test("an unset panel reads stored == nil while the effective density is still Simple")
    func unsetPanelHasNilStored() {
        let store = PanelDensityStore(backing: SpyBacking())
        #expect(store.storedDensity(forPanel: "quantize") == nil)   // never set
        #expect(store.density(forPanel: "quantize") == .simple)     // …but the UI still shows Simple
        #expect(store.storedDensities().isEmpty)
    }

    @Test("a set makes stored non-nil — including an explicit Simple, which unset is NOT")
    func setMakesStoredNonNil() {
        let store = PanelDensityStore(backing: SpyBacking())
        store.setDensity(.pro, forPanel: "mixer")
        #expect(store.storedDensity(forPanel: "mixer") == .pro)

        // The pair the fallback hides: both READ `.simple` effectively, only one
        // is stored. If this ever collapses, the restore bug is back.
        store.setDensity(.simple, forPanel: "mixer")
        #expect(store.density(forPanel: "mixer") == .simple)
        #expect(store.storedDensity(forPanel: "mixer") == .simple)   // explicitly Simple
        #expect(store.density(forPanel: "pianoRoll") == .simple)
        #expect(store.storedDensity(forPanel: "pianoRoll") == nil)   // never-set Simple
    }

    /// Proves `stored` reads THROUGH to persistence rather than merely
    /// reflecting this session's cache — the relaunch analogue of
    /// `readsFromBacking`, with no in-session set at all.
    @Test("stored reads through to the backing on a fresh store (no in-session set)")
    func storedReadsThroughToBacking() {
        let backing = SpyBacking(["pianoRoll": .pro])
        let store = PanelDensityStore(backing: backing)
        #expect(store.storedDensity(forPanel: "pianoRoll") == .pro)
        #expect(store.storedDensity(forPanel: "mixer") == nil)
        #expect(store.storedDensities() == ["pianoRoll": .pro])
    }

    /// A read that writes is not a read. `density(forPanel:)` is documented as
    /// never mutating state; the new reads must hold the same line, or a gate
    /// that merely LOOKS at the density leaks one.
    @Test("the stored reads never write through the backing")
    func storedReadsDoNotMutate() {
        let backing = SpyBacking(["mixer": .pro])
        let store = PanelDensityStore(backing: backing)
        _ = store.storedDensity(forPanel: "mixer")
        _ = store.storedDensity(forPanel: "neverTouched")
        _ = store.storedDensities()
        _ = store.density(forPanel: "neverTouched")
        #expect(backing.writes.isEmpty)
        #expect(backing.storage["neverTouched"] == nil)   // no key conjured by reading
    }

    @Test("storedDensities lists only explicitly set panels, never a default")
    func storedDensitiesListsOnlyExplicit() {
        let store = PanelDensityStore(backing: SpyBacking())
        #expect(store.storedDensities() == [:])
        store.setDensity(.pro, forPanel: "mixer")
        store.setDensity(.simple, forPanel: "pianoRoll")
        #expect(store.storedDensities() == ["mixer": .pro, "pianoRoll": .simple])
        // Reading a third panel must not enrol it.
        _ = store.density(forPanel: "arrange")
        #expect(store.storedDensities() == ["mixer": .pro, "pianoRoll": .simple])
    }

    // MARK: - Clear / restore-to-unset (m23-ej-1)

    /// THE discriminating assertion for m23-ej-1, and the reason every test here
    /// checks `storedDensity` rather than `density`: after a clear the effective
    /// density reads `.simple` — but it reads `.simple` after an explicit
    /// `setDensity(.simple)` too. Only `stored == nil` separates "returned to
    /// unset" from "wrote the default back", which is the whole point of the
    /// verb. The `storedDensities()` and backing-storage assertions add the
    /// other two paths a value could survive on.
    @Test("clear returns a panel to unset — stored nil, effective density still Simple")
    func clearMakesStoredNil() {
        let backing = SpyBacking(["mixer": .pro])          // a persisted prior, no in-session set
        let store = PanelDensityStore(backing: backing)
        #expect(store.storedDensity(forPanel: "mixer") == .pro)

        store.clearDensity(forPanel: "mixer")

        #expect(store.storedDensity(forPanel: "mixer") == nil)   // genuinely unset…
        #expect(store.density(forPanel: "mixer") == .simple)     // …and the UI falls back
        #expect(store.storedDensities()["mixer"] == nil)         // absent from the enumeration
        #expect(store.storedDensities().isEmpty)
        #expect(backing.storage["mixer"] == nil)                 // it reached PERSISTENCE…
        #expect(backing.removals == ["mixer"])                   // …through removeDensity
    }

    /// Clear must not be confusable with writing the default. Same panel, both
    /// paths, same effective density, different stored — if this pair ever
    /// collapses the clear verb has stopped meaning anything.
    @Test("clear is NOT the same as writing Simple — identical mode, different stored")
    func clearIsNotAnExplicitSimple() {
        let store = PanelDensityStore(backing: SpyBacking())
        store.setDensity(.simple, forPanel: "quantize")
        #expect(store.density(forPanel: "quantize") == .simple)
        #expect(store.storedDensity(forPanel: "quantize") == .simple)   // explicit
        #expect(store.storedDensities() == ["quantize": .simple])

        store.clearDensity(forPanel: "quantize")
        #expect(store.density(forPanel: "quantize") == .simple)         // unchanged reading…
        #expect(store.storedDensity(forPanel: "quantize") == nil)       // …opposite state
        #expect(store.storedDensities().isEmpty)
    }

    /// THE CACHE-EVICTION TEST — this is the one that reddens if
    /// `clearDensity` removes from the backing but leaves `densities[panelID]`
    /// behind. `density(forPanel:)` and `storedDensity(forPanel:)` consult the
    /// cache FIRST and `storedDensities()` merges it OVER the backing, so a
    /// missed eviction resurrects the value on all three paths for the rest of
    /// the session while the backing looks correctly empty.
    @Test("clear survives an in-session setDensity — the cache is evicted, not just the backing")
    func clearEvictsSessionCache() {
        let backing = SpyBacking()
        let store = PanelDensityStore(backing: backing)
        store.setDensity(.pro, forPanel: "pianoRoll")     // populates BOTH cache and backing
        #expect(store.storedDensity(forPanel: "pianoRoll") == .pro)
        #expect(store.storedDensities() == ["pianoRoll": .pro])

        store.clearDensity(forPanel: "pianoRoll")

        // Path 1: the single-panel stored read (cache consulted first).
        #expect(store.storedDensity(forPanel: "pianoRoll") == nil)
        // Path 2: the enumeration (cache merged OVER the backing).
        #expect(store.storedDensities()["pianoRoll"] == nil)
        #expect(store.storedDensities().isEmpty)
        // Path 3: the effective read (cache consulted first) falls back.
        #expect(store.density(forPanel: "pianoRoll") == .simple)
        // And it went through the seam, so a relaunch agrees with this session.
        #expect(backing.storage["pianoRoll"] == nil)
        #expect(backing.removals == ["pianoRoll"])
    }

    /// A restore helper runs `clear` whenever the prior was null, which is most
    /// of the time — it must not have to check first.
    @Test("clearing a never-set panel is a no-op, not an error")
    func clearUnsetPanelIsNoOp() {
        let backing = SpyBacking(["mixer": .pro])
        let store = PanelDensityStore(backing: backing)

        store.clearDensity(forPanel: "neverTouched")

        #expect(store.storedDensity(forPanel: "neverTouched") == nil)
        #expect(store.density(forPanel: "neverTouched") == .simple)
        #expect(store.storedDensities() == ["mixer": .pro])   // nothing else disturbed
        #expect(backing.writes.isEmpty)                       // no key conjured by clearing
        // The seam is called UNCONDITIONALLY (documented choice): a backing that
        // persists outside this store's knowledge still gets the message, and
        // removing a missing key is harmless.
        #expect(backing.removals == ["neverTouched"])

        // Idempotent — a second clear is equally uneventful.
        store.clearDensity(forPanel: "neverTouched")
        #expect(store.storedDensity(forPanel: "neverTouched") == nil)
        #expect(store.storedDensities() == ["mixer": .pro])
    }

    @Test("clear is per-panel — clearing one leaves the others exactly as they were")
    func clearIsPerPanel() {
        let backing = SpyBacking(["arrange": .pro])
        let store = PanelDensityStore(backing: backing)
        store.setDensity(.pro, forPanel: "mixer")
        store.setDensity(.simple, forPanel: "pianoRoll")

        store.clearDensity(forPanel: "mixer")

        #expect(store.storedDensity(forPanel: "mixer") == nil)
        #expect(store.storedDensity(forPanel: "pianoRoll") == .simple)  // in-session, untouched
        #expect(store.storedDensity(forPanel: "arrange") == .pro)       // persisted, untouched
        #expect(store.storedDensities() == ["pianoRoll": .simple, "arrange": .pro])
        #expect(store.density(forPanel: "arrange") == .pro)
        #expect(backing.removals == ["mixer"])
    }

    /// Clear is not a one-way door: the panel is settable again afterwards, and
    /// the re-set is a normal explicit write (stored non-nil again).
    @Test("a cleared panel can be set again")
    func clearThenSetAgain() {
        let backing = SpyBacking()
        let store = PanelDensityStore(backing: backing)
        store.setDensity(.pro, forPanel: "transport")
        store.clearDensity(forPanel: "transport")
        #expect(store.storedDensity(forPanel: "transport") == nil)

        store.setDensity(.pro, forPanel: "transport")
        #expect(store.storedDensity(forPanel: "transport") == .pro)
        #expect(store.density(forPanel: "transport") == .pro)
        #expect(backing.storage["transport"] == .pro)
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

    @Test("both backings enumerate exactly the panels that were explicitly stored")
    func backingsEnumerateStored() {
        let mem = InMemoryPanelDensityBacking()
        #expect(mem.storedDensities() == [:])
        mem.storeDensity(.pro, forPanel: "mixer")
        _ = mem.loadDensity(forPanel: "pianoRoll")           // a read must not enrol
        #expect(mem.storedDensities() == ["mixer": .pro])

        let suite = "PanelDensityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ud = UserDefaultsPanelDensityBacking(defaults: defaults)
        #expect(ud.storedDensities() == [:])

        ud.storeDensity(.pro, forPanel: "mixer")
        ud.storeDensity(.simple, forPanel: "pianoRoll")      // explicit Simple IS stored
        // Three keys that must all be filtered OUT, planted directly so the
        // enumeration is proven against a hostile domain and not just its own
        // writes: an unparseable value, an empty panel ID, and a foreign key.
        defaults.set("loud", forKey: "panelDensity.corrupt")
        defaults.set("pro", forKey: "panelDensity.")
        defaults.set("pro", forKey: "somethingElse")
        #expect(ud.storedDensities() == ["mixer": .pro, "pianoRoll": .simple])

        // A custom prefix enumerates its own namespace only.
        let scoped = UserDefaultsPanelDensityBacking(defaults: defaults, keyPrefix: "otherNS.")
        #expect(scoped.storedDensities() == [:])
        scoped.storeDensity(.pro, forPanel: "mixer")
        #expect(scoped.storedDensities() == ["mixer": .pro])
        #expect(ud.storedDensities() == ["mixer": .pro, "pianoRoll": .simple])  // untouched
    }

    /// Both concrete backings must behave IDENTICALLY through the removal seam
    /// (m23-ej-1) — the store is written against the protocol, so a backing that
    /// merely wrote `.simple` back, or removed under a different key scheme,
    /// would leave the store's clear correct in tests and wrong in the app.
    @Test("both backings remove a key rather than defaulting it, under the same key scheme")
    func backingsRemoveStored() {
        let mem = InMemoryPanelDensityBacking(["mixer": .pro, "pianoRoll": .simple])
        mem.removeDensity(forPanel: "mixer")
        #expect(mem.loadDensity(forPanel: "mixer") == nil)               // gone, not `.simple`
        #expect(mem.storedDensities() == ["pianoRoll": .simple])         // neighbour untouched
        mem.removeDensity(forPanel: "neverStored")                       // no-op, no error
        #expect(mem.storedDensities() == ["pianoRoll": .simple])

        let suite = "PanelDensityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ud = UserDefaultsPanelDensityBacking(defaults: defaults)
        ud.storeDensity(.pro, forPanel: "mixer")
        ud.storeDensity(.simple, forPanel: "pianoRoll")

        ud.removeDensity(forPanel: "mixer")
        #expect(ud.loadDensity(forPanel: "mixer") == nil)
        // The KEY itself is gone from the domain — not present holding some
        // other value, which `loadDensity` alone could not tell apart.
        #expect(defaults.object(forKey: "panelDensity.mixer") == nil)
        #expect(ud.storedDensities() == ["pianoRoll": .simple])
        ud.removeDensity(forPanel: "neverStored")                        // no-op, no error
        #expect(ud.storedDensities() == ["pianoRoll": .simple])

        // Removal honours the SAME `keyPrefix` scheme `storeDensity` writes
        // with: a scoped backing clears its own namespace and nobody else's.
        let scoped = UserDefaultsPanelDensityBacking(defaults: defaults, keyPrefix: "otherNS.")
        scoped.storeDensity(.pro, forPanel: "pianoRoll")
        scoped.removeDensity(forPanel: "pianoRoll")
        #expect(scoped.storedDensities() == [:])
        #expect(ud.storedDensities() == ["pianoRoll": .simple])          // untouched
    }

    /// The same clear, driven through the STORE over each concrete backing —
    /// the app wires `UserDefaultsPanelDensityBacking`, and only this leg proves
    /// the store's eviction plus that backing's `removeObject` agree end to end.
    @Test("clear through the store behaves identically on both concrete backings")
    func clearThroughStoreOnBothBackings() {
        let memStore = PanelDensityStore(backing: InMemoryPanelDensityBacking(["mixer": .pro]))
        memStore.setDensity(.pro, forPanel: "pianoRoll")     // one cached, one backing-only
        memStore.clearDensity(forPanel: "pianoRoll")
        memStore.clearDensity(forPanel: "mixer")
        #expect(memStore.storedDensity(forPanel: "pianoRoll") == nil)
        #expect(memStore.storedDensity(forPanel: "mixer") == nil)
        #expect(memStore.storedDensities().isEmpty)
        #expect(memStore.density(forPanel: "mixer") == .simple)

        let suite = "PanelDensityStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let backing = UserDefaultsPanelDensityBacking(defaults: defaults)
        backing.storeDensity(.pro, forPanel: "mixer")
        let udStore = PanelDensityStore(backing: backing)
        udStore.setDensity(.pro, forPanel: "pianoRoll")
        udStore.clearDensity(forPanel: "pianoRoll")
        udStore.clearDensity(forPanel: "mixer")
        #expect(udStore.storedDensity(forPanel: "pianoRoll") == nil)
        #expect(udStore.storedDensity(forPanel: "mixer") == nil)
        #expect(udStore.storedDensities().isEmpty)
        #expect(udStore.density(forPanel: "mixer") == .simple)
        // …and a FRESH store over the same defaults agrees, which is the
        // relaunch case a cache-only clear would silently fail.
        let relaunched = PanelDensityStore(
            backing: UserDefaultsPanelDensityBacking(defaults: defaults))
        #expect(relaunched.storedDensity(forPanel: "mixer") == nil)
        #expect(relaunched.storedDensities().isEmpty)
    }
}
