import CoreGraphics
import Testing
@testable import DAWAppKit

/// m25-j — the arithmetic that turns a measured LAYOUT frame into the DRAWN one.
///
/// Deliberately NOT `@MainActor`: this is pure geometry, it must stay runnable
/// headless, and the tree is at its main-actor suite cap.
///
/// ⚠️ HONEST SCOPE. These prove the arithmetic and nothing else. The defect lived
/// in SwiftUI's measurement, which no headless test can express — the instrument
/// that proves the FIX is `scripts/gates/m25j-clip-frames.mjs`, which drives a
/// real app on staging and checks reported origins against the app's own `ppb`
/// and the sidebar's own row pitch.
@Suite("ExplainGeometry (m25-j)")
struct ExplainGeometryTests {
    @Test("a render offset moves the origin and leaves the size alone")
    func drawnFrameShiftsOriginOnly() {
        let layout = CGRect(x: 298, y: 163, width: 64, height: 34)
        let drawn = ExplainGeometry.drawnFrame(layout: layout,
                                               renderOffset: CGSize(width: 128, height: 40))
        #expect(drawn.origin.x == 426)
        #expect(drawn.origin.y == 203)
        // Size is untouched — `.offset` never resizes, which is exactly why width
        // and height were CORRECT throughout the defect and only x/y were wrong.
        #expect(drawn.size == layout.size)
    }

    @Test("zero offset is the identity — an untagged, unoffset control is unaffected")
    func zeroOffsetIsIdentity() {
        let layout = CGRect(x: 12, y: 7, width: 3, height: 5)
        #expect(ExplainGeometry.drawnFrame(layout: layout, renderOffset: .zero) == layout)
    }

    @Test("negative offsets (a clip dragged left of its rest position) work too")
    func negativeOffset() {
        let drawn = ExplainGeometry.drawnFrame(
            layout: CGRect(x: 298, y: 163, width: 64, height: 34),
            renderOffset: CGSize(width: -64, height: -40))
        #expect(drawn.origin.x == 234)
        #expect(drawn.origin.y == 123)
    }

    @Test("the reported frame is the layout frame plus exactly ONE offset")
    func exactlyOneOffsetIsAdded() {
        // The regression this pins is DOUBLE counting, not under-counting: the
        // first cut inherited the offset down an environment key as well as
        // applying it at the site, and a planted tag inside an offset clip
        // reported x=554 where the clip drew at 426 (the offset twice). MEASURED
        // on staging — see `ExplainGeometry`'s own note.
        let layout = CGRect(x: 298, y: 163, width: 64, height: 34)
        let once = ExplainGeometry.drawnFrame(layout: layout,
                                              renderOffset: CGSize(width: 128, height: 40))
        #expect(once.origin.x == 426)
        let twice = ExplainGeometry.drawnFrame(layout: once,
                                               renderOffset: CGSize(width: 128, height: 40))
        #expect(twice.origin.x == 554)
        #expect(once.origin.x != twice.origin.x)
    }
}
