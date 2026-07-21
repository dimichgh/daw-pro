import SwiftUI
import DAWCore
import DAWAppKit

/// The built-in POLY SYNTH editor card — the `EffectEditorOverlay`'s
/// instrument twin: a vertical channel-strip-lineage card of grouped KNOB
/// sections opened from the instrument picker's TUNE affordance (and
/// `debug.synthEditor`). Another instance of the centered dark-glass modal
/// over a dimmed scrim — an in-window card, NEVER a popover or NSWindow, so
/// `debug.captureUI` snapshots it (the captureUI law).
///
/// Sections follow `PolySynthEditorModel.groups` — OSC (the categorical wave
/// shape as a segmented picker, never a knob — report §3) above ENVELOPE →
/// FILTER → OUTPUT last (the SSL/Cubase/Pro-C3 precedent), hairline breaks
/// between groups, labels ABOVE each knob with the SF Mono readout below
/// (report §5). Every edit routes through `PolySynthEditorModel` →
/// `store.setInstrument`, the exact method the wire's `track.setInstrument`
/// calls (UI == wire; the store's per-track coalescing makes a whole drag ONE
/// undo step).
///
/// NO VIOLET — standard instrument chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3): cyan accents only the level-flavored
/// gain knob and the earned active waveform segment; envelope/filter knobs
/// stay neutral white (the `PanKnob` precedent).
struct PolySynthEditorOverlay: View {
    var model: PolySynthEditorModel
    var onClose: () -> Void

    /// The vertical-strip width — the house 340 pt panel lineage
    /// (EffectEditorOverlay / Sketchpad / ClipFix / Voice).
    private static let cardWidth: CGFloat = 340
    /// One knob cell's column width: the editor's 94 pt three-across cell,
    /// narrowed to 70 pt for the four-knob ENVELOPE row (A/D/S/R sit shoulder
    /// to shoulder — the tight-column abbreviation convention, report §5).
    private static func cellWidth(itemCount: Int) -> CGFloat {
        itemCount >= 4 ? 70 : 94
    }

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            // The card renders only while the target still plays the built-in
            // poly synth — a wire instrument swap mid-open honestly drops the
            // card, never a stale ghost (the EffectEditorOverlay rule).
            if model.targetIsPolySynth {
                card
                    .frame(width: Self.cardWidth)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
        }
        .transition(.opacity)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            // Four fixed sections hug their content — no ScrollView needed
            // (the schema is closed; a limiter-card-style hugging height by
            // construction).
            VStack(alignment: .leading, spacing: 10) {
                oscSection
                ForEach(Array(PolySynthEditorModel.groups.enumerated()), id: \.offset) { _, group in
                    // The visual group break — hairline, never just whitespace
                    // (report §5: every strip precedent draws its section seams).
                    Divider().overlay(DAWTheme.hairline)
                    groupSection(group)
                }
            }
            .padding(.vertical, 2)
            if let error = model.lastErrorMessage {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.record)   // amber: a teaching warning
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Drag a knob up or down to hear the change · double-click resets · hold ⌥ for fine control")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .explainable(.polySynthEditor)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text("POLY SYNTH")
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(model.targetLabel)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the synth editor")
        }
    }

    // MARK: OSC (waveform — a segmented picker, never a knob; report §3)

    private var oscSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("OSC")
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.textDim)
            HStack(spacing: 6) {
                ForEach(PolySynthEditorModel.waveforms, id: \.rawValue) { waveform in
                    waveformChip(waveform)
                }
            }
        }
    }

    /// One wave-shape segment — the house state-chip idiom (the
    /// SimpleProToggle active-half / delay-toggle cell): cyan-lit = the earned
    /// current shape, dim = available. Writes through the SAME
    /// `setInstrument` path every knob uses.
    private func waveformChip(_ waveform: PolySynthParams.Waveform) -> some View {
        let on = model.waveform == waveform
        return Button {
            model.setWaveform(waveform)
        } label: {
            Text(PolySynthEditorModel.waveformLabel(waveform).uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(on ? DAWTheme.playback : DAWTheme.textDim)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(on ? DAWTheme.playback.opacity(0.18) : DAWTheme.panelRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(
                    on ? DAWTheme.playback.opacity(0.5) : DAWTheme.hairline, lineWidth: 1))
                .glow(DAWTheme.playback, radius: 4, intensity: on ? 0.4 : 0)
        }
        .buttonStyle(.plain)
        .help("\(PolySynthEditorModel.waveformLabel(waveform)) wave — click to switch the synth's basic tone.")
        .accessibilityValue(on ? "selected" : "not selected")
    }

    // MARK: Knob sections

    /// One grouped section: the micro-header over a tight row of knob cells
    /// (the EffectEditorOverlay section idiom).
    private func groupSection(_ group: PolySynthParamGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(group.title)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.textDim)
            HStack(alignment: .top, spacing: 8) {
                ForEach(group.items, id: \.name) { spec in
                    knobCell(spec, width: Self.cellWidth(itemCount: group.items.count))
                }
            }
        }
    }

    /// One knob cell: label above, `KnobControl` riding the model's fraction
    /// mapping (log travel for the cutoff; every range is unipolar min-start),
    /// SF Mono readout below. Double-click resets to the domain default.
    private func knobCell(_ spec: PolySynthParamSpec, width: CGFloat) -> some View {
        let isLevel = PolySynthEditorModel.isLevelParam(spec)
        let readout = PolySynthEditorModel.readout(value: model.value(for: spec), spec: spec)
        return KnobControl(
            label: spec.label,
            fraction: model.fraction(for: spec),
            fillAnchor: 0,
            readout: readout.text,
            unit: readout.unit,
            accent: isLevel ? DAWTheme.playback : DAWTheme.textPrimary,
            glowsReadout: isLevel,
            onChange: { model.setFraction($0, for: spec) },
            onReset: { model.resetToDefault(spec) }
        )
        .frame(width: width)
        .help("\(spec.label) — drag up or down; double-click to reset.")
    }
}
