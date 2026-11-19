import CoreGraphics

/// The template picker card's vertical budget (m39-tpl-8, design §9.2): how tall
/// the card may grow in a window, and how many ROWS of template tiles it shows.
///
/// ## The rule (docs/DESIGN-LANGUAGE.md "Centered modal cards — the height budget,
/// and WHICH region yields", m26-i)
///
/// The ceiling is DERIVED from the window, never a constant, and exactly ONE
/// region yields: **the template grid**. The header, the Pro tab row, the
/// buttons with their captions, the message slot and the Pro library row each
/// take a fixed, computed height; the grid hugs its tiles when they fit and
/// scrolls inside its room when they do not
/// (`ScrollView { … }.frame(height: gridRoom)` — a FIXED height the view applies,
/// so the row count is a decision rather than a leftover; the `SamplerCardLayout`
/// mechanism). In Pro the detail pane sits BESIDE the grid and takes the grid's
/// height, so it adds width, not chrome.
///
/// The grid never shows fewer than `minVisibleRows` rows: that floor is a valve,
/// not a target, and the card's minimum height is DERIVED from it
/// (`chrome + floor rows`), so the floor can never outrank the ceiling by a
/// picked constant (the sampler card's second defect).
///
/// ## ⚠️ The chrome constants are HAND-SUMMED, NOT MEASURED (this round)
///
/// The user is at the Mac in the round that built this card, so no staging app
/// ran and nothing was measured from pixels. `simpleChromeHeight` and
/// `proExtraChromeHeight` are sums of the view's own literals, rounded UP (an
/// over-estimate costs a tile row; an under-estimate overflows the card, and
/// only the chrome constant can do that). ⛔ OWED: measure both from the running
/// app the `_m26i-card-height-probe.mjs` way (two tile counts subtract out the
/// grid; the window floor isolates the chrome's error), then replace these sums.
public enum TemplatePickerLayout {

    // MARK: - Tiles

    /// Two tiles per row (a ten-tile catalog is five rows).
    public static let columns = 2
    /// One tile's drawn height: 10 pt padding top and bottom, the name (13 pt,
    /// one line), a 4 pt gap, the summary (10 pt, two lines), a 6 pt gap, the
    /// glyph row (12 pt glyphs, the "6 tracks" label).
    public static let tileHeight: CGFloat = 92
    /// The gap between two tile rows (and between the two columns).
    public static let tileGap: CGFloat = 8

    // MARK: - Widths

    /// Simple: two tile columns.
    public static let simpleCardWidth: CGFloat = 600
    /// Pro: the same two columns plus the detail pane beside them.
    public static let detailPaneWidth: CGFloat = 270
    public static var proCardWidth: CGFloat { simpleCardWidth + detailPaneWidth + 14 }

    // MARK: - Chrome (hand-summed, see the type's doc)

    /// Everything on a Simple card that is not the grid: card padding (2 × 16),
    /// the header (title 16 pt + subtitle 11 pt + their gap ≈ 40), four 12 pt
    /// stack gaps, the button row (a 30 pt button over a two-line 10 pt caption,
    /// ≈ 62), and the message slot (`messageSlotHeight`). 32 + 40 + 48 + 62 + 52 = 234.
    public static let simpleChromeHeight: CGFloat = 240
    /// What Pro adds above and below the grid: the Built-in / My Templates tab
    /// row (24 + a 12 pt gap) and the library row (Import, Export, Remove, Save
    /// as Template: 26 + a 12 pt gap). 36 + 38 = 74.
    public static let proExtraChromeHeight: CGFloat = 76
    /// The message slot under the buttons: up to three 10 pt lines, then it
    /// scrolls inside itself. FIXED, so a message appearing or leaving never
    /// moves the buttons (the "chrome that comes and goes keeps its row's height"
    /// rule).
    public static let messageSlotHeight: CGFloat = 52

    // MARK: - The window

    /// Breathing room between the card and the window edge, per side (the
    /// `ExportSheetLayout` convention).
    public static let windowMargin: CGFloat = 24
    /// The tallest the card may ever grow, however tall the display is.
    public static let maxCardHeight: CGFloat = 900
    /// The fewest tile rows the grid may show while it has rows to show.
    public static let minVisibleRows = 2

    // MARK: - Derivations

    public static func chromeHeight(isPro: Bool) -> CGFloat {
        simpleChromeHeight + (isPro ? proExtraChromeHeight : 0)
    }

    /// Rows needed for `tileCount` tiles (an empty tab still draws one row's
    /// worth: its "no saved templates" line).
    public static func rows(tileCount: Int) -> Int {
        max(1, (tileCount + columns - 1) / columns)
    }

    /// The height that shows exactly `rows` rows, gaps between, none trailing.
    public static func height(rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        return CGFloat(rows) * (tileHeight + tileGap) - tileGap
    }

    /// How many WHOLE rows a grid of `height` shows — the number a person counts.
    public static func visibleRows(inHeight height: CGFloat) -> Int {
        guard height > 0 else { return 0 }
        return max(0, Int(((height + tileGap) / (tileHeight + tileGap)).rounded(.down)))
    }

    /// The card's intrinsic minimum: its chrome plus the floor rows. Derived, so
    /// it agrees with the floor by construction.
    public static func minCardHeight(isPro: Bool) -> CGFloat {
        chromeHeight(isPro: isPro) + height(rows: minVisibleRows)
    }

    /// The card's ceiling in a window `availableHeight` tall.
    public static func cardCeiling(availableHeight: CGFloat, isPro: Bool) -> CGFloat {
        min(maxCardHeight, max(minCardHeight(isPro: isPro), availableHeight - 2 * windowMargin))
    }

    /// The grid's FIXED height: never taller than its tiles need (a short tab
    /// must not draw an empty well), never taller than the ceiling leaves —
    /// snapped DOWN to whole rows, because a sliced row is not a row a person
    /// can read — and never shorter than `minVisibleRows` rows (the floor that
    /// keeps the grid usable at the smallest window). It is the one region that
    /// yields.
    public static func gridHeight(tileCount: Int, isPro: Bool, availableHeight: CGFloat) -> CGFloat {
        let natural = height(rows: rows(tileCount: tileCount))
        let room = cardCeiling(availableHeight: availableHeight, isPro: isPro) - chromeHeight(isPro: isPro)
        let roomRows = max(minVisibleRows, visibleRows(inHeight: room))
        return min(natural, height(rows: roomRows))
    }

    // MARK: - The Save as Template card

    /// The Save card's width.
    public static let saveCardWidth: CGFloat = 420
    /// One track row with its tick.
    public static let saveRowHeight: CGFloat = 24
    /// Everything on the Save card that is not the track list: padding (2 × 16),
    /// the header (title + a two-line subtitle ≈ 50), the NAME block (≈ 45), the
    /// TRACKS label and the bus note (≈ 36), the footer (a reason line + the
    /// buttons ≈ 51) and the stack gaps (≈ 42). Hand-summed (≈ 256), rounded up;
    /// unmeasured, like the picker's chrome.
    public static let saveChromeHeight: CGFloat = 264
    /// The fewest track rows the list keeps at any window.
    public static let saveMinVisibleRows = 3

    /// The track list's room: what the window leaves after the chrome, never
    /// under three rows. The list hugs its rows inside it and scrolls past it —
    /// the one region on this card that yields.
    public static func saveListRoom(availableHeight: CGFloat) -> CGFloat {
        let ceiling = min(maxCardHeight, availableHeight - 2 * windowMargin)
        return max(CGFloat(saveMinVisibleRows) * saveRowHeight, ceiling - saveChromeHeight)
    }

    /// The card's whole height: chrome plus the grid.
    public static func cardHeight(tileCount: Int, isPro: Bool, availableHeight: CGFloat) -> CGFloat {
        chromeHeight(isPro: isPro)
            + gridHeight(tileCount: tileCount, isPro: isPro, availableHeight: availableHeight)
    }
}
