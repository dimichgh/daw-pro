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

/// m25-f-4 — WHICH lane a right-click on EMPTY LANE SPACE names for a paste.
///
/// The gesture itself is unreachable from any test in this tree (nothing here
/// can right-click, and `DAWApp` has no test target), so what is pinned is the
/// decidable half: the composition `emptyLaneIndex` performs, including the two
/// traps that would make the menu lie — the playhead grab tolerance, and a
/// point over a clip.
@Suite("ArrangePointer — empty-lane paste target (m25-f-4)")
struct ArrangeEmptyLanePasteTargetTests {

    /// The m23-e fixture, verbatim: row 0 plain, row 1 expanded with 64 pt of
    /// extras. Clip bands [0, 34) and [40, 74), extras [74, 138).
    private func lanes(spans0: [ArrangeClipSpan] = [],
                       spans1: [ArrangeClipSpan] = []) -> [ArrangePointerLane] {
        let r1Top: CGFloat = 40
        return [
            ArrangePointerLane(clipTop: 0, clipBottom: 34, bottom: 34, clipSpans: spans0),
            ArrangePointerLane(clipTop: r1Top, clipBottom: r1Top + 34,
                               bottom: r1Top + 34 + 64, clipSpans: spans1),
        ]
    }

    @Test("an empty stretch of a clip band names its row")
    func emptyStretchNamesItsRow() {
        let l = lanes(spans0: [ArrangeClipSpan(startBeat: 0, lengthBeats: 4)])
        #expect(ArrangePointer.emptyLaneIndex(atY: 10, beatRaw: 8, in: l) == 0)
        #expect(ArrangePointer.emptyLaneIndex(atY: 50, beatRaw: 2, in: l) == 1)
    }

    @Test("a point OVER a clip names no paste target — the clip's own menu owns it")
    func overAClipIsNoTarget() {
        let l = lanes(spans0: [ArrangeClipSpan(startBeat: 4, lengthBeats: 4)])
        #expect(ArrangePointer.emptyLaneIndex(atY: 10, beatRaw: 4, in: l) == nil)
        #expect(ArrangePointer.emptyLaneIndex(atY: 10, beatRaw: 7.9, in: l) == nil)
        // Half-open: the beat a resident ENDS on is empty again.
        #expect(ArrangePointer.emptyLaneIndex(atY: 10, beatRaw: 8, in: l) == 0)
    }

    @Test("a clip on ANOTHER row does not block this row's target")
    func residentsAreReadPerRow() {
        // The negative control for the test above: the same beat that is refused
        // on row 0 must resolve on row 1, so the nil there is the CLIP and not
        // some geometry mistake that refuses everything.
        let l = lanes(spans0: [ArrangeClipSpan(startBeat: 4, lengthBeats: 4)])
        #expect(ArrangePointer.emptyLaneIndex(atY: 10, beatRaw: 5, in: l) == nil)
        #expect(ArrangePointer.emptyLaneIndex(atY: 50, beatRaw: 5, in: l) == 1)
    }

    @Test("the row gap, a row's extras, below the stack and an empty project name nothing")
    func nonLaneBandsNameNothing() {
        let l = lanes()
        #expect(ArrangePointer.emptyLaneIndex(atY: 36, beatRaw: 1, in: l) == nil)   // 6 pt gap
        #expect(ArrangePointer.emptyLaneIndex(atY: 100, beatRaw: 1, in: l) == nil)  // extras
        #expect(ArrangePointer.emptyLaneIndex(atY: 400, beatRaw: 1, in: l) == nil)  // below
        #expect(ArrangePointer.emptyLaneIndex(atY: 10, beatRaw: 1, in: []) == nil)  // no tracks
    }

    /// ⚠️ THE TRAP THE ADVISOR NAMED, AND THE ONE THIS FUNCTION EXISTS FOR.
    /// `zone(...)` checks the playhead grab tolerance BEFORE the clip lookup, so
    /// empty space within 4 pt of the playhead reads `.playheadGrab`. A user
    /// clicks empty space — which SEEKS the playhead onto that point — then
    /// right-clicks there. Under a zone guard the menu would find no target on
    /// exactly the spot they had just pointed at.
    @Test("the target is independent of the playhead, unlike zone()")
    func independentOfPlayhead() {
        let l = lanes()
        let ppb: CGFloat = 40
        let x: CGFloat = 80              // beat 2, and the playhead is here
        #expect(ArrangePointer.zone(
            x: x, y: 10, playheadX: x, pixelsPerBeat: ppb, topInset: 0,
            contentBottom: 200, lanes: l, laneSpacing: 6) == .playheadGrab)
        #expect(ArrangePointer.emptyLaneIndex(
            atY: 10, beatRaw: Double(x / ppb), in: l) == 0)
    }
}
