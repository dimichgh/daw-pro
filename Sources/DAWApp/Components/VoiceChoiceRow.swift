import SwiftUI
import AIServices
import DAWAppKit

/// The voice-model row and its state vocabulary — ONE treatment, shared by the
/// Voice panel's read-only VOICES list and the *Convert Voice…* panel's picker
/// (m24-m leg B).
///
/// ⭐ **WHY THIS IS A COMPONENT AND NOT A SECOND COPY.** Before this file the
/// convert sheet drew its own voice row and showed only the PIPELINE TEST tag,
/// while the panel showed READY / NEEDS PREP / INCOMPLETE — so the exact surface
/// where the state MATTERS (you are about to spend minutes converting) was the
/// one that hid it. A voice that needs preparation is the same fact in both
/// places and now says the same word in both places. Plain value inputs, so the
/// previews, the panel and the picker share one implementation.
///
/// **Ink**: the picked row is **VIOLET**-lit — a voice model is an AI parameter
/// (the ClipFix STRENGTH precedent), and cyan stays reserved for playback /
/// active transport state (Rule 3). The state chips keep their own semantic
/// colours: green = ready, amber = needs work, dim = incomplete.
enum VoiceRowInk {

    /// READY green / NEEDS PREP amber / INCOMPLETE dim — the ONE mapping from
    /// the facade's `state` string to a label and a colour.
    ///
    /// ⚠️ An unknown state reads INCOMPLETE rather than inventing a fifth face:
    /// a facade ahead of this app must degrade to "we don't know that this is
    /// usable", never to a green claim.
    static func stateFace(_ state: String) -> (label: String, color: Color) {
        switch state {
        case "ready": ("READY", DAWTheme.signal)
        case "needsConversion": ("NEEDS PREP", DAWTheme.record)
        default: ("INCOMPLETE", DAWTheme.textDim)
        }
    }
}

/// A small outlined mono tag — the house micro-badge (PIPELINE TEST, READY, …).
struct VoiceTag: View {
    var text: String
    var color: Color

    var body: some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .monospaced))
            .tracking(0.6)
            .foregroundStyle(color)
            .padding(.horizontal, 5).padding(.vertical, 2)
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(color.opacity(0.5), lineWidth: 1))
    }
}

/// The facade's voice state as a chip.
struct VoiceStateChip: View {
    var state: String

    var body: some View {
        let face = VoiceRowInk.stateFace(state)
        VoiceTag(text: face.label, color: face.color)
    }
}

/// One selectable voice in the *Convert Voice…* picker.
///
/// **The "base" honesty is stated BEFORE converting, not after** — the facade's
/// reserved smoke target carries its PIPELINE TEST tag and one plain-language
/// warning in the row itself, because a user who learns after a minutes-long run
/// that it was never a real conversion has paid for the lesson twice.
struct VoiceChoiceRow: View {
    var descriptor: VoiceDescriptor
    var isSelected: Bool
    var isEnabled: Bool
    var onSelect: () -> Void

    private var isSmokeTarget: Bool { VoicePanelModel.isSmokeTarget(descriptor) }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                        .font(.system(size: 10))
                        .foregroundStyle(isSelected ? DAWTheme.ai : DAWTheme.textDim)
                    Image(systemName: isSmokeTarget ? "waveform.path" : "person.wave.2.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(isSmokeTarget ? DAWTheme.textDim : DAWTheme.ai)
                    Text(descriptor.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DAWTheme.textPrimary)
                        .lineLimit(1)
                    if isSmokeTarget { VoiceTag(text: "PIPELINE TEST", color: DAWTheme.textDim) }
                    Spacer(minLength: 4)
                    // The SAME chip the Voice panel's list draws — one
                    // vocabulary for one fact.
                    VoiceStateChip(state: descriptor.state)
                }
                // ⚠️ ONE honesty line, not two. This row shipped drawing our
                // plain-language warning AND the facade's own note stacked
                // under it — MEASURED on staging, two near-identical sentences
                // saying the same thing, which is the near-identical-copy rule
                // broken inside a single control. The BEGINNER-READABLE line
                // wins here (Rule 6); the facade's note is still rendered
                // verbatim where it belongs — the Voice panel's list, and the
                // result strip after a conversion.
                if isSmokeTarget {
                    Text("Proves the pipeline works — the result is not a real voice conversion.")
                        .font(.system(size: 9))
                        .foregroundStyle(DAWTheme.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(isSelected ? DAWTheme.ai.opacity(0.12) : DAWTheme.panelRaised)
            .clipShape(RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(isSelected ? DAWTheme.ai.opacity(0.6) : DAWTheme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}
