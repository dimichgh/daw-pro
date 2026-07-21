import Foundation

/// The ONE home of the mean-power-DENSITY band fold (m22-g, extracted
/// VERBATIM from `AudioContentAnalyzer.spectralBalance` — the m22-b
/// `EQFilterResponse` one-home extraction rule; never fork the math).
///
/// Input: a half-spectrum of per-bin MEAN POWER (amplitude-normalized so a
/// bin-centered full-scale tone reads ≈ 1.0 at its bin — the shared
/// `1/Σhann` scale both STFT front-ends use) from an `fftSize`-point FFT at
/// `sampleRate`. Output: mean power DENSITY over the bins whose center lies
/// in [low, high) — a per-bin average, so wide bands don't read hot for
/// owning more bins — in dB with the house −80 floor.
///
/// Consumers: `AudioContentAnalyzer` (16384-pt windowed clip analysis,
/// m21-e) and `ReferenceAnalyzer` (2048-pt whole-file reference analysis,
/// m22-g), both folding into `MasterMixAnalyzer.bandEdges`. NOTE the fold is
/// geometry-parameterized: the same MATH at different `fftSize` yields
/// slightly different DENSITY readings for tonal material (a tone's fixed
/// total power averages over more bins at a larger FFT) — identical for
/// broadband material, which is what the cross-analyzer sanity pin uses.
enum SpectrumBandFold {

    /// Mean power density over bins whose center lies in [low, high),
    /// clamped to [bin 1, Nyquist) — dB with the `floorDb` floor. Degenerate
    /// geometry (empty spectrum, bad rate/size, inverted range) reads the
    /// floor.
    ///
    /// `emptyBandReadsNearestBin` picks between the two homes' HISTORICAL
    /// empty-band conventions (a band narrower than one bin — only the
    /// lowest few at 2048-pt geometry): `false` = the floor (the
    /// `AudioContentAnalyzer` convention, whose 16384-pt geometry never
    /// produces an empty band in practice — its output stays bit-identical
    /// to the pre-extraction inline fold); `true` = the bin nearest the
    /// band's geometric center (the `MasterMixAnalyzer` live convention —
    /// `ReferenceAnalyzer` uses it so the reference's 2048-pt curve is
    /// point-for-point comparable with the live mix spectrum it overlays).
    static func bandDb(
        meanPower: [Double], sampleRate: Double, fftSize: Int,
        low: Double, high: Double, floorDb: Double,
        emptyBandReadsNearestBin: Bool = false
    ) -> Double {
        let half = meanPower.count
        guard half > 1, sampleRate > 0, fftSize > 0 else { return floorDb }
        let binHz = sampleRate / Double(fftSize)
        let nyquist = sampleRate / 2
        let clampedLow = max(low, binHz)
        let clampedHigh = min(high, nyquist)
        guard clampedHigh > clampedLow else { return floorDb }
        let firstBin = max(1, Int((clampedLow / binHz).rounded(.up)))
        let lastBin = min(half - 1, Int((clampedHigh / binHz).rounded(.up)) - 1)
        guard firstBin <= lastBin else {
            guard emptyBandReadsNearestBin else { return floorDb }
            // The MasterMixAnalyzer nearest-bin rule, verbatim: the bin
            // nearest the band's GEOMETRIC center, clamped inside 1..<half.
            let center = (clampedLow * clampedHigh).squareRoot()
            let nearest = min(half - 1, max(1, Int((center / binHz).rounded())))
            return powerDb(meanPower[nearest], floorDb: floorDb)
        }
        var sum = 0.0
        for bin in firstBin...lastBin { sum += meanPower[bin] }
        return powerDb(sum / Double(lastBin - firstBin + 1), floorDb: floorDb)
    }

    /// The 24 `MasterMixAnalyzer.bandEdges` bands through `bandDb`.
    static func bandsDb(
        meanPower: [Double], sampleRate: Double, fftSize: Int, floorDb: Double,
        emptyBandReadsNearestBin: Bool = false
    ) -> [Double] {
        let edges = MasterMixAnalyzer.bandEdges
        return (0..<MasterMixAnalyzer.bandCount).map { band in
            bandDb(meanPower: meanPower, sampleRate: sampleRate, fftSize: fftSize,
                   low: edges[band], high: edges[band + 1], floorDb: floorDb,
                   emptyBandReadsNearestBin: emptyBandReadsNearestBin)
        }
    }

    /// Power → dB, `floorDb`-floored; zero/non-finite reads EXACTLY the
    /// floor (the `AudioContentAnalyzer.powerDb` convention, moved here with
    /// the fold).
    static func powerDb(_ power: Double, floorDb: Double) -> Double {
        guard power > 0, power.isFinite else { return floorDb }
        return max(10 * log10(power), floorDb)
    }
}
