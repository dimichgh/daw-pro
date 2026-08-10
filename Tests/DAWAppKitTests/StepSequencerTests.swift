import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Headless coverage for the STEP SEQUENCER (m23-cq-1) — the grid editor over
/// the SAME `[MIDINote]` the piano roll edits.
///
/// Everything the surface decides lives in `DAWAppKit` precisely so it can be
/// swept here: `DAWApp` is an executable target with no test target, so a
/// step→beat mapping, a lane rule or a toggle semantic put in the view would be
/// untestable forever. The view holds one Canvas, one gesture and no decisions.
@Suite("Step sequencer (m23-cq-1)")
struct StepSequencerTests {

    // MARK: - Fixtures

    /// A 4/4, 4-beat clip's geometry at the 1/16 default.
    private func geometry(isDrumKit: Bool = true, notes: [MIDINote] = [],
                          lengthBeats: Double = 4,
                          resolution: SnapResolution = .sixteenth,
                          beatsPerBar: Int = 4) -> StepSequencerGeometry {
        StepSequencerGeometry.make(
            isDrumKit: isDrumKit, notes: notes, clipLengthBeats: lengthBeats,
            resolution: resolution, beatsPerBar: beatsPerBar)
    }

    private static let kick = 36        // "Bass Drum 1"
    private static let snare = 38       // "Acoustic Snare"

    // MARK: - Which editor opens

    @Test("a drum-kit track opens in STEPS, everything else in NOTES — until the user picks")
    func modePolicyDefaultsFromTheTrack() {
        #expect(ClipEditorModePolicy.resolve(override: nil, isDrumKit: true) == .steps)
        #expect(ClipEditorModePolicy.resolve(override: nil, isDrumKit: false) == .notes)
        // The pick wins in BOTH directions — a user who deliberately opened a
        // drum clip in the piano roll must not be thrown back into the grid by
        // clicking the next drum clip.
        #expect(ClipEditorModePolicy.resolve(override: .notes, isDrumKit: true) == .notes)
        #expect(ClipEditorModePolicy.resolve(override: .steps, isDrumKit: false) == .steps)
    }

    // MARK: - Lanes

    @Test("drum lane names come from the GM percussion key map, never a hardcoded table")
    func drumLanesAreNamedFromTheGMKeyMap() {
        let lanes = StepSequencerLanes.lanes(isDrumKit: true, notes: [])
        // Every covered GM percussion note gets a lane — the palette a user
        // clicks into. Derived from the catalog, so this test fails if the two
        // ever disagree rather than restating a literal 17.
        #expect(lanes.count == InstrumentFamilyResolver.percussionNotes.count)
        for entry in InstrumentFamilyResolver.percussionNotes {
            let lane = lanes.first { $0.pitch == entry.note }
            #expect(lane?.label == entry.gmName, "lane \(entry.note) lost its GM name")
            #expect(lane?.isNamedPercussion == true)
        }
        // The two a beginner reaches for first, pinned verbatim so a silent
        // re-label of the catalog is visible here.
        #expect(lanes.first { $0.pitch == Self.kick }?.label == "Bass Drum 1")
        #expect(lanes.first { $0.pitch == Self.snare }?.label == "Acoustic Snare")
    }

    @Test("a melodic clip gets a two-octave window around middle C, named by note")
    func melodicLanesAreAPitchWindow() {
        let lanes = StepSequencerLanes.lanes(isDrumKit: false, notes: [])
        #expect(lanes.count == 24)
        #expect(lanes.map(\.pitch).contains(60))          // middle C is inside
        #expect(lanes.first?.pitch == 71)                 // B4 on top
        #expect(lanes.last?.pitch == 48)                  // C3 at the bottom
        #expect(lanes.first { $0.pitch == 60 }?.label == "C4")
        #expect(lanes.allSatisfy { !$0.isNamedPercussion })
    }

    @Test("EVERY pitch in the clip gets a lane — the grid's only deletion path must reach it")
    func everyPitchInTheClipGetsALane() {
        // 39 (hand clap) is deliberately NOT covered by the v1 percussion table,
        // and 90 is two octaves above the melodic window. Both must still be
        // reachable: the toggle is this surface's only way to delete, and it is
        // mouse-only by design.
        let drum = StepSequencerLanes.lanes(
            isDrumKit: true,
            notes: [MIDINote(pitch: 39, startBeat: 0, lengthBeats: 0.25)])
        let clap = drum.first { $0.pitch == 39 }
        #expect(clap != nil)
        #expect(clap?.isNamedPercussion == false)   // no name is invented for it
        #expect(clap?.label == "D#2")   // the note name, since GM v1 covers no name for 39

        let melodic = StepSequencerLanes.lanes(
            isDrumKit: false,
            notes: [MIDINote(pitch: 90, startBeat: 0, lengthBeats: 1)])
        #expect(melodic.contains { $0.pitch == 90 })
        #expect(melodic.count == 25)
    }

    @Test("lanes run HIGH pitch first — the piano roll's axis, in both editors")
    func lanesRunHighPitchFirst() {
        let drum = StepSequencerLanes.lanes(isDrumKit: true, notes: []).map(\.pitch)
        #expect(drum == drum.sorted(by: >))
        // The GM map ascending kick → cymbals means descending pitch also lands
        // the kit in drum-machine order, kick at the bottom, with no special case.
        #expect(drum.last == 35)
        let melodic = StepSequencerLanes.lanes(isDrumKit: false, notes: []).map(\.pitch)
        #expect(melodic == melodic.sorted(by: >))
    }

    // MARK: - Columns

    @Test("the step count covers the clip AND every note onset past its end")
    func stepCountCoversTheClipAndEveryOnset() {
        #expect(geometry().stepCount == 16)                       // 4 beats at 1/16
        #expect(geometry(resolution: .eighth).stepCount == 8)
        #expect(geometry(resolution: .beat).stepCount == 4)
        // A note left beyond the clip end by a trim is store-legal and latent —
        // and un-deletable from a grid that stopped at the clip end.
        let stranded = geometry(notes: [MIDINote(pitch: 36, startBeat: 5, lengthBeats: 0.25)])
        #expect(stranded.stepCount == 21)
        #expect(stranded.clipEndX < stranded.contentWidth)        // shaded, not cropped
        // Never zero columns, whatever the clip length says.
        #expect(geometry(lengthBeats: 0).stepCount == 1)
    }

    @Test("a drum grid opens at the BOTTOM, where the kick and snare are")
    func drumGridOpensOnTheKit() {
        // Measured, not reasoned: 17 lanes are 424 pt tall against a ~390 pt
        // editor pane, and the first capture of this surface opened on the
        // cymbals with the kick, snare and closed hat all below the fold.
        #expect(geometry(isDrumKit: true).opensAtBottom)
        #expect(!geometry(isDrumKit: false).opensAtBottom)
    }

    @Test("a step grid has no OFF — that resolution falls back to 1/16 and is not offered")
    func offSnapHasNoStepGrid() {
        #expect(StepSequencerGeometry.stepBeats(for: .off) == 0.25)
        #expect(StepSequencerGeometry.stepBeats(for: .eighth) == 0.5)
        #expect(!StepSequencerGeometry.pickableResolutions.contains(.off))
        #expect(StepSequencerGeometry.pickableResolutions.count
                == SnapResolution.allCases.count - 1)
    }

    @Test("Simple density locks the grid to 1/16 without losing the Pro pick")
    func simpleDensityLocksTheStepGrid() {
        #expect(StepSequencerGeometry.effectiveResolution(density: .simple, picked: .eighth)
                == .sixteenth)
        // The pick is never mutated, so flipping back to Pro restores it (the
        // `ClipSnap.effective` rule).
        #expect(StepSequencerGeometry.effectiveResolution(density: .pro, picked: .eighth)
                == .eighth)
    }

    @Test("bar and beat emphasis follow the meter, and vanish when a step is longer than a beat")
    func emphasisFollowsTheMeter() {
        let fourFour = geometry()
        #expect(fourFour.stepsPerBeat == 4)
        #expect(fourFour.stepsPerBar == 16)
        #expect(fourFour.isBarStart(step: 0))
        #expect(!fourFour.isBarStart(step: 4))
        #expect(fourFour.isBeatStart(step: 4))
        #expect(fourFour.barNumber(forStep: 17) == 2)
        // 3/4: a bar is three beats, so the bar line lands every 12 steps.
        #expect(geometry(lengthBeats: 3, beatsPerBar: 3).stepsPerBar == 12)
        // A Bar-sized step has no sub-emphasis to draw.
        let coarse = geometry(resolution: .bar)
        #expect(coarse.stepsPerBeat == 0)
        #expect(coarse.stepsPerBar == 0)
        #expect(coarse.barNumber(forStep: 2) == 3)   // still counts, one bar per step
    }

    @Test("a beat maps to its step even on a triplet grid — the float epsilon")
    func stepIndexSurvivesTripletFloats() {
        let triplet = geometry(resolution: .eighthTriplet)   // 1/3 beat
        // (2.0/3.0) / (1.0/3.0) is 1.9999999999999998 in binary floating point,
        // so a plain floor puts the note that starts ON step 2 into step 1 — the
        // sequencer would draw it a column left of where the roll draws it and
        // the toggle round trip would break on every triplet grid.
        #expect(triplet.stepIndex(forBeat: 2.0 / 3.0) == 2)
        #expect(triplet.stepIndex(forBeat: 1.0) == 3)
        #expect(triplet.stepIndex(forBeat: 0) == 0)
        // Genuinely-between beats still floor to the step they are inside.
        #expect(triplet.stepIndex(forBeat: 0.5) == 1)
        let sixteenths = geometry()
        #expect(sixteenths.stepIndex(forBeat: 0.75) == 3)
        #expect(sixteenths.stepIndex(forBeat: 3.99) == 15)
    }

    // MARK: - Hit testing

    @Test("the hit test addresses exactly the cells the grid draws")
    func hitTestMatchesTheDrawnRects() {
        let g = geometry()
        let topLane = g.lanes[0].pitch
        #expect(g.cell(at: CGPoint(x: 1, y: 1)) == StepCell(step: 0, pitch: topLane))
        // Dead centre of step 3, row 2 — computed from the geometry, never from
        // a hardcoded 30×24.
        let rect = g.cellRect(step: 3, lane: 2)
        #expect(g.cell(at: CGPoint(x: rect.midX, y: rect.midY))
                == StepCell(step: 3, pitch: g.lanes[2].pitch))
        // Outside in every direction is nil, so a click in the shade or below
        // the last lane does nothing rather than toggling an edge cell.
        #expect(g.cell(at: CGPoint(x: -1, y: 4)) == nil)
        #expect(g.cell(at: CGPoint(x: 4, y: -1)) == nil)
        #expect(g.cell(at: CGPoint(x: g.contentWidth + 1, y: 4)) == nil)
        #expect(g.cell(at: CGPoint(x: 4, y: g.contentHeight + 1)) == nil)
    }

    // MARK: - The toggle

    @Test("toggling an empty cell writes ONE note at the step, with the roll's own defaults")
    func toggleOnAddsOneNote() {
        let g = geometry()
        let outcome = StepSequencerEdit.toggle(
            notes: [], cell: StepCell(step: 4, pitch: Self.kick), geometry: g)
        #expect(outcome.notes.count == 1)
        #expect(outcome.removed.isEmpty)
        #expect(outcome.isFilledAfter)
        let note = outcome.notes[0]
        #expect(note.pitch == Self.kick)
        #expect(note.startBeat == 1.0)              // step 4 at 1/16 = beat 1
        #expect(note.lengthBeats == 0.25)           // one grid cell
        #expect(note.velocity == StepSequencerEdit.defaultVelocity)
    }

    @Test("THE ROUND TRIP: toggling a cell on and off returns the clip to its original notes")
    func toggleRoundTripsTheNoteArray() {
        let before = [
            MIDINote(pitch: Self.kick, velocity: 110, startBeat: 0, lengthBeats: 0.25),
            MIDINote(pitch: Self.snare, velocity: 90, startBeat: 1, lengthBeats: 0.25),
        ]
        let g = geometry(notes: before)
        let cell = StepCell(step: 8, pitch: Self.kick)      // beat 2, empty
        let on = StepSequencerEdit.toggle(notes: before, cell: cell, geometry: g)
        #expect(on.notes.count == 3)
        let off = StepSequencerEdit.toggle(notes: on.notes, cell: cell, geometry: g)
        // Compared through the store's OWN canonical order, because that is what
        // `setClipNotes` does to the array on the way in — raw array equality
        // would pass for a reason the real commit path does not guarantee.
        #expect(MIDINote.canonicallyOrdered(off.notes) == MIDINote.canonicallyOrdered(before))
        #expect(off.removed.count == 1)
        #expect(!off.isFilledAfter)
        // And the untouched neighbours kept their velocities, i.e. the toggle
        // rewrote nothing it did not name.
        #expect(off.notes.first { $0.pitch == Self.kick }?.velocity == 110)
        #expect(off.notes.first { $0.pitch == Self.snare }?.velocity == 90)
    }

    @Test("the round trip holds on a triplet grid too")
    func toggleRoundTripsOnTriplets() {
        let before = [MIDINote(pitch: Self.snare, startBeat: 1, lengthBeats: 1.0 / 3.0)]
        let g = geometry(notes: before, resolution: .eighthTriplet)
        let cell = StepCell(step: 2, pitch: Self.kick)
        let on = StepSequencerEdit.toggle(notes: before, cell: cell, geometry: g)
        // The note it just wrote must map BACK to the cell that wrote it — the
        // property the epsilon exists for.
        #expect(StepSequencerEdit.filledCells(notes: on.notes, geometry: g).contains(cell))
        let off = StepSequencerEdit.toggle(notes: on.notes, cell: cell, geometry: g)
        #expect(MIDINote.canonicallyOrdered(off.notes) == MIDINote.canonicallyOrdered(before))
    }

    @Test("toggling a filled cell OFF removes every note in it — the documented flam loss")
    func toggleOffRemovesEveryOccupant() {
        // Two notes a few ticks apart (a flam a user authored in the piano roll)
        // share one box. The cell is a boolean, so the honest answer is to empty
        // it — half-removing would leave a box that looks off and still sounds.
        let flam = [
            MIDINote(pitch: Self.snare, velocity: 100, startBeat: 1, lengthBeats: 0.25),
            MIDINote(pitch: Self.snare, velocity: 60, startBeat: 1.05, lengthBeats: 0.25),
            MIDINote(pitch: Self.kick, velocity: 100, startBeat: 1, lengthBeats: 0.25),
        ]
        let g = geometry(notes: flam)
        let cell = StepCell(step: 4, pitch: Self.snare)
        #expect(StepSequencerEdit.notes(in: flam, cell: cell, geometry: g).count == 2)
        let off = StepSequencerEdit.toggle(notes: flam, cell: cell, geometry: g)
        #expect(off.removed.count == 2)
        #expect(off.notes.count == 1)               // the kick in the same column stays
        #expect(off.notes[0].pitch == Self.kick)
        // Toggling back on returns ONE note at the snapped step — lossy, and
        // documented as such rather than silently rounded.
        let on = StepSequencerEdit.toggle(notes: off.notes, cell: cell, geometry: g)
        #expect(on.notes.filter { $0.pitch == Self.snare }.count == 1)
        #expect(on.added?.startBeat == 1.0)
    }

    @Test("toggling off a LONGER-than-a-step note removes the whole note")
    func toggleOffRemovesALongNoteEntirely() {
        // The grid has no column for a two-beat note's tail, so it cannot show a
        // length it cannot express — and half-deleting would be worse.
        let held = [MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 2)]
        let g = geometry(isDrumKit: false, notes: held)
        let off = StepSequencerEdit.toggle(
            notes: held, cell: StepCell(step: 0, pitch: 60), geometry: g)
        #expect(off.notes.isEmpty)
        #expect(off.removed.count == 1)
        // …and it comes back one step long, at velocity 100. Lossy in both
        // fields, named here so nobody reads the round-trip test as a promise
        // that covers this case.
        let on = StepSequencerEdit.toggle(
            notes: off.notes, cell: StepCell(step: 0, pitch: 60), geometry: g)
        #expect(on.notes[0].lengthBeats == 0.25)
        #expect(on.notes[0].velocity == 100)
    }

    @Test("an UNSNAPPED note occupies the box it starts in, and returns to it snapped")
    func unsnappedNotesOccupyTheirBox() {
        // A note the roll authored with snapping off, at beat 1.1 — inside step
        // 4's box (beats 1.0…1.25) but not on its line.
        let loose = [MIDINote(pitch: Self.kick, velocity: 100, startBeat: 1.1, lengthBeats: 0.3)]
        let g = geometry(notes: loose)
        let cell = StepCell(step: 4, pitch: Self.kick)
        #expect(StepSequencerEdit.filledCells(notes: loose, geometry: g) == [cell])
        let cycled = StepSequencerEdit.toggle(
            notes: StepSequencerEdit.toggle(notes: loose, cell: cell, geometry: g).notes,
            cell: cell, geometry: g)
        #expect(cycled.notes.count == 1)
        #expect(cycled.notes[0].startBeat == 1.0)       // snapped by the trip
        #expect(cycled.notes[0].lengthBeats == 0.25)
    }

    // MARK: - What the grid draws

    @Test("the drawn fills carry the loudest hit in a box, and ghost past the clip end")
    func fillsCarryVelocityAndLatency() {
        let notes = [
            MIDINote(pitch: Self.snare, velocity: 40, startBeat: 1, lengthBeats: 0.25),
            MIDINote(pitch: Self.snare, velocity: 120, startBeat: 1.05, lengthBeats: 0.25),
            // Past the clip end (4 beats) — store-legal, never sounded.
            MIDINote(pitch: Self.kick, velocity: 100, startBeat: 4.5, lengthBeats: 0.25),
        ]
        let g = geometry(notes: notes)
        let fills = StepSequencerEdit.fills(notes: notes, geometry: g)
        #expect(fills.count == 2)
        let snare = fills.first { $0.cell.pitch == Self.snare }
        #expect(snare?.velocity == 120)     // the quieter flam hit must not dim the box
        #expect(snare?.isLatent == false)
        let stranded = fills.first { $0.cell.pitch == Self.kick }
        #expect(stranded?.isLatent == true)
        #expect(stranded?.cell.step == 18)
        // `filledCells` derives from the same walk — one home for "is this box on".
        #expect(StepSequencerEdit.filledCells(notes: notes, geometry: g)
                == Set(fills.map(\.cell)))
    }

    @Test("cells sort step-major, high pitch first — an echoed pattern reads like the grid")
    func cellsSortLikeTheGrid() {
        let cells = [
            StepCell(step: 4, pitch: 36),
            StepCell(step: 0, pitch: 36),
            StepCell(step: 0, pitch: 42),
        ].sorted()
        #expect(cells == [
            StepCell(step: 0, pitch: 42),
            StepCell(step: 0, pitch: 36),
            StepCell(step: 4, pitch: 36),
        ])
    }

    // MARK: - ONE note store

    @MainActor
    @Test("the sequencer writes the SAME note the piano roll's add writes")
    func bothEditorsAuthorTheSameNote() {
        // The two editors must not disagree about what "a new note" is, or a
        // part authored in one would sound different from the same part
        // authored in the other.
        let roll = PianoRollModel(notes: [], clipLengthBeats: 4)
        let rollNote = roll.addNote(atBeat: 1, pitch: Self.kick, resolution: .sixteenth)
        let stepNote = StepSequencerEdit.toggle(
            notes: [], cell: StepCell(step: 4, pitch: Self.kick),
            geometry: geometry()).added
        #expect(stepNote?.pitch == rollNote.pitch)
        #expect(stepNote?.startBeat == rollNote.startBeat)
        #expect(stepNote?.lengthBeats == rollNote.lengthBeats)
        #expect(stepNote?.velocity == rollNote.velocity)
    }

    @MainActor
    @Test("replaceDraft is the sequencer's write path and prunes a dangling selection")
    func replaceDraftPrunesSelection() {
        let kept = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let doomed = MIDINote(pitch: 62, startBeat: 1, lengthBeats: 1)
        let model = PianoRollModel(notes: [kept, doomed], clipLengthBeats: 4)
        model.selection = [kept.id, doomed.id]
        model.replaceDraft([kept])
        #expect(model.draft.map(\.id) == [kept.id])
        // A selection naming a note that no longer exists would keep claiming
        // Edit ▸ Delete and the arrange's arrow keys for invisible content.
        #expect(model.selection == [kept.id])
    }

    // MARK: - The bridge (session state + the staging seam)

    @MainActor
    @Test("the bridge resolves the mode, latches the user's pick, and keeps the picked step")
    func bridgeResolvesAndLatches() {
        let bridge = StepSequencerBridge()
        #expect(bridge.mode(isDrumKit: true) == .steps)
        #expect(bridge.mode(isDrumKit: false) == .notes)
        bridge.setMode(.notes)
        #expect(bridge.mode(isDrumKit: true) == .notes)
        #expect(bridge.pickedResolution == .sixteenth)
        bridge.setResolution(.eighth)
        #expect(bridge.effectiveResolution(density: .pro) == .eighth)
        #expect(bridge.effectiveResolution(density: .simple) == .sixteenth)
        #expect(bridge.pickedResolution == .eighth)   // the lock never eats the pick
    }

    @MainActor
    @Test("a staged toggle bumps a nonce, so the same cell can be asked for twice")
    func bridgeStagesTogglesByNonce() {
        let bridge = StepSequencerBridge()
        let cell = StepCell(step: 3, pitch: 42)
        bridge.stageToggle(cell)
        #expect(bridge.stagedCell == cell)
        #expect(bridge.toggleNonce == 1)
        // On, then off: two requests carrying identical payloads. Without the
        // nonce the view's `.onChange` would never see the second one.
        bridge.stageToggle(cell)
        #expect(bridge.toggleNonce == 2)
    }

    @MainActor
    @Test("the bridge echoes only what a grid reported, and a teardown clears it")
    func bridgeEchoesTheDrawnGrid() {
        let bridge = StepSequencerBridge()
        // Before anything draws, the echo says "no grid" — never the mode the
        // seam asked for.
        bridge.setMode(.steps)
        #expect(bridge.reportedMode == .notes)
        #expect(bridge.reportedLanes.isEmpty)

        let g = geometry()
        let token = UUID()
        let fills = StepSequencerEdit.fills(
            notes: [MIDINote(pitch: Self.kick, startBeat: 0, lengthBeats: 0.25)], geometry: g)
        bridge.report(token: token, lanes: g.lanes, stepCount: g.stepCount,
                      stepBeats: g.stepBeats, fills: fills,
                      rowHeight: g.rowHeight, stepWidth: g.stepWidth)
        #expect(bridge.reportedMode == .steps)
        #expect(bridge.reportedStepCount == 16)
        #expect(bridge.reportedFilledCells == [StepCell(step: 0, pitch: Self.kick)])
        #expect(bridge.reportSeq == 1)

        bridge.reportNoGrid(from: token)
        #expect(bridge.reportedMode == .notes)
        #expect(bridge.reportedStepCount == 0)
        #expect(bridge.reportSeq == 2)
    }

    @MainActor
    @Test("a clip switch cannot blank a live grid — the report token beats the teardown race")
    func teardownCannotClearANewerGrid() {
        // `.id(clip.id)` rebuilds the editor on a clip switch, and SwiftUI does
        // not promise whether the outgoing view's `.onDisappear` or the incoming
        // one's first report runs first (measured for exactly this race in
        // m23-x). A clear that ignored ownership would leave the seam claiming
        // "no grid" while a grid is on screen.
        let bridge = StepSequencerBridge()
        let g = geometry()
        let outgoing = UUID()
        let incoming = UUID()
        bridge.report(token: outgoing, lanes: g.lanes, stepCount: g.stepCount,
                      stepBeats: g.stepBeats, fills: [],
                      rowHeight: g.rowHeight, stepWidth: g.stepWidth)
        // The NEW grid reports before the OLD one tears down…
        bridge.report(token: incoming, lanes: g.lanes, stepCount: 8,
                      stepBeats: 0.5, fills: [],
                      rowHeight: g.rowHeight, stepWidth: g.stepWidth)
        bridge.reportNoGrid(from: outgoing)
        #expect(bridge.reportedMode == .steps)
        #expect(bridge.reportedStepCount == 8)
        // …and the live grid's own teardown still clears.
        bridge.reportNoGrid(from: incoming)
        #expect(bridge.reportedMode == .notes)
    }
}
