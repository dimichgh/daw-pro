import DAWCore
import Foundation
import Observation

/// The persistence seam for `CopilotLimitsStore` (beta m10-m). Injected so the store
/// is hermetic in tests (a spy / in-memory backing) while the app wires a
/// UserDefaults-backed one — the Copilot round budget is an app-side sticky
/// PREFERENCE (never project data), so it survives relaunch but is never written into
/// the project file. `@MainActor` because the store (a UI-state model) is main-actor
/// isolated (the `ControlPortBacking` precedent).
@MainActor
public protocol CopilotLimitsBacking: AnyObject {
    /// The persisted max-rounds, or nil if the setting has never been set (or is a
    /// corrupt / wrong-type entry the backing chose to ignore).
    func loadMaxRounds() -> Int?
    /// Persists `rounds`.
    func storeMaxRounds(_ rounds: Int)
}

/// The in-app Copilot round-budget SETTING (beta m10-m): the max number of tool
/// rounds one Copilot reply may take, editable in Settings → Copilot and persisted
/// through the injected `CopilotLimitsBacking` under `copilot.maxRounds`. Unlike the
/// control-server port (a restart-scoped setting), a change here takes effect on the
/// Copilot's NEXT reply — the engine reads this store's `maxRounds` fresh at the
/// start of each turn — so there's nothing to restart.
///
/// `@Observable` so the Settings field re-renders when the value commits;
/// `@ObservationIgnored` shields the backing (persistence, not observed state).
/// SwiftUI-free (this target has no SwiftUI) — the DAWApp Settings section binds the
/// field and drives `commit`. The `ControlPortStore` idiom throughout.
@MainActor
@Observable
public final class CopilotLimitsStore {
    /// The persisted setting, or nil when none is set (the default flows). Read by the
    /// Settings field (current value vs. the "8" placeholder). The engine reads the
    /// resolved value through `maxRounds`, never this raw optional.
    public private(set) var configuredMaxRounds: Int?

    @ObservationIgnored private let backing: CopilotLimitsBacking

    /// - Parameter backing: the persistence seam. Defaults to an in-memory backing
    ///   (previews / tests / a session that shouldn't persist). A persisted value
    ///   OUTSIDE `validRange` is CLAMPED into range on load (not discarded) — a stale
    ///   setting from a build with a wider range still expresses the user's intent
    ///   ("a lot" → the ceiling) rather than snapping back to the default. This is a
    ///   deliberate divergence from `ControlPortStore`, which treats an out-of-range
    ///   persisted port as "no setting": a bad port is dangerous to bind, whereas a
    ///   clamped round count is always safe. An ABSENT or corrupt entry (backing
    ///   returns nil) flows to the default.
    public init(backing: CopilotLimitsBacking? = nil) {
        let backing = backing ?? InMemoryCopilotLimitsBacking()
        self.backing = backing
        if let stored = backing.loadMaxRounds() {
            self.configuredMaxRounds = CopilotLimits.clamp(stored)
        } else {
            self.configuredMaxRounds = nil
        }
    }

    /// The effective max tool-rounds the engine should honor: the persisted setting,
    /// or `CopilotLimits.defaultMaxRounds` (8) when none is set. The bootstrap hands
    /// the engine `{ store.maxRounds }` as its per-turn resolver.
    public var maxRounds: Int {
        configuredMaxRounds ?? CopilotLimits.defaultMaxRounds
    }

    /// Validates and persists a user-entered string. On success the parsed value is
    /// stored and returned; on invalid input NOTHING is persisted (the current
    /// setting is left intact) and nil is returned so the caller can show an inline
    /// error. Validation lives in `CopilotLimits.validate` (one tested source) —
    /// the field REJECTS out-of-range input (unlike the wire override, which clamps).
    @discardableResult
    public func commit(_ input: String) -> Int? {
        guard let rounds = CopilotLimits.validate(input) else { return nil }
        configuredMaxRounds = rounds
        backing.storeMaxRounds(rounds)
        return rounds
    }
}

/// A non-persistent in-memory backing — the default for `CopilotLimitsStore`, used by
/// previews and tests. Just a single optional slot.
@MainActor
public final class InMemoryCopilotLimitsBacking: CopilotLimitsBacking {
    private var storage: Int?

    public init(_ initial: Int? = nil) { self.storage = initial }

    public func loadMaxRounds() -> Int? { storage }
    public func storeMaxRounds(_ rounds: Int) { storage = rounds }
}

/// UserDefaults-backed persistence for the app: the round budget under
/// `copilot.maxRounds`, stored as an integer. Makes the setting an app-side sticky
/// preference (survives relaunch) that is NEVER part of the project file.
/// Foundation-only, so it lives here in DAWAppKit (the
/// `UserDefaultsControlPortBacking` precedent).
@MainActor
public final class UserDefaultsCopilotLimitsBacking: CopilotLimitsBacking {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = CopilotLimits.userDefaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func loadMaxRounds() -> Int? {
        // Distinguish "never set" (nil) and a corrupt / wrong-type entry (a stored
        // string, say) from a real stored number — both non-numeric cases read as nil
        // so the default flows, while a numeric value (even out of range) is returned
        // for the store to clamp.
        guard let object = defaults.object(forKey: key) else { return nil }
        guard let number = object as? NSNumber else { return nil }
        return number.intValue
    }

    public func storeMaxRounds(_ rounds: Int) {
        defaults.set(rounds, forKey: key)
    }
}
