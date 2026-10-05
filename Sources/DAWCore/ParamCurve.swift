import Foundation

/// How a parameter's 0…1 normalised travel maps onto its real range — the
/// ONE HOME for the taper, **declared** per parameter rather than inferred from
/// a free-text unit string (m39-a).
///
/// Before m39-a the mapping was re-derived independently in two editor models
/// (`EffectEditorModel.scale(for:)` and `PolySynthEditorModel.scale(for:)`),
/// each asking `unit == "Hz" && range.lowerBound > 0`. Two copies of one rule,
/// and a rule the UI knew but the wire did not: an agent driving `cutoffHz`
/// over `fx.describe` saw only name/range/unit/note and had to guess. The curve
/// is now a property of the spec, and both editors read it.
///
/// It is also load-bearing beyond the UI. The m39-e modulation depth law
/// (`docs/design/2026-09-19-modulation-layer.md` §7.3) is *defined* in terms of
/// this type: `depth` is a unitless `[-1, 1]` number whose musical meaning
/// comes from the target's curve — full depth on a `.logarithmic` target is
/// `±log2(hi/lo)` OCTAVES, which is why a depth of 0.1 on `cutoffHz` means the
/// same gesture at 200 Hz as at 8 kHz. `normalise` / `denormalise` in that law
/// are exactly `fraction(forValue:in:)` / `value(forFraction:in:)` below.
///
/// ⚠️ **This is a DECLARATION, not a heuristic.** Nothing here inspects a unit
/// string. If a future parameter is measured in Hz but genuinely wants linear
/// travel (or vice versa), declare it — that is the point of the type, and the
/// conformance test in `ParamCurveConformanceTests` documents how to record the
/// exemption rather than silently drifting.
public enum ParamCurve: String, Sendable, Equatable, Codable, CaseIterable {
    /// Even travel across the raw range. The safe default, and what every
    /// parameter that is not a frequency uses today: times, ratios, dB-valued
    /// ranges (already logarithmic in their own units), 0…1 amounts, and the
    /// 0/1 binary toggles.
    case linear

    /// Even travel across OCTAVES — `value = lo · (hi/lo)^f`. For frequencies:
    /// a linear 20 Hz–20 kHz slider buries everything below 2 kHz in its first
    /// tenth, and a linear-Hz modulation depth is a different musical gesture
    /// at each end of the range.
    ///
    /// ⚠️ Requires `lo > 0` — `log(0)` is `-infinity`. `ParamCurve.validate`
    /// checks this and `fraction`/`value` fall back to linear rather than
    /// returning NaN, so a mis-declared spec degrades instead of poisoning a
    /// render.
    case logarithmic

    /// Even travel across DECIBELS of a LINEAR-AMPLITUDE range —
    /// `value = lo · (hi/lo)^f` in amplitude terms is the same curve as
    /// `.logarithmic`, but the *depth law* reads it differently: full
    /// modulation depth means `±(dB(hi) − dB(lo))` decibels rather than octaves
    /// (§7.3's third row). Declared here because the modulation design names it
    /// for m39-a by name.
    ///
    /// ⭐ **No shipping parameter uses `.decibel` today**, and adopting one for
    /// an existing parameter would move its on-screen control — see the
    /// `gainLinear` note in `EffectParamSpec.specs(for: .gain)`. It exists so
    /// m39-e's depth law has its declared third domain, and for new parameters
    /// whose travel should read evenly in dB from birth.
    ///
    /// ⚠️ Requires `lo > 0`, for the same reason as `.logarithmic` plus a
    /// second one: `dB(0)` is `-infinity` and the normalisation divides by it.
    case decibel

    /// Whether this curve can be applied to `range` at all — false for the two
    /// multiplicative curves on a range that touches or crosses zero.
    ///
    /// The DECLARED safe default when this returns false is `.linear`: it is
    /// total over every finite range, and it is what `fraction`/`value` fall
    /// back to below, so a mis-declared spec degrades instead of emitting NaN
    /// into a slider or a render.
    ///
    /// ⚠️ That fallback is **SILENT** — it does not warn, and a mis-declared
    /// spec would simply behave linearly. What makes the mistake visible is the
    /// gate, not the runtime: `ParamCurveConformanceTests`'s
    /// `multiplicativeCurvesHaveAPositiveLowerBound` asserts this over every
    /// shipping spec table, so the declaration is caught at test time.
    public func isValid(for range: ClosedRange<Double>) -> Bool {
        switch self {
        case .linear:
            return true
        case .logarithmic, .decibel:
            return range.lowerBound > 0 && range.upperBound > 0
        }
    }

    /// The 0…1 normalised travel for a value in `range` (the depth law's
    /// `normalise`). Clamped both sides; a degenerate or invalid range returns
    /// 0 rather than NaN.
    public func fraction(forValue value: Double, in range: ClosedRange<Double>) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        guard hi > lo else { return 0 }
        let v = value.clamped(to: range)
        switch self {
        case .linear:
            return (v - lo) / (hi - lo)
        case .logarithmic, .decibel:
            // Both are the same multiplicative mapping; they differ only in
            // what the depth law calls the resulting unit (octaves vs dB).
            guard isValid(for: range) else {
                return (v - lo) / (hi - lo)
            }
            return (log(v / lo) / log(hi / lo)).clamped(to: 0...1)
        }
    }

    /// The value at a 0…1 normalised travel in `range` (the depth law's
    /// `denormalise`) — the exact inverse of `fraction(forValue:in:)`.
    public func value(forFraction fraction: Double, in range: ClosedRange<Double>) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        let f = fraction.clamped(to: 0...1)
        switch self {
        case .linear:
            return lo + f * (hi - lo)
        case .logarithmic, .decibel:
            guard isValid(for: range) else {
                return lo + f * (hi - lo)
            }
            return lo * pow(hi / lo, f)
        }
    }

    /// How wide full modulation depth is on this curve, in the curve's own
    /// unit — octaves for `.logarithmic`, decibels for `.decibel`, raw range
    /// units for `.linear` (§7.3's "full depth means" column). Not used by the
    /// UI; it is the number m39-e's depth law and `mod.describeKinds` need, and
    /// it lives here so it cannot be re-derived somewhere else.
    public func fullDepthSpan(in range: ClosedRange<Double>) -> Double {
        let lo = range.lowerBound, hi = range.upperBound
        guard hi > lo else { return 0 }
        switch self {
        case .linear:
            return hi - lo
        case .logarithmic:
            guard isValid(for: range) else { return hi - lo }
            return log2(hi / lo)
        case .decibel:
            guard isValid(for: range) else { return hi - lo }
            return 20 * log10(hi / lo)
        }
    }
}
