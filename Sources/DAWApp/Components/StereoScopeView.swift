import SwiftUI
import DAWCore
import DAWAppKit

/// The master strip's **stereo-image block** (m22-d): a goniometer/vectorscope
/// over a mono-safety readout — so users (and a capture the copilot narrates)
/// can SEE phase/mono problems, not just hear about them.
///
/// Anatomy top→bottom:
/// - header ("STEREO IMAGE" + a faint "MONO SAFETY" tag — the LOUDNESS block's
///   header voice, one block over),
/// - the goniometer well (**Pro only** — the Lissajous cloud is a pro
///   instrument; Simple keeps the beginner-relevant verdict below and hands
///   the height back to the fader throw, the mixer's Simple rationale),
/// - the live verdict row (plain-language zone word + SF Mono correlation),
/// - the −1…+1 mono-safety bar (marker colored by the same zone),
/// - WIDTH / BAL readouts (**Pro only** — pro numbers; the verdict already
///   carries the Simple story).
///
/// ONE semantic meaning, three places: the zone color (green in-phase / amber
/// very-wide / red out-of-phase) tints the trail, the zone word, and the bar
/// marker — they can never disagree because all three derive from
/// `StereoScopeModel.zone(forCorrelation:)`.
///
/// Rendering discipline (the m22-b spectrum precedent): the trail redraws in
/// its OWN `TimelineView` at 20 Hz and the readouts in THEIRS at 10 Hz, so
/// neither invalidates the strip around them; all geometry/semantics are
/// headless in `DAWAppKit.StereoScopeModel`. Plain value/closure inputs, so
/// previews and the real strip share it.
struct MasterStereoImageBlock: View {
    /// Pro reveals the goniometer well + the WIDTH/BAL row.
    var showsScope: Bool
    /// Polled by the trail at ~20 Hz — `appModel.scopeSeed?.frame ??
    /// store.masterScopeFrame()` in the app (the `VibeMeterView` closure idiom).
    var scopeFrame: () -> MasterScopeFrame
    /// Polled at readout rate for `correlation` / `width` / `balance`.
    var analysis: () -> MasterAnalysisSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text("STEREO IMAGE")
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(DAWTheme.textDim)
                Spacer(minLength: 0)
                Text("MONO SAFETY")
                    .font(.system(size: 7, weight: .semibold))
                    .foregroundStyle(DAWTheme.textFaint)
            }
            if showsScope {
                StereoScopeView(scopeFrame: scopeFrame, analysis: analysis)
            }
            StereoImageReadouts(analysis: analysis, showsDetail: showsScope)
        }
        .help("How wide the mix is and whether it stays mono-safe. The scope traces left vs right — a vertical line is mono, a cloud is wide stereo, a horizontal line cancels on single-speaker (phone) playback. The bar is the same verdict: green in phase, amber very wide, red out of phase.")
    }
}

/// The goniometer well: a static grid canvas (drawn once — never on a tick)
/// under the glowing trail canvas, which is isolated in its own
/// `TimelineView` at 20 Hz so its redraw never invalidates siblings. Height
/// flexes 64…108 pt so the master strip compresses instead of overflowing at
/// short windows (the fader-min idiom); the drawing centers the largest
/// square that fits, both layers via `StereoScopeModel.squareRect`.
struct StereoScopeView: View {
    var scopeFrame: () -> MasterScopeFrame
    var analysis: () -> MasterAnalysisSnapshot

    /// Pause the 20 Hz poll when the window isn't active (the `VibeMeterView`
    /// guidance — no frames for a scope nobody's looking at).
    @Environment(\.controlActiveState) private var controlActiveState

    /// Trail poll rate: 20 Hz. The frame spans ~43 ms, so consecutive polls
    /// tile the signal almost seamlessly; ≥30 Hz would only redraw the same
    /// pairs more often.
    private static let pollInterval = 1.0 / 20

    var body: some View {
        ZStack {
            // Layer 1: the well + grid — static chrome, no TimelineView.
            Canvas { @Sendable context, size in
                Self.drawGrid(&context, size: size)
            }
            // Layer 2: the trail — the only continuously-redrawing layer.
            TimelineView(.animation(minimumInterval: Self.pollInterval,
                                    paused: controlActiveState == .inactive)) { _ in
                // CANVAS CONTRACT (m16-a): @Sendable renderer, value captures
                // only, computed before the closure (the per-frame point
                // buffer is the VibeMeterView precedent).
                let frame = scopeFrame()
                let calm = StereoScopeModel.isCalm(frame)
                let zone = StereoScopeModel.zone(forCorrelation: Double(analysis().correlation))
                let color = zoneColor(zone)
                let points = calm ? [] : StereoScopeModel.displayPoints(frame)
                Canvas { @Sendable context, size in
                    Self.drawTrail(&context, size: size, points: points,
                                   color: color, calm: calm)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 64, idealHeight: 108, maxHeight: 108)
        .accessibilityHidden(true)   // the readouts below speak for the block
    }

    /// The static well: recessed near-black glass (the base surface, darker
    /// than the raised strip — an "empty well" when silent), a subtle
    /// circle + diamond grid, the L/R diagonal axis guides, and faint L/R
    /// tags. No glow — never glow static chrome.
    private nonisolated static func drawGrid(_ context: inout GraphicsContext, size: CGSize) {
        let rect = StereoScopeModel.squareRect(in: size)
        let well = Path(roundedRect: rect, cornerRadius: 6)
        context.fill(well, with: .color(DAWTheme.background))
        context.stroke(well, with: .color(DAWTheme.hairline), lineWidth: 1)

        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = rect.width / 2

        // L/R diagonal axis guides (corner to corner, the goniometer axes).
        var diagonals = Path()
        let d = r * 0.7071   // 45° extent, kept inside the rounded corners
        diagonals.move(to: CGPoint(x: c.x - d, y: c.y - d))
        diagonals.addLine(to: CGPoint(x: c.x + d, y: c.y + d))
        diagonals.move(to: CGPoint(x: c.x + d, y: c.y - d))
        diagonals.addLine(to: CGPoint(x: c.x - d, y: c.y + d))
        context.stroke(diagonals, with: .color(DAWTheme.gridEmphasis), lineWidth: 1)

        // Subtle reference circle (drawn a hair inside the unit circle, where
        // full-scale hard-pan lands, so it clears the rounded corners) + a
        // half-scale diamond.
        let circle = Path(ellipseIn: CGRect(x: c.x - r * 0.95, y: c.y - r * 0.95,
                                            width: r * 1.9, height: r * 1.9))
        context.stroke(circle, with: .color(DAWTheme.hairline), lineWidth: 1)
        var diamond = Path()
        diamond.move(to: CGPoint(x: c.x, y: rect.minY + r * 0.5))
        diamond.addLine(to: CGPoint(x: rect.maxX - r * 0.5, y: c.y))
        diamond.addLine(to: CGPoint(x: c.x, y: rect.maxY - r * 0.5))
        diamond.addLine(to: CGPoint(x: rect.minX + r * 0.5, y: c.y))
        diamond.closeSubpath()
        context.stroke(diamond, with: .color(DAWTheme.hairline), lineWidth: 1)

        // Channel tags at the diagonal tops — hard-L rides up-LEFT (the
        // hardware convention; matches the balance/pan direction).
        let tagFont = Font.system(size: 7, weight: .semibold, design: .monospaced)
        context.draw(Text("L").font(tagFont).foregroundStyle(DAWTheme.textFaint),
                     at: CGPoint(x: rect.minX + 8, y: rect.minY + 8))
        context.draw(Text("R").font(tagFont).foregroundStyle(DAWTheme.textFaint),
                     at: CGPoint(x: rect.maxX - 8, y: rect.minY + 8))
    }

    /// The trail: a faint wide bloom under per-tier fading strokes (the glow
    /// recipe, drawn in-canvas so the static grid never glows), newest pairs
    /// hottest with a bright head dot. Calm (silence) draws one dim center
    /// dot in the well — a resting instrument, never garbage.
    private nonisolated static func drawTrail(_ context: inout GraphicsContext, size: CGSize,
                                              points: [CGPoint], color: Color, calm: Bool) {
        let rect = StereoScopeModel.squareRect(in: size)
        if calm || points.count < 2 {
            let dot = Path(ellipseIn: CGRect(x: rect.midX - 2, y: rect.midY - 2,
                                             width: 4, height: 4))
            context.fill(dot, with: .color(color.opacity(0.45)))
            return
        }
        // Keep the trail inside the well's rounded glass.
        context.clip(to: Path(roundedRect: rect.insetBy(dx: 1, dy: 1), cornerRadius: 5))

        func at(_ i: Int) -> CGPoint {
            CGPoint(x: rect.minX + points[i].x * rect.width,
                    y: rect.minY + points[i].y * rect.height)
        }

        // Bloom: the whole trail once, wide and faint, under everything.
        var whole = Path()
        whole.move(to: at(0))
        for i in 1..<points.count { whole.addLine(to: at(i)) }
        context.stroke(whole, with: .color(color.opacity(0.10)), lineWidth: 3)

        // Core: segments bucketed into fade tiers (oldest dimmest), one
        // stroke per tier — bounded work per frame (8 strokes for 256 pairs).
        var tiers = [Path](repeating: Path(), count: StereoScopeModel.trailTierCount)
        for i in 1..<points.count {
            let tier = StereoScopeModel.trailTier(index: i, count: points.count)
            tiers[tier].move(to: at(i - 1))
            tiers[tier].addLine(to: at(i))
        }
        for (tier, path) in tiers.enumerated() where !path.isEmpty {
            context.stroke(path, with: .color(color.opacity(StereoScopeModel.tierOpacity(tier))),
                           lineWidth: 1)
        }

        // The hot head: the newest sample, a small bright cap on the beam.
        let head = at(points.count - 1)
        let headDot = Path(ellipseIn: CGRect(x: head.x - 1.5, y: head.y - 1.5,
                                             width: 3, height: 3))
        context.fill(headDot, with: .color(color.opacity(0.9)))
    }
}

/// The mono-safety readouts under the scope: the plain-language verdict row,
/// the −1…+1 correlation bar, and (Pro) the WIDTH/BAL values — in the
/// LOUDNESS block's exact typographic voice (dim 8 pt labels, SF Mono glowing
/// values). Own `TimelineView` at 10 Hz: the scalars ride τ 300 ms ballistics
/// (≈3 Hz of real information), so 10 Hz renders the bar's motion smoothly
/// without joining the trail's 20 Hz tick.
struct StereoImageReadouts: View {
    var analysis: () -> MasterAnalysisSnapshot
    /// Pro shows the WIDTH/BAL row; Simple keeps just the verdict + bar.
    var showsDetail: Bool

    @Environment(\.controlActiveState) private var controlActiveState

    private static let pollInterval = 1.0 / 10

    var body: some View {
        TimelineView(.animation(minimumInterval: Self.pollInterval,
                                paused: controlActiveState == .inactive)) { _ in
            let snapshot = analysis()
            let correlation = Double(snapshot.correlation)
            let zone = StereoScopeModel.zone(forCorrelation: correlation)
            let color = zoneColor(zone)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Text(zone.label)
                        .font(.system(size: 7, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(color)
                        .glow(color, radius: 3, intensity: 0.35)
                    Spacer(minLength: 0)
                    Text(StereoScopeModel.correlationText(correlation))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(color)
                        .glow(color, radius: 3, intensity: 0.35)
                        .lineLimit(1)
                }
                bar(correlation: correlation, color: color)
                if showsDetail {
                    Grid(alignment: .leading, horizontalSpacing: 6, verticalSpacing: 2) {
                        GridRow {
                            label("WIDTH"); value(StereoScopeModel.widthText(Double(snapshot.width)))
                            label("BAL"); value(StereoScopeModel.balanceText(Double(snapshot.balance)))
                        }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Stereo image")
            .accessibilityValue(accessibilityValue(snapshot, zone: zone))
        }
    }

    /// The −1…+1 mono-safety bar: a dark recessed track with a center (0)
    /// tick and a glowing marker at the correlation, colored by its zone.
    private func bar(correlation: Double, color: Color) -> some View {
        GeometryReader { geo in
            let markerWidth: CGFloat = 3
            let x = CGFloat(StereoScopeModel.barPosition(correlation: correlation))
                * (geo.size.width - markerWidth)
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DAWTheme.background)
                    .frame(height: 6)
                    .overlay(Capsule().stroke(DAWTheme.hairline, lineWidth: 1))
                    .overlay(Rectangle().fill(DAWTheme.gridEmphasis).frame(width: 1, height: 6))
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: markerWidth, height: 10)
                    .glow(color, radius: 3, intensity: 0.5)
                    .offset(x: x)
            }
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .frame(height: 10)
        .help("Mono safety, −1 to +1: +1 means the sides add up perfectly on one speaker; near 0 is very wide; below 0 parts of the mix cancel in mono.")
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .semibold))
            .foregroundStyle(DAWTheme.textDim)
    }

    /// SF Mono cyan value — the LOUDNESS block's `value()` voice (cyan is the
    /// numeric-readout color; the VERDICT rows above carry the zone color).
    private func value(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(DAWTheme.playback)
            .glow(DAWTheme.playback, radius: 3, intensity: 0.35)
            .lineLimit(1)
    }

    private func accessibilityValue(_ snapshot: MasterAnalysisSnapshot,
                                    zone: StereoScopeModel.CorrelationZone) -> String {
        let verdict: String
        switch zone {
        case .inPhase: verdict = "in phase"
        case .wide: verdict = "very wide"
        case .antiPhase: verdict = "out of phase"
        }
        return String(format: "%@, correlation %@, width %@, balance %@",
                      verdict,
                      StereoScopeModel.correlationText(Double(snapshot.correlation)),
                      StereoScopeModel.widthText(Double(snapshot.width)),
                      StereoScopeModel.balanceText(Double(snapshot.balance)))
    }
}

/// The zone's semantic accent (file-scoped so the trail, verdict word, and
/// bar marker share one mapping): green = healthy/mono-safe, amber = caution,
/// red = destructive (content cancels in mono) — DESIGN-LANGUAGE accents,
/// never violet (nothing here is AI).
private func zoneColor(_ zone: StereoScopeModel.CorrelationZone) -> Color {
    switch zone {
    case .inPhase: return DAWTheme.signal
    case .wide: return DAWTheme.record
    case .antiPhase: return DAWTheme.clip
    }
}
