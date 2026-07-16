import CoreGraphics
import Foundation
import DAWCore

// Arrange timeline pointer affordances (m17-c, user requests #4 + #5): the
// headless zone classifier + snap math behind the playhead grab strip, the
// lanes hover ghost line, and the empty-lane click-seek. Pure + `Sendable` so
// every decision the view makes about the pointer is testable without AppKit
// (the `LoopRulerModel`/`MarkerLaneModel` precedent). The view builds one
// `ArrangePointerLane` per track from the SAME laneTop/rowHeight/extras math
// its layout uses, and every x↔beat conversion routes through the live
// instance `pixelsPerBeat` (the m17-b zoom law — nothing here hardcodes 16).

/// One arrange track row's vertical geometry for pointer classification.
/// `clipTop..<clipBottom` is the clip lane band; `clipBottom..<bottom` is the
/// row's expanded extras (take lanes + automation editor), which own their own
/// gestures — the pointer layer must stay out of their way.
public struct ArrangePointerLane: Equatable, Sendable {
    public var clipTop: CGFloat
    public var clipBottom: CGFloat
    public var bottom: CGFloat
    /// The row's clip spans in timeline beats (draw order — later wins on top).
    public var clipSpans: [ArrangeClipSpan]

    public init(clipTop: CGFloat, clipBottom: CGFloat, bottom: CGFloat,
                clipSpans: [ArrangeClipSpan] = []) {
        self.clipTop = clipTop
        self.clipBottom = clipBottom
        self.bottom = bottom
        self.clipSpans = clipSpans
    }
}

/// A clip's beat span, the minimal shape zone classification needs.
public struct ArrangeClipSpan: Equatable, Sendable {
    public var startBeat: Double
    public var lengthBeats: Double
    public var endBeat: Double { startBeat + lengthBeats }

    public init(startBeat: Double, lengthBeats: Double) {
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }
}

/// What the pointer is over in the lanes area. Raw values are stable strings so
/// the `debug.arrangePointer` seam can echo them without a mapping table.
public enum ArrangePointerZone: String, Equatable, Sendable {
    /// Within the grab tolerance of the playhead, over a surface the grab strip
    /// actually covers (clip bands + the free space below the lanes) — hovering
    /// here shows the open hand and a drag scrub-seeks.
    case playheadGrab = "playhead-grab"
    /// Over a clip block — the block's own cursor/gestures rule; no ghost line.
    case clip
    /// Over a row's expanded take lanes / automation editor — those editors own
    /// the pointer entirely (comp painting, breakpoint drags); no ghost, no
    /// seek, and the grab strip carves this band out.
    case laneControls = "lane-controls"
    /// Empty timeline space (an empty stretch of a clip lane, the gap between
    /// rows, or below the last lane): ghost line + click-to-seek live here.
    case empty
    /// Above the lane area (the `.full` ruler inset) or off the content — the
    /// pointer layer is inert (the ruler surfaces own their own affordances).
    case outside
}

/// The pure decisions behind the m17-c pointer layer.
public enum ArrangePointer {
    /// Half-width (points) of the playhead grab strip: the playhead is grabbable
    /// within ± this tolerance. Deliberately narrow so a clip's trim edge one
    /// zoom step away stays reachable; the classifier and the strip views share
    /// this ONE constant so the advertised zone never drifts from the hit zone.
    public static let playheadGrabTolerance: CGFloat = 4

    /// Movement (points) below which a press on the grab strip stays a click
    /// (which is a no-op — grabbing the playhead without moving must not jump
    /// it to a snapped beat).
    public static let scrubSlop: CGFloat = 2

    /// Classifies a content-space point against the lane geometry. `topInset`
    /// is the ruler strip height in `.full` (0 in `.lanes`, where the ruler is
    /// pinned elsewhere); `contentBottom` is the drawn lane-stack height.
    /// Precedence: laneControls > playheadGrab > clip > empty — mirroring the
    /// actual hit-test stack (extras editors sit above the strip; the strip
    /// sits above the clip blocks).
    public static func zone(
        x: CGFloat, y: CGFloat,
        playheadX: CGFloat,
        pixelsPerBeat: CGFloat,
        topInset: CGFloat,
        contentBottom: CGFloat,
        lanes: [ArrangePointerLane],
        laneSpacing: CGFloat
    ) -> ArrangePointerZone {
        guard x >= 0, y >= topInset, y <= contentBottom else { return .outside }
        let nearPlayhead = abs(x - playheadX) <= playheadGrabTolerance

        for lane in lanes {
            if y >= lane.clipTop && y < lane.clipBottom {
                // Clip lane band: the grab strip covers it, above the blocks.
                if nearPlayhead { return .playheadGrab }
                let beat = Double(x / max(pixelsPerBeat, 0.0001))
                return clipIndex(atBeat: beat, in: lane.clipSpans) != nil ? .clip : .empty
            }
            if y >= lane.clipBottom && y < lane.bottom {
                // Take lanes / automation editor — theirs, even at the playhead.
                return .laneControls
            }
            if y >= lane.bottom && y < lane.bottom + laneSpacing {
                // The 6 pt gap between rows: empty space, but the grab strip
                // deliberately does not cover it (segments span clip bands +
                // tail only), so it is never `playheadGrab`.
                return .empty
            }
        }
        // Below the last row (or an empty project): free space — the tail grab
        // segment covers it, else it's empty seekable space.
        return nearPlayhead ? .playheadGrab : .empty
    }

    /// The topmost clip under a beat (draw order: later in the array wins),
    /// or nil over empty lane space. Zero-length spans never hit.
    public static func clipIndex(atBeat beat: Double, in spans: [ArrangeClipSpan]) -> Int? {
        spans.lastIndex { beat >= $0.startBeat && beat < $0.endBeat && $0.lengthBeats > 0 }
    }

    /// The beat a pointer x maps to for the seek surfaces (ghost line,
    /// empty-lane click, playhead scrub): floored at 0, snapped on the active
    /// arrange grid — or raw when the fine-drag modifier (⌥, the house
    /// convention) bypasses the snap.
    public static func beat(
        forX x: CGFloat,
        pixelsPerBeat: CGFloat,
        snap: ClipSnap,
        meterMap: MeterMap,
        snapBypassed: Bool = false
    ) -> Double {
        let raw = max(0, Double(x / max(pixelsPerBeat, 0.0001)))
        return snapBypassed ? raw : snap.snap(beat: raw, meterMap: meterMap)
    }

    /// Cursor the pointer layer advertises for a zone. Only the playhead grab
    /// claims one (the movable-body open/closed hand via the tested
    /// `CursorAffordance` catalog); every other zone returns nil so the clip
    /// blocks' own resolvers — and the plain arrow over empty space — rule
    /// without a competing tracking area (the gain-chip no-race precedent).
    public static func cursor(for zone: ArrangePointerZone, dragging: Bool = false) -> CursorKind? {
        switch zone {
        case .playheadGrab:
            return dragging ? CursorAffordance.playhead.dragCursor
                            : CursorAffordance.playhead.restCursor
        case .clip, .laneControls, .empty, .outside:
            return nil
        }
    }
}
