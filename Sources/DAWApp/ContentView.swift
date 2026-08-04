import SwiftUI
import DAWCore
import DAWEngine
import DAWAppKit
import DAWControl

struct ContentView: View {
    @Environment(ProjectStore.self) private var store
    /// Selection (the open piano-roll clip) lives on AppModel, not local @State,
    /// so the `debug.captureUI` render shares it with the live window.
    @Environment(AppModel.self) private var model
    var engine: AudioEngine
    var controlPort: UInt16

    /// The "Explain this" overlay's presentation coordinator (M8 ex-a): tracks tagged
    /// control frames + hover timing. Lives on `AppModel` beside the mode's on/off
    /// flag — it was view-local `@State` until the measured frames became wire-readable
    /// (`debug.explainFrames`), and a debug command can only read state the model owns.
    /// Still pure view geometry; nothing else about it changed.
    private var explainCoordinator: ExplainCoordinator { model.explainCoordinator }

    /// Drag origins for the adjustable-layout splitters (beta m10-d): each is
    /// captured on the drag's first tick (the gesture reports translation from the
    /// start, so the origin + delta reconstructs the target value), and cleared on
    /// end. nil = no drag in flight. Kept view-local — pure gesture bookkeeping; the
    /// clamped values themselves live on `model.panelLayout`.
    @State private var sidebarDragOrigin: CGFloat?
    @State private var editorDragOrigin: CGFloat?

    /// Live horizontal scroll offset of the arrange lanes (m13-g). The scrolling
    /// `.lanes` instance reports it; the pinned `.ruler` block mirrors it so the
    /// ruler stays horizontally synced with the content while pinned above the
    /// vertical scroll. Hoisted onto AppModel (m17-b) so the zoom entry points
    /// (menu / toolbar / pinch / debug seam) can compute the anchor-preserving
    /// offset off the same live value.
    private var arrangeHScroll: CGFloat { model.arrangeHScroll }

    /// Gap between the pinned ruler block and the scrolling track area (m13-g) —
    /// reads as a distinct pinned ruler bar over the track panels.
    private static let arrangeBlockGap: CGFloat = 6

    /// The clip whose piano roll is open (nil = closed). Only MIDI clips open it.
    /// Hoisted onto AppModel — see `model` above.
    private var selectedClipID: UUID? {
        get { model.selectedClipID }
        nonmutating set { model.selectedClipID = newValue }
    }

    /// Dev affordance: with `DAW_DEBUG_OPEN_PIANOROLL=1`, the piano roll auto-
    /// opens on the first MIDI clip whenever one appears and nothing is selected.
    /// Lets UI verification reach the editor without a click (a MIDI clip added
    /// over the control port pops the panel open). Off by default; never a hack
    /// in normal use.
    private static let debugOpenPianoRoll =
        ProcessInfo.processInfo.environment["DAW_DEBUG_OPEN_PIANOROLL"] == "1"

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 10) {
                header

                // The Copilot rail docks OUTERMOST-right, spanning the full
                // workspace height in BOTH Arrange and Mix — it's app-level, not
                // selection-gated (unlike the Sketchpad/ClipFix panels, which
                // live inside the Arrange workspace beside the timeline).
                HStack(spacing: 10) {
                    VStack(spacing: 10) {
                        switch model.workspaceMode {
                        case .arrange:
                            arrangeDeleteKeyScope(geo)
                        case .mix:
                            mixToolbar
                            MixerView(densityStore: model.panelDensity,
                                      layoutStore: model.panelLayout)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    if model.showCopilot {
                        CopilotRailView(
                            engine: model.copilotEngine,
                            store: model.store,
                            ui: model.copilotRailUI,
                            draftPrefill: model.copilotDraft,
                            onConsumeDraftPrefill: { model.copilotDraft = nil }
                        ) {
                            withAnimation(.easeOut(duration: 0.18)) { model.showCopilot = false }
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                .frame(maxHeight: .infinity)

                TransportBar(engine: engine, densityStore: model.panelDensity)
            }
            .padding(12)
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(DAWTheme.background)
        // Instrument picker (m10-n-3): a centered dark-glass modal over a scrim
        // (the Settings-overlay idiom) — rendered INSIDE the main window content so
        // `debug.captureUI` can snapshot it headlessly (a popover can't be). Opened
        // by the track-header / mixer instrument chips and `debug.instrumentPicker`.
        .overlay { pickerOverlays }
        // Quantize & groove panel (m11-a): a centered dark-glass modal over a scrim
        // (the instrument-picker idiom) — rendered INSIDE the window so
        // `debug.captureUI` can snapshot it. Opened by the piano-roll QUANTIZE chip,
        // the arrange clip context menu, and `debug.quantizePanel`. UI-only: Apply
        // and Extract route through the SAME store methods the wire uses.
        .overlay {
            if model.quantizePanelClipID != nil {
                QuantizePanel(
                    model: model.quantizeModel,
                    densityStore: model.panelDensity,
                    onApply: { withAnimation(.easeOut(duration: 0.15)) { model.applyQuantize() } },
                    onRemoveGroove: { model.removeGroove(id: $0) },
                    onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeQuantizePanel() } }
                )
            }
        }
        // "Convert to Voice…" sheet (m10-p-5): a centered dark-glass modal over a
        // scrim (the Quantize idiom) — rendered INSIDE the window so
        // `debug.captureUI` can snapshot it. Opened by an audio clip's context
        // menu and `debug.voicePanel`; the convert rides the SAME client/store
        // seams as the wire's `vc.convertVocals` clipId-form (one undoable edit).
        .overlay {
            if let clipID = model.voiceConvertClipID {
                VoiceConvertSheet(
                    model: model.voicePanel,
                    clipID: clipID,
                    clipName: voiceConvertClipName(clipID),
                    onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeVoiceConvert() } }
                )
            }
        }
        // Export dialog (m23-m3): a centered dark-glass modal over a scrim (the
        // Quantize idiom) — rendered INSIDE the window so `debug.captureUI` can
        // snapshot it. Opened by the transport EXPORT chip, the onboarding tour's
        // export step, and `debug.exportDialog`. The bounce runs through
        // `ExportDialogModel.export`, the same method the debug seam and the
        // suites drive, so the button can never diverge from the gate.
        .overlay {
            if model.showExportSheet {
                ExportSheet(
                    model: model.exportDialog,
                    projectName: store.projectName,
                    onExport: { model.runExportFromDialog() },
                    onClose: { model.closeExportSheet() }
                )
            }
        }
        // Undo-history panel (m11-b): a centered dark-glass modal over a scrim (the
        // Quantize idiom) — rendered INSIDE the window so `debug.captureUI` can
        // snapshot it. Opened by the arrange-toolbar HISTORY chip and
        // `debug.undoHistory`. UI-only: clicking a row re-drives the SAME
        // `store.undo()`/`redo()` the wire and Cmd-Z use (no new mutation surface).
        .overlay {
            if model.showUndoHistory {
                UndoHistoryPanel(
                    model: model.undoHistoryModel,
                    onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeUndoHistory() } }
                )
            }
        }
        .overlay {
            if model.showSettings {
                SettingsOverlay(
                    model: model.settings,
                    store: store,
                    revealBeta: model.settingsRevealBeta,
                    revealConnection: model.settingsRevealConnection,
                    // The ACTUAL bound port (m10-l) — what agents connect to, not
                    // whatever's pending in the setting field.
                    controlPort: model.controlServer.port,
                    portStore: model.controlPortStore,
                    copilotLimits: model.copilotLimitsStore,
                    onReplayTour: { withAnimation(.easeOut(duration: 0.2)) { model.replayTour() } },
                    onClose: { withAnimation(.easeOut(duration: 0.15)) { model.showSettings = false } }
                )
            }
        }
        // Engine-notices popover (m15-e, audit F6): a bottom-anchored dark-glass
        // card listing schedule-time degradations, opened by the transport-bar
        // notices chip (and `debug.postEngineNotice`). Rendered INSIDE the window
        // (the ContentView "a popover can't be captured" precedent — a real
        // NSPopover lives in its own window, invisible to the `debug.captureUI`
        // cacheDisplay path) so a headless capture snapshots it. A near-transparent
        // backdrop dismisses on any outside click. Anchored trailing, floated above
        // the transport bar — it reads as popping from the bar's right status cluster.
        .overlay(alignment: .bottom) {
            if model.showEngineNotices, !store.engineNotices.isEmpty {
                ZStack(alignment: .bottomTrailing) {
                    Color.black.opacity(0.001)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(.easeOut(duration: 0.15)) { model.showEngineNotices = false }
                        }
                    EngineNoticesPopover(
                        model: EngineNoticesModel(notices: store.engineNotices),
                        onClose: {
                            withAnimation(.easeOut(duration: 0.15)) { model.showEngineNotices = false }
                        }
                    )
                    .padding(.trailing, 24)
                    .padding(.bottom, 84)
                }
                .transition(.opacity)
            }
        }
        // "Explain this" overlay (M8 ex-a/ex-b): inject the mode + coordinator around
        // BOTH the workspace AND the Settings modal, so any `.explainable` control —
        // including a Settings key row — reports into this coordinate space. Collect
        // their frames and float the card OUTERMOST (above the Settings panel); the
        // empty area stays click-through, so controls still work in explain mode.
        .environment(model.explain)
        // The onboarding tour model (M8 ob-b): injected around the same tree as
        // explain so `.explainable` controls report their frames while a tour step
        // is active (the tour card anchors on them), and the tour overlay reads it.
        .environment(model.onboarding)
        .environment(explainCoordinator)
        // Declares the `explainRoot` named space AND mounts m23-ag's capture-space
        // probe on the SAME view, so the probe's AppKit bounds ARE the space's
        // bounds. One modifier, not two, so the pair cannot be separated by a later
        // edit — and so a layout modifier can never be slipped between them.
        .explainCoordinateSpaceRoot()
        .onPreferenceChange(ExplainFramePreferenceKey.self) { frames in
            explainCoordinator.setFrames(frames)
        }
        .overlay {
            ExplainOverlay(explain: model.explain, coordinator: explainCoordinator,
                           onAskCopilot: askCopilotAboutControl)
        }
        // The guided tour card, OUTERMOST so it floats above every panel + the
        // Settings modal; its empty area is click-through, so the user can operate
        // the very controls it points at (the completion signal advances the step).
        .overlay {
            OnboardingTourOverlay(
                model: model.onboarding,
                coordinator: explainCoordinator,
                onPrimary: performTourPrimary,
                onSkipStep: { model.onboarding.skipStep() },
                onSkipTour: { withAnimation(.easeOut(duration: 0.18)) { model.onboarding.dismissTour() } }
            )
        }
        // Crash-recovery offer (M9 crash-b), OUTERMOST so it blocks the workspace
        // at launch until the user restores or discards. Same store path as the
        // project.recover command; staged for captures via debug.recoveryOffer.
        .overlay {
            if let offer = model.recoveryOffer {
                RecoveryOfferView(
                    status: offer,
                    onRestore: { model.restoreFromRecovery() },
                    onDiscard: { model.discardRecovery() }
                )
            }
        }
        // m10-s: the offer can also be resolved WITHOUT the sheet — `project.recover`
        // over the control wire, or a `project.new`/`project.open` that supersedes the
        // snapshot. Those flip `store.recoveryOfferAvailable` false without touching the
        // one-shot `recoveryOffer` snapshot, so the sheet used to linger. Mirror the
        // buttons' dismissal on the available→unavailable transition. Transition-based
        // (not a derived `if available` gate) so `debug.recoveryOffer` staging — which
        // sets `recoveryOffer` while the store flag stays false — still shows for
        // captures. The double-clear when the sheet's OWN buttons resolve is harmless:
        // both paths set `recoveryOffer = nil` with the same animation.
        .onChange(of: store.recoveryOfferAvailable) { _, available in
            if !available, model.recoveryOffer != nil {
                withAnimation(.easeOut(duration: 0.18)) { model.recoveryOffer = nil }
            }
        }
        .background { explainEscHandler }
        .onChange(of: model.explain.isActive) { _, active in
            if !active { explainCoordinator.reset() }
        }
        .preferredColorScheme(.dark)
        // The MEASURED window floor (m10-j): the smallest window at which all fixed
        // chrome (header, arrange toolbar, transport, a timeline sliver, the editor
        // at its max fraction) stays visible; the arrange track area SCROLLS past it.
        // Also enforced on the NSWindow via `applyWindowFloor()` (belt-and-suspenders).
        .frame(minWidth: WindowFloor.minWidth, minHeight: WindowFloor.minHeight)
        // Window title tracks the session; " — Edited" marks unsaved changes.
        .navigationTitle(store.projectName + (store.isDirty ? " — Edited" : ""))
        .onAppear(perform: maybeAutoOpen)
        // First-launch offer: the welcome card IS the offer (Skip tour dismisses
        // forever). Idempotent — no-ops once active or terminal.
        .onAppear { model.offerTourIfEligible() }
        // m10-t: resolve the API-key rows via the NON-BLOCKING presence probe only
        // AFTER the window exists — never in `AppModel.init`, where a stored key on
        // a rebuilt/foreign-identity binary used to hang startup on the Keychain
        // consent dialog before any UI (or the control server) came up. The probe
        // runs off the main actor inside `refresh()`.
        .task { await model.settings.refresh() }
        .onChange(of: firstMIDIClipID) { _, _ in maybeAutoOpen() }
        // Any clip stretch/pitch/formant change (from a drag OR the control port)
        // kicks the engine-status poll, so the timeline shimmers a clip while its
        // offline stretch render is pending and clears when it lands (M5 ii-e).
        .onChange(of: stretchSignature) { _, _ in model.noteStretchEdit() }
    }

    /// Hash of every clip's stretch parameters — changes exactly when a stretch
    /// edit lands, driving the render-status poll (`.onChange` above).
    private var stretchSignature: Int {
        var hasher = Hasher()
        for track in store.tracks {
            for clip in track.clips {
                hasher.combine(clip.id)
                hasher.combine(clip.stretchRatio)
                hasher.combine(clip.pitchShiftSemitones)
                hasher.combine(clip.formantPreserve)
            }
        }
        return hasher.finalize()
    }

    /// The instrument + AU-effect picker modals (m10-n / m13-g), extracted from
    /// `body` so the long overlay chain type-checks. Both are centered dark-glass
    /// modals rendered inside the window (so `debug.captureUI` can snapshot them);
    /// each routes selection through the SAME store method the wire uses.
    @ViewBuilder
    private var pickerOverlays: some View {
        // ⌘= alias for Zoom In (m17-b): macOS convention answers BOTH ⌘+ (the
        // View-menu item — physically ⌘⇧=) and bare ⌘=. A menu item carries ONE
        // key equivalent, so the alias is a hidden in-window shortcut — folded
        // into this always-present overlay builder so the root body chain gains
        // no new modifier link (the chain sits at the type-checker's limit).
        // Routes through the m21-c focus router, like the menu item it aliases.
        Button("") { model.zoomIn() }
            .keyboardShortcut("=", modifiers: .command)
            .buttonStyle(.plain)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
        if model.instrumentPickerTrackID != nil {
            InstrumentPickerOverlay(
                model: model.instrumentPicker,
                densityStore: model.panelDensity,
                onChoose: { model.applyInstrumentChoice($0) },
                onImport: { model.importSoundBankViaPanel() },
                onImportSampleLibrary: { model.importSampleLibraryViaPanel() },
                onTunePolySynth: { withAnimation(.easeOut(duration: 0.15)) { model.openPolySynthEditorFromPicker() } },
                onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeInstrumentPicker() } }
            )
        }
        // Poly Synth editor: the effect editor's instrument twin — opened by
        // the instrument picker's TUNE affordance (replacing the picker; one
        // centered card at a time) and `debug.synthEditor`. Every knob routes
        // through the SAME `store.setInstrument` the wire's
        // `track.setInstrument` calls; the store's per-track coalescing makes
        // a whole drag ONE undo step. The kind gate drops the card honestly if
        // the instrument is swapped (e.g. a wire setInstrument) while open.
        if model.polySynthEditorTrackID != nil, model.polySynthEditor.targetIsPolySynth {
            PolySynthEditorOverlay(
                model: model.polySynthEditor,
                onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closePolySynthEditor() } }
            )
        }
        // AU-effect picker (m13-g, audit F6): opened by a Pro channel/bus strip's
        // insert add-menu "Audio Units…" item; UI-only — Add routes through the SAME
        // `store.addEffect(kind:.audioUnit)` the wire uses. Never opened for master.
        if model.effectPickerTrackID != nil {
            EffectPickerOverlay(
                model: model.effectPicker,
                trackName: model.effectPickerTrackName,
                onChoose: { config in withAnimation(.easeOut(duration: 0.15)) { model.applyEffectChoice(config) } },
                onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeEffectPicker() } }
            )
        }
        // Built-in insert effect editor (m17-a): the FIFTH centered dark-glass
        // modal (Settings / Instrument Picker / Quantize / Undo History) — opened
        // by clicking a built-in InsertRow or auto-opened by the UI insert add
        // (never by the wire's fx.add). Every slider routes through the SAME
        // `store.setEffectParam`/`setMasterEffectParam` the wire's `fx.setParam`
        // calls. The descriptor gate drops the card honestly if the insert is
        // removed (e.g. a wire `fx.remove`) while it is open.
        if model.effectEditorTarget != nil, model.effectEditor.descriptor != nil {
            EffectEditorOverlay(
                model: model.effectEditor,
                curveModel: model.eqCurveEditor,
                densityStore: model.panelDensity,
                // The EQ curve card's spectrum (m23-r3): resolved against the
                // card's CURRENT target each tick — the master mix for a master
                // insert, this insert's own armed tap for a track one — with
                // the seed overrides first (the `vibeSeed`/`grSeed` idiom).
                spectrum: { model.effectEditorSpectrum() },
                // The plot's caption, resolved at its one home — the pre-fader
                // (track) / post-fader (master) labelling law. `debug
                // .effectEditor` reports this same property.
                curveHelp: model.effectEditorCurveHelp,
                // The instrument frequency guide (m23-o2), resolved at its one
                // home — `debug.effectEditor` reports this same property.
                instrumentGuide: model.effectEditorInstrumentGuide,
                onPlotWidth: { model.effectEditorPlotWidth = $0 },
                // The tap's arm lifecycle, run as the spectrum layer's
                // `.task(id:)` body — the app owns the arm, the layer owns
                // when it lives (the single-consumer invariant, AppModel).
                holdSpectrum: { await model.holdInsertSpectrum() },
                // The kind's drawn honesty disclosure (m23-p2), resolved at its
                // one home — `debug.effectEditor` reports this same property.
                honestyNote: model.effectEditorHonestyNote,
                onCardMeasured: { width, height in
                    model.effectEditorCardWidth = width
                    model.effectEditorCardHeight = height
                },
                onHonestyStyle: { role, face, ink in
                    model.effectEditorHonestyStyle.record(role: role, face: face, ink: ink)
                },
                // The dynamics kinds' GAIN REDUCTION poll (m22-e): resolved
                // against the card's CURRENT target each tick (grSeed override
                // first — the scopeSeed idiom — else the live store tap).
                gainReduction: {
                    guard let target = model.effectEditorTarget else { return nil }
                    return model.gainReductionDb(trackID: target.trackID,
                                                 effectID: target.effectID)
                },
                onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeEffectEditor() } }
            )
        }
        // REFERENCE panel (m22-g P3): the comparison surface, opened by the
        // master strip's REFERENCE row (or `debug.referenceSeed {panel:true}`).
        // Declared in this always-present overlay builder — NOT inside the Mix
        // workspace — so the root body chain gains no new modifier link (the
        // ⌘= alias rule) and a wire-driven capture can stage it from either
        // workspace. NO VIOLET: a reference is user material, not AI content.
        if model.referencePanel.isOpen {
            ReferencePanelView(
                model: model.referencePanel,
                compare: { model.referenceCompareForUI() },
                onClose: { model.closeReferencePanel() }
            )
        }
        // Unified generation-progress card (m17-h): the canonical violet status
        // surface — EVERY generation job (Sketchpad, wire/MCP, import paths)
        // reports here. An IN-WINDOW card floated bottom-trailing above the
        // transport bar's right status cluster (the engine-notices slot), never
        // a popover, so `debug.captureUI` snapshots it. Present in BOTH
        // workspaces (a wire job can land any time); folded into this
        // always-present overlay builder so the root body chain gains no new
        // modifier link (the ⌘= alias rule — the chain sits at the
        // type-checker's limit). Status chrome sits UNDER the centered modals
        // above by declaration order — a modal legitimately covers it.
        if model.generationPresence.isVisible {
            GenerationPresenceCard(presence: model.generationPresence)
                .padding(.trailing, 24)
                .padding(.bottom, 84)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .transition(.opacity)
        }
    }

    /// The arrange workspace with the DELETE-key scope wrapped around it — the
    /// ONLY place `ArrangeDeleteKey` is mounted (see that type for why placement
    /// is the entire safety argument).
    ///
    /// THE `VStack` IS LOAD-BEARING, not cosmetic. `arrangeWorkspace` is a
    /// `@ViewBuilder`, so it returns a `TupleView` of three children (toolbar,
    /// timeline row, optional editor pane). A modifier applied to a multi-view
    /// builder result DISTRIBUTES to each child — which would give this modifier
    /// three independent `@FocusState`s all asserting focus on the same nonce, i.e.
    /// a focus fight. Collapsing the tuple into one view first makes the modifier
    /// apply exactly once. The `spacing: 10` matches the enclosing `VStack`, so
    /// the three children keep byte-identical spacing (the gate re-derives the
    /// lane pitch from pixels and would fail loudly if this shifted anything).
    private func arrangeDeleteKeyScope(_ geo: GeometryProxy) -> some View {
        VStack(spacing: 10) { arrangeWorkspace(geo) }
            .modifier(ArrangeDeleteKey(model: model))
    }

    /// The Arrange surface: track list + timeline, with the piano roll docked
    /// below when a MIDI clip is open. Extracted so `body` can switch it against
    /// the Mix console without duplicating the header/transport chrome.
    @ViewBuilder
    private func arrangeWorkspace(_ geo: GeometryProxy) -> some View {
        arrangeToolbar
        HStack(spacing: 10) {
            // Ruler-block pinning (m13-g): the ruler + loop band + marker lane +
            // tempo lane + TRACKS header PIN in a block ABOVE the shared vertical
            // scroll (a sibling in the VStack, so it never scrolls away), while the
            // ScrollView below still owns BOTH columns (rows + lanes) as ONE unit —
            // the m10-j no-desync invariant is preserved (there is still exactly one
            // vertical scroll for both columns). The pinned ruler stays HORIZONTALLY
            // synced with the lanes: the `.lanes` instance reports its scroll offset
            // into `arrangeHScroll` and the `.ruler` instance mirrors it. The
            // Sketchpad/ClipFix side panels stay OUTSIDE this at full height.
            GeometryReader { trackGeo in
                let sidebarW = model.panelLayout.sidebarWidth
                let bodyViewport = max(0, trackGeo.size.height
                                       - TimelineLanesView.rulerHeight - Self.arrangeBlockGap)
                // The lanes viewport WIDTH (m17-b): total minus the sidebar, the
                // 6 pt splitter, and the two 10 pt HStack gaps — identical in the
                // pinned ruler row and the scrolling row, so one value serves the
                // zoom anchor math and the zoomed-out padding heuristic.
                let lanesViewportW = max(0, trackGeo.size.width - sidebarW - 6 - 20)
                // `alignment: .leading` (m17-b, measured): the pinned block and the
                // shared vertical scroll MUST share a leading edge — the ruler's
                // beat→x math assumes the columns start at the same x. Under the
                // default center alignment this macOS laid the scroll subtree out
                // 6 pt right of the pinned row (a half-scroller phantom width),
                // statically skewing every lanes gridline off its ruler tick.
                VStack(alignment: .leading, spacing: Self.arrangeBlockGap) {
                    // PINNED RULER BLOCK — both columns, fixed at rulerHeight.
                    HStack(spacing: 10) {
                        TracksHeaderBar()
                            .frame(width: sidebarW, height: TimelineLanesView.rulerHeight)
                            .glassPanel()
                        // Spacer matching the 6pt sidebarSplitter below, so the pinned
                        // ruler lines up with the scrolling lanes.
                        Color.clear.frame(width: 6)
                        arrangeTimeline(.ruler, viewport: 0)
                            .glassPanel()
                    }
                    // Pin the block to exactly `rulerHeight`. Without this the 6pt
                    // `Color.clear` spacer (which has no height) is vertically greedy,
                    // so the VStack splits its space ~50/50 between this block and the
                    // scroll below — leaving the ruler floating mid-panel (m13-g fix).
                    .frame(height: TimelineLanesView.rulerHeight)
                    // SHARED VERTICAL SCROLL — owns both columns (m10-j preserved).
                    ScrollViewReader { proxy in
                        ScrollView(.vertical) {
                            HStack(spacing: 10) {
                                TrackRowsList()
                                    .frame(width: sidebarW)
                                // Draggable sidebar↔timeline splitter (beta m10-d).
                                sidebarSplitter
                                arrangeTimeline(.lanes, viewport: bodyViewport)
                            }
                            // Fill the viewport when content is short (glass panels stay
                            // full height); grow past it when tall (scroll takes over).
                            .frame(minHeight: bodyViewport, alignment: .top)
                        }
                        // Deep-scroll proof (m13-g G3): `debug.arrangeScroll` sets a
                        // target track id + bumps a nonce; the shared scroll jumps to
                        // it so a capture can frame the bottom of a deep session with
                        // the block pinned. (Nonce, not the id, so a repeat still fires.)
                        .onChange(of: model.arrangeScrollNonce) { _, _ in
                            guard let target = model.arrangeScrollTarget else { return }
                            withAnimation(.easeOut(duration: 0.25)) {
                                proxy.scrollTo(target,
                                               anchor: model.arrangeScrollToBottom ? .bottom : .top)
                            }
                        }
                    }
                }
                // Report the live lanes viewport width to the zoom model (m17-b) —
                // onChange (not inline) so the model mutation never runs mid-render.
                .onChange(of: lanesViewportW, initial: true) { _, w in
                    model.arrangeViewportWidth = w
                }
                // FOLLOW THE PLAYHEAD (m23-c2) — driven from the TRANSPORT
                // observation path, never from a geometry callback: a `scrollTo`
                // issued inside a layout transaction moves layout but does not
                // durably update the scroller's position (m17-b, measured), and
                // `debug.captureUI`'s `cacheDisplay` forces exactly the re-render
                // that would then jump. `positionBeats` is plain `@Observable`
                // state pushed by the engine's playhead handler (~30 Hz), so this
                // fires on real playback and on nothing else.
                .onChange(of: store.transport.positionBeats) { _, _ in
                    model.followArrangeTick()
                }
                // Pressing play is the moment a user expects the view to take
                // charge again, so a start clears any manual-scroll suspension.
                .onChange(of: store.transport.isPlaying) { _, playing in
                    if playing { model.rearmFollow() }
                }
            }

            if model.showSketchpad {
                SketchpadView(model: model.sketchpad)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if model.showClipFix {
                ClipFixPanel(model: model.clipFix)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if model.showVoicePanel {
                VoicePanel(model: model.voicePanel)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxHeight: .infinity)
        // Keep the fix panel's composer pointed at the live audio selection. The
        // panel is thin over the model, so the view (not the model) reads the
        // selection and seeds the composer target; deselecting an audio clip
        // collapses the composer to its hint (the jobs strip keeps running).
        .onChange(of: selectedAudioClipKey) { _, _ in syncClipFixTarget() }
        .onChange(of: model.showClipFix) { _, _ in syncClipFixTarget() }

        if let clip = selectedMIDIClip {
            // Draggable editor-height splitter (beta m10-d) on the editor's top edge.
            // Drag UP grows the piano roll; the store clamps the fraction to 0.30–0.55
            // (0.55 keeps the app chrome visible at the height the app runs at; a
            // smaller window can still overflow at the max → m10-j).
            editorSplitter(geoHeight: geo.size.height)
            PianoRollView(
                clip: clip,
                // m12-d (design row 74, v1 policy: one meter per clip view): the
                // grid uses the meter GOVERNING THE CLIP'S START beat, so a clip in
                // a 7/8 section rules bars every 7 beats and a 4/4 clip every 4.
                beatsPerBar: store.transport.meterMap.beatsPerBar(atBeat: clip.startBeat),
                // The SAME transport source the arrange timeline consumes (no second
                // ticker) — the piano roll playhead is a rendering of this state.
                positionBeats: store.transport.positionBeats,
                // m23-c2: follow keeps the playhead in frame during PLAYBACK only.
                isPlaying: store.transport.isPlaying,
                densityStore: model.panelDensity,
                // m21-c: the shared layout store carries the persisted
                // piano-roll zoom slot (`pianoRollPPB`) the editor scales by, and
                // (m23-c2) the ONE `followPlayhead` flag both surfaces read.
                layout: model.panelLayout,
                // m23-c2: the roll's follow runtime, held by the app so it survives
                // a clip switch and `debug.followPlayhead` can echo it.
                follow: model.pianoRollFollow,
                onCommit: { notes in _ = try? store.setClipNotes(clipID: clip.id, notes: notes) },
                // Scrub seeks through the app's store seek (the existing transport.seek
                // path), NOT the WebSocket. Refused mid-record → try? swallows it.
                onSeek: { beats in _ = try? store.seek(toBeats: beats) },
                // Bar ops (m10-h) route through the store's time-range primitives and
                // return the updated clip so the piano roll can reseed its edit model.
                onDeleteTimeRange: { start, len in
                    try? store.deleteTimeRange(clipID: clip.id, startBeat: start, lengthBeats: len)
                },
                onInsertTimeRange: { at, len in
                    try? store.insertTimeRange(clipID: clip.id, atBeat: at, lengthBeats: len)
                },
                onOpenQuantize: { model.openQuantizePanel(clipID: clip.id) },
                // Controller strip (m16-b4) commits through the same store call the
                // clip.setControllerLane wire verb uses; returns the updated clip so
                // the strip reseeds its edit model.
                onCommitControllerLane: { type, points in
                    try? store.setControllerLane(clipID: clip.id, type: type, points: points)
                },
                onClose: { selectedClipID = nil },
                // m23-d: hear the pitch you drag, and the key you press in the
                // gutter. The defeat switch is checked HERE rather than in the
                // view, so the view keeps zero audition policy — and the
                // `note.audition` wire verb, which does not come through here,
                // deliberately ignores it.
                onAudition: { pitches, velocity in
                    guard model.panelLayout.auditionEnabled else { return }
                    guard let trackID = trackID(ofClip: clip.id) else { return }
                    _ = try? store.auditionPitches(trackID: trackID, pitches: pitches,
                                                   velocity: velocity)
                },
                // m21-c/m23-al: the roll's SwiftUI key-focus report. Still fed,
                // still echoed — but NOTHING ROUTES ON IT any more. It is an
                // instrument for the divergence between "who holds focus" and
                // "which surface is active" (see `AppModel.pianoRollEditorFocused`
                // for the measurement that demoted it).
                onFocusChange: { model.pianoRollEditorFocused = $0 },
                // m23-al: the roll reports that the user just ACTED inside it —
                // the one closure behind its eight gesture funnels. THIS is what
                // ⌘+/⌘−/⌘0 route on, via `EditorSurfaceRouter`.
                onEngage: { model.editorEngagement.engage(.pianoRoll) },
                // m23-x: the roll publishes whether it holds a NOTE selection,
                // which is what the arrange's arrow-key nudge refuses on (with
                // focus). Same object carries the debug seam's staged selection
                // back in — see `PianoRollNoteSelectionBridge`.
                noteSelection: model.pianoRollNoteSelection,
                // m23-t: the bar-ops readout publishes the string and ink it
                // DREW, from inside the drawing arguments themselves, so
                // `debug.pianoRollBarOps` reports the pixels rather than a
                // re-derivation. The ledger is deliberately non-observable —
                // this write happens during `body`.
                onBarOpsStyle: { role, text, ink in
                    model.pianoRollBarOpsStyle.record(role: role, text: text, ink: ink)
                }
            )
            .id(clip.id)
            .frame(height: geo.size.height * model.panelLayout.editorFraction)
        }
    }

    /// Builds one arrange-timeline instance in the given render mode (m13-g). The
    /// SAME big param set drives both the pinned `.ruler` block and the scrolling
    /// `.lanes` body — the two share geometry (contentWidth/beat scale) so bar lines
    /// align, and stay horizontally synced via `arrangeHScroll` (the `.lanes`
    /// instance reports its offset; the `.ruler` mirrors it). `viewport` is the
    /// vertical space the lanes fill when content is short (0 for the ruler).
    @ViewBuilder
    private func arrangeTimeline(_ content: ArrangeContent, viewport: CGFloat) -> some View {
        TimelineLanesView(
            tracks: store.tracks,
            positionBeats: store.transport.positionBeats,
            selection: model.arrangeSelection,
            onSelectClip: selectClip,
            onSelectionRendered: { model.arrangeSelectionRenderSeq &+= 1 },
            // m23-g2: the group-drag seam's "the lanes have run" signal.
            onClipLayoutRendered: { model.arrangeClipLayoutRenderSeq &+= 1 },
            expandedTrackIDs: model.expandedAutomationTrackIDs,
            selectedLaneByTrack: model.automationLaneSelection,
            onCommitPoints: { trackID, laneID, points in
                _ = try? store.setAutomationPoints(trackID: trackID, laneID: laneID, points: points)
            },
            // m23-ai: the arrow-key nudge's SIXTH guard reads this. Every
            // automation lane editor these lanes mount reports its own breakpoint
            // selection into it, so ← / → with a point selected edits the point
            // rather than sliding the whole clip underneath the open lane.
            automationPointSelection: model.automationPointSelection,
            snap: model.clipSnap,
            // m12-d: route the waveform seconds-per-beat through the tempo-map API.
            // Base-tempo scalar (segment 0); clips crossing a non-trivial boundary
            // carry the amber honesty hint instead.
            secondsPerBeat: store.transport.tempoMap.secondsPerBeat(atBeat: 0),
            waveformStore: model.waveformStore,
            densityStore: model.panelDensity,
            // Global track-row height (beta m10-d) — the SAME store value the sidebar
            // rows use, so lanes and headers stay pixel-aligned.
            rowHeight: model.panelLayout.rowHeight,
            // Arrange zoom (m17-b): the SAME store value drives the pinned ruler
            // and the lanes, so both columns rescale in one update.
            pixelsPerBeat: model.panelLayout.arrangePPB,
            availableWidth: model.arrangeViewportWidth,
            // Pinch zoom, anchored at the pointer — the model owns the math.
            onPinchZoomChanged: { x, m in
                model.arrangePinchChanged(anchorContentX: x, magnification: m)
            },
            onPinchZoomEnded: { model.arrangePinchEnded() },
            // The shared-scroll viewport height (m10-j): the lanes fill it when short.
            availableHeight: viewport,
            // m23-g2: a body drag goes through the group verb, ALWAYS — there is
            // no count==1 special case, so a single-clip drag and a three-clip
            // drag are the same code path (and `moveClipsLabel` keeps the
            // single-clip undo entry reading exactly as it did before).
            // `trackID` is unused: the move is id-addressed and same-track by
            // construction (there is no cross-track drag — see `moveClips`).
            onMoveClip: { _, clip, anchorOriginalStart, rawDragDeltaBeats in
                model.dragArrangeClips(anchorClipID: clip.id,
                                       anchorOriginalStart: anchorOriginalStart,
                                       rawDragDeltaBeats: rawDragDeltaBeats).anchorStart
            },
            onTrimClip: { trackID, clip, newStart, newLength in
                _ = try? store.trimClip(trackId: trackID, clipId: clip.id,
                                        newStartBeat: newStart, newLengthBeats: newLength)
            },
            // Fit to Content (m21-d, Pro clip menu): one store call — MIDI trims
            // to the last note's end, audio to the remaining source duration.
            onFitClipToContent: { trackID, clip in
                _ = try? store.fitClipToContent(trackId: trackID, clipId: clip.id)
            },
            onSplitClip: { trackID, clip, atBeat in
                // m17-c: refusals (comp member, outside-span) surface VERBATIM
                // as an amber bubble on the clip — the same message the wire's
                // `clip.split` returns (the double-click and the verb share
                // `ProjectStore.splitClip`, so the copy is identical by
                // construction).
                do { _ = try store.splitClip(trackId: trackID, clipId: clip.id, atBeat: atBeat) }
                catch { model.presentArrangeSplitRefusal(error, clipID: clip.id) }
            },
            onSetClipFades: { trackID, clip, fadeIn, fadeOut, inCurve, outCurve in
                _ = try? store.setClipFades(trackId: trackID, clipId: clip.id,
                                            fadeInBeats: fadeIn, fadeOutBeats: fadeOut,
                                            fadeInCurve: inCurve, fadeOutCurve: outCurve)
            },
            onSetClipGain: { trackID, clip, gainDb in
                _ = try? store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: gainDb)
            },
            onSetClipGainEnvelope: { trackID, clip, points in
                _ = try? store.setClipGainEnvelope(trackId: trackID, clipId: clip.id, points: points)
            },
            onStretchClip: { trackID, clip, toLength in
                _ = try? store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: toLength)
            },
            // Quantize & groove (m11-a): the arrange clip context menu (Pro, sp-c)
            // opens the SAME panel the piano roll does.
            onOpenQuantize: { clip in model.openQuantizePanel(clipID: clip.id) },
            onExtractGroove: { clip in
                model.openQuantizePanel(clipID: clip.id, startExtract: true)
            },
            // Convert to voice (m10-p-5, Pro clip menu): opens the sheet, which
            // rides the SAME seams as the wire's vc.convertVocals.
            onConvertToVoice: { clip in model.openVoiceConvert(clipID: clip.id) },
            // Crossfade two adjacent/overlapping audio clips (m11-d, Pro clip menu).
            onCrossfadeClips: { trackID, clipID, otherClipID, length in
                _ = try? store.crossfadeClips(trackId: trackID, clipId: clipID,
                                              otherClipId: otherClipID, lengthBeats: length)
            },
            stretchStatus: { clip in model.stretchStatus(for: clip.id) },
            expandedTakeTrackIDs: model.expandedTakeTrackIDs,
            onSetTakeComp: { trackID, groupID, segments in
                _ = try? store.setCompSegments(trackId: trackID, groupId: groupID, segments: segments)
            },
            onSelectTake: { trackID, groupID, laneID in
                _ = try? store.selectTake(trackId: trackID, groupId: groupID, laneId: laneID)
            },
            onFlattenTakeGroup: { trackID, groupID in
                _ = try? store.flattenTakeGroup(trackId: trackID, groupId: groupID)
            },
            onRemoveTakeLane: { trackID, groupID, laneID in
                _ = try? store.removeTakeLane(trackId: trackID, groupId: groupID, laneId: laneID)
            },
            // Loop region ruler (beta m10-g): loop state flows in by value so an
            // agent's `transport.setLoop` over the wire updates the band live; the
            // callbacks route through the pre-existing store methods.
            isLoopEnabled: store.transport.isLoopEnabled,
            loopStartBeat: store.transport.loopStartBeat,
            loopEndBeat: store.transport.loopEndBeat,
            onSetLoop: { enabled, start, end in
                _ = try? store.setLoop(enabled: enabled, startBeat: start, endBeat: end)
            },
            onSeek: { beat in _ = try? store.seek(toBeats: beat) },
            // Session markers (m11-c): markers flow in by value from the store.
            markers: store.markers,
            onAddMarker: { beat in _ = store.addMarker(beat: beat) },
            onMoveMarker: { markerID, beat in _ = try? store.moveMarker(id: markerID, beat: beat) },
            onRenameMarker: { markerID, name in _ = try? store.renameMarker(id: markerID, name: name) },
            onRemoveMarker: { markerID in try? store.removeMarker(id: markerID) },
            stageRenameMarkerID: model.stagedMarkerRenameID,
            // Pointer affordances (m17-c): the debug-staged pointer event flows
            // down; the live zone/ghost state flows back up so the seam echoes
            // ground truth; a split refusal flows down to the refused block.
            stagePointer: model.arrangePointerStage,
            onPointerState: { zone, ghost in
                model.arrangePointerZone = zone.rawValue
                model.arrangeGhostBeat = ghost
                // m23-e: the seam's "the view has run" signal — see
                // `arrangePointerReportSeq`. Bumped LAST so the zone/ghost it
                // announces are already stored.
                model.arrangePointerReportSeq &+= 1
            },
            splitRefusal: model.arrangeSplitRefusal,
            // m23-e: an empty-lane double-click is the beginner's path from a
            // fresh instrument track to a writable grid. ONE store call — the
            // same `ProjectStore.addMIDIClip` the `clip.addMIDI` wire verb uses,
            // so it is one undo step — then select the new clip, which is what
            // OPENS the piano roll on it. On an audio/bus lane the store refuses
            // with `midiClipsRequireInstrumentTrack` and the message surfaces
            // VERBATIM on that lane: never a silent no-op, since "nothing
            // happened and nothing said why" is the very complaint this fixes.
            onCreateMIDIClip: { trackID, beat, length in
                do {
                    let clip = try store.addMIDIClip(toTrack: trackID, atBeat: beat,
                                                     lengthBeats: length)
                    model.noteCreatedClip(clip.id)
                } catch {
                    model.presentArrangeLaneRefusal(error, trackID: trackID, beat: beat)
                }
            },
            // m23-v: the VISIBLE half of m23-e. The lanes compose the hint set
            // once, draw it, and report THAT value up — never a re-derivation
            // here, which is what keeps `debug.arrangePointer`'s echo an
            // observation of the pixels rather than a second opinion about them.
            onEmptyLaneHints: { hints in
                model.arrangeEmptyLaneHints = hints
                // Bumped LAST so the hints it announces are already stored (the
                // `arrangePointerReportSeq` rule).
                model.arrangeEmptyLaneHintSeq &+= 1
            },
            // Rubber band (m23-g3): the staged step flows down; the band + its
            // hits flow back up so `debug.arrangeMarquee` echoes ground truth,
            // and the RESOLVED lane ladder flows up on its own path so a BARE
            // seam read can answer it before any drag exists.
            stageMarquee: model.arrangeMarqueeStage,
            onMarqueeSelect: { hits, base, additive in
                model.applyArrangeMarquee(hits: hits, base: base, additive: additive)
            },
            onMarqueeState: { band, hits in
                model.arrangeMarqueeBand = band
                model.arrangeMarqueeHits = hits
                // Bumped LAST so the state it announces is already stored (the
                // `arrangePointerReportSeq` rule).
                model.arrangeMarqueeReportSeq &+= 1
            },
            onLaneGeometry: { geometry in model.arrangeLaneGeometry = geometry },
            // Audio import via drag-drop (beta m10-k). m23-f: the per-file
            // results are RETAINED (not discarded) so the drop seam can echo
            // what actually landed — the drop path used to throw them away, so a
            // file the store refused vanished without a trace.
            onImportFiles: { urls, targetTrackID, landing in
                model.arrangeDropImportResults = model.importFiles(
                    urls: urls, targetTrackID: targetTrackID, startBeat: landing)
            },
            // Drop staging (m23-f): the staged drag phase flows down; the live
            // hover + the handler's decision flow back up so `debug.arrangeDrop`
            // echoes ground truth.
            stageDrop: model.arrangeDropStage,
            onDropState: { live, decided in
                model.arrangeDropHover = live
                model.arrangeDropDecided = decided
                // Bumped LAST so the state it announces is already stored (the
                // `arrangePointerReportSeq` rule).
                model.arrangeDropReportSeq &+= 1
            },
            onDropHoverChange: { live in
                model.arrangeDropHover = live
                model.arrangeDropReportSeq &+= 1
            },
            // Tempo + meter maps (m12-d): the RESOLVED maps flow in by value.
            meterMap: store.transport.meterMap,
            tempoMap: store.transport.tempoMap,
            tempoLane: model.tempoLaneModel,
            isRecordingTransport: store.transport.isRecording,
            // Ruler-block pinning (m13-g): the render mode + horizontal-sync wiring.
            content: content,
            hScrollOffset: arrangeHScroll,
            onHScrollChange: {
                // The live report is ground truth: it drives the ruler mirror, the
                // `reported` copy the debug seams echo (m17-b — a zoom's analytic
                // write touches only the mirror, so `reported` can't lie), and
                // follow's manual-scroll detector (m23-c2).
                model.reportArrangeHScroll($0)
            },
            // The programmatic scroll request: a zoom's anchor-preserving offset
            // (m17-b) or a follow page turn (m23-c2), applied by the lanes'
            // `ScrollViewReader` in the same update as whatever drove it.
            hScrollApplyTarget: model.arrangeHScrollApplyTarget,
            hScrollApplyNonce: model.arrangeHScrollApplyNonce,
            // The laid-out content width — follow's clamp ceiling (m23-c2).
            onContentWidthChange: { model.arrangeContentWidth = $0 }
        )
    }

    /// The vertical hairline between the track sidebar and the timeline (beta
    /// m10-d). A body drag adjusts `panelLayout.sidebarWidth` live; the store clamps.
    private var sidebarSplitter: some View {
        PanelSplitter(axis: .vertical) { translation in
            if sidebarDragOrigin == nil { sidebarDragOrigin = model.panelLayout.sidebarWidth }
            let origin = sidebarDragOrigin ?? PanelLayoutStore.defaultSidebarWidth
            model.panelLayout.setSidebarWidth(origin + translation.width)
        } onEnded: {
            sidebarDragOrigin = nil
        }
    }

    /// The horizontal hairline on the bottom editor's top edge (beta m10-d). A drag
    /// UP grows the editor (negative height delta → larger fraction); converting
    /// points→fraction against the live window height keeps the drag 1:1 with the
    /// pointer. The store clamps the fraction.
    private func editorSplitter(geoHeight: CGFloat) -> some View {
        PanelSplitter(axis: .horizontal) { translation in
            if editorDragOrigin == nil { editorDragOrigin = model.panelLayout.editorFraction }
            let origin = editorDragOrigin ?? PanelLayoutStore.defaultEditorFraction
            let deltaFraction = -translation.height / max(1, geoHeight)
            model.panelLayout.setEditorFraction(origin + deltaFraction)
        } onEnded: {
            editorDragOrigin = nil
        }
    }

    /// A tap selects any clip (brightening it and revealing its gain readout);
    /// only a MIDI clip additionally opens the piano roll (`selectedMIDIClip`
    /// filters audio out, so the panel stays closed for audio selections).
    ///
    /// m23-g1: shift/⌘ toggles instead of replacing. The decision and the state
    /// change both live on `AppModel.clickClip`, which the
    /// `debug.arrangeSelection` seam calls too — this is the thin view edge, not
    /// a second copy of the rule.
    private func selectClip(_ clip: Clip, _ modifiers: ArrangeClickModifiers) {
        model.clickClip(id: clip.id, modifiers: modifiers)
    }

    /// Arrange-header strip: label + (in Pro) the grid-snap picker, then the
    /// workspace's SIMPLE/PRO density chip pinned top-right — the same slot the
    /// snap picker used to own alone. This mirrors the piano-roll header exactly
    /// (the shared `SimpleProToggle`, with the snap picker rendered BESIDE it in Pro
    /// only): the whole arrange surface is ONE panel (`TimelineLanesView.panelID`),
    /// so the chip gates every clip's trim/fade/split/gain/stretch at once and locks
    /// the grid to Bar in Simple (docs/DESIGN-LANGUAGE.md "Clip editing").
    private var arrangeToolbar: some View {
        HStack(spacing: 8) {
            Text("ARRANGE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            if selectedAudioClip != nil {
                clipFixToggle
                    .explainable(.aiFix)
            }
            // FOLLOW (m23-c2) — seated with the zoom cluster because both are view
            // NAVIGATION, and shown in both densities for the same reason. ONE chip
            // governs both following surfaces: the piano roll is docked INSIDE this
            // workspace, so this toolbar is on screen whenever either surface is,
            // and a second copy in the roll's header would be one value wearing two
            // faces. It is deliberately absent from the Mix console's toolbar —
            // there is no playhead to follow there.
            followChip
                .explainable(.arrangeFollow)
            // Arrange zoom cluster (m17-b) — seated beside the SNAP chip; shown in
            // BOTH densities (zoom is view navigation, not Pro edit chrome).
            zoomCluster
                .explainable(.arrangeZoom)
            if arrangeIsPro {
                snapPicker
                    .explainable(.arrangeSnap)
            }
            historyToggle
                .explainable(.editHistory)
            SimpleProToggle(
                store: model.panelDensity,
                panelID: TimelineLanesView.panelID,
                help: "Simple: move clips on a bar grid. Pro: trim, fade, split, gain, stretch, snap."
            )
            .explainable(.panelDensity)   // shared density id (ex-b)
        }
        .padding(.horizontal, 4)
    }

    /// FOLLOW chip (m23-c2): keeps the playhead in frame during playback, on the
    /// arrange lanes AND the piano-roll bands. THREE faces, because two would lie:
    ///
    /// - **off** — neutral chrome (Rule 3: no accent at rest).
    /// - **following** — cyan + glow. `playback` is the playhead's own colour and
    ///   following is an earned active state, so the glow is earned too.
    /// - **paused** — cyan outline, NO fill and NO glow: the user scrolled during
    ///   playback and follow stood down. A chip that kept glowing here would be
    ///   claiming to follow while the view sits still, which is the dishonest-
    ///   readout class this project keeps closing. A click resumes.
    private var followChip: some View {
        let following = model.isFollowingPlayhead
        let paused = model.isFollowSuspended
        let lit = following && !paused
        return Button {
            model.toggleFollowPlayhead()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: paused ? "location.slash" : "location.north.line.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("FOLLOW")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(following ? DAWTheme.playback : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(lit ? DAWTheme.playback.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(paused ? DAWTheme.playback.opacity(0.6) : Color.clear, lineWidth: 1)
            )
            .glow(DAWTheme.playback, radius: 5, intensity: lit ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .help(followHelp)
    }

    private var followHelp: String {
        if model.isFollowSuspended {
            return "Following paused — you scrolled. Click to resume, or press play again"
        }
        return model.isFollowingPlayhead
            ? "Following the playhead — the view keeps it in frame while you play"
            : "Keep the playhead in frame while you play"
    }

    /// HISTORY chip: opens the Undo-history panel. Shown in BOTH densities — undo
    /// history is a universal beginner action (everyone reaches for Cmd-Z), not a
    /// Pro-only power tool. Standard editing chrome, so NEUTRAL, never violet
    /// (docs/DESIGN-LANGUAGE.md Rule 3); lit cyan only as the earned active state
    /// while the panel is open.
    private var historyToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) {
                if model.showUndoHistory { model.closeUndoHistory() } else { model.openUndoHistory() }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9, weight: .bold))
                Text("HISTORY")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(model.showUndoHistory ? DAWTheme.playback : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.showUndoHistory ? DAWTheme.playback.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Show the list of edits you can step back to or redo")
    }

    /// The arrange workspace's live density — drives the Pro-only snap picker.
    private var arrangeIsPro: Bool {
        model.panelDensity.density(forPanel: TimelineLanesView.panelID) == .pro
    }

    /// Mix-header strip: label + the console's SIMPLE/PRO density chip, placed
    /// top-right in the exact slot the Arrange snap picker occupies — the whole
    /// console is ONE panel (`MixerView.panelID`), so the shared `SimpleProToggle`
    /// gates every strip's inserts/sends/routing at once (docs/DESIGN-LANGUAGE.md).
    private var mixToolbar: some View {
        HStack(spacing: 8) {
            Text("MIX")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            SimpleProToggle(
                store: model.panelDensity,
                panelID: MixerView.panelID,
                help: "Simple: level, pan, mute/solo. Pro: inserts, sends, routing."
            )
            .explainable(.panelDensity)   // shared density id (ex-b)
        }
        .padding(.horizontal, 4)
    }

    /// Violet FIX WITH AI affordance: appears when an audio clip is selected and
    /// opens the clip vocal-fix panel seeded from that clip's span. Violet because
    /// everything behind it is AI-generated (docs/DESIGN-LANGUAGE.md); lit +
    /// glowing while the panel is open.
    private var clipFixToggle: some View {
        Button {
            withAnimation(.easeOut(duration: 0.18)) { model.showClipFix = true }
            syncClipFixTarget()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 9, weight: .bold))
                Text("FIX WITH AI")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(model.showClipFix ? DAWTheme.ai : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.showClipFix ? DAWTheme.ai.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(model.showClipFix ? DAWTheme.ai.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
            )
            .glow(model.showClipFix ? DAWTheme.ai : .clear, radius: 5, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .help("Fix a region of this audio clip with AI — lands as a violet take lane")
    }

    /// Arrange zoom cluster (m17-b): a −/readout/+ chip for the horizontal
    /// pixels-per-beat scale plus an S/M/L chip for the stepped track-row height.
    /// Neutral chrome (zoom is navigation, not an active state — Rule 3): SF Mono
    /// for the percent readout, cyan ONLY on the earned active row step (the
    /// SimpleProToggle active-half idiom). Every action routes through the SAME
    /// AppModel zoom entry points the ⌘ menu and `debug.arrangeZoom` use, so the
    /// playhead-anchored no-jump rule applies from every driver.
    private var zoomCluster: some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                // m23-al: pressing the ARRANGE's own zoom button is an arrange
                // gesture, so it claims the surface for the ⌘ keys too. Engaged
                // HERE at the BUTTON, never inside `setArrangeZoom` — that is a
                // router target, and a zoom entry point that engaged the surface
                // it routed to would be self-confirming and would latch forever
                // (pinned by `EditorSurfaceOwnershipSiteTests`).
                zoomStepButton("minus.magnifyingglass", help: "Zoom out (⌘−)") {
                    model.editorEngagement.engage(.arrange)
                    model.zoomArrangeOut()
                }
                Text(ArrangeZoom.percentLabel(pixelsPerBeat: model.panelLayout.arrangePPB))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 40)
                    .help("Timeline zoom — ⌘0 resets to 100%")
                zoomStepButton("plus.magnifyingglass", help: "Zoom in (⌘+)") {
                    model.editorEngagement.engage(.arrange)
                    model.zoomArrangeIn()
                }
            }
            .padding(.vertical, 3)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(DAWTheme.hairline, lineWidth: 1)
            )

            HStack(spacing: 1) {
                ForEach(ArrangeZoom.RowStep.allCases, id: \.self) { step in
                    rowStepButton(step)
                }
            }
            .padding(2)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(DAWTheme.hairline, lineWidth: 1)
            )
            .help("Track height — small, medium, or large rows")
        }
    }

    private func zoomStepButton(_ systemImage: String, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func rowStepButton(_ step: ArrangeZoom.RowStep) -> some View {
        let active = model.arrangeRowStep == step
        return Button {
            model.setArrangeRowStep(step)
        } label: {
            Text(step.label)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(active ? DAWTheme.playback : DAWTheme.textDim)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(active ? DAWTheme.playback.opacity(0.18) : .clear)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Themed grid-snap menu: Off / Bar / Beat / 1/2 / 1/4 / 1/8 / 1/16 (beat
    /// fractions). Bar follows the meter.
    private var snapPicker: some View {
        Menu {
            ForEach(ClipSnap.allCases, id: \.self) { resolution in
                Button {
                    model.clipSnap = resolution
                } label: {
                    if model.clipSnap == resolution {
                        Label(resolution.label, systemImage: "checkmark")
                    } else {
                        Text(resolution.label)
                    }
                }
            }
        } label: {
            Text("SNAP: \(model.clipSnap.label)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1)
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Grid snap for clip move, trim, and split")
    }

    /// The open clip resolved against the live store, or nil when it's gone or
    /// isn't MIDI (which auto-closes the panel). Lives on the AppModel (m23-e)
    /// so the `debug.arrangePointer` echo reports the SAME resolution the editor
    /// branch gates on — an echo that could disagree with the screen would be
    /// worse than no echo.
    private var selectedMIDIClip: Clip? { model.openEditorClip }

    /// The id of the track owning `clipID` (m23-d) — the `selectedMIDIClip`
    /// iteration, returning the OWNER rather than the clip.
    private func trackID(ofClip clipID: UUID) -> UUID? {
        store.tracks.first { $0.clips.contains { $0.id == clipID } }?.id
    }

    /// The selected clip when it's a plain AUDIO clip, paired with its track id —
    /// the fixable target for FIX WITH AI (MIDI clips open the piano roll instead).
    private var selectedAudioClip: (trackID: UUID, clip: Clip)? {
        guard let id = selectedClipID else { return nil }
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == id }), !clip.isMIDI {
                return (track.id, clip)
            }
        }
        return nil
    }

    /// A key that changes exactly when the selected audio clip's identity or span
    /// changes — drives the fix-panel composer re-seed.
    private var selectedAudioClipKey: String {
        guard let sel = selectedAudioClip else { return "" }
        return "\(sel.clip.id.uuidString):\(sel.clip.startBeat):\(sel.clip.lengthBeats)"
    }

    /// Points the fix panel's composer at the live audio selection (a no-op when
    /// the panel is closed or nothing fixable is selected — the last target is
    /// kept, so deselecting doesn't wipe an in-progress region edit).
    private func syncClipFixTarget() {
        guard model.showClipFix, let sel = selectedAudioClip else { return }
        model.clipFix.prepare(trackID: sel.trackID, clipID: sel.clip.id, name: sel.clip.name,
                              startBeat: sel.clip.startBeat,
                              endBeat: sel.clip.startBeat + sel.clip.lengthBeats)
    }

    /// First MIDI clip in track/clip order, for the debug auto-open.
    private var firstMIDIClipID: UUID? {
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.isMIDI }) { return clip.id }
        }
        return nil
    }

    private func maybeAutoOpen() {
        guard Self.debugOpenPianoRoll, selectedClipID == nil, let id = firstMIDIClipID else { return }
        selectedClipID = id
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("DAW PRO")
                .font(.system(size: 13, weight: .heavy))
                .tracking(3)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(store.projectName)
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textDim)

            Spacer()

            WorkspaceToggle(mode: model.workspaceMode) { model.workspaceMode = $0 }

            Spacer()

            explainChip
            copilotToggle
                .explainable(.aiCopilot)
            sketchpadToggle
                .explainable(.aiSketchpad)
            voiceToggle
                .explainable(.voicePanel)
            inputDevicePicker
            settingsToggle
                .explainable(.settingsGear)

            HStack(spacing: 5) {
                Circle()
                    .fill(DAWTheme.ai)
                    .frame(width: 6, height: 6)
                    .glow(DAWTheme.ai, radius: 4, intensity: 0.8)
                Text("MCP \(String(controlPort))")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .help("AI control surface listening on ws://127.0.0.1:\(String(controlPort))")
        }
        .padding(.horizontal, 4)
    }

    /// Violet EXPLAIN chip: toggles the "Explain this" overlay (M8 ex-a). Violet
    /// because it's an AI-identified affordance (docs/DESIGN-LANGUAGE.md Rule 3 —
    /// violet = AI only); the shared `ExplainChip` lights + glows while explain mode
    /// is active. Esc also exits (see `explainEscHandler`).
    private var explainChip: some View {
        ExplainChip(isActive: model.explain.isActive) {
            withAnimation(.easeOut(duration: 0.18)) { model.explain.toggle() }
        }
    }

    /// Esc exits explain mode (sticky-until-toggled, per the settled interaction
    /// model). Present ONLY while explain mode is on, so Esc keeps its normal meaning
    /// everywhere else — a hidden zero-size button carrying the cancel shortcut.
    @ViewBuilder
    private var explainEscHandler: some View {
        if model.explain.isActive {
            Button("") { withAnimation(.easeOut(duration: 0.18)) { model.explain.setActive(false) } }
                .keyboardShortcut(.cancelAction)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// The explain card's "Ask the Copilot" hand-off (M8 ex-a): close explain mode,
    /// prefill a plain-language question about this control, and open the copilot
    /// rail — which loads the draft but NEVER auto-sends (so it works with or without
    /// an API key). Routes through the rail's existing draft path (no engine change).
    private func askCopilotAboutControl(_ id: ExplainID, _ entry: ExplainEntry) {
        model.explain.setActive(false)
        model.copilotDraft = "Explain \(entry.title) — what should I do with it here?"
        withAnimation(.easeOut(duration: 0.18)) { model.showCopilot = true }
    }

    /// The tour card's primary CTA per step (M8 ob-b). Welcome/done advance the
    /// model directly (no signal); each task step performs its NATURAL helpful action
    /// — the real operation then fires the completion signal (via the observing
    /// adapter) that advances the step. A step the user reaches another way (pressing
    /// the real Play button, dragging a fader) advances just the same.
    private func performTourPrimary(_ step: OnboardingStep) {
        switch step {
        case .welcome, .done:
            withAnimation(.easeOut(duration: 0.18)) { model.onboarding.advance() }
        case .generate:
            withAnimation(.easeOut(duration: 0.18)) { model.workspaceMode = .arrange }
            if !model.showSketchpad { model.toggleSketchpad() }
        case .listen:
            if !store.transport.isPlaying { store.play() }
        case .shape:
            withAnimation(.easeOut(duration: 0.18)) { model.workspaceMode = .arrange }
        case .mix:
            withAnimation(.easeOut(duration: 0.18)) { model.workspaceMode = .mix }
        case .export:
            model.exportSong()
        }
    }

    /// Violet COPILOT toggle chip: opens the AI chat rail. Always visible — the
    /// copilot is app-level, not gated on a selection (unlike FIX WITH AI). Violet
    /// because the copilot IS the AI (docs/DESIGN-LANGUAGE.md); lit + glowing when
    /// the rail is open.
    private var copilotToggle: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { model.toggleCopilot() } } label: {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("COPILOT")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(model.showCopilot ? DAWTheme.ai : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.showCopilot ? DAWTheme.ai.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(model.showCopilot ? DAWTheme.ai.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
            )
            .glow(model.showCopilot ? DAWTheme.ai : .clear, radius: 5, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .help("Open the AI Copilot — ask it to work the project for you")
    }

    /// Violet AI-Sketchpad toggle chip: opens the generation panel. Violet
    /// because everything behind it is AI-generated (docs/DESIGN-LANGUAGE.md).
    /// Lit + glowing when the panel is open.
    private var sketchpadToggle: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { model.toggleSketchpad() } } label: {
            HStack(spacing: 4) {
                Image(systemName: "sparkles")
                    .font(.system(size: 9, weight: .bold))
                Text("SKETCHPAD")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(model.showSketchpad ? DAWTheme.ai : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.showSketchpad ? DAWTheme.ai.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(model.showSketchpad ? DAWTheme.ai.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
            )
            .glow(model.showSketchpad ? DAWTheme.ai : .clear, radius: 5, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .help("Open the AI Sketchpad — generate a song from a prompt")
    }

    /// Violet VOICE toggle chip (m10-p-5): opens the Voice panel — your own
    /// trained voices + their training recordings. Violet because a voice model
    /// is AI identity and conversion output is AI-generated audio
    /// (docs/DESIGN-LANGUAGE.md Rule 3). Lit + glowing when the panel is open.
    private var voiceToggle: some View {
        Button { withAnimation(.easeOut(duration: 0.18)) { model.toggleVoicePanel() } } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.wave.2.fill")
                    .font(.system(size: 9, weight: .bold))
                Text("VOICE")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(model.showVoicePanel ? DAWTheme.ai : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(model.showVoicePanel ? DAWTheme.ai.opacity(0.14) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(model.showVoicePanel ? DAWTheme.ai.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
            )
            .glow(model.showVoicePanel ? DAWTheme.ai : .clear, radius: 5, intensity: 0.6)
        }
        .buttonStyle(.plain)
        .help("Open the Voice panel — build a voice of your own and convert vocals to it")
    }

    /// The convert sheet's header clip name, resolved against the live store
    /// (falls back to the track name for an unnamed clip).
    private func voiceConvertClipName(_ id: UUID) -> String {
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == id }) {
                return clip.name.isEmpty ? track.name : clip.name
            }
        }
        return "Audio Clip"
    }

    /// Settings gear chip: opens the glass Settings overlay (API keys). Neutral
    /// chrome (not violet — this isn't AI content); lit when the panel is open.
    private var settingsToggle: some View {
        Button { withAnimation(.easeOut(duration: 0.15)) { model.toggleSettings() } } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(model.showSettings ? DAWTheme.textPrimary : DAWTheme.textDim)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(model.showSettings ? DAWTheme.panelRaised : DAWTheme.panelRaised.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(model.showSettings ? DAWTheme.textDim.opacity(0.4) : DAWTheme.hairline, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .help("Settings — API keys")
    }

    /// Compact recording-input selector chip: shows the pinned device (or
    /// "Default" when following the system default) and opens the live device
    /// list. Selection applies to the NEXT take — switching mid-take is
    /// refused by the store, hence the quiet try?.
    private var inputDevicePicker: some View {
        Menu {
            Button {
                try? store.selectInputDevice(uid: nil)
            } label: {
                if store.selectedInputDeviceUID == nil {
                    Label("System Default", systemImage: "checkmark")
                } else {
                    Text("System Default")
                }
            }
            Divider()
            ForEach(store.listInputDevices()) { device in
                Button {
                    try? store.selectInputDevice(uid: device.uid)
                } label: {
                    if store.selectedInputDeviceUID == device.uid {
                        Label(device.name, systemImage: "checkmark")
                    } else {
                        Text(device.name)
                    }
                }
            }
        } label: {
            Text("IN: \(selectedInputDeviceName)")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1)
                )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Recording input device — takes effect on the next take")
    }

    /// Chip label: the pinned device's current name, or "Default" when
    /// following the system default (or the pinned device vanished).
    private var selectedInputDeviceName: String {
        guard let uid = store.selectedInputDeviceUID else { return "Default" }
        return store.listInputDevices().first { $0.uid == uid }?.name ?? "Default"
    }
}

/// DELETE removes the arrange selection (m23-g1). A `ViewModifier` rather than
/// five modifiers inline on ContentView's body — that body is already at the
/// type-checker's limit, and a 1-line call site keeps it there.
///
/// SUPERSEDED IN PLACE AT m23-x, name kept deliberately: this modifier now hosts
/// TWO arrange keys — DELETE and the ←/→ clip nudge. It was NOT renamed to
/// something like `ArrangeKeyCommands` because `ArrangeDeleteKey` is the name
/// the m23-g1 and m23-g2 roadmap records, this file's `arrangeDeleteKeyScope`,
/// and `AppModel.handleArrangeDeleteKey`'s own comments all cite; renaming would
/// have made five accurate references stale to gain a word. WHY THE ARROWS LIVE
/// HERE AND NOT IN A SECOND MODIFIER: this one owns the workspace's `@FocusState`
/// and its single `.focusable()`. A second modifier would bring a second
/// `@FocusState` asserting focus on the same scope — precisely the focus fight
/// `arrangeDeleteKeyScope`'s `VStack` note exists to prevent — and the arrows
/// need exactly the focus DELETE already has.
///
/// PLACEMENT IS THE WHOLE SAFETY ARGUMENT. This is applied to the ARRANGE
/// WORKSPACE (via `ContentView.arrangeDeleteKeyScope`) — not to the lanes, and
/// deliberately NOT to the window root:
///
///   • NOT THE WINDOW ROOT. Every modal in this app (instrument picker, quantize
///     panel, Settings, undo history, voice-convert sheet, engine notices) is
///     rendered as an `.overlay` on ContentView's root, i.e. INSIDE that root's
///     subtree. Mounted there, this modifier would be an ancestor of all of them:
///     with three clips selected, focusing any non-text control in a modal and
///     pressing DELETE would silently destroy the clips behind it as one
///     journaled edit. The Mix console would have been live for the same key.
///     Scoping to the arrange workspace closes the PROPAGATION path: this is no
///     longer an ancestor of the overlays, so a key ignored inside a modal can no
///     longer bubble here. It does NOT by itself close the RETAINED-FOCUS path —
///     the workspace can still hold focus from an earlier clip click while a modal
///     is open, and then the key arrives here directly. `handleArrangeDeleteKey`
///     guards that case explicitly (`isModalPresented`), and the Mix case twice
///     over (`workspaceMode`), because those are the halves a gate can OBSERVE;
///     the scoping is what makes them defence in depth rather than the only line.
///   • Scoping also contains `.focusEffectDisabled()`, which propagates down the
///     environment: at the window root it suppressed focus rings for every rename
///     field, Copilot input and Settings control in the app.
///
///   • The piano roll (`PianoRollView.onKeyPress(.delete)`) and the automation
///     lane editor own the key on their OWN surfaces and are DESCENDANTS of the
///     view this wraps. SwiftUI offers a key press to the focused descendant
///     first, so a focused roll with notes selected consumes it and this never
///     runs — the m23-e/m23-d note path cannot regress through here
///     STRUCTURALLY, not by a guard someone has to remember to maintain. A roll
///     with NO notes selected returns `.ignored`, and the key then falls through
///     to the clips, which is what a user pressing DELETE with clips selected
///     means.
///   • It is NOT a menu key equivalent, on purpose: those are checked BEFORE
///     text insertion, so an Edit-menu item with `.keyboardShortcut(.delete)`
///     would steal Backspace from every rename field in the app — the exact trap
///     m17-d documented for the space bar.
///   • `AppModel.handleArrangeDeleteKey` re-checks the field-editor case with
///     the m17-d responder classifier ANYWAY, so a Backspace that somehow
///     reached here while the user is typing still cannot delete their clips.
///     Delivery order is SwiftUI's business; that guard does not depend on it.
private struct ArrangeDeleteKey: ViewModifier {
    var model: AppModel
    /// Keyboard focus on the workspace root — what makes the key press eligible
    /// at all. Asserted on every arrange clip click (via
    /// `AppModel.arrangeKeyFocusNonce`) so DELETE works immediately after
    /// selecting clips, with no separate "click the background first" step.
    @FocusState private var focused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            // No focus ring on the workspace root — the selected clips ARE the
            // cue (docs/DESIGN-LANGUAGE.md: one accent per meaning).
            .focusEffectDisabled()
            .onKeyPress(.delete) { model.handleArrangeDeleteKey() ? .handled : .ignored }
            // ←/→ NUDGE the arrange selection (m23-x). Three things here are
            // decisions, not defaults:
            //
            //   • `phases: [.down, .repeat]` — key REPEAT is load-bearing, and
            //     this is the OPPOSITE of the space bar, whose predicate has
            //     `guard !isRepeat` so a held space cannot machine-gun the
            //     transport. Walking a clip into place by holding an arrow is
            //     the whole gesture; the undo cost is paid by
            //     `ProjectStore.moveClipsKey`'s selection-stable coalescing key.
            //   • ↑/↓ are a SEPARATE mount below, not two more keys in this
            //     list. They resolve to a different direction enum on a
            //     different axis (see the banner atop `ArrangeNudge`), so
            //     folding them in here would need a character switch that
            //     returns two unrelated types.
            //   • The whole modifier POLICY lives in `ArrangeNudge.step`, not
            //     here: ⌥ fine, ⇧ bar, ⌘/⌃ pass through. This closure only
            //     translates SwiftUI's vocabulary into the headless one, so the
            //     policy stays unit-testable (`DAWApp` has no test target) and
            //     the `debug.arrangeSelection {act:"nudge"}` seam — which passes
            //     the chord EXPLICITLY, because a synthesized press carries none
            //     — exercises the SAME rule the real key does.
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat]) { press in
                let character = press.key.character
                let direction: ArrangeNudgeDirection
                if character == KeyEquivalent.leftArrow.character {
                    direction = .left
                } else if character == KeyEquivalent.rightArrow.character {
                    direction = .right
                } else {
                    return .ignored
                }
                let outcome = model.handleArrangeNudgeKey(
                    .horizontal(direction),
                    modifiers: AppModel.keyPressModifiers(press.modifiers))
                return outcome.handled ? .handled : .ignored
            }
            // ↑/↓ move the arrange selection ACROSS TRACKS (m23-aj-3), through
            // the SAME `handleArrangeNudgeKey` and therefore the same six guards.
            //
            //   • `phases: [.down, .repeat]`, identically to ←/→ — walking a clip
            //     down four lanes by holding ↓ is the gesture, and the undo cost
            //     is paid by the same selection-stable coalescing key.
            //   • The modifier policy is `ArrangeNudge.verticalStep`'s and is
            //     STRICTER than the horizontal one: BARE PRESS ONLY. ⇧ and ⌥ are
            //     reserved (extend-selection / duplicate-down) and pass through
            //     to the lanes' vertical `ScrollView`, which is a descendant of
            //     this mount.
            //   • A REFUSED vertical nudge is still CONSUMED when it got past the
            //     guards — see `AppModel.ArrangeNudgeOutcome`. That is the one
            //     place the two axes deliberately differ.
            .onKeyPress(keys: [.upArrow, .downArrow], phases: [.down, .repeat]) { press in
                let character = press.key.character
                let direction: ArrangeVerticalNudgeDirection
                if character == KeyEquivalent.upArrow.character {
                    direction = .up
                } else if character == KeyEquivalent.downArrow.character {
                    direction = .down
                } else {
                    return .ignored
                }
                let outcome = model.handleArrangeNudgeKey(
                    .vertical(direction),
                    modifiers: AppModel.keyPressModifiers(press.modifiers))
                return outcome.handled ? .handled : .ignored
            }
            .onChange(of: model.arrangeKeyFocusNonce) { _, _ in focused = true }
    }
}
