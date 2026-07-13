import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit
import DAWCore

/// Unit tests for the headless clip-edit geometry, snap math, hit
/// classification, trim/fade/split preview, and gain formatting. The arrange
/// clip gesture layer is thin over these, so exercising them here covers the
/// editor's logic without a display (the AutomationLaneModel precedent).
@Suite("ClipEditModel")
struct ClipEditModelTests {

    private func geometry() -> ClipEditGeometry { ClipEditGeometry() }

    /// Trivial single-meter map at `bpb` beats/bar — the byte-equivalence anchor
    /// (a trivial map reproduces the old base-meter `beatsPerBar` math exactly).
    private func meter(_ bpb: Int = 4) -> MeterMap {
        MeterMap(constant: TimeSignature(beatsPerBar: bpb))
    }

    /// A 4/4 → 6/8 map: 6/8 (top-number convention, beatUnit cosmetic in v1 →
    /// bpb 6) starts at beat 16. 4/4 barlines: 0,4,8,12,16; 6/8 barlines from the
    /// change: 16,22,28,… — a non-uniform bar grid across the boundary.
    private func crossMeter() -> MeterMap {
        try! MeterMap(changes: [
            .init(startBeat: 0, beatsPerBar: 4, beatUnit: 4),
            .init(startBeat: 16, beatsPerBar: 6, beatUnit: 8),
        ])
    }

    /// The legacy base-meter snap formula, implemented inline so the trivial-map
    /// regression compares against the ORIGINAL arithmetic (grid rounding, floored
    /// at 0), not the new code path.
    private func legacySnap(_ snap: ClipSnap, _ beat: Double, _ bpb: Int) -> Double {
        let grid: Double?
        switch snap {
        case .off: grid = nil
        case .bar: grid = Double(max(1, bpb))
        case .beat: grid = 1
        case .half: grid = 0.5
        case .quarter: grid = 0.25
        }
        guard let g = grid, g > 0 else { return max(0, beat) }
        return max(0, (beat / g).rounded() * g)
    }

    // MARK: - Snap

    @Test("snap grid sizes follow the meter for bar, are fixed for finer divisions")
    func snapGridBeats() {
        #expect(ClipSnap.off.gridBeats(beatsPerBar: 4) == nil)
        #expect(ClipSnap.bar.gridBeats(beatsPerBar: 4) == 4)
        #expect(ClipSnap.bar.gridBeats(beatsPerBar: 3) == 3)
        #expect(ClipSnap.beat.gridBeats(beatsPerBar: 4) == 1)
        #expect(ClipSnap.half.gridBeats(beatsPerBar: 4) == 0.5)
        #expect(ClipSnap.quarter.gridBeats(beatsPerBar: 4) == 0.25)
    }

    @Test("snap labels are beginner-first / plain fractions")
    func snapLabels() {
        #expect(ClipSnap.off.label == "Off")
        #expect(ClipSnap.bar.label == "Bar")
        #expect(ClipSnap.beat.label == "Beat")
        #expect(ClipSnap.half.label == "1/2")
        #expect(ClipSnap.quarter.label == "1/4")
    }

    @Test("snap rounds to nearest grid line, floors at 0, and off passes through")
    func snapRounding() {
        #expect(ClipSnap.beat.snap(beat: 2.4, beatsPerBar: 4) == 2)
        #expect(ClipSnap.beat.snap(beat: 2.6, beatsPerBar: 4) == 3)
        #expect(ClipSnap.bar.snap(beat: 5, beatsPerBar: 4) == 4)      // nearest bar (bar=4)
        #expect(ClipSnap.bar.snap(beat: 5, beatsPerBar: 3) == 6)      // nearest bar (bar=3)
        #expect(ClipSnap.quarter.snap(beat: 1.1, beatsPerBar: 4) == 1)
        #expect(ClipSnap.off.snap(beat: 2.37, beatsPerBar: 4) == 2.37)
        #expect(ClipSnap.beat.snap(beat: -3, beatsPerBar: 4) == 0)    // floored
        #expect(ClipSnap.off.snap(beat: -3, beatsPerBar: 4) == 0)
    }

    @Test("effective snap locks to Bar in Simple, honors the picker in Pro (sp-c)")
    func effectiveSnapDensityLock() {
        // Pro passes the picked resolution straight through.
        for picked in ClipSnap.allCases {
            #expect(ClipSnap.effective(density: .pro, picked: picked) == picked)
        }
        // Simple locks to Bar regardless of what the picker holds — and the picker
        // value is untouched (this is pure), so flipping back to Pro restores it.
        for picked in ClipSnap.allCases {
            #expect(ClipSnap.effective(density: .simple, picked: picked) == .bar)
        }
    }

    // MARK: - Geometry

    @Test("beat<->x round-trips at the fixed scale and floors at 0")
    func beatXRoundTrip() {
        let g = geometry()
        #expect(g.x(forBeat: 3.5) == 3.5 * g.pixelsPerBeat)
        for beat in [0.0, 1.0, 2.25, 4.0] {
            #expect(abs(g.beat(forX: g.x(forBeat: beat)) - beat) < 1e-9)
        }
        #expect(g.beat(forX: -20) == 0)
    }

    // MARK: - Hit classification

    @Test("classifyZone routes body, trim edges, and no-fade top corners")
    func classifyBasics() {
        let g = geometry()
        let w: CGFloat = 64   // a 4-beat clip at 16 pt/beat
        // Middle of the body.
        #expect(g.classifyZone(localPoint: CGPoint(x: 32, y: 20), clipWidth: w,
                               fadeInBeats: 0, fadeOutBeats: 0) == .body)
        // Lower-left edge strip trims the start (below the fade zone).
        #expect(g.classifyZone(localPoint: CGPoint(x: 3, y: 25), clipWidth: w,
                               fadeInBeats: 0, fadeOutBeats: 0) == .trimStart)
        // Lower-right edge strip trims the end.
        #expect(g.classifyZone(localPoint: CGPoint(x: 62, y: 25), clipWidth: w,
                               fadeInBeats: 0, fadeOutBeats: 0) == .trimEnd)
        // Top corners (no fades yet) grab the fade grips sitting at the corners.
        #expect(g.classifyZone(localPoint: CGPoint(x: 1, y: 2), clipWidth: w,
                               fadeInBeats: 0, fadeOutBeats: 0) == .fadeInHandle)
        #expect(g.classifyZone(localPoint: CGPoint(x: 63, y: 2), clipWidth: w,
                               fadeInBeats: 0, fadeOutBeats: 0) == .fadeOutHandle)
    }

    @Test("classifyZone tracks fade grips as the fades grow inward")
    func classifyFollowsFades() {
        let g = geometry()
        let w: CGFloat = 64
        // Fade-in of 1 beat puts its grip at x = 16; a top press there is the grip.
        #expect(g.classifyZone(localPoint: CGPoint(x: 16, y: 3), clipWidth: w,
                               fadeInBeats: 1, fadeOutBeats: 0) == .fadeInHandle)
        // Fade-out of 1 beat puts its grip at x = 48.
        #expect(g.classifyZone(localPoint: CGPoint(x: 48, y: 3), clipWidth: w,
                               fadeInBeats: 0, fadeOutBeats: 1) == .fadeOutHandle)
        // Away from either grip along the top is the body, not a fade.
        #expect(g.classifyZone(localPoint: CGPoint(x: 32, y: 3), clipWidth: w,
                               fadeInBeats: 1, fadeOutBeats: 1) == .body)
    }

    // MARK: - Move

    @Test("movedStartBeat applies the delta then snaps and floors at 0")
    func movePreview() {
        #expect(ClipEdit.movedStartBeat(originalStart: 4, dragDeltaBeats: 2.4,
                                        snap: .beat, meterMap: meter()) == 6)
        #expect(ClipEdit.movedStartBeat(originalStart: 4, dragDeltaBeats: -10,
                                        snap: .beat, meterMap: meter()) == 0)
        #expect(ClipEdit.movedStartBeat(originalStart: 3, dragDeltaBeats: 0.2,
                                        snap: .off, meterMap: meter()) == 3.2)
    }

    // MARK: - Trim

    @Test("trimStart pins the end, snaps the start, and honors the min length")
    func trimStartPreview() {
        // Clip [4, 8): drag the start to ~5.6 with beat snap -> start 6, length 2.
        let a = ClipEdit.trimStart(originalStart: 4, originalLength: 4, newStartBeatRaw: 5.6,
                                   snap: .beat, meterMap: meter())
        #expect(a.startBeat == 6)
        #expect(a.lengthBeats == 2)
        // Dragging the start past the end clamps to end - min length.
        let b = ClipEdit.trimStart(originalStart: 4, originalLength: 4, newStartBeatRaw: 100,
                                   snap: .off, meterMap: meter())
        #expect(abs(b.startBeat - (8 - ClipEdit.minClipLengthBeats)) < 1e-9)
        #expect(abs(b.lengthBeats - ClipEdit.minClipLengthBeats) < 1e-9)
    }

    @Test("trimEnd pins the start, snaps the end, and honors the min length")
    func trimEndPreview() {
        // Clip [4, 8): drag the end to ~6.4 with beat snap -> length 2 (end 6).
        let a = ClipEdit.trimEnd(originalStart: 4, newEndBeatRaw: 6.4, snap: .beat, meterMap: meter())
        #expect(a.startBeat == 4)
        #expect(a.lengthBeats == 2)
        // Dragging the end before the start clamps to start + min length.
        let b = ClipEdit.trimEnd(originalStart: 4, newEndBeatRaw: 0, snap: .off, meterMap: meter())
        #expect(abs(b.lengthBeats - ClipEdit.minClipLengthBeats) < 1e-9)
    }

    // MARK: - Fades

    @Test("fade previews clamp so the two never overlap")
    func fadePreview() {
        let ppb: CGFloat = 16
        // Fade-in grip dragged to x = 32 -> 2 beats, with no fade-out.
        #expect(ClipEdit.fadeInBeats(forLocalX: 32, length: 4, fadeOutBeats: 0,
                                     pixelsPerBeat: ppb) == 2)
        // With a 3-beat fade-out already, the fade-in caps at length - 3 = 1.
        #expect(ClipEdit.fadeInBeats(forLocalX: 999, length: 4, fadeOutBeats: 3,
                                     pixelsPerBeat: ppb) == 1)
        // Fade-out grip dragged to x = 48 on a 64 pt clip -> 1 beat.
        #expect(ClipEdit.fadeOutBeats(forLocalX: 48, clipWidth: 64, length: 4,
                                      fadeInBeats: 0, pixelsPerBeat: ppb) == 1)
        // Never negative.
        #expect(ClipEdit.fadeOutBeats(forLocalX: 200, clipWidth: 64, length: 4,
                                      fadeInBeats: 0, pixelsPerBeat: ppb) == 0)
    }

    @Test("toggledCurve flips linear<->equalPower")
    func curveToggle() {
        #expect(ClipEdit.toggledCurve(.linear) == .equalPower)
        #expect(ClipEdit.toggledCurve(.equalPower) == .linear)
    }

    // MARK: - Split

    @Test("snappedSplit snaps inside, falls back to the raw beat, else nil")
    func splitPreview() {
        // Clip [4, 8): a click at ~5.6 with beat snap lands on 6 (strictly inside).
        #expect(ClipEdit.snappedSplit(timelineBeatRaw: 5.6, clipStart: 4, clipLength: 4,
                                      snap: .beat, meterMap: meter()) == 6)
        // Bar snap would push 4.3 down to 4 (a boundary) — fall back to the raw beat.
        #expect(ClipEdit.snappedSplit(timelineBeatRaw: 4.3, clipStart: 4, clipLength: 4,
                                      snap: .bar, meterMap: meter()) == 4.3)
        // A click on the exact boundary can't split -> nil.
        #expect(ClipEdit.snappedSplit(timelineBeatRaw: 8, clipStart: 4, clipLength: 4,
                                      snap: .off, meterMap: meter()) == nil)
        #expect(ClipEdit.snappedSplit(timelineBeatRaw: 4, clipStart: 4, clipLength: 4,
                                      snap: .off, meterMap: meter()) == nil)
    }

    // MARK: - Meter-aware snap (m13-h)

    @Test("clip drag/trim/split .bar snap routes through nearestBarline on both sides of a meter change")
    func clipEditBarSnapCrossBoundary() {
        let m = crossMeter()   // 4/4 → 6/8 @ beat 16; barlines …12,16,22,28…
        // MOVE: a raw start just LEFT of 16 (in 4/4) → nearest of {12,16} = 16.
        #expect(ClipEdit.movedStartBeat(originalStart: 0, dragDeltaBeats: 15.4,
                                        snap: .bar, meterMap: m) == 16)
        // MOVE: a raw start just RIGHT of 16 (in 6/8) → nearest of {16,22} = 16.
        #expect(ClipEdit.movedStartBeat(originalStart: 0, dragDeltaBeats: 17.5,
                                        snap: .bar, meterMap: m) == 16)
        // MOVE: deep in 6/8 → snaps to the 6/8 grid (bar at 22, not a 4-beat grid).
        #expect(ClipEdit.movedStartBeat(originalStart: 0, dragDeltaBeats: 20,
                                        snap: .bar, meterMap: m) == 22)
        // TRIM START: end pinned at 26; new start raw 17 (6/8) → 16.
        let ts = ClipEdit.trimStart(originalStart: 16, originalLength: 10,
                                    newStartBeatRaw: 17, snap: .bar, meterMap: m)
        #expect(ts.startBeat == 16)
        #expect(ts.lengthBeats == 10)
        // TRIM END: start pinned at 16; new end raw 21 (6/8) → nearest of {16,22} = 22.
        let te = ClipEdit.trimEnd(originalStart: 16, newEndBeatRaw: 21, snap: .bar, meterMap: m)
        #expect(te.lengthBeats == 6)          // one 6/8 bar
        // SPLIT: clip [16,28); a click at 21 (6/8) snaps to the 6/8 barline 22.
        #expect(ClipEdit.snappedSplit(timelineBeatRaw: 21, clipStart: 16, clipLength: 12,
                                      snap: .bar, meterMap: m) == 22)
    }

    @Test("a finer grid in the 6/8 region snaps on that fixed grid (meter-agnostic)")
    func clipEditFinerGridInChangedRegion() {
        let m = crossMeter()
        // .quarter (0.25) is meter-agnostic: 17.1 → 17.0 regardless of the 6/8 meter.
        #expect(ClipEdit.movedStartBeat(originalStart: 0, dragDeltaBeats: 17.1,
                                        snap: .quarter, meterMap: m) == 17)
        // .beat (1.0): 20.6 → 21 in the 6/8 region (still whole-beat spacing).
        #expect(ClipEdit.movedStartBeat(originalStart: 0, dragDeltaBeats: 20.6,
                                        snap: .beat, meterMap: m) == 21)
    }

    @Test("trivial single-meter map reproduces the legacy base-meter snap EXACTLY")
    func clipEditTrivialMapMatchesLegacy() {
        for bpb in [3, 4, 5, 6, 7] {
            let m = meter(bpb)
            var beat = -3.0
            while beat <= 40 {
                for snap in ClipSnap.allCases {
                    let expected = legacySnap(snap, max(0, beat), bpb)
                    // MOVE (originalStart 0 so the delta IS the raw beat).
                    #expect(ClipEdit.movedStartBeat(originalStart: 0, dragDeltaBeats: beat,
                                                    snap: snap, meterMap: m) == expected,
                            "move bpb=\(bpb) snap=\(snap) beat=\(beat)")
                    // SPLIT snapping (compare the snap it uses on a wide clip so the
                    // strict-inside guard never masks the snapped value).
                    let split = ClipEdit.snappedSplit(timelineBeatRaw: beat,
                                                      clipStart: -100, clipLength: 200,
                                                      snap: snap, meterMap: m)
                    #expect(split == expected, "split bpb=\(bpb) snap=\(snap) beat=\(beat)")
                }
                beat += 0.1
            }
        }
    }

    // MARK: - Gain

    @Test("adjustedGainDb clamps to the clip gain range")
    func gainAdjust() {
        #expect(ClipEdit.adjustedGainDb(0, deltaDb: -6) == -6)
        #expect(ClipEdit.adjustedGainDb(-70, deltaDb: -20) == Clip.gainDbRange.lowerBound)
        #expect(ClipEdit.adjustedGainDb(20, deltaDb: 20) == Clip.gainDbRange.upperBound)
    }

    @Test("gainDbString formats with sign, one decimal, and folds -0")
    func gainString() {
        #expect(ClipEdit.gainDbString(0) == "0.0 dB")
        #expect(ClipEdit.gainDbString(-6) == "-6.0 dB")
        #expect(ClipEdit.gainDbString(3) == "+3.0 dB")
        #expect(ClipEdit.gainDbString(-0.04) == "0.0 dB")   // rounds to 0, no -0.0
        #expect(ClipEdit.gainDbString(1.25) == "+1.3 dB")
    }
}
