import DAWCore
import Foundation
import Testing
@testable import DAWEngine

/// m39-w4-4c (W8-W44G) — the musical clock's two readers: the render's
/// `ModulationEvaluator` and the control plane's `mod.describe`.
///
/// CG, the clock gate: `compileClock`'s whole output (every segment's four
/// Doubles as bit patterns, the head count and the loop constants) over a
/// grid of tempo maps, meter maps, roll anchors, loops and sample rates. With
/// `W44G_CLOCKGATE_OUT=<folder>` the text lands there, so a refactor of the
/// compile can be compared with `cmp` against a capture taken before it.
/// W44's G1 byte gate cannot see `compileClock` at all (none of its renders
/// carries a synced source); this one is the gate that can.
///
/// T4, the agreement: `ModulationMath.syncedStepValue` (DAWCore, what
/// `mod.describe` reports) evaluated at the clock's own beat equals
/// `ModulationEvaluator.value` (what the render outputs) BIT FOR BIT, across a
/// tempo change, a meter change, loop wraps, two sample rates and hard and
/// 2 ms edges. One home, two readers: if either side re-derives the
/// arithmetic, this goes red.
@Suite("ModDescribe clock agreement (m39-w4-4c): describe and the render read one clock")
struct ModDescribeClockAgreementTests {
    static func gateTempoMaps() throws -> [(name: String, map: TempoMap)] {
        [
            ("t120", TempoMap(constantBPM: 120)),
            ("t120-90@8", try TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 8, bpm: 90)])),
            ("t100-174@6-61@19.5",
             try TempoMap(segments: [.init(startBeat: 0, bpm: 100), .init(startBeat: 6, bpm: 174),
                                     .init(startBeat: 19.5, bpm: 61)])),
        ]
    }

    static func gateMeterMaps() throws -> [(name: String, map: MeterMap)] {
        [
            ("m4/4", MeterMap(constant: TimeSignature())),
            ("m3/4", try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 3, beatUnit: 4)])),
            ("m4/4-3/4@16",
             try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                    .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])),
            ("m4/4-3/4@16-7/8@25-5/4@32",
             try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                    .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4),
                                    .init(startBeat: 25, beatsPerBar: 7, beatUnit: 8),
                                    .init(startBeat: 32, beatsPerBar: 5, beatUnit: 4)])),
        ]
    }

    static let gateFromBeats: [Double] = [-1, 0, 2, 15.9, 16, 17.3, 25, 31.75]
    static let gateLoops: [(start: Double, end: Double)?] = [nil, (6, 14), (12, 20), (14, 26), (16, 33)]
    static let gateRates: [Double] = [44_100, 48_000]

    static func hex(_ value: Double) -> String { String(value.bitPattern, radix: 16) }

    /// One line per spec: its description, then every number `compileClock`
    /// produced, as bit patterns. Text, so a difference names its spec.
    static func clockGateLines() throws -> (lines: [String], origins: [(meter: MeterMap, startBeat: Double, origin: Double)]) {
        var lines: [String] = []
        var origins: [(meter: MeterMap, startBeat: Double, origin: Double)] = []
        for tempo in try gateTempoMaps() {
            let tempoMap = tempo.map
            for meter in try gateMeterMaps() {
                let meterMap = meter.map
                for fromBeat in gateFromBeats {
                    for loop in gateLoops {
                        for rate in gateRates {
                            let spec = ModulationClockTests.spec(tempoMap: tempoMap, meterMap: meterMap,
                                                                 fromBeat: fromBeat, loop: loop, rate: rate)
                            let clock = ModulationSnapshotBuilder.compileClock(spec)
                            var line = "\(tempo.name) \(meter.name) from=\(fromBeat) "
                                + "loop=\(loop.map { "\($0.start)-\($0.end)" } ?? "none") rate=\(rate) |"
                                + " head=\(clock.headCount) lh=\(hex(clock.loopHeadSeconds))"
                                + " lc=\(hex(clock.loopCycleSeconds)) n=\(clock.segments.count) |"
                            for segment in clock.segments {
                                line += " [\(hex(segment.startSeconds)) \(hex(segment.startBeat))"
                                    + " \(hex(segment.beatsPerSample)) \(hex(segment.patternOriginBeat))]"
                                origins.append((meterMap, segment.startBeat, segment.patternOriginBeat))
                            }
                            lines.append(line)
                        }
                    }
                }
            }
        }
        return (lines, origins)
    }

    @Test("ModDescribe CG: compileClock's output over 960 specs, captured as bit patterns for a before/after cmp")
    func modDescribeClockGateCapture() throws {
        let (lines, origins) = try Self.clockGateLines()
        #expect(lines.count == 3 * 4 * 8 * 5 * 2)
        // The gate can see a meter change: some segment's origin is not 0,
        // and the same roll compiles differently under a different meter.
        #expect(origins.contains { $0.origin == 16 })
        #expect(origins.contains { $0.origin == 32 })
        let plain = lines.filter { $0.hasPrefix("t120 m4/4 from=0.0 loop=none rate=48000.0") }
        let changed = lines.filter { $0.hasPrefix("t120 m4/4-3/4@16 from=0.0 loop=none rate=48000.0") }
        #expect(plain.count == 1 && changed.count == 1 && plain != changed,
                "a clock gate blind to the meter map compares nothing")
        // m39-w4-4c: every compiled origin is the one home's answer, and the
        // one home is the expression the compile used before it existed.
        var legacyMismatches = 0
        var homeMismatches = 0
        for entry in origins {
            let legacy = entry.meter.changes.last { $0.startBeat <= entry.startBeat }?.startBeat ?? 0
            if entry.origin.bitPattern != legacy.bitPattern { legacyMismatches += 1 }
            if entry.origin.bitPattern != entry.meter.patternOriginBeat(atBeat: entry.startBeat).bitPattern {
                homeMismatches += 1
            }
        }
        print("[measured] ModDescribe CG: \(lines.count) specs, \(origins.count) segments; origin ≠ legacy "
              + "expression: \(legacyMismatches); origin ≠ MeterMap.patternOriginBeat: \(homeMismatches)")
        #expect(legacyMismatches == 0)
        #expect(homeMismatches == 0)
        if let folder = ProcessInfo.processInfo.environment["W44G_CLOCKGATE_OUT"] {
            let url = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try Data((lines.joined(separator: "\n") + "\n").utf8)
                .write(to: url.appendingPathComponent("clockgate.txt"))
        }
    }

    // MARK: - T4: describe's closed form == the render evaluator, bit for bit

    /// Roll frames to probe: a stride through the roll plus EVERY frame within
    /// 150 of each segment start (tempo change, meter change, roll anchor) in the
    /// head and in the first three loop cycles — the frames where the trailing
    /// edge, the pattern restart and the wrap actually live.
    static func probeFrames(_ spec: ModulationClockSpec, frames: Int64) -> [Int64] {
        var result: [Int64] = []
        var n: Int64 = 0
        while n < frames { result.append(n); n += 97 }
        let clock = ModulationSnapshotBuilder.compileClock(spec)
        var starts: [Double] = []
        for (index, segment) in clock.segments.enumerated() {
            if index < clock.headCount {
                starts.append(segment.startSeconds * spec.sampleRate)
            } else {
                var cycle = 0
                while cycle < 3 {
                    let offset = clock.loopHeadSeconds + Double(cycle) * clock.loopCycleSeconds
                    starts.append((offset + segment.startSeconds) * spec.sampleRate)
                    cycle += 1
                }
            }
        }
        for start in starts {
            let centre = Int64(start.rounded())
            var k = max(0, centre - 150)
            while k <= centre + 150 { result.append(k); k += 1 }
        }
        return result
    }

    @Test("ModDescribe T4: describe's synced value equals the render evaluator's at the same roll frames, bit for bit — 120→90, 4/4→3/4, loops, 44.1/48 kHz, hard and 2 ms edges")
    func modDescribeAgreesWithTheRenderEvaluator() throws {
        let tempo = try ModulationClockTests.g2TempoMap()
        let meter = try ModulationClockTests.g2MeterMap()
        let rolls: [(fromBeat: Double, loop: (start: Double, end: Double)?)] = [
            (0, nil), (2, nil), (17.3, nil), (2, (6, 14)), (10, (12, 20)), (0, (14, 26)),
        ]
        var probes = 0
        var mismatches = 0
        var inRamp = 0
        var oldPathDisagrees = 0
        var firstMismatch: String?
        for rate in [44_100.0, 48_000.0] {
            for edgeMs in [0.0, 2.0] {
                for roll in rolls {
                    let spec = ModulationClockTests.spec(tempoMap: tempo, meterMap: meter, fromBeat: roll.fromBeat,
                                                         loop: roll.loop, rate: rate)
                    let source = ModulationClockTests.syncedSource(steps: ModulationClockTests.fiveDistinct,
                                                                   edgeMs: edgeMs)
                    guard case .stepSequencer(let params) = source.params else {
                        Issue.record("the fixture is not a step source")
                        return
                    }
                    let snap = try #require(ModulationClockTests.snapshot(
                        [source], spec: spec, rate: rate, origin: ModulationClockTests.originSample(spec)))
                    let stepValues = Set(ModulationClockTests.fiveDistinct.map { Double(Float($0)) })
                    for n in Self.probeFrames(spec, frames: Int64(24 * rate)) {
                        let rendered = ModulationClockTests.read(snap, rollFrame: n)
                        let clock = snap.clockPosition(atRollSample: n)
                        let described = ModulationMath.syncedStepValue(
                            params, atBeat: clock.beat, tempoMap: tempo, meterMap: meter, sampleRate: rate)
                        probes += 1
                        if !stepValues.contains(rendered) { inRamp += 1 }
                        if described?.bitPattern != rendered.bitPattern {
                            mismatches += 1
                            if firstMismatch == nil {
                                firstMismatch = "rate \(rate) edge \(edgeMs) from \(roll.fromBeat) loop "
                                    + "\(String(describing: roll.loop)) frame \(n) beat \(clock.beat): "
                                    + "described \(String(describing: described)) vs rendered \(rendered)"
                            }
                        }
                        // The pre-fix describe path (rateHz free-running from the
                        // song start) — the control that shows this probe can see.
                        let free = StepSequencerSourceParams(steps: params.steps, rateHz: params.rateHz,
                                                             edgeMs: params.edgeMs)
                        let songSample = Int64((tempo.seconds(from: 0, to: clock.beat) * rate).rounded())
                        if ModulationMath.value(of: .stepSequencer(free), atSample: songSample,
                                                sampleRate: rate) != rendered {
                            oldPathDisagrees += 1
                        }
                    }
                }
            }
        }
        print("[measured] ModDescribe T4: \(probes) probes, \(mismatches) bit mismatches, \(inRamp) inside an "
              + "edge ramp, the old free-running describe path disagrees at \(oldPathDisagrees)")
        #expect(mismatches == 0, "first: \(firstMismatch ?? "-")")
        #expect(inRamp > 100, "the probes must reach inside the 2 ms ramps, where `+ h` lives")
        #expect(oldPathDisagrees > probes / 4, "a probe the old describe path also passes proves nothing")
    }
}
