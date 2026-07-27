import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// Unit tests for the headless piano-roll playhead mapping (beta m10-e). The
/// SwiftUI view is thin over this — it draws the cyan line at `lineX` and seeks
/// through `scrubProjectBeat` — so exercising the timeline↔clip-local math here
/// covers the editor playhead's logic without a display (the `PianoRollModel`
/// test-suite style).
@Suite("PianoRollPlayhead")
struct PianoRollPlayheadTests {

    private let ppb: CGFloat = 32   // PianoRollModel.defaultPixelsPerBeat

    // 1. local beat = project position minus the clip's start on the timeline.
    @Test("localBeat subtracts the clip's timeline offset")
    func localBeatOffset() {
        // Clip starts at bar-3 (beat 8); transport at beat 10 → local beat 2.
        #expect(PianoRollPlayhead.localBeat(position: 10, clipStartBeat: 8) == 2)
        // Transport before the clip → negative local (still returned; caller gates).
        #expect(PianoRollPlayhead.localBeat(position: 5, clipStartBeat: 8) == -3)
        // A clip at the very start is an identity map.
        #expect(PianoRollPlayhead.localBeat(position: 4.5, clipStartBeat: 0) == 4.5)
    }

    // 2. Visibility window: inside, outside (both sides), and the exact edges.
    @Test("isVisible is true only within the clip span, inclusive at both edges")
    func visibilityWindow() {
        let start = 8.0, len = 4.0   // clip occupies project beats 8...12
        // Inside.
        #expect(PianoRollPlayhead.isVisible(position: 10, clipStartBeat: start, lengthBeats: len))
        // Exact edges are inclusive (line shows at the clip's start and end).
        #expect(PianoRollPlayhead.isVisible(position: 8, clipStartBeat: start, lengthBeats: len))
        #expect(PianoRollPlayhead.isVisible(position: 12, clipStartBeat: start, lengthBeats: len))
        // Just outside either edge → no line (honest absence, no edge parking).
        #expect(!PianoRollPlayhead.isVisible(position: 7.999, clipStartBeat: start, lengthBeats: len))
        #expect(!PianoRollPlayhead.isVisible(position: 12.001, clipStartBeat: start, lengthBeats: len))
        // Far away in both directions.
        #expect(!PianoRollPlayhead.isVisible(position: 0, clipStartBeat: start, lengthBeats: len))
        #expect(!PianoRollPlayhead.isVisible(position: 100, clipStartBeat: start, lengthBeats: len))
    }

    // 3. lineX: the beat→pixel expression, and nil outside the span.
    @Test("lineX maps to (position − start)·ppb inside the span, nil outside")
    func lineXExpression() {
        let start = 8.0, len = 4.0
        // Beat 10 → local 2 → 2·32 = 64 pt.
        #expect(PianoRollPlayhead.lineX(position: 10, clipStartBeat: start,
                                        lengthBeats: len, pixelsPerBeat: ppb) == 64)
        // Clip start → x 0; clip end → len·ppb.
        #expect(PianoRollPlayhead.lineX(position: 8, clipStartBeat: start,
                                        lengthBeats: len, pixelsPerBeat: ppb) == 0)
        #expect(PianoRollPlayhead.lineX(position: 12, clipStartBeat: start,
                                        lengthBeats: len, pixelsPerBeat: ppb) == 128)
        // Outside → nil (no line).
        #expect(PianoRollPlayhead.lineX(position: 4, clipStartBeat: start,
                                        lengthBeats: len, pixelsPerBeat: ppb) == nil)
    }

    // 4. Scrub x→beat clamps to the clip span at BOTH ends, then re-offsets.
    @Test("scrubProjectBeat maps content x to a clamped project beat")
    func scrubClamp() {
        let start = 8.0, len = 4.0
        // Mid-clip: x 64 → local 2 → project 10 (free/unsnapped, so a fractional x maps straight through).
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 64, clipStartBeat: start,
                                                   lengthBeats: len, pixelsPerBeat: ppb) == 10)
        // Fractional x is NOT snapped — the free-scrub default.
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 80, clipStartBeat: start,
                                                   lengthBeats: len, pixelsPerBeat: ppb) == 10.5)
        // Negative x clamps to the clip start (project = start).
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: -40, clipStartBeat: start,
                                                   lengthBeats: len, pixelsPerBeat: ppb) == 8)
        // x past the clip end clamps to the clip end (project = start + len).
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 10_000, clipStartBeat: start,
                                                   lengthBeats: len, pixelsPerBeat: ppb) == 12)
        // Exact end x is inside (no over-clamp).
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 128, clipStartBeat: start,
                                                   lengthBeats: len, pixelsPerBeat: ppb) == 12)
    }

    // 5. A clip at the timeline origin: local == project, scrub floors at 0.
    @Test("a clip at beat 0 maps identity and floors a negative scrub at 0")
    func clipAtOrigin() {
        let start = 0.0, len = 8.0
        #expect(PianoRollPlayhead.lineX(position: 3, clipStartBeat: start,
                                        lengthBeats: len, pixelsPerBeat: ppb) == 96)
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: -5, clipStartBeat: start,
                                                   lengthBeats: len, pixelsPerBeat: ppb) == 0)
        #expect(PianoRollPlayhead.scrubProjectBeat(localX: 96, clipStartBeat: start,
                                                   lengthBeats: len, pixelsPerBeat: ppb) == 3)
    }

    // MARK: - Off-clip edge cue (m23-c1)

    // 6. THE load-bearing invariant: the cue and the line are complementary, at
    //    the inclusive edges included. If this ever fails the two objects can
    //    double-draw (both on) or the band can go silent again (both off).
    @Test("offClipCue is non-nil EXACTLY when lineX is nil, edges included")
    func cueComplementsTheLine() {
        let start = 8.0, len = 4.0   // clip occupies project beats 8...12
        // A dense sweep across and well past both edges, hitting the exact edges.
        var position = 0.0
        while position <= 24.0 {
            let line = PianoRollPlayhead.lineX(position: position, clipStartBeat: start,
                                               lengthBeats: len, pixelsPerBeat: ppb)
            let cue = PianoRollPlayhead.offClipCue(position: position, clipStartBeat: start,
                                                   lengthBeats: len, beatsPerBar: 4)
            #expect((line == nil) == (cue != nil),
                    "line and cue must never both draw or both vanish at beat \(position)")
            position += 0.25
        }
        // The exact inclusive edges belong to the LINE — no cue there.
        #expect(PianoRollPlayhead.offClipCue(position: 8, clipStartBeat: start,
                                             lengthBeats: len, beatsPerBar: 4) == nil)
        #expect(PianoRollPlayhead.offClipCue(position: 12, clipStartBeat: start,
                                             lengthBeats: len, beatsPerBar: 4) == nil)
        // One tick outside either edge the cue takes over.
        #expect(PianoRollPlayhead.offClipCue(position: 7.999, clipStartBeat: start,
                                             lengthBeats: len, beatsPerBar: 4) != nil)
        #expect(PianoRollPlayhead.offClipCue(position: 12.001, clipStartBeat: start,
                                             lengthBeats: len, beatsPerBar: 4) != nil)
    }

    // 7. Side + distance are measured to the clip's NEAR edge, both directions.
    @Test("offClipCue reports the direction and the distance to the near edge")
    func cueSideAndDistance() {
        let start = 8.0, len = 4.0
        let before = PianoRollPlayhead.offClipCue(position: 0, clipStartBeat: start,
                                                  lengthBeats: len, beatsPerBar: 4)
        #expect(before?.side == .before)
        #expect(before?.beatsAway == 8)          // 8 beats before the clip start
        #expect(before?.label == "2 BARS")
        let after = PianoRollPlayhead.offClipCue(position: 20, clipStartBeat: start,
                                                 lengthBeats: len, beatsPerBar: 4)
        #expect(after?.side == .after)
        #expect(after?.beatsAway == 8)           // 8 beats past the clip END (beat 12)
        #expect(after?.label == "2 BARS")
    }

    // 8. The proximity ramp: 0 at/beyond the approach window, 1 at the edge, and
    //    monotonically rising in between (this is the motion the user reported
    //    missing, so it has to actually change with position).
    @Test("proximity ramps from 0 at approachBars away up to 1 at the edge")
    func cueProximityRamp() {
        let start = 16.0, len = 8.0, bpb = 4
        let window = Double(bpb) * PianoRollPlayhead.approachBars   // 16 beats
        func proximity(at position: Double) -> Double {
            PianoRollPlayhead.offClipCue(position: position, clipStartBeat: start,
                                         lengthBeats: len, beatsPerBar: bpb)?.proximity ?? -1
        }
        #expect(proximity(at: start - window) == 0)          // exactly one window out
        #expect(proximity(at: start - window - 40) == 0)     // clamped, never negative
        #expect(abs(proximity(at: start - window / 2) - 0.5) < 1e-9)
        // Approaching the clip raises it, and it stays under 1 until the edge.
        let near = proximity(at: start - 0.5)
        #expect(near > 0.9 && near < 1)
        // Same ramp on the far side, measured from the clip END.
        #expect(proximity(at: start + len + window) == 0)
        #expect(abs(proximity(at: start + len + window / 2) - 0.5) < 1e-9)
    }

    // 9. Label formatting: unit choice, singular/plural, one decimal, and the
    //    floor that keeps it from ever claiming a zero distance.
    @Test("distanceLabel reads in bars, falls back to beats, never says 0")
    func cueDistanceLabel() {
        // Bars once it rounds to a bar or more.
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 32, beatsPerBar: 4) == "8 BARS")
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 4, beatsPerBar: 4) == "1 BAR")
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 6, beatsPerBar: 4) == "1.5 BARS")
        // Unit is picked from the ROUNDED bar count, so no flicker at the edge
        // of the boundary: 3.97 beats in 4/4 reads as one bar, not four beats.
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 3.97, beatsPerBar: 4) == "1 BAR")
        // Below that, beats.
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 3, beatsPerBar: 4) == "3 BEATS")
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 1, beatsPerBar: 4) == "1 BEAT")
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 0.5, beatsPerBar: 4) == "0.5 BEATS")
        // Never 0 — that would read as "at the edge", the parked-playhead claim.
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 0.01, beatsPerBar: 4) == "0.1 BEATS")
        // Meter-aware: 7 beats is one bar in 7/8, not quite two in 4/4.
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 7, beatsPerBar: 7) == "1 BAR")
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 7, beatsPerBar: 4) == "1.8 BARS")
        // A degenerate meter can't divide by zero.
        #expect(PianoRollPlayhead.distanceLabel(beatsAway: 3, beatsPerBar: 0) == "3 BARS")
    }

    // 10. A clip at the timeline origin can only ever be overshot — there is no
    //     "before" side to be on, since the transport floors at beat 0.
    @Test("a clip at beat 0 only ever shows an AFTER cue")
    func cueAtOrigin() {
        let start = 0.0, len = 8.0
        #expect(PianoRollPlayhead.offClipCue(position: 0, clipStartBeat: start,
                                             lengthBeats: len, beatsPerBar: 4) == nil)
        let past = PianoRollPlayhead.offClipCue(position: 12, clipStartBeat: start,
                                                lengthBeats: len, beatsPerBar: 4)
        #expect(past?.side == .after)
        #expect(past?.label == "1 BAR")
    }
}
