import CoreGraphics
import DAWAppKit
import Foundation

// Staging + reporting plumbing for the m23-h track-header reorder drag, in the
// `ArrangeMarqueeStaging` / `ArrangePointerStaging` tradition: the seam stages a
// synthetic gesture through the SAME handlers a real mouse drag runs, and the
// list reports the resulting ladder + landing back UP so a bare seam call echoes
// GROUND TRUTH rather than its own input.

/// A staged step of a track-header drag (debug tier only; nil in normal use).
///
/// `y` is measured in the TRACK LIST's own coordinate space — the same space the
/// rows are measured in and the same one the live `DragGesture` reports in. That
/// makes a staged fixture SCROLL-INVARIANT: the space scrolls with the rows, so
/// a y computed from the echoed ladder means the same row at any scroll
/// position. (Mixing a `.local` frame with a content-space gesture is the trap
/// this avoids: silent at scroll 0, wrong everywhere else.)
///
/// PHASED, not one-shot, for the `ArrangeMarqueeStage` reason: a one-shot "move
/// this track there" seam is just the wire command with extra steps — it could
/// never observe that the drop INDICATOR stands where the track will land, or
/// that the order does NOT change until release.
struct TrackReorderStage: Equatable {
    enum Action: String {
        /// Press + first movement: pick a row up. Carries the track id (a
        /// synthesized gesture has no hit test to derive it from).
        case begin
        /// Drag: move the pointer, re-deciding the landing every step.
        case changed
        /// Release: commit the landing (one undo step) and put the row down.
        case end
    }

    var action: Action
    /// `begin` only — which row is picked up.
    var trackID: UUID?
    /// Pointer y in the track list's coordinate space.
    var y: CGFloat
    /// Bumped per request so a repeat of the same step still fires `.onChange`.
    var nonce: Int
}

/// The list's LIVE drag state, reported UP so the seam echoes what the view is
/// actually doing. Never the seam's own input: `drop` is the resolved landing
/// the list is DRAWING the indicator from, so the echo cannot claim a landing
/// the user is not being shown.
struct TrackReorderDragState: Equatable {
    var trackID: UUID
    /// The landing, or nil when the ladder could not resolve one (an unmeasured
    /// list). nil is reported honestly rather than smoothed to "index 0".
    var drop: ResolvedTrackDrop?
    /// How far the picked-up row is visually displaced from its resting slot.
    var offsetY: CGFloat
}
