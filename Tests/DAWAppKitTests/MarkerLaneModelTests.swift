import CoreGraphics
import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the arrange marker-lane model (m11-c). The SwiftUI marker
/// lane is thin over this — it maps a marker to its flag x, hit-tests a press to a
/// marker, snaps a drag to a new beat, and snaps an "add here" point — so the
/// geometry + edit math is exercised here without a display (the `LoopRulerModel`
/// test-suite style).
@Suite("MarkerLaneModel — marker mouse surface (m11-c)")
struct MarkerLaneModelTests {
    private let geometry = MarkerLaneGeometry()   // 16 px/beat, 16 pt grab

    /// Trivial single-meter map (m13-h) — the byte-equivalence anchor.
    private func meter(_ bpb: Int = 4) -> MeterMap {
        MeterMap(constant: TimeSignature(beatsPerBar: bpb))
    }

    /// 4/4 → 6/8 @ beat 16 (bpb 6): barlines …12,16,22,28…
    private func crossMeter() -> MeterMap {
        try! MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 6, beatUnit: 8),
        ])
    }

    /// The legacy base-meter snap formula, inline.
    private func legacySnap(_ snap: ClipSnap, _ beat: Double, _ bpb: Int) -> Double {
        let grid: Double?
        switch snap {
        case .off: grid = nil
        case .bar: grid = Double(max(1, bpb))
        case .beat: grid = 1
        case .half: grid = 0.5
        case .quarter: grid = 0.25
        case .eighth: grid = 0.125
        case .sixteenth: grid = 0.0625
        }
        guard let g = grid, g > 0 else { return max(0, beat) }
        return max(0, (beat / g).rounded() * g)
    }

    @Test("beat↔x round-trip at the timeline scale, x floored at 0")
    func beatXMapping() {
        #expect(geometry.x(forBeat: 4) == 64)
        #expect(geometry.beat(forX: 64) == 4)
        #expect(geometry.beat(forX: -20) == 0)   // floored
    }

    @Test("markerID(atContentX:) grabs the nearest flag within half the grab width")
    func hitTest() {
        let a = Marker(name: "A", beat: 4)   // x = 64
        let b = Marker(name: "B", beat: 8)   // x = 128
        let markers = [a, b]
        // Right on A's anchor → A.
        #expect(geometry.markerID(atContentX: 64, markers: markers) == a.id)
        // Within half the grab strip (8 pt) of A → A.
        #expect(geometry.markerID(atContentX: 70, markers: markers) == a.id)
        // Between the two, outside either grab strip → nil.
        #expect(geometry.markerID(atContentX: 96, markers: markers) == nil)
        // Near B → B.
        #expect(geometry.markerID(atContentX: 132, markers: markers) == b.id)
    }

    @Test("markerID: the NEAREST flag wins when two overlap")
    func hitTestNearestWins() {
        let a = Marker(name: "A", beat: 4)     // x = 64
        let b = Marker(name: "B", beat: 4.3)   // x = 68.8 — overlapping grab strips
        // x = 67 is closer to A (3) than B (1.8)? A: |67-64|=3, B: |67-68.8|=1.8 → B.
        #expect(geometry.markerID(atContentX: 67, markers: [a, b]) == b.id)
        // x = 65 → A (1) vs B (3.8) → A.
        #expect(geometry.markerID(atContentX: 65, markers: [a, b]) == a.id)
    }

    @Test("movedBeat snaps to the grid and clamps at 0")
    func movedBeatSnapClamp() {
        // Bar snap in 4/4 (bars at 0,4,8,12…): origin 8, +2.1 → 10.1 snaps UP to 12.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 2.1, snap: .bar, meterMap: meter()) == 12)
        // Bar snap: origin 8, +1.5 → 9.5 snaps DOWN to 8.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 1.5, snap: .bar, meterMap: meter()) == 8)
        // Beat snap: origin 8, +3.4 → 11.4 snaps to 11.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 3.4, snap: .beat, meterMap: meter()) == 11)
        // A big leftward drag past 0 clamps to 0.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 4, dragDeltaBeats: -100, snap: .beat, meterMap: meter()) == 0)
    }

    @Test("movedBeat with snap off passes through (still floored at 0)")
    func movedBeatSnapOff() {
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 1.7, snap: .off, meterMap: meter()) == 9.7)
        #expect(MarkerLaneEdit.movedBeat(originBeat: 1, dragDeltaBeats: -5, snap: .off, meterMap: meter()) == 0)
    }

    @Test("addBeat snaps the pointer x to the grid")
    func addBeatSnaps() {
        // x = 70 → beat 4.375; Bar snap (4/4) → 4.
        #expect(MarkerLaneEdit.addBeat(atContentX: 70, geometry: geometry, snap: .bar, meterMap: meter()) == 4)
        // x = 70 → 4.375; Beat snap → 4.
        #expect(MarkerLaneEdit.addBeat(atContentX: 70, geometry: geometry, snap: .beat, meterMap: meter()) == 4)
        // Bar snap respects the meter (3/4): x = 100 → 6.25 → nearest 3-beat bar = 6.
        #expect(MarkerLaneEdit.addBeat(atContentX: 100, geometry: geometry, snap: .bar, meterMap: meter(3)) == 6)
    }

    // MARK: - Meter-aware snap (m13-h)

    @Test("marker drag/place .bar snap routes through nearestBarline on both sides of a meter change")
    func markerBarSnapCrossBoundary() {
        let m = crossMeter()   // barlines …12,16,22,28…
        // DRAG a marker from 12 (4/4) into 6/8: +9 → raw 21 → nearest of {16,22} = 22.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 12, dragDeltaBeats: 9, snap: .bar, meterMap: m) == 22)
        // DRAG just left of the boundary: origin 12, +3 → raw 15 → 16 (shared barline).
        #expect(MarkerLaneEdit.movedBeat(originBeat: 12, dragDeltaBeats: 3, snap: .bar, meterMap: m) == 16)
        // PLACE ("add here") deep in 6/8: x for beat 20 → 6/8 barline 22.
        #expect(MarkerLaneEdit.addBeat(atContentX: geometry.x(forBeat: 20),
                                       geometry: geometry, snap: .bar, meterMap: m) == 22)
        // PLACE just right of the boundary: x for beat 17 → 16.
        #expect(MarkerLaneEdit.addBeat(atContentX: geometry.x(forBeat: 17),
                                       geometry: geometry, snap: .bar, meterMap: m) == 16)
        // A finer grid in the 6/8 region stays on its fixed grid.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 16, dragDeltaBeats: 4.6, snap: .beat, meterMap: m) == 21)
    }

    @Test("trivial single-meter map reproduces the legacy snap for marker move/place")
    func markerTrivialMapMatchesLegacy() {
        for bpb in [3, 4, 5, 6, 7] {
            let m = meter(bpb)
            var beat = 0.0
            while beat <= 40 {
                for snap in ClipSnap.allCases {
                    let expected = legacySnap(snap, beat, bpb)
                    #expect(MarkerLaneEdit.movedBeat(originBeat: 0, dragDeltaBeats: beat,
                                                     snap: snap, meterMap: m) == expected,
                            "marker move bpb=\(bpb) snap=\(snap) beat=\(beat)")
                }
                beat += 0.1
            }
        }
    }
}
