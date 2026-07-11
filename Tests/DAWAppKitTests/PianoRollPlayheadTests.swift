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
}
