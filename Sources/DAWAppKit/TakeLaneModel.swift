import CoreGraphics
import Foundation
import DAWCore

/// Beat↔x mapping and lane-row hit classification for the arrange take-lane
/// editor (M5 iii-c), aligned to the timeline's fixed pixels-per-beat so a
/// group's lane rows line up under the comped member clips that ride the main
/// lane. A value type carrying only geometry — pure, `Equatable`,
/// headless-testable (the `AutomationGeometry` / `ClipEditGeometry` precedent).
///
/// Coordinate space is LOCAL to the takes section: x = 0 at bar 1, y = 0 at the
/// top of the first lane row; the caller has already offset the section below
/// the track's clip lane. Rows stack top-to-bottom in the group's lane order
/// (row 0 = oldest lane); the view draws each lane's dim take material with the
/// comp's selected lane-range regions glowing over it.
public struct TakeLaneGeometry: Sendable, Equatable {
    /// Horizontal scale — matches `TimelineLanesView.pixelsPerBeat`.
    public var pixelsPerBeat: CGFloat
    /// Height of one lane sub-row.
    public var rowHeight: CGFloat

    public init(pixelsPerBeat: CGFloat = 16, rowHeight: CGFloat = 26) {
        self.pixelsPerBeat = pixelsPerBeat
        self.rowHeight = rowHeight
    }

    /// x for an absolute timeline beat.
    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    /// Absolute beat at an x, floored at 0 (a comp can never reach before bar 1).
    public func beat(forX x: CGFloat) -> Double { max(0, Double(x / pixelsPerBeat)) }

    /// Top y of lane row `index`.
    public func rowTop(_ index: Int) -> CGFloat { CGFloat(index) * rowHeight }

    /// Full stacked height of `rowCount` lane rows.
    public func height(rowCount: Int) -> CGFloat { CGFloat(max(0, rowCount)) * rowHeight }

    /// Lane-row index a local y lands in, or nil when outside the stacked rows.
    public func rowIndex(forY y: CGFloat, rowCount: Int) -> Int? {
        guard y >= 0, rowHeight > 0 else { return nil }
        let index = Int(y / rowHeight)
        return (index >= 0 && index < rowCount) ? index : nil
    }

    /// The drawn rect (local coordinates) for a comp segment on lane row `index`:
    /// its `[startBeat, endBeat)` span across the full row height. A tiny inset
    /// keeps the glow off the row edges.
    public func segmentRect(startBeat: Double, endBeat: Double, rowIndex index: Int,
                            inset: CGFloat = 1.5) -> CGRect {
        let x0 = x(forBeat: startBeat)
        let x1 = x(forBeat: max(startBeat, endBeat))
        return CGRect(x: x0, y: rowTop(index) + inset,
                      width: max(0, x1 - x0), height: max(0, rowHeight - inset * 2))
    }
}

/// A snapped, classified paint gesture across one lane row (M5 iii-c). A short
/// press (below the click threshold) reads as a whole-lane SELECT; a real drag
/// paints the lane into the comp over `[startBeat, endBeat)`.
public struct TakePaintGesture: Sendable, Equatable {
    /// The lane the row belongs to.
    public var laneID: UUID
    /// Snapped, ordered, range-clamped span the drag painted.
    public var startBeat: Double
    public var endBeat: Double
    /// True when the raw drag stayed under the click threshold — the view swaps
    /// the whole comp to this lane (a `selectTake`) instead of painting a span.
    public var isClick: Bool

    public init(laneID: UUID, startBeat: Double, endBeat: Double, isClick: Bool) {
        self.laneID = laneID
        self.startBeat = startBeat
        self.endBeat = endBeat
        self.isClick = isClick
    }
}

/// Pure comp-segment editing for the take-lane surface: paint-drag classification
/// + snapping, the "paint lane over a range" override math, whole-lane select,
/// and the sort/clamp/coalesce normalize that mirrors what
/// `ProjectStore.setCompSegments` accepts (sorted, non-overlapping, `end > start`,
/// inside the group range). Static, value-in/value-out — the view is thin over
/// these and the tests exercise them headless (the `AutomationEdit` precedent).
///
/// Every op returns a fresh `[CompSegment]` fit to hand straight to
/// `setCompSegments`: the paint output is already non-overlapping and sorted, so
/// the store never rejects a comp the editor drew.
public enum TakeComp {
    /// Minimum painted span (beats) — mirrors `ClipEdit.minClipLengthBeats` so a
    /// snapped paint can never collapse below what a member clip can be.
    public static let minPaintBeats: Double = ClipEdit.minClipLengthBeats

    // MARK: - Drag classification

    /// Classifies + snaps a horizontal paint drag on `laneID`'s row. `fromBeatRaw`
    /// / `toBeatRaw` are the unsnapped press/current beats; the span is ordered,
    /// each end snapped to the grid, widened to at least `minPaintBeats`, and
    /// clamped to the group `range`. `isClick` is set when the RAW span stayed
    /// under `clickThresholdBeats` (a tap, not a paint) so the caller can route it
    /// to a whole-lane select.
    public static func classifyDrag(
        laneID: UUID, fromBeatRaw: Double, toBeatRaw: Double,
        snap: ClipSnap, beatsPerBar: Int, range: ClosedRange<Double>,
        clickThresholdBeats: Double = 0.15
    ) -> TakePaintGesture {
        let rawSpan = abs(toBeatRaw - fromBeatRaw)
        let lo = min(fromBeatRaw, toBeatRaw)
        let hi = max(fromBeatRaw, toBeatRaw)
        var start = snap.snap(beat: lo, beatsPerBar: beatsPerBar)
        var end = snap.snap(beat: hi, beatsPerBar: beatsPerBar)
        if end <= start { end = start + minPaintBeats }
        // Clamp into the group range, preserving a non-empty span.
        start = start.clamped(to: range)
        end = end.clamped(to: range)
        if end <= start {
            start = max(range.lowerBound, min(start, range.upperBound - minPaintBeats))
            end = min(range.upperBound, start + minPaintBeats)
        }
        return TakePaintGesture(laneID: laneID, startBeat: start, endBeat: end,
                                isClick: rawSpan < clickThresholdBeats)
    }

    // MARK: - Edits

    /// Paints `laneID` over `[startBeat, endBeat)`, OVERRIDING whatever the comp
    /// had there: existing segments are trimmed/split around the painted span, the
    /// new segment is inserted, and abutting same-lane neighbors coalesce. The
    /// result is sorted, non-overlapping, and clamped to `range` — ready for
    /// `setCompSegments`. A degenerate span (`end <= start` after clamping) is a
    /// no-op that still returns the normalized comp.
    public static func paint(
        _ comp: [CompSegment], laneID: UUID,
        startBeat: Double, endBeat: Double, range: ClosedRange<Double>
    ) -> [CompSegment] {
        let a = max(startBeat, range.lowerBound)
        let b = min(endBeat, range.upperBound)
        guard b > a else { return normalize(comp, range: range) }

        var out: [CompSegment] = []
        for seg in comp {
            // Keep the portion of `seg` left of the painted span.
            if seg.startBeat < a {
                let leftEnd = min(seg.endBeat, a)
                if leftEnd > seg.startBeat {
                    out.append(CompSegment(laneID: seg.laneID, startBeat: seg.startBeat, endBeat: leftEnd))
                }
            }
            // Keep the portion right of the painted span.
            if seg.endBeat > b {
                let rightStart = max(seg.startBeat, b)
                if seg.endBeat > rightStart {
                    out.append(CompSegment(laneID: seg.laneID, startBeat: rightStart, endBeat: seg.endBeat))
                }
            }
        }
        out.append(CompSegment(laneID: laneID, startBeat: a, endBeat: b))
        return normalize(out, range: range)
    }

    /// A quick whole-lane swap: the comp becomes one full-range segment on
    /// `laneID` (mirrors `ProjectStore.selectTake`).
    public static func selectWholeRange(laneID: UUID, range: ClosedRange<Double>) -> [CompSegment] {
        guard range.upperBound > range.lowerBound else { return [] }
        return [CompSegment(laneID: laneID, startBeat: range.lowerBound, endBeat: range.upperBound)]
    }

    // MARK: - Queries

    /// The lane whose comp segment covers `beat` (`start <= beat < end`), or nil
    /// for a gap (silence). Used to light the row a beat currently plays from.
    public static func laneID(at beat: Double, comp: [CompSegment]) -> UUID? {
        for seg in comp where beat >= seg.startBeat && beat < seg.endBeat {
            return seg.laneID
        }
        return nil
    }

    /// The comp segments assigned to `laneID` (the glowing regions on its row).
    public static func segments(forLane laneID: UUID, comp: [CompSegment]) -> [CompSegment] {
        comp.filter { $0.laneID == laneID }
    }

    // MARK: - Normalize

    /// Sorts by start, clamps each segment to `range`, drops empties, and
    /// coalesces abutting same-lane neighbors — the canonical shape
    /// `setCompSegments` stores. Input need not be sorted; overlaps are resolved
    /// last-writer-wins by trimming an earlier segment to the next one's start
    /// (defensive — `paint` never produces overlaps).
    public static func normalize(_ comp: [CompSegment], range: ClosedRange<Double>) -> [CompSegment] {
        let clamped: [CompSegment] = comp.compactMap { seg in
            let s = seg.startBeat.clamped(to: range)
            let e = seg.endBeat.clamped(to: range)
            guard e > s else { return nil }
            return CompSegment(laneID: seg.laneID, startBeat: s, endBeat: e)
        }
        let sorted = clamped.sorted { $0.startBeat < $1.startBeat }
        var out: [CompSegment] = []
        for seg in sorted {
            // Resolve overlaps last-writer-wins: trim (or drop) an earlier
            // segment whose tail the later one's start intrudes on.
            while let last = out.last, seg.startBeat < last.endBeat {
                if seg.startBeat <= last.startBeat {
                    out.removeLast()                // earlier segment fully covered
                } else {
                    out[out.count - 1] = CompSegment(laneID: last.laneID,
                                                     startBeat: last.startBeat, endBeat: seg.startBeat)
                    break
                }
            }
            // Coalesce an abutting same-lane run into one segment.
            if let last = out.last, last.laneID == seg.laneID,
               abs(last.endBeat - seg.startBeat) < 1e-9 {
                out[out.count - 1] = CompSegment(laneID: last.laneID, startBeat: last.startBeat,
                                                 endBeat: max(last.endBeat, seg.endBeat))
                continue
            }
            out.append(seg)
        }
        return out
    }
}

/// Small selection/derivation helpers behind the take disclosure glyph and the
/// per-lane row chrome (the `AutomationLaneSelection` precedent). Pure over the
/// domain `Track` / `TakeGroup` so the header, the row, and the tests agree.
public enum TakeLaneSelection {
    /// True when a track carries any take group — the state the disclosure glyph
    /// glows for ("this track has takes to comp").
    public static func hasTakeGroups(_ track: Track) -> Bool {
        !track.takeGroups.isEmpty
    }

    /// Total lane sub-rows a track's takes section draws (summed across its
    /// groups) — drives the section height in both the sidebar and the timeline.
    public static func totalLaneRows(_ track: Track) -> Int {
        track.takeGroups.reduce(0) { $0 + $1.lanes.count }
    }

    /// A short "name · N" badge for a group's member clips (group name + lane
    /// count), so a comped clip reads as part of its take group at a glance.
    public static func badge(for group: TakeGroup) -> String {
        "\(group.name) · \(group.lanes.count)"
    }

    /// The group that owns a member clip on `track` (matched by `takeGroupID`),
    /// or nil for an ordinary clip.
    public static func group(forMember clip: Clip, in track: Track) -> TakeGroup? {
        guard let gid = clip.takeGroupID else { return nil }
        return track.takeGroups.first { $0.id == gid }
    }

    /// True when `clip` is a comp member whose LEFT edge is an internal comp
    /// splice (another member of the same group ends exactly at its start) — the
    /// view draws a thin glowing splice line there. The group's outer start is
    /// never a splice.
    public static func hasLeadingSplice(_ clip: Clip, among members: [Clip]) -> Bool {
        guard let gid = clip.takeGroupID else { return false }
        return members.contains { other in
            other.id != clip.id && other.takeGroupID == gid
                && abs((other.startBeat + other.lengthBeats) - clip.startBeat) < 1e-6
        }
    }
}
