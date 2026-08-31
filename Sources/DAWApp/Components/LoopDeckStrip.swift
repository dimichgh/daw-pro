import SwiftUI
import DAWCore
import DAWAppKit

/// LIVE LOOPING (m34-h-1) — the loop deck's lamp strip: what is armed, what is
/// recording, and what is playing, **read without looking away from your
/// hands.**
///
/// ⛔⛔ **STATE IS SHOWN BY LIGHT, NEVER BY TEXT — rule ⑤ of the
/// Boss/Ableton/Loopy convergence, and a rule this tree has already broken
/// once.** m34-i shipped ten numeric badges of which four read "1"; the user's
/// report was that they were unreadable while playing. A performer's eyes are
/// on their hands or their instrument, so every LIVE value here is a colour, a
/// brightness or a motion. The two pieces of text on the strip are deliberately
/// NOT live state:
///   • the loop length (`4 BAR`) is a session SETTING, fixed for the whole
///     performance and glanced at once;
///   • each lamp's caption is its TRACK NAME — the *"show assignment on the
///     screen"* the user asked for by name.
///
/// ⭐ **THE BLINK IS DRIVEN BY THE MUSIC, NOT BY A WALL CLOCK.** Every animated
/// value here is a function of `cyclePhase` (0..<1 through the loop), so the
/// queued lamp flashes ON THE BEAT and the playing lamps breathe with the
/// cycle. That is better to play to than an arbitrary 2 Hz blink — and it also
/// makes a screenshot deterministic, which a `repeatForever` animation is not.
struct LoopDeckStrip: View {
    let status: LoopDeckStatus
    /// Absolute playhead beat — the `LoopDeckPulse` fallback's only input.
    /// Defaulted so a preview can render one frame with no transport.
    var playheadBeat: Double = 0
    /// Toggling a layer's mute. Defaulted to a no-op so a preview of the pure
    /// look needs no store.
    var onToggleMute: (UUID, Bool) -> Void = { _, _ in }

    private var pulse: LoopDeckPulse { LoopDeckPulse(status: status, playheadBeat: playheadBeat) }

    /// The phase every STATE animation derives from — falls back to the bar when
    /// there is no cycle yet (see `LoopDeckPulse`).
    private var phase: Double { pulse.phase }

    private var onBeat: Bool { pulse.onBeat }

    /// ⚠️ **THE SWEEP IS THE ONE THING THAT MUST *NOT* USE THE FALLBACK.** Every
    /// state animation here reads `phase` (which falls back to the bar so a
    /// press-to-end session still visibly blinks), but the sweep means *"where
    /// you are in the loop"* — and before the first layer decides the length
    /// there is genuinely nowhere to be. A sweep animating on the bar would draw
    /// cycle progress the session does not have, which is exactly the lie the
    /// `—` length label beside it exists to avoid. So it reads raw.
    private var sweepPhase: Double { status.cyclePhase }

    var body: some View {
        HStack(spacing: 10) {
            cycleSweep
            if status.lamps.isEmpty {
                emptyDeckHint
            } else {
                HStack(spacing: 8) {
                    ForEach(status.lamps, id: \.layerID) { lamp in
                        lampView(lamp)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DAWTheme.panelRaised)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(deckStroke, lineWidth: deckStrokeWidth)
                )
                .glow(DAWTheme.record, radius: 8, intensity: deckGlow)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Loop deck")
        .accessibilityValue(deckAccessibilityValue)
    }

    // MARK: The pending-launch state, at the size of the whole strip
    //
    // ⭐⭐ **THE STRIP'S OWN CHROME IS THE PENDING-LAUNCH INDICATOR (m34-h-2),
    // AND IT IS THE BIGGEST TARGET THIS FEATURE HAS.** A 26×22 lamp flashing
    // amber is correct and is already shipped — but it is 26 points wide in a
    // bar full of chips, and *"armed but not yet recording"* is the single state
    // a performer most needs from the corner of their eye, because it is the
    // whole point of quantized launch: the press has landed, the recording has
    // not started, and the gap between the two is up to a full cycle long.
    // Promoting that state to the strip's border and glow costs NO new data
    // (`pendingPhase` and the pulse are already here) and makes the entire
    // component the indicator. It is the same three-word vocabulary the lamps
    // use — queued FLASHES, recording BREATHES, closing DRAINS — so nothing new
    // has to be learned.
    //
    // ⛔ NO TEXT. The strip's two strings stay what they were: a session SETTING
    // and the track names.

    private var deckStroke: Color {
        switch status.pendingPhase {
        case .none: return DAWTheme.hairline
        case .queued: return DAWTheme.record.opacity(onBeat ? 0.90 : 0.22)
        case .recording: return DAWTheme.record.opacity(0.70 + 0.25 * (1 - phase))
        case .closing: return DAWTheme.record.opacity(0.55 * (1 - phase) + 0.15)
        }
    }

    private var deckStrokeWidth: CGFloat {
        switch status.pendingPhase {
        case .none: return 1
        case .queued, .closing: return 1.5
        case .recording: return 2
        }
    }

    private var deckGlow: Double {
        switch status.pendingPhase {
        case .none: return 0
        case .queued: return onBeat ? 0.45 : 0
        case .recording: return 0.30 + 0.25 * (1 - phase)
        case .closing: return 0.30 * (1 - phase)
        }
    }

    /// The one place the deck's state IS spoken — VoiceOver has no colour and no
    /// glow, so the rule "state by light, never text" is a rule about PIXELS and
    /// the accessibility layer is its exception, not its violation.
    private var deckAccessibilityValue: String {
        switch status.pendingPhase {
        case .none: return "\(status.lamps.count) layers"
        case .queued: return "layer armed, waiting for the loop boundary"
        case .recording: return "recording a layer"
        case .closing: return "layer ending on the boundary"
        }
    }

    // MARK: The cycle sweep — where you are in the loop

    /// A vertical bar that fills as the cycle runs, plus the loop length. The
    /// SWEEP is the live part and carries no digits; the length beside it is
    /// the session setting.
    private var cycleSweep: some View {
        HStack(spacing: 6) {
            ZStack(alignment: .bottom) {
                Capsule().fill(DAWTheme.playback.opacity(0.14))
                Capsule()
                    .fill(DAWTheme.playback)
                    .frame(height: max(2, 30 * sweepPhase))
                    .shadow(color: DAWTheme.playback.opacity(0.6), radius: 4)
            }
            .frame(width: 4, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("LOOP")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(DAWTheme.textDim)
                Text(lengthLabel)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DAWTheme.textSecondary)
            }
            // ⚠️⚠️ **`fixedSize` IS LOAD-BEARING, AND A SCREENSHOT IS THE ONLY
            // THING THAT COULD HAVE CAUGHT ITS ABSENCE.** The transport bar is
            // one long `HStack` with a `Spacer`, and SwiftUI compressed this
            // two-line label to ~2 pt of width when the strip appeared: the
            // MEASURED render showed two thin vertical slivers where "LOOP" and
            // "2 BAR" should have been, which reads as a stray dashed rule. No
            // assertion in this tree can see that — the view "rendered", the
            // status was correct, and every leg of the m34-h-1 gate was green.
            .fixedSize()
        }
    }

    /// The loop length as bars, or an em dash while press-to-end has not decided
    /// it yet. ⚠️ The dash is the honest answer: a "0" or a guessed "4" would be
    /// a number the session does not have.
    private var lengthLabel: String {
        guard let cycleBeats = status.cycleBeats, status.beatsPerBar > 0 else { return "—" }
        let bars = cycleBeats / status.beatsPerBar
        let whole = Int(bars.rounded())
        return abs(bars - Double(whole)) < 0.01 ? "\(whole) BAR" : String(format: "%.2f", bars)
    }

    private var emptyDeckHint: some View {
        // No lamps yet. Deliberately a DIM OUTLINE of the first slot rather than
        // a sentence: it shows the shape of what is coming without asking the
        // performer to read anything.
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .strokeBorder(DAWTheme.textFaint.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(width: 26, height: 30)
    }

    // MARK: One lamp

    /// ⭐ **THE LAMP IS THE MUTE BUTTON (m34-h-2)** — *"drop the drums for the
    /// chorus"* is a live-performance gesture, and the thing you want to press
    /// is the thing that is lit. It needs no new affordance and no new colour:
    /// `.muted` is already in the light language (slate, no glow), so the press
    /// simply moves the lamp between two states it could already draw.
    ///
    /// ⚠️ **A LAMP FOR A QUEUED OR RECORDING LAYER IS STILL PRESSABLE, AND THAT
    /// IS THE STORE'S CALL TO MAKE, NOT THIS VIEW'S.** `setLoopLayerMuted`
    /// applies clip gain and refuses nothing but a missing layer; muting the
    /// layer you are overdubbing onto is a real (if unusual) thing to want, so
    /// this view does not invent a refusal the domain does not have.
    private func lampView(_ lamp: LoopDeckStatus.Lamp) -> some View {
        Button { onToggleMute(lamp.layerID, !lamp.isMuted) } label: {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(fill(for: lamp.state))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(stroke(for: lamp.state), lineWidth: borderWidth(for: lamp.state))
                    )
                    .shadow(color: glow(for: lamp.state), radius: glowRadius(for: lamp.state))
                    .frame(width: 26, height: 22)
                // ⭐⭐ **HEAD TRUNCATION, NOT TAIL — AND THIS IS THE m34-i LESSON
                // ARRIVING IN A NEW MEDIUM.** That item shipped ten numeric badges
                // of which four read "1"; here the FIRST render of this strip showed
                // two lamps both captioned "Deck…", because SwiftUI's default tail
                // truncation throws away the end of a name — which is precisely
                // where track names differ. "Deck Chords" and "Deck Bass" become
                // "…Chords" and "…Bass": distinguishable at a glance, in less
                // width. The general rule, and the reason this is not a one-off
                // patch: a performer's tracks are named by ROLE, and the role is
                // the last word.
                Text(lamp.trackName)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(width: 42)
            }
        }
        .buttonStyle(.plain)
        // ⚠️ THE EXISTING LABEL IS PRESERVED VERBATIM, AND THE `.plain` STYLE IS
        // PART OF WHY. Wrapping a lamp in a Button hands SwiftUI a chance to
        // synthesise its own label from the button's contents — here, the track
        // name alone, silently dropping the STATE that is the lamp's whole
        // purpose to a VoiceOver user. Restating it is not redundancy.
        // (Checked, so the comment does not outlive the fact: nothing in
        // `Tests/` or `scripts/gates/` asserts this string today — it is the
        // shipped VoiceOver label and nothing more.)
        .accessibilityLabel("\(lamp.trackName) loop layer, \(lamp.state.rawValue)")
        .accessibilityHint(lamp.isMuted ? "Unmute this layer" : "Mute this layer")
        .accessibilityAddTraits(lamp.isMuted ? [.isSelected] : [])
        .help(lamp.isMuted
              ? "\(lamp.trackName) — muted. Click to bring it back."
              : "\(lamp.trackName) — playing. Click to drop it out.")
    }

    // MARK: The light language
    //
    // ⭐ ONE SEMANTIC COLOUR PER MEANING, from the shipped accent system — no new
    // hues invented for this strip:
    //   • AMBER (`DAWTheme.record`) = this layer is being written to. Nothing
    //     else in the app is amber, so "amber means recording" survives.
    //   • CYAN (`DAWTheme.playback`) = sounding. The same cyan as the playhead,
    //     so the strip and the timeline agree about what "live" looks like.
    //   • SLATE = present but silent.
    // The three are distinguished by HUE first and brightness second, so they
    // survive peripheral vision, which is the only vision a performer has spare.

    private func fill(for state: LoopLayerState) -> Color {
        switch state {
        case .queued:
            // Flashing, ON THE BEAT: the state the research singles out as
            // mattering most, because a press that visibly did nothing reads as
            // ignored and invites a second press that would double-fire.
            return DAWTheme.record.opacity(onBeat ? 0.55 : 0.10)
        case .recording:
            // Solid and bright, breathing once per cycle so it is unmistakably
            // the live one even at the edge of vision.
            return DAWTheme.record.opacity(0.70 + 0.25 * (1 - phase))
        case .closing:
            // Ending on the boundary: amber still, but draining as the cycle
            // runs out, so the performer SEES the close coming.
            return DAWTheme.record.opacity(0.65 * (1 - phase) + 0.15)
        case .playing:
            return DAWTheme.playback.opacity(0.34 + 0.22 * (1 - phase))
        case .muted:
            return DAWTheme.textFaint.opacity(0.10)
        }
    }

    private func stroke(for state: LoopLayerState) -> Color {
        switch state {
        case .queued: return DAWTheme.record.opacity(onBeat ? 0.95 : 0.35)
        case .recording, .closing: return DAWTheme.record
        case .playing: return DAWTheme.playback.opacity(0.85)
        case .muted: return DAWTheme.textFaint.opacity(0.55)
        }
    }

    private func borderWidth(for state: LoopLayerState) -> CGFloat {
        switch state {
        case .recording: return 2
        case .queued, .closing: return 1.5
        default: return 1
        }
    }

    private func glow(for state: LoopLayerState) -> Color {
        switch state {
        case .recording: return DAWTheme.record.opacity(0.75)
        case .queued: return DAWTheme.record.opacity(onBeat ? 0.55 : 0)
        case .closing: return DAWTheme.record.opacity(0.4)
        case .playing: return DAWTheme.playback.opacity(0.45)
        case .muted: return .clear
        }
    }

    private func glowRadius(for state: LoopLayerState) -> CGFloat {
        switch state {
        case .recording: return 7
        case .queued, .closing: return 5
        case .playing: return 4
        case .muted: return 0
        }
    }
}
