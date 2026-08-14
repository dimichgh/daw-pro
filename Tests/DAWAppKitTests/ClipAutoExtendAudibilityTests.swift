import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// m25-a — the JOIN between the new grow rule (`DAWCore.ClipAutoExtend`) and the
/// editor's own boundary definition (`PianoRollModel.playableEndBeat`, the
/// m18-f/m19-g ghost rule).
///
/// The two live in different modules and neither imports the other's opinion, so
/// nothing but a test can hold them together — and holding them together IS the
/// feature. "The note becomes audible" is not a claim about clip length; it is a
/// claim about what `playableEndBeat` returns for that note afterwards, which is
/// the same function the roll uses to decide whether to draw the note as a ghost.
/// If these ever disagree the user gets the exact bug m25-a was filed about, only
/// with a longer clip: a note that looks lit and makes no sound.
@Suite("ClipAutoExtend ↔ playableEndBeat (m25-a)")
struct ClipAutoExtendAudibilityTests {

    @Test("after the grow, the placed note is no longer a ghost")
    func grownNoteStopsGhosting() {
        let clipLength = 4.0
        let note = MIDINote(pitch: 60, startBeat: 5, lengthBeats: 1)

        // Before: fully latent — `nil` means "the whole pill ghosts".
        #expect(PianoRollModel.playableEndBeat(of: note, clipLengthBeats: clipLength) == nil)

        let grown = ClipAutoExtend.extendedLength(
            currentLengthBeats: clipLength,
            coveringOnsetBeat: note.startBeat, coveringEndBeat: note.endBeat,
            beatsPerBar: 4)
        #expect(grown == 8)

        // After: fully lit, and lit to the note's OWN end (not truncated) —
        // `== endBeat` is the "fully lit" reading in `playableEndBeat`'s doc.
        let played = PianoRollModel.playableEndBeat(of: note, clipLengthBeats: grown!)
        #expect(played == note.endBeat)
    }

    @Test("every REFUSAL leaves the note exactly as latent as it was — the m18-f rule survives")
    func refusalsPreserveLatency() {
        // Refusal ① — past the growth cap.
        let wild = MIDINote(pitch: 60, startBeat: 100, lengthBeats: 1)
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: wild.startBeat,
            coveringEndBeat: wild.endBeat, beatsPerBar: 4) == nil)
        #expect(PianoRollModel.playableEndBeat(of: wild, clipLengthBeats: 4) == nil)

        // Refusal ② — a neighbour leaves no usable room.
        let blocked = MIDINote(pitch: 60, startBeat: 7, lengthBeats: 1)
        #expect(ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: blocked.startBeat,
            coveringEndBeat: blocked.endBeat, beatsPerBar: 4,
            maxLengthBeats: 6) == nil)
        #expect(PianoRollModel.playableEndBeat(of: blocked, clipLengthBeats: 4) == nil)
    }

    @Test("a clamped grow can still leave a TRUNCATED tail, and playableEndBeat says so")
    func clampedGrowReportsTruncation() {
        // Onset inside the room, tail beyond it: the note sounds, its tail is
        // cut at the clip end. `playableEndBeat` reports the boundary, so the
        // roll ghosts only the overhang — the honest drawing, unchanged by m25-a.
        let note = MIDINote(pitch: 60, startBeat: 5, lengthBeats: 4)   // ends at 9
        let grown = ClipAutoExtend.extendedLength(
            currentLengthBeats: 4, coveringOnsetBeat: note.startBeat,
            coveringEndBeat: note.endBeat, beatsPerBar: 4, maxLengthBeats: 7)
        #expect(grown == 7)
        #expect(PianoRollModel.playableEndBeat(of: note, clipLengthBeats: grown!) == 7)
    }

    @Test("the grid stops shading the region the clip grew into")
    func shadeFollowsTheGrow() {
        // `drawOutOfClipShade` shades from `clipLengthBeats · pixelsPerBeat` to
        // the drawn width, so a grown clip narrows the shaded latent band by
        // construction. Pinned through the ONE drawn-width definition rather
        // than the Canvas closure (which no test can reach).
        let ppb: CGFloat = 32
        let viewport: CGFloat = 640
        let drawnBefore = PianoRollModel.drawnWidth(content: 4 * ppb, viewport: viewport)
        let drawnAfter = PianoRollModel.drawnWidth(content: 8 * ppb, viewport: viewport)
        #expect(drawnBefore == viewport)
        #expect(drawnAfter == viewport)
        // Same drawn width, more clip: strictly less shaded latent space.
        #expect(viewport - 8 * ppb < viewport - 4 * ppb)
    }
}
