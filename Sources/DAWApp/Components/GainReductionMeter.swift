import SwiftUI
import DAWCore
import DAWAppKit

/// The **GAIN REDUCTION** block in a dynamics insert's editor card (m22-e
/// phase 2): a beginner-labeled, left→right glowing segment ladder showing
/// how many dB the compressor/limiter/gate is pulling the level down right
/// now, with 0/3/6/12/24 dB scale marks and an SF Mono readout.
///
/// Anatomy (the LOUDNESS / STEREO IMAGE typographic voice): a dim 8 pt
/// "GAIN REDUCTION" header with the live readout at the right (cyan number +
/// "dB", or the gate's plain-language "CLOSED" verdict in signal green, or
/// the honest "–" dash while nothing reports), over the ladder — a recessed
/// well with ghost segments and tick labels (static chrome, its own tick-free
/// Canvas) under the lit segments (the ONLY continuously-redrawing layer,
/// isolated in its own `TimelineView` per the m22-b/m22-d law so the poll
/// never invalidates the knob table around it).
///
/// Scale/zone/readout semantics are all headless in
/// `DAWAppKit.GainReductionMeterModel` — the bar saturates so the musical
/// 1…6 dB region gets most of the travel, values past 24 dB pin the bar full
/// (a closed gate reads "CLOSED", never a broken scale), and the segments
/// wear position zones (green ≤6 / amber ≤12 / red beyond — a GATE stays
/// uniformly green: deep attenuation is its job, not an alarm).
///
/// Plain value/closure inputs so previews and the card share it; the poll
/// closure resolves `debug.grSeed ?? store.effectGainReductionDb(...)` at
/// the call site (the `scopeFrame` idiom). Engine-side ballistics (instant
/// attack, −20 dB/s held-peak release) arrive pre-smoothed — never re-smooth.
struct GainReductionMeterBlock: View {
    var kind: EffectDescriptor.Kind
    /// Polled at 15 Hz — POSITIVE dB of reduction, nil = not reporting.
    var gainReduction: () -> Double?

    /// 15 Hz: the reading is a held peak with a −20 dB/s release (≈1.3 dB of
    /// motion between polls at worst) — honest motion without joining the
    /// 60 fps club. Unpaused `.periodic` (the LOUDNESS readout pattern), NOT
    /// `.animation(paused: controlActiveState…)`: a DAW's meters keep moving
    /// while the user works in another app, and the paused variant freezes
    /// solid for an unfocused/control-driven app (the m22-e pixel-review
    /// catch — seeds rendered via state invalidation, live never ticked).
    private static let pollInterval = 1.0 / 15
    // nonisolated: the @Sendable Canvas renderers below read these (m16-a).
    private nonisolated static let segmentCount = 24
    private nonisolated static let ladderHeight: CGFloat = 10
    /// Tick-label strip under the ladder (SF Mono 7 pt).
    private nonisolated static let labelHeight: CGFloat = 11

    var body: some View {
        let kind = kind
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text("GAIN REDUCTION")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textDim)
                Spacer(minLength: 0)
                // The readout ticks in ITS OWN TimelineView so the header
                // label/spacer never re-render (the m22-d readout isolation).
                TimelineView(.periodic(from: .now, by: Self.pollInterval)) { _ in
                    readout(db: gainReduction())
                }
            }
            ZStack {
                // Layer 1: well + ghost ladder + ticks — static chrome, no
                // TimelineView, never glowing.
                Canvas { @Sendable context, size in
                    Self.drawScale(&context, size: size, kind: kind)
                }
                // Layer 2: the lit segments — the only redrawing layer.
                TimelineView(.periodic(from: .now, by: Self.pollInterval)) { _ in
                    // CANVAS CONTRACT (m16-a): @Sendable renderer, value
                    // captures only, computed before the closure.
                    let fraction = GainReductionMeterModel.fraction(
                        forDb: gainReduction() ?? 0)
                    Canvas { @Sendable context, size in
                        Self.drawFill(&context, size: size, fraction: fraction, kind: kind)
                    }
                }
            }
            .frame(height: Self.ladderHeight + Self.labelHeight)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Gain reduction")
        .accessibilityValue(accessibilityValue(gainReduction()))
        .help("How many decibels this effect is turning the level down right now. 0 means it isn't touching the sound; the scale pins at 24 dB (a closed gate reads CLOSED).")
    }

    /// The SF Mono readout: cyan number + dim "dB" (the LOUDNESS voice), the
    /// gate's "CLOSED" verdict in signal green (healthy — the gate is doing
    /// its job), or a faint "–" while nothing reports (honest absence).
    private func readout(db: Double?) -> some View {
        let text = GainReductionMeterModel.readoutText(forDb: db, kind: kind)
        let closed = db.map { GainReductionMeterModel.isClosed(db: $0, kind: kind) } ?? false
        let color: Color = closed ? DAWTheme.signal
            : (db == nil ? DAWTheme.textFaint : DAWTheme.playback)
        return HStack(spacing: 3) {
            Text(text)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
                .glow(color, radius: 3, intensity: db == nil ? 0 : 0.35)
                .lineLimit(1)
            if GainReductionMeterModel.showsUnit(forDb: db, kind: kind) {
                Text("dB")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(DAWTheme.textFaint)
            }
        }
    }

    /// Static scale: a recessed near-black well, ghost segments, tick
    /// hairlines and SF Mono labels at 0/3/6/12/24 dB (positions from the
    /// SAME `fraction(forDb:)` the fill uses, so they can never drift).
    private nonisolated static func drawScale(_ context: inout GraphicsContext,
                                              size: CGSize,
                                              kind: EffectDescriptor.Kind) {
        let ladder = CGRect(x: 0, y: 0, width: size.width, height: ladderHeight)
        let well = Path(roundedRect: ladder, cornerRadius: 3)
        context.fill(well, with: .color(DAWTheme.background))
        context.stroke(well, with: .color(DAWTheme.hairline), lineWidth: 1)

        // Ghost segments (unlit ladder) — zone-tinted at 10% like SegmentMeter.
        forEachSegment(width: size.width) { rect, zoneFraction in
            let color = zoneColor(GainReductionMeterModel.zone(
                atBarFraction: zoneFraction, kind: kind))
            context.fill(Path(roundedRect: rect.insetBy(dx: 0, dy: 1.5), cornerRadius: 1),
                         with: .color(color.opacity(0.10)))
        }

        // Ticks + labels.
        let font = Font.system(size: 7, weight: .semibold, design: .monospaced)
        for db in GainReductionMeterModel.tickDbValues {
            let f = GainReductionMeterModel.fraction(forDb: db)
            let x = CGFloat(f) * size.width
            context.fill(Path(CGRect(x: min(max(x - 0.5, 0), size.width - 1),
                                     y: ladderHeight, width: 1, height: 2)),
                         with: .color(DAWTheme.gridEmphasis))
            let anchor: UnitPoint = f <= 0 ? .topLeading : (f >= 1 ? .topTrailing : .top)
            context.draw(Text("\(Int(db))").font(font).foregroundStyle(DAWTheme.textFaint),
                         at: CGPoint(x: x, y: ladderHeight + 3), anchor: anchor)
        }
    }

    /// The lit segments up to `fraction` — position-zone colored, glow drawn
    /// in-canvas (a soft under-fill) so the static scale never glows.
    private nonisolated static func drawFill(_ context: inout GraphicsContext,
                                             size: CGSize,
                                             fraction: Double,
                                             kind: EffectDescriptor.Kind) {
        guard fraction > 0 else { return }
        forEachSegment(width: size.width) { rect, zoneFraction in
            // Lit when the fill passes the segment's LOWER edge — the
            // SegmentMeter/MiniLevelBar convention.
            guard fraction >= zoneFraction - 1.0 / Double(segmentCount) + 0.001 else { return }
            let color = zoneColor(GainReductionMeterModel.zone(
                atBarFraction: zoneFraction, kind: kind))
            let seg = Path(roundedRect: rect.insetBy(dx: 0, dy: 1.5), cornerRadius: 1)
            // Faint wide bloom under the crisp core (the glow recipe, in-canvas).
            context.fill(Path(roundedRect: rect.insetBy(dx: -1, dy: -0.5), cornerRadius: 2),
                         with: .color(color.opacity(0.18)))
            context.fill(seg, with: .color(color))
        }
    }

    /// Shared segment layout: `body(rect, upperEdgeFraction)` per segment —
    /// the `SegmentMeter` (index+1)/count convention, laid horizontally.
    private nonisolated static func forEachSegment(
        width: CGFloat, _ body: (CGRect, Double) -> Void) {
        let gap: CGFloat = 2
        let segmentWidth = max(0.5, (width - CGFloat(segmentCount - 1) * gap)
            / CGFloat(segmentCount))
        for index in 0..<segmentCount {
            let rect = CGRect(x: CGFloat(index) * (segmentWidth + gap), y: 0,
                              width: segmentWidth, height: ladderHeight)
            body(rect, Double(index + 1) / Double(segmentCount))
        }
    }

    private func accessibilityValue(_ db: Double?) -> String {
        guard let db else { return "not reporting" }
        if GainReductionMeterModel.isClosed(db: db, kind: kind) { return "closed" }
        return String(format: "%.1f decibels", db)
    }
}

/// The tiny GR activity bar on a dynamics insert chip (m22-e phase 2): five
/// zone-colored cells lit up to the current reduction, so a user scanning
/// the rack sees WHICH insert is working without opening it — the
/// `MiniLevelBar` sibling on the `GainReductionMeterModel` scale. Renders
/// NOTHING while the effect isn't reporting (nil poll: hosted AU, headless,
/// no engine) — a dead bar is never faked, and the pre-m22-e row layout is
/// untouched in that case. Own 10 Hz unpaused `.periodic` `TimelineView` so
/// the tick never invalidates the row around it and keeps ticking while the
/// app is unfocused (the LOUDNESS pattern — see `GainReductionMeterBlock`).
struct GainReductionMiniBar: View {
    var kind: EffectDescriptor.Kind
    /// Polled at 10 Hz — POSITIVE dB of reduction, nil = not reporting.
    var gainReduction: () -> Double?

    private static let pollInterval = 1.0 / 10
    // nonisolated: the @Sendable Canvas renderer below reads it (m16-a).
    private nonisolated static let segmentCount = 5

    var body: some View {
        let kind = kind
        TimelineView(.periodic(from: .now, by: Self.pollInterval)) { _ in
            if let db = gainReduction() {
                // CANVAS CONTRACT (m16-a): @Sendable renderer, value captures
                // only, computed before the closure.
                let fraction = GainReductionMeterModel.fraction(forDb: db)
                Canvas { @Sendable context, size in
                    Self.draw(&context, size: size, fraction: fraction, kind: kind)
                }
                .frame(width: 24, height: 5)
                .accessibilityLabel("Gain reduction")
                .accessibilityValue(String(format: "%.1f decibels", db))
                .help("How hard this effect is working — how many decibels it's turning the level down right now.")
            }
        }
    }

    private nonisolated static func draw(_ context: inout GraphicsContext,
                                         size: CGSize,
                                         fraction: Double,
                                         kind: EffectDescriptor.Kind) {
        let gap: CGFloat = 1
        let cellWidth = max(0.5, (size.width - CGFloat(segmentCount - 1) * gap)
            / CGFloat(segmentCount))
        for index in 0..<segmentCount {
            let upper = Double(index + 1) / Double(segmentCount)
            let lit = fraction >= Double(index) / Double(segmentCount) + 0.001
            let color = zoneColor(GainReductionMeterModel.zone(
                atBarFraction: upper, kind: kind))
            let rect = CGRect(x: CGFloat(index) * (cellWidth + gap), y: 0,
                              width: cellWidth, height: size.height)
            context.fill(Path(roundedRect: rect, cornerRadius: 1),
                         with: .color(lit ? color : color.opacity(0.10)))
        }
    }
}

/// The zone's semantic accent (file-scoped so the card ladder and the chip
/// mini-bar share one mapping): green = gentle/healthy work, amber = firm,
/// red = crushing — DESIGN-LANGUAGE accents, never violet (nothing here is
/// AI; a gate maps entirely to green via the model's kind rule).
private func zoneColor(_ zone: GainReductionMeterModel.Zone) -> Color {
    switch zone {
    case .light: return DAWTheme.signal
    case .firm: return DAWTheme.record
    case .heavy: return DAWTheme.clip
    }
}
