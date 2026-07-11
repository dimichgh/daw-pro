import Foundation
import Observation

/// The two density modes every panel carries (docs/DESIGN-LANGUAGE.md "Panels").
/// Simple is the default: it shows the 20 % of controls used 80 % of the time;
/// Pro reveals everything. The raw value is the wire/persistence key, so the
/// `debug.panelDensity` staging command and the UserDefaults backing round-trip
/// through `PanelDensity(rawValue:)`.
public enum PanelDensity: String, CaseIterable, Sendable {
    case simple
    case pro

    /// Chip label ("Simple" / "Pro").
    public var label: String {
        switch self {
        case .simple: "Simple"
        case .pro: "Pro"
        }
    }
}

/// The persistence seam for `PanelDensityStore`. Injected so the store is
/// hermetic in tests (a spy / in-memory backing) while the app wires a
/// UserDefaults-backed one — the density is an app-side sticky PREFERENCE, never
/// project data, so it survives panel close/reopen and relaunch but is never
/// written into the project file. `@MainActor` because the store (a UI-state
/// model) is main-actor isolated.
@MainActor
public protocol PanelDensityBacking: AnyObject {
    /// The stored density for `panelID`, or nil if the panel has never been set.
    func loadDensity(forPanel panelID: String) -> PanelDensity?
    /// Persists `density` for `panelID`.
    func storeDensity(_ density: PanelDensity, forPanel panelID: String)
}

/// Per-panel Simple/Pro density state, keyed by a stable panel ID (e.g.
/// `"pianoRoll"`). Density is PER PANEL, not global — a beginner may want a Pro
/// piano roll but a Simple mixer (docs/DESIGN-LANGUAGE.md). `@Observable` so a
/// bound view re-renders when the mode flips; reads/writes go through the
/// injected `PanelDensityBacking` for sticky persistence.
///
/// SwiftUI-free (this target has no SwiftUI): the `SimpleProToggle` component in
/// DAWApp binds a store to a panel ID and drives `density`/`setDensity`.
@MainActor
@Observable
public final class PanelDensityStore {
    /// Observed cache of the live density per panel. A read that misses the cache
    /// falls back to the backing (defaulting to `.simple`); a set writes both the
    /// cache (so the view updates) and the backing (so it sticks). Reading the
    /// subscript registers the observation dependency, so a later `setDensity`
    /// re-renders every bound view.
    private var densities: [String: PanelDensity] = [:]

    @ObservationIgnored private let backing: PanelDensityBacking

    /// - Parameter backing: the persistence seam. Defaults to an in-memory
    ///   backing (previews / tests / a session that shouldn't persist).
    public init(backing: PanelDensityBacking? = nil) {
        self.backing = backing ?? InMemoryPanelDensityBacking()
    }

    /// The current density for `panelID` — the cached value, else the persisted
    /// value, else `.simple` (the default). Never mutates state (safe to call
    /// from a view body).
    public func density(forPanel panelID: String) -> PanelDensity {
        densities[panelID] ?? backing.loadDensity(forPanel: panelID) ?? .simple
    }

    /// Sets `panelID`'s density and persists it through the backing.
    public func setDensity(_ density: PanelDensity, forPanel panelID: String) {
        densities[panelID] = density
        backing.storeDensity(density, forPanel: panelID)
    }

    /// Flips `panelID` between Simple and Pro.
    public func toggle(forPanel panelID: String) {
        setDensity(density(forPanel: panelID) == .simple ? .pro : .simple, forPanel: panelID)
    }
}

/// A non-persistent in-memory backing — the default for `PanelDensityStore`, used
/// by previews and tests. Just a dictionary.
@MainActor
public final class InMemoryPanelDensityBacking: PanelDensityBacking {
    private var storage: [String: PanelDensity]

    public init(_ initial: [String: PanelDensity] = [:]) {
        self.storage = initial
    }

    public func loadDensity(forPanel panelID: String) -> PanelDensity? {
        storage[panelID]
    }

    public func storeDensity(_ density: PanelDensity, forPanel panelID: String) {
        storage[panelID] = density
    }
}

/// UserDefaults-backed persistence for the app: one key per panel,
/// `panelDensity.<panelID>`, storing the density's raw value. This makes density
/// an app-side sticky preference (survives relaunch) that is NEVER part of the
/// project file. Foundation-only, so it can live here in DAWAppKit.
@MainActor
public final class UserDefaultsPanelDensityBacking: PanelDensityBacking {
    private let defaults: UserDefaults
    private let keyPrefix: String

    public init(defaults: UserDefaults = .standard, keyPrefix: String = "panelDensity.") {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
    }

    private func key(_ panelID: String) -> String { keyPrefix + panelID }

    public func loadDensity(forPanel panelID: String) -> PanelDensity? {
        defaults.string(forKey: key(panelID)).flatMap(PanelDensity.init(rawValue:))
    }

    public func storeDensity(_ density: PanelDensity, forPanel panelID: String) {
        defaults.set(density.rawValue, forKey: key(panelID))
    }
}
