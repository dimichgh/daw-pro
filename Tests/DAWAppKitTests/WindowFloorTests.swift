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
        let small = WindowFloor.clamp(width: 400, height: 300)
        #expect(small.width == WindowFloor.minWidth)
        #expect(small.height == WindowFloor.minHeight)

        let big = WindowFloor.clamp(width: 2000, height: 1400)
        #expect(big.width == 2000)
        #expect(big.height == 1400)

        // A mixed request clamps each axis independently.
        let mixed = WindowFloor.clamp(width: 500, height: 2000)
        #expect(mixed.width == WindowFloor.minWidth)
        #expect(mixed.height == 2000)

        // Exactly at the floor passes through unchanged.
        let atFloor = WindowFloor.clamp(width: WindowFloor.minWidth, height: WindowFloor.minHeight)
        #expect(atFloor.width == WindowFloor.minWidth)
        #expect(atFloor.height == WindowFloor.minHeight)
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

    @Test("editor max fraction matches the layout store's clamp ceiling")
    func editorFractionMatchesStore() {
        // The height derivation is only honest if it uses the SAME max fraction the
        // splitter can actually reach.
        #expect(WindowFloor.editorMaxFraction == PanelLayoutStore.editorFractionRange.upperBound)
    }

    @Test("the default size sits at or above the floor on both axes")
    func defaultAboveFloor() {
        #expect(WindowFloor.defaultWidth >= WindowFloor.minWidth)
        #expect(WindowFloor.defaultHeight >= WindowFloor.minHeight)
    }
}
