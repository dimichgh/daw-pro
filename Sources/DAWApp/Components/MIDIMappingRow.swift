import SwiftUI
import DAWCore
import DAWAppKit

/// One "this hardware control drives that" row, in the glass-cockpit language
/// (m28-knob-ui).
///
/// ## Reusable on purpose, and the reason is written into `MIDIControlMap`
///
/// That type's own header says the target table is **not hard-wired to the
/// breath pad** — a target is a name plus a 0…1 contract, and adding one is a
/// case there plus a branch at the delivery site. The moment a third target
/// lands, "which knob drives what" stops being a breath-pad question and wants a
/// machine-preferences home. So this row takes **plain value inputs and
/// closures** and knows nothing about the pad: a preferences window can host the
/// same rows later without a rewrite, which is the `Components/` contract.
///
/// ## Colour
///
/// NO VIOLET (docs/DESIGN-LANGUAGE.md Rule 3 — violet is AI identity, and a
/// hardware knob is the most human thing in the app). **Amber while LEARNING**,
/// because an armed learn is a live, time-limited, hardware-facing state — the
/// next controller change anywhere on the desk will be captured — and it is the
/// one moment on this row where something is happening to the user's gear. Cyan
/// for a bound row's CC readout, the earned-active knob-arc rule. Neutral when
/// unbound: an empty row has earned no accent.
///
/// The armed row is the only thing on the card that glows without the pointer on
/// it, and that is the exception the glow recipe allows — *"never glow static
/// chrome"* is about decoration, and an armed learn is not static: it is the app
/// waiting on the user's hand.
struct MIDIMappingRow: View {
    /// The beginner-readable target name (`MIDIControlTarget.displayName`).
    var name: String
    /// One sentence on what turning the control will do
    /// (`MIDIControlTarget.summary`). Drawn only when `showsSummary`.
    var summary: String
    /// `"CC 74"`, or empty when nothing is bound.
    var controllerLabel: String
    /// `"Keystation 49"` / `"any device"` / `"device 1234"`, or empty.
    var deviceLabel: String
    /// Whether LEARN is armed for this row right now.
    var isLearning: Bool
    /// Whether a binding exists.
    var isBound: Bool
    /// Whether the bound control's sweep is flipped.
    var isInverted: Bool
    /// Whether the explanatory sentence is drawn (Pro density; the card's
    /// collapsed state never draws one).
    var showsSummary: Bool = true

    /// Arm learn, or cancel it if this row is already armed.
    var onLearn: () -> Void
    /// Flip the sweep. Ignored by the owner when nothing is bound.
    var onInvert: () -> Void
    /// Forget this mapping.
    var onUnbind: () -> Void

    private var accent: Color {
        if isLearning { return DAWTheme.record }
        return isBound ? DAWTheme.playback : DAWTheme.textFaint
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(name)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(DAWTheme.textSecondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 4)
                // The BOUND CC and the device, SF Mono — the digital-readout
                // rule. It is the row's fact, so it sits nearest the controls
                // that change it.
                // ⛔ ALL THREE BRANCHES ARE `lineLimit(1)`. The row is inside a
                // height budget measured ONCE, so a branch that could wrap would
                // make the section a different height in the armed state than in
                // the state that was measured — the P7 defect, arriving through a
                // string length rather than through arithmetic.
                if isLearning {
                    Text("TURN A KNOB")
                        .font(.system(size: 9, weight: .heavy, design: .monospaced))
                        .tracking(1.2)
                        .foregroundStyle(DAWTheme.record)
                        .lineLimit(1)
                        .glow(DAWTheme.record, radius: 5, intensity: 0.45)
                } else if isBound {
                    HStack(spacing: 5) {
                        Text(controllerLabel)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DAWTheme.playback)
                            .lineLimit(1)
                        Text(deviceLabel)
                            .font(.system(size: 9))
                            .foregroundStyle(DAWTheme.textFaint)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } else {
                    Text("NOT MAPPED")
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .tracking(1)
                        .foregroundStyle(DAWTheme.textFaint)
                        .lineLimit(1)
                }
            }
            HStack(spacing: 6) {
                chip(isLearning ? "CANCEL" : "LEARN",
                     tint: isLearning ? DAWTheme.record : DAWTheme.textSecondary,
                     filled: isLearning,
                     help: isLearning
                        ? "Stop waiting for a knob"
                        : "Press, then turn the knob you want to use. This is when DAW Pro starts listening to your MIDI gear.",
                     action: onLearn)
                chip("FLIP", tint: isInverted ? DAWTheme.playback : DAWTheme.textSecondary,
                     filled: isInverted,
                     enabled: isBound,
                     help: "Turn the knob the other way round — for a control wired backwards",
                     action: onInvert)
                chip("FORGET", tint: DAWTheme.textSecondary, filled: false, enabled: isBound,
                     help: "Forget this mapping", action: onUnbind)
                Spacer(minLength: 0)
            }
            if showsSummary {
                Text(summary)
                    .font(.system(size: 9))
                    .foregroundStyle(DAWTheme.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DAWTheme.panelRaised.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(isLearning ? DAWTheme.record.opacity(0.8) : DAWTheme.hairline,
                        lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(name)
        .accessibilityValue(isLearning
                            ? "waiting for a knob"
                            : (isBound ? "\(controllerLabel), \(deviceLabel)" : "not mapped"))
    }

    /// The house micro-button: a bordered chip, not stock AppKit chrome
    /// (docs/DESIGN-LANGUAGE.md — no utility-gray panels).
    private func chip(_ title: String, tint: Color, filled: Bool, enabled: Bool = true,
                      help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 8.5, weight: .heavy))
                .tracking(1)
                .foregroundStyle(filled ? DAWTheme.background : (enabled ? tint : DAWTheme.textFaint))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(filled ? tint : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5)
                    .stroke(filled ? Color.clear
                            : (enabled ? DAWTheme.hairline : DAWTheme.hairline.opacity(0.5)),
                            lineWidth: 1))
                .glow(tint, radius: 5, intensity: filled ? 0.4 : 0)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
    }
}
