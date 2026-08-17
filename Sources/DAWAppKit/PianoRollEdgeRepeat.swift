import CoreGraphics
import Foundation

/// HELD-AT-EDGE AUTO-REPEAT for the piano roll's edge drag (m25-r) — the clock
/// half of `PianoRollAutoScroll`, kept pure for the same reason that one is:
/// nothing in this tree can drive a real pointer (m23-g1), so the rule has to be
/// pinned where a headless test can reach it.
///
/// ═══ WHAT THE GAP ACTUALLY WAS — MEASURE THE PREMISE FIRST ═══
///
/// m25-f-3 shipped with a stated cost: *"with the pointer held still inside the
/// band, scrolling stops, and at the window's physical edge the pointer runs out
/// of travel."* The item that became m25-r read the second clause as a REACH
/// ceiling — "a drag cannot reach content further than one screen-width of
/// pointer movement". **That reading is wrong, and the correction is the reason
/// this file is shaped the way it is.**
///
/// `PianoRollAutoScroll.nextOffset` is called once per `DragGesture.onChanged`,
/// and its step depends only on WHERE the pointer is, never on how far it moved.
/// So the scroll is metered **per event, not per unit of travel**: a pointer
/// that moves one point inside the band still buys a full `maxStep`. Reach is
/// therefore bounded by the number of events, not by the screen — a user who
/// keeps jiggling at the edge reaches the end of any clip. The real defect is
/// narrower and different in kind: **a pointer at rest produces no events, so
/// the scroll rate is exactly zero and the user has to keep the mouse moving to
/// hold it open.**
///
/// ⛔ **WHY WIDENING `edgeBand` OR RAISING `maxStep` WAS COSTED AND REJECTED.**
/// Both are multipliers on the per-event step, and in the failure mode above the
/// event count is **zero**. Zero × 2 is zero. What they do buy is the one-off
/// scroll collected while the pointer SWEEPS through the band on its way to the
/// edge, which is `maxStep × eventRate × (band / sweepSpeed) × meanDepthFraction`
/// — at 60 Hz, a 500 pt·s⁻¹ sweep and a mean depth fraction of 0.5 that is about
/// 70 pt today (~2.2 beats at the default 32 pt/beat) and about 185 pt at
/// 64/48. Against the 4096 pt a 32-bar clip draws, neither is the difference
/// between reaching the target and not. **The event rate in that arithmetic is
/// an ASSUMPTION, not a measurement — no instrument in this tree can observe
/// SwiftUI's `onChanged` delivery rate.** The conclusion does not rest on it:
/// the failure mode is a zero, and scaling a zero changes nothing.
///
/// ═══ THE QUESTION THAT HAD TO BE ANSWERED BEFORE ANY CLOCK ═══
///
/// `PianoRollAutoScroll`'s own doc refuses a timer because *"a timer firing
/// between pointer events has no such event to read and would have to FABRICATE
/// a translation — inventing the one quantity the whole gesture path takes
/// verbatim from SwiftUI"*, and a fabricated translation desyncs the dragged
/// notes from the cursor. **The refusal is answerable, and this is the answer:
/// a repeat tick does not have to invent anything, because it can RECOMPUTE.**
///
/// A held pointer's position in the CONTENT changes only because the content
/// moved, and the content moved only because the roll scrolled it — a quantity
/// the roll observes directly in `gridScrollX`. So the pointer's viewport-local
/// x is an invariant of the hold, and the content-space location is
/// `localX + observedOffset`, recomputed from scratch every tick. Nothing is
/// integrated, nothing accumulates, and tick N's error (if the observed offset
/// lags by a frame) is fully erased by tick N+1 rather than compounding.
///
/// ⭐ **AND THAT IS EXACTLY THE VALUE SwiftUI WOULD REPORT**, so the next real
/// event agrees with the synthesised ones instead of contradicting them. The
/// premise — the grid gesture resolves in the scrolling CONTENT's space — is not
/// framework lore here, it is **established by construction from shipped code**:
/// `PianoRollView.scrubDrag` runs on the non-scrolling scrub strip and must add
/// `gridScrollX` to recover a content x, while `gridDrag` feeds `value.location`
/// straight into `model.hitTest`, `model.beat(forX:)` and
/// `placementLocalBeat(atContentX:)` with no offset term anywhere. If those two
/// spaces were the same, note hit-testing would be wrong by the scroll offset at
/// every scrolled position of a surface the user works in daily.
///
/// ⚠️ **WHAT THAT ARGUMENT IS AND IS NOT.** It is reasoning over code, not a
/// measurement; no gate in this tree can feel a scroll ramp or watch a note
/// track a cursor, so the ramp's *feel* — the tick rate, whether the ramp is
/// comfortable — is settled only by a human hand. What IS measured headlessly is
/// the arithmetic: `PianoRollEdgeRepeatTests` runs the feedback loop to the wall
/// and pins the dragged note's SCREEN position invariant across the whole run.
///
/// ═══ THE PROPERTY THAT MAKES THIS SAFE TO SHIP ═══
///
/// **A tick fires only after the pointer has been still for `holdDelay`.** While
/// the pointer is moving, every tick is suppressed and the behaviour is
/// byte-identical to the shipped, human-confirmed m25-f-3 scroll. The repeat is
/// reachable ONLY from the state that had no behaviour at all before it, so this
/// cannot make a working gesture worse — and without the gate a moving pointer
/// would collect the event's step AND the clock's, i.e. the shipped scroll would
/// silently speed up.
///
/// A runaway is likewise unreachable: `nextOffset` computes an ABSOLUTE target
/// from the OBSERVED offset and returns nil when that target equals it, so the
/// loop can never request more than one `maxStep` beyond what it has actually
/// seen. If the scroll lands slower than the clock ticks, the repeat degrades to
/// the observation rate. The failure direction is "slower than asked", never
/// "faster than asked".
public enum PianoRollEdgeRepeat {

    /// How often a held pointer's repeat fires, in seconds.
    ///
    /// 60 Hz is not a round number picked for feel — it is the rate that makes
    /// the held scroll match the MOVING scroll the user just had. A moving
    /// pointer collects one `maxStep` per `onChanged`, which macOS delivers at
    /// 60 Hz or better, so ticking any faster would make letting go of the mouse
    /// SPEED THE SCROLL UP, which is the one behaviour a "keep going" affordance
    /// must not have. At `PianoRollAutoScroll.maxStep` that is 1440 pt·s⁻¹ at
    /// full depth — about one 1400 pt viewport per second — and the proportional
    /// ramp means the user still aims: ~0 at the band's inner lip, full rate
    /// only at the very edge.
    public static let interval: Duration = .milliseconds(16)

    /// The last REAL pointer event of a live content drag, in the only form a
    /// repeat can use.
    ///
    /// ⚠️ **`localX` IS THE POINT OF THIS TYPE.** Storing the pointer's content x
    /// would be storing a value that goes stale the instant the roll scrolls;
    /// storing its VIEWPORT-LOCAL x stores the thing that a hold leaves
    /// unchanged, so every tick can rebuild the content x rather than nudge it.
    /// The pair `(pointerContentX, currentOffset)` must be read from the SAME
    /// laid-out geometry — which is what `applyGesture` does, both values coming
    /// off one pass — or `localX` absorbs the discrepancy.
    public struct HeldPointer: Equatable, Sendable {
        /// The pointer's x within the visible band — invariant while held.
        public var localX: CGFloat
        /// The pointer's y in content space. There is no vertical edge scroll,
        /// so a hold never changes it, and a repeat therefore never changes
        /// pitch: `deltaPitch` is a function of `translation.height` alone.
        public var contentY: CGFloat
        /// `DragGesture.Value.startLocation` — a fixed CONTENT point, so
        /// `location - origin` reproduces SwiftUI's own `translation`.
        public var origin: CGPoint

        public init(pointerContentX: CGFloat, pointerContentY: CGFloat,
                    origin: CGPoint, currentOffset: CGFloat) {
            self.localX = pointerContentX - currentOffset
            self.contentY = pointerContentY
            self.origin = origin
        }
    }

    /// The synthesised pointer for one repeat tick — the two quantities
    /// `advanceGesture` consumes, and nothing else.
    ///
    /// ⚠️ **NO SCROLL TARGET HERE, DELIBERATELY.** The tick hands these to the
    /// SAME `advanceGesture` a real event does, and that funnel already ends in
    /// `autoScroll(towards:)`. Returning a target too would give the roll two
    /// computations of "where should the viewport go", which is precisely the
    /// second home `PianoRollAutoScroll` exists to prevent.
    public struct Tick: Equatable, Sendable {
        /// The pointer's position in CONTENT space, recomputed from the
        /// observed offset.
        public let location: CGPoint
        /// `location - origin`, i.e. SwiftUI's `DragGesture.Value.translation`
        /// for a stationary pointer over content that has scrolled.
        public let translation: CGSize
    }

    /// The tick for a pointer HELD still at `held`, or **nil when there is
    /// nothing to repeat** — the pointer is outside the edge band, or the
    /// viewport is already against the wall it is being pushed towards.
    ///
    /// - Parameters:
    ///   - held: the record captured from the last real pointer event.
    ///   - observedOffset: `gridScrollX` — where the scroller ACTUALLY sits, not
    ///     where the previous tick asked it to go. Using the observation is what
    ///     makes the note motion agree with the viewport motion even when a
    ///     scroll request lands late or is refused at the wall.
    ///   - viewportWidth: `bandViewportWidth`.
    ///   - contentWidth: `gridDrawnWidth`.
    public static func tick(
        held: HeldPointer,
        observedOffset: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> Tick? {
        let pointerContentX = held.localX + observedOffset
        // The SAME predicate the live gesture scrolls on, asked of the SAME
        // function — so a repeat can never be live where a real event would be
        // inert, and the band, the ramp and the walls are spelled once.
        guard PianoRollAutoScroll.nextOffset(
            pointerContentX: pointerContentX,
            currentOffset: observedOffset,
            viewportWidth: viewportWidth,
            contentWidth: contentWidth) != nil else { return nil }

        let location = CGPoint(x: pointerContentX, y: held.contentY)
        return Tick(location: location,
                    translation: CGSize(width: location.x - held.origin.x,
                                        height: location.y - held.origin.y))
    }

    /// How long the pointer must be still before it counts as HELD and the
    /// repeat begins — the auto-repeat "initial delay", and the rule that keeps
    /// this feature additive.
    ///
    /// ⚠️ **THE FIRST VERSION OF THIS GATE WAS A COUNTER AND IT WAS WRONG.**
    /// "Fire when no pointer event arrived since the previous tick" reads as
    /// exactly equivalent and is not: a 16 ms clock and ~16.7 ms pointer events
    /// BEAT against each other, so roughly every other tick would land in a
    /// genuinely empty window while the pointer was still moving, add its step
    /// to the real event's, and silently speed up the shipped m25-f-3 scroll a
    /// human has already confirmed. A duration cannot beat: at any delivery rate
    /// of 60 Hz or better a MOVING pointer never leaves a 200 ms gap, so every
    /// tick of a moving drag is suppressed and the shipped behaviour is
    /// untouched. The repeat is reachable ONLY from the pointer-at-rest state,
    /// which had no behaviour at all before m25-r.
    ///
    /// ⚠️⚠️ **THE COST THIS BUYS, STATED RATHER THAN DISCOVERED: A DELIBERATE
    /// PAUSE INSIDE THE BAND NOW CREEPS.** A user who drags a note to a spot
    /// that happens to lie in the 48 pt band and pauses to check its alignment
    /// gets a scroll after 200 ms, proportional to depth — near zero at the
    /// band's inner lip, full rate at the very edge. That is inherent to the
    /// feature class (every shipping DAW's edge scroll behaves this way) and the
    /// delay is the only dial that trades it against responsiveness: 200 ms is
    /// short enough to be imperceptible when the user IS pinned at the edge
    /// meaning to travel, and long enough that a glance-and-adjust pause usually
    /// escapes it. **Whether that trade is right is a FEEL question and no
    /// instrument in this tree can answer it — it needs a human hand.**
    public static let holdDelay: Duration = .milliseconds(200)

    /// True when the pointer has been still long enough to count as held.
    public static func isHeld(sinceLastPointerEvent elapsed: Duration) -> Bool {
        elapsed >= holdDelay
    }
}
