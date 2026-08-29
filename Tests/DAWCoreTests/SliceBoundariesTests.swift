import Foundation
import Testing
@testable import DAWCore

/// m32-b0 — `SliceBoundaries`, the ONE HOME for boundary conditioning.
///
/// ⚠️ The conditioning rule was EXTRACTED VERBATIM from
/// `AudioQuantizePlan.compute` step 1. The real extraction gate is that the
/// whole existing audio-quantize suite still passes unchanged (it does — the
/// planner now calls this and nothing else moved). What this suite adds is the
/// explicit pin the design asks for: one hand-built onset list carrying ALL
/// FOUR conditioning hazards at once, with the exact surviving list named, so
/// a future "cleanup" of the extracted body has something to break.
@Suite("SliceBoundaries — conditioning + generation (m32-b0)")
struct SliceBoundariesTests {

    // MARK: - condition

    @Test("all four conditioning hazards at once, exact surviving list")
    func fourHazards() {
        // Window [0, 2) s, minSlice 0.25 s.
        //   0.10  — inside the window but WITHIN minSlice of windowStart → dropped
        //   1.95  — inside the window but WITHIN minSlice of windowEnd   → dropped
        //   2.50  — OUTSIDE the window                                   → dropped
        //  -0.30  — outside on the low side                              → dropped
        //   0.00  — exactly AT windowStart (strict `>`)                  → dropped
        //   0.60  — survives
        //   0.70  — within minSlice of its predecessor 0.60              → dropped
        //   1.00  — survives (0.40 past 0.60)
        // ...and the list is fed UNSORTED, to pin the leading `sorted()`.
        let raw = [1.00, 0.70, 2.50, 0.10, -0.30, 0.60, 1.95, 0.00]
        let kept = SliceBoundaries.condition(
            onsetsSourceSeconds: raw, windowStart: 0, windowEnd: 2, minSliceSeconds: 0.25)
        #expect(kept == [0.60, 1.00])
    }

    @Test("merge is against the SURVIVING predecessor, not the raw one")
    func mergeAgainstSurvivor() {
        // 0.50 survives; 0.60 and 0.70 are each within 0.25 of 0.50 and drop.
        // A rule that compared against the RAW predecessor would keep 0.70
        // (0.70 − 0.60 = 0.10 < 0.25 drops it too, so use 0.80): with a raw
        // comparison 0.80 − 0.70 = 0.10 would DROP 0.80; with the surviving
        // comparison 0.80 − 0.50 = 0.30 KEEPS it. The two rules disagree here.
        let kept = SliceBoundaries.condition(
            onsetsSourceSeconds: [0.50, 0.60, 0.70, 0.80],
            windowStart: 0, windowEnd: 2, minSliceSeconds: 0.25)
        #expect(kept == [0.50, 0.80])
    }

    @Test("empty input and a window with no room both return []")
    func degenerate() {
        #expect(SliceBoundaries.condition(onsetsSourceSeconds: [], windowStart: 0,
                                          windowEnd: 2, minSliceSeconds: 0.25).isEmpty)
        // Window narrower than 2× minSlice: nothing can be minSlice from BOTH edges.
        #expect(SliceBoundaries.condition(onsetsSourceSeconds: [0.1, 0.2, 0.3],
                                          windowStart: 0, windowEnd: 0.4,
                                          minSliceSeconds: 0.25).isEmpty)
    }

    // MARK: - equalDivisions

    @Test("8 divisions of a 4 s window are the 7 interior 0.5 s boundaries")
    func eightDivisions() {
        let kept = SliceBoundaries.equalDivisions(
            windowStart: 0, windowEnd: 4, divisions: 8, minSliceSeconds: 0.05)
        #expect(kept.count == 7)
        for (i, value) in kept.enumerated() {
            #expect(abs(value - Double(i + 1) * 0.5) < 1e-9)
        }
    }

    @Test("divisions offset by a trimmed window start")
    func divisionsRespectWindowStart() {
        let kept = SliceBoundaries.equalDivisions(
            windowStart: 10, windowEnd: 14, divisions: 4, minSliceSeconds: 0.05)
        #expect(kept.count == 3)
        #expect(abs(kept[0] - 11) < 1e-9)
        #expect(abs(kept[2] - 13) < 1e-9)
    }

    @Test("too many divisions for the window drop by the minSlice rule, honestly")
    func divisionsClampByMinSlice() {
        // 64 divisions of 1 s = 15.6 ms apart, well under the 50 ms floor —
        // the honest answer is fewer boundaries, not 63 slivers.
        let kept = SliceBoundaries.equalDivisions(
            windowStart: 0, windowEnd: 1, divisions: 64, minSliceSeconds: 0.05)
        #expect(kept.count < 63)
        for i in 1..<kept.count {
            #expect(kept[i] - kept[i - 1] >= 0.05 - 1e-12)
        }
        // POSITIVE CONTROL: the same call at a floor that fits keeps all 63.
        let all = SliceBoundaries.equalDivisions(
            windowStart: 0, windowEnd: 1, divisions: 64, minSliceSeconds: 0.001)
        #expect(all.count == 63)
    }

    @Test("fewer than 2 divisions yields no boundaries")
    func oneDivision() {
        #expect(SliceBoundaries.equalDivisions(windowStart: 0, windowEnd: 4, divisions: 1,
                                               minSliceSeconds: 0.05).isEmpty)
    }

    // MARK: - gridDivisions

    @Test("grid lines land on whole beats in source seconds")
    func gridAtOrigin() {
        // 120 BPM → spb 0.5. Clip at beat 0, window [0, 2) s = beats [0, 4).
        // gridBeats 1 → interior lines at beats 1, 2, 3 → 0.5, 1.0, 1.5 s.
        let kept = SliceBoundaries.gridDivisions(
            clipStartBeat: 0, windowStart: 0, windowEnd: 2, gridBeats: 1,
            tempoMap: TempoMap(constantBPM: 120), minSliceSeconds: 0.05)
        #expect(kept.count == 3)
        #expect(abs(kept[0] - 0.5) < 1e-9)
        #expect(abs(kept[1] - 1.0) < 1e-9)
        #expect(abs(kept[2] - 1.5) < 1e-9)
    }

    @Test("grid lines are ABSOLUTE, so a clip starting off-grid is cut off-grid")
    func gridOffOrigin() {
        // Clip starts at beat 0.5 and runs 4 beats → interior absolute lines
        // at beats 1, 2, 3, 4 → 0.25, 0.75, 1.25, 1.75 s into the source.
        let kept = SliceBoundaries.gridDivisions(
            clipStartBeat: 0.5, windowStart: 0, windowEnd: 2, gridBeats: 1,
            tempoMap: TempoMap(constantBPM: 120), minSliceSeconds: 0.05)
        #expect(kept.count == 4)
        #expect(abs(kept[0] - 0.25) < 1e-9)
        #expect(abs(kept[3] - 1.75) < 1e-9)
        // POSITIVE CONTROL: an on-grid clip gives a DIFFERENT list. A test that
        // only ever compares one placement to itself cannot see a planner that
        // ignored `clipStartBeat`.
        let onGrid = SliceBoundaries.gridDivisions(
            clipStartBeat: 0, windowStart: 0, windowEnd: 2, gridBeats: 1,
            tempoMap: TempoMap(constantBPM: 120), minSliceSeconds: 0.05)
        #expect(onGrid != kept)
    }

    @Test("a window start offset carries into the returned source seconds")
    func gridWithSourceOffset() {
        let kept = SliceBoundaries.gridDivisions(
            clipStartBeat: 0, windowStart: 10, windowEnd: 12, gridBeats: 1,
            tempoMap: TempoMap(constantBPM: 120), minSliceSeconds: 0.05)
        #expect(kept.count == 3)
        #expect(abs(kept[0] - 10.5) < 1e-9)
    }

    @Test("a non-positive gridBeats yields nothing rather than spinning")
    func gridGuards() {
        #expect(SliceBoundaries.gridDivisions(
            clipStartBeat: 0, windowStart: 0, windowEnd: 2, gridBeats: 0,
            tempoMap: TempoMap(constantBPM: 120), minSliceSeconds: 0.05).isEmpty)
        #expect(SliceBoundaries.gridDivisions(
            clipStartBeat: 0, windowStart: 2, windowEnd: 2, gridBeats: 1,
            tempoMap: TempoMap(constantBPM: 120), minSliceSeconds: 0.05).isEmpty)
    }
}
