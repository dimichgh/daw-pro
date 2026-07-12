import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for the arrange loop-ruler model (beta m10-g). The SwiftUI
/// view is thin over this — it classifies a ruler point, previews create/resize/
/// move regions, and routes clicks to toggle/seek — so exercising the geometry +
/// edit math here covers the loop surface's logic without a display (the
/// `PianoRollPlayhead` / `ClipEdit` test-suite style).
@Suite("LoopRulerModel — loop region mouse surface (m10-g)")
struct LoopRulerModelTests {

    private let geo = LoopRulerGeometry(pixelsPerBeat: 16, edgeTolerance: 6)

    // MARK: - Geometry mapping

    @Test("beat↔x round-trip at the timeline scale, x floored at 0")
    func beatXMapping() {
        #expect(geo.x(forBeat: 4) == 64)
        #expect(geo.beat(forX: 64) == 4)
        // Negative content x floors at beat 0 (never a negative beat).
        #expect(geo.beat(forX: -32) == 0)
    }

    // MARK: - Zone classification

    @Test("classify: nil region makes the whole ruler empty")
    func classifyNilRegion() {
        #expect(geo.classify(contentX: 0, region: nil) == .empty)
        #expect(geo.classify(contentX: 500, region: nil) == .empty)
    }

    @Test("classify: edges within tolerance, body between, empty outside")
    func classifyZones() {
        let region = LoopRegion(start: 4, end: 12)   // x 64…192
        // Exact edges.
        #expect(geo.classify(contentX: 64, region: region) == .edgeStart)
        #expect(geo.classify(contentX: 192, region: region) == .edgeEnd)
        // Within the 6 pt tolerance of an edge → that edge (grab from just outside too).
        #expect(geo.classify(contentX: 69, region: region) == .edgeStart)   // dStart 5
        #expect(geo.classify(contentX: 60, region: region) == .edgeStart)   // 4 pt left of start
        #expect(geo.classify(contentX: 188, region: region) == .edgeEnd)
        // Body between the edges (past both tolerances).
        #expect(geo.classify(contentX: 120, region: region) == .body)
        #expect(geo.classify(contentX: 71, region: region) == .body)        // dStart 7 > tol
        // Outside the region entirely.
        #expect(geo.classify(contentX: 10, region: region) == .empty)
        #expect(geo.classify(contentX: 300, region: region) == .empty)
    }

    @Test("classify: on a very short region the NEARER edge wins")
    func classifyShortRegionNearestEdge() {
        let region = LoopRegion(start: 4, end: 4.5)   // x 64…72, both within tol of the middle
        #expect(geo.classify(contentX: 65, region: region) == .edgeStart)   // dStart 1 < dEnd 7
        #expect(geo.classify(contentX: 71, region: region) == .edgeEnd)     // dEnd 1 < dStart 7
        #expect(geo.classify(contentX: 68, region: region) == .edgeStart)   // tie → start
    }

    // MARK: - Create (sketch a region)

    @Test("createRegion snaps both ends and orders a rightward drag")
    func createRightward() {
        // Drag from beat ~4.3 to ~11.6, snap to Bar (4 beats): 4 → 12.
        let r = LoopEdit.createRegion(anchorBeat: 4.3, currentBeat: 11.6, snap: .bar, beatsPerBar: 4)
        #expect(r == LoopRegion(start: 4, end: 12))
    }

    @Test("createRegion handles a LEFTWARD (right-to-left) drag")
    func createLeftward() {
        // Anchor to the RIGHT of the current pointer — must still order lo…hi.
        let r = LoopEdit.createRegion(anchorBeat: 12, currentBeat: 4, snap: .bar, beatsPerBar: 4)
        #expect(r == LoopRegion(start: 4, end: 12))
        // And unsnapped, leftward.
        let off = LoopEdit.createRegion(anchorBeat: 9.5, currentBeat: 2.25, snap: .off, beatsPerBar: 4)
        #expect(off == LoopRegion(start: 2.25, end: 9.5))
    }

    @Test("createRegion returns nil for a sub-threshold drag (a click)")
    func createSubThreshold() {
        // A drag that stays inside one bar snaps both ends to the SAME grid line → nil.
        #expect(LoopEdit.createRegion(anchorBeat: 4.2, currentBeat: 4.6, snap: .bar, beatsPerBar: 4) == nil)
        // Snap off: below the absolute floor → nil.
        #expect(LoopEdit.createRegion(anchorBeat: 4.0, currentBeat: 4.1, snap: .off, beatsPerBar: 4) == nil)
        // Exactly one snap unit is ACCEPTED (the minimum, not rejected).
        #expect(LoopEdit.createRegion(anchorBeat: 4, currentBeat: 8, snap: .bar, beatsPerBar: 4)
                == LoopRegion(start: 4, end: 8))
        // Exactly the absolute floor with snap off is accepted.
        #expect(LoopEdit.createRegion(anchorBeat: 4, currentBeat: 4.25, snap: .off, beatsPerBar: 4)
                == LoopRegion(start: 4, end: 4.25))
    }

    @Test("createRegion respects the meter for a Bar snap (3/4)")
    func createRespectsMeter() {
        // In 3/4 a bar is 3 beats: ~2.4 → ~7.1 snaps to bars 3 and 6.
        let r = LoopEdit.createRegion(anchorBeat: 2.4, currentBeat: 7.1, snap: .bar, beatsPerBar: 3)
        #expect(r == LoopRegion(start: 3, end: 6))
    }

    // MARK: - Resize (drag an edge)

    @Test("resizedStart snaps, pins the end, and floors at 0")
    func resizeStartBasic() {
        let region = LoopRegion(start: 4, end: 16)
        // Move the start out to ~7.6 → snaps to 8; end stays 16.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: 7.6, snap: .bar, beatsPerBar: 4)
                == LoopRegion(start: 8, end: 16))
        // A negative raw start floors at beat 0.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: -3, snap: .bar, beatsPerBar: 4)
                == LoopRegion(start: 0, end: 16))
    }

    @Test("resizedStart CLAMPS one snap unit before the end when dragged past it")
    func resizeStartClampsPastEnd() {
        let region = LoopRegion(start: 4, end: 16)   // end at 16, bar = 4
        // Drag the start well past the end (raw 40) → clamped to end - 1 bar = 12.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: 40, snap: .bar, beatsPerBar: 4)
                == LoopRegion(start: 12, end: 16))
    }

    @Test("resizedEnd snaps, pins the start, and clamps past the start")
    func resizeEndBasicAndClamp() {
        let region = LoopRegion(start: 4, end: 16)
        // Pull the end in to ~11.6 → snaps to 12; start stays 4.
        #expect(LoopEdit.resizedEnd(region: region, newEndRaw: 11.6, snap: .bar, beatsPerBar: 4)
                == LoopRegion(start: 4, end: 12))
        // Drag the end past the start (raw 0) → clamped to start + 1 bar = 8.
        #expect(LoopEdit.resizedEnd(region: region, newEndRaw: 0, snap: .bar, beatsPerBar: 4)
                == LoopRegion(start: 4, end: 8))
    }

    @Test("resize keeps at least the absolute floor with snap off")
    func resizeMinLengthOff() {
        let region = LoopRegion(start: 4, end: 16)
        // End dragged to just above the start, snap off → clamped to start + 0.25.
        #expect(LoopEdit.resizedEnd(region: region, newEndRaw: 4.05, snap: .off, beatsPerBar: 4)
                == LoopRegion(start: 4, end: 4.25))
        // Start dragged to just below the end, snap off → clamped to end - 0.25.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: 15.95, snap: .off, beatsPerBar: 4)
                == LoopRegion(start: 15.75, end: 16))
    }

    // MARK: - Move (drag the body)

    @Test("movedRegion preserves length and snaps the start")
    func moveBasic() {
        let region = LoopRegion(start: 4, end: 12)   // length 8
        // Shift right by ~3.6 beats → start snaps 4→8 (bar), length preserved.
        let r = LoopEdit.movedRegion(region: region, dragDeltaBeats: 3.6, snap: .bar, beatsPerBar: 4)
        #expect(r == LoopRegion(start: 8, end: 16))
        #expect(r.length == region.length)
    }

    @Test("movedRegion clamps at beat 0 keeping length (no negative, no invert)")
    func moveClampsAtZero() {
        let region = LoopRegion(start: 4, end: 12)   // length 8
        // Shove far left → start pins at 0, length 8 intact.
        let r = LoopEdit.movedRegion(region: region, dragDeltaBeats: -100, snap: .bar, beatsPerBar: 4)
        #expect(r == LoopRegion(start: 0, end: 8))
        #expect(r.start >= 0)
        #expect(r.end > r.start)
    }

    @Test("movedRegion with snap off shifts freely, still floored at 0")
    func moveOff() {
        let region = LoopRegion(start: 4, end: 10)   // length 6
        #expect(LoopEdit.movedRegion(region: region, dragDeltaBeats: 1.3, snap: .off, beatsPerBar: 4)
                == LoopRegion(start: 5.3, end: 11.3))
        #expect(LoopEdit.movedRegion(region: region, dragDeltaBeats: -5, snap: .off, beatsPerBar: 4)
                == LoopRegion(start: 0, end: 6))
    }

    // MARK: - Click semantics (toggle vs seek)

    @Test("click inside the region (body or edge) toggles")
    func clickInsideToggles() {
        let region = LoopRegion(start: 4, end: 12)   // x 64…192
        #expect(LoopEdit.click(contentX: 120, region: region, geometry: geo, snap: .bar, beatsPerBar: 4) == .toggle)
        #expect(LoopEdit.click(contentX: 64, region: region, geometry: geo, snap: .bar, beatsPerBar: 4) == .toggle)
        #expect(LoopEdit.click(contentX: 192, region: region, geometry: geo, snap: .bar, beatsPerBar: 4) == .toggle)
    }

    @Test("click outside the region seeks to the snapped beat")
    func clickOutsideSeeks() {
        let region = LoopRegion(start: 4, end: 12)
        // x 300 → beat 18.75, snap Bar → 20.
        #expect(LoopEdit.click(contentX: 300, region: region, geometry: geo, snap: .bar, beatsPerBar: 4)
                == .seek(20))
        // No region at all → the whole ruler seeks. x 40 → beat 2.5, snap Bar → 4.
        #expect(LoopEdit.click(contentX: 40, region: nil, geometry: geo, snap: .bar, beatsPerBar: 4)
                == .seek(4))
        // Snap off → the raw beat under the pointer. x 40 → beat 2.5.
        #expect(LoopEdit.click(contentX: 40, region: nil, geometry: geo, snap: .off, beatsPerBar: 4)
                == .seek(2.5))
    }

    // MARK: - Cursor mapping (mirrors the geometry classifier)

    @Test("loop zones map: edges resize, body grabs then grabbing, empty resizes")
    func loopZoneCursors() {
        #expect(CursorAffordance.forLoopZone(.edgeStart) == .resizeLeftRight)
        #expect(CursorAffordance.forLoopZone(.edgeEnd) == .resizeLeftRight)
        #expect(CursorAffordance.forLoopZone(.body) == .grab)
        #expect(CursorAffordance.forLoopZone(.body, dragging: true) == .grabbing)
        #expect(CursorAffordance.forLoopZone(.empty) == .resizeLeftRight)
        // Edges hold their resize through a drag (a value edge never grabs).
        #expect(CursorAffordance.forLoopZone(.edgeStart, dragging: true) == .resizeLeftRight)
    }

    // MARK: - Min-region helper

    @Test("minRegionBeats is one grid unit when snapping, else the floor")
    func minRegionHelper() {
        #expect(LoopEdit.minRegionBeats(snap: .bar, beatsPerBar: 4) == 4)
        #expect(LoopEdit.minRegionBeats(snap: .bar, beatsPerBar: 3) == 3)
        #expect(LoopEdit.minRegionBeats(snap: .beat, beatsPerBar: 4) == 1)
        #expect(LoopEdit.minRegionBeats(snap: .quarter, beatsPerBar: 4) == 0.25)
        #expect(LoopEdit.minRegionBeats(snap: .off, beatsPerBar: 4) == LoopEdit.minLoopLengthBeats)
    }
}
