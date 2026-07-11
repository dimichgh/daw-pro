import AppKit
import DAWAppKit
import DAWControl
import SwiftUI

/// One floating plugin window: an `NSPanel` with the glass chrome header above
/// the resolved body view, plus the `NSWindowDelegate` that reports every close
/// (button / ⌘W / manager-driven) back to `PluginWindowManager`. All
/// decision-shaped state lives in `PluginWindowLedger`; this class is the thin,
/// defensive AppKit slab around it.
@MainActor
final class PluginPanelController: NSObject, NSWindowDelegate {
    /// Fixed chrome height (design §4.2). The window frame is `bodySize.height +
    /// chromeHeight` tall.
    static let chromeHeight: CGFloat = 34

    /// Body sizing bounds (design §4.2), the single source shared with the
    /// manager's window-size clamp.
    static let defaultBodySize = CGSize(width: 480, height: 320)
    static let minBodySize = CGSize(width: 320, height: 180)

    /// The body's preferred size BEFORE clamping (design §4.2): a v3
    /// `preferredContentSize` if non-zero, else the resolved view's own
    /// `frame.size` if non-zero, else the 480×320 default the manager clamps
    /// against. `BodyHostViewController` seeds `preferredContentSize` from the
    /// vendor view's natural size, so v2 custom views land here too.
    static func preferredBodySize(for viewController: NSViewController) -> CGSize {
        let preferred = viewController.preferredContentSize
        if preferred.width > 1, preferred.height > 1 { return preferred }
        let viewSize = viewController.view.frame.size
        if viewSize.width > 1, viewSize.height > 1 { return viewSize }
        return defaultBodySize
    }

    let key: PluginWindowLedger.Key
    let panel: NSPanel

    /// Retained so the generic/vendor VC (and, through it, the AU) outlives the
    /// window it draws into.
    private let bodyViewController: NSViewController
    private let chromeHost: NSHostingView<PluginChromeHeader>
    private let title: String
    private let subtitle: String

    /// The static window facts (component/track/body/warning). The live frame is
    /// filled from the panel on every read — see `currentInfo()`.
    private let infoTemplate: PluginUIWindowInfo

    /// The reference screen's full AppKit frame, captured at creation, so the
    /// top-left ⇄ AppKit conversion round-trips exactly for the wire result.
    private let referenceScreenFrame: CGRect

    /// Fired on `windowWillClose` (any cause). The manager unregisters here — the
    /// single close path, so button/⌘W/manager close all converge.
    var onClose: ((PluginWindowLedger.Key) -> Void)?

    /// - Parameters:
    ///   - frameRect: the WHOLE window frame in AppKit (bottom-left) coordinates.
    ///   - referenceScreenFrame: the screen frame used to derive `frameRect`.
    init(key: PluginWindowLedger.Key,
         info: PluginUIWindowInfo,
         chromeSubtitle: String,
         bodyViewController: NSViewController,
         frameRect: CGRect,
         referenceScreenFrame: CGRect) {
        self.key = key
        self.title = info.componentName
        self.subtitle = chromeSubtitle
        self.infoTemplate = info
        self.bodyViewController = bodyViewController
        self.referenceScreenFrame = referenceScreenFrame

        let panel = NSPanel(
            contentRect: frameRect,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isReleasedWhenClosed = false      // the manager owns lifetime
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isMovableByWindowBackground = true
        panel.title = title
        self.panel = panel

        let host = NSHostingView(
            rootView: PluginChromeHeader(title: title, subtitle: subtitle, isKey: false))
        // Pin the chrome height entirely from the Auto Layout constraint below;
        // empty sizingOptions stop the hosting view from also imposing an intrinsic
        // height derived from the flexible SwiftUI frame. (The subtitle-row clipping
        // itself came from the titlebar safe-area inset — see `.ignoresSafeArea()`
        // in PluginChromeHeader.)
        host.sizingOptions = []
        self.chromeHost = host

        super.init()

        // contentView = [ chrome header (34 pt) | body ] stacked vertically.
        let container = NSView(frame: CGRect(origin: .zero, size: frameRect.size))
        let bodyView = bodyViewController.view
        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        bodyView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chromeHost)
        container.addSubview(bodyView)
        NSLayoutConstraint.activate([
            chromeHost.topAnchor.constraint(equalTo: container.topAnchor),
            chromeHost.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            chromeHost.heightAnchor.constraint(equalToConstant: Self.chromeHeight),
            bodyView.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            bodyView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bodyView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        panel.contentView = container
        panel.delegate = self
        // Pin the exact frame (fullSizeContentView makes content == frame, but a
        // titled window may still nudge on creation — force it so the wire's
        // returned frame echoes the requested origin exactly).
        panel.setFrame(frameRect, display: false)

        installBodyResizeFollow()
    }

    deinit {
        // Thread-safe and touches no isolated state — safe from a nonisolated deinit.
        NotificationCenter.default.removeObserver(self)
    }

    /// Brings the window to the front and makes it key. `orderFrontRegardless`
    /// covers a backgrounded app during wire-driven verification runs (the
    /// WindowGroup activation-hack reasoning).
    func focus() {
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Closes the panel — routes through `windowWillClose` → `onClose`.
    func close() {
        panel.close()
    }

    /// The window's CURRENT frame in top-left-origin screen points (what the
    /// wire returns) — the exact inverse of the `frameRect` conversion.
    var topLeftFrame: PluginUIWindowInfo.Frame {
        let f = panel.frame
        return PluginUIWindowInfo.Frame(
            x: Double(f.minX - referenceScreenFrame.minX),
            y: Double(referenceScreenFrame.maxY - f.maxY),
            width: Double(f.width),
            height: Double(f.height))
    }

    /// The window's info snapshot with its LIVE frame — used for `plugin.openUI`
    /// (open + reopen-focus) and each `plugin.listOpenUIs` entry.
    func currentInfo() -> PluginUIWindowInfo {
        var info = infoTemplate
        info.frame = topLeftFrame
        return info
    }

    // MARK: - Resize follow (v2 vendor views self-resize — design §4.2)

    /// Guards against the resize the observer itself triggers re-entering the
    /// handler: setting the panel frame resizes the edge-pinned body, which posts
    /// another `frameDidChange` — the guard makes the whole follow idempotent, so
    /// it can never loop.
    private var isFollowingBodyResize = false

    /// Observe the body view's own frame changes (a vendor v2 Cocoa view may
    /// resize itself after loading its real content). `preferredContentSize` KVO
    /// is out of scope for v1 (design §4.2).
    private func installBodyResizeFollow() {
        let bodyView = bodyViewController.view
        bodyView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(bodyFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification, object: bodyView)
    }

    @objc private func bodyFrameDidChange(_ notification: Notification) {
        guard !isFollowingBodyResize else { return }
        let bodySize = bodyViewController.view.frame.size
        guard bodySize.width > 1, bodySize.height > 1 else { return }

        // Desired WINDOW size = clamped body + chrome, within [min, visible − chrome].
        let visible = (panel.screen ?? NSScreen.main)?.visibleFrame ?? panel.frame
        let maxBodyW = max(Self.minBodySize.width, visible.width)
        let maxBodyH = max(Self.minBodySize.height, visible.height - Self.chromeHeight)
        let bodyW = min(max(bodySize.width, Self.minBodySize.width), maxBodyW)
        let bodyH = min(max(bodySize.height, Self.minBodySize.height), maxBodyH)
        let desired = CGSize(width: bodyW, height: bodyH + Self.chromeHeight)

        var frame = panel.frame
        guard abs(frame.width - desired.width) > 0.5
            || abs(frame.height - desired.height) > 0.5 else { return }
        // Keep the top-left corner pinned (grow/shrink downward) so the window
        // doesn't jump, then clamp the whole frame inside the visible area.
        let topLeftY = frame.maxY
        frame.size = desired
        frame.origin.y = topLeftY - desired.height
        frame = Self.clampWithinVisible(frame, visible: visible)

        isFollowingBodyResize = true
        panel.setFrame(frame, display: true)
        isFollowingBodyResize = false
    }

    private static func clampWithinVisible(_ frame: CGRect, visible: CGRect) -> CGRect {
        var f = frame
        f.origin.x = min(max(f.minX, visible.minX), max(visible.minX, visible.maxX - f.width))
        f.origin.y = min(max(f.minY, visible.minY), max(visible.minY, visible.maxY - f.height))
        return f
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        onClose?(key)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        updateChrome(isKey: true)
    }

    func windowDidResignKey(_ notification: Notification) {
        updateChrome(isKey: false)
    }

    private func updateChrome(isKey: Bool) {
        chromeHost.rootView = PluginChromeHeader(title: title, subtitle: subtitle, isKey: isKey)
    }
}
