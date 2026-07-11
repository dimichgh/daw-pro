import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `PanelLayoutStore` (beta m10-d): the adjustable window
/// layout the arrange splitters drive — sidebar width, bottom-editor height
/// fraction, and the GLOBAL track-row height. Driven against an injected spy
/// backing so the suite is hermetic (no UserDefaults, no relaunch) while proving
/// the same write-through + clamping the app's UserDefaults backing relies on.
/// Clamping lives in the STORE (a raw drag delta is tamed to the range), so these
/// tests pin the contract the `debug.panelLayout` command and the drag gestures
/// depend on.
@MainActor
@Suite("PanelLayoutStore — adjustable layout (beta m10-d)")
struct PanelLayoutStoreTests {

    /// A spy backing that records every read/write, so the suite can assert the
    /// store persists through it (and only through it).
    final class SpyBacking: PanelLayoutBacking {
        private(set) var storage: [String: Double]
        private(set) var writes: [(key: String, value: Double)] = []
        private(set) var reads: [String] = []

        init(_ initial: [String: Double] = [:]) { self.storage = initial }

        func loadValue(forKey key: String) -> Double? {
            reads.append(key)
            return storage[key]
        }
        func storeValue(_ value: Double, forKey key: String) {
            writes.append((key, value))
            storage[key] = value
        }
    }

    // MARK: - Defaults

    @Test("a never-set store returns the historical defaults (260 / 0.45 / 34)")
    func defaults() {
        let store = PanelLayoutStore(backing: SpyBacking())
        #expect(store.sidebarWidth == 260)
        #expect(store.editorFraction == 0.45)
        #expect(store.rowHeight == 34)
    }

    @Test("a store with no injected backing still returns the defaults")
    func defaultBacking() {
        let store = PanelLayoutStore()
        #expect(store.sidebarWidth == PanelLayoutStore.defaultSidebarWidth)
        #expect(store.editorFraction == PanelLayoutStore.defaultEditorFraction)
        #expect(store.rowHeight == PanelLayoutStore.defaultRowHeight)
    }

    // MARK: - Round-trip within a session

    @Test("set then read round-trips within a session")
    func setGetRoundTrip() {
        let store = PanelLayoutStore(backing: SpyBacking())
        store.setSidebarWidth(300)
        store.setEditorFraction(0.5)
        store.setRowHeight(48)
        #expect(store.sidebarWidth == 300)
        #expect(store.editorFraction == 0.5)
        #expect(store.rowHeight == 48)
    }

    // MARK: - Clamping (lives in the store)

    @Test("sidebar width clamps to 250–420")
    func sidebarClamps() {
        let store = PanelLayoutStore(backing: SpyBacking())
        store.setSidebarWidth(9999)
        #expect(store.sidebarWidth == 420)     // above max → max
        store.setSidebarWidth(10)
        #expect(store.sidebarWidth == 250)     // below min → min
        store.setSidebarWidth(300)
        #expect(store.sidebarWidth == 300)     // in range → exact
        // The historical default (260) sits inside the tightened range.
        #expect(PanelLayoutStore.sidebarWidthRange.contains(PanelLayoutStore.defaultSidebarWidth))
    }

    @Test("editor fraction clamps to 0.30–0.55")
    func editorClamps() {
        let store = PanelLayoutStore(backing: SpyBacking())
        store.setEditorFraction(1.0)
        #expect(store.editorFraction == 0.55)
        store.setEditorFraction(0.0)
        #expect(store.editorFraction == 0.30)
        store.setEditorFraction(0.5)
        #expect(store.editorFraction == 0.5)
        // The historical default (0.45) sits inside the tightened range.
        #expect(PanelLayoutStore.editorFractionRange.contains(PanelLayoutStore.defaultEditorFraction))
    }

    @Test("row height clamps to 24–64")
    func rowClamps() {
        let store = PanelLayoutStore(backing: SpyBacking())
        store.setRowHeight(1000)
        #expect(store.rowHeight == 64)
        store.setRowHeight(1)
        #expect(store.rowHeight == 24)
        store.setRowHeight(40)
        #expect(store.rowHeight == 40)
    }

    @Test("a stored OUT-OF-RANGE value is re-clamped on load")
    func loadReClamps() {
        // Simulate a corrupt / stale defaults value beyond the range.
        let backing = SpyBacking([
            PanelLayoutStore.sidebarWidthKey: 5000,
            PanelLayoutStore.editorFractionKey: -1,
            PanelLayoutStore.rowHeightKey: 999,
        ])
        let store = PanelLayoutStore(backing: backing)
        #expect(store.sidebarWidth == 420)
        #expect(store.editorFraction == 0.30)
        #expect(store.rowHeight == 64)
    }

    // MARK: - Persistence write-through

    @Test("every set writes the CLAMPED value through to the backing under its key")
    func writeThrough() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        store.setSidebarWidth(9999)     // clamps to 420
        store.setEditorFraction(0.5)
        store.setRowHeight(48)
        #expect(backing.storage[PanelLayoutStore.sidebarWidthKey] == 420)
        #expect(backing.storage[PanelLayoutStore.editorFractionKey] == 0.5)
        #expect(backing.storage[PanelLayoutStore.rowHeightKey] == 48)
        // The persisted numbers are the post-clamp values, never the raw input.
        #expect(backing.writes.contains { $0.key == PanelLayoutStore.sidebarWidthKey && $0.value == 420 })
    }

    @Test("a fresh store reads its initial values from the backing (sticky across a reopen)")
    func readsFromBacking() {
        // Simulate a relaunch: a fresh store over a backing that already holds values.
        let backing = SpyBacking([
            PanelLayoutStore.sidebarWidthKey: 320,
            PanelLayoutStore.rowHeightKey: 50,
        ])
        let store = PanelLayoutStore(backing: backing)
        #expect(store.sidebarWidth == 320)                              // persisted wins
        #expect(store.rowHeight == 50)                                  // persisted wins
        #expect(store.editorFraction == PanelLayoutStore.defaultEditorFraction)  // untouched → default
    }

    // MARK: - Reset

    @Test("reset restores every dimension to its default and persists the reset")
    func reset() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        store.setSidebarWidth(400)
        store.setEditorFraction(0.6)
        store.setRowHeight(60)

        store.reset()
        #expect(store.sidebarWidth == 260)
        #expect(store.editorFraction == 0.45)
        #expect(store.rowHeight == 34)
        // The reset is written through, so a relaunch sees the defaults too.
        #expect(backing.storage[PanelLayoutStore.sidebarWidthKey] == 260)
        #expect(backing.storage[PanelLayoutStore.editorFractionKey] == 0.45)
        #expect(backing.storage[PanelLayoutStore.rowHeightKey] == 34)
    }

    // MARK: - Backing conformances

    @Test("InMemory + UserDefaults backings both round-trip, keyed panelLayout.<dimension>")
    func backingsRoundTrip() {
        let mem = InMemoryPanelLayoutBacking()
        #expect(mem.loadValue(forKey: "x") == nil)     // never set → nil, not 0
        mem.storeValue(300, forKey: "x")
        #expect(mem.loadValue(forKey: "x") == 300)

        // A private suite name keeps the test off the real standard defaults.
        let suite = "PanelLayoutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ud = UserDefaultsPanelLayoutBacking(defaults: defaults)
        #expect(ud.loadValue(forKey: PanelLayoutStore.sidebarWidthKey) == nil)   // unset → nil
        ud.storeValue(300, forKey: PanelLayoutStore.sidebarWidthKey)
        #expect(ud.loadValue(forKey: PanelLayoutStore.sidebarWidthKey) == 300)
        // The final UserDefaults key is prefixed panelLayout.<dimension>.
        #expect(defaults.double(forKey: "panelLayout.sidebarWidth") == 300)
    }

    @Test("a stored 0 is distinguishable from unset in the UserDefaults backing")
    func zeroVsUnset() {
        let suite = "PanelLayoutStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let ud = UserDefaultsPanelLayoutBacking(defaults: defaults)
        #expect(ud.loadValue(forKey: PanelLayoutStore.rowHeightKey) == nil)  // unset
        ud.storeValue(0, forKey: PanelLayoutStore.rowHeightKey)
        #expect(ud.loadValue(forKey: PanelLayoutStore.rowHeightKey) == 0)    // stored 0, not nil
    }
}
