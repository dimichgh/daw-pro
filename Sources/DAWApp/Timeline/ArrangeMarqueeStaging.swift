import CoreGraphics
import Foundation

// Staging + reporting plumbing for the m23-g3 rubber band, in the
// `ArrangePointerStaging` / `ArrangeDropStage` tradition: the seam stages a
// synthetic gesture through the SAME view handlers a real mouse drag runs, and
// the view reports the resulting band + selection back UP so a bare seam call
// echoes GROUND TRUTH rather than its own input.

/// A staged marquee gesture step for the arrange lanes (debug tier only; nil in
/// normal use). Coordinates are CONTENT-space points (x = beats ·
/// pixelsPerBeat, y measured against the SAME `laneTop` ladder the lanes lay
/// out with), so a probe stays exact at any zoom and any row height.
///
/// PHASED, not one-shot, and that is load-bearing: a one-shot "select this
/// rect" seam structurally cannot observe the claim "the band is VISIBLE during
/// the drag" — it would have begun and ended inside one call, with nothing
/// standing to look at. Begin/changed/end is also the only shape that can
/// exercise a growing-and-shrinking band re-deciding the selection on every
/// update, which is how the real gesture behaves.
struct ArrangeMarqueeStage: Equatable {
    enum Action: String {
        /// Press: capture the band ORIGIN and the pre-drag selection (the base
        /// a shift-marquee unions onto), and apply the (degenerate) band.
        case begin
        /// Drag: move the band's free corner and re-decide the selection.
        case changed
        /// Release: apply the final band, then clear it.
        case end
    }

    var action: Action
    var x: CGFloat
    var y: CGFloat
    /// `begin` only: the additive chord (shift/⌘). A synthesized gesture carries
    /// no real `NSEvent.modifierFlags`, so the seam passes the chord EXPLICITLY —
    /// the `debug.arrangeSelection {shift, command}` convention.
    var additive: Bool
    /// Bumped per request so a repeat of the same step still fires `.onChange`.
    var nonce: Int
}

/// The lanes' RESOLVED vertical ladder, reported up so the marquee seam can
/// echo it (m23-g3).
///
/// WHY THIS IS REPORTED AND NOT COMPUTED APP-SIDE: `laneTop` accumulates
/// `rowHeight + extraHeight(track) + laneSpacing` per row, so the ladder is
/// NON-UNIFORM the moment a track's automation row or takes section is open,
/// and `rowHeight` is user-adjustable (beta m10-d). A caller that hardcoded
/// 34 + 6 would compute a fixture the app never renders — and an AppModel that
/// recomputed the ladder would be a SECOND producer of it, free to agree with
/// the view by luck. The view is the one producer; this carries its answer out.
struct ArrangeLaneGeometry: Equatable {
    /// Content-space top y of each track's CLIP band, in track order.
    var laneTops: [CGFloat]
    /// The live clip-lane height — `laneTops[i] ..< laneTops[i] + rowHeight` is
    /// track i's clip band, which is exactly what the marquee intersects.
    var rowHeight: CGFloat

    static let empty = ArrangeLaneGeometry(laneTops: [], rowHeight: 0)
}
