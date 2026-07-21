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
    /// The EQ curve surface's headless model (m22-b) — non-nil only while the
    /// open insert is an EQ (AppModel creates it at open with the live render
    /// sample rate). Every other kind ignores it entirely.
    var curveModel: EQCurveEditorModel?
    /// The card's Simple/Pro density store (panel ID `Self.panelID`). For the
    /// eq kind the modes GENUINELY differ — Simple = the curve editor
    /// (default), Pro = the m22-a knob table — so eq alone earns the chip;
    /// every other kind's modes coincide and the density law forbids a
    /// do-nothing toggle (docs/DESIGN-LANGUAGE.md Panels rule).
    var densityStore: PanelDensityStore
    /// Polled by the curve surface's spectrum layer — `appModel.vibeSeed ??
    /// store.masterAnalysis()`, the `VibeMeterView` closure verbatim (§4.1).
    var spectrum: () -> MasterAnalysisSnapshot
    /// Polled by the dynamics kinds' GAIN REDUCTION block (m22-e) at 15 Hz —
    /// `appModel.gainReductionDb(...)` (the `debug.grSeed` override, else the
    /// live `store.effectGainReductionDb` poll). nil = not reporting (the
    /// block shows the honest "–", never a fabricated 0). Non-dynamics kinds
    /// never call it.
    var gainReduction: () -> Double?
    var onClose: () -> Void

    /// The density store's panel ID (app-sticky, never project data).
    static let panelID = "effectEditor"

    /// The vertical-strip width — the house 340 pt panel lineage (Sketchpad /
    /// ClipFix / Voice), narrowed from the v1 420 pt slider list: three knob
    /// cells sit shoulder to shoulder, so the card reads as a strip, not a
    /// form.
    private static let cardWidth: CGFloat = 340
    /// The eq CURVE card's width (m22-b §6: plot ≈ 528×260 + 16 pt padding).
    /// Knob mode and every other kind keep the 340 pt strip.
    private static let curveCardWidth: CGFloat = 560
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
                    .frame(width: showsCurve ? Self.curveCardWidth : Self.cardWidth)
                    .frame(maxHeight: 560)
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 12)
            }
        }
        .transition(.opacity)
    }

    /// The sections area HUGS its content — a 2-param limiter card must not
    /// pad itself to the modal's max height (a ScrollView is vertically
    /// greedy, so the height is computed from the layout constants), capped so
    /// a long schema (the m22-a EQ) scrolls instead of outgrowing the window.
    /// A group renders as ceil(items/3) knob rows — three cells fit the strip
    /// width, so a 4-item EQ band wraps to a second row.
    private var sectionsHeight: CGFloat {
        let groups = model.groups
        guard !groups.isEmpty else { return 24 }
        let sections = groups.reduce(CGFloat(0)) { acc, group in
            acc + (group.title.isEmpty ? 0 : Self.headerLineHeight)
                + Self.cellHeight * CGFloat(Self.rows(of: group).count)
        }
        // Each boundary: spacing + 1 pt hairline + spacing.
        let boundaries = CGFloat(groups.count - 1) * (Self.groupSpacing * 2 + 1)
        return min(sections + boundaries + 10, 460)
    }

    /// Chunks a group's items into knob rows of ≤ 3 (the strip fits three
    /// 94 pt cells across; the m22-a EQ bands carry four items).
    private static func rows(of group: EffectParamGroup) -> [[EffectParamGroup.Item]] {
        stride(from: 0, to: group.items.count, by: 3).map {
            Array(group.items[$0..<min($0 + 3, group.items.count)])
        }
    }

    /// Whether the card body is the m22-b CURVE surface: the eq kind in
    /// Simple density (the default). Pro keeps the m22-a knob table — exact
    /// numeric control over all 22 params — and every other kind renders the
    /// knob card unchanged (a kind check, not a registry — §6 YAGNI).
    private var showsCurve: Bool {
        model.kind == .eq && curveModel != nil
            && densityStore.density(forPanel: Self.panelID) == .simple
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            // The GAIN REDUCTION meter (m22-e): dynamics kinds only, seated
            // ABOVE the knob sections so it reads while dragging Threshold /
            // Ceiling — the report-§4 pairing that unblocks those knobs'
            // meter story. Its 15 Hz polls tick in the block's own
            // TimelineViews (the m22-b isolation law), never this card.
            if let kind = model.kind, GainReductionMeterModel.isDynamicsKind(kind) {
                GainReductionMeterBlock(kind: kind, gainReduction: gainReduction)
                Divider().overlay(DAWTheme.hairline)
            }
            if showsCurve, let curveModel {
                // Simple density: the frequency-curve editor. Its band strip
                // absorbs the slope chips + ON toggles, and its footer carries
                // the curve hint line (§5.5). Spectrum only on the MASTER
                // chain's EQ (§4.1 gating — absent on a track, never fake).
                EQCurveEditor(
                    editor: model,
                    model: curveModel,
                    showsSpectrum: model.target?.trackID == nil,
                    spectrum: spectrum)
            } else {
                knobSections
            }
            if let error = model.lastErrorMessage {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.record)   // amber: a teaching warning
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !showsCurve {
                Text("Drag a knob up or down to hear the change · double-click resets · hold ⌥ for fine control")
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        .explainable(.effectEditor)
    }

    /// The m17-a/m22-a grouped knob table — every kind's card body, and the
    /// eq kind's PRO density (the complete fallback surface).
    private var knobSections: some View {
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
                // The one SOFT element in the header: when the eq's density
                // chip joins the 340 pt Pro card the prose label truncates —
                // the state chips never compress (m22-b; the m10-i soft-name
                // idiom).
                .layoutPriority(-1)
            Spacer()
            // The Simple/Pro chip renders for the eq kind ONLY — its two
            // densities genuinely differ (curve vs knob table); every other
            // kind's modes coincide and must never grow a do-nothing toggle
            // (the density law).
            if EQCurveEditorModel.showsDensityChip(for: model.kind) {
                SimpleProToggle(
                    store: densityStore,
                    panelID: Self.panelID,
                    help: "Simple: shape the EQ on the curve. Pro: every parameter as a knob.")
                // Never compress the chip labels on the 340 pt Pro card —
                // the header's target label truncates instead.
                .fixedSize()
            }
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
            ForEach(Array(Self.rows(of: group).enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top, spacing: 8) {
                    ForEach(row, id: \.spec.name) { item in
                        if EffectEditorModel.isToggleParam(item.spec) {
                            toggleCell(item)
                        } else if EffectEditorModel.isSlopeParam(item.spec) {
                            slopeCell(item)
                        } else if EffectEditorModel.isDivisionParam(item.spec) {
                            divisionCell(item)
                        } else if item.spec.name == "timeMs", model.delaySyncActive {
                            syncedTimeCell(item)
                        } else {
                            knobCell(item)
                        }
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

    /// The m22-f DIVISION picker — the synced delay's note length. An 18-way
    /// CHOICE (1/1…1/32 straight/dotted/triplet), so it renders as the house
    /// compact menu chip (the QuantizePanel grid-picker idiom), never a knob.
    /// Writes the division's length in BEATS through the SAME `set` path —
    /// zero wire change (the store snaps to the nearest legal value). Dimmed
    /// while sync is off (the choice is stored but not yet heard); neutral
    /// chrome — a time choice, not a level (no cyan).
    private func divisionCell(_ item: EffectParamGroup.Item) -> some View {
        let current = model.delayDivision
        let syncOn = model.delaySyncActive
        return VStack(spacing: 4) {
            Text(item.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Menu {
                ForEach(NoteDivision.allCases, id: \.rawValue) { division in
                    Button {
                        model.setDelayDivision(division)
                    } label: {
                        if division == current {
                            Label(division.rawValue, systemImage: "checkmark")
                        } else {
                            Text(division.rawValue)
                        }
                    }
                }
            } label: {
                HStack(spacing: 5) {
                    Text(current.rawValue)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .tracking(0.6)
                        .foregroundStyle(DAWTheme.textPrimary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(DAWTheme.textDim)
                }
                .padding(.horizontal, 10)
                .frame(height: 20)
                .background(DAWTheme.panelRaised)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(height: 24)
            Text("NOTE")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(DAWTheme.textDim)
        }
        .frame(width: Self.cellWidth)
        .opacity(syncOn ? 1 : 0.45)
        .help(syncOn
              ? "\(item.label) — the note length the delay tracks (d = dotted, t = triplet)."
              : "\(item.label) — heard once SYNC is on (d = dotted, t = triplet).")
        .accessibilityValue(current.rawValue)
    }

    /// The m22-f synced TIME cell — while SYNC is on the tempo OWNS the
    /// delay time, so the knob yields to a read-only readout of the derived
    /// ms (never a fightable control): same label/readout typography as a
    /// knob cell, with the source spelled out underneath.
    private func syncedTimeCell(_ item: EffectParamGroup.Item) -> some View {
        let derived = model.syncedDelayTimeMs ?? DelayParams.timeRange.lowerBound
        let readout = EffectEditorModel.readout(value: derived, spec: item.spec)
        return VStack(spacing: 4) {
            Text(item.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            VStack(spacing: 2) {
                Text("\(readout.text) \(readout.unit)")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textPrimary)
                Image(systemName: "metronome")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .frame(height: 36)
            Text("FROM TEMPO")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(DAWTheme.textDim)
        }
        .frame(width: Self.cellWidth)
        .help("\(item.label) — derived from the tempo while SYNC is on; "
              + "switch SYNC off to set milliseconds by hand.")
        .accessibilityValue("\(readout.text) \(readout.unit), from tempo")
    }

    /// The m22-a HP/LP SLOPE chip — a TWO-STATE control (12 or 24 dB/oct;
    /// the model layer snaps everything else), so it renders as a chip that
    /// flips between the two legal values, never a knob. Writes 12.0/24.0
    /// through the SAME `set` path — zero wire change. Neutral chrome: slope
    /// is a tone-shaping choice, not a level (no cyan).
    private func slopeCell(_ item: EffectParamGroup.Item) -> some View {
        let is24 = EffectEditorModel.slopeIs24(model.value(for: item.spec))
        return VStack(spacing: 4) {
            Text(item.label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            Button {
                model.set(name: item.spec.name, value: is24 ? 12 : 24)
            } label: {
                Text(is24 ? "24" : "12")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(DAWTheme.textPrimary)
                    .padding(.horizontal, 10)
                    .frame(height: 20)
                    .background(DAWTheme.panelRaised)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .frame(height: 24)
            Text("dB/OCT")
                .font(.system(size: 7, weight: .semibold, design: .monospaced))
                .tracking(0.6)
                .foregroundStyle(DAWTheme.textDim)
        }
        .frame(width: Self.cellWidth)
        .help("\(item.label) — click to switch between 12 and 24 dB per octave.")
        .accessibilityValue(is24 ? "24 dB per octave" : "12 dB per octave")
    }
}
