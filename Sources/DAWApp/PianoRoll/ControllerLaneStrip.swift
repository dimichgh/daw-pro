import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Pro-mode CONTROLLER STRIP (m16-b4): a collapsible strip directly under the
/// velocity lane that edits ONE MIDI controller lane at a time — pitch bend, mod
/// wheel, sustain, expression, pressure, or any CC — drawn as a STEPPED value
/// line (hold-until-next, never interpolated) with draggable point handles. A
/// chip row on top selects the visible lane; a "+" menu adds one. Thin over the
/// headless `ControllerStripModel`: all geometry + edits live there, this draws
/// (Canvas) and routes gestures. Edits mutate the model draft live; `onCommit`
/// fires on gesture END only (the whole-array submit contract, one undo).
struct ControllerLaneStrip: View {
    var model: ControllerStripModel
    /// The clip's accent (violet for AI clips, else cyan) — the note/velocity tint.
    var accent: Color
    /// Grid snap for pencil ticks (shares the piano roll's resolution).
    var snap: SnapResolution
    /// Drawn canvas width — the model's content width, extended to the editor
    /// viewport at wide windows (m18-f, DESIGN-LANGUAGE "Wide windows"). The
    /// parent computes it via the shared `PianoRollModel.drawnWidth` rule so all
    /// three editor bands extend identically; a plain value input keeps the
    /// strip previewable. The canvas already draws the extension honestly —
    /// shade + boundary hairline + ghost hold-line run to `size.width` (m18-e).
    var drawnWidth: CGFloat
    /// Commits the visible lane through `ProjectStore.setControllerLane` (the wire
    /// verb's store call) and reseeds the model from the returned clip.
    var onCommit: () -> Void

    static let height: CGFloat = ControllerStripModel.laneHeight   // 72 pt
    /// The three vertical bands (chip row + divider + value canvas) sum EXACTLY to
    /// `height` — a clean 72 pt total, no sub-pixel clip. One source of truth with
    /// the model, which also maps VALUE↔y over `canvasHeight` so drawn handles land
    /// where clicks do.
    private static let chipRowHeight = ControllerStripModel.chipRowHeight   // 24
    private static let dividerHeight = ControllerStripModel.dividerHeight   // 1
    private static let canvasHeight = ControllerStripModel.canvasHeight     // 47
    private static let sidebarWidth: CGFloat = 54

    @State private var stripExpanded = true
    @State private var phase: GesturePhase = .idle
    @State private var didEdit = false
    @State private var showOtherCCEntry = false
    @State private var otherCCText = ""
    @FocusState private var otherCCFocused: Bool

    private enum GesturePhase { case idle, pencil, dragPoint, deleted }

    var body: some View {
        VStack(spacing: 0) {
            chipRow
            if stripExpanded {
                Rectangle().fill(DAWTheme.hairline).frame(height: Self.dividerHeight)
                laneBody
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel("Controller lane strip")
    }

    // MARK: - Chip row (lane selection + add)

    private var chipRow: some View {
        HStack(spacing: 6) {
            disclosure
            ForEach(model.laneChips) { chip in
                laneChip(chip)
            }
            pendingChip
            addMenu
            Spacer(minLength: 0)
            if let type = model.selectedType {
                valueReadout(type: type)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: Self.chipRowHeight)
    }

    /// Combined disclosure: the chevron + the "CTRL" section label as ONE hit target
    /// (a lone chevron reads as chrome, not a control — the design-language polish
    /// the phase-1 note asked for). No rest background — it is a section label, not a
    /// chip; the standard button hover brightens it.
    private var disclosure: some View {
        Button {
            stripExpanded.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: stripExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                Text("CTRL")
                    .font(.system(size: 8, weight: .semibold, design: .monospaced))
                    .tracking(1)
            }
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 5)
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(stripExpanded ? "Collapse the controller strip" : "Expand the controller strip")
    }

    /// A staged-but-uncommitted lane (picked from "+", not yet drawn) shows a chip
    /// IMMEDIATELY in a distinct PENDING style — accent-lit like the visible
    /// selection it is, but with a dashed border + faint fill so it reads as "not
    /// saved until you draw a point." Absent once the type becomes a real lane (then
    /// `laneChip` renders it) or when nothing is staged.
    @ViewBuilder
    private var pendingChip: some View {
        if let sel = model.selectedType,
           !model.laneChips.contains(where: { $0.type == sel }) {
            Text(ControllerStripModel.label(for: sel))
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(accent)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(accent.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(accent.opacity(0.7), style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
                .help("New \(ControllerStripModel.label(for: sel)) lane — draw a point to add it")
        }
    }

    private func laneChip(_ chip: ControllerStripModel.LaneChip) -> some View {
        let selected = model.selectedType == chip.type
        return Button {
            model.select(type: chip.type)
        } label: {
            Text(chip.label)
                .font(.system(size: 9, weight: .medium, design: .monospaced))
                .foregroundStyle(selected ? accent : DAWTheme.textDim)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(selected ? accent.opacity(0.16) : DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(selected ? accent.opacity(0.6) : DAWTheme.hairline, lineWidth: 1))
                // Selected = earned active state → a soft accent glow (Rule 3);
                // clear/0 is an invisible no-op when unselected.
                .glow(selected ? accent : .clear, radius: 4, intensity: selected ? 0.4 : 0)
        }
        .buttonStyle(.plain)
        .help("Edit the \(chip.label) lane")
    }

    private var addMenu: some View {
        Menu {
            ForEach(ControllerStripModel.addMenuItems) { item in
                switch item {
                case .type(let type, let label):
                    Button(label) { model.select(type: type) }
                case .otherCC:
                    Button("Other CC…") { showOtherCCEntry = true }
                }
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DAWTheme.textPrimary)
                .frame(width: 20, height: 18)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Add a controller lane — bend, mod wheel, sustain, expression, or any CC")
        .popover(isPresented: $showOtherCCEntry, arrowEdge: .bottom) { otherCCPopover }
    }

    /// The current draft parsed to a legal CC number (0–127), else nil — gates the
    /// ADD chip's lit state (an earned active state, Rule 3).
    private var otherCCValue: Int? {
        guard let n = Int(otherCCText.trimmingCharacters(in: .whitespaces)), (0...127).contains(n) else { return nil }
        return n
    }

    /// Numeric entry for an arbitrary CC number (design-m16b §9 "Other CC…"), styled
    /// to the glass cockpit: a dark card, an SF Mono field with a cyan focus border,
    /// and an ADD chip that lights cyan only once the number is valid.
    private var otherCCPopover: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("CONTROLLER NUMBER")
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .tracking(1)
                .foregroundStyle(DAWTheme.textDim)
            Text("Any CC 0–127 (1 = mod wheel, 64 = sustain).")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                TextField("0–127", text: $otherCCText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .focused($otherCCFocused)
                    .frame(width: 66)
                    .padding(.horizontal, 8)
                    .frame(height: 26)
                    .background(DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                        otherCCFocused ? DAWTheme.playback.opacity(0.8) : DAWTheme.hairline, lineWidth: 1))
                    .onSubmit { addOtherCC() }
                Button(action: addOtherCC) {
                    Text("ADD")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(otherCCValue != nil ? DAWTheme.playback : DAWTheme.textFaint)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background((otherCCValue != nil ? DAWTheme.playback : DAWTheme.textFaint).opacity(0.14))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(
                            (otherCCValue != nil ? DAWTheme.playback : DAWTheme.hairline).opacity(0.6), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(otherCCValue == nil)
            }
        }
        .padding(14)
        .frame(width: 224)
        .background(DAWTheme.panel)
        .onAppear { otherCCFocused = true }
    }

    private func addOtherCC() {
        if let n = otherCCValue {
            model.select(type: .cc(controller: n))
        }
        otherCCText = ""
        showOtherCCEntry = false
    }

    /// SF Mono live value of the visible lane at its last point (the numeric-
    /// readout rule — DESIGN-LANGUAGE "SF Mono for numeric readouts"). The dim
    /// lane label rides along (m17-f F3): the readout is trailing-pinned, so at a
    /// wide window a BARE number floats over a thousand points from the lane it
    /// describes and reads as stray debris — labeled, it reads as a readout.
    @ViewBuilder
    private func valueReadout(type: MIDIControllerType) -> some View {
        let value = model.draft.max(by: { $0.beat < $1.beat })?.value
        if let value {
            HStack(spacing: 4) {
                Text(ControllerStripModel.label(for: type))
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
                Text("\(value)")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .glow(accent, radius: 4, intensity: 0.45)
            }
        }
    }

    // MARK: - Lane body (sidebar label + canvas)

    private var laneBody: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebarLabel
            ScrollView(.horizontal, showsIndicators: false) {
                ControllerLaneCanvas(model: model, accent: accent)
                    .frame(width: max(drawnWidth, model.contentWidth), height: Self.canvasHeight)
                    .contentShape(Rectangle())
                    .hoverCursor(resolve: laneCursor)
                    .gesture(laneDrag)
            }
        }
        .frame(height: Self.canvasHeight)
    }

    private var sidebarLabel: some View {
        Text(model.selectedType.map { ControllerStripModel.label(for: $0) } ?? "—")
            .font(.system(size: 8, weight: .semibold, design: .monospaced))
            .foregroundStyle(DAWTheme.textDim)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(width: Self.sidebarWidth, height: Self.canvasHeight)
    }

    /// Point cursor over a handle (the automation-point grab family), field cursor
    /// (click adds a point) over empty — the automation-lane cursor precedent.
    private func laneCursor(at point: CGPoint) -> CursorKind? {
        guard model.selectedType != nil else { return nil }
        return model.hitTest(point) != nil
            ? CursorAffordance.automationPoint.restCursor
            : CursorAffordance.automationField.restCursor
    }

    private var laneDrag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard let type = model.selectedType else { return }
                if phase == .idle {
                    if NSEvent.modifierFlags.contains(.option) {
                        // Option-click deletes the nearest point.
                        didEdit = model.removePoint(at: value.startLocation)
                        phase = .deleted
                        return
                    }
                    phase = model.beginDrag(at: value.startLocation) ? .dragPoint : .pencil
                }
                let beat = snapped(model.beat(forX: value.location.x))
                let val = model.value(forY: value.location.y, type: type)
                switch phase {
                case .dragPoint:
                    model.dragPoint(toBeat: beat, value: val)
                    didEdit = true
                case .pencil:
                    if model.pencilInsert(atBeat: beat, value: val) { didEdit = true }
                case .idle, .deleted:
                    break
                }
            }
            .onEnded { _ in
                model.endDrag()
                if didEdit { onCommit() }
                phase = .idle
                didEdit = false
            }
    }

    private func snapped(_ beat: Double) -> Double {
        guard let grid = snap.beats, grid > 0 else { return max(0, beat) }
        return max(0, (beat / grid).rounded() * grid)
    }
}

/// The stepped controller line as its own Canvas view. Extracted so its inputs
/// are closure-free and tick-stable: only a controller edit invalidates it (the
/// piano-roll grid extraction idiom). CANVAS CONTRACT (m16-a): the renderer is
/// `@Sendable` with value-only captures computed before the closure, and all
/// drawing runs in `nonisolated` static helpers (View statics infer @MainActor,
/// so `nonisolated` is load-bearing). See docs/research/design-m16a-canvas-crash.md.
private struct ControllerLaneCanvas: View {
    var model: ControllerStripModel
    var accent: Color

    /// A Sendable value snapshot taken on the main actor before the closure runs.
    private struct Snapshot {
        var pixelsPerBeat: CGFloat
        var verticalInset: CGFloat
        var points: [MIDIControllerPoint]
        var valueUpper: Double
        var showHandles: Bool
        var centerFraction: Double?     // bend center, as a fraction from the bottom
        var clipLengthBeats: Double
        /// Split index for the m18-e ghost treatment: `points[..<playableCount]`
        /// play (full glow), `points[playableCount...]` are beyond-clip latent
        /// data (ghost — dim core, no glow). One boundary definition, the
        /// model's engine-honest `playableCount`.
        var playableCount: Int
        var accent: Color
        var hasLane: Bool
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let type = model.selectedType
        // Draw the canonical (sorted, deduped) draft so the stepped line is honest
        // even mid-gesture; the model keeps its own index-stable draft for editing.
        let points = type.map { MIDIControllerLane.canonicalPoints(model.draft, type: $0) } ?? []
        let s = Snapshot(
            pixelsPerBeat: model.pixelsPerBeat,
            verticalInset: ControllerStripModel.verticalInset,
            points: points,
            valueUpper: type.map { Double($0.valueRange.upperBound) } ?? 127,
            showHandles: model.handlesVisible,
            centerFraction: (type.flatMap { t -> Double? in
                if case .pitchBend = t { return Double(t.neutralDefault) / Double(t.valueRange.upperBound) }
                return nil
            }),
            clipLengthBeats: model.clipLengthBeats,
            playableCount: ControllerStripModel.playableCount(
                points, clipLengthBeats: model.clipLengthBeats),
            accent: accent,
            hasLane: type != nil)
        return Canvas { @Sendable context, size in
            Self.drawBackground(&context, size: size, s: s)
            Self.drawCenterGuideline(&context, size: size, s: s)
            Self.drawSteppedLine(&context, size: size, s: s)
            Self.drawHandles(&context, size: size, s: s)
        }
    }

    private nonisolated static func yFor(value: Int, size: CGSize, s: Snapshot) -> CGFloat {
        let frac = s.valueUpper > 0 ? Swift.min(1, Swift.max(0, Double(value) / s.valueUpper)) : 0
        let usable = Swift.max(1, size.height - s.verticalInset * 2)
        return s.verticalInset + usable * (1 - CGFloat(frac))
    }

    private nonisolated static func drawBackground(_ context: inout GraphicsContext, size: CGSize, s: Snapshot) {
        // Bottom baseline (the velocity-lane idiom).
        context.fill(
            Path(CGRect(x: 0, y: size.height - 0.5, width: size.width, height: 0.5)),
            with: .color(DAWTheme.hairline))
        // Out-of-clip shade past the clip length (the note-grid shade, same
        // 0.28 black) + a 1 pt neutral boundary hairline at the clip end so the
        // latent region reads as a deliberate boundary, not a rendering seam
        // (m18-e — DESIGN-LANGUAGE "Controller strips"; gridEmphasis is the
        // grid's own bar-line chrome, no accent and no glow: a boundary is
        // chrome, not state).
        let clipX = CGFloat(s.clipLengthBeats) * s.pixelsPerBeat
        if clipX < size.width {
            context.fill(
                Path(CGRect(x: clipX, y: 0, width: size.width - clipX, height: size.height)),
                with: .color(Color.black.opacity(0.28)))
            context.fill(
                Path(CGRect(x: clipX - 0.5, y: 0, width: 1, height: size.height)),
                with: .color(DAWTheme.gridEmphasis))
        }
    }

    private nonisolated static func drawCenterGuideline(_ context: inout GraphicsContext, size: CGSize, s: Snapshot) {
        guard let frac = s.centerFraction else { return }
        let usable = Swift.max(1, size.height - s.verticalInset * 2)
        let y = s.verticalInset + usable * (1 - CGFloat(frac))
        var line = Path()
        line.move(to: CGPoint(x: 0, y: y))
        line.addLine(to: CGPoint(x: size.width, y: y))
        context.stroke(line, with: .color(DAWTheme.gridEmphasis),
                       style: StrokeStyle(lineWidth: 0.75, dash: [3, 3]))
    }

    /// The stepped value line, split at the clip boundary (m18-e ghost
    /// treatment — DESIGN-LANGUAGE "Controller strips"): the in-clip portion
    /// takes the full neon treatment (bloom + bright core), the beyond-clip
    /// portion — latent data the engine never plays — draws as a single dim
    /// core with NO glow (glow is earned; inert data earns none, the
    /// disabled-automation-lane idiom). Hold segments that cross the boundary
    /// split exactly at the clip-end x; a vertical step AT the boundary is
    /// ghost (the model's strict-`<` playable rule).
    private nonisolated static func drawSteppedLine(_ context: inout GraphicsContext, size: CGSize, s: Snapshot) {
        guard s.hasLane, !s.points.isEmpty else { return }
        let clipX = CGFloat(s.clipLengthBeats) * s.pixelsPerBeat
        var lit = Path()
        var ghost = Path()
        var litEnd: CGPoint?
        var ghostEnd: CGPoint?
        // Appends one polyline segment to a path, continuing the subpath when
        // it abuts the previous segment (a step line is one continuous trace
        // per side of the boundary).
        func add(_ a: CGPoint, _ b: CGPoint, lit litSide: Bool) {
            if litSide {
                if litEnd != a { lit.move(to: a) }
                lit.addLine(to: b)
                litEnd = b
            } else {
                if ghostEnd != a { ghost.move(to: a) }
                ghost.addLine(to: b)
                ghostEnd = b
            }
        }
        // Routes a segment to the lit or ghost path, splitting a hold that
        // crosses the clip boundary at exactly x = clipX.
        func segment(_ a: CGPoint, _ b: CGPoint) {
            if a.x >= clipX && b.x >= clipX {
                add(a, b, lit: false)
            } else if b.x <= clipX {
                add(a, b, lit: true)
            } else {
                let mid = CGPoint(x: clipX, y: a.y)
                add(a, mid, lit: true)
                add(mid, b, lit: false)
            }
        }
        var pen: CGPoint?
        for point in s.points {
            let x = CGFloat(point.beat) * s.pixelsPerBeat
            let y = yFor(value: point.value, size: size, s: s)
            if let last = pen {
                segment(last, CGPoint(x: x, y: last.y))       // hold
                segment(CGPoint(x: x, y: last.y), CGPoint(x: x, y: y))   // step
            }
            pen = CGPoint(x: x, y: y)
        }
        // Hold the final value out to the canvas right edge (ghosted past the
        // clip end — nothing sounds there).
        if let last = pen {
            let rightEdge = Swift.max(clipX, size.width)
            if rightEdge > last.x {
                segment(last, CGPoint(x: rightEdge, y: last.y))
            }
        }
        // Neon glow recipe (value-only, m16-a): a faint wide bloom under the
        // bright core, matching the velocity-lane accent stems — in-clip only.
        if !lit.isEmpty {
            context.stroke(lit, with: .color(s.accent.opacity(0.16)), lineWidth: 4)
            context.stroke(lit, with: .color(s.accent.opacity(0.9)), lineWidth: 1.5)
        }
        if !ghost.isEmpty {
            context.stroke(ghost, with: .color(s.accent.opacity(0.35)), lineWidth: 1)
        }
    }

    private nonisolated static func drawHandles(_ context: inout GraphicsContext, size: CGSize, s: Snapshot) {
        guard s.hasLane, s.showHandles else { return }
        for (index, point) in s.points.enumerated() {
            let x = CGFloat(point.beat) * s.pixelsPerBeat
            let y = yFor(value: point.value, size: size, s: s)
            if index < s.playableCount {
                // Glow recipe (value-only, m16-a): a faint wide bloom + a mid ring
                // under the bright core, so each handle reads as a soft neon dot.
                context.fill(Path(ellipseIn: CGRect(x: x - 5.5, y: y - 5.5, width: 11, height: 11)),
                             with: .color(s.accent.opacity(0.16)))
                context.fill(Path(ellipseIn: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7)),
                             with: .color(s.accent.opacity(0.32)))
                context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)),
                             with: .color(s.accent))
            } else {
                // Beyond-clip ghost handle (m18-e): the flat dim core only — no
                // bloom, no ring, no glow (latent data; still a full edit target,
                // hit-test/drag/delete are boundary-blind on purpose).
                context.fill(Path(ellipseIn: CGRect(x: x - 2.5, y: y - 2.5, width: 5, height: 5)),
                             with: .color(s.accent.opacity(0.45)))
            }
        }
    }
}
