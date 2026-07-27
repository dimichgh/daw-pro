import CoreGraphics
import DAWAppKit
import Foundation

// Staging + reporting plumbing for the m23-z MIXER strip reorder drag, the
// `TrackReorderStaging` twin one surface over: the seam stages a synthetic
// gesture through the SAME handlers a real mouse drag runs, and the console
// reports the resulting ladder + landing back UP so a bare seam call echoes
// GROUND TRUTH rather than its own input.

/// A staged step of a mixer strip drag (debug tier only; nil in normal use).
///
/// `x` is measured in the STRIP RACK's own coordinate space — the same space the
/// strips are measured in and the same one the live `DragGesture` reports in.
/// The rack scrolls horizontally, so that is what makes a staged fixture
/// SCROLL-INVARIANT; a `.local` frame would be silently right at scroll 0 and
/// wrong at every other offset.
///
/// PHASED, not one-shot, for the `TrackReorderStage` reason: a one-shot "move
/// this strip there" seam is just `track.reorder` with extra steps — it could
/// never observe that the insertion line stands where the strip will land, that
/// the order does NOT change until release, or that a visually-inert landing
/// draws no line at all.
struct MixerStripDragStage: Equatable {
    enum Action: String {
        /// Press + first movement: pick a strip up. Carries the track id (a
        /// synthesized gesture has no hit test to derive it from).
        case begin
        /// Drag: move the pointer, re-deciding the landing every step.
        case changed
        /// Release: commit the landing (one undo step) and put the strip down.
        case end
    }

    var action: Action
    /// `begin` only — which strip is picked up.
    var trackID: UUID?
    /// Pointer x in the strip rack's coordinate space.
    var x: CGFloat
    /// Bumped per request so a repeat of the same step still fires `.onChange`.
    var nonce: Int
}

/// The console's LIVE drag state, reported UP so the seam echoes what the view
/// is actually doing. Never the seam's own input: `drop` is the resolved landing
/// the console is DRAWING the line from, and `partingOffsets` are the very
/// offsets the resting strips are rendered with — so the echo cannot claim a
/// landing or a parting the user is not being shown.
struct MixerStripDragState: Equatable {
    var trackID: UUID
    /// The landing, or nil when the ladder could not resolve one (an unmeasured
    /// rack). nil is reported honestly rather than smoothed to "slot 0".
    var drop: ResolvedStripDrop?
    /// How far the picked-up strip is visually displaced from its resting slot.
    var offsetX: CGFloat
    /// Per-visual-slot parting displacement, straight out of
    /// `MixerStripReorder.partingOffsets` — the SAME array the view offsets the
    /// resting strips by. Empty when nothing is parting.
    var partingOffsets: [CGFloat]
}
