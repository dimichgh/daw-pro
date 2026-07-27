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

/// The m23-e empty-lane double-click decisions: WHICH lane a double-click names
/// (if any) and HOW LONG the clip it creates may be. Both are pure so the
/// beginner's "new track → writable grid" path is pinned without AppKit.
@Suite("ArrangePointer — empty-lane MIDI clip create (m23-e)")
struct ArrangeCreateClipTests {

    /// Row 0 plain, row 1 expanded with 64 pt of extras (the m17-c fixture):
    /// clip bands [0, 34) and [40, 74), extras [74, 138).
    private func lanes(rowHeight: CGFloat = 34) -> [ArrangePointerLane] {
        let r1Top = rowHeight + 6
        return [
            ArrangePointerLane(clipTop: 0, clipBottom: rowHeight, bottom: rowHeight),
            ArrangePointerLane(clipTop: r1Top, clipBottom: r1Top + rowHeight,
                               bottom: r1Top + rowHeight + 64),
        ]
    }

    // MARK: - Lane resolution

    @Test("clipLaneIndex names the row whose CLIP BAND holds y")
    func laneBands() {
        let l = lanes()
        #expect(ArrangePointer.clipLaneIndex(atY: 0, in: l) == 0)
        #expect(ArrangePointer.clipLaneIndex(atY: 33.9, in: l) == 0)
        #expect(ArrangePointer.clipLaneIndex(atY: 40, in: l) == 1)
        #expect(ArrangePointer.clipLaneIndex(atY: 73.9, in: l) == 1)
    }

    @Test("no lane in the row gap, in a row's extras, or below the stack")
    func nonLaneBands() {
        let l = lanes()
        #expect(ArrangePointer.clipLaneIndex(atY: 36, in: l) == nil)    // 6 pt gap
        #expect(ArrangePointer.clipLaneIndex(atY: 100, in: l) == nil)   // automation editor
        #expect(ArrangePointer.clipLaneIndex(atY: 400, in: l) == nil)   // free space below
        #expect(ArrangePointer.clipLaneIndex(atY: -5, in: l) == nil)
        #expect(ArrangePointer.clipLaneIndex(atY: 10, in: []) == nil)   // empty project
    }

    @Test("lane resolution follows the live row height (S/L rows)",
          arguments: [CGFloat(24), 34, 50])
    func laneBandsFollowRowHeight(rowHeight: CGFloat) {
        let l = lanes(rowHeight: rowHeight)
        #expect(ArrangePointer.clipLaneIndex(atY: rowHeight - 0.5, in: l) == 0)
        #expect(ArrangePointer.clipLaneIndex(atY: rowHeight + 0.5, in: l) == nil)
        #expect(ArrangePointer.clipLaneIndex(atY: rowHeight + 6, in: l) == 1)
    }

    /// The create must NOT inherit `zone`'s playhead-grab precedence: empty lane
    /// space within the grab tolerance classifies `.playheadGrab`, so a zone
    /// guard would refuse a create at exactly the beat a preceding single tap
    /// had just seeked to — while the staged path (which never seeks) passed.
    @Test("lane resolution is independent of the playhead, unlike zone()")
    func independentOfPlayhead() {
        let l = lanes()
        let x: CGFloat = 5 * 16
        #expect(ArrangePointer.zone(x: x, y: 10, playheadX: x, pixelsPerBeat: 16,
                                    topInset: 0, contentBottom: 600,
                                    lanes: l, laneSpacing: 6) == .playheadGrab)
        #expect(ArrangePointer.clipLaneIndex(atY: 10, in: l) == 0)
        #expect(ArrangePointer.createClipLength(startBeat: 5, beatsPerBar: 4, spans: []) == 4)
    }

    // MARK: - Length policy

    @Test("an empty lane yields one BAR of the governing meter, not a hardcoded 4",
          arguments: [2, 3, 4, 5, 7])
    func oneBarOfTheMeter(bpb: Int) {
        #expect(ArrangePointer.createClipLength(
            startBeat: 8, beatsPerBar: bpb, spans: []) == Double(bpb))
    }

    @Test("a degenerate meter still yields a positive length")
    func degenerateMeter() {
        #expect(ArrangePointer.createClipLength(startBeat: 0, beatsPerBar: 0, spans: []) == 1)
        #expect(ArrangePointer.createClipLength(startBeat: 0, beatsPerBar: -3, spans: []) == 1)
    }

    /// The clamp is not cosmetic: `addMIDIClip` lands through the no-silent-
    /// overlap choke point with the NEW clip active, so an unclamped bar reaching
    /// over a resident would TRIM the resident's notes away — silent data loss
    /// from a double-click on empty space.
    @Test("the bar is clamped to the gap before the next clip")
    func clampedToGap() {
        let spans = [ArrangeClipSpan(startBeat: 6, lengthBeats: 4)]
        #expect(ArrangePointer.createClipLength(startBeat: 4, beatsPerBar: 4, spans: spans) == 2)
        // A gap wider than a bar keeps the full bar.
        #expect(ArrangePointer.createClipLength(startBeat: 0, beatsPerBar: 4, spans: spans) == 4)
        // Past the resident there is nothing to clamp against.
        #expect(ArrangePointer.createClipLength(startBeat: 12, beatsPerBar: 4, spans: spans) == 4)
    }

    @Test("only clips STARTING after the point clamp it — an earlier one is irrelevant")
    func clampIgnoresEarlierClips() {
        let spans = [
            ArrangeClipSpan(startBeat: 0, lengthBeats: 4),
            ArrangeClipSpan(startBeat: 16, lengthBeats: 4),
        ]
        #expect(ArrangePointer.createClipLength(startBeat: 8, beatsPerBar: 4, spans: spans) == 4)
        #expect(ArrangePointer.createClipLength(startBeat: 14, beatsPerBar: 4, spans: spans) == 2)
    }

    @Test("zero-length spans never clamp (they are inert everywhere else too)")
    func zeroLengthSpansInert() {
        let spans = [ArrangeClipSpan(startBeat: 5, lengthBeats: 0)]
        #expect(ArrangePointer.createClipLength(startBeat: 4, beatsPerBar: 4, spans: spans) == 4)
    }

    /// The SNAP can land the start beat inside a clip even though the raw
    /// pointer was over empty space (hovering just left of a clip that starts on
    /// the barline). Creating there would trim the resident — so: create nothing.
    @Test("a start beat at or inside a resident yields nil (create nothing)")
    func noRoomInsideResident() {
        let spans = [ArrangeClipSpan(startBeat: 4, lengthBeats: 4)]
        #expect(ArrangePointer.createClipLength(startBeat: 4, beatsPerBar: 4, spans: spans) == nil)
        #expect(ArrangePointer.createClipLength(startBeat: 6, beatsPerBar: 4, spans: spans) == nil)
        // The end beat is exclusive — the clip's own end is free space again.
        #expect(ArrangePointer.createClipLength(startBeat: 8, beatsPerBar: 4, spans: spans) == 4)
    }

    @Test("back-to-back residents leave no room between them")
    func noRoomBetweenAbuttingClips() {
        let spans = [
            ArrangeClipSpan(startBeat: 0, lengthBeats: 4),
            ArrangeClipSpan(startBeat: 4, lengthBeats: 4),
        ]
        #expect(ArrangePointer.createClipLength(startBeat: 4, beatsPerBar: 4, spans: spans) == nil)
    }

    @Test("every length the policy returns is strictly positive")
    func lengthsAlwaysPositive() {
        let spans = [ArrangeClipSpan(startBeat: 3.25, lengthBeats: 2)]
        for start in stride(from: 0.0, through: 3.0, by: 0.25) {
            let length = ArrangePointer.createClipLength(
                startBeat: start, beatsPerBar: 4, spans: spans)
            #expect(length == nil || length! > 0)
        }
    }
}
