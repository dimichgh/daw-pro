import Foundation
import DAWCore

// Arrange GROUP DRAG geometry (m23-g2) — the ONE producer of the rigid delta a
// multi-clip body drag translates by. Headless (no SwiftUI, no AppKit) so the
// rule is unit-testable, in the `ArrangeDropSnap` / `ArrangeSelection` /
// `MixerStripLayout` / `KnobGeometry` / `PianoRollPlayhead` tradition.
//
// THE RULE, in one line: **snapping is a property of the GESTURE, not of each
// clip.** The clip under the pointer is the ANCHOR; its ABSOLUTE start snaps
// ONCE; the delta that produced it is applied RIGIDLY to every selected clip.
//
// WHY THAT MATTERS — the defect this type exists to make unreachable. The
// pre-g2 arrange applied `ClipEdit.movedStartBeat` to the ONE dragged clip,
// which is correct for one clip and silently wrong for a group: it snaps each
// clip's own absolute start, so two clips at different SUB-GRID PHASES are
// WELDED TOGETHER by the drag. Clips at beats 0 and 2.5 under `.bar` snap both
// land on 4; the 2.5-beat gap the user arranged is gone, and nothing warns
// them. Snapping once, on the anchor, is what makes the translation rigid.
//
// WHERE THE WHOLE-GROUP CLAMP IS NOT: this type does NOT compute the
// whole-group beat-0 clamp, and that omission is deliberate.
// `ProjectStore.moveClips(ids:byBeats:)` owns it because it is the only place
// that can see every selected clip's start. If the gesture layer computed it
// too, the app would hold TWO independent computations of the same quantity
// that could agree BY LUCK — the m23-f finding, where a mutation restoring a
// duplicate computation left one gate row passing while three failed. So there
// is exactly one producer of positions (the store) and exactly one producer of
// the requested delta (this type).
//
// WHAT THIS TYPE *DOES* FLOOR, stated precisely because an earlier version of
// this comment claimed it floored nothing and that was FALSE (found in review,
// m23-g2 round 2): `ClipEdit.movedStartBeat` — the shared single-clip anchor
// snap — floors the ANCHOR at `max(0, …)` before snapping. So a drag whose
// anchor is asked below beat 0 has ALREADY had that reduction absorbed here,
// and the store, receiving a delta that needs no clamping, correctly reports
// `clamped: false`. Two DIFFERENT quantities, not one computed twice: the
// group clamp is `max(delta, -minStartAmongSelection)` over the whole
// selection; this is a floor on the ANCHOR alone. `Plan.flooredAtZero` exists
// so the caller can tell that the reduction happened HERE — without it the
// honest question "was this drag reduced?" gets opposite answers for the same
// geometry depending on WHICH clip the pointer grabbed.
public enum ArrangeGroupDrag {
    /// What a body drag is asking for.
    public struct Plan: Equatable, Sendable {
        /// Where the ANCHOR clip's start wants to land — snapped ONCE, floored
        /// at 0. This is the gesture's whole snapping decision.
        public var snappedAnchorStart: Double
        /// The rigid translation to hand to `ProjectStore.moveClips`. Measured
        /// against the anchor's CURRENT start, not its drag-origin start, so a
        /// live drag (which emits many updates and applies each one) asks only
        /// for the part it has not already applied.
        ///
        /// NOT unconditionally unclamped — see `flooredAtZero`. The store still
        /// owns the WHOLE-GROUP clamp and reports what it did, but when the
        /// anchor itself was asked below beat 0 the reduction already happened
        /// here and the store never sees it.
        public var deltaBeats: Double
        /// True when the ANCHOR's requested landing was below beat 0 and
        /// `ClipEdit.movedStartBeat`'s floor pulled it up — i.e. this gesture
        /// asked for more travel than `deltaBeats` carries.
        ///
        /// This is the floor ONLY. It is deliberately NOT "the landing moved
        /// down", because a snap can also move a landing down and that is not a
        /// clamp: anchor 6, raw -5, `.bar` gives `max(0, 1)` = 1, which SNAPS to
        /// 0. Nothing was clamped there — the grid did it — and broadening this
        /// predicate to catch that case would make every downward snap report as
        /// a clamp. `ArrangeGroupDragTests` pins both halves.
        public var flooredAtZero: Bool

        public init(snappedAnchorStart: Double, deltaBeats: Double, flooredAtZero: Bool) {
            self.snappedAnchorStart = snappedAnchorStart
            self.deltaBeats = deltaBeats
            self.flooredAtZero = flooredAtZero
        }
    }

    /// Plans one update of a body drag.
    ///
    /// - `anchorOriginalStart`: the anchor clip's start when the drag BEGAN
    ///   (SwiftUI reports `translation` from the gesture's start, so the snap
    ///   must be measured from the same origin or the clip creeps).
    /// - `anchorCurrentStart`: the anchor's start RIGHT NOW, read from the
    ///   STORE. Reading it from the view's render-time clip value instead would
    ///   go stale between a mutation and the next SwiftUI pass, and the drag
    ///   would over-shoot by whatever it had already applied.
    /// - `rawDragDeltaBeats`: the pointer translation in beats, PRE-SNAP.
    ///
    /// SELF-CORRECTING BY CONSTRUCTION: because the group translates rigidly,
    /// `anchorCurrentStart - anchorOriginalStart` is exactly the total already
    /// applied to EVERY member. So a drag that was clamped at the wall and then
    /// pulled back out lands where an unclamped drag would have — the clamp is
    /// re-derived from live positions on every update instead of being
    /// remembered.
    public static func plan(
        anchorOriginalStart: Double, anchorCurrentStart: Double,
        rawDragDeltaBeats: Double, snap: ClipSnap, meterMap: MeterMap
    ) -> Plan {
        // ONE call to the ONE anchor-snap home. `ClipEdit.movedStartBeat` is
        // also what a single-clip drag has always used, so the anchor's own
        // landing is byte-identical to its pre-g2 behaviour.
        let snapped = ClipEdit.movedStartBeat(
            originalStart: anchorOriginalStart, dragDeltaBeats: rawDragDeltaBeats,
            snap: snap, meterMap: meterMap)
        // A RESTATEMENT of `movedStartBeat`'s own `max(0, originalStart +
        // dragDeltaBeats)` — the floor is applied BEFORE the snap, so this is
        // the identical predicate, not a second guess at it.
        let floored = (anchorOriginalStart + rawDragDeltaBeats) < 0
        return Plan(snappedAnchorStart: snapped, deltaBeats: snapped - anchorCurrentStart,
                    flooredAtZero: floored)
    }
}
