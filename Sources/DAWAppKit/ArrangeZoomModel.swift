import CoreGraphics
import Foundation

/// Headless zoom math for the Arrange timeline (m17-b): the horizontal
/// pixels-per-beat clamp + step ladder, the anchor-preserving scroll-offset
/// recompute (the "view never visually jumps" rule), the pinch-gesture state,
/// the grid/label density rules the ruler Canvas reads, and the stepped S/M/L
/// track-row-height ladder. Pure functions + tiny value types so every rule is
/// unit-testable without SwiftUI (the `ClipEdit`/`LoopRulerModel` precedent).
///
/// The LIVE zoom value itself is persisted app-side as a sticky PREFERENCE in
/// `PanelLayoutStore.arrangePPB` (the `panelLayout.rowHeight` slot's sibling —
/// never project data, never undoable, never in the wire snapshot); this type
/// owns only the math.
public enum ArrangeZoom {

    // MARK: - Horizontal scale (pixels per beat)

    /// The historical fixed arrange scale (docs/DESIGN-LANGUAGE.md "Arrange
    /// timeline": 16 pt/beat) — the default and the ⌘0 reset target.
    public static let defaultPixelsPerBeat: CGFloat = 16
    /// Clamp bounds: 4 pt/beat surveys a whole song (a 4/4 bar = 16 pt), 200
    /// pt/beat is sample-fine clip-edit territory (a beat wider than most clips).
    public static let pixelsPerBeatRange: ClosedRange<CGFloat> = 4...200
    /// One ⌘+/⌘− (or toolbar ±) step multiplies/divides by this — multiplicative
    /// so each press FEELS the same at every scale (a linear step would crawl
    /// when zoomed out and leap when zoomed in).
    public static let stepFactor: CGFloat = 1.25

    /// Tames any requested scale into the legal range.
    public static func clamp(_ pixelsPerBeat: CGFloat) -> CGFloat {
        pixelsPerBeat.clamped(to: pixelsPerBeatRange)
    }

    /// One ladder step in (⌘+ / toolbar "+").
    public static func zoomedIn(_ pixelsPerBeat: CGFloat) -> CGFloat {
        clamp(pixelsPerBeat * stepFactor)
    }

    /// One ladder step out (⌘− / toolbar "−").
    public static func zoomedOut(_ pixelsPerBeat: CGFloat) -> CGFloat {
        clamp(pixelsPerBeat / stepFactor)
    }

    // MARK: - Anchor-preserving offset (the no-jump rule)

    /// The new horizontal scroll offset that keeps the beat under `anchorScreenX`
    /// (viewport-relative x) at that same screen x after the scale changes:
    /// the anchor's beat is `(oldOffset + anchorScreenX) / oldPPB`, and its new
    /// content x minus the same screen x is the offset that pins it. Floored at 0
    /// (the timeline origin can never scroll past the left edge); the scroll view
    /// clamps the right edge against its own content width.
    public static func offsetPreservingAnchor(oldPPB: CGFloat, newPPB: CGFloat,
                                              oldOffset: CGFloat,
                                              anchorScreenX: CGFloat) -> CGFloat {
        guard oldPPB > 0 else { return max(0, oldOffset) }
        let anchorBeat = (oldOffset + anchorScreenX) / oldPPB
        return max(0, anchorBeat * newPPB - anchorScreenX)
    }

    /// The screen-x a keyboard/toolbar zoom anchors on: the PLAYHEAD when it is
    /// inside the viewport (the eye is on it), else the viewport center.
    /// `playheadContentX` is `positionBeats · oldPPB`.
    public static func anchorScreenX(playheadContentX: CGFloat, offset: CGFloat,
                                     viewportWidth: CGFloat) -> CGFloat {
        let screenX = playheadContentX - offset
        if viewportWidth > 0, screenX >= 0, screenX <= viewportWidth {
            return screenX
        }
        return max(0, viewportWidth / 2)
    }

    // MARK: - Pinch (MagnifyGesture) — anchored at the pointer

    /// Captured ONCE on the first pinch tick so per-tick math measures off a
    /// FIXED anchor (the marker-drag "don't feed your own motion back" rule):
    /// the content point under the pointer at gesture start defines the anchor
    /// BEAT and its SCREEN x, both of which stay invariant through the pinch.
    public struct PinchState: Equatable, Sendable {
        public var startPPB: CGFloat
        public var anchorBeat: CGFloat
        public var anchorScreenX: CGFloat

        /// - Parameters:
        ///   - startPPB: the scale when the pinch began.
        ///   - startOffset: the horizontal scroll offset when the pinch began.
        ///   - anchorContentX: the pointer's x in CONTENT space at gesture start.
        public init(startPPB: CGFloat, startOffset: CGFloat, anchorContentX: CGFloat) {
            self.startPPB = max(startPPB, 0.001)
            self.anchorBeat = anchorContentX / self.startPPB
            self.anchorScreenX = anchorContentX - startOffset
        }

        /// The scale + offset for a live magnification tick: scale multiplies the
        /// GESTURE-START scale (not the last tick's — magnification is cumulative),
        /// and the offset re-pins the anchor beat to its start screen x.
        public func zoomed(magnification: CGFloat) -> (ppb: CGFloat, offset: CGFloat) {
            let ppb = ArrangeZoom.clamp(startPPB * max(magnification, 0.001))
            let offset = max(0, anchorBeat * ppb - anchorScreenX)
            return (ppb, offset)
        }
    }

    // MARK: - Grid / label density (the ruler adapts, never forks)

    /// Below this spacing, per-beat hairlines smear into noise — the grid drops
    /// them and keeps only bar lines (they reappear as you zoom back in).
    public static let minBeatLineSpacing: CGFloat = 8
    /// A bar NUMBER needs at least this much room before the next one; zoomed
    /// out, labels thin to every 2nd/4th/8th… bar so they never collide.
    public static let minBarLabelSpacing: CGFloat = 44

    /// Whether per-beat (non-bar) grid lines draw at this scale.
    public static func showsBeatLines(pixelsPerBeat: CGFloat) -> Bool {
        pixelsPerBeat >= minBeatLineSpacing
    }

    /// Label every Nth bar: the smallest power of two whose bar spacing clears
    /// `minBarLabelSpacing` (powers of two so the surviving numbers land on
    /// musically round bars: 1, 3, 5… → 1, 5, 9… → 1, 9, 17…).
    public static func barLabelStride(pixelsPerBeat: CGFloat, beatsPerBar: Int) -> Int {
        let barWidth = pixelsPerBeat * CGFloat(max(1, beatsPerBar))
        guard barWidth > 0 else { return 1 }
        var stride = 1
        while CGFloat(stride) * barWidth < minBarLabelSpacing && stride < 1024 {
            stride *= 2
        }
        return stride
    }

    // MARK: - Vertical: stepped track-row heights (S / M / L)

    /// The row-height ladder. Values live inside `PanelLayoutStore.rowHeightRange`
    /// (24…64): Small = the dense floor, Medium = the historical default (34),
    /// Large = a comfortable waveform-reading row. The height itself is stored in
    /// the SAME `panelLayout.rowHeight` slot the m10-d splitter drags, so the
    /// sidebar rows and the lanes stay pixel-aligned by construction (both read
    /// one store value) and the continuous drag keeps working between steps.
    public enum RowStep: String, CaseIterable, Sendable {
        case small, medium, large

        /// The `panelLayout.rowHeight` this step sets.
        public var rowHeight: CGFloat {
            switch self {
            case .small: return 24
            case .medium: return 34
            case .large: return 50
            }
        }

        /// Toolbar chip label.
        public var label: String {
            switch self {
            case .small: return "S"
            case .medium: return "M"
            case .large: return "L"
            }
        }
    }

    /// Classifies an arbitrary row height (the splitter is continuous) onto the
    /// NEAREST step, so the toolbar chip always shows an honest position and
    /// `debug.arrangeZoom` echoes a stable value. Ties round UP (26→small,
    /// 29→medium: midpoint 29 belongs to the coarser read below it… see tests).
    public static func rowStep(closestTo height: CGFloat) -> RowStep {
        RowStep.allCases.min {
            abs($0.rowHeight - height) < abs($1.rowHeight - height)
        } ?? .medium
    }

    // MARK: - Readout

    /// The toolbar's SF Mono zoom readout: percent of the default scale
    /// ("100%" at 16 pt/beat, "25%" at the floor, "1250%" at the ceiling).
    public static func percentLabel(pixelsPerBeat: CGFloat) -> String {
        let percent = (pixelsPerBeat / defaultPixelsPerBeat) * 100
        return "\(Int(percent.rounded()))%"
    }
}
