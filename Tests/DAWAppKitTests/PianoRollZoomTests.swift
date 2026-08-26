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

    // MARK: - Anchor-preserving zoom (m25-b-3)

    @Test("a visible playhead is the anchor; its SCREEN x is what the zoom holds")
    func anchorIsThePlayheadWhenVisible() {
        // Playhead at content 500, scroller at 200 → 300 pt into a 900 pt viewport.
        #expect(PianoRollZoom.anchorScreenX(playheadContentX: 500, offset: 200,
                                            viewportWidth: 900) == 300)
        // Exactly on either edge still counts as in frame (the arrange's rule).
        #expect(PianoRollZoom.anchorScreenX(playheadContentX: 200, offset: 200,
                                            viewportWidth: 900) == 0)
        #expect(PianoRollZoom.anchorScreenX(playheadContentX: 1100, offset: 200,
                                            viewportWidth: 900) == 900)
    }

    @Test("OFF-CLIP (nil) falls back to the viewport centre — the m23-c1 rule")
    func offClipAnchorsOnTheCentre() {
        // ⚠️ THE POINT OF THIS ASSERTION IS THE COMPARISON, NOT THE NUMBER. It is
        // pinned against `ArrangeZoom`'s OWN no-playhead answer rather than a
        // re-typed `viewportWidth / 2`, so the day the shared centre rule changes
        // this test tracks it instead of freezing a second definition into the
        // roll. `PianoRollZoom.anchorScreenX` delegates by handing the shared rule
        // a playhead that cannot be in frame; if someone "tidies" that into a local
        // literal, this stays green — which is why the NEXT test exists.
        let shared = ArrangeZoom.anchorScreenX(playheadContentX: 5000, offset: 0,
                                               viewportWidth: 900)
        #expect(PianoRollZoom.anchorScreenX(playheadContentX: nil, offset: 0,
                                            viewportWidth: 900) == shared)
        #expect(PianoRollZoom.anchorScreenX(playheadContentX: nil, offset: 400,
                                            viewportWidth: 900) == shared)
        // A playhead that exists but has been scrolled out of frame takes the same
        // fallback — "not on screen" and "not in this clip" are one case here.
        #expect(PianoRollZoom.anchorScreenX(playheadContentX: 50, offset: 400,
                                            viewportWidth: 900) == shared)
        // Degenerate viewport: no anchor to invent, and never a negative one.
        #expect(PianoRollZoom.anchorScreenX(playheadContentX: nil, offset: 0,
                                            viewportWidth: 0) == 0)
    }

    @Test("the beat under the anchor survives the zoom — at roll scales, both directions")
    func anchoredZoomHoldsTheBeat() {
        // ⭐ THE RULE THE WHOLE ITEM EXISTS FOR, exercised through the shared home
        // the roll now calls (`ArrangeZoom.offsetPreservingAnchor`) at the ROLL's
        // own default scale and ladder — a proof that the arrange's arithmetic is
        // surface-independent, which is the premise of reusing it.
        let viewport: CGFloat = 900
        for anchorX in [CGFloat(0), 120, viewport / 2, 880] {
            for oldOffset in [CGFloat(0), 37, 1024] {
                let old = PianoRollZoom.defaultPixelsPerBeat        // 32
                let beatUnderAnchor = (oldOffset + anchorX) / old
                for new in [PianoRollZoom.zoomedIn(old), PianoRollZoom.zoomedOut(old),
                            CGFloat(200), CGFloat(4)] {
                    let offset = ArrangeZoom.offsetPreservingAnchor(
                        oldPPB: old, newPPB: new,
                        oldOffset: oldOffset, anchorScreenX: anchorX)
                    // Where does that beat now sit on screen? Only the floor at 0
                    // may move it, and only when the anchor would need a negative
                    // offset (the timeline origin cannot scroll past the left edge).
                    let screenX = beatUnderAnchor * new - offset
                    let floored = beatUnderAnchor * new - anchorX < 0
                    if floored {
                        #expect(offset == 0)
                        #expect(screenX <= anchorX + 1e-9)
                    } else {
                        #expect(abs(screenX - anchorX) < 1e-9,
                                "ppb \(old)→\(new), offset \(oldOffset), anchor \(anchorX)")
                    }
                }
            }
        }
    }

    @Test("a degenerate OLD scale cannot produce a NaN offset (divide-by-zero guard)")
    func degenerateOldScaleIsSafe() {
        let offset = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: 0, newPPB: 32, oldOffset: 400, anchorScreenX: 100)
        #expect(offset == 400)
        #expect(!offset.isNaN)
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

    // MARK: - Vertical scale: pitch-row height (m25-b-4)

    @Test("the row-height range is 10...56 with the historical 14 as the default")
    func rowHeightRange() {
        #expect(PianoRollZoom.defaultRowHeight == 14)
        #expect(PianoRollZoom.rowHeightRange == 10...56)
        #expect(PianoRollZoom.clampRowHeight(1) == 10)
        #expect(PianoRollZoom.clampRowHeight(1000) == 56)
        #expect(PianoRollZoom.clampRowHeight(14) == 14)

        // THE FLOOR IS THE GUTTER'S, AND IT IS MEASURED: the m25-i key labels are
        // 8 pt SF Mono, drawn centred in their row, and that face lays out in a
        // 10.0 pt line box (NSLayoutManager.defaultLineHeight and
        // NSAttributedString.size().height agree, both weights). Adjacent names
        // first TOUCH at 10, so the floor sits exactly at the fit bound and every
        // reachable row height names every key — which is why the gutter needed no
        // density ladder. Re-derived here so lowering the floor breaks this test
        // rather than the gutter.
        #expect(PianoRollZoom.rowHeightRange.lowerBound >= 10)

        // The floor is safe for the GRID too, on the roll's own shipped numbers: a
        // note's hit rect is the full row (`noteRect`), and 10 pt clears the roll's
        // smallest grab dimension...
        #expect(PianoRollZoom.rowHeightRange.lowerBound > PianoRollModel.resizeHandleWidth)
        // ...and the pill (inset dy 1.5 at its one draw site, corner radius 3)
        // still draws taller than 2× its radius, so it reads as a rounded BAR.
        #expect(PianoRollZoom.rowHeightRange.lowerBound - 3 >= 6)

        // The ceiling is a JUDGEMENT about visible pitch span, recorded as 4×.
        #expect(PianoRollZoom.rowHeightRange.upperBound == PianoRollZoom.defaultRowHeight * 4)
    }

    @Test("the row ladder is the SAME multiplicative step as the horizontal one")
    func rowLadder() {
        #expect(PianoRollZoom.tallerRow(14) == 14 * PianoRollZoom.stepFactor)
        #expect(PianoRollZoom.shorterRow(14) == 14 / PianoRollZoom.stepFactor)
        // Both ends clamp rather than running away.
        #expect(PianoRollZoom.tallerRow(56) == 56)
        #expect(PianoRollZoom.shorterRow(10) == 10)
        // The ladder reaches both bounds from the default in finite presses.
        var up = PianoRollZoom.defaultRowHeight
        for _ in 0..<20 { up = PianoRollZoom.tallerRow(up) }
        #expect(up == 56)
        var down = PianoRollZoom.defaultRowHeight
        for _ in 0..<20 { down = PianoRollZoom.shorterRow(down) }
        #expect(down == 10)
        #expect(PianoRollZoom.rowPercentLabel(rowHeight: 14) == "100%")
        #expect(PianoRollZoom.rowPercentLabel(rowHeight: 28) == "200%")
    }

    @Test("the vertical anchor is the viewport CENTRE, borrowed not re-typed")
    func rowAnchorIsTheCentre() {
        // Pinned against ArrangeZoom's OWN fallback rather than a re-typed
        // `height / 2`, so the delegation is observable (the m25-b-3 law: the
        // centre keeps ONE definition).
        for h in [0 as CGFloat, 1, 400, 1793] {
            #expect(PianoRollZoom.rowAnchorScreenY(viewportHeight: h)
                    == ArrangeZoom.anchorScreenX(playheadContentX: .infinity,
                                                 offset: 0, viewportWidth: h))
        }
        #expect(PianoRollZoom.rowAnchorScreenY(viewportHeight: 400) == 200)
        #expect(PianoRollZoom.rowAnchorScreenY(viewportHeight: 0) == 0)
    }

    /// ⭐ **THE ITEM'S HEADLINE RULE, WITH ITS OWN NEGATIVE CONTROL.** A vertical
    /// zoom that rescales rows without re-pinning an anchor pitch throws the notes
    /// the user is looking at off screen — so this leg asserts the anchored offset
    /// holds the centre pitch AND that the un-anchored behaviour (keep the old
    /// offset) demonstrably does NOT. Without the control, a `rowZoomOffset` that
    /// simply returned `oldOffset` would pass the first half at any zoom where the
    /// centre happened not to move.
    @Test("a row-height zoom holds the pitch at the viewport centre")
    func rowZoomHoldsTheCentrePitch() {
        let viewport: CGFloat = 400
        let old: CGFloat = 14
        // Scrolled well into the pitch stack, so a drift is unmissable.
        let oldOffset: CGFloat = 600
        // The pitch under the centre before the zoom, in the model's own affine.
        let centrePitch = (oldOffset + viewport / 2) / old

        for new in [28 as CGFloat, 10, 56, 17.5] {
            let offset = PianoRollZoom.rowZoomOffset(
                oldRowHeight: old, newRowHeight: new,
                oldOffset: oldOffset, viewportHeight: viewport)
            let after = (offset + viewport / 2) / new
            #expect(abs(after - centrePitch) < 1e-9,
                    "row \(old) → \(new): centre pitch drifted \(centrePitch) → \(after)")

            // NEGATIVE CONTROL — the un-anchored behaviour this item exists to
            // prevent: keep the old offset and the centre pitch moves, by more
            // than a row, in every direction the zoom can go.
            let unanchored = (oldOffset + viewport / 2) / new
            #expect(abs(unanchored - centrePitch) > 1,
                    "the control failed to drift at row \(old) → \(new)")
        }
    }

    @Test("the vertical offset is floored at 0 AND clamped to the new content height")
    func rowZoomOffsetIsClampedBothEnds() {
        let viewport: CGFloat = 400
        // At the top of the stack a zoom can never produce a negative offset.
        #expect(PianoRollZoom.rowZoomOffset(oldRowHeight: 14, newRowHeight: 10,
                                            oldOffset: 0, viewportHeight: viewport) == 0)

        // ⚠️ THE CLAMP THE HORIZONTAL RULE DOES NOT NEED. Parked at the very bottom
        // and zooming OUT, the anchored offset must not exceed the NEW content
        // height minus the viewport — `verticalTargetY` sizes a marker inside the
        // gutter, and a target past its end lands somewhere else entirely.
        let old: CGFloat = 56
        let bottom = CGFloat(PianoRollModel.pitchCount) * old - viewport
        let new: CGFloat = 10
        let offset = PianoRollZoom.rowZoomOffset(oldRowHeight: old, newRowHeight: new,
                                                 oldOffset: bottom, viewportHeight: viewport)
        let maxOffset = CGFloat(PianoRollModel.pitchCount) * new - viewport
        #expect(offset <= maxOffset)
        #expect(offset >= 0)
        // The control: the RAW anchored formula does overshoot here, so the clamp
        // is load-bearing rather than decorative.
        let raw = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: old, newPPB: new, oldOffset: bottom,
            anchorScreenX: PianoRollZoom.rowAnchorScreenY(viewportHeight: viewport))
        #expect(raw > maxOffset)
    }

    @Test("a viewport shorter than the content still yields a legal offset")
    func rowZoomOffsetWithATinyViewport() {
        // A zero viewport is the not-yet-laid-out case; the view guards it, but the
        // math must not produce a negative or a NaN if it ever arrives.
        let offset = PianoRollZoom.rowZoomOffset(oldRowHeight: 14, newRowHeight: 28,
                                                 oldOffset: 0, viewportHeight: 0)
        #expect(offset >= 0)
        #expect(offset.isFinite)
        // A degenerate OLD scale cannot divide by zero (the shared rule's guard).
        let guarded = PianoRollZoom.rowZoomOffset(oldRowHeight: 0, newRowHeight: 28,
                                                  oldOffset: 120, viewportHeight: 400)
        #expect(guarded.isFinite)
        #expect(guarded >= 0)
    }
}
