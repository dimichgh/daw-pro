import CoreGraphics
import Foundation
import DAWCore

/// m23-z — the ONE home for "where does a MIXER strip drag land?", the console's
/// facade over the axis-neutral `ReorderLadder` core that also backs the
/// arrange's `TrackReorderDrag` (same file as the core; two honest facades, one
/// scan).
///
/// THE WHOLE CONTENT OF THIS SURFACE IS AN INDEX TRANSLATION. The arrange list
/// renders `store.tracks` RAW, so visual position == array index and there is
/// nothing to get wrong. The console renders
/// `MixerLayout.channelTracks ++ MixerLayout.busTracks` — two order-preserving
/// FILTERS — so the moment a bus sits between two channels the two indices come
/// apart. The rule, and it is the only one that gives the result a user expects:
///
///   **The landing visual slot identifies a TARGET TRACK; the array index to
///   commit is that target track's index in `tracks`.**
///
/// Worked discriminator (the one the gate is built on): array
/// `[C0(chan), B1(bus), C2(chan), C3(chan)]` shows as `C0, C2, C3 | B1`. Drag C0
/// onto the LAST CHANNEL slot (visual 2 = C3, array 3):
///   • correct → `reorderTrack(C0, toIndex: 3)` → `[B1, C2, C3, C0]`, i.e.
///     channels read `C2, C3, C0`;
///   • a naive pass-through of the VISUAL index 2 → `[B1, C2, C0, C3]`, i.e.
///     channels read `C2, C0, C3`.
/// They differ — and they AGREE on every all-channels-first project, which is
/// what natural creation order and every default fixture produce.
///
/// SEMANTICS, settled on the roadmap line and NOT re-litigated here: the array
/// is the single ordering and the console's partition is a VIEW of it. Buses are
/// not special-cased and not pinned; a mixer drag is one remove + one insert on
/// the array. The accepted consequence is that dragging a channel in the mixer
/// can change where a BUS appears in the arrange list. The rejected alternative
/// (clamping a channel drag to the channel section) would make the dragged
/// track's KIND decide which slots are reachable — a second, kind-based ordering
/// rule the arrange does not have.
///
/// AN INVARIANT WORTH STATING, because three things below depend on it: a
/// reorder never changes HOW MANY channels or buses exist, so the divider always
/// sits at the same visual slot boundary, the ladder's gap PATTERN is invariant
/// under any landing, and every visually-effective move is a permutation WITHIN
/// one section.
public enum MixerStripReorder {
    /// Resolves a live pointer position into a landing.
    ///
    /// Returns nil when the geometry is not honest — an unmeasured ladder, a
    /// ladder that describes a different number of strips than the project has,
    /// or a dragged id that is not a strip. A drag with no honest geometry must
    /// do NOTHING rather than fall back to slot 0, which would look exactly like
    /// "the user dragged to the far left".
    ///
    /// - Parameters:
    ///   - pointerX: the pointer's x in the STRIP RACK's own coordinate space —
    ///     the same space the ladder was measured in. The rack scrolls
    ///     horizontally, so a `.local` frame would be silently right at scroll 0
    ///     and wrong at every other offset.
    ///   - draggedID: the strip being carried.
    ///   - tracks: the project's track array, in array order.
    ///   - ladder: the MEASURED strip ladder, in VISUAL (console) order.
    public static func resolve(pointerX: CGFloat, draggedID: UUID, tracks: [Track],
                               ladder: MixerStripLadder) -> ResolvedStripDrop? {
        let strips = MixerLayout.orderedStrips(tracks)
        guard ladder.isWellFormed, ladder.count == strips.count,
              let from = tracks.firstIndex(where: { $0.id == draggedID }),
              let fromSlot = strips.firstIndex(where: { $0.id == draggedID }),
              let targetSlot = ladder.axis.slot(at: pointerX),
              let targetIndex = tracks.firstIndex(where: { $0.id == strips[targetSlot].id })
        else { return nil }

        // THE NO-OP LANDING, and why `moves` cannot be `index != from` on this
        // surface: dropping C0 onto B1's slot in the fixture above resolves to
        // array index 1 → `[B1, C0, C2, C3]` → the console STILL shows
        // `C0, C2, C3 | B1`. The array changed; the visible order did not. An
        // array-index comparison would report a move and draw an insertion line
        // for a landing the user sees nothing come of. So the question this
        // surface asks is the VISIBLE one: does the console's order change?
        //
        // The prediction runs through `TrackOrder.applying`, which is the very
        // function `ProjectStore.reorderTrack` mutates with — not a second copy
        // of remove-and-insert that could disagree with it.
        let before = strips.map(\.id)
        let after = MixerLayout
            .orderedStrips(TrackOrder.applying(tracks, moving: draggedID, to: targetIndex))
            .map(\.id)
        guard after != before, let landingSlot = after.firstIndex(of: draggedID) else {
            return ResolvedStripDrop(from: from, fromSlot: fromSlot, targetSlot: targetSlot,
                                     targetIndex: targetIndex, landing: nil)
        }
        // THE LINE MARKS WHERE THE STRIP WILL ACTUALLY BE, not where the pointer
        // is. For every within-section drag those are the same slot. They come
        // apart only when the landing crosses the divider — e.g. dragging the
        // second of two buses onto a channel's slot, which is effective (it
        // reverses the two buses) but lands the strip back in the bus section.
        // Marking the pointer's slot there would promise a position the console
        // will not produce.
        return ResolvedStripDrop(
            from: from, fromSlot: fromSlot, targetSlot: targetSlot, targetIndex: targetIndex,
            landing: ResolvedStripDrop.Landing(
                arrayIndex: targetIndex, slot: landingSlot,
                indicatorX: ladder.axis.edge(landing: landingSlot, from: fromSlot)))
    }

    /// How far each resting strip SLIDES while a drag is in flight, indexed by
    /// VISUAL slot — so the rack parts and opens the gap the strip is heading
    /// for instead of the carried strip simply covering its target.
    ///
    /// The WHOLE array is produced here, in one call, rather than the view asking
    /// per strip for a number it could also have computed itself: the vacated
    /// gap is the one part of this item whose only other observable is a pixel
    /// offset, and a parting distance computed in the view is invisible to every
    /// headless test (the m23-g3 hardening-shadow failure). The seam echoes this
    /// array; the view indexes into it.
    ///
    /// Empty when there is no honest landing — never a plausible array of zeros
    /// of the wrong length.
    public static func partingOffsets(drop: ResolvedStripDrop,
                                      ladder: MixerStripLadder) -> [CGFloat] {
        guard ladder.isWellFormed, let landing = drop.landing else { return [] }
        return (0..<ladder.count).map {
            ladder.axis.displacement(slot: $0, from: drop.fromSlot, landing: landing.slot)
        }
    }
}

/// The console's MEASURED horizontal ladder: each strip's left edge and width,
/// in VISUAL order (channels then buses), in the strip rack's own coordinate
/// space.
///
/// MEASURED, never computed — and the temptation here is real, because the
/// strips are a fixed `.frame(width: 132)`. The `busDivider`'s width is
/// INTRINSIC (it is sized by the "BUSES" caption's text), so a computed ladder
/// would be a SECOND producer that agrees with the layout by luck on every
/// bus-free project and drifts on every other one.
public struct MixerStripLadder: Equatable, Sendable {
    /// Left edge of each strip, in visual order. Ascending.
    public var lefts: [CGFloat]
    /// Width of each strip, in the same order.
    public var widths: [CGFloat]

    public init(lefts: [CGFloat] = [], widths: [CGFloat] = []) {
        self.lefts = lefts
        self.widths = widths
    }

    public static let empty = MixerStripLadder()

    public var count: Int { lefts.count }

    /// Usable only when it describes every strip exactly once.
    public var isWellFormed: Bool { axis.isWellFormed }

    /// The MEASURED gap between strip `i` and strip `i + 1`. PER INDEX, and that
    /// is the whole point on this surface: the rack is an `HStack(spacing: 10)`
    /// with the bus divider inserted between the last channel and the first bus,
    /// so exactly ONE gap is `10 + dividerWidth + 10` and every other is 10.
    /// `TrackRowLadder.spacing`'s trick of sampling rows 0–1 would report the
    /// DIVIDER gap on any project with a single channel, and it would fail
    /// silently — the number stays plausible.
    public func gap(after i: Int) -> CGFloat { axis.gap(after: i) }

    var axis: ReorderLadder { ReorderLadder(starts: lefts, extents: widths) }
}

/// Where a mixer strip drag would land, and where to draw the line that says so.
/// The two can never disagree: both come out of one `resolve` call, and this
/// type cannot be constructed anywhere else (`fileprivate init`).
public struct ResolvedStripDrop: Equatable, Sendable {
    /// A landing that will actually change what the console shows. Its existence
    /// IS the "this moves" fact: there is no separate flag to fall out of step
    /// with it, and no way to hold an insertion line for a visually-inert
    /// landing — `nil` means no line, no commit, no undo entry, by construction.
    public struct Landing: Equatable, Sendable {
        /// The FINAL index in `tracks` to commit — exactly what
        /// `ProjectStore.reorderTrack(id:toIndex:)` and the `track.reorder` wire
        /// command mean by `toIndex`/`index`.
        public let arrayIndex: Int
        /// The VISUAL slot the dragged strip will occupy afterwards. Usually the
        /// slot the pointer is over; different when the landing crosses the
        /// channel/bus divider.
        public let slot: Int
        /// Rack-space x for the insertion line.
        public let indicatorX: CGFloat
    }

    /// The dragged track's index in `tracks`.
    public let from: Int
    /// The dragged strip's current VISUAL slot.
    public let fromSlot: Int
    /// The visual slot the pointer is over. Always meaningful — reported even
    /// for an inert landing, so a gate can see that the translation ran and
    /// judged it inert rather than never ran at all.
    public let targetSlot: Int
    /// `targetSlot`'s strip, as an index into `tracks` — the translation this
    /// whole registry exists to perform.
    public let targetIndex: Int
    /// The landing, or nil when releasing here would leave the console looking
    /// exactly as it does now.
    public let landing: Landing?

    /// True when releasing here changes what the console SHOWS. Not
    /// `index != from`: on this surface an array move can be visibly inert.
    public var moves: Bool { landing != nil }

    fileprivate init(from: Int, fromSlot: Int, targetSlot: Int, targetIndex: Int,
                     landing: Landing?) {
        self.from = from
        self.fromSlot = fromSlot
        self.targetSlot = targetSlot
        self.targetIndex = targetIndex
        self.landing = landing
    }
}
