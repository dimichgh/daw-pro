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
    /// control frames + hover timing. View-local (`@State`) — it's pure view geometry;
    /// the mode on/off flag lives on `AppModel.explain` so `debug.explainMode` can
    /// drive it (and `debug.captureUI` renders the same state).
    @State private var explainCoordinator = ExplainCoordinator()

    /// Drag origins for the adjustable-layout splitters (beta m10-d): each is
    /// captured on the drag's first tick (the gesture reports translation from the
    /// start, so the origin + delta reconstructs the target value), and cleared on
    /// end. nil = no drag in flight. Kept view-local — pure gesture bookkeeping; the
    /// clamped values themselves live on `model.panelLayout`.
    @State private var sidebarDragOrigin: CGFloat?
    @State private var editorDragOrigin: CGFloat?

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
                            arrangeWorkspace(geo)
                        case .mix:
                            mixToolbar
                            MixerView(densityStore: model.panelDensity)
                                .frame(maxHeight: .infinity)
                        }
                    }
                    if model.showCopilot {
                        CopilotRailView(
                            engine: model.copilotEngine,
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
        .overlay {
            if model.instrumentPickerTrackID != nil {
                InstrumentPickerOverlay(
                    model: model.instrumentPicker,
                    densityStore: model.panelDensity,
                    onChoose: { model.applyInstrumentChoice($0) },
                    onImport: { model.importSoundBankViaPanel() },
                    onClose: { withAnimation(.easeOut(duration: 0.15)) { model.closeInstrumentPicker() } }
                )
            }
        }
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
        .coordinateSpace(.named(ExplainCoordinateSpace.name))
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

    /// The Arrange surface: track list + timeline, with the piano roll docked
    /// below when a MIDI clip is open. Extracted so `body` can switch it against
    /// the Mix console without duplicating the header/transport chrome.
    @ViewBuilder
    private func arrangeWorkspace(_ geo: GeometryProxy) -> some View {
        arrangeToolbar
        HStack(spacing: 10) {
            // Shared-scroll arrange (m10-j): ONE vertical ScrollView owns BOTH
            // columns (the sidebar track rows + the timeline lanes) as a single
            // HStack, so there is exactly one scroll position and the two columns can
            // never desync — the structurally safer choice over synchronizing two
            // offsets. When the content is taller than the viewport the whole track
            // area scrolls together (rows stay pixel-locked to lanes); when it's
            // shorter, `minHeight` fills the viewport so the glass panels don't shrink
            // to their content. The Sketchpad/ClipFix side panels stay OUTSIDE this
            // scroll at full height. On macOS, wheel-driven scrolling doesn't conflict
            // with the click-drag splitters inside (the existing row-height grabber
            // already lives inside a scroll). The ruler + TRACKS header sit at the top
            // of the shared content — their HORIZONTAL behavior is unchanged (the
            // ruler still h-scrolls with the lanes); vertically they ride the scroll.
            GeometryReader { trackGeo in
                ScrollView(.vertical) {
                    HStack(spacing: 10) {
                        TrackListView()
                            .frame(width: model.panelLayout.sidebarWidth)
                        // Draggable sidebar↔timeline splitter (beta m10-d). Drag right
                        // widens the track list; the store clamps to 250–420 pt.
                        sidebarSplitter
                        TimelineLanesView(
                            tracks: store.tracks,
                            positionBeats: store.transport.positionBeats,
                            beatsPerBar: store.transport.timeSignature.beatsPerBar,
                            selectedClipID: selectedClipID,
                            onSelectClip: selectClip,
                            expandedTrackIDs: model.expandedAutomationTrackIDs,
                            selectedLaneByTrack: model.automationLaneSelection,
                            onCommitPoints: { trackID, laneID, points in
                                _ = try? store.setAutomationPoints(trackID: trackID, laneID: laneID, points: points)
                            },
                            snap: model.clipSnap,
                            secondsPerBeat: 60.0 / store.transport.tempoBPM,
                            waveformStore: model.waveformStore,
                            densityStore: model.panelDensity,
                            // Global track-row height (beta m10-d) — the SAME store value
                            // the sidebar rows use, so lanes and headers stay pixel-aligned.
                            rowHeight: model.panelLayout.rowHeight,
                            // The shared-scroll viewport height (m10-j): the timeline fills
                            // it when content is short and reports its natural (content)
                            // height when tall, so the outer scroll drives the overflow.
                            availableHeight: trackGeo.size.height,
                            onMoveClip: { trackID, clip, toStart in
                                _ = try? store.moveClip(trackId: trackID, clipId: clip.id, toStartBeat: toStart)
                            },
                            onTrimClip: { trackID, clip, newStart, newLength in
                                _ = try? store.trimClip(trackId: trackID, clipId: clip.id,
                                                        newStartBeat: newStart, newLengthBeats: newLength)
                            },
                            onSplitClip: { trackID, clip, atBeat in
                                _ = try? store.splitClip(trackId: trackID, clipId: clip.id, atBeat: atBeat)
                            },
                            onSetClipFades: { trackID, clip, fadeIn, fadeOut, inCurve, outCurve in
                                _ = try? store.setClipFades(trackId: trackID, clipId: clip.id,
                                                            fadeInBeats: fadeIn, fadeOutBeats: fadeOut,
                                                            fadeInCurve: inCurve, fadeOutCurve: outCurve)
                            },
                            onSetClipGain: { trackID, clip, gainDb in
                                _ = try? store.setClipGain(trackId: trackID, clipId: clip.id, gainDb: gainDb)
                            },
                            onStretchClip: { trackID, clip, toLength in
                                _ = try? store.stretchClip(trackId: trackID, clipId: clip.id, toLengthBeats: toLength)
                            },
                            // Quantize & groove (m11-a): the arrange clip context menu
                            // (Pro, sp-c) opens the SAME panel the piano roll does.
                            // "Extract Groove…" jumps straight to the extract field.
                            onOpenQuantize: { clip in model.openQuantizePanel(clipID: clip.id) },
                            onExtractGroove: { clip in
                                model.openQuantizePanel(clipID: clip.id, startExtract: true)
                            },
                            // Crossfade two adjacent/overlapping audio clips (m11-d,
                            // Pro clip menu) — routes through the store's crossfade
                            // method (one undo step; the sanctioned-overlap tool).
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
                            // Loop region ruler (beta m10-g): loop state flows in by value
                            // so an agent's `transport.setLoop` over the wire updates the
                            // band live; the callbacks route through the pre-existing store
                            // methods (no new wire command — the m10-c/e pure-view precedent).
                            isLoopEnabled: store.transport.isLoopEnabled,
                            loopStartBeat: store.transport.loopStartBeat,
                            loopEndBeat: store.transport.loopEndBeat,
                            onSetLoop: { enabled, start, end in
                                _ = try? store.setLoop(enabled: enabled, startBeat: start, endBeat: end)
                            },
                            onSeek: { beat in _ = try? store.seek(toBeats: beat) },
                            // Session markers (m11-c): markers flow in by value from the
                            // store (already beat-sorted) so an agent's marker.* over the
                            // wire updates the lane live; callbacks route through the store
                            // marker methods (undo/coalescing free).
                            markers: store.markers,
                            onAddMarker: { beat in _ = store.addMarker(beat: beat) },
                            onMoveMarker: { markerID, beat in _ = try? store.moveMarker(id: markerID, beat: beat) },
                            onRenameMarker: { markerID, name in _ = try? store.renameMarker(id: markerID, name: name) },
                            onRemoveMarker: { markerID in try? store.removeMarker(id: markerID) },
                            stageRenameMarkerID: model.stagedMarkerRenameID,
                            // Audio import via drag-drop (beta m10-k): dropped file URLs
                            // run through the SAME shared plan pipeline the File→Import
                            // menu uses; the target lane + drop beat come from the drop
                            // location, routing/fan-out/naming decided by AudioImportPlan.
                            onImportAudio: { urls, targetTrackID, atBeatRaw in
                                model.importAudioFiles(urls: urls, targetTrackID: targetTrackID,
                                                       atBeatRaw: atBeatRaw)
                            }
                        )
                    }
                    // Fill the viewport when content is short (glass panels stay full
                    // height); grow past it when tall (the shared scroll takes over).
                    .frame(minHeight: trackGeo.size.height, alignment: .top)
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
                beatsPerBar: store.transport.timeSignature.beatsPerBar,
                // The SAME transport source the arrange timeline consumes (no second
                // ticker) — the piano roll playhead is a rendering of this state.
                positionBeats: store.transport.positionBeats,
                densityStore: model.panelDensity,
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
                onClose: { selectedClipID = nil }
            )
            .id(clip.id)
            .frame(height: geo.size.height * model.panelLayout.editorFraction)
        }
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
    private func selectClip(_ clip: Clip) {
        selectedClipID = clip.id
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

    /// Themed grid-snap menu: Off / Bar / Beat / 1/2 / 1/4. Bar follows the meter.
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
    /// isn't MIDI (which auto-closes the panel).
    private var selectedMIDIClip: Clip? {
        guard let id = selectedClipID else { return nil }
        for track in store.tracks {
            if let clip = track.clips.first(where: { $0.id == id }), clip.isMIDI {
                return clip
            }
        }
        return nil
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
