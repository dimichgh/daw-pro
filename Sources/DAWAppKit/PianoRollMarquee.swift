import CoreGraphics
import Foundation

// Piano-roll RUBBER-BAND (marquee) selection geometry (m23-ek-1) — the ONE home
// for "a band rect over the note grid → the note ids it touches". Headless (no
// SwiftUI, no AppKit) so every branch is unit-testable, in the `ArrangeMarquee`
// / `ArrangeGroupDrag` / `ArrangeSelection` / `PianoRollPlayhead` tradition. The
// view owns the visual and the gesture; it owns no geometry math.
//
// ⭐ WHY THIS IS *NOT* A COPY OF `ArrangeMarquee` — the ladder question.
// `ArrangeMarquee` takes RESOLVED lane bands (`ArrangeMarqueeLane`) as input
// because the arrange's ladder is NON-UNIFORM: `TimelineLanesView.laneTop(index)`
// accumulates `rowHeight + extraHeight(track) + laneSpacing`, so a uniform pitch
// is wrong the moment one track above the band is expanded (`ArrangeMarquee.swift:11-22`
// states this, and `ArrangeMarqueeTests` carries a permanent validity leg that
// runs the rejected uniform mapping and asserts the two id sets DIFFER).
//
// THE ROLL'S LADDER IS AFFINE AND ALWAYS FULLY DRAWN: `PianoRollModel.y(forPitch:)`
// is `(127 - pitch) * rowHeight`, `pitch(forY:)` is its exact inverse, and
// `contentHeight` is always `128 * rowHeight` — every pitch row exists, always.
// The velocity lane and the controller strip are SIBLINGS of the note grid in
// the editor's outer `VStack`, each with its own coordinate space and its own
// horizontal scroller, so they perturb nothing here. Mirroring the arrange's
// shape would therefore mean building 128 rows of ceremony to encode a fact the
// model states in one line — and, worse, standing up a SECOND producer of a
// mapping that currently has exactly one.
//
// ⚠️⚠️ THE REAL TRAP IS *WHICH RECT*, NOT WHICH LADDER. There are three
// candidate rectangles per note and picking the wrong one ships a band that
// disagrees with a CLICK:
//   1. `PianoRollModel.noteRect(…)` — applies `max(3, lengthBeats * ppb)`, a
//      minimum HIT width so a very short note stays clickable. This is what
//      `PianoRollModel.hitTest(_:)` uses.
//   2. the DRAWN pill — (1) then `.insetBy(dx: 0.5, dy: 1.5)`, strictly smaller.
//   3. a freshly re-derived `startBeat * ppb … endBeat * ppb` rect — what a
//      careless implementation writes.
// At the default 32 px/beat a 1/64 note (0.0625 beats) is 2 px wide and floored
// to 3; under (3) the band's rect is 2 px while the click's is 3, so there is a
// 1 px column where clicking selects the note and sweeping does not. Under (2)
// the disagreement is 1 px of inset on EVERY note.
//
// SO THIS TYPE CONTAINS NO BEAT MATH AND NO PITCH MATH AT ALL. `hits` takes
// ALREADY-BUILT rects (`PianoRollModel.noteRects()`, which forwards to the same
// `noteRect` static `rect(for:)` and the Canvas both use). There is nothing here
// that COULD drift from the click. `PianoRollMarqueeTests` pins the agreement
// against `hitTest` directly, plus a validity leg proving the DRAWN rect gives a
// different answer — i.e. that the test can tell the two apart.
//
// CARRIED OVER FROM `ArrangeMarquee`, deliberately and by reference:
//  • TOUCH, NOT CONTAINMENT (`ArrangeMarquee.swift:24-26`) — a note is selected
//    when the band OVERLAPS it. Requiring containment would make a band unable
//    to grab a note longer than the viewport.
//  • STRICT overlap, so a DEGENERATE band selects nothing (`:28-33`). A press
//    that never swept AREA cannot silently replace the user's selection with a
//    lucky hit.
//
// NOT CARRIED OVER: `ArrangeMarquee.hits`'s `where clip.lengthBeats > 0` filter
// (`:119`). It has no referent here — `MIDINote.minLengthBeats` is 0.001 and the
// `max(3, …)` floor means no note can have zero extent. Copying it blind would
// ship a guard for a state that cannot exist, which is how dead rules
// accumulate.
public enum PianoRollMarquee {

    /// Pointer travel (points) that promotes a click into a band.
    ///
    /// The same 4 pt as `ArrangeMarquee.dragSlop`, and cross-referenced rather
    /// than shared: these are PER-SURFACE constants that happen to agree today,
    /// exactly as `ArrangeMarquee.dragSlop` records about the ruler's
    /// `loopClickSlop`. Two homes for one number is the honest shape when the
    /// two surfaces could legitimately diverge; one home would make a future
    /// tuning of the arrange silently retune the roll.
    ///
    /// ⚠️ RADIAL, not per-axis, and NOT the same decision as
    /// `moveCommitSlop` below.
    public static let dragSlop: CGFloat = 4

    /// The travel (points, PER AXIS) at which an in-flight note move/resize
    /// counts as an EDIT rather than a click — `PianoRollView`'s `didMove`
    /// threshold, hoisted verbatim so this surface has ONE home for pointer
    /// travel thresholds and the difference between the two is legible.
    ///
    /// ⚠️ NOT MERGEABLE WITH `dragSlop`, and the values agreeing to within 1 pt
    /// is not an argument that they should be. `didMove` answers "was this an
    /// edit or a click?" and decides whether `commit()` runs; `dragSlop` answers
    /// "was this a click or a band?". Changing this one would alter shipped
    /// note-drag commit behaviour.
    public static let moveCommitSlop: CGFloat = 3

    /// The band two content-space points describe — NORMALIZED, so a drag
    /// right-to-left and/or bottom-to-top produces the same rect as the
    /// equivalent left-to-right, top-to-bottom one.
    ///
    /// A verbatim twin of `ArrangeMarquee.band(from:to:)` (`:92-95`), for the
    /// `dragSlop` reason above. `CGRect.standardized` is not enough on its own:
    /// `CGRect(x:y:width:height:)` with a negative width is legal but not
    /// standardized, and every consumer would then have to remember to
    /// standardize it. Producing the normalized rect HERE means a negative
    /// extent cannot exist downstream.
    public static func band(from origin: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
               width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    /// Every note the band TOUCHES.
    ///
    /// - `band`: normalized content-space rect (see `band(from:to:)`).
    /// - `rects`: the notes' HIT rects, built by `PianoRollModel.noteRects()` —
    ///   i.e. by the same producer `hitTest` consumes. Never rebuilt here.
    ///
    /// Empty for a degenerate band (zero width or zero height): the strict
    /// comparisons below would already return the empty set, and the guard
    /// states the rule where a reader looks for it. `CGRect.intersects` gives
    /// the same answer for these inputs (both rects always have positive
    /// extent), and is deliberately not used: an explicit test is what makes
    /// "touching edges do NOT count" reviewable rather than inherited.
    public static func hits(band: CGRect, rects: [(id: UUID, rect: CGRect)]) -> Set<UUID> {
        guard band.width > 0, band.height > 0 else { return [] }
        var out: Set<UUID> = []
        for entry in rects
        where band.minX < entry.rect.maxX && entry.rect.minX < band.maxX
            && band.minY < entry.rect.maxY && entry.rect.minY < band.maxY {
            out.insert(entry.id)
        }
        return out
    }
}

/// A staged marquee gesture step for the note grid (debug tier only; nil in
/// normal use). Coordinates are the note grid's CONTENT-space points — x =
/// beats · `pixelsPerBeat`, y = `(127 - pitch) · rowHeight` — so a probe stays
/// exact at any zoom and any row height. Both scales are echoed by
/// `debug.pianoRollMarquee`, and a fixture MUST derive its coordinates from that
/// echo: `pixelsPerBeat` is driven by the persisted, user-zoomable
/// `PanelLayoutStore.pianoRollPPB`, so a fixture hardcoding 32 (or 14) passes at
/// defaults and silently tests nothing at any other zoom.
///
/// PHASED, not one-shot, for `ArrangeMarqueeStage`'s reason verbatim: a one-shot
/// "select this rect" seam structurally cannot observe the claim "the band is
/// VISIBLE during the drag" — it would have begun and ended inside one call with
/// nothing standing to look at.
///
/// ⚠️ LIVES IN DAWAppKit, NOT beside its `debug.*` handler in DAWApp, and that
/// is forced rather than chosen: `PianoRollNoteSelectionBridge` (this module)
/// holds the staged step, and DAWAppKit cannot import DAWApp. The m23-ek design
/// doc places this struct in `Sources/DAWApp/PianoRoll/PianoRollMarqueeStaging.swift`
/// alongside the handler; that placement does not compile, and the file it names
/// carries the `extension AppModel` handler only.
public struct PianoRollMarqueeStage: Equatable, Sendable {
    public enum Action: String, Sendable {
        /// Press. Runs the roll's OWN press handler — so a press on empty grid
        /// becomes `.click(nil)` (the state a band can be promoted out of) and a
        /// press on a note becomes a move/click exactly as the mouse would.
        /// NO band is armed here.
        ///
        /// ⚠️ A staged `begin` therefore CANNOT exercise the promotion
        /// threshold: it carries explicit coordinates and arms nothing.
        /// Promotion is reachable only through `changed` — see `Action.changed`.
        case begin
        /// Drag. The first `changed` past `PianoRollMarquee.dragSlop` from the
        /// press point is what PROMOTES the press into a band; each later one
        /// re-decides the whole selection from the frozen base (grow adds,
        /// shrink gives back). A `changed` WITHIN the slop leaves the press a
        /// click and draws no band — which is the only honest way to test the
        /// threshold through this seam.
        case changed
        /// Release. Runs the roll's own end handler: a promoted gesture applies
        /// its final band and puts it away; an unpromoted one resolves as the
        /// CLICK it still is (empty grid + `.replace` ⇒ the selection clears,
        /// exactly as it does today).
        case end
    }

    public var action: Action
    public var x: CGFloat
    public var y: CGFloat
    /// The chord, passed EXPLICITLY because a synthesized gesture carries no
    /// real `NSEvent.modifierFlags` (`ArrangeClickModifiersBridge.current`'s own
    /// note). Routed through `ArrangeClickIntent.intent(for:)` on the far side,
    /// so the seam cannot grow a second chord table.
    ///
    /// ⚠️ CARRIED ON EVERY STEP of a chorded gesture, unlike
    /// `ArrangeMarqueeStage.additive` which is a `begin`-only field. The band
    /// here is a PROMOTION, so the additive decision is taken on the first
    /// `changed` past the slop, and the click/toggle decision on `end` — the two
    /// instants at which a live gesture reads the real modifier flags. A chord
    /// supplied only at `begin` describes a user who let the key go before
    /// dragging, and the seam answers accordingly (MEASURED, m23-ek-1 gate).
    public var shift: Bool
    public var command: Bool
    /// Bumped per request so a repeat of the same step still fires `.onChange`.
    public var nonce: Int

    public init(action: Action, x: CGFloat, y: CGFloat,
                shift: Bool = false, command: Bool = false, nonce: Int) {
        self.action = action
        self.x = x
        self.y = y
        self.shift = shift
        self.command = command
        self.nonce = nonce
    }
}

/// Everything the note grid's surface looks like RIGHT NOW, reported up so the
/// marquee seam can echo it (m23-ek-1) — the `ArrangeLaneGeometry` sibling.
///
/// WHY IT IS REPORTED AND NOT COMPUTED APP-SIDE: `PianoRollModel` is `@State
/// private` inside `PianoRollView`, so nothing outside can read the draft, the
/// selection or the live scales at all. An AppModel that recomputed them would
/// be a SECOND producer, free to agree with the view by luck.
public struct PianoRollSurfaceState: Equatable, Sendable {
    /// One semitone row's height — the vertical scale a fixture must derive y
    /// from.
    public var rowHeight: CGFloat
    /// The LIVE horizontal scale (`PanelLayoutStore.pianoRollPPB`, user-zoomable).
    public var pixelsPerBeat: CGFloat
    public var clipLengthBeats: Double
    public var noteCount: Int
    /// The model's own selection — `base ∪ hits` under an additive chord, which
    /// is why it is reported beside `hits` rather than derived from it.
    public var selection: Set<UUID>

    public static let empty = PianoRollSurfaceState(
        rowHeight: 0, pixelsPerBeat: 0, clipLengthBeats: 0, noteCount: 0, selection: [])

    public init(rowHeight: CGFloat, pixelsPerBeat: CGFloat, clipLengthBeats: Double,
                noteCount: Int, selection: Set<UUID>) {
        self.rowHeight = rowHeight
        self.pixelsPerBeat = pixelsPerBeat
        self.clipLengthBeats = clipLengthBeats
        self.noteCount = noteCount
        self.selection = selection
    }
}
