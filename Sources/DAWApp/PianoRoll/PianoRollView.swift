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
    /// Submits the whole note array (wired to `ProjectStore.setClipNotes`).
    var onCommit: ([MIDINote]) -> Void
    /// Seeks the transport to a PROJECT beat (wired to `ProjectStore.seek`) — the
    /// scrub's only side effect. Kept a closure so the view stays store-free and
    /// previewable (the `onCommit` precedent).
    var onSeek: (Double) -> Void
    var onClose: () -> Void

    @State private var model: PianoRollModel
    @State private var snap: SnapResolution = .beat
    @State private var activeDrag: ActiveDrag = .none
    @State private var didMove = false
    /// Live horizontal-scroll offset of the note grid, read from the grid's
    /// content geometry so the frozen scrub strip above the grid maps its local x
    /// back to a content beat even when the grid is scrolled. Only changes on a
    /// horizontal scroll (never on a transport tick), so it stays off the playback
    /// redraw path.
    @State private var gridScrollX: CGFloat = 0
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
         onCommit: @escaping ([MIDINote]) -> Void, onSeek: @escaping (Double) -> Void,
         onClose: @escaping () -> Void) {
        self.clip = clip
        self.beatsPerBar = beatsPerBar
        self.positionBeats = positionBeats
        self.densityStore = densityStore
        self.onCommit = onCommit
        self.onSeek = onSeek
        self.onClose = onClose
        _model = State(initialValue: PianoRollModel(
            notes: clip.notes ?? [],
            clipLengthBeats: clip.lengthBeats
        ))
    }

    /// The panel's live density (Simple default), read from the shared store.
    private var mode: PanelDensity { densityStore.density(forPanel: Self.panelID) }

    /// Simple mode locks snapping to whole beats; Pro honors the picker.
    private var effectiveSnap: SnapResolution { mode == .simple ? .beat : snap }

    /// Violet whenever the clip is AI-touched, else playback cyan.
    private var noteColor: Color { clip.isAIGenerated ? DAWTheme.ai : DAWTheme.playback }

    private enum ActiveDrag: Equatable {
        case none
        case click(UUID?)     // shift-click or empty — resolved on drag end
        case move
        case resize(UUID)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(DAWTheme.hairline)
            editor
                .explainable(.pianoRollGrid)
            if mode == .pro {
                Divider().overlay(DAWTheme.hairline)
                velocitySection
                    .explainable(.pianoRollVelocity)
            }
        }
        .glassPanel()
        .focusable()
        .focused($isFocused)
        .onKeyPress(.delete) {
            guard !model.selection.isEmpty else { return .ignored }
            model.deleteSelection()
            commit()
            return .handled
        }
        .onAppear { isFocused = true }
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
            if mode == .pro {
                snapPicker
                    .explainable(.pianoRollSnap)
            }
            closeButton
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
                        .frame(width: model.contentWidth, height: model.contentHeight)
                        // Playhead above the grid, below floating chrome; full grid
                        // height so it reads at any vertical scroll position.
                        .overlay(alignment: .topLeading) { gridPlayhead }
                        .background { gridScrollReader }
                        // Pointer affordances (docs/DESIGN-LANGUAGE.md): a note body
                        // grabs, its right-edge resize handle (Pro) resizes, empty
                        // grid keeps the arrow. Mirrors `gridDrag`'s hit routing.
                        .hoverCursor(resolve: gridCursor)
                        .gesture(gridDrag)
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
                    case .click, .none: break
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
        case .click, .none:
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
                    .frame(width: model.contentWidth)
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

    var body: some View {
        Canvas { context, size in
            drawBlackKeyRows(&context, size: size)
            drawGridLines(&context, size: size)
            drawOutOfClipShade(&context, size: size)
            drawNotes(&context)
        }
    }

    private func drawBlackKeyRows(_ context: inout GraphicsContext, size: CGSize) {
        for pitch in 0..<PianoRollModel.pitchCount where KeyboardSidebar.isBlackKey(pitch) {
            let y = model.y(forPitch: pitch)
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: model.rowHeight)),
                with: .color(Color.black.opacity(0.22))
            )
        }
        // Octave separators.
        for pitch in stride(from: 0, through: PianoRollModel.pitchCount - 1, by: 12) {
            let y = model.y(forPitch: pitch)
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                with: .color(Color.white.opacity(0.10))
            )
        }
    }

    private func drawGridLines(_ context: inout GraphicsContext, size: CGSize) {
        let beatsShown = Int((size.width / model.pixelsPerBeat).rounded(.up))
        let step = snap.beats ?? 1
        var beat = 0.0
        while beat <= Double(beatsShown) + 0.0001 {
            let x = model.x(forBeat: beat)
            let isBar = beat.truncatingRemainder(dividingBy: Double(beatsPerBar)).magnitude < 0.001
            let isBeat = beat.truncatingRemainder(dividingBy: 1).magnitude < 0.001
            let color = isBar
                ? DAWTheme.gridEmphasis
                : (isBeat ? DAWTheme.hairline : DAWTheme.hairline.opacity(0.5))
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(color))
            beat += step
        }
    }

    private func drawOutOfClipShade(_ context: inout GraphicsContext, size: CGSize) {
        let clipX = model.x(forBeat: model.clipLengthBeats)
        guard clipX < size.width else { return }
        context.fill(
            Path(CGRect(x: clipX, y: 0, width: size.width - clipX, height: size.height)),
            with: .color(Color.black.opacity(0.28))
        )
    }

    private func drawNotes(_ context: inout GraphicsContext) {
        for note in model.draft {
            let rect = model.rect(for: note).insetBy(dx: 0.5, dy: 1.5)
            let selected = model.isSelected(note.id)
            let velocity = Double(note.velocity) / 127
            let opacity = 0.45 + 0.5 * velocity
            let path = Path(roundedRect: rect, cornerRadius: 3)
            if selected {
                // Subtle bloom behind a selected note.
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
                    with: .color(noteColor.opacity(0.28))
                )
            }
            context.fill(path, with: .color(noteColor.opacity(selected ? min(1, opacity + 0.2) : opacity)))
            context.stroke(
                path,
                with: .color(selected ? DAWTheme.textPrimary.opacity(0.9) : noteColor.opacity(0.9)),
                lineWidth: selected ? 1 : 0.5
            )
        }
    }
}
