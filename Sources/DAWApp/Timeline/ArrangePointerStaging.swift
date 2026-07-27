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
        /// Over a clip: the split path (Pro; same store method). Over EMPTY lane
        /// space: the m23-e "start writing notes here" path — creates a bar-long
        /// MIDI clip and opens the editor on it (both densities).
        case doubleClick
        case clear        // end the hover (ghost off, zone → outside)
    }

    var action: Action
    var x: CGFloat
    var y: CGFloat
    /// Bumped per request so a repeat of the same point still fires `.onChange`.
    var nonce: Int
}

/// A refused arrange edit to surface in the UI (m17-c): the store's
/// LocalizedError message VERBATIM — the same string the wire returns for the
/// same call — anchored as a transient amber bubble on the thing that refused.
struct ArrangeSplitRefusal: Equatable {
    /// Where the bubble hangs. A clip edit anchors on the refused BLOCK; the
    /// m23-e empty-lane create has no clip to hang on (that is the whole point
    /// of the refusal), so it anchors on the LANE + beat it was attempted at.
    enum Anchor: Equatable {
        case clip(UUID)
        case lane(trackID: UUID, beat: Double)
    }

    var anchor: Anchor?
    var message: String
    /// Monotonic sequence so the auto-clear task never clears a NEWER refusal.
    var seq: Int

    /// The refused clip, when the anchor names one (the pre-m23-e accessor the
    /// clip blocks and the `debug.arrangePointer` echo read).
    var clipID: UUID? {
        if case .clip(let id) = anchor { return id }
        return nil
    }

    /// The lane the refusal hangs on, when it is a lane refusal.
    var laneAnchor: (trackID: UUID, beat: Double)? {
        if case .lane(let trackID, let beat) = anchor { return (trackID, beat) }
        return nil
    }
}
