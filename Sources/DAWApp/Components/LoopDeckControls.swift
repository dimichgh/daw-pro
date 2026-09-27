import SwiftUI
import DAWCore
import DAWAppKit

/// LIVE LOOPING, THE DOOR (m34-h-2) — the transport bar's loop-deck surface:
/// the control that OPENS a session, and the controls that drive one.
///
/// ⛔⛔ **THE ITEM THIS CLOSES: m34-h-1 SHIPPED A FULLY-BUILT LOOPER WITH NO
/// DOOR.** Engine, domain, seven `looper.*` wire verbs, seven MCP tools, three
/// test suites — and `LoopDeckStrip` mounted behind `if let deck =
/// store.loopDeckStatus`, i.e. visible only once a session exists, with nothing
/// anywhere in the app able to create one. The only way to start a loop deck was
/// to ask an AI agent over MCP. This file is the human's way in.
///
/// ⭐ **NO NEW CAPABILITY, NO NEW WIRE SURFACE.** Every button here calls a
/// `ProjectStore` method that already shipped and is already tested; the
/// command count is untouched. This is a UI layer over a tested API.
///
/// ⭐⭐ **DENSITY, DECIDED DELIBERATELY (docs/DESIGN-LANGUAGE.md "Panels"):**
///   • **The DOOR and every in-session control show in BOTH densities.** Rule 6
///     and the exact precedent this bar already sets twice — `musicalTypingToggle`
///     ("a beginner needs a way to play a note more than a pro does") and
///     `LoopDeckStrip` itself. Hiding the only entry point behind a mode chip
///     would recreate the no-door problem this item exists to fix, one level up.
///   • **The LENGTH CHOICE is PRO-ONLY.** The PUNCH precedent (an advanced
///     record window is Pro) plus the research's own argument for the default:
///     *you cannot pick a bad length because you never pick a length, only a bar
///     count.* Simple gets one press and a safe 4-bar loop; Pro reveals the bar
///     stepper and FREE (press-to-end). **The decision is advanced; the feature
///     is not.**
///
/// ⭐⭐ **NARROW WINDOWS (TB-F1, 2026-09-27): TWO COMPACT FORMS, CHOSEN BY A RULE,
/// NEVER BY `ViewThatFits`.** At the 1208 pt window floor an open session (226 pt
/// and up) did not fit the transport bar, and the glass panel's clip cut the
/// master meter and the SIMPLE/PRO toggle off its right edge. `TransportBarFit`
/// now decides, from the width the bar's right region is offered, when this
/// surface takes its compact form (`form: .compact`):
///   • an OPEN session becomes one glass capsule — the sweep and a BOUNDED box of
///     lamp bars — beside the four controls stacked 2 × 2 at 20 pt. The length
///     label and the track names leave the screen for the tooltips and the
///     accessibility labels; the light language, the one-click mute and the
///     pending-launch border all stay;
///   • Pro's CLOSED door becomes `[⧉][FREE]` over `[− 4 BAR +]`: the LOOPER word
///     goes to the tooltip, and the length choice keeps every word of its own.
/// The deck is stateful and animated, so the design language forbids wrapping it
/// in a `ViewThatFits`: the choice is the rule's, pinned headlessly by
/// `TransportBarFitTests`, and every compact size here READS `TransportBarFit`, so
/// the width the rule models is the width this file draws.
struct LoopDeckControls: View {
    /// nil when no session is open — this view is what offers to create one.
    let status: LoopDeckStatus?
    /// Absolute playhead beat. ⚠️ **LOAD-BEARING, NOT DECORATION:**
    /// `loopDeckStatus` pins `cyclePhase` to 0 whenever `cycleBeats == nil`, so
    /// in press-to-end mode — before the first layer has decided the length —
    /// every cycle-derived animation freezes. That is the one mode where the
    /// wait is longest and most needs a live indicator. The bar's phase is the
    /// fallback. See `LoopDeckPulse`.
    let playheadBeat: Double
    /// The resolved availability set. Passed in rather than computed here so a
    /// preview and the live bar share one decision.
    let model: LoopDeckControlModel
    /// Pro reveals the length choice; the door itself is in both densities.
    let isPro: Bool
    /// TB-F1: the form the transport's fit rule chose — `.full` is everything
    /// this file drew before TB-F1; `.compact` is the narrow-window form (header).
    var form: TransportBarFit.Form = .full
    /// TB-F1: the compact deck's lamp box, from the same plan. Bounded, so the
    /// compact deck's width never grows with the layer count.
    var lampBoxWidth: CGFloat = TransportBarFit.CompactDeck.lampBoxFloor
    /// The pending START choice, held by the caller so it survives this view's
    /// identity and can be driven from a preview.
    @Binding var length: LoopDeckControlModel.LengthChoice

    var onStart: (LoopDeckControlModel.LengthChoice) -> Void
    var onArm: (UUID) -> Void
    var onFinish: () -> Void
    var onPeel: () -> Void
    var onEnd: () -> Void
    var onToggleMute: (UUID, Bool) -> Void

    var body: some View {
        HStack(spacing: form == .compact
               ? TransportBarFit.CompactDeck.capsuleToControls
               : TransportBarFit.FullDeck.stripToControls) {
            if let status {
                if form == .compact {
                    compactStrip(status)
                    compactSessionControls
                } else {
                    LoopDeckStrip(status: status,
                                  playheadBeat: playheadBeat,
                                  onToggleMute: onToggleMute)
                    sessionControls
                }
            } else if form == .compact {
                tightStartControls
            } else {
                startControls
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Looper")
    }

    // MARK: - No session: the door

    /// ⭐ **NARROW WINDOWS (TB, 2026-09-25): THE DOOR NEVER BREAKS A WORD.** At
    /// the 1208 pt window floor this surface used to be squeezed like the rest
    /// of the bar — `LOO`/`PER` in Simple, and in Pro the length choice lost
    /// its FREE label entirely. Now it is a `ViewThatFits` of two forms, widest
    /// first, and the transport bar's `collapsePriority` decides WHEN this
    /// surface gives way (first in Pro, where the give loses no word; last in
    /// Simple, where it does):
    ///   ① the full row — the door, then (Pro) the length choice beside it;
    ///   ② Pro: the length choice rides UNDER the door, the bar's own
    ///      CLICK-over-count-in idiom (m15-b) — every word stays on screen,
    ///      201 pt becomes ~106, and the column (26 + 2 + 11) stays inside the
    ///      bar's 44 pt row; Simple: the door drops its WORD and keeps its glyph
    ///      (`TransportChipFace`), with the tooltip and the accessibility label
    ///      still saying "looper".
    private var startControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                startChip(compact: false)
                // PRO ONLY. In Simple the row closes up to a single chip — no
                // placeholder, the `punchChip` rule.
                if isPro {
                    barsStepper
                    freeChip(mini: false)
                }
            }
            if isPro {
                VStack(spacing: 2) {
                    startChip(compact: false)
                    HStack(spacing: 3) {
                        barsStepper
                        freeChip(mini: true)
                    }
                }
            } else {
                startChip(compact: true)
            }
        }
    }

    /// ⭐ **THE TIGHT DOOR (TB-F1) — WHEN EVEN THE STACKED FORM CANNOT FIT.** Pro
    /// with a notices chip at the 1208 pt floor was 38.5 pt over with every TB give
    /// taken; the stacked door (107.5) is the widest thing left that can give. Here
    /// the door drops its WORD (the tooltip and the accessibility label still say
    /// "looper"), FREE moves up beside it, and the stepper keeps the row under it —
    /// so the row the stacked form spent on FREE is gone, and the width is the
    /// stepper's alone (`TransportBarFit.TightDoor.width`, 72 pt). Every word of
    /// the length choice stays on screen. Simple's door has no length choice: its
    /// tight form is TB's glyph, whole.
    ///
    /// Chosen by `TransportBarFit`, never by `ViewThatFits` — the rule tests the fit
    /// of the whole bar, which a single chip's `ViewThatFits` cannot see.
    private var tightStartControls: some View {
        Group {
            if isPro {
                VStack(alignment: .leading, spacing: TransportBarFit.TightDoor.rowGap) {
                    HStack(spacing: TransportBarFit.TightDoor.rowSpacing) {
                        startChip(compact: true)
                        freeChip(mini: false)
                    }
                    barsStepper
                }
            } else {
                startChip(compact: true)
            }
        }
    }

    /// ⭐ **NEUTRAL CHROME AT REST — Rule 3, read exactly as written:** *"Create
    /// /add affordances are neutral chrome — `textPrimary` on the raised chip,
    /// no accent and no glow at rest; an accent is earned by state, not by
    /// inviting a click."* This chip creates a session. It gets no accent until
    /// there is one, at which point it is replaced by the strip, which is all
    /// accent.
    ///
    /// ⚠️ The glyph is a STACK, not a repeat arrow. The transport's own `LOOP`
    /// chip is eight points away and means the opposite thing (take comping);
    /// giving this one the loop glyph would pair the two controls that must
    /// never be confused. The word "LOOPER" matches the `looper.*` verbs an
    /// agent transcript shows, so the UI and the AI use one vocabulary.
    private func startChip(compact: Bool) -> some View {
        Button { onStart(length) } label: {
            TransportChipFace(
                systemName: "square.stack.3d.up",
                word: "LOOPER",
                compact: compact,
                ink: model.start.isEnabled ? DAWTheme.textDim : DAWTheme.textFaint
            )
        }
        .buttonStyle(.plain)
        .disabled(!model.start.isEnabled)
        .help(model.start.help)
        .accessibilityLabel("Start looper session")
        .accessibilityHint(model.start.help)
    }

    /// The bar count. `CountInNudgeButton` at the bar's own stepper scale — the
    /// idiom `countInStepper` already sets, so a second stepper in the same bar
    /// looks like the first one.
    private var barsStepper: some View {
        let bars: Int = {
            if case .bars(let n) = length { return n }
            return 4
        }()
        let isFree = length == .pressToEnd
        return HStack(spacing: TransportBarFit.LengthChoice.stepperSpacing) {
            CountInNudgeButton(label: "−") {
                length = .bars(LoopDeckControlModel.clampedBars(bars - 1))
            }
            .disabled(isFree || bars <= LoopDeckControlModel.barsRange.lowerBound)
            Text("\(bars) BAR")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(isFree ? DAWTheme.textFaint : DAWTheme.textSecondary)
                .frame(minWidth: TransportBarFit.LengthChoice.barsReadoutMinWidth)
                .fixedSize()
            CountInNudgeButton(label: "+") {
                length = .bars(LoopDeckControlModel.clampedBars(bars + 1))
            }
            .disabled(isFree || bars >= LoopDeckControlModel.barsRange.upperBound)
        }
        .help("Loop length in bars (1–64). The safe default: you never pick a "
              + "length, only a bar count.")
        .accessibilityLabel("Loop length \(bars) bars")
    }

    /// Press-to-end. ⭐ **NO ACCENT WHEN SELECTED, AND THAT IS RULE 3 APPLIED
    /// RATHER THAN AN OVERSIGHT:** the deck's accents are AMBER = being written
    /// to and CYAN = sounding, and this is neither — it is a session *setting*
    /// chosen before anything is live. It brightens to `textPrimary` on a
    /// brighter hairline instead, so "selected" is unmistakable without
    /// spending a semantic colour on a value that makes no sound.
    ///
    /// `mini` is the narrow-window form (TB): the same word and the same
    /// selected treatment at the count-in row's 11 pt height, so it can ride
    /// under the door beside the bar stepper.
    private func freeChip(mini: Bool) -> some View {
        let isFree = length == .pressToEnd
        let corner: CGFloat = mini ? 2 : 4
        return Button {
            length = isFree ? LoopDeckControlModel.defaultLength : .pressToEnd
        } label: {
            Text("FREE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(isFree ? DAWTheme.textPrimary : DAWTheme.textDim)
                .lineLimit(1)
                .frame(height: mini ? 11 : 22)
                .padding(.horizontal, mini ? 4 : 7)
                .background(isFree ? DAWTheme.panelRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: corner))
                .overlay(
                    RoundedRectangle(cornerRadius: corner)
                        .stroke(isFree ? Color.white.opacity(0.18) : DAWTheme.hairline,
                                lineWidth: 1)
                )
                .fixedSize()
        }
        .buttonStyle(.plain)
        .help("Free length — you press FINISH when the first layer should end, and "
              + "that sets the loop (rounded to the nearest bar).")
        .accessibilityLabel("Free loop length")
        .accessibilityAddTraits(isFree ? [.isSelected] : [])
    }

    // MARK: - Session open: the controls

    /// ⭐ **ICON-ONLY, WHICH IS THIS BAR'S OWN IDIOM, NOT A SHORTCUT.** Play,
    /// pause, record and panic are all glyph-only `TransportButton`s. Rule 6 is
    /// satisfied by the tooltip, which is a full beginner-readable sentence on
    /// every one of these — including, and especially, when the control is
    /// unavailable and the sentence is the *reason*.
    private var sessionControls: some View {
        let side = TransportBarFit.FullDeck.controlSide
        return HStack(spacing: TransportBarFit.FullDeck.controlSpacing) {
            armButton(side: side, glyphSize: 13)
            finishButton(side: side, glyphSize: 12)
            peelButton(side: side, glyphSize: 12)
            endButton(side: side, glyphSize: 12)
        }
    }

    /// TB-F1 — the same four controls, stacked 2 × 2 at 20 pt so they fit inside
    /// the bar's 44 pt row: 48 pt wide instead of the row's 119. Two ROWS, not two
    /// columns, so the reading order is the full row's (arm, finish / take back,
    /// end) for VoiceOver too. The first column is the ARM menu's MEASURED 25 pt box
    /// (`TransportBarFit.CompactDeck.armColumnWidth`) and TAKE BACK is framed to it,
    /// so the chips line up in columns. The glyphs stay at 11 and 10 pt (above the
    /// 8 pt floor), and every control keeps its tooltip sentence and its
    /// accessibility label — and the ARM its light, drawn outside its menu
    /// (`armButton`), since a press whose effect is invisible invites a double-fire
    /// at any size.
    private var compactSessionControls: some View {
        let side = TransportBarFit.CompactDeck.controlSide
        let glyph = TransportBarFit.CompactDeck.controlGlyphSize
        let armColumn = TransportBarFit.CompactDeck.armColumnWidth
        return VStack(spacing: TransportBarFit.CompactDeck.controlSpacing) {
            HStack(spacing: TransportBarFit.CompactDeck.controlSpacing) {
                armButton(side: side, glyphSize: TransportBarFit.CompactDeck.armGlyphSize,
                          columnWidth: armColumn)
                finishButton(side: side, glyphSize: glyph)
            }
            HStack(spacing: TransportBarFit.CompactDeck.controlSpacing) {
                peelButton(side: side, glyphSize: glyph)
                    .frame(width: armColumn)
                endButton(side: side, glyphSize: glyph)
            }
        }
    }

    private func finishButton(side: CGFloat, glyphSize: CGFloat) -> some View {
        DeckIconButton(systemName: "checkmark",
                       tint: DAWTheme.signal,
                       isLit: false,
                       command: model.finish,
                       accessibilityLabel: model.pendingPhase == .queued
                           ? "Cancel armed layer" : "Finish layer",
                       side: side,
                       glyphSize: glyphSize,
                       action: onFinish)
    }

    /// ⭐ PEEL IS ITS OWN GESTURE (looping rule ④) and its glyph says so: the
    /// layer-undo arrow, not the app's general undo. See the header note on why
    /// this does not route through the two-route destructive pattern.
    private func peelButton(side: CGFloat, glyphSize: CGFloat) -> some View {
        DeckIconButton(systemName: "arrow.uturn.backward",
                       tint: DAWTheme.clip,
                       isLit: false,
                       command: model.peel,
                       accessibilityLabel: "Take back last layer",
                       side: side,
                       glyphSize: glyphSize,
                       action: onPeel)
    }

    private func endButton(side: CGFloat, glyphSize: CGFloat) -> some View {
        DeckIconButton(systemName: "xmark",
                       tint: DAWTheme.textPrimary,
                       isLit: false,
                       command: model.end,
                       accessibilityLabel: "End looper session",
                       side: side,
                       glyphSize: glyphSize,
                       action: onEnd)
    }

    /// ARM — the one control with a choice attached, so it is the one `Menu`.
    ///
    /// ⭐ **PRIMARY ACTION ARMS THE TRACK YOU ARE ALREADY PLAYING.** A plain
    /// click arms `primaryArmTarget` (the arrange view's active track when it is
    /// an instrument track — the same track Musical Typing sounds); holding
    /// opens the list. One click for the common case, no modal for the other.
    ///
    /// ⛔ **THE MENU LISTS INSTRUMENT TRACKS ONLY.** `armLoopLayer` throws
    /// `trackKindUnsupported` on an audio track, so listing one would be
    /// offering an entry whose only possible outcome is a refusal.
    ///
    /// ⭐⭐ **THIS BUTTON REPORTS ITS OWN OUTCOME IN THE DECK'S LIGHT LANGUAGE**
    /// — amber, flashing on the beat while `queued`, solid and breathing while
    /// `recording`, draining while `closing`. The research's finding is that a
    /// press whose effect is invisible reads as ignored and invites a second
    /// press that would double-fire; the press that arms a layer produces
    /// nothing audible for up to a whole cycle, so it must produce something
    /// visible immediately.
    ///
    /// ⛔ **THE CHIP AND ITS LIGHT ARE DRAWN OUTSIDE THE MENU, BECAUSE macOS
    /// FLATTENS A BORDERLESS MENU'S LABEL (found by TB-F1, 2026-09-27).** Until
    /// then the fill, the stroke and the glow sat INSIDE the label, and the
    /// platform drew the label as a flat template glyph: TB's 1600 pt capture and
    /// TB-F1's recording probe both show a bare grey ◉ with no chip and no amber,
    /// under a comment promising an amber, breathing chip. Now the chip is a
    /// BACKGROUND the menu is drawn over — the same `Menu`, style and
    /// `primaryAction`, so the click and the hold behave exactly as before. The
    /// glyph's own ink stays the platform's.
    ///
    /// `columnWidth` is the layout box, when it differs from the chip. The menu is
    /// laid out at its own size — 25 pt at the compact 20 pt label
    /// (`TransportBarFit.CompactDeck.armColumnWidth`) — so it is framed to a known
    /// column, and the chip is drawn at `side` in the middle of it.
    private func armButton(side: CGFloat, glyphSize: CGFloat, columnWidth: CGFloat? = nil) -> some View {
        let chip = RoundedRectangle(cornerRadius: 5, style: .continuous)
        return Menu {
            ForEach(model.armTargets) { track in
                Button(track.name) { onArm(track.id) }
            }
        } label: {
            Image(systemName: "record.circle")
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(armInk)
        } primaryAction: {
            if let target = model.primaryArmTarget { onArm(target) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: columnWidth ?? side, height: side)
        .background(
            chip.fill(armFill)
                .overlay(chip.stroke(armStroke, lineWidth: model.pendingPhase == .recording ? 2 : 1))
                .glow(DAWTheme.record, radius: 6, intensity: armGlow)
                .frame(width: side, height: side)
        )
        .disabled(!model.arm.isEnabled)
        .help(model.arm.help)
        .accessibilityLabel("Arm layer")
        .accessibilityHint(model.arm.help)
    }

    /// The pulse every animated value on this surface derives from — the same
    /// one the strip uses, so the button and the lamp blink together rather than
    /// nearly together.
    private var pulse: LoopDeckPulse {
        LoopDeckPulse(status: status, playheadBeat: playheadBeat)
    }

    private var armInk: Color {
        model.pendingPhase == nil
            ? (model.arm.isEnabled ? DAWTheme.textDim : DAWTheme.textFaint)
            : DAWTheme.record
    }

    private var armFill: Color {
        switch model.pendingPhase {
        case .none: return DAWTheme.panelRaised
        case .queued: return DAWTheme.record.opacity(pulse.onBeat ? 0.45 : 0.10)
        case .recording: return DAWTheme.record.opacity(0.55 + 0.25 * (1 - pulse.phase))
        case .closing: return DAWTheme.record.opacity(0.50 * (1 - pulse.phase) + 0.12)
        }
    }

    private var armStroke: Color {
        switch model.pendingPhase {
        case .none: return DAWTheme.hairline
        case .queued: return DAWTheme.record.opacity(pulse.onBeat ? 0.95 : 0.35)
        case .recording, .closing: return DAWTheme.record
        }
    }

    private var armGlow: Double {
        switch model.pendingPhase {
        case .none: return 0
        case .queued: return pulse.onBeat ? 0.5 : 0
        case .recording: return 0.65
        case .closing: return 0.35
        }
    }

    // MARK: - TB-F1: the compact session capsule

    /// ⭐ **THE COMPACT DECK: STILL STATE BY LIGHT, STILL ONE CLICK TO MUTE.** One
    /// glass capsule holding the cycle sweep and a lamp bar per layer, at the
    /// strip's own 30 pt height (the capsule is 42 pt, the empty full strip's).
    /// What leaves the screen is TEXT only — the "LOOP / 4 BAR" label and the track
    /// names under the lamps — and it lands in the capsule's tooltip and
    /// accessibility value and in each bar's tooltip and accessibility label
    /// (`TransportDeckCopy`). The capsule's border and glow still run the strip's
    /// pending-launch light (queued flashes, recording breathes, closing drains).
    ///
    /// ⭐ **THE LAMP BOX IS BOUNDED** (`TransportBarFit.lampBoxWidth`): past its
    /// ideal width the bars SHARE the box instead of widening it, so the compact
    /// deck is as wide at twelve layers as at three and can never push the toggle
    /// off the bar. The bars keep the strip's reading order, left to right.
    private func compactStrip(_ status: LoopDeckStatus) -> some View {
        let pulse = LoopDeckPulse(status: status, playheadBeat: playheadBeat)
        let deck = TransportBarFit.CompactDeck.self
        let bars = TransportBarFit.compactLampLayout(count: status.lamps.count, boxWidth: lampBoxWidth)
        return HStack(spacing: deck.sweepSpacing) {
            compactSweep(phase: status.cyclePhase)
            if status.lamps.isEmpty {
                // No layer yet: the dim outline of the first bar (the strip's
                // empty-slot hint, at bar scale) — a shape, not a sentence.
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(DAWTheme.textFaint.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .frame(width: deck.lampIdealWidth, height: deck.lampHeight)
            } else {
                HStack(spacing: bars.gap) {
                    ForEach(status.lamps, id: \.layerID) { lamp in
                        compactLamp(lamp, width: bars.barWidth, pulse: pulse)
                    }
                }
                .frame(width: lampBoxWidth, alignment: .leading)
            }
        }
        .padding(deck.capsulePadding)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DAWTheme.panelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(CompactDeckLight.deckStroke(status.pendingPhase, pulse),
                                      lineWidth: CompactDeckLight.deckStrokeWidth(status.pendingPhase))
                )
                .glow(DAWTheme.record, radius: 8,
                      intensity: CompactDeckLight.deckGlow(status.pendingPhase, pulse))
        )
        .help(TransportDeckCopy.compactDeckHelp(cycleBeats: status.cycleBeats,
                                                beatsPerBar: status.beatsPerBar))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop deck")
        .accessibilityValue(TransportDeckCopy.compactDeckAccessibilityValue(
            cycleBeats: status.cycleBeats, beatsPerBar: status.beatsPerBar,
            layerCount: status.lamps.count,
            pendingPhrase: CompactDeckLight.pendingPhrase(status.pendingPhase)))
    }

    /// The cycle sweep at the strip's scale. ⚠️ Reads the RAW `cyclePhase`, never
    /// the pulse's bar fallback — the strip's own rule: before the first layer
    /// decides the length there is no loop to show progress through.
    private func compactSweep(phase: Double) -> some View {
        let deck = TransportBarFit.CompactDeck.self
        return ZStack(alignment: .bottom) {
            Capsule().fill(DAWTheme.playback.opacity(0.14))
            Capsule()
                .fill(DAWTheme.playback)
                .frame(height: max(2, deck.lampHeight * phase))
                .shadow(color: DAWTheme.playback.opacity(0.6), radius: 4)
        }
        .frame(width: deck.sweepWidth, height: deck.lampHeight)
    }

    /// One layer as a lamp BAR — and, as on the strip, the bar is the mute button.
    /// Its tooltip and accessibility label are the strip lamp's, verbatim, so the
    /// track name the caption showed is one hover (or one VoiceOver stop) away.
    private func compactLamp(_ lamp: LoopDeckStatus.Lamp, width: CGFloat,
                             pulse: LoopDeckPulse) -> some View {
        Button { onToggleMute(lamp.layerID, !lamp.isMuted) } label: {
            RoundedRectangle(cornerRadius: min(2, width / 2), style: .continuous)
                .fill(CompactDeckLight.fill(lamp.state, pulse))
                .overlay(
                    RoundedRectangle(cornerRadius: min(2, width / 2), style: .continuous)
                        // 1 pt, not the strip's 1.5–2 (that would halve a 6 pt bar);
                        // under 4 pt a bar is all fill — a border would eat it.
                        .strokeBorder(CompactDeckLight.stroke(lamp.state, pulse),
                                      lineWidth: width >= 4 ? 1 : 0)
                )
                .shadow(color: CompactDeckLight.glow(lamp.state, pulse),
                        radius: CompactDeckLight.glowRadius(lamp.state))
                .frame(width: width, height: TransportBarFit.CompactDeck.lampHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(lamp.trackName) loop layer, \(lamp.state.rawValue)")
        .accessibilityHint(lamp.isMuted ? "Unmute this layer" : "Mute this layer")
        .accessibilityAddTraits(lamp.isMuted ? [.isSelected] : [])
        .help(lamp.isMuted
              ? "\(lamp.trackName) — muted. Click to bring it back."
              : "\(lamp.trackName) — playing. Click to drop it out.")
    }
}

/// TB-F1 — the compact deck's light language: the SAME numbers `LoopDeckStrip`
/// draws its lamps and chrome with (amber = being written to, cyan = sounding,
/// slate = silent; queued flashes, recording breathes, closing drains), so a
/// layer looks the same in both forms.
///
/// ⚠️ **A SECOND HOME, RECORDED NOT HIDDEN.** The strip's copy of these numbers is
/// private to `LoopDeckStrip.swift`, which this lane does not own. Follow-up for
/// its owner: expose one table both forms read. Until then, a change to the
/// strip's light must be made here too.
private enum CompactDeckLight {
    static func fill(_ state: LoopLayerState, _ pulse: LoopDeckPulse) -> Color {
        switch state {
        case .queued: return DAWTheme.record.opacity(pulse.onBeat ? 0.55 : 0.10)
        case .recording: return DAWTheme.record.opacity(0.70 + 0.25 * (1 - pulse.phase))
        case .closing: return DAWTheme.record.opacity(0.65 * (1 - pulse.phase) + 0.15)
        case .playing: return DAWTheme.playback.opacity(0.34 + 0.22 * (1 - pulse.phase))
        case .muted: return DAWTheme.textFaint.opacity(0.10)
        }
    }

    static func stroke(_ state: LoopLayerState, _ pulse: LoopDeckPulse) -> Color {
        switch state {
        case .queued: return DAWTheme.record.opacity(pulse.onBeat ? 0.95 : 0.35)
        case .recording, .closing: return DAWTheme.record
        case .playing: return DAWTheme.playback.opacity(0.85)
        case .muted: return DAWTheme.textFaint.opacity(0.55)
        }
    }

    static func glow(_ state: LoopLayerState, _ pulse: LoopDeckPulse) -> Color {
        switch state {
        case .recording: return DAWTheme.record.opacity(0.75)
        case .queued: return DAWTheme.record.opacity(pulse.onBeat ? 0.55 : 0)
        case .closing: return DAWTheme.record.opacity(0.4)
        case .playing: return DAWTheme.playback.opacity(0.45)
        case .muted: return .clear
        }
    }

    static func glowRadius(_ state: LoopLayerState) -> CGFloat {
        switch state {
        case .recording: return 7
        case .queued, .closing: return 5
        case .playing: return 4
        case .muted: return 0
        }
    }

    static func deckStroke(_ phase: LoopPendingLayer.Phase?, _ pulse: LoopDeckPulse) -> Color {
        switch phase {
        case .none: return DAWTheme.hairline
        case .queued: return DAWTheme.record.opacity(pulse.onBeat ? 0.90 : 0.22)
        case .recording: return DAWTheme.record.opacity(0.70 + 0.25 * (1 - pulse.phase))
        case .closing: return DAWTheme.record.opacity(0.55 * (1 - pulse.phase) + 0.15)
        }
    }

    static func deckStrokeWidth(_ phase: LoopPendingLayer.Phase?) -> CGFloat {
        switch phase {
        case .none: return 1
        case .queued, .closing: return 1.5
        case .recording: return 2
        }
    }

    static func deckGlow(_ phase: LoopPendingLayer.Phase?, _ pulse: LoopDeckPulse) -> Double {
        switch phase {
        case .none: return 0
        case .queued: return pulse.onBeat ? 0.45 : 0
        case .recording: return 0.30 + 0.25 * (1 - pulse.phase)
        case .closing: return 0.30 * (1 - pulse.phase)
        }
    }

    /// The strip's spoken state (its `deckAccessibilityValue`), nil when no layer
    /// is pending — the caller then speaks the layer count.
    static func pendingPhrase(_ phase: LoopPendingLayer.Phase?) -> String? {
        switch phase {
        case .none: return nil
        case .queued: return "layer armed, waiting for the loop boundary"
        case .recording: return "recording a layer"
        case .closing: return "layer ending on the boundary"
        }
    }
}

/// One in-session control. Square, glyph-only, at the strip's own scale.
///
/// ⚠️ **`.disabled` IS NOT THE WHOLE STORY AND THAT IS THE POINT** — every one
/// of these carries `command.help`, which is the *refusal sentence* when the
/// control is off. A greyed control that explains itself is a taught user; a
/// live control that swallows a `try?` is a dead press.
struct DeckIconButton: View {
    var systemName: String
    /// The colour this control uses when it is the meaningful one to press.
    var tint: Color
    /// Reserved for controls that carry live state; the three that use this
    /// today are momentary, so they never light.
    var isLit: Bool
    var command: LoopDeckControlModel.Command
    var accessibilityLabel: String
    /// The square's side: the bar's 26 pt, or the compact deck's 20 (TB-F1).
    var side: CGFloat = TransportBarFit.FullDeck.controlSide
    var glyphSize: CGFloat = 12
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: glyphSize, weight: .semibold))
                .foregroundStyle(command.isEnabled
                                 ? (isLit ? tint : DAWTheme.textDim)
                                 : DAWTheme.textFaint)
                .frame(width: side, height: side)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isLit ? tint.opacity(0.18) : DAWTheme.panelRaised)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(isLit ? tint.opacity(0.55) : DAWTheme.hairline, lineWidth: 1)
                )
                .glow(tint, radius: 6, intensity: isLit ? 0.45 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!command.isEnabled)
        .help(command.help)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(command.help)
    }
}
