import CoreGraphics
import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Headless coverage for the piano-roll CONTROLLER STRIP model (m16-b4). The
/// SwiftUI `ControllerLaneStrip` view is thin over this — all geometry + edits
/// live here — so exercising it covers the strip's logic without a display (the
/// `PianoRollModel` / `AutomationLaneModel` suite style). Lane truth is always the
/// DAWCore primitives (`MIDIControllerLane.canonicalPoints`); the strip never
/// re-derives stepwise semantics.
@MainActor
@Suite("ControllerStripModel (m16-b4)")
struct ControllerStripModelTests {

    private func makeModel(lanes: [MIDIControllerLane] = [], length: Double = 8) -> ControllerStripModel {
        ControllerStripModel(lanes: lanes, clipLengthBeats: length)
    }

    // MARK: - C16 value↔y (both domains)

    // 1. cc/pressure occupy the 127 domain: value 0 at the bottom inset, 127 at the
    //    top inset, and value(forY:) round-trips.
    @Test("C16 value↔y in the 127 domain round-trips (cc)")
    func valueYCC127() {
        let m = makeModel()
        let t = MIDIControllerType.cc(controller: 1)
        let inset = ControllerStripModel.verticalInset
        let usable = m.usableHeight
        // value 0 → bottom (inset + usable); value 127 → top (inset).
        #expect(m.y(forValue: 0, type: t) == inset + usable)
        #expect(m.y(forValue: 127, type: t) == inset)
        // Round-trip the endpoints and a midpoint.
        #expect(m.value(forY: m.y(forValue: 0, type: t), type: t) == 0)
        #expect(m.value(forY: m.y(forValue: 127, type: t), type: t) == 127)
        let mid = m.y(forValue: 64, type: t)
        #expect(abs(m.value(forY: mid, type: t) - 64) <= 1)
        // Out-of-band y clamps into the domain.
        #expect(m.value(forY: -100, type: t) == 127)
        #expect(m.value(forY: ControllerStripModel.laneHeight + 100, type: t) == 0)
    }

    // 2. Pitch bend occupies the 16383 domain; the center (8192) lands near
    //    mid-height, which is where the strip draws its center guideline.
    @Test("C16 value↔y in the 16383 domain; bend center is the guideline (bend)")
    func valueYBend16383() {
        let m = makeModel()
        let t = MIDIControllerType.pitchBend
        // Center 8192 round-trips.
        let centerY = m.y(forValue: 8192, type: t)
        #expect(m.value(forY: centerY, type: t) == 8192)
        // The guideline is exactly the center-value y for bend, and nil otherwise.
        #expect(m.centerGuidelineY(type: t) == centerY)
        #expect(m.centerGuidelineY(type: .cc(controller: 11)) == nil)
        // Endpoints span the strip: 0 at the bottom, 16383 at the top.
        #expect(m.y(forValue: 0, type: t) == ControllerStripModel.verticalInset + m.usableHeight)
        #expect(m.y(forValue: 16383, type: t) == ControllerStripModel.verticalInset)
    }

    // 3. beat↔x reuses the affine scale.
    @Test("C16 beat↔x round-trips at the strip scale")
    func beatXRoundTrip() {
        let m = makeModel()
        #expect(m.x(forBeat: 3) == 3 * ControllerStripModel.defaultPixelsPerBeat)
        for beat in [0.0, 1.0, 2.5, 6.0] {
            #expect(abs(m.beat(forX: m.x(forBeat: beat)) - beat) < 1e-9)
        }
        #expect(m.beat(forX: -50) == 0)   // floored at 0
    }

    // MARK: - C16 pencil / drag / hit

    // 4. Pencil inserts at ticks; a same-value point at a held level is DROPPED;
    //    the same tick REPLACES.
    @Test("C16 pencil inserts, drops duplicate values, replaces the same tick")
    func pencilInsertDropReplace() {
        let m = makeModel()
        m.select(type: .cc(controller: 1))
        #expect(m.pencilInsert(atBeat: 0, value: 20))
        #expect(m.pencilInsert(atBeat: 2, value: 100))
        // Value 100 already holds at beat 4 (stepwise) → dropped, no new point.
        #expect(m.pencilInsert(atBeat: 4, value: 100) == false)
        #expect(m.draft.count == 2)
        // Re-touching beat 2 with a new value replaces in place (no growth).
        #expect(m.pencilInsert(atBeat: 2, value: 80))
        #expect(m.draft.count == 2)
        #expect(m.buildSubmission() == [
            MIDIControllerPoint(beat: 0, value: 20),
            MIDIControllerPoint(beat: 2, value: 80),
        ])
    }

    // 5. Drag targets the NEAREST point (identity-free) and moves its beat+value.
    @Test("C16 drag moves the nearest point (nearest-stem idiom)")
    func dragNearestPoint() {
        let m = makeModel()
        m.select(type: .cc(controller: 1))
        m.pencilInsert(atBeat: 0, value: 10)
        m.pencilInsert(atBeat: 4, value: 100)
        // Begin a drag right on the beat-4 point.
        let near = CGPoint(x: m.x(forBeat: 4), y: m.y(forValue: 100, type: .cc(controller: 1)))
        #expect(m.beginDrag(at: near))
        // Drag it to beat 3, value 60.
        m.dragPoint(toBeat: 3, value: 60)
        m.endDrag()
        let out = m.buildSubmission()
        // Points canonicalize by beat: (0,10) then (3,60).
        #expect(out == [MIDIControllerPoint(beat: 0, value: 10), MIDIControllerPoint(beat: 3, value: 60)])
    }

    // 6. hitTest returns the nearest index within the radius, nil over empty space;
    //    removePoint deletes the nearest.
    @Test("C16 hitTest + removePoint target the nearest point")
    func hitAndRemove() {
        let m = makeModel()
        m.select(type: .pitchBend)
        m.pencilInsert(atBeat: 1, value: 8192)
        m.pencilInsert(atBeat: 3, value: 12000)
        let p1 = CGPoint(x: m.x(forBeat: 1), y: m.y(forValue: 8192, type: .pitchBend))
        #expect(m.hitTest(p1) != nil)
        #expect(m.hitTest(CGPoint(x: 5000, y: 5000)) == nil)   // far → miss
        #expect(m.removePoint(at: p1))
        #expect(m.draft.count == 1)
        #expect(m.draft.first?.beat == 3)
    }

    // MARK: - C16 submission + cap

    // 7. buildSubmission returns the canonical whole-lane array (sorted, clamped).
    @Test("C16 buildSubmission is the canonical whole-lane array")
    func buildSubmissionCanonical() {
        let m = makeModel()
        m.select(type: .cc(controller: 11))
        // Insert out of order + an out-of-range value (clamps at submit).
        m.pencilInsert(atBeat: 3, value: 200)   // clamps → 127
        m.pencilInsert(atBeat: 1, value: 40)
        let out = m.buildSubmission()
        #expect(out == [
            MIDIControllerPoint(beat: 1, value: 40),
            MIDIControllerPoint(beat: 3, value: 127),
        ])
        // No lane selected → empty submission.
        let empty = makeModel()
        #expect(empty.buildSubmission().isEmpty)
    }

    // 8. The 16384-point cap is enforced AT SUBMIT (the strip never hands the store
    //    an over-cap array — the store would throw).
    @Test("C16 buildSubmission decimates to the 16384-point cap")
    func submissionCap() {
        let m = makeModel(length: 4)
        m.select(type: .cc(controller: 1))
        // 20000 distinct-beat points — over the cap.
        m.draft = (0..<20_000).map { MIDIControllerPoint(beat: Double($0) * 0.001, value: $0 % 128) }
        let out = m.buildSubmission()
        #expect(out.count <= ControllerStripModel.maxPoints)
        #expect(out.count == ControllerStripModel.maxPoints)   // decimated to exactly the cap
        // Still canonical (strictly ascending beats).
        for i in 1..<out.count { #expect(out[i].beat > out[i - 1].beat) }
    }

    // 9. Handles hide above the density threshold (dense captured data draws as the
    //    stepped line only).
    @Test("C16 handles hide above the 4-points/px density threshold")
    func handleDensity() {
        let sparse = makeModel(length: 4)
        sparse.select(type: .cc(controller: 1))
        sparse.pencilInsert(atBeat: 0, value: 0)
        sparse.pencilInsert(atBeat: 2, value: 100)
        #expect(sparse.handlesVisible)   // 2 points / 128 px → visible
        let dense = makeModel(length: 4)
        dense.select(type: .cc(controller: 1))
        // 600 points over the 128 px content → 4.7 points/px → hidden.
        dense.draft = (0..<600).map { MIDIControllerPoint(beat: Double($0) * 0.005, value: $0 % 128) }
        #expect(dense.handlesVisible == false)
    }

    // MARK: - C18 densities (labels, chips, add menu, Simple summary)

    // 10. Beginner-readable lane labels (design-m16b §9, DESIGN-LANGUAGE rule 6).
    @Test("C18 lane labels are beginner-readable")
    func laneLabels() {
        #expect(ControllerStripModel.label(for: .pitchBend) == "Bend")
        #expect(ControllerStripModel.label(for: .channelPressure) == "Pressure")
        #expect(ControllerStripModel.label(for: .cc(controller: 1)) == "Mod (CC 1)")
        #expect(ControllerStripModel.label(for: .cc(controller: 11)) == "Expression (CC 11)")
        #expect(ControllerStripModel.label(for: .cc(controller: 64)) == "Sustain (CC 64)")
        #expect(ControllerStripModel.label(for: .cc(controller: 74)) == "CC 74")
    }

    // 11. Chips enumerate the clip's lanes in canonical order; the "+" menu offers
    //    the named controllers plus the "Other CC…" numeric entry.
    @Test("C18 chips enumerate lanes; the add menu offers the named set + Other CC")
    func chipsAndAddMenu() {
        let m = makeModel(lanes: [
            MIDIControllerLane(type: .pitchBend, points: [MIDIControllerPoint(beat: 0, value: 8192)]),
            MIDIControllerLane(type: .cc(controller: 1), points: [MIDIControllerPoint(beat: 0, value: 10)]),
        ])
        // Canonical order: cc(1) before pitchBend.
        #expect(m.laneChips.map(\.type) == [.cc(controller: 1), .pitchBend])
        #expect(m.laneChips.map(\.label) == ["Mod (CC 1)", "Bend"])
        // Add menu: 6 items, ending in the numeric-entry sentinel.
        let items = ControllerStripModel.addMenuItems
        #expect(items.count == 6)
        #expect(items.first == .type(.pitchBend, label: "Bend"))
        #expect(items.last == .otherCC)
        #expect(items.last?.label == "Other CC…")
    }

    // 12. Simple-density passive summary (the m15-c Pro-only precedent): the chip's
    //    copy comes from the model layer, testable headlessly.
    @Test("C18 Simple-density lane-count summary copy")
    func laneCountSummary() {
        #expect(ControllerStripModel.laneCountSummary(count: 0) == nil)
        #expect(ControllerStripModel.laneCountSummary(count: 1) == "1 controller lane")
        #expect(ControllerStripModel.laneCountSummary(count: 3) == "3 controller lanes")
        // The instance summary reflects the clip's lanes.
        let m = makeModel(lanes: [
            MIDIControllerLane(type: .cc(controller: 1), points: [MIDIControllerPoint(beat: 0, value: 1)]),
            MIDIControllerLane(type: .pitchBend, points: [MIDIControllerPoint(beat: 0, value: 8192)]),
        ])
        #expect(m.laneCountSummary == "2 controller lanes")
        #expect(makeModel().laneCountSummary == nil)   // no lanes → no chip
    }

    // MARK: - selection / staging / reseed

    // 13. Selecting an existing lane loads its points; staging a new type starts an
    //    empty editable draft (the "+" menu path).
    @Test("select loads an existing lane; a staged type starts empty")
    func selectAndStage() {
        let m = makeModel(lanes: [
            MIDIControllerLane(type: .cc(controller: 1), points: [
                MIDIControllerPoint(beat: 0, value: 10),
                MIDIControllerPoint(beat: 2, value: 90)]),
        ])
        // Opens on the first lane.
        #expect(m.selectedType == .cc(controller: 1))
        #expect(m.draft.count == 2)
        // Stage a brand-new type → empty draft, ready to paint.
        m.select(type: .pitchBend)
        #expect(m.selectedType == .pitchBend)
        #expect(m.draft.isEmpty)
    }

    // 14. load keeps the current selection when its type survives, else falls back.
    @Test("load keeps a surviving selection, else falls to the first lane / nil")
    func loadReseed() {
        let m = makeModel(lanes: [MIDIControllerLane(type: .cc(controller: 1),
                                                     points: [MIDIControllerPoint(beat: 0, value: 5)])])
        m.select(type: .cc(controller: 1))
        // Reseed with the same lane present → selection kept, draft re-read.
        m.load(lanes: [MIDIControllerLane(type: .cc(controller: 1),
                                          points: [MIDIControllerPoint(beat: 0, value: 42)])],
               clipLengthBeats: 8)
        #expect(m.selectedType == .cc(controller: 1))
        #expect(m.draft.first?.value == 42)
        // Reseed with the selection gone → falls to the first remaining lane.
        m.load(lanes: [MIDIControllerLane(type: .pitchBend,
                                          points: [MIDIControllerPoint(beat: 0, value: 8192)])],
               clipLengthBeats: 8)
        #expect(m.selectedType == .pitchBend)
        // Reseed empty → nothing selected.
        m.load(lanes: [], clipLengthBeats: 8)
        #expect(m.selectedType == nil)
        #expect(m.draft.isEmpty)
    }
}

/// C17 — UI == wire equivalence (the m11-a idiom): a strip gesture commit produces
/// store state IDENTICAL to the equivalent `clip.setControllerLane` wire call.
@MainActor
@Suite("Controller strip UI==wire equivalence (m16-b4 C17)")
struct ControllerStripWireEquivalenceTests {

    private func storeWithMIDIClip() throws -> (store: ProjectStore, clip: Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, lengthBeats: 8,
                                         notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        return (store, clip)
    }

    // C17.a — the model driven end-to-end through setControllerLane produces the
    // same clip state as a direct wire-shaped setControllerLane call on a twin.
    @Test("C17 a strip commit equals the wire call on a twin store")
    func stripCommitEqualsWire() throws {
        // Store A: drive the strip model, then commit through the store call the
        // clip.setControllerLane wire verb uses.
        let (storeA, clipA) = try storeWithMIDIClip()
        let model = ControllerStripModel(lanes: clipA.controllerLanes, clipLengthBeats: clipA.lengthBeats)
        model.select(type: .cc(controller: 1))
        model.pencilInsert(atBeat: 0, value: 20)
        model.pencilInsert(atBeat: 4, value: 100)
        model.pencilInsert(atBeat: 2, value: 60)   // out of order — canonicalizes on submit
        _ = try storeA.setControllerLane(clipID: clipA.id,
                                         type: model.selectedType!,
                                         points: model.buildSubmission())

        // Store B (twin): the equivalent wire call with the same intended points.
        let (storeB, clipB) = try storeWithMIDIClip()
        _ = try storeB.setControllerLane(clipID: clipB.id, type: .cc(controller: 1), points: [
            MIDIControllerPoint(beat: 0, value: 20),
            MIDIControllerPoint(beat: 2, value: 60),
            MIDIControllerPoint(beat: 4, value: 100),
        ])

        #expect(storeA.tracks[0].clips[0].controllerLanes ==
                storeB.tracks[0].clips[0].controllerLanes)
        #expect(!storeA.tracks[0].clips[0].controllerLanes.isEmpty)
    }

    // C17.b — clearing the visible lane commits an empty array, which the store
    // treats as delete-the-lane — identical to the wire remove/empty path.
    @Test("C17 clearing the lane commits empty == the store's delete path")
    func clearEqualsDelete() throws {
        let (store, clip) = try storeWithMIDIClip()
        _ = try store.setControllerLane(clipID: clip.id, type: .pitchBend,
                                        points: [MIDIControllerPoint(beat: 0, value: 8192)])
        let model = ControllerStripModel(lanes: store.tracks[0].clips[0].controllerLanes,
                                         clipLengthBeats: clip.lengthBeats)
        model.select(type: .pitchBend)
        model.clearDraft()
        _ = try store.setControllerLane(clipID: clip.id, type: .pitchBend,
                                        points: model.buildSubmission())
        #expect(store.tracks[0].clips[0].controllerLanes.isEmpty)
    }
}
