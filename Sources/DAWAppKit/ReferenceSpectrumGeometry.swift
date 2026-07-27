import Foundation
import DAWCore

/// Pure geometry for the REFERENCE panel's **spectrum overlay** (m22-g P3,
/// design-m22g-reference-tracks §7.2 point 6): the reference's stored 24-band
/// whole-file average and the live mix's 24 bands drawn on ONE shared
/// log-frequency axis so the two curves are point-comparable by construction.
///
/// The axis is the analyzer's OWN band span — 40 Hz…16 kHz
/// (`MasterMixAnalyzer.bandEdges`, restated here because DAWAppKit must not
/// import DAWEngine; the `EQCurveEditorModel.spectrumBandEdgeHz` precedent) —
/// NOT the EQ editor's 20 Hz…20 kHz plot axis: this surface has no filter
/// curve to co-plot, so stretching the bands into a wider axis would leave
/// dead glass at both ends and buy nothing. Both curves therefore start at
/// band 0's true low edge and end at band 23's true high edge.
///
/// The y axis is the house band-magnitude window (`VibeMeterModel.bandFloorDB`
/// −72 … `bandCeilingDB` −6) so this spectrum reads with the same tilt as the
/// vibe meter and the EQ card's spectrum fill. The m22-g P1 analyzer folds the
/// reference at the LIVE 2048-point geometry, so the reference average and the
/// live mix bands are the same quantity in the same units — the only reason
/// plotting them on one scale is honest.
///
/// Pure `Double` math, no state, no isolation: the Canvas `@Sendable`
/// renderers compute value captures from this before their closures run (the
/// m16-a contract). Screen convention: x grows rightward, y grows DOWNWARD
/// (−6 dB at y = 0, −72 dB at y = height).
public enum ReferenceSpectrumGeometry {

    // MARK: - The shared band axis

    /// Band count — exactly the analysis snapshot's (24). A curve with any
    /// other count is refused by `polylinePoints` (honest absence, never a
    /// stretched-to-fit lie).
    public static let bandCount = MasterAnalysisSnapshot.bandCount
    /// Band 0's low edge / band 23's high edge — the analyzer's geometric
    /// subdivision of [40, 16000] Hz.
    public static let lowestBandHz = 40.0
    public static let highestBandHz = 16_000.0

    /// The display dB window, shared with the vibe meter and the EQ card's
    /// spectrum fill so one spectral tilt reads the same everywhere.
    public static let dbRange: ClosedRange<Double> =
        Double(VibeMeterModel.bandFloorDB)...Double(VibeMeterModel.bandCeilingDB)

    /// Edge `index` of the 25 geometric band edges (0…24), Hz.
    public static func bandEdgeHz(_ index: Int) -> Double {
        let k = min(max(index, 0), bandCount)
        return lowestBandHz * pow(highestBandHz / lowestBandHz,
                                  Double(k) / Double(bandCount))
    }

    /// Band `index`'s geometric center — √(lo·hi), the point its value is
    /// plotted at.
    public static func bandCenterHz(_ index: Int) -> Double {
        (bandEdgeHz(index) * bandEdgeHz(index + 1)).squareRoot()
    }

    /// x for a frequency on the log axis: `width · log(f/40) / log(16000/40)`.
    /// Clamped to the axis, so an out-of-range probe can never run off-plot.
    public static func x(forFrequency frequency: Double, in width: Double) -> Double {
        let f = frequency.clamped(to: lowestBandHz...highestBandHz)
        return width * log(f / lowestBandHz) / log(highestBandHz / lowestBandHz)
    }

    /// y for a band dB value: −6 dB at the top, −72 dB at the bottom.
    public static func y(forDb db: Double, in height: Double) -> Double {
        let d = db.clamped(to: dbRange)
        return height * (dbRange.upperBound - d)
            / (dbRange.upperBound - dbRange.lowerBound)
    }

    // MARK: - Curves

    /// The polyline for one 24-band curve: the FIRST point sits at band 0's
    /// true LOW edge and the LAST at band 23's true HIGH edge (carrying the
    /// end bands' values, so the fill closes on the plot edges without
    /// inventing data), with one point per band at its geometric-center x.
    ///
    /// A curve whose count isn't `bandCount` returns EMPTY — the view then
    /// draws nothing at all rather than a resampled fiction (the "honest
    /// absence" rule; a wrong-count `bandsDb` is exactly what the P1 tolerant
    /// decode sanitizes away).
    public static func polylinePoints(bandsDb: [Double],
                                      width: Double, height: Double) -> [CGPoint] {
        guard bandsDb.count == bandCount, width > 0, height > 0 else { return [] }
        var points: [CGPoint] = []
        points.reserveCapacity(bandCount + 2)
        points.append(CGPoint(x: x(forFrequency: bandEdgeHz(0), in: width),
                              y: y(forDb: bandsDb[0], in: height)))
        for index in 0..<bandCount {
            points.append(CGPoint(x: x(forFrequency: bandCenterHz(index), in: width),
                                  y: y(forDb: bandsDb[index], in: height)))
        }
        points.append(CGPoint(x: x(forFrequency: bandEdgeHz(bandCount), in: width),
                              y: y(forDb: bandsDb[bandCount - 1], in: height)))
        return points
    }

    // MARK: - Grid (static chrome — never glowed)

    /// The decade-ish frequency marks drawn as hairlines with SF Mono labels,
    /// beginner-readable ("100", "1k", "10k" — never scientific notation, the
    /// EQ card's label rule). Only marks INSIDE the axis are returned.
    public static let frequencyGridHz: [Double] = [50, 100, 200, 500, 1_000, 2_000, 5_000, 10_000]

    /// "50" / "1k" / "10k" — the EQ grid's exact voice.
    public static func frequencyLabel(_ hz: Double) -> String {
        hz >= 1_000
            ? "\(Int((hz / 1_000).rounded()))k"
            : "\(Int(hz.rounded()))"
    }
}

// MARK: - Mix-side smoothing (the "recent average" the label promises)

/// An exponential moving average over the live mix's 24 bands, in dB
/// (design §7.2: the mix curve is labeled "MIX (recent average)", so it must
/// actually BE an average — never a ballistic snapshot passed off as one).
///
/// τ ≈ 2.5 s: long enough that a bar of music averages into one shape, short
/// enough that switching to a new section is visible within a few seconds.
/// The step is the standard one-pole `α = 1 − exp(−dt/τ)`, applied
/// SYMMETRICALLY (an average has no attack/release asymmetry — that is a
/// meter's ballistics, and this deliberately is not a meter).
///
/// Reference-type scratch, held `@ObservationIgnored` by the panel model so
/// advancing it inside a `TimelineView` body schedules no invalidation (the
/// `EQCurveEditorModel.spectrumHeights` precedent), and it never allocates
/// per frame — the band array is preallocated and mutated in place.
public final class ReferenceSpectrumAverage {
    /// The averaging time constant, seconds.
    public static let tau = 2.5
    /// A dt longer than this is treated as a gap (a backgrounded window, a
    /// stalled frame) and clamped, so the average can never be snapped by one
    /// long frame.
    public static let maxStepSeconds = 0.5

    /// The smoothed band values in dB, `ReferenceSpectrumGeometry.bandCount`
    /// long. `nil` until the first frame lands — an un-fed average has no
    /// value to draw and says so (the warming-up dash rule, one surface over).
    public private(set) var bandsDb: [Double]?

    public init() {}

    /// Advances the average one frame toward `targets`. A wrong-count or
    /// empty target array is IGNORED (state untouched — a missing poll must
    /// not decay the curve toward a floor it never measured); a non-positive
    /// `deltaTime` is a no-op. The first valid frame SEEDS the average
    /// exactly (no ramp up from a fabricated floor).
    public func advance(toward targets: [Double], deltaTime: Double) {
        guard targets.count == ReferenceSpectrumGeometry.bandCount else { return }
        guard var current = bandsDb else {
            bandsDb = targets
            return
        }
        guard deltaTime > 0 else { return }
        let dt = min(deltaTime, Self.maxStepSeconds)
        let alpha = 1 - exp(-dt / Self.tau)
        for i in current.indices {
            current[i] += (targets[i] - current[i]) * alpha
        }
        bandsDb = current
    }

    /// Drops the accumulated average (panel close / a new reference / a seed
    /// change) so the next frame re-seeds exactly.
    public func reset() {
        bandsDb = nil
    }
}
