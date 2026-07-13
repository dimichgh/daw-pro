import Foundation
import Testing
@testable import DAWCore

/// m12-d Phase D (Gate A) — the METER CONSUMERS: bar numbering across a 7/8→4/4
/// change (the exact case the roadmap item pins), barline snap positions
/// (`nearestBarline` — the meter-aware bar snap the arrange surfaces + tempo lane
/// route through), and the `barsBeatsDisplay` readout formatting under a
/// non-trivial meter map. All headless (design §3.2, rows 2/62–67/70).
@Suite("Meter consumers (m12-d Phase D)")
struct MeterMapConsumerTests {

    /// 7/8 for two bars (beats 0…13), then 4/4 from beat 14. The change at beat 14
    /// is 14/7 = 2 whole bars past beat 0 → a valid barline of the 7/8 meter.
    private func sevenEightThenFour() throws -> MeterMap {
        try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 7, beatUnit: 8),
            .init(startBeat: 14, beatsPerBar: 4, beatUnit: 4),
        ])
    }

    // MARK: - Bar numbering EXACT across the change

    @Test("bar numbering is exact across a 7/8 → 4/4 change (== on bar indices)")
    func barNumberingAcrossChange() throws {
        let map = try sevenEightThenFour()
        // 7/8 region: bars every 7 beats.
        #expect(map.barBeat(atBeat: 0).bar == 0)
        #expect(map.barBeat(atBeat: 6.9).bar == 0)
        #expect(map.barBeat(atBeat: 7).bar == 1)
        #expect(map.barBeat(atBeat: 13.9).bar == 1)
        // 4/4 region from beat 14: bars every 4 beats, numbering CONTINUES.
        #expect(map.barBeat(atBeat: 14).bar == 2)
        #expect(map.barBeat(atBeat: 17.9).bar == 2)
        #expect(map.barBeat(atBeat: 18).bar == 3)
        #expect(map.barBeat(atBeat: 22).bar == 4)

        // Beat-within-bar is exact on both sides of the change.
        #expect(map.barBeat(atBeat: 10) == (bar: 1, beatInBar: 3.0))    // 7/8 bar 1, beat 4
        #expect(map.barBeat(atBeat: 16) == (bar: 2, beatInBar: 2.0))    // 4/4 bar 2, beat 3
    }

    @Test("1-based ruler bar LABELS across the change are exact")
    func rulerBarLabels() throws {
        let map = try sevenEightThenFour()
        // The ruler draws `bar + 1` at every barline (beatInBar == 0).
        let labelsAtBarlines: [(beat: Double, label: Int)] = [
            (0, 1), (7, 2), (14, 3), (18, 4), (22, 5),
        ]
        for (beat, label) in labelsAtBarlines {
            let position = map.barBeat(atBeat: beat)
            #expect(position.beatInBar < 0.001, "beat \(beat) must be a barline")
            #expect(position.bar + 1 == label)
        }
    }

    @Test("beat(ofBar:) is the exact inverse of the labels")
    func beatOfBarInverse() throws {
        let map = try sevenEightThenFour()
        #expect(map.beat(ofBar: 0) == 0)
        #expect(map.beat(ofBar: 1) == 7)
        #expect(map.beat(ofBar: 2) == 14)     // the change barline
        #expect(map.beat(ofBar: 3) == 18)
        #expect(map.beat(ofBar: 4) == 22)
    }

    // MARK: - Barline snap positions (nearestBarline)

    @Test("nearestBarline snaps to the correct (non-uniform) barline")
    func nearestBarlineNonUniform() throws {
        let map = try sevenEightThenFour()
        // Within the 7/8 region (bars at 0, 7, 14).
        #expect(map.nearestBarline(toBeat: 3) == 0)      // 3<4 → bar 0
        #expect(map.nearestBarline(toBeat: 4) == 7)      // tie-up rule → 7
        #expect(map.nearestBarline(toBeat: 6) == 7)
        // Across into the 4/4 region (bars at 14, 18, 22).
        #expect(map.nearestBarline(toBeat: 15) == 14)
        #expect(map.nearestBarline(toBeat: 16.5) == 18)  // 2.5 vs 1.5 → 18
        #expect(map.nearestBarline(toBeat: 20) == 22)    // 2 vs 2 → tie-up → 22
        #expect(map.nearestBarline(toBeat: -5) == 0)     // clamps ≥ 0
    }

    @Test("nearestBarline reproduces the legacy uniform bar snap for a trivial 4/4 map")
    func nearestBarlineTrivialMatchesLegacy() {
        let map = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))
        // The legacy ClipSnap `.bar` snap is (beat/4).rounded()*4 — assert parity.
        for beat in stride(from: 0.0, through: 32.0, by: 0.37) {
            let legacy = (beat / 4).rounded() * 4
            #expect(map.nearestBarline(toBeat: beat) == legacy, "mismatch at \(beat)")
        }
    }

    // MARK: - bars.beats readout formatting under a meter map

    @Test("barsBeatsDisplay formats 1-based bar.beat across a meter change")
    func barsBeatsDisplayAcrossChange() throws {
        var transport = TransportState()
        transport.meterMapOverride = try sevenEightThenFour()
        // 7/8 region.
        transport.positionBeats = 0;  #expect(transport.barsBeatsDisplay == "1.1")
        transport.positionBeats = 7;  #expect(transport.barsBeatsDisplay == "2.1")
        transport.positionBeats = 10; #expect(transport.barsBeatsDisplay == "2.4")
        // 4/4 region (numbering continues).
        transport.positionBeats = 14; #expect(transport.barsBeatsDisplay == "3.1")
        transport.positionBeats = 17; #expect(transport.barsBeatsDisplay == "3.4")
        transport.positionBeats = 18; #expect(transport.barsBeatsDisplay == "4.1")
    }

    @Test("barsBeatsDisplay is unchanged for a trivial 4/4 project (no regression)")
    func barsBeatsDisplayTrivial() {
        var transport = TransportState()   // 4/4, no override
        transport.positionBeats = 5        // bar 2 (0-based bar 1), beat 2
        #expect(transport.barsBeatsDisplay == "2.2")
    }
}
