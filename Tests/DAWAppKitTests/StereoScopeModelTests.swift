import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Headless coverage for `StereoScopeModel` (m22-d) — the goniometer geometry
/// + stereo semantics behind the master strip's stereo-image block. Pinned
/// without a running app (the `VibeMeterModel`/`EQCurveEditorModel`
/// precedent): the 45° rotation is exact on known pairs, the display mapping
/// keeps the hardware convention (hard-L up-LEFT, matching the balance/pan
/// direction), trail fade indexing is monotone with the newest pair hottest,
/// the zone thresholds and their beginner-readable labels hold, silence reads
/// calm, and the `debug.scopeSeed` presets are deterministic figures.
@Suite("StereoScopeModel — goniometer geometry + stereo semantics (m22-d)")
struct StereoScopeModelTests {

    // MARK: - Rotation (x = (L−R)·s, y = (L+R)·s, s = 1/√2)

    @Test("rotation is exact on known pairs")
    func rotationExactOnKnownPairs() {
        let s = 1.0 / 2.0.squareRoot()

        // Mono: identical channels → x exactly 0 (the vertical line).
        let mono = StereoScopeModel.rotated(left: 0.5, right: 0.5)
        #expect(mono.x == 0)
        #expect(abs(mono.y - 1.0 * s) < 1e-12)

        // Anti-phase: R == −L → y exactly 0 (the horizontal line).
        let anti = StereoScopeModel.rotated(left: 0.5, right: -0.5)
        #expect(anti.y == 0)
        #expect(abs(anti.x - 1.0 * s) < 1e-12)

        // Hard-L: single channel → |x| == |y| (a 45° quadrant diagonal),
        // and full-scale lands at unit distance (0.8 → 0.8 from center).
        let hardL = StereoScopeModel.rotated(left: 0.8, right: 0)
        #expect(abs(abs(hardL.x) - abs(hardL.y)) < 1e-12)
        #expect(abs((hardL.x * hardL.x + hardL.y * hardL.y).squareRoot() - 0.8) < 1e-12)

        // Digital zero stays the exact center.
        let zero = StereoScopeModel.rotated(left: 0, right: 0)
        #expect(zero.x == 0 && zero.y == 0)
    }

    @Test("display mapping: unit square, hard-L up-LEFT, +mid up, clamped")
    func displayMappingConvention() {
        // Mono rides the vertical center line, above center for +mid.
        let mono = StereoScopeModel.displayPoint(left: 0.5, right: 0.5)
        #expect(Double(mono.x) == 0.5)
        #expect(Double(mono.y) < 0.5)

        // Anti-phase rides the horizontal center line.
        let anti = StereoScopeModel.displayPoint(left: 0.5, right: -0.5)
        #expect(Double(anti.y) == 0.5)
        #expect(Double(anti.x) != 0.5)

        // Hard-L: up-LEFT diagonal (x == y, both < 0.5) — the hardware
        // goniometer convention, agreeing with balance −1 = left.
        let hardL = StereoScopeModel.displayPoint(left: 0.8, right: 0)
        #expect(abs(Double(hardL.x) - Double(hardL.y)) < 1e-12)
        #expect(Double(hardL.x) < 0.5)

        // Hard-R mirrors: up-RIGHT diagonal (x > 0.5, same distance off
        // center as y).
        let hardR = StereoScopeModel.displayPoint(left: 0, right: 0.8)
        #expect(Double(hardR.x) > 0.5)
        #expect(abs((Double(hardR.x) - 0.5) - (0.5 - Double(hardR.y))) < 1e-12)

        // Louder-than-unit mono clamps to the square edge (scopes clip).
        let hot = StereoScopeModel.displayPoint(left: 1.0, right: 1.0)
        #expect(Double(hot.y) == 0)
        let hotNeg = StereoScopeModel.displayPoint(left: -1.0, right: -1.0)
        #expect(Double(hotNeg.y) == 1)
    }

    @Test("whole-frame display points keep figure shape and index order")
    func displayPointsWholeFrame() {
        // Mono preset: every point on the vertical center line.
        let mono = StereoScopePreset.mono.seed().frame
        let monoPoints = StereoScopeModel.displayPoints(mono)
        #expect(monoPoints.count == MasterScopeFrame.pairCount)
        #expect(monoPoints.allSatisfy { Double($0.x) == 0.5 })

        // Anti-phase preset: every point on the horizontal center line.
        let anti = StereoScopePreset.antiPhase.seed().frame
        #expect(StereoScopeModel.displayPoints(anti).allSatisfy { Double($0.y) == 0.5 })

        // Hard-left preset: the sine swings both ways, so the figure is the
        // full up-left ↔ down-right diagonal LINE (display x == y on every
        // point), with the positive excursion reaching the up-left quadrant.
        let hardL = StereoScopeModel.displayPoints(StereoScopePreset.hardLeft.seed().frame)
        #expect(hardL.allSatisfy { abs(Double($0.x) - Double($0.y)) < 1e-6 })
        #expect(hardL.contains { Double($0.x) < 0.35 })

        // The empty frame maps to 256 center points — the calm dot, never
        // garbage.
        let empty = StereoScopeModel.displayPoints(.empty)
        #expect(empty.allSatisfy { Double($0.x) == 0.5 && Double($0.y) == 0.5 })
    }

    // MARK: - Trail fade indexing

    @Test("trail fade: monotone tiers, oldest dimmest, newest hottest")
    func trailFadeIndexing() {
        let count = MasterScopeFrame.pairCount
        #expect(StereoScopeModel.trailTier(index: 0, count: count) == 0)
        #expect(StereoScopeModel.trailTier(index: count - 1, count: count)
            == StereoScopeModel.trailTierCount - 1)

        // Monotone non-decreasing across the whole frame.
        var last = 0
        for i in 0..<count {
            let tier = StereoScopeModel.trailTier(index: i, count: count)
            #expect(tier >= last)
            last = tier
        }

        // Opacity strictly increases tier to tier, dim ghost → hot head.
        for tier in 1..<StereoScopeModel.trailTierCount {
            #expect(StereoScopeModel.tierOpacity(tier) > StereoScopeModel.tierOpacity(tier - 1))
        }
        #expect(abs(StereoScopeModel.tierOpacity(0) - 0.08) < 1e-12)
        #expect(abs(StereoScopeModel.tierOpacity(StereoScopeModel.trailTierCount - 1) - 0.85) < 1e-12)

        // Out-of-range inputs clamp instead of trapping.
        #expect(StereoScopeModel.trailTier(index: -1, count: count) == 0)
        #expect(StereoScopeModel.trailTier(index: count + 10, count: count)
            == StereoScopeModel.trailTierCount - 1)
        #expect(StereoScopeModel.trailTier(index: 0, count: 0) == 0)
    }

    // MARK: - Correlation zones + labels

    @Test("correlation zones: ±0.2 boundaries, beginner-readable labels")
    func correlationZones() {
        #expect(StereoScopeModel.zone(forCorrelation: 1.0) == .inPhase)
        #expect(StereoScopeModel.zone(forCorrelation: 0.2) == .inPhase)   // boundary is healthy
        #expect(StereoScopeModel.zone(forCorrelation: 0.19) == .wide)
        #expect(StereoScopeModel.zone(forCorrelation: 0.0) == .wide)
        #expect(StereoScopeModel.zone(forCorrelation: -0.19) == .wide)
        #expect(StereoScopeModel.zone(forCorrelation: -0.2) == .antiPhase) // boundary warns
        #expect(StereoScopeModel.zone(forCorrelation: -1.0) == .antiPhase)

        // The verdict words are plain language, never a bare "CORR".
        #expect(StereoScopeModel.CorrelationZone.inPhase.label == "IN PHASE")
        #expect(StereoScopeModel.CorrelationZone.wide.label == "VERY WIDE")
        #expect(StereoScopeModel.CorrelationZone.antiPhase.label == "OUT OF PHASE")
    }

    @Test("bar position maps −1…+1 to 0…1, clamped")
    func barPosition() {
        #expect(StereoScopeModel.barPosition(correlation: -1) == 0)
        #expect(StereoScopeModel.barPosition(correlation: 0) == 0.5)
        #expect(StereoScopeModel.barPosition(correlation: 1) == 1)
        #expect(StereoScopeModel.barPosition(correlation: -2) == 0)
        #expect(StereoScopeModel.barPosition(correlation: 2) == 1)
    }

    // MARK: - Calm (silence) state

    @Test("silence reads calm; audible content does not")
    func calmState() {
        #expect(StereoScopeModel.isCalm(.empty))
        #expect(StereoScopeModel.isCalm(StereoScopePreset.silence.seed().frame))
        #expect(!StereoScopeModel.isCalm(StereoScopePreset.mono.seed().frame))

        // Sub-floor noise (≈ −66 dB) is calm; just-audible content is not.
        let n = MasterScopeFrame.pairCount
        let tiny = MasterScopeFrame(left: [Float](repeating: 0.0005, count: n),
                                    right: [Float](repeating: -0.0005, count: n))
        #expect(StereoScopeModel.isCalm(tiny))
        let audible = MasterScopeFrame(left: [Float](repeating: 0.002, count: n),
                                       right: [Float](repeating: 0.002, count: n))
        #expect(!StereoScopeModel.isCalm(audible))
    }

    // MARK: - Readout formatting

    @Test("readout formatters: signed correlation, percent width, pan-voice balance")
    func formatters() {
        #expect(StereoScopeModel.correlationText(1.0) == "+1.00")
        #expect(StereoScopeModel.correlationText(-0.31) == "-0.31")
        #expect(StereoScopeModel.correlationText(0.984) == "+0.98")
        #expect(StereoScopeModel.correlationText(0) == "0.00")
        #expect(StereoScopeModel.correlationText(-0.0001) == "0.00")  // −0.0 folds

        #expect(StereoScopeModel.widthText(0) == "0%")
        #expect(StereoScopeModel.widthText(0.42) == "42%")
        #expect(StereoScopeModel.widthText(1) == "100%")
        #expect(StereoScopeModel.widthText(1.5) == "100%")            // clamped

        // Balance speaks the pan knob's exact voice (MixerFormat.panString).
        #expect(StereoScopeModel.balanceText(0) == "C")
        #expect(StereoScopeModel.balanceText(-1) == "L100")
        #expect(StereoScopeModel.balanceText(0.5) == "R50")
        #expect(StereoScopeModel.balanceText(-2) == "L100")           // clamped
    }

    // MARK: - Scope well geometry

    @Test("square rect: largest centered square in any canvas size")
    func squareRect() {
        let wide = StereoScopeModel.squareRect(in: CGSize(width: 132, height: 64))
        #expect(Double(wide.width) == 64 && Double(wide.height) == 64)
        #expect(Double(wide.minX) == 34 && Double(wide.minY) == 0)

        let square = StereoScopeModel.squareRect(in: CGSize(width: 108, height: 108))
        #expect(Double(square.minX) == 0 && Double(square.width) == 108)
    }

    // MARK: - debug.scopeSeed presets

    @Test("presets: deterministic figures matching the m22-d analyzer laws")
    func presets() {
        for preset in StereoScopePreset.allCases {
            let seed = preset.seed()
            #expect(seed.frame.left.count == MasterScopeFrame.pairCount)
            #expect(seed.frame.right.count == MasterScopeFrame.pairCount)
            #expect(seed == preset.seed())   // bit-identical every call
        }

        let mono = StereoScopePreset.mono.seed()
        #expect(mono.frame.left == mono.frame.right)
        #expect(mono.correlation == 1 && mono.width == 0 && mono.balance == 0)

        let anti = StereoScopePreset.antiPhase.seed()
        #expect(anti.frame.right == anti.frame.left.map { -$0 })
        #expect(anti.correlation == -1 && anti.width == 1)

        // Hard-pan: the dead channel is all zeros, and the scalars follow the
        // phase-1 DSP law (correlation +1 — mono summing loses nothing —
        // width 0.5, balance ±1).
        let hardL = StereoScopePreset.hardLeft.seed()
        #expect(hardL.frame.right.allSatisfy { $0 == 0 })
        #expect(hardL.correlation == 1 && hardL.width == 0.5 && hardL.balance == -1)
        let hardR = StereoScopePreset.hardRight.seed()
        #expect(hardR.frame.left.allSatisfy { $0 == 0 })
        #expect(hardR.balance == 1)

        let cloud = StereoScopePreset.cloud.seed()
        #expect(cloud.correlation == 0 && cloud.width == 0.5 && cloud.balance == 0)
        #expect(!StereoScopeModel.isCalm(cloud.frame))

        let silence = StereoScopePreset.silence.seed()
        #expect(silence.frame == .empty)
        #expect(silence.correlation == 1 && silence.width == 0 && silence.balance == 0)
    }
}
