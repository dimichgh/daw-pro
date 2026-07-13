import SwiftUI
import DAWCore

/// Compact horizontal segmented level bar for track rows — SegmentMeter's
/// little sibling laid on its side. Same green -> amber -> red zone thresholds
/// and glow recipe (docs/DESIGN-LANGUAGE.md "Meters"); glow follows RMS.
struct MiniLevelBar: View {
    var meter: MeterFrame
    // Ten segments with a 1 pt gap so the bar still reads as segmented LEDs even
    // at its narrow compress floor (beta m10-i round 2): at 22 pt that leaves
    // ~1.3 pt per segment, at 44 pt ~3.5 pt — both render cleanly.
    var segmentCount: Int = 10
    /// Layout floor for a graceful compress (beta m10-i): in a crowded narrow
    /// track header the bar may shrink from its ideal `maxWidth` down to this
    /// `minWidth` (a narrower bar, NOT hidden — the Canvas simply draws slimmer
    /// segments) so the track NAME wins the layout fight. Default `min == max`
    /// keeps the original rigid 44 pt everywhere else.
    var minWidth: CGFloat = 44
    var maxWidth: CGFloat = 44

    private nonisolated static func zoneColor(_ fraction: Double) -> Color {
        if fraction > 0.92 { return DAWTheme.clip }
        if fraction > 0.72 { return DAWTheme.record }
        return DAWTheme.signal
    }

    var body: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let count = segmentCount
        let level = Double(meter.rms.clamped(to: 0...1))
        return Canvas { @Sendable context, size in
            let gap: CGFloat = 1.0
            // Guard against a degenerate/negative segment width if the frame is
            // ever proposed narrower than the gaps demand.
            let segmentWidth = max(0.5, (size.width - CGFloat(count - 1) * gap) / CGFloat(count))

            for index in 0..<count {
                let fraction = Double(index + 1) / Double(count)
                let isLit = level >= Double(index) / Double(count) + 0.001
                let color = Self.zoneColor(fraction)
                let x = CGFloat(index) * (segmentWidth + gap)
                let rect = CGRect(x: x, y: 0, width: segmentWidth, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: 1)
                context.fill(path, with: .color(isLit ? color : color.opacity(0.10)))
            }
        }
        .frame(minWidth: minWidth, maxWidth: maxWidth, minHeight: 6, maxHeight: 6)
        .glow(Self.zoneColor(Double(meter.rms)), radius: 4, intensity: Double(meter.rms) * 0.7)
        .accessibilityLabel("Track level")
        .accessibilityValue("\(Int(Double(meter.rms) * 100)) percent")
    }
}
