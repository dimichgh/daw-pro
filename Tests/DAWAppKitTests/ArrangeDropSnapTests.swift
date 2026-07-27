import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the ONE home that decides where a dragged audio file
/// lands on the arrange timeline (m23-f): grid snap, magnetic snap to bar 1 and
/// to the target lane's clip edges, the pixel threshold, and the drag-session
/// rules that stop a drop overlay being stranded on screen.
@Suite("ArrangeDropSnap")
struct ArrangeDropSnapTests {
    private let fourFour = MeterMap(constant: TimeSignature(beatsPerBar: 4))
    /// The zoom every threshold case below is computed against: at 80 pt/beat
    /// the 10 pt magnet radius is exactly 0.125 beat. Every "inside" / "outside"
    /// probe is DERIVED from that number rather than guessed (the m23-c2 fixture
    /// law: compute the precondition, do not discover it by trial).
    private let ppb: Double = 80
    private var thresholdBeats: Double { ArrangeDropSnap.magnetThresholdPoints / ppb }

    // MARK: - Grid (no magnets in range)

    @Test("bar snap rounds to the nearest barline")
    func gridBar() {
        let r = ArrangeDropSnap.resolve(rawBeat: 9.4, snap: .bar, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(r.beat == 8)
        #expect(r.source == .grid)
        #expect(!r.isMagnetised)
    }

    @Test("beat snap rounds to the nearest beat")
    func gridBeat() {
        let r = ArrangeDropSnap.resolve(rawBeat: 9.4, snap: .beat, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(r.beat == 9)
        #expect(r.source == .grid)
    }

    @Test("sixteenth snap reaches the fine grid")
    func gridSixteenth() {
        let r = ArrangeDropSnap.resolve(rawBeat: 4.3, snap: .sixteenth, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(abs(r.beat - 4.3125) < 1e-9)   // 69/16
        #expect(r.source == .grid)
    }

    @Test("bar snap follows the meter map across a time-signature change (m13-h)")
    func gridMeterAware() throws {
        // 4/4 → 6/8 @ beat 16 (bpb 6): barlines …12, 16, 22, 28…
        // Moved here verbatim from `AudioImportPlanTests` when m23-f took
        // snapping out of the plan — the coverage did not disappear, it followed
        // the behaviour to its new home.
        let map = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 6, beatUnit: 8),
        ])
        // A drop at raw beat 20 (in 6/8) snaps to the 6/8 barline 22, not a
        // 4-beat grid.
        let right = ArrangeDropSnap.resolve(rawBeat: 20, snap: .bar, meterMap: map,
                                            pixelsPerBeat: ppb)
        #expect(right.beat == 22)
        #expect(right.source == .grid)
        // Just left of the boundary (4/4) snaps to the shared barline 16.
        let left = ArrangeDropSnap.resolve(rawBeat: 15, snap: .bar, meterMap: map,
                                           pixelsPerBeat: ppb)
        #expect(left.beat == 16)
    }

    @Test("bar snap follows an odd meter")
    func gridOddMeter() {
        // 3/4: bars at 0, 3, 6 — raw 5 → nearest bar 6.
        let map = MeterMap(constant: TimeSignature(beatsPerBar: 3))
        let r = ArrangeDropSnap.resolve(rawBeat: 5, snap: .bar, meterMap: map,
                                        pixelsPerBeat: ppb)
        #expect(r.beat == 6)
        #expect(r.source == .grid)
    }

    @Test("a negative drop x floors at the start of the song")
    func negativeFloors() {
        let r = ArrangeDropSnap.resolve(rawBeat: -12, snap: .bar, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(r.beat == 0)
    }

    // MARK: - Snap OFF

    @Test("snap off passes the raw beat through untouched")
    func offIsRaw() {
        let r = ArrangeDropSnap.resolve(rawBeat: 5.37, snap: .off, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(r.beat == 5.37)
        #expect(r.source == .raw)
    }

    @Test("snap off does NOT magnetise, even with a clip edge one pixel away")
    func offNeverMagnetises() {
        // 5.37 is 0.0125 beat (= 1 pt at 80 ppb) from the edge at 5.3825 — deep
        // inside the magnet radius. Snap OFF means the user asked for no
        // snapping, and the magnet must not overrule that.
        let r = ArrangeDropSnap.resolve(rawBeat: 5.37, snap: .off, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: [5.3825])
        #expect(r.beat == 5.37)
        #expect(r.source == .raw)
        #expect(!r.isMagnetised)
    }

    @Test("snap off does not magnetise to bar 1 either")
    func offNeverMagnetisesToBarOne() {
        let r = ArrangeDropSnap.resolve(rawBeat: 0.02, snap: .off, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(r.beat == 0.02)
        #expect(r.source == .raw)
    }

    // MARK: - Magnet: clip edges

    @Test("a clip edge inside the threshold takes the drop from the grid")
    func clipEdgeWins() {
        // Clip ends at 7.4. Drop at 7.45 => 0.05 beat away, inside 0.125.
        // The grid (.bar) would send it to 8.
        let r = ArrangeDropSnap.resolve(rawBeat: 7.45, snap: .bar, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: [3.0, 7.4])
        #expect(r.beat == 7.4)
        #expect(r.source == .magnetClipEdge)
        #expect(r.isMagnetised)
    }

    @Test("a clip edge OUTSIDE the threshold leaves the grid in charge")
    func clipEdgeOutsideThresholdLoses() {
        // Same clip edge, but the pointer is 0.2 beat away — outside 0.125.
        // This is the direction that proves the radius is real: without it the
        // magnet would swallow every drop on the lane.
        let r = ArrangeDropSnap.resolve(rawBeat: 7.6, snap: .bar, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: [7.4])
        #expect(r.beat == 8)
        #expect(r.source == .grid)
    }

    @Test("the threshold boundary is inclusive")
    func thresholdBoundaryInclusive() {
        let edge = 7.4
        let r = ArrangeDropSnap.resolve(rawBeat: edge + thresholdBeats, snap: .bar,
                                        meterMap: fourFour, pixelsPerBeat: ppb,
                                        clipEdgeBeats: [edge])
        #expect(r.beat == edge)
        #expect(r.source == .magnetClipEdge)
    }

    @Test("a clip's START edge magnetises as well as its end")
    func clipStartEdgeMagnetises() {
        let edges = ArrangeDropSnap.clipEdgeBeats(startBeats: [5.25], lengthBeats: [2.5])
        #expect(edges == [5.25, 7.75])
        let r = ArrangeDropSnap.resolve(rawBeat: 5.3, snap: .bar, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: edges)
        #expect(r.beat == 5.25)
        #expect(r.source == .magnetClipEdge)
    }

    @Test("the NEAREST of several in-range magnets wins")
    func nearestMagnetWins() {
        // Both 9.44 and 9.5 are inside 0.125 of 9.47; 9.5 is nearer (0.03).
        let r = ArrangeDropSnap.resolve(rawBeat: 9.47, snap: .beat, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: [9.44, 9.5])
        #expect(r.beat == 9.5)
        #expect(r.source == .magnetClipEdge)
    }

    @Test("magnet precedence holds even when the grid line is NEARER")
    func magnetBeatsANearerGridLine() {
        // The deliberate cost of precedence, named so it is never a surprise:
        // with a 1/16 grid the nearest grid line (9.5) is 0.01 beat away while
        // the clip edge (9.45) is 0.04 — yet the edge takes it, because butting
        // exactly against existing audio is the whole point of the magnet and a
        // fine grid would otherwise make every magnet unreachable.
        let r = ArrangeDropSnap.resolve(rawBeat: 9.49, snap: .sixteenth, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: [9.45])
        #expect(r.beat == 9.45)
        #expect(r.source == .magnetClipEdge)
    }

    @Test("a clip edge before the song start is clamped to 0")
    func negativeEdgeClamped() {
        let r = ArrangeDropSnap.resolve(rawBeat: 0.02, snap: .beat, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: [-4])
        #expect(r.beat == 0)
    }

    // MARK: - Magnet: bar 1

    @Test("bar 1 magnetises under a FINE grid — the case nearest-wins would kill")
    func barOneUnderFineGrid() {
        // 0.05 beat from bar 1, with a 1/16 grid whose nearest line (0.0625) is
        // only 0.0125 away. A nearest-wins-overall rule can NEVER pick bar 1 —
        // beat 0 is a grid line for every division and `ClipSnap.snap` rounds to
        // the nearest line, so the grid is always at least as close. Precedence
        // inside the radius is what keeps the requested feature alive.
        let r = ArrangeDropSnap.resolve(rawBeat: 0.05, snap: .sixteenth, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(r.beat == 0)
        #expect(r.source == .magnetBarOne)
    }

    @Test("bar 1 does not reach past the threshold")
    func barOneRespectsThreshold() {
        let r = ArrangeDropSnap.resolve(rawBeat: 0.2, snap: .sixteenth, meterMap: fourFour,
                                        pixelsPerBeat: ppb)
        #expect(abs(r.beat - 0.1875) < 1e-9)   // 3/16
        #expect(r.source == .grid)
    }

    @Test("an exact tie between bar 1 and a clip edge goes to bar 1")
    func tieGoesToBarOne() {
        // Ties resolve to the LOWER beat, so the result never depends on the
        // order candidates were offered in.
        let r = ArrangeDropSnap.resolve(rawBeat: 0.05, snap: .beat, meterMap: fourFour,
                                        pixelsPerBeat: ppb, clipEdgeBeats: [0.1])
        #expect(r.beat == 0)
        #expect(r.source == .magnetBarOne)
    }

    // MARK: - The threshold is in POINTS (zoom-invariant on screen)

    @Test("the same pixel radius covers less musical time as you zoom IN")
    func thresholdIsPixelBased() {
        let edge = 12.0
        // 0.1 beat away. At 80 ppb that is 8 pt — inside the 10 pt radius.
        let zoomedOut = ArrangeDropSnap.resolve(rawBeat: 12.1, snap: .bar, meterMap: fourFour,
                                                pixelsPerBeat: 80, clipEdgeBeats: [edge])
        #expect(zoomedOut.source == .magnetClipEdge)
        // The same 0.1 beat at 200 ppb is 20 pt — outside it.
        let zoomedIn = ArrangeDropSnap.resolve(rawBeat: 12.1, snap: .bar, meterMap: fourFour,
                                               pixelsPerBeat: 200, clipEdgeBeats: [edge])
        #expect(zoomedIn.source == .grid)
        #expect(zoomedIn.beat == 12)
    }

    @Test("a degenerate zoom disables the magnet rather than making it infinite")
    func zeroPPBDisablesMagnet() {
        let r = ArrangeDropSnap.resolve(rawBeat: 7.6, snap: .bar, meterMap: fourFour,
                                        pixelsPerBeat: 0, clipEdgeBeats: [7.4])
        #expect(r.beat == 8)
        #expect(r.source == .grid)
    }

    // MARK: - Drag session (the report-(2) fix)

    // `entered()`/`updated()` are `mutating`, and the `#expect` macro captures
    // its operands immutably — so each call is made on its own line and the
    // RESULT is what gets asserted.

    @Test("enter then update arms the preview")
    func sessionEnterUpdate() {
        var session = ArrangeDropSession()
        #expect(session.phase == .idle)
        let entered = session.entered()
        #expect(entered)
        #expect(session.phase == .dragging)
        let updated = session.updated()
        #expect(updated)
    }

    @Test("an update AFTER a drop is refused — the stranding ordering")
    func sessionRefusesPostDropUpdate() {
        var session = ArrangeDropSession()
        session.entered()
        session.updated()
        session.dropped()
        #expect(session.phase == .dropped)
        let updated = session.updated()
        #expect(updated == false)
        #expect(session.phase == .dropped, "a refused update must not reopen the session")
    }

    @Test("a fresh enter reopens the session after a drop")
    func sessionReopensOnEnter() {
        var session = ArrangeDropSession()
        session.dropped()
        let refused = session.updated()
        #expect(refused == false)
        let entered = session.entered()
        #expect(entered)
        let updated = session.updated()
        #expect(updated)
    }

    @Test("an exit reopens the session after a drop")
    func sessionReopensOnExit() {
        var session = ArrangeDropSession()
        session.dropped()
        session.exited()
        #expect(session.phase == .idle)
        let updated = session.updated()
        #expect(updated, "an exit ends the drop, so the next drag may preview")
    }

    @Test("an update with no prior enter still arms (a missed enter must not kill the preview)")
    func sessionImplicitEnter() {
        var session = ArrangeDropSession()
        let updated = session.updated()
        #expect(updated)
        #expect(session.phase == .dragging)
    }

    @Test("a stranded hover is dismissible by a pointer event only with no button held")
    func pointerDismissRule() {
        // The guard that makes the dismissal safe: a Finder drag holds the
        // primary button down for its whole duration, so a live preview can
        // never be cancelled by this path even if hover events were delivered
        // mid-drag.
        #expect(ArrangeDropSession.pointerMayDismissHover(hoverPresent: true,
                                                          pressedMouseButtons: 0))
        #expect(!ArrangeDropSession.pointerMayDismissHover(hoverPresent: true,
                                                           pressedMouseButtons: 1))
        #expect(!ArrangeDropSession.pointerMayDismissHover(hoverPresent: true,
                                                           pressedMouseButtons: 2))
        // Nothing to dismiss is not a dismissal.
        #expect(!ArrangeDropSession.pointerMayDismissHover(hoverPresent: false,
                                                           pressedMouseButtons: 0))
    }
}
