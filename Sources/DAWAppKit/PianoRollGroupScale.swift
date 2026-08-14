import CoreGraphics
import Foundation

/// GROUP COMPRESS / EXTEND for the piano roll (m25-g) — pure geometry and pure
/// arithmetic, no store, no SwiftUI, so the rule is testable headlessly instead
/// of only reachable by hovering and dragging with a real mouse (m23-g1: an
/// unbundled staging binary does not route real pointer events, so no `.mjs`
/// gate can see this gesture at all — the same reason `PianoRollAutoScroll` was
/// extracted).
///
/// The user's words: *"select several notes, hover near the selection's edge,
/// get a handle, drag it to scale the group's timing (compress or stretch), like
/// the ends of a region."*
///
/// ═══════════════════ THE DECISIONS THIS ENCODES ═══════════════════
///
/// ⭐ **1. IT SCALES BOTH ONSETS AND LENGTHS — a true time-stretch, not a
/// rhythm-only squeeze.** *"Like the ends of a region"* is the deciding phrase:
/// dragging a region's edge scales its whole musical content, and a region whose
/// events kept their absolute durations while their onsets closed up would not
/// read as a shorter region — it would read as a broken one. Concretely, scaling
/// onsets ALONE at factor 0.5 turns a legato line into a pile of overlapping
/// same-pitch notes (each note now outlasts the next one's onset) and at factor
/// 2 turns it into staccato with silent gaps. Scaling both preserves the
/// ARTICULATION RATIO — legato stays legato, staccato stays staccato — which is
/// what a musician means by "compress this passage".
///
/// **What onsets-only would have bought, stated rather than dismissed:** it
/// keeps absolute durations, which is the right verb for "tighten the timing of
/// a drum pattern without changing the sample decay". That is a genuinely
/// different operation and belongs behind a modifier or a second verb, not
/// behind the same handle.
///
/// ⭐ **2. THE ANCHOR IS THE FAR EDGE FROM THE HANDLE.** Dragging the trailing
/// handle keeps the selection's earliest onset fixed; dragging the leading
/// handle keeps its latest end fixed. That is exactly what region resize does,
/// and it is the only choice under which the handle the user is holding is the
/// only thing that appears to move. Anchoring both edges on "selection start"
/// would make the leading handle drag the whole selection sideways as it scaled,
/// which reads as a bug.
///
/// ⭐ **3. ONE CLAMP FOR THE WHOLE GROUP, COMPUTED ONCE — the m23-ek-2 law
/// (`PianoRollModel.moveSelection`), and a scale needs it MORE than a move
/// does.** *Snapping and clamping are properties of the GESTURE, not of each
/// note.* A move that snaps per note welds notes at different sub-grid phases
/// together (a swung pair lands straight); a SCALE that snapped per note would
/// do the same thing while also multiplying the error, because every onset is
/// being multiplied rather than translated. So exactly one number snaps here —
/// the DRAGGED EDGE — and everything else is derived from the resulting factor.
/// This type therefore takes an already-snapped `targetBeat` and returns ONE
/// factor; there is deliberately no per-note entry point to misuse.
///
/// ⭐ **4. THE HANDLE BAND IS STRICTLY OUTSIDE THE SELECTION'S BOUNDING BOX.**
/// `PianoRollView.beginGesture`'s own doc sets the bar — *"a change to shipped
/// pointer behaviour with no assertion naming it is how a regression ships as a
/// feature"* — so the cheapest correct answer is a handle that changes NO
/// shipped pointer behaviour at all. A band biased inward would eat the last
/// selected note's own resize handle (`resizeHandleWidth` is only 8 pt) and,
/// worse, the FIRST selected note's body, which is the roll's most-used gesture
/// (rigid group move). Sitting the band in the margin beside the selection means
/// every press that hit a note before still hits it, exactly. The caller pairs
/// this with a "nothing else claimed this point" rule (`PianoRollHover`), which
/// covers the remaining case: an unselected note parked in that margin keeps its
/// press too.
///
/// **THE THREE KNOWN COSTS, stated rather than hidden.** The band is outside the
/// notes, but it is not nowhere, so it takes something:
///
///  1. **A rubber band can no longer be STARTED inside it** (at Pro density,
///     with 2+ notes selected). A drag from the band is a scale, and that is the
///     feature. Everywhere else on the grid the marquee is untouched, and a band
///     may still be dragged THROUGH the strip from outside it.
///  2. **On a dense grid the margin can be occupied**, and then the handle is
///     not offered at that edge — `PianoRollHover` gives a contested point to
///     the note. The remedy is the one every crowded-grid problem has: zoom in
///     (m21-c), which widens the margin in points without changing a beat.
///  3. ⚠️ **A selection starting at beat 0 has NO leading handle**, because its
///     band is `[-12, 0)` — off the left edge of the grid, where no hover is
///     ever reported. That is the most common selection there is (⌘A in a clip
///     that starts on the downbeat), so it is the sharpest cost of choosing
///     strictly-outside, and `leadingHandleIsUnreachableAtBeatZero` pins it so
///     it stays a decision rather than a surprise. The trailing handle is
///     unaffected, so the selection is still scalable — just not about its end.
///     **This is one constant away from a different trade:** an inward bias of a
///     point or two would give beat-0 selections a handle at the price of the
///     zero-regression property above, and a reviewer who weighs reachability
///     higher than that property should change `grabWidth`'s companion rather
///     than re-derive the type.
public enum PianoRollGroupScale {

    /// Which end of the selection the handle sits on. `leading` is the earliest
    /// onset (left), `trailing` the latest end (right).
    public enum Edge: String, CaseIterable, Sendable, Equatable {
        case leading
        case trailing
    }

    /// How far OUTSIDE the selection's bounding box the grab band reaches, in
    /// points. Nothing inside the box is claimed — see decision 4.
    ///
    /// 12 pt rather than `PianoRollModel.resizeHandleWidth`'s 8: this band is
    /// the ONLY way to reach the gesture (a note's resize handle is reachable
    /// anywhere along an 8-pt edge the pointer is already over), and it lives in
    /// empty space where a wider target costs nothing. At the roll's default
    /// 32 px/beat it is a 3/8-beat margin.
    public static let grabWidth: CGFloat = 12

    /// The fewest selected notes that get a group handle. **Two**, and it is a
    /// routing decision, not a taste one: with ONE note the group span IS that
    /// note, so the gesture would be a resize with a different anchor rule and a
    /// different Pro gate sitting a few points from the note's own resize
    /// handle. Two affordances that mean nearly the same thing, adjacent, is how
    /// a user learns to distrust both. Single-note timing edits stay with
    /// `PianoRollModel.resizeNote`.
    public static let minimumNotes = 2

    // MARK: - Geometry

    /// The selection's bounding box in grid CONTENT coordinates, or nil when the
    /// selection is too small to have a group handle.
    ///
    /// ⚠️ **TAKES RECTS, NEVER `selection.count`.** A selection set can name ids
    /// that are no longer in the draft (a delete elsewhere, a stale echo), so
    /// counting ids can promise a handle for a group that has one note on
    /// screen. Counting RECTS — which come from `PianoRollModel.noteRects()`,
    /// the one rect producer — cannot.
    public static func frame(selectedRects: [(id: UUID, rect: CGRect)]) -> CGRect? {
        guard selectedRects.count >= minimumNotes else { return nil }
        var box = selectedRects[0].rect
        for entry in selectedRects.dropFirst() { box = box.union(entry.rect) }
        guard box.width > 0, box.height > 0 else { return nil }
        return box
    }

    /// The grab / draw band for one edge: `grabWidth` wide, the full height of
    /// the selection's box, sitting entirely outside it.
    ///
    /// The vertical extent is the SELECTION's box rather than the whole grid
    /// height on purpose — a full-height bar would claim empty grid at pitches
    /// the user never selected, several octaves away from anything the gesture
    /// affects.
    public static func handleRect(frame: CGRect, edge: Edge) -> CGRect {
        switch edge {
        case .leading:
            return CGRect(x: frame.minX - grabWidth, y: frame.minY,
                          width: grabWidth, height: frame.height)
        case .trailing:
            return CGRect(x: frame.maxX, y: frame.minY,
                          width: grabWidth, height: frame.height)
        }
    }

    /// Which handle `point` is in, or nil.
    ///
    /// The two bands cannot overlap (they are on opposite sides of a box with
    /// positive width), so no precedence between them is needed — and that is a
    /// property of decision 4 rather than luck: an inward-biased band on a
    /// selection narrower than `2 * grabWidth` WOULD have needed a tie-break.
    public static func edge(at point: CGPoint, frame: CGRect) -> Edge? {
        if handleRect(frame: frame, edge: .trailing).contains(point) { return .trailing }
        if handleRect(frame: frame, edge: .leading).contains(point) { return .leading }
        return nil
    }

    // MARK: - The scale itself

    /// One gesture's decision: what stays put, where the dragged edge landed
    /// after every clamp, and the single factor every selected note is scaled
    /// by.
    public struct Plan: Equatable, Sendable {
        /// The beat that does NOT move — the far edge from the handle.
        public let anchorBeat: Double
        /// Where the dragged edge ends up, after clamping. The caller pins the
        /// note that defines this edge to it EXACTLY (see `scaleSelection`).
        public let edgeBeat: Double
        /// New span ÷ old span. Always > 0.
        public let factor: Double

        public init(anchorBeat: Double, edgeBeat: Double, factor: Double) {
            self.anchorBeat = anchorBeat
            self.edgeBeat = edgeBeat
            self.factor = factor
        }
    }

    /// Turn a dragged edge position into a group scale, with every clamp applied
    /// ONCE to the whole group.
    ///
    /// - Parameters:
    ///   - startBeat: earliest onset in the selection (the baseline's, not the
    ///     live draft's — a scale must not compound tick over tick).
    ///   - endBeat: latest end (onset + length) in the selection.
    ///   - edge: which handle is being dragged.
    ///   - targetBeat: where that edge is being asked to go — **already snapped
    ///     by the caller**, because the gesture snaps exactly one number
    ///     (decision 3).
    ///   - minSpanBeats: the floor the caller wants the group's span to respect,
    ///     normally `PianoRollModel.minResizeLength(for:)`.
    /// - Returns: nil when no scale is defined (an empty or zero-span group).
    ///
    /// ⚠️ **THE SPAN FLOOR IS `min(span, minSpanBeats)`, NOT `minSpanBeats`.**
    /// A bare floor would GROW a selection that is already shorter than one grid
    /// step the moment the user touched its handle — a "compress" gesture that
    /// silently expands. Taking the min means the floor can only ever stop a
    /// compression, never start an expansion. A group already below the grid is
    /// therefore compress-locked at that snap, which is precisely what
    /// single-note resize does (`resizeNote`'s `max(minLength, …)`), and it has
    /// the same escape hatch m21-c gave that case: snap off drops the floor to
    /// `MIDINote.minLengthBeats`, so short AI-authored material stays editable
    /// rather than merely viewable.
    ///
    /// ⚠️ **NO CEILING ON EXTENSION, DELIBERATELY.** Notes past the clip end are
    /// legal and latent (m18-f), and how far a gesture may GROW the clip is
    /// already decided in one place — `ClipAutoExtend` (`maxGrowthBars`, the next
    /// clip's edge), reached through `setClipNotes(…extendToCover:)`. A second
    /// limit here would be a second policy for the same question.
    ///
    /// ⚠️ **THE BEAT-0 WALL BINDS ONLY THE LEADING HANDLE**, and the trailing
    /// case is not an omission: its anchor is the earliest onset, which is
    /// already >= 0, and every scaled onset lands at or after it. The leading
    /// clamp interval is non-empty by construction —
    /// `minSpan <= span <= anchorBeat` because the anchor is `startBeat + span`
    /// and `startBeat >= 0` — so `max(0, …)` and the span floor can never
    /// contradict each other. `groupScaleLeadingClampIntervalIsNonEmpty` asserts
    /// that rather than trusting this sentence.
    public static func plan(startBeat: Double, endBeat: Double, edge: Edge,
                            targetBeat: Double, minSpanBeats: Double) -> Plan? {
        let span = endBeat - startBeat
        guard span > 0 else { return nil }
        // One floor for the group, and it can never force growth.
        let minSpan = Swift.min(span, Swift.max(0, minSpanBeats))
        switch edge {
        case .trailing:
            let anchor = startBeat
            let landed = Swift.max(targetBeat, anchor + minSpan)
            return Plan(anchorBeat: anchor, edgeBeat: landed,
                        factor: (landed - anchor) / span)
        case .leading:
            let anchor = endBeat
            let landed = Swift.min(Swift.max(0, targetBeat), anchor - minSpan)
            return Plan(anchorBeat: anchor, edgeBeat: landed,
                        factor: (anchor - landed) / span)
        }
    }
}
