import Accelerate
import DAWCore
import Foundation

/// Onset-envelope tempo estimation with octave discipline (m21-e,
/// design-clip-analyze-audio §3b). Pure static math over the spectral-flux
/// envelope that `TransientAnalyzer.spectralFlux` produces (1024/256 STFT
/// geometry → envelope rate = sampleRate/256).
///
/// Pipeline: detrend (1 s moving mean) + half-wave rectify → normalized
/// autocorrelation over lags 0.25–2.0 s (30–240 BPM) → local-max candidates,
/// each refined by parabolic interpolation and FOLDED into the 70–180 BPM
/// lattice → harmonic-comb scoring picks the winner → prominence-gated
/// confidence, 4-segment steadiness, comb-phase beat offset.
///
/// DEVIATION from design §3b step 4 (listed in the m21-e flight report): the
/// design's 3-member family sum (1.0·direct + 0.5·half + 0.5·double)
/// mis-ranks fast tempi — a subharmonic candidate (87 for a true 174) absorbs
/// the true peak as its "double" member and outscores it, failing the §8
/// 174 BPM fixture. The comb sum Σ(1/k)·ACF(k·period) keeps the same
/// harmonic-evidence idea but weights the fundamental's own multiples, which
/// ranks every §8 fixture correctly (174 pins the discipline in tests).
///
/// REAL-TIME SAFETY: never referenced from the render path — offline analysis
/// only, inside the cache's detached task.
enum TempoEstimator {

    // Constants are v1 tuning (design §3b) — any change bumps
    // `AudioContentAnalyzer.analyzerVersion`.

    /// Autocorrelation lag range: 0.25–2.0 s ⇔ 240–30 BPM.
    static let minLagSeconds = 0.25
    static let maxLagSeconds = 2.0
    /// Reporting lattice: winners fold into [70, 180) BPM.
    static let latticeMinBPM = 70.0
    static let latticeMaxBPM = 180.0
    /// Moving-mean span for envelope detrending.
    static let detrendSeconds = 1.0
    /// `bpm` is nil below this ACF prominence (peak − median).
    static let nullProminence = 0.08
    /// confidence = clamp01(prominence / 0.4).
    static let confidenceScale = 0.4
    /// Windows shorter than this report bpm nil (not enough evidence).
    static let minWindowSeconds = 6.0
    /// Steadiness: max pairwise segment deviation ≤ 4% AND confidence ≥ 0.3.
    static let steadyMaxDeviation = 0.04
    static let steadyMinConfidence = 0.3
    /// Segment span floor: 4 equal segments, fewer below 20 s.
    static let segmentSeconds = 5.0
    /// Comb depth: Σ_{k=1..8} ACF(k·period)/k (out-of-range teeth read 0).
    static let combHarmonics = 8
    /// Folded candidates (and alternates) within this merge as one reading.
    static let bpmMergeTolerance = 0.5

    // MARK: - The one entry point

    /// Estimate over a flux envelope. `windowSeconds` is the analyzed audio
    /// window's duration (the envelope is derived from it).
    static func estimate(fluxEnvelope: [Float], envelopeRate: Double,
                         windowSeconds: Double) -> TempoEstimate {
        let empty = TempoEstimate(bpm: nil, confidence: 0, steady: false,
                                  beatOffsetSeconds: nil, alternates: [])
        guard envelopeRate > 0, windowSeconds >= minWindowSeconds else { return empty }
        let minLagBins = Int((minLagSeconds * envelopeRate).rounded())
        let maxLagBins = Int((maxLagSeconds * envelopeRate).rounded())
        let envelope = detrendedEnvelope(fluxEnvelope, envelopeRate: envelopeRate)
        guard envelope.count > maxLagBins + 1,
              let acf = normalizedACF(envelope, minLagBins: minLagBins,
                                      maxLagBins: maxLagBins),
              let pick = pickWinner(acf: acf, minLagBins: minLagBins,
                                    envelopeRate: envelopeRate)
        else { return empty }

        let prominence = pick.originValue - median(of: acf)
        let confidence = clamp01(prominence / confidenceScale)
        guard prominence >= nullProminence else {
            return TempoEstimate(bpm: nil, confidence: confidence, steady: false,
                                 beatOffsetSeconds: nil, alternates: [])
        }
        let bpm = pick.foldedBPM

        // Alternates: raw unfolded winner first when the fold moved it, then
        // half/double readings, then runner-up folded candidates. ≤ 3,
        // deduplicated within the merge tolerance.
        var alternates: [TempoAlternate] = []
        func add(_ candidate: Double, score: Double) {
            guard alternates.count < 3, candidate >= 30, candidate <= 240,
                  abs(candidate - bpm) > bpmMergeTolerance,
                  !alternates.contains(where: {
                      abs($0.bpm - candidate) <= bpmMergeTolerance
                  })
            else { return }
            alternates.append(TempoAlternate(bpm: candidate, score: score))
        }
        if abs(pick.rawWinnerBPM - bpm) > bpmMergeTolerance {
            add(pick.rawWinnerBPM, score: pick.rawWinnerValue)
        }
        let lagFor = { (bpm: Double) in envelopeRate * 60.0 / bpm }
        add(bpm / 2, score: value(in: acf, atLagBins: lagFor(bpm / 2),
                                  minLagBins: minLagBins))
        add(bpm * 2, score: value(in: acf, atLagBins: lagFor(bpm * 2),
                                  minLagBins: minLagBins))
        for runnerUp in pick.rankedCandidates.dropFirst() {
            add(runnerUp.foldedBPM, score: runnerUp.originValue)
        }

        // Steadiness: per-segment folded estimates must agree within 4%.
        let segmentCount = max(1, min(4, Int(windowSeconds / segmentSeconds)))
        var steady = confidence >= steadyMinConfidence
        if steady, segmentCount >= 2 {
            var segmentBPMs: [Double] = []
            let segmentLength = envelope.count / segmentCount
            for segment in 0..<segmentCount {
                let start = segment * segmentLength
                let slice = Array(envelope[start..<min(start + segmentLength,
                                                       envelope.count)])
                guard let segmentBPM = foldedBPM(
                    ofSegment: slice, minLagBins: minLagBins,
                    maxLagBins: maxLagBins, envelopeRate: envelopeRate)
                else {
                    steady = false
                    break
                }
                segmentBPMs.append(segmentBPM)
            }
            if steady, let low = segmentBPMs.min(), let high = segmentBPMs.max(),
               low > 0 {
                steady = (high - low) / low <= steadyMaxDeviation
            }
        }

        let beatOffset = beatOffsetSeconds(
            envelope: envelope, periodBins: lagFor(bpm), envelopeRate: envelopeRate)
        return TempoEstimate(bpm: bpm, confidence: confidence, steady: steady,
                             beatOffsetSeconds: beatOffset, alternates: alternates)
    }

    // MARK: - Envelope conditioning

    /// Subtract a 1 s centered moving mean and half-wave rectify — removes
    /// the slowly varying flux baseline so the ACF sees pulses, not level.
    /// Non-finite flux values contribute zero (NaN guard).
    static func detrendedEnvelope(_ flux: [Float], envelopeRate: Double) -> [Double] {
        let n = flux.count
        guard n > 0 else { return [] }
        let x = flux.map { $0.isFinite ? Double($0) : 0 }
        let halfWindow = max(1, Int((detrendSeconds * envelopeRate / 2).rounded()))
        var prefix = [Double](repeating: 0, count: n + 1)
        for i in 0..<n { prefix[i + 1] = prefix[i] + x[i] }
        var out = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let lo = max(0, i - halfWindow)
            let hi = min(n - 1, i + halfWindow)
            let mean = (prefix[hi + 1] - prefix[lo]) / Double(hi - lo + 1)
            out[i] = max(0, x[i] - mean)
        }
        return out
    }

    /// Biased autocorrelation normalized by lag 0, evaluated over
    /// [minLagBins, maxLagBins]. nil when the envelope carries no energy
    /// (silence — no tempo evidence by construction).
    static func normalizedACF(_ envelope: [Double], minLagBins: Int,
                              maxLagBins: Int) -> [Double]? {
        let n = envelope.count
        guard minLagBins > 0, maxLagBins > minLagBins, n > maxLagBins else { return nil }
        var lagZero = 0.0
        vDSP_dotprD(envelope, 1, envelope, 1, &lagZero, vDSP_Length(n))
        guard lagZero > 0, lagZero.isFinite else { return nil }
        var acf = [Double](repeating: 0, count: maxLagBins - minLagBins + 1)
        envelope.withUnsafeBufferPointer { buffer in
            for lag in minLagBins...maxLagBins {
                var dot = 0.0
                vDSP_dotprD(buffer.baseAddress!, 1, buffer.baseAddress! + lag, 1,
                            &dot, vDSP_Length(n - lag))
                let normalized = dot / lagZero
                acf[lag - minLagBins] = normalized.isFinite ? normalized : 0
            }
        }
        return acf
    }

    // MARK: - Candidate picking (fold + comb)

    struct Pick {
        /// Winner, folded into [70, 180) and parabolic-refined.
        var foldedBPM: Double
        /// Normalized ACF value at the winner's ORIGINATING peak (the direct
        /// evidence — feeds prominence/confidence).
        var originValue: Double
        /// The highest-ACF candidate before folding (the "raw winner").
        var rawWinnerBPM: Double
        var rawWinnerValue: Double
        /// All folded candidates, comb-ranked (winner first).
        var rankedCandidates: [(foldedBPM: Double, combScore: Double, originValue: Double)]
    }

    /// Local ACF maxima → refined lags → folded lattice candidates →
    /// harmonic-comb ranking. nil when no local maximum exists.
    static func pickWinner(acf: [Double], minLagBins: Int,
                           envelopeRate: Double) -> Pick? {
        // Strict local maxima (ties on the right lose — one candidate per
        // flat top), positive evidence only.
        var peaks: [(lagBins: Int, value: Double)] = []
        for i in 1..<max(1, acf.count - 1)
        where acf[i] > acf[i - 1] && acf[i] >= acf[i + 1] && acf[i] > 0 {
            peaks.append((minLagBins + i, acf[i]))
        }
        guard !peaks.isEmpty else { return nil }

        func refinedLag(_ lagBins: Int) -> Double {
            let i = lagBins - minLagBins
            guard i > 0, i < acf.count - 1 else { return Double(lagBins) }
            let a = acf[i - 1], b = acf[i], c = acf[i + 1]
            let denominator = a - 2 * b + c
            guard denominator != 0 else { return Double(lagBins) }
            let delta = 0.5 * (a - c) / denominator
            guard delta.isFinite, abs(delta) <= 1 else { return Double(lagBins) }
            return Double(lagBins) + delta
        }

        // Refine + fold every peak.
        struct Candidate {
            var foldedBPM: Double
            var rawBPM: Double
            var value: Double
        }
        var candidates: [Candidate] = []
        for peak in peaks {
            let lag = refinedLag(peak.lagBins)
            guard lag > 0 else { continue }
            let rawBPM = 60.0 * envelopeRate / lag
            candidates.append(Candidate(foldedBPM: fold(rawBPM), rawBPM: rawBPM,
                                        value: peak.value))
        }
        guard !candidates.isEmpty else { return nil }
        let rawWinner = candidates.max { $0.value < $1.value }!

        // Merge folded candidates within tolerance; the strongest member is
        // the group's origin (its refined+folded bpm is the group's reading).
        var groups: [Candidate] = []
        for candidate in candidates.sorted(by: { $0.foldedBPM < $1.foldedBPM }) {
            if let last = groups.last,
               abs(candidate.foldedBPM - last.foldedBPM) <= bpmMergeTolerance {
                if candidate.value > last.value {
                    groups[groups.count - 1] = candidate
                }
            } else {
                groups.append(candidate)
            }
        }

        // Harmonic comb: evidence at every multiple of the candidate period,
        // weighted 1/k — subharmonics get fewer, weaker teeth, so the
        // fundamental wins (see the type doc's deviation note).
        var ranked = groups.map { group in
            let periodBins = 60.0 * envelopeRate / group.foldedBPM
            var comb = 0.0
            for k in 1...combHarmonics {
                comb += value(in: acf, atLagBins: periodBins * Double(k),
                              minLagBins: minLagBins) / Double(k)
            }
            return (foldedBPM: group.foldedBPM, combScore: comb,
                    originValue: group.value)
        }
        // Comb desc; near-ties prefer the faster reading (smaller period).
        ranked.sort {
            if abs($0.combScore - $1.combScore) > 1e-12 {
                return $0.combScore > $1.combScore
            }
            return $0.foldedBPM > $1.foldedBPM
        }
        let winner = ranked[0]

        // Harmonic period refinement: one parabolic vertex has ~0.1-bin
        // error — fine against the ±0.5 BPM bar, but a comb phase over a
        // long window drifts by (period error × beat count) and blows the
        // ±25 ms beat-offset bar. The same peak family repeats at k·period,
        // and refining the HIGHEST in-range multiple divides the period
        // error by k (measured: 120 BPM/30 s beat-phase error −30 ms → −14
        // ms, the flux front-end's own constant latency).
        var refinedBPM = winner.foldedBPM
        let basePeriod = 60.0 * envelopeRate / winner.foldedBPM
        var bestHarmonic = 0
        var bestPeriod = basePeriod
        let lastRefinable = minLagBins + acf.count - 2
        for k in 1...combHarmonics {
            let target = basePeriod * Double(k)
            let nearest = Int(target.rounded())
            guard nearest >= minLagBins + 1, nearest <= lastRefinable else { continue }
            var peakBin = -1
            var peakValue = 0.0
            for bin in max(minLagBins + 1, nearest - 2)...min(lastRefinable, nearest + 2) {
                let i = bin - minLagBins
                if acf[i] > acf[i - 1], acf[i] >= acf[i + 1], acf[i] > peakValue {
                    peakBin = bin
                    peakValue = acf[i]
                }
            }
            // The multiple must be REAL evidence (a peak comparable to the
            // origin), and its implied period must agree with the base one.
            guard peakBin >= 0, peakValue >= 0.5 * winner.originValue else { continue }
            let period = refinedLag(peakBin) / Double(k)
            guard abs(period - basePeriod) <= 0.5 else { continue }
            if k > bestHarmonic {
                bestHarmonic = k
                bestPeriod = period
            }
        }
        if bestHarmonic > 0, bestPeriod > 0 {
            refinedBPM = fold(60.0 * envelopeRate / bestPeriod)
        }
        return Pick(foldedBPM: refinedBPM, originValue: winner.originValue,
                    rawWinnerBPM: rawWinner.rawBPM, rawWinnerValue: rawWinner.value,
                    rankedCandidates: ranked)
    }

    /// Fold a bpm into the [70, 180) lattice by doubling/halving.
    static func fold(_ bpm: Double) -> Double {
        guard bpm > 0, bpm.isFinite else { return latticeMinBPM }
        var folded = bpm
        while folded < latticeMinBPM { folded *= 2 }
        while folded >= latticeMaxBPM { folded /= 2 }
        return folded
    }

    /// Linear-interpolated ACF lookup at a fractional lag; 0 outside the
    /// evaluated range (an out-of-range comb tooth is no evidence).
    static func value(in acf: [Double], atLagBins lagBins: Double,
                      minLagBins: Int) -> Double {
        let position = lagBins - Double(minLagBins)
        guard position >= 0, position <= Double(acf.count - 1) else { return 0 }
        let lower = Int(position)
        guard lower < acf.count - 1 else { return acf[acf.count - 1] }
        let fraction = position - Double(lower)
        return acf[lower] * (1 - fraction) + acf[lower + 1] * fraction
    }

    /// One segment's folded estimate for the steadiness vote. nil = the
    /// segment carries no periodic evidence (which reads as NOT steady).
    static func foldedBPM(ofSegment envelope: [Double], minLagBins: Int,
                          maxLagBins: Int, envelopeRate: Double) -> Double? {
        guard envelope.count > maxLagBins + 1,
              let acf = normalizedACF(envelope, minLagBins: minLagBins,
                                      maxLagBins: maxLagBins),
              let pick = pickWinner(acf: acf, minLagBins: minLagBins,
                                    envelopeRate: envelopeRate),
              pick.originValue - median(of: acf) >= nullProminence
        else { return nil }
        return pick.foldedBPM
    }

    // MARK: - Beat phase

    /// Best circular phase of an impulse comb at the winning period against
    /// the onset envelope: seconds from the window start to the first beat,
    /// in [0, period). Parabolic-refined over the phase axis.
    static func beatOffsetSeconds(envelope: [Double], periodBins: Double,
                                  envelopeRate: Double) -> Double? {
        guard periodBins >= 2, envelopeRate > 0,
              envelope.count > Int(periodBins) else { return nil }
        let phaseCount = max(1, Int(periodBins.rounded(.down)))
        var scores = [Double](repeating: 0, count: phaseCount)
        for phase in 0..<phaseCount {
            var position = Double(phase)
            var index = Int(position.rounded())
            var sum = 0.0
            while index < envelope.count {
                sum += envelope[index]
                position += periodBins
                index = Int(position.rounded())
            }
            scores[phase] = sum
        }
        guard let maxScore = scores.max(), maxScore > 0,
              let best = scores.firstIndex(of: maxScore) else { return nil }
        let previous = scores[(best + phaseCount - 1) % phaseCount]
        let next = scores[(best + 1) % phaseCount]
        let denominator = previous - 2 * maxScore + next
        var delta = 0.0
        if denominator != 0 {
            delta = 0.5 * (previous - next) / denominator
            if !delta.isFinite || abs(delta) > 1 { delta = 0 }
        }
        let period = periodBins / envelopeRate
        var offset = ((Double(best) + delta) / envelopeRate)
            .truncatingRemainder(dividingBy: period)
        if offset < 0 { offset += period }
        return offset
    }

    // MARK: - Helpers

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[mid - 1] + sorted[mid]) / 2
            : sorted[mid]
    }

    private static func clamp01(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
