import CoreGraphics
import Foundation

/// Pitch-name labels ON the piano-roll note blocks (m25-i): the two decisions a
/// label on a *variable* surface has to make — **does it fit**, and **which
/// polarity of ink can be read on it** — kept headless here because `DAWApp` has
/// no test target (DESIGN-LANGUAGE §"Piano roll" states that constraint for the
/// bar-ops readout; it applies to every rule the roll draws by).
///
/// Both rules were MEASURED, not reasoned: a scratchpad `ImageRenderer` harness
/// compiled the real `Theme.swift`, drew pills with the SAME primitives
/// `PianoRollGrid.drawLitPill` uses, and sampled the resulting pixels with a
/// positive control (white-on-black measured 21.00:1 in the same pass, so a
/// sampler that could not see 21 was never trusted to report 4). The numbers
/// pinned in `PianoRollNoteLabelTests` come from that harness.

// MARK: - sRGB colour, the form these rules reason in

/// An opaque sRGB colour as 0…1 components, with the two operations this file
/// needs: WCAG relative luminance, and the alpha blend a `Canvas` fill actually
/// performs.
///
/// It is deliberately NOT a SwiftUI `Color`: a `Color` cannot be inspected
/// without a main-actor `NSColor` round-trip (see `DAWTheme.hexString`), which
/// is exactly the per-frame allocation drawing code may not do — and a value
/// type here is what lets the whole policy be tested headless.
public struct SRGBColor: Sendable, Equatable, Hashable {
    /// 0…1, sRGB-encoded (i.e. gamma-encoded, the form a hex literal is in).
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    /// From the same `0xRRGGBB` literal `Color(hex:)` takes, so a token and its
    /// luminance can never be derived from two different numbers.
    public init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    /// WCAG 2.1 relative luminance.
    public var relativeLuminance: Double {
        func linear(_ c: Double) -> Double {
            c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    /// `self` drawn at `alpha` over `backdrop`.
    ///
    /// ⚠️ The lerp is in **sRGB-ENCODED** space, not linear space, and that is
    /// the one modelling choice in this file that could have been wrong in a way
    /// no amount of reasoning would catch — and the two spaces disagree by far
    /// more than the margin the ink decision below turns on. It was settled by
    /// MEASUREMENT: `playback` (#3EE6FF) drawn at α = 0.45394 over `panel`
    /// (#12151D) through a real `Canvas` sampled as **#267484**; this formula
    /// gives **#267484** and a linear-space blend gives **#2CA2B5** — a green
    /// channel of 162 against a measured 116. CoreGraphics composites in the
    /// destination space; do not "correct" this to linear.
    public func blended(over backdrop: SRGBColor, alpha: Double) -> SRGBColor {
        let a = min(max(alpha, 0), 1)
        return SRGBColor(red: a * red + (1 - a) * backdrop.red,
                         green: a * green + (1 - a) * backdrop.green,
                         blue: a * blue + (1 - a) * backdrop.blue)
    }

    /// WCAG 2.1 contrast ratio, 1…21.
    public static func contrast(_ a: SRGBColor, _ b: SRGBColor) -> Double {
        let la = a.relativeLuminance, lb = b.relativeLuminance
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

// MARK: - Which ink can be read on a note pill

/// DUAL INK, applied to the app's OTHER variable-luminance surface.
///
/// The keyboard gutter's law (DESIGN-LANGUAGE §"Piano roll") is that everything
/// drawn ON a key takes its polarity from THAT key. A note pill is the same
/// problem one surface over, and worse: a key is one of two fixed tones, while a
/// pill's tone sweeps continuously with velocity (fill opacity 0.45…0.95, ×1.0
/// selected) across two tints. So the polarity is picked per pill, from the
/// pill's own composited luminance — never from a constant, and never from
/// velocity alone.
///
/// **A FIXED INK CANNOT SERVE THIS SURFACE, MEASURED** (harness table, m25-i):
///
/// | fill | v=1 | v=32 | v=64 | v=127 |
/// |---|---|---|---|---|
/// | cyan + black ink | 3.91 | 5.41 | 7.46 | 12.74 |
/// | cyan + white ink | 5.37 | 3.88 | 2.82 | 1.65 |
/// | violet + black ink | 2.79 | 3.64 | 4.69 | 7.47 |
/// | violet + white ink | 7.51 | 5.77 | 4.48 | 2.81 |
///
/// Dark ink alone fails Rule 5 (≥ 4.5:1) on every violet note under ~v60 — most
/// soft AI-generated material, i.e. exactly the content violet exists to mark.
/// Light ink alone fails cyan from ~v20 up. The two tints do not even flip at
/// the same velocity (cyan ≈ v8, violet ≈ v56), so no velocity constant serves
/// both either.
public enum NotePillInk {
    /// The pill inks: **pure black and pure white, and the extremes are
    /// load-bearing.** A mid-luminance object can only be labelled at 4.5:1 by
    /// ink near one of the two ends — measured against the same table:
    /// `keyLabelOnWhite` #232833 peaks at **3.80:1** on cyan v=32 and
    /// `background` #0B0D12 crosses over at **4.41:1**, both under Rule 5's
    /// floor, while black/white cross at **4.58:1**. Harmonising these with the
    /// dark-surface text hierarchy would therefore break the contrast rule, not
    /// tidy it.
    public static let dark = SRGBColor(hex: 0x000000)
    public static let light = SRGBColor(hex: 0xFFFFFF)

    /// The luminance at which pure black and pure white are equally readable:
    /// solving `(L+0.05)/0.05 = 1.05/(L+0.05)`. Written as the derivation rather
    /// than as 0.179 so the number cannot drift from its reason. The contrast
    /// the picked ink delivers is worst exactly here — **4.58:1** — which is the
    /// most any pair of inks can promise on the worst background, and is why
    /// this surface clears Rule 5 with ~2 % to spare rather than comfortably.
    public static let crossoverLuminance: Double = (1.05 * 0.05).squareRoot() - 0.05

    /// The pill's composited colour: `tint` at `alpha` over the grid row it sits on.
    public static func pillColor(tint: SRGBColor, alpha: Double, backdrop: SRGBColor) -> SRGBColor {
        tint.blended(over: backdrop, alpha: alpha)
    }

    /// The ink to draw a pitch name on that pill in.
    ///
    /// The backdrop matters and is not a rounding detail: a black-key lane is
    /// `black @ 22 %` darker than a white one, which moves the composite enough
    /// to flip the branch within one velocity step of the crossover (measured —
    /// cyan v=16 reads 4.59:1 with dark ink on a white row and 4.46:1 on a black
    /// one). Pass the row the note is actually on.
    public static func ink(tint: SRGBColor, alpha: Double, backdrop: SRGBColor) -> SRGBColor {
        prefersDarkInk(tint: tint, alpha: alpha, backdrop: backdrop) ? dark : light
    }

    /// `true` when the pill is light enough to carry dark ink.
    public static func prefersDarkInk(tint: SRGBColor, alpha: Double, backdrop: SRGBColor) -> Bool {
        pillColor(tint: tint, alpha: alpha, backdrop: backdrop).relativeLuminance >= crossoverLuminance
    }
}

// MARK: - Does the name fit on the block

/// The fit rule for a pitch name on a note block.
///
/// ⛔ **SUPPRESS, NEVER TRUNCATE — and this surface is the reason the app's
/// tail-truncate convention does not apply here.** A truncated track name reads
/// as truncated ("Synth Bass Lo…"), so the user knows to look further. A
/// truncated pitch name does not: `"C#4"` cut to `"C#"` — or worse, `"C#-1"` cut
/// to `"C#"` — is itself a **valid, different pitch name**. Truncation on this
/// surface produces a plausible WRONG answer, which is worse than no answer, so
/// a name that does not fit is not drawn at all.
///
/// This also gives the roll zoom-adaptive label density for free, with no second
/// mechanism: at 4 pt/beat a 1/16 note is a 0.25 pt sliver and simply carries no
/// name, while at 200 pt/beat it carries one — "grid density adapts, never
/// forks" (DESIGN-LANGUAGE §"Piano roll"), expressed as fit rather than as a
/// ladder of zoom thresholds.
public enum PianoRollNoteLabel {
    /// SF Mono, matching the gutter's key labels — the house idiom for pitch
    /// text (8 pt, `KeyboardSidebar`). One size everywhere on this surface.
    public static let fontSize: CGFloat = 8

    /// Gap before the first glyph and after the last. **Asymmetric on purpose,
    /// and the 1 pt difference is worth more than it looks.** The leading gap is
    /// the visual anchor — a glyph kissing the pill's rounded start (corner
    /// radius 3) reads as an overflow — while the trailing gap only has to stop
    /// the last glyph touching the end. MEASURED consequence at the shipped 8 pt
    /// SF Mono advance of **5.0 pt**: a 2-glyph name needs 15 pt of pill, which
    /// is EXACTLY an eighth note at the default 32 pt/beat. At a symmetric 3/3 it
    /// needs 16 and the default session shows names on quarter notes and longer
    /// only — a whole tier of ordinary material silently unnamed.
    public static let leadingInset: CGFloat = 3
    public static let trailingInset: CGFloat = 2

    /// Does `labelSize` fit inside a pill of `pillSize` with the insets above?
    ///
    /// `pillWidth` is the **VISIBLE** width, not the pill's geometric width: a
    /// note that crosses the clip end is drawn lit only up to the boundary and
    /// ghosted past it (m19-g), so a label sized against the full rect would be
    /// sliced by that clip — reintroducing the truncation this rule exists to
    /// forbid, in the one place it is hardest to notice.
    ///
    /// The height test demands NO clearance, deliberately. A text box's line box
    /// (measured: **10.0 pt** at 8 pt SF Mono) includes ascender and descender
    /// space it does not paint, the pill is inset only 1.5 pt inside a 14 pt row,
    /// and a `Canvas` does not clip a `draw` to the shape under it — so a hair of
    /// overflow lands on the row's own background, never on a neighbouring note.
    /// A 0.5 pt clearance would have put the SHIPPED geometry at exactly 11 ≤ 11:
    /// break-even, where a 0.1 pt change in the platform's font metrics would
    /// silently remove EVERY note label at once. This test exists for genuinely
    /// short rows, and it should fire there and nowhere near there.
    ///
    /// ⚠️ Per-note, so a run of eighth notes can show a name on `C4` and none on
    /// `C#4` — the names are different lengths and the fit is honest about it.
    /// That raggedness is the arrange clip label's shipped behaviour one surface
    /// over ("a name label when width allows"), chosen over a uniform
    /// worst-case-width rule that would have cost every eighth note its name to
    /// buy tidiness.
    public static func fits(labelSize: CGSize, pillWidth: CGFloat, pillHeight: CGFloat) -> Bool {
        guard labelSize.width > 0, labelSize.height > 0 else { return false }
        return labelSize.width + leadingInset + trailingInset <= pillWidth
            && labelSize.height <= pillHeight
    }

    /// Width of `glyphCount` glyphs given the advance of ONE.
    ///
    /// Valid ONLY because the face is monospaced — which is what lets the
    /// renderer resolve a single reference string per DRAW instead of one
    /// `Text` per note, so a 400-note clip costs one text layout, not 400.
    public static func width(glyphCount: Int, advance: CGFloat) -> CGFloat {
        CGFloat(max(0, glyphCount)) * advance
    }
}
