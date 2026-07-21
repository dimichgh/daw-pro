import Foundation
import Testing
import DAWCore

/// m22-b Phase 1 — the shared RBJ response math (`EQFilterResponse`), pinned
/// with closed-form identities and the m22-a measured slope numbers
/// (design-m22b-eq-curve-editor §8.1, fixtures F1…F6). The engine-side
/// anti-drift twin (F7 predicted-vs-rendered) lives in
/// Tests/DAWEngineTests/EQResponsePinTests.swift; the standing bit-exact null
/// pin (F8) is EQv2Tests, untouched.
@Suite("EQ filter response — shared RBJ math (m22-b F1…F6)")
struct EQFilterResponseTests {
    private static let sampleRate = 48_000.0

    private func response(_ params: EQParams, at frequency: Double) -> Double {
        EQFilterResponse.responseDb(params: params, frequency: frequency,
                                    sampleRate: Self.sampleRate)
    }

    // MARK: - F1 peaking exact-at-fc

    @Test("F1: peaking ±6 dB Q 1 is exact at fc and log-symmetric about it")
    func peakingExactAtCenterAndLogSymmetric() {
        // |H(f0)| = A² is an algebraic identity of the RBJ peaking form, so
        // the response at fc is the full ±6.000 dB exactly.
        let boost = EQParams(peak1Freq: 1_000, peak1GainDb: 6, peak1Q: 1)
        #expect(abs(response(boost, at: 1_000) - 6.0) < 0.001)
        let cut = EQParams(peak1Freq: 1_000, peak1GainDb: -6, peak1Q: 1)
        #expect(abs(response(cut, at: 1_000) - (-6.0)) < 0.001)
        // Log-symmetry: one octave below vs one octave above fc.
        let below = response(boost, at: 500)
        let above = response(boost, at: 2_000)
        print("[measured] F1 peaking +6 @ 1 kHz: fc/2 \(below) dB, 2·fc \(above) dB")
        #expect(abs(below - above) < 0.02)
    }

    // MARK: - F2 cut corners exact

    @Test("F2: HP/LP corners sit at −3.0103 dB at either slope")
    func cutCornersAtMinusThreeDb() {
        // |H(f0)| = Q = 1/√2 for the 2nd-order section; 0.5412·1.3066 = 1/√2
        // for the 4th-order cascade (the Butterworth property) — −3.0103 dB
        // at the corner for BOTH slopes.
        for slope in [12, 24] {
            let hp = EQParams(highPassFreq: 100, highPassSlopeDbPerOct: slope)
            let hpCorner = response(hp, at: 100)
            #expect(abs(hpCorner - (-3.0103)) < 0.005, "HP corner, slope \(slope)")
            let lp = EQParams(lowPassFreq: 2_000, lowPassSlopeDbPerOct: slope)
            let lpCorner = response(lp, at: 2_000)
            #expect(abs(lpCorner - (-3.0103)) < 0.005, "LP corner, slope \(slope)")
        }
    }

    // MARK: - F3 slope attenuation (the m22-a measured numbers)

    @Test("F3: one-octave attenuation matches the m22-a measured slope numbers")
    func slopeAttenuationMatchesM22aMeasurements() {
        let hp12 = response(EQParams(highPassFreq: 100), at: 50)
        let hp24 = response(
            EQParams(highPassFreq: 100, highPassSlopeDbPerOct: 24), at: 50)
        let lp12 = response(EQParams(lowPassFreq: 2_000), at: 4_000)
        let lp24 = response(
            EQParams(lowPassFreq: 2_000, lowPassSlopeDbPerOct: 24), at: 4_000)
        print("[measured] F3 HP 100 Hz @ 50 Hz: \(hp12) dB (12), \(hp24) dB (24); "
              + "LP 2 kHz @ 4 kHz: \(lp12) dB (12), \(lp24) dB (24)")
        // The m22-a measured numbers (docs/ROADMAP.md m22-a; bilinear warping
        // included, the same in-test tolerance philosophy).
        #expect(abs(hp12 - (-12.30)) < 0.05)
        #expect(abs(hp24 - (-24.10)) < 0.05)
        #expect(abs(lp12 - (-12.59)) < 0.1)
        #expect(abs(lp24 - (-24.70)) < 0.1)
    }

    // MARK: - F4 shelf plateau + midpoint + nil-Q equivalence

    @Test("F4: shelf plateau, neutral far side, half-gain at fc — both shelves")
    func shelfPlateauAndMidpoint() {
        let ls = EQParams(lowShelfFreq: 200, lowShelfGainDb: 6)
        #expect(abs(response(ls, at: 20) - 6.0) < 0.1)       // plateau
        #expect(abs(response(ls, at: 20_000)) < 0.05)        // far side neutral
        #expect(abs(response(ls, at: 200) - 3.0) < 0.05)     // RBJ half-gain at fc
        // Mirror for the high shelf.
        let hs = EQParams(highShelfFreq: 2_000, highShelfGainDb: 6)
        #expect(abs(response(hs, at: 20_000) - 6.0) < 0.1)
        #expect(abs(response(hs, at: 20)) < 0.05)
        #expect(abs(response(hs, at: 2_000) - 3.0) < 0.05)
    }

    @Test("F4: nil shelf Q and explicit defaultShelfQ produce the same curve")
    func nilShelfQMatchesExplicitDefault() {
        // nil Q takes the legacy verbatim alpha `sinW0 / 2.0 * √2`; explicit
        // 1/√2 takes `sinW0 / (2.0 * q)` — mathematically identical, rounding
        // paths differ by ~1 ulp of alpha. Measured worst case on this grid is
        // 5.31e-9 dB (at 20 Hz on the +6 plateau, where log10 amplifies the
        // last-bit coefficient difference), so the bound is 1e-8 — still
        // ~5 orders tighter than anything audible or drawable. (The design's
        // stated 1e-9 is measurably violated by that one grid point — argued
        // in the m22-b Phase 1 close-out.)
        var maxDiff = 0.0
        for (fc, gain, isLow) in [(200.0, 6.0, true), (200.0, -12.0, true),
                                  (2_000.0, 6.0, false), (8_000.0, -4.0, false)] {
            let nilQ = isLow
                ? EQParams(lowShelfFreq: fc, lowShelfGainDb: gain)
                : EQParams(highShelfFreq: fc, highShelfGainDb: gain)
            var explicitQ = nilQ
            if isLow {
                explicitQ.lowShelfQ = EQParams.defaultShelfQ
            } else {
                explicitQ.highShelfQ = EQParams.defaultShelfQ
            }
            for f in EQFilterResponse.logFrequencyGrid() {
                maxDiff = max(maxDiff, abs(response(nilQ, at: f) - response(explicitQ, at: f)))
            }
        }
        print("[measured] F4 nil-Q vs explicit 1/√2: max |Δ| = \(maxDiff) dB")
        #expect(maxDiff < 1e-8)
    }

    // MARK: - F5 neutrality (exact zero)

    @Test("F5: neutral params and bypassed/0-gain bands contribute exactly 0")
    func neutralityIsExactZero() {
        let grid = EQFilterResponse.logFrequencyGrid()
        #expect(grid.count == 256)
        #expect(grid.first == 20)
        #expect(grid.last == 20_000)
        // All-default params: no active sections — exact 0.0 everywhere, not
        // "small" (mirrors the DSP skip law: inactive bands never run).
        let neutral = EQParams()
        for f in grid {
            #expect(response(neutral, at: f) == 0)
        }
        // A bypassed band contributes exactly 0 despite a non-neutral gain.
        let lsOff = EQParams(lowShelfFreq: 200, lowShelfGainDb: 6, lowShelfEnabled: false)
        #expect(EQFilterResponse.bandResponseDb(.lowShelf, params: lsOff,
                                                frequency: 100, sampleRate: Self.sampleRate) == 0)
        // An HP with a corner set but bypassed contributes exactly 0.
        let hpOff = EQParams(highPassFreq: 100, highPassEnabled: false)
        #expect(EQFilterResponse.bandResponseDb(.highPass, params: hpOff,
                                                frequency: 50, sampleRate: Self.sampleRate) == 0)
        // A band at gain exactly 0 dB contributes exactly 0 (peak1 default).
        #expect(EQFilterResponse.bandResponseDb(.peak1, params: neutral,
                                                frequency: 500, sampleRate: Self.sampleRate) == 0)
    }

    // MARK: - F6 plan equivalence

    /// Runs `fillRenderPlan` into sentinel-prefilled storage: coefficients
    /// NaN, active all-true — so the assertions prove the fill CLEARS
    /// inactive flags and leaves inactive slots' coefficients untouched (the
    /// engine's stale-slot contract).
    private func plan(_ params: EQParams) -> (coeffs: [Double], active: [Bool]) {
        var coeffs = [Double](repeating: .nan,
                              count: EQFilterResponse.sectionCount * 5)
        var active = [Bool](repeating: true, count: EQFilterResponse.sectionCount)
        EQFilterResponse.fillRenderPlan(params: params, sampleRate: Self.sampleRate,
                                        coefficients: &coeffs, active: &active)
        return (coeffs, active)
    }

    private func slot(_ coeffs: [Double], _ slot: Int, equals section: EQBiquad) -> Bool {
        let base = slot * 5
        return coeffs[base] == section.b0 && coeffs[base + 1] == section.b1
            && coeffs[base + 2] == section.b2 && coeffs[base + 3] == section.a1
            && coeffs[base + 4] == section.a2
    }

    private func slotUntouched(_ coeffs: [Double], _ slot: Int) -> Bool {
        (0..<5).allSatisfy { coeffs[slot * 5 + $0].isNaN }
    }

    @Test("F6: fillRenderPlan — all-active rich params, coefficients bit-equal to the sections")
    func renderPlanRichParamsBitEqual() {
        let params = EQParams(
            lowShelfFreq: 120, lowShelfGainDb: 4.5,
            peak1Freq: 450, peak1GainDb: -3.5, peak1Q: 1.8,
            peak2Freq: 3_200, peak2GainDb: 2.5, peak2Q: 0.9,
            highShelfFreq: 9_000, highShelfGainDb: -4,
            highPassFreq: 120, highPassSlopeDbPerOct: 24,
            lowPassFreq: 12_000, lowPassSlopeDbPerOct: 12,
            highShelfQ: 1.3)
        let (coeffs, active) = plan(params)
        // HP 24: both cascade slots; LP 12: first slot only.
        #expect(active == [true, true, true, true, true, true, true, false])
        let fs = Self.sampleRate
        #expect(slot(coeffs, 0, equals: EQFilterResponse.cutSection(
            highPass: true, freq: 120, q: EQFilterResponse.butterworth4QA, sampleRate: fs)))
        #expect(slot(coeffs, 1, equals: EQFilterResponse.cutSection(
            highPass: true, freq: 120, q: EQFilterResponse.butterworth4QB, sampleRate: fs)))
        #expect(slot(coeffs, 2, equals: EQFilterResponse.gainBand(
            kind: 0, freq: 120, gainDb: 4.5, q: nil, sampleRate: fs)))
        #expect(slot(coeffs, 3, equals: EQFilterResponse.gainBand(
            kind: 1, freq: 450, gainDb: -3.5, q: 1.8, sampleRate: fs)))
        #expect(slot(coeffs, 4, equals: EQFilterResponse.gainBand(
            kind: 1, freq: 3_200, gainDb: 2.5, q: 0.9, sampleRate: fs)))
        #expect(slot(coeffs, 5, equals: EQFilterResponse.gainBand(
            kind: 2, freq: 9_000, gainDb: -4, q: 1.3, sampleRate: fs)))
        #expect(slot(coeffs, 6, equals: EQFilterResponse.cutSection(
            highPass: false, freq: 12_000, q: EQFilterResponse.butterworth2Q, sampleRate: fs)))
        // The LP's second cascade slot: inactive AND untouched.
        #expect(slotUntouched(coeffs, 7))
    }

    @Test("F6: fillRenderPlan active matrix — HP off/12/24, bands off/0 dB/nil-enabled")
    func renderPlanActiveMatrix() {
        // HP slope 12: first slot only.
        let hp12 = plan(EQParams(highPassFreq: 100))
        #expect(Array(hp12.active[0...1]) == [true, false])
        #expect(slotUntouched(hp12.coeffs, 1))
        // HP corner nil (never turned on): both slots inactive, untouched.
        let hpNil = plan(EQParams())
        #expect(Array(hpNil.active[0...1]) == [false, false])
        #expect(slotUntouched(hpNil.coeffs, 0))
        #expect(slotUntouched(hpNil.coeffs, 1))
        // HP corner set but bypassed: both slots inactive.
        let hpOff = plan(EQParams(highPassFreq: 100, highPassSlopeDbPerOct: 24,
                                  highPassEnabled: false))
        #expect(Array(hpOff.active[0...1]) == [false, false])
        #expect(slotUntouched(hpOff.coeffs, 0))
        // LP bypassed with a corner set: slots 6-7 inactive.
        let lpOff = plan(EQParams(lowPassFreq: 5_000, lowPassSlopeDbPerOct: 24,
                                  lowPassEnabled: false))
        #expect(Array(lpOff.active[6...7]) == [false, false])
        // A gain band bypassed, and a gain band at exactly 0 dB: inactive,
        // coefficients untouched (band absent ≡ band off ≡ gain 0).
        let bandOff = plan(EQParams(peak1Freq: 450, peak1GainDb: -3.5, peak1Q: 1.8,
                                    peak1Enabled: false))
        #expect(bandOff.active[3] == false)
        #expect(slotUntouched(bandOff.coeffs, 3))
        let bandZero = plan(EQParams(peak2Freq: 3_200, peak2GainDb: 0))
        #expect(bandZero.active[4] == false)
        #expect(slotUntouched(bandZero.coeffs, 4))
        // `*Enabled` nil ≡ explicit true: bit-identical plans.
        let nilEnabled = plan(EQParams(lowShelfFreq: 200, lowShelfGainDb: 6))
        let explicitEnabled = plan(EQParams(lowShelfFreq: 200, lowShelfGainDb: 6,
                                            lowShelfEnabled: true))
        #expect(nilEnabled.active == explicitEnabled.active)
        #expect(slot(explicitEnabled.coeffs, 2, equals: EQFilterResponse.gainBand(
            kind: 0, freq: 200, gainDb: 6, q: nil, sampleRate: Self.sampleRate)))
        #expect(nilEnabled.coeffs[10...14] == explicitEnabled.coeffs[10...14])
    }
}
