import SwiftUI
import DAWCore

/// Segmented LED-style level meter with peak hold. Green -> amber -> red zones,
/// glow follows level (docs/DESIGN-LANGUAGE.md "Meters").
struct SegmentMeter: View {
    var meter: MeterFrame
    var segmentCount: Int = 20

    @State private var heldPeak: Float = 0
    @State private var peakDecayTask: Task<Void, Never>?

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
        let peakFraction = Double(heldPeak.clamped(to: 0...1))
        return Canvas { @Sendable context, size in
            let gap: CGFloat = 2
            let segmentHeight = (size.height - CGFloat(count - 1) * gap) / CGFloat(count)

            for index in 0..<count {
                let fraction = Double(index + 1) / Double(count)
                let isLit = level >= Double(index) / Double(count) + 0.001
                let color = Self.zoneColor(fraction)
                let y = size.height - CGFloat(index + 1) * (segmentHeight + gap) + gap
                let rect = CGRect(x: 0, y: y, width: size.width, height: segmentHeight)
                let path = Path(roundedRect: rect, cornerRadius: 1.5)
                context.fill(path, with: .color(isLit ? color : color.opacity(0.10)))
            }

            // Peak-hold tick.
            if peakFraction > 0.01 {
                let y = size.height * (1 - CGFloat(peakFraction))
                let tick = CGRect(x: 0, y: max(0, y - 1), width: size.width, height: 2)
                context.fill(
                    Path(tick),
                    with: .color(peakFraction > 0.92 ? DAWTheme.clip : DAWTheme.textPrimary)
                )
            }
        }
        .glow(Self.zoneColor(Double(meter.rms)), radius: 6, intensity: Double(meter.rms) * 0.7)
        .onChange(of: meter.peak) { _, newPeak in
            if newPeak >= heldPeak {
                heldPeak = newPeak
                peakDecayTask?.cancel()
                peakDecayTask = Task {
                    try? await Task.sleep(for: .seconds(1.2))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.6)) { heldPeak = 0 }
                }
            }
        }
        .accessibilityLabel("Output level")
        .accessibilityValue("\(Int(Double(meter.rms) * 100)) percent")
    }
}
