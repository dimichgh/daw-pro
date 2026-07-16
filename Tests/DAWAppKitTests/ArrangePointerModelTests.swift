import CoreGraphics
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the m17-c arrange pointer layer: the playhead grab
/// zone widths, the clip/empty/controls classification, and the seek/ghost
/// snap math — at MULTIPLE zoom scales and row heights (the m17-b law: every
/// x↔beat conversion derives from the live `pixelsPerBeat`, so the tests pin
/// non-default scales too).
@Suite("ArrangePointer — timeline pointer affordances (m17-c)")
struct ArrangePointerModelTests {

    /// Two rows at rowHeight 34 (M): row 0 plain (a clip at beats 4..<8), row 1
    /// expanded with 64 pt of extras (automation) under its clip band.
    /// Geometry mirrors `TimelineLanesView`: laneSpacing 6, lanes start at 0
    /// (`.lanes` — rulerInset 0).
    private func lanes(rowHeight: CGFloat = 34) -> [ArrangePointerLane] {
        let r0Top: CGFloat = 0
        let r1Top = rowHeight + 6
        return [
            ArrangePointerLane(
                clipTop: r0Top, clipBottom: r0Top + rowHeight, bottom: r0Top + rowHeight,
                clipSpans: [ArrangeClipSpan(startBeat: 4, lengthBeats: 4)]),
            ArrangePointerLane(
                clipTop: r1Top, clipBottom: r1Top + rowHeight, bottom: r1Top + rowHeight + 64,
                clipSpans: []),
        ]
    }

    private func zone(x: CGFloat, y: CGFloat, playheadX: CGFloat = 0,
                      ppb: CGFloat = 16, topInset: CGFloat = 0,
                      rowHeight: CGFloat = 34) -> ArrangePointerZone {
        ArrangePointer.zone(
            x: x, y: y, playheadX: playheadX, pixelsPerBeat: ppb,
            topInset: topInset, contentBottom: 600,
            lanes: lanes(rowHeight: rowHeight), laneSpacing: 6)
    }

    // MARK: - Playhead grab zone

    @Test("playhead grab tolerance is inclusive at both edges, exclusive past them",
          arguments: [CGFloat(16), 56, 200])
    func grabToleranceEdges(ppb: CGFloat) {
        let tol = ArrangePointer.playheadGrabTolerance
        let px: CGFloat = 10 * ppb   // playhead at beat 10, any zoom
        #expect(zone(x: px, y: 10, playheadX: px, ppb: ppb) == .playheadGrab)
        #expect(zone(x: px - tol, y: 10, playheadX: px, ppb: ppb) == .playheadGrab)
        #expect(zone(x: px + tol, y: 10, playheadX: px, ppb: ppb) == .playheadGrab)
        #expect(zone(x: px - tol - 0.5, y: 10, playheadX: px, ppb: ppb) != .playheadGrab)
        #expect(zone(x: px + tol + 0.5, y: 10, playheadX: px, ppb: ppb) != .playheadGrab)
    }

    @Test("playhead grab beats a clip under it (the strip sits above the blocks)")
    func grabBeatsClip() {
        // Playhead at beat 5 — inside row 0's clip [4, 8). ppb 16 → x = 80.
        #expect(zone(x: 80, y: 10, playheadX: 80) == .playheadGrab)
        // One tolerance past it, the clip rules again.
        #expect(zone(x: 80 + ArrangePointer.playheadGrabTolerance + 0.5, y: 10, playheadX: 80) == .clip)
    }

    @Test("extras rows own the pointer even at the playhead x (no grab, no ghost)")
    func extrasOwnThePointer() {
        // Row 1's automation band: y in [clipBottom, bottom) = [74, 138) at M rows.
        #expect(zone(x: 80, y: 80, playheadX: 80) == .laneControls)
        #expect(zone(x: 300, y: 100) == .laneControls)
    }

    @Test("free space below the lanes grabs near the playhead, seeks elsewhere")
    func tailGrabsAndSeeks() {
        // Below row 1's bottom + spacing (138 + 6 = 144 at M rows).
        #expect(zone(x: 80, y: 200, playheadX: 80) == .playheadGrab)
        #expect(zone(x: 300, y: 200, playheadX: 80) == .empty)
    }

    // MARK: - Clip vs empty vs gaps

    @Test("clip bands classify clip-over-span vs empty, zoom-aware",
          arguments: [CGFloat(16), 56])
    func clipBandClassification(ppb: CGFloat) {
        // Row 0's clip spans beats [4, 8): inside at 5, empty at 2 and 9.
        #expect(zone(x: 5 * ppb, y: 10, playheadX: -100, ppb: ppb) == .clip)
        #expect(zone(x: 2 * ppb, y: 10, playheadX: -100, ppb: ppb) == .empty)
        #expect(zone(x: 9 * ppb, y: 10, playheadX: -100, ppb: ppb) == .empty)
        // Span edges: start inclusive, end exclusive.
        #expect(zone(x: 4 * ppb, y: 10, playheadX: -100, ppb: ppb) == .clip)
        #expect(zone(x: 8 * ppb, y: 10, playheadX: -100, ppb: ppb) == .empty)
    }

    @Test("row gaps are empty (seekable) but never playhead-grab — the strip skips them")
    func gapsAreEmptyNeverGrab() {
        // The 6 pt gap after row 0: y in [34, 40) at M rows.
        #expect(zone(x: 300, y: 36) == .empty)
        #expect(zone(x: 80, y: 36, playheadX: 80) == .empty)
    }

    @Test("row heights move the bands (S/L rows classify at their own geometry)",
          arguments: [CGFloat(24), 50])
    func rowHeightAware(rowHeight: CGFloat) {
        // In-band at y = rowHeight - 1; the gap starts at rowHeight.
        #expect(zone(x: 5 * 16, y: rowHeight - 1, playheadX: -100, rowHeight: rowHeight) == .clip)
        #expect(zone(x: 5 * 16, y: rowHeight + 1, playheadX: -100, rowHeight: rowHeight) == .empty)
    }

    @Test("above the top inset and off-content is outside")
    func outsideRegions() {
        #expect(zone(x: 100, y: 40, topInset: 80) == .outside)   // .full ruler strip
        #expect(zone(x: -5, y: 10) == .outside)
        #expect(ArrangePointer.zone(x: 100, y: 700, playheadX: 0, pixelsPerBeat: 16,
                                    topInset: 0, contentBottom: 600,
                                    lanes: lanes(), laneSpacing: 6) == .outside)
    }

    @Test("an empty project classifies grab at the playhead, empty everywhere else")
    func emptyProject() {
        let z = { (x: CGFloat) in
            ArrangePointer.zone(x: x, y: 100, playheadX: 32, pixelsPerBeat: 16,
                                topInset: 0, contentBottom: 600, lanes: [], laneSpacing: 6)
        }
        #expect(z(32) == .playheadGrab)
        #expect(z(300) == .empty)
    }

    // MARK: - Clip pick (staged double-click)

    @Test("clipIndex picks the TOPMOST (last-drawn) clip on overlap; zero-length never hits")
    func clipIndexPick() {
        let spans = [
            ArrangeClipSpan(startBeat: 0, lengthBeats: 8),
            ArrangeClipSpan(startBeat: 4, lengthBeats: 8),   // overlaps 4..<8, drawn later
            ArrangeClipSpan(startBeat: 6, lengthBeats: 0),   // zero-length — inert
        ]
        #expect(ArrangePointer.clipIndex(atBeat: 5, in: spans) == 1)
        #expect(ArrangePointer.clipIndex(atBeat: 2, in: spans) == 0)
        #expect(ArrangePointer.clipIndex(atBeat: 10, in: spans) == 1)
        #expect(ArrangePointer.clipIndex(atBeat: 12.5, in: spans) == nil)
        #expect(ArrangePointer.clipIndex(atBeat: 5, in: []) == nil)
    }

    // MARK: - Seek / ghost snap math

    @Test("beat(forX:) snaps on the arrange grid at any zoom",
          arguments: [CGFloat(16), 56, 200])
    func beatSnapsZoomAware(ppb: CGFloat) {
        let meter = MeterMap(constant: TimeSignature())   // 4/4
        // x just past beat 4.6 snaps to bar 4 on the Bar grid…
        #expect(ArrangePointer.beat(forX: 4.6 * ppb, pixelsPerBeat: ppb,
                                    snap: .bar, meterMap: meter) == 4)
        // …and to 4.5 on the 1/2 grid.
        #expect(ArrangePointer.beat(forX: 4.6 * ppb, pixelsPerBeat: ppb,
                                    snap: .half, meterMap: meter) == 4.5)
    }

    @Test("bar snap follows the meter map (7/8 barlines land every 7 beats)")
    func barSnapFollowsMeter() {
        // The meter model counts a bar in its OWN beat unit: 7/8 = 7 beats/bar,
        // so barlines sit at 0, 7, 14… — not on the 4/4 grid.
        let meter = MeterMap(constant: TimeSignature(beatsPerBar: 7, beatUnit: 8))
        let up = ArrangePointer.beat(forX: 3.6 * 16, pixelsPerBeat: 16,
                                     snap: .bar, meterMap: meter)
        #expect(abs(up - 7) < 1e-9)
        let down = ArrangePointer.beat(forX: 3.4 * 16, pixelsPerBeat: 16,
                                       snap: .bar, meterMap: meter)
        #expect(down == 0)
    }

    @Test("⌥ bypasses the snap (raw beat), and x floors at beat 0")
    func bypassAndFloor() {
        let meter = MeterMap(constant: TimeSignature())
        let raw = ArrangePointer.beat(forX: 4.6 * 16, pixelsPerBeat: 16,
                                      snap: .bar, meterMap: meter, snapBypassed: true)
        #expect(abs(raw - 4.6) < 1e-9)
        #expect(ArrangePointer.beat(forX: -50, pixelsPerBeat: 16,
                                    snap: .off, meterMap: meter) == 0)
        #expect(ArrangePointer.beat(forX: -50, pixelsPerBeat: 16,
                                    snap: .bar, meterMap: meter, snapBypassed: true) == 0)
    }

    // MARK: - Cursor contract

    @Test("only the playhead grab claims a cursor — open hand at rest, closed while scrubbing")
    func cursorContract() {
        #expect(ArrangePointer.cursor(for: .playheadGrab) == .grab)
        #expect(ArrangePointer.cursor(for: .playheadGrab, dragging: true) == .grabbing)
        for z: ArrangePointerZone in [.clip, .laneControls, .empty, .outside] {
            #expect(ArrangePointer.cursor(for: z) == nil)
            #expect(ArrangePointer.cursor(for: z, dragging: true) == nil)
        }
    }

    @Test("zone raw values are the stable seam vocabulary")
    func zoneRawValues() {
        #expect(ArrangePointerZone.playheadGrab.rawValue == "playhead-grab")
        #expect(ArrangePointerZone.laneControls.rawValue == "lane-controls")
        #expect(ArrangePointerZone(rawValue: "empty") == .empty)
        #expect(ArrangePointerZone(rawValue: "bogus") == nil)
    }

    @Test("scrub slop and grab tolerance stay sane (positive, narrow)")
    func constantsSane() {
        #expect(ArrangePointer.playheadGrabTolerance > 0
                && ArrangePointer.playheadGrabTolerance <= 8)
        #expect(ArrangePointer.scrubSlop > 0
                && ArrangePointer.scrubSlop < ArrangePointer.playheadGrabTolerance)
    }
}
