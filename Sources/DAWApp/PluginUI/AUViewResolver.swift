import AVFAudio
import AppKit
import AudioToolbox
import AudioToolbox.AUCocoaUIView   // the `AUCocoaUIBase` factory protocol (macOS-only)
import CoreAudioKit
import DAWControl
import DAWEngine

/// Resolves the body view for one hosted `AUAudioUnit`'s plugin window via the
/// full, never-failing ladder (design §3.2):
///
///  1. `requestViewController` raced against a 5 s timeout → the plugin's own
///     custom **v3** view controller.
///  2. if the unit is an `AUAudioUnitV2Bridge` and advertises a
///     `kAudioUnitProperty_CocoaUI` view (`AUViewProbe`, DAWEngine), load the
///     factory bundle, build the `AUCocoaUIBase` view → the custom **v2** view.
///  3. `AUGenericViewController` (CoreAudioKit, macOS 13+) → the generic
///     parameter body. This step is a plain init + one property set, so it
///     cannot throw or return nil — which makes `plugin.openUI` total for any
///     `.ready` instance.
///
/// A timeout at step 1, or a partial failure at step 2, degrades to the generic
/// body and carries a readable `warning` instead of failing (the ladder is
/// total). The vendor/generic body is accepted as-is — it will not match the
/// glass theme; that is expected and correct.
@MainActor
enum AUViewResolver {
    struct Resolved {
        let viewController: NSViewController
        let body: PluginUIWindowInfo.BodyKind
        /// Non-nil when a vendor-view leg degraded to the generic body: a step-1
        /// timeout or a step-2 partial failure appends a readable note.
        let warning: String?
    }

    /// The ceiling for a custom-view request (design §3.3): a stalled extension
    /// degrades to the generic body + warning rather than wedging the main actor.
    static let requestTimeout: Duration = .seconds(5)

    /// The preferred size handed to the v2 factory (`uiViewForAudioUnit:withSize:`
    /// is a hint the vendor may ignore; the window later sizes to the returned
    /// view's own frame — see `PluginPanelController.preferredBodySize`).
    private static let v2PreferredSize = NSSize(width: 480, height: 320)

    /// Runs the full ladder. Async because step 1 awaits `requestViewController`.
    static func resolve(_ au: AUAudioUnit) async -> Resolved {
        var warning: String?

        // Step 1 — v3 custom view controller (raced against the 5 s timeout).
        switch await requestViewControllerOnMain(au, timeout: requestTimeout) {
        case .viewController(let vc?):
            return Resolved(viewController: vc, body: .custom, warning: nil)
        case .viewController(nil):
            break   // no custom v3 view — the normal answer for a v2 unit; fall through
        case .timedOut:
            warning = "custom view request timed out after 5s"
        }

        // Step 2 — v2 CocoaUI vendor view (bridged units only).
        if let bridge = au as? AUAudioUnitV2Bridge {
            switch loadCocoaView(bridge: bridge) {
            case .some(.success(let vc)):
                return Resolved(viewController: vc, body: .custom, warning: warning)
            case .some(.failure(let note)):
                warning = appendNote(warning, note)   // advertised a view but loading failed
            case .none:
                break   // no CocoaUI advertised — normal; fall through silently
            }
        }

        // Step 3 — generic body (cannot fail).
        let generic = AUGenericViewController()
        generic.auAudioUnit = au
        return Resolved(viewController: generic, body: .generic, warning: warning)
    }

    // MARK: - Step 1: requestViewController → main-actor bridge (design §3.3)

    enum RequestOutcome {
        case viewController(NSViewController?)
        case timedOut
    }

    /// Bridges `requestViewController`'s completion (which the SDK says may run on
    /// ANY thread — CoreAudioKit/AUViewController.h) to an async main-actor result,
    /// raced against a timeout with the same once-gate + unstructured-task idiom as
    /// `AUHostRegistry.raceAgainstTimeout`: a stalled extension can never wedge the
    /// main actor, and the gate resumes exactly once (a late completion is a no-op).
    ///
    /// Never call this twice concurrently for one AU — `PluginWindowManager`'s
    /// `pendingOpens` serializes opens per target.
    @MainActor
    static func requestViewControllerOnMain(_ au: AUAudioUnit,
                                            timeout: Duration) async -> RequestOutcome {
        await withCheckedContinuation { continuation in
            let gate = ResumeGate(continuation)
            au.requestViewController { vc in
                // Header contract: this closure may run on any thread. Hop the
                // sole `vc` reference to the main actor before ANY use — AppKit
                // objects are main-thread-only, and the nil-check happens after
                // the hop (in `resolve`'s switch). This toolchain already imports
                // the completion's VC as Sendable, so no explicit transfer
                // annotation is needed; the `@MainActor` hop still honors the
                // header's "may run off-main" contract. Nothing is marked Sendable.
                let transfer = vc
                Task { @MainActor in gate.resume(.viewController(transfer)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                gate.resume(.timedOut)
            }
        }
    }

    /// Resumes a continuation exactly once, main-actor confined (a `@MainActor`
    /// class is Sendable, so it may be captured by the completion closure and
    /// only ever touched inside the `@MainActor` hop).
    @MainActor
    private final class ResumeGate {
        private var continuation: CheckedContinuation<RequestOutcome, Never>?

        init(_ continuation: CheckedContinuation<RequestOutcome, Never>) {
            self.continuation = continuation
        }

        func resume(_ outcome: RequestOutcome) {
            continuation?.resume(returning: outcome)
            continuation = nil
        }
    }

    // MARK: - Step 2: v2 kAudioUnitProperty_CocoaUI vendor view (design §3.4)

    private enum CocoaViewLoad {
        case success(NSViewController)
        /// The unit advertised a custom view but a load step failed — a readable
        /// note appended to the warning (the ladder still resolves to generic).
        case failure(String)
    }

    /// Loads the advertised v2 Cocoa view. Returns nil when the unit advertises no
    /// CocoaUI at all (the common case — silent fall-through to generic); a
    /// `.failure` note only when it DID advertise one and a load step failed.
    private static func loadCocoaView(bridge: AUAudioUnitV2Bridge) -> CocoaViewLoad? {
        guard let info = AUViewProbe.cocoaViewInfo(bridge.audioUnit) else { return nil }
        guard let bundle = Bundle(url: info.bundleURL) else {
            return .failure("custom view bundle unavailable (\(info.bundleURL.lastPathComponent))")
        }
        // `classNamed(_:)` loads the bundle if needed and scopes the lookup to it.
        guard let factoryClass = bundle.classNamed(info.className) as? NSObject.Type else {
            return .failure("custom view factory '\(info.className)' not found in bundle")
        }
        guard let factory = factoryClass.init() as? AUCocoaUIBase else {
            return .failure("custom view factory '\(info.className)' is not an AUCocoaUIBase")
        }
        guard let view = factory.uiView(forAudioUnit: bridge.audioUnit,
                                        with: v2PreferredSize) else {
            return .failure("custom view factory '\(info.className)' returned no view")
        }
        // The factory returns the view autoreleased with the client owning the
        // retain (SDK AUCocoaUIView.h); `BodyHostViewController` holds it for the
        // window's lifetime.
        return .success(BodyHostViewController(vendorView: view))
    }

    // MARK: - Helpers

    private static func appendNote(_ warning: String?, _ note: String) -> String {
        guard let warning, !warning.isEmpty else { return note }
        return "\(warning); \(note)"
    }
}

/// Wraps a vendor v2 Cocoa `NSView` (from `AUCocoaUIBase.uiViewForAudioUnit:withSize:`)
/// as an `NSViewController` so the panel embeds it through the same VC path the
/// generic body uses. Retains the vendor view (the factory hands it back
/// autoreleased) and adopts its natural size as the preferred content size, so
/// the window opens at the vendor's own dimensions (design §4.2).
@MainActor
final class BodyHostViewController: NSViewController {
    private let vendorView: NSView

    init(vendorView: NSView) {
        self.vendorView = vendorView
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = vendorView.frame.size
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() { view = vendorView }
}
