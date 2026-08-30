import CoreGraphics

/// How much of the *Convert Voice…* card's height its SCROLLING body may claim
/// (m24-m leg B) — the m23-m3c "a named in-window sheet is bounded by the WINDOW,
/// and hugs before it scrolls" law, with its own measured chrome rather than a
/// borrowed one.
///
/// **Why this card needs a budget at all.** It carries THREE regions that can
/// each outgrow the window and none of which the card controls: the voice list
/// (however many voices the facade serves), the target-clip list (however many
/// clips the user selected — a comped verse can easily be a dozen), and, after a
/// run, the warnings list. The m26-i law is explicit that a centred card with a
/// variable region needs an explicit budget and that **exactly one region
/// yields** — a `ScrollView` is maximally flexible, so any scroller present
/// absorbs the ENTIRE shortfall whether or not it is the region you meant to
/// shrink. Here the yielding region is the whole BODY, one scroller, with the
/// two inner lists capped so neither can starve the other inside it.
///
/// **What is PINNED and why each one is.** The header (the card's identity and
/// its close ✕ — a modal you cannot leave is worse than one that scrolls), the
/// error strip (a reason the conversion was refused that you must scroll to find
/// is a reason you will not read), the progress block (the whole point of the
/// state — see the m24-m progress law) and the footer's primary button (the
/// m23-m3c finding: *a modal whose primary action is off-screen is worse than one
/// that scrolls*).
///
/// ⚠️ **`reservedChromeHeight` IS THE ONE CONSTANT A TEST CANNOT DERIVE**, and
/// the m26-i law says so: every pin CONSUMES it, so all of them stay green when
/// it is wrong, and only the FIXED-CHROME half can actually overflow the card.
/// It is deliberately rounded UP from the sum of the card's pinned literals —
/// over-reserving starts the scroller a few points early, while under-reserving
/// clips the CONVERT button, which is the failure this type exists to prevent.
/// It is verified the way that law requires: a `debug.captureUI` render at the
/// `WindowFloor` height, where the body CLAMPS and the card's overshoot IS this
/// constant's error, isolated.
public enum VoiceConvertSheetLayout {

    /// The card's fixed width. The house side-panel/named-sheet width family:
    /// wider than the 400 pt single-clip sheet it replaces because this one
    /// carries a clip list whose rows hold a name, a track and a beat span.
    public static let cardWidth: CGFloat = 440

    /// What the card spends on chrome that must never scroll: the header row,
    /// the hairline under it, the footer's policy line + CONVERT button, the
    /// card's 16 pt padding top and bottom, and the stack spacings between them.
    public static let reservedChromeHeight: CGFloat = 158

    /// Breathing room between the card and the window edge, per side — the app's
    /// outer padding convention (`ExportSheetLayout.windowMargin`, restated
    /// rather than shared: two cards agreeing on a number today is not the same
    /// as one card owning it).
    public static let windowMargin: CGFloat = 24

    /// The body never shrinks below this. A card showing two rows and a
    /// scrollbar is unusable in a different way; below this the card simply
    /// extends past a window smaller than the enforced floor, which
    /// `WindowFloor` makes unreachable.
    public static let minimumBodyRoom: CGFloat = 200

    /// The scrolling body's bound for a window of `availableHeight` points.
    ///
    /// At the 640 pt `WindowFloor` this is 434 pt, which holds the composer's
    /// tallest ordinary state (a voice list, a clip list and the pitch row)
    /// inside a card whose header and CONVERT button both stay on the window.
    public static func bodyRoom(availableHeight: CGFloat) -> CGFloat {
        max(minimumBodyRoom,
            availableHeight - 2 * windowMargin - reservedChromeHeight)
    }

    /// Cap on the voice picker inside the body. A facade serving twenty voices
    /// must not push the clip list out of the body's room — the m26-i rule that
    /// the yielding region is a DECISION, applied one level in.
    public static let voiceListMaxHeight: CGFloat = 176

    /// Cap on the target-clip list, and on the warnings list in the result
    /// state, for the same reason.
    public static let clipListMaxHeight: CGFloat = 132
}
