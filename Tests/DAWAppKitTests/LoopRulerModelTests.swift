import CoreGraphics
import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the arrange loop-ruler model (beta m10-g). The SwiftUI
/// view is thin over this — it classifies a ruler point, previews create/resize/
/// move regions, and routes clicks to toggle/seek — so exercising the geometry +
/// edit math here covers the loop surface's logic without a display (the
/// `PianoRollPlayhead` / `ClipEdit` test-suite style).
@Suite("LoopRulerModel — loop region mouse surface (m10-g)")
struct LoopRulerModelTests {

    private let geo = LoopRulerGeometry(pixelsPerBeat: 16, edgeTolerance: 6)

    /// Trivial single-meter map (m13-h) — the byte-equivalence anchor.
    private func meter(_ bpb: Int = 4) -> MeterMap {
        MeterMap(constant: TimeSignature(beatsPerBar: bpb))
    }

    /// 4/4 → 6/8 @ beat 16 (bpb 6, top-number convention): barlines …12,16,22,28…
    private func crossMeter() -> MeterMap {
        try! MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 6, beatUnit: 8),
        ])
    }

    /// The legacy base-meter snap formula, inline (grid rounding, floored at 0).
    private func legacySnap(_ snap: ClipSnap, _ beat: Double, _ bpb: Int) -> Double {
        let grid: Double?
        switch snap {
        case .off: grid = nil
        case .bar: grid = Double(max(1, bpb))
        case .beat: grid = 1
        case .half: grid = 0.5
        case .quarter: grid = 0.25
        case .eighth: grid = 0.125
        case .sixteenth: grid = 0.0625
        }
        guard let g = grid, g > 0 else { return max(0, beat) }
        return max(0, (beat / g).rounded() * g)
    }

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
        let r = LoopEdit.createRegion(anchorBeat: 4.3, currentBeat: 11.6, snap: .bar, meterMap: meter())
        #expect(r == LoopRegion(start: 4, end: 12))
    }

    @Test("createRegion handles a LEFTWARD (right-to-left) drag")
    func createLeftward() {
        // Anchor to the RIGHT of the current pointer — must still order lo…hi.
        let r = LoopEdit.createRegion(anchorBeat: 12, currentBeat: 4, snap: .bar, meterMap: meter())
        #expect(r == LoopRegion(start: 4, end: 12))
        // And unsnapped, leftward.
        let off = LoopEdit.createRegion(anchorBeat: 9.5, currentBeat: 2.25, snap: .off, meterMap: meter())
        #expect(off == LoopRegion(start: 2.25, end: 9.5))
    }

    @Test("createRegion returns nil for a sub-threshold drag (a click)")
    func createSubThreshold() {
        // A drag that stays inside one bar snaps both ends to the SAME grid line → nil.
        #expect(LoopEdit.createRegion(anchorBeat: 4.2, currentBeat: 4.6, snap: .bar, meterMap: meter()) == nil)
        // Snap off: below the absolute floor → nil.
        #expect(LoopEdit.createRegion(anchorBeat: 4.0, currentBeat: 4.1, snap: .off, meterMap: meter()) == nil)
        // Exactly one snap unit is ACCEPTED (the minimum, not rejected).
        #expect(LoopEdit.createRegion(anchorBeat: 4, currentBeat: 8, snap: .bar, meterMap: meter())
                == LoopRegion(start: 4, end: 8))
        // Exactly the absolute floor with snap off is accepted.
        #expect(LoopEdit.createRegion(anchorBeat: 4, currentBeat: 4.25, snap: .off, meterMap: meter())
                == LoopRegion(start: 4, end: 4.25))
    }

    @Test("createRegion respects the meter for a Bar snap (3/4)")
    func createRespectsMeter() {
        // In 3/4 a bar is 3 beats: ~2.4 → ~7.1 snaps to bars 3 and 6.
        let r = LoopEdit.createRegion(anchorBeat: 2.4, currentBeat: 7.1, snap: .bar, meterMap: meter(3))
        #expect(r == LoopRegion(start: 3, end: 6))
    }

    // MARK: - Resize (drag an edge)

    @Test("resizedStart snaps, pins the end, and floors at 0")
    func resizeStartBasic() {
        let region = LoopRegion(start: 4, end: 16)
        // Move the start out to ~7.6 → snaps to 8; end stays 16.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: 7.6, snap: .bar, meterMap: meter())
                == LoopRegion(start: 8, end: 16))
        // A negative raw start floors at beat 0.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: -3, snap: .bar, meterMap: meter())
                == LoopRegion(start: 0, end: 16))
    }

    @Test("resizedStart CLAMPS one snap unit before the end when dragged past it")
    func resizeStartClampsPastEnd() {
        let region = LoopRegion(start: 4, end: 16)   // end at 16, bar = 4
        // Drag the start well past the end (raw 40) → clamped to end - 1 bar = 12.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: 40, snap: .bar, meterMap: meter())
                == LoopRegion(start: 12, end: 16))
    }

    @Test("resizedEnd snaps, pins the start, and clamps past the start")
    func resizeEndBasicAndClamp() {
        let region = LoopRegion(start: 4, end: 16)
        // Pull the end in to ~11.6 → snaps to 12; start stays 4.
        #expect(LoopEdit.resizedEnd(region: region, newEndRaw: 11.6, snap: .bar, meterMap: meter())
                == LoopRegion(start: 4, end: 12))
        // Drag the end past the start (raw 0) → clamped to start + 1 bar = 8.
        #expect(LoopEdit.resizedEnd(region: region, newEndRaw: 0, snap: .bar, meterMap: meter())
                == LoopRegion(start: 4, end: 8))
    }

    @Test("resize keeps at least the absolute floor with snap off")
    func resizeMinLengthOff() {
        let region = LoopRegion(start: 4, end: 16)
        // End dragged to just above the start, snap off → clamped to start + 0.25.
        #expect(LoopEdit.resizedEnd(region: region, newEndRaw: 4.05, snap: .off, meterMap: meter())
                == LoopRegion(start: 4, end: 4.25))
        // Start dragged to just below the end, snap off → clamped to end - 0.25.
        #expect(LoopEdit.resizedStart(region: region, newStartRaw: 15.95, snap: .off, meterMap: meter())
                == LoopRegion(start: 15.75, end: 16))
    }

    // MARK: - Move (drag the body)

    @Test("movedRegion preserves length and snaps the start")
    func moveBasic() {
        let region = LoopRegion(start: 4, end: 12)   // length 8
        // Shift right by ~3.6 beats → start snaps 4→8 (bar), length preserved.
        let r = LoopEdit.movedRegion(region: region, dragDeltaBeats: 3.6, snap: .bar, meterMap: meter())
        #expect(r == LoopRegion(start: 8, end: 16))
        #expect(r.length == region.length)
    }

    @Test("movedRegion clamps at beat 0 keeping length (no negative, no invert)")
    func moveClampsAtZero() {
        let region = LoopRegion(start: 4, end: 12)   // length 8
        // Shove far left → start pins at 0, length 8 intact.
        let r = LoopEdit.movedRegion(region: region, dragDeltaBeats: -100, snap: .bar, meterMap: meter())
        #expect(r == LoopRegion(start: 0, end: 8))
        #expect(r.start >= 0)
        #expect(r.end > r.start)
    }

    @Test("movedRegion with snap off shifts freely, still floored at 0")
    func moveOff() {
        let region = LoopRegion(start: 4, end: 10)   // length 6
        #expect(LoopEdit.movedRegion(region: region, dragDeltaBeats: 1.3, snap: .off, meterMap: meter())
                == LoopRegion(start: 5.3, end: 11.3))
        #expect(LoopEdit.movedRegion(region: region, dragDeltaBeats: -5, snap: .off, meterMap: meter())
                == LoopRegion(start: 0, end: 6))
    }

    // MARK: - Click semantics (toggle vs seek)

    @Test("click inside the region (body or edge) toggles")
    func clickInsideToggles() {
        let region = LoopRegion(start: 4, end: 12)   // x 64…192
        #expect(LoopEdit.click(contentX: 120, region: region, geometry: geo, snap: .bar, meterMap: meter()) == .toggle)
        #expect(LoopEdit.click(contentX: 64, region: region, geometry: geo, snap: .bar, meterMap: meter()) == .toggle)
        #expect(LoopEdit.click(contentX: 192, region: region, geometry: geo, snap: .bar, meterMap: meter()) == .toggle)
    }

    @Test("click outside the region seeks to the snapped beat")
    func clickOutsideSeeks() {
        let region = LoopRegion(start: 4, end: 12)
        // x 300 → beat 18.75, snap Bar → 20.
        #expect(LoopEdit.click(contentX: 300, region: region, geometry: geo, snap: .bar, meterMap: meter())
                == .seek(20))
        // No region at all → the whole ruler seeks. x 40 → beat 2.5, snap Bar → 4.
        #expect(LoopEdit.click(contentX: 40, region: nil, geometry: geo, snap: .bar, meterMap: meter())
                == .seek(4))
        // Snap off → the raw beat under the pointer. x 40 → beat 2.5.
        #expect(LoopEdit.click(contentX: 40, region: nil, geometry: geo, snap: .off, meterMap: meter())
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

    @Test("minRegionBeats is one grid unit when snapping, else the floor (trivial map)")
    func minRegionHelper() {
        #expect(LoopEdit.minRegionBeats(snap: .bar, meterMap: meter(4), atBeat: 8) == 4)
        #expect(LoopEdit.minRegionBeats(snap: .bar, meterMap: meter(3), atBeat: 8) == 3)
        #expect(LoopEdit.minRegionBeats(snap: .beat, meterMap: meter(4), atBeat: 8) == 1)
        #expect(LoopEdit.minRegionBeats(snap: .quarter, meterMap: meter(4), atBeat: 8) == 0.25)
        #expect(LoopEdit.minRegionBeats(snap: .off, meterMap: meter(4), atBeat: 8) == LoopEdit.minLoopLengthBeats)
    }

    @Test("minRegionBeats .bar tracks the BAR at atBeat across a meter change")
    func minRegionCrossBoundary() {
        let m = crossMeter()   // 4/4 (bar=4) then 6/8 (bar=6) @ beat 16
        // A beat in the 4/4 region → a 4-beat bar.
        #expect(LoopEdit.minRegionBeats(snap: .bar, meterMap: m, atBeat: 8) == 4)
        // A beat in the 6/8 region → a 6-beat bar (position-dependent).
        #expect(LoopEdit.minRegionBeats(snap: .bar, meterMap: m, atBeat: 19) == 6)
        // Right AT the boundary belongs to the new (6/8) bar [16,22).
        #expect(LoopEdit.minRegionBeats(snap: .bar, meterMap: m, atBeat: 16) == 6)
        // The finer grids stay meter-agnostic on both sides.
        #expect(LoopEdit.minRegionBeats(snap: .beat, meterMap: m, atBeat: 19) == 1)
        #expect(LoopEdit.minRegionBeats(snap: .quarter, meterMap: m, atBeat: 19) == 0.25)
    }

    // MARK: - Cross-boundary snap (m13-h)

    @Test("loop create/resize/move/click .bar snap routes through nearestBarline on both sides")
    func loopBarSnapCrossBoundary() {
        let m = crossMeter()   // barlines …12,16,22,28…
        // CREATE spanning the boundary: raw 15 (→16) to raw 21 (→22), a one-6/8-bar loop.
        #expect(LoopEdit.createRegion(anchorBeat: 15, currentBeat: 21, snap: .bar, meterMap: m)
                == LoopRegion(start: 16, end: 22))
        // CREATE fully inside 6/8: raw 20 (→22) to raw 27 (→28).
        #expect(LoopEdit.createRegion(anchorBeat: 20, currentBeat: 27, snap: .bar, meterMap: m)
                == LoopRegion(start: 22, end: 28))
        // RESIZE START into 6/8: end pinned at 28; raw start 21 → 22.
        #expect(LoopEdit.resizedStart(region: LoopRegion(start: 16, end: 28),
                                      newStartRaw: 21, snap: .bar, meterMap: m)
                == LoopRegion(start: 22, end: 28))
        // RESIZE END into 6/8: start pinned at 16; raw end 21 → 22 (nearest of 16/22).
        #expect(LoopEdit.resizedEnd(region: LoopRegion(start: 16, end: 28),
                                    newEndRaw: 21, snap: .bar, meterMap: m)
                == LoopRegion(start: 16, end: 22))
        // RESIZE END dragged below the pinned 6/8 start clamps to start + one 6/8 bar.
        #expect(LoopEdit.resizedEnd(region: LoopRegion(start: 16, end: 28),
                                    newEndRaw: 16.5, snap: .bar, meterMap: m)
                == LoopRegion(start: 16, end: 22))
        // MOVE a 4/4-region loop across the boundary: start snaps on the 6/8 grid,
        // length preserved (8 beats). start raw 4+16=20 → 22.
        #expect(LoopEdit.movedRegion(region: LoopRegion(start: 4, end: 12),
                                     dragDeltaBeats: 16, snap: .bar, meterMap: m)
                == LoopRegion(start: 22, end: 30))
        // CLICK empty ruler deep in 6/8: x for beat 20 → snaps to 6/8 barline 22.
        #expect(LoopEdit.click(contentX: geo.x(forBeat: 20), region: nil,
                               geometry: geo, snap: .bar, meterMap: m) == .seek(22))
        // CLICK just left of the boundary (4/4) → the shared barline 16.
        #expect(LoopEdit.click(contentX: geo.x(forBeat: 15), region: nil,
                               geometry: geo, snap: .bar, meterMap: m) == .seek(16))
    }

    @Test("trivial single-meter map reproduces the legacy snap for loop move/click")
    func loopTrivialMapMatchesLegacy() {
        for bpb in [3, 4, 5, 6, 7] {
            let m = meter(bpb)
            var beat = 0.0
            while beat <= 40 {
                for snap in ClipSnap.allCases {
                    let expected = legacySnap(snap, beat, bpb)
                    // MOVE: region start 0 so the delta is the raw beat.
                    let moved = LoopEdit.movedRegion(region: LoopRegion(start: 0, end: 4),
                                                     dragDeltaBeats: beat, snap: snap, meterMap: m)
                    #expect(moved.start == expected, "loop move bpb=\(bpb) snap=\(snap) beat=\(beat)")
                }
                beat += 0.1
            }
        }
    }
}
