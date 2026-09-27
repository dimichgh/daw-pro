import Testing
import Foundation
import CoreGraphics
@testable import DAWAppKit

/// I6b-S1 — THE EDGE AUTO-SCROLL HOIST. `PianoRollAutoScroll.nextOffset`'s body
/// moved to `EdgeAutoScroll`, which the pitch editor will ask on both axes, and
/// the roll forwards to it.
///
/// What this suite claims, and each claim has a test that can fail:
/// - the forward is BIT-identical to the body it replaced, over a sweep, against
///   a frozen copy of that body kept below as the oracle;
/// - the roll's literal fixtures hold on x AND on y through the 2-D routing,
///   with the other axis made deliberately different so a swapped axis fails;
/// - `push` reports "in the band at the wall" where `nextOffset` can only say
///   nil, including in a pane with NO scroll room (the docked, filled pane);
/// - a held tick RECOMPUTES the pointer from the observed offset on both axes.
///
/// ⚠️ **WHAT IT CANNOT SEE**, as `PianoRollEdgeRepeatTests` says of itself: no
/// test here feels a ramp or watches a note follow a cursor. The growth rate
/// and the band width on y are feel questions for a human hand.
///
/// `PianoRollAutoScrollTests`, `PianoRollEdgeRepeatTests` and
/// `PianoRollEdgeDragSiteTests` are deliberately left untouched: they must stay
/// green against the forward with no edit, which is the other half of the proof.
@Suite("Edge auto-scroll shared core (I6b-S1)")
struct EdgeAutoScrollTests {

    // MARK: - The oracle: the roll's body as it shipped, frozen

    /// `PianoRollAutoScroll.nextOffset` exactly as it read before the hoist
    /// (HEAD 813c415, `Sources/DAWAppKit/PianoRollAutoScroll.swift:110-158`),
    /// including its private `step`. Only the helper names differ, so they
    /// cannot collide with anything in the module.
    ///
    /// ⚠️ **DO NOT "UPDATE" THIS TO MATCH THE SOURCE.** It is the fixed point
    /// the forward is measured against; editing it to follow a change in
    /// `EdgeAutoScroll` turns the sweep into a test that the code equals itself.
    private static func frozenRollNextOffset(
        pointerContentX: CGFloat,
        currentOffset: CGFloat,
        viewportWidth: CGFloat,
        contentWidth: CGFloat
    ) -> CGFloat? {
        let edgeBand: CGFloat = 48
        guard viewportWidth > 0, contentWidth > viewportWidth else { return nil }
        let band = min(edgeBand, viewportWidth / 2)
        guard band > 0 else { return nil }

        let maxOffset = contentWidth - viewportWidth
        let offset = currentOffset.frozenClamped(to: 0...maxOffset)
        let local = pointerContentX - offset

        let delta: CGFloat
        if local < band {
            delta = -frozenStep(depth: band - local, band: band)
        } else if local > viewportWidth - band {
            delta = frozenStep(depth: local - (viewportWidth - band), band: band)
        } else {
            return nil
        }

        let next = (offset + delta).frozenClamped(to: 0...maxOffset)
        return next == offset ? nil : next
    }

    private static func frozenStep(depth: CGFloat, band: CGFloat) -> CGFloat {
        let maxStep: CGFloat = 24
        guard band > 0 else { return 0 }
        let fraction = (depth / band).frozenClamped(to: 0...1)
        return maxStep * fraction
    }

    /// Bit patterns, so a sweep compares bits rather than `==`, which would
    /// call `-0.0` and `0.0` equal and every NaN unequal.
    private static func bits(_ value: CGFloat?) -> UInt? { value.map(\.bitPattern) }

    // MARK: - The forward is the body it replaced, bit for bit

    /// The sweep grid: fractional pointers across and beyond a 5000-long
    /// content, offsets inside, on and outside both walls, viewports through
    /// the degenerate (≤ 0), the narrow (band capped at half) and the normal,
    /// and contents below, at and above the viewport.
    private static let sweepPointers: [CGFloat] =
        stride(from: -200.0, through: 5200.0, by: 7.25).map { CGFloat($0) }
        + [0, 24, 47.5, 48, 48.5, 952, 976, 1000, 1024, 1048]
    private static let sweepOffsets: [CGFloat] = [-5, 0, 10, 1000, 3990, 4000, 9000]
    private static let sweepViewports: [CGFloat] = [-10, 0, 1, 59, 60, 96, 97, 1000]
    private static let sweepContents: [CGFloat] = [0, 500, 1000, 1001, 5000]

    @Test("the roll's forward is BIT-identical to the frozen original over the sweep")
    func forwardMatchesTheFrozenOriginal() {
        var compared = 0
        var mismatches: [String] = []
        var sawNil = false
        var sawValue = false
        for viewport in Self.sweepViewports {
            for content in Self.sweepContents {
                for offset in Self.sweepOffsets {
                    for pointer in Self.sweepPointers {
                        let old = Self.frozenRollNextOffset(
                            pointerContentX: pointer, currentOffset: offset,
                            viewportWidth: viewport, contentWidth: content)
                        let forwarded = PianoRollAutoScroll.nextOffset(
                            pointerContentX: pointer, currentOffset: offset,
                            viewportWidth: viewport, contentWidth: content)
                        let shared = EdgeAutoScroll.nextOffset(
                            pointer: pointer, offset: offset,
                            viewport: viewport, content: content)
                        compared += 1
                        if old == nil { sawNil = true } else { sawValue = true }
                        if Self.bits(forwarded) != Self.bits(old)
                            || Self.bits(shared) != Self.bits(old) {
                            mismatches.append("p \(pointer) o \(offset) v \(viewport) c \(content): "
                                + "old \(String(describing: old)) roll \(String(describing: forwarded)) "
                                + "shared \(String(describing: shared))")
                        }
                    }
                }
            }
        }
        #expect(mismatches.isEmpty,
                "\(mismatches.count) of \(compared) differ; first: \(mismatches.prefix(5))")
        // ANTI-VACUITY: the grid really does reach both answers, so the
        // equality above is not "nil == nil" forty thousand times.
        #expect(sawNil)
        #expect(sawValue)
        #expect(compared > 10_000)
    }

    /// `push(...).next` IS `nextOffset` wherever there is scroll room — the
    /// single-home claim `EdgeAutoScroll.nextOffset`'s doc makes, checked
    /// against the frozen original rather than against the code under test.
    @Test("wherever there IS scroll room, push's next is the original answer, bit for bit")
    func pushNextMatchesTheOriginalWhereThereIsRoom() {
        var compared = 0
        var mismatches: [String] = []
        var sawAtWall = false
        var sawMove = false
        for viewport in Self.sweepViewports where viewport > 0 {
            for content in Self.sweepContents where content > viewport {
                for offset in Self.sweepOffsets {
                    for pointer in Self.sweepPointers {
                        let old = Self.frozenRollNextOffset(
                            pointerContentX: pointer, currentOffset: offset,
                            viewportWidth: viewport, contentWidth: content)
                        let pushed = EdgeAutoScroll.push(
                            pointer: pointer, offset: offset,
                            viewport: viewport, content: content)
                        compared += 1
                        if let pushed { if pushed.isAtWall { sawAtWall = true } else { sawMove = true } }
                        if Self.bits(pushed?.next) != Self.bits(old) {
                            mismatches.append("p \(pointer) o \(offset) v \(viewport) c \(content)")
                        }
                    }
                }
            }
        }
        #expect(mismatches.isEmpty,
                "\(mismatches.count) of \(compared) differ; first: \(mismatches.prefix(5))")
        #expect(sawAtWall)
        #expect(sawMove)
    }

    // MARK: - The roll's literal fixtures, on x AND on y

    /// What a fixture expects of `next`.
    enum Expected: Sendable, CustomStringConvertible {
        /// nil: do not scroll.
        case inert
        /// Exactly this offset.
        case lands(CGFloat)
        /// Some offset above the current one (the roll asserted `!= nil`;
        /// the direction is the stronger, still literal-free form).
        case movesTowardsTrailing
        /// Some offset below the current one.
        case movesTowardsLeading

        var description: String {
            switch self {
            case .inert: "inert"
            case .lands(let value): "lands \(value)"
            case .movesTowardsTrailing: "moves +"
            case .movesTowardsLeading: "moves −"
            }
        }

        func holds(for next: CGFloat?, from offset: CGFloat) -> Bool {
            switch self {
            case .inert: next == nil
            case .lands(let value): next == value
            case .movesTowardsTrailing: next.map { $0 > offset } ?? false
            case .movesTowardsLeading: next.map { $0 < offset } ?? false
            }
        }
    }

    struct Fixture: Sendable, CustomStringConvertible {
        let pointer: CGFloat
        var offset: CGFloat = 1000
        var viewport: CGFloat = 1000
        var content: CGFloat = 5000
        let expected: Expected

        var description: String {
            "pointer \(pointer) offset \(offset) viewport \(viewport) content \(content) → \(expected)"
        }
    }

    /// Every literal `PianoRollAutoScrollTests` pins, transcribed case by case
    /// (its geometry: a 1000 viewport onto 5000 of content at offset 1000,
    /// `edgeBand` 48, `maxStep` 24). Spelled as numbers, not re-derived from
    /// the constants, so a changed constant fails here as it would there.
    static let rollFixtures: [Fixture] = [
        // middleIsInert
        Fixture(pointer: 1500, expected: .inert),
        Fixture(pointer: 1048, expected: .inert),
        Fixture(pointer: 1952, expected: .inert),
        // trailingBandScrolls: half depth, then the edge
        Fixture(pointer: 1976, expected: .lands(1012)),
        Fixture(pointer: 2000, expected: .lands(1024)),
        // leadingBandScrolls
        Fixture(pointer: 1024, expected: .lands(988)),
        Fixture(pointer: 1000, expected: .lands(976)),
        // beyondTheEdgeCaps
        Fixture(pointer: 4000, expected: .lands(1024)),
        Fixture(pointer: -4000, expected: .lands(976)),
        // leadingWallIsQuiet, and its anti-vacuity leg
        Fixture(pointer: 10, offset: 0, expected: .inert),
        Fixture(pointer: 990, offset: 0, expected: .movesTowardsTrailing),
        // trailingWallIsQuiet
        Fixture(pointer: 5000, offset: 4000, expected: .inert),
        Fixture(pointer: 4010, offset: 4000, expected: .movesTowardsLeading),
        // scrollIsClamped
        Fixture(pointer: 10, offset: 10, expected: .lands(0)),
        Fixture(pointer: 5000, offset: 3990, expected: .lands(4000)),
        // nothingToScroll
        Fixture(pointer: 500, offset: 0, viewport: 1000, content: 1000, expected: .inert),
        Fixture(pointer: 500, offset: 0, viewport: 1000, content: 500, expected: .inert),
        // unmeasuredViewportIsInert
        Fixture(pointer: 0, offset: 0, viewport: 0, content: 5000, expected: .inert),
        Fixture(pointer: 0, offset: 0, viewport: -10, content: 5000, expected: .inert),
        // narrowPanelBandsDoNotOverlap
        Fixture(pointer: 30, offset: 0, viewport: 60, content: 5000, expected: .inert),
        Fixture(pointer: 55, offset: 0, viewport: 60, content: 5000, expected: .movesTowardsTrailing),
        Fixture(pointer: 5, offset: 100, viewport: 60, content: 5000, expected: .movesTowardsLeading),
    ]

    enum FixtureAxis: String, Sendable, CaseIterable { case x, y }

    /// The idle axis's geometry: a 300 viewport onto 300 of content with the
    /// pointer in its exact middle. It shares no number with any fixture, so
    /// an implementation that paired x's pointer with y's viewport (or the
    /// reverse) reads the wrong geometry and fails; and its pointer is outside
    /// both bands, so its `Push` must be nil.
    private static let idleLength: CGFloat = 300
    private static let idlePointer: CGFloat = 150

    @Test("the 1-D rule meets every one of the roll's literals")
    func rollFixturesHoldInOneDimension() {
        for fixture in Self.rollFixtures {
            let next = EdgeAutoScroll.nextOffset(
                pointer: fixture.pointer, offset: fixture.offset,
                viewport: fixture.viewport, content: fixture.content)
            #expect(fixture.expected.holds(for: next, from: fixture.offset),
                    "\(fixture): got \(String(describing: next))")
        }
        // The one relation the roll pins between its constants.
        #expect(EdgeAutoScroll.maxStep < EdgeAutoScroll.edgeBand)
        // And the roll's names still read the same values: aliases, not copies.
        #expect(PianoRollAutoScroll.edgeBand == EdgeAutoScroll.edgeBand)
        #expect(PianoRollAutoScroll.maxStep == EdgeAutoScroll.maxStep)
    }

    @Test("the roll's literals hold on BOTH axes through the 2-D routing",
          arguments: FixtureAxis.allCases)
    func rollFixturesHoldOnEachAxis(_ axis: FixtureAxis) {
        let idle = Self.idleLength
        for fixture in Self.rollFixtures {
            let pointer: CGPoint
            let offset: CGPoint
            let viewport: CGSize
            let content: CGSize
            switch axis {
            case .x:
                pointer = CGPoint(x: fixture.pointer, y: Self.idlePointer)
                offset = CGPoint(x: fixture.offset, y: 0)
                viewport = CGSize(width: fixture.viewport, height: idle)
                content = CGSize(width: fixture.content, height: idle)
            case .y:
                pointer = CGPoint(x: Self.idlePointer, y: fixture.pointer)
                offset = CGPoint(x: 0, y: fixture.offset)
                viewport = CGSize(width: idle, height: fixture.viewport)
                content = CGSize(width: idle, height: fixture.content)
            }
            let pushes = EdgeAutoScroll.push(pointer: pointer, offset: offset,
                                             viewport: viewport, content: content,
                                             axes: .both)
            let (active, other) = axis == .x
                ? (pushes.horizontal, pushes.vertical)
                : (pushes.vertical, pushes.horizontal)
            #expect(fixture.expected.holds(for: active?.next, from: fixture.offset),
                    "axis \(axis) \(fixture): got \(String(describing: active))")
            #expect(other == nil, "axis \(axis) \(fixture): the idle axis pushed \(String(describing: other))")
        }
    }

    // MARK: - push: the band at the wall, which nil could not say

    /// ⭐⭐ **THE TRAP THIS STEP WAS BRIEFED ON.** I6c's filled pane is DOCKED:
    /// its window is exactly as tall as the pane, so content == viewport and
    /// there is no scroll room. `nextOffset` bails on that before it looks at
    /// the band, and a `push` that inherited the bail would make growth, the
    /// only thing a drag can do there, unreachable.
    @Test("⭐ a DOCKED pane (content == viewport) still reports the band, at the wall")
    func dockedPaneReportsTheBandAtTheWall() {
        // A 17-row window of 14 pt rows in a pane exactly that tall.
        let height: CGFloat = 17 * 14                    // 238
        // 10 pt from the top: 38 of the 48 pt band deep.
        let top = EdgeAutoScroll.push(pointer: 10, offset: 0, viewport: height, content: height)
        #expect(top?.side == .leading)
        #expect(top?.depthFraction == CGFloat(38) / 48)
        #expect(top?.next == nil)
        #expect(top?.isAtWall == true)
        // At the very bottom edge: full depth, trailing, also at the wall.
        let bottom = EdgeAutoScroll.push(pointer: height, offset: 0, viewport: height, content: height)
        #expect(bottom == EdgeAutoScroll.Push(side: .trailing, depthFraction: 1, next: nil))
        // The middle is outside both bands: nil, not "at the wall".
        #expect(EdgeAutoScroll.push(pointer: height / 2, offset: 0,
                                    viewport: height, content: height) == nil)
        // ⚠️ THE CONTRAST THAT MAKES THIS A TEST OF THE BAIL: for the SAME
        // inputs the roll's rule can only say nil. If `push` said nil too, the
        // two would be indistinguishable here and growth would never fire.
        #expect(EdgeAutoScroll.nextOffset(pointer: 10, offset: 0,
                                          viewport: height, content: height) == nil)
        #expect(EdgeAutoScroll.nextOffset(pointer: height, offset: 0,
                                          viewport: height, content: height) == nil)
    }

    @Test("content SHORTER than the viewport is at the wall on both sides, too")
    func shortContentIsAtTheWallOnBothSides() {
        let top = EdgeAutoScroll.push(pointer: 0, offset: 0, viewport: 1000, content: 500)
        #expect(top == EdgeAutoScroll.Push(side: .leading, depthFraction: 1, next: nil))
        let bottom = EdgeAutoScroll.push(pointer: 990, offset: 0, viewport: 1000, content: 500)
        #expect(bottom?.side == .trailing)
        #expect(bottom?.isAtWall == true)
        // A stale offset left over from a taller layout clamps to 0, the only
        // offset short content has. Pointer 30 is then 18 pt into the leading
        // band (depth 0.375); read against the stale 200 it would be 170 pt
        // PAST the edge, a full-depth push at a rate the user never asked for.
        let stale = EdgeAutoScroll.push(pointer: 30, offset: 200, viewport: 1000, content: 500)
        #expect(stale == EdgeAutoScroll.Push(side: .leading, depthFraction: 0.375, next: nil))
    }

    @Test("with scroll room, the wall and the middle are DIFFERENT answers")
    func atTheWallIsNotOutsideTheBand() {
        // Offset 0 is the leading wall; a pointer in the leading band pushes
        // against it. nextOffset says nil. push says where and how hard.
        let wall = EdgeAutoScroll.push(pointer: 10, offset: 0, viewport: 1000, content: 5000)
        #expect(wall?.side == .leading)
        #expect(wall?.isAtWall == true)
        #expect(EdgeAutoScroll.nextOffset(pointer: 10, offset: 0, viewport: 1000, content: 5000) == nil)
        // The middle: nil from both.
        #expect(EdgeAutoScroll.push(pointer: 500, offset: 0, viewport: 1000, content: 5000) == nil)
        // ANTI-VACUITY: off the wall, the same band moves, and `next` is the
        // scroll the roll would make.
        let moving = EdgeAutoScroll.push(pointer: 1010, offset: 1000, viewport: 1000, content: 5000)
        #expect(moving?.isAtWall == false)
        #expect(moving?.next == EdgeAutoScroll.nextOffset(pointer: 1010, offset: 1000,
                                                          viewport: 1000, content: 5000))
    }

    @Test("depth is 0 at the lip, proportional inside, and capped at 1 past the edge")
    func depthFractionRamps() {
        func depth(_ pointer: CGFloat) -> CGFloat? {
            EdgeAutoScroll.push(pointer: pointer, offset: 0, viewport: 1000, content: 1000)?.depthFraction
        }
        #expect(depth(48) == nil)          // exactly the lip: outside, as the roll has it
        #expect(depth(24) == 0.5)
        #expect(depth(0) == 1)
        #expect(depth(-500) == 1)          // dragged clean off the pane: full, never more
        #expect(depth(976) == 0.5)
        #expect(depth(1000) == 1)
        #expect(depth(1500) == 1)
    }

    @Test("an unmeasured viewport has no band, whatever the pointer")
    func unmeasuredViewportHasNoBand() {
        #expect(EdgeAutoScroll.push(pointer: 0, offset: 0, viewport: 0, content: 0) == nil)
        #expect(EdgeAutoScroll.push(pointer: 0, offset: 0, viewport: -10, content: 5000) == nil)
        // ANTI-VACUITY: one point of viewport and the same pointer is in a band.
        #expect(EdgeAutoScroll.push(pointer: 0, offset: 0, viewport: 1, content: 0) != nil)
    }

    /// ⚠️ **WHY THIS EXISTS: DROPPING THE BAIL MOVED A GUARD.** The roll's
    /// `content > viewport` bail also kept a NaN content from ever building
    /// `0...maxOffset`, and a `ClosedRange` with a NaN bound TRAPS. A crash here
    /// fails the whole run loudly, which is the point of asking.
    @Test("non-finite geometry never traps, and agrees with the original where it has an answer")
    func nonFiniteGeometryNeverTraps() {
        let specials: [CGFloat] = [.nan, .infinity, -.infinity, 0, 10, 1000]
        var pushes = 0
        for pointer in specials {
            for offset in specials {
                for viewport in specials {
                    for content in specials {
                        _ = EdgeAutoScroll.push(pointer: pointer, offset: offset,
                                                viewport: viewport, content: content)
                        pushes += 1
                        let old = Self.frozenRollNextOffset(
                            pointerContentX: pointer, currentOffset: offset,
                            viewportWidth: viewport, contentWidth: content)
                        let forwarded = PianoRollAutoScroll.nextOffset(
                            pointerContentX: pointer, currentOffset: offset,
                            viewportWidth: viewport, contentWidth: content)
                        #expect(Self.bits(forwarded) == Self.bits(old),
                                "p \(pointer) o \(offset) v \(viewport) c \(content)")
                    }
                }
            }
        }
        #expect(pushes == 6 * 6 * 6 * 6)
    }

    // MARK: - The held pointer, on two axes

    /// The pitch pane's shape for the loop below: a 400 × 300 viewport onto
    /// 2000 × 1500 of content, so the maximum offsets are 1600 and 1200 — two
    /// DIFFERENT numbers, so a loop that ran on the wrong axis stops at the
    /// wrong wall.
    private let paneViewport = CGSize(width: 400, height: 300)
    private let paneContent = CGSize(width: 2000, height: 1500)

    @Test("a held pointer's viewport-local point is invariant under scrolling, on each axis")
    func localIsTheInvariantOfAHold() {
        let atRest = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 390, y: 290), origin: .zero, currentOffset: .zero)
        // The SAME physical pointer after the pane scrolled 240 right and 96
        // down under it: the content point moved by exactly the scroll.
        let afterScroll = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 630, y: 386), origin: .zero,
            currentOffset: CGPoint(x: 240, y: 96))
        #expect(atRest.local == afterScroll.local)
        // ANTI-VACUITY, per axis: a different physical position does not
        // collapse to the same local point on either axis.
        let movedY = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 630, y: 400), origin: .zero,
            currentOffset: CGPoint(x: 240, y: 96))
        #expect(movedY.local.x == atRest.local.x)
        #expect(movedY.local.y != atRest.local.y)
    }

    /// ⭐⭐ **RECOMPUTE, NEVER INTEGRATE, AS ONE ASSERTION.** The tick's location
    /// is `local + observedOffset` for ANY observed offset — including one no
    /// tick ever asked for, which is what a scroller that lands late, short or
    /// not at all reports. A tick that advanced by the step it REQUESTED, or
    /// accumulated its own previous answer, disagrees here at once.
    @Test("⭐ a tick's location is local + the OBSERVED offset, even one nobody requested")
    func tickRecomputesFromTheObservation() {
        let held = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 200, y: 290), origin: CGPoint(x: 180, y: 150),
            currentOffset: .zero)
        // 7.5 and 13.25: offsets no 24 pt ramp step lands on.
        for observed in [CGPoint(x: 0, y: 7.5), CGPoint(x: 0, y: 13.25),
                         CGPoint(x: 31, y: 7.5), CGPoint(x: 0, y: 0)] {
            let tick = EdgeAutoScroll.tick(held: held, observedOffset: observed,
                                           viewport: paneViewport, content: paneContent,
                                           axes: .vertical)
            #expect(tick?.location == CGPoint(x: 200 + observed.x, y: 290 + observed.y),
                    "observed \(observed)")
            #expect(tick?.translation == CGSize(width: 200 + observed.x - 180,
                                                height: 290 + observed.y - 150),
                    "observed \(observed)")
        }
        // The tick is a function of its inputs and nothing else: asked twice
        // with the same observation, it answers the same.
        let first = EdgeAutoScroll.tick(held: held, observedOffset: CGPoint(x: 0, y: 7.5),
                                        viewport: paneViewport, content: paneContent,
                                        axes: .vertical)
        let again = EdgeAutoScroll.tick(held: held, observedOffset: CGPoint(x: 0, y: 7.5),
                                        viewport: paneViewport, content: paneContent,
                                        axes: .vertical)
        #expect(first != nil)
        #expect(first == again)
    }

    /// The loop the pane will run on y: tick → the funnel asks `push` of the
    /// synthesised location → the scroller lands → tick again. Returns every
    /// observed offset and every tick.
    private func runVertical(_ held: EdgeAutoScroll.HeldPoint,
                             from start: CGPoint,
                             limit: Int = 5000)
        -> (offsets: [CGPoint], ticks: [EdgeAutoScroll.Tick]) {
        var offset = start
        var offsets = [start]
        var ticks: [EdgeAutoScroll.Tick] = []
        while offsets.count <= limit,
              let tick = EdgeAutoScroll.tick(held: held, observedOffset: offset,
                                             viewport: paneViewport, content: paneContent,
                                             axes: .vertical) {
            ticks.append(tick)
            guard let landed = EdgeAutoScroll.push(
                pointer: tick.location, offset: offset,
                viewport: paneViewport, content: paneContent,
                axes: .vertical).vertical?.next else { break }
            offset = CGPoint(x: offset.x, y: landed)
            offsets.append(offset)
        }
        return (offsets, ticks)
    }

    /// The roll's `heldRepeatKeepsTheNoteUnderTheCursor`, on y. The dragged
    /// note sits at `baseline + translation.height` in content space and is
    /// drawn at that minus the offset; a held pointer's screen y never changes,
    /// so if the note tracks it that difference is constant for the whole run.
    @Test("⭐ held at the bottom edge, the viewport reaches the wall and the note stays under the pointer")
    func heldAtTheBottomEdgeTracksThePointer() throws {
        let held = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 200, y: 300), origin: CGPoint(x: 200, y: 250),
            currentOffset: .zero)
        let (offsets, ticks) = runVertical(held, from: .zero)
        let maxOffsetY = paneContent.height - paneViewport.height     // 1200
        #expect(offsets.last?.y == maxOffsetY)
        // 1200 / 24 = 50 full steps, landing exactly on the wall.
        #expect(offsets.count - 1 == Int((maxOffsetY / EdgeAutoScroll.maxStep).rounded(.up)))
        // x never moved: a vertical-only hold scrolls y and nothing else.
        #expect(Set(offsets.map(\.x)) == [0])

        let baseline: CGFloat = 250
        let screenYs = zip(offsets, ticks).map { offset, tick in
            baseline + tick.translation.height - offset.y
        }
        #expect(screenYs.count > 40)
        #expect(Set(screenYs).count == 1)
        // ANTI-VACUITY: freeze the translation (no recompute) and the same
        // arithmetic drifts by the whole scrolled distance. `#require`, not
        // `ticks[0]`: a broken tick that never fires must FAIL this test, not
        // trap the whole test process and hide every other result (it did,
        // under the axis-swap plant).
        let frozen = try #require(ticks.first).translation.height
        let drifting = offsets.map { baseline + frozen - $0.y }
        #expect((drifting.max() ?? 0) - (drifting.min() ?? 0) == maxOffsetY)
    }

    @Test("axes gate whether a tick is live, never where it says the pointer is")
    func axesGateLivenessOnly() {
        // In the x band (local x 390 of 400), in the middle of y (150 of 300).
        let inXBandOnly = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 390, y: 150), origin: .zero, currentOffset: .zero)
        func tick(_ held: EdgeAutoScroll.HeldPoint, _ axes: EdgeAutoScroll.Axes,
                  observed: CGPoint = .zero) -> EdgeAutoScroll.Tick? {
            EdgeAutoScroll.tick(held: held, observedOffset: observed,
                                viewport: paneViewport, content: paneContent, axes: axes)
        }
        // A note drag pushes on y only: the x band is not its business.
        #expect(tick(inXBandOnly, .vertical) == nil)
        // ANTI-VACUITY: the same pointer IS live for a gesture allowed x.
        #expect(tick(inXBandOnly, .horizontal) != nil)
        #expect(tick(inXBandOnly, .both) != nil)
        #expect(tick(inXBandOnly, []) == nil)

        // In the y band, and the observed x offset is 31: a y-only tick still
        // reports the TRUE content x, because that is what SwiftUI would.
        let inYBand = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 200, y: 295), origin: .zero, currentOffset: .zero)
        let yOnly = tick(inYBand, .vertical, observed: CGPoint(x: 31, y: 0))
        #expect(yOnly?.location == CGPoint(x: 231, y: 295))
    }

    /// ⚠️ **THE DELIBERATE DIVERGENCE FROM THE ROLL, PINNED BOTH WAYS.** The
    /// roll's repeat is nil at the wall because the roll has nothing left to do
    /// there. The pitch pane grows its window there, so its tick must stay live
    /// — in the docked pane, the wall is the ONLY place a held pointer does
    /// anything.
    @Test("⚠️ in a DOCKED pane the held tick is live at the wall, where the roll's is nil")
    func dockedTickIsLiveAtTheWall() {
        let height: CGFloat = 17 * 14                    // 238: content == viewport
        let viewport = CGSize(width: 400, height: height)
        let content = CGSize(width: 400, height: height)
        let atTop = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 200, y: 4), origin: CGPoint(x: 200, y: 120),
            currentOffset: .zero)
        let tick = EdgeAutoScroll.tick(held: atTop, observedOffset: .zero,
                                       viewport: viewport, content: content, axes: .vertical)
        #expect(tick?.location == CGPoint(x: 200, y: 4))
        #expect(tick?.translation == CGSize(width: 0, height: 4 - 120))
        // The roll's repeat, asked the same 1-D question, says nil. If a later
        // edit "unified" the two predicates, one of these lines would flip.
        let roll = PianoRollEdgeRepeat.tick(
            held: PianoRollEdgeRepeat.HeldPointer(
                pointerContentX: 4, pointerContentY: 0, origin: .zero, currentOffset: 0),
            observedOffset: 0, viewportWidth: height, contentWidth: height)
        #expect(roll == nil)
        // And the middle of the docked pane is quiet for both.
        let middle = EdgeAutoScroll.HeldPoint(
            pointer: CGPoint(x: 200, y: height / 2), origin: .zero, currentOffset: .zero)
        #expect(EdgeAutoScroll.tick(held: middle, observedOffset: .zero,
                                    viewport: viewport, content: content, axes: .vertical) == nil)
    }

    @Test("a tick is live exactly where a real event's push is non-nil")
    func tickIsLiveExactlyWherePushIs() {
        // local y probes across both bands, both lips and the middle, at an
        // offset with room both ways and at each wall.
        let localYs: [CGFloat] = [0, 10, 47.9, 48, 150, 252, 252.1, 290, 300]
        let offsetsY: [CGFloat] = [0, 600, 1200]
        var live = 0
        var quiet = 0
        for offsetY in offsetsY {
            for localY in localYs {
                let observed = CGPoint(x: 0, y: offsetY)
                let held = EdgeAutoScroll.HeldPoint(
                    pointer: CGPoint(x: 200, y: localY + offsetY), origin: .zero,
                    currentOffset: observed)
                let tick = EdgeAutoScroll.tick(held: held, observedOffset: observed,
                                               viewport: paneViewport, content: paneContent,
                                               axes: .vertical)
                let push = EdgeAutoScroll.push(pointer: localY + offsetY, offset: offsetY,
                                               viewport: paneViewport.height,
                                               content: paneContent.height)
                #expect((tick != nil) == (push != nil), "local \(localY) offset \(offsetY)")
                if tick != nil { live += 1 } else { quiet += 1 }
            }
        }
        #expect(live > 0)
        #expect(quiet > 0)
    }

    // MARK: - Growth rate

    /// The design said "a semitone per step"; the arithmetic says the roll's
    /// scroll rate, read as rows, is far too fast for pitch, so growth has its
    /// own constant. This pins the value and the reason, not a feel.
    @Test("growth has its own rate, an octave a second, far below the roll's scroll in rows")
    func growthRateIsItsOwnConstant() {
        #expect(EdgeAutoScroll.growthSemitonesPerSecond == 12)
        // The roll's full-depth repeat: one `maxStep` per 16 ms tick, read as
        // 14 pt rows, is ~107 rows a second.
        let tickSeconds = Double(PianoRollEdgeRepeat.interval.components.attoseconds) / 1e18
            + Double(PianoRollEdgeRepeat.interval.components.seconds)
        let rollRowsPerSecond = Double(EdgeAutoScroll.maxStep / PianoRollZoom.defaultRowHeight)
            / tickSeconds
        #expect(rollRowsPerSecond > 100)
        // Growth is under an eighth of that (12 × 8 = 96), so it can be aimed.
        #expect(EdgeAutoScroll.growthSemitonesPerSecond * 8 < rollRowsPerSecond)
    }
}

private extension CGFloat {
    /// The oracle's own clamp, spelled exactly like the original's.
    func frozenClamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
