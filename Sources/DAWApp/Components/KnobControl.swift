import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// Reusable rotary knob in the glass-cockpit language — `PanKnob` generalized
/// into a value-range control (m17-a v2, the 2026-07-19 knob-vs-slider report):
/// a flat dark cap, a faint 270° track, and a thin neon value arc that fills
/// from `fillAnchor` — 0 for a unipolar min-start sweep (freq/time/mix), the
/// zero detent (e.g. 0.5) for a bipolar center-out fill (±dB gains, the
/// `PanKnob` shape). Label ABOVE the knob, live SF Mono readout below — the
/// tight-column channel-strip convention (report §5), not the label-left row.
///
/// Interaction is the house knob contract (`PanKnob`): vertical drag over a
/// 120 pt throw, ⌥ = fine (quarter speed), double-click resets, `resizeUpDown`
/// cursor held for the whole drag. The arc glows only while hovered or
/// dragging — glow is earned by interaction state, never static chrome.
/// Plain value inputs (fraction + strings + closures) so previews and the
/// live app share it; the owner maps value ↔ fraction (including log scales).
struct KnobControl: View {
    /// The micro-label drawn above the knob (rendered uppercase).
    var label: String
    /// Current travel fraction 0…1 (owner-mapped; log scales live owner-side).
    var fraction: Double
    /// The travel fraction the value arc starts from: 0 = unipolar min-start,
    /// a mid detent (e.g. 0.5) = bipolar center-out fill.
    var fillAnchor: Double = 0
    /// The live SF Mono value text below the knob ("-18.0", "3.00", "35").
    var readout: String
    /// The dim unit tag beside the readout ("dB", "kHz", "%").
    var unit: String = ""
    /// Arc/pointer/readout tint — neutral white unless the param genuinely
    /// earns a semantic accent (cyan for level/gain, per the editor's rule).
    var accent: Color = DAWTheme.textPrimary
    /// Whether the readout carries a soft glow (the editor's level params).
    var glowsReadout: Bool = false
    /// New travel fraction on every drag tick (already clamped 0…1).
    var onChange: (Double) -> Void
    /// Double-click reset (nil = no reset affordance).
    var onReset: (() -> Void)? = nil

    /// Travel fraction captured at drag start, for relative (hardware-feel)
    /// drag — the `PanKnob` gesture contract.
    @State private var dragStart: Double?
    @State private var hovering = false

    private static let knobSize: CGFloat = 36

    private nonisolated static func point(_ center: CGPoint, _ radius: CGFloat, _ f: Double) -> CGPoint {
        let radians = MixerMath.knobAngleDegrees(forFraction: f) * .pi / 180
        return CGPoint(x: center.x + radius * CGFloat(cos(radians)),
                       y: center.y + radius * CGFloat(sin(radians)))
    }

    private nonisolated static func arc(_ center: CGPoint, _ radius: CGFloat, from f0: Double, to f1: Double) -> Path {
        var path = Path()
        let steps = 20
        for i in 0...steps {
            let f = f0 + (f1 - f0) * Double(i) / Double(steps)
            let pt = point(center, radius, f)
            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
        }
        return path
    }

    var body: some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(DAWTheme.textDim)
                .lineLimit(1)
            knob
            HStack(spacing: 2) {
                Text(readout)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(accent)
                    .glow(accent, radius: 4, intensity: glowsReadout ? 0.4 : 0)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 7, weight: .semibold))
                        .foregroundStyle(DAWTheme.textDim)
                }
            }
            .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(unit.isEmpty ? readout : "\(readout) \(unit)")
    }

    private var knob: some View {
        // CANVAS CONTRACT (m16-a): renderer closures are @Sendable — value captures
        // only, computed before the closure. See docs/research/design-m16a-canvas-crash.md.
        let fraction = fraction.clamped(to: 0...1)
        let anchor = fillAnchor.clamped(to: 0...1)
        let accent = accent
        let engaged = hovering || dragStart != nil
        return Canvas { @Sendable ctx, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = min(size.width, size.height) / 2 - 3
            let cap = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                             width: radius * 2, height: radius * 2))
            ctx.fill(cap, with: .color(DAWTheme.panelRaised))
            ctx.stroke(cap, with: .color(DAWTheme.hairline), lineWidth: 1)

            ctx.stroke(Self.arc(center, radius - 2, from: 0, to: 1),
                       with: .color(DAWTheme.textDim.opacity(0.25)),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
            ctx.stroke(Self.arc(center, radius - 2, from: anchor, to: fraction),
                       with: .color(accent.opacity(0.85)),
                       style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            var pointer = Path()
            pointer.move(to: center)
            pointer.addLine(to: Self.point(center, radius - 3, fraction))
            ctx.stroke(pointer, with: .color(accent),
                       style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: Self.knobSize, height: Self.knobSize)
        .contentShape(Circle())
        // A rotary knob is a vertical value drag → resizeUpDown (docs/DESIGN-
        // LANGUAGE.md "Pointer affordances"), the `PanKnob` family.
        .hoverCursor(.resizeUpDown)
        .onHover { hovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    DragCursor.set(.resizeUpDown)
                    let start = dragStart ?? fraction
                    if dragStart == nil { dragStart = start }
                    let fine = NSEvent.modifierFlags.contains(.option) ? 0.25 : 1.0
                    let moved = -Double(value.translation.height) * fine
                    onChange(MixerMath.adjustedFraction(
                        start: start, dragPoints: moved, throwPoints: 120))
                }
                .onEnded { _ in dragStart = nil; DragCursor.clear() }
        )
        .simultaneousGesture(TapGesture(count: 2).onEnded { onReset?() })
        // Glow earned by interaction state — never on static chrome.
        .glow(accent, radius: 5, intensity: engaged ? 0.45 : 0)
    }
}
