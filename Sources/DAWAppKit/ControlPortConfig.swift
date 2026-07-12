import Foundation
import Observation

/// Where the live control-server port actually came from (beta m10-l). A UI reads
/// this so it can be HONEST about what's in effect: the `DAW_CONTROL_PORT`
/// environment override outranks the in-app setting, so the settings field must
/// never look broken when the staging harness (or a power user) pins the port from
/// the shell. Raw-valued so it rides the `app.connectionInfo` wire response as a
/// stable string.
public enum ControlPortSource: String, Sendable, Equatable, CaseIterable {
    /// The `DAW_CONTROL_PORT` environment variable — the sacred override.
    case environment
    /// The in-app, persisted port setting (Settings → Agent Connection).
    case settings
    /// The built-in default (17600) — no override, no setting.
    case `default`
}

/// The resolved control-server port plus its provenance (beta m10-l) — the answer
/// `ControlPortConfig.resolve` returns and the bootstrap binds the server to. A
/// plain value so it hops actors/layers freely (the app hands `port` to the
/// `ControlServer` and `source` to the `app.connectionInfo` surface).
public struct ControlPortResolution: Sendable, Equatable {
    /// The port to bind (env > settings > default 17600).
    public let port: UInt16
    /// Where `port` came from — so a UI can annotate an env override.
    public let source: ControlPortSource

    public init(port: UInt16, source: ControlPortSource) {
        self.port = port
        self.source = source
    }

    /// The loopback WebSocket URL an agent connects to.
    public var url: String { "ws://127.0.0.1:\(port)" }
}

/// Pure, headless resolution + validation for the control-server port (beta
/// m10-l). Before m10-l the port was resolvable ONLY through the
/// `DAW_CONTROL_PORT` env var (read inline at bootstrap); this adds a persisted
/// in-app setting WITHOUT dethroning that env override. Everything here is a pure
/// function so the precedence matrix and the field-validation edges are unit-tested
/// without a running app (the `PanelDensity`/`ExplainCatalog` headless-copy
/// precedent).
public enum ControlPortConfig {
    /// The built-in default port — byte-identical to the pre-m10-l inline literal.
    public static let defaultPort: UInt16 = 17600

    /// Valid range for the IN-APP setting field: non-privileged, user-assignable
    /// TCP ports. The env override is deliberately NOT range-checked here (it keeps
    /// its historical `UInt16.init` behavior — see `resolve`), so a shell can still
    /// pin any port it likes; the range only gates what the UI will persist.
    public static let validRange: ClosedRange<UInt16> = 1024...65535

    /// The environment variable that overrides everything.
    public static let environmentKey = "DAW_CONTROL_PORT"

    /// The UserDefaults key the in-app setting persists under — the
    /// `panelLayout.*` / `panelDensity.*` naming family.
    public static let userDefaultsKey = "controlServer.port"

    /// Resolves the port to bind, honoring precedence **environment > persisted
    /// setting > default**.
    ///
    /// - The env branch matches the pre-m10-l inline behavior EXACTLY: the value is
    ///   parsed with `UInt16.init`, so a present-but-non-numeric (or overflowing)
    ///   value simply falls through to the setting/default — it never errors and
    ///   never blocks the app. THE ENV OVERRIDE IS SACRED: a persisted setting can
    ///   never outrank a parseable env value.
    /// - `persisted` is the in-app setting (nil = none set), already range-validated
    ///   on the way in (see `validate`).
    public static func resolve(environment: [String: String], persisted: UInt16?) -> ControlPortResolution {
        if let raw = environment[environmentKey], let envPort = UInt16(raw) {
            return ControlPortResolution(port: envPort, source: .environment)
        }
        if let persisted {
            return ControlPortResolution(port: persisted, source: .settings)
        }
        return ControlPortResolution(port: defaultPort, source: .default)
    }

    /// Validates a user-entered port string for the Settings field: the trimmed
    /// input must parse as an integer inside `validRange` (1024–65535). Returns the
    /// parsed port on success, or nil for a parse failure / out-of-range / empty /
    /// whitespace input — the caller then persists nothing and shows an inline
    /// error (keeps the field honest and the rule unit-testable).
    public static func validate(_ input: String) -> UInt16? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = UInt16(trimmed), validRange.contains(value) else { return nil }
        return value
    }
}

/// The persistence seam for `ControlPortStore` (beta m10-l). Injected so the store
/// is hermetic in tests (a spy / in-memory backing) while the app wires a
/// UserDefaults-backed one — the port is an app-side sticky PREFERENCE (never
/// project data), so it survives relaunch but is never written into the project
/// file. `@MainActor` because the store (a UI-state model) is main-actor isolated
/// (the `PanelLayoutBacking` precedent).
@MainActor
public protocol ControlPortBacking: AnyObject {
    /// The persisted port, or nil if the setting has never been set.
    func loadPort() -> UInt16?
    /// Persists `port`.
    func storePort(_ port: UInt16)
}

/// The in-app control-server port SETTING (beta m10-l): an app-side sticky
/// preference the Settings → Agent Connection field edits, persisted through the
/// injected `ControlPortBacking` under `controlServer.port`. Changing it does NOT
/// live-rebind the running server — a new port takes effect on the next launch
/// (the bootstrap reads this store to resolve the bind port); rebinding mid-session
/// would sever the live agent connection and the transport broadcaster, so it's
/// deliberately a restart-scoped setting.
///
/// `@Observable` so the Settings field re-renders when the value commits;
/// `@ObservationIgnored` shields the backing (persistence, not observed state).
/// SwiftUI-free (this target has no SwiftUI) — the DAWApp Settings section binds
/// the field and drives `commit`. The `PanelLayoutStore` idiom throughout.
@MainActor
@Observable
public final class ControlPortStore {
    /// The persisted setting, or nil when none is set (default flows). Read by the
    /// bootstrap (to resolve the bind port) and by the Settings field (to show the
    /// current value vs. the "17600" placeholder).
    public private(set) var configuredPort: UInt16?

    @ObservationIgnored private let backing: ControlPortBacking

    /// - Parameter backing: the persistence seam. Defaults to an in-memory backing
    ///   (previews / tests / a session that shouldn't persist). A stored value
    ///   outside `validRange` is treated as "no setting" (nil) on load, so a corrupt
    ///   or stale UserDefaults entry can never bind a bad port.
    public init(backing: ControlPortBacking? = nil) {
        let backing = backing ?? InMemoryControlPortBacking()
        self.backing = backing
        if let stored = backing.loadPort(), ControlPortConfig.validRange.contains(stored) {
            self.configuredPort = stored
        } else {
            self.configuredPort = nil
        }
    }

    /// Validates and persists a user-entered string. On success the parsed port is
    /// stored and returned; on invalid input NOTHING is persisted (the current
    /// setting is left intact) and nil is returned so the caller can show an inline
    /// error. Validation lives in `ControlPortConfig.validate` (one tested source).
    @discardableResult
    public func commit(_ input: String) -> UInt16? {
        guard let port = ControlPortConfig.validate(input) else { return nil }
        configuredPort = port
        backing.storePort(port)
        return port
    }

    /// The resolved bind port + provenance for `environment` (default: the live
    /// process environment). The bootstrap calls this to pick the port; the
    /// Settings section calls it to decide whether to show the env-override note.
    public func resolution(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ControlPortResolution {
        ControlPortConfig.resolve(environment: environment, persisted: configuredPort)
    }
}

/// A non-persistent in-memory backing — the default for `ControlPortStore`, used by
/// previews and tests. Just a single optional slot.
@MainActor
public final class InMemoryControlPortBacking: ControlPortBacking {
    private var storage: UInt16?

    public init(_ initial: UInt16? = nil) { self.storage = initial }

    public func loadPort() -> UInt16? { storage }
    public func storePort(_ port: UInt16) { storage = port }
}

/// UserDefaults-backed persistence for the app: the port setting under
/// `controlServer.port`, stored as an integer. Makes the port an app-side sticky
/// preference (survives relaunch) that is NEVER part of the project file.
/// Foundation-only, so it lives here in DAWAppKit (the `UserDefaultsPanelLayoutBacking`
/// precedent).
@MainActor
public final class UserDefaultsControlPortBacking: ControlPortBacking {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = ControlPortConfig.userDefaultsKey) {
        self.defaults = defaults
        self.key = key
    }

    public func loadPort() -> UInt16? {
        // `object(forKey:)` distinguishes "never set" (nil) from a stored 0.
        guard defaults.object(forKey: key) != nil else { return nil }
        let value = defaults.integer(forKey: key)
        guard (0...Int(UInt16.max)).contains(value) else { return nil }
        return UInt16(value)
    }

    public func storePort(_ port: UInt16) {
        defaults.set(Int(port), forKey: key)
    }
}
