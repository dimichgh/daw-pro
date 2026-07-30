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
    /// Polled by the curve surface's spectrum layer — `appModel
    /// .effectEditorSpectrum()`, resolved against the card's CURRENT target
    /// each tick (master mix vs this insert's own tap, m23-r3).
    var spectrum: () -> MasterAnalysisSnapshot
    /// The curve plot's `.help` caption (m23-r3), resolved by the app model at
    /// its one home — see `EQCurveEditor.help`.
    var curveHelp: String
    /// The instrument frequency guide's state (m23-o2), resolved by the app
    /// model at its one home — see `EQCurveEditor.guide`.
    var instrumentGuide: EQInstrumentGuide
    /// Reports the guidance plot's MEASURED width to the app model — see
    /// `EQCurveEditor.onPlotWidth`. Threaded rather than read from a constant so
    /// `debug.effectEditor` reports positions at the width that was drawn.
    var onPlotWidth: (Double) -> Void
    /// The spectrum tap's `.task(id:)` lifecycle hold (m23-r3) — see
    /// `EQCurveEditor.holdSpectrum`.
    var holdSpectrum: () async -> Void
    /// The kind's DRAWN honesty disclosure (m23-p2), resolved by the app model
    /// at its one home — see `EffectHonestyNote`. nil for every kind whose own
    /// name already says what it does; non-nil only for the bass enhancer
    /// today. A plain value input: a preview passes `.bassEnhancer` directly.
    var honestyNote: EffectHonestyNote?
    /// Reports the card's MEASURED size to the app model, from the card's own
    /// `GeometryReader` (the `onPlotWidth` idiom, m23-o2/m23-r3). The card is a
    /// modal with no scroll of its own, so its height is a real constraint
    /// against `WindowFloor.minHeight` — and this cycle grew it. Measured
    /// rather than derived: `sectionsHeight` is arithmetic over layout
    /// constants and knows nothing about a block that WRAPS, so a derived
    /// number would agree with itself and with nothing on screen.
    ///
    /// The WIDTH is reported for the same reason at one remove: this card is a
    /// FLOATING modal, so it is not constrained by the mixer strip's width
    /// budget — it takes `curveCardWidth` when a curve shows and `cardWidth`
    /// otherwise. That is the width the wrapping disclosure gets, and it is the
    /// number every line-count estimate in this file implicitly assumes. Since
    /// m23-o2 the house rule is to REPORT WHAT WAS DRAWN rather than let a
    /// probe recompute it from constants the view might have stopped using.
    var onCardMeasured: (_ width: Double, _ height: Double) -> Void
    /// Reports the FACE and INK the disclosure's own modifiers consumed, per
    /// role (`headline` / `body` / `footnote`, plus `background`). Either half
    /// may be nil — the two are reported by two different modifier arguments,
    /// so a mutation that replaces one call site leaves that half MISSING, and
    /// missing is what the gate leg fails on. See `honestyText`.
    ///
    /// Called during `body` evaluation on purpose. The receiver must therefore
    /// write somewhere Observation does not watch (`AppModel`'s ledger is a
    /// plain reference type for exactly this reason) — a tracked write here
    /// would invalidate the view that just made it.
    var onHonestyStyle: (_ role: String, _ face: String?, _ inkHex: String?) -> Void
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
    ///
    /// Read from `DAWAppKit` since m23-o2 rather than restated as a literal:
    /// the guidance row's legibility pin is a claim about how many characters
    /// fit at `cardWidth − 2 × cardPadding`, and a pin that reads a constant
    /// this view does not use would be a claim about nothing.
    private static let curveCardWidth = CGFloat(EQGuidanceLayout.cardWidth)
    /// The modal's own height cap — the frame this card is laid out inside.
    /// Named (and reported by `debug.effectEditor` as `cardMaxHeight`) since
    /// m23-p2: the honesty disclosure is the first content on this card whose
    /// height is a function of PROSE, and a card whose intrinsic height
    /// outgrows its own declared cap overflows the frame silently. The gate
    /// asserts the MEASURED height against this number, so the next person to
    /// lengthen a sentence learns it from a red check instead of from a
    /// screenshot.
    static let maxCardHeight: CGFloat = 560
    /// Where the disclosure's DRAWN face and ink land (m23-p2 review round).
    ///
    /// Deliberately outside Observation: `EffectEditorOverlay` reports from
    /// inside its own `.font`/`.foregroundStyle` ARGUMENTS, which run during
    /// `body`. That placement is what makes a mutation unable to change the
    /// drawing without changing the report — and it means the write must not
    /// invalidate the view making it. Read only by `debug.effectEditor`.
    ///
    /// The two halves arrive separately (a font argument and a colour
    /// argument), so an entry can legitimately be half-filled for one frame —
    /// and a PERMANENTLY half-filled entry is the signature of a call site that
    /// was replaced by a literal, which the gate fails on.
    @MainActor
    final class EffectHonestyStyleLedger {
        private(set) var entries: [String: (face: String?, ink: String?)] = [:]

        func record(role: String, face: String?, ink: String?) {
            var entry = entries[role] ?? (face: nil, ink: nil)
            if let face { entry.face = face }
            if let ink { entry.ink = ink }
            entries[role] = entry
        }

        func clear() { entries.removeAll() }
    }

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
                    .frame(maxHeight: Self.maxCardHeight)
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
        Self.showsCurveSurface(kind: model.kind, hasCurveModel: curveModel != nil,
                               density: densityStore.density(forPanel: Self.panelID))
    }

    /// ONE HOME for that rule (m23-r3): `debug.effectEditor`'s state read
    /// reports whether the SPECTRUM LAYER is on screen, and the layer is only
    /// on screen when this surface is — so the probe calls this rather than
    /// carrying a second copy that would stay green while the real gate moved.
    static func showsCurveSurface(kind: EffectDescriptor.Kind?, hasCurveModel: Bool,
                                  density: PanelDensity) -> Bool {
        kind == .eq && hasCurveModel && density == .simple
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider().overlay(DAWTheme.hairline)
            // The HONESTY DISCLOSURE (m23-p2): drawn for any kind whose stated
            // benefit is revelation while its mechanism is synthesis — the bass
            // enhancer today. Seated FIRST, above every control, because it has
            // to be read before the user reaches for a knob, and deliberately
            // OUTSIDE `knobSections` (a capped ScrollView): guidance that can be
            // scrolled out of frame is guidance `debug.captureUI` may photograph
            // as absent and a user may never scroll to.
            // No trailing `Divider()`: the block draws its own bordered
            // container, so a hairline under it would be a second seam saying
            // the same thing — and on a card this tall, 13 pt of chrome that
            // buys nothing is 13 pt the honest copy could have used.
            if let honestyNote { honestyBlock(honestyNote) }
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
                // the curve hint line (§5.5). The spectrum layer draws on EVERY
                // EQ card since m23-r3 (master mix, or this insert's own armed
                // tap) — the gate is ONE expression, in the headless model.
                EQCurveEditor(
                    editor: model,
                    model: curveModel,
                    showsSpectrum: EQCurveEditorModel.showsSpectrum(for: model.target),
                    help: curveHelp,
                    spectrum: spectrum,
                    guide: instrumentGuide,
                    holdSpectrum: holdSpectrum,
                    onPlotWidth: onPlotWidth)
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
        // The other half of the m23-o2 legibility pin's basis — see
        // `curveCardWidth`. One home for both numbers, in the tested module.
        .padding(CGFloat(EQGuidanceLayout.cardPadding))
        .background(DAWTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(DAWTheme.hairline, lineWidth: 1))
        // The card's REAL size, measured where it is drawn (never derived from
        // `sectionsHeight`/`cardWidth`, which cannot see a wrapping block).
        // Reported so a gate can assert the card still fits the window floor —
        // the honesty disclosure is the first thing on this card whose height
        // is a function of prose, and prose grows. `proxy.size` (not
        // `.height`) so the width the prose actually wraps inside is a
        // measurement too, not a constant a probe restates.
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onChange(of: proxy.size, initial: true) { _, measured in
                        onCardMeasured(Double(measured.width), Double(measured.height))
                    }
            }
        }
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

    // MARK: Honesty disclosure (m23-p2)

    /// The drawn disclosure for a kind that CREATES signal its input did not
    /// contain while its benefit is phrased as revelation. Every ink choice
    /// here is a refusal, and each refusal has a different reason
    /// (docs/DESIGN-LANGUAGE.md):
    ///
    /// - **Never violet.** Violet means AI-touched content (Rule 3). These
    ///   harmonics come from a Chebyshev shaper, not a model; violet would tell
    ///   the user something false about where the sound came from.
    /// - **Never amber.** Amber is warning ink. Using an effect as designed is
    ///   not a fault — the same call m23-o2 made when it refused to build an
    ///   amber "you are cutting into the fundamental" alarm.
    /// - **Never SF Mono.** In this app SF Mono means *numeric readout*. A
    ///   mono-face line a few points above the card's real readouts would read
    ///   as a measurement of the user's signal, which is the m23-o2
    ///   `HP 35 Hz` failure reached through a different door. The headline
    ///   therefore takes the group-micro-header register (system semibold,
    ///   tracked) and the prose takes the hint-line register.
    /// - **Never the dimmest text on the card.** The headline sits at
    ///   `textSecondary` — one step ABOVE the `textDim` knob labels — because a
    ///   disclosure rendered as fine print is its own honesty failure. The
    ///   prose sits at `textDim`, level with those labels, never below them.
    ///
    /// The block WRAPS rather than taking a fixed height (the m23-o2 fixed-row
    /// rule does not bite here): its copy is constant for the kind, so it can
    /// never resize the card on a retarget the way a per-family guidance row
    /// would. No `TimelineView` — nothing here moves (the m23-o2 static-layer
    /// rule: a timeline for everything that moves, and nothing that doesn't).
    private func honestyBlock(_ note: EffectHonestyNote) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "waveform.badge.plus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DAWTheme.textSecondary)
                honestyText(note.headline, role: "headline",
                            ink: DAWTheme.textSecondary,
                            size: 9, weight: .semibold, tracking: 0.9)
            }
            honestyText(note.body, role: "body", ink: DAWTheme.textDim, size: 9)
            honestyText(note.footnote, role: "footnote", ink: DAWTheme.textDim, size: 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        // The prose's contrast ratio is a claim about THIS fill, so the fill
        // reports itself the same way the text does — a gate comparing drawn
        // text against a background it merely assumed would be checking nothing.
        .background(reportedInk(DAWTheme.panelRaised, role: "background"))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(DAWTheme.hairline, lineWidth: 1))
        .accessibilityElement(children: .combine)
    }

    /// ONE line of disclosure copy — and the ONLY way this block draws text.
    ///
    /// It exists because of a hole a reviewer's mutation walked straight
    /// through: eleven mutations had pinned WHICH WORDS EXIST and WHERE THE
    /// BLOCK SITS, and none of them touched THE INK. Redrawing the prose in
    /// `DAWTheme.ai` — violet, which in this app means AI-generated content, so
    /// a disclosure about synthesized harmonics would have been claiming the
    /// COPY was machine-written — left the gate 42/42 GREEN.
    ///
    /// **The reporting is inside the modifier's ARGUMENT, and that placement is
    /// the whole mechanism.** The first fix reported from a sibling
    /// `.onChange` reading the same parameters, and the reviewer's literal
    /// mutation — `.foregroundStyle(ink)` → `.foregroundStyle(DAWTheme.ai)` —
    /// walked through it GREEN, because a report and a draw that are two
    /// statements naming the same value can be decoupled by editing one of
    /// them. `reportedFont`/`reportedInk` RETURN what they report, so the
    /// argument handed to `.font`/`.foregroundStyle` IS the reported value.
    /// A mutation now has exactly two options and both are red: change the
    /// argument (the report changes with it), or replace the whole call with a
    /// literal (the report never fires, and a role missing its face or ink
    /// fails the probe leg rather than passing quietly).
    private func honestyText(_ string: String, role: String, ink: Color,
                             size: CGFloat, weight: Font.Weight = .regular,
                             design: Font.Design = .default,
                             tracking: CGFloat = 0) -> some View {
        Text(string)
            .font(reportedFont(size: size, weight: weight, design: design, role: role))
            .tracking(tracking)
            .foregroundStyle(reportedInk(ink, role: role))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Builds the font, reports the FACE it was built with, and returns it.
    /// The face name comes from the `Font.Design` value itself
    /// (`"default"` / `"monospaced"`) — never from a parallel string that could
    /// disagree with what was drawn.
    private func reportedFont(size: CGFloat, weight: Font.Weight,
                              design: Font.Design, role: String) -> Font {
        onHonestyStyle(role, String(describing: design), nil)
        return .system(size: size, weight: weight, design: design)
    }

    /// Reports a colour and returns it, so the value that reaches the modifier
    /// is the value the probe publishes. Resolved through `NSColor` rather than
    /// echoed as a token name: a probe naming the token it INTENDED agrees with
    /// itself while the view draws something else (the m23-o2 `widthSource`
    /// lesson, in colour).
    private func reportedInk(_ ink: Color, role: String) -> Color {
        onHonestyStyle(role, nil, DAWTheme.hexString(ink))
        return ink
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
