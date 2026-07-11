import Foundation
import DAWCore

/// The pure, headless mapping + smoothing behind the **session vibe meter** — the
/// app's signature "glowing instrument" (M8 vm-b; VISION.md:16). It turns one
/// `MasterAnalysisSnapshot` (vm-a's 24-band / level / peak / centroid / flux data
/// source) into the normalized visual primitives the `VibeMeterView` Canvas draws,
/// and smooths them frame-to-frame so the instrument *breathes* rather than jitters.
///
/// Everything perceptual lives here so it's unit-tested without a running app (the
/// `ClipStretch`/`PanelDensity` precedent): a bass-heavy mix maps warm and heavy, a
/// bright mix cool and airy, and silence maps to a dim ember (never a black hole).
///
/// **NO VIOLET** (docs/DESIGN-LANGUAGE.md Rule 3 — violet = AI identity only). The
/// color field runs a **warm-amber ↔ cyan** ramp whose green channel stays high at
/// both poles, so the interpolation never passes through a violet/magenta hue; a
/// headless test (`rampColor`) pins that invariant so the marquee visual can never
/// regress into the AI color.
///
/// The four mapped quantities (the settled mapping):
/// - **centroid → hue** `0…1` (0 = warm amber / bassy·dark, 1 = cyan / bright·airy),
///   a log-frequency position over the band range 40 Hz → 16 kHz.
/// - **level → brightness** `0…1` (the core glow intensity; floor → 0, full → 1).
/// - **bands → geometry** — each band's dB folds to a `0…1` radius that shapes the
///   orb's spectral silhouette (bass at the bottom, treble at the top).
/// - **flux → motion** `0…1` (the shimmer/ripple rate — energy that's *moving*).
public struct VibeMeterModel: Equatable, Sendable {

    // MARK: Mapped, smoothed visual state (what the Canvas reads)

    /// Hue position `0…1` along the warm-amber (0) ↔ cyan (1) ramp. Smoothed.
    public private(set) var hue: Double
    /// Core glow intensity `0…1` from the short-term level. Smoothed (asymmetric:
    /// fast attack, slow release — the "breathing" ballistics).
    public private(set) var brightness: Double
    /// Per-band silhouette radii `0…1` (24 values, bass → treble). Smoothed.
    public private(set) var bands: [Double]
    /// Motion rate `0…1` from spectral flux — how fast the corona shimmers. Smoothed.
    public private(set) var motion: Double

    /// True when the instrument sits at/near its floor — the **dim ember** state
    /// (stopped / silent). Derived from the smoothed fields so it can never disagree
    /// with what's drawn. Silence looks dormant, not black.
    public var isDormant: Bool {
        brightness < Self.dormantBrightness && (bands.max() ?? 0) < Self.dormantBand
    }

    // MARK: - Mapping range constants

    /// Log-frequency hue ends — the band range vm-a analyzes (40 Hz → 16 kHz).
    public static let hueFloorHz: Float = 40
    public static let hueCeilingHz: Float = 16_000
    /// Level → brightness runs the full snapshot dB span (−80 → 0).
    public static let levelFloorDB: Float = MasterAnalysisSnapshot.floorDB   // −80
    public static let levelCeilingDB: Float = 0
    /// Band dB → geometry span. Tighter than the raw floor so per-band energy —
    /// which sits well below 0 dB in real mixes — reads with punchy dynamic range
    /// (below `bandFloorDB` → nothing, at/above `bandCeilingDB` → full extent).
    public static let bandFloorDB: Float = -72
    public static let bandCeilingDB: Float = -6

    /// Dormant thresholds (the smoothed floor where the instrument reads as a dim
    /// ember). Deliberately low so a barely-audible tail still stirs the glow.
    static let dormantBrightness: Double = 0.045
    static let dormantBand: Double = 0.045

    // MARK: - Smoothing time constants (seconds)

    /// Level/band ballistics: energy jumps IN fast (attack) and eases OUT slowly
    /// (release), so the meter breathes with the music instead of strobing.
    static let attackTau: Double = 0.05
    static let releaseTau: Double = 0.32
    /// Hue glides symmetrically so color drifts warm↔cool without snapping.
    static let hueTau: Double = 0.18
    /// Motion follows flux quickly on the way up, medium on the way down.
    static let motionAttackTau: Double = 0.04
    static let motionReleaseTau: Double = 0.24

    // MARK: - Init (the floor / dormant state)

    /// A fresh model reads the dim-ember floor: no glow, a flat silhouette, still.
    /// This is exactly what a stopped/silent session settles to.
    public init() {
        hue = 0
        brightness = 0
        bands = [Double](repeating: 0, count: MasterAnalysisSnapshot.bandCount)
        motion = 0
    }

    // MARK: - Frame update (smoothing toward the snapshot's mapped targets)

    /// Advances the smoothed state one frame toward `snapshot`'s mapped targets over
    /// `deltaTime` seconds. Called each `TimelineView` tick with the freshly polled
    /// snapshot; asymmetric one-pole filters give the attack/release "breathing".
    /// `deltaTime` should be clamped by the caller (a stalled frame must not snap the
    /// visual); a non-positive `deltaTime` is a no-op.
    public mutating func update(with snapshot: MasterAnalysisSnapshot, deltaTime: Double) {
        guard deltaTime > 0 else { return }

        let targetHue = Self.hue(forCentroidHz: snapshot.centroidHz)
        let targetBrightness = Self.brightness(forLevelDB: snapshot.levelDB)
        let targetMotion = Self.motion(forFlux: snapshot.flux)

        hue = Self.smooth(hue, toward: targetHue, deltaTime: deltaTime,
                          risingTau: Self.hueTau, fallingTau: Self.hueTau)
        brightness = Self.smooth(brightness, toward: targetBrightness, deltaTime: deltaTime,
                                 risingTau: Self.attackTau, fallingTau: Self.releaseTau)
        motion = Self.smooth(motion, toward: targetMotion, deltaTime: deltaTime,
                             risingTau: Self.motionAttackTau, fallingTau: Self.motionReleaseTau)

        for i in bands.indices {
            let db = i < snapshot.bands.count ? snapshot.bands[i] : MasterAnalysisSnapshot.floorDB
            let target = Self.bandMagnitude(forDB: db)
            bands[i] = Self.smooth(bands[i], toward: target, deltaTime: deltaTime,
                                   risingTau: Self.attackTau, fallingTau: Self.releaseTau)
        }
    }

    // MARK: - Pure mapping curves (testable independent of smoothing)

    /// Spectral centroid → hue position `0…1`. A **log-frequency** placement over
    /// 40 Hz → 16 kHz (matching the band range): a deep/bassy mix (low centroid)
    /// sits near 0 (warm amber), a bright mix (high centroid) near 1 (cyan). Silence
    /// reports centroid 0, which clamps to the warmest end (moot — it's dormant).
    /// Monotonically non-decreasing in `centroidHz`.
    public static func hue(forCentroidHz centroidHz: Float) -> Double {
        let f = max(centroidHz, hueFloorHz)
        let lo = log2(Double(hueFloorHz))
        let hi = log2(Double(hueCeilingHz))
        return clamp01((log2(Double(f)) - lo) / (hi - lo))
    }

    /// Short-term level (dB) → core brightness `0…1`, linear over the snapshot's
    /// full −80 → 0 dB span: floor → 0 (dim ember), full-scale → 1 (blazing core).
    /// Monotonically non-decreasing.
    public static func brightness(forLevelDB levelDB: Float) -> Double {
        clamp01(Double(levelDB - levelFloorDB) / Double(levelCeilingDB - levelFloorDB))
    }

    /// One band's dB → silhouette radius `0…1` over the −72 → −6 dB geometry span.
    /// Monotonically non-decreasing; below the floor → 0, at/above the ceiling → 1.
    public static func bandMagnitude(forDB db: Float) -> Double {
        clamp01(Double(db - bandFloorDB) / Double(bandCeilingDB - bandFloorDB))
    }

    /// Normalized spectral flux → motion rate `0…1`. Flux already arrives 0–1
    /// (vm-a); passed through, clamped for safety. Monotonic.
    public static func motion(forFlux flux: Float) -> Double {
        clamp01(Double(flux))
    }

    // MARK: - Color ramp (warm-amber ↔ cyan, NEVER violet)

    /// The instrument's color for a hue position `0…1`, as normalized sRGB
    /// components. Endpoints are the palette's **amber** (`#FFB84D`, warm/bassy) and
    /// **cyan** (`#3EE6FF`, cool/bright); the linear ramp keeps green high at both
    /// ends and through the middle, so it reads amber → teal → cyan and **never**
    /// passes through violet/magenta (Rule 3). A test asserts the no-violet
    /// invariant across the whole range so the marquee visual can't regress.
    public static func rampColor(hue: Double) -> (r: Double, g: Double, b: Double) {
        let t = clamp01(hue)
        // amber #FFB84D
        let a = (r: 1.0, g: 0.722, b: 0.302)
        // cyan #3EE6FF
        let c = (r: 0.243, g: 0.902, b: 1.0)
        return (
            r: a.r + (c.r - a.r) * t,
            g: a.g + (c.g - a.g) * t,
            b: a.b + (c.b - a.b) * t
        )
    }

    // MARK: - Helpers

    /// One-pole smoothing toward `target` over `deltaTime`, with a different time
    /// constant depending on whether the value is rising (attack) or falling
    /// (release) — the asymmetric ballistics that make the glow breathe.
    static func smooth(_ current: Double, toward target: Double, deltaTime: Double,
                       risingTau: Double, fallingTau: Double) -> Double {
        let tau = target >= current ? risingTau : fallingTau
        guard tau > 0 else { return target }
        let alpha = 1 - exp(-deltaTime / tau)
        return current + (target - current) * alpha
    }

    static func clamp01(_ x: Double) -> Double { min(max(x, 0), 1) }
}
