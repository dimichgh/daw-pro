import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Unit pins for the m23-r3b **live-layer tick witness** — the seam
/// `debug.liveLayers` publishes and `scripts/gates/m23r3b-live-layers.mjs`
/// measures. The gate proves the VIEWS still tick; these prove the witness
/// reports what it was handed, which is what makes the gate's readings mean
/// anything.
@Suite("Live-layer tick witness (m23-r3b)")
@MainActor
struct LiveLayerWitnessTests {

    private func snapshot(correlation: Float, width: Float = 0.5,
                          balance: Float = 0) -> MasterAnalysisSnapshot {
        var s = MasterAnalysisSnapshot.floor
        s.correlation = correlation
        s.width = width
        s.balance = balance
        return s
    }

    @Test("a fresh witness has drawn nothing")
    func startsEmpty() {
        let w = LiveLayerWitness()
        #expect(w.vibe.ticks == 0)
        #expect(w.trail.ticks == 0)
        #expect(w.readouts.ticks == 0)
        // Dormant/calm is the honest resting state, not a value anyone drew.
        #expect(w.vibe.isDormant)
        #expect(w.trail.calm)
    }

    @Test("each layer counts its OWN frames — the three counters never move together")
    func countersAreIndependent() {
        // The gate's whole per-site pin structure rests on this: mutation M1
        // froze the orb while the trail and readouts kept ticking, and that is
        // only readable if one recorder cannot bump another's count.
        let w = LiveLayerWitness()
        w.recordVibeFrame(VibeMeterModel())
        w.recordVibeFrame(VibeMeterModel())
        w.recordTrailFrame(points: 256, calm: false, zone: .wide)
        #expect(w.vibe.ticks == 2)
        #expect(w.trail.ticks == 1)
        #expect(w.readouts.ticks == 0)
    }

    @Test("the vibe reading is the SMOOTHED state that was drawn")
    func vibeReadingMirrorsTheDrawnState() {
        let w = LiveLayerWitness()
        var model = VibeMeterModel()
        var loud = MasterAnalysisSnapshot.floor
        loud.levelDB = -3
        loud.centroidHz = 9000
        // Advance well past the 50 ms attack so the smoothed state is off the floor.
        for _ in 0..<60 { model.update(with: loud, deltaTime: 1.0 / 60) }
        w.recordVibeFrame(model)
        #expect(w.vibe.brightness == model.brightness)
        #expect(w.vibe.hue == model.hue)
        #expect(w.vibe.motion == model.motion)
        #expect(w.vibe.isDormant == model.isDormant)
        #expect(w.vibe.brightness > 0.5, "fixture check: the model must be off the floor")
    }

    @Test("the zone reported is the one the VIEW resolved, never re-derived here")
    func zoneIsHandedInNotRecomputed() {
        // The m23-r3 M9 lesson, pinned: a witness that recomputed the zone from
        // the correlation would agree with itself forever and stay green through
        // a mis-wired view. So this test hands in a zone that CONTRADICTS the
        // correlation and requires the witness to report what it was given.
        // If someone "fixes" the witness to derive the zone, this reddens — that
        // is the point, not a bug in the test.
        let w = LiveLayerWitness()
        w.recordReadoutFrame(snapshot(correlation: 0.95), zone: .antiPhase)
        #expect(w.readouts.zone == .antiPhase)
        #expect(StereoScopeModel.zone(forCorrelation: 0.95) == .inPhase,
                "fixture check: the handed-in zone really does contradict the value")
        w.recordTrailFrame(points: 4, calm: true, zone: .antiPhase)
        #expect(w.trail.zone == .antiPhase)
    }

    @Test("the readout reading carries every scalar the row draws")
    func readoutReadingCarriesAllScalars() {
        let w = LiveLayerWitness()
        w.recordReadoutFrame(snapshot(correlation: -0.88, width: 0.9, balance: 0.3),
                             zone: .antiPhase)
        #expect(abs(w.readouts.correlation - -0.88) < 1e-6)
        #expect(abs(w.readouts.width - 0.9) < 1e-6)
        #expect(abs(w.readouts.balance - 0.3) < 1e-6)
    }

    @Test("resetTicks zeroes the COUNTS and keeps the values — that pair IS the freeze signature")
    func resetKeepsTheDrawnValues() {
        // `ticks == 0` beside a live value is exactly what a frozen layer looks
        // like over the wire, so the reset must not wipe the value and turn a
        // freeze into a fresh-looking zero.
        let w = LiveLayerWitness()
        w.recordTrailFrame(points: 256, calm: false, zone: .wide)
        w.recordReadoutFrame(snapshot(correlation: -0.5), zone: .antiPhase)
        w.resetTicks()
        #expect(w.trail.ticks == 0)
        #expect(w.readouts.ticks == 0)
        #expect(w.trail.points == 256)
        #expect(w.trail.zone == .wide)
        #expect(w.readouts.zone == .antiPhase)
        #expect(abs(w.readouts.correlation - -0.5) < 1e-6)
    }
}
