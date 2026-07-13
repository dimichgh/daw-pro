import Foundation
import Testing
@testable import DAWCore
@testable import DAWAppKit

/// m12-d Phase D (Gate A snap + Gate B lane model). Meter-aware `ClipSnap`, the
/// pure `TempoLaneEdit` map math, the `TempoLaneHint` amber predicate, and the
/// `TempoLaneModel` orchestration (right-map apply, coalesced scrub = ONE undo,
/// add/remove, meter barline validation, trivial-map behavior). Headless — the
/// SwiftUI lane is thin over these (the `LoopEdit`/`QuantizeModel` precedent).
@MainActor
@Suite("Tempo lane model + meter-aware snap (m12-d Phase D)")
struct TempoLaneModelTests {

    private func multiTempo() throws -> TempoMap {
        try TempoMap(segments: [
            .init(startBeat: 0, bpm: 120),
            .init(startBeat: 8, bpm: 90),
            .init(startBeat: 16, bpm: 140),
        ])
    }

    // MARK: - Meter-aware ClipSnap (Gate A: barline snap positions)

    @Test("ClipSnap.bar routes through the meter map's non-uniform barlines")
    func barSnapMeterAware() throws {
        let meter = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 7, beatUnit: 8),
            .init(startBeat: 14, beatsPerBar: 4, beatUnit: 4),
        ])
        #expect(ClipSnap.bar.snap(beat: 3, meterMap: meter) == 0)
        #expect(ClipSnap.bar.snap(beat: 4, meterMap: meter) == 7)
        #expect(ClipSnap.bar.snap(beat: 15, meterMap: meter) == 14)
        #expect(ClipSnap.bar.snap(beat: 16.5, meterMap: meter) == 18)
    }

    @Test("finer ClipSnap grids are meter-agnostic and match the legacy math")
    func finerSnapUnchanged() {
        let meter = MeterMap(constant: TimeSignature(beatsPerBar: 3, beatUnit: 4))
        #expect(ClipSnap.beat.snap(beat: 2.4, meterMap: meter) == 2)
        #expect(ClipSnap.half.snap(beat: 2.3, meterMap: meter) == 2.5)
        #expect(ClipSnap.quarter.snap(beat: 2.1, meterMap: meter) == 2.0)
        #expect(ClipSnap.off.snap(beat: 2.37, meterMap: meter) == 2.37)
    }

    @Test("trivial 4/4 meter map reproduces snap(beat:beatsPerBar:) exactly")
    func trivialSnapParity() {
        let meter = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))
        for snap in ClipSnap.allCases {
            for beat in stride(from: 0.0, through: 20.0, by: 0.33) {
                #expect(snap.snap(beat: beat, meterMap: meter)
                        == snap.snap(beat: beat, beatsPerBar: 4), "\(snap) @ \(beat)")
            }
        }
    }

    // MARK: - TempoLaneEdit (pure map math)

    @Test("movedBoundary snaps and clamps strictly between neighbors")
    func movedBoundary() throws {
        let map = try multiTempo()   // boundaries at 8 and 16
        // Drag segment 1's boundary to 12 (snaps to bar 12 in 4/4).
        let meter = MeterMap(constant: TimeSignature())
        let moved = TempoLaneEdit.movedBoundary(map: map, index: 1, toBeat: 11.6, snap: .bar, meterMap: meter)
        #expect(moved.segments[1].startBeat == 12)
        #expect(moved.segments[1].bpm == 90)          // bpm preserved
        // Dragging past the next boundary (16) clamps to below it.
        let clamped = TempoLaneEdit.movedBoundary(map: map, index: 1, toBeat: 40, snap: .off, meterMap: meter)
        #expect(clamped.segments[1].startBeat < 16)
        #expect(clamped.segments[1].startBeat >= 15.7)   // 16 - minSegmentBeats
        // Segment 0's boundary is fixed.
        #expect(TempoLaneEdit.movedBoundary(map: map, index: 0, toBeat: 4, snap: .off, meterMap: meter) == map)
    }

    @Test("scrubbedBPM sets the segment bpm (clamped to the transport range)")
    func scrubbedBPM() throws {
        let map = try multiTempo()
        #expect(TempoLaneEdit.scrubbedBPM(map: map, index: 1, toBPM: 100).segments[1].bpm == 100)
        // Above the range clamps to 400; below to 20 (Segment.init clamps).
        #expect(TempoLaneEdit.scrubbedBPM(map: map, index: 0, toBPM: 9999).segments[0].bpm == 400)
        #expect(TempoLaneEdit.scrubbedBPM(map: map, index: 2, toBPM: 1).segments[2].bpm == 20)
    }

    @Test("addedSegment inserts a snapped split at the governing bpm; duplicates no-op")
    func addedSegment() throws {
        let map = try TempoMap(segments: [.init(startBeat: 0, bpm: 120)])
        let meter = MeterMap(constant: TimeSignature())
        let added = TempoLaneEdit.addedSegment(map: map, atBeat: 7.6, snap: .bar, meterMap: meter)
        #expect(added.segments.count == 2)
        #expect(added.segments[1].startBeat == 8)          // snapped to bar
        #expect(added.segments[1].bpm == 120)              // inherits the governing tempo
        // Adding on an existing boundary is a no-op.
        #expect(TempoLaneEdit.addedSegment(map: added, atBeat: 8, snap: .off, meterMap: meter).segments.count == 2)
        // beat 0 is fixed → no-op.
        #expect(TempoLaneEdit.addedSegment(map: map, atBeat: 0, snap: .off, meterMap: meter).segments.count == 1)
    }

    @Test("removedSegment drops a middle segment; segment 0 is protected")
    func removedSegment() throws {
        let map = try multiTempo()
        let removed = TempoLaneEdit.removedSegment(map: map, index: 1)
        #expect(removed.segments.map(\.startBeat) == [0, 16])
        #expect(TempoLaneEdit.removedSegment(map: map, index: 0) == map)   // base protected
    }

    @Test("meterEdited adds/edits at a barline; orphaning a later change throws")
    func meterEdited() throws {
        let meter = MeterMap(constant: TimeSignature(beatsPerBar: 4, beatUnit: 4))
        // Add 3/4 at beat 8 (a 4/4 barline).
        let edited = try TempoLaneEdit.meterEdited(meterMap: meter, atBeat: 8.1, beatsPerBar: 3, beatUnit: 4)
        #expect(edited.changes.count == 2)
        #expect(edited.changes[1].startBeat == 8)
        #expect(edited.changes[1].beatsPerBar == 3)

        // Now a change exists at 8 (3/4) and at 16 (4/4)... build that, then make
        // beat 8 7/8 so beat 16 is no longer a whole number of bars past it → throw.
        let two = try MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 8, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 4, beatUnit: 4),
        ])
        #expect(throws: MeterMap.ValidationError.self) {
            _ = try TempoLaneEdit.meterEdited(meterMap: two, atBeat: 8, beatsPerBar: 7, beatUnit: 8)
        }
    }

    // MARK: - TempoLaneHint (amber boundary predicate, §3.5)

    @Test("amber hint: audio clip crossing a non-trivial boundary hints; MIDI never")
    func amberHint() throws {
        let map = try multiTempo()   // boundary at 8, 16
        // Audio clip [4, 12) crosses beat 8 → hints.
        #expect(TempoLaneHint.audioClipCrossesBoundary(startBeat: 4, lengthBeats: 8, isMIDI: false, tempoMap: map))
        // Same span, MIDI → never hints.
        #expect(!TempoLaneHint.audioClipCrossesBoundary(startBeat: 4, lengthBeats: 8, isMIDI: true, tempoMap: map))
        // Audio clip entirely inside segment 0 → no hint.
        #expect(!TempoLaneHint.audioClipCrossesBoundary(startBeat: 0, lengthBeats: 8, isMIDI: false, tempoMap: map))
        // Audio clip ENDING exactly on the boundary → no hint (its material is pre-8).
        #expect(!TempoLaneHint.audioClipCrossesBoundary(startBeat: 4, lengthBeats: 4, isMIDI: false, tempoMap: map))
        // Trivial map → never hints.
        let trivial = TempoMap(constantBPM: 120)
        #expect(!TempoLaneHint.audioClipCrossesBoundary(startBeat: 0, lengthBeats: 100, isMIDI: false, tempoMap: trivial))
    }

    // MARK: - TempoLaneModel (orchestration through the store)

    @Test("dragBoundary applies the right map through setTempoMap")
    func modelDragBoundary() throws {
        let store = ProjectStore()
        try store.setTempoMap(multiTempo())
        let model = makeModel(store)
        model.dragBoundary(index: 1, toBeat: 11.7, snap: .bar)
        #expect(store.transport.tempoMap.segments[1].startBeat == 12)
        #expect(store.transport.tempoMap.segments.count == 3)
    }

    @Test("a bpm scrub burst coalesces into ONE undo step")
    func modelScrubCoalesces() throws {
        let store = ProjectStore()
        try store.setTempoMap(TempoMap(segments: [.init(startBeat: 0, bpm: 120), .init(startBeat: 8, bpm: 90)]))
        // Break coalescing off the seed edit (undo→redo leaves a nil-key top), so
        // the scrub burst forms its own single entry we can measure cleanly.
        try store.undo(); try store.redo()
        let before = store.undoHistory().undo.count

        let model = makeModel(store)
        model.scrubBPM(index: 1, toBPM: 95)
        model.scrubBPM(index: 1, toBPM: 100)
        model.scrubBPM(index: 1, toBPM: 105)
        #expect(store.transport.tempoMap.segments[1].bpm == 105)
        // Exactly ONE new undo entry for the whole burst.
        #expect(store.undoHistory().undo.count == before + 1)
        // And one undo reverts the ENTIRE scrub to the pre-burst bpm.
        try store.undo()
        #expect(store.transport.tempoMap.segments[1].bpm == 90)
    }

    @Test("add then remove a segment round-trips through the store")
    func modelAddRemove() throws {
        let store = ProjectStore()
        let model = makeModel(store)
        #expect(model.isTrivial)
        model.addSegment(atBeat: 8, snap: .bar)
        #expect(store.transport.tempoMap.segments.count == 2)
        #expect(model.selectedSegmentIndex == 1)
        model.removeSegment(index: 1)
        #expect(store.transport.tempoMap.segments.count == 1)
        #expect(model.selectedSegmentIndex == nil)
        #expect(model.isTrivial)                              // back to the scalar affordance
    }

    @Test("setMeter through the store installs a barline change; an orphaning edit surfaces a teaching error")
    func modelSetMeter() throws {
        let store = ProjectStore()
        let model = makeModel(store)
        model.setMeter(atBeat: 8, beatsPerBar: 3, beatUnit: 4)
        #expect(store.transport.meterMap.changes.count == 2)
        #expect(store.transport.meterMap.changes[1].beatsPerBar == 3)
        #expect(model.lastErrorMessage == nil)

        // A later change at 16 exists implicitly? No — add one, then orphan it.
        model.setMeter(atBeat: 16, beatsPerBar: 4, beatUnit: 4)
        model.setMeter(atBeat: 8, beatsPerBar: 7, beatUnit: 8)   // 16 no longer a bar past 8
        #expect(model.lastErrorMessage != nil)
    }

    @Test("a rejected apply surfaces the store's teaching error, touches nothing")
    func modelApplyErrorSurfaces() throws {
        // Fake apply that always throws the recording-lock error (the store's shape).
        var applied = false
        let model = TempoLaneModel(
            map: { (TempoMap(constantBPM: 120), MeterMap(constant: TimeSignature())) },
            apply: { _, _ in applied = true; throw ProjectError.transportBusy("cannot change the tempo map while recording — stop first") })
        model.scrubBPM(index: 0, toBPM: 130)
        #expect(applied)
        #expect(model.lastErrorMessage == "cannot change the tempo map while recording — stop first")
    }

    private func makeModel(_ store: ProjectStore) -> TempoLaneModel {
        TempoLaneModel(
            map: { (store.transport.tempoMap, store.transport.meterMap) },
            apply: { tempo, meter in try store.setTempoMap(tempo, meterMap: meter) })
    }
}
