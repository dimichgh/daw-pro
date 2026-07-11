/// Onset-based take micro-alignment (M6 v-d). Pure math, no I/O, no Foundation
/// — fully deterministic and testable headless. The store feeds it onset lists
/// (timeline seconds) detected in a take group's reference lane and in a
/// candidate lane; it answers "how far is the candidate's phrasing from the
/// reference, and how sure are we?".
///
/// Sign convention (load-bearing): `offsetSeconds` is how far the CANDIDATE's
/// onsets sit AFTER the reference's (positive = the take is late). Moving the
/// candidate by MINUS `offsetSeconds` locks its onsets onto the reference.

/// The aligner's verdict for one reference/candidate onset pair of lanes.
public struct AlignmentResult: Sendable, Equatable {
    /// Candidate-minus-reference offset in seconds (positive = candidate late).
    /// Median-refined — NOT quantized to the 1 ms search grid.
    public var offsetSeconds: Double
    /// Candidate onsets that found a reference partner at the winning offset.
    public var matchedOnsets: Int
    /// Total onsets supplied for the reference lane.
    public var referenceOnsets: Int
    /// Total onsets supplied for the candidate lane.
    public var candidateOnsets: Int
    /// Mean |pair deviation| in seconds AFTER the median refinement — the
    /// residual jitter that alignment cannot remove.
    public var meanAbsDeviationSeconds: Double
    /// `matchedOnsets / max(1, min(referenceOnsets, candidateOnsets))`, 0...1.
    public var confidence: Double

    public init(offsetSeconds: Double, matchedOnsets: Int, referenceOnsets: Int,
                candidateOnsets: Int, meanAbsDeviationSeconds: Double, confidence: Double) {
        self.offsetSeconds = offsetSeconds
        self.matchedOnsets = matchedOnsets
        self.referenceOnsets = referenceOnsets
        self.candidateOnsets = candidateOnsets
        self.meanAbsDeviationSeconds = meanAbsDeviationSeconds
        self.confidence = confidence
    }
}

/// Grid-search onset aligner. Algorithm (settled in the v-d design):
///
/// 1. Try every candidate offset over ±`searchWindowSeconds` at 1 ms steps.
/// 2. At each trial offset, greedily match each shifted candidate onset to the
///    NEAREST reference onset within `matchToleranceSeconds`; every reference
///    onset is consumable once.
/// 3. The offset with the MOST matches wins; ties break on the smallest mean
///    absolute deviation of the matched pairs, then on the smallest |offset|
///    (then the smaller signed offset — fully deterministic).
/// 4. The winner is refined to the MEDIAN of its matched pair deltas
///    (candidate − reference), so the final number is sub-millisecond and free
///    of grid quantization.
/// 5. Fewer than 2 matches at the best offset → nil. Nil means "inconclusive"
///    — the aligner never guesses.
public enum TakeAligner {

    /// Grid step for the offset search (1 ms — the median refinement recovers
    /// sub-millisecond precision afterwards).
    public static let gridStepSeconds = 0.001

    /// Minimum matched pairs for a conclusive verdict.
    public static let minimumMatches = 2

    public static func align(
        referenceOnsets: [Double],
        candidateOnsets: [Double],
        searchWindowSeconds: Double,
        matchToleranceSeconds: Double = 0.025
    ) -> AlignmentResult? {
        guard searchWindowSeconds >= 0, matchToleranceSeconds > 0 else { return nil }
        let reference = referenceOnsets.sorted()
        let candidate = candidateOnsets.sorted()
        guard reference.count >= minimumMatches, candidate.count >= minimumMatches else {
            return nil
        }

        // 1–3. Grid search. `trial` is the hypothesized candidate offset: the
        // candidate shifted EARLIER by `trial` is compared to the reference.
        let steps = Int((searchWindowSeconds / gridStepSeconds).rounded())
        var best: (offset: Double, matches: Int, meanAbsDeviation: Double)?
        for step in -steps...steps {
            let trial = Double(step) * gridStepSeconds
            let pairs = matchPairs(reference: reference, candidate: candidate,
                                   candidateOffset: trial, tolerance: matchToleranceSeconds)
            guard !pairs.isEmpty else { continue }
            let mad = pairs.reduce(0.0) { $0 + abs(($1.candidate - trial) - $1.reference) }
                / Double(pairs.count)
            if isBetter(matches: pairs.count, meanAbsDeviation: mad, offset: trial, than: best) {
                best = (offset: trial, matches: pairs.count, meanAbsDeviation: mad)
            }
        }
        guard let winner = best, winner.matches >= minimumMatches else { return nil }

        // 4. Median refinement over the winner's matched pair deltas.
        let winningPairs = matchPairs(reference: reference, candidate: candidate,
                                      candidateOffset: winner.offset,
                                      tolerance: matchToleranceSeconds)
        let deltas = winningPairs.map { $0.candidate - $0.reference }.sorted()
        let refined = median(ofSorted: deltas)
        let residual = winningPairs.reduce(0.0) {
            $0 + abs(($1.candidate - refined) - $1.reference)
        } / Double(winningPairs.count)

        return AlignmentResult(
            offsetSeconds: refined,
            matchedOnsets: winningPairs.count,
            referenceOnsets: reference.count,
            candidateOnsets: candidate.count,
            meanAbsDeviationSeconds: residual,
            confidence: Double(winningPairs.count)
                / Double(max(1, min(reference.count, candidate.count))))
    }

    // MARK: - Matching

    /// Greedy nearest matching: candidates in ascending order, each grabbing
    /// the nearest still-unconsumed reference onset within `tolerance` of its
    /// shifted position (`candidate − candidateOffset`). A distance tie takes
    /// the EARLIER reference onset — deterministic.
    static func matchPairs(
        reference: [Double], candidate: [Double],
        candidateOffset: Double, tolerance: Double
    ) -> [(reference: Double, candidate: Double)] {
        var consumed = [Bool](repeating: false, count: reference.count)
        var pairs: [(reference: Double, candidate: Double)] = []
        var searchStart = 0
        for c in candidate {
            let shifted = c - candidateOffset
            // Advance the window floor past references below this candidate's
            // window — candidates ascend, so no later candidate can reach
            // them either (consumed or not).
            while searchStart < reference.count, reference[searchStart] < shifted - tolerance {
                searchStart += 1
            }
            var bestIndex = -1
            var bestDistance = Double.infinity
            var r = searchStart
            while r < reference.count, reference[r] <= shifted + tolerance {
                if !consumed[r] {
                    let distance = abs(reference[r] - shifted)
                    if distance <= tolerance, distance < bestDistance {
                        bestDistance = distance
                        bestIndex = r
                    }
                }
                r += 1
            }
            if bestIndex >= 0 {
                consumed[bestIndex] = true
                pairs.append((reference: reference[bestIndex], candidate: c))
            }
        }
        return pairs
    }

    // MARK: - Helpers

    /// True when (matches, mad, offset) beats the incumbent: more matches,
    /// then smaller mean absolute deviation, then smaller |offset|, then the
    /// smaller signed offset.
    private static func isBetter(
        matches: Int, meanAbsDeviation: Double, offset: Double,
        than incumbent: (offset: Double, matches: Int, meanAbsDeviation: Double)?
    ) -> Bool {
        guard let b = incumbent else { return true }
        if matches != b.matches { return matches > b.matches }
        if meanAbsDeviation != b.meanAbsDeviation { return meanAbsDeviation < b.meanAbsDeviation }
        if abs(offset) != abs(b.offset) { return abs(offset) < abs(b.offset) }
        return offset < b.offset
    }

    /// Median of an already-sorted, non-empty array (even count → midpoint
    /// average, the TransientAnalyzer.median convention).
    static func median(ofSorted values: [Double]) -> Double {
        let mid = values.count / 2
        return values.count.isMultiple(of: 2)
            ? (values[mid - 1] + values[mid]) / 2
            : values[mid]
    }
}
