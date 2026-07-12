import CoreGraphics
import Foundation

/// Direct-manipulation loop region on the arrange ruler (beta m10-g). The wire
/// command `transport.setLoop` and `ProjectStore.setLoop` already persist a loop
/// region; the TransportBar LOOP chip toggles it. This namespace is the pure
/// geometry + edit math for the missing MOUSE surface: sketch a region by
/// dragging the ruler, drag its edges to resize, drag its body to move, click to
/// toggle it, click empty ruler to seek.
///
/// Like `PianoRollPlayhead` / `ClipEdit`, the loop ruler is a RENDERING +
/// gesture layer over existing state — no new wire command (`transport.setLoop`
/// and `transport.seek` pre-exist). Everything a test can pin (zone
/// classification, create/resize/move math, click semantics, snap + min-length +
/// clamp) lives here so the SwiftUI view stays thin (the m10-c/e precedent).

// MARK: - Region

/// A loop region in PROJECT beats. `start < end` is the invariant every producer
/// in this file guarantees (create/resize/move all keep at least one snap unit).
public struct LoopRegion: Sendable, Equatable {
    public var start: Double
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// Region length in beats (always > 0 for a well-formed region).
    public var length: Double { end - start }
}

// MARK: - Zones

/// Which part of the loop band a ruler point landed on — routes a press to the
/// right gesture (resize an edge, move the body, or sketch/seek on empty ruler).
/// `empty` covers both "no region at all" and "over the ruler but outside the
/// region."
public enum LoopRulerZone: Sendable, Equatable {
    case edgeStart
    case edgeEnd
    case body
    case empty
}

/// What a click on the ruler means: toggle looping (inside the region) or seek
/// the transport to a snapped beat (empty ruler). The mirror of the TransportBar
/// LOOP chip for the inside case, and the m10-e piano-roll-strip seek for the
/// outside case (the ruler must never be a dead click surface).
public enum LoopClickResult: Sendable, Equatable {
    case toggle
    case seek(Double)
}

// MARK: - Geometry

/// Beat↔x mapping and zone hit-classification for the arrange loop ruler, aligned
/// to the timeline's fixed pixels-per-beat so the band lines up with the grid. A
/// value type carrying only geometry — pure, `Equatable`, headless-testable (the
/// `ClipEditGeometry` precedent). Coordinates are CONTENT-space x (x = 0 at the
/// timeline origin, `beat · pixelsPerBeat` elsewhere); the ruler spans the full
/// content width.
public struct LoopRulerGeometry: Sendable, Equatable {
    /// Horizontal scale — matches `TimelineLanesView.pixelsPerBeat`.
    public var pixelsPerBeat: CGFloat
    /// Grab strip (points) around each edge for a resize; a point within this of an
    /// edge classifies as that edge, even from just outside the region (forgiving).
    public var edgeTolerance: CGFloat

    public init(pixelsPerBeat: CGFloat = 16, edgeTolerance: CGFloat = 6) {
        self.pixelsPerBeat = pixelsPerBeat
        self.edgeTolerance = edgeTolerance
    }

    /// Content-space x for a project beat.
    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    /// Project beat at a content x, floored at 0.
    public func beat(forX x: CGFloat) -> Double { max(0, Double(x / pixelsPerBeat)) }

    /// Classifies a content-space x against a region. A nil region (none exists)
    /// makes the WHOLE ruler `.empty`, so it is one uniform sketch/seek surface.
    /// Precedence: an edge within tolerance wins over the body (so the corners
    /// resize and the middle moves); when both edges are within tolerance (a very
    /// short region) the NEARER edge wins.
    public func classify(contentX: CGFloat, region: LoopRegion?) -> LoopRulerZone {
        guard let region else { return .empty }
        let startX = x(forBeat: region.start)
        let endX = x(forBeat: region.end)
        let dStart = abs(contentX - startX)
        let dEnd = abs(contentX - endX)
        if dStart <= edgeTolerance || dEnd <= edgeTolerance {
            return dStart <= dEnd ? .edgeStart : .edgeEnd
        }
        if contentX > startX, contentX < endX { return .body }
        return .empty
    }
}

// MARK: - Edit math

/// Pure loop-region edit math for the arrange ruler gesture layer: snapped
/// create/resize/move preview and click semantics. Every op enforces a minimum
/// region and clamps ≥ 0 so an on-screen preview never disagrees with what
/// `ProjectStore.setLoop` will persist. Static, value-in/value-out — the view is
/// thin over these and the tests exercise them headless (the `ClipEdit`
/// precedent).
public enum LoopEdit {
    /// Absolute floor on a loop region's length when snapping is off — mirrors
    /// `TransportState.minLoopLengthBeats` (0.25 beat) so a preview can never go
    /// past what the store allows. Kept local (not imported) so the pure model's
    /// tests don't depend on DAWCore's constant, the `ClipEdit.minClipLengthBeats`
    /// precedent.
    public static let minLoopLengthBeats: Double = 0.25

    /// Floating-point slack for length comparisons, so a region exactly one snap
    /// unit long isn't rejected by rounding.
    private static let epsilon: Double = 1e-9

    /// The minimum region length for a given snap: one grid unit when snapping,
    /// else the absolute floor. So a snapped create/resize can never produce a
    /// sub-grid loop, and an off-grid one still can't go below the floor.
    public static func minRegionBeats(snap: ClipSnap, beatsPerBar: Int) -> Double {
        snap.gridBeats(beatsPerBar: beatsPerBar) ?? minLoopLengthBeats
    }

    // MARK: Create (sketch a new region)

    /// Proposed region for a create-drag from `anchorBeat` (press) to `currentBeat`
    /// (pointer). Snaps BOTH endpoints, orders them so a leftward (right-to-left)
    /// drag is valid, and returns nil when the snapped span is shorter than one
    /// snap unit — a sub-threshold drag the caller treats as a click (seek). With
    /// snapping ON, two distinct snapped grid points are already ≥ one grid apart,
    /// so the minimum falls out; with snapping OFF the floor is enforced explicitly.
    public static func createRegion(
        anchorBeat: Double, currentBeat: Double, snap: ClipSnap, beatsPerBar: Int
    ) -> LoopRegion? {
        let a = snap.snap(beat: anchorBeat, beatsPerBar: beatsPerBar)
        let b = snap.snap(beat: currentBeat, beatsPerBar: beatsPerBar)
        let lo = min(a, b)
        let hi = max(a, b)
        let minLen = minRegionBeats(snap: snap, beatsPerBar: beatsPerBar)
        guard hi - lo >= minLen - epsilon else { return nil }
        return LoopRegion(start: lo, end: hi)
    }

    // MARK: Resize (drag an edge)

    /// Resize the START edge; the END stays pinned. Snaps, floors at 0, and clamps
    /// so at least one snap unit remains. Dragging the start PAST the end pins it
    /// exactly one unit before the end (CLAMP, not flip — the predictable choice).
    public static func resizedStart(
        region: LoopRegion, newStartRaw: Double, snap: ClipSnap, beatsPerBar: Int
    ) -> LoopRegion {
        let minLen = minRegionBeats(snap: snap, beatsPerBar: beatsPerBar)
        let snapped = snap.snap(beat: max(0, newStartRaw), beatsPerBar: beatsPerBar)
        let maxStart = max(0, region.end - minLen)
        let start = min(max(0, snapped), maxStart)
        return LoopRegion(start: start, end: region.end)
    }

    /// Resize the END edge; the START stays pinned. Snaps and clamps so at least
    /// one snap unit remains. Dragging the end PAST the start pins it exactly one
    /// unit after the start (CLAMP, not flip).
    public static func resizedEnd(
        region: LoopRegion, newEndRaw: Double, snap: ClipSnap, beatsPerBar: Int
    ) -> LoopRegion {
        let minLen = minRegionBeats(snap: snap, beatsPerBar: beatsPerBar)
        let snapped = snap.snap(beat: max(0, newEndRaw), beatsPerBar: beatsPerBar)
        let end = max(snapped, region.start + minLen)
        return LoopRegion(start: region.start, end: end)
    }

    // MARK: Move (drag the body)

    /// Move the whole region by a beat delta, PRESERVING its length. Snaps the new
    /// START to the grid and clamps at 0 — a leftward drag past 0 pins the region
    /// at beat 0 with its length intact (never inverts, never goes negative).
    public static func movedRegion(
        region: LoopRegion, dragDeltaBeats: Double, snap: ClipSnap, beatsPerBar: Int
    ) -> LoopRegion {
        let length = region.length
        let newStart = snap.snap(beat: max(0, region.start + dragDeltaBeats), beatsPerBar: beatsPerBar)
        return LoopRegion(start: newStart, end: newStart + length)
    }

    // MARK: Click (toggle vs seek)

    /// Click semantics for a content-space x: inside the region (body OR an edge)
    /// toggles looping; empty ruler seeks to the snapped beat under the pointer.
    /// Reuses the same zone classification the drag routing does, so the click and
    /// the press agree about what's "inside."
    public static func click(
        contentX: CGFloat, region: LoopRegion?, geometry: LoopRulerGeometry,
        snap: ClipSnap, beatsPerBar: Int
    ) -> LoopClickResult {
        switch geometry.classify(contentX: contentX, region: region) {
        case .body, .edgeStart, .edgeEnd:
            return .toggle
        case .empty:
            return .seek(snap.snap(beat: geometry.beat(forX: contentX), beatsPerBar: beatsPerBar))
        }
    }
}
