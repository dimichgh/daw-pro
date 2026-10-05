import Foundation

/// One frame of the session vibe orb, exactly as it would be DRAWN: the smoothed
/// model plus the shimmer phase. A pure value, so "same frame" is plain `==`.
public struct VibeOrbFrame: Equatable, Sendable {
    public var model: VibeMeterModel
    public var phase: Double

    public init(model: VibeMeterModel, phase: Double) {
        self.model = model
        self.phase = phase
    }
}

/// **Which frame the vibe orb draws on this tick — so a resting orb stops
/// re-displaying pixels it is already showing (WF-F1).**
///
/// The orb ticks at 60 Hz whatever the window state (the m23-r3b law: never
/// pause a live layer). Before this gate every tick re-rendered the orb's
/// `Canvas`, even when the smoothed state had not moved — a dormant orb, or one
/// that had converged on a steady mix. Each re-render is an `-[RBLayer display]`
/// of a SMALL layer, and RenderBox packs small layers into a shared surface
/// (`RB::SharedSurfaceGroup`). Re-using a slot there waits for the previous
/// commit to be DISPLAYED (`wait_for_allocations → -[CAContext
/// waitForCommitId:timeout:]`). With the display asleep or the screen locked no
/// commit is ever displayed, so every tick blocked the MAIN THREAD until the wait
/// timed out: measured 25–36 displays/s at ~25–30 ms each, 2.5–4.5 s of every
/// 3–6 s phase, `WEDGED` breadcrumbs of 3–7.7 s.
///
/// The gate keeps the timeline, the smoother and the witness exactly as they
/// were (the orb still TICKS 60/s; `LiveLayerWitness` still counts every tick).
/// It only decides what to hand the Equatable orb face: while the fresh state is
/// visually identical to the last DRAWN frame it returns that frame unchanged,
/// the face compares equal, and SwiftUI does not re-render it — no display, no
/// commit, no wait.
///
/// "Visually identical" is deliberately far below one pixel step:
/// - every smoothed field within `tolerance` (1e-6 of its 0…1 range — at the
///   transport's 22 pt orb radius that is 2e-5 pt of geometry, 3e-4 of an 8-bit
///   color step);
/// - the same dormant/awake read (`isDormant` switches the glow recipe, so it is
///   compared exactly, never within a tolerance);
/// - the same phase, unless BOTH frames' motion is below `motionFloor` — the
///   shimmer ripple is `motion × radius × 0.10 × sin(phase …)`, so with motion
///   that small the phase cannot move a pixel. (After audio stops, `motion`
///   decays geometrically and sticks at the smallest subnormal instead of
///   reaching 0, so an exact-zero test would redraw a still orb forever.)
///
/// And one exact redraw when the state SETTLES (bit-identical to the previous
/// tick) but the drawn frame is still a within-tolerance neighbour, so a resting
/// orb always shows its exact resting state — never an approximation of it.
public struct VibeOrbFrameGate: Sendable {
    /// Per-field tolerance on the 0…1 smoothed values.
    public static let tolerance: Double = 1e-6
    /// Below this motion the shimmer ripple is invisible, so phase is ignored.
    public static let motionFloor: Double = 1e-6

    /// The frame the orb last DREW (nil before the first tick).
    public private(set) var drawn: VibeOrbFrame?
    private var lastModel: VibeMeterModel?

    public init() {}

    /// The frame to draw on this tick. Returns the stored `drawn` frame
    /// unchanged (bit-identical, so an Equatable face skips its render) while
    /// `model`/`phase` are visually identical to it.
    public mutating func frame(for model: VibeMeterModel, phase: Double) -> VibeOrbFrame {
        let now = VibeOrbFrame(model: model, phase: phase)
        defer { lastModel = model }
        guard let last = drawn else {
            drawn = now
            return now
        }
        if Self.isVisuallyIdentical(now, last) {
            // Settled exactly, but what is on screen is a near neighbour: draw the
            // exact resting state once.
            if model == lastModel, last.model != model {
                drawn = now
                return now
            }
            return last
        }
        drawn = now
        return now
    }

    /// Whether two frames draw the same pixels (see the type's doc for the rule).
    public static func isVisuallyIdentical(_ a: VibeOrbFrame, _ b: VibeOrbFrame) -> Bool {
        isVisuallyIdentical(Visual(a), Visual(b))
    }

    /// Exactly the inputs the orb's drawing reads — the rule below compares
    /// these, so a test can build any pair (the model's fields are
    /// `private(set)`, reachable only through its smoothing).
    struct Visual: Equatable {
        var hue: Double
        var brightness: Double
        var motion: Double
        var bands: [Double]
        var isDormant: Bool
        var phase: Double

        init(hue: Double, brightness: Double, motion: Double, bands: [Double],
             isDormant: Bool, phase: Double) {
            self.hue = hue; self.brightness = brightness; self.motion = motion
            self.bands = bands; self.isDormant = isDormant; self.phase = phase
        }

        init(_ f: VibeOrbFrame) {
            self.init(hue: f.model.hue, brightness: f.model.brightness, motion: f.model.motion,
                      bands: f.model.bands, isDormant: f.model.isDormant, phase: f.phase)
        }
    }

    static func isVisuallyIdentical(_ x: Visual, _ y: Visual) -> Bool {
        guard x.isDormant == y.isDormant, x.bands.count == y.bands.count else { return false }
        guard abs(x.hue - y.hue) <= tolerance,
              abs(x.brightness - y.brightness) <= tolerance,
              abs(x.motion - y.motion) <= tolerance else { return false }
        for i in x.bands.indices where abs(x.bands[i] - y.bands[i]) > tolerance { return false }
        if x.motion < motionFloor && y.motion < motionFloor { return true }
        return x.phase == y.phase
    }
}
