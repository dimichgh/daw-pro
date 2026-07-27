import CoreGraphics

/// How much of the Export card's height its SCROLLING body may claim
/// (m23-m3c) — the m23-a "hug when it fits, scroll when it doesn't" mechanism,
/// applied to a dialog instead of a mixer strip.
///
/// **Why the card needed this at all, measured rather than assumed.** The m23-m3
/// bounce card stands ~616 pt tall in its fullest state, against a 640 pt window
/// floor (`WindowFloor`) — four points of margin. Stems mode adds a mode
/// selector, two sibling toggles with a nested loudness pair and the file
/// preview, which took the card to ~726 pt: at the floor BOTH the title and the
/// EXPORT button fell off the window (captured, m23-m3c). A modal whose primary
/// action is unreachable is worse than one that scrolls.
///
/// So the card's header, its error strip and its footer are PINNED, and
/// everything between them lives in ONE scroll region bounded by `bodyRoom`.
/// Read the three modifiers as one mechanism (the mixer-strip law, verbatim):
/// `ScrollView { sections }.frame(maxHeight: bodyRoom).fixedSize(horizontal:
/// false, vertical: true)` — the scroller's ideal height is its content's, so
/// `fixedSize` makes the region take that ideal rather than the height the card
/// offers it, and `maxHeight` clamps the ideal to the room. The region is
/// therefore inflexible at `min(content, room)`: at a comfortable window the
/// card renders EXACTLY as it did before this type existed, and only a small
/// window ever sees a scroller.
public enum ExportSheetLayout {

    /// What the card spends on chrome that must never scroll: the title row, the
    /// hairline under it, the footer's name + EXPORT button, the card's 16 pt
    /// padding top and bottom, and the stack spacings between them. Deliberately
    /// rounded UP from the sum of those literals — over-reserving starts the
    /// scroller a few points early, while under-reserving clips the button,
    /// which is the failure this type exists to prevent.
    public static let reservedChromeHeight: CGFloat = 150

    /// Breathing room between the card and the window edge, per side. The app's
    /// outer padding convention.
    public static let windowMargin: CGFloat = 24

    /// The region never shrinks below this: a card that showed two rows of a
    /// section and a scrollbar would be unusable in a different way. Below this
    /// the card simply extends past a window smaller than the enforced floor,
    /// which `WindowFloor` makes unreachable.
    public static let minimumBodyRoom: CGFloat = 180

    /// The scrolling body's bound for a window of `availableHeight` points.
    ///
    /// At the 640 pt window floor this is 442 pt, which holds the tallest stems
    /// card (~576 pt of sections) inside a 592 pt card — button included.
    public static func bodyRoom(availableHeight: CGFloat) -> CGFloat {
        max(minimumBodyRoom,
            availableHeight - 2 * windowMargin - reservedChromeHeight)
    }
}
