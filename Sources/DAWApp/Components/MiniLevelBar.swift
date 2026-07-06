import SwiftUI
import DAWCore

/// Compact horizontal segmented level bar for track rows — SegmentMeter's
/// little sibling laid on its side. Same green -> amber -> red zone thresholds
/// and glow recipe (docs/DESIGN-LANGUAGE.md "Meters"); glow follows RMS.
struct MiniLevelBar: View {
    var meter: MeterFrame
    var segmentCount: Int = 12

    private func zoneColor(_ fraction: Double) -> Color {
        if fraction > 0.92 { return DAWTheme.clip }
        if fraction > 0.72 { return DAWTheme.record }
        return DAWTheme.signal
    }

    var body: some View {
        Canvas { context, size in
            let count = segmentCount
            let gap: CGFloat = 1.5
            let segmentWidth = (size.width - CGFloat(count - 1) * gap) / CGFloat(count)
            let level = Double(meter.rms.clamped(to: 0...1))

            for index in 0..<count {
                let fraction = Double(index + 1) / Double(count)
                let isLit = level >= Double(index) / Double(count) + 0.001
                let color = zoneColor(fraction)
                let x = CGFloat(index) * (segmentWidth + gap)
                let rect = CGRect(x: x, y: 0, width: segmentWidth, height: size.height)
                let path = Path(roundedRect: rect, cornerRadius: 1)
                context.fill(path, with: .color(isLit ? color : color.opacity(0.10)))
            }
        }
        .frame(width: 44, height: 6)
        .glow(zoneColor(Double(meter.rms)), radius: 4, intensity: Double(meter.rms) * 0.7)
        .accessibilityLabel("Track level")
        .accessibilityValue("\(Int(Double(meter.rms) * 100)) percent")
    }
}
