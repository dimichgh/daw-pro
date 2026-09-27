import CoreGraphics

// W7-NTU — THE PITCH EDITOR'S TOOL PALETTE, AS NUMBERS.
//
// The palette row (`PitchEditorToolPalette`, `DAWApp`) draws its slots, the
// engaged tool's HELP and the live SF Mono readout with these metrics, and
// `PitchEditorPaletteFitTests` measures the real strings against them with the
// real fonts. `DAWApp` has no test target, so a fit that is only true in the
// view is a fit nobody can pin: C5a-F11's full help at the 1208 pt floor was
// pinned by exact strings and ONE looked-at capture, and the next sentence
// added to the help ("Hold ⌘ to draw instead.", C5b-4b) cut it again with every
// test green.

/// The tool palette's metrics (m23-ap design §7.2; the help's two lines, W7-NTU).
public enum PitchEditorPaletteLayout {

    // MARK: The row

    /// The palette's side padding inside the pane, and its vertical padding.
    public static let horizontalPadding: CGFloat = 12
    public static let verticalPadding: CGFloat = 7
    /// Between the row's children (each slot, the help, the spacer, the
    /// readout).
    public static let spacing: CGFloat = 8

    // MARK: A tool slot

    /// The slot's SF Symbol (medium) and its name (medium).
    public static let slotIconSize: CGFloat = 11
    public static let slotLabelSize: CGFloat = 10
    /// Between the symbol and the name.
    public static let slotInnerSpacing: CGFloat = 5
    /// The capsule's padding around them, each side.
    ///
    /// W7-NTU U3 (2026-09-27): 9 → 6 for the FOURTH slot (Voice, 61 pt at 6).
    /// MEASURED: at 9, four slots left the Wobble help 325 pt beside its
    /// longest at-rest readout (`PitchWobbleCopy.tooUnevenToMeasure`, 520 pt)
    /// and `PitchEditorPaletteFitTests.wobbleHelpFitsAtTheFloor` read 3 lines
    /// there. Its two lines need 336 pt plus the suite's 4 pt margin. At 6 the
    /// four slots give back 24 pt: 349 pt in that tightest case, 9 pt to spare
    /// (7 would leave 1). A slot at 6 still clears its glyph and name by 6 pt
    /// each side.
    public static let slotHorizontalPadding: CGFloat = 6
    public static let slotVerticalPadding: CGFloat = 4

    // MARK: The help

    /// The help's font size (regular).
    public static let helpFontSize: CGFloat = 9
    /// ⭐ **TWO LINES, IN A BOX OF FIXED HEIGHT.** One line held the Move and
    /// Split help, but not the Wobble help beside the hover readout at the
    /// 1208 pt floor once it gained "Hold ⌘ to draw instead." (C5b-4b):
    /// MEASURED on the `c5a4b-6-floor-1208` capture, the one-line help ended
    /// ~31 pt before the readout, and that sentence needs ~105. Two lines hold
    /// it with room (`PitchEditorPaletteFitTests`).
    public static let helpLineLimit = 2
    /// The help's box: ALWAYS this tall, one line of help or two, so the
    /// palette row never changes height as the help changes (a row that grows
    /// on a tool switch or a hover moves every note above it). Two lines of
    /// `helpFontSize` fit, measured by the fit test.
    public static let helpHeight: CGFloat = 22

    // MARK: The readout

    /// The live readout's font size (semibold SF Mono).
    public static let readoutFontSize: CGFloat = 10

    // MARK: The fit rule

    /// The width the help may take in a palette row `rowWidth` wide (the
    /// pane's width), beside slots whose drawn widths are `slotWidths` and a
    /// readout `readoutWidth` wide (nil = none drawn). The row's children in
    /// order are the slots, the help, a `Spacer`, then the readout, each
    /// `spacing` apart; the readout takes its width FIRST (`layoutPriority`),
    /// so the help gets what is left.
    public static func helpWidth(rowWidth: CGFloat, slotWidths: [CGFloat],
                                 readoutWidth: CGFloat?) -> CGFloat {
        let children = slotWidths.count + 2 + (readoutWidth == nil ? 0 : 1)
        let gaps = CGFloat(max(0, children - 1)) * spacing
        let taken = slotWidths.reduce(0, +) + (readoutWidth ?? 0) + gaps
        return max(0, rowWidth - 2 * horizontalPadding - taken)
    }
}
