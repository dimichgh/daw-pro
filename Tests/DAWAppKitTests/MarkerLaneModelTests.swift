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
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 2.1, snap: .bar, beatsPerBar: 4) == 12)
        // Bar snap: origin 8, +1.5 → 9.5 snaps DOWN to 8.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 1.5, snap: .bar, beatsPerBar: 4) == 8)
        // Beat snap: origin 8, +3.4 → 11.4 snaps to 11.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 3.4, snap: .beat, beatsPerBar: 4) == 11)
        // A big leftward drag past 0 clamps to 0.
        #expect(MarkerLaneEdit.movedBeat(originBeat: 4, dragDeltaBeats: -100, snap: .beat, beatsPerBar: 4) == 0)
    }

    @Test("movedBeat with snap off passes through (still floored at 0)")
    func movedBeatSnapOff() {
        #expect(MarkerLaneEdit.movedBeat(originBeat: 8, dragDeltaBeats: 1.7, snap: .off, beatsPerBar: 4) == 9.7)
        #expect(MarkerLaneEdit.movedBeat(originBeat: 1, dragDeltaBeats: -5, snap: .off, beatsPerBar: 4) == 0)
    }

    @Test("addBeat snaps the pointer x to the grid")
    func addBeatSnaps() {
        // x = 70 → beat 4.375; Bar snap (4/4) → 4.
        #expect(MarkerLaneEdit.addBeat(atContentX: 70, geometry: geometry, snap: .bar, beatsPerBar: 4) == 4)
        // x = 70 → 4.375; Beat snap → 4.
        #expect(MarkerLaneEdit.addBeat(atContentX: 70, geometry: geometry, snap: .beat, beatsPerBar: 4) == 4)
        // Bar snap respects the meter (3/4): x = 100 → 6.25 → nearest 3-beat bar = 6.
        #expect(MarkerLaneEdit.addBeat(atContentX: 100, geometry: geometry, snap: .bar, beatsPerBar: 3) == 6)
    }
}
