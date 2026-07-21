import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// The EQ FREQUENCY-CURVE editor surface (m22-b Phase 3, design
/// docs/research/design-m22b-eq-curve-editor.md §4/§5): the eq card's Simple
/// density — direct manipulation on the response curve itself, over the
/// exact §5.3 four-layer stack. Bottom → top inside the plot:
///
/// 1. **Spectrum Canvas** (master-chain EQ ONLY — a track EQ draws an ABSENT
///    layer, never a fake one): its own `TimelineView(.animation)` paused
///    when the window is inactive, fed by the injected snapshot closure
///    (`appModel.vibeSeed ?? store.masterAnalysis()`, the `VibeMeterView`
///    pattern verbatim), display-smoothed by the model's §4.1 asymmetric
///    one-pole, bands drawn at their TRUE 40 Hz–16 kHz geometric edges as a
///    bottom-anchored filled path. Signal-green at low opacity — live healthy
///    signal semantics, context under the curve, never a measurement readout.
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
    /// Master-chain gate (§4.1): true iff `editor.target?.trackID == nil`.
    /// Track-strip EQ editors draw NO spectrum in v1 — display honesty.
    var showsSpectrum: Bool
    /// Polled once per spectrum frame — `appModel.vibeSeed ??
    /// store.masterAnalysis()` in the app, a fake in previews. A closure, so
    /// no engine coupling here (the `VibeMeterView` seam).
    var spectrum: () -> MasterAnalysisSnapshot

    /// The plot's fixed height (§6: plot ≈ 528×260 inside the 560 pt card).
    private static let plotHeight: CGFloat = 260

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            plot
            EQBandStrip(editor: editor, model: model)
            footer
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
                    }
                    EQGridLayer()
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
        .help(showsSpectrum
              ? "The green fill is the live master-mix spectrum — context only; its height is not the EQ's dB scale."
              : "Drag a handle to shape the EQ curve.")
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

// MARK: - Layer 1: the spectrum (master EQ only, §4.1)

/// The spectrum overlay — the ONLY continuously-redrawing layer, isolated in
/// its own `TimelineView(.animation)` so the 60 fps tick never invalidates the
/// grid/curves/handle layers (§5.3 structure; §8.4 target). Paused when the
/// window is inactive (the `VibeMeterView` guidance). Each frame advances the
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

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        TimelineView(.animation(paused: controlActiveState == .inactive)) { timeline in
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
