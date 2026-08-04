import CoreGraphics
import Testing
@testable import DAWAppKit

/// The headless half of m23-ag's proof: the flip/edge arithmetic that turns a rect
/// measured against a window's content view into a top-left origin in the captured
/// image's row space.
///
/// The live half (is the probe anchored on the coordinate space's root? does the
/// reported origin match an ink-derived one?) can only be measured against a running
/// window and is a separate gate. What is pinned HERE is the part that is silently
/// wrong when it is wrong: an unflipped content view needs `height - maxY`, and using
/// `minY` there produces a perfectly plausible number pointing at the wrong rows.
@Suite("Capture space geometry (m23-ag)")
struct CaptureSpaceGeometryTests {

    @Test("Flipped content view: the top edge IS minY")
    func flippedTakesMinY() {
        let rect = CGRect(x: 0, y: 32, width: 1400, height: 968)
        let origin = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 1000, isFlipped: true)
        #expect(origin.x == 0)
        #expect(origin.y == 32)
    }

    @Test("Unflipped content view: the top edge is contentHeight - maxY")
    func unflippedTakesComplementOfMaxY() {
        // Same space, expressed bottom-left: it sits 0 pt off the bottom and 32 pt
        // off the top, so an AppKit rect at y=0 with height 968 in a 1000 pt content
        // view must convert to a top-left y of 32.
        let rect = CGRect(x: 0, y: 0, width: 1400, height: 968)
        let origin = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 1000, isFlipped: false)
        #expect(origin.x == 0)
        #expect(origin.y == 32)
    }

    @Test("The two conventions disagree — so the branch is load-bearing, not cosmetic")
    func flipBranchIsDiscriminating() {
        // The exact trap this function exists to remove: reading `minY` on an
        // unflipped view yields 0 here, which looks like a perfectly reasonable
        // "the space starts at the content origin" and is wrong by 32 pt.
        let rect = CGRect(x: 0, y: 0, width: 1400, height: 968)
        let flipped = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 1000, isFlipped: true)
        let unflipped = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 1000, isFlipped: false)
        #expect(flipped.y != unflipped.y)
        #expect(flipped.y == 0)
        #expect(unflipped.y == 32)
    }

    @Test("A non-zero rect origin is carried, not dropped, on both branches")
    func nonZeroRectOrigin() {
        let rect = CGRect(x: 24.5, y: 17.25, width: 300, height: 200)
        let flipped = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 640, isFlipped: true)
        #expect(flipped.x == 24.5)
        #expect(flipped.y == 17.25)

        let unflipped = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 640, isFlipped: false)
        #expect(unflipped.x == 24.5)
        // 640 - (17.25 + 200)
        #expect(unflipped.y == 422.75)
    }

    @Test("X never depends on the flip — only the vertical convention differs")
    func xIsFlipInvariant() {
        for x in [-12.0, 0.0, 7.5, 298.0] {
            let rect = CGRect(x: x, y: 40, width: 100, height: 50)
            let flipped = CaptureSpaceGeometry.topLeftOrigin(
                of: rect, contentHeight: 900, isFlipped: true)
            let unflipped = CaptureSpaceGeometry.topLeftOrigin(
                of: rect, contentHeight: 900, isFlipped: false)
            #expect(flipped.x == CGFloat(x))
            #expect(unflipped.x == CGFloat(x))
        }
    }

    @Test("A rect spanning the whole content view converts to the origin on both branches")
    func fullSpanIsZeroEitherWay() {
        // The degenerate case a wrong branch also gets right — recorded so nobody
        // mistakes it for evidence: if the space filled the content view, this bug
        // would never have been visible at all.
        let rect = CGRect(x: 0, y: 0, width: 1320, height: 880)
        let flipped = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 880, isFlipped: true)
        let unflipped = CaptureSpaceGeometry.topLeftOrigin(
            of: rect, contentHeight: 880, isFlipped: false)
        #expect(flipped == CGPoint(x: 0, y: 0))
        #expect(unflipped == CGPoint(x: 0, y: 0))
    }
}
