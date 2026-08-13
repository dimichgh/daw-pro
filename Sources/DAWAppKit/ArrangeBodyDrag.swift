import Foundation

// Arrange body-drag CADENCE (m25-k) — the ONE place that decides WHEN a body
// drag touches the project. Headless (no SwiftUI, no AppKit) so the rule is
// unit-testable, in the `ArrangeGroupDrag` / `ArrangeMarquee` / `ArrangeSelection`
// tradition. It is the deliberate companion of `ArrangeGroupDrag`, which owns
// HOW FAR the drag translates; this owns WHEN that translation is applied.
//
// THE RULE, in one line: **a body drag PREVIEWS on every update and COMMITS
// exactly once, on release.**
//
// WHY IT EXISTS — the defect this type makes unreachable (USER-REPORTED
// 2026-08-13). `TimelineLanesView.clipDrag` used to call the real store move on
// EVERY `.onChanged` frame and commit nothing on `.onEnded`. The store move
// resolves overlap destructively (`ProjectStore.moveClips`, the m11-d/m13-b
// no-silent-overlap choke point), and that policy is about where a clip LANDS —
// so running it ~60 times a second made every INTERMEDIATE position eat whatever
// it passed over. Dragging a clip from bar 1 to bar 9 destroyed the clip sitting
// at bar 5, which the user never dropped on. The user's words: *"just mare
// mooving across over the clips removes it. It should go into effect only if I
// drag and drop it over the clip."*
//
// ⚠️ THE OVERLAP POLICY ITSELF IS CORRECT AND IS NOT CHANGED BY THIS TYPE.
// Drop-time overwrite matches Logic and Live and the user explicitly endorses it
// (*"it should clip overlaping one with the one I dropped"*). **The bug was the
// CADENCE, not the policy** — a land-time rule invoked at every intermediate
// position. So this type carries no overlap opinion at all; it only decides that
// the store hears about the drag ONCE, with the FINAL translation.
//
// WHY THE PREVIEW CANNOT WRITE: `update(rawDragDeltaBeats:)` returns Void and
// this type holds no store reference, so "preview accidentally mutates" is not a
// bug that can be reintroduced by editing a call site — it would take a new
// dependency. That is the structural half of the fix; `commit()` returning the
// payload exactly once is the behavioural half.
public struct ArrangeBodyDrag: Equatable, Sendable {
    /// What `commit()` hands to `AppModel.dragArrangeClips` — the ONE real move.
    ///
    /// Carries the drag-ORIGIN anchor start (not the anchor's current start):
    /// SwiftUI reports `translation` from the gesture's start, so the snap must
    /// be measured from the same origin or the clip creeps. That is
    /// `ArrangeGroupDrag.plan`'s `anchorOriginalStart` contract, unchanged.
    public struct Commit: Equatable, Sendable {
        public var anchorClipID: UUID
        public var anchorOriginalStart: Double
        public var rawDragDeltaBeats: Double

        public init(anchorClipID: UUID, anchorOriginalStart: Double,
                    rawDragDeltaBeats: Double) {
            self.anchorClipID = anchorClipID
            self.anchorOriginalStart = anchorOriginalStart
            self.rawDragDeltaBeats = rawDragDeltaBeats
        }
    }

    /// The clip under the pointer — the drag's anchor (`ArrangeGroupDrag`'s
    /// sense: the one clip whose absolute start snaps).
    public let anchorClipID: UUID
    /// The anchor's start when the drag BEGAN.
    public let anchorOriginalStart: Double
    /// The most recent RAW, pre-snap pointer translation in beats. This is what
    /// `commit()` will hand over — the LAST one, never an accumulation, because
    /// SwiftUI's `translation` is already measured from the gesture's start.
    public private(set) var rawDragDeltaBeats: Double
    /// True once this drag has produced its one commit (or been cancelled).
    /// A spent drag previews nothing and commits nothing.
    public private(set) var isSpent: Bool

    public init(anchorClipID: UUID, anchorOriginalStart: Double,
                rawDragDeltaBeats: Double = 0) {
        self.anchorClipID = anchorClipID
        self.anchorOriginalStart = anchorOriginalStart
        self.rawDragDeltaBeats = rawDragDeltaBeats
        self.isSpent = false
    }

    /// One pointer update. PREVIEW ONLY — returns nothing, reaches nothing.
    public mutating func update(rawDragDeltaBeats delta: Double) {
        guard !isSpent else { return }
        rawDragDeltaBeats = delta
    }

    /// The release. Returns the ONE commit payload the first time it is called
    /// and `nil` after that.
    ///
    /// IDEMPOTENT ON PURPOSE. SwiftUI can deliver a release to more than one
    /// gesture recognizer on the same view (`clipDrag` and `stretchDrag` share
    /// this drag state), and a double commit would journal the move twice —
    /// which the `clip.move` coalescing key would hide in the undo stack while
    /// the second pass re-ran overlap resolution against an already-moved clip.
    public mutating func commit() -> Commit? {
        guard !isSpent else { return nil }
        isSpent = true
        return Commit(anchorClipID: anchorClipID,
                      anchorOriginalStart: anchorOriginalStart,
                      rawDragDeltaBeats: rawDragDeltaBeats)
    }

    /// The gesture died without a release — SwiftUI cancellation, or the anchor
    /// clip vanishing under the drag (an undo, an agent's `clip.remove`). The
    /// `PianoRollView` `.cancelled` precedent (m18-i): a swallowed gesture must
    /// commit NOTHING, and the preview must not be left on screen showing an
    /// offset the store never took.
    public mutating func cancel() {
        isSpent = true
    }
}

/// What the lanes DRAW while a body drag is in flight (m25-k) — a pure render
/// offset, applied to the clips that are moving, over the positions the store
/// still holds.
///
/// THE MODEL IS NOT CONSULTED AND NOT TOUCHED. That is the point: the preview is
/// the only thing that moves until the release, so the project keeps its
/// pre-drag geometry (and therefore every clip the drag merely passes over)
/// until the user actually drops.
///
/// `deltaBeats` is the ACHIEVED translation, not the requested one — it has
/// already been through the gesture's anchor snap (`ArrangeGroupDrag.plan`) and
/// the store's whole-group beat-0 clamp (`ProjectStore.plannedGroupBeatDelta`),
/// so the ghost sits exactly where the drop will land. A preview that showed the
/// raw request would promise a landing the commit then refuses, which is the
/// honesty violation the design language forbids.
public struct ArrangeDragPreview: Equatable, Sendable {
    /// The anchor clip. Kept so a consumer can drop the whole preview once the
    /// anchor stops existing (see `AppModel.liveArrangeDragPreview`).
    public var anchorClipID: UUID
    /// Every clip translating with the gesture — the resolved arrange selection.
    public var movingClipIDs: Set<UUID>
    /// The achieved translation, in beats.
    public var deltaBeats: Double

    public init(anchorClipID: UUID, movingClipIDs: Set<UUID>, deltaBeats: Double) {
        self.anchorClipID = anchorClipID
        self.movingClipIDs = movingClipIDs
        self.deltaBeats = deltaBeats
    }

    /// The beat offset to draw `id` at. Zero for anything not in the drag.
    public func offsetBeats(for id: UUID) -> Double {
        movingClipIDs.contains(id) ? deltaBeats : 0
    }
}
