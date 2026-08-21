import SwiftUI
import DAWCore
import DAWAppKit

/// The breath pad's HARDWARE section (m28-knob-ui): which knob on the user's
/// desk drives which dimension of the pad, what we last heard from it, and
/// whether we are listening at all.
///
/// ## ⛔⛔ THIS VIEW CANNOT WAKE CoreMIDI, STRUCTURALLY
///
/// It holds a `BreathPadHardwareModel` and nothing else — no `ProjectStore`, no
/// engine, no device enumeration. Every path that brings the MIDI client up
/// (`armMIDIControlLearn`, `availableMIDIInputs`, `listMIDIInputs`) is behind a
/// closure the app injected, and the only one reachable from here runs from the
/// LEARN button's `action:`. There is deliberately **no `onAppear`** in this
/// file: opening a panel must never connect to the user's hardware.
/// `BreathPadHardwareSiteTests` asserts that as source shape, because a comment
/// promising it is worth nothing.
///
/// ## Collapsed by default, and the collapsed row is the DIAGNOSTIC
///
/// The pad's card was already scrolling below a ~689 pt window before this
/// section existed. An always-expanded editor would push that threshold past
/// most real window sizes, so the editor lives behind a disclosure — but the
/// state that answers *"is my knob doing anything?"* does not. The header row
/// carries `summaryLine` ("2 knobs mapped · listening") whether or not the
/// section is open.
///
/// ## Colour
///
/// NO VIOLET (Rule 3). Amber for the armed learn — the one live, hardware-facing
/// state on the card. Cyan for a heard controller value, the earned-active rule:
/// the LAST HEARD readout is lit only while something has actually arrived.
struct BreathPadHardwareSection: View {
    @Bindable var hardware: BreathPadHardwareModel

    var body: some View {
        // ⚠️ ONE `state` FOR THE WHOLE BODY. `hardware.state` CONSTRUCTS a
        // `MIDIControlPanelState` — a rows array plus several composed strings —
        // on every read. The header alone read it three times, and this body
        // re-evaluates on every drag frame of the dial above it, so that was
        // three allocations per frame on a card whose whole premise is that
        // drawing does not allocate. Built once, passed down.
        let state = hardware.state
        return VStack(alignment: .leading, spacing: 8) {
            disclosureHeader(state: state)
            if hardware.isExpanded {
                ForEach(state.rows) { row in
                    MIDIMappingRow(
                        name: row.name,
                        summary: row.summary,
                        controllerLabel: row.controllerLabel,
                        deviceLabel: row.deviceLabel,
                        isLearning: row.isLearning,
                        isBound: row.isBound,
                        isInverted: row.isInverted,
                        onLearn: { hardware.toggleLearn(row.target) },
                        onInvert: { hardware.toggleInverted(row.target) },
                        onUnbind: { hardware.unbind(row.target) })
                }
                // ⚠️ ITS OWN LEAF. `lastEvent` changes on EVERY controller
                // change, mapped or not — a mod wheel during a take is a genuine
                // 30 Hz change — and this is the one readout that follows it. In
                // its own view a CC storm invalidates a `Text`, not the card
                // that owns the dial's Canvas.
                BreathPadLastHeard(state: state)
                footer(state: state)
            }
        }
    }

    /// The row that is always visible. Tapping anywhere on it toggles — a
    /// disclosure whose only hit target is a 10 pt chevron is the fiddly control
    /// docs/DESIGN-LANGUAGE.md's spacing rule exists to prevent.
    private func disclosureHeader(state: MIDIControlPanelState) -> some View {
        Button {
            hardware.isExpanded.toggle()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "dial.min")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DAWTheme.textDim)
                Text("HARDWARE KNOBS")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.4)
                    .foregroundStyle(DAWTheme.textSecondary)
                Spacer(minLength: 4)
                Text(state.summaryLine)
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(state.isLearning
                                     ? DAWTheme.record
                                     : (state.boundCount > 0
                                        ? DAWTheme.playback : DAWTheme.textFaint))
                    .lineLimit(1)
                Image(systemName: hardware.isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DAWTheme.textDim)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Drive the pad from a knob on your MIDI controller")
    }

    /// Below the rows: whether we are listening, the escape from an armed learn,
    /// and the fact that none of this is saved with the song.
    private func footer(state: MIDIControlPanelState) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .top, spacing: 6) {
                // A LISTENING dot, lit only when the subscription is real. This
                // is `MIDIControlController.isSubscribed`, which describes an
                // engine actually holding our observer — not our intent to be
                // subscribed. The two came apart once (the latch survived an
                // engine swap) and every state variable insisted the feed was
                // live while the knob was dead.
                Circle()
                    .fill(state.isSubscribed ? DAWTheme.playback : DAWTheme.textFaint)
                    .frame(width: 6, height: 6)
                    .glow(DAWTheme.playback, radius: 4, intensity: state.isSubscribed ? 0.5 : 0)
                    .padding(.top, 4)
                // ⛔⛔ RESERVED AT THE WORST CASE, LIKE `summaryReservation`.
                // `feedLine` has three variants and the longest ("Not listening
                // yet. Nothing is mapped…") wraps to TWO lines at this width
                // while the other two fit on one. Left to vary, the section's
                // height would depend on subscription state — and
                // `hardwareExpandedChrome` is ONE number measured in ONE state.
                // A budget constant sampled in a state the panel does not stay
                // in is exactly the P7 defect: budget says it fits, the card
                // draws taller, and the overhang lands on the apply button.
                Text(state.feedLine)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                    // ⚠️ `.topLeading`, NOT `.top`. A `.frame` alignment of
                    // `.top` pins the vertical axis and CENTRES the horizontal
                    // one, so the wrapped second line sat indented under the
                    // first — visible in the render, invisible to every test,
                    // because no assertion here measures x.
                    .frame(minHeight: BreathPadLayout.hardwareFeedReservation,
                           alignment: .topLeading)
            }
            Text(MIDIControlPanelState.persistenceNote)
                .font(.system(size: 9))
                .foregroundStyle(DAWTheme.textFaint)
                .fixedSize(horizontal: false, vertical: true)
            // ⛔ PRESENT EVEN WHEN INERT — two rules meet here and agree.
            //
            // (1) The destructive-action rule: the item exists whether or not it
            //     can fire, so the user learns the escape hatch is there BEFORE
            //     they need it; disabled teaches, absent teaches nothing.
            // (2) The budget: a control that appears when the first knob is
            //     mapped changes the section's height at runtime, and
            //     `hardwareExpandedChrome` is a single measured number. Reserved
            //     the same way the feed line above is.
            Button { hardware.clearAll() } label: {
                Text("FORGET ALL MAPPINGS")
                    .font(.system(size: 8.5, weight: .heavy))
                    .tracking(1)
                    .foregroundStyle(state.boundCount > 0
                                     ? DAWTheme.textDim : DAWTheme.textFaint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(DAWTheme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(state.boundCount == 0)
            .help(state.boundCount > 0
                  ? "Forget every knob mapping and stop listening to your MIDI gear"
                  : "Nothing is mapped yet")
        }
    }
}

/// The LAST HEARD readout, in its own leaf so a controller storm redraws a
/// `Text` and not the pad's Canvas (m28-knob-ui).
///
/// ⭐⭐ **THE LINE THAT MAKES A DEAD KNOB DIAGNOSABLE.** "I turn it and nothing
/// happens" has two causes that look identical from every other part of this
/// panel — the knob sends a CC we are not mapped to, or the knob sends nothing
/// at all. `MIDIControlMap.lastEvent` is read NON-DESTRUCTIVELY, so showing it
/// here never steals an event from the delivery pump.
private struct BreathPadLastHeard: View {
    var state: MIDIControlPanelState

    var body: some View {
        HStack(spacing: 8) {
            Text("LAST HEARD")
                .font(.system(size: 8.5, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(DAWTheme.textDim)
            Text(state.lastHeardLine)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(state.lastEvent == nil ? DAWTheme.textFaint : DAWTheme.playback)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panelRaised.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Last heard")
        .accessibilityValue(state.lastHeardLine)
    }
}
