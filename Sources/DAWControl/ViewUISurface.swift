import Foundation

/// The agent-facing VIEW surface (M35) — the typed app-layer seam the four
/// `view.*` commands route through. These types live in DAWControl
/// (Foundation-only, engine-free, AppKit-free) so the command router can
/// validate and route `view.capture` / `view.selectClip` / `view.panelLayout` /
/// `view.openEditor` without importing AppKit, SwiftUI or DAWEngine
/// (`Package.swift`: DAWControl depends on DAWCore + AIServices only and must
/// stay headless-testable). The concrete implementation is installed by DAWApp
/// at startup onto `CommandRouter.viewUI` — the `PluginUIControlling`
/// (`plugin.*`, M3 vi-b) and `EditPasteControlling` (`edit.pasteClips`, m26-k)
/// precedent, verbatim.
///
/// ⭐ **THE GAP THIS CLOSES IS MEASURED.** An agent driving DAW Pro over MCP can
/// MUTATE the project but cannot LOOK at it: everything it knows about the UI it
/// infers. The four capabilities already worked — as app-tier `debug.*` staging
/// seams deliberately off `allCommands` and off MCP. M35 promotes them to
/// production; `debug.*` is kept BYTE-FOR-BYTE (additive-only is a hard rule)
/// and the two tiers share ONE implementation inside `AppModel`.
///
/// ⚠️ **HEADLESS FAILS LOUDLY, ON EVERY ONE OF THE FOUR.** The router guards
/// `viewUI` and throws rather than returning an empty success — and
/// `view.capture` deliberately does NOT inherit `debug.captureUI`'s
/// `ImageRenderer` fallback: a 1280×800 PNG whose every ScrollView rasterizes
/// blank is a success that means nothing, which is precisely this tree's
/// characteristic failure mode. `plugin.listOpenUIs`' `{available:false}` shape
/// is NOT copied here for the same reason — there is no honest empty answer to
/// "show me the app" when there is no app.

/// A rectangle in POINTS, top-left origin — four Doubles rather than a `CGRect`,
/// because `CGRect` is CoreGraphics and this module imports Foundation only
/// (`PluginUIWindowInfo.Frame`'s reason, verbatim).
public struct ViewRect: Sendable {
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

/// What `view.capture` actually rasterized. Mirrors `debug.captureUI`'s window
/// path 1:1 — `width`/`height` are PIXELS, `rect` is the POINTS they cover and
/// `scale` the backing factor pixels-per-point, so a caller converting a point
/// into an image row never has to assume either (m23-ag).
public struct ViewCaptureResult: Sendable {
    /// Where the PNG was written.
    public var path: String
    public var width: Int
    public var height: Int
    /// Always `"window"` — the ONLY method `view.capture` will report, and the
    /// reason it is present anyway is that `debug.captureUI` can answer
    /// `"imageRenderer"` or `"plugin"` here and a shared reader must not have to
    /// guess which tier produced a payload.
    public var method: String
    public var rect: ViewRect
    public var scale: Double
    /// Whether the app was frontmost when the shot was taken (m23-ds — the
    /// capture states its own focus ambient, so a later "why did these two
    /// bytes move" question can be asked BACKWARD instead of forensically).
    public var appActive: Bool

    public init(path: String, width: Int, height: Int, method: String,
                rect: ViewRect, scale: Double, appActive: Bool) {
        self.path = path
        self.width = width
        self.height = height
        self.method = method
        self.rect = rect
        self.scale = scale
        self.appActive = appActive
    }
}

/// What `view.selectClip` actually did — and, when it did not open an editor,
/// WHY NOT, in a machine-readable term.
///
/// ⭐ **THE HONEST-`reason` RULE (m35-c) IS THE POINT OF THIS TYPE.** Selecting
/// an AUDIO clip succeeds — the arrange selection moves, the clip lights up —
/// and opens NO piano roll, because there is no piano roll for audio. Reporting
/// that as a bare success would hand an agent a capture it cannot explain and a
/// belief it cannot check. So the reply says which of the three things happened.
public struct ViewSelectClipResult: Sendable {
    /// Why the piano roll is, or is not, on screen for the clip just selected.
    public enum Reason: String, Sendable {
        /// A MIDI clip in the Arrange workspace: the roll is mounted on it.
        case pianoRollOpened = "piano-roll-opened"
        /// An AUDIO clip. It IS selected — but audio has no note editor, so
        /// nothing opened. Not an error; a different surface.
        case audioClipHasNoEditor = "audio-clip-has-no-editor"
        /// A MIDI clip, selected, but the window is showing the MIX console —
        /// the roll's mount point is the Arrange workspace, so it is not on
        /// screen. Call `view.panelLayout {workspace:"arrange"}` and it will be.
        case workspaceIsNotArrange = "workspace-is-not-arrange"
    }

    /// The clip now focused (always the id that was asked for — a selection
    /// mints nothing).
    public var clipID: UUID
    /// The track it lives on.
    public var trackID: UUID
    /// `"midi"` or `"audio"` — the term `reason` turns on, stated separately so
    /// a caller does not have to parse the reason to learn it.
    public var clipKind: String
    /// Whether the piano roll is ACTUALLY mounted on this clip. Derived from
    /// `AppModel.openEditorClip` (the tree's ONE rule for "is the roll on
    /// screen") plus the workspace term — never from `clip.isMIDI` directly, so
    /// the reply and the screen cannot diverge.
    public var editorOpen: Bool
    public var reason: Reason
    /// The workspace the window is showing right now (`"arrange"` / `"mix"`).
    public var workspace: String

    public init(clipID: UUID, trackID: UUID, clipKind: String,
                editorOpen: Bool, reason: Reason, workspace: String) {
        self.clipID = clipID
        self.trackID = trackID
        self.clipKind = clipKind
        self.editorOpen = editorOpen
        self.reason = reason
        self.workspace = workspace
    }
}

/// The post-apply echo of `view.panelLayout` — the two production-tier layout
/// controls plus the one read-only value that proves the restore contract.
///
/// ⚠️ **EXACTLY TWO SETTABLE KEYS, AND THE NARROWNESS IS THE DESIGN.**
/// `docs/DESIGN-LANGUAGE.md` records adjustable window layout as a documented
/// NON-INVOKABLE preference with no wire command, and `setPanelLayout`'s comment
/// block cites that rule. M35 NARROWS the rule, it does not repeal it:
/// `workspace` and `editorMaximized` are the two controls that determine WHAT A
/// CAPTURE CAN SEE — which surface is on screen, and whether the editor is
/// filling the window — so an agent that can capture must be able to set them or
/// the capture verb is half a capability. Sidebar width, arrange and piano-roll
/// row heights, zoom, minimap, waveform scaling and note audition stay
/// debug-tier chrome: they change what a human's eye prefers, not what exists to
/// be seen, and `debug.panelLayout` remains their one home.
public struct ViewPanelLayoutResult: Sendable {
    public var workspace: String
    public var editorMaximized: Bool
    /// Read-only, echoed BESIDE `editorMaximized` on purpose (the m25-b-1
    /// contract): the two are INDEPENDENT — maximize never writes the fraction —
    /// so one round trip proves the restore contract.
    public var editorFraction: Double

    public init(workspace: String, editorMaximized: Bool, editorFraction: Double) {
        self.workspace = workspace
        self.editorMaximized = editorMaximized
        self.editorFraction = editorFraction
    }
}

/// Which editor `view.openEditor` should put on screen.
public enum ViewEditorTarget: Sendable {
    /// A track's INSTRUMENT editor. Which one opens follows the instrument's own
    /// kind — the app resolves it; the caller does not have to know whether the
    /// track plays the built-in Poly Synth, the Sampler, or a hosted Audio Unit.
    case instrument(trackID: UUID)
    /// One INSERT EFFECT's editor. `trackID == nil` addresses the MASTER chain
    /// (the `fx.*` / `debug.effectEditor` `"master"` sentinel, decoded by the
    /// router so this type carries no magic string).
    case effect(trackID: UUID?, effectID: UUID)
}

/// What `view.openEditor` opened.
public struct ViewEditorResult: Sendable {
    /// Which editor surface is now up. A CLOSED set with no `other` member: a
    /// new instrument or effect kind must be routed deliberately rather than
    /// falling into a bucket that tells an agent nothing.
    public enum Editor: String, Sendable {
        /// The built-in Poly Synth card.
        case polySynth = "poly-synth"
        /// The built-in Sampler card.
        case sampler = "sampler"
        /// A built-in effect card (EQ, compressor, …) in the Mix workspace.
        case builtInEffect = "built-in-effect"
        /// A hosted Audio Unit's own floating window — DELEGATED to the shipped
        /// `plugin.*` seam rather than reimplemented, so there is exactly one
        /// code path that ever materializes an AU window. `pluginWindow` carries
        /// the same payload `plugin.openUI` returns.
        case pluginWindow = "plugin-window"
    }

    public var editor: Editor
    /// The track whose editor opened; nil only for a MASTER-chain effect.
    public var trackID: UUID?
    /// The effect whose editor opened; nil for an instrument editor.
    public var effectID: UUID?
    /// A human-readable name for what opened ("Poly Synth", "DLSMusicDevice", …).
    public var title: String
    /// Non-nil exactly when `editor == .pluginWindow`.
    public var pluginWindow: PluginUIWindowInfo?
    /// True when the call FOCUSED something already open rather than opening it.
    /// Only an AU window can report this honestly (the in-app cards have no
    /// separate window to focus), so it is false for the three built-in kinds.
    public var alreadyOpen: Bool

    public init(editor: Editor, trackID: UUID?, effectID: UUID?, title: String,
                pluginWindow: PluginUIWindowInfo? = nil, alreadyOpen: Bool = false) {
        self.editor = editor
        self.trackID = trackID
        self.effectID = effectID
        self.title = title
        self.pluginWindow = pluginWindow
        self.alreadyOpen = alreadyOpen
    }
}

/// The app-layer seam the `view.*` commands route through — the
/// `PluginUIControlling` precedent verbatim. `@MainActor`: every implementation
/// touches `NSWindow`, `ProjectStore`, `ArrangeSelection` and `PanelLayoutStore`,
/// all main-actor-only. The reference never leaves that isolation domain, so no
/// AppKit object ever crosses an actor boundary and Swift 6 sendability is
/// satisfied by construction.
@MainActor
public protocol ViewUIControlling: AnyObject {
    /// Rasterizes the app's real window content to a PNG. `path` nil = an
    /// auto-named file under `NSTemporaryDirectory()/DAWPro`.
    ///
    /// ⚠️ **THROWS when there is no drawable window** — it never falls back to
    /// an offscreen `ImageRenderer` pass. `debug.captureUI` keeps that fallback;
    /// this tier does not, because the fallback cannot draw NSScrollView-backed
    /// content, so the track rows, the timeline clips and the piano-roll grid —
    /// everything a caller asked to SEE — come out blank while the call reports
    /// success.
    ///
    /// ⚠️ **`async` FOR ONE REASON: THE BOUNDED LAYOUT FLUSH (m35-f).** The
    /// implementation must let a SwiftUI update scheduled by an EARLIER wire
    /// request actually draw before it photographs the window, and the only way
    /// to do that is to RELEASE the main actor — a nested `RunLoop.main.run`
    /// cannot, because the caller is itself occupying the main actor while it
    /// spins — measured with the arm positive-controlled: a spin instrumented at
    /// 2349 ms of real wall time changed the captured frame by ZERO bytes.
    /// See `flushPendingViewUpdates()` in `ViewUIWireSurface.swift`.
    func captureView(path: String?) async throws -> ViewCaptureResult

    /// Focuses one clip, opening the piano roll on it when the clip and the
    /// workspace both permit. Throws when `clipID` names no clip in the project
    /// (a caller error, reported readably); every other outcome is a success
    /// carrying an honest `reason`.
    func selectClipForView(_ clipID: UUID) throws -> ViewSelectClipResult

    /// Applies the two production-tier layout controls and echoes the result. A
    /// call with BOTH arguments nil is READ-ONLY (the m11-a bare-call law, which
    /// `debug.panelLayout` already obeys). `workspace` has already been
    /// validated against the workspace vocabulary by the router.
    func applyViewPanelLayout(workspace: String?, editorMaximized: Bool?)
        -> ViewPanelLayoutResult

    /// Opens the editor for an instrument or an insert effect, dispatching on
    /// the target's own kind and DELEGATING every hosted-Audio-Unit case to the
    /// `plugin.*` window seam. Throws readably when the target does not exist or
    /// carries no editable unit.
    func openViewEditor(_ target: ViewEditorTarget) async throws -> ViewEditorResult
}
