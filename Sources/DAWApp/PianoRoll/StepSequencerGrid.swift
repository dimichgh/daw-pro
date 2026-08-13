import SwiftUI
import DAWCore
import DAWAppKit

/// The STEP SEQUENCER band (m23-cq-1) — a grid over the SAME clip notes the
/// piano roll edits, mounted in place of the note grid when the pane's mode is
/// `.steps`.
///
/// Thin over `DAWAppKit.StepSequencerGeometry` / `StepSequencerEdit`: every
/// decision (which rows, which columns, which cell a point is in, what a toggle
/// writes) is headless and tested; this file draws and routes ONE gesture.
///
/// ⚠️ **MOUSE-ONLY. NO keyboard shortcut belongs on this surface** — not DELETE,
/// not arrows, not space. The click is simultaneously the entry path and the
/// deletion path, which is the property that made the surface safe to build
/// while m23-cf (a bare DELETE reported dead on notes and clips) was still
/// undiagnosed. ⭐ **m23-cf IS FIXED as of 2026-08-12** (user-confirmed by hand),
/// so the ORIGINAL reason for the mouse-only scoping has expired — but the
/// scoping itself is kept on its own merits: one gesture that is both entry and
/// deletion needs no key, and adding one now would be a new design decision
/// rather than the removal of a workaround. See `StepSequencerEdit`.
struct StepSequencerBand: View {
    /// The resolved grid — lanes, columns, cell size. Built by the parent from
    /// the live draft so the drawing, the hit test and the edit share one value.
    var geometry: StepSequencerGeometry
    /// The lit boxes, with the weight each was drawn at.
    var fills: [StepCellFill]
    /// Cyan, or VIOLET when the clip is AI-touched — the SAME `noteColor` the
    /// roll's pills use. Two surfaces over one note must not disagree about
    /// colour, and this is how "violet = AI-touched, always" holds here.
    var noteColor: Color
    /// The playhead's x in this grid's content space, or nil when the transport
    /// sits outside the edited clip (the m23-c1 rule, one surface over).
    var playheadX: CGFloat?
    /// Viewport width the band may extend into at wide windows (m18-f) — the
    /// grid always reaches the panel's right edge instead of leaving dead glass.
    var viewportWidth: CGFloat
    /// Reports what was drawn, and clears the report on teardown.
    var bridge: StepSequencerBridge
    /// Toggles a cell. Routed to the parent, which owns the ONE note draft and
    /// the ONE commit funnel — this view never touches the store.
    var onToggle: (StepCell) -> Void

    /// Height of the frozen step-number ruler pinned over the top of the grid.
    private static let rulerHeight: CGFloat = 16
    private static let scrollSpace = "stepSequencerGridScroll"

    /// Live horizontal scroll offset, read from the content's leading edge (the
    /// roll's `gridScrollReader` idiom) so the frozen ruler above the grid stays
    /// over the column it names when the grid is scrolled.
    @State private var scrollX: CGFloat = 0

    /// Identifies THIS grid instance to the bridge, so a teardown can only clear
    /// its own report (`StepSequencerBridge.reportNoGrid(from:)` — the clip
    /// switch race).
    @State private var reportToken = UUID()

    /// Everything the reporter publishes, as ONE value. The Canvas is given the
    /// same `geometry`/`fills` this is composed from, and the `.onChange` that
    /// publishes it hangs off the Canvas itself — so a build that keeps the
    /// value and draws nothing takes the reporter with it (m23-v, measured: the
    /// alternative leaves every headless test and every echo leg green).
    private struct DrawnState: Equatable {
        var lanes: [StepSequencerLane]
        var stepCount: Int
        var stepBeats: Double
        var fills: [StepCellFill]
        var rowHeight: CGFloat
        var stepWidth: CGFloat
    }

    private var drawnState: DrawnState {
        DrawnState(lanes: geometry.lanes, stepCount: geometry.stepCount,
                   stepBeats: geometry.stepBeats, fills: fills,
                   rowHeight: geometry.rowHeight, stepWidth: geometry.stepWidth)
    }

    /// Drawn width: content, extended to the viewport at wide windows (m18-f,
    /// the ONE definition shared with the roll's three bands). The extension is
    /// shaded latent space — the out-of-clip shade keeps it honest.
    private var drawnWidth: CGFloat {
        PianoRollModel.drawnWidth(
            content: geometry.contentWidth,
            viewport: max(0, viewportWidth - StepSequencerGeometry.laneGutterWidth))
    }

    /// ⚠️ **THE RULER IS A ROW IN THE FLOW, NOT AN OVERLAY ON THE GRID — and
    /// this was built wrong first.** Build 1 hung the step ruler over the top of
    /// the grid and gave the LANE GUTTER a matching 16 pt spacer to clear it.
    /// Measured from a real capture at 2×: every lane label then sat exactly one
    /// ruler-height BELOW the row it names, so the hi-hat pattern drew on the
    /// "High Floor Tom" line while the model, the echo and every headless test
    /// stayed green — the m23-an defect (the pixels blaming an innocent row) in
    /// a surface whose whole job is saying which drum you just placed. Putting
    /// the ruler OUTSIDE both columns makes the disagreement unrepresentable:
    /// the gutter and the grid start at the same y because nothing sits above
    /// only one of them.
    var body: some View {
        VStack(spacing: 0) {
            stepRuler
            gridBody
        }
    }

    private var gridBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                laneGutter
                ScrollView(.horizontal, showsIndicators: true) {
                    StepGridCanvas(geometry: geometry, fills: fills, noteColor: noteColor)
                        .frame(width: drawnWidth, height: geometry.contentHeight)
                        .overlay(alignment: .topLeading) { playhead }
                        .background { scrollReader }
                        // A `Canvas` contributes no hit region of its own, so the
                        // tap needs a shape (the m23-cf `.contentShape` finding,
                        // one file over — measured there, not assumed here).
                        .contentShape(Rectangle())
                        .hoverCursor(CursorAffordance.stepCell.restCursor)
                        .gesture(cellTap)
                        // The report rides the DRAWING layer, not a sibling.
                        .onChange(of: drawnState, initial: true) { _, drawn in
                            bridge.report(
                                token: reportToken,
                                lanes: drawn.lanes, stepCount: drawn.stepCount,
                                stepBeats: drawn.stepBeats, fills: drawn.fills,
                                rowHeight: drawn.rowHeight, stepWidth: drawn.stepWidth)
                        }
                        .onDisappear { bridge.reportNoGrid(from: reportToken) }
                }
                .coordinateSpace(name: Self.scrollSpace)
            }
        }
        // Opens where the work is: at the BOTTOM on a drum kit (the kick, the
        // snare and the hats), centred on a melodic clip. `.center` is not a
        // guess — it is the SAME rule the roll itself opens on ("open near
        // middle C", `PianoRollView.swift`'s grid `.defaultScrollAnchor`), so
        // the two editors of one clip land a beginner in the same register.
        // Deliberately NOT content-aware: making only the steps view chase the
        // notes would make the two editors of the same clip open differently.
        // The decision is the geometry's — see `opensAtBottom`, which records
        // the capture that produced the drum half of the rule.
        .defaultScrollAnchor(geometry.opensAtBottom ? .bottom : .center)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Lane gutter

    /// One labelled row per lane. Prose, so SF Pro and `textSecondary` — a drum
    /// name is not a numeric readout (docs/DESIGN-LANGUAGE.md "Text"). Names
    /// come from the GM percussion key map via `StepSequencerLanes`; nothing
    /// here is hardcoded.
    private var laneGutter: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(geometry.lanes) { lane in
                Text(lane.label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .frame(height: geometry.rowHeight)
                    .background(alignment: .bottom) {
                        Rectangle().fill(DAWTheme.hairline).frame(height: 0.5)
                    }
                    .help(lane.label)
            }
        }
        .frame(width: StepSequencerGeometry.laneGutterWidth,
               height: geometry.contentHeight, alignment: .top)
        .background(DAWTheme.panel)
        .overlay(alignment: .trailing) {
            Rectangle().fill(DAWTheme.hairline).frame(width: 1)
        }
    }

    // MARK: - Step ruler

    /// Bar numbers over the columns that start a bar — SF Mono, because a bar
    /// number is a numeric readout, and `textDim` because it is a caption, never
    /// a position (cyan in this pane is the transport playhead: the m23-t
    /// operand-vs-position ruling, applied to the sibling readout one file
    /// over).
    private var stepRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: StepSequencerGeometry.laneGutterWidth)
            ZStack(alignment: .topLeading) {
                ForEach(barStartSteps, id: \.self) { step in
                    Text("\(geometry.barNumber(forStep: step))")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                        .frame(width: geometry.stepWidth, height: Self.rulerHeight,
                               alignment: .leading)
                        .padding(.leading, 3)
                        .offset(x: geometry.x(forStep: step) - scrollX)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
        }
        .frame(height: Self.rulerHeight)
        .background(DAWTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 0.5)
        }
        .allowsHitTesting(false)
    }

    private var barStartSteps: [Int] {
        guard geometry.stepsPerBar > 0 else { return [] }
        return Swift.stride(from: 0, to: geometry.stepCount, by: geometry.stepsPerBar).map { $0 }
    }

    // MARK: - Playhead

    /// A 1 pt glowing cyan hairline at the transport position — OFFSET, never a
    /// per-frame Canvas redraw (the arrange rule). Cyan even on an AI clip:
    /// cyan is playback state, and the note colour is content.
    @ViewBuilder
    private var playhead: some View {
        if let x = playheadX {
            Rectangle()
                .fill(DAWTheme.playback)
                .frame(width: 1, height: geometry.contentHeight)
                .glow(DAWTheme.playback, radius: 6, intensity: 0.6)
                .offset(x: x)
                .allowsHitTesting(false)
        }
    }

    // MARK: - The one gesture

    /// CLICK A CELL TO TOGGLE IT. The whole interaction vocabulary of this
    /// surface (m23-cq-1) — one gesture that is both entry and deletion.
    ///
    /// m23-al R9: a click in the step grid is the user ACTING INSIDE the editor
    /// pane, so it must engage the roll or this gesture silently fails to claim
    /// ⌘+/⌘−/⌘0. It engages through the parent's `commit()` funnel (R6), which
    /// every toggle runs — see `PianoRollView.applyStepToggle`.
    private var cellTap: some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                guard let cell = geometry.cell(at: value.location) else { return }
                onToggle(cell)
            }
    }

    /// Reads the grid content's leading x in the scroll viewport space → the
    /// live horizontal offset the frozen ruler shifts by (the roll's
    /// `gridScrollReader` idiom, minus the follow reporting: follow does not
    /// drive this band in v1).
    private var scrollReader: some View {
        GeometryReader { geo in
            let leadingX = geo.frame(in: .named(Self.scrollSpace)).minX
            Color.clear
                .onChange(of: leadingX, initial: true) { _, newValue in
                    scrollX = -newValue
                }
        }
        .allowsHitTesting(false)
    }
}

/// The step grid Canvas: lane stripes, bar/beat columns, the out-of-clip shade,
/// and the lit boxes.
///
/// Its own struct with closure-free, tick-stable inputs (the `PianoRollGrid`
/// rule): a transport tick re-evaluates the parent but leaves this value equal,
/// so SwiftUI skips it and the draw closure never re-runs on playback — only the
/// playhead overlay's offset moves. No allocation per frame, because there are
/// no frames: redraw is per interaction.
private struct StepGridCanvas: View {
    var geometry: StepSequencerGeometry
    var fills: [StepCellFill]
    var noteColor: Color

    /// A value snapshot for the `@Sendable` renderer (CANVAS CONTRACT, m16-a):
    /// value captures only, computed before the closure.
    private struct Snapshot {
        var geometry: StepSequencerGeometry
        var fills: [StepCellFill]
        var noteColor: Color
    }

    var body: some View {
        let s = Snapshot(geometry: geometry, fills: fills, noteColor: noteColor)
        return Canvas { @Sendable context, size in
            Self.drawLaneRows(&context, size: size, s: s)
            Self.drawColumns(&context, size: size, s: s)
            Self.drawOutOfClipShade(&context, size: size, s: s)
            Self.drawFills(&context, s: s)
        }
    }

    /// Alternating lane stripes + a row separator, so a wide grid stays
    /// row-readable across 16 columns. Neutral chrome — no accent (Rule 3).
    private nonisolated static func drawLaneRows(_ context: inout GraphicsContext,
                                                 size: CGSize, s: Snapshot) {
        for index in s.geometry.lanes.indices {
            let y = s.geometry.y(forLane: index)
            if index.isMultiple(of: 2) {
                context.fill(
                    Path(CGRect(x: 0, y: y, width: size.width, height: s.geometry.rowHeight)),
                    with: .color(Color.black.opacity(0.18)))
            }
            context.fill(
                Path(CGRect(x: 0, y: y, width: size.width, height: 0.5)),
                with: .color(DAWTheme.hairline))
        }
    }

    /// Column lines: bar starts take `gridEmphasis`, beat starts the hairline,
    /// every other step a fainter one — the roll's survey-grid weights, so the
    /// two editors' gridlines read as the same grid.
    private nonisolated static func drawColumns(_ context: inout GraphicsContext,
                                                size: CGSize, s: Snapshot) {
        let columns = max(s.geometry.stepCount,
                          Int((size.width / s.geometry.stepWidth).rounded(.up)))
        for step in 0...columns {
            let x = s.geometry.x(forStep: step)
            let color: Color
            if s.geometry.isBarStart(step: step) {
                color = DAWTheme.gridEmphasis
            } else if s.geometry.isBeatStart(step: step) {
                color = DAWTheme.hairline
            } else {
                color = DAWTheme.hairline.opacity(0.5)
            }
            context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                         with: .color(color))
        }
    }

    /// Everything past the clip end is LATENT: the same 0.28 shade + 1 pt
    /// `gridEmphasis` boundary hairline the roll's three bands draw (m19-g), at
    /// the same meaning — a box there is store-legal and never sounds.
    private nonisolated static func drawOutOfClipShade(_ context: inout GraphicsContext,
                                                       size: CGSize, s: Snapshot) {
        let clipX = s.geometry.clipEndX
        guard clipX < size.width else { return }
        context.fill(
            Path(CGRect(x: clipX, y: 0, width: size.width - clipX, height: size.height)),
            with: .color(Color.black.opacity(0.28)))
        context.fill(
            Path(CGRect(x: clipX - 0.5, y: 0, width: 1, height: size.height)),
            with: .color(DAWTheme.gridEmphasis))
    }

    /// The lit boxes. Velocity → fill opacity with the roll's own curve, so one
    /// note reads at the same weight in both editors. A lit box earns the glow
    /// recipe (it is CONTENT and it is state — never static chrome); a LATENT
    /// box past the clip end gets the m19-g ghost instead: flat dim core, no
    /// bloom, velocity no longer modulating it.
    private nonisolated static func drawFills(_ context: inout GraphicsContext, s: Snapshot) {
        for fill in s.fills {
            guard let row = s.geometry.laneIndex(ofPitch: fill.cell.pitch) else { continue }
            let rect = s.geometry.cellRect(step: fill.cell.step, lane: row)
                .insetBy(dx: 2.5, dy: 3)
            let path = Path(roundedRect: rect, cornerRadius: 3)
            if fill.isLatent {
                context.fill(path, with: .color(s.noteColor.opacity(0.35)))
                context.stroke(path, with: .color(s.noteColor.opacity(0.45)), lineWidth: 0.5)
                continue
            }
            let opacity = 0.45 + 0.5 * Double(fill.velocity) / 127
            // Wide faint bloom under a bright core — the glow recipe, drawn as
            // rings rather than a shadow because a Canvas shadow would re-blur
            // on every redraw.
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 5),
                with: .color(s.noteColor.opacity(0.10)))
            context.fill(
                Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 4),
                with: .color(s.noteColor.opacity(0.22)))
            context.fill(path, with: .color(s.noteColor.opacity(opacity)))
            context.stroke(path, with: .color(s.noteColor.opacity(0.95)), lineWidth: 0.5)
        }
    }
}
