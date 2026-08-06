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
    /// Every panel that carries an EXPLICITLY persisted density, keyed by panel
    /// ID. A panel that has never been set is ABSENT — never present with the
    /// `.simple` default, which is the whole point (m23-du(a)): a caller that
    /// cannot tell "never set" from "explicitly simple" will write the default
    /// back and silently convert an unset key into an explicit one.
    ///
    /// A HARD requirement with no default implementation ON PURPOSE. A default
    /// returning `[:]` would let a non-enumerating backing under-report
    /// invisibly, and an under-report reads as *"nothing to restore"* — the
    /// failure points the wrong way. Making it a requirement lets the compiler
    /// enumerate the conformers instead.
    func storedDensities() -> [String: PanelDensity]
    /// Removes any persisted density for `panelID`, returning the panel to
    /// GENUINELY UNSET — not to an explicitly-stored `.simple` (m23-ej-1). This
    /// is the only way to put a `nil` back: `storeDensity` always writes an
    /// explicit value, so a caller restoring a null prior would otherwise have
    /// to invent one, converting an unset key into an explicit one (the exact
    /// defect `storedDensity(forPanel:)` exists to expose).
    ///
    /// Removing a panel that was never stored is a NO-OP, not an error — a
    /// restore should not have to know whether it has anything to undo. Note
    /// this is the CONFORMER'S obligation: `PanelDensityStore.clearDensity`
    /// calls through UNCONDITIONALLY and does not short-circuit on a panel it
    /// believes is unset, since the store's view of "unset" is only as good as
    /// its cache. Every backing must therefore tolerate removing a missing key.
    ///
    /// Also a hard requirement with no default implementation, for the same
    /// reason as `storedDensities()`: a default that did nothing would let a
    /// backing silently keep the key while the store reported the clear as
    /// having worked, and "clear that didn't" is invisible until the relaunch.
    func removeDensity(forPanel panelID: String)
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

    /// The EXPLICITLY persisted density for `panelID`, or nil when the panel has
    /// never been set — the same lookup as `density(forPanel:)` MINUS the
    /// `.simple` fallback (m23-du(a)).
    ///
    /// This exists because `density(forPanel:)` cannot answer the question a
    /// restore actually needs. It returns `.simple` both for a panel someone
    /// chose Simple on and for a panel nobody has ever touched, so a caller that
    /// reads it and writes it back converts an unset key into an explicit one —
    /// changing what a fresh machine looks like. Read this to learn whether
    /// there is anything to put back; read `density(forPanel:)` to learn what
    /// the UI is actually showing. Never mutates state (safe from a view body).
    ///
    /// A caller holding a `nil` prior restores it with `clearDensity(forPanel:)`
    /// — `setDensity` only ever writes an explicit value and cannot.
    public func storedDensity(forPanel panelID: String) -> PanelDensity? {
        // The cache first — it is only ever populated by `setDensity`, which
        // writes through, so the two agree; consulting it first also registers
        // the observation dependency and skips a backing hit.
        densities[panelID] ?? backing.loadDensity(forPanel: panelID)
    }

    /// Every panel with an EXPLICITLY persisted density. Panels never set are
    /// absent (see `storedDensity(forPanel:)` for why that distinction is the
    /// point). The union of the backing's enumeration and this session's cache:
    /// the cache can only ever hold written-through values, so for a fully
    /// enumerating backing the union equals the backing — but the union is never
    /// LESS informative, and it never invents a panel nobody set.
    public func storedDensities() -> [String: PanelDensity] {
        backing.storedDensities().merging(densities) { _, session in session }
    }

    /// Sets `panelID`'s density and persists it through the backing.
    public func setDensity(_ density: PanelDensity, forPanel panelID: String) {
        densities[panelID] = density
        backing.storeDensity(density, forPanel: panelID)
    }

    /// Returns `panelID` to GENUINELY UNSET: drops the persisted value and the
    /// in-session cache entry, so `storedDensity(forPanel:)` reads nil again and
    /// `density(forPanel:)` falls back to `.simple` (m23-ej-1). This is the
    /// inverse of `setDensity`, and the only restore available to a caller whose
    /// prior was null — writing `.simple` back would look the same in the UI but
    /// leave an explicit key behind, which is a different machine state.
    ///
    /// ⚠️ THE EVICTION IS LOAD-BEARING, and dropping it is how this ships broken
    /// while looking right: `densities[panelID]` is consulted FIRST by both
    /// `density(forPanel:)` and `storedDensity(forPanel:)`, and merged OVER the
    /// backing by `storedDensities()`. Remove from the backing alone and the
    /// cached value resurrects on the very next read — the clear silently does
    /// nothing for the rest of the session, then appears to have worked after a
    /// relaunch. Mutating `densities` also fires the observation, so a bound
    /// `SimpleProToggle` re-renders on the fallback.
    ///
    /// Clearing a panel that was never set is a NO-OP. The backing is still
    /// called (removing a missing key is harmless everywhere and keeps the seam
    /// unconditional), so a backing that persists outside this store's knowledge
    /// still gets the message.
    public func clearDensity(forPanel panelID: String) {
        densities.removeValue(forKey: panelID)
        backing.removeDensity(forPanel: panelID)
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

    /// The dictionary IS the set of explicitly stored panels — nothing is
    /// defaulted into it, so it needs no filtering.
    public func storedDensities() -> [String: PanelDensity] { storage }

    /// Drops the key entirely, so the panel reads as never set rather than as
    /// explicitly `.simple`. Removing an absent key is a no-op.
    public func removeDensity(forPanel panelID: String) {
        storage.removeValue(forKey: panelID)
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

    /// Enumerates the domain for `panelDensity.<panelID>` keys. Derived from the
    /// defaults themselves — there is deliberately NO hardcoded panel list here,
    /// because a hardcoded list would report panels nobody set and miss any
    /// panel added later, which is exactly the lie `storedDensity` exists to
    /// avoid.
    ///
    /// Candidate keys come from `dictionaryRepresentation()`; each is then
    /// CONFIRMED through `loadDensity(forPanel:)`, so a key holding a
    /// non-`PanelDensity` string (hand-edited plist, a renamed case) is dropped
    /// rather than reported as stored. An empty panel ID (a bare
    /// `"panelDensity."` key) is dropped too.
    ///
    /// ⚠️ ONE HONEST LIMITATION, stated rather than papered over: on
    /// `UserDefaults` the composite search list includes the REGISTRATION
    /// domain, and no public API distinguishes *"registered as a default"* from
    /// *"explicitly written"* for a suite this type does not own the name of.
    /// Nothing calls `register(defaults:)` with a `panelDensity.*` key today, so
    /// today every key found here was genuinely written. If that ever changes,
    /// this would over-report — so `panelDensity.*` must never be registered.
    public func storedDensities() -> [String: PanelDensity] {
        var result: [String: PanelDensity] = [:]
        for candidate in defaults.dictionaryRepresentation().keys
        where candidate.hasPrefix(keyPrefix) {
            let panelID = String(candidate.dropFirst(keyPrefix.count))
            guard !panelID.isEmpty else { continue }
            guard let density = loadDensity(forPanel: panelID) else { continue }
            result[panelID] = density
        }
        return result
    }

    /// Removes the `panelDensity.<panelID>` key from the domain, through the
    /// SAME `key(_:)` scheme `storeDensity` writes with — so a custom
    /// `keyPrefix` clears its own namespace and nobody else's. `removeObject` on
    /// a key that was never written is a no-op.
    ///
    /// ⚠️ This removes from the APPLICATION domain only, which is where
    /// `storeDensity` writes. A value arriving from the registration domain (or
    /// from a managed/global domain) is not removable by any public API and
    /// would survive this call — the same limitation `storedDensities()`
    /// documents, and the same reason `panelDensity.*` must never be registered.
    public func removeDensity(forPanel panelID: String) {
        defaults.removeObject(forKey: key(panelID))
    }
}
