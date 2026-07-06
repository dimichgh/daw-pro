import AppKit
import SwiftUI
import DAWCore
import DAWEngine
import DAWControl
import DAWAppKit

@main
struct DAWProApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(engine: model.engine, controlPort: model.controlServer.port)
                .environment(model.store)
                .environment(model)
                .onAppear {
                    // Running from `swift run` (no app bundle): become a real
                    // foreground app so the window shows and takes focus.
                    NSApplication.shared.setActivationPolicy(.regular)
                    NSApplication.shared.activate(ignoringOtherApps: true)
                }
        }
        .commands {
            FileCommands(store: model.store)
            EditCommands(store: model.store)
        }
    }
}

/// Which workspace the main window shows. Arrange is the timeline/edit surface;
/// Mix is the mixing console (M4 vi). Hoisted onto AppModel (like
/// `selectedClipID`) so `debug.captureUI` and the `ui.showMixer` control command
/// share the live window's mode.
enum WorkspaceMode: String, Sendable {
    case arrange
    case mix
}

@MainActor
@Observable
final class AppModel {
    let store: ProjectStore
    let engine: AudioEngine
    let controlServer: ControlServer
    let transportBroadcaster: TransportBroadcaster

    /// UI selection: the clip whose piano roll is open (nil = closed). Hoisted
    /// out of ContentView's @State so `debug.captureUI` renders with the same
    /// selection as the live window. Only MIDI clips open the editor.
    var selectedClipID: UUID?

    /// Active workspace (Arrange or Mix). Driven by the header toggle and by the
    /// `ui.showMixer` control command (for headless UI verification).
    var workspaceMode: WorkspaceMode = .arrange

    /// Arrange automation UI state (shared by the sidebar disclosure/picker and
    /// the timeline editor rows so both columns stay aligned). Driven by the
    /// track-header disclosure toggle and by the `ui.showAutomation` debug
    /// command (for headless UI verification).
    var expandedAutomationTrackIDs: Set<UUID> = []
    /// Which lane each track is editing (trackID → laneID); absent = its first.
    var automationLaneSelection: [UUID: UUID] = [:]

    /// Arrange take-lanes UI state (M5 iii-c): tracks whose takes section is
    /// expanded (shared by the sidebar disclosure and the timeline lane rows).
    /// Driven by the track-header takes glyph and the `ui.showTakes` debug command
    /// (headless UI verification). Only tracks with take groups draw the section.
    var expandedTakeTrackIDs: Set<UUID> = []

    /// Arrange grid snap for clip move/trim/split (arrange-header picker). Bar by
    /// default — the coarsest musical grid a beginner reaches for first.
    var clipSnap: ClipSnap = .bar

    /// Peak cache for audio-clip waveforms, shared across the window so a file is
    /// read off-main once and reused by every clip that windows it.
    let waveformStore = WaveformStore()

    /// Live offline-stretch render state per clip id (M5 ii-e), polled from the
    /// engine's pull-based `clipStretchStatus` so the timeline can shimmer a clip
    /// while its render is pending and flag a failure. Only non-idle clips appear
    /// here; a poll cycle runs after a stretch edit until everything settles.
    private(set) var clipStretchStatuses: [UUID: ClipStretchStatus] = [:]
    private var stretchPollTimer: Timer?
    private var stretchPollUntil: Date = .distantPast

    /// The clip's current render state (idle when absent). The timeline reads
    /// this per clip each redraw; the poller drives the redraws.
    func stretchStatus(for clipID: UUID) -> ClipStretchStatus {
        clipStretchStatuses[clipID] ?? .idle
    }

    /// Kicks a bounded poll cycle after a stretch edit: the engine debounces
    /// 250 ms then renders in the background, so we sample `clipStretchStatus` at
    /// 10 Hz for a grace window (catching the debounce → rendering → done arc) and
    /// stop once nothing is pending past the deadline.
    func noteStretchEdit() {
        stretchPollUntil = Date().addingTimeInterval(12)
        refreshStretchStatuses()
        guard stretchPollTimer == nil else { return }
        stretchPollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickStretchPolling() }
        }
    }

    private func tickStretchPolling() {
        refreshStretchStatuses()
        let anyRendering = clipStretchStatuses.values.contains { $0 == .rendering }
        if !anyRendering, Date() > stretchPollUntil {
            stretchPollTimer?.invalidate()
            stretchPollTimer = nil
        }
    }

    private func refreshStretchStatuses() {
        var next: [UUID: ClipStretchStatus] = [:]
        for track in store.tracks {
            for clip in track.clips where !clip.isMIDI {
                if let status = store.clipStretchStatus(trackID: track.id, clipID: clip.id),
                   status != .idle {
                    next[clip.id] = status
                }
            }
        }
        if next != clipStretchStatuses { clipStretchStatuses = next }
    }

    /// Retained so the app-command handler can be (re)installed; also kept alive
    /// alongside the server.
    private let router: CommandRouter

    /// Serial suffix for auto-named `debug.captureUI` files. MainActor-isolated
    /// (member of a @MainActor type), so incrementing it needs no lock.
    private static var captureCounter = 0

    init() {
        let store = ProjectStore()
        let engine = AudioEngine()
        store.engine = engine
        // Save-time Audio Unit state capture: each save/autosave refreshes
        // `.audioUnit` descriptors' stateData from the live AU (local copy
        // only — no model mutation, no undo entry, no dirty flip).
        store.instrumentStateProvider = { [weak engine] trackID in
            engine?.instrumentState(forTrack: trackID)
        }
        // The insert-effect mirror (M4 v): hosted AU effect state, keyed by
        // effect id, joins every save/autosave the same way.
        store.effectStateProvider = { [weak engine] effectID in
            engine?.effectState(forEffect: effectID)
        }
        store.media = AudioFileImporter()
        store.startAutosave()
        self.store = store
        self.engine = engine

        let port = ProcessInfo.processInfo.environment["DAW_CONTROL_PORT"]
            .flatMap(UInt16.init) ?? 17600
        let router = CommandRouter(store: store)
        let server = ControlServer(router: router, port: port)
        self.router = router
        controlServer = server
        let broadcaster = TransportBroadcaster(store: store, server: server)
        transportBroadcaster = broadcaster
        do {
            try server.start()
            // Transport/position frames flow to control clients once the server
            // is live; harmless (no subscribers) if start() failed.
            broadcaster.start()
        } catch {
            // Not fatal: the app works without the control plane, agents don't.
            FileHandle.standardError.write(
                Data("control server failed to start on port \(port): \(error)\n".utf8)
            )
        }
        installDebugCommands()
    }

    /// Installs the app-layer `debug.*` command surface on the router. These are
    /// developer/verification affordances (not agent-facing, not in allCommands)
    /// that render the live SwiftUI hierarchy — hence they live in the app, not
    /// headless DAWControl.
    private func installDebugCommands() {
        router.appCommandHandler = { [weak self] command, params in
            guard let self else { return nil }
            switch command {
            case "debug.captureUI":
                return try self.captureUI(params)
            case "ui.showMixer":
                return self.showMixer(params)
            case "ui.showAutomation":
                return try self.showAutomation(params)
            case "ui.showTakes":
                return try self.showTakes(params)
            default:
                return nil   // fall through to the router's unknown-command error
            }
        }
    }

    /// Switches the main window between the Arrange and Mix workspaces. Optional
    /// `show` bool (default true) picks Mix vs Arrange; returns the resulting
    /// mode. App-layer only (like `debug.*`) — a UI-verification affordance so a
    /// headless run can drive the window into the mixer before `debug.captureUI`.
    private func showMixer(_ params: [String: JSONValue]) -> JSONValue {
        let show = params["show"]?.boolValue ?? true
        workspaceMode = show ? .mix : .arrange
        return .object(["mode": .string(workspaceMode.rawValue)])
    }

    /// Opens a track's arrange automation row (Arrange workspace, disclosure
    /// expanded, first lane selected if any) so a headless run can drive the UI
    /// into the automation editor before `debug.captureUI`. App-layer only (like
    /// `ui.showMixer`) — a UI-verification affordance, not agent-facing.
    /// Params: `trackId` (required UUID). Returns the resulting state.
    private func showAutomation(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let raw = params["trackId"]?.stringValue else {
            throw DebugError("ui.showAutomation requires a trackId")
        }
        guard let id = UUID(uuidString: raw) else {
            throw DebugError("trackId is not a valid UUID: \(raw)")
        }
        workspaceMode = .arrange
        expandedAutomationTrackIDs.insert(id)
        if automationLaneSelection[id] == nil,
           let first = store.tracks.first(where: { $0.id == id })?.automation.first {
            automationLaneSelection[id] = first.id
        }
        return .object([
            "trackId": .string(id.uuidString),
            "expanded": .bool(true),
            "selectedLaneId": automationLaneSelection[id].map { JSONValue.string($0.uuidString) } ?? .null,
        ])
    }

    /// Opens a track's take-lanes section (Arrange workspace, takes disclosure
    /// expanded) so a headless run can drive the UI into the comp editor before
    /// `debug.captureUI`. App-layer only (like `ui.showAutomation`) — a
    /// UI-verification affordance, not agent-facing. Params: `trackId` (required
    /// UUID). Returns the resulting state (expanded + the track's group count).
    private func showTakes(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let raw = params["trackId"]?.stringValue else {
            throw DebugError("ui.showTakes requires a trackId")
        }
        guard let id = UUID(uuidString: raw) else {
            throw DebugError("trackId is not a valid UUID: \(raw)")
        }
        let show = params["show"]?.boolValue ?? true
        workspaceMode = .arrange
        if show { expandedTakeTrackIDs.insert(id) } else { expandedTakeTrackIDs.remove(id) }
        let groupCount = store.tracks.first { $0.id == id }?.takeGroups.count ?? 0
        return .object([
            "trackId": .string(id.uuidString),
            "expanded": .bool(show),
            "groupCount": .number(Double(groupCount)),
        ])
    }

    /// Toggles a track's take-lanes section open/closed (the header glyph).
    func toggleTakes(_ trackID: UUID) {
        if expandedTakeTrackIDs.contains(trackID) {
            expandedTakeTrackIDs.remove(trackID)
        } else {
            expandedTakeTrackIDs.insert(trackID)
        }
    }

    // MARK: - Arrange automation UI actions (sidebar disclosure + picker)

    /// Toggles a track's automation row open/closed. Opening defaults the
    /// selection to the track's first existing lane (if any).
    func toggleAutomation(_ trackID: UUID) {
        if expandedAutomationTrackIDs.contains(trackID) {
            expandedAutomationTrackIDs.remove(trackID)
        } else {
            expandedAutomationTrackIDs.insert(trackID)
            if automationLaneSelection[trackID] == nil,
               let first = store.tracks.first(where: { $0.id == trackID })?.automation.first {
                automationLaneSelection[trackID] = first.id
            }
        }
    }

    /// Picks a v0 param to edit: selects its existing lane, or creates one via
    /// the store (idempotent per target) and selects that. Ensures the row is open.
    func selectOrCreateAutomationLane(trackID: UUID, param: AutomationParam) {
        guard let track = store.tracks.first(where: { $0.id == trackID }) else { return }
        if let existing = AutomationLaneSelection.lane(for: param, in: track) {
            automationLaneSelection[trackID] = existing.id
        } else if let lane = try? store.addAutomationLane(trackID: trackID, target: param.target) {
            automationLaneSelection[trackID] = lane.id
        }
        expandedAutomationTrackIDs.insert(trackID)
    }

    /// Removes a lane and re-points the selection to the track's first remaining
    /// lane (or nil).
    func deleteAutomationLane(trackID: UUID, laneID: UUID) {
        try? store.removeAutomationLane(trackID: trackID, laneID: laneID)
        if automationLaneSelection[trackID] == laneID {
            automationLaneSelection[trackID] =
                store.tracks.first(where: { $0.id == trackID })?.automation.first?.id
        }
    }

    /// Captures the app UI to a PNG and returns `{path, width, height, method}`.
    /// Lets UI verification run without Screen Recording TCC: we snapshot our
    /// OWN window (or, headless, our own view tree) — never the screen.
    ///
    /// Primary path (`method: "window"`): draws the live NSWindow's contentView
    /// with `cacheDisplay(in:to:)`, so it includes the REAL rendered pixels of
    /// every ScrollView (track rows, timeline clips, piano-roll keyboard/grid/
    /// notes). Pixel size follows the window's backing scale (Retina = 2×); the
    /// `scale` param is NOT honored here (the backing store dictates it) — this
    /// is documented behavior, not a bug, and the true pixel dims are returned.
    ///
    /// Fallback (`method: "imageRenderer"`): only when no window exists (a
    /// headless edge). `ImageRenderer` DOES honor `scale`, but cannot draw
    /// NSScrollView-backed content, so scrollable areas come out blank there.
    ///
    /// Params (all optional): `path` (~-expanded; defaults under
    /// NSTemporaryDirectory()/DAWPro), `scale` (fallback only, default 2),
    /// `selectClip` (a clip UUID to open the piano roll on — set before capture
    /// and left set, so the live window follows).
    private func captureUI(_ params: [String: JSONValue]) throws -> JSONValue {
        // Selection first: a bad uuid is a caller error, reported readably. The
        // set persists (the live window mirrors it — intended and useful).
        var selectionChanged = false
        if let raw = params["selectClip"]?.stringValue {
            guard let id = UUID(uuidString: raw) else {
                throw DebugError("selectClip is not a valid UUID: \(raw)")
            }
            if selectedClipID != id {
                selectedClipID = id
                selectionChanged = true
            }
        }

        let scale = params["scale"]?.doubleValue ?? 2
        let url = captureURL(params)

        // Layout-flush: setting selectedClipID only *schedules* a SwiftUI update;
        // the PianoRollView subtree isn't instantiated or laid out until the main
        // runloop processes SwiftUI's transaction. We're on the main actor, so a
        // bare layoutSubtreeIfNeeded lays out the *current* tree, not the not-yet-
        // created subtree — instead we spin the main runloop briefly to let the
        // pending update land before we snapshot. Bounded and only on an actual
        // selection change; standard (if ugly) AppKit synchronous-snapshot
        // practice. Reentrancy caveat: the spin can service other queued main work
        // — fine for the serial control stream this serves.
        if selectionChanged {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.2))
        }

        // Primary: snapshot the real window content (all ScrollView content).
        if let window = mainCaptureWindow, let contentView = window.contentView,
           contentView.bounds.width > 1, contentView.bounds.height > 1 {
            window.displayIfNeeded()
            contentView.layoutSubtreeIfNeeded()
            guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
                throw DebugError("window has no drawable backing yet — retry once it has displayed")
            }
            contentView.cacheDisplay(in: contentView.bounds, to: rep)
            try writePNG(rep, to: url)
            return .object([
                "path": .string(url.path),
                "width": .number(Double(rep.pixelsWide)),
                "height": .number(Double(rep.pixelsHigh)),
                "method": .string("window"),
            ])
        }

        // Fallback: ImageRenderer of a fresh ContentView at a fixed 1280×800
        // frame (chrome only — scrollable content renders blank here).
        let content = ContentView(engine: engine, controlPort: controlServer.port)
            .environment(store)
            .environment(self)
            .frame(width: 1280, height: 800)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        guard let cgImage = renderer.cgImage else {
            throw DebugError("no window to capture and ImageRenderer produced no image")
        }
        try writePNG(NSBitmapImageRep(cgImage: cgImage), to: url)
        return .object([
            "path": .string(url.path),
            "width": .number(Double(cgImage.width)),
            "height": .number(Double(cgImage.height)),
            "method": .string("imageRenderer"),
        ])
    }

    /// Our content-hosting NSWindow. Prefers key/main; otherwise the first
    /// window with a laid-out content view (the WindowGroup window even when the
    /// app isn't frontmost — e.g. launched in the background for verification).
    private var mainCaptureWindow: NSWindow? {
        let app = NSApplication.shared
        if let window = app.keyWindow, window.contentView != nil { return window }
        if let window = app.mainWindow, window.contentView != nil { return window }
        return app.windows.first {
            guard let view = $0.contentView else { return false }
            return view.bounds.width > 1 && view.bounds.height > 1
        }
    }

    /// Destination URL: explicit `path` (~-expanded) or an auto-named file under
    /// NSTemporaryDirectory()/DAWPro.
    private func captureURL(_ params: [String: JSONValue]) -> URL {
        if let raw = params["path"]?.stringValue {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        }
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("DAWPro", isDirectory: true)
        let n = Self.captureCounter
        Self.captureCounter += 1
        return dir.appendingPathComponent("ui-capture-\(n).png")
    }

    /// Encodes `rep` as PNG at `url`, creating the parent directory. Readable
    /// errors for the two failure modes agents hit: unwritable dir / path.
    private func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw DebugError("cannot create capture directory \(url.deletingLastPathComponent().path): \(error.localizedDescription)")
        }
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw DebugError("failed to encode PNG")
        }
        do {
            try data.write(to: url)
        } catch {
            throw DebugError("cannot write capture to \(url.path): \(error.localizedDescription)")
        }
    }
}

/// App-layer control error carrying a client-readable message. Conforms to
/// `LocalizedError` so `CommandRouter.handle` surfaces `errorDescription`
/// verbatim rather than dumping the Swift value.
struct DebugError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
