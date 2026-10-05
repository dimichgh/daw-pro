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
///
/// ═══ THE BODY NOW LIVES IN `EdgeAutoScroll` (I6b-S1, 2026-09-25) ═══
///
/// The pitch editor needs this rule on both axes, so the arithmetic moved to
/// `EdgeAutoScroll.nextOffset`, and this namespace FORWARDS to it. The name, the
/// signature and both constants are unchanged, so every caller and every pinned
/// literal is too. `EdgeAutoScrollTests` sweeps the forward against a frozen
/// copy of the original body and checks the bits. Everything above still binds
/// the shared file: it is the same rule.
public enum PianoRollAutoScroll {

    /// How wide the hot band at each viewport edge is, in points.
    ///
    /// 48 pt is a note's own scale, not an arbitrary round number: the roll's
    /// default is 32 px/beat, so the band is a beat and a half wide — big enough
    /// to enter deliberately while dragging, small enough that the middle ~90 %
    /// of a 1400 pt viewport is completely inert. It is also comfortably wider
    /// than `PianoRollMarquee.dragSlop`, so a drag can never begin already
    /// inside the band by accident of the press point.
    ///
    /// The value's one home is `EdgeAutoScroll.edgeBand`; this is an alias.
    public static let edgeBand: CGFloat = EdgeAutoScroll.edgeBand

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
    ///
    /// The value's one home is `EdgeAutoScroll.maxStep`; this is an alias.
    public static let maxStep: CGFloat = EdgeAutoScroll.maxStep

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
    ///
    /// A FORWARD to `EdgeAutoScroll.nextOffset`, which holds this body now
    /// (the band, the proportional ramp, both walls, the nil). The x names stay
    /// because every roll caller and `PianoRollEdgeRepeat` spell them.
    public static func nextOffset(
        pointerContentX: CGFloat,
        currentOffset: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat? {
        EdgeAutoScroll.nextOffset(pointer: pointerContentX, offset: currentOffset,
                                  viewport: viewportWidth, content: contentWidth)
    }
}
