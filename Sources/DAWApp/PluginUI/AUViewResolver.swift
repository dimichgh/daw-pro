import AVFAudio
import AppKit
import AudioToolbox
import AudioToolbox.AUCocoaUIView   // the `AUCocoaUIBase` factory protocol (macOS-only)
import CoreAudioKit
import DAWControl
import DAWCore
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

    /// Bridges `requestViewController` to an async main-actor result, raced against a
    /// REAL wall-clock deadline (`DAWCore.DeadlineRace`, m23-at).
    ///
    /// The deadline runs on `Task.detached` inside `DeadlineRace`, so it fires on wall
    /// time regardless of main-actor contention — the defect m23-au removed. `DeadlineRace`
    /// also cancels its own deadline task when the work wins, so a successful open no
    /// longer leaves a task sleeping out the full 5 s.
    ///
    /// `requestViewController()` is the SDK's ASYNC import of
    /// `requestViewController(completionHandler:)`. Using it rather than the
    /// completion-handler form is load-bearing, not cosmetic:
    ///  · it removes the hand-rolled inner continuation, so there is no continuation this
    ///    file could orphan when the deadline wins (m23-au §3);
    ///  · the header contract (`CoreAudioKit/AUViewController.h`: the completion may run on
    ///    ANY thread) is still honoured — the async thunk copies the VC POINTER out of the
    ///    completion on whatever thread it ran on and resumes this task, and this task is
    ///    `@MainActor`, so the first USE of the value is already on the main actor. That is
    ///    the same guarantee the old hand-written `Task { @MainActor in … }` hop gave, now
    ///    given by the language instead of by a comment;
    ///  · a DIRECT completion-handler call in an `async` function emits "consider using
    ///    asynchronous alternative function", which the 0-warning build would reject.
    ///    ⚠️ MEASURED, m23-au: that check is NARROW and does NOT protect this shape.
    ///    Wrapping the same call in a `withCheckedContinuation` body closure emits
    ///    NOTHING — which is precisely why the pre-m23-au code here built warning-free
    ///    with the defect present. The build cannot catch a regression to that shape;
    ///    `AUViewResolverDeadlineSiteTests` leg S4 is what does.
    ///
    /// ⚠️ Do NOT reintroduce a local timeout, gate, or continuation here. `DeadlineRace`
    /// is the ONE home for this decision (m23-at/m23-au); this file was the last
    /// hand-rolled sleep-then-resume race in `Sources/`.
    ///
    /// ⚠️ Concurrency note, CORRECTED by m23-au: `PluginWindowManager.pendingOpens`
    /// serializes `openUI` CALLS per target, which is NOT the same as serializing
    /// outstanding view requests. Now that the deadline really fires, a timed-out request
    /// is still in flight when `openUI` returns, and the user can immediately reopen — so
    /// two `requestViewController` calls CAN be outstanding on one AU. Each resolves into
    /// its own abandoned task and its result is discarded; nothing here is shared between
    /// them. See m23-au §8.4.
    @MainActor
    static func requestViewControllerOnMain(_ au: AUAudioUnit,
                                            timeout: Duration) async -> RequestOutcome {
        let outcome = await DeadlineRace.run(timeout: timeout) { @MainActor in
            await au.requestViewController()
        }
        switch outcome {
        case .value(let vc):
            return .viewController(vc)
        case .timedOut:
            return .timedOut
        case .error(let error):
            // Unreachable: `requestViewController()` is non-throwing, so `DeadlineRace`
            // cannot produce `.error` here. Handled rather than force-unwrapped because
            // the ladder is TOTAL (design §3.2) — fall through to steps 2/3 exactly as a
            // unit with no custom v3 view does, and say so on stderr rather than
            // mislabelling it a timeout in the user-facing warning.
            FileHandle.standardError.write(Data(
                "AUViewResolver: requestViewController surfaced an unexpected error (\(error)) — falling through to the ladder\n".utf8))
            return .viewController(nil)
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
