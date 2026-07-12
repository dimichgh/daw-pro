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
/// notes). The window enforces this floor (the SwiftUI root `.frame(minWidth:
/// minHeight:)` plus the NSWindow `contentMinSize`), and the `debug.windowFrame`
/// staging command clamps to it, so a small-window gate can never drive the chrome
/// off-screen.
///
/// SwiftUI-free (this target has no SwiftUI): the DAWApp scene reads the constants
/// for `.defaultSize` / the root frame and applies `contentMinSize`; the clamp is
/// unit-tested here (the `PanelLayoutStore` / `TrackHeaderLayout` precedent).
public enum WindowFloor {

    // MARK: - Width

    /// The Pro transport bar's MEASURED minimum width (`NSHostingView` fittingSize of
    /// the real row, INCLUDING its own internal hpad 16: 3 transport buttons + LOOP /
    /// PUNCH / CLICK in the fixed 340 pt leading cluster, the Position / Time / Tempo
    /// readouts, the EXPORT chip, the Pro-only test-tone button, the vibe meter, the
    /// master cluster, and the SIMPLE/PRO chip, at spacing 20). The transport is the
    /// width-binding chrome — wider than the header (~817) or the arrange toolbar
    /// (~377) — and is present in BOTH workspaces, so it sets the floor. Pro (not
    /// Simple, ~1125) because Pro is reachable and its extra controls must not clip.
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
    public static let timelineSliverMinHeight: CGFloat = 96

    /// Minimum window CONTENT height. Derived so that with the editor open at its
    /// maximum fraction, the fixed chrome + a usable timeline sliver still fit:
    ///   `minHeight · (1 − editorMaxFraction) ≥ fixedChromeHeight + timelineSliverMinHeight`
    /// → `minHeight ≥ (189 + 96) / 0.45 ≈ 633` → 640 (a touch of headroom, and the
    /// value the app has shipped with — now derived rather than guessed).
    public static let minHeight: CGFloat = 640

    // MARK: - Default

    /// A comfortable default window content size, well above the floor.
    public static let defaultWidth: CGFloat = 1440
    public static let defaultHeight: CGFloat = 900

    // MARK: - Clamp

    /// Clamps a requested content size UP to the floor (no upper bound — a large
    /// window is fine; the floor only stops it going too small). Used by
    /// `debug.windowFrame` so a gate can request the floor / a smaller size and land
    /// exactly on the enforced minimum.
    public static func clamp(width: CGFloat, height: CGFloat) -> CGSize {
        CGSize(width: max(width, minWidth), height: max(height, minHeight))
    }
}
