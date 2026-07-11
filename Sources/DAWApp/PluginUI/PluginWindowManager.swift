import AVFAudio
import AppKit
import AudioToolbox
import DAWAppKit
import DAWControl
import DAWCore
import DAWEngine
import Foundation

/// Owns the app's floating plugin windows (M3 vi-b) and implements the DAWControl
/// `PluginUIControlling` seam that `plugin.*` routes through. One window per live
/// hosted-AU instance (reopen = focus); the ONLY invalidation authority is the
/// engine's registry-release callback (`hostedAUReleased`) — the manager never
/// watches `ProjectStore`, so there is a single source of truth for teardown.
///
/// `@MainActor` throughout: it reads the live `AUAudioUnit` off the concrete
/// engine and drives AppKit — the reference is produced and consumed inside one
/// isolation domain, so nothing crosses an actor boundary (design §2.3).
@MainActor
final class PluginWindowManager: PluginUIControlling {
    private let engine: AudioEngine
    private let store: ProjectStore

    private var ledger = PluginWindowLedger()
    private var controllers: [PluginWindowLedger.Key: PluginPanelController] = [:]
    /// Targets whose open is resolving right now — a concurrent open for the
    /// same target fails honestly rather than racing two `requestViewController`
    /// calls (design §4.4). Trivially satisfied in vi-b-1 (the generic-body
    /// resolve is synchronous), kept for the vendor-view cycle.
    private var pendingOpens: Set<PluginWindowLedger.Key> = []

    /// Body sizing bounds (design §4.2) — owned by `PluginPanelController` so the
    /// open-time clamp and the resize-follow clamp share one source of truth.
    private static let defaultBodySize = PluginPanelController.defaultBodySize
    private static let minBodySize = PluginPanelController.minBodySize

    init(engine: AudioEngine, store: ProjectStore) {
        self.engine = engine
        self.store = store
    }

    // MARK: - PluginUIControlling

    func openUI(_ target: PluginUITarget, x: Double?, y: Double?) async throws
        -> (info: PluginUIWindowInfo, alreadyOpen: Bool) {
        let key = Self.ledgerKey(for: target)
        let liveAU = liveAudioUnit(for: target)

        // Reopen: a window already exists for this target.
        if let controller = controllers[key] {
            let stamp = liveAU.map(ObjectIdentifier.init)
            if !ledger.isStale(key, liveStamp: stamp) {
                controller.focus()
                return (controller.currentInfo(), true)
            }
            // Belt-and-braces: the instance was swapped between the release
            // callback and this command — close the stale window, open fresh.
            controller.close()
        }

        // A window needs a ready instance.
        guard let au = liveAU else {
            throw PluginWindowError.notReady(status: status(for: target))
        }
        guard !pendingOpens.contains(key) else {
            throw PluginWindowError.alreadyOpening
        }
        pendingOpens.insert(key)
        defer { pendingOpens.remove(key) }

        // The full view-resolution ladder (design §3.2): custom v3 view →
        // custom v2 CocoaUI view → generic body. Always resolves (never fails);
        // a timeout/partial-failure carries a `warning`. Awaits step 1's
        // `requestViewController` — `pendingOpens` above serializes per target.
        let resolved = await AUViewResolver.resolve(au)
        let facts = displayFacts(for: target, au: au)

        // Geometry — all in top-left-origin screen points (the wire convention).
        let screen = NSScreen.main ?? NSScreen.screens.first
        let screenFrame = screen?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let visibleTopLeft = Self.visibleTopLeft(screenFrame: screenFrame,
                                                 visibleFrame: screen?.visibleFrame ?? screenFrame)
        // Preferred body size: v3 `preferredContentSize`, else the resolved
        // view's own frame, else the 480×320 default (design §4.2).
        let windowSize = Self.windowSize(
            forBody: PluginPanelController.preferredBodySize(for: resolved.viewController),
            visible: visibleTopLeft)
        let requestedOrigin: CGPoint = (x != nil && y != nil)
            ? CGPoint(x: x!, y: y!)
            : ledger.cascadeOrigin(visibleTopLeft: visibleTopLeft)
        let origin = Self.clamp(origin: requestedOrigin, size: windowSize, within: visibleTopLeft)
        let frameRect = Self.appKitFrame(topLeftOrigin: origin, size: windowSize,
                                         screenFrame: screenFrame)

        var info = PluginUIWindowInfo(
            trackID: target.trackID, effectID: target.effectID,
            title: facts.title, componentName: facts.componentName,
            manufacturerName: facts.manufacturerName, isV3: facts.isV3,
            body: resolved.body,
            frame: PluginUIWindowInfo.Frame(x: Double(origin.x), y: Double(origin.y),
                                            width: Double(windowSize.width),
                                            height: Double(windowSize.height)),
            warning: resolved.warning)

        let controller = PluginPanelController(
            key: key, info: info, chromeSubtitle: facts.subtitle,
            bodyViewController: resolved.viewController,
            frameRect: frameRect, referenceScreenFrame: screenFrame)
        controller.onClose = { [weak self] key in self?.didCloseWindow(key) }
        controllers[key] = controller

        let topLeft = controller.topLeftFrame
        ledger.open(key, stamp: ObjectIdentifier(au),
                    frame: CGRect(x: topLeft.x, y: topLeft.y,
                                  width: topLeft.width, height: topLeft.height))
        controller.focus()

        info.frame = topLeft   // the ACTUAL frame after any AppKit adjustment
        return (info, false)
    }

    func closeUI(_ target: PluginUITarget) -> Bool {
        let key = Self.ledgerKey(for: target)
        guard let controller = controllers[key] else { return false }
        controller.close()   // → windowWillClose → didCloseWindow
        return true
    }

    func listOpenUIs() -> [PluginUIWindowInfo] {
        ledger.orderedKeys.compactMap { controllers[$0]?.currentInfo() }
    }

    // MARK: - Invalidation (the single source of truth)

    /// The engine's registry-release callback: the live instance behind this
    /// endpoint just went away (effect/track removal, instrument switch, project
    /// open/new, config re-prepare), so its window closes in the SAME main-actor
    /// turn — before `deallocateRenderResources`. A no-op when no window is open.
    func hostedAUReleased(_ endpoint: HostedAUEndpoint) {
        let key: PluginWindowLedger.Key
        switch endpoint {
        case .instrument(let trackID): key = .instrument(trackID: trackID)
        case .effect(let effectID): key = .effect(effectID: effectID)
        }
        controllers[key]?.close()
    }

    /// The single close path — `windowWillClose` for button / ⌘W / manager close
    /// all converge here.
    private func didCloseWindow(_ key: PluginWindowLedger.Key) {
        controllers[key] = nil
        ledger.close(key)
        pendingOpens.remove(key)
    }

    // MARK: - Capture support (debug.captureUI target:plugin)

    /// The panel for a target, or nil when no window is open — the
    /// `debug.captureUI {target:"plugin"}` seam.
    func panel(forTrackID trackID: UUID, effectID: UUID?) -> NSPanel? {
        let key: PluginWindowLedger.Key = effectID.map { .effect(effectID: $0) }
            ?? .instrument(trackID: trackID)
        return controllers[key]?.panel
    }

    // MARK: - Live instance + status

    private func liveAudioUnit(for target: PluginUITarget) -> AUAudioUnit? {
        switch target {
        case .instrument(let trackID):
            return engine.hostedInstrumentAudioUnit(forTrack: trackID)
        case .effect(_, let effectID):
            return engine.hostedEffectAudioUnit(forEffect: effectID)
        }
    }

    private func status(for target: PluginUITarget) -> AudioUnitTrackStatus? {
        switch target {
        case .instrument(let trackID):
            return engine.audioUnitStatus(forTrack: trackID)
        case .effect(_, let effectID):
            return engine.audioUnitEffectStatus(forEffect: effectID)
        }
    }

    // MARK: - Display facts

    private struct DisplayFacts {
        var title: String            // "Component — Track"
        var componentName: String
        var manufacturerName: String
        var subtitle: String         // "Track · Manufacturer"
        var isV3: Bool
    }

    private func displayFacts(for target: PluginUITarget, au: AUAudioUnit) -> DisplayFacts {
        let track = store.tracks.first { $0.id == target.trackID }
        let trackName = track?.name ?? "Track"
        let config: AudioUnitConfig?
        switch target {
        case .instrument:
            config = track?.instrument?.audioUnit
        case .effect(_, let effectID):
            config = track?.effects.first { $0.id == effectID }?.audioUnit
        }
        // Prefer the captured display facts; fall back to the live AU's own names.
        let componentName = config?.name.nonEmptyOrNil
            ?? au.audioUnitName?.nonEmptyOrNil ?? "Audio Unit"
        let manufacturerName = config?.manufacturerName.nonEmptyOrNil
            ?? au.manufacturerName?.nonEmptyOrNil ?? ""
        let isV3 = au.componentDescription.componentFlags
            & AudioComponentFlags.isV3AudioUnit.rawValue != 0
        let subtitle = manufacturerName.isEmpty ? trackName : "\(trackName) · \(manufacturerName)"
        return DisplayFacts(
            title: "\(componentName) — \(trackName)",
            componentName: componentName, manufacturerName: manufacturerName,
            subtitle: subtitle, isV3: isV3)
    }

    // MARK: - Keys + geometry (top-left-origin screen points)

    static func ledgerKey(for target: PluginUITarget) -> PluginWindowLedger.Key {
        switch target {
        case .instrument(let trackID): return .instrument(trackID: trackID)
        case .effect(_, let effectID): return .effect(effectID: effectID)
        }
    }

    /// The screen's visible frame expressed in top-left origin (y measured down
    /// from the screen's top edge; the menu-bar/dock gap becomes `minY`).
    private static func visibleTopLeft(screenFrame: CGRect, visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.minX - screenFrame.minX,
               y: screenFrame.maxY - visibleFrame.maxY,
               width: visibleFrame.width, height: visibleFrame.height)
    }

    /// Body preferred size (view frame if non-zero, else 480×320), clamped to
    /// [320×180, visible − chrome]; the returned WINDOW size adds the chrome.
    private static func windowSize(forBody raw: CGSize, visible: CGRect) -> CGSize {
        let chrome = PluginPanelController.chromeHeight
        let bodyW = raw.width > 1 ? raw.width : defaultBodySize.width
        let bodyH = raw.height > 1 ? raw.height : defaultBodySize.height
        let maxW = max(minBodySize.width, visible.width)
        let maxH = max(minBodySize.height, visible.height - chrome)
        let clampedW = min(max(bodyW, minBodySize.width), maxW)
        let clampedH = min(max(bodyH, minBodySize.height), maxH)
        return CGSize(width: clampedW, height: clampedH + chrome)
    }

    /// Clamps a top-left origin so the window stays inside the visible area.
    private static func clamp(origin: CGPoint, size: CGSize, within visible: CGRect) -> CGPoint {
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return CGPoint(x: min(max(origin.x, visible.minX), maxX),
                       y: min(max(origin.y, visible.minY), maxY))
    }

    /// Top-left origin + size → the AppKit (bottom-left) window frame on the
    /// reference screen. The exact inverse of `PluginPanelController.topLeftFrame`.
    private static func appKitFrame(topLeftOrigin: CGPoint, size: CGSize,
                                    screenFrame: CGRect) -> CGRect {
        CGRect(x: screenFrame.minX + topLeftOrigin.x,
               y: screenFrame.maxY - topLeftOrigin.y - size.height,
               width: size.width, height: size.height)
    }
}

/// The manager's open-failure taxonomy (design §5.3). `LocalizedError` so the
/// router surfaces `errorDescription` verbatim.
enum PluginWindowError: LocalizedError {
    case notReady(status: AudioUnitTrackStatus?)
    case alreadyOpening

    var errorDescription: String? {
        switch self {
        case .notReady(let status):
            switch status {
            case .pending:
                return "Audio Unit is not ready (status: pending) — retry once prepared"
            case .missing:
                return "Audio Unit is not ready (status: missing)"
            case .failed(let reason):
                return "Audio Unit is not ready (status: failed: \(reason))"
            case .ready, .none:
                return "Audio Unit is not ready (status: unknown)"
            }
        case .alreadyOpening:
            return "plugin UI for this target is already opening"
        }
    }
}

private extension String {
    var nonEmptyOrNil: String? { isEmpty ? nil : self }
}
