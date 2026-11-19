import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless piano-roll geometry + edit model. The SwiftUI
/// views are thin over this, so exercising it here covers the editor's logic
/// without a display.
@MainActor
@Suite("PianoRollModel")
struct PianoRollModelTests {

    /// A model at the default 32 pt/beat, 14 pt/row scale.
    private func makeModel(notes: [MIDINote] = [], length: Double = 8) -> PianoRollModel {
        PianoRollModel(notes: notes, clipLengthBeats: length)
    }

    // 1. Snap: every resolution, including off, from below and above a grid line.
    @Test("snap rounds to the nearest grid line for each resolution")
    func snapAllResolutions() {
        let m = makeModel()
        // off passes through, floored at 0.
        #expect(m.snap(beat: 2.37, resolution: .off) == 2.37)
        #expect(m.snap(beat: -5, resolution: .off) == 0)
        // bar = 4 beats.
        #expect(m.snap(beat: 5.9, resolution: .bar) == 4)
        #expect(m.snap(beat: 6.1, resolution: .bar) == 8)
        // beat = 1.
        #expect(m.snap(beat: 2.4, resolution: .beat) == 2)
        #expect(m.snap(beat: 2.6, resolution: .beat) == 3)
        // eighth = 0.5.
        #expect(m.snap(beat: 1.2, resolution: .eighth) == 1.0)
        #expect(m.snap(beat: 1.3, resolution: .eighth) == 1.5)
        // sixteenth = 0.25.
        #expect(m.snap(beat: 0.30, resolution: .sixteenth) == 0.25)
        #expect(m.snap(beat: 0.40, resolution: .sixteenth) == 0.5)
        // m21-c finer divisions: thirtySecond = 0.125, sixtyFourth = 0.0625.
        #expect(m.snap(beat: 0.19, resolution: .thirtySecond) == 0.25)
        #expect(m.snap(beat: 0.18, resolution: .thirtySecond) == 0.125)
        #expect(m.snap(beat: 0.10, resolution: .sixtyFourth) == 0.125)
        #expect(m.snap(beat: 0.08, resolution: .sixtyFourth) == 0.0625)
        // never negative.
        #expect(m.snap(beat: -1, resolution: .beat) == 0)
    }

    // 1b. m21-c triplet snap math: 1/8T = 1/3 beat, 1/16T = 1/6 beat — three
    //    even notes in the straight pair's span, landing back on every beat.
    @Test("m21-c triplet snaps land on thirds and sixths of a beat")
    func snapTriplets() {
        let m = makeModel()
        #expect(abs(SnapResolution.eighthTriplet.beats! - 1.0 / 3.0) < 1e-12)
        #expect(abs(SnapResolution.sixteenthTriplet.beats! - 1.0 / 6.0) < 1e-12)
        // 1/8T: 0.4 → nearest third = 1/3; 0.55 → 2/3; 0.9 → the beat itself.
        #expect(abs(m.snap(beat: 0.4, resolution: .eighthTriplet) - 1.0 / 3.0) < 1e-9)
        #expect(abs(m.snap(beat: 0.55, resolution: .eighthTriplet) - 2.0 / 3.0) < 1e-9)
        #expect(abs(m.snap(beat: 0.9, resolution: .eighthTriplet) - 1.0) < 1e-9)
        // 1/16T: sixths are 0.1667 / 0.3333 / 0.5 … — 0.1 → 1/6, 0.26 → 2/6
        // (0.26 sits nearer 0.3333 than 0.1667; a straight 1/4 is NOT on this grid).
        #expect(abs(m.snap(beat: 0.1, resolution: .sixteenthTriplet) - 1.0 / 6.0) < 1e-9)
        #expect(abs(m.snap(beat: 0.26, resolution: .sixteenthTriplet) - 2.0 / 6.0) < 1e-9)
        // A triplet grid still contains every whole beat (k·grid lands on beats).
        #expect(abs(m.snap(beat: 2.01, resolution: .eighthTriplet) - 2.0) < 1e-9)
        #expect(abs(m.snap(beat: 3.99, resolution: .sixteenthTriplet) - 4.0) < 1e-9)
    }

    // 2. defaultLength per resolution (1 grid cell; 1 beat when off) — the ADD
    //    default only; the resize floor is minResizeLength (m21-c).
    @Test("defaultLength is one grid cell, one beat when snapping is off")
    func defaultLength() {
        let m = makeModel()
        #expect(m.defaultLength(for: .off) == 1.0)
        #expect(m.defaultLength(for: .bar) == 4)
        #expect(m.defaultLength(for: .beat) == 1)
        #expect(m.defaultLength(for: .eighth) == 0.5)
        #expect(m.defaultLength(for: .sixteenth) == 0.25)
        #expect(m.defaultLength(for: .thirtySecond) == 0.125)
        #expect(m.defaultLength(for: .sixtyFourth) == 0.0625)
        #expect(abs(m.defaultLength(for: .eighthTriplet) - 1.0 / 3.0) < 1e-12)
        #expect(abs(m.defaultLength(for: .sixteenthTriplet) - 1.0 / 6.0) < 1e-12)
    }

    // 2b. m21-c: the resize floor is ONE grid step of the current snap — and
    //    with snap OFF it is the store's own minimum, NOT the 1-beat add
    //    default (the old conflation made short AI-authored notes viewable but
    //    not editable).
    @Test("m21-c minResizeLength is one grid step; snap off floors at the store minimum")
    func minResizeLength() {
        let m = makeModel()
        #expect(m.minResizeLength(for: .off) == MIDINote.minLengthBeats)
        #expect(m.minResizeLength(for: .bar) == 4)
        #expect(m.minResizeLength(for: .beat) == 1)
        #expect(m.minResizeLength(for: .sixteenth) == 0.25)
        #expect(m.minResizeLength(for: .sixtyFourth) == 0.0625)
        #expect(abs(m.minResizeLength(for: .sixteenthTriplet) - 1.0 / 6.0) < 1e-12)
    }

    // 3. beat <-> x round trip.
    @Test("beat<->x round-trips at the fixed scale")
    func beatXRoundTrip() {
        let m = makeModel()
        #expect(m.x(forBeat: 3.5) == 3.5 * PianoRollModel.defaultPixelsPerBeat)
        for beat in [0.0, 1.0, 2.25, 3.5, 16.0] {
            #expect(abs(m.beat(forX: m.x(forBeat: beat)) - beat) < 1e-9)
        }
    }

    // 4. pitch <-> y round trip (high pitch at top).
    @Test("pitch<->y round-trips, pitch 127 at the top row")
    func pitchYRoundTrip() {
        let m = makeModel()
        #expect(m.y(forPitch: 127) == 0)                       // top row
        #expect(m.y(forPitch: 0) == 127 * PianoRollModel.defaultRowHeight)
        for pitch in [0, 24, 60, 96, 127] {
            // Sample the middle of the row so floor() lands back on it.
            let midY = m.y(forPitch: pitch) + PianoRollModel.defaultRowHeight / 2
            #expect(m.pitch(forY: midY) == pitch)
        }
        // Out-of-range y clamps to the pitch range.
        #expect(m.pitch(forY: -100) == 127)
        #expect(m.pitch(forY: m.contentHeight + 100) == 0)
    }

    // 5. Hit test: empty grid.
    @Test("hitTest returns nil over empty grid")
    func hitEmpty() {
        let m = makeModel(notes: [MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)])
        // Far from the single note (different pitch + time).
        #expect(m.hitTest(CGPoint(x: 500, y: 0)) == nil)
    }

    // 6. Hit test: body.
    @Test("hitTest returns body for a click inside a note")
    func hitBody() {
        let note = MIDINote(pitch: 60, startBeat: 2, lengthBeats: 2)
        let m = makeModel(notes: [note])
        let r = m.rect(for: note)
        let hit = m.hitTest(CGPoint(x: r.minX + 5, y: r.midY))
        #expect(hit?.id == note.id)
        #expect(hit?.zone == .body)
    }

    // 7. Hit test: resize handle at the right edge.
    @Test("hitTest returns resizeHandle near a note's right edge")
    func hitHandle() {
        let note = MIDINote(pitch: 60, startBeat: 2, lengthBeats: 2)
        let m = makeModel(notes: [note])
        let r = m.rect(for: note)
        let hit = m.hitTest(CGPoint(x: r.maxX - 2, y: r.midY))
        #expect(hit?.id == note.id)
        #expect(hit?.zone == .resizeHandle)
    }

    // 8. Add note: snapped position + default length + velocity 100.
    @Test("addNote snaps the start, sets one-cell length and velocity 100")
    func addNoteSnapped() {
        let m = makeModel()
        let added = m.addNote(atBeat: 2.6, pitch: 64, resolution: .beat)
        #expect(added.startBeat == 3)          // snapped to nearest beat
        #expect(added.lengthBeats == 1)        // one beat cell
        #expect(added.velocity == 100)
        #expect(added.pitch == 64)
        #expect(m.draft.count == 1)

        // Finer grid → shorter default length, sub-beat snap.
        let fine = m.addNote(atBeat: 1.30, pitch: 72, resolution: .sixteenth)
        #expect(fine.startBeat == 1.25)
        #expect(fine.lengthBeats == 0.25)
    }

    // 9. Move clamps pitch 0-127 and beat >= 0.
    @Test("moveSelection clamps pitch to 0-127 and start to >= 0")
    func moveClamps() {
        let note = MIDINote(pitch: 60, startBeat: 4, lengthBeats: 1)
        let m = makeModel(notes: [note])
        m.selectOnly(note.id)
        m.beginMove()

        // Push far negative in both axes.
        m.moveSelection(deltaBeats: -100, deltaPitch: -200, resolution: .beat)
        #expect(m.draft[0].startBeat == 0)
        #expect(m.draft[0].pitch == 0)
        #expect(m.draft[0].lengthBeats == 1)   // length preserved

        // From the same baseline, push far positive in pitch.
        m.moveSelection(deltaBeats: 3, deltaPitch: 500, resolution: .beat)
        #expect(m.draft[0].pitch == 127)
        #expect(m.draft[0].startBeat == 7)     // 4 + 3, snapped
    }

    // 10. Move snaps to grid off the baseline (no drift across ticks).
    @Test("moveSelection snaps off the captured baseline, not cumulatively")
    func moveSnapsFromBaseline() {
        let note = MIDINote(pitch: 60, startBeat: 2, lengthBeats: 1)
        let m = makeModel(notes: [note])
        m.selectOnly(note.id)
        m.beginMove()
        // Two ticks with sub-beat deltas must both resolve off startBeat 2.
        m.moveSelection(deltaBeats: 0.4, deltaPitch: 0, resolution: .beat)
        #expect(m.draft[0].startBeat == 2)     // 2.4 -> 2
        m.moveSelection(deltaBeats: 0.7, deltaPitch: 1, resolution: .beat)
        #expect(m.draft[0].startBeat == 3)     // 2.7 -> 3, off baseline (not 2->3->4)
        #expect(m.draft[0].pitch == 61)
    }

    // 11. Resize snaps and enforces a minimum length.
    @Test("resizeNote snaps the end and floors length at one grid step")
    func resizeMinLength() {
        let note = MIDINote(pitch: 60, startBeat: 2, lengthBeats: 2)
        let m = makeModel(notes: [note])
        // Drag end out to ~5.1 beats, beat snap -> end 5, length 3.
        m.resizeNote(id: note.id, toEndBeat: 5.1, resolution: .beat)
        #expect(m.draft[0].lengthBeats == 3)
        // Drag end back before the start -> clamps to one-beat minimum.
        m.resizeNote(id: note.id, toEndBeat: 0.1, resolution: .beat)
        #expect(m.draft[0].lengthBeats == 1)
        #expect(m.draft[0].startBeat == 2)     // start untouched
        // m21-c: a finer snap shrinks the floor with it — one 1/64 step.
        m.resizeNote(id: note.id, toEndBeat: 0.1, resolution: .sixtyFourth)
        #expect(m.draft[0].lengthBeats == 0.0625)
        // Snap off: the floor is the store's own minimum, not the 1-beat add
        // default (the old conflation).
        m.resizeNote(id: note.id, toEndBeat: 0.1, resolution: .off)
        #expect(m.draft[0].lengthBeats == MIDINote.minLengthBeats)
    }

    // 11b. m21-c: an AI-authored SHORT note (shorter than any menu grid) stays
    //     EDITABLE, not merely viewable — the store accepts it, so the editor
    //     must too: growing works, and shrinking respects the honest floor.
    @Test("m21-c a short AI-authored note is resizable in both directions")
    func shortNoteStaysEditable() {
        let short = MIDINote(pitch: 60, startBeat: 1, lengthBeats: 0.01)
        let m = makeModel(notes: [short])
        // Grow it: end 1.5 with snap off → exact length 0.5.
        m.resizeNote(id: short.id, toEndBeat: 1.5, resolution: .off)
        #expect(abs(m.draft[0].lengthBeats - 0.5) < 1e-9)
        // Shrink it back below any menu grid: snap off honors the tiny target.
        m.resizeNote(id: short.id, toEndBeat: 1.01, resolution: .off)
        #expect(abs(m.draft[0].lengthBeats - 0.01) < 1e-9)
        // With a grid ACTIVE the floor is that grid's step — the resize can't
        // silently make it shorter than one 1/32 cell.
        m.resizeNote(id: short.id, toEndBeat: 1.001, resolution: .thirtySecond)
        #expect(m.draft[0].lengthBeats == 0.125)
    }

    // 12. Velocity clamp (via MIDINote's 1...127).
    @Test("setVelocity clamps to 1-127")
    func velocityClamp() {
        let note = MIDINote(pitch: 60, velocity: 100, startBeat: 0, lengthBeats: 1)
        let m = makeModel(notes: [note])
        m.setVelocity(id: note.id, velocity: 200)
        #expect(m.draft[0].velocity == 127)
        m.setVelocity(id: note.id, velocity: 0)
        #expect(m.draft[0].velocity == 1)      // 0 is note-off, never stored
        m.setVelocity(id: note.id, velocity: 64)
        #expect(m.draft[0].velocity == 64)
    }

    // 13. Draft round-trip preserves untouched note ids.
    @Test("editing one note preserves the ids of the others in the submission")
    func draftPreservesIDs() {
        let a = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let b = MIDINote(pitch: 64, startBeat: 1, lengthBeats: 1)
        let c = MIDINote(pitch: 67, startBeat: 2, lengthBeats: 1)
        let m = makeModel(notes: [a, b, c])
        m.selectOnly(b.id)
        m.beginMove()
        m.moveSelection(deltaBeats: 2, deltaPitch: 0, resolution: .beat)

        let submitted = m.buildSubmission()
        #expect(Set(submitted.map(\.id)) == Set([a.id, b.id, c.id]))
        // a and c unchanged in place.
        #expect(submitted.first { $0.id == a.id } == a)
        #expect(submitted.first { $0.id == c.id } == c)
        // b moved.
        #expect(submitted.first { $0.id == b.id }?.startBeat == 3)
    }

    // 14. Delete removes only the selected notes.
    @Test("deleteSelection removes selected notes and clears selection")
    func deleteSelection() {
        let a = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let b = MIDINote(pitch: 64, startBeat: 1, lengthBeats: 1)
        let m = makeModel(notes: [a, b])
        m.selectOnly(a.id)
        m.deleteSelection()
        #expect(m.draft.map(\.id) == [b.id])
        #expect(m.selection.isEmpty)
    }

    // 15. Selection ops: selectOnly, toggle, clear.
    @Test("selection ops: selectOnly, toggle in/out, clear")
    func selectionOps() {
        let a = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        let b = MIDINote(pitch: 64, startBeat: 1, lengthBeats: 1)
        let m = makeModel(notes: [a, b])

        m.selectOnly(a.id)
        #expect(m.selection == [a.id])
        m.selectOnly(b.id)
        #expect(m.selection == [b.id])          // selectOnly replaces

        m.toggle(a.id)
        #expect(m.selection == [a.id, b.id])    // toggle adds
        m.toggle(a.id)
        #expect(m.selection == [b.id])          // toggle removes

        m.clearSelection()
        #expect(m.selection.isEmpty)
        #expect(!m.isSelected(b.id))
    }

    // 16. contentWidth grows to hold out-of-clip notes; contentHeight is full.
    @Test("content size covers the clip and any out-of-clip notes")
    func contentSize() {
        let m = makeModel(notes: [MIDINote(pitch: 60, startBeat: 10, lengthBeats: 4)], length: 8)
        // Note ends at beat 14, past the 8-beat clip.
        #expect(m.contentWidth == 14 * PianoRollModel.defaultPixelsPerBeat)
        #expect(m.contentHeight == 128 * PianoRollModel.defaultRowHeight)
    }

    // 17. m18-f wide-window rule (DESIGN-LANGUAGE "Wide windows"): a band draws
    // at max(content, viewport) — extended to the panel's right edge at wide
    // windows, never narrower than its content.
    @Test("drawnWidth extends content to a wider viewport")
    func drawnWidthExtends() {
        // 8-beat clip = 256 pt of content inside a 3400 pt ultra-wide viewport.
        #expect(PianoRollModel.drawnWidth(content: 256, viewport: 3400) == 3400)
        // Exactly-fitting viewport is a no-op.
        #expect(PianoRollModel.drawnWidth(content: 256, viewport: 256) == 256)
    }

    // 18. Content always wins over a narrower viewport (the pre-m18-f behavior
    // is unchanged when the clip outruns the window — the band stays scrollable),
    // including content the model already extended for out-of-clip notes.
    @Test("drawnWidth never shrinks below content")
    func drawnWidthKeepsContent() {
        #expect(PianoRollModel.drawnWidth(content: 2048, viewport: 1330) == 2048)
        let m = makeModel(notes: [MIDINote(pitch: 60, startBeat: 10, lengthBeats: 4)], length: 8)
        // Note-extended content (14 beats) beats a viewport narrower than it.
        let content = m.contentWidth
        #expect(PianoRollModel.drawnWidth(content: content, viewport: content - 1) == content)
        // A degenerate viewport (panel narrower than the gutter reports <= 0)
        // floors at 0 and passes content through untouched.
        #expect(PianoRollModel.drawnWidth(content: content, viewport: -10) == content)
    }

    // MARK: - m19-g beyond-clip boundary (playableEndBeat)

    // 19. playableEndBeat mirrors the engine's note rule EXACTLY (MIDISchedule
    //    strict `<`): an onset strictly inside [0, clipLen) plays, an onset
    //    exactly AT the clip end is latent — the ghost treatment's one split
    //    value (the ControllerStripModel.playableCount sibling).
    @Test("m19-g playableEndBeat is strict-< at the clip end (engine-honest)")
    func playableEndBeatStrictBoundary() {
        // Onset just inside → plays.
        let inside = MIDINote(pitch: 60, startBeat: 3.9, lengthBeats: 0.1)
        #expect(PianoRollModel.playableEndBeat(of: inside, clipLengthBeats: 4) == 4)
        // Onset exactly AT the end → latent (strict <).
        let atEnd = MIDINote(pitch: 60, startBeat: 4, lengthBeats: 1)
        #expect(PianoRollModel.playableEndBeat(of: atEnd, clipLengthBeats: 4) == nil)
        // Onset wholly beyond → latent.
        let beyond = MIDINote(pitch: 60, startBeat: 9, lengthBeats: 1)
        #expect(PianoRollModel.playableEndBeat(of: beyond, clipLengthBeats: 4) == nil)
        // Zero-length clip → everything latent.
        let atZero = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 1)
        #expect(PianoRollModel.playableEndBeat(of: atZero, clipLengthBeats: 0) == nil)
    }

    // 20. Partial overhang — the engine TRUNCATES the note-off at the clip end
    //    (`min(endBeat, clipLength)`, MIDISchedule.buildEvents): the playable
    //    end is the boundary, not the note's own end — lit body to the
    //    boundary, ghost tail past it. A fully-inside note plays untouched.
    @Test("m19-g partial overhang truncates at the boundary; inside notes play in full")
    func playableEndBeatOverhang() {
        let overhang = MIDINote(pitch: 62, startBeat: 7, lengthBeats: 3)   // ends at 10
        #expect(PianoRollModel.playableEndBeat(of: overhang, clipLengthBeats: 8) == 8)
        let inside = MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1.5)
        #expect(PianoRollModel.playableEndBeat(of: inside, clipLengthBeats: 8) == inside.endBeat)
    }

    // 21. Extension re-lights (the window grows over latent data): the same
    //    notes flip nil → playing / truncated → full as clipLengthBeats grows —
    //    the live re-light a wire `clip.trim` extension produces via reseed.
    @Test("m19-g extension re-lights: ghosts come alive as the window grows")
    func playableEndBeatExtensionRelights() {
        let overhang = MIDINote(pitch: 62, startBeat: 7, lengthBeats: 3)   // ends at 10
        let latent = MIDINote(pitch: 69, startBeat: 9, lengthBeats: 1)     // ends at 10
        // At 8 beats: overhang truncated, latent silent.
        #expect(PianoRollModel.playableEndBeat(of: overhang, clipLengthBeats: 8) == 8)
        #expect(PianoRollModel.playableEndBeat(of: latent, clipLengthBeats: 8) == nil)
        // Extended to 13: both fully lit.
        #expect(PianoRollModel.playableEndBeat(of: overhang, clipLengthBeats: 13) == overhang.endBeat)
        #expect(PianoRollModel.playableEndBeat(of: latent, clipLengthBeats: 13) == latent.endBeat)
    }

    // 22. Trim ghosts (the window shrinks): a formerly in-window note goes
    //    truncated, then latent, as the boundary crosses it.
    @Test("m19-g trim ghosts former in-window notes as the window shrinks")
    func playableEndBeatTrimGhosts() {
        let note = MIDINote(pitch: 60, startBeat: 2, lengthBeats: 2)       // [2, 4)
        #expect(PianoRollModel.playableEndBeat(of: note, clipLengthBeats: 8) == 4)   // full
        #expect(PianoRollModel.playableEndBeat(of: note, clipLengthBeats: 3) == 3)   // truncated
        #expect(PianoRollModel.playableEndBeat(of: note, clipLengthBeats: 2) == nil) // latent
    }

    // 23. Editing stays boundary-blind (the m18-e rule): a ghost pill hit-tests,
    //    moves, and resizes exactly like a lit one, and dragging across the
    //    boundary flips its treatment live in both directions.
    @Test("m19-g ghost pills stay first-class edit targets; drags flip treatment live")
    func ghostPillsStayEditable() {
        let ghost = MIDINote(pitch: 69, startBeat: 10, lengthBeats: 1)     // beyond the 8-beat clip
        let m = makeModel(notes: [ghost], length: 8)
        // Hit-test lands on the ghost pill at its drawn position.
        let inside = CGPoint(x: m.x(forBeat: 10.5), y: m.y(forPitch: 69) + 5)
        #expect(m.hitTest(inside)?.id == ghost.id)
        // Move it back inside the clip → it re-lights.
        m.selectOnly(ghost.id)
        m.beginMove()
        m.moveSelection(deltaBeats: -6, deltaPitch: 0, resolution: .beat)
        let moved = m.draft[0]
        #expect(moved.startBeat == 4)
        #expect(PianoRollModel.playableEndBeat(of: moved, clipLengthBeats: 8) == moved.endBeat)
        // Resize its tail past the clip end → truncated (lit body, ghost tail).
        m.resizeNote(id: ghost.id, toEndBeat: 10, resolution: .beat)
        #expect(PianoRollModel.playableEndBeat(of: m.draft[0], clipLengthBeats: 8) == 8)
        // Move it wholly out again → latent (no clamp; the store accepts it).
        m.beginMove()
        m.moveSelection(deltaBeats: 5, deltaPitch: 0, resolution: .beat)
        #expect(PianoRollModel.playableEndBeat(of: m.draft[0], clipLengthBeats: 8) == nil)
    }

    // MARK: - m23-ek-2: a GROUP drag is RIGID

    // The m23-g2 defect, on both axes. Before ek-2 `moveSelection` clamped
    // pitch, floored the beat AND snapped PER NOTE off each note's own base, so
    // a multi-note drag DEFORMED the selection. Each leg below carries the
    // rejected per-note expression as its validity half — a test that cannot
    // tell the two rules apart proves nothing when it passes.

    // 24. A chord dragged into the 127 ceiling keeps its intervals.
    @Test("m23-ek-2 a chord dragged into the pitch ceiling stops as a UNIT, intervals intact")
    func groupPitchClampIsRigid() {
        let root = MIDINote(pitch: 120, startBeat: 0, lengthBeats: 1)
        let third = MIDINote(pitch: 124, startBeat: 0, lengthBeats: 1)
        let fifth = MIDINote(pitch: 127 - 0, startBeat: 0, lengthBeats: 1)   // already AT the ceiling
        let m = makeModel(notes: [root, third, fifth])
        m.selection = [root.id, third.id, fifth.id]
        m.beginMove(anchorID: root.id)
        // Ask for +10: the top note cannot move at all, so nothing may.
        m.moveSelection(deltaBeats: 0, deltaPitch: 10, resolution: .beat)
        let pitches = m.draft.map(\.pitch)
        #expect(pitches == [120, 124, 127], "the group stopped at the wall as a unit")
        // VALIDITY: the OLD per-note expression gives a different, deformed
        // answer for the same ask — the chord collapses into a cluster.
        let perNote = [120, 124, 127].map { ($0 + 10).clamped(to: MIDINote.pitchRange) }
        #expect(perNote == [127, 127, 127])
        #expect(pitches != perNote)
        // A move that FITS still moves the whole group.
        m.moveSelection(deltaBeats: 0, deltaPitch: -20, resolution: .beat)
        #expect(m.draft.map(\.pitch) == [100, 104, 107])
        // …and downward, the floor binds on the LOWEST note, again as a unit.
        m.moveSelection(deltaBeats: 0, deltaPitch: -500, resolution: .beat)
        #expect(m.draft.map(\.pitch) == [0, 4, 7])
    }

    // 25. A group dragged left past 0 keeps its gaps.
    @Test("m23-ek-2 a group dragged past beat 0 stops as a UNIT, rhythm intact")
    func groupBeatFloorIsRigid() {
        let a = MIDINote(pitch: 60, startBeat: 2, lengthBeats: 1)
        let b = MIDINote(pitch: 62, startBeat: 5, lengthBeats: 1)
        let c = MIDINote(pitch: 64, startBeat: 6, lengthBeats: 1)
        let m = makeModel(notes: [a, b, c], length: 16)
        m.selection = [a.id, b.id, c.id]
        m.beginMove(anchorID: b.id)
        m.moveSelection(deltaBeats: -50, deltaPitch: 0, resolution: .beat)
        #expect(m.draft.map(\.startBeat) == [0, 3, 4], "gaps 3 and 1 survive the wall")
        // VALIDITY: per-note flooring piles every note onto 0.
        let perNote = [2.0, 5.0, 6.0].map { max(0, $0 - 50) }
        #expect(perNote == [0, 0, 0])
        #expect(m.draft.map(\.startBeat) != perNote)
    }

    // 26. Sub-grid phases survive a snapped group drag — the welding defect.
    @Test("m23-ek-2 two notes at different sub-grid phases keep their gap through a snapped drag")
    func groupSnapDoesNotWeld() {
        let onGrid = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 0.25)
        let offGrid = MIDINote(pitch: 62, startBeat: 0.5, lengthBeats: 0.25)
        let m = makeModel(notes: [onGrid, offGrid], length: 16)
        m.selection = [onGrid.id, offGrid.id]
        m.beginMove(anchorID: onGrid.id)
        m.moveSelection(deltaBeats: 0.1, deltaPitch: 0, resolution: .beat)
        let starts = m.draft.map(\.startBeat)
        #expect(starts == [0, 0.5], "the anchor snapped to 0; the gap is still 0.5")
        #expect(starts[1] - starts[0] == 0.5)
        // VALIDITY: the OLD per-note snap welds them a full beat apart — the
        // m23-g2 defect verbatim, on the beat axis.
        let perNote = [0.0, 0.5].map { m.snap(beat: max(0, $0 + 0.1), resolution: .beat) }
        #expect(perNote == [0, 1])
        #expect(perNote[1] - perNote[0] == 1.0)
        #expect(starts != perNote)
        // The anchor decides the snap: grabbing the OFF-grid note instead moves
        // the pair by a different (still rigid) delta.
        m.beginMove(anchorID: offGrid.id)
        m.moveSelection(deltaBeats: 0.1, deltaPitch: 0, resolution: .beat)
        #expect(m.draft.map(\.startBeat) == [0.5, 1.0], "anchor 0.5+0.1 snaps to 1; delta +0.5")
        #expect(m.draft[1].startBeat - m.draft[0].startBeat == 0.5)
    }

    // 27. ⚠️ The case the design's three legs miss: a snap can round the anchor
    //    DOWN past the group floor that was just applied.
    @Test("m23-ek-2 a snap that rounds the anchor down cannot push a note below beat 0")
    func groupSnapCannotUndershootZero() {
        // ⚠️ FIXTURE LAW: every value here is a dyadic rational (0.25, 2.5,
        // 0.125), so every arithmetic step is EXACT in binary floating point and
        // an `==` failure can only mean the rule is wrong — never that the
        // fixture drifted by an ulp.
        let low = MIDINote(pitch: 60, startBeat: 0.25, lengthBeats: 0.25)
        let anchor = MIDINote(pitch: 62, startBeat: 2.5, lengthBeats: 0.25)
        let m = makeModel(notes: [low, anchor], length: 16)
        m.selection = [low.id, anchor.id]
        m.beginMove(anchorID: anchor.id)
        // The group floor gives −0.125; the anchor's 2.375 then SNAPS DOWN to 2,
        // an applied −0.5 that would land `low` at −0.25 if the floor were only
        // applied to the ASK.
        m.moveSelection(deltaBeats: -0.125, deltaPitch: 0, resolution: .beat)
        #expect(m.draft[0].startBeat == 0, "the group stopped at the wall")
        #expect(m.draft[1].startBeat == 2.25, "…rigidly, with the anchor left off-grid")
        #expect(m.draft.allSatisfy { $0.startBeat >= 0 })
        // And nothing was welded: the 2.25-beat gap is preserved exactly.
        #expect(m.draft[1].startBeat - m.draft[0].startBeat == 2.25)
    }

    // 28. ⭐ THE SAFETY PROPERTY: single-note drags are byte-identical.
    @Test("m23-ek-2 a SINGLE-note drag is byte-identical to the pre-ek-2 expression",
          arguments: [SnapResolution.off, .bar, .beat, .eighth, .eighthTriplet,
                      .sixteenth, .sixteenthTriplet, .thirtySecond, .sixtyFourth])
    func singleNoteDragUnchanged(resolution: SnapResolution) {
        // The whole snap ladder × a spread of bases and deltas, compared against
        // the EXACT expression `moveSelection` used to run per note. Byte, not
        // "close": `==` on Double, deliberately.
        for base in [0.0, 0.2, 2.0, 2.4, 7.75, 100.0] {
            for delta in [-1000.0, -3.3, -0.1, 0.0, 0.1, 0.7, 3.0, 96.4] {
                let note = MIDINote(pitch: 60, startBeat: base, lengthBeats: 1)
                let m = makeModel(notes: [note], length: 128)
                m.selectOnly(note.id)
                m.beginMove(anchorID: note.id)
                m.moveSelection(deltaBeats: delta, deltaPitch: 3, resolution: resolution)
                let old = m.snap(beat: max(0, base + delta), resolution: resolution)
                #expect(m.draft[0].startBeat == old,
                        "base \(base) delta \(delta) \(resolution): \(m.draft[0].startBeat) != \(old)")
                #expect(m.draft[0].pitch == (60 + 3).clamped(to: MIDINote.pitchRange))
                #expect(m.draft[0].lengthBeats == 1)
            }
        }
    }

    // 29. …and byte-identical WITHOUT an anchor id, which is what the six
    //    pre-ek-2 call sites (deliberately not rewritten) exercise.
    @Test("m23-ek-2 the anchor defaults deterministically — an anchorless drag is still rigid")
    func anchorlessDragIsDeterministicAndRigid() {
        let late = MIDINote(pitch: 60, startBeat: 4, lengthBeats: 1)
        let early = MIDINote(pitch: 72, startBeat: 1.5, lengthBeats: 1)
        let m = makeModel(notes: [late, early], length: 16)
        m.selection = [late.id, early.id]
        // No anchor: the EARLIEST note (startBeat, then pitch, then id) — never
        // Set iteration order, which is unstable run to run.
        m.beginMove()
        m.moveSelection(deltaBeats: 0.6, deltaPitch: 0, resolution: .beat)
        // early 1.5 + 0.6 = 2.1 snaps to 2 → delta +0.5, applied to both.
        #expect(m.draft.map(\.startBeat) == [4.5, 2.0])
        #expect(m.draft[0].startBeat - m.draft[1].startBeat == 2.5, "the gap is unchanged")
        // Repeating the whole gesture gives the SAME answer (determinism, not
        // a lucky hash order): re-seed a fresh model with the notes swapped.
        let m2 = makeModel(notes: [early, late], length: 16)
        m2.selection = [late.id, early.id]
        m2.beginMove()
        m2.moveSelection(deltaBeats: 0.6, deltaPitch: 0, resolution: .beat)
        #expect(m2.draft.first { $0.id == early.id }?.startBeat == 2.0)
        #expect(m2.draft.first { $0.id == late.id }?.startBeat == 4.5)
    }

    // MARK: - m23-ek-1: ONE producer of the note rect

    // 30. The static, `rect(for:)` and `noteRects()` are the same arithmetic —
    //     the property the rubber band's agreement with a click rests on.
    @Test("m23-ek-1 noteRect is the ONE producer: rect(for:), noteRects() and hitTest all agree")
    func noteRectIsTheOneProducer() {
        let short = MIDINote(pitch: 64, startBeat: 2, lengthBeats: 0.0625)
        let long = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 4)
        let m = PianoRollModel(notes: [short, long], clipLengthBeats: 8, pixelsPerBeat: 8)
        for note in [short, long] {
            let viaStatic = PianoRollModel.noteRect(
                note, rowHeight: m.rowHeight, pixelsPerBeat: m.pixelsPerBeat)
            #expect(m.rect(for: note) == viaStatic)
            #expect(m.noteRects().first { $0.id == note.id }?.rect == viaStatic)
            // hitTest resolves against the same rect, including the 3 pt floor.
            #expect(m.hitTest(CGPoint(x: viaStatic.midX, y: viaStatic.midY))?.id == note.id)
        }
        // The floor is the reason this matters at all.
        #expect(m.rect(for: short).width == 3)
        #expect(CGFloat(short.lengthBeats) * m.pixelsPerBeat < 3)
    }

    // MARK: - p2-sing-pr-words-f3: double-click ON an existing note (CHARACTERISATION)

    // ⚠️ CHARACTERISATION TESTS: they pin TODAY's behaviour so a change to it is
    // seen, and they rule nothing. Whether double-clicking a note should keep
    // adding one is a separate call (design 2026-10-12-piano-roll-words §1.9 F3,
    // §7.4). The roll's double-tap (`PianoRollView`'s `SpatialTapGesture(count: 2)`)
    // calls `addNote(atBeat: model.beat(forX:), pitch: model.pitch(forY:),
    // resolution: effectiveSnap, …)` with NO hit test, then submits the whole
    // draft through `setClipNotes`. These tests feed `addNote` the points a
    // double-click on a note produces, exactly as that handler does; the
    // gesture's own dispatch is not run here (no window).

    /// A store holding `notes` in one MIDI clip on an instrument track.
    private func f3Store(notes: [MIDINote], length: Double = 8) throws -> (ProjectStore, Clip) {
        let store = ProjectStore()
        let track = store.addTrack(kind: .instrument)
        let clip = try store.addMIDIClip(toTrack: track.id, atBeat: 0, lengthBeats: length, notes: notes)
        return (store, clip)
    }

    // 31. The default snap (Simple density locks `.beat`, `SnapResolution.effective`):
    //     a double-click on the LEFT half of a one-beat note snaps back to its start.
    @Test("characterisation (p2-sing-pr-words-f3): a double-click on a note's left half stacks an exact duplicate, and the store keeps both")
    func characterisationDoubleClickStacksADuplicate() throws {
        let existing = MIDINote(pitch: 64, velocity: 100, startBeat: 2, lengthBeats: 1)
        let (store, clip) = try f3Store(notes: [existing])
        let m = makeModel(notes: [existing])
        let r = m.rect(for: existing)
        let point = CGPoint(x: r.minX + r.width * 0.25, y: r.midY)
        #expect(m.hitTest(point)?.id == existing.id, "control: the double-click lands ON the note")
        #expect(SnapResolution.effective(appSnap: .bar, density: .simple, picked: .sixteenth) == .beat,
                "control: the roll's default snap is the beat")

        let added = m.addNote(atBeat: m.beat(forX: point.x), pitch: m.pitch(forY: point.y), resolution: .beat)
        #expect(m.draft.count == 2, "a second note is added; the first is not selected, moved or removed")
        #expect(added.id != existing.id)
        #expect(added.pitch == existing.pitch)
        #expect(added.startBeat == existing.startBeat)
        #expect(added.lengthBeats == existing.lengthBeats)
        #expect(added.velocity == existing.velocity, "an exact duplicate: same pitch, start, length and velocity")

        // The roll's commit funnel: the whole draft through `setClipNotes`.
        let stored = try store.setClipNotes(clipID: clip.id, notes: m.buildSubmission(), extendToCover: [added.id])
        let twins = (stored.notes ?? []).filter { $0.pitch == 64 && $0.startBeat == 2 && $0.lengthBeats == 1 }
        #expect(twins.count == 2, "the store keeps both: nothing on the way merges a stacked note")
        #expect(Set(twins.map(\.id)) == [existing.id, added.id])
    }

    // 32. Where the click lands decides what is added; it is always a NEW note.
    @Test("characterisation (p2-sing-pr-words-f3): elsewhere on a note the double-click adds a neighbour or an overlapping note, never nothing")
    func characterisationDoubleClickElsewhereOnANote() {
        // Right half of a one-beat note, beat snap: the next beat — beside it, not on it.
        let one = MIDINote(pitch: 64, startBeat: 2, lengthBeats: 1)
        let a = makeModel(notes: [one])
        let right = a.rect(for: one)
        let rightPoint = CGPoint(x: right.minX + right.width * 0.75, y: right.midY)
        #expect(a.hitTest(rightPoint)?.id == one.id, "control: on the note")
        let beside = a.addNote(atBeat: a.beat(forX: rightPoint.x), pitch: a.pitch(forY: rightPoint.y), resolution: .beat)
        #expect(a.draft.count == 2)
        #expect(beside.pitch == 64 && beside.startBeat == 3 && beside.lengthBeats == 1)

        // Inside a long note, beat snap: a one-beat note of the same pitch INSIDE it.
        let long = MIDINote(pitch: 60, startBeat: 0, lengthBeats: 4)
        let b = makeModel(notes: [long])
        let longRect = b.rect(for: long)
        let inside = CGPoint(x: longRect.minX + 1.7 * b.pixelsPerBeat, y: longRect.midY)
        #expect(b.hitTest(inside)?.id == long.id, "control: on the note")
        let overlapping = b.addNote(atBeat: b.beat(forX: inside.x), pitch: b.pitch(forY: inside.y), resolution: .beat)
        #expect(b.draft.count == 2)
        #expect(overlapping.pitch == 60 && overlapping.startBeat == 2 && overlapping.lengthBeats == 1)
        #expect(overlapping.startBeat > long.startBeat && overlapping.endBeat <= long.endBeat, "wholly inside the long note")

        // A Pro sixteenth snap, centre of a one-beat note: a sixteenth inside it.
        let c = makeModel(notes: [one])
        let centre = CGPoint(x: c.rect(for: one).midX, y: c.rect(for: one).midY)
        let sixteenth = c.addNote(atBeat: c.beat(forX: centre.x), pitch: c.pitch(forY: centre.y), resolution: .sixteenth)
        #expect(c.draft.count == 2)
        #expect(sixteenth.pitch == 64 && sixteenth.startBeat == 2.5 && sixteenth.lengthBeats == 0.25)
    }
}
