import Testing
import CoreGraphics
import DAWAppKit

/// m34-a-3 — **VERTICAL FOLLOW TO THE ARMED ROW: THE LANDING RULE.**
///
/// ✅ Ruled in by the user: *"Yes"* — recording on track 12 of 14 while staring
/// at tracks 1–6 is as useless as not following time at all.
///
/// ⛔⛔ **BUT IT IS NOT SYMMETRIC WITH HORIZONTAL FOLLOW, AND THIS SUITE IS
/// WHERE THAT ASYMMETRY IS PINNED.** The horizontal axis follows a playhead that
/// moves on its own and pages when it nears an edge. The vertical axis follows a
/// ROW THAT DOES NOT MOVE, and a performer scrolls vertically ON PURPOSE — to
/// watch another track while a take runs. So the rule is *reveal only when the
/// row is entirely out of view*, and **never re-centre a row that is already
/// visible**. Half of the tests below exist to prove the NO-SCROLL cases, which
/// is the half a symmetric implementation would fail.
///
/// ⭐ **THESE ARE BEHAVIOURAL, NOT SOURCE-SHAPED** — a spy gate beats a
/// source-shape gate. `FollowPlayhead` and `FollowPlayheadModel` live in
/// `DAWAppKit` and can simply be exercised; the source-shape half (which flag
/// the app's two vertical call sites read) is `ArrangeFollowEnableSiteTests`,
/// and it is there only because that pairing is invisible to any behavioural
/// test.
@Suite("Vertical follow to the armed row (m34-a-3)")
struct ArrangeVerticalFollowTests {

    // A 14-row session at 40 pt per row in a 300 pt viewport: rows 0-7 fit,
    // the rest do not. Content 560, so `maxOffset` is 260.
    private static let rowH: CGFloat = 40
    private static let viewport: CGFloat = 300
    private static let content: CGFloat = 560
    private static func rowTop(_ index: Int) -> CGFloat { CGFloat(index) * rowH }

    private static func reveal(row: Int, offset: CGFloat) -> FollowPlayhead.RowReveal? {
        FollowPlayhead.rowReveal(rowTop: rowTop(row), rowHeight: rowH,
                                 viewportHeight: viewport, contentHeight: content,
                                 currentOffset: offset)
    }

    // MARK: - The no-scroll half (what a symmetric implementation gets wrong)

    @Test("⛔⛔ a row that is ALREADY VISIBLE is never re-centred — the whole asymmetry")
    func aVisibleRowIsNeverRecentred() {
        // POSITIVE CONTROL FIRST: this fixture can produce a reveal, so every
        // nil below is attributable to the rule and not to dead geometry.
        #expect(Self.reveal(row: 12, offset: 0) != nil,
                "fixture cannot reveal anything — every nil in this suite would be vacuous")

        // At offset 0 the viewport shows content y 0…300, i.e. rows 0…6 whole
        // and row 7 partly. NONE of them may move the view.
        for row in 0...7 {
            #expect(Self.reveal(row: row, offset: 0) == nil,
                    "row \(row) is visible at offset 0 and must not be scrolled to")
        }
        // The same claim from a scrolled position: at offset 200 the viewport
        // shows y 200…500, i.e. rows 5…12.
        for row in 5...12 {
            #expect(Self.reveal(row: row, offset: 200) == nil,
                    "row \(row) is visible at offset 200 and must not be scrolled to")
        }
    }

    @Test("a PARTIALLY visible row is left alone — strict 'entirely out', the conservative direction")
    func aPartiallyVisibleRowIsLeftAlone() {
        // Offset 10: the viewport is y 10…310. Row 7 spans 280…320, so 30 of its
        // 40 pt are showing. Being too shy here is far cheaper than fighting a
        // deliberate scroll.
        #expect(Self.reveal(row: 7, offset: 10) == nil)
        // And row 0 spans 0…40 with 30 pt showing at the top edge.
        #expect(Self.reveal(row: 0, offset: 10) == nil)
    }

    @Test("a row TALLER than the viewport needs no special case — any part showing is enough")
    func aRowTallerThanTheViewportIsNotSpecial() {
        let tall = FollowPlayhead.rowReveal(rowTop: 100, rowHeight: 500,
                                            viewportHeight: Self.viewport,
                                            contentHeight: 900, currentOffset: 200)
        #expect(tall == nil, "part of the row fills the whole viewport — there is nothing to reveal")
    }

    @Test("a zero-height viewport or row (a view not laid out yet) reveals nothing")
    func unlaidOutGeometryRevealsNothing() {
        #expect(FollowPlayhead.rowReveal(rowTop: 400, rowHeight: Self.rowH, viewportHeight: 0,
                                         contentHeight: Self.content, currentOffset: 0) == nil)
        #expect(FollowPlayhead.rowReveal(rowTop: 400, rowHeight: 0, viewportHeight: Self.viewport,
                                         contentHeight: Self.content, currentOffset: 0) == nil)
    }

    // MARK: - The reveal half

    @Test("⭐ a row entirely BELOW the viewport is revealed against the BOTTOM edge")
    func aRowBelowIsRevealedAtTheBottom() {
        // Row 12 spans 480…520; at offset 0 the viewport ends at 300.
        let reveal = try? #require(Self.reveal(row: 12, offset: 0))
        #expect(reveal?.anchorsBottom == true)
        #expect(reveal?.offset == 220, "expected rowBottom(520) − viewport(300), got \(String(describing: reveal?.offset))")
    }

    @Test("⭐ a row entirely ABOVE the viewport is revealed against the TOP edge")
    func aRowAboveIsRevealedAtTheTop() {
        // At offset 400 the viewport is y 400…700; row 2 spans 80…120.
        let reveal = try? #require(Self.reveal(row: 2, offset: 400))
        #expect(reveal?.anchorsBottom == false)
        #expect(reveal?.offset == 80)
    }

    @Test("⚠️ the offset is CLAMPED at the top as well as floored at 0 — the m25-b-4 rule, borrowed")
    func theOffsetIsClampedAtBothEnds() {
        // The last row: 13 spans 520…560. Its bottom-anchored target is
        // 560 − 300 = 260, which is exactly `maxOffset` — asking for more would
        // scroll past the end of the content.
        let last = try? #require(Self.reveal(row: 13, offset: 0))
        #expect(last?.offset == 260)
        #expect((last?.offset ?? 999) <= FollowPlayhead.maxOffset(contentWidth: Self.content,
                                                                  viewportWidth: Self.viewport))

        // ⭐ AGAINST THE **NEW** CONTENT HEIGHT, which is the half of m25-b-4's
        // rule that is easy to lose: the arrange's row heights are variable, so
        // the ceiling moves. With a SHORTER content the same row must clamp
        // lower, not to the value the old height implied.
        let shorter = FollowPlayhead.rowReveal(rowTop: 520, rowHeight: Self.rowH,
                                               viewportHeight: Self.viewport,
                                               contentHeight: 400, currentOffset: 0)
        #expect(shorter?.offset == 100, "clamped against the OLD height — got \(String(describing: shorter?.offset))")

        // And never below zero: a content shorter than the viewport can only sit at 0.
        let tiny = FollowPlayhead.rowReveal(rowTop: 0, rowHeight: Self.rowH,
                                            viewportHeight: Self.viewport,
                                            contentHeight: 120, currentOffset: 250)
        #expect((tiny?.offset ?? 0) >= 0)
    }

    // MARK: - The runtime: one policy, reused

    @MainActor
    @Test("⭐⭐ the vertical runtime obeys the SHIPPED suspend/rearm policy, not a second one")
    func theVerticalRuntimeReusesTheSuspensionPolicy() {
        let model = FollowPlayheadModel()
        func target(_ offset: CGFloat = 0) -> FollowPlayhead.RowReveal? {
            model.rowRevealTarget(isEnabled: true, isPlaying: true,
                                  rowTop: Self.rowTop(12), rowHeight: Self.rowH,
                                  viewportHeight: Self.viewport, contentHeight: Self.content,
                                  currentOffset: offset)
        }
        #expect(target() != nil, "positive control: the fixture must reveal when un-suspended")

        // A MANUAL SCROLL suspends this surface — the same detector, unchanged.
        model.reportOffset(123, isEnabled: true, isPlaying: true,
                           contentWidth: Self.content, viewportWidth: Self.viewport)
        model.reportOffset(456, isEnabled: true, isPlaying: true,
                           contentWidth: Self.content, viewportWidth: Self.viewport)
        #expect(model.isSuspended, "an unexpected vertical offset must suspend, exactly as on the horizontal axis")
        #expect(target() == nil, "a suspended vertical follow must issue nothing")

        // And the transport-start re-arm clears it, so a stand-down never
        // outlives its take.
        model.rearm()
        #expect(!model.isSuspended)
        #expect(target() != nil, "rearm() did not restore vertical follow")

        // The chip's press stands BOTH axes down through the same state.
        model.standDown()
        #expect(model.isSuspended)
        #expect(target() == nil)
    }

    @MainActor
    @Test("the enable and isPlaying guards are the horizontal ones, verbatim")
    func theGuardsMatchTheHorizontalAxis() {
        let model = FollowPlayheadModel()
        func target(enabled: Bool, playing: Bool) -> FollowPlayhead.RowReveal? {
            model.rowRevealTarget(isEnabled: enabled, isPlaying: playing,
                                  rowTop: Self.rowTop(12), rowHeight: Self.rowH,
                                  viewportHeight: Self.viewport, contentHeight: Self.content,
                                  currentOffset: 0)
        }
        #expect(target(enabled: false, playing: true) == nil)
        #expect(target(enabled: true, playing: false) == nil)
        #expect(target(enabled: true, playing: true) != nil, "positive control")
    }

    @MainActor
    @Test("⭐ an issued reveal REGISTERS its offset, so the proxy's landing is not blamed on the user")
    func anIssuedRevealSeedsTheDetector() {
        let model = FollowPlayheadModel()
        let reveal = model.rowRevealTarget(isEnabled: true, isPlaying: true,
                                           rowTop: Self.rowTop(12), rowHeight: Self.rowH,
                                           viewportHeight: Self.viewport,
                                           contentHeight: Self.content, currentOffset: 0)
        #expect(reveal != nil)
        #expect(model.expectedOffset == reveal?.offset,
                "the issued offset must become the detector's baseline")

        // The landing comes back slightly off (a `scrollTo` anchors, it does not
        // take an offset). It must be absorbed as OUR issue, never read as a drag.
        model.reportOffset((reveal?.offset ?? 0) + 7, isEnabled: true, isPlaying: true,
                           contentWidth: Self.content, viewportWidth: Self.viewport)
        #expect(!model.isSuspended, """
            The landing of a reveal WE issued suspended follow. The vertical scroll \
            lands by anchor, not by offset, so its report is always a few points off \
            what was asked for — blaming the user for it would stand follow down on \
            the very first reveal of every take.
            """)
    }
}
