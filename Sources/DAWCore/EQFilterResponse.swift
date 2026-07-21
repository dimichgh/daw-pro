import Foundation

/// One normalized RBJ biquad section (a0 divided out) — POD, stack-only.
/// Field order matches the engine's flat per-slot coefficient layout
/// (b0, b1, b2, a1, a2).
public struct EQBiquad: Sendable, Equatable {
    public var b0, b1, b2, a1, a2: Double

    public init(b0: Double, b1: Double, b2: Double, a1: Double, a2: Double) {
        self.b0 = b0
        self.b1 = b1
        self.b2 = b2
        self.a1 = a1
        self.a2 = a2
    }
}

/// The EQ's coefficient and magnitude-response math (m22-b Phase 1),
/// extracted EXPRESSION-VERBATIM from `EQEffect` so the engine's render-side
/// derivation and the curve editor's drawn response share ONE source of
/// truth. Any change here is change to the audible DSP — the m22-a bit-exact
/// null pin (EQv2Tests) and the F7 predicted-vs-rendered pin
/// (EQResponsePinTests) both gate it.
///
/// HARD RULE (design-m22b-eq-curve-editor §3.2): the expressions are copied
/// character-for-character from the pre-extraction `EQEffect` — in particular
/// the legacy shelf alpha `sinW0 / 2.0 * (2.0).squareRoot()` (evaluation
/// order (sinW0/2)·√2 is load-bearing), the `pow(10.0, gainDb / 40.0)`
/// A-form, and the `min(freq, sampleRate * 0.49)` Nyquist clamp. No
/// algebraic cleanup, ever — IEEE-754 determinism is what keeps the null pin
/// bit-exact.
///
/// Render-path contract: `fillRenderPlan` runs on the render thread on
/// snapshot adoption/automation stores — pure libm, no allocation (it writes
/// in place into caller-preallocated `inout` arrays), no locks, no ObjC.
public enum EQFilterResponse {
    // MARK: - The engine's fixed slot layout (8 biquad sections in series)

    /// Slots 0-1: high-pass cascade; 2 low shelf; 3 peak 1; 4 peak 2;
    /// 5 high shelf; 6-7: low-pass cascade.
    public static let sectionCount = 8
    public static let highPassSlots = 0...1
    public static let lowShelfSlot = 2, peak1Slot = 3, peak2Slot = 4, highShelfSlot = 5
    public static let lowPassSlots = 6...7

    /// 2nd-order Butterworth Q (the 12 dB/oct section and each shelf's
    /// nil-Q equivalent): 1/√2.
    public static let butterworth2Q = 0.7071067811865476
    /// 4th-order Butterworth section Qs (the 24 dB/oct cascade):
    /// 1/(2cos(π/8)) and 1/(2cos(3π/8)).
    public static let butterworth4QA = 0.5411961001461969
    public static let butterworth4QB = 1.3065629648763766

    // MARK: - RBJ sections (expression-verbatim from EQEffect)

    /// RBJ Audio EQ Cookbook coefficients for one gain band, normalized by
    /// a0. `kind`: 0 = low shelf, 1 = peaking, 2 = high shelf. `q` nil on a
    /// shelf = the ORIGINAL fixed S = 1 expression, kept verbatim (not
    /// algebraically rearranged) so nil-Q output is bit-identical to the
    /// pre-m22-a build. Pure math, no allocation — render-safe.
    public static func gainBand(kind: Int, freq: Double, gainDb: Double,
                                q: Double?, sampleRate: Double) -> EQBiquad {
        let a = pow(10.0, gainDb / 40.0)
        let f = min(freq, sampleRate * 0.49)
        let w0 = 2.0 * Double.pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        var b0 = 1.0, b1 = 0.0, b2 = 0.0, a0 = 1.0, a1 = 0.0, a2 = 0.0
        switch kind {
        case 1:  // peaking, alpha from Q
            let alpha = sinW0 / (2.0 * (q ?? 1.0))
            b0 = 1.0 + alpha * a
            b1 = -2.0 * cosW0
            b2 = 1.0 - alpha * a
            a0 = 1.0 + alpha / a
            a1 = -2.0 * cosW0
            a2 = 1.0 - alpha / a
        default:  // shelves: alpha from Q, or the legacy fixed S = 1 slope
            let alpha: Double
            if let q {
                alpha = sinW0 / (2.0 * q)
            } else {
                alpha = sinW0 / 2.0 * (2.0).squareRoot()
            }
            let sqrtA = a.squareRoot()
            let twoSqrtAAlpha = 2.0 * sqrtA * alpha
            if kind == 0 {  // low shelf
                b0 = a * ((a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha)
                b1 = 2.0 * a * ((a - 1.0) - (a + 1.0) * cosW0)
                b2 = a * ((a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha)
                a0 = (a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha
                a1 = -2.0 * ((a - 1.0) + (a + 1.0) * cosW0)
                a2 = (a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha
            } else {  // high shelf
                b0 = a * ((a + 1.0) + (a - 1.0) * cosW0 + twoSqrtAAlpha)
                b1 = -2.0 * a * ((a - 1.0) + (a + 1.0) * cosW0)
                b2 = a * ((a + 1.0) + (a - 1.0) * cosW0 - twoSqrtAAlpha)
                a0 = (a + 1.0) - (a - 1.0) * cosW0 + twoSqrtAAlpha
                a1 = 2.0 * ((a - 1.0) - (a + 1.0) * cosW0)
                a2 = (a + 1.0) - (a - 1.0) * cosW0 - twoSqrtAAlpha
            }
        }
        return EQBiquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    /// One RBJ high/low-pass section at `q`, normalized by a0. Same
    /// render-thread contract as `gainBand`.
    public static func cutSection(highPass: Bool, freq: Double, q: Double,
                                  sampleRate: Double) -> EQBiquad {
        let f = min(freq, sampleRate * 0.49)
        let w0 = 2.0 * Double.pi * f / sampleRate
        let cosW0 = cos(w0)
        let sinW0 = sin(w0)
        let alpha = sinW0 / (2.0 * q)
        let b0: Double, b1: Double, b2: Double
        if highPass {
            b0 = (1.0 + cosW0) / 2.0
            b1 = -(1.0 + cosW0)
            b2 = (1.0 + cosW0) / 2.0
        } else {
            b0 = (1.0 - cosW0) / 2.0
            b1 = 1.0 - cosW0
            b2 = (1.0 - cosW0) / 2.0
        }
        let a0 = 1.0 + alpha
        let a1 = -2.0 * cosW0
        let a2 = 1.0 - alpha
        return EQBiquad(b0: b0 / a0, b1: b1 / a0, b2: b2 / a0, a1: a1 / a0, a2: a2 / a0)
    }

    // MARK: - The render plan (EQEffect's deriveRenderParams, verbatim)

    /// Fills caller-owned storage — `coefficients` is `sectionCount` × 5
    /// normalized coeffs laid out b0, b1, b2, a1, a2 per slot (the engine's
    /// flat `coeffs` shape); `active` is one flag per slot — reproducing the
    /// pre-extraction `deriveRenderParams`/`setCutPair` EXACTLY: a gain band
    /// is active iff its resolved `*Enabled` is true AND its gain is nonzero;
    /// HP/LP are active iff a corner is set AND not bypassed; slope 24
    /// cascades both slots at the 4th-order Butterworth Qs, slope 12 uses the
    /// first slot only at 1/√2. An INACTIVE slot's coefficients are left
    /// untouched (stale values are never read — the engine's contract).
    /// Writes in place via `inout` into preallocated arrays — NO allocation,
    /// render-safe.
    public static func fillRenderPlan(params p: EQParams, sampleRate: Double,
                                      coefficients: inout [Double],
                                      active: inout [Bool]) {
        fillCutPair(firstSlot: highPassSlots.lowerBound, highPass: true,
                    freq: p.highPassFreq, slope: p.highPassSlopeDbPerOct ?? 12,
                    enabled: p.highPassEnabled ?? true, sampleRate: sampleRate,
                    coefficients: &coefficients, active: &active)
        fillGainBand(slot: lowShelfSlot, kind: 0, enabled: p.lowShelfEnabled ?? true,
                     freq: p.lowShelfFreq, gainDb: p.lowShelfGainDb, q: p.lowShelfQ,
                     sampleRate: sampleRate, coefficients: &coefficients, active: &active)
        fillGainBand(slot: peak1Slot, kind: 1, enabled: p.peak1Enabled ?? true,
                     freq: p.peak1Freq, gainDb: p.peak1GainDb, q: p.peak1Q,
                     sampleRate: sampleRate, coefficients: &coefficients, active: &active)
        fillGainBand(slot: peak2Slot, kind: 1, enabled: p.peak2Enabled ?? true,
                     freq: p.peak2Freq, gainDb: p.peak2GainDb, q: p.peak2Q,
                     sampleRate: sampleRate, coefficients: &coefficients, active: &active)
        fillGainBand(slot: highShelfSlot, kind: 2, enabled: p.highShelfEnabled ?? true,
                     freq: p.highShelfFreq, gainDb: p.highShelfGainDb, q: p.highShelfQ,
                     sampleRate: sampleRate, coefficients: &coefficients, active: &active)
        fillCutPair(firstSlot: lowPassSlots.lowerBound, highPass: false,
                    freq: p.lowPassFreq, slope: p.lowPassSlopeDbPerOct ?? 12,
                    enabled: p.lowPassEnabled ?? true, sampleRate: sampleRate,
                    coefficients: &coefficients, active: &active)
    }

    /// One gain band into its slot — the pre-extraction `setBand` skip law:
    /// active iff `enabled && gainDb != 0`, coefficients untouched otherwise.
    private static func fillGainBand(slot: Int, kind: Int, enabled: Bool,
                                     freq: Double, gainDb: Double, q: Double?,
                                     sampleRate: Double,
                                     coefficients: inout [Double],
                                     active: inout [Bool]) {
        active[slot] = enabled && gainDb != 0
        guard active[slot] else { return }
        store(gainBand(kind: kind, freq: freq, gainDb: gainDb, q: q, sampleRate: sampleRate),
              slot: slot, into: &coefficients)
    }

    /// The HP or LP pair of slots — the pre-extraction `setCutPair` exactly:
    /// both slots inactive when `freq` is nil (the filter has never been
    /// turned on) or `enabled` is false; 12 dB/oct uses the first slot only
    /// and deactivates the second; 24 dB/oct cascades both.
    private static func fillCutPair(firstSlot: Int, highPass: Bool,
                                    freq: Double?, slope: Int, enabled: Bool,
                                    sampleRate: Double,
                                    coefficients: inout [Double],
                                    active: inout [Bool]) {
        guard let freq, enabled else {
            active[firstSlot] = false
            active[firstSlot + 1] = false
            return
        }
        if slope >= 24 {
            active[firstSlot] = true
            store(cutSection(highPass: highPass, freq: freq, q: butterworth4QA,
                             sampleRate: sampleRate),
                  slot: firstSlot, into: &coefficients)
            active[firstSlot + 1] = true
            store(cutSection(highPass: highPass, freq: freq, q: butterworth4QB,
                             sampleRate: sampleRate),
                  slot: firstSlot + 1, into: &coefficients)
        } else {
            active[firstSlot] = true
            store(cutSection(highPass: highPass, freq: freq, q: butterworth2Q,
                             sampleRate: sampleRate),
                  slot: firstSlot, into: &coefficients)
            active[firstSlot + 1] = false
        }
    }

    /// Element-wise in-place write (no whole-array reassignment — CoW-safe on
    /// the render thread).
    private static func store(_ section: EQBiquad, slot: Int,
                              into coefficients: inout [Double]) {
        let base = slot * 5
        coefficients[base] = section.b0
        coefficients[base + 1] = section.b1
        coefficients[base + 2] = section.b2
        coefficients[base + 3] = section.a1
        coefficients[base + 4] = section.a2
    }

    // MARK: - Magnitude response

    /// |H| in dB of one normalized biquad at `frequency` (w = 2π·f/fs):
    ///   num = b0²+b1²+b2² + 2(b0·b1 + b1·b2)·cos w + 2·b0·b2·cos 2w
    ///   den = 1 +a1²+a2² + 2(a1 + a1·a2)·cos w + 2·a2·cos 2w
    ///   dB  = 10·log10(num/den), epsilon-guarded, clamped to ±120, finite.
    public static func magnitudeDb(_ section: EQBiquad, frequency: Double,
                                   sampleRate: Double) -> Double {
        let w = 2.0 * Double.pi * frequency / sampleRate
        let cosW = cos(w)
        let cos2W = cos(2.0 * w)
        let b0 = section.b0, b1 = section.b1, b2 = section.b2
        let a1 = section.a1, a2 = section.a2
        let num = b0 * b0 + b1 * b1 + b2 * b2
            + 2.0 * (b0 * b1 + b1 * b2) * cosW
            + 2.0 * b0 * b2 * cos2W
        let den = 1.0 + a1 * a1 + a2 * a2
            + 2.0 * (a1 + a1 * a2) * cosW
            + 2.0 * a2 * cos2W
        let epsilon = 1e-30
        let db = 10.0 * log10(max(num, epsilon) / max(den, epsilon))
        guard db.isFinite else { return 0 }
        return min(max(db, -120.0), 120.0)
    }

    // MARK: - Logical bands (the UI-facing identity over the 8 slots)

    /// The six logical bands the editor draws (HP/LP each own a cascade pair).
    public enum Band: String, CaseIterable, Sendable {
        case highPass, lowShelf, peak1, peak2, highShelf, lowPass
    }

    /// One logical band's response in dB at `frequency`. An INACTIVE band —
    /// bypassed, gain exactly 0, or an HP/LP with no corner set — returns
    /// exactly 0 (mirrors the render plan's skip law bit-for-bit: the same
    /// activity test, the same sections at the same Qs). A cut band sums its
    /// active cascade slots (series sections add in dB).
    public static func bandResponseDb(_ band: Band, params: EQParams,
                                      frequency: Double, sampleRate: Double) -> Double {
        switch band {
        case .highPass:
            return cutPairResponseDb(
                highPass: true, enabled: params.resolvedHighPassEnabled,
                freq: params.resolvedHighPassFreq, slope: params.resolvedHighPassSlope,
                frequency: frequency, sampleRate: sampleRate)
        case .lowShelf:
            return gainBandResponseDb(
                kind: 0, enabled: params.resolvedLowShelfEnabled,
                freq: params.lowShelfFreq, gainDb: params.lowShelfGainDb,
                q: params.lowShelfQ, frequency: frequency, sampleRate: sampleRate)
        case .peak1:
            return gainBandResponseDb(
                kind: 1, enabled: params.resolvedPeak1Enabled,
                freq: params.peak1Freq, gainDb: params.peak1GainDb,
                q: params.peak1Q, frequency: frequency, sampleRate: sampleRate)
        case .peak2:
            return gainBandResponseDb(
                kind: 1, enabled: params.resolvedPeak2Enabled,
                freq: params.peak2Freq, gainDb: params.peak2GainDb,
                q: params.peak2Q, frequency: frequency, sampleRate: sampleRate)
        case .highShelf:
            return gainBandResponseDb(
                kind: 2, enabled: params.resolvedHighShelfEnabled,
                freq: params.highShelfFreq, gainDb: params.highShelfGainDb,
                q: params.highShelfQ, frequency: frequency, sampleRate: sampleRate)
        case .lowPass:
            return cutPairResponseDb(
                highPass: false, enabled: params.resolvedLowPassEnabled,
                freq: params.resolvedLowPassFreq, slope: params.resolvedLowPassSlope,
                frequency: frequency, sampleRate: sampleRate)
        }
    }

    private static func gainBandResponseDb(kind: Int, enabled: Bool, freq: Double,
                                           gainDb: Double, q: Double?,
                                           frequency: Double, sampleRate: Double) -> Double {
        guard enabled && gainDb != 0 else { return 0 }
        return magnitudeDb(
            gainBand(kind: kind, freq: freq, gainDb: gainDb, q: q, sampleRate: sampleRate),
            frequency: frequency, sampleRate: sampleRate)
    }

    private static func cutPairResponseDb(highPass: Bool, enabled: Bool, freq: Double,
                                          slope: Int, frequency: Double,
                                          sampleRate: Double) -> Double {
        guard enabled else { return 0 }
        if slope >= 24 {
            return magnitudeDb(
                cutSection(highPass: highPass, freq: freq, q: butterworth4QA,
                           sampleRate: sampleRate),
                frequency: frequency, sampleRate: sampleRate)
                + magnitudeDb(
                    cutSection(highPass: highPass, freq: freq, q: butterworth4QB,
                               sampleRate: sampleRate),
                    frequency: frequency, sampleRate: sampleRate)
        }
        return magnitudeDb(
            cutSection(highPass: highPass, freq: freq, q: butterworth2Q,
                       sampleRate: sampleRate),
            frequency: frequency, sampleRate: sampleRate)
    }

    /// Composite response = Σ per-band dB (series filters add in dB). All
    /// bands neutral → exactly 0.0 (a sum of exact zeros).
    public static func responseDb(params: EQParams, frequency: Double,
                                  sampleRate: Double) -> Double {
        var total = 0.0
        for band in Band.allCases {
            total += bandResponseDb(band, params: params,
                                    frequency: frequency, sampleRate: sampleRate)
        }
        return total
    }

    // MARK: - Editor grid

    /// `count` log-spaced Hz values over `lo`…`hi` inclusive — the curve
    /// editor's sampling grid. Main-actor tier (allocates its result).
    public static func logFrequencyGrid(count: Int = 256, lo: Double = 20,
                                        hi: Double = 20_000) -> [Double] {
        guard count > 1 else { return count == 1 ? [lo] : [] }
        let ratio = hi / lo
        return (0..<count).map { lo * pow(ratio, Double($0) / Double(count - 1)) }
    }
}
