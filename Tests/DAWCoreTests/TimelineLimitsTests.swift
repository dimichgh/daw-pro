import Foundation
import Testing
@testable import DAWCore

/// m23-ap I5-F4 round 4 — the timeline ceiling, and two of the arithmetic
/// sites it protects made TOTAL on their own: `MeterMap.barBeat`
/// (TempoMap.swift) and the groove fold (`GrooveTemplate`, Groove.swift).
///
/// Each site is pinned two ways: it answers ANY input without trapping, and on
/// every input that worked before it answers exactly what it answered before,
/// compared bit for bit against a verbatim copy of the old body kept below.
/// (The traps themselves are proven in throwaway processes, never here: a trap
/// would kill every suite in the run.)
///
/// Nonisolated: pure values only.
@Suite("Timeline ceiling (m23-ap I5-F4 round 4)")
struct TimelineLimitsTests {

    // MARK: - The one number

    @Test("the ceiling is 2^20 beats; a position within it in either direction is accepted, and anything past it or not finite is not")
    func ceilingIsPinned() {
        #expect(TimelineLimits.maximumBeats == 1_048_576)
        #expect(TimelineLimits.maximumBeats == Double(1 << 20))
        for inside in [0.0, 1, 0.25, 1_048_575.75, 1_048_576, -1_048_576, -0.0] {
            #expect(TimelineLimits.isWithin(inside), "\(inside)")
        }
        for outside in [1_048_576.000_001, -1_048_576.000_001, 2e6, 1e300,
                        Double.greatestFiniteMagnitude, .infinity, -.infinity, .nan] {
            #expect(!TimelineLimits.isWithin(outside), "\(outside)")
        }
    }

    @Test("a grid quantize can use is finite, at least 1/1024 beat and at most the 2^20-beat ceiling")
    func usableGridIsPinned() {
        for usable in [1.0 / 1024, 0.0625, 0.25, 1.0 / 3.0, 4, 1_048_576] {
            #expect(QuantizeLimits.isUsableGrid(usable), "\(usable)")
        }
        for unusable in [0.0009, 1e-20, Double.leastNonzeroMagnitude, 0, -0.25,
                         1_048_576.000_001, 1e300, .infinity, .nan] {
            #expect(!QuantizeLimits.isUsableGrid(unusable), "\(unusable)")
        }
    }

    // MARK: - MeterMap.barBeat (TempoMap.swift)

    /// `MeterMap.barBeat` as it was before round 4, verbatim, over the same
    /// derived `barsBefore` the init builds (recomputed here from the changes,
    /// with the init's own expression).
    private static func legacyBarBeat(_ changes: [MeterMap.Change],
                                      _ beat: Double) -> (bar: Int, beatInBar: Double) {
        var barsBefore = [0]
        for i in 1..<max(1, changes.count) {
            let prev = changes[i - 1]
            let bars = (changes[i].startBeat - prev.startBeat) / Double(prev.beatsPerBar)
            barsBefore.append(barsBefore[i - 1] + Int(bars.rounded()))
        }
        var i = 0
        for (k, change) in changes.enumerated() where change.startBeat <= beat { i = k }
        let change = changes[i]
        let bpb = Double(change.beatsPerBar)
        let rel = max(0, beat - change.startBeat)
        return (bar: barsBefore[i] + Int(rel / bpb),
                beatInBar: rel.truncatingRemainder(dividingBy: bpb))
    }

    private static let meterMaps: [[MeterMap.Change]] = [
        [MeterMap.Change(startBeat: 0, beatsPerBar: 4, beatUnit: 4)],
        [MeterMap.Change(startBeat: 0, beatsPerBar: 3, beatUnit: 4)],
        [MeterMap.Change(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
         MeterMap.Change(startBeat: 16, beatsPerBar: 3, beatUnit: 4),
         MeterMap.Change(startBeat: 25, beatsPerBar: 5, beatUnit: 4),
         MeterMap.Change(startBeat: 40, beatsPerBar: 7, beatUnit: 8)],
    ]

    @Test("MeterMap.barBeat answers exactly what it answered before for every beat whose bar is below 2^62 — every position the app can hold and far beyond — bit for bit")
    func barBeatIsUnchangedInRange() throws {
        var beats: [Double] = [0, 0.5, 1, 3.999, 4, 15.9, 16, 16.5, 24.99, 25, 39.99, 40, 41,
                               1000.25, 1_048_575.5, 1_048_576, 1e6 + 0.3, 1e9, 1e12 + 0.5,
                               1e15, 1e18, 3e18, 1.8e19, -1, -1e300, .nan, -.infinity]
        // The largest beat of each map whose bar still sits below 2^62 in 4/4.
        beats.append(18_446_744_073_709_549_568.0)   // 2^64 - 2048: bar 2^62 - 512 in 4/4
        var compared = 0
        for changes in Self.meterMaps {
            let map = try MeterMap(changes: changes)
            for beat in beats {
                let legacy = Self.legacyBarBeat(changes, beat)
                guard legacy.bar < 1 << 62 else { continue }   // the pinned region, below
                let now = map.barBeat(atBeat: beat)
                #expect(now.bar == legacy.bar, "bar at \(beat) in \(changes.count)-change map")
                #expect(now.beatInBar.bitPattern == legacy.beatInBar.bitPattern,
                        "beatInBar at \(beat) in \(changes.count)-change map")
                compared += 1
            }
        }
        // CONTROL: the sweep really compared (a filter that skipped everything
        // would pass the loop above vacuously).
        #expect(compared >= 3 * (beats.count - 2))
    }

    @Test("MeterMap.barBeat answers ANY beat without trapping: a beat 2^63 or more bars in, the largest Double, and infinity pin at bar 2^62, beat 0 of that bar, and nearestBarline stays finite there")
    func barBeatIsTotal() throws {
        let farthest = 1 << 62
        for changes in Self.meterMaps {
            let map = try MeterMap(changes: changes)
            // 3.7e19 beats in 4/4 is 9.25e18 bars: past Int.max, a trap before.
            for beat in [3.7e19, 1e20, 1e300, Double.greatestFiniteMagnitude, .infinity] {
                let answer = map.barBeat(atBeat: beat)
                #expect(answer.bar == farthest, "\(beat)")
                #expect(answer.beatInBar == 0, "\(beat)")
                #expect(map.nearestBarline(toBeat: beat).isFinite, "\(beat)")
            }
            // Not a number, and minus infinity, clamp to bar 0 as before.
            #expect(map.barBeat(atBeat: .nan).bar == 0)
            #expect(map.barBeat(atBeat: -.infinity).bar == 0)
        }
        // The boundary: 2^64 beats in 4/4 is exactly bar 2^62, which the old
        // body also answered; one representable beat further pins.
        let fourFour = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))
        #expect(fourFour.barBeat(atBeat: 18_446_744_073_709_551_616.0).bar == farthest)
        #expect(fourFour.barBeat(atBeat: 18_446_744_073_709_555_712.0).bar == farthest)
    }

    // MARK: - The groove fold (Groove.swift)

    /// `GrooveTemplate.extract` + the init's normalization as they were before
    /// round 4, verbatim: `Int` slots, an `Int` fold, and an uncapped count.
    private static func legacyExtractOffsets(_ onsets: [Double], gridBeats: Double,
                                             cycleBeats: Double) -> [Double] {
        let grid = gridBeats > 0 ? gridBeats : 0.0001
        let cycle = cycleBeats > 0 ? cycleBeats : grid
        let count = max(1, Int((cycle / grid).rounded()))
        var sums = [Double](repeating: 0, count: count)
        var hits = [Int](repeating: 0, count: count)
        for onset in onsets {
            let slot = Int((onset / grid).rounded())
            let folded = ((slot % count) + count) % count
            let deviation = onset - Double(slot) * grid
            sums[folded] += deviation
            hits[folded] += 1
        }
        let offsets = (0..<count).map { hits[$0] > 0 ? sums[$0] / Double(hits[$0]) : 0 }
        // The init's normalization (count is unchanged by it).
        let bound = grid / 2
        return offsets.map { $0.clamped(to: -bound...bound) }
    }

    /// Deterministic onsets around each slot, negative ones, exact multiples of
    /// the whole cycle on both sides (the `-0.0` fold), and slots up to 2^62,
    /// the region where only an exact fold keeps the answer.
    private static func onsets(grid: Double, cycle: Double) -> [Double] {
        var out: [Double] = []
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        for i in 0..<48 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let jitter = (Double(state >> 11) / Double(1 << 53) - 0.5) * grid * 0.8
            out.append(Double(i) * grid + jitter)
            out.append(-Double(i) * grid + jitter)
        }
        for k in [1.0, 3, 7] {
            out.append(k * cycle)
            out.append(-k * cycle)
        }
        for slot in [1e6, 1e12, 9_007_199_254_740_992.0, 4e17, 4_611_686_018_427_387_904.0] {
            out.append(slot * grid + grid * 0.1)
            out.append(-slot * grid - grid * 0.2)
        }
        return out
    }

    @Test("the groove fold answers exactly what it answered before — every offset, bit for bit — for every grid and cycle that worked, including slots up to 2^62 and cycles of exactly 65536 slots")
    func grooveFoldIsUnchangedInRange() {
        var compared = 0
        for grid in [0.25, 0.5, 1.0 / 3.0, 1.0 / 6.0, 0.0625, 1.0 / 1024, 1, 4] {
            for slots in [1.0, 2, 3, 16, 65_536] {
                let cycle = grid * slots
                let onsets = Self.onsets(grid: grid, cycle: cycle)
                let legacy = Self.legacyExtractOffsets(onsets, gridBeats: grid, cycleBeats: cycle)
                let now = GrooveTemplate.extract(fromOnsetBeats: onsets, gridBeats: grid,
                                                 cycleBeats: cycle, name: "pin").offsets
                let nowBits = now.map { $0.bitPattern }
                let legacyBits = legacy.map { $0.bitPattern }
                #expect(now.count == legacy.count, "grid \(grid) slots \(slots)")
                #expect(nowBits == legacyBits, "grid \(grid) slots \(slots)")
                compared += 1
            }
        }
        #expect(compared == 40)
        // The init builds the same count as before up to and including 65536.
        for slots in [1.0, 16, 65_535, 65_536] {
            let groove = GrooveTemplate(name: "n", gridBeats: 0.25, cycleBeats: 0.25 * slots, offsets: [])
            #expect(groove.offsets.count == Int(slots))
        }
    }

    @Test("the groove fold answers ANY grid, cycle and onset without trapping: a count past 65536 slots (or not a number) is held at 65536, and an onset with no finite slot is left out")
    func grooveFoldIsTotal() {
        // A cycle of 65537 slots: the one count the cap changes (65537 before).
        #expect(GrooveTemplate(name: "n", gridBeats: 0.25, cycleBeats: 0.25 * 65_537,
                               offsets: []).offsets.count == 65_536)
        // Ratios that trapped `Int(_:)` in the init and in extract.
        for (grid, cycle) in [(1e-20, 4.0), (1e-300, 4.0), (Double.leastNonzeroMagnitude, 1),
                              (0.25, Double.infinity)] {
            let built = GrooveTemplate(name: "n", gridBeats: grid, cycleBeats: cycle, offsets: [0.1])
            #expect(built.offsets.count == 65_536, "init \(grid) / \(cycle)")
            let extracted = GrooveTemplate.extract(fromOnsetBeats: [0, 1, 2.5], gridBeats: grid,
                                                   cycleBeats: cycle, name: "n")
            #expect(extracted.offsets.count == 65_536, "extract \(grid) / \(cycle)")
            #expect(extracted.offsets.allSatisfy { $0.isFinite })
        }
        // An infinite grid and cycle: the ratio is not a number (a trap before).
        #expect(GrooveTemplate(name: "n", gridBeats: .infinity, cycleBeats: .infinity,
                               offsets: []).offsets.count == 65_536)
        #expect(GrooveTemplate.extract(fromOnsetBeats: [1], gridBeats: .infinity,
                                       cycleBeats: .infinity, name: "n").offsets.count == 65_536)
        // Onsets whose slot trapped (2^63 slots or more, or not finite).
        let far = GrooveTemplate.extract(fromOnsetBeats: [3e18, 1e300, .infinity, -.infinity, .nan],
                                         gridBeats: 0.25, cycleBeats: 1, name: "far")
        #expect(far.offsets.count == 4)
        #expect(far.offsets.allSatisfy { $0.isFinite })
        let skipped = GrooveTemplate.extract(fromOnsetBeats: [.infinity, -.infinity, .nan],
                                             gridBeats: 0.25, cycleBeats: 1, name: "none")
        #expect(skipped.offsets == [0, 0, 0, 0])
    }
}
