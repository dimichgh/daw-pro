import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Headless coverage for `VibeMeterModel` (M8 vm-b) — the mapping + smoothing
/// behind the session vibe meter's "glowing instrument". Everything perceptual is
/// pinned here without a running app (the `ClipStretch`/`PanelDensity` precedent):
/// the dB→0-1 curves are monotone and land their anchor points, floors read the
/// dormant ember, the attack/release ballistics breathe (fast up, slow down), and —
/// the marquee invariant — the color ramp NEVER passes through violet (Rule 3:
/// violet = AI identity only).
@Suite("VibeMeterModel — mapping + smoothing (M8 vm-b)")
struct VibeMeterModelTests {

    /// A snapshot with a chosen centroid/level/flux and a flat band bed at `bandDB`.
    private func snapshot(centroidHz: Float = 2000, levelDB: Float = -12,
                          peakDB: Float = -6, flux: Float = 0.3,
                          bandDB: Float = -30) -> MasterAnalysisSnapshot {
        MasterAnalysisSnapshot(
            bands: [Float](repeating: bandDB, count: MasterAnalysisSnapshot.bandCount),
            levelDB: levelDB, peakDB: peakDB, centroidHz: centroidHz, flux: flux)
    }

    /// Runs the smoother forward long enough to converge on the snapshot's targets
    /// (many small frames) — the steady-state the visual reaches while a signal holds.
    private func converged(on snap: MasterAnalysisSnapshot, seconds: Double = 4) -> VibeMeterModel {
        var model = VibeMeterModel()
        let dt = 1.0 / 60
        var t = 0.0
        while t < seconds { model.update(with: snap, deltaTime: dt); t += dt }
        return model
    }

    // MARK: - Curve anchor points (the settled mapping)

    @Test("a 1 kHz centroid maps to a middle hue (warm↔cool balance point)")
    func centroidMidHue() {
        let h = VibeMeterModel.hue(forCentroidHz: 1000)
        #expect(h > 0.45 && h < 0.65, "1 kHz should land mid-ramp, got \(h)")
        // The poles read decisively warm / cool.
        #expect(VibeMeterModel.hue(forCentroidHz: 40) == 0)        // bass floor → amber
        #expect(VibeMeterModel.hue(forCentroidHz: 16_000) == 1)    // treble ceiling → cyan
        #expect(VibeMeterModel.hue(forCentroidHz: 60) < 0.2)       // deep/bassy → warm
        #expect(VibeMeterModel.hue(forCentroidHz: 9000) > 0.85)    // airy → cool
    }

    @Test("full-scale level maps to brightness 1; floor maps to 0")
    func brightnessEnds() {
        #expect(VibeMeterModel.brightness(forLevelDB: 0) == 1)
        #expect(VibeMeterModel.brightness(forLevelDB: MasterAnalysisSnapshot.floorDB) == 0)
        #expect(VibeMeterModel.brightness(forLevelDB: -40) == 0.5)   // linear midpoint
        // Below the floor still clamps to 0 (never negative glow).
        #expect(VibeMeterModel.brightness(forLevelDB: -120) == 0)
    }

    @Test("band dB maps to 0 below the floor and 1 at/above the ceiling")
    func bandEnds() {
        #expect(VibeMeterModel.bandMagnitude(forDB: MasterAnalysisSnapshot.floorDB) == 0)
        #expect(VibeMeterModel.bandMagnitude(forDB: -72) == 0)     // geometry floor
        #expect(VibeMeterModel.bandMagnitude(forDB: -6) == 1)      // geometry ceiling
        #expect(VibeMeterModel.bandMagnitude(forDB: 0) == 1)       // above ceiling clamps
        let mid = VibeMeterModel.bandMagnitude(forDB: -39)         // ~mid of −72…−6
        #expect(mid > 0.4 && mid < 0.6)
    }

    @Test("flux passes through as motion 0–1, clamped")
    func motionPassthrough() {
        #expect(VibeMeterModel.motion(forFlux: 0) == 0)
        #expect(VibeMeterModel.motion(forFlux: 0.5) == 0.5)
        #expect(VibeMeterModel.motion(forFlux: 1) == 1)
        #expect(VibeMeterModel.motion(forFlux: 2) == 1)     // clamped
        #expect(VibeMeterModel.motion(forFlux: -1) == 0)
    }

    // MARK: - Monotonicity (the curves never fold back)

    @Test("hue, brightness, and band magnitude are all monotonically non-decreasing")
    func monotonicCurves() {
        // Hue over a log sweep of the audible band.
        var lastHue = -1.0
        for hz in stride(from: Float(40), through: 16_000, by: 200) {
            let h = VibeMeterModel.hue(forCentroidHz: hz)
            #expect(h >= lastHue, "hue folded back at \(hz) Hz")
            lastHue = h
        }
        // Brightness over the dB span.
        var lastB = -1.0
        for db in stride(from: Float(-90), through: 6, by: 1) {
            let b = VibeMeterModel.brightness(forLevelDB: db)
            #expect(b >= lastB, "brightness folded back at \(db)")
            lastB = b
        }
        // Band magnitude over the dB span.
        var lastM = -1.0
        for db in stride(from: Float(-90), through: 6, by: 1) {
            let m = VibeMeterModel.bandMagnitude(forDB: db)
            #expect(m >= lastM, "band magnitude folded back at \(db)")
            lastM = m
        }
    }

    // MARK: - Dormant (the dim ember)

    @Test("a fresh model reads the dormant floor exactly")
    func freshIsDormant() {
        let model = VibeMeterModel()
        #expect(model.isDormant)
        #expect(model.brightness == 0)
        #expect(model.motion == 0)
        #expect(model.bands.count == MasterAnalysisSnapshot.bandCount)
        #expect(model.bands.allSatisfy { $0 == 0 })
    }

    @Test("holding the floor snapshot stays dormant; a loud mix wakes it")
    func floorStaysDormantLoudWakes() {
        // Feeding the all-floors snapshot never lifts the ember off the floor.
        let atFloor = converged(on: .floor)
        #expect(atFloor.isDormant)
        #expect(atFloor.brightness < VibeMeterModel.dormantBrightness)

        // A loud, energetic mix is decisively awake.
        let loud = converged(on: snapshot(centroidHz: 3000, levelDB: -6, flux: 0.6, bandDB: -18))
        #expect(!loud.isDormant)
        #expect(loud.brightness > 0.8)
        #expect(loud.motion > 0.4)
    }

    // MARK: - Smoothing converges to the mapped targets

    @Test("smoothing converges on the pure-mapping targets while a signal holds")
    func convergesToTargets() {
        let snap = snapshot(centroidHz: 1000, levelDB: -20, flux: 0.5, bandDB: -24)
        let model = converged(on: snap)
        #expect(abs(model.hue - VibeMeterModel.hue(forCentroidHz: 1000)) < 0.01)
        #expect(abs(model.brightness - VibeMeterModel.brightness(forLevelDB: -20)) < 0.01)
        #expect(abs(model.motion - VibeMeterModel.motion(forFlux: 0.5)) < 0.02)
        #expect(abs(model.bands[0] - VibeMeterModel.bandMagnitude(forDB: -24)) < 0.01)
    }

    // MARK: - Breathing ballistics (fast attack, slow release)

    @Test("brightness attacks faster than it releases (the breathing feel)")
    func attackFasterThanRelease() {
        let dt = 1.0 / 60
        // One attack step from the floor toward a loud target.
        var rising = VibeMeterModel()
        rising.update(with: snapshot(levelDB: 0), deltaTime: dt)
        let attackRise = rising.brightness              // distance climbed in one frame

        // One release step from a converged-loud state back toward the floor.
        var falling = converged(on: snapshot(levelDB: 0))
        let before = falling.brightness
        falling.update(with: .floor, deltaTime: dt)
        let releaseFall = before - falling.brightness   // distance fallen in one frame

        // From symmetric distances, attack covers more ground than release.
        #expect(attackRise > releaseFall,
                "attack (\(attackRise)) should outrun release (\(releaseFall))")
    }

    @Test("a non-positive deltaTime is a no-op")
    func nonPositiveDeltaIsNoop() {
        var model = converged(on: snapshot(levelDB: -10))
        let before = model
        model.update(with: .floor, deltaTime: 0)
        #expect(model == before)
        model.update(with: snapshot(levelDB: 0), deltaTime: -0.5)
        #expect(model == before)
    }

    @Test("a short band array is padded with the floor (defensive)")
    func shortBandArrayPads() {
        // A malformed snapshot with only 3 bands must not crash or read stale.
        let short = MasterAnalysisSnapshot(bands: [-10, -10, -10], levelDB: -10,
                                           peakDB: -6, centroidHz: 2000, flux: 0.2)
        var model = VibeMeterModel()
        for _ in 0..<240 { model.update(with: short, deltaTime: 1.0 / 60) }
        #expect(model.bands.count == MasterAnalysisSnapshot.bandCount)
        #expect(model.bands[0] > 0.5)                  // the provided loud bands lit
        #expect(model.bands[23] < 0.05)               // the missing bands read floor
    }

    // MARK: - The no-violet invariant (Rule 3)

    @Test("the color ramp NEVER passes through violet/magenta anywhere on 0…1")
    func rampHasNoViolet() {
        // Violet/magenta = red AND blue both strong while green is the weakest
        // channel. The amber↔cyan ramp keeps green high throughout, so this
        // signature must never appear — the marquee visual can't regress into the
        // AI color (docs/DESIGN-LANGUAGE.md Rule 3).
        for i in 0...100 {
            let t = Double(i) / 100
            let (r, g, b) = VibeMeterModel.rampColor(hue: t)
            let violet = r > 0.5 && b > 0.5 && g < min(r, b)
            #expect(!violet, "ramp turned violet at hue \(t): r=\(r) g=\(g) b=\(b)")
            // Green stays healthy across the whole ramp (amber and cyan both carry it).
            #expect(g > 0.6, "green dipped at hue \(t): \(g)")
        }
        // The poles are the palette's amber and cyan.
        let warm = VibeMeterModel.rampColor(hue: 0)
        #expect(warm.r > warm.b)                       // warm end leans red over blue
        let cool = VibeMeterModel.rampColor(hue: 1)
        #expect(cool.b > cool.r)                       // cool end leans blue over red
    }
}
