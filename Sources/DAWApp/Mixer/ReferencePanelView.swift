import SwiftUI
import AppKit
import DAWCore
import DAWAppKit

/// The **REFERENCE panel** (m22-g P3, design-m22g-reference-tracks §7.2): the
/// dedicated surface for comparing the mix against a finished record the user
/// trusts. Another instance of the named centered dark-glass modal over a
/// dimmed scrim (Settings / Instrument Picker / Quantize / Undo History /
/// Effect Editor) — an IN-WINDOW card, never a popover or child NSWindow, so
/// `debug.captureUI` can snapshot it (the captureUI law).
///
/// **NO VIOLET anywhere** (DESIGN-LANGUAGE Rule 3): a reference is user-chosen
/// material, not AI content — the header wears a neutral waveform glyph and
/// the card has no violet edge, deliberately unlike the Sketchpad/ClipFix/Voice
/// family. Cyan marks the earned ACTIVE state (monitoring, and the SF Mono
/// numeric readouts); amber marks the honest ceiling clamp; red appears only on
/// the armed REMOVE confirmation.
///
/// Anatomy top→bottom (§7.2): header · empty-state invitation OR the loaded
/// file line with quiet REPLACE/REMOVE · the shared MIX|REF A/B cluster with
/// the match-gain readout and its plain-language basis line · OFFSET/TRIM
/// steppers · the two-curve SPECTRUM overlay · the DELTA row with its beginner
/// sub-caption.
///
/// **Poll discipline — the m22-e LAW**: every live layer ticks in its own
/// UNPAUSED `.periodic` `TimelineView`. NEVER
/// `.animation(paused: controlActiveState == .inactive)`: that idiom froze the
/// m22-e meters solid in an unfocused/control-driven app, and this panel is the
/// same shape and the same risk (a capture agent's app is never frontmost).
///
/// **Density: COINCIDENT by design** — no SIMPLE/PRO chip. Every control here
/// is load-bearing for the one job the panel does; a chip that hid the spectrum
/// or the deltas would hide the comparison itself, and a chip that changed
/// nothing is worse than none (the "never a do-nothing toggle" rule; verdict
/// recorded in docs/research/simple-pro-inventory.md).
struct ReferencePanelView: View {
    var model: ReferencePanelModel
    /// Resolved at the call site — the `debug.referenceSeed` staging override
    /// when present, else the live `liveLoudness` + `masterAnalysis` polls (the
    /// `scopeSeed` / `grSeed` idiom).
    var compare: () -> ReferenceCompareResult?
    var onClose: () -> Void

    /// 560 pt wide — the EQ curve card's exact width (the app's OTHER 24-band
    /// spectrum surface), so the two spectra read at the same scale. See the
    /// height note on `cardMaxHeight`.
    private static let cardWidth: CGFloat = 560
    /// The card hugs its content and caps here. §7.2 proposed 420 pt before the
    /// anatomy was laid out; measured, the seven blocks need ≈480 pt (a 180 pt
    /// spectrum alone is 43 % of 420). 520 keeps the card inside the 640 pt
    /// window floor with ≈60 pt of scrim above and below, and under the
    /// `EffectEditorOverlay` 560 pt modal cap.
    private static let cardMaxHeight: CGFloat = 520
    /// §7.2 point 6: the spectrum well at its designed height…
    private static let spectrumHeight: CGFloat = 180
    /// …and the floor it compresses to when the card also has to carry the
    /// file-missing banner and/or a refusal strip.
    private static let spectrumMinHeight: CGFloat = 108

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
                .frame(width: Self.cardWidth)
                .frame(maxHeight: Self.cardMaxHeight)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
        .explainable(.referencePanel)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider().overlay(DAWTheme.hairline)
            if let refusal = model.refusal {
                refusalStrip(refusal)
            }
            switch model.phase {
            case .empty:
                emptyState
            case .importing, .analyzing:
                busyState
            case .fileMissing:
                fileMissingState
                loadedBody
            case .ready:
                loadedBody
            }
        }
        .padding(14)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Header (§7.2 point 1)

    private var header: some View {
        HStack(spacing: 8) {
            // A NEUTRAL waveform glyph — this is a record, not AI output.
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textSecondary)
            Text("REFERENCE")
                .font(.system(size: 11, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textPrimary)
            if let name = model.slot?.name {
                Text(name)
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 6)
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
            .help("Close the reference panel")
        }
    }

    /// Store refusals reach the user WORD FOR WORD on amber chrome (the
    /// refusal-bubble one-vocabulary law) — never re-worded, never swallowed.
    private func refusalStrip(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DAWTheme.record)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 4)
            Button { model.clearRefusal() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(DAWTheme.record.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(DAWTheme.record.opacity(0.45), lineWidth: 1))
    }

    // MARK: - Empty / busy / missing states (§7.2 point 2)

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compare your mix against a finished song you trust.")
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textSecondary)
            Text("The reference is copied into the project, measured once, and "
                 + "kept out of every export. It is never a track in your mixer.")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Button(action: chooseFile) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .bold))
                    Text("IMPORT REFERENCE…")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.8)
                }
                .foregroundStyle(DAWTheme.playback)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(DAWTheme.playback.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .stroke(DAWTheme.playback.opacity(0.4), lineWidth: 1))
            }
            .buttonStyle(.plain)
            .help("Choose a finished song to mix against. The file is copied, never moved.")
        }
        // No trailing Spacer: the card HUGS this state (the EffectEditorOverlay
        // hugging rule). A greedy spacer padded the invitation out to the full
        // 520 pt cap with ~340 pt of dead glass under it — caught in the P3
        // pixel review.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var busyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(model.busy == .importing
                     ? "Copying and measuring the reference…"
                     : "Measuring the reference…")
                    .font(.system(size: 12))
                    .foregroundStyle(DAWTheme.textSecondary)
            }
            Text("This runs once. The numbers are saved with the project.")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Honest absence (§3.3): the slot and its measurements survive a missing
    /// file — the panel says which file is gone and names the fix, and the A/B
    /// below stays visible but will refuse with the store's own words.
    private var fileMissingState: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "questionmark.folder")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DAWTheme.record)
            VStack(alignment: .leading, spacing: 2) {
                Text("The reference file is not where the project left it.")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textSecondary)
                Text(model.slot?.sourcePath ?? "")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(DAWTheme.textFaint)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text("Import it again to hear it; the measurements below are kept.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.record.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Loaded body

    @ViewBuilder
    private var loadedBody: some View {
        fileLine
        abCluster
        Divider().overlay(DAWTheme.hairline)
        offsetTrimRow
        Divider().overlay(DAWTheme.hairline)
        spectrumBlock
        deltaBlock
    }

    /// §7.2 point 3 — name + facts, with quiet REPLACE / REMOVE verbs. REMOVE
    /// turns red only once armed (the in-row hover-confirm idiom — never a
    /// system alert).
    private var fileLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.slot?.name ?? "")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(ReferencePanelModel.fileFactsLine(model.slot?.analysis))
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DAWTheme.textDim)
            }
            Spacer(minLength: 6)
            if model.needsAnalysis {
                quietVerb("ANALYZE", tint: DAWTheme.playback) {
                    Task { await model.runAnalyze() }
                }
            }
            quietVerb("REPLACE", tint: DAWTheme.textDim, action: chooseFile)
            if model.confirmingRemove {
                quietVerb("REMOVE?", tint: DAWTheme.clip) { model.requestRemove() }
                Button { model.cancelRemove() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .buttonStyle(.plain)
            } else {
                quietVerb("REMOVE", tint: DAWTheme.textDim) { model.requestRemove() }
            }
        }
    }

    private func quietVerb(_ title: String, tint: Color,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(tint)
                .padding(.horizontal, 7)
                .frame(height: 18)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(tint.opacity(0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    /// §7.2 point 4 — the shared MIX|REF chip, the match-gain readout, and the
    /// plain-language basis line. Polled at 5 Hz (the LOUDNESS readout cadence)
    /// in its own UNPAUSED `.periodic` timeline: the monitor state and the
    /// match gain both move from the wire, so a control-driven app must see
    /// them change without being frontmost.
    private var abCluster: some View {
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let status = model.status
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ReferenceABToggle(isMonitoring: status.monitoring, height: 22) {
                        model.setMonitor($0)
                    }
                    .explainable(.referenceABToggle)
                    matchGainReadout(status)
                    Spacer(minLength: 0)
                }
                Text(ReferencePanelModel.basisLine(status))
                    .font(.system(size: 10))
                    .foregroundStyle(status.ceilingLimited == true
                                     ? DAWTheme.record : DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Cyan while monitoring (a dB readout is cyan), AMBER when the ceiling
    /// clamp reduced it — the honest "you are not hearing a full match" cue.
    private func matchGainReadout(_ status: ReferenceStatus) -> some View {
        let db = ReferencePanelModel.displayedMatchGainDb(status)
        let clamped = status.ceilingLimited == true
        let tint: Color = db == nil ? DAWTheme.textFaint
            : (clamped ? DAWTheme.record : DAWTheme.playback)
        return HStack(spacing: 3) {
            Text(ReferencePanelModel.matchGainText(db))
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint)
                .glow(tint, radius: 4, intensity: db == nil ? 0 : 0.4)
            if db != nil {
                Text("dB")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DAWTheme.textDim)
            }
        }
        .help(clamped
              ? "The reference was turned down further than a level match asks for, so it cannot clip."
              : "How much the reference is turned up or down to sit at your mix's loudness.")
    }

    // MARK: - OFFSET / TRIM (§7.2 point 5)

    private var offsetTrimRow: some View {
        HStack(alignment: .top, spacing: 18) {
            stepper(label: "OFFSET",
                    value: ReferencePanelModel.offsetText(model.slot?.offsetSeconds ?? 0),
                    unit: "s",
                    caption: "Line the reference's chorus up with yours.",
                    onStep: { model.nudgeOffset($0) })
            stepper(label: "TRIM",
                    value: ReferencePanelModel.trimText(model.slot?.trimDb ?? 0),
                    unit: "dB",
                    caption: "Your own nudge on top of the level match.",
                    onStep: { model.nudgeTrim($0) })
        }
    }

    private func stepper(label: String, value: String, unit: String,
                         caption: String, onStep: @escaping (Int) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.textDim)
            HStack(spacing: 4) {
                stepButton("minus") { onStep(-1) }
                HStack(spacing: 2) {
                    Text(value)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DAWTheme.playback)
                        .frame(minWidth: 46, alignment: .trailing)
                    Text(unit)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                stepButton("plus") { onStep(1) }
            }
            Text(caption)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func stepButton(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DAWTheme.textSecondary)
                .frame(width: 20, height: 20)
                .background(DAWTheme.panelRaised)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Spectrum overlay (§7.2 point 6)

    private var spectrumBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("SPECTRUM")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textDim)
                Spacer(minLength: 0)
                legend(color: DAWTheme.textPrimary, text: "REFERENCE (whole song)")
                // "recent average" is a PROMISE — the mix curve really is an
                // exponential average (tau 2.5 s), never a ballistic snapshot
                // wearing an average's label (§7.2 honesty note).
                legend(color: DAWTheme.playback, text: "MIX (recent average)")
            }
            ZStack {
                // Layer 1: the static well + grid + its frequency labels —
                // tick-free Canvas, never glowing (the "never glow static
                // chrome" rule). The LABELS are drawn in this same Canvas at
                // each line's own log x: an evenly-spaced label row underneath
                // sat visibly off its gridlines (P3 pixel review), and a
                // frequency label that doesn't point at its own line is a lie
                // about where the energy is.
                Canvas { @Sendable context, size in
                    Self.drawGrid(&context, size: size)
                }
                // Layer 2: the two curves — the ONLY redrawing layer, in its
                // own UNPAUSED periodic timeline (the m22-e law).
                ReferenceSpectrumLayer(model: model)
            }
            // FLEXIBLE, not fixed: when the file-missing banner (or a refusal
            // strip, or both) joins the card, the spectrum yields height
            // instead of pushing the delta caption past the clip shape — the
            // overflow the P3 pixel review caught on the fileMissing leg.
            .frame(minHeight: Self.spectrumMinHeight, maxHeight: Self.spectrumHeight)
            .background(Color.black.opacity(0.25))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
            .explainable(.referenceSpectrum)
        }
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color)
                .frame(width: 10, height: 2)
            Text(text)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(DAWTheme.textFaint)
        }
    }

    private nonisolated static func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        for hz in ReferenceSpectrumGeometry.frequencyGridHz {
            let x = ReferenceSpectrumGeometry.x(forFrequency: hz, in: size.width)
            var path = Path()
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height - ReferenceSpectrumMetrics.axisLabelStrip))
            context.stroke(path, with: .color(DAWTheme.hairline), lineWidth: 1)
            // The label sits ON its own line's x (SF Mono, `textFaint`,
            // beginner-readable "1k" — never scientific notation).
            let label = Text(ReferenceSpectrumGeometry.frequencyLabel(hz))
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .foregroundStyle(DAWTheme.textFaint)
            context.draw(label, at: CGPoint(x: x, y: size.height - ReferenceSpectrumMetrics.axisLabelStrip / 2),
                         anchor: .center)
        }
        for db in stride(from: -66.0, through: -12.0, by: 18.0) {
            let y = ReferenceSpectrumGeometry.y(
                forDb: db, in: size.height - ReferenceSpectrumMetrics.axisLabelStrip)
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(DAWTheme.hairline), lineWidth: 1)
        }
    }

    // MARK: - Delta row (§7.2 point 7)

    private var deltaBlock: some View {
        // 5 Hz, unpaused (the LOUDNESS readout cadence): these are numbers, and
        // the mix side behind them only refreshes on the analyzer's own hop.
        TimelineView(.periodic(from: .now, by: 0.2)) { _ in
            let delta = compare()?.delta
            let cells = ReferencePanelModel.deltaCells(delta)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 0) {
                    ForEach(cells, id: \.label) { cell in
                        VStack(spacing: 2) {
                            Text(cell.label)
                                .font(.system(size: 7, weight: .semibold))
                                .tracking(0.8)
                                .foregroundStyle(DAWTheme.textDim)
                                .lineLimit(1)
                            // NEUTRAL on purpose — a delta is information, not
                            // a judgment, so v1 ships no green/red verdicts.
                            Text(cell.text)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(cell.text == "—"
                                                 ? DAWTheme.textFaint : DAWTheme.textPrimary)
                        }
                        .frame(maxWidth: .infinity)
                        .help(cell.help)
                    }
                }
                Text(ReferencePanelModel.deltaCaption(delta)
                     ?? "Play a section of your mix to compare it against the reference.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    // MARK: - Import (NSOpenPanel → the SAME store method the wire calls)

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Import"
        panel.message = "Choose a finished song to compare your mix against. "
            + "The file is copied into the project — the original is left where it is."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.runImport(path: url.path) }
    }
}

// MARK: - Shared spectrum metrics

/// Layout constants shared by the static grid Canvas and the curve Canvas, so
/// the two layers can never disagree about where the plot ends and the
/// frequency-label strip begins (the `StereoScopeModel.squareRect` rule).
private enum ReferenceSpectrumMetrics {
    /// The SF Mono frequency-label strip reserved at the BOTTOM of the well.
    static let axisLabelStrip: CGFloat = 12
}

// MARK: - The redrawing spectrum layer

/// The two-curve overlay: the reference's stored whole-song average as a
/// NEUTRAL WHITE filled polyline (static material — filled so it reads as the
/// backdrop, and deliberately UNGLOWED: it is not a live signal), and the live
/// mix's running average as a CYAN glowing polyline over it (the active signal
/// earns the glow recipe).
///
/// UNPAUSED `.periodic` at 10 Hz — the m22-e law. The averaging time constant
/// is 2.5 s, so 10 Hz is far more than the curve's own information rate; the
/// cadence is chosen so a wire-driven capture sees motion promptly, not so the
/// curve looks smooth.
private struct ReferenceSpectrumLayer: View {
    var model: ReferencePanelModel

    private static let pollInterval = 0.1

    /// Non-observable frame clock (the `EQSpectrumClock` scratch pattern):
    /// advancing it inside the timeline closure schedules no invalidation.
    @State private var clock = ReferenceSpectrumClock()

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.pollInterval)) { timeline in
            // CANVAS CONTRACT (m16-a): the renderer is @Sendable — value
            // captures only, computed before the closure.
            let frame = model.advanceSpectrum(deltaTime: clock.advance(to: timeline.date))
            let referenceBands = frame.reference ?? []
            let mixBands = frame.mix ?? []
            Canvas { @Sendable context, size in
                Self.draw(&context, size: size,
                          referenceBands: referenceBands, mixBands: mixBands)
            }
        }
        .accessibilityHidden(true)   // context under the readouts, not a readout
    }

    private nonisolated static func draw(_ context: inout GraphicsContext, size: CGSize,
                                         referenceBands: [Double], mixBands: [Double]) {
        // The plot stops above the frequency-label strip the grid layer draws,
        // so a curve at the −72 rail never runs through its own axis labels.
        let plotHeight = max(1, size.height - ReferenceSpectrumMetrics.axisLabelStrip)
        let referencePoints = ReferenceSpectrumGeometry.polylinePoints(
            bandsDb: referenceBands, width: size.width, height: plotHeight)
        if referencePoints.count > 2 {
            let line = smoothed(referencePoints)
            var fill = line
            fill.addLine(to: CGPoint(x: referencePoints[referencePoints.count - 1].x,
                                     y: plotHeight))
            fill.addLine(to: CGPoint(x: referencePoints[0].x, y: plotHeight))
            fill.closeSubpath()
            context.fill(fill, with: .color(Color.white.opacity(0.10)))
            context.stroke(line, with: .color(Color.white.opacity(0.55)), lineWidth: 1.5)
        }
        let mixPoints = ReferenceSpectrumGeometry.polylinePoints(
            bandsDb: mixBands, width: size.width, height: plotHeight)
        if mixPoints.count > 2 {
            let line = smoothed(mixPoints)
            // The glow recipe, drawn in-canvas: a wide faint bloom under a
            // bright core (the m22-d trail idiom).
            context.stroke(line, with: .color(DAWTheme.playback.opacity(0.18)), lineWidth: 6)
            context.stroke(line, with: .color(DAWTheme.playback), lineWidth: 1.5)
        }
    }

    /// Midpoint quad curves through the band points (the `VibeMeterView` /
    /// EQ-spectrum idiom) so 24 bands read as a curve, not a staircase.
    private nonisolated static func smoothed(_ points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        for i in 1..<points.count - 1 {
            let mid = CGPoint(x: (points[i].x + points[i + 1].x) / 2,
                              y: (points[i].y + points[i + 1].y) / 2)
            path.addQuadCurve(to: mid, control: points[i])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

/// Real elapsed time between frames, capped so a stalled/backgrounded frame
/// cannot snap the average (the `EQSpectrumClock` twin).
private final class ReferenceSpectrumClock {
    private var lastDate: Date?

    func advance(to date: Date) -> Double {
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.5) } ?? 0.1
        lastDate = date
        return dt
    }
}
