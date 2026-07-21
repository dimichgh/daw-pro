import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Headless coverage for `GainReductionMeterModel` (m22-e phase 2) — the
/// scale/cap/zone/readout semantics behind the dynamics editor cards' GAIN
/// REDUCTION ladder and the insert chips' activity mini-bar. Pinned without a
/// running app (the `StereoScopeModel` precedent): the dB→fraction map hits
/// its exact anchors (0/3/6/12/24 → 0, 5/12, 5/8, 5/6, 1), the display cap
/// pins a gate's 80 dB slam at a full bar + the "CLOSED" verdict (never a
/// broken scale), zone boundaries face the problem, nil reads as the honest
/// dash, and the `debug.grSeed` blanket/targeted resolution holds.
@Suite("GainReductionMeterModel — GR scale + cap/closed semantics (m22-e)")
struct GainReductionMeterModelTests {

    // MARK: - Which effects meter

    @Test("only the built-in dynamics kinds grow a meter")
    func dynamicsKindsOnly() {
        for kind in EffectDescriptor.Kind.allCases {
            let expected = kind == .compressor || kind == .limiter || kind == .gate
            #expect(GainReductionMeterModel.isDynamicsKind(kind) == expected,
                    "\(kind) should\(expected ? "" : " not") meter")
        }
    }

    // MARK: - Scale (dB → bar fraction)

    @Test("fraction hits its exact anchors at 0/3/6/12/24/80 dB")
    func fractionExactAnchors() {
        // f(db) = (db/(db+6)) / (24/30) — chosen so the anchors are exact
        // rationals: 3 dB of compression reads at ~42% of the bar (the
        // musical region gets the travel), 24 dB is the full scale, and the
        // gate's 80 dB engine cap clamps to a pinned bar.
        #expect(GainReductionMeterModel.fraction(forDb: 0) == 0)
        #expect(abs(GainReductionMeterModel.fraction(forDb: 3) - 5.0 / 12.0) < 1e-12)
        #expect(abs(GainReductionMeterModel.fraction(forDb: 6) - 5.0 / 8.0) < 1e-12)
        #expect(abs(GainReductionMeterModel.fraction(forDb: 12) - 5.0 / 6.0) < 1e-12)
        #expect(GainReductionMeterModel.fraction(forDb: 24) == 1.0)
        #expect(GainReductionMeterModel.fraction(forDb: 80) == 1.0)
    }

    @Test("fraction is monotone, clamped, and garbage-proof")
    func fractionMonotoneAndClamped() {
        var previous = -1.0
        for db in stride(from: 0.0, through: 30.0, by: 0.5) {
            let f = GainReductionMeterModel.fraction(forDb: db)
            #expect(f >= 0 && f <= 1)
            #expect(f >= previous, "fraction must never decrease as GR deepens")
            previous = f
        }
        // Negative / non-finite input reads as an honest empty bar, never
        // garbage (only the engine's finite 0…80 readings ever pin it full).
        #expect(GainReductionMeterModel.fraction(forDb: -3) == 0)
        #expect(GainReductionMeterModel.fraction(forDb: .nan) == 0)
        #expect(GainReductionMeterModel.fraction(forDb: .infinity) == 0)
    }

    @Test("ticks are 0/3/6/12/24 with fractions spanning the full bar")
    func tickPositions() {
        #expect(GainReductionMeterModel.tickDbValues == [0, 3, 6, 12, 24])
        let fractions = GainReductionMeterModel.tickDbValues
            .map { GainReductionMeterModel.fraction(forDb: $0) }
        #expect(fractions.first == 0)
        #expect(fractions.last == 1)
        #expect(fractions == fractions.sorted())
        // Strictly increasing — no two marks collapse onto each other.
        #expect(Set(fractions).count == fractions.count)
    }

    // MARK: - Zones

    @Test("zone boundaries face the problem (6 dB firm, 12 dB heavy)")
    func zoneBoundaries() {
        let f6 = GainReductionMeterModel.fraction(forDb: 6)
        let f12 = GainReductionMeterModel.fraction(forDb: 12)
        for kind in [EffectDescriptor.Kind.compressor, .limiter] {
            #expect(GainReductionMeterModel.zone(atBarFraction: f6 - 0.001, kind: kind) == .light)
            #expect(GainReductionMeterModel.zone(atBarFraction: f6, kind: kind) == .firm)
            #expect(GainReductionMeterModel.zone(atBarFraction: f12 - 0.001, kind: kind) == .firm)
            #expect(GainReductionMeterModel.zone(atBarFraction: f12, kind: kind) == .heavy)
            #expect(GainReductionMeterModel.zone(atBarFraction: 1.0, kind: kind) == .heavy)
        }
    }

    @Test("a gate's ladder is uniformly green — closing is its job, not an alarm")
    func gateAlwaysLight() {
        for f in stride(from: 0.0, through: 1.0, by: 0.1) {
            #expect(GainReductionMeterModel.zone(atBarFraction: f, kind: .gate) == .light)
        }
    }

    // MARK: - "Closed" (gate) semantics

    @Test("a gate within 0.05 dB of the 80 dB engine cap reads closed")
    func gateClosedThreshold() {
        #expect(GainReductionMeterModel.engineCapDb == 80.0)
        #expect(GainReductionMeterModel.isClosed(db: 80.0, kind: .gate))
        #expect(GainReductionMeterModel.isClosed(db: 79.96, kind: .gate))
        #expect(!GainReductionMeterModel.isClosed(db: 79.9, kind: .gate))
        #expect(!GainReductionMeterModel.isClosed(db: 0, kind: .gate))
        // Only the gate speaks CLOSED — a pinned compressor/limiter still
        // reads its (crushing) number.
        #expect(!GainReductionMeterModel.isClosed(db: 80.0, kind: .compressor))
        #expect(!GainReductionMeterModel.isClosed(db: 80.0, kind: .limiter))
    }

    // MARK: - Readout

    @Test("readout: honest dash on nil, CLOSED on a shut gate, true dB elsewhere")
    func readoutText() {
        // nil = not reporting (hosted AU / headless) — the LOUDNESS warming
        // dash, never a fabricated 0. And no dangling unit tag.
        #expect(GainReductionMeterModel.readoutText(forDb: nil, kind: .compressor) == "–")
        #expect(!GainReductionMeterModel.showsUnit(forDb: nil, kind: .compressor))

        #expect(GainReductionMeterModel.readoutText(forDb: 0, kind: .compressor) == "0.0")
        #expect(GainReductionMeterModel.readoutText(forDb: 6.24, kind: .limiter) == "6.2")
        // Past the 24 dB DISPLAY cap the bar pins but the number stays honest.
        #expect(GainReductionMeterModel.readoutText(forDb: 31.4, kind: .compressor) == "31.4")
        #expect(GainReductionMeterModel.readoutText(forDb: 80, kind: .compressor) == "80.0")
        #expect(GainReductionMeterModel.showsUnit(forDb: 80, kind: .compressor))

        // The gate's full slam is plain language, unit-free.
        #expect(GainReductionMeterModel.readoutText(forDb: 80, kind: .gate) == "CLOSED")
        #expect(!GainReductionMeterModel.showsUnit(forDb: 80, kind: .gate))
        // …but a merely-working gate reads its number like everyone else.
        #expect(GainReductionMeterModel.readoutText(forDb: 12.5, kind: .gate) == "12.5")
        #expect(GainReductionMeterModel.showsUnit(forDb: 12.5, kind: .gate))
    }

    // MARK: - debug.grSeed resolution

    @Test("a blanket seed applies to every insert; targeted only to its own")
    func seedResolution() {
        let a = UUID(), b = UUID()

        let blanket = GainReductionSeed(db: 7.5, effectID: nil)
        #expect(blanket.value(forEffect: a) == 7.5)
        #expect(blanket.value(forEffect: b) == 7.5)

        let targeted = GainReductionSeed(db: 4.0, effectID: a)
        #expect(targeted.value(forEffect: a) == 4.0)
        // A mismatch yields nil — the caller falls through to the LIVE poll
        // (`seed?.value(forEffect: id) ?? live()`), so other meters stay real.
        #expect(targeted.value(forEffect: b) == nil)
    }
}
