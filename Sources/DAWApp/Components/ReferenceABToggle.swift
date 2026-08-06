import SwiftUI
import DAWAppKit

/// The shared **MIX | REF** A/B chip pair (m22-g P3, design §7.1/§7.2 point 4).
///
/// ONE component, rendered in exactly two places — the master strip's REFERENCE
/// row and the REFERENCE panel's A/B cluster — because two copies would drift
/// (the `SimpleProToggle` shared-chip rule). Both instances also carry the ONE
/// shared `.explainable(.referenceABToggle)` id; per-instance frame anchoring
/// lands the card on whichever copy the pointer is over.
///
/// Colors (DESIGN-LANGUAGE Rule 3): the lit half is **cyan** — an earned ACTIVE
/// state — and NEVER violet. A reference is a record the user chose, not
/// AI-generated content; violet here would lie about what the audio is. The REF
/// half additionally wears the glow recipe while monitoring, because "am I
/// hearing my mix or the record?" is the single most important thing this
/// surface has to answer at a glance.
///
/// Plain value inputs (`isMonitoring` + a closure), so previews and both call
/// sites share it and neither reaches into a store.
struct ReferenceABToggle: View {
    /// True while the reference is being auditioned (the REF half is lit).
    var isMonitoring: Bool
    /// The chip's height — 18 pt in the master strip's tight 25 pt row, 22 pt
    /// in the panel where the cluster is the primary control.
    var height: CGFloat = 18
    /// Called with the requested monitor state (the same value the wire's
    /// `reference.setMonitor {on}` carries).
    var onSet: (Bool) -> Void

    var body: some View {
        HStack(spacing: 0) {
            half(title: "MIX", isOn: !isMonitoring, wantsMonitor: false)
            half(title: "REF", isOn: isMonitoring, wantsMonitor: true)
        }
        // The chip pins its OWN width — one size, everywhere. Historically (the
        // m22-g P3 regression) the master strip's HStack proposal split let the
        // row squeeze the chip whenever the neighbouring match-gain readout grew
        // a glyph (a plain `-5.8 dB` read `MIX | REF`, a `+11.4 dB` collapsed it
        // to `M… | R…`), and a truncated label on the app's primary A/B control
        // is unreadable. Pinned at the OUTER stack, not the inner `Text`: the
        // halves' 8 pt padding and background would still compress under a
        // narrow proposal even with the text itself fixed. In the panel this is
        // a no-op — that cluster already gets its ideal width.
        //
        // ⚠️ **THAT SQUEEZE DOES NOT HAPPEN AT TODAY'S WIDTHS** (m23-dt). The
        // sentence above is history, not a live counterfactual: the master row
        // now has ≈14 pt of slack (chip 69 + 6 spacing + widest readout 43,
        // inside 132), so the `Spacer(minLength: 0)` absorbs the residual and
        // removing this pin ALONE moves zero pixels. Measured at m23-be with the
        // row proven rasterized (`m22g` E0b/E2b), not inferred.
        //
        // ⭐ It is still the pin that matters MOST, and the one to restore first
        // if this row is ever re-laid-out: widen the readout past the slack and
        // drop THIS pin, and the chip fans out to one width per glyph
        // (`75d6f3f5` / `d576b9ab`×2 / `91c6c22b` / `1216db16`); put it back with
        // the readout still outgrown and the chip returns to a single width.
        // `MixerStripView`'s readout pin is the junior partner. The leg that
        // notices is `m22g-reference-panel.mjs` **E2c**.
        .fixedSize(horizontal: true, vertical: false)
        .background(DAWTheme.panelRaised)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(DAWTheme.hairline, lineWidth: 1))
        .help(isMonitoring
              ? "Hearing the REFERENCE, level-matched to your mix. Press MIX to come back."
              : "Hearing your MIX. Press REF to hear the reference at the same loudness.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Mix or reference")
        .accessibilityValue(isMonitoring ? "reference" : "mix")
        .accessibilityAddTraits(.isButton)
    }

    private func half(title: String, isOn: Bool, wantsMonitor: Bool) -> some View {
        Button { onSet(wantsMonitor) } label: {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(0.6)
                .lineLimit(1)
                .foregroundStyle(isOn ? DAWTheme.playback : DAWTheme.textDim)
                .frame(height: height)
                .padding(.horizontal, 8)
                .background(isOn ? DAWTheme.playback.opacity(0.18) : Color.clear)
                // Glow is EARNED: only the lit REF half blooms, because that is
                // the state a user must never mistake. The lit MIX half is the
                // resting default and stays quiet (never glow static chrome).
                .glow(DAWTheme.playback, radius: 5,
                      intensity: (isOn && wantsMonitor) ? 0.45 : 0)
        }
        .buttonStyle(.plain)
    }
}
