import CoreGraphics
import Foundation
import DAWCore

/// Direct-manipulation session-marker lane on the arrange ruler (m11-c). Session
/// markers (`DAWCore.Marker`) are named song-section anchors; the wire commands
/// `marker.add/remove/rename/move` and `transport.seek` already persist and drive
/// them. This namespace is the pure geometry + edit math for the MOUSE surface:
/// map a marker to its flag x, hit-test a press to a marker, snap a drag to a new
/// beat, and snap an "add here" point — so the SwiftUI marker lane stays thin and
/// every pin (beat↔x, hit-test grab width, snapped move/add, clamp ≥ 0) unit-tests
/// headless (the `LoopRulerModel` / `ClipEdit` precedent).
///
/// Rename commit rules are NOT duplicated here — the marker lane reuses the SAME
/// `TrackRename.committedName` idiom the track-header rename uses (trim / empty-
/// cancel / unchanged-no-op), so there is one tested source of truth for "what a
/// name edit commits."

// MARK: - Geometry

/// Beat↔x mapping and flag hit-classification for the arrange marker lane, aligned
/// to the timeline's fixed pixels-per-beat so a flag lines up with the grid. A
/// value type carrying only geometry — pure, `Equatable`, headless-testable (the
/// `LoopRulerGeometry` precedent). Coordinates are CONTENT-space x (x = 0 at the
/// timeline origin, `beat · pixelsPerBeat` elsewhere).
public struct MarkerLaneGeometry: Sendable, Equatable {
    /// Horizontal scale — matches `TimelineLanesView.pixelsPerBeat`.
    public var pixelsPerBeat: CGFloat
    /// Grab strip (points) around a flag's anchor x within which a press lands on
    /// that flag. A generous strip (the flag's chip is wider than a hairline) so a
    /// marker is easy to grab without stealing the whole ruler.
    public var grabWidth: CGFloat

    public init(pixelsPerBeat: CGFloat = 16, grabWidth: CGFloat = 16) {
        self.pixelsPerBeat = pixelsPerBeat
        self.grabWidth = grabWidth
    }

    /// Content-space x for a marker beat.
    public func x(forBeat beat: Double) -> CGFloat { CGFloat(beat) * pixelsPerBeat }

    /// Project beat at a content x, floored at 0.
    public func beat(forX x: CGFloat) -> Double { max(0, Double(x / pixelsPerBeat)) }

    /// The marker (by id) whose flag anchor is nearest `contentX` AND within half
    /// the grab width, or nil when the press is empty ruler. The NEAREST wins when
    /// two flags overlap (stacked markers at nearby beats), so a press always grabs
    /// the closest one deterministically.
    public func markerID(atContentX contentX: CGFloat, markers: [Marker]) -> UUID? {
        var best: (id: UUID, distance: CGFloat)?
        for marker in markers {
            let d = abs(contentX - x(forBeat: marker.beat))
            guard d <= grabWidth / 2 else { continue }
            if best == nil || d < best!.distance { best = (marker.id, d) }
        }
        return best?.id
    }
}

// MARK: - Edit math

/// Pure marker edit math for the arrange lane gesture layer: a snapped moved beat
/// and a snapped "add here" beat. Both enforce the model's `beat ≥ 0` clamp so an
/// on-screen preview never disagrees with what `ProjectStore.moveMarker`/
/// `addMarker` will persist. Static, value-in/value-out — the view is thin over
/// these (the `LoopEdit` precedent).
public enum MarkerLaneEdit {
    /// Snapped new beat for a marker dragged by `dragDeltaBeats` from `originBeat`.
    /// Snaps to the effective grid (Bar in Simple, the picked snap in Pro — the
    /// caller passes the already-resolved `ClipSnap`) and clamps at 0, so a
    /// leftward drag past the start pins the flag at beat 0 (never negative).
    public static func movedBeat(
        originBeat: Double, dragDeltaBeats: Double, snap: ClipSnap, beatsPerBar: Int
    ) -> Double {
        snap.snap(beat: max(0, originBeat + dragDeltaBeats), beatsPerBar: beatsPerBar)
    }

    /// Snapped beat for an "Add Marker Here" at content x — the same snap the drag
    /// uses, so the flag lands on the grid the ruler shows.
    public static func addBeat(
        atContentX contentX: CGFloat, geometry: MarkerLaneGeometry, snap: ClipSnap, beatsPerBar: Int
    ) -> Double {
        snap.snap(beat: geometry.beat(forX: contentX), beatsPerBar: beatsPerBar)
    }
}
