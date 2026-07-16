import CoreGraphics
import Foundation

// Staging + refusal plumbing for the m17-c pointer affordances. Hover states are
// not reachable through real pointer injection on the unbundled staging binary
// (no Accessibility grant — the m17-b AppleEvent −1712 measurement), so the
// `debug.arrangePointer` seam stages a synthetic pointer event through the SAME
// view handlers a real hover/click runs (the `stageRenameMarkerID` mirror
// precedent), and the view reports the resulting zone/ghost state back up so a
// bare seam call can echo ground truth.

/// A staged pointer event for the arrange lanes (debug tier only; nil in normal
/// use). Coordinates are CONTENT-space points (x = beats · pixelsPerBeat), so a
/// probe stays exact at any zoom without knowing the scroll offset.
struct ArrangePointerStage: Equatable {
    enum Action: String {
        case hover        // classify + show/hide the ghost line
        case click        // the empty-lane click-seek path
        case doubleClick  // the double-click split path (Pro; same store method)
        case clear        // end the hover (ghost off, zone → outside)
    }

    var action: Action
    var x: CGFloat
    var y: CGFloat
    /// Bumped per request so a repeat of the same point still fires `.onChange`.
    var nonce: Int
}

/// A clip-edit refusal to surface in the arrange UI (m17-c): the store's
/// LocalizedError message VERBATIM — the same string the wire returns for the
/// same call — anchored on the refused clip as a transient amber bubble.
struct ArrangeSplitRefusal: Equatable {
    /// The clip whose block shows the bubble (nil if it could not be resolved).
    var clipID: UUID?
    var message: String
    /// Monotonic sequence so the auto-clear task never clears a NEWER refusal.
    var seq: Int
}
