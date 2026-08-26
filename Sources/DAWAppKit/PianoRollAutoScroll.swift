import CoreGraphics
import Foundation

/// EDGE-DRAG AUTO-SCROLL for the piano roll (m25-f-3) — pure geometry, no store,
/// no SwiftUI, so the rule is testable headlessly instead of only reachable by
/// dragging a note with a real mouse (and nothing in this tree can do that:
/// m23-g1 established that an unbundled staging binary does not route real key
/// or pointer events, so a gate cannot see this gesture at all).
///
/// The user's words: *"as user moves close to the edge of the note, it should
/// expand/scroll the note area as well as auto extend clip if it reaches the
/// edge."* This namespace is the **scroll** half. The **extend** half is
/// `DAWCore.ClipAutoExtend`, reached through the store verb
/// `setClipNotes(clipID:notes:extendToCover:)`, and the two are deliberately
/// separate: one is a view-only viewport move that must leave no undo entry, the
/// other is a model edit that must land inside the drag's single `performEdit`.
///
/// ═══ THE DECISIONS THIS ENCODES ═══
///
/// **PROPORTIONAL, NOT CONSTANT.** The step grows linearly with how deep into
/// the edge band the pointer has pushed, from ~0 at the band's inner lip to
/// `maxStep` at the viewport edge. A constant step makes the surface lurch the
/// instant the pointer crosses an invisible line; a proportional one lets the
/// user *aim* — nudge for a bar, push for a page — which is the behaviour every
/// shipping DAW has and the only one that is controllable with a mouse.
///
/// **NIL MEANS "DO NOT SCROLL", AND IT IS LOAD-BEARING.** The caller turns a
/// non-nil answer into a `FollowPlayheadModel.scrollExternally(to:)` call, which
/// bumps a nonce that three separate `ScrollViewReader`s watch. Returning the
/// CURRENT offset instead of nil would fire that nonce on every pointer tick of
/// every drag — a `scrollTo` storm through the grid, the velocity lane and the
/// controller strip for gestures nowhere near an edge. So this returns nil both
/// when the pointer is outside the band and when the band is pushing against a
/// content wall the viewport already sits on.
///
/// ⚠️ **THIS IS DRIVEN BY POINTER MOTION, NOT BY A TIMER — a deliberate scope
/// line, and the reason is correctness, not laziness.** A `DragGesture`'s
/// `location`/`translation` are resolved in the gesture's own coordinate space,
/// which is the scrolling CONTENT: when the content scrolls, the next real
/// pointer event already carries the scroll in its translation, so the dragged
/// notes keep tracking the pointer with no compensation term anywhere. A timer
/// firing between pointer events has no such event to read and would have to
/// FABRICATE a translation — inventing the one quantity the whole gesture path
/// takes verbatim from SwiftUI — and would additionally owe a cancel on every
/// exit path including m18-i's `.cancelled` reseed. **Known cost, stated rather
/// than hidden: with the pointer held still inside the band, scrolling stops,
/// and at the window's physical edge the pointer runs out of travel.** The
/// user's sentence says *"as user MOVES close to the edge"*, which this
/// satisfies; a held-at-edge auto-repeat is a separate, timer-shaped item.
///
/// ⭐⭐ **THE FABRICATION OBJECTION ABOVE WAS ANSWERED AND IS RETRACTED (m25-r,
/// 2026-08-16). IT IS LEFT STANDING BECAUSE THE REASONING IS STILL CORRECT AND
/// STILL BINDING ON ANY FUTURE TIMER — but it is no longer a reason not to have
/// one.** A tick does not have to fabricate, because it can RECOMPUTE: a held
/// pointer's content position changes only because the content moved, and the
/// content moved only because this file's own `nextOffset` scrolled it, which
/// the roll observes directly. `localX + observedOffset`, rebuilt from scratch
/// every tick, integrates nothing and therefore drifts nowhere — and it is
/// exactly the value SwiftUI would report, so the next real event agrees with
/// the synthesised ones. **The cancel debt was real and was paid: three
/// teardowns, all pinned.** The policy lives in `PianoRollEdgeRepeat.swift`;
/// this file is still pointer-driven and unchanged. ⚠️ **DO NOT "SIMPLIFY" BY
/// DELETING THE PARAGRAPH ABOVE — a future timer that integrates instead of
/// recomputing reintroduces exactly the desync it names.**
public enum PianoRollAutoScroll {

    /// How wide the hot band at each viewport edge is, in points.
    ///
    /// 48 pt is a note's own scale, not an arbitrary round number: the roll's
    /// default is 32 px/beat, so the band is a beat and a half wide — big enough
    /// to enter deliberately while dragging, small enough that the middle ~90 %
    /// of a 1400 pt viewport is completely inert. It is also comfortably wider
    /// than `PianoRollMarquee.dragSlop`, so a drag can never begin already
    /// inside the band by accident of the press point.
    public static let edgeBand: CGFloat = 48

    /// The most one pointer tick may scroll, in points — reached only when the
    /// pointer is at the very edge of the viewport.
    ///
    /// 24 pt is deliberately less than `edgeBand`: a single tick can never carry
    /// the content further than the band is wide, so the pointer cannot "fall
    /// out" of the band it is steering through one large jump.
    ///
    /// ⚠️⚠️ **THAT RATIONALE DESCRIBES A WORLD THIS CODE DOES NOT LIVE IN, AND
    /// THE CONSTANT IS RIGHT FOR A DIFFERENT REASON (found m25-r, 2026-08-16).**
    /// The pointer cannot "fall out" of the band by scrolling at all: `local`
    /// reduces to the pointer's physical viewport x, which does not move when
    /// the content moves under it. The sentence presumes the pointer's
    /// band-position travels with the content — the opposite of the content-space
    /// premise this file's own header relies on. **Kept because the VALUE is
    /// sound (a 24 pt ceiling is a comfortable per-event step) and because
    /// `PianoRollAutoScrollTests` pins literals derived from it; corrected
    /// because a guard justified by a false premise is how the next reader
    /// derives a false conclusion.** The file asserted one premise in prose and
    /// guarded its negation in a constant, and nobody had established which held.
    public static let maxStep: CGFloat = 24

    /// The next horizontal content offset for a drag whose pointer is at
    /// `pointerContentX`, or **nil to leave the viewport exactly where it is**.
    ///
    /// - Parameters:
    ///   - pointerContentX: the pointer's x in the scrolling CONTENT's space —
    ///     i.e. `DragGesture.Value.location.x` as the grid canvas sees it, the
    ///     same quantity `PianoRollModel.beat(forX:)` and `hitTest` consume.
    ///   - currentOffset: the content x currently at the viewport's leading
    ///     edge (`gridScrollX`), which is `>= 0`.
    ///   - viewportWidth: the visible width of a band (`bandViewportWidth`).
    ///   - contentWidth: the full drawn width (`gridDrawnWidth`).
    /// - Returns: a new offset in `0...(contentWidth - viewportWidth)`, or nil.
    public static func nextOffset(
        pointerContentX: CGFloat,
        currentOffset: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat? {
        // A viewport that cannot show less than everything has nothing to
        // scroll. Also the degenerate-geometry guard: a zero or negative
        // viewport is what a band reports before its first layout pass, and a
        // drag can be delivered in that window.
        guard viewportWidth > 0, contentWidth > viewportWidth else { return nil }
        // The band cannot be wider than half the viewport, or the two hot zones
        // would overlap in the middle and every pointer position would be "at an
        // edge" — with the trailing test winning, so a narrow panel would scroll
        // right no matter which way the user dragged.
        let band = min(edgeBand, viewportWidth / 2)
        guard band > 0 else { return nil }

        let maxOffset = contentWidth - viewportWidth
        let offset = currentOffset.clamped(to: 0...maxOffset)
        // The pointer's position WITHIN the visible window.
        let local = pointerContentX - offset

        let delta: CGFloat
        if local < band {
            // Leading edge. Depth is measured from the band's inner lip, and is
            // allowed to exceed `band` when the pointer has been dragged past
            // the viewport entirely — capped below, so an off-window pointer
            // scrolls at full speed rather than wrapping to some other rate.
            delta = -step(depth: band - local, band: band)
        } else if local > viewportWidth - band {
            delta = step(depth: local - (viewportWidth - band), band: band)
        } else {
            return nil
        }

        let next = (offset + delta).clamped(to: 0...maxOffset)
        // Already against the wall the pointer is pushing towards: no movement,
        // so no nonce, so no `scrollTo` storm at the ends of the clip.
        return next == offset ? nil : next
    }

    /// Points to scroll for a pointer `depth` points into a `band`-wide zone.
    /// Linear from 0 at the lip to `maxStep` at the edge and beyond.
    private static func step(depth: CGFloat, band: CGFloat) -> CGFloat {
        guard band > 0 else { return 0 }
        let fraction = (depth / band).clamped(to: 0...1)
        return maxStep * fraction
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
