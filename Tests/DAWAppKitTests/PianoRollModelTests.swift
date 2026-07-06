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
        // never negative.
        #expect(m.snap(beat: -1, resolution: .beat) == 0)
    }

    // 2. defaultLength per resolution (1 grid cell; 1 beat when off).
    @Test("defaultLength is one grid cell, one beat when snapping is off")
    func defaultLength() {
        let m = makeModel()
        #expect(m.defaultLength(for: .off) == 1.0)
        #expect(m.defaultLength(for: .bar) == 4)
        #expect(m.defaultLength(for: .beat) == 1)
        #expect(m.defaultLength(for: .eighth) == 0.5)
        #expect(m.defaultLength(for: .sixteenth) == 0.25)
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
    @Test("resizeNote snaps the end and floors length at one grid cell")
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
}
