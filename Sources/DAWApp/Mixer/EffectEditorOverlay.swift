import SwiftUI
import DAWCore
import DAWAppKit

/// The built-in insert EFFECT EDITOR card (m17-a): the panel of sliders a
/// built-in effect opens from its `InsertRow`. The FIFTH instance of the
/// centered dark-glass modal over a dimmed scrim (Settings / Instrument Picker
/// / Quantize & Groove / Undo History) — an in-window card, NEVER a popover or
/// NSWindow, so `debug.captureUI` snapshots it (the captureUI law) and Logic's
/// floating-window clutter never imports. One row per `EffectParamSpec` — the
/// SAME schema `fx.describe` serves — and every drag routes through
/// `EffectEditorModel.set` → `store.setEffectParam`/`setMasterEffectParam`,
/// the exact methods the wire's `fx.setParam` calls (UI == wire; the store's
/// per-(effect, name) coalescing makes a whole drag ONE undo step).
///
/// Pro-only by construction (reached only from the Pro inserts section, which
/// Simple never renders). NO VIOLET — standard mixing chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3): cyan accents only the genuinely
/// level/gain-flavored readouts; tone/time params stay neutral white (the
/// `PanKnob` precedent). Bypass wears the row dot's signal-green semantics.
struct EffectEditorOverlay: View {
    var model: EffectEditorModel
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
            // The card renders only while the target still resolves — a wire
            // `fx.remove` mid-open honestly drops the card, never a stale ghost.
            if model.descriptor != nil {
                card
                    .frame(width: 420)
                    .frame(maxHeight: 560)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
        }
        .transition(.opacity)
    }

    /// The rows area HUGS its content — a 2-param limiter card must not pad
    /// itself to the modal's max height (a ScrollView is vertically greedy, so
    /// the height is computed from the layout constants: 18 pt rows — the
    /// `ValueSlider` row height — on 7 pt spacing + 4 pt padding), capped so a
    /// future long schema scrolls instead of outgrowing the window.
    private var rowsHeight: CGFloat {
        let count = CGFloat(max(model.specs.count, 1))
        return min(count * 18 + (count - 1) * 7 + 4, 460)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            ScrollView {
                VStack(spacing: 7) {
                    ForEach(model.specs, id: \.name) { spec in
                        paramRow(spec)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: rowsHeight)
            if let error = model.lastErrorMessage {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.record)   // amber: a teaching warning
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Drag a slider to hear the change · double-click resets · hold ⌥ for fine control")
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textDim)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .explainable(.effectEditor)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DAWTheme.textDim)
            Text(model.displayName.uppercased())
                .font(.system(size: 12, weight: .heavy))
                .tracking(1.6)
                .foregroundStyle(DAWTheme.textPrimary)
            Text(model.targetLabel)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Spacer()
            bypassChip
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .buttonStyle(.plain)
            .help("Close the effect editor")
        }
    }

    /// The header BYPASS toggle — the row dot's exact semantics one size up:
    /// a signal-green glowing dot + "ACTIVE" while passing audio, a dim dot +
    /// "BYPASSED" while muted-through. Same store path as the row's dot.
    private var bypassChip: some View {
        let bypassed = model.isBypassed
        return Button {
            model.toggleBypass()
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(bypassed ? DAWTheme.textDim.opacity(0.35) : DAWTheme.signal)
                    .frame(width: 7, height: 7)
                    .glow(DAWTheme.signal, radius: 4, intensity: bypassed ? 0 : 0.6)
                Text(bypassed ? "BYPASSED" : "ACTIVE")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(bypassed ? DAWTheme.textDim : DAWTheme.signal)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(bypassed ? DAWTheme.panelRaised : DAWTheme.signal.opacity(0.14))
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(
                    bypassed ? DAWTheme.hairline : DAWTheme.signal.opacity(0.5), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help(bypassed ? "Bypassed — click to enable" : "Active — click to bypass")
    }

    // MARK: Rows

    /// One generic parameter row: humanized label, a `ValueSlider` riding the
    /// model's fraction mapping (log travel for frequencies), and the SF Mono
    /// readout + unit. Double-click resets to the spec default.
    private func paramRow(_ spec: EffectParamSpec) -> some View {
        let accent = EffectEditorModel.isLevelParam(spec)
            ? DAWTheme.playback : DAWTheme.textPrimary
        let readout = EffectEditorModel.readout(value: model.value(for: spec), spec: spec)
        return HStack(spacing: 10) {
            Text(EffectEditorModel.label(for: spec).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .frame(width: 104, alignment: .leading)
                .lineLimit(1)
            ValueSlider(
                value: model.fraction(for: spec),
                range: 0...1,
                onChange: { model.setFraction($0, for: spec) },
                tint: accent
            )
            .simultaneousGesture(TapGesture(count: 2).onEnded { model.resetToDefault(spec) })
            HStack(spacing: 3) {
                Text(readout.text)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .glow(accent, radius: 4,
                          intensity: EffectEditorModel.isLevelParam(spec) ? 0.4 : 0)
                if !readout.unit.isEmpty {
                    Text(readout.unit)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(DAWTheme.textDim)
                }
            }
            .frame(width: 72, alignment: .trailing)
            .lineLimit(1)
        }
        .help("\(EffectEditorModel.label(for: spec)) — double-click the slider to reset.")
    }
}
