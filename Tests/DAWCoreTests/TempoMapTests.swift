import Foundation
import Testing
@testable import DAWCore

/// m12-b Phase A — the TempoMap/MeterMap contract (design §3.1/§3.2).
/// Multi-segment maps are exercised HERE ONLY: the app itself builds nothing
/// but trivial single-segment maps until Phase C.
@Suite("TempoMap")
struct TempoMapTests {

    // MARK: - Trivial-map equivalence (the Phase-A byte contract)

    @Test("trivial map reproduces the scalar formulas EXACTLY (bit-for-bit)")
    func trivialMapMatchesScalarFormulas() {
        for bpm in [20.0, 60.0, 97.3, 120.0, 128.0, 140.0, 400.0] {
            let map = TempoMap(constantBPM: bpm)
            for beat in [0.0, 0.25, 1.0, 3.9, 7.5, 14.0, 16.001, 1000.0] {
                // Forward: the spb idiom, div-first.
                #expect(map.seconds(fromBeatZeroTo: beat) == beat * (60.0 / bpm))
                #expect(map.seconds(from: 2.5, to: beat) == (beat - 2.5) * (60.0 / bpm))
                // Inverse: the derivedBeats shape, mul-first.
                for s in [0.0, 0.033, 1.5, 60.0] {
                    #expect(map.beat(from: beat, elapsedSeconds: s)
                            == beat + s * bpm / 60.0)
                    #expect(map.beat(atSecondsFromZero: s) == s * bpm / 60.0)
                }
                #expect(map.bpm(atBeat: beat) == bpm)
                #expect(map.secondsPerBeat(atBeat: beat) == 60.0 / bpm)
            }
        }
    }

    @Test("the TransportState seam synthesizes the trivial map from tempoBPM")
    func transportSeam() {
        let transport = TransportState(tempoBPM: 97.3)
        #expect(transport.tempoMap == TempoMap(constantBPM: 97.3))
        #expect(transport.tempoMap.segments.count == 1)
        #expect(transport.tempoMap.segments[0].startBeat == 0)
        #expect(transport.meterMap == MeterMap(constant: transport.timeSignature))
        // positionSeconds routes through the map (row 1).
        var moved = transport
        moved.positionBeats = 8
        #expect(moved.positionSeconds == 8 * (60.0 / 97.3))
    }

    // MARK: - Integral / inverse round-trip (randomized multi-segment)

    @Test("beat(atSeconds:seconds(toBeat:)) round-trips to 1e-12 over random maps")
    func roundTripProperty() throws {
        var rng = SplitMix64(seed: 0xDAD5_BEA7)
        for _ in 0..<200 {
            let segmentCount = Int(rng.next() % 6) + 1
            var segments: [TempoMap.Segment] = [
                .init(startBeat: 0, bpm: 20 + Double(rng.next() % 3801) / 10)
            ]
            var beatCursor = 0.0
            for _ in 1..<segmentCount {
                beatCursor += 0.25 + Double(rng.next() % 640) / 16      // strictly increasing
                segments.append(.init(startBeat: beatCursor,
                                      bpm: 20 + Double(rng.next() % 3801) / 10))
            }
            let map = try TempoMap(segments: segments)
            for _ in 0..<20 {
                let beat = Double(rng.next() % 200_000) / 1000          // 0 ... 200 beats
                let s = map.seconds(fromBeatZeroTo: beat)
                let back = map.beat(atSecondsFromZero: s)
                #expect(abs(back - beat) <= 1e-12,
                        "round trip \(beat) -> \(s) -> \(back) under \(segments)")
            }
            // The relative form round-trips too (anchored mid-timeline).
            for _ in 0..<10 {
                let anchor = Double(rng.next() % 100_000) / 1000
                let dt = Double(rng.next() % 60_000) / 1000 - 30        // signed
                let landed = map.beat(from: anchor, elapsedSeconds: dt)
                if landed >= 0 {
                    let recovered = map.seconds(from: anchor, to: landed)
                    #expect(abs(recovered - dt) <= 1e-9,
                            "elapsed \(dt) -> beat \(landed) -> \(recovered)")
                }
            }
        }
    }

    @Test("multi-segment integral is the exact piecewise sum")
    func multiSegmentIntegral() throws {
        // 120 for 4 beats (2.0 s), then 60 for 4 beats (4.0 s), then 240.
        let map = try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120),
            .init(startBeat: 4, bpm: 60),
            .init(startBeat: 8, bpm: 240),
        ])
        #expect(map.seconds(fromBeatZeroTo: 4) == 2.0)
        #expect(map.seconds(fromBeatZeroTo: 8) == 6.0)
        #expect(map.seconds(fromBeatZeroTo: 10) == 6.5)
        #expect(map.seconds(from: 2, to: 6) == 1.0 + 2.0)
        // Signed span reverses sign exactly.
        #expect(map.seconds(from: 6, to: 2) == -3.0)
        // Inverse walks the same boundaries.
        #expect(map.beat(atSecondsFromZero: 2.0) == 4.0)
        #expect(map.beat(atSecondsFromZero: 6.0) == 8.0)
        #expect(map.beat(atSecondsFromZero: 6.5) == 10.0)
        #expect(map.beat(from: 2, elapsedSeconds: 3.0) == 6.0)   // crosses 120→60
        // bpm lookup is right-continuous: the change AT 4 governs [4, 8).
        #expect(map.bpm(atBeat: 4) == 60)
        #expect(map.bpm(atBeat: 3.999) == 120)
        #expect(map.bpm(atBeat: -1) == 120)                      // segment 0 extrapolates
    }

    // MARK: - Mutation invariants

    @Test("segment validation: empty, first-not-zero, unsorted, duplicate")
    func segmentValidation() {
        #expect(throws: TempoMap.ValidationError.emptySegments) {
            try TempoMap(segments: [])
        }
        #expect(throws: TempoMap.ValidationError.firstSegmentNotAtZero(startBeat: 1)) {
            try TempoMap(segments: [.init(startBeat: 1, bpm: 120)])
        }
        #expect(throws: TempoMap.ValidationError.unsortedOrDuplicateStartBeat(index: 2)) {
            try TempoMap(segments: [
                .init(startBeat: 0, bpm: 120),
                .init(startBeat: 8, bpm: 90),
                .init(startBeat: 4, bpm: 100),
            ])
        }
        #expect(throws: TempoMap.ValidationError.unsortedOrDuplicateStartBeat(index: 1)) {
            try TempoMap(segments: [
                .init(startBeat: 0, bpm: 120),
                .init(startBeat: 0, bpm: 90),
            ])
        }
        // setSegments funnels through the same validation and REBUILDS prefix
        // sums (observable through the integral).
        var map = TempoMap(constantBPM: 120)
        try? map.setSegments([.init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 60)])
        #expect(map.segments.count == 2)
        #expect(map.seconds(fromBeatZeroTo: 8) == 6.0)
        #expect(throws: TempoMap.ValidationError.self) {
            try map.setSegments([])
        }
    }

    @Test("segment bpm clamps to TransportState.tempoRange")
    func bpmClamps() {
        #expect(TempoMap.Segment(startBeat: 0, bpm: 5).bpm == 20)
        #expect(TempoMap.Segment(startBeat: 0, bpm: 9999).bpm == 400)
        #expect(TempoMap(constantBPM: 0).bpm(atBeat: 0) == 20)   // never a 0-bpm map
    }

    @Test("Codable round-trips segments and rebuilds prefix sums; Equatable is segment identity")
    func codableAndEquatable() throws {
        let map = try TempoMap(segments: [
            .init(startBeat: 0, bpm: 97.3),
            .init(startBeat: 16, bpm: 140),
        ])
        let decoded = try JSONDecoder().decode(TempoMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        #expect(decoded.seconds(fromBeatZeroTo: 20) == map.seconds(fromBeatZeroTo: 20))
        // A corrupt payload fails decoding (never a silently repaired map).
        let bad = #"{"segments":[{"startBeat":4,"bpm":120}]}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(TempoMap.self, from: bad)
        }
    }

    @Test("lookups are total: NaN and negative inputs never trap")
    func totalFunctions() throws {
        let map = try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 60),
        ])
        #expect(map.seconds(fromBeatZeroTo: -3) == -1.5)         // signed extrapolation
        #expect(map.beat(atSecondsFromZero: -1.5) == -3)
        #expect(map.bpm(atBeat: .nan) == 120)                    // NaN resolves to segment 0
        _ = map.seconds(fromBeatZeroTo: .nan)                    // no trap
        _ = map.beat(from: .nan, elapsedSeconds: 1)              // no trap
    }

    // MARK: - m12-c Phase B additions

    @Test("framesPerBeat keeps the verbatim rate*60/bpm op order (bit-for-bit)")
    func framesPerBeatOpOrder() throws {
        // The exact idiom ClipFadeBake's fast path relied on pre-m12-c
        // (`fileRate * 60.0 / bpm`): mul-first, single division. 140 BPM is
        // the documented 1-ULP witness for div-first reordering.
        for bpm in [97.3, 120.0, 140.0] {
            let map = TempoMap(constantBPM: bpm)
            #expect(map.framesPerBeat(atBeat: 0, sampleRate: 48_000) == 48_000.0 * 60.0 / bpm)
            #expect(map.framesPerBeat(atBeat: 7, sampleRate: 44_100) == 44_100.0 * 60.0 / bpm)
        }
        let two = try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 90),
        ])
        #expect(two.framesPerBeat(atBeat: 3.9, sampleRate: 48_000) == 48_000.0 * 60.0 / 120.0)
        #expect(two.framesPerBeat(atBeat: 4.0, sampleRate: 48_000) == 48_000.0 * 60.0 / 90.0)
    }

    @Test("isConstant: single-segment spans true, boundary-crossing/ending spans false")
    func isConstantSpans() throws {
        let trivial = TempoMap(constantBPM: 120)
        #expect(trivial.isConstant(from: 0, to: 1_000))
        let two = try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120), .init(startBeat: 4, bpm: 90),
        ])
        #expect(two.isConstant(from: 0, to: 3.999))
        #expect(two.isConstant(from: 4.0, to: 100))
        #expect(!two.isConstant(from: 3.9, to: 4.1))
        // A span ENDING exactly on the boundary reports false by convention
        // (right-continuous segments) — callers take the piecewise path,
        // which yields the same integral values.
        #expect(!two.isConstant(from: 3.0, to: 4.0))
        // Either argument order (the doc contract says "either order").
        #expect(!two.isConstant(from: 4.1, to: 3.9))
        #expect(two.isConstant(from: 3.5, to: 3.0))
    }
}

@Suite("MeterMap")
struct MeterMapTests {

    @Test("trivial map reproduces barsBeatsDisplay arithmetic exactly")
    func trivialBarBeat() {
        let map = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))
        for pos in [0.0, 0.5, 3.999, 4.0, 7.5, 8.0, 15.25] {
            let legacyBar = Int(pos / 4.0)
            let legacyBeat = pos.truncatingRemainder(dividingBy: 4.0)
            let got = map.barBeat(atBeat: pos)
            #expect(got.bar == legacyBar)
            #expect(got.beatInBar == legacyBeat)
        }
        #expect(map.beatsPerBar(atBeat: 100) == 4)
        #expect(map.beat(ofBar: 3) == 12)
        #expect(map.beat(ofBar: -1) == 0)                        // clamps like barBeat
    }

    @Test("meter changes are barline-constrained (field-named error otherwise)")
    func barlineValidation() throws {
        // 4/4 for 2 bars (8 beats), then 3/4 — beat 8 IS a barline.
        let map = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4),
        ])
        #expect(map.barBeat(atBeat: 7.0) == (bar: 1, beatInBar: 3.0))
        #expect(map.barBeat(atBeat: 8.0) == (bar: 2, beatInBar: 0.0))
        #expect(map.barBeat(atBeat: 12.5) == (bar: 3, beatInBar: 1.5))
        #expect(map.beatsPerBar(atBeat: 9) == 3)
        #expect(map.beat(ofBar: 2) == 8)
        #expect(map.beat(ofBar: 4) == 14)                        // 8 + 2 bars of 3
        // Beat 6 is NOT a 4/4 barline → changeOffBarline names the index.
        #expect(throws: MeterMap.ValidationError.changeOffBarline(index: 1)) {
            try MeterMap(changes: [
                .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                .init(startBeat: 6, beatsPerBar: 3, beatUnit: 4),
            ])
        }
        #expect(throws: MeterMap.ValidationError.emptyChanges) {
            try MeterMap(changes: [])
        }
        #expect(throws: MeterMap.ValidationError.firstChangeNotAtZero(startBeat: 4)) {
            try MeterMap(changes: [.init(startBeat: 4, beatsPerBar: 4, beatUnit: 4)])
        }
        #expect(throws: MeterMap.ValidationError.unsortedOrDuplicateStartBeat(index: 1)) {
            try MeterMap(changes: [
                .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                .init(startBeat: 0, beatsPerBar: 3, beatUnit: 4),
            ])
        }
    }

    @Test("Codable round-trips changes; clamps ride Change.init")
    func codableAndClamps() throws {
        #expect(MeterMap.Change(startBeat: 0, beatsPerBar: 0, beatUnit: 0).beatsPerBar == 1)
        let map = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 7, beatUnit: 8),
            .init(startBeat: 14, beatsPerBar: 4, beatUnit: 4),
        ])
        let decoded = try JSONDecoder().decode(MeterMap.self, from: JSONEncoder().encode(map))
        #expect(decoded == map)
        #expect(decoded.barBeat(atBeat: 18.0) == (bar: 3, beatInBar: 0.0))
    }
}

/// Deterministic tiny RNG for the property test (seeded, no Foundation
/// randomness — reruns are identical).
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
