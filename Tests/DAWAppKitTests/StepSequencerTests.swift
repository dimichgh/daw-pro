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

    // MARK: - m23-ap I5-F4: the columns are the SONG's grid cells

    /// The I5-F2 fixture's meter: 4/4 until beat 8, 3/4 after. Song bars: 1 at
    /// 0, 2 at 4, 3 at 8, 4 at 11, 5 at 14, 6 at 17.
    static let songMeter: MeterMap = {
        // A literal map the initialiser accepts (8 is a 4/4 bar line), so `try!`
        // cannot fire; a typo here fails every test loudly, never quietly.
        try! MeterMap(changes: [.init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
                                .init(startBeat: 8, beatsPerBar: 3, beatUnit: 4)])
    }()
    static let fourFour = MeterMap(constant: TimeSignature())

    /// A drum clip's geometry on the song's grid, starting at song beat `start`.
    private func songGeometry(start: Double, notes: [MIDINote] = [], lengthBeats: Double = 4,
                              resolution: SnapResolution = .sixteenth,
                              meter: MeterMap = StepSequencerTests.fourFour) -> StepSequencerGeometry {
        StepSequencerGeometry.make(
            isDrumKit: true, notes: notes, clipLengthBeats: lengthBeats, resolution: resolution,
            songGrid: PianoRollSongGrid.Context(clipStartBeat: start, meterMap: meter))
    }

    /// True when a SONG beat sits on a line of `grid` counted from song beat 0.
    private func onLine(_ songBeat: Double, _ grid: Double) -> Bool {
        let r = songBeat.truncatingRemainder(dividingBy: grid)
        return r < 1e-9 || grid - r < 1e-9
    }

    @Test("I5-F4 INVARIANCE — a clip that starts ON a line of its step grid counts, draws, hits, fills, toggles and places the playhead BIT-IDENTICALLY to the pre-I5-F4 clip-local grid (starts on odd steps, a triplet's 16, a large 1024; every pickable step but Bar)")
    func onGridColumnsAreBitIdentical() throws {
        let notes = [
            MIDINote(pitch: Self.kick, startBeat: 0, lengthBeats: 0.25),
            MIDINote(pitch: Self.snare, startBeat: 1.0 / 3.0, lengthBeats: 0.25),
            MIDINote(pitch: Self.kick, startBeat: 0.74, lengthBeats: 0.25),
            MIDINote(pitch: Self.snare, startBeat: 2.0 / 3.0, lengthBeats: 0.25),
            MIDINote(pitch: 42, startBeat: 3.99, lengthBeats: 0.25),
            MIDINote(pitch: 42, startBeat: 5, lengthBeats: 0.25),      // past the end: latent
        ]
        var failures: [String] = []
        var cases = 0
        for resolution in StepSequencerGeometry.pickableResolutions where resolution != .bar {
            let step = StepSequencerGeometry.stepBeats(for: resolution)
            let old = geometry(notes: notes, resolution: resolution)   // pre-I5-F4 signature: clip at 0, 4/4
            for start in [0, step, 3 * step, 5 * step, 4, 16, 1024] {
                let new = songGeometry(start: start, notes: notes, resolution: resolution)
                try #require(new.phaseBeats == 0, "fixture \(start) is off the \(resolution) grid")
                cases += 1
                let tag = "\(resolution)@\(start)"
                if new.stepCount != old.stepCount || new.stepBeats != old.stepBeats {
                    failures.append("\(tag) stepCount/stepBeats")
                }
                if new.clipEndX.native.bitPattern != old.clipEndX.native.bitPattern {
                    failures.append("\(tag) clipEndX")
                }
                if new.clipStartX != 0 { failures.append("\(tag) clipStartX") }
                for k in 0...old.stepCount
                    where new.beat(forStep: k).bitPattern != old.beat(forStep: k).bitPattern {
                    failures.append("\(tag) beat(forStep: \(k))")
                }
                for b in stride(from: 0.0, through: 6, by: 0.01)
                    where new.stepIndex(forBeat: b) != old.stepIndex(forBeat: b) {
                    failures.append("\(tag) stepIndex(\(b))")
                }
                if StepSequencerEdit.fills(notes: notes, geometry: new)
                    != StepSequencerEdit.fills(notes: notes, geometry: old) {
                    failures.append("\(tag) fills")
                }
                for k in [0, 1, 5, old.stepCount - 1] {
                    let cell = StepCell(step: k, pitch: 44)
                    let a = StepSequencerEdit.toggle(notes: notes, cell: cell, geometry: new).added
                    let b = StepSequencerEdit.toggle(notes: notes, cell: cell, geometry: old).added
                    if a?.startBeat.bitPattern != b?.startBeat.bitPattern
                        || a?.lengthBeats.bitPattern != b?.lengthBeats.bitPattern {
                        failures.append("\(tag) toggle \(k)")
                    }
                }
                // The view's pre-I5-F4 playhead: `lineX` on the step scale, unshifted.
                let was = PianoRollPlayhead.lineX(position: start + 1.5, clipStartBeat: start,
                                                  lengthBeats: 4,
                                                  pixelsPerBeat: old.stepWidth / CGFloat(old.stepBeats))
                let now = new.playheadX(position: start + 1.5, lengthBeats: 4)
                if now?.native.bitPattern != was?.native.bitPattern { failures.append("\(tag) playhead") }
            }
        }
        #expect(cases == (StepSequencerGeometry.pickableResolutions.count - 1) * 7)
        #expect(failures.isEmpty, "\(failures.count) differ, e.g. \(failures.prefix(6))")
    }

    @Test("I5-F4 INVARIANCE — on a BAR-aligned clip (bar 3 in 4/4) the bar and beat emphasis is the clip-local grid's, column for column; the bar NUMBERS are the song's (3, 4, … where the old grid read 1, 2, …)")
    func barAlignedEmphasisIsUnchangedAndNumbersAreTheSongs() {
        var failures: [String] = []
        for resolution in [SnapResolution.sixteenth, .eighth, .eighthTriplet, .beat, .bar] {
            let old = geometry(lengthBeats: 12, resolution: resolution)
            let new = songGeometry(start: 8, lengthBeats: 12, resolution: resolution)
            if new.stepCount != old.stepCount { failures.append("\(resolution) stepCount") }
            for k in 0..<old.stepCount {
                if new.isBarStart(step: k) != old.isBarStart(step: k) { failures.append("\(resolution) bar \(k)") }
                if new.isBeatStart(step: k) != old.isBeatStart(step: k) { failures.append("\(resolution) beat \(k)") }
                if new.barNumber(forStep: k) != old.barNumber(forStep: k) + 2 {
                    failures.append("\(resolution) number \(k)")
                }
            }
        }
        #expect(failures.isEmpty, "\(failures.prefix(6))")
    }

    @Test("I5-F4 — an OFF-GRID clip's columns are the SONG's cells: at 2.1 under 1/16, column 0 opens on song 2.0 (0.1 beat of it before the clip, shaded) and every column edge is a drawn line; the clip-counted edges were all 0.1 off")
    func offGridColumnEdgesAreSongLines() {
        let g = songGeometry(start: 2.1)                        // a 4-beat clip: song 2.1 … 6.1
        #expect(abs(g.phaseBeats - 0.1) < 1e-12)
        #expect(g.firstStepSongBeat == 2.0)
        #expect(g.stepCount == 17)                              // (4 + 0.1) / 0.25 = 16.4 → 17
        #expect(abs(g.clipStartX - 12) < 1e-9)                  // 0.1 beat at 120 pt per beat
        #expect(abs(g.clipEndX - 492) < 1e-9)                   // (4 + 0.1) · 120
        let edges = (0...g.stepCount).map { 2.1 + g.beat(forStep: $0) }
        #expect(edges.allSatisfy { onLine($0, 0.25) }, "\(edges)")
        // CONTROL — the clip-counted grid's edges sit 0.1 beat off every line.
        let old = geometry()
        #expect((0...old.stepCount).map { 2.1 + old.beat(forStep: $0) }.allSatisfy { !onLine($0, 0.25) })
    }

    @Test("I5-F4 — on an off-grid clip a note sits in the column its song line opens, a box writes its note ON that line, and column 0's box writes on the clip's first beat (notes clamp at 0) — both round-trip")
    func offGridTogglesWriteOnSongLines() throws {
        let g = songGeometry(start: 2.1)
        #expect(g.stepIndex(forBeat: 0) == 0)           // song 2.1, inside [2.0, 2.25)
        #expect(g.stepIndex(forBeat: 0.14) == 0)        // song 2.24
        #expect(g.stepIndex(forBeat: 0.15) == 1)        // song 2.25 opens column 1
        #expect(g.stepIndex(forBeat: 0.9) == 4)         // song 3.0
        let three = StepSequencerEdit.toggle(notes: [], cell: StepCell(step: 3, pitch: Self.kick), geometry: g)
        let written = try #require(three.added)
        #expect(abs(2.1 + written.startBeat - 2.75) < 1e-9, "\(2.1 + written.startBeat)")
        #expect(StepSequencerEdit.filledCells(notes: three.notes, geometry: g)
                == [StepCell(step: 3, pitch: Self.kick)])
        let zero = StepSequencerEdit.toggle(notes: [], cell: StepCell(step: 0, pitch: Self.snare), geometry: g)
        #expect(zero.added?.startBeat == 0)
        #expect(StepSequencerEdit.filledCells(notes: zero.notes, geometry: g)
                == [StepCell(step: 0, pitch: Self.snare)])
        let off = StepSequencerEdit.toggle(notes: zero.notes, cell: StepCell(step: 0, pitch: Self.snare), geometry: g)
        #expect(off.notes.isEmpty)
        // CONTROL — the clip-counted grid wrote column 3's note at song 2.85.
        let old = StepSequencerEdit.toggle(notes: [], cell: StepCell(step: 3, pitch: Self.kick), geometry: geometry())
        #expect(!onLine(2.1 + (old.added?.startBeat ?? 0), 0.25))
    }

    @Test("I5-F4 — bar lines and bar numbers are the SONG's through a meter change (clip at 2.5, 4/4 → 3/4 at 8): the columns over song 4, 8, 11, 14, 17 read bars 2…6 on a 1/16 grid AND on a triplet grid; the clip-counted stride put a bar every 16 columns from the clip's start")
    func barLinesAndNumbersAreTheSongs() {
        let sixteenths = songGeometry(start: 2.5, lengthBeats: 16, meter: Self.songMeter)
        #expect(sixteenths.phaseBeats == 0)
        #expect(sixteenths.barMarks == [StepBarMark(step: 6, bar: 2), StepBarMark(step: 22, bar: 3),
                                        StepBarMark(step: 34, bar: 4), StepBarMark(step: 46, bar: 5),
                                        StepBarMark(step: 58, bar: 6)], "\(sixteenths.barMarks)")
        // Beat emphasis on whole SONG beats: 2.5 + k/4 is whole for k = 2, 6, 10.
        #expect((0..<12).filter { sixteenths.isBeatStart(step: $0) } == [2, 6, 10])
        // Triplets: column 0 opens on song 7/3 (phase 1/6); the bars are song
        // steps 12, 24, 33, 42, 51 — found by integer arithmetic, where a float
        // song beat would read 3.9999999999999996 and miss bar 2.
        let triplets = songGeometry(start: 2.5, lengthBeats: 16, resolution: .eighthTriplet,
                                    meter: Self.songMeter)
        #expect(abs(triplets.phaseBeats - 1.0 / 6.0) < 1e-12)
        #expect(triplets.barMarks.map(\.step) == [5, 17, 26, 35, 44], "\(triplets.barMarks)")
        #expect(triplets.barMarks.map(\.bar) == [2, 3, 4, 5, 6])
        // CONTROL — the clip-counted stride.
        let old = geometry(lengthBeats: 16)
        #expect((0..<old.stepCount).filter { old.isBarStart(step: $0) } == [0, 16, 32, 48])
    }

    @Test("I5-F4 — a BAR column is one bar of the meter the clip starts in (3 beats in 3/4; 4 in 4/4, unchanged), measured from the song's bar line")
    func barColumnsAreMeterAware() {
        let threeFour = MeterMap(constant: TimeSignature(beatsPerBar: 3))
        let onBar = songGeometry(start: 3, lengthBeats: 9, resolution: .bar, meter: threeFour)
        #expect(onBar.stepBeats == 3)
        #expect(onBar.phaseBeats == 0)
        #expect(onBar.stepCount == 3)
        #expect((0..<3).map { onBar.barNumber(forStep: $0) } == [2, 3, 4])
        let offBar = songGeometry(start: 4, lengthBeats: 9, resolution: .bar, meter: threeFour)
        #expect(offBar.phaseBeats == 1)
        #expect(offBar.firstStepSongBeat == 3)
        #expect(songGeometry(start: 0, lengthBeats: 8, resolution: .bar).stepBeats == 4)
        // Across a meter change a column stays one bar of the STARTING meter —
        // uniform columns cannot re-space (documented on `columnPlacement`).
        #expect(songGeometry(start: 4, lengthBeats: 12, resolution: .bar,
                             meter: Self.songMeter).stepBeats == 4)
    }

    @Test("I5-F4 — the step grid's playhead moves right by the partial column 0, so it crosses the column holding its beat; nil outside the clip, as before")
    func playheadShiftsByTheLeadingColumn() throws {
        let g = songGeometry(start: 2.1)                        // 120 pt per beat
        let atClipStart = try #require(g.playheadX(position: 2.1, lengthBeats: 4))
        #expect(abs(atClipStart - 12) < 1e-9)
        let atLine = try #require(g.playheadX(position: 2.25, lengthBeats: 4))
        #expect(abs(atLine - g.x(forStep: 1)) < 1e-9)           // song 2.25 is column 1's edge
        #expect(g.playheadX(position: 1.0, lengthBeats: 4) == nil)
        #expect(g.playheadX(position: 7.0, lengthBeats: 4) == nil)
    }

    @Test("I5-F4 — the pre-I5-F4 `make(…beatsPerBar:)` IS the song-grid geometry of a clip at song beat 0 in one meter")
    func oldSignatureForwardsToTheSongGrid() {
        for resolution in StepSequencerGeometry.pickableResolutions {
            for bpb in [3, 4, 7] {
                let old = StepSequencerGeometry.make(isDrumKit: false, notes: [], clipLengthBeats: 8,
                                                     resolution: resolution, beatsPerBar: bpb)
                let new = StepSequencerGeometry.make(
                    isDrumKit: false, notes: [], clipLengthBeats: 8, resolution: resolution,
                    songGrid: .init(clipStartBeat: 0,
                                    meterMap: MeterMap(constant: TimeSignature(beatsPerBar: bpb))))
                #expect(old == new, "\(resolution) \(bpb)")
            }
        }
    }

    @MainActor
    @Test("I5-F4 — the bridge carries the grid's song placement (phase, column 0's song beat, the bar marks) and a teardown clears it")
    func bridgeEchoesTheSongPlacement() {
        let bridge = StepSequencerBridge()
        let g = songGeometry(start: 2.1, lengthBeats: 8)
        let token = UUID()
        bridge.report(token: token, lanes: g.lanes, stepCount: g.stepCount, stepBeats: g.stepBeats,
                      fills: [], rowHeight: g.rowHeight, stepWidth: g.stepWidth,
                      phaseBeats: g.phaseBeats, firstStepSongBeat: g.firstStepSongBeat,
                      barMarks: g.barMarks)
        #expect(abs(bridge.reportedPhaseBeats - 0.1) < 1e-12)
        #expect(bridge.reportedFirstStepSongBeat == 2.0)
        #expect(bridge.reportedBarMarks == [StepBarMark(step: 8, bar: 2), StepBarMark(step: 24, bar: 3)])
        bridge.reportNoGrid(from: token)
        #expect(bridge.reportedPhaseBeats == 0)
        #expect(bridge.reportedFirstStepSongBeat == 0)
        #expect(bridge.reportedBarMarks.isEmpty)
    }

    @Test("I5-F4 round 3 — a clip far out (2.4e18 beats up to the largest Double) builds its step geometry without trapping: past 2^53 song steps the lattice is dropped (no song emphasis, no meter lookups) and columns still count and hit; below it the lattice is kept")
    func farOutClipsKeepTheGeometryTotal() {
        let notes = [MIDINote(pitch: Self.kick, startBeat: 0, lengthBeats: 0.25),
                     MIDINote(pitch: Self.snare, startBeat: 1, lengthBeats: 0.25)]
        for resolution in [SnapResolution.sixteenth, .thirtySecond, .sixteenthTriplet, .beat] {
            for start in [2.4e18, 1e19, 1e300, Double.greatestFiniteMagnitude] {
                let g = songGeometry(start: start, notes: notes, resolution: resolution)
                #expect(g.stepsPerWholeBeat == nil, "\(resolution) at \(start)")
                #expect(g.firstStepIndex == 0)
                #expect(g.stepCount > 0 && g.phaseBeats.isFinite)
                #expect(g.barMarks.isEmpty)
                #expect((0..<g.stepCount).allSatisfy { !g.isBarStart(step: $0) })
                #expect((0..<g.stepCount).map { g.isBeatStart(step: $0) }.count == g.stepCount)
                #expect(g.stepIndex(forBeat: 1) >= 0)
            }
        }
        // CONTROL: below 2^53 the lattice is kept, so the drop above is the guard's.
        let kept = songGeometry(start: 1024, notes: notes, resolution: .sixteenth)
        #expect(kept.stepsPerWholeBeat == 4)
        #expect(!kept.barMarks.isEmpty)
    }

    @Test("I5-F4 round 4 — a note or a clip end out past any grid (a note 2.4e18 beats in at 1/16, 1e300, the largest Double, an infinite clip) builds a grid of at most maximumStepCount (2^20) columns without trapping, and stepIndex answers such a beat with a step no column has; nothing past the grid fills a cell")
    func farNotesKeepTheStepGridTotal() {
        #expect(StepSequencerGeometry.maximumStepCount == 1 << 20)
        for resolution in [SnapResolution.sixteenth, .sixtyFourth, .sixteenthTriplet, .bar] {
            for far in [2.4e18, 1e300, Double.greatestFiniteMagnitude] {
                let notes = [MIDINote(pitch: Self.kick, startBeat: 0, lengthBeats: 0.25),
                             MIDINote(pitch: Self.snare, startBeat: far, lengthBeats: 0.25)]
                let g = geometry(notes: notes, resolution: resolution)
                #expect(g.stepCount == StepSequencerGeometry.maximumStepCount, "\(resolution) \(far)")
                let step = g.stepIndex(forBeat: far)
                #expect(step >= g.stepCount, "\(resolution) \(far): \(step)")
                let cells = StepSequencerEdit.fills(notes: notes, geometry: g).map { $0.cell }
                #expect(cells == [StepCell(step: 0, pitch: Self.kick)])
            }
            let endless = geometry(lengthBeats: .infinity, resolution: resolution)
            #expect(endless.stepCount == StepSequencerGeometry.maximumStepCount)
            let g = geometry(resolution: resolution)
            #expect(g.stepIndex(forBeat: .infinity) == Int.max)
            #expect(g.stepIndex(forBeat: 1e300) == Int.max)
            #expect(g.stepIndex(forBeat: -1e300) == Int.min)
            #expect(g.stepIndex(forBeat: -.infinity) == Int.min)
            #expect(g.stepIndex(forBeat: .nan) == Int.min)
        }
    }

    @Test("I5-F4 round 4 — every grid below the cap keeps the count it had: exactly 2^20 columns (the cap itself) and one fewer are unchanged, one more is held at the cap, and stepIndex answers every finite beat below 2^63 steps as the plain formula does")
    func stepGridBelowTheCapIsUnchanged() {
        // 1/16 steps are 0.25 beat: 2^20 columns span exactly 262144 beats.
        let atCap = geometry(lengthBeats: 0.25 * 1_048_576)
        #expect(atCap.stepCount == 1_048_576)
        #expect(geometry(lengthBeats: 0.25 * 1_048_575).stepCount == 1_048_575)
        #expect(geometry(lengthBeats: 0.25 * 1_048_577).stepCount == 1_048_576)   // the one change
        for lengthBeats in [0.0, 0.1, 1, 4, 4.1, 16, 1000.3, 65_536] {
            for resolution in StepSequencerGeometry.pickableResolutions {
                let g = geometry(lengthBeats: lengthBeats, resolution: resolution)
                let plain = max(1, Int(((max(lengthBeats, g.stepBeats) + g.phaseBeats) / g.stepBeats
                                        - 1e-9).rounded(.up)))
                if plain <= StepSequencerGeometry.maximumStepCount {
                    #expect(g.stepCount == plain, "\(lengthBeats) \(resolution)")
                }
            }
        }
        let g = geometry(resolution: .sixteenth)
        for beat in [0.0, 0.2, 0.25, 0.26, 3.99, 1e6 + 0.1, 1e15, 2e18, -0.3, -2e18] {
            let scaled = (beat + g.phaseBeats) / g.stepBeats
            let nearest = scaled.rounded()
            let plain = abs(scaled - nearest) < 1e-6 ? Int(nearest) : Int(scaled.rounded(.down))
            #expect(g.stepIndex(forBeat: beat) == plain, "\(beat)")
        }
    }
}

// MARK: - m39-w4-3: entry velocity in one home, and the Accent row

/// `docs/design/2026-10-07-loop-drum-depth.md` §3.4–§3.6, §9.2 `m39-w4-3`.
/// Appended to this suite (no new `@Suite`): the `PianoRollModel` legs are
/// `@MainActor` per test, which the suite census does not count.
///
/// The gates hold a FIXTURE drum velocity of 80. At the shipped 100 the drum and
/// melodic answers coincide, so only a fixture that differs can tell "both
/// editors read `NoteEntryDefaults`" from "both still carry a literal 100".
extension StepSequencerTests {

    static let w43Fixture = NoteEntryDefaults.Values(drumVelocity: 80)
    /// Our drum machine in its default `pads` layout: the track `isDrumKit`
    /// answers "no" for and the lane map answers with eight rows.
    static let w43PadsLanes = DrumLaneMap.lanes(for: InstrumentDescriptor(kind: .drumSynth))
    static let w43GMKitLanes = DrumLaneMap.lanes(for: InstrumentDescriptor(
        kind: .soundBank,
        soundBank: SoundBankConfig(source: .generalMIDI, program: 0,
                                   bankMSB: GMProgramCatalog.percussionBankMSB)))
    static let w43GMLayoutLanes = DrumLaneMap.lanes(for: InstrumentDescriptor(
        kind: .drumSynth, drumKit: DrumKitParams(noteLayout: .gm)))

    /// A 4-beat 4/4 clip at 1/16 on the song's beat 0: 16 columns.
    static func w43Grid(_ drumLanes: [DrumLane]?, notes: [MIDINote] = []) -> StepSequencerGeometry {
        StepSequencerGeometry.make(
            drumLanes: drumLanes, notes: notes, clipLengthBeats: 4, resolution: .sixteenth,
            songGrid: PianoRollSongGrid.Context(clipStartBeat: 0,
                                                meterMap: MeterMap(constant: TimeSignature())))
    }

    static func w43Note(_ lanes: [DrumLane]?, _ voice: DrumVoice) throws -> Int {
        try #require(lanes?.first { $0.voice == voice }?.note)
    }

    /// Clicks `cells` (step, pitch) in order on `grid`, as a user would.
    static func w43Click(_ cells: [(Int, Int)], on grid: StepSequencerGeometry,
                         entry: NoteEntryDefaults.Values = .shipped,
                         into start: [MIDINote] = []) -> [MIDINote] {
        var notes = start
        for (step, pitch) in cells {
            notes = StepSequencerEdit.toggle(notes: notes, cell: StepCell(step: step, pitch: pitch),
                                             geometry: grid, entry: entry).notes
        }
        return notes
    }

    // MARK: P1 + the plant-3 target: both editors read the one function

    @MainActor
    @Test("m39-w4-3 P1 — both editors mint through the ONE entry function: with a fixture drum velocity of 80, a hit on our pads drum machine is 80 in the step grid AND the piano roll, and a melodic note is 100 in both")
    func bothEditorsReadTheOneEntryFunction() throws {
        let fixture = Self.w43Fixture
        let pads = try #require(Self.w43PadsLanes)
        let kick = try Self.w43Note(pads, .kick)

        let drumGrid = Self.w43Grid(pads)
        let stepHit = StepSequencerEdit.toggle(notes: [], cell: StepCell(step: 0, pitch: kick),
                                               geometry: drumGrid, entry: fixture).added
        #expect(stepHit?.velocity == 80)

        let roll = PianoRollModel(notes: [], clipLengthBeats: 4)
        let rollHit = roll.addNote(atBeat: 0, pitch: kick, resolution: .sixteenth,
                                   drumLanes: pads, entry: fixture)
        #expect(rollHit.velocity == 80)

        // The same melodic fixture, both editors: the melodic default.
        let melodicGrid = Self.w43Grid(nil)
        let stepMelodic = StepSequencerEdit.toggle(notes: [], cell: StepCell(step: 0, pitch: 60),
                                                   geometry: melodicGrid, entry: fixture).added
        #expect(stepMelodic?.velocity == 100)
        let rollMelodic = roll.addNote(atBeat: 1, pitch: 60, resolution: .sixteenth,
                                       drumLanes: nil, entry: fixture)
        #expect(rollMelodic.velocity == 100)

        // The two editors author the SAME note on the same track (the law at
        // `StepSequencerEdit.defaultVelocity`, now by construction).
        #expect(stepHit?.velocity == rollHit.velocity)
        #expect(stepHit?.pitch == rollHit.pitch)
        #expect(stepHit?.startBeat == rollHit.startBeat)
        #expect(stepHit?.lengthBeats == rollHit.lengthBeats)
    }

    // MARK: I1: zero behaviour change at the shipped values

    @MainActor
    @Test("m39-w4-3 I1 — at the shipped values a note toggled on in either editor, on any track, is born at 100, exactly as before the item")
    func shippedEntryVelocityUnchangedInBothEditors() throws {
        let roll = PianoRollModel(notes: [], clipLengthBeats: 4)
        for (name, lanes) in [("pads drum machine", Self.w43PadsLanes),
                              ("gm-layout drum machine", Self.w43GMLayoutLanes),
                              ("GM percussion bank", Self.w43GMKitLanes),
                              ("melodic", nil)] {
            let pitch = lanes?.first?.note ?? 60
            let stepHit = StepSequencerEdit.toggle(notes: [], cell: StepCell(step: 3, pitch: pitch),
                                                   geometry: Self.w43Grid(lanes)).added
            #expect(stepHit?.velocity == 100, "\(name) step grid")
            #expect(roll.addNote(atBeat: 2, pitch: pitch, resolution: .sixteenth,
                                 drumLanes: lanes).velocity == 100, "\(name) piano roll")
        }
        // The roll's old call shape (no lane list) is the melodic default, 100.
        #expect(roll.addNote(atBeat: 3, pitch: 64, resolution: .beat).velocity == 100)
        #expect(StepSequencerEdit.defaultVelocity == 100)
    }

    // MARK: The Accent row: read

    @Test("m39-w4-3 — the Accent row reads the accent CONSTANT, never the kit's threshold: a beat clicked in at the shipped 100 lights NO column; an all-127 column is on, a 127 + 100 column is mixed, a column with no hit is empty")
    func accentReadsTheConstantNotTheKitThreshold() throws {
        let pads = try #require(Self.w43PadsLanes)
        let grid = Self.w43Grid(pads)
        let kick = try Self.w43Note(pads, .kick)
        let snare = try Self.w43Note(pads, .snare)
        let hat = try Self.w43Note(pads, .closedHat)
        let beat = Self.w43Click([(0, kick), (8, kick), (4, snare), (12, snare)]
                                 + stride(from: 0, to: 16, by: 2).map { ($0, hat) }, on: grid)
        // Premises: every hit was born at the shipped 100, which the kit's
        // default threshold (100) would call accented.
        #expect(beat.count == 12)
        #expect(beat.allSatisfy { $0.velocity == 100 })
        #expect(DrumKitParams().accentThreshold == 100)

        let columns = StepAccent.columns(notes: beat, geometry: grid)
        #expect(columns.map(\.step) == [0, 2, 4, 6, 8, 10, 12, 14])
        #expect(columns.allSatisfy { $0.state == .off }, "no column is accented until the user asks")
        #expect(StepAccent.state(notes: beat, step: 1, geometry: grid) == .empty)

        // On: every hit in column 0 at 127.
        let accented = beat.map { note -> MIDINote in
            var n = note
            if grid.stepIndex(forBeat: n.startBeat) == 0 { n.velocity = 127 }
            if grid.stepIndex(forBeat: n.startBeat) == 4, n.pitch == snare { n.velocity = 127 }
            return n
        }
        #expect(StepAccent.state(notes: accented, step: 0, geometry: grid) == .on)
        // Mixed: column 4 holds a 127 snare and a 100 hat.
        #expect(StepAccent.state(notes: accented, step: 4, geometry: grid) == .mixed)
        #expect(StepAccent.state(notes: accented, step: 2, geometry: grid) == .off)
        #expect(StepAccent.columns(notes: accented, geometry: grid).first { $0.step == 4 }?.state == .mixed)
        #expect(StepAccent.columns(notes: accented, geometry: grid).first { $0.step == 0 }?.state == .on)
    }

    // MARK: The Accent row: write

    @Test("m39-w4-3 — clicking an Accent cell lifts every hit in that column to 127 and nothing else; clicking again returns them to the drum default (fixture 80); a mixed column goes to 127; a column with no hit answers nil (no commit)")
    func accentColumnToggleWritesEveryHitInTheColumn() throws {
        let fixture = Self.w43Fixture
        let pads = try #require(Self.w43PadsLanes)
        let grid = Self.w43Grid(pads)
        let kick = try Self.w43Note(pads, .kick)
        let snare = try Self.w43Note(pads, .snare)
        let hat = try Self.w43Note(pads, .closedHat)
        let beat = Self.w43Click([(0, kick), (0, hat), (4, snare), (4, hat)], on: grid, entry: fixture)
        #expect(beat.allSatisfy { $0.velocity == 80 })

        let on = try #require(StepAccent.toggle(notes: beat, step: 0, geometry: grid, entry: fixture))
        #expect(on.count == beat.count)
        for (before, after) in zip(beat, on) {
            #expect(after.id == before.id)
            #expect(after.pitch == before.pitch)
            #expect(after.startBeat == before.startBeat)
            #expect(after.lengthBeats == before.lengthBeats)
            let inColumn = grid.stepIndex(forBeat: before.startBeat) == 0
            #expect(after.velocity == (inColumn ? 127 : 80), "pitch \(before.pitch)")
        }
        #expect(StepAccent.state(notes: on, step: 0, geometry: grid, entry: fixture) == .on)

        let off = try #require(StepAccent.toggle(notes: on, step: 0, geometry: grid, entry: fixture))
        #expect(off == beat, "a second click returns the column to the drum default")

        var mixed = beat
        let snareIndex = try #require(mixed.firstIndex { $0.pitch == snare })
        mixed[snareIndex].velocity = 127
        #expect(StepAccent.state(notes: mixed, step: 4, geometry: grid, entry: fixture) == .mixed)
        let lifted = try #require(StepAccent.toggle(notes: mixed, step: 4, geometry: grid, entry: fixture))
        #expect(StepAccent.hits(in: lifted, step: 4, geometry: grid).map(\.velocity) == [127, 127])

        #expect(StepAccent.toggle(notes: beat, step: 1, geometry: grid, entry: fixture) == nil)
        // A melodic grid has no Accent row: nothing to click, nothing written.
        let melodicNotes = [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 0.25)]
        let melodic = Self.w43Grid(nil, notes: melodicNotes)
        #expect(StepAccent.toggle(notes: melodicNotes, step: 0, geometry: melodic) == nil)
    }

    @Test("m39-w4-3 — a hit toggled on in a fully accented column is born at 127; in a mixed column at the drum default; on a melodic grid an all-127 column means nothing and a new note takes the melodic default")
    func aHitBornInAnAccentedColumnIsAccented() throws {
        let fixture = Self.w43Fixture
        let pads = try #require(Self.w43PadsLanes)
        let grid = Self.w43Grid(pads)
        let kick = try Self.w43Note(pads, .kick)
        let snare = try Self.w43Note(pads, .snare)
        let hat = try Self.w43Note(pads, .closedHat)
        let beat = Self.w43Click([(0, kick), (4, snare), (4, hat)], on: grid, entry: fixture)
        let column0On = try #require(StepAccent.toggle(notes: beat, step: 0, geometry: grid, entry: fixture))
        let bornOn = StepSequencerEdit.toggle(notes: column0On, cell: StepCell(step: 0, pitch: hat),
                                              geometry: grid, entry: fixture).added
        #expect(bornOn?.velocity == 127)

        var mixed = beat
        let snareIndex = try #require(mixed.firstIndex { $0.pitch == snare })
        mixed[snareIndex].velocity = 127
        let bornMixed = StepSequencerEdit.toggle(notes: mixed, cell: StepCell(step: 4, pitch: kick),
                                                 geometry: grid, entry: fixture).added
        #expect(bornMixed?.velocity == 80)

        let loud = [MIDINote(pitch: 60, velocity: 127, startBeat: 0, lengthBeats: 0.25)]
        let melodic = Self.w43Grid(nil, notes: loud)
        let bornMelodic = StepSequencerEdit.toggle(notes: loud, cell: StepCell(step: 0, pitch: 62),
                                                   geometry: melodic, entry: fixture).added
        #expect(bornMelodic?.velocity == 100)
        #expect(StepAccent.columns(notes: loud, geometry: melodic).isEmpty)
    }

    // MARK: Where the row exists, and its hit test

    @Test("m39-w4-3 — only drum grids carry an Accent row: the geometry keeps the lane list its rows came from (pads and gm drum machine, GM kit), and a melodic grid keeps nil; the pre-w4-2 Bool forms agree")
    func onlyDrumGridsCarryAnAccentRow() throws {
        for lanes in [Self.w43PadsLanes, Self.w43GMLayoutLanes, Self.w43GMKitLanes] {
            let grid = Self.w43Grid(lanes)
            #expect(lanes != nil)
            #expect(grid.drumLanes == lanes)
            #expect(StepAccent.hasRow(grid))
            #expect(grid.opensAtBottom == StepAccent.hasRow(grid))
        }
        let melodic = Self.w43Grid(nil)
        #expect(melodic.drumLanes == nil)
        #expect(!StepAccent.hasRow(melodic))
        #expect(StepAccent.hasRow(geometry(isDrumKit: true)))
        #expect(!StepAccent.hasRow(geometry(isDrumKit: false)))
        #expect(geometry(isDrumKit: true).drumLanes == DrumLaneMap.generalMIDIPercussionLanes)
    }

    @Test("m39-w4-3 — the Accent row reads only columns the grid draws: onsets past the last column, before the first, or on a pitch with no row are not in any column; the row's hit test is the grid's")
    func accentIgnoresOnsetsOutsideTheGrid() throws {
        let pads = try #require(Self.w43PadsLanes)
        let kick = try Self.w43Note(pads, .kick)
        let grid = Self.w43Grid(pads)            // built with no notes: 16 columns
        #expect(grid.stepCount == 16)
        let notes = [MIDINote(pitch: kick, startBeat: 0, lengthBeats: 0.25),
                     MIDINote(pitch: 90, startBeat: 0, lengthBeats: 0.25),     // no row on this grid
                     MIDINote(pitch: kick, startBeat: 5, lengthBeats: 0.25)]   // past column 15
        #expect(StepAccent.hits(in: notes, step: 0, geometry: grid).map(\.pitch) == [kick])
        #expect(StepAccent.hits(in: notes, step: 20, geometry: grid).isEmpty)
        #expect(StepAccent.hits(in: notes, step: -1, geometry: grid).isEmpty)
        #expect(StepAccent.columns(notes: notes, geometry: grid).map(\.step) == [0])

        let w = grid.stepWidth
        #expect(StepAccent.step(atX: -1, geometry: grid) == nil)
        #expect(StepAccent.step(atX: 0, geometry: grid) == 0)
        #expect(StepAccent.step(atX: w * 15.5, geometry: grid) == 15)
        #expect(StepAccent.step(atX: grid.contentWidth, geometry: grid) == nil)
        for step in 0..<grid.stepCount {
            let x = grid.x(forStep: step) + w / 2
            #expect(StepAccent.step(atX: x, geometry: grid)
                    == grid.cell(at: CGPoint(x: x, y: 0))?.step)
        }
    }

    // MARK: I2: opening a saved drum clip changes nothing

    @Test("m39-w4-3 I2 — opening a saved drum clip and reading it through the grid and the Accent row changes nothing: the decoded notes re-encode to the same bytes, and a stored note with no velocity still decodes at 100 whatever the entry defaults say")
    func openingADrumClipChangesNothing() throws {
        let pads = try #require(Self.w43PadsLanes)
        let kick = try Self.w43Note(pads, .kick)
        let snare = try Self.w43Note(pads, .snare)
        let saved = Clip(name: "Beat", startBeat: 0, lengthBeats: 4, notes: [
            MIDINote(pitch: kick, velocity: 100, startBeat: 0, lengthBeats: 0.25),
            MIDINote(pitch: snare, velocity: 127, startBeat: 1, lengthBeats: 0.25),
            MIDINote(pitch: kick, velocity: 64, startBeat: 2, lengthBeats: 0.25),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(saved)
        let opened = try JSONDecoder().decode(Clip.self, from: bytes)
        let notes = try #require(opened.notes)
        let grid = Self.w43Grid(pads, notes: notes)
        _ = StepSequencerEdit.fills(notes: notes, geometry: grid)
        _ = StepAccent.columns(notes: notes, geometry: grid)
        #expect(notes == saved.notes)
        #expect(try encoder.encode(opened) == bytes)

        // The decode default is STORAGE, not entry: a note saved without a
        // velocity key reads 100 even with a drum entry default of 80.
        let bare = Data(#"{"pitch":36,"startBeat":0,"lengthBeats":0.25}"#.utf8)
        #expect(try JSONDecoder().decode(MIDINote.self, from: bare).velocity == 100)
        #expect(Self.w43Fixture.drumVelocity == 80)
    }
}
