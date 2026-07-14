import CoreGraphics
import Foundation
import Testing
import DAWCore
@testable import DAWAppKit

/// Unit tests for the headless MIDI mini-note-map geometry (beta m10-f). The
/// arrange `ClipMIDIMap` view and the take-lane note strip are thin over this —
/// each note's pill rect comes straight from `noteRects` — so exercising the
/// pitch↔y / beat↔x math here covers the note map's logic without a display (the
/// `PianoRollPlayhead` / `TakeLaneGeometry` test-suite style).
@Suite("MIDIMapGeometry")
struct MIDIMapGeometryTests {

    private let ppb: CGFloat = 16   // TimelineLanesView.pixelsPerBeat

    private func note(_ pitch: Int, start: Double, length: Double = 1) -> MIDINote {
        MIDINote(pitch: pitch, startBeat: start, lengthBeats: length)
    }

    // 1. Empty notes → no rects, and no pitch span (nothing to draw, no crash).
    @Test("empty notes produce no rects and no span")
    func emptyIsNoOp() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)
        #expect(g.noteRects([], clipLengthBeats: 8, height: 30).isEmpty)
        #expect(MIDIMapGeometry.pitchSpan([]) == nil)
    }

    // 2. Pitch span is the min/max across all notes.
    @Test("pitchSpan spans the lowest and highest note")
    func spanBounds() {
        let notes = [note(60, start: 0), note(72, start: 1), note(48, start: 2)]
        let span = MIDIMapGeometry.pitchSpan(notes)
        #expect(span?.lo == 48)
        #expect(span?.hi == 72)
    }

    // 3. x = startBeat·ppb; width = lengthBeats·ppb; pill height is the config value.
    @Test("x and width map beats to pixels")
    func horizontalMapping() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)   // default pillHeight 3
        // Two pitches so the span is real (2 semitones); take the note at beat 2, len 3.
        let notes = [note(60, start: 0), note(62, start: 2, length: 3)]
        let rects = g.noteRects(notes, clipLengthBeats: 8, height: 30)
        #expect(rects.count == 2)
        // Second note: x = 2·16 = 32, width = 3·16 = 48, height = pill 3.
        #expect(rects[1].origin.x == 32)
        #expect(rects[1].width == 48)
        #expect(rects[1].height == 3)
    }

    // 4. Higher pitch sits nearer the TOP; lowest pitch nearer the bottom.
    @Test("higher pitch maps to a smaller y (nearer the top)")
    func pitchVerticalOrder() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)   // inset 3, pill 3
        let height: CGFloat = 30
        // lo = 60 → frac 0 → centerY = 30 - 3 - 0 = 27; rectY = 27 - 1.5 = 25.5.
        // hi = 72 → frac 1 → centerY = 30 - 3 - (30-6) = 3;  rectY = 3 - 1.5 = 1.5.
        let rects = g.noteRects([note(60, start: 0), note(72, start: 1)], clipLengthBeats: 8, height: height)
        #expect(rects[0].origin.y == 25.5)   // low pitch → bottom
        #expect(rects[1].origin.y == 1.5)    // high pitch → top
        #expect(rects[1].origin.y < rects[0].origin.y)
    }

    // 5. pitchFraction: endpoints and the midpoint of a clean span.
    @Test("pitchFraction is 0 at lo, 1 at hi, 0.5 at the midpoint")
    func fractionMapping() {
        #expect(MIDIMapGeometry.pitchFraction(60, lo: 60, hi: 72) == 0)
        #expect(MIDIMapGeometry.pitchFraction(72, lo: 60, hi: 72) == 1)
        #expect(MIDIMapGeometry.pitchFraction(66, lo: 60, hi: 72) == 0.5)
    }

    // 6. Single-pitch clip: span clamps to 1, every note reads frac 0 → the bottom
    //    (the take-lane idiom — a single pitch has no vertical span to show).
    @Test("a single-pitch clip clamps the span and lands notes at the bottom")
    func singlePitchClamp() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)
        let height: CGFloat = 30
        let rects = g.noteRects([note(64, start: 0), note(64, start: 2)], clipLengthBeats: 8, height: height)
        #expect(rects.count == 2)
        // frac 0 → centerY = 30 - 3 = 27 → rectY 25.5 for both.
        #expect(rects[0].origin.y == 25.5)
        #expect(rects[1].origin.y == 25.5)
        // No division blow-up: fraction is finite.
        #expect(MIDIMapGeometry.pitchFraction(64, lo: 64, hi: 64) == 0)
    }

    // 7. Min pill width: a near-zero-length note still draws a visible pill.
    @Test("a very short note keeps the minimum pill width")
    func minPillWidth() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb, minPillWidth: 2)
        // length 0.01 beats → 0.16 pt raw, clamped up to minPillWidth 2.
        let rects = g.noteRects([note(60, start: 0, length: 0.01), note(62, start: 1)],
                                clipLengthBeats: 8, height: 30)
        #expect(rects[0].width == 2)
    }

    // 8. A note extending past the clip end is clamped to the right edge.
    @Test("a note past the clip end clamps its width to the clip's right edge")
    func clampWidthToClipEnd() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)
        // Clip is 4 beats → contentWidth 64. Note starts at beat 3 (x 48), length 5
        // beats (raw width 80) → clamped to 64 - 48 = 16.
        let rects = g.noteRects([note(60, start: 3, length: 5), note(62, start: 0)],
                                clipLengthBeats: 4, height: 30)
        let clamped = rects.first { $0.origin.x == 48 }
        #expect(clamped?.width == 16)
        // The pill never crosses the clip's right edge.
        #expect((clamped?.maxX ?? .infinity) <= 64)
    }

    // 9. A note starting at or after the clip end has no visible extent → dropped.
    @Test("a note starting at/after the clip end is dropped")
    func dropNoteAfterEnd() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)
        // Clip 4 beats (contentWidth 64). A note at beat 4 (x 64) starts AT the end.
        let rects = g.noteRects([note(60, start: 4), note(62, start: 1)],
                                clipLengthBeats: 4, height: 30)
        #expect(rects.count == 1)          // only the in-bounds note survives
        #expect(rects[0].origin.x == 16)   // the beat-1 note
    }

    // 10. Vertical inset keeps pills off both edges across the m10-d row range.
    @Test("pills stay within the drawable bounds at the row-height extremes")
    func verticalBoundsAcrossRowHeights() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)   // inset 3, pill 3
        for height in [CGFloat(24), 44, 64] {
            let rects = g.noteRects([note(0, start: 0), note(127, start: 1)],
                                    clipLengthBeats: 8, height: height)
            for r in rects {
                #expect(r.minY >= 0)        // top pill fits under the top edge
                #expect(r.maxY <= height)   // bottom pill fits above the bottom edge
            }
        }
    }

    // 11. Equatable value type (the pure-geometry contract).
    @Test("geometry is an Equatable value type")
    func equatable() {
        #expect(MIDIMapGeometry(pixelsPerBeat: 16) == MIDIMapGeometry(pixelsPerBeat: 16))
        #expect(MIDIMapGeometry(pixelsPerBeat: 16) != MIDIMapGeometry(pixelsPerBeat: 32))
    }

    // MARK: - controllerTrace (m16-b4 arrange mini-map)

    // 12. Empty lane → no trace (nothing to draw; the caller skips the stroke so a
    //     laneless clip is pixel-identical).
    @Test("an empty controller lane produces no trace points")
    func controllerTraceEmpty() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)
        let empty = MIDIControllerLane(type: .cc(controller: 1), points: [])
        #expect(g.controllerTrace(empty, clipLengthBeats: 8, height: 30).isEmpty)
    }

    // 13. A stepped CC trace holds each value until the next point, then steps —
    //     never an interpolated slope — and maps into the bottom 20% band with
    //     higher values nearer the top of the band. Extends the last value out to
    //     the clip's right edge.
    @Test("controllerTrace steps in the bottom band and holds to the right edge")
    func controllerTraceStepped() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)   // 16 pt/beat
        let height: CGFloat = 30                       // band = 6 pt (bottom 20%)
        // CC 0 @0, CC 127 @2 in a 4-beat clip (contentWidth 64).
        let lane = MIDIControllerLane(type: .cc(controller: 1), points: [
            MIDIControllerPoint(beat: 0, value: 0),
            MIDIControllerPoint(beat: 2, value: 127),
        ])
        let pts = g.controllerTrace(lane, clipLengthBeats: 4, height: height)
        // value 0 → y = height = 30 (bottom edge); value 127 → y = 30 - 6 = 24.
        // Trace: (0,30) → hold (32,30) → step (32,24) → hold to right edge (64,24).
        #expect(pts == [
            CGPoint(x: 0, y: 30),
            CGPoint(x: 32, y: 30),
            CGPoint(x: 32, y: 24),
            CGPoint(x: 64, y: 24),
        ])
        // Every segment is axis-aligned (stepwise, never a diagonal ramp).
        for i in 1..<pts.count {
            let horizontal = pts[i].y == pts[i - 1].y
            let vertical = pts[i].x == pts[i - 1].x
            #expect(horizontal || vertical)
        }
    }

    // 14. Bend uses the wider 16383 domain and clamps x to the clip's right edge; a
    //     point past the clip end never draws beyond the block.
    @Test("controllerTrace uses the lane's value domain and clamps x to the clip end")
    func controllerTraceBendDomainAndClamp() {
        let g = MIDIMapGeometry(pixelsPerBeat: ppb)
        let height: CGFloat = 40                       // band = 8 pt
        // Bend center (8192) then a point past the 2-beat clip end (contentWidth 32).
        let lane = MIDIControllerLane(type: .pitchBend, points: [
            MIDIControllerPoint(beat: 0, value: 8192),
            MIDIControllerPoint(beat: 5, value: 16383),
        ])
        let pts = g.controllerTrace(lane, clipLengthBeats: 2, height: height)
        // center 8192/16383 ≈ 0.5 → y ≈ 40 - 8·0.5 = 36; max 16383 → y = 40 - 8 = 32.
        #expect(abs(pts[0].y - 36) < 0.01)             // bend center in the band
        // The out-of-clip point's x clamps to the right edge (32), never past it.
        #expect(pts.map(\.x).max() == 32)
    }
}
