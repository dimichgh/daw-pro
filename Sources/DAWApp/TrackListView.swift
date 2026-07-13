import SwiftUI
import DAWCore
import DAWAppKit

/// The discoverable add-track control (beta m10-i): a themed chip menu (the
/// piano-roll snap-picker idiom, never a stock gray control — Rule 2) offering
/// the three track kinds a human can create. Each routes to `store.addTrack`,
/// which supplies a sensible default name ("Inst 3", "Audio 2", "Bus 1"). One
/// component backs both the header chip and the empty-state button so they stay
/// in sync. Carries the shared `.arrangeAddTrack` Explain entry.
struct AddTrackMenu<ChipLabel: View>: View {
    @Environment(ProjectStore.self) private var store
    @ViewBuilder var label: () -> ChipLabel

    var body: some View {
        Menu {
            Button {
                store.addTrack(kind: .instrument)
            } label: { Label("Instrument Track", systemImage: "pianokeys") }
            Button {
                store.addTrack(kind: .audio)
            } label: { Label("Audio Track", systemImage: "waveform") }
            Button {
                store.addTrack(kind: .bus)
            } label: { Label("Bus Track", systemImage: "arrow.triangle.merge") }
        } label: {
            label()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a track — instrument, audio, or bus")
        .explainable(.arrangeAddTrack)
    }
}

/// The pinned TRACKS header bar (m13-g, ruler-block pinning): the "TRACKS" label +
/// the add-track chip. Extracted from the old `TrackListView` so it can ride the
/// pinned ruler block ABOVE the shared vertical scroll (staying visible however
/// deep you scroll) while `TrackRowsList` scrolls below it. Its content sits at the
/// TOP of the block (`rulerHeight` tall) so it aligns with the ruler beside it.
struct TracksHeaderBar: View {
    var body: some View {
        HStack {
            Text("TRACKS")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            // A LABELED add-track affordance so a human never has to wonder whether
            // tracks are AI-only (beta m10-i): a compact "+ ADD" chip that drops a
            // kind menu. Neutral chrome — textPrimary on the raised chip, no accent
            // at rest (Rule 3: a create "+" earns no accent).
            AddTrackMenu {
                HStack(spacing: 3) {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                    Text("ADD")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.8)
                }
                .foregroundStyle(DAWTheme.textPrimary)
                .padding(.horizontal, 8)
                .frame(height: 22)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The scrolling track rows (m13-g) — the sidebar body BELOW the pinned
/// `TracksHeaderBar`. Rows anchor at the top of the shared vertical scroll (no top
/// padding), so row 0 lines up with lane 0 (which also starts at y = 0 now that the
/// ruler is pinned separately). A plain VStack: the shared outer vertical
/// ScrollView in ContentView scrolls these rows and the timeline lanes TOGETHER as
/// one unit (m10-j), so they stay pixel-locked.
struct TrackRowsList: View {
    @Environment(ProjectStore.self) private var store

    var body: some View {
        Group {
            if store.tracks.isEmpty {
                VStack(spacing: 10) {
                    VStack(spacing: 6) {
                        Text("No tracks yet")
                            .font(.system(size: 12))
                            .foregroundStyle(DAWTheme.textDim)
                        Text("Add one below, or let an agent do it over MCP")
                            .font(.system(size: 10))
                            .foregroundStyle(DAWTheme.textFaint)
                    }
                    // The empty state gets a REAL, obvious add button (not just the
                    // tucked-away header chip) so a first-time human has a clear
                    // starting move (beta m10-i).
                    AddTrackMenu {
                        HStack(spacing: 5) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .bold))
                            Text("ADD TRACK")
                                .font(.system(size: 10, weight: .bold, design: .monospaced))
                                .tracking(0.8)
                        }
                        .foregroundStyle(DAWTheme.textPrimary)
                        .padding(.horizontal, 12)
                        .frame(height: 28)
                        .background(DAWTheme.panelRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Row 0 anchors flush at the top of the scroll (no top padding), so
                // it lines up with lane 0 — which also starts at y = 0 now that the
                // ruler is pinned separately (m13-g). Both columns flush = aligned.
                VStack(spacing: 6) {
                    ForEach(store.tracks) { track in
                        TrackRow(track: track)
                            .id(track.id)   // scroll target (m13-g deep-scroll proof)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }
}

struct TrackRow: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    var track: Track

    /// The live sidebar width (beta m10-i round 2) — read from the SAME m10-d
    /// layout store the splitter drives, so the row's width-budget decisions
    /// (does the clip badge fold?) track the sidebar deterministically without a
    /// GeometryReader inside the ScrollView.
    private var sidebarWidth: CGFloat { model.panelLayout.sidebarWidth }

    /// Drag origin for the row-height grabber (beta m10-d), captured on the first
    /// tick and cleared on end — only one row is dragged at a time. Adjusts the
    /// GLOBAL `panelLayout.rowHeight`, not this track.
    @State private var rowDragOrigin: CGFloat?

    /// Inline rename state (beta m10-i): double-click the identity swaps the name
    /// Text for a TextField seeded here; Return / focus-loss commits, Escape
    /// cancels. `isEditingName` gates both the swap and the focus-loss commit so
    /// a Return or Escape that removes the field can't double-fire the commit.
    @State private var isEditingName = false
    @State private var nameDraft = ""
    @FocusState private var nameFieldFocused: Bool

    /// The live global row height — the SAME value the timeline lanes read, so the
    /// sidebar header and its lane stay pixel-aligned at every size (beta m10-d).
    private var rowHeight: CGFloat { model.panelLayout.rowHeight }

    private var kindIcon: String {
        switch track.kind {
        case .audio: "waveform"
        case .instrument: "pianokeys"
        case .bus: "arrow.triangle.merge"
        }
    }

    private var isExpanded: Bool { model.expandedAutomationTrackIDs.contains(track.id) }
    /// Takes section shows only when expanded AND the track has groups (mirrors
    /// the timeline's `isTakesExpanded`).
    private var isTakesExpanded: Bool {
        model.expandedTakeTrackIDs.contains(track.id) && !track.takeGroups.isEmpty
    }

    /// Whether the automation disclosure rides inline (m10-j). It folds into the
    /// context menu on a take-group row at a narrow sidebar so the soft name keeps
    /// its readable share — the pure rule lives in `TrackHeaderLayout`.
    private var showsInlineAutomation: Bool {
        TrackHeaderLayout.showsInlineAutomationDisclosure(
            sidebarWidth: sidebarWidth, hasTakeGroups: TakeLaneSelection.hasTakeGroups(track))
    }

    var body: some View {
        VStack(spacing: 0) {
            row
            if isTakesExpanded {
                TakeTrackControls(track: track)
            }
            if isExpanded {
                AutomationTrackControls(track: track)
            }
        }
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7).stroke(
                track.isAIGenerated ? DAWTheme.ai.opacity(0.35) : DAWTheme.hairline,
                lineWidth: 1
            )
        )
        .contextMenu {
            // Discoverability twin of the double-click rename (beta m10-i).
            Button("Rename Track") { beginEditing() }
            // When the inline automation disclosure has folded away (a take-group row
            // at a narrow sidebar, m10-j), it stays reachable here so automation is
            // never lost — just relocated.
            if !showsInlineAutomation {
                Button(isExpanded ? "Hide Automation" : "Show Automation") {
                    model.toggleAutomation(track.id)
                }
            }
            // Bounce in Place (m11-e): render this track and land it as a new
            // audio track + clip in one undo step. Offered only for master
            // inputs (a direct-to-master track or a bus) — the SAME eligibility
            // render.stems / bounceTrackInPlace enforce; a bus-routed source
            // has no stem of its own, so the item hides rather than fail. Both
            // densities (a plain action, no advanced-control split).
            if track.kind == .bus || track.outputBusID == nil {
                Button("Bounce in Place") {
                    Task { try? await store.bounceTrackInPlace(trackId: track.id) }
                }
            }
            Button("Remove Track", role: .destructive) {
                // m13-c: refused mid-recording (transportBusy) — safe no-op here.
                _ = try? store.removeTrack(id: track.id)
            }
        }
    }

    private var row: some View {
        // Tight top-level spacing (5 pt) so a fully-loaded row still fits inside
        // the sidebar's narrow end (250 pt) WITHOUT the name giving up its readable
        // share; the Spacer restores generous separation at wider widths.
        HStack(spacing: 5) {
            identityCluster

            // The instrument chip (m10-n-3): the current sound + the picker opener,
            // on instrument tracks only. COMPACT + SOFT (truncating, default layout
            // priority below the name's `.layoutPriority(1)` cluster) so it yields
            // the name its readable share and carries no hard minimum — it can never
            // inflate the sidebar past its 250 pt floor (the m10-i soft-label rule).
            // It folds toward a glyph at the narrow end.
            if track.kind == .instrument {
                InstrumentChip(
                    descriptor: track.instrument,
                    status: store.audioUnitStatus(forTrack: track.id),
                    compact: true,
                    onOpen: { model.openInstrumentPicker(trackID: track.id) }
                )
                .layoutPriority(0)
            }

            Spacer(minLength: 0)

            // The level bar yields FIRST when the header is crowded (beta m10-i):
            // it compresses from its ideal 44 pt down to a 22 pt floor (a slimmer
            // bar, never hidden) so the identity keeps its readable share.
            MiniLevelBar(meter: store.trackMeters[track.id] ?? .silence,
                         minWidth: 22, maxWidth: 44)

            // The clip-count badge is the LEAST load-bearing chip, so it folds into
            // the identity tooltip at the narrow end (beta m10-i round 2) rather
            // than steal the name's room. The decision is the pure, tested
            // `TrackHeaderLayout.showsClipBadge`.
            if TrackHeaderLayout.showsClipBadge(sidebarWidth: sidebarWidth,
                                                clipCount: track.clips.count) {
                Text("\(track.clips.count) ♪")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize()
            }

            takesDisclosure

            // The automation disclosure folds into the context menu on a HEAVY row
            // (one that also carries a take-group disclosure) at a narrow sidebar, so
            // the two disclosures don't squeeze the soft name below its readable floor
            // (m10-j — the deferred m10-i "~36 pt name at 250" edge). The pure rule is
            // `TrackHeaderLayout.showsInlineAutomationDisclosure`.
            if showsInlineAutomation {
                automationDisclosure
            }

            // M/S/A reuse the mixer strip's ExplainIDs — the copy reads
            // context-neutral, so one entry serves both surfaces (ex-b shared-id rule).
            ToggleChip(label: "M", isOn: track.isMuted, onColor: DAWTheme.clip) {
                store.setTrackMute(id: track.id, muted: !track.isMuted)
            }
            .explainable(.mixerMute)
            ToggleChip(label: "S", isOn: track.isSoloed, onColor: DAWTheme.playback) {
                store.setTrackSolo(id: track.id, soloed: !track.isSoloed)
            }
            .explainable(.mixerSolo)
            if track.kind == .audio || track.kind == .instrument {
                // Record arm (audio capture / MIDI capture + live thru) —
                // throws only for bus tracks, which never show the chip.
                ToggleChip(label: "R", isOn: track.isArmed, onColor: DAWTheme.record) {
                    _ = try? store.setTrackArm(id: track.id, armed: !track.isArmed)
                }
                .explainable(.mixerArm)
            }
        }
        .padding(.horizontal, 10)
        // The header IS the timeline lane's height (beta m10-d): a fixed frame on
        // the store value (not intrinsic padding) so it matches `rowHeight` exactly,
        // keeping the sidebar and timeline pixel-aligned. Content centers within it.
        .frame(height: rowHeight)
        // Drag the header's bottom edge to resize ALL rows (resizeUpDown, not grab —
        // the macOS glyph for a height adjustment; see DESIGN-LANGUAGE "Panel
        // splitters"). Idle-invisible so N rows don't grow N rest lines.
        .overlay(alignment: .bottom) { rowHeightHandle }
    }

    /// The kind icon + name = the track's identity (one shared "Track" card).
    /// The name wins the layout fight against the crowded right side (beta m10-i)
    /// via LAYOUT PRIORITY, NOT a hard minimum width — a bare truncating Text has
    /// a tiny intrinsic minimum (an ellipsis), so it never inflates the sidebar's
    /// (and thus the window's) minimum width (the round-2 clip bug), yet priority
    /// hands it the surplus so it stays readable (≳ 60 pt even at sidebar 250 once
    /// the clip badge folds away). A long name truncates at the TAIL (the app's
    /// `lineLimit(1)` convention); the full name + clip count live in the tooltip.
    /// Double-click swaps in the inline rename field.
    private var identityCluster: some View {
        HStack(spacing: 5) {
            Image(systemName: kindIcon)
                .font(.system(size: 11))
                .foregroundStyle(track.isAIGenerated ? DAWTheme.ai : DAWTheme.textDim)
                .frame(width: 16)

            if isEditingName {
                nameField
            } else {
                // A BARE truncating Text — finite ideal (the full string), tiny
                // minimum (an ellipsis). The cluster's `layoutPriority` below hands
                // it the surplus so it reads; its small minimum keeps the sidebar
                // from inflating. The Spacer (not this) soaks up wide-width slack,
                // so the level bar can still grow to its full 44 pt.
                Text(track.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .contentShape(Rectangle())
                    // Double-click the identity to rename (the discoverability twin
                    // is the "Rename Track" context-menu item).
                    .onTapGesture(count: 2) { beginEditing() }
                    // Full name + clip count on hover — a truncated title (and a
                    // folded-away clip badge) stay discoverable.
                    .help(TrackHeaderLayout.identityTooltip(name: track.name,
                                                            clipCount: track.clips.count))
            }
        }
        // Priority on the CLUSTER (one unit): it wins the top-level surplus over
        // the Spacer/level bar so the name stays readable, WITHOUT a hard minimum
        // width — so the row never inflates the sidebar past its 250 pt floor and
        // slides the whole panel off-screen (the m10-i round-2 clip bug).
        .layoutPriority(1)
        .explainable(.trackRowIdentity)
    }

    /// The inline rename TextField (beta m10-i): SF Pro to match the name Text it
    /// replaces (a track name is prose, not a numeric readout — so not SF Mono),
    /// styled to the dark-glass field idiom (the Copilot input / ClipFix beat
    /// field). Like the display name it is soft (priority-won, no hard minimum) so
    /// entering edit mode never inflates the sidebar. Commit on Return (`onSubmit`)
    /// and on focus loss; Escape cancels.
    private var nameField: some View {
        TextField("", text: $nameDraft)
            .textFieldStyle(.plain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(DAWTheme.textPrimary)
            .focused($nameFieldFocused)
            // Fill the cluster while editing (its priority is on the cluster); the
            // field's own minimum stays small, so edit mode never inflates the row.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .background(DAWTheme.background)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.playback.opacity(0.5), lineWidth: 1))
            // Focus the field the moment it enters the tree (belt-and-suspenders
            // with the set in `beginEditing`) so the caret lands without a click.
            .onAppear { nameFieldFocused = true }
            .onSubmit { commitRename() }
            // Escape cancels (drops the draft) BEFORE the focus-loss commit runs —
            // `isEditingName` is cleared first, so the onChange below no-ops.
            .onKeyPress(.escape) { cancelRename(); return .handled }
            // Focus loss (click elsewhere) commits; guarded so a Return/Escape that
            // already tore down the field can't commit a second time.
            .onChange(of: nameFieldFocused) { _, focused in
                if !focused && isEditingName { commitRename() }
            }
    }

    /// Enter rename mode: seed the draft from the live name and focus the field.
    private func beginEditing() {
        nameDraft = track.name
        isEditingName = true
        nameFieldFocused = true
    }

    /// Commit the draft through the store's rename (which journals one undo step),
    /// but only when the pure resolver says it's a real change — empty input and an
    /// unchanged re-type both drop back to the plain name with no edit.
    private func commitRename() {
        guard isEditingName else { return }
        isEditingName = false
        if let name = TrackRename.committedName(draft: nameDraft, current: track.name) {
            store.renameTrack(id: track.id, name: name)
        }
    }

    /// Cancel: discard the draft, restore the plain name, and disarm the focus-loss
    /// commit (so tearing down the field doesn't re-commit).
    private func cancelRename() {
        isEditingName = false
        nameFieldFocused = false
    }

    /// The bottom-edge grabber that adjusts the global track-row height (beta m10-d).
    /// Drag DOWN grows every row; the store clamps to 24–64 pt.
    private var rowHeightHandle: some View {
        PanelSplitter(axis: .horizontal, idleVisible: false) { translation in
            if rowDragOrigin == nil { rowDragOrigin = model.panelLayout.rowHeight }
            let origin = rowDragOrigin ?? PanelLayoutStore.defaultRowHeight
            model.panelLayout.setRowHeight(origin + translation.height)
        } onEnded: {
            rowDragOrigin = nil
        }
    }

    /// Automation disclosure: an axis-chart glyph that opens the track's
    /// breakpoint editor row. Glows cyan when the track has an active (enabled,
    /// non-empty) lane; outlined while the row is open.
    private var automationDisclosure: some View {
        let active = AutomationLaneSelection.hasActiveLane(track)
        return Button {
            model.toggleAutomation(track.id)
        } label: {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(active || isExpanded ? DAWTheme.playback : DAWTheme.textDim)
                .frame(width: 20, height: 18)
                .background((active || isExpanded) ? DAWTheme.playback.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(
                        isExpanded ? DAWTheme.playback.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
                )
                .glow(DAWTheme.playback, radius: 4, intensity: active ? 0.5 : 0)
        }
        .buttonStyle(.plain)
        .help("Automation — draw volume or pan over time")
    }

    /// Takes disclosure (M5 iii-c): a stacked-layers glyph that opens the track's
    /// take-lanes section. Shown only when the track HAS take groups (nothing to
    /// comp otherwise); glows signal-green because a group exists, outlined while
    /// the section is open.
    @ViewBuilder
    private var takesDisclosure: some View {
        if TakeLaneSelection.hasTakeGroups(track) {
            Button {
                model.toggleTakes(track.id)
            } label: {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.signal)
                    .frame(width: 20, height: 18)
                    .background(DAWTheme.signal.opacity(isTakesExpanded ? 0.22 : 0.14))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4).stroke(
                            isTakesExpanded ? DAWTheme.signal.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
                    )
                    .glow(DAWTheme.signal, radius: 4, intensity: 0.5)
            }
            .buttonStyle(.plain)
            .help("Takes — comp the best parts across recorded takes")
        }
    }
}

/// The expanded automation controls under a track header: a target picker
/// (Volume / Pan in v0), an enable toggle, and a remove button for the selected
/// lane. Sized to match the timeline's automation editor row so the two columns
/// stay aligned. All mutations route through the store's automation methods.
struct AutomationTrackControls: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    var track: Track

    private var selectedLane: AutomationLane? {
        AutomationLaneSelection.selectedLane(in: track, selection: model.automationLaneSelection[track.id])
    }

    private var selectedParam: AutomationParam? {
        selectedLane.flatMap { AutomationParam(target: $0.target) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("AUTOMATION")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textDim)
                Spacer()
                if let lane = selectedLane {
                    enableToggle(lane)
                    removeButton(lane)
                }
            }

            HStack(spacing: 6) {
                ForEach(AutomationParam.allCases, id: \.self) { param in
                    paramChip(param)
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(height: TimelineLanesView.automationLaneHeight, alignment: .top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 1)
        }
    }

    /// A target chip: lit cyan when it's the one being edited, with a small dot
    /// when a lane already exists for it. Tapping selects-or-creates its lane.
    private func paramChip(_ param: AutomationParam) -> some View {
        let isSelected = selectedParam == param
        let hasLane = AutomationLaneSelection.lane(for: param, in: track) != nil
        return Button {
            model.selectOrCreateAutomationLane(trackID: track.id, param: param)
        } label: {
            HStack(spacing: 4) {
                Circle()
                    .fill(hasLane ? DAWTheme.playback : DAWTheme.textDim.opacity(0.4))
                    .frame(width: 5, height: 5)
                Text(param.shortLabel)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(isSelected ? DAWTheme.playback : DAWTheme.textDim)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? DAWTheme.playback.opacity(0.18) : DAWTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(
                    isSelected ? DAWTheme.playback.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Automate \(param.label.lowercased())")
    }

    /// Read/manual toggle: green "ON" when the lane's drawn curve drives the
    /// engine, dim "OFF" when the fader/knob is back in the user's hands.
    private func enableToggle(_ lane: AutomationLane) -> some View {
        Button {
            _ = try? store.setAutomationLaneEnabled(
                trackID: track.id, laneID: lane.id, !lane.isEnabled)
        } label: {
            Text(lane.isEnabled ? "ON" : "OFF")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(lane.isEnabled ? DAWTheme.signal : DAWTheme.textDim)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(lane.isEnabled ? DAWTheme.signal.opacity(0.18) : DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(
                        lane.isEnabled ? DAWTheme.signal.opacity(0.6) : DAWTheme.hairline, lineWidth: 1)
                )
                .glow(DAWTheme.signal, radius: 4, intensity: lane.isEnabled ? 0.4 : 0)
        }
        .buttonStyle(.plain)
        .help(lane.isEnabled ? "Automation on — the drawn curve drives this control"
                             : "Automation off — the fader/knob is manual")
    }

    private func removeButton(_ lane: AutomationLane) -> some View {
        Button {
            model.deleteAutomationLane(trackID: track.id, laneID: lane.id)
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 20, height: 18)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Delete this automation lane")
    }
}

/// The expanded take controls under a track header (M5 iii-c): one block per
/// take group (name + lane count + Flatten) over a compact row per lane (name,
/// a select button, a delete button). Sized row-for-row to match the timeline's
/// take-lanes section so the sidebar and timeline stay aligned. All mutations
/// route through the store's take methods.
struct TakeTrackControls: View {
    @Environment(ProjectStore.self) private var store
    var track: Track

    var body: some View {
        VStack(spacing: 0) {
            ForEach(track.takeGroups) { group in
                groupBlock(group)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 1)
        }
    }

    @ViewBuilder
    private func groupBlock(_ group: TakeGroup) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DAWTheme.signal)
                Text(group.name)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(group.lanes.count)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                Button {
                    _ = try? store.flattenTakeGroup(trackId: track.id, groupId: group.id)
                } label: {
                    Text("FLATTEN")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                        .padding(.horizontal, 4)
                        .frame(height: 13)
                        .background(DAWTheme.panel)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help("Flatten this take group into ordinary, editable clips")
            }
            .padding(.horizontal, 8)
            .frame(height: TimelineLanesView.takeGroupHeaderHeight)

            ForEach(Array(group.lanes.enumerated()), id: \.element.id) { index, lane in
                laneRow(group: group, lane: lane, isNewest: index == group.lanes.count - 1)
            }
        }
    }

    private func laneRow(group: TakeGroup, lane: TakeLane, isNewest: Bool) -> some View {
        let isSelected = group.comp.contains { $0.laneID == lane.id }
        return HStack(spacing: 5) {
            if isNewest {
                Rectangle().fill(DAWTheme.signal.opacity(0.7)).frame(width: 2, height: 12)
            } else {
                Spacer().frame(width: 2)
            }
            Button {
                _ = try? store.selectTake(trackId: track.id, groupId: group.id, laneId: lane.id)
            } label: {
                Circle()
                    .fill(isSelected ? DAWTheme.signal : DAWTheme.textDim.opacity(0.4))
                    .frame(width: 6, height: 6)
                    .glow(DAWTheme.signal, radius: 3, intensity: isSelected ? 0.5 : 0)
            }
            .buttonStyle(.plain)
            .help("Select this take across the whole range")

            Text(lane.name)
                .font(.system(size: 9, weight: isNewest ? .bold : .medium, design: .monospaced))
                .foregroundStyle(isSelected ? DAWTheme.textPrimary : DAWTheme.textDim)
                .lineLimit(1)

            Spacer(minLength: 0)

            Button {
                _ = try? store.removeTakeLane(trackId: track.id, groupId: group.id, laneId: lane.id)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 8))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 18, height: 14)
                    .background(DAWTheme.panel)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            .buttonStyle(.plain)
            .help("Delete this take (rejected while it is in use or the last take)")
        }
        .padding(.horizontal, 8)
        .frame(height: TimelineLanesView.takeLaneRowHeight)
        .background(isSelected ? DAWTheme.signal.opacity(0.08) : Color.clear)
    }
}

struct ToggleChip: View {
    var label: String
    var isOn: Bool
    var onColor: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isOn ? onColor : DAWTheme.textDim)
                .frame(width: 20, height: 18)
                .background(isOn ? onColor.opacity(0.18) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4).stroke(
                        isOn ? onColor.opacity(0.6) : DAWTheme.hairline,
                        lineWidth: 1
                    )
                )
                .glow(onColor, radius: 4, intensity: isOn ? 0.5 : 0)
        }
        .buttonStyle(.plain)
    }
}
