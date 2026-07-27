import AppKit
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
    @Environment(AppModel.self) private var model

    /// The list's own coordinate space (m23-h). The row frames, the reorder
    /// drag gesture and the drop indicator ALL live in it, which is what makes
    /// the drag scroll-invariant: the space scrolls with the rows, so a pointer
    /// y always means the same row wherever the shared vertical scroll sits.
    static let rowSpace = "trackRows"

    /// The MEASURED row ladder — the one producer of "where is row i". Never
    /// recomputed from `rowHeight` + the model: a row's height depends on its
    /// takes/automation sections and `rowHeight` is user-adjustable, so a second
    /// computation would be free to agree with the layout only by luck.
    @State private var ladder = TrackRowLadder.empty
    /// The drag in flight, or nil. Visual-only until release — the model is NOT
    /// mutated on every step, so the whole gesture is ONE undo step.
    @State private var drag: TrackHeaderDragSession?

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
                    ForEach(Array(store.tracks.enumerated()), id: \.element.id) { index, track in
                        TrackRow(
                            track: track,
                            // Non-nil ONLY on the row being dragged: it is both the
                            // lift styling's switch and its displacement, so a lifted
                            // row that isn't moving is unrepresentable.
                            dragOffsetY: drag?.trackID == track.id ? drag?.offsetY : nil,
                            onReorderChanged: { y in
                                dragUpdate(trackID: track.id, pointerY: y)
                            },
                            onReorderEnded: { y in dragEnd(pointerY: y) })
                            .id(track.id)   // scroll target (m13-g deep-scroll proof)
                            // The picked-up row rides ABOVE its neighbours.
                            .zIndex(drag?.trackID == track.id ? 1 : 0)
                            // …and every row it passes SLIDES to open the slot it
                            // is heading for, so the list parts instead of the
                            // dragged row simply covering its target. STATED
                            // LIMIT: the preview is the SIDEBAR's alone — the
                            // timeline lanes read the model, which does not move
                            // until release, so for the duration of a drag the
                            // two columns are deliberately out of step. Previewing
                            // the lanes too would mean threading the drag into
                            // `TimelineLanesView`; the alternative (no parting)
                            // hides the very row the user is aiming at.
                            .offset(y: partingOffset(row: index, track: track))
                            .animation(.easeOut(duration: 0.12),
                                       value: partingOffset(row: index, track: track))
                            .background(rowFrameReporter(track.id))
                    }
                }
                .coordinateSpace(name: Self.rowSpace)
                .overlay(alignment: .top) { dropIndicator }
                .onPreferenceChange(TrackRowFramesKey.self) { frames in
                    measureLadder(frames)
                }
                // The staging seam (m23-h) drives the SAME two handlers the live
                // gesture drives — never a private "just reorder it" path, which
                // could pass a gate the real drag fails.
                .onChange(of: model.trackReorderStage) { _, stage in applyStage(stage) }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .glassPanel()
    }

    /// The insertion line: where the picked-up row will land if released now.
    /// Cyan (the app's "active/where you are" accent) and glowing — earned by
    /// the drag, never standing at rest. It exists EXACTLY when the drop would
    /// change the order: `indicatorY` is nil for a no-op landing by
    /// construction, so "the line lies" is not a reachable state.
    @ViewBuilder
    private var dropIndicator: some View {
        if let y = drag?.drop?.indicatorY {
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(height: 2)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.8)
                .offset(y: y - 1)
                .allowsHitTesting(false)
        }
    }

    /// How far a resting row slides to open the slot the drag is heading for.
    /// Zero for the dragged row itself — it follows the pointer instead, and
    /// the registry refuses to displace its origin row, so the two offsets can
    /// never both apply.
    private func partingOffset(row: Int, track: Track) -> CGFloat {
        guard let drag, track.id != drag.trackID, let drop = drag.drop else { return 0 }
        return TrackReorderDrag.displacement(row: row, drop: drop, ladder: ladder)
    }

    /// Reports one row's rect in the list's coordinate space. A transparent
    /// background probe — it changes no layout.
    private func rowFrameReporter(_ id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: TrackRowFramesKey.self,
                value: [id: geo.frame(in: .named(Self.rowSpace))])
        }
    }

    // MARK: - Drag handlers (the live gesture AND the seam land here)

    /// Collects the measured rects into the ordered ladder. Ignores a
    /// HALF-measured pass (a row added/removed mid-layout): a ladder that
    /// described the wrong number of rows would resolve confident, wrong
    /// landings.
    ///
    /// FROZEN FOR THE WHOLE GESTURE, and that is load-bearing rather than
    /// cautious: the lift and the parting are `offset`s, so a live re-measure
    /// would report rows at their DISPLACED positions, feed that back into the
    /// ladder the landing is resolved against, and let the drag chase itself.
    /// The ladder describes the RESTING slots — which is exactly what a landing
    /// index means. It re-measures on the next layout after release.
    private func measureLadder(_ frames: [UUID: CGRect]) {
        guard drag == nil else { return }
        let ordered = store.tracks.compactMap { frames[$0.id] }
        guard ordered.count == store.tracks.count else { return }
        let next = TrackRowLadder(tops: ordered.map(\.minY), heights: ordered.map(\.height))
        guard next != ladder else { return }
        ladder = next
        publish()
    }

    /// Press / drag. Begins the session on the first tick (there is no separate
    /// "press" event in a `DragGesture`), then re-decides the landing every
    /// step. Visual only — nothing is committed until release.
    private func dragUpdate(trackID: UUID, pointerY: CGFloat) {
        defer { publish() }
        guard let from = store.tracks.firstIndex(where: { $0.id == trackID }) else {
            drag = nil
            return
        }
        var session = drag?.trackID == trackID
            ? drag!
            : TrackHeaderDragSession(trackID: trackID, startPointerY: pointerY,
                                     pointerY: pointerY, drop: nil)
        session.pointerY = pointerY
        session.drop = TrackReorderDrag.resolve(
            pointerY: pointerY, from: from, ladder: ladder)
        drag = session
    }

    /// Release: commit the landing the indicator was showing, then put the row
    /// down. ONE store call ⇒ ONE undo step for the whole gesture.
    private func dragEnd(pointerY: CGFloat) {
        defer { publish() }
        guard let session = drag else { return }
        drag = nil
        guard let from = store.tracks.firstIndex(where: { $0.id == session.trackID }),
              let drop = TrackReorderDrag.resolve(
                pointerY: pointerY, from: from, ladder: ladder),
              drop.moves else { return }
        commit(trackID: session.trackID, drop: drop)
    }

    /// The ONE commit path, typed to take a `ResolvedTrackDrop` — which only
    /// `TrackReorderDrag.resolve` can produce. So the index committed here is
    /// the very one the indicator was drawn from; they cannot drift apart.
    /// `try?`: the sole throw is `trackNotFound`, and the index was resolved
    /// from a live row a moment ago — a race there means the track is gone and
    /// there is nothing to say about it.
    private func commit(trackID: UUID, drop: ResolvedTrackDrop) {
        _ = try? store.reorderTrack(id: trackID, toIndex: drop.index)
    }

    /// Applies a staged step through the handlers above. Every branch reports
    /// (the handlers' `defer { publish() }`, or an explicit publish), because
    /// the seam WAITS on the report seq — a branch that stayed silent would
    /// leave it echoing the previous call's state.
    private func applyStage(_ stage: TrackReorderStage?) {
        guard let stage else { return }
        switch stage.action {
        case .begin:
            drag = nil
            if let id = stage.trackID, store.tracks.contains(where: { $0.id == id }) {
                dragUpdate(trackID: id, pointerY: stage.y)
            } else {
                publish()
            }
        case .changed:
            if let id = drag?.trackID {
                dragUpdate(trackID: id, pointerY: stage.y)
            } else {
                publish()   // nothing in flight: report, never invent a drag
            }
        case .end:
            dragEnd(pointerY: stage.y)
        }
    }

    /// Hands the ladder + the live landing UP to the app model, then bumps the
    /// report seq LAST so anything waiting on it sees the state it announces
    /// (the `arrangePointerReportSeq` rule).
    private func publish() {
        if model.trackRowLadder != ladder { model.trackRowLadder = ladder }
        let state = drag.map {
            TrackReorderDragState(trackID: $0.trackID, drop: $0.drop, offsetY: $0.offsetY)
        }
        if model.trackReorderDrag != state { model.trackReorderDrag = state }
        model.trackReorderReportSeq &+= 1
    }
}

/// The drag in flight (view-local). `offsetY` is derived, never stored, so the
/// lift and the landing can never describe different pointer positions.
struct TrackHeaderDragSession: Equatable {
    var trackID: UUID
    var startPointerY: CGFloat
    var pointerY: CGFloat
    var drop: ResolvedTrackDrop?

    var offsetY: CGFloat { pointerY - startPointerY }
}

/// Per-row measured rects, merged up the tree (m23-h).
private struct TrackRowFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

struct TrackRow: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    var track: Track

    // MARK: Reorder drag (m23-h) — owned by the LIST, driven from here

    /// How far this row is displaced while it is the one being dragged; nil on
    /// every other row (and on all of them when no drag is in flight). One
    /// value carries both "am I lifted" and "by how much".
    var dragOffsetY: CGFloat?
    /// Pointer moved, in the list's coordinate space.
    var onReorderChanged: (CGFloat) -> Void = { _ in }
    /// Pointer released, in the list's coordinate space.
    var onReorderEnded: (CGFloat) -> Void = { _ in }

    private var isDragging: Bool { dragOffsetY != nil }

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
                isDragging
                    ? DAWTheme.playback.opacity(0.7)
                    : (track.isAIGenerated ? DAWTheme.ai.opacity(0.35) : DAWTheme.hairline),
                lineWidth: 1
            )
        )
        // Picked up: the card LIFTS off the panel — a cyan rim, a soft glow and
        // a cast shadow, all earned by the drag and gone the instant it ends
        // (Rule 3: nothing static glows). The offset follows the pointer so the
        // row is literally the thing being moved, not a proxy for it.
        .glow(DAWTheme.playback, radius: 6, intensity: isDragging ? 0.45 : 0)
        .shadow(color: .black.opacity(isDragging ? 0.45 : 0),
                radius: isDragging ? 10 : 0, y: isDragging ? 4 : 0)
        .offset(y: dragOffsetY ?? 0)
        // RENDERED FROM THE MODEL (m23-m3b), never from inline conditions.
        // `TrackHeaderMenu.items` decides WHICH items exist and what each says;
        // this builder only binds them to their actions. An AppKit context-menu
        // popup cannot be opened by `debug.captureUI`, so the item list is only
        // assertable if it lives somewhere headless — and only HONESTLY
        // assertable if the menu holds no second opinion. There is deliberately
        // not one `if` left in this body: "the view ignores the model" would now
        // have to be a visible edit here, not a silent runtime divergence.
        .contextMenu {
            ForEach(model.trackHeaderMenuItems(for: track)) { item in
                Button(item.title, role: item.isDestructive ? .destructive : nil) {
                    perform(item.action)
                }
            }
        }
    }

    /// Runs the action a context-menu item names — the ONE place each item's
    /// behaviour lives, so the builder above stays a pure rendering of the list.
    private func perform(_ action: TrackHeaderMenuAction) {
        switch action {
        case .rename:
            beginEditing()
        case .toggleAutomation:
            model.toggleAutomation(track.id)
        case .bounceInPlace:
            // Both densities (a plain action, no advanced-control split). Lands
            // a new audio track + clip in one undo step; refused states fail as
            // safe no-ops, hence `try?`.
            Task { try? await store.bounceTrackInPlace(trackId: track.id) }
        case .exportMIDI:
            exportMIDI()
        case .removeTrack:
            // m13-c: refused mid-recording (transportBusy) — safe no-op here.
            _ = try? store.removeTrack(id: track.id)
        }
    }

    /// "Export MIDI…" (m23-m3b): write THIS track out as a Standard MIDI File,
    /// giving `store.exportTrackMIDIFile` (m23-k4a) its first human surface.
    ///
    /// The item is offered only where `Track.canExportMIDI` holds, which is the
    /// SAME predicate the store refuses on, so the save panel can never open on
    /// a track the store would then reject. That leaves exactly one reachable
    /// failure — an unwritable destination — and this is the first action in
    /// this view that SURFACES its error rather than swallowing it. The `try?`
    /// sites around it are deliberately left alone: those are operations that
    /// fail as safe no-ops in known states (a reorder or a remove refused
    /// mid-recording), whereas an export the user explicitly asked for that
    /// wrote no file must say so. Same alert shape as `FileCommands.present(_:)`
    /// for the sibling whole-project verb, surfacing the reason verbatim.
    ///
    /// Export mutates nothing, so there is no undo step and no success alert.
    @MainActor
    private func exportMIDI() {
        let panel = NSSavePanel()
        // The TRACK's name, not the project's — this file is one part.
        panel.nameFieldStringValue = track.name
        panel.prompt = "Export"
        // The SAME list File→Export MIDI… uses (`FileCommands.swift:119`). A
        // second literal here is how two save panels start disagreeing about
        // what a MIDI file is.
        panel.allowedContentTypes = AudioImportPlan.midiContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportTrackMIDIFile(trackID: track.id, path: url.path)
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "Couldn't complete that"
            alert.informativeText = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            alert.runModal()
        }
    }

    private var row: some View {
        // Tight top-level spacing (4 pt, m17-f F1 — was 5) so a fully-loaded row
        // still fits inside the sidebar's narrow end (250 pt) WITHOUT the name
        // giving up its readable share; the Spacer restores generous separation at
        // wider widths. The instrument chip (m10-n-3) joined this row after the
        // m10-i budget was measured, so the chrome (spacing + M/S/R + disclosure
        // widths) re-tightened here to hand the name back its ≳60 pt share at the
        // DEFAULT sidebar — "Synth 10" must read untruncated out of the box.
        HStack(spacing: 4) {
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
        // It is an OVERLAY on this row, so inside its 6 pt strip it wins the
        // gesture over the reorder drag below — height resize and reorder never
        // fight for the same pixels.
        .overlay(alignment: .bottom) { rowHeightHandle }
        // Drag the header ITSELF to reorder the track list (m23-h). A 6 pt
        // minimum distance keeps every click gesture the row already has — the
        // double-click rename, the M/S/R chips, the disclosures — reachable: a
        // press that doesn't travel is never a drag.
        .gesture(reorderDrag)
    }

    /// The reorder gesture. Reports the pointer in the LIST's coordinate space
    /// (never `.local`), which is the space the row ladder is measured in — so
    /// the landing is right at any scroll position and any row height.
    private var reorderDrag: some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named(TrackRowsList.rowSpace))
            .onChanged { value in
                // Hold the closed hand for the whole drag, even when the pointer
                // leaves the row (the m10-c gesture-driven cursor idiom).
                DragCursor.set(CursorAffordance.trackHeader.dragCursor)
                onReorderChanged(value.location.y)
            }
            .onEnded { value in
                DragCursor.clear()
                onReorderEnded(value.location.y)
            }
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
        // The open hand advertises the reorder drag where it is most obviously
        // "the track itself" — the icon + name. The gesture works from anywhere
        // on the row that isn't a control; the cursor teaches the canonical spot
        // rather than claiming the chips (m23-h, the movable-body family).
        .hoverCursor(CursorAffordance.trackHeader.restCursor)
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
                .frame(width: 18, height: 18)   // 18 pt (m17-f F1) — see ToggleChip
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
                    .frame(width: 18, height: 18)   // 18 pt (m17-f F1) — see ToggleChip
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
                // 18 pt wide (m17-f F1 — was 20): one mono letter needs ~8 pt, and
                // the 3 chips ride the crowded track-header row where every point
                // feeds the name's readable share.
                .frame(width: 18, height: 18)
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
