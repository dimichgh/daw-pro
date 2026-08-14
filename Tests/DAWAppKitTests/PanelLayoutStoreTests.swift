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

    @Test("arrange zoom (m17-b) defaults to 16 pt/beat, clamps to 4–200, and persists")
    func arrangePPB() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        #expect(store.arrangePPB == 16)                       // the historical fixed scale
        store.setArrangePPB(9999)
        #expect(store.arrangePPB == 200)
        store.setArrangePPB(0)
        #expect(store.arrangePPB == 4)
        store.setArrangePPB(32)
        #expect(store.arrangePPB == 32)
        #expect(backing.storage[PanelLayoutStore.arrangePPBKey] == 32)   // write-through
        // Sticky across a "relaunch": a fresh store over the same backing.
        #expect(PanelLayoutStore(backing: backing).arrangePPB == 32)
        // Reset restores + persists the default (like every dimension).
        store.reset()
        #expect(store.arrangePPB == 16)
        #expect(backing.storage[PanelLayoutStore.arrangePPBKey] == 16)
    }

    @Test("piano-roll zoom (m21-c) defaults to 32 pt/beat, clamps to 4–200, and persists")
    func pianoRollPPB() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        #expect(store.pianoRollPPB == 32)                     // the historical fixed scale
        store.setPianoRollPPB(9999)
        #expect(store.pianoRollPPB == 200)
        store.setPianoRollPPB(0)
        #expect(store.pianoRollPPB == 4)
        store.setPianoRollPPB(64)
        #expect(store.pianoRollPPB == 64)
        #expect(backing.storage[PanelLayoutStore.pianoRollPPBKey] == 64)   // write-through
        // Independent of the arrange slot — zooming the roll never moves the timeline.
        #expect(store.arrangePPB == PanelLayoutStore.defaultArrangePPB)
        // Sticky across a "relaunch": a fresh store over the same backing.
        #expect(PanelLayoutStore(backing: backing).pianoRollPPB == 64)
        // A corrupt stored value is re-clamped on load (the every-dimension rule).
        #expect(PanelLayoutStore(backing: SpyBacking([PanelLayoutStore.pianoRollPPBKey: 100_000]))
            .pianoRollPPB == 200)
        // Reset restores + persists the default (like every dimension).
        store.reset()
        #expect(store.pianoRollPPB == 32)
        #expect(backing.storage[PanelLayoutStore.pianoRollPPBKey] == 32)
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

        store.setMixerInsertsCollapsed(true)
        store.setFollowPlayhead(true)
        store.setWaveformNormalize(false)
        store.setWaveformVerticalZoom(4)
        store.setEditorMaximized(true)

        store.reset()
        #expect(store.sidebarWidth == 260)
        #expect(store.editorFraction == 0.45)
        #expect(store.rowHeight == 34)
        // m23-a: the mixer disclosure is a dimension too — reset must not leave it
        // behind (a half-reset is the bug this line exists to catch).
        #expect(store.mixerInsertsCollapsed == false)
        // m23-c2: follow is a dimension too — same half-reset guard.
        #expect(store.followPlayhead == false)
        // The reset is written through, so a relaunch sees the defaults too.
        #expect(backing.storage[PanelLayoutStore.sidebarWidthKey] == 260)
        #expect(backing.storage[PanelLayoutStore.editorFractionKey] == 0.45)
        #expect(backing.storage[PanelLayoutStore.rowHeightKey] == 34)
        #expect(backing.storage[PanelLayoutStore.mixerInsertsCollapsedKey] == 0)
        #expect(backing.storage[PanelLayoutStore.followPlayheadKey] == 0)
        // m25-e: the waveform's two slots are dimensions too — same half-reset
        // guard. BOTH halves come back, which is what ⌥⌘0 promises: a reset that
        // left RAW latched would be one the user could not see the effect of.
        #expect(store.waveformNormalize == true)
        #expect(store.waveformVerticalZoom == 1)
        #expect(backing.storage[PanelLayoutStore.waveformNormalizeKey] == 1)
        #expect(backing.storage[PanelLayoutStore.waveformVerticalZoomKey] == 1)
        // m25-b-1: the maximized MODE is a dimension too — same half-reset guard.
        // A reset that left the editor maximized would hand the user a window with
        // the arrange collapsed to a ruler strip and no memory of asking for it.
        #expect(store.editorMaximized == false)
        #expect(backing.storage[PanelLayoutStore.editorMaximizedKey] == 0)
    }

    // MARK: - Maximized editor (m25-b-1)

    @Test("the maximized mode defaults OFF, round-trips, persists as 1/0, and is sticky")
    func editorMaximized() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        // Default OFF — the `followPlayhead` rationale: a mode that collapses the
        // arrange must be asked for, never inherited.
        #expect(store.editorMaximized == false)
        #expect(PanelLayoutStore.defaultEditorMaximized == false)

        store.setEditorMaximized(true)
        #expect(store.editorMaximized == true)
        // The shared Double backing's 1/0 encoding, like every other Bool slot.
        #expect(backing.storage[PanelLayoutStore.editorMaximizedKey] == 1)

        store.setEditorMaximized(false)
        #expect(store.editorMaximized == false)
        #expect(backing.storage[PanelLayoutStore.editorMaximizedKey] == 0)

        // Sticky: a fresh store over the same backing reads the mode back.
        store.setEditorMaximized(true)
        let reopened = PanelLayoutStore(backing: backing)
        #expect(reopened.editorMaximized == true)
    }

    /// ⭐⭐ THE RESTORE CONTRACT, PINNED WHERE IT LIVES: maximizing must not
    /// disturb `editorFraction`, because leaving the mode is nothing more than
    /// dropping the override — there is no stash to put back. If a future change
    /// ever "helpfully" writes the maximized fraction into the slot, the value
    /// would be clamped to 0.55 on the way in and the user's own height would be
    /// gone. That is the whole reason this item ships no `previousFraction` slot,
    /// so it is a test and not a comment.
    @Test("maximizing NEVER writes editorFraction — the restore is the untouched slot")
    func maximizeLeavesFractionAlone() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        store.setEditorFraction(0.38)          // the user's dragged height
        #expect(store.editorFraction == 0.38)

        store.setEditorMaximized(true)
        #expect(store.editorFraction == 0.38)  // untouched while maximized
        #expect(backing.storage[PanelLayoutStore.editorFractionKey] == 0.38)

        store.setEditorMaximized(false)
        #expect(store.editorFraction == 0.38)  // and the restore lands on it

        // Belt and braces: not one write to the fraction key rode along with the
        // two mode writes. Equal VALUES could hide a write-then-rewrite; the write
        // LOG cannot.
        let fractionWrites = backing.writes.filter { $0.key == PanelLayoutStore.editorFractionKey }
        #expect(fractionWrites.count == 1, "maximize wrote editorFraction: \(fractionWrites)")
    }

    // MARK: - Waveform height (m25-e)

    @Test("waveform auto-fit defaults ON, round-trips, persists as 1/0, and is sticky")
    func waveformNormalize() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        // NOT opt-in — the reported defect IS the un-normalised look, so the fix
        // has to be on by default (the `auditionEnabled` rationale).
        #expect(store.waveformNormalize == true)
        #expect(PanelLayoutStore.defaultWaveformNormalize == true)

        store.setWaveformNormalize(false)
        #expect(store.waveformNormalize == false)
        #expect(backing.storage[PanelLayoutStore.waveformNormalizeKey] == 0)

        // Sticky across a store rebuild — a user who went back to true amplitude
        // is still there after relaunch. This is the leg that proves RAW is
        // REACHABLE AND PERSISTENT, i.e. that relative level is genuinely
        // recoverable rather than nominally so.
        #expect(PanelLayoutStore(backing: backing).waveformNormalize == false)

        store.setWaveformNormalize(true)
        #expect(backing.storage[PanelLayoutStore.waveformNormalizeKey] == 1)
        #expect(PanelLayoutStore(backing: backing).waveformNormalize == true)
    }

    @Test("waveform vertical zoom defaults to 1×, clamps to 1–8, and persists")
    func waveformVerticalZoom() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        #expect(store.waveformVerticalZoom == 1)
        #expect(PanelLayoutStore.defaultWaveformVerticalZoom == 1)

        store.setWaveformVerticalZoom(2.5)
        #expect(store.waveformVerticalZoom == 2.5)
        #expect(backing.storage[PanelLayoutStore.waveformVerticalZoomKey] == 2.5)

        // The store CLAMPS, it does not snap: a between-rungs value is legal.
        store.setWaveformVerticalZoom(99)
        #expect(store.waveformVerticalZoom == 8)
        store.setWaveformVerticalZoom(0.01)
        #expect(store.waveformVerticalZoom == 1)          // never shrinks below 1×
        store.setWaveformVerticalZoom(-4)
        #expect(store.waveformVerticalZoom == 1)

        // Sticky, and an out-of-range STORED value is re-clamped on load.
        store.setWaveformVerticalZoom(3)
        #expect(PanelLayoutStore(backing: backing).waveformVerticalZoom == 3)
        backing.storeValue(500, forKey: PanelLayoutStore.waveformVerticalZoomKey)
        #expect(PanelLayoutStore(backing: backing).waveformVerticalZoom == 8)
    }

    // MARK: - Follow the playhead (m23-c2)

    @Test("follow-the-playhead defaults OFF, round-trips, persists as 1/0, and is sticky")
    func followPlayhead() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        // OPT-IN: a view that moves on its own has to be asked for.
        #expect(store.followPlayhead == false)
        #expect(PanelLayoutStore.defaultFollowPlayhead == false)

        store.setFollowPlayhead(true)
        #expect(store.followPlayhead)
        #expect(backing.storage[PanelLayoutStore.followPlayheadKey] == 1)

        // Sticky across a store rebuild — the relaunch path.
        #expect(PanelLayoutStore(backing: backing).followPlayhead)

        store.setFollowPlayhead(false)
        #expect(backing.storage[PanelLayoutStore.followPlayheadKey] == 0)
        // A stored 0 reads as OFF, not as "never set".
        #expect(PanelLayoutStore(backing: backing).followPlayhead == false)
    }

    // MARK: - Mixer inserts disclosure (m23-a)

    @Test("mixer inserts default to EXPANDED, round-trip, and persist as 1/0")
    func mixerInsertsCollapsed() {
        let backing = SpyBacking()
        let store = PanelLayoutStore(backing: backing)
        // Default EXPANDED — a persisted "collapsed" default would make an existing
        // user's insert chains vanish the first time they open the update.
        #expect(store.mixerInsertsCollapsed == false)
        #expect(PanelLayoutStore.defaultMixerInsertsCollapsed == false)

        store.setMixerInsertsCollapsed(true)
        #expect(store.mixerInsertsCollapsed)
        // The Double backing encodes the Bool as 1/0; the encoding never escapes
        // the store's API.
        #expect(backing.storage[PanelLayoutStore.mixerInsertsCollapsedKey] == 1)

        store.setMixerInsertsCollapsed(false)
        #expect(store.mixerInsertsCollapsed == false)
        #expect(backing.storage[PanelLayoutStore.mixerInsertsCollapsedKey] == 0)
    }

    @Test("a fresh store reads the mixer disclosure back from the backing (sticky)")
    func mixerInsertsCollapsedIsSticky() {
        let backing = SpyBacking()
        PanelLayoutStore(backing: backing).setMixerInsertsCollapsed(true)
        #expect(PanelLayoutStore(backing: backing).mixerInsertsCollapsed)

        // A stored 0 must read as expanded, not as "never set" — the `object(forKey:)`
        // nil-vs-0 distinction the UserDefaults backing makes.
        PanelLayoutStore(backing: backing).setMixerInsertsCollapsed(false)
        #expect(PanelLayoutStore(backing: backing).mixerInsertsCollapsed == false)
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
