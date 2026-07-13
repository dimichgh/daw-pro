import SwiftUI
import DAWCore

/// Compact vertical master-volume fader (~10×44 pt): dark track, cyan fill
/// proportional to gain (0...2, unity at half travel, faint tick there).
/// Drag anywhere to set; double-click snaps back to unity. Glow follows gain
/// per docs/DESIGN-LANGUAGE.md.
struct MasterVolumeFader: View {
    /// Linear gain 0...2 (1 = unity).
    var volume: Double
    var onChange: (Double) -> Void

    private static let range = Track.volumeRange

    var body: some View {
        GeometryReader { proxy in
            let height = max(proxy.size.height, 1)
            // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
            // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
            let fraction = (volume / Self.range.upperBound).clamped(to: 0...1)
            Canvas { @Sendable context, size in
                let trackPath = Path(
                    roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 3
                )
                context.fill(trackPath, with: .color(DAWTheme.panelRaised))

                // Fill from the bottom, proportional to volume / 2.
                if fraction > 0.001 {
                    var fill = context
                    fill.clip(to: trackPath)
                    let fillHeight = size.height * CGFloat(fraction)
                    fill.fill(
                        Path(CGRect(x: 0, y: size.height - fillHeight,
                                    width: size.width, height: fillHeight)),
                        with: .color(DAWTheme.playback.opacity(0.85))
                    )
                }

                // Unity (1.0) tick at half travel.
                context.fill(
                    Path(CGRect(x: 0, y: size.height * 0.5 - 0.5, width: size.width, height: 1)),
                    with: .color(DAWTheme.textPrimary.opacity(0.35))
                )

                context.stroke(trackPath, with: .color(DAWTheme.hairline), lineWidth: 1)
            }
            .contentShape(Rectangle())
            // Vertical value drag → resizeUpDown (docs/DESIGN-LANGUAGE.md "Pointer
            // affordances"; faders keep the resize cursor, they never "grab").
            .hoverCursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        DragCursor.set(.resizeUpDown)
                        let fraction = 1 - Double(value.location.y) / Double(height)
                        onChange((fraction * Self.range.upperBound).clamped(to: Self.range))
                    }
                    .onEnded { _ in DragCursor.clear() }
            )
            .simultaneousGesture(
                TapGesture(count: 2).onEnded { onChange(1.0) }
            )
        }
        .glow(DAWTheme.playback, radius: 5,
              intensity: 0.2 + 0.4 * (volume / Self.range.upperBound).clamped(to: 0...1))
        .accessibilityLabel("Master volume")
        .accessibilityValue("\(Int(volume * 100)) percent")
    }
}
