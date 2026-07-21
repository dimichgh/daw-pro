import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `PianoRollZoom` (m21-c): the piano roll's horizontal
/// pixels-per-beat clamp + step ladder (the `ArrangeZoom` sibling), the percent
/// readout, and the zoom-adaptive grid-density rules the note-grid Canvas reads
/// (sub-beat lines fade out before a 1/64 or triplet grid can become visual
/// soup). Pure value math — no SwiftUI, no store.
@Suite("PianoRollZoom — piano-roll zoom math (m21-c)")
struct PianoRollZoomTests {

    // MARK: - Clamp + ladder

    @Test("clamp tames any scale into 4…200; the 32 pt/beat default sits inside")
    func clampRange() {
        #expect(PianoRollZoom.pixelsPerBeatRange == 4...200)
        #expect(PianoRollZoom.clamp(9999) == 200)
        #expect(PianoRollZoom.clamp(0) == 4)
        #expect(PianoRollZoom.clamp(-5) == 4)
        #expect(PianoRollZoom.clamp(32) == 32)
        #expect(PianoRollZoom.pixelsPerBeatRange.contains(PianoRollZoom.defaultPixelsPerBeat))
        // The model's drawing constant reads THIS value — one source of truth.
        #expect(PianoRollZoom.defaultPixelsPerBeat == 32)
    }

    @Test("the roll's ladder stays in lockstep with the arrange surface")
    func mirrorsArrangeIdiom() {
        // Same multiplicative step and same clamp bounds (m21-c mirrors m17-b),
        // so one ⌘+/⌘− press FEELS identical on both surfaces.
        #expect(PianoRollZoom.stepFactor == ArrangeZoom.stepFactor)
        #expect(PianoRollZoom.pixelsPerBeatRange == ArrangeZoom.pixelsPerBeatRange)
    }

    @Test("zoomedIn/zoomedOut walk the multiplicative ladder and saturate at the bounds")
    func ladder() {
        #expect(PianoRollZoom.zoomedIn(32) == 40)          // 32 × 1.25
        #expect(PianoRollZoom.zoomedOut(40) == 32)         // exact inverse
        // Round-trip is exact at any interior scale (multiply then divide).
        let there = PianoRollZoom.zoomedIn(50)
        #expect(abs(PianoRollZoom.zoomedOut(there) - 50) < 1e-9)
        // Saturation: stepping past a bound clamps and stays there.
        #expect(PianoRollZoom.zoomedIn(200) == 200)
        #expect(PianoRollZoom.zoomedIn(180) == 200)        // 225 → clamped
        #expect(PianoRollZoom.zoomedOut(4) == 4)
        #expect(PianoRollZoom.zoomedOut(4.5) == 4)         // 3.6 → clamped
    }

    @Test("percentLabel reads relative to the roll's own 32 pt/beat default")
    func percentLabel() {
        #expect(PianoRollZoom.percentLabel(pixelsPerBeat: 32) == "100%")
        #expect(PianoRollZoom.percentLabel(pixelsPerBeat: 64) == "200%")
        #expect(PianoRollZoom.percentLabel(pixelsPerBeat: 16) == "50%")
        #expect(PianoRollZoom.percentLabel(pixelsPerBeat: 4) == "13%")    // 12.5 rounds up
        #expect(PianoRollZoom.percentLabel(pixelsPerBeat: 200) == "625%")
    }

    // MARK: - Grid density (the sub-beat fade)

    @Test("sub-beat lines are hidden at ≤4 pt spacing, full at ≥8 pt, a linear ramp between")
    func subBeatFadeThresholds() {
        // Spacing = step · ppb. Pin the ramp shape at a fixed 1-pt step.
        #expect(PianoRollZoom.subBeatLineAlpha(step: 1, pixelsPerBeat: 4) == 0)
        #expect(PianoRollZoom.subBeatLineAlpha(step: 1, pixelsPerBeat: 3) == 0)
        #expect(PianoRollZoom.subBeatLineAlpha(step: 1, pixelsPerBeat: 8) == 1)
        #expect(PianoRollZoom.subBeatLineAlpha(step: 1, pixelsPerBeat: 20) == 1)
        #expect(abs(PianoRollZoom.subBeatLineAlpha(step: 1, pixelsPerBeat: 6) - 0.5) < 1e-9)
        // Degenerate step never divides by zero or shows lines.
        #expect(PianoRollZoom.subBeatLineAlpha(step: 0, pixelsPerBeat: 100) == 0)
        #expect(PianoRollZoom.subBeatLineAlpha(step: -1, pixelsPerBeat: 100) == 0)
    }

    @Test("a 1/64 grid is invisible at the default zoom and earns full lines when zoomed in")
    func sixtyFourthFadesByZoom() {
        let step = SnapResolution.sixtyFourth.beats!               // 0.0625 beat
        // Default 32 pt/beat → 2 pt spacing → hidden (never visual soup).
        #expect(PianoRollZoom.subBeatLineAlpha(step: step, pixelsPerBeat: 32) == 0)
        // 96 pt/beat → 6 pt → mid-fade; 128 pt/beat → 8 pt → full strength.
        #expect(abs(PianoRollZoom.subBeatLineAlpha(step: step, pixelsPerBeat: 96) - 0.5) < 1e-9)
        #expect(PianoRollZoom.subBeatLineAlpha(step: step, pixelsPerBeat: 128) == 1)
        // The fade is monotonic in zoom — lines only ever brighten zooming in.
        var last = -1.0
        for ppb in stride(from: 4.0, through: 200.0, by: 4.0) {
            let alpha = PianoRollZoom.subBeatLineAlpha(step: step, pixelsPerBeat: ppb)
            #expect(alpha >= last)
            last = alpha
        }
    }

    @Test("the pre-zoom defaults keep their grid: 1/16 lines draw full-strength at 32 pt/beat")
    func historicalGridUnchangedAtDefaultZoom() {
        // The m21-c fade must NOT dim what the roll always drew: at the default
        // scale an eighth (16 pt) or sixteenth (8 pt) grid stays full strength.
        #expect(PianoRollZoom.subBeatLineAlpha(step: 0.5, pixelsPerBeat: 32) == 1)
        #expect(PianoRollZoom.subBeatLineAlpha(step: 0.25, pixelsPerBeat: 32) == 1)
        // Triplets at the default: 1/8T ≈ 10.7 pt → full; 1/16T ≈ 5.3 pt → mid-fade.
        #expect(PianoRollZoom.subBeatLineAlpha(step: 1.0 / 3.0, pixelsPerBeat: 32) == 1)
        let t16 = PianoRollZoom.subBeatLineAlpha(step: 1.0 / 6.0, pixelsPerBeat: 32)
        #expect(t16 > 0 && t16 < 1)
    }

    @Test("divisionsPerBeat turns a snap step into exact per-beat divisions (triplets included)")
    func divisionsPerBeat() {
        #expect(PianoRollZoom.divisionsPerBeat(step: 0.5) == 2)
        #expect(PianoRollZoom.divisionsPerBeat(step: 0.25) == 4)
        #expect(PianoRollZoom.divisionsPerBeat(step: 0.125) == 8)
        #expect(PianoRollZoom.divisionsPerBeat(step: 0.0625) == 16)
        #expect(PianoRollZoom.divisionsPerBeat(step: 1.0 / 3.0) == 3)     // 1/8T
        #expect(PianoRollZoom.divisionsPerBeat(step: 1.0 / 6.0) == 6)     // 1/16T
        // Beat-or-coarser steps (and degenerates) draw no sub-divisions.
        #expect(PianoRollZoom.divisionsPerBeat(step: 1) == 1)
        #expect(PianoRollZoom.divisionsPerBeat(step: 4) == 1)
        #expect(PianoRollZoom.divisionsPerBeat(step: 0) == 1)
        // Every sub-beat snap's division count reconstructs its own step, so
        // the painter's rational positions (beat + d/divisions) land exactly
        // on the snap grid — triplet lines never drift off their snap targets.
        for snap in SnapResolution.allCases {
            guard let beats = snap.beats, beats < 1 else { continue }
            let divisions = PianoRollZoom.divisionsPerBeat(step: beats)
            #expect(abs(1.0 / Double(divisions) - beats) < 1e-12,
                    "\(snap.rawValue): \(divisions) divisions don't reconstruct \(beats)")
        }
    }
}
