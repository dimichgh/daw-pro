import SwiftUI
import DAWCore
import DAWAppKit

/// The **session vibe meter** — the app's signature "glowing instrument" (M8 vm-b;
/// VISION.md:16). One coherent glowing orb (NOT a bar-graph spectrum) that reads the
/// whole mix's feel at a glance: a bilaterally-symmetric spectral silhouette around a
/// hot ember core, drawn on `Canvas` at 60 fps via `TimelineView(.animation)`.
///
/// The mapping (all perceptual math is headless in `DAWAppKit.VibeMeterModel`, tested):
/// - **brightness** (short-term level) → the core's size and glow — loud blazes, quiet
///   dims to an ember (never black).
/// - **hue** (spectral centroid) → a **warm-amber ↔ cyan** color — a deep/bassy mix
///   burns warm, a bright mix turns cool and airy. NEVER violet (Rule 3: violet = AI).
/// - **bands** (24-band energy) → the silhouette geometry — bass bulges the bottom,
///   treble the top, so the shape itself shows the spectral tilt.
/// - **flux** (energy movement) → motion — a shimmer ripple that quickens with change.
///
/// Reusable: it takes plain value inputs (a snapshot-polling closure), so previews and
/// the real transport bar share it. The caller sizes it (`.frame`). It polls the latest
/// snapshot each frame and smooths it (attack/release) so the instrument breathes.
struct VibeMeterView: View {
    /// Polled once per frame for the latest master-mix snapshot. In the app this is
    /// `appModel.vibeSeed ?? store.masterAnalysis()` — the seed override (for captures)
    /// preferred over the live engine poll. A closure, so no engine coupling here.
    var snapshot: () -> MasterAnalysisSnapshot

    /// Frame-to-frame smoothing state. A plain (non-observable) reference held in
    /// `@State` — the established "scratch object" pattern: advancing it inside the
    /// `TimelineView` closure schedules no view invalidation (the timeline drives the
    /// next frame), so the smoother persists across frames without an update loop.
    @State private var smoother = VibeSmoother()

    /// Pause the display link when the window isn't active — no point burning frames
    /// on an instrument nobody's looking at (the "pause when inactive" guidance).
    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        TimelineView(.animation(paused: controlActiveState == .inactive)) { timeline in
            let state = smoother.advance(to: timeline.date, snapshot: snapshot())
            let rgb = Self.components(for: state)
            let color = Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1)
            Canvas { context, size in
                Self.draw(state, phase: smoother.phase, in: &context,
                          size: size, rgb: rgb, color: color)
            }
            // The wide house-recipe halo (docs/DESIGN-LANGUAGE.md "Glow recipe"),
            // intensity following the core brightness — dim ember → blazing core.
            .glow(color, radius: 9, intensity: state.isDormant ? 0.18 : 0.30 + state.brightness * 0.45)
        }
        .accessibilityLabel("Session vibe")
        .accessibilityValue(accessibilityValue)
    }

    /// A plain-language read of the current mix feel (for VoiceOver).
    private var accessibilityValue: String {
        let s = smoother.model
        if s.isDormant { return "quiet" }
        let warmth = s.hue < 0.4 ? "warm" : (s.hue > 0.6 ? "bright" : "balanced")
        let energy = s.brightness > 0.66 ? "loud" : (s.brightness > 0.33 ? "medium" : "soft")
        return "\(energy), \(warmth)"
    }

    // MARK: - Color

    /// The instrument's current color components from the smoothed hue. A fully dormant
    /// meter forces the warm-amber end so silence reads as a warm ember, not a cold dot.
    static func components(for state: VibeMeterModel) -> (r: Double, g: Double, b: Double) {
        VibeMeterModel.rampColor(hue: state.isDormant ? 0 : state.hue)
    }

    // MARK: - Drawing

    /// Draws the orb: a radial-gradient body under a crisp neon rim, with a hot core.
    /// All geometry is derived from the smoothed state; nothing is retained between
    /// frames beyond the small point buffer built here.
    static func draw(_ state: VibeMeterModel, phase: Double, in context: inout GraphicsContext,
                     size: CGSize, rgb: (r: Double, g: Double, b: Double), color: Color) {
        let cx = size.width / 2
        let cy = size.height / 2
        let half = min(size.width, size.height) / 2

        // Core grows with level; floored so a dormant ember is always a visible dot.
        let core = 2.2 + state.brightness * (half * 0.22)
        let ringBase = core + half * 0.14
        let ampMax = max(1, half - ringBase - 1.5)
        let ripple = state.motion * (half * 0.10)

        let points = silhouettePoints(
            state: state, cx: cx, cy: cy,
            ringBase: ringBase, ampMax: ampMax, ripple: ripple, phase: phase)
        let body = smoothClosedPath(points)

        // 1) Body: a radial gradient, hot at the core, fading to a faint edge.
        let glow = state.isDormant ? 0.16 : 0.42 + state.brightness * 0.42
        let hot = whiten(rgb, 0.35 * state.brightness)
        let bodyGradient = GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: hot.opacity(min(1, glow + 0.15)), location: 0),
                .init(color: color.opacity(glow), location: 0.45),
                .init(color: color.opacity(glow * 0.18), location: 1),
            ]),
            center: CGPoint(x: cx, y: cy),
            startRadius: 0, endRadius: half)
        context.fill(body, with: bodyGradient)

        // 2) Rim: a thin, brighter neon stroke — the crisp "core-stroke" of the recipe.
        context.stroke(body, with: .color(color.opacity(state.isDormant ? 0.30 : 0.85)),
                       lineWidth: 1)

        // 3) Core: the hottest point, toward white when loud, always a warm ember dim.
        let coreColor = whiten(rgb, 0.5 * state.brightness)
        let corePath = Path(ellipseIn: CGRect(x: cx - core, y: cy - core,
                                              width: core * 2, height: core * 2))
        context.fill(corePath, with: .color(coreColor.opacity(state.isDormant ? 0.5 : 0.95)))
    }

    /// The orb's boundary points: bass (band 0) at the bottom, treble (band 23) at the
    /// top, swept up the right side and mirrored to the left — a bilaterally-symmetric
    /// closed silhouette. Each band's normalized magnitude sets its radius, plus a
    /// per-band shimmer ripple that scales with motion.
    static func silhouettePoints(state: VibeMeterModel, cx: CGFloat, cy: CGFloat,
                                 ringBase: CGFloat, ampMax: CGFloat,
                                 ripple: CGFloat, phase: Double) -> [CGPoint] {
        let n = state.bands.count            // 24
        guard n > 1 else { return [] }
        func radius(_ i: Int) -> CGFloat {
            let m = CGFloat(state.bands[i])
            let shimmer = ripple * CGFloat(sin(phase + Double(i) * 0.9))
            return ringBase + m * ampMax * 0.9 + shimmer
        }
        func point(bandFrac frac: Double, radius r: CGFloat) -> CGPoint {
            // +90° = straight down (bass apex), −90° = straight up (treble apex).
            let angle = Double.pi / 2 - frac * Double.pi
            return CGPoint(x: cx + r * CGFloat(cos(angle)),
                           y: cy + r * CGFloat(sin(angle)))
        }
        var pts: [CGPoint] = []
        pts.reserveCapacity(n * 2)
        // Right side: band 0 (bottom apex) → band 23 (top apex).
        for i in 0..<n {
            pts.append(point(bandFrac: Double(i) / Double(n - 1), radius: radius(i)))
        }
        // Left side: mirror band 22 → band 1 (apexes are shared, so skip 23 and 0).
        for i in stride(from: n - 2, through: 1, by: -1) {
            let p = point(bandFrac: Double(i) / Double(n - 1), radius: radius(i))
            pts.append(CGPoint(x: 2 * cx - p.x, y: p.y))
        }
        return pts
    }

    /// A smooth closed path through `points` via midpoint quad curves — rounds the
    /// polygon so the orb reads organic, not faceted, even at a tiny transport size.
    static func smoothClosedPath(_ points: [CGPoint]) -> Path {
        var path = Path()
        guard points.count > 2 else { return path }
        func mid(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
            CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        }
        path.move(to: mid(points[points.count - 1], points[0]))
        for i in 0..<points.count {
            let cur = points[i]
            let next = points[(i + 1) % points.count]
            path.addQuadCurve(to: mid(cur, next), control: cur)
        }
        path.closeSubpath()
        return path
    }

    /// Blend rgb components toward white by `t` (0…1) — for the hot-toward-white core.
    static func whiten(_ c: (r: Double, g: Double, b: Double), _ t: Double) -> Color {
        let f = min(max(t, 0), 1)
        return Color(.sRGB, red: c.r + (1 - c.r) * f,
                     green: c.g + (1 - c.g) * f,
                     blue: c.b + (1 - c.b) * f, opacity: 1)
    }
}

/// Non-observable scratch smoother held in the view's `@State`. Advancing it inside
/// the `TimelineView` closure mutates fields (no reassignment, no `@Observable`), so
/// it schedules no invalidation — the timeline alone drives the next frame. Also
/// carries the shimmer phase, advanced by real elapsed time so motion is frame-rate
/// independent.
final class VibeSmoother {
    private(set) var model = VibeMeterModel()
    private(set) var phase: Double = 0
    private var lastDate: Date?

    /// Advances the model + shimmer phase toward `snapshot` over the real elapsed time
    /// since the last frame (capped, so a stalled/paused frame can't snap the visual),
    /// and returns the fresh state for drawing.
    func advance(to date: Date, snapshot: MasterAnalysisSnapshot) -> VibeMeterModel {
        let dt = lastDate.map { min(max(date.timeIntervalSince($0), 0), 0.1) } ?? (1.0 / 60)
        lastDate = date
        model.update(with: snapshot, deltaTime: dt)
        // Shimmer speeds up with motion (energy that's moving): 2.2 → ~7 rad/s.
        phase += dt * (2.2 + model.motion * 4.8)
        if phase > .pi * 2 { phase -= .pi * 2 }
        return model
    }
}
