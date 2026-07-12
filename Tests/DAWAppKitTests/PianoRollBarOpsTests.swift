import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for the piano-roll bar-ops arithmetic (beta m10-h): which
/// bar the insert/delete buttons target given the transport position + clip
/// geometry, the one-based readout, and the delete-enable gate. The SwiftUI
/// header is thin over this (the `PianoRollPlayhead` precedent).
@Suite("PianoRollBarOps")
struct PianoRollBarOpsTests {
    private func target(pos: Double, start: Double = 0, length: Double = 16, bpb: Int = 4) -> Double {
        PianoRollBarOps.targetBarStartBeat(
            position: pos, clipStartBeat: start, lengthBeats: length, beatsPerBar: bpb)
    }

    @Test("target bar floors the playhead's clip-local beat to a bar boundary")
    func targetInsideClip() {
        #expect(target(pos: 0) == 0)
        #expect(target(pos: 3.9) == 0)
        #expect(target(pos: 4) == 4)
        #expect(target(pos: 6) == 4)
        #expect(target(pos: 8) == 8)
        #expect(target(pos: 13) == 12)
    }

    @Test("a playhead resting exactly on the clip end targets the LAST bar, not a phantom one")
    func targetAtClipEnd() {
        #expect(target(pos: 16, length: 16) == 12)   // last of four 4-beat bars
    }

    @Test("target maps through the clip's timeline offset (clip-local, not project, beats)")
    func targetHonorsClipStart() {
        // Clip sits at beat 8; playhead at 14 → clip-local 6 → bar index 1 → start 4.
        #expect(target(pos: 14, start: 8) == 4)
    }

    @Test("a transport OUTSIDE the clip falls back to the first bar")
    func targetFallsBackWhenOutside() {
        #expect(target(pos: 2, start: 8) == 0)     // before the clip
        #expect(target(pos: 30, start: 8, length: 16) == 0)   // after the clip (ends at 24)
    }

    @Test("target is meter-aware (3/4 → three-beat bars)")
    func targetMeterAware() {
        #expect(target(pos: 7, length: 12, bpb: 3) == 6)   // floor(7/3) = 2 → start 6
        #expect(target(pos: 2, length: 12, bpb: 3) == 0)
    }

    @Test("bar number is one-based off the target bar")
    func barNumber() {
        func number(pos: Double, length: Double = 16, bpb: Int = 4) -> Int {
            PianoRollBarOps.targetBarNumber(
                position: pos, clipStartBeat: 0, lengthBeats: length, beatsPerBar: bpb)
        }
        #expect(number(pos: 0) == 1)
        #expect(number(pos: 6) == 2)
        #expect(number(pos: 12) == 4)
        #expect(number(pos: 7, length: 12, bpb: 3) == 3)   // start 6 / 3 + 1
    }

    @Test("delete is enabled only when the clip is longer than one bar (meter-aware)")
    func deleteGate() {
        #expect(PianoRollBarOps.canDeleteBar(lengthBeats: 8, beatsPerBar: 4))     // 2 bars
        #expect(PianoRollBarOps.canDeleteBar(lengthBeats: 6, beatsPerBar: 4))     // 1.5 bars
        #expect(!PianoRollBarOps.canDeleteBar(lengthBeats: 4, beatsPerBar: 4))    // exactly 1 bar → off
        #expect(!PianoRollBarOps.canDeleteBar(lengthBeats: 3, beatsPerBar: 4))    // under 1 bar → off
        #expect(PianoRollBarOps.canDeleteBar(lengthBeats: 4, beatsPerBar: 3))     // >1 bar in 3/4
        #expect(!PianoRollBarOps.canDeleteBar(lengthBeats: 3, beatsPerBar: 3))    // exactly 1 bar in 3/4 → off
    }
}
