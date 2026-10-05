import Foundation
import Testing
@testable import DAWCore

/// m23-ap I5-F4 round 4 — `SliceBoundaries.gridDivisions`, TOTAL: it no longer
/// lists every grid line in the window before conditioning (a 1e-20 grid on a
/// 4-beat clip asked `Int(_:)` for 4e20 lines), it searches for the next line
/// `condition` would keep.
///
/// THE PROOF IS A DIFFERENTIAL: `legacyWalk` + `legacyGridDivisions` below are
/// the old body, verbatim, and every case the old body can finish is compared with the new
/// one bit for bit, across clip positions (on and off the grid, far out),
/// windows, grids (straight, triplet, the 1/1024 floor, finer, coarser than the
/// window), tempos and minimum slices (including 0 and negative, where every
/// line is kept). The traps themselves are proven in throwaway processes, never
/// here. Nonisolated: pure values only.
@Suite("Slice grid, total (m23-ap I5-F4 round 4)")
struct SliceGridTotalityTests {

    /// `SliceBoundaries.gridDivisions` as it was before round 4, VERBATIM, split
    /// in two only so the walk (which does not read `minSliceSeconds`) runs
    /// once per case: `legacyWalk` is the old body up to its `condition` call,
    /// returning the raw list or nil where the old body returned [] early.
    private static func legacyWalk(clipStartBeat: Double,
                                   windowStart: Double, windowEnd: Double,
                                   gridBeats: Double,
                                   tempoMap: TempoMap) -> [Double]? {
        guard gridBeats > 0, windowEnd > windowStart else { return nil }
        let spb = tempoMap.secondsPerBeat(atBeat: clipStartBeat)
        guard spb > 0 else { return nil }
        let startBeat = clipStartBeat
        let endBeat = clipStartBeat + (windowEnd - windowStart) / spb
        var raw: [Double] = []
        var index = (startBeat / gridBeats).rounded(.down)
        let maxLines = Int(((endBeat - startBeat) / gridBeats).rounded(.up)) + 2
        var emitted = 0
        while emitted <= maxLines {
            let beat = index * gridBeats
            index += 1
            emitted += 1
            if beat <= startBeat { continue }
            if beat >= endBeat { break }
            raw.append(windowStart + (beat - startBeat) * spb)
        }
        return raw
    }

    private static func legacyGridDivisions(raw: [Double]?, windowStart: Double, windowEnd: Double,
                                            minSliceSeconds: Double) -> [Double] {
        guard let raw else { return [] }
        return SliceBoundaries.condition(onsetsSourceSeconds: raw, windowStart: windowStart,
                                         windowEnd: windowEnd, minSliceSeconds: minSliceSeconds)
    }

    private static func tempo(_ bpm: Double) -> TempoMap { TempoMap(constantBPM: bpm) }

    @Test("DIFFERENTIAL: for every case the old walk can finish, the new gridDivisions returns exactly the old boundaries, bit for bit — across positions, windows, grids, tempos and minimum slices, including every line kept (minimum 0 or negative) and grids far finer than the minimum slice")
    func sameBoundariesAsTheOldWalk() {
        let starts = [0.0, 0.1, 2.1, 7.3, 1000.37, 1_048_576, 3e9 + 0.5, -4.2]
        let windows: [(Double, Double)] = [(0, 2), (0.5, 3.7), (10, 10.004), (0, 60), (3, 3.000_000_1), (1.25, 9.75)]
        let grids = [0.25, 0.5, 1.0 / 3.0, 1.0 / 6.0, 0.0625, 1.0 / 1024, 1, 4, 7.3, 1e-4, 1e6]
        let bpms = [120.0, 97.3, 400, 20]
        let minimums = [0.05, 0.001, 0.5, 10, 0, -1]
        var compared = 0, nonEmpty = 0, lines = 0.0
        for bpm in bpms {
            let map = Self.tempo(bpm)
            let spb = map.secondsPerBeat(atBeat: 0)
            for start in starts {
                for (ws, we) in windows {
                    for grid in grids {
                        // Keep the OLD walk affordable: at most 2e5 lines per case.
                        let visited = (we - ws) / spb / grid
                        guard visited <= 200_000 else { continue }
                        let raw = Self.legacyWalk(clipStartBeat: start, windowStart: ws, windowEnd: we,
                                                  gridBeats: grid, tempoMap: map)
                        lines += visited
                        for minimum in minimums {
                            let old = Self.legacyGridDivisions(raw: raw, windowStart: ws, windowEnd: we,
                                                               minSliceSeconds: minimum)
                            let new = SliceBoundaries.gridDivisions(
                                clipStartBeat: start, windowStart: ws, windowEnd: we, gridBeats: grid,
                                tempoMap: map, minSliceSeconds: minimum)
                            // ONE Bool, not the two lists: `#expect` prints its
                            // operands, and a failing case can hold 2e5 lines (a
                            // planted bug once wrote a 942 MB log this way). The
                            // predicate is unchanged: the same bits, in order.
                            let same = old.map { $0.bitPattern } == new.map { $0.bitPattern }
                            let firstDifference = same ? -1 : (zip(old, new).enumerated()
                                .first { $0.element.0.bitPattern != $0.element.1.bitPattern }?.offset
                                ?? min(old.count, new.count))
                            #expect(same,
                                    "start \(start) window \(ws)...\(we) grid \(grid) bpm \(bpm) min \(minimum): \(old.count) vs \(new.count), first difference at index \(firstDifference)")
                            compared += 1
                            if !old.isEmpty { nonEmpty += 1 }
                        }
                    }
                }
            }
        }
        // CONTROLS: the sweep really ran, most cases produced boundaries, and it
        // reached the long walks where the search skips the most.
        #expect(compared > 5_000, "\(compared)")
        #expect(nonEmpty > compared / 3, "\(nonEmpty) of \(compared)")
        #expect(lines > 5_000_000, "\(lines)")
    }

    @Test("the cap keeps the first boundaries, in order: any maximumBoundaries gives a prefix of the full answer; the default is 2^24")
    func capKeepsAPrefix() {
        #expect(SliceBoundaries.maximumGridBoundaries == 1 << 24)
        let map = Self.tempo(120)
        let full = SliceBoundaries.gridDivisions(clipStartBeat: 0, windowStart: 0, windowEnd: 8,
                                                 gridBeats: 0.25, tempoMap: map, minSliceSeconds: 0.05)
        #expect(full.count == 63)   // 16 beats of 1/16 lines, the two ends excluded
        for cap in [0, 1, 5, 63, 64, 1000] {
            let capped = SliceBoundaries.gridDivisions(clipStartBeat: 0, windowStart: 0, windowEnd: 8,
                                                       gridBeats: 0.25, tempoMap: map, minSliceSeconds: 0.05,
                                                       maximumBoundaries: cap)
            #expect(capped == Array(full.prefix(max(0, cap))), "cap \(cap)")
        }
    }

    @Test("TOTAL: grids and windows the old walk could not finish (4e12 lines) or trapped on (4e20 lines, an infinite window, not a number) answer at once; where the line indices pass 2^53 there are no boundaries")
    func answersWhatTheOldWalkCouldNot() {
        let map = Self.tempo(120)
        // 1e-12 on 4 beats (2 s at 120): 4e12 lines, which the old walk could
        // finish only in theory. Only lines at least 50 ms apart are kept: one
        // per 50 ms, the two ends excluded.
        let fine = SliceBoundaries.gridDivisions(clipStartBeat: 0, windowStart: 0, windowEnd: 2,
                                                 gridBeats: 1e-12, tempoMap: map, minSliceSeconds: 0.05)
        #expect(fine.count >= 38 && fine.count <= 39, "\(fine.count)")
        let gaps = zip(fine, fine.dropFirst()).map { $1 - $0 }
        #expect(gaps.allSatisfy { $0 >= 0.05 })
        #expect(fine.allSatisfy { $0 >= 0.05 && $0 <= 1.95 })
        // 1e-20 on the same window: 4e20 lines, `Int(_:)` trapped before. Its
        // line indices pass 2^53, so there is no grid to answer with.
        #expect(SliceBoundaries.gridDivisions(clipStartBeat: 0, windowStart: 0, windowEnd: 2,
                                              gridBeats: 1e-20, tempoMap: map, minSliceSeconds: 0.05).isEmpty)
        // Every line kept (minimum 0) is bounded by the cap, not by the lines.
        let everyLine = SliceBoundaries.gridDivisions(clipStartBeat: 0, windowStart: 0, windowEnd: 2,
                                                      gridBeats: 1e-12, tempoMap: map, minSliceSeconds: 0,
                                                      maximumBoundaries: 1000)
        #expect(everyLine.count == 1000)
        // An infinite window, and a clip position that is not a number.
        #expect(SliceBoundaries.gridDivisions(clipStartBeat: 0, windowStart: 0, windowEnd: .infinity,
                                              gridBeats: 0.25, tempoMap: map, minSliceSeconds: 0.05,
                                              maximumBoundaries: 10).count <= 10)
        #expect(SliceBoundaries.gridDivisions(clipStartBeat: .nan, windowStart: 0, windowEnd: 2,
                                              gridBeats: 0.25, tempoMap: map, minSliceSeconds: 0.05).isEmpty)
        // Far out: past 2^53 grid lines from beat 0 there is no grid to answer with.
        #expect(SliceBoundaries.gridDivisions(clipStartBeat: 1e18, windowStart: 0, windowEnd: 2,
                                              gridBeats: 0.25, tempoMap: map, minSliceSeconds: 0.05).isEmpty)
        #expect(SliceBoundaries.gridDivisions(clipStartBeat: 0, windowStart: 0, windowEnd: 2,
                                              gridBeats: Double.leastNonzeroMagnitude, tempoMap: map,
                                              minSliceSeconds: 0.05).isEmpty)
        // An infinite grid has no line inside any window (as before).
        #expect(SliceBoundaries.gridDivisions(clipStartBeat: 3, windowStart: 0, windowEnd: 2,
                                              gridBeats: .infinity, tempoMap: map, minSliceSeconds: 0.05).isEmpty)
    }
}
