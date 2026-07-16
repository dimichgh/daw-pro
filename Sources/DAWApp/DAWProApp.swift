import AppKit
import SwiftUI
import UniformTypeIdentifiers
import DAWCore
import DAWEngine
import DAWControl
import DAWAppKit
import AIServices

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
                    // Enforce the MEASURED window floor (m10-j) directly on the
                    // NSWindow too — belt-and-suspenders with the root
                    // `.frame(minWidth:minHeight:)` — so a user drag can never shrink
                    // the window below the point where chrome would leave the frame.
                    model.applyWindowFloor()
                }
        }
        // Open at a comfortable size well above the floor (m10-j).
        .defaultSize(width: WindowFloor.defaultWidth, height: WindowFloor.defaultHeight)
        .commands {
            // Native ⌘, wired to the in-window glass Settings overlay (not a
            // stock preferences window — glass-cockpit chrome, docs/DESIGN-LANGUAGE).
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
            FileCommands(store: model.store, model: model)
            EditCommands(store: model.store)
            // Arrange zoom (m17-b): ⌘+/⌘−/⌘0 + the Track Height ladder.
            ViewCommands(model: model)
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

    /// m18-b: the main-actor wedge detector. A background timer pings the main
    /// actor once a second; a pong overdue past the threshold = wedged. The
    /// control server's QUEUE tier reads `snapshot()` before every MainActor
    /// hop so agents get honest answers (not silent hangs) while the UI is
    /// wedged; breadcrumbs land in ~/Library/Logs/DAWPro/main-actor-wedge.log.
    /// Detection only — no auto-kill, no restart, and the engine/render side
    /// runs right through a wedge untouched.
    let livenessMonitor: MainActorLivenessMonitor

    /// The local ACE-Step song generator + its sidecar manager, SHARED with the
    /// control router (so the Sketchpad panel and the `ai.*` wire path talk to
    /// the same job state) and used directly by the Sketchpad model.
    let songGenerator: ACEStepClient
    let sidecarManager: SidecarManager

    /// The unified generation-progress registry (m17-h): EVERY generation job
    /// — Sketchpad, wire `ai.generateSong` / MCP `generate_song`, stems /
    /// repaint / import paths — reports here through the origin-tagged
    /// `GenerationObservingGenerator` wrappers, and the canonical violet
    /// progress card renders it. Owned here so `debug.generationCard` can
    /// stage/read it and `debug.captureUI` renders the same instance.
    let generationPresence: GenerationPresenceModel

    /// The AI Sketchpad panel's headless model (M6 iii-b). Owned here so the
    /// `debug.sketchpad*` capture commands can drive it and `debug.captureUI`
    /// renders the same instance the live panel shows.
    let sketchpad: SketchpadModel

    /// Whether the Sketchpad side panel is open in the Arrange workspace. Driven
    /// by the header toggle and the `ui.showSketchpad` debug command.
    var showSketchpad = false

    /// The Lyrics Workshop's headless model (M6): the Anthropic/OpenAI-powered
    /// write/refine surface that feeds bracketed lyrics into the Sketchpad. Owned
    /// here so `debug.lyricsWorkshop*` capture commands can drive it and
    /// `debug.captureUI` renders the same instance the panel shows.
    let lyricsWorkshop: LyricsWorkshopModel

    /// Whether the WRITE-WITH-AI workshop is expanded inside the Sketchpad panel.
    /// Driven by the panel's disclosure and the `ui.showLyricsWorkshop` command.
    var showLyricsWorkshop = false

    /// The clip vocal-fix panel's headless model (M6 v-b-2): the region + prompt
    /// composer and the submit → poll → import lifecycle of every in-flight AI
    /// fix. Owned here (like `sketchpad`) so the `debug.clipFix*` capture commands
    /// can drive it and `debug.captureUI` renders the same instance the panel
    /// shows. Submits through `ProjectStore.fixClipRegion`, imports through
    /// `importClipFix` — the same one-command surface the control plane calls.
    let clipFix: ClipFixModel

    /// Whether the FIX-WITH-AI panel is open in the Arrange workspace. Driven by
    /// the clip-selection affordance and the `ui.showClipFix` debug command.
    var showClipFix = false

    /// The instrument picker's headless model (m10-n-3): the three-section browser
    /// + GM program browser + Simple "Instrument Sets" + `InstrumentChoice`
    /// construction. Owned here (like `clipFix`) so the `debug.instrumentPicker`
    /// capture command can drive it and `debug.captureUI` renders the same
    /// instance the live overlay shows. Data flows in through store-backed
    /// providers; selection converges on `ProjectStore.setInstrument` — the SAME
    /// one-command surface the wire uses.
    let instrumentPicker: InstrumentPickerModel

    /// The track the instrument picker is open for (nil = closed). Set by the
    /// track-header / mixer instrument chip and the `debug.instrumentPicker`
    /// command; the picker renders as a centered overlay over the workspace.
    var instrumentPickerTrackID: UUID?

    /// The mixer AU-effect picker's headless model (m13-g, audit F6): the searchable
    /// installed-AU-effects list + the `AudioUnitConfig` a selection applies. Owned
    /// here (like `instrumentPicker`) so `debug.effectPicker` can drive it and
    /// `debug.captureUI` renders the same instance the live overlay shows. Selection
    /// converges on `ProjectStore.addEffect(kind:.audioUnit)` — the SAME store call
    /// the wire's `fx.add kind:"audioUnit"` uses.
    let effectPicker: EffectPickerModel

    /// The track the AU-effect picker is adding to (nil = closed). Set by the Pro
    /// inserts add-menu's "Audio Units…" item and `debug.effectPicker`; the picker
    /// renders as a centered overlay. Never a MASTER target (built-ins only, v1).
    var effectPickerTrackID: UUID?

    /// The built-in insert EFFECT EDITOR's headless model (m17-a): spec-driven
    /// param rows + the wire-identical apply path (`setEffectParam` /
    /// `setMasterEffectParam` — exactly what `fx.setParam` calls). Owned here
    /// (like `effectPicker`) so `debug.effectEditor` can drive it and
    /// `debug.captureUI` renders the same instance the live card shows.
    let effectEditor: EffectEditorModel

    /// The open effect editor's insert (nil = closed; `trackID` nil = the MASTER
    /// chain). ONE editor open app-wide — opening another insert's editor
    /// replaces this. Set by clicking a built-in `InsertRow`, by the UI insert
    /// add-menu (auto-open, Logic precedent), and by `debug.effectEditor`; the
    /// wire's `fx.add` NEVER sets it (agents must not pop UI).
    var effectEditorTarget: EffectEditorTarget?

    /// The Quantize & Groove panel's headless model (m11-a): the grid/strength/
    /// swing/ends state, the groove picker (built-in swings + saved templates), and
    /// the extract affordance. Owned here (like `instrumentPicker`) so the
    /// `debug.quantizePanel` capture command drives it and `debug.captureUI` renders
    /// the same instance the live overlay shows. Data flows in through store-backed
    /// providers; Apply converges on `ProjectStore.quantizeClipNotes` — the SAME
    /// method the `clip.quantize` wire uses (UI-only; no new wire surface).
    let quantizeModel: QuantizeModel

    /// The clip the Quantize panel is open for (nil = closed). Set by the
    /// piano-roll header QUANTIZE chip, the arrange clip context menu, and the
    /// `debug.quantizePanel` command; the panel renders as a centered overlay.
    var quantizePanelClipID: UUID?

    /// Staging seam for the arrange marker-lane inline rename (m11-c): when set to
    /// a marker id, the timeline opens that flag's rename field. Driven ONLY by the
    /// `debug.markerRename` capture command (the live UI uses double-click / the
    /// context menu); nil at rest. Not persisted — a capture-only view override.
    var stagedMarkerRenameID: UUID?

    /// The Undo-history panel's headless model (m11-b): projects the store's
    /// labeled undo/redo stacks into a clickable step plan and jumps to any point
    /// by REPEATING `ProjectStore.undo()`/`redo()` (no new mutation surface). Owned
    /// here (like `quantizeModel`) so the `debug.undoHistory` capture command drives
    /// it and `debug.captureUI` renders the same instance the live overlay shows.
    let undoHistoryModel: UndoHistoryModel

    /// Whether the Undo-history panel is open. Driven by the arrange-toolbar HISTORY
    /// chip and the `debug.undoHistory` staging command; the panel renders as a
    /// centered overlay over the workspace.
    var showUndoHistory = false

    /// Whether the engine-notices popover is open (m15-e, audit F6). Driven by the
    /// transport-bar notices chip and the `debug.postEngineNotice` staging command;
    /// the list renders as a bottom-anchored in-window overlay (the notices ring
    /// itself lives on `store.engineNotices`, so this is pure presentation state).
    var showEngineNotices = false

    /// The arrange tempo-lane's headless model (m12-d): reads the RESOLVED tempo/
    /// meter maps and applies every edit through `ProjectStore.setTempoMap` (ONE
    /// undo via the "tempo.map" coalescing key — a drag folds to a single step).
    /// Owned here (like `quantizeModel`) so the `debug.tempoLane` capture command
    /// drives it and the timeline ruler renders the same instance (shared selection
    /// + teaching-error state). UI-only — no parallel mutation path.
    let tempoLaneModel: TempoLaneModel

    /// The in-app AI Copilot (M6 rail-c): a chat rail that drives the project
    /// through the SAME control-command surface as the WebSocket, in-process.
    /// Owned here (retained) so `router.copilotEngine`'s weak reference stays
    /// alive; constructed with a dispatch closure straight to `router.handle`
    /// (no loopback self-connection). Key-less to construct — the AI provider
    /// is resolved fresh on each `send()`.
    let copilotEngine: CopilotEngine

    /// The floating AU plugin windows (M3 vi-b). Owned here (strong) so
    /// `router.pluginUI`'s weak reference stays alive; drives `plugin.*` over the
    /// wire AND the mixer/instrument open-window buttons through the SAME manager.
    let pluginWindows: PluginWindowManager

    /// Whether the Copilot chat rail is open (M6 rail-d). App-level, not
    /// selection-gated — driven by the always-visible header COPILOT chip and the
    /// `ui.showCopilot` debug command; the rail coexists with the ClipFix panel.
    var showCopilot = false

    /// The Settings → API Keys panel's headless model (M6). Backed by the real
    /// Keychain in normal use; the `debug.settings*` capture commands swap in a
    /// seeded model (in-memory store + fake environment) so a capture can show
    /// env-locked / keychain-configured rows without touching real secrets.
    private(set) var settings: SettingsModel

    /// Whether the Settings overlay is open. Driven by the header gear chip, the
    /// ⌘, menu command, and the `ui.showSettings` debug command.
    var showSettings = false

    /// Deep-link the Settings modal to its below-the-fold "Beta" utility row
    /// (M9 beta) — the panel's `ScrollViewReader` scrolls to it when true. Set by
    /// `ui.showSettings {reveal:"beta"}` so a headless capture can frame the row;
    /// false in normal use (the panel opens at the top, on the API keys).
    var settingsRevealBeta = false

    /// Deep-link the Settings modal to its "Agent Connection" section (beta m10-l) —
    /// the panel's `ScrollViewReader` scrolls to it when true. Set by
    /// `ui.showSettings {reveal:"connection"}` so a headless capture (or a beginner
    /// following the guide) can jump straight to the control-URL / port surface;
    /// false in normal use (the panel opens at the top, on the API keys).
    var settingsRevealConnection = false

    /// UI selection: the clip whose piano roll is open (nil = closed). Hoisted
    /// out of ContentView's @State so `debug.captureUI` renders with the same
    /// selection as the live window. Only MIDI clips open the editor.
    var selectedClipID: UUID?

    /// Deep-scroll staging for the pinned-ruler proof (m13-g): the track id the
    /// shared arrange scroll should jump to (via ContentView's `ScrollViewReader`),
    /// so a headless capture can frame the bottom of a deep session with the ruler
    /// block still pinned. nil in normal use. Driven ONLY by `debug.arrangeScroll`.
    var arrangeScrollTarget: UUID?
    /// Whether `arrangeScrollTarget` anchors at the BOTTOM (deep-scroll) or the top.
    var arrangeScrollToBottom = false
    /// Bumped on every `debug.arrangeScroll` call so ContentView's `.onChange`
    /// fires even when the target repeats (SwiftUI dedups equal values).
    var arrangeScrollNonce = 0

    // MARK: Arrange zoom (m17-b)

    /// The lanes' horizontal scroll offset MIRROR — what the pinned ruler
    /// offsets by. Normally the `.lanes` preference feeds it; a zoom writes its
    /// analytic target here FIRST so the ruler moves in the same update, and the
    /// preference then re-confirms from real layout.
    var arrangeHScroll: CGFloat = 0
    /// The last offset the `.lanes` preference ACTUALLY reported (m17-b) — never
    /// written analytically, so `debug.arrangeZoom` echoes ground truth: if a
    /// programmatic zoom scroll failed to land, this diverges from the mirror
    /// and the gate catches it (no circular pass).
    var arrangeHScrollReported: CGFloat = 0
    /// The lanes viewport width, reported by ContentView's geometry — sizes the
    /// zoom anchor's viewport-center fallback and the zoomed-out padding.
    var arrangeViewportWidth: CGFloat = 0
    /// A programmatic horizontal scroll request (the anchor-preserving offset a
    /// zoom computed) + its nonce; consumed by the lanes' `ArrangeHScrollBridge`
    /// in the same transaction as the scale change.
    var arrangeZoomScrollTarget: CGFloat?
    var arrangeZoomScrollNonce = 0
    /// The pinch in flight (nil at rest): captured on the first magnify tick so
    /// per-tick zoom math measures off a FIXED anchor beat/screen-x.
    private var arrangePinch: ArrangeZoom.PinchState?

    // MARK: Arrange pointer affordances (m17-c)

    /// The staged pointer event `debug.arrangePointer` injects (nil in normal
    /// use) — ContentView threads it into the lanes, which run it through the
    /// SAME handlers a real hover/click uses (the `stagedMarkerRenameID`
    /// mirror precedent; hover isn't injectable without Accessibility).
    var arrangePointerStage: ArrangePointerStage?
    /// The pointer layer's live state, reported UP by the lanes (real hovers
    /// and staged events alike) so the seam echoes ground truth — never its
    /// own input (the `arrangeHScrollReported` honesty rule).
    var arrangePointerZone: String = ArrangePointerZone.outside.rawValue
    var arrangeGhostBeat: Double?
    /// The split refusal currently surfaced on a clip block (verbatim store
    /// message, amber bubble). Auto-clears a few seconds after presentation.
    var arrangeSplitRefusal: ArrangeSplitRefusal?
    private var arrangeRefusalSeq = 0

    /// Surfaces a refused clip edit VERBATIM (m17-c): the store's
    /// LocalizedError message — the SAME string the wire returns for the same
    /// call — as a transient amber bubble on the refused clip. Auto-clears
    /// after 6 s unless a newer refusal replaced it (seq guard).
    func presentArrangeSplitRefusal(_ error: any Error, clipID: UUID?) {
        arrangeRefusalSeq += 1
        let seq = arrangeRefusalSeq
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        arrangeSplitRefusal = ArrangeSplitRefusal(clipID: clipID, message: message, seq: seq)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.arrangeSplitRefusal?.seq == seq else { return }
            self.arrangeSplitRefusal = nil
        }
    }

    // MARK: Space-bar transport toggle (m17-d)

    /// The app-wide key-down LOCAL monitor behind the space-bar transport
    /// toggle (m17-d, user #6) — the TimelineLanesView ⌥-tracking precedent,
    /// app-scoped. A monitor rather than a SwiftUI `.keyboardShortcut`/menu
    /// key equivalent because key equivalents are checked BEFORE text
    /// insertion — a space equivalent would steal the space bar from every
    /// rename field (the exact failure the focus guard exists to prevent).
    /// The monitor sees the event WITH the live first responder, asks the
    /// headless `TransportKeyRouting.decide` predicate, and either swallows
    /// the space (toggle) or hands it back untouched (pass through).
    /// Installed once in `init`, lives for the app's lifetime.
    @ObservationIgnored private var spaceKeyMonitor: Any?

    /// The ONE content window (the WindowGroup window hosting ContentView),
    /// captured when `applyWindowFloor()` runs on its appearance. The space
    /// toggle is MAIN-WINDOW-ONLY (the documented safe default): events aimed
    /// at floating plugin windows or any other panel classify as `.secondary`
    /// and pass through. Weak — a closed window never dangles.
    @ObservationIgnored private weak var contentWindow: NSWindow?

    /// Installs the space-bar monitor (m17-d). The handler body lives in
    /// `handleKeyDownEvent` so the `debug.keySpace` seam runs the SAME code
    /// path with a synthesized event (real key injection needs Accessibility
    /// the staging binary lacks — measured law).
    private func installSpaceKeyMonitor() {
        spaceKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            return self.handleKeyDownEvent(event)
        }
    }

    /// The one key-down body — the live monitor and `debug.keySpace {press:true}`
    /// both run exactly this. Maps the event's facts (key code, chord modifiers,
    /// repeat, the TARGET window's first responder, window identity) into the
    /// headless predicate's value types and obeys the verdict. Returns nil to
    /// swallow the event (the toggle consumed it — nothing downstream beeps or
    /// types) or the event untouched to pass it through.
    func handleKeyDownEvent(_ event: NSEvent) -> NSEvent? {
        let decision = TransportKeyRouting.decide(
            keyCode: event.keyCode,
            modifiers: Self.transportKeyModifiers(event.modifierFlags),
            isRepeat: event.isARepeat,
            responder: Self.transportKeyResponder(event.window?.firstResponder),
            window: transportKeyWindow(event.window))
        guard decision == .toggleTransport else { return event }
        toggleTransportFromSpaceKey()
        return nil
    }

    /// The granted toggle: the play/pause button's EXACT funnel
    /// (`isPlaying ? store.stop() : store.play()`, TransportBar) routed through
    /// the headless `toggleIntent` so the ternary is unit-pinned. Recording
    /// sets `isPlaying` true (`ProjectStore.record()`), so a mid-record space
    /// lands on the SAME `store.stop()` the record button's stop branch calls.
    func toggleTransportFromSpaceKey() {
        switch TransportKeyRouting.toggleIntent(isPlaying: store.transport.isPlaying) {
        case .play: store.play()
        case .stop: store.stop()
        }
    }

    /// Maps the event's device-independent chord modifiers into the headless
    /// option set. Only command/option/control/shift block the toggle — caps
    /// lock, fn, and numeric-pad flags deliberately don't (caps lock being on
    /// must not kill the space bar).
    private static func transportKeyModifiers(_ flags: NSEvent.ModifierFlags) -> TransportKeyModifiers {
        let device = flags.intersection(.deviceIndependentFlagsMask)
        var mods: TransportKeyModifiers = []
        if device.contains(.command) { mods.insert(.command) }
        if device.contains(.option) { mods.insert(.option) }
        if device.contains(.control) { mods.insert(.control) }
        if device.contains(.shift) { mods.insert(.shift) }
        return mods
    }

    /// Classifies the first responder for the focus guard: any text-input
    /// surface means the space belongs to the text. `NSText` covers the shared
    /// field editor (an `NSTextView`) behind every AppKit-backed `TextField` —
    /// track/marker/take renames, the Copilot rail input, Settings fields.
    /// The `NSTextInputClient` catch-all covers SwiftUI-native text hosts that
    /// aren't `NSText` subclasses (belt-and-suspenders). MEASURED live (m17-d
    /// gate): at rest this app's first responder is the NSWindow itself
    /// (`AppKitWindow`), which conforms to neither → `.none`; a focused rename
    /// TextField puts `_SystemTextFieldFieldEditor` (an `NSTextView`) first →
    /// `.textEditing` via the `NSText` branch.
    private static func transportKeyResponder(_ responder: NSResponder?) -> TransportKeyResponder {
        guard let responder else { return .none }
        if responder is NSText { return .textEditing }
        if responder is any NSTextInputClient { return .textEditing }
        return .none
    }

    /// Main-window-only guard: only events aimed at THE content window toggle.
    /// nil window (an unresolvable synthesized window number) is `.secondary`.
    private func transportKeyWindow(_ window: NSWindow?) -> TransportKeyWindow {
        guard let window, window === contentWindow else { return .secondary }
        return .main
    }

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

    /// Per-panel Simple/Pro density (M8 sp-a). App-side sticky PREFERENCE (never
    /// project data): the UserDefaults backing persists each panel's mode under
    /// `panelDensity.<panelID>`, so it survives close/reopen and relaunch. Driven
    /// by each panel's `SimpleProToggle` and by the `debug.panelDensity` staging
    /// command (which writes straight to this store, so the live chip reflects it).
    let panelDensity = PanelDensityStore(backing: UserDefaultsPanelDensityBacking())

    /// Adjustable window layout (beta m10-d): the arrange sidebar width, the bottom
    /// editor's height fraction, and the GLOBAL track-row height. Like `panelDensity`
    /// it's an app-side sticky PREFERENCE (never project data) — the UserDefaults
    /// backing persists each dimension under `panelLayout.<dimension>`, so a resized
    /// layout survives relaunch. Driven by the draggable `PanelSplitter`s and by the
    /// `debug.panelLayout` staging command (which writes straight to this store, so
    /// the live layout reflects it). Deliberately NOT a wire command / MCP tool —
    /// a window-layout preference, not an invokable capability (the panelDensity
    /// precedent).
    let panelLayout = PanelLayoutStore(backing: UserDefaultsPanelLayoutBacking())

    /// The in-app control-server port SETTING (beta m10-l). Like `panelLayout` it's
    /// an app-side sticky PREFERENCE (never project data) — the UserDefaults backing
    /// persists it under `controlServer.port`. The bootstrap reads it (below) to
    /// resolve the bind port (env override > this setting > default 17600); the
    /// Settings → Agent Connection section edits it. Changing it takes effect on the
    /// NEXT launch — the running server is never live-rebound (that would sever the
    /// live agent session and the transport broadcaster).
    let controlPortStore = ControlPortStore(backing: UserDefaultsControlPortBacking())

    /// The in-app Copilot round-budget SETTING (beta m10-m). Like `controlPortStore`
    /// it's an app-side sticky PREFERENCE (never project data) — the UserDefaults
    /// backing persists it under `copilot.maxRounds`. The CopilotEngine reads its
    /// `maxRounds` FRESH at the start of each turn (via the injected resolver below),
    /// so a change takes effect on the Copilot's next reply — no restart, unlike the
    /// control-server port. The Settings → Copilot section edits it.
    let copilotLimitsStore = CopilotLimitsStore(backing: UserDefaultsCopilotLimitsBacking())

    /// Explain-mode state (M8 ex-a): the transient violet "?" EXPLAIN overlay's
    /// on/off flag + an optional capture focus. Owned here (like `panelDensity`) so
    /// the `debug.explainMode` staging command can drive it. NOT persisted — unlike
    /// density, explain mode is a per-session aid, off by default.
    let explain = ExplainModel()

    /// The "first song in ten minutes" guided-tour state machine (M8 ob-b). Owned
    /// here with the UserDefaults backing (key `onboarding.state`) so mid-tour
    /// progress + the two terminals survive relaunch; offered once on first launch
    /// (`offerTourIfEligible`), replayable from Settings (`replayTour`), and staged
    /// for captures/E2E by `debug.onboardingState`. The tour model NEVER reads the
    /// store — `onboardingAdapter` is the only bridge.
    let onboarding = OnboardingModel(backing: UserDefaultsOnboardingStateBacking())

    /// Observes `ProjectStore` and fires the tour's completion signals (ob-b). Held
    /// so it stays alive for the app's lifetime; started in `init`.
    private let onboardingAdapter: OnboardingSignalAdapter

    /// Launch-time crash-recovery offer (M9 crash-b): non-nil when the last session
    /// ended unexpectedly AND a restorable autosave snapshot is present, so
    /// `RecoveryOfferView` floats over the workspace. Set in `init` from
    /// `store.recoveryStatus()`; the sheet's own buttons clear it, and it is
    /// stageable for captures via `debug.recoveryOffer`. The sheet drives the SAME
    /// `ProjectStore.recoverFromAutosave` path the `project.recover` command uses.
    ///
    /// Because this is a one-shot snapshot, it does NOT by itself notice when the
    /// offer is resolved by a path OTHER than the sheet — `project.recover` over the
    /// wire, or a `project.new`/`project.open` transition. ContentView bridges that
    /// gap (m10-s): it observes `store.recoveryOfferAvailable` and clears this on the
    /// available→unavailable transition, mirroring the buttons' dismissal. That
    /// observer is transition-based, so `debug.recoveryOffer` staging (which sets
    /// this while the store flag stays false) keeps working for captures.
    var recoveryOffer: AutosaveRecoveryStatus?

    /// Retains the `NSApplication.willTerminateNotification` observer so the
    /// clean-exit lock removal (crash-b) stays live for the app's lifetime.
    @ObservationIgnored private var terminationObserver: (any NSObjectProtocol)?

    /// A synthetic master-analysis snapshot the session vibe meter prefers over the
    /// live engine poll (M8 vm-b). nil in normal use (the meter reads
    /// `store.masterAnalysis()`); the debug-tier `debug.vibeSeed` command sets it so a
    /// capture / E2E can stage a specific mix feel (dim ember, bass-heavy, bright)
    /// without real audio. The ENGINE is never touched by seeding — this is a
    /// view-side override, the `debug.explainMode focus` precedent.
    var vibeSeed: MasterAnalysisSnapshot?

    /// A pending copilot draft (M8 ex-a hand-off). The explain card's "Ask the
    /// Copilot" button sets this to a prefilled question and opens the rail; the rail
    /// loads it into its input on appear and clears it (never auto-sends — the user
    /// presses send, so it works with or without an API key).
    var copilotDraft: String?

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
        // Crash-recovery autosave (M9 crash-b): detect a prior crash (a surviving
        // session.lock) BEFORE writing this session's lock, then run the rolling
        // 30-s snapshot loop. This supersedes the legacy `startAutosave` in-place
        // loop — the crash-recovery snapshot never touches the user's file and is
        // offered back only after a crash.
        let crashDetected = store.beginCrashDetection()
        store.startCrashAutosave()
        // Untitled-recovery bundles accumulate one per abandoned untitled session
        // (flushForTransition) with no other cleanup path — prune to the newest
        // few at launch.
        store.pruneUntitledRecoveryBundles()
        self.store = store
        self.engine = engine
        // If a crash left restorable unsaved work, stage the launch offer (the
        // sheet reads this; nil = no offer). `recoveryStatus()` also confirms the
        // snapshot files are actually present, so a bare lock never over-offers.
        if crashDetected {
            let status = store.recoveryStatus()
            if status.available { self.recoveryOffer = status }
        }
        // Clean-exit lock removal: fires on in-app quit (Cmd-Q / the quit Apple
        // event). SIGTERM/pkill does NOT reach AppKit termination for this
        // process (verified live) — it dies like a crash, and since nothing
        // saves on the way down, the next launch correctly offers recovery.
        // The lock URL is a Sendable value, so the observer needs no actor hop.
        let lockURL = store.crashLockURL
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            try? FileManager.default.removeItem(at: lockURL)
        }

        // One song generator + sidecar manager, shared with the router so the
        // panel's own generate/import and the `ai.*` wire path never diverge on
        // job state or audio caching.
        let songGenerator = ACEStepClient()
        let sidecarManager = SidecarManager()
        self.songGenerator = songGenerator
        self.sidecarManager = sidecarManager

        // The unified generation-progress registry (m17-h): its own polls read
        // the RAW client (never a decorator — no self-observation loop) and the
        // sidecar manager's own status; a sidecar death mid-job posts an
        // engine notice through the SAME handler funnel the engine uses (the
        // `debug.postEngineNotice` path), so the transport chip lights up —
        // failed card + notice, never silent.
        let generationPresence = GenerationPresenceModel(
            status: { [songGenerator] jobID in
                try await songGenerator.generationStatus(jobID: jobID)
            },
            sidecarStatus: { [sidecarManager] in await sidecarManager.status() },
            notify: { [weak engine] message in
                engine?.engineNoticeHandler?(
                    EngineNoticeEvent(code: "ai-generation-interrupted", message: message))
            })
        self.generationPresence = generationPresence

        // Auto-start (m17-h): boots the sidecar and waits for healthy — the
        // manager's `start()` blocks through its own ~30 s health window, then
        // this keeps polling through the multi-minute model load (the presence
        // card narrates the phases meanwhile). Bounded so a broken install can
        // never wedge a submit forever.
        let ensureSidecar: GenerationObservingGenerator.EnsureSidecar = { [sidecarManager] in
            if let started = try? await sidecarManager.start(), started.state == .healthy {
                return true
            }
            let deadline = Date().addingTimeInterval(15 * 60)
            while Date() < deadline {
                let probe = await sidecarManager.status()
                switch probe.state {
                case .healthy: return true
                case .notInstalled, .error: return false
                case .starting, .installedNotRunning: break
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
            return false
        }

        // ONE real client, THREE origin-tagged observers (m17-h) — job state
        // and audio caching stay unified in `songGenerator`; only the presence
        // tag differs. The Sketchpad's awaits the auto-start boot (its generate
        // is a panel action, free to take the boot inline); the wire's and the
        // import seam's kick the boot fire-and-forget and rethrow — a control
        // command must not block for a multi-minute model load, and the
        // router's error translation already reports "starting…" honestly.
        let sketchpadGenerator = GenerationObservingGenerator(
            wrapping: songGenerator, origin: .sketchpad, presence: generationPresence,
            ensureSidecar: ensureSidecar, awaitsBoot: true)
        let wireGenerator = GenerationObservingGenerator(
            wrapping: songGenerator, origin: .wire, presence: generationPresence,
            ensureSidecar: ensureSidecar, awaitsBoot: false)
        let importGenerator = GenerationObservingGenerator(
            wrapping: songGenerator, origin: .import, presence: generationPresence,
            ensureSidecar: ensureSidecar, awaitsBoot: false)

        // The Sketchpad model: generate over the shared client (through its
        // origin-tagged observer), import through the store's one-undo
        // generation-import pipeline (the created track's name is read back
        // for the imported badge).
        let sketchpad = SketchpadModel(
            generator: sketchpadGenerator,
            importer: { [weak store] jobID in
                guard let store else { throw DebugError("project store unavailable") }
                let (trackID, _, _) = try await store.importGeneration(jobID: jobID)
                let name = store.tracks.first { $0.id == trackID }?.name ?? "AI Track"
                return SketchpadImportResult(trackID: trackID, trackName: name)
            }
        )
        self.sketchpad = sketchpad

        // The clip vocal-fix model (M6 v-b-2): submit bounces+repaints through the
        // store's fixClipRegion, poll rides the SAME shared generation-status
        // surface the Sketchpad uses, import lands the fix as a violet take lane
        // through importClipFix. All three hops are closures so DAWAppKit stays off
        // the engine bridge; the store's generationSource is wired by the router
        // below (one source of truth with the ai.* wire path).
        self.clipFix = ClipFixModel(
            submitter: { [weak store] request in
                guard let store else { throw DebugError("project store unavailable") }
                return try await store.fixClipRegion(
                    trackId: request.trackId, clipId: request.clipId,
                    startBeat: request.startBeat, endBeat: request.endBeat,
                    prompt: request.prompt, lyrics: request.lyrics,
                    mode: request.mode, strength: request.strength,
                    seed: request.seed, contextSeconds: request.contextSeconds)
            },
            statusProvider: { [songGenerator] jobID in
                try await songGenerator.generationStatus(jobID: jobID)
            },
            importer: { [weak store] jobID in
                guard let store else { throw DebugError("project store unavailable") }
                return try await store.importClipFix(jobID: jobID)
            })

        // The instrument picker model (m10-n-3): all data flows in through
        // store-backed providers so the headless model stays off the engine
        // bridge; a missing bank's throw is swallowed to an honest empty listing
        // (the picker never errors on a resolvable-but-empty bank). Selection is
        // applied by the view via `applyInstrumentChoice` → `store.setInstrument`.
        self.instrumentPicker = InstrumentPickerModel(
            soundBanks: { [weak store] in store?.availableSoundBanks() ?? [] },
            programs: { [weak store] source in
                guard let store else { return ([], false) }
                return (try? store.soundBankPrograms(source: source)) ?? ([], false)
            },
            audioUnits: { [weak store] in store?.availableAudioUnits() ?? [] },
            importer: { [weak store] url in
                guard let store else { throw DebugError("project store unavailable") }
                return try store.importSoundBank(from: url)
            })

        // The AU-effect picker model (m13-g): the installed AU EFFECTS flow in
        // through a store-backed provider (the SAME `availableAudioUnitEffects`
        // registry the wire's `fx.listAudioUnits` / `fx.add` use), so the headless
        // model stays off the engine bridge; selection is applied by the view via
        // `applyEffectChoice` → `store.addEffect(kind:.audioUnit)`.
        self.effectPicker = EffectPickerModel(
            audioUnits: { [weak store] in store?.availableAudioUnitEffects() ?? [] })

        // The built-in insert effect editor model (m17-a): reads the LIVE
        // descriptor (so a wire `fx.setParam` moves the open card's sliders and
        // a removed effect honestly blanks it) and applies every edit through
        // the SAME store methods the wire's `fx.setParam` calls — trackID nil =
        // the MASTER chain (the `MixerInsertsSection` convention). The store's
        // per-(effect, name) coalescing makes a slider drag ONE undo step.
        self.effectEditor = EffectEditorModel(
            descriptor: { [weak store] trackID, effectID in
                guard let store else { return nil }
                if let trackID {
                    return store.tracks.first { $0.id == trackID }?
                        .effects.first { $0.id == effectID }
                }
                return store.masterEffects.first { $0.id == effectID }
            },
            apply: { [weak store] trackID, effectID, name, value in
                guard let store else { throw DebugError("project store unavailable") }
                if let trackID {
                    _ = try store.setEffectParam(
                        trackID: trackID, effectID: effectID, name: name, value: value)
                } else {
                    _ = try store.setMasterEffectParam(effectID: effectID, name: name, value: value)
                }
            },
            setBypassed: { [weak store] trackID, effectID, bypassed in
                guard let store else { throw DebugError("project store unavailable") }
                if let trackID {
                    try store.setEffectBypassed(
                        trackID: trackID, effectID: effectID, bypassed: bypassed)
                } else {
                    try store.setMasterEffectBypassed(effectID: effectID, bypassed: bypassed)
                }
            })

        // The Quantize & Groove model (m11-a): the built-in MPC swings are computed
        // once; the saved-template list, Apply, and Extract all route through the
        // store methods the wire uses (`quantizeClipNotes` = ONE undo step via its
        // `clip.quantize:<id>` coalescing key; `extractGroove` for both MIDI onsets
        // and audio transients). UI-only — no parallel mutation path.
        self.quantizeModel = QuantizeModel(
            builtinGrooves: GrooveTemplate.builtinNames.compactMap { GrooveTemplate.builtin(named: $0) },
            savedGrooves: { [weak store] in store?.grooveTemplates ?? [] },
            apply: { [weak store] clipID, settings in
                _ = try? store?.quantizeClipNotes(clipId: clipID, settings: settings)
            },
            extract: { [weak store] clipID, name, grid, cycle in
                guard let store else { throw DebugError("project store unavailable") }
                return try await store.extractGroove(
                    fromClipId: clipID, name: name, gridBeats: grid, cycleBeats: cycle)
            })

        // The Undo-history model (m11-b): reads the store's label projection and
        // steps through history by RE-DRIVING the same `undo()`/`redo()` the wire
        // and Cmd-Z use — so the coalescing barrier + mid-take guard apply and no
        // parallel mutation path exists. Each step closure returns whether it
        // actually happened, so a multi-step jump stops early if a guard refuses.
        self.undoHistoryModel = UndoHistoryModel(
            history: { [weak store] in store?.undoHistory() ?? UndoHistory(undo: [], redo: []) },
            undoStep: { [weak store] in
                guard let store else { return false }
                return (try? store.undo()) != nil
            },
            redoStep: { [weak store] in
                guard let store else { return false }
                return (try? store.redo()) != nil
            })

        // The tempo-lane model (m12-d): reads the store's RESOLVED tempo/meter maps
        // and applies every edit through the SAME `setTempoMap` the `tempo.setMap`
        // wire uses (ONE undo via the "tempo.map" coalescing key). UI-only — no
        // parallel mutation path; the wire and the lane stay equivalent by
        // construction.
        self.tempoLaneModel = TempoLaneModel(
            map: { [weak store] in
                let transport = store?.transport
                return (transport?.tempoMap ?? TempoMap(constantBPM: 120),
                        transport?.meterMap ?? MeterMap(constant: TimeSignature()))
            },
            apply: { [weak store] tempo, meter in
                try store?.setTempoMap(tempo, meterMap: meter)
            })

        // API-key management over the system Keychain (M6). Env vars still win
        // (highest precedence); the Keychain is the in-app fallback. Key VALUES
        // never leave this Mac and never cross the control plane — the wire gets
        // status only (see `ai.providerStatus`). One store instance is shared
        // with the router so `ai.providerStatus` reflects what the UI manages.
        let keyStore = KeychainKeyStore()
        self.settings = SettingsModel(store: keyStore)

        // The Lyrics Workshop: resolves a lyrics writer from the SAME key chain
        // the Settings panel manages (Anthropic preferred, OpenAI fallback, else
        // an actionable no-key error surfaced in the panel), reads the live
        // project key/tempo/time-signature as context, and applies its finished
        // draft straight into the Sketchpad's lyrics editor. Key VALUES never
        // leave this Mac — the workshop reads presence only, via resolveLyricsWriter.
        self.lyricsWorkshop = LyricsWorkshopModel(
            makeWriter: {
                try resolveLyricsWriter(
                    environment: ProcessInfo.processInfo.environment, store: keyStore)
            },
            contextProvider: { [weak store] in
                guard let store else { return LyricsWriteContext() }
                let t = store.transport
                return LyricsWriteContext(
                    tempoBPM: t.tempoBPM,
                    timeSignature: "\(t.timeSignature.beatsPerBar)/\(t.timeSignature.beatUnit)")
            },
            applier: { [weak sketchpad] lyrics in
                sketchpad?.lyrics = lyrics
            })

        // Resolve the bind port through the m10-l resolver: env override > the
        // persisted in-app setting > default 17600. With no env AND no setting this
        // is byte-identical to the pre-m10-l inline read (17600). THE ENV OVERRIDE
        // IS SACRED — a persisted setting can never outrank DAW_CONTROL_PORT (the
        // staging harness relies on this).
        let portResolution = controlPortStore.resolution()
        let port = portResolution.port
        let router = CommandRouter(
            store: store, sidecarManager: sidecarManager,
            // The wire's origin-tagged observer (m17-h): every `ai.*` job an
            // agent submits lands on the unified progress card tagged "wire";
            // the import seam gets its own "import"-tagged wrapper. Both wrap
            // the SAME `songGenerator`, so job state stays unified.
            songGenerator: wireGenerator, keyStore: keyStore,
            // Hand the resolved endpoint to the router so `app.connectionInfo` can
            // report it (the server owns the router, so it can't ask back). Value
            // in, no cycle.
            connectionInfo: ControlConnectionInfo(
                port: port, source: portResolution.source.rawValue,
                defaultPort: ControlPortConfig.defaultPort),
            importGenerator: importGenerator)
        // m18-b: the wedge monitor must exist before the server so the queue
        // tier can consult it on every frame. Strong capture is cycle-free
        // (server → closure → monitor; the monitor references nothing back).
        let livenessMonitor = MainActorLivenessMonitor()
        self.livenessMonitor = livenessMonitor
        let server = ControlServer(
            router: router, port: port,
            livenessSnapshot: { livenessMonitor.snapshot() })
        self.router = router
        // Two-phase, no-retain-cycle wiring (the appCommandHandler precedent):
        // the engine strongly captures `router` via the dispatch closure; the
        // router only holds the engine back weakly (`copilotEngine`).
        // Inject the round-budget resolver (beta m10-m): the engine reads
        // `copilotLimitsStore.maxRounds` FRESH at the start of each turn, so a
        // Settings change takes effect on the next reply. Capture the store instance
        // (not self) so the engine's held closure never retains the app model.
        let copilotEngine = CopilotEngine(
            store: store,
            dispatch: { await router.handle($0) },
            maxToolRounds: { [copilotLimitsStore] in copilotLimitsStore.maxRounds })
        self.copilotEngine = copilotEngine
        router.copilotEngine = copilotEngine
        // Plugin windows (M3 vi-b): the app owns the manager; the router holds it
        // weakly (the copilotEngine precedent), and the engine's registry-release
        // callback drives every auto-close (the single invalidation authority).
        let pluginWindows = PluginWindowManager(engine: engine, store: store)
        self.pluginWindows = pluginWindows
        router.pluginUI = pluginWindows
        engine.hostedAUReleased = { [weak pluginWindows] endpoint in
            pluginWindows?.hostedAUReleased(endpoint)
        }
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
        // m18-b: start pinging the main actor. Deliberately OUTSIDE the
        // server's do/catch — the wedge breadcrumb log is worth having even
        // when the control plane failed to bind.
        livenessMonitor.start()
        // The onboarding signal adapter observes the store and fires the tour's
        // completion signals (ob-b) — for UI AND wire-driven actions alike.
        onboardingAdapter = OnboardingSignalAdapter(store: store, model: onboarding)
        onboardingAdapter.start()
        installDebugCommands()
        // Space-bar transport toggle (m17-d): the app-wide key monitor. Last —
        // it reads store state only through the toggle funnel, no init order
        // dependency, but keeping bootstrap side effects at the tail is house style.
        installSpaceKeyMonitor()
    }

    /// Offers the tour on first launch: begins it when eligible (fresh / reset).
    /// Idempotent — `begin()` no-ops once active, and the two terminals never
    /// re-offer, so calling this on every ContentView appear is safe.
    func offerTourIfEligible() {
        if onboarding.shouldOfferTour { onboarding.begin() }
    }

    /// The Settings "Replay tour" seam: return the tour to eligible, then start it
    /// from the welcome card.
    func replayTour() {
        onboarding.reset()
        onboarding.begin()
    }

    /// RESTORE on the crash-recovery sheet (crash-b): load the autosaved snapshot
    /// as the live session (kept dirty, source path preserved), then dismiss. Same
    /// store path as `project.recover accept:true`; a failure just drops the offer
    /// (nothing to restore into — the session is untouched).
    func restoreFromRecovery() {
        defer { withAnimation(.easeOut(duration: 0.18)) { recoveryOffer = nil } }
        do {
            _ = try store.recoverFromAutosave(accept: true)
        } catch {
            FileHandle.standardError.write(
                Data("recovery restore failed: \(error.localizedDescription)\n".utf8))
        }
    }

    /// DISCARD on the crash-recovery sheet (crash-b): drop the snapshot and fall
    /// through to the normal fresh-launch session. Same store path as
    /// `project.recover accept:false`.
    func discardRecovery() {
        _ = try? store.recoverFromAutosave(accept: false)
        withAnimation(.easeOut(duration: 0.18)) { recoveryOffer = nil }
    }

    /// Runs the bounce-to-file flow behind the transport EXPORT button and the
    /// onboarding `export` step (ob-b): an NSSavePanel, then
    /// `store.renderBounce(toPath:)`. Completion flows through the store's
    /// `renderCompletedCount` — the onboarding adapter fires `renderCompleted` on
    /// the increment, so there is ONE path and no direct tour-signal emission here.
    func exportSong() {
        let panel = NSSavePanel()
        panel.title = "Export Song"
        panel.prompt = "Export"
        panel.nameFieldStringValue = "\(store.projectName).wav"
        panel.allowedContentTypes = [.wav]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                _ = try await store.renderBounce(toPath: url.path)
            } catch {
                FileHandle.standardError.write(
                    Data("export failed: \(error.localizedDescription)\n".utf8))
            }
        }
    }

    /// Opens (or focuses) the floating plugin window for a track's AU instrument
    /// or one AU insert effect (M3 vi-b) — the mixer/instrument open-window
    /// buttons and the wire's `plugin.openUI` converge on the SAME manager.
    /// Fire-and-forget: a not-ready/headless failure logs and is otherwise a
    /// no-op (the button never blocks the UI).
    func openPluginWindow(trackID: UUID, effectID: UUID? = nil) {
        let target: PluginUITarget = effectID.map { .effect(trackID: trackID, effectID: $0) }
            ?? .instrument(trackID: trackID)
        Task { @MainActor in
            do {
                _ = try await pluginWindows.openUI(target, x: nil, y: nil)
            } catch {
                FileHandle.standardError.write(Data(
                    "plugin window open failed: \(error.localizedDescription)\n".utf8))
            }
        }
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
            case "debug.panelDensity":
                return try self.setPanelDensity(params)
            case "debug.panelLayout":
                return self.setPanelLayout(params)
            case "debug.windowFrame":
                return self.setWindowFrame(params)
            case "debug.arrangeScroll":
                return self.setArrangeScroll(params)
            case "debug.arrangeZoom":
                return try self.arrangeZoomDebug(params)
            case "debug.arrangePointer":
                return try self.arrangePointerDebug(params)
            case "debug.keySpace":
                return try self.keySpaceDebug(params)
            case "debug.mainActorWedge":
                return try self.mainActorWedgeDebug(params)
            case "debug.mixerAddAU":
                return self.mixerAddAUDebug(params)
            case "debug.effectPicker":
                return self.effectPickerDebug(params)
            case "debug.effectEditor":
                return try self.effectEditorDebug(params)
            case "debug.explainMode":
                return try self.setExplainMode(params)
            case "debug.vibeSeed":
                return try self.setVibeSeed(params)
            case "debug.onboardingState":
                return try self.setOnboardingState(params)
            case "debug.recoveryOffer":
                return self.setRecoveryOffer(params)
            case "debug.importAudio":
                return try self.importAudioDebug(params)
            case "debug.masterCapture":
                return try self.masterCaptureDebug(params)
            case "debug.postEngineNotice":
                return self.postEngineNoticeDebug(params)
            case "ui.showAutomation":
                return try self.showAutomation(params)
            case "ui.showTakes":
                return try self.showTakes(params)
            case "ui.showSketchpad":
                return self.showSketchpadCommand(params)
            case "debug.sketchpadDemo":
                return self.sketchpadDemo(params)
            case "debug.sidecarSeed":
                return try self.setSidecarSeed(params)
            case "debug.sketchpadGenerate":
                return try self.sketchpadGenerate(params)
            case "debug.sketchpadRefresh":
                return self.sketchpadRefresh(params)
            case "debug.sketchpadImport":
                return try self.sketchpadImport(params)
            case "debug.sketchpadState":
                return self.sketchpadStateResponse()
            case "ui.showClipFix":
                return self.showClipFixCommand(params)
            case "debug.clipFixSeed":
                return self.clipFixSeed(params)
            case "debug.clipFixState":
                return self.clipFixStateResponse()
            case "debug.instrumentPicker":
                return self.instrumentPickerDebug(params)
            case "debug.quantizePanel":
                return self.quantizePanelDebug(params)
            case "debug.tempoLane":
                return self.tempoLaneDebug(params)
            case "debug.undoHistory":
                return self.undoHistoryDebug(params)
            case "debug.markerRename":
                return self.markerRenameDebug(params)
            case "ui.showCopilot":
                return self.showCopilotCommand(params)
            case "debug.copilotSeed":
                return self.copilotSeed(params)
            case "debug.copilotState":
                return self.copilotStateResponse()
            case "ui.showLyricsWorkshop":
                return self.showLyricsWorkshopCommand(params)
            case "debug.lyricsWorkshopSeed":
                return self.lyricsWorkshopSeed(params)
            case "debug.lyricsWorkshopState":
                return self.lyricsWorkshopStateResponse()
            case "debug.generationCard":
                return try self.generationCardDebug(params)
            case "debug.sketchpadReset":
                self.sketchpad.setCandidatesForCapture([])
                self.sketchpad.prompt = ""
                self.sketchpad.lyrics = ""
                return self.sketchpadStateResponse()
            case "ui.showSettings":
                return self.showSettingsCommand(params)
            case "debug.settingsSeed":
                return self.settingsSeed(params)
            case "debug.settingsReset":
                return self.settingsReset()
            case "debug.settingsState":
                return self.settingsStateResponse()
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

    /// `debug.panelDensity {panel, mode}` — stages a panel's Simple/Pro density so
    /// a headless capture / E2E can drive a panel into Pro before `debug.captureUI`
    /// (the `debug.sketchpadDemo` seed-then-capture precedent). Writes straight to
    /// the shared `panelDensity` store, so the panel's live `SimpleProToggle`
    /// reflects it. Debug tier ONLY — off `allCommands`/MCP (density is UI chrome;
    /// agents drive the protocol directly, not the chrome). Params: `panel`
    /// (required, e.g. `"pianoRoll"`), `mode` (`"simple"` | `"pro"`). Unknown mode
    /// → error; happy path returns the resulting `{panel, mode}`.
    private func setPanelDensity(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let panel = params["panel"]?.stringValue, !panel.isEmpty else {
            throw DebugError("debug.panelDensity requires a panel")
        }
        guard let modeRaw = params["mode"]?.stringValue else {
            throw DebugError("debug.panelDensity requires a mode (\"simple\" or \"pro\")")
        }
        guard let density = PanelDensity(rawValue: modeRaw) else {
            throw DebugError("unknown mode \"\(modeRaw)\" — expected \"simple\" or \"pro\"")
        }
        panelDensity.setDensity(density, forPanel: panel)
        return .object([
            "panel": .string(panel),
            "mode": .string(density.rawValue),
        ])
    }

    /// `debug.panelLayout {sidebarWidth?, editorFraction?, rowHeight?, reset?}` —
    /// stages the adjustable window layout (beta m10-d) so a headless capture / E2E
    /// can drive the arrange sidebar width, the bottom editor's height fraction, and
    /// the global track-row height before `debug.captureUI` (the `debug.panelDensity`
    /// precedent: writes straight to the shared `panelLayout` store so the live
    /// splitters reflect it). Debug tier ONLY — off `allCommands`/MCP (window layout
    /// is a UI preference, not an invokable capability; agents drive the protocol,
    /// not the chrome). Every field is optional; `reset:true` restores the defaults
    /// FIRST (so `{reset:true, rowHeight:48}` resets then applies 48). Values are
    /// clamped by the store, and the result echoes the APPLIED (post-clamp) values.
    private func setPanelLayout(_ params: [String: JSONValue]) -> JSONValue {
        if params["reset"]?.boolValue == true { panelLayout.reset() }
        if let w = params["sidebarWidth"]?.doubleValue { panelLayout.setSidebarWidth(CGFloat(w)) }
        if let f = params["editorFraction"]?.doubleValue { panelLayout.setEditorFraction(CGFloat(f)) }
        if let h = params["rowHeight"]?.doubleValue { panelLayout.setRowHeight(CGFloat(h)) }
        return .object([
            "sidebarWidth": .number(Double(panelLayout.sidebarWidth)),
            "editorFraction": .number(Double(panelLayout.editorFraction)),
            "rowHeight": .number(Double(panelLayout.rowHeight)),
        ])
    }

    /// Applies the MEASURED window floor (m10-j) to the live NSWindow's
    /// `contentMinSize`, so a user drag can never shrink the window below the point
    /// where the transport / title row / TRACKS header would leave the frame. Called
    /// once the window exists (ContentView's onAppear); a no-op headless.
    func applyWindowFloor() {
        let window = mainCaptureWindow
        // Capture THE content window for the space-bar toggle's main-window-only
        // guard (m17-d) — at first appearance the WindowGroup window is the only
        // one, so this can never latch a plugin panel.
        contentWindow = window
        window?.contentMinSize = CGSize(width: WindowFloor.minWidth,
                                        height: WindowFloor.minHeight)
    }

    /// `debug.windowFrame {width?, height?}` — stages the main window's CONTENT size
    /// for captures/E2E (the `debug.panelLayout` precedent: app-level handler, debug
    /// tier ONLY — off `allCommands`/MCP, since window size is a chrome/verification
    /// affordance, not an invokable capability). Called with NO size params it just
    /// echoes the current frame. A requested `width`/`height` is CLAMPED to the
    /// measured `WindowFloor` (min 1208×640) and applied keeping the window's TOP-LEFT
    /// fixed (so a shrink reveals the floor without walking the title bar off-screen).
    /// The result echoes the resulting content size + origin + the floor, so a gate
    /// can assert it landed exactly on the enforced minimum.
    private func setWindowFrame(_ params: [String: JSONValue]) -> JSONValue {
        guard let window = mainCaptureWindow else {
            // Headless / no window yet: still report the floor so a caller learns it.
            return .object([
                "error": .string("no window"),
                "minWidth": .number(Double(WindowFloor.minWidth)),
                "minHeight": .number(Double(WindowFloor.minHeight)),
            ])
        }
        // The floor is also enforced on the NSWindow itself; re-assert here so a
        // frame set can't outrun a not-yet-applied contentMinSize.
        window.contentMinSize = CGSize(width: WindowFloor.minWidth, height: WindowFloor.minHeight)
        if params["width"] != nil || params["height"] != nil {
            let content = window.contentRect(forFrameRect: window.frame)
            let reqW = params["width"]?.doubleValue.map { CGFloat($0) } ?? content.width
            let reqH = params["height"]?.doubleValue.map { CGFloat($0) } ?? content.height
            let clamped = WindowFloor.clamp(width: reqW, height: reqH)
            let newFrame = window.frameRect(forContentRect: CGRect(
                x: content.minX, y: content.minY, width: clamped.width, height: clamped.height))
            // Keep the top-left corner stationary: AppKit origins are bottom-left, so
            // hold the current top (maxY) and drop the origin by the new height.
            let top = window.frame.maxY
            var framed = newFrame
            framed.origin.x = window.frame.minX
            framed.origin.y = top - framed.height
            window.setFrame(framed, display: true)
        }
        let content = window.contentRect(forFrameRect: window.frame)
        return .object([
            "width": .number(Double(content.width)),
            "height": .number(Double(content.height)),
            "x": .number(Double(window.frame.minX)),
            "y": .number(Double(window.frame.minY)),
            "minWidth": .number(Double(WindowFloor.minWidth)),
            "minHeight": .number(Double(WindowFloor.minHeight)),
        ])
    }

    /// `debug.arrangeScroll {trackId?, index?, bottom?, reset?}` — jumps the shared
    /// arrange vertical scroll to a track so a capture can frame the BOTTOM of a
    /// deep session with the ruler block still pinned (m13-g G3). App-level, debug
    /// tier ONLY (off `allCommands`/MCP — a chrome/verification affordance, the
    /// `debug.windowFrame` precedent). `trackId` names the target directly; `index`
    /// picks the Nth track (default: the LAST, i.e. scroll to the bottom); `bottom`
    /// (default true) anchors the target at the viewport bottom; `reset` scrolls back
    /// to the first track (top). Echoes the resolved target.
    private func setArrangeScroll(_ params: [String: JSONValue]) -> JSONValue {
        workspaceMode = .arrange
        let tracks = store.tracks
        guard !tracks.isEmpty else {
            arrangeScrollTarget = nil
            return .object(["ok": .bool(false), "reason": .string("no tracks")])
        }
        if params["reset"]?.boolValue == true {
            arrangeScrollToBottom = false
            arrangeScrollTarget = tracks.first?.id
            arrangeScrollNonce += 1
            return arrangeScrollResponse()
        }
        let target: Track
        if let raw = params["trackId"]?.stringValue, let id = UUID(uuidString: raw),
           let match = tracks.first(where: { $0.id == id }) {
            target = match
        } else if let idx = params["index"]?.doubleValue.map({ Int($0) }),
                  tracks.indices.contains(idx) {
            target = tracks[idx]
        } else {
            target = tracks[tracks.count - 1]   // default: the bottom of the session
        }
        arrangeScrollToBottom = params["bottom"]?.boolValue ?? true
        arrangeScrollTarget = target.id
        arrangeScrollNonce += 1
        return arrangeScrollResponse()
    }

    private func arrangeScrollResponse() -> JSONValue {
        .object([
            "ok": .bool(true),
            "trackId": arrangeScrollTarget.map { JSONValue.string($0.uuidString) } ?? .null,
            "bottom": .bool(arrangeScrollToBottom),
        ])
    }

    // MARK: - Arrange zoom (m17-b)

    /// The live arrange horizontal zoom (pixels per beat) — one source of truth
    /// in the persisted layout store.
    var arrangePPB: CGFloat { panelLayout.arrangePPB }

    /// The current track-row-height step (S/M/L), classified from the continuous
    /// `panelLayout.rowHeight` (the m10-d splitter can sit between steps).
    var arrangeRowStep: ArrangeZoom.RowStep {
        ArrangeZoom.rowStep(closestTo: panelLayout.rowHeight)
    }

    /// Sets the arrange zoom, keeping one screen point visually stationary (the
    /// no-jump rule): the PLAYHEAD's screen x when it's inside the viewport,
    /// else the viewport center — or an explicit `anchorScreenX` (pointer /
    /// debug seam). Writes the scale to the layout store and hands the
    /// compensating scroll offset to the lanes bridge + the pinned ruler in the
    /// SAME update, so both columns move together.
    func setArrangeZoom(toPPB raw: CGFloat, anchorScreenX explicit: CGFloat? = nil) {
        let old = panelLayout.arrangePPB
        let new = ArrangeZoom.clamp(raw)
        guard abs(new - old) > 0.0001 else { return }
        let anchor = explicit ?? ArrangeZoom.anchorScreenX(
            playheadContentX: CGFloat(store.transport.positionBeats) * old,
            offset: arrangeHScroll,
            viewportWidth: arrangeViewportWidth)
        let newOffset = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: old, newPPB: new, oldOffset: arrangeHScroll, anchorScreenX: anchor)
        panelLayout.setArrangePPB(new)
        applyArrangeHScroll(newOffset)
    }

    /// One ladder step in (⌘+ / toolbar "+").
    func zoomArrangeIn() { setArrangeZoom(toPPB: ArrangeZoom.zoomedIn(arrangePPB)) }
    /// One ladder step out (⌘− / toolbar "−").
    func zoomArrangeOut() { setArrangeZoom(toPPB: ArrangeZoom.zoomedOut(arrangePPB)) }
    /// Back to the historical 16 pt/beat (⌘0).
    func zoomArrangeReset() { setArrangeZoom(toPPB: ArrangeZoom.defaultPixelsPerBeat) }

    /// Sets the stepped track-row height (S/M/L) through the SAME
    /// `panelLayout.rowHeight` slot the m10-d splitter drags — the sidebar rows
    /// and the lanes read that one value, so both columns stay row-aligned.
    func setArrangeRowStep(_ step: ArrangeZoom.RowStep) {
        panelLayout.setRowHeight(step.rowHeight)
    }

    /// A live pinch tick from the lanes (m17-b): the first tick captures the
    /// anchor (`PinchState` — fixed beat + screen x under the pointer), each
    /// tick rescales off the gesture-START state so magnification stays
    /// cumulative and the anchor never feeds its own motion back.
    func arrangePinchChanged(anchorContentX: CGFloat, magnification: CGFloat) {
        if arrangePinch == nil {
            arrangePinch = ArrangeZoom.PinchState(
                startPPB: arrangePPB, startOffset: arrangeHScroll,
                anchorContentX: anchorContentX)
        }
        guard let pinch = arrangePinch else { return }
        let zoomed = pinch.zoomed(magnification: magnification)
        guard abs(zoomed.ppb - arrangePPB) > 0.0001 else { return }
        panelLayout.setArrangePPB(zoomed.ppb)
        applyArrangeHScroll(zoomed.offset)
    }

    func arrangePinchEnded() { arrangePinch = nil }

    /// Routes a computed offset to BOTH sync surfaces in one update: the pinned
    /// ruler mirror (`arrangeHScroll` — the preference will re-confirm it from
    /// the real layout) and the lanes' AppKit bridge (nonce-bumped so repeats
    /// still apply).
    private func applyArrangeHScroll(_ offset: CGFloat) {
        arrangeHScroll = offset
        arrangeZoomScrollTarget = offset
        arrangeZoomScrollNonce += 1
    }

    /// `debug.arrangeZoom {ppb?, step?, rowStep?, reset?, anchorX?}` — the m17-b
    /// zoom seam for captures/E2E (the `debug.arrangeScroll` precedent:
    /// app-level, debug tier ONLY, off `allCommands`/MCP — zoom is UI state, so
    /// ZERO new wire surface). `ppb` sets the scale through the SAME
    /// anchor-preserving path the menu/toolbar use; `step` ("in"|"out") walks
    /// the ladder; `anchorX` pins an explicit screen x (else playhead/center);
    /// `rowStep` ("small"|"medium"|"large") sets the row-height ladder;
    /// `reset:true` restores both defaults. A BARE call is READ-ONLY (the
    /// m11-a law) and echoes {ppb, rowStep, rowHeight, hOffset, viewportWidth,
    /// playheadBeat, playheadScreenX} so a gate can assert anchor stability
    /// from the REAL reported offset.
    private func arrangeZoomDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        let anchorX = params["anchorX"]?.doubleValue.map { CGFloat($0) }
        let mutating = params["ppb"] != nil || params["step"] != nil
            || params["rowStep"] != nil || params["reset"]?.boolValue == true
        if mutating { workspaceMode = .arrange }
        if params["reset"]?.boolValue == true {
            setArrangeZoom(toPPB: ArrangeZoom.defaultPixelsPerBeat, anchorScreenX: anchorX)
            setArrangeRowStep(.medium)
        }
        if let raw = params["ppb"]?.doubleValue {
            setArrangeZoom(toPPB: CGFloat(raw), anchorScreenX: anchorX)
        }
        if let step = params["step"]?.stringValue {
            switch step {
            case "in": setArrangeZoom(toPPB: ArrangeZoom.zoomedIn(arrangePPB), anchorScreenX: anchorX)
            case "out": setArrangeZoom(toPPB: ArrangeZoom.zoomedOut(arrangePPB), anchorScreenX: anchorX)
            default: throw DebugError("unknown step \"\(step)\" — expected \"in\" or \"out\"")
            }
        }
        if let raw = params["rowStep"]?.stringValue {
            guard let step = ArrangeZoom.RowStep(rawValue: raw) else {
                throw DebugError("unknown rowStep \"\(raw)\" — expected \"small\", \"medium\", or \"large\"")
            }
            setArrangeRowStep(step)
        }
        let ppb = arrangePPB
        let playheadBeat = store.transport.positionBeats
        return .object([
            "ppb": .number(Double(ppb)),
            "rowStep": .string(arrangeRowStep.rawValue),
            "rowHeight": .number(Double(panelLayout.rowHeight)),
            // GROUND TRUTH: the preference-REPORTED offset (real layout), never
            // the analytic mirror — a failed programmatic scroll shows up here.
            "hOffset": .number(Double(arrangeHScrollReported)),
            "hOffsetMirror": .number(Double(arrangeHScroll)),
            "viewportWidth": .number(Double(arrangeViewportWidth)),
            "playheadBeat": .number(playheadBeat),
            "playheadScreenX": .number(Double(CGFloat(playheadBeat) * ppb - arrangeHScrollReported)),
        ])
    }

    /// `debug.arrangePointer {act?, x?, y?}` — the m17-c pointer seam for
    /// captures/E2E (the `debug.arrangeZoom` precedent: app-level, debug tier
    /// ONLY, off `allCommands`/MCP — pointer affordances ride the EXISTING
    /// `transport.seek`/`clip.split` verbs, so ZERO new wire surface).
    /// `act` is "hover" | "click" | "doubleClick" | "clear"; `x`/`y` are
    /// CONTENT-space points (x = beats · ppb — zoom-exact without knowing the
    /// scroll offset), required for all but "clear". The staged event runs
    /// through the SAME view handlers a real pointer uses; the echo reflects
    /// the state the view last REPORTED, so after a mutating call settle one
    /// main-actor turn (~250 ms, the m17-b law) and re-read with a bare call.
    /// A BARE call is READ-ONLY (the m11-a law) and echoes
    /// {zone, ghostBeat, playheadBeat, ppb, refusal, refusalClipId}.
    private func arrangePointerDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let act = params["act"]?.stringValue {
            guard let action = ArrangePointerStage.Action(rawValue: act) else {
                throw DebugError(
                    "unknown act \"\(act)\" — expected \"hover\", \"click\", \"doubleClick\", or \"clear\"")
            }
            workspaceMode = .arrange
            var x: CGFloat = 0, y: CGFloat = 0
            if action != .clear {
                guard let xv = params["x"]?.doubleValue, let yv = params["y"]?.doubleValue else {
                    throw DebugError(
                        "act \"\(act)\" needs content-space x and y (points; x = beats · ppb)")
                }
                x = CGFloat(xv)
                y = CGFloat(yv)
            }
            arrangePointerStage = ArrangePointerStage(
                action: action, x: x, y: y,
                nonce: (arrangePointerStage?.nonce ?? 0) + 1)
        }
        return .object([
            "zone": .string(arrangePointerZone),
            "ghostBeat": arrangeGhostBeat.map { .number($0) } ?? .null,
            "playheadBeat": .number(store.transport.positionBeats),
            "ppb": .number(Double(arrangePPB)),
            "refusal": arrangeSplitRefusal.map { .string($0.message) } ?? .null,
            "refusalClipId": arrangeSplitRefusal?.clipID.map { .string($0.uuidString) } ?? .null,
        ])
    }

    /// `debug.keySpace {press?, post?, command?, option?, control?, shift?, repeat?}`
    /// — the space-bar transport toggle's staging seam (m17-d). App-level, debug
    /// tier ONLY (off `allCommands`/MCP — ZERO wire growth; play/stop already
    /// exist as `transport.play`/`transport.stop`, the space bar is just a UI
    /// driver for the same funnels). Real key injection needs an Accessibility
    /// grant the staging binary lacks (measured law), so the seam synthesizes an
    /// `NSEvent` and exercises the REAL code path:
    ///   - `{}` — pure state read (the `debug.effectEditor` convention): monitor
    ///     installed, window role, the content window's first-responder class +
    ///     classification, the focused field's text when one is editing, and the
    ///     transport state.
    ///   - `{press:true}` — synthesizes the space key-down (modifier/repeat/
    ///     `noWindow` overrides for matrix probing; `noWindow:true` targets an
    ///     unresolvable window number → the `.secondary` branch) and runs the
    ///     SAME `handleKeyDownEvent` body the live monitor runs. Echoes the
    ///     decision + resulting transport.
    ///   - `{press:true, post:true}` — posts the event through the REAL queue
    ///     instead (`NSApp.postEvent`): the live monitor fires, and a passed-
    ///     through space genuinely reaches the responder chain (a focused rename
    ///     field gains the character). Asynchronous — settle, then read `{}`.
    private func keySpaceDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        guard params["press"]?.boolValue == true else { return keySpaceStateResponse() }
        var flags: NSEvent.ModifierFlags = []
        if params["command"]?.boolValue == true { flags.insert(.command) }
        if params["option"]?.boolValue == true { flags.insert(.option) }
        if params["control"]?.boolValue == true { flags.insert(.control) }
        if params["shift"]?.boolValue == true { flags.insert(.shift) }
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: params["noWindow"]?.boolValue == true
                ? 0 : (contentWindow?.windowNumber ?? 0),
            context: nil,
            characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: params["repeat"]?.boolValue ?? false,
            keyCode: TransportKeyRouting.spaceKeyCode) else {
            throw DebugError("failed to synthesize the space key event")
        }
        if params["post"]?.boolValue == true {
            NSApplication.shared.postEvent(event, atStart: false)
            return keySpaceStateResponse(extra: ["posted": .bool(true)])
        }
        let passedThrough = handleKeyDownEvent(event)
        let decision: TransportKeyDecision = passedThrough == nil ? .toggleTransport : .passThrough
        return keySpaceStateResponse(extra: [
            "decision": .string(decision.rawValue),
            "swallowed": .bool(passedThrough == nil),
        ])
    }

    /// `debug.mainActorWedge {seconds?}` — the m18-b staging seam for the
    /// main-actor liveness watchdog. App-level, debug tier ONLY (the
    /// `debug.arrangeZoom` precedent: off `allCommands`/MCP, ZERO wire growth
    /// — wedge visibility rides the EXISTING `engine.watchdogStatus` verb).
    ///   - `{}` — READ-ONLY (the m11-a bare-read law): the monitor snapshot
    ///     {responsive, wedgedForSeconds, pingsSent, pongsReceived,
    ///     lastWedgeDurationSeconds, wedgeThresholdSeconds}.
    ///   - `{seconds: N}` — deliberately BLOCKS the main actor for N seconds
    ///     (clamped 0.5–30) via `Thread.sleep`, staged `asyncAfter` 0.1 s out
    ///     so THIS response leaves the socket before the wedge begins. While
    ///     wedged, verify from a SECOND connection: `engine.watchdogStatus`
    ///     answers off-main with `mainActor.responsive: false`; every other
    ///     command gets the teaching error instead of a silent hang.
    /// Detection-only surface — nothing here kills or restarts anything.
    private func mainActorWedgeDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let secondsParam = params["seconds"] {
            guard let raw = secondsParam.doubleValue else {
                throw DebugError("'seconds' must be a number (0.5–30)")
            }
            let clamped = min(max(raw, 0.5), 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                Thread.sleep(forTimeInterval: clamped)
            }
            return .object([
                "staged": .bool(true),
                "seconds": .number(clamped),
                "startsInSeconds": .number(0.1),
            ])
        }
        let snap = livenessMonitor.snapshot()
        return .object([
            "responsive": .bool(snap.responsive),
            "wedgedForSeconds": snap.wedgedForSeconds.map { .number($0) } ?? .null,
            "pingsSent": .number(Double(snap.pingsSent)),
            "pongsReceived": .number(Double(snap.pongsReceived)),
            "lastWedgeDurationSeconds": snap.lastWedgeDurationSeconds.map { .number($0) } ?? .null,
            "wedgeThresholdSeconds": .number(snap.wedgeThresholdSeconds),
        ])
    }

    /// The `debug.keySpace` state echo: ground truth read fresh from the live
    /// window + store (never the seam's own input — the `arrangeHScrollReported`
    /// honesty rule). `fieldText` appears only while an `NSText` first responder
    /// is editing, so the focus gate can prove a passed-through space actually
    /// landed in the field.
    private func keySpaceStateResponse(extra: [String: JSONValue] = [:]) -> JSONValue {
        let responder = contentWindow?.firstResponder
        var fields: [String: JSONValue] = [
            "monitorInstalled": .bool(spaceKeyMonitor != nil),
            "windowRole": .string(transportKeyWindow(contentWindow).rawValue),
            "firstResponder": .string(Self.transportKeyResponder(responder).rawValue),
            "responderClass": responder.map { .string(String(describing: type(of: $0))) } ?? .null,
            "isPlaying": .bool(store.transport.isPlaying),
            "isRecording": .bool(store.transport.isRecording),
            "positionBeats": .number(store.transport.positionBeats),
        ]
        if let text = (responder as? NSText)?.string {
            fields["fieldText"] = .string(text)
        }
        for (key, value) in extra { fields[key] = value }
        return .object(fields)
    }

    /// `debug.mixerAddAU {trackId, index?, subType?}` — drives the EXACT store call
    /// the mixer inserts add-menu's "Audio Units" branch invokes (m13-g G2), so a
    /// gate can prove UI == wire without a nested-menu click-driver. Resolves the AU
    /// from the SAME `store.availableAudioUnitEffects()` registry the wire's
    /// `fx.add kind:"audioUnit"` uses, builds the config via `EffectPickerModel`
    /// (the picker modal's helper), and calls `store.addEffect(kind:.audioUnit,audioUnit:)`.
    /// App-level, debug tier ONLY (off `allCommands`/MCP). Echoes the new effectId.
    private func mixerAddAUDebug(_ params: [String: JSONValue]) -> JSONValue {
        guard let raw = params["trackId"]?.stringValue, let trackID = UUID(uuidString: raw),
              store.tracks.contains(where: { $0.id == trackID }) else {
            return .object(["ok": .bool(false), "reason": .string("track not found")])
        }
        let units = store.availableAudioUnitEffects()
        let unit: AudioUnitComponentInfo?
        if let subType = params["subType"]?.stringValue {
            unit = units.first { $0.component.subType.trimmingCharacters(in: .whitespaces)
                                  == subType.trimmingCharacters(in: .whitespaces) }
        } else {
            let idx = params["index"]?.doubleValue.map { Int($0) } ?? 0
            unit = units.indices.contains(idx) ? units[idx] : units.first
        }
        guard let unit else {
            return .object(["ok": .bool(false), "reason": .string("no AU effects installed")])
        }
        // The literal UI path: the modal builds the config via EffectPickerModel and
        // hands it to applyEffectChoice → store.addEffect(kind:.audioUnit).
        let config = effectPicker.config(for: unit)
        guard let effect = try? store.addEffect(toTrack: trackID, kind: .audioUnit,
                                                audioUnit: config) else {
            return .object(["ok": .bool(false), "reason": .string("addEffect failed")])
        }
        return .object([
            "ok": .bool(true),
            "trackId": .string(trackID.uuidString),
            "effectId": .string(effect.id.uuidString),
            "name": .string(unit.name),
        ])
    }

    /// `debug.explainMode {on, focus?, instance?}` — stages the violet "?" EXPLAIN
    /// overlay for a capture / E2E (the `debug.panelDensity` precedent: app-level
    /// handler, debug tier ONLY — off `allCommands`/MCP, since explain is UI chrome
    /// and agents drive the protocol directly). `on` toggles the mode (default true).
    /// Because the wire can't synthesize a pointer hover, the optional `focus` param
    /// names an `ExplainID` to programmatically present that control's card, and the
    /// optional `instance` (0-based, tree order; default 0) picks WHICH copy of a
    /// repeated control (e.g. the 3rd mixer strip) to anchor on — CAPTURE STAGING
    /// ONLY (normal use presents on hover, per-instance). Unknown focus → error;
    /// happy path returns the resulting `{on, focus, instance}`.
    private func setExplainMode(_ params: [String: JSONValue]) throws -> JSONValue {
        let on = params["on"]?.boolValue ?? true
        explain.setActive(on)
        if on, let raw = params["focus"]?.stringValue {
            guard let id = ExplainID(rawValue: raw) else {
                throw DebugError("unknown explain focus \"\(raw)\" — expected an ExplainID (e.g. \"transportPlay\")")
            }
            explain.focusedForCapture = id
            explain.focusedInstance = params["instance"]?.doubleValue.map { Int($0) }
        } else {
            explain.focusedForCapture = nil
            explain.focusedInstance = nil
        }
        return .object([
            "on": .bool(explain.isActive),
            "focus": explain.focusedForCapture.map { JSONValue.string($0.rawValue) } ?? .null,
            "instance": explain.focusedInstance.map { JSONValue.number(Double($0)) } ?? .null,
        ])
    }

    /// `debug.vibeSeed {bands?, levelDB?, peakDB?, centroidHz?, flux?}` — stages a
    /// synthetic master-analysis snapshot the session vibe meter prefers over the live
    /// engine poll, so a capture / E2E can show a specific mix feel without real audio
    /// (the `debug.explainMode focus` staging precedent). App-level, debug tier ONLY —
    /// off `allCommands`/MCP (it's UI chrome; agents drive the real audio path). The
    /// ENGINE is never touched — this only sets `vibeSeed`. `{clear: true}` drops the
    /// override back to the live poll. All fields optional with sensible mid-mix
    /// defaults; `bands` (when given) must carry exactly 24 values. Returns the seeded
    /// snapshot (or `{cleared: true}`).
    private func setVibeSeed(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["clear"]?.boolValue == true {
            vibeSeed = nil
            return .object(["cleared": .bool(true)])
        }
        let bandCount = MasterAnalysisSnapshot.bandCount
        var bands = [Float](repeating: -30, count: bandCount)
        if let raw = params["bands"]?.arrayValue {
            guard raw.count == bandCount else {
                throw DebugError("debug.vibeSeed bands must have exactly \(bandCount) values (got \(raw.count))")
            }
            bands = raw.map { Float($0.doubleValue ?? Double(MasterAnalysisSnapshot.floorDB)) }
        }
        let levelDB = params["levelDB"]?.doubleValue.map(Float.init) ?? -10
        let peakDB = params["peakDB"]?.doubleValue.map(Float.init) ?? (levelDB + 4)
        let centroidHz = params["centroidHz"]?.doubleValue.map(Float.init) ?? 2000
        let flux = params["flux"]?.doubleValue.map(Float.init) ?? 0.3
        let snapshot = MasterAnalysisSnapshot(bands: bands, levelDB: levelDB, peakDB: peakDB,
                                              centroidHz: centroidHz, flux: flux)
        vibeSeed = snapshot
        return .object([
            "levelDB": .number(Double(levelDB)),
            "peakDB": .number(Double(peakDB)),
            "centroidHz": .number(Double(centroidHz)),
            "flux": .number(Double(flux)),
            "bands": .array(bands.map { .number(Double($0)) }),
        ])
    }

    /// `debug.onboardingState {set?, signal?}` — stages the onboarding tour for a
    /// capture / E2E (the `debug.vibeSeed` / `debug.explainMode` idiom: app-level,
    /// debug tier ONLY — off `allCommands`/MCP, since the tour is UI chrome and
    /// agents drive the protocol directly). `set` FORCES a state
    /// (`"inactive"|"active:<i>"|"completed"|"dismissed"`, parsed via
    /// `OnboardingState(persisted:)`) by driving the FROZEN model API to that state;
    /// `signal` (an `OnboardingSignal` raw value) injects through the SAME
    /// `model.signal(_:)` path the app uses (so its strict active-step matching still
    /// governs). Both optional; `set` applies before `signal`. Unknown values →
    /// error. The response echoes the resulting persisted state string.
    private func setOnboardingState(_ params: [String: JSONValue]) throws -> JSONValue {
        if let raw = params["set"]?.stringValue {
            guard let target = OnboardingState(persisted: raw) else {
                throw DebugError("unknown onboarding state \"\(raw)\" — expected \"inactive\", \"active:<i>\", \"completed\", or \"dismissed\"")
            }
            forceOnboardingState(target)
        }
        if let raw = params["signal"]?.stringValue {
            guard let sig = OnboardingSignal(rawValue: raw) else {
                let valid = OnboardingSignal.allCases.map(\.rawValue).joined(separator: ", ")
                throw DebugError("unknown onboarding signal \"\(raw)\" — expected one of: \(valid)")
            }
            onboarding.signal(sig)
        }
        return .object(["state": .string(onboarding.state.persistedValue)])
    }

    /// Drives the FROZEN `OnboardingModel` public API to `target` (there is no state
    /// setter — the model API is frozen). `reset()` establishes the `inactive`
    /// baseline; `begin()` + bounded `advance()`s walk to an active index or to
    /// `completed`; `dismissTour()` reaches `dismissed`.
    private func forceOnboardingState(_ target: OnboardingState) {
        onboarding.reset()   // → inactive
        let stepCount = OnboardingStep.allCases.count
        switch target {
        case .inactive:
            break
        case .active(let i):
            onboarding.begin()   // → active(0)
            var guardCount = 0
            while (onboarding.stepIndex ?? Int.max) < i, guardCount < stepCount {
                onboarding.advance(); guardCount += 1
            }
        case .completed:
            onboarding.begin()
            var guardCount = 0
            while onboarding.currentStep != nil, guardCount <= stepCount {
                onboarding.advance(); guardCount += 1
            }
        case .dismissed:
            onboarding.dismissTour()   // inactive → dismissed
        }
    }

    /// `debug.recoveryOffer {show?, savedAt?, sourcePath?, editCount?}` — stages the
    /// crash-recovery sheet (crash-b) for a capture / E2E without an actual crash
    /// (the `debug.onboardingState` staging precedent: app-level, debug tier ONLY —
    /// off `allCommands`/MCP, since the sheet is UI chrome and agents drive the real
    /// `project.recover*` protocol). `show` (default true) floats a synthetic offer;
    /// `false` clears it. Optional `savedAt` (epoch seconds; default a fixed 14:32
    /// so the HH:MM readout is deterministic), `sourcePath` (default a sample so both
    /// readouts show), and `editCount`. Never touches the real autosave on disk —
    /// this ONLY sets `recoveryOffer`. Returns `{visible}`.
    private func setRecoveryOffer(_ params: [String: JSONValue]) -> JSONValue {
        let show = params["show"]?.boolValue ?? true
        if show {
            let savedAt = params["savedAt"]?.doubleValue.map { Date(timeIntervalSince1970: $0) }
                // 2024-01-01 14:32 local-agnostic default → a stable HH:MM readout.
                ?? Date(timeIntervalSince1970: 1_704_119_520)
            let sourcePath = params["sourcePath"].flatMap { value -> String? in
                if case .null = value { return nil }
                return value.stringValue ?? "~/Music/DAW Pro/Midnight Drive.dawproj"
            } ?? "~/Music/DAW Pro/Midnight Drive.dawproj"
            recoveryOffer = AutosaveRecoveryStatus(
                available: true,
                savedAt: savedAt,
                sourcePath: sourcePath,
                editCount: params["editCount"]?.doubleValue.map { Int($0) } ?? 12)
        } else {
            recoveryOffer = nil
        }
        return .object(["visible": .bool(recoveryOffer != nil)])
    }

    // MARK: - Audio import (beta m10-k) — File→Import + drag-drop shared pipeline

    /// The ONE execution path behind BOTH human import affordances (the File→Import
    /// menu and the arrange drag-drop) and the `debug.importAudio` staging command.
    /// Builds the headless `AudioImportPlan` from the live grid + the given context,
    /// maps its actions onto `store.importAudioBatch` (ONE undo step), and returns
    /// per-file results (imported clip/track, or a readable error) in input order.
    ///
    /// `targetTrackID` is the hovered/target track (its KIND is resolved here from
    /// the store, so callers pass only the id); a nil / non-audio target routes to
    /// new tracks, and multiple files always fan out — all decided by the plan.
    /// `atBeatRaw` is the unsnapped landing beat (drop-x or the playhead); the plan
    /// snaps it with the arrange EFFECTIVE snap (Bar in Simple).
    @discardableResult
    func importAudioFiles(urls: [URL], targetTrackID: UUID?,
                          atBeatRaw: Double) -> [AudioImportFileResult] {
        let targetKind = targetTrackID.flatMap { id in
            store.tracks.first(where: { $0.id == id })?.kind
        }
        let snap = ClipSnap.effective(
            density: panelDensity.density(forPanel: TimelineLanesView.panelID),
            picked: clipSnap)
        let context = AudioImportContext(
            targetTrackID: targetTrackID, targetTrackKind: targetKind,
            atBeatRaw: atBeatRaw, snap: snap,
            meterMap: store.transport.meterMap)
        let plan = AudioImportPlan(urls: urls, context: context)

        let requests: [AudioImportRequest] = plan.actions.map { action in
            switch action {
            case .existingTrack(let trackID, let startBeat, let url):
                return AudioImportRequest(url: url, destination: .existingTrack(trackID),
                                          startBeat: startBeat)
            case .newTrack(let name, let startBeat, let url):
                return AudioImportRequest(url: url, destination: .newTrack(name: name),
                                          startBeat: startBeat)
            }
        }

        var outcomeByURL: [URL: AudioImportOutcome] = [:]
        var batchError: String?
        do {
            for outcome in try store.importAudioBatch(requests) { outcomeByURL[outcome.url] = outcome }
        } catch {
            batchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }

        var rejectedByURL: [URL: String] = [:]
        for rejection in plan.rejected { rejectedByURL[rejection.url] = rejection.reason }

        // Preserve the caller's input order for a readable per-file report.
        return urls.map { url in
            if let reason = rejectedByURL[url] {
                return AudioImportFileResult(path: url.path, error: reason)
            }
            if let outcome = outcomeByURL[url] {
                return AudioImportFileResult(path: url.path, clipID: outcome.clip?.id,
                                             trackID: outcome.trackID,
                                             trackName: outcome.trackName, error: outcome.error)
            }
            // An action file with no outcome only happens when the whole batch
            // threw its hard precondition (no media service).
            return AudioImportFileResult(path: url.path,
                                         error: batchError ?? "import did not run")
        }
    }

    /// `debug.importAudio {paths: [string], trackId?, atBeat?}` — runs the SAME
    /// human-import pipeline (`AudioImportPlan` → `store.importAudioBatch`) the
    /// File→Import menu and the arrange drag-drop use, but from explicit file paths,
    /// because NSOpenPanel and OS drag can't be wire-driven (the shared execution
    /// function is the bridge). App-level, debug tier ONLY — off `allCommands`/MCP
    /// (audio import is already agent-invokable via `clip.addAudio`; this stages the
    /// exact HUMAN plan pipeline for gating with real files — the `debug.panelLayout`
    /// precedent). `trackId` targets a track (a non-audio/absent target routes to new
    /// tracks, per the plan); `atBeat` overrides the playhead landing beat (snapped
    /// by the plan). Returns `{results: [{path, clipId?, trackId?, trackName?, error?}]}`.
    private func importAudioDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let rawPaths = params["paths"]?.arrayValue, !rawPaths.isEmpty else {
            throw DebugError("debug.importAudio requires a non-empty 'paths' array of file paths")
        }
        let urls: [URL] = rawPaths.compactMap { $0.stringValue }.map {
            URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
        }
        guard urls.count == rawPaths.count else {
            throw DebugError("debug.importAudio 'paths' must all be strings")
        }
        let targetTrackID = params["trackId"]?.stringValue.flatMap { UUID(uuidString: $0) }
        let atBeat = params["atBeat"]?.doubleValue ?? store.transport.positionBeats
        let results = importAudioFiles(urls: urls, targetTrackID: targetTrackID, atBeatRaw: atBeat)
        return .object(["results": .array(results.map { result in
            var object: [String: JSONValue] = ["path": .string(result.path)]
            if let clipID = result.clipID { object["clipId"] = .string(clipID.uuidString) }
            if let trackID = result.trackID { object["trackId"] = .string(trackID.uuidString) }
            if let trackName = result.trackName { object["trackName"] = .string(trackName) }
            if let error = result.error { object["error"] = .string(error) }
            return .object(object)
        })])
    }

    /// Debug master-bus sample capture (m14-d, the C5 live gate): start/stop
    /// a tap-fed Float32 capture of the master summing bus so verification
    /// gates can analyze live seams at sample level (a chain tail crossing
    /// the loop wrap; the absence of the old 60 ms zero-run; the post-stop
    /// flush). App `debug.*` tier by the established convention — NOT in
    /// `allCommands`, no MCP tool, zero wire growth. Params:
    /// `action` "start"|"stop"; "start" also takes `path` (required, the
    /// capture file to write — .caf recommended). "stop" returns
    /// `{frames}` written (0 when nothing was armed).
    private func masterCaptureDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let action = params["action"]?.stringValue else {
            throw DebugError("debug.masterCapture requires 'action' (start|stop)")
        }
        switch action {
        case "start":
            guard let rawPath = params["path"]?.stringValue else {
                throw DebugError("debug.masterCapture start requires 'path'")
            }
            let path = (rawPath as NSString).expandingTildeInPath
            do {
                try engine.startDebugMasterCapture(toPath: path)
            } catch {
                throw DebugError("debug.masterCapture start failed: \(error.localizedDescription)")
            }
            return .object(["capturing": .bool(true), "path": .string(path)])
        case "stop":
            let frames = engine.stopDebugMasterCapture() ?? 0
            return .object(["capturing": .bool(false), "frames": .number(Double(frames))])
        default:
            throw DebugError("debug.masterCapture 'action' must be start|stop, got '\(action)'")
        }
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

    // MARK: - Sketchpad actions (M6 iii-b)

    /// Opens/closes the Sketchpad side panel (header toggle). Opening kicks a
    /// sidecar-health refresh so the banner + Generate gate are current.
    func toggleSketchpad() {
        showSketchpad.toggle()
        if showSketchpad { Task { await refreshSketchpadSidecar() } }
    }

    /// Probes the shared sidecar manager and feeds the result into the panel
    /// model (drives its banner + `canGenerate`).
    func refreshSketchpadSidecar() async {
        let status = await sidecarManager.status()
        sketchpad.updateSidecar(status)
    }

    /// Starts the local sidecar (the banner's Start button) and refreshes the
    /// panel's status from the result — falling back to a plain re-probe if the
    /// start attempt threw.
    func startSketchpadSidecar() async {
        if let started = try? await sidecarManager.start() {
            sketchpad.updateSidecar(started)
        } else {
            await refreshSketchpadSidecar()
        }
    }

    // MARK: - Sketchpad debug commands (capture support, not agent-facing)

    /// `ui.showSketchpad` — opens/closes the panel so a headless capture can
    /// drive it (the `ui.showTakes` pattern). Kicks a sidecar re-probe; the
    /// caller sleeps briefly before capturing so the async status lands (the
    /// natural ws round-trip cadence). Params: `show` (optional, default true).
    private func showSketchpadCommand(_ params: [String: JSONValue]) -> JSONValue {
        let show = params["show"]?.boolValue ?? true
        workspaceMode = .arrange
        showSketchpad = show
        if show { Task { await self.refreshSketchpadSidecar() } }
        return .object([
            "visible": .bool(show),
            "sidecar": .string(sketchpad.sidecarStatus?.state.rawValue ?? "unknown"),
        ])
    }

    /// `debug.sketchpadDemo` — seeds the panel with one candidate in each
    /// representative state (generating / succeeded / failed / imported) plus a
    /// filled composer, for a capture that can't be reached from the wire alone
    /// (the established seed-then-capture approach). Forces a healthy sidecar so
    /// the composer reads as ready.
    private func sketchpadDemo(_ params: [String: JSONValue]) -> JSONValue {
        workspaceMode = .arrange
        showSketchpad = true
        sketchpad.updateSidecar(SidecarStatus(state: .healthy, message: "running",
                                              version: "stub", ditModel: "XL-turbo"))
        sketchpad.prompt = "warm 80s synth-pop, anthemic, driving bass"
        sketchpad.lyrics = "[verse]\nCity lights below\n[chorus]\nWe rise tonight"
        // Ordered so the view's newest-first reversal puts the two states not
        // shown in the other captures — generating (shimmer + progress) and
        // failed (red) — at the TOP of the demo capture, with succeeded +
        // imported below. The generating row carries an EMPTY jobId so the
        // view's real poll timer skips it (a fake id would poll → jobNotFound →
        // a spurious "reconnecting"): the demo shows a clean generating cue.
        sketchpad.setCandidatesForCapture([
            SketchpadCandidate(jobID: "demo-4", promptSnippet: "ambient pads",
                               state: .imported(trackID: UUID(), trackName: "AI: ambient pads")),
            SketchpadCandidate(jobID: "demo-2", promptSnippet: "lofi chillhop, mellow keys",
                               state: .succeeded(audioPath: "", bpm: 92, durationSeconds: 30)),
            SketchpadCandidate(jobID: "demo-3", promptSnippet: "aggressive dnb, dark",
                               state: .failed(message: "worker ran out of memory — try a shorter length")),
            SketchpadCandidate(jobID: "", promptSnippet: "warm 80s synth-pop",
                               state: .running(progress: 0.4, statusText: "step 3/8")),
        ])
        return sketchpadStateResponse()
    }

    /// `debug.sidecarSeed {state, message?, phase?, startingForSeconds?, clear?}`
    /// — stages a synthesized `SidecarStatus` straight into the Sketchpad
    /// panel's `updateSidecar` (the `debug.vibeSeed`/`debug.copilotSeed`
    /// idiom: app-level handler, debug tier ONLY — off `allCommands`/MCP,
    /// since this is an orchestrator capture affordance, not agent-facing)
    /// so a capture / E2E can stage the M10-b `.starting` banner (spinner +
    /// phase + elapsed) without waiting through a real, multi-minute cold
    /// sidecar boot. `state` (required unless `clear`) is a `SidecarState`
    /// raw value; `message` defaults to a plausible per-state sentence when
    /// omitted; `phase`/`startingForSeconds` are additive and only applied
    /// when `state == "starting"` (matching `SidecarStatus`'s own contract —
    /// see `Sources/AIServices/SidecarStatus.swift`). `{clear: true}` drops
    /// the seed and re-probes the real sidecar instead.
    private func setSidecarSeed(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["clear"]?.boolValue == true {
            Task { await self.refreshSketchpadSidecar() }
            return .object(["cleared": .bool(true)])
        }
        guard let stateRaw = params["state"]?.stringValue, let state = SidecarState(rawValue: stateRaw) else {
            throw DebugError(
                "debug.sidecarSeed requires a state (notInstalled|installedNotRunning|starting|healthy|error)")
        }
        let phase = state == .starting ? params["phase"]?.stringValue : nil
        let startingForSeconds = state == .starting
            ? params["startingForSeconds"]?.doubleValue.map { Int($0) } : nil
        let message = params["message"]?.stringValue
            ?? Self.defaultSidecarSeedMessage(state: state, phase: phase, startingForSeconds: startingForSeconds)
        sketchpad.updateSidecar(SidecarStatus(
            state: state, message: message, phase: phase, startingForSeconds: startingForSeconds))

        var response: [String: JSONValue] = ["state": .string(state.rawValue), "message": .string(message)]
        if let phase { response["phase"] = .string(phase) }
        if let startingForSeconds { response["startingForSeconds"] = .number(Double(startingForSeconds)) }
        return .object(response)
    }

    private static func defaultSidecarSeedMessage(
        state: SidecarState, phase: String?, startingForSeconds: Int?
    ) -> String {
        switch state {
        case .notInstalled:
            return "ACE-Step sidecar is not installed — run scripts/ace-step/install.sh first."
        case .installedNotRunning:
            return "ACE-Step is installed but not running — call ai.sidecarStart."
        case .starting:
            guard let startingForSeconds else { return "ACE-Step sidecar is starting." }
            if let phase {
                return "ACE-Step sidecar is starting — \(phase) (\(startingForSeconds)s so far)."
            }
            return "ACE-Step sidecar is starting (\(startingForSeconds)s so far)."
        case .healthy:
            return "ACE-Step sidecar is running and healthy."
        case .error:
            return "ACE-Step sidecar responded, but its /health response could not be parsed."
        }
    }

    /// `debug.sketchpadGenerate {prompt, lyrics?, durationSeconds?}` — sets the
    /// composer inputs and runs the REAL `model.generate()` against the app's
    /// (stub) sidecar, blocking until the submission returns. Params: `prompt`
    /// (required).
    private func sketchpadGenerate(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let prompt = params["prompt"]?.stringValue, !prompt.isEmpty else {
            throw DebugError("debug.sketchpadGenerate requires a non-empty prompt")
        }
        workspaceMode = .arrange
        showSketchpad = true
        sketchpad.prompt = prompt
        if let lyrics = params["lyrics"]?.stringValue { sketchpad.lyrics = lyrics }
        if let duration = params["durationSeconds"]?.doubleValue { sketchpad.setDurationSeconds(duration) }
        // Fire-and-forget: the submission completes on the main actor during the
        // caller's next sleep/round-trip. The caller polls `debug.sketchpadState`
        // for the candidate to appear and progress (the view's real path too).
        Task {
            await self.refreshSketchpadSidecar()
            await self.sketchpad.generate()
        }
        return sketchpadStateResponse()
    }

    /// `debug.sketchpadRefresh` — kicks ONE real poll cycle (the model's own
    /// `refresh`), so a capture flow can advance queued → running → succeeded
    /// deterministically without waiting on the view's timer. Poll
    /// `debug.sketchpadState` after a short sleep to read the transition.
    private func sketchpadRefresh(_ params: [String: JSONValue]) -> JSONValue {
        Task { await self.sketchpad.refresh() }
        return sketchpadStateResponse()
    }

    /// `debug.sketchpadImport {candidateId?}` — imports a succeeded candidate
    /// (the given one, or the first succeeded) through the real store pipeline.
    private func sketchpadImport(_ params: [String: JSONValue]) throws -> JSONValue {
        let targetID: UUID?
        if let raw = params["candidateId"]?.stringValue {
            guard let id = UUID(uuidString: raw) else {
                throw DebugError("candidateId is not a valid UUID: \(raw)")
            }
            targetID = id
        } else {
            targetID = sketchpad.candidates.first {
                if case .succeeded = $0.state { return true }; return false
            }?.id
        }
        guard let id = targetID else {
            throw DebugError("no succeeded candidate to import")
        }
        Task { await self.sketchpad.importCandidate(id) }
        return sketchpadStateResponse()
    }

    // MARK: - Generation-presence card (m17-h)

    /// `debug.generationCard {seed?, clear?}` — stages/reads the unified
    /// generation-progress card for captures/E2E (app tier, debug tier ONLY —
    /// off `allCommands`/MCP, the `debug.arrangeZoom`/`debug.effectEditor`
    /// precedent: the card is status chrome; agents drive the `ai.*` protocol,
    /// not the chrome). A bare call is READ-ONLY and echoes the registry (the
    /// m11-a law) — gate scripts poll it to assert the card tracks sidecar
    /// truth. `clear:true` drops every row FIRST (so `{clear:true, seed:{…}}`
    /// resets then stages). `seed` appends ONE staged row:
    /// `{phase (required: startingSidecar|sidecarReady|queued|running|
    /// succeeded|failed), origin? ("sketchpad"|"wire"|"import", default
    /// "wire"), label?, jobId? (OMIT to keep the live poll off the staged row —
    /// the `debug.sketchpadDemo` empty-jobID rule), progress? (0…1), stage?,
    /// detail? (the boot phase hint), reason? (the failed row's verbatim
    /// text), elapsedSeconds? (backdates startedAt so the elapsed readout
    /// shows it), stale?}`. Returns the resulting registry.
    private func generationCardDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["clear"]?.boolValue == true {
            generationPresence.clearForCapture()
        }
        if let seed = params["seed"]?.objectValue {
            guard let phaseRaw = seed["phase"]?.stringValue else {
                throw DebugError("debug.generationCard seed requires a phase")
            }
            let phase: GenerationPresencePhase
            switch phaseRaw {
            case "startingSidecar":
                phase = .startingSidecar(detail: seed["detail"]?.stringValue)
            case "sidecarReady":
                phase = .sidecarReady
            case "queued":
                phase = .queued
            case "running":
                phase = .running(progress: seed["progress"]?.doubleValue,
                                 stageText: seed["stage"]?.stringValue)
            case "succeeded":
                phase = .succeeded
            case "failed":
                phase = .failed(reason: seed["reason"]?.stringValue ?? "Generation failed (staged)")
            default:
                throw DebugError("unknown phase \"\(phaseRaw)\" — expected startingSidecar|"
                    + "sidecarReady|queued|running|succeeded|failed")
            }
            let originRaw = seed["origin"]?.stringValue ?? GenerationJobOrigin.wire.rawValue
            guard let origin = GenerationJobOrigin(rawValue: originRaw) else {
                throw DebugError("unknown origin \"\(originRaw)\" — expected sketchpad|wire|import")
            }
            let elapsed = seed["elapsedSeconds"]?.doubleValue ?? 0
            var job = GenerationPresenceJob(
                jobID: seed["jobId"]?.stringValue,
                origin: origin,
                label: seed["label"]?.stringValue ?? "staged generation",
                phase: phase,
                startedAt: Date().addingTimeInterval(-elapsed),
                isStale: seed["stale"]?.boolValue ?? false)
            if !phase.isActive { job.finishedAt = Date() }
            generationPresence.seedJobForCapture(job)
        }
        return generationCardState()
    }

    /// The registry echo `debug.generationCard` returns — also what the gate
    /// scripts diff against sidecar truth.
    private func generationCardState() -> JSONValue {
        .object([
            "visible": .bool(generationPresence.isVisible),
            "jobs": .array(generationPresence.jobs.map { job in
                var fields: [String: JSONValue] = [
                    "id": .string(job.id.uuidString),
                    "origin": .string(job.origin.rawValue),
                    "label": .string(job.label),
                    "phase": .string(job.phase.rawTag),
                    "stageLabel": .string(GenerationPresenceModel.stageLabel(for: job.phase)),
                    "elapsed": .string(generationPresence.elapsedText(for: job)),
                    "stale": .bool(job.isStale),
                ]
                if let jobID = job.jobID { fields["jobId"] = .string(jobID) }
                if case .running(let progress?, _) = job.phase {
                    fields["progress"] = .number(progress)
                }
                if case .running(_, let stage?) = job.phase {
                    fields["stage"] = .string(stage)
                }
                if case .failed(let reason) = job.phase {
                    fields["reason"] = .string(reason)
                }
                return .object(fields)
            }),
        ])
    }

    // MARK: - Clip fix (M6 v-b-2)

    /// Opens/closes the FIX-WITH-AI panel (the clip-selection affordance).
    func toggleClipFix() {
        showClipFix.toggle()
    }

    /// `ui.showClipFix {show?}` — opens/closes the clip vocal-fix panel so a
    /// headless capture can drive it (the `ui.showSketchpad` pattern). Off
    /// `allCommands`/MCP. Returns the panel state.
    private func showClipFixCommand(_ params: [String: JSONValue]) -> JSONValue {
        let show = params["show"]?.boolValue ?? true
        workspaceMode = .arrange
        showClipFix = show
        return clipFixStateResponse()
    }

    /// `debug.clipFixSeed {mode}` — stages the fix panel for a capture that can't
    /// be reached from the wire alone (no real audio clip / sidecar on the capture
    /// machine — the `debug.sketchpadDemo` precedent). Always fills the composer
    /// (a target clip + region + prompt/lyrics); the jobs strip varies by `mode`:
    ///   - `composer`: an empty jobs strip (the filled-composer shot).
    ///   - `jobs` (default): a running (shimmer + 40 %) + a succeeded (IMPORT) + a
    ///     failed card — the state-variety shot.
    ///   - `imported`: a single imported card with its lane name.
    /// The running card carries an EMPTY jobId so the panel's real poll timer
    /// skips it (a fake id would poll → jobNotFound → a spurious RECONNECTING),
    /// mirroring `debug.sketchpadDemo`.
    private func clipFixSeed(_ params: [String: JSONValue]) -> JSONValue {
        let mode = params["mode"]?.stringValue ?? "jobs"
        workspaceMode = .arrange
        showClipFix = true

        let trackID = UUID()
        func seedComposer() {
            clipFix.setComposerForCapture(
                trackID: trackID, clipID: UUID(), name: "Lead Vocal",
                startBeat: 33, endBeat: 41,
                prompt: "clean up the pitch on the chorus line",
                lyrics: "[chorus]\nwe rise tonight", mode: .balanced)
        }

        // Ordered so the view's newest-first reversal puts running at the TOP.
        let running = ClipFixCard(jobID: "", trackID: trackID,
                                  regionStartBeat: 33, regionEndBeat: 41,
                                  promptSnippet: "clean the chorus",
                                  state: .running(progress: 0.4, statusText: "step 3/8"))
        let succeeded = ClipFixCard(jobID: "fix-ok", trackID: trackID,
                                    regionStartBeat: 16, regionEndBeat: 20,
                                    promptSnippet: "fix the pitch",
                                    state: .succeededAwaitingImport)
        let failed = ClipFixCard(jobID: "fix-fail", trackID: trackID,
                                 regionStartBeat: 24, regionEndBeat: 28,
                                 promptSnippet: "de-ess the sibilance",
                                 state: .failed(message: "worker ran out of memory — try a shorter region"))
        let imported = ClipFixCard(jobID: "fix-imp", trackID: trackID,
                                   regionStartBeat: 8, regionEndBeat: 12,
                                   promptSnippet: "warm the low notes",
                                   state: .imported(laneName: "AI Fix 1"))
        switch mode {
        case "composer":
            seedComposer()
            clipFix.setCardsForCapture([])
        case "imported":
            seedComposer()
            clipFix.setCardsForCapture([imported])
        default:   // "jobs": collapse the composer so all three cards fit in view
            clipFix.clearTarget()
            clipFix.setCardsForCapture([failed, succeeded, running])
        }
        return clipFixStateResponse()
    }

    /// `debug.clipFixState` — read-only snapshot of the panel (visibility +
    /// composer target + the cards and their state tags), so a capture flow can
    /// poll for the state it wants.
    private func clipFixStateResponse() -> JSONValue {
        .object([
            "visible": .bool(showClipFix),
            "targetClipId": clipFix.targetClipID.map { JSONValue.string($0.uuidString) } ?? .null,
            "regionStartBeat": .number(clipFix.regionStartBeat),
            "regionEndBeat": .number(clipFix.regionEndBeat),
            "cards": .array(clipFix.cards.map(Self.clipFixCardSummary)),
        ])
    }

    /// A compact JSON summary of one fix card for the debug commands.
    private static func clipFixCardSummary(_ c: ClipFixCard) -> JSONValue {
        var obj: [String: JSONValue] = [
            "jobId": .string(c.jobID),
            "regionStartBeat": .number(c.regionStartBeat),
            "regionEndBeat": .number(c.regionEndBeat),
            "stale": .bool(c.isStale),
        ]
        switch c.state {
        case .pending:
            obj["state"] = .string("pending")
        case .running(let progress, let statusText):
            obj["state"] = .string("running")
            if let progress { obj["progress"] = .number(progress) }
            if let statusText { obj["statusText"] = .string(statusText) }
        case .succeededAwaitingImport:
            obj["state"] = .string("succeededAwaitingImport")
        case .imported(let laneName):
            obj["state"] = .string("imported")
            obj["laneName"] = .string(laneName)
        case .failed(let message):
            obj["state"] = .string("failed")
            obj["message"] = .string(message)
        case .stale(let message):
            obj["state"] = .string("stale")
            obj["message"] = .string(message)
        }
        return .object(obj)
    }

    // MARK: - Instrument picker (m10-n-3)

    /// Opens the instrument picker for a track: seeds the model with its current
    /// instrument (highlight + chip name) + status, and syncs the picker's density
    /// from the shared store. Called by the track-header / mixer instrument chips.
    func openInstrumentPicker(trackID: UUID) {
        let track = store.tracks.first { $0.id == trackID }
        instrumentPicker.prepare(trackID: trackID, descriptor: track?.instrument,
                                 status: store.audioUnitStatus(forTrack: trackID))
        instrumentPicker.density = panelDensity.density(forPanel: InstrumentPickerOverlay.panelID)
        instrumentPickerTrackID = trackID
    }

    /// Closes the instrument picker.
    func closeInstrumentPicker() {
        instrumentPickerTrackID = nil
    }

    /// Applies a picker `InstrumentChoice` to the open track through the SAME store
    /// method the wire uses (`setInstrument`), then re-reads the descriptor + status
    /// so the picker highlight and the chip update live. The picker STAYS OPEN so
    /// the user can compare instruments (the design's audition rule); a failed
    /// selection surfaces through the chip's status, never a silent swap.
    func applyInstrumentChoice(_ choice: InstrumentChoice) {
        guard let trackID = instrumentPickerTrackID else { return }
        switch choice {
        case .builtIn(let kind):
            _ = try? store.setInstrument(id: trackID, kind: kind)
        case .soundBank(let config):
            _ = try? store.setInstrument(id: trackID, soundBank: config)
        case .audioUnit(let config):
            _ = try? store.setInstrument(id: trackID, audioUnit: config)
        }
        let descriptor = store.tracks.first { $0.id == trackID }?.instrument
        instrumentPicker.updateCurrent(descriptor: descriptor,
                                       status: store.audioUnitStatus(forTrack: trackID))
    }

    // MARK: - AU-effect picker (m13-g, audit F6)

    /// Opens the AU-effect picker for a track/bus (the Pro inserts "Audio Units…"
    /// item), reloading the installed-AU list. Never called for master (the item is
    /// hidden there — built-ins only, v1).
    func openEffectPicker(trackID: UUID) {
        effectPicker.prepare(trackID: trackID)
        effectPickerTrackID = trackID
    }

    /// Closes the AU-effect picker.
    func closeEffectPicker() {
        effectPickerTrackID = nil
    }

    /// Applies a chosen AU effect to the open track through the SAME store call the
    /// wire's `fx.add kind:"audioUnit"` makes (`addEffect(kind:.audioUnit)`), then
    /// closes — a single decisive add. The current track name for the picker header
    /// comes from the store.
    func applyEffectChoice(_ config: AudioUnitConfig) {
        guard let trackID = effectPickerTrackID else { return }
        _ = try? store.addEffect(toTrack: trackID, kind: .audioUnit, audioUnit: config)
        closeEffectPicker()
    }

    /// The open picker's target track name (for the modal header). Empty when closed.
    var effectPickerTrackName: String {
        guard let id = effectPickerTrackID else { return "" }
        return store.tracks.first { $0.id == id }?.name ?? ""
    }

    /// `debug.effectPicker {trackId?, open?, search?, close?}` — stages the AU-effect
    /// picker for a capture the wire alone can't reach (the picker is UI chrome, off
    /// `allCommands`/MCP — the `debug.instrumentPicker` precedent). Opens the picker
    /// on a track (the given one, else the first audio/instrument track); `search`
    /// presets the filter; `close:true` dismisses it. Switches to the Mix workspace
    /// so a capture frames the console behind the modal. Echoes the picker state.
    private func effectPickerDebug(_ params: [String: JSONValue]) -> JSONValue {
        if params["close"]?.boolValue == true {
            closeEffectPicker()
            return effectPickerStateResponse()
        }
        let trackID: UUID
        if let raw = params["trackId"]?.stringValue, let id = UUID(uuidString: raw),
           store.tracks.contains(where: { $0.id == id }) {
            trackID = id
        } else if let track = store.tracks.first(where: { $0.kind != .bus }) {
            trackID = track.id
        } else {
            trackID = store.addTrack(kind: .audio).id
        }
        workspaceMode = .mix
        panelDensity.setDensity(.pro, forPanel: MixerView.panelID)
        openEffectPicker(trackID: trackID)
        if let search = params["search"]?.stringValue { effectPicker.searchText = search }
        return effectPickerStateResponse()
    }

    private func effectPickerStateResponse() -> JSONValue {
        .object([
            "visible": .bool(effectPickerTrackID != nil),
            "trackId": effectPickerTrackID.map { JSONValue.string($0.uuidString) } ?? .null,
            "count": .number(Double(effectPicker.filteredAudioUnits.count)),
            "search": .string(effectPicker.searchText),
        ])
    }

    // MARK: - Built-in insert effect editor (m17-a)

    /// Opens the effect editor card on one BUILT-IN insert (`trackID` nil = the
    /// MASTER chain — built-ins only, so the card is the master chain's ONLY
    /// in-app param surface). ONE editor app-wide: opening another insert's
    /// editor replaces the current one. A hosted AU never opens the generic
    /// card (v1 — AUs keep their plugin window, M3 vi-b).
    func openEffectEditor(trackID: UUID?, effectID: UUID) {
        let descriptor: EffectDescriptor?
        if let trackID {
            descriptor = store.tracks.first { $0.id == trackID }?
                .effects.first { $0.id == effectID }
        } else {
            descriptor = store.masterEffects.first { $0.id == effectID }
        }
        guard let descriptor, descriptor.kind != .audioUnit else { return }
        let label = trackID
            .flatMap { id in store.tracks.first { $0.id == id }?.name }
            .map { "on \($0)" } ?? "on Master"
        effectEditor.prepare(trackID: trackID, effectID: effectID, targetLabel: label)
        effectEditorTarget = EffectEditorTarget(trackID: trackID, effectID: effectID)
    }

    /// The `InsertRow` click: toggles the editor on that insert (clicking the
    /// open row closes it; clicking another replaces — one editor app-wide).
    func toggleEffectEditor(trackID: UUID?, effectID: UUID) {
        if effectEditorTarget == EffectEditorTarget(trackID: trackID, effectID: effectID) {
            closeEffectEditor()
        } else {
            openEffectEditor(trackID: trackID, effectID: effectID)
        }
    }

    /// Closes the effect editor (scrim click, ✕, or replacing modal flows).
    func closeEffectEditor() {
        effectEditorTarget = nil
        effectEditor.clear()
    }

    /// The UI insert add funnel (m17-a): adds a built-in effect through the
    /// SAME store methods the wire's `fx.add` calls, then AUTO-OPENS its editor
    /// card (the Logic add-then-open habit, scoped to an in-window card). Only
    /// the strip's "+" menu and `debug.effectEditor {add}` come through here —
    /// the wire's `fx.add` does NOT (an agent must never pop UI).
    func addBuiltInInsert(trackID: UUID?, kind: EffectDescriptor.Kind) {
        let added: EffectDescriptor?
        if let trackID {
            added = try? store.addEffect(toTrack: trackID, kind: kind)
        } else {
            added = try? store.addMasterEffect(kind: kind)
        }
        guard let added else { return }
        openEffectEditor(trackID: trackID, effectID: added.id)
    }

    /// `debug.effectEditor {trackId?, effectId?, open?, add?, param?, value?,
    /// close?}` — stages the built-in effect editor for captures/E2E (app-level,
    /// debug tier — off `allCommands`/MCP, the `debug.effectPicker` precedent).
    /// `trackId` takes a track UUID or `"master"` (the fx.* sentinel; omitted =
    /// the first chain carrying a built-in insert). `open:true` opens the card
    /// (switching to the Mix workspace + Pro density so a capture frames it);
    /// `add:"eq"` drives the EXACT UI add funnel (`addBuiltInInsert` — store add
    /// + auto-open, what the strip's "+" menu runs); `param`+`value` drive the
    /// OPEN card's apply path (`EffectEditorModel.set` → the same store call a
    /// slider tick makes — the G2 UI-vs-wire seam); `close:true` dismisses. A
    /// bare call is READ-ONLY (echoes state, never re-opens — the m11-a law).
    private func effectEditorDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["close"]?.boolValue == true {
            closeEffectEditor()
            return effectEditorStateResponse()
        }

        // Resolve the target chain: "master" → nil trackID; a UUID must exist.
        var chainTrackID: UUID?
        var chainGiven = false
        if let raw = params["trackId"]?.stringValue {
            chainGiven = true
            if raw == "master" {
                chainTrackID = nil
            } else if let id = UUID(uuidString: raw),
                      store.tracks.contains(where: { $0.id == id }) {
                chainTrackID = id
            } else {
                throw DebugError("trackId is not 'master' or a known track UUID: \(raw)")
            }
        }

        if let rawKind = params["add"]?.stringValue {
            guard let kind = EffectDescriptor.Kind(rawValue: rawKind), kind != .audioUnit else {
                throw DebugError("add must name a built-in effect kind, got: \(rawKind)")
            }
            if !chainGiven {
                chainTrackID = store.tracks.first { $0.kind != .bus }?.id
            }
            workspaceMode = .mix
            panelDensity.setDensity(.pro, forPanel: MixerView.panelID)
            // THE UI funnel — store add + auto-open, verbatim what the "+" menu runs.
            addBuiltInInsert(trackID: chainTrackID, kind: kind)
            return effectEditorStateResponse()
        }

        if params["open"]?.boolValue == true {
            if !chainGiven {
                // Default: the first chain (tracks first, then master) with a built-in.
                if let t = store.tracks.first(where: { t in
                    t.effects.contains { $0.kind != .audioUnit }
                }) {
                    chainTrackID = t.id
                } else if store.masterEffects.contains(where: { $0.kind != .audioUnit }) {
                    chainTrackID = nil
                } else {
                    throw DebugError("no built-in insert exists to open an editor on")
                }
            }
            let effects = chainTrackID
                .map { id in store.tracks.first { $0.id == id }?.effects ?? [] }
                ?? store.masterEffects
            let effectID: UUID
            if let raw = params["effectId"]?.stringValue {
                guard let id = UUID(uuidString: raw),
                      effects.contains(where: { $0.id == id && $0.kind != .audioUnit }) else {
                    throw DebugError("effectId is not a built-in insert on the target chain: \(raw)")
                }
                effectID = id
            } else if let first = effects.first(where: { $0.kind != .audioUnit }) {
                effectID = first.id
            } else {
                throw DebugError("no built-in insert on the target chain")
            }
            workspaceMode = .mix
            panelDensity.setDensity(.pro, forPanel: MixerView.panelID)
            openEffectEditor(trackID: chainTrackID, effectID: effectID)
        }

        // param + value drive the OPEN card's apply path — the exact model call
        // a slider tick makes (clamp → injected apply → setEffectParam twin).
        if let name = params["param"]?.stringValue {
            guard effectEditorTarget != nil else {
                throw DebugError("no effect editor is open — pass open:true first")
            }
            guard let value = params["value"]?.doubleValue else {
                throw DebugError("param requires a numeric value")
            }
            effectEditor.set(name: name, value: value)
            if let error = effectEditor.lastErrorMessage {
                throw DebugError(error)
            }
        }
        return effectEditorStateResponse()
    }

    private func effectEditorStateResponse() -> JSONValue {
        let values: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: effectEditor.specs.map {
                ($0.name, JSONValue.number(effectEditor.value(for: $0)))
            })
        return .object([
            "visible": .bool(effectEditorTarget != nil && effectEditor.descriptor != nil),
            "trackId": effectEditorTarget.map {
                $0.trackID.map { JSONValue.string($0.uuidString) } ?? .string("master")
            } ?? .null,
            "effectId": effectEditorTarget.map { JSONValue.string($0.effectID.uuidString) } ?? .null,
            "kind": effectEditor.kind.map { JSONValue.string($0.rawValue) } ?? .null,
            "bypassed": .bool(effectEditor.isBypassed),
            "values": .object(values),
        ])
    }

    /// Imports a SoundFont/DLS via NSOpenPanel (not headless — the app view drives
    /// it), then refreshes the picker's bank list. Errors surface inline in the
    /// Sound Banks section (`model.importError`). A cancelled panel is a no-op.
    func importSoundBankViaPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes =
            [UTType(filenameExtension: "sf2"), UTType(filenameExtension: "dls")].compactMap { $0 }
        panel.prompt = "Add"
        panel.message = "Choose a SoundFont (.sf2) or DLS bank file to add to your library."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        instrumentPicker.importBank(from: url)
    }

    /// `debug.instrumentPicker {trackId?, mode?, search?, bank?}` — stages the
    /// picker for a capture that the wire alone can't reach (the picker is UI
    /// chrome, off `allCommands`/MCP — the `debug.clipFixSeed` precedent). Opens
    /// the picker on an instrument track (the given one, else the first, else a
    /// freshly-added one); `mode` sets Simple/Pro density; `search` presets the
    /// filter; `bank:"gm"` drills straight into the GM program browser. Returns the
    /// resulting picker state so a capture flow can poll for what it wants.
    private func instrumentPickerDebug(_ params: [String: JSONValue]) -> JSONValue {
        // `close:true` dismisses the picker so a capture can frame the track-header
        // / mixer chip underneath after a selection lands.
        if params["close"]?.boolValue == true {
            closeInstrumentPicker()
            return instrumentPickerStateResponse()
        }
        // Resolve a target instrument track.
        let trackID: UUID
        if let raw = params["trackId"]?.stringValue, let id = UUID(uuidString: raw) {
            trackID = id
        } else if let inst = store.tracks.first(where: { $0.kind == .instrument }) {
            trackID = inst.id
        } else {
            trackID = store.addTrack(kind: .instrument).id
        }
        workspaceMode = .arrange
        if let modeRaw = params["mode"]?.stringValue, let density = PanelDensity(rawValue: modeRaw) {
            panelDensity.setDensity(density, forPanel: InstrumentPickerOverlay.panelID)
        }
        openInstrumentPicker(trackID: trackID)
        if let bank = params["bank"]?.stringValue, bank == "gm" {
            if let gm = instrumentPicker.banks.first(where: { $0.source == .generalMIDI }) {
                instrumentPicker.drillInto(gm)
            }
        }
        if let search = params["search"]?.stringValue {
            instrumentPicker.searchText = search
        }
        return instrumentPickerStateResponse()
    }

    // MARK: - Quantize & groove panel (m11-a)

    /// Opens the Quantize panel for a clip: seeds the model with the clip's name +
    /// kind (MIDI → note-quantize controls; audio → extract-only) and syncs the
    /// panel density from the shared store. Called by the piano-roll header chip and
    /// the arrange clip context menu. `startExtract` reveals the extract field
    /// straight away (the "Extract Groove…" menu entry's entry point).
    func openQuantizePanel(clipID: UUID, startExtract: Bool = false) {
        guard let clip = store.tracks.flatMap(\.clips).first(where: { $0.id == clipID }) else { return }
        quantizeModel.prepare(clipID: clipID, clipName: clip.name, isMIDI: clip.isMIDI)
        quantizeModel.density = panelDensity.density(forPanel: QuantizePanel.panelID)
        if startExtract { quantizeModel.beginExtract() }
        quantizePanelClipID = clipID
    }

    /// Closes the Quantize panel.
    func closeQuantizePanel() {
        quantizePanelClipID = nil
    }

    /// Applies the model's built settings to the clip through the SAME store method
    /// the wire uses (`quantizeClipNotes`, ONE undo step), then closes the panel — a
    /// single decisive action (re-quantizing partial-strength notes compounds, so
    /// the panel doesn't linger inviting an accidental re-apply).
    func applyQuantize() {
        quantizeModel.apply()
        closeQuantizePanel()
    }

    /// Removes a saved groove template through the store (`removeGrooveTemplate`,
    /// one undo step; the wire's `groove.remove` method). Built-ins aren't stored,
    /// so they're never passed here.
    func removeGroove(id: UUID) {
        _ = try? store.removeGrooveTemplate(id: id)
    }

    /// `debug.quantizePanel {clipId?, open?, mode?, grid?, strength?, swing?,
    /// quantizeEnds?, groove?, extract?, extractName?, apply?, close?}` — stages the
    /// panel for a capture/E2E the wire alone can't reach (the panel is UI chrome,
    /// off `allCommands`/MCP — the `debug.instrumentPicker` precedent). Opens the
    /// panel on a clip (the given one, else the first MIDI clip), sets density +
    /// each setting, optionally selects a groove (resolved via `store.resolveGroove`,
    /// which auto-forces Pro so the groove is honoured), optionally triggers the UI
    /// extract or apply path, and echoes the resulting panel state to poll.
    private func quantizePanelDebug(_ params: [String: JSONValue]) -> JSONValue {
        if params["close"]?.boolValue == true {
            closeQuantizePanel()
            return quantizePanelStateResponse()
        }
        // Resolve a target clip: the given id, else the first MIDI clip, else the
        // first clip of any kind (extract works on audio too).
        let clip: Clip?
        if let raw = params["clipId"]?.stringValue, let id = UUID(uuidString: raw) {
            clip = store.tracks.flatMap(\.clips).first { $0.id == id }
        } else if let midi = store.tracks.flatMap(\.clips).first(where: { $0.isMIDI }) {
            clip = midi
        } else {
            clip = store.tracks.flatMap(\.clips).first
        }
        guard let clip else { return quantizePanelStateResponse() }
        workspaceMode = .arrange
        if let modeRaw = params["mode"]?.stringValue, let density = PanelDensity(rawValue: modeRaw) {
            panelDensity.setDensity(density, forPanel: QuantizePanel.panelID)
        }
        openQuantizePanel(clipID: clip.id)
        // Settings staging.
        if let gridRaw = params["grid"]?.stringValue,
           let index = QuantizeModel.grids.firstIndex(where: { $0.label == gridRaw }) {
            quantizeModel.gridIndex = index
        } else if let gridBeats = params["gridBeats"]?.doubleValue,
                  let index = QuantizeModel.grids.firstIndex(where: { abs($0.beats - gridBeats) < 1e-6 }) {
            quantizeModel.gridIndex = index
        }
        if let strength = params["strength"]?.doubleValue {
            quantizeModel.strength = strength.clamped(to: 0...1)
        }
        if let swing = params["swing"]?.doubleValue {
            quantizeModel.swingPercent = swing.clamped(to: 50...75)
        }
        if let ends = params["quantizeEnds"]?.boolValue { quantizeModel.quantizeEnds = ends }
        // A groove ref forces Pro (Simple builds no groove — the density gate) then
        // selects the resolved template BY VALUE, matching the wire's resolution.
        if let ref = params["groove"]?.stringValue {
            panelDensity.setDensity(.pro, forPanel: QuantizePanel.panelID)
            quantizeModel.density = .pro
            quantizeModel.selectGroove(store.resolveGroove(ref))
        }
        // Reveal the extract composer WITHOUT firing (for a capture of the field).
        if params["expandExtract"]?.boolValue == true {
            if let name = params["extractName"]?.stringValue { quantizeModel.extractName = name }
            quantizeModel.beginExtract()
            if let name = params["extractName"]?.stringValue { quantizeModel.extractName = name }
        }
        // Extract via the UI path (async on the main actor; MIDI completes on the
        // next turn, so a follow-up `groove.list` sees it — the capture flow polls).
        if params["extract"]?.boolValue == true {
            if let name = params["extractName"]?.stringValue { quantizeModel.extractName = name }
            quantizeModel.beginExtract()
            if let name = params["extractName"]?.stringValue { quantizeModel.extractName = name }
            Task { @MainActor in await self.quantizeModel.extract() }
        }
        // Apply via the UI path (sync; `quantizeClipNotes` = one undo step). Leaves
        // the panel OPEN under debug so a capture can still frame the applied state.
        if params["apply"]?.boolValue == true {
            quantizeModel.apply()
        }
        return quantizePanelStateResponse()
    }

    /// Read-only snapshot of the Quantize panel so a capture flow can poll.
    private func quantizePanelStateResponse() -> JSONValue {
        .object([
            "visible": .bool(quantizePanelClipID != nil),
            "clipId": quantizePanelClipID.map { JSONValue.string($0.uuidString) } ?? .null,
            "isMIDI": .bool(quantizeModel.targetIsMIDI),
            "mode": .string(panelDensity.density(forPanel: QuantizePanel.panelID).rawValue),
            "grid": .string(quantizeModel.effectiveGridLabel),
            "strength": .number(quantizeModel.strength),
            "swing": .number(quantizeModel.swingPercent),
            "quantizeEnds": .bool(quantizeModel.quantizeEnds),
            "groove": quantizeModel.selectedGroove.map { JSONValue.string($0.name) } ?? .null,
            "grooveLocked": .bool(quantizeModel.gridIsGrooveLocked),
            "savedGrooveCount": .number(Double(quantizeModel.savedGrooves.count)),
            "extractExpanded": .bool(quantizeModel.isExtractExpanded),
        ])
    }

    // MARK: - Tempo lane (m12-d)

    /// `debug.tempoLane {mode?, selectSegment?, dragBoundaryIndex?+dragBoundaryToBeat?,
    /// dragBpmIndex?+dragBpmToBpm?, addSegmentAt?(+addSegmentBpm?), removeSegment?,
    /// setMeterBeat?(+setMeterBeatsPerBar?/setMeterBeatUnit?), removeMeterAt?}` — drives
    /// the arrange tempo lane headlessly for captures + gates (the `debug.quantizePanel`
    /// precedent; app-tier ONLY, off `allCommands`/MCP). Every edit routes through the
    /// SAME `tempoLaneModel` the live ruler renders, whose closures apply through
    /// `ProjectStore.setTempoMap` — so the UI mutation and the `tempo.map` wire state
    /// agree by construction and a drag coalesces to ONE undo. A BARE call is READ-ONLY
    /// (echoes state). `mode` sets the arrange density (Simple = read-only lane; Pro =
    /// editable). Returns the lane state to poll.
    private func tempoLaneDebug(_ params: [String: JSONValue]) -> JSONValue {
        workspaceMode = .arrange
        if let modeRaw = params["mode"]?.stringValue, let density = PanelDensity(rawValue: modeRaw) {
            panelDensity.setDensity(density, forPanel: TimelineLanesView.panelID)
        }
        let model = tempoLaneModel
        let snap = ClipSnap.effective(
            density: panelDensity.density(forPanel: TimelineLanesView.panelID), picked: clipSnap)

        if params["deselect"]?.boolValue == true {
            model.selectSegment(nil)
        } else if let i = params["selectSegment"]?.doubleValue {
            model.selectSegment(Int(i))
        }
        if let beat = params["dragBoundaryToBeat"]?.doubleValue,
           let idx = params["dragBoundaryIndex"]?.doubleValue {
            model.dragBoundary(index: Int(idx), toBeat: beat, snap: snap)
        }
        if let bpm = params["dragBpmToBpm"]?.doubleValue,
           let idx = params["dragBpmIndex"]?.doubleValue {
            model.scrubBPM(index: Int(idx), toBPM: bpm)
        }
        if let beat = params["addSegmentAt"]?.doubleValue {
            model.addSegment(atBeat: beat, snap: snap, bpm: params["addSegmentBpm"]?.doubleValue)
        }
        if let idx = params["removeSegment"]?.doubleValue {
            model.removeSegment(index: Int(idx))
        }
        if let beat = params["setMeterBeat"]?.doubleValue {
            model.setMeter(
                atBeat: beat,
                beatsPerBar: Int(params["setMeterBeatsPerBar"]?.doubleValue ?? 4),
                beatUnit: Int(params["setMeterBeatUnit"]?.doubleValue ?? 4))
        }
        if let beat = params["removeMeterAt"]?.doubleValue {
            model.removeMeter(atBeat: beat)
        }
        return tempoLaneStateResponse()
    }

    /// Read-only snapshot of the tempo lane so a capture/gate flow can poll — the
    /// RESOLVED maps (what the wire `tempo.map` reports), the selection, the
    /// `mapRevision`, and the count of audio clips currently carrying the amber
    /// tempo-boundary hint (§3.5) so a gate can assert the hint flips.
    private func tempoLaneStateResponse() -> JSONValue {
        let model = tempoLaneModel
        let tempo = model.tempoMap
        let meter = model.meterMap
        let amberClipCount = store.tracks.flatMap(\.clips).filter {
            TempoLaneHint.audioClipCrossesBoundary(
                startBeat: $0.startBeat, lengthBeats: $0.lengthBeats,
                isMIDI: $0.isMIDI, tempoMap: tempo)
        }.count
        return .object([
            "mode": .string(panelDensity.density(forPanel: TimelineLanesView.panelID).rawValue),
            "isTrivial": .bool(model.isTrivial),
            "selectedSegment": model.selectedSegmentIndex.map { JSONValue.number(Double($0)) } ?? .null,
            "segments": .array(tempo.segments.map {
                .object(["startBeat": .number($0.startBeat), "bpm": .number($0.bpm)])
            }),
            "meterChanges": .array(meter.changes.map {
                .object(["startBeat": .number($0.startBeat),
                         "beatsPerBar": .number(Double($0.beatsPerBar)),
                         "beatUnit": .number(Double($0.beatUnit))])
            }),
            "mapRevision": .number(Double(store.mapRevision)),
            "amberClipCount": .number(Double(amberClipCount)),
            "lastError": model.lastErrorMessage.map { JSONValue.string($0) } ?? .null,
        ])
    }

    // MARK: - Undo-history panel (m11-b)

    /// Opens the Undo-history panel (the arrange-toolbar HISTORY chip). The panel is
    /// a live projection of the store's journal — no per-open seeding needed.
    func openUndoHistory() {
        showUndoHistory = true
    }

    /// Closes the Undo-history panel.
    func closeUndoHistory() {
        showUndoHistory = false
    }

    /// `debug.undoHistory {open?, close?, undoTo?, redoTo?}` — stages the panel for a
    /// capture/E2E the wire alone can't reach (the panel is UI chrome, off
    /// `allCommands`/MCP — the `debug.quantizePanel` precedent). `open:true` shows it,
    /// `close:true` hides it; `undoTo:i` clicks the i-th undo row (i+1 undos through
    /// the SAME `store.undo()` the wire uses), `redoTo:j` clicks the j-th redo row.
    /// A BARE call (no acting param) is READ-ONLY — it echoes state without opening or
    /// stepping (the m11-a persistence trap: the panel's open flag survives across
    /// debug calls, so the echo must never re-open it implicitly). Returns the panel
    /// state to poll.
    private func undoHistoryDebug(_ params: [String: JSONValue]) -> JSONValue {
        if params["close"]?.boolValue == true {
            closeUndoHistory()
            return undoHistoryStateResponse()
        }
        if params["open"]?.boolValue == true {
            workspaceMode = .arrange
            openUndoHistory()
        }
        // Step through history via the UI model's plan (repeated store.undo/redo).
        if let i = params["undoTo"]?.doubleValue {
            undoHistoryModel.stepToUndoIndex(Int(i))
        }
        if let j = params["redoTo"]?.doubleValue {
            undoHistoryModel.stepToRedoIndex(Int(j))
        }
        return undoHistoryStateResponse()
    }

    // MARK: - Engine notices (m15-e)

    /// `debug.postEngineNotice {code?, message?, beat?, open?}` — stages the
    /// engine-notices surface for captures/E2E the wire alone can't reach cheaply
    /// (posting a real degradation needs a mid-session bake failure). Debug tier
    /// ONLY — off `allCommands`/MCP (the `debug.masterCapture` precedent). It routes
    /// a synthetic `EngineNoticeEvent` through the SAME `engineNoticeHandler` the
    /// real engine pushes on (engine → store ring), so the store's coalescing /
    /// ordering path is exercised exactly as in production — this never pokes the
    /// ring directly. `message` defaults to real-shape copy for the three known
    /// codes (a capture may pass an explicit string to reproduce a site verbatim);
    /// `open` toggles the popover. A bare call only echoes state. Returns the ring.
    private func postEngineNoticeDebug(_ params: [String: JSONValue]) -> JSONValue {
        if let code = params["code"]?.stringValue, !code.isEmpty {
            let message = params["message"]?.stringValue ?? Self.sampleEngineNoticeMessage(for: code)
            let beat = params["beat"]?.doubleValue
            engine.engineNoticeHandler?(EngineNoticeEvent(code: code, message: message, beat: beat))
        }
        if let open = params["open"]?.boolValue {
            showEngineNotices = open
        }
        return .object([
            "count": .number(Double(store.engineNotices.count)),
            "open": .bool(showEngineNotices),
            "notices": .array(store.engineNotices.map { notice in
                .object([
                    "code": .string(notice.code),
                    "message": .string(notice.message),
                    "beat": notice.beat.map { JSONValue.number($0) } ?? .null,
                    "count": .number(Double(notice.count)),
                    "lastAt": .number(Double(notice.lastAt)),
                ])
            }),
        ])
    }

    /// Beginner-readable fallback copy for the three engine-notice codes the
    /// PlaybackGraph posts (m15-e) — mirrors those inline message shapes so a bare
    /// `debug.postEngineNotice {code}` still renders real-shape copy; captures pass
    /// an explicit `message` when they want a production string byte-for-byte.
    private static func sampleEngineNoticeMessage(for code: String) -> String {
        switch code {
        case "clip-fades-skipped":
            return "Fades on 'Vocal' couldn't be applied this pass — the clip played on time, without its fades."
        case "clip-envelope-skipped":
            return "The gain envelope on 'Pad' couldn't be applied this pass — the clip played on time, without its envelope or fades."
        case "clip-stretch-pending":
            return "'Guitar' is still being time-stretched — it plays as silence until the stretch is ready."
        default:
            return "Playback ran with a schedule-time change (\(code))."
        }
    }

    /// Staging for the arrange marker-lane inline rename capture (m11-c): opens the
    /// rename field on `markerId` (or the first marker when omitted), or clears it
    /// with `{clear:true}`. Capture-only — the live UI reaches rename by double-
    /// click / context menu. READ-ONLY beyond the view override (never mutates the
    /// project), the `debug.undoHistory` precedent.
    private func markerRenameDebug(_ params: [String: JSONValue]) -> JSONValue {
        workspaceMode = .arrange
        if params["clear"]?.boolValue == true {
            stagedMarkerRenameID = nil
        } else if let raw = params["markerId"]?.stringValue, let id = UUID(uuidString: raw) {
            stagedMarkerRenameID = id
        } else {
            stagedMarkerRenameID = store.markers.first?.id
        }
        return .object(["renamingMarkerId": stagedMarkerRenameID.map { .string($0.uuidString) } ?? .null])
    }

    /// Read-only snapshot of the Undo-history panel so a capture flow can poll — the
    /// visibility plus the model's live step plan (labels + step counts), matching
    /// what `edit.history` returns over the wire (newest-first both directions).
    private func undoHistoryStateResponse() -> JSONValue {
        let history = undoHistoryModel.history
        return .object([
            "visible": .bool(showUndoHistory),
            "undo": .array(history.undo.map { JSONValue.string($0) }),
            "redo": .array(history.redo.map { JSONValue.string($0) }),
            "canUndo": .bool(history.canUndo),
            "canRedo": .bool(history.canRedo),
            "undoRows": .array(undoHistoryModel.undoRows.map { row in
                .object(["label": .string(row.label), "steps": .number(Double(row.stepCount))])
            }),
            "redoRows": .array(undoHistoryModel.redoRows.map { row in
                .object(["label": .string(row.label), "steps": .number(Double(row.stepCount))])
            }),
        ])
    }

    /// Read-only snapshot of the instrument picker (visibility + target + density +
    /// drilled bank + search + current display name), so a capture flow can poll.
    private func instrumentPickerStateResponse() -> JSONValue {
        .object([
            "visible": .bool(instrumentPickerTrackID != nil),
            "trackId": instrumentPickerTrackID.map { JSONValue.string($0.uuidString) } ?? .null,
            "mode": .string(panelDensity.density(forPanel: InstrumentPickerOverlay.panelID).rawValue),
            "search": .string(instrumentPicker.searchText),
            "drilledBank": instrumentPicker.drilledBank.map { JSONValue.string($0.name) } ?? .null,
            "current": .string(instrumentPicker.currentDisplayName),
            "bankCount": .number(Double(instrumentPicker.banks.count)),
            "audioUnitCount": .number(Double(instrumentPicker.audioUnits.count)),
        ])
    }

    // MARK: - Copilot rail (M6 rail-d)

    /// Opens/closes the Copilot chat rail (the header COPILOT chip). App-level —
    /// available in both the Arrange and Mix workspaces.
    func toggleCopilot() {
        showCopilot.toggle()
    }

    /// `ui.showCopilot {show?}` — opens/closes the copilot rail so a headless
    /// capture can drive it (the `ui.showClipFix` pattern). App-level, so it does
    /// NOT force a workspace. Off `allCommands`/MCP. Returns the rail state.
    private func showCopilotCommand(_ params: [String: JSONValue]) -> JSONValue {
        let show = params["show"]?.boolValue ?? true
        showCopilot = show
        return copilotStateResponse()
    }

    /// `debug.copilotSeed {mode}` — stages the copilot rail for a capture/E2E
    /// that can't be reached from the wire alone (no AI provider key on the
    /// capture machine — the `debug.clipFixSeed` precedent). Seeds a scripted
    /// transcript straight into the engine via `seedForCapture` (never a provider
    /// call). Opens the rail; `mode`:
    ///   - `conversation` (default): a user turn, assistant prose, two toolCall
    ///     chips (distinct commands), an ok toolResult + an error toolResult, a
    ///     closing assistant line, with `status = running` so the working shimmer
    ///     shows — the state-variety shot.
    ///   - `failed`: a short turn that ends in a `failure` entry (`status =
    ///     failed`) so the failure strip + reset affordance read.
    ///   - `idle`/`empty`: resets the engine to an empty idle rail (the first-use
    ///     hint shot).
    /// Off `allCommands`/MCP. Returns the resulting rail state.
    private func copilotSeed(_ params: [String: JSONValue]) -> JSONValue {
        let mode = params["mode"]?.stringValue ?? "conversation"
        showCopilot = true
        typealias Kind = CopilotEngine.TranscriptEntry.Kind
        let turnID = "seed-turn"
        switch mode {
        case "idle", "empty":
            copilotEngine.reset()
        case "failed":
            copilotEngine.seedForCapture(turnID: turnID, status: .failed, entries: [
                .user("add a punchy drum track and set the tempo to 120"),
                .assistant("On it — adding a drum track, then setting the tempo."),
                .toolCall(command: "track.add", argsSummary: #"{"name": "Drums", "kind": "audio"}"#),
                .toolResult(command: "track.add", ok: true, summary: #"{"trackId": "a1b2c3d4", "name": "Drums"}"#),
                .toolCall(command: "transport.setTempo", argsSummary: #"{"bpm": 120}"#),
                .failure("the AI provider returned an error: rate limit exceeded — wait a moment, then send again"),
            ])
        default:   // "conversation"
            copilotEngine.seedForCapture(turnID: turnID, status: .running, entries: [
                .user("set the tempo to 120 and add a bass track"),
                .assistant("Sure — I'll set the tempo to 120 BPM and add a bass track."),
                .toolCall(command: "transport.setTempo", argsSummary: #"{"bpm": 120}"#),
                .toolResult(command: "transport.setTempo", ok: true, summary: #"{"tempoBPM": 120}"#),
                .toolCall(command: "track.add", argsSummary: #"{"name": "Bass", "kind": "instrument"}"#),
                .toolResult(command: "track.add", ok: false,
                            summary: #"unknown kind "instrument" — expected "audio" or "midi""#),
                .assistant("That kind isn't valid — retrying the bass as a MIDI track."),
            ])
        }
        return copilotStateResponse()
    }

    /// `debug.copilotState` — read-only echo of the rail (visibility + the
    /// engine's own `ai.copilotState` wire shape: status, transcript, current
    /// turn) so an E2E flow can assert on the seeded transcript. Off
    /// `allCommands`/MCP.
    private func copilotStateResponse() -> JSONValue {
        .object([
            "visible": .bool(showCopilot),
            "state": copilotEngine.stateJSON(turnID: nil),
        ])
    }

    // MARK: - Lyrics Workshop (M6)

    /// Expands/collapses the WRITE-WITH-AI workshop inside the Sketchpad panel
    /// (the disclosure header).
    func toggleLyricsWorkshop() {
        showLyricsWorkshop.toggle()
    }

    /// `ui.showLyricsWorkshop {show?}` — opens the Sketchpad panel and
    /// expands/collapses the workshop so a headless capture can drive it (the
    /// `ui.showSketchpad` pattern). Off `allCommands`/MCP. Returns panel state.
    private func showLyricsWorkshopCommand(_ params: [String: JSONValue]) -> JSONValue {
        let show = params["show"]?.boolValue ?? true
        workspaceMode = .arrange
        showSketchpad = true
        showLyricsWorkshop = show
        return lyricsWorkshopStateResponse()
    }

    /// `debug.lyricsWorkshopSeed {mode}` — stages the workshop for a capture that
    /// can't be reached from the wire (no API key on the capture machine — the
    /// `debug.sketchpadDemo` precedent). Opens the panel + workshop and fills the
    /// composer, then per `mode`:
    ///   - `filled` (default): theme/style + a custom structure, no draft yet.
    ///   - `written`: also seeds a bracketed draft (with a provider credit) so the
    ///     APPLY button is visible.
    ///   - `applied`: as `written`, then applies the draft into the Sketchpad
    ///     lyrics editor (proving the hand-off).
    /// The seeded draft is a plain demo string, never a real provider call.
    private func lyricsWorkshopSeed(_ params: [String: JSONValue]) -> JSONValue {
        let mode = params["mode"]?.stringValue ?? "filled"
        workspaceMode = .arrange
        showSketchpad = true
        showLyricsWorkshop = true
        // A healthy sidecar so the surrounding Sketchpad reads as ready.
        sketchpad.updateSidecar(SidecarStatus(state: .healthy, message: "running",
                                              version: "stub", ditModel: "XL-turbo"))
        lyricsWorkshop.theme = "driving home under city lights"
        lyricsWorkshop.style = "80s synth-pop, wistful"
        lyricsWorkshop.setStructureForCapture(["verse", "chorus", "verse", "chorus", "bridge", "outro"])
        lyricsWorkshop.refineInstruction = ""

        let draft = """
        [verse]
        Headlights paint the empty street
        Radio and a steady beat
        [chorus]
        We're driving home, we're driving home
        Neon rivers, we're not alone
        [bridge]
        Hold the wheel, let the night unfold
        [outro]
        Driving home
        """
        switch mode {
        case "written":
            lyricsWorkshop.setDraftForCapture(draft, provider: "anthropic")
        case "applied":
            lyricsWorkshop.setDraftForCapture(draft, provider: "anthropic")
            lyricsWorkshop.apply()
        default:
            break   // "filled": composer only
        }
        return lyricsWorkshopStateResponse()
    }

    /// `debug.lyricsWorkshopState` — read-only snapshot of the workshop (never a
    /// key value): visibility, composer inputs, draft presence, provider credit,
    /// and the state tag.
    private func lyricsWorkshopStateResponse() -> JSONValue {
        let stateTag: String
        switch lyricsWorkshop.state {
        case .idle: stateTag = "idle"
        case .writing: stateTag = "writing"
        case .failed: stateTag = "failed"
        }
        return .object([
            "sketchpadVisible": .bool(showSketchpad),
            "workshopExpanded": .bool(showLyricsWorkshop),
            "theme": .string(lyricsWorkshop.theme),
            "style": .string(lyricsWorkshop.style),
            "structure": .array(lyricsWorkshop.structure.map { .string($0) }),
            "hasDraft": .bool(!lyricsWorkshop.draft.isEmpty),
            "provider": lyricsWorkshop.lastProvider.map { JSONValue.string($0) } ?? .null,
            "state": .string(stateTag),
            "sketchpadLyrics": .string(sketchpad.lyrics),
        ])
    }

    // MARK: - Settings panel (M6)

    /// Opens/closes the Settings overlay (the header gear chip + the ⌘, menu).
    func toggleSettings() {
        showSettings.toggle()
    }

    /// `ui.showSettings {show?}` — opens/closes the Settings overlay so a
    /// headless capture can drive it (the `ui.showSketchpad` pattern). Returns a
    /// status-only snapshot (never a key value). Off `allCommands`/MCP.
    private func showSettingsCommand(_ params: [String: JSONValue]) -> JSONValue {
        let show = params["show"]?.boolValue ?? true
        workspaceMode = .arrange
        showSettings = show
        // Optional `reveal` deep-links the modal to a below-the-fold section (a
        // capture / follow-the-guide affordance); anything else opens at the top.
        // "beta" → the Beta utility row; "connection" → the Agent Connection section.
        let reveal = params["reveal"]?.stringValue
        settingsRevealBeta = show && reveal == "beta"
        settingsRevealConnection = show && reveal == "connection"
        return settingsStateResponse()
    }

    /// `debug.settingsSeed {mode}` — swaps in a SEEDED settings model for a
    /// capture that can't be reached from the wire (the `debug.sketchpadDemo`
    /// precedent). `mode`:
    ///   - `empty`: nothing configured (all rows NOT SET).
    ///   - `mixed` (default): anthropic env-LOCKED + openai KEYCHAIN-configured
    ///     + suno dormant/not-set + ACE-Step keyless.
    /// ASSUMPTION: the seed uses an in-memory store + a fake environment (not the
    /// real Keychain) so a capture is deterministic and can never clobber a real
    /// user key — the row badge reflects `source`, which the in-memory store
    /// reports identically. The real Keychain round-trip is proven by
    /// AIServicesTests/KeyStoreTests. Fake values are non-secret demo strings.
    private func settingsSeed(_ params: [String: JSONValue]) -> JSONValue {
        let mode = params["mode"]?.stringValue ?? "mixed"
        let store: APIKeyStoring
        let environment: [String: String]
        switch mode {
        case "empty":
            store = InMemoryKeyStore()
            environment = [:]
        default:
            store = InMemoryKeyStore([.openai: "sk-test-openai-DEMO1234"])
            environment = ["ANTHROPIC_API_KEY": "sk-ant-env-DEMO5678"]
        }
        let seeded = SettingsModel(store: store, environment: environment)
        // Captures drive an InMemoryKeyStore (never the real Keychain), so the
        // presence probe is trivially non-blocking — resolve synchronously here so
        // the captured rows are truthful immediately (the launch path uses the
        // async, off-main `refresh()`).
        seeded.resolveForCapture()
        if mode != "empty" {
            // Show the session "just saved" mask on the keychain row too (last 4
            // of the seeded demo key, matching SettingsModel.mask output).
            seeded.setSavedMaskForCapture("•••• 1234", for: .openai)
        }
        settings = seeded
        workspaceMode = .arrange
        showSettings = true
        return settingsStateResponse()
    }

    /// `debug.settingsReset` — restores the real Keychain-backed settings model
    /// and closes the overlay.
    private func settingsReset() -> JSONValue {
        settings = SettingsModel(store: KeychainKeyStore())
        showSettings = false
        // Restore the real, presence-probed rows off the main actor (m10-t) — the
        // model starts `.checking`; this resolves it without blocking.
        Task { [settings] in await settings.refresh() }
        return settingsStateResponse()
    }

    /// `debug.settingsState` — status-only snapshot (visibility + per-row
    /// configured/source/locked). Never carries a key value — same discipline as
    /// the `ai.providerStatus` wire surface.
    private func settingsStateResponse() -> JSONValue {
        .object([
            "visible": .bool(showSettings),
            "rows": .array(settings.rows.map { row in
                .object([
                    "id": .string(row.id),
                    "configured": .bool(row.configured),
                    "source": .string(row.source.rawValue),
                    "locked": .bool(row.isLocked),
                    // m10-t additive: whether the row is still awaiting its presence
                    // probe, and whether a stored key is consent-gated — so a gate
                    // can assert the row resolved truthfully after the async refresh.
                    "checking": .bool(row.isChecking),
                    "consentRequired": .bool(row.consentRequired),
                ])
            }),
        ])
    }

    /// `debug.sketchpadState` — read-only snapshot of the panel (candidates +
    /// visibility + sidecar), so a capture flow can poll for the state it wants.
    /// Each candidate additionally carries `row` (m18-g, additive): the RESOLVED
    /// presentation the row actually displays after deferring to the
    /// generation-presence registry (`SketchpadModel.resolvedCandidate`) — a
    /// gate can diff `row.statusText` against the card's `stageLabel` to prove
    /// both surfaces tell one story about the same job.
    private func sketchpadStateResponse() -> JSONValue {
        .object([
            "visible": .bool(showSketchpad),
            "sidecar": .string(sketchpad.sidecarStatus?.state.rawValue ?? "unknown"),
            "candidates": .array(sketchpad.candidates.map { candidate in
                guard case .object(var fields) = Self.candidateSummary(candidate) else {
                    return Self.candidateSummary(candidate)   // unreachable — summary is an object
                }
                fields["row"] = Self.candidateSummary(SketchpadModel.resolvedCandidate(
                    candidate, registry: generationPresence.jobs))
                return .object(fields)
            }),
        ])
    }

    /// A compact JSON summary of one candidate for the debug commands.
    private static func candidateSummary(_ c: SketchpadCandidate) -> JSONValue {
        var obj: [String: JSONValue] = [
            "id": .string(c.id.uuidString),
            "jobId": .string(c.jobID),
            "prompt": .string(c.promptSnippet),
            "stale": .bool(c.isStale),
        ]
        switch c.state {
        case .queued:
            obj["state"] = .string("queued")
        case .running(let progress, let statusText):
            obj["state"] = .string("running")
            if let progress { obj["progress"] = .number(progress) }
            if let statusText { obj["statusText"] = .string(statusText) }
        case .succeeded(let audioPath, let bpm, let duration):
            obj["state"] = .string("succeeded")
            obj["audioPath"] = .string(audioPath)
            if let bpm { obj["bpm"] = .number(bpm) }
            if let duration { obj["durationSeconds"] = .number(duration) }
        case .failed(let message):
            obj["state"] = .string("failed")
            obj["message"] = .string(message)
        case .imported(let trackID, let trackName):
            obj["state"] = .string("imported")
            obj["trackId"] = .string(trackID.uuidString)
            obj["trackName"] = .string(trackName)
        }
        return .object(obj)
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
        // target:"plugin" (M3 vi-b) captures a floating plugin window instead of
        // the main window. KNOWN LIMIT: an out-of-process AUv3 remote view
        // rasterizes BLANK through cacheDisplay (the body then proves chrome +
        // frame only; plugin.listOpenUIs is the functional assertion). In-process
        // bodies — all of cycle vi-b-1 (generic) and cycle vi-b-2's v2 views —
        // capture fully.
        if params["target"]?.stringValue == "plugin" {
            return try capturePluginUI(params)
        }

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

    /// Captures one open plugin window's contentView to a PNG (the
    /// `debug.captureUI {target:"plugin", trackId, effectId?}` path). Same
    /// `cacheDisplay(in:to:)` pipeline as the main-window capture — so an
    /// in-process generic/v2 body renders its real pixels (chrome header + the
    /// parameter rows). Returns `{path, width, height, method:"plugin"}`.
    private func capturePluginUI(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let rawTrack = params["trackId"]?.stringValue else {
            throw DebugError("debug.captureUI target:\"plugin\" requires trackId")
        }
        guard let trackID = UUID(uuidString: rawTrack) else {
            throw DebugError("trackId is not a valid UUID: \(rawTrack)")
        }
        var effectID: UUID?
        if let rawEffect = params["effectId"]?.stringValue {
            guard let parsed = UUID(uuidString: rawEffect) else {
                throw DebugError("effectId is not a valid UUID: \(rawEffect)")
            }
            effectID = parsed
        }
        guard let panel = pluginWindows.panel(forTrackID: trackID, effectID: effectID),
              let contentView = panel.contentView,
              contentView.bounds.width > 1, contentView.bounds.height > 1 else {
            throw DebugError(
                "no plugin window open for that target — open it with plugin.openUI first")
        }
        let url = captureURL(params)
        panel.displayIfNeeded()
        contentView.layoutSubtreeIfNeeded()
        guard let rep = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds) else {
            throw DebugError("plugin window has no drawable backing yet — retry once it has displayed")
        }
        contentView.cacheDisplay(in: contentView.bounds, to: rep)
        try writePNG(rep, to: url)
        return .object([
            "path": .string(url.path),
            "width": .number(Double(rep.pixelsWide)),
            "height": .number(Double(rep.pixelsHigh)),
            "method": .string("plugin"),
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
