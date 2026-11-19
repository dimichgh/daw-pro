import CoreGraphics
import Testing
@testable import DAWAppKit

/// m39-tpl-8 — the template picker card's height budget (`TemplatePickerLayout`):
/// the TEMPLATE GRID is the one region that yields (design §9.2, the m26-i law in
/// docs/DESIGN-LANGUAGE.md "Centered modal cards").
///
/// ⚠️ These tests CONSUME the chrome constants; they cannot tell whether a
/// constant matches the drawn card (that needs pixels, `_m26i-card-height-probe`
/// style, owed for the §8.9 dogfood). What they pin is the RULE: a ceiling
/// derived from the window, a fixed chrome, a grid that hugs when it fits,
/// scrolls when it does not, snaps to whole rows, and never goes under its floor.
@Suite("m39-tpl-8: TemplatePickerLayout — the grid is the one region that yields")
struct TemplatePickerLayoutTests {
    typealias L = TemplatePickerLayout

    /// The smallest window the app allows, its whole content height.
    static let smallest = WindowFloor.minHeight
    static let tall: CGFloat = 1400

    @Test("at the smallest window the card FITS the window, the chrome keeps its height, and the grid scrolls whole rows")
    func smallestWindow() {
        for isPro in [false, true] {
            let available = Self.smallest
            let grid = L.gridHeight(tileCount: 10, isPro: isPro, availableHeight: available)
            let card = L.cardHeight(tileCount: 10, isPro: isPro, availableHeight: available)
            #expect(card <= available - 2 * L.windowMargin, "isPro=\(isPro): \(card) overflows \(available)")
            #expect(card == L.chromeHeight(isPro: isPro) + grid, "the chrome is fixed; only the grid moved")
            let rows = L.visibleRows(inHeight: grid)
            #expect(rows >= L.minVisibleRows, "isPro=\(isPro): \(rows) rows")
            #expect(rows < L.rows(tileCount: 10), "isPro=\(isPro): ten tiles cannot all fit — the grid must scroll")
            #expect(grid == L.height(rows: rows), "a sliced row is not a row: \(grid) is not whole rows")
        }
        // The two densities' answers at the floor, as numbers a person can check on screen.
        #expect(L.visibleRows(inHeight: L.gridHeight(tileCount: 10, isPro: false, availableHeight: Self.smallest)) == 3)
        #expect(L.visibleRows(inHeight: L.gridHeight(tileCount: 10, isPro: true, availableHeight: Self.smallest)) == 2)
    }

    @Test("in a tall window the grid HUGS its tiles — all five rows, no empty well — and the card stays under its ceiling")
    func tallWindow() {
        for isPro in [false, true] {
            let grid = L.gridHeight(tileCount: 10, isPro: isPro, availableHeight: Self.tall)
            #expect(grid == L.height(rows: 5), "isPro=\(isPro)")
            let card = L.cardHeight(tileCount: 10, isPro: isPro, availableHeight: Self.tall)
            #expect(card < L.cardCeiling(availableHeight: Self.tall, isPro: isPro))
        }
        // A short tab (one saved template) draws one row, not a five-row well.
        #expect(L.gridHeight(tileCount: 1, isPro: true, availableHeight: Self.tall) == L.height(rows: 1))
        // An empty tab still draws one row's worth, for its "no saved templates" line.
        #expect(L.gridHeight(tileCount: 0, isPro: true, availableHeight: Self.tall) == L.height(rows: 1))
    }

    @Test("the ceiling comes from the window: a taller window never shrinks the grid, up to the cap")
    func ceilingFollowsTheWindow() {
        var last: CGFloat = 0
        for available in stride(from: Self.smallest, through: 1600, by: 20) {
            let grid = L.gridHeight(tileCount: 40, isPro: false, availableHeight: available)
            #expect(grid >= last, "at \(available) the grid shrank from \(last) to \(grid)")
            last = grid
        }
        #expect(L.cardCeiling(availableHeight: 5000, isPro: false) == L.maxCardHeight)
    }

    @Test("the floor is a valve: below any real window the grid keeps its floor rows, and the minimum card is DERIVED from it")
    func floorIsDerived() {
        for isPro in [false, true] {
            let grid = L.gridHeight(tileCount: 10, isPro: isPro, availableHeight: 300)
            #expect(L.visibleRows(inHeight: grid) == L.minVisibleRows)
            #expect(L.minCardHeight(isPro: isPro) == L.chromeHeight(isPro: isPro) + L.height(rows: L.minVisibleRows))
            #expect(L.minCardHeight(isPro: isPro) <= Self.smallest - 2 * L.windowMargin,
                    "the floor must fit the smallest window, or it outranks the ceiling there")
        }
    }

    @Test("the Save card's track list yields: it fits the smallest window and never drops under three rows")
    func saveCardListYields() {
        let room = L.saveListRoom(availableHeight: Self.smallest)
        #expect(L.saveChromeHeight + room <= Self.smallest - 2 * L.windowMargin)
        #expect(room >= CGFloat(L.saveMinVisibleRows) * L.saveRowHeight)
        #expect(L.saveListRoom(availableHeight: 200) == CGFloat(L.saveMinVisibleRows) * L.saveRowHeight)
        #expect(L.saveListRoom(availableHeight: Self.tall) > room, "a taller window gives the list more room")
    }

    @Test("row arithmetic: height(rows:) and visibleRows(inHeight:) invert each other")
    func rowArithmetic() {
        for rows in 0...8 {
            #expect(L.visibleRows(inHeight: L.height(rows: rows)) == rows)
        }
        #expect(L.rows(tileCount: 10) == 5)
        #expect(L.rows(tileCount: 11) == 6)
        #expect(L.proCardWidth > L.simpleCardWidth, "Pro's detail pane adds width, not chrome")
    }
}
