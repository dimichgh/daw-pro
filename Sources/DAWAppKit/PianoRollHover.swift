import CoreGraphics
import Foundation

/// What the pointer is over in the piano-roll grid — the roll's ONE hover
/// vocabulary (m25-g).
///
/// Before this the roll tracked no hover position at all: `hoverCursor(resolve:)`
/// (an `NSTrackingArea` overlay) resolved a CURSOR per point and threw the point
/// away, so nothing on this surface could DRAW at the pointer or offer an
/// affordance before the click.
public enum PianoRollHoverTarget: Equatable, Sendable {
    /// A note, with its zone already density-resolved (see `PianoRollHover.target`).
    case note(id: UUID, zone: NoteZone)
    /// The group compress/extend handle beside a multi-note selection (m25-g).
    case groupScaleHandle(PianoRollGroupScale.Edge)
    /// The transport playhead LINE, within `PianoRollPlayhead.grabTolerance` of
    /// its x, with nothing else under the pointer — press and drag to scrub
    /// (m25-o-2).
    ///
    /// ⚠️ **RETURNED ONLY WHERE THE LINE IS ACTUALLY DRAWN.** `target` takes the
    /// playhead's x as an OPTIONAL and `PianoRollPlayhead.lineX` is nil whenever
    /// the transport sits outside the edited clip, so an off-clip transport is
    /// ungrabbable at every x. You can only grab what you can see — which is the
    /// honest-absence law (`PianoRollPlayhead`'s "the LINE is never parked at an
    /// edge") reaching the pointer instead of only the pixels.
    case playhead
    /// Nothing in particular — empty grid.
    case empty
}

/// THE HOVER FACILITY for the piano-roll grid (m25-g), and it is deliberately
/// one function.
///
/// ═══════════════════ WHY ONE RESOLVER ═══════════════════
///
/// The roadmap is explicit: *"Shares the hover facility with m25-o and m25-g —
/// build ONE, not three."* Three items want the pointer's position on this
/// surface — group scale (m25-g), ⌘-click empty grid to position the playhead
/// (m25-o), drag the playhead line (m25-o-2) — and the thing that would rot if
/// each grew its own is not the `.onContinuousHover` reader (that is three
/// lines) but the PRECEDENCE between their targets. Two independent precedence
/// tables that disagree is how a surface ends up where the cursor promises one
/// thing and the press does another.
///
/// So: the view keeps ONE hover reader storing one point, and every consumer —
/// the rest cursor, the handle overlay, and the press router in `beginGesture`
/// — asks THIS function. Cursor and press cannot disagree, because they are the
/// same answer.
///
/// ⭐⭐ **THE CHORD IS AN INPUT, AND EACH CALLER SUPPLIES ITS OWN — THAT IS
/// CORRECT, NOT A SMELL (m25-x).** `target` takes an `ArrangeClickModifiers`
/// because the affordance depends on the modifier as well as the point, and the
/// two consumers legitimately know DIFFERENT truths:
///
///   - the hover path (`gridCursor`, `visibleGroupScaleEdge`) passes
///     `pointerModifiers`, built from the `.flagsChanged` monitor — the only
///     way a surface can know a modifier is down while the mouse is still;
///   - the press path (`beginGesture`) passes the GESTURE'S own chord, read at
///     the press, because that is what the press will actually be routed with.
///
/// **Do not "unify" these into one source.** Feeding the press from the hover
/// monitor would route a real click by state that is stale whenever the pointer
/// entered the surface with a modifier already down and no `.flagsChanged`
/// followed; feeding hover from the gesture is impossible, because hover has no
/// gesture. Same function, caller-supplied truth, one precedence table.
///
/// **How m25-o-2 (drag the playhead line) consumes it — BUILT, and the ranking
/// this paragraph used to predict was REVERSED BY THE USER.**
///
/// ⚠️⚠️ **THIS DOC ONCE ARGUED `.playhead` MUST BEAT `.note`.** The argument was
/// that the line crosses notes, so a grab band losing to `.note` is ungrabbable
/// wherever there is music — which is where a playhead usually is. It was
/// written speculatively, before the item was scoped, and **the user's own words
/// settle it the other way (2026-08-13): *"when a mouse hover over the playhead
/// line and there is NO OTHER ELEMENTS UNDER THE MOUSE"*.** A note is an other
/// element. So the ranking is:
///
///     .note  >  .groupScaleHandle  >  .playhead  >  .empty
///
/// — `.playhead` beats ONLY `.empty`, which is that clause expressed as
/// precedence rather than as a cursor rule. The alternative is strictly worse
/// than the bug it fixes: grabbing the line where it crosses a note makes NOTES
/// ungrabbable wherever the transport happens to sit, and the transport sits in
/// the music by definition. Editing notes is this surface's whole job; moving
/// the playhead is not.
///
/// ⭐ **THE OLD ARGUMENT'S COST IS REAL BUT BOUNDED, AND IT HAS TWO ESCAPE
/// HATCHES THAT ALREADY SHIP.** The playhead is still grabbable at ANY x, notes
/// or not, in the 18 pt scrub ruler strip frozen to the top of the grid
/// (m25-f-5); and ⌘-click places it anywhere at all, over notes included
/// (m25-o). So "ungrabbable where there is music" costs a user one pointer move
/// to the ruler, never the capability. That is why the user's ranking is
/// affordable, and it is the reason to prefer it rather than merely to accept it.
///
/// Mechanically: `ActiveDrag` gains a `.playheadDrag` case routed by the SAME
/// `beginGesture` / `advanceGesture` / `endGesture` trio m25-g uses, so the roll
/// still attaches no new gesture
/// (`EditorSurfaceOwnershipSiteTests.rollGestureCountIsPinned`).
///
/// **How m25-o (⌘-click empty grid → position the playhead) consumes it, stated
/// honestly:** the CLICK itself does not need hover at all — `beginGesture`
/// already has the press point and the chord, and the target it needs is
/// `.empty`, which this function already returns. What hover buys m25-o is the
/// PRE-click affordance the design language asks for: a crosshair cursor and/or
/// a ghost playhead line under the pointer, so the user learns the gesture
/// exists before performing it. That is a real use of the facility, but it is
/// the smaller half, and claiming m25-o "needs" hover would be an overclaim.
public enum PianoRollHover {

    /// Resolve what is under `point`.
    ///
    /// - Parameters:
    ///   - hit: `PianoRollModel.hitTest(point)`'s answer, passed in rather than
    ///     recomputed so the model stays the ONE producer of note geometry (the
    ///     `noteRects()` rule) and so a caller that already hit-tested — every
    ///     press does — does not pay twice.
    ///   - selectionFrame: `PianoRollGroupScale.frame(selectedRects:)`, or nil
    ///     when the selection is too small for a group handle.
    ///   - proDensity: the panel's density. Pro gates BOTH edge affordances.
    ///   - modifiers: the chord the pointer is carrying (m25-x). See
    ///     "THE CHORD IS AN AVAILABILITY GATE" below for what it decides and
    ///     what it deliberately does not.
    ///
    ///     ⚠️ **DELIBERATELY NOT DEFAULTED, for `playheadX`'s reason.** A
    ///     defaulted `[]` would let the view silently forget to pass it: the
    ///     handle would go back to advertising under ⌘ and every test in this
    ///     file would stay green, because they would all be exercising the
    ///     default.
    ///
    ///     ⭐ **A CHORD, NOT A `toggling: Bool`.** The suppression below is
    ///     `ArrangeClickIntent.intent(for:) == .toggle` — the SAME predicate
    ///     `PianoRollGridPress.release` and `beginGesture` derive. Taking a
    ///     pre-computed `Bool` would push that derivation out to every caller,
    ///     which is precisely the two-copies-of-a-gate defect the Pro-density
    ///     note below exists to prevent: a caller that wrote
    ///     `modifiers.contains(.command)` instead of the intent would suppress
    ///     under ⌘ and not under ⇧, and this function could not tell.
    ///   - playheadX: `PianoRollPlayhead.lineX(...)` — the drawn playhead's
    ///     content x, or nil when the transport is outside the edited clip and
    ///     no line exists to grab (m25-o-2).
    ///
    ///     ⚠️ **DELIBERATELY NOT DEFAULTED.** A defaulted `nil` would let the
    ///     view silently forget to pass it: the playhead would become
    ///     ungrabbable everywhere and every test in this file would stay green,
    ///     because they would all be exercising the default. This repo has been
    ///     bitten by that exact vacuity twice (`flagsMonitorTornDown`'s mutant
    ///     M10, and the site helper that fell back to searching a whole file).
    ///     Callers that genuinely have no playhead pass an explicit `nil`, which
    ///     also makes "no line here" readable at the call site.
    ///
    /// ⭐ **NOTES OUTRANK THE GROUP HANDLE, and that is what makes m25-g a
    /// zero-regression change.** The handle band already sits entirely outside
    /// the selection's bounding box (`PianoRollGroupScale` decision 4), so the
    /// only points this rule decides are those where some OTHER note is parked
    /// in the margin beside the selection. Giving those to the note means: every
    /// press that started a move or a resize before this item still does. The
    /// cost is that a handle can be unreachable at one edge on a dense grid;
    /// the benefit is that no shipped gesture had to be re-learned.
    ///
    /// ⚠️ **THE PRO DOWNGRADE LIVES HERE, ONCE.** `hitTest` reports a
    /// `.resizeHandle` zone at any density — it is pure geometry and knows
    /// nothing about panels — and both the cursor and the press router used to
    /// re-apply `mode == .pro` independently. Two copies of a gate is one
    /// rename away from a cursor that promises a resize Simple will not perform.
    ///
    /// ⭐⭐ **THE CHORD IS AN AVAILABILITY GATE OF THE SAME KIND (m25-x), AND
    /// IT SUPPRESSES EXACTLY ONE TARGET.** Density and chord both answer "is
    /// this affordance OFFERED here", not "what is the geometry" — so they
    /// belong in the same function for the same reason. Before m25-x this
    /// function was modifier-BLIND while `beginGesture` was not, and the gap had
    /// a visible consequence: under ⌘ the glowing group-scale bar still drew and
    /// the cursor still said "edge drag", while the press fell through to
    /// `.click(nil)` and released into `.positionPlayhead`. One verb shown,
    /// another performed.
    ///
    /// The rule, stated once so it can be checked against every case:
    /// **a target survives a chord iff the chord's verb belongs to THAT target.**
    ///
    ///   - `.note` under ⇧/⌘ — SURVIVES. The press still does a note-scoped
    ///     thing (`PianoRollGridRelease.toggle`), so the pointer is honestly
    ///     over a note.
    ///   - `.playhead` under ⌘ — SURVIVES. The press still does a
    ///     playhead-scoped thing (`.positionPlayhead`), and it advertises the
    ///     SAME `.verticalBar` cursor the drag would, so nothing disagrees.
    ///   - `.groupScaleHandle` under ⇧/⌘ — **SUPPRESSED.** This is the only
    ///     target whose verb the chord takes away outright, leaving nothing
    ///     group-scoped in its place. So it falls through to what is actually
    ///     under the pointer there: the playhead line if one is within grab
    ///     tolerance, else bare grid.
    ///
    /// ⚠️ **⇧ AND ⌘ ARE TREATED IDENTICALLY, AND THAT IS THE POINT OF KEYING ON
    /// THE INTENT.** ⇧-click on the band was inert before m25-x (the handle
    /// drew, `beginGesture` refused it, `release` returned `.doNothing`) — a
    /// promise of NOTHING rather than of a different verb, which is why it went
    /// unnoticed. It is the same lie one degree quieter, and one predicate fixes
    /// both.
    ///
    /// ⚠️ **ONE RESIDUAL MISMATCH IS KNOWN AND DELIBERATELY LEFT (m25-x):**
    /// under ⇧ WITHOUT ⌘, a pointer on the playhead line still resolves
    /// `.playhead` and still shows `.verticalBar`, but `beginGesture` refuses
    /// the drag (`!toggling`) and `release` returns `.doNothing`. Suppressing it
    /// would need `.playhead` to survive on `!toggling || contains(.command)`
    /// rather than on presence — a change to a target m25-o-2 shipped
    /// deliberately, for a cursor shape nobody has reported. Recorded rather
    /// than fixed, so the next reader finds a decision instead of an oversight.
    public static func target(
        at point: CGPoint,
        hit: (id: UUID, zone: NoteZone)?,
        selectionFrame: CGRect?,
        proDensity: Bool,
        modifiers: ArrangeClickModifiers,
        playheadX: CGFloat?
    ) -> PianoRollHoverTarget {
        if let hit {
            let zone: NoteZone = (hit.zone == .resizeHandle && proDensity) ? .resizeHandle : .body
            return .note(id: hit.id, zone: zone)
        }
        // m25-x — the chord gate. Derived from `ArrangeClickIntent`, never from a
        // second reading of the flags, so this and `PianoRollGridPress.release`
        // cannot come to disagree about what "toggling" means.
        let toggling = ArrangeClickIntent.intent(for: modifiers) == .toggle
        if !toggling, proDensity, let frame = selectionFrame,
           let edge = PianoRollGroupScale.edge(at: point, frame: frame) {
            return .groupScaleHandle(edge)
        }
        // m25-o-2 — LAST BEFORE `.empty`, and the position in this function IS
        // the user's ruling ("no other elements under the mouse"). Both branches
        // above have already returned for every element this surface has, so
        // reaching here means the pointer is over bare grid.
        if let playheadX, abs(point.x - playheadX) <= PianoRollPlayhead.grabTolerance {
            return .playhead
        }
        return .empty
    }

    /// The rest cursor for a target — nil meaning "no special cursor here"
    /// (the arrow), which is what `hoverCursor(resolve:)` expects.
    ///
    /// Kept beside `target` so the affordance a surface ADVERTISES and the
    /// gesture it PERFORMS are decided by one pair of switches over one enum.
    /// The group handle borrows `trimEdge` rather than adding a
    /// `CursorAffordance` case: it is a horizontal edge drag, which is exactly
    /// what that affordance names ("clip trim edge, note right-edge resize
    /// handle"), and `CursorModelTests` pins `allCases.count == 16` — a new case
    /// there would move a number that guards a catalog, for no new vocabulary.
    public static func cursor(for target: PianoRollHoverTarget) -> CursorKind? {
        switch target {
        case .note(_, let zone):
            return CursorAffordance.forNoteZone(zone)
        case .groupScaleHandle:
            return CursorAffordance.trimEdge.restCursor
        case .playhead:
            // m25-o-2 — the SAME cursor m25-o's ⌘ affordance shows, and reusing
            // it is the point: both gestures move the transport, and the user
            // asked for this shape in both breaths ("cursor turns into some
            // vertical sign", then "it should change to the vertical visual
            // element"). A second playhead cursor would be the third silent
            // convention `CursorKind.verticalBar`'s own doc refuses.
            return .verticalBar
        case .empty:
            return nil
        }
    }
}
