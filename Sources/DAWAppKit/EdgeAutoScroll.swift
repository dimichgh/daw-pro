import CoreGraphics
import Foundation

/// EDGE AUTO-SCROLL, ONE RULE FOR EVERY AXIS (I6b-S1) — the arithmetic the
/// piano roll shipped as `PianoRollAutoScroll` (m25-f-3), hoisted so the pitch
/// editor can use it on BOTH axes without a second copy. Pure geometry, no
/// store, no SwiftUI, for the reason the roll's banner gives: nothing in this
/// tree can drive a real pointer (m23-g1), so the rule is pinned where a
/// headless test can reach it.
///
/// ═══ WHAT MOVED, AND WHAT DID NOT ═══
///
/// `nextOffset` is the roll's 1-D body. `PianoRollAutoScroll.nextOffset` keeps
/// its name, signature and constants and FORWARDS here, so the roll's pinned
/// literals and its m25-r repeat run through this file unchanged.
/// `EdgeAutoScrollTests` proves the forward bit-identical against a frozen copy
/// of the original body over a sweep. The roll's banner — including its
/// retracted no-timer objection and the paragraph that must not be deleted —
/// stays in `PianoRollAutoScroll.swift`, and it binds this file too.
///
/// The pitch pane asks it per axis with I0's viewport: pitch drags on y, bands
/// on x and y. **The function has no axis of its own**: `pointer`, `offset`,
/// `viewport` and `content` are one axis's four numbers. The 2-D entry points
/// below route each axis to it and nothing else, so an axis mix-up has exactly
/// one place to happen and one test (the roll's fixtures on x AND y) to fail.
///
/// ═══ WHAT IS NEW: `push`, BECAUSE nil MEANT TWO THINGS ═══
///
/// `nextOffset`'s nil is load-bearing for the roll (no nonce, no `scrollTo`
/// storm) and it answers only "should the viewport move?". It conflates three
/// states the pitch pane must tell apart: the pointer is outside the band; the
/// pointer is in the band but the viewport sits against the wall it is pushing
/// towards; and there is no scroll room at all. **The pitch pane GROWS its
/// window exactly where the roll does nothing** (design §9, "vertical means
/// GROWTH, not only scroll"), so it needs the second and third states named.
///
/// ⚠️ **`push` DOES NOT INHERIT `nextOffset`'s `content > viewport` BAIL, AND
/// THAT IS THE POINT OF IT.** I6c's filled pane is docked: a 17-row window in a
/// 17-row pane has content == viewport and zero scroll room, so `nextOffset`
/// returns nil before it ever looks at the band. Growth is the ONLY thing a
/// drag can do there, and a `push` that bailed the same way would make growth
/// unreachable in the one pane shape where it is the whole feature. `push`
/// treats content ≤ viewport as "at the wall on both sides" and still reports
/// which band the pointer is in and how deep.
public enum EdgeAutoScroll {

    /// How wide the hot band at each viewport edge is, in points — per axis.
    ///
    /// The value was set by the roll (see `PianoRollAutoScroll.edgeBand` for
    /// why 48 is a note's own scale there) and the pitch pane reuses it as a
    /// delegated default (I6b survey). On the pitch pane's y axis 48 pt is
    /// about three and a half 14 pt rows, so a pause near the top or bottom row
    /// can creep once the held repeat lands; whether that feels right needs a
    /// human hand.
    public static let edgeBand: CGFloat = 48

    /// The most one pointer event may scroll, in points, reached only at the
    /// very edge of the viewport. The roll's value, with the roll's corrected
    /// rationale (`PianoRollAutoScroll.maxStep`).
    public static let maxStep: CGFloat = 24

    /// How fast the pitch pane's window GROWS at full band depth, in semitones
    /// per second. The rate scales with `Push.depthFraction`, like the scroll.
    ///
    /// ⚠️ **A SEPARATE CONSTANT, NOT `maxStep` IN ROWS, AND THE ARITHMETIC IS
    /// WHY.** At the pane's 14 pt default row height, `maxStep` is ~1.7 rows per
    /// event, and at the 60 Hz the roll's repeat assumes that is about 100
    /// semitones per second: the whole 0...127 range in under two seconds, far
    /// too fast to aim a note with. The design's "a semitone per step" was
    /// written without that number. 12 is one octave per second at full depth.
    /// It is a DELEGATED DEFAULT: the arithmetic says it can be aimed, and only
    /// a human hand can say it feels right.
    ///
    /// The fractional remainder between whole rows is GROWTH STATE owned by the
    /// model and reset per press, never pointer integration (I6b S2).
    public static let growthSemitonesPerSecond: Double = 12

    /// Which end of an axis the pointer is pushing towards.
    ///
    /// ON y, `.leading` IS THE TOP, and the pitch pane draws its highest pitch
    /// at the top (`y(forMidi:)` counts down from `midiRange.upperBound`), so
    /// `.leading` means HIGHER notes and `.trailing` means lower ones. On x,
    /// `.leading` is earlier time.
    public enum Side: Equatable, Sendable {
        /// Towards offset 0: left on x, the top (higher pitch) on y.
        case leading
        /// Towards the maximum offset: right on x, the bottom on y.
        case trailing
    }

    /// A pointer inside an edge band, and what it asks for.
    public struct Push: Equatable, Sendable {
        /// The band the pointer is in.
        public let side: Side
        /// How deep into the band, `0...1` — 0 at the band's inner lip, 1 at
        /// the viewport edge and beyond. The same fraction the scroll step
        /// uses, so a growth rate scaled by it ramps exactly like the scroll.
        public let depthFraction: CGFloat
        /// The new offset, or **nil when the viewport already sits against the
        /// wall on `side`**, including when there is no scroll room at all. It
        /// is the value `nextOffset` returns whenever there IS scroll room.
        public let next: CGFloat?

        public init(side: Side, depthFraction: CGFloat, next: CGFloat?) {
            self.side = side
            self.depthFraction = depthFraction
            self.next = next
        }

        /// In the band with nowhere left to scroll — the state where the pitch
        /// pane grows its window instead.
        public var isAtWall: Bool { next == nil }
    }

    // MARK: - One axis

    /// The next content offset along one axis for a drag whose pointer is at
    /// `pointer`, or **nil to leave the viewport exactly where it is** — the
    /// roll's m25-f-3 rule, and its nil is load-bearing for the same reason
    /// (`PianoRollAutoScroll`'s banner: a non-nil answer fires a scroll nonce).
    ///
    /// - Parameters:
    ///   - pointer: the pointer on this axis in the scrolling CONTENT's space —
    ///     `DragGesture.Value.location` as the content sees it.
    ///   - offset: the content coordinate currently at the viewport's leading
    ///     edge, `>= 0`.
    ///   - viewport: the visible length on this axis.
    ///   - content: the full drawn length on this axis.
    /// - Returns: a new offset in `0...(content - viewport)`, or nil.
    ///
    /// ⚠️ **THE ROLL'S BODY, SPLIT AT ITS FIRST GUARD, NOT RETYPED.** The roll's
    /// first guard (no scroll room, or an unmeasured viewport) stays here; every
    /// line after it is `push`, in the original operation order, so there is one
    /// home for the band, the ramp and the walls. With scroll room, `push`'s
    /// maximum offset is `content - viewport` exactly and negating a step is
    /// exact, which is why the forward is bit-identical rather than
    /// merely close — and `EdgeAutoScrollTests` checks the bits, not the claim.
    public static func nextOffset(
        pointer: CGFloat,
        offset: CGFloat,
        viewport: CGFloat,
        content: CGFloat
    ) -> CGFloat? {
        // A viewport that cannot show less than everything has nothing to
        // scroll. Also the degenerate-geometry guard: a zero or negative
        // viewport is what a pane reports before its first layout pass, and a
        // drag can be delivered in that window.
        guard viewport > 0, content > viewport else { return nil }
        return push(pointer: pointer, offset: offset,
                    viewport: viewport, content: content)?.next
    }

    /// Where the pointer is pushing along one axis: **nil when it is outside
    /// both bands** (or the viewport is unmeasured), otherwise the band, the
    /// depth and the scroll — whose `next` is nil at the wall.
    ///
    /// ⚠️ **NO `content > viewport` BAIL HERE — see the banner.** Content that
    /// fits the viewport clamps the offset to 0 and every scroll to 0, so both
    /// sides report `isAtWall`, and the band and depth are still measured. The
    /// unmeasured-viewport guard DOES stay: a 0 or negative viewport has no
    /// band to be in.
    public static func push(
        pointer: CGFloat,
        offset currentOffset: CGFloat,
        viewport: CGFloat,
        content: CGFloat
    ) -> Push? {
        guard viewport > 0 else { return nil }
        // The band cannot be wider than half the viewport, or the two hot zones
        // would overlap in the middle and every pointer position would be "at an
        // edge" — with the trailing test winning, so a narrow panel would scroll
        // right no matter which way the user dragged.
        let band = min(edgeBand, viewport / 2)
        guard band > 0 else { return nil }

        // No scroll room is a maximum offset of 0, not a reason to stop looking:
        // the pointer can still be in a band, and the pitch pane grows there.
        // ⚠️ A comparison, not `max(room, 0)`: `Swift.max(NaN, 0)` is NaN, and
        // `0...NaN` TRAPS. The roll's bail kept a NaN content from ever reaching
        // a range; without the bail this line is where that guard has to live.
        let room = content - viewport
        let maxOffset = room > 0 ? room : 0
        let offset = currentOffset.clamped(to: 0...maxOffset)
        // The pointer's position WITHIN the visible window.
        let local = pointer - offset

        let side: Side
        let depth: CGFloat
        if local < band {
            // Leading edge. Depth is measured from the band's inner lip, and is
            // allowed to exceed `band` when the pointer has been dragged past
            // the viewport entirely — capped below, so an off-window pointer
            // scrolls at full speed rather than wrapping to some other rate.
            side = .leading
            depth = band - local
        } else if local > viewport - band {
            side = .trailing
            depth = local - (viewport - band)
        } else {
            return nil
        }

        let fraction = (depth / band).clamped(to: 0...1)
        let step = maxStep * fraction
        let delta = side == .leading ? -step : step
        let next = (offset + delta).clamped(to: 0...maxOffset)
        // Already against the wall the pointer is pushing towards: no movement,
        // so no nonce, so no `scrollTo` storm at the ends of the content.
        return Push(side: side, depthFraction: fraction,
                    next: next == offset ? nil : next)
    }

    // MARK: - Two axes

    /// Which axes a gesture may push along. The pitch pane decides per press
    /// kind (I6b S3): a note drag pushes on y only, a band on x and y.
    public struct Axes: OptionSet, Equatable, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let horizontal = Axes(rawValue: 1 << 0)
        public static let vertical = Axes(rawValue: 1 << 1)
        public static let both: Axes = [.horizontal, .vertical]
    }

    /// One `Push` per axis; nil on an axis that is not enabled or whose pointer
    /// is outside both of its bands.
    public struct Pushes: Equatable, Sendable {
        public let horizontal: Push?
        public let vertical: Push?

        public init(horizontal: Push?, vertical: Push?) {
            self.horizontal = horizontal
            self.vertical = vertical
        }

        /// No enabled axis has its pointer in a band.
        public var isEmpty: Bool { horizontal == nil && vertical == nil }
    }

    /// `push` asked of each enabled axis, x with the widths and y with the
    /// heights. This routing is the ONLY place the 2-D callers pair a pointer
    /// coordinate with a viewport dimension, so an axis mix-up has one home.
    public static func push(
        pointer: CGPoint,
        offset: CGPoint,
        viewport: CGSize,
        content: CGSize,
        axes: Axes
    ) -> Pushes {
        Pushes(
            horizontal: axes.contains(.horizontal)
                ? push(pointer: pointer.x, offset: offset.x,
                       viewport: viewport.width, content: content.width)
                : nil,
            vertical: axes.contains(.vertical)
                ? push(pointer: pointer.y, offset: offset.y,
                       viewport: viewport.height, content: content.height)
                : nil)
    }

    // MARK: - The held pointer, on two axes

    /// The last REAL pointer event of a live drag, in the only form a repeat
    /// can use — `PianoRollEdgeRepeat.HeldPointer` on both axes.
    ///
    /// ⚠️ **`local` IS THE POINT OF THIS TYPE, AS `localX` IS THE ROLL'S.** A
    /// held pointer's CONTENT position changes only because the content moved;
    /// its VIEWPORT-LOCAL position is the invariant of the hold, on each axis
    /// independently. Store that, and every tick rebuilds the content position
    /// from scratch instead of nudging it. The pair `(pointer, currentOffset)`
    /// must be read from the SAME laid-out geometry, or `local` absorbs the
    /// discrepancy.
    ///
    /// The roll's type fixes the content y because the roll has no vertical
    /// edge scroll. The pitch pane does, so y is recomputed exactly like x.
    public struct HeldPoint: Equatable, Sendable {
        /// The pointer within the visible viewport, invariant while held.
        public var local: CGPoint
        /// `DragGesture.Value.startLocation`, a fixed CONTENT point, so
        /// `location - origin` reproduces SwiftUI's own `translation`.
        public var origin: CGPoint

        public init(pointer: CGPoint, origin: CGPoint, currentOffset: CGPoint) {
            self.local = CGPoint(x: pointer.x - currentOffset.x,
                                 y: pointer.y - currentOffset.y)
            self.origin = origin
        }
    }

    /// The synthesised pointer for one repeat tick: the two quantities the
    /// pane's drag funnel consumes, and nothing else.
    ///
    /// ⚠️ **NO SCROLL TARGET AND NO GROWTH HERE, DELIBERATELY** — the roll's
    /// rule (`PianoRollEdgeRepeat.Tick`). The tick feeds the SAME funnel a real
    /// event does, and that funnel asks `push` itself. A target here would be a
    /// second answer to "where should the viewport go".
    public struct Tick: Equatable, Sendable {
        /// The pointer in CONTENT space, recomputed from the observed offset.
        public let location: CGPoint
        /// `location - origin`: SwiftUI's `DragGesture.Value.translation` for a
        /// still pointer over content that has scrolled.
        public let translation: CGSize

        public init(location: CGPoint, translation: CGSize) {
            self.location = location
            self.translation = translation
        }
    }

    /// The tick for a pointer HELD still at `held`, or **nil when no enabled
    /// axis has its pointer in a band**.
    ///
    /// ⭐ **RECOMPUTE, NEVER INTEGRATE** (`PianoRollAutoScroll`'s retracted
    /// objection and `PianoRollEdgeRepeat`'s answer to it). The location is
    /// `local + observedOffset` on BOTH axes, rebuilt from scratch every tick,
    /// and it is exactly what SwiftUI reports, because the pane's gesture
    /// resolves in the scrolling content's space on both axes. `axes` gates
    /// whether the tick is live; it never changes the location, so a note drag
    /// that is only allowed y still reports the true x.
    ///
    /// ⚠️ **LIVE AT THE WALL, UNLIKE THE ROLL — A DELIBERATE DIVERGENCE.**
    /// `PianoRollEdgeRepeat.tick` is nil when the viewport already sits against
    /// the wall, because at the wall the roll has nothing left to do. The pitch
    /// pane grows its window there, so this tick stays live whenever the pointer
    /// is in a band on an enabled axis, wall or not. **The cost, stated:** a
    /// held band at a wall with no scroll room synthesises ticks that change
    /// nothing, at most one per `PianoRollEdgeRepeat.interval`; the funnel's own
    /// `push` returns a nil `next`, so no nonce fires. The runaway argument
    /// still holds: every target is computed from the OBSERVED offset.
    ///
    /// The clock itself is the roll's, by reference and never redeclared:
    /// `PianoRollEdgeRepeat.interval`, `.holdDelay` and `.isHeld`.
    ///
    /// - Parameters:
    ///   - held: the record captured from the last real pointer event.
    ///   - observedOffset: where the scrollers ACTUALLY sit, not where the last
    ///     tick asked them to go.
    ///   - viewport: the visible size.
    ///   - content: the full drawn size.
    ///   - axes: the axes this gesture may push along.
    public static func tick(
        held: HeldPoint,
        observedOffset: CGPoint,
        viewport: CGSize,
        content: CGSize,
        axes: Axes
    ) -> Tick? {
        let location = CGPoint(x: held.local.x + observedOffset.x,
                               y: held.local.y + observedOffset.y)
        // The SAME predicate the live funnel pushes on, asked of the SAME
        // function, so a repeat is never live where a real event is inert.
        guard !push(pointer: location, offset: observedOffset,
                    viewport: viewport, content: content, axes: axes).isEmpty
        else { return nil }
        return Tick(location: location,
                    translation: CGSize(width: location.x - held.origin.x,
                                        height: location.y - held.origin.y))
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
