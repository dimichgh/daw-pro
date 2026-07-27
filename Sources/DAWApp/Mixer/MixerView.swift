import SwiftUI
import DAWCore
import DAWAppKit

/// The full mixing console: a horizontal rack of channel strips (audio +
/// instrument tracks in project order), then the visually-grouped bus strips,
/// with the master strip pinned at the right. Overflows horizontally; the
/// master stays in view. A thin surface over `ProjectStore` + `MixerLayout` —
/// no local mixing state of its own.
struct MixerView: View {
    @Environment(ProjectStore.self) private var store
    @Environment(AppModel.self) private var model
    /// The console's shared density store (docs/DESIGN-LANGUAGE.md "Panels").
    /// Threaded to every channel/bus strip AND the master strip — since m13-d
    /// the master strip reveals its insert chain only in Pro (its fader/meters
    /// show in both). The SIMPLE/PRO chip in the Mix toolbar binds the same
    /// store under `panelID`.
    var densityStore: PanelDensityStore
    /// The app's shared layout store (m23-a) — threaded to every strip for the
    /// console-wide INSERTS disclosure flag (`panelLayout.mixerInsertsCollapsed`).
    /// Console-wide like density: the mixer is ONE panel.
    var layoutStore: PanelLayoutStore

    /// Stable density key for the whole mixer console — the console is ONE panel,
    /// so every strip and the toolbar chip share this one ID.
    static let panelID = "mixer"

    /// The strip rack's own coordinate space (m23-z). The strip frames, the
    /// reorder gesture and the insertion line ALL live in it, which is what makes
    /// the drag scroll-invariant: the space scrolls WITH the strips, so a pointer
    /// x always means the same strip wherever the horizontal scroll sits. (A
    /// `.local` frame here is the classic trap — silently right at scroll 0 and
    /// wrong at every other offset.)
    static let stripSpace = "mixerStrips"

    /// The MEASURED strip ladder, in VISUAL order — the one producer of "where
    /// is strip i". Never computed from the 132 pt strip width: the bus divider
    /// is sized by its caption's INTRINSIC width, so a computed ladder would
    /// agree with the layout by luck on a bus-free project and drift on every
    /// other one.
    @State private var ladder = MixerStripLadder.empty
    /// The drag in flight, or nil. Visual-only until release — the model is NOT
    /// mutated on every step, so the whole gesture is ONE undo step.
    @State private var drag: MixerStripDragSession?

    var body: some View {
        let channels = MixerLayout.channelTracks(store.tracks)
        let buses = MixerLayout.busTracks(store.tracks)
        let strips = MixerLayout.orderedStrips(store.tracks)

        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 10) {
                    if channels.isEmpty && buses.isEmpty {
                        emptyState
                    } else {
                        // Every strip is explainable (ex-b): per-instance frame
                        // anchoring (ExplainCoordinator) lands each shared ExplainID
                        // on whichever strip is hovered, so a full console tags cleanly.
                        ForEach(channels) { track in
                            strip(track, slot: strips.firstIndex { $0.id == track.id })
                        }
                        if !buses.isEmpty {
                            busDivider
                            ForEach(buses) { track in
                                strip(track, slot: strips.firstIndex { $0.id == track.id })
                            }
                        }
                    }
                }
                .coordinateSpace(name: Self.stripSpace)
                .overlay(alignment: .leading) { dropIndicator }
                .onPreferenceChange(MixerStripFramesKey.self) { frames in
                    measureLadder(frames)
                }
                // The staging seam (m23-z) drives the SAME two handlers the live
                // gesture drives — never a private "just reorder it" path, which
                // could pass a gate the real drag fails.
                .onChange(of: model.mixerStripDragStage) { _, stage in applyStage(stage) }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxHeight: .infinity)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // Master is outside the scroller so it stays pinned at the right.
            MixerMasterStrip(densityStore: densityStore, layoutStore: layoutStore)
                .padding(.vertical, 12)
                .padding(.leading, 8)
                .padding(.trailing, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .glassPanel(cornerRadius: 12)
    }

    /// One strip, wired for the reorder drag (m23-z). `slot` is its VISUAL
    /// position — the index the ladder and the parting offsets are keyed by.
    /// Nil is unreachable (the strip came out of `orderedStrips`); it is handled
    /// rather than force-unwrapped so a race can never trap the console.
    @ViewBuilder
    private func strip(_ track: Track, slot: Int?) -> some View {
        MixerChannelStrip(
            track: track, densityStore: densityStore, layoutStore: layoutStore,
            // Non-nil ONLY on the strip being dragged: it is both the lift
            // styling's switch and its displacement, so a lifted strip that
            // isn't moving is unrepresentable.
            dragOffsetX: drag?.trackID == track.id ? drag?.offsetX : nil,
            onReorderChanged: { x in dragUpdate(trackID: track.id, pointerX: x) },
            onReorderEnded: { x in dragEnd(pointerX: x) })
            // The picked-up strip rides ABOVE its neighbours.
            .zIndex(drag?.trackID == track.id ? 1 : 0)
            // …and every strip it passes SLIDES to open the slot it is heading
            // for, so the rack parts instead of the dragged strip simply
            // covering its target.
            .offset(x: partingOffset(slot: slot, track: track))
            .animation(.easeOut(duration: 0.12), value: partingOffset(slot: slot, track: track))
            .background(stripFrameReporter(track.id))
    }

    /// The insertion line: where the picked-up strip will land if released now.
    /// Cyan (the app's "active/where you are" accent) and glowing — earned by
    /// the drag, never standing at rest. It exists EXACTLY when the drop would
    /// change what the console shows: a visually-inert landing has no `landing`
    /// at all, so "the line lies" is not a reachable state.
    @ViewBuilder
    private var dropIndicator: some View {
        if let x = drag?.drop?.landing?.indicatorX {
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.8)
                .offset(x: x - 1)
                .allowsHitTesting(false)
        }
    }

    /// How far a resting strip slides to open the slot the drag is heading for.
    /// Read out of the registry's ONE `partingOffsets` array — the same array
    /// the seam echoes — rather than recomputed per strip here, so no parting
    /// distance exists that a headless test cannot see.
    private func partingOffset(slot: Int?, track: Track) -> CGFloat {
        guard let drag, let slot, track.id != drag.trackID,
              drag.partingOffsets.indices.contains(slot) else { return 0 }
        return drag.partingOffsets[slot]
    }

    /// Reports one strip's rect in the rack's coordinate space. A transparent
    /// background probe — it changes no layout.
    private func stripFrameReporter(_ id: UUID) -> some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: MixerStripFramesKey.self,
                value: [id: geo.frame(in: .named(Self.stripSpace))])
        }
    }

    // MARK: - Drag handlers (the live gesture AND the seam land here)

    /// Collects the measured rects into the ordered ladder. Ignores a
    /// HALF-measured pass (a strip added/removed mid-layout): a ladder that
    /// described the wrong number of strips would resolve confident, wrong
    /// landings.
    ///
    /// FROZEN FOR THE WHOLE GESTURE, and that is load-bearing rather than
    /// cautious: the lift and the parting are `offset`s, so a live re-measure
    /// would report strips at their DISPLACED positions, feed that back into the
    /// ladder the landing is resolved against, and let the drag chase itself.
    /// The ladder describes the RESTING slots — which is exactly what a landing
    /// means. It re-measures on the next layout after release.
    private func measureLadder(_ frames: [UUID: CGRect]) {
        guard drag == nil else { return }
        let strips = MixerLayout.orderedStrips(store.tracks)
        let ordered = strips.compactMap { frames[$0.id] }
        guard ordered.count == strips.count else { return }
        let next = MixerStripLadder(lefts: ordered.map(\.minX), widths: ordered.map(\.width))
        guard next != ladder else { return }
        ladder = next
        publish()
    }

    /// Press / drag. Begins the session on the first tick (there is no separate
    /// "press" event in a `DragGesture`), then re-decides the landing every
    /// step. Visual only — nothing is committed until release.
    private func dragUpdate(trackID: UUID, pointerX: CGFloat) {
        defer { publish() }
        guard store.tracks.contains(where: { $0.id == trackID }) else {
            drag = nil
            return
        }
        var session = drag?.trackID == trackID
            ? drag!
            : MixerStripDragSession(trackID: trackID, startPointerX: pointerX,
                                    pointerX: pointerX, drop: nil, partingOffsets: [])
        session.pointerX = pointerX
        session.drop = MixerStripReorder.resolve(
            pointerX: pointerX, draggedID: trackID, tracks: store.tracks, ladder: ladder)
        session.partingOffsets = session.drop.map {
            MixerStripReorder.partingOffsets(drop: $0, ladder: ladder)
        } ?? []
        drag = session
    }

    /// Release: commit the landing the line was showing, then put the strip
    /// down. ONE store call ⇒ ONE undo step for the whole gesture, and NO call
    /// at all for a visually-inert landing (an array move nobody can see must
    /// not spend an undo step or dirty the project).
    private func dragEnd(pointerX: CGFloat) {
        defer { publish() }
        guard let session = drag else { return }
        drag = nil
        guard let drop = MixerStripReorder.resolve(
            pointerX: pointerX, draggedID: session.trackID,
            tracks: store.tracks, ladder: ladder) else { return }
        commit(trackID: session.trackID, drop: drop)
    }

    /// The ONE commit path, typed to take a `ResolvedStripDrop` — which only
    /// `MixerStripReorder.resolve` can produce, and whose `landing` is nil
    /// exactly when the line was not drawn. So the index committed here is the
    /// very one the line was drawn from, and an inert landing cannot be
    /// committed by forgetting to check a flag: there is no index to pass.
    /// `try?`: the sole throw is `trackNotFound`, and the index was resolved
    /// from a live strip a moment ago.
    private func commit(trackID: UUID, drop: ResolvedStripDrop) {
        guard let landing = drop.landing else { return }
        _ = try? store.reorderTrack(id: trackID, toIndex: landing.arrayIndex)
    }

    /// Applies a staged step through the handlers above. Every branch reports
    /// (the handlers' `defer { publish() }`, or an explicit publish), because
    /// the seam WAITS on the report seq — a branch that stayed silent would
    /// leave it echoing the previous call's state.
    private func applyStage(_ stage: MixerStripDragStage?) {
        guard let stage else { return }
        switch stage.action {
        case .begin:
            drag = nil
            if let id = stage.trackID, store.tracks.contains(where: { $0.id == id }) {
                dragUpdate(trackID: id, pointerX: stage.x)
            } else {
                publish()
            }
        case .changed:
            if let id = drag?.trackID {
                dragUpdate(trackID: id, pointerX: stage.x)
            } else {
                publish()   // nothing in flight: report, never invent a drag
            }
        case .end:
            dragEnd(pointerX: stage.x)
        }
    }

    /// Hands the ladder + the live landing UP to the app model, then bumps the
    /// report seq LAST so anything waiting on it sees the state it announces.
    private func publish() {
        if model.mixerStripLadder != ladder { model.mixerStripLadder = ladder }
        let state = drag.map {
            MixerStripDragState(trackID: $0.trackID, drop: $0.drop, offsetX: $0.offsetX,
                                partingOffsets: $0.partingOffsets)
        }
        if model.mixerStripDrag != state { model.mixerStripDrag = state }
        model.mixerStripDragReportSeq &+= 1
    }

    /// A slim separator + caption that marks where the bus group begins.
    private var busDivider: some View {
        VStack(spacing: 8) {
            Text("BUSES")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Rectangle()
                .fill(DAWTheme.hairline)
                .frame(width: 1)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, 2)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "slider.vertical.3")
                .font(.system(size: 26))
                .foregroundStyle(DAWTheme.textFaint)
            Text("No tracks to mix yet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DAWTheme.textDim)
            Text("Add a track in Arrange, or let an agent do it over MCP")
                .font(.system(size: 11))
                .foregroundStyle(DAWTheme.textFaint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

/// The drag in flight (view-local). `offsetX` is derived, never stored, so the
/// lift and the landing can never describe different pointer positions.
struct MixerStripDragSession: Equatable {
    var trackID: UUID
    var startPointerX: CGFloat
    var pointerX: CGFloat
    var drop: ResolvedStripDrop?
    /// The registry's parting array for the current landing, kept beside the
    /// drop so the view and the seam read the SAME numbers.
    var partingOffsets: [CGFloat]

    var offsetX: CGFloat { pointerX - startPointerX }
}

/// Per-strip measured rects, merged up the tree (m23-z).
private struct MixerStripFramesKey: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// Arrange ⇄ Mix workspace switch — the themed segmented chip pair described in
/// DESIGN-LANGUAGE (active half cyan-lit), matching the Simple/Pro control idiom.
struct WorkspaceToggle: View {
    var mode: WorkspaceMode
    var onSelect: (WorkspaceMode) -> Void

    var body: some View {
        HStack(spacing: 0) {
            segment("Arrange", .arrange)
            segment("Mix", .mix)
        }
        .padding(2)
        .background(DAWTheme.panelRaised)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func segment(_ label: String, _ value: WorkspaceMode) -> some View {
        let active = mode == value
        return Button { onSelect(value) } label: {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(active ? DAWTheme.playback : DAWTheme.textDim)
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(active ? DAWTheme.playback.opacity(0.16) : Color.clear)
                .clipShape(Capsule())
                .glow(DAWTheme.playback, radius: 4, intensity: active ? 0.4 : 0)
        }
        .buttonStyle(.plain)
    }
}
