import SwiftUI
import DAWAppKit

/// Which way a splitter divides, and therefore the resize it advertises.
enum SplitterAxis {
    /// A vertical hairline between two side-by-side panels — dragged LEFT/RIGHT to
    /// resize the column (the sidebar↔timeline splitter). Cursor: `resizeLeftRight`.
    case vertical
    /// A horizontal hairline between stacked panels — dragged UP/DOWN to resize the
    /// row (the editor's top edge, a track header's bottom edge). Cursor:
    /// `resizeUpDown` — the macOS-correct glyph for a height adjustment (see
    /// docs/DESIGN-LANGUAGE.md "Panel splitters" for why height uses resize, not grab).
    case horizontal

    var cursor: CursorKind { self == .vertical ? .resizeLeftRight : .resizeUpDown }
}

/// A draggable splitter between panels (beta m10-d, docs/DESIGN-LANGUAGE.md
/// "Panel splitters"): a dark-glass hairline that reports its drag translation to
/// the caller (which applies it to a `PanelLayoutStore` dimension). It follows the
/// accent-earned-by-state rule — a quiet `gridEmphasis` hairline at rest, cyan-lit
/// + glowing ONLY while hovered or dragging (never violet, Rule 3). The hit target
/// is `thickness` pt (≥ 6) even though the line draws as a 1 px hairline, so it is
/// easy to grab; it advertises itself with the axis's resize cursor on hover and
/// HOLDS that cursor for the whole drag via `DragCursor` (so it persists when the
/// pointer leaves the strip). The redraw is state-driven (hover/drag), never
/// per-frame — no allocation at rest.
///
/// Reusable + preview-friendly: it takes only plain closures, so a caller wires it
/// to any resizable boundary. `onChanged` receives the gesture's CUMULATIVE
/// translation from the drag start; the caller captures its own origin on the first
/// tick and clamps through the store.
struct PanelSplitter: View {
    var axis: SplitterAxis
    /// Whether the hairline shows at rest. Panel boundaries show it (`true`); a
    /// per-row grabber hides it (`false`) so N stacked track rows don't grow N rest
    /// lines — it's discovered by the resize cursor + hover glow instead.
    var idleVisible: Bool = true
    /// Grab-target thickness (points). ≥ 6 so the hairline is easy to hit.
    var thickness: CGFloat = 6
    var onChanged: (CGSize) -> Void
    var onEnded: () -> Void = {}

    @State private var hovering = false
    @State private var dragging = false

    private var active: Bool { hovering || dragging }

    private var lineColor: Color {
        if active { return DAWTheme.playback.opacity(0.85) }
        return idleVisible ? DAWTheme.gridEmphasis : .clear
    }

    var body: some View {
        ZStack {
            // Transparent grab target fills the whole strip.
            Color.clear
            // The drawn hairline — thin at rest, a touch bolder + glowing when active.
            Rectangle()
                .fill(lineColor)
                .frame(
                    width: axis == .vertical ? (active ? 2 : 1) : nil,
                    height: axis == .horizontal ? (active ? 2 : 1) : nil
                )
                .glow(active ? DAWTheme.playback : .clear, radius: 4, intensity: active ? 0.6 : 0)
        }
        .frame(
            width: axis == .vertical ? thickness : nil,
            height: axis == .horizontal ? thickness : nil
        )
        .frame(
            maxWidth: axis == .horizontal ? .infinity : nil,
            maxHeight: axis == .vertical ? .infinity : nil
        )
        .contentShape(Rectangle())
        .hoverCursor(axis.cursor)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    dragging = true
                    // Hold the resize cursor for the whole drag, even outside the
                    // strip (the m10-c gesture-driven cursor idiom).
                    DragCursor.set(axis.cursor)
                    onChanged(value.translation)
                }
                .onEnded { _ in
                    dragging = false
                    DragCursor.clear()
                    onEnded()
                }
        )
    }
}
