import SwiftUI
import DAWCore
import DAWAppKit

/// The built-in insert EFFECT EDITOR card (m17-a; knob layout per the
/// 2026-07-19 knob-vs-slider report): a VERTICAL channel-strip-lineage card of
/// grouped KNOB sections a built-in effect opens from its `InsertRow`. The
/// FIFTH instance of the centered dark-glass modal over a dimmed scrim
/// (Settings / Instrument Picker / Quantize & Groove / Undo History) — an
/// in-window card, NEVER a popover or NSWindow, so `debug.captureUI` snapshots
/// it (the captureUI law) and Logic's floating-window clutter never imports.
/// Sections follow `EffectEditorModel.groups(for:)` — input/trigger →
/// time/processing → OUTPUT always last (the SSL/Cubase/Pro-C3 precedent),
/// hairline breaks between groups, labels ABOVE each knob with the SF Mono
/// readout below (report §5). The binary delay `pingPong` renders as a house
/// TOGGLE, not a knob. Every drag routes through `EffectEditorModel.set` →
/// `store.setEffectParam`/`setMasterEffectParam`, the exact methods the wire's
/// `fx.setParam` calls (UI == wire; the store's per-(effect, name) coalescing
/// makes a whole drag ONE undo step).
///
/// Pro-only by construction (reached only from the Pro inserts section, which
/// Simple never renders). NO VIOLET — standard mixing chrome, not AI content
/// (docs/DESIGN-LANGUAGE.md Rule 3): cyan accents only the genuinely
/// level/gain-flavored knobs; tone/time params stay neutral white (the
/// `PanKnob` precedent). Bypass wears the row dot's signal-green semantics.
struct EffectEditorOverlay: View {
    var model: EffectEditorModel
    var onClose: () -> Void

    /// The vertical-strip width — the house 340 pt panel lineage (Sketchpad /
    /// ClipFix / Voice), narrowed from the v1 420 pt slider list: three knob
    /// cells sit shoulder to shoulder, so the card reads as a strip, not a
    /// form.
    private static let cardWidth: CGFloat = 340
    /// One knob/toggle cell's column width (3 across fit the strip).
    private static let cellWidth: CGFloat = 94
    /// Layout constants the hugging height is computed from (see
    /// `sectionsHeight`): a knob cell (8 pt label + 36 pt knob + readout +
    /// spacing) and a section micro-header line.
    private static let cellHeight: CGFloat = 68
    private static let headerLineHeight: CGFloat = 16
    private static let groupSpacing: CGFloat = 10

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
                    .frame(width: Self.cardWidth)
                    .frame(maxHeight: 560)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
        }
        .transition(.opacity)
    }

    /// The sections area HUGS its content — a 2-param limiter card must not
    /// pad itself to the modal's max height (a ScrollView is vertically
    /// greedy, so the height is computed from the layout constants), capped so
    /// a future long schema scrolls instead of outgrowing the window. Every
    /// group is a single knob row (≤ 3 params per group across all 9 kinds).
    private var sectionsHeight: CGFloat {
        let groups = model.groups
        guard !groups.isEmpty else { return 24 }
        let sections = groups.reduce(CGFloat(0)) { acc, group in
            acc + (group.title.isEmpty ? 0 : Self.headerLineHeight) + Self.cellHeight
        }
        // Each boundary: spacing + 1 pt hairline + spacing.
        let boundaries = CGFloat(groups.count - 1) * (Self.groupSpacing * 2 + 1)
        return min(sections + boundaries + 10, 460)
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Self.groupSpacing) {
                    ForEach(Array(model.groups.enumerated()), id: \.offset) { index, group in
                        if index > 0 {
                            // The visual group break — hairline, never just
                            // whitespace (report §5: every strip precedent
                            // draws its section seams).
                            Divider().overlay(DAWTheme.hairline)
                        }
                        groupSection(group)
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(height: sectionsHeight)
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

    // MARK: Sections

    /// One grouped section: the micro-header (the mixer's `StripSectionLabel`
    /// caption idiom; empty on a single-knob card like gain) over a tight row
    /// of knob/toggle cells.
    private func groupSection(_ group: EffectParamGroup) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !group.title.isEmpty {
                Text(group.title)
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textDim)
            }
            HStack(alignment: .top, spacing: 8) {
                ForEach(group.items, id: \.spec.name) { item in
                    if EffectEditorModel.isToggleParam(item.spec) {
                        toggleCell(item)
                    } else {
                        knobCell(item)
                    }
                }
            }
        }
    }

    /// One knob cell: label above, `KnobControl` riding the model's fraction
    /// mapping (log travel for frequencies; bipolar center-out fill for ±dB
    /// gains), SF Mono readout below. Double-click resets to the spec default.
    private func knobCell(_ item: EffectParamGroup.Item) -> some View {
        let spec = item.spec
        let isLevel = EffectEditorModel.isLevelParam(spec)
        let readout = EffectEditorModel.readout(value: model.value(for: spec), spec: spec)
        return KnobControl(
            label: item.label,
            fraction: model.fraction(for: spec),
            fillAnchor: EffectEditorModel.knobFillAnchor(for: spec),
            readout: readout.text,
            unit: readout.unit,
            accent: isLevel ? DAWTheme.playback : DAWTheme.textPrimary,
            glowsReadout: isLevel,
            onChange: { model.setFraction($0, for: spec) },
            onReset: { model.resetToDefault(spec) }
        )
        .frame(width: Self.cellWidth)
        .help("\(item.label) — drag up or down; double-click to reset.")
    }

    /// The pingPong TOGGLE cell — the param is binary at the model layer
    /// (`DelayParams` rounds it), so it renders as the house state toggle
    /// (the SimpleProToggle active-half idiom: cyan-lit = earned active mode,
    /// dim = off), never a knob or slider. Writes 0.0/1.0 through the SAME
    /// `set` path every knob uses — zero wire change.
    private func toggleCell(_ item: EffectParamGroup.Item) -> some View {
        let on = EffectEditorModel.toggleIsOn(model.value(for: item.spec))
        return VStack(spacing: 4) {
            Text(item.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Button {
                model.set(name: item.spec.name, value: on ? 0 : 1)
            } label: {
                Text(on ? "ON" : "OFF")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(on ? DAWTheme.playback : DAWTheme.textDim)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .background(on ? DAWTheme.playback.opacity(0.18) : DAWTheme.panelRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(
                        on ? DAWTheme.playback.opacity(0.5) : DAWTheme.hairline, lineWidth: 1))
                    .glow(DAWTheme.playback, radius: 4, intensity: on ? 0.4 : 0)
            }
            .buttonStyle(.plain)
            // Center the chip in the knob-slot height so the row reads level.
            .frame(height: 36)
        }
        .frame(width: Self.cellWidth)
        .help("\(item.label) — click to switch on or off.")
        .accessibilityValue(on ? "on" : "off")
    }
}
