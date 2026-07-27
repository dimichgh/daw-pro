import CoreGraphics
import Testing
@testable import DAWAppKit

/// The Export card's body bound (m23-m3c).
///
/// The number that matters is the one at the WINDOW FLOOR: stems mode took the
/// card to ~726 pt against a 640 pt floor, and both the title and the EXPORT
/// button fell off the window (captured before this type existed). So the legs
/// here are about the floor and about the comfortable window, not about the
/// arithmetic in the abstract.
@Suite("Export sheet layout (m23-m3c)")
struct ExportSheetLayoutTests {

    /// `DAWAppKit.WindowFloor`'s enforced minimum — the size the window can
    /// actually be dragged to, read from the same place the window enforces it
    /// rather than typed as a literal here.
    private var floorHeight: CGFloat { WindowFloor.minHeight }

    @Test("at the window floor the card's chrome still fits inside the window")
    func fitsAtTheFloor() {
        let room = ExportSheetLayout.bodyRoom(availableHeight: floorHeight)
        // The whole card is the room plus the chrome that never scrolls, and it
        // must clear the window with its margins — otherwise the EXPORT button
        // is off-screen and the dialog cannot be completed at all.
        let cardHeight = room + ExportSheetLayout.reservedChromeHeight
        #expect(cardHeight + 2 * ExportSheetLayout.windowMargin <= floorHeight,
                "card \(cardHeight) pt does not fit a \(floorHeight) pt window")
        // …and the region is still worth reading, not a two-row slot.
        #expect(room >= ExportSheetLayout.minimumBodyRoom)
    }

    @Test("a comfortable window leaves room for the tallest stems card, so it hugs")
    func hugsAtTheDefaultWindow() {
        #expect(ExportSheetLayout.bodyRoom(availableHeight: WindowFloor.defaultHeight)
                >= tallestStemsSections,
                "the card would scroll at the app's own default window size")
    }

    /// The tallest measured stems state, in points of SECTION content (mode +
    /// quality + both siblings + the nested loudness pair + a five-file
    /// preview). Measured off the staging captures, not derived.
    private var tallestStemsSections: CGFloat { 576 }

    @Test("at the floor the stems card genuinely SCROLLS — the path is taken, not just available")
    func theFloorTakesTheScrollPath() {
        // Asserted rather than assumed: a capture at the floor shows the file
        // list below the fold (`debug.captureUI` cannot scroll, so no gate leg
        // can exercise the gesture). This pins the arithmetic that says the
        // region is overflowing there — if a future trim made the sections fit,
        // this test fails and the "it scrolls at the floor" claim is retired
        // deliberately instead of quietly becoming false.
        let room = ExportSheetLayout.bodyRoom(availableHeight: floorHeight)
        #expect(tallestStemsSections > room,
                "the stems sections (\(tallestStemsSections) pt) now fit the floor's \(room) pt")
        // …and what the user must still be able to read WITHOUT scrolling is the
        // pinned chrome: the title row and the footer's count + EXPORT button.
        // Both live outside the region, which is what `reservedChromeHeight` buys.
        #expect(ExportSheetLayout.reservedChromeHeight > 0)
    }

    @Test("the bound grows with the window and never goes negative")
    func monotonicAndFloored() {
        var previous = ExportSheetLayout.bodyRoom(availableHeight: 200)
        #expect(previous == ExportSheetLayout.minimumBodyRoom,
                "an absurdly short window clamps rather than proposing a negative height")
        for height in stride(from: CGFloat(400), through: 2000, by: 100) {
            let room = ExportSheetLayout.bodyRoom(availableHeight: height)
            #expect(room >= previous)
            #expect(room > 0)
            previous = room
        }
    }
}
