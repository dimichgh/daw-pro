import SwiftUI
import DAWAppKit

/// The arrange toolbar's **WAVE** cluster (m25-e): how tall audio waveforms are
/// drawn inside their clips — auto-fit on/off, plus a vertical magnification on
/// top of it.
///
/// Shaped as a deliberate MIRROR of the horizontal zoom cluster sitting beside it
/// (`ContentView.zoomCluster`): `−` · readout · `+` on one raised chip with a
/// hairline border, SF Mono 10 pt readout. The two clusters are the same idea on
/// the two axes — time on one, amplitude on the other — so a user who has found
/// one has found the other. The middle element additionally opens a **chip menu**
/// (the SNAP-picker idiom) carrying the mode choice, the preset ladder and the
/// reset, so the steppers stay one-click while the less-used choices have a home.
///
/// **Colour (Rule 3): neutral chrome in every state, no accent.** Neither mode is
/// an "active" state that earns cyan — they are two ways of drawing the same
/// thing, and cyan means playback/activity. What the chip does instead is
/// BRIGHTEN its readout from `textDim` to `textPrimary` once the user has moved
/// off the default, so "something is set here" reads at a glance without
/// inventing a new accent meaning. The sibling horizontal-zoom readout's
/// `textDim` is the precedent for the resting colour.
///
/// Plain value inputs + callbacks (no store, no AppModel), so a preview drives it
/// exactly like the app does.
struct WaveformZoomControl: View {
    /// Auto-fit on (FIT) or raw amplitude (RAW) — `PanelLayoutStore.waveformNormalize`.
    var normalize: Bool
    /// Magnification on top of the fit — `PanelLayoutStore.waveformVerticalZoom`.
    var verticalZoom: CGFloat
    var onSetNormalize: (Bool) -> Void
    var onZoomOut: () -> Void
    var onZoomIn: () -> Void
    var onSetZoom: (CGFloat) -> Void
    /// Back to the app default: auto-fit on, 1×.
    var onReset: () -> Void

    /// True once the user has moved off the app default — drives the readout's
    /// dim→bright lift (never an accent).
    private var isModified: Bool {
        normalize != WaveformScale.defaultNormalize
            || abs(verticalZoom - WaveformScale.defaultVerticalZoom) > 0.0001
    }

    var body: some View {
        HStack(spacing: 0) {
            stepButton("minus", help: "Shorter waveforms (⌥⌘−)", action: onZoomOut)
            readoutMenu
            stepButton("plus", help: "Taller waveforms (⌥⌘+)", action: onZoomIn)
        }
        .padding(.vertical, 3)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(DAWTheme.hairline, lineWidth: 1)
        )
    }

    /// The middle element: a waveform glyph + the SF Mono state readout, which is
    /// also the menu button. Its width is PINNED (the m22-g law — a shared control
    /// never truncates and a readout never shrinks) at the widest string the model
    /// can produce, `RAW 1.5×`, so the ± buttons never shift as the label changes.
    private var readoutMenu: some View {
        Menu {
            Section("Waveform Height") {
                menuChoice("Fit to Clip Height", isOn: normalize) { onSetNormalize(true) }
                menuChoice("True Level", isOn: !normalize) { onSetNormalize(false) }
            }
            Section("Magnify") {
                ForEach(WaveformScale.zoomLadder, id: \.self) { rung in
                    menuChoice(WaveformScale.zoomLabel(rung),
                               isOn: abs(verticalZoom - rung) < 0.0001) { onSetZoom(rung) }
                }
            }
            Divider()
            Button("Reset Waveform View", action: onReset)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .bold))
                Text(WaveformScale.modeLabel(normalize: normalize, verticalZoom: verticalZoom))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
            }
            .foregroundStyle(isModified ? DAWTheme.textPrimary : DAWTheme.textDim)
            .frame(width: 66)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(WaveformScale.help(normalize: normalize, verticalZoom: verticalZoom))
    }

    /// A checkmark-or-plain menu row — the SNAP picker's radio idiom, so a
    /// selected choice reads the same everywhere in this app.
    private func menuChoice(_ title: String, isOn: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// The ± ends, matching `zoomCluster.zoomStepButton` exactly (9 pt bold glyph,
    /// 7 pt horizontal padding, plain style, its own hit shape).
    private func stepButton(_ systemImage: String, help: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(DAWTheme.textDim)
                .padding(.horizontal, 7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

#Preview("Waveform zoom — the four states") {
    VStack(alignment: .leading, spacing: 10) {
        WaveformZoomControl(normalize: true, verticalZoom: 1,
                            onSetNormalize: { _ in }, onZoomOut: {}, onZoomIn: {},
                            onSetZoom: { _ in }, onReset: {})
        WaveformZoomControl(normalize: true, verticalZoom: 1.5,
                            onSetNormalize: { _ in }, onZoomOut: {}, onZoomIn: {},
                            onSetZoom: { _ in }, onReset: {})
        WaveformZoomControl(normalize: false, verticalZoom: 1,
                            onSetNormalize: { _ in }, onZoomOut: {}, onZoomIn: {},
                            onSetZoom: { _ in }, onReset: {})
        WaveformZoomControl(normalize: false, verticalZoom: 8,
                            onSetNormalize: { _ in }, onZoomOut: {}, onZoomIn: {},
                            onSetZoom: { _ in }, onReset: {})
    }
    .padding(24)
    .background(DAWTheme.background)
}
