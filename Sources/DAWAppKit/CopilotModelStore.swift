import AIServices
import Foundation
import Observation

/// The persistence seam for `CopilotModelStore` (M10-p-6). Injected so the
/// store is hermetic in tests (a spy / in-memory backing) while the app
/// wires a UserDefaults-backed one — the copilot's selected model is an
/// app-side sticky PREFERENCE (never project data), so it survives relaunch
/// but is never written into the project file. `@MainActor` because the
/// store (a UI-state model) is main-actor isolated — the
/// `CopilotLimitsBacking` precedent.
@MainActor
public protocol CopilotModelBacking: AnyObject {
    /// The persisted model id, or nil if the setting has never been set (or
    /// is a corrupt / wrong-type entry the backing chose to ignore).
    func loadModel() -> String?
    /// Persists `modelID`.
    func storeModel(_ modelID: String)
}

/// The in-app Copilot model SETTING (M10-p-6): which Anthropic model the
/// copilot's turns target, editable in a future Settings picker and
/// persisted through the injected `CopilotModelBacking` under
/// `AnthropicModelCatalog.userDefaultsKey`. Like the round-budget setting
/// (`CopilotLimitsStore`), a change here takes effect on the copilot's NEXT
/// turn — `CopilotEngine` reads this store's `effectiveModel` fresh at the
/// start of each turn's provider resolution — so there's nothing to
/// restart.
///
/// `@Observable` so a Settings picker re-renders when the value commits;
/// `@ObservationIgnored` shields the backing (persistence, not observed
/// state). SwiftUI-free (this target has no SwiftUI) — a DAWApp Settings
/// section (a later UI phase) would bind the field and drive `commit`. The
/// `CopilotLimitsStore` idiom throughout.
@MainActor
@Observable
public final class CopilotModelStore {
    /// The persisted setting, or nil when none is set (the default flows).
    /// The engine reads the resolved value through `effectiveModel`, never
    /// this raw optional.
    public private(set) var configuredModel: String?

    @ObservationIgnored private let backing: CopilotModelBacking

    /// - Parameter backing: the persistence seam. Defaults to an in-memory
    ///   backing (previews / tests / a session that shouldn't persist). A
    ///   persisted id that is no longer in `AnthropicModelCatalog.curated`
    ///   (a build whose curated list shrank) is treated as "no setting" —
    ///   unlike `CopilotLimitsStore`'s numeric clamp, there's no sensible
    ///   "nearest valid model" to coerce to, so the default flows instead.
    public init(backing: CopilotModelBacking? = nil) {
        let backing = backing ?? InMemoryCopilotModelBacking()
        self.backing = backing
        if let stored = backing.loadModel(), AnthropicModelCatalog.curated.contains(where: { $0.id == stored }) {
            self.configuredModel = stored
        } else {
            self.configuredModel = nil
        }
    }

    /// The effective model id the copilot's turns should target: the
    /// persisted setting, or `AnthropicModelCatalog.defaultModelID` when
    /// none is set. The bootstrap hands the engine
    /// `{ store.effectiveModel }` as its per-turn resolver.
    public var effectiveModel: String {
        configuredModel ?? AnthropicModelCatalog.defaultModelID
    }

    /// Validates `modelID` against `AnthropicModelCatalog.curated` and
    /// persists it on success — on success the id is stored and returned; on
    /// an unrecognized id NOTHING is persisted (the current setting is left
    /// intact) and nil is returned so the caller can show/throw an
    /// actionable error (`ai.copilotSetModel`'s teaching-error message lists
    /// the same curated ids this validates against — one source of truth,
    /// `AnthropicModelCatalog`).
    @discardableResult
    public func commit(_ modelID: String) -> String? {
        guard AnthropicModelCatalog.curated.contains(where: { $0.id == modelID }) else { return nil }
        configuredModel = modelID
        backing.storeModel(modelID)
        return modelID
    }
}

/// A non-persistent in-memory backing — the default for `CopilotModelStore`,
/// used by previews and tests. Just a single optional slot.
@MainActor
public final class InMemoryCopilotModelBacking: CopilotModelBacking {
    private var storage: String?

    public init(_ initial: String? = nil) { self.storage = initial }

    public func loadModel() -> String? { storage }
    public func storeModel(_ modelID: String) { storage = modelID }
}

/// UserDefaults-backed persistence for the app: the selected model under
/// `AnthropicModelCatalog.userDefaultsKey`, stored as a string. Makes the
/// setting an app-side sticky preference (survives relaunch) that is NEVER
/// part of the project file. Foundation-only, so it lives here in DAWAppKit
/// (the `UserDefaultsCopilotLimitsBacking` precedent).
@MainActor
public final class UserDefaultsCopilotModelBacking: CopilotModelBacking {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = AnthropicModelCatalog.userDefaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func loadModel() -> String? {
        // Distinguish "never set" (nil) and a corrupt / wrong-type entry (a
        // stored number, say) from a real stored string — both non-string
        // cases read as nil so the default flows.
        guard let object = defaults.object(forKey: key) else { return nil }
        return object as? String
    }

    public func storeModel(_ modelID: String) {
        defaults.set(modelID, forKey: key)
    }
}
