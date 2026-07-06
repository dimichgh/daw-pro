import CoreGraphics
import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless tests for the M5 (iii-c) take-lane UI model: lane-row geometry, paint
/// drag classification + snapping, the paint override math, and the
/// sort/clamp/coalesce normalize that must stay inside what
/// `ProjectStore.setCompSegments` accepts. The store-validation cross-check
/// (`assertStoreAcceptable`) mirrors the store's guards so a comp the editor
/// draws is provably one the store will store (the ClipEditModel precedent).
@Suite struct TakeLaneModelTests {

    // A local mirror of ProjectStore.setCompSegments' validation: known lanes,
    // end > start, sorted, non-overlapping. If the editor's output would fail
    // this it would be rejected by the store — so every paint result must pass.
    private func assertStoreAcceptable(_ comp: [CompSegment], laneIDs: Set<UUID>,
                                       sourceLocation: SourceLocation = #_sourceLocation) {
        for seg in comp {
            #expect(laneIDs.contains(seg.laneID), sourceLocation: sourceLocation)
            #expect(seg.endBeat > seg.startBeat, sourceLocation: sourceLocation)
        }
        for i in comp.indices.dropFirst() {
            #expect(comp[i].startBeat >= comp[i - 1].endBeat, sourceLocation: sourceLocation)
        }
    }

    // MARK: - Geometry

    @Test func geometryBeatXRoundTrip() {
        let geo = TakeLaneGeometry(pixelsPerBeat: 16, rowHeight: 26)
        #expect(geo.x(forBeat: 4) == 64)
        #expect(geo.beat(forX: 64) == 4)
        #expect(geo.beat(forX: -10) == 0)           // floored at bar 1
    }

    @Test func geometryRowStacking() {
        let geo = TakeLaneGeometry(pixelsPerBeat: 16, rowHeight: 26)
        #expect(geo.rowTop(0) == 0)
        #expect(geo.rowTop(2) == 52)
        #expect(geo.height(rowCount: 3) == 78)
        #expect(geo.rowIndex(forY: 0, rowCount: 3) == 0)
        #expect(geo.rowIndex(forY: 27, rowCount: 3) == 1)
        #expect(geo.rowIndex(forY: 60, rowCount: 3) == 2)
        #expect(geo.rowIndex(forY: 90, rowCount: 3) == nil)   // past the last row
        #expect(geo.rowIndex(forY: -5, rowCount: 3) == nil)
    }

    @Test func segmentRectSpansBeatsAcrossRow() {
        let geo = TakeLaneGeometry(pixelsPerBeat: 16, rowHeight: 26)
        let rect = geo.segmentRect(startBeat: 2, endBeat: 6, rowIndex: 1, inset: 1.5)
        #expect(rect.origin.x == 32)
        #expect(rect.width == 64)
        #expect(rect.origin.y == geo.rowTop(1) + 1.5)
        #expect(rect.height == 23.0)   // rowHeight 26 - inset 1.5 * 2
    }

    // MARK: - Drag classification

    @Test func classifyClickBelowThresholdSelects() {
        let lane = UUID()
        let g = TakeComp.classifyDrag(laneID: lane, fromBeatRaw: 3.0, toBeatRaw: 3.02,
                                      snap: .off, beatsPerBar: 4, range: 0...8)
        #expect(g.isClick)   // 0.02-beat raw span < 0.15 threshold
    }

    @Test func classifyDragSnapsAndOrders() {
        let lane = UUID()
        // Dragged right-to-left (to < from); snap to beat grid; ordered lo..hi.
        let g = TakeComp.classifyDrag(laneID: lane, fromBeatRaw: 5.4, toBeatRaw: 1.6,
                                      snap: .beat, beatsPerBar: 4, range: 0...8)
        #expect(!g.isClick)
        #expect(g.startBeat == 2)   // 1.6 -> 2
        #expect(g.endBeat == 5)     // 5.4 -> 5
    }

    @Test func classifyDragClampsToRangeAndKeepsSpan() {
        let lane = UUID()
        // A tiny snapped span at the range end still clamps to a >= min span.
        let g = TakeComp.classifyDrag(laneID: lane, fromBeatRaw: 7.9, toBeatRaw: 8.4,
                                      snap: .off, beatsPerBar: 4, range: 0...8)
        #expect(g.endBeat <= 8.0 + 1e-9)
        #expect(g.endBeat > g.startBeat)
    }

    // MARK: - Paint override

    @Test func paintOverMiddleSplitsExistingSegment() {
        let a = UUID(), b = UUID()
        let range = 0.0...8.0
        // Start with one full-range segment on lane A.
        let comp = [CompSegment(laneID: a, startBeat: 0, endBeat: 8)]
        // Paint lane B over the middle.
        let out = TakeComp.paint(comp, laneID: b, startBeat: 3, endBeat: 5, range: range)
        #expect(out.count == 3)
        #expect(out[0].laneID == a && out[0].startBeat == 0 && out[0].endBeat == 3)
        #expect(out[1].laneID == b && out[1].startBeat == 3 && out[1].endBeat == 5)
        #expect(out[2].laneID == a && out[2].startBeat == 5 && out[2].endBeat == 8)
        assertStoreAcceptable(out, laneIDs: [a, b])
    }

    @Test func paintWholeRangeReplaces() {
        let a = UUID(), b = UUID()
        let range = 0.0...8.0
        let comp = [CompSegment(laneID: a, startBeat: 0, endBeat: 8)]
        let out = TakeComp.paint(comp, laneID: b, startBeat: 0, endBeat: 8, range: range)
        #expect(out.count == 1)
        #expect(out[0].laneID == b)
        assertStoreAcceptable(out, laneIDs: [a, b])
    }

    @Test func paintCoalescesAbuttingSameLane() {
        let a = UUID(), b = UUID()
        let range = 0.0...8.0
        // Two A segments with a B segment between; painting A over the B run
        // should re-merge into a single A segment.
        let comp = [
            CompSegment(laneID: a, startBeat: 0, endBeat: 3),
            CompSegment(laneID: b, startBeat: 3, endBeat: 5),
            CompSegment(laneID: a, startBeat: 5, endBeat: 8),
        ]
        let out = TakeComp.paint(comp, laneID: a, startBeat: 3, endBeat: 5, range: range)
        #expect(out.count == 1)
        #expect(out[0].laneID == a && out[0].startBeat == 0 && out[0].endBeat == 8)
        assertStoreAcceptable(out, laneIDs: [a, b])
    }

    @Test func paintOverlappingEdgesTrimsNeighbors() {
        let a = UUID(), b = UUID(), c = UUID()
        let range = 0.0...9.0
        let comp = [
            CompSegment(laneID: a, startBeat: 0, endBeat: 3),
            CompSegment(laneID: b, startBeat: 3, endBeat: 6),
            CompSegment(laneID: c, startBeat: 6, endBeat: 9),
        ]
        // Paint A over [2,7): trims the A tail, wipes B, trims the C head.
        let out = TakeComp.paint(comp, laneID: a, startBeat: 2, endBeat: 7, range: range)
        assertStoreAcceptable(out, laneIDs: [a, b, c])
        // The painted region is fully lane A and coalesced with the leading A.
        #expect(TakeComp.laneID(at: 0, comp: out) == a)
        #expect(TakeComp.laneID(at: 5, comp: out) == a)
        #expect(TakeComp.laneID(at: 6.5, comp: out) == a)
        #expect(TakeComp.laneID(at: 8, comp: out) == c)
    }

    @Test func paintClampsToRange() {
        let a = UUID()
        let range = 1.0...7.0
        let out = TakeComp.paint([], laneID: a, startBeat: -2, endBeat: 20, range: range)
        #expect(out.count == 1)
        #expect(out[0].startBeat == 1 && out[0].endBeat == 7)
        assertStoreAcceptable(out, laneIDs: [a])
    }

    // MARK: - Select + queries

    @Test func selectWholeRangeIsOneSegment() {
        let a = UUID()
        let out = TakeComp.selectWholeRange(laneID: a, range: 2...10)
        #expect(out == [CompSegment(laneID: a, startBeat: 2, endBeat: 10)])
    }

    @Test func laneIDAtBeatHonorsGaps() {
        let a = UUID(), b = UUID()
        let comp = [
            CompSegment(laneID: a, startBeat: 0, endBeat: 3),
            CompSegment(laneID: b, startBeat: 5, endBeat: 8),
        ]
        #expect(TakeComp.laneID(at: 1, comp: comp) == a)
        #expect(TakeComp.laneID(at: 4, comp: comp) == nil)   // gap = silence
        #expect(TakeComp.laneID(at: 6, comp: comp) == b)
        #expect(TakeComp.laneID(at: 8, comp: comp) == nil)   // half-open end
    }

    @Test func segmentsForLaneFilters() {
        let a = UUID(), b = UUID()
        let comp = [
            CompSegment(laneID: a, startBeat: 0, endBeat: 3),
            CompSegment(laneID: b, startBeat: 3, endBeat: 5),
            CompSegment(laneID: a, startBeat: 5, endBeat: 8),
        ]
        #expect(TakeComp.segments(forLane: a, comp: comp).count == 2)
        #expect(TakeComp.segments(forLane: b, comp: comp).count == 1)
    }

    // MARK: - Normalize

    @Test func normalizeSortsClampsAndDropsEmpties() {
        let a = UUID(), b = UUID()
        let range = 0.0...8.0
        let messy = [
            CompSegment(laneID: b, startBeat: 5, endBeat: 8),
            CompSegment(laneID: a, startBeat: -2, endBeat: 3),   // clamps to 0..3
            CompSegment(laneID: a, startBeat: 4, endBeat: 4),    // empty -> dropped
        ]
        let out = TakeComp.normalize(messy, range: range)
        #expect(out.count == 2)
        #expect(out[0].laneID == a && out[0].startBeat == 0 && out[0].endBeat == 3)
        #expect(out[1].laneID == b && out[1].startBeat == 5 && out[1].endBeat == 8)
        assertStoreAcceptable(out, laneIDs: [a, b])
    }

    @Test func normalizeResolvesOverlapLastWins() {
        let a = UUID(), b = UUID()
        let overlapping = [
            CompSegment(laneID: a, startBeat: 0, endBeat: 5),
            CompSegment(laneID: b, startBeat: 3, endBeat: 8),
        ]
        let out = TakeComp.normalize(overlapping, range: 0...8)
        assertStoreAcceptable(out, laneIDs: [a, b])
        #expect(out[0].endBeat == 3)   // A trimmed at B's start
        #expect(out[1].startBeat == 3)
    }
}

/// Selection/derivation helpers used by the disclosure glyph, group badge, and
/// splice lines.
@Suite struct TakeLaneSelectionTests {

    private func audioClip(start: Double, length: Double, group: UUID? = nil) -> Clip {
        var c = Clip(name: "Take", startBeat: start, lengthBeats: length,
                     audioFileURL: URL(fileURLWithPath: "/tmp/take.caf"))
        c.takeGroupID = group
        return c
    }

    @Test func hasTakeGroupsAndRowCount() {
        var track = Track(name: "Vox", kind: .audio)
        #expect(!TakeLaneSelection.hasTakeGroups(track))
        #expect(TakeLaneSelection.totalLaneRows(track) == 0)

        let lanes = [
            TakeLane(name: "Take 1", clip: audioClip(start: 0, length: 4)),
            TakeLane(name: "Take 2", clip: audioClip(start: 0, length: 4)),
        ]
        track.takeGroups = [TakeGroup(name: "Vox Takes", lanes: lanes)]
        #expect(TakeLaneSelection.hasTakeGroups(track))
        #expect(TakeLaneSelection.totalLaneRows(track) == 2)
    }

    @Test func badgeNamesGroupAndLaneCount() {
        let lanes = [
            TakeLane(name: "Take 1", clip: audioClip(start: 0, length: 4)),
            TakeLane(name: "Take 2", clip: audioClip(start: 0, length: 4)),
            TakeLane(name: "Take 3", clip: audioClip(start: 0, length: 4)),
        ]
        let group = TakeGroup(name: "Vox Takes", lanes: lanes)
        #expect(TakeLaneSelection.badge(for: group) == "Vox Takes · 3")
    }

    @Test func groupForMemberMatchesByID() {
        var track = Track(name: "Vox", kind: .audio)
        let lanes = [TakeLane(name: "Take 1", clip: audioClip(start: 0, length: 4)),
                     TakeLane(name: "Take 2", clip: audioClip(start: 0, length: 4))]
        let group = TakeGroup(name: "Vox Takes", lanes: lanes)
        track.takeGroups = [group]
        let member = audioClip(start: 0, length: 4, group: group.id)
        #expect(TakeLaneSelection.group(forMember: member, in: track)?.id == group.id)
        let ordinary = audioClip(start: 0, length: 4)
        #expect(TakeLaneSelection.group(forMember: ordinary, in: track) == nil)
    }

    @Test func leadingSpliceDetectedAtInternalBoundary() {
        let gid = UUID()
        let left = audioClip(start: 0, length: 3, group: gid)
        let right = audioClip(start: 3, length: 5, group: gid)
        let members = [left, right]
        #expect(!TakeLaneSelection.hasLeadingSplice(left, among: members))   // group start
        #expect(TakeLaneSelection.hasLeadingSplice(right, among: members))   // internal splice
    }
}
