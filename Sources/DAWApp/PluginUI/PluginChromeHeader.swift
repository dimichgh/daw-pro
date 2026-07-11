import SwiftUI

/// The glass-cockpit chrome header pinned above every plugin window's body
/// (docs/DESIGN-LANGUAGE.md). Fixed 34 pt. Background `DAWTheme.panel`, a
/// title/subtitle stack, and a cyan (`DAWTheme.playback`) key-accent line along
/// the bottom edge while the panel is key (a neutral hairline otherwise).
///
/// NEUTRAL/CYAN ONLY — violet (`DAWTheme.ai`) is reserved for AI meaning and
/// never appears in plugin chrome. The vendor/generic body BELOW this header is
/// accepted as-is (it will not match the theme; that is expected and correct).
struct PluginChromeHeader: View {
    /// Plugin (component) name, e.g. "DLSMusicDevice".
    var title: String
    /// "TrackName · ManufacturerName", e.g. "Keys · Apple".
    var subtitle: String
    /// Whether the owning panel is currently key (drives the cyan accent).
    var isKey: Bool

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DAWTheme.textPrimary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(DAWTheme.textDim)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(DAWTheme.panel)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(isKey ? DAWTheme.playback : DAWTheme.hairline)
                .frame(height: isKey ? 2 : 1)
        }
        // The panel is `.titled` + `.fullSizeContentView` with a transparent
        // titlebar, so SwiftUI otherwise insets this content by the (utility)
        // title-bar height (~16 pt) — that push-down dropped the subtitle row out
        // of the 34 pt band. Ignoring the safe area lets the chrome fill the band
        // from its true top so BOTH the title and subtitle rows sit inside it.
        .ignoresSafeArea()
    }
}
