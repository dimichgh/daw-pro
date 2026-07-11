import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Canvas breakpoint editor for one automation lane, horizontally aligned with
/// the clip timeline (same beat→x mapping). Thin over the headless
/// `AutomationGeometry` / `AutomationEdit`: it draws a neon polyline with glowing
/// breakpoints and routes gestures, holding a local `draft` array that it submits
/// through `onCommit` (wired to `ProjectStore.setAutomationPoints`, whole-array
/// replace). The store canonicalizes + clamps, so the editor re-reads the
/// canonical points after each gesture rather than assuming its own order.
///
/// Interactions (docs/DESIGN-LANGUAGE.md "Glass Cockpit"):
///  - click empty space = add a breakpoint at that beat/value (then drag it),
///  - drag a breakpoint = move it, with a live value/beat readout by the cursor,
///  - double-click a breakpoint (or select + ⌫) = delete,
///  - a disabled lane renders dimmed (its curve is inert until re-enabled).
struct AutomationLaneEditor: View {
    /// The lane being edited (value input — previewable without the store).
    var lane: AutomationLane
    /// The v0 param this lane drives (volume/pan) — drives color + readout.
    var param: AutomationParam
    var geometry: AutomationGeometry
    /// Drawn width — the timeline's content width, so the lane spans the ruler.
    var contentWidth: CGFloat
    /// Submits the whole point array (wired to `setAutomationPoints`).
    var onCommit: ([AutomationPoint]) -> Void

    /// Local working copy. Every interaction mutates this; it is submitted on
    /// each change and re-seeded from the canonical lane when a gesture ends.
    @State private var draft: [AutomationPoint]
    @State private var drag: DragState = .idle
    @State private var selection: Int?
    /// Cursor readout during a drag: content-space position + formatted text.
    @State private var readout: Readout?
    @FocusState private var focused: Bool

    init(lane: AutomationLane, param: AutomationParam, geometry: AutomationGeometry,
         contentWidth: CGFloat, onCommit: @escaping ([AutomationPoint]) -> Void) {
        self.lane = lane
        self.param = param
        self.geometry = geometry
        self.contentWidth = contentWidth
        self.onCommit = onCommit
        _draft = State(initialValue: lane.points)
    }

    private enum DragState: Equatable {
        case idle
        case moving(Int)   // dragging the breakpoint at this draft index
    }

    private struct Readout: Equatable {
        var position: CGPoint
        var text: String
    }

    /// Volume tracks the fader's cyan; pan stays neutral white (the mixer's
    /// semantics — pan claims no accent). A disabled lane dims to a muted slate.
    private var accent: Color {
        guard lane.isEnabled else { return DAWTheme.textDim }
        switch param {
        case .volume: return DAWTheme.playback
        case .pan: return DAWTheme.textPrimary
        }
    }

    var body: some View {
        canvas
            .frame(width: contentWidth, height: geometry.laneHeight)
            .contentShape(Rectangle())
            // Pointer affordances (docs/DESIGN-LANGUAGE.md): a breakpoint grabs;
            // empty space is a crosshair (click to place a point there).
            .hoverCursor(resolve: pointCursor)
            .gesture(pointDrag)
            .simultaneousGesture(doubleClickDelete)
            .overlay(alignment: .topLeading) { readoutBubble }
            .focusable()
            .focused($focused)
            .onKeyPress(.delete, action: deleteSelection)
            // Re-seed from the canonical lane whenever it changes outside a drag
            // (undo, an agent edit, or our own committed gesture landing sorted).
            .onChange(of: lane.points) { _, points in
                if drag == .idle { draft = points; selection = nil }
            }
    }

    // MARK: - Drawing

    private var canvas: some View {
        Canvas { context, size in
            drawBackground(&context, size: size)
            drawGuideLine(&context, size: size)
            drawPolyline(&context, size: size)
            drawBreakpoints(&context)
        }
    }

    private func drawBackground(_ context: inout GraphicsContext, size: CGSize) {
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(DAWTheme.background.opacity(lane.isEnabled ? 0.45 : 0.30))
        )
        // Hairline top edge separating the lane from the clip row above it.
        context.fill(
            Path(CGRect(x: 0, y: 0, width: size.width, height: 1)),
            with: .color(DAWTheme.hairline)
        )
    }

    /// The neutral resting line (unity gain / center pan) — a faint dashed guide.
    private func drawGuideLine(_ context: inout GraphicsContext, size: CGSize) {
        let y = geometry.y(forValue: param.neutralValue)
        context.stroke(
            Path { $0.move(to: CGPoint(x: 0, y: y)); $0.addLine(to: CGPoint(x: size.width, y: y)) },
            with: .color(DAWTheme.textDim.opacity(0.25)),
            style: StrokeStyle(lineWidth: 1, dash: [3, 4])
        )
    }

    /// Neon polyline: flat lead-in from the left edge to the first point, linear
    /// segments between points, flat lead-out to the right edge (matching
    /// `AutomationLane.value(atBeat:)`). Drawn bloom-under-core for the glow
    /// recipe. An empty lane draws a flat line at the neutral value.
    private func drawPolyline(_ context: inout GraphicsContext, size: CGSize) {
        let sorted = AutomationLane.canonicalize(draft)
        var line = Path()
        if let first = sorted.first {
            let firstPoint = geometry.point(for: first)
            line.move(to: CGPoint(x: 0, y: firstPoint.y))
            line.addLine(to: firstPoint)
            for point in sorted.dropFirst() {
                line.addLine(to: geometry.point(for: point))
            }
            if let last = sorted.last {
                let lastPoint = geometry.point(for: last)
                line.addLine(to: CGPoint(x: size.width, y: lastPoint.y))
            }
        } else {
            // Empty lane: a flat neutral line (inert but shows the target level).
            let y = geometry.y(forValue: param.neutralValue)
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: size.width, y: y))
        }
        let bright = lane.isEnabled ? 1.0 : 0.4
        // Wide faint bloom first, then the bright core.
        context.stroke(line, with: .color(accent.opacity(0.18 * bright)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        context.stroke(line, with: .color(accent.opacity(0.9 * bright)),
                       style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
    }

    /// Glowing breakpoint dots (faint disc + bright core), the selected one ringed.
    private func drawBreakpoints(_ context: inout GraphicsContext) {
        let bright = lane.isEnabled ? 1.0 : 0.45
        for (index, point) in draft.enumerated() {
            let p = geometry.point(for: point)
            let isSelected = selection == index
            // Bloom.
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)),
                with: .color(accent.opacity(0.22 * bright))
            )
            // Core.
            context.fill(
                Path(ellipseIn: CGRect(x: p.x - 3.5, y: p.y - 3.5, width: 7, height: 7)),
                with: .color(accent.opacity(bright))
            )
            if isSelected {
                context.stroke(
                    Path(ellipseIn: CGRect(x: p.x - 6, y: p.y - 6, width: 12, height: 12)),
                    with: .color(DAWTheme.textPrimary.opacity(0.9)),
                    lineWidth: 1.5
                )
            }
        }
    }

    // MARK: - Readout bubble

    @ViewBuilder
    private var readoutBubble: some View {
        if let readout {
            Text(readout.text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(param == .pan ? DAWTheme.textPrimary : DAWTheme.playback)
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(DAWTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
                .glow(param == .pan ? DAWTheme.textPrimary : DAWTheme.playback, radius: 4, intensity: 0.35)
                .fixedSize()
                // Sit just above the dragged point, clamped into the lane.
                .offset(
                    x: min(max(readout.position.x - 26, 0), max(0, contentWidth - 70)),
                    y: max(0, readout.position.y - 26)
                )
                .allowsHitTesting(false)
        }
    }

    // MARK: - Gestures

    /// Rest cursor: grab over an existing breakpoint (it's movable), crosshair over
    /// empty space (a click there ADDS a point — the place/paint family).
    private func pointCursor(at location: CGPoint) -> CursorKind? {
        geometry.hitTest(location, points: draft) != nil
            ? CursorAffordance.automationPoint.restCursor
            : CursorAffordance.automationField.restCursor
    }

    private var pointDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if drag == .idle {
                    beginDrag(at: value.startLocation)
                    // Either grabbed a point or added one — both MOVE a point now.
                    DragCursor.set(.grabbing)
                }
                applyDrag(to: value.location)
            }
            .onEnded { _ in endDrag(); DragCursor.clear() }
    }

    /// Double-click a breakpoint to delete it (the drag gesture treats the same
    /// presses as a no-move selection — harmless).
    private var doubleClickDelete: some Gesture {
        SpatialTapGesture(count: 2)
            .onEnded { value in
                guard let index = geometry.hitTest(value.location, points: draft) else { return }
                commit(AutomationEdit.removePoint(draft, index: index))
                selection = nil
            }
    }

    private func beginDrag(at start: CGPoint) {
        focused = true
        if let index = geometry.hitTest(start, points: draft) {
            // Grabbed an existing breakpoint — move it.
            selection = index
            drag = .moving(index)
        } else {
            // Empty space — add a breakpoint here and drag it (click = add).
            let beat = geometry.beat(forX: start.x)
            let value = geometry.value(forY: start.y)
            let added = AutomationEdit.addPoint(draft, atBeat: beat, value: value, in: geometry.range)
            let index = added.count - 1
            draft = added
            selection = index
            drag = .moving(index)
            onCommit(added)
            setReadout(at: start, beat: beat, value: value)
        }
    }

    private func applyDrag(to location: CGPoint) {
        guard case .moving(let index) = drag, draft.indices.contains(index) else { return }
        let beat = geometry.beat(forX: location.x)
        let value = geometry.value(forY: location.y)
        let moved = AutomationEdit.movePoint(draft, index: index, toBeat: beat, value: value, in: geometry.range)
        draft = moved
        onCommit(moved)
        setReadout(at: geometry.point(for: moved[index]), beat: beat, value: value)
    }

    private func endDrag() {
        drag = .idle
        readout = nil
        // A final commit lands sorted; onChange(lane.points) re-seeds the draft.
        onCommit(draft)
    }

    private func deleteSelection() -> KeyPress.Result {
        guard let index = selection, draft.indices.contains(index) else { return .ignored }
        commit(AutomationEdit.removePoint(draft, index: index))
        selection = nil
        return .handled
    }

    /// Applies a discrete (non-drag) edit: update the draft and submit it.
    private func commit(_ points: [AutomationPoint]) {
        draft = points
        onCommit(points)
    }

    private func setReadout(at position: CGPoint, beat: Double, value: Double) {
        readout = Readout(position: position, text: param.readout(value))
    }
}
