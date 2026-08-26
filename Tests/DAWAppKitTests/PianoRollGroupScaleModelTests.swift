import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// m25-g — group compress/extend as the MODEL performs it: the baseline
/// snapshot, the single snap, the two exactness pins, and the property this
/// whole item's craft exists to protect (a scaled figure keeps its sub-grid
/// phase).
@MainActor
@Suite("PianoRollModel group scale (m25-g)")
struct PianoRollGroupScaleModelTests {

    private func note(_ start: Double, _ length: Double, pitch: Int = 60,
                      velocity: Int = 100) -> MIDINote {
        MIDINote(pitch: pitch, velocity: velocity, startBeat: start, lengthBeats: length)
    }

    private func model(_ notes: [MIDINote], length: Double = 8) -> PianoRollModel {
        let m = PianoRollModel(notes: notes, clipLengthBeats: length)
        m.selection = Set(notes.map(\.id))
        return m
    }

    private func starts(_ m: PianoRollModel) -> [Double] {
        m.draft.sorted { $0.startBeat < $1.startBeat }.map(\.startBeat)
    }

    /// An EIGHTH-NOTE TRIPLET bar: three even notes across one beat, none of
    /// which (bar the first) can be expressed on the 1/16 grid. This is the
    /// fixture that can see a per-note snap; a straight figure cannot.
    private func tripletFigure() -> [MIDINote] {
        [note(0, 1.0 / 3.0), note(1.0 / 3.0, 1.0 / 3.0), note(2.0 / 3.0, 1.0 / 3.0)]
    }

    // MARK: - THE property (m23-ek-2's law, applied to a scale)

    @Test("a compressed triplet keeps its phase — no note is welded to the grid")
    func compressedTripletKeepsItsPhase() {
        // ⭐⭐ THE TEST THIS ITEM EXISTS TO GET RIGHT. Snapping each scaled onset
        // instead of the gesture's one edge sends 1/6 -> 0.25 and 1/3 -> 0.25
        // under a 1/16 grid: TWO NOTES WELD ONTO THE SAME BEAT and a triplet
        // silently becomes something the user never played. Mutation-tested —
        // see the suite's docs and the item report.
        let notes = tripletFigure()
        // FIXTURE POSITIVE CONTROL: the figure really does span exactly 0...1,
        // so `maxEnd` is what the exactness pins below assume. (2/3 + 1/3 == 1.0
        // in IEEE double — round-half-to-even — but a test should not take that
        // on faith.)
        #expect(notes[2].startBeat + notes[2].lengthBeats == 1.0)

        let m = model(notes)
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 0.5, resolution: .sixteenth)   // factor 0.5

        let s = starts(m)
        #expect(s.count == 3)
        // Evenness survives: the two gaps stay equal. Asserting the RATIO of
        // successive gaps rather than their values is what makes this insensitive
        // to the factor and sensitive only to welding.
        let gapA = s[1] - s[0]
        let gapB = s[2] - s[1]
        #expect(abs(gapA - gapB) < 1e-12, "gaps \(gapA) and \(gapB) diverged — a phase was snapped")
        #expect(abs(gapA - 1.0 / 6.0) < 1e-12)
        // And nothing collapsed onto anything.
        #expect(Set(s.map { ($0 * 1e9).rounded() }).count == 3)
    }

    @Test("a stretched triplet keeps its phase too")
    func stretchedTripletKeepsItsPhase() {
        // The stretch direction, at a factor whose products sit OFF the grid
        // (x1.25 -> 0.4167 and 0.8333, which a per-note snap would push to 0.5
        // and 0.75 — in OPPOSITE directions, so the gaps stop being equal).
        let m = model(tripletFigure())
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 1.25, resolution: .sixteenth)

        let s = starts(m)
        let gapA = s[1] - s[0]
        let gapB = s[2] - s[1]
        #expect(abs(gapA - gapB) < 1e-12, "gaps \(gapA) and \(gapB) diverged — a phase was snapped")
        #expect(abs(s[1] - 0.4166666666666667) < 1e-12)
        #expect(abs(s[2] - 0.8333333333333334) < 1e-12)
    }

    @Test("an already-on-grid figure is invariant under the same scale")
    func onGridFigureIsInvariant() {
        // ⭐ THE NEGATIVE CONTROL for the two tests above. A straight figure
        // doubled lands back on the grid, so a planted per-note snap CANNOT
        // redden this one. That is what proves the triplet fixture is the
        // discriminator, rather than the mutant being caught by something
        // incidental to the change.
        let m = model([note(0, 0.5), note(0.5, 0.5), note(1.0, 0.5)])
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 3.0, resolution: .sixteenth)   // factor 2
        #expect(starts(m) == [0, 1, 2])
        #expect(m.draft.allSatisfy { $0.lengthBeats == 1 })
    }

    // MARK: - Both edges land EXACTLY (the asymmetric float pins)

    @Test("the trailing drag pins the moving END and leaves the start untouched")
    func trailingEdgeIsExact() {
        let m = model(tripletFigure())
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 1.25, resolution: .sixteenth)
        let ordered = m.draft.sorted { $0.startBeat < $1.startBeat }
        // EXACT equality, deliberately: an approximate assertion here would pass
        // against exactly the drift the pin exists to prevent.
        #expect(ordered[0].startBeat == 0.0)
        #expect(ordered[2].startBeat + ordered[2].lengthBeats == 1.25)
    }

    @Test("the leading drag pins the moving START and the stationary END")
    func leadingEdgeIsExact() {
        // The mirror image, and the reason it needs its own test: an END is
        // derived from start + length, so each direction has exactly ONE
        // "pin a length to fix an end" case, and they are on opposite sides.
        let m = model(tripletFigure())
        m.beginGroupScale(edge: .leading)
        m.scaleSelection(toBeat: -0.75, resolution: .sixteenth)   // asks for -0.75, floored to 0
        let ordered = m.draft.sorted { $0.startBeat < $1.startBeat }
        #expect(ordered[0].startBeat == 0.0)
        // ⭐ The edge the user was promised would NOT move must not move by a
        // single ulp: it is the visible anchor of the whole gesture.
        #expect(ordered[2].startBeat + ordered[2].lengthBeats == 1.0)
    }

    @Test("a leading drag with room to move pins both edges exactly")
    func leadingEdgeIsExactAwayFromTheWall() {
        // The clamped case above could pass on a coincidence of zero; this one
        // lands the moving edge on a non-zero grid line.
        let m = model([note(2, 0.5), note(2.5, 1.0)])
        m.beginGroupScale(edge: .leading)
        m.scaleSelection(toBeat: 1.5, resolution: .sixteenth)   // span 1.5 -> 2, factor 4/3
        let ordered = m.draft.sorted { $0.startBeat < $1.startBeat }
        #expect(ordered[0].startBeat == 1.5)
        #expect(ordered[1].endBeat == 3.5)
    }

    // MARK: - It is a TIME-STRETCH (decision 1)

    @Test("lengths scale with onsets, so articulation ratios survive")
    func lengthsScaleToo() {
        // DECISION 1. Scaling onsets alone at factor 0.5 would leave three
        // half-beat notes 0.25 apart — every note outlasting the next one's
        // onset, a legato line turned into a pile of overlaps.
        let m = model([note(0, 0.5), note(1, 0.5), note(2, 0.5)])
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 1.25, resolution: .sixteenth)   // span 2.5 -> 1.25
        let ordered = m.draft.sorted { $0.startBeat < $1.startBeat }
        #expect(ordered.map(\.startBeat) == [0, 0.5, 1.0])
        #expect(ordered.map(\.lengthBeats) == [0.25, 0.25, 0.25])
        // The ratio of sounding time to step time — the "articulation" — is
        // unchanged at 0.5 in both the before and after.
        #expect(ordered[0].lengthBeats / (ordered[1].startBeat - ordered[0].startBeat) == 0.5)
    }

    @Test("pitch and velocity are read live, never from the baseline")
    func pitchAndVelocitySurvive() {
        // `resizeNote`'s rule: a velocity-lane edit landing mid-gesture must not
        // be clobbered by a stale copy captured at press.
        let notes = [note(0, 1, pitch: 60, velocity: 30), note(1, 1, pitch: 72, velocity: 120)]
        let m = model(notes)
        m.beginGroupScale(edge: .trailing)
        m.setVelocity(id: notes[0].id, velocity: 99)
        m.scaleSelection(toBeat: 4, resolution: .beat)
        #expect(m.draft.first { $0.id == notes[0].id }?.velocity == 99)
        #expect(m.draft.first { $0.id == notes[0].id }?.pitch == 60)
        #expect(m.draft.first { $0.id == notes[1].id }?.pitch == 72)
        #expect(m.draft.first { $0.id == notes[1].id }?.velocity == 120)
    }

    // MARK: - The baseline (no compounding)

    @Test("every tick maps off the frozen baseline, so a drag out and back is exact")
    func theBaselineDoesNotCompound() {
        let notes = tripletFigure()
        let m = model(notes)
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 4, resolution: .beat)      // way out
        m.scaleSelection(toBeat: 0.25, resolution: .beat)   // way back in (floored)
        m.scaleSelection(toBeat: 1, resolution: .beat)      // home: factor 1
        let ordered = m.draft.sorted { $0.startBeat < $1.startBeat }
        // BYTE-IDENTICAL onsets and ENDS — a compounding implementation would be
        // off by the product of every intermediate factor.
        //
        // ⚠️ ONSETS AND ENDS, NOT LENGTHS, and the difference is honest rather
        // than convenient: at factor 1 the far-edge note's length is re-derived
        // as `edgeBeat - start` (the exactness pin), which can differ from the
        // captured length by one ulp while producing the SAME end. The end is
        // what the scheduler and the user hear; the length is bookkeeping.
        #expect(ordered.map(\.startBeat) == notes.map(\.startBeat))
        #expect(ordered.map(\.endBeat) == notes.map(\.endBeat))
    }

    @Test("cancelling a scale restores the selection byte-exactly")
    func cancelRestoresTheBaseline() {
        // The no-travel release path: a 1-pt twitch on the handle has already
        // scaled the draft on its own tick, and nothing is going to commit it.
        // Restoring from the BASELINE rather than re-scaling by factor 1 is what
        // makes this exact instead of merely close.
        let notes = tripletFigure()
        let m = model(notes)
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 4, resolution: .off)
        #expect(starts(m) != notes.map(\.startBeat))   // it really did deform
        m.cancelGroupScale()
        let ordered = m.draft.sorted { $0.startBeat < $1.startBeat }
        #expect(ordered.map(\.startBeat) == notes.map(\.startBeat))
        #expect(ordered.map(\.lengthBeats) == notes.map(\.lengthBeats))
    }

    @Test("cancelling keeps a velocity edit that landed during the gesture")
    func cancelDoesNotUndoAVelocityEdit() {
        // `cancelGroupScale` restores TIMING, which is all it froze. Restoring
        // pitch/velocity from the baseline would make an unrelated edit vanish.
        let notes = [note(0, 1, velocity: 40), note(2, 1, velocity: 40)]
        let m = model(notes)
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 6, resolution: .beat)
        m.setVelocity(id: notes[0].id, velocity: 111)
        m.cancelGroupScale()
        #expect(m.draft.first { $0.id == notes[0].id }?.velocity == 111)
        #expect(m.draft.first { $0.id == notes[0].id }?.startBeat == 0)
        #expect(m.draft.first { $0.id == notes[1].id }?.startBeat == 2)
    }

    @Test("nothing happens without a begin")
    func aScaleNeedsItsBaseline() {
        let m = model([note(0, 1), note(2, 1)])
        let before = m.draft
        m.scaleSelection(toBeat: 8, resolution: .beat)
        #expect(m.draft.map(\.startBeat) == before.map(\.startBeat))
        // POSITIVE CONTROL: with a begin, the same call DOES move notes.
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 6, resolution: .beat)
        #expect(m.draft.map(\.startBeat) != before.map(\.startBeat))
    }

    @Test("only SELECTED notes are scaled")
    func unselectedNotesAreUntouched() {
        let notes = [note(0, 1), note(2, 1), note(6, 1)]
        let m = PianoRollModel(notes: notes, clipLengthBeats: 16)
        m.selection = [notes[0].id, notes[1].id]
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 6, resolution: .beat)
        #expect(m.draft.first { $0.id == notes[2].id }?.startBeat == 6)
        #expect(m.draft.first { $0.id == notes[2].id }?.lengthBeats == 1)
    }

    // MARK: - Degenerate selections

    @Test("a chord — every note at the same onset — scales its durations only")
    func aChordHasAScale() {
        // DEGENERATE CASE: zero onset spread. The SPAN is still positive (it is
        // measured start-to-END, and a note cannot have zero length), so there
        // is no division by zero and no refusal — the sensible answer is that the
        // chord's durations scale about its onset.
        let notes = [note(1, 2, pitch: 60), note(1, 2, pitch: 64), note(1, 2, pitch: 67)]
        let m = model(notes)
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: 2, resolution: .beat)   // span 2 -> 1
        #expect(m.draft.allSatisfy { $0.startBeat == 1 })
        #expect(m.draft.allSatisfy { $0.lengthBeats == 1 })
    }

    @Test("no note is ever pushed before beat 0")
    func nothingGoesNegative() {
        // A sweep over leading drags from every fixture position, because the
        // clamp is a GROUP clamp and one example cannot show it holds for the
        // notes that are not at the edge.
        var checked = 0
        for start in [0.0, 0.25, 1.0, 3.0] {
            for target in [-100.0, -1.0, 0.0, 0.125] {
                let notes = [note(start, 0.5), note(start + 1, 0.5), note(start + 1.5, 0.5)]
                let m = model(notes, length: 16)
                m.beginGroupScale(edge: .leading)
                m.scaleSelection(toBeat: target, resolution: .sixteenth)
                #expect(m.draft.allSatisfy { $0.startBeat >= 0 })
                #expect(m.draft.allSatisfy { $0.lengthBeats >= MIDINote.minLengthBeats })
                checked += 1
            }
        }
        #expect(checked == 16, "the sweep ran \(checked) cases, expected 16")
    }

    @Test("compressing to nothing is refused, not performed")
    func compressToZeroIsRefused() {
        // Dragging the trailing handle back past the anchor. Without the group
        // floor this is factor <= 0: every note on one beat, or the figure
        // reversed.
        let m = model([note(1, 1), note(3, 1)])
        m.beginGroupScale(edge: .trailing)
        m.scaleSelection(toBeat: -20, resolution: .sixteenth)
        let ordered = m.draft.sorted { $0.startBeat < $1.startBeat }
        #expect(ordered[0].startBeat == 1)                                   // anchor held
        #expect(ordered[1].startBeat > ordered[0].startBeat)                 // order preserved
        #expect(ordered[1].startBeat + ordered[1].lengthBeats == 1.25)       // floored span
        #expect(m.draft.allSatisfy { $0.lengthBeats >= MIDINote.minLengthBeats })
    }

    // MARK: - Auto-extend id set (decision 4)

    @Test("only notes that were audible at press may grow the clip")
    func onlyAudibleNotesMayGrowTheClip() {
        // m25-a / m25-f-3's rule, reached through a third door. A latent note
        // past the clip end must not drag the clip's edge out to itself just
        // because a stretch touched it.
        let audible = note(0, 1)
        let atTheEdge = note(4, 1)      // onset exactly AT the end: already silent
        let latent = note(12, 1)        // m18-f latent note
        let m = PianoRollModel(notes: [audible, atTheEdge, latent], clipLengthBeats: 4)
        m.selection = [audible.id, atTheEdge.id, latent.id]
        m.beginGroupScale(edge: .trailing)
        #expect(m.scaleIDsStartingAudible() == [audible.id])
    }

    @Test("the audible set is empty before a gesture begins")
    func audibleSetIsEmptyAtRest() {
        // Safe to call from any gesture-end branch — `moveIDsStartingAudible`'s
        // property, which `autoExtendIDs` relies on for both.
        let m = model([note(0, 1), note(1, 1)])
        #expect(m.scaleIDsStartingAudible().isEmpty)
    }

    // MARK: - The frame the handle is drawn from

    @Test("the group frame counts RECTS, so a stale selection id cannot conjure a handle")
    func staleSelectionIDsDoNotProduceAHandle() {
        // `selection` can name ids that are no longer in the draft. Counting ids
        // would promise a two-note handle for a one-note group.
        let live = note(0, 1)
        let m = PianoRollModel(notes: [live], clipLengthBeats: 8)
        m.selection = [live.id, UUID(), UUID()]
        #expect(m.selectedRects().count == 1)
        #expect(m.groupScaleFrame() == nil)
        // POSITIVE CONTROL: a genuinely two-note selection does get one.
        let second = note(2, 1, pitch: 64)
        m.draft.append(second)
        m.selection.insert(second.id)
        #expect(m.groupScaleFrame() != nil)
    }

    @Test("the group frame spans the selection in both axes at the live scale")
    func frameMatchesTheLiveGeometry() {
        let a = note(1, 1, pitch: 60)
        let b = note(2, 2, pitch: 67)
        let m = model([a, b])
        let frame = m.groupScaleFrame()
        // Same producer the marquee and hit test use: 32 pt/beat, 14 pt/row.
        #expect(frame?.minX == 32)
        #expect(frame?.maxX == 128)
        let height: CGFloat = frame?.height ?? -1
        // Pitches 60 and 67 are 7 rows apart, plus the bottom row's own height.
        #expect(height == 112, "selection box height was \(Double(height))")
    }
}
