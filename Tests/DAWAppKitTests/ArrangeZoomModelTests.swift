import CoreGraphics
import Foundation
import Testing
@testable import DAWAppKit

/// Headless coverage for `ArrangeZoom` (m17-b): the arrange-timeline zoom math —
/// the pixels-per-beat clamp + multiplicative ladder, the anchor-preserving
/// scroll-offset recompute (the "view never visually jumps" rule), the pinch
/// state's fixed-anchor invariance, the grid/label density rules the ruler
/// Canvas reads, and the stepped S/M/L row-height ladder. Pure math — no
/// SwiftUI, no store (`@MainActor` only for the `PanelLayoutStore` static
/// range/default cross-checks).
@MainActor
@Suite("ArrangeZoom — arrange timeline zoom math (m17-b)")
struct ArrangeZoomModelTests {

    // MARK: - Clamp + ladder

    @Test("clamp tames any input into 4…200 and preserves in-range values")
    func clampBounds() {
        #expect(ArrangeZoom.clamp(0) == 4)
        #expect(ArrangeZoom.clamp(-50) == 4)
        #expect(ArrangeZoom.clamp(4) == 4)
        #expect(ArrangeZoom.clamp(16) == 16)
        #expect(ArrangeZoom.clamp(200) == 200)
        #expect(ArrangeZoom.clamp(100_000) == 200)
    }

    @Test("the default scale is the historical 16 pt/beat, inside the range")
    func defaultScale() {
        #expect(ArrangeZoom.defaultPixelsPerBeat == 16)
        #expect(ArrangeZoom.pixelsPerBeatRange.contains(ArrangeZoom.defaultPixelsPerBeat))
    }

    @Test("one step in multiplies by the factor; one step out divides")
    func ladderSteps() {
        #expect(ArrangeZoom.zoomedIn(16) == 16 * ArrangeZoom.stepFactor)
        #expect(ArrangeZoom.zoomedOut(16) == 16 / ArrangeZoom.stepFactor)
    }

    @Test("in-then-out returns to the start anywhere clamping doesn't bite")
    func ladderRoundTrip() {
        for ppb: CGFloat in [6, 16, 40, 120] {
            let there = ArrangeZoom.zoomedIn(ppb)
            let back = ArrangeZoom.zoomedOut(there)
            #expect(abs(back - ppb) < 0.0001)
        }
    }

    @Test("the ladder reaches both bounds in finitely many steps and stays put")
    func ladderReachesBounds() {
        var ppb = ArrangeZoom.defaultPixelsPerBeat
        for _ in 0..<64 { ppb = ArrangeZoom.zoomedIn(ppb) }
        #expect(ppb == ArrangeZoom.pixelsPerBeatRange.upperBound)
        #expect(ArrangeZoom.zoomedIn(ppb) == ppb)   // pinned at max
        for _ in 0..<64 { ppb = ArrangeZoom.zoomedOut(ppb) }
        #expect(ppb == ArrangeZoom.pixelsPerBeatRange.lowerBound)
        #expect(ArrangeZoom.zoomedOut(ppb) == ppb)  // pinned at min
    }

    // MARK: - Anchor-preserving offset (the no-jump rule)

    /// The property that IS the feature: after
    /// `offsetPreservingAnchor(old, new, offset, anchorX)`, the beat that sat at
    /// screen x = anchorX still sits at screen x = anchorX under the new scale.
    @Test("the anchor beat's screen x is invariant across a zoom")
    func anchorScreenXInvariant() {
        // Vectors chosen so the compensating offset stays ≥ 0 — at the floor the
        // origin deliberately pins instead (see `offsetFloorsAtZero`).
        let cases: [(old: CGFloat, new: CGFloat, offset: CGFloat, anchorX: CGFloat)] = [
            (16, 32, 100, 240),      // zoom in, playhead mid-view
            (16, 8, 400, 240),       // zoom out, deep enough to keep the anchor
            (16, 20, 0, 0),          // at origin, leading-edge anchor
            (4, 200, 371.5, 613.25), // extreme sweep, fractional state
            (200, 4, 5000, 12),      // extreme reverse from deep scroll
            (16, 24, 800, 450.75),   // fractional anchor
        ]
        for c in cases {
            let anchorBeat = (c.offset + c.anchorX) / c.old
            let newOffset = ArrangeZoom.offsetPreservingAnchor(
                oldPPB: c.old, newPPB: c.new, oldOffset: c.offset, anchorScreenX: c.anchorX)
            let newScreenX = anchorBeat * c.new - newOffset
            #expect(abs(newScreenX - c.anchorX) < 1e-9,
                    "anchor drifted: \(c) → screenX \(newScreenX)")
        }
    }

    @Test("the offset floors at 0 — the timeline origin never scrolls past the left edge")
    func offsetFloorsAtZero() {
        // Zooming OUT near the origin would need a negative offset to hold the
        // anchor — the floor wins (the origin pins instead; nothing to show left
        // of beat 0).
        let newOffset = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: 16, newPPB: 4, oldOffset: 20, anchorScreenX: 100)
        #expect(newOffset == 0)
    }

    @Test("a degenerate old scale is tamed, not divided by")
    func degenerateOldScale() {
        let offset = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: 0, newPPB: 16, oldOffset: 50, anchorScreenX: 10)
        #expect(offset == 50)   // falls back to the old offset, floored
    }

    // MARK: - Keyboard/toolbar anchor pick (playhead if visible, else center)

    @Test("the playhead anchors the zoom when it is inside the viewport")
    func playheadAnchorWhenVisible() {
        // Playhead at content x 500, offset 400, viewport 800 → screen x 100.
        let anchor = ArrangeZoom.anchorScreenX(
            playheadContentX: 500, offset: 400, viewportWidth: 800)
        #expect(anchor == 100)
        // Edges are inclusive.
        #expect(ArrangeZoom.anchorScreenX(playheadContentX: 400, offset: 400, viewportWidth: 800) == 0)
        #expect(ArrangeZoom.anchorScreenX(playheadContentX: 1200, offset: 400, viewportWidth: 800) == 800)
    }

    @Test("an off-screen playhead falls back to the viewport center")
    func centerFallback() {
        #expect(ArrangeZoom.anchorScreenX(playheadContentX: 30, offset: 400, viewportWidth: 800) == 400)
        #expect(ArrangeZoom.anchorScreenX(playheadContentX: 5000, offset: 400, viewportWidth: 800) == 400)
        // A degenerate viewport (headless, never laid out) still yields a sane 0.
        #expect(ArrangeZoom.anchorScreenX(playheadContentX: 5000, offset: 0, viewportWidth: 0) == 0)
    }

    // MARK: - Pinch state (pointer-anchored, fixed through the gesture)

    @Test("a pinch holds the beat under the pointer at its start screen x")
    func pinchAnchorInvariant() {
        let pinch = ArrangeZoom.PinchState(
            startPPB: 16, startOffset: 320, anchorContentX: 560)
        // anchorBeat = 35, anchorScreenX = 240.
        for magnification: CGFloat in [0.5, 0.8, 1.0, 1.6, 3.0] {
            let (ppb, offset) = pinch.zoomed(magnification: magnification)
            let screenX = pinch.anchorBeat * ppb - offset
            #expect(abs(screenX - pinch.anchorScreenX) < 1e-9)
            #expect(ArrangeZoom.pixelsPerBeatRange.contains(ppb))
        }
    }

    @Test("pinch magnification is cumulative off the gesture-START scale")
    func pinchCumulative() {
        let pinch = ArrangeZoom.PinchState(startPPB: 16, startOffset: 0, anchorContentX: 0)
        #expect(pinch.zoomed(magnification: 2).ppb == 32)
        // A second tick at 2.5× measures from 16, not from 32.
        #expect(pinch.zoomed(magnification: 2.5).ppb == 40)
    }

    @Test("pinch clamps at the range bounds without breaking the anchor floor")
    func pinchClamps() {
        let pinch = ArrangeZoom.PinchState(startPPB: 16, startOffset: 0, anchorContentX: 100)
        #expect(pinch.zoomed(magnification: 100).ppb == 200)
        #expect(pinch.zoomed(magnification: 0.001).ppb == 4)
        #expect(pinch.zoomed(magnification: 0.001).offset >= 0)
    }

    @Test("pinch equivalence: a pinch tick equals setZoom with the same anchor")
    func pinchMatchesSetZoomMath() {
        // The pinch path and the keyboard path must be the SAME math: a pinch to
        // magnification m from (ppb₀, offset₀) anchored at content x equals
        // offsetPreservingAnchor(ppb₀ → ppb₀·m) anchored at (x − offset₀).
        let startPPB: CGFloat = 16, startOffset: CGFloat = 320, contentX: CGFloat = 560
        let pinch = ArrangeZoom.PinchState(
            startPPB: startPPB, startOffset: startOffset, anchorContentX: contentX)
        let (ppb, offset) = pinch.zoomed(magnification: 1.5)
        let expected = ArrangeZoom.offsetPreservingAnchor(
            oldPPB: startPPB, newPPB: ppb, oldOffset: startOffset,
            anchorScreenX: contentX - startOffset)
        #expect(abs(offset - expected) < 1e-9)
    }

    // MARK: - Grid / label density

    @Test("beat lines show at the default scale and drop below the legibility floor")
    func beatLineDensity() {
        #expect(ArrangeZoom.showsBeatLines(pixelsPerBeat: 16))
        #expect(ArrangeZoom.showsBeatLines(pixelsPerBeat: ArrangeZoom.minBeatLineSpacing))
        #expect(!ArrangeZoom.showsBeatLines(pixelsPerBeat: ArrangeZoom.minBeatLineSpacing - 0.01))
        #expect(!ArrangeZoom.showsBeatLines(pixelsPerBeat: 4))
    }

    @Test("bar labels keep every bar at default zoom and thin by powers of two zoomed out")
    func barLabelStride() {
        // 4/4 at 16 ppb: bar = 64 pt ≥ 44 → every bar.
        #expect(ArrangeZoom.barLabelStride(pixelsPerBeat: 16, beatsPerBar: 4) == 1)
        // 4/4 at 8 ppb: bar = 32 pt → every 2nd bar.
        #expect(ArrangeZoom.barLabelStride(pixelsPerBeat: 8, beatsPerBar: 4) == 2)
        // 4/4 at 4 ppb: bar = 16 pt → every 4th bar (stride 2 = 32 pt still short).
        #expect(ArrangeZoom.barLabelStride(pixelsPerBeat: 4, beatsPerBar: 4) == 4)
        // 3/4 at 4 ppb: bar = 12 pt → every 4th bar (48 pt clears 44).
        #expect(ArrangeZoom.barLabelStride(pixelsPerBeat: 4, beatsPerBar: 3) == 4)
        // Degenerate inputs stay sane (0 beats/bar is tamed to 1 → 4 pt bars).
        #expect(ArrangeZoom.barLabelStride(pixelsPerBeat: 0, beatsPerBar: 4) == 1)
        #expect(ArrangeZoom.barLabelStride(pixelsPerBeat: 4, beatsPerBar: 0) == 16)
    }

    @Test("every stride is a power of two — surviving numbers land on round bars")
    func stridesArePowersOfTwo() {
        for ppb in stride(from: 4.0, through: 200.0, by: 1.0) {
            for beats in [1, 3, 4, 7] {
                let s = ArrangeZoom.barLabelStride(pixelsPerBeat: CGFloat(ppb), beatsPerBar: beats)
                #expect(s > 0 && (s & (s - 1)) == 0, "stride \(s) at \(ppb)ppb/\(beats)bpb")
            }
        }
    }

    // MARK: - Row-height ladder (S / M / L)

    @Test("the ladder's heights are ordered, in-range, and Medium is today's default")
    func rowStepHeights() {
        let s = ArrangeZoom.RowStep.small.rowHeight
        let m = ArrangeZoom.RowStep.medium.rowHeight
        let l = ArrangeZoom.RowStep.large.rowHeight
        #expect(s < m && m < l)
        #expect(m == PanelLayoutStore.defaultRowHeight)
        for h in [s, m, l] {
            #expect(PanelLayoutStore.rowHeightRange.contains(h))
        }
    }

    @Test("classification round-trips: each step's height classifies as itself")
    func rowStepRoundTrip() {
        for step in ArrangeZoom.RowStep.allCases {
            #expect(ArrangeZoom.rowStep(closestTo: step.rowHeight) == step)
        }
    }

    @Test("an off-ladder height (the continuous splitter) classifies to the nearest step")
    func rowStepNearest() {
        #expect(ArrangeZoom.rowStep(closestTo: 24) == .small)
        #expect(ArrangeZoom.rowStep(closestTo: 27) == .small)     // 3 vs 7
        #expect(ArrangeZoom.rowStep(closestTo: 31) == .medium)    // 7 vs 3
        #expect(ArrangeZoom.rowStep(closestTo: 40) == .medium)    // 6 vs 10
        #expect(ArrangeZoom.rowStep(closestTo: 45) == .large)     // 11 vs 5
        #expect(ArrangeZoom.rowStep(closestTo: 64) == .large)
    }

    // MARK: - Readout

    @Test("the percent readout reads 100% at default, 25% at the floor, 1250% at the ceiling")
    func percentReadout() {
        #expect(ArrangeZoom.percentLabel(pixelsPerBeat: 16) == "100%")
        #expect(ArrangeZoom.percentLabel(pixelsPerBeat: 4) == "25%")
        #expect(ArrangeZoom.percentLabel(pixelsPerBeat: 200) == "1250%")
        #expect(ArrangeZoom.percentLabel(pixelsPerBeat: 20) == "125%")
    }
}
