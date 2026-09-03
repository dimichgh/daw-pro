import Foundation
import CoreGraphics

/// The Sampler editor card's vertical budget — how tall the card may grow in a
/// given window, and how many ZONE ROWS the list actually shows.
///
/// ## Why this is headless, and why it exists at all
///
/// The first cut of the card hard-capped its height at a constant and let the
/// zone list be the only flexible child. Both halves of that were wrong
/// together: the constant was **smaller than the card's own content** once the
/// per-zone inspector opened, and a `ScrollView` is the child a `VStack`
/// compresses first — so the list absorbed **every** point of the shortfall and
/// collapsed to about one and a half rows. Selecting a zone to tune it made the
/// list you select zones from unusable, and it was identical at 3 zones and at
/// 46: the collapse was driven by the ceiling, not by the library.
///
/// ⭐⭐ **IT LOOKED FINE FROM EVERY ANGLE THE BUILDING AGENT COULD SEE.** The
/// suite was green, the build was clean, the model was right, and the card
/// really did render — the defect was only visible in PIXELS, and only in the
/// one state (inspector open) that a first glance does not linger on. It was
/// found by rendering the card on staging and looking. That is why this
/// arithmetic now lives here instead of inline in the view: **a row count that
/// a test can assert is a row count somebody can be wrong about out loud.**
///
/// ## The shape of the answer
///
/// The card is **responsive to the window**, never a fixed height: the ceiling
/// is derived from the height actually available, so it can neither overflow a
/// short window nor waste a tall one (the measured failure was a ~615 pt card
/// sitting in a ~900 pt window with ~280 pt of empty space below it).
///
/// Within that ceiling the roles are deliberately SWAPPED from the first cut:
/// the zone list takes a **fixed, computed** height — so its row count is a
/// decision rather than a leftover — and the per-zone inspector is the region
/// that gives way, hugging its content when it fits and scrolling inside its
/// room when it does not (the `MixerStripLayout.signalFlowRoom` mechanism from
/// docs/DESIGN-LANGUAGE.md's RESERVED CLUSTER law: `ScrollView { … }
/// .frame(maxHeight: room).fixedSize(horizontal: false, vertical: true)`).
///
/// ## The chrome constants, and how they stopped being guesses
///
/// The three constants below are not derived by the layout system, so they are
/// a maintenance obligation: changing a font size or a section's spacing in
/// `SamplerEditorOverlay` without updating them makes the budget drift.
///
/// ⭐⭐ **THEY ARE NOW MEASURED FROM THE RUNNING APP, NOT SUMMED BY HAND.**
/// `scripts/gates/_m26i-card-height-probe.mjs` reads the card's DRAWN box out
/// of `debug.explainFrames` at several zone counts; subtracting the known list
/// height leaves the chrome+inspector lump, and squeezing the window to its
/// floor (where the inspector CLAMPS) splits that lump into its two halves.
/// The first run of that probe found the hand-summed numbers were
/// `chrome 265.5 / inspectorOpen 311.0 / inspectorClosed 29.0` against
/// constants of `266 / 308 / 42` — i.e. **`inspectorOpenHeight` under-stated
/// the real inspector by 3 pt, in the one direction that is not safe.** Every
/// unit test in the round stayed green through that, because they all CONSUME
/// these constants rather than measure them.
///
/// ⚠️ **They must be OVER-estimates: an over-estimate costs a row, an
/// under-estimate costs an overflowing card.** ⭐ And the asymmetry is sharper
/// than it looks — **only `chromeHeight` can actually overflow the card.** When
/// the inspector clamps, its height IS `inspectorRoom`, so the card measures
/// `ceiling + (chrome_real − chromeHeight)`: the overshoot is that one
/// constant's error and nothing else's. An error in `inspectorOpenHeight` only
/// mis-sizes the list/inspector split by a few points. That is why the probe
/// asserts them separately rather than as a sum.
public enum SamplerCardLayout {

    // MARK: - Measured constants (from SamplerEditorOverlay)

    /// One zone row's drawn height.
    public static let rowHeight: CGFloat = 26
    /// The gap between two zone rows (the list's `LazyVStack` spacing).
    public static let rowGap: CGFloat = 2

    /// Everything on the card that is NEITHER the zone-list viewport NOR the
    /// per-zone inspector body: card padding (2 × 16), the eight 10 pt gaps of
    /// the card's own `VStack`, the header, the coverage line, three hairline
    /// dividers, the GLOBALS section, the ZONES section's label, and the footer
    /// hint line.
    ///
    /// **Measured: 265.5 (m26-i), then 322.5 (m34-u).** ⛔ THE ONE CONSTANT THAT
    /// CAN OVERFLOW THE CARD (see the type's doc) — kept a shade above the
    /// measurement on purpose.
    ///
    /// ⚠️⚠️ **m34-u MEASURES IT IN ITS TALLEST STATE, AND THAT IS THE WHOLE
    /// SUBTLETY.** The GLOBALS section now carries a CONDITIONAL amber line —
    /// the stored-but-inert glide warning — and unlike `oneShotOverrideNote`
    /// (which lives inside the yielding inspector scroller and is absorbed
    /// there) it sits in the FIXED chrome. So the honest constant is the chrome
    /// with the warning SHOWING; measuring the quiet state would under-state it
    /// by the one line, in the one direction that overflows the card.
    ///
    /// ⭐ **HONEST COST, RECORDED NOT HIDDEN** (the design language's own idiom
    /// for this): the m34-u VOICE chip row plus the one-line glide warning cost
    /// **57 pt** of chrome (265.5 → 322.5, measured by the probe both before and
    /// after), and at the default window with the per-zone inspector open the
    /// zone list therefore draws **6 rows where it drew 8**. It is unaffected
    /// with no zone selected (still the 12-row cap), it is well above
    /// `minVisibleRows`, and `zoneListSurvivesTheInspector` pins the new floor
    /// so a further slide is a red test rather than a discovery.
    ///
    /// ⚠️ **THE WARNING'S SECOND LINE WAS WORTH A WHOLE ZONE ROW, MEASURED.**
    /// The first two drafts of `SamplerEditorModel.glideInertNote` wrapped to
    /// two lines: chrome came out 333.5 and the list drew a SLICED 5.79 rows.
    /// Cutting the copy to one line bought back 11 pt and a clean 6. Copy length
    /// in fixed chrome is a layout decision on this card, not a wording one.
    ///
    /// ⛔ **NEXT AGENT TO ADD A CONTROL HERE: RE-MEASURE, DO NOT HAND-SUM.**
    /// `node scripts/gates/_m26i-card-height-probe.mjs` is the instrument, and
    /// as of m34-u it stages the INERT-GLIDE state on every measurement so the
    /// conditional warning line is SHOWING while the chrome is measured — it
    /// throws if that staging does not take, so a silently-quiet card cannot
    /// return a too-small number. The GLOBALS row is at **304 of 308 pt** wide
    /// with four knobs; there is no room for a fifth, and m34-h-2 is an open
    /// defect from exactly that kind of squeeze. m34-w's `glideMode` in
    /// particular changes what the GLIDE readout MEANS (a total slide time vs a
    /// rate per interval) rather than adding a value — so it wants the existing
    /// readout to say which, not a new cell beside it.
    public static let chromeHeight: CGFloat = 324

    /// The per-zone inspector's NATURAL height with a zone selected: its
    /// section label, three knob groups (PITCH / ENVELOPE / OUTPUT, each a
    /// micro-header over a 66 pt knob cell), and the LOOP segmented row.
    ///
    /// **Measured: 311.0.** It was 308 — a hand-sum that under-stated the real
    /// inspector, which the height probe caught on its first run.
    public static let inspectorOpenHeight: CGFloat = 312
    /// The inspector's height with NOTHING selected — a label over one line of
    /// prompt copy. **Measured: 29.0** (it was a hand-summed 42, a harmless but
    /// wasteful over-estimate that spent 13 pt of list budget for nothing).
    public static let inspectorClosedHeight: CGFloat = 32

    /// Breathing room kept between the card and the window's edges, so a modal
    /// never sits flush against the chrome.
    public static let windowMargin: CGFloat = 56
    /// The tallest the card may ever grow, however tall the display is. Past
    /// this a 340 pt-wide column reads as a ribbon rather than a card.
    public static let maxCardHeight: CGFloat = 860
    /// The floor the ceiling itself may not go below — the card's INTRINSIC
    /// minimum, derived rather than picked: its fixed chrome plus the zone
    /// list's own `minVisibleRows` floor, which is the smallest the card can
    /// draw without breaking a promise it has already made.
    ///
    /// ⚠️ **This was 320, a guess, and my own layout pin caught it**: at a
    /// 420 pt window the derived ceiling (364) came out SHORT of the chrome
    /// plus the four-row floor, so the card overflowed the window it was meant
    /// to fit — the row floor silently outranked the ceiling. Deriving it makes
    /// the two agree by construction instead of by luck, and it keeps agreeing
    /// when `chromeHeight` is re-measured. Below this the card genuinely does
    /// not fit and overflows rather than hiding a control; that is well under
    /// the app's own 672 pt window-content floor (`WindowFloor`).
    public static var minCardHeight: CGFloat { chromeHeight + height(rows: minVisibleRows) }

    /// The fewest zone rows the list may show while it still has rows to show.
    /// **This is the number the defect violated** (it fell to ~1.7), and it is
    /// a floor, not a target.
    public static let minVisibleRows = 4
    /// The most rows to show while the per-zone inspector is open — the
    /// inspector needs the room, and a list this long is for browsing, not for
    /// the zone you are already tuning.
    public static let maxRowsWithInspector = 8
    /// The most rows to show with no selection, when the list IS the card's
    /// subject.
    public static let maxRowsWithoutInspector = 12

    // MARK: - Derivations

    /// The height that shows exactly `rows` zone rows (gaps between, none
    /// trailing). Zero rows is zero height, not a negative one.
    public static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * (rowHeight + rowGap) - rowGap
    }

    /// How many WHOLE rows a viewport of `height` shows. The inverse of
    /// `height(rows:)`, and the number a probe or a human counts on screen — a
    /// partially sliced row is not a visible row.
    public static func visibleRows(inHeight height: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        return max(0, Int(((height + rowGap) / (rowHeight + rowGap)).rounded(.down)))
    }

    /// The card's height ceiling in a window of `availableHeight`.
    public static func cardCeiling(availableHeight: CGFloat) -> CGFloat {
        min(maxCardHeight, max(minCardHeight, availableHeight - windowMargin))
    }

    /// The zone list's viewport height — a FIXED value the view applies, so the
    /// row count is chosen rather than left over.
    ///
    /// Three bounds, in the order they bind: never taller than the rows
    /// actually present (a 3-zone library must not draw a 12-row well), never
    /// taller than this state's cap, and — the floor that fixes the defect —
    /// never shorter than `minVisibleRows` even when the window cannot afford
    /// it. When the floor is what binds, the inspector below scrolls instead;
    /// the list does not collapse.
    public static func zoneListHeight(rowCount: Int, inspectorOpen: Bool,
                                      availableHeight: CGFloat) -> CGFloat {
        let natural = height(rows: rowCount)
        let cap = height(rows: inspectorOpen ? maxRowsWithInspector : maxRowsWithoutInspector)
        let budget = cardCeiling(availableHeight: availableHeight)
            - chromeHeight
            - (inspectorOpen ? inspectorOpenHeight : inspectorClosedHeight)
        return min(natural, cap, max(budget, height(rows: minVisibleRows)))
    }

    /// The room the per-zone inspector gets: whatever the ceiling has left once
    /// the chrome and the zone list have taken theirs. It HUGS its content
    /// inside this and scrolls past it, so the card's real height is
    /// `chrome + list + min(inspector content, this)` and can never exceed the
    /// ceiling.
    public static func inspectorRoom(rowCount: Int, inspectorOpen: Bool,
                                     availableHeight: CGFloat) -> CGFloat {
        let list = zoneListHeight(rowCount: rowCount, inspectorOpen: inspectorOpen,
                                  availableHeight: availableHeight)
        return max(0, cardCeiling(availableHeight: availableHeight) - chromeHeight - list)
    }
}
