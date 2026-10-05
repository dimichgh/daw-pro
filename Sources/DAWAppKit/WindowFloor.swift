import CoreGraphics

/// The main-window size floor (roadmap m10-j): the smallest window at which ALL
/// fixed chrome stays visible and usable — the app header row, the arrange toolbar,
/// a usable timeline sliver (the ruler + a row or two), the bottom editor at its
/// maximum height fraction when open, and the transport bar — with the arrange
/// track area SCROLLING (never pushing chrome off-window) once content exceeds the
/// viewport.
///
/// The numbers are MEASURED, not guessed (the m10-d law). Each chrome row was
/// rendered via `NSHostingView.fittingSize` at the app's real fonts / paddings /
/// spacings and the floor derived from those intrinsics (see the per-constant
/// notes). The window enforces this floor at TWO layers, and — this is the m23-dw
/// correction — they are expressed in DIFFERENT UNITS and are therefore DIFFERENT
/// NUMBERS:
///   • the SwiftUI root `.frame(minWidth:minHeight:)` is in LAYOUT-AREA units — the
///     area SwiftUI lays the root view out in, which `WindowGroup` places BELOW the
///     32 pt titlebar inset. That layer uses `minWidth` / `minHeight`.
///   • the NSWindow `contentMinSize` (and `debug.windowFrame`, and
///     `clampWindowContent`) is in WINDOW CONTENT-RECT units, which INCLUDE the
///     titlebar inset. That layer uses `minWidth` / `minWindowContentHeight`
///     (= `minHeight + titlebarInset`).
/// Before m23-dw both layers were given `minHeight`, so the NSWindow advertised a
/// 640 pt floor it could not hold: the whole band `[… 671]` was echoed back verbatim
/// and then silently drifted up to 672 once SwiftUI laid out. Width is unaffected —
/// there is no titlebar on the horizontal axis, so one constant serves both layers.
/// The `debug.windowFrame` staging command clamps to the floor, so a small-window
/// gate can never drive the chrome off-screen.
///
/// SwiftUI-free (this target has no SwiftUI): the DAWApp scene reads the constants
/// for `.defaultSize` / the root frame and applies `contentMinSize`; the clamp is
/// unit-tested here (the `PanelLayoutStore` / `TrackHeaderLayout` precedent).
public enum WindowFloor {

    // MARK: - Width

    /// The Pro transport bar's minimum width. The transport is the width-binding
    /// chrome — wider than the header (~817) or the arrange toolbar (~377) — and is
    /// present in BOTH workspaces, so it sets the floor; Pro because Pro is reachable
    /// and its extra controls must not clip.
    ///
    /// ⚠️ HISTORY, and why the number still holds (TB-F1, 2026-09-27): it was first
    /// MEASURED (m10-j) as the `NSHostingView` fittingSize of the Pro row at spacing
    /// 20 with every word. That row no longer exists: the worded Pro bar at rest is
    /// now 1435 pt. The number holds only because TB's word drops and gap closing
    /// (2026-09-25) and TB-F1's rule-driven gives (`TransportBarFit`) pay for PANIC,
    /// KEYS, the count-in stepper and the LOOPER door. MEASURED on staging (TB-F1):
    /// the binding state at the floor is Pro at rest (looper closed, no notice),
    /// 32 + 689 + 20 + 437 = 1178 pt of bar — 1183 less its 5 pt safety, a
    /// coincidence of arithmetic, not a derivation. Every other state needs less
    /// (the rule's 48-case model, `TransportBarFitTests`). Adding a transport
    /// control means re-deriving this, not trusting it.
    public static let transportProMinWidth: CGFloat = 1183

    /// The window content's outer horizontal inset (ContentView's `.padding(12)` on
    /// both sides). Every row — including the full-width transport bar — lives inside
    /// it, so it's added to the width-binding chrome's own intrinsic width.
    public static let outerHorizontalPadding: CGFloat = 24

    /// Minimum window CONTENT width: the measured Pro transport bar + the outer
    /// window padding it sits inside, +1 pt slack (1183 + 24 + 1).
    public static let minWidth: CGFloat = 1208

    // MARK: - Height

    /// The bottom editor's maximum height fraction (`PanelLayoutStore.editorFraction`
    /// caps at 0.55) — the WORST case for chrome visibility, since the editor then
    /// claims the most vertical space, leaving the least for everything else.
    public static let editorMaxFraction: CGFloat = 0.55

    /// The fixed (non-scrolling, non-editor) vertical chrome the window must always
    /// show, summed from the MEASURED rows + the layout's spacings/paddings:
    /// 12 (top pad) + 25 (header) + 10 + 20 (arrange toolbar) + 10 + 10 (spacing) +
    /// 6 (editor splitter) + 10 + 10 (spacing) + 64 (transport) + 12 (bottom pad).
    public static let fixedChromeHeight: CGFloat = 189

    /// A "usable sliver" of the arrange track area that must stay visible even with
    /// the editor open at its max fraction: the 42 pt ruler + ~1.5 default rows.
    /// Below this the track area SCROLLS (m10-j), so this is the visible minimum,
    /// not a content minimum.
    ///
    /// ⚠️ **THE PROSE ABOVE IS STALE AND THE NUMBER IS DELIBERATELY NOT MOVED**
    /// (found while measuring for m25-b-1, 2026-08-13). `TimelineLanesView.rulerHeight`
    /// is **80 pt**, not 42 — the pinned block grew when the loop band, marker lane
    /// and tempo lane joined the bar ruler (m13-g), and this comment predates that.
    /// So 96 is NOT "ruler + 1.5 rows"; it is the ruler block plus 16 pt. Changing
    /// the constant would move `minHeight` and therefore the shipped window floor,
    /// which is a measured decision of its own and out of scope here — recorded
    /// rather than silently corrected, because a wrong justification for a right
    /// number is how the next reader derives a wrong one from it. `EditorMaximize`
    /// deliberately does NOT derive its reserve from this constant for exactly
    /// this reason.
    public static let timelineSliverMinHeight: CGFloat = 96

    /// Minimum window CONTENT height. Derived so that with the editor open at its
    /// maximum fraction, the fixed chrome + a usable timeline sliver still fit:
    ///   `minHeight · (1 − editorMaxFraction) ≥ fixedChromeHeight + timelineSliverMinHeight`
    /// → `minHeight ≥ (189 + 96) / 0.45 ≈ 633` → 640 (a touch of headroom, and the
    /// value the app has shipped with — now derived rather than guessed).
    public static let minHeight: CGFloat = 640

    /// The vertical inset `WindowGroup` reserves for the TITLEBAR inside the window's
    /// content rect: the SwiftUI root view is laid out BELOW it, so a root
    /// `.frame(minHeight: 640)` forces a 672 pt content RECT. MEASURED, three
    /// independent corroborations:
    ///   1. an m23-dw `debug.windowFrame` sweep on staging — every request in
    ///      `[… 671]` was echoed verbatim at t0 and had DRIFTED to 672 by t+400 ms,
    ///      while 672 / 673 / 900 held exactly: 672 − 640 = 32;
    ///   2. m23-ag's capture geometry, where `captureOrigin.y = 32`;
    ///   3. the pre-existing measurement noted at `MixerStripLayout.swift:471`
    ///      ("the window's 672 pt of content" at the 640 pt layout floor).
    /// Not a guess and not a magic number at a call site — the unit conversion
    /// between the two floors below.
    public static let titlebarInset: CGFloat = 32

    /// Minimum window CONTENT-RECT height — the unit `NSWindow.contentMinSize`,
    /// `debug.windowFrame`, and `clampWindowContent(width:height:)` all actually
    /// operate in.
    /// It is `minHeight` (the SwiftUI layout area) PLUS the titlebar inset SwiftUI
    /// puts above that area: 640 + 32 = 672. This is the smallest content rect the
    /// window can genuinely hold; asking for less is not refused, it is silently
    /// drifted up ~100 ms later, which is the bug m23-dw fixes.
    ///
    /// Use this ANYWHERE the number is about the window. Use `minHeight` only where
    /// the number is about the SwiftUI content area below the titlebar (the root
    /// `.frame`, `ExportSheetLayout`, `debug.effectEditor`'s `windowMinHeight`).
    public static let minWindowContentHeight: CGFloat = minHeight + titlebarInset

    // MARK: - Default

    /// A comfortable default window content size, well above the floor.
    public static let defaultWidth: CGFloat = 1440
    public static let defaultHeight: CGFloat = 900

    // MARK: - Clamp

    /// Clamps a requested WINDOW CONTENT-RECT size UP to the floor (no upper bound —
    /// a large window is fine; the floor only stops it going too small). Used by
    /// `debug.windowFrame` so a gate can request the floor / a smaller size and land
    /// exactly on the enforced minimum — and, since m23-dw, actually STAY there.
    ///
    /// ⚠️ The two axes deliberately clamp against DIFFERENT-LOOKING constants, and
    /// that asymmetry is the whole point of m23-dw (see the type doc): the argument
    /// pair is in window content-rect units, `minWidth` is already in those units
    /// (no titlebar on the horizontal axis), but the VERTICAL floor in those units is
    /// `minWindowContentHeight` (= `minHeight` + `titlebarInset`), not `minHeight`.
    /// Named `clampWindowContent` (not `clamp`) precisely because it is asymmetric —
    /// both arguments and both results are window content-rect units, never the
    /// SwiftUI layout-area `minHeight`.
    public static func clampWindowContent(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(
            width: max(width, minWidth),
            // NOT `minHeight`: `height` here is a CONTENT-RECT height, and the content
            // rect includes the titlebar the SwiftUI layout floor sits below. Clamping
            // to `minHeight` advertises 640 and drifts to 672 — the m23-dw bug.
            height: max(height, minWindowContentHeight))
    }
}
