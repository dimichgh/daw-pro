import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// m25-g — the PURE half of group compress/extend: where the handle is, and what
/// one drag of it decides. Everything here is reachable only by hovering and
/// dragging with a real pointer in the shipping app, and m23-g1 established that
/// nothing in this tree can produce one — so this suite is the only instrument
/// that can see any of it.
@Suite("Piano roll group scale — geometry + plan (m25-g)")
struct PianoRollGroupScaleTests {

    private func rect(x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat = 14)
        -> (id: UUID, rect: CGRect) {
        (UUID(), CGRect(x: x, y: y, width: w, height: h))
    }

    // MARK: - The selection box

    @Test("the group frame is the union of the selected rects")
    func frameIsTheUnion() {
        let frame = PianoRollGroupScale.frame(selectedRects: [
            rect(x: 32, y: 140, w: 16),
            rect(x: 96, y: 70, w: 32),
        ])
        #expect(frame == CGRect(x: 32, y: 70, width: 96, height: 84))
    }

    @Test("fewer than two selected notes get no handle at all")
    func singleNoteHasNoGroupHandle() {
        // DEGENERATE CASE 1. A one-note selection's span IS that note, so a
        // "group" scale would be a resize with a different anchor rule sitting a
        // few points from the note's own resize handle. `minimumNotes` refuses.
        #expect(PianoRollGroupScale.frame(selectedRects: []) == nil)
        #expect(PianoRollGroupScale.frame(selectedRects: [rect(x: 0, y: 0, w: 32)]) == nil)
        // POSITIVE CONTROL: the same call with two rects DOES produce a frame,
        // so the two negatives above are the rule and not a broken helper.
        #expect(PianoRollGroupScale.frame(selectedRects: [
            rect(x: 0, y: 0, w: 32), rect(x: 64, y: 0, w: 32),
        ]) != nil)
    }

    // MARK: - The band sits OUTSIDE the selection (decision 4)

    @Test("both handle bands are strictly outside the selection's box")
    func bandsAreStrictlyOutside() {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 42)
        let leading = PianoRollGroupScale.handleRect(frame: frame, edge: .leading)
        let trailing = PianoRollGroupScale.handleRect(frame: frame, edge: .trailing)
        #expect(leading.maxX == frame.minX)
        #expect(trailing.minX == frame.maxX)
        #expect(leading.width == PianoRollGroupScale.grabWidth)
        #expect(trailing.width == PianoRollGroupScale.grabWidth)
        // Vertically they match the selection exactly — never the whole grid.
        #expect(leading.minY == frame.minY && leading.height == frame.height)
        #expect(trailing.minY == frame.minY && trailing.height == frame.height)
    }

    // `@MainActor` for ONE reason: `PianoRollModel.resizeHandleWidth` is
    // actor-isolated, and this test reads the REAL constant rather than
    // re-typing `8` — a literal would keep passing if the note's own handle grew
    // into the band this test says it does not touch.
    @MainActor
    @Test("a point one pixel inside the first note's body is NOT a handle")
    func aPressInsideTheSelectionIsNeverAHandle() {
        // ⭐ THE ZERO-REGRESSION PROPERTY, asserted rather than asserted-in-prose.
        // The first selected note's body starts at `frame.minX`, and pressing it
        // starts the roll's most-used gesture (rigid group move). If the leading
        // band were biased even one point inward, that press would silently
        // become a scale.
        let frame = CGRect(x: 100, y: 50, width: 200, height: 42)
        let inside = CGPoint(x: frame.minX + 1, y: frame.midY)
        #expect(PianoRollGroupScale.edge(at: inside, frame: frame) == nil)
        // The box's own left edge belongs to the note, not the band.
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.minX, y: frame.midY),
                                         frame: frame) == nil)
        // ...and the last note's right-edge resize handle keeps all 8 of its
        // points: the trailing band starts at maxX, which `CGRect.contains`
        // already excludes from the note.
        let lastNoteResizeZone = CGPoint(
            x: frame.maxX - PianoRollModel.resizeHandleWidth / 2, y: frame.midY)
        #expect(PianoRollGroupScale.edge(at: lastNoteResizeZone, frame: frame) == nil)
        // POSITIVE CONTROL: a point in the margin IS a handle, so the negatives
        // above are the geometry and not an always-nil function.
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.minX - 1, y: frame.midY),
                                         frame: frame) == .leading)
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.maxX + 1, y: frame.midY),
                                         frame: frame) == .trailing)
    }

    @Test("the bands end where they end, horizontally and vertically")
    func bandsAreBounded() {
        let frame = CGRect(x: 100, y: 50, width: 200, height: 42)
        let w = PianoRollGroupScale.grabWidth
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.minX - w + 0.5, y: frame.midY),
                                         frame: frame) == .leading)
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.minX - w - 0.5, y: frame.midY),
                                         frame: frame) == nil)
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.maxX + w - 0.5, y: frame.midY),
                                         frame: frame) == .trailing)
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.maxX + w + 0.5, y: frame.midY),
                                         frame: frame) == nil)
        // A point beside the selection but at a pitch nobody selected is inert —
        // the band is the selection's height, not the grid's.
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: frame.maxX + 1, y: frame.minY - 20),
                                         frame: frame) == nil)
    }

    @Test("a selection starting at beat 0 has no reachable leading handle")
    func leadingHandleIsUnreachableAtBeatZero() {
        // ⚠️ KNOWN COST 3, PINNED SO IT STAYS A DECISION. The band for a
        // selection whose earliest onset is beat 0 is `[-12, 0)` — off the left
        // edge of the grid, where `.onContinuousHover` never reports. A ⌘A in a
        // clip that starts on the downbeat therefore gets a trailing handle and
        // no leading one.
        //
        // The assertion is on the REACHABLE part: no point a hover can produce
        // (x >= 0) resolves to `.leading`.
        let atZero = CGRect(x: 0, y: 50, width: 200, height: 42)
        for x in stride(from: 0.0, through: 40.0, by: 0.5) {
            #expect(PianoRollGroupScale.edge(at: CGPoint(x: x, y: atZero.midY),
                                             frame: atZero) != .leading)
        }
        // POSITIVE CONTROL: shift the same selection right by one grab width and
        // the leading handle becomes reachable — so the sweep above measures the
        // wall, not a broken predicate.
        let shifted = atZero.offsetBy(dx: PianoRollGroupScale.grabWidth, dy: 0)
        #expect(PianoRollGroupScale.edge(at: CGPoint(x: 1, y: shifted.midY),
                                         frame: shifted) == .leading)
    }

    // MARK: - The plan

    @Test("the trailing handle anchors on the earliest onset")
    func trailingAnchorsOnStart() {
        // Span 0...4 dragged out to 8: everything doubles about beat 0.
        let plan = PianoRollGroupScale.plan(
            startBeat: 0, endBeat: 4, edge: .trailing, targetBeat: 8, minSpanBeats: 0.25)
        #expect(plan?.anchorBeat == 0)
        #expect(plan?.edgeBeat == 8)
        #expect(plan?.factor == 2)
    }

    @Test("the leading handle anchors on the latest end")
    func leadingAnchorsOnEnd() {
        // ⭐ DECISION 2: dragging the LEFT handle must leave the RIGHT edge
        // exactly where it was — the region-resize expectation. Span 4...8
        // dragged left to 0 doubles about beat 8.
        let plan = PianoRollGroupScale.plan(
            startBeat: 4, endBeat: 8, edge: .leading, targetBeat: 0, minSpanBeats: 0.25)
        #expect(plan?.anchorBeat == 8)
        #expect(plan?.edgeBeat == 0)
        #expect(plan?.factor == 2)
    }

    @Test("a zero or negative span has no scale, and never divides by zero")
    func zeroSpanIsRefused() {
        // DEGENERATE CASE 2. Unreachable through `MIDINote` (whose initializer
        // floors length at `minLengthBeats`), which is exactly why it is worth a
        // test: the guard is the only thing standing between a future caller
        // with a synthetic span and a `0/0` factor propagating a NaN into every
        // selected note's start.
        #expect(PianoRollGroupScale.plan(startBeat: 2, endBeat: 2, edge: .trailing,
                                         targetBeat: 4, minSpanBeats: 0.25) == nil)
        #expect(PianoRollGroupScale.plan(startBeat: 4, endBeat: 2, edge: .leading,
                                         targetBeat: 0, minSpanBeats: 0.25) == nil)
    }

    @Test("compressing bottoms out at the span floor instead of collapsing")
    func compressionIsFloored() {
        // DEGENERATE CASE 3a: drag the trailing handle back past the anchor.
        // Without the floor this is a zero or NEGATIVE factor — every note
        // stacked on one beat, or the figure played backwards.
        let plan = PianoRollGroupScale.plan(
            startBeat: 2, endBeat: 6, edge: .trailing, targetBeat: 0, minSpanBeats: 0.25)
        #expect(plan?.edgeBeat == 2.25)
        #expect(plan?.factor == 0.0625)   // 0.25 / 4
        #expect((plan?.factor ?? 0) > 0)
        // Same wall from the other handle.
        let mirrored = PianoRollGroupScale.plan(
            startBeat: 2, endBeat: 6, edge: .leading, targetBeat: 99, minSpanBeats: 0.25)
        #expect(mirrored?.edgeBeat == 5.75)
        #expect(mirrored?.factor == 0.0625)
    }

    @Test("the floor never GROWS a selection that is already shorter than it")
    func theFloorCannotExpand() {
        // ⚠️ The whole reason the floor is `min(span, minSpanBeats)`. A group
        // spanning 1/16 of a beat, with a 1/4-beat grid: a bare floor would jump
        // it to a quarter note the instant the handle was touched — a compress
        // gesture that expands.
        let plan = PianoRollGroupScale.plan(
            startBeat: 1, endBeat: 1.0625, edge: .trailing, targetBeat: 0, minSpanBeats: 0.25)
        #expect(plan?.edgeBeat == 1.0625)   // unchanged, not grown to 1.25
        #expect(plan?.factor == 1)
    }

    @Test("the leading handle stops at beat 0 and never goes negative")
    func leadingStopsAtZero() {
        // DEGENERATE CASE 4: dragging the left handle off the front of the clip.
        let plan = PianoRollGroupScale.plan(
            startBeat: 1, endBeat: 3, edge: .leading, targetBeat: -50, minSpanBeats: 0.25)
        #expect(plan?.edgeBeat == 0)
        #expect(plan?.factor == 1.5)        // span 2 -> 3
        #expect((plan?.edgeBeat ?? -1) >= 0)
    }

    @Test("the leading handle's two clamps can never contradict each other")
    func leadingClampIntervalIsNonEmpty() {
        // The advisor's property, asserted instead of argued: the leading edge
        // must satisfy BOTH `>= 0` and `<= anchor - minSpan`, and that interval
        // is non-empty by construction because `minSpan <= span <= anchor`.
        // A sweep, because a single example proves nothing about an invariant.
        var checked = 0
        for start in stride(from: 0.0, through: 3.0, by: 0.25) {
            for span in stride(from: 0.0625, through: 4.0, by: 0.3125) {
                for floor in [0.0625, 0.25, 1.0, 4.0, 16.0] {
                    for target in [-10.0, 0.0, start, start + span, 99.0] {
                        guard let plan = PianoRollGroupScale.plan(
                            startBeat: start, endBeat: start + span, edge: .leading,
                            targetBeat: target, minSpanBeats: floor) else { continue }
                        #expect(plan.edgeBeat >= 0)
                        #expect(plan.edgeBeat <= plan.anchorBeat)
                        #expect(plan.factor > 0)
                        checked += 1
                    }
                }
            }
        }
        // ANTI-VACUITY: a sweep that generated nothing passes every assertion in
        // it. 13 starts x 13 spans x 5 floors x 5 targets.
        #expect(checked == 4225, "the sweep ran \(checked) cases, expected 4225")
    }

    @Test("stretching has no ceiling here — that is ClipAutoExtend's decision")
    func stretchIsUnbounded() {
        // Notes past the clip end are legal and latent (m18-f). A second limit
        // in this type would be a second policy for a question
        // `ClipAutoExtend.maxGrowthBars` already owns.
        let plan = PianoRollGroupScale.plan(
            startBeat: 0, endBeat: 1, edge: .trailing, targetBeat: 4096, minSpanBeats: 0.25)
        #expect(plan?.edgeBeat == 4096)
        #expect(plan?.factor == 4096)
    }
}
