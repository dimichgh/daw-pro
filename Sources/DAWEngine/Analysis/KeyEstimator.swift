import DAWCore
import Foundation

/// Krumhansl-Schmuckler key estimation over a 12-bin chroma vector (m21-e,
/// design-clip-analyze-audio §3a). Pure static math — the chroma itself is
/// accumulated by `AudioContentAnalyzer`'s STFT pass; this type only ranks
/// the 24 Krumhansl-Kessler profile rotations and applies the honesty gates.
///
/// REAL-TIME SAFETY: never referenced from the render path — offline analysis
/// only, inside the cache's detached task.
enum KeyEstimator {

    /// Krumhansl-Kessler probe-tone profiles (1982), tonic at index 0.
    /// Constants are v1 tuning — any change bumps
    /// `AudioContentAnalyzer.analyzerVersion`.
    static let majorProfile: [Double] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
    ]
    static let minorProfile: [Double] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
    ]

    /// `tonal` gates (design §3a): best correlation must reach this…
    static let tonalMinimumCorrelation = 0.5
    /// …and the chroma must not be this flat (percussion/noise chroma is
    /// near-uniform → spectral flatness near 1).
    static let tonalMaximumFlatness = 0.95
    /// Margin gate divisor: confidence = clamp01(r1) × clamp01((r1−r2)/0.1).
    static let confidenceMarginScale = 0.1

    /// Ranks all 24 keys against the chroma and applies the confidence /
    /// tonal gates. A zero (or degenerate) chroma reads r = 0 everywhere →
    /// confidence 0, tonal false, deterministic C-major-first ordering.
    static func estimate(chroma: [Double]) -> KeyEstimate {
        precondition(chroma.count == 12, "chroma must have 12 pitch classes")
        var ranked: [(tonic: Int, mode: String, r: Double)] = []
        ranked.reserveCapacity(24)
        for (mode, profile) in [("major", majorProfile), ("minor", minorProfile)] {
            for tonic in 0..<12 {
                var predicted = [Double](repeating: 0, count: 12)
                for pc in 0..<12 {
                    predicted[pc] = profile[((pc - tonic) % 12 + 12) % 12]
                }
                ranked.append((tonic, mode, pearson(chroma, predicted)))
            }
        }
        // Deterministic order: correlation desc, then tonic, then mode.
        ranked.sort {
            if $0.r != $1.r { return $0.r > $1.r }
            if $0.tonic != $1.tonic { return $0.tonic < $1.tonic }
            return $0.mode < $1.mode
        }

        let best = ranked[0]
        let r1 = best.r
        let r2 = ranked[1].r
        let confidence = clamp01(r1) * clamp01((r1 - r2) / confidenceMarginScale)
        let tonal = r1 >= tonalMinimumCorrelation
            && flatness(of: chroma) <= tonalMaximumFlatness
        return KeyEstimate(
            tonic: KeyEstimate.pitchClassesSharp[best.tonic],
            mode: best.mode,
            confidence: confidence,
            tonal: tonal,
            alternatives: ranked[1...3].map {
                KeyAlternative(tonic: KeyEstimate.pitchClassesSharp[$0.tonic],
                               mode: $0.mode, score: $0.r)
            })
    }

    /// Pearson correlation; 0 when either side is degenerate (zero variance)
    /// or the result is non-finite — a poisoned chroma must not rank keys.
    static func pearson(_ a: [Double], _ b: [Double]) -> Double {
        let n = Double(a.count)
        guard n > 1, a.count == b.count else { return 0 }
        let meanA = a.reduce(0, +) / n
        let meanB = b.reduce(0, +) / n
        var covariance = 0.0, varianceA = 0.0, varianceB = 0.0
        for i in a.indices {
            let da = a[i] - meanA
            let db = b[i] - meanB
            covariance += da * db
            varianceA += da * da
            varianceB += db * db
        }
        guard varianceA > 0, varianceB > 0 else { return 0 }
        let r = covariance / (varianceA * varianceB).squareRoot()
        return r.isFinite ? r : 0
    }

    /// Spectral flatness of the chroma vector (geometric ÷ arithmetic mean,
    /// scale-invariant): 1 = perfectly flat (noise), → 0 = peaked (tonal).
    /// An all-zero chroma reads 1 (flat — nothing tonal there).
    static func flatness(of chroma: [Double]) -> Double {
        let n = Double(chroma.count)
        let mean = chroma.reduce(0, +) / n
        guard mean > 0 else { return 1 }
        // Normalize by the mean so the log sum is scale-free; epsilon guards
        // log(0) for empty pitch classes (drives flatness toward 0, correct).
        var logSum = 0.0
        for value in chroma {
            logSum += log(max(value / mean, 1e-12))
        }
        let flatness = exp(logSum / n)
        return flatness.isFinite ? min(max(flatness, 0), 1) : 1
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
