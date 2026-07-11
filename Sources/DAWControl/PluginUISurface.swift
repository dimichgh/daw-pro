import Foundation

/// The plugin-UI-window control surface (M3 vi-b). These types live in
/// DAWControl (Foundation-only, engine-free) so the command router can validate
/// and route `plugin.*` without importing DAWEngine or AppKit; the concrete
/// `PluginUIControlling` implementation is installed by DAWApp at startup (the
/// `copilotEngine`/`appCommandHandler` two-phase precedent). When no
/// implementation is installed (a headless control session), open/close fail
/// with a readable error and `listOpenUIs` answers honestly with an empty list.

/// Which live hosted-AU instance a plugin window addresses. Carries the track
/// id for both cases (effect windows want it for the display title) — the
/// control-surface twin of DAWEngine's `HostedAUEndpoint`, which keys effects by
/// id alone.
public enum PluginUITarget: Hashable, Sendable {
    case instrument(trackID: UUID)
    case effect(trackID: UUID, effectID: UUID)

    /// The addressed track for both shapes.
    public var trackID: UUID {
        switch self {
        case .instrument(let trackID): return trackID
        case .effect(let trackID, _): return trackID
        }
    }

    /// The addressed effect, or nil for an instrument window.
    public var effectID: UUID? {
        switch self {
        case .instrument: return nil
        case .effect(_, let effectID): return effectID
        }
    }
}

/// A snapshot of one open plugin window, mirrored 1:1 into the `plugin.openUI` /
/// `plugin.listOpenUIs` wire result.
public struct PluginUIWindowInfo: Sendable {
    /// How the window's body was resolved: `custom` = the plugin's own vendor
    /// view, `generic` = the system parameter view (`AUGenericViewController`).
    public enum BodyKind: String, Sendable {
        case custom
        case generic
    }

    /// The window's actual frame in top-left-origin screen points (the
    /// agent-friendly convention) — always the REAL frame, which makes captures
    /// deterministic.
    public struct Frame: Sendable {
        public var x: Double
        public var y: Double
        public var width: Double
        public var height: Double

        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x
            self.y = y
            self.width = width
            self.height = height
        }
    }

    public var trackID: UUID
    public var effectID: UUID?                       // nil = instrument window
    public var title: String                         // "DLSMusicDevice — Keys"
    public var componentName: String
    public var manufacturerName: String
    public var isV3: Bool
    public var body: BodyKind
    public var frame: Frame
    public var warning: String?

    public init(trackID: UUID, effectID: UUID?, title: String,
                componentName: String, manufacturerName: String, isV3: Bool,
                body: BodyKind, frame: Frame, warning: String? = nil) {
        self.trackID = trackID
        self.effectID = effectID
        self.title = title
        self.componentName = componentName
        self.manufacturerName = manufacturerName
        self.isV3 = isV3
        self.body = body
        self.frame = frame
        self.warning = warning
    }
}

/// The app-layer seam the `plugin.*` commands route through. `@MainActor`: the
/// implementation owns `NSPanel`s and touches the live AU on the main actor. The
/// reference never leaves that isolation domain, so no `AUAudioUnit` ever
/// crosses an actor boundary (Swift 6 sendability is satisfied by construction —
/// design §2.3).
@MainActor
public protocol PluginUIControlling: AnyObject {
    /// Opens (or focuses) the window for an already-validated target. `x`/`y`
    /// pin the top-left origin in screen points; nil = a deterministic cascade.
    /// Throws a `LocalizedError` (surfaced verbatim by the router) when the
    /// registry has no ready instance or an open is already in flight for the
    /// target. `alreadyOpen` is true when the call focused an existing window.
    func openUI(_ target: PluginUITarget, x: Double?, y: Double?) async throws
        -> (info: PluginUIWindowInfo, alreadyOpen: Bool)

    /// True if a window was open and is now closed; false = an honest no-op
    /// (idempotent close — the target may already be gone).
    func closeUI(_ target: PluginUITarget) -> Bool

    /// Every currently open plugin window, in open order.
    func listOpenUIs() -> [PluginUIWindowInfo]
}
