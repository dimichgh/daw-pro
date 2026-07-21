import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Bottom piano-roll editor panel for a MIDI clip. Thin over `PianoRollModel`:
/// all geometry + edits live there, this draws the grid/notes (Canvas) and
/// routes gestures. Every edit mutates the model draft; the draft is submitted
/// through `onCommit` on gesture END only (never per tick).
///
/// The transport playhead + scrub (beta m10-e) are RENDERINGS of existing state:
/// `positionBeats` is the SAME source the arrange timeline consumes (no second
/// ticker), mapped clip-local by the headless `PianoRollPlayhead`; the cyan line
/// shows only while the transport is inside the edited clip, and `onSeek` is the
/// app's store seek (the existing `transport.seek` path, NOT the WebSocket).
struct PianoRollView: View {
    /// The clip being edited (value input — previewable without the store).
    var clip: Clip
    var beatsPerBar: Int
    /// Live transport position in PROJECT beats (the arrange timeline's source),
    /// mapped clip-local for the playhead. A plain value input so a preview can
    /// stage the line at any position.
    var positionBeats: Double
    /// The shared per-panel density store (docs/DESIGN-LANGUAGE.md "Panels"). The
    /// piano roll reads/sets its Simple/Pro mode under `panelID`, so the mode is
    /// now sticky across close/reopen and relaunch. A plain value input — a
    /// preview can pass a `PanelDensityStore()` with an in-memory backing.
    var densityStore: PanelDensityStore
    /// The shared layout store (m21-c): owns the persisted `pianoRollPPB` zoom
    /// slot every band rescales from. A plain value input — a preview can pass
    /// a `PanelLayoutStore()` with an in-memory backing.
    var layout: PanelLayoutStore
    /// Submits the whole note array (wired to `ProjectStore.setClipNotes`).
    var onCommit: ([MIDINote]) -> Void
    /// Seeks the transport to a PROJECT beat (wired to `ProjectStore.seek`) — the
    /// scrub's only side effect. Kept a closure so the view stays store-free and
    /// previewable (the `onCommit` precedent).
    var onSeek: (Double) -> Void
    /// Excises a CLIP-LOCAL beat range and closes the gap (wired to
    /// `ProjectStore.deleteTimeRange`); returns the updated clip so the view can
    /// reseed its edit model, or nil if the store rejected it. Store-free closure
    /// (the `onCommit`/`onSeek` precedent) so the view stays previewable (m10-h).
    var onDeleteTimeRange: (_ startBeat: Double, _ lengthBeats: Double) -> Clip?
    /// Inserts CLIP-LOCAL silence, pushing later notes right (wired to
    /// `ProjectStore.insertTimeRange`); returns the updated clip or nil (m10-h).
    var onInsertTimeRange: (_ atBeat: Double, _ lengthBeats: Double) -> Clip?
    /// Opens the Quantize & Groove panel for this clip (m11-a) — the panel owns its
    /// own density, so this affordance shows in both piano-roll modes (tightening
    /// timing is a beginner action; the panel's Simple mode is grid + strength).
    var onOpenQuantize: () -> Void
    /// Commits the visible controller lane (m16-b4) through
    /// `ProjectStore.setControllerLane` — the SAME store call the
    /// `clip.setControllerLane` wire verb uses — and returns the updated clip so
    /// the strip can reseed its edit model (the bar-ops reseed idiom). Store-free
    /// closure (the `onCommit` precedent) so the view stays previewable.
    var onCommitControllerLane: (_ type: MIDIControllerType, _ points: [MIDIControllerPoint]) -> Clip?
    var onClose: () -> Void
    /// Reports the editor's key-focus state (m21-c) so the app can route the
    /// View-menu ⌘+/⌘−/⌘0 to THIS editor's zoom while it is focused (menu key
    /// equivalents fire before any focused view sees the key, so the routing
    /// must happen app-side). Defaulted so previews stay one-liner-simple.
    var onFocusChange: (Bool) -> Void

    @State private var model: PianoRollModel
    /// Edit model for the Pro controller strip (m16-b4), seeded from the clip's
    /// lanes. Recreated with the view on a clip switch (`.id(clip.id)`).
    @State private var controllerModel: ControllerStripModel
    @State private var snap: SnapResolution = .beat
    @State private var activeDrag: ActiveDrag = .none
    @State private var didMove = false
    /// Live horizontal-scroll offset of the note grid, read from the grid's
    /// content geometry so the frozen scrub strip above the grid maps its local x
    /// back to a content beat even when the grid is scrolled. Only changes on a
    /// horizontal scroll (never on a transport tick), so it stays off the playback
    /// redraw path.
    @State private var gridScrollX: CGFloat = 0
    /// The editor panel's full width, read once from a background GeometryReader
    /// (the `gridScrollReader` idiom). Feeds the m18-f wide-window rule: every
    /// horizontal band draws at `max(content, viewport)` so the grid reaches the
    /// panel's right edge instead of leaving dead glass. Changes only on a window
    /// or splitter resize — never on a transport tick or playback frame.
    @State private var panelWidth: CGFloat = 0
    /// The zoom scale captured on the first pinch tick (m21-c) — each tick
    /// rescales off the gesture-START value because `MagnifyGesture`'s
    /// magnification is cumulative (the arrange `PinchState` rule, minus the
    /// anchor math: the roll's plain SwiftUI scroller owns its own offset).
    @State private var pinchStartPPB: CGFloat?
    /// A transient inline reason shown when the delete-bar button is pressed
    /// while it can't act (m21-c bar-ops honesty) — the m17-c refusal-bubble
    /// idiom: amber, verbatim prose, auto-clearing.
    @State private var barOpsNotice: String?
    @State private var barOpsNoticeTask: Task<Void, Never>?
    @FocusState private var isFocused: Bool

    private static let keyboardWidth: CGFloat = 54
    /// Height of the frozen scrub strip pinned to the top of the note grid.
    private static let scrubStripHeight: CGFloat = 18
    /// Stable density key for this panel.
    private static let panelID = "pianoRoll"
    /// Coordinate space naming the grid's horizontal scroll viewport, so the
    /// content's leading edge reports the live scroll offset.
    private static let gridScrollSpace = "pianoRollGridScroll"

    init(clip: Clip, beatsPerBar: Int, positionBeats: Double, densityStore: PanelDensityStore,
         layout: PanelLayoutStore,
         onCommit: @escaping ([MIDINote]) -> Void, onSeek: @escaping (Double) -> Void,
         onDeleteTimeRange: @escaping (_ startBeat: Double, _ lengthBeats: Double) -> Clip?,
         onInsertTimeRange: @escaping (_ atBeat: Double, _ lengthBeats: Double) -> Clip?,
         onOpenQuantize: @escaping () -> Void,
         onCommitControllerLane: @escaping (_ type: MIDIControllerType, _ points: [MIDIControllerPoint]) -> Clip?,
         onClose: @escaping () -> Void,
         onFocusChange: @escaping (Bool) -> Void = { _ in }) {
        self.clip = clip
        self.beatsPerBar = beatsPerBar
        self.positionBeats = positionBeats
        self.densityStore = densityStore
        self.layout = layout
        self.onCommit = onCommit
        self.onSeek = onSeek
        self.onDeleteTimeRange = onDeleteTimeRange
        self.onInsertTimeRange = onInsertTimeRange
        self.onOpenQuantize = onOpenQuantize
        self.onCommitControllerLane = onCommitControllerLane
        self.onClose = onClose
        self.onFocusChange = onFocusChange
        _model = State(initialValue: PianoRollModel(
            notes: clip.notes ?? [],
            clipLengthBeats: clip.lengthBeats
        ))
        _controllerModel = State(initialValue: ControllerStripModel(
            lanes: clip.controllerLanes,
            clipLengthBeats: clip.lengthBeats
        ))
    }

    /// The panel's live density (Simple default), read from the shared store.
    private var mode: PanelDensity { densityStore.density(forPanel: Self.panelID) }

    /// Simple mode locks snapping to whole beats; Pro honors the picker.
    private var effectiveSnap: SnapResolution { mode == .simple ? .beat : snap }

    /// Violet whenever the clip is AI-touched, else playback cyan.
    private var noteColor: Color { clip.isAIGenerated ? DAWTheme.ai : DAWTheme.playback }

    // MARK: - Wide-window band widths (m18-f — DESIGN-LANGUAGE "Wide windows")

    /// The horizontal viewport every band scrolls in: the panel minus the shared
    /// 54 pt gutter (keyboard sidebar / VEL label / CTRL label — all
    /// `keyboardWidth`-wide by design, so one number serves all three bands).
    private var bandViewportWidth: CGFloat { max(0, panelWidth - Self.keyboardWidth) }

    /// Drawn width of the note grid AND the velocity lane (they share the grid's
    /// beat→x space, so they must stay width-identical): content, extended to the
    /// viewport at wide windows. The extension is shaded latent space — the
    /// out-of-clip shade keeps the playable window honest.
    private var gridDrawnWidth: CGFloat {
        PianoRollModel.drawnWidth(content: model.contentWidth, viewport: bandViewportWidth)
    }

    /// Drawn width of the controller canvas — its own model's content width
    /// (CC points can outrun notes and vice versa), same viewport extension.
    private var controllerDrawnWidth: CGFloat {
        PianoRollModel.drawnWidth(content: controllerModel.contentWidth, viewport: bandViewportWidth)
    }

    private enum ActiveDrag: Equatable {
        case none
        case click(UUID?)     // shift-click or empty — resolved on drag end
        case move
        case resize(UUID)
        /// An external mutation reseeded the models mid-gesture (m18-i): the
        /// rest of the drag is swallowed — no apply, no commit, and no restart
        /// (`onChanged` only begins a gesture from `.none`) — so a half-dragged
        /// ghost never lands on the new content. Cleared on gesture end.
        case cancelled
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                // The bar-ops refusal bubble hangs below the header over the
                // grid; keep the header's overflow above the editor band.
                .zIndex(1)
            Divider().overlay(DAWTheme.hairline)
            editor
                .explainable(.pianoRollGrid)
            if mode == .pro {
                Divider().overlay(DAWTheme.hairline)
                velocitySection
                    .explainable(.pianoRollVelocity)
                Divider().overlay(DAWTheme.hairline)
                controllerSection
                    .explainable(.pianoRollControllers)
            }
        }
        .glassPanel()
        .background { panelWidthReader }
        .focusable()
        .focused($isFocused)
        .onKeyPress(.delete) {
            guard !model.selection.isEmpty else { return .ignored }
            model.deleteSelection()
            commit()
            return .handled
        }
        .onAppear { isFocused = true }
        // m21-c: report key focus so the app routes ⌘+/⌘−/⌘0 to THIS editor's
        // zoom while it is focused (the View-menu key equivalents fire before
        // any focused view sees the key, so routing lives app-side).
        .onChange(of: isFocused, initial: true) { _, focused in onFocusChange(focused) }
        .onDisappear { onFocusChange(false) }
        // m21-c: ONE persisted zoom value (`panelLayout.pianoRollPPB`) feeds
        // every band's beat→x mapping — the note grid + velocity lane via
        // `model`, the controller strip via its own model — so all three
        // rescale together and never drift.
        .onChange(of: layout.pianoRollPPB, initial: true) { _, ppb in
            model.pixelsPerBeat = ppb
            controllerModel.pixelsPerBeat = ppb
        }
        // m18-i: the external-mutation seam. `.id(clip.id)` recreates this view
        // (and its seeded @State models) only on a clip IDENTITY switch; a
        // wire/arrange-side geometry op (`clip.trim`/`move`/`split`, arrange
        // bar ops, undo/redo of any) mutates the clip VALUE under the same
        // identity — without this, every band keeps drawing the pre-op
        // snapshot until a reselect. The MODELS decide staleness themselves
        // (`needsReseed`, canonical-content compare — headless-tested), so the
        // editor's own commits echoing back through the store read as equal
        // and never double-reseed (which would clobber scroll/selection/the
        // strip's chosen lane).
        .onChange(of: clip) { _, newValue in
            reseedFromExternalMutation(newValue)
        }
    }

    /// Reseeds the edit models from an externally mutated clip value (m18-i).
    /// CANCEL-THEN-RESEED for an in-flight grid gesture: the drag parks in
    /// `.cancelled` (remaining ticks swallowed — no apply, no commit, no
    /// restart) and the models clear their own drag baselines (`reseed` doc
    /// comments), so stale gesture state never edits the new content.
    private func reseedFromExternalMutation(_ clip: Clip) {
        let notes = clip.notes ?? []
        let gridStale = model.needsReseed(notes: notes, clipLengthBeats: clip.lengthBeats)
        let stripStale = controllerModel.needsReseed(
            lanes: clip.controllerLanes, clipLengthBeats: clip.lengthBeats)
        guard gridStale || stripStale else { return }
        if activeDrag != .none {
            activeDrag = .cancelled
            didMove = false
        }
        if gridStale { model.reseed(notes: notes, clipLengthBeats: clip.lengthBeats) }
        if stripStale {
            controllerModel.reseed(lanes: clip.controllerLanes, clipLengthBeats: clip.lengthBeats)
        }
    }

    private func commit() { onCommit(model.buildSubmission()) }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "pianokeys")
                .font(.system(size: 12))
                .foregroundStyle(noteColor)
            Text(clip.name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textPrimary)
                .lineLimit(1)
            if clip.isAIGenerated {
                Text("AI")
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(DAWTheme.ai)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(DAWTheme.ai.opacity(0.6), lineWidth: 1))
            }

            Spacer()

            modeToggle
                .explainable(.panelDensity)   // shared density id (ex-b)
            // Zoom cluster (m21-c) — shown in BOTH densities (zoom is view
            // navigation, not Pro edit chrome — the arrange m17-b rationale).
            zoomCluster
                .explainable(.pianoRollZoom)
            if mode == .pro {
                snapPicker
                    .explainable(.pianoRollSnap)
            }
            quantizeChip
                .explainable(.quantize)
            barOpsCluster
                .explainable(.pianoRollBarOps)
            controllerLaneSummaryChip
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Passive Simple-density chip announcing the clip's controller lanes when it
    /// has any (m16-b4, the m15-c master-lane Pro-only precedent): data is never
    /// hidden, but EDITING controllers is a Pro surface — the full strip appears in
    /// Pro. NOT a button in v1 (no earned accent, Rule 3). Absent in Pro (the strip
    /// is shown instead) and when the clip has no lanes.
    @ViewBuilder
    private var controllerLaneSummaryChip: some View {
        if mode == .simple,
           let summary = ControllerStripModel.laneCountSummary(count: clip.controllerLanes.count) {
            HStack(spacing: 4) {
                Image(systemName: "dial.min")
                    .font(.system(size: 9, weight: .semibold))
                Text(summary)
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
            .help("This part has controller data (mod wheel, sustain, pitch bend). Switch to Pro to edit it.")
        }
    }

    // MARK: - Bar ops (insert / delete a measure, beta m10-h)

    /// Clip-local start beat of the target bar (under the playhead, else bar 0).
    private var targetBarStart: Double {
        PianoRollBarOps.targetBarStartBeat(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// One-based bar number the buttons act on — the SF Mono readout.
    private var targetBarNumber: Int {
        PianoRollBarOps.targetBarNumber(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// Delete is off when it would collapse the clip below one bar (invalid → off).
    private var canDeleteBar: Bool {
        PianoRollBarOps.canDeleteBar(lengthBeats: clip.lengthBeats, beatsPerBar: beatsPerBar)
    }

    /// The plain-language reason the delete-bar button can't act (≤ 1 bar left).
    private static let deleteBarBlockedReason =
        "This part is only one bar long — add a bar before deleting one."

    /// A compact glass cluster in the header: the target bar readout + insert/delete
    /// buttons (v1 acts on the bar under the playhead, or the first bar when the
    /// transport is elsewhere). Shown in BOTH densities — inserting/removing a
    /// measure is a structural edit a beginner reaches for, not Pro-only chrome.
    /// One bar = `beatsPerBar` beats (meter-aware). Dark glass + hairline, the
    /// snap-picker idiom; the +/− glyphs are neutral chrome (Rule 3 — an accent is
    /// earned by state, not by inviting a click). The delete button never goes
    /// dead (m21-c discoverability): when it can't act it stays dim but a press
    /// explains WHY inline (the m17-c refusal-bubble idiom) instead of silently
    /// swallowing the click — a tooltip alone proved undiscoverable.
    private var barOpsCluster: some View {
        HStack(spacing: 0) {
            Text("BAR \(targetBarNumber)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.playback)   // cyan = position readout
                .padding(.horizontal, 7)
            barOpsDivider
            barOpButton(system: "plus", enabled: true,
                        help: "Insert an empty bar at bar \(targetBarNumber), pushing later notes right") {
                insertBar()
            }
            barOpsDivider
            barOpButton(system: "minus", enabled: canDeleteBar,
                        help: canDeleteBar
                            ? "Delete bar \(targetBarNumber) and pull the rest of the part back to close the gap"
                            : Self.deleteBarBlockedReason) {
                if canDeleteBar {
                    deleteBar()
                } else {
                    flashBarOpsNotice(Self.deleteBarBlockedReason)
                }
            }
        }
        .frame(height: 22)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .overlay(alignment: .topTrailing) { barOpsNoticeBubble }
    }

    private var barOpsDivider: some View {
        Rectangle().fill(DAWTheme.hairline).frame(width: 1, height: 14)
    }

    /// A press on a can't-act bar op explains itself here (m21-c): the m17-c
    /// edit-refusal bubble — amber (nothing happened, nothing destroyed), SF Pro
    /// prose, soft warning glow — hung under the cluster, auto-clearing.
    @ViewBuilder
    private var barOpsNoticeBubble: some View {
        if let barOpsNotice {
            Text(barOpsNotice)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(DAWTheme.record)
                .multilineTextAlignment(.trailing)
                .frame(width: 240, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(DAWTheme.record.opacity(0.6), lineWidth: 1))
                .glow(DAWTheme.record, radius: 3, intensity: 0.3)
                .offset(y: 26)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    /// Shows the inline bar-ops reason for a few seconds, then fades it.
    private func flashBarOpsNotice(_ message: String) {
        barOpsNoticeTask?.cancel()
        withAnimation(.easeOut(duration: 0.15)) { barOpsNotice = message }
        barOpsNoticeTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { barOpsNotice = nil }
        }
    }

    private func barOpButton(system: String, enabled: Bool, help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(enabled ? DAWTheme.textPrimary : DAWTheme.textFaint)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        // Deliberately NOT `.disabled` (m21-c): the action itself refuses and
        // explains when it can't act, so the press is never silently dead; the
        // dim `textFaint` glyph still reads as "not available right now".
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Zoom (m21-c)

    /// The header's compact zoom cluster — the arrange toolbar's magnifier
    /// cluster (m17-b) at header-chip scale: −/+ steps around an SF Mono
    /// percent readout, neutral chrome (zoom is navigation, not an active
    /// state — Rule 3). Every driver mutates the ONE persisted
    /// `panelLayout.pianoRollPPB` slot (buttons here, pinch on the grid, and
    /// the View-menu ⌘+/⌘−/⌘0 while the editor is focused via the app router).
    private var zoomCluster: some View {
        HStack(spacing: 0) {
            zoomStepButton("minus.magnifyingglass", help: "Zoom the notes out (⌘− while the editor is focused)") {
                layout.setPianoRollPPB(PianoRollZoom.zoomedOut(layout.pianoRollPPB))
            }
            Text(PianoRollZoom.percentLabel(pixelsPerBeat: layout.pianoRollPPB))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 34)
                .help("Editor zoom — ⌘0 resets to 100% while the editor is focused")
            zoomStepButton("plus.magnifyingglass", help: "Zoom the notes in (⌘+ while the editor is focused)") {
                layout.setPianoRollPPB(PianoRollZoom.zoomedIn(layout.pianoRollPPB))
            }
        }
        .frame(height: 22)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    private func zoomStepButton(_ systemImage: String, help: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 6)
                .frame(height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    /// The live pinch (m21-c): magnification is cumulative, so every tick
    /// rescales off the gesture-START scale (the arrange `PinchState` rule).
    /// The roll's plain SwiftUI scroller keeps its own offset — no programmatic
    /// anchor re-pin here (the arrange lanes needed an AppKit bridge for that).
    private var gridPinch: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                if pinchStartPPB == nil { pinchStartPPB = layout.pianoRollPPB }
                guard let start = pinchStartPPB else { return }
                layout.setPianoRollPPB(PianoRollZoom.clamp(start * value.magnification))
            }
            .onEnded { _ in pinchStartPPB = nil }
    }

    /// Inserts one empty bar at the target bar start, then reseeds the edit model
    /// from the updated clip (the store closed/opened the gap — the model must
    /// re-read, not keep its stale draft).
    private func insertBar() {
        if let updated = onInsertTimeRange(targetBarStart, Double(beatsPerBar)) {
            model.load(notes: updated.notes ?? [], clipLengthBeats: updated.lengthBeats)
            // Clip-local bar edits leave controller lanes untouched (design-m16b
            // §14 A4) but change the clip length — reseed so the strip's drawn
            // width tracks.
            controllerModel.load(lanes: updated.controllerLanes, clipLengthBeats: updated.lengthBeats)
        }
    }

    /// Deletes the target bar and closes the gap, then reseeds the edit model.
    private func deleteBar() {
        if let updated = onDeleteTimeRange(targetBarStart, Double(beatsPerBar)) {
            model.load(notes: updated.notes ?? [], clipLengthBeats: updated.lengthBeats)
            controllerModel.load(lanes: updated.controllerLanes, clipLengthBeats: updated.lengthBeats)
        }
    }

    /// Opens the Quantize & Groove panel for this clip (m11-a). Neutral create-
    /// chrome (Rule 3 — `textPrimary`, no earned accent at rest); the snap-picker
    /// chip idiom, never a stock control.
    private var quantizeChip: some View {
        Button(action: onOpenQuantize) {
            HStack(spacing: 4) {
                Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                    .font(.system(size: 9, weight: .semibold))
                Text("QUANTIZE")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .tracking(0.6)
            }
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Tighten this part's timing to a grid, or apply a groove")
    }

    /// Simple / Pro segmented chip — the shared `SimpleProToggle` component bound
    /// to this panel's density (docs/DESIGN-LANGUAGE.md density modes).
    private var modeToggle: some View {
        SimpleProToggle(
            store: densityStore,
            panelID: Self.panelID,
            help: "Simple: add, move, delete on a beat grid. Pro: velocity, snap, resize."
        )
    }

    /// Themed snap menu (Pro only) — styled like the input-device picker chip,
    /// never a stock gray control (docs/DESIGN-LANGUAGE.md rule 2).
    private var snapPicker: some View {
        Menu {
            ForEach(SnapResolution.allCases, id: \.self) { resolution in
                Button {
                    snap = resolution
                } label: {
                    if snap == resolution {
                        Label(resolution.label, systemImage: "checkmark")
                    } else {
                        Text(resolution.label)
                    }
                }
            }
        } label: {
            Text("SNAP: \(snap.label)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Grid snap resolution")
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 22, height: 22)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
        .help("Close piano roll")
    }

    // MARK: - Editor (keyboard + grid), vertically scrolled together

    private var editor: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                KeyboardSidebar(model: model, width: Self.keyboardWidth)
                ScrollView(.horizontal, showsIndicators: true) {
                    // The grid Canvas is its own struct with closure-free, tick-stable
                    // inputs (model ref + beatsPerBar + snap + color), so a transport
                    // tick — which re-evaluates this body — never re-invokes its draw
                    // closure: only the playhead overlay's offset moves (the arrange
                    // "offset a view, never a per-frame Canvas redraw" rule, enforced
                    // here by extraction rather than trusting Canvas diffing).
                    PianoRollGrid(model: model, beatsPerBar: beatsPerBar,
                                  snap: effectiveSnap, noteColor: noteColor)
                        // Extended to the viewport at wide windows (m18-f): the
                        // Canvas draws the extension correctly by construction —
                        // key rows + gridlines run the full width and the
                        // out-of-clip shade covers everything past the clip end.
                        .frame(width: gridDrawnWidth, height: model.contentHeight)
                        // Playhead above the grid, below floating chrome; full grid
                        // height so it reads at any vertical scroll position.
                        .overlay(alignment: .topLeading) { gridPlayhead }
                        .background { gridScrollReader }
                        // Pointer affordances (docs/DESIGN-LANGUAGE.md): a note body
                        // grabs, its right-edge resize handle (Pro) resizes, empty
                        // grid keeps the arrow. Mirrors `gridDrag`'s hit routing.
                        .hoverCursor(resolve: gridCursor)
                        .gesture(gridDrag)
                        // Pinch-to-zoom (m21-c) — simultaneous so it never
                        // steals the drag/tap routing.
                        .simultaneousGesture(gridPinch)
                        .simultaneousGesture(
                            SpatialTapGesture(count: 2).onEnded { value in
                                let note = model.addNote(
                                    atBeat: model.beat(forX: value.location.x),
                                    pitch: model.pitch(forY: value.location.y),
                                    resolution: effectiveSnap
                                )
                                model.selectOnly(note.id)
                                commit()
                            }
                        )
                }
                .coordinateSpace(name: Self.gridScrollSpace)
            }
        }
        .defaultScrollAnchor(.center)   // open near middle C, full 0-127 scrollable
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Scrub strip: a frozen band pinned to the top of the VISIBLE grid (the
        // note grid vertical-scrolls under it), so it's always reachable — a drag
        // seeks the transport (m10-e). Sits over the grid area only, past the
        // keyboard gutter.
        .overlay(alignment: .topLeading) { scrubStrip }
    }

    /// The cyan transport playhead inside the grid content (beta m10-e). Same
    /// visual idiom as the arrange playhead — a glowing cyan hairline offset by
    /// `localBeat · pixelsPerBeat` — drawn ONLY while the transport is inside the
    /// edited clip (honest absence otherwise). Cyan is the active-state accent,
    /// never violet, even for an AI clip whose notes are violet (Rule 3).
    @ViewBuilder
    private var gridPlayhead: some View {
        if let x = PianoRollPlayhead.lineX(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat) {
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(width: 1.5, height: model.contentHeight)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    /// Reads the editor panel's full width for the m18-f band extension. A
    /// background (never hit-tested), updated only when the width actually
    /// changes — a window/splitter resize, never a playback tick.
    private var panelWidthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onChange(of: geo.size.width, initial: true) { _, newValue in
                    panelWidth = newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// Reads the grid content's leading x in the scroll viewport space → the live
    /// horizontal scroll offset. A background (behind the grid, never hit-tested),
    /// updated only when the offset actually changes.
    private var gridScrollReader: some View {
        GeometryReader { geo in
            let leadingX = geo.frame(in: .named(Self.gridScrollSpace)).minX
            Color.clear
                .onChange(of: leadingX, initial: true) { _, newValue in
                    gridScrollX = -newValue
                }
        }
        .allowsHitTesting(false)
    }

    /// The frozen scrub band: a transparent strip over the top of the grid (past
    /// the keyboard gutter) whose drag SEEKS the transport. Click jumps, drag
    /// scrubs continuously — free (unsnapped), the deliberate pro default. Works
    /// while playing and stopped (mid-play seek is supported engine behavior). The
    /// `resizeLeftRight` cursor advertises it (a horizontal position drag), held
    /// through the drag by `DragCursor` (docs/DESIGN-LANGUAGE.md pointer family).
    private var scrubStrip: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: Self.keyboardWidth)   // gutter — no scrub here
            Color.clear
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .hoverCursor(.resizeLeftRight)
                .gesture(scrubDrag)
                .help("Scrub — drag to move the playhead")
        }
        .frame(height: Self.scrubStripHeight)
    }

    private var scrubDrag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                DragCursor.set(.resizeLeftRight)
                // Strip-local x=0 is the grid's left edge (unscrolled); add the
                // live scroll offset to recover the content beat.
                let contentX = value.location.x + gridScrollX
                onSeek(PianoRollPlayhead.scrubProjectBeat(
                    localX: contentX, clipStartBeat: clip.startBeat,
                    lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat))
            }
            .onEnded { _ in DragCursor.clear() }
    }

    // MARK: - Grid gesture (move / resize / click-select)

    /// Rest cursor over the note grid: mirror the `gridDrag` hit routing so the
    /// hover cue matches what a press would do (a note body grabs, its Pro resize
    /// handle resizes, empty grid keeps the arrow — double-click-to-add doesn't
    /// warrant a crosshair on a single hover).
    private func gridCursor(at point: CGPoint) -> CursorKind? {
        guard let hit = model.hitTest(point) else { return nil }
        let zone: NoteZone = (hit.zone == .resizeHandle && mode == .pro) ? .resizeHandle : .body
        return CursorAffordance.forNoteZone(zone)
    }

    private var gridDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if activeDrag == .none {
                    beginGesture(at: value.startLocation)
                    didMove = false
                    // Hold the drag cursor for the whole gesture (grabbing while
                    // moving a note, resize while dragging its right edge).
                    switch activeDrag {
                    case .move: DragCursor.set(.grabbing)
                    case .resize: DragCursor.set(.resizeLeftRight)
                    case .click, .none, .cancelled: break
                    }
                }
                applyGesture(value)
            }
            .onEnded { value in
                endGesture(value)
                DragCursor.clear()
            }
    }

    private func beginGesture(at start: CGPoint) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        let hit = model.hitTest(start)
        if let hit, !shift, hit.zone == .resizeHandle, mode == .pro {
            if !model.isSelected(hit.id) { model.selectOnly(hit.id) }
            activeDrag = .resize(hit.id)
        } else if let hit, !shift {
            if !model.isSelected(hit.id) { model.selectOnly(hit.id) }
            model.beginMove()
            activeDrag = .move
        } else {
            activeDrag = .click(hit?.id)
        }
    }

    private func applyGesture(_ value: DragGesture.Value) {
        switch activeDrag {
        case .move:
            let deltaBeats = model.beat(forX: value.translation.width)
            let deltaPitch = -Int((value.translation.height / model.rowHeight).rounded())
            model.moveSelection(deltaBeats: deltaBeats, deltaPitch: deltaPitch, resolution: effectiveSnap)
            if abs(value.translation.width) > 3 || abs(value.translation.height) > 3 { didMove = true }
        case .resize(let id):
            model.resizeNote(id: id, toEndBeat: model.beat(forX: value.location.x), resolution: effectiveSnap)
            if abs(value.translation.width) > 3 { didMove = true }
        case .click, .none, .cancelled:
            break
        }
    }

    private func endGesture(_ value: DragGesture.Value) {
        switch activeDrag {
        case .move, .resize:
            if didMove { commit() }   // else it was a plain click; selection already set
        case .click(let id):
            let shift = NSEvent.modifierFlags.contains(.shift)
            if let id {
                if shift { model.toggle(id) } else { model.selectOnly(id) }
            } else if !shift {
                model.clearSelection()
            }
        case .none:
            break
        case .cancelled:
            break   // external reseed swallowed this gesture (m18-i) — no commit
        }
        activeDrag = .none
        didMove = false
    }

    // MARK: - Velocity lane (Pro)

    private var velocitySection: some View {
        HStack(alignment: .top, spacing: 0) {
            Text("VEL")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: Self.keyboardWidth, height: VelocityLane.height, alignment: .center)
            ScrollView(.horizontal, showsIndicators: false) {
                VelocityLane(model: model, noteColor: noteColor, onCommit: commit)
                    // Width-identical with the note grid (same beat→x space),
                    // so the m18-f viewport extension rides along.
                    .frame(width: gridDrawnWidth)
                    // The playhead continues through the velocity lane so the eye
                    // tracks it across both editors (m10-e). Same content x + scale
                    // as the grid, so it lines up.
                    .overlay(alignment: .topLeading) { velocityPlayhead }
            }
        }
        .frame(height: VelocityLane.height)
    }

    /// The playhead line inside the velocity lane content (beta m10-e) — same cyan
    /// glowing hairline as the grid, spanning the lane height.
    @ViewBuilder
    private var velocityPlayhead: some View {
        if let x = PianoRollPlayhead.lineX(
            position: positionBeats, clipStartBeat: clip.startBeat,
            lengthBeats: clip.lengthBeats, pixelsPerBeat: model.pixelsPerBeat) {
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(width: 1.5, height: VelocityLane.height)
                .glow(DAWTheme.playback, radius: 5, intensity: 0.7)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    // MARK: - Controller strip (Pro, m16-b4)

    /// The Pro controller strip directly under the velocity lane — bend, mod,
    /// sustain, expression, pressure, and any CC as a stepped value line. Thin over
    /// `ControllerStripModel`; commits through `onCommitControllerLane`.
    private var controllerSection: some View {
        ControllerLaneStrip(
            model: controllerModel,
            accent: noteColor,
            snap: effectiveSnap,
            drawnWidth: controllerDrawnWidth,
            onCommit: commitControllerLane
        )
    }

    /// Commits the visible controller lane and reseeds the strip model from the
    /// updated clip (canonicalized stored lanes; keeps chips + selection live).
    private func commitControllerLane() {
        guard let type = controllerModel.selectedType else { return }
        let points = controllerModel.buildSubmission()
        if let updated = onCommitControllerLane(type, points) {
            controllerModel.load(lanes: updated.controllerLanes, clipLengthBeats: updated.lengthBeats)
        }
    }
}

/// The piano-roll note grid (black-key rows, beat/bar lines, out-of-clip shade,
/// notes) as its own Canvas view. Extracted from `PianoRollView` so its inputs
/// are closure-free and tick-stable: a transport tick that re-evaluates the
/// parent leaves this value equal, so SwiftUI skips it and the draw closure never
/// re-runs on playback (only note/snap/color edits invalidate it). Redraw is
/// still per-interaction, never per-frame (docs/DESIGN-LANGUAGE.md "Meters").
private struct PianoRollGrid: View {
    var model: PianoRollModel
    var beatsPerBar: Int
    var snap: SnapResolution
    var noteColor: Color

    /// A value snapshot of everything the renderer needs, taken on the main actor
    /// before the closure runs. All fields are Sendable so the `@Sendable` Canvas
    /// closure captures only plain values — never `model` or `self` (CANVAS
    /// CONTRACT, m16-a; the pitch/beat mappings are affine and reproduced inline).
    private struct GridSnapshot {
        var rowHeight: CGFloat
        var pixelsPerBeat: CGFloat
        var clipLengthBeats: Double
        var draft: [MIDINote]
        var selectedIDs: Set<UUID>
        var beatsPerBar: Int
        var snapStep: Double
        var noteColor: Color
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let s = GridSnapshot(
            rowHeight: model.rowHeight,
            pixelsPerBeat: model.pixelsPerBeat,
            clipLengthBeats: model.clipLengthBeats,
            draft: model.draft,
            selectedIDs: model.selection,
            beatsPerBar: beatsPerBar,
            snapStep: snap.beats ?? 1,
            noteColor: noteColor)
        return Canvas { @Sendable context, size in
            Self.drawBlackKeyRows(&context, size: size, s: s)
            Self.drawGridLines(&context, size: size, s: s)
            Self.drawOutOfClipShade(&context, size: size, s: s)
            Self.drawNotes(&context, s: s)
        }
    }

    private nonisolated static func drawBlackKeyRows(_ context: inout GraphicsContext, size: CGSize, s: GridSnapshot) {
        for pitch in 0..<PianoRollModel.pitchCount where KeyboardSidebar.isBlackKey(pitch) {
            let y = CGFloat(PianoRollModel.pitchCount - 1 - pitch) * s.rowHeight
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: s.rowHeight)),
                with: .color(Color.black.opacity(0.22))
            )
        }
        // Octave separators.
        for pitch in stride(from: 0, through: PianoRollModel.pitchCount - 1, by: 12) {
            let y = CGFloat(PianoRollModel.pitchCount - 1 - pitch) * s.rowHeight
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                with: .color(Color.white.opacity(0.10))
            )
        }
    }

    /// Grid lines follow the snap, density-adapted to the zoom (m21-c): bar
    /// lines (`gridEmphasis`) and beat lines (`hairline`) always draw — the
    /// survey grid — while SUB-beat division hairlines fade with zoom
    /// (`PianoRollZoom.subBeatLineAlpha`) so a 1/64 or triplet grid appears
    /// only once it has room to be useful, never as visual soup (the arrange
    /// m17-b "grid density adapts, never forks" rule). Division x positions
    /// are exact rationals (`beat + d/divisions`), so triplet lines never
    /// accumulate float drift; when the fade bottoms out the sub-division loop
    /// is skipped entirely (no invisible-line work).
    private nonisolated static func drawGridLines(_ context: inout GraphicsContext, size: CGSize, s: GridSnapshot) {
        let beatsShown = Int((size.width / s.pixelsPerBeat).rounded(.up))
        let step = s.snapStep
        let barStride = max(1, s.beatsPerBar)
        // Coarser-than-beat snaps (Bar) keep drawing only their own lines —
        // the pre-zoom behavior.
        if step >= 1 {
            let stride = max(1, Int(step.rounded()))
            var b = 0
            while b <= beatsShown {
                let x = CGFloat(b) * s.pixelsPerBeat
                let color = b % barStride == 0 ? DAWTheme.gridEmphasis : DAWTheme.hairline
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
                b += stride
            }
            return
        }
        let divisions = PianoRollZoom.divisionsPerBeat(step: step)
        let alpha = PianoRollZoom.subBeatLineAlpha(step: step, pixelsPerBeat: s.pixelsPerBeat)
        let subColor = DAWTheme.hairline.opacity(0.5 * alpha)
        for b in 0...beatsShown {
            let x = CGFloat(b) * s.pixelsPerBeat
            let color = b % barStride == 0 ? DAWTheme.gridEmphasis : DAWTheme.hairline
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
            guard alpha > 0, b < beatsShown, divisions > 1 else { continue }
            for d in 1..<divisions {
                let dx = (CGFloat(b) + CGFloat(d) / CGFloat(divisions)) * s.pixelsPerBeat
                context.fill(Path(CGRect(x: dx, y: 0, width: 1, height: size.height)), with: .color(subColor))
            }
        }
    }

    private nonisolated static func drawOutOfClipShade(_ context: inout GraphicsContext, size: CGSize, s: GridSnapshot) {
        let clipX = CGFloat(s.clipLengthBeats) * s.pixelsPerBeat
        guard clipX < size.width else { return }
        context.fill(
            Path(CGRect(x: clipX, y: 0, width: size.width - clipX, height: size.height)),
            with: .color(Color.black.opacity(0.28))
        )
        // 1 pt neutral clip-end hairline (m19-g — the m18-e CTRL-strip boundary
        // grammar, now in all three bands at the same x): the latent region
        // reads as a deliberate boundary, not a rendering seam. gridEmphasis is
        // the grid's own bar-line chrome — no accent, no glow (a boundary is
        // chrome, not state). Drawn over the shade; where the clip end lands on
        // a bar line the two same-color lines merge — never a second visible
        // hairline.
        context.fill(
            Path(CGRect(x: clipX - 0.5, y: 0, width: 1, height: size.height)),
            with: .color(DAWTheme.gridEmphasis)
        )
    }

    /// Note pills, split at the clip boundary (m19-g ghost treatment —
    /// DESIGN-LANGUAGE "Controller strips"): a note whose onset the engine
    /// plays takes the full neon treatment; latent data — an onset at/past the
    /// clip end, or the truncated tail of a note crossing it — draws as a dim
    /// flat core with NO bloom (glow is earned; inert data earns none, the
    /// m18-e ghost grammar). The split comes from the model's engine-honest
    /// `playableEndBeat` — ONE boundary definition, never view beat math.
    private nonisolated static func drawNotes(_ context: inout GraphicsContext, s: GridSnapshot) {
        for note in s.draft {
            let rect = CGRect(
                x: CGFloat(note.startBeat) * s.pixelsPerBeat,
                y: CGFloat(PianoRollModel.pitchCount - 1 - note.pitch) * s.rowHeight,
                width: max(3, CGFloat(note.lengthBeats) * s.pixelsPerBeat),
                height: s.rowHeight
            ).insetBy(dx: 0.5, dy: 1.5)
            let selected = s.selectedIDs.contains(note.id)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            guard let playableEnd = PianoRollModel.playableEndBeat(
                of: note, clipLengthBeats: s.clipLengthBeats) else {
                // Onset at/past the clip end — the engine never sounds it.
                drawGhostPill(&context, path: path, selected: selected, s: s)
                continue
            }
            if playableEnd >= note.endBeat {
                drawLitPill(&context, rect: rect, path: path, note: note, selected: selected, s: s)
            } else {
                // Partial overhang: the engine truncates the note-off at the
                // clip end (`min(endBeat, clipLength)`), so the body is lit to
                // the boundary and the silent tail ghosts past it. Clipped
                // copies of the context split the one rounded pill at exactly
                // the boundary x (the bloom stays inside the lit side — glow
                // never spills into latent space).
                let boundaryX = CGFloat(playableEnd) * s.pixelsPerBeat
                let pad: CGFloat = 4
                var lit = context
                lit.clip(to: Path(CGRect(x: rect.minX - pad, y: rect.minY - pad,
                                         width: boundaryX - (rect.minX - pad),
                                         height: rect.height + pad * 2)))
                drawLitPill(&lit, rect: rect, path: path, note: note, selected: selected, s: s)
                var ghost = context
                ghost.clip(to: Path(CGRect(x: boundaryX, y: rect.minY - pad,
                                           width: (rect.maxX + pad) - boundaryX,
                                           height: rect.height + pad * 2)))
                drawGhostPill(&ghost, path: path, selected: selected, s: s)
            }
        }
    }

    /// The full neon pill treatment (unchanged from pre-m19-g): velocity →
    /// fill opacity, selected = brighter + hairline + subtle bloom.
    private nonisolated static func drawLitPill(_ context: inout GraphicsContext, rect: CGRect, path: Path,
                                                note: MIDINote, selected: Bool, s: GridSnapshot) {
        let velocity = Double(note.velocity) / 127
        let opacity = 0.45 + 0.5 * velocity
        if selected {
            // Subtle bloom behind a selected note.
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
                with: .color(s.noteColor.opacity(0.28))
            )
        }
        context.fill(path, with: .color(s.noteColor.opacity(selected ? min(1, opacity + 0.2) : opacity)))
        context.stroke(
            path,
            with: .color(selected ? DAWTheme.textPrimary.opacity(0.9) : s.noteColor.opacity(0.9)),
            lineWidth: selected ? 1 : 0.5
        )
    }

    /// The m19-g ghost pill: a flat dim core (fill 0.35 / hairline 0.45 — the
    /// m18-e ghost-handle ratios) with velocity NO LONGER modulating opacity
    /// (latent data reads uniformly inert). Selection keeps its neutral
    /// hairline stroke — a selected ghost must still read selected (editing is
    /// boundary-blind) — but never the bloom: no glow layers on latent data.
    private nonisolated static func drawGhostPill(_ context: inout GraphicsContext, path: Path,
                                                  selected: Bool, s: GridSnapshot) {
        context.fill(path, with: .color(s.noteColor.opacity(0.35)))
        context.stroke(
            path,
            with: .color(selected ? DAWTheme.textPrimary.opacity(0.9) : s.noteColor.opacity(0.45)),
            lineWidth: selected ? 1 : 0.5
        )
    }
}
