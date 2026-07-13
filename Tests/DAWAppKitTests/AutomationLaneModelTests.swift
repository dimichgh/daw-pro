import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless automation-lane geometry, edit ops, param
/// formatting, and selection logic. The arrange lane editor view is thin over
/// these, so exercising them here covers the editor's logic without a display.
@Suite("AutomationLaneModel")
struct AutomationLaneModelTests {

    /// A volume geometry (range 0…2) at the timeline's 16 pt/beat, 64 pt lane.
    private func volumeGeometry() -> AutomationGeometry {
        AutomationGeometry(range: Track.volumeRange)
    }

    private func panGeometry() -> AutomationGeometry {
        AutomationGeometry(range: Track.panRange)
    }

    // MARK: - Param

    @Test("param maps to target, range, and neutral value")
    func paramTargetsAndRanges() {
        #expect(AutomationParam.volume.target == .volume)
        #expect(AutomationParam.pan.target == .pan)
        #expect(AutomationParam.volume.range == Track.volumeRange)
        #expect(AutomationParam.pan.range == Track.panRange)
        #expect(AutomationParam.volume.neutralValue == 1)
        #expect(AutomationParam.pan.neutralValue == 0)
    }

    @Test("param init from target covers v0 cases and rejects deferred targets")
    func paramFromTarget() {
        #expect(AutomationParam(target: .volume) == .volume)
        #expect(AutomationParam(target: .pan) == .pan)
        #expect(AutomationParam(target: .sendLevel(sendID: UUID())) == nil)
        #expect(AutomationParam(target: .effectParam(effectID: UUID(), paramName: "x")) == nil)
    }

    @Test("param readout formats volume as dB and pan as L/C/R")
    func paramReadout() {
        #expect(AutomationParam.volume.readout(1.0) == "0.0 dB")
        #expect(AutomationParam.volume.readout(2.0) == "+6.0 dB")
        #expect(AutomationParam.volume.readout(0.5) == "-6.0 dB")
        #expect(AutomationParam.volume.readout(0.0) == "-∞ dB")
        #expect(AutomationParam.pan.readout(0) == "C")
        #expect(AutomationParam.pan.readout(-1) == "L100")
        #expect(AutomationParam.pan.readout(1) == "R100")
        #expect(AutomationParam.pan.readout(0.5) == "R50")
    }

    // MARK: - Geometry: beats

    @Test("beat<->x round-trips at the fixed scale and floors at 0")
    func beatXRoundTrip() {
        let g = volumeGeometry()
        #expect(g.x(forBeat: 3.5) == 3.5 * g.pixelsPerBeat)
        for beat in [0.0, 1.0, 2.25, 3.5, 16.0] {
            #expect(abs(g.beat(forX: g.x(forBeat: beat)) - beat) < 1e-9)
        }
        // Negative x floors to beat 0.
        #expect(g.beat(forX: -40) == 0)
    }

    // MARK: - Geometry: value

    @Test("value maps to y with range max at the top inset, min at the bottom")
    func valueToYEndpoints() {
        let g = volumeGeometry()
        // Range max (2.0) sits at the top inset; range min (0.0) at the bottom.
        #expect(abs(g.y(forValue: 2.0) - g.verticalInset) < 1e-9)
        #expect(abs(g.y(forValue: 0.0) - (g.laneHeight - g.verticalInset)) < 1e-9)
        // Unity (1.0) sits at the vertical center.
        #expect(abs(g.y(forValue: 1.0) - g.laneHeight / 2) < 1e-9)
    }

    @Test("value<->y round-trips inside the usable band")
    func valueYRoundTrip() {
        let g = volumeGeometry()
        for value in [0.0, 0.25, 1.0, 1.5, 2.0] {
            let back = g.value(forY: g.y(forValue: value))
            #expect(abs(back - value) < 1e-9)
        }
    }

    @Test("value clamps to the target range beyond the lane bounds")
    func valueClampsToRange() {
        let g = panGeometry()
        // Above the top inset clamps to the range max; below clamps to min.
        #expect(g.value(forY: -100) == 1)
        #expect(g.value(forY: g.laneHeight + 100) == -1)
        // Center of the lane is pan 0.
        #expect(abs(g.value(forY: g.laneHeight / 2)) < 1e-9)
    }

    // MARK: - Hit testing

    @Test("hitTest finds the nearest breakpoint within the grab radius")
    func hitTestNearest() {
        let g = volumeGeometry()
        let points = [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 4, value: 2),
            AutomationPoint(beat: 8, value: 0),
        ]
        // Directly on the beat-4 point.
        let p1 = g.point(for: points[1])
        #expect(g.hitTest(p1, points: points) == 1)
        // A couple points away from beat-4 still grabs it.
        #expect(g.hitTest(CGPoint(x: p1.x + 3, y: p1.y - 3), points: points) == 1)
        // Empty space (far from all points) grabs nothing.
        #expect(g.hitTest(CGPoint(x: p1.x + 100, y: p1.y), points: points) == nil)
    }

    @Test("hitTest just outside the radius misses")
    func hitTestMisses() {
        let g = volumeGeometry()
        let points = [AutomationPoint(beat: 4, value: 1)]
        let p = g.point(for: points[0])
        // Just beyond hitRadius horizontally.
        #expect(g.hitTest(CGPoint(x: p.x + g.hitRadius + 2, y: p.y), points: points) == nil)
    }

    // MARK: - Edit ops

    @Test("addPoint appends a clamped point at the end, beat floored")
    func addPointClamps() {
        let start = [AutomationPoint(beat: 0, value: 1)]
        // Over-range value clamps to 2; negative beat floors to 0.
        let out = AutomationEdit.addPoint(start, atBeat: -3, value: 5, in: Track.volumeRange)
        #expect(out.count == 2)
        #expect(out.last?.beat == 0)
        #expect(out.last?.value == 2)
    }

    @Test("movePoint updates one point in place, clamped, keeping curve")
    func movePointClamps() {
        let start = [
            AutomationPoint(beat: 0, value: 1, curve: .hold),
            AutomationPoint(beat: 4, value: 1),
        ]
        let out = AutomationEdit.movePoint(start, index: 0, toBeat: 2, value: -1, in: Track.volumeRange)
        #expect(out[0].beat == 2)
        #expect(out[0].value == 0)          // clamped to range min
        #expect(out[0].curve == .hold)      // curve preserved
        #expect(out[1] == start[1])         // other point untouched
        // Order is NOT re-sorted here (stable index through a drag).
        #expect(out.count == 2)
    }

    @Test("movePoint out of range is a no-op")
    func movePointOutOfRange() {
        let start = [AutomationPoint(beat: 0, value: 1)]
        #expect(AutomationEdit.movePoint(start, index: 5, toBeat: 1, value: 1, in: Track.volumeRange) == start)
    }

    @Test("removePoint drops one index, out-of-range is a no-op")
    func removePoint() {
        let start = [
            AutomationPoint(beat: 0, value: 1),
            AutomationPoint(beat: 4, value: 2),
        ]
        let out = AutomationEdit.removePoint(start, index: 0)
        #expect(out.count == 1)
        #expect(out[0].beat == 4)
        #expect(AutomationEdit.removePoint(start, index: 9) == start)
    }

    // MARK: - Selection

    @Test("selectedLane prefers the explicit selection, falls back to first")
    func selectedLane() {
        let volume = AutomationLane(target: .volume)
        let pan = AutomationLane(target: .pan)
        var track = Track(name: "T", kind: .audio)
        track.automation = [volume, pan]
        // Explicit selection wins.
        #expect(AutomationLaneSelection.selectedLane(in: track, selection: pan.id)?.id == pan.id)
        // A stale selection falls back to the first lane.
        #expect(AutomationLaneSelection.selectedLane(in: track, selection: UUID())?.id == volume.id)
        // No selection → first lane.
        #expect(AutomationLaneSelection.selectedLane(in: track, selection: nil)?.id == volume.id)
    }

    @Test("lane(for:) finds the lane matching a v0 param")
    func laneForParam() {
        let pan = AutomationLane(target: .pan)
        var track = Track(name: "T", kind: .audio)
        track.automation = [pan]
        #expect(AutomationLaneSelection.lane(for: .pan, in: track)?.id == pan.id)
        #expect(AutomationLaneSelection.lane(for: .volume, in: track) == nil)
    }

    @Test("hasActiveLane is true only for an enabled, non-empty lane")
    func hasActiveLane() {
        var track = Track(name: "T", kind: .audio)
        // Empty lane → not active.
        track.automation = [AutomationLane(target: .volume, points: [], isEnabled: true)]
        #expect(!AutomationLaneSelection.hasActiveLane(track))
        // Disabled with points → not active.
        track.automation = [AutomationLane(
            target: .volume, points: [AutomationPoint(beat: 0, value: 1)], isEnabled: false)]
        #expect(!AutomationLaneSelection.hasActiveLane(track))
        // Enabled with points → active.
        track.automation = [AutomationLane(
            target: .volume, points: [AutomationPoint(beat: 0, value: 1)], isEnabled: true)]
        #expect(AutomationLaneSelection.hasActiveLane(track))
    }

    // MARK: - Master volume automation (m15-c)

    @Test("masterVolumeLane finds the volume lane in a master-automation array, else nil")
    func masterVolumeLaneLookup() {
        let volume = AutomationLane(target: .volume)
        // No lanes → nil (the strip shows its create button).
        #expect(AutomationLaneSelection.masterVolumeLane(in: []) == nil)
        // The volume lane is found regardless of position.
        #expect(AutomationLaneSelection.masterVolumeLane(in: [volume])?.id == volume.id)
    }

    @Test("hasActiveMasterLane glows only for an enabled, non-empty volume lane")
    func hasActiveMasterLane() {
        // Empty lane → inert, no glow.
        #expect(!AutomationLaneSelection.hasActiveMasterLane(
            [AutomationLane(target: .volume, points: [], isEnabled: true)]))
        // Disabled with points → no glow.
        #expect(!AutomationLaneSelection.hasActiveMasterLane(
            [AutomationLane(target: .volume, points: [AutomationPoint(beat: 0, value: 1)], isEnabled: false)]))
        // Enabled with points → active glow.
        #expect(AutomationLaneSelection.hasActiveMasterLane(
            [AutomationLane(target: .volume, points: [AutomationPoint(beat: 0, value: 1)], isEnabled: true)]))
    }

    /// UI == wire (the m11-a / m13-g equivalence idiom): the master-strip editor
    /// builds its breakpoint array through the SAME `AutomationEdit` primitives the
    /// `AutomationLaneEditor` commits, then submits it through the SAME store method
    /// the `automation.setPoints {trackId:"master"}` wire verb calls. So an
    /// unsorted editor draft must canonicalize to the byte-identical master lane an
    /// agent's already-ordered array produces.
    @Test("master lane: the editor's AutomationEdit draft lands byte-identical to the wire's array")
    @MainActor
    func masterAutomationUIEqualsWire() throws {
        let range = AutomationParam.volume.range

        // UI editor path: two breakpoints APPENDED out of order (the editor adds to
        // the draft's end and lets the store canonicalize), then a drag on the first.
        var draft = AutomationEdit.addPoint([], atBeat: 16, value: 1.0, in: range)
        draft = AutomationEdit.addPoint(draft, atBeat: 0, value: 1.0, in: range)     // [{16,1},{0,1}] — unsorted
        draft = AutomationEdit.movePoint(draft, index: 0, toBeat: 16, value: 0.0, in: range) // end point → 0.0

        // The wire's equivalent: an agent's already-ordered fade-out array.
        let wireArray = [
            AutomationPoint(beat: 0, value: 1.0),
            AutomationPoint(beat: 16, value: 0.0),
        ]

        let store = ProjectStore()
        let lane = try store.addMasterAutomationLane(target: .volume)

        func encodedMaster() throws -> Data {
            let enc = JSONEncoder()
            enc.outputFormatting = [.sortedKeys]
            return try enc.encode(store.masterAutomation)
        }

        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: draft)
        let uiJSON = try encodedMaster()

        _ = try store.setMasterAutomationPoints(laneID: lane.id, points: wireArray)
        let wireJSON = try encodedMaster()

        // Same store + same lane id: the JSON is byte-identical iff the two arrays
        // canonicalize to the same curve — the equivalence.
        #expect(uiJSON == wireJSON)
        #expect(store.masterAutomation.first?.points == wireArray)
    }
}
