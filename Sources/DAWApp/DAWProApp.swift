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

    /// The local RVC voice-conversion sidecar's lifecycle manager + typed
    /// client (m10-p-5) — the `sidecarManager`/`songGenerator` split for the
    /// SECOND local sidecar (127.0.0.1:8002, `scripts/rvc/`). SHARED with the
    /// control router (the `sidecarManager` precedent) so the Voice panel and
    /// the `vc.*` wire path never diverge on sidecar/boot state.
    let voiceConversionManager: VoiceConversionManager
    let voiceConversionClient: VoiceConversionClient

    /// The Voice panel's headless model (m10-p-5): local voice DATASETS under
    /// app support, the voice-engine banner (user copy), the facade voice
    /// list, the honest Train state machine, and the convert-clip action.
    /// Owned here (like `clipFix`) so `debug.voicePanel` can drive it and
    /// `debug.captureUI` renders the same instance the live panel shows.
    /// Convert rides the SAME store/client seams as the wire's
    /// `vc.convertVocals` (no parallel mutation path).
    let voicePanel: VoicePanelModel

    /// Whether the Voice panel is open in the Arrange workspace. Driven by the
    /// header VOICE chip and `debug.voicePanel`.
    var showVoicePanel = false

    /// The audio clip the "Convert to Voice…" sheet is open for (nil =
    /// closed). Set by the clip context menu and `debug.voicePanel`; the sheet
    /// renders as a centered overlay (the named in-window modal pattern).
    var voiceConvertClipID: UUID?

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

    /// The EQ CURVE editor's headless model (m22-b): created over
    /// `effectEditor` whenever the opened insert is an EQ — the engine's live
    /// render sample rate is injected AT OPEN TIME (design §3.4; coefficients
    /// near Nyquist depend on it) — and dropped on close or when a non-EQ
    /// insert replaces it. Owned here (like `effectEditor`) so
    /// `debug.effectEditor` can echo `selectedBand` off the SAME instance the
    /// live card renders.
    var eqCurveEditor: EQCurveEditorModel?

    /// The built-in POLY SYNTH editor's headless model (the `effectEditor`
    /// twin for instruments): the spec-driven knob sections + the
    /// wire-identical apply path (`setInstrument` partial updates — exactly
    /// what `track.setInstrument` calls). Owned here (like `effectEditor`) so
    /// `debug.synthEditor` can drive it and `debug.captureUI` renders the
    /// same instance the live card shows.
    let polySynthEditor: PolySynthEditorModel

    /// The track the Poly Synth editor is open for (nil = closed). Set by the
    /// instrument picker's TUNE affordance (which replaces the picker modal)
    /// and `debug.synthEditor`; the card renders as a centered overlay. Only
    /// ever a track whose current instrument is the built-in poly synth.
    var polySynthEditorTrackID: UUID?

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

    /// The Export (bounce) dialog's headless model (m23-m3): the output format
    /// (`DeliveryFormat`), the tracks to leave out, and the loudness target —
    /// plus the ONE place that state becomes `ProjectStore.renderBounce`
    /// arguments (`ExportDialogModel.export`). Owned here (like `quantizeModel`)
    /// rather than in `ContentView`'s `@State` so `debug.captureUI` renders the
    /// same instance the user sees and `debug.exportDialog` can drive it
    /// headlessly — that hoisting is what makes the item's gate runnable.
    let exportDialog: ExportDialogModel

    /// Whether the Export dialog is open. Driven by the transport EXPORT chip
    /// (via `exportSong()`), the onboarding tour's export step, and the
    /// `debug.exportDialog` staging command; the card renders as a centered
    /// overlay over the workspace.
    var showExportSheet = false

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

    /// UI selection: which arrange clips are selected, and which one is the FOCUS
    /// (m23-g1). Hoisted out of ContentView's @State so `debug.captureUI` renders
    /// with the same selection as the live window.
    ///
    /// The invariants and the focus rule live on the type (`ArrangeSelection`),
    /// not here — `ids`/`focusID` are `private(set)`, so nothing outside its
    /// mutators can put the pair into an incoherent state.
    var arrangeSelection = ArrangeSelection()

    /// The FOCUS clip — the one whose piano roll is open (nil = closed). Only
    /// MIDI clips actually open the editor (`openEditorClip` filters).
    ///
    /// A COMPUTED MIRROR of `arrangeSelection.focusID` since m23-g1, rather than
    /// stored state that could drift from the selection set. Every pre-existing
    /// read and write keeps its exact meaning: a non-nil assignment is a fresh
    /// SINGLE selection (`selectOnly`) and nil is "nothing selected" (`clear`) —
    /// which is bit-identical to the pre-g1 behaviour, because single selection
    /// is the only selection that existed before g1. That is what keeps the
    /// m23-e note-editor path (this property IS the editor's target resolver, at
    /// ~19 call sites) safe from the multi-select work.
    var selectedClipID: UUID? {
        get { arrangeSelection.focusID }
        set { arrangeSelection.focus(newValue) }
    }

    /// Bumped every time the LANES have re-rendered with a new selection — the
    /// `arrangeDropReportSeq` contract (m23-e echo-seam law). Not state anyone
    /// renders: it is the `debug.arrangeSelection` seam's proof that a selection
    /// it just changed has been THROUGH the view, so a capture taken right after
    /// the echo answers frames the NEW selection rather than the previous one.
    var arrangeSelectionRenderSeq = 0

    /// Bumped every time the LANES have re-rendered with new clip GEOMETRY —
    /// the `arrangeSelectionRenderSeq` twin, for `debug.arrangeDrag` (m23-g2).
    ///
    /// A SEPARATE counter is required, not a convenience: `arrangeSelectionRenderSeq`
    /// fires on `.onChange(of: selection)`, and a group MOVE does not change the
    /// selection at all — so waiting on it after a drag would always time out
    /// (and, worse, a gate that waited on it would read whatever the last
    /// SELECTION change left behind and believe it had waited for something).
    var arrangeClipLayoutRenderSeq = 0

    /// Bumped whenever a clip is clicked in the arrange (real tap or staged) so
    /// ContentView moves keyboard focus onto the arrange surface. A nonce rather
    /// than a Bool because the request repeats: every click re-asserts focus,
    /// including the clicks that follow the piano roll grabbing it on open
    /// (`PianoRollView.onAppear { isFocused = true }`).
    var arrangeKeyFocusNonce = 0

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
    /// A programmatic horizontal scroll request + its nonce, consumed by the lanes
    /// (`TimelineLanesView.hScrollApplyTarget`) — a `ScrollViewReader` jump onto a
    /// layout-real 1 pt marker at that content x. There is NO AppKit bridge here
    /// and never was: the arrange's programmatic scroll is plain SwiftUI (the name
    /// `ArrangeHScrollBridge` in this comment before m23-c2 described
    /// infrastructure that was never built, and it is what made m23-c2's roadmap
    /// line assume the piano roll needed one too — it did not).
    ///
    /// TWO drivers write here: a zoom's anchor-preserving offset (m17-b), applied
    /// in the same transaction as the scale change, and follow-the-playhead's page
    /// turns (m23-c2).
    var arrangeHScrollApplyTarget: CGFloat?
    var arrangeHScrollApplyNonce = 0
    /// The pinch in flight (nil at rest): captured on the first magnify tick so
    /// per-tick zoom math measures off a FIXED anchor beat/screen-x.
    private var arrangePinch: ArrangeZoom.PinchState?

    // MARK: Follow the playhead (m23-c2)

    /// The arrange lanes' follow runtime. Per-surface (scrolling the roll must not
    /// suspend the arrange) while the ENABLE flag both surfaces read is the one
    /// persisted `panelLayout.followPlayhead` slot.
    let arrangeFollow = FollowPlayheadModel()
    /// The piano-roll bands' follow runtime. Hoisted here rather than living in the
    /// view's `@State` so it survives a clip switch and so the `debug.followPlayhead`
    /// echo can report BOTH surfaces' ground truth from one place.
    let pianoRollFollow = FollowPlayheadModel()
    /// The lanes' LAID-OUT content width, reported by the lanes' own geometry. The
    /// follow clamp's ceiling — computing it here instead would fork
    /// `TimelineLanesView.totalBeats`'s padding heuristic into a second source of
    /// truth. `@ObservationIgnored`: nothing renders it, so it must not invalidate.
    @ObservationIgnored var arrangeContentWidth: CGFloat = 0
    // MARK: Piano-roll zoom (m21-c)

    /// True while the piano-roll editor holds key focus (reported by the view's
    /// `onFocusChange`). Routes the View-menu ⌘+/⌘−/⌘0 to the ROLL's zoom
    /// instead of the arrange timeline's — the menu key equivalents fire before
    /// any focused view sees the key, so the routing must live here.
    var pianoRollEditorFocused = false

    /// Whether the open roll has NOTES selected, reported by the view (m23-x).
    ///
    /// NOT a second focus flag, and not interchangeable with one: the roll
    /// self-focuses on appear and opens for ANY single selected MIDI clip, so
    /// `pianoRollEditorFocused` alone is already true when the user has merely
    /// clicked a clip in the arrange. This is the extra term that separates
    /// "user is editing notes" from "user selected a clip" — see
    /// `PianoRollNoteSelectionBridge` for the measurement that forced it.
    let pianoRollNoteSelection = PianoRollNoteSelectionBridge()

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
    /// Bumped every time the lanes report pointer state back UP (m23-e). Not
    /// state anyone renders — it is the seam's proof that a staged event has
    /// been THROUGH the view, which is what `arrangePointerDebug` waits on
    /// before it answers. Every staged action reports (`applyPointerStage` runs
    /// `handlePointerHover`/`endPointerHover` on all four), so this bumps once
    /// per staging regardless of what the action then did.
    var arrangePointerReportSeq = 0
    /// The refusal currently surfaced in the arrange lanes (verbatim store
    /// message, amber bubble) — on a clip block, or (m23-e) on the lane an
    /// empty-lane create was refused on. Auto-clears a few seconds after
    /// presentation.
    var arrangeSplitRefusal: ArrangeSplitRefusal?
    private var arrangeRefusalSeq = 0

    /// The clip the last empty-lane double-click CREATED (m23-e), or nil when
    /// that create was refused or found no room. Read-back state for the
    /// `debug.arrangePointer` echo — never a source of truth for the UI. Set
    /// ONLY by the view's own create callback; the seam clears it before staging
    /// a double-click so the echo can never describe a previous one.
    var arrangeCreatedClipID: UUID?

    /// The empty-lane hints the arrange lanes are DRAWING (m23-v), reported UP by
    /// the very layer that draws them — never recomputed here.
    ///
    /// That distinction is the item, not plumbing. `DAWApp` has no test target,
    /// so a hint composed in a `body` is invisible to everything under `Tests/`
    /// (m23-m3b measured the consequence: a mutant that broke a `DAWApp`-only
    /// binding left 3979 tests / 405 suites entirely green). An `AppModel`-side
    /// re-derivation of `ArrangeEmptyLaneHints.hints(for: store.tracks)` would
    /// echo `true` from a build whose lanes draw nothing at all — the echo would
    /// be decoration. Reading the drawing layer's own report means a view that
    /// does not draw structurally cannot claim it did.
    var arrangeEmptyLaneHints: [ArrangeEmptyLaneHint] = []
    /// Bumped every time the lanes report their hint set (the
    /// `arrangePointerReportSeq` discipline). Nothing renders it: it is the
    /// seam's proof that a render has been through the view since a caller last
    /// looked, which is what lets a staged read WAIT for a hint to appear or go
    /// after a `track.add` / `clip.addMIDI` rather than sleep and hope.
    var arrangeEmptyLaneHintSeq = 0

    // MARK: Arrange audio-drop staging (m23-f)

    /// The staged drop event `debug.arrangeDrop` injects (nil in normal use) —
    /// ContentView threads it into the lanes, which run it through the SAME
    /// `AudioLaneDropCore` a real Finder drag runs. A real drag is not
    /// injectable: `DropInfo` has no public initializer, and the unbundled
    /// staging binary has no Accessibility grant (the m17-b measurement).
    var arrangeDropStage: ArrangeDropStage?
    /// The drop layer's LIVE hover, reported UP by the lanes — i.e. whether a
    /// drop line is actually standing. Never the seam's own input.
    var arrangeDropHover: AudioDropHover?
    /// What the drop handler RESOLVED on the last staged action (as opposed to
    /// what it left behind). Distinguishing the two is the point: a drop decides
    /// a landing beat and must leave no live hover.
    var arrangeDropDecided: AudioDropHover?
    /// Bumped every time the lanes report drop state back UP. Not state anyone
    /// renders — it is the seam's proof that a staged event has been THROUGH the
    /// view, which `arrangeDropDebug` waits on before it answers (the m23-e
    /// echo-seam law: an echo that reports state the caller just changed must
    /// wait for the view to confirm it applied, or it returns the PREVIOUS
    /// call's state and can stale-green a gate).
    var arrangeDropReportSeq = 0
    /// The per-file results of the last import that came in through the ARRANGE
    /// DROP path (never the File→Import menu, which reports its own failures in
    /// an alert). Read-back state for the `debug.arrangeDrop` echo; cleared by
    /// the seam before staging a drop so the echo can never describe an earlier
    /// one (the `arrangeCreatedClipID` convention).
    var arrangeDropImportResults: [AudioImportFileResult] = []

    // MARK: Arrange rubber band (m23-g3)

    /// The staged marquee step `debug.arrangeMarquee` injects (nil in normal
    /// use) — ContentView threads it into the lanes, which run it through the
    /// SAME handlers the real `DragGesture` runs (the `arrangePointerStage`
    /// precedent; a real mouse drag is not injectable on the unbundled staging
    /// binary — the m17-b Accessibility measurement).
    var arrangeMarqueeStage: ArrangeMarqueeStage?
    /// The band the lanes are ACTUALLY drawing, reported up — nil exactly when
    /// no marquee is in flight. Never the seam's own input: this is the only
    /// honest instrument for "the band is standing mid-drag and gone after",
    /// and a mirror written by the seam would prove nothing about the view.
    var arrangeMarqueeBand: CGRect?
    /// What the last reported band TOUCHED. Distinct from the selection: with
    /// the shift chord the selection is base ∪ hits, so a gate that could only
    /// see the selection could not tell a union from a replace.
    var arrangeMarqueeHits: Set<UUID> = []
    /// Bumped every time the lanes report marquee state back UP — the seam's
    /// proof that a staged step has been THROUGH the view (the m23-e echo-seam
    /// law: an echo that reports state the caller just changed must wait for the
    /// view to confirm it applied, or it answers with the PREVIOUS call's state
    /// and can stale-GREEN a gate).
    var arrangeMarqueeReportSeq = 0
    /// The lanes' RESOLVED vertical ladder, reported up on first render and on
    /// every change. The ladder is NON-UNIFORM (an expanded automation row adds
    /// 64 pt) and `rowHeight` is user-adjustable (beta m10-d), so a caller that
    /// hardcoded a pitch would compute a fixture the app never renders — and a
    /// ladder recomputed HERE would be a second producer free to agree with the
    /// view by luck. The view produces it; this only carries it out.
    var arrangeLaneGeometry: ArrangeLaneGeometry = .empty

    // MARK: Arrange track-header reorder (m23-h)

    /// The staged drag step `debug.trackHeaderDrag` injects (nil in normal use)
    /// — `TrackRowsList` runs it through the SAME `dragUpdate`/`dragEnd`
    /// handlers the real `DragGesture` runs (the `arrangeMarqueeStage`
    /// precedent; a real mouse drag is not injectable on the unbundled staging
    /// binary — the m17-b Accessibility measurement).
    var trackReorderStage: TrackReorderStage?
    /// The list's MEASURED row ladder, reported up on first layout and on every
    /// change. The seam echoes it because it is the ground truth a caller must
    /// compute a fixture FROM: row heights vary with each track's open
    /// takes/automation sections and `rowHeight` is user-adjustable (beta
    /// m10-d), so a hardcoded pitch would describe a list the app never drew.
    var trackRowLadder: TrackRowLadder = .empty
    /// The drag the list is ACTUALLY running — including the landing it is
    /// drawing the indicator from. Never the seam's own input: this is the only
    /// honest instrument for "the drop line stands at the right slot mid-drag,
    /// and the order has NOT changed yet".
    var trackReorderDrag: TrackReorderDragState?
    /// Bumped every time the list reports back UP — the seam's proof that a
    /// staged step has been THROUGH the view (the m23-e echo-seam law: an echo
    /// that reports state the caller just changed must wait for the view to
    /// confirm it applied, or it answers with the PREVIOUS call's state and can
    /// stale-GREEN a gate).
    var trackReorderReportSeq = 0

    // MARK: Mixer strip reorder (m23-z)

    /// The staged drag step `debug.mixerStripDrag` injects (nil in normal use)
    /// — `MixerView` runs it through the SAME `dragUpdate`/`dragEnd` handlers
    /// the real `DragGesture` runs.
    var mixerStripDragStage: MixerStripDragStage?
    /// The console's MEASURED strip ladder, in VISUAL order, reported up on
    /// first layout and on every change. The seam echoes it because it is the
    /// ground truth a caller must compute a fixture FROM: the bus divider's
    /// width is intrinsic (its caption's text), so the gaps are NOT uniform and
    /// a hardcoded pitch would describe a rack the app never drew.
    ///
    /// Only measured while the Mix workspace is on screen — a caller reads it
    /// after `ui.showMixer`, and an empty ladder from the Arrange tab means
    /// "not rendered", which is why the seam echoes `workspaceMode` beside it.
    var mixerStripLadder: MixerStripLadder = .empty
    /// The drag the console is ACTUALLY running — the landing it is drawing the
    /// line from, and the parting offsets it is rendering the resting strips
    /// with. The only honest instrument for "the line stands at the right slot,
    /// the rack parted by the right distance, and the order has NOT changed yet".
    var mixerStripDrag: MixerStripDragState?
    /// Bumped every time the console reports back UP (the echo-seam law).
    var mixerStripDragReportSeq = 0

    /// Surfaces a refused arrange edit VERBATIM (m17-c): the store's
    /// LocalizedError message — the SAME string the wire returns for the same
    /// call — as a transient amber bubble on whatever refused. Auto-clears
    /// after 6 s unless a newer refusal replaced it (seq guard).
    func presentArrangeSplitRefusal(_ error: any Error, clipID: UUID?) {
        presentArrangeRefusal(error, anchor: clipID.map { .clip($0) })
    }

    /// m23-e: the empty-lane create's refusal — same verbatim copy, anchored on
    /// the LANE it was attempted on (there is no clip to hang it from).
    func presentArrangeLaneRefusal(_ error: any Error, trackID: UUID, beat: Double) {
        arrangeCreatedClipID = nil
        presentArrangeRefusal(error, anchor: .lane(trackID: trackID, beat: beat))
    }

    private func presentArrangeRefusal(_ error: any Error, anchor: ArrangeSplitRefusal.Anchor?) {
        arrangeRefusalSeq += 1
        let seq = arrangeRefusalSeq
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        arrangeSplitRefusal = ArrangeSplitRefusal(anchor: anchor, message: message, seq: seq)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, self.arrangeSplitRefusal?.seq == seq else { return }
            self.arrangeSplitRefusal = nil
        }
    }

    /// m23-e: a successful empty-lane create — select the new clip (which is
    /// what OPENS the piano roll on it) and clear any standing refusal, so the
    /// amber bubble can never outlive the condition that produced it.
    func noteCreatedClip(_ clipID: UUID) {
        arrangeCreatedClipID = clipID
        arrangeSplitRefusal = nil
        selectedClipID = clipID
    }

    // MARK: - Arrange multi-select (m23-g1)

    /// The ONE arrange click handler: the ClipBlock tap and the
    /// `debug.arrangeSelection {act:"click"}` seam both land here, so the seam
    /// cannot drift from the gesture. Policy is the headless type's
    /// (`ArrangeSelection.apply(click:modifiers:)`); this adds only the focus
    /// request, which is view state the model cannot set itself.
    @discardableResult
    func clickClip(id: UUID, modifiers: ArrangeClickModifiers) -> ArrangeClickIntent {
        let intent = arrangeSelection.apply(click: id, modifiers: modifiers)
        // Move keyboard focus onto the arrange so DELETE reaches it. Bumped on
        // EVERY click, including a plain re-click of an already-selected clip:
        // opening the piano roll steals focus back (its `.onAppear`), so a
        // one-shot flag would leave the arrange permanently unfocused for MIDI.
        arrangeKeyFocusNonce &+= 1
        return intent
    }

    /// The ONE arrange TRACK-HEADER click handler (m23-y): the `TrackRow` tap and
    /// the `debug.arrangeSelection {act:"clickTrack"}` seam both land here, so the
    /// seam cannot drift from the gesture. `clickClip`'s twin, in the same shape
    /// and for the same reasons.
    ///
    /// Policy is the headless type's (`ArrangeTrackSelection.apply` — including
    /// what "this track's clips" means, the shared chord table, and the
    /// all-or-none set toggle); this owns only composition. Nothing here decides
    /// anything, which is what keeps the whole rule inside `Tests/DAWAppKitTests`
    /// while `DAWApp` has no test target.
    ///
    /// Returns nil for an unknown track id — and does NOT bump the focus nonce in
    /// that case: nothing was selected, so asserting arrange key focus would be a
    /// side effect with no cause. The seam turns the nil into a thrown error with
    /// the id in it (`debug.trackHeaderDrag`'s "no track with id" convention),
    /// rather than answering a silent no-op a gate would read as green.
    ///
    /// THE NONCE BUMP IS LOAD-BEARING, exactly as it is on `clickClip`: it is what
    /// moves keyboard focus onto the arrange workspace (`ArrangeDeleteKey`'s
    /// `.onChange(of: model.arrangeKeyFocusNonce)`), so DELETE reaches the clips
    /// the header click just selected with no separate "click the background
    /// first" step. Bumped on EVERY header click, including one that changed
    /// nothing, for `clickClip`'s stated reason — opening the piano roll steals
    /// focus back, so a one-shot flag would leave the arrange permanently
    /// unfocused.
    ///
    /// A CONSEQUENCE THIS MAKES NEWLY REACHABLE, stated because it is a real
    /// arbitration and not an accident: `ArrangeSelection.replace(with:)` KEEPS a
    /// focus that survives into the new set, so clicking the header of the track
    /// holding the open editor clip leaves the piano roll OPEN while this bump
    /// moves key focus to the arrange. DELETE then has two candidate consumers.
    /// The arbitration is SwiftUI's and is structural — `PianoRollView` owns
    /// `.onKeyPress(.delete)` as a DESCENDANT of `ArrangeDeleteKey`, so a focused
    /// roll with notes selected consumes the key first and this path never runs.
    /// What is decided HERE, and is the half a gate can observe, is the other
    /// branch: when `handleArrangeDeleteKey` DOES run it has no piano-roll term
    /// among its four guards (unlike `handleArrangeNudgeKey`'s fifth), so it
    /// deletes the whole union INCLUDING the clip the roll is open on, atomically,
    /// and `openEditorClip` resolves the now-dead id to nil and closes the editor.
    /// There is no partial state in between: the delete is one `performEdit`.
    @discardableResult
    func clickTrack(id: UUID, modifiers: ArrangeClickModifiers) -> ArrangeTrackClickOutcome? {
        guard let track = store.tracks.first(where: { $0.id == id }) else { return nil }
        let outcome = ArrangeTrackSelection.apply(
            click: track, modifiers: modifiers, to: &arrangeSelection)
        arrangeKeyFocusNonce &+= 1
        return outcome
    }

    /// The ONE arrange MARQUEE handler (m23-g3): the lanes' `DragGesture` and
    /// the `debug.arrangeMarquee` seam both land here, so the seam cannot drift
    /// from the gesture.
    ///
    /// Geometry is `ArrangeMarquee`'s and selection policy is
    /// `ArrangeSelection`'s; this owns only the composition of the two, and it
    /// is deliberately tiny:
    ///   • plain band → the selection IS the hit set
    ///   • shift/⌘ band → the pre-drag BASE, then the hits unioned on
    /// The additive path restores the base FIRST rather than unioning onto
    /// whatever the previous update left, because a marquee re-decides on every
    /// pointer move: without the restore, shrinking a shift-band could never
    /// give a clip back and the selection would only ever grow. The focus
    /// survives both paths untouched (it is a member of `base`), and neither
    /// path invents one — see `ArrangeSelection.replace(with:)` for why a band
    /// must never open the note editor.
    ///
    /// NO keyboard-focus nonce here, unlike `clickClip`: a marquee is a
    /// pointer-only bulk gesture on EMPTY space, and asserting arrange focus
    /// mid-drag would fight the piano roll for the key window on every update.
    func applyArrangeMarquee(hits: Set<UUID>, base: Set<UUID>, additive: Bool) {
        if additive {
            arrangeSelection.replace(with: base)
            arrangeSelection.formUnion(hits)
        } else {
            arrangeSelection.replace(with: hits)
        }
    }

    /// Deletes every selected clip as ONE undoable edit. The DELETE key and the
    /// `debug.arrangeSelection {act:"delete"}` seam both call exactly this.
    ///
    /// Filters the selection against LIVE clips first (the stale-id policy on
    /// `ArrangeSelection.resolved(in:)`): a selected clip can vanish under the
    /// selection via undo/redo or an agent's `clip.remove`, and a stale id must
    /// be a silent skip, never a thrown refusal at the user. Anything the store
    /// then refuses (a take-comp member) surfaces VERBATIM as the amber bubble,
    /// on the focus clip if there is one — the m17-c/m23-e refusal convention;
    /// a silent no-op is the complaint that convention exists to prevent.
    ///
    /// Returns true when clips were actually removed (so the key handler can
    /// answer `.handled` vs `.ignored` honestly).
    @discardableResult
    func deleteArrangeSelection() -> Bool {
        let live = Set(store.tracks.flatMap { $0.clips.map(\.id) })
        let targets = arrangeSelection.resolved(in: live)
        guard !targets.isEmpty else { return false }
        do {
            _ = try store.removeClips(ids: Array(targets))
            // Cleared only on success: a refused delete leaves the selection
            // standing so the user can see what was refused and fix it.
            arrangeSelection.clear()
            return true
        } catch {
            presentArrangeSplitRefusal(error, clipID: arrangeSelection.focusID ?? targets.first)
            return false
        }
    }

    // MARK: - Arrange group drag (m23-g2)

    /// The arrange grid the LANES actually apply — Simple locks it to `.bar`
    /// regardless of the picker (`ClipSnap.effective`). One expression, shared by
    /// the group-drag handler and both debug seams, so a gate that sets `snap`
    /// and a gesture that reads it can never disagree about what is in force.
    var effectiveClipSnap: ClipSnap {
        ClipSnap.effective(density: panelDensity.density(forPanel: TimelineLanesView.panelID),
                           picked: clipSnap)
    }

    /// What a group drag actually did — the drag's honest answer, sourced from
    /// the STORE's own `ClipsMoveResult` rather than recomputed.
    struct ArrangeGroupDragOutcome {
        /// The ACHIEVED anchor start (not the requested one). The drag readout
        /// shows this, so the bubble cannot claim a beat the clamp overrode.
        var anchorStart: Double
        var movedIDs: [UUID] = []
        /// What the STORE was asked for — post-gesture-floor, so it is NOT
        /// always what the pointer asked for. When `gestureFlooredAtZero` is
        /// true this equals `effectiveDeltaBeats` (the store had nothing left
        /// to clamp) and the earlier reduction is the flag's to report. Kept
        /// store-local on purpose: an app-layer field that shadowed
        /// `ClipsMoveResult.requestedDeltaBeats` with a DIFFERENT meaning is
        /// exactly the drift this cycle was spent designing out.
        var requestedDeltaBeats: Double = 0
        var effectiveDeltaBeats: Double = 0
        /// The whole-group clamp inside `ProjectStore.moveClips` engaged.
        var storeClamped: Bool = false
        /// The gesture's own anchor floor engaged (`ArrangeGroupDrag.Plan`).
        var gestureFlooredAtZero: Bool = false
        /// THE DRAG'S REQUESTED LANDING WAS REDUCED — by either stage.
        ///
        /// COMPUTED, never stored, because the two stages are genuinely two
        /// places and a stored copy could drift from them. This shape is a
        /// REGRESSION FIX (m23-g2 round 2, found in independent verification):
        /// `clamped` used to be the store's flag alone, which made it
        /// ANCHOR-DEPENDENT — clips at 4 and 12 dragged by -10 with snap off
        /// land at 0 and 8 either way, but grabbing the leftmost reported
        /// `clamped: false` (the gesture floor had already absorbed it) and
        /// grabbing the rightmost reported `true`. Same geometry, same
        /// effective delta, opposite report. A debug echo that answers the same
        /// question two ways poisons every diagnosis made through it — the
        /// ECHO-SEAM LAW, learned at m23-e — and this is the field m23-x's
        /// arrow-key nudge will inherit.
        var clamped: Bool { storeClamped || gestureFlooredAtZero }
        var trimmedIDs: [UUID] = []
        var removedIDs: [UUID] = []
        var refusal: String?
        /// True when the store was actually mutated — the debug seam only waits
        /// on a re-render when there is one to wait for.
        var changed: Bool {
            effectiveDeltaBeats != 0 || !trimmedIDs.isEmpty || !removedIDs.isEmpty
        }
    }

    /// The ONE arrange body-drag handler: the ClipBlock drag gesture and the
    /// `debug.arrangeDrag` seam both land here, so the seam cannot drift from
    /// the gesture. Returns the ACHIEVED anchor start.
    ///
    /// THE GRAB RULE, decided and documented: dragging a clip that IS in the
    /// selection moves the WHOLE selection; dragging one that is NOT selects it
    /// first — collapsing the selection to it — and moves it alone. Without the
    /// second half, a selection left standing from an earlier gesture would
    /// silently drag clips the user is not touching, possibly off-screen. The
    /// collapse routes through `clickClip`, the same handler a plain click uses,
    /// so it also bumps `arrangeKeyFocusNonce` and DELETE still reaches the
    /// arrange after the drag.
    ///
    /// Snap, delta and clamp each have exactly one home: `effectiveClipSnap`
    /// (which grid), `ArrangeGroupDrag.plan` (the rigid delta, anchor-snapped
    /// once, plus the ANCHOR's own beat-0 floor), `ProjectStore.moveClips` (the
    /// WHOLE-GROUP beat-0 clamp and every resulting position). This method only
    /// routes between them — and unions the two reductions into one honest
    /// `clamped`, which neither stage can answer alone.
    @discardableResult
    func dragArrangeClips(anchorClipID: UUID, anchorOriginalStart: Double,
                          rawDragDeltaBeats: Double) -> ArrangeGroupDragOutcome {
        // GRAB RULE — collapse onto the grabbed clip when it is not selected.
        if !arrangeSelection.contains(anchorClipID) {
            clickClip(id: anchorClipID, modifiers: [])
        }
        guard let anchorCurrentStart = liveClip(anchorClipID)?.startBeat else {
            // The anchor vanished under the drag (an undo, an agent's
            // clip.remove). Nothing to translate against — report honestly.
            return ArrangeGroupDragOutcome(anchorStart: anchorOriginalStart)
        }
        let plan = ArrangeGroupDrag.plan(
            anchorOriginalStart: anchorOriginalStart, anchorCurrentStart: anchorCurrentStart,
            rawDragDeltaBeats: rawDragDeltaBeats,
            snap: effectiveClipSnap, meterMap: store.transport.meterMap)
        // Stale ids are a silent skip (the `ArrangeSelection.resolved(in:)`
        // policy) — a clip can vanish under the selection, and that must never
        // reach the store as a thrown refusal at the user.
        let live = Set(store.tracks.flatMap { $0.clips.map(\.id) })
        let targets = arrangeSelection.resolved(in: live)
        guard !targets.isEmpty else {
            return ArrangeGroupDragOutcome(anchorStart: anchorCurrentStart)
        }
        do {
            let result = try store.moveClips(ids: Array(targets), byBeats: plan.deltaBeats)
            return ArrangeGroupDragOutcome(
                anchorStart: liveClip(anchorClipID)?.startBeat ?? anchorCurrentStart,
                movedIDs: result.clips.map(\.id),
                requestedDeltaBeats: result.requestedDeltaBeats,
                effectiveDeltaBeats: result.effectiveDeltaBeats,
                storeClamped: result.clamped,
                gestureFlooredAtZero: plan.flooredAtZero,
                trimmedIDs: result.trimmedClipIDs,
                removedIDs: result.removedClipIDs)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            presentArrangeDragRefusal(error, message: message, clipID: anchorClipID)
            return ArrangeGroupDragOutcome(anchorStart: anchorCurrentStart, refusal: message)
        }
    }

    /// The clip with this id, from whichever track holds it.
    func liveClip(_ id: UUID) -> Clip? {
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) { return clip }
        }
        return nil
    }

    /// A refused drag surfaces the store's message VERBATIM as the amber bubble
    /// (the m17-c/m23-e convention — a silent no-op is what that convention
    /// exists to prevent), but ONLY when the message is new.
    ///
    /// A drag emits one call per pointer event, and `presentArrangeSplitRefusal`
    /// spawns a six-second auto-dismiss `Task` per call. Without this guard,
    /// dragging one take-comp member across the lane would spawn hundreds of
    /// sleeping tasks for a single gesture that shows exactly one bubble.
    private func presentArrangeDragRefusal(_ error: any Error, message: String, clipID: UUID) {
        guard arrangeSplitRefusal?.message != message else { return }
        presentArrangeSplitRefusal(error, clipID: clipID)
    }

    /// True when a text-input surface owns keyboard focus — the m17-d focus
    /// guard, SECOND CONSUMER. Reuses `transportKeyResponder`, the classifier
    /// MEASURED live at m17-d (`NSText` covers the shared field editor behind
    /// every AppKit-backed `TextField`; `NSTextInputClient` catches SwiftUI-native
    /// hosts), so "is the user typing?" has one answer in this app, not two.
    ///
    /// Why the delete handler checks this even though SwiftUI's focused-view-first
    /// ordering should already keep the key inside a focused field: a Backspace
    /// that reaches the arrange while a track/marker rename is open would delete
    /// the user's CLIPS instead of a character. That failure is destructive and
    /// silent, so it gets a guard that does not depend on delivery order.
    var isArrangeTextEditingFocused: Bool {
        let responder = (contentWindow ?? NSApp.keyWindow)?.firstResponder
        return Self.transportKeyResponder(responder) == .textEditing
    }

    /// The DELETE key's arrange handler — ContentView's `.onKeyPress(.delete)`
    /// fallback calls it and reports `.handled` when it returns true.
    ///
    /// It is a FALLBACK by construction: the piano roll and the automation lane
    /// editor own `.onKeyPress(.delete)` on their own surfaces and are
    /// DESCENDANTS of the view that hosts this one, so a focused roll with notes
    /// selected consumes the key and this never runs. Structural, not asserted —
    /// which is why m23-e's note-deletion path cannot regress through here.
    /// Whether a blocking modal is on screen. Every one of these renders as a
    /// centered panel over a scrim in `ContentView`'s `.overlay` chain.
    ///
    /// WHY AN ENUMERATED LIST, when the rest of this guard is structural: scoping
    /// `ArrangeDeleteKey` to the arrange workspace closes the PROPAGATION path
    /// (focus lands in the modal, the modal ignores the key, it bubbles to an
    /// ancestor — the workspace is no longer an ancestor of the overlays). It does
    /// NOT close the RETAINED-FOCUS path: selecting clips bumps
    /// `arrangeKeyFocusNonce`, which asserts focus on the workspace, and opening
    /// an inline `.overlay` does not necessarily move it — so a DELETE pressed
    /// with a modal open can arrive here directly, never having propagated.
    /// That path cannot be observed from the debug seam (it depends on SwiftUI's
    /// focus arbitration, which `debug.arrangeSelection {keyHandler}` bypasses by
    /// construction, and real key delivery does not reach staging). Since the
    /// failure it prevents is SILENT DESTRUCTION of the user's clips behind a
    /// panel they are looking at, it is guarded here, where a gate can see it,
    /// rather than argued to be impossible.
    ///
    /// MAINTENANCE OBLIGATION: a new blocking modal must be added to this list.
    /// `showEngineNotices` is deliberately NOT here — it is a passive bottom
    /// banner, not a scrimmed modal, and it can linger; blocking DELETE under it
    /// would be the usability bug, not the fix.
    var isModalPresented: Bool {
        instrumentPickerTrackID != nil
            || (polySynthEditorTrackID != nil && polySynthEditor.targetIsPolySynth)
            || effectPickerTrackID != nil
            || quantizePanelClipID != nil
            || voiceConvertClipID != nil
            || showExportSheet
            || showUndoHistory
            || showSettings
    }

    func handleArrangeDeleteKey() -> Bool {
        // The Mix console has no clip selection, so DELETE there must be inert.
        // The view already makes this unreachable (`ArrangeDeleteKey` is mounted
        // inside the arrange workspace, which the Mix branch replaces), but this
        // is the half of that scoping a headless gate can OBSERVE.
        guard workspaceMode == .arrange else { return false }
        guard !isModalPresented else { return false }
        guard !isArrangeTextEditingFocused else { return false }
        guard !arrangeSelection.isEmpty else { return false }
        return deleteArrangeSelection()
    }

    // MARK: - Arrow-key nudge (m23-x)

    /// WHICH guard refused a nudge — echoed by the `debug.arrangeSelection
    /// {act:"nudge"}` seam so a CONTROLLED-PAIR gate can prove the guard it is
    /// aiming at is the one that fired. A bare `handled:false` cannot: a leg
    /// that meant to test the text-editing guard would pass identically if the
    /// selection had quietly emptied, which is how a dead handler slips through
    /// a refusal-only test.
    enum ArrangeNudgeRefusal: String {
        case workspace
        case modal
        case textEditing = "text-editing"
        case emptySelection = "empty-selection"
        /// The chord carries ⌘ or ⌃ — not ours, pass it through.
        case chord
        /// The piano roll is open with NOTES SELECTED — the editor owns ← / →.
        /// Named for the note edit, not for focus: focus is explicitly not a
        /// term in the predicate (see `handleArrangeNudgeKey`).
        case pianoRollNoteEdit = "piano-roll-note-edit"
        /// The store refused (a take-comp member); `refusal` carries its words.
        case store
    }

    /// What one arrow press actually did.
    ///
    /// `handled` AND `effectiveDeltaBeats` ARE DIFFERENT QUESTIONS and must
    /// never be conflated in an assertion. `handled` means "the arrange
    /// CONSUMED this key" and drives `.handled` vs `.ignored`; it is TRUE for a
    /// nudge the beat-0 clamp reduced to nothing, deliberately — an arrow that
    /// fell through at the wall would scroll the timeline out from under the
    /// user instead of doing nothing. Whether anything MOVED is
    /// `effectiveDeltaBeats` / `movedIDs`, read from the store's own
    /// `ClipsMoveResult`, never recomputed here.
    ///
    /// TWO OUTCOMES SET `handled: true` WHILE CHANGING NOTHING, and they are the
    /// same rule seen twice: the fully-clamped nudge at the beat-0 wall, and the
    /// `.pianoRollNoteEdit` refusal. Both are states where the user pressed an
    /// arrow and nothing should visibly happen — so the key must be EATEN, or
    /// `TimelineLanesView`'s horizontal `ScrollView` answers it by scrolling the
    /// timeline instead. Every other refusal (`workspace`, `modal`,
    /// `textEditing`, `emptySelection`, `chord`, `store`) genuinely is not ours
    /// and must fall through. If a third `handled: true` refusal ever appears,
    /// check it against that test rather than copying the shape.
    struct ArrangeNudgeOutcome {
        var handled: Bool = false
        var refusedBy: ArrangeNudgeRefusal?
        /// The step the ONE producer (`ArrangeNudge.step`) chose, echoed rather
        /// than recomputed. Nil when a guard refused before it was consulted.
        var stepBeats: Double?
        var stepSource: String?
        /// What the STORE was asked for (`ClipsMoveResult.requestedDeltaBeats`).
        /// Unlike the drag path there is no gesture-side floor on this route, so
        /// this always equals the step's own signed delta and `clamped` is the
        /// whole reduction story — no `gestureFlooredAtZero` twin is needed.
        var requestedDeltaBeats: Double = 0
        var effectiveDeltaBeats: Double = 0
        /// The WHOLE-GROUP beat-0 clamp inside `ProjectStore.moveClips` engaged.
        var clamped: Bool = false
        var movedIDs: [UUID] = []
        var trimmedIDs: [UUID] = []
        var removedIDs: [UUID] = []
        var refusal: String?
        /// True when the store was actually mutated — the debug seam only waits
        /// on a re-render when there is one to wait for.
        var changed: Bool {
            effectiveDeltaBeats != 0 || !trimmedIDs.isEmpty || !removedIDs.isEmpty
        }
    }

    /// The ONE arrow-key nudge handler: `ArrangeDeleteKey`'s `.onKeyPress` and
    /// the `debug.arrangeSelection {act:"nudge"}` seam both land here, so the
    /// seam cannot drift from the key.
    ///
    /// GUARDS MIRROR `handleArrangeDeleteKey` EXACTLY, in the same order and for
    /// the same reasons (read that method and `isModalPresented` for the full
    /// argument; it is not repeated here). One of them carries MORE weight for
    /// arrows than for DELETE: `isArrangeTextEditingFocused`. A Backspace typed
    /// into a rename field is a rare accident; ← and → are pressed inside text
    /// fields constantly, by every user, in every rename — so on this path that
    /// guard is load-bearing rather than defence in depth.
    ///
    /// THE SELECTION IS DELIBERATELY *NOT* CLEARED, which is where this parts
    /// company with delete: you keep nudging the same clips. That is also what
    /// makes the undo coalescing work — `ProjectStore.moveClipsKey(ids:)` is
    /// selection-stable, so a burst of presses on an unchanged selection folds
    /// into ONE journal entry.
    ///
    /// ↑/↓ ARE NOT HANDLED, AND THAT IS A DECISION — see the note at the top of
    /// `ArrangeNudge`: no cross-track move verb exists anywhere in the app, so
    /// a vertical nudge is a new domain verb, not a keyboard layer.
    ///
    /// THE FIFTH GUARD IS NOT IN THE DELETE HANDLER, AND THAT ASYMMETRY IS THE
    /// POINT. `handleArrangeDeleteKey`'s four guards are sufficient partly
    /// because of a STRUCTURAL fact that does NOT transfer to arrows:
    /// `PianoRollView` and `AutomationLaneEditor` each own `.onKeyPress(.delete)`
    /// on their own surfaces and are DESCENDANTS of `ArrangeDeleteKey`, so a
    /// focused editor consumes DELETE and this file never sees it. Nothing
    /// anywhere in the app consumes ← / → — grep: the only arrow `.onKeyPress`
    /// is the one that calls this method — so without a guard here the clip
    /// slides underneath the open editor. Measured on staging before the fix:
    /// roll open and focused, → moved the clip 12 → 16 with `refusedBy: nil`.
    ///
    /// THE PREDICATE IS "ROLL ON SCREEN **AND** NOTES SELECTED". It mirrors what
    /// the roll's OWN delete handler does — `guard !model.selection.isEmpty else
    /// { return .ignored }`, i.e. consume only when there is a note selection,
    /// else fall through and let the arrange act on the clip.
    ///
    /// TWO SIMPLER PREDICATES WERE IMPLEMENTED AND MEASURED WRONG FIRST, which
    /// is why this one looks over-specified. (1) `pianoRollEditorFocused` ALONE
    /// refuses every single-MIDI-clip nudge — the roll self-focuses and opens
    /// for any single selected MIDI clip, so the flag is already true in the
    /// ordinary "clicked one clip" state (measured: 0 → 0 with
    /// `refusedBy` set, and 9 of 46 gate assertions red, every one a CONTROL
    /// half). (2) Focus as an EXTRA term makes the guard INTERMITTENT: the flag
    /// alternates deterministically on clip switches (6 true / 6 false over 12
    /// consecutive selections, editor open on all 12), so the clip would slide
    /// underneath the editor every other time. Measurements:
    /// `PianoRollNoteSelectionBridge`.
    ///
    /// KNOWN, MEASURED CONSEQUENCE — A GROUP NUDGE CAN GO DEAD. `openEditorClip`
    /// stays non-nil when a selection is EXTENDED past one clip, and the roll
    /// does not drop its note selection on a shift-click, so: select a MIDI clip,
    /// select notes in the roll, shift-click two more clips, press → and nothing
    /// happens (measured: `refusedBy: piano-roll-note-edit`, starts 0/8/16
    /// unchanged). The refusal is CORRECT by this predicate — notes really are
    /// selected in an open editor — but the user's intent is plainly the group.
    /// Left as-is deliberately rather than re-cut a third time: the honest fix
    /// is for the roll to drop its note selection when the arrange selection
    /// grows past the clip it is open on, which is the editor's business, not
    /// this handler's. Filed for the roadmap.
    ///
    /// STILL NOT CLOSED, HONESTLY: whether a REAL arrow keypress reaches an
    /// ancestor `.onKeyPress` while a descendant holds `@FocusState` is not
    /// measurable here — the unbundled staging binary does not route real key
    /// events (m23-g1). This guard rests on handler-level certainty plus
    /// SwiftUI's ancestor bubbling, not on an end-to-end measurement.
    ///
    /// THE AUTOMATION LANE EDITOR HAS THE IDENTICAL EXPOSURE AND IS NOT FIXED
    /// HERE: `AutomationLaneEditor` has its own `@FocusState private var
    /// focused` but never reports it to the model, so guarding it needs new
    /// plumbing. Filed as its own roadmap item — do not bolt it on here.
    ///
    /// Snap, step and clamp each have exactly one home: `effectiveClipSnap`
    /// (which grid), `ArrangeNudge.step` (how far), `ProjectStore.moveClips`
    /// (the WHOLE-GROUP beat-0 clamp and every resulting position). This method
    /// only routes between them and reports what they said.
    @discardableResult
    func handleArrangeNudgeKey(direction: ArrangeNudgeDirection,
                               modifiers: TransportKeyModifiers) -> ArrangeNudgeOutcome {
        guard workspaceMode == .arrange else { return ArrangeNudgeOutcome(refusedBy: .workspace) }
        guard !isModalPresented else { return ArrangeNudgeOutcome(refusedBy: .modal) }
        guard !isArrangeTextEditingFocused else {
            return ArrangeNudgeOutcome(refusedBy: .textEditing)
        }
        // THE ROLL WOULD HAVE CONSUMED THIS KEY: it is on screen AND holds a
        // note selection — precisely the test its own `.onKeyPress(.delete)`
        // applies before deciding to consume or fall through.
        //
        // `pianoRollEditorFocused` IS DELIBERATELY NOT A TERM HERE. Both of its
        // plausible readings were implemented and MEASURED to be wrong: alone it
        // refuses every single-MIDI-clip nudge (the roll self-focuses and opens
        // for any single MIDI clip), and as an extra term it makes the guard
        // INTERMITTENT — the flag alternates deterministically on clip switches
        // (measured 6 true / 6 false over 12 consecutive selections, strictly
        // alternating, editor open throughout), so the clip would slide
        // underneath the editor on every other selection. Full measurements:
        // `PianoRollNoteSelectionBridge`.
        // `openEditorClip != nil` IS NOT AN INDEPENDENTLY PROVEN TERM, and is
        // kept knowingly: deleting it reddens NOTHING (mutation, m23-x), because
        // `hasSelection` already implies a mounted roll — the bridge is cleared
        // in `.onDisappear`. It is belt-and-braces against exactly that clear
        // being missed, where a latched `true` would kill the arrow keys for the
        // whole session. Structural, cheap, and not to be mistaken for tested.
        // CONSUMED, NOT PASSED THROUGH — the N6e twin. `handled: true` here
        // while every OTHER refusal returns false, because this is the one
        // refusal whose fall-through has a visible consequence:
        // `TimelineLanesView`'s `ScrollView(.horizontal)` takes an `.ignored`
        // arrow and scrolls the timeline sideways. That would swap the surprise
        // this guard removes (the clip sliding) for a different one (the view
        // sliding), which is exactly the reasoning that already makes a
        // fully-clamped nudge at the beat-0 wall report `handled: true`.
        //
        // It costs the future note-nudge feature nothing: `PianoRollView` is a
        // DESCENDANT of the arrow mount in `ArrangeDeleteKey`, and a descendant's
        // `.onKeyPress` sees the key first — once the roll handles arrows itself
        // it consumes them and this handler never runs.
        guard !(openEditorClip != nil && pianoRollNoteSelection.hasSelection) else {
            return ArrangeNudgeOutcome(handled: true, refusedBy: .pianoRollNoteEdit)
        }
        guard !arrangeSelection.isEmpty else {
            return ArrangeNudgeOutcome(refusedBy: .emptySelection)
        }
        guard let step = ArrangeNudge.step(
            direction: direction, modifiers: modifiers, snap: effectiveClipSnap,
            // A rigid translation has no position, so there is no "bar I am in"
            // to ask about under a meter map (see `ArrangeNudge.step`). Beat 0's
            // meter, read from `transport.meterMap` — the SAME map the drag path
            // and the lanes apply — is the one number that applies to the whole
            // move; taking it from `transport.timeSignature` instead would read
            // a field a `meterMapOverride` can contradict.
            beatsPerBar: store.transport.meterMap.beatsPerBar(atBeat: 0)) else {
            return ArrangeNudgeOutcome(refusedBy: .chord)
        }
        // Stale ids are a silent skip (the `ArrangeSelection.resolved(in:)`
        // policy the drag path uses) — a clip can vanish under the selection
        // via undo or an agent's `clip.remove`, and that must never reach the
        // store as a thrown refusal at the user.
        let live = Set(store.tracks.flatMap { $0.clips.map(\.id) })
        let targets = arrangeSelection.resolved(in: live)
        guard !targets.isEmpty else {
            return ArrangeNudgeOutcome(refusedBy: .emptySelection,
                                       stepBeats: step.magnitudeBeats,
                                       stepSource: step.source.rawValue)
        }
        do {
            let result = try store.moveClips(ids: Array(targets), byBeats: step.deltaBeats)
            return ArrangeNudgeOutcome(
                handled: true,
                stepBeats: step.magnitudeBeats, stepSource: step.source.rawValue,
                requestedDeltaBeats: result.requestedDeltaBeats,
                effectiveDeltaBeats: result.effectiveDeltaBeats,
                clamped: result.clamped,
                movedIDs: result.clips.map(\.id),
                trimmedIDs: result.trimmedClipIDs,
                removedIDs: result.removedClipIDs)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            // The DRAG path's de-duplicating presenter, not the bare one: a HELD
            // arrow repeats, and `presentArrangeSplitRefusal` spawns a six-second
            // auto-dismiss `Task` PER CALL. Without this, holding → on a
            // take-comp member would spawn hundreds of sleeping tasks for one
            // bubble — the exact hazard m23-g2 found on the drag.
            if let clipID = arrangeSelection.focusID ?? targets.first {
                presentArrangeDragRefusal(error, message: message, clipID: clipID)
            }
            return ArrangeNudgeOutcome(
                refusedBy: .store, stepBeats: step.magnitudeBeats,
                stepSource: step.source.rawValue, refusal: message)
        }
    }

    /// Maps SwiftUI's `EventModifiers` (what `KeyPress` carries) onto the
    /// headless `TransportKeyModifiers` the nudge policy speaks — the
    /// `transportKeyModifiers(_:)` twin for the `.onKeyPress` route, which
    /// reports SwiftUI's type rather than `NSEvent.ModifierFlags`. Only the four
    /// chord modifiers; caps lock / numeric pad deliberately do not participate.
    static func keyPressModifiers(_ flags: EventModifiers) -> TransportKeyModifiers {
        var mods: TransportKeyModifiers = []
        if flags.contains(.command) { mods.insert(.command) }
        if flags.contains(.option) { mods.insert(.option) }
        if flags.contains(.control) { mods.insert(.control) }
        if flags.contains(.shift) { mods.insert(.shift) }
        return mods
    }

    /// The clip the piano roll is ACTUALLY open on: `selectedClipID` resolved
    /// against the live store and filtered to MIDI. This is the ONE rule —
    /// `ContentView`'s editor branch renders exactly when this is non-nil, and
    /// the `debug.arrangePointer` echo reports exactly this — so the echo can
    /// never claim an editor that isn't on screen (a stale id after an undo
    /// resolves to nil here, closing the panel and emptying the echo together).
    var openEditorClip: Clip? {
        guard let id = selectedClipID else { return nil }
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == id }), clip.isMIDI {
                return clip
            }
        }
        return nil
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

    /// The in-app Copilot model SETTING (M10-p-6). Like `copilotLimitsStore`
    /// it's an app-side sticky PREFERENCE (never project data) — the
    /// UserDefaults backing persists it under
    /// `AnthropicModelCatalog.userDefaultsKey`. `CopilotEngine` reads its
    /// `effectiveModel` FRESH at the start of each turn's provider
    /// resolution, so a change takes effect on the copilot's next reply — no
    /// restart. A future Settings section will edit it; today it's driven by
    /// the `ai.copilotGetModel`/`ai.copilotSetModel` wire commands.
    let copilotModelStore = CopilotModelStore(backing: UserDefaultsCopilotModelBacking())

    /// The copilot rail's transient presentation state (M10-p-6 UI phase):
    /// per-entry thinking disclosures + the model-picker open flag. Session-only
    /// (never persisted — a reading aid, not a preference), owned here (not
    /// rail-local `@State`) so `debug.copilotSeed` can stage every visual state
    /// for captures/E2E — the `explain`/`voicePanel` staging precedent.
    let copilotRailUI = CopilotRailUIModel()

    /// Explain-mode state (M8 ex-a): the transient violet "?" EXPLAIN overlay's
    /// on/off flag + an optional capture focus. Owned here (like `panelDensity`) so
    /// the `debug.explainMode` staging command can drive it. NOT persisted — unlike
    /// density, explain mode is a per-session aid, off by default.
    let explain = ExplainModel()

    /// The explain overlay's presentation coordinator — the ONE home for every
    /// `.explainable` control's measured frame (id → one rect per rendered
    /// instance, in the `explainRoot` coordinate space). Hoisted out of
    /// `ContentView`'s `@State` (the `arrangeHScroll` / `selectedClipID` idiom) so
    /// the `debug.explainFrames` staging command reads the SAME frames the live
    /// overlay anchors on — a gate that asserts a control's measured Y must read
    /// the window's own geometry, never a second computation of it.
    let explainCoordinator = ExplainCoordinator()

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

    /// A synthetic goniometer frame + stereo-scalar override the master strip's
    /// stereo-image block prefers over the live polls (m22-d). nil in normal use
    /// (the block reads `store.masterScopeFrame()` / `store.masterAnalysis()`);
    /// the debug-tier `debug.scopeSeed` command sets it so a capture / E2E can
    /// stage a deterministic figure (mono line, anti-phase line, decorrelated
    /// cloud, hard-pan diagonal) without real audio. The ENGINE is never touched
    /// by seeding — a view-side override, the `debug.vibeSeed` precedent.
    var scopeSeed: StereoScopeSeed?

    /// ── THE LIVE-LAYER TICK WITNESS (m23-r3b) ────────────────────────────
    ///
    /// Every continuously-redrawing layer reports the values it drew, once per
    /// frame, into this one object; `debug.liveLayers` publishes them. It
    /// exists because the m22-e poll-discipline law's failure mode is INVISIBLE
    /// to every other probe in the app: a layer that froze because it was
    /// paused on window-inactive is pixel-identical to a live one until the
    /// data moves, and neither the goniometer trail nor the mono-safety
    /// readouts keep any smoothed state a probe could read (the trick m23-r3
    /// used on `EQCurveEditorModel.spectrumHeights` does not generalize).
    ///
    /// `@ObservationIgnored` is REQUIRED, not tidiness: these fields are
    /// written from inside `TimelineView` closures during view updates, so an
    /// observed property would schedule an invalidation per frame on every
    /// meter in the app (and trip "Modifying state during view update"). The
    /// `VibeSmoother` / `EQSpectrumClock` scratch-object pattern.
    @ObservationIgnored let liveLayers = LiveLayerWitness()

    /// ── THE INSERT-ROW LABEL WITNESS (m23-s) ─────────────────────────────
    ///
    /// Every rendered `InsertRow` reports the name it DREW — the string, the
    /// `.fixedSize` pin flag, the drawn frame, the string's single-line ideal
    /// width, the name line's width — plus every gain-reduction underline frame.
    /// `debug.insertLabels` publishes them.
    ///
    /// It exists because m23-s was filed from a pixel-reviewed capture: nothing
    /// in this app reported a drawn insert label, so "a control label never
    /// truncates" was a rule no assertion could reach.
    ///
    /// `@ObservationIgnored` is REQUIRED, not tidiness (the `liveLayers` note
    /// above): these fields are written from inside `GeometryReader` and
    /// `TimelineView` closures during view updates, so an observed property
    /// would schedule an invalidation per layout pass on every insert row.
    @ObservationIgnored let insertLabels = InsertLabelWitness()

    /// A synthetic gain-reduction reading the GR meters (the dynamics editor
    /// cards' GAIN REDUCTION block + the insert chips' mini-bar, m22-e) prefer
    /// over the live store polls. nil in normal use (the meters read
    /// `store.effectGainReductionDb` / `masterEffectGainReductionDb`); the
    /// debug-tier `debug.grSeed` command sets it so a headless capture / E2E
    /// shows a working meter deterministically. The ENGINE is never touched by
    /// seeding — a view-side override, the `debug.scopeSeed` precedent.
    var grSeed: GainReductionSeed?

    /// One GR poll for the meters (m22-e): the `debug.grSeed` override when it
    /// applies to this insert (blanket or id-targeted), else the live phase-1
    /// store tap (`trackID` nil = the MASTER chain). nil = not reporting —
    /// the meters show nothing fabricated.
    func gainReductionDb(trackID: UUID?, effectID: UUID) -> Double? {
        if let seeded = grSeed?.value(forEffect: effectID) { return seeded }
        if let trackID {
            return store.effectGainReductionDb(trackID: trackID, effectID: effectID)
        }
        return store.masterEffectGainReductionDb(effectID: effectID)
    }

    // MARK: - Per-insert spectrum (m23-r3)

    /// A synthetic per-insert spectrum the open TRACK EQ card's spectrum layer
    /// prefers over the live `store.insertAnalysis` poll. nil in normal use;
    /// the debug-tier `debug.insertSpectrumSeed` command sets it so a headless
    /// capture / E2E gets a deterministic silhouette without real audio (the
    /// `debug.vibeSeed` precedent — which stays the MASTER card's override, so
    /// the two surfaces are staged independently). The ENGINE is never touched
    /// by seeding, and because seeding bypasses `store.insertAnalysis`
    /// entirely, an UNSEEDED reading is honest evidence that the live tap ticks.
    var insertSpectrumSeed: MasterAnalysisSnapshot?

    /// ── THE SINGLE-CONSUMER INVARIANT (m23-r3, constraint c) ──────────────
    ///
    /// `store.insertAnalysis` DRAINS the tap's ring (`InsertSpectrumTap
    /// .drainAndSnapshot` advances `readIndex`), and when zero frames are
    /// available it hands back the analyzer's PREVIOUS snapshot rather than a
    /// floor — so a second consumer does not surface as a dead meter or an
    /// error, it surfaces as a plausible STALE one that nothing anywhere
    /// reports. Exactly one consumer per armed insert, therefore, is a
    /// correctness requirement and not a performance note.
    ///
    /// The UI keeps that invariant STRUCTURALLY, three ways:
    ///
    /// 1. **One slot.** These two properties are the only UI-side arm. At most
    ///    ONE insert is armed by the UI at any instant, and the one view that
    ///    owns it (`EQSpectrumLayer`, whose `.task(id:)` calls `holdInsertSpectrum`)
    ///    is the only thing that polls it. Layer exists ⟺ armed ⟺ polled.
    /// 2. **A generation token, because `.task(id:)` cancellation is NOT
    ///    ordered before the next task's start.** On a target change SwiftUI
    ///    cancels the old task and starts the new one without awaiting the
    ///    cancellation, so an old A-task's release can land AFTER a new A-task
    ///    has re-armed A (arm A → B → back to A). A release therefore only bites
    ///    when it still holds the CURRENT token; a stale one is a no-op. Both
    ///    interleavings then end with exactly A armed.
    /// 3. **Arming a new target releases the old one first**, so the slot can
    ///    never leak an arm when the release loses the race.
    ///
    /// A NON-UI consumer (m23-r4's wire path) must take its OWN arm and must
    /// never poll an insert this slot holds: the engine's cap is 8 armed taps
    /// and REFUSES rather than evicts, so a second arm is cheap — a second
    /// POLL of the same insert is the bug.
    private var insertSpectrumArmedTarget: EffectEditorTarget?
    private var insertSpectrumArmToken = 0

    /// True while the OPEN card's spectrum layer is genuinely measuring: a
    /// master card always (`masterAnalysis()` is unconditional), a track card
    /// only while its per-insert tap is armed. Drives the card's help fork, so
    /// a REFUSED arm (engine cap full, insert gone, headless) never has the
    /// tooltip promising a live reading over a floor silhouette.
    var effectEditorSpectrumIsMeasuring: Bool {
        guard let target = effectEditorTarget else { return false }
        guard target.trackID != nil else { return true }
        return insertSpectrumArmedTarget == target
    }

    /// The open EQ card's `.help` caption — resolved ONCE, here, and handed to
    /// the plot as a plain String. `debug.effectEditor` reports THIS property,
    /// so the gate reads the very value the card draws rather than a parallel
    /// re-derivation of it: a tooltip is invisible to `debug.captureUI`, and
    /// the pre-fader / post-fader distinction is too load-bearing to be pinned
    /// only as a function nobody can prove is wired up (m23-r3).
    var effectEditorCurveHelp: String {
        EQCurveEditorModel.curveHelp(for: effectEditorTarget,
                                     isMeasuring: effectEditorSpectrumIsMeasuring)
    }

    /// The open card's HONESTY DISCLOSURE (m23-p2) — the drawn admission an
    /// effect owes when its benefit is phrased as revelation and its mechanism
    /// is synthesis. nil for every kind that has no such gap.
    ///
    /// Resolved ONCE, here, and handed to the card as a plain value — the
    /// `effectEditorCurveHelp` precedent, for the same reason: `debug
    /// .effectEditor` reports THIS property, so a gate reads the very value the
    /// card draws instead of a parallel re-derivation that happens to agree.
    /// Every wording decision lives in `DAWAppKit.EffectHonestyNote`, which has
    /// a test target; this line is a call, not a rule.
    var effectEditorHonestyNote: EffectHonestyNote? {
        EffectHonestyNote.note(for: effectEditor.kind)
    }

    /// The open EQ card's INSTRUMENT FREQUENCY GUIDE (m23-o2) — m23-o1's cited
    /// reference table, resolved for the card's own track.
    ///
    /// Resolved ONCE, here, and handed to the card as a plain value — the
    /// `effectEditorCurveHelp` precedent, for the same reason: `debug
    /// .effectEditor` reports THIS property, so the gate reads the very value
    /// the card draws rather than a parallel re-derivation that happens to
    /// agree (the m23-r2a hand-assignment hole).
    ///
    /// Every decision inside it lives in `DAWAppKit.EQInstrumentGuide`, which
    /// has a test target; this line is a call, not a rule. In particular the
    /// FAMILY comes from `InstrumentFamilyResolver` — DAWCore's one home — and
    /// there is no name heuristic anywhere on this path.
    var effectEditorInstrumentGuide: EQInstrumentGuide {
        EQInstrumentGuide.resolve(target: effectEditorTarget, tracks: store.tracks)
    }

    /// The guidance plot's MEASURED width, reported by `EQCurveEditor` from its
    /// own `GeometryReader` (`onPlotWidth`). nil until the card has laid out.
    ///
    /// ⚠️ THE PROBE MUST REPORT WHAT WAS DRAWN, NOT WHAT WAS INTENDED. Deriving
    /// `debug.effectEditor`'s x positions from `EQGuidanceLayout.contentWidth`
    /// while the Canvas draws from `size.width` makes the two agree only because
    /// the card is a fixed 560 pt frame — and since `DAWApp` has NO test target,
    /// a staging gate is the only instrument that can see this path at all. A
    /// gate checking "x is consistent with the width the probe names" would then
    /// be self-consistent and blind, certifying a card that had drifted to a
    /// different frame. Reported provenance (`widthSource`) makes the fallback
    /// assertable instead of invisible.
    ///
    /// Cleared when the editor closes so a stale width can never be reported
    /// against a freshly opened card.
    var effectEditorPlotWidth: Double?

    /// The open card's MEASURED height (m23-p2), reported by
    /// `EffectEditorOverlay` from its own `GeometryReader`. nil until the card
    /// has laid out, and cleared on close.
    ///
    /// It exists because m23-p2 grew this card: the honesty disclosure is the
    /// first thing on it whose height is a function of PROSE, and the card is
    /// a modal with no scroll of its own, so a longer future disclosure is a
    /// card that outgrows `WindowFloor.minHeight`. `debug.effectEditor` reports
    /// this number so a gate can assert the fit instead of a human squinting at
    /// a screenshot — and it reports what was DRAWN, never `sectionsHeight`,
    /// which is arithmetic over layout constants and cannot see a block that
    /// wraps (the m23-o2 widthSource lesson: a probe deriving its answer from
    /// the same constants the view ignores is self-consistent and blind).
    var effectEditorCardHeight: Double?

    /// The open card's MEASURED width (m23-p2), from the same `GeometryReader`.
    ///
    /// The card is a FLOATING modal — it is not constrained by the mixer
    /// strip's width budget, and it takes two different widths (the 340 pt
    /// house strip, or the wider curve card when an EQ plot shows). Every
    /// line-count assumption behind the disclosure's fit is a claim about this
    /// number, so the gate asserts the width the card was DRAWN at rather than
    /// restating a constant from the view.
    var effectEditorCardWidth: Double?

    /// The FACE and INK the open disclosure actually drew, per role, reported
    /// by `EffectEditorOverlay.honestyText` from the same parameters its `Text`
    /// modifiers consume (m23-p2, review round).
    ///
    /// Four claims in the design language ride on this block's ink — never SF
    /// Mono, never violet, never amber, never dimmer than the knob labels — and
    /// before this dictionary existed every one of them was enforced by nothing
    /// but a doc comment. The reviewer's mutation proved it: the prose redrawn
    /// in `DAWTheme.ai` (violet = AI-authored content in this app, so a
    /// disclosure ABOUT synthesis would have been claiming the disclosure
    /// itself was synthesized) left the gate 42/42 green.
    ///
    /// Values are resolved sRGB hex from `DAWTheme.hexString`, never token
    /// names: a probe echoing the token it INTENDED agrees with itself while
    /// the view draws something else.
    ///
    /// A plain `final class`, NOT an observed property, and that is load
    /// bearing: the card reports from inside its own modifier arguments —
    /// during `body` evaluation — which is what makes the report inseparable
    /// from the draw. A tracked write at that moment would invalidate the view
    /// that just made it. Nothing here drives rendering; it is read only by the
    /// probe.
    let effectEditorHonestyStyle = EffectEditorOverlay.EffectHonestyStyleLedger()

    /// Where the piano-roll bar-ops readout's DRAWN text and ink land (m23-t) —
    /// the `effectEditorHonestyStyle` shape, for the same reason and with the
    /// same non-observable discipline: the roll's header reports from inside its
    /// own `Text`/`.foregroundStyle` arguments, during `body`. Read only by
    /// `debug.pianoRollBarOps`.
    let pianoRollBarOpsStyle = PianoRollView.BarOpsStyleLedger()

    /// Maps the guide's transport enum onto the wire's `JSONValue`. DAWAppKit
    /// must not depend on `DAWControl`, so the value crosses as
    /// `EQInstrumentGuide.ProbeValue` and is widened here. Deliberately a bare
    /// five-case switch with no logic: anything smarter than this belongs in
    /// the module that has tests.
    static func guideProbeJSON(_ value: EQInstrumentGuide.ProbeValue) -> JSONValue {
        switch value {
        case .string(let text): return .string(text)
        case .strings(let list): return .array(list.map { JSONValue.string($0) })
        case .number(let number): return .number(number)
        case .numbers(let list): return .array(list.map { JSONValue.number($0) })
        case .bool(let flag): return .bool(flag)
        }
    }

    /// The spectrum layer's lifecycle hold — the body of its `.task(id:)`.
    /// Arms the open card's insert on entry, holds until SwiftUI cancels the
    /// task (target change, card close, density flip to the knob table, window
    /// teardown), then releases. A MASTER card arms nothing and holds nothing:
    /// `masterAnalysis()` needs no tap.
    ///
    /// The layer keys its `.task` on `EffectEditorModel.target` while this body
    /// reads `effectEditorTarget` — two properties, and the task would arm the
    /// WRONG insert if they could ever disagree when it runs. They cannot:
    /// `openEffectEditor` sets both (`effectEditor.prepare` then the app-model
    /// target) in ONE synchronous @MainActor body, as does `closeEffectEditor`,
    /// and SwiftUI cannot render — so cannot start a task — between two
    /// statements of a main-actor function. Keep them adjacent; splitting an
    /// `await` between them is what would break this.
    @MainActor
    func holdInsertSpectrum() async {
        guard let target = effectEditorTarget, target.trackID != nil else { return }
        let token = armInsertSpectrum(target)
        defer { releaseInsertSpectrum(token: token) }
        // Hold until cancelled — the sleep throws on cancellation, so the loop
        // falls out and `defer` releases (the SketchpadView/VoicePanel poll-hold
        // idiom). The interval is a liveness backstop only; nothing is polled
        // here (the layer's TimelineView does the polling).
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(60))
        }
    }

    /// Takes the single UI arm slot for `target`, releasing whatever it held.
    /// Returns the generation token the matching `releaseInsertSpectrum` must
    /// present. A REFUSED arm still consumes a token (so the release path stays
    /// symmetric) but leaves the slot empty — the card then draws the honest
    /// floor and `effectEditorSpectrumIsMeasuring` reads false.
    @discardableResult
    private func armInsertSpectrum(_ target: EffectEditorTarget) -> Int {
        if let held = insertSpectrumArmedTarget, held != target {
            store.setInsertAnalysisArmed(trackID: held.trackID,
                                         effectID: held.effectID, armed: false, owner: .ui)
            insertSpectrumArmedTarget = nil
        }
        insertSpectrumArmToken += 1
        // m23-r4: the store's owner set means this call can never stomp a
        // wire lease (`fx.spectrum`'s `.control` owner) on the same insert.
        let outcome = store.setInsertAnalysisArmed(trackID: target.trackID,
                                                    effectID: target.effectID,
                                                    armed: true, owner: .ui)
        insertSpectrumArmedTarget = (outcome == .armed) ? target : nil
        return insertSpectrumArmToken
    }

    /// Releases the arm slot IF it is still the one `token` took. A stale token
    /// (a cancelled task resuming after a newer task already re-armed) is a
    /// no-op — see the invariant note above.
    private func releaseInsertSpectrum(token: Int) {
        guard token == insertSpectrumArmToken else { return }
        if let held = insertSpectrumArmedTarget {
            store.setInsertAnalysisArmed(trackID: held.trackID,
                                         effectID: held.effectID, armed: false, owner: .ui)
        }
        insertSpectrumArmedTarget = nil
    }

    /// Which reading the open EQ card's spectrum layer is drawing. Reported by
    /// `debug.effectEditor` — and the SAME value `effectEditorSpectrum()`
    /// switches on, so the label can never describe a branch the poll does not
    /// take.
    enum SpectrumSource: String {
        /// No card open — nothing polls.
        case none
        /// The live whole-mix reading, POST master fader.
        case master
        /// `debug.vibeSeed`'s staged master snapshot.
        case masterSeed
        /// This insert's live tap, POST the insert and PRE the strip fader.
        case insert
        /// `debug.insertSpectrumSeed`'s staged per-insert snapshot.
        case insertSeed
    }

    var effectEditorSpectrumSource: SpectrumSource {
        guard let target = effectEditorTarget else { return .none }
        guard target.trackID != nil else { return vibeSeed != nil ? .masterSeed : .master }
        return insertSpectrumSeed != nil ? .insertSeed : .insert
    }

    /// ONE spectrum poll for the open EQ card's layer, resolved against the
    /// card's CURRENT target each tick (the `gainReductionDb` idiom):
    ///
    /// - MASTER target → `vibeSeed ?? store.masterAnalysis()`, byte-identical
    ///   to m22-b. That curve is measured POST-fader, over the whole mix.
    /// - TRACK target → `insertSpectrumSeed ?? store.insertAnalysis(...)`,
    ///   the spectrum POST this insert and PRE the strip fader.
    ///
    /// `insertAnalysis` returns nil for "not armed" and `.floor` for "armed but
    /// silent, or still warming (< ~2048 frames)" — a deliberate engine
    /// distinction, because a floor snapshot on an UNARMED tap would read like
    /// a live, silent meter. The DRAWN layer has no third thing to draw, so it
    /// collapses both to a floor silhouette; the distinction is carried instead
    /// by `effectEditorSpectrumIsMeasuring`, which forks the card's help text
    /// and backs `debug.effectEditor`'s `spectrumArmed` field.
    func effectEditorSpectrum() -> MasterAnalysisSnapshot {
        switch effectEditorSpectrumSource {
        case .none, .master:
            return store.masterAnalysis()
        case .masterSeed:
            return vibeSeed ?? store.masterAnalysis()
        case .insertSeed:
            return insertSpectrumSeed ?? .floor
        case .insert:
            guard let target = effectEditorTarget, let trackID = target.trackID
            else { return .floor }
            return store.insertAnalysis(trackID: trackID,
                                        effectID: target.effectID) ?? .floor
        }
    }

    /// A synthetic reference slot / monitor status / mix-side evidence the
    /// master strip's REFERENCE row and the REFERENCE panel prefer over the
    /// live store polls (m22-g P3). nil in normal use; the debug-tier
    /// `debug.referenceSeed` command sets it so a headless capture / E2E can
    /// stage every §7.1/§7.2 state deterministically. The STORE and the ENGINE
    /// are never touched by seeding — a view-side override, the
    /// `debug.scopeSeed` / `debug.grSeed` precedent. Because seeding writes no
    /// project data, an UNSEEDED capture is honest evidence that the live polls
    /// are ticking.
    var referenceSeed: ReferenceSeed?

    /// The REFERENCE panel's headless model (m22-g P3) — created in `init`
    /// against the store's `reference.*` methods, the SAME ones the wire's
    /// `reference.*` commands call (UI == wire by construction), with every
    /// READ routed through the seed override first.
    let referencePanel: ReferencePanelModel

    /// The slot the master strip's REFERENCE row gates on: the staged slot when
    /// seeding, else the project's own. nil = no row at all (zero cost for a
    /// project without a reference).
    var referenceRowSlot: ReferenceSlot? {
        if let referenceSeed { return referenceSeed.slot }
        return store.reference
    }

    /// The panel's status read: the staged status when seeding, else the
    /// store's own (which computes the `wouldMatchGainDb` preview through the
    /// exact `ReferenceLevelMatch` law).
    func referenceStatusForUI() -> ReferenceStatus {
        if let referenceSeed { return referenceSeed.status }
        return store.referenceStatus()
    }

    /// The panel's comparison read. Seeded mix evidence wins; otherwise the
    /// live polls — `liveLoudness()` for loudness/true-peak/range and the
    /// `vibeSeed ?? masterAnalysis()` spectrum closure the EQ card already uses
    /// (ContentView.swift's `spectrum:` argument), so one spectrum override
    /// serves both surfaces. nil whenever there is no reference analysis to
    /// compare against — the panel then shows honest dashes, never a floor.
    func referenceCompareForUI() -> ReferenceCompareResult? {
        let slot = referenceSeed?.slot ?? store.reference
        guard let analysis = slot?.analysis else { return nil }
        let live: LiveLoudnessSnapshot
        if let seeded = referenceSeed?.mixLive {
            live = seeded
        } else if referenceSeed != nil {
            // A seed with no staged mix evidence stages the honest
            // no-live-reading case (every loudness delta reads "—").
            live = .empty
        } else if let polled = try? store.liveLoudness() {
            live = polled
        } else {
            live = .empty
        }
        let master = referenceSeed?.mixAnalysis ?? vibeSeed ?? store.masterAnalysis()
        return ReferenceCompareResult.assemble(live: live, master: master, analysis: analysis)
    }

    /// Opens the REFERENCE panel (the master strip's row, and
    /// `debug.referenceSeed {panel: true}`).
    func openReferencePanel() {
        withAnimation(.easeOut(duration: 0.15)) { referencePanel.open() }
    }

    func closeReferencePanel() {
        withAnimation(.easeOut(duration: 0.15)) { referencePanel.close() }
    }

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
        // The lock URL is a Sendable value, so the lock removal needs no
        // actor hop; the clean-quit autosave DOES touch the store, and the
        // `.main` queue guarantees the main thread, so `assumeIsolated` is
        // sound (the store itself is Sendable via its @MainActor isolation).
        let lockURL = store.crashLockURL
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak store] _ in
            // Clean-quit autosave (chat-persist §4.4), BEFORE the lock goes:
            // a titled session saves in place, an untitled one writes its
            // recovery bundle — so an edit or a copilot conversation
            // finished seconds before quit is never lost (previously only
            // the crash path would have covered it).
            MainActor.assumeIsolated {
                // m23-d: release any held audition FIRST — after this the main
                // actor stops being able to send note-offs, and the render side's
                // 3 s watchdog would be the only thing left between a held key
                // and a note ringing through teardown.
                store?.stopAllAudition()
                store?.autosaveIfNeeded()
            }
            try? FileManager.default.removeItem(at: lockURL)
        }

        // One song generator + sidecar manager, shared with the router so the
        // panel's own generate/import and the `ai.*` wire path never diverge on
        // job state or audio caching.
        let songGenerator = ACEStepClient()
        let sidecarManager = SidecarManager()
        self.songGenerator = songGenerator
        self.sidecarManager = sidecarManager

        // The SECOND local sidecar (m10-p-5): one RVC voice-conversion manager
        // + one typed client, shared with the router below (the
        // sidecarManager/songGenerator precedent) so the Voice panel's Start
        // button and the wire's vc.sidecarStart track the SAME boot, and the
        // panel's convert/train ride the SAME client the vc.* commands use.
        let voiceConversionManager = VoiceConversionManager()
        let voiceConversionClient = VoiceConversionClient()
        self.voiceConversionManager = voiceConversionManager
        self.voiceConversionClient = voiceConversionClient

        // The Voice panel model (m10-p-5): datasets under app support
        // (recordings are app-side data; trained MODELS stay facade-owned in
        // scripts/rvc/runtime/voices/ — never duplicated here), sidecar
        // status/start through the shared manager, voices/train/convert
        // through the shared client, and the clip-source + import seams
        // through the SAME two store methods the wire's vc.convertVocals
        // calls (`voiceConversionSource` / `importConvertedVoice`) — the
        // m10-n-3 "one command surface" law.
        self.voicePanel = VoicePanelModel(
            datasetsRoot: VoicePanelModel.defaultDatasetsRoot(),
            sidecarStatus: { [voiceConversionManager] in await voiceConversionManager.status() },
            startSidecar: { [voiceConversionManager] in try await voiceConversionManager.start() },
            // The SAME composed list the wire's vc.listVoices serves
            // (availableVoiceTargets: the reserved "base" smoke target from
            // its own status endpoint + the real-voices-only list) — UI and
            // wire can never diverge on what's convertible.
            voices: { [voiceConversionClient] in try await voiceConversionClient.availableVoiceTargets() },
            train: { [voiceConversionClient] in try await voiceConversionClient.train($0) },
            convert: { [voiceConversionClient] in try await voiceConversionClient.convert($0) },
            clipSource: { [weak store] clipID in
                guard let store else { throw DebugError("project store unavailable") }
                return try store.voiceConversionSource(clipId: clipID)
            },
            importConverted: { [weak store] url, trackName, atBeat in
                guard let store else { throw DebugError("project store unavailable") }
                return try store.importConvertedVoice(
                    fileURL: url, trackName: trackName, atBeat: atBeat)
            })

        // The REFERENCE panel model (m22-g P3). Constructed bare here (its
        // providers close over `self`, which is not whole yet) and wired at the
        // tail of `init` by `wireReferencePanel()`.
        self.referencePanel = ReferencePanelModel()

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
            },
            // m22-f: the synced delay card's derived-time readout — tempo at
            // the playhead, the same per-position rule the engine's control-
            // plane resolve applies.
            tempoBPM: { [weak store] in
                guard let store else { return 120 }
                return store.transport.tempoMap.bpm(atBeat: store.transport.positionBeats)
            })

        // The Poly Synth editor model: reads the LIVE resolved descriptor (nil
        // instrument on an instrument track = `.default`, which IS the poly
        // synth) so a wire `track.setInstrument` moves the open card's knobs,
        // and applies every edit through the SAME `setInstrument`
        // partial-update the wire calls — one field per knob tick, coalesced
        // per-track ("Change Instrument") so a drag is ONE undo step.
        self.polySynthEditor = PolySynthEditorModel(
            descriptor: { [weak store] trackID in
                guard let track = store?.tracks.first(where: { $0.id == trackID }),
                      track.kind == .instrument else { return nil }
                return track.instrument ?? .default
            },
            apply: { [weak store] trackID, name, value in
                guard let store else { throw DebugError("project store unavailable") }
                _ = try store.setInstrument(
                    id: trackID,
                    attack: name == "attack" ? value : nil,
                    decay: name == "decay" ? value : nil,
                    sustain: name == "sustain" ? value : nil,
                    release: name == "release" ? value : nil,
                    cutoffHz: name == "cutoffHz" ? value : nil,
                    resonance: name == "resonance" ? value : nil,
                    gain: name == "gain" ? value : nil)
            },
            setWaveform: { [weak store] trackID, waveform in
                guard let store else { throw DebugError("project store unavailable") }
                _ = try store.setInstrument(id: trackID, waveform: waveform)
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

        // The Export dialog model (m23-m3). Stateless to construct — it takes
        // its track list as a VALUE snapshot at open time (`prepare(tracks:)`)
        // and drives the store only through the export call it is handed, so it
        // previews and unit-tests without a store at all.
        self.exportDialog = ExportDialogModel()

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
            // The RVC sidecar's manager + client, SHARED with the Voice panel
            // (m10-p-5) so vc.* wire calls and the panel see one truth.
            voiceConversionManager: voiceConversionManager,
            voiceConverting: voiceConversionClient,
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
            maxToolRounds: { [copilotLimitsStore] in copilotLimitsStore.maxRounds },
            // M10-p-6: same fresh-read-per-turn pattern as maxToolRounds,
            // for the persisted model setting. `modelSetter` discards
            // `commit`'s returned id — `ai.copilotSetModel` already
            // validated against `AnthropicModelCatalog.curated` before ever
            // calling `copilotEngine.setModel`, so this call can't fail.
            modelResolver: { [copilotModelStore] in copilotModelStore.effectiveModel },
            modelSetter: { [copilotModelStore] modelID in copilotModelStore.commit(modelID) })
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
        wireReferencePanel()
        installDebugCommands()
        // Space-bar transport toggle (m17-d): the app-wide key monitor. Last —
        // it reads store state only through the toggle funnel, no init order
        // dependency, but keeping bootstrap side effects at the tail is house style.
        installSpaceKeyMonitor()
    }

    /// Binds the REFERENCE panel model to the store (m22-g P3). Every READ goes
    /// through the seed override first (the `scopeSeed` idiom) and every ACTION
    /// routes to the SAME `ProjectStore` method the matching `reference.*` wire
    /// command calls — so a reference imported from the panel and one imported
    /// by an agent are byte-identical, and the panel adds ZERO wire surface (the
    /// m10-c/m22-b pure-view precedent).
    private func wireReferencePanel() {
        referencePanel.slotProvider = { [weak self] in self?.referenceRowSlot }
        referencePanel.statusProvider = { [weak self] in
            self?.referenceStatusForUI() ?? ReferenceStatus()
        }
        referencePanel.compareProvider = { [weak self] in self?.referenceCompareForUI() }
        referencePanel.fileExists = { [weak self] path in
            // A STAGED slot is a view-side fiction whose path names nothing on
            // disk, so while one is seeded the seed's own `fileMissing` flag is
            // the whole truth — probing the filesystem there would report every
            // seeded capture as a missing file (caught by the m22-g P3 gate's
            // C2 leg, which staged "loaded + monitoring" and got fileMissing).
            if let seed = self?.referenceSeed, seed.slot != nil {
                return !seed.fileMissing
            }
            return FileManager.default.fileExists(atPath: path)
        }
        referencePanel.importAction = { [weak self] path in
            guard let self else { return }
            try await self.store.importReference(path: path)
        }
        referencePanel.analyzeAction = { [weak self] in
            guard let self else { return }
            _ = try await self.store.analyzeReference()
        }
        referencePanel.removeAction = { [weak self] in
            guard let self else { return }
            _ = try self.store.removeReference()
        }
        referencePanel.monitorAction = { [weak self] on in
            guard let self else { return }
            _ = try self.store.setReferenceMonitor(on: on)
        }
        referencePanel.offsetAction = { [weak self] seconds in
            guard let self else { return }
            _ = try self.store.setReferenceOffset(seconds: seconds)
        }
        referencePanel.trimAction = { [weak self] db in
            guard let self else { return }
            _ = try self.store.setReferenceTrim(db: db)
        }
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

    /// Opens the Export dialog — the entry point behind the transport EXPORT
    /// button and the onboarding `export` step (ob-b).
    ///
    /// Before m23-m3 this ran a bare `NSSavePanel` hardcoded to `.wav` straight
    /// into `store.renderBounce(toPath:)` with every format parameter defaulted.
    /// The save panel now comes AFTER the settings (`runExportFromDialog`), which
    /// is also what lets it offer the chosen file type. Completion still flows
    /// through the store's `renderCompletedCount` — the onboarding adapter fires
    /// `renderCompleted` on the increment, so there is ONE path and no direct
    /// tour-signal emission here.
    func exportSong() {
        openExportSheet()
    }

    /// Opens (or re-opens) the Export dialog. Refreshes its track snapshot from
    /// the live store and drops the previous run's result; the FORMAT and
    /// normalization choices survive, because a second export in one session
    /// almost always wants the first one's settings.
    func openExportSheet() {
        // Whole `Track` VALUES (m23-m3c): the dialog's stems preview plans
        // through `StemPlan`, which reads each track's routing and kind to work
        // out which tracks are master inputs. The checkbox rows' reduced view is
        // derived inside `prepare`.
        exportDialog.prepare(tracks: store.tracks)
        withAnimation(.easeOut(duration: 0.15)) { showExportSheet = true }
    }

    func closeExportSheet() {
        withAnimation(.easeOut(duration: 0.15)) { showExportSheet = false }
    }

    /// The dialog's EXPORT button: pick a destination, then run the bounce the
    /// dialog describes.
    ///
    /// The panel's file type and default name come from the model's
    /// `DeliveryFormat` — never a literal `.wav` — because the extension is what
    /// actually selects the container (m23-m2). The user can still type any name
    /// they like; `DeliveryFormat.applyingExtension` then APPENDS the canonical
    /// extension rather than clobbering theirs, so an AIFF export saved as
    /// "mix.wav" lands as "mix.wav.aiff" — ugly, but never a file whose bytes
    /// disagree with its name.
    ///
    /// The render itself goes through `ExportDialogModel.export` — the SAME
    /// method `debug.exportDialog {exportToPath}` and the suites call, so the
    /// button cannot drift from what the gate measures.
    ///
    /// The dialog's ONE button, dispatched on the mode (m23-m3c): the two modes
    /// need different terminal steps — a save panel for the single bounce file,
    /// a folder chooser for the stems SET — and this is the only place that
    /// choice is made, so the button can never open the panel for the mode the
    /// model is not in.
    func runExportFromDialog() {
        switch exportDialog.mode {
        case .bounce: runBounceExportFromDialog()
        case .stems: runStemExportFromDialog()
        }
    }

    private func runBounceExportFromDialog() {
        let format = exportDialog.format
        let panel = NSSavePanel()
        panel.title = "Export Song"
        panel.prompt = "Export"
        panel.nameFieldStringValue = exportDialog.suggestedFileName(
            projectName: store.projectName)
        if let type = UTType(filenameExtension: format.fileExtension) {
            panel.allowedContentTypes = [type]
        }
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            _ = await self.exportDialog.export(store: self.store, toPath: url.path)
        }
    }

    /// The dialog's EXPORT button in STEMS mode (m23-m3c): pick a FOLDER, then
    /// write the set the preview promised.
    ///
    /// A different terminal step, not a different dialog — `renderStems` writes
    /// a SET into a directory, so this is an `NSOpenPanel` in directory mode
    /// rather than the bounce's `NSSavePanel`. There is no file name to suggest
    /// and no content type to allow: the files' names come from `StemPlan` and
    /// their container from the shared format control, which is exactly why the
    /// card previews them before this panel opens.
    ///
    /// The render goes through `ExportDialogModel.exportStems` — the SAME method
    /// `debug.exportDialog {exportToDirectory}` and the suites call.
    private func runStemExportFromDialog() {
        let panel = NSOpenPanel()
        panel.title = "Export Stems"
        panel.message = "Choose a folder for the stem files"
        panel.prompt = "Export"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { @MainActor in
            _ = await self.exportDialog.exportStems(store: self.store, toDirectory: url.path)
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
            case "debug.followPlayhead":
                return try self.followPlayheadDebug(params)
            case "debug.windowFrame":
                return self.setWindowFrame(params)
            case "debug.arrangeScroll":
                return self.setArrangeScroll(params)
            case "debug.arrangeZoom":
                return try self.arrangeZoomDebug(params)
            case "debug.arrangePointer":
                return try self.arrangePointerDebug(params)
            case "debug.arrangeDrop":
                return try self.arrangeDropDebug(params)
            case "debug.arrangeSelection":
                return try self.arrangeSelectionDebug(params)
            case "debug.arrangeDrag":
                return try self.arrangeDragDebug(params)
            case "debug.arrangeMarquee":
                return try self.arrangeMarqueeDebug(params)
            case "debug.trackHeaderDrag":
                return try self.trackHeaderDragDebug(params)
            case "debug.mixerStripDrag":
                return try self.mixerStripDragDebug(params)
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
            case "debug.synthEditor":
                return try self.synthEditorDebug(params)
            case "debug.explainMode":
                return try self.setExplainMode(params)
            case "debug.explainFrames":
                return try self.explainFrames(params)
            case "debug.vibeSeed":
                return try self.setVibeSeed(params)
            case "debug.insertSpectrumSeed":
                return try self.setInsertSpectrumSeed(params)
            case "debug.scopeSeed":
                return try self.setScopeSeed(params)
            case "debug.liveLayers":
                return self.liveLayersDebug(params)
            case "debug.insertLabels":
                return self.insertLabelsDebug(params)
            case "debug.pianoRollBarOps":
                return self.pianoRollBarOpsDebug(params)
            case "debug.grSeed":
                return try self.setGRSeed(params)
            case "debug.referenceSeed":
                return try self.setReferenceSeed(params)
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
            case "debug.voicePanel":
                return try self.voicePanelDebug(params)
            case "debug.instrumentPicker":
                return self.instrumentPickerDebug(params)
            case "debug.quantizePanel":
                return self.quantizePanelDebug(params)
            case "debug.exportDialog":
                return try self.exportDialogDebug(params)
            case "debug.trackMenu":
                return try self.trackMenuDebug(params)
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

    /// `debug.panelLayout {sidebarWidth?, editorFraction?, rowHeight?,
    /// pianoRollPPB?, mixerInsertsCollapsed?, followPlayhead?, auditionEnabled?,
    /// reset?}` — stages the adjustable
    /// window layout (beta m10-d)
    /// so a headless capture / E2E can drive the arrange sidebar width, the bottom
    /// editor's height fraction, the global track-row height, and (m21-c) the
    /// piano-roll zoom before `debug.captureUI` (the `debug.panelDensity`
    /// precedent: writes straight to the shared `panelLayout` store so the live
    /// splitters reflect it). Debug tier ONLY — off `allCommands`/MCP (window layout
    /// is a UI preference, not an invokable capability; agents drive the protocol,
    /// not the chrome). Every field is optional; `reset:true` restores the defaults
    /// FIRST (so `{reset:true, rowHeight:48}` resets then applies 48). Values are
    /// clamped by the store, and the result echoes the APPLIED (post-clamp) values.
    /// The piano-roll zoom lives HERE, not in a `debug.arrangeZoom` sibling: it is
    /// one more `PanelLayoutStore` slot with no anchor/scroll machinery, so the
    /// layout seam already tells the whole truth about it.
    private func setPanelLayout(_ params: [String: JSONValue]) -> JSONValue {
        if params["reset"]?.boolValue == true { panelLayout.reset() }
        if let w = params["sidebarWidth"]?.doubleValue { panelLayout.setSidebarWidth(CGFloat(w)) }
        if let f = params["editorFraction"]?.doubleValue { panelLayout.setEditorFraction(CGFloat(f)) }
        if let h = params["rowHeight"]?.doubleValue { panelLayout.setRowHeight(CGFloat(h)) }
        if let z = params["pianoRollPPB"]?.doubleValue { panelLayout.setPianoRollPPB(CGFloat(z)) }
        // m23-a: the mixer console's INSERTS disclosure — one more sticky layout
        // slot, staged here so a capture can prove the collapsed strip.
        if let c = params["mixerInsertsCollapsed"]?.boolValue {
            panelLayout.setMixerInsertsCollapsed(c)
        }
        // m23-c2: follow-the-playhead is one more sticky slot. Set through the
        // AppModel so both surfaces are re-armed with it (a stale suspension must
        // not survive an enable) — `debug.followPlayhead` echoes the RUNTIME.
        if let f = params["followPlayhead"]?.boolValue { setFollowPlayhead(f) }
        // m23-d: the note-audition defeat switch. Also a `PanelLayoutStore` slot,
        // also debug tier ONLY — hearing notes while you edit is view chrome, and
        // the `note.audition` WIRE verb deliberately ignores it (an agent asking to
        // hear something is an explicit request, not an editing preference).
        if let a = params["auditionEnabled"]?.boolValue { panelLayout.setAuditionEnabled(a) }
        return .object([
            "sidebarWidth": .number(Double(panelLayout.sidebarWidth)),
            "editorFraction": .number(Double(panelLayout.editorFraction)),
            "rowHeight": .number(Double(panelLayout.rowHeight)),
            "pianoRollPPB": .number(Double(panelLayout.pianoRollPPB)),
            "mixerInsertsCollapsed": .bool(panelLayout.mixerInsertsCollapsed),
            "followPlayhead": .bool(panelLayout.followPlayhead),
            "auditionEnabled": .bool(panelLayout.auditionEnabled),
        ])
    }

    /// `debug.followPlayhead {rearm?, resetCounters?}` — the m23-c2 follow
    /// seam for captures/E2E. Debug tier ONLY (off `allCommands`/MCP — following is
    /// view chrome, so it adds ZERO wire surface; the m10-c/sp-b pure-view rule).
    /// The persisted ON/OFF switch is NOT here: it is a `PanelLayoutStore` slot, so
    /// it is staged through `debug.panelLayout {followPlayhead}` like every other
    /// sticky dimension. What lives here is RUNTIME ground truth neither the store
    /// nor a capture can tell you: each surface's live scroll offset, whether a
    /// manual scroll has suspended it, and the churn counters.
    ///
    /// A BARE call is READ-ONLY (the m11-a law). `rearm:true` clears a manual-scroll
    /// suspension; `resetCounters:true` zeroes the churn counters — the pair that
    /// measured page against continuous (`FollowPlayhead`'s table) and that any
    /// re-measurement of follow's cost still runs on.
    private func followPlayheadDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["rearm"]?.boolValue == true { rearmFollow() }
        if params["resetCounters"]?.boolValue == true {
            arrangeFollow.resetCounters()
            pianoRollFollow.resetCounters()
        }
        // A simulated POINTER scroll (gate seam): moves the named surface's scroller
        // without registering an expected offset, which is exactly what a drag looks
        // like to the manual-scroll detector. The arrange applies here because its
        // scroller is driven from this model; the roll's lives in view state, so it
        // travels the model's `scrollExternally` seam — different hop count, same
        // thing arrives at the detector (an offset follow never asked for).
        if let raw = params["simulateUserScroll"]?.doubleValue {
            let surface = params["surface"]?.stringValue ?? "arrange"
            switch surface {
            case "arrange": applyArrangeHScroll(CGFloat(raw))
            case "pianoRoll": pianoRollFollow.scrollExternally(to: CGFloat(raw))
            default:
                throw DebugError(
                    "unknown surface \"\(surface)\" — expected \"arrange\" or \"pianoRoll\"")
            }
        }
        // Geometry is echoed LIVE where the app owns it. The follow model only
        // learns geometry when a target is computed or an offset reported, so its
        // own copy can be one report stale — and a stale `contentWidth: 0` in a
        // gate's first read looks exactly like a surface that cannot scroll. The
        // arrange's geometry lives on this model, so it is passed in; the roll's
        // lives in view state, so the model's last-seen IS the freshest value here.
        func surface(_ model: FollowPlayheadModel,
                     contentWidth: CGFloat? = nil, viewportWidth: CGFloat? = nil) -> JSONValue {
            .object([
                "offset": .number(Double(model.reportedOffset)),
                "viewportWidth": .number(Double(viewportWidth ?? model.viewportWidth)),
                "contentWidth": .number(Double(contentWidth ?? model.contentWidth)),
                "suspended": .bool(model.isSuspended),
                "expectedOffset": model.expectedOffset.map { JSONValue.number(Double($0)) } ?? .null,
                "scrolls": .number(Double(model.scrollCount)),
                "offsetReports": .number(Double(model.offsetReportCount)),
                "contentWidthChanges": .number(Double(model.contentWidthChangeCount)),
            ])
        }
        return .object([
            "enabled": .bool(panelLayout.followPlayhead),
            "isPlaying": .bool(store.transport.isPlaying),
            "arrange": surface(arrangeFollow, contentWidth: arrangeContentWidth,
                               viewportWidth: arrangeViewportWidth),
            "pianoRoll": surface(pianoRollFollow),
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

    // MARK: - Zoom routing (m21-c)

    /// The View-menu ⌘+/⌘−/⌘0 target: the PIANO ROLL's zoom while its editor
    /// holds key focus, else the arrange timeline's (menu key equivalents fire
    /// before any focused view sees the key, so the focused-editor rule is
    /// applied here — one router for the menu items and the ⌘= alias).
    func zoomIn() {
        if pianoRollEditorFocused { zoomPianoRollIn() } else { zoomArrangeIn() }
    }
    func zoomOut() {
        if pianoRollEditorFocused { zoomPianoRollOut() } else { zoomArrangeOut() }
    }
    func zoomReset() {
        if pianoRollEditorFocused { zoomPianoRollReset() } else { zoomArrangeReset() }
    }

    /// Piano-roll zoom entry points (m21-c): every driver — the header cluster,
    /// the grid pinch, the ⌘ router above, and `debug.panelLayout` — mutates
    /// the ONE persisted `panelLayout.pianoRollPPB` slot (clamped by the
    /// store); the editor's bands re-read it and rescale together. Unlike the
    /// arrange entry points there is no anchor-offset recompute: the roll's
    /// plain SwiftUI scroller owns its own offset.
    func zoomPianoRollIn() { panelLayout.setPianoRollPPB(PianoRollZoom.zoomedIn(panelLayout.pianoRollPPB)) }
    func zoomPianoRollOut() { panelLayout.setPianoRollPPB(PianoRollZoom.zoomedOut(panelLayout.pianoRollPPB)) }
    func zoomPianoRollReset() { panelLayout.setPianoRollPPB(PianoRollZoom.defaultPixelsPerBeat) }

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
    /// ruler mirror (`arrangeHScroll` — the lanes' live report will re-confirm it
    /// from the real layout) and the lanes' `ScrollViewReader` marker (nonce-bumped
    /// so repeats still apply). Used by the zoom anchor (m17-b) AND by follow
    /// (m23-c2) — one seam, so the ruler can never lag whichever one moved.
    private func applyArrangeHScroll(_ offset: CGFloat) {
        arrangeHScroll = offset
        arrangeHScrollApplyTarget = offset
        arrangeHScrollApplyNonce += 1
    }

    // MARK: - Follow the playhead (m23-c2)

    /// The ONE opt-in flag both following surfaces read.
    var isFollowingPlayhead: Bool { panelLayout.followPlayhead }

    /// Whichever follow surface is currently suspended by a manual scroll — what
    /// the FOLLOW chip's paused face reports.
    var isFollowSuspended: Bool {
        panelLayout.followPlayhead && (arrangeFollow.isSuspended || pianoRollFollow.isSuspended)
    }

    /// The FOLLOW chip's action. While follow is PAUSED (the user scrolled during
    /// playback) a click RESUMES rather than switching off — resuming is what the
    /// press means when the chip is showing "paused", and the off state is still
    /// one more click away.
    func toggleFollowPlayhead() {
        if isFollowSuspended {
            rearmFollow()
        } else {
            setFollowPlayhead(!panelLayout.followPlayhead)
        }
    }

    /// Sets the persisted flag and re-arms both surfaces (turning follow on must
    /// never inherit a stale suspension from a previous run).
    func setFollowPlayhead(_ following: Bool) {
        panelLayout.setFollowPlayhead(following)
        rearmFollow()
    }

    /// Clears the manual-scroll suspension on both surfaces. Called on the chip's
    /// resume and whenever the transport STARTS — pressing play is the moment a
    /// user expects the view to take charge again.
    func rearmFollow() {
        arrangeFollow.rearm()
        pianoRollFollow.rearm()
    }

    /// One transport tick's follow for the ARRANGE lanes. Driven from the
    /// TRANSPORT observation path (ContentView's `onChange` of
    /// `transport.positionBeats`), never from a geometry callback: a `scrollTo`
    /// issued inside a layout transaction moves layout without durably updating
    /// the scroller's internal position (m17-b, measured), and `debug.captureUI`'s
    /// `cacheDisplay` forces exactly the re-render that would then jump.
    ///
    /// `currentOffset` is `arrangeHScrollReported` — the offset the lanes ACTUALLY
    /// reported, never the analytic mirror, so follow can never chase a value it
    /// wrote itself.
    func followArrangeTick() {
        guard workspaceMode == .arrange else { return }
        guard let target = arrangeFollow.target(
            isEnabled: panelLayout.followPlayhead,
            isPlaying: store.transport.isPlaying,
            playheadX: CGFloat(store.transport.positionBeats) * arrangePPB,
            viewportWidth: arrangeViewportWidth,
            contentWidth: arrangeContentWidth,
            currentOffset: arrangeHScrollReported) else { return }
        applyArrangeHScroll(target)
    }

    /// The lanes' live horizontal offset (ground truth from their own geometry):
    /// drives the pinned-ruler mirror, the `reported` copy the debug seams echo,
    /// and follow's manual-scroll detector.
    func reportArrangeHScroll(_ offset: CGFloat) {
        arrangeHScroll = offset
        arrangeHScrollReported = offset
        arrangeFollow.reportOffset(offset,
                                   isEnabled: panelLayout.followPlayhead,
                                   isPlaying: store.transport.isPlaying,
                                   contentWidth: arrangeContentWidth,
                                   viewportWidth: arrangeViewportWidth)
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
    /// `transport.seek`/`clip.split`/`clip.addMIDI` verbs, so ZERO new wire
    /// surface).
    /// `act` is "hover" | "click" | "doubleClick" | "clear"; `x`/`y` are
    /// CONTENT-space points (x = beats · ppb — zoom-exact without knowing the
    /// scroll offset), required for all but "clear". The staged event runs
    /// through the SAME view handlers a real pointer uses.
    ///
    /// m23-e: an `act` call WAITS (bounded) for the lanes to actually run the
    /// event before answering — see `awaitPointerStageApplied` — so the call
    /// that CAUSES a change reports that change. It used to answer from the
    /// state the view had last reported, i.e. one call behind, which meant a
    /// caller reading the causing response could pass on a stale id from an
    /// earlier action. Settling and re-reading with a bare call still works and
    /// is still the safest habit; it is no longer required.
    /// A BARE call is READ-ONLY (the m11-a law) and echoes
    /// {zone, ghostBeat, playheadBeat, ppb, refusal, refusalClipId,
    ///  refusalTrackId, selectedClipId, editorClipId, createdClipId}.
    ///
    /// m23-e: `doubleClick` over EMPTY lane space creates a bar-long MIDI clip
    /// at the snapped beat and opens the editor on it (over a clip it still
    /// splits, Pro-only). Assert the outcome with `createdClipId` +
    /// `editorClipId` — a refused create (audio/bus lane) nulls `createdClipId`
    /// and fills `refusal`/`refusalTrackId` with the store's verbatim message.
    /// Spins the main runloop, BOUNDED, until the lanes have actually run the
    /// staged pointer event — or the deadline passes (m23-e).
    ///
    /// Assigning `arrangePointerStage` only SCHEDULES a SwiftUI update; the
    /// view's `.onChange` (and everything downstream of it: the seek, the clip
    /// create, the refusal) runs when the main runloop processes that
    /// transaction. Without this wait the response is built from state the call
    /// has not caused yet, so the call that CAUSES the change answers with the
    /// PREVIOUS one's — measured as a clean one-call lag. That is not merely
    /// inconvenient: because the stale value is a real id from an earlier
    /// action, a caller reading the causing response can pass on it. The seam
    /// exists to prevent exactly that class of false pass, so the fix belongs
    /// here and not in a "read a follow-up call" convention at the caller.
    ///
    /// The `captureUI` precedent (same problem, same shape): we are on the main
    /// actor, so a bare `layoutSubtreeIfNeeded` would lay out the CURRENT tree,
    /// not the pending update — only spinning the runloop lets it land.
    /// Bounded twice over: it stops the instant the view reports back (the
    /// common case — one turn), and hard-stops at `deadline` if no lanes view
    /// is present to report at all (e.g. a `.ruler`-only or not-yet-created
    /// arrange surface), so the main actor is never held indefinitely.
    /// Reentrancy caveat, inherited from `captureUI`: the spin can service other
    /// queued main work — fine for the serial control stream this serves.
    private func awaitPointerStageApplied(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while arrangePointerReportSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

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
            // m23-e: staging a double-click CLEARS the previous outcome first, so
            // the echo describes THIS double-click and not a stale one — a
            // create that finds no room (snap landing inside a resident) leaves
            // both null rather than re-reporting the last successful create.
            // Only ever cleared here, never optimistically set: the success value
            // can arrive solely from the view's own create callback.
            if action == .doubleClick {
                arrangeCreatedClipID = nil
                arrangeSplitRefusal = nil
            }
            let reportsBefore = arrangePointerReportSeq
            arrangePointerStage = ArrangePointerStage(
                action: action, x: x, y: y,
                nonce: (arrangePointerStage?.nonce ?? 0) + 1)
            awaitPointerStageApplied(after: reportsBefore)
        }
        return .object([
            "zone": .string(arrangePointerZone),
            "ghostBeat": arrangeGhostBeat.map { .number($0) } ?? .null,
            "playheadBeat": .number(store.transport.positionBeats),
            "ppb": .number(Double(arrangePPB)),
            "refusal": arrangeSplitRefusal.map { .string($0.message) } ?? .null,
            "refusalClipId": arrangeSplitRefusal?.clipID.map { .string($0.uuidString) } ?? .null,
            // m23-e: the refused LANE (an empty-lane create has no clip to name).
            "refusalTrackId": arrangeSplitRefusal?.laneAnchor
                .map { .string($0.trackID.uuidString) } ?? .null,
            // m23-e read-back. `selectedClipId` is the raw selection; `editorClipId`
            // is the clip the piano roll is ACTUALLY open on — the SAME
            // `openEditorClip` the ContentView editor branch gates on, so a
            // non-null value here means the roll is on screen for that clip (a
            // stale id after undo resolves to null in both places at once).
            // `createdClipId` is the clip the last empty-lane double-click made,
            // and is cleared by a refusal, so it can never survive a failed create.
            "selectedClipId": selectedClipID.map { .string($0.uuidString) } ?? .null,
            "editorClipId": openEditorClip.map { .string($0.id.uuidString) } ?? .null,
            "createdClipId": arrangeCreatedClipID.map { .string($0.uuidString) } ?? .null,
            // m23-v: the empty-lane hints the LANES ARE DRAWING right now, as the
            // drawing layer reported them (never re-derived here — see
            // `arrangeEmptyLaneHints`). `text` is the string on screen, so a copy
            // change shows up here; `laneIndex` names the ladder row so a caller
            // can compute the band it expects the ink in. `emptyLaneHintSeq`
            // advances on every report, so a caller that just added or removed a
            // clip can poll for a fresh render instead of sleeping.
            //
            // This costs ZERO wire surface: `debug.*` sits off `allCommands` and
            // off MCP.
            "emptyLaneHints": .array(arrangeEmptyLaneHints.map {
                .object([
                    "trackId": .string($0.trackID.uuidString),
                    "laneIndex": .number(Double($0.laneIndex)),
                    "text": .string($0.text),
                ])
            }),
            "emptyLaneHintSeq": .number(Double(arrangeEmptyLaneHintSeq)),
        ])
    }

    /// Spins the main runloop, BOUNDED, until the lanes have actually run the
    /// staged DROP event — the `awaitPointerStageApplied` contract, same reasons
    /// (m23-e echo-seam law). Bounded twice over: it stops the instant the view
    /// reports back, and hard-stops at the deadline if no lanes view is present
    /// to report at all (a `.ruler`-only / not-yet-created arrange surface).
    private func awaitDropStageApplied(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while arrangeDropReportSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.arrangeDrop {act?, x?, y?, paths?, fileCount?}` — the m23-f staging
    /// seam for the Finder audio-file drag-drop onto the arrange lanes. App-level,
    /// debug tier ONLY (off `allCommands`/MCP — ZERO wire growth; the import
    /// itself is already agent-invokable via `clip.addAudio` / `debug.importAudio`,
    /// and this stages the DROP GESTURE, which no wire verb models).
    ///
    /// A real Finder drag cannot be driven over the control port for two
    /// independent reasons — `DropInfo` has no public initializer, and the
    /// unbundled staging binary has no Accessibility grant (m17-b, −1712) — so
    /// the seam drives `AudioLaneDropCore`, the same object `AudioLaneDropDelegate`
    /// drives. Each drag phase is independently addressable so a gate can
    /// reproduce a REAL ordering (`enter → update → update → drop`) rather than an
    /// isolated drop (the m23-e staged-gate law: a synthetic gate cannot see a bug
    /// that only real event ordering produces).
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law).
    ///   - `{act:"enter"|"update", x, y, fileCount?, carriesMidi?}` — the hover
    ///     phases. `carriesMidi` stages a drag carrying a `.mid` (m23-k4b): a
    ///     real hover reads that from the drag's UTIs before any URL has loaded,
    ///     so there is nothing for a staged hover to derive it from. It changes
    ///     the ROUTING (`hoverTargetLaneIndex` goes null — a `.mid` makes its own
    ///     instrument tracks, so no audio lane may be highlighted) and nothing
    ///     about the landing beat.
    ///   - `{act:"exit"}` — the drag left the lanes.
    ///   - `{act:"drop", x, y, paths:[...]}` — the release. `paths` are resolved
    ///     SYNCHRONOUSLY (no `NSItemProvider`), so one bounded wait covers the
    ///     whole drop and the causing response can already report the landing.
    ///   - `{snap:"off"|"bar"|"beat"|…}` — sets the arrange snap PICKER, so a
    ///     gate can sweep the drop-position table. Combinable with an `act`
    ///     (applied first) or usable alone. There is no wire verb for the snap
    ///     picker; it is UI state, so it belongs on a debug seam rather than
    ///     growing the agent-facing surface.
    ///
    /// Echoes `{hoverVisible, hoverBeat, hoverRawBeat, hoverTargetTrackId,
    /// hoverTargetLaneIndex, hoverSnapSource, decidedBeat, decidedRawBeat,
    /// decidedSnapSource, decidedTargetTrackId, ppb, snap, effectiveSnap,
    /// results}`. `hoverVisible` is the report-(2) measurement: whether a drop
    /// line is standing. It is read from the LIVE view state, never from the
    /// seam's input. `snap`/`effectiveSnap` are echoed so a caller CHECKS that a
    /// snap it asked for actually landed instead of assuming it (the m23-c2
    /// corollary: a debug command silently ignores keys it does not own).
    private func arrangeDropDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let raw = params["snap"]?.stringValue {
            guard let snap = ClipSnap(rawValue: raw) else {
                throw DebugError("unknown snap \"\(raw)\" — expected one of "
                    + ClipSnap.allCases.map(\.rawValue).joined(separator: ", "))
            }
            clipSnap = snap
        }
        if let act = params["act"]?.stringValue {
            guard let action = ArrangeDropStage.Action(rawValue: act) else {
                throw DebugError(
                    "unknown act \"\(act)\" — expected \"enter\", \"update\", \"drop\", or \"exit\"")
            }
            workspaceMode = .arrange
            var x: CGFloat = 0, y: CGFloat = 0
            if action != .exit {
                guard let xv = params["x"]?.doubleValue, let yv = params["y"]?.doubleValue else {
                    throw DebugError(
                        "act \"\(act)\" needs content-space x and y (points; x = beats · ppb)")
                }
                x = CGFloat(xv)
                y = CGFloat(yv)
            }
            var urls: [URL] = []
            if action == .drop {
                guard let rawPaths = params["paths"]?.arrayValue, !rawPaths.isEmpty else {
                    throw DebugError(
                        "act \"drop\" requires a non-empty 'paths' array (the dragged files)")
                }
                let strings = rawPaths.compactMap { $0.stringValue }
                guard strings.count == rawPaths.count else {
                    throw DebugError("debug.arrangeDrop 'paths' must all be strings")
                }
                urls = strings.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                // Clear the previous drop's results so the echo describes THIS
                // drop and not a stale one (the `arrangeCreatedClipID` rule).
                arrangeDropImportResults = []
            }
            let fileCount = params["fileCount"]?.doubleValue.map { Int($0) } ?? max(1, urls.count)
            // A staged HOVER has no URLs to classify (neither does a real one —
            // its providers load async), so `carriesMidi` is how a gate stages a
            // MIDI-carrying drag. A staged DROP ignores it and derives the truth
            // from `paths`, exactly as the real drop does (m23-k4b).
            let carriesMIDI = params["carriesMidi"]?.boolValue ?? false
            let reportsBefore = arrangeDropReportSeq
            arrangeDropStage = ArrangeDropStage(
                action: action, x: x, y: y, urls: urls, fileCount: fileCount,
                carriesMIDI: carriesMIDI,
                nonce: (arrangeDropStage?.nonce ?? 0) + 1)
            awaitDropStageApplied(after: reportsBefore)
        }
        let live = arrangeDropHover
        let decided = arrangeDropDecided
        return .object([
            "hoverVisible": .bool(live != nil),
            "hoverBeat": live.map { .number($0.snappedBeat) } ?? .null,
            "hoverRawBeat": live.map { .number($0.rawBeat) } ?? .null,
            "hoverTargetTrackId": live?.targetTrackID.map { .string($0.uuidString) } ?? .null,
            "hoverTargetLaneIndex": live?.targetLaneIndex.map { .number(Double($0)) } ?? .null,
            // WHICH rule decided the landing (m23-f) — "raw" | "grid" |
            // "magnetBarOne" | "magnetClipEdge". A gate can then assert not just
            // where a drop landed but why, which is what distinguishes a working
            // magnet from a grid line that happened to sit in the same place.
            "hoverSnapSource": live.map { .string($0.landing.source.rawValue) } ?? .null,
            "decidedBeat": decided.map { .number($0.snappedBeat) } ?? .null,
            "decidedRawBeat": decided.map { .number($0.rawBeat) } ?? .null,
            "decidedSnapSource": decided.map { .string($0.landing.source.rawValue) } ?? .null,
            "decidedTargetTrackId": decided?.targetTrackID.map { .string($0.uuidString) } ?? .null,
            "ppb": .number(Double(arrangePPB)),
            "snap": .string(clipSnap.rawValue),
            // The guard behind the pointer dismissal, echoed so this seam can be
            // diagnosed instead of guessed at: a non-zero value means a mouse
            // button is held, and a stranded line will (correctly) survive an
            // ordinary pointer event.
            "pressedMouseButtons": .number(Double(NSEvent.pressedMouseButtons)),
            // What the arrange lane ACTUALLY uses — Simple locks it to Bar
            // regardless of the picker, so a gate that only read `snap` could
            // sweep a table that the view never applied.
            "effectiveSnap": .string(effectiveClipSnap.rawValue),
            "results": .array(arrangeDropImportResults.map(Self.encodeImportResult)),
        ])
    }

    /// Spins the main runloop, BOUNDED, until the LANES have re-rendered with the
    /// selection this call just changed — the `awaitDropStageApplied` contract
    /// (m23-e echo-seam law). Without it a capture taken straight after the echo
    /// can frame the PREVIOUS selection, which does not merely fail a gate: it
    /// can stale-GREEN one. Bounded twice over: it stops the instant the lanes
    /// report, and hard-stops at the deadline when no lanes view exists to report
    /// at all (the Mix workspace, a not-yet-created arrange surface).
    private func awaitSelectionRendered(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while arrangeSelectionRenderSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.arrangeSelection {act?, clipId?, shift?, command?}` — the m23-g1
    /// staging seam for arrange multi-select and group delete. App-level, debug
    /// tier ONLY (off `allCommands`/MCP — ZERO wire growth).
    ///
    /// WHY DEBUG TIER: the selection is UI state, and UI state belongs on a debug
    /// seam rather than on the agent-facing surface (the `debug.arrangeDrop` snap
    /// picker set the precedent, for the same reason). The DOMAIN effect of group
    /// delete is already agent-reachable as N× `clip.remove`; the only delta is
    /// undo ATOMICITY, and the command that would expose it (`clip.removeMany`
    /// → MCP `daw_clip_remove_many`) is left as a TODO on
    /// `ProjectStore.removeClips` rather than shipped unasked.
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law).
    ///   - `{act:"click", clipId, shift?, command?}` — runs the SAME
    ///     `AppModel.clickClip` the ClipBlock tap runs, with EXPLICIT modifiers.
    ///     The one thing it does not exercise is `NSEvent.modifierFlags` (a
    ///     synthesized tap carries no chord) — see `ArrangeClickModifiers.current`.
    ///   - `{act:"clickTrack", trackId, shift?, command?}` (m23-y) — runs the SAME
    ///     `AppModel.clickTrack` the `TrackRow` tap runs, with EXPLICIT modifiers,
    ///     for the same reason. Echoes `trackClickIntent` / `trackClickEffect` /
    ///     `trackClipIds`, all carried off `ArrangeTrackClickOutcome` rather than
    ///     recomputed: without the EFFECT a gate cannot tell "⇧ added this track's
    ///     three clips" from "⇧ found them already selected and removed nothing",
    ///     since both can leave the same `selectedIds`. An unknown id THROWS.
    ///   - `{act:"clear"}` — deselect everything.
    ///   - `{act:"delete"}` — the group delete, through the SAME
    ///     `deleteArrangeSelection` the DELETE key calls.
    ///   - `{act:"keyHandler"}` — the DELETE key's HANDLER body including its
    ///     guards (`handleArrangeDeleteKey`), for proving the text-editing guard.
    ///   - `{act:"nudge", direction:"left"|"right", option?, shift?, command?,
    ///     control?, repeat?}` (m23-x) — the ARROW key's HANDLER body including
    ///     its guards (`handleArrangeNudgeKey`), the `keyHandler` twin. The chord
    ///     is passed EXPLICITLY, per the house convention above: a synthesized
    ///     press carries no `NSEvent.modifierFlags`, so the whole modifier policy
    ///     lives in `ArrangeNudge.step` and this exercises exactly the rule the
    ///     real key does. `repeat` (default 1, capped) runs the handler N times
    ///     back to back with NO awaits between — key repeat, faithfully — which
    ///     is what makes the undo-coalescing leg measurable: interleaving a
    ///     render wait per press would blow past `UndoJournal.coalescingWindow`
    ///     (800 ms) and the burst would stop folding for a reason that has
    ///     nothing to do with the app.
    ///   - `{act:"keyDelete"}` — the STRONGER probe: synthesizes a real DELETE
    ///     key-down and sends it through `NSApp.sendEvent`, i.e. the actual
    ///     responder chain and SwiftUI's focus arbitration. When `delivered` is
    ///     true this proves key DELIVERY, not just the handler. It is a probe,
    ///     not a guarantee: an unbundled staging binary whose window is not key
    ///     may never route it, and the honest report of that is `delivered:false`
    ///     with the selection unchanged.
    ///
    /// Echoes the selection GROUND TRUTH (`arrangeSelection`, the model's own
    /// state — never the seam's input), plus `editorClipId`, which is the clip
    /// the piano roll is ACTUALLY open on (`openEditorClip`, the same value
    /// `debug.arrangePointer` reports): that is the m23-e regression instrument.
    private func arrangeSelectionDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        var deleted: Bool?
        var intent: ArrangeClickIntent?
        var delivered: Bool?
        var nudge: ArrangeNudgeOutcome?
        var nudgeRepeats: Int?
        var trackClick: ArrangeTrackClickOutcome?
        if let act = params["act"]?.stringValue {
            let reportsBefore = arrangeSelectionRenderSeq
            switch act {
            case "click":
                guard let raw = params["clipId"]?.stringValue, let id = UUID(uuidString: raw) else {
                    throw DebugError("act \"click\" needs a 'clipId' UUID")
                }
                workspaceMode = .arrange
                var mods: ArrangeClickModifiers = []
                if params["shift"]?.boolValue == true { mods.insert(.shift) }
                if params["command"]?.boolValue == true { mods.insert(.command) }
                intent = clickClip(id: id, modifiers: mods)
            case "clickTrack":
                // m23-y — the TRACK HEADER click, through the SAME
                // `AppModel.clickTrack` the `TrackRow` tap runs. `workspaceMode`
                // IS forced to `.arrange` here, matching "click" and NOT "nudge":
                // the header column only exists in the arrange, so a gate that
                // had to remember to set the workspace would be fighting the
                // fixture rather than the feature. ("nudge" refuses to, on
                // purpose — the workspace guard is one of the four IT exists to
                // let a gate prove; there is no such guard on this path.)
                guard let raw = params["trackId"]?.stringValue else {
                    throw DebugError("act \"clickTrack\" needs a 'trackId' UUID")
                }
                guard let id = UUID(uuidString: raw) else {
                    throw DebugError("'trackId' is not a valid UUID: \(raw)")
                }
                workspaceMode = .arrange
                var mods: ArrangeClickModifiers = []
                if params["shift"]?.boolValue == true { mods.insert(.shift) }
                if params["command"]?.boolValue == true { mods.insert(.command) }
                guard let outcome = clickTrack(id: id, modifiers: mods) else {
                    // The `debug.trackHeaderDrag` convention: an unknown id is
                    // TOLD, never answered as a silent no-op a gate reads as green.
                    throw DebugError("no track with id \(raw)")
                }
                trackClick = outcome
            case "pianoRollNotes":
                // m23-x: put the OPEN ROLL into (or out of) the state where it
                // would consume ← / → — a real selection in the roll's own
                // `@State private` model, reached the only way anything outside
                // can reach it (the `follow.externalScrollNonce` nonce seam), so
                // the controlled pair drives the SHIPPED wiring end to end and
                // not a flag a gate set for itself.
                guard let select = params["select"]?.boolValue else {
                    throw DebugError("act \"pianoRollNotes\" needs 'select' (bool)")
                }
                pianoRollNoteSelection.stage(selectAll: select)
                // The roll applies this in an `.onChange`, i.e. on the next main
                // runloop turn — answer only once it has, or the caller reads
                // the PREVIOUS state (the m23-e one-call-lag class).
                let noteDeadline = Date().addingTimeInterval(0.30)
                while pianoRollNoteSelection.hasSelection != select,
                      Date() < noteDeadline {
                    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
                }
            case "clear":
                arrangeSelection.clear()
            case "delete":
                deleted = deleteArrangeSelection()
            case "keyHandler":
                // The DELETE key's HANDLER body, guards and all — what
                // `.onKeyPress(.delete)` calls. Distinct from "delete" (which is
                // the bare action) because the guards are the point: this is how
                // a gate proves that a Backspace typed into a rename field
                // cannot delete the user's clips, WITHOUT depending on whether
                // an unbundled staging binary routes real key events.
                deleted = handleArrangeDeleteKey()
            case "nudge":
                // The ARROW key's HANDLER body, guards and all (m23-x) — the
                // `keyHandler` twin. `workspaceMode` is NOT forced to `.arrange`
                // here (unlike "click"), deliberately: the workspace guard is
                // one of the four this seam exists to let a gate PROVE, and a
                // seam that silently repaired it would make that leg vacuous.
                guard let raw = params["direction"]?.stringValue,
                      let direction = ArrangeNudgeDirection(rawValue: raw) else {
                    throw DebugError("act \"nudge\" needs 'direction' — \"left\" or \"right\" "
                        + "(there is no vertical nudge: see ArrangeNudge)")
                }
                var mods: TransportKeyModifiers = []
                if params["option"]?.boolValue == true { mods.insert(.option) }
                if params["shift"]?.boolValue == true { mods.insert(.shift) }
                if params["command"]?.boolValue == true { mods.insert(.command) }
                if params["control"]?.boolValue == true { mods.insert(.control) }
                // Capped so a typo cannot wedge the main actor. 200 presses is
                // ~2.5 s of real key repeat, far more than any leg needs.
                let times = min(200, max(1, Int(params["repeat"]?.doubleValue ?? 1)))
                nudgeRepeats = times
                let layoutBefore = arrangeClipLayoutRenderSeq
                var last: ArrangeNudgeOutcome?
                for _ in 0..<times {
                    last = handleArrangeNudgeKey(direction: direction, modifiers: mods)
                }
                nudge = last
                // A nudge changes no SELECTION, so `arrangeSelectionRenderSeq`
                // will never bump for it — waiting on that (the m23-g2 finding)
                // would always time out and report whatever the last selection
                // change left behind. The clip-layout seq is the move's signal.
                if last?.changed == true { awaitClipLayoutRendered(after: layoutBefore) }
            case "keyDelete":
                guard let event = NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: contentWindow?.windowNumber ?? 0,
                    context: nil,
                    // NSDeleteCharacter (0x7F) is what the Mac's Delete/Backspace
                    // key sends, and is what SwiftUI's `KeyEquivalent.delete`
                    // matches. keyCode 51 = kVK_Delete, layout-independent.
                    characters: "\u{7F}", charactersIgnoringModifiers: "\u{7F}",
                    isARepeat: false, keyCode: 51) else {
                    throw DebugError("failed to synthesize the delete key event")
                }
                let before = arrangeSelection.ids
                // Make the target window key first: SwiftUI's focus system is
                // only ACTIVE in the key window, so a key event sent to a
                // non-key window is dropped before any `.onKeyPress` sees it.
                // Window-scoped, not `NSApp.activate` — staging must never steal
                // the user's system focus.
                contentWindow?.makeKeyAndOrderFront(nil)
                NSApplication.shared.sendEvent(event)
                // Let SwiftUI's key handling land before the echo answers.
                RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.15))
                delivered = arrangeSelection.ids != before
            default:
                throw DebugError("unknown act \"\(act)\" — expected \"click\", \"clickTrack\", "
                    + "\"clear\", \"delete\", \"keyHandler\", \"nudge\", "
                    + "\"pianoRollNotes\", or \"keyDelete\"")
            }
            // "nudge" opts OUT: it changes no selection, so this wait can only
            // burn its full deadline, and burning ~0.3 s per seam call is not
            // free here — two calls a gate means to coalesce would then sit
            // 800 ms apart and stop folding for a reason that is the seam's,
            // not the app's. It waits on the CLIP LAYOUT seq instead, above.
            // "pianoRollNotes" opts out for the same reason and waits on its own
            // condition (the roll reporting the staged state) inside the case.
            if act != "nudge", act != "pianoRollNotes" {
                awaitSelectionRendered(after: reportsBefore)
            }
        }
        var object: [String: JSONValue] = [
            "selectedIds": .array(arrangeSelection.ids.map { .string($0.uuidString) }
                .sorted { a, b in (a.stringValue ?? "") < (b.stringValue ?? "") }),
            "count": .number(Double(arrangeSelection.count)),
            // The FOCUS clip and its two aliases, so a gate can see the mirror is
            // coherent rather than assume it: `selectedClipId` is the property
            // ~19 pre-g1 call sites read, and it must always equal `focusClipId`.
            "focusClipId": arrangeSelection.focusID.map { .string($0.uuidString) } ?? .null,
            "selectedClipId": selectedClipID.map { .string($0.uuidString) } ?? .null,
            // The m23-e instrument: the clip the piano roll is ACTUALLY open on.
            "editorClipId": openEditorClip.map { .string($0.id.uuidString) } ?? .null,
            // The focus guard's live verdict — echoed so a gate can PROVE the
            // text-editing leg is testing what it thinks it is.
            "textEditing": .bool(isArrangeTextEditingFocused),
            // Which workspace is live — the observable half of the DELETE-key
            // scoping (see `handleArrangeDeleteKey`).
            "workspaceMode": .string(workspaceMode.rawValue),
            // Whether a blocking modal is up — the retained-focus DELETE guard
            // (see `isModalPresented`), echoed so a gate can prove it non-vacuous.
            "modalPresented": .bool(isModalPresented),
            // Whether the PIANO ROLL currently holds key focus (set by the roll's
            // own `onFocusChange`). Echoed because clicking an arrange clip bumps
            // `arrangeKeyFocusNonce`, which asserts focus on the workspace scope —
            // this is the only way to see whether that nonce is racing the roll's
            // focus, i.e. whether note DELETE inside the roll can still win the key.
            // m23-x UPDATED THE SECOND HALF OF THIS NOTE: note selection IS now
            // drivable, via `act:"pianoRollNotes"`, so the pair below is a real
            // controlled instrument rather than a measurement. (The roll's own
            // note-DELETE path still needs a human — that is about key DELIVERY,
            // which no unbundled staging binary can exercise; m23-g1.)
            "pianoRollEditorFocused": .bool(pianoRollEditorFocused),
            // m23-x: the OTHER half of the nudge's fifth guard. Both terms are
            // echoed separately so a red leg says WHICH one was not in the state
            // the leg assumed — focus alone is true for any single selected MIDI
            // clip and is NOT sufficient to refuse (see `handleArrangeNudgeKey`).
            "pianoRollNoteSelection": .bool(pianoRollNoteSelection.hasSelection),
            "renderSeq": .number(Double(arrangeSelectionRenderSeq)),
            // m23-y: the KEY-FOCUS nonce, echoed on every read so a gate can take
            // a baseline with the same call it asserts with. This is the
            // mechanism that moves keyboard focus onto the arrange workspace
            // (`ArrangeDeleteKey`'s `.onChange(of: model.arrangeKeyFocusNonce)`),
            // so DELETE reaches the clips a click just selected.
            //
            // WHAT IT PROVES AND WHAT IT DOES NOT: that the BUMP happened. It
            // does NOT prove focus actually moved — that is SwiftUI's focus
            // arbitration, which no seam in this app can observe (the roll's own
            // `pianoRollEditorFocused` flag was measured ALTERNATING 6/6 across
            // clip switches at m23-x and must not be used as one). Without this
            // field, dropping the bump would be invisible to every gate, which
            // is worse than an honestly-partial assertion.
            "keyFocusNonce": .number(Double(arrangeKeyFocusNonce)),
            // m23-x instruments, echoed on EVERY read (not just after a nudge)
            // so a gate can take a baseline with the same call it asserts with.
            //
            // `editSeq` is the VACUITY DISCRIMINATOR the nudge legs turn on.
            // `performEdit` ticks it for EVERY journaled edit including a
            // COALESCED one, while the undo DEPTH only grows on a fresh entry —
            // so "5 presses folded into 1 entry" (seq +5, depth +1) and "1 press
            // landed and 4 were silently dropped" (seq +1, depth +1), which an
            // undo-depth assertion alone cannot tell apart, are distinguishable
            // here. Read from the STORE's own `lastEditEvent`, never counted by
            // this seam.
            "editSeq": .number(Double(store.lastEditEvent?.seq ?? 0)),
            "undoDepth": .number(Double(store.undoHistory().undo.count)),
            "undoLabel": store.undoHistory().undo.first.map { .string($0) } ?? .null,
            // The grid a bare arrow steps by. Both, per the m23-c2 corollary:
            // Simple density locks the effective grid to `.bar` regardless of the
            // picker, so a gate that set `sixteenth` and read back only `snap`
            // would sweep a table the app never applied.
            "snap": .string(clipSnap.rawValue),
            "effectiveSnap": .string(effectiveClipSnap.rawValue),
        ]
        if let deleted { object["deleted"] = .bool(deleted) }
        if let intent { object["intent"] = .string(intent.rawValue) }
        if let delivered { object["delivered"] = .bool(delivered) }
        if let trackClick {
            // m23-y. `trackClipIds` is the set `ArrangeTrackSelection.clipIDs(on:)`
            // ACTUALLY RETURNED, carried out on the outcome — never a fresh
            // `track.clips.map(\.id)` computed here. A seam that recomputed it
            // would agree with a broken rule by construction and could not see a
            // mutation to the rule at all.
            object["trackClickIntent"] = .string(trackClick.intent.rawValue)
            object["trackClickEffect"] = .string(trackClick.effect.rawValue)
            object["trackClipIds"] = .array(trackClick.clipIDs.map { .string($0.uuidString) }
                .sorted { a, b in (a.stringValue ?? "") < (b.stringValue ?? "") })
        }
        if let repeats = nudgeRepeats { object["nudgeRepeats"] = .number(Double(repeats)) }
        if let nudge {
            // GROUND TRUTH from the handler's own outcome — `stepBeats` is the
            // number `ArrangeNudge.step` produced, never a second computation
            // here (a seam that recomputed the step could agree with the handler
            // by luck and hide a wiring bug, the m23-f finding).
            object["nudged"] = .bool(nudge.handled)
            object["refusedBy"] = nudge.refusedBy.map { .string($0.rawValue) } ?? .null
            object["stepBeats"] = nudge.stepBeats.map { .number($0) } ?? .null
            object["stepSource"] = nudge.stepSource.map { .string($0) } ?? .null
            object["requestedDeltaBeats"] = .number(nudge.requestedDeltaBeats)
            object["effectiveDeltaBeats"] = .number(nudge.effectiveDeltaBeats)
            object["clamped"] = .bool(nudge.clamped)
            object["movedIds"] = .array(nudge.movedIDs.map { .string($0.uuidString) }
                .sorted { a, b in (a.stringValue ?? "") < (b.stringValue ?? "") })
            object["trimmedIds"] = .array(nudge.trimmedIDs.map { .string($0.uuidString) })
            object["removedIds"] = .array(nudge.removedIDs.map { .string($0.uuidString) })
        }
        if let refusal = arrangeSplitRefusal { object["refusal"] = .string(refusal.message) }
        return .object(object)
    }

    /// Spins the main runloop, BOUNDED, until the LANES have re-rendered with
    /// the clip GEOMETRY this call just changed — the `awaitSelectionRendered`
    /// contract (m23-e echo-seam law), on the other counter.
    private func awaitClipLayoutRendered(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while arrangeClipLayoutRenderSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.arrangeDrag {clipId?, deltaBeats?, snap?}` — the m23-g2 staging seam
    /// for the arrange clip BODY DRAG. App-level, debug tier ONLY (off
    /// `allCommands`/MCP — ZERO wire growth; the group-move verb's own wire
    /// exposure is filed as roadmap item m23-w, see `ProjectStore.moveClips`).
    ///
    /// WHY IT EXISTS: `debug.arrangePointer` models hover / click / doubleClick
    /// / clear and has no DRAG act, so before this the group-drag feature was
    /// not observable from outside the app at all.
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law).
    ///   - `{clipId, deltaBeats}` — one body-drag update anchored on `clipId`.
    ///     **`deltaBeats` is the RAW, PRE-SNAP pointer translation in beats**, so
    ///     the seam exercises the snapping decision instead of bypassing it; the
    ///     anchor's drag-origin start is its CURRENT start (a staged drag starts
    ///     from rest). It runs `AppModel.dragArrangeClips` — the SAME method the
    ///     ClipBlock gesture runs, grab rule included, so a staged drag on an
    ///     UNSELECTED clip collapses the selection onto it exactly as the mouse
    ///     would.
    ///   - `{snap:"off"|"bar"|…}` — sets the arrange snap PICKER (the
    ///     `debug.arrangeDrop` precedent), combinable with a drag (applied first)
    ///     or alone.
    ///
    /// Echoes `snap` AND `effectiveSnap`: Simple density locks the grid to `.bar`
    /// regardless of the picker, so a caller that set `sixteenth` and read back
    /// only `snap` would sweep a table the view never applied (the m23-c2
    /// corollary — echo back and CHECK, never assume a parameter landed).
    /// `starts`/`lengths`/`noteCounts` cover EVERY live clip, not just the
    /// movers, because the data-loss guard this item exists for is about the
    /// INNOCENT clip between two movers.
    private func arrangeDragDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let raw = params["snap"]?.stringValue {
            guard let snap = ClipSnap(rawValue: raw) else {
                throw DebugError("unknown snap \"\(raw)\" — expected one of "
                    + ClipSnap.allCases.map(\.rawValue).joined(separator: ", "))
            }
            clipSnap = snap
        }
        var outcome: ArrangeGroupDragOutcome?
        if let rawID = params["clipId"]?.stringValue {
            guard let id = UUID(uuidString: rawID) else {
                throw DebugError("debug.arrangeDrag 'clipId' must be a UUID")
            }
            guard let delta = params["deltaBeats"]?.doubleValue else {
                throw DebugError(
                    "debug.arrangeDrag needs 'deltaBeats' — the RAW, PRE-SNAP drag translation in beats")
            }
            guard let anchor = liveClip(id) else {
                throw DebugError("no clip \(rawID) in this project")
            }
            workspaceMode = .arrange
            let reportsBefore = arrangeClipLayoutRenderSeq
            let result = dragArrangeClips(
                anchorClipID: id, anchorOriginalStart: anchor.startBeat,
                rawDragDeltaBeats: delta)
            outcome = result
            // Only wait when there IS a re-render coming: a drag that moved
            // nothing would otherwise burn the full 0.30 s deadline.
            if result.changed { awaitClipLayoutRendered(after: reportsBefore) }
        } else if params["deltaBeats"] != nil {
            throw DebugError("debug.arrangeDrag 'deltaBeats' needs a 'clipId' anchor")
        }

        var starts: [String: JSONValue] = [:]
        var lengths: [String: JSONValue] = [:]
        var noteCounts: [String: JSONValue] = [:]
        for track in store.tracks {
            for clip in track.clips {
                let key = clip.id.uuidString
                starts[key] = .number(clip.startBeat)
                lengths[key] = .number(clip.lengthBeats)
                noteCounts[key] = .number(Double(clip.notes?.count ?? 0))
            }
        }
        var object: [String: JSONValue] = [
            "snap": .string(clipSnap.rawValue),
            "effectiveSnap": .string(effectiveClipSnap.rawValue),
            "ppb": .number(Double(arrangePPB)),
            "selectedIds": .array(arrangeSelection.ids.map { .string($0.uuidString) }
                .sorted { a, b in (a.stringValue ?? "") < (b.stringValue ?? "") }),
            "focusClipId": arrangeSelection.focusID.map { .string($0.uuidString) } ?? .null,
            "starts": .object(starts),
            "lengths": .object(lengths),
            "noteCounts": .object(noteCounts),
            "renderSeq": .number(Double(arrangeClipLayoutRenderSeq)),
            "undoDepth": .number(Double(store.undoHistory().undo.count)),
            "undoLabel": store.undoHistory().undo.first.map { .string($0) } ?? .null,
        ]
        if let outcome {
            object["anchorId"] = params["clipId"].map { $0 } ?? .null
            object["movedIds"] = .array(outcome.movedIDs.map { .string($0.uuidString) }
                .sorted { a, b in (a.stringValue ?? "") < (b.stringValue ?? "") })
            object["anchorStart"] = .number(outcome.anchorStart)
            object["requestedDeltaBeats"] = .number(outcome.requestedDeltaBeats)
            object["effectiveDeltaBeats"] = .number(outcome.effectiveDeltaBeats)
            // `clamped` is the union — "the requested landing was reduced",
            // whichever stage did it. The two stage flags ride alongside so a
            // diagnosis made THROUGH this echo can tell WHERE, and so the
            // `requested == effective` case (gesture floor, store had nothing
            // left to clamp) reads as an explanation instead of a paradox.
            object["clamped"] = .bool(outcome.clamped)
            object["storeClamped"] = .bool(outcome.storeClamped)
            object["gestureFlooredAtZero"] = .bool(outcome.gestureFlooredAtZero)
            object["trimmedIds"] = .array(outcome.trimmedIDs.map { .string($0.uuidString) })
            object["removedIds"] = .array(outcome.removedIDs.map { .string($0.uuidString) })
            object["refusal"] = outcome.refusal.map { .string($0) } ?? .null
        }
        return .object(object)
    }

    /// Spins the main runloop, BOUNDED, until the LANES have run the staged
    /// marquee step and reported back — the `awaitPointerStageApplied` contract
    /// (m23-e echo-seam law). Without it the echo answers with the PREVIOUS
    /// step's band and selection, which does not merely fail a gate: a stale
    /// echo poisons every diagnosis made through it. Bounded twice over: it
    /// stops the instant the lanes report, and hard-stops at the deadline when
    /// no lanes instance exists to report at all (the Mix workspace, a
    /// not-yet-created arrange surface).
    private func awaitMarqueeApplied(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while arrangeMarqueeReportSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.arrangeMarquee {act?, x?, y?, shift?, command?}` — the m23-g3
    /// staging seam for the arrange RUBBER BAND. App-level, debug tier ONLY (off
    /// `allCommands`/MCP — ZERO wire growth, matching m23-g1 and m23-g2: the
    /// selection is UI state, and the marquee's only domain effect is the
    /// selection it produces, which `debug.arrangeSelection` already echoes).
    ///
    /// PHASED, not one-shot. A one-shot "select this rect" seam structurally
    /// cannot observe "the band is VISIBLE during the drag" — it would have
    /// begun and ended inside one call, leaving nothing standing to look at:
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law). Answers the LADDER too,
    ///     which is the point: `laneTops` + `rowHeight` are what a caller needs
    ///     to compute a band, and both are unknowable from outside (the ladder
    ///     is non-uniform, `rowHeight` is user-adjustable — beta m10-d). A
    ///     caller MUST derive its fixture from these, never from 34/6/64.
    ///   - `{act:"begin", x, y, shift?|command?}` — press. Freezes the band
    ///     origin and the pre-drag selection; applies the (degenerate) band, so
    ///     a plain begin clears the selection exactly as the live gesture does
    ///     the instant it arms.
    ///   - `{act:"changed", x, y}` — drag the band's free corner. Re-decides the
    ///     whole selection from the frozen base, so shrinking gives clips back.
    ///   - `{act:"end", x, y}` — release: apply the final band, then clear it.
    ///
    /// A synthesized gesture carries no real `NSEvent.modifierFlags`, so the
    /// chord is passed EXPLICITLY (the `debug.arrangeSelection` convention); the
    /// one line the seam therefore cannot exercise is the live
    /// `ArrangeClickModifiers.current` read, exactly as recorded there.
    ///
    /// Echoes GROUND TRUTH throughout — `bandRect` is the rect the LANES are
    /// drawing (reported up), never the seam's input, and `selectedIds`/`focusId`
    /// are the model's own `ArrangeSelection`.
    private func arrangeMarqueeDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let act = params["act"]?.stringValue {
            guard let action = ArrangeMarqueeStage.Action(rawValue: act) else {
                throw DebugError(
                    "unknown act \"\(act)\" — expected \"begin\", \"changed\", or \"end\"")
            }
            guard let xv = params["x"]?.doubleValue, let yv = params["y"]?.doubleValue else {
                throw DebugError(
                    "act \"\(act)\" needs content-space x and y (points; x = beats · ppb, "
                    + "y measured against the laneTops this command echoes)")
            }
            workspaceMode = .arrange
            let additive = params["shift"]?.boolValue == true
                || params["command"]?.boolValue == true
            let reportsBefore = arrangeMarqueeReportSeq
            arrangeMarqueeStage = ArrangeMarqueeStage(
                action: action, x: CGFloat(xv), y: CGFloat(yv), additive: additive,
                nonce: (arrangeMarqueeStage?.nonce ?? 0) + 1)
            awaitMarqueeApplied(after: reportsBefore)
        } else if params["x"] != nil || params["y"] != nil {
            throw DebugError("debug.arrangeMarquee 'x'/'y' need an 'act'")
        }

        return .object([
            // The LADDER — the ground truth a fixture must be computed FROM.
            "laneTops": .array(arrangeLaneGeometry.laneTops.map { .number(Double($0)) }),
            "rowHeight": .number(Double(arrangeLaneGeometry.rowHeight)),
            "laneCount": .number(Double(arrangeLaneGeometry.laneTops.count)),
            "ppb": .number(Double(arrangePPB)),
            // The band the LANES are drawing — null exactly when none is in
            // flight. Non-null mid-drag is the only positive proof the band
            // exists; "gone after" alone passes vacuously against an
            // implementation that never draws one.
            "bandRect": arrangeMarqueeBand.map {
                .object([
                    "x": .number(Double($0.minX)), "y": .number(Double($0.minY)),
                    "width": .number(Double($0.width)), "height": .number(Double($0.height)),
                ])
            } ?? .null,
            // What the last reported band TOUCHED — distinct from the selection,
            // which under the shift chord is base ∪ hits.
            "hitIds": .array(arrangeMarqueeHits.map { .string($0.uuidString) }
                .sorted { a, b in (a.stringValue ?? "") < (b.stringValue ?? "") }),
            "selectedIds": .array(arrangeSelection.ids.map { .string($0.uuidString) }
                .sorted { a, b in (a.stringValue ?? "") < (b.stringValue ?? "") }),
            "count": .number(Double(arrangeSelection.count)),
            // `focusId` is the name m23-g3 specifies; `focusClipId` is the name
            // the three sibling arrange seams already use. Both, so neither a
            // gate written to the item nor one written to the house convention
            // has to guess.
            "focusId": arrangeSelection.focusID.map { .string($0.uuidString) } ?? .null,
            "focusClipId": arrangeSelection.focusID.map { .string($0.uuidString) } ?? .null,
            // The m23-e instrument: the clip the piano roll is ACTUALLY open on.
            // A marquee must never open it (see `ArrangeSelection.replace`).
            "editorClipId": openEditorClip.map { .string($0.id.uuidString) } ?? .null,
            "reportSeq": .number(Double(arrangeMarqueeReportSeq)),
        ])
    }

    /// Bounded wait for the TRACK LIST to confirm it applied a staged drag step
    /// (the `awaitMarqueeApplied` twin, m23-e echo-seam law). Stops the instant
    /// the list reports; hard-stops at the deadline when no list exists to
    /// report at all (the Mix workspace, or a session with no tracks).
    private func awaitTrackReorderApplied(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while trackReorderReportSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.trackHeaderDrag {act?, trackId?, y?}` — the m23-h staging seam for
    /// the ARRANGE track-header reorder drag. App-level, debug tier ONLY (off
    /// `allCommands`/MCP — ZERO wire growth: the drag's only domain effect is
    /// `track.reorder`, which IS on the wire, so a second agent-facing verb here
    /// would be a duplicate ordering authority).
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law). Answers the LADDER, which
    ///     is the point: `rowTops`/`rowHeights` are what a caller needs to
    ///     compute a drag, and both are unknowable from outside (a row grows
    ///     with its takes/automation sections; `rowHeight` is user-adjustable).
    ///     A caller MUST derive its fixture from these. A bare read NEVER stages
    ///     anything — a read that applied a degenerate drag would make a gate
    ///     vacuously green.
    ///   - `{act:"begin", trackId, y}` — pick that row up at pointer y.
    ///   - `{act:"changed", y}` — move the pointer; the landing is re-decided
    ///     every step, and NOTHING is committed (the order in `order` must not
    ///     move until release — that is the leg a one-shot seam cannot test).
    ///   - `{act:"end", y}` — release: commit the landing as ONE undo step.
    ///
    /// `y` is in the TRACK LIST's coordinate space — the same space the ladder
    /// is measured in and the live `DragGesture` reports in, so a fixture
    /// computed from `rowTops` is SCROLL-INVARIANT (the space scrolls with the
    /// rows). A staged step runs through the list's own `dragUpdate`/`dragEnd`,
    /// i.e. the very handlers the mouse drives; there is no seam-only path.
    ///
    /// Echoes GROUND TRUTH throughout: `order` is read back off the STORE,
    /// `targetIndex`/`indicatorY` are the landing the LIST resolved and is
    /// drawing, and the answer waits (bounded) for the list to confirm it
    /// applied before returning.
    private func trackHeaderDragDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let act = params["act"]?.stringValue {
            guard let action = TrackReorderStage.Action(rawValue: act) else {
                throw DebugError(
                    "unknown act \"\(act)\" — expected \"begin\", \"changed\", or \"end\"")
            }
            guard let yv = params["y"]?.doubleValue else {
                throw DebugError(
                    "act \"\(act)\" needs a track-list-space y (points, measured "
                    + "against the rowTops this command echoes)")
            }
            var stagedTrackID: UUID?
            if action == .begin {
                guard let raw = params["trackId"]?.stringValue else {
                    throw DebugError("act \"begin\" needs a 'trackId' — which row is picked up")
                }
                guard let parsed = UUID(uuidString: raw) else {
                    throw DebugError("'trackId' is not a valid UUID: \(raw)")
                }
                guard store.tracks.contains(where: { $0.id == parsed }) else {
                    throw DebugError("no track with id \(raw)")
                }
                stagedTrackID = parsed
            } else if params["trackId"] != nil {
                throw DebugError(
                    "only act \"begin\" takes a 'trackId' — \"changed\"/\"end\" "
                    + "continue the drag already in flight")
            }
            workspaceMode = .arrange
            let reportsBefore = trackReorderReportSeq
            trackReorderStage = TrackReorderStage(
                action: action, trackID: stagedTrackID, y: CGFloat(yv),
                nonce: (trackReorderStage?.nonce ?? 0) + 1)
            awaitTrackReorderApplied(after: reportsBefore)
        } else if params["y"] != nil || params["trackId"] != nil {
            throw DebugError("debug.trackHeaderDrag 'y'/'trackId' need an 'act'")
        }

        let drag = trackReorderDrag
        return .object([
            // The LADDER — the ground truth a fixture must be computed FROM.
            "rowTops": .array(trackRowLadder.tops.map { .number(Double($0)) }),
            "rowHeights": .array(trackRowLadder.heights.map { .number(Double($0)) }),
            "rowCount": .number(Double(trackRowLadder.count)),
            // The ORDER, read off the store — the only thing that finally
            // matters, and the leg that must NOT move until an "end".
            "order": .array(store.tracks.map { .string($0.id.uuidString) }),
            "names": .array(store.tracks.map { .string($0.name) }),
            // The drag in flight, as the LIST sees it. Null when idle.
            "dragTrackId": drag.map { .string($0.trackID.uuidString) } ?? .null,
            "fromIndex": drag?.drop.map { .number(Double($0.from)) } ?? .null,
            "targetIndex": drag?.drop.map { .number(Double($0.index)) } ?? .null,
            "moves": .bool(drag?.drop?.moves ?? false),
            // The line the list is DRAWING — non-null mid-drag is the only
            // positive proof the affordance exists; "gone after" alone passes
            // vacuously against an implementation that never drew one.
            "indicatorY": drag?.drop?.indicatorY.map { .number(Double($0)) } ?? .null,
            "offsetY": drag.map { .number(Double($0.offsetY)) } ?? .null,
            // Undo depth, so a gate can prove the whole gesture is ONE step
            // without a second round trip to `edit.history`.
            "undoDepth": .number(Double(store.undoHistory().undo.count)),
            "undoLabel": store.undoLabel.map { .string($0) } ?? .null,
            "reportSeq": .number(Double(trackReorderReportSeq)),
        ])
    }

    /// Bounded wait for the CONSOLE to confirm it applied a staged drag step
    /// (the `awaitTrackReorderApplied` twin). Stops the instant the console
    /// reports; hard-stops at the deadline when no console exists to report at
    /// all (the Arrange workspace, or a project with no tracks).
    private func awaitMixerStripDragApplied(after reportsBefore: Int) {
        let deadline = Date().addingTimeInterval(0.30)
        while mixerStripDragReportSeq == reportsBefore, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.005))
        }
    }

    /// `debug.mixerStripDrag {act?, trackId?, x?}` — the m23-z staging seam for
    /// the MIXER strip reorder drag. App-level, debug tier ONLY (off
    /// `allCommands`/MCP — ZERO wire growth: the drag's only domain effect is
    /// `track.reorder`, which IS on the wire, so a second agent-facing verb here
    /// would be a duplicate ordering authority).
    ///
    ///   - `{}` — READ-ONLY (the m11-a bare-read law). Answers the LADDER and
    ///     the VISUAL order, which is the point: `stripLefts`/`stripWidths` are
    ///     what a caller needs to compute a drag and are unknowable from outside
    ///     (the bus divider's width is its caption's INTRINSIC width, so exactly
    ///     one gap in the rack is not 10 pt). A caller MUST derive its fixture
    ///     from these. A bare read NEVER stages anything.
    ///   - `{act:"begin", trackId, x}` — pick that strip up at pointer x.
    ///   - `{act:"changed", x}` — move the pointer; the landing is re-decided
    ///     every step and NOTHING is committed (`order` must not move until
    ///     release — the leg a one-shot seam cannot test).
    ///   - `{act:"end", x}` — release: commit the landing as ONE undo step, or
    ///     commit NOTHING when the landing is visually inert.
    ///
    /// THE CONSOLE ONLY MEASURES ITSELF WHILE IT IS ON SCREEN, so a caller runs
    /// `ui.showMixer {show:true}` first. This command deliberately does NOT
    /// switch the workspace itself, not even on a staged step: the arrange twin's
    /// `workspaceMode = .arrange` is there because the arrange IS the default
    /// tab, whereas silently flipping the user's window into Mix would be a
    /// mutation hiding inside a debug read. Instead `workspaceMode` is echoed, so
    /// an empty ladder is diagnosable ("not rendered") rather than ambiguous with
    /// "no tracks".
    ///
    /// Echoes GROUND TRUTH throughout: `order` is read off the STORE,
    /// `visualOrder` off `MixerLayout`, and `targetVisualIndex`/
    /// `targetArrayIndex`/`indicatorX`/`partingOffsets` are what the console
    /// RESOLVED and is drawing. The answer waits (bounded) for the console to
    /// confirm it applied before returning.
    private func mixerStripDragDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if let act = params["act"]?.stringValue {
            guard let action = MixerStripDragStage.Action(rawValue: act) else {
                throw DebugError(
                    "unknown act \"\(act)\" — expected \"begin\", \"changed\", or \"end\"")
            }
            guard let xv = params["x"]?.doubleValue else {
                throw DebugError(
                    "act \"\(act)\" needs a strip-rack-space x (points, measured "
                    + "against the stripLefts this command echoes)")
            }
            var stagedTrackID: UUID?
            if action == .begin {
                guard let raw = params["trackId"]?.stringValue else {
                    throw DebugError("act \"begin\" needs a 'trackId' — which strip is picked up")
                }
                guard let parsed = UUID(uuidString: raw) else {
                    throw DebugError("'trackId' is not a valid UUID: \(raw)")
                }
                guard store.tracks.contains(where: { $0.id == parsed }) else {
                    throw DebugError("no track with id \(raw)")
                }
                stagedTrackID = parsed
            } else if params["trackId"] != nil {
                throw DebugError(
                    "only act \"begin\" takes a 'trackId' — \"changed\"/\"end\" "
                    + "continue the drag already in flight")
            }
            let reportsBefore = mixerStripDragReportSeq
            mixerStripDragStage = MixerStripDragStage(
                action: action, trackID: stagedTrackID, x: CGFloat(xv),
                nonce: (mixerStripDragStage?.nonce ?? 0) + 1)
            awaitMixerStripDragApplied(after: reportsBefore)
        } else if params["x"] != nil || params["trackId"] != nil {
            throw DebugError("debug.mixerStripDrag 'x'/'trackId' need an 'act'")
        } else if !mixerStripLadder.isWellFormed {
            // A read taken in the same turn as `ui.showMixer` would otherwise
            // answer "no strips" before the console's first layout has reported.
            // Waiting is not staging: nothing is mutated, the deadline is the
            // same 300 ms, and a genuinely empty project still returns promptly
            // ambiguity-free thanks to the `workspaceMode` echo.
            awaitMixerStripDragApplied(after: mixerStripDragReportSeq)
        }

        let drag = mixerStripDrag
        let visual = MixerLayout.orderedStrips(store.tracks)
        return .object([
            // The LADDER — the ground truth a fixture must be computed FROM.
            "stripLefts": .array(mixerStripLadder.lefts.map { .number(Double($0)) }),
            "stripWidths": .array(mixerStripLadder.widths.map { .number(Double($0)) }),
            "stripCount": .number(Double(mixerStripLadder.count)),
            // The console's VISUAL order (channels, then buses) — the thing the
            // user actually sees, and the order a mixer drag is judged against.
            "visualOrder": .array(visual.map { .string($0.id.uuidString) }),
            "visualNames": .array(visual.map { .string($0.name) }),
            // The ARRAY order, read off the store — the single ordering both
            // surfaces read, and the leg that must NOT move until an "end".
            "order": .array(store.tracks.map { .string($0.id.uuidString) }),
            "names": .array(store.tracks.map { .string($0.name) }),
            // Which tab is up: an empty ladder from Arrange means "not
            // rendered", not "no tracks".
            "workspaceMode": .string(workspaceMode.rawValue),
            // The drag in flight, as the CONSOLE sees it. Null when idle.
            "dragTrackId": drag.map { .string($0.trackID.uuidString) } ?? .null,
            "fromIndex": drag?.drop.map { .number(Double($0.from)) } ?? .null,
            "fromVisualIndex": drag?.drop.map { .number(Double($0.fromSlot)) } ?? .null,
            // THE INDEX TRANSLATION, both halves: the visual slot the pointer is
            // over, and the ARRAY index that slot's strip occupies. On an
            // all-channels-first project they are equal — which is exactly why a
            // gate needs a bus BETWEEN two channels.
            "targetVisualIndex": drag?.drop.map { .number(Double($0.targetSlot)) } ?? .null,
            "targetArrayIndex": drag?.drop.map { .number(Double($0.targetIndex)) } ?? .null,
            // Where the strip will actually END UP visually if released now —
            // the slot the line marks, which differs from `targetVisualIndex`
            // only when the landing crosses the channel/bus divider.
            "landingVisualIndex": drag?.drop?.landing.map { .number(Double($0.slot)) } ?? .null,
            // MOVES IS A VISUAL-ORDER FACT ON THIS SURFACE, not `index != from`:
            // an array move that leaves `channels ++ buses` reading the same is
            // inert, and draws no line, commits nothing, spends no undo step.
            "moves": .bool(drag?.drop?.moves ?? false),
            // The line the console is DRAWING — non-null mid-drag is the only
            // positive proof the affordance exists.
            "indicatorX": drag?.drop?.landing.map { .number(Double($0.indicatorX)) } ?? .null,
            "offsetX": drag.map { .number(Double($0.offsetX)) } ?? .null,
            // The parting distances the resting strips are rendered with, keyed
            // by VISUAL slot — straight out of `MixerStripReorder.partingOffsets`,
            // the same array the view offsets by. This is the only observable of
            // the per-index gap work other than a pixel.
            "partingOffsets": .array((drag?.partingOffsets ?? []).map { .number(Double($0)) }),
            // Undo depth, so a gate can prove the whole gesture is ONE step —
            // and that an inert landing is ZERO steps — without a second round
            // trip to `edit.history`.
            "undoDepth": .number(Double(store.undoHistory().undo.count)),
            "undoLabel": store.undoLabel.map { .string($0) } ?? .null,
            "reportSeq": .number(Double(mixerStripDragReportSeq)),
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

    /// `debug.explainFrames {ids?}` — reads back the MEASURED frame of every
    /// `.explainable` control currently in the tree, keyed by `ExplainID` to a list
    /// of rects (one per rendered instance, tree order) in the `explainRoot`
    /// coordinate space. READ-ONLY, always (the m11-a law): it stages nothing and
    /// touches neither the store nor the engine — it is the wire's window onto the
    /// geometry the live overlay already anchors cards on.
    ///
    /// **Why it exists.** A layout promise ("the fader sits at the same Y on every
    /// strip, whatever the insert count") can only be proven by measuring the real
    /// window; a gate that recomputed the budget would merely restate the code it is
    /// meant to check. Frames flow only while explain mode is on (or a tour step is
    /// active) — the reporter is inert otherwise — so a caller must `debug.explainMode
    /// {on:true}` first; the result says which state it read in (`explainActive`) so
    /// an empty dict is never mistaken for "the control is missing".
    ///
    /// App-level, debug tier ONLY — off `allCommands`/MCP (the `debug.explainMode`
    /// precedent: explain is UI chrome). Optional `ids` filters to the named
    /// `ExplainID`s; an unknown id teaches rather than returning silence.
    private func explainFrames(_ params: [String: JSONValue]) throws -> JSONValue {
        var wanted: Set<ExplainID>?
        if let raw = params["ids"]?.arrayValue {
            var ids: Set<ExplainID> = []
            for value in raw {
                guard let name = value.stringValue, let id = ExplainID(rawValue: name) else {
                    throw DebugError("unknown explain id \"\(value.stringValue ?? "?")\" — expected an ExplainID (e.g. \"mixerFader\")")
                }
                ids.insert(id)
            }
            wanted = ids
        }
        var out: [String: JSONValue] = [:]
        for (id, rects) in explainCoordinator.frames where wanted?.contains(id) ?? true {
            out[id.rawValue] = .array(rects.map { rect in
                .object([
                    "x": .number(Double(rect.minX)),
                    "y": .number(Double(rect.minY)),
                    "width": .number(Double(rect.width)),
                    "height": .number(Double(rect.height)),
                ])
            })
        }
        return .object([
            "explainActive": .bool(explain.isActive),
            "tourStep": .bool(onboarding.currentStep != nil),
            "frames": .object(out),
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

    /// `debug.insertSpectrumSeed {bands?, levelDB?, peakDB?, centroidHz?, flux?, clear?}`
    /// — the `debug.vibeSeed` twin for the m23-r3 PER-INSERT spectrum: stages a
    /// synthetic snapshot the open TRACK EQ card's spectrum layer prefers over
    /// its live `store.insertAnalysis` poll, so a capture / E2E gets a
    /// deterministic silhouette without real audio. App-level, debug tier ONLY
    /// — off `allCommands`/MCP (it's UI chrome; agents drive the real audio
    /// path). The ENGINE is never touched, and the ARM is not faked either: a
    /// seeded card is still armed by the layer's `.task`, so seeding proves
    /// PIXELS, never liveness. `{clear: true}` drops back to the live poll.
    ///
    /// Deliberately separate from `vibeSeed`, which stays the MASTER card's (and
    /// the vibe meter's) override: the two curves are different measurements —
    /// master POST-fader over the whole mix, a strip insert PRE-fader — so one
    /// seed must never stage both.
    private func setInsertSpectrumSeed(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["clear"]?.boolValue == true {
            insertSpectrumSeed = nil
            return .object(["cleared": .bool(true)])
        }
        let bandCount = MasterAnalysisSnapshot.bandCount
        var bands = [Float](repeating: -30, count: bandCount)
        if let raw = params["bands"]?.arrayValue {
            guard raw.count == bandCount else {
                throw DebugError("debug.insertSpectrumSeed bands must have exactly \(bandCount) values (got \(raw.count))")
            }
            bands = raw.map { Float($0.doubleValue ?? Double(MasterAnalysisSnapshot.floorDB)) }
        }
        let levelDB = params["levelDB"]?.doubleValue.map(Float.init) ?? -10
        let peakDB = params["peakDB"]?.doubleValue.map(Float.init) ?? (levelDB + 4)
        let centroidHz = params["centroidHz"]?.doubleValue.map(Float.init) ?? 2000
        let flux = params["flux"]?.doubleValue.map(Float.init) ?? 0.3
        let snapshot = MasterAnalysisSnapshot(bands: bands, levelDB: levelDB, peakDB: peakDB,
                                              centroidHz: centroidHz, flux: flux)
        insertSpectrumSeed = snapshot
        return .object([
            "levelDB": .number(Double(levelDB)),
            "peakDB": .number(Double(peakDB)),
            "centroidHz": .number(Double(centroidHz)),
            "flux": .number(Double(flux)),
            "bands": .array(bands.map { .number(Double($0)) }),
        ])
    }

    /// `debug.scopeSeed {preset?, left?, right?, correlation?, width?, balance?, clear?}`
    /// — stages a synthetic goniometer frame + stereo scalars the master strip's
    /// stereo-image block prefers over the live polls, so a capture / E2E can show a
    /// deterministic figure without real audio (the `debug.vibeSeed` staging
    /// precedent). App-level, debug tier ONLY — off `allCommands`/MCP (it's UI
    /// chrome; agents drive the real audio path, and scope pairs stay off the wire
    /// by the m22-d law). The ENGINE is never touched — this only sets `scopeSeed`;
    /// `{clear: true}` drops the override back to the live polls.
    ///
    /// `preset` names a deterministic figure (`silence | mono | antiPhase | cloud |
    /// hardLeft | hardRight`, default `mono` — pure sine constructions, headless in
    /// `DAWAppKit.StereoScopePreset`); `left`/`right` (given together, exactly 256
    /// values each) override the frame sample-exact; `correlation`/`width`/`balance`
    /// override the preset's scalars. Returns the seeded scalars + pair count (NOT
    /// the 512 floats — a deliberate slimming of the `vibeSeed` full echo).
    private func setScopeSeed(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["clear"]?.boolValue == true {
            scopeSeed = nil
            return .object(["cleared": .bool(true)])
        }
        var preset = StereoScopePreset.mono
        if let raw = params["preset"]?.stringValue {
            guard let named = StereoScopePreset(rawValue: raw) else {
                let valid = StereoScopePreset.allCases.map(\.rawValue).joined(separator: ", ")
                throw DebugError("unknown scope preset \"\(raw)\" — expected one of: \(valid)")
            }
            preset = named
        }
        var seed = preset.seed()
        let left = params["left"]?.arrayValue
        let right = params["right"]?.arrayValue
        if left != nil || right != nil {
            let pairCount = MasterScopeFrame.pairCount
            guard let left, let right else {
                throw DebugError("debug.scopeSeed left/right must be given together")
            }
            guard left.count == pairCount, right.count == pairCount else {
                throw DebugError("debug.scopeSeed left/right must each have exactly \(pairCount) values (got \(left.count)/\(right.count))")
            }
            seed.frame = MasterScopeFrame(
                left: left.map { Float($0.doubleValue ?? 0) },
                right: right.map { Float($0.doubleValue ?? 0) })
        }
        if let correlation = params["correlation"]?.doubleValue { seed.correlation = Float(correlation) }
        if let width = params["width"]?.doubleValue { seed.width = Float(width) }
        if let balance = params["balance"]?.doubleValue { seed.balance = Float(balance) }
        scopeSeed = seed
        return .object([
            "preset": .string(preset.rawValue),
            "correlation": .number(Double(seed.correlation)),
            "width": .number(Double(seed.width)),
            "balance": .number(Double(seed.balance)),
            "pairs": .number(Double(MasterScopeFrame.pairCount)),
        ])
    }

    /// `debug.liveLayers {reset?}` — reports the **live-layer tick witness**
    /// (m23-r3b): for each continuously-redrawing meter, how many frames it has
    /// DRAWN and the values it drew on the last one. `reset: true` zeroes the
    /// counts (keeping the values) so a caller can measure "frames since now".
    ///
    /// This is the only probe that can see the m22-e poll-discipline failure.
    /// A layer paused on window-inactive is pixel-identical to a live one until
    /// the data moves, so the check that matters is: hold focus ELSEWHERE,
    /// change the seed, and prove the DRAWN value followed. A frozen layer
    /// reports `ticks: 0` beside a stale value; a live one reports both moving.
    ///
    /// `appActive` is the measurement's own precondition, not decoration: it is
    /// what `controlActiveState` follows, so a focus-theft harness that silently
    /// failed (no automation permission, an app that refuses to yield) would
    /// otherwise produce a green run that proves nothing at all. Assert it
    /// FALSE in any leg whose claim is about the unfocused case.
    ///
    /// `mixerVisible` / `scopeShown` are CONTEXT for whoever reads the payload —
    /// the two gates the block's call site reads (`workspaceMode == .mix`, and
    /// the goniometer well being Pro-only). The load-bearing claims are the
    /// counts and the drawn values; presence proves itself, because a layer that
    /// is not on screen cannot tick.
    /// `debug.insertLabels {reset?, resetBarTicks?}` — reports every mixer
    /// insert row's DRAWN name (m23-s), keyed by effect id, plus each row's
    /// gain-reduction underline reading. App-level, debug tier ONLY — off
    /// `allCommands`/MCP (the `debug.liveLayers` / `debug.explainFrames`
    /// precedent: this is UI geometry, and agents drive the protocol directly).
    ///
    /// **Every field is a measurement, not a re-derivation.** `label` is the
    /// string the `Text` was built from, `pinned` is the argument handed to
    /// `.fixedSize(horizontal:)`, `drawn` is that `Text`'s own frame, `intrinsic`
    /// is the same string's single-line ideal measured by a hidden twin built by
    /// the same builder, and `line` is the name line's own width. A probe that
    /// recomputed `effectDisplayName` and compared it against a layout constant
    /// would agree with itself while the view truncated — the m23-p2 law.
    ///
    /// Derived, but only from those measurements: `available = line − originX`
    /// (exact on a built-in row, which carries no trailing chrome; an AU row's
    /// glyph makes it an over-estimate there, which is why the AU leg asserts
    /// `truncated`, not `available`), and `truncated = intrinsic > drawn`.
    ///
    /// `{reset:true}` drops every reading — for a gate that rebuilt a chain and
    /// must not read a removed insert's stale row. `{resetBarTicks:true}` zeroes
    /// the underline tick counts and KEEPS their last drawn values, so
    /// `ticks == 0` beside a live value stays the freeze signature.
    private func insertLabelsDebug(_ params: [String: JSONValue]) -> JSONValue {
        if params["reset"]?.boolValue == true { insertLabels.clear() }
        if params["resetBarTicks"]?.boolValue == true { insertLabels.resetBarTicks() }
        let rows: [JSONValue] = insertLabels.labels.values
            .sorted { $0.label < $1.label }
            .map { reading in
                let line = insertLabels.lines[reading.effectID]
                let intrinsic = insertLabels.intrinsics[reading.effectID]
                var fields: [String: JSONValue] = [
                    "effectId": .string(reading.effectID.uuidString),
                    "trackId": reading.trackID.map { JSONValue.string($0.uuidString) } ?? .null,
                    "chain": .string(reading.trackID == nil ? "master" : "track"),
                    "kind": .string(reading.kind),
                    "label": .string(reading.label),
                    "pinned": insertLabels.pins[reading.effectID].map { JSONValue.bool($0) } ?? .null,
                    "drawn": .number(Double(reading.drawnWidth)),
                    "originX": .number(Double(reading.originX)),
                    "intrinsic": intrinsic.map { JSONValue.number(Double($0)) } ?? .null,
                    "line": line.map { JSONValue.number(Double($0)) } ?? .null,
                ]
                if let intrinsic {
                    fields["truncated"] = .bool(intrinsic > reading.drawnWidth + 0.5)
                }
                if let line {
                    fields["available"] = .number(Double(max(0, line - reading.originX)))
                    fields["overflows"] = .bool(reading.originX + reading.drawnWidth > line + 0.5)
                }
                if let bar = insertLabels.bars[reading.effectID] {
                    fields["bar"] = .object([
                        "ticks": .number(Double(bar.ticks)),
                        "fraction": .number(bar.fraction),
                        "width": .number(Double(bar.width)),
                    ])
                }
                return .object(fields)
            }
        return .object([
            "appActive": .bool(NSApplication.shared.isActive),
            "mixerVisible": .bool(workspaceMode == .mix),
            "mixerDensity": .string(
                panelDensity.density(forPanel: MixerView.panelID) == .pro ? "pro" : "simple"),
            "rows": .array(rows),
        ])
    }

    /// `debug.pianoRollBarOps {reset?}` — reports the piano-roll header's
    /// bar-ops readout exactly as it was DRAWN (m23-t). App-level, debug tier
    /// ONLY — off `allCommands`/MCP (this is UI ink, and agents drive the
    /// protocol directly; the `debug.grSeed`/`debug.scopeSeed` tier rule). A
    /// bare call is READ-ONLY (the m11-a law); `{reset:true}` drops the ledger
    /// so a gate that closed the editor cannot read a stale row.
    ///
    /// `roles` carries what the view PUBLISHED FROM INSIDE its own
    /// `Text(...)`/`.foregroundStyle(...)` arguments — the string is the string
    /// `Text` was built from and the ink is that colour resolved to sRGB hex,
    /// not the token name it was meant to be. A role present with a null half
    /// means a call site was replaced by a literal, and that is a FAILURE for
    /// whoever reads this, never something to skip over.
    ///
    /// `inkTokens` is the REFERENCE side, named rather than measured, so no gate
    /// has to hardcode the palette to say which token was used. `playback` is
    /// listed first because it is the one this readout must never wear again:
    /// cyan is the transport playhead in this very view, and the bar number is
    /// the +/− buttons' operand, not a position.
    ///
    /// Deliberately NOT reported: the target bar as an Int. The DRAWN STRING is
    /// the claim; a number re-derived here would agree with itself while the
    /// header drew something else. A caller wanting the bar reads it out of the
    /// string, and asserts the transport independently through
    /// `project.overview` — a different subsystem.
    private func pianoRollBarOpsDebug(_ params: [String: JSONValue]) -> JSONValue {
        if params["reset"]?.boolValue == true { pianoRollBarOpsStyle.clear() }
        let roles: [String: JSONValue] = pianoRollBarOpsStyle.entries.mapValues { entry in
            JSONValue.object([
                "text": entry.text.map { JSONValue.string($0) } ?? .null,
                "ink": entry.ink.map { JSONValue.string($0) } ?? .null,
            ])
        }
        return .object([
            // The SAME gate `ContentView` puts the roll behind (`openEditorClip`,
            // which additionally requires the clip to be MIDI) — not the looser
            // `selectedClipID != nil`, which is true with an AUDIO clip selected
            // and no roll on screen. On a cycle about a field claiming more than
            // it measures, this one does not get to.
            "editorOpen": .bool(openEditorClip != nil),
            "density": .string(
                panelDensity.density(forPanel: PianoRollView.panelID) == .pro ? "pro" : "simple"),
            "roles": .object(roles),
            // How many times the cluster REPORTED since the last reset (two per
            // body — the string and the ink — so this is not a frame count), and
            // how many of those cost an `NSColor` resolution. This readout sits
            // in a view fed `positionBeats`, so it redraws while the transport
            // runs (0 reports idle over 2 s, 118 over 2.007 s playing = 59
            // bodies, ~29 redraws/s), and drawing
            // code does not get to allocate per frame. `inkResolutions` must
            // stay FLAT while `ticks` climbs — that gap IS the memo, and it is
            // unobservable from outside without these two numbers.
            "ticks": .number(Double(pianoRollBarOpsStyle.ticks)),
            "inkResolutions": .number(Double(pianoRollBarOpsStyle.inkResolutions)),
            "inkTokens": .object([
                "playback": .string(DAWTheme.hexString(DAWTheme.playback)),
                "textPrimary": .string(DAWTheme.hexString(DAWTheme.textPrimary)),
                "textDim": .string(DAWTheme.hexString(DAWTheme.textDim)),
                "textFaint": .string(DAWTheme.hexString(DAWTheme.textFaint)),
                "ai": .string(DAWTheme.hexString(DAWTheme.ai)),
            ]),
        ])
    }

    private func liveLayersDebug(_ params: [String: JSONValue]) -> JSONValue {
        if params["reset"]?.boolValue == true { liveLayers.resetTicks() }
        let isPro = panelDensity.density(forPanel: MixerView.panelID) == .pro
        let mixerVisible = workspaceMode == .mix
        let vibe = liveLayers.vibe
        let trail = liveLayers.trail
        let readouts = liveLayers.readouts
        return .object([
            "appActive": .bool(NSApplication.shared.isActive),
            "mixerVisible": .bool(mixerVisible),
            "mixerDensity": .string(isPro ? "pro" : "simple"),
            "scopeShown": .bool(mixerVisible && isPro),
            "readoutsShown": .bool(mixerVisible),
            "vibe": .object([
                "ticks": .number(Double(vibe.ticks)),
                "brightness": .number(vibe.brightness),
                "hue": .number(vibe.hue),
                "motion": .number(vibe.motion),
                "dormant": .bool(vibe.isDormant),
            ]),
            "trail": .object([
                "ticks": .number(Double(trail.ticks)),
                "points": .number(Double(trail.points)),
                "calm": .bool(trail.calm),
                "zone": .string(trail.zone.rawValue),
            ]),
            "readouts": .object([
                "ticks": .number(Double(readouts.ticks)),
                "correlation": .number(readouts.correlation),
                "width": .number(readouts.width),
                "balance": .number(readouts.balance),
                "zone": .string(readouts.zone.rawValue),
            ]),
        ])
    }

    /// `debug.grSeed {db?, effectId?, clear?}` — stages a synthetic
    /// gain-reduction reading the GR meters (the dynamics editor cards' GAIN
    /// REDUCTION block + the insert chips' mini-bar, m22-e) prefer over the
    /// live store polls, so a headless capture / E2E shows a working meter
    /// deterministically (the `debug.scopeSeed` staging precedent). App-level,
    /// debug tier ONLY — off `allCommands`/MCP (it's UI chrome; agents read
    /// the real per-effect `gainReductionDb` off the wire snapshot). The
    /// ENGINE is never touched — this only sets `grSeed`; `{clear: true}`
    /// drops the override back to the live polls.
    ///
    /// `db` is the POSITIVE dB of reduction (clamped to 0…80, mirroring the
    /// engine cap — 80 pins a gate's meter as CLOSED). `effectId` (optional)
    /// targets ONE insert — every other meter keeps its live poll; omitted =
    /// a BLANKET seed (every dynamics meter shows `db`). Non-dynamics kinds
    /// never grow a meter, seeded or not.
    private func setGRSeed(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["clear"]?.boolValue == true {
            grSeed = nil
            return .object(["cleared": .bool(true)])
        }
        guard let raw = params["db"]?.doubleValue else {
            throw DebugError("debug.grSeed needs db (positive dB of gain reduction) or {clear: true}")
        }
        guard raw.isFinite, raw >= 0 else {
            throw DebugError("debug.grSeed db must be a finite dB value ≥ 0 (got \(raw))")
        }
        var effectID: UUID?
        if let idRaw = params["effectId"]?.stringValue {
            guard let id = UUID(uuidString: idRaw) else {
                throw DebugError("debug.grSeed effectId must be a UUID (got \"\(idRaw)\")")
            }
            effectID = id
        }
        let seed = GainReductionSeed(
            db: min(raw, GainReductionMeterModel.engineCapDb), effectID: effectID)
        grSeed = seed
        return .object([
            "db": .number(seed.db),
            "effectId": seed.effectID.map { JSONValue.string($0.uuidString) } ?? .null,
        ])
    }

    /// `debug.referenceSeed {slot?, name?, path?, offsetSeconds?, trimDb?,
    /// analysis?, integratedLufs?, truePeakDbtp?, loudnessRangeLu?,
    /// monitoring?, matchGainDb?, matchBasis?, ceilingLimited?,
    /// wouldMatchGainDb?, fileMissing?, mix?, mixLufs?, mixTruePeakDbtp?,
    /// mixLra?, panel?, clear?}` — stages the master strip's REFERENCE row and
    /// the REFERENCE panel for a capture / E2E (m22-g P3, the `debug.scopeSeed`
    /// / `debug.grSeed` staging precedent). App-level, **debug tier ONLY** —
    /// off `allCommands`/MCP: agents drive the real `reference.*` commands, and
    /// this only overrides what the two VIEWS read. The STORE and the ENGINE
    /// are never touched: seeding creates no journaled edit, no dirty flag, no
    /// undo entry — which is what makes an unseeded capture honest evidence
    /// that the live polls tick.
    ///
    /// A **bare call is READ-ONLY** (the m11-a law): it echoes the current
    /// staging state and never opens the panel or invents a slot.
    ///
    /// Calls are **INCREMENTAL**: every staged field is carried forward from the
    /// previous seed unless the new call overrides it, so a gate can stage the
    /// facts in one call and the view state in the next. This holds for the
    /// analysis loudness (`integratedLufs`/`truePeakDbtp`/`loudnessRangeLu`) and
    /// the mix loudness (`mixLufs`/`mixTruePeakDbtp`/`mixLra`) exactly as it
    /// does for the slot's `name`/`path`/`offsetSeconds`/`trimDb`. Only `slot:
    /// false`, `analysis: false`, `mix: false` and `clear: true` DROP state, and
    /// each says so by name.
    ///
    /// - `slot` (bool, default true once any slot field is given): `false`
    ///   stages the EMPTY state even when the project holds a real reference.
    ///   `name`/`path`/`offsetSeconds`/`trimDb` shape it.
    /// - `analysis` (bool, default true): `false` stages the never-analyzed
    ///   slot; the three loudness overrides tune the deterministic sample
    ///   curve from `ReferenceSeed.sampleAnalysis`.
    /// - `monitoring` + `matchGainDb`/`matchBasis`/`ceilingLimited`/
    ///   `wouldMatchGainDb` stage the A/B chip and the match readout.
    /// - `mix` (bool, default true when `monitoring` or any mix field is set)
    ///   stages the mix side of the comparison from
    ///   `ReferenceSeed.sampleMixAnalysis`; `mixLufs`/`mixTruePeakDbtp`/`mixLra`
    ///   fill the loudness deltas that no live meter would supply in a silent
    ///   staged app. `mix: false` stages the no-evidence case (every loudness
    ///   delta reads the honest em-dash).
    /// - `fileMissing` stages the missing-file phase without touching disk.
    /// - `panel` opens/closes the card. `{clear: true}` drops the override back
    ///   to the live store polls (and closes the panel).
    private func setReferenceSeed(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["clear"]?.boolValue == true {
            referenceSeed = nil
            referencePanel.close()
            return .object(["cleared": .bool(true)])
        }
        let stagingKeys: Set<String> = [
            "slot", "name", "path", "offsetSeconds", "trimDb", "analysis",
            "integratedLufs", "truePeakDbtp", "loudnessRangeLu", "monitoring",
            "matchGainDb", "matchBasis", "ceilingLimited", "wouldMatchGainDb",
            "fileMissing", "mix", "mixLufs", "mixTruePeakDbtp", "mixLra", "panel",
        ]
        // Unknown keys teach FIRST — before the bare-read fallthrough, or a
        // typo'd param would be silently swallowed as "no staging keys given"
        // and answered with a read-only echo (caught by the P3 gate's C7 leg).
        for key in params.keys where !stagingKeys.contains(key) && key != "clear" {
            throw DebugError("debug.referenceSeed: unknown key \"\(key)\" — valid keys: "
                             + stagingKeys.sorted().joined(separator: ", ") + ", clear")
        }
        // Bare call: read-only echo (the m11-a law).
        guard params.keys.contains(where: { stagingKeys.contains($0) }) else {
            return referenceSeedResponse()
        }

        var seed = referenceSeed ?? ReferenceSeed()
        let wantsSlot = params["slot"]?.boolValue ?? true
        if wantsSlot {
            let wantsAnalysis = params["analysis"]?.boolValue ?? true
            var analysis: ReferenceAnalysis?
            if wantsAnalysis {
                // Carried forward exactly like the slot's name/path/offset/trim
                // below: param → the previously seeded analysis → the literal
                // default. Rebuilding from defaults would make a two-step stage
                // (facts first, then panel/mix keys) silently discard the facts.
                let previous = seed.slot?.analysis
                analysis = ReferenceSeed.sampleAnalysis(
                    integratedLufs: params["integratedLufs"]?.doubleValue
                        ?? previous?.integratedLufs ?? -9.4,
                    truePeakDbtp: params["truePeakDbtp"]?.doubleValue
                        ?? previous?.truePeakDbtp ?? -0.9,
                    loudnessRangeLu: params["loudnessRangeLu"]?.doubleValue
                        ?? previous?.loudnessRangeLu ?? 5.2)
            }
            seed.slot = ReferenceSlot(
                id: seed.slot?.id ?? UUID(),
                name: params["name"]?.stringValue ?? seed.slot?.name ?? "Seeded Reference",
                sourcePath: params["path"]?.stringValue ?? seed.slot?.sourcePath
                    ?? "/Users/Shared/DAWPro/References/Seeded Reference.wav",
                offsetSeconds: params["offsetSeconds"]?.doubleValue ?? seed.slot?.offsetSeconds ?? 0,
                trimDb: params["trimDb"]?.doubleValue ?? seed.slot?.trimDb ?? 0,
                analysis: analysis)
        } else {
            seed.slot = nil
        }

        let monitoring = params["monitoring"]?.boolValue ?? seed.status.monitoring
        let ceilingLimited = params["ceilingLimited"]?.boolValue
            ?? (monitoring ? (seed.status.ceilingLimited ?? false) : nil)
        let matchGainDb = params["matchGainDb"]?.doubleValue
            ?? (monitoring ? (seed.status.matchGainDb ?? -4.6) : nil)
        let matchBasis = params["matchBasis"]?.stringValue
            ?? (monitoring ? (seed.status.matchBasis ?? "liveIntegrated") : nil)
        seed.status = ReferenceStatus(
            reference: seed.slot,
            monitoring: monitoring,
            wouldMatchGainDb: params["wouldMatchGainDb"]?.doubleValue
                ?? matchGainDb ?? seed.status.wouldMatchGainDb,
            matchGainDb: matchGainDb,
            matchBasis: matchBasis,
            ceilingLimited: ceilingLimited)

        seed.fileMissing = params["fileMissing"]?.boolValue ?? seed.fileMissing

        let mixFieldGiven = params["mixLufs"] != nil || params["mixTruePeakDbtp"] != nil
            || params["mixLra"] != nil
        let wantsMix = params["mix"]?.boolValue
            ?? (mixFieldGiven || monitoring || seed.mixAnalysis != nil)
        if wantsMix {
            // Same three-deep carry as the analysis above, computed ONCE per
            // field — repeating the chain inline is how the earlier
            // rebuild-from-defaults inconsistency got in.
            let mixLufs = params["mixLufs"]?.doubleValue
                ?? seed.mixLive?.integratedLufs ?? -12.8
            let mixLra = params["mixLra"]?.doubleValue
                ?? seed.mixLive?.loudnessRangeLu ?? 7.6
            let mixTruePeak = params["mixTruePeakDbtp"]?.doubleValue
                ?? seed.mixLive?.truePeakDbtp ?? -2.4
            seed.mixAnalysis = ReferenceSeed.sampleMixAnalysis()
            seed.mixLive = LiveLoudnessSnapshot(
                momentaryLufs: mixLufs,
                shortTermLufs: mixLufs,
                integratedLufs: mixLufs,
                loudnessRangeLu: mixLra,
                truePeakDbtp: mixTruePeak,
                secondsAnalyzed: 42)
        } else {
            seed.mixAnalysis = nil
            seed.mixLive = nil
        }

        referenceSeed = seed
        if let open = params["panel"]?.boolValue {
            open ? referencePanel.open() : referencePanel.close()
        }
        // Re-evaluate the staged file state for an already-open panel.
        referencePanel.refreshFileState()
        return referenceSeedResponse()
    }

    /// The `debug.referenceSeed` echo — the staged facts a capture gate asserts
    /// on, deliberately WITHOUT the two 24-value band arrays (the `scopeSeed`
    /// slimming rule).
    private func referenceSeedResponse() -> JSONValue {
        guard let seed = referenceSeed else {
            return .object([
                "seeded": .bool(false),
                "panel": .bool(referencePanel.isOpen),
                "phase": .string(referencePanel.phase.rawValue),
            ])
        }
        return .object([
            "seeded": .bool(true),
            "panel": .bool(referencePanel.isOpen),
            "phase": .string(referencePanel.phase.rawValue),
            "slot": seed.slot.map { JSONValue.string($0.name) } ?? .null,
            "analyzed": .bool(seed.slot?.analysis != nil),
            "offsetSeconds": .number(seed.slot?.offsetSeconds ?? 0),
            "trimDb": .number(seed.slot?.trimDb ?? 0),
            "monitoring": .bool(seed.status.monitoring),
            "matchGainDb": seed.status.matchGainDb.map { JSONValue.number($0) } ?? .null,
            "matchBasis": seed.status.matchBasis.map { JSONValue.string($0) } ?? .null,
            "ceilingLimited": seed.status.ceilingLimited.map { JSONValue.bool($0) } ?? .null,
            "fileMissing": .bool(seed.fileMissing),
            "mixIntegratedLufs": seed.mixLive?.integratedLufs.map { JSONValue.number($0) } ?? .null,
            "mixBands": .bool(seed.mixAnalysis != nil),
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

    // MARK: - File import (beta m10-k; MIDI m23-k4b) — File→Import + drag-drop

    /// The ONE execution path behind EVERY human import affordance (File→Import
    /// Audio… / Import MIDI…, the arrange drag-drop) and the `debug.importAudio`
    /// staging command. Builds the headless `AudioImportPlan` from the live grid +
    /// the given context, maps its audio actions onto `store.importAudioBatch`
    /// (ONE undo step) and its MIDI members onto `store.importMIDIFile`, and
    /// returns per-file results (imported clip/track, or a readable error) in
    /// input order.
    ///
    /// `targetTrackID` is the hovered/target track (its KIND is resolved here from
    /// the store, so callers pass only the id); a nil / non-audio target routes to
    /// new tracks, and multiple files always fan out — all decided by the plan.
    /// `startBeat` is ALREADY resolved (m23-f): the arrange drop passes the very
    /// value its drop line was drawn at, and the menu / `debug.importAudio` paths
    /// build theirs through `resolvedImportBeat(...)` — the same one home, with no
    /// magnets, since neither has a lane under a pointer. A `.mid` in the set
    /// lands on that SAME beat (m23-k4b), carried in `MIDIImportAction`.
    ///
    /// UNDO COST, stated because it is observable: the audio members cost ONE
    /// step for the whole batch, and EACH MIDI file costs one more —
    /// `importMIDIFile` owns its own `performEdit` (it has to: tempo/meter
    /// adoption folds into that same edit). A mixed `.wav` + `.mid` drop is
    /// therefore TWO undo steps, not one. Folding them would mean reopening
    /// k3's transaction boundary, which m23-g1's atomicity work sits on.
    @discardableResult
    func importFiles(urls: [URL], targetTrackID: UUID?,
                     startBeat: ResolvedDropBeat) -> [AudioImportFileResult] {
        let targetKind = targetTrackID.flatMap { id in
            store.tracks.first(where: { $0.id == id })?.kind
        }
        let context = AudioImportContext(
            targetTrackID: targetTrackID, targetTrackKind: targetKind,
            startBeat: startBeat)
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
        // Skipped entirely for a MIDI-ONLY import: `importAudioBatch` returns []
        // for an empty request list, but only AFTER its `mediaServiceUnavailable`
        // precondition — so calling it with nothing to do could manufacture an
        // error for an import that has no audio in it at all.
        if !requests.isEmpty {
            do {
                for outcome in try store.importAudioBatch(requests) { outcomeByURL[outcome.url] = outcome }
            } catch {
                batchError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }

        // Each MIDI file is its own store call, and its own undo step — see the
        // note above. The report's FIRST imported part supplies the anchor ids;
        // `tracksCreated` carries the rest of the truth.
        var midiResultByURL: [URL: AudioImportFileResult] = [:]
        for midi in plan.midiImports {
            do {
                let report = try store.importMIDIFile(path: midi.url.path, atBeat: midi.startBeat)
                let landed = report.parts.first { $0.imported && $0.clipID != nil }
                midiResultByURL[midi.url] = AudioImportFileResult(
                    path: midi.url.path, clipID: landed?.clipID, trackID: landed?.trackID,
                    trackName: landed?.name, tracksCreated: report.tracksCreated)
            } catch {
                midiResultByURL[midi.url] = AudioImportFileResult(
                    path: midi.url.path,
                    error: (error as? LocalizedError)?.errorDescription
                        ?? error.localizedDescription)
            }
        }

        var rejectedByURL: [URL: String] = [:]
        for rejection in plan.rejected { rejectedByURL[rejection.url] = rejection.reason }

        // Preserve the caller's input order for a readable per-file report.
        return urls.map { url in
            if let reason = rejectedByURL[url] {
                return AudioImportFileResult(path: url.path, error: reason)
            }
            if let midiResult = midiResultByURL[url] { return midiResult }
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

    /// Resolves a NON-DROP import beat (the File→Import menu at the playhead, or
    /// `debug.importAudio`'s `atBeat`) through the SAME one home the arrange drop
    /// uses — the arrange effective snap (Bar in Simple), the live meter map, the
    /// live zoom, and NO magnets, because neither caller has a lane under a
    /// pointer to magnetise to. Routing every caller through `resolve` is what
    /// keeps `ResolvedDropBeat`'s private initializer meaningful rather than
    /// decorative.
    func resolvedImportBeat(rawBeat: Double) -> ResolvedDropBeat {
        ArrangeDropSnap.resolve(
            rawBeat: rawBeat,
            snap: ClipSnap.effective(
                density: panelDensity.density(forPanel: TimelineLanesView.panelID),
                picked: clipSnap),
            meterMap: store.transport.meterMap,
            pixelsPerBeat: Double(arrangePPB))
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
        let results = importFiles(urls: urls, targetTrackID: targetTrackID,
                                  startBeat: resolvedImportBeat(rawBeat: atBeat))
        return .object(["results": .array(results.map(Self.encodeImportResult))])
    }

    /// One encoding for a per-file import result, shared by `debug.importAudio`
    /// and `debug.arrangeDrop` so the two seams cannot describe the same value
    /// differently. `tracksCreated` appears only for a MIDI member (m23-k4b),
    /// where the anchor `trackId`/`clipId` name just the first imported part.
    private static func encodeImportResult(_ result: AudioImportFileResult) -> JSONValue {
        var object: [String: JSONValue] = ["path": .string(result.path)]
        if let clipID = result.clipID { object["clipId"] = .string(clipID.uuidString) }
        if let trackID = result.trackID { object["trackId"] = .string(trackID.uuidString) }
        if let trackName = result.trackName { object["trackName"] = .string(trackName) }
        if let error = result.error { object["error"] = .string(error) }
        if let tracksCreated = result.tracksCreated {
            object["tracksCreated"] = .number(Double(tracksCreated))
        }
        return .object(object)
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

    // MARK: - Voice panel actions (m10-p-5)

    /// Opens/closes the Voice panel (header VOICE chip). Opening rescans the
    /// local datasets and kicks a sidecar re-probe so the banner is current.
    func toggleVoicePanel() {
        showVoicePanel.toggle()
        if showVoicePanel {
            voicePanel.rescanDatasets()
            Task { await voicePanel.refreshSidecar() }
        }
    }

    /// Opens the "Convert to Voice…" sheet on an audio clip (the clip context
    /// menu / `debug.voicePanel`). Fresh transient state each open.
    func openVoiceConvert(clipID: UUID) {
        voicePanel.resetConvertState()
        workspaceMode = .arrange
        voiceConvertClipID = clipID
    }

    /// Closes the convert sheet and clears its transient state.
    func closeVoiceConvert() {
        voiceConvertClipID = nil
        voicePanel.resetConvertState()
    }

    // MARK: - Voice panel debug command (m10-p-5, capture support)

    /// `debug.voicePanel {open?, close?, sidecarState?, sidecarMessage?,
    /// startingForSeconds?, sidecarClear?, seedVoices?, refreshVoices?,
    /// rescan?, createVoice?, sampleVoice?+samplePath?/sampleClip?, train?,
    /// convertSheet?, convertGo?+convertVoiceId?+convertPitch?, closeSheet?}`
    /// — stages the Voice panel + convert sheet for captures/E2E (app-level,
    /// debug tier — off `allCommands`/MCP, the `debug.instrumentPicker`
    /// precedent). Async paths (`refreshVoices`/`train`/`convertGo`) kick a
    /// Task through the SAME model methods the live UI calls and echo state —
    /// the caller sleeps/re-reads (the `debug.sketchpadGenerate` cadence). A
    /// bare call is READ-ONLY (echoes state, never re-opens — the m11-a law).
    private func voicePanelDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["open"]?.boolValue == true {
            workspaceMode = .arrange
            showVoicePanel = true
            voicePanel.rescanDatasets()
        }
        if params["close"]?.boolValue == true { showVoicePanel = false }

        // Sidecar seeding (the `debug.sidecarSeed` idiom, for banner states a
        // capture can't wait for) / clear = re-probe the real manager.
        if params["sidecarClear"]?.boolValue == true {
            Task { await self.voicePanel.refreshSidecar() }
        } else if let stateRaw = params["sidecarState"]?.stringValue {
            guard let state = SidecarState(rawValue: stateRaw) else {
                throw DebugError(
                    "debug.voicePanel sidecarState must be notInstalled|installedNotRunning|starting|healthy|error")
            }
            let seconds = state == .starting
                ? params["startingForSeconds"]?.doubleValue.map { Int($0) } : nil
            voicePanel.updateSidecar(VoiceConversionStatus(
                state: state,
                message: params["sidecarMessage"]?.stringValue ?? "seeded (\(stateRaw))",
                startingForSeconds: seconds))
        }

        // Voice-list staging: seedVoices plants the facade's real at-rest
        // shape (just "base") without a live sidecar; refreshVoices asks the
        // REAL client (live-gate path).
        if params["seedVoices"]?.boolValue == true {
            voicePanel.setVoicesForCapture([VoiceDescriptor(
                id: "base", name: "Base (untrained)", state: "ready", kind: "builtin",
                trained: false,
                note: "pipeline smoke target — proves conversion runs, not a real voice")])
        }
        if params["refreshVoices"]?.boolValue == true {
            Task { await self.voicePanel.refreshVoices() }
        }

        if params["rescan"]?.boolValue == true { voicePanel.rescanDatasets() }
        if let name = params["createVoice"]?.stringValue {
            _ = voicePanel.createVoice(named: name)
        }
        if let voiceName = params["sampleVoice"]?.stringValue {
            if let path = params["samplePath"]?.stringValue {
                _ = voicePanel.importSamples(
                    [URL(fileURLWithPath: (path as NSString).expandingTildeInPath)],
                    intoVoice: voiceName)
            }
            if let clipRaw = params["sampleClip"]?.stringValue {
                guard let clipID = UUID(uuidString: clipRaw) else {
                    throw DebugError("sampleClip is not a valid UUID: \(clipRaw)")
                }
                _ = voicePanel.addClipAsSample(clipID: clipID, intoVoice: voiceName)
            }
        }
        if let trainName = params["train"]?.stringValue {
            Task { await self.voicePanel.train(voiceNamed: trainName) }
        }

        // Convert sheet: open on a clip; convertGo drives the SAME
        // model.convertClip the sheet's button calls (the UI path seam the
        // live gate exercises).
        if let sheetRaw = params["convertSheet"]?.stringValue {
            guard let clipID = UUID(uuidString: sheetRaw) else {
                throw DebugError("convertSheet is not a valid UUID: \(sheetRaw)")
            }
            openVoiceConvert(clipID: clipID)
        }
        if params["convertGo"]?.boolValue == true {
            guard let clipID = voiceConvertClipID else {
                throw DebugError("debug.voicePanel convertGo needs the convert sheet open (pass convertSheet first)")
            }
            guard let voiceID = params["convertVoiceId"]?.stringValue else {
                throw DebugError("debug.voicePanel convertGo requires convertVoiceId")
            }
            let pitch = params["convertPitch"]?.doubleValue.map { Int($0) } ?? 0
            Task {
                _ = await self.voicePanel.convertClip(
                    clipID: clipID, voiceID: voiceID, pitchSemitones: pitch)
            }
        }
        if params["closeSheet"]?.boolValue == true { closeVoiceConvert() }

        return voicePanelStateResponse()
    }

    /// The `debug.voicePanel` state echo (read-only; also what every staging
    /// call returns).
    private func voicePanelStateResponse() -> JSONValue {
        var trainStates: [String: JSONValue] = [:]
        for dataset in voicePanel.localVoices {
            let state: String = switch voicePanel.trainState(forVoice: dataset.name) {
            case .idle: "idle"
            case .submitting: "submitting"
            case .progress: "progress"
            case .comingSoon(let message): "comingSoon: \(message)"
            case .failed(let message): "failed: \(message)"
            }
            trainStates[dataset.name] = .string(state)
        }
        var response: [String: JSONValue] = [
            "visible": .bool(showVoicePanel),
            "sidecarState": .string(voicePanel.sidecarStatus?.state.rawValue ?? "unknown"),
            "voices": .array(voicePanel.voices.map { .string($0.id) }),
            "localVoices": .array(voicePanel.localVoices.map { dataset in
                .object([
                    "name": .string(dataset.name),
                    "samples": .array(dataset.samples.map { .string($0.name) }),
                ])
            }),
            "trainStates": .object(trainStates),
            "isConverting": .bool(voicePanel.isConverting),
            "datasetsRoot": .string(voicePanel.datasetsRoot.path),
        ]
        if let clipID = voiceConvertClipID {
            response["convertSheetClipId"] = .string(clipID.uuidString)
        }
        if let error = voicePanel.convertError { response["convertError"] = .string(error) }
        if let error = voicePanel.datasetError { response["datasetError"] = .string(error) }
        if let error = voicePanel.voicesError { response["voicesError"] = .string(error) }
        if let outcome = voicePanel.lastConversion {
            response["lastConversion"] = .object([
                "voiceId": .string(outcome.voiceID),
                "trackName": .string(outcome.trackName),
                "realConversion": .bool(outcome.realConversion),
                "note": outcome.note.map { .string($0) } ?? .null,
            ])
        }
        return .object(response)
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
        // The EQ curve surface (m22-b): built over the SAME editor model, with
        // the live render rate injected at open time (§3.4). Non-EQ inserts
        // carry no curve model at all.
        eqCurveEditor = descriptor.kind == .eq
            ? EQCurveEditorModel(editor: effectEditor,
                                 sampleRate: store.renderSampleRateHz())
            : nil
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
        eqCurveEditor = nil
        // The plot is gone, so its measured width is no longer a fact about
        // anything on screen. Dropping it makes the next card report
        // `widthSource: layoutConstant` until it has actually laid out, rather
        // than a stale number from the card that just closed.
        effectEditorPlotWidth = nil
        // Same reason (m23-p2): a size measured on the card that just closed is
        // not a fact about the card that opens next — and the width in
        // particular would be a LIE across a kind change, since the curve kinds
        // draw a wider card than the knob strip.
        effectEditorCardHeight = nil
        effectEditorCardWidth = nil
        // Same reason again: ink reported by a card that has closed describes
        // nothing on screen, and a stale entry here would let a kind that draws
        // NO disclosure inherit the last one's clean bill of health.
        effectEditorHonestyStyle.clear()
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

    // MARK: - Poly Synth editor

    /// Opens the Poly Synth editor card for a track. Guarded to a track whose
    /// CURRENT instrument is the built-in poly synth (nil instrument on an
    /// instrument track = the default descriptor, which IS the poly synth) —
    /// sound banks pick programs and hosted AUs open their own plugin window,
    /// so neither ever reaches this card.
    func openPolySynthEditor(trackID: UUID) {
        guard let track = store.tracks.first(where: { $0.id == trackID }),
              track.kind == .instrument,
              (track.instrument?.kind ?? .polySynth) == .polySynth else { return }
        polySynthEditor.prepare(trackID: trackID, targetLabel: "on \(track.name)")
        polySynthEditorTrackID = trackID
    }

    /// Closes the Poly Synth editor (scrim click, ✕, or replacing modal flows).
    func closePolySynthEditor() {
        polySynthEditorTrackID = nil
        polySynthEditor.clear()
    }

    /// The instrument picker's TUNE affordance: drills from the picker into
    /// the Poly Synth editor for the same track — replacing the picker modal
    /// (one centered card at a time, the house replacing-modal rule).
    func openPolySynthEditorFromPicker() {
        guard let trackID = instrumentPickerTrackID else { return }
        closeInstrumentPicker()
        openPolySynthEditor(trackID: trackID)
    }

    /// `debug.synthEditor {trackId?, open?, param?, value?, waveform?, close?}`
    /// — stages the Poly Synth editor for captures/E2E (app-level, debug tier —
    /// off `allCommands`/MCP, the `debug.effectEditor` precedent). `open:true`
    /// opens the card (the given track, else the first poly-synth instrument
    /// track, else a fresh instrument track); `param`+`value` and `waveform`
    /// drive the OPEN card's apply path (`PolySynthEditorModel.set` /
    /// `setWaveform` → the same `setInstrument` call a knob tick makes — the
    /// UI-vs-wire seam); `close:true` dismisses. A bare call is READ-ONLY
    /// (echoes state, never re-opens — the m11-a law).
    private func synthEditorDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["close"]?.boolValue == true {
            closePolySynthEditor()
            return synthEditorStateResponse()
        }
        if params["open"]?.boolValue == true {
            let trackID: UUID
            if let raw = params["trackId"]?.stringValue {
                guard let id = UUID(uuidString: raw),
                      store.tracks.contains(where: { $0.id == id }) else {
                    throw DebugError("trackId is not a known track UUID: \(raw)")
                }
                trackID = id
            } else if let track = store.tracks.first(where: { track in
                track.kind == .instrument && (track.instrument?.kind ?? .polySynth) == .polySynth
            }) {
                trackID = track.id
            } else {
                trackID = store.addTrack(kind: .instrument).id
            }
            openPolySynthEditor(trackID: trackID)
            guard polySynthEditorTrackID != nil else {
                throw DebugError("track does not play the built-in Poly Synth")
            }
        }
        if let name = params["param"]?.stringValue {
            guard polySynthEditorTrackID != nil else {
                throw DebugError("no synth editor is open — pass open:true first")
            }
            guard let value = params["value"]?.doubleValue else {
                throw DebugError("param requires a numeric value")
            }
            polySynthEditor.set(name: name, value: value)
            if let error = polySynthEditor.lastErrorMessage { throw DebugError(error) }
        }
        if let raw = params["waveform"]?.stringValue {
            guard polySynthEditorTrackID != nil else {
                throw DebugError("no synth editor is open — pass open:true first")
            }
            guard let waveform = PolySynthParams.Waveform(rawValue: raw) else {
                throw DebugError("waveform must be one of saw|square|triangle|sine, got: \(raw)")
            }
            polySynthEditor.setWaveform(waveform)
            if let error = polySynthEditor.lastErrorMessage { throw DebugError(error) }
        }
        return synthEditorStateResponse()
    }

    private func synthEditorStateResponse() -> JSONValue {
        let values: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: PolySynthEditorModel.specs.map {
                ($0.name, JSONValue.number(polySynthEditor.value(for: $0)))
            })
        return .object([
            "visible": .bool(polySynthEditorTrackID != nil && polySynthEditor.targetIsPolySynth),
            "trackId": polySynthEditorTrackID.map { JSONValue.string($0.uuidString) } ?? .null,
            "waveform": .string(polySynthEditor.waveform.rawValue),
            "values": .object(values),
        ])
    }

    /// `debug.effectEditor {trackId?, effectId?, open?, add?, param?, value?,
    /// probeHz?, close?}` — stages the built-in effect editor for captures/E2E
    /// (app-level, debug tier — off `allCommands`/MCP, the `debug.effectPicker`
    /// precedent). `trackId` takes a track UUID or `"master"` (the fx.* sentinel;
    /// omitted = the first chain carrying a built-in insert). `open:true` opens
    /// the card (switching to the Mix workspace + Pro density so a capture
    /// frames it); `add:"eq"` drives the EXACT UI add funnel (`addBuiltInInsert`
    /// — store add + auto-open, what the strip's "+" menu runs); `param`+`value`
    /// drive the OPEN card's apply path (`EffectEditorModel.set` → the same
    /// store call a slider tick makes — the G2 UI-vs-wire seam); `close:true`
    /// dismisses. A bare call is READ-ONLY (echoes state, never re-opens — the
    /// m11-a law). m22-b: when the open card is an EQ the state echo gains
    /// `editorMode` ("curve"/"knobs" from the density store) + `selectedBand`,
    /// and `probeHz: [Double]` returns `responseDb: {"<hz>": dB}` through the
    /// SAME `EQFilterResponse` math + params + sample rate the curve Canvas
    /// draws — numeric E2E without pixel-parsing (§7).
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

        // m22-b: probeHz → the drawn curve's dB at each frequency, computed
        // through the SAME EQFilterResponse call + resolved params + sample
        // rate the curves Canvas uses (the honest numeric twin of the pixels).
        var responseDb: JSONValue?
        if let probe = params["probeHz"]?.arrayValue {
            guard effectEditorTarget != nil, effectEditor.kind == .eq,
                  let eqParams = effectEditor.descriptor?.resolvedEQ,
                  let curveModel = eqCurveEditor else {
                throw DebugError("probeHz requires an open EQ editor — pass open:true on an eq insert first")
            }
            var probes: [String: JSONValue] = [:]
            for entry in probe {
                guard let hz = entry.doubleValue, hz > 0 else {
                    throw DebugError("probeHz values must be positive numbers")
                }
                probes[String(format: "%g", hz)] = .number(EQFilterResponse.responseDb(
                    params: eqParams, frequency: hz, sampleRate: curveModel.sampleRate))
            }
            responseDb = .object(probes)
        }
        return effectEditorStateResponse(responseDb: responseDb)
    }

    private func effectEditorStateResponse(responseDb: JSONValue? = nil) -> JSONValue {
        let values: [String: JSONValue] = Dictionary(
            uniqueKeysWithValues: effectEditor.specs.map {
                ($0.name, JSONValue.number(effectEditor.value(for: $0)))
            })
        var fields: [String: JSONValue] = [
            "visible": .bool(effectEditorTarget != nil && effectEditor.descriptor != nil),
            "trackId": effectEditorTarget.map {
                $0.trackID.map { JSONValue.string($0.uuidString) } ?? .string("master")
            } ?? .null,
            "effectId": effectEditorTarget.map { JSONValue.string($0.effectID.uuidString) } ?? .null,
            "kind": effectEditor.kind.map { JSONValue.string($0.rawValue) } ?? .null,
            "bypassed": .bool(effectEditor.isBypassed),
            "values": .object(values),
        ]
        // m23-p2: the card's drawn HONESTY DISCLOSURE, reported for EVERY kind
        // (null when the kind has no note) rather than nested inside a
        // `kind == .bassEnhancer` block. A field that only exists for the one
        // kind that has a note cannot catch the wiring error that matters —
        // the card drawing the note for the WRONG kind, or for none. Reports
        // `effectEditorHonestyNote`, the SAME property ContentView hands the
        // card, so a mis-wired disclosure reddens here instead of agreeing with
        // a re-derivation. The words are otherwise pixels only: `.help` is
        // invisible to `debug.captureUI`, and so is a string nobody echoes.
        fields["honestyNote"] = effectEditorHonestyNote.map { note in
            JSONValue.object([
                "headline": .string(note.headline),
                "body": .string(note.body),
                "footnote": .string(note.footnote),
                // `drawnStrings`, not three re-listed fields: the gate's
                // readout-token sweep runs over THIS array, so a fourth drawn
                // string added to the type is swept the day it is added
                // instead of the day someone remembers to name it here.
                "drawn": .array(note.drawnStrings.map(JSONValue.string)),
            ])
        } ?? .null
        // m23-p2: the card's MEASURED size and the floor it has to fit inside.
        // The floor travels with it so a gate never has to hardcode the floor —
        // if `WindowFloor.minHeight` moves, the assertion moves with it. null
        // while no card has laid out.
        // m23-p2 (review round): the DRAWN face and ink, per role. Reported for
        // every kind — an empty object for a kind with no disclosure is the
        // honest answer and lets a gate catch ink reported for a card that
        // draws no copy. `inkTokens` carries the tokens a gate has to compare
        // AGAINST (violet = AI, amber = record/warning, and the knob label the
        // prose must not sit below), so no gate hardcodes a hex — the drawn
        // side is measured, the reference side is named.
        fields["honestyStyle"] = .object(effectEditorHonestyStyle.entries.mapValues { entry in
            JSONValue.object([
                "face": entry.face.map { JSONValue.string($0) } ?? .null,
                "ink": entry.ink.map { JSONValue.string($0) } ?? .null,
            ])
        })
        fields["inkTokens"] = .object([
            "ai": .string(DAWTheme.hexString(DAWTheme.ai)),
            "record": .string(DAWTheme.hexString(DAWTheme.record)),
            "knobLabel": .string(DAWTheme.hexString(KnobControl.labelInk)),
            "textSecondary": .string(DAWTheme.hexString(DAWTheme.textSecondary)),
        ])
        fields["cardHeight"] = effectEditorCardHeight.map { JSONValue.number($0) } ?? .null
        fields["cardWidth"] = effectEditorCardWidth.map { JSONValue.number($0) } ?? .null
        fields["cardMaxHeight"] = .number(Double(EffectEditorOverlay.maxCardHeight))
        fields["windowMinHeight"] = .number(Double(WindowFloor.minHeight))
        // m22-b: an open EQ card additionally reports which surface renders
        // (Simple = curve, Pro = knobs — the density store is the truth) and
        // the curve model's selected band.
        if effectEditor.kind == .eq {
            fields["editorMode"] = .string(
                panelDensity.density(forPanel: EffectEditorOverlay.panelID) == .pro
                    ? "knobs" : "curve")
            fields["selectedBand"] = eqCurveEditor?.selectedBand
                .map { JSONValue.string($0.rawValue) } ?? .null
            // m23-r3: the spectrum layer's state, for the gate.
            //
            // NONE of this drains the tap. `spectrumShown` reads the ONE-home
            // gates the CARD itself passes down (invert either and this field
            // moves with it — the m23-r2a hand-assignment hole, closed by
            // construction); `spectrumArmed` reads the AppModel arm slot and
            // NOT `store.insertAnalysis(...) != nil`, which would make this
            // probe a second consumer of a ring that has room for exactly one;
            // and `spectrumHeights` is the layer's own smoothed output —
            // DOWNSTREAM of the drain, so it proves the layer polled AND
            // smoothed, and a floor silhouette (heights climb toward a seeded
            // shape) can never be mistaken for a MISSING layer (heights stay
            // flat at zero, because nothing is advancing them).
            let showsCurve = EffectEditorOverlay.showsCurveSurface(
                kind: effectEditor.kind, hasCurveModel: eqCurveEditor != nil,
                density: panelDensity.density(forPanel: EffectEditorOverlay.panelID))
            fields["spectrumShown"] = .bool(
                showsCurve && EQCurveEditorModel.showsSpectrum(for: effectEditorTarget))
            fields["spectrumArmed"] = .bool(effectEditorSpectrumIsMeasuring)
            fields["spectrumSource"] = .string(effectEditorSpectrumSource.rawValue)
            fields["spectrumHeights"] = .array(
                (eqCurveEditor?.spectrumHeights ?? []).map { JSONValue.number($0) })
            // The plot's `.help` caption — the SAME property ContentView hands
            // the card, not a re-derivation of it, so a mis-wired caption
            // reddens here. A tooltip is invisible to `debug.captureUI`, so
            // without this field the pre-fader / post-fader labelling law —
            // this cycle's headline decision — would be pinned as a FUNCTION
            // and unpinned as a WIRE. Null when there is no plot on screen (Pro
            // density draws the knob table): the field mirrors the view's own
            // existence rather than describing a caption nobody can read.
            fields["curveHelp"] = showsCurve ? .string(effectEditorCurveHelp) : .null
            // m23-o2: the instrument frequency guide's state, for the gate.
            //
            // Reports `effectEditorInstrumentGuide` — the SAME property
            // ContentView hands the card — mapped through the value's own
            // `probeFields`, which is the function the drawing layer's geometry
            // also goes through. There is no second computation here to drift.
            //
            // Both Hz AND on-plot x ride in the payload on purpose: "the
            // bracket is at the right frequency" and "the bracket is in the
            // right place on this axis" are different claims, and a
            // coordinate-space bug satisfies the first while failing the
            // second. The width they are computed at is reported beside them.
            //
            // Null when there is no plot on screen (Pro density draws the knob
            // table), mirroring `curveHelp`: the field describes a drawing that
            // exists, never one nobody can see.
            //
            // ⚠️ THE WIDTH IS THE ONE THE PLOT MEASURED, not the layout
            // constant. `EQCurveEditor` reports its `GeometryReader` width up
            // through `onPlotWidth`, so the x values below come from the same
            // number `EQGuidanceLayer.draw` lays its tags out at. The constant
            // is a FALLBACK for the window between opening the card and its
            // first layout, and the payload NAMES which one was used — a gate
            // that asserted x against a width the probe itself chose would be
            // self-consistent and blind, and `DAWApp` has no test target, so a
            // staging gate is the only thing that can see this path.
            if showsCurve {
                var guideFields: [String: JSONValue] = [:]
                let measured = effectEditorPlotWidth
                for (key, value) in effectEditorInstrumentGuide
                    .probeFields(width: measured ?? EQGuidanceLayout.contentWidth,
                                 widthSource: measured == nil
                                     ? .layoutConstant : .measured) {
                    guideFields[key] = Self.guideProbeJSON(value)
                }
                fields["instrumentGuide"] = .object(guideFields)
            } else {
                fields["instrumentGuide"] = .null
            }
        }
        if let responseDb {
            fields["responseDb"] = responseDb
        }
        return .object(fields)
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

    /// Imports a sample library — .sfz (documented subset) or .dspreset —
    /// onto the instrument picker's target track via NSOpenPanel (not
    /// headless — the app view drives it), routing through the SAME store
    /// method the wire's `instrument.importSampleLibrary` uses (one journaled
    /// "Change Instrument" edit). The report's zone counts + degradation
    /// sentences surface in the picker's neutral inline notice; refusals in
    /// the inline error row (the `importSoundBankViaPanel` idiom). A
    /// cancelled panel is a no-op. `.dslibrary` stays selectable ON PURPOSE:
    /// picking one surfaces the teaching error ("unzip and import the
    /// .dspreset inside") instead of an unexplained grayed-out file.
    func importSampleLibraryViaPanel() {
        guard let trackID = instrumentPickerTrackID else { return }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "sfz"),
                                     UTType(filenameExtension: "dspreset"),
                                     UTType(filenameExtension: "dslibrary")].compactMap { $0 }
        panel.prompt = "Import"
        panel.message = "Choose a sample library — .sfz (documented subset) or .dspreset — to play on this track's Sampler."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = try store.importSampleLibrary(trackID: trackID, path: url.path)
            var lines = [
                "Imported \(report.zonesImported) zone\(report.zonesImported == 1 ? "" : "s") · \(report.velocityLayerCount) velocity layer\(report.velocityLayerCount == 1 ? "" : "s") · \(report.groupCount) group\(report.groupCount == 1 ? "" : "s")",
            ]
            if !report.skippedRegions.isEmpty {
                let summary = report.skippedRegions.sorted { $0.key < $1.key }
                    .map { "\($0.key) ×\($0.value)" }.joined(separator: ", ")
                lines.append("Skipped: \(summary)")
            }
            lines += report.degradations
            instrumentPicker.presentSampleLibraryOutcome(
                notice: lines.joined(separator: "\n"), error: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            instrumentPicker.presentSampleLibraryOutcome(notice: nil, error: message)
        }
        // Refresh the picker's current-instrument highlight (now the Sampler
        // on success) — the applyInstrumentChoice re-read discipline.
        let descriptor = store.tracks.first { $0.id == trackID }?.instrument
        instrumentPicker.updateCurrent(descriptor: descriptor,
                                       status: store.audioUnitStatus(forTrack: trackID))
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

    // MARK: - Export dialog (m23-m3)

    /// `debug.exportDialog {open?, close?, mode?, bitDepth?, container?,
    /// exclude?[], excludeNamed?[], includeAll?, normalize?, lufsTarget?,
    /// truePeakCeilingDb?, includeMixdown?, includeMasteredMixdown?,
    /// masteredNormalize?, masteredLufsTarget?, masteredTruePeakCeilingDb?,
    /// exportToPath?, exportToDirectory?}` — drives the Export dialog headlessly
    /// for captures + gates (the `debug.quantizePanel` precedent; app tier ONLY,
    /// off `allCommands` and off MCP, so it costs ZERO agent-facing wire
    /// surface). A BARE call is READ-ONLY (echoes state, never re-opens — the
    /// m11-a law).
    ///
    /// `exportToPath` runs the export through **`ExportDialogModel.export` — the
    /// exact method the sheet's button calls**, bypassing only the NSSavePanel
    /// (which no headless run can drive). A render is seconds-class, so it kicks
    /// a Task and echoes `exporting: true`; poll with a bare call and read
    /// `lastExport` / `lastError` (the `debug.voicePanel convertGo` cadence).
    ///
    /// `exportToDirectory` is its STEMS sibling (m23-m3c), running
    /// `ExportDialogModel.exportStems` — a directory rather than a path, because
    /// that call writes a SET. It is the only way a headless gate can reach the
    /// stems surface at all (`NSOpenPanel` is as undriveable as `NSSavePanel`),
    /// and it is what lets a gate compare the `plannedFiles` echo against the
    /// directory listing afterwards. It does NOT set the mode — the mode decides
    /// which button the sheet shows, and a seam that silently switched it would
    /// hide the very wiring under test.
    ///
    /// `bitDepth` accepts a number or the string "float"/"32f" for the default;
    /// an unknown value is REFUSED by the model, so the echo shows what actually
    /// stands rather than what was asked for.
    private func exportDialogDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        if params["close"]?.boolValue == true {
            showExportSheet = false
            return exportDialogStateResponse()
        }
        if params["open"]?.boolValue == true {
            // Deliberately does NOT force `workspaceMode` (unlike the
            // clip-scoped `debug.voicePanel` / `debug.quantizePanel` seams).
            // Export is app-level and its overlay sits OUTSIDE the workspace
            // switch, so it is reachable from the Mix console too — forcing
            // arrange here would render a backdrop the user path never
            // produces, and a capture must show what a person actually sees.
            openExportSheet()
        }

        // The mode (m23-m3c) — refused rather than defaulted on an unknown
        // value, the same rule the depth picker follows.
        if let raw = params["mode"]?.stringValue {
            guard let mode = ExportMode(rawValue: raw) else {
                throw DebugError(
                    "debug.exportDialog mode must be one of "
                    + ExportMode.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", "))
            }
            exportDialog.mode = mode
        }

        // Format staging — through the model's resolve-only setters, so an
        // out-of-vocabulary depth cannot reach a render.
        if let raw = params["bitDepth"] {
            switch raw {
            case .null:
                exportDialog.setBitDepth(nil)
            case .string(let text) where ["float", "32f", "float32", "default"].contains(text):
                exportDialog.setBitDepth(nil)
            case .number(let value):
                exportDialog.setBitDepth(Int(value))
            default:
                throw DebugError(
                    "debug.exportDialog bitDepth must be 16, 24, 32, null or \"float\"")
            }
        }
        if let raw = params["container"]?.stringValue {
            guard let container = DeliveryContainer(rawValue: raw) else {
                throw DebugError(
                    "debug.exportDialog container must be one of "
                    + DeliveryContainer.allCases.map { "'\($0.rawValue)'" }.joined(separator: ", "))
            }
            exportDialog.setContainer(container)
        }

        // Exclusions — by id, or by NAME for a readable gate script. Both drive
        // the same toggle the checkbox rows call.
        if params["includeAll"]?.boolValue == true { exportDialog.clearExclusions() }
        if case .array(let ids)? = params["exclude"] {
            for entry in ids {
                guard let raw = entry.stringValue, let id = UUID(uuidString: raw) else {
                    throw DebugError("debug.exportDialog exclude entries must be track UUIDs")
                }
                guard exportDialog.tracks.contains(where: { $0.id == id }) else {
                    throw DebugError("debug.exportDialog exclude: no such track in the dialog's list — \(raw)")
                }
                if !exportDialog.isExcluded(id) { exportDialog.toggleExcluded(id) }
            }
        }
        if case .array(let names)? = params["excludeNamed"] {
            for entry in names {
                guard let name = entry.stringValue,
                      let match = exportDialog.tracks.first(where: { $0.name == name }) else {
                    throw DebugError("debug.exportDialog excludeNamed: no track named \(entry.stringValue ?? "?")")
                }
                if !exportDialog.isExcluded(match.id) { exportDialog.toggleExcluded(match.id) }
            }
        }

        // Normalization. Setting a value does NOT switch the toggle on — the
        // request only carries a target when `normalize` is true, and a staging
        // seam that silently enabled it would hide exactly that rule.
        if let normalize = params["normalize"]?.boolValue { exportDialog.normalize = normalize }
        if let target = params["lufsTarget"]?.doubleValue { exportDialog.lufsTarget = target }
        if let ceiling = params["truePeakCeilingDb"]?.doubleValue {
            exportDialog.truePeakCeilingDb = ceiling
        }

        // Stems staging (m23-m3c). Same rule as normalization above: setting a
        // mastered target does NOT switch its toggle on, because the request
        // only carries one when the toggle is on and a seam that flipped it
        // would hide exactly that rule.
        if let value = params["includeMixdown"]?.boolValue { exportDialog.includeMixdown = value }
        if let value = params["includeMasteredMixdown"]?.boolValue {
            exportDialog.includeMasteredMixdown = value
        }
        if let value = params["masteredNormalize"]?.boolValue {
            exportDialog.masteredNormalize = value
        }
        if let target = params["masteredLufsTarget"]?.doubleValue {
            exportDialog.masteredLufsTarget = target
        }
        if let ceiling = params["masteredTruePeakCeilingDb"]?.doubleValue {
            exportDialog.masteredTruePeakCeilingDb = ceiling
        }

        if let path = params["exportToPath"]?.stringValue {
            let expanded = (path as NSString).expandingTildeInPath
            Task { @MainActor in
                _ = await self.exportDialog.export(store: self.store, toPath: expanded)
            }
        }
        if let directory = params["exportToDirectory"]?.stringValue {
            let expanded = (directory as NSString).expandingTildeInPath
            Task { @MainActor in
                _ = await self.exportDialog.exportStems(store: self.store, toDirectory: expanded)
            }
        }
        return exportDialogStateResponse()
    }

    /// Read-only snapshot of the Export dialog so a capture/gate flow can poll.
    /// Deliberately carries NO loudness numbers — for the same reason the card
    /// shows none (the m23-m2 pre-quantization hazard).
    private func exportDialogStateResponse() -> JSONValue {
        let format = exportDialog.format
        var response: [String: JSONValue] = [
            "visible": .bool(showExportSheet),
            "mode": .string(exportDialog.mode.rawValue),
            "bitDepth": format.bitDepth.map { JSONValue.number(Double($0)) } ?? .null,
            "container": .string(format.container.rawValue),
            "fileExtension": .string(format.fileExtension),
            "formatLabel": .string(format.label),
            "suggestedFileName": .string(
                exportDialog.suggestedFileName(projectName: store.projectName)),
            "tracks": .array(exportDialog.tracks.map { .string($0.name) }),
            "excluded": .array(exportDialog.excludedNames.map { .string($0) }),
            "normalize": .bool(exportDialog.normalize),
            "lufsTarget": .number(exportDialog.lufsTarget),
            "truePeakCeilingDb": .number(exportDialog.truePeakCeilingDb),
            "exporting": .bool(exportDialog.isExporting),
            "renderCompletedCount": .number(Double(store.renderCompletedCount)),
        ]
        // The REQUEST as it stands — what `renderBounce` would actually receive.
        // Absence is meaningful here (nil = the shipped default), so nil fields
        // encode as JSON null rather than being omitted.
        let request = exportDialog.request()
        response["request"] = .object([
            "bitDepth": request.bitDepth.map { JSONValue.number(Double($0)) } ?? .null,
            "container": request.container.map { JSONValue.string($0) } ?? .null,
            "excludeTrackIds": request.excludeTrackIds
                .map { JSONValue.array($0.map { .string($0.uuidString) }) } ?? .null,
            "lufsTarget": request.lufsTarget.map { JSONValue.number($0) } ?? .null,
            "truePeakCeilingDb": .number(request.truePeakCeilingDb),
        ])
        // The stems side (m23-m3c): the toggles as controls, the request as
        // `renderStems` would receive it, and the PLANNED file set — which is
        // `StemPlan.fileSet`, the same list the card renders, so a gate can
        // compare the promise against the directory afterwards.
        response["includeMixdown"] = .bool(exportDialog.includeMixdown)
        response["includeMasteredMixdown"] = .bool(exportDialog.includeMasteredMixdown)
        response["masteredNormalize"] = .bool(exportDialog.masteredNormalize)
        response["masteredLufsTarget"] = .number(exportDialog.masteredLufsTarget)
        response["masteredTruePeakCeilingDb"] = .number(exportDialog.masteredTruePeakCeilingDb)
        response["plannedFiles"] = .array(exportDialog.plannedStemFiles.map { .string($0) })
        let stemRequest = exportDialog.stemRequest()
        response["stemRequest"] = .object([
            "trackIds": stemRequest.trackIds
                .map { JSONValue.array($0.map { .string($0.uuidString) }) } ?? .null,
            "includeMixdown": .bool(stemRequest.includeMixdown),
            "includeMasteredMixdown": .bool(stemRequest.includeMasteredMixdown),
            "masteredLufsTarget": stemRequest.masteredLufsTarget
                .map { JSONValue.number($0) } ?? .null,
            "masteredTruePeakCeilingDb": .number(stemRequest.masteredTruePeakCeilingDb),
            "bitDepth": stemRequest.bitDepth.map { JSONValue.number(Double($0)) } ?? .null,
            "container": stemRequest.container.map { JSONValue.string($0) } ?? .null,
        ])
        if let error = exportDialog.lastError { response["lastError"] = .string(error) }
        if let outcome = exportDialog.lastExport {
            response["lastExport"] = .object([
                "path": .string(outcome.path),
                "durationSeconds": .number(outcome.durationSeconds),
                "formatLabel": .string(outcome.formatLabel),
                "excludedTracks": .array(outcome.excludedTracks.map { .string($0) }),
                "limitedByCeiling": .bool(outcome.limitedByCeiling),
            ])
        }
        // The stems run's own outcome — the files that ACTUALLY landed, read off
        // the result's paths. Carries no loudness number, for the same
        // pre-quantization reason the bounce outcome carries none.
        if let outcome = exportDialog.lastStemExport {
            response["lastStemExport"] = .object([
                "directory": .string(outcome.directory),
                "files": .array(outcome.fileNames.map { .string($0) }),
                "durationSeconds": .number(outcome.durationSeconds),
                "formatLabel": .string(outcome.formatLabel),
                "limitedByCeiling": .bool(outcome.limitedByCeiling),
                "masterChainExcluded": .bool(outcome.masterChainExcluded),
            ])
        }
        return .object(response)
    }

    // MARK: - Track-header context menu (m23-m3b)

    /// The arrange track-header context menu's items for one track — **the ONE
    /// binding of live app state to `TrackHeaderMenu`** (m23-m3b).
    ///
    /// Both the SwiftUI row and `debug.trackMenu` call THIS, which is the half
    /// the headless echo can actually reach: a seam that re-derived the inputs
    /// for itself could agree with the pure rule while the row read a different
    /// expanded set or a stale sidebar width, and no test would see it.
    func trackHeaderMenuItems(for track: Track) -> [TrackHeaderMenuItem] {
        TrackHeaderMenu.items(
            track: track,
            sidebarWidth: panelLayout.sidebarWidth,
            isAutomationExpanded: expandedAutomationTrackIDs.contains(track.id))
    }

    /// `debug.trackMenu {trackId}` — echoes the arrange track-header context
    /// menu's ITEM LIST for one track.
    ///
    /// An AppKit context-menu popup cannot be opened by `debug.captureUI`, so
    /// this is the only way the menu's CONTENTS are assertable at all; the row
    /// renders from the same `trackHeaderMenuItems(for:)` call above, so the two
    /// agreeing is structural rather than a coincidence a refactor could break.
    ///
    /// **Parameter-thin on purpose.** Both inputs that shape the list already
    /// have live seams — `debug.panelLayout {sidebarWidth}` and the
    /// `ui.showAutomation {trackId}` verb — so staging them here would invent a
    /// second way to set state that the real menu never reads. A gate drives the
    /// app, then asks what the menu says.
    ///
    /// Debug tier ONLY: off `allCommands` and off MCP, so this costs ZERO
    /// agent-facing wire surface. A menu's contents are not an invokable
    /// capability — every action in it already has (or is) a wire verb.
    private func trackMenuDebug(_ params: [String: JSONValue]) throws -> JSONValue {
        guard let raw = params["trackId"]?.stringValue, let id = UUID(uuidString: raw) else {
            throw DebugError("debug.trackMenu requires trackId (a track UUID)")
        }
        guard let track = store.tracks.first(where: { $0.id == id }) else {
            throw DebugError("debug.trackMenu: no such track — \(raw)")
        }
        let items = trackHeaderMenuItems(for: track)
        return .object([
            "trackId": .string(track.id.uuidString),
            "name": .string(track.name),
            "kind": .string(track.kind.rawValue),
            // The INPUTS the list was computed from, echoed beside it so a
            // surprising list can be read without a second round trip.
            "sidebarWidth": .number(Double(panelLayout.sidebarWidth)),
            "automationExpanded": .bool(expandedAutomationTrackIDs.contains(track.id)),
            "canExportMIDI": .bool(track.canExportMIDI),
            // Bare identifiers for a one-line assertion, plus the full entries
            // (titles carry state — "Show" vs "Hide" — so they are worth seeing).
            "actions": .array(items.map { .string($0.action.rawValue) }),
            "items": .array(items.map {
                .object([
                    "action": .string($0.action.rawValue),
                    "title": .string($0.title),
                    "destructive": .bool($0.isDestructive),
                ])
            }),
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

    /// `debug.copilotSeed {mode, expandThinking?, modelPicker?, model?}` — stages
    /// the copilot rail for a capture/E2E that can't be reached from the wire
    /// alone (no AI provider key on the capture machine — the `debug.clipFixSeed`
    /// precedent). Seeds a scripted transcript straight into the engine via
    /// `seedForCapture` (never a provider call). Opens the rail; `mode`:
    ///   - `conversation` (default): a user turn, assistant prose, two toolCall
    ///     chips (distinct commands), an ok toolResult + an error toolResult, a
    ///     closing assistant line, with `status = running` so the working shimmer
    ///     shows — the state-variety shot.
    ///   - `streaming` (M10-p-6): a mid-round live-streaming turn — a FINALIZED
    ///     thinking entry (the settled REASONED disclosure), tool traffic, then a
    ///     PARTIAL thinking entry and a PARTIAL assistant entry (both `partial:
    ///     true`, the breathing-dot streaming states), `status = running`.
    ///   - `failed`: a short turn that ends in a `failure` entry (`status =
    ///     failed`) so the failure strip + reset affordance read.
    ///   - `idle`/`empty`: resets the engine to an empty idle rail (the first-use
    ///     hint shot).
    /// Additive presentation staging (any mode; M10-p-6):
    ///   - `expandThinking: true/false` expands/collapses ALL thinking entries
    ///     (the `CopilotRailUIModel` disclosure state).
    ///   - `modelPicker: true/false` opens/closes the in-rail model picker.
    ///   - `model: "<id>"` routes through `engine.setModel` — the SAME path the
    ///     picker rows commit through (an unknown id no-ops, the store's own
    ///     validation; NOTE it persists like any real selection).
    /// Chat-persist Phase D staging (additive; capture-tier only):
    ///   - `droppedEntries: N` rides the seed into the engine (`seedForCapture`'s
    ///     additive param) so the L6 truncation banner renders; ignored by
    ///     `idle`/`empty` (a fresh chat has nothing trimmed).
    ///   - `seedChats: N` (clamped 0…8) archives N scripted sample chats through
    ///     `store.archiveCopilotChat` — the REAL archive path, so list order,
    ///     upsert, and eviction behave exactly as live. One sample carries
    ///     `droppedEntries` so the row's "trimmed" honesty tag can be captured.
    ///     NOTE: they land in the open project's chat list and arm `chatsDirty`
    ///     like any archive — staging boxes / scratch projects only.
    ///   - `chatList: true/false` opens/closes the in-rail chat-history list.
    ///   - `renameChat: true` begins an inline rename on the newest archived
    ///     row; `confirmDelete: true` arms its delete confirmation (the two
    ///     capture states §8.6 needs; rename wins if both are sent, matching
    ///     the model's one-sub-state rule).
    /// Off `allCommands`/MCP. Returns the resulting rail state.
    private func copilotSeed(_ params: [String: JSONValue]) -> JSONValue {
        let mode = params["mode"]?.stringValue ?? "conversation"
        showCopilot = true
        typealias Kind = CopilotEngine.TranscriptEntry.Kind
        let turnID = "seed-turn"
        let seedDropped = (params["droppedEntries"]?.doubleValue).map(Int.init) ?? 0
        switch mode {
        case "idle", "empty":
            copilotEngine.reset()
            copilotRailUI.collapseAllThinking()
        case "streaming":
            typealias Entry = CopilotEngine.TranscriptEntry
            copilotEngine.seedForCapture(turnID: turnID, status: .running, transcript: [
                Entry(id: UUID(), turnID: turnID,
                      kind: .user("tighten up the drum timing, then brighten the mix a little")),
                Entry(id: UUID(), turnID: turnID,
                      kind: .thinking("The drums live on track 2 with a loose 1/16 feel — quantizing at "
                        + "80% strength tightens the timing without making it robotic. For brightness, "
                        + "a gentle master high-shelf is safer than reshaping each track.")),
                Entry(id: UUID(), turnID: turnID,
                      kind: .assistant("I'll tighten the drum timing first, then add a touch of top end.")),
                Entry(id: UUID(), turnID: turnID,
                      kind: .toolCall(command: "clip.quantize",
                                      argsSummary: #"{"clipId": "a1b2c3d4", "grid": 0.25, "strength": 0.8}"#)),
                Entry(id: UUID(), turnID: turnID,
                      kind: .toolResult(command: "clip.quantize", ok: true,
                                        summary: #"{"notesMoved": 14}"#)),
                Entry(id: UUID(), turnID: turnID,
                      kind: .thinking("Drums are tightened. Now checking the master chain for room to "
                        + "lift the highs without pushing the loudest peaks into"),
                      partial: true),
                Entry(id: UUID(), turnID: turnID,
                      kind: .assistant("Done — the drums now sit right on the grid. Next I'm brightening "
                        + "the top end with a gentle"),
                      partial: true),
            ], droppedEntries: seedDropped)
        case "failed":
            copilotEngine.seedForCapture(turnID: turnID, status: .failed, entries: [
                .user("add a punchy drum track and set the tempo to 120"),
                .assistant("On it — adding a drum track, then setting the tempo."),
                .toolCall(command: "track.add", argsSummary: #"{"name": "Drums", "kind": "audio"}"#),
                .toolResult(command: "track.add", ok: true, summary: #"{"trackId": "a1b2c3d4", "name": "Drums"}"#),
                .toolCall(command: "transport.setTempo", argsSummary: #"{"bpm": 120}"#),
                .failure("the AI provider returned an error: rate limit exceeded — wait a moment, then send again"),
            ], droppedEntries: seedDropped)
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
            ], droppedEntries: seedDropped)
        }
        // Presentation staging (M10-p-6) — applied AFTER seeding so entry ids exist.
        if let expand = params["expandThinking"]?.boolValue {
            if expand {
                for entry in copilotEngine.transcript {
                    if case .thinking = entry.kind { copilotRailUI.expandThinking(entry.id) }
                }
            } else {
                copilotRailUI.collapseAllThinking()
            }
        }
        if let pickerOpen = params["modelPicker"]?.boolValue {
            copilotRailUI.isModelPickerOpen = pickerOpen
        }
        if let model = params["model"]?.stringValue {
            copilotEngine.setModel(model)   // the picker's own commit path; invalid ids no-op
        }
        // Chat-persist Phase D staging (additive; capture-tier).
        if let count = (params["seedChats"]?.doubleValue).map(Int.init), count > 0 {
            seedSampleChats(min(count, 8))
        }
        if let listOpen = params["chatList"]?.boolValue {
            if listOpen { copilotRailUI.openChatList() } else { copilotRailUI.closeChatList() }
        }
        // Sorted like the list renders (newest updatedAt first) so "the first
        // archived row" means the row a capture actually shows on top.
        let newestArchived = store.copilotChats.max { $0.updatedAt < $1.updatedAt }
        if params["confirmDelete"]?.boolValue == true, let target = newestArchived {
            copilotRailUI.requestDeleteConfirm(target.id)
        }
        if params["renameChat"]?.boolValue == true, let target = newestArchived {
            copilotRailUI.beginRename(target.id, currentTitle: target.title)
        }
        return copilotStateResponse()
    }

    /// Archives `count` scripted sample chats through the REAL
    /// `store.archiveCopilotChat` path (staggered ages/titles; the second
    /// one carries a `droppedEntries` count so the row's "trimmed" tag can
    /// be captured). Capture-tier only — they enter the open project's chat
    /// list and arm `chatsDirty` exactly like live archives.
    private func seedSampleChats(_ count: Int) {
        let samples: [(title: String, minutesAgo: Double, dropped: Int?)] = [
            ("add a funky bassline", 4, nil),
            ("balance the mix for streaming", 75, 40),
            ("fix the chorus vocals", 26 * 60, nil),
            ("build a four-bar drum groove", 2 * 24 * 60, nil),
            ("sketch a bridge in a minor key", 5 * 24 * 60, nil),
            ("tighten the hi-hats", 9 * 24 * 60, nil),
            ("make the intro punchier", 16 * 24 * 60, nil),
            ("automate a slow filter sweep", 30 * 24 * 60, nil),
        ]
        for sample in samples.prefix(count) {
            let stamp = Date().addingTimeInterval(-sample.minutesAgo * 60)
            let turn = UUID().uuidString
            let chat = CopilotChatDocument(
                id: UUID(),
                title: sample.title,
                createdAt: stamp.addingTimeInterval(-300),
                updatedAt: stamp,
                model: nil,
                droppedEntries: sample.dropped,
                transcript: [
                    .init(turnId: turn, kind: "user", text: sample.title),
                    .init(turnId: turn, kind: "assistant",
                          text: "Done — take a listen and tell me what to adjust."),
                ],
                providerMessages: [])
            store.archiveCopilotChat(chat)
        }
    }

    /// `debug.copilotState` — read-only echo of the rail (visibility + the
    /// engine's own `ai.copilotState` wire shape: status, transcript, current
    /// turn, plus the M10-p-6 presentation state: the effective model, the
    /// model-picker open flag, and the expanded-thinking count; plus the
    /// Phase D chat-list presentation: list open, archived count, the
    /// rename/confirm sub-states) so an E2E flow can assert on the seeded
    /// state. Off `allCommands`/MCP.
    private func copilotStateResponse() -> JSONValue {
        .object([
            "visible": .bool(showCopilot),
            "state": copilotEngine.stateJSON(turnID: nil),
            "model": .string(copilotEngine.currentModel),
            "modelPickerOpen": .bool(copilotRailUI.isModelPickerOpen),
            "expandedThinking": .number(Double(copilotRailUI.expandedThinkingIDs.count)),
            "chatListOpen": .bool(copilotRailUI.isChatListOpen),
            "archivedChats": .number(Double(store.copilotChats.count)),
            "renamingChat": .bool(copilotRailUI.renamingChatID != nil),
            "confirmingDelete": .bool(copilotRailUI.confirmingDeleteChatID != nil),
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
