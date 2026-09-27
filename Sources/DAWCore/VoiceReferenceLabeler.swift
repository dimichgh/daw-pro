import Foundation

// p2-sing-d3 — own-voice reference labels by ROUTE N (design docs/design/2026-09-27-p2-sing-integration.md §3.7).
//
// Why not Route H (the spike's `route_h`): it assumed the singer kept the guide's rhythm with ONE global time offset and
// its intervals with ONE global key. The user sang freely (intervals wider than written, residuals −221…+449 c), so only
// 1 of 10 labels landed within ±50 c of what was sung [M]. Route N instead:
//   1. finds the voiced region and the prompt window [first voiced − 0.24 s, last voiced + 0.24 s];
//   2. builds the sung contour in semitones, folding isolated ±12 tracker octave errors against a 150 ms median;
//   3. subtracts each contour's own median (key-invariance), the guide's and the sung;
//   4. aligns the guide's frames (P1: 10 notes, 4.8 s) to the sung frames by DTW — local cost min(|guide − sung|, 3 st),
//      0.3 for an unvoiced sung frame, guide note onsets pulled toward sung onset peaks, a symmetric step pattern with
//      the local slope limited to 1/3…3;
//   5. takes note spans from the path, snapping boundaries between repeated same-pitch notes to the strongest onset
//      peak within ±80 ms;
//   6. labels each note with what was SUNG: round(median of the sung contour over the middle 50% of its span); a span
//      with under 60 ms of confident pitch falls back to the key-relative guide pitch and is flagged;
//   7. makes gaps of 0.20 s or more `<SP>`; shorter gaps are absorbed into the following note; each gap belongs only
//      to its NEAREST boundary (`placeGaps`);
//   8. takes the words from P1.
//
// ⚠️ VACUITY (design §3.7): "8+ of 10 labels within ±50 c" is TRUE BY CONSTRUCTION here — the labels ARE the rounded sung
// pitch. It must never be Route N's gate. Route N is graded on boundary accuracy against known truth.
//
// Pure DAWCore: the engine supplies the SwiftF0 frames; `onsetStrength(samples:…)` turns the decoded samples into the
// onset evidence on the same frame grid.

/// Route N's labels for one own-voice reference recording.
public struct VoiceReferenceLabels: Codable, Sendable, Equatable {
    public enum Verdict: String, Codable, Sendable { case good, fair, poor }

    /// One labelled P1 note.
    public struct Note: Codable, Sendable, Equatable {
        /// P1 note index, 0…9.
        public var index: Int
        public var syllable: String
        /// File-absolute seconds.
        public var startSeconds: Double
        public var endSeconds: Double
        /// What was sung, rounded to a semitone (or the key-relative guide pitch when `fallback`).
        public var midi: Int
        /// True when the span had under 60 ms of confident pitch.
        public var fallback: Bool
        public var confidentSeconds: Double
        /// Interquartile range of the span's confident pitch, cents; nil with no confident frame.
        public var pitchIqrCents: Double?
    }

    /// A `<SP>` between two notes (a gap of 0.20 s or more).
    public struct Rest: Codable, Sendable, Equatable {
        public var startSeconds: Double
        public var endSeconds: Double
    }

    /// The four advisory measures (§3.7 "Quality").
    public struct Quality: Codable, Sendable, Equatable {
        /// Mean pitch local cost along the DTW path, semitones (symmetric-normalised; without the onset pull).
        public var dtwMeanLocalCost: Double
        /// Spans whose confident pitch has an IQR of 100 c or less (a wider span straddles two sung pitches).
        public var spansWithSteadyPitch: Int
        /// Share of ALL the recording's confident frames that fall inside note spans.
        public var voicedFramesInsideSpans: Double
        public var shortestSpanSeconds: Double
        /// False when the sung line is outside 1/3…3× the guide's length (the slope limit), so no DTW path exists.
        public var dtwFeasible: Bool
    }

    public var method: String
    /// The prompt window, file-absolute seconds: [first voiced − 0.24, last voiced + 0.24], clamped to the file.
    public var windowStartSeconds: Double
    public var windowEndSeconds: Double
    public var notes: [Note]
    public var rests: [Rest]
    /// P1's words, and which notes each is sung on.
    public var words: [String]
    public var sungMedianMidi: Double?
    public var octaveFoldedFrames: Int
    /// The harmonic-comb check of the register, when the caller ran it (`VoiceRangeFit.octaveCheck`).
    public var registerConfirmed: Bool?
    public var quality: Quality
    public var verdict: Verdict
    /// §5.7 "Poor alignment", when the verdict is poor.
    public var message: String?
}

public enum VoiceReferenceLabeler {
    // MARK: - Constants (design §3.7 where it gives them; [A] and pre-registered otherwise)

    public static let windowMarginSeconds = 0.24
    public static let octaveFoldWindowSeconds = 0.150
    /// A frame this close to ±12 st from its 150 ms median is an octave error ([A]).
    public static let octaveFoldToleranceSemitones = 1.5
    public static let localCostCapSemitones = 3.0
    public static let unvoicedFrameCost = 0.3
    /// At a guide note-onset frame the cost rises by this × (1 − the sung frame's onset strength) ([A]).
    public static let onsetPullWeight = 1.0
    /// A small cost on every non-diagonal step, so evidence-free stretches stay near-diagonal ([A]).
    public static let offDiagonalStepPenalty = 0.01
    public static let repeatedNoteSnapSeconds = 0.080
    public static let minConfidentSecondsPerSpan = 0.060
    /// `MIN_GAP_S`: gaps this long become `<SP>`.
    public static let restMinSeconds = 0.20
    public static let steadySpanIqrCents = 100.0
    /// The voiced region starts and ends on a run of at least this many confident frames ([A]).
    public static let minVoicedRunFrames = 3

    // Verdict mapping ([A], pre-registered before the first run — see the p2-sing-d3 report).
    // p2-sing-d3-mis (round 3, pre-registered): the DTW shape distance (`dtwMeanLocalCost`) is the different-melody
    // measure. Its poor threshold was 2.0 [A], never calibrated: fixture 8 (a different melody) graded poor only through
    // the one-frame notes that `placeGaps` removed. 1.30 sits between the worst right-melody fixture (the user's shape,
    // 1.059) and a different melody (1.582 on frames, 1.630 through SwiftF0). The good ceiling (was 1.5) merges with it,
    // so no cost band is dead code.
    public static let goodMaxMeanCost = 1.30
    public static let poorAboveMeanCost = 1.30
    public static let goodMinSteadySpans = 9
    public static let poorBelowSteadySpans = 7
    public static let minVoicedInsideSpans = 0.90
    public static let minSpanSeconds = 0.060

    /// §5.7 "Poor alignment".
    public static let poorAlignmentMessage = "I couldn't follow your recording closely (did you sing the same words?). "
        + "Your voice will still work, but it may sound less like you."

    // MARK: - Labelling

    /// Route N over one recording's SwiftF0 frames.
    /// - Parameters:
    ///   - frames: `detectPitch(inFileAt:)` over the whole file, on one uniform grid.
    ///   - onsetStrength: per frame, 0…1 (`onsetStrength(samples:…)`); nil = no onset evidence (no pull, no snap).
    ///   - durationSeconds: the file's length, for the window clamp.
    ///   - registerCheck: the comb check, when run.
    public static func label(frames: [ClipPitchFrame], onsetStrength: [Double]?, durationSeconds: Double,
                             registerCheck: VoiceOctaveCheck? = nil,
                             confidenceThreshold: Double = PitchDetectionDefaults.defaultConfidenceThreshold)
        -> VoiceReferenceLabels {
        let n = frames.count
        let words = SingGuideLine.words.map(\.text)
        let noGrid = VoiceReferenceLabels.Quality(dtwMeanLocalCost: localCostCapSemitones, spansWithSteadyPitch: 0,
                                                  voicedFramesInsideSpans: 0, shortestSpanSeconds: 0, dtwFeasible: false)
        func empty() -> VoiceReferenceLabels {
            VoiceReferenceLabels(method: "routeN", windowStartSeconds: 0, windowEndSeconds: durationSeconds, notes: [],
                                 rests: [], words: words, sungMedianMidi: nil, octaveFoldedFrames: 0,
                                 registerConfirmed: registerCheck?.registerConfirmed, quality: noGrid, verdict: .poor,
                                 message: poorAlignmentMessage)
        }
        guard n > 1 else { return empty() }
        let hop = medianGap(frames)
        guard hop > 0 else { return empty() }

        // 1. Confident frames and the voiced region.
        let raw: [Double?] = frames.map { f in
            guard let hz = f.frequencyHz, f.confidence >= confidenceThreshold else { return nil }
            return VoiceRangeFit.midi(fromHz: hz)
        }
        guard let region = voicedRegion(raw) else { return empty() }
        let (first, last) = region
        let windowStart = max(0, frames[first].timeSeconds - windowMarginSeconds)
        let windowEnd = min(durationSeconds, frames[last].timeSeconds + hop + windowMarginSeconds)

        // 2. Octave fold against a 150 ms running median.
        let (folded, foldCount) = foldOctaveErrors(raw, halfWidth: Int((octaveFoldWindowSeconds / 2 / hop).rounded()))

        // 3. Key-invariance: each contour minus its own median.
        let m = last - first + 1
        let sungCore = Array(folded[first...last])
        let sungMedian = median(sungCore.compactMap { $0 }) ?? 0
        let sung: [Double?] = sungCore.map { $0.map { $0 - sungMedian } }
        let guideLine = guideFrames(hop: hop)
        let guideMedian = median(guideLine.midi) ?? 0
        let guide = guideLine.midi.map { $0 - guideMedian }
        let onsets: [Double]? = onsetStrength.map { strengths in
            (0..<m).map { j in first + j < strengths.count ? min(1, max(0, strengths[first + j])) : 0 }
        }

        // 4. DTW.
        let noteCount = SingGuideLine.notes.count
        var starts = [Int](repeating: 0, count: noteCount)
        var meanCost = localCostCapSemitones
        let feasible = m <= 3 * guide.count && guide.count <= 3 * m
        if feasible, let path = dtw(guide: guide, sung: sung, guideOnset: guideLine.isOnset, onsets: onsets) {
            meanCost = path.meanPitchCost
            for k in 1..<noteCount {
                let onsetFrame = guideLine.onsetFrame[k]
                starts[k] = path.cells.first { $0.i == onsetFrame }?.j ?? 0
            }
        } else {
            // No path under the slope limit: spread P1 proportionally (the verdict is poor regardless).
            for k in 1..<noteCount {
                starts[k] = Int((Double(guideLine.onsetFrame[k]) / Double(guide.count) * Double(m)).rounded())
            }
        }

        // 5. Repeated same-pitch notes: snap to the strongest onset peak within ±80 ms.
        let reach = Int((repeatedNoteSnapSeconds / hop).rounded())
        if let onsets {
            for k in 1..<noteCount
            where SingGuideLine.notes[k].semitonesAboveStart == SingGuideLine.notes[k - 1].semitonesAboveStart {
                let lo = max(starts[k - 1] + 1, starts[k] - reach)
                let hi = min(k + 1 < noteCount ? starts[k + 1] - 1 : m - 1, starts[k] + reach)
                guard lo <= hi else { continue }
                var best = starts[k]
                var bestStrength = -1.0
                for j in lo...hi {
                    let strength = onsets[j]
                    if strength > bestStrength || (strength == bestStrength && abs(j - starts[k]) < abs(best - starts[k])) {
                        best = j
                        bestStrength = strength
                    }
                }
                if bestStrength > 0 { starts[k] = best }
            }
        }

        // 7. Gaps near each boundary: >= 0.20 s becomes <SP>; shorter is absorbed into the following note. Each gap
        // belongs only to its nearest boundary; then every span is kept non-empty and in order.
        let placed = placeGaps(starts: starts, sung: sung, reach: reach, hop: hop)
        starts = placed.starts
        let ends = placed.ends
        let restSpans = placed.rests

        // 6. Labels = what was sung.
        func seconds(_ j: Int) -> Double {
            let index = first + j
            return index < n ? frames[index].timeSeconds : frames[n - 1].timeSeconds + hop * Double(index - n + 1)
        }
        var notes: [VoiceReferenceLabels.Note] = []
        var steady = 0
        var inside = 0
        for k in 0..<noteCount {
            let a = starts[k]
            let b = max(ends[k], a + 1)
            let span = (a..<b).compactMap { sung[$0].map { $0 + sungMedian } }
            let confident = Double(span.count) * hop
            let lo = Double(a) + 0.25 * Double(b - a)
            let hi = Double(a) + 0.75 * Double(b - a)
            let middle = (a..<b).filter { Double($0) >= lo && Double($0) < hi }.compactMap { sung[$0].map { $0 + sungMedian } }
            let keyRelativeGuide = Int((guideLine.noteMidi[k] - guideMedian + sungMedian).rounded())
            let fallback = confident < minConfidentSecondsPerSpan
            let sungLabel = Int(((median(middle.isEmpty ? span : middle)) ?? Double(keyRelativeGuide)).rounded())
            let label = fallback ? keyRelativeGuide : sungLabel
            var iqr: Double?
            if !span.isEmpty {
                let sorted = span.sorted()
                iqr = (VoiceClipCheck.percentileLinear(sorted, 0.75) - VoiceClipCheck.percentileLinear(sorted, 0.25)) * 100
            }
            if let iqr, iqr <= steadySpanIqrCents { steady += 1 }
            inside += span.count
            notes.append(.init(index: k, syllable: SingGuideLine.notes[k].syllable, startSeconds: seconds(a),
                               endSeconds: seconds(b), midi: label, fallback: fallback, confidentSeconds: confident,
                               pitchIqrCents: iqr))
        }

        // Quality and verdict.
        let allConfident = raw.compactMap { $0 }.count
        let insideShare = allConfident > 0 ? Double(inside) / Double(allConfident) : 0
        let shortest = (0..<noteCount).map { Double(max(ends[$0], starts[$0] + 1) - starts[$0]) * hop }.min() ?? 0
        let quality = VoiceReferenceLabels.Quality(dtwMeanLocalCost: meanCost, spansWithSteadyPitch: steady,
                                                   voicedFramesInsideSpans: insideShare,
                                                   shortestSpanSeconds: shortest, dtwFeasible: feasible)
        let verdict = self.verdict(quality)
        return VoiceReferenceLabels(
            method: "routeN", windowStartSeconds: windowStart, windowEndSeconds: windowEnd, notes: notes,
            rests: restSpans.map { .init(startSeconds: seconds($0.lowerBound), endSeconds: seconds($0.upperBound)) },
            words: words,
            sungMedianMidi: sungMedian, octaveFoldedFrames: foldCount,
            registerConfirmed: registerCheck?.registerConfirmed, quality: quality, verdict: verdict,
            message: verdict == .poor ? poorAlignmentMessage : nil)
    }

    /// The pre-registered mapping from the four measures to good / fair / poor.
    public static func verdict(_ q: VoiceReferenceLabels.Quality) -> VoiceReferenceLabels.Verdict {
        let steadyOK = q.spansWithSteadyPitch >= goodMinSteadySpans
        let insideOK = q.voicedFramesInsideSpans >= minVoicedInsideSpans
        let lengthOK = q.shortestSpanSeconds >= minSpanSeconds
        let misses = [steadyOK, insideOK, lengthOK].filter { !$0 }.count
        if !q.dtwFeasible || q.dtwMeanLocalCost > poorAboveMeanCost || q.spansWithSteadyPitch < poorBelowSteadySpans
            || misses >= 2 {
            return .poor
        }
        if q.dtwMeanLocalCost <= goodMaxMeanCost && misses == 0 { return .good }
        return .fair
    }

    // MARK: - Pieces (internal for tests)

    static func medianGap(_ frames: [ClipPitchFrame]) -> Double {
        var gaps: [Double] = []
        for i in 1..<frames.count { gaps.append(frames[i].timeSeconds - frames[i - 1].timeSeconds) }
        return median(gaps) ?? 0
    }

    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return VoiceClipCheck.percentileLinear(values.sorted(), 0.5)
    }

    /// First and last confident frame that belong to a run of at least `minVoicedRunFrames`.
    static func voicedRegion(_ midi: [Double?]) -> (Int, Int)? {
        var first: Int?
        var last: Int?
        var i = 0
        while i < midi.count {
            guard midi[i] != nil else { i += 1; continue }
            var j = i
            while j < midi.count, midi[j] != nil { j += 1 }
            if j - i >= minVoicedRunFrames {
                if first == nil { first = i }
                last = j - 1
            }
            i = j
        }
        guard let first, let last else { return nil }
        return (first, last)
    }

    /// Folds frames sitting 12 ± 1.5 st from the median of their ±`halfWidth` neighbourhood back by an octave.
    static func foldOctaveErrors(_ midi: [Double?], halfWidth: Int) -> ([Double?], Int) {
        var out = midi
        var count = 0
        for j in midi.indices {
            guard let value = midi[j] else { continue }
            let neighbours = (max(0, j - halfWidth)...min(midi.count - 1, j + halfWidth)).compactMap { midi[$0] }
            guard let local = median(neighbours) else { continue }
            let d = value - local
            if abs(abs(d) - 12) <= octaveFoldToleranceSemitones {
                out[j] = value - 12 * (d > 0 ? 1 : -1)
                count += 1
            }
        }
        return (out, count)
    }

    /// P1 (from C4) on the frame grid: each frame's written MIDI (by its centre), onset flags and onset frames.
    static func guideFrames(hop: Double) -> (midi: [Double], noteMidi: [Double], isOnset: [Bool], onsetFrame: [Int]) {
        let notes = SingGuideLine.timedNotes(startMidi: 60)
        let count = Int((SingGuideLine.spanSeconds / hop).rounded())
        var midi = [Double](repeating: 0, count: count)
        var noteOf = [Int](repeating: 0, count: count)
        var k = 0
        for i in 0..<count {
            let centre = (Double(i) + 0.5) * hop
            while k + 1 < notes.count, centre >= notes[k + 1].startSeconds { k += 1 }
            midi[i] = Double(notes[k].midi)
            noteOf[i] = k
        }
        var onsetFrame = [Int](repeating: 0, count: notes.count)
        var isOnset = [Bool](repeating: false, count: count)
        for note in 1..<notes.count {
            let frame = noteOf.firstIndex(of: note) ?? 0
            onsetFrame[note] = frame
            isOnset[frame] = true
        }
        return (midi, notes.map { Double($0.midi) }, isOnset, onsetFrame)
    }

    struct Cell: Equatable {
        let i: Int
        let j: Int
    }

    /// Symmetric DTW with moves (1,1), (1,2), (2,1), (1,3), (3,1) — local slope within 1/3…3. A move's cost is
    /// (di + dj) × the mean local cost of the cells it visits, so a path's total weight is N + M. The pitch part of the
    /// cost is tracked separately for the quality measure (no onset pull, no step penalty).
    static func dtw(guide: [Double], sung: [Double?], guideOnset: [Bool], onsets: [Double]?)
        -> (cells: [Cell], meanPitchCost: Double)? {
        let rows = guide.count
        let cols = sung.count
        guard rows > 0, cols > 0 else { return nil }
        var pitch = [Double](repeating: 0, count: rows * cols)
        var cost = [Double](repeating: 0, count: rows * cols)
        for i in 0..<rows {
            for j in 0..<cols {
                let p = sung[j].map { min(abs(guide[i] - $0), localCostCapSemitones) } ?? unvoicedFrameCost
                pitch[i * cols + j] = p
                var c = p
                if guideOnset[i], let onsets { c += onsetPullWeight * (1 - onsets[j]) }
                cost[i * cols + j] = c
            }
        }
        // (di, dj) and the visited cells relative to (i, j).
        let moves: [(di: Int, dj: Int, visits: [(Int, Int)])] = [
            (1, 1, [(0, 0)]),
            (1, 2, [(0, -1), (0, 0)]),
            (2, 1, [(-1, 0), (0, 0)]),
            (1, 3, [(0, -2), (0, -1), (0, 0)]),
            (3, 1, [(-2, 0), (-1, 0), (0, 0)]),
        ]
        var total = [Double](repeating: .infinity, count: rows * cols)
        var pitchTotal = [Double](repeating: 0, count: rows * cols)
        var from = [Int8](repeating: -1, count: rows * cols)
        total[0] = 2 * cost[0]
        pitchTotal[0] = 2 * pitch[0]
        for i in 0..<rows {
            for j in 0..<cols where i > 0 || j > 0 {
                var best = Double.infinity
                var bestPitch = 0.0
                var bestMove: Int8 = -1
                for (index, move) in moves.enumerated() {
                    let pi = i - move.di
                    let pj = j - move.dj
                    guard pi >= 0, pj >= 0 else { continue }
                    let previous = total[pi * cols + pj]
                    guard previous.isFinite else { continue }
                    let weight = Double(move.di + move.dj) / Double(move.visits.count)
                    var add = 0.0
                    var addPitch = 0.0
                    for (vi, vj) in move.visits {
                        add += cost[(i + vi) * cols + (j + vj)]
                        addPitch += pitch[(i + vi) * cols + (j + vj)]
                    }
                    let candidate = previous + weight * add + (index == 0 ? 0 : offDiagonalStepPenalty)
                    if candidate < best {
                        best = candidate
                        bestPitch = pitchTotal[pi * cols + pj] + weight * addPitch
                        bestMove = Int8(index)
                    }
                }
                total[i * cols + j] = best
                pitchTotal[i * cols + j] = bestPitch
                from[i * cols + j] = bestMove
            }
        }
        guard total[rows * cols - 1].isFinite else { return nil }
        // Backtrack, expanding each move into the cells it visits.
        var cells: [Cell] = []
        var i = rows - 1
        var j = cols - 1
        while i > 0 || j > 0 {
            let index = Int(from[i * cols + j])
            guard index >= 0 else { return nil }
            let move = moves[index]
            for (vi, vj) in move.visits.reversed() { cells.append(Cell(i: i + vi, j: j + vj)) }
            i -= move.di
            j -= move.dj
        }
        cells.append(Cell(i: 0, j: 0))
        cells.reverse()
        return (cells, pitchTotal[rows * cols - 1] / Double(rows + cols))
    }

    /// Step 7: the gaps near each boundary. A gap of `restMinSeconds` or more becomes `<SP>` (the note before it ends where
    /// the gap starts, the note after it starts where the gap ends); a shorter gap is absorbed into the following note.
    ///
    /// Each gap belongs only to its NEAREST boundary, among the boundaries within `reach` frames of it. A tie goes to the
    /// earlier boundary ([A], p2-sing-d3 round 3; it is also who claimed first before the fix). A boundary that owns no gap
    /// keeps its aligned position. Before round 3 every boundary claimed its own nearest gap, so on the user's take one
    /// breath (3.296-3.520 s) was claimed by three boundaries: three identical rests, and the order pass below squeezed
    /// the two notes between them to one frame each (16 ms). Two boundaries INSIDE one breath still leave the later one's
    /// note a single frame: the alignment put that note in silence, and there is no voiced time to give it.
    ///
    /// Then every span is kept non-empty and in order.
    /// - Parameters:
    ///   - aligned: each note's first frame from the alignment (index 0 is the window's first frame), ascending.
    ///   - sung: the window's frames; nil = unvoiced.
    ///   - reach: how far from a boundary, in frames, a gap may sit and still be claimed.
    ///   - hop: seconds per frame.
    /// - Returns: each note's first frame and end frame (half-open), and the rests.
    static func placeGaps(starts aligned: [Int], sung: [Double?], reach: Int, hop: Double)
        -> (starts: [Int], ends: [Int], rests: [Range<Int>]) {
        let m = sung.count
        let noteCount = aligned.count
        var starts = aligned
        var ends = [Int](repeating: m, count: noteCount)
        var rests: [Range<Int>] = []
        guard noteCount >= 1 else { return (starts, ends, rests) }
        let runs = unvoicedRuns(sung)
        func isNear(_ run: Range<Int>, _ boundary: Int) -> Bool {
            run.upperBound > boundary - reach && run.lowerBound <= boundary + reach
        }
        // Each gap's owner: the nearest boundary it is near. Only a strictly nearer boundary replaces the owner, so a tie
        // goes to the earlier one.
        var owner = [Int?](repeating: nil, count: runs.count)
        for (r, run) in runs.enumerated() {
            for k in 1..<noteCount where isNear(run, aligned[k]) {
                if let o = owner[r], distance(run, aligned[o]) <= distance(run, aligned[k]) { continue }
                owner[r] = k
            }
        }
        for k in 1..<noteCount {
            ends[k - 1] = starts[k]
            let boundary = aligned[k]
            let owned = runs.indices.filter { owner[$0] == k }
            guard let r = owned.min(by: { distance(runs[$0], boundary) < distance(runs[$1], boundary) }) else { continue }
            let run = runs[r]
            if Double(run.upperBound - run.lowerBound) * hop >= restMinSeconds {
                ends[k - 1] = run.lowerBound
                starts[k] = run.upperBound
                rests.append(run)
            } else {
                starts[k] = run.lowerBound
                ends[k - 1] = run.lowerBound
            }
        }
        // Keep every span non-empty and in order.
        for k in 1..<noteCount {
            starts[k] = min(max(starts[k], starts[k - 1] + 1), m - (noteCount - k))
            ends[k - 1] = min(max(ends[k - 1], starts[k - 1] + 1), starts[k])
        }
        ends[noteCount - 1] = m
        return (starts, ends, rests)
    }

    /// Maximal runs of unvoiced frames, as half-open index ranges.
    static func unvoicedRuns(_ sung: [Double?]) -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var i = 0
        while i < sung.count {
            guard sung[i] == nil else { i += 1; continue }
            var j = i
            while j < sung.count, sung[j] == nil { j += 1 }
            runs.append(i..<j)
            i = j
        }
        return runs
    }

    static func distance(_ run: Range<Int>, _ index: Int) -> Int {
        if run.contains(index) { return 0 }
        return index < run.lowerBound ? run.lowerBound - index : index - (run.upperBound - 1)
    }

    // MARK: - Onset evidence from audio (RMS rise + spectral flux)

    /// Onset strength on the pitch frames' grid, 0…1: half the normalised RMS rise (dB over 32 ms, clipped at 0) and
    /// half the normalised spectral flux (positive log-magnitude differences between consecutive frames, Hann window
    /// of ~43 ms), each divided by its 99th percentile and clipped to 1. Offline analysis only.
    public static func onsetStrength(samples: [Float], sampleRate: Double, frameTimes: [Double]) -> [Double] {
        let count = frameTimes.count
        guard count > 0, sampleRate > 0, !samples.isEmpty else { return [Double](repeating: 0, count: count) }
        let rmsHalf = max(1, Int(0.016 * sampleRate))
        func levelDb(at t: Double) -> Double {
            let centre = Int((t * sampleRate).rounded())
            let lo = max(0, centre - rmsHalf)
            let hi = min(samples.count, centre + rmsHalf)
            guard hi > lo else { return -120 }
            var sum = 0.0
            for s in lo..<hi { sum += Double(samples[s]) * Double(samples[s]) }
            return 10 * log10(sum / Double(hi - lo) + 1e-12)
        }
        var rise = [Double](repeating: 0, count: count)
        for (k, t) in frameTimes.enumerated() { rise[k] = max(0, levelDb(at: t) - levelDb(at: t - 0.032)) }

        let size = 1 << Int((log2(0.043 * sampleRate)).rounded())
        let window = TimbreLiveness.hann(size)
        var previous: [Double]?
        var flux = [Double](repeating: 0, count: count)
        for (k, t) in frameTimes.enumerated() {
            let start = Int((t * sampleRate).rounded()) - size / 2
            var real = [Double](repeating: 0, count: size)
            var imaginary = [Double](repeating: 0, count: size)
            for i in 0..<size where start + i >= 0 && start + i < samples.count {
                real[i] = Double(samples[start + i]) * window[i]
            }
            TimbreLiveness.fft(real: &real, imaginary: &imaginary)
            var spectrum = [Double](repeating: 0, count: size / 2)
            for b in 0..<(size / 2) {
                spectrum[b] = log(1 + 100 * (real[b] * real[b] + imaginary[b] * imaginary[b]).squareRoot())
            }
            if let previous {
                var sum = 0.0
                for b in 0..<(size / 2) { sum += max(0, spectrum[b] - previous[b]) }
                flux[k] = sum
            }
            previous = spectrum
        }
        func normalised(_ x: [Double]) -> [Double] {
            let p99 = VoiceClipCheck.percentileLinear(x.sorted(), 0.99)
            guard p99 > 0 else { return x.map { _ in 0 } }
            return x.map { min(1, $0 / p99) }
        }
        let r = normalised(rise)
        let f = normalised(flux)
        return (0..<count).map { 0.5 * r[$0] + 0.5 * f[$0] }
    }
}
