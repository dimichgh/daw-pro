import CoreGraphics
import Foundation

// Arrange RUBBER-BAND (marquee) selection geometry (m23-g3) — the ONE home for
// "a band rect over the lanes → the clip ids it touches". Headless (no SwiftUI,
// no AppKit) so every branch is unit-testable, in the `ArrangeDropSnap` /
// `ArrangeGroupDrag` / `ArrangeSelection` / `MixerStripLayout` / `KnobGeometry`
// / `PianoRollPlayhead` tradition. The view owns the visual and the gesture; it
// owns no geometry math.
//
// THE HAZARD THIS TYPE IS SHAPED AROUND — **the lane ladder is NON-UNIFORM.**
// `TimelineLanesView.laneTop(index)` accumulates
// `rowHeight + extraHeight(track) + laneSpacing`, where `extraHeight` is the
// track's takes section plus (when expanded) its 64 pt automation row. So
// `floor(y / rowHeight)` — or ANY uniform pitch — is wrong the moment one track
// above the band is expanded, and RIGHT for every default project, which is
// exactly why a careless fixture cannot see the bug. This type therefore takes
// the RESOLVED lane bands as INPUT (`ArrangeMarqueeLane`) and has no notion of
// a row pitch at all: there is nothing here that COULD re-derive the ladder, so
// the view's `laneTop` stays the only producer of it. `ArrangeMarqueeTests`
// pins the discriminator with a permanent validity leg that runs the rejected
// uniform mapping and asserts the two id sets DIFFER.
//
// TOUCH, NOT CONTAINMENT: a clip is selected when the band OVERLAPS it, which
// is what every DAW's rubber band does — requiring full containment would make
// a band unable to grab a clip wider than the viewport.
//
// STRICT overlap, so a DEGENERATE band selects nothing. A press that never
// crossed the drag slop, or a drag straight down (zero width), produces an
// empty rect; `CGRect.intersects` is likewise false for empty rects, so this
// matches the platform's own answer rather than inventing a second one. The
// consequence that matters: a marquee gesture that did not actually sweep any
// AREA cannot silently replace the user's selection with a lucky hit.

/// One clip's marquee-relevant shape: its identity and its beat span. The
/// minimal input — a marquee decides membership, never geometry of the clip.
public struct ArrangeMarqueeClip: Equatable, Sendable {
    public var id: UUID
    public var startBeat: Double
    public var lengthBeats: Double

    public var endBeat: Double { startBeat + lengthBeats }

    public init(id: UUID, startBeat: Double, lengthBeats: Double) {
        self.id = id
        self.startBeat = startBeat
        self.lengthBeats = lengthBeats
    }
}

/// One arrange track row's CLIP BAND, in content-space points, plus the clips
/// drawn in it.
///
/// `clipTop..<clipBottom` is the clip lane ONLY — deliberately not the row's
/// full extent. A track's expanded take lanes / automation editor sit BELOW the
/// clip band and hold no clips, so a band that dips into them must not select
/// the row's clips (and must not shift the ladder's meaning either): they are
/// simply absent from this model, which is why the caller must pass real
/// `laneTop` values rather than a pitch this type could multiply out.
public struct ArrangeMarqueeLane: Equatable, Sendable {
    public var clipTop: CGFloat
    public var clipBottom: CGFloat
    public var clips: [ArrangeMarqueeClip]

    public init(clipTop: CGFloat, clipBottom: CGFloat, clips: [ArrangeMarqueeClip] = []) {
        self.clipTop = clipTop
        self.clipBottom = clipBottom
        self.clips = clips
    }
}

/// The pure decisions behind the m23-g3 rubber band.
public enum ArrangeMarquee {
    /// Pointer movement (points) that separates a CLICK from a marquee drag.
    ///
    /// The same 4 pt the ruler's `loopClickSlop` uses, and for the same reason:
    /// below it the press must stay a click, because `pointerHoverSurface`
    /// carries click-to-seek (m17-c) and double-click-create (m23-e) and a
    /// marquee that armed on a jittery press would steal both. It lives HERE,
    /// next to the geometry, so the gesture's threshold and the "did this
    /// gesture sweep anything" question have one answer.
    public static let dragSlop: CGFloat = 4

    /// The band two content-space points describe — NORMALIZED, so a drag
    /// right-to-left and/or bottom-to-top produces the same rect as the
    /// equivalent left-to-right, top-to-bottom one.
    ///
    /// `CGRect.standardized` is not enough on its own: `CGRect(x:y:width:height:)`
    /// with a negative width is legal but not standardized, and every consumer
    /// would then need to remember to standardize it. Producing the normalized
    /// rect HERE means a negative extent cannot exist downstream.
    public static func band(from origin: CGPoint, to current: CGPoint) -> CGRect {
        CGRect(x: min(origin.x, current.x), y: min(origin.y, current.y),
               width: abs(current.x - origin.x), height: abs(current.y - origin.y))
    }

    /// Every clip the band TOUCHES.
    ///
    /// - `band`: normalized content-space rect (see `band(from:to:)`).
    /// - `lanes`: the RESOLVED clip bands, in track order — built by the view
    ///   from its own `laneTop`/`rowHeight`, never from a pitch.
    /// - `pixelsPerBeat`: the live arrange zoom (m17-b law — nothing here
    ///   hardcodes a scale).
    ///
    /// Empty for a degenerate band (zero width or zero height) and for
    /// zero-length clips, which `ArrangePointer.clipIndex` also refuses to hit —
    /// one rule about degenerate spans across the whole pointer layer.
    public static func hits(
        band: CGRect, lanes: [ArrangeMarqueeLane], pixelsPerBeat: CGFloat
    ) -> Set<UUID> {
        guard band.width > 0, band.height > 0 else { return [] }
        let ppb = max(pixelsPerBeat, 0.0001)
        var out: Set<UUID> = []
        for lane in lanes {
            // Vertical overlap with the CLIP band, strictly. A band that only
            // touches a lane's edge (its bottom == the lane's top) has swept no
            // pixel of that lane and selects nothing from it.
            guard band.minY < lane.clipBottom, lane.clipTop < band.maxY else { continue }
            for clip in lane.clips where clip.lengthBeats > 0 {
                let x0 = CGFloat(clip.startBeat) * ppb
                let x1 = CGFloat(clip.endBeat) * ppb
                if band.minX < x1, x0 < band.maxX { out.insert(clip.id) }
            }
        }
        return out
    }

    /// The lane indices the band's VERTICAL extent covers — the same rule
    /// `hits` applies, exposed for the view's own affordances and for the debug
    /// echo, so "which rows did the band reach" can never be answered by a
    /// second, drifting computation.
    public static func laneIndices(
        band: CGRect, lanes: [ArrangeMarqueeLane]
    ) -> Set<Int> {
        guard band.width > 0, band.height > 0 else { return [] }
        var out: Set<Int> = []
        for (i, lane) in lanes.enumerated()
        where band.minY < lane.clipBottom && lane.clipTop < band.maxY {
            out.insert(i)
        }
        return out
    }
}
