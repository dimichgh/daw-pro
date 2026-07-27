import SwiftUI

/// The arrange edit-refusal chip (m17-c, shared out at m23-e): the store's
/// refusal message VERBATIM in an amber (warning — the edit didn't happen,
/// nothing was destroyed) bubble. Prose, so SF Pro (SF Mono is reserved for
/// numeric readouts); soft amber glow at the warning intensity; transient — the
/// AppModel auto-clears the refusal that drives it.
///
/// ONE component, two anchors: a refused clip edit hangs it over the refused
/// BLOCK, and a refused empty-lane create (m23-e — MIDI on an audio/bus lane)
/// hangs it on the lane, because there is no block to hang it from. Sharing the
/// view is what keeps the two refusals reading identically; the callers own only
/// the placement.
struct ArrangeRefusalBubble: View {
    var message: String

    /// A wrap width wide enough that the verbatim message is never truncated —
    /// it must read exactly as the wire returns it. (Claimed explicitly because
    /// an overlay is proposed its host's width, which can be a sliver.)
    static let width: CGFloat = 300

    var body: some View {
        Text(message)
            .font(.system(size: 9, weight: .medium))
            .foregroundStyle(DAWTheme.record)
            .multilineTextAlignment(.leading)
            .frame(width: Self.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(DAWTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4)
                .stroke(DAWTheme.record.opacity(0.6), lineWidth: 1))
            .glow(DAWTheme.record, radius: 3, intensity: 0.3)
            .allowsHitTesting(false)
    }
}
