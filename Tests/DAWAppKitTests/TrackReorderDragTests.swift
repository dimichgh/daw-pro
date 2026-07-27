import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// m23-h — the pure drop-landing registry behind the arrange track-header drag.
///
/// The fixtures here are deliberately UNEVEN (one expanded row, one takes row):
/// a uniform ladder is the fixture that cannot tell "the row under the pointer"
/// apart from "pointerY / pitch", and the app's ladder is never uniform once a
/// track opens its automation or takes section.
@Suite("Track reorder drag (m23-h)")
struct TrackReorderDragTests {
    /// Four rows: 34, 98 (expanded), 34, 34, separated by the 6 pt lane gap.
    /// tops:    0, 40, 144, 184
    /// bottoms: 34, 138, 178, 218
    private let ladder = TrackRowLadder(
        tops: [0, 40, 144, 184],
        heights: [34, 98, 34, 34])

    // MARK: - The landing rule

    @Test("the drop target is the row the pointer is over")
    func landsOnTheHoveredRow() throws {
        for (y, expected) in [(2.0, 0), (33.0, 0), (41.0, 1), (137.0, 1),
                              (150.0, 2), (200.0, 3)] {
            let drop = try #require(
                TrackReorderDrag.resolve(pointerY: y, from: 0, ladder: ladder))
            #expect(drop.index == expected, "y=\(y)")
        }
    }

    @Test("the gap between two rows belongs to the row above — no dead zone")
    func gapsBelongToTheRowAbove() throws {
        // y = 36 is inside the 6 pt gap under row 0 (34 … 40).
        let drop = try #require(
            TrackReorderDrag.resolve(pointerY: 36, from: 2, ladder: ladder))
        #expect(drop.index == 0)
    }

    @Test("above the first row clamps to 0; below the last clamps to the last")
    func clampsAtBothEnds() throws {
        let above = try #require(
            TrackReorderDrag.resolve(pointerY: -400, from: 2, ladder: ladder))
        #expect(above.index == 0)
        let below = try #require(
            TrackReorderDrag.resolve(pointerY: 9_000, from: 1, ladder: ladder))
        #expect(below.index == 3)
    }

    @Test("dragging further down never walks the landing back up (monotonic)")
    func landingIsMonotonic() throws {
        var previous = -1
        for step in stride(from: -50.0, through: 300.0, by: 3.0) {
            let drop = try #require(
                TrackReorderDrag.resolve(pointerY: step, from: 0, ladder: ladder))
            #expect(drop.index >= previous, "landing went backwards at y=\(step)")
            previous = drop.index
        }
        #expect(previous == 3)
    }

    // MARK: - The indicator, which cannot disagree with the index

    @Test("a DOWN move draws the line under the target row; an UP move above it")
    func indicatorMarksTheLandingEdge() throws {
        let down = try #require(
            TrackReorderDrag.resolve(pointerY: 150, from: 0, ladder: ladder))
        #expect(down.index == 2)
        #expect(down.moves)
        // Row 2 spans 144 … 178; landing BELOW it means the line sits at 178.
        #expect(down.indicatorY == 178)

        let up = try #require(
            TrackReorderDrag.resolve(pointerY: 41, from: 3, ladder: ladder))
        #expect(up.index == 1)
        #expect(up.indicatorY == 40)          // row 1's top edge
    }

    @Test("no move ⇒ no line: the indicator is nil exactly when the index is unchanged")
    func noMoveHasNoIndicator() throws {
        // Every pointer position that resolves to the dragged row's OWN index
        // must produce a nil indicator — the exclusivity is structural, so this
        // holds across the whole row rather than at one probe point.
        for y in stride(from: 40.0, through: 140.0, by: 5.0) {
            let drop = try #require(
                TrackReorderDrag.resolve(pointerY: y, from: 1, ladder: ladder))
            #expect(drop.index == 1)
            #expect(!drop.moves)
            #expect(drop.indicatorY == nil, "a no-op drop drew a line at y=\(y)")
        }
    }

    @Test("`from` rides along so the commit knows which direction it moved")
    func carriesTheOrigin() throws {
        let drop = try #require(
            TrackReorderDrag.resolve(pointerY: 200, from: 1, ladder: ladder))
        #expect(drop.from == 1)
        #expect(drop.index == 3)
    }

    // MARK: - The parting reflow

    @Test("the measured gap comes off the ladder, not a hardcoded 6")
    func spacingIsMeasured() {
        #expect(ladder.spacing == 6)
        #expect(TrackRowLadder(tops: [0], heights: [34]).spacing == 0)
        #expect(TrackRowLadder(tops: [0, 50], heights: [40, 40]).spacing == 10)
    }

    @Test("a DOWN move slides the rows it passes UP by exactly the vacated slot")
    func downMovePartsUpward() throws {
        // Row 0 (34 tall) heading for index 2: rows 1 and 2 slide up by
        // 34 + 6 = 40; row 3 (past the landing) does not move.
        let drop = try #require(
            TrackReorderDrag.resolve(pointerY: 150, from: 0, ladder: ladder))
        #expect(drop.index == 2)
        let slides = (0..<4).map {
            TrackReorderDrag.displacement(row: $0, drop: drop, ladder: ladder)
        }
        #expect(slides == [0, -40, -40, 0])
    }

    @Test("an UP move slides the rows it passes DOWN by the same slot")
    func upMovePartsDownward() throws {
        // Row 3 (34 tall) heading for index 1: rows 1 and 2 slide down by 40.
        let drop = try #require(
            TrackReorderDrag.resolve(pointerY: 41, from: 3, ladder: ladder))
        #expect(drop.index == 1)
        let slides = (0..<4).map {
            TrackReorderDrag.displacement(row: $0, drop: drop, ladder: ladder)
        }
        #expect(slides == [0, 40, 40, 0])
    }

    @Test("the slot that opens is exactly the slot that closes (nothing overlaps)")
    func partingConservesTheLadder() throws {
        // Dragging the TALL row (index 1, 98 pt) proves the slot is the DRAGGED
        // row's height, not a uniform pitch: everything it passes moves by
        // 98 + 6, so the gap that opens fits it exactly.
        let drop = try #require(
            TrackReorderDrag.resolve(pointerY: 200, from: 1, ladder: ladder))
        #expect(drop.index == 3)
        let slides = (0..<4).map {
            TrackReorderDrag.displacement(row: $0, drop: drop, ladder: ladder)
        }
        #expect(slides == [0, 0, -104, -104])

        // The parted rows land exactly where the COMMITTED order would put them:
        // after moving row 1 to index 3 the order is 0, 2, 3, 1 — so row 2's new
        // top is row 1's old top, and row 3 follows it.
        #expect(ladder.tops[2] + slides[2] == ladder.tops[1])
        #expect(ladder.tops[3] + slides[3] == ladder.tops[1] + ladder.heights[2] + ladder.spacing)
    }

    @Test("a no-op landing parts nothing, and the dragged row never displaces itself")
    func noOpPartsNothing() throws {
        let stay = try #require(
            TrackReorderDrag.resolve(pointerY: 100, from: 1, ladder: ladder))
        #expect(!stay.moves)
        for row in 0..<4 {
            #expect(TrackReorderDrag.displacement(row: row, drop: stay, ladder: ladder) == 0)
        }
        let moving = try #require(
            TrackReorderDrag.resolve(pointerY: 200, from: 0, ladder: ladder))
        #expect(TrackReorderDrag.displacement(row: 0, drop: moving, ladder: ladder) == 0)
    }

    @Test("an out-of-ladder row asks for no displacement rather than trapping")
    func displacementIsTotal() throws {
        let drop = try #require(
            TrackReorderDrag.resolve(pointerY: 200, from: 0, ladder: ladder))
        #expect(TrackReorderDrag.displacement(row: 9, drop: drop, ladder: ladder) == 0)
        #expect(TrackReorderDrag.displacement(row: -1, drop: drop, ladder: ladder) == 0)
        #expect(TrackReorderDrag.displacement(row: 1, drop: drop, ladder: .empty) == 0)
    }

    // MARK: - Refusals (a bad ladder must produce NO landing, never index 0)

    @Test("an unmeasured or mismatched ladder resolves to nil, not to the top slot")
    func unusableLadderResolvesToNil() {
        #expect(TrackReorderDrag.resolve(pointerY: 10, from: 0, ladder: .empty) == nil)
        #expect(TrackReorderDrag.resolve(
            pointerY: 10, from: 0,
            ladder: TrackRowLadder(tops: [0, 40], heights: [34])) == nil)
        #expect(!TrackRowLadder(tops: [0, 40], heights: [34]).isWellFormed)
    }

    @Test("a `from` outside the ladder resolves to nil")
    func unknownOriginResolvesToNil() {
        #expect(TrackReorderDrag.resolve(pointerY: 10, from: 4, ladder: ladder) == nil)
        #expect(TrackReorderDrag.resolve(pointerY: 10, from: -1, ladder: ladder) == nil)
    }

    @Test("a single-row ladder can only ever land on itself")
    func singleRowLadder() throws {
        let one = TrackRowLadder(tops: [0], heights: [34])
        for y in [-100.0, 5.0, 500.0] {
            let drop = try #require(TrackReorderDrag.resolve(pointerY: y, from: 0, ladder: one))
            #expect(drop.index == 0)
            #expect(!drop.moves)
            #expect(drop.indicatorY == nil)
        }
    }
}
