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
        HStack(spacing: 8) {
            if let status {
                LoopDeckStrip(status: status,
                              playheadBeat: playheadBeat,
                              onToggleMute: onToggleMute)
                sessionControls
            } else {
                startControls
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Looper")
    }

    // MARK: - No session: the door

    private var startControls: some View {
        HStack(spacing: 6) {
            startChip
            // PRO ONLY. In Simple the row closes up to a single chip — no
            // placeholder, the `punchChip` rule.
            if isPro {
                barsStepper
                freeChip
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
    private var startChip: some View {
        Button { onStart(length) } label: {
            HStack(spacing: 5) {
                Image(systemName: "square.stack.3d.up")
                    .font(.system(size: 11, weight: .semibold))
                Text("LOOPER")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
            }
            .foregroundStyle(model.start.isEnabled ? DAWTheme.textDim : DAWTheme.textFaint)
            .padding(.horizontal, 9)
            .frame(height: 26)
            .background(DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(
                RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1)
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
        return HStack(spacing: 3) {
            CountInNudgeButton(label: "−") {
                length = .bars(LoopDeckControlModel.clampedBars(bars - 1))
            }
            .disabled(isFree || bars <= LoopDeckControlModel.barsRange.lowerBound)
            Text("\(bars) BAR")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(isFree ? DAWTheme.textFaint : DAWTheme.textSecondary)
                .frame(minWidth: 38)
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
    private var freeChip: some View {
        let isFree = length == .pressToEnd
        return Button {
            length = isFree ? LoopDeckControlModel.defaultLength : .pressToEnd
        } label: {
            Text("FREE")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(isFree ? DAWTheme.textPrimary : DAWTheme.textDim)
                .frame(height: 22)
                .padding(.horizontal, 7)
                .background(isFree ? DAWTheme.panelRaised : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isFree ? Color.white.opacity(0.18) : DAWTheme.hairline,
                                lineWidth: 1)
                )
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
        HStack(spacing: 5) {
            armButton
            DeckIconButton(systemName: "checkmark",
                           tint: DAWTheme.signal,
                           isLit: false,
                           command: model.finish,
                           accessibilityLabel: model.pendingPhase == .queued
                               ? "Cancel armed layer" : "Finish layer",
                           action: onFinish)
            // ⭐ PEEL IS ITS OWN GESTURE (looping rule ④) and its glyph says so:
            // the layer-undo arrow, not the app's general undo. See the header
            // note on why this does not route through the two-route destructive
            // pattern.
            DeckIconButton(systemName: "arrow.uturn.backward",
                           tint: DAWTheme.clip,
                           isLit: false,
                           command: model.peel,
                           accessibilityLabel: "Take back last layer",
                           action: onPeel)
            DeckIconButton(systemName: "xmark",
                           tint: DAWTheme.textPrimary,
                           isLit: false,
                           command: model.end,
                           accessibilityLabel: "End looper session",
                           action: onEnd)
        }
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
    private var armButton: some View {
        Menu {
            ForEach(model.armTargets) { track in
                Button(track.name) { onArm(track.id) }
            }
        } label: {
            Image(systemName: "record.circle")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(armInk)
                .frame(width: 26, height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(armFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(armStroke, lineWidth: model.pendingPhase == .recording ? 2 : 1)
                )
                .glow(DAWTheme.record, radius: 6, intensity: armGlow)
        } primaryAction: {
            if let target = model.primaryArmTarget { onArm(target) }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
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
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(command.isEnabled
                                 ? (isLit ? tint : DAWTheme.textDim)
                                 : DAWTheme.textFaint)
                .frame(width: 26, height: 26)
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
