import Testing
import Foundation
import CoreGraphics
@testable import DAWAppKit

/// m25-r — HELD-AT-EDGE AUTO-REPEAT. The limit m25-f-3 shipped with, stated by
/// its own author: *"with the pointer held still inside the band, scrolling
/// stops, and at the window's physical edge the pointer runs out of travel."*
///
/// ⚠️ **WHAT THESE TESTS CAN AND CANNOT SEE.** m23-g1 established that nothing
/// in this tree routes a real pointer event, so no test here can feel a ramp,
/// watch a note track a cursor, or judge whether 200 ms of hold delay feels
/// right. **Those need a human hand and this suite does not claim them.** What
/// it does claim is the arithmetic the feature rests on: that the loop
/// terminates at the wall, that the dragged note's SCREEN position is invariant
/// across the whole run, and that the repeat is live exactly where the shipped
/// per-event scroll is.
@Suite("Piano roll held-at-edge repeat (m25-r)")
struct PianoRollEdgeRepeatTests {

    /// The `PianoRollAutoScrollTests` geometry, deliberately: a viewport 1000
    /// wide onto 5000 of content, so the maximum offset is 4000 and every number
    /// below is derived from those three rather than discovered.
    private let viewport: CGFloat = 1000
    private let content: CGFloat = 5000

    /// A pointer pinned at the viewport's TRAILING edge — viewport-local x
    /// 1000, i.e. depth `edgeBand` into the trailing band, the full-step case.
    private func heldAtTrailingEdge(offset: CGFloat = 0) -> PianoRollEdgeRepeat.HeldPointer {
        PianoRollEdgeRepeat.HeldPointer(
            pointerContentX: viewport + offset, pointerContentY: 300,
            origin: CGPoint(x: 900, y: 300), currentOffset: offset)
    }

    private func tick(_ held: PianoRollEdgeRepeat.HeldPointer,
                      offset: CGFloat) -> PianoRollEdgeRepeat.Tick? {
        PianoRollEdgeRepeat.tick(held: held, observedOffset: offset,
                                 viewportWidth: viewport, contentWidth: content)
    }

    /// One full run of the feedback loop the view performs: tick → apply →
    /// observe the scroll → tick again. The view's `advanceGesture` reaches
    /// `autoScroll`, which asks `PianoRollAutoScroll.nextOffset` with the
    /// synthesised location, so the loop below is that path and not a model of
    /// it. Returns every observed offset, starting at `from`.
    private func run(_ held: PianoRollEdgeRepeat.HeldPointer,
                     from start: CGFloat,
                     limit: Int = 5000) -> (offsets: [CGFloat], ticks: [PianoRollEdgeRepeat.Tick]) {
        var offset = start
        var offsets: [CGFloat] = [start]
        var ticks: [PianoRollEdgeRepeat.Tick] = []
        while offsets.count <= limit, let next = tick(held, offset: offset) {
            ticks.append(next)
            guard let landed = PianoRollAutoScroll.nextOffset(
                pointerContentX: next.location.x, currentOffset: offset,
                viewportWidth: viewport, contentWidth: content) else { break }
            offset = landed
            offsets.append(offset)
        }
        return (offsets, ticks)
    }

    // MARK: - The premise, in one assertion

    /// ⭐⭐ **THE WHOLE FEATURE RESTS ON THIS ONE LINE.** A held pointer's
    /// position in the CONTENT changes by exactly the amount the content
    /// scrolled, so its VIEWPORT-LOCAL x is the invariant of a hold. That is
    /// what makes a repeat tick able to RECOMPUTE the pointer rather than invent
    /// it — which is the desync objection `PianoRollAutoScroll`'s no-timer note
    /// raises, answered.
    @Test("a stationary pointer over scrolled content keeps its viewport-local x")
    func localXIsTheInvariantOfAHold() {
        let atRest = PianoRollEdgeRepeat.HeldPointer(
            pointerContentX: 1000, pointerContentY: 300,
            origin: .zero, currentOffset: 0)
        // The SAME physical pointer, after the roll scrolled 240 points under
        // it: SwiftUI reports a content x 240 further along, because the grid
        // gesture resolves in the scrolling content's own space.
        let afterScroll = PianoRollEdgeRepeat.HeldPointer(
            pointerContentX: 1240, pointerContentY: 300,
            origin: .zero, currentOffset: 240)
        #expect(atRest.localX == afterScroll.localX)
        // ANTI-VACUITY: a DIFFERENT physical position does not collapse to the
        // same local x, so the equality above is the invariance and not a
        // constructor that throws its input away.
        let moved = PianoRollEdgeRepeat.HeldPointer(
            pointerContentX: 1300, pointerContentY: 300,
            origin: .zero, currentOffset: 240)
        #expect(moved.localX != atRest.localX)
    }

    // MARK: - The loop

    @Test("a pointer HELD at the trailing edge drives the viewport all the way to the wall")
    func heldPointerReachesTheTrailingWall() {
        let (offsets, _) = run(heldAtTrailingEdge(), from: 0)
        let maxOffset = content - viewport                 // 4000
        #expect(offsets.last == maxOffset)
        // 4000 / 24 = 166.67, so 166 full steps and one clamped one. Spelled as
        // arithmetic rather than as a discovered constant: if `maxStep` moves,
        // this moves with it and still means the same thing.
        let full = (maxOffset / PianoRollAutoScroll.maxStep).rounded(.down)
        #expect(offsets.count - 1 == Int(full) + 1)
        // And it STOPS: the run terminated on the policy's own nil rather than
        // on the loop guard.
        #expect(offsets.count < 5000)
    }

    /// ⚠️ **HALF DEPTH, NOT THE EDGE, AND THAT IS THE WHOLE POINT OF THIS LEG.**
    /// The first version put the pointer at viewport-local 0 and asserted only
    /// that it reached the wall — and **it survived two mutations that broke the
    /// trailing leg**, because the leading band is saturated for any pointer at
    /// or past its lip: the depth is clamped to 1 the whole way down, so a
    /// corrupted scroll term still walks to zero at full speed and the leg
    /// proves nothing about the ramp. At half depth the RATE is observable, and
    /// the tick count is what pins it.
    @Test("a pointer HELD half-deep in the leading band scrolls back at HALF rate")
    func heldPointerReachesTheLeadingWall() {
        let maxOffset = content - viewport
        // Viewport-local x 24 — half of `edgeBand` from the lip, so half step.
        let localX = PianoRollAutoScroll.edgeBand / 2
        let held = PianoRollEdgeRepeat.HeldPointer(
            pointerContentX: maxOffset + localX, pointerContentY: 300,
            origin: CGPoint(x: maxOffset + 100, y: 300), currentOffset: maxOffset)
        let (offsets, _) = run(held, from: maxOffset)
        #expect(offsets.last == 0)
        let perTick = PianoRollAutoScroll.maxStep / 2
        #expect(offsets.count - 1 == Int((maxOffset / perTick).rounded(.up)))
        // ANTI-VACUITY: the rate really is HALF, so the count above is the ramp
        // and not just "it got there".
        #expect((offsets[0] - offsets[1]) == perTick)
        #expect(perTick != PianoRollAutoScroll.maxStep)
    }

    /// ⭐⭐⭐ **THE PREMISE DIVERGENCE, IN NUMBERS — and it is the most useful
    /// thing in this file.**
    ///
    /// The feature assumes (A): the grid gesture resolves in the SCROLLING
    /// CONTENT's space, so a held pointer's content x tracks the scroll. That is
    /// established by construction from shipped code — `PianoRollView.scrubDrag`
    /// runs on the non-scrolling scrub strip and must ADD `gridScrollX` to
    /// recover a content x, while `gridDrag` feeds `value.location` straight
    /// into `model.hitTest` with no offset term, so if the two spaces were the
    /// same, note hit-testing would be wrong at every scrolled position.
    ///
    /// This pins what the OTHER world would look like, so the two can never be
    /// confused again: under ¬(A) the pointer's content x would be FROZEN, the
    /// depth would decay geometrically as the viewport slid out from under it,
    /// and a held repeat would scroll **exactly `edgeBand` points and stall** —
    /// independent of `maxStep`, because 24 + 12 + 6 + … = 48.
    ///
    /// ⚠️ **AND THAT RETIRES A CLAIM IN THE SHIPPED FILE.**
    /// `PianoRollAutoScroll.maxStep`'s doc justifies `maxStep < edgeBand` as
    /// stopping the pointer from "falling out of the band it is steering
    /// through". Under (A) that cannot happen at all — the pointer's local x is
    /// invariant under scrolling, as the test above pins. The guard describes
    /// the ¬(A) world. It is harmless and stays; the rationale is what is wrong.
    @Test("⚠️ under the OPPOSITE premise a held repeat stalls after exactly `edgeBand` points")
    func frozenPointerWouldStallAtTheBandWidth() {
        var offset: CGFloat = 0
        var ticks = 0
        // ¬(A): the SAME content x every iteration — a gesture space that does
        // not travel with the content.
        while ticks < 5000, let next = PianoRollAutoScroll.nextOffset(
            pointerContentX: viewport, currentOffset: offset,
            viewportWidth: viewport, contentWidth: content) {
            offset = next
            ticks += 1
        }
        #expect(abs(offset - PianoRollAutoScroll.edgeBand) < 0.000_001)
        // Nowhere near the wall, which is the point: the same clock that reaches
        // 4000 under (A) reaches 48 under ¬(A).
        #expect(offset < content - viewport)
        // It converges fast (the step halves each time), so the assertion above
        // is about the limit and not about the loop guard.
        #expect(ticks < 100)
    }

    // MARK: - The desync question, answered arithmetically

    /// ⭐⭐ **THE OBJECTION m25-f-3 RAISED, MEASURED.** *"A timer firing between
    /// pointer events … would have to FABRICATE a translation, and a fabricated
    /// translation desyncs the dragged notes from the cursor."*
    ///
    /// The dragged note sits at `baseline + translation.width` in CONTENT space
    /// and is drawn at `that − offset` on SCREEN. The pointer is HELD, so its
    /// screen position never changes. If the note tracks the cursor, that
    /// difference is constant for the entire run — through 167 ticks and 4000
    /// points of scroll.
    @Test("⭐ the dragged note's SCREEN position never moves under a held pointer")
    func heldRepeatKeepsTheNoteUnderTheCursor() {
        let held = heldAtTrailingEdge()
        let (offsets, ticks) = run(held, from: 0)
        let baseline: CGFloat = 800          // the note's content x at press
        let screenXs = zip(offsets, ticks).map { offset, tick in
            baseline + tick.translation.width - offset
        }
        #expect(screenXs.count > 100)
        #expect(Set(screenXs).count == 1)

        // ⚠️ ANTI-VACUITY, AND IT IS THE WHOLE PROOF: hold the translation FIXED
        // — the "scroll only, let the next real event catch the notes up"
        // variant, which for a HELD pointer means no next event ever comes — and
        // the same arithmetic drifts by the entire scrolled distance. So the
        // invariance above is a property of the synthesis, not of the formula.
        let frozen = ticks[0].translation.width
        let driftingXs = offsets.map { baseline + frozen - $0 }
        let drift = (driftingXs.max() ?? 0) - (driftingXs.min() ?? 0)
        #expect(drift == content - viewport)
    }

    /// A repeat carries notes SIDEWAYS and must never transpose them: there is
    /// no vertical edge scroll, so `contentY` is fixed for the whole hold, and
    /// `deltaPitch` in `advanceGesture` is a function of `translation.height`
    /// alone.
    @Test("a held repeat cannot change pitch — every tick's vertical translation is identical")
    func heldRepeatNeverTransposes() {
        let held = heldAtTrailingEdge()
        let (_, ticks) = run(held, from: 0)
        #expect(ticks.count > 100)
        #expect(Set(ticks.map(\.translation.height)).count == 1)
        #expect(ticks[0].translation.height == held.contentY - held.origin.y)
    }

    // MARK: - The repeat is live exactly where the shipped scroll is

    @Test("nil wherever a real pointer event would not scroll either")
    func repeatMatchesTheShippedPredicate() {
        // Middle of the viewport, both inner lips, both walls, degenerate
        // geometry — the `PianoRollAutoScrollTests` census, asked of the repeat.
        let cases: [(localX: CGFloat, offset: CGFloat)] = [
            (500, 1000), (48, 1000), (952, 1000),      // inert
            (1000, 4000), (0, 0),                      // walls
            (1000, 1000), (0, 1000),                   // live, both directions
        ]
        for probe in cases {
            let held = PianoRollEdgeRepeat.HeldPointer(
                pointerContentX: probe.localX + probe.offset, pointerContentY: 0,
                origin: .zero, currentOffset: probe.offset)
            let repeatAnswer = tick(held, offset: probe.offset) != nil
            let shipped = PianoRollAutoScroll.nextOffset(
                pointerContentX: probe.localX + probe.offset, currentOffset: probe.offset,
                viewportWidth: viewport, contentWidth: content) != nil
            #expect(repeatAnswer == shipped,
                    "localX \(probe.localX) at offset \(probe.offset)")
        }
        // ANTI-VACUITY: the census really does contain both answers, so the
        // equality above is not "nil == nil" seven times.
        let anyLive = cases.contains { probe in
            tick(PianoRollEdgeRepeat.HeldPointer(
                pointerContentX: probe.localX + probe.offset, pointerContentY: 0,
                origin: .zero, currentOffset: probe.offset), offset: probe.offset) != nil
        }
        let anyInert = cases.contains { probe in
            tick(PianoRollEdgeRepeat.HeldPointer(
                pointerContentX: probe.localX + probe.offset, pointerContentY: 0,
                origin: .zero, currentOffset: probe.offset), offset: probe.offset) == nil
        }
        #expect(anyLive)
        #expect(anyInert)
    }

    @Test("content that fits the viewport never repeats")
    func nothingToScroll() {
        let held = PianoRollEdgeRepeat.HeldPointer(
            pointerContentX: 990, pointerContentY: 0, origin: .zero, currentOffset: 0)
        #expect(PianoRollEdgeRepeat.tick(held: held, observedOffset: 0,
                                         viewportWidth: 1000, contentWidth: 1000) == nil)
        // ANTI-VACUITY: the same pointer over LONGER content does repeat, so the
        // nil above is the geometry and not a dead function.
        #expect(PianoRollEdgeRepeat.tick(held: held, observedOffset: 0,
                                         viewportWidth: 1000, contentWidth: 5000) != nil)
    }

    // MARK: - The hold delay

    /// ⚠️ **THIS GATE IS WHY THE FEATURE IS ADDITIVE.** While the pointer is
    /// moving, every tick is suppressed and the shipped m25-f-3 scroll runs
    /// byte-identically; the repeat is reachable only from the pointer-at-rest
    /// state, which had no behaviour at all before m25-r.
    @Test("the repeat waits for the pointer to actually be still")
    func holdDelayGatesTheClock() {
        #expect(!PianoRollEdgeRepeat.isHeld(sinceLastPointerEvent: .zero))
        #expect(!PianoRollEdgeRepeat.isHeld(sinceLastPointerEvent: .milliseconds(16)))
        #expect(PianoRollEdgeRepeat.isHeld(
            sinceLastPointerEvent: PianoRollEdgeRepeat.holdDelay))
        #expect(PianoRollEdgeRepeat.isHeld(sinceLastPointerEvent: .seconds(1)))
    }

    /// ⚠️⚠️ **THE ANTI-BEAT MARGIN, AND THE FIRST VERSION OF THIS GATE FAILED
    /// IT.** A counter-based rule ("no pointer event since the previous tick")
    /// reads as equivalent and is not: a 16 ms clock and ~16.7 ms pointer events
    /// beat against each other, so roughly every other tick would land in a
    /// genuinely empty window while the pointer was still MOVING, add its step
    /// to the real event's, and silently speed the shipped scroll up. A duration
    /// several tick-periods long cannot beat.
    @Test("the hold delay is many pointer-event periods, so a moving drag never trips it")
    func holdDelayCannotBeatAgainstTheEventRate() {
        #expect(PianoRollEdgeRepeat.holdDelay > PianoRollEdgeRepeat.interval * 4)
        // At 60 Hz delivery a moving pointer leaves ~16.7 ms gaps; the delay must
        // clear that by a wide margin even under a dropped frame or two.
        #expect(!PianoRollEdgeRepeat.isHeld(sinceLastPointerEvent: .milliseconds(50)))
    }

    /// The repeat must not be able to outrun the scroll it is asking for: every
    /// tick's target is computed from the OBSERVED offset, so a request can
    /// never be more than one `maxStep` beyond what the roll has actually seen.
    /// If the scroll lands slower than the clock ticks, the repeat degrades to
    /// the observation rate — "slower than asked", never "faster".
    @Test("no tick ever asks for more than one step beyond the observed offset")
    func aTickCannotOutrunTheObservedScroll() {
        let held = heldAtTrailingEdge()
        let (offsets, _) = run(held, from: 0)
        for (previous, next) in zip(offsets, offsets.dropFirst()) {
            #expect(next - previous <= PianoRollAutoScroll.maxStep)
            #expect(next - previous > 0)
        }
        #expect(offsets.count > 100)
    }
}
