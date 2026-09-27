import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Headless coverage for `VibeOrbFrameGate` (WF-F1): the orb keeps TICKING every
/// frame, but re-DRAWS only when what it would draw has visibly changed. Every
/// "skipped" frame must come back BIT-IDENTICAL to the stored one — that is what
/// lets the Equatable orb face skip its render — and every visible change must
/// reach the screen on the tick it happens.
@Suite("VibeOrbFrameGate — draw only visibly new frames (WF-F1)")
struct VibeOrbFrameGateTests {

    private func snapshot(levelDB: Float = -12, flux: Float = 0, bands: [Float]? = nil,
                          bandDB: Float = -30, centroidHz: Float = 800) -> MasterAnalysisSnapshot {
        MasterAnalysisSnapshot(
            bands: bands ?? [Float](repeating: bandDB, count: MasterAnalysisSnapshot.bandCount),
            levelDB: levelDB, peakDB: levelDB + 4, centroidHz: centroidHz, flux: flux)
    }

    private func run(_ model: inout VibeMeterModel, on snap: MasterAnalysisSnapshot, seconds: Double) {
        var t = 0.0
        while t < seconds { model.update(with: snap, deltaTime: 1.0 / 60); t += 1.0 / 60 }
    }

    /// A converged model, then the same model moved toward a snapshot that differs
    /// in ONE band only, for `dt` seconds — a controlled, tiny, real change.
    private func nudged(dt: Double) -> (base: VibeMeterModel, moved: VibeMeterModel) {
        var base = VibeMeterModel()
        run(&base, on: snapshot(), seconds: 4)
        var bands = [Float](repeating: -30, count: MasterAnalysisSnapshot.bandCount)
        bands[3] = -6
        var moved = base
        moved.update(with: snapshot(bands: bands), deltaTime: dt)
        return (base, moved)
    }

    @Test("the first tick draws, and a resting dormant orb then never redraws — whatever the phase")
    func dormantOrbDrawsOnce() {
        var gate = VibeOrbFrameGate()
        let rest = VibeMeterModel()                     // the dormant floor, motion exactly 0
        let first = gate.frame(for: rest, phase: 0.1)
        #expect(first == VibeOrbFrame(model: rest, phase: 0.1))
        var redraws = 0
        for i in 1...600 where gate.frame(for: rest, phase: 0.1 + Double(i) * 0.04) != first {
            redraws += 1
        }
        #expect(redraws == 0, "a resting orb re-drew \(redraws) times in 600 ticks")
    }

    @Test("a moving orb redraws every tick — the shimmer phase is visible")
    func movingOrbRedrawsEveryTick() {
        var model = VibeMeterModel()
        run(&model, on: snapshot(flux: 0.9), seconds: 2)
        #expect(model.motion > 0.5, "precondition: the seeded mix moves (motion \(model.motion))")
        var gate = VibeOrbFrameGate()
        var previous = gate.frame(for: model, phase: 0)
        var skipped = 0
        for i in 1...120 {
            let f = gate.frame(for: model, phase: Double(i) * 0.05)
            if f == previous { skipped += 1 }
            previous = f
        }
        #expect(skipped == 0, "\(skipped) visible shimmer steps were skipped")
    }

    @Test("a real change past the tolerance draws on its tick; one inside it does not")
    func toleranceBoundary() {
        let inside = nudged(dt: 1e-8)
        let insideDelta = abs(inside.moved.bands[3] - inside.base.bands[3])
        #expect(insideDelta > 0 && insideDelta < VibeOrbFrameGate.tolerance,
                "precondition: a real sub-tolerance change (\(insideDelta))")
        var gate = VibeOrbFrameGate()
        let drawn = gate.frame(for: inside.base, phase: 0)
        #expect(gate.frame(for: inside.moved, phase: 0) == drawn, "a sub-tolerance change re-drew")

        let outside = nudged(dt: 1e-4)
        let outsideDelta = abs(outside.moved.bands[3] - outside.base.bands[3])
        #expect(outsideDelta > VibeOrbFrameGate.tolerance, "precondition: past tolerance (\(outsideDelta))")
        var gate2 = VibeOrbFrameGate()
        _ = gate2.frame(for: outside.base, phase: 0)
        #expect(gate2.frame(for: outside.moved, phase: 0) == VibeOrbFrame(model: outside.moved, phase: 0),
                "a past-tolerance change was not drawn")
    }

    @Test("a settled state inside the tolerance gets ONE exact redraw, then rests")
    func settledStateDrawsExactlyOnce() {
        let pair = nudged(dt: 1e-8)
        var gate = VibeOrbFrameGate()
        _ = gate.frame(for: pair.base, phase: 0)
        // First sighting: within tolerance and not yet settled (it differs from the
        // previous tick), so the old frame is kept.
        #expect(gate.frame(for: pair.moved, phase: 0).model == pair.base)
        // Second identical tick: settled. Draw the EXACT state once…
        #expect(gate.frame(for: pair.moved, phase: 0).model == pair.moved)
        // …and never again while it rests.
        let rest = gate.frame(for: pair.moved, phase: 0)
        var redraws = 0
        for _ in 0..<60 where gate.frame(for: pair.moved, phase: 0) != rest { redraws += 1 }
        #expect(redraws == 0)
    }

    @Test("the rule: dormant flips always count; sub-floor motion ignores phase; otherwise phase counts")
    func visualRule() {
        typealias V = VibeOrbFrameGate.Visual
        let bands = [Double](repeating: 0.2, count: MasterAnalysisSnapshot.bandCount)
        let a = V(hue: 0.5, brightness: 0.3, motion: 0, bands: bands, isDormant: false, phase: 0)
        // Identical but for the dormant read (a threshold straddle within tolerance).
        var b = a; b.isDormant = true
        #expect(!VibeOrbFrameGate.isVisuallyIdentical(a, b))
        // Sub-floor motion on both sides: phase cannot move a pixel.
        var c = a; c.motion = VibeOrbFrameGate.motionFloor / 2; c.phase = 2.0
        var d = a; d.motion = VibeOrbFrameGate.motionFloor / 3
        #expect(VibeOrbFrameGate.isVisuallyIdentical(c, d))
        // Visible motion: a phase step is a visible change.
        var e = a; e.motion = 0.5
        var f = e; f.phase = 0.01
        #expect(!VibeOrbFrameGate.isVisuallyIdentical(e, f))
        // Each field past tolerance is a change (anti-vacuity for the loop).
        let step = VibeOrbFrameGate.tolerance * 2
        var g = a; g.hue += step
        var h = a; h.brightness += step
        var k = a; k.bands[23] += step
        for changed in [g, h, k] { #expect(!VibeOrbFrameGate.isVisuallyIdentical(a, changed)) }
    }

    @Test("after audio stops the decaying tail comes to rest instead of redrawing forever")
    func decayTailComesToRest() {
        var model = VibeMeterModel()
        run(&model, on: snapshot(levelDB: -6, flux: 0.9, bandDB: -12), seconds: 2)
        let silence = snapshot(levelDB: -80, flux: 0, bandDB: -80, centroidHz: 0)
        var gate = VibeOrbFrameGate()
        var phase = 0.0
        var redrawsLate = 0
        var exactChangesLate = 0
        var last = gate.frame(for: model, phase: phase)
        var previousModel = model
        // 60 s of silence at 60 Hz. Past the first 10 s, nothing may redraw.
        for tick in 1...3600 {
            model.update(with: silence, deltaTime: 1.0 / 60)
            phase += 0.04
            let f = gate.frame(for: model, phase: phase)
            if tick > 600 {
                if f != last { redrawsLate += 1 }
                if model != previousModel { exactChangesLate += 1 }
            }
            last = f
            previousModel = model
        }
        #expect(redrawsLate == 0, "\(redrawsLate) redraws of a silent orb after its first 10 s")
        // Anti-vacuity: the tail keeps changing bit-wise well past 10 s (or motion
        // sticks above 0 with a moving phase), so an EXACT comparison would redraw.
        #expect(exactChangesLate > 0 || model.motion > 0,
                "precondition: the decay tail is not exactly still (\(exactChangesLate) changes, motion \(model.motion))")
    }
}
