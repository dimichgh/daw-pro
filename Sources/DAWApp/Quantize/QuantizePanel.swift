import SwiftUI
import DAWCore
import DAWAppKit

/// The Quantize & Groove panel (m11-a): the face for the shipped quantize/groove
/// engine. It presents as a centered dark-glass modal card over a dimmed scrim
/// (the Settings / instrument-picker overlay idiom) — rendered INSIDE the main
/// window content so `debug.captureUI` can snapshot it headlessly (a popover lives
/// in its own window, invisible to the window cacheDisplay path).
///
/// Reachable from the piano-roll header (a QUANTIZE chip, both densities) and the
/// arrange clip context menu (Pro only, sp-c). Thin over `QuantizeModel`: all state
/// + the built `QuantizeSettings` live there; the view routes Apply straight to
/// `ProjectStore.quantizeClipNotes` (the wire's method) for ONE undo step.
///
/// NO VIOLET anywhere — quantize is standard editing chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3). Cyan marks only earned active state (the
/// selected groove, the SF Mono readouts, the Apply button).
///
/// **Density decision** (docs/research/simple-pro-inventory.md): Simple = grid +
/// strength (tighten timing, this hard); Pro adds swing, snap-ends, the groove
/// picker, and extract. A genuine delta, so it earns a live SIMPLE/PRO chip — but
/// only for a MIDI target (audio has only the extract affordance, so its modes
/// coincide and the chip is hidden, never a do-nothing toggle).
struct QuantizePanel: View {
    @Bindable var model: QuantizeModel
    /// The panel's own Simple/Pro density store (the sixth live-chip surface).
    var densityStore: PanelDensityStore
    /// Applies the built settings + closes (wired to `ProjectStore.quantizeClipNotes`).
    var onApply: () -> Void
    /// Removes a saved groove template (wired to `ProjectStore.removeGrooveTemplate`).
    var onRemoveGroove: (UUID) -> Void
    var onClose: () -> Void

    /// The panel's stable density key.
    static let panelID = "quantize"

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            card
                .frame(width: 380)
                .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
        }
        .transition(.opacity)
        .onAppear { model.density = densityStore.density(forPanel: Self.panelID) }
        .onChange(of: densityStore.density(forPanel: Self.panelID)) { _, new in
            model.density = new
        }
    }

    private var isPro: Bool { densityStore.density(forPanel: Self.panelID) == .pro }

    private var card: some View {
        // The card HUGS its content (no greedy outer ScrollView) so Simple isn't a
        // tall empty box; only the groove LIST scrolls internally when it grows long.
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider().overlay(DAWTheme.hairline)
            if model.targetIsMIDI {
                gridRow
                strengthRow
                if isPro {
                    swingRow
                    endsRow
                    Divider().overlay(DAWTheme.hairline)
                    grooveSection
                }
            } else {
                audioNote
                Divider().overlay(DAWTheme.hairline)
                grooveSection
            }
            if model.targetIsMIDI {
                applyButton
                    .explainable(.quantize)
            }
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.grid.3x1.below.line.grid.1x2")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("QUANTIZE")
                .font(.system(size: 12, weight: .heavy))
                .tracking(2)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(model.targetClipName)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer()
            // The chip earns its place only for a MIDI target (a real Simple/Pro
            // delta); an audio target has only extract, so its modes coincide —
            // no do-nothing toggle (docs/DESIGN-LANGUAGE.md "Panels").
            if model.targetIsMIDI {
                SimpleProToggle(
                    store: densityStore, panelID: Self.panelID,
                    help: "Simple: grid + strength. Pro: swing, note-end snap, and grooves."
                )
                .explainable(.panelDensity)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the quantize panel")
        }
    }

    // MARK: - Grid

    private var gridRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("GRID", trailing: model.gridIsGrooveLocked
                     ? AnyView(lockedNote("set by the groove")) : nil)
            if model.gridIsGrooveLocked {
                lockedChip(model.effectiveGridLabel)
            } else {
                gridPicker
            }
        }
        .explainable(.quantizeGrid)
    }

    private var gridPicker: some View {
        Menu {
            ForEach(Array(QuantizeModel.grids.enumerated()), id: \.element.id) { index, grid in
                Button {
                    model.gridIndex = index
                } label: {
                    if model.gridIndex == index {
                        Label(grid.label, systemImage: "checkmark")
                    } else {
                        Text(grid.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(model.grid.label)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.playback)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The timing grid notes snap to")
    }

    // MARK: - Strength

    private var strengthRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("STRENGTH", trailing: AnyView(readout("\(Int((model.strength * 100).rounded()))%")))
            ValueSlider(value: model.strength, range: 0...1,
                        onChange: { model.strength = $0 })
        }
        .explainable(.quantizeStrength)
    }

    // MARK: - Swing

    private var swingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            rowLabel("SWING", trailing: model.swingIsInert
                     ? AnyView(lockedNote("groove sets the feel"))
                     : AnyView(readout("\(Int(model.swingPercent.rounded()))%")))
            ValueSlider(value: model.swingPercent, range: 50...75,
                        onChange: { model.swingPercent = $0 },
                        enabled: !model.swingIsInert)
        }
        .explainable(.quantizeSwing)
    }

    // MARK: - Snap ends

    private var endsRow: some View {
        Button {
            model.quantizeEnds.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: model.quantizeEnds ? "checkmark.square.fill" : "square")
                    .font(.system(size: 13))
                    .foregroundStyle(model.quantizeEnds ? DAWTheme.playback : DAWTheme.textDim)
                Text("Also snap note ends")
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textPrimary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .explainable(.quantizeEnds)
    }

    // MARK: - Groove section (built-ins + saved + extract)

    private var grooveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            rowLabel("GROOVE", trailing: AnyView(extractButton))
            // A groove picker only feeds Apply, which is MIDI-only — so an audio
            // target shows the extract affordance alone (no selectable list).
            if model.targetIsMIDI {
                grooveList
            } else {
                Text("Capture this clip's timing feel as a groove you can apply to other parts.")
                    .font(.system(size: 10))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if model.isExtractExpanded { extractComposer }
        }
        .explainable(.quantizeGroove)
    }

    @ViewBuilder
    private var grooveList: some View {
        // Bounded scroll so 8 built-ins + N saved templates never blow the card past
        // the window; short lists still hug (the card sizes to content).
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                grooveRow(title: "Straight grid", detail: "no groove", selected: model.selectedGroove == nil) {
                    model.selectGroove(nil)
                }
                // Keyed on `name` (unique) — the built-ins' deterministic ids can
                // collide within a family, which would make ForEach reuse one row.
                ForEach(model.builtinGrooves, id: \.name) { groove in
                    let display = QuantizeModel.builtinDisplay(groove)
                    grooveRow(title: display.title, detail: display.detail,
                              selected: model.isGrooveSelected(groove)) {
                        model.selectGroove(groove)
                    }
                }
                if !model.savedGrooves.isEmpty {
                    Text("SAVED")
                        .font(.system(size: 8.5, weight: .semibold))
                        .tracking(1.2)
                        .foregroundStyle(DAWTheme.textFaint)
                        .padding(.top, 4)
                    ForEach(model.savedGrooves) { groove in
                        grooveRow(title: groove.name,
                                  detail: QuantizeModel.gridLabel(forBeats: groove.gridBeats),
                                  selected: model.isGrooveSelected(groove),
                                  onRemove: { onRemoveGroove(groove.id) }) {
                            model.selectGroove(groove)
                        }
                    }
                }
            }
            .padding(.vertical, 1)
        }
        .frame(maxHeight: 240)
    }

    private func grooveRow(title: String, detail: String, selected: Bool,
                           onRemove: (() -> Void)? = nil,
                           action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 11))
                        .foregroundStyle(selected ? DAWTheme.playback : DAWTheme.textFaint)
                    Text(title)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(selected ? DAWTheme.playback : DAWTheme.textPrimary)
                        .lineLimit(1)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(DAWTheme.textDim)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textFaint)
                }
                .buttonStyle(.plain)
                .help("Remove this saved groove")
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? DAWTheme.playback.opacity(0.1) : DAWTheme.panelRaised.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6)
            .stroke(selected ? DAWTheme.playback.opacity(0.4) : DAWTheme.hairline, lineWidth: 1))
    }

    // MARK: - Extract affordance

    private var extractButton: some View {
        Button {
            if model.isExtractExpanded { model.cancelExtract() } else { model.beginExtract() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: model.isExtractExpanded ? "xmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                Text(model.isExtractExpanded ? "Cancel" : "Extract from clip")
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(DAWTheme.textPrimary)   // neutral create-chrome (Rule 3)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Capture this clip's timing feel as a reusable groove")
    }

    private var extractComposer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // A name is prose, not a numeric readout — SF Pro, the track-rename idiom.
            TextField("Groove name…", text: $model.extractName)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(DAWTheme.textPrimary)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(DAWTheme.background)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .stroke(DAWTheme.playback.opacity(0.4), lineWidth: 1))
            if let error = model.extractError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(DAWTheme.record)
                    Text(error)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(DAWTheme.record)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
            }
            Button {
                Task { await model.extract() }
            } label: {
                Text(model.isExtracting ? "EXTRACTING…" : "EXTRACT GROOVE")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(model.canExtract ? DAWTheme.background : DAWTheme.textFaint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(model.canExtract ? DAWTheme.playback : DAWTheme.panelRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(!model.canExtract)
        }
        .padding(10)
        .background(DAWTheme.panelRaised.opacity(0.4))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Audio note (extract-only target)

    private var audioNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 12)).foregroundStyle(DAWTheme.signal)
            Text("Timing quantize applies to instrument parts. You can still capture this audio clip's groove below.")
                .font(.system(size: 10.5))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Apply

    private var applyButton: some View {
        Button(action: onApply) {
            Text("APPLY QUANTIZE")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.background)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(DAWTheme.playback)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .glow(DAWTheme.playback, radius: 6, intensity: 0.4)
        }
        .buttonStyle(.plain)
        .help("Apply the quantize to this clip (one undo step)")
    }

    // MARK: - Small helpers

    private func rowLabel(_ text: String, trailing: AnyView? = nil) -> some View {
        HStack {
            Text(text)
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(DAWTheme.textDim)
            Spacer()
            if let trailing { trailing }
        }
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(DAWTheme.playback)
    }

    private func lockedNote(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(DAWTheme.textFaint)
    }

    private func lockedChip(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundStyle(DAWTheme.textDim)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DAWTheme.panelRaised.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(DAWTheme.hairline, lineWidth: 1))
    }
}
