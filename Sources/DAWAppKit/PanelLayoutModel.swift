import CoreGraphics
import Foundation
import Observation
import DAWCore

/// The persistence seam for `PanelLayoutStore` (beta m10-d). Injected so the store
/// is hermetic in tests (an in-memory / spy backing) while the app wires a
/// UserDefaults-backed one — the layout is an app-side sticky PREFERENCE (window
/// chrome), never project data, so it survives relaunch but is never written into
/// the project file. One `Double`-valued slot per dimension, keyed by a stable
/// name. `@MainActor` because the store (a UI-state model) is main-actor isolated.
/// The `PanelDensityBacking` precedent — pure model here, no SwiftUI.
@MainActor
public protocol PanelLayoutBacking: AnyObject {
    /// The stored value for `key`, or nil if that dimension has never been set.
    func loadValue(forKey key: String) -> Double?
    /// Persists `value` for `key`.
    func storeValue(_ value: Double, forKey key: String)
}

/// Adjustable window layout for the arrange workspace (beta m10-d): the track
/// sidebar width, the bottom editor's height as a fraction of the window, and the
/// GLOBAL track-row height (one value shared by the sidebar headers and the
/// timeline lanes, so they stay pixel-aligned at every size). Each dimension is an
/// app-side sticky PREFERENCE — never project data — persisted through the injected
/// `PanelLayoutBacking` under `panelLayout.<dimension>`, so a resized layout
/// survives close/reopen and relaunch (the `PanelDensityStore` precedent).
///
/// **Clamping lives here**: every setter tames its input to the dimension's range
/// (setting 9999 stores the max), so the view layer can hand a raw drag delta
/// straight through. `@Observable` so a bound view re-renders when a value changes;
/// `@ObservationIgnored` shields the backing (persistence, not observed state).
///
/// SwiftUI-free (this target has no SwiftUI): the DAWApp `PanelSplitter` component
/// drives the setters from its drag gestures and the views read the values.
@MainActor
@Observable
public final class PanelLayoutStore {

    // MARK: - Persistence keys (one per dimension)

    public static let sidebarWidthKey = "sidebarWidth"
    public static let editorFractionKey = "editorFraction"
    public static let rowHeightKey = "rowHeight"

    // MARK: - Defaults (today's hardcoded values — the pre-m10-d look)

    /// Track sidebar width — was `frame(width: 260)` in ContentView.
    public static let defaultSidebarWidth: CGFloat = 260
    /// Bottom editor height as a fraction of window height — was `geo.height * 0.45`.
    public static let defaultEditorFraction: CGFloat = 0.45
    /// Global track-row / timeline-lane height — was `TimelineLanesView.laneHeight`.
    public static let defaultRowHeight: CGFloat = 34

    // MARK: - Clamp ranges
    //
    // These ranges are deliberately CONSERVATIVE (beta m10-d gate): the reachable
    // extremes must not visibly break at the window size the app actually runs at.
    // The track-header row does not fully priority-shrink (fixed-width meter + M/S/A
    // chips). As of m10-j the WINDOW has a measured floor (`WindowFloor`) and the
    // arrange track area SCROLLS as one unit rather than overflowing, so a small
    // window scrolls instead of pushing chrome off-frame — the ranges + the floor +
    // the shared scroll now hold the line together.

    /// Sidebar min = the header row's measured intrinsic floor (headless
    /// `fittingSize`: ~242 pt empty / ~267 pt with a clip-count, name truncated),
    /// tolerance-matched to the proven-clean 260 pt default; max leaves the timeline
    /// room. The soft name (m10-i) + the take-group automation fold (m10-j,
    /// `TrackHeaderLayout`) keep the name readable at this floor without inflating it.
    public static let sidebarWidthRange: ClosedRange<CGFloat> = 250...420
    /// Editor max (0.55) keeps the app header + arrange chrome + transport visible;
    /// it is the WORST case the window's measured height floor (`WindowFloor`, m10-j)
    /// is derived against, so the chrome stays visible at the floor with the editor
    /// open. Min stays comfortably usable.
    public static let editorFractionRange: ClosedRange<CGFloat> = 0.30...0.55
    /// Row height spans a dense multitrack view up to a comfortable large row (this
    /// range was innocent — the earlier tall-editor overflow came from the fraction,
    /// not the row height).
    public static let rowHeightRange: ClosedRange<CGFloat> = 24...64

    // MARK: - Live values (observed)

    public private(set) var sidebarWidth: CGFloat
    public private(set) var editorFraction: CGFloat
    public private(set) var rowHeight: CGFloat

    @ObservationIgnored private let backing: PanelLayoutBacking

    /// - Parameter backing: the persistence seam. Defaults to an in-memory backing
    ///   (previews / tests / a session that shouldn't persist). Persisted values are
    ///   re-clamped on load, so a corrupt or out-of-range stored number is tamed.
    public init(backing: PanelLayoutBacking? = nil) {
        let backing = backing ?? InMemoryPanelLayoutBacking()
        self.backing = backing
        self.sidebarWidth = Self.loaded(backing, Self.sidebarWidthKey,
                                        default: Self.defaultSidebarWidth, range: Self.sidebarWidthRange)
        self.editorFraction = Self.loaded(backing, Self.editorFractionKey,
                                          default: Self.defaultEditorFraction, range: Self.editorFractionRange)
        self.rowHeight = Self.loaded(backing, Self.rowHeightKey,
                                     default: Self.defaultRowHeight, range: Self.rowHeightRange)
    }

    private static func loaded(_ backing: PanelLayoutBacking, _ key: String,
                               default fallback: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        (backing.loadValue(forKey: key).map { CGFloat($0) } ?? fallback).clamped(to: range)
    }

    // MARK: - Setters (clamp + write-through)

    public func setSidebarWidth(_ value: CGFloat) {
        sidebarWidth = value.clamped(to: Self.sidebarWidthRange)
        backing.storeValue(Double(sidebarWidth), forKey: Self.sidebarWidthKey)
    }

    public func setEditorFraction(_ value: CGFloat) {
        editorFraction = value.clamped(to: Self.editorFractionRange)
        backing.storeValue(Double(editorFraction), forKey: Self.editorFractionKey)
    }

    public func setRowHeight(_ value: CGFloat) {
        rowHeight = value.clamped(to: Self.rowHeightRange)
        backing.storeValue(Double(rowHeight), forKey: Self.rowHeightKey)
    }

    /// Restores every dimension to its default (and persists the reset).
    public func reset() {
        setSidebarWidth(Self.defaultSidebarWidth)
        setEditorFraction(Self.defaultEditorFraction)
        setRowHeight(Self.defaultRowHeight)
    }
}

/// A non-persistent in-memory backing — the default for `PanelLayoutStore`, used by
/// previews and tests. Just a dictionary.
@MainActor
public final class InMemoryPanelLayoutBacking: PanelLayoutBacking {
    private var storage: [String: Double]

    public init(_ initial: [String: Double] = [:]) {
        self.storage = initial
    }

    public func loadValue(forKey key: String) -> Double? { storage[key] }
    public func storeValue(_ value: Double, forKey key: String) { storage[key] = value }
}

/// UserDefaults-backed persistence for the app: one key per dimension,
/// `panelLayout.<dimension>`, storing the value as a Double. This makes the layout
/// an app-side sticky preference (survives relaunch) that is NEVER part of the
/// project file. Foundation-only, so it can live here in DAWAppKit.
@MainActor
public final class UserDefaultsPanelLayoutBacking: PanelLayoutBacking {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "panelLayout.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(_ dimension: String) -> String { keyPrefix + dimension }

    public func loadValue(forKey key: String) -> Double? {
        // `object(forKey:)` distinguishes "never set" (nil) from a stored 0.
        guard defaults.object(forKey: self.key(key)) != nil else { return nil }
        return defaults.double(forKey: self.key(key))
    }

    public func storeValue(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: self.key(key))
    }
}
