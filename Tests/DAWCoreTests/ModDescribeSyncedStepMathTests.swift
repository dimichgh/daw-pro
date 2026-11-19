import DAWCore
import Foundation
import Testing

/// m39-w4-4c (W8-W44G) — the DAWCore half of "`mod.describe` reads a synced
/// step source the way the render does" (`$S/w8/W44R/REVIEW.md` §Q5 N2).
///
/// Before this, `mod.describe` evaluated every step source with
/// `ModulationMath.value(of:atSample:sampleRate:)`, which free-runs on
/// `rateHz`; the render reads a SYNCED source on the musical clock and
/// ignores `rateHz`. These pin the one home both now read:
/// `MeterMap.patternOriginBeat(atBeat:)` (shared with the clock compile) and
/// `ModulationMath.syncedStepValue(_:atBeat:tempoMap:meterMap:sampleRate:)`.
/// The bit-for-bit agreement with the render evaluator lives in
/// `Tests/DAWEngineTests/ModDescribeClockAgreementTests.swift` (the evaluator
/// is internal to DAWEngine); the wire half is appended to `FXCommandTests`.
@Suite("ModDescribe synced step math (m39-w4-4c): one pattern origin, one synced closed form")
struct ModDescribeSyncedStepMathTests {
    static let rate = 48_000.0

    static func meterMaps() throws -> [(name: String, map: MeterMap)] {
        [
            ("4/4", MeterMap(constant: TimeSignature())),
            ("3/4", try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 3, beatUnit: 4)])),
            ("4/4, 3/4@16", try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                                   .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])),
            ("4/4, 3/4@16, 7/8@25, 5/4@32",
             try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                    .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4),
                                    .init(startBeat: 25, beatsPerBar: 7, beatUnit: 8),
                                    .init(startBeat: 32, beatsPerBar: 5, beatUnit: 4)])),
        ]
    }

    static func synced(_ steps: [Double], _ division: String, edgeMs: Double = 2) -> StepSequencerSourceParams {
        StepSequencerSourceParams(steps: steps, stepDivision: division, rateHz: 4, edgeMs: edgeMs)
    }

    static func value(_ params: StepSequencerSourceParams, atBeat beat: Double, tempo: TempoMap,
                      meter: MeterMap = MeterMap(constant: TimeSignature())) throws -> Double {
        try #require(ModulationMath.syncedStepValue(params, atBeat: beat, tempoMap: tempo,
                                                    meterMap: meter, sampleRate: rate))
    }

    // MARK: - T1: the pattern origin's one home

    @Test("ModDescribe T1: MeterMap.patternOriginBeat equals the clock compile's old expression bit for bit — negative, NaN, ±inf, on and between changes")
    func patternOriginMatchesTheLegacyExpression() throws {
        var beats: [Double] = [-.infinity, -1e300, -16, -1, -0.5, -Double.leastNonzeroMagnitude, -0.0, 0,
                               Double.leastNonzeroMagnitude, 0.25, 15.999_999, Double(16).nextDown, 16,
                               Double(16).nextUp, 17, 24.9, Double(25).nextDown, 25, 31.75, 32, 33, 1e6,
                               1e300, .greatestFiniteMagnitude, .infinity, .nan]
        var b = -2.0
        while b < 40 { beats.append(b); b += 0.125 }
        var checked = 0
        var wrong: [String] = []
        for (name, map) in try Self.meterMaps() {
            for beat in beats {
                let legacy = map.changes.last { $0.startBeat <= beat }?.startBeat ?? 0
                let origin = map.patternOriginBeat(atBeat: beat)
                checked += 1
                if origin.bitPattern != legacy.bitPattern { wrong.append("\(name) @\(beat): \(origin) vs \(legacy)") }
            }
        }
        print("[measured] ModDescribe T1: \(checked) (map, beat) pairs, \(wrong.count) differ from the legacy expression")
        #expect(checked == 4 * beats.count)
        #expect(wrong.isEmpty, "first: \(wrong.first ?? "-")")
        // Known values, so the equivalence cannot hold vacuously (both 0).
        let four = try #require(try Self.meterMaps().last?.map)
        let expected: [(Double, Double)] = [(-1, 0), (0, 0), (15.9, 0), (16, 16), (24.99, 16), (25, 25),
                                            (31.9, 25), (32, 32), (1e9, 32)]
        for (beat, origin) in expected {
            #expect(four.patternOriginBeat(atBeat: beat) == origin, "beat \(beat)")
        }
    }

    // MARK: - T2: the synced closed form, known values

    @Test("ModDescribe T2: [1,0] at 1/16 and 90 BPM reads step 1 at beat 0.25 (0) where rateHz free-running reads step 0 (1)")
    func syncedStepReadsTheBeatNotRateHz() throws {
        let tempo = TempoMap(constantBPM: 90)
        let params = Self.synced([1, 0], "1/16")
        let atZero = try Self.value(params, atBeat: 0, tempo: tempo)
        let atQuarter = try Self.value(params, atBeat: 0.25, tempo: tempo)
        let atHalf = try Self.value(params, atBeat: 0.5, tempo: tempo)
        print("[measured] ModDescribe T2: synced [1,0] 1/16 @90 — beat 0 → \(atZero), 0.25 → \(atQuarter), 0.5 → \(atHalf)")
        #expect(abs(atZero - 1) < 1e-9)
        #expect(abs(atQuarter) < 1e-9, "beat 0.25 is step 1 of a 1/16 pattern")
        #expect(abs(atHalf - 1) < 1e-9, "beat 0.5 wraps to step 0")
        // Control: what describe used to report — the SAME steps free-running at
        // rateHz 4 (sample 8000 at 90 BPM is 0.667 of a step: still step 0).
        let free = StepSequencerSourceParams(steps: [1, 0], rateHz: 4, edgeMs: 2)
        let sample = Int64((tempo.seconds(from: 0, to: 0.25) * Self.rate).rounded())
        let freeValue = try #require(ModulationMath.value(of: .stepSequencer(free), atSample: sample,
                                                          sampleRate: Self.rate))
        #expect(freeValue == 1, "the free-running reading the bug reported")
        #expect(ModulationMath.syncedStepValue(free, atBeat: 0.25, tempoMap: tempo,
                                               meterMap: MeterMap(constant: TimeSignature()),
                                               sampleRate: Self.rate) == nil,
                "an unsynced source has no synced reading: value(of:) answers for it")
        // The tempo does not move a synced step: beat 0.25 is step 1 at 120 BPM too.
        #expect(abs(try Self.value(params, atBeat: 0.25, tempo: TempoMap(constantBPM: 120))) < 1e-9)
    }

    @Test("ModDescribe T2: the pattern restarts at a meter change — [1,0,0] at 1/4 reads step 0 at beat 16 after 4/4 → 3/4")
    func syncedStepRestartsAtAMeterChange() throws {
        let tempo = TempoMap(constantBPM: 90)
        let meter = try MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                           .init(startBeat: 16, beatsPerBar: 3, beatUnit: 4)])
        let params = Self.synced([1, 0, 0], "1/4")
        let readings = try [15.0, 16, 17, 18, 19].map { try Self.value(params, atBeat: $0, tempo: tempo, meter: meter) }
        print("[measured] ModDescribe T2 meter: beats 15…19 → \(readings)")
        let expected: [Double] = [1, 1, 0, 0, 1]
        for (got, want) in zip(readings, expected) { #expect(abs(got - want) < 1e-9) }
        // Control: without the meter change beat 16 is 16 mod 3 = step 1.
        #expect(abs(try Self.value(params, atBeat: 16, tempo: tempo)) < 1e-9)
    }

    @Test("ModDescribe T2: the 2 ms edge TRAILS the step boundary — exact at the boundary, a ramp just before it")
    func syncedEdgeTrailsTheBoundary() throws {
        let tempo = TempoMap(constantBPM: 90)
        let params = Self.synced([1, 0], "1/16", edgeMs: 2)
        // 2 ms at 90 BPM = 0.003 beats; the ramp is [0.25 − 0.003, 0.25).
        let inRamp = try Self.value(params, atBeat: 0.2485, tempo: tempo)
        let before = try Self.value(params, atBeat: 0.2465, tempo: tempo)
        #expect(inRamp > 0.01 && inRamp < 0.99, "mid-ramp, got \(inRamp)")
        #expect(abs(before - 1) < 1e-9)
        let hard = Self.synced([1, 0], "1/16", edgeMs: 0)
        #expect(try Self.value(hard, atBeat: 0.2485, tempo: tempo) == 1, "no edge: no ramp")
    }

    // MARK: - T3: value(of:) declares the synced source, like the follower

    @Test("ModDescribe T3: value(of:atSample:) returns nil for a SYNCED step source — a forgotten caller shows null, not a rateHz number")
    func sampleBasedValueDeclinesASyncedSource() throws {
        let synced = ModulationSourceParams.stepSequencer(Self.synced([1, 0], "1/16"))
        #expect(ModulationMath.value(of: synced, atSample: 8_000, sampleRate: Self.rate) == nil)
        for division in NoteDivision.allCases {
            let params = ModulationSourceParams.stepSequencer(
                StepSequencerSourceParams(steps: [1, 0], stepDivision: division.rawValue))
            #expect(ModulationMath.value(of: params, atSample: 1_234, sampleRate: Self.rate) == nil,
                    "\(division.rawValue)")
        }
        // Controls: the same steps unsynced, and a garbage division the render
        // runs free (only a recognised NoteDivision syncs), keep their number.
        let free = ModulationSourceParams.stepSequencer(StepSequencerSourceParams(steps: [1, 0], rateHz: 4))
        #expect(ModulationMath.value(of: free, atSample: 8_000, sampleRate: Self.rate) == 1)
        let garbage = ModulationSourceParams.stepSequencer(
            StepSequencerSourceParams(steps: [1, 0], stepDivision: "1/17", rateHz: 4))
        #expect(ModulationMath.value(of: garbage, atSample: 8_000, sampleRate: Self.rate) == 1)
        let garbageParams = StepSequencerSourceParams(steps: [1, 0], stepDivision: "1/17", rateHz: 4)
        #expect(ModulationMath.syncedStepValue(garbageParams, atBeat: 0.25, tempoMap: TempoMap(constantBPM: 90),
                                               meterMap: MeterMap(constant: TimeSignature()),
                                               sampleRate: Self.rate) == nil)
    }
}
