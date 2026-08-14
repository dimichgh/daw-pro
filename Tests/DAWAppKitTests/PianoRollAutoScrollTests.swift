import Testing
import Foundation
import CoreGraphics
@testable import DAWAppKit

/// m25-f-3 — EDGE-DRAG AUTO-SCROLL. *"as user moves close to the edge of the
/// note, it should expand/scroll the note area as well as auto extend clip if it
/// reaches the edge."*
///
/// Nothing in this tree can see a real drag (m23-g1: an unbundled staging binary
/// does not route real pointer events), so the pure policy is where the rule is
/// actually pinned. The wiring — that the drag calls it, and that the result
/// travels the manual-scroll seam rather than writing the persisted follow
/// enable — is pinned by `PianoRollEdgeDragSiteTests`.
@Suite("Piano roll edge auto-scroll (m25-f-3)")
struct PianoRollAutoScrollTests {

    /// A viewport 1000 wide onto 5000 of content, currently at offset 1000.
    /// So the visible window is content x 1000...2000, and the maximum offset is
    /// 4000. Every number below is derived from these, never discovered.
    private let viewport: CGFloat = 1000
    private let content: CGFloat = 5000
    private let offset: CGFloat = 1000

    private func next(_ pointerContentX: CGFloat,
                      offset: CGFloat? = nil,
                      viewport: CGFloat? = nil,
                      content: CGFloat? = nil) -> CGFloat? {
        PianoRollAutoScroll.nextOffset(
            pointerContentX: pointerContentX,
            currentOffset: offset ?? self.offset,
            viewportWidth: viewport ?? self.viewport,
            contentWidth: content ?? self.content)
    }

    // MARK: - The inert middle

    @Test("the middle of the viewport does not scroll AT ALL — nil, not the current offset")
    func middleIsInert() {
        // ⚠️ NIL IS LOAD-BEARING, not a style choice. The caller turns any
        // non-nil answer into a `scrollExternally` call, which bumps a nonce
        // three `ScrollViewReader`s watch. Returning the current offset here
        // would fire a `scrollTo` storm through the grid, the velocity lane and
        // the controller strip on every tick of every drag.
        #expect(next(1500) == nil)
        // Just inside each lip: the band is 48, so 1048 and 1952 are the first
        // inert points.
        #expect(next(1048) == nil)
        #expect(next(1952) == nil)
    }

    // MARK: - The bands

    @Test("the TRAILING band scrolls right, PROPORTIONALLY to depth")
    func trailingBandScrolls() {
        // Depth 24 of a 48 band = half of maxStep = 12.
        let half = next(1976)
        #expect(half == offset + PianoRollAutoScroll.maxStep / 2)
        // At the viewport edge exactly: full step.
        let full = next(2000)
        #expect(full == offset + PianoRollAutoScroll.maxStep)
        // ANTI-VACUITY: the two are DIFFERENT, so "proportional" is measured
        // rather than asserted — a constant-step implementation passes the
        // `full` leg alone.
        #expect(half != full)
    }

    @Test("the LEADING band scrolls left, proportionally")
    func leadingBandScrolls() {
        #expect(next(1024) == offset - PianoRollAutoScroll.maxStep / 2)
        #expect(next(1000) == offset - PianoRollAutoScroll.maxStep)
    }

    @Test("a pointer dragged clean OUT of the viewport scrolls at full speed, never faster")
    func beyondTheEdgeCaps() {
        // The fraction is clamped, so an off-window pointer does not produce a
        // step proportional to how far off it went — a drag flung to the far
        // side of the screen must not teleport the viewport.
        #expect(next(4000) == offset + PianoRollAutoScroll.maxStep)
        #expect(next(-4000) == offset - PianoRollAutoScroll.maxStep)
    }

    @Test("one tick never carries the content further than the band is wide")
    func stepCannotOutrunTheBand() {
        // Why it matters: if a tick could jump further than `edgeBand`, the
        // pointer would fall OUT of the band it is steering through, and the
        // scroll would stutter instead of running.
        #expect(PianoRollAutoScroll.maxStep < PianoRollAutoScroll.edgeBand)
    }

    // MARK: - The walls

    @Test("already at the leading wall → nil, so no nonce and no scrollTo storm")
    func leadingWallIsQuiet() {
        // Offset 0, pointer in the leading band: there is nowhere to go.
        #expect(next(10, offset: 0) == nil)
        // ANTI-VACUITY: one point further in, still at offset 0, the TRAILING
        // band does move — so the nil above is the wall, not a dead function.
        #expect(next(990, offset: 0) != nil)
    }

    @Test("already at the trailing wall → nil")
    func trailingWallIsQuiet() {
        let maxOffset = content - viewport      // 4000
        #expect(next(maxOffset + viewport, offset: maxOffset) == nil)
        #expect(next(maxOffset + 10, offset: maxOffset) != nil)   // leading band still free
    }

    @Test("a scroll is CLAMPED to the content, never past either end")
    func scrollIsClamped() {
        // 10 points from the leading wall with a full step asked for.
        let landing = next(10, offset: 10)
        #expect(landing == 0)
        let maxOffset = content - viewport
        let far = next(maxOffset + viewport, offset: maxOffset - 10)
        #expect(far == maxOffset)
    }

    // MARK: - Degenerate geometry

    @Test("content that fits the viewport never scrolls")
    func nothingToScroll() {
        #expect(next(500, offset: 0, viewport: 1000, content: 1000) == nil)
        #expect(next(500, offset: 0, viewport: 1000, content: 500) == nil)
    }

    @Test("a zero or negative viewport is inert — a band before its first layout pass")
    func unmeasuredViewportIsInert() {
        // A drag CAN be delivered in that window, so this is a real path rather
        // than a defensive formality.
        #expect(next(0, offset: 0, viewport: 0, content: 5000) == nil)
        #expect(next(0, offset: 0, viewport: -10, content: 5000) == nil)
    }

    @Test("⚠️ in a NARROW panel the two bands cannot overlap and fight")
    func narrowPanelBandsDoNotOverlap() {
        // 60 wide is narrower than two 48 bands, so an uncapped band would make
        // EVERY pointer position "at an edge" — with the trailing test winning,
        // so a narrow panel would scroll right no matter which way the user
        // dragged. The band is capped at half the viewport, which leaves the
        // exact centre inert.
        let centre = next(30, offset: 0, viewport: 60, content: 5000)
        #expect(centre == nil)
        // And each half still works, in the right direction.
        let right = next(55, offset: 0, viewport: 60, content: 5000)
        #expect(right != nil)
        #expect((right ?? 0) > 0)
        let left = next(5, offset: 100, viewport: 60, content: 5000)
        #expect(left != nil)
        #expect((left ?? 0) < 100)
    }
}
