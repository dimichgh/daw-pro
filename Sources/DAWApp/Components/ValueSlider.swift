import AppKit
import SwiftUI
import DAWCore
import DAWAppKit

/// A thin horizontal value slider in the glass-cockpit language (m11-a) — a dark
/// track under a neon fill and a flat cap, drawn with shapes (NOT a stock AppKit
/// `Slider`, Rule 2). It redraws only on interaction, so it needs no Canvas /
/// `TimelineView` (the meters' 60 fps rule is for continuous readouts, not a
/// value control). Reusable: plain value inputs (value + range + an `onChange`
/// closure + a tint + an enabled flag), so a preview drives it exactly like the
/// app (docs/DESIGN-LANGUAGE.md "Knobs/faders").
///
/// Interaction follows the pointer convention (docs "Pointer affordances"): a
/// horizontal value drag advertises `resizeLeftRight` on hover and holds it for
/// the whole drag. Click/drag maps the pointer position across the track (jump to
/// where you point); holding ⌥ switches to a fine relative drag from where the
/// gesture began. A disabled slider dims and ignores the pointer entirely.
struct ValueSlider: View {
    /// The current value (a plain value input, not a `Binding` — the owner writes
    /// through `onChange`, mirroring the piano-roll / clip-edit closure idiom).
    var value: Double
    /// The value range the track spans.
    var range: ClosedRange<Double>
    /// Called with the new (clamped) value on every drag tick.
    var onChange: (Double) -> Void
    /// False dims the control and drops interaction (e.g. swing while a groove wins).
    var enabled: Bool = true
    /// The fill/cap tint — cyan by default (an earned active readout, never violet).
    var tint: Color = DAWTheme.playback

    /// The value captured when a ⌥ fine-drag begins (nil = absolute drag).
    @State private var fineAnchor: Double?

    private static let trackHeight: CGFloat = 4
    private static let thumbWidth: CGFloat = 10
    private static let rowHeight: CGFloat = 18

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let usable = max(1, width - Self.thumbWidth)
            let frac = fraction(value)
            let thumbX = CGFloat(frac) * usable
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DAWTheme.panelRaised)
                    .frame(height: Self.trackHeight)
                    .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
                Capsule()
                    .fill(enabled ? tint.opacity(0.85) : DAWTheme.textFaint.opacity(0.35))
                    .frame(width: thumbX + Self.thumbWidth / 2, height: Self.trackHeight)
                RoundedRectangle(cornerRadius: 3)
                    .fill(enabled ? tint : DAWTheme.textFaint)
                    .frame(width: Self.thumbWidth, height: 14)
                    .glow(enabled ? tint : .clear, radius: 4, intensity: enabled ? 0.5 : 0)
                    .offset(x: thumbX)
            }
            .frame(height: Self.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(drag(usable: usable), including: enabled ? .gesture : .none)
            .modifier(HoverIf(enabled: enabled))
        }
        .frame(height: Self.rowHeight)
    }

    private func fraction(_ v: Double) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((v - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }

    private func drag(usable: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { g in
                let span = range.upperBound - range.lowerBound
                if NSEvent.modifierFlags.contains(.option) {
                    // ⌥ fine: a relative nudge (quarter speed) from where the drag began.
                    if fineAnchor == nil { fineAnchor = value }
                    let deltaFrac = Double(g.translation.width / usable) * 0.25
                    onChange(((fineAnchor ?? value) + deltaFrac * span).clamped(to: range))
                } else {
                    // Absolute: map the pointer's x across the track (jump to point).
                    fineAnchor = nil
                    let x = g.location.x - Self.thumbWidth / 2
                    let frac = Double(x / usable).clamped(to: 0...1)
                    onChange((range.lowerBound + frac * span))
                }
                DragCursor.set(.resizeLeftRight)
            }
            .onEnded { _ in
                fineAnchor = nil
                DragCursor.clear()
            }
    }
}

/// Applies the `resizeLeftRight` hover cursor only while the slider is enabled (a
/// disabled control advertises nothing) — factored out so the `.gesture(...,
/// including:)` mask and the cursor stay in step.
private struct HoverIf: ViewModifier {
    var enabled: Bool
    func body(content: Content) -> some View {
        if enabled { content.hoverCursor(.resizeLeftRight) } else { content }
    }
}
