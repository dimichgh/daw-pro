import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// The EQ FREQUENCY-CURVE editor surface (m22-b Phase 3, design
/// docs/research/design-m22b-eq-curve-editor.md §4/§5): the eq card's Simple
/// density — direct manipulation on the response curve itself, over the
/// exact §5.3 four-layer stack. Bottom → top inside the plot:
///
/// 1. **Spectrum Canvas** (m22-b: master chain only; SINCE m23-r3: every EQ
///    card, master or track — the per-insert tap m23-r1/r2a/r2b built is what
///    m22-b's "display honesty" was waiting for): its own UNPAUSED 60 Hz
///    `TimelineView(.periodic)` — the m22-e poll-discipline law, which this
///    layer violated from m22-b until m23-r3 measured the freeze — fed by the
///    injected snapshot closure (`appModel.effectEditorSpectrum()`, the
///    `VibeMeterView` pattern verbatim), display-smoothed by the model's §4.1
///    asymmetric one-pole, bands drawn at their TRUE 40 Hz–16 kHz geometric
///    edges as a bottom-anchored filled path. Signal-green at low opacity —
///    live healthy signal semantics, context under the curve, never a
///    measurement readout. **The two curves do not mean the same thing** — a
///    master card measures POST-fader over the whole mix, a track card measures
///    POST this insert and PRE the strip fader — so they are LABELLED
///    differently (see `plot`'s help fork).
/// 2. **Grid Canvas** — hairlines every 6 dB + the beginner-readable decade
///    marks with SF Mono dim labels; redraws on size change only.
/// 3. **Curves Canvas** — per-band dim neutral curves (the selected band's
///    brightened) under the glowing playback-cyan composite (the curve IS a
///    gain readout — cyan earned; bloom-under-core, the house glow recipe).
///    Redraws on PARAM change via Observation — never on a timeline tick.
/// 4. **Handle layer** — six SwiftUI handle views positioned by the model
///    (12 pt dot + SF Mono micro-tag, 28 pt hit target), plus the transparent
///    scroll-resolution surface underneath them.
///
/// Every edit routes through `EQCurveEditorModel` → `EffectEditorModel.set` —
/// the SAME store twins the wire's `fx.setParam` calls (UI == wire; undo
/// coalescing per (chain, effect, name) comes free). ALL math lives in the
/// headless model (the hard review rule); this file is drawing and gestures.
/// All three Canvas layers obey the m16-a `@Sendable` value-capture contract.
/// NO VIOLET anywhere — an EQ curve is standard mixing chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3).
struct EQCurveEditor: View {
    /// The wrapped knob-strip model — band-strip chip reads (slope/enabled
    /// values) and the write path the curve model routes through.
    var editor: EffectEditorModel
    /// The headless curve model (handle layout, interaction laws, spectrum
    /// smoother, selection state).
    var model: EQCurveEditorModel
    /// The spectrum-layer gate, computed at ONE home
    /// (`EQCurveEditorModel.showsSpectrum(for:)`) — since m23-r3, true for a
    /// track card as well as the master's.
    var showsSpectrum: Bool
    /// The plot's `.help` caption, RESOLVED by the caller through the one-home
    /// `EQCurveEditorModel.curveHelp(for:isMeasuring:)` (master / track /
    /// not-measuring / no-spectrum, whole). It arrives as a plain String on
    /// purpose: a tooltip is invisible to `debug.captureUI`, so if this view
    /// picked the branch itself, the pre-fader labelling law would be pinned as
    /// a function and unpinned as a wire — no test and no capture could tell a
    /// mis-wired caption from a correct one. Resolved once, in the app model,
    /// where `debug.effectEditor` reports the SAME value it passes here.
    var help: String
    /// Polled once per spectrum frame — `appModel.effectEditorSpectrum()` in
    /// the app, a fake in previews. A closure, so no engine coupling here (the
    /// `VibeMeterView` seam).
    var spectrum: () -> MasterAnalysisSnapshot
    /// The INSTRUMENT FREQUENCY GUIDE's whole state (m23-o2), resolved by the
    /// caller at its one home (`AppModel.effectEditorInstrumentGuide` →
    /// `EQInstrumentGuide.resolve`). It arrives as a plain value for the same
    /// reason `help` does: `debug.effectEditor` reports that very property, so
    /// the gate reads the value the card draws instead of a re-derivation.
    ///
    /// Required, never defaulted. A `= .notApplicable` default is exactly how
    /// this becomes a silent no-op at some future call site — and its failure
    /// mode is invisible, because "no guidance" looks identical to "this track
    /// has no resolvable family".
    var guide: EQInstrumentGuide
    /// The tap's LIFECYCLE hold, run as the spectrum layer's `.task(id:)` body:
    /// arms the open insert on entry, releases when SwiftUI cancels it. Hung on
    /// the LAYER, not the card, so "the layer exists" ⟺ "the tap is armed" ⟺
    /// "exactly one thing polls it" — the m23-r3 single-consumer invariant is
    /// then structural rather than a convention (`insertAnalysis` DRAINS; a
    /// second consumer yields a plausible STALE reading, never an error). A
    /// master card's hold is a no-op: `masterAnalysis()` needs no tap.
    /// Required, never defaulted — a `= {}` default is how this silently
    /// becomes a no-op at some future call site.
    var holdSpectrum: () async -> Void
    /// Reports the plot's MEASURED width up to the app model, so
    /// `debug.effectEditor` can report positions at the width that was actually
    /// drawn rather than at `EQGuidanceLayout.contentWidth`.
    ///
    /// ⚠️ THIS CLOSURE IS THE ONLY THING THAT MAKES THE PROBE'S x VALUES
    /// FALSIFIABLE. `DAWApp` has no test target, so nothing in `DAWAppKitTests`
    /// can see this file; if the probe derived x from the layout CONSTANT while
    /// this Canvas drew from `size.width`, the two would agree only because the
    /// card happens to be a fixed 560 pt frame, and a staging gate checking
    /// "x matches the width the probe names" would be self-consistent and blind.
    /// Required, never defaulted — same reasoning as `guide` and `holdSpectrum`.
    var onPlotWidth: (Double) -> Void

    /// The plot's fixed height (§6: plot ≈ 528×260 inside the 560 pt card).
    private static let plotHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            plot
            guidanceRow
            EQBandStrip(editor: editor, model: model)
            footer
        }
    }

    // MARK: - The guidance row (m23-o2) — DRAWN prose, never a tooltip

    /// The instrument frequency guide's words, immediately under the plot.
    ///
    /// **This row exists because `.help` is a tooltip and `debug.captureUI`
    /// photographs the window** — guidance that lived only in a tooltip is
    /// guidance the gate cannot see and a user may never find. It is also what
    /// makes the plot's compact SF Mono tags ("CUT BELOW 35 Hz") legible without
    /// hovering: their expansion is drawn permanently 10 pt below them, in
    /// words, rather than hidden behind a pointer. Those tags deliberately share
    /// NO vocabulary with the band handles' own HP·LS·1·2·HS·LP micro-tags — see
    /// `EQInstrumentGuide.Mark.tag`.
    ///
    /// Its height is FIXED (`EQGuidanceLayout.rowHeight`) — the footer's own
    /// law one view down: the row keeps its height so the card never reflows
    /// when the user retargets it. `EQInstrumentGuideTests` pins every string
    /// inside the character budget that keeps both lines single.
    ///
    /// NEUTRAL ink, and that is the softness decision made visible: cyan is
    /// earned playback state and green is a live measurement, so a REFERENCE —
    /// published opinion, six of whose thirteen rows the m23-o1 review flagged
    /// as softly sourced — gets neither. It reads as the marker-flag lineage
    /// (navigation furniture, deliberately neutral), never as a readout.
    @ViewBuilder
    private var guidanceRow: some View {
        // `.notApplicable` (master / bus) renders NOTHING, not an empty state:
        // there is no instrument identity to find and no remedy to offer, so a
        // row there would be chrome explaining a question nobody asked.
        if guide.showsRow {
            VStack(alignment: .leading, spacing: 2) {
                Text(guide.headline)
                    .font(.system(size: EQGuidanceLayout.rowFontSize, weight: .semibold))
                    .foregroundStyle(DAWTheme.textSecondary)
                // SF Mono — this line is numbers (the house readout rule).
                Text(guide.detail)
                    .font(.system(size: EQGuidanceLayout.rowFontSize, design: .monospaced))
                    .tracking(0.2)
                    .foregroundStyle(DAWTheme.textDim)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: EQGuidanceLayout.rowHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Instrument frequency guide")
            .accessibilityValue("\(guide.headline). \(guide.detail)")
        }
    }

    // MARK: - The plot (§5.3 stack)

    private var plot: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            // Observation seam: reading the params HERE (through the model →
            // editor → live descriptor) registers the store dependency, so a
            // wire `fx.setParam` moves the curve live — and the spectrum's
            // 60 fps tick never invalidates these layers (it lives inside its
            // own TimelineView below).
            let params = model.params
            let selected = model.selectedBand
            ZStack(alignment: .topLeading) {
                // The three Canvas layers clip to the plot's rounded glass;
                // the handle layer sits OUTSIDE the clip so an OFF HP/LP
                // parked at its 20 Hz/20 kHz range edge (= the plot edge)
                // renders whole, never half-scissored.
                ZStack(alignment: .topLeading) {
                    if showsSpectrum {
                        EQSpectrumLayer(model: model, snapshot: spectrum)
                            // The arm rides the LAYER's identity: it appears
                            // with the layer, re-fires when the card retargets
                            // (`.task(id:)` on the open insert), and is
                            // cancelled — releasing the tap — the moment the
                            // layer leaves (close, retarget, Simple→Pro flip).
                            .task(id: editor.target) { await holdSpectrum() }
                    }
                    EQGridLayer()
                    // The m23-o2 guidance marks: ABOVE the grid so the dashes
                    // are not lost among its hairlines, BELOW the curves so the
                    // cyan composite — the thing the user is actually editing —
                    // always wins. Static: no TimelineView (see the layer).
                    // The layer reports its OWN Canvas width up through
                    // `onPlotWidth` — deliberately NOT `geo.size.width` from
                    // this outer reader, which would be the slot's width and
                    // could silently differ from what the Canvas fills. See the
                    // invariant on `EQGuidanceLayer`.
                    EQGuidanceLayer(guide: guide, onPlotWidth: onPlotWidth)
                    curvesLayer(params: params, selected: selected,
                                width: width, height: height)
                }
                .background(DAWTheme.background.opacity(0.6))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(DAWTheme.hairline, lineWidth: 1))
                .allowsHitTesting(false)
                // The transparent scroll-resolution surface (§5.3): resolves a
                // scroll anywhere over the plot to the hovered ?? selected
                // band's Q; an unclaimed event falls through so Q-scroll never
                // hijacks window scroll (§10).
                EQScrollCatcher { deltaY, fine in
                    guard let band = model.hoveredBand ?? model.selectedBand,
                          EQCurveEditorModel.qParamName(for: band) != nil
                    else { return false }
                    model.scroll(deltaY: deltaY, fine: fine)
                    return true
                }
                if let params {
                    ForEach(EQCurveEditorModel.handles(params: params),
                            id: \.band) { handle in
                        EQBandHandle(
                            model: model,
                            handle: handle,
                            plotWidth: width,
                            plotHeight: height,
                            readout: EQCurveEditorModel.dragReadout(
                                band: handle.band, params: params))
                        .position(EQCurveEditorModel.handleCenter(
                            handle, width: width, height: height))
                    }
                }
            }
        }
        .frame(height: Self.plotHeight)
        // The pre-fader / post-fader labelling law lives headless (and pinned)
        // in EQCurveEditorModel — a master fill and a track fill are different
        // measurements in identical ink, so they never share a caption. This
        // view picks NOTHING: it draws the caption it is handed, which is the
        // same value `debug.effectEditor` reports.
        .help(help)
    }

    /// Layer 3: per-band dim curves + the glowing composite. The point arrays
    /// are computed HERE (main actor, Observation-tracked) and captured by
    /// VALUE into the `@Sendable` renderer — the m16-a contract.
    private func curvesLayer(params: EQParams?, selected: EQCurveEditorModel.Band?,
                             width: Double, height: Double) -> some View {
        let sampleRate = model.sampleRate
        let bandCurves: [(band: EQCurveEditorModel.Band, points: [CGPoint])] =
            params.map { p in
                EQCurveEditorModel.Band.allCases.map { band in
                    (band, EQCurveGeometry.bandCurve(band, params: p, sampleRate: sampleRate,
                                                     width: width, height: height))
                }
            } ?? []
        let composite = params.map { p in
            EQCurveGeometry.compositeCurve(params: p, sampleRate: sampleRate,
                                           width: width, height: height)
        } ?? []
        return Canvas { @Sendable context, _ in
            Self.drawCurves(&context, bandCurves: bandCurves,
                            selected: selected, composite: composite)
        }
    }

    private nonisolated static func drawCurves(
        _ context: inout GraphicsContext,
        bandCurves: [(band: EQCurveEditorModel.Band, points: [CGPoint])],
        selected: EQCurveEditorModel.Band?,
        composite: [CGPoint]
    ) {
        // Per-band curves: dim neutral white; the selected band brightens so
        // the handle you hold reads against its own shape (§5.2).
        for (band, points) in bandCurves {
            let isSelected = band == selected
            context.stroke(
                path(through: points),
                with: .color(DAWTheme.textPrimary.opacity(isSelected ? 0.45 : 0.14)),
                style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1,
                                   lineCap: .round, lineJoin: .round))
        }
        // The composite: playback cyan, bloom-under-core (the glow recipe —
        // wide faint bloom, then a tighter halo, then the crisp core).
        let curve = path(through: composite)
        context.stroke(curve, with: .color(DAWTheme.playback.opacity(0.10)),
                       style: StrokeStyle(lineWidth: 16, lineCap: .round, lineJoin: .round))
        context.stroke(curve, with: .color(DAWTheme.playback.opacity(0.28)),
                       style: StrokeStyle(lineWidth: 6, lineCap: .round, lineJoin: .round))
        context.stroke(curve, with: .color(DAWTheme.playback.opacity(0.95)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
    }

    /// A polyline through dense (256-pt) sample points — dense enough that
    /// line segments read as a smooth curve.
    private nonisolated static func path(through points: [CGPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        for point in points.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }

    // MARK: - Footer (readout chip + the beginner hint, §5.5)

    private var footer: some View {
        HStack(spacing: 8) {
            Text("Drag a handle to shape · ⌥-drag or scroll for width (Q) · double-click a handle to switch its band off")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            // The drag readout chip — SF Mono, present only while a drag is
            // live; the row keeps its height so the card never reflows.
            if let readout = model.dragReadout {
                Text(readout)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(DAWTheme.textPrimary)
                    .padding(.horizontal, 8)
                    .frame(height: 18)
                    .background(DAWTheme.panelRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
            }
        }
        .frame(minHeight: 18)
    }
}

// MARK: - Layer 1: the spectrum (§4.1; every EQ card since m23-r3)

/// The spectrum overlay — the ONLY continuously-redrawing layer, isolated in
/// its own `TimelineView(.periodic)` so the 60 fps tick never invalidates the
/// grid/curves/handle layers (§5.3 structure; §8.4 target). NEVER paused on
/// window-inactive — see `pollInterval` for the law and the measured freeze it
/// prevents. Each frame advances the
/// model's §4.1 smoother by REAL elapsed time (the `VibeSmoother` clock idiom
/// — the smoothed heights are `@ObservationIgnored` scratch, so the mutation
/// schedules no invalidation; the timeline alone drives the next frame) and
/// draws the silhouette as a bottom-anchored signal-green fill.
private struct EQSpectrumLayer: View {
    var model: EQCurveEditorModel
    var snapshot: () -> MasterAnalysisSnapshot

    /// Non-observable frame clock in `@State` — the `VibeSmoother` scratch
    /// pattern: advancing it inside the timeline closure schedules no view
    /// invalidation.
    @State private var clock = EQSpectrumClock()

    /// **Poll discipline — the m22-e LAW** (`ReferencePanelView.swift:26`):
    /// every live layer ticks in its own UNPAUSED periodic `TimelineView`, and
    /// NEVER `.animation(paused: controlActiveState == .inactive)`. This layer
    /// carried that forbidden idiom from m22-b, which predates the law — and it
    /// froze exactly as the law predicts: with the app not frontmost the
    /// smoother never advanced, so the fill sat at the floor while the tap was
    /// armed and reading. **That is user-visible, not merely a test problem** —
    /// this app is driven over a control socket by agents, so its window is
    /// routinely NOT the active one, and a frozen spectrum under a live curve
    /// is the dishonest-readout failure this project keeps closing.
    /// (m23-r3; found by the m23-r3 gate's own liveness preconditions, whose
    /// `masterSeed` reading proved the freeze independent of any audio.)
    ///
    /// 60 Hz, not the reference panel's 10 Hz: the EQ card is a MODAL that
    /// exists only while its insert is being edited, so the cost is bounded and
    /// short-lived, and m22-b's motion quality is a pinned design property.
    private static let pollInterval = 1.0 / 60

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.pollInterval)) { timeline in
            // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value
            // captures only, computed before the closure (the point buffer is
            // the VibeMeterView small-per-frame-buffer precedent).
            let points = advanceFrame(to: timeline.date)
            Canvas { @Sendable context, size in
                Self.drawSpectrum(&context, size: size, points: points)
            }
        }
        .accessibilityHidden(true)   // context, not a readout (§4.1)
    }

    /// One frame: poll the snapshot, advance the model's smoother by the real
    /// elapsed time, and hand back the drawable silhouette points.
    private func advanceFrame(to date: Date) -> [CGPoint] {
        model.updateSpectrum(with: snapshot(), deltaTime: clock.advance(to: date))
        // Width/height are resolved inside the Canvas closure via `size`; the
        // points are built in NORMALIZED plot space here and scaled there —
        // no GeometryReader dependency for the hot layer.
        return EQCurveEditorModel.spectrumPathPoints(
            heights: model.spectrumHeights, width: 1, height: 1)
    }

    private nonisolated static func drawSpectrum(_ context: inout GraphicsContext,
                                                 size: CGSize, points: [CGPoint]) {
        guard points.count > 2 else { return }
        // Scale the normalized silhouette to the live plot size, smoothing
        // band steps with midpoint quad curves (the VibeMeterView idiom).
        func at(_ i: Int) -> CGPoint {
            CGPoint(x: points[i].x * size.width, y: points[i].y * size.height)
        }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        var top = Path()
        top.move(to: at(0))
        for i in 1..<points.count - 1 {
            top.addQuadCurve(to: mid(at(i), at(i + 1)), control: at(i))
        }
        top.addLine(to: at(points.count - 1))
        // Bottom-anchor the fill at the TRUE band edges (§4.1 honesty).
        var fill = top
        fill.addLine(to: CGPoint(x: at(points.count - 1).x, y: size.height))
        fill.addLine(to: CGPoint(x: at(0).x, y: size.height))
        fill.closeSubpath()
        // Signal green at low opacity — live-signal context under the curve,
        // with a faint top edge so the silhouette reads without weight.
        context.fill(fill, with: .color(DAWTheme.signal.opacity(0.12)))
        context.stroke(top, with: .color(DAWTheme.signal.opacity(0.30)), lineWidth: 1)
    }
}

/// Non-observable frame clock (the `VibeSmoother` dt logic verbatim): real
/// elapsed time, capped so a stalled/paused frame can't snap the smoother.
private final class EQSpectrumClock {
    private var lastDate: Date?

    func advance(to date: Date) -> Double {
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? (1.0 / 60)
        lastDate = date
        return dt
    }
}

// MARK: - Layer 1b: the instrument frequency guide (m23-o2)

/// m23-o1's cited reference, drawn against the live curve: the instrument's
/// fundamental range as a soft region, and its recommended high-pass /
/// low-pass corners as dashed verticals — so a beginner can SEE whether the
/// corner they are dragging sits below the instrument or inside it.
///
/// **NO TIMELINEVIEW, deliberately.** A reference row does not change 60 times
/// a second, so this Canvas redraws only when its size or its `guide` value
/// changes. The m22-e poll discipline says every LIVE layer ticks in its own
/// UNPAUSED `.periodic` timeline; it does not say every layer gets one, and
/// adding a timer here "for symmetry" would spend a frame budget on a picture
/// that never moves. (The spectrum layer above genuinely is live and keeps its
/// own 60 Hz timeline; nothing here is paused, because nothing here ticks.)
///
/// **THE INK IS THE SOFTNESS DECISION.** Everything this layer draws is DASHED
/// and NEUTRAL — no cyan (earned playback/active state), no green (a live
/// measurement), no violet (AI content, and this table is cited human research,
/// not generated). The saturated colours on this plot all belong to things that
/// are true right now about THIS track; guidance is published opinion about a
/// KIND of instrument, six of whose thirteen rows the m23-o1 review flagged as
/// softly sourced. So no guidance mark is ever drawn in a way that could be
/// mistaken for a measurement, and none is drawn with a hard edge. The
/// per-fact caveat that dashes cannot express — "a drum's pitch is a tuning
/// choice" — is carried in words by the guidance row below the plot.
///
/// Every position comes from `EQInstrumentGuide`, which computes it through
/// `EQCurveGeometry` — the plot's ONE axis, the same one the grid, the handles
/// and the spectrum use. There is no second mapping here and no `if`: this
/// view draws the marks it is handed, and an empty list draws nothing.
private struct EQGuidanceLayer: View {
    var guide: EQInstrumentGuide
    /// Reports THIS CANVAS'S OWN laid-out width — see the invariant below.
    var onPlotWidth: (Double) -> Void

    var body: some View {
        // Value-captured before the @Sendable renderer (the m16-a contract).
        let marks = guide.marks
        Canvas { @Sendable context, size in
            Self.draw(&context, size: size, marks: marks)
        }
        // ─────────────────────────────────────────────────────────────────
        // ⚠️ THE REPORTED WIDTH MUST BE THIS CANVAS'S OWN, NEVER THE SLOT'S.
        //
        // `debug.effectEditor` reports x positions computed at the width this
        // closure hands up. `draw` above lays every mark out from the Canvas
        // renderer's `size.width`. Those two MUST be the same rectangle, and
        // the only way to guarantee it is to measure the Canvas ITSELF — which
        // is what a `GeometryReader` in its `.background` does: the background
        // is handed exactly the Canvas's laid-out frame.
        //
        // THE VERSION THIS REPLACED WAS WRONG, AND WRONG INVISIBLY. It read
        // `geo.size.width` from the plot's outer `GeometryReader` and reported
        // that. The two agreed only because this layer sat in the ZStack with
        // no `.frame` and no padding — SwiftUI layout inheritance, stated
        // nowhere and enforced by nothing. Adding `.padding(.horizontal, 20)`
        // to this layer for aesthetics made the Canvas draw 40 pt narrower
        // while the probe kept sincerely reporting the outer 528: every mark
        // ~20 pt off on screen, with the payload internally consistent and a
        // staging gate fully green. A gate CANNOT catch that — it can only read
        // what the probe reports, and the probe was reporting a number that was
        // honestly measured and simply not the one drawn at.
        //
        // So: if you inset, reframe or pad this lane, do it and change nothing
        // else — both halves move together now, because they are one read.
        // Do NOT hoist this measurement back out to the caller.
        //
        // The callback fires from the BACKGROUND view's modifier, not from
        // inside the `@Sendable` renderer — the m16-a contract forbids touching
        // the main actor there.
        // ─────────────────────────────────────────────────────────────────
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size.width, initial: true) { _, measured in
                        onPlotWidth(Double(measured))
                    }
            }
        }
        // Context under the curve, and every word of it is repeated as real
        // text in the guidance row — which is the accessible surface.
        .accessibilityHidden(true)
    }

    private nonisolated static func draw(
        _ context: inout GraphicsContext, size: CGSize,
        marks: [EQInstrumentGuide.Mark]
    ) {
        let width = Double(size.width)
        let height = Double(size.height)
        guard width > 0, height > 0, !marks.isEmpty else { return }
        // ⚠️ ONE WIDTH FOR BOTH COORDINATE SPACES. The tags are laid out from the
        // SAME `size.width` the marks are drawn from, inside this closure —
        // never from `EQGuidanceLayout.contentWidth` outside it. Those two are
        // equal today only because the card is a fixed 560 pt frame; deriving
        // the tag lane from the constant while the lines came from the live size
        // is the dual-coordinate-space bug where "the bracket is at the right
        // Hz" stays true while "the tag is over the bracket" quietly stops being.
        // `EQGridLayer` calls `EQCurveGeometry.x(forFrequency:in:)` inside its
        // own closure for the same reason.
        let placements = EQInstrumentGuide.placements(marks, width: width)
        let dashed = StrokeStyle(lineWidth: 1, dash: [3, 3])

        for mark in marks {
            if let span = EQInstrumentGuide.spanX(mark, width: width) {
                // The fundamental region: a barely-there wash between two
                // dashed edges. A FILLED confident block here would be a strong
                // claim about a number that is, for three of these rows, a
                // tuning choice.
                context.fill(
                    Path(CGRect(x: span.lo, y: 0,
                                width: span.hi - span.lo, height: height)),
                    with: .color(DAWTheme.textFaint.opacity(0.07)))
                for x in [span.lo, span.hi] {
                    context.stroke(verticalPath(x: x, height: height),
                                   with: .color(DAWTheme.textSecondary.opacity(0.30)),
                                   style: dashed)
                }
                // A rule tying the two edges together so the pair reads as ONE
                // range, seated below both label lanes so it never crosses a tag.
                var rule = Path()
                let y = EQGuidanceLayout.cornerLaneY + 12
                rule.move(to: CGPoint(x: span.lo, y: y))
                rule.addLine(to: CGPoint(x: span.hi, y: y))
                context.stroke(rule, with: .color(DAWTheme.textSecondary.opacity(0.30)),
                               style: dashed)
            } else if let x = EQInstrumentGuide.cornerX(mark, width: width) {
                // A recommended corner: one dashed vertical, full height, so it
                // reads against the handle the user is dragging toward it.
                context.stroke(verticalPath(x: x, height: height),
                               with: .color(DAWTheme.textSecondary.opacity(0.38)),
                               style: dashed)
            }
        }

        // The tags. Two lanes in the plot's TOP strip — the only region that is
        // reliably free (the grid's frequency numbers own the bottom ~14 pt and
        // the six band handles own the vertical middle).
        for placement in placements {
            context.draw(
                Text(placement.text)
                    .font(.system(size: EQGuidanceLayout.tagFontSize,
                                  weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.textSecondary),
                at: CGPoint(x: placement.x, y: placement.y),
                anchor: anchor(for: placement.anchor))
        }
    }

    private nonisolated static func verticalPath(x: Double, height: Double) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: x, y: 0))
        path.addLine(to: CGPoint(x: x, y: height))
        return path
    }

    /// The model's anchor vocabulary → SwiftUI's. The lane y is the tag's TOP,
    /// so every case hangs the text downward from its lane.
    private nonisolated static func anchor(
        for anchor: EQInstrumentGuide.Placement.Anchor
    ) -> UnitPoint {
        switch anchor {
        case .leading: return .topLeading
        case .center: return .top
        case .trailing: return .topTrailing
        }
    }
}

// MARK: - Layer 2: the grid (§5.1)

/// The static plot grid: horizontal hairlines every 6 dB (0 dB center
/// emphasized), vertical decade marks, SF Mono dim labels — "100", "1k",
/// "10k", never scientific notation (the beginner rule). No captured state,
/// so SwiftUI redraws it only when the size changes.
private struct EQGridLayer: View {
    var body: some View {
        Canvas { @Sendable context, size in
            EQGridLayer.drawGrid(&context, size: size)
        }
    }

    private nonisolated static func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        let width = Double(size.width)
        let height = Double(size.height)
        // Horizontal dB hairlines (±6/±12/±18 labeled; 0 dB is the drawn
        // center line and carries no label).
        for db in EQCurveGeometry.dbGridLines {
            let y = EQCurveGeometry.y(forDb: db, in: height)
            var line = Path()
            line.move(to: CGPoint(x: 0, y: y))
            line.addLine(to: CGPoint(x: width, y: y))
            context.stroke(
                line,
                with: .color(db == 0 ? DAWTheme.gridEmphasis : DAWTheme.hairline),
                lineWidth: 1)
            if let label = EQCurveGeometry.dbGridLabel(db) {
                context.draw(
                    Text(label)
                        .font(.system(size: 8, weight: .medium, design: .monospaced))
                        .foregroundStyle(DAWTheme.textDim.opacity(0.8)),
                    at: CGPoint(x: 4, y: y - 1), anchor: .bottomLeading)
            }
        }
        // Vertical frequency hairlines at the decade marks.
        for hz in EQCurveGeometry.frequencyGridLines {
            let x = EQCurveGeometry.x(forFrequency: hz, in: width)
            var line = Path()
            line.move(to: CGPoint(x: x, y: 0))
            line.addLine(to: CGPoint(x: x, y: height))
            context.stroke(line, with: .color(DAWTheme.hairline), lineWidth: 1)
            let label = Text(EQCurveGeometry.frequencyGridLabel(hz))
                .font(.system(size: 8, weight: .medium, design: .monospaced))
                .foregroundStyle(DAWTheme.textDim.opacity(0.8))
            // Anchor the edge labels inward so nothing clips at the plot rim.
            if hz == EQCurveGeometry.frequencyRange.lowerBound {
                context.draw(label, at: CGPoint(x: x + 3, y: height - 3), anchor: .bottomLeading)
            } else if hz == EQCurveGeometry.frequencyRange.upperBound {
                context.draw(label, at: CGPoint(x: x - 3, y: height - 3), anchor: .bottomTrailing)
            } else {
                context.draw(label, at: CGPoint(x: x + 3, y: height - 3), anchor: .bottomLeading)
            }
        }
    }
}

// MARK: - Layer 4: one band handle (§5.2)

/// One draggable band handle: a 12 pt dot (dim hollow ring when the band is
/// OFF) + SF Mono micro-tag, inside a generous 28 pt hit target. Rest =
/// neutral; hovered = bright; dragged/selected = cyan + glow (earned active
/// state); disabled = dim hollow. Drag = freq(x)+gain(y); ⌥-drag vertical =
/// Q; ⇧ = fine; double-click = band on/off — ALL through the model's tested
/// delta methods (never inline math here).
private struct EQBandHandle: View {
    var model: EQCurveEditorModel
    var handle: EQCurveEditorModel.Handle
    var plotWidth: Double
    var plotHeight: Double
    /// The band's current readout string (the drag chip's format) — the
    /// accessibility value, so VoiceOver reads what the chip shows.
    var readout: String

    @State private var hovering = false
    @State private var dragging = false

    var body: some View {
        let isSelected = model.selectedBand == handle.band
        let isActive = dragging || isSelected
        let dotColor: Color = !handle.isEnabled
            ? DAWTheme.textDim.opacity(hovering ? 0.9 : 0.6)
            : isActive ? DAWTheme.playback
            : DAWTheme.textPrimary.opacity(hovering ? 1.0 : 0.72)
        ZStack {
            if handle.isEnabled {
                Circle()
                    .fill(dotColor)
                    .frame(width: 12, height: 12)
            } else {
                // The dim hollow ring — an OFF band parked at its resolved
                // position (§5.2), still grabbable to re-enable.
                Circle()
                    .stroke(dotColor, lineWidth: 1.5)
                    .frame(width: 11, height: 11)
            }
            Text(handle.tag)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(handle.isEnabled ? dotColor : DAWTheme.textDim)
                .offset(y: -13)
        }
        .frame(width: EQCurveEditorModel.hitRadius, height: EQCurveEditorModel.hitRadius)
        .contentShape(Circle())
        // Glow earned by interaction state — never static chrome.
        .glow(DAWTheme.playback, radius: 6, intensity: isActive && handle.isEnabled ? 0.55 : 0)
        // A handle is a movable body: open hand at rest, closed while
        // dragging (docs/DESIGN-LANGUAGE.md "Pointer affordances").
        .hoverCursor(.grab)
        .onHover { inside in
            hovering = inside
            if inside {
                model.hoveredBand = handle.band
            } else if model.hoveredBand == handle.band {
                model.hoveredBand = nil
            }
        }
        // Double-click = band on/off — simultaneous with the drag (the
        // KnobControl reset idiom; a two-click never travels, so the zero-
        // translation drag ticks it also fires are position no-ops).
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.toggleEnabled(handle.band)
        })
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    DragCursor.set(.grabbing)
                    if !dragging {
                        dragging = true
                        model.beginDrag(handle.band)
                    }
                    let flags = NSEvent.modifierFlags
                    model.updateDrag(
                        translationX: value.translation.width,
                        translationY: value.translation.height,
                        width: plotWidth, height: plotHeight,
                        adjustQ: flags.contains(.option),
                        fine: flags.contains(.shift))
                }
                .onEnded { _ in
                    dragging = false
                    model.endDrag()
                    DragCursor.clear()
                }
        )
        .help(helpText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(EQCurveEditorModel.bandName(handle.band))
        .accessibilityValue(handle.isEnabled ? readout : "\(readout), off")
    }

    private var helpText: String {
        let name = EQCurveEditorModel.bandName(handle.band)
        if EQCurveEditorModel.qParamName(for: handle.band) == nil {
            return "\(name) — drag left or right to set the corner; double-click to switch it on or off."
        }
        return "\(name) — drag to set frequency and gain; ⌥-drag or scroll for width (Q); ⇧ for fine moves; double-click to switch it on or off."
    }
}

// MARK: - The band strip (§5.5)

/// Six compact band cells under the plot: micro-tag + name, the ON toggle
/// (the m22-a toggle idiom), and — for HP/LP — the 12/24 slope chip (the
/// knob card's chip reused). Clicking a cell selects its band (one shared
/// `selectedBand` property with the handles — sync by construction).
private struct EQBandStrip: View {
    var editor: EffectEditorModel
    var model: EQCurveEditorModel

    var body: some View {
        let specs = EffectParamSpec.specs(for: .eq)
        HStack(alignment: .top, spacing: 6) {
            ForEach(EQCurveEditorModel.Band.allCases, id: \.self) { band in
                cell(band, specs: specs)
            }
        }
    }

    private func cell(_ band: EQCurveEditorModel.Band,
                      specs: [EffectParamSpec]) -> some View {
        let isSelected = model.selectedBand == band
        let isOn = model.params.map { EQCurveEditorModel.isEnabled(band, in: $0) } ?? true
        return VStack(spacing: 5) {
            HStack(spacing: 4) {
                Text(EQCurveEditorModel.tag(for: band))
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.5)
                    .foregroundStyle(isSelected ? DAWTheme.playback : DAWTheme.textDim)
                Text(EQCurveEditorModel.bandName(band))
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(isOn ? DAWTheme.textSecondary : DAWTheme.textDim)
                    .lineLimit(1)
            }
            HStack(spacing: 4) {
                onToggle(band, isOn: isOn)
                if let slopeName = EQCurveEditorModel.slopeParamName(for: band),
                   let slopeSpec = specs.first(where: { $0.name == slopeName }) {
                    slopeChip(band, spec: slopeSpec)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(isSelected ? DAWTheme.panelRaised : DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(
            isSelected ? DAWTheme.playback.opacity(0.45) : DAWTheme.hairline, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture { model.selectedBand = band }
        .help("\(EQCurveEditorModel.bandName(band)) — click to select its handle.")
    }

    /// The m22-a ON toggle idiom (the knob card's `toggleCell` chip, sized
    /// for the strip): cyan-lit = the band shapes sound, dim = off. Routes
    /// through the model's toggle (which also selects the band, §5.5).
    private func onToggle(_ band: EQCurveEditorModel.Band, isOn: Bool) -> some View {
        Button {
            model.toggleEnabled(band)
        } label: {
            Text(isOn ? "ON" : "OFF")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(isOn ? DAWTheme.playback : DAWTheme.textDim)
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(isOn ? DAWTheme.playback.opacity(0.18) : DAWTheme.panelRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(
                    isOn ? DAWTheme.playback.opacity(0.5) : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("\(EQCurveEditorModel.bandName(band)) — click to switch on or off.")
        .accessibilityValue(isOn ? "on" : "off")
    }

    /// The m22-a HP/LP SLOPE chip (the knob card's `slopeCell` reused, strip-
    /// sized): a TWO-STATE 12/24 dB/oct flip through the SAME `set` path.
    /// Neutral chrome — slope is a tone-shaping choice, not a level.
    private func slopeChip(_ band: EQCurveEditorModel.Band,
                           spec: EffectParamSpec) -> some View {
        let is24 = EffectEditorModel.slopeIs24(editor.value(for: spec))
        return Button {
            model.selectedBand = band
            editor.set(name: spec.name, value: is24 ? 12 : 24)
        } label: {
            Text(is24 ? "24" : "12")
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(DAWTheme.textPrimary)
                .padding(.horizontal, 7)
                .frame(height: 16)
                .background(DAWTheme.panelRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Slope — click to switch between 12 and 24 dB per octave.")
        .accessibilityValue(is24 ? "24 dB per octave" : "12 dB per octave")
    }
}

// MARK: - The scroll-resolution surface

/// A transparent AppKit-backed surface that resolves scroll-wheel events over
/// the plot to the Q law (§5.2) WITHOUT ever claiming mouse events: it
/// hit-tests to nil (handles above and the scrim behind keep their gestures)
/// and listens via a local `.scrollWheel` event monitor scoped to its own
/// window + bounds. `onScroll` returns whether the event was claimed — an
/// unclaimed event is returned to AppKit untouched, so plot scroll never
/// hijacks window scrolling (§10; the fall-through law).
private struct EQScrollCatcher: NSViewRepresentable {
    /// (scrollingDeltaY, ⇧ fine) → claimed?
    var onScroll: (Double, Bool) -> Bool

    func makeNSView(context: Context) -> CatcherView {
        let view = CatcherView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: CatcherView, context: Context) {
        nsView.onScroll = onScroll
    }

    final class CatcherView: NSView {
        var onScroll: (Double, Bool) -> Bool = { _, _ in false }
        private var monitor: Any?

        /// NEVER claims mouse events — scroll arrives via the monitor only.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                removeMonitor()
                return
            }
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) {
                [weak self] event in
                guard let self, let window = self.window, event.window === window
                else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }
                let fine = event.modifierFlags.contains(.shift)
                // Claimed → swallow; unclaimed → fall through untouched.
                return self.onScroll(event.scrollingDeltaY, fine) ? nil : event
            }
        }

        private func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
