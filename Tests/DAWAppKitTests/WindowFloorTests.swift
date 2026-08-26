import CoreGraphics
import Testing
@testable import DAWAppKit

/// Headless coverage for the main-window size floor (m10-j). The window enforces
/// this floor and `debug.windowFrame` clamps to it, so a small-window gate can
/// never drive the chrome off-screen. The numbers are MEASURED (NSHostingView
/// fittingSize of the real chrome rows); these tests pin the clamp contract and the
/// two derivations (width covers the Pro transport bar; height keeps the fixed
/// chrome + a timeline sliver visible with the editor at its max fraction) so a
/// future edit that quietly lowers the floor fails (the `PanelLayoutStore` style).
@MainActor
@Suite("WindowFloor — window size floor (m10-j)")
struct WindowFloorTests {

    @Test("clamp raises a too-small request to the floor, leaves a large one, passes the floor")
    func clamp() {
        let small = WindowFloor.clampWindowContent(width: 400, height: 300)
        #expect(small.width == WindowFloor.minWidth)
        // `clampWindowContent`'s height argument and result are CONTENT-RECT units
        // (what the NSWindow actually holds), so the floor it clamps to is
        // `minWindowContentHeight` (672), not the SwiftUI layout floor `minHeight`
        // (640) — that mismatch was the m23-dw bug: a request below 672 used to be
        // echoed back verbatim and then silently drift up once SwiftUI laid out.
        #expect(small.height == WindowFloor.minWindowContentHeight)

        let big = WindowFloor.clampWindowContent(width: 2000, height: 1400)
        #expect(big.width == 2000)
        #expect(big.height == 1400)

        // A mixed request clamps each axis independently.
        let mixed = WindowFloor.clampWindowContent(width: 500, height: 2000)
        #expect(mixed.width == WindowFloor.minWidth)
        #expect(mixed.height == 2000)

        // Exactly at the (content-rect) floor passes through unchanged.
        let atFloor = WindowFloor.clampWindowContent(width: WindowFloor.minWidth,
                                                       height: WindowFloor.minWindowContentHeight)
        #expect(atFloor.width == WindowFloor.minWidth)
        #expect(atFloor.height == WindowFloor.minWindowContentHeight)
    }

    @Test("min width covers the measured Pro transport bar plus the outer padding")
    func widthFloor() {
        // The transport is the width-binding chrome; the floor must fit its Pro
        // variant (the widest reachable) INSIDE the window's outer padding, so
        // nothing clips at the minimum.
        #expect(WindowFloor.minWidth >= WindowFloor.transportProMinWidth + WindowFloor.outerHorizontalPadding)
    }

    @Test("min height keeps fixed chrome + a timeline sliver visible with the editor at max")
    func heightFloor() {
        // Worst case for chrome visibility: the editor open at its max fraction. The
        // remaining (1 − fraction) of the window must still hold the fixed chrome AND
        // a usable timeline sliver — the derivation the minHeight is set from.
        let nonEditor = WindowFloor.minHeight * (1 - WindowFloor.editorMaxFraction)
        #expect(nonEditor >= WindowFloor.fixedChromeHeight + WindowFloor.timelineSliverMinHeight)
    }

    @Test("minWindowContentHeight is minHeight plus the titlebar inset, and strictly taller")
    func unitRelationship() {
        // The whole m23-dw bug was one constant asked to do two jobs in two unit
        // systems. Pin the derivation explicitly so a future edit that collapses
        // `minWindowContentHeight` back down to equal `minHeight` (reintroducing
        // the drift) fails HERE, rather than only showing up as a staging sweep
        // weeks later.
        #expect(WindowFloor.minWindowContentHeight == WindowFloor.minHeight + WindowFloor.titlebarInset)
        #expect(WindowFloor.minWindowContentHeight > WindowFloor.minHeight)
    }

    @Test("the declared window floor is a fixed point, and the old lying band clamps up to it")
    func floorIsAchievable() {
        // This is the actual m23-dw defect, not just a units mismatch: a window
        // asked for exactly the floor must GET exactly the floor back — the same
        // width/height pair, unchanged — because that is the smallest content
        // rect the window can genuinely hold.
        let atFloor = WindowFloor.clampWindowContent(width: WindowFloor.minWidth,
                                                       height: WindowFloor.minWindowContentHeight)
        #expect(atFloor.width == WindowFloor.minWidth)
        #expect(atFloor.height == WindowFloor.minWindowContentHeight)

        // Before the fix, the whole band `[minHeight … minWindowContentHeight - 1]`
        // (640…671) was echoed back VERBATIM at t0 and only drifted up to 672 about
        // 400 ms later, once SwiftUI laid out — a caller reading the echo saw a
        // height the window could not actually hold. Every request in that band
        // must now clamp UP immediately, not pass through.
        for requested in [CGFloat(641), 656, 671] {
            let clamped = WindowFloor.clampWindowContent(width: WindowFloor.minWidth, height: requested)
            #expect(clamped.height == WindowFloor.minWindowContentHeight,
                     "\(requested) pt must clamp up to \(WindowFloor.minWindowContentHeight), not pass through the way the pre-m23-dw lying band did")
        }
    }

    @Test("editor max fraction matches the layout store's clamp ceiling")
    func editorFractionMatchesStore() {
        // The height derivation is only honest if it uses the SAME max fraction the
        // splitter can actually reach.
        #expect(WindowFloor.editorMaxFraction == PanelLayoutStore.editorFractionRange.upperBound)
    }

    @Test("the default size sits at or above the floor on both axes")
    func defaultAboveFloor() {
        #expect(WindowFloor.defaultWidth >= WindowFloor.minWidth)
        // Both readings, on purpose: `minHeight` is the weaker, layout-area pin
        // (kept so a future edit that collapses `minWindowContentHeight` back down
        // to equal it doesn't silently lose coverage here too), but `defaultHeight`
        // is itself a window CONTENT-RECT height (what `.defaultSize` and the
        // NSWindow itself see), so the check that actually matters is against the
        // REAL, achievable floor — `minWindowContentHeight` (672) — not just the
        // SwiftUI layout floor, which is a smaller number in a different unit
        // system and would pass even if the default window shipped BELOW the floor
        // the window itself enforces.
        #expect(WindowFloor.defaultHeight >= WindowFloor.minHeight)
        #expect(WindowFloor.defaultHeight >= WindowFloor.minWindowContentHeight)
    }
}
