import CoreGraphics
import Foundation

/// The ONE home for "where does a track-header drag land?" (m23-h), in the
/// `ArrangeDropSnap` / `ArrangeGroupDrag` / `MixerStripLayout` tradition: pure,
/// headless, unit-tested, and the ONLY producer of a landing index in the
/// program.
///
/// WHY A REGISTRY AND NOT TWO LINES IN THE VIEW: a drag that draws an insertion
/// line where the track will land and then commits a DIFFERENT index is the
/// classic reorder bug, and it is invisible to any gate that only reads the
/// final order (the two computations agree on most fixtures, and disagree
/// exactly where heights are uneven). So the indicator's y and the committed
/// index come out of the SAME call: `ResolvedTrackDrop.init` is `fileprivate`,
/// making `resolve(...)` the only way to obtain one, and the view's commit path
/// takes a `ResolvedTrackDrop` — so a second computation is not merely absent,
/// it is unrepresentable (the m23-f `ResolvedDropBeat` model).

/// The AXIS-NEUTRAL core of every reorder drag in the app (m23-z): a measured
/// ladder of slots along ONE axis, plus the three rules a reorder drag needs —
/// which slot is the pointer over, which edge does the insertion line mark, and
/// how far does a resting slot slide to open the gap.
///
/// WHY A CORE AND NOT A REUSED `resolve(pointerY:)`: the mixer's ladder runs
/// along x (strips), the arrange's along y (rows). Calling a `pointerY` entry
/// point with an x coordinate reads fine today and misleads in six months, and
/// re-implementing the scan per surface is two producers of one rule — the
/// failure this whole registry exists to prevent. So: one core, two honest
/// facades (`TrackReorderDrag.resolve(pointerY:…)` for the arrange,
/// `MixerStripReorder.resolve(pointerX:…)` for the console).
///
/// Deliberately `internal`: it has no business being a public vocabulary type.
/// The two facades are the API.
struct ReorderLadder: Equatable {
    /// Leading edge of each slot along the axis, in slot order. Ascending.
    var starts: [CGFloat]
    /// Extent of each slot along the same axis (a row's height, a strip's width).
    var extents: [CGFloat]

    var count: Int { starts.count }

    var isWellFormed: Bool { !starts.isEmpty && starts.count == extents.count }

    /// The MEASURED gap between slot `i` and `i + 1` — PER INDEX, never sampled
    /// once and reused. The arrange's gaps happen to be uniform; the mixer's are
    /// NOT (its channel/bus divider makes exactly one of them
    /// `spacing + dividerWidth + spacing`), and a single sample there still
    /// yields a plausible number — so the failure would be silent.
    func gap(after i: Int) -> CGFloat {
        guard starts.indices.contains(i), extents.indices.contains(i),
              starts.indices.contains(i + 1) else { return 0 }
        return starts[i + 1] - (starts[i] + extents[i])
    }

    /// The slot the pointer is OVER — the last slot whose start is at or before
    /// it — clamped to the ends. Continuous and monotonic by construction: the
    /// gap between two slots belongs to the slot before it, so there is no dead
    /// zone where a drag stops responding, and dragging further never walks the
    /// landing backwards. nil only for an unusable ladder.
    func slot(at pointer: CGFloat) -> Int? {
        guard isWellFormed else { return nil }
        let hit = starts.lastIndex { $0 <= pointer } ?? 0
        return min(max(0, hit), count - 1)
    }

    /// Where the insertion line goes for a landing at `landing`, coming from
    /// `from`: the FAR edge of the landing slot when moving forward, its NEAR
    /// edge when moving back. Both read as "it goes here" without an arrow.
    func edge(landing: Int, from: Int) -> CGFloat {
        guard starts.indices.contains(landing) else { return 0 }
        return landing > from ? starts[landing] + extents[landing] : starts[landing]
    }

    /// The slot that CLOSES when the dragged element leaves: its own extent plus
    /// the gap on the side it departs from.
    ///
    /// THE DIRECTION RULE, and why it is not `gap(after: from)`: removing an
    /// element merges the gaps on either side of it into one, and the surviving
    /// gap is the layout's to decide. On a surface with a section divider (the
    /// mixer) the divider gap is STRUCTURAL — it stays at the section boundary,
    /// because a reorder never changes how many strips are in each section — so
    /// the gap that actually disappears is the plain one on the side facing the
    /// destination. On a uniform ladder (the arrange) both sides are equal and
    /// the rule collapses to the constant. Total on its domain: callers guard
    /// `from != landing`, so the neighbour on the destination side always exists.
    func vacatedSlot(from: Int, landing: Int) -> CGFloat {
        guard extents.indices.contains(from) else { return 0 }
        return extents[from] + (landing > from ? gap(after: from) : gap(after: from - 1))
    }

    /// How far the slot at `slot` SLIDES while the drag is in flight, so the
    /// layout parts and opens the gap the dragged element is about to occupy.
    /// Zero for the dragged element itself (it follows the pointer instead) and
    /// for a landing that moves nothing.
    func displacement(slot: Int, from: Int, landing: Int) -> CGFloat {
        guard isWellFormed, from != landing,
              starts.indices.contains(slot),
              starts.indices.contains(from),
              starts.indices.contains(landing),
              slot != from else { return 0 }
        let vacated = vacatedSlot(from: from, landing: landing)
        if landing > from, slot > from, slot <= landing { return -vacated }
        if landing < from, slot >= landing, slot < from { return vacated }
        return 0
    }
}

/// The sidebar's MEASURED vertical ladder: each track row's top and total
/// height, in track order, in the track-list's own coordinate space.
///
/// MEASURED, never recomputed: a row's height is `rowHeight` plus whatever its
/// take section and automation row add, `rowHeight` is user-adjustable (beta
/// m10-d), and the rows are laid out by a `VStack` — so the only honest ladder
/// is the one the layout actually produced. A ladder recomputed from the model
/// would be a SECOND producer, free to agree with the view by luck.
public struct TrackRowLadder: Equatable, Sendable {
    /// Top edge of each row, in track order. Ascending.
    public var tops: [CGFloat]
    /// Total height of each row (header + takes + automation), in track order.
    public var heights: [CGFloat]

    public init(tops: [CGFloat] = [], heights: [CGFloat] = []) {
        self.tops = tops
        self.heights = heights
    }

    public static let empty = TrackRowLadder()

    public var count: Int { tops.count }

    /// A ladder is usable only when it describes every row exactly once. An
    /// unmeasured or half-measured ladder must produce NO landing rather than a
    /// plausible-looking index 0.
    public var isWellFormed: Bool { axis.isWellFormed }

    /// This ladder as the axis-neutral core reads it (y-oriented). The scan, the
    /// indicator edge and the parting distance all come from there, so the
    /// arrange and the mixer cannot drift apart.
    var axis: ReorderLadder { ReorderLadder(starts: tops, extents: heights) }

    /// The MEASURED gap between row `i` and row `i + 1`. Per index — see
    /// `ReorderLadder.gap(after:)` for why a single sample is not safe in
    /// general (it is safe HERE, which is what `spacing` documents).
    public func gap(after i: Int) -> CGFloat { axis.gap(after: i) }

    /// The MEASURED gap between two rows (0 when there is only one). Read from
    /// the layout rather than hardcoded to the `VStack`'s 6 pt, for the same
    /// reason the tops are measured: the constant is the view's to change.
    ///
    /// SAMPLED FROM ROWS 0–1, WHICH IS ONLY HONEST BECAUSE THE GAP IS UNIFORM:
    /// the arrange sidebar is a single `VStack(spacing: 6)` with exactly one
    /// `TrackRow` per track and no per-row padding, so every gap is that one
    /// constant regardless of how tall a row grows (verified in
    /// `TrackListView.swift`; a row's automation/takes sections live INSIDE the
    /// card and land in `heights`, never between cards). A surface whose gaps
    /// vary per row — the mixer, whose channel/bus partition inserts a divider —
    /// must NOT reuse this, because sampling one gap there still produces a
    /// plausible number and so fails SILENTLY. m23-z resolved that by deriving
    /// the gap PER INDEX (`gap(after:)`, and `ReorderLadder.vacatedSlot`'s
    /// direction rule); this stays only as the arrange's convenience, and
    /// nothing in the drag path reads it any more.
    public var spacing: CGFloat {
        guard count >= 2 else { return 0 }
        return gap(after: 0)
    }
}

/// Where a track-header drag would land, and where to draw the line that says
/// so. The two can never disagree: both come from one `resolve` call, and this
/// type cannot be constructed anywhere else (`fileprivate init`).
public struct ResolvedTrackDrop: Equatable, Sendable {
    /// The index the drag started from.
    public let from: Int
    /// The FINAL index the track lands at — exactly what
    /// `ProjectStore.reorderTrack(id:toIndex:)` and the `track.reorder` wire
    /// command mean by `toIndex`/`index` (NOT SwiftUI's `onMove` pre-removal
    /// offset). Always a valid index into the ladder.
    public let index: Int
    /// Content-space y for the insertion line, or nil when the drop would not
    /// move anything. Exclusivity is STRUCTURAL rather than a second `if` at the
    /// draw site: no move ⇒ no line, by construction.
    public let indicatorY: CGFloat?

    /// True when committing this drop would actually change the order.
    public var moves: Bool { index != from }

    fileprivate init(from: Int, index: Int, indicatorY: CGFloat?) {
        self.from = from
        self.index = index
        self.indicatorY = indicatorY
    }
}

public enum TrackReorderDrag {
    /// Resolves a live pointer position into a landing.
    ///
    /// THE RULE: the drop target is the row the pointer is OVER — the last row
    /// whose top is at or above the pointer — clamped to the ends. Continuous
    /// and monotonic by construction: the 6 pt gaps between rows belong to the
    /// row above them, so there is no dead zone where a drag stops responding,
    /// and dragging further down never moves the landing back up.
    ///
    /// Returns nil when the ladder is unusable (not yet measured, or stale
    /// against the track list) or `from` is not a row: a drag with no honest
    /// geometry must do NOTHING, not fall back to index 0 — which would look
    /// exactly like "the user dragged to the top".
    ///
    /// - Parameters:
    ///   - pointerY: the pointer's y in the track list's coordinate space (the
    ///     SAME space the ladder was measured in — mixing a `.local` frame with
    ///     a content-space gesture is silent at scroll 0 and wrong everywhere
    ///     else).
    ///   - from: the dragged track's current index.
    public static func resolve(pointerY: CGFloat, from: Int,
                               ladder: TrackRowLadder) -> ResolvedTrackDrop? {
        guard ladder.tops.indices.contains(from),
              let index = ladder.axis.slot(at: pointerY) else { return nil }
        guard index != from else {
            return ResolvedTrackDrop(from: from, index: index, indicatorY: nil)
        }
        // The line marks the EDGE the track lands against: below the target row
        // when moving down, above it when moving up. Both read as "it goes
        // here" without needing an arrow.
        return ResolvedTrackDrop(from: from, index: index,
                                 indicatorY: ladder.axis.edge(landing: index, from: from))
    }

    /// How far a row SLIDES while a drag is in flight, so the list parts and
    /// opens the slot the track is about to occupy.
    ///
    /// WHY THE LIST PARTS AT ALL: without it the picked-up row simply covers
    /// whatever it is dragged over — the user cannot see the row they are aiming
    /// at, which is precisely the information the gesture needs to convey. The
    /// rows between the origin and the landing move by EXACTLY the slot the
    /// dragged row vacates (its height plus the measured gap), which is the same
    /// distance the committed reorder will move them — so the preview is the
    /// result, not an impression of it.
    ///
    /// Returns 0 for the dragged row itself (it follows the pointer instead),
    /// for a landing that would not move anything, and for any unusable input.
    public static func displacement(row: Int, drop: ResolvedTrackDrop,
                                    ladder: TrackRowLadder) -> CGFloat {
        guard drop.moves else { return 0 }
        return ladder.axis.displacement(slot: row, from: drop.from, landing: drop.index)
    }
}
