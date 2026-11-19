import SwiftUI
import DAWCore
import DAWAppKit

/// The STEP SEQUENCER band (m23-cq-1) — a grid over the SAME clip notes the
/// piano roll edits, mounted in place of the note grid when the pane's mode is
/// `.steps`.
///
/// Thin over `DAWAppKit.StepSequencerGeometry` / `StepSequencerEdit`: every
/// decision (which rows, which columns, which cell a point is in, what a toggle
/// writes) is headless and tested; this file draws and routes TWO gestures: the
/// cell click, and (m39-w4-3) the Accent row's column click (`StepAccent`).
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
    /// m39-w4-3: the Accent row's lit columns (`StepAccent.columns`). Empty on a
    /// melodic grid, which draws no Accent row at all (`StepAccent.hasRow`).
    var accentColumns: [StepAccentColumn] = []
    /// Clicks an Accent cell (a column index). Routed to the parent, which owns
    /// the ONE note draft and the ONE commit funnel, like `onToggle`.
    var onAccent: (Int) -> Void = { _ in }
    /// m39-w4-10: the ready-made beats this EMPTY drum clip offers
    /// (`StepStartFromBeat.choices`), or nil when the clip is not an empty drum
    /// clip, which draws no "Start from a beat" strip.
    var beatChoices: [StepBeatChoice]? = nil
    /// Writes the chosen beat (its id) into the clip and answers what happened.
    /// Routed to the parent, which hands it to the store (one undo step); this
    /// view never touches the store.
    var onStartFromBeat: (String) -> StepBeatOutcome = { _ in .nothing }

    /// Height of the frozen step-number ruler pinned over the top of the grid.
    private static let rulerHeight: CGFloat = 16
    /// Height of the Accent row: a touch shorter than a drum row (24 pt), so it
    /// reads as a control strip under the kit rather than a ninth drum.
    private static let accentRowHeight: CGFloat = 22
    private static let scrollSpace = "stepSequencerGridScroll"

    /// Live horizontal scroll offset, read from the content's leading edge (the
    /// roll's `gridScrollReader` idiom) so the frozen ruler above the grid stays
    /// over the column it names when the grid is scrolled.
    @State private var scrollX: CGFloat = 0

    /// Identifies THIS grid instance to the bridge, so a teardown can only clear
    /// its own report (`StepSequencerBridge.reportNoGrid(from:)` — the clip
    /// switch race).
    @State private var reportToken = UUID()

    /// m39-w4-10: what the last "Start from a beat" pick did, shown in the strip
    /// until the next click in the grid, the dismiss button, or the clip going
    /// empty again (an undo).
    @State private var beatOutcome: StepBeatOutcome? = nil

    /// W9-PATF: how many beat picks this grid has run (the menu's and the
    /// debug seam's), so the strip's report fires even when a refused pick
    /// answers with the same sentence twice.
    @State private var beatPicks = 0

    /// What the strip shows, as ONE value for the reporter (the `DrawnState`
    /// idiom): the debug seam reads this back instead of echoing its input.
    private struct BeatStripState: Equatable {
        var offered: Bool
        var outcome: StepBeatOutcome?
        var picks: Int
    }

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
        // m23-ap I5-F4 — where the drawn columns sit on the song's grid.
        var phaseBeats: Double
        var firstStepSongBeat: Double
        var barMarks: [StepBarMark]
    }

    private var drawnState: DrawnState {
        DrawnState(lanes: geometry.lanes, stepCount: geometry.stepCount,
                   stepBeats: geometry.stepBeats, fills: fills,
                   rowHeight: geometry.rowHeight, stepWidth: geometry.stepWidth,
                   phaseBeats: geometry.phaseBeats,
                   firstStepSongBeat: geometry.firstStepSongBeat,
                   barMarks: geometry.barMarks)
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
            // m39-w4-10: the "Start from a beat" strip is a row in the flow
            // too, above the ruler, for the ruler's reason: an overlay would sit
            // over drum cells the user may want to click.
            if beatChoices != nil || beatOutcome != nil { beatStrip }
            stepRuler
            gridBody
            // m39-w4-3: the Accent row is ALSO a row in the flow, for the
            // ruler's reason above: its label and its cells share one HStack,
            // so they cannot sit at different heights. Pinned under the grid,
            // it stays in view however far the drum rows are scrolled.
            if StepAccent.hasRow(geometry) { accentRow }
        }
        // The clip went empty again (an undo of the beat): a "beat added" line
        // would now be false, so the strip goes back to offering the menu.
        .onChange(of: beatChoices != nil) { _, offered in
            if offered, beatOutcome?.changed == true { beatOutcome = nil }
        }
        // W9-PATF: the strip reports what it shows (offered? which result line?)
        // so `debug.stepSequencer` can echo ground truth, and takes a staged
        // pick through the SAME function the menu item runs.
        .onChange(of: BeatStripState(offered: beatChoices != nil, outcome: beatOutcome, picks: beatPicks),
                  initial: true) { _, strip in
            bridge.reportBeatStrip(token: reportToken, offered: strip.offered,
                                   outcome: strip.outcome, picks: strip.picks)
        }
        .onChange(of: bridge.beatNonce) { _, _ in
            guard beatChoices != nil, let id = bridge.stagedBeat else { return }
            pickBeat(id)
        }
    }

    /// THE ONE PICK: the menu item and the debug seam both run exactly this.
    private func pickBeat(_ patternID: String) {
        beatOutcome = onStartFromBeat(patternID)
        beatPicks += 1
    }

    // MARK: - "Start from a beat" (m39-w4-10)

    /// The strip's height: a touch taller than a drum row, so the chip has room.
    private static let beatStripHeight: CGFloat = 30

    /// ONE ROW OVER THE RULER (design §8, last bullet). On an empty drum clip it
    /// says so and offers the menu; after a pick it shows what happened (the
    /// result line, and a sentence naming any drum this kit lacks), with the
    /// menu still there when the pick was refused and the clip is still empty.
    private var beatStrip: some View {
        HStack(alignment: .center, spacing: 8) {
            if let outcome = beatOutcome {
                Image(systemName: outcome.isWarning
                      ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(outcome.isWarning ? DAWTheme.record : DAWTheme.signal)
                beatOutcomeLines(outcome)
                if let choices = beatChoices { beatMenu(choices) }
                beatDismissButton
            } else if let choices = beatChoices {
                Text(StepStartFromBeat.emptyPrompt)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                beatMenu(choices)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: Self.beatStripHeight, alignment: .leading)
        .background(DAWTheme.panelRaised)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 0.5)
        }
    }

    /// The result line first (what was added), then each warning, one per line.
    /// Prose, so SF Pro; a warning in the warning colour, the refusal bubble's
    /// amber, and the words are the store's, verbatim.
    private func beatOutcomeLines(_ outcome: StepBeatOutcome) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(outcome.lines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: 11, weight: index == 0 ? .medium : .regular))
                    .foregroundStyle(index == 0 && outcome.changed
                                     ? DAWTheme.textPrimary : DAWTheme.record)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(outcome.lines.joined(separator: " "))
    }

    /// THE MENU: every beat in library order (the first is the user's L2 pick),
    /// each with its one-line description as help. A themed chip, the step-size
    /// picker's grammar (`panelRaised`, hairline, SF Mono caps): never a stock
    /// gray control.
    private func beatMenu(_ choices: [StepBeatChoice]) -> some View {
        Menu {
            ForEach(choices) { choice in
                Button(choice.name) {
                    pickBeat(choice.id)
                }
                .help(choice.help)
            }
        } label: {
            HStack(spacing: 4) {
                Text(StepStartFromBeat.menuTitle.uppercased())
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
            .foregroundStyle(DAWTheme.textPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DAWTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.gridEmphasis, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(StepStartFromBeat.menuHelp)
        .accessibilityLabel(StepStartFromBeat.menuTitle)
    }

    /// Clears the result line.
    private var beatDismissButton: some View {
        Button {
            beatOutcome = nil
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .help("Hide this message")
        .accessibilityLabel("Hide this message")
    }

    private var gridBody: some View {
        ScrollView(.vertical, showsIndicators: true) {
            HStack(alignment: .top, spacing: 0) {
                laneGutter
                ScrollView(.horizontal, showsIndicators: true) {
                    StepGridCanvas(geometry: geometry, fills: fills, noteColor: noteColor)
                        .equatable()
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
                                rowHeight: drawn.rowHeight, stepWidth: drawn.stepWidth,
                                phaseBeats: drawn.phaseBeats,
                                firstStepSongBeat: drawn.firstStepSongBeat,
                                barMarks: drawn.barMarks)
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
    ///
    /// m23-ap I5-F4: the SONG's bars (`geometry.barMarks`) — a clip on bar 3
    /// reads 3, as the roll's ruler and the transport do — over the columns
    /// the grid emphasizes, from the one `isBarStart` predicate.
    private var stepRuler: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: StepSequencerGeometry.laneGutterWidth)
            ZStack(alignment: .topLeading) {
                ForEach(geometry.barMarks, id: \.step) { mark in
                    Text("\(mark.bar)")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim)
                        .frame(width: geometry.stepWidth, height: Self.rulerHeight,
                               alignment: .leading)
                        .padding(.leading, 3)
                        .offset(x: geometry.x(forStep: mark.step) - scrollX)
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

    // MARK: - Accent row (m39-w4-3)

    /// Novice copy for the row. Source: design
    /// `docs/design/2026-10-07-loop-drum-depth.md` §3.1 ("click a column and
    /// every hit in it plays harder") and §3.5 (click again to go back; a
    /// column with no hits has nothing to accent).
    static let accentRowLabel = "Accent"
    static let accentRowHelp = "Accent: click a step to make every hit in it play harder. "
        + "Click it again to go back. A step with no hits has nothing to accent."

    /// ONE ROW UNDER THE DRUM ROWS, labelled "Accent" (design §3.5). Its cells
    /// sit under the grid's columns: the canvas is the grid's drawn width,
    /// shifted by the live horizontal scroll exactly as the ruler's numbers
    /// are, so column k of the row is under column k of the grid.
    ///
    /// Mouse-only like the rest of this surface. The tap is caught on the
    /// CLIPPED frame (the visible strip right of the gutter), never on the
    /// shifted canvas, so a click on the "Accent" label cannot land on a
    /// column scrolled under it.
    private var accentRow: some View {
        HStack(spacing: 0) {
            Text(Self.accentRowLabel)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DAWTheme.textSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 8)
                .frame(width: StepSequencerGeometry.laneGutterWidth,
                       height: Self.accentRowHeight)
                .overlay(alignment: .trailing) {
                    Rectangle().fill(DAWTheme.hairline).frame(width: 1)
                }
            StepAccentCanvas(geometry: geometry, columns: accentColumns, noteColor: noteColor)
                .equatable()
                .frame(width: drawnWidth, height: Self.accentRowHeight)
                .offset(x: -scrollX)
                .allowsHitTesting(false)
                .frame(maxWidth: .infinity, maxHeight: Self.accentRowHeight, alignment: .leading)
                .clipped()
                .contentShape(Rectangle())
                .hoverCursor(CursorAffordance.stepCell.restCursor)
                .gesture(accentTap)
        }
        .frame(height: Self.accentRowHeight)
        .background(DAWTheme.panel)
        .overlay(alignment: .top) {
            Rectangle().fill(DAWTheme.hairline).frame(height: 0.5)
        }
        .help(Self.accentRowHelp)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Self.accentRowLabel)
    }

    /// CLICK AN ACCENT CELL: the visible x plus the scroll offset is the
    /// content x, and `StepAccent.step(atX:)` asks the grid's own hit test.
    private var accentTap: some Gesture {
        SpatialTapGesture(count: 1)
            .onEnded { value in
                guard let step = StepAccent.step(atX: value.location.x + scrollX,
                                                 geometry: geometry) else { return }
                beatOutcome = nil
                onAccent(step)
            }
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
                beatOutcome = nil
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
///
/// m23-ap I5-F4: `Equatable` and mounted `.equatable()`, the `PianoRollGrid`
/// fix from I5-F2 for the same reason — the geometry now carries the song's
/// `MeterMap`, whose arrays are rebuilt on every `transport.meterMap` read, and
/// the parent rebuilds `lanes` and `fills` on every evaluation too. Equality is
/// by VALUE (`MeterMap` compares its changes), so a tick that changes nothing
/// the grid draws cannot redraw it.
private struct StepGridCanvas: View, Equatable {
    var geometry: StepSequencerGeometry
    var fills: [StepCellFill]
    var noteColor: Color

    nonisolated static func == (lhs: StepGridCanvas, rhs: StepGridCanvas) -> Bool {
        lhs.geometry == rhs.geometry && lhs.fills == rhs.fills && lhs.noteColor == rhs.noteColor
    }

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
    ///
    /// m23-ap I5-F4: an off-grid clip's column 0 starts on the song line BEFORE
    /// the clip's first beat, so the part of it left of `clipStartX` is outside
    /// the clip too and takes the same shade and boundary hairline. Nothing is
    /// drawn there for a clip that starts on a line (`clipStartX` is 0).
    private nonisolated static func drawOutOfClipShade(_ context: inout GraphicsContext,
                                                       size: CGSize, s: Snapshot) {
        let startX = min(s.geometry.clipStartX, size.width)
        if startX > 0 {
            context.fill(
                Path(CGRect(x: 0, y: 0, width: startX, height: size.height)),
                with: .color(Color.black.opacity(0.28)))
            context.fill(
                Path(CGRect(x: startX - 0.5, y: 0, width: 1, height: size.height)),
                with: .color(DAWTheme.gridEmphasis))
        }
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

/// m39-w4-3 — THE ACCENT ROW's Canvas: one slot per column, and each column with
/// hits drawn in its state (`StepAccentState`).
///
/// The note colour, not a new hue: an accent IS a note velocity (nothing else
/// is stored), so it wears the same cyan, or violet on an AI clip, as the hits
/// it lifts (DESIGN-LANGUAGE: semantic accents only; violet = AI-touched).
///  - `on`: a lit bar with the cells' glow rings.
///  - `mixed`: the bottom half lit, under an outline: some hits are accented.
///  - `off`: an outline only: hits you could accent.
///  - empty: the faint slot every column has, so the row reads as clickable.
///
/// Equatable and mounted `.equatable()`, the `StepGridCanvas` rule: a transport
/// tick that changes nothing drawn does not redraw it.
private struct StepAccentCanvas: View, Equatable {
    var geometry: StepSequencerGeometry
    var columns: [StepAccentColumn]
    var noteColor: Color

    nonisolated static func == (lhs: StepAccentCanvas, rhs: StepAccentCanvas) -> Bool {
        lhs.geometry == rhs.geometry && lhs.columns == rhs.columns
            && lhs.noteColor == rhs.noteColor
    }

    private struct Snapshot {
        var geometry: StepSequencerGeometry
        var columns: [StepAccentColumn]
        var noteColor: Color
    }

    var body: some View {
        let s = Snapshot(geometry: geometry, columns: columns, noteColor: noteColor)
        return Canvas { @Sendable context, size in
            Self.drawSlots(&context, size: size, s: s)
            Self.drawColumns(&context, size: size, s: s)
        }
    }

    private nonisolated static func slotRect(step: Int, size: CGSize, s: Snapshot) -> CGRect {
        CGRect(x: s.geometry.x(forStep: step), y: 0,
               width: s.geometry.stepWidth, height: size.height)
            .insetBy(dx: 3.5, dy: 5)
    }

    /// A faint slot under every column the grid has, so a beginner sees where
    /// to click before anything is lit. Neutral chrome, no accent hue.
    private nonisolated static func drawSlots(_ context: inout GraphicsContext,
                                              size: CGSize, s: Snapshot) {
        for step in 0..<s.geometry.stepCount {
            let rect = slotRect(step: step, size: size, s: s)
            context.fill(Path(roundedRect: rect, cornerRadius: 2.5),
                         with: .color(Color.white.opacity(0.04)))
        }
    }

    private nonisolated static func drawColumns(_ context: inout GraphicsContext,
                                                size: CGSize, s: Snapshot) {
        for column in s.columns {
            let rect = slotRect(step: column.step, size: size, s: s)
            let path = Path(roundedRect: rect, cornerRadius: 2.5)
            switch column.state {
            case .empty:
                continue
            case .off:
                context.stroke(path, with: .color(s.noteColor.opacity(0.40)), lineWidth: 0.75)
            case .mixed:
                let lower = CGRect(x: rect.minX, y: rect.midY,
                                   width: rect.width, height: rect.height / 2)
                context.fill(Path(roundedRect: lower, cornerRadius: 2),
                             with: .color(s.noteColor.opacity(0.60)))
                context.stroke(path, with: .color(s.noteColor.opacity(0.70)), lineWidth: 0.75)
            case .on:
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: -3, dy: -3), cornerRadius: 4.5),
                    with: .color(s.noteColor.opacity(0.10)))
                context.fill(
                    Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: 3.5),
                    with: .color(s.noteColor.opacity(0.22)))
                context.fill(path, with: .color(s.noteColor.opacity(0.92)))
                context.stroke(path, with: .color(s.noteColor.opacity(0.95)), lineWidth: 0.5)
            }
        }
    }
}
