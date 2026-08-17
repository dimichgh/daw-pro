import SwiftUI

/// The inline panel refusal line (m25-c-2): the store's refusal message VERBATIM,
/// beside the disabled control it explains.
///
/// **WHY THIS IS NOT A THIRD CONVENTION.** The tree already had two panel banner
/// types (`VoicePanelBanner`, `SketchpadBanner`) and one arrange idiom
/// (`ArrangeRefusalBubble`), and the Humanize/Quantize panels had no message
/// surface at all. Rather than a third banner, this is the SMALLEST thing that
/// works — one line of prose — and it deliberately wears `ArrangeRefusalBubble`'s
/// semantics so a refusal reads the same wherever it lands:
///
/// - **Amber (`DAWTheme.record`, the "record/warning" token), not red.** The
///   arrange bubble owns that colour for exactly this meaning: *the edit did not
///   happen, and nothing was destroyed*. A refused Apply is that, not an error.
/// - **The message is passed in VERBATIM and never composed here.** The words
///   belong to the store (`ProjectStore.compEditRefusal` → `errorDescription`),
///   which is the m25-a-2 rule: one obstacle, one sentence, told identically to
///   the human and to the agent that gets it back from the wire.
/// - **SF Pro, not SF Mono** — prose, and SF Mono is reserved for numeric
///   readouts (docs/DESIGN-LANGUAGE.md; the arrange bubble states the same rule).
///
/// SHARED BY TWO CALLERS on purpose (`HumanizePanel`, `QuantizePanel`): a shape
/// with one caller is not shared, it is just moved. `QuantizePanel.extractError`
/// renders a similar-looking row and is deliberately LEFT ALONE — it reports an
/// operation that RAN AND FAILED, which is a different message class from a
/// refusal decided before the press, and rewriting it is not this item's business.
struct PanelRefusalLine: View {
    /// The store's sentence, rendered as given.
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.record)
            Text(message)
                .font(.system(size: 10))
                .foregroundStyle(DAWTheme.record)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
